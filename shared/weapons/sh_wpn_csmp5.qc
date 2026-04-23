// ============================================================
//  shared/weapons/sh_wpn_csmp5.qc  -  CS MP5
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 120 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_mp5;
.float ammo_mp5;

// --- Animation frames ---
const float MP5_FRAME_INTERVAL        = 0.0333334;   // 1/30

const float MP5_DRAW_START            = 1;
const float MP5_DRAW_END              = 18;
const float MP5_DRAW_SLIDE_FRAME      = 4;

const float MP5_FIRE_START            = 19;
const float MP5_FIRE_END              = 32;
const float MP5_FIRE_DELAY            = 0.1;

const float MP5_RELOAD_START          = 61;
const float MP5_RELOAD_END            = 113;
const float MP5_RELOAD_CLIPOUT_FRAME  = 66;
const float MP5_RELOAD_CLIPIN_FRAME   = 84;
const float MP5_RELOAD_SLIDE_FRAME    = 100;
const float MP5_RELOAD_APPLY          = 100;

const float MP5_IDLE_FRAME            = 33;

const float MAX_MAG_MP5               = 30;
const float MAX_AMMO_MP5              = 120;

// --- Balance ---
const float MP5_BASE_SPREAD           = 0.01;
const float MP5_MOVE_SPREAD           = 0.06;
const float MP5_FULL_SPREAD_SPEED     = 320;
const float MP5_CLOSE_DAMAGE          = 12;
const float MP5_MIN_DAMAGE            = 6;
const float MP5_DAMAGE_FALLOFF_RANGE  = 2048;
const float MP5_DRYFIRE_DELAY         = 0.2;

// --- Pre-computed state durations ---
const float MP5_DRAW_DURATION         = (MP5_DRAW_END - MP5_DRAW_START) * MP5_FRAME_INTERVAL;
const float MP5_FIRE_DURATION         = (MP5_FIRE_END - MP5_FIRE_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_DURATION       = (MP5_RELOAD_END - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_APPLY_TIME     = (MP5_RELOAD_APPLY - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;

const string MP5_VIEWMODEL    = "models/weapons/wpn_csmp5/v_mp5.mdl";
const string MP5_WORLDMODEL   = "models/weapons/wpn_csmp5/w_mp5.mdl";
const string MP5_DEPLOY_SOUND = "";
const string MP5_DISPLAY_NAME = "MP5";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_MP5TickState =
{
    return SH_StandardTickState(now, mag_mp5, ammo_mp5, MAX_MAG_MP5,
        MP5_DRAW_DURATION, MP5_FIRE_DURATION,
        MP5_RELOAD_DURATION, MP5_RELOAD_APPLY_TIME);
};

float(float now) SH_MP5TryFire =
{
    return SH_StandardTryFire(now, mag_mp5, MP5_FIRE_DELAY, MP5_DRYFIRE_DELAY);
};

float(float now) SH_MP5TryReload =
{
    return SH_StandardTryReload(now, mag_mp5, ammo_mp5, MAX_MAG_MP5, MP5_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_MP5PickupCopy =
{ player.mag_mp5 = self.mag_mp5; player.ammo_mp5 = self.ammo_mp5; };

void() W_MP5Shoot =
{
    W_PenetratingHitscanShoot(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED,
        MP5_CLOSE_DAMAGE, MP5_MIN_DAMAGE, MP5_DAMAGE_FALLOFF_RANGE, 32, 0.96);
};

void() W_MP5Fire =
{
    float r = SH_MP5TryFire(time);
    if (r == 1)
    {
        self.weaponframe = MP5_FIRE_START;
        self.wep_nextframe = time + MP5_FRAME_INTERVAL;
        W_MP5Shoot();
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RED, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_MP5Reload =
{
    if (SH_MP5TryReload(time))
    { self.weaponframe = MP5_RELOAD_START; self.wep_nextframe = time + MP5_FRAME_INTERVAL; }
};

void() W_MP5Frame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += MP5_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW && self.weaponframe == MP5_DRAW_SLIDE_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == MP5_RELOAD_CLIPOUT_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == MP5_RELOAD_CLIPIN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipin.wav", 1, ATTN_NORM);
        if (self.weaponframe == MP5_RELOAD_SLIDE_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);
    }

    result = SH_MP5TickState(time);
    if (result & 1)
    { self.weaponframe = MP5_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_MP5Equip =
{
    W_StandardEquipSetup(MP5_VIEWMODEL, MP5_DISPLAY_NAME, MP5_DRAW_START,
        MP5_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_MP5Fire;
    self.reload   = W_MP5Reload;
    self.wepframe = W_MP5Frame;
    self.shoot    = W_MP5Shoot;
    W_SetCrosshairProfile(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_MP5Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_mp5 = self.mag_mp5; tgt.ammo_mp5 = self.ammo_mp5;
    self.mag_mp5 = 0; self.ammo_mp5 = 0;
    setmodel(tgt, "models/weapons/wpn_csmp5/w_mp5.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_csmp5"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSMP5; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_MP5Equip; tgt.weap_drop_func = W_MP5Drop;
    tgt.pickupcopy = W_MP5PickupCopy; tgt.touch = weapon_touch;
    tgt.dropped_spin = 1;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csmp5 =
{
    setmodel(self, "models/weapons/wpn_csmp5/w_mp5.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_csmp5"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSMP5; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_MP5Equip; self.weap_drop_func = W_MP5Drop;
    self.pickupcopy = W_MP5PickupCopy; self.touch = weapon_touch;
    self.dropped_spin = 1;
    self.mag_mp5 = MAX_MAG_MP5; self.ammo_mp5 = MAX_AMMO_MP5;
    W_RegisterMapWeapon(weapon_csmp5);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float MP5_DRAW_SLIDE_TIME = (MP5_DRAW_SLIDE_FRAME - MP5_DRAW_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_CLIPOUT_TIME = (MP5_RELOAD_CLIPOUT_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_CLIPIN_TIME = (MP5_RELOAD_CLIPIN_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_SLIDE_TIME = (MP5_RELOAD_SLIDE_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;

float csqc_mp5_draw_snd_played;
float csqc_mp5_reload_snd_stage;

void() CSQC_PredictMP5Command =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_MP5TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED,
                    MP5_CLOSE_DAMAGE, MP5_MIN_DAMAGE, MP5_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/redcasing.mdl",
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
    // Predicted draw slide sound
    if (self.weaponstate == WS_DRAW && !csqc_mp5_draw_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= MP5_DRAW_SLIDE_TIME)
        { localsound("sounds/weapons/wpn_csmp5/slideback.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_draw_snd_played = TRUE; }
    }
    else if (self.weaponstate != WS_DRAW)
        csqc_mp5_draw_snd_played = FALSE;

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_mp5_reload_snd_stage < 1 && reload_elapsed >= MP5_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csmp5/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_mp5_reload_snd_stage = 1;
        }
        if (csqc_mp5_reload_snd_stage < 2 && reload_elapsed >= MP5_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csmp5/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_reload_snd_stage = 2; }
        if (csqc_mp5_reload_snd_stage < 3 && reload_elapsed >= MP5_RELOAD_SLIDE_TIME)
        { localsound("sounds/weapons/wpn_csmp5/slideback.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_reload_snd_stage = 3; }
    }

    SH_MP5TickState(csqc_pred_time);
};

void() CSQC_PredictMP5Reload =
{
    if (SH_MP5TryReload(csqc_pred_time))
    { csqc_mp5_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_MP5DisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, MP5_FRAME_INTERVAL,
        MP5_DRAW_START, MP5_DRAW_END,
        MP5_FIRE_START, MP5_FIRE_END,
        MP5_RELOAD_START, MP5_RELOAD_END,
        MP5_IDLE_FRAME);
};

void() CSQC_MP5DropClear =
{
	self.mag_mp5 = 0;
	self.ammo_mp5 = 0;
};

void() CSQC_MP5Equip =
{
	self.weapon_name         = MP5_DISPLAY_NAME;
	self.weapon_viewmodel    = MP5_VIEWMODEL;
	self.weapon_worldmodel   = MP5_WORLDMODEL;
	self.weapon_deploy_sound = MP5_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictMP5Command;
	self.csqc_predict_reload = CSQC_PredictMP5Reload;
	self.csqc_display_frame  = CSQC_MP5DisplayFrame;
	self.csqc_drop_clear     = CSQC_MP5DropClear;
};

#endif // CSQC
