// ============================================================
//  shared/weapons/sh_wpn_cfgalil.qc  -  FN SCAR (CF series, galil slot)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_scar.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFFiveSeven /
//  CFG3SG1.  W_CFGalilFrame does NOT step weaponframe per tick.
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
//  Per-reload sound trackers use SEPARATE fields (.cfgalil_draw_snd_played
//  and .cfgalil_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFFiveSeven / CFG3SG1 / CSUSP / CSAK47 pattern;
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
.float mag_cfgalil;
.float ammo_cfgalil;

// --- Per-entity sound stage trackers (server side) ---
.float cfgalil_draw_snd_played;
.float cfgalil_reload_snd_stage;

// --- Sequence indices ---
const float CFGALIL_SEQ_IDLE    = 0;
const float CFGALIL_SEQ_RELOAD  = 1;
const float CFGALIL_SEQ_DRAW    = 2;
const float CFGALIL_SEQ_SHOOT1  = 3;
const float CFGALIL_SEQ_SHOOT2  = 4;
const float CFGALIL_SEQ_SHOOT3  = 5;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 34 fps:
//   clipout at frame  2 / 34 = 0.059s   — mag drops out
//   clipin  at frame 44 / 34 = 1.294s   — fresh mag in
//   reload  at frame 61 / 34 = 1.794s   — final bolt rack (reload.wav)
// Select sequence @ 40 fps:
//   bback   at frame 16 / 40 = 0.400s   — draw bolt back (bback.wav)
const float CFGALIL_RELOAD_CLIPOUT_TIME  = 0.059;
const float CFGALIL_RELOAD_CLIPIN_TIME   = 1.294;
const float CFGALIL_RELOAD_FINAL_TIME    = 1.794;
const float CFGALIL_DRAW_BBACK_TIME      = 0.400;

// Ammo applies right after clipin lands (mag visually seated).
const float CFGALIL_RELOAD_APPLY_TIME    = 1.30;

// --- Gameplay tuning ---
const float CFGALIL_FIRE_DELAY        = 0.090;   // full-auto, ~666 RPM
const float CFGALIL_DRYFIRE_DELAY     = 0.20;
const float CFGALIL_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFGALIL           = 30;
const float MAX_AMMO_CFGALIL          = 90;

// --- Balance ---
const float CFGALIL_BASE_SPREAD          = 0.012;
const float CFGALIL_MOVE_SPREAD          = 0.07;
const float CFGALIL_FULL_SPREAD_SPEED    = 320;
const float CFGALIL_CLOSE_DAMAGE         = 28;
const float CFGALIL_MIN_DAMAGE           = 14;
const float CFGALIL_DAMAGE_FALLOFF_RANGE = 4096;
const float CFGALIL_KICK_PITCH    = 0.7;
const float CFGALIL_KICK_VARIANCE = 0.35;
const float CFGALIL_KICK_STRENGTH = 0.85;

// Muzzle attachment — sourced from the v_scar.mdl's $attachment 0:
//     $attachment 0 "Bone01" 22.8 0 0
// Bone name + local-frame offset come straight from the .qc; if the
// muzzle appears in the wrong spot, re-check those values in HLAM /
// the model's .qc and update here, not in camera-local space.
const string CFGALIL_MUZZLE_BONE   = "Bone01";
#define CFGALIL_MUZZLE_OFFSET ('22.8 0 0')

const string CFGALIL_VIEWMODEL    = "models/weapons/wpn_cfgalil/v_galil.mdl";
const string CFGALIL_WORLDMODEL   = "models/weapons/wpn_cfgalil/w_galil.mdl";
const string CFGALIL_DEPLOY_SOUND = "";
const string CFGALIL_DISPLAY_NAME = "FN SCAR";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFGalilPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFGALIL_SEQ_SHOOT1;
    if (r < 0.67) return CFGALIL_SEQ_SHOOT2;
    return CFGALIL_SEQ_SHOOT3;
};

float(float now) SH_CFGalilTickState =
{
    return SH_StandardTickState(now, mag_cfgalil, ammo_cfgalil, MAX_MAG_CFGALIL,
        SH_SeqDuration(CFGALIL_VIEWMODEL, CFGALIL_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFGALIL_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFGALIL_VIEWMODEL, CFGALIL_SEQ_RELOAD, 2.0),
        CFGALIL_RELOAD_APPLY_TIME);
};

float(float now) SH_CFGalilTryFire =
{
    // Full-auto rifle: FIRE_DELAY paces cyclic rate, holding +attack
    // continues firing.  Standard (NOT SemiAuto) try-fire gate.
    return SH_StandardTryFire(now, mag_cfgalil, CFGALIL_FIRE_DELAY, CFGALIL_DRYFIRE_DELAY);
};

float(float now) SH_CFGalilTryReload =
{
    return SH_StandardTryReload(now, mag_cfgalil, ammo_cfgalil, MAX_MAG_CFGALIL,
        SH_SeqDuration(CFGALIL_VIEWMODEL, CFGALIL_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFGalilPickupCopy =
{
    player.mag_cfgalil  = self.mag_cfgalil;
    player.ammo_cfgalil = self.ammo_cfgalil;
};

void() W_CFGalilShoot =
{
    W_PenetratingHitscanShoot(CFGALIL_BASE_SPREAD, CFGALIL_MOVE_SPREAD, CFGALIL_FULL_SPREAD_SPEED,
        CFGALIL_CLOSE_DAMAGE, CFGALIL_MIN_DAMAGE, CFGALIL_DAMAGE_FALLOFF_RANGE, 32, 0.97,
        CFGALIL_KICK_PITCH, CFGALIL_KICK_VARIANCE, CFGALIL_KICK_STRENGTH);
};

void() W_CFGalilFire =
{
    float r = SH_CFGalilTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFGalilPickShootSeq();
        self.wep_nextframe = time + CFGALIL_FRAME_INTERVAL;

        W_CFGalilShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfgalil/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFGalilReload =
{
    if (SH_CFGalilTryReload(time))
    {
        self.weaponframe   = CFGALIL_SEQ_RELOAD;
        self.wep_nextframe = time + CFGALIL_FRAME_INTERVAL;
        self.cfgalil_reload_snd_stage = 0;
    }
};

void() W_CFGalilFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFGALIL_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFGALIL_DRAW_BBACK_TIME && !self.cfgalil_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfgalil/reload.WAV", 1, ATTN_NORM);
            self.cfgalil_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFGALIL_RELOAD_CLIPOUT_TIME && self.cfgalil_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfgalil/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfgalil_reload_snd_stage = 1;
        }
        if (elapsed >= CFGALIL_RELOAD_CLIPIN_TIME && self.cfgalil_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfgalil/clipin.WAV", 1, ATTN_NORM);
            self.cfgalil_reload_snd_stage = 2;
        }
        if (elapsed >= CFGALIL_RELOAD_FINAL_TIME && self.cfgalil_reload_snd_stage < 3)
        {
            // Final-rack: the third reload event in the source mdl uses
            // reload.wav (NOT a dedicated bcback / bcy file).
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfgalil/reload.WAV", 1, ATTN_NORM);
            self.cfgalil_reload_snd_stage = 3;
        }
    }

    result = SH_CFGalilTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFGALIL_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfgalil_reload_snd_stage = 0;
    }
};

void() W_CFGalilEquip =
{
    W_StandardEquipSetup(CFGALIL_VIEWMODEL, CFGALIL_DISPLAY_NAME, CFGALIL_SEQ_DRAW,
        CFGALIL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFGalilFire;
    self.reload   = W_CFGalilReload;
    self.wepframe = W_CFGalilFrame;
    self.shoot    = W_CFGalilShoot;
    self.cfgalil_draw_snd_played  = 0;
    self.cfgalil_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFGALIL_BASE_SPREAD, CFGALIL_MOVE_SPREAD, CFGALIL_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFGalilDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfgalil  = self.mag_cfgalil;
    tgt.ammo_cfgalil = self.ammo_cfgalil;

    self.mag_cfgalil  = 0;
    self.ammo_cfgalil = 0;

    setmodel(tgt, CFGALIL_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfgalil";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFGALIL;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFGalilEquip;
    tgt.weap_drop_func = W_CFGalilDrop;
    tgt.pickupcopy    = W_CFGalilPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfgalil =
{
    setmodel(self, CFGALIL_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfgalil";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFGALIL;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFGalilEquip;
    self.weap_drop_func = W_CFGalilDrop;
    self.pickupcopy   = W_CFGalilPickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfgalil  = MAX_MAG_CFGALIL;
    self.ammo_cfgalil = MAX_AMMO_CFGALIL;
    W_RegisterMapWeapon(weapon_cfgalil);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfgalil_draw_snd_played;
float csqc_cfgalil_reload_snd_stage;
float csqc_cfgalil_snd_action;

void() CSQC_PredictCFGalilCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfgalil_snd_action)
    {
        csqc_cfgalil_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfgalil_draw_snd_played  = 0;
        csqc_cfgalil_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFGalilTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfgalil/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFGALIL_BASE_SPREAD, CFGALIL_MOVE_SPREAD, CFGALIL_FULL_SPREAD_SPEED,
                    CFGALIL_CLOSE_DAMAGE, CFGALIL_MIN_DAMAGE, CFGALIL_DAMAGE_FALLOFF_RANGE, 32, 0.97,
                    CFGALIL_KICK_PITCH, CFGALIL_KICK_VARIANCE, CFGALIL_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle — $attachment 0 "Bone01" + local
                // offset.  Resolved each shot through
                // CSQC_ViewmodelAttachmentWorldPos so the flash and smoke
                // track the firing animation instead of sitting at a
                // hand-tuned camera-local offset.  Static (non-animated)
                // flash variant per spec.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFGALIL_MUZZLE_BONE, CFGALIL_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFGalilFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfgalil_draw_snd_played && elapsed >= CFGALIL_DRAW_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfgalil/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfgalil_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfgalil_reload_snd_stage < 1 && elapsed >= CFGALIL_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfgalil/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfgalil_reload_snd_stage = 1;
            }
            if (csqc_cfgalil_reload_snd_stage < 2 && elapsed >= CFGALIL_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfgalil/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfgalil_reload_snd_stage = 2;
            }
            if (csqc_cfgalil_reload_snd_stage < 3 && elapsed >= CFGALIL_RELOAD_FINAL_TIME)
            {
                // Final-rack — reload.wav per the source mdl event.
                localsound("sounds/weapons/wpn_cfgalil/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfgalil_reload_snd_stage = 3;
            }
        }
    }

    SH_CFGalilTickState(csqc_pred_time);
};

void() CSQC_PredictCFGalilReload =
{
    if (SH_CFGalilTryReload(csqc_pred_time))
    {
        csqc_cfgalil_reload_snd_stage = 0;
        csqc_cfgalil_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally.  All branches read predicted_player so the render
// path stays consistent across reconcile.
float(float elapsed) CSQC_CFGalilDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFGALIL_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFGALIL_SEQ_SHOOT1;
        if (r < 0.67) return CFGALIL_SEQ_SHOOT2;
        return CFGALIL_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFGALIL_SEQ_RELOAD;

    return CFGALIL_SEQ_IDLE;
};

void() CSQC_CFGalilDropClear =
{
    self.mag_cfgalil  = 0;
    self.ammo_cfgalil = 0;
};

void() CSQC_CFGalilEquip =
{
    self.weapon_name         = CFGALIL_DISPLAY_NAME;
    self.weapon_viewmodel    = CFGALIL_VIEWMODEL;
    self.weapon_worldmodel   = CFGALIL_WORLDMODEL;
    self.weapon_deploy_sound = CFGALIL_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFGalilCommand;
    self.csqc_predict_reload = CSQC_PredictCFGalilReload;
    self.csqc_display_frame  = CSQC_CFGalilDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFGalilDropClear;
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
    self.weapon_muzzle_bone   = CFGALIL_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFGALIL_MUZZLE_OFFSET;

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
        csqc_cfgalil_draw_snd_played = 1;
        csqc_cfgalil_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
