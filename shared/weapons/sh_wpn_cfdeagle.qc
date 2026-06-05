// ============================================================
//  shared/weapons/sh_wpn_cfdeagle.qc  -  Colt Anaconda (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 36 reserve, semi-auto .44 Magnum revolver
//  Fire  : lag-compensated penetrating hitscan, heavy single-shot kick
//
//  Independent of WEP_DEAGLE — has its own ammo pool (mag_cfdeagle /
//  ammo_cfdeagle) and animation set.  Naming collision is purely
//  lexical: WEP_DEAGLE = "Desert Eagle", WEP_CFDEAGLE = "Colt Anaconda".
//
//  Sequence-driven GoldSrc viewmodel (v_deagle.mdl in wpn_cfdeagle).
//  Same prediction shape as HDAK47 / cffiveseven: setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally; W_CFDeagleFrame ticks the state machine
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
.float mag_cfdeagle;
.float ammo_cfdeagle;

// --- Per-entity sound stage trackers (server side) ---
.float cfdeagle_draw_snd_played;
.float cfdeagle_reload_snd_stage;

// --- Sequence indices ---
const float CFDEAGLE_SEQ_IDLE     = 0;
const float CFDEAGLE_SEQ_SHOOT1   = 1;
const float CFDEAGLE_SEQ_SHOOT2   = 2;
const float CFDEAGLE_SEQ_SHOOT3   = 3;
const float CFDEAGLE_SEQ_RELOAD   = 4;
const float CFDEAGLE_SEQ_DRAW     = 5;
const float CFDEAGLE_SEQ_DRAW2    = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 45 fps:
//   clipout at frame  9 / 45 = 0.200s
//   clipin  at frame 40 / 45 = 0.889s
//   bcback  at frame 53 / 45 = 1.178s
// Select sequence @ 30 fps:
//   reload1 at frame  2 / 30 = 0.067s
const float CFDEAGLE_RELOAD_CLIPOUT_TIME = 0.200;
const float CFDEAGLE_RELOAD_CLIPIN_TIME  = 0.889;
const float CFDEAGLE_RELOAD_BCBACK_TIME  = 1.178;
const float CFDEAGLE_DRAW_CLACK_TIME     = 0.067;

// Ammo applies once cylinder is closed (after bcback frame).
const float CFDEAGLE_RELOAD_APPLY_TIME   = 1.20;

// --- Gameplay tuning ---
const float CFDEAGLE_FIRE_DELAY        = 0.30;   // heavy single-shot revolver
const float CFDEAGLE_DRYFIRE_DELAY     = 0.20;
const float CFDEAGLE_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFDEAGLE           = 6;
const float MAX_AMMO_CFDEAGLE          = 36;

// --- Balance ---
// Big revolver — slightly higher damage than the Desert Eagle, but
// smaller mag and slower cyclic rate.  Tune to taste once in game.
const float CFDEAGLE_BASE_SPREAD          = 0.012;
const float CFDEAGLE_MOVE_SPREAD          = 0.07;
const float CFDEAGLE_FULL_SPREAD_SPEED    = 320;
const float CFDEAGLE_CLOSE_DAMAGE         = 42;
const float CFDEAGLE_MIN_DAMAGE           = 22;
const float CFDEAGLE_DAMAGE_FALLOFF_RANGE = 4096;
const float CFDEAGLE_KICK_PITCH    = 1.75;
const float CFDEAGLE_KICK_VARIANCE = 0.55;
const float CFDEAGLE_KICK_STRENGTH = 1.5;

// Muzzle attachment from v_deagle.mdl's $attachment 0:
//   $attachment 0 "Bone gun" 15.0 0.0 0.0
// Bone name DELIBERATELY contains a space — match it verbatim.
const string CFDEAGLE_MUZZLE_BONE   = "Bone gun";
#define CFDEAGLE_MUZZLE_OFFSET ('15.0 0.0 0.0')

const string CFDEAGLE_VIEWMODEL    = "models/weapons/wpn_cfdeagle/v_deagle.mdl";
const string CFDEAGLE_WORLDMODEL   = "models/weapons/wpn_cfdeagle/w_deagle.mdl";
const string CFDEAGLE_DEPLOY_SOUND = "";
const string CFDEAGLE_DISPLAY_NAME = "Colt Anaconda";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

float() SH_CFDeaglePickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFDEAGLE_SEQ_SHOOT1;
    if (r < 0.67) return CFDEAGLE_SEQ_SHOOT2;
    return CFDEAGLE_SEQ_SHOOT3;
};

float(float now) SH_CFDeagleTickState =
{
    return SH_StandardTickState(now, mag_cfdeagle, ammo_cfdeagle, MAX_MAG_CFDEAGLE,
        SH_SeqDuration(CFDEAGLE_VIEWMODEL, CFDEAGLE_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFDEAGLE_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFDEAGLE_VIEWMODEL, CFDEAGLE_SEQ_RELOAD, 1.5),
        CFDEAGLE_RELOAD_APPLY_TIME);
};

float(float now) SH_CFDeagleTryFire =
{
    // Semi-auto: must release +attack between shots (revolver trigger pull).
    return SH_StandardTryFireSemiAuto(now, mag_cfdeagle, CFDEAGLE_FIRE_DELAY, CFDEAGLE_DRYFIRE_DELAY);
};

float(float now) SH_CFDeagleTryReload =
{
    return SH_StandardTryReload(now, mag_cfdeagle, ammo_cfdeagle, MAX_MAG_CFDEAGLE,
        SH_SeqDuration(CFDEAGLE_VIEWMODEL, CFDEAGLE_SEQ_RELOAD, 1.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFDeaglePickupCopy =
{
    player.mag_cfdeagle  = self.mag_cfdeagle;
    player.ammo_cfdeagle = self.ammo_cfdeagle;
};

void() W_CFDeagleShoot =
{
    W_PenetratingHitscanShoot(CFDEAGLE_BASE_SPREAD, CFDEAGLE_MOVE_SPREAD, CFDEAGLE_FULL_SPREAD_SPEED,
        CFDEAGLE_CLOSE_DAMAGE, CFDEAGLE_MIN_DAMAGE, CFDEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CFDEAGLE_KICK_PITCH, CFDEAGLE_KICK_VARIANCE, CFDEAGLE_KICK_STRENGTH);
};

void() W_CFDeagleFire =
{
    float r = SH_CFDeagleTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFDeaglePickShootSeq();
        self.wep_nextframe = time + CFDEAGLE_FRAME_INTERVAL;

        W_CFDeagleShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfdeagle/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFDeagleReload =
{
    if (SH_CFDeagleTryReload(time))
    {
        self.weaponframe   = CFDEAGLE_SEQ_RELOAD;
        self.wep_nextframe = time + CFDEAGLE_FRAME_INTERVAL;
        self.cfdeagle_reload_snd_stage = 0;
    }
};

void() W_CFDeagleFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFDEAGLE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFDEAGLE_DRAW_CLACK_TIME && !self.cfdeagle_draw_snd_played)
        {
            // Always use reload1.wav for the select-sequence sound.
            // Original design alternated reload1/reload2 across equips
            // but the server's weaponframe (set by W_StandardEquipSetup
            // to CFDEAGLE_SEQ_DRAW) diverged from CSQC's DisplayFrame
            // when the alt latch was set, so both animations rendered
            // simultaneously.  Settling on one sequence eliminates the
            // desync; alt animations can come back if the latch is
            // replicated through the prediction proxy.
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfdeagle/reload1.WAV", 1, ATTN_NORM);
            self.cfdeagle_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFDEAGLE_RELOAD_CLIPOUT_TIME && self.cfdeagle_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfdeagle/clipout.WAV", 1, ATTN_NORM);
            self.cfdeagle_reload_snd_stage = 1;
        }
        if (elapsed >= CFDEAGLE_RELOAD_CLIPIN_TIME && self.cfdeagle_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfdeagle/clipin.WAV", 1, ATTN_NORM);
            self.cfdeagle_reload_snd_stage = 2;
        }
        if (elapsed >= CFDEAGLE_RELOAD_BCBACK_TIME && self.cfdeagle_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfdeagle/bcback.WAV", 1, ATTN_NORM);
            self.cfdeagle_reload_snd_stage = 3;
        }
    }

    result = SH_CFDeagleTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFDEAGLE_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfdeagle_reload_snd_stage = 0;
    }
};

void() W_CFDeagleEquip =
{
    W_StandardEquipSetup(CFDEAGLE_VIEWMODEL, CFDEAGLE_DISPLAY_NAME, CFDEAGLE_SEQ_DRAW,
        CFDEAGLE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFDeagleFire;
    self.reload   = W_CFDeagleReload;
    self.wepframe = W_CFDeagleFrame;
    self.shoot    = W_CFDeagleShoot;
    self.cfdeagle_draw_snd_played  = 0;
    self.cfdeagle_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFDEAGLE_BASE_SPREAD, CFDEAGLE_MOVE_SPREAD, CFDEAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFDeagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfdeagle  = self.mag_cfdeagle;
    tgt.ammo_cfdeagle = self.ammo_cfdeagle;

    self.mag_cfdeagle  = 0;
    self.ammo_cfdeagle = 0;

    setmodel(tgt, CFDEAGLE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfdeagle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFDEAGLE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFDeagleEquip;
    tgt.weap_drop_func = W_CFDeagleDrop;
    tgt.pickupcopy   = W_CFDeaglePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfdeagle =
{
    setmodel(self, CFDEAGLE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfdeagle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFDEAGLE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFDeagleEquip;
    self.weap_drop_func = W_CFDeagleDrop;
    self.pickupcopy    = W_CFDeaglePickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfdeagle  = MAX_MAG_CFDEAGLE;
    self.ammo_cfdeagle = MAX_AMMO_CFDEAGLE;
    W_RegisterMapWeapon(weapon_cfdeagle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfdeagle_draw_snd_played;
float csqc_cfdeagle_reload_snd_stage;
float csqc_cfdeagle_snd_action;

void() CSQC_PredictCFDeagleCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfdeagle_snd_action)
    {
        csqc_cfdeagle_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfdeagle_draw_snd_played  = 0;
        csqc_cfdeagle_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFDeagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfdeagle/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFDEAGLE_BASE_SPREAD, CFDEAGLE_MOVE_SPREAD, CFDEAGLE_FULL_SPREAD_SPEED,
                    CFDEAGLE_CLOSE_DAMAGE, CFDEAGLE_MIN_DAMAGE, CFDEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CFDEAGLE_KICK_PITCH, CFDEAGLE_KICK_VARIANCE, CFDEAGLE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFDEAGLE_MUZZLE_BONE, CFDEAGLE_MUZZLE_OFFSET);
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
            if (!csqc_cfdeagle_draw_snd_played && elapsed >= CFDEAGLE_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfdeagle/reload1.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfdeagle_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfdeagle_reload_snd_stage < 1 && elapsed >= CFDEAGLE_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfdeagle/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfdeagle_reload_snd_stage = 1;
            }
            if (csqc_cfdeagle_reload_snd_stage < 2 && elapsed >= CFDEAGLE_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfdeagle/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfdeagle_reload_snd_stage = 2;
            }
            if (csqc_cfdeagle_reload_snd_stage < 3 && elapsed >= CFDEAGLE_RELOAD_BCBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfdeagle/bcback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfdeagle_reload_snd_stage = 3;
            }
        }
    }

    SH_CFDeagleTickState(csqc_pred_time);
};

void() CSQC_PredictCFDeagleReload =
{
    if (SH_CFDeagleTryReload(csqc_pred_time))
    {
        csqc_cfdeagle_reload_snd_stage = 0;
        csqc_cfdeagle_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFDeagleDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFDEAGLE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFDEAGLE_SEQ_SHOOT1;
        if (r < 0.67) return CFDEAGLE_SEQ_SHOOT2;
        return CFDEAGLE_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFDEAGLE_SEQ_RELOAD;

    return CFDEAGLE_SEQ_IDLE;
};

void() CSQC_CFDeagleDropClear =
{
    self.mag_cfdeagle  = 0;
    self.ammo_cfdeagle = 0;
};

void() CSQC_CFDeagleEquip =
{
    self.weapon_name         = CFDEAGLE_DISPLAY_NAME;
    self.weapon_viewmodel    = CFDEAGLE_VIEWMODEL;
    self.weapon_worldmodel   = CFDEAGLE_WORLDMODEL;
    self.weapon_deploy_sound = CFDEAGLE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFDeagleCommand;
    self.csqc_predict_reload = CSQC_PredictCFDeagleReload;
    self.csqc_display_frame  = CSQC_CFDeagleDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFDeagleDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFDEAGLE_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFDEAGLE_MUZZLE_OFFSET;

    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfdeagle_draw_snd_played = 1;
        csqc_cfdeagle_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
