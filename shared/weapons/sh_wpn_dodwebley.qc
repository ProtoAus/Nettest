// ============================================================
//  shared/weapons/sh_wpn_dodwebley.qc  -  Day of Defeat Webley Mk VI
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 18 reserve, double-action .455 revolver
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_webley.mdl, models/w_webley.mdl,
// models/p_webley.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_webley.mdl — only FOUR sequences, the smallest
// set of the twelve:
//   [0] idle    12fps    2f  0.083s
//   [1] shoot   32fps   31f  0.938s   f0 5001 (muzzleflash)
//   [2] reload  35fps  140f  3.971s   -- break action, all six at once
//         f14  5004 "weapons/colt_reload_clipin.wav"  frac 0.1007
//         f85  5004 "weapons/colt_reload_clipin.wav"  frac 0.6115
//         f108 5004 "weapons/colt_reload_clipin.wav"  frac 0.7770
//         f123 5004 "weapons/colt_reload_clipin.wav"  frac 0.8849
//   [3] draw    30fps   28f  0.900s
//         f1  5004 "weapons/rifleselect.wav"          frac 0.0370
//         f17 5004 "weapons/colt_reload_clipin.wav"   frac 0.6296
//
// NO shoot_empty AND NO empty_idle, which is correct for a revolver -- there is
// no slide to lock back -- so unlike the two automatics this one has a single
// firing take and a single reload.  It also means the near-four-second reload
// is unconditional: a Webley with one round left costs the same to top up as an
// empty one, which is the real trade-off of a break-action and is left in.

// --- Ammo fields ---
.float mag_dodwebley;
.float ammo_dodwebley;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODWEBLEY_SEQ_IDLE   = 0;
const float DODWEBLEY_SEQ_SHOOT  = 1;
const float DODWEBLEY_SEQ_RELOAD = 2;
const float DODWEBLEY_SEQ_DRAW   = 3;

const float DODWEBLEY_FRAME_INTERVAL = 0.0333334;
const float DODWEBLEY_FIRE_DELAY     = 0.32;
const float DODWEBLEY_DRYFIRE_DELAY  = 0.20;

const float DODWEBLEY_DRAW_F_SELECT   = 0.0370;   // frame 1   / 27
const float DODWEBLEY_DRAW_F_CLOSE    = 0.6296;   // frame 17  / 27
const float DODWEBLEY_RELOAD_F_BREAK  = 0.1007;   // frame 14  / 139
const float DODWEBLEY_RELOAD_F_LOAD1  = 0.6115;   // frame 85  / 139
const float DODWEBLEY_RELOAD_F_LOAD2  = 0.7770;   // frame 108 / 139
const float DODWEBLEY_RELOAD_F_CLOSE  = 0.8849;   // frame 123 / 139

const float DODWEBLEY_IDLE_REARM_MIN = 10;
const float DODWEBLEY_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODWEBLEY  = 6;
const float MAX_AMMO_DODWEBLEY = 18;

// --- Balance ---
//
// The heaviest-hitting pistol in this set and the slowest, which is what a .455
// service revolver is.  38 close puts it one step above the Deagle's 35 -- a
// huge slow bullet -- but it sheds to 20 and it sheds early (1800, the shortest
// falloff of the three DoD pistols), and 0.32s between shots is slower than the
// Deagle's 0.30.  Six rounds and a four-second reload are the rest of the price.
const float DODWEBLEY_BASE_SPREAD          = 0.009;
const float DODWEBLEY_MOVE_SPREAD          = 0.060;
const float DODWEBLEY_FULL_SPREAD_SPEED    = 320;
const float DODWEBLEY_CLOSE_DAMAGE         = 38;
const float DODWEBLEY_MIN_DAMAGE           = 20;
const float DODWEBLEY_DAMAGE_FALLOFF_RANGE = 1800;
const float DODWEBLEY_KICK_PITCH    = 1.60;
const float DODWEBLEY_KICK_VARIANCE = 0.45;
const float DODWEBLEY_KICK_STRENGTH = 1.45;

const float DODWEBLEY_MUZZLE_FORWARD = 24;
const float DODWEBLEY_MUZZLE_RIGHT   = 4.5;
const float DODWEBLEY_MUZZLE_DOWN    = 3.0;

const string DODWEBLEY_VIEWMODEL    = "models/v_webley.mdl";
const string DODWEBLEY_WORLDMODEL   = "models/w_webley.mdl";
const string DODWEBLEY_DEPLOY_SOUND = "";
const string DODWEBLEY_DISPLAY_NAME = "Webley";

.float dodwebley_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodWebleySeqIdle   = { return SH_SeqForName(DODWEBLEY_VIEWMODEL, "idle",   DODWEBLEY_SEQ_IDLE); };
float() SH_DodWebleySeqShoot  = { return SH_SeqForName(DODWEBLEY_VIEWMODEL, "shoot",  DODWEBLEY_SEQ_SHOOT); };
float() SH_DodWebleySeqReload = { return SH_SeqForName(DODWEBLEY_VIEWMODEL, "reload", DODWEBLEY_SEQ_RELOAD); };
float() SH_DodWebleySeqDraw   = { return SH_SeqForName(DODWEBLEY_VIEWMODEL, "draw",   DODWEBLEY_SEQ_DRAW); };

float() SH_DodWebleyDrawDuration   = { return SH_SeqDuration(DODWEBLEY_VIEWMODEL, SH_DodWebleySeqDraw(),   0.900); };
float() SH_DodWebleyReloadDuration = { return SH_SeqDuration(DODWEBLEY_VIEWMODEL, SH_DodWebleySeqReload(), 3.971); };

// ============================================================
//  SHARED - state machine
// ============================================================

// The rounds land at RELOAD_F_CLOSE, when the cylinder snaps shut -- not at the
// end.  There is only one reload take here, so nothing branches on the magazine
// and applying early is free (the Colt and Luger cannot do this; see
// SH_DodColtTickState).
float(float now) SH_DodWebleyTickState =
{
    float rel = SH_DodWebleyReloadDuration();
    return SH_StandardTickState(now, mag_dodwebley, ammo_dodwebley, MAX_MAG_DODWEBLEY,
        SH_DodWebleyDrawDuration(),
        SH_SeqDuration(DODWEBLEY_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODWEBLEY_RELOAD_F_CLOSE);
};

float(float now) SH_DodWebleyTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodwebley, DODWEBLEY_FIRE_DELAY, DODWEBLEY_DRYFIRE_DELAY);
};

float(float now) SH_DodWebleyTryReload =
{
    return SH_StandardTryReload(now, mag_dodwebley, ammo_dodwebley, MAX_MAG_DODWEBLEY,
        SH_DodWebleyReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodWebleyPickupCopy =
{
    player.mag_dodwebley  = self.mag_dodwebley;
    player.ammo_dodwebley = self.ammo_dodwebley;
};

void() W_DodWebleyShoot =
{
    W_PenetratingHitscanShoot(DODWEBLEY_BASE_SPREAD, DODWEBLEY_MOVE_SPREAD, DODWEBLEY_FULL_SPREAD_SPEED,
        DODWEBLEY_CLOSE_DAMAGE, DODWEBLEY_MIN_DAMAGE, DODWEBLEY_DAMAGE_FALLOFF_RANGE, 28, 0.95,
        DODWEBLEY_KICK_PITCH, DODWEBLEY_KICK_VARIANCE, DODWEBLEY_KICK_STRENGTH);
};

void() W_DodWebleyFire =
{
    float r = SH_DodWebleyTryFire(time);

    if (r == 1)
    {
        self.weaponframe         = SH_DodWebleySeqShoot();
        self.wep_nextframe       = time + DODWEBLEY_FRAME_INTERVAL;
        self.dodwebley_snd_stage = 0;

        W_DodWebleyShoot();

        sound(self, CHAN_WEAPON, "weapons/webley_shoot.wav", 1, ATTN_NORM);
        // NO W_ShellEffect: a revolver holds its brass in the cylinder until the
        // break-open on reload.  The empties come out with the reload instead.
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodWebleyReload =
{
    if (SH_DodWebleyTryReload(time))
    {
        self.weaponframe         = SH_DodWebleySeqReload();
        self.wep_nextframe       = time + DODWEBLEY_FRAME_INTERVAL;
        self.dodwebley_snd_stage = 0;
    }
};

void() W_DodWebleyFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODWEBLEY_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodWebleyDrawDuration() * DODWEBLEY_DRAW_F_SELECT
            && self.dodwebley_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 1;
        }
        if (elapsed >= SH_DodWebleyDrawDuration() * DODWEBLEY_DRAW_F_CLOSE
            && self.dodwebley_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodWebleyReloadDuration();

        if (elapsed >= rel * DODWEBLEY_RELOAD_F_BREAK && self.dodwebley_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 1;
        }
        if (elapsed >= rel * DODWEBLEY_RELOAD_F_LOAD1 && self.dodwebley_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 2;
        }
        if (elapsed >= rel * DODWEBLEY_RELOAD_F_LOAD2 && self.dodwebley_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 3;
        }
        if (elapsed >= rel * DODWEBLEY_RELOAD_F_CLOSE && self.dodwebley_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodwebley_snd_stage = 4;
        }
    }

    result = SH_DodWebleyTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_DodWebleySeqIdle();
        self.wep_nextframe       = 0;
        self.dodwebley_snd_stage = 0;
    }
};

void() W_DodWebleyEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodwebley", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODWEBLEY_VIEWMODEL, DODWEBLEY_DISPLAY_NAME, SH_DodWebleySeqDraw(),
        DODWEBLEY_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodWebleyFire;
    self.reload   = W_DodWebleyReload;
    self.wepframe = W_DodWebleyFrame;
    self.shoot    = W_DodWebleyShoot;
    self.dodwebley_snd_stage = 0;
    W_SetCrosshairProfile(DODWEBLEY_BASE_SPREAD, DODWEBLEY_MOVE_SPREAD, DODWEBLEY_FULL_SPREAD_SPEED, 1.3, TRUE);
};

void() W_DodWebleyDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodwebley  = self.mag_dodwebley;
    tgt.ammo_dodwebley = self.ammo_dodwebley;

    self.mag_dodwebley  = 0;
    self.ammo_dodwebley = 0;

    setmodel(tgt, DODWEBLEY_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_webley";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODWEBLEY;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_DodWebleyEquip;
    tgt.weap_drop_func = W_DodWebleyDrop;
    tgt.pickupcopy     = W_DodWebleyPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Day of Defeat never gave the British weapons map entities -- they arrive from
// the class menu -- so weapon_webley is this mod's spelling rather than one out
// of dod.fgd.  It was unused in this tree.
void() weapon_webley =
{
    setmodel(self, DODWEBLEY_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_webley";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODWEBLEY;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_DodWebleyEquip;
    self.weap_drop_func = W_DodWebleyDrop;
    self.pickupcopy     = W_DodWebleyPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodwebley  = MAX_MAG_DODWEBLEY;
    self.ammo_dodwebley = MAX_AMMO_DODWEBLEY;
    W_RegisterMapWeapon(weapon_webley);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodwebley_snd_stage;
float csqc_dodwebley_snd_action;

void() CSQC_PredictDodWebleyCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodwebley_snd_action)
    {
        csqc_dodwebley_snd_action = predicted_player.wep_action_id;
        csqc_dodwebley_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodWebleyTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/webley_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODWEBLEY_BASE_SPREAD, DODWEBLEY_MOVE_SPREAD, DODWEBLEY_FULL_SPREAD_SPEED,
                    DODWEBLEY_CLOSE_DAMAGE, DODWEBLEY_MIN_DAMAGE, DODWEBLEY_DAMAGE_FALLOFF_RANGE, 28, 0.95,
                    DODWEBLEY_KICK_PITCH, DODWEBLEY_KICK_VARIANCE, DODWEBLEY_KICK_STRENGTH);
                // No casing — see W_DodWebleyFire.
                CSQC_MuzzleFlashAtMuzzle(DODWEBLEY_MUZZLE_FORWARD, DODWEBLEY_MUZZLE_RIGHT,
                    DODWEBLEY_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODWEBLEY_MUZZLE_FORWARD, DODWEBLEY_MUZZLE_RIGHT,
                    DODWEBLEY_MUZZLE_DOWN, self.wep_action_id, 2);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            float dr = SH_DodWebleyDrawDuration();
            if (csqc_dodwebley_snd_stage < 1 && elapsed >= dr * DODWEBLEY_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 1;
            }
            if (csqc_dodwebley_snd_stage < 2 && elapsed >= dr * DODWEBLEY_DRAW_F_CLOSE)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodWebleyReloadDuration();

            if (csqc_dodwebley_snd_stage < 1 && elapsed >= rel * DODWEBLEY_RELOAD_F_BREAK)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 1;
            }
            if (csqc_dodwebley_snd_stage < 2 && elapsed >= rel * DODWEBLEY_RELOAD_F_LOAD1)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 2;
            }
            if (csqc_dodwebley_snd_stage < 3 && elapsed >= rel * DODWEBLEY_RELOAD_F_LOAD2)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 3;
            }
            if (csqc_dodwebley_snd_stage < 4 && elapsed >= rel * DODWEBLEY_RELOAD_F_CLOSE)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodwebley_snd_stage = 4;
            }
        }
    }

    SH_DodWebleyTickState(csqc_pred_time);
};

void() CSQC_PredictDodWebleyReload =
{
    if (SH_DodWebleyTryReload(csqc_pred_time))
    {
        csqc_dodwebley_snd_stage  = 0;
        csqc_dodwebley_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodWebleyDisplayFrame =
{
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODWEBLEY, predicted_player.weaponstate,
                                   SH_DodWebleySeqIdle(), SH_DodWebleySeqIdle(),
                                   DODWEBLEY_IDLE_REARM_MIN, DODWEBLEY_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodWebleySeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodWebleySeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodWebleySeqShoot();

    return SH_DodWebleySeqIdle();
};

void() CSQC_DodWebleyDropClear =
{
    self.mag_dodwebley  = 0;
    self.ammo_dodwebley = 0;
};

void() CSQC_DodWebleyEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodwebley", SCOPE_CLASS_NONE);
    self.weapon_name         = DODWEBLEY_DISPLAY_NAME;
    self.weapon_viewmodel    = DODWEBLEY_VIEWMODEL;
    self.weapon_worldmodel   = DODWEBLEY_WORLDMODEL;
    self.weapon_deploy_sound = DODWEBLEY_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodWebleyCommand;
    self.csqc_predict_reload = CSQC_PredictDodWebleyReload;
    self.csqc_display_frame  = CSQC_DodWebleyDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodWebleyDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
