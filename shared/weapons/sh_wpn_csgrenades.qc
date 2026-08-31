// ============================================================
//  shared/weapons/sh_wpn_csgrenades.qc  -  FIVE thrown grenades, two games
//
//  Slot  : SLOT_UTILITY (multi-carry)
//  Fire  : hold +attack to pull pin, release to throw.  Fuse starts on
//          release and detonates after two seconds.
// ============================================================
//
//  THE FILE NAME IS NOW A LITTLE WRONG and that is deliberate.  It covers the
//  three Counter-Strike grenades it was written for PLUS Day of Defeat's Mills
//  bomb and stick grenade, because the two DoD grenades are functionally the CS
//  HE grenade with different assets and different numbers — pull a pin, throw,
//  two-second fuse, bounce, radius explosion.  Everything in here already
//  dispatches on `wep`, so adding them cost a row in each table instead of a
//  second seven-hundred-line copy of the projectile lifecycle (bounce sounds,
//  resting, the CSQC fake, the explode event, the auto-switch tail).  Renaming
//  the file would have meant touching two .src files and every reference for no
//  behavioural gain, so the header carries the correction instead.
//
//  THE TWO SETS DO NOT SHARE A SEQUENCE LAYOUT, which is the one thing that had
//  to be generalised rather than tabulated.  Measured:
//
//    cstrike v_hegrenade.mdl      idle1 / pullpin / throw  / draw
//    dod     v_mills.mdl          idle  / draw    / pinpull/ holster / throw
//                                 + exploding_idle / _draw / _pinpull / _throw
//    dod     v_stick.mdl          same nine as v_mills
//
//  Different names AND different order — `throw` is index 2 on the CS models
//  and index 4 on the DoD ones — so the four CSGREN_SEQ_* constants below are
//  now FALLBACKS and every lookup goes through SH_CSGrenSeq*, by name.  Feeding
//  a CS index to a DoD model would have played `holster` for a throw.
//
//  THE DoD MODELS CARRY A LIVE-GRENADE SET the CS ones do not: exploding_idle,
//  exploding_draw, exploding_pinpull and exploding_throw, meant for a grenade
//  whose pin is already out.  Wired — see SH_CSGrenSeqPullpin/Throw, which pick
//  the exploding_* take once the pin is gone, because standing there holding a
//  live grenade with the pin still in it is exactly the pose those exist to
//  replace.  On a CS model the lookup falls back to the ordinary take.
//
//  ONE DoD GRENADE IS DELIBERATELY ABSENT: the US Mk2 frag.  Its view model is
//  dod/models/v_grenade.mdl, and `v_grenade.mdl` is one of the TEN model names
//  DoD reuses from Half-Life — with the dod mount deliberately at the bottom of
//  fs_addons.txt (see the note there), that path resolves to Sven's HL hand
//  grenade and always will.  There is no way to ask for the DoD one from QC, and
//  the role is already covered twice over by the HL hand grenade and the CS HE.

.float csgren_throw_pending;
.float csgren_spawn_time;
.float csgren_throw_type;
.float csgren_fake_spawned_serial;
.float csgren_next_bounce_sound;
.float csgren_resting;
// Pin-sound latch.  WS_SPECIAL is held for as long as the player cooks the
// grenade, so the mark inside the pull-pin take needs a once-only guard rather
// than an edge.
.float csgren_pin_played;

const float MAX_AMMO_CSHEGRENADE      = 1;
const float MAX_AMMO_CSFLASHBANG      = 2;
const float MAX_AMMO_CSSMOKEGRENADE   = 1;
// DoD issued its riflemen more grenades than CS does, and they are the cheaper
// weapon here (no flash, no smoke, no utility beyond blast), so two apiece.
const float MAX_AMMO_DODMILLS         = 2;
const float MAX_AMMO_DODSTICK         = 2;

// FALLBACKS ONLY — see the sequence note in the header.  These are the CS
// layout; the DoD models differ in both name and order and are reached by name.
const float CSGREN_SEQ_IDLE           = 0;
const float CSGREN_SEQ_PULLPIN        = 1;
const float CSGREN_SEQ_THROW          = 2;
const float CSGREN_SEQ_DEPLOY         = 3;

const float CSGREN_FRAME_INTERVAL     = 0.05;

// FALLBACKS ONLY.  These three used to be the live numbers, applied to all five
// grenades, and not one of the five actually matched them:
//
//                    deploy   pinpull   throw
//   assumed here      0.730     0.790    0.520
//   cstrike HE/flash/ 0.667     0.976    0.767
//     smoke
//   dod v_stick       0.750     0.833    0.025
//   dod v_mills       0.857     0.733    0.025
//
// The throw row is what you could see.  WS_FIRE ran for 0.520 s against a 0.767 s
// throw take, so the CS release animation was cut off at 68% every single time
// and the next grenade's deploy spliced in over the top of it — and on the LAST
// grenade the state exited there, so the arm never finished the throw at all.
// Everything below now asks the model that actually loaded, the same way every
// other sequence-driven weapon in this tree does; these stay only as the value
// used if a model is missing or not yet precached.
const float CSGREN_DEPLOY_DURATION    = 0.73;
const float CSGREN_PULLPIN_DURATION   = 0.79;
const float CSGREN_THROW_DURATION     = 0.52;

// The DoD models' throw take is TWO FRAMES (0.025 s): a release pose, not an
// arc, because DoD plays holster/draw straight afterwards.  The projectile is
// spawned CSGREN_THROW_DELAY into WS_FIRE, so a phase that short would end the
// state before the grenade ever left the hand.  The throw PHASE is floored here;
// a short take simply holds its final pose (an empty hand) for the remainder,
// which is what it depicts anyway.
const float CSGREN_THROW_MIN          = 0.25;
const float CSGREN_THROW_DELAY        = 0.12;
const float CSGREN_DRYFIRE_DELAY      = 0.2;
const float CSGREN_FUSE_TIME          = 2.0;
const float CSGREN_THROW_FORWARD      = 720;
const float CSGREN_THROW_UPWARD       = 120;     // straight forward, no upward bias
const float CSGREN_GRAVITY            = 0.55;
const float CSGREN_REST_SPEED         = 25;
// Per-bounce velocity multiplier — vanilla MOVETYPE_BOUNCE preserves
// (or even amplifies, default 1.5) momentum on bounce, which made the
// CS grenades feel like superballs.  CS-style "thunk-and-settle" sits
// around 0.45.  Lower = quieter settle, higher = wilder skip.
const float CSGREN_BOUNCEFACTOR       = 0.45;
// Per-bounce angular damping — without this the random ±360 spin set
// at spawn keeps the grenade tumbling forever.  Multiply avelocity by
// this on each surface contact so the spin decays in step with linear
// velocity.
const float CSGREN_BOUNCE_AVEL_DAMP   = 0.55;

const float CSHE_EXPLOSION_DAMAGE     = 100;
const float CSHE_EXPLOSION_RADIUS     = 260;
const float CSHE_EXPLOSION_MIN_DAMAGE = 5;

const float FLASHBANG_RADIUS          = 2000;
const float FLASHBANG_MAX_BLINDNESS   = 5;
const float FLASHBANG_DECAY_RATE      = 1;

// THE MOUNTED COUNTER-STRIKE MODELS, not the mod-local copies under
// models/weapons/wpn_cs*grenade/.
//
// Those copies are not what Counter-Strike ships.  The v_ and p_ ones are
// custom high-poly replacements (526 KB and 279 KB against Valve's 246 KB and
// 26 KB), and the w_ ones are worse than that: they are QUAKE-format models
// (`IDPO`, not `IDST`), 653 KB with 128 frames apiece, and the flashbang's and
// the smoke grenade's are byte-for-byte the same file as each other.  The whole
// set resolves out of the cstrike mount that fs_addons.txt already carries and
// that a hundred-odd other models here already depend on, so these are the
// authentic ones at a fraction of the size.
//
// To go back, put the models/weapons/wpn_cs<x>grenade/ paths back on these nine
// lines and on the matching precaches in shared/sh_customdefs.qc; the old files
// are all still on disk.
const string CSHE_VIEWMODEL           = "models/v_hegrenade.mdl";
const string CSHE_WORLDMODEL          = "models/w_hegrenade.mdl";
const string CSHE_PMODEL              = "models/p_hegrenade.mdl";
const string FLASH_VIEWMODEL          = "models/v_flashbang.mdl";
const string FLASH_WORLDMODEL         = "models/w_flashbang.mdl";
const string FLASH_PMODEL             = "models/p_flashbang.mdl";
const string SMOKE_VIEWMODEL          = "models/v_smokegrenade.mdl";
const string SMOKE_WORLDMODEL         = "models/w_smokegrenade.mdl";
const string SMOKE_PMODEL             = "models/p_smokegrenade.mdl";

const string CSHE_PIN_SOUND           = "sounds/weapons/wpn_cshegrenade/pinpull.wav";
const string FLASH_PIN_SOUND          = "sounds/weapons/wpn_csflashbang/pinpull.wav";
const string SMOKE_PIN_SOUND          = "sounds/weapons/wpn_cssmokegrenade/pinpull.wav";
const string FLASH_RING_SOUND         = "sounds/weapons/wpn_csflashbang/ringing.wav";

// Day of Defeat's two, out of the mounted dod gamedir.  All six names are
// DoD-exclusive — unlike v_grenade.mdl, which is why the US frag is not here
// (see the header).
const string DODMILLS_VIEWMODEL       = "models/v_mills.mdl";
const string DODMILLS_WORLDMODEL      = "models/w_mills.mdl";
const string DODMILLS_PMODEL          = "models/p_mills.mdl";
const string DODSTICK_VIEWMODEL       = "models/v_stick.mdl";
const string DODSTICK_WORLDMODEL      = "models/w_stick.mdl";
const string DODSTICK_PMODEL          = "models/p_stick.mdl";

string(float wep) CSGrenadeViewModel =
{
    if (wep == WEP_CSHEGRENADE) return CSHE_VIEWMODEL;
    if (wep == WEP_CSFLASHBANG) return FLASH_VIEWMODEL;
    if (wep == WEP_CSSMOKEGRENADE) return SMOKE_VIEWMODEL;
    if (wep == WEP_DODMILLS) return DODMILLS_VIEWMODEL;
    if (wep == WEP_DODSTICK) return DODSTICK_VIEWMODEL;
    return "";
};

string(float wep) CSGrenadeWorldModel =
{
    if (wep == WEP_CSHEGRENADE) return CSHE_WORLDMODEL;
    if (wep == WEP_CSFLASHBANG) return FLASH_WORLDMODEL;
    if (wep == WEP_CSSMOKEGRENADE) return SMOKE_WORLDMODEL;
    if (wep == WEP_DODMILLS) return DODMILLS_WORLDMODEL;
    if (wep == WEP_DODSTICK) return DODSTICK_WORLDMODEL;
    return "";
};

string(float wep) CSGrenadeDisplayName =
{
    if (wep == WEP_CSHEGRENADE) return "HE GRENADE";
    if (wep == WEP_CSFLASHBANG) return "FLASHBANG";
    if (wep == WEP_CSSMOKEGRENADE) return "SMOKE";
    if (wep == WEP_DODMILLS) return "MILLS BOMB";
    if (wep == WEP_DODSTICK) return "STICK GRENADE";
    return "GRENADE";
};

// The classnames, in one place rather than repeated as a ternary in the drop
// and spawn commons — which is where a fourth entry would have been forgotten.
// weapon_handgrenade is Half-Life's and is NOT taken here; these are DoD's own.
string(float wep) CSGrenadeClassname =
{
    if (wep == WEP_CSHEGRENADE) return "weapon_cshegrenade";
    if (wep == WEP_CSFLASHBANG) return "weapon_csflashbang";
    if (wep == WEP_DODMILLS) return "weapon_mills";
    if (wep == WEP_DODSTICK) return "weapon_stick";
    return "weapon_cssmokegrenade";
};

// DoD's grenade models carry NO pin event of their own (their only 5004 is
// rifleselect on the draw), so both borrow the CS HE pin — the closest sample in
// any mounted game, and the alternative is silence on the most important frame
// of the animation.
string(float wep) CSGrenadePinSound =
{
    if (wep == WEP_CSHEGRENADE) return CSHE_PIN_SOUND;
    if (wep == WEP_CSFLASHBANG) return FLASH_PIN_SOUND;
    if (wep == WEP_CSSMOKEGRENADE) return SMOKE_PIN_SOUND;
    if (wep == WEP_DODMILLS) return CSHE_PIN_SOUND;
    if (wep == WEP_DODSTICK) return CSHE_PIN_SOUND;
    return "";
};

float(float wep) CSGrenadeProjectileType =
{
    if (wep == WEP_CSHEGRENADE) return PROJ_TYPE_CSHEGRENADE;
    if (wep == WEP_CSFLASHBANG) return PROJ_TYPE_CSFLASHBANG;
    if (wep == WEP_CSSMOKEGRENADE) return PROJ_TYPE_CSSMOKEGRENADE;
    if (wep == WEP_DODMILLS) return PROJ_TYPE_DOD_MILLS;
    if (wep == WEP_DODSTICK) return PROJ_TYPE_DOD_STICK;
    return PROJ_TYPE_HLGRENADE;
};

float(entity player, float wep) CSGrenadeEntityAmmo =
{
    if (!player) return 0;
    if (wep == WEP_CSHEGRENADE) return player.ammo_cshegrenade;
    if (wep == WEP_CSFLASHBANG) return player.ammo_csflashbang;
    if (wep == WEP_CSSMOKEGRENADE) return player.ammo_cssmokegrenade;
    if (wep == WEP_DODMILLS) return player.ammo_dodmills;
    if (wep == WEP_DODSTICK) return player.ammo_dodstick;
    return 0;
};

void(entity player, float wep, float ammo) CSGrenadeSetEntityAmmo =
{
    if (wep == WEP_CSHEGRENADE) player.ammo_cshegrenade = ammo;
    else if (wep == WEP_CSFLASHBANG) player.ammo_csflashbang = ammo;
    else if (wep == WEP_CSSMOKEGRENADE) player.ammo_cssmokegrenade = ammo;
    else if (wep == WEP_DODMILLS) player.ammo_dodmills = ammo;
    else if (wep == WEP_DODSTICK) player.ammo_dodstick = ammo;
};

// --- Balance, for the two DoD grenades ------------------------------------
//
// The CS HE grenade is 100 peak / 5 min over 260 units and is a one-per-life
// finisher.  These two are carried two apiece, so they hit for a little less
// over a slightly wider area — a grenade you have two of should not also be
// the more lethal one:
//
//   Mills bomb      85 / 5 over 280   defensive grenade, thick casing, wide
//   stick grenade   80 / 5 over 300   offensive: less fragmentation, more blast
//
// That is the real difference between the two types and it maps cleanly onto
// peak-vs-radius, so it is what the numbers say.
float(float wep) CSGrenadeBlastDamage =
{
    if (wep == WEP_DODMILLS) return 85;
    if (wep == WEP_DODSTICK) return 80;
    return CSHE_EXPLOSION_DAMAGE;
};

float(float wep) CSGrenadeBlastRadius =
{
    if (wep == WEP_DODMILLS) return 280;
    if (wep == WEP_DODSTICK) return 300;
    return CSHE_EXPLOSION_RADIUS;
};

// TRUE for a grenade that does damage on detonation — i.e. everything except
// the flashbang and the smoke, which have their own effects elsewhere.
float(float wep) CSGrenadeIsExplosive =
{
    return (wep == WEP_CSHEGRENADE || wep == WEP_DODMILLS || wep == WEP_DODSTICK);
};

// --- Sequence resolution, by NAME -----------------------------------------
//
// See the header: the CS and DoD models disagree about both the labels and the
// order, so nothing here may use a bare index.  `live` selects the DoD
// exploding_* take — the pose for a grenade whose pin is already out — and is
// ignored by the CS models, which have no such set and fall through to the
// ordinary take.
// EVERY "DOES THIS MODEL HAVE THAT TAKE" TEST BELOW USES SH_SeqTryName, NOT
// SH_SeqForName WITH A -1 FALLBACK.  They used the latter, and it does not mean
// what it looks like: SH_SeqForName range-checks its fallback and turns a negative
// one into 0 (sh_weapon_standard.qc), which on these models is `idle`.  So
// `if (SH_SeqForName(m, "exploding_pinpull", -1) >= 0)` was ALWAYS true and always
// handed back the idle pose.
//
// That is the whole of the reported "cs grenades, no cooking of grenades in the
// v_model": v_hegrenade / v_flashbang / v_smokegrenade carry exactly four takes —
// idle, pullpin, throw, deploy — and no exploding_* set, so holding +attack
// rendered the resting pose for the entire cook AND the entire throw, while the
// pin sound still played on time out of a hand that never moved.  It also mistimed
// the throw phase, which was measured against idle's 0.333 s instead of throw's
// 0.767 s.  The DoD Mills and stick were unaffected for the cook — they really do
// carry exploding_pinpull — but lost their `pinpull` spelling to the same defect.
float(float wep) SH_CSGrenSeqIdle =
{
    string m = CSGrenadeViewModel(wep);
    // CS spells it idle1, DoD spells it idle.  Try both before the fallback.
    float s = SH_SeqTryName(m, "idle1");
    if (s >= 0) return s;
    return SH_SeqForName(m, "idle", CSGREN_SEQ_IDLE);
};

float(float wep) SH_CSGrenSeqDeploy =
{
    // TWO SPELLINGS, like every other take in this file.  DoD calls it `draw`,
    // Counter-Strike calls it `deploy` — and this asked only for `draw`, so on the
    // three CS models the name missed and it survived purely on the fallback index
    // happening to be 3, which is where cstrike puts `deploy`.  A coincidence, and
    // one that would break silently the moment a mount reordered anything.
    string m = CSGrenadeViewModel(wep);
    float s = SH_SeqTryName(m, "draw");
    if (s >= 0) return s;
    return SH_SeqForName(m, "deploy", CSGREN_SEQ_DEPLOY);
};

float(float wep, float live) SH_CSGrenSeqPullpin =
{
    string m = CSGrenadeViewModel(wep);
    if (live)
    {
        // The COOKED pose — pin out, arm cocked, fuse burning.  DoD only.
        float e = SH_SeqTryName(m, "exploding_pinpull");
        if (e >= 0) return e;
    }
    // CS: "pullpin".  DoD: "pinpull".  Two spellings of one action.
    float s = SH_SeqTryName(m, "pullpin");
    if (s >= 0) return s;
    return SH_SeqForName(m, "pinpull", CSGREN_SEQ_PULLPIN);
};

float(float wep, float live) SH_CSGrenSeqThrow =
{
    string m = CSGrenadeViewModel(wep);
    if (live)
    {
        float e = SH_SeqTryName(m, "exploding_throw");
        if (e >= 0) return e;
    }
    return SH_SeqForName(m, "throw", CSGREN_SEQ_THROW);
};

// --- Live durations, read off the model that actually loaded ---
//
// Every one of these takes `wep` rather than reading self.weapon, because the
// CSQC display frame runs with `self` set to the viewmodel entity, not the
// player, and has to pass predicted_player.weapon in explicitly.
float(float wep) SH_CSGrenDeployDuration =
{
    return SH_SeqDuration(CSGrenadeViewModel(wep), SH_CSGrenSeqDeploy(wep),
                          CSGREN_DEPLOY_DURATION);
};

float(float wep) SH_CSGrenPullpinDuration =
{
    return SH_SeqDuration(CSGrenadeViewModel(wep), SH_CSGrenSeqPullpin(wep, FALSE),
                          CSGREN_PULLPIN_DURATION);
};

// The throw PHASE, not the throw take — see CSGREN_THROW_MIN.
float(float wep) SH_CSGrenThrowPhase =
{
    float d = SH_SeqDuration(CSGrenadeViewModel(wep), SH_CSGrenSeqThrow(wep, TRUE),
                             CSGREN_THROW_DURATION);
    if (d < CSGREN_THROW_MIN)
        return CSGREN_THROW_MIN;
    return d;
};

// Where in the pull-pin take the pin actually comes free.  cstrike's models
// carry the event at frame 27 of 40 (0.675); the DoD pair carry none, and their
// pin sample is a different, shorter noise, so they keep the head of the take.
float(float wep) SH_CSGrenPinFrac =
{
    if (wep == WEP_DODMILLS || wep == WEP_DODSTICK)
        return 0.0;
    return 0.675;
};

float(float wep) CSGrenadeRandomExplodeSample =
{
    float r;
    r = random();
    if (wep == WEP_CSHEGRENADE || wep == WEP_DODMILLS || wep == WEP_DODSTICK)
    {
        if (r < 0.333) return 0;
        if (r < 0.666) return 1;
        return 2;
    }
    if (wep == WEP_CSFLASHBANG)
        return (r < 0.5) ? 0 : 1;
    return 0;
};

string(float wep, float snd_idx) CSGrenadeExplodeSound =
{
    if (wep == WEP_CSHEGRENADE)
    {
        if (snd_idx == 0) return "sounds/weapons/wpn_cshegrenade/explode1.wav";
        if (snd_idx == 1) return "sounds/weapons/wpn_cshegrenade/explode2.wav";
        return "sounds/weapons/wpn_cshegrenade/explode3.wav";
    }
    // DoD's own three, and it ships exactly three, so the same 3-way roll the CS
    // HE grenade uses maps onto them one-for-one.
    if (wep == WEP_DODMILLS || wep == WEP_DODSTICK)
    {
        if (snd_idx == 0) return "weapons/explode3.wav";
        if (snd_idx == 1) return "weapons/explode4.wav";
        return "weapons/explode5.wav";
    }
    if (wep == WEP_CSFLASHBANG)
    {
        if (snd_idx == 0) return "sounds/weapons/wpn_csflashbang/explode1.wav";
        return "sounds/weapons/wpn_csflashbang/explode2.wav";
    }
    if (wep == WEP_CSSMOKEGRENADE)
        return "sounds/weapons/wpn_cssmokegrenade/explode.wav";
    return "";
};

string(float wep, float snd_idx) CSGrenadeBounceSound =
{
    if (wep == WEP_CSHEGRENADE)
        return "sounds/weapons/wpn_cshegrenade/bounce.wav";
    // DoD names its bounce samples grenade_hit1..3.  Three of them, so the same
    // roll the explode sound uses picks one.
    if (wep == WEP_DODMILLS || wep == WEP_DODSTICK)
    {
        if (snd_idx == 0) return "weapons/grenade_hit1.wav";
        if (snd_idx == 1) return "weapons/grenade_hit2.wav";
        return "weapons/grenade_hit3.wav";
    }
    if (wep == WEP_CSFLASHBANG)
    {
        if (snd_idx == 0) return "sounds/weapons/wpn_csflashbang/bounce1.wav";
        return "sounds/weapons/wpn_csflashbang/bounce2.wav";
    }
    if (wep == WEP_CSSMOKEGRENADE)
    {
        if (snd_idx == 0) return "sounds/weapons/wpn_cssmokegrenade/bounce1.wav";
        return "sounds/weapons/wpn_cssmokegrenade/bounce2.wav";
    }
    return "";
};

// WS_FIRE timing has two phases when more grenades are in the pool:
//   [0, THROW_DURATION)                — throw animation
//   [THROW_DURATION, +DEPLOY_DURATION) — pull-out-the-next-grenade
//                                        (DEPLOY sequence, mirrors snowball)
// Last-grenade throws skip the deploy phase — the auto-switch tail in
// W_CSGrenadeFrame fires immediately so the player isn't left waving
// an empty hand for the deploy animation.
float(float now) SH_CSGrenadeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSGrenDeployDuration(self.weapon))
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_SPECIAL)
        return 0;

    if (self.weaponstate == WS_FIRE)
    {
        // The grenade that is IN THE AIR decides how long the throw takes —
        // self.weapon may already have been re-pointed by W_UtilityNextAfterSpent
        // on the last one, and asking the new weapon's model would time the
        // throw against a take from a different grenade.
        float thrown = self.csgren_throw_type;
        if (!thrown) thrown = self.weapon;

        float fire_total = SH_CSGrenThrowPhase(thrown);
        if (CSGrenadeEntityAmmo(self, self.weapon) > 0)
            fire_total = fire_total + SH_CSGrenDeployDuration(self.weapon);
        if (elapsed >= fire_total)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_CSGrenadeTryPinPull =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (CSGrenadeEntityAmmo(self, self.weapon) <= 0)
    {
        self.attack_finished = now + CSGREN_DRYFIRE_DELAY;
        return -1;
    }

    self.weaponstate = WS_SPECIAL;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.attack_finished = now + CSGREN_DRYFIRE_DELAY;
    return 1;
};

float(float now) SH_CSGrenadeThrow =
{
    float wep;

    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;

    if (self.weaponstate != WS_SPECIAL) return 0;

    wep = self.weapon;
    CSGrenadeSetEntityAmmo(self, wep, CSGrenadeEntityAmmo(self, wep) - 1);
    self.csgren_throw_type = wep;
    self.weaponstate = WS_FIRE;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.attack_finished = now + SH_CSGrenThrowPhase(wep);

    if (CSGrenadeEntityAmmo(self, wep) <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(wep);

    return 1;
};

void() SH_CSGrenadeSettleModel =
{
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.angles_x = 0;
    self.angles_z = 0;
    self.csgren_resting = TRUE;
    self.movetype = MOVETYPE_NONE;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSHEGrenadePickupCopy =
{
    player.ammo_cshegrenade = self.ammo_cshegrenade;
};

void(entity player) W_DodMillsPickupCopy =
{
    player.ammo_dodmills = self.ammo_dodmills;
};

void(entity player) W_DodStickPickupCopy =
{
    player.ammo_dodstick = self.ammo_dodstick;
};

void(entity player) W_CSFlashbangPickupCopy =
{
    player.ammo_csflashbang = self.ammo_csflashbang;
};

void(entity player) W_CSSmokeGrenadePickupCopy =
{
    player.ammo_cssmokegrenade = self.ammo_cssmokegrenade;
};

void() W_CSGrenadeExplode =
{
    float wep;
    float snd_idx;
    vector epos;

    wep = self.weapon;
    snd_idx = CSGrenadeRandomExplodeSample(wep);
    epos = self.origin + '0 0 4';

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_CSGRENADE_EXPLODE);
    WriteByte(MSG_MULTICAST, self.owner ? num_for_edict(self.owner) : 0);
    WriteByte(MSG_MULTICAST, wep);
    WriteCoord(MSG_MULTICAST, epos_x);
    WriteCoord(MSG_MULTICAST, epos_y);
    WriteCoord(MSG_MULTICAST, epos_z);
    WriteByte(MSG_MULTICAST, snd_idx);
    multicast(epos, MULTICAST_PVS);

    // The CS HE grenade plus DoD's two — see CSGrenadeIsExplosive.  The
    // flashbang and the smoke reach their effects by other routes and must not
    // fall in here.
    if (CSGrenadeIsExplosive(wep))
    {
        W_RadiusExplode(self.origin, CSGrenadeBlastRadius(wep),
                        CSGrenadeBlastDamage(wep), CSHE_EXPLOSION_MIN_DAMAGE,
                        800, 350, self.owner);
    }

    remove(self);
};

void() W_CSGrenadeProjectileTick =
{
    self.SendFlags |= 1;

    if (!self.csgren_resting
        && time >= self.csgren_spawn_time + 0.25
        && (self.flags & FL_ONGROUND)
        && vlen(self.velocity) < CSGREN_REST_SPEED)
    {
        SH_CSGrenadeSettleModel();
        self.SendFlags |= 1;
    }

    if (time >= self.proj_fuse_end)
    {
        // Smoke grenades defer the cloud deploy until the can has
        // physically come to rest — matches the CS / real-world
        // behaviour where smoke pops only after the canister has
        // landed.  HE and flash still explode in mid-air on the
        // fuse like before; the gate is keyed on the weapon type.
        // If the smoke can never stops (perpetual bounce, sliding
        // along a slope) the deploy waits indefinitely — that's
        // intentional, the rest detector already accepts FL_ONGROUND
        // + low velocity which catches every reasonable settle.
        if (self.weapon == WEP_CSSMOKEGRENADE && !self.csgren_resting)
        {
            self.nextthink = time + Toss_NextThinkInterval();
            return;
        }
        W_CSGrenadeExplode();
        return;
    }

    self.nextthink = time + Toss_NextThinkInterval();
};

void() W_CSGrenadeBounce =
{
    float snd_idx;

    if (other.classname == "player")
        return;

    // Damp spin every contact so the random ±360 throw rotation
    // doesn't outlive the linear velocity.  Engine handles the
    // linear velocity damp via .bouncefactor, but avelocity has no
    // built-in decay path on MOVETYPE_BOUNCE.
    self.avelocity = self.avelocity * CSGREN_BOUNCE_AVEL_DAMP;

    if (time < self.csgren_next_bounce_sound)
        return;

    self.csgren_next_bounce_sound = time + 0.12;
    snd_idx = (random() < 0.5) ? 0 : 1;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_CSGRENADE_BOUNCE);
    WriteByte(MSG_MULTICAST, self.owner ? num_for_edict(self.owner) : 0);
    WriteByte(MSG_MULTICAST, self.weapon);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z);
    WriteByte(MSG_MULTICAST, snd_idx);
    multicast(self.origin, MULTICAST_PVS);
};

void() W_CSGrenadeSpawnProjectile =
{
    entity gren;

    makevectors(self.v_angle);
    gren = spawn();
    gren.owner = self;
    gren.classname = "proj_csgrenade";
    gren.movetype = MOVETYPE_BOUNCE;
    gren.solid = SOLID_BBOX;
    setmodel(gren, CSGrenadeWorldModel(self.csgren_throw_type));
    setsize(gren, '-2 -2 -2', '2 2 2');
    // FTE's point-hull threshold is Quake's `size[0] < 3` (q1bsp.c:1554), not
    // GoldSrc's `size[0] <= 8`.  This bbox is 4 wide, so without the override
    // the grenade collides with the world as HL's 32x32x36 crouch hull
    // (hulls[3], gl_model.c:5564) offset by clip_mins - mins = (-14,-14,-16) —
    // it bounces off nothing visible up to 30 units short of walls, and the
    // bounce normals are wrong.  Same defect as the snark; see the long note in
    // sh_wpn_hlsnark.qc's W_SnarkSpawn.  1 == hulls[0] == the point hull.
    // Set on the CSQC-predicted copy too, or prediction disagrees with the
    // server about every wall the grenade meets.
    gren.hull = 1;
    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
    gren.velocity = self.velocity
                  + v_forward * CSGREN_THROW_FORWARD
                  + v_up      * CSGREN_THROW_UPWARD;
    gren.avelocity = [(random() * 720) - 360,
                      (random() * 720) - 360,
                      (random() * 720) - 360];
    gren.gravity = CSGREN_GRAVITY;
    gren.bouncefactor = CSGREN_BOUNCEFACTOR;
    gren.touch = W_CSGrenadeBounce;
    gren.weapon = self.csgren_throw_type;
    gren.proj_type = CSGrenadeProjectileType(self.csgren_throw_type);
    gren.frame = 0;
    gren.SendEntity = projectile_SendEntity;
    gren.SendFlags = 1;
    gren.csgren_spawn_time = time;
    gren.proj_fuse_end = time + CSGREN_FUSE_TIME;
    gren.think = W_CSGrenadeProjectileTick;
    gren.nextthink = time + Toss_NextThinkInterval();
};

void() W_CSGrenadeFire =
{
    float r;

    r = SH_CSGrenadeTryPinPull(time);
    if (r == 1)
    {
        // `live` is FALSE here: the pin is coming out during THIS take, so the
        // ordinary pinpull is the one that shows it happening.  The exploding_*
        // set is for afterwards.
        self.weaponframe = SH_CSGrenSeqPullpin(self.weapon, FALSE);
        self.wep_nextframe = time + CSGREN_FRAME_INTERVAL;
        self.csgren_pin_played = 0;
        // The sound is NOT played here.  cstrike's pullpin take carries its pin
        // event at frame 27 of 40 — two thirds in — so firing it on the button
        // press put the noise a full 0.66 s before the hand did anything.  It is
        // emitted from W_CSGrenadeFrame below, on the model's own mark.
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_CSGrenadeRelease =
{
    if (!SH_CSGrenadeThrow(time))
        return;

    // `live` TRUE: by the time the throw plays the pin is already gone, which is
    // exactly what the DoD models' exploding_throw depicts.
    self.weaponframe = SH_CSGrenSeqThrow(self.weapon, TRUE);
    self.wep_nextframe = time + CSGREN_FRAME_INTERVAL;
    self.csgren_throw_pending = 1;
    self.csgren_spawn_time = time + CSGREN_THROW_DELAY;
};

void() W_CSGrenadeFrame =
{
    float was_fire;
    float result;

    if (self.weaponstate == WS_SPECIAL)
    {
        // The pin comes free partway through the take — see W_CSGrenadeFire.
        float held = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;
        if (!self.csgren_pin_played
            && held >= SH_CSGrenPullpinDuration(self.weapon) * SH_CSGrenPinFrac(self.weapon))
        {
            sound(self, CHAN_WEAPON, CSGrenadePinSound(self.weapon), 1, ATTN_NORM);
            self.csgren_pin_played = 1;
        }

        if (!self.button0)
        {
            // A TAP MUST STILL PULL THE PIN.  The mark sits 0.659 s into the
            // pullpin take, and a release before that threw the grenade in total
            // silence — you cannot throw a live grenade without the pin having come
            // out, so if the release beats the mark the sound is owed here.
            if (!self.csgren_pin_played)
            {
                sound(self, CHAN_WEAPON, CSGrenadePinSound(self.weapon), 1, ATTN_NORM);
                self.csgren_pin_played = 1;
            }
            W_CSGrenadeRelease();
        }
        return;
    }

    if (self.weaponstate == WS_FIRE
        && self.csgren_throw_pending > 0
        && time >= self.csgren_spawn_time)
    {
        self.csgren_throw_pending = 0;
        W_CSGrenadeSpawnProjectile();
    }

    was_fire = (self.weaponstate == WS_FIRE);
    result = SH_CSGrenadeTickState(time);
    if (was_fire && (result & 1)
        && CSGrenadeEntityAmmo(self, self.weapon) <= 0
        && self.weapon == self.csgren_throw_type)
    {
        // Mirror the CSQC prediction chain in CSQC_PredictCSGrenadeCommand
        // exactly so prediction and authoritative state agree.  Using
        // W_SelectNextWeapon here picked a different fallback (its util
        // cycle is non-wrapping while W_UtilityNextAfterSpent wraps),
        // leaving the player visually on an empty grenade until the
        // client noticed the mismatch.
        if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
        else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
        else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
        else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
    }
};

void(float wep) W_CSGrenadeEquipCommon =
{
    W_StandardEquipSetup(CSGrenadeViewModel(wep), CSGrenadeDisplayName(wep),
        SH_CSGrenSeqDeploy(wep), CSGREN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire = W_CSGrenadeFire;
    self.reload = __NULL__;
    self.wepframe = W_CSGrenadeFrame;
    self.csgren_throw_pending = 0;
    self.csgren_spawn_time = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_CSHEGrenadeEquip = { W_CSGrenadeEquipCommon(WEP_CSHEGRENADE); };
void() W_CSFlashbangEquip = { W_CSGrenadeEquipCommon(WEP_CSFLASHBANG); };
void() W_CSSmokeGrenadeEquip = { W_CSGrenadeEquipCommon(WEP_CSSMOKEGRENADE); };
void() W_DodMillsEquip = { W_CSGrenadeEquipCommon(WEP_DODMILLS); };
void() W_DodStickEquip = { W_CSGrenadeEquipCommon(WEP_DODSTICK); };

void(float wep, void() equip_func, void() drop_func, void(entity) copy_func) W_CSGrenadeDropCommon =
{
    entity tgt;

    tgt = weapon_drop_target;
    CSGrenadeSetEntityAmmo(tgt, wep, CSGrenadeEntityAmmo(self, wep));
    CSGrenadeSetEntityAmmo(self, wep, 0);

    setmodel(tgt, CSGrenadeWorldModel(wep));
    setsize(tgt, '-16 -16 0', '16 16 40');
    tgt.classname = CSGrenadeClassname(wep);
    tgt.solid = SOLID_NOT;
    tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = wep;
    tgt.weapon_slot = SLOT_UTILITY;
    tgt.weap_draw = equip_func;
    tgt.weap_drop_func = drop_func;
    tgt.pickupcopy = copy_func;
    tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid;
    tgt.nextthink = time + 0.7;
};

void() W_CSHEGrenadeDrop =
{ W_CSGrenadeDropCommon(WEP_CSHEGRENADE, W_CSHEGrenadeEquip, W_CSHEGrenadeDrop, W_CSHEGrenadePickupCopy); };

void() W_CSFlashbangDrop =
{ W_CSGrenadeDropCommon(WEP_CSFLASHBANG, W_CSFlashbangEquip, W_CSFlashbangDrop, W_CSFlashbangPickupCopy); };

void() W_CSSmokeGrenadeDrop =
{ W_CSGrenadeDropCommon(WEP_CSSMOKEGRENADE, W_CSSmokeGrenadeEquip, W_CSSmokeGrenadeDrop, W_CSSmokeGrenadePickupCopy); };

void() W_DodMillsDrop =
{ W_CSGrenadeDropCommon(WEP_DODMILLS, W_DodMillsEquip, W_DodMillsDrop, W_DodMillsPickupCopy); };

void() W_DodStickDrop =
{ W_CSGrenadeDropCommon(WEP_DODSTICK, W_DodStickEquip, W_DodStickDrop, W_DodStickPickupCopy); };

void(float wep, void() equip_func, void() drop_func, void(entity) copy_func, float ammo) W_CSGrenadeSpawnCommon =
{
    setmodel(self, CSGrenadeWorldModel(wep));
    setsize(self, '-16 -16 0', '16 16 40');
    self.classname = CSGrenadeClassname(wep);
    self.solid = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.weapon = wep;
    self.weapon_slot = SLOT_UTILITY;
    self.weap_draw = equip_func;
    self.weap_drop_func = drop_func;
    self.pickupcopy = copy_func;
    self.touch = weapon_touch;
    CSGrenadeSetEntityAmmo(self, wep, ammo);
};

void() weapon_cshegrenade =
{
    W_CSGrenadeSpawnCommon(WEP_CSHEGRENADE, W_CSHEGrenadeEquip, W_CSHEGrenadeDrop,
        W_CSHEGrenadePickupCopy, MAX_AMMO_CSHEGRENADE);
    W_RegisterMapWeapon(weapon_cshegrenade);
};

void() weapon_hegrenade = { weapon_cshegrenade(); };

void() weapon_csflashbang =
{
    W_CSGrenadeSpawnCommon(WEP_CSFLASHBANG, W_CSFlashbangEquip, W_CSFlashbangDrop,
        W_CSFlashbangPickupCopy, MAX_AMMO_CSFLASHBANG);
    W_RegisterMapWeapon(weapon_csflashbang);
};

void() weapon_flashbang = { weapon_csflashbang(); };

void() weapon_cssmokegrenade =
{
    W_CSGrenadeSpawnCommon(WEP_CSSMOKEGRENADE, W_CSSmokeGrenadeEquip, W_CSSmokeGrenadeDrop,
        W_CSSmokeGrenadePickupCopy, MAX_AMMO_CSSMOKEGRENADE);
    W_RegisterMapWeapon(weapon_cssmokegrenade);
};

void() weapon_smokegrenade = { weapon_cssmokegrenade(); };

// Day of Defeat's two.  `weapon_mills` and `weapon_stick` are the mod's own
// spelling — DoD hands grenades out with the class kit and gave neither a map
// entity — and neither name is taken anywhere else in this tree.  Deliberately
// NOT `weapon_handgrenade`, which is Half-Life's and already spoken for.
void() weapon_mills =
{
    W_CSGrenadeSpawnCommon(WEP_DODMILLS, W_DodMillsEquip, W_DodMillsDrop,
        W_DodMillsPickupCopy, MAX_AMMO_DODMILLS);
    W_RegisterMapWeapon(weapon_mills);
};

void() weapon_stick =
{
    W_CSGrenadeSpawnCommon(WEP_DODSTICK, W_DodStickEquip, W_DodStickDrop,
        W_DodStickPickupCopy, MAX_AMMO_DODSTICK);
    W_RegisterMapWeapon(weapon_stick);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void(float new_weapon) CSQC_PredictSelectWeapon;
void() CSQC_RecordPredictedWeaponSound;
void() CSQC_MarkPendingWeaponAck;

entity csgren_smoke_list;
.entity csgren_smoke_next;
.float csgren_smoke_spawn_time;
.float csgren_smoke_life;

// One-shot wipe — used by CSQC_EVENT_ROUND_CLEANUP (round restart)
// and CSQC_EVENT_CLEANDECALS (server "cleandecals" cmd).  Walks the
// smoke-puff linked list, removes every entity, nulls the head.
// Without this, smoke puffs survive across rounds (their per-puff
// 11-17 s lifetime is independent of round timing) and the new
// `cleandecals` command would have no way to clear them.
void() CSQC_CSGrenadeSmokeWipeAll =
{
    entity puff = csgren_smoke_list;
    while (puff)
    {
        entity nxt = puff.csgren_smoke_next;
        remove(puff);
        puff = nxt;
    }
    csgren_smoke_list = world;
};
.float csgren_smoke_start_size;
.float csgren_smoke_end_size;
.float csgren_smoke_phase;
.vector csgren_smoke_drift;
.vector csgren_smoke_colour;

float csgren_flash_blindness;
float csgren_flash_last_time;
entity csgren_flash_ring_ent;
float csgren_flash_ring_active;

// CS HE-grenade explosion sprite. Was three randomised hl_explode*
// variants; collapsed to a single new gfx/eexplo.spr per content
// update. snd_idx arg kept so the call site doesn't have to change
// — ignored now (single sprite, no variation). If we want
// per-explosion variation back later, re-introduce the dispatch.
string(float snd_idx) CSQC_CSGrenadeExplosionSprite =
{
    return "gfx/eexplo.spr";
};

void() CSQC_CSGrenadeSpriteThink =
{
    self.frame = self.frame + 1;
    if (self.frame >= 8)
    {
        remove(self);
        return;
    }
    self.nextthink = time + 0.05;
};

void(vector pos, float sample) CSQC_SpawnCSGrenadeSprite =
{
    entity spr;

    // Lift the sprite center 16 qu so the lower half doesn't sink
    // through the ground when the grenade detonates near the floor.
    spr = spawn();
    setorigin(spr, pos + '0 0 16');
    setmodel(spr, CSQC_CSGrenadeExplosionSprite(sample));
    spr.drawmask = MASK_ENGINE;
    spr.effects = EF_ADDITIVE;
    spr.frame = 0;
    spr.think = CSQC_CSGrenadeSpriteThink;
    spr.nextthink = time + 0.05;
};

// Wipe all client-side grenade FX state.  Called from
// CSQC_ResetPredictionState on respawn / disconnect so a flash that
// detonated just before death doesn't bleed its blindness/ringing
// into the next life.  Also removes any fake-grenade entities that
// were still in flight when the player died (their think pointers
// reference functions that read predicted_player; without removal
// the explode() at the end of the fuse would fire against a stale
// or null context).
void() CSQC_ResetCSGrenadeState =
{
    csgren_flash_blindness = 0;
    csgren_flash_last_time = 0;

    if (csgren_flash_ring_ent)
    {
        if (csgren_flash_ring_active)
            sound(csgren_flash_ring_ent, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NONE);
        remove(csgren_flash_ring_ent);
        csgren_flash_ring_ent = world;
    }
    csgren_flash_ring_active = FALSE;

    entity e = findchain(classname, "csqc_fake_csgrenade");
    while (e)
    {
        entity nxt = e.chain;
        remove(e);
        e = nxt;
    }
};

void(vector pos) CSQC_ApplyFlashbang =
{
    vector eye;
    float dist;
    float amount;

    // Eye position priority: predicted_player (normal case) → engine
    // view origin (covers the post-respawn race where a fake grenade's
    // 2 s fuse fires before the new prediction proxy has been spawned,
    // which previously left CSQC_ApplyFlashbang silently no-op'ing the
    // entire flash effect — including any view-angle bonus and the
    // ringing sound).  STAT_HEALTH > 0 ensures we don't blind a
    // spectator camera or a dead body.
    if (predicted_player)
        eye = predicted_player.origin + predicted_player.view_ofs;
    else
        eye = getproperty(VF_ORIGIN);

    if (getstati(STAT_HEALTH) <= 0)
        return;

    dist = vlen(eye - pos);
    if (dist >= FLASHBANG_RADIUS)
        return;

    traceline(eye, pos, MOVE_NOMONSTERS, predicted_player);
    if (trace_fraction < 1 && vlen(trace_endpos - pos) > 24)
        return;

    amount = FLASHBANG_MAX_BLINDNESS * (1 - dist / FLASHBANG_RADIUS);
    if (amount <= 0)
        return;

    // View-angle bonus: looking directly at the flash gets full
    // intensity (1.5×) and a higher blindness cap so the white-out
    // phase lasts longer; perpendicular (0.9×) is roughly the old
    // value; looking away (0.3×) only catches peripheral spill.
    // Mapping is linear over the dot product in [-1, 1].
    makevectors(input_angles);
    vector to_flash = normalize(pos - eye);
    float dot = to_flash * v_forward;
    float angle_mult = 0.3 + (dot + 1) * 0.6;   // -1 → 0.3, 0 → 0.9, 1 → 1.5
    amount = amount * angle_mult;

    // Lift the per-flash blindness cap when the player is looking at
    // the flash so the bonus intensity actually translates into extra
    // duration (decay rate is fixed; higher peak → longer fade).
    // Stay at the normal cap when the bonus is below 1× so glancing
    // exposure can't grant "extra" duration.
    float cap = FLASHBANG_MAX_BLINDNESS;
    if (angle_mult > 1)
        cap = FLASHBANG_MAX_BLINDNESS * angle_mult;

    csgren_flash_blindness = bound(0, csgren_flash_blindness + amount, cap);
    csgren_flash_last_time = cltime;
};

void(float volume) CSQC_UpdateFlashbangRing =
{
    float flags;

    // No SOUNDFLAG_ABSVOLUME — that flag bypasses the master `volume`
    // cvar, so muting the game still rang. Letting the engine apply
    // master + channel volume scales the ring naturally with the
    // user's settings (volume 0 → silent ring).
    flags = SOUNDFLAG_FORCELOOP | SOUNDFLAG_NOSPACIALISE;

    if (!csgren_flash_ring_ent)
    {
        csgren_flash_ring_ent = spawn();
        csgren_flash_ring_ent.classname = "csgren_flash_ring";
        csgren_flash_ring_ent.movetype = MOVETYPE_NONE;
        csgren_flash_ring_ent.solid = SOLID_NOT;
    }

    if (volume > 0.01)
    {
        if (!csgren_flash_ring_active)
        {
            sound(csgren_flash_ring_ent, CHAN_VOICE, FLASH_RING_SOUND, volume, ATTN_NONE, 100, flags);
            csgren_flash_ring_active = TRUE;
        }
        else
            soundupdate(csgren_flash_ring_ent, CHAN_VOICE, FLASH_RING_SOUND, volume, ATTN_NONE, 100, flags, 0);
    }
    else if (csgren_flash_ring_active)
    {
        sound(csgren_flash_ring_ent, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NONE);
        csgren_flash_ring_active = FALSE;
    }
};

void() CSQC_DrawFlashbangOverlay =
{
    float dt;
    float alpha;
    float volume;

    if (csgren_flash_last_time <= 0)
        csgren_flash_last_time = cltime;

    dt = cltime - csgren_flash_last_time;
    if (dt < 0) dt = 0;
    csgren_flash_last_time = cltime;

    if (csgren_flash_blindness > 0)
    {
        csgren_flash_blindness -= dt * FLASHBANG_DECAY_RATE;
        if (csgren_flash_blindness < 0)
            csgren_flash_blindness = 0;
    }

    alpha = bound(0, csgren_flash_blindness / 2, 1);
    volume = bound(0, csgren_flash_blindness / FLASHBANG_MAX_BLINDNESS, 1) * 0.7;
    CSQC_UpdateFlashbangRing(volume);

    if (alpha > 0)
        drawfill([0, 0, 0], [g_width, g_height, 0], '1 1 1', alpha, 0);
};

vector() CSQC_CSGrenadeSmokeRandomDir =
{
    vector dir;

    dir = [(random() * 2) - 1, (random() * 2) - 1, (random() * 0.7) - 0.15];
    if (vlen(dir) < 0.1)
        return '1 0 0';
    return normalize(dir);
};

void(vector pos) CSQC_SpawnSmokePuff =
{
    entity puff;
    vector dir;
    float spread;

    dir = CSQC_CSGrenadeSmokeRandomDir();
    spread = random() * 52;

    puff = spawn();
    puff.classname = "csgren_smoke_puff";
    setorigin(puff, pos + dir * spread + [0, 0, random() * 8]);
    puff.drawmask = 0;
    puff.csgren_smoke_next = csgren_smoke_list;
    csgren_smoke_list = puff;
    puff.csgren_smoke_spawn_time = cltime + random() * 3.6;
    puff.csgren_smoke_life = 11.0 + random() * 6.0;
    puff.csgren_smoke_start_size = 10 + random() * 12;
    puff.csgren_smoke_end_size = 58 + random() * 46;
    puff.csgren_smoke_drift = [(random() * 20) - 10,
                               (random() * 20) - 10,
                               3 + random() * 7];
    puff.csgren_smoke_phase = random() * 6.28;
    puff.csgren_smoke_colour = '0.62 0.64 0.64' + '1 1 1' * (random() * 0.12);
};

// Explosion smoke, as distinct from SMOKE-GRENADE smoke.
//
// env_explosion used to call CSQC_SpawnSmokePuff above, and that puff is tuned
// for a smoke grenade: it holds its spawn for up to 3.6 s and then lives 11-17 s,
// because a grenade's whole job is to sit there and deny a sightline for a round.
// Stacked on the emitter's 6 bursts x 0.5 s that put explosion smoke on screen for
// the better part of TWENTY SECONDS after the bang - "usually too long for
// whatever they were going for", and it is: nothing about a detonation wants a
// lingering cloud.  Half-Life's own explosion is one sprite plus a short puff.
//
// Same puff entity, same draw path, same colour ramp - only the TIMING differs, so
// this cannot change how a smoke grenade looks.  Deliberately a separate function
// rather than a parameter on the one above: the grenade's numbers are tuned and
// nobody editing an explosion should be able to reach them by accident.
//
// Rise is a little faster and the growth a little smaller: a puff that has ~2 s
// instead of ~14 to tell its story has to read as "kicked up and dissipated"
// rather than "settled in".
void(vector pos) CSQC_SpawnExplosionSmokePuff =
{
    entity puff;
    vector dir;
    float spread;

    dir = CSQC_CSGrenadeSmokeRandomDir();
    spread = random() * 34;

    puff = spawn();
    puff.classname = "csgren_smoke_puff";
    setorigin(puff, pos + dir * spread + [0, 0, random() * 8]);
    puff.drawmask = 0;
    puff.csgren_smoke_next = csgren_smoke_list;
    csgren_smoke_list = puff;
    // Near-immediate: a blast's smoke is there on the frame of the flash.
    puff.csgren_smoke_spawn_time = cltime + random() * 0.18;
    puff.csgren_smoke_life = 1.3 + random() * 0.9;
    puff.csgren_smoke_start_size = 8 + random() * 10;
    puff.csgren_smoke_end_size = 44 + random() * 30;
    puff.csgren_smoke_drift = [(random() * 26) - 13,
                               (random() * 26) - 13,
                               10 + random() * 12];
    puff.csgren_smoke_phase = random() * 6.28;
    puff.csgren_smoke_colour = '0.62 0.64 0.64' + '1 1 1' * (random() * 0.12);
};

void(vector pos) CSQC_SpawnSmokeCloud =
{
    float i;

    for (i = 0; i < 46; i = i + 1)
        CSQC_SpawnSmokePuff(pos);
};

void() CSQC_DrawSmokePuff =
{
    float age;
    float life;
    float frac;
    float fade_in;
    float fade_out;
    float alpha;
    float size;
    vector pos;
    vector right;
    vector up;

    age = cltime - self.csgren_smoke_spawn_time;
    if (age < 0)
        return;

    life = self.csgren_smoke_life;
    frac = bound(0, age / life, 1);
    fade_in = bound(0, age / 0.9, 1);
    fade_out = bound(0, (life - age) / 2.0, 1);
    alpha = min(fade_in, fade_out) * 0.78;
    if (alpha <= 0)
        return;

    size = self.csgren_smoke_start_size
         + (self.csgren_smoke_end_size - self.csgren_smoke_start_size) * (frac * frac * (3 - 2 * frac));
    pos = self.origin + self.csgren_smoke_drift * age;
    pos_x += sin(cltime * 0.9 + self.csgren_smoke_phase) * 3;
    pos_y += cos(cltime * 0.8 + self.csgren_smoke_phase) * 3;

    right = v_right * size;
    up = v_up * size;

    R_BeginPolygon("gfx/smoke", 1024, 0);
    R_PolygonVertex(pos - right - up, '0 1 0', self.csgren_smoke_colour, alpha);
    R_PolygonVertex(pos + right - up, '1 1 0', self.csgren_smoke_colour, alpha);
    R_PolygonVertex(pos + right + up, '1 0 0', self.csgren_smoke_colour, alpha);
    R_PolygonVertex(pos - right + up, '0 0 0', self.csgren_smoke_colour, alpha);
    R_EndPolygon();
};

// Translucent smoke quads can't self-sort per-fragment — the engine
// emits them in submission order with depth-write off, so a far puff
// drawn AFTER a near puff stomps the near one. Fix: gather alive puffs
// into a fixed-size buffer each frame, insertion-sort by squared
// distance to camera (descending = back-to-front), then draw in
// sorted order. ~200 puffs sorts in < 0.1 ms — trivial vs. the draw cost.
const float SMOKE_SORT_MAX = 256;
entity smoke_sort_ent[SMOKE_SORT_MAX];
float  smoke_sort_dsq[SMOKE_SORT_MAX];

void() CSQC_DrawSmokeClouds =
{
    entity puff;
    entity prev;
    entity next_puff;
    entity old_self;
    vector cam;
    vector dvec;
    float  count;
    float  i;
    float  j;
    entity ke;
    float  kd;

    old_self = self;
    makevectors(view_angles);
    cam = (vector)getproperty(VF_ORIGIN);

    // Pass 1 — walk list, free expired, gather visible puffs + dist².
    puff = csgren_smoke_list;
    prev = world;
    count = 0;
    while (puff)
    {
        next_puff = puff.csgren_smoke_next;
        if (cltime - puff.csgren_smoke_spawn_time > puff.csgren_smoke_life)
        {
            if (prev)
                prev.csgren_smoke_next = next_puff;
            else
                csgren_smoke_list = next_puff;
            remove(puff);
            puff = next_puff;
            continue;
        }

        // Skip puffs that haven't reached their staggered spawn yet —
        // CSQC_DrawSmokePuff would early-out anyway, no need to sort them.
        if (cltime >= puff.csgren_smoke_spawn_time && count < SMOKE_SORT_MAX)
        {
            dvec = puff.origin - cam;
            smoke_sort_ent[count] = puff;
            smoke_sort_dsq[count] = dvec * dvec;
            count = count + 1;
        }

        prev = puff;
        puff = next_puff;
    }

    // Pass 2 — insertion sort, descending dist² (far → near).
    // NOTE: fteqcc's `&&` does NOT short-circuit array indexing on the
    // RHS — `j >= 0 && arr[j] < kd` evaluates `arr[j]` even when j is
    // -1, triggering "Progs boundcheck failed. Value is -1." Split the
    // loop test so the index check happens before the array read.
    i = 1;
    while (i < count)
    {
        ke = smoke_sort_ent[i];
        kd = smoke_sort_dsq[i];
        j = i - 1;
        while (j >= 0)
        {
            if (smoke_sort_dsq[j] >= kd)
                break;
            smoke_sort_ent[j + 1] = smoke_sort_ent[j];
            smoke_sort_dsq[j + 1] = smoke_sort_dsq[j];
            j = j - 1;
        }
        smoke_sort_ent[j + 1] = ke;
        smoke_sort_dsq[j + 1] = kd;
        i = i + 1;
    }

    // Pass 3 — draw in sorted order so each puff blends correctly
    // over what's already in the framebuffer.
    i = 0;
    while (i < count)
    {
        self = smoke_sort_ent[i];
        CSQC_DrawSmokePuff();
        i = i + 1;
    }

    self = old_self;
};

void(float wep, vector pos, float snd_idx) CSQC_CSGrenadeExplodeFX =
{
    string snd;

    snd = CSGrenadeExplodeSound(wep, snd_idx);
    if (snd != "")
        pointsound(pos, snd, 1, ATTN_NORM);

    if (CSGrenadeIsExplosive(wep))
    {
        te_explosion(pos);
        CSQC_SpawnCSGrenadeSprite(pos, snd_idx);
        CSQC_AddExplosionLight(pos);
        CSQC_SpawnScorchDecal(pos, 1);
    }
    else if (wep == WEP_CSFLASHBANG)
    {
        // No detonation sprite — the white-flash overlay
        // (CSQC_ApplyFlashbang) and the explosion light already
        // communicate the flashbang going off, the sprite was just
        // visual noise on top of an already-blown-out screen.
        CSQC_AddExplosionLight(pos);
        CSQC_ApplyFlashbang(pos);
    }
    else if (wep == WEP_CSSMOKEGRENADE)
    {
        // Smoke grenade is gas-only — no flash/explosion sprite, only the
        // smoke cloud build-up.  HE still uses the sprite for its initial
        // detonation flash; flashbang skips it for the same reason as
        // smoke (its own overlay/effect carries the detonation read).
        // Spawn the cloud 16 qu BELOW the explode origin so the lower
        // portion of each puff hugs the floor without sinking the
        // visible mass into geometry.
        CSQC_SpawnSmokeCloud(pos - '0 0 16');
    }
};

void(float wep, float snd_idx, vector pos) CSQC_CSGrenadeBounceFX =
{
    string snd;

    snd = CSGrenadeBounceSound(wep, snd_idx);
    if (snd != "")
        pointsound(pos, snd, 1, ATTN_NORM);
};

float() CSQC_FakeCSGrenadePredraw =
{
    if (!self.csgren_resting
        && (self.flags & FL_ONGROUND)
        && vlen(self.velocity) < CSGREN_REST_SPEED)
        SH_CSGrenadeSettleModel();

    self.angles = self.angles + self.avelocity * frametime;
    addentity(self);
    return PREDRAW_NEXT;
};

void() CSQC_FakeCSGrenadeExplode =
{
    // Mirror the server's smoke-deploy gate (W_CSGrenadeProjectileTick).
    // The local shooter's predicted fake is otherwise the only thing
    // they see — if the fake pops mid-air on the fuse and the server
    // then deploys smoke late, the local player gets two cues at
    // different positions.  Polling at 50 ms here is fine; the
    // grenade is already at rest when this matters and we just need
    // to notice the rest state.
    if (self.weapon == WEP_CSSMOKEGRENADE && !self.csgren_resting)
    {
        self.nextthink = time + 0.05;
        return;
    }

    float snd_idx;
    vector pos;

    snd_idx = CSGrenadeRandomExplodeSample(self.weapon);
    pos = self.origin + '0 0 4';
    CSQC_CSGrenadeExplodeFX(self.weapon, pos, snd_idx);
    remove(self);
};

void() CSQC_FakeCSGrenadeBounce =
{
    float snd_idx;

    if (other == self.owner)
        return;
    if (other.entnum >= 1 && other.entnum <= maxclients)
        return;

    // Match the server-side bounce avelocity damp so the predicted
    // grenade's spin decays with each contact and lines up with the
    // server's view by the time the player is watching it settle.
    self.avelocity = self.avelocity * CSGREN_BOUNCE_AVEL_DAMP;

    if (time < self.csgren_next_bounce_sound)
        return;

    self.csgren_next_bounce_sound = time + 0.12;
    snd_idx = (random() < 0.5) ? 0 : 1;
    CSQC_CSGrenadeBounceFX(self.weapon, snd_idx, self.origin);
};

void() CSQC_SpawnFakeCSGrenade =
{
    entity gren;

    makevectors(input_angles);
    gren = spawn();
    gren.classname = "csqc_fake_csgrenade";   // findchain target on reset
    // Also stamp csqc_projectile_type so cl_throwtrail's iterator
    // picks it up (the iterator finds both classnames in the loop;
    // the type field is what drives eligibility).  csgren_throw_type
    // is the CS grenade subtype (HE / Flash / Smoke) — map to the
    // matching PROJ_TYPE_* constant so cl_throwtrail's eligibility
    // check works without a per-subtype filter.
    if (self.csgren_throw_type == WEP_CSFLASHBANG)
        gren.csqc_projectile_type = PROJ_TYPE_CSFLASHBANG;
    else if (self.csgren_throw_type == WEP_CSSMOKEGRENADE)
        gren.csqc_projectile_type = PROJ_TYPE_CSSMOKEGRENADE;
    else
        gren.csqc_projectile_type = PROJ_TYPE_CSHEGRENADE;
    setmodel(gren, CSGrenadeWorldModel(self.csgren_throw_type));
    setsize(gren, '-2 -2 -2', '2 2 2');
    // FTE's point-hull threshold is Quake's `size[0] < 3` (q1bsp.c:1554), not
    // GoldSrc's `size[0] <= 8`.  This bbox is 4 wide, so without the override
    // the grenade collides with the world as HL's 32x32x36 crouch hull
    // (hulls[3], gl_model.c:5564) offset by clip_mins - mins = (-14,-14,-16) —
    // it bounces off nothing visible up to 30 units short of walls, and the
    // bounce normals are wrong.  Same defect as the snark; see the long note in
    // sh_wpn_hlsnark.qc's W_SnarkSpawn.  1 == hulls[0] == the point hull.
    // Set on the CSQC-predicted copy too, or prediction disagrees with the
    // server about every wall the grenade meets.
    gren.hull = 1;
    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
    gren.owner = self;
    gren.weapon = self.csgren_throw_type;
    gren.frame = 0;
    gren.velocity = self.velocity
                  + v_forward * CSGREN_THROW_FORWARD
                  + v_up      * CSGREN_THROW_UPWARD;
    gren.avelocity = [(random() * 720) - 360,
                      (random() * 720) - 360,
                      (random() * 720) - 360];
    gren.movetype = MOVETYPE_BOUNCE;
    gren.solid = SOLID_BBOX;
    gren.gravity = CSGREN_GRAVITY;
    gren.bouncefactor = CSGREN_BOUNCEFACTOR;
    gren.drawmask = MASK_ENGINE;
    gren.touch = CSQC_FakeCSGrenadeBounce;
    gren.predraw = CSQC_FakeCSGrenadePredraw;
    gren.think = CSQC_FakeCSGrenadeExplode;
    gren.nextthink = time + CSGREN_FUSE_TIME;
};

float csqc_csgren_pin_played;
float csqc_csgren_pin_action;

void() CSQC_PredictCSGrenadeCommand =
{
    float r;
    float was_fire;

    if (predicted_player.wep_action_id != csqc_csgren_pin_action)
    {
        csqc_csgren_pin_action = predicted_player.wep_action_id;
        csqc_csgren_pin_played = FALSE;
    }

    if (input_buttons & 1)
    {
        r = SH_CSGrenadeTryPinPull(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Sound deferred to the model's own mark — see W_CSGrenadeFire.
            csqc_csgren_pin_played = FALSE;
            csqc_csgren_pin_action = predicted_player.wep_action_id;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted pin sound, on the model's own mark inside the pull-pin take.
    if (self.weaponstate == WS_SPECIAL && !csqc_csgren_pin_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start
            >= SH_CSGrenPullpinDuration(self.weapon) * SH_CSGrenPinFrac(self.weapon))
        {
            localsound(CSGrenadePinSound(self.weapon));
            CSQC_RecordPredictedWeaponSound();
            csqc_csgren_pin_played = TRUE;
        }
    }

    if (self.weaponstate == WS_SPECIAL && !(input_buttons & 1))
    {
        // A tap that beats the pin mark still owes the pin sound — mirrors the
        // server's arm in W_CSGrenadeFrame.  Emitted BEFORE the throw so the order
        // is pin-then-throw whichever path got there first.
        if (!csqc_csgren_pin_played && !pm_suppress_sounds)
        {
            localsound(CSGrenadePinSound(self.weapon));
            CSQC_RecordPredictedWeaponSound();
            csqc_csgren_pin_played = TRUE;
        }
        if (SH_CSGrenadeThrow(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            self.csgren_throw_pending = 1;
            self.csgren_spawn_time = csqc_pred_time + CSGREN_THROW_DELAY;
        }
    }

    if (self.weaponstate == WS_FIRE
        && self.csgren_throw_pending > 0
        && csqc_pred_time >= self.csgren_spawn_time
        && !pm_suppress_sounds
        && self.csgren_fake_spawned_serial != self.wep_action_id)
    {
        self.csgren_throw_pending = 0;
        self.csgren_fake_spawned_serial = self.wep_action_id;
        CSQC_SpawnFakeCSGrenade();
    }

    was_fire = (self.weaponstate == WS_FIRE);
    SH_CSGrenadeTickState(csqc_pred_time);

    if (was_fire && self.weaponstate == WS_IDLE
        && CSGrenadeEntityAmmo(self, self.weapon) <= 0
        && self.weapon == self.csgren_throw_type)
    {
        if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
        else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
        else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
        else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
    }
};

float(float elapsed) CSQC_CSGrenadeDisplayFrame =
{
    float wep = predicted_player.weapon;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSGrenSeqDeploy(wep);
    if (predicted_player.weaponstate == WS_SPECIAL)
        // WS_SPECIAL IS THE HELD-PIN STATE, not the pulling of it: the pin comes
        // out at the start and the player then stands there cooking it until
        // they release.  So this is where the DoD models' exploding_pinpull
        // belongs — a hand holding a live grenade with the lever down.
        return SH_CSGrenSeqPullpin(wep, TRUE);
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Two-phase WS_FIRE display (see SH_CSGrenadeTickState):
        //   [0, THROW_DURATION)              → THROW seq (release)
        //   [THROW_DURATION, +DEPLOY_DURATION) → DEPLOY seq (re-arm)
        // sequence_time_override resets the deploy-anim playhead to 0
        // so it doesn't pick up mid-anim — same pattern as snowball.
        // The deploy phase only renders when ammo > 0 (the tick state
        // exits WS_FIRE early on the last grenade).
        // The take that is playing belongs to the grenade that was THROWN, which
        // on the last one is no longer predicted_player.weapon.
        float thrown = predicted_player.csgren_throw_type;
        if (!thrown) thrown = wep;

        float phase = SH_CSGrenThrowPhase(thrown);
        if (elapsed >= phase)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = max(0, elapsed - phase);
            return SH_CSGrenSeqDeploy(wep);
        }
        return SH_CSGrenSeqThrow(thrown, TRUE);
    }
    return SH_CSGrenSeqIdle(wep);
};

void() CSQC_CSGrenadeDropClear =
{
    CSGrenadeSetEntityAmmo(self, self.weapon, 0);
};

void(float wep) CSQC_CSGrenadeEquipCommon =
{
    self.weapon_name = CSGrenadeDisplayName(wep);
    self.weapon_viewmodel = CSGrenadeViewModel(wep);
    self.weapon_worldmodel = CSGrenadeWorldModel(wep);
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd = CSQC_PredictCSGrenadeCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame = CSQC_CSGrenadeDisplayFrame;
    self.csqc_drop_clear = CSQC_CSGrenadeDropClear;
    self.weapon_uses_sequences = TRUE;
    // FLIPPED, because the model under these three constants changed.  The
    // old value here was FALSE and its justification was "100% of verts at
    // negative Y (HE -29.56, flash/smoke -29.34)" — a measurement of the
    // mod-local high-poly replacements that are no longer what gets loaded.
    //
    // That test does not actually decide handedness, and measuring the rest of
    // the roster the same way proves it: the CrossFire viewmodels are ALSO
    // 100% negative-Y (v_mp5 -3.05, v_m4 -5.86) and every one of them sets
    // flip TRUE, while wpn_csusp's is -31.14 and sets FALSE.  Where the mesh
    // sits along Y says nothing about which arm was modelled.
    //
    // Counter-Strike's own v_hegrenade / v_flashbang / v_smokegrenade (438
    // verts each, meanY -18.63, identical arm mesh across all three) are
    // authored left-handed and are reported as such in game, so they are
    // mirrored here the same way the 32 CrossFire weapons are.  RF_XFLIP also
    // inverts the cull winding, so backfaces stay hidden.
    //
    // cl_lefthand XORs against this, so a player who wants them the other way
    // round still can; and reverting is this one word.
    //
    // THE TWO DAY OF DEFEAT GRENADES ARE THE EXCEPTION — see below.  They ride
    // this common equip for everything else, so the flip is corrected after the
    // call rather than by forking the whole function.
    self.weapon_viewmodel_flip = TRUE;
};

void() CSQC_CSHEGrenadeEquip = { CSQC_CSGrenadeEquipCommon(WEP_CSHEGRENADE); };
void() CSQC_CSFlashbangEquip = { CSQC_CSGrenadeEquipCommon(WEP_CSFLASHBANG); };
void() CSQC_CSSmokeGrenadeEquip = { CSQC_CSGrenadeEquipCommon(WEP_CSSMOKEGRENADE); };

// NOT flipped.  models/v_mills.mdl and models/v_stick.mdl come from the mounted
// Day of Defeat gamedir, not from cstrike, and DoD authored its viewmodels the
// opposite way round from Counter-Strike's — every one of the other 24 DoD
// weapons in this tree leaves weapon_viewmodel_flip at its FALSE default and
// none of them has ever been reported wrong.  These two were the only DoD
// weapons routed through a Counter-Strike equip, so they inherited a flip that
// belongs to the three CS grenades above and came out left-handed.
//
// The stick was the one reported; the Mills bomb is the same model set from the
// same mount through the same call, so it is corrected with it rather than left
// to be reported separately.
void() CSQC_DodMillsEquip =
{
    CSQC_CSGrenadeEquipCommon(WEP_DODMILLS);
    self.weapon_viewmodel_flip = FALSE;
};
void() CSQC_DodStickEquip =
{
    CSQC_CSGrenadeEquipCommon(WEP_DODSTICK);
    self.weapon_viewmodel_flip = FALSE;
};

#endif // CSQC
