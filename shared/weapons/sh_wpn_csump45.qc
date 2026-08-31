// ============================================================
//  shared/weapons/sh_wpn_csump45.qc  -  Counter-Strike HK UMP45
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 25-round magazine, 100 reserve, full-auto .45 ACP SMG
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  ADS   : plain iron sights, no scope class
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_ump45.mdl, models/w_ump45.mdl,
// models/p_ump45.mdl and every "weapons/*.wav" below resolve through the
// mounted cstrike gamedir (fs_addons.txt:16), exactly the way sh_wpn_csaug.qc
// takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl
// from valve.  The mod's CrossFire UMP45 (sh_wpn_cfump45.qc) is a DIFFERENT
// weapon with its own shipped model set under models/weapons/wpn_cfump45/ and
// keeps the bare "ump45" manifest key; this one answers to "csump45".
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_ump45.mdl itself, not guessed:
//
//   [0] idle1    12fps   3 frames  0.167s
//   [1] reload   33fps 116 frames  3.485s
//         f23  5004 "weapons/ump45_clipout.wav"   frac 0.2000
//         f59  5004 "weapons/ump45_clipin.wav"    frac 0.5130
//         f86  5004 "weapons/ump45_boltslap.wav"  frac 0.7478
//   [2] draw     30fps  31 frames  1.000s   <- NO SOUND EVENT AT ALL
//   [3] shoot1   32fps  15 frames  0.438s   f0 5001 (muzzleflash)
//   [4] shoot2   32fps  15 frames  0.438s   f0 5001
//   [5] shoot3   32fps  15 frames  0.438s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  The draw sequence carries no event of any code: the real CS 1.6 UMP45
// is silent on deploy, so this file has NO draw sound branch.  Borrowing
// another gun's deploy sample would be inventing content the model does not
// ask for, and it would desync the moment the czero copy (different fps) won
// the mount.
//
// czero's models/v_ump45.mdl carries a SEVENTH sequence, shoot_empty (index 6),
// which cstrike's copy does not have — see the SH_CSUmp45SeqShootE note below.

// --- Ammo fields ---
.float mag_ump45;
.float ammo_ump45;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted
// (fs_addons.txt:16-17) and both ship models/v_ump45.mdl with the same labels
// at different fps, different frame counts and — for shoot_empty — a different
// number of sequences entirely.  Whichever mount wins, resolving by name and
// scaling every event mark by that model's own duration keeps the sounds on
// the animation.
const float CSUMP45_SEQ_IDLE   = 0;
const float CSUMP45_SEQ_RELOAD = 1;
const float CSUMP45_SEQ_DRAW   = 2;
const float CSUMP45_SEQ_SHOOT1 = 3;
const float CSUMP45_SEQ_SHOOT2 = 4;
const float CSUMP45_SEQ_SHOOT3 = 5;
// shoot_empty is index 6 on czero and DOES NOT EXIST on cstrike, so the
// fallback here is deliberately shoot1's index rather than 6.  Ask for the name
// and you get the real last-round take wherever it exists; on the cstrike copy
// SH_SeqForName finds no such name and hands back an ordinary shoot instead.
// Passing 6 would be worse than useless on cstrike: SH_SeqForName range-checks
// the fallback too and would return 0 (idle) rather than let frameduration
// clamp an out-of-range index — a firing animation that plays the idle.
const float CSUMP45_SEQ_SHOOTE = 3;

const float CSUMP45_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSUMP45_FIRE_DELAY       = 0.11;        // CS 1.6 UMP45 is ~545 rpm
const float CSUMP45_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
// frameduration divides by (numframes-1), which is the form these were taken in.
const float CSUMP45_RELOAD_F_CLIPOUT = 0.2000;   // frame 23 / 115
const float CSUMP45_RELOAD_F_CLIPIN  = 0.5130;   // frame 59 / 115
const float CSUMP45_RELOAD_F_SLAP    = 0.7478;   // frame 86 / 115
const float CSUMP45_RELOAD_F_APPLY   = 0.7000;   // fresh mag seated, before the bolt slap

const float MAX_MAG_CSUMP45          = 25;
const float MAX_AMMO_CSUMP45         = 100;

// --- Balance ---
//
// Placed on the CS ladder this mod already runs, which the CS MP5
// (sh_wpn_csmp5.qc, 12/6 at 2048) anchors — NOT on the older CrossFire ladder
// the CF twin sits on.  sh_wpn_cfump45.qc reads 24/12 at 1900, roughly double
// close damage, because the whole CF set was tuned against itself; matching it
// here would make the CS SMG bracket incoherent with the CS rifles above it.
//
// 14/7 makes this the hardest-hitting SMG per bullet in the set — the highest
// of the four new ones and two points above the MP5 — which is exactly how CS
// 1.6 orders it, and it pays with the second-slowest rate: 0.11s between shots
// against the MP5's 0.10.  Falloff is 1800, the shortest of any automatic here
// (MP5 2048, AUG 2304): a pistol-calibre .45 round sheds energy fast, so the
// UMP45 wins the room and loses the corridor.  Spread inherits the CF twin's
// shape, nudged from 0.010/0.07 to 0.011/0.070 so it sits a hair looser than
// the rifles at a standstill.
const float CSUMP45_BASE_SPREAD          = 0.011;
const float CSUMP45_MOVE_SPREAD          = 0.070;
const float CSUMP45_FULL_SPREAD_SPEED    = 320;
const float CSUMP45_CLOSE_DAMAGE         = 14;
const float CSUMP45_MIN_DAMAGE           = 7;
const float CSUMP45_DAMAGE_FALLOFF_RANGE = 1800;
// sv_gunkick — the CF twin's 0.8/0.4 pair carried over unchanged; strength goes
// to 1.15 (MP5 1.2, AUG 1.0) for the heavier per-shot .45 impulse at a rate
// slow enough that each one reads individually.
const float CSUMP45_KICK_PITCH    = 0.80;
const float CSUMP45_KICK_VARIANCE = 0.40;
const float CSUMP45_KICK_STRENGTH = 1.15;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the MP5's numbers and pulled in for the UMP45's shorter barrel; the CS mesh
// is its own model, so treat these as a starting point rather than tuned values.
const float CSUMP45_MUZZLE_FORWARD = 36;
const float CSUMP45_MUZZLE_RIGHT   = 9.8;
const float CSUMP45_MUZZLE_DOWN    = 6.2;

const string CSUMP45_VIEWMODEL    = "models/v_ump45.mdl";
const string CSUMP45_WORLDMODEL   = "models/w_ump45.mdl";
const string CSUMP45_DEPLOY_SOUND = "";
const string CSUMP45_DISPLAY_NAME = "UMP45";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload events latch off elapsed time instead of a frame number.
.float ump45_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSUmp45SeqIdle   = { return SH_SeqForName(CSUMP45_VIEWMODEL, "idle1",  CSUMP45_SEQ_IDLE); };
float() SH_CSUmp45SeqReload = { return SH_SeqForName(CSUMP45_VIEWMODEL, "reload", CSUMP45_SEQ_RELOAD); };
float() SH_CSUmp45SeqDraw   = { return SH_SeqForName(CSUMP45_VIEWMODEL, "draw",   CSUMP45_SEQ_DRAW); };
float() SH_CSUmp45SeqShoot1 = { return SH_SeqForName(CSUMP45_VIEWMODEL, "shoot1", CSUMP45_SEQ_SHOOT1); };
float() SH_CSUmp45SeqShoot2 = { return SH_SeqForName(CSUMP45_VIEWMODEL, "shoot2", CSUMP45_SEQ_SHOOT2); };
float() SH_CSUmp45SeqShoot3 = { return SH_SeqForName(CSUMP45_VIEWMODEL, "shoot3", CSUMP45_SEQ_SHOOT3); };

// The clearest demonstration in this set of why everything here resolves by
// name: ask for "shoot_empty" unconditionally.  On the czero copy of
// v_ump45.mdl that name exists (index 6) and the last round out gets its real
// bolt-locked-back take; on the cstrike copy the name is absent and the
// range-checked fallback quietly returns an ordinary shoot.  Neither mount
// needs a branch here, and an index-keyed lookup could not have done this at all.
float() SH_CSUmp45SeqShootE = { return SH_SeqForName(CSUMP45_VIEWMODEL, "shoot_empty", CSUMP45_SEQ_SHOOTE); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot.  `mag_left` is the magazine count AFTER
// this shot, which is what selects the empty take.
//
// Random-picking across the shoot takes is only legitimate because THESE takes
// are interchangeable: shoot1/2/3 on v_ump45.mdl each carry two ev5001 events
// on the SAME frame (t=0.000 twice), which is one flash authored twice, not a
// cadence — so all three are single-round animations.  It is NOT legitimate in
// general — the CS Glock's
// shoot/shoot2 carry three flashes apiece and are its BURST takes, and picking
// them for +attack is what "the animation looks like burst but only one bullet
// comes out" was (sh_wpn_csglock.qc:38).  Check the event table before copying
// this shape onto a weapon with an alternate fire mode.
float(float action_id, float mag_left) SH_CSUmp45PickShootSeq =
{
    if (mag_left <= 0)
        return SH_CSUmp45SeqShootE();
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSUmp45SeqShoot1();
    if (r < 0.6667) return SH_CSUmp45SeqShoot2();
    return SH_CSUmp45SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSUmp45DrawDuration   = { return SH_SeqDuration(CSUMP45_VIEWMODEL, SH_CSUmp45SeqDraw(),   1.000); };
float() SH_CSUmp45ReloadDuration = { return SH_SeqDuration(CSUMP45_VIEWMODEL, SH_CSUmp45SeqReload(), 3.485); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSUmp45TickState =
{
    float rel = SH_CSUmp45ReloadDuration();
    return SH_StandardTickState(now, mag_ump45, ammo_ump45, MAX_MAG_CSUMP45,
        SH_CSUmp45DrawDuration(),
        SH_SeqDuration(CSUMP45_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSUMP45_RELOAD_F_APPLY);
};

// FULL-AUTO: SH_StandardTryFire, not the SemiAuto form — holding +attack keeps
// the gun running at CSUMP45_FIRE_DELAY.
float(float now) SH_CSUmp45TryFire =
{
    return SH_StandardTryFire(now, mag_ump45, CSUMP45_FIRE_DELAY, CSUMP45_DRYFIRE_DELAY);
};

float(float now) SH_CSUmp45TryReload =
{
    return SH_StandardTryReload(now, mag_ump45, ammo_ump45, MAX_MAG_CSUMP45,
        SH_CSUmp45ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSUmp45PickupCopy =
{
    player.mag_ump45  = self.mag_ump45;
    player.ammo_ump45 = self.ammo_ump45;
};

void() W_CSUmp45Shoot =
{
    W_PenetratingHitscanShoot(CSUMP45_BASE_SPREAD, CSUMP45_MOVE_SPREAD, CSUMP45_FULL_SPREAD_SPEED,
        CSUMP45_CLOSE_DAMAGE, CSUMP45_MIN_DAMAGE, CSUMP45_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CSUMP45_KICK_PITCH, CSUMP45_KICK_VARIANCE, CSUMP45_KICK_STRENGTH);
};

void() W_CSUmp45Fire =
{
    float r = SH_CSUmp45TryFire(time);

    if (r == 1)
    {
        // mag_ump45 is already decremented by SH_StandardTryFire, so this is
        // the post-shot count — which is what selects shoot_empty.
        self.weaponframe      = SH_CSUmp45PickShootSeq(self.wep_action_id, self.mag_ump45);
        self.wep_nextframe    = time + CSUMP45_FRAME_INTERVAL;
        self.ump45_snd_stage  = 0;

        W_CSUmp45Shoot();

        sound(self, CHAN_WEAPON, "weapons/ump45-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RED, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSUmp45Reload =
{
    if (SH_CSUmp45TryReload(time))
    {
        self.weaponframe     = SH_CSUmp45SeqReload();
        self.wep_nextframe   = time + CSUMP45_FRAME_INTERVAL;
        self.ump45_snd_stage = 0;
    }
};

void() W_CSUmp45Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSUMP45_FRAME_INTERVAL;

    // No WS_DRAW branch: v_ump45.mdl's draw sequence carries no studio event,
    // so the deploy is silent.  See the header note.
    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSUmp45ReloadDuration();

        if (elapsed >= rel * CSUMP45_RELOAD_F_CLIPOUT && self.ump45_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/ump45_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.ump45_snd_stage = 1;
        }
        if (elapsed >= rel * CSUMP45_RELOAD_F_CLIPIN && self.ump45_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/ump45_clipin.wav", 1, ATTN_NORM);
            self.ump45_snd_stage = 2;
        }
        if (elapsed >= rel * CSUMP45_RELOAD_F_SLAP && self.ump45_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/ump45_boltslap.wav", 1, ATTN_NORM);
            self.ump45_snd_stage = 3;
        }
    }

    result = SH_CSUmp45TickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSUmp45SeqIdle();
        self.wep_nextframe   = 0;
        self.ump45_snd_stage = 0;
    }
};

void() W_CSUmp45Equip =
{
    // Iron sights only — no scope class, so cl_codscope never engages and the
    // ADS pose comes straight off the cl_ads_csump45_* cvar family.
    W_SetADSProfile(TRUE, "cl_ads_csump45", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSUMP45_VIEWMODEL, CSUMP45_DISPLAY_NAME, SH_CSUmp45SeqDraw(),
        CSUMP45_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSUmp45Fire;
    self.reload   = W_CSUmp45Reload;
    self.wepframe = W_CSUmp45Frame;
    self.shoot    = W_CSUmp45Shoot;
    self.ump45_snd_stage = 0;
    W_SetCrosshairProfile(CSUMP45_BASE_SPREAD, CSUMP45_MOVE_SPREAD, CSUMP45_FULL_SPREAD_SPEED, 1.4, TRUE);
};

void() W_CSUmp45Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_ump45  = self.mag_ump45;
    tgt.ammo_ump45 = self.ammo_ump45;

    self.mag_ump45  = 0;
    self.ammo_ump45 = 0;

    setmodel(tgt, CSUMP45_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_ump45";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSUMP45;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSUmp45Equip;
    tgt.weap_drop_func = W_CSUmp45Drop;
    tgt.pickupcopy     = W_CSUmp45PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_ump45 had zero references in
// this tree before this weapon existed, so nothing is displaced and a GoldSrc CS
// map placing one now gets the UMP45 rather than "no spawn function".
void() weapon_ump45 =
{
    setmodel(self, CSUMP45_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_ump45";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSUMP45;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSUmp45Equip;
    self.weap_drop_func = W_CSUmp45Drop;
    self.pickupcopy     = W_CSUmp45PickupCopy;
    self.touch          = weapon_touch;
    self.mag_ump45      = MAX_MAG_CSUMP45;
    self.ammo_ump45     = MAX_AMMO_CSUMP45;
    W_RegisterMapWeapon(weapon_ump45);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_ump45_snd_stage;
float csqc_ump45_snd_action;

void() CSQC_PredictCSUmp45Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_ump45_snd_action)
    {
        csqc_ump45_snd_action = predicted_player.wep_action_id;
        csqc_ump45_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSUmp45TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/ump45-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSUMP45_BASE_SPREAD, CSUMP45_MOVE_SPREAD, CSUMP45_FULL_SPREAD_SPEED,
                    CSUMP45_CLOSE_DAMAGE, CSUMP45_MIN_DAMAGE, CSUMP45_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CSUMP45_KICK_PITCH, CSUMP45_KICK_VARIANCE, CSUMP45_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/redcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSUMP45_MUZZLE_FORWARD, CSUMP45_MUZZLE_RIGHT,
                    CSUMP45_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSUMP45_MUZZLE_FORWARD, CSUMP45_MUZZLE_RIGHT,
                    CSUMP45_MUZZLE_DOWN, self.wep_action_id, 1);
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

        // No WS_DRAW branch here either — the server half has none, because the
        // model has no draw event.  Adding one on this side only would be a
        // sound the server never plays.
        if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSUmp45ReloadDuration();

            if (csqc_ump45_snd_stage < 1 && elapsed >= rel * CSUMP45_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/ump45_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_ump45_snd_stage = 1;
            }
            if (csqc_ump45_snd_stage < 2 && elapsed >= rel * CSUMP45_RELOAD_F_CLIPIN)
            {
                localsound("weapons/ump45_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_ump45_snd_stage = 2;
            }
            if (csqc_ump45_snd_stage < 3 && elapsed >= rel * CSUMP45_RELOAD_F_SLAP)
            {
                localsound("weapons/ump45_boltslap.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_ump45_snd_stage = 3;
            }
        }
    }

    SH_CSUmp45TickState(csqc_pred_time);
};

void() CSQC_PredictCSUmp45Reload =
{
    if (SH_CSUmp45TryReload(csqc_pred_time))
    {
        csqc_ump45_snd_stage  = 0;
        csqc_ump45_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  The fire
// case reads predicted_player.mag_ump45 — the post-shot count, same input the
// server's W_CSUmp45Fire uses — so both sides land on the same take, empty or not.
float(float elapsed) CSQC_CSUmp45DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSUmp45SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSUmp45SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSUmp45PickShootSeq(predicted_player.wep_action_id,
                                      predicted_player.mag_ump45);

    return SH_CSUmp45SeqIdle();
};

void() CSQC_CSUmp45DropClear =
{
    self.mag_ump45  = 0;
    self.ammo_ump45 = 0;
};

void() CSQC_CSUmp45Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csump45", SCOPE_CLASS_NONE);
    self.weapon_name         = CSUMP45_DISPLAY_NAME;
    self.weapon_viewmodel    = CSUMP45_VIEWMODEL;
    self.weapon_worldmodel   = CSUMP45_WORLDMODEL;
    self.weapon_deploy_sound = CSUMP45_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSUmp45Command;
    self.csqc_predict_reload = CSQC_PredictCSUmp45Reload;
    self.csqc_display_frame  = CSQC_CSUmp45DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSUmp45DropClear;
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
