// ============================================================
//  shared/weapons/sh_wpn_cfvector.qc  -  CF Vector (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 25-round magazine, 125 reserve, full-auto .45 SMG.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage
//          falloff.  Very high cyclic rate, low per-shot recoil.
//
//  GoldSrc-format viewmodel — sequence-driven; durations from the
//  model via SH_SeqDuration.  Same pattern as cfmac10.
//
//  Sequence layout (v_vector.mdl):
//     0  idle_0    30 fps
//     1  reload    19 fps  (clipout @ 14, clipin @ 34, reload-tail @ 46)
//     2  select    30 fps  (deploy @ 2)
//     3  prefire1  25 fps
//     4  prefire2  25 fps
//     5  prefire3  25 fps
//
//  Sounds in sounds/weapons/wpn_cfvector/.
// ============================================================

.float mag_cfvector;
.float ammo_cfvector;

const float CFVECTOR_SEQ_IDLE   = 0;
const float CFVECTOR_SEQ_RELOAD = 1;
const float CFVECTOR_SEQ_SELECT = 2;
const float CFVECTOR_SEQ_SHOOT1 = 3;
const float CFVECTOR_SEQ_SHOOT2 = 4;
const float CFVECTOR_SEQ_SHOOT3 = 5;

const float CFVECTOR_RELOAD_APPLY_TIME = 1.85;   // ~clipin + small gap

const float CFVECTOR_FIRE_DELAY        = 0.05;   // ~1200 rpm cyclic
const float CFVECTOR_DRYFIRE_DELAY     = 0.20;
const float CFVECTOR_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (reload 19 fps, select 30 fps) ---
//   reload  clipout    @ frame 14 / 19 = 0.737s
//   reload  clipin     @ frame 34 / 19 = 1.789s
//   reload  reload-tail @ frame 46 / 19 = 2.421s
//   select  deploy     @ frame 2  / 30 = 0.067s
const float CFVECTOR_RELOAD_CLIPOUT_TIME = 0.737;
const float CFVECTOR_RELOAD_CLIPIN_TIME  = 1.789;
const float CFVECTOR_RELOAD_TAIL_TIME    = 2.421;
const float CFVECTOR_SELECT_DEPLOY_TIME  = 0.067;

const float MAX_MAG_CFVECTOR             = 25;
const float MAX_AMMO_CFVECTOR            = 125;

const float CFVECTOR_BASE_SPREAD          = 0.01;
const float CFVECTOR_MOVE_SPREAD          = 0.06;
const float CFVECTOR_FULL_SPREAD_SPEED    = 320;
const float CFVECTOR_CLOSE_DAMAGE         = 22;     // .45 ACP SMG
const float CFVECTOR_MIN_DAMAGE           = 11;
const float CFVECTOR_DAMAGE_FALLOFF_RANGE = 1800;

const float CFVECTOR_KICK_PITCH    = 0.7;
const float CFVECTOR_KICK_VARIANCE = 0.4;
const float CFVECTOR_KICK_STRENGTH = 0.9;   // very controllable

// Muzzle attachment — from v_vector.mdl's $attachment 0:
//     $attachment 0 "Bone01" 17.6 0.0 -0.8
const string CFVECTOR_MUZZLE_BONE   = "Bone01";
#define CFVECTOR_MUZZLE_OFFSET ('17.6 0.0 -0.8')

const string CFVECTOR_VIEWMODEL    = "models/weapons/wpn_cfvector/v_vector.mdl";
const string CFVECTOR_WORLDMODEL   = "models/weapons/wpn_cfvector/w_vector.mdl";
const string CFVECTOR_DEPLOY_SOUND = "";
const string CFVECTOR_DISPLAY_NAME = "Vector";

.float cfvector_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFVectorPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFVECTOR_SEQ_SHOOT1;
    if (r < 0.67) return CFVECTOR_SEQ_SHOOT2;
    return CFVECTOR_SEQ_SHOOT3;
};

float(float now) SH_CFVectorTickState =
{
    return SH_StandardTickState(now, mag_cfvector, ammo_cfvector, MAX_MAG_CFVECTOR,
        SH_SeqDuration(CFVECTOR_VIEWMODEL, CFVECTOR_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFVECTOR_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFVECTOR_VIEWMODEL, CFVECTOR_SEQ_RELOAD, 2.5),
        CFVECTOR_RELOAD_APPLY_TIME);
};

float(float now) SH_CFVectorTryFire =
{
    return SH_StandardTryFire(now, mag_cfvector, CFVECTOR_FIRE_DELAY, CFVECTOR_DRYFIRE_DELAY);
};

float(float now) SH_CFVectorTryReload =
{
    return SH_StandardTryReload(now, mag_cfvector, ammo_cfvector, MAX_MAG_CFVECTOR,
        SH_SeqDuration(CFVECTOR_VIEWMODEL, CFVECTOR_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFVectorPickupCopy =
{
    player.mag_cfvector  = self.mag_cfvector;
    player.ammo_cfvector = self.ammo_cfvector;
};

void() W_CFVectorShoot =
{
    W_PenetratingHitscanShoot(CFVECTOR_BASE_SPREAD, CFVECTOR_MOVE_SPREAD, CFVECTOR_FULL_SPREAD_SPEED,
        CFVECTOR_CLOSE_DAMAGE, CFVECTOR_MIN_DAMAGE, CFVECTOR_DAMAGE_FALLOFF_RANGE, 32, 0.95,
        CFVECTOR_KICK_PITCH, CFVECTOR_KICK_VARIANCE, CFVECTOR_KICK_STRENGTH);
};

void() W_CFVectorFire =
{
    float r = SH_CFVectorTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFVectorPickShootSeq();
        self.wep_nextframe = time + CFVECTOR_FRAME_INTERVAL;
        self.cfvector_snd_stage = 0;

        W_CFVectorShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfvector/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFVectorReload =
{
    if (SH_CFVectorTryReload(time))
    {
        self.weaponframe   = CFVECTOR_SEQ_RELOAD;
        self.wep_nextframe = time + CFVECTOR_FRAME_INTERVAL;
        self.cfvector_snd_stage = 0;
    }
};

void() W_CFVectorFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFVECTOR_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFVECTOR_SELECT_DEPLOY_TIME && self.cfvector_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfvector/draw.WAV", 1, ATTN_NORM);
            self.cfvector_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFVECTOR_RELOAD_CLIPOUT_TIME && self.cfvector_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfvector/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.cfvector_snd_stage = 1;
        }
        if (elapsed >= CFVECTOR_RELOAD_CLIPIN_TIME && self.cfvector_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfvector/clipin.WAV", 1, ATTN_NORM);
            self.cfvector_snd_stage = 2;
        }
        if (elapsed >= CFVECTOR_RELOAD_TAIL_TIME && self.cfvector_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfvector/reload.WAV", 1, ATTN_NORM);
            self.cfvector_snd_stage = 3;
        }
    }

    result = SH_CFVectorTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFVECTOR_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfvector_snd_stage = 0;
    }
};

void() W_CFVectorEquip =
{
    W_StandardEquipSetup(CFVECTOR_VIEWMODEL, CFVECTOR_DISPLAY_NAME, CFVECTOR_SEQ_SELECT,
        CFVECTOR_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFVectorFire;
    self.reload   = W_CFVectorReload;
    self.wepframe = W_CFVectorFrame;
    self.shoot    = W_CFVectorShoot;
    self.cfvector_snd_stage = 0;
    W_SetCrosshairProfile(CFVECTOR_BASE_SPREAD, CFVECTOR_MOVE_SPREAD, CFVECTOR_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_CFVectorDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfvector  = self.mag_cfvector;
    tgt.ammo_cfvector = self.ammo_cfvector;

    self.mag_cfvector  = 0;
    self.ammo_cfvector = 0;

    setmodel(tgt, CFVECTOR_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfvector";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFVECTOR;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFVectorEquip;
    tgt.weap_drop_func = W_CFVectorDrop;
    tgt.pickupcopy    = W_CFVectorPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfvector =
{
    setmodel(self, CFVECTOR_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfvector";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFVECTOR;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFVectorEquip;
    self.weap_drop_func = W_CFVectorDrop;
    self.pickupcopy   = W_CFVectorPickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfvector  = MAX_MAG_CFVECTOR;
    self.ammo_cfvector = MAX_AMMO_CFVECTOR;
    W_RegisterMapWeapon(weapon_cfvector);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfvector_snd_stage;
float csqc_cfvector_snd_action;

void() CSQC_PredictCFVectorCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfvector_snd_action)
    {
        csqc_cfvector_snd_action = predicted_player.wep_action_id;
        csqc_cfvector_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFVectorTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfvector/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFVECTOR_BASE_SPREAD, CFVECTOR_MOVE_SPREAD, CFVECTOR_FULL_SPREAD_SPEED,
                    CFVECTOR_CLOSE_DAMAGE, CFVECTOR_MIN_DAMAGE, CFVECTOR_DAMAGE_FALLOFF_RANGE, 32, 0.95,
                    CFVECTOR_KICK_PITCH, CFVECTOR_KICK_VARIANCE, CFVECTOR_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFVECTOR_MUZZLE_BONE, CFVECTOR_MUZZLE_OFFSET);
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
            if (csqc_cfvector_snd_stage < 1 && elapsed >= CFVECTOR_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfvector/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfvector_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfvector_snd_stage < 1 && elapsed >= CFVECTOR_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfvector/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfvector_snd_stage = 1;
            }
            if (csqc_cfvector_snd_stage < 2 && elapsed >= CFVECTOR_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfvector/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfvector_snd_stage = 2;
            }
            if (csqc_cfvector_snd_stage < 3 && elapsed >= CFVECTOR_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfvector/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfvector_snd_stage = 3;
            }
        }
    }

    SH_CFVectorTickState(csqc_pred_time);
};

void() CSQC_PredictCFVectorReload =
{
    if (SH_CFVectorTryReload(csqc_pred_time))
    {
        csqc_cfvector_snd_stage  = 0;
        csqc_cfvector_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFVectorDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFVECTOR_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFVECTOR_SEQ_SHOOT1;
        if (r < 0.67) return CFVECTOR_SEQ_SHOOT2;
        return CFVECTOR_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFVECTOR_SEQ_RELOAD;

    return CFVECTOR_SEQ_IDLE;
};

void() CSQC_CFVectorDropClear =
{
    self.mag_cfvector = 0;
    self.ammo_cfvector = 0;
};

void() CSQC_CFVectorEquip =
{
    self.weapon_name         = CFVECTOR_DISPLAY_NAME;
    self.weapon_viewmodel    = CFVECTOR_VIEWMODEL;
    self.weapon_worldmodel   = CFVECTOR_WORLDMODEL;
    self.weapon_deploy_sound = CFVECTOR_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFVectorCommand;
    self.csqc_predict_reload = CSQC_PredictCFVectorReload;
    self.csqc_display_frame  = CSQC_CFVectorDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFVectorDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFVECTOR_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFVECTOR_MUZZLE_OFFSET;
};

#endif // CSQC
