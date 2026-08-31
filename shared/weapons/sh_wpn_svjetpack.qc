// ============================================================
//  shared/weapons/sh_wpn_svjetpack.qc  -  Glock 18 Jetpack (pizza_ya_san2)
//
//  Slot  : SLOT_SECONDARY
//  Stats : 20-round magazine / 100 reserve on the shared 9mm pool, plus a
//          separate 100-unit FUEL pool on the uranium pool.
//  Fire  : +attack  — a 9mm pistol, mechanically the CS Glock 18.
//          +attack2 — jetpack thrust: lifts you and lowers your gravity.
//          special  — cycle the boost level 1..10 (crouched steps down).
//
//  Unlike the Opposing Force weapons in this batch, this one HAS READABLE
//  SOURCE.  The map's own AngelScript ships with Sven Co-op at
//  svencoop_downloads/scripts/maps/pizza_ya_san/weapon_as_jetpack.as (330
//  lines), so every constant below has an origin and the divergences are
//  deliberate rather than invented.
//
//  TWO DELIBERATE DIVERGENCES FROM THE SCRIPT, both called out again where they
//  happen:
//
//    1. The script applies a FIXED impulse per call from a 0.01 s re-arm, so its
//       thrust is frame-rate dependent.  In a predicted mod that guarantees the
//       client and server disagree whenever framerate != tickrate.  Every
//       constant here is per-SECOND and scaled by the tick length instead.
//    2. The script has NO rise cap and at boost 10 accelerates upward until the
//       fuel runs out.  Uncapped vertical velocity interacts badly with
//       PM_CategorizePosition and with fall damage, so JET_MAX_RISE exists.
//
//  Also changed: the script repurposes m_iClip as the boost level and has no
//  magazine at all.  This mod is magazine-based everywhere and the model ships
//  real reload sequences, so the primary gets a proper 20-round magazine and the
//  boost level moves onto this mod's third weapon verb (WEAPON_IMPULSE_SPECIAL).
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float mag_jetpack;
.float ammo_jetpack;
.float jet_boost;          // 1..10, .as m_iClip, default 3 (.as line 50)
.float jet_grav_until;     // low gravity holds until this time
.float jet_grav_saved;     // the gravity we found before lowering it
.float jet_fuel_accum;     // seconds of thrust since the last fuel unit burned
.float jet_burn_next;      // next burn effect
.float jet_alt_held;       // +attack2 seen this frame; the frame applies the thrust

// --- Sequence indices, read out of v_glock18jet.mdl (9 sequences) ---------
const float JET_SEQ_IDLE1        = 0;   // idle1,        3.000 s
const float JET_SEQ_IDLE2        = 1;   // idle2,        1.400 s
const float JET_SEQ_IDLE3        = 2;   // idle3,        3.000 s
const float JET_SEQ_SHOOT        = 3;   // shoot,        0.667 s
const float JET_SEQ_SHOOT_EMPTY  = 4;   // shoot_empty,  0.667 s
const float JET_SEQ_RELOAD_EMPTY = 5;   // reload_empty, 1.964 s
const float JET_SEQ_RELOAD       = 6;   // reload,       1.833 s
const float JET_SEQ_DRAW         = 7;   // draw,         0.800 s
const float JET_SEQ_HOLSTER      = 8;   // holster,      0.200 s

const float JET_FRAME_INTERVAL   = 0.05;
const float JET_DRAW_DURATION    = 0.8;
const float JET_FIRE_DURATION    = 0.667;
const float JET_RELOAD_DURATION  = 1.833;
const float JET_RELOAD_APPLY     = 1.5;

const float MAX_MAG_JETPACK      = 20;    // matches this mod's Glock 18
const float MAX_AMMO_JETPACK     = 100;
const float MAX_FUEL_JETPACK     = 100;   // .as MP5_MAX_AMMO2

// --- Balance -------------------------------------------------------------
const float JET_FIRE_DELAY       = 0.15;
const float JET_DRYFIRE_DELAY    = 0.2;
const float JET_CLOSE_DAMAGE     = 18;
const float JET_MIN_DAMAGE       = 10;
const float JET_FALLOFF_RANGE    = 2048;
const float JET_BASE_SPREAD      = 0.01;
const float JET_MOVE_SPREAD      = 0.05;
const float JET_FULL_SPREAD_SPD  = 320;

const float JET_LOW_GRAVITY      = 0.3;   // .as line 24
const float JET_GRAV_LINGER      = 1.0;   // .as WeaponIdle restores after 1 s
const float JET_THRUST_BASE      = 1000;  // u/s^2
const float JET_THRUST_PER_LEVEL = 300;   // u/s^2 per boost level (.as: 3*m_iClip/tick)
const float JET_LATERAL_ASSIST   = 0.15;  // .as accX/accY
const float JET_MAX_RISE         = 400;   // NOT in the .as - see header
const float JET_FUEL_INTERVAL    = 0.6;   // .as: 1 fuel per FUEL_CYCLE(60) ticks
const float JET_BURN_INTERVAL    = 0.3;   // .as: FUEL_CYCLE/2
const float JET_BOOST_MIN        = 1;
const float JET_BOOST_MAX        = 10;

const float JET_MUZZLE_FORWARD   = 38;
const float JET_MUZZLE_RIGHT     = 13.3;
const float JET_MUZZLE_DOWN      = 9;

const string JET_VIEWMODEL       = "models/pizza_ya_san/v_glock18jet.mdl";
const string JET_WORLDMODEL      = "models/pizza_ya_san/w_glock18jet.mdl";
const string JET_DISPLAY_NAME    = "GLOCK 18 JETPACK";
const string JET_DEPLOY_SOUND    = "";
const string JET_BURN_SOUND      = "ambience/steamburst1.wav";
// The .as spells its two UI sounds "hl/items/clipinsert1.wav" and
// "hl/weapons/357_cock1.wav".  That hl/ prefix is a Sven Co-op convention and
// those paths exist ONLY in the svencoop mount - the unprefixed spellings are in
// valve as well, so they resolve whether or not Sven is mounted.  Same files.

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_JetTickState =
{
    return SH_StandardTickState(now, mag_jetpack, ammo_jetpack, MAX_MAG_JETPACK,
        JET_DRAW_DURATION, JET_FIRE_DURATION,
        JET_RELOAD_DURATION, JET_RELOAD_APPLY);
};

float(float now) SH_JetTryFire =
{
    // .as line 128 - no shooting underwater.
    if (self.waterlevel >= 3) return 0;
    return SH_StandardTryFire(now, mag_jetpack, JET_FIRE_DELAY, JET_DRYFIRE_DELAY);
};

float(float now) SH_JetTryReload =
{
    return SH_StandardTryReload(now, mag_jetpack, ammo_jetpack, MAX_MAG_JETPACK,
                                JET_RELOAD_DURATION);
};

// THE GRAVITY, AND WHY IT LIVES IN SHARED CODE.
//
// shared/sh_pmove.qc reads .gravity every move (mv_entgravity), but .gravity is
// replicated by NOTHING - it is absent from the PM_SF_MOVEMENT proxy writer, the
// CSQC reader and the confirmed-state snapshot.  So a server-only
// `self.gravity = 0.3` would leave the client predicting full gravity for the
// whole flight, which is continuous vertical rubber-banding rather than a glitch
// you could ship.
//
// The fix costs no protocol change, because the ordering already cooperates:
// CSQC_PredictWeaponCommand runs BEFORE PM_PlayerMove on the client (both on the
// live path and on the reconcile replay), mirroring the server where the weapon
// frame runs inside PlayerPreThink before PM_Move.  So writing .gravity from a
// pure function of buffered input, on both sides, lands before pmove reads it
// and re-derives identically during replay.  This is the same trick the gauss
// uses for its self-push.
//
// Restoring the SAVED value rather than a hard 1.0 is what keeps this from
// quietly cancelling a trigger_gravity the player is standing in; the .as
// restores a hard NORMAL_GRAVITY and would clobber exactly that case.
void(float now) SH_JetTickGravity =
{
    if (self.weapon != WEP_JETPACK)
    {
        // Switching away must never strand you floating.
        if (self.jet_grav_until > 0)
        {
            self.gravity = self.jet_grav_saved;
            self.jet_grav_until = 0;
        }
        return;
    }

    if (now < self.jet_grav_until)
    {
        self.gravity = JET_LOW_GRAVITY;
        return;
    }

    if (self.jet_grav_until > 0)
    {
        self.gravity = self.jet_grav_saved;
        self.jet_grav_until = 0;
    }
};

// One thrust tick.  dt is the real elapsed time for this tick, so the result is
// frame-rate independent - see divergence 1 in the header.
float(float now, float dt) SH_JetThrust =
{
    if (self.waterlevel >= 3) return 0;          // .as line 207
    if (self.ammo_jetfuel <= 0) return 0;
    if (dt <= 0) return 0;

    if (self.jet_boost < JET_BOOST_MIN) self.jet_boost = 3;

    // Stash the pre-thrust gravity on the rising edge only.
    if (self.jet_grav_until <= 0)
        self.jet_grav_saved = self.gravity;
    self.jet_grav_until = now + JET_GRAV_LINGER;
    self.gravity = JET_LOW_GRAVITY;

    float accel = JET_THRUST_BASE + JET_THRUST_PER_LEVEL * self.jet_boost;
    self.velocity_z = self.velocity_z + accel * dt;
    if (self.velocity_z > JET_MAX_RISE)
        self.velocity_z = JET_MAX_RISE;

    // .as lines 220-226: a little help in whatever direction you are already
    // moving, so the pack steers rather than only lifting.
    self.velocity_x = self.velocity_x + self.velocity_x * JET_LATERAL_ASSIST * dt;
    self.velocity_y = self.velocity_y + self.velocity_y * JET_LATERAL_ASSIST * dt;

    // Fuel burns on an accumulator, not a tick counter - same reason as thrust.
    self.jet_fuel_accum = self.jet_fuel_accum + dt;
    while (self.jet_fuel_accum >= JET_FUEL_INTERVAL && self.ammo_jetfuel > 0)
    {
        self.jet_fuel_accum = self.jet_fuel_accum - JET_FUEL_INTERVAL;
        self.ammo_jetfuel   = self.ammo_jetfuel - 1;
    }
    return 1;
};

// THE BOOST CYCLE IS SHARED, and it has to be.
//
// .jet_boost is not on the prediction proxy, and the thrust it selects is applied
// by SH_JetTickGravity — which is shared and runs inside the CLIENT's pmove as well
// as the server's.  So while only the server cycled it, the centreprint and the
// click arrived (both server-side) and the flight did not change on your own
// screen: the client kept predicting the boost it drew with, and from boost 4 up
// the server lifted you faster than the client thought, which reconcile then
// yanked back every snapshot.
//
// Both sides run this off the same consumed impulse and the same replicated
// FL_DUCKING, so they stay in step with no wire change.
void() SH_JetCycleBoost =
{
    // .as lines 273-296: crouched steps DOWN, standing steps UP, both wrap.
    if (self.flags & FL_DUCKING)
    {
        self.jet_boost = self.jet_boost - 1;
        if (self.jet_boost < JET_BOOST_MIN) self.jet_boost = JET_BOOST_MAX;
    }
    else
    {
        self.jet_boost = self.jet_boost + 1;
        if (self.jet_boost > JET_BOOST_MAX) self.jet_boost = JET_BOOST_MIN;
    }
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_JetPickupCopy =
{
    player.mag_jetpack   = self.mag_jetpack;
    player.ammo_jetpack  = self.ammo_jetpack;
    player.ammo_jetfuel  = self.ammo_jetfuel;
    if (player.jet_boost < JET_BOOST_MIN) player.jet_boost = 3;
};

void() W_JetShoot =
{
    W_PenetratingHitscanShoot(JET_BASE_SPREAD, JET_MOVE_SPREAD, JET_FULL_SPREAD_SPD,
        JET_CLOSE_DAMAGE, JET_MIN_DAMAGE, JET_FALLOFF_RANGE, 8, 0.94,
        0.55, 2.25, 1.5);
};

void() W_JetFire =
{
    float r = SH_JetTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = (self.mag_jetpack > 0) ? JET_SEQ_SHOOT : JET_SEQ_SHOOT_EMPTY;
        // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
        // wep_nextframe > 0, so a 0 here retires the frame function permanently and
        // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
        // it kept shooting and the freeze went unnoticed -- but the idle animation and
        // every per-tick behaviour behind the frame function stopped).  Clear it only
        // on the idle-retire, the way the *Frame functions below do.
        self.wep_nextframe = time + JET_FRAME_INTERVAL;
        W_JetShoot();
        sound(self, CHAN_WEAPON, "weapons/hks1.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_JetAltFire =
{
    // The thrust itself is applied in the weapon frame, where a real dt is
    // available; the button only marks intent.  Doing it here would tie the
    // impulse to the +attack2 re-arm rate, which is the .as's own bug.
    self.jet_alt_held = TRUE;
};

void() W_JetReload =
{
    if (SH_JetTryReload(time))
    {
        self.weaponframe   = (self.mag_jetpack > 0) ? JET_SEQ_RELOAD : JET_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = 0;
        sound(self, CHAN_WEAPON, "items/clipinsert1.wav", 1, ATTN_NORM);
    }
};

// This mod's third weapon verb, which is where the boost level goes.
void() W_JetCycleBoost =
{
    SH_JetCycleBoost();
    sound(self, CHAN_ITEM, "weapons/357_cock1.wav", 0.8, ATTN_NORM);
    centerprint(self, sprintf("Boost Level: %g\n", self.jet_boost));
};

void() W_JetFrame =
{
    SH_JetTickGravity(time);

    if (self.jet_alt_held)
    {
        if (SH_JetThrust(time, frametime))
        {
            if (time >= self.jet_burn_next)
            {
                self.jet_burn_next = time + JET_BURN_INTERVAL;
                sound(self, CHAN_BODY, JET_BURN_SOUND, 0.8, ATTN_NORM);
            }
        }
        self.jet_alt_held = FALSE;
    }

    float result = SH_JetTickState(time);
    if (result & 1)
    {
        self.weaponframe   = JET_SEQ_IDLE1;
        self.wep_nextframe = 0;
    }
};

void() W_JetEquip =
{
    W_StandardEquipSetup(JET_VIEWMODEL, JET_DISPLAY_NAME, JET_SEQ_DRAW,
        JET_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_JetFire;
    self.altfire  = W_JetAltFire;
    self.reload   = W_JetReload;
    self.special  = W_JetCycleBoost;
    self.wepframe = W_JetFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    if (self.jet_boost < JET_BOOST_MIN) self.jet_boost = 3;
    W_SetCrosshairProfile(0, 0, 320, 1.2, TRUE);
};

void() W_JetDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_jetpack  = self.mag_jetpack;
    tgt.ammo_jetpack = self.ammo_jetpack;
    tgt.ammo_jetfuel = self.ammo_jetfuel;
    self.mag_jetpack = 0; self.ammo_jetpack = 0; self.ammo_jetfuel = 0;

    // .as Holster (line 118) restores gravity, and so must dropping it.
    if (self.jet_grav_until > 0)
    {
        self.gravity = self.jet_grav_saved;
        self.jet_grav_until = 0;
    }

    setmodel(tgt, JET_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname    = "weapon_as_jetpack";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_JETPACK;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_JetEquip;
    tgt.weap_drop_func = W_JetDrop;
    tgt.pickupcopy   = W_JetPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_as_jetpack =
{
    precache_model(JET_WORLDMODEL);
    precache_model(JET_VIEWMODEL);

    setmodel(self, JET_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname     = "weapon_as_jetpack";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_JETPACK;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_JetEquip;
    self.weap_drop_func = W_JetDrop;
    self.pickupcopy    = W_JetPickupCopy;
    self.touch         = weapon_touch;
    self.mag_jetpack   = MAX_MAG_JETPACK;
    self.ammo_jetpack  = MAX_AMMO_JETPACK;
    self.ammo_jetfuel  = MAX_FUEL_JETPACK;
    self.jet_boost     = 3;
    W_RegisterMapWeapon(weapon_as_jetpack);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictJetCommand =
{
    // Gravity and thrust BOTH run here, before PM_PlayerMove reads .gravity and
    // .velocity - see SH_JetTickGravity's note.  input_timelength is the
    // client's real tick length and is what makes the two sides agree.
    SH_JetTickGravity(csqc_pred_time);

    // Bit 4 is +attack2; bit 2 is PM_BTN_JUMP (sh_pmove.qc:42).  Same wrong-bit
    // defect the satchel had, and worse here: the thrust is PREDICTED movement,
    // so reading the jump bit meant jumping applied thrust client-side that the
    // server never applied, and +attack2 thrusted server-side with no local
    // prediction at all.  sh_weapons.qc:145 documents the jetpack as +attack2.
    if (input_buttons & 4)
        SH_JetThrust(csqc_pred_time, input_timelength);

    if (input_buttons & 1)
    {
        float r = SH_JetTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/hks1.wav", 1, ATTN_NORM);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash(MUZZLE_TINT_DEFAULT);
            }
        }
    }

    SH_JetTickState(csqc_pred_time);
};

// Weapon special (impulse 7) — cycle the boost level.  Sound and centreprint stay
// the server's; only the LEVEL is predicted, because the client's own pmove reads
// it through SH_JetTickGravity and would otherwise fly at the boost it started with
// no matter what the server said.
//
// Dispatched from CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL chain in
// client/cl_weapons.qc — that chain is a hand-written else-if, and this weapon was
// missing from it.
void() CSQC_PredictJetSpecial =
{
    SH_JetCycleBoost();
    CSQC_MarkPendingWeaponAck();
};

void() CSQC_PredictJetReload =
{
    SH_JetTryReload(csqc_pred_time);
};

float(float elapsed) CSQC_JetDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)   return JET_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_jetpack > 0) ? JET_SEQ_RELOAD : JET_SEQ_RELOAD_EMPTY;
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_jetpack > 0) ? JET_SEQ_SHOOT : JET_SEQ_SHOOT_EMPTY;
    return JET_SEQ_IDLE1;
};

void() CSQC_JetDropClear =
{
    self.mag_jetpack = 0;
    self.ammo_jetpack = 0;
    self.ammo_jetfuel = 0;
    // A dropped pack must not leave the client predicting low gravity.
    if (self.jet_grav_until > 0)
    {
        self.gravity = self.jet_grav_saved;
        self.jet_grav_until = 0;
    }
};

void() CSQC_JetEquip =
{
    self.weapon_name         = JET_DISPLAY_NAME;
    self.weapon_viewmodel    = JET_VIEWMODEL;
    self.weapon_worldmodel   = JET_WORLDMODEL;
    self.weapon_deploy_sound = JET_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictJetCommand;
    self.csqc_predict_reload = CSQC_PredictJetReload;
    self.csqc_display_frame  = CSQC_JetDisplayFrame;
    self.csqc_drop_clear     = CSQC_JetDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
