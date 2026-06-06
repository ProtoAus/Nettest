// ============================================================
//  shared/weapons/sh_wpn_cfsvd.qc  -  SVD Dragunov (CF series, SG550 slot)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, semi-auto sniper rifle
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : CoD-scope eligible (sv_codscopes) — orchestrator hooks
//          cl_codscope.qc against this weapon's display name.  No
//          alt-fire here; CoD-mode owns the scope state externally,
//          same as cfbarrett / cfpsg1.  Orchestrator excludes this weapon
//          from the post-fire scope-suppression list (semi-auto can
//          tap-fire without breaking the scope between shots).
//
//  GoldSrc-format viewmodel (v_dragunov.mdl) — sequence-driven.  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFPSG1 / CFBarrett.
//
//  Sequence layout (from v_dragunov.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   30 fps  (shoot variant A — event 5001 "12")
//      2  prefire   30 fps  (shoot variant B)
//      3  reload    17 fps  (clipout @ 7, clipin @ 22, reload @ 44 final rack)
//      4  select    30 fps  (event @ frame 14 -> reload.WAV draw clack)
//
//  Per-reload sound trackers use SEPARATE fields (.cfsvd_draw_snd_played
//  and .cfsvd_reload_snd_stage) — NOT a single collapsed stage
//  variable.  This is the CFPSG1 / CFBarrett pattern; see the HDAK47
//  reload-sound bug fix commit for why the single-variable approach
//  corrupts state under the every-reconcile CSQC_WeaponEquip call.
//
//  Semi-auto pacing is enforced by FIRE_DELAY alone — we use
//  SH_StandardTryFire (NOT the SemiAuto edge gate) so players can
//  fire-tap rapidly the way the existing CSG3SG1 / CFPSG1 play.
//
//  Muzzle attachment — sourced from the v_dragunov.mdl's $attachment 0:
//      $attachment 0 "Bone01" 31.0 0.0 0.0
//  Static flash (CSQC_MuzzleFlashAtWorld) suits the heavy semi-auto
//  feel — same intensity per shot rather than the animated burst used
//  on full-auto rifles.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfsvd;
.float ammo_cfsvd;

// --- Per-entity sound stage trackers (server side) ---
.float cfsvd_draw_snd_played;
.float cfsvd_reload_snd_stage;

// --- Sequence indices ---
const float CFSVD_SEQ_IDLE    = 0;
const float CFSVD_SEQ_SHOOT1  = 1;
const float CFSVD_SEQ_SHOOT2  = 2;
const float CFSVD_SEQ_RELOAD  = 3;
const float CFSVD_SEQ_DRAW    = 4;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 17 fps:
//   clipout at frame  7 / 17 = 0.412s   — mag drops out
//   clipin  at frame 22 / 17 = 1.294s   — fresh mag in
//   reload  at frame 44 / 17 = 2.588s   — final bolt-rack / chamber close
// Select sequence @ 30 fps:
//   reload  at frame 14 / 30 = 0.467s   — draw clack
const float CFSVD_RELOAD_CLIPOUT_TIME  = 0.412;
const float CFSVD_RELOAD_CLIPIN_TIME   = 1.294;
const float CFSVD_RELOAD_FINAL_TIME    = 2.588;
const float CFSVD_DRAW_CLACK_TIME      = 0.467;

// Ammo applies right after the final rack lands so the mag is visually
// seated and the bolt is closed before the new round counts.
const float CFSVD_RELOAD_APPLY_TIME    = 2.65;

// --- Gameplay tuning ---
// Semi-auto sniper: FIRE_DELAY alone paces single-shots — players can
// tap-fire as fast as 0.35s allows.  See header comment.
const float CFSVD_FIRE_DELAY        = 0.35;
const float CFSVD_DRYFIRE_DELAY     = 0.20;
const float CFSVD_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFSVD           = 10;
const float MAX_AMMO_CFSVD          = 30;

// --- Balance ---
// 7.62x54mmR Dragunov — heavier-hitting than the PSG1 / G3SG1.
const float CFSVD_BASE_SPREAD          = 0.009;
const float CFSVD_MOVE_SPREAD          = 0.09;
const float CFSVD_FULL_SPREAD_SPEED    = 320;
const float CFSVD_CLOSE_DAMAGE         = 95;
const float CFSVD_MIN_DAMAGE           = 55;
const float CFSVD_DAMAGE_FALLOFF_RANGE = 4096;
const float CFSVD_KICK_PITCH    = 1.7;   // sv_gunkick — semi-auto sniper, heavier than PSG1.
const float CFSVD_KICK_VARIANCE = 0.45;
const float CFSVD_KICK_STRENGTH = 1.1;

// --- Bone-attached muzzle (HDAK47 pattern) ---
//
// Bone name + local-frame offset come straight from the model's
// $attachment 0 entry.  If the muzzle appears in the wrong spot, re-
// check those values in HLAM / the model's .qc and update here, not
// in camera-local space.
const string CFSVD_MUZZLE_BONE   = "Bone01";
#define CFSVD_MUZZLE_OFFSET ('31.0 0.0 0.0')

const string CFSVD_VIEWMODEL    = "models/weapons/wpn_cfsvd/v_svd.mdl";
const string CFSVD_WORLDMODEL   = "models/weapons/wpn_cfsvd/w_svd.mdl";
const string CFSVD_DEPLOY_SOUND = "";
const string CFSVD_DISPLAY_NAME = "SVD Dragunov";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFSVDPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFSVD_SEQ_SHOOT1;
    return CFSVD_SEQ_SHOOT2;
};

float(float now) SH_CFSVDTickState =
{
    return SH_StandardTickState(now, mag_cfsvd, ammo_cfsvd, MAX_MAG_CFSVD,
        SH_SeqDuration(CFSVD_VIEWMODEL, CFSVD_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFSVD_VIEWMODEL, self.weaponframe,   0.35),
        SH_SeqDuration(CFSVD_VIEWMODEL, CFSVD_SEQ_RELOAD, 2.7),
        CFSVD_RELOAD_APPLY_TIME);
};

float(float now) SH_CFSVDTryFire =
{
    // Semi-auto sniper: FIRE_DELAY paces single-shots.  NOT the
    // SemiAuto edge gate — players expect to fire-tap at the rate
    // FIRE_DELAY allows, same as the existing CFPSG1.
    return SH_StandardTryFire(now, mag_cfsvd, CFSVD_FIRE_DELAY, CFSVD_DRYFIRE_DELAY);
};

float(float now) SH_CFSVDTryReload =
{
    return SH_StandardTryReload(now, mag_cfsvd, ammo_cfsvd, MAX_MAG_CFSVD,
        SH_SeqDuration(CFSVD_VIEWMODEL, CFSVD_SEQ_RELOAD, 2.7));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFSVDPickupCopy =
{
    player.mag_cfsvd  = self.mag_cfsvd;
    player.ammo_cfsvd = self.ammo_cfsvd;
};

void() W_CFSVDShoot =
{
    W_PenetratingHitscanShoot(CFSVD_BASE_SPREAD, CFSVD_MOVE_SPREAD, CFSVD_FULL_SPREAD_SPEED,
        CFSVD_CLOSE_DAMAGE, CFSVD_MIN_DAMAGE, CFSVD_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        CFSVD_KICK_PITCH, CFSVD_KICK_VARIANCE, CFSVD_KICK_STRENGTH);
};

void() W_CFSVDFire =
{
    float r = SH_CFSVDTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFSVDPickShootSeq();
        self.wep_nextframe = time + CFSVD_FRAME_INTERVAL;

        W_CFSVDShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsvd/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFSVDReload =
{
    if (SH_CFSVDTryReload(time))
    {
        self.weaponframe   = CFSVD_SEQ_RELOAD;
        self.wep_nextframe = time + CFSVD_FRAME_INTERVAL;
        self.cfsvd_reload_snd_stage = 0;
    }
};

void() W_CFSVDFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFSVD_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFSVD_DRAW_CLACK_TIME && !self.cfsvd_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsvd/reload.WAV", 1, ATTN_NORM);
            self.cfsvd_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFSVD_RELOAD_CLIPOUT_TIME && self.cfsvd_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsvd/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfsvd_reload_snd_stage = 1;
        }
        if (elapsed >= CFSVD_RELOAD_CLIPIN_TIME && self.cfsvd_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsvd/clipin.WAV", 1, ATTN_NORM);
            self.cfsvd_reload_snd_stage = 2;
        }
        if (elapsed >= CFSVD_RELOAD_FINAL_TIME && self.cfsvd_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfsvd/reload.WAV", 1, ATTN_NORM);
            self.cfsvd_reload_snd_stage = 3;
        }
    }

    result = SH_CFSVDTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFSVD_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfsvd_reload_snd_stage = 0;
    }
};

void() W_CFSVDEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dragunov", SCOPE_CLASS_SNIPER_SEMI);
    W_StandardEquipSetup(CFSVD_VIEWMODEL, CFSVD_DISPLAY_NAME, CFSVD_SEQ_DRAW,
        CFSVD_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFSVDFire;
    self.reload   = W_CFSVDReload;
    self.wepframe = W_CFSVDFrame;
    self.shoot    = W_CFSVDShoot;
    self.cfsvd_draw_snd_played  = 0;
    self.cfsvd_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFSVD_BASE_SPREAD, CFSVD_MOVE_SPREAD, CFSVD_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFSVDDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfsvd  = self.mag_cfsvd;
    tgt.ammo_cfsvd = self.ammo_cfsvd;

    self.mag_cfsvd  = 0;
    self.ammo_cfsvd = 0;

    setmodel(tgt, CFSVD_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname      = "weapon_cfsvd";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CFSVD;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CFSVDEquip;
    tgt.weap_drop_func = W_CFSVDDrop;
    tgt.pickupcopy     = W_CFSVDPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_cfsvd =
{
    setmodel(self, CFSVD_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname      = "weapon_cfsvd";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CFSVD;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CFSVDEquip;
    self.weap_drop_func = W_CFSVDDrop;
    self.pickupcopy     = W_CFSVDPickupCopy;
    self.touch          = weapon_touch;
    self.mag_cfsvd    = MAX_MAG_CFSVD;
    self.ammo_cfsvd   = MAX_AMMO_CFSVD;
    W_RegisterMapWeapon(weapon_cfsvd);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfsvd_draw_snd_played;
float csqc_cfsvd_reload_snd_stage;
float csqc_cfsvd_snd_action;

void() CSQC_PredictCFSVDCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfsvd_snd_action)
    {
        csqc_cfsvd_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfsvd_draw_snd_played  = 0;
        csqc_cfsvd_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFSVDTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfsvd/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFSVD_BASE_SPREAD, CFSVD_MOVE_SPREAD, CFSVD_FULL_SPREAD_SPEED,
                    CFSVD_CLOSE_DAMAGE, CFSVD_MIN_DAMAGE, CFSVD_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    CFSVD_KICK_PITCH, CFSVD_KICK_VARIANCE, CFSVD_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle flash — anchored to v_dragunov's
                // $attachment 0 (Bone01 + offset) so the flash tracks the
                // firing animation instead of sitting at a hand-tuned
                // camera-local point.  Static flash (not Animated) suits
                // the heavy-thump semi-auto cadence — same intensity per
                // shot rather than the burst variant used on full-auto.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFSVD_MUZZLE_BONE, CFSVD_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFSVDFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfsvd_draw_snd_played && elapsed >= CFSVD_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfsvd/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsvd_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfsvd_reload_snd_stage < 1 && elapsed >= CFSVD_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfsvd/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfsvd_reload_snd_stage = 1;
            }
            if (csqc_cfsvd_reload_snd_stage < 2 && elapsed >= CFSVD_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfsvd/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsvd_reload_snd_stage = 2;
            }
            if (csqc_cfsvd_reload_snd_stage < 3 && elapsed >= CFSVD_RELOAD_FINAL_TIME)
            {
                localsound("sounds/weapons/wpn_cfsvd/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfsvd_reload_snd_stage = 3;
            }
        }
    }

    SH_CFSVDTickState(csqc_pred_time);
};

void() CSQC_PredictCFSVDReload =
{
    if (SH_CFSVDTryReload(csqc_pred_time))
    {
        csqc_cfsvd_reload_snd_stage = 0;
        csqc_cfsvd_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFSVDDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFSVD_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFSVD_SEQ_SHOOT1;
        return CFSVD_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFSVD_SEQ_RELOAD;

    return CFSVD_SEQ_IDLE;
};

void() CSQC_CFSVDDropClear =
{
    self.mag_cfsvd  = 0;
    self.ammo_cfsvd = 0;
};

void() CSQC_CFSVDEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dragunov", SCOPE_CLASS_SNIPER_SEMI);
    self.weapon_name         = CFSVD_DISPLAY_NAME;
    self.weapon_viewmodel    = CFSVD_VIEWMODEL;
    self.weapon_worldmodel   = CFSVD_WORLDMODEL;
    self.weapon_deploy_sound = CFSVD_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFSVDCommand;
    self.csqc_predict_reload = CSQC_PredictCFSVDReload;
    self.csqc_display_frame  = CSQC_CFSVDDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFSVDDropClear;
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
    self.weapon_muzzle_bone   = CFSVD_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFSVD_MUZZLE_OFFSET;

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
        csqc_cfsvd_draw_snd_played = 1;
        csqc_cfsvd_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
