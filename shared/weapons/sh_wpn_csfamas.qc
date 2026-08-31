// ============================================================
//  shared/weapons/sh_wpn_csfamas.qc  -  Counter-Strike FAMAS
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 25-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : the FIRE SELECTOR — +attack2 switches between full-auto and 3-round
//          burst, and +attack then fires in whichever mode is selected
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_famas.mdl, models/w_famas.mdl,
// models/p_famas.mdl and every "weapons/..." sound below resolve through the
// mounted cstrike gamedir (fs_addons.txt:16), the same way sh_wpn_csaug.qc
// takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl
// from valve.  The mod's CrossFire FAMAS (sh_wpn_cffamas.qc) is a DIFFERENT
// pickup with its own shipped model set and keeps the bare "famas" manifest
// key; this one answers to "csfamas".
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_famas.mdl itself, not guessed:
//
//   [0] idle     30fps   2 frames  0.033s
//   [1] reload   30fps  91 frames  3.000s
//         f15  5004 "weapons/famas_clipout.wav"   frac 0.1667
//         f47  5004 "weapons/famas_clipin.wav"    frac 0.5222
//         f65  5004 "weapons/famas_forearm.wav"   frac 0.7222
//   [2] draw     35fps  31 frames  0.857s
//         f10  5004 "weapons/famas_forearm.wav"   frac 0.3333
//   [3] shoot1   35fps  31 frames  0.857s   f0 5001 (muzzleflash, attachment 2)
//   [4] shoot2   35fps  31 frames  0.857s   f0 5001
//   [5] shoot3   35fps  31 frames  0.857s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.
//
// There is NO burst sequence in this model.  CS 1.6 has none either — burst
// mode replays the ordinary shoot takes, which is what the burst path below
// does (same call as single fire into SH_CSFamasPickShootSeq).  Only the sound
// and the cadence differ.

// --- Ammo fields ---
.float mag_famas;
.float ammo_famas;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt:16-17)
// and both ship models/v_famas.mdl with the same labels at different fps and
// frame counts.  Whichever mount wins, resolving by name and scaling every mark
// by that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSFAMAS_SEQ_IDLE   = 0;
const float CSFAMAS_SEQ_RELOAD = 1;
const float CSFAMAS_SEQ_DRAW   = 2;
const float CSFAMAS_SEQ_SHOOT1 = 3;
const float CSFAMAS_SEQ_SHOOT2 = 4;
const float CSFAMAS_SEQ_SHOOT3 = 5;

const float CSFAMAS_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSFAMAS_FIRE_DELAY       = 0.09;        // CS 1.6 FAMAS is ~666 rpm
const float CSFAMAS_DRYFIRE_DELAY    = 0.20;

// --- Burst timing ---
//
// The selector's second position: three rounds, faster than the automatic
// cadence, then a long enforced pause.  0.055 between rounds against the
// 0.09 of full-auto is the whole point of the mode — the burst lands before
// the recoil has time to walk, and pays for it with the cooldown.
const float CSFAMAS_BURST_FIRE_DELAY = 0.055;   // gap between burst rounds
const float CSFAMAS_BURST_COOLDOWN   = 0.40;    // trigger dead until this expires

// Burst is a gameplay window, not a sequence: the model has no burst take, so
// unlike every other duration in this file this one CANNOT come from
// SH_SeqDuration and is derived from the burst's own timings instead — the
// same call sh_wpn_csglock.qc had to make for the Glock.
//
//   round 1 at 0.000 (fired by SH_CSFamasTryBurst itself)
//   round 2 at 0.055
//   round 3 at 0.110      = 2 * CSFAMAS_BURST_FIRE_DELAY
//   + 0.055 so the third take is not cut off mid-recoil
//   + 0.200 settle tail
//   = 0.365
//
// It MUST stay below CSFAMAS_BURST_COOLDOWN.  WS_SPECIAL blocks both triggers
// while it runs, so a burst window longer than the cooldown would become the
// real rate limit and the 0.40 above would be a lie.  0.365 leaves 0.035s of
// margin: the gun is visibly back on idle a hair before the trigger goes live.
const float CSFAMAS_BURST_DURATION   = 0.365;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSFAMAS_DRAW_F_FOREARM   = 0.3333;   // frame 10 / 30
const float CSFAMAS_RELOAD_F_CLIPOUT = 0.1667;   // frame 15 / 90
const float CSFAMAS_RELOAD_F_CLIPIN  = 0.5222;   // frame 47 / 90
const float CSFAMAS_RELOAD_F_FOREARM = 0.7222;   // frame 65 / 90
const float CSFAMAS_RELOAD_F_APPLY   = 0.6800;   // just after the fresh mag seats

const float MAX_MAG_CSFAMAS          = 25;
const float MAX_AMMO_CSFAMAS         = 90;

// --- Balance ---
//
// 30/20 close/min is copied straight off sh_wpn_cffamas.qc, for the same reason
// sh_wpn_csgalil.qc copies its CF twin: it is literally the same rifle already
// placed on this mod's ladder, and two pickups of one gun should not hit
// differently.  That puts it in the cheap-rifle band with the Galil (30/20) and
// under the CS AUG (32/21), the SG-552 (33) and the AK47 (34), which is the
// order CS 1.6 and the manifest price line both give it — famas 2250 against
// galil 2000 and aug/sg552 3500 apiece.  Falloff 2304 matches the CF twin, the
// AUG and the AK47; the FAMAS is a full-power 5.56 rifle and keeps rifle reach
// even though it does not keep rifle damage.
//
// What the extra 250 dollars over the Galil buys is accuracy and the selector:
// BASE_SPREAD 0.010 is the AUG's, the tightest of the new CS rifles (Galil
// 0.012), and the alt-fire burst below trades 3 damage a round for a cadence no
// other rifle here has.  What it pays is the magazine — 25 rounds, the smallest
// of the four.
const float CSFAMAS_BASE_SPREAD          = 0.010;
const float CSFAMAS_MOVE_SPREAD          = 0.070;
const float CSFAMAS_FULL_SPREAD_SPEED    = 320;
const float CSFAMAS_CLOSE_DAMAGE         = 30;
const float CSFAMAS_MIN_DAMAGE           = 20;
const float CSFAMAS_DAMAGE_FALLOFF_RANGE = 2304;
const float CSFAMAS_KICK_PITCH    = 1.40;   // sv_gunkick — climbs a little more
const float CSFAMAS_KICK_VARIANCE = 1.30;   // than the AUG's 1.3/1.2 and a
const float CSFAMAS_KICK_STRENGTH = 0.95;   // little less than the Galil's 1.45/1.35.

// Burst rounds: slightly worse per shot than automatic fire so the mode is a
// choice and not a strict upgrade.  27 close (against 30) means a three-round
// burst is 81 rather than 90, and 0.013 spread (against 0.010) means the three
// holes are not the one hole the tight cadence would otherwise guarantee.
const float CSFAMAS_BURST_SPREAD         = 0.013;
const float CSFAMAS_BURST_DAMAGE         = 27;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the AUG's numbers and pulled in for the FAMAS's shorter bullpup mesh; treat
// these as a starting point rather than tuned values.
const float CSFAMAS_MUZZLE_FORWARD = 40;
const float CSFAMAS_MUZZLE_RIGHT   = 9.0;
const float CSFAMAS_MUZZLE_DOWN    = 5.6;

const string CSFAMAS_VIEWMODEL    = "models/v_famas.mdl";
const string CSFAMAS_WORLDMODEL   = "models/w_famas.mdl";
const string CSFAMAS_DEPLOY_SOUND = "";
const string CSFAMAS_DISPLAY_NAME = "FAMAS";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float famas_snd_stage;

// --- Burst state ---
.float famas_burst_count;   // rounds still queued in this burst (0 = not bursting)
.float famas_burst_next;    // absolute time the next queued round goes off

// --- The fire selector ---
//
// THE SELECTOR IS A MODE, NOT A TRIGGER, and that is the change from the first
// version of this weapon.  +attack2 used to FIRE a burst directly while +attack
// stayed full-auto — two triggers, one gun.  The real FAMAS (and CS 1.6) has one
// trigger and a selector switch: right-click moves the switch, left-click fires
// whatever the switch is set to.
//
// famas_burst_mode rides the prediction proxy's weapon-state section (v29) beside
// wep_deployed.  It has to: it decides which of two very different things
// +attack does, so a client whose copy had drifted would predict the wrong one
// outright — the same argument satchel_state's byte is there for.
.float famas_burst_mode;    // 0 = full-auto, 1 = 3-round burst

// Rising-edge latch for the selector.  NOT proxied and deliberately so: it is
// re-derived every frame from the +attack2 bit both sides already have (the
// server through altfire/altrelease, which sv_weapons.qc:4993-5001 calls one or
// the other of EVERY frame; CSQC through input_buttons), so it re-converges on
// its own and a stale copy cannot outlive one command.
.float famas_alt_held;
.float famas_sel_next;      // debounce clock for the switch itself

// Debounce on the switch itself, so a click that spans two commands cannot flip
// it twice.  Short — this is a thumb on a lever, not an animation.
const float CSFAMAS_SELECTOR_DELAY = 0.25;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSFamasSeqIdle   = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "idle",   CSFAMAS_SEQ_IDLE); };
float() SH_CSFamasSeqReload = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "reload", CSFAMAS_SEQ_RELOAD); };
float() SH_CSFamasSeqDraw   = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "draw",   CSFAMAS_SEQ_DRAW); };
float() SH_CSFamasSeqShoot1 = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "shoot1", CSFAMAS_SEQ_SHOOT1); };
float() SH_CSFamasSeqShoot2 = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "shoot2", CSFAMAS_SEQ_SHOOT2); };
float() SH_CSFamasSeqShoot3 = { return SH_SeqForName(CSFAMAS_VIEWMODEL, "shoot3", CSFAMAS_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CFGLOCK pattern.  Burst rounds
// come through here too: they bump wep_action_id the same way single shots do,
// so the takes keep cycling across a burst instead of freezing on one.
float(float action_id) SH_CSFamasPickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSFamasSeqShoot1();
    if (r < 0.6667) return SH_CSFamasSeqShoot2();
    return SH_CSFamasSeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSFamasDrawDuration   = { return SH_SeqDuration(CSFAMAS_VIEWMODEL, SH_CSFamasSeqDraw(),   0.857); };
float() SH_CSFamasReloadDuration = { return SH_SeqDuration(CSFAMAS_VIEWMODEL, SH_CSFamasSeqReload(), 3.000); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSFamasTickState =
{
    float elapsed;

    // WS_SPECIAL = a burst is playing.  Held apart from WS_FIRE because the
    // window is not a sequence length: the shoot takes run 0.857s, far past the
    // cooldown, so letting SH_StandardTickState time this off the sequence
    // would lock the trigger for more than twice as long as intended.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= CSFAMAS_BURST_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_CSFamasReloadDuration();
    return SH_StandardTickState(now, mag_famas, ammo_famas, MAX_MAG_CSFAMAS,
        SH_CSFamasDrawDuration(),
        SH_SeqDuration(CSFAMAS_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSFAMAS_RELOAD_F_APPLY);
};

// The AUTOMATIC half of the trigger — SH_StandardTryFire, not the SemiAuto
// wrapper.  Reached only while the selector is on auto; SH_CSFamasTryBurst below
// is the other half.  W_CSFamasFire / CSQC_PredictCSFamasCommand pick between
// them off famas_burst_mode, so there is one trigger and two behaviours rather
// than two triggers.
float(float now) SH_CSFamasTryFire =
{
    // A burst owns the gun until it finishes: neither the queued rounds nor the
    // WS_SPECIAL window may be cut short by a mode change mid-burst.
    if (self.weaponstate == WS_SPECIAL || self.famas_burst_count > 0)
        return 0;
    return SH_StandardTryFire(now, mag_famas, CSFAMAS_FIRE_DELAY, CSFAMAS_DRYFIRE_DELAY);
};

// Move the selector.  Returns TRUE if it actually moved.
//
// Rising edge only, so holding +attack2 flips it once rather than every frame,
// and debounced on top so a press spanning two commands cannot double-flip.  The
// edge latch is cleared by SH_CSFamasSelectorRelease, which both sides call on
// every frame the button is up.
float(float now) SH_CSFamasTrySelector =
{
    if (self.famas_alt_held)
        return FALSE;
    self.famas_alt_held = 1;

    if (Weapon_LowerBlocksFire()) return FALSE;
    // A switch takes a thumb off the grip: not mid-reload, mid-draw or mid-burst.
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return FALSE;
    if (self.famas_burst_count > 0)
        return FALSE;
    // famas_sel_next, NOT famas_burst_next — that one is the queued-round clock
    // and is re-stamped every 0.055 s while a burst drains.
    if (now < self.famas_sel_next)
        return FALSE;

    self.famas_burst_mode = !self.famas_burst_mode;
    self.famas_sel_next   = now + CSFAMAS_SELECTOR_DELAY;
    return TRUE;
};

void() SH_CSFamasSelectorRelease =
{
    self.famas_alt_held = 0;
};

float(float now) SH_CSFamasTryReload =
{
    return SH_StandardTryReload(now, mag_famas, ammo_famas, MAX_MAG_CSFAMAS,
        SH_CSFamasReloadDuration());
};

// Start a 3-round burst.  Returns 1 = started, -1 = dry, 0 = blocked.
// The first round goes off in the caller; the other two are queued and drained
// by W_CSFamasFrame / CSQC_PredictCSFamasCommand.
//
// This gate is hand-rolled rather than routed through SH_StandardTryFire
// because the cooldown, the state and the spread penalty all differ — the same
// reason SH_GlockTryBurst and SH_THM16TryBurst are hand-rolled.  It therefore
// has to repeat SH_StandardTryFire's guards by hand, INCLUDING the CSQC
// reconcile-replay latch: without csqc_fire_guard a replayed buffered command
// re-runs the burst and the client predicts rounds the server never fired
// (sh_wpn_thm16a1.qc:170 carries the same three lines for the same reason).
float(float now) SH_CSFamasTryBurst =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return 0;
    if (self.famas_burst_count > 0)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_famas <= 0)
    {
        self.attack_finished = now + CSFAMAS_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + CSFAMAS_DRYFIRE_DELAY;
#endif
        return -1;
    }

    // First round leaves here; the drain loops fire the remaining two.  They
    // re-check the magazine each time, so a burst begun on one or two rounds
    // simply fires what is there instead of dry-clicking the remainder.
    self.mag_famas          -= 1;
    self.weaponstate         = WS_SPECIAL;
    self.wep_action_id      += 1;
    self.wep_anim_start      = now;
    self.famas_burst_count   = 2;
    self.famas_burst_next    = now + CSFAMAS_BURST_FIRE_DELAY;
    self.attack_finished     = now + CSFAMAS_BURST_COOLDOWN;
#ifdef CSQC
    self.csqc_fire_guard     = self.attack_finished;
#endif
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSFamasPickupCopy =
{
    player.mag_famas  = self.mag_famas;
    player.ammo_famas = self.ammo_famas;
};

void() W_CSFamasShoot =
{
    W_PenetratingHitscanShoot(CSFAMAS_BASE_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED,
        CSFAMAS_CLOSE_DAMAGE, CSFAMAS_MIN_DAMAGE, CSFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CSFAMAS_KICK_PITCH, CSFAMAS_KICK_VARIANCE, CSFAMAS_KICK_STRENGTH);
};

void() W_CSFamasBurstShoot =
{
    W_PenetratingHitscanShoot(CSFAMAS_BURST_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED,
        CSFAMAS_BURST_DAMAGE, CSFAMAS_MIN_DAMAGE, CSFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CSFAMAS_KICK_PITCH, CSFAMAS_KICK_VARIANCE, CSFAMAS_KICK_STRENGTH);
};

// The BURST half of the trigger, split out so W_CSFamasFire can route to it.
void() W_CSFamasFireBurst;

void() W_CSFamasFire =
{
    // ONE TRIGGER, TWO MODES.  The selector decides which; +attack2 no longer
    // fires anything of its own.
    if (self.famas_burst_mode)
    {
        W_CSFamasFireBurst();
        return;
    }

    float r = SH_CSFamasTryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSFamasPickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSFAMAS_FRAME_INTERVAL;
        self.famas_snd_stage = 0;

        W_CSFamasShoot();

        sound(self, CHAN_WEAPON, "weapons/famas-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

// +attack2 — move the fire selector.  The click is the mount's own selector
// sample; CS 1.6 plays it on exactly this action.
void() W_CSFamasAltFire =
{
    if (SH_CSFamasTrySelector(time))
        sound(self, CHAN_WEAPON, "weapons/famas_forearm.wav", 0.7, ATTN_NORM);
};

void() W_CSFamasAltRelease =
{
    SH_CSFamasSelectorRelease();
};

void() W_CSFamasFireBurst =
{
    float r = SH_CSFamasTryBurst(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSFamasPickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSFAMAS_FRAME_INTERVAL;
        self.famas_snd_stage = 0;

        W_CSFamasBurstShoot();

        // Burst rounds get their own report.  cstrike/sound/weapons ships
        // famas-burst.wav alongside famas-1.wav and it is a SINGLE-shot sample
        // (1.48s against famas-1's 1.40s — the length is the tail, not three
        // reports), so it plays once per round exactly like the automatic
        // sound does.  This is the one place the FAMAS diverges from the
        // Glock's burst pattern, and it is real CS behaviour rather than an
        // invention: the mount carries the file for precisely this mode.
        sound(self, CHAN_WEAPON, "weapons/famas-burst.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSFamasReload =
{
    if (SH_CSFamasTryReload(time))
    {
        self.weaponframe       = SH_CSFamasSeqReload();
        self.wep_nextframe     = time + CSFAMAS_FRAME_INTERVAL;
        self.famas_snd_stage   = 0;
        self.famas_burst_count = 0;   // a reload cancels whatever the burst had left
    }
};

void() W_CSFamasFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine, drains
    // the burst queue and fires the timed sound events.  CHAN_AUTO so the
    // predicted-sound dedup window matches CSQC_RecordPredictedAutoSound on
    // the client.
    self.wep_nextframe += CSFAMAS_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSFamasDrawDuration() * CSFAMAS_DRAW_F_FOREARM
            && self.famas_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/famas_forearm.wav", 1, ATTN_NORM);
            self.famas_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSFamasReloadDuration();

        if (elapsed >= rel * CSFAMAS_RELOAD_F_CLIPOUT && self.famas_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/famas_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.famas_snd_stage = 1;
        }
        if (elapsed >= rel * CSFAMAS_RELOAD_F_CLIPIN && self.famas_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/famas_clipin.wav", 1, ATTN_NORM);
            self.famas_snd_stage = 2;
        }
        if (elapsed >= rel * CSFAMAS_RELOAD_F_FOREARM && self.famas_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/famas_forearm.wav", 1, ATTN_NORM);
            self.famas_snd_stage = 3;
        }
    }

    // Queued burst rounds.  Deliberately outside the weaponstate test so a
    // burst finishes even if something else has moved the state on.
    if (self.famas_burst_count > 0 && time >= self.famas_burst_next)
    {
        if (self.mag_famas > 0)
        {
            self.mag_famas           -= 1;
            self.wep_action_id       += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            W_CSFamasBurstShoot();
            sound(self, CHAN_WEAPON, "weapons/famas-burst.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
            self.weaponframe = SH_CSFamasPickShootSeq(self.wep_action_id);
        }
        self.famas_burst_count -= 1;
        self.famas_burst_next   = time + CSFAMAS_BURST_FIRE_DELAY;
    }

    result = SH_CSFamasTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSFamasSeqIdle();
        self.famas_snd_stage = 0;
        // Idle retire.  Held back while the burst still has rounds queued: a
        // zero here stops wepframe being called at all, and the loop above is
        // the only thing that fires them.  The queue drains at 0.110s and
        // WS_SPECIAL runs 0.365s, so this guard should never be the one that
        // fires — it is here so that shortening CSFAMAS_BURST_DURATION later
        // cannot silently eat two rounds (sh_wpn_thm16a1.qc:349).
        if (self.famas_burst_count <= 0)
            self.wep_nextframe = 0;
    }
};

void() W_CSFamasEquip =
{
    // NOT ADS-ELIGIBLE.  +attack2 is the fire selector on this weapon, and the
    // shared ADS envelope reads the same button (cl_viewfx.qc:281): with both
    // live, every flick of the selector also dragged the gun to the eye.  The
    // prefix stays so its cvars keep a reader.
    W_SetADSProfile(FALSE, "cl_ads_csfamas", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSFAMAS_VIEWMODEL, CSFAMAS_DISPLAY_NAME, SH_CSFamasSeqDraw(),
        CSFAMAS_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire       = W_CSFamasFire;
    self.altfire    = W_CSFamasAltFire;
    self.altrelease = W_CSFamasAltRelease;
    self.reload     = W_CSFamasReload;
    self.wepframe   = W_CSFamasFrame;
    self.shoot      = W_CSFamasShoot;
    self.famas_snd_stage   = 0;
    self.famas_burst_count = 0;
    // The selector survives a re-equip — a soldier who set it to burst expects
    // it to still be on burst when they draw the rifle again.  Only the edge
    // latch is cleared, so a held button does not count as a fresh press.
    self.famas_alt_held    = 0;
    W_SetCrosshairProfile(CSFAMAS_BASE_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CSFamasDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_famas  = self.mag_famas;
    tgt.ammo_famas = self.ammo_famas;

    self.mag_famas         = 0;
    self.ammo_famas        = 0;
    self.famas_burst_count = 0;

    setmodel(tgt, CSFAMAS_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_famas";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSFAMAS;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSFamasEquip;
    tgt.weap_drop_func = W_CSFamasDrop;
    tgt.pickupcopy     = W_CSFamasPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_famas had zero references in
// this tree before this weapon existed — the CrossFire FAMAS spawns as
// weapon_cffamas — so nothing is displaced and a GoldSrc CS map placing one now
// gets the FAMAS rather than "no spawn function".
void() weapon_famas =
{
    setmodel(self, CSFAMAS_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_famas";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSFAMAS;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSFamasEquip;
    self.weap_drop_func = W_CSFamasDrop;
    self.pickupcopy     = W_CSFamasPickupCopy;
    self.touch          = weapon_touch;
    self.mag_famas      = MAX_MAG_CSFAMAS;
    self.ammo_famas     = MAX_AMMO_CSFAMAS;
    W_RegisterMapWeapon(weapon_famas);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_famas_snd_stage;
float csqc_famas_snd_action;

void() CSQC_PredictCSFamasCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_famas_snd_action)
    {
        csqc_famas_snd_action = predicted_player.wep_action_id;
        csqc_famas_snd_stage  = 0;
    }

    // THE FIRE SELECTOR, mirrored from W_CSFamasAltFire / W_CSFamasAltRelease.
    // Runs BEFORE the trigger test so a mode change and a trigger pull arriving in
    // the same command are ordered the way the server orders them.
    if (input_buttons & 4)
    {
        if (SH_CSFamasTrySelector(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/famas_forearm.wav", 0.7, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }
    else
        SH_CSFamasSelectorRelease();

    // ONE TRIGGER, TWO MODES — the mirror of W_CSFamasFire's routing.
    if ((input_buttons & 1) && !predicted_player.famas_burst_mode)
    {
        r = SH_CSFamasTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/famas-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSFAMAS_BASE_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED,
                    CSFAMAS_CLOSE_DAMAGE, CSFAMAS_MIN_DAMAGE, CSFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSFAMAS_KICK_PITCH, CSFAMAS_KICK_VARIANCE, CSFAMAS_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // The BURST half of the same trigger — the first round of a burst.  Mirror of
    // W_CSFamasFireBurst, and reached from +attack now, not +attack2.
    if ((input_buttons & 1) && predicted_player.famas_burst_mode)
    {
        r = SH_CSFamasTryBurst(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/famas-burst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSFAMAS_BURST_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED,
                    CSFAMAS_BURST_DAMAGE, CSFAMAS_MIN_DAMAGE, CSFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSFAMAS_KICK_PITCH, CSFAMAS_KICK_VARIANCE, CSFAMAS_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Queued burst rounds — the mirror of the drain block in W_CSFamasFrame,
    // same predicate, same sound, same shot count.  It runs on csqc_pred_time
    // where the server runs on `time`; the queue is keyed off famas_burst_next,
    // which both sides advance by CSFAMAS_BURST_FIRE_DELAY from their own clock.
    if (self.famas_burst_count > 0 && csqc_pred_time >= self.famas_burst_next)
    {
        if (self.mag_famas > 0)
        {
            self.mag_famas           -= 1;
            self.wep_action_id       += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/famas-burst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSFAMAS_BURST_SPREAD, CSFAMAS_MOVE_SPREAD, CSFAMAS_FULL_SPREAD_SPEED,
                    CSFAMAS_BURST_DAMAGE, CSFAMAS_MIN_DAMAGE, CSFAMAS_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSFAMAS_KICK_PITCH, CSFAMAS_KICK_VARIANCE, CSFAMAS_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT,
                    CSFAMAS_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        self.famas_burst_count -= 1;
        self.famas_burst_next   = csqc_pred_time + CSFAMAS_BURST_FIRE_DELAY;
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_famas_snd_stage < 1
                && elapsed >= SH_CSFamasDrawDuration() * CSFAMAS_DRAW_F_FOREARM)
            {
                localsound("weapons/famas_forearm.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_famas_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSFamasReloadDuration();

            if (csqc_famas_snd_stage < 1 && elapsed >= rel * CSFAMAS_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/famas_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_famas_snd_stage = 1;
            }
            if (csqc_famas_snd_stage < 2 && elapsed >= rel * CSFAMAS_RELOAD_F_CLIPIN)
            {
                localsound("weapons/famas_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_famas_snd_stage = 2;
            }
            if (csqc_famas_snd_stage < 3 && elapsed >= rel * CSFAMAS_RELOAD_F_FOREARM)
            {
                localsound("weapons/famas_forearm.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_famas_snd_stage = 3;
            }
        }
    }

    SH_CSFamasTickState(csqc_pred_time);
};

void() CSQC_PredictCSFamasReload =
{
    if (SH_CSFamasTryReload(csqc_pred_time))
    {
        csqc_famas_snd_stage   = 0;
        csqc_famas_snd_action  = predicted_player.wep_action_id;
        self.famas_burst_count = 0;   // mirrors W_CSFamasReload
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  Burst
// (WS_SPECIAL) shares the shoot takes — the model has no dedicated burst
// sequence, and neither does CS 1.6.
float(float elapsed) CSQC_CSFamasDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSFamasSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSFamasSeqReload();
    if (predicted_player.weaponstate == WS_FIRE
        || predicted_player.weaponstate == WS_SPECIAL)
        return SH_CSFamasPickShootSeq(predicted_player.wep_action_id);

    return SH_CSFamasSeqIdle();
};

void() CSQC_CSFamasDropClear =
{
    self.mag_famas         = 0;
    self.ammo_famas        = 0;
    self.famas_burst_count = 0;
};

void() CSQC_CSFamasEquip =
{
    // Must match W_CSFamasEquip: NOT ADS-eligible, because +attack2 is the fire
    // selector and the shared ADS envelope reads the same button.
    W_SetADSProfile(FALSE, "cl_ads_csfamas", SCOPE_CLASS_NONE);
    self.weapon_name         = CSFAMAS_DISPLAY_NAME;
    self.weapon_viewmodel    = CSFAMAS_VIEWMODEL;
    self.weapon_worldmodel   = CSFAMAS_WORLDMODEL;
    self.weapon_deploy_sound = CSFAMAS_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSFamasCommand;
    self.csqc_predict_reload = CSQC_PredictCSFamasReload;
    self.csqc_display_frame  = CSQC_CSFamasDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSFamasDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game, and sh_wpn_csglock.qc:664 lists
    // this weapon among the ten to flip once reported.
    //
    // LESS CERTAIN THAN THE OTHER EIGHT, and worth an eyeball: v_famas.mdl and
    // v_galil.mdl are the only two in the CS set built on a Bip01 biped rather
    // than the stock rhand/lhand arm meshes that are byte-identical across
    // v_glock18 / v_usp / v_p228 / v_aug / v_mac10 / v_p90 / v_tmp / v_ump45 /
    // v_sg552 / v_xm1014.  So the "same arm, therefore same flip" argument does
    // not carry here — this is set to match the rest of the set.  If the FAMAS
    // alone now looks wrong, this one word is the revert.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
