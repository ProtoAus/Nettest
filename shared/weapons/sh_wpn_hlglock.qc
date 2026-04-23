// ============================================================
//  shared/weapons/sh_wpn_hlglock.qc  -  HL Glock (Semi-Auto Pistol)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 17-round magazine, 250 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlglock;
.float ammo_hlglock;

// --- Animation frames ---
const float HLGLOCK_DRAW_FRAME_INTERVAL  = 0.0625;  // 16fps for draw
const float HLGLOCK_FRAME_INTERVAL       = 0.05;    // 20fps

const float HLGLOCK_DRAW_START           = 0;
const float HLGLOCK_DRAW_END             = 15;

const float HLGLOCK_FIRE_START           = 16;
const float HLGLOCK_FIRE_END             = 27;
const float HLGLOCK_FIRE_DELAY           = 0.3;

const float HLGLOCK_RELOAD_START         = 40;
const float HLGLOCK_RELOAD_END           = 81;
const float HLGLOCK_RELOAD_FRAME_INTERVAL = 0.0556; // 18fps
const float HLGLOCK_RELOAD_SND1_FRAME    = 50;
const float HLGLOCK_RELOAD_SND2_FRAME    = 70;

const float HLGLOCK_IDLE_FRAME           = 124;

const float MAX_MAG_HLGLOCK              = 17;
const float MAX_AMMO_HLGLOCK             = 250;

// --- Balance ---
const float HLGLOCK_BASE_SPREAD          = 0.01;
const float HLGLOCK_MOVE_SPREAD          = 0.04;
const float HLGLOCK_FULL_SPREAD_SPEED    = 320;
const float HLGLOCK_CLOSE_DAMAGE         = 16;
const float HLGLOCK_MIN_DAMAGE           = 8;
const float HLGLOCK_DAMAGE_FALLOFF_RANGE = 2048;
const float HLGLOCK_DRYFIRE_DELAY        = 0.2;
const float HLGLOCK_ALT_FIRE_DELAY      = 0.2;   // auto-fire mode (faster)
const float HLGLOCK_ALT_SPREAD          = 0.04;  // wider spread in auto mode

// --- Pre-computed state durations ---
const float HLGLOCK_DRAW_DURATION        = (HLGLOCK_DRAW_END - HLGLOCK_DRAW_START) * HLGLOCK_DRAW_FRAME_INTERVAL;
const float HLGLOCK_FIRE_DURATION        = (HLGLOCK_FIRE_END - HLGLOCK_FIRE_START) * HLGLOCK_FRAME_INTERVAL;
const float HLGLOCK_RELOAD_DURATION      = (HLGLOCK_RELOAD_END - HLGLOCK_RELOAD_START) * HLGLOCK_RELOAD_FRAME_INTERVAL;
const float HLGLOCK_RELOAD_APPLY_TIME    = HLGLOCK_RELOAD_DURATION;  // apply at end

const string HLGLOCK_VIEWMODEL    = "models/weapons/wpn_hlglock/v_glock.mdl";
const string HLGLOCK_WORLDMODEL   = "models/weapons/wpn_hlglock/w_glock.mdl";
const string HLGLOCK_DEPLOY_SOUND = "";
const string HLGLOCK_DISPLAY_NAME = "HL GLOCK";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_HLGlockTickState =
{
    return SH_StandardTickState(now, mag_hlglock, ammo_hlglock, MAX_MAG_HLGLOCK,
        HLGLOCK_DRAW_DURATION, HLGLOCK_FIRE_DURATION,
        HLGLOCK_RELOAD_DURATION, HLGLOCK_RELOAD_APPLY_TIME);
};

float(float now) SH_HLGlockTryFire =
{
    return SH_StandardTryFire(now, mag_hlglock, HLGLOCK_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);
};

float(float now) SH_HLGlockTryReload =
{
    return SH_StandardTryReload(now, mag_hlglock, ammo_hlglock, MAX_MAG_HLGLOCK, HLGLOCK_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLGlockPickupCopy =
{
    player.mag_hlglock  = self.mag_hlglock;
    player.ammo_hlglock = self.ammo_hlglock;
};

void() W_HLGlockShoot =
{
    W_PenetratingHitscanShoot(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
        HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94);
};

void() W_HLGlockFire =
{
    float r = SH_HLGlockTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = HLGLOCK_FIRE_START;
        self.wep_nextframe = time + HLGLOCK_FRAME_INTERVAL;

        W_HLGlockShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlglock/fire.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_HLGlockAltFire =
{
    float r = SH_StandardTryFire(time, mag_hlglock, HLGLOCK_ALT_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);

    if (r == 1)
    {
        self.weaponframe   = HLGLOCK_FIRE_START;
        self.wep_nextframe = time + HLGLOCK_FRAME_INTERVAL;

        // Wider spread in auto mode
        W_PenetratingHitscanShoot(HLGLOCK_ALT_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
            HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94);

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlglock/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLGlockReload =
{
    if (SH_HLGlockTryReload(time))
    {
        self.weaponframe   = HLGLOCK_RELOAD_START;
        self.wep_nextframe = time + HLGLOCK_RELOAD_FRAME_INTERVAL;
    }
};

void() W_HLGlockFrame =
{
    float result;

    self.weaponframe  += 1;

    // Use appropriate frame interval per state
    if (self.weaponstate == WS_DRAW)
        self.wep_nextframe += HLGLOCK_DRAW_FRAME_INTERVAL;
    else if (self.weaponstate == WS_RELOAD)
        self.wep_nextframe += HLGLOCK_RELOAD_FRAME_INTERVAL;
    else
        self.wep_nextframe += HLGLOCK_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == HLGLOCK_RELOAD_SND1_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlglock/reload1.wav", 1, ATTN_NORM);
        if (self.weaponframe == HLGLOCK_RELOAD_SND2_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlglock/reload2.wav", 1, ATTN_NORM);
    }

    result = SH_HLGlockTickState(time);
    if (result & 1)
    {
        self.weaponframe   = HLGLOCK_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_HLGlockEquip =
{
    W_StandardEquipSetup(HLGLOCK_VIEWMODEL, HLGLOCK_DISPLAY_NAME, HLGLOCK_DRAW_START,
        HLGLOCK_DRAW_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HLGlockFire;
    self.altfire  = W_HLGlockAltFire;
    self.reload   = W_HLGlockReload;
    self.wepframe = W_HLGlockFrame;
    self.shoot    = W_HLGlockShoot;
    W_SetCrosshairProfile(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_HLGlockDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlglock  = self.mag_hlglock;
    tgt.ammo_hlglock = self.ammo_hlglock;

    self.mag_hlglock  = 0;
    self.ammo_hlglock = 0;

    setmodel(tgt, "models/weapons/wpn_hlglock/w_glock.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_hlglock";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLGLOCK;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_HLGlockEquip;
    tgt.weap_drop_func = W_HLGlockDrop;
    tgt.pickupcopy   = W_HLGlockPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlglock =
{
    setmodel(self, "models/weapons/wpn_hlglock/w_glock.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_hlglock";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLGLOCK;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_HLGlockEquip;
    self.weap_drop_func = W_HLGlockDrop;
    self.pickupcopy    = W_HLGlockPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlglock   = MAX_MAG_HLGLOCK;
    self.ammo_hlglock  = MAX_AMMO_HLGLOCK;
    W_RegisterMapWeapon(weapon_hlglock);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Pre-computed reload sound times (elapsed from reload start)
const float HLGLOCK_RELOAD_SND1_TIME = (HLGLOCK_RELOAD_SND1_FRAME - HLGLOCK_RELOAD_START) * HLGLOCK_RELOAD_FRAME_INTERVAL;
const float HLGLOCK_RELOAD_SND2_TIME = (HLGLOCK_RELOAD_SND2_FRAME - HLGLOCK_RELOAD_START) * HLGLOCK_RELOAD_FRAME_INTERVAL;

float csqc_hlglock_reload_snd_stage;

void() CSQC_PredictHLGlockCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_HLGlockTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_hlglock/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
                    HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Alt-fire: auto mode (button 4 = +attack2)
    if (input_buttons & 4)
    {
        r = SH_StandardTryFire(csqc_pred_time, mag_hlglock, HLGLOCK_ALT_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_hlglock/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(HLGLOCK_ALT_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
                    HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_hlglock_reload_snd_stage < 1 && reload_elapsed >= HLGLOCK_RELOAD_SND1_TIME)
        {
            localsound("sounds/weapons/wpn_hlglock/reload1.wav"); CSQC_RecordPredictedAutoSound();
            csqc_hlglock_reload_snd_stage = 1;
        }
        if (csqc_hlglock_reload_snd_stage < 2 && reload_elapsed >= HLGLOCK_RELOAD_SND2_TIME)
        { localsound("sounds/weapons/wpn_hlglock/reload2.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlglock_reload_snd_stage = 2; }
    }

    SH_HLGlockTickState(csqc_pred_time);
};

void() CSQC_PredictHLGlockReload =
{
    if (SH_HLGlockTryReload(csqc_pred_time))
    { csqc_hlglock_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_HLGlockDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = HLGLOCK_DRAW_START + elapsed / HLGLOCK_DRAW_FRAME_INTERVAL; return bound(HLGLOCK_DRAW_START, frame, HLGLOCK_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = HLGLOCK_FIRE_START + elapsed / HLGLOCK_FRAME_INTERVAL; return bound(HLGLOCK_FIRE_START, frame, HLGLOCK_FIRE_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    { frame = HLGLOCK_RELOAD_START + elapsed / HLGLOCK_RELOAD_FRAME_INTERVAL; return bound(HLGLOCK_RELOAD_START, frame, HLGLOCK_RELOAD_END - 1); }
    return HLGLOCK_IDLE_FRAME;
};

void() CSQC_HLGlockDropClear =
{
	self.mag_hlglock = 0;
	self.ammo_hlglock = 0;
};

void() CSQC_HLGlockEquip =
{
	self.weapon_name         = HLGLOCK_DISPLAY_NAME;
	self.weapon_viewmodel    = HLGLOCK_VIEWMODEL;
	self.weapon_worldmodel   = HLGLOCK_WORLDMODEL;
	self.weapon_deploy_sound = HLGLOCK_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLGlockCommand;
	self.csqc_predict_reload = CSQC_PredictHLGlockReload;
	self.csqc_display_frame  = CSQC_HLGlockDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLGlockDropClear;
};

#endif // CSQC
