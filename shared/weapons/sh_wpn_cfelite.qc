// ============================================================
//  shared/weapons/sh_wpn_cfelite.qc  -  Scout Elite (CF series, scout model)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action scout sniper rifle
//          (CoD-scope: scopes out + bolt-rack sound after each shot)
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : CoD-scope eligible (sv_codscopes) — orchestrator hooks
//          cl_codscope.qc against this weapon's display name.  No
//          alt-fire here; CoD-mode owns the scope state externally,
//          same as cfpsg1.
//
//  GoldSrc-format viewmodel (v_scout.mdl) — sequence-driven.  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFAug.
//
//  Sequence layout (from v_scout.mdl source .qc):
//      0  idle      30 fps
//      1  shoot1    (shoot variant A — fire.WAV)
//      2  shoot2    (shoot variant B)
//      3  reload    30 fps  (clipout@6, clipin@22, blowback@37)
//      4  select    20 fps  (draw clack @ frame 3 -> draw.WAV)
//
//  Per-reload sound trackers use SEPARATE fields (.cfelite_draw_snd_played
//  and .cfelite_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFM9 / CSUSP / CSAK47 pattern;
//  see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Semi-auto pacing is enforced by FIRE_DELAY alone — we use
//  SH_StandardTryFire (NOT the SemiAuto edge gate) so players can
//  fire-tap rapidly the way the existing cfpsg1 plays.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfelite;
.float ammo_cfelite;

// --- Per-entity sound stage trackers (server side) ---
.float cfelite_draw_snd_played;
.float cfelite_reload_snd_stage;
.float cfelite_post_fire_bolt_played;   // bolt-cycle rack sound latch (per shot)

// --- Sequence indices ---
const float CFELITE_SEQ_IDLE    = 0;
const float CFELITE_SEQ_SHOOT1  = 1;
const float CFELITE_SEQ_SHOOT2  = 2;
const float CFELITE_SEQ_RELOAD  = 3;
const float CFELITE_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 30 fps:
//   clipout  at frame 6  / 30 = 0.200s   - mag drops out
//   clipin   at frame 22 / 30 = 0.733s   - fresh mag in
//   blowback at frame 37 / 30 = 1.233s   - bolt cycled
// Select sequence @ 20 fps:
//   draw     at frame 3  / 20 = 0.150s   - draw clack
const float CFELITE_RELOAD_CLIPOUT_TIME  = 0.200;
const float CFELITE_RELOAD_CLIPIN_TIME   = 0.733;
const float CFELITE_RELOAD_BLOWBACK_TIME = 1.233;
const float CFELITE_DRAW_CLACK_TIME      = 0.150;
// Bolt-cycle rack sound, ~0.4s after each shot (prefire event 5004 @
// frame 12 / 30fps).  The model's SteyrElite_Reload event = reload.WAV.
const float CFELITE_POST_FIRE_BOLT_TIME  = 0.400;

// Ammo applies right after clipin lands (mag visually seated).
const float CFELITE_RELOAD_APPLY_TIME    = 0.76;

// --- Gameplay tuning ---
// Bolt-action sniper: FIRE_DELAY is the bolt cycle (Scout-fast).  The CoD
// scope drops on every shot and re-forms after the suppress window (see
// pm_fire_suppress_until in the fire paths); weapon_scope_class is set to
// SCOPE_CLASS_SNIPER_BOLT in the equip.
const float CFELITE_FIRE_DELAY        = 0.60;
const float CFELITE_DRYFIRE_DELAY     = 0.20;
const float CFELITE_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFELITE           = 10;
const float MAX_AMMO_CFELITE          = 30;

// --- Balance ---
const float CFELITE_BASE_SPREAD          = 0.01;
const float CFELITE_MOVE_SPREAD          = 0.08;
const float CFELITE_FULL_SPREAD_SPEED    = 320;
const float CFELITE_CLOSE_DAMAGE         = 70;
const float CFELITE_MIN_DAMAGE           = 50;
const float CFELITE_DAMAGE_FALLOFF_RANGE = 3800;
const float CFELITE_KICK_PITCH    = 1.4;   // sv_gunkick — semi-auto sniper.
const float CFELITE_KICK_VARIANCE = 0.4;
const float CFELITE_KICK_STRENGTH = 1.0;   // semi-auto — moderate per-shot delay.

// Muzzle attachment from v_scout.mdl's bone "Box003":
//   bone "Box003" offset 0.0 0.0 0.0
const string CFELITE_MUZZLE_BONE   = "Box003";
#define CFELITE_MUZZLE_OFFSET ('0.0 0.0 0.0')

const string CFELITE_VIEWMODEL    = "models/weapons/wpn_cfelite/v_scout.mdl";
const string CFELITE_WORLDMODEL   = "models/weapons/wpn_cfelite/w_scout.mdl";
const string CFELITE_DEPLOY_SOUND = "";
const string CFELITE_DISPLAY_NAME = "Scout Elite";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFElitePickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFELITE_SEQ_SHOOT1;
    return CFELITE_SEQ_SHOOT2;
};

float(float now) SH_CFEliteTickState =
{
    return SH_StandardTickState(now, mag_cfelite, ammo_cfelite, MAX_MAG_CFELITE,
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFELITE_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_RELOAD, 2.9),
        CFELITE_RELOAD_APPLY_TIME);
};

float(float now) SH_CFEliteTryFire =
{
    // Semi-auto sniper: FIRE_DELAY paces single-shots.  NOT the
    // SemiAuto edge gate — players expect to fire-tap at the rate
    // FIRE_DELAY allows, same as the existing cfpsg1.
    return SH_StandardTryFire(now, mag_cfelite, CFELITE_FIRE_DELAY, CFELITE_DRYFIRE_DELAY);
};

float(float now) SH_CFEliteTryReload =
{
    return SH_StandardTryReload(now, mag_cfelite, ammo_cfelite, MAX_MAG_CFELITE,
        SH_SeqDuration(CFELITE_VIEWMODEL, CFELITE_SEQ_RELOAD, 2.9));
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
        CFELITE_CLOSE_DAMAGE, CFELITE_MIN_DAMAGE, CFELITE_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        CFELITE_KICK_PITCH, CFELITE_KICK_VARIANCE, CFELITE_KICK_STRENGTH);
};

void() W_CFEliteFire =
{
    float r = SH_CFEliteTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFElitePickShootSeq();
        self.wep_nextframe = time + CFELITE_FRAME_INTERVAL;
        self.cfelite_post_fire_bolt_played = 0;
        // Bolt-action scope-rescope: hold the CoD-scope suppress for the
        // full bolt cycle so the scope can't re-form mid-cycle.
        self.pm_fire_suppress_until = time + CFELITE_FIRE_DELAY;

        W_CFEliteShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfelite/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
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
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/draw.WAV", 1, ATTN_NORM);
            self.cfelite_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Bolt-cycle rack sound, once per shot (~0.4s into the prefire).
        if (elapsed >= CFELITE_POST_FIRE_BOLT_TIME && !self.cfelite_post_fire_bolt_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/reload.WAV", 1, ATTN_NORM);
            self.cfelite_post_fire_bolt_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFELITE_RELOAD_CLIPOUT_TIME && self.cfelite_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfelite_reload_snd_stage = 1;
        }
        if (elapsed >= CFELITE_RELOAD_CLIPIN_TIME && self.cfelite_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/clipin.WAV", 1, ATTN_NORM);
            self.cfelite_reload_snd_stage = 2;
        }
        if (elapsed >= CFELITE_RELOAD_BLOWBACK_TIME && self.cfelite_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfelite/blowback.WAV", 1, ATTN_NORM);
            self.cfelite_reload_snd_stage = 3;
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
    W_SetADSProfile(FALSE, "cl_ads_elite", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(CFELITE_VIEWMODEL, CFELITE_DISPLAY_NAME, CFELITE_SEQ_DRAW,
        CFELITE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFEliteFire;
    self.reload   = W_CFEliteReload;
    self.wepframe = W_CFEliteFrame;
    self.shoot    = W_CFEliteShoot;
    self.cfelite_draw_snd_played  = 0;
    self.cfelite_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFELITE_BASE_SPREAD, CFELITE_MOVE_SPREAD, CFELITE_FULL_SPREAD_SPEED, 1.5, FALSE);
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
    tgt.classname     = "weapon_cfelite";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFELITE;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFEliteEquip;
    tgt.weap_drop_func = W_CFEliteDrop;
    tgt.pickupcopy    = W_CFElitePickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfelite =
{
    setmodel(self, CFELITE_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfelite";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFELITE;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFEliteEquip;
    self.weap_drop_func = W_CFEliteDrop;
    self.pickupcopy   = W_CFElitePickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfelite  = MAX_MAG_CFELITE;
    self.ammo_cfelite = MAX_AMMO_CFELITE;
    W_RegisterMapWeapon(weapon_cfelite);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfelite_draw_snd_played;
float csqc_cfelite_reload_snd_stage;
float csqc_cfelite_post_fire_bolt_played;
float csqc_cfelite_snd_action;

void() CSQC_PredictCFEliteCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
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
        // Each shot bumps wep_action_id → re-arm the bolt rack latch.
        csqc_cfelite_post_fire_bolt_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFEliteTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Bolt-action scope-rescope suppress — mirror the server's
            // W_CFEliteFire (cl_codscope compares against `time`, same as
            // cfawm/cfbarrett) so the scope-out edge predicts identically.
            self.pm_fire_suppress_until = time + CFELITE_FIRE_DELAY;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfelite/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFELITE_BASE_SPREAD, CFELITE_MOVE_SPREAD, CFELITE_FULL_SPREAD_SPEED,
                    CFELITE_CLOSE_DAMAGE, CFELITE_MIN_DAMAGE, CFELITE_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    CFELITE_KICK_PITCH, CFELITE_KICK_VARIANCE, CFELITE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Animated muzzle flash — frame-walked variant.  Tune
                // position via CFELITE_MUZZLE_* above, framerate via
                // cl_muzzleflash_anim_fps (default 30).
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFELITE_MUZZLE_BONE, CFELITE_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorldAnimated(muzzle_world, self.wep_action_id);
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

    // Predicted draw / reload sounds — match the server's W_CFEliteFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfelite_draw_snd_played && elapsed >= CFELITE_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            // Predicted bolt-cycle rack sound, mirrors W_CFEliteFrame.
            if (!csqc_cfelite_post_fire_bolt_played && elapsed >= CFELITE_POST_FIRE_BOLT_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_post_fire_bolt_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfelite_reload_snd_stage < 1 && elapsed >= CFELITE_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfelite_reload_snd_stage = 1;
            }
            if (csqc_cfelite_reload_snd_stage < 2 && elapsed >= CFELITE_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_reload_snd_stage = 2;
            }
            if (csqc_cfelite_reload_snd_stage < 3 && elapsed >= CFELITE_RELOAD_BLOWBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfelite/blowback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfelite_reload_snd_stage = 3;
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
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFELITE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFELITE_SEQ_SHOOT1;
        return CFELITE_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFELITE_SEQ_RELOAD;

    return CFELITE_SEQ_IDLE;
};

void() CSQC_CFEliteDropClear =
{
    self.mag_cfelite  = 0;
    self.ammo_cfelite = 0;
};

void() CSQC_CFEliteEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_elite", SCOPE_CLASS_SNIPER_BOLT);
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
    self.weapon_muzzle_bone   = CFELITE_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFELITE_MUZZLE_OFFSET;

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
        csqc_cfelite_draw_snd_played = 1;
        csqc_cfelite_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
