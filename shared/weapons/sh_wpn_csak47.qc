// ============================================================
//  shared/weapons/sh_wpn_csak47.qc  -  CS AK47
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_ak47;
.float ammo_ak47;

// --- Animation frames ---
const float AK47_FRAME_INTERVAL      = 0.0333334;   // 1/30

const float AK47_DRAW_START          = 111;
const float AK47_DRAW_END            = 138;
const float AK47_DRAW_BOLTPULL_FRAME = 120;

const float AK47_FIRE_START          = 140;
const float AK47_FIRE_END            = 147;
const float AK47_FIRE_DELAY          = 0.1;

const float AK47_RELOAD_START        = 18;
const float AK47_RELOAD_END          = 108;
const float AK47_RELOAD_CLIPOUT      = 30;
const float AK47_RELOAD_CLIPIN       = 72;
const float AK47_RELOAD_APPLY        = 83;

const float AK47_IDLE_FRAME          = 20;

const float MAX_MAG_AK47             = 30;
const float MAX_AMMO_AK47            = 90;

// --- Balance ---
const float AK47_BASE_SPREAD          = 0.01;
const float AK47_MOVE_SPREAD          = 0.07;
const float AK47_FULL_SPREAD_SPEED    = 320;
const float AK47_CLOSE_DAMAGE         = 34;
const float AK47_MIN_DAMAGE           = 20;
const float AK47_DAMAGE_FALLOFF_RANGE = 2304;
const float AK47_DRYFIRE_DELAY        = 0.2;

// sv_gunkick — heavy rifle, sustained-fire upward climb with notable
// horizontal jitter. AK is the headline auto rifle; kick should
// dominate the spread system after ~3 shots into a burst so users
// must drag down to keep the cone on target.
const float AK47_KICK_PITCH    = 1.6;
const float AK47_KICK_VARIANCE = 1.5;
const float AK47_KICK_STRENGTH = 1.0;   // baseline auto rifle.

// Camera-local muzzle offset for the two-frame sprite muzzle flash
// (cl_muzzleflash.qc CSQC_MuzzleFlashAtMuzzle). Tune to align the
// flash with where v_ak47.mdl's barrel sits in screen space.
//   FORWARD  qu in front of the camera origin
//   RIGHT    qu to the right (cl_lefthand mirrors)
//   DOWN     qu below the camera origin
const float AK47_MUZZLE_FORWARD = 42;
const float AK47_MUZZLE_RIGHT   = 10;
const float AK47_MUZZLE_DOWN    = 7;

// --- Pre-computed state durations ---
const float AK47_DRAW_DURATION      = (AK47_DRAW_END - AK47_DRAW_START) * AK47_FRAME_INTERVAL;
const float AK47_FIRE_DURATION      = (AK47_FIRE_END - AK47_FIRE_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_DURATION    = (AK47_RELOAD_END - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_APPLY_TIME  = (AK47_RELOAD_APPLY - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;

const string AK47_VIEWMODEL    = "models/weapons/wpn_csak47/v_ak47.mdl";
const string AK47_WORLDMODEL   = "models/weapons/wpn_csak47/w_ak47.mdl";
const string AK47_DEPLOY_SOUND = "";
const string AK47_DISPLAY_NAME = "AK47";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_AK47TickState =
{
    return SH_StandardTickState(now, mag_ak47, ammo_ak47, MAX_MAG_AK47,
        AK47_DRAW_DURATION, AK47_FIRE_DURATION,
        AK47_RELOAD_DURATION, AK47_RELOAD_APPLY_TIME);
};

float(float now) SH_AK47TryFire =
{
    return SH_StandardTryFire(now, mag_ak47, AK47_FIRE_DELAY, AK47_DRYFIRE_DELAY);
};

float(float now) SH_AK47TryReload =
{
    return SH_StandardTryReload(now, mag_ak47, ammo_ak47, MAX_MAG_AK47, AK47_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_AK47PickupCopy =
{
    player.mag_ak47  = self.mag_ak47;
    player.ammo_ak47 = self.ammo_ak47;
};

void() W_AK47Shoot =
{
    W_PenetratingHitscanShoot(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED,
        AK47_CLOSE_DAMAGE, AK47_MIN_DAMAGE, AK47_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        AK47_KICK_PITCH, AK47_KICK_VARIANCE, AK47_KICK_STRENGTH);
};

void() W_AK47Fire =
{
    float r = SH_AK47TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = AK47_FIRE_START;
        self.wep_nextframe = time + AK47_FRAME_INTERVAL;

        W_AK47Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_AK47Reload =
{
    if (SH_AK47TryReload(time))
    {
        self.weaponframe   = AK47_RELOAD_START;
        self.wep_nextframe = time + AK47_FRAME_INTERVAL;
    }
};

void() W_AK47Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += AK47_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW && self.weaponframe == AK47_DRAW_BOLTPULL_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/boltpull.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == AK47_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == AK47_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipin.wav", 1, ATTN_NORM);
    }

    result = SH_AK47TickState(time);
    if (result & 1)
    {
        self.weaponframe   = AK47_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_AK47Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ak47", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(AK47_VIEWMODEL, AK47_DISPLAY_NAME, AK47_DRAW_START,
        AK47_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_AK47Fire;
    self.reload   = W_AK47Reload;
    self.wepframe = W_AK47Frame;
    self.shoot    = W_AK47Shoot;
    W_SetCrosshairProfile(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_AK47Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_ak47  = self.mag_ak47;
    tgt.ammo_ak47 = self.ammo_ak47;

    self.mag_ak47  = 0;
    self.ammo_ak47 = 0;

    setmodel(tgt, "models/weapons/wpn_csak47/w_ak47.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_ak47";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_AK47;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_AK47Equip;
    tgt.weap_drop_func = W_AK47Drop;
    tgt.pickupcopy   = W_AK47PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_ak47 =
{
    setmodel(self, "models/weapons/wpn_csak47/w_ak47.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_ak47";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_AK47;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_AK47Equip;
    self.weap_drop_func = W_AK47Drop;
    self.pickupcopy    = W_AK47PickupCopy;
    self.touch         = weapon_touch;
    self.mag_ak47      = MAX_MAG_AK47;
    self.ammo_ak47     = MAX_AMMO_AK47;
    W_RegisterMapWeapon(weapon_ak47);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Pre-computed time for boltpull sound during draw
const float AK47_DRAW_BOLTPULL_TIME = (AK47_DRAW_BOLTPULL_FRAME - AK47_DRAW_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_CLIPOUT_TIME = (AK47_RELOAD_CLIPOUT - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_CLIPIN_TIME = (AK47_RELOAD_CLIPIN - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;

float csqc_ak47_draw_snd_played;
float csqc_ak47_reload_snd_stage;

void() CSQC_PredictAK47Command =
{
    float r;

    // Play draw boltpull sound at the correct frame time
    if (self.weaponstate == WS_DRAW && !pm_suppress_sounds && !csqc_ak47_draw_snd_played)
    {
        float elapsed = (self.wep_anim_start > 0) ? (csqc_pred_time - self.wep_anim_start) : 0;
        if (elapsed >= AK47_DRAW_BOLTPULL_TIME)
        {
            localsound("sounds/weapons/wpn_csak47/boltpull.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_ak47_draw_snd_played = TRUE;
        }
    }
    else if (self.weaponstate != WS_DRAW)
    {
        csqc_ak47_draw_snd_played = FALSE;
    }

    if (input_buttons & 1)
    {
        r = SH_AK47TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                // CHAN_WEAPON cuts previous fire sound (no overlap)
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED,
                    AK47_CLOSE_DAMAGE, AK47_MIN_DAMAGE, AK47_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    AK47_KICK_PITCH, AK47_KICK_VARIANCE, AK47_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Two-frame additive muzzle flash at the rifle's
                // muzzle. Tune via AK47_MUZZLE_* constants at the top
                // of this file.
                CSQC_MuzzleFlashAtMuzzle(AK47_MUZZLE_FORWARD, AK47_MUZZLE_RIGHT,
                    AK47_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(AK47_MUZZLE_FORWARD, AK47_MUZZLE_RIGHT,
                    AK47_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_ak47_reload_snd_stage < 1 && reload_elapsed >= AK47_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csak47/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_ak47_reload_snd_stage = 1;
        }
        if (csqc_ak47_reload_snd_stage < 2 && reload_elapsed >= AK47_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csak47/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_ak47_reload_snd_stage = 2; }
    }

    SH_AK47TickState(csqc_pred_time);
};

void() CSQC_PredictAK47Reload =
{
    if (SH_AK47TryReload(csqc_pred_time))
    { csqc_ak47_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_AK47DisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, AK47_FRAME_INTERVAL,
        AK47_DRAW_START, AK47_DRAW_END,
        AK47_FIRE_START, AK47_FIRE_END,
        AK47_RELOAD_START, AK47_RELOAD_END,
        AK47_IDLE_FRAME);
};

void() CSQC_AK47DropClear =
{
	self.mag_ak47 = 0;
	self.ammo_ak47 = 0;
};

void() CSQC_AK47Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ak47", SCOPE_CLASS_NONE);
	self.weapon_name         = AK47_DISPLAY_NAME;
	self.weapon_viewmodel    = AK47_VIEWMODEL;
	self.weapon_worldmodel   = AK47_WORLDMODEL;
	self.weapon_deploy_sound = AK47_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictAK47Command;
	self.csqc_predict_reload = CSQC_PredictAK47Reload;
	self.csqc_display_frame  = CSQC_AK47DisplayFrame;
	self.csqc_drop_clear     = CSQC_AK47DropClear;
    self.weapon_viewmodel_flip = TRUE;

	// Snapshot-driven equip suppresses the predicted boltpull sound.
	// CSQC_PredictSelectWeapon (cl_weapons.qc) sets weaponstate=WS_DRAW
	// BEFORE calling CSQC_WeaponEquip, so on a LOCAL switch we see
	// WS_DRAW here.  The snapshot reconcile path (cl_player.qc:830)
	// calls CSQC_WeaponEquip BEFORE setting WS_DRAW — at this point
	// weaponstate is the prior frame's (WS_DEAD on respawn, WS_IDLE
	// on fresh spawn, etc.).  When the server is the driver, its
	// W_AK47Frame already emits the boltpull on CHAN_AUTO; that
	// sound rides the same snapshot packet as the WS_DRAW state and
	// gets played by the engine BEFORE any CSQC predict tick can
	// stamp csqc_last_predicted_auto_sound_time, so the dedup window
	// is empty.  Latching here means the next predict tick skips its
	// own localsound, avoiding the double boltpull.
	if (self.weaponstate != WS_DRAW)
		csqc_ak47_draw_snd_played = TRUE;
};

#endif // CSQC
