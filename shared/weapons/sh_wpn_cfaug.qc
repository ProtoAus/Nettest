// ============================================================
//  shared/weapons/sh_wpn_cfaug.qc  -  Steyr AUG (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto.
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff.
//
//  GoldSrc-format viewmodel — sequence-driven, anim windows queried
//  from the model via SH_SeqDuration.  Same pattern as HDAK47.
//
//  Sequence layout (v_aug.mdl):
//     0  idle_0     30 fps
//     1  reload     33 fps  (bcy @ 8, clipout @ 35, clipin @ 64, cy @ 75)
//     2  select     35 fps  (deploy @ 9)
//     3  prefire1   30 fps
//     4  prefire2   30 fps
//     5  prefire3   30 fps
//
//  Sounds in sounds/weapons/wpn_cfaug/.
// ============================================================

// --- Ammo ---
.float mag_cfaug;
.float ammo_cfaug;

// --- Sequence indices ---
const float CFAUG_SEQ_IDLE   = 0;
const float CFAUG_SEQ_RELOAD = 1;
const float CFAUG_SEQ_SELECT = 2;
const float CFAUG_SEQ_SHOOT1 = 3;
const float CFAUG_SEQ_SHOOT2 = 4;
const float CFAUG_SEQ_SHOOT3 = 5;

// --- Timing ---
//
// Sequence-window durations come from the model via SH_SeqDuration.
// Reload-apply (when the mag is visually re-seated) is an internal
// event position; frameduration() can't report those, so it stays a
// constant.  Tuned to land slightly after the clipin event below.
const float CFAUG_RELOAD_APPLY_TIME = 2.00;

const float CFAUG_FIRE_DELAY        = 0.10;   // ~10 rps cyclic
const float CFAUG_DRYFIRE_DELAY     = 0.20;
const float CFAUG_FRAME_INTERVAL    = 0.05;

// --- Sound event timings (elapsed from wep_anim_start) ---
//   reload  bcy      @ frame 8  / 33 fps = 0.242s
//   reload  clipout  @ frame 35 / 33 fps = 1.061s
//   reload  clipin   @ frame 64 / 33 fps = 1.939s
//   reload  cy       @ frame 75 / 33 fps = 2.273s
//   select  deploy   @ frame 9  / 35 fps = 0.257s
const float CFAUG_RELOAD_BCY_TIME      = 0.242;
const float CFAUG_RELOAD_CLIPOUT_TIME  = 1.061;
const float CFAUG_RELOAD_CLIPIN_TIME   = 1.939;
const float CFAUG_RELOAD_CY_TIME       = 2.273;
const float CFAUG_SELECT_DEPLOY_TIME   = 0.257;

// --- Balance ---
const float MAX_MAG_CFAUG             = 30;
const float MAX_AMMO_CFAUG            = 90;

const float CFAUG_BASE_SPREAD          = 0.01;
const float CFAUG_MOVE_SPREAD          = 0.07;
const float CFAUG_FULL_SPREAD_SPEED    = 320;
const float CFAUG_CLOSE_DAMAGE         = 31;
const float CFAUG_MIN_DAMAGE           = 22;
const float CFAUG_DAMAGE_FALLOFF_RANGE = 2304;

const float CFAUG_KICK_PITCH    = 1.4;
const float CFAUG_KICK_VARIANCE = 1.3;
const float CFAUG_KICK_STRENGTH = 1.0;

const float CFAUG_MUZZLE_FORWARD = 42;
const float CFAUG_MUZZLE_RIGHT   = 8.90;
const float CFAUG_MUZZLE_DOWN    = 5.40;

const string CFAUG_VIEWMODEL    = "models/weapons/wpn_cfaug/v_aug.mdl";
const string CFAUG_WORLDMODEL   = "models/weapons/wpn_cfaug/w_aug.mdl";
const string CFAUG_DEPLOY_SOUND = "";
const string CFAUG_DISPLAY_NAME = "AUG";

// Sound stage tracker — fires each timed reload event exactly once
// per action (paired with wep_action_id reset).  Reload has 4 events
// (bcy/clipout/clipin/cy) plus draw has 1 event (deploy).
.float cfaug_snd_stage;

// ============================================================
//  SHARED — sequence-pick + state machine
// ============================================================

float() SH_CFAugPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFAUG_SEQ_SHOOT1;
    if (r < 0.67) return CFAUG_SEQ_SHOOT2;
    return CFAUG_SEQ_SHOOT3;
};

float(float now) SH_CFAugTickState =
{
    return SH_StandardTickState(now, mag_cfaug, ammo_cfaug, MAX_MAG_CFAUG,
        SH_SeqDuration(CFAUG_VIEWMODEL, CFAUG_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFAUG_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFAUG_VIEWMODEL, CFAUG_SEQ_RELOAD, 2.5),
        CFAUG_RELOAD_APPLY_TIME);
};

float(float now) SH_CFAugTryFire =
{
    return SH_StandardTryFire(now, mag_cfaug, CFAUG_FIRE_DELAY, CFAUG_DRYFIRE_DELAY);
};

float(float now) SH_CFAugTryReload =
{
    return SH_StandardTryReload(now, mag_cfaug, ammo_cfaug, MAX_MAG_CFAUG,
        SH_SeqDuration(CFAUG_VIEWMODEL, CFAUG_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFAugPickupCopy =
{
    player.mag_cfaug  = self.mag_cfaug;
    player.ammo_cfaug = self.ammo_cfaug;
};

void() W_CFAugShoot =
{
    W_PenetratingHitscanShoot(CFAUG_BASE_SPREAD, CFAUG_MOVE_SPREAD, CFAUG_FULL_SPREAD_SPEED,
        CFAUG_CLOSE_DAMAGE, CFAUG_MIN_DAMAGE, CFAUG_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CFAUG_KICK_PITCH, CFAUG_KICK_VARIANCE, CFAUG_KICK_STRENGTH);
};

void() W_CFAugFire =
{
    float r = SH_CFAugTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFAugPickShootSeq();
        self.wep_nextframe = time + CFAUG_FRAME_INTERVAL;
        self.cfaug_snd_stage = 0;

        W_CFAugShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfaug/fire1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFAugReload =
{
    if (SH_CFAugTryReload(time))
    {
        self.weaponframe   = CFAUG_SEQ_RELOAD;
        self.wep_nextframe = time + CFAUG_FRAME_INTERVAL;
        self.cfaug_snd_stage = 0;
    }
};

void() W_CFAugFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFAUG_FRAME_INTERVAL;

    // CHAN_AUTO so the predicted-sound dedup window matches CSQC_RecordPredictedAutoSound.
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFAUG_SELECT_DEPLOY_TIME && self.cfaug_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfaug/reload.wav", 1, ATTN_NORM);
            self.cfaug_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFAUG_RELOAD_BCY_TIME && self.cfaug_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfaug/bcy.wav", 1, ATTN_NORM);
            self.cfaug_snd_stage = 1;
        }
        if (elapsed >= CFAUG_RELOAD_CLIPOUT_TIME && self.cfaug_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfaug/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfaug_snd_stage = 2;
        }
        if (elapsed >= CFAUG_RELOAD_CLIPIN_TIME && self.cfaug_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfaug/clipin.wav", 1, ATTN_NORM);
            self.cfaug_snd_stage = 3;
        }
        if (elapsed >= CFAUG_RELOAD_CY_TIME && self.cfaug_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfaug/cy.wav", 1, ATTN_NORM);
            self.cfaug_snd_stage = 4;
        }
    }

    result = SH_CFAugTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFAUG_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfaug_snd_stage = 0;
    }
};

void() W_CFAugEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_aug", SCOPE_CLASS_RIFLE_LOWPOWER);
    W_StandardEquipSetup(CFAUG_VIEWMODEL, CFAUG_DISPLAY_NAME, CFAUG_SEQ_SELECT,
        CFAUG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFAugFire;
    self.reload   = W_CFAugReload;
    self.wepframe = W_CFAugFrame;
    self.shoot    = W_CFAugShoot;
    self.cfaug_snd_stage = 0;
    W_SetCrosshairProfile(CFAUG_BASE_SPREAD, CFAUG_MOVE_SPREAD, CFAUG_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFAugDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfaug  = self.mag_cfaug;
    tgt.ammo_cfaug = self.ammo_cfaug;

    self.mag_cfaug  = 0;
    self.ammo_cfaug = 0;

    setmodel(tgt, CFAUG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfaug";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFAUG;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFAugEquip;
    tgt.weap_drop_func = W_CFAugDrop;
    tgt.pickupcopy    = W_CFAugPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfaug =
{
    setmodel(self, CFAUG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfaug";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFAUG;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFAugEquip;
    self.weap_drop_func = W_CFAugDrop;
    self.pickupcopy   = W_CFAugPickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfaug    = MAX_MAG_CFAUG;
    self.ammo_cfaug   = MAX_AMMO_CFAUG;
    W_RegisterMapWeapon(weapon_cfaug);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfaug_snd_stage;
float csqc_cfaug_snd_action;

void() CSQC_PredictCFAugCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfaug_snd_action)
    {
        csqc_cfaug_snd_action = predicted_player.wep_action_id;
        csqc_cfaug_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFAugTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfaug/fire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFAUG_BASE_SPREAD, CFAUG_MOVE_SPREAD, CFAUG_FULL_SPREAD_SPEED,
                    CFAUG_CLOSE_DAMAGE, CFAUG_MIN_DAMAGE, CFAUG_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CFAUG_KICK_PITCH, CFAUG_KICK_VARIANCE, CFAUG_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CFAUG_MUZZLE_FORWARD, CFAUG_MUZZLE_RIGHT,
                    CFAUG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CFAUG_MUZZLE_FORWARD, CFAUG_MUZZLE_RIGHT,
                    CFAUG_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_cfaug_snd_stage < 1 && elapsed >= CFAUG_SELECT_DEPLOY_TIME)
            {
                localsound("sounds/weapons/wpn_cfaug/reload.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfaug_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfaug_snd_stage < 1 && elapsed >= CFAUG_RELOAD_BCY_TIME)
            {
                localsound("sounds/weapons/wpn_cfaug/bcy.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfaug_snd_stage = 1;
            }
            if (csqc_cfaug_snd_stage < 2 && elapsed >= CFAUG_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfaug/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfaug_snd_stage = 2;
            }
            if (csqc_cfaug_snd_stage < 3 && elapsed >= CFAUG_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfaug/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfaug_snd_stage = 3;
            }
            if (csqc_cfaug_snd_stage < 4 && elapsed >= CFAUG_RELOAD_CY_TIME)
            {
                localsound("sounds/weapons/wpn_cfaug/cy.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_cfaug_snd_stage = 4;
            }
        }
    }

    SH_CFAugTickState(csqc_pred_time);
};

void() CSQC_PredictCFAugReload =
{
    if (SH_CFAugTryReload(csqc_pred_time))
    {
        csqc_cfaug_snd_stage  = 0;
        csqc_cfaug_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFAugDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFAUG_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFAUG_SEQ_SHOOT1;
        if (r < 0.67) return CFAUG_SEQ_SHOOT2;
        return CFAUG_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFAUG_SEQ_RELOAD;

    return CFAUG_SEQ_IDLE;
};

void() CSQC_CFAugDropClear =
{
    self.mag_cfaug = 0;
    self.ammo_cfaug = 0;
};

void() CSQC_CFAugEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_aug", SCOPE_CLASS_RIFLE_LOWPOWER);
    self.weapon_name         = CFAUG_DISPLAY_NAME;
    self.weapon_viewmodel    = CFAUG_VIEWMODEL;
    self.weapon_worldmodel   = CFAUG_WORLDMODEL;
    self.weapon_deploy_sound = CFAUG_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFAugCommand;
    self.csqc_predict_reload = CSQC_PredictCFAugReload;
    self.csqc_display_frame  = CSQC_CFAugDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFAugDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
