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

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_ak47.mdl) ---
//
// FALLBACKS ONLY.  Every one resolves by NAME at runtime through SH_SeqForName,
// because cstrike AND czero are both mounted (fs_addons.txt) and both ship
// models/v_ak47.mdl with the same labels at different frame counts.  Scaling
// every event mark by that model's own duration keeps the sounds on the
// animation whichever mount wins.  Same treatment as sh_wpn_csaug.qc.
//
// Read out of cstrike/models/v_ak47.mdl itself:
//   [0] idle1   30fps  17f  0.533s
//   [1] reload  37fps  91f  2.432s   f13 "ak47_clipout"  f57 "ak47_clipin"
//   [2] draw    30fps  31f  1.000s   f11 "ak47_boltpull"
//   [3] shoot1  20fps  17f  0.800s   f0 5001 (muzzleflash, attachment 2)
//   [4] shoot2  20fps  17f  0.800s
//   [5] shoot3  20fps  17f  0.800s
const float AK47_SEQ_IDLE   = 0;
const float AK47_SEQ_RELOAD = 1;
const float AK47_SEQ_DRAW   = 2;
const float AK47_SEQ_SHOOT1 = 3;
const float AK47_SEQ_SHOOT2 = 4;
const float AK47_SEQ_SHOOT3 = 5;

const float AK47_FRAME_INTERVAL      = 0.0333334;   // state-machine tick rate
const float AK47_FIRE_DELAY          = 0.1;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float AK47_DRAW_F_BOLT         = 0.3667;   // frame 11 / 30
const float AK47_RELOAD_F_CLIPOUT    = 0.1444;   // frame 13 / 90
const float AK47_RELOAD_F_CLIPIN     = 0.6333;   // frame 57 / 90
const float AK47_RELOAD_F_APPLY      = 0.7000;   // just after the fresh mag seats

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

// models/v_ak47.mdl, models/w_ak47.mdl and models/p_ak47.mdl all resolve
// through the mounted cstrike gamedir — the same route sh_wpn_csaug.qc takes for
// v_aug.mdl.  The w_ and p_ paths were ALREADY the mount; only the viewmodel was
// a mod-bundled IDPO (Quake-format) bake under models/weapons/wpn_csak47/, which
// is what made the AK look like the HD pack rather than stock CS.  Switching the
// path alone would have played a different animation at every index, so the
// whole animation half of this file moved from frame-stepping to sequence-driven
// with it.  Sounds stay on the mod's own copies (byte-for-byte the CS samples,
// already precached) — only their timing was re-derived from the new model.
const string AK47_VIEWMODEL    = "models/v_ak47.mdl";
const string AK47_WORLDMODEL   = "models/w_ak47.mdl";
const string AK47_DEPLOY_SOUND = "";
const string AK47_DISPLAY_NAME = "AK47";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float ak47_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_AK47SeqIdle   = { return SH_SeqForName(AK47_VIEWMODEL, "idle1",  AK47_SEQ_IDLE); };
float() SH_AK47SeqReload = { return SH_SeqForName(AK47_VIEWMODEL, "reload", AK47_SEQ_RELOAD); };
float() SH_AK47SeqDraw   = { return SH_SeqForName(AK47_VIEWMODEL, "draw",   AK47_SEQ_DRAW); };
float() SH_AK47SeqShoot1 = { return SH_SeqForName(AK47_VIEWMODEL, "shoot1", AK47_SEQ_SHOOT1); };
float() SH_AK47SeqShoot2 = { return SH_SeqForName(AK47_VIEWMODEL, "shoot2", AK47_SEQ_SHOOT2); };
float() SH_AK47SeqShoot3 = { return SH_SeqForName(AK47_VIEWMODEL, "shoot3", AK47_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CSAUG/CFGLOCK pattern.
float(float action_id) SH_AK47PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_AK47SeqShoot1();
    if (r < 0.6667) return SH_AK47SeqShoot2();
    return SH_AK47SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_AK47DrawDuration   = { return SH_SeqDuration(AK47_VIEWMODEL, SH_AK47SeqDraw(),   1.000); };
float() SH_AK47ReloadDuration = { return SH_SeqDuration(AK47_VIEWMODEL, SH_AK47SeqReload(), 2.432); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_AK47TickState =
{
    float rel = SH_AK47ReloadDuration();
    return SH_StandardTickState(now, mag_ak47, ammo_ak47, MAX_MAG_AK47,
        SH_AK47DrawDuration(),
        SH_SeqDuration(AK47_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * AK47_RELOAD_F_APPLY);
};

float(float now) SH_AK47TryFire =
{
    return SH_StandardTryFire(now, mag_ak47, AK47_FIRE_DELAY, AK47_DRYFIRE_DELAY);
};

float(float now) SH_AK47TryReload =
{
    return SH_StandardTryReload(now, mag_ak47, ammo_ak47, MAX_MAG_AK47, SH_AK47ReloadDuration());
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
        self.weaponframe    = SH_AK47PickShootSeq(self.wep_action_id);
        self.wep_nextframe  = time + AK47_FRAME_INTERVAL;
        self.ak47_snd_stage = 0;

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
        self.weaponframe    = SH_AK47SeqReload();
        self.wep_nextframe  = time + AK47_FRAME_INTERVAL;
        self.ak47_snd_stage = 0;
    }
};

void() W_AK47Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += AK47_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_AK47DrawDuration() * AK47_DRAW_F_BOLT
            && self.ak47_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/boltpull.wav", 1, ATTN_NORM);
            self.ak47_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_AK47ReloadDuration();

        if (elapsed >= rel * AK47_RELOAD_F_CLIPOUT && self.ak47_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.ak47_snd_stage = 1;
        }
        if (elapsed >= rel * AK47_RELOAD_F_CLIPIN && self.ak47_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipin.wav", 1, ATTN_NORM);
            self.ak47_snd_stage = 2;
        }
    }

    result = SH_AK47TickState(time);
    if (result & 1)
    {
        self.weaponframe    = SH_AK47SeqIdle();
        self.wep_nextframe  = 0;
        self.ak47_snd_stage = 0;
    }
};

void() W_AK47Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ak47", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(AK47_VIEWMODEL, AK47_DISPLAY_NAME, SH_AK47SeqDraw(),
        AK47_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_AK47Fire;
    self.reload   = W_AK47Reload;
    self.wepframe = W_AK47Frame;
    self.shoot    = W_AK47Shoot;
    self.ak47_snd_stage = 0;
    W_SetCrosshairProfile(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_AK47Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_ak47  = self.mag_ak47;
    tgt.ammo_ak47 = self.ammo_ak47;

    self.mag_ak47  = 0;
    self.ammo_ak47 = 0;

    setmodel(tgt, "models/w_ak47.mdl");
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
    setmodel(self, "models/w_ak47.mdl");
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

float csqc_ak47_snd_stage;
float csqc_ak47_snd_action;

void() CSQC_PredictAK47Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_ak47_snd_action)
    {
        csqc_ak47_snd_action = predicted_player.wep_action_id;
        csqc_ak47_snd_stage  = 0;
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

    // Predicted draw / reload sounds, timed off the loaded model's own
    // sequence durations rather than a stepped frame number.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_ak47_snd_stage < 1
                && elapsed >= SH_AK47DrawDuration() * AK47_DRAW_F_BOLT)
            {
                localsound("sounds/weapons/wpn_csak47/boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_ak47_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_AK47ReloadDuration();

            if (csqc_ak47_snd_stage < 1 && elapsed >= rel * AK47_RELOAD_F_CLIPOUT)
            {
                localsound("sounds/weapons/wpn_csak47/clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_ak47_snd_stage = 1;
            }
            if (csqc_ak47_snd_stage < 2 && elapsed >= rel * AK47_RELOAD_F_CLIPIN)
            {
                localsound("sounds/weapons/wpn_csak47/clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_ak47_snd_stage = 2;
            }
        }
    }

    SH_AK47TickState(csqc_pred_time);
};

void() CSQC_PredictAK47Reload =
{
    if (SH_AK47TryReload(csqc_pred_time))
    {
        csqc_ak47_snd_stage  = 0;
        csqc_ak47_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_AK47DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_AK47SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_AK47SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_AK47PickShootSeq(predicted_player.wep_action_id);

    return SH_AK47SeqIdle();
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
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED.  The FALSE that used to sit here described the OLD bundled
    // viewmodel (models/weapons/wpn_csak47/v_ak47.mdl), which was a re-baked
    // IDPO copy.  This weapon now draws the stock cstrike models/v_ak47.mdl,
    // whose rhand/lhand meshes are the same ones v_aug / v_glock18 / v_usp use,
    // and every one of those is flipped.  Reported left-handed in game.
    // cl_lefthand XORs against this, so reverting is one word.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
