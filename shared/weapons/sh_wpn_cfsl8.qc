// ============================================================
//  shared/weapons/sh_wpn_cfsl8.qc  -  HK SL8 (CF series, primary slot)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 80 reserve, semi-auto marksman 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_sl8.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFScar.  W_CFSl8Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_sl8.mdl):
//      0  idle_0    30 fps
//      1  prefire   30 fps  (shoot variant A — event 5001 fire)
//      2  prefire   30 fps  (shoot variant B)
//      3  reload    24 fps  (clipout @ 9, clipin @ 40)
//      4  select    30 fps  (draw — reload.wav at frame 1)
//
//  The reload sequence has only TWO sound events (clipout + clipin) —
//  there is NO final bolt-rack / reload-tail event on this model.  Two
//  reload events total drive a 3-stage tracker (0..2).  The deploy /
//  select clack REUSES reload.wav (no dedicated draw sound).
//
//  Per-reload sound trackers use SEPARATE fields (.cfsl8_draw_snd_played
//  and .cfsl8_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFM9 / CFScar / CFPSG1 / CSUSP / CSAK47
//  pattern; see the HDAK47 reload-sound bug fix commit for why the
//  single-variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  Muzzle is bone-attached via $attachment 0 "Bone01" (32 0 0) —
//  CSQC_ViewmodelAttachmentWorldPos resolves the world position each
//  shot so the flash tracks the firing animation.  Static
//  CSQC_MuzzleFlashAtWorld (NOT the *Animated frame-walked variant) per
//  spec.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfsl8;
.float ammo_cfsl8;

// --- Per-entity sound stage trackers (server side) ---
.float cfsl8_draw_snd_played;
.float cfsl8_reload_snd_stage;

// --- Sequence indices ---
const float CFSL8_SEQ_IDLE    = 0;
const float CFSL8_SEQ_SHOOT1  = 1;
const float CFSL8_SEQ_SHOOT2  = 2;
const float CFSL8_SEQ_RELOAD  = 3;
const float CFSL8_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 24 fps:
//   clipout at frame  9 / 24 = 0.375s   — mag drops out
//   clipin  at frame 40 / 24 = 1.667s   — fresh mag in
// Select sequence @ 30 fps:
//   clack   at frame  1 / 30 = 0.033s   — draw clack (reuses reload.wav)
const float CFSL8_RELOAD_CLIPOUT_TIME  = 0.375;
const float CFSL8_RELOAD_CLIPIN_TIME   = 1.667;
const float CFSL8_DRAW_CLACK_TIME      = 0.033;

// Ammo applies right after clipin lands (mag visually seated).
const float CFSL8_RELOAD_APPLY_TIME    = 1.67;

// --- Gameplay tuning ---
const float CFSL8_FIRE_DELAY        = 0.150;   // semi-auto, marksman tap rate
const float CFSL8_DRYFIRE_DELAY     = 0.20;
const float CFSL8_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFSL8           = 20;
const float MAX_AMMO_CFSL8          = 80;

// --- Balance ---
const float CFSL8_BASE_SPREAD          = 0.012;
const float CFSL8_MOVE_SPREAD          = 0.07;
const float CFSL8_FULL_SPREAD_SPEED    = 320;
const float CFSL8_CLOSE_DAMAGE         = 40;
const float CFSL8_MIN_DAMAGE           = 28;
const float CFSL8_DAMAGE_FALLOFF_RANGE = 2600;
const float CFSL8_KICK_PITCH    = 0.7;
const float CFSL8_KICK_VARIANCE = 0.35;
const float CFSL8_KICK_STRENGTH = 0.85;

// Muzzle attachment — sourced from the v_sl8.mdl's $attachment 0:
//     $attachment 0 "Bone01" 32 0 0
// Bone name + local-frame offset come straight from the .qc; if the
// muzzle appears in the wrong spot, re-check those values in HLAM /
// the model's .qc and update here, not in camera-local space.
const string CFSL8_MUZZLE_BONE   = "Bone01";
#define CFSL8_MUZZLE_OFFSET ('32 0 0')

const string CFSL8_VIEWMODEL    = "models/weapons/wpn_cfsl8/v_sl8.mdl";
const string CFSL8_WORLDMODEL   = "models/weapons/wpn_cfsl8/w_sl8.mdl";
const string CFSL8_DEPLOY_SOUND = "";
const string CFSL8_DISPLAY_NAME = "SL8";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFSl8PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFSL8_SEQ_SHOOT1;
    return CFSL8_SEQ_SHOOT2;
};

float(float now) SH_CFSl8TickState =
{
    return SH_StandardTickState(now, mag_cfsl8, ammo_cfsl8, MAX_MAG_CFSL8,
        SH_SeqDuration(CFSL8_VIEWMODEL, CFSL8_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFSL8_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFSL8_VIEWMODEL, CFSL8_SEQ_RELOAD, 2.0),
        CFSL8_RELOAD_APPLY_TIME);
};

float(float now) SH_CFSl8TryFire =
{
    // Semi-auto marksman rifle: must release +attack between shots.
    return SH_StandardTryFireSemiAuto(now, mag_cfsl8, CFSL8_FIRE_DELAY, CFSL8_DRYFIRE_DELAY);
};

float(float now) SH_CFSl8TryReload =
{
    return SH_StandardTryReload(now, mag_cfsl8, ammo_cfsl8, MAX_MAG_CFSL8,
        SH_SeqDuration(CFSL8_VIEWMODEL, CFSL8_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFSl8PickupCopy =
{
    player.mag_cfsl8  = self.mag_cfsl8;
    player.ammo_cfsl8 = self.ammo_cfsl8;
};

void() W_CFSl8Shoot =
{
    W_PenetratingHitscanShoot(CFSL8_BASE_SPREAD, CFSL8_MOVE_SPREAD, CFSL8_FULL_SPREAD_SPEED,
        CFSL8_CLOSE_DAMAGE, CFSL8_MIN_DAMAGE, CFSL8_DAMAGE_FALLOFF_RANGE, 32, 0.97,
        CFSL8_KICK_PITCH, CFSL8_KICK_VARIANCE, CFSL8_KICK_STRENGTH);
};

void() W_CFSl8Fire =
{
    float r = SH_CFSl8TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFSl8PickShootSeq();
        self.wep_nextframe = time + CFSL8_FRAME_INTERVAL;

        W_CFSl8Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsl8/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFSl8Reload =
{
    if (SH_CFSl8TryReload(time))
    {
        self.weaponframe   = CFSL8_SEQ_RELOAD;
        self.wep_nextframe = time + CFSL8_FRAME_INTERVAL;
        self.cfsl8_reload_snd_stage = 0;
    }
};

void() W_CFSl8Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFSL8_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFSL8_DRAW_CLACK_TIME && !self.cfsl8_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsl8/reload.WAV", 1, ATTN_NORM);
            self.cfsl8_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFSL8_RELOAD_CLIPOUT_TIME && self.cfsl8_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsl8/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfsl8_reload_snd_stage = 1;
        }
        if (elapsed >= CFSL8_RELOAD_CLIPIN_TIME && self.cfsl8_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsl8/clipin.WAV", 1, ATTN_NORM);
            self.cfsl8_reload_snd_stage = 2;
        }
    }

    result = SH_CFSl8TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFSL8_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfsl8_reload_snd_stage = 0;
    }
};

void() W_CFSl8Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_sl8", SCOPE_CLASS_RIFLE_LOWPOWER);
    W_StandardEquipSetup(CFSL8_VIEWMODEL, CFSL8_DISPLAY_NAME, CFSL8_SEQ_DRAW,
        CFSL8_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFSl8Fire;
    self.reload   = W_CFSl8Reload;
    self.wepframe = W_CFSl8Frame;
    self.shoot    = W_CFSl8Shoot;
    self.cfsl8_draw_snd_played  = 0;
    self.cfsl8_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFSL8_BASE_SPREAD, CFSL8_MOVE_SPREAD, CFSL8_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CFSl8Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfsl8  = self.mag_cfsl8;
    tgt.ammo_cfsl8 = self.ammo_cfsl8;

    self.mag_cfsl8  = 0;
    self.ammo_cfsl8 = 0;

    setmodel(tgt, CFSL8_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfsl8";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFSL8;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFSl8Equip;
    tgt.weap_drop_func = W_CFSl8Drop;
    tgt.pickupcopy    = W_CFSl8PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfsl8 =
{
    setmodel(self, CFSL8_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname    = "weapon_cfsl8";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFSL8;
    self.weapon_slot  = SLOT_PRIMARY;
    self.weap_draw    = W_CFSl8Equip;
    self.weap_drop_func = W_CFSl8Drop;
    self.pickupcopy   = W_CFSl8PickupCopy;
    self.touch        = weapon_touch;
    self.mag_cfsl8  = MAX_MAG_CFSL8;
    self.ammo_cfsl8 = MAX_AMMO_CFSL8;
    W_RegisterMapWeapon(weapon_cfsl8);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfsl8_draw_snd_played;
float csqc_cfsl8_reload_snd_stage;
float csqc_cfsl8_snd_action;

void() CSQC_PredictCFSl8Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfsl8_snd_action)
    {
        csqc_cfsl8_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfsl8_draw_snd_played  = 0;
        csqc_cfsl8_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFSl8TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsl8/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFSL8_BASE_SPREAD, CFSL8_MOVE_SPREAD, CFSL8_FULL_SPREAD_SPEED,
                    CFSL8_CLOSE_DAMAGE, CFSL8_MIN_DAMAGE, CFSL8_DAMAGE_FALLOFF_RANGE, 32, 0.97,
                    CFSL8_KICK_PITCH, CFSL8_KICK_VARIANCE, CFSL8_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle — $attachment 0 "Bone01" + local
                // offset.  Resolved each shot through
                // CSQC_ViewmodelAttachmentWorldPos so the flash and smoke
                // track the firing animation instead of sitting at a
                // hand-tuned camera-local offset.  Static (non-animated)
                // flash variant per spec.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFSL8_MUZZLE_BONE, CFSL8_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFSl8Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfsl8_draw_snd_played && elapsed >= CFSL8_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfsl8/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsl8_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfsl8_reload_snd_stage < 1 && elapsed >= CFSL8_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfsl8/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfsl8_reload_snd_stage = 1;
            }
            if (csqc_cfsl8_reload_snd_stage < 2 && elapsed >= CFSL8_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfsl8/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsl8_reload_snd_stage = 2;
            }
        }
    }

    SH_CFSl8TickState(csqc_pred_time);
};

void() CSQC_PredictCFSl8Reload =
{
    if (SH_CFSl8TryReload(csqc_pred_time))
    {
        csqc_cfsl8_reload_snd_stage = 0;
        csqc_cfsl8_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally.  All branches read predicted_player so the render
// path stays consistent across reconcile.
float(float elapsed) CSQC_CFSl8DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFSL8_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFSL8_SEQ_SHOOT1;
        return CFSL8_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFSL8_SEQ_RELOAD;

    return CFSL8_SEQ_IDLE;
};

void() CSQC_CFSl8DropClear =
{
    self.mag_cfsl8  = 0;
    self.ammo_cfsl8 = 0;
};

void() CSQC_CFSl8Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_sl8", SCOPE_CLASS_RIFLE_LOWPOWER);
    self.weapon_name         = CFSL8_DISPLAY_NAME;
    self.weapon_viewmodel    = CFSL8_VIEWMODEL;
    self.weapon_worldmodel   = CFSL8_WORLDMODEL;
    self.weapon_deploy_sound = CFSL8_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFSl8Command;
    self.csqc_predict_reload = CSQC_PredictCFSl8Reload;
    self.csqc_display_frame  = CSQC_CFSl8DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFSl8DropClear;
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
    self.weapon_muzzle_bone   = CFSL8_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFSL8_MUZZLE_OFFSET;

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
        csqc_cfsl8_draw_snd_played = 1;
        csqc_cfsl8_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
