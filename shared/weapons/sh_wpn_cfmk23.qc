// ============================================================
//  shared/weapons/sh_wpn_cfmk23.qc  -  CF MK23 SOCOM (GoldSrc MDL)
//
//  Slot  : SLOT_SECONDARY
//  Stats : 12-round magazine, 36 reserve, semi-auto .45 pistol.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage falloff.
//  Alt   : silencer attach/detach toggle (+attack2, WS_SPECIAL).
//
//  Sequence-driven viewmodel with TWO sequence sets — silenced (0-7)
//  and unsilenced (8-15).  Silencer state in self.cfmk23_silenced,
//  networked via slot_secondary_aux (same convention as M4A1).
//
//  Sequence layout (v_mk23.mdl):
//     0  idle_0          30 fps   (silenced)
//     1-4 prefire        30 fps   (silenced shoot variants)
//     5  reload          25 fps   (blowback@0 clipout@11 clipin@34 delblowback@52)
//     6  select          30 fps
//     7  add             30 fps   (attach silencer:  unsil -> sil)
//     8  idle_unsil      30 fps
//     9-12 prefire_unsil 30 fps   (unsilenced shoot variants)
//     13 reload_unsil    25 fps
//     14 select_unsil    30 fps
//     15 detach          30 fps   (remove silencer:  sil -> unsil)
//
//  Sounds in sounds/weapons/wpn_cfmk23/.
// ============================================================

.float mag_cfmk23;
.float ammo_cfmk23;
.float cfmk23_silenced;

.float cfmk23_snd_stage;
.float cfmk23_silencer_snd_played;

const float CFMK23_SEQ_IDLE          = 0;
const float CFMK23_SEQ_SHOOT1        = 1;
const float CFMK23_SEQ_SHOOT4        = 4;
const float CFMK23_SEQ_RELOAD        = 5;
const float CFMK23_SEQ_SELECT        = 6;
const float CFMK23_SEQ_ADD           = 7;
const float CFMK23_SEQ_IDLE_UNSIL    = 8;
const float CFMK23_SEQ_SHOOT_UNSIL1  = 9;
const float CFMK23_SEQ_RELOAD_UNSIL  = 13;
const float CFMK23_SEQ_SELECT_UNSIL  = 14;
const float CFMK23_SEQ_DETACH        = 15;

// --- Reload sound timings (reload 25 fps) ---
const float CFMK23_RELOAD_BLOWBACK_TIME    = 0.000;   // frame 0
const float CFMK23_RELOAD_CLIPOUT_TIME     = 0.440;   // frame 11 / 25
const float CFMK23_RELOAD_CLIPIN_TIME      = 1.360;   // frame 34 / 25
const float CFMK23_RELOAD_DELBLOWBACK_TIME = 2.080;   // frame 52 / 25
const float CFMK23_SELECT_DEPLOY_TIME      = 0.400;   // select @ 12/30
const float CFMK23_SILENCER_SWAP_TIME      = 2.300;   // slide pullback at frame 70/30fps (end of add/detach)

const float CFMK23_RELOAD_APPLY_TIME = 1.45;

const float CFMK23_FIRE_DELAY        = 0.15;
const float CFMK23_DRYFIRE_DELAY     = 0.20;
const float CFMK23_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFMK23           = 12;
const float MAX_AMMO_CFMK23          = 36;

const float CFMK23_BASE_SPREAD          = 0.012;
const float CFMK23_MOVE_SPREAD          = 0.05;
const float CFMK23_FULL_SPREAD_SPEED    = 250;
const float CFMK23_CLOSE_DAMAGE         = 30;     // .45 ACP pistol
const float CFMK23_MIN_DAMAGE           = 18;
const float CFMK23_SILENCED_CLOSE_DAMAGE = 27;
const float CFMK23_SILENCED_MIN_DAMAGE   = 16;
const float CFMK23_DAMAGE_FALLOFF_RANGE = 1800;

const float CFMK23_KICK_PITCH    = 1.0;
const float CFMK23_KICK_VARIANCE = 0.4;
const float CFMK23_KICK_STRENGTH = 0.9;

// Muzzle attachment — from v_mk23.mdl's $attachment 0:
//     $attachment 0 "gunfire" 0.0 0.0 0.0
const string CFMK23_MUZZLE_BONE   = "gunfire";
#define CFMK23_MUZZLE_OFFSET ('0.0 0.0 0.0')

const string CFMK23_VIEWMODEL    = "models/weapons/wpn_cfmk23/v_mk23.mdl";
const string CFMK23_WORLDMODEL   = "models/weapons/wpn_cfmk23/w_mk23.mdl";
const string CFMK23_DEPLOY_SOUND = "";
const string CFMK23_DISPLAY_NAME = "MK23 SOCOM";

// ============================================================
//  SHARED — silencer-aware sequence helpers + state machine
// ============================================================

float() SH_CFMk23IdleSeq =
{
    if (self.cfmk23_silenced) return CFMK23_SEQ_IDLE;
    return CFMK23_SEQ_IDLE_UNSIL;
};

float() SH_CFMk23ReloadSeq =
{
    if (self.cfmk23_silenced) return CFMK23_SEQ_RELOAD;
    return CFMK23_SEQ_RELOAD_UNSIL;
};

float() SH_CFMk23SelectSeq =
{
    if (self.cfmk23_silenced) return CFMK23_SEQ_SELECT;
    return CFMK23_SEQ_SELECT_UNSIL;
};

float() SH_CFMk23PickShootSeq =
{
    float base = self.cfmk23_silenced ? CFMK23_SEQ_SHOOT1 : CFMK23_SEQ_SHOOT_UNSIL1;
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.25) return base;
    if (r < 0.50) return base + 1;
    if (r < 0.75) return base + 2;
    return base + 3;
};

float(float now) SH_CFMk23TickState =
{
    // WS_SPECIAL (silencer toggle) — flip state at the end of the
    // add/detach animation, then drop to the appropriate idle.
    if (self.weaponstate == WS_SPECIAL)
    {
        float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        float toggle_dur = SH_SeqDuration(CFMK23_VIEWMODEL, self.weaponframe, 2.6);
        if (elapsed >= toggle_dur)
        {
            self.cfmk23_silenced = !self.cfmk23_silenced;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return SH_StandardTickState(now, mag_cfmk23, ammo_cfmk23, MAX_MAG_CFMK23,
        SH_SeqDuration(CFMK23_VIEWMODEL, SH_CFMk23SelectSeq(), 1.0),
        SH_SeqDuration(CFMK23_VIEWMODEL, self.weaponframe,     0.5),
        SH_SeqDuration(CFMK23_VIEWMODEL, SH_CFMk23ReloadSeq(), 2.5),
        CFMK23_RELOAD_APPLY_TIME);
};

float(float now) SH_CFMk23TryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_cfmk23, CFMK23_FIRE_DELAY, CFMK23_DRYFIRE_DELAY);
};

float(float now) SH_CFMk23TryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_cfmk23, ammo_cfmk23, MAX_MAG_CFMK23,
        SH_SeqDuration(CFMK23_VIEWMODEL, SH_CFMk23ReloadSeq(), 2.5));
};

float(float now) SH_CFMk23TryAltFire =
{
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished)
        return 0;

    // silenced -> detach (remove); unsilenced -> add (attach).
    float seq = self.cfmk23_silenced ? CFMK23_SEQ_DETACH : CFMK23_SEQ_ADD;
    self.weaponstate     = WS_SPECIAL;
    self.weaponframe     = seq;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SH_SeqDuration(CFMK23_VIEWMODEL, seq, 2.6);
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFMk23PickupCopy =
{
    player.mag_cfmk23      = self.mag_cfmk23;
    player.ammo_cfmk23     = self.ammo_cfmk23;
    player.cfmk23_silenced = self.cfmk23_silenced;
};

void() W_CFMk23Shoot =
{
    float close_dmg, min_dmg;
    if (self.cfmk23_silenced) { close_dmg = CFMK23_SILENCED_CLOSE_DAMAGE; min_dmg = CFMK23_SILENCED_MIN_DAMAGE; }
    else                      { close_dmg = CFMK23_CLOSE_DAMAGE;          min_dmg = CFMK23_MIN_DAMAGE; }

    W_PenetratingHitscanShoot(CFMK23_BASE_SPREAD, CFMK23_MOVE_SPREAD, CFMK23_FULL_SPREAD_SPEED,
        close_dmg, min_dmg, CFMK23_DAMAGE_FALLOFF_RANGE, 32, 0.95,
        CFMK23_KICK_PITCH, CFMK23_KICK_VARIANCE, CFMK23_KICK_STRENGTH);
};

void() W_CFMk23Fire =
{
    float r = SH_CFMk23TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFMk23PickShootSeq();
        self.wep_nextframe = time + CFMK23_FRAME_INTERVAL;

        W_CFMk23Shoot();

        if (self.cfmk23_silenced)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmk23/fire-silenced.WAV", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmk23/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFMk23Reload =
{
    if (SH_CFMk23TryReload(time))
    {
        self.weaponframe   = SH_CFMk23ReloadSeq();
        self.wep_nextframe = time + CFMK23_FRAME_INTERVAL;
        self.cfmk23_snd_stage = 0;
    }
};

void() W_CFMk23AltFire =
{
    if (SH_CFMk23TryAltFire(time))
    {
        self.wep_nextframe = time + CFMK23_FRAME_INTERVAL;
        self.cfmk23_silencer_snd_played = 0;
    }
};

void() W_CFMk23Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFMK23_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFMK23_SELECT_DEPLOY_TIME && self.cfmk23_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/draw.WAV", 1, ATTN_NORM);
            self.cfmk23_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= CFMK23_SILENCER_SWAP_TIME && !self.cfmk23_silencer_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/draw.WAV", 1, ATTN_NORM);
            self.cfmk23_silencer_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFMK23_RELOAD_BLOWBACK_TIME && self.cfmk23_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/blowback.WAV", 1, ATTN_NORM);
            self.cfmk23_snd_stage = 1;
        }
        if (elapsed >= CFMK23_RELOAD_CLIPOUT_TIME && self.cfmk23_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.cfmk23_snd_stage = 2;
        }
        if (elapsed >= CFMK23_RELOAD_CLIPIN_TIME && self.cfmk23_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/clipin.WAV", 1, ATTN_NORM);
            self.cfmk23_snd_stage = 3;
        }
        if (elapsed >= CFMK23_RELOAD_DELBLOWBACK_TIME && self.cfmk23_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmk23/delblowback.WAV", 1, ATTN_NORM);
            self.cfmk23_snd_stage = 4;
        }
    }

    result = SH_CFMk23TickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_CFMk23IdleSeq();
        self.wep_nextframe = 0;
        self.cfmk23_snd_stage = 0;
    }
};

void() W_CFMk23Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_mk23", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFMK23_VIEWMODEL, CFMK23_DISPLAY_NAME, SH_CFMk23SelectSeq(),
        CFMK23_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFMk23Fire;
    self.reload   = W_CFMk23Reload;
    self.wepframe = W_CFMk23Frame;
    self.special  = W_CFMk23AltFire;   // silencer toggle on weapon-special (impulse 7)
    self.shoot    = W_CFMk23Shoot;
    self.cfmk23_snd_stage = 0;
    W_SetCrosshairProfile(CFMK23_BASE_SPREAD, CFMK23_MOVE_SPREAD, CFMK23_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_CFMk23Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfmk23      = self.mag_cfmk23;
    tgt.ammo_cfmk23     = self.ammo_cfmk23;
    tgt.cfmk23_silenced = self.cfmk23_silenced;

    self.mag_cfmk23      = 0;
    self.ammo_cfmk23     = 0;
    self.cfmk23_silenced = 0;

    setmodel(tgt, CFMK23_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfmk23";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFMK23;
    tgt.weapon_slot   = SLOT_SECONDARY;
    tgt.weap_draw     = W_CFMk23Equip;
    tgt.weap_drop_func = W_CFMk23Drop;
    tgt.pickupcopy    = W_CFMk23PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfmk23 =
{
    setmodel(self, CFMK23_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_cfmk23";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFMK23;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFMk23Equip;
    self.weap_drop_func = W_CFMk23Drop;
    self.pickupcopy    = W_CFMk23PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfmk23    = MAX_MAG_CFMK23;
    self.ammo_cfmk23   = MAX_AMMO_CFMK23;
    self.cfmk23_silenced = TRUE;
    W_RegisterMapWeapon(weapon_cfmk23);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfmk23_snd_stage;
float csqc_cfmk23_silencer_snd_played;
float csqc_cfmk23_snd_action;

void() CSQC_PredictCFMk23Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfmk23_snd_action)
    {
        csqc_cfmk23_snd_action = predicted_player.wep_action_id;
        csqc_cfmk23_snd_stage  = 0;
        csqc_cfmk23_silencer_snd_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFMk23TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (self.cfmk23_silenced)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmk23/fire-silenced.WAV", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmk23/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFMK23_BASE_SPREAD, CFMK23_MOVE_SPREAD, CFMK23_FULL_SPREAD_SPEED,
                    self.cfmk23_silenced ? CFMK23_SILENCED_CLOSE_DAMAGE : CFMK23_CLOSE_DAMAGE,
                    self.cfmk23_silenced ? CFMK23_SILENCED_MIN_DAMAGE   : CFMK23_MIN_DAMAGE,
                    CFMK23_DAMAGE_FALLOFF_RANGE, 32, 0.95,
                    CFMK23_KICK_PITCH, CFMK23_KICK_VARIANCE, CFMK23_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Silenced suppresses the flash — smoke only.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFMK23_MUZZLE_BONE, CFMK23_MUZZLE_OFFSET);
                if (!self.cfmk23_silenced)
                    CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
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


    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_cfmk23_snd_stage < 1 && elapsed >= CFMK23_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmk23_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            if (!csqc_cfmk23_silencer_snd_played && elapsed >= CFMK23_SILENCER_SWAP_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmk23_silencer_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfmk23_snd_stage < 1 && elapsed >= CFMK23_RELOAD_BLOWBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/blowback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmk23_snd_stage = 1;
            }
            if (csqc_cfmk23_snd_stage < 2 && elapsed >= CFMK23_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfmk23_snd_stage = 2;
            }
            if (csqc_cfmk23_snd_stage < 3 && elapsed >= CFMK23_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmk23_snd_stage = 3;
            }
            if (csqc_cfmk23_snd_stage < 4 && elapsed >= CFMK23_RELOAD_DELBLOWBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfmk23/delblowback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmk23_snd_stage = 4;
            }
        }
    }

    SH_CFMk23TickState(csqc_pred_time);
};

void() CSQC_PredictCFMk23Reload =
{
    if (SH_CFMk23TryReload(csqc_pred_time))
    {
        csqc_cfmk23_snd_stage  = 0;
        csqc_cfmk23_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFMk23DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return predicted_player.cfmk23_silenced ? CFMK23_SEQ_SELECT : CFMK23_SEQ_SELECT_UNSIL;
    if (predicted_player.weaponstate == WS_SPECIAL)
        // Mid-toggle: silenced means we're DETACHing; unsil means ADDing.
        return predicted_player.cfmk23_silenced ? CFMK23_SEQ_DETACH : CFMK23_SEQ_ADD;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        float base = predicted_player.cfmk23_silenced ? CFMK23_SEQ_SHOOT1 : CFMK23_SEQ_SHOOT_UNSIL1;
        float r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.25) return base;
        if (r < 0.50) return base + 1;
        if (r < 0.75) return base + 2;
        return base + 3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return predicted_player.cfmk23_silenced ? CFMK23_SEQ_RELOAD : CFMK23_SEQ_RELOAD_UNSIL;

    return predicted_player.cfmk23_silenced ? CFMK23_SEQ_IDLE : CFMK23_SEQ_IDLE_UNSIL;
};

void() CSQC_CFMk23DropClear =
{
    self.mag_cfmk23      = 0;
    self.ammo_cfmk23     = 0;
    self.cfmk23_silenced = 0;
};

// Weapon special (impulse 7) — silencer toggle, predicted client-side.
// Dispatched from CSQC_PredictWeaponImpulse.
void() CSQC_PredictCFMk23Special =
{
    if (SH_CFMk23TryAltFire(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_cfmk23_silencer_snd_played = 0;
    }
};

void() CSQC_CFMk23Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_mk23", SCOPE_CLASS_NONE);
    self.weapon_name         = CFMK23_DISPLAY_NAME;
    self.weapon_viewmodel    = CFMK23_VIEWMODEL;
    self.weapon_worldmodel   = CFMK23_WORLDMODEL;
    self.weapon_deploy_sound = CFMK23_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFMk23Command;
    self.csqc_predict_reload = CSQC_PredictCFMk23Reload;
    self.csqc_display_frame  = CSQC_CFMk23DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFMk23DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFMK23_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFMK23_MUZZLE_OFFSET;
};

#endif // CSQC
