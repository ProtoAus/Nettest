// server/monsters/mon_barnacle.qc
// ----------------------------------------------------------------------------
// monster_barnacle  —  183 placements.
//
// A ceiling hazard, not a fighter: it hangs, drops a tongue, and eats whatever
// walks underneath.  Three things make it unlike every other class so far.
//
// IT HAS NO ATTACK EVENTS.  Every other monster in this programme takes its
// damage timing from the model — the grunt's three burst codes, the houndeye's
// thump at 2.36 s, the turret's muzzleflashes.  barnacle.mdl's attack1 carries
// NONE, so the tongue has to be driven from QC.  That is why the damage lives in
// the per-tick class hook below rather than in an .ai_event handler.
//
// IT IS THE ONLY CLASS THAT MUST NOT DROP TO THE FLOOR.  AIMODE_STATIC skips
// droptofloor entirely, which is the specific bug that mode was built to prevent
// back in W1c: a ceiling barnacle placed 200 units up would otherwise land on the
// ground and hang its tongue into the floor.
//
// models/barnacle.mdl (7 sequences, 1 bone controller), read out of the file:
//   [0] idle1 act 1 61f@15   [1] idle2 act 1 (two code-1 events)
//   [2] idle3 act 1 LOOP     [3] flinch_sm act 26
//   [4] attack1 act 0 (!) 51f@30 LOOP   <- the ONLY untagged sequence
//   [5] chewcycle act 35 = ACT_EAT LOOP
//   [6] death act 36 101f@15, four code-2 events
//
// The plan recorded this model as having "no activities"; measuring it showed the
// opposite — everything except attack1 is tagged, so only that one sequence needs
// AI_SetSequenceNamed and the rest resolve normally.  ACT_BARNACLE_HIT/PULL/
// CHOMP/CHEW (40-43) are the VICTIM's activities, played by whatever is being
// eaten, and are not in this model at all.
//
// HONEST LIMITATION: the victim is not lifted.  The tongue IS drawn now - that
// half of this note stopped being true when the W1a bone-controller patch landed
// and Barnacle_Tick started writing .bonecontrol1 - but hauling a player upward
// means hijacking their movement, which is a lot of invasive code for something
// that would fight prediction the whole way.  What is implemented is the part
// that matters for play: standing under a barnacle hurts, continuously, the
// tongue reaches down to whatever floor is actually beneath it, and the thing
// visibly chews while it happens.
// ----------------------------------------------------------------------------

// How far down it can reach, and this number is A HARD WIRE LIMIT rather than a
// taste call - do not raise it.  Bone controllers cross the network as a short
// scaled by ES_BONECONTROL_SCALE = 64 (engine/common/protocol.h:1298) and are
// clamped to that on send (engine/server/sv_ents.c:3654), so the largest
// magnitude that can be transmitted at all is 32768/64 = 512 units.  Half-Life
// traces 2048 (barnacle.cpp:400) and the model's own controller range goes to
// -1024, but neither of those can be reached from here: a barnacle hung more
// than 512 units above its floor will silently clamp, and lifting that needs a
// protocol change, not a QC one.
const float BARN_TONGUE_MAX  = 512;

// THE TONGUE IS ALREADY IN THE ANIMATION, and this is the part that was missing.
//
// barnacle.mdl's sequences carry some tongue baked in, and the controller can
// only make it LONGER (range -1024..0, where 0 is the baked length).  Half-Life
// tracks that in m_flTongueAdj and SUBTRACTS it so the DRAWN TIP lands on the
// measured altitude rather than 100 units past it:
//     SetBoneController(0, -(m_flAltitude + m_flTongueAdj))   barnacle.cpp:314
// with m_flTongueAdj = -100 at rest (:121, :251) and -20 while chomping (:278),
// the sequence-specific amounts for this exact model.  Without these the floor
// trace below would just trade "always 64 units" for "always ~100 too long".
//
// A consequence worth knowing rather than treating as a bug: with the idle
// sequence holding ~100 units, a barnacle closer than that to its floor cannot
// draw a shorter tongue - the subtraction goes negative and clamps at 0.  HL
// clamps in exactly the same place and for the same reason (SetController pins
// to the controller's own start..end), so this matches rather than approximates.
const float BARN_TONGUE_BAKED_IDLE   = 100;
const float BARN_TONGUE_BAKED_ATTACK = 20;

// ----------------------------------------------------------------------------
//  THE GRAB.  This is the half the header used to call an "HONEST LIMITATION".
// ----------------------------------------------------------------------------
//  What was here before detected a victim, drew the tongue at it and applied
//  10 damage every half second.  What it never did was the defining behaviour:
//  lock the victim in place, haul it up into the mouth, and eat it.  That is
//  the reported "nothing happens when you touch the tongue" — you were taking
//  damage, but nothing GRABBED you.
//
//  The old reason for not doing it was that "hauling a player upward means
//  hijacking their movement... which would fight prediction the whole way".
//  That is not true on this codebase's own terms: the mod already owns a
//  prediction-SAFE freeze, `pm_movetype = PM_MOVETYPE_NONE`, which replicates
//  through PM_SF_MOVEMENT and is restored on every reconcile replay so the
//  client stops on the same frame the server does (sv_trigger_camera.qc uses
//  exactly this for CAMF_FREEZE_PLAYER).  Paired with setorigin +
//  PM_SyncPredictionProxy the lift is smooth rather than a fight.
//
//  Half-Life's numbers, from barnacle.cpp:
//     BARNACLE_PULL_SPEED       8    (:26) — units per think, both directions
//     BARNACLE_KILL_VICTIM_DELAY 5   (:27) — the constant, but note the code
//                                     at :196 actually arms TEN seconds, and
//                                     :289 parks it at -1 while lifting.
//                                     The code wins; the #define is vestigial.
//  Arrival test, barnacle.cpp:187: the prey is "in position" once
//  |barnacle.z - (victim.z + view_ofs.z - 8)| < BARNACLE_BODY_HEIGHT.
//
//  PLAYER ONLY, deliberately.  Lifting an NPC needs the victim-side activity
//  set (ACT_BARNACLE_HIT/PULL/CHOMP/CHEW) and an MS_PRONE state that suspends
//  its schedule — both declared in sv_ai_defs.qc and both still unused — and
//  that is a much wider change across the AI spine for behaviour nobody is
//  looking at.  An NPC in the column keeps taking the chewing damage it always
//  did and simply dies standing up.
// ----------------------------------------------------------------------------
const float BARN_PULL_SPEED_V   = 8;    // barnacle.cpp:26
const float BARN_BODY_HEIGHT    = 44;   // barnacle.cpp's BARNACLE_BODY_HEIGHT
const float BARN_CHEW_DELAY     = 10;   // barnacle.cpp:196 — the real value

// On the VICTIM.  Kept on the victim rather than the barnacle so a release can
// always be driven from either end without a search.
.entity barn_holder;            // the barnacle currently holding this entity
.float  barn_saved_pm_movetype; // what to give back on release
.float  barn_killtime;          // when the chewing bite lands; 0 = still lifting

// Tongue lowers this far per think, and SNAPS up.  barnacle.cpp:26
// (BARNACLE_PULL_SPEED) and :297-307: the asymmetry is deliberate there too -
// reaching down is a movement, reeling in a catch is not.
const float BARN_PULL_SPEED  = 8;

const float BARN_BITE_GAP    = 0.5;	// seconds between damage ticks
const float BARN_HULL_R      = 12;	// tongue column radius

// Current tongue length in units below the barnacle - Half-Life's m_flAltitude.
// It is STATE rather than a per-tick derivation because the tongue eases down,
// and it is seeded at spawn (Barnacle_ClassInit) so that a barnacle nobody has
// walked up to yet still hangs at the right length: AI_Think's dormancy
// early-return (sv_ai_core.qc:1947-1948) happens BEFORE .ai_tick is called
// (:1969), so a sleeping barnacle's tick never runs and anything computed only
// there would be stuck at the baked minimum until a player came within 1024
// units, then visibly grow.
.float barn_altitude;

// TRUE once the tongue has finished reaching its resting length.  HL will not
// let a barnacle grab with a tongue still on its way down (barnacle.cpp:270).
.float barn_extended;

// Rate limit for the `sv_ai_debug 2` grab-refusal line.  Per barnacle, because
// two of them hanging side by side over the same walkway is the normal case and
// one shared limiter would hide whichever lost the race.
.float barn_dbg_next;

// barnacle.cpp:192-275, :342-343.  Two of these were unreachable:
//
//   bcl_bite3 - Valve's comment on the precache line calls it "just got food to
//   mouth" - was precached by this file and played by nothing.  It is the ONE
//   sound that tells a player their teammate has been grabbed, and it fires on
//   acquisition, not on the chew.
//
//   bcl_alert2 - "happy, lifting food up" - was not even precached.
//
// There is no pain family and that is not an omission: CBarnacle has no
// PainSound at all.  It has no eyes and no voice; it chews.
const string SND_BARN_CHEW  = "barnacle/bcl_chew1.wav barnacle/bcl_chew2.wav barnacle/bcl_chew3.wav";
const string SND_BARN_DIE   = "barnacle/bcl_die1.wav barnacle/bcl_die3.wav";
const string SND_BARN_BITE  = "barnacle/bcl_bite3.wav";
const string SND_BARN_ALERT = "barnacle/bcl_alert2.wav";

void() Barnacle_Precache =
{
	precache_model("models/barnacle.mdl");
	AI_SndPrecache(SND_BARN_CHEW);
	AI_SndPrecache(SND_BARN_DIE);
	precache_sound(SND_BARN_BITE);
	precache_sound(SND_BARN_ALERT);
};

// How far it is to the floor, which is what a barnacle's resting tongue length
// actually is.
//
// THIS IS THE BUG THE TONGUE HAD: there was no such trace, and the resting
// length was the constant 64 regardless of how high the thing was bolted.  The
// distance was even being measured already - Barnacle_FindVictim below does a
// downward tracebox and reads trace_ent while DISCARDING trace_endpos, so the
// engine computed the answer and the QC threw it away.
//
// Deliberately a SEPARATE trace from the victim search, and deliberately
// MOVE_NOMONSTERS.  Half-Life splits the same two jobs the same way
// (barnacle.cpp:400 traces the architecture with ignore_monsters for the length;
// :407-425 does an entirely separate box query for the victim), and the reason
// shows up immediately if they are merged: the resting length is a property of
// the ROOM, so sharing one MOVE_NORMAL trace would make a barnacle reel its
// tongue up whenever a corpse or a crate happened to be lying under it.
//
// A line rather than a box, again matching HL - a box would catch a doorframe
// beside the column and report the floor as nearer than it is.  Width is what
// the VICTIM test needs, not what the length test needs.
float(entity m) Barnacle_FloorReach =
{
	traceline(m.origin, m.origin - '0 0 1' * BARN_TONGUE_MAX, MOVE_NOMONSTERS, m);
	return m.origin_z - trace_endpos_z;
};

// Is `e` edible, ignoring where it is?
float(entity m, entity e) Barnacle_Edible =
{
	if (!e || e == world || e == m)
		return FALSE;
	if (e.health <= 0)
		return FALSE;
	if (e.takedamage != DAMAGE_YES && e.classname != "player")
		return FALSE;
	// A barnacle eats CREATURES.  takedamage alone is far too wide a net: it
	// also admits func_breakable, shootable func_door, func_button,
	// func_rot_button, momentary_door, func_pushable, cycler, func_vehicle —
	// and monster CORPSES, which AI_Died deliberately leaves with a positive
	// gib-pool health (see sv_weapons.qc's note).  Without this test a barnacle
	// hung over a crate or a door spends its whole life chewing brushwork while
	// a player stands underneath untouched.
	if (!(e.flags & (FL_MONSTER | FL_CLIENT)))
		return FALSE;
	// Never eat its own kind, and never eat another barnacle's meal.
	if (e.classname == m.classname)
		return FALSE;
	if (e.barn_holder && e.barn_holder != m)
		return FALSE;
	return TRUE;
};

// What is hanging in the tongue's column right now, or world.
//
// THIS USED TO BE A DOWNWARD tracebox AND THAT IS WHY THE TONGUE CAUGHT NOTHING.
//
// The box asked for was ('-12 -12 0' .. '12 12 0'), and on a GoldSrc BSP there is
// no such hull to trace with.  Q1BSP_ChooseHull (q1bsp.c:1554) picks by width: 24
// is over the 3-unit point threshold and under 32.1, so every one of those traces
// silently became the 32x32x56 PLAYER hull, and :1570 then re-anchors it at the
// requested MIN corner — which for a box asking for zero height means the hull
// gets shoved 36 units down and 20 units UP, straight into the ceiling the
// barnacle is bolted to.  The trace started solid, trace_ent came back as the
// world, and the search returned "nothing here" for the entire life of the map.
// `sv_compatiblehulls` is 1 by default (sv_main.c:210), so World_Move never even
// tries a best-fit.
//
// So the column is tested arithmetically instead, against the two entity lists
// that can possibly contain prey.  That is exact at any radius, needs no hull
// that the BSP does not have, and is cheap: this walks players plus monsters, not
// the edict table.  The line-of-sight check is a POINT trace, which is the one
// shape a Q1 BSP always has exactly.
//
// It also lifts the old PLAYER-ONLY restriction, which was never in Half-Life:
// CBarnacle::TongueTouchEnt tests FL_MONSTER|FL_CLIENT (barnacle.cpp:407-425) and
// barnacles eat headcrabs and grunts in the campaign as readily as they eat you.
entity(entity m) Barnacle_FindVictim =
{
	// How far down the tongue can reach before the ARCHITECTURE stops it.  A
	// barnacle over a catwalk must not reach through the catwalk to the floor
	// below, and this is the same MOVE_NOMONSTERS line the resting length uses.
	float reach = bound(0, Barnacle_FloorReach(m), BARN_TONGUE_MAX);

	entity best  = world;
	float  bestz = -1;			// the HIGHEST candidate wins: it is nearest the mouth

	float pass;
	for (pass = 0; pass < 2; pass = pass + 1)
	{
		entity e = pass ? monster_chain_head : player_chain_head;
		while (e)
		{
			entity nxt = pass ? e.monster_chain_next : e.player_chain_next;

			if (Barnacle_Edible(m, e))
			{
				// Horizontal overlap of the entity's own footprint with the tongue
				// column, not a centre-point test: a player standing with one
				// shoulder under a barnacle is caught in Half-Life and has to be
				// caught here.
				float dx = fabs(e.origin_x - m.origin_x) - (e.maxs_x + BARN_HULL_R);
				float dy = fabs(e.origin_y - m.origin_y) - (e.maxs_y + BARN_HULL_R);
				if (dx < 0 && dy < 0)
				{
					// Below the barnacle, and no further down than the tongue goes.
					float top  = e.origin_z + e.maxs_z;
					float drop = m.origin_z - top;
					if (drop > 0 && drop <= reach)
					{
						// Clear line from the mouth down to the top of the victim.
						traceline(m.origin, [e.origin_x, e.origin_y, top],
						          MOVE_NOMONSTERS, m);
						if (trace_fraction == 1)
							if (top > bestz)
							{
								bestz = top;
								best  = e;
							}
					}
				}
			}

			e = nxt;
		}
	}

	return best;
};

// Let go.  Driven from BOTH ends — the victim dying, and the barnacle dying —
// because Half-Life does the same (CBarnacle::Killed calls
// pVictim->BarnacleVictimReleased at barnacle.cpp:334) and because a player left
// frozen after either event is stuck for the rest of the map.
//
// NOTE the correction to a common misreading: CBasePlayer inherits
// CBaseMonster::MyMonsterPointer and does NOT return NULL, so HL's release path
// really does reach a live grabbed player.  This must handle one, not assume the
// victim is already dead.
void(entity v) Barnacle_ReleaseVictim =
{
	if (!v || v == world)
		return;
	if (v.classname == "player")
	{
		// 4 rather than PM_MOVETYPE_NONE: the PM_MOVETYPE_* names are plain
		// globals in shared/sh_pmove.qc, which compiles long after this file, and
		// QC forward-declares functions but not constants.  Same reason
		// sv_breakable.qc spells its noclip test 5 and 4.
		if (v.pm_movetype == 4)
			v.pm_movetype = v.barn_saved_pm_movetype;
		v.velocity = '0 0 0';
		PM_SyncPredictionProxy(v);
	}
	else if (v.flags & FL_MONSTER)
	{
		// Hand the body back to its own physics and its own schedule.  The saved
		// movetype is stashed in the same field the player path uses, which is why
		// that field is named for what it holds rather than for pm_movetype.
		if (v.barn_saved_pm_movetype)
			v.movetype = v.barn_saved_pm_movetype;
		v.velocity  = '0 0 0';
		v.ai_stuck  = 0;
		// Un-park the think.  Same mechanism (and the same restore) as
		// AIDbg_Freeze, which is the only other thing in the tree that suspends a
		// monster without removing it.
		if (v.health > 0 && v.nextthink > time + 3600)
			v.nextthink = time + 0.05 + random() * 0.1;
		setorigin(v, v.origin);
	}
	v.barn_holder          = world;
	v.barn_killtime        = 0;
	v.barn_saved_pm_movetype = 0;
};

// Lock a victim into the tongue.  Returns TRUE if it took hold.
//
// TWO KINDS OF VICTIM, and they are frozen by different mechanisms because they
// are moved by different code.  A player is moved by the shared pmove on BOTH
// sides, so the freeze has to be the replicated pm_movetype one or the client
// walks out of the tongue and gets yanked back once a tick.  A monster is moved
// only by its own think on the server, so parking that think is both sufficient
// and exact — the same lever AIDbg_Freeze pulls.
//
// Half-Life freezes both the same way (MOVETYPE_FLY plus MONSTERSTATE_PRONE); the
// split here is a consequence of prediction, not a divergence in behaviour.
// Every `return FALSE` below is a refusal that used to be SILENT and, worse, used
// to be permanent (see the latch note in Barnacle_Tick).  It is retried now, but a
// barnacle that refuses on every tick forever still looks identical to one that
// never sees anything, so `sv_ai_debug 2` names which gate said no.  Rate-limited
// to one line a second per barnacle: this is called ten times a second.
void(entity m, entity v, string why) Barnacle_RefuseDbg =
{
	if (cvar("sv_ai_debug") < 2)
		return;
	if (time < m.barn_dbg_next)
		return;
	m.barn_dbg_next = time + 1;
	dprint(sprintf("[barnacle] at %v: refused \"%s\" (%s)\n", m.origin, v.classname, why));
};

float(entity m, entity v) Barnacle_GrabVictim =
{
	if (v.barn_holder)
	{
		Barnacle_RefuseDbg(m, v, "already held by another barnacle");
		return FALSE;               // already somebody's meal
	}

	if (v.classname == "player")
	{
		// Only an ordinary walking player is edible.  This also covers the frozen
		// cutscene player, the spectator and the noclipping admin, all of which set
		// pm_movetype to something other than NORMAL.
		if (v.pm_movetype != 0)     // PM_MOVETYPE_NORMAL
		{
			Barnacle_RefuseDbg(m, v, sprintf("player pm_movetype=%g, not NORMAL", v.pm_movetype));
			return FALSE;
		}

		v.barn_saved_pm_movetype = v.pm_movetype;
		v.pm_movetype            = 4;   // PM_MOVETYPE_NONE — the prediction-safe freeze
		PM_SyncPredictionProxy(v);
	}
	else if (v.flags & FL_MONSTER)
	{
		// A monster already under script control is somebody else's actor; taking
		// it would strand the script waiting for a mark it can no longer reach.
		if (v.ai_script)
		{
			Barnacle_RefuseDbg(m, v, "monster is running a scripted_sequence");
			return FALSE;
		}
		if (v.ai_movemode == AIMODE_STATIC)
		{
			Barnacle_RefuseDbg(m, v, "monster is AIMODE_STATIC (bolted down)");
			return FALSE;           // bolted down (turret, tentacle) — nothing to lift
		}

		// MOVETYPE_NONE rather than FLY: the lift is done with setorigin from
		// Barnacle_PullVictim, so the victim must not also be integrating its own
		// velocity or falling out of the tongue between ticks.
		v.barn_saved_pm_movetype = v.movetype;
		v.movetype               = MOVETYPE_NONE;
		v.flags                  = v.flags - (v.flags & FL_ONGROUND);
		v.nextthink              = time + 86400;   // parked; restored on release
	}
	else
	{
		Barnacle_RefuseDbg(m, v, "neither a player nor FL_MONSTER");
		return FALSE;
	}

	v.barn_holder   = m;
	v.velocity      = '0 0 0';
	v.barn_killtime = 0;            // still being lifted; armed on arrival
	return TRUE;
};

// Haul the held victim up, and eat it when it arrives.
void(entity m, entity v) Barnacle_PullVictim =
{
	if (v.barn_killtime > 0)
	{
		// Dangling in the mouth.  barnacle.cpp:213 — the killing bite.
		if (time > v.barn_killtime)
		{
			AI_Sound(m, CHAN_WEAPON, SND_BARN_BITE, 1, ATTN_NORM);
			entity held = v;
			// Release BEFORE the kill so the corpse is not left frozen, and so
			// a gib does not try to hand movement back to a removed entity.
			Barnacle_ReleaseVictim(v);
			sv_dmg_bits = DMG_CLUB;     // eaten, not shot — gib by intent
			W_ApplyDamage(m, held, held.health + 100);
			m.ai_victim = world;
		}
		return;
	}

	// barnacle.cpp:176-204.  Slide the victim onto the barnacle's own column and
	// lift by BARNACLE_PULL_SPEED per think.
	vector np = v.origin;
	np_x = m.origin_x;
	np_y = m.origin_y;
	np_z = np_z + BARN_PULL_SPEED_V;

	// Arrival: the victim's eye point, less 8, is within a body height of the
	// barnacle (barnacle.cpp:187).
	float gap = m.origin_z - (np_z + v.view_ofs_z - 8);
	if (gap < 0)
		gap = 0 - gap;
	if (gap < BARN_BODY_HEIGHT)
	{
		AI_Sound(m, CHAN_WEAPON, SND_BARN_BITE, 1, ATTN_NORM);
		v.barn_killtime = time + BARN_CHEW_DELAY;
		AI_SetActivity(m, ACT_EAT);
	}

	setorigin(v, np);
	if (v.classname == "player")
		PM_SyncPredictionProxy(v);
};

// The per-tick class hook (.ai_tick).  This monster is the reason that hook
// exists: its damage cannot come from an anim event because attack1 carries none,
// and it cannot come from ai_checkattack because that only fires when an attack
// condition is already set - which needs a non-zero attack range, which a barnacle
// deliberately does not have.  Measured before the hook existed: the tongue check
// ran ZERO times while the class oscillated between two schedules 295 times.
void() Barnacle_Tick =
{
	// ALREADY HOLDING SOMEBODY?  Then the column search is irrelevant — the
	// victim has been lifted off the floor and out of it.  HL splits the same
	// way: BarnacleThink only calls TongueTouchEnt when m_hEnemy is NULL
	// (barnacle.cpp:260).
	entity held = self.ai_victim;
	if (held != world && held.barn_holder == self)
	{
		if (held.health <= 0 || self.ai_state == MS_DEAD)
		{
			Barnacle_ReleaseVictim(held);
			self.ai_victim = world;
		}
		else
		{
			// Tongue is AT the catch while it hauls.
			self.barn_altitude = bound(0, self.origin_z - (held.origin_z + held.view_ofs_z),
			                           BARN_TONGUE_MAX);
			self.barn_extended = FALSE;
			self.bonecontrol1  = 0 - bound(0, self.barn_altitude - BARN_TONGUE_BAKED_ATTACK,
			                               BARN_TONGUE_MAX);
			self.ai_cond = self.ai_cond | COND_SEE_ENEMY;
			Barnacle_PullVictim(self, held);
			return;
		}
	}

	entity v = Barnacle_FindVictim(self);

	// A tongue still on its way down cannot catch anything (barnacle.cpp:270).
	// The gate is on ACQUIRING, not on holding: something already caught stays
	// caught, or the barnacle would drop its meal on the very next tick, since
	// taking a victim clears the extended latch (it is holding, not reaching).
	if (v != world && v != self.ai_victim && !self.barn_extended)
		v = world;

	// THE GRAB.  Attempted on EVERY tick the column is occupied by something we are
	// not already holding - not only on the tick the occupant changes.
	//
	// >>> THIS IS WHY THE TONGUE NEVER PICKED ANYONE UP. <<<
	//
	// The attempt used to be guarded by the bare edge test `self.ai_victim != v`,
	// and `self.ai_victim = v` below runs whether or not the grab SUCCEEDED.  So a
	// single refusal was permanent: ai_victim was left pointing at a victim whose
	// barn_holder had never been set, the next tick found v == ai_victim, skipped
	// the attempt, and every tick after that did the same.  Nothing ever reset it,
	// because the reset condition was the victim changing and the victim was
	// standing right there.
	//
	// What made it survive three passes is that everything ELSE about the barnacle
	// keeps working in that state.  The chew damage at the bottom of this function
	// needs only `v`, not a hold; so does the tongue length, so does the bite
	// sound, so does COND_SEE_ENEMY.  The barnacle bites, chews, drips its tongue
	// onto your head and hurts you - it just never lifts you, which is exactly the
	// report.  Every previous fix looked at the parts that were visibly working.
	//
	// Every reason Barnacle_GrabVictim can refuse is TRANSIENT: a player frozen in
	// a cutscene or on a mortar, a monster mid-scripted_sequence, prey another
	// barnacle got to first.  All of them clear on their own, so the correct
	// response is to try again on the next tick rather than to give up for the rest
	// of the map.
	//
	// The SOUND stays on the edge - Barnacle_Tick runs ten times a second and a
	// bite per tick would be a drone rather than an event.
	float already_held = FALSE;
	if (v != world)
	if (self.ai_victim == v)
	if (v.barn_holder == self)
		already_held = TRUE;

	if (v != world && !already_held)
	{
		if (self.ai_victim != v)
		if (!self.gag)
		{
			AI_Sound(self, CHAN_WEAPON, SND_BARN_BITE,  1, ATTN_NORM);
			AI_Sound(self, CHAN_VOICE,  SND_BARN_ALERT, 1, ATTN_NORM);
		}
		// ...and TAKE HOLD, which is what was missing.  barnacle.cpp:282 sets
		// the victim MOVETYPE_FLY at this point so the world stops carrying it;
		// our equivalent is the prediction-safe pm_movetype freeze.
		if (Barnacle_GrabVictim(self, v))
		{
			self.ai_victim = v;
			return;
		}
	}

	self.ai_victim = v;

	// THE TONGUE, now that bone controllers reach the client (W1a, Patch 125).
	//
	// barnacle.mdl's single controller is type 0x0002 - a TRANSLATION, not a
	// rotation - with a range of -1024..0, so the value is in world units and
	// NEGATIVE is further down.  It is not degrees and it is not normalised; the
	// engine passes it straight through (gl_hlmdl.c:990, the non-rotation branch).
	//
	// Three states, mirroring barnacle.cpp:290-314:
	//   * holding something  -> the tongue is AT the catch, and snaps there.  HL
	//     measures to the victim's EYES rather than its feet (:291), which is the
	//     difference between a tongue that ends at a player's head and one that
	//     ends at the floor they are standing on.
	//   * reaching down      -> eases toward the floor at BARN_PULL_SPEED per
	//     think.  Only relevant after a catch is released, because the resting
	//     length is seeded at spawn; a barnacle does not spend its first five
	//     seconds unrolling.
	//   * at rest            -> pinned to the floor distance, extended latch set.
	float want;
	float baked;

	if (v)
	{
		want  = self.origin_z - (v.origin_z + v.view_ofs_z);
		baked = BARN_TONGUE_BAKED_ATTACK;
		self.barn_altitude = bound(0, want, BARN_TONGUE_MAX);
		self.barn_extended = FALSE;	// it is holding, not reaching
	}
	else
	{
		want  = bound(0, Barnacle_FloorReach(self), BARN_TONGUE_MAX);
		baked = BARN_TONGUE_BAKED_IDLE;
		if (self.barn_altitude < want)
		{
			self.barn_altitude = self.barn_altitude + BARN_PULL_SPEED;
			if (self.barn_altitude >= want)
			{
				self.barn_altitude = want;
				self.barn_extended = TRUE;
			}
			else
				self.barn_extended = FALSE;
		}
		else
		{
			self.barn_altitude = want;	// snaps up; see BARN_PULL_SPEED
			self.barn_extended = TRUE;
		}
	}

	// The subtraction is the whole point of BARN_TONGUE_BAKED_*: bonecontrol1
	// asks for tongue BEYOND what the sequence already draws, so handing it the
	// raw altitude would hang the tip a baked-length past the floor.
	self.bonecontrol1 = 0 - bound(0, self.barn_altitude - baked, BARN_TONGUE_MAX);

	if (!v)
		return;			// nothing in the column; the idle schedule handles it

	// A barnacle does not care about line of sight, hearing or range: if you are
	// in the column, you are food.  It has no eyes, so it never consults the
	// sighting path at all - which is exactly why the victim lives in its own
	// field rather than in ai_enemy.
	//
	// COND_SEE_ENEMY is asserted purely so the idle schedule's interrupt mask can
	// react on the same tick; nothing here reads it as "I can see something".
	self.ai_cond = self.ai_cond | COND_SEE_ENEMY;

	if (time < self.ai_nextattack)
		return;
	self.ai_nextattack = time + BARN_BITE_GAP;

	float d = cvar("sv_ai_barnacle_dmg");
	if (d <= 0)
		d = 10;
	W_ApplyDamage(self, v, d);

	AI_SndPlay(self, CHAN_WEAPON, SND_BARN_CHEW);
};

float() Barnacle_SelectSched =
{
	if (self.ai_state == MS_DEAD)
		return SCHED_NONE;

	if (self.ai_victim)
		return SCHED_BARNACLE_CHOMP;
	return SCHED_BARNACLE_IDLE;
};

// Death.  The ONLY reason this exists is the last line: a corpse's tongue has to
// go away, and there is nowhere else to do it from.  AI_Think returns at
// sv_ai_core.qc:1933 once the state is MS_DEAD, before .ai_tick is ever reached
// (:1969), so nothing the class runs per-tick can clear the controller and a dead
// barnacle would keep its last tongue length hanging in the air forever.
// Half-Life zeroes it explicitly for the same reason (barnacle.cpp:347).
//
// The die sound is the default TASK_DIE behaviour this replaces
// (sv_ai_core.qc:1383-1384) and has to be repeated by hand: assigning .ai_death
// substitutes for that branch rather than adding to it.
void() Barnacle_Death =
{
	// DROP WHATEVER IT WAS EATING.  CBarnacle::Killed does this first
	// (barnacle.cpp:334, pVictim->BarnacleVictimReleased) and it is not optional
	// here: a player frozen in the tongue when the barnacle dies would otherwise
	// stay frozen, in mid-air, for the rest of the map.
	if (self.ai_victim != world && self.ai_victim.barn_holder == self)
		Barnacle_ReleaseVictim(self.ai_victim);
	self.ai_victim = world;

	AI_SndPlay(self, CHAN_VOICE, self.ai_snd_die);
	self.bonecontrol1  = 0;
	self.barn_altitude = 0;
	self.barn_extended = FALSE;
};

void(entity m) Barnacle_ClassInit =
{
	m.ai_class = CLASS_ALIEN_MONSTER;
	// Bolted to the ceiling with a tongue straight down: a forward cone means
	// nothing to it, and giving it one could only ever take prey away.
	m.ai_fov   = -1;

	// STATIC: bolted to the ceiling.  See the header — this is the class the mode
	// was designed around.
	m.ai_movemode = AIMODE_STATIC;

	// Both ranges zero: the generic ladder must never offer it an attack schedule.
	// Everything it does is driven by Barnacle_SelectSched instead.
	m.ai_melee_range = 0;
	m.ai_range_range = 0;
	m.ai_yaw_speed   = 0;			// it does not turn; it hangs

	m.ai_selectsched = Barnacle_SelectSched;
	m.ai_tick        = Barnacle_Tick;
	m.ai_death       = Barnacle_Death;
	m.ai_snd_die     = SND_BARN_DIE;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;

	// SEED THE TONGUE HERE, not on the first tick, because the first tick may
	// never come: a barnacle with no player within 1024 units is dormant and
	// .ai_tick is skipped entirely (sv_ai_core.qc:1947-1948 returns before
	// :1969).  Left to the tick alone, every barnacle across the room would hang
	// at the sequence's baked minimum and then visibly stretch as you approached.
	//
	// Safe at this point in the spawn: AI_Spawn's own comment (sv_ai_core.qc:2363)
	// records that Monster_Build has already set the model, hull and origin before
	// calling in, and this class is AIMODE_STATIC so nothing moves it afterwards.
	// The guard is for the case that is genuinely not ready - a barnacle whose
	// floor is a brush entity later in the entity lump - where 0 leaves it at the
	// baked length and the first awake tick corrects it, which is exactly the
	// pre-existing behaviour rather than a new failure.
	m.barn_altitude = bound(0, Barnacle_FloorReach(m), BARN_TONGUE_MAX);
	m.barn_extended = (m.barn_altitude > 0);
	m.bonecontrol1  = 0 - bound(0, m.barn_altitude - BARN_TONGUE_BAKED_IDLE, BARN_TONGUE_MAX);

	// `sv_ai_debug 2`: the one number that was wrong for this feature's whole
	// life, printed once per barnacle.  A tongue is not something a headless run
	// can look at, and the old constant-64 bug was invisible precisely because
	// every other signal about this monster was healthy - it hung, it traced, it
	// bit, it chewed.  ceil is the measured floor distance; ctrl is what actually
	// goes on the wire.  ceil varying between placements is the whole fix; a run
	// where every barnacle reports the same ceil is the bug come back.
	if (cvar("sv_ai_debug") >= 2)
		dprint(sprintf("[barnacle] at %v: ceil=%g ctrl=%g extended=%g%s\n",
		               m.origin, m.barn_altitude, m.bonecontrol1, m.barn_extended,
		               (m.barn_altitude >= BARN_TONGUE_MAX)
		                 ? "  (CLAMPED at the 512-unit wire limit)" : ""));
};

float() Barnacle_DefaultHealth
	= { float h = cvar("sv_ai_barnacle_health"); return (h > 0) ? h : 25; };
