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
const float TRIPMINE_SEQ_PLACE   = 3;   // place,   0.333 s  (tripmine.cpp calls it ARM2)
const float TRIPMINE_SEQ_FIDGET  = 4;   // fidget,  3.333 s
const float TRIPMINE_SEQ_HOLSTER = 5;   // holster, 0.500 s
const float TRIPMINE_SEQ_DRAW    = 6;   // draw,    0.500 s
const float TRIPMINE_SEQ_WORLD   = 7;   // world,   2.500 s, looping
const float TRIPMINE_SEQ_GROUND  = 8;   // ground,  2.500 s, looping

const float TRIPMINE_FRAME_INTERVAL = 0.05;
const float TRIPMINE_DRAW_DURATION  = 0.5;
const float TRIPMINE_PLACE_DURATION = 0.333;

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

// The deployed mine and the ground pickup both use p_tripmine.mdl.
//
// This resolves what was flagged as an unavoidable compromise.  w_tripmine.mdl
// genuinely is absent from this install, and HL's own answer is to draw the
// deployed mine with v_tripmine.mdl at body 3 - a bodygroup that hides the
// hands and swaps in the world mesh.  FTE cannot do that here: gl_hlmdl.c:1767
// hardcodes entity_body to 0 and bodygroups are only reachable through a .skin
// file, which cl_ents.c:5109 clears for every server-replicated entity.  But
// p_tripmine.mdl has ONE bodypart, "reference_tripmine" - it is already the
// bare mine with no hands, which is exactly what body 3 was selecting.  So the
// missing asset costs nothing.
const string TRIPMINE_VIEWMODEL     = "models/v_tripmine.mdl";
const string TRIPMINE_WORLDMODEL    = "models/p_tripmine.mdl";
const string TRIPMINE_MINE_MODEL    = "models/p_tripmine.mdl";
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

// The shared half only decides whether a placement may START.  Whether it
// SUCCEEDS depends on a traceline, and tripmine.cpp:452 charges the 0.3 s
// cooldown either way but only spends a mine on a hit — so the ammo decrement
// lives on the server/predict side next to the trace, not here.
float(float now) SH_TripmineTryPlace =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.ammo_tripmine <= 0) return 0;   // tripmine.cpp:417 - silent, no dry-fire

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

    W_RadiusExplode(self.origin, TRIPMINE_RADIUS,
                    TRIPMINE_DAMAGE, TRIPMINE_MIN_DAMAGE,
                    TRIPMINE_KNOCK_PUSH, TRIPMINE_KNOCK_UPLIFT, self.owner);
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
    m.classname = "monster_tripmine";       // tripmine.cpp:46
    m.movetype  = MOVETYPE_FLY;             // tripmine.cpp:86 — it hangs on the wall
    m.solid     = SOLID_NOT;                // goes BBOX when it arms
    setmodel(m, TRIPMINE_MINE_MODEL);
    setsize(m, '-8 -8 -8', '8 8 8');        // tripmine.cpp:94
    setorigin(m, org);
    m.angles    = vectoangles(dir);
    m.frame     = 0;
    m.takedamage = DAMAGE_YES;              // tripmine.cpp:125
    m.health    = 1;                        // "don't let die normally"
    m.on_killed = W_TripmineDie;

    m.tripmine_dir         = dir;
    m.tripmine_end         = org + dir * TRIPMINE_BEAM_RANGE;
    m.tripmine_powerup_end = time + TRIPMINE_POWERUP_TIME;
    m.think     = W_TripminePowerupThink;
    m.nextthink = time + 0.2;               // tripmine.cpp:122

    sound(m, CHAN_VOICE, "weapons/mine_deploy.wav", 1.0, ATTN_NORM);
    sound(m, CHAN_BODY,  "weapons/mine_charge.wav", 0.2, ATTN_NORM);
    return m;
};

void() W_TripmineFire =
{
    if (!SH_TripmineTryPlace(time)) return;

    self.weaponframe   = TRIPMINE_SEQ_PLACE;
    self.wep_nextframe = 0;

    makevectors(self.v_angle);
    vector src = self.origin + self.view_ofs;
    traceline(src, src + v_forward * TRIPMINE_PLACE_RANGE, FALSE, self);

    if (trace_fraction >= 1.0)
    {
        // Nothing in reach.  The swing still cost its 0.3 s (tripmine.cpp:452
        // charges the delay outside the hit test) and no mine is spent.
        if (cvar("sv_hlequip_test"))
            dprint("[tripmine] no surface within 128 units - nothing placed\n");
        return;
    }

    // tripmine.cpp:429 refuses conveyors specifically, because a mine stuck to
    // a moving surface would blow the instant the surface moved.  The general
    // form of that is "anything that moves", which is what this tests.
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
        if (SH_TripmineTryPlace(csqc_pred_time))
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
        return TRIPMINE_SEQ_PLACE;
    return TRIPMINE_SEQ_IDLE1;
};

void() CSQC_TripmineDropClear =
{ self.ammo_tripmine = 0; };

void() CSQC_TripmineEquip =
{
    self.weapon_name         = TRIPMINE_DISPLAY_NAME;
    self.weapon_viewmodel    = TRIPMINE_VIEWMODEL;
    self.weapon_worldmodel   = TRIPMINE_WORLDMODEL;
    self.weapon_deploy_sound = TRIPMINE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTripmineCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_TripmineDisplayFrame;
    self.csqc_drop_clear     = CSQC_TripmineDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
