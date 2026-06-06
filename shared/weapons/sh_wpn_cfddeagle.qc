// ============================================================
//  shared/weapons/sh_wpn_cfddeagle.qc  -  Dual Desert Deagle (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 30-round SHARED magazine, 90 reserve, semi-auto alternating
//          dual .50 AE pistols (CS 1.6 Elites style — both pistols
//          draw from a single mag pool, not split 15/15).
//  Fire  : lag-compensated penetrating hitscan, deagle damage profile.
//          Semi-auto edge gate (must release +attack between shots).
//          Each successful fire alternates barrel side: action_id odd
//          fires RIGHT, action_id even fires LEFT.  Shot #1 advances
//          wep_action_id to 1 (odd) inside SH_StandardTryFire, so the
//          first shot of a fresh clip is RIGHT.
//
//  Sequence-driven GoldSrc viewmodel (v_elite.mdl).  Same prediction
//  shape as cfm9 / cfrevolver / hdak47: setting self.weaponframe
//  = N plays sequence N as a whole and the engine animates it.
//  W_CFDdeagleFrame ticks the state machine and emits timed sound
//  events; it never per-tick frame-steps.
//
//  Sequence layout (from v_elite.mdl source .qc):
//      0  idle_0    30 fps
//      1  idle_0    30 fps  (duplicate)
//      2  prefire   50 fps  (RIGHT shoot variant A — event 5011 "21")
//      3  prefire   50 fps  (RIGHT shoot variant B)
//      4  prefire   50 fps  (RIGHT shoot variant C)
//      5  prefire   50 fps  (RIGHT shoot variant D)
//      6  prefire   50 fps  (RIGHT shoot variant E)
//      7  prefire   50 fps  (RIGHT shoot variant F)
//      8  prefire_L 50 fps  (LEFT  shoot variant A — event 5001 "21")
//      9  prefire_L 50 fps  (LEFT  shoot variant B)
//     10  prefire_L 50 fps  (LEFT  shoot variant C)
//     11  prefire_L 50 fps  (LEFT  shoot variant D)
//     12  prefire_L 50 fps  (LEFT  shoot variant E)
//     13  prefire_L 50 fps  (LEFT  shoot variant F)
//     14  reload    25 fps  (clipout@20, clipin@56, clipin@73, reload@92)
//     15  select    30 fps  (event @ frame 2 → select.WAV)
//
//  Two clipIn events are present in the source animation — the user
//  inserts the left mag first, then the right.  Both fire the same
//  clipin.WAV (sole file in the asset dir), but we emit it TWICE so
//  the player audibly hears each mag seat.  The fourth event ("reload"
//  at frame 92, both bolts return) is the bolt-back / racking cue.
//  Four distinct timed events → 5-stage reload tracker (0..4).
//
//  Side-select determinism: side = (wep_action_id & 1) ? RIGHT : LEFT.
//  The same parity formula is consumed by:
//    - server fire path        (W_CFDdeagleFire)
//    - CSQC predict-fire path  (CSQC_PredictCFDdeagleCommand)
//    - CSQC display-frame path (CSQC_CFDdeagleDisplayFrame)
//    - muzzle/tracer offset    (right-axis flip on top of cl_lefthand)
//  All four sites read self.wep_action_id (or predicted_player on
//  CSQC display) AFTER SH_StandardTryFire has incremented it, so the
//  rendered viewmodel sequence matches the barrel that "actually"
//  fired this shot.
//
//  Variant pick within a side: SH_SpreadHash(wep_action_id) * 6 → one
//  of 6 prefire variants on that side.  Base index is 2 (RIGHT) or 8
//  (LEFT), so seq = base + variant ∈ {2..7} or {8..13}.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields (SHARED 30-round pool — both pistols feed this) ---
.float mag_cfddeagle;
.float ammo_cfddeagle;

// --- Per-entity sound stage trackers (server side) ---
// TWO separate fields — never collapsed (see HDAK47 reload-bug fix).
.float cfddeagle_draw_snd_played;
.float cfddeagle_reload_snd_stage;

// --- Sequence indices ---
const float CFDDEAGLE_SEQ_IDLE          = 0;
const float CFDDEAGLE_SEQ_SHOOT_R_BASE  = 2;   // seqs 2..7  — RIGHT barrel
const float CFDDEAGLE_SEQ_SHOOT_L_BASE  = 8;   // seqs 8..13 — LEFT  barrel
const float CFDDEAGLE_SEQ_VARIANT_COUNT = 6;
const float CFDDEAGLE_SEQ_RELOAD        = 14;
const float CFDDEAGLE_SEQ_SELECT        = 15;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 25 fps:
//   clipout    at frame 20 / 25 = 0.800s   (mag drops)
//   clipin (L) at frame 56 / 25 = 2.240s   (left mag inserted)
//   clipin (R) at frame 73 / 25 = 2.920s   (right mag inserted)
//   reload     at frame 92 / 25 = 3.680s   (both bolts return)
// Select sequence @ 30 fps:
//   select     at frame  2 / 30 = 0.067s   (draw clack)
const float CFDDEAGLE_RELOAD_CLIPOUT_TIME  = 0.800;
const float CFDDEAGLE_RELOAD_CLIPIN_L_TIME = 2.240;
const float CFDDEAGLE_RELOAD_CLIPIN_R_TIME = 2.920;
const float CFDDEAGLE_RELOAD_BOLT_TIME     = 3.680;
const float CFDDEAGLE_DRAW_CLACK_TIME      = 0.067;

// Ammo applies right after the second clipin (right mag seated).
const float CFDDEAGLE_RELOAD_APPLY_TIME    = 2.95;

// --- Gameplay tuning ---
// Alternating fire rate.  CS 1.6 Elites cycle ~0.0625 s between shots
// (16 Hz).  We pace at 0.060 s here so rapid trigger-clicks all
// register — the semi-auto edge gate still requires re-press between
// shots, so this delay is just the lower bound on tap rate.
const float CFDDEAGLE_FIRE_DELAY        = 0.060;
const float CFDDEAGLE_DRYFIRE_DELAY     = 0.20;
const float CFDDEAGLE_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFDDEAGLE           = 30;
const float MAX_AMMO_CFDDEAGLE          = 90;

// --- Balance --- (matches Desert Eagle damage profile per design)
const float CFDDEAGLE_BASE_SPREAD          = 0.012;
const float CFDDEAGLE_MOVE_SPREAD          = 0.07;
const float CFDDEAGLE_FULL_SPREAD_SPEED    = 320;
const float CFDDEAGLE_CLOSE_DAMAGE         = 35;
const float CFDDEAGLE_MIN_DAMAGE           = 18;
const float CFDDEAGLE_DAMAGE_FALLOFF_RANGE = 4096;
const float CFDDEAGLE_KICK_PITCH    = 1.4;
const float CFDDEAGLE_KICK_VARIANCE = 0.5;
const float CFDDEAGLE_KICK_STRENGTH = 1.2;

// Muzzle attachments from v_elite.mdl — TWO bones, one per barrel:
//   $attachment 0 "Bone11" 10.5 0.0 -0.5  (right barrel)
//   $attachment 1 "Bone01" 10.5 0.0  0.5  (left  barrel)
// The fire path picks bone+offset based on wep_action_id parity (the
// same parity that picks the prefire / prefire_L sequence) so the
// flash spawns from the firing barrel.
const string CFDDEAGLE_MUZZLE_BONE_RIGHT  = "Bone11";
#define CFDDEAGLE_MUZZLE_OFFSET_RIGHT     ('10.5 0.0 -0.5')
const string CFDDEAGLE_MUZZLE_BONE_LEFT   = "Bone01";
#define CFDDEAGLE_MUZZLE_OFFSET_LEFT      ('10.5 0.0  0.5')

const string CFDDEAGLE_VIEWMODEL    = "models/weapons/wpn_cfddeagle/v_ddeagle.mdl";
const string CFDDEAGLE_WORLDMODEL   = "models/weapons/wpn_cfddeagle/w_ddeagle.mdl";
const string CFDDEAGLE_DEPLOY_SOUND = "";
const string CFDDEAGLE_DISPLAY_NAME = "Dual Desert Deagle";

// ============================================================
//  SHARED — side / variant / sequence pick helpers
// ============================================================

// Parity: action_id odd  → RIGHT (base 2)
//         action_id even → LEFT  (base 8)
// Shot 1 sees wep_action_id == 1 after SH_StandardTryFire's increment,
// so the first shot of a fresh clip fires RIGHT — per design.
//
// Returns the base sequence index for this shot's side.
float(float action_id) SH_CFDdeagleSideBase =
{
    if (action_id & 1)
        return CFDDEAGLE_SEQ_SHOOT_R_BASE;
    return CFDDEAGLE_SEQ_SHOOT_L_BASE;
};

// Deterministic 0..5 variant pick from the same action_id so client
// and server agree which of the six per-side prefire variants plays.
float(float action_id) SH_CFDdeagleVariantIndex =
{
    float v = floor(SH_SpreadHash(action_id) * CFDDEAGLE_SEQ_VARIANT_COUNT);
    if (v < 0)                              v = 0;
    if (v >= CFDDEAGLE_SEQ_VARIANT_COUNT)     v = CFDDEAGLE_SEQ_VARIANT_COUNT - 1;
    return v;
};

// Final sequence index for the current shot.  base + variant ∈
// {2..7} (RIGHT) or {8..13} (LEFT).
float(float action_id) SH_CFDdeaglePickShootSeq =
{
    return SH_CFDdeagleSideBase(action_id) + SH_CFDdeagleVariantIndex(action_id);
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CFDdeagleTickState =
{
    return SH_StandardTickState(now, mag_cfddeagle, ammo_cfddeagle, MAX_MAG_CFDDEAGLE,
        SH_SeqDuration(CFDDEAGLE_VIEWMODEL, CFDDEAGLE_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFDDEAGLE_VIEWMODEL, self.weaponframe,   0.3),
        SH_SeqDuration(CFDDEAGLE_VIEWMODEL, CFDDEAGLE_SEQ_RELOAD, 3.7),
        CFDDEAGLE_RELOAD_APPLY_TIME);
};

float(float now) SH_CFDdeagleTryFire =
{
    // Semi-auto: must release +attack between shots.  Each successful
    // fire increments wep_action_id, which flips the side parity for
    // the next shot — alternating barrel behaviour falls out for free.
    return SH_StandardTryFireSemiAuto(now, mag_cfddeagle, CFDDEAGLE_FIRE_DELAY, CFDDEAGLE_DRYFIRE_DELAY);
};

float(float now) SH_CFDdeagleTryReload =
{
    return SH_StandardTryReload(now, mag_cfddeagle, ammo_cfddeagle, MAX_MAG_CFDDEAGLE,
        SH_SeqDuration(CFDDEAGLE_VIEWMODEL, CFDDEAGLE_SEQ_RELOAD, 3.7));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFDdeaglePickupCopy =
{
    player.mag_cfddeagle  = self.mag_cfddeagle;
    player.ammo_cfddeagle = self.ammo_cfddeagle;
};

void() W_CFDdeagleShoot =
{
    W_PenetratingHitscanShoot(CFDDEAGLE_BASE_SPREAD, CFDDEAGLE_MOVE_SPREAD, CFDDEAGLE_FULL_SPREAD_SPEED,
        CFDDEAGLE_CLOSE_DAMAGE, CFDDEAGLE_MIN_DAMAGE, CFDDEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CFDDEAGLE_KICK_PITCH, CFDDEAGLE_KICK_VARIANCE, CFDDEAGLE_KICK_STRENGTH);
};

void() W_CFDdeagleFire =
{
    float r = SH_CFDdeagleTryFire(time);

    if (r == 1)
    {
        // wep_action_id has just been incremented inside the helper —
        // the new parity tells us which side fired this shot.
        self.weaponframe   = SH_CFDdeaglePickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + CFDDEAGLE_FRAME_INTERVAL;

        W_CFDdeagleShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfddeagle/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFDdeagleReload =
{
    if (SH_CFDdeagleTryReload(time))
    {
        self.weaponframe   = CFDDEAGLE_SEQ_RELOAD;
        self.wep_nextframe = time + CFDDEAGLE_FRAME_INTERVAL;
        self.cfddeagle_reload_snd_stage = 0;
    }
};

void() W_CFDdeagleFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFDDEAGLE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFDDEAGLE_DRAW_CLACK_TIME && !self.cfddeagle_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfddeagle/select.WAV", 1, ATTN_NORM);
            self.cfddeagle_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFDDEAGLE_RELOAD_CLIPOUT_TIME && self.cfddeagle_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfddeagle/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.cfddeagle_reload_snd_stage = 1;
        }
        if (elapsed >= CFDDEAGLE_RELOAD_CLIPIN_L_TIME && self.cfddeagle_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfddeagle/clipin.WAV", 1, ATTN_NORM);
            self.cfddeagle_reload_snd_stage = 2;
        }
        if (elapsed >= CFDDEAGLE_RELOAD_CLIPIN_R_TIME && self.cfddeagle_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfddeagle/clipin.WAV", 1, ATTN_NORM);
            self.cfddeagle_reload_snd_stage = 3;
        }
        if (elapsed >= CFDDEAGLE_RELOAD_BOLT_TIME && self.cfddeagle_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfddeagle/reload.WAV", 1, ATTN_NORM);
            self.cfddeagle_reload_snd_stage = 4;
        }
    }

    result = SH_CFDdeagleTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFDDEAGLE_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfddeagle_reload_snd_stage = 0;
    }
};

void() W_CFDdeagleEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_ddeagle", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFDDEAGLE_VIEWMODEL, CFDDEAGLE_DISPLAY_NAME, CFDDEAGLE_SEQ_SELECT,
        CFDDEAGLE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFDdeagleFire;
    self.reload   = W_CFDdeagleReload;
    self.wepframe = W_CFDdeagleFrame;
    self.shoot    = W_CFDdeagleShoot;
    self.cfddeagle_draw_snd_played  = 0;
    self.cfddeagle_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFDDEAGLE_BASE_SPREAD, CFDDEAGLE_MOVE_SPREAD, CFDDEAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFDdeagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfddeagle  = self.mag_cfddeagle;
    tgt.ammo_cfddeagle = self.ammo_cfddeagle;

    self.mag_cfddeagle  = 0;
    self.ammo_cfddeagle = 0;

    setmodel(tgt, CFDDEAGLE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfddeagle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFDDEAGLE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFDdeagleEquip;
    tgt.weap_drop_func = W_CFDdeagleDrop;
    tgt.pickupcopy   = W_CFDdeaglePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfddeagle =
{
    setmodel(self, CFDDEAGLE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfddeagle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFDDEAGLE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFDdeagleEquip;
    self.weap_drop_func = W_CFDdeagleDrop;
    self.pickupcopy    = W_CFDdeaglePickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfddeagle   = MAX_MAG_CFDDEAGLE;
    self.ammo_cfddeagle  = MAX_AMMO_CFDDEAGLE;
    W_RegisterMapWeapon(weapon_cfddeagle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfddeagle_draw_snd_played;
float csqc_cfddeagle_reload_snd_stage;
float csqc_cfddeagle_snd_action;

void() CSQC_PredictCFDdeagleCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires
    // its events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfddeagle_snd_action)
    {
        csqc_cfddeagle_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfddeagle_draw_snd_played  = 0;
        csqc_cfddeagle_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFDdeagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfddeagle/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFDDEAGLE_BASE_SPREAD, CFDDEAGLE_MOVE_SPREAD, CFDDEAGLE_FULL_SPREAD_SPEED,
                    CFDDEAGLE_CLOSE_DAMAGE, CFDDEAGLE_MIN_DAMAGE, CFDDEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CFDDEAGLE_KICK_PITCH, CFDDEAGLE_KICK_VARIANCE, CFDDEAGLE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');

                // Side parity AFTER the increment inside SH_StandardTryFire.
                //   action_id odd  → RIGHT barrel → Bone11 attachment
                //   action_id even → LEFT  barrel → Bone01 attachment
                // Picks the bone+offset pair matching the firing barrel
                // so the flash anchors to the actual muzzle in the
                // animation regardless of cl_lefthand handedness.
                vector muzzle_world;
                if (self.wep_action_id & 1)
                    muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                        CFDDEAGLE_MUZZLE_BONE_RIGHT, CFDDEAGLE_MUZZLE_OFFSET_RIGHT);
                else
                    muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                        CFDDEAGLE_MUZZLE_BONE_LEFT, CFDDEAGLE_MUZZLE_OFFSET_LEFT);

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

    // Predicted draw / reload sounds — match the server's W_CFDdeagleFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfddeagle_draw_snd_played && elapsed >= CFDDEAGLE_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfddeagle/select.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfddeagle_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfddeagle_reload_snd_stage < 1 && elapsed >= CFDDEAGLE_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfddeagle/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfddeagle_reload_snd_stage = 1;
            }
            if (csqc_cfddeagle_reload_snd_stage < 2 && elapsed >= CFDDEAGLE_RELOAD_CLIPIN_L_TIME)
            {
                localsound("sounds/weapons/wpn_cfddeagle/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfddeagle_reload_snd_stage = 2;
            }
            if (csqc_cfddeagle_reload_snd_stage < 3 && elapsed >= CFDDEAGLE_RELOAD_CLIPIN_R_TIME)
            {
                localsound("sounds/weapons/wpn_cfddeagle/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfddeagle_reload_snd_stage = 3;
            }
            if (csqc_cfddeagle_reload_snd_stage < 4 && elapsed >= CFDDEAGLE_RELOAD_BOLT_TIME)
            {
                localsound("sounds/weapons/wpn_cfddeagle/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfddeagle_reload_snd_stage = 4;
            }
        }
    }

    SH_CFDdeagleTickState(csqc_pred_time);
};

void() CSQC_PredictCFDdeagleReload =
{
    if (SH_CFDdeagleTryReload(csqc_pred_time))
    {
        csqc_cfddeagle_reload_snd_stage = 0;
        csqc_cfddeagle_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFDdeagleDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return CFDDEAGLE_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFDDEAGLE_SEQ_RELOAD;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Same parity + variant math as the fire path so the rendered
        // viewmodel sequence matches the barrel that actually fired.
        return SH_CFDdeaglePickShootSeq(predicted_player.wep_action_id);
    }

    return CFDDEAGLE_SEQ_IDLE;
};

void() CSQC_CFDdeagleDropClear =
{
    self.mag_cfddeagle  = 0;
    self.ammo_cfddeagle = 0;
};

void() CSQC_CFDdeagleEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_ddeagle", SCOPE_CLASS_NONE);
    self.weapon_name         = CFDDEAGLE_DISPLAY_NAME;
    self.weapon_viewmodel    = CFDDEAGLE_VIEWMODEL;
    self.weapon_worldmodel   = CFDDEAGLE_WORLDMODEL;
    self.weapon_deploy_sound = CFDDEAGLE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFDdeagleCommand;
    self.csqc_predict_reload = CSQC_PredictCFDdeagleReload;
    self.csqc_display_frame  = CSQC_CFDdeagleDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFDdeagleDropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot anchor — use the RIGHT-barrel bone (Bone11) since the
    // sway visual just needs a stable rotation centre; the per-shot
    // bone pick still happens in the fire path.
    self.weapon_muzzle_bone   = CFDDEAGLE_MUZZLE_BONE_RIGHT;
    self.weapon_muzzle_offset = CFDDEAGLE_MUZZLE_OFFSET_RIGHT;

    // Snapshot-driven equip suppress for the draw clack — same shape
    // as cfm9 / cfrevolver.  Does NOT stomp the stage tracker
    // when mid-DRAW / mid-RELOAD / mid-FIRE so reconcile-replay can
    // continue to emit predicted events (avoids the HDAK47 collapsed-
    // tracker reload bug).
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfddeagle_draw_snd_played = 1;
        csqc_cfddeagle_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
