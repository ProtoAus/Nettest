// ============================================================
//  shared/weapons/sh_wpn_cselite.qc  -  Counter-Strike Dual Berettas
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 30-round POOLED magazine, 120 reserve, semi-auto 9mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Quirk : the two guns fire ALTERNATELY — left, right, left, right —
//          and the viewmodel has a separate take for each side.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_elite.mdl, models/w_elite.mdl,
// models/p_elite.mdl (manifest row) and every weapons/elite_*.wav below resolve
// through the mounted cstrike gamedir (fs_addons.txt:16), the same way
// sh_wpn_csaug.qc takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes
// models/v_crowbar.mdl from valve.  Only the dry click is the mod's own file.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_elite.mdl itself, not guessed:
//
//   [ 0] idle             16fps   9f  0.500s
//   [ 1] idle_leftempty   16fps  11f  0.625s   (DELIBERATELY UNUSED — see below)
//   [ 2] shoot_left1      40fps  41f  1.000s   f0 5001  (muzzleflash attachment 0)
//   [ 3] shoot_left2      40fps  41f  1.000s   f0 5001
//   [ 4] shoot_left3      40fps  41f  1.000s   f0 5001
//   [ 5] shoot_left4      40fps  41f  1.000s   f0 5001
//   [ 6] shoot_left5      40fps  41f  1.000s   f0 5001
//   [ 7] shoot_leftlast   40fps  41f  1.000s   f0 5001
//   [ 8] shoot_right1     40fps  41f  1.000s   f0 5011  (muzzleflash attachment 1)
//   [ 9] shoot_right2     40fps  41f  1.000s   f0 5011
//   [10] shoot_right3     40fps  41f  1.000s   f0 5011
//   [11] shoot_right4     40fps  41f  1.000s   f0 5011
//   [12] shoot_right5     40fps  41f  1.000s   f0 5011
//   [13] shoot_rightlast  40fps  41f  1.000s   f0 5011
//   [14] reload           30fps 138f  4.567s   SIX sound events, listed below
//   [15] draw             30fps  33f  1.067s   f1 "weapons/elite_deploy.wav"
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  (The 5001/5011 muzzleflash events carry an attachment index, not a
// name — this mod draws its own flash from cl_muzzleflash.qc instead.)
//
// idle_leftempty IS NOT WIRED, ON PURPOSE.  It is the half-empty pose GoldSrc
// plays once the left gun is dry but the right one is not.  This mod models the
// elites the way CS 1.6 models them — ONE pooled 30-round magazine, not two
// 15-round ones — so there is no "left empty, right loaded" state to key it off,
// and inventing one would mean a new replicated field on the prediction proxy
// for a pose nobody looks at.  Named here so the next reader knows it was seen
// and rejected rather than missed.
//
// ============================================================
//  SEQUENCE INDICES ARE FALLBACKS ONLY
// ============================================================
//
// Every one is resolved by NAME at runtime through SH_SeqForName, because
// cstrike AND czero are both mounted (fs_addons.txt:16-17) and both ship
// models/v_elite.mdl with the same sixteen labels at different frame counts.
// Measured side by side, czero's copy is a different animation set wearing the
// same names:
//
//                     cstrike            czero
//     idle             9f 0.500s          2f 0.063s
//     shoot_*         41f 1.000s         31f 0.750s
//     reload         138f 4.567s        141f 4.667s
//     draw event      frame 1            frame 0
//     reloadstart     frac 0.0438        frac 0.0643
//     rightclipin     frac 0.8175        frac 0.8214
//
// So resolving by name and scaling every mark by THAT model's own duration is
// what keeps the six reload sounds on the animation whichever mount wins.  The
// same divergence is worse elsewhere in this set: czero's v_ump45.mdl carries a
// seventh sequence cstrike's lacks, so an index-keyed lookup there would be
// reading a sequence that is not present at all.
const float CSELITE_SEQ_IDLE       = 0;
const float CSELITE_SEQ_SHOOT_L1   = 2;
const float CSELITE_SEQ_SHOOT_L2   = 3;
const float CSELITE_SEQ_SHOOT_L3   = 4;
const float CSELITE_SEQ_SHOOT_L4   = 5;
const float CSELITE_SEQ_SHOOT_L5   = 6;
const float CSELITE_SEQ_SHOOT_LAST_L = 7;
const float CSELITE_SEQ_SHOOT_R1   = 8;
const float CSELITE_SEQ_SHOOT_R2   = 9;
const float CSELITE_SEQ_SHOOT_R3   = 10;
const float CSELITE_SEQ_SHOOT_R4   = 11;
const float CSELITE_SEQ_SHOOT_R5   = 12;
const float CSELITE_SEQ_SHOOT_LAST_R = 13;
const float CSELITE_SEQ_RELOAD     = 14;
const float CSELITE_SEQ_DRAW       = 15;

// --- Ammo fields ---
//
// ONE pool for both guns.  CS 1.6 does the same thing: the elites carry 30
// rounds between them and the animation alternates which barrel spends one.
// Modelling two 15-round magazines would need a second replicated mag field and
// a second reload path for a difference the player never sees.
.float mag_elite;
.float ammo_elite;

const float CSELITE_FRAME_INTERVAL = 0.0333334;   // state-machine tick rate
const float CSELITE_FIRE_DELAY     = 0.12;        // semi-auto; see the balance note
const float CSELITE_DRYFIRE_DELAY  = 0.20;

// Event marks as a FRACTION of their sequence — see the czero note above.
// Frame numbers are out of (numframes - 1), which is the form SH_SeqDuration
// scales.  The reload's six events, in the order the model fires them:
const float CSELITE_DRAW_F_DEPLOY      = 0.0312;   // frame   1 / 32
const float CSELITE_RELOAD_F_START     = 0.0438;   // frame   6 / 137
const float CSELITE_RELOAD_F_LCLIPIN   = 0.3212;   // frame  44 / 137
const float CSELITE_RELOAD_F_CLIPOUT   = 0.5328;   // frame  73 / 137
const float CSELITE_RELOAD_F_SLIDE1    = 0.5985;   // frame  82 / 137
const float CSELITE_RELOAD_F_RCLIPIN   = 0.8175;   // frame 112 / 137
const float CSELITE_RELOAD_F_SLIDE2    = 0.9124;   // frame 125 / 137
// Ammo credits just after the SECOND magazine seats at 0.8175 — both guns are
// only actually loaded once the right one is fed.
const float CSELITE_RELOAD_F_APPLY     = 0.8800;

const float MAX_MAG_CSELITE  = 30;
const float MAX_AMMO_CSELITE = 120;

// --- Balance ---
//
// Anchored on sh_wpn_cfm9.qc, the single Beretta M9 already on this mod's
// ladder at 24/11 close/min over 2048.  The elites are the SAME pistol twice, so
// they sit just under it per shot at 22/12 rather than above it: what you buy
// with the second gun is the 30-round pool (the M9 carries 15) and a floor that
// is one point higher at range, not a harder hit.  That keeps the secondary
// ladder ordered CSGLOCK 18 < CSELITE 22 < CFM9 24, which is the order the buy
// menu already prices them in (sh_weapon_manifest.qc:1248 — 800 for these,
// against the Five-Seven's 750).
//
// FIRE_DELAY 0.12 against the M9's 0.075 is the real cost.  Both are semi-auto
// so the player is tapping either way, but the elites swing between two guns
// and cannot be tapped as fast as one — and at 22 a shot that would make them
// strictly better than the M9 at any trigger speed.  MOVE_SPREAD 0.070 (the M9
// is 0.06) is the arms-apart stance: worse than any single handgun on the move.
const float CSELITE_BASE_SPREAD          = 0.012;
const float CSELITE_MOVE_SPREAD          = 0.070;
const float CSELITE_FULL_SPREAD_SPEED    = 320;
const float CSELITE_CLOSE_DAMAGE         = 22;
const float CSELITE_MIN_DAMAGE           = 12;
const float CSELITE_DAMAGE_FALLOFF_RANGE = 2048;
const float CSELITE_KICK_PITCH    = 0.6;   // sv_gunkick — light 9mm, one barrel at a time.
const float CSELITE_KICK_VARIANCE = 0.5;
const float CSELITE_KICK_STRENGTH = 1.0;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  RIGHT is
// mirrored per shot: the model has two muzzleflash attachments (0 = left gun,
// 1 = right) and the flash has to come out of whichever one just fired.
const float CSELITE_MUZZLE_FORWARD = 30;
const float CSELITE_MUZZLE_RIGHT   = 12;
const float CSELITE_MUZZLE_DOWN    = 8;

// Casing ejection, in the gun's local frame (x forward, y right, z up) — see
// W_ShellEffect (sv_weapons.qc:1171), which resolves y against v_right.  The y
// terms are mirrored for the left gun for the same reason the muzzle offset is.
// #define, not const vector, so the SSQC and CSQC halves cannot drift apart —
// same idiom as CFM9_MUZZLE_OFFSET in sh_wpn_cfm9.qc.
#define CSELITE_EJECT_OFS ('8 6 -4')
#define CSELITE_EJECT_VEL ('6 46 36')

const string CSELITE_VIEWMODEL    = "models/v_elite.mdl";
const string CSELITE_WORLDMODEL   = "models/w_elite.mdl";
const string CSELITE_DEPLOY_SOUND = "";   // the draw sound is a sequence event, below
const string CSELITE_DISPLAY_NAME = "Dual Berettas";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
// This one runs to SIX because the reload does — every other gun in the set
// tops out at four.
.float elite_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSEliteSeqIdle      = { return SH_SeqForName(CSELITE_VIEWMODEL, "idle",            CSELITE_SEQ_IDLE); };
float() SH_CSEliteSeqReload    = { return SH_SeqForName(CSELITE_VIEWMODEL, "reload",          CSELITE_SEQ_RELOAD); };
float() SH_CSEliteSeqDraw      = { return SH_SeqForName(CSELITE_VIEWMODEL, "draw",            CSELITE_SEQ_DRAW); };
float() SH_CSEliteSeqShootL1   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_left1",     CSELITE_SEQ_SHOOT_L1); };
float() SH_CSEliteSeqShootL2   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_left2",     CSELITE_SEQ_SHOOT_L2); };
float() SH_CSEliteSeqShootL3   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_left3",     CSELITE_SEQ_SHOOT_L3); };
float() SH_CSEliteSeqShootL4   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_left4",     CSELITE_SEQ_SHOOT_L4); };
float() SH_CSEliteSeqShootL5   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_left5",     CSELITE_SEQ_SHOOT_L5); };
float() SH_CSEliteSeqShootLastL= { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_leftlast",  CSELITE_SEQ_SHOOT_LAST_L); };
float() SH_CSEliteSeqShootR1   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_right1",    CSELITE_SEQ_SHOOT_R1); };
float() SH_CSEliteSeqShootR2   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_right2",    CSELITE_SEQ_SHOOT_R2); };
float() SH_CSEliteSeqShootR3   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_right3",    CSELITE_SEQ_SHOOT_R3); };
float() SH_CSEliteSeqShootR4   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_right4",    CSELITE_SEQ_SHOOT_R4); };
float() SH_CSEliteSeqShootR5   = { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_right5",    CSELITE_SEQ_SHOOT_R5); };
float() SH_CSEliteSeqShootLastR= { return SH_SeqForName(CSELITE_VIEWMODEL, "shoot_rightlast", CSELITE_SEQ_SHOOT_LAST_R); };

// WHICH GUN FIRES THIS SHOT.  Returns 1 for the right gun, 0 for the left.
//
// Pure function of wep_action_id, which is what makes the alternation free: the
// server and the client both derive it from a counter that is already
// replicated, so nothing extra goes on the wire and no reconcile-replay can
// desync the side.  Even ids fire left, odd fire right.
//
// `x - floor(x/n)*n` is this codebase's fmod idiom (sh_pmove.qc:2578); QC has no
// `%` operator on floats.
//
// wep_action_id also increments on reload (SH_StandardTryReload), so the very
// first shot after a reload can repeat the side the last shot before it used.
// That is cosmetic — the pool is shared, so no ammo bookkeeping depends on it —
// and it is identical on both sides, which is the property that matters.
float(float action_id) SH_CSEliteFiringRight =
{
    return action_id - floor(action_id / 2) * 2;
};

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CSAUG / CFGLOCK pattern, widened
// to five takes per side.
//
// `mag_left` is the POOLED magazine count AFTER this shot.  At zero the model
// has a dedicated slide-locks-back take for each gun; the pool empties on
// whichever side happened to fire the thirtieth round, so the ..last take is
// chosen on that same side.
float(float action_id, float mag_left) SH_CSElitePickShootSeq =
{
    float right = SH_CSEliteFiringRight(action_id);
    float take;

    if (mag_left <= 0)
    {
        if (right) return SH_CSEliteSeqShootLastR();
        return SH_CSEliteSeqShootLastL();
    }

    // SH_SpreadHash returns [0,1); floor(h*5) is therefore 0..4.  The clamp is
    // belt-and-braces against a hash that ever reaches 1.0.
    take = floor(SH_SpreadHash(action_id) * 5);
    if (take > 4) take = 4;

    if (right)
    {
        if (take <= 0) return SH_CSEliteSeqShootR1();
        if (take == 1) return SH_CSEliteSeqShootR2();
        if (take == 2) return SH_CSEliteSeqShootR3();
        if (take == 3) return SH_CSEliteSeqShootR4();
        return SH_CSEliteSeqShootR5();
    }

    if (take <= 0) return SH_CSEliteSeqShootL1();
    if (take == 1) return SH_CSEliteSeqShootL2();
    if (take == 2) return SH_CSEliteSeqShootL3();
    if (take == 3) return SH_CSEliteSeqShootL4();
    return SH_CSEliteSeqShootL5();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSEliteDrawDuration   = { return SH_SeqDuration(CSELITE_VIEWMODEL, SH_CSEliteSeqDraw(),   1.067); };
float() SH_CSEliteReloadDuration = { return SH_SeqDuration(CSELITE_VIEWMODEL, SH_CSEliteSeqReload(), 4.567); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSEliteTickState =
{
    float rel = SH_CSEliteReloadDuration();
    return SH_StandardTickState(now, mag_elite, ammo_elite, MAX_MAG_CSELITE,
        SH_CSEliteDrawDuration(),
        SH_SeqDuration(CSELITE_VIEWMODEL, self.weaponframe, 1.0),
        rel, rel * CSELITE_RELOAD_F_APPLY);
};

float(float now) SH_CSEliteTryFire =
{
    // SEMI-AUTO: one shot per trigger press, like every other handgun in the
    // tree (CFM9, CSUSP, Deagle).  Holding +attack does not walk the pool.
    return SH_StandardTryFireSemiAuto(now, mag_elite, CSELITE_FIRE_DELAY, CSELITE_DRYFIRE_DELAY);
};

float(float now) SH_CSEliteTryReload =
{
    return SH_StandardTryReload(now, mag_elite, ammo_elite, MAX_MAG_CSELITE,
        SH_CSEliteReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSElitePickupCopy =
{
    player.mag_elite  = self.mag_elite;
    player.ammo_elite = self.ammo_elite;
};

void() W_CSEliteShoot =
{
    W_PenetratingHitscanShoot(CSELITE_BASE_SPREAD, CSELITE_MOVE_SPREAD, CSELITE_FULL_SPREAD_SPEED,
        CSELITE_CLOSE_DAMAGE, CSELITE_MIN_DAMAGE, CSELITE_DAMAGE_FALLOFF_RANGE, 8, 0.94,
        CSELITE_KICK_PITCH, CSELITE_KICK_VARIANCE, CSELITE_KICK_STRENGTH);
};

void() W_CSEliteFire =
{
    float r;
    vector eject_ofs;
    vector eject_vel;

    r = SH_CSEliteTryFire(time);

    if (r == 1)
    {
        // mag_elite is already decremented by SH_StandardTryFire, so this is the
        // post-shot count — which is what selects shoot_leftlast/rightlast.
        self.weaponframe     = SH_CSElitePickShootSeq(self.wep_action_id, self.mag_elite);
        self.wep_nextframe   = time + CSELITE_FRAME_INTERVAL;
        self.elite_snd_stage = 0;

        W_CSEliteShoot();

        sound(self, CHAN_WEAPON, "weapons/elite_fire.wav", 1, ATTN_NORM);

        // Eject out of the gun that fired — mirrored exactly the way
        // CSQC_PredictCSEliteCommand mirrors it, off the same predicate.
        eject_ofs = CSELITE_EJECT_OFS;
        eject_vel = CSELITE_EJECT_VEL;
        if (!SH_CSEliteFiringRight(self.wep_action_id))
        {
            eject_ofs_y = 0 - eject_ofs_y;
            eject_vel_y = 0 - eject_vel_y;
        }
        W_ShellEffect(SHELL_9MM, eject_ofs, eject_vel, '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSEliteReload =
{
    if (SH_CSEliteTryReload(time))
    {
        self.weaponframe     = SH_CSEliteSeqReload();
        self.wep_nextframe   = time + CSELITE_FRAME_INTERVAL;
        self.elite_snd_stage = 0;
    }
};

void() W_CSEliteFrame =
{
    float result;
    float rel;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSELITE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSEliteDrawDuration() * CSELITE_DRAW_F_DEPLOY
            && self.elite_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/elite_deploy.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        rel = SH_CSEliteReloadDuration();

        // SIX stages, in the model's own order.  Note that leftclipin (0.3212)
        // lands BEFORE the event the model calls clipout (0.5328): the anim
        // feeds the left gun first and only drops the right gun's magazine
        // afterwards.  That looks backwards next to every single-gun reload in
        // this tree, and it is what the model does — do not "fix" the order.
        if (elapsed >= rel * CSELITE_RELOAD_F_START && self.elite_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/elite_reloadstart.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 1;
        }
        if (elapsed >= rel * CSELITE_RELOAD_F_LCLIPIN && self.elite_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/elite_leftclipin.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 2;
        }
        if (elapsed >= rel * CSELITE_RELOAD_F_CLIPOUT && self.elite_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/elite_clipout.wav", 1, ATTN_NORM);
            // One dropped magazine, at the one event the model names clipout.
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.elite_snd_stage = 3;
        }
        if (elapsed >= rel * CSELITE_RELOAD_F_SLIDE1 && self.elite_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "weapons/elite_sliderelease.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 4;
        }
        if (elapsed >= rel * CSELITE_RELOAD_F_RCLIPIN && self.elite_snd_stage < 5)
        {
            sound(self, CHAN_AUTO, "weapons/elite_rightclipin.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 5;
        }
        // sliderelease a SECOND time — the model fires the same sample at 0.5985
        // and again at 0.9124, once per gun.  Both emissions are correct.
        if (elapsed >= rel * CSELITE_RELOAD_F_SLIDE2 && self.elite_snd_stage < 6)
        {
            sound(self, CHAN_AUTO, "weapons/elite_sliderelease.wav", 1, ATTN_NORM);
            self.elite_snd_stage = 6;
        }
    }

    result = SH_CSEliteTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSEliteSeqIdle();
        self.wep_nextframe   = 0;
        self.elite_snd_stage = 0;
    }
};

void() W_CSEliteEquip =
{
    // No scope of any kind — SCOPE_CLASS_NONE — but ADS-eligible, so the shared
    // iron-sight envelope in cl_codscope.qc still applies.  Same shape as the
    // CFM9's W_SetADSProfile(TRUE, ..., SCOPE_CLASS_NONE).
    W_SetADSProfile(TRUE, "cl_ads_cselite", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSELITE_VIEWMODEL, CSELITE_DISPLAY_NAME, SH_CSEliteSeqDraw(),
        CSELITE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSEliteFire;
    self.reload   = W_CSEliteReload;
    self.wepframe = W_CSEliteFrame;
    self.shoot    = W_CSEliteShoot;
    self.elite_snd_stage = 0;
    W_SetCrosshairProfile(CSELITE_BASE_SPREAD, CSELITE_MOVE_SPREAD, CSELITE_FULL_SPREAD_SPEED, 1.35, TRUE);
};

void() W_CSEliteDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_elite  = self.mag_elite;
    tgt.ammo_elite = self.ammo_elite;

    self.mag_elite  = 0;
    self.ammo_elite = 0;

    setmodel(tgt, CSELITE_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname      = "weapon_elite";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSELITE;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_CSEliteEquip;
    tgt.weap_drop_func = W_CSEliteDrop;
    tgt.pickupcopy     = W_CSElitePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_elite had zero references in
// this tree before this weapon existed, so nothing is displaced and a GoldSrc CS
// map placing one now gets the dual Berettas rather than "no spawn function".
void() weapon_elite =
{
    setmodel(self, CSELITE_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname      = "weapon_elite";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSELITE;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_CSEliteEquip;
    self.weap_drop_func = W_CSEliteDrop;
    self.pickupcopy     = W_CSElitePickupCopy;
    self.touch          = weapon_touch;
    self.mag_elite      = MAX_MAG_CSELITE;
    self.ammo_elite     = MAX_AMMO_CSELITE;
    W_RegisterMapWeapon(weapon_elite);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_elite_snd_stage;
float csqc_elite_snd_action;

void() CSQC_PredictCSEliteCommand =
{
    float r;
    float elapsed;
    float rel;
    float muzzle_right;
    vector eject_ofs;
    vector eject_vel;

    // Reset the sound stage on action change so each draw / reload fires its
    // events exactly once even when pmove replay re-runs the same buffered
    // command.
    if (predicted_player.wep_action_id != csqc_elite_snd_action)
    {
        csqc_elite_snd_action = predicted_player.wep_action_id;
        csqc_elite_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSEliteTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/elite_fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSELITE_BASE_SPREAD, CSELITE_MOVE_SPREAD, CSELITE_FULL_SPREAD_SPEED,
                    CSELITE_CLOSE_DAMAGE, CSELITE_MIN_DAMAGE, CSELITE_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    CSELITE_KICK_PITCH, CSELITE_KICK_VARIANCE, CSELITE_KICK_STRENGTH);

                // Same mirror as W_CSEliteFire, off the same predicate and the
                // same wep_action_id — casing and flash come out of whichever
                // gun the viewmodel just cycled.
                eject_ofs = CSELITE_EJECT_OFS;
                eject_vel = CSELITE_EJECT_VEL;
                muzzle_right = CSELITE_MUZZLE_RIGHT;
                if (!SH_CSEliteFiringRight(self.wep_action_id))
                {
                    eject_ofs_y  = 0 - eject_ofs_y;
                    eject_vel_y  = 0 - eject_vel_y;
                    muzzle_right = 0 - muzzle_right;
                }

                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    eject_ofs, eject_vel, '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSELITE_MUZZLE_FORWARD, muzzle_right,
                    CSELITE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSELITE_MUZZLE_FORWARD, muzzle_right,
                    CSELITE_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted draw / reload sounds — same marks as W_CSEliteFrame so the dedup
    // window suppresses the server's CHAN_AUTO echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_elite_snd_stage < 1
                && elapsed >= SH_CSEliteDrawDuration() * CSELITE_DRAW_F_DEPLOY)
            {
                localsound("weapons/elite_deploy.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            rel = SH_CSEliteReloadDuration();

            if (csqc_elite_snd_stage < 1 && elapsed >= rel * CSELITE_RELOAD_F_START)
            {
                localsound("weapons/elite_reloadstart.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 1;
            }
            if (csqc_elite_snd_stage < 2 && elapsed >= rel * CSELITE_RELOAD_F_LCLIPIN)
            {
                localsound("weapons/elite_leftclipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 2;
            }
            if (csqc_elite_snd_stage < 3 && elapsed >= rel * CSELITE_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/elite_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_elite_snd_stage = 3;
            }
            if (csqc_elite_snd_stage < 4 && elapsed >= rel * CSELITE_RELOAD_F_SLIDE1)
            {
                localsound("weapons/elite_sliderelease.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 4;
            }
            if (csqc_elite_snd_stage < 5 && elapsed >= rel * CSELITE_RELOAD_F_RCLIPIN)
            {
                localsound("weapons/elite_rightclipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 5;
            }
            // Second sliderelease — see the note in W_CSEliteFrame.
            if (csqc_elite_snd_stage < 6 && elapsed >= rel * CSELITE_RELOAD_F_SLIDE2)
            {
                localsound("weapons/elite_sliderelease.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_elite_snd_stage = 6;
            }
        }
    }

    SH_CSEliteTickState(csqc_pred_time);
};

void() CSQC_PredictCSEliteReload =
{
    if (SH_CSEliteTryReload(csqc_pred_time))
    {
        csqc_elite_snd_stage  = 0;
        csqc_elite_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  The shoot
// pick reads the same two replicated values the server used — wep_action_id for
// the side and the take, mag_elite for the slide-lock — so the displayed take is
// the one the server chose without anything extra on the wire.
float(float elapsed) CSQC_CSEliteDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSEliteSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSEliteSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSElitePickShootSeq(predicted_player.wep_action_id,
                                      predicted_player.mag_elite);

    return SH_CSEliteSeqIdle();
};

void() CSQC_CSEliteDropClear =
{
    self.mag_elite  = 0;
    self.ammo_elite = 0;
};

void() CSQC_CSEliteEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_cselite", SCOPE_CLASS_NONE);
    self.weapon_name         = CSELITE_DISPLAY_NAME;
    self.weapon_viewmodel    = CSELITE_VIEWMODEL;
    self.weapon_worldmodel   = CSELITE_WORLDMODEL;
    self.weapon_deploy_sound = CSELITE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSEliteCommand;
    self.csqc_predict_reload = CSQC_PredictCSEliteReload;
    self.csqc_display_frame  = CSQC_CSEliteDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSEliteDropClear;
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
