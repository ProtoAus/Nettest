// ============================================================
//  shared/weapons/sh_wpn_cfm700.qc  -  Remington M700 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round magazine, 30 reserve, bolt-action .308
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff.
//          Single-shot pacing enforced by CFM700_FIRE_DELAY (~1.0s)
//          — no semi-auto edge gate needed at the bolt-action cadence.
//  Scope : CoD-style toggle scope owned by cl_codscope.qc when
//          sv_codscopes is set.  This file contains NO altfire / zoom
//          code — orchestrator wires the CodScope_Eligible hook against
//          the display name.
//
//  GoldSrc-format viewmodel (v_m700.mdl) — sequence-driven.  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as CFBARRETT / CFPSG1 / HDAK47.
//  W_CFM700Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_m700.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   30 fps  (shoot variant A — event 5001 "21",
//                            event 5004 @ frame 17 -> reload.wav for
//                            the post-fire bolt-cycle)
//      2  prefire   30 fps  (shoot variant B)
//      3  reload    35 fps  (clipout @ 7, clipin @ 23, reload @ 51)
//      4  select    30 fps  (event @ frame 1 -> select.wav)
//
//  Note on the prefire frame-17 event 5004 marker: FTE does NOT
//  auto-play those.  We drive the post-fire bolt-cycle sound from QC
//  using elapsed-since-fire vs CFM700_FIRE_BOLTCYCLE_TIME, gated
//  by .cfm700_post_fire_bolt_played so it emits exactly once per
//  shot (reset to 0 at each fire start).
//
//  Per-state sound trackers use SEPARATE fields:
//     .cfm700_draw_snd_played       — select.wav (one-shot)
//     .cfm700_reload_snd_stage      — clipout/clipin/reload stages
//     .cfm700_post_fire_bolt_played — mid-fire bolt cycle
//  NOT a single collapsed stage variable.  This is the CFM9 /
//  CFBARRETT / CFPSG1 pattern; see the HDAK47 reload-sound bug fix
//  commit for why the single-variable approach corrupts state under
//  the every-reconcile CSQC_WeaponEquip call.
//
//  Muzzle attachment: $attachment 0 "Bone01" 55.0 0 0 — bone-relative
//  offset, resolved via CSQC_ViewmodelAttachmentWorldPos so the flash
//  tracks the firing animation.  Static (non-animated) muzzle flash —
//  bolt-action one-shot feel.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfm700;
.float ammo_cfm700;

// --- Per-entity sound stage trackers (server side) ---
.float cfm700_draw_snd_played;
.float cfm700_reload_snd_stage;
.float cfm700_post_fire_bolt_played;

// --- Sequence indices ---
const float CFM700_SEQ_IDLE    = 0;
const float CFM700_SEQ_SHOOT1  = 1;
const float CFM700_SEQ_SHOOT2  = 2;
const float CFM700_SEQ_RELOAD  = 3;
const float CFM700_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Fire (prefire) sequence @ 30 fps:
//   bolt-cycle at frame 17 / 30 = 0.567s — mid-fire bolt cycle, emits
//                                          reload.wav on CHAN_AUTO.
// Reload sequence @ 35 fps:
//   clipout    at frame  7 / 35 = 0.200s — mag drops out
//   clipin     at frame 23 / 35 = 0.657s — fresh mag in
//   reload     at frame 51 / 35 = 1.457s — bolt cycle / chamber close
// Select sequence @ 30 fps:
//   select     at frame  1 / 30 = 0.033s — draw clack
const float CFM700_FIRE_BOLTCYCLE_TIME = 0.567;
const float CFM700_RELOAD_CLIPOUT_TIME = 0.200;
const float CFM700_RELOAD_CLIPIN_TIME  = 0.657;
const float CFM700_RELOAD_RELOAD_TIME  = 1.457;
const float CFM700_DRAW_CLACK_TIME     = 0.033;

// Ammo applies right after the final reload event lands so the mag is
// visually seated and the bolt is closed before the new round counts.
const float CFM700_RELOAD_APPLY_TIME   = 1.50;

// --- Gameplay tuning ---
const float CFM700_FIRE_DELAY        = 1.0;    // bolt-action — slow refire
const float CFM700_DRYFIRE_DELAY     = 0.2;
const float CFM700_FRAME_INTERVAL    = 0.05;   // state-machine tick rate

const float MAX_MAG_CFM700           = 5;
const float MAX_AMMO_CFM700          = 30;

// --- Balance ---
// M700 — classic .308 bolt-action; clean one-shot to the upper torso
// inside ~half the falloff window, falls off to a body-shot KO at long
// range so it isn't an oppressive one-tap at every distance.
const float CFM700_BASE_SPREAD          = 0.008;
const float CFM700_MOVE_SPREAD          = 0.12;
const float CFM700_FULL_SPREAD_SPEED    = 320;
const float CFM700_CLOSE_DAMAGE         = 115;
const float CFM700_MIN_DAMAGE           = 70;
const float CFM700_DAMAGE_FALLOFF_RANGE = 4096;
const float CFM700_KICK_PITCH    = 2.2;    // sv_gunkick — heavy bolt-action
const float CFM700_KICK_VARIANCE = 0.5;
const float CFM700_KICK_STRENGTH = 1.8;

// Muzzle attachment — sourced from v_m700.mdl's $attachment 0:
//     $attachment 0 "Bone01" 55.0 0 0
// Bone name + local-frame offset come straight from the model; if the
// muzzle appears in the wrong spot, re-check those values and update
// here, not in camera-local space.
const string CFM700_MUZZLE_BONE   = "Bone01";
#define CFM700_MUZZLE_OFFSET ('55.0 0.0 0.0')

const string CFM700_VIEWMODEL    = "models/weapons/wpn_cfm700/v_m700.mdl";
const string CFM700_WORLDMODEL   = "models/weapons/wpn_cfm700/w_m700.mdl";
const string CFM700_DEPLOY_SOUND = "";
const string CFM700_DISPLAY_NAME = "M700";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFM700PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFM700_SEQ_SHOOT1;
    return CFM700_SEQ_SHOOT2;
};

float(float now) SH_CFM700TickState =
{
    return SH_StandardTickState(now, mag_cfm700, ammo_cfm700, MAX_MAG_CFM700,
        SH_SeqDuration(CFM700_VIEWMODEL, CFM700_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFM700_VIEWMODEL, self.weaponframe,        0.5),
        SH_SeqDuration(CFM700_VIEWMODEL, CFM700_SEQ_RELOAD, 2.0),
        CFM700_RELOAD_APPLY_TIME);
};

float(float now) SH_CFM700TryFire =
{
    // Bolt-action: FIRE_DELAY itself enforces single-shot pacing —
    // no semi-auto edge gate needed.
    return SH_StandardTryFire(now, mag_cfm700, CFM700_FIRE_DELAY, CFM700_DRYFIRE_DELAY);
};

float(float now) SH_CFM700TryReload =
{
    return SH_StandardTryReload(now, mag_cfm700, ammo_cfm700, MAX_MAG_CFM700,
        SH_SeqDuration(CFM700_VIEWMODEL, CFM700_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFM700PickupCopy =
{
    player.mag_cfm700  = self.mag_cfm700;
    player.ammo_cfm700 = self.ammo_cfm700;
};

void() W_CFM700Shoot =
{
    W_PenetratingHitscanShoot(CFM700_BASE_SPREAD, CFM700_MOVE_SPREAD, CFM700_FULL_SPREAD_SPEED,
        CFM700_CLOSE_DAMAGE, CFM700_MIN_DAMAGE, CFM700_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        CFM700_KICK_PITCH, CFM700_KICK_VARIANCE, CFM700_KICK_STRENGTH);
};

void() W_CFM700Fire =
{
    float r = SH_CFM700TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFM700PickShootSeq();
        self.wep_nextframe = time + CFM700_FRAME_INTERVAL;
        // Reset the post-fire bolt-cycle gate so this shot's
        // mid-fire reload.wav plays exactly once at +0.567s.
        self.cfm700_post_fire_bolt_played = 0;

        // Bolt-action scope-rescope: override the 0.4s default to
        // FIRE_DELAY so the CoD scope is suppressed until the bolt
        // cycle finishes.  See cfbarrett for the rationale.
        self.pm_fire_suppress_until = time + CFM700_FIRE_DELAY;

        W_CFM700Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm700/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFM700Reload =
{
    if (SH_CFM700TryReload(time))
    {
        self.weaponframe   = CFM700_SEQ_RELOAD;
        self.wep_nextframe = time + CFM700_FRAME_INTERVAL;
        self.cfm700_reload_snd_stage = 0;
    }
};

void() W_CFM700Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFM700_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFM700_DRAW_CLACK_TIME && !self.cfm700_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm700/draw.WAV", 1, ATTN_NORM);
            self.cfm700_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Post-fire bolt-cycle: reload.wav on CHAN_AUTO at +0.567s.
        // Gated by a SEPARATE per-shot tracker (NOT the reload stage
        // variable) so cycling doesn't corrupt mid-reload progress.
        if (elapsed >= CFM700_FIRE_BOLTCYCLE_TIME && !self.cfm700_post_fire_bolt_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm700/reload.WAV", 1, ATTN_NORM);
            self.cfm700_post_fire_bolt_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFM700_RELOAD_CLIPOUT_TIME && self.cfm700_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm700/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfm700_reload_snd_stage = 1;
        }
        if (elapsed >= CFM700_RELOAD_CLIPIN_TIME && self.cfm700_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm700/clipin.WAV", 1, ATTN_NORM);
            self.cfm700_reload_snd_stage = 2;
        }
        if (elapsed >= CFM700_RELOAD_RELOAD_TIME && self.cfm700_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm700/reload.WAV", 1, ATTN_NORM);
            self.cfm700_reload_snd_stage = 3;
        }
    }

    result = SH_CFM700TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFM700_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfm700_reload_snd_stage = 0;
    }
};

void() W_CFM700Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_m700", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(CFM700_VIEWMODEL, CFM700_DISPLAY_NAME, CFM700_SEQ_DRAW,
        CFM700_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFM700Fire;
    self.reload   = W_CFM700Reload;
    self.wepframe = W_CFM700Frame;
    self.shoot    = W_CFM700Shoot;
    self.cfm700_draw_snd_played       = 0;
    self.cfm700_reload_snd_stage      = 0;
    self.cfm700_post_fire_bolt_played = 0;
    W_SetCrosshairProfile(CFM700_BASE_SPREAD, CFM700_MOVE_SPREAD, CFM700_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFM700Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfm700  = self.mag_cfm700;
    tgt.ammo_cfm700 = self.ammo_cfm700;

    self.mag_cfm700  = 0;
    self.ammo_cfm700 = 0;

    setmodel(tgt, CFM700_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfm700";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFM700;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFM700Equip;
    tgt.weap_drop_func = W_CFM700Drop;
    tgt.pickupcopy    = W_CFM700PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfm700 =
{
    setmodel(self, CFM700_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfm700";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFM700;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFM700Equip;
    self.weap_drop_func = W_CFM700Drop;
    self.pickupcopy    = W_CFM700PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfm700  = MAX_MAG_CFM700;
    self.ammo_cfm700 = MAX_AMMO_CFM700;
    W_RegisterMapWeapon(weapon_cfm700);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfm700_draw_snd_played;
float csqc_cfm700_reload_snd_stage;
float csqc_cfm700_post_fire_bolt_played;
float csqc_cfm700_snd_action;

void() CSQC_PredictCFM700Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload / shot
    // fires its events exactly once even when pmove replay re-runs the
    // same buffered command.
    if (predicted_player.wep_action_id != csqc_cfm700_snd_action)
    {
        csqc_cfm700_snd_action            = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfm700_draw_snd_played  = 0;
        csqc_cfm700_reload_snd_stage      = 0;
        csqc_cfm700_post_fire_bolt_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFM700TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Reset post-fire bolt-cycle gate at the start of THIS
            // predicted shot so the mid-fire reload.wav fires once.
            csqc_cfm700_post_fire_bolt_played = 0;
            // Bolt-action scope-rescope suppress — mirror the server.
            self.pm_fire_suppress_until = time + CFM700_FIRE_DELAY;

            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm700/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFM700_BASE_SPREAD, CFM700_MOVE_SPREAD, CFM700_FULL_SPREAD_SPEED,
                    CFM700_CLOSE_DAMAGE, CFM700_MIN_DAMAGE, CFM700_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    CFM700_KICK_PITCH, CFM700_KICK_VARIANCE, CFM700_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Static muzzle flash + smoke, anchored to viewmodel
                // $attachment 0 (Bone01) so position tracks the firing
                // animation.  Tracer start point follows automatically
                // via CSQC_MuzzleFlashWorldPos.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFM700_MUZZLE_BONE, CFM700_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, 4);
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

    // Predicted draw / fire-bolt-cycle / reload sounds — match the
    // server's W_CFM700Frame timings exactly so the dedup window
    // suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfm700_draw_snd_played && elapsed >= CFM700_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfm700/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm700_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            // Mid-fire bolt cycle — reload.wav on CHAN_AUTO at +0.567s.
            // Separate tracker from reload progress (cleared per shot
            // above + on action-id flip).
            if (!csqc_cfm700_post_fire_bolt_played && elapsed >= CFM700_FIRE_BOLTCYCLE_TIME)
            {
                localsound("sounds/weapons/wpn_cfm700/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm700_post_fire_bolt_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfm700_reload_snd_stage < 1 && elapsed >= CFM700_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfm700/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfm700_reload_snd_stage = 1;
            }
            if (csqc_cfm700_reload_snd_stage < 2 && elapsed >= CFM700_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfm700/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm700_reload_snd_stage = 2;
            }
            if (csqc_cfm700_reload_snd_stage < 3 && elapsed >= CFM700_RELOAD_RELOAD_TIME)
            {
                localsound("sounds/weapons/wpn_cfm700/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm700_reload_snd_stage = 3;
            }
        }
    }

    SH_CFM700TickState(csqc_pred_time);
};

void() CSQC_PredictCFM700Reload =
{
    if (SH_CFM700TryReload(csqc_pred_time))
    {
        csqc_cfm700_reload_snd_stage = 0;
        csqc_cfm700_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFM700DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFM700_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFM700_SEQ_SHOOT1;
        return CFM700_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFM700_SEQ_RELOAD;

    return CFM700_SEQ_IDLE;
};

void() CSQC_CFM700DropClear =
{
    self.mag_cfm700  = 0;
    self.ammo_cfm700 = 0;
};

void() CSQC_CFM700Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_m700", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = CFM700_DISPLAY_NAME;
    self.weapon_viewmodel    = CFM700_VIEWMODEL;
    self.weapon_worldmodel   = CFM700_WORLDMODEL;
    self.weapon_deploy_sound = CFM700_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFM700Command;
    self.csqc_predict_reload = CSQC_PredictCFM700Reload;
    self.csqc_display_frame  = CSQC_CFM700DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFM700DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;

    // Muzzle tag — reuse the constants the fire path passes to
    // CSQC_ViewmodelAttachmentWorldPos so cl_viewfx's sway-pivot mode
    // rotates around the same point the flash is anchored to.
    self.weapon_muzzle_bone   = CFM700_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFM700_MUZZLE_OFFSET;

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
        csqc_cfm700_draw_snd_played = 1;
        csqc_cfm700_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
