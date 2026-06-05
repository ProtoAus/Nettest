// ============================================================
//  shared/weapons/sh_wpn_cftype89.qc  -  CF Type 89 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56 rifle.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage
//          falloff.  Rifle round — penetrates more than the SMGs.
//
//  GoldSrc-format viewmodel — sequence-driven; durations from the
//  model via SH_SeqDuration.  Same pattern as cfaug.
//
//  Sequence layout (v_type89.mdl):
//     0  idle_0    30 fps
//     1  reload    27 fps  (clipout @ 8, clipin @ 31, reload-tail @ 60)
//     2  select    35 fps  (deploy @ 2)
//     3  prefire1  30 fps
//     4  prefire2  30 fps
//     5  prefire3  30 fps
//
//  Sounds in sounds/weapons/wpn_cftype89/.
// ============================================================

.float mag_cftype89;
.float ammo_cftype89;

const float CFTYPE89_SEQ_IDLE   = 0;
const float CFTYPE89_SEQ_RELOAD = 1;
const float CFTYPE89_SEQ_SELECT = 2;
const float CFTYPE89_SEQ_SHOOT1 = 3;
const float CFTYPE89_SEQ_SHOOT2 = 4;
const float CFTYPE89_SEQ_SHOOT3 = 5;

const float CFTYPE89_RELOAD_APPLY_TIME = 1.25;   // ~clipin + small gap

const float CFTYPE89_FIRE_DELAY        = 0.0857; // ~700 rpm cyclic
const float CFTYPE89_DRYFIRE_DELAY     = 0.20;
const float CFTYPE89_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (reload 27 fps, select 35 fps) ---
//   reload  clipout    @ frame 8  / 27 = 0.296s
//   reload  clipin     @ frame 31 / 27 = 1.148s
//   reload  reload-tail @ frame 60 / 27 = 2.222s
//   select  deploy     @ frame 2  / 35 = 0.057s
const float CFTYPE89_RELOAD_CLIPOUT_TIME = 0.296;
const float CFTYPE89_RELOAD_CLIPIN_TIME  = 1.148;
const float CFTYPE89_RELOAD_TAIL_TIME    = 2.222;
const float CFTYPE89_SELECT_DEPLOY_TIME  = 0.057;

const float MAX_MAG_CFTYPE89             = 30;
const float MAX_AMMO_CFTYPE89            = 90;

const float CFTYPE89_BASE_SPREAD          = 0.01;
const float CFTYPE89_MOVE_SPREAD          = 0.07;
const float CFTYPE89_FULL_SPREAD_SPEED    = 320;
const float CFTYPE89_CLOSE_DAMAGE         = 30;     // 5.56 rifle
const float CFTYPE89_MIN_DAMAGE           = 21;
const float CFTYPE89_DAMAGE_FALLOFF_RANGE = 2304;

const float CFTYPE89_KICK_PITCH    = 1.3;
const float CFTYPE89_KICK_VARIANCE = 1.2;
const float CFTYPE89_KICK_STRENGTH = 1.0;

// Muzzle attachment — from v_type89.mdl's $attachment 0:
//     $attachment 0 "Bone01" 28.0 0.0 0.0
const string CFTYPE89_MUZZLE_BONE   = "Bone01";
#define CFTYPE89_MUZZLE_OFFSET ('28.0 0.0 0.0')

const string CFTYPE89_VIEWMODEL    = "models/weapons/wpn_cftype89/v_type89.mdl";
const string CFTYPE89_WORLDMODEL   = "models/weapons/wpn_cftype89/w_type89.mdl";
const string CFTYPE89_DEPLOY_SOUND = "";
const string CFTYPE89_DISPLAY_NAME = "Type 89";

.float cftype89_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFType89PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFTYPE89_SEQ_SHOOT1;
    if (r < 0.67) return CFTYPE89_SEQ_SHOOT2;
    return CFTYPE89_SEQ_SHOOT3;
};

float(float now) SH_CFType89TickState =
{
    return SH_StandardTickState(now, mag_cftype89, ammo_cftype89, MAX_MAG_CFTYPE89,
        SH_SeqDuration(CFTYPE89_VIEWMODEL, CFTYPE89_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFTYPE89_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFTYPE89_VIEWMODEL, CFTYPE89_SEQ_RELOAD, 2.5),
        CFTYPE89_RELOAD_APPLY_TIME);
};

float(float now) SH_CFType89TryFire =
{
    return SH_StandardTryFire(now, mag_cftype89, CFTYPE89_FIRE_DELAY, CFTYPE89_DRYFIRE_DELAY);
};

float(float now) SH_CFType89TryReload =
{
    return SH_StandardTryReload(now, mag_cftype89, ammo_cftype89, MAX_MAG_CFTYPE89,
        SH_SeqDuration(CFTYPE89_VIEWMODEL, CFTYPE89_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFType89PickupCopy =
{
    player.mag_cftype89  = self.mag_cftype89;
    player.ammo_cftype89 = self.ammo_cftype89;
};

void() W_CFType89Shoot =
{
    W_PenetratingHitscanShoot(CFTYPE89_BASE_SPREAD, CFTYPE89_MOVE_SPREAD, CFTYPE89_FULL_SPREAD_SPEED,
        CFTYPE89_CLOSE_DAMAGE, CFTYPE89_MIN_DAMAGE, CFTYPE89_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CFTYPE89_KICK_PITCH, CFTYPE89_KICK_VARIANCE, CFTYPE89_KICK_STRENGTH);
};

void() W_CFType89Fire =
{
    float r = SH_CFType89TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFType89PickShootSeq();
        self.wep_nextframe = time + CFTYPE89_FRAME_INTERVAL;
        self.cftype89_snd_stage = 0;

        W_CFType89Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cftype89/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFType89Reload =
{
    if (SH_CFType89TryReload(time))
    {
        self.weaponframe   = CFTYPE89_SEQ_RELOAD;
        self.wep_nextframe = time + CFTYPE89_FRAME_INTERVAL;
        self.cftype89_snd_stage = 0;
    }
};

void() W_CFType89Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFTYPE89_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFTYPE89_SELECT_DEPLOY_TIME && self.cftype89_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cftype89/draw.WAV", 1, ATTN_NORM);
            self.cftype89_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFTYPE89_RELOAD_CLIPOUT_TIME && self.cftype89_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cftype89/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cftype89_snd_stage = 1;
        }
        if (elapsed >= CFTYPE89_RELOAD_CLIPIN_TIME && self.cftype89_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cftype89/clipin.WAV", 1, ATTN_NORM);
            self.cftype89_snd_stage = 2;
        }
        if (elapsed >= CFTYPE89_RELOAD_TAIL_TIME && self.cftype89_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cftype89/reload.WAV", 1, ATTN_NORM);
            self.cftype89_snd_stage = 3;
        }
    }

    result = SH_CFType89TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFTYPE89_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cftype89_snd_stage = 0;
    }
};

void() W_CFType89Equip =
{
    W_StandardEquipSetup(CFTYPE89_VIEWMODEL, CFTYPE89_DISPLAY_NAME, CFTYPE89_SEQ_SELECT,
        CFTYPE89_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFType89Fire;
    self.reload   = W_CFType89Reload;
    self.wepframe = W_CFType89Frame;
    self.shoot    = W_CFType89Shoot;
    self.cftype89_snd_stage = 0;
    W_SetCrosshairProfile(CFTYPE89_BASE_SPREAD, CFTYPE89_MOVE_SPREAD, CFTYPE89_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFType89Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cftype89  = self.mag_cftype89;
    tgt.ammo_cftype89 = self.ammo_cftype89;

    self.mag_cftype89  = 0;
    self.ammo_cftype89 = 0;

    setmodel(tgt, CFTYPE89_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cftype89";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFTYPE89;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFType89Equip;
    tgt.weap_drop_func = W_CFType89Drop;
    tgt.pickupcopy    = W_CFType89PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cftype89 =
{
    setmodel(self, CFTYPE89_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cftype89";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFTYPE89;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFType89Equip;
    self.weap_drop_func = W_CFType89Drop;
    self.pickupcopy   = W_CFType89PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cftype89  = MAX_MAG_CFTYPE89;
    self.ammo_cftype89 = MAX_AMMO_CFTYPE89;
    W_RegisterMapWeapon(weapon_cftype89);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cftype89_snd_stage;
float csqc_cftype89_snd_action;

void() CSQC_PredictCFType89Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cftype89_snd_action)
    {
        csqc_cftype89_snd_action = predicted_player.wep_action_id;
        csqc_cftype89_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFType89TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cftype89/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFTYPE89_BASE_SPREAD, CFTYPE89_MOVE_SPREAD, CFTYPE89_FULL_SPREAD_SPEED,
                    CFTYPE89_CLOSE_DAMAGE, CFTYPE89_MIN_DAMAGE, CFTYPE89_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CFTYPE89_KICK_PITCH, CFTYPE89_KICK_VARIANCE, CFTYPE89_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFTYPE89_MUZZLE_BONE, CFTYPE89_MUZZLE_OFFSET);
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
            if (csqc_cftype89_snd_stage < 1 && elapsed >= CFTYPE89_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cftype89/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cftype89_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cftype89_snd_stage < 1 && elapsed >= CFTYPE89_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cftype89/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cftype89_snd_stage = 1;
            }
            if (csqc_cftype89_snd_stage < 2 && elapsed >= CFTYPE89_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cftype89/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cftype89_snd_stage = 2;
            }
            if (csqc_cftype89_snd_stage < 3 && elapsed >= CFTYPE89_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cftype89/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cftype89_snd_stage = 3;
            }
        }
    }

    SH_CFType89TickState(csqc_pred_time);
};

void() CSQC_PredictCFType89Reload =
{
    if (SH_CFType89TryReload(csqc_pred_time))
    {
        csqc_cftype89_snd_stage  = 0;
        csqc_cftype89_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFType89DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFTYPE89_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFTYPE89_SEQ_SHOOT1;
        if (r < 0.67) return CFTYPE89_SEQ_SHOOT2;
        return CFTYPE89_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFTYPE89_SEQ_RELOAD;

    return CFTYPE89_SEQ_IDLE;
};

void() CSQC_CFType89DropClear =
{
    self.mag_cftype89 = 0;
    self.ammo_cftype89 = 0;
};

void() CSQC_CFType89Equip =
{
    self.weapon_name         = CFTYPE89_DISPLAY_NAME;
    self.weapon_viewmodel    = CFTYPE89_VIEWMODEL;
    self.weapon_worldmodel   = CFTYPE89_WORLDMODEL;
    self.weapon_deploy_sound = CFTYPE89_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFType89Command;
    self.csqc_predict_reload = CSQC_PredictCFType89Reload;
    self.csqc_display_frame  = CSQC_CFType89DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFType89DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFTYPE89_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFTYPE89_MUZZLE_OFFSET;
};

#endif // CSQC
