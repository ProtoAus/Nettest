// ============================================================
//  shared/weapons/sh_wpn_csglock.qc  -  CS Glock 18
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 20-round magazine, 40 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : 3-round burst fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_glock;
.float ammo_glock;

// --- Animation frames (placeholder — user will tune) ---
const float GLOCK_FRAME_INTERVAL      = 0.0333334;   // 1/30

const float GLOCK_DRAW_START          = 1;
const float GLOCK_DRAW_END            = 20;
const float GLOCK_DRAW_SND_FRAME      = 11;

const float GLOCK_FIRE_START          = 55;
const float GLOCK_FIRE_END            = 66;
const float GLOCK_FIRE_DELAY          = 0.15;

const float GLOCK_BURST_START         = 21;     // burst fire animation (separate from single fire)
const float GLOCK_BURST_END           = 38;
const float GLOCK_BURST_FIRE_DELAY    = 0.05;   // delay between burst shots
const float GLOCK_BURST_COOLDOWN      = 0.5;    // delay after burst completes

const float GLOCK_RELOAD_START        = 67;
const float GLOCK_RELOAD_END          = 116;
const float GLOCK_RELOAD_CLIPOUT      = 86;
const float GLOCK_RELOAD_CLIPIN       = 104;
const float GLOCK_RELOAD_APPLY        = 104;
const float GLOCK_RELOAD_SLIDE_FRAME  = 111;

const float GLOCK_IDLE_FRAME          = 20;

const float MAX_MAG_GLOCK             = 20;
const float MAX_AMMO_GLOCK            = 40;

// --- Balance ---
const float GLOCK_BASE_SPREAD          = 0.01;
const float GLOCK_MOVE_SPREAD          = 0.05;
const float GLOCK_FULL_SPREAD_SPEED    = 320;
const float GLOCK_CLOSE_DAMAGE         = 18;
const float GLOCK_MIN_DAMAGE           = 10;
const float GLOCK_DAMAGE_FALLOFF_RANGE = 2048;
const float GLOCK_DRYFIRE_DELAY        = 0.2;

const float GLOCK_BURST_SPREAD         = 0.03;   // base spread during burst
const float GLOCK_BURST_DAMAGE         = 14;     // less damage per bullet in burst

// --- Pre-computed state durations ---
const float GLOCK_DRAW_DURATION      = (GLOCK_DRAW_END - GLOCK_DRAW_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_FIRE_DURATION      = (GLOCK_FIRE_END - GLOCK_FIRE_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_BURST_DURATION     = (GLOCK_BURST_END - GLOCK_BURST_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_RELOAD_DURATION    = (GLOCK_RELOAD_END - GLOCK_RELOAD_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_RELOAD_APPLY_TIME  = (GLOCK_RELOAD_APPLY - GLOCK_RELOAD_START) * GLOCK_FRAME_INTERVAL;

const string GLOCK_VIEWMODEL    = "models/weapons/wpn_csglock/v_glock.mdl";
const string GLOCK_WORLDMODEL   = "models/weapons/wpn_csglock/w_glock.mdl";
const string GLOCK_DEPLOY_SOUND = "";
const string GLOCK_DISPLAY_NAME = "GLOCK";

// --- Burst state ---
.float glock_burst_count;     // shots remaining in current burst (0 = not bursting)
.float glock_burst_next;      // time of next burst shot

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GlockTickState =
{
    float elapsed;

    // WS_SPECIAL = burst fire animation
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= GLOCK_BURST_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return SH_StandardTickState(now, mag_glock, ammo_glock, MAX_MAG_GLOCK,
        GLOCK_DRAW_DURATION, GLOCK_FIRE_DURATION,
        GLOCK_RELOAD_DURATION, GLOCK_RELOAD_APPLY_TIME);
};

float(float now) SH_GlockTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_glock, GLOCK_FIRE_DELAY, GLOCK_DRYFIRE_DELAY);
};

float(float now) SH_GlockTryReload =
{
    return SH_StandardTryReload(now, mag_glock, ammo_glock, MAX_MAG_GLOCK);
};

// Start a 3-round burst. Returns 1 if burst started, -1 dry, 0 blocked.
float(float now) SH_GlockTryBurst =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished)
        return 0;
    if (self.glock_burst_count > 0)
        return 0;

    if (self.mag_glock <= 0)
    {
        self.attack_finished = now + GLOCK_DRYFIRE_DELAY;
        return -1;
    }

    // Fire first bullet of burst immediately, use WS_SPECIAL for burst animation
    self.mag_glock       -= 1;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.glock_burst_count = 2;   // 2 more shots queued
    self.glock_burst_next  = now + GLOCK_BURST_FIRE_DELAY;
    self.attack_finished   = now + GLOCK_BURST_COOLDOWN;
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_GlockPickupCopy =
{
    player.mag_glock  = self.mag_glock;
    player.ammo_glock = self.ammo_glock;
};

void() W_GlockShoot =
{
    W_StandardHitscanShoot(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
        GLOCK_CLOSE_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE);
};

void() W_GlockBurstShoot =
{
    W_StandardHitscanShoot(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
        GLOCK_BURST_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE);
};

void() W_GlockFire =
{
    float r = SH_GlockTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = GLOCK_FIRE_START;
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        W_GlockShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GlockAltFire =
{
    float r = SH_GlockTryBurst(time);
    if (r == 1)
    {
        self.weaponframe   = GLOCK_BURST_START;
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        W_GlockBurstShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GlockReload =
{
    if (SH_GlockTryReload(time))
    {
        self.weaponframe   = GLOCK_RELOAD_START;
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        self.glock_burst_count = 0;
    }
};

void() W_GlockFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += GLOCK_FRAME_INTERVAL;

    // Draw sound
    if (self.weaponstate == WS_DRAW && self.weaponframe == GLOCK_DRAW_SND_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/slideback.wav", 1, ATTN_NORM);

    // Reload sounds
    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == GLOCK_RELOAD_START + 1)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/reload.wav", 1, ATTN_NORM);
        if (self.weaponframe == GLOCK_RELOAD_CLIPOUT)
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
        if (self.weaponframe == GLOCK_RELOAD_SLIDE_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/sliderelease.wav", 1, ATTN_NORM);
    }

    // Burst: fire remaining queued shots
    if (self.glock_burst_count > 0 && time >= self.glock_burst_next)
    {
        if (self.mag_glock > 0)
        {
            self.mag_glock -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            W_GlockBurstShoot();
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
        }
        self.glock_burst_count -= 1;
        self.glock_burst_next = time + GLOCK_BURST_FIRE_DELAY;
    }

    result = SH_GlockTickState(time);
    if (result & 1)
    {
        self.weaponframe   = GLOCK_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_GlockEquip =
{
    W_StandardEquipSetup(GLOCK_VIEWMODEL, GLOCK_DISPLAY_NAME, GLOCK_DRAW_START,
        GLOCK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_GlockFire;
    self.reload   = W_GlockReload;
    self.wepframe = W_GlockFrame;
    self.altfire  = W_GlockAltFire;
    self.shoot    = W_GlockShoot;
    self.glock_burst_count = 0;
    W_SetCrosshairProfile(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_GlockDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_glock  = self.mag_glock;
    tgt.ammo_glock = self.ammo_glock;
    self.mag_glock  = 0;
    self.ammo_glock = 0;

    setmodel(tgt, "models/weapons/wpn_csglock/w_glock.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_glock";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_GLOCK;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_GlockEquip;
    tgt.weap_drop_func = W_GlockDrop;
    tgt.pickupcopy   = W_GlockPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_glock =
{
    setmodel(self, "models/weapons/wpn_csglock/w_glock.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_glock";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_GLOCK;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_GlockEquip;
    self.weap_drop_func = W_GlockDrop;
    self.pickupcopy    = W_GlockPickupCopy;
    self.touch         = weapon_touch;
    self.mag_glock     = MAX_MAG_GLOCK;
    self.ammo_glock    = MAX_AMMO_GLOCK;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float GLOCK_RELOAD_CLIPOUT_TIME = (GLOCK_RELOAD_CLIPOUT - GLOCK_RELOAD_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_RELOAD_CLIPIN_TIME = (GLOCK_RELOAD_CLIPIN - GLOCK_RELOAD_START) * GLOCK_FRAME_INTERVAL;
const float GLOCK_RELOAD_SLIDE_TIME = (GLOCK_RELOAD_SLIDE_FRAME - GLOCK_RELOAD_START) * GLOCK_FRAME_INTERVAL;

float csqc_glock_reload_snd_stage;

void() CSQC_PredictGlockCommand =
{
    float r;

    // Primary fire (single shot)
    if (input_buttons & 1)
    {
        r = SH_GlockTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
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

    // Alt-fire (burst)
    if (input_buttons & 4)
    {
        r = SH_GlockTryBurst(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
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

    // Burst: fire remaining queued shots client-side
    if (self.glock_burst_count > 0 && csqc_pred_time >= self.glock_burst_next)
    {
        if (self.mag_glock > 0)
        {
            self.mag_glock -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        self.glock_burst_count -= 1;
        self.glock_burst_next = csqc_pred_time + GLOCK_BURST_FIRE_DELAY;
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_glock_reload_snd_stage < 1 && reload_elapsed >= GLOCK_FRAME_INTERVAL)
        {
            localsound("sounds/weapons/wpn_csglock/reload.wav"); CSQC_RecordPredictedAutoSound();
            csqc_glock_reload_snd_stage = 1;
        }
        if (csqc_glock_reload_snd_stage < 2 && reload_elapsed >= GLOCK_RELOAD_CLIPOUT_TIME)
        {
            CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_glock_reload_snd_stage = 2;
        }
        if (csqc_glock_reload_snd_stage < 3 && reload_elapsed >= GLOCK_RELOAD_SLIDE_TIME)
        { localsound("sounds/weapons/wpn_csglock/sliderelease.wav"); CSQC_RecordPredictedAutoSound(); csqc_glock_reload_snd_stage = 3; }
    }

    SH_GlockTickState(csqc_pred_time);
};

void() CSQC_PredictGlockReload =
{
    if (SH_GlockTryReload(csqc_pred_time))
    { csqc_glock_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_GlockDisplayFrame =
{
    float frame;

    // Burst fire uses its own animation range
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        frame = GLOCK_BURST_START + elapsed / GLOCK_FRAME_INTERVAL;
        return bound(GLOCK_BURST_START, frame, GLOCK_BURST_END - 1);
    }

    return CSQC_StandardDisplayFrame(elapsed, GLOCK_FRAME_INTERVAL,
        GLOCK_DRAW_START, GLOCK_DRAW_END,
        GLOCK_FIRE_START, GLOCK_FIRE_END,
        GLOCK_RELOAD_START, GLOCK_RELOAD_END,
        GLOCK_IDLE_FRAME);
};

void() CSQC_GlockDropClear =
{
	self.mag_glock  = 0;
	self.ammo_glock = 0;
};

void() CSQC_GlockEquip =
{
	self.weapon_name         = GLOCK_DISPLAY_NAME;
	self.weapon_viewmodel    = GLOCK_VIEWMODEL;
	self.weapon_worldmodel   = GLOCK_WORLDMODEL;
	self.weapon_deploy_sound = GLOCK_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictGlockCommand;
	self.csqc_predict_reload = CSQC_PredictGlockReload;
	self.csqc_display_frame  = CSQC_GlockDisplayFrame;
	self.csqc_drop_clear     = CSQC_GlockDropClear;
};

#endif // CSQC
