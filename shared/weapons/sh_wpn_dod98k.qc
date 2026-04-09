// ============================================================
//  shared/weapons/sh_wpn_dod98k.qc  -  DOD 98K Karabiner
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round stripper clip, 25 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : Bayonet stab (melee, WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_98k;
.float ammo_98k;

// --- Animation frames ---
const float K98_FRAME_INTERVAL        = 0.0333334;   // 1/30

const float K98_DRAW_START            = 186;
const float K98_DRAW_END              = 215;

const float K98_FIRE_START            = 3;
const float K98_FIRE_END              = 59;
const float K98_FIRE_DELAY            = 1.05;
const float K98_FIRE_BOLTBACK_FRAME   = 28;
const float K98_FIRE_BOLTFWD_FRAME    = 41;

const float K98_RELOAD_START          = 60;
const float K98_RELOAD_END            = 183;
const float K98_RELOAD_BOLTBACK_FRAME = 76;
const float K98_RELOAD_SND_FRAME      = 132;
const float K98_RELOAD_APPLY          = 145;
const float K98_RELOAD_BOLTFWD_FRAME  = 160;

const float K98_STAB_START            = 264;
const float K98_STAB_END              = 298;
const float K98_STAB_STRIKE_FRAME     = 265;
const float K98_STAB_DELAY            = 0.65;

const float K98_IDLE_FRAME            = 1;

const float MAX_MAG_98K               = 5;
const float MAX_AMMO_98K              = 25;

// --- Balance ---
const float K98_BASE_SPREAD           = 0.025;
const float K98_MOVE_SPREAD           = 0.09;
const float K98_FULL_SPREAD_SPEED     = 320;
const float K98_CLOSE_DAMAGE          = 100;
const float K98_MIN_DAMAGE            = 70;
const float K98_DAMAGE_FALLOFF_RANGE  = 4096;
const float K98_DRYFIRE_DELAY         = 0.2;
const float K98_STAB_DAMAGE           = 55;
const float K98_STAB_RANGE            = 72;

// --- Pre-computed state durations ---
const float K98_DRAW_DURATION         = (K98_DRAW_END - K98_DRAW_START) * K98_FRAME_INTERVAL;
const float K98_FIRE_DURATION         = (K98_FIRE_END - K98_FIRE_START) * K98_FRAME_INTERVAL;
const float K98_RELOAD_DURATION       = (K98_RELOAD_END - K98_RELOAD_START) * K98_FRAME_INTERVAL;
const float K98_RELOAD_APPLY_TIME     = (K98_RELOAD_APPLY - K98_RELOAD_START) * K98_FRAME_INTERVAL;
const float K98_STAB_DURATION         = (K98_STAB_END - K98_STAB_START) * K98_FRAME_INTERVAL;

const string K98_VIEWMODEL    = "models/weapons/wpn_dod98k/v_98k.mdl";
const string K98_WORLDMODEL   = "models/weapons/wpn_dod98k/w_98k.mdl";
const string K98_DEPLOY_SOUND = "";
const string K98_DISPLAY_NAME = "98K";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_98KTickState =
{
    float elapsed;

    // WS_SPECIAL (bayonet stab) is handled here, not by the standard function
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= K98_STAB_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return SH_StandardTickState(now, mag_98k, ammo_98k, MAX_MAG_98K,
        K98_DRAW_DURATION, K98_FIRE_DURATION,
        K98_RELOAD_DURATION, K98_RELOAD_APPLY_TIME);
};

float(float now) SH_98KTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_98k, K98_FIRE_DELAY, K98_DRYFIRE_DELAY);
};

float(float now) SH_98KTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_98k, ammo_98k, MAX_MAG_98K);
};

float(float now) SH_98KTryStab =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished) return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + K98_STAB_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_98KPickupCopy =
{ player.mag_98k = self.mag_98k; player.ammo_98k = self.ammo_98k; };

void() W_98KShoot =
{
    W_StandardHitscanShoot(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED,
        K98_CLOSE_DAMAGE, K98_MIN_DAMAGE, K98_DAMAGE_FALLOFF_RANGE);
};

void() W_98KStab =
{
    vector src, end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * K98_STAB_RANGE;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_dod98k/stab.wav", 1, ATTN_NORM);
        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, K98_STAB_DAMAGE);
        else
            W_ImpactEffect(trace_endpos);
    }
    else
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_dod98k/stab.wav", 1, ATTN_NORM);
};

void() W_98KFire =
{
    float r = SH_98KTryFire(time);
    if (r == 1)
    {
        self.weaponframe = K98_FIRE_START;
        self.wep_nextframe = time + K98_FRAME_INTERVAL;
        W_98KShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_dod98k/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_98KAltFire =
{
    if (SH_98KTryStab(time))
    {
        self.weaponframe = K98_STAB_START;
        self.wep_nextframe = time + K98_FRAME_INTERVAL;
    }
};

void() W_98KReload =
{
    if (SH_98KTryReload(time))
    { self.weaponframe = K98_RELOAD_START; self.wep_nextframe = time + K98_FRAME_INTERVAL; }
};

void() W_98KFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += K98_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == K98_FIRE_BOLTBACK_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_dod98k/boltback.wav", 1, ATTN_NORM);
        if (self.weaponframe == K98_FIRE_BOLTFWD_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_dod98k/boltforward.wav", 1, ATTN_NORM);
    }

    if (self.weaponstate == WS_SPECIAL && self.weaponframe == K98_STAB_STRIKE_FRAME)
        W_98KStab();

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == K98_RELOAD_BOLTBACK_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_dod98k/boltback.wav", 1, ATTN_NORM);
        if (self.weaponframe == K98_RELOAD_SND_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_dod98k/reload.wav", 1, ATTN_NORM);
        if (self.weaponframe == K98_RELOAD_BOLTFWD_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_dod98k/boltforward.wav", 1, ATTN_NORM);
    }

    result = SH_98KTickState(time);
    if (result & 1)
    { self.weaponframe = K98_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_98KEquip =
{
    W_StandardEquipSetup(K98_VIEWMODEL, K98_DISPLAY_NAME, K98_DRAW_START,
        K98_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_98KFire;
    self.reload   = W_98KReload;
    self.wepframe = W_98KFrame;
    self.altfire  = W_98KAltFire;
    self.shoot    = W_98KShoot;
    W_SetCrosshairProfile(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_98KDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_98k = self.mag_98k; tgt.ammo_98k = self.ammo_98k;
    self.mag_98k = 0; self.ammo_98k = 0;
    setmodel(tgt, "models/weapons/wpn_dod98k/w_98k.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_dod98k"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_DOD98K; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_98KEquip; tgt.weap_drop_func = W_98KDrop;
    tgt.pickupcopy = W_98KPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_dod98k =
{
    setmodel(self, "models/weapons/wpn_dod98k/w_98k.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_dod98k"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_DOD98K; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_98KEquip; self.weap_drop_func = W_98KDrop;
    self.pickupcopy = W_98KPickupCopy; self.touch = weapon_touch;
    self.mag_98k = MAX_MAG_98K; self.ammo_98k = MAX_AMMO_98K;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float K98_FIRE_BOLTBACK_TIME = (K98_FIRE_BOLTBACK_FRAME - K98_FIRE_START) * K98_FRAME_INTERVAL;
const float K98_FIRE_BOLTFWD_TIME = (K98_FIRE_BOLTFWD_FRAME - K98_FIRE_START) * K98_FRAME_INTERVAL;
const float K98_RELOAD_BOLTBACK_TIME = (K98_RELOAD_BOLTBACK_FRAME - K98_RELOAD_START) * K98_FRAME_INTERVAL;
const float K98_RELOAD_SND_TIME = (K98_RELOAD_SND_FRAME - K98_RELOAD_START) * K98_FRAME_INTERVAL;
const float K98_RELOAD_BOLTFWD_TIME = (K98_RELOAD_BOLTFWD_FRAME - K98_RELOAD_START) * K98_FRAME_INTERVAL;

float csqc_98k_fire_snd_stage;
float csqc_98k_reload_snd_stage;

void() CSQC_Predict98KCommand =
{
    float r;

    // Alt-fire: bayonet stab — skip during replay (no ammo to deplete,
    // would cause infinite re-fires like the knife)
    if (!pm_suppress_sounds && (input_buttons & 4))
    {
        if (SH_98KTryStab(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            CSQC_PredictedMeleeTrace(K98_STAB_RANGE,
                "sounds/weapons/wpn_dod98k/stab.wav", "",
                "sounds/weapons/wpn_dod98k/stab.wav");
            CSQC_RecordPredictedWeaponSound();
        }
    }

    if (input_buttons & 1)
    {
        r = SH_98KTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_98k_fire_snd_stage = 0;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_dod98k/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
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

    // Predicted fire bolt sounds
    if (self.weaponstate == WS_FIRE && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float fire_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_98k_fire_snd_stage < 1 && fire_elapsed >= K98_FIRE_BOLTBACK_TIME)
        { localsound("sounds/weapons/wpn_dod98k/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_fire_snd_stage = 1; }
        if (csqc_98k_fire_snd_stage < 2 && fire_elapsed >= K98_FIRE_BOLTFWD_TIME)
        { localsound("sounds/weapons/wpn_dod98k/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_fire_snd_stage = 2; }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_98k_reload_snd_stage < 1 && reload_elapsed >= K98_RELOAD_BOLTBACK_TIME)
        { localsound("sounds/weapons/wpn_dod98k/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_reload_snd_stage = 1; }
        if (csqc_98k_reload_snd_stage < 2 && reload_elapsed >= K98_RELOAD_SND_TIME)
        { localsound("sounds/weapons/wpn_dod98k/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_reload_snd_stage = 2; }
        if (csqc_98k_reload_snd_stage < 3 && reload_elapsed >= K98_RELOAD_BOLTFWD_TIME)
        { localsound("sounds/weapons/wpn_dod98k/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_reload_snd_stage = 3; }
    }

    SH_98KTickState(csqc_pred_time);
};

void() CSQC_Predict98KReload =
{
    if (SH_98KTryReload(csqc_pred_time))
    { csqc_98k_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_98KDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        frame = K98_STAB_START + elapsed / K98_FRAME_INTERVAL;
        return bound(K98_STAB_START, frame, K98_STAB_END - 1);
    }
    return CSQC_StandardDisplayFrame(elapsed, K98_FRAME_INTERVAL,
        K98_DRAW_START, K98_DRAW_END,
        K98_FIRE_START, K98_FIRE_END,
        K98_RELOAD_START, K98_RELOAD_END,
        K98_IDLE_FRAME);
};

void() CSQC_98KDropClear =
{
	self.mag_98k = 0;
	self.ammo_98k = 0;
};

void() CSQC_98KEquip =
{
	self.weapon_name         = K98_DISPLAY_NAME;
	self.weapon_viewmodel    = K98_VIEWMODEL;
	self.weapon_worldmodel   = K98_WORLDMODEL;
	self.weapon_deploy_sound = K98_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_Predict98KCommand;
	self.csqc_predict_reload = CSQC_Predict98KReload;
	self.csqc_display_frame  = CSQC_98KDisplayFrame;
	self.csqc_drop_clear     = CSQC_98KDropClear;
};

#endif // CSQC
