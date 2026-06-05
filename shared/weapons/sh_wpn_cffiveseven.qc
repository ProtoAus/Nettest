// ============================================================
//  shared/weapons/sh_wpn_cffiveseven.qc  -  Beretta M9 (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 15-round magazine, 90 reserve, semi-auto 9mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_fiveseven.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CSUSP.
//
//  Sequence layout (from v_fiveseven.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   50 fps  (shoot variant A — event 5001 fire)
//      2  prefire   50 fps  (shoot variant B)
//      3  prefire   50 fps  (shoot variant C)
//      4  reload    24 fps  (bback@1, clipout@10, clipin@34, bcback@51)
//      5  select    30 fps  (draw — reload.wav at frame 1)
//
//  Note: the source folder names diverge — model is at
//  models/weapons/wpn_cffiveseven/ but sounds are at
//  sounds/weapons/wpn_fiveseven/ (no "cf" prefix).  Both paths are
//  used verbatim below; do NOT "normalise" them.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable like the original HDAK47).  This is the
//  CSUSP / CSAK47 pattern — see the HDAK47 reload-sound bug fix
//  commit for why the single-variable approach corrupts state under
//  the every-reconcile CSQC_WeaponEquip call.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cffiveseven;
.float ammo_cffiveseven;

// --- Per-entity sound stage trackers (server side) ---
.float cffiveseven_draw_snd_played;
.float cffiveseven_reload_snd_stage;

// --- Sequence indices ---
const float CFFIVESEVEN_SEQ_IDLE    = 0;
const float CFFIVESEVEN_SEQ_SHOOT1  = 1;
const float CFFIVESEVEN_SEQ_SHOOT2  = 2;
const float CFFIVESEVEN_SEQ_SHOOT3  = 3;
const float CFFIVESEVEN_SEQ_RELOAD  = 4;
const float CFFIVESEVEN_SEQ_DRAW    = 5;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 24 fps:
//   bback   at frame  1 / 24 = 0.042s   — initial bolt back
//   clipout at frame 10 / 24 = 0.417s   — mag drops out
//   clipin  at frame 34 / 24 = 1.417s   — fresh mag in
//   bcback  at frame 51 / 24 = 2.125s   — slide forward (chamber)
// Select sequence @ 30 fps:
//   reload  at frame  1 / 30 = 0.033s   — draw clack
const float CFFIVESEVEN_RELOAD_BBACK_TIME    = 0.042;
const float CFFIVESEVEN_RELOAD_CLIPOUT_TIME  = 0.417;
const float CFFIVESEVEN_RELOAD_CLIPIN_TIME   = 1.417;
const float CFFIVESEVEN_RELOAD_BCBACK_TIME   = 2.125;
const float CFFIVESEVEN_DRAW_CLACK_TIME      = 0.033;

// Ammo applies right after clipin lands (mag visually seated).
const float CFFIVESEVEN_RELOAD_APPLY_TIME    = 1.42;

// --- Gameplay tuning ---
const float CFFIVESEVEN_FIRE_DELAY        = 0.075;   // semi-auto, fast tap rate
const float CFFIVESEVEN_DRYFIRE_DELAY     = 0.20;
const float CFFIVESEVEN_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFFIVESEVEN           = 15;
const float MAX_AMMO_CFFIVESEVEN          = 90;

// --- Balance ---
const float CFFIVESEVEN_BASE_SPREAD          = 0.012;
const float CFFIVESEVEN_MOVE_SPREAD          = 0.06;
const float CFFIVESEVEN_FULL_SPREAD_SPEED    = 320;
const float CFFIVESEVEN_CLOSE_DAMAGE         = 24;
const float CFFIVESEVEN_MIN_DAMAGE           = 11;
const float CFFIVESEVEN_DAMAGE_FALLOFF_RANGE = 2048;
const float CFFIVESEVEN_KICK_PITCH    = 0.55;
const float CFFIVESEVEN_KICK_VARIANCE = 0.35;
const float CFFIVESEVEN_KICK_STRENGTH = 0.7;

// Muzzle attachment from v_fiveseven.mdl's $attachment 0:
//   $attachment 0 "Bone05" 9.3 0.0 0.0
const string CFFIVESEVEN_MUZZLE_BONE   = "Bone05";
#define CFFIVESEVEN_MUZZLE_OFFSET ('9.3 0.0 0.0')

const string CFFIVESEVEN_VIEWMODEL    = "models/weapons/wpn_cffiveseven/v_fiveseven.mdl";
const string CFFIVESEVEN_WORLDMODEL   = "models/weapons/wpn_cffiveseven/w_fiveseven.mdl";
const string CFFIVESEVEN_DEPLOY_SOUND = "";
const string CFFIVESEVEN_DISPLAY_NAME = "Beretta M9";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFFiveSevenPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFFIVESEVEN_SEQ_SHOOT1;
    if (r < 0.67) return CFFIVESEVEN_SEQ_SHOOT2;
    return CFFIVESEVEN_SEQ_SHOOT3;
};

float(float now) SH_CFFiveSevenTickState =
{
    return SH_StandardTickState(now, mag_cffiveseven, ammo_cffiveseven, MAX_MAG_CFFIVESEVEN,
        SH_SeqDuration(CFFIVESEVEN_VIEWMODEL, CFFIVESEVEN_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFFIVESEVEN_VIEWMODEL, self.weaponframe,        0.3),
        SH_SeqDuration(CFFIVESEVEN_VIEWMODEL, CFFIVESEVEN_SEQ_RELOAD, 2.5),
        CFFIVESEVEN_RELOAD_APPLY_TIME);
};

float(float now) SH_CFFiveSevenTryFire =
{
    // Semi-auto: must release +attack between shots.
    return SH_StandardTryFireSemiAuto(now, mag_cffiveseven, CFFIVESEVEN_FIRE_DELAY, CFFIVESEVEN_DRYFIRE_DELAY);
};

float(float now) SH_CFFiveSevenTryReload =
{
    return SH_StandardTryReload(now, mag_cffiveseven, ammo_cffiveseven, MAX_MAG_CFFIVESEVEN,
        SH_SeqDuration(CFFIVESEVEN_VIEWMODEL, CFFIVESEVEN_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFFiveSevenPickupCopy =
{
    player.mag_cffiveseven  = self.mag_cffiveseven;
    player.ammo_cffiveseven = self.ammo_cffiveseven;
};

void() W_CFFiveSevenShoot =
{
    W_PenetratingHitscanShoot(CFFIVESEVEN_BASE_SPREAD, CFFIVESEVEN_MOVE_SPREAD, CFFIVESEVEN_FULL_SPREAD_SPEED,
        CFFIVESEVEN_CLOSE_DAMAGE, CFFIVESEVEN_MIN_DAMAGE, CFFIVESEVEN_DAMAGE_FALLOFF_RANGE, 24, 0.94,
        CFFIVESEVEN_KICK_PITCH, CFFIVESEVEN_KICK_VARIANCE, CFFIVESEVEN_KICK_STRENGTH);
};

void() W_CFFiveSevenFire =
{
    float r = SH_CFFiveSevenTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFFiveSevenPickShootSeq();
        self.wep_nextframe = time + CFFIVESEVEN_FRAME_INTERVAL;

        W_CFFiveSevenShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_fiveseven/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFFiveSevenReload =
{
    if (SH_CFFiveSevenTryReload(time))
    {
        self.weaponframe   = CFFIVESEVEN_SEQ_RELOAD;
        self.wep_nextframe = time + CFFIVESEVEN_FRAME_INTERVAL;
        self.cffiveseven_reload_snd_stage = 0;
    }
};

void() W_CFFiveSevenFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFFIVESEVEN_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFFIVESEVEN_DRAW_CLACK_TIME && !self.cffiveseven_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_fiveseven/reload.WAV", 1, ATTN_NORM);
            self.cffiveseven_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFFIVESEVEN_RELOAD_BBACK_TIME && self.cffiveseven_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_fiveseven/bback.WAV", 1, ATTN_NORM);
            self.cffiveseven_reload_snd_stage = 1;
        }
        if (elapsed >= CFFIVESEVEN_RELOAD_CLIPOUT_TIME && self.cffiveseven_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_fiveseven/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.cffiveseven_reload_snd_stage = 2;
        }
        if (elapsed >= CFFIVESEVEN_RELOAD_CLIPIN_TIME && self.cffiveseven_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_fiveseven/clipin.WAV", 1, ATTN_NORM);
            self.cffiveseven_reload_snd_stage = 3;
        }
        if (elapsed >= CFFIVESEVEN_RELOAD_BCBACK_TIME && self.cffiveseven_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_fiveseven/bcback.WAV", 1, ATTN_NORM);
            self.cffiveseven_reload_snd_stage = 4;
        }
    }

    result = SH_CFFiveSevenTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFFIVESEVEN_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cffiveseven_reload_snd_stage = 0;
    }
};

void() W_CFFiveSevenEquip =
{
    W_StandardEquipSetup(CFFIVESEVEN_VIEWMODEL, CFFIVESEVEN_DISPLAY_NAME, CFFIVESEVEN_SEQ_DRAW,
        CFFIVESEVEN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFFiveSevenFire;
    self.reload   = W_CFFiveSevenReload;
    self.wepframe = W_CFFiveSevenFrame;
    self.shoot    = W_CFFiveSevenShoot;
    self.cffiveseven_draw_snd_played  = 0;
    self.cffiveseven_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFFIVESEVEN_BASE_SPREAD, CFFIVESEVEN_MOVE_SPREAD, CFFIVESEVEN_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFFiveSevenDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cffiveseven  = self.mag_cffiveseven;
    tgt.ammo_cffiveseven = self.ammo_cffiveseven;

    self.mag_cffiveseven  = 0;
    self.ammo_cffiveseven = 0;

    setmodel(tgt, CFFIVESEVEN_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cffiveseven";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFFIVESEVEN;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFFiveSevenEquip;
    tgt.weap_drop_func = W_CFFiveSevenDrop;
    tgt.pickupcopy   = W_CFFiveSevenPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cffiveseven =
{
    setmodel(self, CFFIVESEVEN_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cffiveseven";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFFIVESEVEN;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFFiveSevenEquip;
    self.weap_drop_func = W_CFFiveSevenDrop;
    self.pickupcopy    = W_CFFiveSevenPickupCopy;
    self.touch         = weapon_touch;
    self.mag_cffiveseven  = MAX_MAG_CFFIVESEVEN;
    self.ammo_cffiveseven = MAX_AMMO_CFFIVESEVEN;
    W_RegisterMapWeapon(weapon_cffiveseven);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cffiveseven_draw_snd_played;
float csqc_cffiveseven_reload_snd_stage;
float csqc_cffiveseven_snd_action;

void() CSQC_PredictCFFiveSevenCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cffiveseven_snd_action)
    {
        csqc_cffiveseven_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cffiveseven_draw_snd_played  = 0;
        csqc_cffiveseven_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFFiveSevenTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_fiveseven/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFFIVESEVEN_BASE_SPREAD, CFFIVESEVEN_MOVE_SPREAD, CFFIVESEVEN_FULL_SPREAD_SPEED,
                    CFFIVESEVEN_CLOSE_DAMAGE, CFFIVESEVEN_MIN_DAMAGE, CFFIVESEVEN_DAMAGE_FALLOFF_RANGE, 24, 0.94,
                    CFFIVESEVEN_KICK_PITCH, CFFIVESEVEN_KICK_VARIANCE, CFFIVESEVEN_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFFIVESEVEN_MUZZLE_BONE, CFFIVESEVEN_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFFiveSevenFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cffiveseven_draw_snd_played && elapsed >= CFFIVESEVEN_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_fiveseven/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cffiveseven_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cffiveseven_reload_snd_stage < 1 && elapsed >= CFFIVESEVEN_RELOAD_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_fiveseven/bback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cffiveseven_reload_snd_stage = 1;
            }
            if (csqc_cffiveseven_reload_snd_stage < 2 && elapsed >= CFFIVESEVEN_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_fiveseven/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cffiveseven_reload_snd_stage = 2;
            }
            if (csqc_cffiveseven_reload_snd_stage < 3 && elapsed >= CFFIVESEVEN_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_fiveseven/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cffiveseven_reload_snd_stage = 3;
            }
            if (csqc_cffiveseven_reload_snd_stage < 4 && elapsed >= CFFIVESEVEN_RELOAD_BCBACK_TIME)
            {
                localsound("sounds/weapons/wpn_fiveseven/bcback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cffiveseven_reload_snd_stage = 4;
            }
        }
    }

    SH_CFFiveSevenTickState(csqc_pred_time);
};

void() CSQC_PredictCFFiveSevenReload =
{
    if (SH_CFFiveSevenTryReload(csqc_pred_time))
    {
        csqc_cffiveseven_reload_snd_stage = 0;
        csqc_cffiveseven_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFFiveSevenDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFFIVESEVEN_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFFIVESEVEN_SEQ_SHOOT1;
        if (r < 0.67) return CFFIVESEVEN_SEQ_SHOOT2;
        return CFFIVESEVEN_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFFIVESEVEN_SEQ_RELOAD;

    return CFFIVESEVEN_SEQ_IDLE;
};

void() CSQC_CFFiveSevenDropClear =
{
    self.mag_cffiveseven  = 0;
    self.ammo_cffiveseven = 0;
};

void() CSQC_CFFiveSevenEquip =
{
    self.weapon_name         = CFFIVESEVEN_DISPLAY_NAME;
    self.weapon_viewmodel    = CFFIVESEVEN_VIEWMODEL;
    self.weapon_worldmodel   = CFFIVESEVEN_WORLDMODEL;
    self.weapon_deploy_sound = CFFIVESEVEN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFFiveSevenCommand;
    self.csqc_predict_reload = CSQC_PredictCFFiveSevenReload;
    self.csqc_display_frame  = CSQC_CFFiveSevenDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFFiveSevenDropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFFIVESEVEN_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFFIVESEVEN_MUZZLE_OFFSET;

    // Snapshot-driven equip suppress for the draw-clack: weaponstate at
    // this point is WS_IDLE / WS_DEAD on a snapshot-driven draw
    // (cl_player.qc sets WS_DRAW AFTER Equip), so latching the
    // draw-snd-played flag here means the predict path skips the local
    // draw-clack and lets the server's CHAN_AUTO emission play through
    // unsuppressed.  Local-prediction draw (CSQC_PredictSelectWeapon
    // sets WS_DRAW BEFORE Equip) skips this branch — predicted draw
    // sound still fires.  Mid-RELOAD / mid-FIRE reconciles also skip
    // (avoiding the HDAK47 collapsed-tracker bug — see commit history).
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cffiveseven_draw_snd_played = 1;
        csqc_cffiveseven_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
