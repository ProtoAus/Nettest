// ============================================================
//  shared/weapons/sh_wpn_cfscar.qc  -  FN SCAR (CF series, galil slot)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_scar.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFPSG1.  W_CFScarFrame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_scar.mdl):
//      0  idle_0    30 fps
//      1  reload    34 fps  (clipout @ 2, clipin @ 44, reload @ 61)
//      2  select    40 fps  (bback @ 16  — draw bolt back)
//      3  prefire   30 fps  (shoot variant A — event 5001 "22")
//      4  prefire   30 fps  (shoot variant B)
//      5  prefire   30 fps  (shoot variant C)
//
//  The reload sequence's third event ("reload" at frame 61) is the
//  final bolt-rack — we play reload.wav on CHAN_AUTO at that point.
//  Three reload events total drive a 4-stage tracker (0..3).
//
//  Per-reload sound trackers use SEPARATE fields (.cfscar_draw_snd_played
//  and .cfscar_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFM9 / CFPSG1 / CSUSP / CSAK47 pattern;
//  see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Muzzle is bone-attached via $attachment 0 "Bone01" (22.8 0 0) —
//  CSQC_ViewmodelAttachmentWorldPos resolves the world position each
//  shot so the flash tracks the firing animation.  Static
//  CSQC_MuzzleFlashAtWorld (NOT the *Animated frame-walked variant) per
//  spec.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfscar;
.float ammo_cfscar;

// --- Per-entity sound stage trackers (server side) ---
.float cfscar_draw_snd_played;
.float cfscar_reload_snd_stage;

// --- Sequence indices ---
const float CFSCAR_SEQ_IDLE    = 0;
const float CFSCAR_SEQ_RELOAD  = 1;
const float CFSCAR_SEQ_DRAW    = 2;
const float CFSCAR_SEQ_SHOOT1  = 3;
const float CFSCAR_SEQ_SHOOT2  = 4;
const float CFSCAR_SEQ_SHOOT3  = 5;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 34 fps:
//   clipout at frame  2 / 34 = 0.059s   — mag drops out
//   clipin  at frame 44 / 34 = 1.294s   — fresh mag in
//   reload  at frame 61 / 34 = 1.794s   — final bolt rack (reload.wav)
// Select sequence @ 40 fps:
//   bback   at frame 16 / 40 = 0.400s   — draw bolt back (bback.wav)
const float CFSCAR_RELOAD_CLIPOUT_TIME  = 0.059;
const float CFSCAR_RELOAD_CLIPIN_TIME   = 1.294;
const float CFSCAR_RELOAD_FINAL_TIME    = 1.794;
const float CFSCAR_DRAW_BBACK_TIME      = 0.400;

// Ammo applies right after clipin lands (mag visually seated).
const float CFSCAR_RELOAD_APPLY_TIME    = 1.30;

// --- Gameplay tuning ---
const float CFSCAR_FIRE_DELAY        = 0.090;   // full-auto, ~666 RPM
const float CFSCAR_DRYFIRE_DELAY     = 0.20;
const float CFSCAR_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFSCAR           = 30;
const float MAX_AMMO_CFSCAR          = 90;

// --- Balance ---
const float CFSCAR_BASE_SPREAD          = 0.012;
const float CFSCAR_MOVE_SPREAD          = 0.07;
const float CFSCAR_FULL_SPREAD_SPEED    = 320;
const float CFSCAR_CLOSE_DAMAGE         = 28;
const float CFSCAR_MIN_DAMAGE           = 14;
const float CFSCAR_DAMAGE_FALLOFF_RANGE = 4096;
const float CFSCAR_KICK_PITCH    = 0.7;
const float CFSCAR_KICK_VARIANCE = 0.35;
const float CFSCAR_KICK_STRENGTH = 0.85;

// Muzzle attachment — sourced from the v_scar.mdl's $attachment 0:
//     $attachment 0 "Bone01" 22.8 0 0
// Bone name + local-frame offset come straight from the .qc; if the
// muzzle appears in the wrong spot, re-check those values in HLAM /
// the model's .qc and update here, not in camera-local space.
const string CFSCAR_MUZZLE_BONE   = "Bone01";
#define CFSCAR_MUZZLE_OFFSET ('22.8 0 0')

const string CFSCAR_VIEWMODEL    = "models/weapons/wpn_cfscar/v_scar.mdl";
const string CFSCAR_WORLDMODEL   = "models/weapons/wpn_cfscar/w_scar.mdl";
const string CFSCAR_DEPLOY_SOUND = "";
const string CFSCAR_DISPLAY_NAME = "FN SCAR";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFScarPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFSCAR_SEQ_SHOOT1;
    if (r < 0.67) return CFSCAR_SEQ_SHOOT2;
    return CFSCAR_SEQ_SHOOT3;
};

float(float now) SH_CFScarTickState =
{
    return SH_StandardTickState(now, mag_cfscar, ammo_cfscar, MAX_MAG_CFSCAR,
        SH_SeqDuration(CFSCAR_VIEWMODEL, CFSCAR_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFSCAR_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFSCAR_VIEWMODEL, CFSCAR_SEQ_RELOAD, 2.0),
        CFSCAR_RELOAD_APPLY_TIME);
};

float(float now) SH_CFScarTryFire =
{
    // Full-auto rifle: FIRE_DELAY paces cyclic rate, holding +attack
    // continues firing.  Standard (NOT SemiAuto) try-fire gate.
    return SH_StandardTryFire(now, mag_cfscar, CFSCAR_FIRE_DELAY, CFSCAR_DRYFIRE_DELAY);
};

float(float now) SH_CFScarTryReload =
{
    return SH_StandardTryReload(now, mag_cfscar, ammo_cfscar, MAX_MAG_CFSCAR,
        SH_SeqDuration(CFSCAR_VIEWMODEL, CFSCAR_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFScarPickupCopy =
{
    player.mag_cfscar  = self.mag_cfscar;
    player.ammo_cfscar = self.ammo_cfscar;
};

void() W_CFScarShoot =
{
    W_PenetratingHitscanShoot(CFSCAR_BASE_SPREAD, CFSCAR_MOVE_SPREAD, CFSCAR_FULL_SPREAD_SPEED,
        CFSCAR_CLOSE_DAMAGE, CFSCAR_MIN_DAMAGE, CFSCAR_DAMAGE_FALLOFF_RANGE, 32, 0.97,
        CFSCAR_KICK_PITCH, CFSCAR_KICK_VARIANCE, CFSCAR_KICK_STRENGTH);
};

void() W_CFScarFire =
{
    float r = SH_CFScarTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFScarPickShootSeq();
        self.wep_nextframe = time + CFSCAR_FRAME_INTERVAL;

        W_CFScarShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfscar/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFScarReload =
{
    if (SH_CFScarTryReload(time))
    {
        self.weaponframe   = CFSCAR_SEQ_RELOAD;
        self.wep_nextframe = time + CFSCAR_FRAME_INTERVAL;
        self.cfscar_reload_snd_stage = 0;
    }
};

void() W_CFScarFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFSCAR_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFSCAR_DRAW_BBACK_TIME && !self.cfscar_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfscar/reload.WAV", 1, ATTN_NORM);
            self.cfscar_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFSCAR_RELOAD_CLIPOUT_TIME && self.cfscar_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfscar/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfscar_reload_snd_stage = 1;
        }
        if (elapsed >= CFSCAR_RELOAD_CLIPIN_TIME && self.cfscar_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfscar/clipin.WAV", 1, ATTN_NORM);
            self.cfscar_reload_snd_stage = 2;
        }
        if (elapsed >= CFSCAR_RELOAD_FINAL_TIME && self.cfscar_reload_snd_stage < 3)
        {
            // Final-rack: the third reload event in the source mdl uses
            // reload.wav (NOT a dedicated bcback / bcy file).
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfscar/reload.WAV", 1, ATTN_NORM);
            self.cfscar_reload_snd_stage = 3;
        }
    }

    result = SH_CFScarTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFSCAR_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfscar_reload_snd_stage = 0;
    }
};

void() W_CFScarEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_scar", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFSCAR_VIEWMODEL, CFSCAR_DISPLAY_NAME, CFSCAR_SEQ_DRAW,
        CFSCAR_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFScarFire;
    self.reload   = W_CFScarReload;
    self.wepframe = W_CFScarFrame;
    self.shoot    = W_CFScarShoot;
    self.cfscar_draw_snd_played  = 0;
    self.cfscar_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFSCAR_BASE_SPREAD, CFSCAR_MOVE_SPREAD, CFSCAR_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFScarDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfscar  = self.mag_cfscar;
    tgt.ammo_cfscar = self.ammo_cfscar;

    self.mag_cfscar  = 0;
    self.ammo_cfscar = 0;

    setmodel(tgt, CFSCAR_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfscar";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFSCAR;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFScarEquip;
    tgt.weap_drop_func = W_CFScarDrop;
    tgt.pickupcopy    = W_CFScarPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfscar =
{
    setmodel(self, CFSCAR_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfscar";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFSCAR;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFScarEquip;
    self.weap_drop_func = W_CFScarDrop;
    self.pickupcopy   = W_CFScarPickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfscar  = MAX_MAG_CFSCAR;
    self.ammo_cfscar = MAX_AMMO_CFSCAR;
    W_RegisterMapWeapon(weapon_cfscar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfscar_draw_snd_played;
float csqc_cfscar_reload_snd_stage;
float csqc_cfscar_snd_action;

void() CSQC_PredictCFScarCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfscar_snd_action)
    {
        csqc_cfscar_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfscar_draw_snd_played  = 0;
        csqc_cfscar_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFScarTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfscar/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFSCAR_BASE_SPREAD, CFSCAR_MOVE_SPREAD, CFSCAR_FULL_SPREAD_SPEED,
                    CFSCAR_CLOSE_DAMAGE, CFSCAR_MIN_DAMAGE, CFSCAR_DAMAGE_FALLOFF_RANGE, 32, 0.97,
                    CFSCAR_KICK_PITCH, CFSCAR_KICK_VARIANCE, CFSCAR_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle — $attachment 0 "Bone01" + local
                // offset.  Resolved each shot through
                // CSQC_ViewmodelAttachmentWorldPos so the flash and smoke
                // track the firing animation instead of sitting at a
                // hand-tuned camera-local offset.  Static (non-animated)
                // flash variant per spec.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFSCAR_MUZZLE_BONE, CFSCAR_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFScarFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfscar_draw_snd_played && elapsed >= CFSCAR_DRAW_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfscar/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfscar_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfscar_reload_snd_stage < 1 && elapsed >= CFSCAR_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfscar/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfscar_reload_snd_stage = 1;
            }
            if (csqc_cfscar_reload_snd_stage < 2 && elapsed >= CFSCAR_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfscar/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfscar_reload_snd_stage = 2;
            }
            if (csqc_cfscar_reload_snd_stage < 3 && elapsed >= CFSCAR_RELOAD_FINAL_TIME)
            {
                // Final-rack — reload.wav per the source mdl event.
                localsound("sounds/weapons/wpn_cfscar/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfscar_reload_snd_stage = 3;
            }
        }
    }

    SH_CFScarTickState(csqc_pred_time);
};

void() CSQC_PredictCFScarReload =
{
    if (SH_CFScarTryReload(csqc_pred_time))
    {
        csqc_cfscar_reload_snd_stage = 0;
        csqc_cfscar_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally.  All branches read predicted_player so the render
// path stays consistent across reconcile.
float(float elapsed) CSQC_CFScarDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFSCAR_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFSCAR_SEQ_SHOOT1;
        if (r < 0.67) return CFSCAR_SEQ_SHOOT2;
        return CFSCAR_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFSCAR_SEQ_RELOAD;

    return CFSCAR_SEQ_IDLE;
};

void() CSQC_CFScarDropClear =
{
    self.mag_cfscar  = 0;
    self.ammo_cfscar = 0;
};

void() CSQC_CFScarEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_scar", SCOPE_CLASS_NONE);
    self.weapon_name         = CFSCAR_DISPLAY_NAME;
    self.weapon_viewmodel    = CFSCAR_VIEWMODEL;
    self.weapon_worldmodel   = CFSCAR_WORLDMODEL;
    self.weapon_deploy_sound = CFSCAR_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFScarCommand;
    self.csqc_predict_reload = CSQC_PredictCFScarReload;
    self.csqc_display_frame  = CSQC_CFScarDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFScarDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel
    // horizontally; the engine inverts cull winding so backface culling
    // stays correct.
    self.weapon_viewmodel_flip = TRUE;

    // Muzzle tag — reuse the constants the fire path passes to
    // CSQC_ViewmodelAttachmentWorldPos so cl_viewfx's sway-pivot mode
    // rotates around the same point the flash is anchored to.
    self.weapon_muzzle_bone   = CFSCAR_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFSCAR_MUZZLE_OFFSET;

    // Snapshot-driven equip suppress for the draw-bback: weaponstate at
    // this point is WS_IDLE / WS_DEAD on a snapshot-driven draw
    // (cl_player.qc sets WS_DRAW AFTER Equip), so latching the
    // draw-snd-played flag here means the predict path skips the local
    // draw-bback and lets the server's CHAN_AUTO emission play through
    // unsuppressed.  Local-prediction draw (CSQC_PredictSelectWeapon
    // sets WS_DRAW BEFORE Equip) skips this branch — predicted draw
    // sound still fires.  Mid-RELOAD / mid-FIRE reconciles also skip
    // (avoiding the HDAK47 collapsed-tracker bug — see commit history).
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfscar_draw_snd_played = 1;
        csqc_cfscar_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
