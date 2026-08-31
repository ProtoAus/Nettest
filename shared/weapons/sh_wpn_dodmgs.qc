// ============================================================
//  shared/weapons/sh_wpn_dodmgs.qc  -  Day of Defeat machine guns, all three
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : belt-fed, full-auto, huge magazines and punishing spread
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none (see THE BIPOD, below)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THESE — v_/w_ come from the mounted dod gamedir, and the
//  player models are the "bipod up" variants (p_mg34bu, p_mg42bu) because that
//  is the pose this mod actually puts the gun in; see below.
//
//  MEASURED, and the three are NOT the same shape on disk:
//
//    dod/models/v_30cal.mdl   59 seqs, 66 bones   M1919A6 .30 cal
//    dod/models/v_mg42.mdl    59 seqs, 63 bones   MG42
//    dod/models/v_mg34.mdl    13 seqs, 62 bones   MG34
//
//  THE 59-SEQUENCE PAIR CARRY A VISIBLE BELT, AND IT IS WIRED NOW.  Their idles,
//  transitions and shoot takes each exist TEN times over — `upidle`, `upidle8`,
//  `upidle7` ... `upidle1`, `upidleempty` — one per remaining-belt bracket, so
//  the ammunition hanging off the side of the gun shrinks as you fire.
//  SH_DodMGBeltSuffix is the bracket->suffix map, and every sequence accessor
//  below goes through SH_SeqForName2 so a model that lacks the suffixed take
//  falls back to the base name rather than to an index that means something else.
//
//    >8 rounds   ""        the full belt
//    8..1        "8".."1"  one take per round
//    0           "empty"   the feed tray bare
//
//  The MG34 spells its bracket differently and only has one: `_empty`, with an
//  underscore, against the belt pair's un-underscored `empty`.  Same function,
//  one branch — which is why this is not a shared helper across DoD.
//
//  THE BIPOD IS WIRED, and it is a real movement stance.  All three models carry
//  a full `down_*` set — deployed idle, deployed shoot, and the `uptodown` /
//  `downtoup` transitions between them, each of those in all ten belt brackets on
//  the 59-sequence pair.
//
//  +attack2 AND weapon-special (impulse 7) both plant the gun, and you have to be
//  CROUCHED to plant.  Both buttons, because the Bren and the two FG42s have only
//  ever been on impulse 7 (their +attack2 is the ADS hold) and these five bound no
//  .special at all — "none of the machine guns up_to_down work? I try weapon
//  special and nothing?".  While planted the player is held crouched and pinned:
//  the shared .wep_deployed flag
//  (sh_weapons.qc) locks movement to zero through SH_DeploySpeedFactor, exactly
//  as it does for the mortar, and the reward for standing still is a much tighter
//  cone — DODMG_DEPLOY_SPREAD_SCALE.  The old note here said wiring `downshoot`
//  without a movement framework "would hand out the accuracy benefit of a bipod
//  with none of its cost"; the framework now exists, so the cost is real.
//
//    UP IS THE HIPFIRE SET AND DOWN IS THE DEPLOYED ONE, not the other way
//    round: `uptodown` is the gun going DOWN onto its bipod.  Confirmed against
//    v_bar.mdl, whose `up_to_down` carries a tommy_reload_clipin event at the
//    point the bipod legs clack open.
//
//  THERE IS NO `draw` SEQUENCE IN ANY OF THE THREE.  DoD never selects these
//  from a holster — it starts you holding one — so the deploy animation here is
//  `downtoup`, the gun coming up off the ground, which is exactly what drawing
//  one looks like.  The fallbacks below name it as such.  It doubles as the
//  stand-up take, which is what it depicts either way.
//
//  RELOAD EVENTS, read out of each model and different in all three:
//    30cal  reload 20fps 121f 6.050s
//       f1   chainpull.wav    0.008     f28  clampdown.wav   0.231
//       f41  bulletchain.wav  0.339     f85  clampdown.wav   0.702
//       f104 mgbolt.wav       0.860
//    mg42   reload 20fps 139f 6.950s
//       f1   chainpull.wav    0.007     f37  bulletchain.wav 0.266
//       f100 clampdown.wav    0.719     f110 mgbolt.wav      0.791
//    mg34   reload 29fps 166f 5.724s   <- BOX fed, so a clipout/clipin pair
//       f44  tommy_reload_clipout.wav 0.265
//       f120 tommy_reload_clipin.wav  0.723
//       f127 clampdown.wav            0.765
//       f150 mgbolt.wav               0.904

// --- Ammo fields ---
.float mag_dod30cal;
.float ammo_dod30cal;
.float mag_dodmg34;
.float ammo_dodmg34;
.float mag_dodmg42;
.float ammo_dodmg42;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
// Taken from v_30cal.mdl / v_mg42.mdl, which share a layout.  The MG34's differ
// and are reached by NAME, so the fallbacks are only ever used if a mount ships
// a model with none of these labels at all.
const float DODMG_SEQ_UPIDLE   = 0;
const float DODMG_SEQ_DOWNIDLE = 10;
const float DODMG_SEQ_DOWNTOUP = 20;
const float DODMG_SEQ_UPTODOWN = 30;
const float DODMG_SEQ_UPSHOOT  = 40;
const float DODMG_SEQ_DOWNSHOOT = 49;
const float DODMG_SEQ_RELOAD   = 58;

const float DODMG_FRAME_INTERVAL = 0.0333334;
const float DODMG_DRYFIRE_DELAY  = 0.25;

// Spread multiplier while the gun is on its bipod.  A machine gun firing off a
// mount is the steadiest thing in the game and this is what pays for the
// movement lock; 0.35 keeps it well inside a rifle's cone without making it a
// sniper at range, where DODMG_DAMAGE_FALLOFF_RANGE is doing the limiting.
const float DODMG_DEPLOY_SPREAD_SCALE = 0.35;

const float DODMG_IDLE_REARM_MIN = 10;
const float DODMG_IDLE_REARM_MAX = 15;

.float dodmg_snd_stage;

// ============================================================
//  SHARED — per-weapon table
// ============================================================

string(float wep) SH_DodMGViewModel =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return "models/v_30cal.mdl";
    case WEP_DODMG34:  return "models/v_mg34.mdl";
    case WEP_DODMG42:  return "models/v_mg42.mdl";
    }
    return "models/v_30cal.mdl";
};

string(float wep) SH_DodMGWorldModel =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return "models/w_30cal.mdl";
    case WEP_DODMG34:  return "models/w_mg34.mdl";
    case WEP_DODMG42:  return "models/w_mg42.mdl";
    }
    return "models/w_30cal.mdl";
};

string(float wep) SH_DodMGDisplayName =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return ".30 CAL";
    case WEP_DODMG34:  return "MG34";
    case WEP_DODMG42:  return "MG42";
    }
    return ".30 CAL";
};

string(float wep) SH_DodMGClassname =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return "weapon_30cal";
    case WEP_DODMG34:  return "weapon_mg34";
    case WEP_DODMG42:  return "weapon_mg42";
    }
    return "weapon_30cal";
};

string(float wep) SH_DodMGFireSound =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return "weapons/30cal_shoot.wav";
    case WEP_DODMG34:  return "weapons/mg34_shoot.wav";
    case WEP_DODMG42:  return "weapons/mg42_shoot.wav";
    }
    return "weapons/30cal_shoot.wav";
};

// --- Balance ---
//
// RATE OF FIRE IS THE WHOLE IDENTITY OF THIS TRIO and the real guns differ by
// more than two to one, so that is where the numbers come from rather than from
// a spreadsheet.  The MG42's 1200 rpm buzzsaw is the single most recognisable
// thing about it and it would be absurd to flatten it:
//
//   .30 cal  ~500 rpm -> 0.120 s   heaviest round, steadiest, 100-round belt
//   MG34     ~900 rpm -> 0.067 s   the middle of the three in every respect
//   MG42    ~1200 rpm -> 0.050 s   fastest, loosest, and eats its belt
//
// Damage is deliberately FLAT across the three at 26/16 — these are all firing
// full-power rifle rounds, and letting the fastest gun also hit hardest would
// make the other two pointless.  The MG42 pays for its rate with the worst
// spread of the set and a magazine that lasts 2.5 seconds held down.
//
// All three sit ABOVE the BAR (which this tree gives 34 at 20 rounds) on volume
// and BELOW it per bullet, which is the correct relationship between an
// automatic rifle and a belt-fed machine gun.
float(float wep) SH_DodMGFireDelay =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return 0.120;
    case WEP_DODMG34:  return 0.067;
    case WEP_DODMG42:  return 0.050;
    }
    return 0.120;
};

float(float wep) SH_DodMGMaxMag =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return 100;
    case WEP_DODMG34:  return 50;
    case WEP_DODMG42:  return 50;
    }
    return 100;
};

float(float wep) SH_DodMGMaxAmmo =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return 200;
    case WEP_DODMG34:  return 150;
    case WEP_DODMG42:  return 150;
    }
    return 200;
};

// Standing spread.  Hipfiring a machine gun should be bad — that is what the
// bipod is FOR, and now that it is wired the cost is paid rather than assumed.
float(float wep) SH_DodMGBaseSpread =
{
    switch (wep)
    {
    case WEP_DOD30CAL: return 0.055;
    case WEP_DODMG34:  return 0.062;
    case WEP_DODMG42:  return 0.072;
    }
    return 0.055;
};

// The LIVE spread — base, scaled by the bipod.  Every shot path goes through
// this; SH_DodMGBaseSpread stays the standing number so the crosshair profile and
// the balance comment above still read as one value per gun.
float(float wep) SH_DodMGSpread =
{
    if (self.wep_deployed)
        return SH_DodMGBaseSpread(wep) * DODMG_DEPLOY_SPREAD_SCALE;
    return SH_DodMGBaseSpread(wep);
};

const float DODMG_MOVE_SPREAD          = 0.150;
const float DODMG_FULL_SPREAD_SPEED    = 260;
const float DODMG_CLOSE_DAMAGE         = 26;
const float DODMG_MIN_DAMAGE           = 16;
const float DODMG_DAMAGE_FALLOFF_RANGE = 3000;
const float DODMG_KICK_PITCH    = 0.55;
const float DODMG_KICK_VARIANCE = 0.35;
const float DODMG_KICK_STRENGTH = 0.75;

const float DODMG_MUZZLE_FORWARD = 46;
const float DODMG_MUZZLE_RIGHT   = 4;
const float DODMG_MUZZLE_DOWN    = 3;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

// THE BELT BRACKET.  The suffix the model appends to a base name for the number
// of rounds still on the belt — see the header.  Returns "" for a full belt,
// which makes every accessor below "try the suffixed take, else the base one".
//
// The MG34 is the branch: it carries ONE bracket and spells it `_empty` with an
// underscore, where the 59-sequence pair spell theirs `empty` with none.
string(float wep, float mag) SH_DodMGBeltSuffix =
{
    if (wep == WEP_DODMG34)
        return (mag <= 0) ? "_empty" : "";
    if (mag <= 0) return "empty";
    if (mag > 8)  return "";
    return ftos(mag);
};

// Every accessor takes the magazine and the stance as PARAMETERS rather than
// reading self, because the CSQC display path runs with self set to the viewmodel
// entity and has to pass predicted_player's copies in.
//
// SH_SeqForName2(model, first, second, fallback) is doing the load-bearing work:
// the suffixed name first, the base name if the model has no such variant, and
// only then an index.  A model without the belt set therefore behaves exactly as
// it did before this change rather than landing on an unrelated sequence.
float(float wep, float mag, float deployed) SH_DodMGSeqIdle =
{
    string m = SH_DodMGViewModel(wep);
    if (deployed)
        return SH_SeqForName2(m, strcat("downidle", SH_DodMGBeltSuffix(wep, mag)),
                              "downidle", DODMG_SEQ_DOWNIDLE);
    return SH_SeqForName2(m, strcat("upidle", SH_DodMGBeltSuffix(wep, mag)),
                          "upidle", DODMG_SEQ_UPIDLE);
};

// THE SHOOT TAKE HAS NO `empty` BRACKET on the 59-sequence pair.  The artist
// shipped upshoot + upshoot8..upshoot1 and downshoot + downshoot8..downshoot1 and
// stopped there; only the idle and the two transitions got an `empty`.
//
// That matters because W_DodMGFire reads the magazine AFTER the decrement, so the
// shot that empties the belt asks for "upshootempty", misses, and used to fall
// through to the bare "upshoot" — which is the FULL belt.  The last round of a
// belt was therefore fired with a full one draped over the gun, a visible flash of
// ammunition that is not there.  The emptiest bracket that DOES exist is the right
// degrade, so an empty belt asks for the 1-round take second.
//
// The MG34 needs none of this: it really does carry upshoot_empty / downshoot_empty
// (sequences 11 and 5), and SH_DodMGBeltSuffix's first branch already hands it the
// right name.
float(float wep, float mag, float deployed) SH_DodMGSeqShoot =
{
    string m    = SH_DodMGViewModel(wep);
    string base = deployed ? "downshoot" : "upshoot";
    string second = base;

    if (wep != WEP_DODMG34 && mag <= 0)
        second = strcat(base, "1");

    return SH_SeqForName2(m, strcat(base, SH_DodMGBeltSuffix(wep, mag)), second,
                          deployed ? DODMG_SEQ_DOWNSHOOT : DODMG_SEQ_UPSHOOT);
};

float(float wep) SH_DodMGSeqReload =
{ return SH_SeqForName(SH_DodMGViewModel(wep), "reload", DODMG_SEQ_RELOAD); };

// The two stance transitions, both belt-bracketed as well.  `downtoup` is the gun
// coming UP off its bipod, `uptodown` is it going down onto it.
float(float wep, float mag) SH_DodMGSeqStandUp =
{
    string m = SH_DodMGViewModel(wep);
    return SH_SeqForName2(m, strcat("downtoup", SH_DodMGBeltSuffix(wep, mag)),
                          "downtoup", DODMG_SEQ_DOWNTOUP);
};

float(float wep, float mag) SH_DodMGSeqPlant =
{
    string m = SH_DodMGViewModel(wep);
    return SH_SeqForName2(m, strcat("uptodown", SH_DodMGBeltSuffix(wep, mag)),
                          "uptodown", DODMG_SEQ_UPTODOWN);
};

// The take that plays for a stance change is the one LEAVING the current stance,
// because .wep_deployed does not flip until the take ends.
float(float wep, float mag, float deployed) SH_DodMGSeqStance =
{
    return deployed ? SH_DodMGSeqStandUp(wep, mag) : SH_DodMGSeqPlant(wep, mag);
};

// The deploy — see "THERE IS NO draw SEQUENCE" in the header; the gun comes up off
// the ground, so `downtoup` IS the draw.
//
// IT TAKES THE BELT BRACKET.  It used to hardcode the base name, justified by "the
// bracket takes are frame-identical apart from the belt mesh" — which is the exact
// reason it was wrong, because the belt mesh is the only thing being looked at.
// Drawing a .30 cal with three rounds left showed a completely full belt for the
// whole 1.2 s and then emptied it the instant the idle took over.  Every bracket is
// the same length on all three models, so this costs no timing change.
float(float wep, float mag) SH_DodMGSeqDraw =
{
    return SH_SeqForName2(SH_DodMGViewModel(wep),
                          strcat("downtoup", SH_DodMGBeltSuffix(wep, mag)),
                          "downtoup", DODMG_SEQ_DOWNTOUP);
};

float(float wep, float mag) SH_DodMGDrawDuration =
{ return SH_SeqDuration(SH_DodMGViewModel(wep), SH_DodMGSeqDraw(wep, mag), 1.240); };

float(float wep) SH_DodMGReloadDuration =
{ return SH_SeqDuration(SH_DodMGViewModel(wep), SH_DodMGSeqReload(wep), 6.050); };

// Both transitions are the same length in every bracket on all three models, so
// one duration per direction serves the whole set.
float(float wep, float mag) SH_DodMGPlantDuration =
{ return SH_SeqDuration(SH_DodMGViewModel(wep), SH_DodMGSeqPlant(wep, mag), 1.000); };

float(float wep, float mag) SH_DodMGStandUpDuration =
{ return SH_SeqDuration(SH_DodMGViewModel(wep), SH_DodMGSeqStandUp(wep, mag), 1.200); };

float(float wep, float mag, float deployed) SH_DodMGStanceDuration =
{
    return deployed ? SH_DodMGStandUpDuration(wep, mag) : SH_DodMGPlantDuration(wep, mag);
};

// ============================================================
//  SHARED — state machine
// ============================================================

// The rounds land at the very END of the reload.  These are the longest reloads
// in the game (5.7 s to 7.0 s) and every one of them ends on `mgbolt.wav`, the
// bolt being cycled onto the fresh belt — before that the gun genuinely is not
// loaded, so applying early would be wrong as well as generous.
// Read the live magazine without duplicating the switch at every call site.
// Defined up here rather than below the try-gates, because the stance helpers
// need it too.
float(entity e) SH_DodMGMag =
{
    switch (e.weapon)
    {
    case WEP_DODMG34: return e.mag_dodmg34;
    case WEP_DODMG42: return e.mag_dodmg42;
    }
    return e.mag_dod30cal;
};

// +attack2 plants the gun on its bipod, or picks it back up.  Same shape as the
// mortar's SH_DodMortarTryStance and the shield's SH_ShieldToggle: both sides run
// it, the flag flips when the take ends, and the proxy reconciles it.
float(float now) SH_DodMGTryStance =
{
    // RISING EDGE — see SH_StanceAltEdge in sh_weapons.qc.  A held +attack2 would
    // otherwise re-toggle the frame after the bipod take ends, flapping the gun on
    // and off its legs for as long as the key is down.
    if (!SH_StanceAltEdge(TRUE)) return FALSE;

    if (Weapon_LowerBlocksFire()) return FALSE;
    // CROUCH TO PLANT.  Same gate and same reasoning as the mortar's — see
    // SH_DodMortarTryStance.  Both sides read the replicated FL_DUCKING, so it is
    // prediction-exact; the !wep_deployed guard keeps standing back up free.
    if (!self.wep_deployed
        && !((self.flags & FL_DUCKING) && (self.flags & FL_ONGROUND)))
        return FALSE;
    // Not mid-draw, mid-reload or already changing stance — a six-second belt
    // change and a bipod are competing for the same two hands.
    if (self.weaponstate != WS_IDLE) return FALSE;
    if (now < self.attack_finished)  return FALSE;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SH_DodMGStanceDuration(self.weapon, SH_DodMGMag(self),
                                                        self.wep_deployed);
    return TRUE;
};

float(float now) SH_DodMGTickState =
{
    float wep = self.weapon;

    // WS_SPECIAL is the plant / stand-up take.  Handled before the standard
    // driver, which has no arm for it and would leave the player frozen in an
    // animation that never ends.
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodMGStanceDuration(wep, SH_DodMGMag(self), self.wep_deployed))
        {
            self.wep_deployed = !self.wep_deployed;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_DodMGReloadDuration(wep);
    float dr  = SH_DodMGDrawDuration(wep, SH_DodMGMag(self));
    float fd  = SH_DodMGFireDelay(wep);

    switch (wep)
    {
    case WEP_DODMG34:
        return SH_StandardTickState(now, mag_dodmg34, ammo_dodmg34, SH_DodMGMaxMag(wep),
                                    dr, fd, rel, rel);
    case WEP_DODMG42:
        return SH_StandardTickState(now, mag_dodmg42, ammo_dodmg42, SH_DodMGMaxMag(wep),
                                    dr, fd, rel, rel);
    }
    return SH_StandardTickState(now, mag_dod30cal, ammo_dod30cal, SH_DodMGMaxMag(wep),
                                dr, fd, rel, rel);
};

// FULL AUTO — SH_StandardTryFire, not the SemiAuto wrapper.  A machine gun that
// needed a trigger pull per round would be a worse rifle.
float(float now) SH_DodMGTryFire =
{
    float wep = self.weapon;
    float fd  = SH_DodMGFireDelay(wep);

    switch (wep)
    {
    case WEP_DODMG34: return SH_StandardTryFire(now, mag_dodmg34,  fd, DODMG_DRYFIRE_DELAY);
    case WEP_DODMG42: return SH_StandardTryFire(now, mag_dodmg42,  fd, DODMG_DRYFIRE_DELAY);
    }
    return SH_StandardTryFire(now, mag_dod30cal, fd, DODMG_DRYFIRE_DELAY);
};

float(float now) SH_DodMGTryReload =
{
    float wep = self.weapon;
    float rel = SH_DodMGReloadDuration(wep);

    switch (wep)
    {
    case WEP_DODMG34:
        return SH_StandardTryReload(now, mag_dodmg34, ammo_dodmg34, SH_DodMGMaxMag(wep), rel);
    case WEP_DODMG42:
        return SH_StandardTryReload(now, mag_dodmg42, ammo_dodmg42, SH_DodMGMaxMag(wep), rel);
    }
    return SH_StandardTryReload(now, mag_dod30cal, ammo_dod30cal, SH_DodMGMaxMag(wep), rel);
};

// ============================================================
//  SHARED — reload audio schedule
// ============================================================
//
// Returns the FRACTION of the reload at which stage `n` (1..5) fires, or -1 when
// that weapon has no stage n.  One table rather than three copies of the same
// if-ladder in six places (server frame, client predict).
float(float wep, float n) SH_DodMGReloadStageFrac =
{
    if (wep == WEP_DODMG34)
    {
        if (n == 1) return 0.265;   // tommy_reload_clipout
        if (n == 2) return 0.723;   // tommy_reload_clipin
        if (n == 3) return 0.765;   // clampdown
        if (n == 4) return 0.904;   // mgbolt
        return -1;
    }
    if (wep == WEP_DODMG42)
    {
        if (n == 1) return 0.007;   // chainpull
        if (n == 2) return 0.266;   // bulletchain
        if (n == 3) return 0.719;   // clampdown
        if (n == 4) return 0.791;   // mgbolt
        return -1;
    }
    // .30 cal — five stages, the only one with two clampdowns
    if (n == 1) return 0.008;       // chainpull
    if (n == 2) return 0.231;       // clampdown
    if (n == 3) return 0.339;       // bulletchain
    if (n == 4) return 0.702;       // clampdown
    if (n == 5) return 0.860;       // mgbolt
    return -1;
};

string(float wep, float n) SH_DodMGReloadStageSound =
{
    if (wep == WEP_DODMG34)
    {
        if (n == 1) return "weapons/tommy_reload_clipout.wav";
        if (n == 2) return "weapons/tommy_reload_clipin.wav";
        if (n == 3) return "weapons/clampdown.wav";
        if (n == 4) return "weapons/mgbolt.wav";
        return "";
    }
    if (wep == WEP_DODMG42)
    {
        if (n == 1) return "weapons/chainpull.wav";
        if (n == 2) return "weapons/bulletchain.wav";
        if (n == 3) return "weapons/clampdown.wav";
        if (n == 4) return "weapons/mgbolt.wav";
        return "";
    }
    if (n == 1) return "weapons/chainpull.wav";
    if (n == 2) return "weapons/clampdown.wav";
    if (n == 3) return "weapons/bulletchain.wav";
    if (n == 4) return "weapons/clampdown.wav";
    if (n == 5) return "weapons/mgbolt.wav";
    return "";
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodMGPickupCopy =
{
    player.mag_dod30cal  = self.mag_dod30cal;
    player.ammo_dod30cal = self.ammo_dod30cal;
    player.mag_dodmg34   = self.mag_dodmg34;
    player.ammo_dodmg34  = self.ammo_dodmg34;
    player.mag_dodmg42   = self.mag_dodmg42;
    player.ammo_dodmg42  = self.ammo_dodmg42;
};

void() W_DodMGShoot =
{
    float wep = self.weapon;
    W_PenetratingHitscanShoot(SH_DodMGSpread(wep), DODMG_MOVE_SPREAD, DODMG_FULL_SPREAD_SPEED,
        DODMG_CLOSE_DAMAGE, DODMG_MIN_DAMAGE, DODMG_DAMAGE_FALLOFF_RANGE, 40, 0.92,
        DODMG_KICK_PITCH, DODMG_KICK_VARIANCE, DODMG_KICK_STRENGTH);
};

// +attack2 — plant on the bipod, or pick the gun back up.
// Button-up half of the rising-edge latch; sv_weapons.qc calls .altrelease every
// frame the button is up, which is exactly the clearing edge needed.
void() W_DodMGAltRelease =
{
    SH_StanceAltEdge(FALSE);
};

void() W_DodMGAltFire =
{
    if (SH_DodMGTryStance(time))
    {
        self.weaponframe     = SH_DodMGSeqStance(self.weapon, SH_DodMGMag(self), self.wep_deployed);
        self.wep_nextframe   = time + DODMG_FRAME_INTERVAL;
        self.dodmg_snd_stage = 0;
    }
};

// SECOND ENTRY POINT: weapon-special (impulse 7) plants the bipod too.  These
// three bound only .altfire, so impulse 7 reached W_CheckImpulses, found .special
// unset and returned — "none of the machine guns up_to_down work? I try weapon
// special and nothing?".  The Bren and both FG42s have always been on impulse 7
// (their +attack2 is the ADS hold), so weapon-special is the rule a player learns
// first; both buttons work on all six deployables now.
void() W_DodMGSpecial =
{
    SH_StanceAltArmForImpulse();
    W_DodMGAltFire();
};

void() W_DodMGFire =
{
    float r = SH_DodMGTryFire(time);

    if (r == 1)
    {
        // Read the magazine AFTER the shot — the belt take that plays is the one
        // for the rounds still on it, and the round just fired has gone.
        self.weaponframe    = SH_DodMGSeqShoot(self.weapon, SH_DodMGMag(self), self.wep_deployed);
        self.wep_nextframe  = time + DODMG_FRAME_INTERVAL;

        W_DodMGShoot();

        sound(self, CHAN_WEAPON, SH_DodMGFireSound(self.weapon), 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodMGReload =
{
    if (SH_DodMGTryReload(time))
    {
        self.weaponframe     = SH_DodMGSeqReload(self.weapon);
        self.wep_nextframe   = time + DODMG_FRAME_INTERVAL;
        self.dodmg_snd_stage = 0;
    }
};

void() W_DodMGFrame =
{
    float wep     = self.weapon;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODMG_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodMGReloadDuration(wep);
        float n;
        for (n = 1; n <= 5; n = n + 1)
        {
            float f = SH_DodMGReloadStageFrac(wep, n);
            if (f < 0)
                break;
            if (elapsed >= rel * f && self.dodmg_snd_stage < n)
            {
                sound(self, CHAN_AUTO, SH_DodMGReloadStageSound(wep, n), 1, ATTN_NORM);
                self.dodmg_snd_stage = n;
            }
        }
    }

    float result = SH_DodMGTickState(time);
    if (result & 1)
    {
        // wep_deployed may have just flipped inside the tick, so it is re-read
        // rather than cached at the top of the frame.
        self.weaponframe     = SH_DodMGSeqIdle(wep, SH_DodMGMag(self), self.wep_deployed);
        self.wep_nextframe   = 0;
        self.dodmg_snd_stage = 0;
    }
};

void() W_DodMGEquip =
{
    float wep = self.weapon;
    W_SetADSProfile(TRUE, "cl_ads_dodmg", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(SH_DodMGViewModel(wep), SH_DodMGDisplayName(wep),
        SH_DodMGSeqDraw(wep, SH_DodMGMag(self)),
        DODMG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodMGFire;
    self.altfire    = W_DodMGAltFire;      // plant / pick up
    self.altrelease = W_DodMGAltRelease;   // clears the rising-edge latch
    self.special    = W_DodMGSpecial;      // impulse 7 does the same thing
    self.wep_stance_alt_held = 0;
    self.reload   = W_DodMGReload;
    self.wepframe = W_DodMGFrame;
    self.shoot    = W_DodMGShoot;
    self.dodmg_snd_stage = 0;
    // ALWAYS COMES OUT STANDING — the draw take (`downtoup`) is the gun coming up
    // off the ground, so drawing one already ends in the standing pose.  A weapon
    // that remembered being planted would also hand the player a movement lock
    // they did not ask for on a switch.
    self.wep_deployed      = 0;
    self.weapon_deployable = TRUE;   // arms the shared SH_DeploySpeedFactor lock
    W_SetCrosshairProfile(SH_DodMGBaseSpread(wep), DODMG_MOVE_SPREAD, DODMG_FULL_SPREAD_SPEED, 2.2, TRUE);
};

void() W_DodMGDrop =
{
    entity tgt = weapon_drop_target;
    float  wep = self.weapon;

    tgt.mag_dod30cal  = self.mag_dod30cal;   tgt.ammo_dod30cal = self.ammo_dod30cal;
    tgt.mag_dodmg34   = self.mag_dodmg34;    tgt.ammo_dodmg34  = self.ammo_dodmg34;
    tgt.mag_dodmg42   = self.mag_dodmg42;    tgt.ammo_dodmg42  = self.ammo_dodmg42;

    self.mag_dod30cal = 0;  self.ammo_dod30cal = 0;
    self.mag_dodmg34  = 0;  self.ammo_dodmg34  = 0;
    self.mag_dodmg42  = 0;  self.ammo_dodmg42  = 0;

    setmodel(tgt, SH_DodMGWorldModel(wep));
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = SH_DodMGClassname(wep);
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = wep;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodMGEquip;
    tgt.weap_drop_func = W_DodMGDrop;
    tgt.pickupcopy     = W_DodMGPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void(float wep) W_DodMGSpawnCommon =
{
    setmodel(self, SH_DodMGWorldModel(wep));
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = SH_DodMGClassname(wep);
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = wep;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodMGEquip;
    self.weap_drop_func = W_DodMGDrop;
    self.pickupcopy     = W_DodMGPickupCopy;
    self.touch          = weapon_touch;

    switch (wep)
    {
    case WEP_DODMG34:
        self.mag_dodmg34  = SH_DodMGMaxMag(wep);
        self.ammo_dodmg34 = SH_DodMGMaxAmmo(wep);
        break;
    case WEP_DODMG42:
        self.mag_dodmg42  = SH_DodMGMaxMag(wep);
        self.ammo_dodmg42 = SH_DodMGMaxAmmo(wep);
        break;
    default:
        self.mag_dod30cal  = SH_DodMGMaxMag(wep);
        self.ammo_dod30cal = SH_DodMGMaxAmmo(wep);
        break;
    }
};

void() weapon_30cal = { W_DodMGSpawnCommon(WEP_DOD30CAL); W_RegisterMapWeapon(weapon_30cal); };
void() weapon_mg34  = { W_DodMGSpawnCommon(WEP_DODMG34);  W_RegisterMapWeapon(weapon_mg34); };
void() weapon_mg42  = { W_DodMGSpawnCommon(WEP_DODMG42);  W_RegisterMapWeapon(weapon_mg42); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodmg_snd_stage;
float csqc_dodmg_snd_action;

void() CSQC_PredictDodMGCommand =
{
    float r;
    float wep = self.weapon;

    if (predicted_player.wep_action_id != csqc_dodmg_snd_action)
    {
        csqc_dodmg_snd_action = predicted_player.wep_action_id;
        csqc_dodmg_snd_stage  = 0;
    }

    // +attack2 — plant on the bipod, or pick the gun back up.  Predicted so the
    // movement lock lifts the instant the take ends rather than a round trip
    // later; SH_DodMGTickState flips the flag identically on both sides.
    if (input_buttons & 4)
    {
        if (SH_DodMGTryStance(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_dodmg_snd_stage  = 0;
            csqc_dodmg_snd_action = predicted_player.wep_action_id;
        }
    }
    else
    {
        // Clearing half of the rising-edge latch, mirroring W_DodMGAltRelease.
        SH_StanceAltEdge(FALSE);
    }

    if (input_buttons & 1)
    {
        r = SH_DodMGTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, SH_DodMGFireSound(wep), 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SH_DodMGSpread(wep), DODMG_MOVE_SPREAD, DODMG_FULL_SPREAD_SPEED,
                    DODMG_CLOSE_DAMAGE, DODMG_MIN_DAMAGE, DODMG_DAMAGE_FALLOFF_RANGE, 40, 0.92,
                    DODMG_KICK_PITCH, DODMG_KICK_VARIANCE, DODMG_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODMG_MUZZLE_FORWARD, DODMG_MUZZLE_RIGHT,
                    DODMG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODMG_MUZZLE_FORWARD, DODMG_MUZZLE_RIGHT,
                    DODMG_MUZZLE_DOWN, self.wep_action_id, 1);
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

    if (!pm_suppress_sounds && self.wep_anim_start > 0 && self.weaponstate == WS_RELOAD)
    {
        float elapsed = csqc_pred_time - self.wep_anim_start;
        float rel = SH_DodMGReloadDuration(wep);
        float n;
        for (n = 1; n <= 5; n = n + 1)
        {
            float f = SH_DodMGReloadStageFrac(wep, n);
            if (f < 0)
                break;
            if (csqc_dodmg_snd_stage < n && elapsed >= rel * f)
            {
                localsound(SH_DodMGReloadStageSound(wep, n));
                CSQC_RecordPredictedAutoSound();
                csqc_dodmg_snd_stage = n;
            }
        }
    }

    // Mark the ack at the stance FLIP as well as at the press, or reconcile stomps
    // the predicted flip for a full RTT — see the long note at the same place in
    // sh_wpn_dodbar.qc.
    float mg_pre_dep = self.wep_deployed;
    SH_DodMGTickState(csqc_pred_time);
    if (self.wep_deployed != mg_pre_dep)
        CSQC_MarkPendingWeaponAck();
};

// Weapon-special (impulse 7), the second entry point to the bipod toggle.  Has to
// be on the hand-written else-if chain under WEAPON_IMPULSE_SPECIAL in
// client/cl_weapons.qc or the plant runs server-side and the viewmodel never moves
// — see W_DodMGSpecial and [[impulse7-dispatch-is-a-hand-list]].
void() CSQC_PredictDodMGSpecial =
{
    SH_StanceAltArmForImpulse();
    if (SH_DodMGTryStance(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_dodmg_snd_stage  = 0;
        csqc_dodmg_snd_action = predicted_player.wep_action_id;
    }
};

void() CSQC_PredictDodMGReload =
{
    if (SH_DodMGTryReload(csqc_pred_time))
    {
        csqc_dodmg_snd_stage  = 0;
        csqc_dodmg_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodMGDisplayFrame =
{
    float wep = predicted_player.weapon;
    float mag = SH_DodMGMag(predicted_player);
    float dep = predicted_player.wep_deployed;

    // THE HELPER GOES FIRST.  Its own contract says so — sh_weapon_standard.qc:543
    // reads "Call FIRST from a csqc_display_frame implementation, for EVERY state —
    // it has to see the non-idle frames to catch the return-to-idle edge" — and
    // this function used to call it LAST, after early returns that covered every
    // non-idle state there is.  So it was only ever entered with WS_IDLE,
    // csqc_seqidle_prev_state was already WS_IDLE on every call, the
    // non-idle -> idle edge never fired even once, and csqc_seqidle_seq stayed
    // latched at whatever the draw left it on until the 10-15 s fidget reroll
    // happened to overwrite it.  `pose` was recomputed correctly every frame and
    // then thrown away, because the latched value is returned in preference.
    //
    // That is the whole of "the gun doesn't know which sequence to use": the belt
    // shrank correctly WHILE the trigger was held (WS_FIRE returns live below) and
    // snapped back to a full belt the instant you let go, and the bipod pose popped
    // back to the standing idle the moment the plant animation finished.
    //
    // The reorder is behaviour-neutral for the non-idle states: the helper returns
    // -1 for them before it touches csqc_viewmodel_sequence_time_override.  With it
    // in front, every shot, every reload and every stance flip produces the edge
    // that re-picks `pose` — and since the magazine can only change on a shot or a
    // reload, and the stance only on a flip, the bracket can never go stale again.
    //
    // CSQC_DodBarDisplayFrame and CSQC_DodColtDisplayFrame already had this order.
    float pose = SH_DodMGSeqIdle(wep, mag, dep);

    // The stance is folded into the latch key — see the note at the same call in
    // sh_wpn_dodbar.qc.  The belt bracket does NOT need to be: the magazine can
    // only change on a shot or a reload, and both of those produce a real
    // non-idle -> idle edge.
    float idle = SH_SeqIdleDisplay(cltime, wep + (dep ? 4096 : 0),
                                   predicted_player.weaponstate,
                                   pose, pose,
                                   DODMG_IDLE_REARM_MIN, DODMG_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodMGSeqDraw(wep, mag);
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodMGSeqReload(wep);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodMGSeqShoot(wep, mag, dep);
    // The stance change.  The flag has not flipped yet — it flips when the take
    // ends — so SH_DodMGSeqStance returns the one leaving the current stance.
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodMGSeqStance(wep, mag, dep);

    return pose;
};

void() CSQC_DodMGDropClear =
{
    self.mag_dod30cal = 0;  self.ammo_dod30cal = 0;
    self.mag_dodmg34  = 0;  self.ammo_dodmg34  = 0;
    self.mag_dodmg42  = 0;  self.ammo_dodmg42  = 0;
};

void() CSQC_DodMGEquipCommon =
{
    float wep = self.weapon;
    W_SetADSProfile(TRUE, "cl_ads_dodmg", SCOPE_CLASS_NONE);
    self.weapon_name         = SH_DodMGDisplayName(wep);
    self.weapon_viewmodel    = SH_DodMGViewModel(wep);
    self.weapon_worldmodel   = SH_DodMGWorldModel(wep);
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd    = CSQC_PredictDodMGCommand;
    self.csqc_predict_reload = CSQC_PredictDodMGReload;
    self.csqc_display_frame  = CSQC_DodMGDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodMGDropClear;
    self.weapon_uses_sequences = TRUE;
    // Arms the shared movement lock on the client's copy too — CSQC runs
    // Weapon_SpeedFactor_Smooth in its own pmove.  NOT accompanied by a
    // wep_deployed reset, for the same reason as the sound stage below: this
    // function re-runs on every reconcile and would unplant the gun 20x a second.
    self.weapon_deployable = TRUE;
    // DO NOT RESET csqc_dodmg_snd_stage HERE — see the same note in
    // sh_wpn_dodat.qc.  CSQC_WeaponEquip is re-invoked from
    // CSQC_ResetToConfirmedState (client/cl_player.qc:1051) on every reconcile,
    // so this line wiped the latch several times a second and the MG reload's
    // event list re-fired from the top each time.  That is the reported
    // "repeating reloading sound".  The per-action guard in
    // CSQC_PredictDodMGCommand is the correct re-arm point.
};

void() CSQC_Dod30CalEquip = { CSQC_DodMGEquipCommon(); };
void() CSQC_DodMG34Equip  = { CSQC_DodMGEquipCommon(); };
void() CSQC_DodMG42Equip  = { CSQC_DodMGEquipCommon(); };

#endif // CSQC
