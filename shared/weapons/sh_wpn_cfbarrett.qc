// ============================================================
//  shared/weapons/sh_wpn_cfbarrett.qc  -  Barrett M82 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action .50 BMG
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//          Single-shot pacing enforced by CFBARRETT_FIRE_DELAY (~1.5s) —
//          no semi-auto edge gate needed at the bolt-action cadence.
//  Scope : CoD-style toggle scope owned by cl_codscope.qc when
//          sv_codscopes is set.  This file contains NO altfire / zoom
//          code — orchestrator wires the CodScope_Eligible hook and
//          cl_viewfx codscopes block.
//
//  Sequence-driven GoldSrc viewmodel (v_awp.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFAUG.  W_CFBarrettFrame does NOT step weaponframe per tick.
//
//  Sequence layout (from $sequence dump):
//      0  idle_0    30 fps
//      1  prefire   60 fps  (shoot variant A)
//      2  prefire   60 fps  (shoot variant B)
//      3  prefire   60 fps  (shoot variant C)
//      4  reload    27 fps  (clipout @ 8, clipin @ 25, reload @ 51)
//      5  select    22 fps  (draw clack @ frame 2)
//
//  Note on the prefire frame-50 reload-wav event in the .mdl: that's
//  a model-author artifact (likely an editing breadcrumb for a
//  between-shots bolt cycle).  FTE does NOT auto-play $sequence event
//  5004 markers anyway, and we drive fire sounds from QC.  We emit
//  fire.WAV exactly once per shot — no embedded bolt-cycle sound.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable).  This is the CFM9 pattern — see
//  the HDAK47 reload-sound bug fix commit for why the single-variable
//  approach corrupts state under the every-reconcile CSQC_WeaponEquip
//  call.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfbarrett;
.float ammo_cfbarrett;

// --- Per-entity sound stage trackers (server side) ---
.float cfbarrett_draw_snd_played;
.float cfbarrett_reload_snd_stage;
// Between-shots bolt-cycle sound — the prefire $sequence has a
// frame-50 event the model author intended for the bolt rack after
// the shot.  Emitted on CHAN_AUTO once per fire, at elapsed ~0.833s
// (50 / 60 fps).  Tracked per shot so it fires exactly once per
// trigger pull and resets on the NEXT shot.
.float cfbarrett_post_fire_bolt_played;

// --- Sequence indices ---
const float CFBARRETT_SEQ_IDLE    = 0;
const float CFBARRETT_SEQ_SHOOT1  = 1;
const float CFBARRETT_SEQ_SHOOT2  = 2;
const float CFBARRETT_SEQ_SHOOT3  = 3;
const float CFBARRETT_SEQ_RELOAD  = 4;
const float CFBARRETT_SEQ_DRAW    = 5;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload sequence @ 27 fps:
//   clipout at frame  8 / 27 = 0.296s   — mag drops out
//   clipin  at frame 25 / 27 = 0.926s   — fresh mag in
//   reload  at frame 51 / 27 = 1.889s   — bolt cycle / chamber close
// Select sequence @ 22 fps:
//   clack   at frame  2 / 22 = 0.091s   — draw clack
const float CFBARRETT_RELOAD_CLIPOUT_TIME  = 0.296;
const float CFBARRETT_RELOAD_CLIPIN_TIME   = 0.926;
const float CFBARRETT_RELOAD_RELOAD_TIME   = 1.889;
const float CFBARRETT_DRAW_CLACK_TIME      = 0.091;
// Bolt-cycle sound during prefire — frame 50 of prefire @ 60 fps.
const float CFBARRETT_POST_FIRE_BOLT_TIME  = 0.833;

// Ammo applies right after the final reload event lands so the mag is
// visually seated and the bolt is closed before the new round counts.
const float CFBARRETT_RELOAD_APPLY_TIME    = 1.90;

// --- Gameplay tuning ---
const float CFBARRETT_FIRE_DELAY        = 1.5;    // bolt-action — slow refire
const float CFBARRETT_DRYFIRE_DELAY     = 0.2;
const float CFBARRETT_FRAME_INTERVAL    = 0.05;   // state-machine tick rate

const float MAX_MAG_CFBARRETT           = 10;
const float MAX_AMMO_CFBARRETT          = 30;

// --- Balance ---
// Barrett M82 — heaviest hitter in the lineup.
const float CFBARRETT_BASE_SPREAD          = 0.008;
const float CFBARRETT_MOVE_SPREAD          = 0.12;
const float CFBARRETT_FULL_SPREAD_SPEED    = 320;
const float CFBARRETT_CLOSE_DAMAGE         = 150;
const float CFBARRETT_MIN_DAMAGE           = 80;
const float CFBARRETT_DAMAGE_FALLOFF_RANGE = 4096;
const float CFBARRETT_KICK_PITCH    = 2.5;    // sv_gunkick — anti-materiel rifle, very heavy
const float CFBARRETT_KICK_VARIANCE = 0.6;
const float CFBARRETT_KICK_STRENGTH = 2.0;

// Camera-local muzzle offset — no $attachment dump available for this
// model yet, so the flash is anchored to a camera-relative point
// rather than the bone.  Rifle scale.
// Muzzle attachment from v_awp.mdl's $attachment 0:
//   $attachment 0 "Bone01" 58.0 0.0 0.0
const string CFBARRETT_MUZZLE_BONE   = "Bone01";
#define CFBARRETT_MUZZLE_OFFSET ('58.0 0.0 0.0')

const string CFBARRETT_VIEWMODEL    = "models/weapons/wpn_cfbarrett/v_barrett.mdl";
const string CFBARRETT_WORLDMODEL   = "models/weapons/wpn_cfbarrett/w_barrett.mdl";
const string CFBARRETT_DEPLOY_SOUND = "";
const string CFBARRETT_DISPLAY_NAME = "Barrett M82";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2/3 plays for this shot.
float() SH_CFBarrettPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFBARRETT_SEQ_SHOOT1;
    if (r < 0.67) return CFBARRETT_SEQ_SHOOT2;
    return CFBARRETT_SEQ_SHOOT3;
};

float(float now) SH_CFBarrettTickState =
{
    return SH_StandardTickState(now, mag_cfbarrett, ammo_cfbarrett, MAX_MAG_CFBARRETT,
        SH_SeqDuration(CFBARRETT_VIEWMODEL, CFBARRETT_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFBARRETT_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFBARRETT_VIEWMODEL, CFBARRETT_SEQ_RELOAD, 2.5),
        CFBARRETT_RELOAD_APPLY_TIME);
};

float(float now) SH_CFBarrettTryFire =
{
    // Bolt-action: FIRE_DELAY itself enforces single-shot pacing —
    // no semi-auto edge gate needed.
    return SH_StandardTryFire(now, mag_cfbarrett, CFBARRETT_FIRE_DELAY, CFBARRETT_DRYFIRE_DELAY);
};

float(float now) SH_CFBarrettTryReload =
{
    return SH_StandardTryReload(now, mag_cfbarrett, ammo_cfbarrett, MAX_MAG_CFBARRETT,
        SH_SeqDuration(CFBARRETT_VIEWMODEL, CFBARRETT_SEQ_RELOAD, 2.5));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFBarrettPickupCopy =
{
    player.mag_cfbarrett  = self.mag_cfbarrett;
    player.ammo_cfbarrett = self.ammo_cfbarrett;
};

void() W_CFBarrettShoot =
{
    W_PenetratingHitscanShoot(CFBARRETT_BASE_SPREAD, CFBARRETT_MOVE_SPREAD, CFBARRETT_FULL_SPREAD_SPEED,
        CFBARRETT_CLOSE_DAMAGE, CFBARRETT_MIN_DAMAGE, CFBARRETT_DAMAGE_FALLOFF_RANGE, 64, 0.985,
        CFBARRETT_KICK_PITCH, CFBARRETT_KICK_VARIANCE, CFBARRETT_KICK_STRENGTH);
};

void() W_CFBarrettFire =
{
    float r = SH_CFBarrettTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFBarrettPickShootSeq();
        self.wep_nextframe = time + CFBARRETT_FRAME_INTERVAL;
        // Re-arm the post-fire bolt-cycle latch so the rack sound
        // emits ~0.83s into the prefire animation.
        self.cfbarrett_post_fire_bolt_played = 0;

        // Bolt-action scope-rescope: SH_StandardTryFire stamped the
        // suppress to the standard 0.4s.  Override to the full
        // bolt-cycle (FIRE_DELAY) so the CoD scope can't re-engage
        // until the bolt is back in battery.  Semi-auto snipers
        // (PSG1 / SVD) are excluded from the suppress in cl_codscope.qc
        // entirely, so this only affects bolt-actions.
        self.pm_fire_suppress_until = time + CFBARRETT_FIRE_DELAY;

        W_CFBarrettShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfbarrett/fire.WAV", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFBarrettReload =
{
    if (SH_CFBarrettTryReload(time))
    {
        self.weaponframe   = CFBARRETT_SEQ_RELOAD;
        self.wep_nextframe = time + CFBARRETT_FRAME_INTERVAL;
        self.cfbarrett_reload_snd_stage = 0;
    }
};

void() W_CFBarrettFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client.
    self.wep_nextframe += CFBARRETT_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFBARRETT_DRAW_CLACK_TIME && !self.cfbarrett_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfbarrett/draw.WAV", 1, ATTN_NORM);
            self.cfbarrett_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Between-shots bolt cycle — reload.wav at ~0.83s into the
        // prefire animation (frame 50 / 60 fps).  Latched per-shot
        // so it fires exactly once; reset to 0 each W_CFBarrettFire.
        if (elapsed >= CFBARRETT_POST_FIRE_BOLT_TIME && !self.cfbarrett_post_fire_bolt_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfbarrett/reload.WAV", 1, ATTN_NORM);
            self.cfbarrett_post_fire_bolt_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFBARRETT_RELOAD_CLIPOUT_TIME && self.cfbarrett_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfbarrett/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfbarrett_reload_snd_stage = 1;
        }
        if (elapsed >= CFBARRETT_RELOAD_CLIPIN_TIME && self.cfbarrett_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfbarrett/clipin.WAV", 1, ATTN_NORM);
            self.cfbarrett_reload_snd_stage = 2;
        }
        if (elapsed >= CFBARRETT_RELOAD_RELOAD_TIME && self.cfbarrett_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfbarrett/reload.WAV", 1, ATTN_NORM);
            self.cfbarrett_reload_snd_stage = 3;
        }
    }

    result = SH_CFBarrettTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFBARRETT_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfbarrett_reload_snd_stage = 0;
    }
};

void() W_CFBarrettEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_barrett", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(CFBARRETT_VIEWMODEL, CFBARRETT_DISPLAY_NAME, CFBARRETT_SEQ_DRAW,
        CFBARRETT_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFBarrettFire;
    self.reload   = W_CFBarrettReload;
    self.wepframe = W_CFBarrettFrame;
    self.shoot    = W_CFBarrettShoot;
    self.cfbarrett_draw_snd_played  = 0;
    self.cfbarrett_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFBARRETT_BASE_SPREAD, CFBARRETT_MOVE_SPREAD, CFBARRETT_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFBarrettDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfbarrett  = self.mag_cfbarrett;
    tgt.ammo_cfbarrett = self.ammo_cfbarrett;

    self.mag_cfbarrett  = 0;
    self.ammo_cfbarrett = 0;

    setmodel(tgt, CFBARRETT_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfbarrett";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFBARRETT;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFBarrettEquip;
    tgt.weap_drop_func = W_CFBarrettDrop;
    tgt.pickupcopy    = W_CFBarrettPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfbarrett =
{
    setmodel(self, CFBARRETT_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfbarrett";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFBARRETT;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFBarrettEquip;
    self.weap_drop_func = W_CFBarrettDrop;
    self.pickupcopy    = W_CFBarrettPickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfbarrett     = MAX_MAG_CFBARRETT;
    self.ammo_cfbarrett    = MAX_AMMO_CFBARRETT;
    W_RegisterMapWeapon(weapon_cfbarrett);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfbarrett_draw_snd_played;
float csqc_cfbarrett_reload_snd_stage;
float csqc_cfbarrett_post_fire_bolt_played;
float csqc_cfbarrett_snd_action;

void() CSQC_PredictCFBarrettCommand =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same
    // buffered command.
    if (predicted_player.wep_action_id != csqc_cfbarrett_snd_action)
    {
        csqc_cfbarrett_snd_action            = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfbarrett_draw_snd_played  = 0;
        csqc_cfbarrett_reload_snd_stage      = 0;
        // Each new fire bumps wep_action_id → re-arm the bolt-cycle
        // latch so the rack sound fires once per shot.
        csqc_cfbarrett_post_fire_bolt_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFBarrettTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Bolt-action scope-rescope suppress — mirror the server's
            // W_CFBarrettFire override (see that file for the rationale).
            self.pm_fire_suppress_until = time + CFBARRETT_FIRE_DELAY;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfbarrett/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFBARRETT_BASE_SPREAD, CFBARRETT_MOVE_SPREAD, CFBARRETT_FULL_SPREAD_SPEED,
                    CFBARRETT_CLOSE_DAMAGE, CFBARRETT_MIN_DAMAGE, CFBARRETT_DAMAGE_FALLOFF_RANGE, 64, 0.985,
                    CFBARRETT_KICK_PITCH, CFBARRETT_KICK_VARIANCE, CFBARRETT_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Animated muzzle flash — heavier feel for the .50 BMG,
                // same pattern as Deagle.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFBARRETT_MUZZLE_BONE, CFBARRETT_MUZZLE_OFFSET);
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

    // Predicted draw / reload sounds — match the server's W_CFBarrettFrame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfbarrett_draw_snd_played && elapsed >= CFBARRETT_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfbarrett/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfbarrett_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            // Between-shots bolt cycle mirror — same elapsed timing as
            // the server's W_CFBarrettFrame WS_FIRE branch.
            if (!csqc_cfbarrett_post_fire_bolt_played && elapsed >= CFBARRETT_POST_FIRE_BOLT_TIME)
            {
                localsound("sounds/weapons/wpn_cfbarrett/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfbarrett_post_fire_bolt_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfbarrett_reload_snd_stage < 1 && elapsed >= CFBARRETT_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfbarrett/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfbarrett_reload_snd_stage = 1;
            }
            if (csqc_cfbarrett_reload_snd_stage < 2 && elapsed >= CFBARRETT_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfbarrett/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfbarrett_reload_snd_stage = 2;
            }
            if (csqc_cfbarrett_reload_snd_stage < 3 && elapsed >= CFBARRETT_RELOAD_RELOAD_TIME)
            {
                localsound("sounds/weapons/wpn_cfbarrett/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfbarrett_reload_snd_stage = 3;
            }
        }
    }

    SH_CFBarrettTickState(csqc_pred_time);
};

void() CSQC_PredictCFBarrettReload =
{
    if (SH_CFBarrettTryReload(csqc_pred_time))
    {
        csqc_cfbarrett_reload_snd_stage = 0;
        csqc_cfbarrett_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFBarrettDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFBARRETT_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFBARRETT_SEQ_SHOOT1;
        if (r < 0.67) return CFBARRETT_SEQ_SHOOT2;
        return CFBARRETT_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFBARRETT_SEQ_RELOAD;

    return CFBARRETT_SEQ_IDLE;
};

void() CSQC_CFBarrettDropClear =
{
    self.mag_cfbarrett  = 0;
    self.ammo_cfbarrett = 0;
};

void() CSQC_CFBarrettEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_barrett", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = CFBARRETT_DISPLAY_NAME;
    self.weapon_viewmodel    = CFBARRETT_VIEWMODEL;
    self.weapon_worldmodel   = CFBARRETT_WORLDMODEL;
    self.weapon_deploy_sound = CFBARRETT_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFBarrettCommand;
    self.csqc_predict_reload = CSQC_PredictCFBarrettReload;
    self.csqc_display_frame  = CSQC_CFBarrettDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFBarrettDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    // Bone-attached muzzle (Bone01 + 58 unit forward offset) — the
    // sway-pivot mode rotates around this point too.
    self.weapon_muzzle_bone   = CFBARRETT_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFBARRETT_MUZZLE_OFFSET;

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
        csqc_cfbarrett_draw_snd_played = 1;
        csqc_cfbarrett_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
