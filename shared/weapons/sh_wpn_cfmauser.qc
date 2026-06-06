// ============================================================
//  shared/weapons/sh_wpn_cfmauser.qc  -  C96 Mauser (CF series)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 10-round magazine, 60 reserve, semi-auto 7.63x25 Mauser
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//
//  Sequence-driven GoldSrc viewmodel (v_mauser.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as CFM9 / HDAK47 /
//  CFBARRETT.  W_CFMauserFrame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_mauser.mdl source):
//      0  idle      30 fps
//      3  shoot1    50 fps  (prefire — event 5001 "21")
//      4  shoot2    50 fps  (prefire — event 5001 "21")
//      5  shoot3    50 fps  (prefire — event 5001 "21")
//      7  reload    42 fps  (clipout @ frame 1, clipin @ frame 18)
//      8  select    30 fps  (select.wav at frame 2)
//
//  Indices 1/2/6 in the source $sequence dump are duplicate idle /
//  variant frames the artist authored — we deliberately ignore those
//  and only reference the indices listed above.  FTE does NOT
//  auto-play $sequence event 5001 / 5004 markers; sound events are
//  driven from QC against wep_anim_start elapsed time.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable like the original HDAK47).  This is the
//  CFM9 / CFBARRETT pattern — see the HDAK47 reload-sound bug fix
//  commit for why the single-variable approach corrupts state under
//  the every-reconcile CSQC_WeaponEquip call.
//
//  Muzzle is bone-attached.  The bone name in v_mauser.mdl is
//  literally "Box01" (3DS Max default — NOT "Bone01").  Local offset
//  is zero — the bone pivot sits exactly at the muzzle tip.  If the
//  flash appears off, re-check the model's $attachment dump and
//  update HERE rather than overriding in camera-local space.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfmauser;
.float ammo_cfmauser;

// --- Per-entity sound stage trackers (server side) ---
.float cfmauser_draw_snd_played;
.float cfmauser_reload_snd_stage;

// --- Sequence indices ---
const float CFMAUSER_SEQ_IDLE    = 0;
const float CFMAUSER_SEQ_SHOOT1  = 3;
const float CFMAUSER_SEQ_SHOOT2  = 4;
const float CFMAUSER_SEQ_SHOOT3  = 5;
const float CFMAUSER_SEQ_RELOAD  = 7;
const float CFMAUSER_SEQ_DRAW    = 8;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 42 fps:
//   clipout at frame  1 / 42 = 0.024s   — mag drops out
//   clipin  at frame 18 / 42 = 0.429s   — fresh stripper-clip seated
// Select sequence @ 30 fps:
//   select  at frame  2 / 30 = 0.067s   — draw clack
const float CFMAUSER_RELOAD_CLIPOUT_TIME  = 0.024;
const float CFMAUSER_RELOAD_CLIPIN_TIME   = 0.429;
const float CFMAUSER_DRAW_CLACK_TIME      = 0.067;

// Ammo applies right after clipin lands (mag visually seated).
const float CFMAUSER_RELOAD_APPLY_TIME    = 0.45;

// --- Gameplay tuning ---
const float CFMAUSER_FIRE_DELAY        = 0.090;   // semi-auto, fast tap rate
const float CFMAUSER_DRYFIRE_DELAY     = 0.20;
const float CFMAUSER_FRAME_INTERVAL    = 0.05;    // state-machine tick rate

const float MAX_MAG_CFMAUSER           = 10;
const float MAX_AMMO_CFMAUSER          = 60;

// --- Balance ---
const float CFMAUSER_BASE_SPREAD          = 0.011;
const float CFMAUSER_MOVE_SPREAD          = 0.058;
const float CFMAUSER_FULL_SPREAD_SPEED    = 320;
const float CFMAUSER_CLOSE_DAMAGE         = 28;
const float CFMAUSER_MIN_DAMAGE           = 14;
const float CFMAUSER_DAMAGE_FALLOFF_RANGE = 2048;
const float CFMAUSER_KICK_PITCH    = 0.65;
const float CFMAUSER_KICK_VARIANCE = 0.35;
const float CFMAUSER_KICK_STRENGTH = 0.75;

// Muzzle attachment — bone-attached (HDAK47 pattern).  v_mauser.mdl
// exposes the muzzle bone as literal "Box01" (3DS Max default name —
// NOT "Bone01"); the local-frame offset is zero because the bone pivot
// sits exactly at the muzzle tip.  Do NOT "fix" the bone string.
const string CFMAUSER_MUZZLE_BONE   = "Box01";
#define CFMAUSER_MUZZLE_OFFSET ('0 0 0')

const string CFMAUSER_VIEWMODEL    = "models/weapons/wpn_cfmauser/v_mauser.mdl";
const string CFMAUSER_WORLDMODEL   = "models/weapons/wpn_cfmauser/w_mauser.mdl";
const string CFMAUSER_DEPLOY_SOUND = "";
const string CFMAUSER_DISPLAY_NAME = "C96 Mauser";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFMauserPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFMAUSER_SEQ_SHOOT1;
    if (r < 0.67) return CFMAUSER_SEQ_SHOOT2;
    return CFMAUSER_SEQ_SHOOT3;
};

float(float now) SH_CFMauserTickState =
{
    return SH_StandardTickState(now, mag_cfmauser, ammo_cfmauser, MAX_MAG_CFMAUSER,
        SH_SeqDuration(CFMAUSER_VIEWMODEL, CFMAUSER_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFMAUSER_VIEWMODEL, self.weaponframe,    0.3),
        SH_SeqDuration(CFMAUSER_VIEWMODEL, CFMAUSER_SEQ_RELOAD, 1.5),
        CFMAUSER_RELOAD_APPLY_TIME);
};

float(float now) SH_CFMauserTryFire =
{
    // Semi-auto: must release +attack between shots.
    return SH_StandardTryFireSemiAuto(now, mag_cfmauser, CFMAUSER_FIRE_DELAY, CFMAUSER_DRYFIRE_DELAY);
};

float(float now) SH_CFMauserTryReload =
{
    return SH_StandardTryReload(now, mag_cfmauser, ammo_cfmauser, MAX_MAG_CFMAUSER,
        SH_SeqDuration(CFMAUSER_VIEWMODEL, CFMAUSER_SEQ_RELOAD, 1.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFMauserPickupCopy =
{
    player.mag_cfmauser  = self.mag_cfmauser;
    player.ammo_cfmauser = self.ammo_cfmauser;
};

void() W_CFMauserShoot =
{
    W_PenetratingHitscanShoot(CFMAUSER_BASE_SPREAD, CFMAUSER_MOVE_SPREAD, CFMAUSER_FULL_SPREAD_SPEED,
        CFMAUSER_CLOSE_DAMAGE, CFMAUSER_MIN_DAMAGE, CFMAUSER_DAMAGE_FALLOFF_RANGE, 28, 0.94,
        CFMAUSER_KICK_PITCH, CFMAUSER_KICK_VARIANCE, CFMAUSER_KICK_STRENGTH);
};

void() W_CFMauserFire =
{
    float r = SH_CFMauserTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFMauserPickShootSeq();
        self.wep_nextframe = time + CFMAUSER_FRAME_INTERVAL;

        W_CFMauserShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmauser/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFMauserReload =
{
    if (SH_CFMauserTryReload(time))
    {
        self.weaponframe   = CFMAUSER_SEQ_RELOAD;
        self.wep_nextframe = time + CFMAUSER_FRAME_INTERVAL;
        self.cfmauser_reload_snd_stage = 0;
    }
};

void() W_CFMauserFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFMAUSER_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFMAUSER_DRAW_CLACK_TIME && !self.cfmauser_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmauser/draw.WAV", 1, ATTN_NORM);
            self.cfmauser_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFMAUSER_RELOAD_CLIPOUT_TIME && self.cfmauser_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmauser/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.cfmauser_reload_snd_stage = 1;
        }
        if (elapsed >= CFMAUSER_RELOAD_CLIPIN_TIME && self.cfmauser_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfmauser/clipin.WAV", 1, ATTN_NORM);
            self.cfmauser_reload_snd_stage = 2;
        }
    }

    result = SH_CFMauserTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFMAUSER_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfmauser_reload_snd_stage = 0;
    }
};

void() W_CFMauserEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_mauser", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFMAUSER_VIEWMODEL, CFMAUSER_DISPLAY_NAME, CFMAUSER_SEQ_DRAW,
        CFMAUSER_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFMauserFire;
    self.reload   = W_CFMauserReload;
    self.wepframe = W_CFMauserFrame;
    self.shoot    = W_CFMauserShoot;
    self.cfmauser_draw_snd_played  = 0;
    self.cfmauser_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFMAUSER_BASE_SPREAD, CFMAUSER_MOVE_SPREAD, CFMAUSER_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_CFMauserDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfmauser  = self.mag_cfmauser;
    tgt.ammo_cfmauser = self.ammo_cfmauser;

    self.mag_cfmauser  = 0;
    self.ammo_cfmauser = 0;

    setmodel(tgt, CFMAUSER_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname    = "weapon_cfmauser";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CFMAUSER;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CFMauserEquip;
    tgt.weap_drop_func = W_CFMauserDrop;
    tgt.pickupcopy   = W_CFMauserPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_cfmauser =
{
    setmodel(self, CFMAUSER_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfmauser";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFMAUSER;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CFMauserEquip;
    self.weap_drop_func = W_CFMauserDrop;
    self.pickupcopy    = W_CFMauserPickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfmauser   = MAX_MAG_CFMAUSER;
    self.ammo_cfmauser  = MAX_AMMO_CFMAUSER;
    W_RegisterMapWeapon(weapon_cfmauser);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfmauser_draw_snd_played;
float csqc_cfmauser_reload_snd_stage;
float csqc_cfmauser_snd_action;

void() CSQC_PredictCFMauserCommand =
{
    float r;
    float elapsed;
    vector muzzle_world;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfmauser_snd_action)
    {
        csqc_cfmauser_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfmauser_draw_snd_played  = 0;
        csqc_cfmauser_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFMauserTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfmauser/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFMAUSER_BASE_SPREAD, CFMAUSER_MOVE_SPREAD, CFMAUSER_FULL_SPREAD_SPEED,
                    CFMAUSER_CLOSE_DAMAGE, CFMAUSER_MIN_DAMAGE, CFMAUSER_DAMAGE_FALLOFF_RANGE, 28, 0.94,
                    CFMAUSER_KICK_PITCH, CFMAUSER_KICK_VARIANCE, CFMAUSER_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle flash / smoke (HDAK47 pattern).
                // Tracer start point is resolved through the same
                // attachment so it follows the firing animation instead
                // of sitting at a hand-tuned camera-local offset.
                muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFMAUSER_MUZZLE_BONE, CFMAUSER_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFMauserFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfmauser_draw_snd_played && elapsed >= CFMAUSER_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfmauser/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmauser_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfmauser_reload_snd_stage < 1 && elapsed >= CFMAUSER_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfmauser/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfmauser_reload_snd_stage = 1;
            }
            if (csqc_cfmauser_reload_snd_stage < 2 && elapsed >= CFMAUSER_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfmauser/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfmauser_reload_snd_stage = 2;
            }
        }
    }

    SH_CFMauserTickState(csqc_pred_time);
};

void() CSQC_PredictCFMauserReload =
{
    if (SH_CFMauserTryReload(csqc_pred_time))
    {
        csqc_cfmauser_reload_snd_stage = 0;
        csqc_cfmauser_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFMauserDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFMAUSER_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFMAUSER_SEQ_SHOOT1;
        if (r < 0.67) return CFMAUSER_SEQ_SHOOT2;
        return CFMAUSER_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFMAUSER_SEQ_RELOAD;

    return CFMAUSER_SEQ_IDLE;
};

void() CSQC_CFMauserDropClear =
{
    self.mag_cfmauser  = 0;
    self.ammo_cfmauser = 0;
};

void() CSQC_CFMauserEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_mauser", SCOPE_CLASS_NONE);
    self.weapon_name         = CFMAUSER_DISPLAY_NAME;
    self.weapon_viewmodel    = CFMAUSER_VIEWMODEL;
    self.weapon_worldmodel   = CFMAUSER_WORLDMODEL;
    self.weapon_deploy_sound = CFMAUSER_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFMauserCommand;
    self.csqc_predict_reload = CSQC_PredictCFMauserReload;
    self.csqc_display_frame  = CSQC_CFMauserDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFMauserDropClear;
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
    self.weapon_muzzle_bone   = CFMAUSER_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFMAUSER_MUZZLE_OFFSET;

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
        csqc_cfmauser_draw_snd_played = 1;
        csqc_cfmauser_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
