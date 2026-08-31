// ============================================================
//  shared/weapons/sh_wpn_csscout.qc  -  CS Scout
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_scout;
.float ammo_scout;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_scout.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName; see sh_wpn_csaug.qc.
// Read out of cstrike/models/v_scout.mdl itself:
//   [0] idle1   16fps  11f  0.625s
//   [1] shoot   35fps  46f  1.286s  f0 5001 (muzzleflash) f13 "scout_bolt"
//   [2] shoot   35fps  46f  1.286s  <- SAME LABEL, frame-identical duplicate
//   [3] reload  30fps  61f  2.000s  f13 "scout_clipout" f37 "scout_clipin"
//   [4] draw    30fps  31f  1.000s
//
// Only ONE shoot take is used.  Both carry the label "shoot", so SH_SeqForName
// resolves either request to index 1 anyway, and the pair is byte-identical in
// fps, frame count and events — there is nothing to pick between.
const float SCOUT_SEQ_IDLE   = 0;
const float SCOUT_SEQ_SHOOT  = 1;
const float SCOUT_SEQ_RELOAD = 3;
const float SCOUT_SEQ_DRAW   = 4;

const float SCOUT_FRAME_INTERVAL      = 0.0333334;   // state-machine tick rate
const float SCOUT_FIRE_DELAY          = 1.0;

// Event marks as a FRACTION of their sequence.
const float SCOUT_FIRE_F_BOLT         = 0.2889;   // frame 13 / 45
const float SCOUT_RELOAD_F_CLIPOUT    = 0.2167;   // frame 13 / 60
const float SCOUT_RELOAD_F_CLIPIN     = 0.6167;   // frame 37 / 60
const float SCOUT_RELOAD_F_APPLY      = 0.6500;   // just after the fresh mag seats

const float MAX_MAG_SCOUT             = 10;
const float MAX_AMMO_SCOUT            = 30;

// --- Balance ---
const float SCOUT_BASE_SPREAD          = 0.01;
const float SCOUT_MOVE_SPREAD          = 0.08;
const float SCOUT_FULL_SPREAD_SPEED    = 320;
const float SCOUT_CLOSE_DAMAGE         = 70;
const float SCOUT_MIN_DAMAGE           = 50;
const float SCOUT_DAMAGE_FALLOFF_RANGE = 4096;
const float SCOUT_DRYFIRE_DELAY        = 0.2;
const float SCOUT_KICK_PITCH    = 3.0;   // sv_gunkick — bolt sniper.
const float SCOUT_KICK_VARIANCE = 0.5;
const float SCOUT_KICK_STRENGTH = 0.8;   // single-shot bolt — heavy kick.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float SCOUT_MUZZLE_FORWARD = 42;
const float SCOUT_MUZZLE_RIGHT   = 8.3;
const float SCOUT_MUZZLE_DOWN    = 4.95;

// v_/w_/p_ all resolve through the mounted cstrike gamedir.  Only the viewmodel
// moved — it was a mod-bundled IDPO re-bake — so the animation half of this file
// went sequence-driven with the path.
const string SCOUT_VIEWMODEL    = "models/v_scout.mdl";
const string SCOUT_WORLDMODEL   = "models/w_scout.mdl";
const string SCOUT_DEPLOY_SOUND = "";
const string SCOUT_DISPLAY_NAME = "SCOUT";

// Sound stage latch — a sequence-driven model never steps weaponframe.
.float scout_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_ScoutSeqIdle   = { return SH_SeqForName(SCOUT_VIEWMODEL, "idle1",  SCOUT_SEQ_IDLE); };
float() SH_ScoutSeqReload = { return SH_SeqForName(SCOUT_VIEWMODEL, "reload", SCOUT_SEQ_RELOAD); };
float() SH_ScoutSeqDraw   = { return SH_SeqForName(SCOUT_VIEWMODEL, "draw",   SCOUT_SEQ_DRAW); };
float() SH_ScoutSeqShoot  = { return SH_SeqForName(SCOUT_VIEWMODEL, "shoot",  SCOUT_SEQ_SHOOT); };

float() SH_ScoutDrawDuration   = { return SH_SeqDuration(SCOUT_VIEWMODEL, SH_ScoutSeqDraw(),   1.000); };
float() SH_ScoutReloadDuration = { return SH_SeqDuration(SCOUT_VIEWMODEL, SH_ScoutSeqReload(), 2.000); };
float() SH_ScoutFireDuration   = { return SH_SeqDuration(SCOUT_VIEWMODEL, SH_ScoutSeqShoot(),  1.286); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_ScoutTickState =
{
    float rel = SH_ScoutReloadDuration();
    return SH_StandardTickState(now, mag_scout, ammo_scout, MAX_MAG_SCOUT,
        SH_ScoutDrawDuration(),
        SH_SeqDuration(SCOUT_VIEWMODEL, self.weaponframe, 1.286),
        rel, rel * SCOUT_RELOAD_F_APPLY);
};

float(float now) SH_ScoutTryFire =
{
    // Don't clear zoomstage here — Shoot needs it for spread calculation.
    // Zoomstage is cleared in W_ScoutFire / CSQC prediction AFTER the shot.
    return SH_StandardTryFire(now, mag_scout, SCOUT_FIRE_DELAY, SCOUT_DRYFIRE_DELAY);
};

float(float now) SH_ScoutTryReload =
{
    float r = SH_StandardTryReload(now, mag_scout, ammo_scout, MAX_MAG_SCOUT, SH_ScoutReloadDuration());
    if (r == 1)
        self.zoomstage = 0;   // unscope on reload
    return r;
};

float(float now) SH_ScoutTryAltFire =
{
    // sv_codscopes mode reassigns +attack2 from this CS-style stage
    // cycle to a CoD-style ADS-hold scope (cl_codscope.qc).  Short-
    // circuit here so zoomstage stays at 0 — the CoD state machine
    // owns scope visuals and FOV via its own path.  Returns 0 so the
    // SSQC / CSQC predict callers don't emit a click sfx or stamp
    // altfire_finished.
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_ScoutPickupCopy =
{
    player.mag_scout  = self.mag_scout;
    player.ammo_scout = self.ammo_scout;
};

void() W_ScoutShoot =
{
    // Scoped: no base spread. Unscoped: full base spread.
    if (self.zoomstage > 0)
        W_PenetratingHitscanShoot(0, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED,
            SCOUT_CLOSE_DAMAGE, SCOUT_MIN_DAMAGE, SCOUT_DAMAGE_FALLOFF_RANGE, 80, 0.98,
            SCOUT_KICK_PITCH, SCOUT_KICK_VARIANCE, SCOUT_KICK_STRENGTH);
    else
        W_PenetratingHitscanShoot(SCOUT_BASE_SPREAD, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED,
            SCOUT_CLOSE_DAMAGE, SCOUT_MIN_DAMAGE, SCOUT_DAMAGE_FALLOFF_RANGE, 80, 0.98,
            SCOUT_KICK_PITCH, SCOUT_KICK_VARIANCE, SCOUT_KICK_STRENGTH);
};

void() W_ScoutFire =
{
    float r = SH_ScoutTryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_ScoutSeqShoot();
        self.wep_nextframe   = time + SCOUT_FRAME_INTERVAL;
        self.scout_snd_stage = 0;

        W_ScoutShoot();
        self.zoomstage = 0;
        self.sv_zoomstage = 0;

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csscout/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_ScoutAltFire =
{
    if (SH_ScoutTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_ScoutReload =
{
    if (SH_ScoutTryReload(time))
    {
        self.weaponframe     = SH_ScoutSeqReload();
        self.wep_nextframe   = time + SCOUT_FRAME_INTERVAL;
        self.scout_snd_stage = 0;
        self.sv_zoomstage    = 0;
    }
};

void() W_ScoutFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += SCOUT_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_ScoutFireDuration() * SCOUT_FIRE_F_BOLT
            && self.scout_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/bolt.wav", 1, ATTN_NORM);
            self.scout_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_ScoutReloadDuration();

        if (elapsed >= rel * SCOUT_RELOAD_F_CLIPOUT && self.scout_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.scout_snd_stage = 1;
        }
        if (elapsed >= rel * SCOUT_RELOAD_F_CLIPIN && self.scout_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/clipin.wav", 1, ATTN_NORM);
            self.scout_snd_stage = 2;
        }
    }

    result = SH_ScoutTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_ScoutSeqIdle();
        self.wep_nextframe   = 0;
        self.scout_snd_stage = 0;
    }
};

void() W_ScoutEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_scout", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(SCOUT_VIEWMODEL, SCOUT_DISPLAY_NAME, SH_ScoutSeqDraw(),
        SCOUT_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.scout_snd_stage = 0;
    self.fire     = W_ScoutFire;
    self.reload   = W_ScoutReload;
    self.wepframe = W_ScoutFrame;
    self.altfire  = W_ScoutAltFire;
    self.shoot    = W_ScoutShoot;
    W_ClearZoom();
    W_SetCrosshairProfile(SCOUT_BASE_SPREAD, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED, 1.45, FALSE);
};

void() W_ScoutDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_scout  = self.mag_scout;
    tgt.ammo_scout = self.ammo_scout;

    self.mag_scout  = 0;
    self.ammo_scout = 0;

    setmodel(tgt, "models/w_scout.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_scout";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_SCOUT;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_ScoutEquip;
    tgt.weap_drop_func = W_ScoutDrop;
    tgt.pickupcopy   = W_ScoutPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_scout =
{
    setmodel(self, "models/w_scout.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_scout";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_SCOUT;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_ScoutEquip;
    self.weap_drop_func = W_ScoutDrop;
    self.pickupcopy    = W_ScoutPickupCopy;
    self.touch         = weapon_touch;
    self.mag_scout     = MAX_MAG_SCOUT;
    self.ammo_scout    = MAX_AMMO_SCOUT;
    W_RegisterMapWeapon(weapon_scout);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_scout_snd_stage;
float csqc_scout_snd_action;

void() CSQC_PredictScoutCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_scout_snd_action)
    {
        csqc_scout_snd_action = predicted_player.wep_action_id;
        csqc_scout_snd_stage  = 0;
    }

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_ScoutTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_csawp/zoom.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_ScoutTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_scout_snd_stage = 0;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csscout/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(self.zoomstage > 0 ? 0 : SCOUT_BASE_SPREAD, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED,
                    SCOUT_CLOSE_DAMAGE, SCOUT_MIN_DAMAGE, SCOUT_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    SCOUT_KICK_PITCH, SCOUT_KICK_VARIANCE, SCOUT_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Sniper muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(SCOUT_MUZZLE_FORWARD, SCOUT_MUZZLE_RIGHT,
                    SCOUT_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(SCOUT_MUZZLE_FORWARD, SCOUT_MUZZLE_RIGHT,
                    SCOUT_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
            self.zoomstage = 0;
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

    // Predicted bolt-cycle / reload sounds, timed off the loaded model's own
    // sequence durations rather than a stepped frame number.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_FIRE)
        {
            if (csqc_scout_snd_stage < 1
                && elapsed >= SH_ScoutFireDuration() * SCOUT_FIRE_F_BOLT)
            {
                localsound("sounds/weapons/wpn_csscout/bolt.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_scout_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_ScoutReloadDuration();

            if (csqc_scout_snd_stage < 1 && elapsed >= rel * SCOUT_RELOAD_F_CLIPOUT)
            {
                localsound("sounds/weapons/wpn_csscout/clipout.wav"); CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_scout_snd_stage = 1;
            }
            if (csqc_scout_snd_stage < 2 && elapsed >= rel * SCOUT_RELOAD_F_CLIPIN)
            { localsound("sounds/weapons/wpn_csscout/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_scout_snd_stage = 2; }
        }
    }

    SH_ScoutTickState(csqc_pred_time);
};

void() CSQC_PredictScoutReload =
{
    if (SH_ScoutTryReload(csqc_pred_time))
    {
        csqc_scout_snd_stage  = 0;
        csqc_scout_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_ScoutDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_ScoutSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_ScoutSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_ScoutSeqShoot();

    return SH_ScoutSeqIdle();
};

void() CSQC_ScoutDropClear =
{
	self.mag_scout = 0;
	self.ammo_scout = 0;
	self.zoomstage = 0;
};

void() CSQC_ScoutEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_scout", SCOPE_CLASS_SNIPER_BOLT);
	self.weapon_name         = SCOUT_DISPLAY_NAME;
	self.weapon_viewmodel    = SCOUT_VIEWMODEL;
	self.weapon_worldmodel   = SCOUT_WORLDMODEL;
	self.weapon_deploy_sound = SCOUT_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictScoutCommand;
	self.csqc_predict_reload = CSQC_PredictScoutReload;
	self.csqc_display_frame  = CSQC_ScoutDisplayFrame;
	self.csqc_drop_clear     = CSQC_ScoutDropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED.  The FALSE that used to sit here described the OLD bundled
	// viewmodel (models/weapons/wpn_csscout/v_scout.mdl), an IDPO re-bake.  This
	// weapon now draws stock cstrike models/v_scout.mdl, whose arm meshes are the
	// ones v_aug / v_glock18 / v_usp use — all flipped.  cl_lefthand XORs.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
