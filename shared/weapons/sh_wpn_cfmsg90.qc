// ============================================================
//  shared/weapons/sh_wpn_cfmsg90.qc  -  MSG90 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, semi-auto sniper rifle
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : CoD-scope eligible (sv_codscopes) — orchestrator hooks
//          cl_codscope.qc against this weapon's display name.  No
//          alt-fire here; CoD-mode owns the scope state externally,
//          same as cfpsg1 / cfbarrett.
//
//  GoldSrc-format viewmodel (v_msg90.mdl) — sequence-driven.  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFAug / CFPSG1.
//
//  Sequence layout (from v_msg90.mdl source .qc):
//      0  idle      30 fps
//      1  shoot1    (shoot variant A)
//      2  shoot2    (shoot variant B)
//      3  reload    25 fps  (clipout@6, clipin@35, reload@61)
//      4  select    30 fps  (event @ frame 11 -> draw.WAV)
//
//  Per-reload sound trackers use SEPARATE fields (.cfmsg90_draw_snd_played
//  and .cfmsg90_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFM9 / CSUSP / CSAK47 / CFPSG1 pattern;
//  see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Semi-auto pacing is enforced by FIRE_DELAY alone — we use
//  SH_StandardTryFire (NOT the SemiAuto edge gate) so players can
//  fire-tap rapidly the way the existing CFPSG1 plays.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfmsg90;
.float ammo_cfmsg90;

// --- Per-entity sound stage trackers (server side) ---
.float cfmsg90_draw_snd_played;
.float cfmsg90_reload_snd_stage;

// --- Sequence indices ---
const float CFMSG90_SEQ_IDLE    = 0;
const float CFMSG90_SEQ_SHOOT1  = 1;
const float CFMSG90_SEQ_SHOOT2  = 2;
const float CFMSG90_SEQ_RELOAD  = 3;
const float CFMSG90_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 25 fps:
//   clipout at frame  6 / 25 = 0.24s   - mag drops out
//   clipin  at frame 35 / 25 = 1.40s   - fresh mag in
//   reload  at frame 61 / 25 = 2.44s   - charging handle returned
// Select sequence @ 30 fps:
//   draw    at frame 11 / 30 = 0.37s   - draw clack
const float CFMSG90_RELOAD_CLIPOUT_TIME  = 0.24;
const float CFMSG90_RELOAD_CLIPIN_TIME   = 1.40;
const float CFMSG90_RELOAD_TAIL_TIME     = 2.44;
const float CFMSG90_DRAW_CLACK_TIME      = 0.37;

// Ammo applies right after clipin lands (mag visually seated).
const float CFMSG90_RELOAD_APPLY_TIME    = 1.42;

// --- Gameplay tuning ---
// Semi-auto sniper: FIRE_DELAY alone paces single-shots — players can
// tap-fire as fast as 0.30s allows.  See header comment.
const float CFMSG90_FIRE_DELAY        = 0.30;
const float CFMSG90_DRYFIRE_DELAY     = 0.20;
const float CFMSG90_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFMSG90           = 10;
const float MAX_AMMO_CFMSG90          = 30;

// --- Balance ---
const float CFMSG90_BASE_SPREAD          = 0.01;
const float CFMSG90_MOVE_SPREAD          = 0.08;
const float CFMSG90_FULL_SPREAD_SPEED    = 320;
const float CFMSG90_CLOSE_DAMAGE         = 75;
const float CFMSG90_MIN_DAMAGE           = 55;
const float CFMSG90_DAMAGE_FALLOFF_RANGE = 4000;
const float CFMSG90_KICK_PITCH    = 1.4;   // sv_gunkick — semi-auto sniper.
const float CFMSG90_KICK_VARIANCE = 0.4;
const float CFMSG90_KICK_STRENGTH = 1.0;   // semi-auto — moderate per-shot delay.

// Muzzle attachment from v_msg90.mdl's $attachment 0:
//   $attachment 0 "Bone01" 55.0 0.0 0.0
const string CFMSG90_MUZZLE_BONE   = "Bone01";
#define CFMSG90_MUZZLE_OFFSET ('55.0 0.0 0.0')

const string CFMSG90_VIEWMODEL    = "models/weapons/wpn_cfmsg90/v_msg90.mdl";
const string CFMSG90_WORLDMODEL   = "models/weapons/wpn_cfmsg90/w_msg90.mdl";
const string CFMSG90_DEPLOY_SOUND = "";
const string CFMSG90_DISPLAY_NAME = "MSG90";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFMsg90PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFMSG90_SEQ_SHOOT1;
    return CFMSG90_SEQ_SHOOT2;
};

float(float now) SH_CFMsg90TickState =
{
    return SH_StandardTickState(now, mag_cfmsg90, ammo_cfmsg90, MAX_MAG_CFMSG90,
        SH_SeqDuration(CFMSG90_VIEWMODEL, CFMSG90_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFMSG90_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFMSG90_VIEWMODEL, CFMSG90_SEQ_RELOAD, 2.5),
        CFMSG90_RELOAD_APPLY_TIME);
};

float(float now) SH_CFMsg90TryFire =
{
    // Semi-auto sniper: FIRE_DELAY paces single-shots.  NOT the
    // SemiAuto edge gate — players expect to fire-tap at the rate
    // FIRE_DELAY allows, same as the existing CFPSG1.
    return SH_StandardTryFire(now, mag_cfmsg90, CFMSG90_FIRE_DELAY, CFMSG90_DRYFIRE_DELAY);
};

float(float now) SH_CFMsg90TryReload =
{
    return SH_StandardTryReload(now, mag_cfmsg90, ammo_cfmsg90, MAX_MAG_CFMSG90,
        SH_SeqDuration(CFMSG90_VIEWMODEL, CFMSG90_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFMsg90PickupCopy =
{
    player.mag_cfmsg90  = self.mag_cfmsg90;
    player.ammo_cfmsg90 = self.ammo_cfmsg90;
};

void() W_CFMsg90Shoot =
{
    W_PenetratingHitscanShoot(CFMSG90_BASE_SPREAD, CFMSG90_MOVE_SPREAD, CFMSG90_FULL_SPREAD_SPEED,
        CFMSG90_CLOSE_DAMAGE, CFMSG90_MIN_DAMAGE, CFMSG90_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        CFMSG90_KICK_PITCH, CFMSG90_KICK_VARIANCE, CFMSG90_KICK_STRENGTH);
};

void() W_CFMsg90Fire =
{
    float r = SH_CFMsg90TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFMsg90PickShootSeq();
        self.wep_nextframe = time + CFMSG90_FRAME_INTERVAL;

        W_CFMsg90Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmsg90/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFMsg90Reload =
{
    if (SH_CFMsg90TryReload(time))
    {
        self.weaponframe   = CFMSG90_SEQ_RELOAD;
        self.wep_nextframe = time + CFMSG90_FRAME_INTERVAL;
        self.cfmsg90_reload_snd_stage = 0;
    }
};

void() W_CFMsg90Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFMSG90_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFMSG90_DRAW_CLACK_TIME && !self.cfmsg90_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmsg90/draw.WAV", 1, ATTN_NORM);
            self.cfmsg90_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFMSG90_RELOAD_CLIPOUT_TIME && self.cfmsg90_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmsg90/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfmsg90_reload_snd_stage = 1;
        }
        if (elapsed >= CFMSG90_RELOAD_CLIPIN_TIME && self.cfmsg90_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmsg90/clipin.WAV", 1, ATTN_NORM);
            self.cfmsg90_reload_snd_stage = 2;
        }
        if (elapsed >= CFMSG90_RELOAD_TAIL_TIME && self.cfmsg90_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmsg90/reload.WAV", 1, ATTN_NORM);
            self.cfmsg90_reload_snd_stage = 3;
        }
    }

    result = SH_CFMsg90TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFMSG90_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfmsg90_reload_snd_stage = 0;
    }
};

void() W_CFMsg90Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_msg90", SCOPE_CLASS_SNIPER_SEMI);
    W_StandardEquipSetup(CFMSG90_VIEWMODEL, CFMSG90_DISPLAY_NAME, CFMSG90_SEQ_DRAW,
        CFMSG90_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFMsg90Fire;
    self.reload   = W_CFMsg90Reload;
    self.wepframe = W_CFMsg90Frame;
    self.shoot    = W_CFMsg90Shoot;
    self.cfmsg90_draw_snd_played  = 0;
    self.cfmsg90_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFMSG90_BASE_SPREAD, CFMSG90_MOVE_SPREAD, CFMSG90_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFMsg90Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfmsg90  = self.mag_cfmsg90;
    tgt.ammo_cfmsg90 = self.ammo_cfmsg90;

    self.mag_cfmsg90  = 0;
    self.ammo_cfmsg90 = 0;

    setmodel(tgt, CFMSG90_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfmsg90";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFMSG90;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFMsg90Equip;
    tgt.weap_drop_func = W_CFMsg90Drop;
    tgt.pickupcopy    = W_CFMsg90PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfmsg90 =
{
    setmodel(self, CFMSG90_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfmsg90";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFMSG90;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFMsg90Equip;
    self.weap_drop_func = W_CFMsg90Drop;
    self.pickupcopy   = W_CFMsg90PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfmsg90  = MAX_MAG_CFMSG90;
    self.ammo_cfmsg90 = MAX_AMMO_CFMSG90;
    W_RegisterMapWeapon(weapon_cfmsg90);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfmsg90_draw_snd_played;
float csqc_cfmsg90_reload_snd_stage;
float csqc_cfmsg90_snd_action;

void() CSQC_PredictCFMsg90Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfmsg90_snd_action)
    {
        csqc_cfmsg90_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfmsg90_draw_snd_played  = 0;
        csqc_cfmsg90_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFMsg90TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmsg90/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFMSG90_BASE_SPREAD, CFMSG90_MOVE_SPREAD, CFMSG90_FULL_SPREAD_SPEED,
                    CFMSG90_CLOSE_DAMAGE, CFMSG90_MIN_DAMAGE, CFMSG90_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    CFMSG90_KICK_PITCH, CFMSG90_KICK_VARIANCE, CFMSG90_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Animated muzzle flash — frame-walked variant.  Tune
                // position via CFMSG90_MUZZLE_* above, framerate via
                // cl_muzzleflash_anim_fps (default 30).
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFMSG90_MUZZLE_BONE, CFMSG90_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFMsg90Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfmsg90_draw_snd_played && elapsed >= CFMSG90_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfmsg90/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmsg90_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfmsg90_reload_snd_stage < 1 && elapsed >= CFMSG90_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfmsg90/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfmsg90_reload_snd_stage = 1;
            }
            if (csqc_cfmsg90_reload_snd_stage < 2 && elapsed >= CFMSG90_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfmsg90/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmsg90_reload_snd_stage = 2;
            }
            if (csqc_cfmsg90_reload_snd_stage < 3 && elapsed >= CFMSG90_RELOAD_TAIL_TIME)
            {
                localsound("sounds/weapons/wpn_cfmsg90/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmsg90_reload_snd_stage = 3;
            }
        }
    }

    SH_CFMsg90TickState(csqc_pred_time);
};

void() CSQC_PredictCFMsg90Reload =
{
    if (SH_CFMsg90TryReload(csqc_pred_time))
    {
        csqc_cfmsg90_reload_snd_stage = 0;
        csqc_cfmsg90_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFMsg90DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFMSG90_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFMSG90_SEQ_SHOOT1;
        return CFMSG90_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFMSG90_SEQ_RELOAD;

    return CFMSG90_SEQ_IDLE;
};

void() CSQC_CFMsg90DropClear =
{
    self.mag_cfmsg90  = 0;
    self.ammo_cfmsg90 = 0;
};

void() CSQC_CFMsg90Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_msg90", SCOPE_CLASS_SNIPER_SEMI);
    self.weapon_name         = CFMSG90_DISPLAY_NAME;
    self.weapon_viewmodel    = CFMSG90_VIEWMODEL;
    self.weapon_worldmodel   = CFMSG90_WORLDMODEL;
    self.weapon_deploy_sound = CFMSG90_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFMsg90Command;
    self.csqc_predict_reload = CSQC_PredictCFMsg90Reload;
    self.csqc_display_frame  = CSQC_CFMsg90DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFMsg90DropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFMSG90_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFMSG90_MUZZLE_OFFSET;

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
        csqc_cfmsg90_draw_snd_played = 1;
        csqc_cfmsg90_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
