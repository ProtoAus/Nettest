// ============================================================
//  shared/weapons/sh_wpn_csfiveseven.qc  -  Counter-Strike FN Five-seven
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 20-round magazine, 100 reserve, semi-auto 5.7x28mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none — ADS only, via the shared iron-sight profile
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_fiveseven.mdl,
// models/w_fiveseven.mdl, models/p_fiveseven.mdl and every "weapons/*.wav"
// below resolve through the mounted cstrike gamedir (fs_addons.txt), exactly
// the way sh_wpn_csaug.qc takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes
// models/v_crowbar.mdl from valve.  The only file this weapon uses from the
// mod's own tree is the dry click, sounds/weapons/dryfire1.wav.
//
// Note that sh_wpn_cfm9.qc ALSO drives cstrike's v_fiveseven.mdl — the CF M9
// borrowed this mesh because its own was missing.  That is a different weapon
// with a different manifest row; it keeps the bare "fiveseven" manifest key and
// the "weapon_cfm9" classname, and this one answers to "csfiveseven" /
// "weapon_fiveseven".  Sharing a viewmodel path is harmless: every sequence
// here is resolved by name off that path at runtime.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_fiveseven.mdl itself, not guessed:
//
//   [0] idle1        16fps   3 frames  0.125s
//   [1] shoot1       36fps  24 frames  0.639s   f0 5001 (muzzleflash)
//   [2] shoot2       36fps  24 frames  0.639s   f0 5001
//   [3] shoot_empty  36fps  24 frames  0.639s   f0 5001
//   [4] reload       30fps  97 frames  3.200s
//         f15 "weapons/fiveseven_clipout.wav"       frac 0.1562
//         f41 "weapons/fiveseven_clipin.wav"        frac 0.4271
//         f75 "weapons/fiveseven_sliderelease.wav"  frac 0.7812
//   [5] draw         30fps  31 frames  1.000s
//         f13 "weapons/fiveseven_slidepull.wav"     frac 0.4333
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.
//
// Unlike the Glock, which carries three shoot takes, this model has only TWO
// (shoot1/shoot2) plus the dedicated shoot_empty that plays with the slide
// locked back.  SH_CSFiveSevenPickShootSeq below splits the hash in half, not
// in thirds, for that reason.

// --- Ammo fields ---
.float mag_fiveseven;
.float ammo_fiveseven;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt)
// and both ship models/v_fiveseven.mdl with the same labels at different fps
// and frame counts.  Whichever mount wins, resolving by name and scaling every
// mark by that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSFIVESEVEN_SEQ_IDLE   = 0;
const float CSFIVESEVEN_SEQ_SHOOT1 = 1;
const float CSFIVESEVEN_SEQ_SHOOT2 = 2;
const float CSFIVESEVEN_SEQ_SHOOTE = 3;   // shoot_empty — last round out, slide locks back
const float CSFIVESEVEN_SEQ_RELOAD = 4;
const float CSFIVESEVEN_SEQ_DRAW   = 5;

const float CSFIVESEVEN_FRAME_INTERVAL = 0.0333334;   // state-machine tick rate
const float CSFIVESEVEN_FIRE_DELAY     = 0.15;        // semi-auto — trigger-limited, matches the Glock
const float CSFIVESEVEN_DRYFIRE_DELAY  = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSFIVESEVEN_DRAW_F_SLIDEPULL   = 0.4333;   // frame 13 / 30
const float CSFIVESEVEN_RELOAD_F_CLIPOUT   = 0.1562;   // frame 15 / 96
const float CSFIVESEVEN_RELOAD_F_CLIPIN    = 0.4271;   // frame 41 / 96
const float CSFIVESEVEN_RELOAD_F_SLIDE     = 0.7812;   // frame 75 / 96
const float CSFIVESEVEN_RELOAD_F_APPLY     = 0.5500;   // just after the fresh mag seats (clipin is 0.4271)

const float MAX_MAG_CSFIVESEVEN        = 20;   // CS 1.6: 20-round mag
const float MAX_AMMO_CSFIVESEVEN       = 100;  // CS 1.6: 100 reserve

// --- Balance ---
//
// Anchored on sh_wpn_csglock.qc, the pistol immediately below this one on the
// ladder (18 close / 10 min / 2048 falloff).  In CS 1.6 the Five-seven is the
// WEAKEST pistol per shot in the class — but it also has the best armour
// penetration and by far the flattest recoil, and none of that survives a
// straight damage copy into a mod with no armour-class model.  So the
// placement moves the character into the numbers that DO exist here:
//
//   * CLOSE_DAMAGE 20 sits only TWO above the Glock's 18 — still bottom of the
//     pistol bracket, well under the Deagle/.357 end of it.  MIN_DAMAGE 12
//     keeps the same +2 offset over the Glock's 10.
//   * DAMAGE_FALLOFF_RANGE 2400 is the LONGEST of any pistol in this tree
//     (the Glock's is 2048).  That is where the 5.7x28mm's penetration goes:
//     it holds its damage further out instead of hitting harder up close.
//   * KICK_PITCH 0.50 / KICK_VARIANCE 0.25 is the flattest recoil on the
//     ladder — the Glock is 0.55 with a 2.25 variance, so the Five-seven's
//     shots stack almost on top of each other where the Glock's scatter.
//   * MOVE_SPREAD 0.050 and FULL_SPREAD_SPEED 320 are the shared pistol
//     handling numbers, unchanged from the Glock.
//
// Reserve is 100 against the Glock's 40, which is the cheap-ammo half of the
// same idea: you get to spend the extra rounds the low per-shot damage costs.
const float CSFIVESEVEN_BASE_SPREAD          = 0.010;
const float CSFIVESEVEN_MOVE_SPREAD          = 0.050;
const float CSFIVESEVEN_FULL_SPREAD_SPEED    = 320;
const float CSFIVESEVEN_CLOSE_DAMAGE         = 20;
const float CSFIVESEVEN_MIN_DAMAGE           = 12;
const float CSFIVESEVEN_DAMAGE_FALLOFF_RANGE = 2400;
const float CSFIVESEVEN_KICK_PITCH    = 0.50;   // sv_gunkick — flattest recoil in the pistol class.
const float CSFIVESEVEN_KICK_VARIANCE = 0.25;
const float CSFIVESEVEN_KICK_STRENGTH = 1.0;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the Glock's pistol numbers and pulled back for the Five-seven's shorter
// slide; treat these as a starting point rather than tuned values.
const float CSFIVESEVEN_MUZZLE_FORWARD = 36;
const float CSFIVESEVEN_MUZZLE_RIGHT   = 12.8;
const float CSFIVESEVEN_MUZZLE_DOWN    = 8.8;

const string CSFIVESEVEN_VIEWMODEL    = "models/v_fiveseven.mdl";
const string CSFIVESEVEN_WORLDMODEL   = "models/w_fiveseven.mdl";
const string CSFIVESEVEN_DEPLOY_SOUND = "";
const string CSFIVESEVEN_DISPLAY_NAME = "Five-Seven";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float fiveseven_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSFiveSevenSeqIdle   = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "idle1",       CSFIVESEVEN_SEQ_IDLE); };
float() SH_CSFiveSevenSeqShoot1 = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "shoot1",      CSFIVESEVEN_SEQ_SHOOT1); };
float() SH_CSFiveSevenSeqShoot2 = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "shoot2",      CSFIVESEVEN_SEQ_SHOOT2); };
float() SH_CSFiveSevenSeqShootE = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "shoot_empty", CSFIVESEVEN_SEQ_SHOOTE); };
float() SH_CSFiveSevenSeqReload = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "reload",      CSFIVESEVEN_SEQ_RELOAD); };
float() SH_CSFiveSevenSeqDraw   = { return SH_SeqForName(CSFIVESEVEN_VIEWMODEL, "draw",        CSFIVESEVEN_SEQ_DRAW); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CSGLOCK pattern.  `mag_left` is
// the magazine count AFTER this shot: at zero the model has a dedicated
// slide-locks-back take.  Only TWO ordinary takes here, so the hash splits in
// half rather than in thirds.
float(float action_id, float mag_left) SH_CSFiveSevenPickShootSeq =
{
    if (mag_left <= 0)
        return SH_CSFiveSevenSeqShootE();
    float r = SH_SpreadHash(action_id);
    if (r < 0.5) return SH_CSFiveSevenSeqShoot1();
    return SH_CSFiveSevenSeqShoot2();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSFiveSevenDrawDuration   = { return SH_SeqDuration(CSFIVESEVEN_VIEWMODEL, SH_CSFiveSevenSeqDraw(),   1.000); };
float() SH_CSFiveSevenReloadDuration = { return SH_SeqDuration(CSFIVESEVEN_VIEWMODEL, SH_CSFiveSevenSeqReload(), 3.200); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSFiveSevenTickState =
{
    float rel = SH_CSFiveSevenReloadDuration();
    // The fire window is whatever shoot take is currently loaded in
    // weaponframe; 0.639 is every shoot sequence's length in the cstrike
    // model and serves as the fallback if the model failed to load.
    return SH_StandardTickState(now, mag_fiveseven, ammo_fiveseven, MAX_MAG_CSFIVESEVEN,
        SH_CSFiveSevenDrawDuration(),
        SH_SeqDuration(CSFIVESEVEN_VIEWMODEL, self.weaponframe, 0.639),
        rel, rel * CSFIVESEVEN_RELOAD_F_APPLY);
};

float(float now) SH_CSFiveSevenTryFire =
{
    // Semi-auto: must release +attack between shots.  SH_StandardTryFire would
    // make this a full-auto machine pistol.
    return SH_StandardTryFireSemiAuto(now, mag_fiveseven,
        CSFIVESEVEN_FIRE_DELAY, CSFIVESEVEN_DRYFIRE_DELAY);
};

float(float now) SH_CSFiveSevenTryReload =
{
    return SH_StandardTryReload(now, mag_fiveseven, ammo_fiveseven, MAX_MAG_CSFIVESEVEN,
        SH_CSFiveSevenReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSFiveSevenPickupCopy =
{
    player.mag_fiveseven  = self.mag_fiveseven;
    player.ammo_fiveseven = self.ammo_fiveseven;
};

void() W_CSFiveSevenShoot =
{
    W_PenetratingHitscanShoot(CSFIVESEVEN_BASE_SPREAD, CSFIVESEVEN_MOVE_SPREAD, CSFIVESEVEN_FULL_SPREAD_SPEED,
        CSFIVESEVEN_CLOSE_DAMAGE, CSFIVESEVEN_MIN_DAMAGE, CSFIVESEVEN_DAMAGE_FALLOFF_RANGE, 8, 0.94,
        CSFIVESEVEN_KICK_PITCH, CSFIVESEVEN_KICK_VARIANCE, CSFIVESEVEN_KICK_STRENGTH);
};

void() W_CSFiveSevenFire =
{
    float r = SH_CSFiveSevenTryFire(time);

    if (r == 1)
    {
        // mag_fiveseven is already decremented by SH_StandardTryFire, so this
        // is the post-shot count — which is what selects shoot_empty.
        self.weaponframe         = SH_CSFiveSevenPickShootSeq(self.wep_action_id, self.mag_fiveseven);
        self.wep_nextframe       = time + CSFIVESEVEN_FRAME_INTERVAL;
        self.fiveseven_snd_stage = 0;

        W_CSFiveSevenShoot();

        sound(self, CHAN_WEAPON, "weapons/fiveseven-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSFiveSevenReload =
{
    if (SH_CSFiveSevenTryReload(time))
    {
        self.weaponframe         = SH_CSFiveSevenSeqReload();
        self.wep_nextframe       = time + CSFIVESEVEN_FRAME_INTERVAL;
        self.fiveseven_snd_stage = 0;
    }
};

void() W_CSFiveSevenFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSFIVESEVEN_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSFiveSevenDrawDuration() * CSFIVESEVEN_DRAW_F_SLIDEPULL
            && self.fiveseven_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/fiveseven_slidepull.wav", 1, ATTN_NORM);
            self.fiveseven_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSFiveSevenReloadDuration();

        if (elapsed >= rel * CSFIVESEVEN_RELOAD_F_CLIPOUT && self.fiveseven_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/fiveseven_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.fiveseven_snd_stage = 1;
        }
        if (elapsed >= rel * CSFIVESEVEN_RELOAD_F_CLIPIN && self.fiveseven_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/fiveseven_clipin.wav", 1, ATTN_NORM);
            self.fiveseven_snd_stage = 2;
        }
        if (elapsed >= rel * CSFIVESEVEN_RELOAD_F_SLIDE && self.fiveseven_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/fiveseven_sliderelease.wav", 1, ATTN_NORM);
            self.fiveseven_snd_stage = 3;
        }
    }

    result = SH_CSFiveSevenTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_CSFiveSevenSeqIdle();
        self.wep_nextframe       = 0;
        self.fiveseven_snd_stage = 0;
    }
};

void() W_CSFiveSevenEquip =
{
    // No scope class — the Five-seven has iron sights only, so the ADS profile
    // is the eligible/no-scope form the CF pistols use.
    W_SetADSProfile(TRUE, "cl_ads_csfiveseven", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSFIVESEVEN_VIEWMODEL, CSFIVESEVEN_DISPLAY_NAME, SH_CSFiveSevenSeqDraw(),
        CSFIVESEVEN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSFiveSevenFire;
    self.reload   = W_CSFiveSevenReload;
    self.wepframe = W_CSFiveSevenFrame;
    self.shoot    = W_CSFiveSevenShoot;
    self.fiveseven_snd_stage = 0;
    W_SetCrosshairProfile(CSFIVESEVEN_BASE_SPREAD, CSFIVESEVEN_MOVE_SPREAD,
        CSFIVESEVEN_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_CSFiveSevenDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_fiveseven  = self.mag_fiveseven;
    tgt.ammo_fiveseven = self.ammo_fiveseven;

    self.mag_fiveseven  = 0;
    self.ammo_fiveseven = 0;

    setmodel(tgt, CSFIVESEVEN_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname      = "weapon_fiveseven";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSFIVESEVEN;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_CSFiveSevenEquip;
    tgt.weap_drop_func = W_CSFiveSevenDrop;
    tgt.pickupcopy     = W_CSFiveSevenPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_fiveseven had zero
// references in this tree before this weapon existed, so nothing is displaced
// and a GoldSrc CS map placing one now gets the Five-seven rather than "no
// spawn function".
void() weapon_fiveseven =
{
    setmodel(self, CSFIVESEVEN_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname      = "weapon_fiveseven";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSFIVESEVEN;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_CSFiveSevenEquip;
    self.weap_drop_func = W_CSFiveSevenDrop;
    self.pickupcopy     = W_CSFiveSevenPickupCopy;
    self.touch          = weapon_touch;
    self.mag_fiveseven  = MAX_MAG_CSFIVESEVEN;
    self.ammo_fiveseven = MAX_AMMO_CSFIVESEVEN;
    W_RegisterMapWeapon(weapon_fiveseven);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_fiveseven_snd_stage;
float csqc_fiveseven_snd_action;

void() CSQC_PredictCSFiveSevenCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_fiveseven_snd_action)
    {
        csqc_fiveseven_snd_action = predicted_player.wep_action_id;
        csqc_fiveseven_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSFiveSevenTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/fiveseven-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSFIVESEVEN_BASE_SPREAD, CSFIVESEVEN_MOVE_SPREAD, CSFIVESEVEN_FULL_SPREAD_SPEED,
                    CSFIVESEVEN_CLOSE_DAMAGE, CSFIVESEVEN_MIN_DAMAGE, CSFIVESEVEN_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    CSFIVESEVEN_KICK_PITCH, CSFIVESEVEN_KICK_VARIANCE, CSFIVESEVEN_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSFIVESEVEN_MUZZLE_FORWARD, CSFIVESEVEN_MUZZLE_RIGHT,
                    CSFIVESEVEN_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSFIVESEVEN_MUZZLE_FORWARD, CSFIVESEVEN_MUZZLE_RIGHT,
                    CSFIVESEVEN_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_fiveseven_snd_stage < 1
                && elapsed >= SH_CSFiveSevenDrawDuration() * CSFIVESEVEN_DRAW_F_SLIDEPULL)
            {
                localsound("weapons/fiveseven_slidepull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_fiveseven_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSFiveSevenReloadDuration();

            if (csqc_fiveseven_snd_stage < 1 && elapsed >= rel * CSFIVESEVEN_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/fiveseven_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_fiveseven_snd_stage = 1;
            }
            if (csqc_fiveseven_snd_stage < 2 && elapsed >= rel * CSFIVESEVEN_RELOAD_F_CLIPIN)
            {
                localsound("weapons/fiveseven_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_fiveseven_snd_stage = 2;
            }
            if (csqc_fiveseven_snd_stage < 3 && elapsed >= rel * CSFIVESEVEN_RELOAD_F_SLIDE)
            {
                localsound("weapons/fiveseven_sliderelease.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_fiveseven_snd_stage = 3;
            }
        }
    }

    SH_CSFiveSevenTickState(csqc_pred_time);
};

void() CSQC_PredictCSFiveSevenReload =
{
    if (SH_CSFiveSevenTryReload(csqc_pred_time))
    {
        csqc_fiveseven_snd_stage  = 0;
        csqc_fiveseven_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSFiveSevenDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSFiveSevenSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSFiveSevenSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSFiveSevenPickShootSeq(predicted_player.wep_action_id,
                                          predicted_player.mag_fiveseven);

    return SH_CSFiveSevenSeqIdle();
};

void() CSQC_CSFiveSevenDropClear =
{
    self.mag_fiveseven  = 0;
    self.ammo_fiveseven = 0;
};

void() CSQC_CSFiveSevenEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_csfiveseven", SCOPE_CLASS_NONE);
    self.weapon_name         = CSFIVESEVEN_DISPLAY_NAME;
    self.weapon_viewmodel    = CSFIVESEVEN_VIEWMODEL;
    self.weapon_worldmodel   = CSFIVESEVEN_WORLDMODEL;
    self.weapon_deploy_sound = CSFIVESEVEN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSFiveSevenCommand;
    self.csqc_predict_reload = CSQC_PredictCSFiveSevenReload;
    self.csqc_display_frame  = CSQC_CSFiveSevenDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSFiveSevenDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED.  This used to read "the CrossFire viewmodels are mirrored and
    // set weapon_viewmodel_flip, the Counter-Strike ones are not" -- but the CS
    // handguns were reported left-handed in game, and they all draw the same
    // stock cstrike arm mesh.  Full reasoning in sh_wpn_csglock.qc.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
