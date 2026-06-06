// ============================================================
//  shared/weapons/sh_wpn_cfump45.qc  -  CF UMP45 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 25-round magazine, 100 reserve, full-auto .45 SMG.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage falloff.
//
//  Sequence layout (v_ump45.mdl):
//     0  idle_0    30 fps
//     1  reload    19 fps  (clipout @ 9, clipin @ 27, reload-tail @ 48)
//     2  select    30 fps  (deploy @ 8)
//     3  prefire1  25 fps
//     4  prefire2  25 fps
//     5  prefire3  25 fps
//
//  Sounds in sounds/weapons/wpn_cfump45/.
// ============================================================

.float mag_cfump45;
.float ammo_cfump45;

const float CFUMP45_SEQ_IDLE   = 0;
const float CFUMP45_SEQ_RELOAD = 1;
const float CFUMP45_SEQ_SELECT = 2;
const float CFUMP45_SEQ_SHOOT1 = 3;
const float CFUMP45_SEQ_SHOOT2 = 4;
const float CFUMP45_SEQ_SHOOT3 = 5;

const float CFUMP45_RELOAD_APPLY_TIME = 1.50;

const float CFUMP45_FIRE_DELAY        = 0.10;   // ~600 rpm cyclic
const float CFUMP45_DRYFIRE_DELAY     = 0.20;
const float CFUMP45_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (reload 19 fps, select 30 fps) ---
const float CFUMP45_RELOAD_CLIPOUT_TIME = 0.474;   // frame 9  / 19
const float CFUMP45_RELOAD_CLIPIN_TIME  = 1.421;   // frame 27 / 19
const float CFUMP45_RELOAD_TAIL_TIME    = 2.526;   // frame 48 / 19
const float CFUMP45_SELECT_DEPLOY_TIME  = 0.267;   // frame 8  / 30

const float MAX_MAG_CFUMP45             = 25;
const float MAX_AMMO_CFUMP45            = 100;

const float CFUMP45_BASE_SPREAD          = 0.01;
const float CFUMP45_MOVE_SPREAD          = 0.07;
const float CFUMP45_FULL_SPREAD_SPEED    = 320;
const float CFUMP45_CLOSE_DAMAGE         = 24;     // .45 ACP SMG
const float CFUMP45_MIN_DAMAGE           = 12;
const float CFUMP45_DAMAGE_FALLOFF_RANGE = 1900;

const float CFUMP45_KICK_PITCH    = 0.8;
const float CFUMP45_KICK_VARIANCE = 0.4;
const float CFUMP45_KICK_STRENGTH = 1.0;

// Muzzle attachment — from v_ump45.mdl's $attachment 0:
//     $attachment 0 "Box001" 0.0 0.0 10.0
const string CFUMP45_MUZZLE_BONE   = "Box001";
#define CFUMP45_MUZZLE_OFFSET ('0.0 0.0 10.0')

const string CFUMP45_VIEWMODEL    = "models/weapons/wpn_cfump45/v_ump45.mdl";
const string CFUMP45_WORLDMODEL   = "models/weapons/wpn_cfump45/w_ump45.mdl";
const string CFUMP45_DEPLOY_SOUND = "";
const string CFUMP45_DISPLAY_NAME = "UMP45";

.float cfump45_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFUmp45PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFUMP45_SEQ_SHOOT1;
    if (r < 0.67) return CFUMP45_SEQ_SHOOT2;
    return CFUMP45_SEQ_SHOOT3;
};

float(float now) SH_CFUmp45TickState =
{
    return SH_StandardTickState(now, mag_cfump45, ammo_cfump45, MAX_MAG_CFUMP45,
        SH_SeqDuration(CFUMP45_VIEWMODEL, CFUMP45_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFUMP45_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFUMP45_VIEWMODEL, CFUMP45_SEQ_RELOAD, 2.6),
        CFUMP45_RELOAD_APPLY_TIME);
};

float(float now) SH_CFUmp45TryFire =
{
    return SH_StandardTryFire(now, mag_cfump45, CFUMP45_FIRE_DELAY, CFUMP45_DRYFIRE_DELAY);
};

float(float now) SH_CFUmp45TryReload =
{
    return SH_StandardTryReload(now, mag_cfump45, ammo_cfump45, MAX_MAG_CFUMP45,
        SH_SeqDuration(CFUMP45_VIEWMODEL, CFUMP45_SEQ_RELOAD, 2.6));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFUmp45PickupCopy =
{
    player.mag_cfump45  = self.mag_cfump45;
    player.ammo_cfump45 = self.ammo_cfump45;
};

void() W_CFUmp45Shoot =
{
    W_PenetratingHitscanShoot(CFUMP45_BASE_SPREAD, CFUMP45_MOVE_SPREAD, CFUMP45_FULL_SPREAD_SPEED,
        CFUMP45_CLOSE_DAMAGE, CFUMP45_MIN_DAMAGE, CFUMP45_DAMAGE_FALLOFF_RANGE, 32, 0.95,
        CFUMP45_KICK_PITCH, CFUMP45_KICK_VARIANCE, CFUMP45_KICK_STRENGTH);
};

void() W_CFUmp45Fire =
{
    float r = SH_CFUmp45TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFUmp45PickShootSeq();
        self.wep_nextframe = time + CFUMP45_FRAME_INTERVAL;
        self.cfump45_snd_stage = 0;

        W_CFUmp45Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfump45/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFUmp45Reload =
{
    if (SH_CFUmp45TryReload(time))
    {
        self.weaponframe   = CFUMP45_SEQ_RELOAD;
        self.wep_nextframe = time + CFUMP45_FRAME_INTERVAL;
        self.cfump45_snd_stage = 0;
    }
};

void() W_CFUmp45Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFUMP45_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFUMP45_SELECT_DEPLOY_TIME && self.cfump45_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfump45/draw.WAV", 1, ATTN_NORM);
            self.cfump45_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFUMP45_RELOAD_CLIPOUT_TIME && self.cfump45_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfump45/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.cfump45_snd_stage = 1;
        }
        if (elapsed >= CFUMP45_RELOAD_CLIPIN_TIME && self.cfump45_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfump45/clipin.WAV", 1, ATTN_NORM);
            self.cfump45_snd_stage = 2;
        }
        if (elapsed >= CFUMP45_RELOAD_TAIL_TIME && self.cfump45_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfump45/reload.WAV", 1, ATTN_NORM);
            self.cfump45_snd_stage = 3;
        }
    }

    result = SH_CFUmp45TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFUMP45_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfump45_snd_stage = 0;
    }
};

void() W_CFUmp45Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ump45", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFUMP45_VIEWMODEL, CFUMP45_DISPLAY_NAME, CFUMP45_SEQ_SELECT,
        CFUMP45_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFUmp45Fire;
    self.reload   = W_CFUmp45Reload;
    self.wepframe = W_CFUmp45Frame;
    self.shoot    = W_CFUmp45Shoot;
    self.cfump45_snd_stage = 0;
    W_SetCrosshairProfile(CFUMP45_BASE_SPREAD, CFUMP45_MOVE_SPREAD, CFUMP45_FULL_SPREAD_SPEED, 1.7, TRUE);
};

void() W_CFUmp45Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfump45  = self.mag_cfump45;
    tgt.ammo_cfump45 = self.ammo_cfump45;

    self.mag_cfump45  = 0;
    self.ammo_cfump45 = 0;

    setmodel(tgt, CFUMP45_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfump45";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFUMP45;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFUmp45Equip;
    tgt.weap_drop_func = W_CFUmp45Drop;
    tgt.pickupcopy    = W_CFUmp45PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfump45 =
{
    setmodel(self, CFUMP45_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfump45";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFUMP45;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFUmp45Equip;
    self.weap_drop_func = W_CFUmp45Drop;
    self.pickupcopy   = W_CFUmp45PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfump45  = MAX_MAG_CFUMP45;
    self.ammo_cfump45 = MAX_AMMO_CFUMP45;
    W_RegisterMapWeapon(weapon_cfump45);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfump45_snd_stage;
float csqc_cfump45_snd_action;

void() CSQC_PredictCFUmp45Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfump45_snd_action)
    {
        csqc_cfump45_snd_action = predicted_player.wep_action_id;
        csqc_cfump45_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFUmp45TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfump45/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFUMP45_BASE_SPREAD, CFUMP45_MOVE_SPREAD, CFUMP45_FULL_SPREAD_SPEED,
                    CFUMP45_CLOSE_DAMAGE, CFUMP45_MIN_DAMAGE, CFUMP45_DAMAGE_FALLOFF_RANGE, 32, 0.95,
                    CFUMP45_KICK_PITCH, CFUMP45_KICK_VARIANCE, CFUMP45_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFUMP45_MUZZLE_BONE, CFUMP45_MUZZLE_OFFSET);
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
            if (csqc_cfump45_snd_stage < 1 && elapsed >= CFUMP45_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfump45/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfump45_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfump45_snd_stage < 1 && elapsed >= CFUMP45_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfump45/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfump45_snd_stage = 1;
            }
            if (csqc_cfump45_snd_stage < 2 && elapsed >= CFUMP45_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfump45/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfump45_snd_stage = 2;
            }
            if (csqc_cfump45_snd_stage < 3 && elapsed >= CFUMP45_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfump45/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfump45_snd_stage = 3;
            }
        }
    }

    SH_CFUmp45TickState(csqc_pred_time);
};

void() CSQC_PredictCFUmp45Reload =
{
    if (SH_CFUmp45TryReload(csqc_pred_time))
    {
        csqc_cfump45_snd_stage  = 0;
        csqc_cfump45_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFUmp45DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFUMP45_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFUMP45_SEQ_SHOOT1;
        if (r < 0.67) return CFUMP45_SEQ_SHOOT2;
        return CFUMP45_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFUMP45_SEQ_RELOAD;

    return CFUMP45_SEQ_IDLE;
};

void() CSQC_CFUmp45DropClear =
{
    self.mag_cfump45 = 0;
    self.ammo_cfump45 = 0;
};

void() CSQC_CFUmp45Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ump45", SCOPE_CLASS_NONE);
    self.weapon_name         = CFUMP45_DISPLAY_NAME;
    self.weapon_viewmodel    = CFUMP45_VIEWMODEL;
    self.weapon_worldmodel   = CFUMP45_WORLDMODEL;
    self.weapon_deploy_sound = CFUMP45_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFUmp45Command;
    self.csqc_predict_reload = CSQC_PredictCFUmp45Reload;
    self.csqc_display_frame  = CSQC_CFUmp45DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFUmp45DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFUMP45_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFUMP45_MUZZLE_OFFSET;
};

#endif // CSQC
