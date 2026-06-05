// ============================================================
//  shared/weapons/sh_wpn_cfelite.qc  -  Dual Desert Deagle (CF series)
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
//  shape as cffiveseven / cfdeagle / hdak47: setting self.weaponframe
//  = N plays sequence N as a whole and the engine animates it.
//  W_CFEliteFrame ticks the state machine and emits timed sound
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
//    - server fire path        (W_CFEliteFire)
//    - CSQC predict-fire path  (CSQC_PredictCFEliteCommand)
//    - CSQC display-frame path (CSQC_CFEliteDisplayFrame)
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
.float mag_cfelite;
.float ammo_cfelite;

// --- Per-entity sound stage trackers (server side) ---
// TWO separate fields — never collapsed (see HDAK47 reload-bug fix).
.float cfelite_draw_snd_played;
.float cfelite_reload_snd_stage;

// --- Sequence indices ---
const float CFELITE_SEQ_IDLE          = 0;
const float CFELITE_SEQ_SHOOT_R_BASE  = 2;   // seqs 2..7  — RIGHT barrel
const float CFELITE_SEQ_SHOOT_L_BASE  = 8;   // seqs 8..13 — LEFT  barrel
const float CFELITE_SEQ_VARIANT_COUNT = 6;
const float CFELITE_SEQ_RELOAD        = 14;
const float CFELITE_SEQ_SELECT        = 15;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 25 fps:
//   clipout    at frame 20 / 25 = 0.800s   (mag drops)
//   clipin (L) at frame 56 / 25 = 2.240s   (left mag inserted)
//   clipin (R) at frame 73 / 25 = 2.920s   (right mag inserted)
//   reload     at frame 92 / 25 = 3.680s   (both bolts return)
// Select sequence @ 30 fps:
//   select     at frame  2 / 30 = 0.067s   (draw clack)
const float CFELITE_RELOAD_CLIPOUT_TIME  = 0.800;
const float CFELITE_RELOAD_CLIPIN_L_TIME = 2.240;
const float CFELITE_RELOAD_CLIPIN_R_TIME = 2.920;
const float CFELITE_RELOAD_BOLT_TIME     = 3.680;
const float CFELITE_DRAW_CLACK_TIME      = 0.067;

// Ammo applies right after the second clipin (right mag seated).
const float CFELITE_RELOAD_APPLY_TIME    = 2.95;

// --- Gameplay tuning ---
// Alternating fire rate.  CS 1.6 Elites cycle ~0.0625 s between shots
// (16 Hz).  We pace at 0.060 s here so rapid trigger-clicks all
// register — the semi-auto edge gate still requires re-press between
// shots, so this delay is just the lower bound on tap rate.
const float CFELITE_FIRE_DELAY        = 0.060;
const float CFELITE_DRYFIRE_DELAY     = 0.20;
const float CFELITE_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFELITE           = 30;
const float MAX_AMMO_CFELITE          = 90;

// --- Balance --- (matches Desert Eagle damage profile per design)
const float CFELITE_BASE_SPREAD          = 0.012;
const float CFELITE_MOVE_SPREAD          = 0.07;
const float CFELITE_FULL_SPREAD_SPEED    = 320;
const float CFELITE_CLOSE_DAMAGE         = 35;
const float CFELITE_MIN_DAMAGE           = 18;
const float CFELITE_DAMAGE_FALLOFF_RANGE = 4096;
const float CFELITE_KICK_PITCH    = 1.4;
const float CFELITE_KICK_VARIANCE = 0.5;
const float CFELITE_KICK_STRENGTH = 1.2;

// Muzzle attachments from v_elite.mdl — TWO bones, one per barrel:
//   $attachment 0 "Bone11" 10.5 0.0 -0.5  (right barrel)
//   $attachment 1 "Bone01" 10.5 0.0  0.5  (left  barrel)
// The fire path picks bone+offset based on wep_action_id parity (the
// same parity that picks the prefire / prefire_L sequence) so the
// flash spawns from the firing barrel.
const string CFELITE_MUZZLE_BONE_RIGHT  = "Bone11";
#define CFELITE_MUZZLE_OFFSET_RIGHT     ('10.5 0.0 -0.5')
const string CFELITE_MUZZLE_BONE_LEFT   = "Bone01";
#define CFELITE_MUZZLE_OFFSET_LEFT      ('10.5 0.0  0.5')

const string CFELITE_VIEWMODEL    = "models/weapons/wpn_cfelite/v_elite.mdl";
const string CFELITE_WORLDMODEL   = "models/weapons/wpn_cfelite/w_elite.mdl";
const string CFELITE_DEPLOY_SOUND = "";
const string CFELITE_DISPLAY_NAME = "Dual Desert Deagle";

// ============================================================
//  SHARED — side / variant / sequence pick helpers
// ============================================================

// Parity: action_id odd  → RIGHT (base 2)
//         action_id even → LEFT  (base 8)
// Shot 1 sees wep_action_id == 1 after SH_StandardTryFire's increment,
// so the first shot of a fresh clip fires RIGHT — per design.
//
// Returns the base sequence index for this shot's side.
float(float action_id) SH_CFEliteSideBase =
{
    if (action_id & 1)
        return CFELITE_SEQ_SHOOT_R_BASE;
    return CFELITE_SEQ_SHOOT_L_BASE;
};

// Deterministic 0..5 variant pick from the same action_id so client
// and server agree which of the six per-side prefire variants plays.
float(float action_id) SH_CFEliteVariantIndex =
{
    float v = floor(SH_SpreadHash(action_id) * CFELITE_SEQ_VARIANT_COUNT);
    if (v < 0)                              v = 0;
    if (v >= CFELITE_SEQ_VARIANT_COUNT)     v = CFELITE_SEQ_VARIANT_COUNT - 1;
    return v;
};

// Final sequence index for the current shot.  base + variant ∈
// {2..7} (RIGHT) or {8..13} (LEFT).
float(float action_id) SH_CFElitePickShootSeq =
{
    return SH_CFEliteSideBase(action_id) + SH_CFEliteVariantIndex(action_id);
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CFEliteTickState =
{
    return SH_StandardTickState(now, mag_cfelite, ammo_cfelite, MAX_MAG_CFELITE,
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_SELECT, 1.0),
        SH_SeqDuration(CFELITE_VIEWMODEL, self.weaponframe,   0.3),
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_RELOAD, 3.7),
        CFELITE_RELOAD_APPLY_TIME);
};

float(float now) SH_CFEliteTryFire =
{
    // Semi-auto: must release +attack between shots.  Each successful
    // fire increments wep_action_id, which flips the side parity for
    // the next shot — alternating barrel behaviour falls out for free.
    return SH_StandardTryFireSemiAuto(now, mag_cfelite, CFELITE_FIRE_DELAY, CFELITE_DRYFIRE_DELAY);
};

float(float now) SH_CFEliteTryReload =
{
    return SH_StandardTryReload(now, mag_cfelite, ammo_cfelite, MAX_MAG_CFELITE,
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_RELOAD, 3.7));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFElitePickupCopy =
{
    player.mag_cfelite  = self.mag_cfelite;
    player.ammo_cfelite = self.ammo_cfelite;
};

void() W_CFEliteShoot =
{
    W_PenetratingHitscanShoot(CFELITE_BASE_SPREAD, CFELITE_MOVE_SPREAD, CFELITE_FULL_SPREAD_SPEED,
        CFELITE_CLOSE_DAMAGE, CFELITE_MIN_DAMAGE, CFELITE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CFELITE_KICK_PITCH, CFELITE_KICK_VARIANCE, CFELITE_KICK_STRENGTH);
};

void() W_CFEliteFire =
{
    float r = SH_CFEliteTryFire(time);

    if (r == 1)
    {
        // wep_action_id has just been incremented inside the helper —
        // the new parity tells us which side fired this shot.
        self.weaponframe   = SH_CFElitePickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + CFELITE_FRAME_INTERVAL;

        W_CFEliteShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfelite/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFEliteReload =
{
    if (SH_CFEliteTryReload(time))
    {
        self.weaponframe   = CFELITE_SEQ_RELOAD;
        self.wep_nextframe = time + CFELITE_FRAME_INTERVAL;
        self.cfelite_reload_snd_stage = 0;
    }
};

void() W_CFEliteFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFELITE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFELITE_DRAW_CLACK_TIME && !self.cfelite_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/select.WAV", 1, ATTN_NORM);
            self.cfelite_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFELITE_RELOAD_CLIPOUT_TIME && self.cfelite_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.cfelite_reload_snd_stage = 1;
        }
        if (elapsed >= CFELITE_RELOAD_CLIPIN_L_TIME && self.cfelite_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/clipin.WAV", 1, ATTN_NORM);
            self.cfelite_reload_snd_stage = 2;
        }
        if (elapsed >= CFELITE_RELOAD_CLIPIN_R_TIME && self.cfelite_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/clipin.WAV", 1, ATTN_NORM);
            self.cfelite_reload_snd_stage = 3;
        }
        if (elapsed >= CFELITE_RELOAD_BOLT_TIME && self.cfelite_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/reload.WAV", 1, ATTN_NORM);
            self.cfelite_reload_snd_stage = 4;
        }
    }

    result = SH_CFEliteTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFELITE_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfelite_reload_snd_stage = 0;
    }
};

void() W_CFEliteEquip =
{
    W_StandardEquipSetup(CFELITE_VIEWMODEL, CFELITE_DISPLAY_NAME, CFELITE_SEQ_SELECT,
        CFELITE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFEliteFire;
    self.reload   = W_CFEliteReload;
    self.wepframe = W_CFEliteFrame;
    self.shoot    = W_CFEliteShoot;
    self.cfelite_draw_snd_played  = 0;
    self.cfelite_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFELITE_BASE_SPREAD, CFELITE_MOVE_SPREAD, CFELITE_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFEliteDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfelite  = self.mag_cfelite;
    tgt.ammo_cfelite = self.ammo_cfelite;

    self.mag_cfelite  = 0;
    self.ammo_cfelite = 0;

    setmodel(tgt, CFELITE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfelite";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFELITE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFEliteEquip;
    tgt.weap_drop_func = W_CFEliteDrop;
    tgt.pickupcopy   = W_CFElitePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfelite =
{
    setmodel(self, CFELITE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfelite";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFELITE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFEliteEquip;
    self.weap_drop_func = W_CFEliteDrop;
    self.pickupcopy    = W_CFElitePickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfelite   = MAX_MAG_CFELITE;
    self.ammo_cfelite  = MAX_AMMO_CFELITE;
    W_RegisterMapWeapon(weapon_cfelite);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfelite_draw_snd_played;
float csqc_cfelite_reload_snd_stage;
float csqc_cfelite_snd_action;

void() CSQC_PredictCFEliteCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires
    // its events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfelite_snd_action)
    {
        csqc_cfelite_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfelite_draw_snd_played  = 0;
        csqc_cfelite_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFEliteTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfelite/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFELITE_BASE_SPREAD, CFELITE_MOVE_SPREAD, CFELITE_FULL_SPREAD_SPEED,
                    CFELITE_CLOSE_DAMAGE, CFELITE_MIN_DAMAGE, CFELITE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CFELITE_KICK_PITCH, CFELITE_KICK_VARIANCE, CFELITE_KICK_STRENGTH);
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
                        CFELITE_MUZZLE_BONE_RIGHT, CFELITE_MUZZLE_OFFSET_RIGHT);
                else
                    muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                        CFELITE_MUZZLE_BONE_LEFT, CFELITE_MUZZLE_OFFSET_LEFT);

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

    // Predicted draw / reload sounds — match the server's W_CFEliteFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfelite_draw_snd_played && elapsed >= CFELITE_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/select.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfelite_reload_snd_stage < 1 && elapsed >= CFELITE_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfelite_reload_snd_stage = 1;
            }
            if (csqc_cfelite_reload_snd_stage < 2 && elapsed >= CFELITE_RELOAD_CLIPIN_L_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_reload_snd_stage = 2;
            }
            if (csqc_cfelite_reload_snd_stage < 3 && elapsed >= CFELITE_RELOAD_CLIPIN_R_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_reload_snd_stage = 3;
            }
            if (csqc_cfelite_reload_snd_stage < 4 && elapsed >= CFELITE_RELOAD_BOLT_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_reload_snd_stage = 4;
            }
        }
    }

    SH_CFEliteTickState(csqc_pred_time);
};

void() CSQC_PredictCFEliteReload =
{
    if (SH_CFEliteTryReload(csqc_pred_time))
    {
        csqc_cfelite_reload_snd_stage = 0;
        csqc_cfelite_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFEliteDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return CFELITE_SEQ_SELECT;
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFELITE_SEQ_RELOAD;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Same parity + variant math as the fire path so the rendered
        // viewmodel sequence matches the barrel that actually fired.
        return SH_CFElitePickShootSeq(predicted_player.wep_action_id);
    }

    return CFELITE_SEQ_IDLE;
};

void() CSQC_CFEliteDropClear =
{
    self.mag_cfelite  = 0;
    self.ammo_cfelite = 0;
};

void() CSQC_CFEliteEquip =
{
    self.weapon_name         = CFELITE_DISPLAY_NAME;
    self.weapon_viewmodel    = CFELITE_VIEWMODEL;
    self.weapon_worldmodel   = CFELITE_WORLDMODEL;
    self.weapon_deploy_sound = CFELITE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFEliteCommand;
    self.csqc_predict_reload = CSQC_PredictCFEliteReload;
    self.csqc_display_frame  = CSQC_CFEliteDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFEliteDropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot anchor — use the RIGHT-barrel bone (Bone11) since the
    // sway visual just needs a stable rotation centre; the per-shot
    // bone pick still happens in the fire path.
    self.weapon_muzzle_bone   = CFELITE_MUZZLE_BONE_RIGHT;
    self.weapon_muzzle_offset = CFELITE_MUZZLE_OFFSET_RIGHT;

    // Snapshot-driven equip suppress for the draw clack — same shape
    // as cffiveseven / cfdeagle.  Does NOT stomp the stage tracker
    // when mid-DRAW / mid-RELOAD / mid-FIRE so reconcile-replay can
    // continue to emit predicted events (avoids the HDAK47 collapsed-
    // tracker reload bug).
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfelite_draw_snd_played = 1;
        csqc_cfelite_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
