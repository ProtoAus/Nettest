// ============================================================
//  shared/weapons/sh_wpn_hdak47.qc  -  HD AK47 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto.
//          SHARES the WEP_AK47 ammo pool (mag_ak47 / ammo_ak47) and
//          all balance numbers — picking up either variant fills the
//          same pool.  Only the model + animation system differs.
//  Fire  : lag-compensated hitscan, linear damage falloff (delegates
//          to AK47's W_AK47Shoot path).
//
//  Animation: SEQUENCE-DRIVEN (GoldSrc convention).  Setting
//  self.weaponframe = N tells FTE to play sequence N as a whole
//  and animate it internally — same pattern as USP / knife.
//  W_HDAK47Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_ak47.mdl):
//     0  idle1     30 fps
//     1  reload    37 fps  (clipout @ frame 13, clipin @ frame 57)
//     2  draw      30 fps  (boltpull @ frame 11)
//     3  shoot1    20 fps
//     4  shoot2    20 fps
//     5  shoot3    20 fps
//
//  Note on $sequence event 5004 markers in the .mdl: FTE does NOT
//  auto-play those.  The events ARE present in the file but the
//  GoldSrc engine-side sound trigger is not implemented in FTE.
//  We trigger sounds from QC using elapsed-time comparisons —
//  same pattern as USP / knife / every other GoldSrc-format
//  weapon in this mod.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Sequence indices ---
const float HDAK47_SEQ_IDLE   = 0;
const float HDAK47_SEQ_RELOAD = 1;
const float HDAK47_SEQ_DRAW   = 2;
const float HDAK47_SEQ_SHOOT1 = 3;
const float HDAK47_SEQ_SHOOT2 = 4;
const float HDAK47_SEQ_SHOOT3 = 5;

// --- Timing ---
//
// Sequence-window durations are queried from the model at runtime via
// SH_SeqDuration (frameduration() builtin) — no _DURATION constants
// needed.  A 1.0s fallback covers the case where the model isn't
// precached yet; real anims are always longer than that.
//
// _APPLY_TIME is an internal event position (when the mag visually
// re-seats), which frameduration() can't report — only total length.
// Stays a constant.
//
// _DELAY values are gameplay cooldowns, not anim windows — they tune
// rate-of-fire / dryfire timing and stay constants.
const float HDAK47_RELOAD_APPLY_TIME = 1.70;

const float HDAK47_FIRE_DELAY        = 0.10;   // matches AK47 cyclic rate
const float HDAK47_DRYFIRE_DELAY     = 0.20;

// State-machine tick rate (no frame stepping — sequence-driven).
const float HDAK47_FRAME_INTERVAL    = 0.05;

// Muzzle attachment — sourced from the v_ak47.mdl's $attachment 0:
//     $attachment 0 "Bone 04" 2.85 -22.5 3.15
// Bone name + local-frame offset come straight from the .qc; if the
// muzzle appears in the wrong spot, re-check those values in HLAM /
// the model's .qc and update here, not in camera-local space.
const string HDAK47_MUZZLE_BONE   = "Bone 04";
#define HDAK47_MUZZLE_OFFSET ('2.85 -22.5 3.15')

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Derived from the $sequence event 5004 markers in v_ak47.mdl:
//   draw    boltpull at frame 11 / 30 fps = 0.367s
//   reload  clipout  at frame 13 / 37 fps = 0.351s
//   reload  clipin   at frame 57 / 37 fps = 1.541s
const float HDAK47_DRAW_BOLTPULL_TIME    = 0.367;
const float HDAK47_RELOAD_CLIPOUT_TIME   = 0.351;
const float HDAK47_RELOAD_CLIPIN_TIME    = 1.541;

const string HDAK47_VIEWMODEL    = "models/weapons/wpn_hdak47/v_ak47.mdl";
const string HDAK47_WORLDMODEL   = "models/weapons/wpn_hdak47/w_ak47.mdl";
const string HDAK47_DEPLOY_SOUND = "";
const string HDAK47_DISPLAY_NAME = "HD AK47";

// Per-entity sound stage tracker so timed events fire exactly once
// per action (paired with wep_action_id reset).  Separate sides:
// server authoritative for hits; CSQC mirrors via csqc_hdak47_snd_stage.
.float hdak47_snd_stage;

// ============================================================
//  SHARED — sequence-pick + idle helpers
// ============================================================

// Pick a shoot sequence deterministically from wep_action_id so the
// client and server agree on which animation to play this shot.
float() SH_HDAK47PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return HDAK47_SEQ_SHOOT1;
    if (r < 0.67) return HDAK47_SEQ_SHOOT2;
    return HDAK47_SEQ_SHOOT3;
};

// ============================================================
//  SHARED — state machine
// ============================================================

// Durations come straight from the model's $sequence headers via
// SH_SeqDuration — keeps the gameplay layer in sync if the artist
// retimes the source MDL.  Each call site asks for the matching seq.
float(float now) SH_HDAK47TickState =
{
    return SH_StandardTickState(now, mag_ak47, ammo_ak47, MAX_MAG_AK47,
        SH_SeqDuration(HDAK47_VIEWMODEL, HDAK47_SEQ_DRAW,   1.0),
        SH_SeqDuration(HDAK47_VIEWMODEL, self.weaponframe,  0.5),
        SH_SeqDuration(HDAK47_VIEWMODEL, HDAK47_SEQ_RELOAD, 2.0),
        HDAK47_RELOAD_APPLY_TIME);
};

float(float now) SH_HDAK47TryFire =
{
    return SH_StandardTryFire(now, mag_ak47, HDAK47_FIRE_DELAY, HDAK47_DRYFIRE_DELAY);
};

float(float now) SH_HDAK47TryReload =
{
    return SH_StandardTryReload(now, mag_ak47, ammo_ak47, MAX_MAG_AK47,
        SH_SeqDuration(HDAK47_VIEWMODEL, HDAK47_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Forward declarations — defined in sh_wpn_csak47.qc which compiles
// earlier in sv_progs.src.  We re-use AK47's hitscan path so the HD
// variant is functionally identical at the gameplay layer.
void() W_AK47Shoot;

void(entity player) W_HDAK47PickupCopy =
{
    player.mag_ak47  = self.mag_ak47;
    player.ammo_ak47 = self.ammo_ak47;
};

void() W_HDAK47Fire =
{
    float r = SH_HDAK47TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_HDAK47PickShootSeq();
        self.wep_nextframe = time + HDAK47_FRAME_INTERVAL;
        self.hdak47_snd_stage = 0;

        // Re-use AK47's lag-comped penetrating hitscan.
        W_AK47Shoot();

        // Same fire sounds as AK47 — no new wav files needed.
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_HDAK47Reload =
{
    if (SH_HDAK47TryReload(time))
    {
        self.weaponframe   = HDAK47_SEQ_RELOAD;
        self.wep_nextframe = time + HDAK47_FRAME_INTERVAL;
        self.hdak47_snd_stage = 0;
    }
};

void() W_HDAK47Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += HDAK47_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HDAK47_DRAW_BOLTPULL_TIME && self.hdak47_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/boltpull.wav", 1, ATTN_NORM);
            self.hdak47_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= HDAK47_RELOAD_CLIPOUT_TIME && self.hdak47_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.hdak47_snd_stage = 1;
        }
        if (elapsed >= HDAK47_RELOAD_CLIPIN_TIME && self.hdak47_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipin.wav", 1, ATTN_NORM);
            self.hdak47_snd_stage = 2;
        }
    }

    result = SH_HDAK47TickState(time);
    if (result & 1)
    {
        self.weaponframe   = HDAK47_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.hdak47_snd_stage = 0;
    }
};

void() W_HDAK47Equip =
{
    W_StandardEquipSetup(HDAK47_VIEWMODEL, HDAK47_DISPLAY_NAME, HDAK47_SEQ_DRAW,
        HDAK47_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HDAK47Fire;
    self.reload   = W_HDAK47Reload;
    self.wepframe = W_HDAK47Frame;
    self.shoot    = W_AK47Shoot;
    self.hdak47_snd_stage = 0;
    W_SetCrosshairProfile(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_HDAK47Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_ak47  = self.mag_ak47;
    tgt.ammo_ak47 = self.ammo_ak47;

    self.mag_ak47  = 0;
    self.ammo_ak47 = 0;

    setmodel(tgt, HDAK47_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_hdak47";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HDAK47;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_HDAK47Equip;
    tgt.weap_drop_func = W_HDAK47Drop;
    tgt.pickupcopy   = W_HDAK47PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hdak47 =
{
    setmodel(self, HDAK47_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_hdak47";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HDAK47;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_HDAK47Equip;
    self.weap_drop_func = W_HDAK47Drop;
    self.pickupcopy    = W_HDAK47PickupCopy;
    self.touch         = weapon_touch;
    self.mag_ak47      = MAX_MAG_AK47;
    self.ammo_ak47     = MAX_AMMO_AK47;
    W_RegisterMapWeapon(weapon_hdak47);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_hdak47_snd_stage;
float csqc_hdak47_snd_action;

void() CSQC_PredictHDAK47Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so a draw boltpull, mid-reload
    // clipout, etc., are each fired exactly once per action even when
    // pmove replay re-runs the same buffered command.
    if (predicted_player.wep_action_id != csqc_hdak47_snd_action)
    {
        csqc_hdak47_snd_action = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_HDAK47Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted bolt-pull
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_hdak47_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_HDAK47TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED,
                    AK47_CLOSE_DAMAGE, AK47_MIN_DAMAGE, AK47_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    AK47_KICK_PITCH, AK47_KICK_VARIANCE, AK47_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Two-frame additive muzzle flash + smoke, anchored to the
                // viewmodel's $attachment 0 (Bone 04) so the position
                // tracks the firing animation instead of sitting at a
                // hand-tuned camera-local offset.  Tracer start point is
                // resolved through CSQC_MuzzleFlashWorldPos so it follows
                // the attachment automatically.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    HDAK47_MUZZLE_BONE, HDAK47_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_HDAK47Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_hdak47_snd_stage < 1 && elapsed >= HDAK47_DRAW_BOLTPULL_TIME)
            {
                localsound("sounds/weapons/wpn_csak47/boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_hdak47_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_hdak47_snd_stage < 1 && elapsed >= HDAK47_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_csak47/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_hdak47_snd_stage = 1;
            }
            if (csqc_hdak47_snd_stage < 2 && elapsed >= HDAK47_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_csak47/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_hdak47_snd_stage = 2;
            }
        }
    }

    SH_HDAK47TickState(csqc_pred_time);
};

void() CSQC_PredictHDAK47Reload =
{
    if (SH_HDAK47TryReload(csqc_pred_time))
    {
        csqc_hdak47_snd_stage  = 0;
        csqc_hdak47_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally.  All branches read predicted_player so the render
// path stays consistent across reconcile.
float(float elapsed) CSQC_HDAK47DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return HDAK47_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Deterministic shoot pick from wep_action_id so client and
        // server agree which of shoot1/2/3 plays for this shot.
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return HDAK47_SEQ_SHOOT1;
        if (r < 0.67) return HDAK47_SEQ_SHOOT2;
        return HDAK47_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return HDAK47_SEQ_RELOAD;

    return HDAK47_SEQ_IDLE;
};

void() CSQC_HDAK47DropClear =
{
    self.mag_ak47 = 0;
    self.ammo_ak47 = 0;
};

void() CSQC_HDAK47Equip =
{
    self.weapon_name         = HDAK47_DISPLAY_NAME;
    self.weapon_viewmodel    = HDAK47_VIEWMODEL;
    self.weapon_worldmodel   = HDAK47_WORLDMODEL;
    self.weapon_deploy_sound = HDAK47_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictHDAK47Command;
    self.csqc_predict_reload = CSQC_PredictHDAK47Reload;
    self.csqc_display_frame  = CSQC_HDAK47DisplayFrame;
    self.csqc_drop_clear     = CSQC_HDAK47DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;

    // Source v_ak47.mdl is left-handed.  RF_XFLIP mirrors the viewmodel
    // horizontally — the engine flips projection X and inverts cull
    // winding so backface culling stays correct.
    self.weapon_viewmodel_flip = TRUE;

    // Muzzle tag — reuse the constants the fire path passes to
    // CSQC_ViewmodelAttachmentWorldPos so cl_viewfx's sway-pivot mode
    // rotates around the same point the flash is anchored to.
    self.weapon_muzzle_bone   = HDAK47_MUZZLE_BONE;
    self.weapon_muzzle_offset = HDAK47_MUZZLE_OFFSET;

    // Snapshot-driven equip suppresses the predicted boltpull.  See
    // CSQC_AK47Equip in sh_wpn_csak47.qc for the full rationale —
    // weaponstate != WS_DRAW at this point means the equip came via
    // cl_player.qc:830 reconcile (which sets WS_DRAW only after the
    // CSQC_WeaponEquip call) rather than a local CSQC_PredictSelectWeapon
    // (which sets WS_DRAW before).  When the server is driving the
    // equip, its W_HDAK47Frame fires the boltpull on CHAN_AUTO inside
    // the same snapshot packet, and the engine plays it before the
    // first predict tick can stamp the dedup time.
    // CSQC_WeaponEquip runs on EVERY reconcile (cl_player.qc:876), not
    // only on weapon-change.  The HDAK47 collapses both its draw-boltpull
    // suppress and reload-sound-progress trackers into a single
    // csqc_hdak47_snd_stage variable, so naively stomping it whenever
    // weaponstate != WS_DRAW also wiped per-reload progress mid-reload.
    //
    // Symptom that triggered this fix: clipout never played (stage was
    // re-stamped to 1 before elapsed reached its frame threshold), and
    // clipin re-fired on every snapshot for ~0.5 s (each reconcile reset
    // stage from 2 back to 1, the next predict tick re-passed the gate
    // and emitted clipin on CHAN_AUTO again — CHAN_AUTO doesn't cut its
    // own channel so the copies stacked into a loud glitchy burst).
    //
    // Fix: only stomp when the player is genuinely NOT already in the
    // middle of an action.  Snapshot-driven draw still works because
    // cl_player.qc sets WS_DRAW AFTER this Equip on that path
    // (so weaponstate is WS_IDLE / WS_DEAD here, both excluded by the
    // new guard).  Local-prediction draw also still works because it
    // sets WS_DRAW BEFORE Equip — original branch was already skipped.
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_hdak47_snd_stage  = 1;
        csqc_hdak47_snd_action = self.wep_action_id;
    }
};

#endif // CSQC
