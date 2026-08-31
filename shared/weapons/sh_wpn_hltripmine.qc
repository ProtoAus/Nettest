// ============================================================
//  shared/weapons/sh_wpn_hltripmine.qc  -  HL Tripmine
//
//  Slot  : SLOT_UTILITY  (impulse 4 / key 4)
//  Stats : ammo_tripmine (direct pool, max 5 — TRIPMINE_MAX_CARRY, weapons.h:118)
//  Fire  : +attack traces 128 units forward and sticks a mine to whatever it
//          finds, facing out along that surface's normal.  The mine arms after
//          2.5 s, then projects a beam that detonates on anything crossing it.
//
//  Ported from the SDK: dlls/tripmine.cpp.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Sequence indices, read out of v_tripmine.mdl (9 sequences) ----------
const float TRIPMINE_SEQ_IDLE1   = 0;   // idle1,   3.000 s, looping
const float TRIPMINE_SEQ_IDLE2   = 1;   // idle2,   2.000 s, looping
const float TRIPMINE_SEQ_ARM1    = 2;   // arm1,    1.000 s
// DELIBERATELY UNREFERENCED.  `place` is Valve's TRIPMINE_ARM2 and Half-Life plays
// it nowhere; its mine bone is not animated, so it leaves the mine hanging in the
// air while the hands drop away.  Kept named so nobody rediscovers index 3 and
// wires it back in.  The placement plays TRIPMINE_SEQ_DRAW, as HL's own client
// event handler does.
const float TRIPMINE_SEQ_PLACE   = 3;   // place,   0.333 s  (tripmine.cpp calls it ARM2)
const float TRIPMINE_SEQ_FIDGET  = 4;   // fidget,  3.333 s
const float TRIPMINE_SEQ_HOLSTER = 5;   // holster, 0.500 s
const float TRIPMINE_SEQ_DRAW    = 6;   // draw,    0.500 s
const float TRIPMINE_SEQ_WORLD   = 7;   // world,   2.500 s, looping
const float TRIPMINE_SEQ_GROUND  = 8;   // ground,  2.500 s, looping

const float TRIPMINE_FRAME_INTERVAL = 0.05;
const float TRIPMINE_DRAW_DURATION  = 0.5;
// 0.500, the length of the `draw` take the placement now plays (it is 0.500 s in
// valve, valve_hd and svencoop alike).  It was 0.333, which is Half-Life's REFIRE
// interval, not an animation length — and because SH_TripmineTryPlace gates on
// weaponstate as well as on attack_finished, that number is doing both jobs here.
// Leaving it at 0.333 would cut the take two thirds of the way through and snap
// the mine back to idle mid-motion, which is the same defect the DoD knives had.
// The cost is an honest one: placing repeatedly is now 0.5 s per mine rather than
// 0.333 s, on a weapon that carries five.
const float TRIPMINE_PLACE_DURATION = 0.500;

const float MAX_AMMO_TRIPMINE       = 5;    // TRIPMINE_MAX_CARRY, weapons.h:118

// --- Balance -------------------------------------------------------------
// sk_plr_tripmine = 150 (valve/skill.cfg), so the same 375-unit blast the
// satchel gets — see sh_wpn_hlsatchel.qc for why the radius is derived.
const float TRIPMINE_DAMAGE         = 150;
const float TRIPMINE_RADIUS         = 375;
const float TRIPMINE_MIN_DAMAGE     = 15;
const float TRIPMINE_KNOCK_PUSH     = 1000;
const float TRIPMINE_KNOCK_UPLIFT   = 400;

const float TRIPMINE_PLACE_RANGE    = 128;   // tripmine.cpp:424
const float TRIPMINE_STANDOFF       = 8;     // tripmine.cpp:432 — endpos + normal*8
const float TRIPMINE_POWERUP_TIME   = 2.5;   // tripmine.cpp:120
const float TRIPMINE_BEAM_RANGE     = 2048;  // tripmine.cpp:135
const float TRIPMINE_ATTACK_DELAY   = 0.3;   // tripmine.cpp:452
const float TRIPMINE_DEATH_DELAY    = 0.2;   // tripmine.cpp:337, RANDOM_FLOAT(0.1,0.3)

// The deployed mine is v_tripmine.mdl at body 3, sequence "world" - exactly what
// tripmine.cpp:102-105 does.
//
// THE PREVIOUS COMMENT HERE WAS WRONG ON ALL THREE OF ITS CLAIMS, and the mine
// floating off the wall was the result.  For the record, since each was checked:
//
//  1. "p_tripmine.mdl is already the bare mine with no hands."  It is not.  It has
//     12 Bip01 bones and its single bodypart is named "studio", not
//     "reference_tripmine"; the mine mesh hangs off bone Box01, parented to
//     Bip01 R Hand in a grip pose.  Its sequence-0 bbox is (2.7,-12.1,30.7) to
//     (6.7,-3.9,35.3) - the mesh draws roughly 33 units ABOVE and to the side of
//     the entity origin.  That is the "floating off the wall" report; the
//     placement arithmetic (endpos + normal*8) was a correct port all along.
//     It also explains the tilt: the mine's local axes are a hand pose, not the
//     model's forward.
//  2. "FTE cannot select a bodygroup - gl_hlmdl.c hardcodes entity_body to 0."
//     It does not.  gl_hlmdl.c:1797 reads rent->body and :1889 selects with
//     (entity_body / bodypart->base) % bodypart->nummodels.  .body is a QC field
//     (server/progdefs.h:368) and Patch 131 replicates it (sv_ents.c:3660,
//     cl_ents.c:5406), so body 3 is reachable now.
//  3. "w_tripmine.mdl is absent from this install."  It is present, in the
//     MOUNTED svencoop (also bmc, enriched_v96, hl_extended).  Not used here
//     because body 3 is what Half-Life itself draws, but it is an option.
const string TRIPMINE_VIEWMODEL     = "models/v_tripmine.mdl";
// THIRD-PERSON HELD model -- what other players see in your hands.  p_ is
// correct for that and only for that.
const string TRIPMINE_PLAYERMODEL   = "models/p_tripmine.mdl";
// GROUND PICKUP model.  This used to be p_tripmine.mdl as well, and that is the
// "gordens hands" report: p_ models are rigged to a hand attachment, so the mesh
// renders as a mine plus a pair of arms, offset from the entity origin by the
// grip pose (~33 units, which is why it floats ABOVE the pickup).  It also had a
// v_tripmine sequence index applied to it, which is a different model entirely.
//
// Half-Life uses v_tripmine.mdl + pev->body = 3 here (tripmine.cpp:357-364), and
// the deployed mine below already does exactly that.  w_tripmine.mdl is the
// simpler answer for the PICKUP though: it needs no bodygroup, so it cannot be
// affected by whether PEXT2_BODYGROUP reached the client, and it is present in
// the mounted svencoop tree (also bmc, enriched_v96, hl_extended).
const string TRIPMINE_WORLDMODEL    = "models/w_tripmine.mdl";

// DEPLOYED mine — the one stuck to the wall.
//
// This was v_tripmine.mdl + body 3, which is what Half-Life itself draws
// (tripmine.cpp:104) and which point 2 above argues is reachable.  In practice it
// is NOT arriving: the hands are still on the deployed mine in game.  The
// bodygroup byte only rides the UF_BONEDATA section of a replacement-delta
// update (sv_ents.c:1390) and is gated on the client having negotiated
// PEXT2_BODYGROUP, so whether it shows up depends on protocol negotiation this
// code cannot see or assert.
//
// w_tripmine.mdl has ONE bodypart with ONE submodel — verified by reading the
// header: bodyparts=1, submodels=1.  There is no bodygroup to get wrong and no
// hand mesh in the file to leak, so this cannot regress the same way regardless
// of what the protocol does.  Trading exact HL parity for a mine that is always
// a mine is the right trade for a thing you stick on a wall and look at.
const string TRIPMINE_MINE_MODEL    = "models/w_tripmine.mdl";
// Kept and still applied: harmless on a single-bodypart model, and correct again
// the moment TRIPMINE_MINE_MODEL goes back to v_tripmine.mdl.
const float  TRIPMINE_MINE_BODY     = 3;     // tripmine.cpp:104
// Sequence index within TRIPMINE_MINE_MODEL.  Must track that model: w_tripmine
// has 2 sequences, v_tripmine has 9 (its world pose is TRIPMINE_SEQ_WORLD = 7).
//
// RESOLVED BY NAME, and it is the "world" pose, not index 0.  w_tripmine.mdl (the
// svencoop copy — it is the only mount that ships one) carries [0] "ground" and
// [1] "world", and Half-Life uses them for exactly the two different things their
// names say: TRIPMINE_WORLD for a mine stuck on a wall (tripmine.cpp:105) and
// TRIPMINE_GROUND for the floor pickup (:364).  This asked for 0, the FLOOR pose.
//
// The two are the same mesh translated by (-3.77, 0, -3.63) in model space, and on
// a wall the mine is yaw-only, so local +X is the wall normal and local +Z is
// world up: the ground pose drew the mine 3.63 units too HIGH and 3.77 units too
// far off the wall.  The laser starts at the entity origin — which is what HL does
// too, and is correct: neither model declares a single attachment, and HL's
// PointEntInit falls back to the origin for the same reason — but the origin sits
// at the mesh BOTTOM in the ground pose and through the LENS in the world pose.
// That is the whole of "the laser is slightly below the tripmine model", and the
// 8-unit wall standoff was tuned for the world pose too (back face lands 0.01 off
// the wall with it, 3.78 off the wall without).
//
// Do NOT compensate with a Z offset on the beam start; the pose is the bug.
const float  TRIPMINE_MINE_SEQ_FB   = 1;
const string TRIPMINE_DEPLOY_SOUND  = "";
const string TRIPMINE_DISPLAY_NAME  = "TRIPMINE";

float(float spent_wep) W_UtilityNextAfterSpent;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_TripmineTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= TRIPMINE_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= TRIPMINE_PLACE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// IS THERE ACTUALLY A WALL IN REACH?  This used to be answered only AFTER the
// place animation had been stamped, so pressing +attack facing open air played
// the full placement take and left nothing behind — "don't do the place
// animation if nothing will be placed".
//
// Shared, because a server-only gate would change nothing the player sees: the
// tripmine is server-autonomous, CSQC runs this same SH_TripmineTryPlace and
// stamps its own WS_FIRE, and reconcile never writes weaponstate back
// (client/cl_player.qc:1022).  Both sides have the BSP, so a world traceline
// predicts identically on both.
//
// THE ANGLE SOURCE HAS TO DIFFER BY VM and that is not cosmetic: .v_angle is
// written only on the server and is never assigned anywhere under client/, so
// using it in CSQC would leave v_forward at world +X regardless of where the
// player is looking, and the gate would allow and refuse at random.  input_angles
// is the client's equivalent — the same split CSQC_PredictedMeleeTraceEx uses
// (shared/sh_weapon_logic.qc:1825).
float() SH_TripmineCanPlace =
{
#ifdef CSQC
    makevectors(input_angles);
#else
    makevectors(self.v_angle);
#endif
    vector src = self.origin + self.view_ofs;
    traceline(src, src + v_forward * TRIPMINE_PLACE_RANGE, FALSE, self);
    return (trace_fraction < 1.0);
};

// The shared half only decides whether a placement may START.  Whether it
// SUCCEEDS depends on a traceline, and tripmine.cpp:452 charges the 0.3 s
// cooldown either way but only spends a mine on a hit — so the ammo decrement
// lives on the server/predict side next to the trace, not here.
//
// Returns 1 to place, 0 to do nothing, -1 to refuse VISIBLY (cooldown charged,
// no animation).  The three-valued shape is the satchel's (sh_wpn_hlsatchel.qc:442)
// and the callers must test `r == 1` / `r == -1`, never truthiness: -1 is truthy
// and `!(-1)` is 0, so a bare `if (!Try...)` would sail straight past a refusal
// and stamp the very animation this exists to suppress.
float(float now) SH_TripmineTryPlace =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.ammo_tripmine <= 0) return 0;   // tripmine.cpp:417 - silent, no dry-fire

    if (!SH_TripmineCanPlace())
    {
        // Charge the delay but play nothing.  Half-Life is SILENT here — both
        // dlls/tripmine.cpp:431 and ev_hldm.cpp:1611 simply skip the animation
        // with no sound — and tripmine.cpp:484 charges the 0.3 s outside the hit
        // branch, so this matches the SDK on both counts.
        self.attack_finished = now + TRIPMINE_ATTACK_DELAY;
        return -1;
    }

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + TRIPMINE_ATTACK_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// The player who placed the mine.  .owner is reassigned to the wall once the
// mine arms (see W_TripminePowerupThink), so this is where the kill credit
// lives -- HL calls it m_pRealOwner, tripmine.cpp:130.
.entity tripmine_real_owner;


// Additive and capped — see W_SatchelPickupCopy for why.
void(entity player) W_TripminePickupCopy =
{ player.ammo_tripmine = bound(0, player.ammo_tripmine + self.ammo_tripmine, MAX_AMMO_TRIPMINE); };

.float tripmine_armed;        // 0 = powering up, 1 = beam live
.float tripmine_powerup_end;
.float tripmine_beamfrac;     // the beam's trace fraction when it was made
.vector tripmine_dir;         // outward normal it was stuck to
.vector tripmine_end;         // origin + dir * TRIPMINE_BEAM_RANGE
.entity tripmine_beam;        // the visible laser (an env_beam-format entity)

// The mine's laser rides the SHIPPED env_beam transport rather than a second
// beam path of its own: CSQC_ENT_ENV_BEAM already draws a ribbon between two
// world points, and cl_env_beam.qc is the only place in this codebase that
// knows how.  EnvBeam_SendEntity lives in server/sv_env_beam.qc, which
// compiles at line 124 - long after this file - so it arrives by prototype,
// and the fields it reads are re-declared here with their own types.  That is
// the established pattern in this tree (.vector rendercolor is declared in
// four files for exactly this reason), not a workaround.
float(entity ent, float changedflags) EnvBeam_SendEntity;
.float  renderamt;
.vector rendercolor;
.float  BoltWidth;
.float  NoiseAmplitude;
.float  TextureScroll;
.float  framerate;
.float  framestart;
.vector ebeam_start_pos;
.vector ebeam_end_pos;
.float  ebeam_active;
.float  ebeam_sprite_index;
.float  ebeam_end_sprite_index;

// tripmine.cpp:225-234.  Colour 0/214/198 and brightness 64 are Valve's; the
// width is BeamCreate(g_pModelNameLaser, 10) i.e. 10 tenths of a unit.
void(entity mine, vector from, vector to) W_TripmineBeamSend =
{
    entity b = mine.tripmine_beam;
    if (!b)
    {
        b = spawn();
        b.classname = "tripmine_beam";
        b.owner     = mine;
        mine.tripmine_beam = b;
        b.SendEntity = EnvBeam_SendEntity;
        // Precached with the rest of the HL equipment in sh_customdefs.qc;
        // this only needs the index it was given.
        b.ebeam_sprite_index     = getmodelindex("sprites/laserbeam.spr");
        b.ebeam_end_sprite_index = 0;
        b.rendercolor    = '0 214 198';
        b.renderamt      = 64;
        b.BoltWidth      = 10;
        b.NoiseAmplitude = 0;       // a tripmine laser is dead straight
        b.TextureScroll  = 35;
        b.framestart     = 0;
        b.framerate      = 0;
    }
    b.ebeam_active    = TRUE;
    b.ebeam_start_pos = from;
    b.ebeam_end_pos   = to;
    setorigin(b, from);
    b.SendFlags = 1;
};

void(entity mine) W_TripmineBeamKill =
{
    if (mine.tripmine_beam)
    {
        remove(mine.tripmine_beam);
        mine.tripmine_beam = world;
    }
    if (cvar("sv_hlequip_test"))
    {
        float left = 0;
        entity q = findchain(classname, "tripmine_beam");
        while (q) { left = left + 1; q = q.chain; }
        dprint(sprintf("[tripmine] beamkill done, beams still alive=%g\n", left));
    }
};

void() W_TripmineExplode =
{
    float snd = random();
    float snd_idx = (snd < 0.333) ? 0 : (snd < 0.666 ? 1 : 2);
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_EXPLODE);
    WriteShort(MSG_MULTICAST, 0);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 8);
    WriteByte(MSG_MULTICAST, snd_idx);
    multicast(self.origin, MULTICAST_PVS);

    // Credit the player who placed it, not the wall it was hanging on.
    // tripmine.cpp:300-305 restores pev->owner from m_pRealOwner at exactly this
    // point and for exactly this reason.
    entity blame = (self.tripmine_real_owner != world)
                 ? self.tripmine_real_owner : self.owner;

    W_RadiusExplode(self.origin, TRIPMINE_RADIUS,
                    TRIPMINE_DAMAGE, TRIPMINE_MIN_DAMAGE,
                    TRIPMINE_KNOCK_PUSH, TRIPMINE_KNOCK_UPLIFT, blame);
    remove(self);
};

void() W_TripmineDelayDeath =
{
    if (cvar("sv_hlequip_test")) dprint("[tripmine] delaydeath -> explode\n");
    W_TripmineBeamKill(self);
    // tripmine.cpp:343 traces back INTO the surface it was stuck to before
    // exploding, so the blast is centred on the wall rather than in mid-air.
    traceline(self.origin + self.tripmine_dir * 8,
              self.origin - self.tripmine_dir * 64, TRUE, self);
    setorigin(self, trace_endpos + self.tripmine_dir * 4);
    W_TripmineExplode();
};

void() W_TripmineDie =
{
    if (cvar("sv_hlequip_test"))
        dprint(sprintf("[tripmine] die: health=%g takedamage=%g solid=%g inflictor=\"%s\"\n",
                       self.health, self.takedamage, self.solid, self.dmg_inflictor.classname));
    self.takedamage = DAMAGE_NO;
    self.think     = W_TripmineDelayDeath;
    self.nextthink = time + 0.1 + random() * 0.2;   // tripmine.cpp:337
};

// tripmine.cpp:238 BeamBreakThink.  The beam is not an entity that gets
// touched - it is a traceline re-run 10 times a second, and any change in how
// far it reaches means something walked into it.
float tripmine_dbg_beamticks;
void() W_TripmineBeamThink =
{
    tripmine_dbg_beamticks = tripmine_dbg_beamticks + 1;
    self.nextthink = time + 0.1;

    traceline(self.origin, self.tripmine_end, FALSE, self);

    if (fabs(self.tripmine_beamfrac - trace_fraction) > 0.001)
    {
        if (cvar("sv_hlequip_test"))
            dprint(sprintf("[tripmine] beam broken: was %g now %g by \"%s\"\n",
                           self.tripmine_beamfrac, trace_fraction, trace_ent.classname));
        W_TripmineDie();
        return;
    }
};

void() W_TripminePowerupThink =
{
    self.nextthink = time + 0.1;

    if (time < self.tripmine_powerup_end)
        return;

    // HAND THE MINE OVER TO THE WALL.
    //
    // Until this happens the mine's .owner is the player who placed it, and
    // FTE's trace clipper SKIPS the passedict's owner (world.c: "don't clip
    // against owner").  So W_TripmineBeamThink's traceline -- which passes the
    // mine as its ignore entity -- could not see the placer AT ALL.  The person
    // who set the trap could walk through their own beam forever and nothing
    // happened, which in solo testing is every case.  That is the "they don't
    // seem to explode when passing it" report, and it is total: no timing, no
    // tuning, the placer was simply invisible to the beam.
    //
    // Half-Life hits precisely this and solves it by reassigning pev->owner to
    // the SURFACE the mine is stuck to during PowerupThink (tripmine.cpp:167-193),
    // keeping the player in m_pRealOwner and restoring it at detonation so the
    // kill still gets credited.  The comment at tripmine.cpp:300-305 spells the
    // whole thing out.  The port took the `owner = placer` half from Spawn and
    // left this half behind.
    if (self.tripmine_real_owner == world)
    {
        self.tripmine_real_owner = self.owner;

        // Trace back into the surface behind the mine to find what it is stuck
        // to.  Ignore-entity is the mine itself; the placer is deliberately no
        // longer relevant here.
        traceline(self.origin + self.tripmine_dir * 8,
                  self.origin - self.tripmine_dir * 32, FALSE, self);
        // world is the normal answer (a brush wall) and is also the right value
        // for "nothing found" -- either way the placer stops being the owner,
        // which is the whole point.
        self.owner = (trace_fraction < 1.0) ? trace_ent : world;
    }

    // Arming: go solid so it can be shot off the wall, measure the beam once,
    // and hand over to the break test.  tripmine.cpp:203.
    self.solid = SOLID_BBOX;
    setorigin(self, self.origin);

    traceline(self.origin, self.tripmine_end, FALSE, self);
    self.tripmine_beamfrac = trace_fraction;
    self.tripmine_armed    = TRUE;
    if (cvar("sv_hlequip_test"))
        dprint(sprintf("[tripmine] armed, beamfrac=%g end=%v\n", trace_fraction, trace_endpos));

    W_TripmineBeamSend(self, self.origin,
                       self.origin + self.tripmine_dir * TRIPMINE_BEAM_RANGE * trace_fraction);

    sound(self, CHAN_VOICE, "weapons/mine_activate.wav", 0.5, ATTN_NORM, 75, 0);

    self.think = W_TripmineBeamThink;
};

void(entity mine) W_TripmineKilled =
{
    entity oldself = self;
    self = mine;
    W_TripmineDie();
    self = oldself;
};

entity(entity placer, vector org, vector dir) W_TripmineSpawn =
{
    entity m = spawn();
    m.owner     = placer;
    m.tripmine_real_owner = world;   // set when the mine arms
    m.classname = "monster_tripmine";       // tripmine.cpp:46
    m.movetype  = MOVETYPE_FLY;             // tripmine.cpp:86 — it hangs on the wall
    m.solid     = SOLID_NOT;                // goes BBOX when it arms
    setmodel(m, TRIPMINE_MINE_MODEL);
    setsize(m, '-8 -8 -8', '8 8 8');        // tripmine.cpp:94
    setorigin(m, org);
    m.body      = TRIPMINE_MINE_BODY;       // tripmine.cpp:104 — hides the hands
    // .frame IS the sequence index for an HL model (tripmine.cpp:105 uses the
    // "world" sequence).  Resolved by NAME so it survives a change of
    // TRIPMINE_MINE_MODEL — TRIPMINE_SEQ_WORLD is an index into v_tripmine's NINE
    // sequences and would be out of range on w_tripmine's two.  See the long note
    // on TRIPMINE_MINE_SEQ_FB for why "world" and not "ground".
    m.frame     = SH_SeqForName(TRIPMINE_MINE_MODEL, "world", TRIPMINE_MINE_SEQ_FB);

    // PITCH MUST BE NEGATED for a GoldSrc model under FTE.
    //
    // vectoangles() returns the MESH convention, +pitch = UP (pr_bgcmd.c:6847
    // passes meshpitch=true, mathlib.c:336 then scales by r_meshpitch = -1), and
    // that is the convention Half-Life's own VectorAngles emits.  But FTE only
    // builds render axes with AngleVectorsMesh for mod_alias — cl_ents.c:5497 —
    // and an HL model is mod_halflife (gl_hlmdl.c:779), so it gets plain
    // AngleVectors, where +pitch = DOWN.  GoldSrc compensates explicitly
    // (StudioModelRenderer.cpp:513, angles[PITCH] = -angles[PITCH]); FTE does not.
    //
    // Untouched, a mine on a floor (normal '0 0 1' -> pitch 90) renders pointing
    // straight INTO the floor.  Only shows up where pitch is non-zero, which is
    // why nothing else in the mod tripped over it — monsters are yaw-only.
    //
    // Fixed here rather than in the engine on purpose: widening cl_ents.c:5497 to
    // mod_halflife would be more principled (cl_ents.c:4128, :6980 and
    // pr_csqc.c:749 all already test both) but would flip EVERY HL model that has
    // been authored against the current behaviour. Not worth it for one weapon.
    m.angles    = vectoangles(dir);
    m.angles_x  = -m.angles_x;

    // tripmine.cpp:139 derives the beam direction from the mine's own angles.  We
    // keep the caller's `dir` for that (see tripmine_dir below) precisely because
    // the angles have now been bent to suit the renderer and no longer round-trip.
    m.takedamage = DAMAGE_YES;              // tripmine.cpp:125
    m.health    = 1;                        // "don't let die normally"
    m.on_killed = W_TripmineDie;

    m.tripmine_dir         = dir;
    m.tripmine_end         = org + dir * TRIPMINE_BEAM_RANGE;
    m.tripmine_powerup_end = time + TRIPMINE_POWERUP_TIME;
    m.think     = W_TripminePowerupThink;
    m.nextthink = time + 0.2;               // tripmine.cpp:122

    // ONLY A MINE SOMEBODY PLACED MAKES A NOISE.  tripmine.cpp:130-137 wraps both
    // of these in `if (pev->owner != NULL)`, and the reason is the map-placed
    // variant: a level that opens with eight armed mines on the walls (hl_c04) must
    // not greet the player with eight deploy beeps from across the map, and in
    // Half-Life it does not, because a `monster_tripmine` placed by the BSP has no
    // owner.  The player's own thrown mine still beeps exactly as before.
    if (placer && placer != world)
    {
        sound(m, CHAN_VOICE, "weapons/mine_deploy.wav", 1.0, ATTN_NORM);
        sound(m, CHAN_BODY,  "weapons/mine_charge.wav", 0.2, ATTN_NORM);
    }
    return m;
};

#ifdef SSQC
// ---------------------------------------------------------------------------
//  monster_tripmine  —  the ARMED WALL MINE a map places
// ---------------------------------------------------------------------------
// The armed mine and the pickup are two different entities in Half-Life, declared
// in the same file: LINK_ENTITY_TO_CLASS(monster_tripmine, CTripmineGrenade) at
// tripmine.cpp:77, and weapon_tripmine -> CTripmine at :355.  This tree had only
// the weapon, so every map-placed mine fell through to SV_OnEntityNoSpawnFunction
// and became an invisible inert relay — which is the "tripmines on the wall that
// are not being placed" report.  It is not one map: monster_tripmine appears on ten
// of the thirty-five Sven hl_c* maps (c04 x8, c07_a2 x11, c11_a3 x16, ...) plus six
// vanilla ones.
//
// Everything the entity needs already existed in W_TripmineSpawn above; what was
// missing was a door from the map into it, plus the three things a BSP placement
// supplies differently from a player throw:
//
//   1. DIRECTION COMES FROM `angles`.  tripmine.cpp:139-141 does
//      UTIL_MakeAimVectors(pev->angles); m_vecDir = gpGlobals->v_forward;
//      i.e. the mapper's angle IS the outward wall normal.  All eight of c04's
//      mines are yaw-only (0 180 0, 0 90 0, 0 270 0, 0 0 0), so the pitch
//      negation W_TripmineSpawn applies for the renderer round-trips cleanly.
//   2. NO OWNER, therefore no deploy beeps — handled in W_TripmineSpawn above.
//   3. SPAWNFLAG 1 IS THE FAST ARM.  tripmine.cpp:112-121 uses 1.0 s instead of
//      the normal 2.5 s.  None of c04's mines set it, but c07_a2 and c11_a3 do.
//
// W_TripminePowerupThink already re-seats .owner onto whatever surface it traces
// to and arms the beam, so nothing else is needed here.
void() monster_tripmine =
{
    makevectors(self.angles);
    vector dir = v_forward;

    entity m = W_TripmineSpawn(world, self.origin, dir);

    if (self.spawnflags & 1)
        m.tripmine_powerup_end = time + 1.0;    // tripmine.cpp:114

    // The map entity itself is only a placement record; the live mine is the new
    // entity.  Carry the name across so a killtarget or a trigger chain naming this
    // mine still reaches something.
    m.targetname = self.targetname;
    remove(self);
};
#endif

void() W_TripmineFire =
{
    // `r == 1`, not truthiness — see the note on SH_TripmineTryPlace's return
    // values.  A -1 refusal has already charged the cooldown and wants no
    // animation at all.
    if (SH_TripmineTryPlace(time) != 1) return;

    // DRAW, NOT PLACE.  `place` is Valve's TRIPMINE_ARM2 and Half-Life never plays
    // it — CTripmine::PrimaryAttack sends no animation at all, and the client event
    // handler plays TRIPMINE_DRAW on a successful placement (ev_hldm.cpp:1583).
    // The reason it is dead is visible in the data: across `place` the mine's bone
    // does not move AT ALL while the hands shove forward and drop out of frame, so
    // the mine hangs in mid-air exactly where the idle left it — the reported "the
    // tripmine stays in front of the placing hands".  `draw` animates both
    // together, which reads as "that one is on the wall now, here is the next".
    //
    // (The masking the report guesses at is impossible on this asset anyway: the
    // blank submodel is on the HANDS bodypart, not the mine, so there is no
    // hands-without-mine combination to select.)
    self.weaponframe   = TRIPMINE_SEQ_DRAW;
    // MUST schedule, not clear -- same defect the satchel had.  sv_weapons.qc:3820
    // only calls wepframe while wep_nextframe > 0, and W_TripmineFrame is the only
    // route to SH_WeaponEnterIdle, so a 0 here left weaponstate at WS_FIRE and
    // SH_TripmineTryPlace refused every later placement.  One mine per equip.
    self.wep_nextframe = time + TRIPMINE_FRAME_INTERVAL;

    makevectors(self.v_angle);
    vector src = self.origin + self.view_ofs;
    traceline(src, src + v_forward * TRIPMINE_PLACE_RANGE, FALSE, self);

    if (trace_fraction >= 1.0)
    {
        // Unreachable in practice now — SH_TripmineCanPlace ran the same trace
        // before the animation was stamped and returned -1.  Kept as a backstop
        // because the two traces are a tick apart and the player can turn.
        if (cvar("sv_hlequip_test"))
            dprint("[tripmine] no surface within 128 units - nothing placed\n");
        return;
    }

    // tripmine.cpp:429 refuses conveyors specifically, because a mine stuck to
    // a moving surface would blow the instant the surface moved.  The general
    // form of that is "anything that moves", which is what this tests.
    //
    // THIS ONE STAYS SERVER-ONLY and therefore still animates before refusing:
    // CSQC holds no reliable .movetype for a server brush entity, so
    // SH_TripmineCanPlace cannot evaluate it and the shared gate above lets it
    // through.  Worth knowing that it is also much broader than the SDK line it
    // cites — tripmine.cpp:487 tests FL_CONVEYOR only, while `movetype !=
    // MOVETYPE_NONE` rejects every MOVETYPE_PUSH brush, i.e. every door, train,
    // plat and button on the map.  Half-Life lets you mine a door; this does
    // not.  Narrowing it toward the conveyor test would shrink the residual
    // phantom-animation case to almost nothing, but that is a behaviour change
    // in its own right and is left for a decision rather than smuggled in here.
    if (trace_ent && trace_ent.movetype != MOVETYPE_NONE && trace_ent != world)
        return;

    entity m = W_TripmineSpawn(self, trace_endpos + trace_plane_normal * TRIPMINE_STANDOFF,
                               trace_plane_normal);
    self.ammo_tripmine -= 1;
    if (cvar("sv_hlequip_test"))
        dprint(sprintf("[tripmine] placed at %v normal=%v surface=\"%s\"\n",
                       m.origin, trace_plane_normal, trace_ent.classname));

    if (self.ammo_tripmine <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(WEP_TRIPMINE);
};

void() W_TripmineFrame =
{
    float result = SH_TripmineTickState(time);
    if (result & 1)
    {
        if (self.ammo_tripmine <= 0 && self.weapon == WEP_TRIPMINE)
        {
            if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
            else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
            else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
            return;
        }
        self.weaponframe   = TRIPMINE_SEQ_IDLE1;
        self.wep_nextframe = 0;
    }
};

void() W_TripmineEquip =
{
    W_StandardEquipSetup(TRIPMINE_VIEWMODEL, TRIPMINE_DISPLAY_NAME, TRIPMINE_SEQ_DRAW,
        TRIPMINE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_TripmineFire;
    self.altfire  = __NULL__;
    self.reload   = __NULL__;
    self.wepframe = W_TripmineFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_TripmineDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_tripmine = self.ammo_tripmine;
    self.ammo_tripmine = 0;

    setmodel(tgt, TRIPMINE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 28');   // tripmine.cpp:368
    tgt.classname    = "weapon_tripmine";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_TRIPMINE;
    tgt.weapon_slot  = SLOT_UTILITY;
    tgt.weap_draw    = W_TripmineEquip;
    tgt.weap_drop_func = W_TripmineDrop;
    tgt.pickupcopy   = W_TripminePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_tripmine =
{
    setmodel(self, TRIPMINE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 28');
    self.classname     = "weapon_tripmine";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_TRIPMINE;
    self.weapon_slot   = SLOT_UTILITY;
    self.weap_draw     = W_TripmineEquip;
    self.weap_drop_func = W_TripmineDrop;
    self.pickupcopy    = W_TripminePickupCopy;
    self.touch         = weapon_touch;
    self.frame         = TRIPMINE_SEQ_GROUND;   // tripmine.cpp:353
    self.ammo_tripmine = 1;                     // TRIPMINE_DEFAULT_GIVE, weapons.h:156
    W_RegisterMapWeapon(weapon_tripmine);
};
void() spawnfunc_weapon_tripmine = { weapon_tripmine(); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void(float new_weapon) CSQC_PredictSelectWeapon;

void() CSQC_PredictTripmineCommand =
{
    if (input_buttons & 1)
    {
        // `== 1`, not truthiness: -1 is TRUE in QC, so the old form claimed an
        // ack for a placement that was refused and never happened.
        if (SH_TripmineTryPlace(csqc_pred_time) == 1)
            CSQC_MarkPendingWeaponAck();
        // The mine itself is NOT predicted.  Its placement depends on a
        // traceline against a world the client only approximates, and a mine
        // that appears and then vanishes on reconcile is worse than one that
        // appears a ping late.
    }

    if (SH_TripmineTickState(csqc_pred_time) & 1)
    {
        if (self.ammo_tripmine <= 0)
        {
            if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
            else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
            else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
        }
    }
};

float(float elapsed) CSQC_TripmineDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return TRIPMINE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        // DRAW, not PLACE — this is the arm that actually drives the local
        // viewmodel, and `place` leaves the mine frozen in mid-air.  See the long
        // note at the same change in W_TripmineFire.
        return TRIPMINE_SEQ_DRAW;
    return TRIPMINE_SEQ_IDLE1;
};

void() CSQC_TripmineDropClear =
{ self.ammo_tripmine = 0; };

void() CSQC_TripmineEquip =
{
    self.weapon_name         = TRIPMINE_DISPLAY_NAME;
    self.weapon_viewmodel    = TRIPMINE_VIEWMODEL;
    self.weapon_worldmodel   = TRIPMINE_PLAYERMODEL;
    self.weapon_deploy_sound = TRIPMINE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTripmineCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_TripmineDisplayFrame;
    self.csqc_drop_clear     = CSQC_TripmineDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
