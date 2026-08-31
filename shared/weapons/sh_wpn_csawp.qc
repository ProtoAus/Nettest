// ============================================================
//  shared/weapons/sh_wpn_csawp.qc  -  CS AWP
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 20 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_awp;
.float ammo_awp;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_awp.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName; see sh_wpn_csaug.qc.
// Read out of cstrike/models/v_awp.mdl itself.  NOTE the ordering: unlike the
// AK/MP5 this model puts the three shoot takes BEFORE reload and draw, so an
// index-keyed lookup against the AK's layout would play reload as a shot.
//   [0] idle1   16fps   9f  0.500s
//   [1] shoot1  35fps  42f  1.171s  f15 "boltup" f19 "boltpull1" f32 "boltdown"
//   [2] shoot2  35fps  42f  1.171s  (same three)
//   [3] shoot3  35fps  42f  1.171s  (same three)
//   [4] reload  30fps  88f  2.900s  f26 "awp_clipout" f53 "awp_clipin"
//   [5] draw    30fps  31f  1.000s  (no events — the deploy sound is ours)
const float AWP_SEQ_IDLE   = 0;
const float AWP_SEQ_SHOOT1 = 1;
const float AWP_SEQ_SHOOT2 = 2;
const float AWP_SEQ_SHOOT3 = 3;
const float AWP_SEQ_RELOAD = 4;
const float AWP_SEQ_DRAW   = 5;

const float AWP_FRAME_INTERVAL        = 0.0333334;   // state-machine tick rate
const float AWP_FIRE_DELAY            = 1.2;

// Event marks as a FRACTION of their sequence.
const float AWP_FIRE_F_BOLTUP         = 0.3659;   // frame 15 / 41
const float AWP_FIRE_F_BOLTPULL       = 0.4634;   // frame 19 / 41
const float AWP_FIRE_F_BOLTDOWN       = 0.7805;   // frame 32 / 41
const float AWP_RELOAD_F_CLIPOUT      = 0.2989;   // frame 26 / 87
const float AWP_RELOAD_F_CLIPIN       = 0.6092;   // frame 53 / 87
const float AWP_RELOAD_F_APPLY        = 0.6500;   // just after the fresh mag seats

const float MAX_MAG_AWP               = 10;
const float MAX_AMMO_AWP              = 20;

// --- Balance ---
const float AWP_BASE_SPREAD           = 0.01;
const float AWP_MOVE_SPREAD           = 0.10;
const float AWP_FULL_SPREAD_SPEED     = 320;
const float AWP_CLOSE_DAMAGE          = 140;
const float AWP_MIN_DAMAGE            = 140;
const float AWP_DAMAGE_FALLOFF_RANGE  = 4096;
const float AWP_DRYFIRE_DELAY         = 0.2;
const float AWP_KICK_PITCH    = 4.0;   // sv_gunkick — bolt sniper, huge single kick.
const float AWP_KICK_VARIANCE = 0.7;
const float AWP_KICK_STRENGTH = 1.0;   // single-shot bolt — heaviest kick.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float AWP_MUZZLE_FORWARD = 52;
const float AWP_MUZZLE_RIGHT   = 6.9;
const float AWP_MUZZLE_DOWN    = 3.6;

// v_/w_/p_ all resolve through the mounted cstrike gamedir.  Only the viewmodel
// moved — it was a mod-bundled IDPO re-bake — so the animation half of this file
// went sequence-driven with the path.
const string AWP_VIEWMODEL    = "models/v_awp.mdl";
const string AWP_WORLDMODEL   = "models/w_awp.mdl";
const string AWP_DEPLOY_SOUND = "sounds/weapons/wpn_csawp/deploy.wav";
const string AWP_DISPLAY_NAME = "AWP";

// Sound stage latch — a sequence-driven model never steps weaponframe.
.float awp_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_AWPSeqIdle   = { return SH_SeqForName(AWP_VIEWMODEL, "idle1",  AWP_SEQ_IDLE); };
float() SH_AWPSeqReload = { return SH_SeqForName(AWP_VIEWMODEL, "reload", AWP_SEQ_RELOAD); };
float() SH_AWPSeqDraw   = { return SH_SeqForName(AWP_VIEWMODEL, "draw",   AWP_SEQ_DRAW); };
float() SH_AWPSeqShoot1 = { return SH_SeqForName(AWP_VIEWMODEL, "shoot1", AWP_SEQ_SHOOT1); };
float() SH_AWPSeqShoot2 = { return SH_SeqForName(AWP_VIEWMODEL, "shoot2", AWP_SEQ_SHOOT2); };
float() SH_AWPSeqShoot3 = { return SH_SeqForName(AWP_VIEWMODEL, "shoot3", AWP_SEQ_SHOOT3); };

float(float action_id) SH_AWPPickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_AWPSeqShoot1();
    if (r < 0.6667) return SH_AWPSeqShoot2();
    return SH_AWPSeqShoot3();
};

float() SH_AWPDrawDuration   = { return SH_SeqDuration(AWP_VIEWMODEL, SH_AWPSeqDraw(),   1.000); };
float() SH_AWPReloadDuration = { return SH_SeqDuration(AWP_VIEWMODEL, SH_AWPSeqReload(), 2.900); };
float() SH_AWPFireDuration   = { return SH_SeqDuration(AWP_VIEWMODEL, SH_AWPSeqShoot1(), 1.171); };

// ============================================================
//  SHARED — state machine
// ============================================================

// THE FIRE DURATION MUST NOT COME FROM self.weaponframe, and this is the bug
// behind "the cs awp animation after firing doesn't do the complete bolt pull
// back sequence".
//
// .weaponframe is stamped by the SERVER (W_AWPFire) and is never written
// anywhere on the client: predicted_player is a mod-spawned CSQC entity
// (cl_player.qc:1380) and no parse path assigns the field, so client-side it
// reads 0 — permanently.  Sequence 0 on every GoldSrc viewmodel is `idle1`, and
// on this model idle1 is 0.500 s against shoot1's 1.171 s.  So CSQC retired
// WS_FIRE at 43 % of the take: `boltup` (frac 0.366) had just played, and
// `boltpull1` (0.463) and `boltdown` (0.780) were both still ahead of it when
// the display frame snapped back to the idle pose.  The two lost bolt SOUNDS
// went with them — they are gated on weaponstate == WS_FIRE.
//
// SH_AWPFireDuration reads shoot1 by name, and all three shoot takes are the
// same 1.171 s, so this is identical to the old expression server-side and
// correct client-side.  The same `self.weaponframe` pattern is used by ~70 other
// weapon files; the AWP is the loudest because its shoot take is the longest
// relative to its idle in the whole tree.
float(float now) SH_AWPTickState =
{
    float rel = SH_AWPReloadDuration();
    return SH_StandardTickState(now, mag_awp, ammo_awp, MAX_MAG_AWP,
        SH_AWPDrawDuration(),
        SH_AWPFireDuration(),
        rel, rel * AWP_RELOAD_F_APPLY);
};

float(float now) SH_AWPTryFire =
{
    // Don't clear zoomstage here — Shoot needs it for spread calculation.
    // Zoomstage is cleared in W_AWPFire / CSQC prediction AFTER the shot.
    return SH_StandardTryFire(now, mag_awp, AWP_FIRE_DELAY, AWP_DRYFIRE_DELAY);
};

float(float now) SH_AWPTryReload =
{
    float r = SH_StandardTryReload(now, mag_awp, ammo_awp, MAX_MAG_AWP, SH_AWPReloadDuration());
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

float(float now) SH_AWPTryAltFire =
{
    // sv_codscopes short-circuit — see SH_ScoutTryAltFire for the
    // full rationale.  CoD mode owns scope visuals via cl_codscope.qc.
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

void(entity player) W_AWPPickupCopy =
{
    player.mag_awp  = self.mag_awp;
    player.ammo_awp = self.ammo_awp;
};

void() W_AWPShoot =
{
    if (self.zoomstage > 0)
        W_PenetratingHitscanShoot(0, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED,
            AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE, 128, 0.985,
            AWP_KICK_PITCH, AWP_KICK_VARIANCE, AWP_KICK_STRENGTH);
    else
        W_PenetratingHitscanShoot(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED,
            AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE, 128, 0.985,
            AWP_KICK_PITCH, AWP_KICK_VARIANCE, AWP_KICK_STRENGTH);
};

void() W_AWPFire =
{
    float r = SH_AWPTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SH_AWPPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        self.awp_snd_stage = 0;
        W_AWPShoot();
        self.zoomstage = 0;
        self.sv_zoomstage = 0;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_AWPAltFire =
{
    if (SH_AWPTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_AWPReload =
{
    if (SH_AWPTryReload(time))
    {
        self.weaponframe   = SH_AWPSeqReload();
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        self.awp_snd_stage = 0;
        self.sv_zoomstage  = 0;
    }
};

void() W_AWPFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += AWP_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        float fir = SH_AWPFireDuration();

        if (elapsed >= fir * AWP_FIRE_F_BOLTUP && self.awp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltup.wav", 1, ATTN_NORM);
            self.awp_snd_stage = 1;
        }
        if (elapsed >= fir * AWP_FIRE_F_BOLTPULL && self.awp_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltpull.wav", 1, ATTN_NORM);
            self.awp_snd_stage = 2;
        }
        if (elapsed >= fir * AWP_FIRE_F_BOLTDOWN && self.awp_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltdown.wav", 1, ATTN_NORM);
            self.awp_snd_stage = 3;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_AWPReloadDuration();

        if (elapsed >= rel * AWP_RELOAD_F_CLIPOUT && self.awp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.awp_snd_stage = 1;
        }
        if (elapsed >= rel * AWP_RELOAD_F_CLIPIN && self.awp_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipin.wav", 1, ATTN_NORM);
            self.awp_snd_stage = 2;
        }
    }

    result = SH_AWPTickState(time);
    if (result & 1)
    { self.weaponframe = SH_AWPSeqIdle(); self.wep_nextframe = 0; self.awp_snd_stage = 0; }
};

void() W_AWPEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_awp", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(AWP_VIEWMODEL, AWP_DISPLAY_NAME, SH_AWPSeqDraw(),
        AWP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.awp_snd_stage = 0;
    self.fire     = W_AWPFire;
    self.reload   = W_AWPReload;
    self.wepframe = W_AWPFrame;
    self.altfire  = W_AWPAltFire;
    self.shoot    = W_AWPShoot;
    W_ClearZoom();
    W_SetCrosshairProfile(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_AWPDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_awp = self.mag_awp; tgt.ammo_awp = self.ammo_awp;
    self.mag_awp = 0; self.ammo_awp = 0;

    setmodel(tgt, "models/w_awp.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_csawp"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSAWP; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_AWPEquip; tgt.weap_drop_func = W_AWPDrop;
    tgt.pickupcopy = W_AWPPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csawp =
{
    setmodel(self, "models/w_awp.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_csawp"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSAWP; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_AWPEquip; self.weap_drop_func = W_AWPDrop;
    self.pickupcopy = W_AWPPickupCopy; self.touch = weapon_touch;
    self.mag_awp = MAX_MAG_AWP; self.ammo_awp = MAX_AMMO_AWP;
    W_RegisterMapWeapon(weapon_csawp);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_awp_snd_stage;
float csqc_awp_snd_action;

void() CSQC_PredictAWPCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_awp_snd_action)
    {
        csqc_awp_snd_action = predicted_player.wep_action_id;
        csqc_awp_snd_stage  = 0;
    }

    if (input_buttons & 4)
    {
        if (SH_AWPTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_AWPTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_awp_snd_stage = 0;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(self.zoomstage > 0 ? 0 : AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED,
                    AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE, 128, 0.985,
                    AWP_KICK_PITCH, AWP_KICK_VARIANCE, AWP_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Sniper muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(AWP_MUZZLE_FORWARD, AWP_MUZZLE_RIGHT,
                    AWP_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(AWP_MUZZLE_FORWARD, AWP_MUZZLE_RIGHT,
                    AWP_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
            self.zoomstage = 0;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted bolt-cycle / reload sounds, timed off the loaded model's own
    // sequence durations rather than a stepped frame number.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_FIRE)
        {
            float fir = SH_AWPFireDuration();

            if (csqc_awp_snd_stage < 1 && elapsed >= fir * AWP_FIRE_F_BOLTUP)
            { localsound("sounds/weapons/wpn_csawp/boltup.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_snd_stage = 1; }
            if (csqc_awp_snd_stage < 2 && elapsed >= fir * AWP_FIRE_F_BOLTPULL)
            { localsound("sounds/weapons/wpn_csawp/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_snd_stage = 2; }
            if (csqc_awp_snd_stage < 3 && elapsed >= fir * AWP_FIRE_F_BOLTDOWN)
            { localsound("sounds/weapons/wpn_csawp/boltdown.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_snd_stage = 3; }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_AWPReloadDuration();

            if (csqc_awp_snd_stage < 1 && elapsed >= rel * AWP_RELOAD_F_CLIPOUT)
            {
                localsound("sounds/weapons/wpn_csawp/clipout.wav"); CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_awp_snd_stage = 1;
            }
            if (csqc_awp_snd_stage < 2 && elapsed >= rel * AWP_RELOAD_F_CLIPIN)
            { localsound("sounds/weapons/wpn_csawp/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_snd_stage = 2; }
        }
    }

    SH_AWPTickState(csqc_pred_time);
};

void() CSQC_PredictAWPReload =
{
    if (SH_AWPTryReload(csqc_pred_time))
    {
        csqc_awp_snd_stage  = 0;
        csqc_awp_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_AWPDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_AWPSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_AWPSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_AWPPickShootSeq(predicted_player.wep_action_id);

    return SH_AWPSeqIdle();
};

void() CSQC_AWPDropClear =
{
	self.mag_awp = 0;
	self.ammo_awp = 0;
	self.zoomstage = 0;
};

void() CSQC_AWPEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_awp", SCOPE_CLASS_SNIPER_BOLT);
	self.weapon_name         = AWP_DISPLAY_NAME;
	self.weapon_viewmodel    = AWP_VIEWMODEL;
	self.weapon_worldmodel   = AWP_WORLDMODEL;
	self.weapon_deploy_sound = AWP_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictAWPCommand;
	self.csqc_predict_reload = CSQC_PredictAWPReload;
	self.csqc_display_frame  = CSQC_AWPDisplayFrame;
	self.csqc_drop_clear     = CSQC_AWPDropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — models/v_awp.mdl draws the same stock cstrike arm as v_aug /
	// v_glock18 / v_usp, all of which are flipped.  cl_lefthand XORs against it.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
