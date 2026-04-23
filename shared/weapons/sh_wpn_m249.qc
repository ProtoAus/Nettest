// ============================================================
//  shared/weapons/sh_wpn_m249.qc  -  M249 LMG
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round belt, 150 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_m249;
.float ammo_m249;

// --- Animation frames ---
const float M249_FRAME_INTERVAL       = 0.0333334;   // 1/30

const float M249_DRAW_START           = 1;
const float M249_DRAW_END             = 20;

const float M249_FIRE_START           = 21;
const float M249_FIRE_END             = 31;
const float M249_ALT_FIRE_START       = 32;
const float M249_ALT_FIRE_END         = 42;
const float M249_FIRE_DELAY           = 0.1;

const float M249_EMPTY_IDLE_FRAME     = 43;
const float M249_RELOAD_START         = 43;
const float M249_RELOAD_END           = 136;
const float M249_RELOAD_APPLY         = 117;

const float M249_IDLE_FRAME           = 20;   // DRAW_END

const float MAX_MAG_M249              = 50;
const float MAX_AMMO_M249             = 150;

// --- Balance ---
const float M249_BASE_SPREAD          = 0.08;
const float M249_MOVE_SPREAD          = 0.12;
const float M249_FULL_SPREAD_SPEED    = 320;
const float M249_CLOSE_DAMAGE         = 14;
const float M249_MIN_DAMAGE           = 7;
const float M249_DAMAGE_FALLOFF_RANGE = 3072;
const float M249_DRYFIRE_DELAY        = 0.2;

// --- Reload sound frames ---
const float M249_SND_COVERUP          = 52;
const float M249_SND_BOXOUT           = 74;
const float M249_SND_BOXIN            = 98;
const float M249_SND_CHAIN            = 108;
const float M249_SND_COVERDOWN        = 129;

// --- Pre-computed state durations ---
const float M249_DRAW_DURATION       = (M249_DRAW_END - M249_DRAW_START) * M249_FRAME_INTERVAL;
const float M249_FIRE_DURATION       = (M249_FIRE_END - M249_FIRE_START) * M249_FRAME_INTERVAL;
const float M249_RELOAD_DURATION     = (M249_RELOAD_END - M249_RELOAD_START) * M249_FRAME_INTERVAL;
const float M249_RELOAD_APPLY_TIME   = (M249_RELOAD_APPLY - M249_RELOAD_START) * M249_FRAME_INTERVAL;

const string M249_VIEWMODEL    = "models/weapons/wpn_csm249/v_m249.mdl";
const string M249_WORLDMODEL   = "models/weapons/wpn_csm249/w_m249.mdl";
const string M249_DEPLOY_SOUND = "";
const string M249_DISPLAY_NAME = "M249";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_M249TickState =
{
    return SH_StandardTickState(now, mag_m249, ammo_m249, MAX_MAG_M249,
        M249_DRAW_DURATION, M249_FIRE_DURATION,
        M249_RELOAD_DURATION, M249_RELOAD_APPLY_TIME);
};

float(float now) SH_M249TryFire =
{
    return SH_StandardTryFire(now, mag_m249, M249_FIRE_DELAY, M249_DRYFIRE_DELAY);
};

float(float now) SH_M249TryReload =
{
    return SH_StandardTryReload(now, mag_m249, ammo_m249, MAX_MAG_M249, M249_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M249PickupCopy =
{
    player.mag_m249  = self.mag_m249;
    player.ammo_m249 = self.ammo_m249;
};

void() W_M249Shoot =
{
    W_PenetratingHitscanShoot(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED,
        M249_CLOSE_DAMAGE, M249_MIN_DAMAGE, M249_DAMAGE_FALLOFF_RANGE, 48, 0.97);
};

void() W_M249Fire =
{
    float r = SH_M249TryFire(time);

    if (r == 1)
    {
        // Randomly pick between two fire animation variants
        if (random() < 0.5)
            self.weaponframe = M249_FIRE_START;
        else
            self.weaponframe = M249_ALT_FIRE_START;

        self.wep_nextframe = time + M249_FRAME_INTERVAL;

        W_M249Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_M249Reload =
{
    if (SH_M249TryReload(time))
    {
        self.weaponframe   = M249_RELOAD_START;
        self.wep_nextframe = time + M249_FRAME_INTERVAL;
    }
};

void() W_M249Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += M249_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == M249_SND_COVERUP)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/coverup.wav", 1, ATTN_NORM);
        if (self.weaponframe == M249_SND_BOXOUT)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/boxout.wav", 1, ATTN_NORM);
        if (self.weaponframe == M249_SND_BOXIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/boxin.wav", 1, ATTN_NORM);
        if (self.weaponframe == M249_SND_CHAIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/chain.wav", 1, ATTN_NORM);
        if (self.weaponframe == M249_SND_COVERDOWN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/coverdown.wav", 1, ATTN_NORM);
    }

    result = SH_M249TickState(time);
    if (result & 1)
    {
        if (self.mag_m249 <= 0)
            self.weaponframe = M249_EMPTY_IDLE_FRAME;
        else
            self.weaponframe = M249_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_M249Equip =
{
    W_StandardEquipSetup(M249_VIEWMODEL, M249_DISPLAY_NAME, M249_DRAW_START,
        M249_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_M249Fire;
    self.reload   = W_M249Reload;
    self.wepframe = W_M249Frame;
    self.shoot    = W_M249Shoot;
    W_SetCrosshairProfile(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED, 5, TRUE);
};

void() W_M249Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_m249  = self.mag_m249;
    tgt.ammo_m249 = self.ammo_m249;

    self.mag_m249  = 0;
    self.ammo_m249 = 0;

    setmodel(tgt, "models/weapons/wpn_csm249/w_m249.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_m249";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_M249;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_M249Equip;
    tgt.weap_drop_func = W_M249Drop;
    tgt.pickupcopy   = W_M249PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.dropped_spin = 1;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_m249 =
{
    setmodel(self, "models/weapons/wpn_csm249/w_m249.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_m249";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_M249;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_M249Equip;
    self.weap_drop_func = W_M249Drop;
    self.pickupcopy    = W_M249PickupCopy;
    self.touch         = weapon_touch;
    self.dropped_spin  = 1;
    self.mag_m249      = MAX_MAG_M249;
    self.ammo_m249     = MAX_AMMO_M249;
    W_RegisterMapWeapon(weapon_m249);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_m249_reload_snd_stage;

void() CSQC_PredictM249Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_M249TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED,
                    M249_CLOSE_DAMAGE, M249_MIN_DAMAGE, M249_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Predicted reload sounds — runs every frame while reloading
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float coverup_t   = (M249_SND_COVERUP - M249_RELOAD_START) * M249_FRAME_INTERVAL;
        float boxout_t    = (M249_SND_BOXOUT - M249_RELOAD_START) * M249_FRAME_INTERVAL;
        float boxin_t     = (M249_SND_BOXIN - M249_RELOAD_START) * M249_FRAME_INTERVAL;
        float chain_t     = (M249_SND_CHAIN - M249_RELOAD_START) * M249_FRAME_INTERVAL;
        float coverdown_t = (M249_SND_COVERDOWN - M249_RELOAD_START) * M249_FRAME_INTERVAL;

        if (csqc_m249_reload_snd_stage < 1 && reload_elapsed >= coverup_t)
        { localsound("sounds/weapons/wpn_csm249/coverup.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_reload_snd_stage = 1; }
        if (csqc_m249_reload_snd_stage < 2 && reload_elapsed >= boxout_t)
        { localsound("sounds/weapons/wpn_csm249/boxout.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_reload_snd_stage = 2; }
        if (csqc_m249_reload_snd_stage < 3 && reload_elapsed >= boxin_t)
        { localsound("sounds/weapons/wpn_csm249/boxin.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_reload_snd_stage = 3; }
        if (csqc_m249_reload_snd_stage < 4 && reload_elapsed >= chain_t)
        { localsound("sounds/weapons/wpn_csm249/chain.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_reload_snd_stage = 4; }
        if (csqc_m249_reload_snd_stage < 5 && reload_elapsed >= coverdown_t)
        { localsound("sounds/weapons/wpn_csm249/coverdown.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_reload_snd_stage = 5; }
    }

    SH_M249TickState(csqc_pred_time);
};

void() CSQC_PredictM249Reload =
{
    if (SH_M249TryReload(csqc_pred_time))
    {
        csqc_m249_reload_snd_stage = 0;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_M249DisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = M249_DRAW_START + elapsed / M249_FRAME_INTERVAL;
        return bound(M249_DRAW_START, frame, M249_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = M249_FIRE_START + elapsed / M249_FRAME_INTERVAL;
        return bound(M249_FIRE_START, frame, M249_ALT_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = M249_RELOAD_START + elapsed / M249_FRAME_INTERVAL;
        return bound(M249_RELOAD_START, frame, M249_RELOAD_END - 1);
    }

    // Empty idle when magazine is empty
    if (predicted_player.mag_m249 <= 0)
        return M249_EMPTY_IDLE_FRAME;

    return M249_IDLE_FRAME;
};

void() CSQC_M249DropClear =
{
	self.mag_m249 = 0;
	self.ammo_m249 = 0;
};

void() CSQC_M249Equip =
{
	self.weapon_name         = M249_DISPLAY_NAME;
	self.weapon_viewmodel    = M249_VIEWMODEL;
	self.weapon_worldmodel   = M249_WORLDMODEL;
	self.weapon_deploy_sound = M249_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM249Command;
	self.csqc_predict_reload = CSQC_PredictM249Reload;
	self.csqc_display_frame  = CSQC_M249DisplayFrame;
	self.csqc_drop_clear     = CSQC_M249DropClear;
};

#endif // CSQC
