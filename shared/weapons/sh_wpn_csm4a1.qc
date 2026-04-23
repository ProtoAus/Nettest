// ============================================================
//  shared/weapons/sh_wpn_csm4a1.qc  -  CS M4A1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : silencer toggle (WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo & state fields ---
.float mag_m4a1;
.float ammo_m4a1;
.float m4a1_silenced;

// --- Animation frames ---
const float M4A1_FRAME_INTERVAL       = 0.0333334;   // 1/30

const float M4A1_DRAW_START           = 1;
const float M4A1_DRAW_END             = 20;
const float M4A1_DRAW_SND_FRAME       = 3;

const float M4A1_FIRE_START           = 22;
const float M4A1_FIRE_END             = 50;
const float M4A1_FIRE_DELAY           = 0.1;         // 3/30

const float M4A1_RELOAD_START         = 112;
const float M4A1_RELOAD_END           = 173;
const float M4A1_RELOAD_CLIPOUT       = 123;
const float M4A1_RELOAD_CLIPIN        = 139;
const float M4A1_RELOAD_APPLY         = 139;
const float M4A1_RELOAD_BOLTPULL      = 158;

const float M4A1_SILENCER_START       = 174;
const float M4A1_SILENCER_END         = 214;
const float M4A1_SILENCER_SWAP_FRAME  = 190;
const float M4A1_SILENCER_DELAY       = 1.3666667;   // 41/30

const float M4A1_IDLE_FRAME           = 50;

const float MAX_MAG_M4A1              = 30;
const float MAX_AMMO_M4A1             = 90;

// --- Balance ---
const float M4A1_BASE_SPREAD            = 0.01;
const float M4A1_MOVE_SPREAD            = 0.06;
const float M4A1_FULL_SPREAD_SPEED      = 320;
const float M4A1_CLOSE_DAMAGE           = 24;
const float M4A1_MIN_DAMAGE             = 14;
const float M4A1_SILENCED_CLOSE_DAMAGE  = 22;
const float M4A1_SILENCED_MIN_DAMAGE    = 12;
const float M4A1_DAMAGE_FALLOFF_RANGE   = 3072;
const float M4A1_DRYFIRE_DELAY          = 0.2;

// --- Pre-computed state durations ---
const float M4A1_DRAW_DURATION        = (M4A1_DRAW_END - M4A1_DRAW_START) * M4A1_FRAME_INTERVAL;
const float M4A1_FIRE_DURATION        = (M4A1_FIRE_END - M4A1_FIRE_START) * M4A1_FRAME_INTERVAL;
const float M4A1_RELOAD_DURATION      = (M4A1_RELOAD_END - M4A1_RELOAD_START) * M4A1_FRAME_INTERVAL;
const float M4A1_RELOAD_APPLY_TIME    = (M4A1_RELOAD_APPLY - M4A1_RELOAD_START) * M4A1_FRAME_INTERVAL;
const float M4A1_SILENCER_DURATION    = (M4A1_SILENCER_END - M4A1_SILENCER_START) * M4A1_FRAME_INTERVAL;
const float M4A1_SILENCER_SWAP_TIME   = (M4A1_SILENCER_SWAP_FRAME - M4A1_SILENCER_START) * M4A1_FRAME_INTERVAL;

const string M4A1_VIEWMODEL       = "models/weapons/wpn_csm4a1/v_m4a1.mdl";
const string M4A1_VIEWMODEL_UNSIL = "models/weapons/wpn_csm4a1/v_m4a1_unsil.mdl";
const string M4A1_WORLDMODEL      = "models/weapons/wpn_csm4a1/w_m4a1.mdl";
const string M4A1_DEPLOY_SOUND    = "sounds/weapons/wpn_csm4a1/deploy.wav";
const string M4A1_DISPLAY_NAME    = "M4A1";

// ============================================================
//  SHARED — state machine
// ============================================================

// Returns viewmodel path based on silencer state
string() SH_M4A1ViewModel =
{
    if (self.m4a1_silenced)
        return M4A1_VIEWMODEL;
    return M4A1_VIEWMODEL_UNSIL;
};

// Returns bitmask: bit 0 = idle, bit 1 = reload ammo applied
float(float now) SH_M4A1TickState =
{
    float elapsed, result;

    // WS_SPECIAL (silencer toggle) — handle locally
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= M4A1_SILENCER_DURATION)
        {
            self.m4a1_silenced = !self.m4a1_silenced;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return SH_StandardTickState(now, mag_m4a1, ammo_m4a1, MAX_MAG_M4A1,
        M4A1_DRAW_DURATION, M4A1_FIRE_DURATION,
        M4A1_RELOAD_DURATION, M4A1_RELOAD_APPLY_TIME);
};

float(float now) SH_M4A1TryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_m4a1, M4A1_FIRE_DELAY, M4A1_DRYFIRE_DELAY);
};

float(float now) SH_M4A1TryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_m4a1, ammo_m4a1, MAX_MAG_M4A1, M4A1_RELOAD_DURATION);
};

float(float now) SH_M4A1TryAltFire =
{
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + M4A1_SILENCER_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M4A1PickupCopy =
{
    player.mag_m4a1      = self.mag_m4a1;
    player.ammo_m4a1     = self.ammo_m4a1;
    player.m4a1_silenced = self.m4a1_silenced;
};

void() W_M4A1Shoot =
{
    float close_dmg, min_dmg;

    if (self.m4a1_silenced)
    {
        close_dmg = M4A1_SILENCED_CLOSE_DAMAGE;
        min_dmg   = M4A1_SILENCED_MIN_DAMAGE;
    }
    else
    {
        close_dmg = M4A1_CLOSE_DAMAGE;
        min_dmg   = M4A1_MIN_DAMAGE;
    }

    W_PenetratingHitscanShoot(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED,
        close_dmg, min_dmg, M4A1_DAMAGE_FALLOFF_RANGE, 48, 0.97);
};

void() W_M4A1Fire =
{
    float r = SH_M4A1TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = M4A1_FIRE_START;
        self.wep_nextframe = time + M4A1_FRAME_INTERVAL;

        W_M4A1Shoot();

        if (self.m4a1_silenced)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/sfire1.wav", 1, ATTN_NORM);
        }
        else
        {
            if (random() < 0.5)
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/fire1.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/fire2.wav", 1, ATTN_NORM);
        }

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_M4A1Reload =
{
    if (SH_M4A1TryReload(time))
    {
        self.weaponframe   = M4A1_RELOAD_START;
        self.wep_nextframe = time + M4A1_FRAME_INTERVAL;
    }
};

void() W_M4A1AltFire =
{
    if (SH_M4A1TryAltFire(time))
    {
        self.weaponframe   = M4A1_SILENCER_START;
        self.wep_nextframe = time + M4A1_FRAME_INTERVAL;
    }
};

void() W_M4A1Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += M4A1_FRAME_INTERVAL;

    // Server-only: sounds at specific frames
    if (self.weaponstate == WS_DRAW && self.weaponframe == M4A1_DRAW_SND_FRAME)
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/deploy.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == M4A1_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == M4A1_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/clipin.wav", 1, ATTN_NORM);
        if (self.weaponframe == M4A1_RELOAD_BOLTPULL)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/boltpull.wav", 1, ATTN_NORM);
    }

    if (self.weaponstate == WS_SPECIAL && self.weaponframe == M4A1_SILENCER_SWAP_FRAME)
    {
        if (self.m4a1_silenced)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/silenceroff.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/silenceron.wav", 1, ATTN_NORM);
    }

    result = SH_M4A1TickState(time);

    if (result & 1)
    {
        self.weaponframe   = M4A1_IDLE_FRAME;
        self.wep_nextframe = 0;
        // Update viewmodel after silencer toggle animation completes
        self.weaponmodel = SH_M4A1ViewModel();
    }
};

void() W_M4A1Equip =
{
    W_StandardEquipSetup(M4A1_VIEWMODEL, M4A1_DISPLAY_NAME, M4A1_DRAW_START,
        M4A1_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.weaponmodel = SH_M4A1ViewModel();  // override: silencer-dependent
    self.fire     = W_M4A1Fire;
    self.reload   = W_M4A1Reload;
    self.wepframe = W_M4A1Frame;
    self.altfire  = W_M4A1AltFire;
    self.shoot    = W_M4A1Shoot;
    W_SetCrosshairProfile(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED, 1.9, TRUE);
};

void() W_M4A1Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_m4a1      = self.mag_m4a1;
    tgt.ammo_m4a1     = self.ammo_m4a1;
    tgt.m4a1_silenced = self.m4a1_silenced;

    self.mag_m4a1      = 0;
    self.ammo_m4a1     = 0;
    self.m4a1_silenced = 0;

    setmodel(tgt, "models/weapons/wpn_csm4a1/w_m4a1.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_m4a1";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_M4A1;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_M4A1Equip;
    tgt.weap_drop_func = W_M4A1Drop;
    tgt.pickupcopy   = W_M4A1PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.dropped_spin = 1;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_m4a1 =
{
    setmodel(self, "models/weapons/wpn_csm4a1/w_m4a1.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_m4a1";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_M4A1;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_M4A1Equip;
    self.weap_drop_func = W_M4A1Drop;
    self.pickupcopy    = W_M4A1PickupCopy;
    self.touch         = weapon_touch;
    self.dropped_spin  = 1;
    self.mag_m4a1      = MAX_MAG_M4A1;
    self.ammo_m4a1     = MAX_AMMO_M4A1;
    self.m4a1_silenced = TRUE;
    W_RegisterMapWeapon(weapon_m4a1);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float M4A1_RELOAD_CLIPOUT_TIME = (M4A1_RELOAD_CLIPOUT - M4A1_RELOAD_START) * M4A1_FRAME_INTERVAL;
const float M4A1_RELOAD_CLIPIN_TIME = (M4A1_RELOAD_CLIPIN - M4A1_RELOAD_START) * M4A1_FRAME_INTERVAL;
const float M4A1_RELOAD_BOLTPULL_TIME = (M4A1_RELOAD_BOLTPULL - M4A1_RELOAD_START) * M4A1_FRAME_INTERVAL;

float csqc_m4a1_reload_snd_stage;
float csqc_m4a1_silencer_snd_played;

void() CSQC_PredictM4A1Command =
{
    float r;

    // Try fire
    if (input_buttons & 1)
    {
        r = SH_M4A1TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (self.m4a1_silenced)
                    localsound("sounds/weapons/wpn_csm4a1/sfire1.wav");
                else
                {
                    if (random() < 0.5)
                        localsound("sounds/weapons/wpn_csm4a1/fire1.wav");
                    else
                        localsound("sounds/weapons/wpn_csm4a1/fire2.wav");
                }
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED,
                    self.m4a1_silenced ? M4A1_SILENCED_CLOSE_DAMAGE : M4A1_CLOSE_DAMAGE,
                    self.m4a1_silenced ? M4A1_SILENCED_MIN_DAMAGE   : M4A1_MIN_DAMAGE,
                    M4A1_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Try alt-fire (silencer toggle)
    if (input_buttons & 4)
    {
        if (SH_M4A1TryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_m4a1_silencer_snd_played = FALSE;
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_m4a1_reload_snd_stage < 1 && reload_elapsed >= M4A1_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csm4a1/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_m4a1_reload_snd_stage = 1;
        }
        if (csqc_m4a1_reload_snd_stage < 2 && reload_elapsed >= M4A1_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csm4a1/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_reload_snd_stage = 2; }
        if (csqc_m4a1_reload_snd_stage < 3 && reload_elapsed >= M4A1_RELOAD_BOLTPULL_TIME)
        { localsound("sounds/weapons/wpn_csm4a1/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_reload_snd_stage = 3; }
    }

    // Predicted silencer toggle sound
    if (self.weaponstate == WS_SPECIAL && !csqc_m4a1_silencer_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= M4A1_SILENCER_SWAP_TIME)
        {
            if (self.m4a1_silenced)
                localsound("sounds/weapons/wpn_csm4a1/silenceroff.wav");
            else
                localsound("sounds/weapons/wpn_csm4a1/silenceron.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_m4a1_silencer_snd_played = TRUE;
        }
    }

    SH_M4A1TickState(csqc_pred_time);
};

void() CSQC_PredictM4A1Reload =
{
    if (SH_M4A1TryReload(csqc_pred_time))
    { csqc_m4a1_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_M4A1DisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        frame = M4A1_SILENCER_START + elapsed / M4A1_FRAME_INTERVAL;
        return bound(M4A1_SILENCER_START, frame, M4A1_SILENCER_END - 1);
    }
    return CSQC_StandardDisplayFrame(elapsed, M4A1_FRAME_INTERVAL,
        M4A1_DRAW_START, M4A1_DRAW_END,
        M4A1_FIRE_START, M4A1_FIRE_END,
        M4A1_RELOAD_START, M4A1_RELOAD_END,
        M4A1_IDLE_FRAME);
};

void() CSQC_M4A1DropClear =
{
	self.mag_m4a1 = 0;
	self.ammo_m4a1 = 0;
	self.m4a1_silenced = 0;
};

void() CSQC_M4A1Equip =
{
	self.weapon_name         = M4A1_DISPLAY_NAME;
	self.weapon_viewmodel    = SH_M4A1ViewModel();
	self.weapon_worldmodel   = M4A1_WORLDMODEL;
	self.weapon_deploy_sound = M4A1_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM4A1Command;
	self.csqc_predict_reload = CSQC_PredictM4A1Reload;
	self.csqc_display_frame  = CSQC_M4A1DisplayFrame;
	self.csqc_drop_clear     = CSQC_M4A1DropClear;
};

#endif // CSQC
