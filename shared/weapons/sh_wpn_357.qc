// ============================================================
//  shared/weapons/sh_wpn_357.qc  -  .357 Revolver
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 18 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_357;
.float ammo_357;

// --- Animation frames ---
const float W357_FRAME_INTERVAL       = 0.05;   // 1/20

const float W357_DRAW_START           = 1;
const float W357_DRAW_END             = 10;

const float W357_FIRE_START           = 11;
const float W357_FIRE_END             = 31;
const float W357_FIRE_DELAY           = 0.75;

const float W357_RELOAD_START         = 139;
const float W357_RELOAD_END           = 200;
const float W357_RELOAD_SOUND_FRAME   = 180;
const float W357_RELOAD_APPLY         = 184;

const float W357_IDLE_FRAME           = 78;

const float MAX_MAG_357               = 6;
const float MAX_AMMO_357              = 18;

// --- Balance ---
const float W357_BASE_SPREAD          = 0.004;
const float W357_MOVE_SPREAD          = 0.03;
const float W357_FULL_SPREAD_SPEED    = 320;
const float W357_CLOSE_DAMAGE         = 70;
const float W357_MIN_DAMAGE           = 45;
const float W357_DAMAGE_FALLOFF_RANGE = 4096;
const float W357_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float W357_DRAW_DURATION      = (W357_DRAW_END - W357_DRAW_START) * W357_FRAME_INTERVAL;
const float W357_FIRE_DURATION      = (W357_FIRE_END - W357_FIRE_START) * W357_FRAME_INTERVAL;
const float W357_RELOAD_DURATION    = (W357_RELOAD_END - W357_RELOAD_START) * W357_FRAME_INTERVAL;
const float W357_RELOAD_APPLY_TIME  = (W357_RELOAD_APPLY - W357_RELOAD_START) * W357_FRAME_INTERVAL;

const string W357_VIEWMODEL    = "models/weapons/wpn_hl357/v_357.mdl";
const string W357_WORLDMODEL   = "models/weapons/wpn_hl357/w_357.mdl";
const string W357_DEPLOY_SOUND = "";
const string W357_DISPLAY_NAME = ".357";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_357TickState =
{
    return SH_StandardTickState(now, mag_357, ammo_357, MAX_MAG_357,
        W357_DRAW_DURATION, W357_FIRE_DURATION,
        W357_RELOAD_DURATION, W357_RELOAD_APPLY_TIME);
};

float(float now) SH_357TryFire =
{
    return SH_StandardTryFire(now, mag_357, W357_FIRE_DELAY, W357_DRYFIRE_DELAY);
};

float(float now) SH_357TryReload =
{
    // 357 blocks reload during attack cooldown (unique to this weapon)
    if (now < self.attack_finished)
        return 0;
    return SH_StandardTryReload(now, mag_357, ammo_357, MAX_MAG_357, W357_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_357PickupCopy =
{
    player.mag_357  = self.mag_357;
    player.ammo_357 = self.ammo_357;
};

void() W_357Shoot =
{
    W_PenetratingHitscanShoot(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED,
        W357_CLOSE_DAMAGE, W357_MIN_DAMAGE, W357_DAMAGE_FALLOFF_RANGE, 48, 0.97);
};

void() W_357Fire =
{
    float r = SH_357TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = W357_FIRE_START;
        self.wep_nextframe = time + W357_FRAME_INTERVAL;

        W_357Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NORM);
    }
};

void() W_357Reload =
{
    if (SH_357TryReload(time))
    {
        self.weaponframe   = W357_RELOAD_START;
        self.wep_nextframe = time + W357_FRAME_INTERVAL;
    }
};

void() W_357Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += W357_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == W357_RELOAD_SOUND_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hl357/reload.wav", 1, ATTN_NORM);
    }

    result = SH_357TickState(time);
    if (result & 1)
    {
        self.weaponframe   = W357_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_357Equip =
{
    W_StandardEquipSetup(W357_VIEWMODEL, W357_DISPLAY_NAME, W357_DRAW_START,
        W357_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_357Fire;
    self.reload   = W_357Reload;
    self.wepframe = W_357Frame;
    self.shoot    = W_357Shoot;
    W_SetCrosshairProfile(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED, 1.4, TRUE);
};

void() W_357Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_357  = self.mag_357;
    tgt.ammo_357 = self.ammo_357;

    self.mag_357  = 0;
    self.ammo_357 = 0;

    setmodel(tgt, "models/weapons/wpn_hl357/w_357.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_357";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_357;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_357Equip;
    tgt.weap_drop_func = W_357Drop;
    tgt.pickupcopy   = W_357PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_357 =
{
    setmodel(self, "models/weapons/wpn_hl357/w_357.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_357";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_357;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_357Equip;
    self.weap_drop_func = W_357Drop;
    self.pickupcopy    = W_357PickupCopy;
    self.touch         = weapon_touch;
    self.mag_357       = MAX_MAG_357;
    self.ammo_357      = MAX_AMMO_357;
    W_RegisterMapWeapon(weapon_357);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_357_reload_snd_played;
const float W357_RELOAD_SND_TIME = (W357_RELOAD_SOUND_FRAME - W357_RELOAD_START) * W357_FRAME_INTERVAL;

void() CSQC_Predict357Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_357TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED,
                    W357_CLOSE_DAMAGE, W357_MIN_DAMAGE, W357_DAMAGE_FALLOFF_RANGE);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted reload sound
    if (self.weaponstate == WS_RELOAD && !csqc_357_reload_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= W357_RELOAD_SND_TIME)
        { localsound("sounds/weapons/wpn_hl357/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_357_reload_snd_played = TRUE; }
    }

    SH_357TickState(csqc_pred_time);
};

void() CSQC_Predict357Reload =
{
    if (SH_357TryReload(csqc_pred_time))
    { csqc_357_reload_snd_played = FALSE; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_357DisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, W357_FRAME_INTERVAL,
        W357_DRAW_START, W357_DRAW_END,
        W357_FIRE_START, W357_FIRE_END,
        W357_RELOAD_START, W357_RELOAD_END,
        W357_IDLE_FRAME);
};

void() CSQC_357DropClear =
{
	self.mag_357 = 0;
	self.ammo_357 = 0;
};

void() CSQC_357Equip =
{
	self.weapon_name         = W357_DISPLAY_NAME;
	self.weapon_viewmodel    = W357_VIEWMODEL;
	self.weapon_worldmodel   = W357_WORLDMODEL;
	self.weapon_deploy_sound = W357_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_Predict357Command;
	self.csqc_predict_reload = CSQC_Predict357Reload;
	self.csqc_display_frame  = CSQC_357DisplayFrame;
	self.csqc_drop_clear     = CSQC_357DropClear;
};

#endif // CSQC
