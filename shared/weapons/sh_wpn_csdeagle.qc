// ============================================================
//  shared/weapons/sh_wpn_csdeagle.qc  -  Desert Eagle
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 35 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
//  Shared logic runs on both sides; #ifdef gates server-only
//  and client-only sections.
// ============================================================

// --- Ammo fields ---
.float mag_deagle;
.float ammo_deagle;

// --- Animation frames ---
const float DEAGLE_FIRE_DELAY        = 0.3;
const float DEAGLE_FRAME_INTERVAL    = 1/30;   // 1/30

const float DEAGLE_DRAW_START        = 151;
const float DEAGLE_DRAW_END          = 180;
const float DEAGLE_DRAW_SND_FRAME    = 155;

const float DEAGLE_FIRE_START        = 2;
const float DEAGLE_FIRE_END          = 32;

const float DEAGLE_RELOAD_START      = 84;
const float DEAGLE_RELOAD_END        = 148;
const float DEAGLE_RELOAD_CLIPOUT    = 87;
const float DEAGLE_RELOAD_CLIPIN     = 120;
const float DEAGLE_RELOAD_APPLY      = 140;

const float MAX_MAG_DEAGLE           = 7;
const float MAX_AMMO_DEAGLE          = 35;

// --- Balance ---
const float DEAGLE_BASE_SPREAD          = 0.008;
const float DEAGLE_MOVE_SPREAD          = 0.06;
const float DEAGLE_FULL_SPREAD_SPEED    = 320;
const float DEAGLE_CLOSE_DAMAGE         = 54;
const float DEAGLE_MIN_DAMAGE           = 34;
const float DEAGLE_DAMAGE_FALLOFF_RANGE = 4096;
const float DEAGLE_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float DEAGLE_DRAW_DURATION      = (DEAGLE_DRAW_END - DEAGLE_DRAW_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_FIRE_DURATION      = (DEAGLE_FIRE_END - DEAGLE_FIRE_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_DURATION    = (DEAGLE_RELOAD_END - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_APPLY_TIME  = (DEAGLE_RELOAD_APPLY - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;

const string DEAGLE_VIEWMODEL    = "models/weapons/wpn_csdeagle/v_deagle.mdl";
const string DEAGLE_WORLDMODEL   = "models/weapons/wpn_csdeagle/w_deagle.mdl";
const string DEAGLE_DEPLOY_SOUND = "sounds/weapons/wpn_csdeagle/deploy.wav";
const string DEAGLE_DISPLAY_NAME = "DEAGLE";

// ============================================================
//  SHARED — state machine (server & client identical)
// ============================================================

// Returns bitmask: bit 0 = transitioned to idle, bit 1 = reload ammo applied
float(float now) SH_DeagleTickState =
{
    return SH_StandardTickState(now, mag_deagle, ammo_deagle, MAX_MAG_DEAGLE,
        DEAGLE_DRAW_DURATION, DEAGLE_FIRE_DURATION,
        DEAGLE_RELOAD_DURATION, DEAGLE_RELOAD_APPLY_TIME);
};

// Returns: 1 = fired, -1 = dry fire, 0 = blocked
float(float now) SH_DeagleTryFire =
{
    return SH_StandardTryFire(now, mag_deagle, DEAGLE_FIRE_DELAY, DEAGLE_DRYFIRE_DELAY);
};

// Returns: 1 = reload started, 0 = blocked
float(float now) SH_DeagleTryReload =
{
    return SH_StandardTryReload(now, mag_deagle, ammo_deagle, MAX_MAG_DEAGLE);
};

// ============================================================
//  SERVER ONLY — authoritative fire, reload, frame, equip,
//  pickup, drop, world entity
// ============================================================

#ifdef SSQC

void(entity player) W_DeaglePickupCopy =
{
    player.mag_deagle  = self.mag_deagle;
    player.ammo_deagle = self.ammo_deagle;
};

void() W_DeagleShoot =
{
    W_StandardHitscanShoot(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED,
        DEAGLE_CLOSE_DAMAGE, DEAGLE_MIN_DAMAGE, DEAGLE_DAMAGE_FALLOFF_RANGE);
};

// Fire — called by W_WeaponFrame when button0 pressed (self = player)
void() W_DeagleFire =
{
    float r = SH_DeagleTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = DEAGLE_FIRE_START;
        self.wep_nextframe = time + DEAGLE_FRAME_INTERVAL;

        W_DeagleShoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 -6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

// Reload — called on impulse 6 / R key (self = player)
void() W_DeagleReload =
{
    if (SH_DeagleTryReload(time))
    {
        self.weaponframe   = DEAGLE_RELOAD_START;
        self.wep_nextframe = time + DEAGLE_FRAME_INTERVAL;
    }
};

// Frame — advances animation state machine (self = player)
void() W_DeagleFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += DEAGLE_FRAME_INTERVAL;

    // Server-only: play sounds at specific frames
    if (self.weaponstate == WS_DRAW && self.weaponframe == DEAGLE_DRAW_SND_FRAME)
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/deploy.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == DEAGLE_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == DEAGLE_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipin.wav", 1, ATTN_NORM);
    }

    // Shared state transitions (idle transition + reload ammo apply)
    result = SH_DeagleTickState(time);
    if (result & 1)
    {
        self.weaponframe   = 2;
        self.wep_nextframe = 0;
    }
};

void() W_DeagleEquip =
{
    W_StandardEquipSetup(DEAGLE_VIEWMODEL, DEAGLE_DISPLAY_NAME, DEAGLE_DRAW_START,
        DEAGLE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DeagleFire;
    self.reload   = W_DeagleReload;
    self.wepframe = W_DeagleFrame;
    self.shoot    = W_DeagleShoot;
    W_SetCrosshairProfile(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

// Drop — called by W_DropCurrentWeapon (self = player)
void() W_DeagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_deagle  = self.mag_deagle;
    tgt.ammo_deagle = self.ammo_deagle;

    self.mag_deagle  = 0;
    self.ammo_deagle = 0;

    setmodel(tgt, "models/weapons/wpn_csdeagle/w_deagle.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_deagle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_DEAGLE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_DeagleEquip;
    tgt.weap_drop_func = W_DeagleDrop;
    tgt.pickupcopy   = W_DeaglePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

// World entity — spawned from map (classname "weapon_deagle")
void() weapon_deagle =
{
    setmodel(self, "models/weapons/wpn_csdeagle/w_deagle.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_deagle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_DEAGLE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_DeagleEquip;
    self.weap_drop_func = W_DeagleDrop;
    self.pickupcopy    = W_DeaglePickupCopy;
    self.touch         = weapon_touch;
    self.mag_deagle    = MAX_MAG_DEAGLE;
    self.ammo_deagle   = MAX_AMMO_DEAGLE;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

const float DEAGLE_RELOAD_CLIPOUT_TIME = (DEAGLE_RELOAD_CLIPOUT - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_CLIPIN_TIME = (DEAGLE_RELOAD_CLIPIN - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
float csqc_deagle_reload_snd_stage;

void() CSQC_PredictDeagleCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_DeagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    localsound("sounds/weapons/wpn_csdeagle/fire1.wav");
                else
                    localsound("sounds/weapons/wpn_csdeagle/fire2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 -6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_deagle_reload_snd_stage < 1 && reload_elapsed >= DEAGLE_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csdeagle/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_deagle_reload_snd_stage = 1;
        }
        if (csqc_deagle_reload_snd_stage < 2 && reload_elapsed >= DEAGLE_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csdeagle/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_deagle_reload_snd_stage = 2; }
    }

    SH_DeagleTickState(csqc_pred_time);
};

void() CSQC_PredictDeagleReload =
{
    if (SH_DeagleTryReload(csqc_pred_time))
    { csqc_deagle_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Returns fractional display frame for viewmodel interpolation.
// Called from CSQC_GetWeaponDisplayFrame dispatcher.
float(float elapsed) CSQC_DeagleDisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, DEAGLE_FRAME_INTERVAL,
        DEAGLE_DRAW_START, DEAGLE_DRAW_END,
        DEAGLE_FIRE_START, DEAGLE_FIRE_END,
        DEAGLE_RELOAD_START, DEAGLE_RELOAD_END,
        2);   // idle frame
};

void() CSQC_DeagleDropClear =
{
	self.mag_deagle = 0;
	self.ammo_deagle = 0;
};

void() CSQC_DeagleEquip =
{
	self.weapon_name         = DEAGLE_DISPLAY_NAME;
	self.weapon_viewmodel    = DEAGLE_VIEWMODEL;
	self.weapon_worldmodel   = DEAGLE_WORLDMODEL;
	self.weapon_deploy_sound = DEAGLE_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictDeagleCommand;
	self.csqc_predict_reload = CSQC_PredictDeagleReload;
	self.csqc_display_frame  = CSQC_DeagleDisplayFrame;
	self.csqc_drop_clear     = CSQC_DeagleDropClear;
};

#endif // CSQC
