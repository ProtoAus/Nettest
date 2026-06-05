// ============================================================
//  shared/weapons/sh_wpn_cfmp5.qc  -  CF MP5 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 30-round magazine, 120 reserve, full-auto 9mm SMG.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage
//          falloff.  Bullets pass through thin geometry/targets.
//
//  GoldSrc-format viewmodel — sequence-driven; durations from the
//  model via SH_SeqDuration.  Same pattern as cfmac10.
//
//  Sequence layout (v_mp5.mdl):
//     0  idle_0    30 fps
//     1  reload    29 fps  (clipout @ 7, clipin @ 24, reload-tail @ 38)
//     2  select    35 fps  (deploy @ 6)
//     3  prefire1  30 fps
//     4  prefire2  30 fps
//     5  prefire3  30 fps
//
//  Sounds in sounds/weapons/wpn_cfmp5/.  NOTE: no draw.WAV ships with
//  this model — deploy reuses reload.WAV (same trick cfaug uses).
// ============================================================

.float mag_cfmp5;
.float ammo_cfmp5;

const float CFMP5_SEQ_IDLE   = 0;
const float CFMP5_SEQ_RELOAD = 1;
const float CFMP5_SEQ_SELECT = 2;
const float CFMP5_SEQ_SHOOT1 = 3;
const float CFMP5_SEQ_SHOOT2 = 4;
const float CFMP5_SEQ_SHOOT3 = 5;

const float CFMP5_RELOAD_APPLY_TIME = 0.95;   // ~clipin + small gap

const float CFMP5_FIRE_DELAY        = 0.075;  // ~800 rpm cyclic
const float CFMP5_DRYFIRE_DELAY     = 0.20;
const float CFMP5_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (reload 29 fps, select 35 fps) ---
//   reload  clipout    @ frame 7  / 29 = 0.241s
//   reload  clipin     @ frame 24 / 29 = 0.828s
//   reload  reload-tail @ frame 38 / 29 = 1.310s
//   select  deploy     @ frame 6  / 35 = 0.171s
const float CFMP5_RELOAD_CLIPOUT_TIME = 0.241;
const float CFMP5_RELOAD_CLIPIN_TIME  = 0.828;
const float CFMP5_RELOAD_TAIL_TIME    = 1.310;
const float CFMP5_SELECT_DEPLOY_TIME  = 0.171;

const float MAX_MAG_CFMP5             = 30;
const float MAX_AMMO_CFMP5            = 120;

const float CFMP5_BASE_SPREAD          = 0.01;
const float CFMP5_MOVE_SPREAD          = 0.07;
const float CFMP5_FULL_SPREAD_SPEED    = 320;
const float CFMP5_CLOSE_DAMAGE         = 20;     // 9mm SMG
const float CFMP5_MIN_DAMAGE           = 10;
const float CFMP5_DAMAGE_FALLOFF_RANGE = 1900;

const float CFMP5_KICK_PITCH    = 0.8;
const float CFMP5_KICK_VARIANCE = 0.4;
const float CFMP5_KICK_STRENGTH = 1.0;

// Muzzle attachment — from v_mp5.mdl's $attachment 0:
//     $attachment 0 "Bone01" 17.0 0.0 0.0
const string CFMP5_MUZZLE_BONE   = "Bone01";
#define CFMP5_MUZZLE_OFFSET ('17.0 0.0 0.0')

const string CFMP5_VIEWMODEL    = "models/weapons/wpn_cfmp5/v_mp5.mdl";
const string CFMP5_WORLDMODEL   = "models/weapons/wpn_cfmp5/w_mp5.mdl";
const string CFMP5_DEPLOY_SOUND = "";
const string CFMP5_DISPLAY_NAME = "CF MP5";

.float cfmp5_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFMp5PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFMP5_SEQ_SHOOT1;
    if (r < 0.67) return CFMP5_SEQ_SHOOT2;
    return CFMP5_SEQ_SHOOT3;
};

float(float now) SH_CFMp5TickState =
{
    return SH_StandardTickState(now, mag_cfmp5, ammo_cfmp5, MAX_MAG_CFMP5,
        SH_SeqDuration(CFMP5_VIEWMODEL, CFMP5_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFMP5_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFMP5_VIEWMODEL, CFMP5_SEQ_RELOAD, 1.5),
        CFMP5_RELOAD_APPLY_TIME);
};

float(float now) SH_CFMp5TryFire =
{
    return SH_StandardTryFire(now, mag_cfmp5, CFMP5_FIRE_DELAY, CFMP5_DRYFIRE_DELAY);
};

float(float now) SH_CFMp5TryReload =
{
    return SH_StandardTryReload(now, mag_cfmp5, ammo_cfmp5, MAX_MAG_CFMP5,
        SH_SeqDuration(CFMP5_VIEWMODEL, CFMP5_SEQ_RELOAD, 1.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFMp5PickupCopy =
{
    player.mag_cfmp5  = self.mag_cfmp5;
    player.ammo_cfmp5 = self.ammo_cfmp5;
};

void() W_CFMp5Shoot =
{
    W_PenetratingHitscanShoot(CFMP5_BASE_SPREAD, CFMP5_MOVE_SPREAD, CFMP5_FULL_SPREAD_SPEED,
        CFMP5_CLOSE_DAMAGE, CFMP5_MIN_DAMAGE, CFMP5_DAMAGE_FALLOFF_RANGE, 32, 0.95,
        CFMP5_KICK_PITCH, CFMP5_KICK_VARIANCE, CFMP5_KICK_STRENGTH);
};

void() W_CFMp5Fire =
{
    float r = SH_CFMp5TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFMp5PickShootSeq();
        self.wep_nextframe = time + CFMP5_FRAME_INTERVAL;
        self.cfmp5_snd_stage = 0;

        W_CFMp5Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmp5/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFMp5Reload =
{
    if (SH_CFMp5TryReload(time))
    {
        self.weaponframe   = CFMP5_SEQ_RELOAD;
        self.wep_nextframe = time + CFMP5_FRAME_INTERVAL;
        self.cfmp5_snd_stage = 0;
    }
};

void() W_CFMp5Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFMP5_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        // No draw.WAV ships — reuse reload.WAV as the deploy cue.
        if (elapsed >= CFMP5_SELECT_DEPLOY_TIME && self.cfmp5_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmp5/reload.WAV", 1, ATTN_NORM);
            self.cfmp5_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFMP5_RELOAD_CLIPOUT_TIME && self.cfmp5_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmp5/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.cfmp5_snd_stage = 1;
        }
        if (elapsed >= CFMP5_RELOAD_CLIPIN_TIME && self.cfmp5_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmp5/clipin.WAV", 1, ATTN_NORM);
            self.cfmp5_snd_stage = 2;
        }
        if (elapsed >= CFMP5_RELOAD_TAIL_TIME && self.cfmp5_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmp5/reload.WAV", 1, ATTN_NORM);
            self.cfmp5_snd_stage = 3;
        }
    }

    result = SH_CFMp5TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFMP5_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfmp5_snd_stage = 0;
    }
};

void() W_CFMp5Equip =
{
    W_StandardEquipSetup(CFMP5_VIEWMODEL, CFMP5_DISPLAY_NAME, CFMP5_SEQ_SELECT,
        CFMP5_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFMp5Fire;
    self.reload   = W_CFMp5Reload;
    self.wepframe = W_CFMp5Frame;
    self.shoot    = W_CFMp5Shoot;
    self.cfmp5_snd_stage = 0;
    W_SetCrosshairProfile(CFMP5_BASE_SPREAD, CFMP5_MOVE_SPREAD, CFMP5_FULL_SPREAD_SPEED, 1.7, TRUE);
};

void() W_CFMp5Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfmp5  = self.mag_cfmp5;
    tgt.ammo_cfmp5 = self.ammo_cfmp5;

    self.mag_cfmp5  = 0;
    self.ammo_cfmp5 = 0;

    setmodel(tgt, CFMP5_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfmp5";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFMP5;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFMp5Equip;
    tgt.weap_drop_func = W_CFMp5Drop;
    tgt.pickupcopy    = W_CFMp5PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfmp5 =
{
    setmodel(self, CFMP5_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfmp5";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFMP5;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFMp5Equip;
    self.weap_drop_func = W_CFMp5Drop;
    self.pickupcopy   = W_CFMp5PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfmp5    = MAX_MAG_CFMP5;
    self.ammo_cfmp5   = MAX_AMMO_CFMP5;
    W_RegisterMapWeapon(weapon_cfmp5);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfmp5_snd_stage;
float csqc_cfmp5_snd_action;

void() CSQC_PredictCFMp5Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfmp5_snd_action)
    {
        csqc_cfmp5_snd_action = predicted_player.wep_action_id;
        csqc_cfmp5_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFMp5TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmp5/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFMP5_BASE_SPREAD, CFMP5_MOVE_SPREAD, CFMP5_FULL_SPREAD_SPEED,
                    CFMP5_CLOSE_DAMAGE, CFMP5_MIN_DAMAGE, CFMP5_DAMAGE_FALLOFF_RANGE, 32, 0.95,
                    CFMP5_KICK_PITCH, CFMP5_KICK_VARIANCE, CFMP5_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFMP5_MUZZLE_BONE, CFMP5_MUZZLE_OFFSET);
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
            if (csqc_cfmp5_snd_stage < 1 && elapsed >= CFMP5_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfmp5/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmp5_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfmp5_snd_stage < 1 && elapsed >= CFMP5_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfmp5/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfmp5_snd_stage = 1;
            }
            if (csqc_cfmp5_snd_stage < 2 && elapsed >= CFMP5_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfmp5/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmp5_snd_stage = 2;
            }
            if (csqc_cfmp5_snd_stage < 3 && elapsed >= CFMP5_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfmp5/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmp5_snd_stage = 3;
            }
        }
    }

    SH_CFMp5TickState(csqc_pred_time);
};

void() CSQC_PredictCFMp5Reload =
{
    if (SH_CFMp5TryReload(csqc_pred_time))
    {
        csqc_cfmp5_snd_stage  = 0;
        csqc_cfmp5_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFMp5DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFMP5_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFMP5_SEQ_SHOOT1;
        if (r < 0.67) return CFMP5_SEQ_SHOOT2;
        return CFMP5_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFMP5_SEQ_RELOAD;

    return CFMP5_SEQ_IDLE;
};

void() CSQC_CFMp5DropClear =
{
    self.mag_cfmp5 = 0;
    self.ammo_cfmp5 = 0;
};

void() CSQC_CFMp5Equip =
{
    self.weapon_name         = CFMP5_DISPLAY_NAME;
    self.weapon_viewmodel    = CFMP5_VIEWMODEL;
    self.weapon_worldmodel   = CFMP5_WORLDMODEL;
    self.weapon_deploy_sound = CFMP5_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFMp5Command;
    self.csqc_predict_reload = CSQC_PredictCFMp5Reload;
    self.csqc_display_frame  = CSQC_CFMp5DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFMp5DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFMP5_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFMP5_MUZZLE_OFFSET;
};

#endif // CSQC
