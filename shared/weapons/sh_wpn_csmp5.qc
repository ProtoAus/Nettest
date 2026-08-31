// ============================================================
//  shared/weapons/sh_wpn_csmp5.qc  -  CS MP5
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 120 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_mp5;
.float ammo_mp5;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_mp5.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName, see sh_wpn_csaug.qc
// for why (cstrike and czero both ship this filename at different frame counts).
// Read out of cstrike/models/v_mp5.mdl itself:
//   [0] idle1   12fps   9f  0.667s
//   [1] reload  38fps 101f  2.632s  f15 "mp5_clipout" f46 "mp5_clipin" f77 "mp5_slideback"
//   [2] draw    35fps  31f  0.857s  f13 "mp5_slideback"
//   [3] shoot1  30fps  21f  0.667s  f0 5001 (muzzleflash, attachment 1)
//   [4] shoot2  30fps  21f  0.667s
//   [5] shoot3  30fps  21f  0.667s
const float MP5_SEQ_IDLE   = 0;
const float MP5_SEQ_RELOAD = 1;
const float MP5_SEQ_DRAW   = 2;
const float MP5_SEQ_SHOOT1 = 3;
const float MP5_SEQ_SHOOT2 = 4;
const float MP5_SEQ_SHOOT3 = 5;

const float MP5_FRAME_INTERVAL        = 0.0333334;   // state-machine tick rate
const float MP5_FIRE_DELAY            = 0.1;

// Event marks as a FRACTION of their sequence.
const float MP5_DRAW_F_SLIDE          = 0.4333;   // frame 13 / 30
const float MP5_RELOAD_F_CLIPOUT      = 0.1500;   // frame 15 / 100
const float MP5_RELOAD_F_CLIPIN       = 0.4600;   // frame 46 / 100
const float MP5_RELOAD_F_SLIDE        = 0.7700;   // frame 77 / 100
const float MP5_RELOAD_F_APPLY        = 0.8000;   // just after the bolt runs forward

const float MAX_MAG_MP5               = 30;
const float MAX_AMMO_MP5              = 120;

// --- Balance ---
const float MP5_BASE_SPREAD           = 0.01;
const float MP5_MOVE_SPREAD           = 0.06;
const float MP5_FULL_SPREAD_SPEED     = 320;
const float MP5_CLOSE_DAMAGE          = 12;
const float MP5_MIN_DAMAGE            = 6;
const float MP5_DAMAGE_FALLOFF_RANGE  = 2048;
const float MP5_DRYFIRE_DELAY         = 0.2;
const float MP5_KICK_PITCH    = 0.7;   // sv_gunkick — SMG, light per-shot kick that builds.
const float MP5_KICK_VARIANCE = 0.3;
const float MP5_KICK_STRENGTH = 1.2;  // SMG — high fire rate, lower per-shot strength.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float MP5_MUZZLE_FORWARD = 42;
const float MP5_MUZZLE_RIGHT   = 10.25;
const float MP5_MUZZLE_DOWN    = 6;

// v_/w_/p_ all resolve through the mounted cstrike gamedir.  The w_ and p_ paths
// already did; the viewmodel was a mod-bundled IDPO re-bake, which is why this
// gun read as "the game version, not the mounted version".  Switching the path
// alone would play a different animation at every index, so the animation half
// of this file moved to sequence-driven with it.
const string MP5_VIEWMODEL    = "models/v_mp5.mdl";
const string MP5_WORLDMODEL   = "models/w_mp5.mdl";
const string MP5_DEPLOY_SOUND = "";
const string MP5_DISPLAY_NAME = "MP5";

// Sound stage latch — a sequence-driven model never steps weaponframe.
.float mp5_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_MP5SeqIdle   = { return SH_SeqForName(MP5_VIEWMODEL, "idle1",  MP5_SEQ_IDLE); };
float() SH_MP5SeqReload = { return SH_SeqForName(MP5_VIEWMODEL, "reload", MP5_SEQ_RELOAD); };
float() SH_MP5SeqDraw   = { return SH_SeqForName(MP5_VIEWMODEL, "draw",   MP5_SEQ_DRAW); };
float() SH_MP5SeqShoot1 = { return SH_SeqForName(MP5_VIEWMODEL, "shoot1", MP5_SEQ_SHOOT1); };
float() SH_MP5SeqShoot2 = { return SH_SeqForName(MP5_VIEWMODEL, "shoot2", MP5_SEQ_SHOOT2); };
float() SH_MP5SeqShoot3 = { return SH_SeqForName(MP5_VIEWMODEL, "shoot3", MP5_SEQ_SHOOT3); };

float(float action_id) SH_MP5PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_MP5SeqShoot1();
    if (r < 0.6667) return SH_MP5SeqShoot2();
    return SH_MP5SeqShoot3();
};

float() SH_MP5DrawDuration   = { return SH_SeqDuration(MP5_VIEWMODEL, SH_MP5SeqDraw(),   0.857); };
float() SH_MP5ReloadDuration = { return SH_SeqDuration(MP5_VIEWMODEL, SH_MP5SeqReload(), 2.632); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_MP5TickState =
{
    float rel = SH_MP5ReloadDuration();
    return SH_StandardTickState(now, mag_mp5, ammo_mp5, MAX_MAG_MP5,
        SH_MP5DrawDuration(),
        SH_SeqDuration(MP5_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * MP5_RELOAD_F_APPLY);
};

float(float now) SH_MP5TryFire =
{
    return SH_StandardTryFire(now, mag_mp5, MP5_FIRE_DELAY, MP5_DRYFIRE_DELAY);
};

float(float now) SH_MP5TryReload =
{
    return SH_StandardTryReload(now, mag_mp5, ammo_mp5, MAX_MAG_MP5, SH_MP5ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_MP5PickupCopy =
{ player.mag_mp5 = self.mag_mp5; player.ammo_mp5 = self.ammo_mp5; };

void() W_MP5Shoot =
{
    W_PenetratingHitscanShoot(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED,
        MP5_CLOSE_DAMAGE, MP5_MIN_DAMAGE, MP5_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        MP5_KICK_PITCH, MP5_KICK_VARIANCE, MP5_KICK_STRENGTH);
};

void() W_MP5Fire =
{
    float r = SH_MP5TryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SH_MP5PickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + MP5_FRAME_INTERVAL;
        self.mp5_snd_stage = 0;
        W_MP5Shoot();
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RED, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_MP5Reload =
{
    if (SH_MP5TryReload(time))
    {
        self.weaponframe   = SH_MP5SeqReload();
        self.wep_nextframe = time + MP5_FRAME_INTERVAL;
        self.mp5_snd_stage = 0;
    }
};

void() W_MP5Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += MP5_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_MP5DrawDuration() * MP5_DRAW_F_SLIDE && self.mp5_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);
            self.mp5_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_MP5ReloadDuration();

        if (elapsed >= rel * MP5_RELOAD_F_CLIPOUT && self.mp5_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.mp5_snd_stage = 1;
        }
        if (elapsed >= rel * MP5_RELOAD_F_CLIPIN && self.mp5_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipin.wav", 1, ATTN_NORM);
            self.mp5_snd_stage = 2;
        }
        if (elapsed >= rel * MP5_RELOAD_F_SLIDE && self.mp5_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);
            self.mp5_snd_stage = 3;
        }
    }

    result = SH_MP5TickState(time);
    if (result & 1)
    { self.weaponframe = SH_MP5SeqIdle(); self.wep_nextframe = 0; self.mp5_snd_stage = 0; }
};

void() W_MP5Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csmp5", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(MP5_VIEWMODEL, MP5_DISPLAY_NAME, SH_MP5SeqDraw(),
        MP5_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_MP5Fire;
    self.reload   = W_MP5Reload;
    self.wepframe = W_MP5Frame;
    self.shoot    = W_MP5Shoot;
    self.mp5_snd_stage = 0;
    W_SetCrosshairProfile(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_MP5Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_mp5 = self.mag_mp5; tgt.ammo_mp5 = self.ammo_mp5;
    self.mag_mp5 = 0; self.ammo_mp5 = 0;
    setmodel(tgt, "models/w_mp5.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_csmp5"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSMP5; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_MP5Equip; tgt.weap_drop_func = W_MP5Drop;
    tgt.pickupcopy = W_MP5PickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csmp5 =
{
    setmodel(self, "models/w_mp5.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_csmp5"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSMP5; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_MP5Equip; self.weap_drop_func = W_MP5Drop;
    self.pickupcopy = W_MP5PickupCopy; self.touch = weapon_touch;
    self.mag_mp5 = MAX_MAG_MP5; self.ammo_mp5 = MAX_AMMO_MP5;
    W_RegisterMapWeapon(weapon_csmp5);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_mp5_snd_stage;
float csqc_mp5_snd_action;

void() CSQC_PredictMP5Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_mp5_snd_action)
    {
        csqc_mp5_snd_action = predicted_player.wep_action_id;
        csqc_mp5_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_MP5TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED,
                    MP5_CLOSE_DAMAGE, MP5_MIN_DAMAGE, MP5_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    MP5_KICK_PITCH, MP5_KICK_VARIANCE, MP5_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/redcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // SMG muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(MP5_MUZZLE_FORWARD, MP5_MUZZLE_RIGHT,
                    MP5_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(MP5_MUZZLE_FORWARD, MP5_MUZZLE_RIGHT,
                    MP5_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }
    // Predicted draw / reload sounds, timed off the loaded model's own
    // sequence durations rather than a stepped frame number.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_mp5_snd_stage < 1
                && elapsed >= SH_MP5DrawDuration() * MP5_DRAW_F_SLIDE)
            {
                localsound("sounds/weapons/wpn_csmp5/slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mp5_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_MP5ReloadDuration();

            if (csqc_mp5_snd_stage < 1 && elapsed >= rel * MP5_RELOAD_F_CLIPOUT)
            {
                localsound("sounds/weapons/wpn_csmp5/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_mp5_snd_stage = 1;
            }
            if (csqc_mp5_snd_stage < 2 && elapsed >= rel * MP5_RELOAD_F_CLIPIN)
            {
                localsound("sounds/weapons/wpn_csmp5/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mp5_snd_stage = 2;
            }
            if (csqc_mp5_snd_stage < 3 && elapsed >= rel * MP5_RELOAD_F_SLIDE)
            {
                localsound("sounds/weapons/wpn_csmp5/slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mp5_snd_stage = 3;
            }
        }
    }

    SH_MP5TickState(csqc_pred_time);
};

void() CSQC_PredictMP5Reload =
{
    if (SH_MP5TryReload(csqc_pred_time))
    {
        csqc_mp5_snd_stage  = 0;
        csqc_mp5_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_MP5DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_MP5SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_MP5SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_MP5PickShootSeq(predicted_player.wep_action_id);

    return SH_MP5SeqIdle();
};

void() CSQC_MP5DropClear =
{
	self.mag_mp5 = 0;
	self.ammo_mp5 = 0;
};

void() CSQC_MP5Equip =
{
	W_SetADSProfile(TRUE, "cl_ads_csmp5", SCOPE_CLASS_NONE);
	self.weapon_name         = MP5_DISPLAY_NAME;
	self.weapon_viewmodel    = MP5_VIEWMODEL;
	self.weapon_worldmodel   = MP5_WORLDMODEL;
	self.weapon_deploy_sound = MP5_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictMP5Command;
	self.csqc_predict_reload = CSQC_PredictMP5Reload;
	self.csqc_display_frame  = CSQC_MP5DisplayFrame;
	self.csqc_drop_clear     = CSQC_MP5DropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — models/v_mp5.mdl draws the same stock cstrike arm as v_aug /
	// v_glock18 / v_usp, all of which are flipped.  cl_lefthand XORs against it.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
