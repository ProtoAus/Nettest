// ============================================================
//  shared/weapons/sh_wpn_csg3sg1.qc  -  CS G3SG1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 60 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_g3sg1;
.float ammo_g3sg1;

// --- Animation frames (placeholder — user will tune) ---
const float G3SG1_FRAME_INTERVAL      = 0.0333334;   // 1/30

const float G3SG1_DRAW_START          = 1;
const float G3SG1_DRAW_END            = 20;

const float G3SG1_FIRE_START          = 21;
const float G3SG1_FIRE_END            = 31;
const float G3SG1_FIRE_DELAY          = 0.25;

const float G3SG1_RELOAD_START        = 44;
const float G3SG1_RELOAD_END          = 136;
const float G3SG1_RELOAD_SLIDE1_FRAME = 56;
const float G3SG1_RELOAD_CLIPOUT      = 80;
const float G3SG1_RELOAD_CLIPIN       = 99;
const float G3SG1_RELOAD_APPLY        = 105;
const float G3SG1_RELOAD_SLIDE2_FRAME = 120;

const float G3SG1_IDLE_FRAME          = 137;

const float MAX_MAG_G3SG1             = 20;
const float MAX_AMMO_G3SG1            = 60;

// --- Balance ---
const float G3SG1_BASE_SPREAD          = 0.02;
const float G3SG1_MOVE_SPREAD          = 0.08;
const float G3SG1_FULL_SPREAD_SPEED    = 320;
const float G3SG1_CLOSE_DAMAGE         = 60;
const float G3SG1_MIN_DAMAGE           = 40;
const float G3SG1_DAMAGE_FALLOFF_RANGE = 4096;
const float G3SG1_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float G3SG1_DRAW_DURATION      = (G3SG1_DRAW_END - G3SG1_DRAW_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_FIRE_DURATION      = (G3SG1_FIRE_END - G3SG1_FIRE_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_RELOAD_DURATION    = (G3SG1_RELOAD_END - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_RELOAD_APPLY_TIME  = (G3SG1_RELOAD_APPLY - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;

const string G3SG1_VIEWMODEL    = "models/weapons/wpn_csg3sg1/v_g3sg1.mdl";
const string G3SG1_WORLDMODEL   = "models/weapons/wpn_csg3sg1/w_g3sg1.mdl";
const string G3SG1_DEPLOY_SOUND = "";
const string G3SG1_DISPLAY_NAME = "G3SG1";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_G3SG1TickState =
{
    return SH_StandardTickState(now, mag_g3sg1, ammo_g3sg1, MAX_MAG_G3SG1,
        G3SG1_DRAW_DURATION, G3SG1_FIRE_DURATION,
        G3SG1_RELOAD_DURATION, G3SG1_RELOAD_APPLY_TIME);
};

// Don't clear zoomstage here — Shoot needs it for spread.
// Cleared in Fire/prediction AFTER the shot.
float(float now) SH_G3SG1TryFire =
{
    return SH_StandardTryFire(now, mag_g3sg1, G3SG1_FIRE_DELAY, G3SG1_DRYFIRE_DELAY);
};

float(float now) SH_G3SG1TryReload =
{
    float r = SH_StandardTryReload(now, mag_g3sg1, ammo_g3sg1, MAX_MAG_G3SG1);
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

float(float now) SH_G3SG1TryAltFire =
{
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_G3SG1PickupCopy =
{
    player.mag_g3sg1  = self.mag_g3sg1;
    player.ammo_g3sg1 = self.ammo_g3sg1;
};

void() W_G3SG1Shoot =
{
    // Scoped: zero base spread, movement still applies
    if (self.zoomstage > 0)
        W_StandardHitscanShoot(0, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED,
            G3SG1_CLOSE_DAMAGE, G3SG1_MIN_DAMAGE, G3SG1_DAMAGE_FALLOFF_RANGE);
    else
        W_StandardHitscanShoot(G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED,
            G3SG1_CLOSE_DAMAGE, G3SG1_MIN_DAMAGE, G3SG1_DAMAGE_FALLOFF_RANGE);
};

void() W_G3SG1Fire =
{
    float r = SH_G3SG1TryFire(time);
    if (r == 1)
    {
        self.weaponframe   = G3SG1_FIRE_START;
        self.wep_nextframe = time + G3SG1_FRAME_INTERVAL;
        W_G3SG1Shoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csg3sg1/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_G3SG1AltFire =
{
    if (SH_G3SG1TryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_G3SG1Reload =
{
    if (SH_G3SG1TryReload(time))
    {
        self.weaponframe   = G3SG1_RELOAD_START;
        self.wep_nextframe = time + G3SG1_FRAME_INTERVAL;
        self.sv_zoomstage = 0;
    }
};

void() W_G3SG1Frame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += G3SG1_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == G3SG1_RELOAD_SLIDE1_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/slide.wav", 1, ATTN_NORM);
        if (self.weaponframe == G3SG1_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == G3SG1_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/clipin.wav", 1, ATTN_NORM);
        if (self.weaponframe == G3SG1_RELOAD_SLIDE2_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/slide.wav", 1, ATTN_NORM);
    }

    result = SH_G3SG1TickState(time);
    if (result & 1)
    { self.weaponframe = G3SG1_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_G3SG1Equip =
{
    W_StandardEquipSetup(G3SG1_VIEWMODEL, G3SG1_DISPLAY_NAME, G3SG1_DRAW_START,
        G3SG1_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_G3SG1Fire;
    self.reload   = W_G3SG1Reload;
    self.wepframe = W_G3SG1Frame;
    self.altfire  = W_G3SG1AltFire;
    self.shoot    = W_G3SG1Shoot;
    W_ClearZoom();
    W_SetCrosshairProfile(G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_G3SG1Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_g3sg1  = self.mag_g3sg1;
    tgt.ammo_g3sg1 = self.ammo_g3sg1;
    self.mag_g3sg1  = 0;
    self.ammo_g3sg1 = 0;

    setmodel(tgt, "models/weapons/wpn_csg3sg1/w_g3sg1.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_g3sg1";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_G3SG1;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_G3SG1Equip;
    tgt.weap_drop_func = W_G3SG1Drop;
    tgt.pickupcopy   = W_G3SG1PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_g3sg1 =
{
    setmodel(self, "models/weapons/wpn_csg3sg1/w_g3sg1.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_g3sg1";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_G3SG1;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_G3SG1Equip;
    self.weap_drop_func = W_G3SG1Drop;
    self.pickupcopy    = W_G3SG1PickupCopy;
    self.touch         = weapon_touch;
    self.mag_g3sg1     = MAX_MAG_G3SG1;
    self.ammo_g3sg1    = MAX_AMMO_G3SG1;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float G3SG1_RELOAD_SLIDE1_TIME = (G3SG1_RELOAD_SLIDE1_FRAME - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_RELOAD_CLIPOUT_TIME = (G3SG1_RELOAD_CLIPOUT - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_RELOAD_CLIPIN_TIME = (G3SG1_RELOAD_CLIPIN - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;
const float G3SG1_RELOAD_SLIDE2_TIME = (G3SG1_RELOAD_SLIDE2_FRAME - G3SG1_RELOAD_START) * G3SG1_FRAME_INTERVAL;

float csqc_g3sg1_reload_snd_stage;

void() CSQC_PredictG3SG1Command =
{
    float r;

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_G3SG1TryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_G3SG1TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csg3sg1/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(self.zoomstage > 0 ? 0 : G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_g3sg1_reload_snd_stage < 1 && reload_elapsed >= G3SG1_RELOAD_SLIDE1_TIME)
        { localsound("sounds/weapons/wpn_csg3sg1/slide.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 1; }
        if (csqc_g3sg1_reload_snd_stage < 2 && reload_elapsed >= G3SG1_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csg3sg1/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_g3sg1_reload_snd_stage = 2;
        }
        if (csqc_g3sg1_reload_snd_stage < 3 && reload_elapsed >= G3SG1_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csg3sg1/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 3; }
        if (csqc_g3sg1_reload_snd_stage < 4 && reload_elapsed >= G3SG1_RELOAD_SLIDE2_TIME)
        { localsound("sounds/weapons/wpn_csg3sg1/slide.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 4; }
    }

    SH_G3SG1TickState(csqc_pred_time);
};

void() CSQC_PredictG3SG1Reload =
{
    if (SH_G3SG1TryReload(csqc_pred_time))
    { csqc_g3sg1_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_G3SG1DisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, G3SG1_FRAME_INTERVAL,
        G3SG1_DRAW_START, G3SG1_DRAW_END,
        G3SG1_FIRE_START, G3SG1_FIRE_END,
        G3SG1_RELOAD_START, G3SG1_RELOAD_END,
        G3SG1_IDLE_FRAME);
};

void() CSQC_G3SG1DropClear =
{
	self.mag_g3sg1 = 0;
	self.ammo_g3sg1 = 0;
	self.zoomstage = 0;
};

void() CSQC_G3SG1Equip =
{
	self.weapon_name         = G3SG1_DISPLAY_NAME;
	self.weapon_viewmodel    = G3SG1_VIEWMODEL;
	self.weapon_worldmodel   = G3SG1_WORLDMODEL;
	self.weapon_deploy_sound = G3SG1_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictG3SG1Command;
	self.csqc_predict_reload = CSQC_PredictG3SG1Reload;
	self.csqc_display_frame  = CSQC_G3SG1DisplayFrame;
	self.csqc_drop_clear     = CSQC_G3SG1DropClear;
};

#endif // CSQC
