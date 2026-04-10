// ============================================================
//  shared/weapons/sh_wpn_csawp.qc  -  CS AWP
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 20 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_awp;
.float ammo_awp;

// --- Animation frames ---
const float AWP_FRAME_INTERVAL        = 0.0333334;   // 1/30

const float AWP_DRAW_START            = 1;
const float AWP_DRAW_END              = 21;
const float AWP_DRAW_DEPLOY_FRAME     = 2;

const float AWP_FIRE_START            = 22;
const float AWP_FIRE_END              = 49;
const float AWP_FIRE_DELAY            = 1.2;
const float AWP_FIRE_BOLTUP_FRAME     = 33;
const float AWP_FIRE_BOLTPULL_FRAME   = 37;
const float AWP_FIRE_BOLTDOWN_FRAME   = 41;

const float AWP_RELOAD_START          = 110;
const float AWP_RELOAD_END            = 163;
const float AWP_RELOAD_CLIPOUT_FRAME  = 123;
const float AWP_RELOAD_CLIPIN_FRAME   = 139;

const float AWP_IDLE_FRAME            = 165;

const float MAX_MAG_AWP               = 10;
const float MAX_AMMO_AWP              = 20;

// --- Balance ---
const float AWP_BASE_SPREAD           = 0.03;
const float AWP_MOVE_SPREAD           = 0.10;
const float AWP_FULL_SPREAD_SPEED     = 320;
const float AWP_CLOSE_DAMAGE          = 120;
const float AWP_MIN_DAMAGE            = 90;
const float AWP_DAMAGE_FALLOFF_RANGE  = 4096;
const float AWP_DRYFIRE_DELAY         = 0.2;

// --- Pre-computed state durations ---
const float AWP_DRAW_DURATION         = (AWP_DRAW_END - AWP_DRAW_START) * AWP_FRAME_INTERVAL;
const float AWP_FIRE_DURATION         = (AWP_FIRE_END - AWP_FIRE_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_DURATION       = (AWP_RELOAD_END - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_APPLY_TIME     = (AWP_RELOAD_CLIPIN_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;

const string AWP_VIEWMODEL    = "models/weapons/wpn_csawp/v_awp.mdl";
const string AWP_WORLDMODEL   = "models/weapons/wpn_csawp/w_awp.mdl";
const string AWP_DEPLOY_SOUND = "sounds/weapons/wpn_csawp/deploy.wav";
const string AWP_DISPLAY_NAME = "AWP";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_AWPTickState =
{
    return SH_StandardTickState(now, mag_awp, ammo_awp, MAX_MAG_AWP,
        AWP_DRAW_DURATION, AWP_FIRE_DURATION,
        AWP_RELOAD_DURATION, AWP_RELOAD_APPLY_TIME);
};

float(float now) SH_AWPTryFire =
{
    // Don't clear zoomstage here — Shoot needs it for spread calculation.
    // Zoomstage is cleared in W_AWPFire / CSQC prediction AFTER the shot.
    return SH_StandardTryFire(now, mag_awp, AWP_FIRE_DELAY, AWP_DRYFIRE_DELAY);
};

float(float now) SH_AWPTryReload =
{
    float r = SH_StandardTryReload(now, mag_awp, ammo_awp, MAX_MAG_AWP);
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

float(float now) SH_AWPTryAltFire =
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

void(entity player) W_AWPPickupCopy =
{
    player.mag_awp  = self.mag_awp;
    player.ammo_awp = self.ammo_awp;
};

void() W_AWPShoot =
{
    if (self.zoomstage > 0)
        W_StandardHitscanShoot(0, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED,
            AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE);
    else
        W_StandardHitscanShoot(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED,
            AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE);
};

void() W_AWPFire =
{
    float r = SH_AWPTryFire(time);
    if (r == 1)
    {
        self.weaponframe = AWP_FIRE_START;
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        W_AWPShoot();
        self.zoomstage = 0;
        self.sv_zoomstage = 0;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_AWPAltFire =
{
    if (SH_AWPTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_AWPReload =
{
    if (SH_AWPTryReload(time))
    {
        self.weaponframe = AWP_RELOAD_START;
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        self.sv_zoomstage = 0;
    }
};

void() W_AWPFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += AWP_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == AWP_FIRE_BOLTUP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltup.wav", 1, ATTN_NORM);
        if (self.weaponframe == AWP_FIRE_BOLTPULL_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltpull.wav", 1, ATTN_NORM);
        if (self.weaponframe == AWP_FIRE_BOLTDOWN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltdown.wav", 1, ATTN_NORM);
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == AWP_RELOAD_CLIPOUT_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == AWP_RELOAD_CLIPIN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipin.wav", 1, ATTN_NORM);
    }

    result = SH_AWPTickState(time);
    if (result & 1)
    { self.weaponframe = AWP_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_AWPEquip =
{
    W_StandardEquipSetup(AWP_VIEWMODEL, AWP_DISPLAY_NAME, AWP_DRAW_START,
        AWP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_AWPFire;
    self.reload   = W_AWPReload;
    self.wepframe = W_AWPFrame;
    self.altfire  = W_AWPAltFire;
    self.shoot    = W_AWPShoot;
    W_ClearZoom();
    W_SetCrosshairProfile(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_AWPDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_awp = self.mag_awp; tgt.ammo_awp = self.ammo_awp;
    self.mag_awp = 0; self.ammo_awp = 0;

    setmodel(tgt, "models/weapons/wpn_csawp/w_awp.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_csawp"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSAWP; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_AWPEquip; tgt.weap_drop_func = W_AWPDrop;
    tgt.pickupcopy = W_AWPPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csawp =
{
    setmodel(self, "models/weapons/wpn_csawp/w_awp.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_csawp"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSAWP; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_AWPEquip; self.weap_drop_func = W_AWPDrop;
    self.pickupcopy = W_AWPPickupCopy; self.touch = weapon_touch;
    self.mag_awp = MAX_MAG_AWP; self.ammo_awp = MAX_AMMO_AWP;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float AWP_FIRE_BOLTUP_TIME = (AWP_FIRE_BOLTUP_FRAME - AWP_FIRE_START) * AWP_FRAME_INTERVAL;
const float AWP_FIRE_BOLTPULL_TIME = (AWP_FIRE_BOLTPULL_FRAME - AWP_FIRE_START) * AWP_FRAME_INTERVAL;
const float AWP_FIRE_BOLTDOWN_TIME = (AWP_FIRE_BOLTDOWN_FRAME - AWP_FIRE_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_CLIPOUT_TIME = (AWP_RELOAD_CLIPOUT_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_CLIPIN_TIME = (AWP_RELOAD_CLIPIN_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;

float csqc_awp_fire_snd_stage;
float csqc_awp_reload_snd_stage;

void() CSQC_PredictAWPCommand =
{
    float r;

    if (input_buttons & 4)
    {
        if (SH_AWPTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_AWPTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_awp_fire_snd_stage = 0;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(self.zoomstage > 0 ? 0 : AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
            self.zoomstage = 0;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted fire bolt sounds
    if (self.weaponstate == WS_FIRE && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float fire_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_awp_fire_snd_stage < 1 && fire_elapsed >= AWP_FIRE_BOLTUP_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltup.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 1; }
        if (csqc_awp_fire_snd_stage < 2 && fire_elapsed >= AWP_FIRE_BOLTPULL_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 2; }
        if (csqc_awp_fire_snd_stage < 3 && fire_elapsed >= AWP_FIRE_BOLTDOWN_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltdown.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 3; }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_awp_reload_snd_stage < 1 && reload_elapsed >= AWP_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csawp/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_awp_reload_snd_stage = 1;
        }
        if (csqc_awp_reload_snd_stage < 2 && reload_elapsed >= AWP_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csawp/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_reload_snd_stage = 2; }
    }

    SH_AWPTickState(csqc_pred_time);
};

void() CSQC_PredictAWPReload =
{
    if (SH_AWPTryReload(csqc_pred_time))
    { csqc_awp_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_AWPDisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, AWP_FRAME_INTERVAL,
        AWP_DRAW_START, AWP_DRAW_END,
        AWP_FIRE_START, AWP_FIRE_END,
        AWP_RELOAD_START, AWP_RELOAD_END,
        AWP_IDLE_FRAME);
};

void() CSQC_AWPDropClear =
{
	self.mag_awp = 0;
	self.ammo_awp = 0;
	self.zoomstage = 0;
};

void() CSQC_AWPEquip =
{
	self.weapon_name         = AWP_DISPLAY_NAME;
	self.weapon_viewmodel    = AWP_VIEWMODEL;
	self.weapon_worldmodel   = AWP_WORLDMODEL;
	self.weapon_deploy_sound = AWP_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictAWPCommand;
	self.csqc_predict_reload = CSQC_PredictAWPReload;
	self.csqc_display_frame  = CSQC_AWPDisplayFrame;
	self.csqc_drop_clear     = CSQC_AWPDropClear;
};

#endif // CSQC
