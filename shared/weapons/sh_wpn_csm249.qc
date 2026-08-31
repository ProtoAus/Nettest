// ============================================================
//  shared/weapons/sh_wpn_csm249.qc  -  CS M249 LMG
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round belt, 150 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_m249;
.float ammo_m249;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_m249.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName; see sh_wpn_csaug.qc.
// Read out of cstrike/models/v_m249.mdl itself:
//   [0] idle1   16fps  11f  0.625s
//   [1] shoot1  30fps  16f  0.500s  f0 5001 (muzzleflash, attachment 2)
//   [2] shoot2  30fps  16f  0.500s
//   [3] reload  30fps 141f  4.667s  coverup/boxout/boxin/chain/coverdown
//   [4] draw    30fps  31f  1.000s  f21 "slideback1"
//
// The old bake had a separate empty-idle frame; the stock cstrike model has no
// empty idle, so the belt stays drawn when the box runs dry.  Nothing selects a
// missing sequence — there is simply one idle.
const float M249_SEQ_IDLE   = 0;
const float M249_SEQ_SHOOT1 = 1;
const float M249_SEQ_SHOOT2 = 2;
const float M249_SEQ_RELOAD = 3;
const float M249_SEQ_DRAW   = 4;

const float M249_FRAME_INTERVAL       = 0.0333334;   // state-machine tick rate
const float M249_FIRE_DELAY           = 0.1;

// Event marks as a FRACTION of the reload sequence.
const float M249_RELOAD_F_COVERUP     = 0.1786;   // frame  25 / 140
const float M249_RELOAD_F_BOXOUT      = 0.3286;   // frame  46 / 140
const float M249_RELOAD_F_BOXIN       = 0.4786;   // frame  67 / 140
const float M249_RELOAD_F_CHAIN       = 0.6214;   // frame  87 / 140
const float M249_RELOAD_F_COVERDOWN   = 0.7643;   // frame 107 / 140
const float M249_RELOAD_F_APPLY       = 0.7000;   // once the chain is fed

const float MAX_MAG_M249              = 50;
const float MAX_AMMO_M249             = 150;

// --- Balance ---
const float M249_BASE_SPREAD          = 0.01;
const float M249_MOVE_SPREAD          = 0.12;
const float M249_FULL_SPREAD_SPEED    = 320;
const float M249_CLOSE_DAMAGE         = 14;
const float M249_MIN_DAMAGE           = 7;
const float M249_DAMAGE_FALLOFF_RANGE = 3072;
const float M249_DRYFIRE_DELAY        = 0.2;
const float M249_KICK_PITCH    = 1.5;   // sv_gunkick — LMG, heavy sustained kick.
const float M249_KICK_VARIANCE = 2.55;
const float M249_KICK_STRENGTH = 1.5;   // LMG baseline.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float M249_MUZZLE_FORWARD = 42;
const float M249_MUZZLE_RIGHT   = 7.95;
const float M249_MUZZLE_DOWN    = 3.4;

// v_/w_/p_ all resolve through the mounted cstrike gamedir.  Only the viewmodel
// moved — it was a mod-bundled IDPO re-bake — so the animation half of this file
// went sequence-driven with the path.
const string M249_VIEWMODEL    = "models/v_m249.mdl";
const string M249_WORLDMODEL   = "models/w_m249.mdl";
const string M249_DEPLOY_SOUND = "";
const string M249_DISPLAY_NAME = "M249";

// Sound stage latch — a sequence-driven model never steps weaponframe.
.float m249_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_M249SeqIdle   = { return SH_SeqForName(M249_VIEWMODEL, "idle1",  M249_SEQ_IDLE); };
float() SH_M249SeqReload = { return SH_SeqForName(M249_VIEWMODEL, "reload", M249_SEQ_RELOAD); };
float() SH_M249SeqDraw   = { return SH_SeqForName(M249_VIEWMODEL, "draw",   M249_SEQ_DRAW); };
float() SH_M249SeqShoot1 = { return SH_SeqForName(M249_VIEWMODEL, "shoot1", M249_SEQ_SHOOT1); };
float() SH_M249SeqShoot2 = { return SH_SeqForName(M249_VIEWMODEL, "shoot2", M249_SEQ_SHOOT2); };

// Only two shoot takes on this model — a straight coin flip off the action id so
// client and server land on the same one.
float(float action_id) SH_M249PickShootSeq =
{
    if (SH_SpreadHash(action_id) < 0.5) return SH_M249SeqShoot1();
    return SH_M249SeqShoot2();
};

float() SH_M249DrawDuration   = { return SH_SeqDuration(M249_VIEWMODEL, SH_M249SeqDraw(),   1.000); };
float() SH_M249ReloadDuration = { return SH_SeqDuration(M249_VIEWMODEL, SH_M249SeqReload(), 4.667); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_M249TickState =
{
    float rel = SH_M249ReloadDuration();
    return SH_StandardTickState(now, mag_m249, ammo_m249, MAX_MAG_M249,
        SH_M249DrawDuration(),
        SH_SeqDuration(M249_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * M249_RELOAD_F_APPLY);
};

float(float now) SH_M249TryFire =
{
    return SH_StandardTryFire(now, mag_m249, M249_FIRE_DELAY, M249_DRYFIRE_DELAY);
};

float(float now) SH_M249TryReload =
{
    return SH_StandardTryReload(now, mag_m249, ammo_m249, MAX_MAG_M249, SH_M249ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M249PickupCopy =
{
    player.mag_m249  = self.mag_m249;
    player.ammo_m249 = self.ammo_m249;
};

void() W_M249Shoot =
{
    W_PenetratingHitscanShoot(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED,
        M249_CLOSE_DAMAGE, M249_MIN_DAMAGE, M249_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        M249_KICK_PITCH, M249_KICK_VARIANCE, M249_KICK_STRENGTH);
};

void() W_M249Fire =
{
    float r = SH_M249TryFire(time);

    if (r == 1)
    {
        // Deterministic take pick from wep_action_id so client and server agree
        // which one plays for this shot — random() would diverge.
        self.weaponframe    = SH_M249PickShootSeq(self.wep_action_id);
        self.wep_nextframe  = time + M249_FRAME_INTERVAL;
        self.m249_snd_stage = 0;

        W_M249Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_M249Reload =
{
    if (SH_M249TryReload(time))
    {
        self.weaponframe    = SH_M249SeqReload();
        self.wep_nextframe  = time + M249_FRAME_INTERVAL;
        self.m249_snd_stage = 0;
    }
};

void() W_M249Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += M249_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_M249ReloadDuration();

        if (elapsed >= rel * M249_RELOAD_F_COVERUP && self.m249_snd_stage < 1)
        { sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/coverup.wav", 1, ATTN_NORM); self.m249_snd_stage = 1; }
        if (elapsed >= rel * M249_RELOAD_F_BOXOUT && self.m249_snd_stage < 2)
        { sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/boxout.wav", 1, ATTN_NORM); self.m249_snd_stage = 2; }
        if (elapsed >= rel * M249_RELOAD_F_BOXIN && self.m249_snd_stage < 3)
        { sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/boxin.wav", 1, ATTN_NORM); self.m249_snd_stage = 3; }
        if (elapsed >= rel * M249_RELOAD_F_CHAIN && self.m249_snd_stage < 4)
        { sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/chain.wav", 1, ATTN_NORM); self.m249_snd_stage = 4; }
        if (elapsed >= rel * M249_RELOAD_F_COVERDOWN && self.m249_snd_stage < 5)
        { sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm249/coverdown.wav", 1, ATTN_NORM); self.m249_snd_stage = 5; }
    }

    result = SH_M249TickState(time);
    if (result & 1)
    {
        self.weaponframe    = SH_M249SeqIdle();
        self.wep_nextframe  = 0;
        self.m249_snd_stage = 0;
    }
};

void() W_M249Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csm249", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(M249_VIEWMODEL, M249_DISPLAY_NAME, SH_M249SeqDraw(),
        M249_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_M249Fire;
    self.reload   = W_M249Reload;
    self.wepframe = W_M249Frame;
    self.shoot    = W_M249Shoot;
    self.m249_snd_stage = 0;
    W_SetCrosshairProfile(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED, 5, TRUE);
};

void() W_M249Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_m249  = self.mag_m249;
    tgt.ammo_m249 = self.ammo_m249;

    self.mag_m249  = 0;
    self.ammo_m249 = 0;

    setmodel(tgt, "models/w_m249.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_csm249";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_M249;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_M249Equip;
    tgt.weap_drop_func = W_M249Drop;
    tgt.pickupcopy   = W_M249PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

// RENAMED FROM weapon_m249.  gearbox's M249 SAW is ALSO `weapon_m249`, and a
// GoldSrc map placing that classname means Opposing Force's belt-fed SAW, not
// Counter-Strike's — so sh_wpn_opsaw.qc took the GoldSrc name and this one moved
// aside.  Nothing regresses for CS play: this gun is handed out by loadout, buy
// menu and debug spawn, none of which go through a classname, and `weapon_m249`
// remains a manifest ALIAS pointing here for any string lookup that still uses
// the old spelling.
void() weapon_csm249 =
{
    setmodel(self, "models/w_m249.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_csm249";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_M249;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_M249Equip;
    self.weap_drop_func = W_M249Drop;
    self.pickupcopy    = W_M249PickupCopy;
    self.touch         = weapon_touch;
    self.mag_m249      = MAX_MAG_M249;
    self.ammo_m249     = MAX_AMMO_M249;
    W_RegisterMapWeapon(weapon_csm249);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_m249_snd_stage;
float csqc_m249_snd_action;

void() CSQC_PredictM249Command =
{
    float r;

    if (predicted_player.wep_action_id != csqc_m249_snd_action)
    {
        csqc_m249_snd_action = predicted_player.wep_action_id;
        csqc_m249_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_M249TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm249/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(M249_BASE_SPREAD, M249_MOVE_SPREAD, M249_FULL_SPREAD_SPEED,
                    M249_CLOSE_DAMAGE, M249_MIN_DAMAGE, M249_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    M249_KICK_PITCH, M249_KICK_VARIANCE, M249_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Rifle/MG muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(M249_MUZZLE_FORWARD, M249_MUZZLE_RIGHT,
                    M249_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(M249_MUZZLE_FORWARD, M249_MUZZLE_RIGHT,
                    M249_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted reload sounds, timed off the loaded model's own reload duration.
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel = SH_M249ReloadDuration();

        if (csqc_m249_snd_stage < 1 && reload_elapsed >= rel * M249_RELOAD_F_COVERUP)
        { localsound("sounds/weapons/wpn_csm249/coverup.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_snd_stage = 1; }
        if (csqc_m249_snd_stage < 2 && reload_elapsed >= rel * M249_RELOAD_F_BOXOUT)
        { localsound("sounds/weapons/wpn_csm249/boxout.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_snd_stage = 2; }
        if (csqc_m249_snd_stage < 3 && reload_elapsed >= rel * M249_RELOAD_F_BOXIN)
        { localsound("sounds/weapons/wpn_csm249/boxin.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_snd_stage = 3; }
        if (csqc_m249_snd_stage < 4 && reload_elapsed >= rel * M249_RELOAD_F_CHAIN)
        { localsound("sounds/weapons/wpn_csm249/chain.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_snd_stage = 4; }
        if (csqc_m249_snd_stage < 5 && reload_elapsed >= rel * M249_RELOAD_F_COVERDOWN)
        { localsound("sounds/weapons/wpn_csm249/coverdown.wav"); CSQC_RecordPredictedAutoSound(); csqc_m249_snd_stage = 5; }
    }

    SH_M249TickState(csqc_pred_time);
};

void() CSQC_PredictM249Reload =
{
    if (SH_M249TryReload(csqc_pred_time))
    {
        csqc_m249_snd_stage  = 0;
        csqc_m249_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_M249DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_M249SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_M249SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_M249PickShootSeq(predicted_player.wep_action_id);

    return SH_M249SeqIdle();
};

void() CSQC_M249DropClear =
{
	self.mag_m249 = 0;
	self.ammo_m249 = 0;
};

void() CSQC_M249Equip =
{
	W_SetADSProfile(TRUE, "cl_ads_csm249", SCOPE_CLASS_NONE);
	self.weapon_name         = M249_DISPLAY_NAME;
	self.weapon_viewmodel    = M249_VIEWMODEL;
	self.weapon_worldmodel   = M249_WORLDMODEL;
	self.weapon_deploy_sound = M249_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM249Command;
	self.csqc_predict_reload = CSQC_PredictM249Reload;
	self.csqc_display_frame  = CSQC_M249DisplayFrame;
	self.csqc_drop_clear     = CSQC_M249DropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — models/v_m249.mdl draws the same stock cstrike arm as v_aug /
	// v_glock18 / v_usp, all of which are flipped.  cl_lefthand XORs against it.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
