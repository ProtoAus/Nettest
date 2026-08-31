// ============================================================
//  shared/weapons/sh_wpn_cssg552.qc  -  Counter-Strike SIG SG-552
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : low-power 1.2x on +attack2, via the shared ADS profile
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_sg552.mdl, models/w_sg552.mdl,
// models/p_sg552.mdl and every sound below resolve through the mounted cstrike
// gamedir (fs_addons.txt:16), exactly the way sh_wpn_csaug.qc takes
// models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl from
// valve.  The mod's CrossFire SG-552 (sh_wpn_cfsg552.qc) is a DIFFERENT weapon
// with its own shipped model set and keeps the bare "sg552" manifest key; this
// one answers to "cssg552".
//
// This is the T-side mirror of sh_wpn_csaug.qc and is deliberately written to
// read as its sibling: same magazine, same cyclic rate, same scope class, same
// state machine.  Only the three numbers CS 1.6 actually separates them by
// differ — see the balance block.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_sg552.mdl itself, not guessed:
//
//   [0] idle     30fps   9 frames  0.267s
//   [1] reload   37fps 119 frames  3.189s
//         f16  5004 "weapons/sg552_clipout.wav"   frac 0.1356
//         f61  5004 "weapons/sg552_clipin.wav"    frac 0.5169
//         f90  5004 "weapons/sg552_boltpull.wav"  frac 0.7627
//   [2] draw     37fps  38 frames  1.000s
//         f12  5004 "weapons/sg552_boltpull.wav"  frac 0.3243
//   [3] shoot1   35fps  31 frames  0.857s   f0 5001 (muzzleflash)
//   [4] shoot2   35fps  31 frames  0.857s   f0 5001
//   [5] shoot3   35fps  31 frames  0.857s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note the event ORDER differs from the AUG's: this reload drops the mag
// FIRST and racks the bolt LAST, where the AUG racks first.  The stage numbers
// below follow this model, not the AUG's.
//
// Note also that /c/tmp/seqlist.py CANNOT show you the options field: it walks
// the event array with a stride of 72 where mstudioevent_t is 76 bytes (int
// frame, int event, int type, char options[64]), so every event past the first
// is read from the middle of its predecessor.  Use the corrected dumper if
// these ever need re-deriving.

// --- Ammo fields ---
.float mag_sg552;
.float ammo_sg552;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt:16-17)
// and both ship models/v_sg552.mdl with the same labels at different fps and
// frame counts.  Whichever mount wins, resolving by name and scaling every mark
// by that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSSG552_SEQ_IDLE   = 0;
const float CSSG552_SEQ_RELOAD = 1;
const float CSSG552_SEQ_DRAW   = 2;
const float CSSG552_SEQ_SHOOT1 = 3;
const float CSSG552_SEQ_SHOOT2 = 4;
const float CSSG552_SEQ_SHOOT3 = 5;

const float CSSG552_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSSG552_FIRE_DELAY       = 0.09;        // CS 1.6 SG-552 is ~666 rpm
const float CSSG552_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSSG552_DRAW_F_BOLT     = 0.3243;   // frame  12 / 37
const float CSSG552_RELOAD_F_CLIPOUT = 0.1356;  // frame  16 / 118
const float CSSG552_RELOAD_F_CLIPIN  = 0.5169;  // frame  61 / 118
const float CSSG552_RELOAD_F_BOLT    = 0.7627;  // frame  90 / 118
const float CSSG552_RELOAD_F_APPLY   = 0.7000;  // fresh mag seated, bolt not yet racked

const float MAX_MAG_CSSG552          = 30;
const float MAX_AMMO_CSSG552         = 90;

// --- Balance ---
//
// Anchored on sh_wpn_cfsg552.qc, which is the same real rifle already placed on
// this mod's ladder at 33/22 with a 2400 falloff — those three carry over
// unchanged, so the CF and CS SG-552s hit identically and only their animation
// and handling differ.
//
// The pairing that matters is against sh_wpn_csaug.qc, the CT-side mirror of
// this gun.  CS 1.6 separates the two by exactly two knobs and this file keeps
// both: the SG-552 hits harder (33/22 against the AUG's 32/21) and is less
// accurate standing still (BASE_SPREAD 0.012 against the AUG's 0.010).
// Everything else — 30/90 ammo, 0.09s cyclic, 0.07 move spread, 320 full-spread
// speed, SCOPE_CLASS_RIFLE_LOWPOWER — is deliberately identical, because that is
// what makes the two read as one weapon per side rather than two unrelated guns.
// 33 stays below the AK47's 34 and above the M4A1's 24, so the rifle tier still
// orders AK47 > SG552 > AUG > M4A1.
const float CSSG552_BASE_SPREAD          = 0.012;
const float CSSG552_MOVE_SPREAD          = 0.070;
const float CSSG552_FULL_SPREAD_SPEED    = 320;
const float CSSG552_CLOSE_DAMAGE         = 33;
const float CSSG552_MIN_DAMAGE           = 22;
const float CSSG552_DAMAGE_FALLOFF_RANGE = 2400;
const float CSSG552_KICK_PITCH    = 1.35;  // sv_gunkick — a touch above the AUG's 1.3.
const float CSSG552_KICK_VARIANCE = 1.25;
const float CSSG552_KICK_STRENGTH = 1.0;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from the
// AUG's numbers, which this mesh is close to but not identical to; treat these
// as a starting point rather than tuned values.
const float CSSG552_MUZZLE_FORWARD = 43;
const float CSSG552_MUZZLE_RIGHT   = 9.0;
const float CSSG552_MUZZLE_DOWN    = 5.5;

const string CSSG552_VIEWMODEL    = "models/v_sg552.mdl";
const string CSSG552_WORLDMODEL   = "models/w_sg552.mdl";
const string CSSG552_DEPLOY_SOUND = "";
const string CSSG552_DISPLAY_NAME = "SG552";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float sg552_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSSg552SeqIdle   = { return SH_SeqForName(CSSG552_VIEWMODEL, "idle",   CSSG552_SEQ_IDLE); };
float() SH_CSSg552SeqReload = { return SH_SeqForName(CSSG552_VIEWMODEL, "reload", CSSG552_SEQ_RELOAD); };
float() SH_CSSg552SeqDraw   = { return SH_SeqForName(CSSG552_VIEWMODEL, "draw",   CSSG552_SEQ_DRAW); };
float() SH_CSSg552SeqShoot1 = { return SH_SeqForName(CSSG552_VIEWMODEL, "shoot1", CSSG552_SEQ_SHOOT1); };
float() SH_CSSg552SeqShoot2 = { return SH_SeqForName(CSSG552_VIEWMODEL, "shoot2", CSSG552_SEQ_SHOOT2); };
float() SH_CSSg552SeqShoot3 = { return SH_SeqForName(CSSG552_VIEWMODEL, "shoot3", CSSG552_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CFGLOCK pattern.
float(float action_id) SH_CSSg552PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSSg552SeqShoot1();
    if (r < 0.6667) return SH_CSSg552SeqShoot2();
    return SH_CSSg552SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSSg552DrawDuration   = { return SH_SeqDuration(CSSG552_VIEWMODEL, SH_CSSg552SeqDraw(),   1.000); };
float() SH_CSSg552ReloadDuration = { return SH_SeqDuration(CSSG552_VIEWMODEL, SH_CSSg552SeqReload(), 3.189); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSSg552TickState =
{
    float rel = SH_CSSg552ReloadDuration();
    return SH_StandardTickState(now, mag_sg552, ammo_sg552, MAX_MAG_CSSG552,
        SH_CSSg552DrawDuration(),
        SH_SeqDuration(CSSG552_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSSG552_RELOAD_F_APPLY);
};

float(float now) SH_CSSg552TryFire =
{
    // Full-auto rifle: FIRE_DELAY paces the cyclic rate and holding +attack
    // keeps firing.  Standard (NOT SemiAuto) try-fire gate.
    return SH_StandardTryFire(now, mag_sg552, CSSG552_FIRE_DELAY, CSSG552_DRYFIRE_DELAY);
};

float(float now) SH_CSSg552TryReload =
{
    return SH_StandardTryReload(now, mag_sg552, ammo_sg552, MAX_MAG_CSSG552,
        SH_CSSg552ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSSg552PickupCopy =
{
    player.mag_sg552  = self.mag_sg552;
    player.ammo_sg552 = self.ammo_sg552;
};

void() W_CSSg552Shoot =
{
    W_PenetratingHitscanShoot(CSSG552_BASE_SPREAD, CSSG552_MOVE_SPREAD, CSSG552_FULL_SPREAD_SPEED,
        CSSG552_CLOSE_DAMAGE, CSSG552_MIN_DAMAGE, CSSG552_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CSSG552_KICK_PITCH, CSSG552_KICK_VARIANCE, CSSG552_KICK_STRENGTH);
};

void() W_CSSg552Fire =
{
    float r = SH_CSSg552TryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSSg552PickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSSG552_FRAME_INTERVAL;
        self.sg552_snd_stage = 0;

        W_CSSg552Shoot();

        sound(self, CHAN_WEAPON, "weapons/sg552-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSSg552Reload =
{
    if (SH_CSSg552TryReload(time))
    {
        self.weaponframe     = SH_CSSg552SeqReload();
        self.wep_nextframe   = time + CSSG552_FRAME_INTERVAL;
        self.sg552_snd_stage = 0;
    }
};

void() W_CSSg552Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSSG552_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSSg552DrawDuration() * CSSG552_DRAW_F_BOLT
            && self.sg552_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/sg552_boltpull.wav", 1, ATTN_NORM);
            self.sg552_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSSg552ReloadDuration();

        if (elapsed >= rel * CSSG552_RELOAD_F_CLIPOUT && self.sg552_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/sg552_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.sg552_snd_stage = 1;
        }
        if (elapsed >= rel * CSSG552_RELOAD_F_CLIPIN && self.sg552_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/sg552_clipin.wav", 1, ATTN_NORM);
            self.sg552_snd_stage = 2;
        }
        if (elapsed >= rel * CSSG552_RELOAD_F_BOLT && self.sg552_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/sg552_boltpull.wav", 1, ATTN_NORM);
            self.sg552_snd_stage = 3;
        }
    }

    result = SH_CSSg552TickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSSg552SeqIdle();
        self.wep_nextframe   = 0;
        self.sg552_snd_stage = 0;
    }
};

void() W_CSSg552Equip =
{
    // The SG-552's scope is the shared low-power rifle sight, driven off
    // weapon_scope_class by sh_pmove.qc / cl_codscope.qc — there is no altfire
    // hook and no per-weapon zoomstage, which is how the AUG and the CF twin do
    // it too.
    W_SetADSProfile(FALSE, "cl_ads_cssg552", SCOPE_CLASS_RIFLE_LOWPOWER);
    W_StandardEquipSetup(CSSG552_VIEWMODEL, CSSG552_DISPLAY_NAME, SH_CSSg552SeqDraw(),
        CSSG552_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSSg552Fire;
    self.reload   = W_CSSg552Reload;
    self.wepframe = W_CSSg552Frame;
    self.shoot    = W_CSSg552Shoot;
    self.sg552_snd_stage = 0;
    W_SetCrosshairProfile(CSSG552_BASE_SPREAD, CSSG552_MOVE_SPREAD, CSSG552_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CSSg552Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_sg552  = self.mag_sg552;
    tgt.ammo_sg552 = self.ammo_sg552;

    self.mag_sg552  = 0;
    self.ammo_sg552 = 0;

    setmodel(tgt, CSSG552_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sg552";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSSG552;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSSg552Equip;
    tgt.weap_drop_func = W_CSSg552Drop;
    tgt.pickupcopy     = W_CSSg552PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_sg552 had zero references in
// this tree before this weapon existed — the CrossFire SG-552 spawns as
// weapon_cfsg552 — so nothing is displaced and a GoldSrc CS map placing one now
// gets this rifle rather than "no spawn function".
void() weapon_sg552 =
{
    setmodel(self, CSSG552_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sg552";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSSG552;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSSg552Equip;
    self.weap_drop_func = W_CSSg552Drop;
    self.pickupcopy     = W_CSSg552PickupCopy;
    self.touch          = weapon_touch;
    self.mag_sg552      = MAX_MAG_CSSG552;
    self.ammo_sg552     = MAX_AMMO_CSSG552;
    W_RegisterMapWeapon(weapon_sg552);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_sg552_snd_stage;
float csqc_sg552_snd_action;

void() CSQC_PredictCSSg552Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_sg552_snd_action)
    {
        csqc_sg552_snd_action = predicted_player.wep_action_id;
        csqc_sg552_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSSg552TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/sg552-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSSG552_BASE_SPREAD, CSSG552_MOVE_SPREAD, CSSG552_FULL_SPREAD_SPEED,
                    CSSG552_CLOSE_DAMAGE, CSSG552_MIN_DAMAGE, CSSG552_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSSG552_KICK_PITCH, CSSG552_KICK_VARIANCE, CSSG552_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSSG552_MUZZLE_FORWARD, CSSG552_MUZZLE_RIGHT,
                    CSSG552_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSSG552_MUZZLE_FORWARD, CSSG552_MUZZLE_RIGHT,
                    CSSG552_MUZZLE_DOWN, self.wep_action_id, 1);
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

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_sg552_snd_stage < 1
                && elapsed >= SH_CSSg552DrawDuration() * CSSG552_DRAW_F_BOLT)
            {
                localsound("weapons/sg552_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sg552_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSSg552ReloadDuration();

            if (csqc_sg552_snd_stage < 1 && elapsed >= rel * CSSG552_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/sg552_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_sg552_snd_stage = 1;
            }
            if (csqc_sg552_snd_stage < 2 && elapsed >= rel * CSSG552_RELOAD_F_CLIPIN)
            {
                localsound("weapons/sg552_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sg552_snd_stage = 2;
            }
            if (csqc_sg552_snd_stage < 3 && elapsed >= rel * CSSG552_RELOAD_F_BOLT)
            {
                localsound("weapons/sg552_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sg552_snd_stage = 3;
            }
        }
    }

    SH_CSSg552TickState(csqc_pred_time);
};

void() CSQC_PredictCSSg552Reload =
{
    if (SH_CSSg552TryReload(csqc_pred_time))
    {
        csqc_sg552_snd_stage  = 0;
        csqc_sg552_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSSg552DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSSg552SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSSg552SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSSg552PickShootSeq(predicted_player.wep_action_id);

    return SH_CSSg552SeqIdle();
};

void() CSQC_CSSg552DropClear =
{
    self.mag_sg552  = 0;
    self.ammo_sg552 = 0;
};

void() CSQC_CSSg552Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_cssg552", SCOPE_CLASS_RIFLE_LOWPOWER);
    self.weapon_name         = CSSG552_DISPLAY_NAME;
    self.weapon_viewmodel    = CSSG552_VIEWMODEL;
    self.weapon_worldmodel   = CSSG552_WORLDMODEL;
    self.weapon_deploy_sound = CSSG552_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSSg552Command;
    self.csqc_predict_reload = CSQC_PredictCSSg552Reload;
    self.csqc_display_frame  = CSQC_CSSg552DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSSg552DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game.  sh_wpn_csglock.qc:664 already
    // listed this weapon as one of the ten drawing the same stock cstrike arm
    // and needing the same flip once it was reported.  The rhand/lhand meshes
    // here are byte-identical to the flipped handguns'.  cl_lefthand still XORs.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
