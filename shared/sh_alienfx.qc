// ============================================================
//  shared/sh_alienfx.qc  -  creature attack visuals
//
//  THE WHOLE PARTICLE SET IS WEAPONS, IMPACTS AND WEATHER.  There was not one
//  alien- or creature-specific recipe in it, and the reason is structural
//  rather than an oversight per class: the SERVER never called pointparticles
//  or trailparticles once, and never set .traileffectnum on anything.  So every
//  creature attack in the game arrived as a bare model or sprite entity with no
//  effect around it, and the ones with no entity at all - the gargantua's stomp,
//  the alien slave's zap wind-up, the controller's hands - arrived as nothing.
//
//  ONE EVENT rather than one per creature.  Every one of these is the same shape
//  on the wire (a point, a direction, and which effect), so the kind picks both
//  the recipe and the dynamic light on the client and adding a creature effect
//  is a table row here plus an r_part block in particles/aliens.cfg.
//
//  Colours are READ OUT OF THE SPRITE FILES wherever the sprite exists, because
//  three of the five would otherwise have been wrong from memory - see the notes
//  on each kind below.  GoldSrc sprite texFormat: 0 normal, 1 additive,
//  2 index-alpha, 3 alpha-test.
// ============================================================

const float ALIENFX_SPIT_MUZZLE = 0;	// bullsquid / pitdrone / gonome, at the mouth
const float ALIENFX_SPIT_IMPACT = 1;	// ...and where the glob lands
const float ALIENFX_HORNET_FIRE = 2;	// alien grunt's arm
const float ALIENFX_ZAP_CHARGE  = 3;	// alien slave winding up (four per zap)
const float ALIENFX_ZAP_FIRE    = 4;	// ...and letting go
const float ALIENFX_CTRL_BALL   = 5;	// alien controller's hands
const float ALIENFX_GARG_STOMP  = 6;	// gargantua stomp, one per wave step
// The spore launcher's detonation.  It lives here rather than beside the grenade
// explosion because it is an ORGANIC burst, not ordnance: the spore is a living
// projectile and Opposing Force bursts it in green, with no fireball and no
// scorch.  W_SporeExplode used to call te_explosion, i.e. the stock Quake rocket
// fireball, which is what made it read as "an explosion effect I don't think is
// correct".  Reusing this event rather than minting a CSQC_EVENT_SPORE_EXPLODE
// also puts the recipe in particles/aliens.cfg, next to alien_spit_impact, which
// is the family it actually belongs to.
const float ALIENFX_SPORE_BURST = 7;	// spore launcher detonation
// The gauss's ricochet balls (ev_hldm.cpp:1016).  Second weapon effect on this
// event, and for the same reason as the spore burst: the wire shape it wants is
// exactly "a point, a direction, and which recipe", which is what this event is.
// The direction carries the SURFACE NORMAL, so the balls spray off the bounce
// the way Half-Life's do.
const float ALIENFX_GAUSS_BALLS = 8;	// gauss beam ricochet
// THE OTHER THREE GAUSS BALL EMISSIONS.  ev_hldm.cpp fires R_Sprite_Trail - the
// bouncing tempent - in FOUR places, not one, and only the reflect was ever wired
// up here.  (R_TempSprite, which sits beside each of them, is a STATIC glow flare
// that never moves; the beam's EndSprite already covers that half.)  Each kind is
// a separate row because the four differ in launch speed and in scatter width,
// and speed is per-kind on this event:
//
//   :1016  shallow reflect        3 balls   normal * 100   scatter +-50
//   :1121  PRIMARY hits a wall    8 balls   normal * 200   scatter +-50
//   :1081  punch-through entry    3 balls  -forward * 100  scatter +-50
//   :1096  punch-through exit     dmg*0.3  -forward *  40  scatter +-100
//
// The primary row is the one that matters and the one that was missing: it is the
// common case (every ordinary wall hit), it is the biggest spray of the four, and
// the branch it belongs to breaks out of the walk without emitting anything.  The
// old comment beside the reflect claimed a square-on hit deliberately got no
// balls; ev_hldm.cpp:1114 says the exact opposite in the SDK's own words -
// "slug doesn't punch through ever with primary fire, so leave a little glowy bit
// and make some balls".
const float ALIENFX_GAUSS_PRIMARY = 9;	// gauss primary, square-on wall hit
const float ALIENFX_GAUSS_PUNCH_IN  = 10;	// gauss charged shot, entry hole
const float ALIENFX_GAUSS_PUNCH_OUT = 11;	// ...and the far side of the wall

#ifdef SSQC

// dir may be '0 0 0' where the effect has no orientation (an impact puff).
//
// `mag` scales the recipe's own particle count.  It exists because the gauss's
// exit spray is the one emission in the game whose count is not a constant -
// ev_hldm.cpp:1096 passes (int)(flDamage * 0.3), up to 60 balls off a full charge -
// and a kind byte cannot carry a magnitude.  Everything else passes 1 through the
// three-arg wrapper below, so no existing call site changes.
void(float kind, vector pos, vector dir, float mag) AlienFX_MulticastMag =
{
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ALIEN_FX);
	WriteByte(MSG_MULTICAST, kind);
	WriteCoord(MSG_MULTICAST, pos_x);
	WriteCoord(MSG_MULTICAST, pos_y);
	WriteCoord(MSG_MULTICAST, pos_z);
	// Quantised to signed bytes exactly as W_ImpactEffectSend quantises its
	// normal: a unit vector costs 3 bytes instead of 12, and these fire on
	// animation events at up to ten a second per creature.
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_x * 127), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_y * 127), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_z * 127), 255));
	// Clamped to 1 at the bottom: a zero would silently emit nothing, which is
	// the failure this file's counters exist to make visible rather than hide.
	WriteByte(MSG_MULTICAST, bound(1, rint(mag), 255));
	multicast(pos, MULTICAST_PVS);
};

void(float kind, vector pos, vector dir) AlienFX_Multicast =
{
	AlienFX_MulticastMag(kind, pos, dir, 1);
};

// The muzzle-ish point for a creature effect: two thirds up the hull and pushed
// forward along the facing.  Deliberately the same construction AI_MuzzlePos
// uses, and for the same reason - a creature's attachment points are not exposed
// through gettaginfo, so the hull is the honest source and having ONE wrong-in-
// the-same-way answer beats two differently wrong ones.
vector(entity m, float fwd_dist) AlienFX_MouthPos =
{
	vector p = m.origin;
	p_z = p_z + m.mins_z + (m.maxs_z - m.mins_z) * 0.66;
	makevectors('0 1 0' * m.angles_y);
	return p + v_forward * fwd_dist;
};

#endif // SSQC

#ifdef CSQC

// One slot per ALIENFX_* kind.  ALIENFX_COUNT rather than a literal because the
// same bound is needed in three places and the last widening of this array left
// two of them behind.
const float ALIENFX_COUNT = 12;
float alienfx_effect[ALIENFX_COUNT];
float alienfx_resolved;

// Counters.  A particle leaves nothing at all in a log, so without these "the
// effect played and looked wrong" and "the effect never fired" are the same
// observation - the trap cl_monstertrace.qc documents at length.
float alienfx_dbg_events;
float alienfx_dbg_noslot;	// particleeffectnum gave nothing: a real failure
float alienfx_dbg_unverified;	// ...it gave a slot the engine will not describe
float alienfx_next_report;

// particleeffectnum RETURNS A SLOT EVEN FOR A NAME THAT WAS NEVER REGISTERED, so
// it cannot by itself tell you the recipe exists; particleeffectquery is the only
// thing that can, and it is what Tracer_Resolve gates on.
//
// IT IS A DIAGNOSTIC HERE, NOT A GATE, and that distinction is measured rather
// than stylistic.  pe_null - the particle engine that is active whenever the
// renderer is headless - has a NULL ParticleQuery entry (engine/client/p_null.c:56),
// so particleeffectquery returns "" for EVERY name in a headless client.  Gating
// on it made all seven of these recipes dead in exactly the configuration that is
// the only way anything CSQC-side gets measured on this machine: measured as
// `events=4 unrecipe=4` on a run where the wire path was working perfectly.
//
// Emitting on an unregistered slot is a harmless no-op, so the gate bought
// nothing and cost the whole measurement.
void() AlienFX_Resolve =
{
	if (alienfx_resolved)
		return;
	alienfx_resolved = TRUE;

	alienfx_effect[ALIENFX_SPIT_MUZZLE] = particleeffectnum("weapons.alien_spit_muzzle");
	alienfx_effect[ALIENFX_SPIT_IMPACT] = particleeffectnum("weapons.alien_spit_impact");
	alienfx_effect[ALIENFX_HORNET_FIRE] = particleeffectnum("weapons.hornet_muzzle");
	alienfx_effect[ALIENFX_ZAP_CHARGE]  = particleeffectnum("weapons.islave_charge");
	alienfx_effect[ALIENFX_ZAP_FIRE]    = particleeffectnum("weapons.islave_zap");
	alienfx_effect[ALIENFX_CTRL_BALL]   = particleeffectnum("weapons.controller_ball");
	alienfx_effect[ALIENFX_GARG_STOMP]  = particleeffectnum("weapons.garg_stomp");
	alienfx_effect[ALIENFX_SPORE_BURST] = particleeffectnum("weapons.spore_burst");
	alienfx_effect[ALIENFX_GAUSS_BALLS] = particleeffectnum("weapons.gauss_balls");
	// The reflect, the primary wall hit and the punch entry all share one recipe:
	// GoldSrc passes the same count (3) and the same scatter amplitude (100) for
	// all three, and the primary's larger spray is expressed as the magnitude
	// byte rather than a fourth block.  Only the exit spray differs in shape -
	// twice the scatter, a quarter the launch speed - so it gets its own.
	alienfx_effect[ALIENFX_GAUSS_PRIMARY]   = particleeffectnum("weapons.gauss_balls");
	alienfx_effect[ALIENFX_GAUSS_PUNCH_IN]  = particleeffectnum("weapons.gauss_balls");
	alienfx_effect[ALIENFX_GAUSS_PUNCH_OUT] = particleeffectnum("weapons.gauss_balls_wide");

	// The diagnostic pass, once.  On a real renderer a non-empty body means the
	// r_part block was parsed; anything empty here is a genuinely missing recipe
	// and worth shouting about.
	float i;
	for (i = 0; i < ALIENFX_COUNT; i = i + 1)
	{
		if (alienfx_effect[i] == 0)
			alienfx_dbg_noslot = alienfx_dbg_noslot + 1;
		else if (particleeffectquery(alienfx_effect[i], 0) == "")
			alienfx_dbg_unverified = alienfx_dbg_unverified + 1;
	}
};

void() CSQC_AlienFX_Report =
{
	if (!cvar("developer"))
		return;
	if (!alienfx_dbg_events)
		return;
	if (cltime < alienfx_next_report)
		return;
	alienfx_next_report = cltime + 2;
	// noslot is always a bug.  unverified is 9 in any headless run and 0 with a
	// real renderer, because pe_null cannot describe an effect - see above.
	print(sprintf("[alienfx] events=%g recipes: noslot=%g unverified=%g\n",
	              alienfx_dbg_events, alienfx_dbg_noslot, alienfx_dbg_unverified));
	alienfx_dbg_events = 0;
};

void() CSQC_AlienFX_Parse =
{
	float kind = readbyte();
	vector pos;
	pos_x = readcoord();
	pos_y = readcoord();
	pos_z = readcoord();
	vector dir;
	dir_x = (readbyte() - 127) / 127;
	dir_y = (readbyte() - 127) / 127;
	dir_z = (readbyte() - 127) / 127;
	// Count multiplier.  READ IT BEFORE THE BOUNDS CHECK BELOW: every byte the
	// sender wrote has to come off the wire even for a kind this build does not
	// know, or the parser desyncs and every later event in the packet is garbage.
	float mag = readbyte();

	alienfx_dbg_events = alienfx_dbg_events + 1;

	if (kind < 0 || kind >= ALIENFX_COUNT)
		return;

	AlienFX_Resolve();
	float fx = alienfx_effect[kind];

	// The emit `dir` IS the spawn velocity for every recipe here, the same
	// convention CSQC_SpawnTracer relies on.  Speeds are per-kind because a
	// spit spray leaves the mouth and a stomp puff rises.
	float speed = 1;
	if (kind == ALIENFX_SPIT_MUZZLE)	speed = 260;
	else if (kind == ALIENFX_SPIT_IMPACT)	speed = 110;
	else if (kind == ALIENFX_HORNET_FIRE)	speed = 60;
	else if (kind == ALIENFX_ZAP_FIRE)	speed = 40;
	else if (kind == ALIENFX_GARG_STOMP)	speed = 200;
	else if (kind == ALIENFX_SPORE_BURST)	speed = 180;
	else if (kind == ALIENFX_GAUSS_BALLS)	speed = 100;	// ev_hldm.cpp:1016 passes speed 100
	else if (kind == ALIENFX_GAUSS_PRIMARY)	speed = 200;	// ev_hldm.cpp:1121, the fast one
	else if (kind == ALIENFX_GAUSS_PUNCH_IN)	speed = 100;	// ev_hldm.cpp:1081
	else if (kind == ALIENFX_GAUSS_PUNCH_OUT)	speed = 40;	// ev_hldm.cpp:1096, slow and wide

	if (fx != 0)
		pointparticles(fx, pos, dir * speed, mag);

	// The dynamic lights, which are half of what makes an energy attack read as
	// one in a dark corridor and which no creature in the game has ever cast.
	if (kind == ALIENFX_ZAP_CHARGE)
		dynamiclight_add(pos, 56, '1.00 0.70 0.38');	// islave.cpp:368-377, 255/180/96
	else if (kind == ALIENFX_ZAP_FIRE)
		dynamiclight_add(pos, 112, '1.00 0.70 0.38');
	else if (kind == ALIENFX_CTRL_BALL)
		dynamiclight_add(pos, 72, '1.00 0.85 0.10');	// xspark4.spr, measured below
	else if (kind == ALIENFX_HORNET_FIRE)
		dynamiclight_add(pos, 64, '0.90 0.35 0.88');	// muz4.spr, measured: MAGENTA
	else if (kind == ALIENFX_GARG_STOMP)
		dynamiclight_add(pos, 96, '1.00 0.20 0.12');	// gargeye1.spr, measured: red
	else if (kind == ALIENFX_SPORE_BURST)
		// Colour MEASURED out of gearbox/sprites/spore_exp_c_01.spr's palette, not
		// remembered — the same method the rest of this file used, and it matters
		// here too: the brightest palette entry is (167,193,41), a yellow-green,
		// where "spore" from memory suggests a deeper green.  Nothing like the
		// orange fireball te_explosion was throwing.
		dynamiclight_add(pos, 104, '0.65 0.76 0.16');
};

#endif // CSQC
