// ============================================================
//  shared/weapons/sh_wpn_cfp228.qc  -  SIG P228 (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 13-round magazine, 52 reserve, semi-auto 9mm
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_p228.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as CFM9 / HDAK47 / CSUSP.
//
//  Sequence layout (from v_p228.mdl source .qc):
//      0  idle      30 fps
//      1  shoot1    50 fps  (prefire — event 5001 fire)
//      2  shoot2    50 fps  (prefire — event 5001 fire)
//      3  shoot3    50 fps  (prefire — event 5001 fire)
//      4  shoot4    50 fps  (prefire — event 5001 fire)
//      5  reload    25 fps  (bback@0, clipout@10, clipin@34, bcback@51)
//      6  select    30 fps  (draw — reload.WAV at frame 1)
//
//  FTE does NOT auto-play $sequence event 5001 / 5004 markers; sound
//  events are driven from QC against wep_anim_start elapsed time.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable like the original HDAK47).  This is the
//  CFM9 / CSUSP pattern — see the HDAK47 reload-sound bug fix commit
//  for why the single-variable approach corrupts state under the
//  every-reconcile CSQC_WeaponEquip call.
//
//  Muzzle is bone-attached.  The bone name in v_p228.mdl is "Bone01";
//  local offset is (8.6 0 1.1).  If the flash appears off, re-check the
//  model's $attachment dump and update HERE rather than overriding in
//  camera-local space.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfp228;
.float ammo_cfp228;

// --- Per-entity sound stage trackers (server side) ---
.float cfp228_draw_snd_played;
.float cfp228_reload_snd_stage;

// --- Sequence indices ---
const float CFP228_SEQ_IDLE    = 0;
const float CFP228_SEQ_SHOOT1  = 1;
const float CFP228_SEQ_SHOOT2  = 2;
const float CFP228_SEQ_SHOOT3  = 3;
const float CFP228_SEQ_SHOOT4  = 4;
const float CFP228_SEQ_RELOAD  = 5;
const float CFP228_SEQ_DRAW    = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 25 fps:
//   bback   at frame  0 / 25 = 0.000s   — initial slide back
//   clipout at frame 10 / 25 = 0.400s   — mag drops out
//   clipin  at frame 34 / 25 = 1.360s   — fresh mag in
//   bcback  at frame 51 / 25 = 2.040s   — slide forward (chamber)
// Select sequence @ 30 fps:
//   reload  at frame  1 / 30 = 0.033s   — draw clack
const float CFP228_RELOAD_BBACK_TIME    = 0.000;
const float CFP228_RELOAD_CLIPOUT_TIME  = 0.400;
const float CFP228_RELOAD_CLIPIN_TIME   = 1.360;
const float CFP228_RELOAD_BCBACK_TIME   = 2.040;
const float CFP228_DRAW_CLACK_TIME      = 0.033;

// Ammo applies right after clipin lands (mag visually seated).
const float CFP228_RELOAD_APPLY_TIME    = 1.36;

// --- Gameplay tuning ---
const float CFP228_FIRE_DELAY        = 0.150;   // semi-auto, tap rate
const float CFP228_DRYFIRE_DELAY     = 0.20;
const float CFP228_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFP228           = 13;
const float MAX_AMMO_CFP228          = 52;

// --- Balance ---
const float CFP228_BASE_SPREAD          = 0.011;
const float CFP228_MOVE_SPREAD          = 0.058;
const float CFP228_FULL_SPREAD_SPEED    = 320;
const float CFP228_CLOSE_DAMAGE         = 28;
const float CFP228_MIN_DAMAGE           = 16;
const float CFP228_DAMAGE_FALLOFF_RANGE = 1900;
const float CFP228_KICK_PITCH    = 0.55;
const float CFP228_KICK_VARIANCE = 0.35;
const float CFP228_KICK_STRENGTH = 0.7;

// Muzzle attachment from v_p228.mdl's $attachment 0:
//   $attachment 0 "Bone01" 8.6 0.0 1.1
const string CFP228_MUZZLE_BONE   = "Bone01";
#define CFP228_MUZZLE_OFFSET ('8.6 0 1.1')

const string CFP228_VIEWMODEL    = "models/weapons/wpn_cfp228/v_p228.mdl";
const string CFP228_WORLDMODEL   = "models/weapons/wpn_cfp228/w_p228.mdl";
const string CFP228_DEPLOY_SOUND = "";
const string CFP228_DISPLAY_NAME = "P228";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3/4 plays for this shot.
float() SH_CFP228PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.25) return CFP228_SEQ_SHOOT1;
    if (r < 0.50) return CFP228_SEQ_SHOOT2;
    if (r < 0.75) return CFP228_SEQ_SHOOT3;
    return CFP228_SEQ_SHOOT4;
};

float(float now) SH_CFP228TickState =
{
    return SH_StandardTickState(now, mag_cfp228, ammo_cfp228, MAX_MAG_CFP228,
        SH_SeqDuration(CFP228_VIEWMODEL, CFP228_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFP228_VIEWMODEL, self.weaponframe,  0.3),
        SH_SeqDuration(CFP228_VIEWMODEL, CFP228_SEQ_RELOAD, 2.5),
        CFP228_RELOAD_APPLY_TIME);
};

float(float now) SH_CFP228TryFire =
{
    // Semi-auto: must release +attack between shots.
    return SH_StandardTryFireSemiAuto(now, mag_cfp228, CFP228_FIRE_DELAY, CFP228_DRYFIRE_DELAY);
};

float(float now) SH_CFP228TryReload =
{
    return SH_StandardTryReload(now, mag_cfp228, ammo_cfp228, MAX_MAG_CFP228,
        SH_SeqDuration(CFP228_VIEWMODEL, CFP228_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFP228PickupCopy =
{
    player.mag_cfp228  = self.mag_cfp228;
    player.ammo_cfp228 = self.ammo_cfp228;
};

void() W_CFP228Shoot =
{
    W_PenetratingHitscanShoot(CFP228_BASE_SPREAD, CFP228_MOVE_SPREAD, CFP228_FULL_SPREAD_SPEED,
        CFP228_CLOSE_DAMAGE, CFP228_MIN_DAMAGE, CFP228_DAMAGE_FALLOFF_RANGE, 28, 0.94,
        CFP228_KICK_PITCH, CFP228_KICK_VARIANCE, CFP228_KICK_STRENGTH);
};

void() W_CFP228Fire =
{
    float r = SH_CFP228TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFP228PickShootSeq();
        self.wep_nextframe = time + CFP228_FRAME_INTERVAL;

        W_CFP228Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfp228/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFP228Reload =
{
    if (SH_CFP228TryReload(time))
    {
        self.weaponframe   = CFP228_SEQ_RELOAD;
        self.wep_nextframe = time + CFP228_FRAME_INTERVAL;
        self.cfp228_reload_snd_stage = 0;
    }
};

void() W_CFP228Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFP228_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFP228_DRAW_CLACK_TIME && !self.cfp228_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfp228/reload.WAV", 1, ATTN_NORM);
            self.cfp228_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFP228_RELOAD_BBACK_TIME && self.cfp228_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfp228/bback.WAV", 1, ATTN_NORM);
            self.cfp228_reload_snd_stage = 1;
        }
        if (elapsed >= CFP228_RELOAD_CLIPOUT_TIME && self.cfp228_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfp228/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.cfp228_reload_snd_stage = 2;
        }
        if (elapsed >= CFP228_RELOAD_CLIPIN_TIME && self.cfp228_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfp228/clipin.WAV", 1, ATTN_NORM);
            self.cfp228_reload_snd_stage = 3;
        }
        if (elapsed >= CFP228_RELOAD_BCBACK_TIME && self.cfp228_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfp228/bcback.WAV", 1, ATTN_NORM);
            self.cfp228_reload_snd_stage = 4;
        }
    }

    result = SH_CFP228TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFP228_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfp228_reload_snd_stage = 0;
    }
};

void() W_CFP228Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_p228", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFP228_VIEWMODEL, CFP228_DISPLAY_NAME, CFP228_SEQ_DRAW,
        CFP228_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFP228Fire;
    self.reload   = W_CFP228Reload;
    self.wepframe = W_CFP228Frame;
    self.shoot    = W_CFP228Shoot;
    self.cfp228_draw_snd_played  = 0;
    self.cfp228_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFP228_BASE_SPREAD, CFP228_MOVE_SPREAD, CFP228_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFP228Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfp228  = self.mag_cfp228;
    tgt.ammo_cfp228 = self.ammo_cfp228;

    self.mag_cfp228  = 0;
    self.ammo_cfp228 = 0;

    setmodel(tgt, CFP228_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfp228";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFP228;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFP228Equip;
    tgt.weap_drop_func = W_CFP228Drop;
    tgt.pickupcopy   = W_CFP228PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfp228 =
{
    setmodel(self, CFP228_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfp228";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFP228;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFP228Equip;
    self.weap_drop_func = W_CFP228Drop;
    self.pickupcopy    = W_CFP228PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfp228  = MAX_MAG_CFP228;
    self.ammo_cfp228 = MAX_AMMO_CFP228;
    W_RegisterMapWeapon(weapon_cfp228);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfp228_draw_snd_played;
float csqc_cfp228_reload_snd_stage;
float csqc_cfp228_snd_action;

void() CSQC_PredictCFP228Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfp228_snd_action)
    {
        csqc_cfp228_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfp228_draw_snd_played  = 0;
        csqc_cfp228_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFP228TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfp228/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFP228_BASE_SPREAD, CFP228_MOVE_SPREAD, CFP228_FULL_SPREAD_SPEED,
                    CFP228_CLOSE_DAMAGE, CFP228_MIN_DAMAGE, CFP228_DAMAGE_FALLOFF_RANGE, 28, 0.94,
                    CFP228_KICK_PITCH, CFP228_KICK_VARIANCE, CFP228_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFP228_MUZZLE_BONE, CFP228_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFP228Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfp228_draw_snd_played && elapsed >= CFP228_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfp228/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfp228_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfp228_reload_snd_stage < 1 && elapsed >= CFP228_RELOAD_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfp228/bback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfp228_reload_snd_stage = 1;
            }
            if (csqc_cfp228_reload_snd_stage < 2 && elapsed >= CFP228_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfp228/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfp228_reload_snd_stage = 2;
            }
            if (csqc_cfp228_reload_snd_stage < 3 && elapsed >= CFP228_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfp228/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfp228_reload_snd_stage = 3;
            }
            if (csqc_cfp228_reload_snd_stage < 4 && elapsed >= CFP228_RELOAD_BCBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfp228/bcback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfp228_reload_snd_stage = 4;
            }
        }
    }

    SH_CFP228TickState(csqc_pred_time);
};

void() CSQC_PredictCFP228Reload =
{
    if (SH_CFP228TryReload(csqc_pred_time))
    {
        csqc_cfp228_reload_snd_stage = 0;
        csqc_cfp228_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFP228DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFP228_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.25) return CFP228_SEQ_SHOOT1;
        if (r < 0.50) return CFP228_SEQ_SHOOT2;
        if (r < 0.75) return CFP228_SEQ_SHOOT3;
        return CFP228_SEQ_SHOOT4;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFP228_SEQ_RELOAD;

    return CFP228_SEQ_IDLE;
};

void() CSQC_CFP228DropClear =
{
    self.mag_cfp228  = 0;
    self.ammo_cfp228 = 0;
};

void() CSQC_CFP228Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_p228", SCOPE_CLASS_NONE);
    self.weapon_name         = CFP228_DISPLAY_NAME;
    self.weapon_viewmodel    = CFP228_VIEWMODEL;
    self.weapon_worldmodel   = CFP228_WORLDMODEL;
    self.weapon_deploy_sound = CFP228_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFP228Command;
    self.csqc_predict_reload = CSQC_PredictCFP228Reload;
    self.csqc_display_frame  = CSQC_CFP228DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFP228DropClear;
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFP228_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFP228_MUZZLE_OFFSET;

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
        csqc_cfp228_draw_snd_played = 1;
        csqc_cfp228_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
