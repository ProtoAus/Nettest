// server/monsters/mon_tentacle.qc
// ----------------------------------------------------------------------------
// monster_tentacle — Half-Life's silo-of-death tentacle (dlls/tentacle.cpp).
//
// Eight placements across the Sven hl_ campaign, all of them set pieces:
//   hl_c05_a2  3 (tent1/tent2/tent3, sweeparc 130)  — Blast Pit
//   hl_c11_a1  1 (tentacle, sweeparc 360, sound 1)  — Surface Tension
//   hl_c16_a2  4 (sweeparc 130/50/130, sound 1)     — Interloper
// Until now every one of them fell through to SV_OnEntityNoSpawnFunction and sat
// as an inert relay, which is why hl_c05_a2 cannot be completed: the map's whole
// middle act is three tentacles you have to get past.
//
// ---------------------------------------------------------------------------
// WHY THIS IS NOT AN AI_Think MONSTER
// ---------------------------------------------------------------------------
// Because CTentacle is not one either.  It overrides GetIdealState to return
// MONSTERSTATE_IDLE unconditionally (tentacle.cpp:73) and CanPlaySequence to
// return TRUE unconditionally (:74), which between them switch off state
// selection and sequence arbitration — the two things CBaseMonster exists to do.
// What is left drives pev->sequence, pev->frame and pev->framerate by hand from
// its own Cycle() think.
//
// Reproducing that on top of this tree's schedule layer would mean fighting
// AI_SetActivity for ownership of .frame on every tick, because the tentacle
// picks its next sequence from a MODEL NODE GRAPH rather than from an activity.
// So it is a plain entity with its own think, and it borrows the three pieces of
// the AI layer that are genuinely reusable:
//
//   * AI_ApplySequence  — the single place .frame is written, so the timing
//                         bookkeeping stays consistent with everything else.
//   * AI_AnimPump       — the shared animation-event pump.  The tentacle's
//                         damage window and every one of its impact sounds are
//                         studio events, so this is not a convenience: without
//                         it the monster is silent and harmless.
//   * .ai_damagefilter  — added in PATCH 153 for the gonarch's staged health.
//                         CTentacle::TakeDamage (:986-997) is the same shape of
//                         override: clamp the hit so health can never fall below
//                         1, and never die.
//
// ---------------------------------------------------------------------------
// HEARING IS THE ONLY INPUT IT HAS
// ---------------------------------------------------------------------------
// The tentacle is blind.  Everything it does — which level it climbs to, which
// way it faces, whether it strikes or taps or rears — comes out of Listen() and
// PBestSound() (:483-529), with HearingSensitivity 2.0 (:67) doubling the radius
// of every noise it can hear.
//
// This tree's producers for that (AI_HeardNoise / AI_HeardGunfire /
// AI_DangerSound) push straight onto monster_chain_head and keep nothing, and
// each walk is gated on `m.think == AI_Think` — which excludes this class by
// construction.  So sv_ai_core.qc now records the most recent world noise in a
// one-slot CSoundEnt equivalent (ai_worldsnd_pos/_radius/_time) that this file
// polls.  See the header there for what one slot does and does not buy.
//
// ---------------------------------------------------------------------------
// REVERSE PLAYBACK — WAS THE ONE REAL DIVERGENCE, NOW ISN'T
// ---------------------------------------------------------------------------
// HL steps between poses with FindTransition (animation.cpp:420-485), which walks
// the model's node graph and returns both a sequence AND A DIRECTION.  A -1 means
// "play this link backwards", set up as pev->frame = 255 and pev->framerate = -1
// (tentacle.cpp:649-663).
//
// PATCH 154 shipped this as forward-edges-only, cutting on the five transitions
// HL reverses (Lev2->Lev1, Lev3->Lev2, Lev<n>->pit, un-rear, un-rotate), because
// the server had no way to say "backwards": the client derived the whole playback
// clock itself, at rate exactly 1, from whenever .frame last changed.
//
// PATCH 155 removed that limit rather than working around it, and it turned out
// the renderer never needed anything.  HL_SetupBones (gl_hlmdl.c:1024) is a pure
// function of frametime — frame1 = (int)(frametime * sequence->timing), lerp to
// frame1+1 — with no accumulator and no assumption that time moves forwards.  A
// decreasing frametime always played the sequence backwards correctly; nothing
// could produce one.  So the engine now carries .animrate (HL's pev->framerate)
// in entity_state_t under PEXT2_FRAMERATE, and CL_LerpNetFrameState starts a
// negative rate at the sequence duration and counts down.
//
// The walk below is therefore HL's FindTransition, both directions, and the
// five cuts are gone.  tent_dbg_cuts should read 0 on every map; tent_dbg_revs
// counts the links actually walked backwards, so the feature stays measurable
// rather than becoming folklore.
//
// The rate is not only a sign.  HL uses the magnitude too, and all three uses are
// reproduced: a randomised +-0.2 per-transition jitter so a row of tentacles
// never moves in lockstep (tentacle.cpp:662), 1.5x while a noise is less than 2 s
// old, and a linear ramp back to 1.0 over the following 3 s (:696-705).  That
// agitation ramp — the tentacle sweeping visibly faster right after it hears you
// — was missing from Patch 154 as well, for the same reason.
//
// ---------------------------------------------------------------------------
// TOUCH DAMAGE
// ---------------------------------------------------------------------------
// HitTouch (:949-983) reads tr.iHitgroup off the global trace to tell a body
// slap (hitgroup >= 3, m_iHitDmg) from a glancing scrape (20).  It can do that
// because SetObjectCollisionBox (:52-56) inflates absmin/absmax to +-400 x 850
// so the studio hitboxes are reachable while pev->size stays 64 units at the
// base.  Neither half is available here: FTE reports no hitgroup for a touch,
// and a setsize to the full 800x800x850 would make the tentacle a solid block
// players cannot walk under, which is worse than the bug.
//
// So the damage lands where HL's own animation says the tentacle hits: on the
// `bang` event (code 1), in a radius around the computed impact point, at
// m_iHitDmg — which the model's own events raise to 200 for the killing swing
// (event 3) and drop back to 25 after it (event 4).  Same numbers, same instants,
// applied by proximity instead of by collision.
//
// ---------------------------------------------------------------------------
// Sequence indices are baked.  All four copies of tentacle2.mdl on this machine
// (valve, gearbox, bshift, svencoop) carry the SAME 53 sequences in the same
// order with the same node graph and an identical 14x14 transition matrix —
// checked byte for byte, not assumed.  Sven's copy is ten times the size only
// because of geometry and textures.  Tent_SelfTest re-checks the anchors by name
// at boot so a fifth copy cannot break this silently.
// ----------------------------------------------------------------------------

// The map keys.  `sweeparc` binds normally; `sound` cannot be a field at all —
// see the .hl_soundkey note in sv_customdefs.qc — and arrives via the
// unknown-key harvest in sv_multi_manager.qc.
.float  sweeparc;

.float  tent_maxyaw;		// m_flMaxYaw: sweeparc / 2, HL default 65
.float  tent_tapsnd;		// m_iTapSound: which impact material
.float  tent_goalseq;		// m_iGoalAnim
.float  tent_initialyaw;	// m_flInitialYaw: the facing it sweeps around
.float  tent_soundyaw;		// m_flSoundYaw: heard-noise bearing, relative
.float  tent_soundlevel;	// m_iSoundLevel: which height band the noise was in
.float  tent_soundtime;		// m_flSoundTime: how long it stays interested
.float  tent_prevsndtime;	// m_flPrevSoundTime
.vector tent_prevsndpos;	// m_vecPrevSound
.float  tent_hitdmg;		// m_iHitDmg
.float  tent_taprad;		// m_flTapRadius
.float  tent_nextsong;		// m_flNextSong
.float  tent_sndstamp;		// ai_worldsnd_time of the last noise consumed
// PATCH 155.  m_iDir is +1 or -1 and persists across thinks because the NEXT
// graph walk needs to know which end of the current sequence it is standing at
// (animation.cpp:441-448).  m_flFramerateAdj is re-rolled per transition and is
// what stops a row of tentacles sweeping in lockstep.
.float  tent_dir;			// m_iDir
.float  tent_rateadj;		// m_flFramerateAdj

// TE_* impact materials (:119-122).  -1 is a real value and means silence, which
// is why the field is read through a stof of the harvested string rather than
// defaulting to 0 on an absent key: the corpus writes 0 and 1 only, but the FGD
// allows -1 and a missing key must land on TE_SILO (0), HL's constructor value.
const float TENT_TE_NONE  = -1;
const float TENT_TE_SILO  = 0;
const float TENT_TE_DIRT  = 1;
const float TENT_TE_WATER = 2;

const string SND_TENT_HITSILO  = "tentacle/te_strike1.wav tentacle/te_strike2.wav";
const string SND_TENT_HITDIRT  = "player/pl_dirt1.wav player/pl_dirt2.wav player/pl_dirt3.wav player/pl_dirt4.wav";
const string SND_TENT_HITWATER = "player/pl_slosh1.wav player/pl_slosh2.wav player/pl_slosh3.wav player/pl_slosh4.wav";
const string SND_TENT_ROAR     = "tentacle/te_roar1.wav tentacle/te_roar2.wav";
const string SND_TENT_SEARCH   = "tentacle/te_search1.wav tentacle/te_search2.wav";
const string SND_TENT_MOVE     = "tentacle/te_move1.wav tentacle/te_move2.wav";
const string SND_TENT_SING     = "tentacle/te_sing1.wav tentacle/te_sing2.wav";
const string SND_TENT_ALERT    = "tentacle/te_alert1.wav tentacle/te_alert2.wav";

// ---------------------------------------------------------------------------
// the model, as data
// ---------------------------------------------------------------------------
// Parsed out of tentacle2.mdl rather than transcribed from the SDK's enum, so
// the numbers below cannot drift from what the renderer will actually play.
const float TSEQ_PIT_IDLE     = 0;
const float TSEQ_RISE         = 1;	// rise_to_Temp1,  node 9 -> 1
const float TSEQ_FLOOR_IDLE   = 3;
const float TSEQ_LEV1_IDLE    = 13;
const float TSEQ_LEV2_IDLE    = 23;
const float TSEQ_LEV3_IDLE    = 33;
const float TSEQ_ENGINE_IDLE  = 44;
const float TSEQ_ENGINE_SWAY  = 45;
const float TSEQ_ENGINE_BOB   = 47;
const float TSEQ_ENGINE_DIE1  = 48;
const float TSEQ_ENGINE_DIE3  = 50;
const float TSEQ_COUNT        = 53;

// entrynode / exitnode / nodeflags for all 53 sequences, one character each,
// 'A' = node 0 (meaning "outside the graph") through 'O' = node 14.  A string
// rather than an array because it is read-only data that has to be initialised
// before any tentacle spawns, and QC has no array initialiser.
const string TENT_NODE_ENTRY = "JJBEEEEEEEMNEBBBBBBBFGBCCCCCCCHICDDDADDDKLALOOOOOOOAA";
const string TENT_NODE_EXIT  = "JBEEEEEEEMNNBBBBBBBFGGCCCCCCCHIIDDDDADDKLLAOOOOOOOOAA";
const string TENT_NODE_FLAGS = "01000000011000000001101000000110100000011001000000000";

// The 14x14 transition matrix, one row per node, same 'A'+n encoding.  Each cell
// is the NEXT NODE on the way from the row's node to the column's node — the
// model's own shortest-path table, which is the whole reason a tentacle rises
// through Floor -> Lev1 -> Lev2 instead of appearing at Lev2.
const string TENT_TRANS =
	"ACCEFFCCJCCEEC"	// from node 1  (Lev1)
	"BADBBBHHBDDBBD"	// from node 2  (Lev2)
	"CCACCCCCCKKCCK"	// from node 3  (Lev3)
	"BBBABBBBBBBMMB"	// from node 4  (Floor)
	"BBBBAGBBBBBBBB"	// from node 5  (Lev1 rotated)
	"FFFFFAFFFFFFFF"	// from node 6  (Lev1 reared)
	"CCCCCCAICCCCCC"	// from node 7  (Lev2 rotated)
	"HHHHHHHAHHHHHH"	// from node 8  (Lev2 reared)
	"BBBBBBBBABBBBB"	// from node 9  (the pit)
	"DDDDDDDDDALDDL"	// from node 10 (Lev3 rotated)
	"KKKKKKKKKKAKKO"	// from node 11 (Lev3 reared)
	"EEEEEEEEEEEANE"	// from node 12 (Floor rotated)
	"MMMMMMMMMMMMAM"	// from node 13 (Floor reared)
	"LLLLLLLLLLLLLA";	// from node 14 (the engine)
const float TENT_NODES = 14;

float tent_dbg_cuts;		// graph walks that found no route and jumped to the goal
float tent_dbg_revs;		// PATCH 155: links walked BACKWARDS (pev->framerate < 0)
float tent_dbg_strikes;		// bang events that landed damage
float tent_dbg_heard;		// world sounds consumed

float(float seq) Tent_Entry
	= { if (seq < 0 || seq >= TSEQ_COUNT) return 0; return str2chr(TENT_NODE_ENTRY, seq) - 'A'; };
float(float seq) Tent_Exit
	= { if (seq < 0 || seq >= TSEQ_COUNT) return 0; return str2chr(TENT_NODE_EXIT, seq) - 'A'; };
float(float seq) Tent_NodeFlags
	= { if (seq < 0 || seq >= TSEQ_COUNT) return 0; return (str2chr(TENT_NODE_FLAGS, seq) == '1'); };

// Next hop from node `a` toward node `b`, both 1-based as the model stores them.
float(float a, float b) Tent_Trans =
{
	if (a < 1 || a > TENT_NODES || b < 1 || b > TENT_NODES)
		return 0;
	return str2chr(TENT_TRANS, (a - 1) * TENT_NODES + (b - 1)) - 'A';
};

// FindTransition (animation.cpp:420-485), both directions.
//
// QC has no out-parameters, so the direction comes back in this global — read it
// immediately after the call, exactly as HL reads m_iDir straight after
// FindTransition returns.  It is only ever meaningful for the call that just
// happened.
float tent_seq_dir;

float(entity m, float goal) Tent_NextSeq =
{
	float cur = m.ai_seq;
	tent_seq_dir = 1;

	if (cur < 0 || cur >= TSEQ_COUNT || goal < 0 || goal >= TSEQ_COUNT)
		return goal;

	float ge = Tent_Entry(goal);
	// HL bails on either end being node 0, and so must this: Lev1_Door_reach,
	// Lev3_Fidget_Swipe and Sven's two grab sequences are all outside the graph,
	// and routing to or from one would index the matrix at -1.
	if (ge == 0 || Tent_Entry(cur) == 0)
		return goal;

	// Which end of the CURRENT sequence we are standing at depends on which way
	// it has been playing — HL reads exitnode when moving forwards and entrynode
	// when moving backwards (animation.cpp:441-448).  Getting this wrong is not
	// cosmetic: a tentacle part-way through a reversed link would route from the
	// node it is heading AWAY from.
	float ee;
	if (m.tent_dir > 0)
		ee = Tent_Exit(cur);
	else
		ee = Tent_Entry(cur);

	if (ee == ge)
		return goal;

	float mid = Tent_Trans(ee, ge);
	if (mid == 0)
		return goal;

	float i = 0;
	while (i < TSEQ_COUNT)
	{
		if (Tent_Entry(i) == ee && Tent_Exit(i) == mid)
			return i;
		// A link the model marks reversible (nodeflags) can be walked the other
		// way, and that is what pev->framerate = -1 is for.  Both tests sit in
		// the SAME iteration, exactly as HL has them: the winner is whichever
		// matches at the lower sequence index, not "forward first".  Splitting
		// them into two passes would pick a different sequence on any rig that
		// offers both, so the shape is load-bearing rather than stylistic.
		if (Tent_NodeFlags(i))
		{
			if (Tent_Exit(i) == ee && Tent_Entry(i) == mid)
			{
				tent_seq_dir = -1;
				tent_dbg_revs = tent_dbg_revs + 1;
				return i;
			}
		}
		i = i + 1;
	}

	// HL prints "error in transition graph" here and returns the goal.  Counted
	// rather than printed: this fires per think, not once.
	tent_dbg_cuts = tent_dbg_cuts + 1;
	return goal;
};

// ---------------------------------------------------------------------------
// levels
// ---------------------------------------------------------------------------
// Level(dz) and MyHeight() verbatim (:350-374).  The bands are what turn "a
// noise happened 300 units above me" into "climb to Lev1 and strike".
float(float dz) Tent_LevelForZ =
{
	if (dz < 216)	return 0;
	if (dz < 408)	return 1;
	if (dz < 600)	return 2;
	return 3;
};

float(entity m) Tent_MyLevel =
{
	float s = m.ai_seq;
	if (s < 0)			return -1;
	if (s == TSEQ_PIT_IDLE)		return -1;
	if (s <= 12)			return 0;	// rise/temp1/floor family + Floor_to_Lev1
	if (s <= 22)			return 1;
	if (s <= 32)			return 2;
	if (s <= 41)			return 3;
	return -1;			// door reach, engine family, Sven's grab pair
};

float(entity m) Tent_MyHeight =
{
	float l = Tent_MyLevel(m);
	if (l == 1)	return 256;
	if (l == 2)	return 448;
	if (l == 3)	return 640;
	return 0;
};

// LookupActivity for the four level-indexed activity families.  Written out as
// tables rather than driven through frameforaction because the tentacle's tags
// are ACT_T_* (1010/1020/1030/1040 + level), which are private to this monster
// and are not in the shared ACT_ enum at all.
//
// The idle weights are the model's own: the plain idle carries actweight 5 and
// each fidget 1, which is what makes a tentacle mostly hold still and
// occasionally do something.
float(float lvl) Tent_IdleSeq =
{
	float r = random() * 8;
	if (lvl == 1)
	{
		if (r < 5) return TSEQ_LEV1_IDLE;
		return 14 + floor((r - 5) * 3 / 3);	// 14/15/16
	}
	if (lvl == 2)
	{
		// Only three tagged variants here: Lev2_Fidget_Swing carries activity 0
		// in the model and is therefore not a candidate, however much it looks
		// like one in the SDK's enum.
		if (r < 5) return TSEQ_LEV2_IDLE;
		if (r < 6.5) return 24;
		return 26;
	}
	if (lvl == 3)
	{
		if (r < 5) return TSEQ_LEV3_IDLE;
		if (r < 6.5) return 34;
		return 35;
	}
	if (r < 5) return TSEQ_FLOOR_IDLE;
	return 4 + floor((r - 5) * 3 / 3);		// 4/5/6
};

float(float lvl) Tent_TapSeq =
{
	if (lvl == 1) return 18;
	if (lvl == 2) return 28;
	if (lvl == 3) return 38;
	return 8;
};

float(float lvl) Tent_StrikeSeq =
{
	if (lvl == 1) return 17;
	if (lvl == 2) return 27;
	if (lvl == 3) return 37;
	return 7;
};

float(float lvl) Tent_RearIdleSeq =
{
	if (lvl == 1) return 21;
	if (lvl == 2) return 31;
	if (lvl == 3) return 41;
	return 11;
};

// Is this sequence one of the eight rear/rear-idle poses?  The yaw clamp inverts
// for those: a reared tentacle faces AWAY from the noise, so the sweep limit
// becomes a minimum instead of a maximum (:535-547).
float(float s) Tent_IsRear =
{
	return (s == 10 || s == 11 || s == 20 || s == 21
	     || s == 30 || s == 31 || s == 40 || s == 41);
};

// ---------------------------------------------------------------------------
// playback
// ---------------------------------------------------------------------------
// `sv_ai_debug 2`.  Nothing this monster does renders in a headless run, and a
// tentacle that never leaves Pit_Idle looks exactly like a tentacle that hears
// nothing — so the one line that separates those two is which sequence it just
// moved to and why.  goal is what Cycle asked for, seq is what the graph walk
// handed back; the two differing IS the transition system working.
void(entity m, float seq) Tent_TraceSeq =
{
	if (cvar("sv_ai_debug") < 2)
		return;
	dprint(sprintf("[tentacle] \"%s\" seq %g -> %g (goal %g, lvl %g, yaw %g)\n",
	               m.targetname, m.ai_seq, seq, m.tent_goalseq,
	               Tent_MyLevel(m), m.tent_soundyaw));
};

// PATCH 155: the playback rate, rebuilt from m_iDir on every transition exactly
// where HL rebuilds it (tentacle.cpp:660-663).  Tent_RateRamp then rides on top
// of this each think for as long as a noise stays fresh.
//
// The +-0.2 jitter is re-rolled here rather than at spawn because HL re-rolls it
// per transition, and that is what keeps three tentacles in the same silo from
// beating in sync after a few seconds.
void(entity m) Tent_SetRate =
{
	m.tent_rateadj = -0.2 + random() * 0.4;
	m.animrate     = m.tent_dir * 1.0 + m.tent_rateadj;
};

// tentacle.cpp:696-705.  1.5x while the last noise is under 2 s old, then a
// linear ramp back to 1.0 across the next 3 s.  Called every think, not just on
// a transition, because the ramp is continuous.
//
// Sign carried through m_iDir throughout: a REVERSED link agitates too, and
// multiplying a negative rate by a positive scale is what keeps it reversed.
void(entity m) Tent_RateRamp =
{
	if (m.tent_prevsndtime + 2.0 > time)
		m.animrate = m.tent_dir * 1.5 + m.tent_rateadj;
	else if (m.tent_prevsndtime + 5.0 > time)
		m.animrate = m.tent_dir
		           + m.tent_dir * (5 - (time - m.tent_prevsndtime)) / 2
		           + m.tent_rateadj;
};

void(entity m, float seq) Tent_PlaySeq =
{
	if (seq != m.ai_seq)
		Tent_TraceSeq(m, seq);

	// tent_seq_dir is whatever the Tent_NextSeq call that produced `seq` decided.
	// QC evaluates the inner call first, so by the time we are here it refers to
	// this transition.  HL clamps a non-positive direction to exactly -1 ("just
	// to safe", tentacle.cpp:657) and so does this.
	if (tent_seq_dir > 0)
		m.tent_dir = 1;
	else
		m.tent_dir = -1;
	Tent_SetRate(m);
	// Looping is a parameter here for the same reason AI_SetSequenceNamed takes
	// one: no builtin reports a sequence's loop flag.  Every one of these is
	// driven to completion and then re-chosen by Cycle, so none of them loops —
	// including Pit_Idle, which is a single frame and would report a zero
	// duration.  AI_ApplySequence substitutes 0.1 s for that case, which is
	// exactly the re-poll interval wanted.
	AI_ApplySequence(m, seq, FALSE);
	m.ai_seqname = "";
};

void(entity m, float lvl, float vol) Tent_ImpactSound =
{
	if (m.tent_tapsnd == TENT_TE_NONE)
		return;
	string fam = SND_TENT_HITSILO;
	if (m.tent_tapsnd == TENT_TE_DIRT)	fam = SND_TENT_HITDIRT;
	if (m.tent_tapsnd == TENT_TE_WATER)	fam = SND_TENT_HITWATER;

	// HL emits this at the computed impact point through UTIL_EmitAmbientSound.
	// Played from the tentacle instead: the impact is at most 512 units out along
	// a body that is already 640 units tall, so the point source and the entity
	// source are the same order of distance apart as the model is big.
	AI_Sound(m, CHAN_BODY, AI_SndPick(fam), vol, ATTN_NORM);
};

// Where the tentacle's tip is at this instant: m_flTapRadius out along its own
// facing, at the height of whichever level it is on (:863-865).
vector(entity m) Tent_TipPos =
{
	makevectors('0 1 0' * m.angles_y);
	vector p = m.origin + v_forward * m.tent_taprad;
	p_z = m.origin_z + Tent_MyHeight(m);
	return p;
};

// ---------------------------------------------------------------------------
// the animation events
// ---------------------------------------------------------------------------
// Codes and meanings from HandleAnimEvent (:814-920).  Events 3 and 4 are the
// whole reason a tentacle is lethal: they bracket the part of a strike where a
// hit is fatal rather than merely painful.
void() Tent_Event =
{
	if (ai_event_code == 1)			// bang — the tip lands
	{
		Tent_ImpactSound(self, Tent_MyLevel(self), 1.0);

		// The damage.  See the header for why this is a proximity test and not a
		// touch: HL leans on studio hitboxes and an inflated collision box, and
		// neither is reachable from here.  128 units is the tentacle's own girth
		// at the tip rather than a tuning knob — narrower and a strike that
		// visibly lands on you would miss.
		vector tip = Tent_TipPos(self);
		entity e = findradius(tip, 128);
		while (e)
		{
			entity nxt = e.chain;

			// NO takedamage GATE, for the reason AI_BlastAttack:234-242 spells
			// out: players in this mod sit at DAMAGE_NO permanently, so testing
			// it here would exempt the only thing a tentacle is meant to kill.
			// W_ApplyDamage asks W_CanDamageTarget, which is the authority.
			if (e != self)
			if (!(e.flags & FL_MONSTER) || e.classname != self.classname)
			{
				sv_dmg_bits = DMG_CRUSH;
				if (W_ApplyDamage(self, e, self.tent_hitdmg))
					tent_dbg_strikes = tent_dbg_strikes + 1;
			}
			e = nxt;
		}
		return;
	}

	if (ai_event_code == 3) { self.tent_hitdmg = 200; return; }	// killing swing opens
	if (ai_event_code == 4) { self.tent_hitdmg = 25;  return; }	// and closes

	if (ai_event_code == 2 || ai_event_code == 6)	// scrape / light tap
	{
		Tent_ImpactSound(self, Tent_MyLevel(self), 0.3 + random() * 0.2);
		return;
	}

	if (ai_event_code == 5)				// whoosh
	{
		AI_Sound(self, CHAN_BODY, "tentacle/te_swing2.wav", 1, ATTN_NORM);
		return;
	}
	if (ai_event_code == 7) { AI_SndPlay(self, CHAN_VOICE, SND_TENT_ROAR);   return; }
	if (ai_event_code == 8) { AI_SndPlay(self, CHAN_VOICE, SND_TENT_SEARCH); return; }
	if (ai_event_code == 9) { AI_SndPlay(self, CHAN_BODY,  SND_TENT_MOVE);   return; }
};

// ---------------------------------------------------------------------------
// hearing
// ---------------------------------------------------------------------------
// Listen() + PBestSound(), against the one-slot world-sound record.  The
// extrapolation is HL's (:494-502): a noise that moved since last time is
// projected forward, which is what makes a tentacle lead a running player
// instead of striking where they were.
void(entity m) Tent_Listen =
{
	if (ai_worldsnd_time <= m.tent_sndstamp)
		return;					// nothing new since the last poll
	if (ai_worldsnd_time <= 0)
		return;

	// HearingSensitivity 2.0 (:67): this monster hears twice as far as the noise
	// nominally carries, and it is the only sense it has.
	if (vlen(ai_worldsnd_pos - m.origin) > ai_worldsnd_radius * 2)
		return;

	m.tent_sndstamp = ai_worldsnd_time;
	tent_dbg_heard  = tent_dbg_heard + 1;

	vector dir;
	if (time - m.tent_prevsndtime < 0.5)
	{
		float dt = time - m.tent_prevsndtime;
		dir = ai_worldsnd_pos + (ai_worldsnd_pos - m.tent_prevsndpos) / dt - m.origin;
	}
	else
		dir = ai_worldsnd_pos - m.origin;

	m.tent_prevsndtime = time;
	m.tent_prevsndpos  = ai_worldsnd_pos;

	m.tent_soundyaw   = AI_AngleNorm(vectoyaw(dir) - m.tent_initialyaw);
	m.tent_soundlevel = Tent_LevelForZ(dir_z);
	m.tent_soundtime  = time + 5 + random() * 5;
};

// ---------------------------------------------------------------------------
// Cycle — the think (:459-706)
// ---------------------------------------------------------------------------
void() Tent_Cycle =
{
	self.nextthink = time + 0.1;

	AI_AnimPump(self);
	AI_ChangeYaw(self, 0.1);
	Tent_Listen(self);

	// Clip the desired facing into the sweep arc.  A reared pose inverts the
	// clamp — it is the pose for a noise BEHIND the tentacle, so the arc becomes
	// the closest it may come to facing forward rather than the furthest.
	float dy = self.tent_soundyaw;
	if (Tent_IsRear(self.ai_seq))
	{
		if (dy < 0 && dy > 0 - self.tent_maxyaw)	dy = 0 - self.tent_maxyaw;
		if (dy > 0 && dy <  self.tent_maxyaw)		dy = self.tent_maxyaw;
	}
	else
	{
		if (dy < 0 - self.tent_maxyaw)	dy = 0 - self.tent_maxyaw;
		if (dy >     self.tent_maxyaw)	dy =     self.tent_maxyaw;
	}
	self.ai_yaw_ideal = AI_AngleNorm(self.tent_initialyaw + dy);

	if (!AI_SeqDone(self))
		return;

	float lvl = Tent_MyLevel(self);

	if (self.health <= 1)
	{
		// Shot to a standstill.  It does not die — CTentacle::Killed (:1002-1006)
		// only sets the goal — it retreats into the pit and comes back with full
		// health, which is why Blast Pit cannot be won with bullets.
		self.tent_goalseq = TSEQ_PIT_IDLE;
		if (self.ai_seq == TSEQ_PIT_IDLE)
			self.health = self.max_health;
	}
	else if (self.tent_soundtime > time)
	{
		// Still interested in the last noise.  Which of the three responses it
		// picks is purely the bearing: in the arc, just outside it, or behind.
		if (self.tent_soundyaw >= 0 - (self.tent_maxyaw + 30)
		 && self.tent_soundyaw <=      self.tent_maxyaw + 30)
			self.tent_goalseq = Tent_StrikeSeq(self.tent_soundlevel);
		else if (self.tent_soundyaw >= 0 - self.tent_maxyaw * 2
		      && self.tent_soundyaw <=     self.tent_maxyaw * 2)
			self.tent_goalseq = Tent_TapSeq(self.tent_soundlevel);
		else
			self.tent_goalseq = Tent_RearIdleSeq(self.tent_soundlevel);
	}
	else if (self.ai_seq == TSEQ_PIT_IDLE)
	{
		self.tent_goalseq = TSEQ_PIT_IDLE;	// stays down until it hears something
	}
	else if (self.ai_seq == self.tent_goalseq)
	{
		if (lvl >= 0 && time < self.tent_soundtime)
		{
			if (floor(random() * 10) < self.tent_soundtime - time)
				self.tent_goalseq = Tent_StrikeSeq(self.tent_soundlevel);
			else
				self.tent_goalseq = Tent_TapSeq(self.tent_soundlevel);
		}
		else if (lvl < 0)
			self.tent_goalseq = Tent_IdleSeq(0);
		else
		{
			if (self.tent_nextsong < time)
			{
				AI_SndPlay(self, CHAN_VOICE, SND_TENT_SING);
				self.tent_nextsong = time + 10 + random() * 10;
			}

			// One roll in sixteen wanders to a DIFFERENT level, which is the only
			// thing that ever makes an undisturbed tentacle change height.
			if (floor(random() * 16) == 0)
				self.tent_goalseq = Tent_IdleSeq(floor(random() * 4));
			else if (floor(random() * 4) == 0)
				self.tent_goalseq = Tent_TapSeq(lvl);
			else
				self.tent_goalseq = Tent_IdleSeq(lvl);
		}

		// Drift the remembered bearing back toward centre so a tentacle that
		// heard one noise does not stare at that spot forever.
		if (self.tent_soundyaw < 0)
			self.tent_soundyaw = self.tent_soundyaw + 2 + random() * 6;
		else
			self.tent_soundyaw = self.tent_soundyaw - 2 - random() * 6;
	}

	Tent_PlaySeq(self, Tent_NextSeq(self, self.tent_goalseq));

	// The tap radius: how far out the tip lands.  HL traces forward at two
	// heights and blends a bone controller between them, so the tentacle reaches
	// the wall it is actually next to rather than a fixed distance.  The blend is
	// not reachable here (no bone controller on this rig), but the trace is what
	// positions the impact sound and the strike damage, so it is kept.
	float s = self.ai_seq;
	if (s == 8 || s == 18 || s == 28 || s == 38)
	{
		makevectors('0 1 0' * self.angles_y);
		vector src = self.origin + '0 0 1' * (Tent_MyHeight(self) - 4);
		traceline(src, src + v_forward * 512, MOVE_NOMONSTERS, self);
		float lo = trace_fraction * 512;

		src = self.origin + '0 0 1' * (Tent_MyHeight(self) + 8);
		traceline(src, src + v_forward * 512, MOVE_NOMONSTERS, self);
		float hi = trace_fraction * 512;

		self.tent_taprad = lo + random() * (hi - lo);
	}
	else
		self.tent_taprad = 336;			// 400 - 64, HL's default reach

	self.view_ofs_z = Tent_MyHeight(self);

	// PATCH 155: last, and OUTSIDE the transition branch above, exactly where HL
	// puts it (tentacle.cpp:696-705).  The agitation ramp is a continuous
	// function of how long ago the noise was, so it has to be re-evaluated on
	// every think and not only when the sequence changes.
	Tent_RateRamp(self);
};

// ---------------------------------------------------------------------------
// DieThink (:740-811)
// ---------------------------------------------------------------------------
// Not a death in the usual sense: the tentacle has already stopped taking damage
// and is now playing out either the engine thrash (Engine_Idle/Sway/Swat/Bob, on
// a loop) or the three-part death, after which the edict goes away.
void() Tent_DieThink =
{
	self.nextthink = time + 0.1;

	AI_AnimPump(self);
	self.ai_yaw_speed = 24;
	AI_ChangeYaw(self, 0.1);

	if (!AI_SeqDone(self))
		return;

	if (self.ai_seq == self.tent_goalseq)
	{
		if (self.ai_seq >= TSEQ_ENGINE_IDLE && self.ai_seq <= TSEQ_ENGINE_BOB)
			self.tent_goalseq = TSEQ_ENGINE_SWAY + floor(random() * 3);
		else if (self.ai_seq >= TSEQ_ENGINE_DIE1 && self.ai_seq <= TSEQ_ENGINE_DIE3)
		{
			remove(self);
			return;
		}
	}

	Tent_PlaySeq(self, Tent_NextSeq(self, self.tent_goalseq));

	// Facing flips 180 degrees for the engine and rear poses (:784-808) — those
	// animations are authored looking the other way.
	// PATCH 155: DieThink sets the rate per branch and does NOT use the noise
	// ramp — by this point the tentacle is not listening any more.  The rear and
	// engine poses keep the direction (and so can still run backwards); anything
	// else is pinned to a flat forward 1.5 regardless of m_iDir, which is
	// tentacle.cpp:801-807 exactly.
	float s = self.ai_seq;
	if (Tent_IsRear(s) || (s >= TSEQ_ENGINE_IDLE && s <= TSEQ_ENGINE_DIE3))
	{
		self.ai_yaw_ideal = AI_AngleNorm(self.tent_initialyaw + 180);
		self.animrate     = self.tent_dir + (-0.2 + random() * 0.4);
	}
	else
	{
		self.ai_yaw_ideal = AI_AngleNorm(self.tent_initialyaw);
		self.animrate     = 1.5;
	}
};

// ---------------------------------------------------------------------------
// CommandUse (:710-736)
// ---------------------------------------------------------------------------
// THE USE TYPE HAS TO BE RESOLVED BY HAND HERE, and it is worth saying why.
//
// hl_c05_a2 drives all three tentacles through trigger_relays, and it uses three
// different states to mean three different things:
//
//     tentacle_ladder_1/2   triggerstate 1        -> USE_ON     ping them
//     tentacle_thrash       triggerstate 2        -> USE_TOGGLE thrash
//     tentacle_die          triggerstate ABSENT   -> USE_OFF    die
//
// Half-Life's CTriggerRelay leaves m_triggerType at 0 when the key is absent, so
// absent and an explicit 0 both mean Off.  This tree's shared mapper
// (GoldSrc_TriggerStateToUseType, sv_triggers.qc:287) deliberately folds 0 and
// unset onto USE_TOGGLE instead, on the grounds that a QC float cannot tell them
// apart and the Sven FGD's editor default is 2.  For every other class that
// choice is a wash; for this one it collapses "die" and "thrash" onto the same
// value and Blast Pit can never be completed.
//
// So the raw key is read back off the caller, which is exact — .triggerstate
// reads 0 for both spellings and HL maps both to Off — and it changes nothing
// outside this file.  The general question is real and measured (1335 corpus
// trigger_relays omit the key, 194 write an explicit 0, and they target env_beam,
// ambient_generic, func_door and friends where Off and Toggle differ visibly);
// it wants its own patch and its own regression run, not a silent flip here.
float() Tent_UseType =
{
	if (sub_use_caller && sub_use_caller.classname == "trigger_relay"
	    && sub_use_caller.triggerstate == 0)
		return USE_OFF;
	return sub_use_type;
};

void() Tent_Use =
{
	float ut = Tent_UseType();

	if (ut == USE_ON)
	{
		// bits_SOUND_WORLD at radius 1024 from the activator (:720-726).  This is
		// how a map points a tentacle at something: hl_c05_a2 fires it as you
		// climb each ladder, so all three turn toward you.
		if (activator)
			AI_WorldSoundRecord(activator.origin, 1024, SND_WORLD);
		return;
	}
	if (ut == USE_SET)
		return;

	self.takedamage   = DAMAGE_NO;
	self.think        = Tent_DieThink;
	self.nextthink    = time + 0.1;
	self.tent_goalseq = (ut == USE_OFF) ? TSEQ_ENGINE_DIE1 : TSEQ_ENGINE_IDLE;

	if (cvar("sv_debug_use"))
		print(sprintf("[tentacle] \"%s\" use %g -> %s\n", self.targetname, ut,
		              (ut == USE_OFF) ? "death" : "engine thrash"));
};

// CTentacle::TakeDamage (:986-997), through the PATCH 153 hook.  It cannot die
// and it cannot go below 1: a hit big enough to kill floors it instead, and Cycle
// reads that floor as "retreat to the pit".
float(entity m, float damage, float dmgbits) Tent_DamageFilter =
{
	if (damage >= m.health)
		return m.health - 1;
	return damage;
};

// ---------------------------------------------------------------------------
// spawn
// ---------------------------------------------------------------------------
void() Tent_Precache =
{
	precache_model("models/tentacle2.mdl");
	precache_sound("ambience/flies.wav");
	precache_sound("ambience/squirm2.wav");
	precache_sound("tentacle/te_flies1.wav");
	precache_sound("tentacle/te_squirm2.wav");
	precache_sound("tentacle/te_swing1.wav");
	precache_sound("tentacle/te_swing2.wav");
	AI_SndPrecache(SND_TENT_HITSILO);
	AI_SndPrecache(SND_TENT_HITDIRT);
	AI_SndPrecache(SND_TENT_HITWATER);
	AI_SndPrecache(SND_TENT_ROAR);
	AI_SndPrecache(SND_TENT_SEARCH);
	AI_SndPrecache(SND_TENT_MOVE);
	AI_SndPrecache(SND_TENT_SING);
	AI_SndPrecache(SND_TENT_ALERT);
};

// The ambient bed.  HL plays flies from the FIRST tentacle on the map and squirm
// from the second, then nothing (:931-941) — two static-file loops that between
// them cover the whole silo.  Reproduced with the same two globals rather than
// per-tentacle, or hl_c16_a2's four would stack four copies of each.
float tent_flysound, tent_squirmsound;

void() Tent_Start =
{
	self.think     = Tent_Cycle;
	self.nextthink = time + 0.1;

	if (!tent_flysound)
	{
		tent_flysound = TRUE;
		AI_Sound(self, CHAN_BODY, "ambience/flies.wav", 1, ATTN_NORM);
	}
	else if (!tent_squirmsound)
	{
		tent_squirmsound = TRUE;
		AI_Sound(self, CHAN_BODY, "ambience/squirm2.wav", 1, ATTN_NORM);
	}
};

void() monster_tentacle =
{
	Tent_Precache();

	self.solid      = SOLID_BBOX;
	self.movetype   = MOVETYPE_FLY;		// held in place; nothing pushes it
	self.health     = 75;
	self.max_health = 75;
	// DAMAGE_YES, not HL's DAMAGE_AIM.  W_CanDamageTarget (sv_weapons.qc:1279)
	// rejects anything whose .takedamage is not exactly DAMAGE_YES, and every
	// damage path in the tree goes through it — so DAMAGE_AIM here would make the
	// tentacle unshootable and Tent_DamageFilter unreachable, which in turn means
	// it could never be driven back into the pit.  Found while testing the
	// Nihilanth, which had the same line.
	self.takedamage = DAMAGE_YES;
	self.flags      = self.flags | FL_MONSTER;

	setmodel(self, "models/tentacle2.mdl");
	setsize(self, '-32 -32 0', '32 32 64');
	setorigin(self, self.origin);

	// The 64-unit hull is right and stays (see the header note at :96-98: sizing the
	// hull to the model would wall off the silo).  What was missing is the SEPARATE
	// shot-cull box HL gives it — tentacle.cpp:52-56 writes absmin/absmax of
	// (-400,-400,0)..(400,400,850) precisely so the studio hitboxes up the length of
	// the tentacle are reachable while pev->size stays 64 at the base.  This class
	// never calls Monster_Build, so it is not on monster_chain and the trace-time
	// inflation walk cannot see it; register it on the side-list that walk also reads.
	Monster_SOCBRegister(self);

	// sweeparc is the FULL arc and m_flMaxYaw is half of it (:333-337), so the
	// hl_c11_a1 tentacle's 360 becomes a 180-degree swing either way — no clamp
	// at all, which is the point of that placement.
	if (self.sweeparc > 0)
		self.tent_maxyaw = self.sweeparc / 2;
	else
		self.tent_maxyaw = 65;			// the constructor's value (:327)

	self.tent_tapsnd = (self.hl_soundkey != "" && self.hl_soundkey)
	                   ? stof(self.hl_soundkey) : TENT_TE_SILO;

	self.tent_initialyaw = self.angles_y;
	self.ai_yaw_ideal    = self.angles_y;
	self.ai_yaw_speed    = 18;		// pev->yaw_speed (:277)
	self.tent_hitdmg     = 20;		// (:284)
	self.tent_taprad     = 336;
	self.bloodcolor      = 195;		// BLOOD_COLOR_GREEN

	self.ai_damagefilter = Tent_DamageFilter;
	self.ai_event        = Tent_Event;
	self.use             = Tent_Use;

	// spawnflags 128 (SF_MONSTER_WAIT_FOR_SCRIPT) is present on hl_c11_a1's
	// tentacle and is inert in Half-Life too: CTentacle::Spawn reads no spawnflag
	// at all.  Recorded so nobody implements it twice.

	self.ai_seq = -1;
	// m_iDir = 1 (tentacle.cpp:275).  Both this and tent_seq_dir must be set
	// before the first Tent_PlaySeq: that call does not come via Tent_NextSeq,
	// so it would otherwise adopt whatever direction the LAST tentacle to spawn
	// happened to leave in the global.
	self.tent_dir = 1;
	tent_seq_dir  = 1;
	Tent_PlaySeq(self, TSEQ_PIT_IDLE);

	self.think     = Tent_Start;
	self.nextthink = time + 0.2;

	if (cvar("sv_ai_debug"))
		dprint(sprintf("[tentacle] \"%s\" at %v: arc %g maxyaw %g material %g\n",
		               self.targetname, self.origin, self.sweeparc,
		               self.tent_maxyaw, self.tent_tapsnd));
};

// ---------------------------------------------------------------------------
// boot self-test  (sv_tentacle_selftest)
// ---------------------------------------------------------------------------
// The baked indices are the fragile part of this file, so they get checked
// against the model actually loaded rather than trusted.  Anchors chosen to span
// the table: one per level, both ends of the engine family, and the pit.
//
// Also walks the node graph the way Tent_NextSeq does and reports how many of the
// 53 sequences are reachable from the pit, which is the one number that would
// change if a replacement rig re-ordered the table without renaming anything.
//
// TWO PHASES, because the interesting half cannot be checked synchronously.  A
// tentacle is BLIND: it does nothing at all until a world noise happens near it,
// and a headless server has no player to make one.  So phase 1 injects a noise
// into the same one-slot record AI_HeardNoise writes, and phase 2 comes back
// three seconds later and reports where each tentacle got to.  That is the only
// end-to-end proof available without eyes on the map — it exercises Listen, the
// height banding, the strike/tap/rear choice and the whole transition walk, and a
// tentacle still sitting in Pit_Idle at phase 2 is an unambiguous failure.
float  tent_selftest_phase;
float  tent_selftest_at;
vector tent_selftest_noise;
float  tent_selftest_radius;

void() Tent_SelfTestReport =
{
	entity t = find(world, classname, "monster_tentacle");
	if (!t)
		return;

	// EARSHOT, not the whole map.  hl_c16_a2 carries four tentacles and the
	// fourth is 3,700 units from the other three — well outside the doubled 1024
	// radius of the injected noise — so it is CORRECT for it to stay in the pit.
	// Counting it as a failure was the first version of this test and it reported
	// BAD=1 on a working monster; the eligible set is what the assertion is about.
	float n = 0, heard_n = 0, moved = 0;
	string seqs = "";
	while (t)
	{
		n = n + 1;
		float inrange = (vlen(t.origin - tent_selftest_noise)
		                 <= tent_selftest_radius * 2);
		if (inrange)
			heard_n = heard_n + 1;
		if (t.ai_seq != TSEQ_PIT_IDLE)
			moved = moved + 1;
		seqs = strcat(seqs, ftos(t.ai_seq), "/L", ftos(Tent_MyLevel(t)),
		              inrange ? " " : "* ");
		t = find(t, classname, "monster_tentacle");
	}

	// Did the strike land on the stand-in?  Its health is the whole answer, and a
	// full 1000 means the damage path did nothing — which is a failure even
	// though every sequence played correctly.
	float bad  = (moved < heard_n) ? 1 : 0;
	float hurt = 0;
	entity d = find(world, classname, "tentacle_selftest_target");
	if (d)
	{
		hurt = d.max_health - d.health;
		if (hurt <= 0)
			bad = bad + 1;
		remove(d);
	}

	// The pieces are folded into one string before the sprintf because fteqcc
	// caps a varargs call at EIGHT parameters INCLUDING the format, and this
	// wants ten.
	// PATCH 155: revs= is the count of node-graph links walked BACKWARDS, i.e.
	// the thing that was impossible before .animrate was networked.  cuts= is now
	// a genuine failure indicator rather than an expected cost: it means the walk
	// found no route at all, forwards or reversed, and jumped to the goal.
	string tail = sprintf("cuts=%g revs=%g strikes=%g heard=%g dmg=%g",
	                      tent_dbg_cuts, tent_dbg_revs, tent_dbg_strikes, tent_dbg_heard, hurt);
	// A trailing '*' on a tentacle marks one that was out of earshot of the test
	// noise and is therefore not expected to have moved.
	print(sprintf("[tentacletest] %g tentacle(s), %g/%g in earshot woke: %s  %s  BAD=%g\n",
	              n, moved, heard_n, seqs, tail, bad));
};

void() Tent_SelfTest =
{
	if (!cvar("sv_tentacle_selftest") || tent_selftest_phase >= 2)
		return;
	if (tent_selftest_at <= 0)
		tent_selftest_at = 3;
	if (time < tent_selftest_at)
		return;

	if (tent_selftest_phase == 1)
	{
		tent_selftest_phase = 2;
		Tent_SelfTestReport();
		return;
	}
	// EIGHT SECONDS, not three.  The rise alone is 4 s (rise_to_Temp1 at 15 fps
	// over 61 frames) and the Lev1 strike another 1 s on top, so a shorter window
	// samples a tentacle that is still climbing and reports a false failure on
	// the damage check.
	tent_selftest_phase = 1;
	tent_selftest_at    = time + 8;

	// getmodelindex, not precache_model: this tree's precache_model is a QC
	// wrapper around the builtin (sh_modellist.qc) and returns the possibly
	// REMAPPED name as a string, not an index — and the remap is exactly what a
	// replacement-model list would change, so asking for the index of whatever
	// actually loaded is the right question anyway.
	float mi = getmodelindex("models/tentacle2.mdl");
	if (mi <= 0)
	{
		// No tentacle on this map, so the rig was never precached.  Say so
		// rather than reporting a failure: the sweep runs this on every map and
		// only three of them carry one.
		print("[tentacletest] no monster_tentacle on this map; gate only, BAD=0\n");
		return;
	}

	float bad = 0;
	float n   = modelframecount(mi);
	if (n != TSEQ_COUNT)
	{
		print(sprintf("[tentacletest] BAD sequence count: %g, expected %g\n",
		              n, TSEQ_COUNT));
		bad = bad + 1;
	}

	// name -> expected index, checked one at a time so the report names the
	// offender rather than just failing.
	string names = "Pit_Idle rise_to_Temp1 Floor_Idle Lev1_Idle Lev2_Idle Lev3_Idle Engine_Idle Engine_death3";
	string want  = "0 1 3 13 23 33 44 50";
	float  i;
	float  cnt = tokenize(names);
	string got = "";
	for (i = 0; i < cnt; i = i + 1)
		got = strcat(got, ftos(frameforname(mi, argv(i))), " ");

	cnt = tokenize(want);
	string wantlist = "";
	for (i = 0; i < cnt; i = i + 1)
		wantlist = strcat(wantlist, argv(i), " ");

	if (got != wantlist)
	{
		print(sprintf("[tentacletest] BAD anchor indices\n  got  %s\n  want %s\n",
		              got, wantlist));
		bad = bad + 1;
	}

	// Reachability from the pit, forward edges only.  Repeated relaxation rather
	// than a proper search because the graph is 14 nodes wide and this runs once.
	float reach = 0;
	float seen  = 0;
	string mark = "";
	for (i = 0; i < TENT_NODES; i = i + 1)
		mark = strcat(mark, (i == 8) ? "1" : "0");	// node 9 = the pit

	float pass = 0;
	while (pass < TENT_NODES)
	{
		float s;
		for (s = 0; s < TSEQ_COUNT; s = s + 1)
		{
			float en = Tent_Entry(s);
			float ex = Tent_Exit(s);
			if (en >= 1 && ex >= 1)
			if (str2chr(mark, en - 1) == '1' && str2chr(mark, ex - 1) == '0')
				mark = strcat(substring(mark, 0, ex - 1), "1",
				              substring(mark, ex, -1));
		}
		pass = pass + 1;
	}
	for (i = 0; i < TENT_NODES; i = i + 1)
		if (str2chr(mark, i) == '1')
			reach = reach + 1;

	// MEASURED 14/14 on every copy of the rig on this machine, which is a better
	// answer than the header's reasoning predicted and worth writing down: a
	// nodeflags=1 link is REVERSIBLE, not reverse-only, so every node including
	// the four reared ones has a forward way in.  Forward-only costs nothing in
	// reachability; it costs the way BACK out, which is what tentacle_cut counts.
	seen = 0;
	for (i = 0; i < TSEQ_COUNT; i = i + 1)
		if (Tent_NodeFlags(i))
			seen = seen + 1;

	// PATCH 155: prove the walk can actually go BACKWARDS, here and now, instead
	// of waiting for a descent to happen inside the runtime test window (it does
	// not — an eight second window is all ascent, and revs= reported 0 while the
	// feature worked).  Every ordered pair is walked; revpairs counts those that
	// resolve to a reversed link.
	//
	// Then the three descents Patch 154 had to cut, by name.  These are the whole
	// point of the extension, so they are asserted individually rather than being
	// left to a total that could be satisfied by any other pair.
	// The counters are saved and restored across the whole probe: Tent_NextSeq
	// bumps tent_dbg_revs/tent_dbg_cuts as a side effect, and 2809 synthetic
	// walks would swamp the runtime figures the phase-2 report exists to show.
	// The first version of this test reported revs=1262 for three real
	// reversals, which is worse than reporting nothing.
	float save_revs = tent_dbg_revs;
	float save_cuts = tent_dbg_cuts;
	entity probe = spawn();
	float revpairs = 0;
	float a, b;
	for (a = 0; a < TSEQ_COUNT; a = a + 1)
		for (b = 0; b < TSEQ_COUNT; b = b + 1)
		{
			probe.tent_dir = 1;
			probe.ai_seq   = a;
			Tent_NextSeq(probe, b);
			if (tent_seq_dir < 0)
				revpairs = revpairs + 1;
		}

	probe.tent_dir = 1;
	probe.ai_seq = TSEQ_LEV2_IDLE;	Tent_NextSeq(probe, TSEQ_LEV1_IDLE);
	float d21 = tent_seq_dir;
	probe.tent_dir = 1;
	probe.ai_seq = TSEQ_LEV3_IDLE;	Tent_NextSeq(probe, TSEQ_LEV2_IDLE);
	float d32 = tent_seq_dir;
	probe.tent_dir = 1;
	probe.ai_seq = TSEQ_LEV1_IDLE;	Tent_NextSeq(probe, TSEQ_PIT_IDLE);
	float d1p = tent_seq_dir;
	remove(probe);
	tent_dbg_revs = save_revs;
	tent_dbg_cuts = save_cuts;

	if (d21 >= 0 || d32 >= 0 || d1p >= 0)
	{
		print(sprintf("[tentacletest] BAD descents not reversed: L2>L1=%g L3>L2=%g L1>pit=%g\n",
		              d21, d32, d1p));
		bad = bad + 1;
	}
	if (revpairs <= 0)
	{
		print("[tentacletest] BAD no reversible route anywhere in the graph\n");
		bad = bad + 1;
	}

	// The reachability figure is still forward-only on purpose: it is the
	// pessimistic bound, and it already read 14/14 before reverse links existed.
	print(sprintf("[tentacletest] %g seqs, %g/%g nodes fwd-reachable, %g reversible links, %g reversed routes, BAD=%g\n",
	              n, reach, TENT_NODES, seen, revpairs, bad));

	// PHASE 1's payload: one synthetic world noise, placed where it will produce
	// a known answer rather than an arbitrary one.  400 units up puts it in
	// Level() band 1 (216..408 is band 1, so 400 is the top of it) and 200 units
	// along the tentacle's own initial facing puts it inside the sweep arc, which
	// together should mean "climb to Lev1 and strike" — the response that
	// exercises the most of this file.
	//
	// Written straight into the record rather than through AI_HeardNoise because
	// that walks the monster chain to wake real AI monsters, and a test noise
	// should not also alert every houndeye on the map.
	entity t = find(world, classname, "monster_tentacle");
	if (!t)
	{
		print("[tentacletest] no monster_tentacle placed; graph checks only\n");
		tent_selftest_phase = 2;
		return;
	}

	makevectors('0 1 0' * t.tent_initialyaw);
	tent_selftest_noise  = t.origin + v_forward * 200 + '0 0 400';
	tent_selftest_radius = 1024;
	AI_WorldSoundRecord(tent_selftest_noise, tent_selftest_radius, SND_WORLD);

	// AND A TARGET TO HIT.  The damage is the one thing about this monster that a
	// graph check cannot reach: it lands from an animation event, through
	// findradius and W_ApplyDamage, and every one of those is a place it could
	// silently do nothing.  So park a stand-in where the Lev1 strike will land —
	// the default tap radius out along the facing, at Lev1 height — and read its
	// health back in phase 2.
	//
	// DAMAGE_YES and FL_MONSTER because that is what W_CanDamageTarget wants to
	// see; a bare edict is refused and would report a false negative.  Same
	// stand-in shape BigMomma_SelfTest uses for the stage gate.
	entity dummy = spawn();
	dummy.classname  = "tentacle_selftest_target";
	dummy.solid      = SOLID_BBOX;
	dummy.movetype   = MOVETYPE_NONE;
	dummy.takedamage = DAMAGE_YES;
	dummy.health     = 1000;
	dummy.max_health = 1000;
	dummy.flags      = dummy.flags | FL_MONSTER;
	setsize(dummy, '-16 -16 -16', '16 16 16');
	setorigin(dummy, t.origin + v_forward * 336 + '0 0 256');

	if (cvar("sv_ai_debug"))
		dprint(sprintf("[tentacletest] noise at %v, target at %v near \"%s\"\n",
		               ai_worldsnd_pos, dummy.origin, t.targetname));
};
