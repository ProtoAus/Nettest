// ============================================================
//  shared/weapons/sh_wpn_cffamas.qc  -  FAMAS (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 25-round magazine, 90 reserve, full-auto.
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff.
//
//  GoldSrc-format viewmodel — sequence-driven; durations from the
//  model via SH_SeqDuration.  Same shape as HDAK47/cfaug.
//
//  Sequence layout (v_famas.mdl):
//     0  idle_0    30 fps
//     1  reload    23 fps  (clipout @ 8, clipin @ 28, blowback @ 39, deploy-tail @ 55)
//     2  select    35 fps  (deploy @ 11)
//     3  prefire1  30 fps
//     4  prefire2  30 fps
//     5  prefire3  30 fps
//
//  Sounds in sounds/weapons/wpn_cffamas/.
// ============================================================

.float mag_cffamas;
.float ammo_cffamas;

const float CFFAMAS_SEQ_IDLE   = 0;
const float CFFAMAS_SEQ_RELOAD = 1;
const float CFFAMAS_SEQ_SELECT = 2;
const float CFFAMAS_SEQ_SHOOT1 = 3;
const float CFFAMAS_SEQ_SHOOT2 = 4;
const float CFFAMAS_SEQ_SHOOT3 = 5;

const float CFFAMAS_RELOAD_APPLY_TIME = 1.30;   // ~clipin + small gap

const float CFFAMAS_FIRE_DELAY        = 0.085;  // ~12 rps cyclic
const float CFFAMAS_DRYFIRE_DELAY     = 0.20;
const float CFFAMAS_FRAME_INTERVAL    = 0.05;

// --- Sound event timings ---
//   reload  clipout    @ frame 8  / 23 = 0.348s
//   reload  clipin     @ frame 28 / 23 = 1.217s
//   reload  blowback   @ frame 39 / 23 = 1.696s   (file: blockback.wav — typo in source)
//   reload  deploy-end @ frame 55 / 23 = 2.391s
//   select  deploy     @ frame 11 / 35 = 0.314s
const float CFFAMAS_RELOAD_CLIPOUT_TIME  = 0.348;
const float CFFAMAS_RELOAD_CLIPIN_TIME   = 1.217;
const float CFFAMAS_RELOAD_BLOWBACK_TIME = 1.696;
const float CFFAMAS_RELOAD_TAIL_TIME     = 2.391;
const float CFFAMAS_SELECT_DEPLOY_TIME   = 0.314;

const float MAX_MAG_CFFAMAS             = 25;
const float MAX_AMMO_CFFAMAS            = 90;

const float CFFAMAS_BASE_SPREAD          = 0.01;
const float CFFAMAS_MOVE_SPREAD          = 0.07;
const float CFFAMAS_FULL_SPREAD_SPEED    = 320;
const float CFFAMAS_CLOSE_DAMAGE         = 30;
const float CFFAMAS_MIN_DAMAGE           = 20;
const float CFFAMAS_DAMAGE_FALLOFF_RANGE = 2304;

const float CFFAMAS_KICK_PITCH    = 1.5;
const float CFFAMAS_KICK_VARIANCE = 1.4;
const float CFFAMAS_KICK_STRENGTH = 0.95;

// Muzzle attachment — sourced from v_famas.mdl's $attachment 0:
//     $attachment 0 "Bone01" 40.0 0.0 0.0
// Bone-attached so the flash + tracer track the firing animation
// instead of sitting at a static camera-relative offset.  Mirrors
// HDAK47's pattern (sh_wpn_hdak47.qc).
const string CFFAMAS_MUZZLE_BONE   = "Bone01";
#define CFFAMAS_MUZZLE_OFFSET ('40.0 0.0 0.0')

const string CFFAMAS_VIEWMODEL    = "models/weapons/wpn_cffamas/v_famas.mdl";
const string CFFAMAS_WORLDMODEL   = "models/weapons/wpn_cffamas/w_famas.mdl";
const string CFFAMAS_DEPLOY_SOUND = "";
const string CFFAMAS_DISPLAY_NAME = "FAMAS";

.float cffamas_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFFamasPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFFAMAS_SEQ_SHOOT1;
    if (r < 0.67) return CFFAMAS_SEQ_SHOOT2;
    return CFFAMAS_SEQ_SHOOT3;
};

float(float now) SH_CFFamasTickState =
{
    return SH_StandardTickState(now, mag_cffamas, ammo_cffamas, MAX_MAG_CFFAMAS,
        SH_SeqDuration(CFFAMAS_VIEWMODEL, CFFAMAS_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFFAMAS_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFFAMAS_VIEWMODEL, CFFAMAS_SEQ_RELOAD, 2.5),
        CFFAMAS_RELOAD_APPLY_TIME);
};

float(float now) SH_CFFamasTryFire =
{
    return SH_StandardTryFire(now, mag_cffamas, CFFAMAS_FIRE_DELAY, CFFAMAS_DRYFIRE_DELAY);
};

float(float now) SH_CFFamasTryReload =
{
    return SH_StandardTryReload(now, mag_cffamas, ammo_cffamas, MAX_MAG_CFFAMAS,
        SH_SeqDuration(CFFAMAS_VIEWMODEL, CFFAMAS_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFFamasPickupCopy =
{
    player.mag_cffamas  = self.mag_cffamas;
    player.ammo_cffamas = self.ammo_cffamas;
};

void() W_CFFamasShoot =
{
    W_PenetratingHitscanShoot(CFFAMAS_BASE_SPREAD, CFFAMAS_MOVE_SPREAD, CFFAMAS_FULL_SPREAD_SPEED,
        CFFAMAS_CLOSE_DAMAGE, CFFAMAS_MIN_DAMAGE, CFFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CFFAMAS_KICK_PITCH, CFFAMAS_KICK_VARIANCE, CFFAMAS_KICK_STRENGTH);
};

void() W_CFFamasFire =
{
    float r = SH_CFFamasTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFFamasPickShootSeq();
        self.wep_nextframe = time + CFFAMAS_FRAME_INTERVAL;
        self.cffamas_snd_stage = 0;

        W_CFFamasShoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cffamas/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cffamas/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFFamasReload =
{
    if (SH_CFFamasTryReload(time))
    {
        self.weaponframe   = CFFAMAS_SEQ_RELOAD;
        self.wep_nextframe = time + CFFAMAS_FRAME_INTERVAL;
        self.cffamas_snd_stage = 0;
    }
};

void() W_CFFamasFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFFAMAS_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFFAMAS_SELECT_DEPLOY_TIME && self.cffamas_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cffamas/reload.wav", 1, ATTN_NORM);
            self.cffamas_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFFAMAS_RELOAD_CLIPOUT_TIME && self.cffamas_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cffamas/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cffamas_snd_stage = 1;
        }
        if (elapsed >= CFFAMAS_RELOAD_CLIPIN_TIME && self.cffamas_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cffamas/clipin.wav", 1, ATTN_NORM);
            self.cffamas_snd_stage = 2;
        }
        if (elapsed >= CFFAMAS_RELOAD_BLOWBACK_TIME && self.cffamas_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cffamas/blockback.wav", 1, ATTN_NORM);
            self.cffamas_snd_stage = 3;
        }
        if (elapsed >= CFFAMAS_RELOAD_TAIL_TIME && self.cffamas_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cffamas/reload.wav", 1, ATTN_NORM);
            self.cffamas_snd_stage = 4;
        }
    }

    result = SH_CFFamasTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFFAMAS_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cffamas_snd_stage = 0;
    }
};

void() W_CFFamasEquip =
{
    W_StandardEquipSetup(CFFAMAS_VIEWMODEL, CFFAMAS_DISPLAY_NAME, CFFAMAS_SEQ_SELECT,
        CFFAMAS_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFFamasFire;
    self.reload   = W_CFFamasReload;
    self.wepframe = W_CFFamasFrame;
    self.shoot    = W_CFFamasShoot;
    self.cffamas_snd_stage = 0;
    W_SetCrosshairProfile(CFFAMAS_BASE_SPREAD, CFFAMAS_MOVE_SPREAD, CFFAMAS_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFFamasDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cffamas  = self.mag_cffamas;
    tgt.ammo_cffamas = self.ammo_cffamas;

    self.mag_cffamas  = 0;
    self.ammo_cffamas = 0;

    setmodel(tgt, CFFAMAS_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cffamas";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFFAMAS;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFFamasEquip;
    tgt.weap_drop_func = W_CFFamasDrop;
    tgt.pickupcopy    = W_CFFamasPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cffamas =
{
    setmodel(self, CFFAMAS_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cffamas";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFFAMAS;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFFamasEquip;
    self.weap_drop_func = W_CFFamasDrop;
    self.pickupcopy   = W_CFFamasPickupCopy;
    self.touch        = weapon_touch;
    self.mag_cffamas  = MAX_MAG_CFFAMAS;
    self.ammo_cffamas = MAX_AMMO_CFFAMAS;
    W_RegisterMapWeapon(weapon_cffamas);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cffamas_snd_stage;
float csqc_cffamas_snd_action;

void() CSQC_PredictCFFamasCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cffamas_snd_action)
    {
        csqc_cffamas_snd_action = predicted_player.wep_action_id;
        csqc_cffamas_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFFamasTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cffamas/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cffamas/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFFAMAS_BASE_SPREAD, CFFAMAS_MOVE_SPREAD, CFFAMAS_FULL_SPREAD_SPEED,
                    CFFAMAS_CLOSE_DAMAGE, CFFAMAS_MIN_DAMAGE, CFFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CFFAMAS_KICK_PITCH, CFFAMAS_KICK_VARIANCE, CFFAMAS_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle flash + smoke — sampled from
                // the viewmodel's $attachment 0 (Bone01) so the flash
                // tracks the firing animation.  Tracer start point
                // follows automatically via CSQC_MuzzleFlashWorldPos.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFFAMAS_MUZZLE_BONE, CFFAMAS_MUZZLE_OFFSET);
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
            if (csqc_cffamas_snd_stage < 1 && elapsed >= CFFAMAS_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cffamas/reload.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cffamas_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cffamas_snd_stage < 1 && elapsed >= CFFAMAS_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cffamas/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cffamas_snd_stage = 1;
            }
            if (csqc_cffamas_snd_stage < 2 && elapsed >= CFFAMAS_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cffamas/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cffamas_snd_stage = 2;
            }
            if (csqc_cffamas_snd_stage < 3 && elapsed >= CFFAMAS_RELOAD_BLOWBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cffamas/blockback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cffamas_snd_stage = 3;
            }
            if (csqc_cffamas_snd_stage < 4 && elapsed >= CFFAMAS_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cffamas/reload.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cffamas_snd_stage = 4;
            }
        }
    }

    SH_CFFamasTickState(csqc_pred_time);
};

void() CSQC_PredictCFFamasReload =
{
    if (SH_CFFamasTryReload(csqc_pred_time))
    {
        csqc_cffamas_snd_stage  = 0;
        csqc_cffamas_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFFamasDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFFAMAS_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFFAMAS_SEQ_SHOOT1;
        if (r < 0.67) return CFFAMAS_SEQ_SHOOT2;
        return CFFAMAS_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFFAMAS_SEQ_RELOAD;

    return CFFAMAS_SEQ_IDLE;
};

void() CSQC_CFFamasDropClear =
{
    self.mag_cffamas = 0;
    self.ammo_cffamas = 0;
};

void() CSQC_CFFamasEquip =
{
    self.weapon_name         = CFFAMAS_DISPLAY_NAME;
    self.weapon_viewmodel    = CFFAMAS_VIEWMODEL;
    self.weapon_worldmodel   = CFFAMAS_WORLDMODEL;
    self.weapon_deploy_sound = CFFAMAS_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFFamasCommand;
    self.csqc_predict_reload = CSQC_PredictCFFamasReload;
    self.csqc_display_frame  = CSQC_CFFamasDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFFamasDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot + muzzle anchor — same constants the fire path uses.
    self.weapon_muzzle_bone   = CFFAMAS_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFFAMAS_MUZZLE_OFFSET;
};

#endif // CSQC
