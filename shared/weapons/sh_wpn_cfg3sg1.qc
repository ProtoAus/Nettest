// ============================================================
//  shared/weapons/sh_wpn_cfg3sg1.qc  -  PSG1 (CF series, G3SG1 model)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 60 reserve, semi-auto sniper rifle
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : CoD-scope eligible (sv_codscopes) — orchestrator hooks
//          cl_codscope.qc against this weapon's display name.  No
//          alt-fire here; CoD-mode owns the scope state externally,
//          same as cfawp.
//
//  GoldSrc-format viewmodel (v_g3sg1.mdl) — sequence-driven.  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFFiveSeven /
//  CFAug.
//
//  Sequence layout (from v_g3sg1.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   40 fps  (shoot variant A — event 5001 "12")
//      2  prefire   40 fps  (shoot variant B)
//      3  reload    28 fps  (cy@10, clipout@29, clipin@51, bcy@78)
//      4  select    37 fps  (event @ frame 17 -> reload.WAV)
//
//  Per-reload sound trackers use SEPARATE fields (.cfg3sg1_draw_snd_played
//  and .cfg3sg1_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFFiveSeven / CSUSP / CSAK47 pattern;
//  see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Semi-auto pacing is enforced by FIRE_DELAY alone — we use
//  SH_StandardTryFire (NOT the SemiAuto edge gate) so players can
//  fire-tap rapidly the way the existing CSG3SG1 plays.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfg3sg1;
.float ammo_cfg3sg1;

// --- Per-entity sound stage trackers (server side) ---
.float cfg3sg1_draw_snd_played;
.float cfg3sg1_reload_snd_stage;

// --- Sequence indices ---
const float CFG3SG1_SEQ_IDLE    = 0;
const float CFG3SG1_SEQ_SHOOT1  = 1;
const float CFG3SG1_SEQ_SHOOT2  = 2;
const float CFG3SG1_SEQ_RELOAD  = 3;
const float CFG3SG1_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 28 fps:
//   cy      at frame 10 / 28 = 0.357s   - charging handle pulled
//   clipout at frame 29 / 28 = 1.036s   - mag drops out
//   clipin  at frame 51 / 28 = 1.821s   - fresh mag in
//   bcy     at frame 78 / 28 = 2.786s   - charging handle returned
// Select sequence @ 37 fps:
//   reload  at frame 17 / 37 = 0.459s   - draw clack
const float CFG3SG1_RELOAD_CY_TIME       = 0.357;
const float CFG3SG1_RELOAD_CLIPOUT_TIME  = 1.036;
const float CFG3SG1_RELOAD_CLIPIN_TIME   = 1.821;
const float CFG3SG1_RELOAD_BCY_TIME      = 2.786;
const float CFG3SG1_DRAW_CLACK_TIME      = 0.459;

// Ammo applies right after clipin lands (mag visually seated).
const float CFG3SG1_RELOAD_APPLY_TIME    = 1.85;

// --- Gameplay tuning ---
// Semi-auto sniper: FIRE_DELAY alone paces single-shots — players can
// tap-fire as fast as 0.30s allows.  See header comment.
const float CFG3SG1_FIRE_DELAY        = 0.30;
const float CFG3SG1_DRYFIRE_DELAY     = 0.20;
const float CFG3SG1_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFG3SG1           = 20;
const float MAX_AMMO_CFG3SG1          = 60;

// --- Balance ---
const float CFG3SG1_BASE_SPREAD          = 0.01;
const float CFG3SG1_MOVE_SPREAD          = 0.08;
const float CFG3SG1_FULL_SPREAD_SPEED    = 320;
const float CFG3SG1_CLOSE_DAMAGE         = 80;
const float CFG3SG1_MIN_DAMAGE           = 50;
const float CFG3SG1_DAMAGE_FALLOFF_RANGE = 4096;
const float CFG3SG1_KICK_PITCH    = 1.4;   // sv_gunkick — semi-auto sniper.
const float CFG3SG1_KICK_VARIANCE = 0.4;
const float CFG3SG1_KICK_STRENGTH = 1.0;   // semi-auto — moderate per-shot delay.

// Camera-local muzzle offset — no $attachment dump available for this
// model yet, so the flash is anchored to a camera-relative point
// rather than the bone.  Rifle-scale numbers (matches CSG3SG1 /
// CFAug ranges).  If the user later supplies $attachment 0 data for
// v_g3sg1.mdl, swap these for the bone-attached pattern.
// Muzzle attachment from v_g3sg1.mdl's $attachment 0:
//   $attachment 0 "Bone01" 58.0 0.0 0.0
const string CFG3SG1_MUZZLE_BONE   = "Bone01";
#define CFG3SG1_MUZZLE_OFFSET ('58.0 0.0 0.0')

const string CFG3SG1_VIEWMODEL    = "models/weapons/wpn_cfg3sg1/v_g3sg1.mdl";
const string CFG3SG1_WORLDMODEL   = "models/weapons/wpn_cfg3sg1/w_g3sg1.mdl";
const string CFG3SG1_DEPLOY_SOUND = "";
const string CFG3SG1_DISPLAY_NAME = "PSG1";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFG3SG1PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFG3SG1_SEQ_SHOOT1;
    return CFG3SG1_SEQ_SHOOT2;
};

float(float now) SH_CFG3SG1TickState =
{
    return SH_StandardTickState(now, mag_cfg3sg1, ammo_cfg3sg1, MAX_MAG_CFG3SG1,
        SH_SeqDuration(CFG3SG1_VIEWMODEL, CFG3SG1_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFG3SG1_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFG3SG1_VIEWMODEL, CFG3SG1_SEQ_RELOAD, 2.9),
        CFG3SG1_RELOAD_APPLY_TIME);
};

float(float now) SH_CFG3SG1TryFire =
{
    // Semi-auto sniper: FIRE_DELAY paces single-shots.  NOT the
    // SemiAuto edge gate — players expect to fire-tap at the rate
    // FIRE_DELAY allows, same as the existing CSG3SG1.
    return SH_StandardTryFire(now, mag_cfg3sg1, CFG3SG1_FIRE_DELAY, CFG3SG1_DRYFIRE_DELAY);
};

float(float now) SH_CFG3SG1TryReload =
{
    return SH_StandardTryReload(now, mag_cfg3sg1, ammo_cfg3sg1, MAX_MAG_CFG3SG1,
        SH_SeqDuration(CFG3SG1_VIEWMODEL, CFG3SG1_SEQ_RELOAD, 2.9));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFG3SG1PickupCopy =
{
    player.mag_cfg3sg1  = self.mag_cfg3sg1;
    player.ammo_cfg3sg1 = self.ammo_cfg3sg1;
};

void() W_CFG3SG1Shoot =
{
    W_PenetratingHitscanShoot(CFG3SG1_BASE_SPREAD, CFG3SG1_MOVE_SPREAD, CFG3SG1_FULL_SPREAD_SPEED,
        CFG3SG1_CLOSE_DAMAGE, CFG3SG1_MIN_DAMAGE, CFG3SG1_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        CFG3SG1_KICK_PITCH, CFG3SG1_KICK_VARIANCE, CFG3SG1_KICK_STRENGTH);
};

void() W_CFG3SG1Fire =
{
    float r = SH_CFG3SG1TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFG3SG1PickShootSeq();
        self.wep_nextframe = time + CFG3SG1_FRAME_INTERVAL;

        W_CFG3SG1Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfg3sg1/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFG3SG1Reload =
{
    if (SH_CFG3SG1TryReload(time))
    {
        self.weaponframe   = CFG3SG1_SEQ_RELOAD;
        self.wep_nextframe = time + CFG3SG1_FRAME_INTERVAL;
        self.cfg3sg1_reload_snd_stage = 0;
    }
};

void() W_CFG3SG1Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFG3SG1_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFG3SG1_DRAW_CLACK_TIME && !self.cfg3sg1_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfg3sg1/reload.WAV", 1, ATTN_NORM);
            self.cfg3sg1_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFG3SG1_RELOAD_CY_TIME && self.cfg3sg1_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfg3sg1/cy.WAV", 1, ATTN_NORM);
            self.cfg3sg1_reload_snd_stage = 1;
        }
        if (elapsed >= CFG3SG1_RELOAD_CLIPOUT_TIME && self.cfg3sg1_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfg3sg1/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfg3sg1_reload_snd_stage = 2;
        }
        if (elapsed >= CFG3SG1_RELOAD_CLIPIN_TIME && self.cfg3sg1_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfg3sg1/clipin.WAV", 1, ATTN_NORM);
            self.cfg3sg1_reload_snd_stage = 3;
        }
        if (elapsed >= CFG3SG1_RELOAD_BCY_TIME && self.cfg3sg1_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfg3sg1/bcy.WAV", 1, ATTN_NORM);
            self.cfg3sg1_reload_snd_stage = 4;
        }
    }

    result = SH_CFG3SG1TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFG3SG1_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfg3sg1_reload_snd_stage = 0;
    }
};

void() W_CFG3SG1Equip =
{
    W_StandardEquipSetup(CFG3SG1_VIEWMODEL, CFG3SG1_DISPLAY_NAME, CFG3SG1_SEQ_DRAW,
        CFG3SG1_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFG3SG1Fire;
    self.reload   = W_CFG3SG1Reload;
    self.wepframe = W_CFG3SG1Frame;
    self.shoot    = W_CFG3SG1Shoot;
    self.cfg3sg1_draw_snd_played  = 0;
    self.cfg3sg1_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFG3SG1_BASE_SPREAD, CFG3SG1_MOVE_SPREAD, CFG3SG1_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFG3SG1Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfg3sg1  = self.mag_cfg3sg1;
    tgt.ammo_cfg3sg1 = self.ammo_cfg3sg1;

    self.mag_cfg3sg1  = 0;
    self.ammo_cfg3sg1 = 0;

    setmodel(tgt, CFG3SG1_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfg3sg1";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFG3SG1;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFG3SG1Equip;
    tgt.weap_drop_func = W_CFG3SG1Drop;
    tgt.pickupcopy    = W_CFG3SG1PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfg3sg1 =
{
    setmodel(self, CFG3SG1_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfg3sg1";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFG3SG1;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFG3SG1Equip;
    self.weap_drop_func = W_CFG3SG1Drop;
    self.pickupcopy   = W_CFG3SG1PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfg3sg1  = MAX_MAG_CFG3SG1;
    self.ammo_cfg3sg1 = MAX_AMMO_CFG3SG1;
    W_RegisterMapWeapon(weapon_cfg3sg1);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfg3sg1_draw_snd_played;
float csqc_cfg3sg1_reload_snd_stage;
float csqc_cfg3sg1_snd_action;

void() CSQC_PredictCFG3SG1Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfg3sg1_snd_action)
    {
        csqc_cfg3sg1_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfg3sg1_draw_snd_played  = 0;
        csqc_cfg3sg1_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFG3SG1TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfg3sg1/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFG3SG1_BASE_SPREAD, CFG3SG1_MOVE_SPREAD, CFG3SG1_FULL_SPREAD_SPEED,
                    CFG3SG1_CLOSE_DAMAGE, CFG3SG1_MIN_DAMAGE, CFG3SG1_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    CFG3SG1_KICK_PITCH, CFG3SG1_KICK_VARIANCE, CFG3SG1_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Animated muzzle flash — frame-walked variant.  Tune
                // position via CFG3SG1_MUZZLE_* above, framerate via
                // cl_muzzleflash_anim_fps (default 30).
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFG3SG1_MUZZLE_BONE, CFG3SG1_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFG3SG1Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfg3sg1_draw_snd_played && elapsed >= CFG3SG1_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfg3sg1/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfg3sg1_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfg3sg1_reload_snd_stage < 1 && elapsed >= CFG3SG1_RELOAD_CY_TIME)
            {
                localsound("sounds/weapons/wpn_cfg3sg1/cy.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfg3sg1_reload_snd_stage = 1;
            }
            if (csqc_cfg3sg1_reload_snd_stage < 2 && elapsed >= CFG3SG1_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfg3sg1/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfg3sg1_reload_snd_stage = 2;
            }
            if (csqc_cfg3sg1_reload_snd_stage < 3 && elapsed >= CFG3SG1_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfg3sg1/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfg3sg1_reload_snd_stage = 3;
            }
            if (csqc_cfg3sg1_reload_snd_stage < 4 && elapsed >= CFG3SG1_RELOAD_BCY_TIME)
            {
                localsound("sounds/weapons/wpn_cfg3sg1/bcy.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfg3sg1_reload_snd_stage = 4;
            }
        }
    }

    SH_CFG3SG1TickState(csqc_pred_time);
};

void() CSQC_PredictCFG3SG1Reload =
{
    if (SH_CFG3SG1TryReload(csqc_pred_time))
    {
        csqc_cfg3sg1_reload_snd_stage = 0;
        csqc_cfg3sg1_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFG3SG1DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFG3SG1_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFG3SG1_SEQ_SHOOT1;
        return CFG3SG1_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFG3SG1_SEQ_RELOAD;

    return CFG3SG1_SEQ_IDLE;
};

void() CSQC_CFG3SG1DropClear =
{
    self.mag_cfg3sg1  = 0;
    self.ammo_cfg3sg1 = 0;
};

void() CSQC_CFG3SG1Equip =
{
    self.weapon_name         = CFG3SG1_DISPLAY_NAME;
    self.weapon_viewmodel    = CFG3SG1_VIEWMODEL;
    self.weapon_worldmodel   = CFG3SG1_WORLDMODEL;
    self.weapon_deploy_sound = CFG3SG1_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFG3SG1Command;
    self.csqc_predict_reload = CSQC_PredictCFG3SG1Reload;
    self.csqc_display_frame  = CSQC_CFG3SG1DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFG3SG1DropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFG3SG1_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFG3SG1_MUZZLE_OFFSET;

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
        csqc_cfg3sg1_draw_snd_played = 1;
        csqc_cfg3sg1_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
