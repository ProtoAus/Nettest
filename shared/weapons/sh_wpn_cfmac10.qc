// ============================================================
//  shared/weapons/sh_wpn_cfmac10.qc  -  MAC-10 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 30-round magazine, 100 reserve, full-auto SMG.
//  Fire  : lag-compensated hitscan, linear damage falloff.  No
//          penetration (SMG, .45 ACP).
//
//  GoldSrc-format viewmodel — sequence-driven; durations from the
//  model via SH_SeqDuration.
//
//  Sequence layout (v_mac10.mdl):
//     0  idle_0    30 fps
//     1  reload    18 fps  (clipout @ 8, clipin @ 22, deploy-tail @ 36)
//     2  select    30 fps  (deploy @ 2)
//     3  prefire1  30 fps
//     4  prefire2  30 fps
//     5  prefire3  30 fps
//
//  Sounds in sounds/weapons/wpn_cfmac10/.
// ============================================================

.float mag_cfmac10;
.float ammo_cfmac10;

const float CFMAC10_SEQ_IDLE   = 0;
const float CFMAC10_SEQ_RELOAD = 1;
const float CFMAC10_SEQ_SELECT = 2;
const float CFMAC10_SEQ_SHOOT1 = 3;
const float CFMAC10_SEQ_SHOOT2 = 4;
const float CFMAC10_SEQ_SHOOT3 = 5;

const float CFMAC10_RELOAD_APPLY_TIME = 1.30;   // ~clipin + small gap

const float CFMAC10_FIRE_DELAY        = 0.075;  // ~13 rps cyclic — high RPM SMG
const float CFMAC10_DRYFIRE_DELAY     = 0.20;
const float CFMAC10_FRAME_INTERVAL    = 0.05;

// --- Sound event timings ---
//   reload  clipout    @ frame 8  / 18 = 0.444s
//   reload  clipin     @ frame 22 / 18 = 1.222s
//   reload  deploy-end @ frame 36 / 18 = 2.000s
//   select  deploy     @ frame 2  / 30 = 0.067s
const float CFMAC10_RELOAD_CLIPOUT_TIME = 0.444;
const float CFMAC10_RELOAD_CLIPIN_TIME  = 1.222;
const float CFMAC10_RELOAD_TAIL_TIME    = 2.000;
const float CFMAC10_SELECT_DEPLOY_TIME  = 0.067;

const float MAX_MAG_CFMAC10             = 30;
const float MAX_AMMO_CFMAC10            = 100;

const float CFMAC10_BASE_SPREAD          = 0.01;
const float CFMAC10_MOVE_SPREAD          = 0.08;
const float CFMAC10_FULL_SPREAD_SPEED    = 320;
const float CFMAC10_CLOSE_DAMAGE         = 14;     // .45 ACP — slightly heavier than 9mm
const float CFMAC10_MIN_DAMAGE           = 7;
const float CFMAC10_DAMAGE_FALLOFF_RANGE = 1800;   // shorter than rifles, .45 falls off fast

const float CFMAC10_KICK_PITCH    = 0.8;
const float CFMAC10_KICK_VARIANCE = 0.4;
const float CFMAC10_KICK_STRENGTH = 1.3;   // notoriously uncontrollable IRL

// Muzzle attachment — sourced from v_mac10.mdl's $attachment 0:
//     $attachment 0 "Bone01" 14.0 0.0 -0.4
// Bone-attached so the flash + tracer track the firing animation
// instead of sitting at a static camera-relative offset.  Mirrors
// HDAK47's pattern (sh_wpn_hdak47.qc).
const string CFMAC10_MUZZLE_BONE   = "Bone01";
#define CFMAC10_MUZZLE_OFFSET ('14.0 0.0 -0.4')

const string CFMAC10_VIEWMODEL    = "models/weapons/wpn_cfmac10/v_mac10.mdl";
const string CFMAC10_WORLDMODEL   = "models/weapons/wpn_cfmac10/w_mac10.mdl";
const string CFMAC10_DEPLOY_SOUND = "";
const string CFMAC10_DISPLAY_NAME = "MAC10";

.float cfmac10_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFMac10PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFMAC10_SEQ_SHOOT1;
    if (r < 0.67) return CFMAC10_SEQ_SHOOT2;
    return CFMAC10_SEQ_SHOOT3;
};

float(float now) SH_CFMac10TickState =
{
    return SH_StandardTickState(now, mag_cfmac10, ammo_cfmac10, MAX_MAG_CFMAC10,
        SH_SeqDuration(CFMAC10_VIEWMODEL, CFMAC10_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFMAC10_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFMAC10_VIEWMODEL, CFMAC10_SEQ_RELOAD, 2.0),
        CFMAC10_RELOAD_APPLY_TIME);
};

float(float now) SH_CFMac10TryFire =
{
    return SH_StandardTryFire(now, mag_cfmac10, CFMAC10_FIRE_DELAY, CFMAC10_DRYFIRE_DELAY);
};

float(float now) SH_CFMac10TryReload =
{
    return SH_StandardTryReload(now, mag_cfmac10, ammo_cfmac10, MAX_MAG_CFMAC10,
        SH_SeqDuration(CFMAC10_VIEWMODEL, CFMAC10_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFMac10PickupCopy =
{
    player.mag_cfmac10  = self.mag_cfmac10;
    player.ammo_cfmac10 = self.ammo_cfmac10;
};

void() W_CFMac10Shoot =
{
    W_StandardHitscanShoot(CFMAC10_BASE_SPREAD, CFMAC10_MOVE_SPREAD, CFMAC10_FULL_SPREAD_SPEED,
        CFMAC10_CLOSE_DAMAGE, CFMAC10_MIN_DAMAGE, CFMAC10_DAMAGE_FALLOFF_RANGE);
    SH_ApplyViewKick(CFMAC10_KICK_PITCH, CFMAC10_KICK_VARIANCE, CFMAC10_KICK_STRENGTH);
};

void() W_CFMac10Fire =
{
    float r = SH_CFMac10TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFMac10PickShootSeq();
        self.wep_nextframe = time + CFMAC10_FRAME_INTERVAL;
        self.cfmac10_snd_stage = 0;

        W_CFMac10Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmac10/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFMac10Reload =
{
    if (SH_CFMac10TryReload(time))
    {
        self.weaponframe   = CFMAC10_SEQ_RELOAD;
        self.wep_nextframe = time + CFMAC10_FRAME_INTERVAL;
        self.cfmac10_snd_stage = 0;
    }
};

void() W_CFMac10Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFMAC10_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFMAC10_SELECT_DEPLOY_TIME && self.cfmac10_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmac10/draw.wav", 1, ATTN_NORM);
            self.cfmac10_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFMAC10_RELOAD_CLIPOUT_TIME && self.cfmac10_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmac10/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.cfmac10_snd_stage = 1;
        }
        if (elapsed >= CFMAC10_RELOAD_CLIPIN_TIME && self.cfmac10_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmac10/clipin.wav", 1, ATTN_NORM);
            self.cfmac10_snd_stage = 2;
        }
        if (elapsed >= CFMAC10_RELOAD_TAIL_TIME && self.cfmac10_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmac10/reload.wav", 1, ATTN_NORM);
            self.cfmac10_snd_stage = 3;
        }
    }

    result = SH_CFMac10TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFMAC10_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfmac10_snd_stage = 0;
    }
};

void() W_CFMac10Equip =
{
    W_StandardEquipSetup(CFMAC10_VIEWMODEL, CFMAC10_DISPLAY_NAME, CFMAC10_SEQ_SELECT,
        CFMAC10_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFMac10Fire;
    self.reload   = W_CFMac10Reload;
    self.wepframe = W_CFMac10Frame;
    self.shoot    = W_CFMac10Shoot;
    self.cfmac10_snd_stage = 0;
    W_SetCrosshairProfile(CFMAC10_BASE_SPREAD, CFMAC10_MOVE_SPREAD, CFMAC10_FULL_SPREAD_SPEED, 1.7, TRUE);
};

void() W_CFMac10Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfmac10  = self.mag_cfmac10;
    tgt.ammo_cfmac10 = self.ammo_cfmac10;

    self.mag_cfmac10  = 0;
    self.ammo_cfmac10 = 0;

    setmodel(tgt, CFMAC10_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfmac10";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFMAC10;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFMac10Equip;
    tgt.weap_drop_func = W_CFMac10Drop;
    tgt.pickupcopy    = W_CFMac10PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfmac10 =
{
    setmodel(self, CFMAC10_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfmac10";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFMAC10;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFMac10Equip;
    self.weap_drop_func = W_CFMac10Drop;
    self.pickupcopy   = W_CFMac10PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfmac10  = MAX_MAG_CFMAC10;
    self.ammo_cfmac10 = MAX_AMMO_CFMAC10;
    W_RegisterMapWeapon(weapon_cfmac10);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfmac10_snd_stage;
float csqc_cfmac10_snd_action;

void() CSQC_PredictCFMac10Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfmac10_snd_action)
    {
        csqc_cfmac10_snd_action = predicted_player.wep_action_id;
        csqc_cfmac10_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFMac10TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmac10/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(CFMAC10_BASE_SPREAD, CFMAC10_MOVE_SPREAD, CFMAC10_FULL_SPREAD_SPEED,
                    CFMAC10_CLOSE_DAMAGE, CFMAC10_MIN_DAMAGE, CFMAC10_DAMAGE_FALLOFF_RANGE);
                SH_ApplyViewKick(CFMAC10_KICK_PITCH, CFMAC10_KICK_VARIANCE, CFMAC10_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle flash + smoke — sampled from
                // the viewmodel's $attachment 0 (Bone01) so the flash
                // tracks the firing animation.  Tracer start point
                // follows automatically via CSQC_MuzzleFlashWorldPos
                // (it reads csqc_muzzle_debug_offset which the World
                // helper sets).
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFMAC10_MUZZLE_BONE, CFMAC10_MUZZLE_OFFSET);
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
            if (csqc_cfmac10_snd_stage < 1 && elapsed >= CFMAC10_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfmac10/draw.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmac10_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfmac10_snd_stage < 1 && elapsed >= CFMAC10_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfmac10/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfmac10_snd_stage = 1;
            }
            if (csqc_cfmac10_snd_stage < 2 && elapsed >= CFMAC10_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfmac10/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmac10_snd_stage = 2;
            }
            if (csqc_cfmac10_snd_stage < 3 && elapsed >= CFMAC10_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfmac10/reload.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmac10_snd_stage = 3;
            }
        }
    }

    SH_CFMac10TickState(csqc_pred_time);
};

void() CSQC_PredictCFMac10Reload =
{
    if (SH_CFMac10TryReload(csqc_pred_time))
    {
        csqc_cfmac10_snd_stage  = 0;
        csqc_cfmac10_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFMac10DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFMAC10_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFMAC10_SEQ_SHOOT1;
        if (r < 0.67) return CFMAC10_SEQ_SHOOT2;
        return CFMAC10_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFMAC10_SEQ_RELOAD;

    return CFMAC10_SEQ_IDLE;
};

void() CSQC_CFMac10DropClear =
{
    self.mag_cfmac10 = 0;
    self.ammo_cfmac10 = 0;
};

void() CSQC_CFMac10Equip =
{
    self.weapon_name         = CFMAC10_DISPLAY_NAME;
    self.weapon_viewmodel    = CFMAC10_VIEWMODEL;
    self.weapon_worldmodel   = CFMAC10_WORLDMODEL;
    self.weapon_deploy_sound = CFMAC10_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFMac10Command;
    self.csqc_predict_reload = CSQC_PredictCFMac10Reload;
    self.csqc_display_frame  = CSQC_CFMac10DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFMac10DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot + muzzle anchor — same constants the fire path uses.
    self.weapon_muzzle_bone   = CFMAC10_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFMAC10_MUZZLE_OFFSET;
};

#endif // CSQC
