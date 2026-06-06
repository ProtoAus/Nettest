// ============================================================
//  shared/weapons/sh_wpn_cfsg552.qc  -  SIG SG552 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_sg552.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFPSG1 / CFScar.  W_CFSG552Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_sg552.mdl):
//      0  idle      30 fps
//      1  reload    29 fps  (clipout @ 8, clipin @ 30, reload @ 60)
//      2  select    35 fps  (deploy — reuses reload.wav @ 9)
//      3  shoot1    30 fps
//      4  shoot2    30 fps
//      5  shoot3    30 fps
//
//  The reload sequence's third event ("reload" at frame 60) is the
//  final bolt-rack — we play reload.wav on CHAN_AUTO at that point.
//  Three reload events total drive a 4-stage tracker (0..3).
//
//  Per-reload sound trackers use SEPARATE fields (.cfsg552_draw_snd_played
//  and .cfsg552_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFM9 / CFPSG1 / CSUSP / CSAK47 pattern;
//  see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Muzzle is bone-attached via $attachment 0 "Bone01" (40 0 0) —
//  CSQC_ViewmodelAttachmentWorldPos resolves the world position each
//  shot so the flash tracks the firing animation.  Static
//  CSQC_MuzzleFlashAtWorld (NOT the *Animated frame-walked variant) per
//  spec.
//
//  No draw.WAV on disk — the deploy/select event REUSES reload.WAV.
//  Disk sounds: clipin, clipout, fire, reload only.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfsg552;
.float ammo_cfsg552;

// --- Per-entity sound stage trackers (server side) ---
.float cfsg552_draw_snd_played;
.float cfsg552_reload_snd_stage;

// --- Sequence indices ---
const float CFSG552_SEQ_IDLE    = 0;
const float CFSG552_SEQ_RELOAD  = 1;
const float CFSG552_SEQ_DRAW    = 2;
const float CFSG552_SEQ_SHOOT1  = 3;
const float CFSG552_SEQ_SHOOT2  = 4;
const float CFSG552_SEQ_SHOOT3  = 5;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 29 fps:
//   clipout at frame  8 / 29 = 0.28s   — mag drops out
//   clipin  at frame 30 / 29 = 1.03s   — fresh mag in
//   reload  at frame 60 / 29 = 2.07s   — final bolt rack (reload.wav)
// Select sequence @ 35 fps:
//   deploy  at frame  9 / 35 = 0.26s   — reuses reload.wav (no draw.wav)
const float CFSG552_RELOAD_CLIPOUT_TIME  = 0.28;
const float CFSG552_RELOAD_CLIPIN_TIME   = 1.03;
const float CFSG552_RELOAD_FINAL_TIME    = 2.07;
const float CFSG552_DRAW_BBACK_TIME      = 0.26;

// Ammo applies right after clipin lands (mag visually seated).
const float CFSG552_RELOAD_APPLY_TIME    = 1.03;

// --- Gameplay tuning ---
const float CFSG552_FIRE_DELAY        = 0.080;   // full-auto
const float CFSG552_DRYFIRE_DELAY     = 0.20;
const float CFSG552_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFSG552           = 30;
const float MAX_AMMO_CFSG552          = 90;

// --- Balance ---
const float CFSG552_BASE_SPREAD          = 0.012;
const float CFSG552_MOVE_SPREAD          = 0.07;
const float CFSG552_FULL_SPREAD_SPEED    = 320;
const float CFSG552_CLOSE_DAMAGE         = 33;
const float CFSG552_MIN_DAMAGE           = 22;
const float CFSG552_DAMAGE_FALLOFF_RANGE = 2400;
const float CFSG552_KICK_PITCH    = 0.7;
const float CFSG552_KICK_VARIANCE = 0.35;
const float CFSG552_KICK_STRENGTH = 0.85;

// Muzzle attachment — sourced from the v_sg552.mdl's $attachment 0:
//     $attachment 0 "Bone01" 40 0 0
// Bone name + local-frame offset come straight from the .qc; if the
// muzzle appears in the wrong spot, re-check those values in HLAM /
// the model's .qc and update here, not in camera-local space.
const string CFSG552_MUZZLE_BONE   = "Bone01";
#define CFSG552_MUZZLE_OFFSET ('40 0 0')

const string CFSG552_VIEWMODEL    = "models/weapons/wpn_cfsg552/v_sg552.mdl";
const string CFSG552_WORLDMODEL   = "models/weapons/wpn_cfsg552/w_sg552.mdl";
const string CFSG552_DEPLOY_SOUND = "";
const string CFSG552_DISPLAY_NAME = "SG552";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFSG552PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFSG552_SEQ_SHOOT1;
    if (r < 0.67) return CFSG552_SEQ_SHOOT2;
    return CFSG552_SEQ_SHOOT3;
};

float(float now) SH_CFSG552TickState =
{
    return SH_StandardTickState(now, mag_cfsg552, ammo_cfsg552, MAX_MAG_CFSG552,
        SH_SeqDuration(CFSG552_VIEWMODEL, CFSG552_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFSG552_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFSG552_VIEWMODEL, CFSG552_SEQ_RELOAD, 2.0),
        CFSG552_RELOAD_APPLY_TIME);
};

float(float now) SH_CFSG552TryFire =
{
    // Full-auto rifle: FIRE_DELAY paces cyclic rate, holding +attack
    // continues firing.  Standard (NOT SemiAuto) try-fire gate.
    return SH_StandardTryFire(now, mag_cfsg552, CFSG552_FIRE_DELAY, CFSG552_DRYFIRE_DELAY);
};

float(float now) SH_CFSG552TryReload =
{
    return SH_StandardTryReload(now, mag_cfsg552, ammo_cfsg552, MAX_MAG_CFSG552,
        SH_SeqDuration(CFSG552_VIEWMODEL, CFSG552_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFSG552PickupCopy =
{
    player.mag_cfsg552  = self.mag_cfsg552;
    player.ammo_cfsg552 = self.ammo_cfsg552;
};

void() W_CFSG552Shoot =
{
    W_PenetratingHitscanShoot(CFSG552_BASE_SPREAD, CFSG552_MOVE_SPREAD, CFSG552_FULL_SPREAD_SPEED,
        CFSG552_CLOSE_DAMAGE, CFSG552_MIN_DAMAGE, CFSG552_DAMAGE_FALLOFF_RANGE, 32, 0.97,
        CFSG552_KICK_PITCH, CFSG552_KICK_VARIANCE, CFSG552_KICK_STRENGTH);
};

void() W_CFSG552Fire =
{
    float r = SH_CFSG552TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFSG552PickShootSeq();
        self.wep_nextframe = time + CFSG552_FRAME_INTERVAL;

        W_CFSG552Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsg552/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFSG552Reload =
{
    if (SH_CFSG552TryReload(time))
    {
        self.weaponframe   = CFSG552_SEQ_RELOAD;
        self.wep_nextframe = time + CFSG552_FRAME_INTERVAL;
        self.cfsg552_reload_snd_stage = 0;
    }
};

void() W_CFSG552Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFSG552_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFSG552_DRAW_BBACK_TIME && !self.cfsg552_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsg552/reload.WAV", 1, ATTN_NORM);
            self.cfsg552_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFSG552_RELOAD_CLIPOUT_TIME && self.cfsg552_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsg552/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfsg552_reload_snd_stage = 1;
        }
        if (elapsed >= CFSG552_RELOAD_CLIPIN_TIME && self.cfsg552_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsg552/clipin.WAV", 1, ATTN_NORM);
            self.cfsg552_reload_snd_stage = 2;
        }
        if (elapsed >= CFSG552_RELOAD_FINAL_TIME && self.cfsg552_reload_snd_stage < 3)
        {
            // Final-rack: the third reload event in the source mdl uses
            // reload.wav (NOT a dedicated bcback / bcy file).
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsg552/reload.WAV", 1, ATTN_NORM);
            self.cfsg552_reload_snd_stage = 3;
        }
    }

    result = SH_CFSG552TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFSG552_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfsg552_reload_snd_stage = 0;
    }
};

void() W_CFSG552Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_sg552", SCOPE_CLASS_RIFLE_LOWPOWER);
    W_StandardEquipSetup(CFSG552_VIEWMODEL, CFSG552_DISPLAY_NAME, CFSG552_SEQ_DRAW,
        CFSG552_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFSG552Fire;
    self.reload   = W_CFSG552Reload;
    self.wepframe = W_CFSG552Frame;
    self.shoot    = W_CFSG552Shoot;
    self.cfsg552_draw_snd_played  = 0;
    self.cfsg552_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFSG552_BASE_SPREAD, CFSG552_MOVE_SPREAD, CFSG552_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFSG552Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfsg552  = self.mag_cfsg552;
    tgt.ammo_cfsg552 = self.ammo_cfsg552;

    self.mag_cfsg552  = 0;
    self.ammo_cfsg552 = 0;

    setmodel(tgt, CFSG552_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfsg552";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFSG552;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFSG552Equip;
    tgt.weap_drop_func = W_CFSG552Drop;
    tgt.pickupcopy    = W_CFSG552PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfsg552 =
{
    setmodel(self, CFSG552_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfsg552";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFSG552;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFSG552Equip;
    self.weap_drop_func = W_CFSG552Drop;
    self.pickupcopy   = W_CFSG552PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfsg552  = MAX_MAG_CFSG552;
    self.ammo_cfsg552 = MAX_AMMO_CFSG552;
    W_RegisterMapWeapon(weapon_cfsg552);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfsg552_draw_snd_played;
float csqc_cfsg552_reload_snd_stage;
float csqc_cfsg552_snd_action;

void() CSQC_PredictCFSG552Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfsg552_snd_action)
    {
        csqc_cfsg552_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfsg552_draw_snd_played  = 0;
        csqc_cfsg552_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFSG552TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsg552/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFSG552_BASE_SPREAD, CFSG552_MOVE_SPREAD, CFSG552_FULL_SPREAD_SPEED,
                    CFSG552_CLOSE_DAMAGE, CFSG552_MIN_DAMAGE, CFSG552_DAMAGE_FALLOFF_RANGE, 32, 0.97,
                    CFSG552_KICK_PITCH, CFSG552_KICK_VARIANCE, CFSG552_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle — $attachment 0 "Bone01" + local
                // offset.  Resolved each shot through
                // CSQC_ViewmodelAttachmentWorldPos so the flash and smoke
                // track the firing animation instead of sitting at a
                // hand-tuned camera-local offset.  Static (non-animated)
                // flash variant per spec.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFSG552_MUZZLE_BONE, CFSG552_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFSG552Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfsg552_draw_snd_played && elapsed >= CFSG552_DRAW_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfsg552/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsg552_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfsg552_reload_snd_stage < 1 && elapsed >= CFSG552_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfsg552/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfsg552_reload_snd_stage = 1;
            }
            if (csqc_cfsg552_reload_snd_stage < 2 && elapsed >= CFSG552_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfsg552/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsg552_reload_snd_stage = 2;
            }
            if (csqc_cfsg552_reload_snd_stage < 3 && elapsed >= CFSG552_RELOAD_FINAL_TIME)
            {
                // Final-rack — reload.wav per the source mdl event.
                localsound("sounds/weapons/wpn_cfsg552/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsg552_reload_snd_stage = 3;
            }
        }
    }

    SH_CFSG552TickState(csqc_pred_time);
};

void() CSQC_PredictCFSG552Reload =
{
    if (SH_CFSG552TryReload(csqc_pred_time))
    {
        csqc_cfsg552_reload_snd_stage = 0;
        csqc_cfsg552_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally.  All branches read predicted_player so the render
// path stays consistent across reconcile.
float(float elapsed) CSQC_CFSG552DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFSG552_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFSG552_SEQ_SHOOT1;
        if (r < 0.67) return CFSG552_SEQ_SHOOT2;
        return CFSG552_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFSG552_SEQ_RELOAD;

    return CFSG552_SEQ_IDLE;
};

void() CSQC_CFSG552DropClear =
{
    self.mag_cfsg552  = 0;
    self.ammo_cfsg552 = 0;
};

void() CSQC_CFSG552Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_sg552", SCOPE_CLASS_RIFLE_LOWPOWER);
    self.weapon_name         = CFSG552_DISPLAY_NAME;
    self.weapon_viewmodel    = CFSG552_VIEWMODEL;
    self.weapon_worldmodel   = CFSG552_WORLDMODEL;
    self.weapon_deploy_sound = CFSG552_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFSG552Command;
    self.csqc_predict_reload = CSQC_PredictCFSG552Reload;
    self.csqc_display_frame  = CSQC_CFSG552DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFSG552DropClear;
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
    self.weapon_muzzle_bone   = CFSG552_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFSG552_MUZZLE_OFFSET;

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
        csqc_cfsg552_draw_snd_played = 1;
        csqc_cfsg552_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
