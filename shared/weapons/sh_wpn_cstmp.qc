// ============================================================
//  shared/weapons/sh_wpn_cstmp.qc  -  Counter-Strike Steyr TMP
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 120 reserve, full-auto silenced 9mm SMG
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : none - hipfire only, the shared ADS profile with
//          SCOPE_CLASS_NONE (eligible for iron-sight pull-in, no zoom)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_tmp.mdl, models/w_tmp.mdl,
// models/p_tmp.mdl and every .wav below resolve through the mounted cstrike
// gamedir (fs_addons.txt:16), exactly the way sh_wpn_csaug.qc takes
// models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl from
// valve.  Nothing in this tree collides with it: the TMP has no CrossFire twin,
// so it keeps the bare "tmp" manifest key alongside "cstmp" and its own GoldSrc
// classname key "weapontmp" (sh_weapon_manifest.qc:866).
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_tmp.mdl itself, not guessed:
//
//   [0] idle1    12fps   9 frames  0.667s
//   [1] reload   25fps  54 frames  2.120s
//         f12  5004 "weapons/clipout1.wav"     frac 0.2264
//         f32  5004 "weapons/clipin1.wav"      frac 0.6038
//   [2] draw     18fps  17 frames  0.889s
//         f16  5004 "items/cliprelease1.wav"   frac 1.0000
//   [3] shoot    15fps  13 frames  0.800s   f0 5001 (muzzleflash, attachment 1)
//   [4] shoot    15fps  13 frames  0.800s   f0 5001
//   [5] shoot    15fps  13 frames  0.800s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.
//
// THE RELOAD SAMPLES ARE THE GENERIC ONES ON PURPOSE.  clipout1/clipin1 and
// items/cliprelease1 are the shared valve/CS magazine samples, not TMP-specific
// ones - and that is what the model itself asks for by name.  No tmp_clipout /
// tmp_clipin / tmp_boltpull exists anywhere on either mount (cstrike/sound/weapons
// holds exactly tmp-1.wav and tmp-2.wav for this gun), so there is nothing to
// substitute and nothing missing.  Do not "upgrade" these to invented names.
//
// The idle sequence is labelled "idle1" here, NOT "idle" the way the AUG's is -
// so the by-name lookup below asks for "idle1".  cstrike and czero both ship
// this model and they do NOT agree on its timing: czero's idle1 is 2 frames
// (0.083s) against cstrike's 9 (0.667s), and its shoot takes are 12 frames
// (0.733s) against cstrike's 13 (0.800s).  Both were dumped from the two
// installed copies before this file was written; the reload and draw happen to
// match frame for frame, which is luck, not a guarantee.

// --- Ammo fields ---
.float mag_tmp;
.float ammo_tmp;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted
// (fs_addons.txt:16-17) and both ship models/v_tmp.mdl with the same labels at
// different fps and frame counts - see the idle1/shoot divergence measured
// above.  Whichever mount wins, resolving by name and scaling every mark by
// that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSTMP_SEQ_IDLE   = 0;
const float CSTMP_SEQ_RELOAD = 1;
const float CSTMP_SEQ_DRAW   = 2;
const float CSTMP_SEQ_SHOOT1 = 3;
const float CSTMP_SEQ_SHOOT2 = 4;
const float CSTMP_SEQ_SHOOT3 = 5;

const float CSTMP_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSTMP_FIRE_DELAY       = 0.11;        // CS 1.6 TMP is ~545 rpm
const float CSTMP_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence - see the fps note above.
//
// CSTMP_DRAW_F_RELEASE IS DELIBERATELY NOT 1.0.  The model's own cliprelease1
// event sits on frame 16 of 16, i.e. frac 1.0000 exactly, and a mark tested as
// `elapsed >= dur * frac` at frac 1.0 only fires if a tick happens to land at or
// past the very end of the draw while the weapon is still in WS_DRAW - which the
// 0.0333s tick grid is under no obligation to do, since it is not aligned to
// wep_anim_start.  For the window [frac*dur, dur) to be guaranteed to contain a
// tick it must be at least one tick wide: dur*(1-frac) >= 0.0333 with the draw's
// 0.889s gives frac <= 0.9625.  0.96 clears that with a little margin and puts
// the clip-release 35ms early, which is inaudible.
const float CSTMP_DRAW_F_RELEASE   = 0.9600;   // model says frame 16/16 = 1.0000
const float CSTMP_RELOAD_F_CLIPOUT = 0.2264;   // frame 12 / 53
const float CSTMP_RELOAD_F_CLIPIN  = 0.6038;   // frame 32 / 53
const float CSTMP_RELOAD_F_APPLY   = 0.6800;   // just after the fresh mag seats

const float MAX_MAG_CSTMP          = 30;
const float MAX_AMMO_CSTMP         = 120;

// --- Balance ---
//
// Anchored on sh_wpn_csmp5.qc, the SMG this mod already had placed (12/6,
// falloff 2048).  The TMP lands UNDER it at 9/5, which is the whole point: in CS
// 1.6 the TMP does 20 base damage against the MP5's 26, and at 1250
// (sh_weapon_manifest.qc:1249) it is the cheapest SMG in the buy menu - cheaper
// than the MAC-10 at 1400, the UMP45 at 1700 and the P90 at 2350.  Scaling that
// 20-vs-26 onto the mod's ladder gives 9, which also puts it one point under the
// CS P90's 10 and makes it the weakest per-bullet automatic weapon in the set.
// It is bought for the suppressor and the price, not for the damage.
//
// Falloff 1900 sits between the .45 SMGs (MAC-10 and UMP45 both 1800) and the
// MP5's 2048: same 9mm round as the MP5 out of a much shorter barrel.
//
// Fire delay matches the UMP45's 0.11 - the two are within a few rpm of each
// other in CS 1.6 - so the TMP's advantage over that gun is never rate of fire.
// Spread 0.012/0.070 is a hair worse standing than the UMP45's 0.011 and equal
// moving, and the three kick terms are the LOWEST of the five SMGs here
// (P90 0.60/0.30/1.10, UMP45 0.80/0.40/1.15, MAC-10 0.90/0.50/1.35): the TMP is
// the quiet, flat, easy-to-hold gun that simply does not hurt very much.
const float CSTMP_BASE_SPREAD          = 0.012;
const float CSTMP_MOVE_SPREAD          = 0.070;
const float CSTMP_FULL_SPREAD_SPEED    = 320;
const float CSTMP_CLOSE_DAMAGE         = 9;
const float CSTMP_MIN_DAMAGE           = 5;
const float CSTMP_DAMAGE_FALLOFF_RANGE = 1900;
const float CSTMP_KICK_PITCH    = 0.55;   // sv_gunkick - integrally suppressed
const float CSTMP_KICK_VARIANCE = 0.25;   // and very light; the flattest recoil
const float CSTMP_KICK_STRENGTH = 1.00;   // profile of any SMG in this set

// Muzzle offset - see cl_debug_muzzle for the live-tune marker.  Short weapon,
// so it sits closer to the camera than the SMGs around it (the MP5's 42, the
// MAC-10's 34).  The CS mesh has never been live-tuned; treat these as a
// starting point rather than measured values.
const float CSTMP_MUZZLE_FORWARD = 38;
const float CSTMP_MUZZLE_RIGHT   = 10.0;
const float CSTMP_MUZZLE_DOWN    = 6.5;

const string CSTMP_VIEWMODEL    = "models/v_tmp.mdl";
const string CSTMP_WORLDMODEL   = "models/w_tmp.mdl";
const string CSTMP_DEPLOY_SOUND = "";
const string CSTMP_DISPLAY_NAME = "TMP";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float tmp_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_CSTmpSeqIdle   = { return SH_SeqForName(CSTMP_VIEWMODEL, "idle1",  CSTMP_SEQ_IDLE); };
float() SH_CSTmpSeqReload = { return SH_SeqForName(CSTMP_VIEWMODEL, "reload", CSTMP_SEQ_RELOAD); };
float() SH_CSTmpSeqDraw   = { return SH_SeqForName(CSTMP_VIEWMODEL, "draw",   CSTMP_SEQ_DRAW); };

// ONE lookup for all three firing takes, NOT three.
//
// This model labels sequences 3, 4 and 5 all literally "shoot" - it does not use
// the shoot1/shoot2/shoot3 naming the AUG and the MAC-10 use.  frameforname()
// returns the FIRST match, so SH_SeqForName(VM, "shoot", ...) hands back 3 every
// single time and shoot2/shoot3 are simply unreachable by name.  Three separate
// name lookups here would silently collapse into one sequence and the gun would
// play the same take on every shot.
//
// So the base is resolved once and the other two are derived as base+1 / base+2.
// Contiguity is the only assumption, and it holds on both mounted copies: cstrike
// and czero each ship exactly six sequences with the shoot takes at 3/4/5 (dumped
// from both before this file was written).  This is the same shape sh_wpn_hlsmg.qc
// uses for v_9mmar.mdl, which has the identical three-identically-named-takes
// problem.  DO NOT "fix" this into three SH_SeqForName calls.
float() SH_CSTmpSeqShootBase =
{
    return SH_SeqForName(CSTMP_VIEWMODEL, "shoot", CSTMP_SEQ_SHOOT1);
};

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot - the CFGLOCK pattern.  Takes the seed as
// an argument because the server reads it off `self` and the client off
// `predicted_player`.
float(float action_id) SH_CSTmpPickShootSeq =
{
    float r    = SH_SpreadHash(action_id);
    float base = SH_CSTmpSeqShootBase();
    if (r < 0.3334) return base;                          // CSTMP_SEQ_SHOOT1
    if (r < 0.6667) return base + 1;                      // CSTMP_SEQ_SHOOT2
    return base + 2;                                      // CSTMP_SEQ_SHOOT3
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSTmpDrawDuration   = { return SH_SeqDuration(CSTMP_VIEWMODEL, SH_CSTmpSeqDraw(),   0.889); };
float() SH_CSTmpReloadDuration = { return SH_SeqDuration(CSTMP_VIEWMODEL, SH_CSTmpSeqReload(), 2.120); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_CSTmpTickState =
{
    float rel = SH_CSTmpReloadDuration();
    return SH_StandardTickState(now, mag_tmp, ammo_tmp, MAX_MAG_CSTMP,
        SH_CSTmpDrawDuration(),
        SH_SeqDuration(CSTMP_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSTMP_RELOAD_F_APPLY);
};

// Full-auto: SH_StandardTryFire, not the SemiAuto wrapper.  Holding +attack
// empties the magazine - the TMP has no burst or single mode in CS 1.6.
float(float now) SH_CSTmpTryFire =
{
    return SH_StandardTryFire(now, mag_tmp, CSTMP_FIRE_DELAY, CSTMP_DRYFIRE_DELAY);
};

float(float now) SH_CSTmpTryReload =
{
    return SH_StandardTryReload(now, mag_tmp, ammo_tmp, MAX_MAG_CSTMP,
        SH_CSTmpReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSTmpPickupCopy =
{
    player.mag_tmp  = self.mag_tmp;
    player.ammo_tmp = self.ammo_tmp;
};

void() W_CSTmpShoot =
{
    // Penetration 32 / 0.96: the SMG pair, half the AUG's 64 and a steeper
    // per-unit decay.  A pistol-calibre round punches thin plywood and crate
    // lids and dies in anything structural, which is the CS 1.6 behaviour for
    // every SMG in this set - csmp5 and csmac10 pass the same two numbers.
    W_PenetratingHitscanShoot(CSTMP_BASE_SPREAD, CSTMP_MOVE_SPREAD, CSTMP_FULL_SPREAD_SPEED,
        CSTMP_CLOSE_DAMAGE, CSTMP_MIN_DAMAGE, CSTMP_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CSTMP_KICK_PITCH, CSTMP_KICK_VARIANCE, CSTMP_KICK_STRENGTH);
};

void() W_CSTmpFire =
{
    float r = SH_CSTmpTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CSTmpPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + CSTMP_FRAME_INTERVAL;
        self.tmp_snd_stage = 0;

        W_CSTmpShoot();

        // The TMP is the quiet gun: tmp-1.wav is the suppressed report, and it
        // is the ONLY firing sample cstrike ships for it that the SDK uses
        // (tmp-2.wav exists on the mount but nothing references it).  One sample,
        // no random pick - which also means there is nothing here for the client
        // half to disagree with.
        sound(self, CHAN_WEAPON, "weapons/tmp-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSTmpReload =
{
    if (SH_CSTmpTryReload(time))
    {
        self.weaponframe   = SH_CSTmpSeqReload();
        self.wep_nextframe = time + CSTMP_FRAME_INTERVAL;
        self.tmp_snd_stage = 0;
    }
};

void() W_CSTmpFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model - DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSTMP_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSTmpDrawDuration() * CSTMP_DRAW_F_RELEASE
            && self.tmp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "items/cliprelease1.wav", 1, ATTN_NORM);
            self.tmp_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSTmpReloadDuration();

        if (elapsed >= rel * CSTMP_RELOAD_F_CLIPOUT && self.tmp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/clipout1.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.tmp_snd_stage = 1;
        }
        if (elapsed >= rel * CSTMP_RELOAD_F_CLIPIN && self.tmp_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/clipin1.wav", 1, ATTN_NORM);
            self.tmp_snd_stage = 2;
        }
    }

    result = SH_CSTmpTickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_CSTmpSeqIdle();
        self.wep_nextframe = 0;
        self.tmp_snd_stage = 0;
    }
};

void() W_CSTmpEquip =
{
    // No optics on the real gun and none in CS 1.6, so the ADS profile is
    // eligible-but-unscoped: SCOPE_CLASS_NONE gives the iron-sight pull-in
    // without a zoom stage, exactly as the other CS SMGs do it.
    W_SetADSProfile(TRUE, "cl_ads_cstmp", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSTMP_VIEWMODEL, CSTMP_DISPLAY_NAME, SH_CSTmpSeqDraw(),
        CSTMP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSTmpFire;
    self.reload   = W_CSTmpReload;
    self.wepframe = W_CSTmpFrame;
    self.shoot    = W_CSTmpShoot;
    self.tmp_snd_stage = 0;
    // 1.4 crosshair scale - between the MAC-10's 1.5 and the MP5's 1.2.  The
    // cone is mid-pack for an SMG and the gun is a close-range weapon, so it
    // stays well under the rifles' 1.85.
    W_SetCrosshairProfile(CSTMP_BASE_SPREAD, CSTMP_MOVE_SPREAD, CSTMP_FULL_SPREAD_SPEED, 1.4, TRUE);
};

void() W_CSTmpDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_tmp  = self.mag_tmp;
    tgt.ammo_tmp = self.ammo_tmp;

    self.mag_tmp  = 0;
    self.ammo_tmp = 0;

    setmodel(tgt, CSTMP_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_tmp";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSTMP;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSTmpEquip;
    tgt.weap_drop_func = W_CSTmpDrop;
    tgt.pickupcopy     = W_CSTmpPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_tmp had zero references in
// this tree before this weapon existed - there is no CrossFire TMP to displace -
// so nothing is taken away from anything and a GoldSrc CS map placing one now
// gets this gun rather than "no spawn function".
void() weapon_tmp =
{
    setmodel(self, CSTMP_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_tmp";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSTMP;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSTmpEquip;
    self.weap_drop_func = W_CSTmpDrop;
    self.pickupcopy     = W_CSTmpPickupCopy;
    self.touch          = weapon_touch;
    self.mag_tmp        = MAX_MAG_CSTMP;
    self.ammo_tmp       = MAX_AMMO_CSTMP;
    W_RegisterMapWeapon(weapon_tmp);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_tmp_snd_stage;
float csqc_tmp_snd_action;

void() CSQC_PredictCSTmpCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_tmp_snd_action)
    {
        csqc_tmp_snd_action = predicted_player.wep_action_id;
        csqc_tmp_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSTmpTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/tmp-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSTMP_BASE_SPREAD, CSTMP_MOVE_SPREAD, CSTMP_FULL_SPREAD_SPEED,
                    CSTMP_CLOSE_DAMAGE, CSTMP_MIN_DAMAGE, CSTMP_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CSTMP_KICK_PITCH, CSTMP_KICK_VARIANCE, CSTMP_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSTMP_MUZZLE_FORWARD, CSTMP_MUZZLE_RIGHT,
                    CSTMP_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSTMP_MUZZLE_FORWARD, CSTMP_MUZZLE_RIGHT,
                    CSTMP_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_tmp_snd_stage < 1
                && elapsed >= SH_CSTmpDrawDuration() * CSTMP_DRAW_F_RELEASE)
            {
                localsound("items/cliprelease1.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_tmp_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSTmpReloadDuration();

            if (csqc_tmp_snd_stage < 1 && elapsed >= rel * CSTMP_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/clipout1.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_tmp_snd_stage = 1;
            }
            if (csqc_tmp_snd_stage < 2 && elapsed >= rel * CSTMP_RELOAD_F_CLIPIN)
            {
                localsound("weapons/clipin1.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_tmp_snd_stage = 2;
            }
        }
    }

    SH_CSTmpTickState(csqc_pred_time);
};

void() CSQC_PredictCSTmpReload =
{
    if (SH_CSTmpTryReload(csqc_pred_time))
    {
        csqc_tmp_snd_stage  = 0;
        csqc_tmp_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSTmpDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSTmpSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSTmpSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSTmpPickShootSeq(predicted_player.wep_action_id);

    return SH_CSTmpSeqIdle();
};

void() CSQC_CSTmpDropClear =
{
    self.mag_tmp  = 0;
    self.ammo_tmp = 0;
};

void() CSQC_CSTmpEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_cstmp", SCOPE_CLASS_NONE);
    self.weapon_name         = CSTMP_DISPLAY_NAME;
    self.weapon_viewmodel    = CSTMP_VIEWMODEL;
    self.weapon_worldmodel   = CSTMP_WORLDMODEL;
    self.weapon_deploy_sound = CSTMP_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSTmpCommand;
    self.csqc_predict_reload = CSQC_PredictCSTmpReload;
    self.csqc_display_frame  = CSQC_CSTmpDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSTmpDropClear;
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
