// ============================================================
//  shared/weapons/sh_wpn_cfm249.qc  -  CF M249 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 100-round belt, 200 reserve, full-auto 5.56 LMG.
//  Fire  : lag-compensated PENETRATING hitscan, linear damage falloff.
//
//  Sequence layout (v_m249.mdl):
//     0  idle_0    30 fps
//     1  prefire1  30 fps
//     2  prefire2  30 fps
//     3  reload    36 fps  (clipout @ 15, clipin @ 41, reload-tail @ 65)
//     4  select    45 fps  (deploy @ 1)
//
//  Sounds in sounds/weapons/wpn_cfm249/.
// ============================================================

.float mag_cfm249;
.float ammo_cfm249;

const float CFM249_SEQ_IDLE   = 0;
const float CFM249_SEQ_SHOOT1 = 1;
const float CFM249_SEQ_SHOOT2 = 2;
const float CFM249_SEQ_RELOAD = 3;
const float CFM249_SEQ_SELECT = 4;

const float CFM249_RELOAD_APPLY_TIME = 1.20;

const float CFM249_FIRE_DELAY        = 0.08;   // ~750 rpm cyclic
const float CFM249_DRYFIRE_DELAY     = 0.20;
const float CFM249_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (reload 36 fps, select 45 fps) ---
const float CFM249_RELOAD_CLIPOUT_TIME = 0.417;   // frame 15 / 36
const float CFM249_RELOAD_CLIPIN_TIME  = 1.139;   // frame 41 / 36
const float CFM249_RELOAD_TAIL_TIME    = 1.806;   // frame 65 / 36
const float CFM249_SELECT_DEPLOY_TIME  = 0.022;   // frame 1  / 45

const float MAX_MAG_CFM249             = 100;
const float MAX_AMMO_CFM249            = 200;

const float CFM249_BASE_SPREAD          = 0.015;
const float CFM249_MOVE_SPREAD          = 0.10;
const float CFM249_FULL_SPREAD_SPEED    = 320;
const float CFM249_CLOSE_DAMAGE         = 28;     // 5.56 LMG
const float CFM249_MIN_DAMAGE           = 18;
const float CFM249_DAMAGE_FALLOFF_RANGE = 2304;

const float CFM249_KICK_PITCH    = 1.0;
const float CFM249_KICK_VARIANCE = 0.8;
const float CFM249_KICK_STRENGTH = 1.1;

// Muzzle attachment — from v_m249.mdl's $attachment 0:
//     $attachment 0 "Box01" 0.0 1.3 18.8
const string CFM249_MUZZLE_BONE   = "Box01";
#define CFM249_MUZZLE_OFFSET ('0.0 1.3 18.8')

const string CFM249_VIEWMODEL    = "models/weapons/wpn_cfm249/v_m249.mdl";
const string CFM249_WORLDMODEL   = "models/weapons/wpn_cfm249/w_m249.mdl";
const string CFM249_DEPLOY_SOUND = "";
const string CFM249_DISPLAY_NAME = "M249";

.float cfm249_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFM249PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFM249_SEQ_SHOOT1;
    return CFM249_SEQ_SHOOT2;
};

float(float now) SH_CFM249TickState =
{
    return SH_StandardTickState(now, mag_cfm249, ammo_cfm249, MAX_MAG_CFM249,
        SH_SeqDuration(CFM249_VIEWMODEL, CFM249_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFM249_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFM249_VIEWMODEL, CFM249_SEQ_RELOAD, 2.0),
        CFM249_RELOAD_APPLY_TIME);
};

float(float now) SH_CFM249TryFire =
{
    return SH_StandardTryFire(now, mag_cfm249, CFM249_FIRE_DELAY, CFM249_DRYFIRE_DELAY);
};

float(float now) SH_CFM249TryReload =
{
    return SH_StandardTryReload(now, mag_cfm249, ammo_cfm249, MAX_MAG_CFM249,
        SH_SeqDuration(CFM249_VIEWMODEL, CFM249_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFM249PickupCopy =
{
    player.mag_cfm249  = self.mag_cfm249;
    player.ammo_cfm249 = self.ammo_cfm249;
};

void() W_CFM249Shoot =
{
    W_PenetratingHitscanShoot(CFM249_BASE_SPREAD, CFM249_MOVE_SPREAD, CFM249_FULL_SPREAD_SPEED,
        CFM249_CLOSE_DAMAGE, CFM249_MIN_DAMAGE, CFM249_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CFM249_KICK_PITCH, CFM249_KICK_VARIANCE, CFM249_KICK_STRENGTH);
};

void() W_CFM249Fire =
{
    float r = SH_CFM249TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFM249PickShootSeq();
        self.wep_nextframe = time + CFM249_FRAME_INTERVAL;
        self.cfm249_snd_stage = 0;

        W_CFM249Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm249/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFM249Reload =
{
    if (SH_CFM249TryReload(time))
    {
        self.weaponframe   = CFM249_SEQ_RELOAD;
        self.wep_nextframe = time + CFM249_FRAME_INTERVAL;
        self.cfm249_snd_stage = 0;
    }
};

void() W_CFM249Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFM249_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFM249_SELECT_DEPLOY_TIME && self.cfm249_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm249/draw.WAV", 1, ATTN_NORM);
            self.cfm249_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFM249_RELOAD_CLIPOUT_TIME && self.cfm249_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm249/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfm249_snd_stage = 1;
        }
        if (elapsed >= CFM249_RELOAD_CLIPIN_TIME && self.cfm249_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm249/clipin.WAV", 1, ATTN_NORM);
            self.cfm249_snd_stage = 2;
        }
        if (elapsed >= CFM249_RELOAD_TAIL_TIME && self.cfm249_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm249/reload.WAV", 1, ATTN_NORM);
            self.cfm249_snd_stage = 3;
        }
    }

    result = SH_CFM249TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFM249_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfm249_snd_stage = 0;
    }
};

void() W_CFM249Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m249", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFM249_VIEWMODEL, CFM249_DISPLAY_NAME, CFM249_SEQ_SELECT,
        CFM249_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFM249Fire;
    self.reload   = W_CFM249Reload;
    self.wepframe = W_CFM249Frame;
    self.shoot    = W_CFM249Shoot;
    self.cfm249_snd_stage = 0;
    W_SetCrosshairProfile(CFM249_BASE_SPREAD, CFM249_MOVE_SPREAD, CFM249_FULL_SPREAD_SPEED, 1.9, TRUE);
};

void() W_CFM249Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfm249  = self.mag_cfm249;
    tgt.ammo_cfm249 = self.ammo_cfm249;

    self.mag_cfm249  = 0;
    self.ammo_cfm249 = 0;

    setmodel(tgt, CFM249_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfm249";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFM249;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFM249Equip;
    tgt.weap_drop_func = W_CFM249Drop;
    tgt.pickupcopy    = W_CFM249PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfm249 =
{
    setmodel(self, CFM249_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfm249";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFM249;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFM249Equip;
    self.weap_drop_func = W_CFM249Drop;
    self.pickupcopy   = W_CFM249PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfm249   = MAX_MAG_CFM249;
    self.ammo_cfm249  = MAX_AMMO_CFM249;
    W_RegisterMapWeapon(weapon_cfm249);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfm249_snd_stage;
float csqc_cfm249_snd_action;

void() CSQC_PredictCFM249Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfm249_snd_action)
    {
        csqc_cfm249_snd_action = predicted_player.wep_action_id;
        csqc_cfm249_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFM249TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm249/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFM249_BASE_SPREAD, CFM249_MOVE_SPREAD, CFM249_FULL_SPREAD_SPEED,
                    CFM249_CLOSE_DAMAGE, CFM249_MIN_DAMAGE, CFM249_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CFM249_KICK_PITCH, CFM249_KICK_VARIANCE, CFM249_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFM249_MUZZLE_BONE, CFM249_MUZZLE_OFFSET);
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
            if (csqc_cfm249_snd_stage < 1 && elapsed >= CFM249_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfm249/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm249_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfm249_snd_stage < 1 && elapsed >= CFM249_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfm249/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfm249_snd_stage = 1;
            }
            if (csqc_cfm249_snd_stage < 2 && elapsed >= CFM249_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfm249/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm249_snd_stage = 2;
            }
            if (csqc_cfm249_snd_stage < 3 && elapsed >= CFM249_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfm249/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm249_snd_stage = 3;
            }
        }
    }

    SH_CFM249TickState(csqc_pred_time);
};

void() CSQC_PredictCFM249Reload =
{
    if (SH_CFM249TryReload(csqc_pred_time))
    {
        csqc_cfm249_snd_stage  = 0;
        csqc_cfm249_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFM249DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFM249_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFM249_SEQ_SHOOT1;
        return CFM249_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFM249_SEQ_RELOAD;

    return CFM249_SEQ_IDLE;
};

void() CSQC_CFM249DropClear =
{
    self.mag_cfm249 = 0;
    self.ammo_cfm249 = 0;
};

void() CSQC_CFM249Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m249", SCOPE_CLASS_NONE);
    self.weapon_name         = CFM249_DISPLAY_NAME;
    self.weapon_viewmodel    = CFM249_VIEWMODEL;
    self.weapon_worldmodel   = CFM249_WORLDMODEL;
    self.weapon_deploy_sound = CFM249_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFM249Command;
    self.csqc_predict_reload = CSQC_PredictCFM249Reload;
    self.csqc_display_frame  = CSQC_CFM249DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFM249DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFM249_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFM249_MUZZLE_OFFSET;
};

#endif // CSQC
