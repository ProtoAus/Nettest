// ============================================================
//  shared/weapons/sh_wpn_cfrevolver.qc  -  Colt Anaconda (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 36 reserve, semi-auto .44 Magnum revolver
//  Fire  : lag-compensated penetrating hitscan, heavy single-shot kick
//
//  Independent of WEP_DEAGLE — has its own ammo pool (mag_cfrevolver /
//  ammo_cfrevolver) and animation set.  Naming collision is purely
//  lexical: WEP_DEAGLE = "Desert Eagle", WEP_CFREVOLVER = "Colt Anaconda".
//
//  Sequence-driven GoldSrc viewmodel (v_deagle.mdl in wpn_cfrevolver).
//  Same prediction shape as HDAK47 / cfm9: setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally; W_CFRevolverFrame ticks the state machine
//  and fires timed sound events, never per-tick frame stepping.
//
//  Sequence layout (from v_deagle.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   90 fps  (shoot variant A — event 5001 fire)
//      2  prefire   90 fps  (shoot variant B)
//      3  prefire   90 fps  (shoot variant C)
//      4  reload    45 fps  (clipout@9, clipin@40, bcback@53)
//      5  select    30 fps  (draw — reload1.wav at frame 2)
//      6  select2   30 fps  (draw variant — reload2.wav at frame 2)
//
//  Reload sounds in this revolver: clipout = cylinder swing-out,
//  clipin = speedloader insertion, bcback = cylinder close-up snap.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfrevolver;
.float ammo_cfrevolver;

// --- Per-entity sound stage trackers (server side) ---
.float cfrevolver_draw_snd_played;
.float cfrevolver_reload_snd_stage;

// --- Sequence indices ---
const float CFREVOLVER_SEQ_IDLE     = 0;
const float CFREVOLVER_SEQ_SHOOT1   = 1;
const float CFREVOLVER_SEQ_SHOOT2   = 2;
const float CFREVOLVER_SEQ_SHOOT3   = 3;
const float CFREVOLVER_SEQ_RELOAD   = 4;
const float CFREVOLVER_SEQ_DRAW     = 5;
const float CFREVOLVER_SEQ_DRAW2    = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 45 fps:
//   clipout at frame  9 / 45 = 0.200s
//   clipin  at frame 40 / 45 = 0.889s
//   bcback  at frame 53 / 45 = 1.178s
// Select sequence @ 30 fps:
//   reload1 at frame  2 / 30 = 0.067s
const float CFREVOLVER_RELOAD_CLIPOUT_TIME = 0.200;
const float CFREVOLVER_RELOAD_CLIPIN_TIME  = 0.889;
const float CFREVOLVER_RELOAD_BCBACK_TIME  = 1.178;
const float CFREVOLVER_DRAW_CLACK_TIME     = 0.067;

// Ammo applies once cylinder is closed (after bcback frame).
const float CFREVOLVER_RELOAD_APPLY_TIME   = 1.20;

// --- Gameplay tuning ---
const float CFREVOLVER_FIRE_DELAY        = 0.30;   // heavy single-shot revolver
const float CFREVOLVER_DRYFIRE_DELAY     = 0.20;
const float CFREVOLVER_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFREVOLVER           = 6;
const float MAX_AMMO_CFREVOLVER          = 36;

// --- Balance ---
// Big revolver — slightly higher damage than the Desert Eagle, but
// smaller mag and slower cyclic rate.  Tune to taste once in game.
const float CFREVOLVER_BASE_SPREAD          = 0.012;
const float CFREVOLVER_MOVE_SPREAD          = 0.07;
const float CFREVOLVER_FULL_SPREAD_SPEED    = 320;
const float CFREVOLVER_CLOSE_DAMAGE         = 42;
const float CFREVOLVER_MIN_DAMAGE           = 22;
const float CFREVOLVER_DAMAGE_FALLOFF_RANGE = 4096;
const float CFREVOLVER_KICK_PITCH    = 1.75;
const float CFREVOLVER_KICK_VARIANCE = 0.55;
const float CFREVOLVER_KICK_STRENGTH = 1.5;

// Muzzle attachment from v_deagle.mdl's $attachment 0:
//   $attachment 0 "Bone gun" 15.0 0.0 0.0
// Bone name DELIBERATELY contains a space — match it verbatim.
const string CFREVOLVER_MUZZLE_BONE   = "Bone gun";
#define CFREVOLVER_MUZZLE_OFFSET ('15.0 0.0 0.0')

const string CFREVOLVER_VIEWMODEL    = "models/weapons/wpn_cfrevolver/v_revolver.mdl";
const string CFREVOLVER_WORLDMODEL   = "models/weapons/wpn_cfrevolver/w_revolver.mdl";
const string CFREVOLVER_DEPLOY_SOUND = "";
const string CFREVOLVER_DISPLAY_NAME = "Colt Anaconda";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

float() SH_CFRevolverPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFREVOLVER_SEQ_SHOOT1;
    if (r < 0.67) return CFREVOLVER_SEQ_SHOOT2;
    return CFREVOLVER_SEQ_SHOOT3;
};

float(float now) SH_CFRevolverTickState =
{
    return SH_StandardTickState(now, mag_cfrevolver, ammo_cfrevolver, MAX_MAG_CFREVOLVER,
        SH_SeqDuration(CFREVOLVER_VIEWMODEL, CFREVOLVER_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFREVOLVER_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFREVOLVER_VIEWMODEL, CFREVOLVER_SEQ_RELOAD, 1.5),
        CFREVOLVER_RELOAD_APPLY_TIME);
};

float(float now) SH_CFRevolverTryFire =
{
    // Semi-auto: must release +attack between shots (revolver trigger pull).
    return SH_StandardTryFireSemiAuto(now, mag_cfrevolver, CFREVOLVER_FIRE_DELAY, CFREVOLVER_DRYFIRE_DELAY);
};

float(float now) SH_CFRevolverTryReload =
{
    return SH_StandardTryReload(now, mag_cfrevolver, ammo_cfrevolver, MAX_MAG_CFREVOLVER,
        SH_SeqDuration(CFREVOLVER_VIEWMODEL, CFREVOLVER_SEQ_RELOAD, 1.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFRevolverPickupCopy =
{
    player.mag_cfrevolver  = self.mag_cfrevolver;
    player.ammo_cfrevolver = self.ammo_cfrevolver;
};

void() W_CFRevolverShoot =
{
    W_PenetratingHitscanShoot(CFREVOLVER_BASE_SPREAD, CFREVOLVER_MOVE_SPREAD, CFREVOLVER_FULL_SPREAD_SPEED,
        CFREVOLVER_CLOSE_DAMAGE, CFREVOLVER_MIN_DAMAGE, CFREVOLVER_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CFREVOLVER_KICK_PITCH, CFREVOLVER_KICK_VARIANCE, CFREVOLVER_KICK_STRENGTH);
};

void() W_CFRevolverFire =
{
    float r = SH_CFRevolverTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFRevolverPickShootSeq();
        self.wep_nextframe = time + CFREVOLVER_FRAME_INTERVAL;

        W_CFRevolverShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfrevolver/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFRevolverReload =
{
    if (SH_CFRevolverTryReload(time))
    {
        self.weaponframe   = CFREVOLVER_SEQ_RELOAD;
        self.wep_nextframe = time + CFREVOLVER_FRAME_INTERVAL;
        self.cfrevolver_reload_snd_stage = 0;
    }
};

void() W_CFRevolverFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFREVOLVER_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFREVOLVER_DRAW_CLACK_TIME && !self.cfrevolver_draw_snd_played)
        {
            // Always use reload1.wav for the select-sequence sound.
            // Original design alternated reload1/reload2 across equips
            // but the server's weaponframe (set by W_StandardEquipSetup
            // to CFREVOLVER_SEQ_DRAW) diverged from CSQC's DisplayFrame
            // when the alt latch was set, so both animations rendered
            // simultaneously.  Settling on one sequence eliminates the
            // desync; alt animations can come back if the latch is
            // replicated through the prediction proxy.
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfrevolver/reload1.WAV", 1, ATTN_NORM);
            self.cfrevolver_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFREVOLVER_RELOAD_CLIPOUT_TIME && self.cfrevolver_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfrevolver/clipout.WAV", 1, ATTN_NORM);
            self.cfrevolver_reload_snd_stage = 1;
        }
        if (elapsed >= CFREVOLVER_RELOAD_CLIPIN_TIME && self.cfrevolver_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfrevolver/clipin.WAV", 1, ATTN_NORM);
            self.cfrevolver_reload_snd_stage = 2;
        }
        if (elapsed >= CFREVOLVER_RELOAD_BCBACK_TIME && self.cfrevolver_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfrevolver/bcback.WAV", 1, ATTN_NORM);
            self.cfrevolver_reload_snd_stage = 3;
        }
    }

    result = SH_CFRevolverTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFREVOLVER_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfrevolver_reload_snd_stage = 0;
    }
};

void() W_CFRevolverEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_anaconda", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFREVOLVER_VIEWMODEL, CFREVOLVER_DISPLAY_NAME, CFREVOLVER_SEQ_DRAW,
        CFREVOLVER_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFRevolverFire;
    self.reload   = W_CFRevolverReload;
    self.wepframe = W_CFRevolverFrame;
    self.shoot    = W_CFRevolverShoot;
    self.cfrevolver_draw_snd_played  = 0;
    self.cfrevolver_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFREVOLVER_BASE_SPREAD, CFREVOLVER_MOVE_SPREAD, CFREVOLVER_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFRevolverDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfrevolver  = self.mag_cfrevolver;
    tgt.ammo_cfrevolver = self.ammo_cfrevolver;

    self.mag_cfrevolver  = 0;
    self.ammo_cfrevolver = 0;

    setmodel(tgt, CFREVOLVER_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfrevolver";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFREVOLVER;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFRevolverEquip;
    tgt.weap_drop_func = W_CFRevolverDrop;
    tgt.pickupcopy   = W_CFRevolverPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfrevolver =
{
    setmodel(self, CFREVOLVER_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfrevolver";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFREVOLVER;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFRevolverEquip;
    self.weap_drop_func = W_CFRevolverDrop;
    self.pickupcopy    = W_CFRevolverPickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfrevolver  = MAX_MAG_CFREVOLVER;
    self.ammo_cfrevolver = MAX_AMMO_CFREVOLVER;
    W_RegisterMapWeapon(weapon_cfrevolver);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfrevolver_draw_snd_played;
float csqc_cfrevolver_reload_snd_stage;
float csqc_cfrevolver_snd_action;

void() CSQC_PredictCFRevolverCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfrevolver_snd_action)
    {
        csqc_cfrevolver_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfrevolver_draw_snd_played  = 0;
        csqc_cfrevolver_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFRevolverTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfrevolver/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFREVOLVER_BASE_SPREAD, CFREVOLVER_MOVE_SPREAD, CFREVOLVER_FULL_SPREAD_SPEED,
                    CFREVOLVER_CLOSE_DAMAGE, CFREVOLVER_MIN_DAMAGE, CFREVOLVER_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CFREVOLVER_KICK_PITCH, CFREVOLVER_KICK_VARIANCE, CFREVOLVER_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFREVOLVER_MUZZLE_BONE, CFREVOLVER_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorldAnimated(muzzle_world, self.wep_action_id);
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
            if (!csqc_cfrevolver_draw_snd_played && elapsed >= CFREVOLVER_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfrevolver/reload1.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfrevolver_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfrevolver_reload_snd_stage < 1 && elapsed >= CFREVOLVER_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfrevolver/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfrevolver_reload_snd_stage = 1;
            }
            if (csqc_cfrevolver_reload_snd_stage < 2 && elapsed >= CFREVOLVER_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfrevolver/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfrevolver_reload_snd_stage = 2;
            }
            if (csqc_cfrevolver_reload_snd_stage < 3 && elapsed >= CFREVOLVER_RELOAD_BCBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfrevolver/bcback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfrevolver_reload_snd_stage = 3;
            }
        }
    }

    SH_CFRevolverTickState(csqc_pred_time);
};

void() CSQC_PredictCFRevolverReload =
{
    if (SH_CFRevolverTryReload(csqc_pred_time))
    {
        csqc_cfrevolver_reload_snd_stage = 0;
        csqc_cfrevolver_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFRevolverDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFREVOLVER_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFREVOLVER_SEQ_SHOOT1;
        if (r < 0.67) return CFREVOLVER_SEQ_SHOOT2;
        return CFREVOLVER_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFREVOLVER_SEQ_RELOAD;

    return CFREVOLVER_SEQ_IDLE;
};

void() CSQC_CFRevolverDropClear =
{
    self.mag_cfrevolver  = 0;
    self.ammo_cfrevolver = 0;
};

void() CSQC_CFRevolverEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_anaconda", SCOPE_CLASS_NONE);
    self.weapon_name         = CFREVOLVER_DISPLAY_NAME;
    self.weapon_viewmodel    = CFREVOLVER_VIEWMODEL;
    self.weapon_worldmodel   = CFREVOLVER_WORLDMODEL;
    self.weapon_deploy_sound = CFREVOLVER_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFRevolverCommand;
    self.csqc_predict_reload = CSQC_PredictCFRevolverReload;
    self.csqc_display_frame  = CSQC_CFRevolverDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFRevolverDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFREVOLVER_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFREVOLVER_MUZZLE_OFFSET;

    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfrevolver_draw_snd_played = 1;
        csqc_cfrevolver_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
