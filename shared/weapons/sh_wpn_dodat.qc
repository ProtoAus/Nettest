// ============================================================
//  shared/weapons/sh_wpn_dodat.qc  -  Day of Defeat anti-tank, all three
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : one round in the tube, a handful in reserve, huge blast
//  Fire  : server-spawned projectile + radius explosion
//  Alt   : +attack2 SHOULDERS the launcher, and it must be held to the end of
//          down_to_up before +attack will fire (see THE SHOULDERED SET, below)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THESE.  v_/w_ and the three rocket meshes all come from
//  the mounted dod gamedir.  Note the Panzerschreck's world model is
//  `w_pschreck.mdl`, NOT w_panzerschreck.mdl — the view model is the only file
//  of the three that spells the name out.
//
//  MEASURED.  Durations are (frames-1)/fps, which is what FTE reports and what
//  SH_SeqDuration returns; the fraction tables below are derived from these.
//
//    dod/models/v_bazooka.mdl        8 seqs, 53 bones
//      [0] idle 30fps 2f 0.033   [1] draw 30fps 31f 1.000  f1 rifleselect
//      [2] aimed 30fps 2f 0.033  [3] launch 35fps 36f 1.000  f1 5001 flash 71
//      [4] down_to_up 34fps 28f 0.794   [5] up_to_down 28fps 29f 1.000
//      [6] reload_aimed 36fps 110f 3.028   [7] reload_idle 36fps 110f 3.028
//            f20 bazookareloadgetrocket.wav   0.182
//            f41 bazookareloadrocketin.wav    0.373
//            f68 bazookareloadshovehome.wav   0.618
//    dod/models/v_panzerschreck.mdl  8 seqs, 52 bones  (same layout)
//      draw 1.000, launch 1.000, down_to_up 0.806, up_to_down 1.000,
//      reload_aimed 3.030, reload_idle 3.514
//            getrocket 0.250, rocketin 0.339, shovehome 0.556
//    dod/models/v_piat.mdl          13 seqs, 53 bones
//      idle/idle_empty, draw/draw_empty, aimed/aimed_empty, launch,
//      down_to_up(_empty), up_to_down(_empty), reload_idle, reload_aimed
//      draw 1.000, launch 1.000, down_to_up 0.811, up_to_down 1.000,
//      reload_idle 3.000
//            getrocket 0.220, rocketin 0.516, shovehome 0.758
//
//  The PIAT's sequence ORDER is not the other two's — it interleaves an `_empty`
//  variant after every pose — so the fallback indices are per-weapon.
//
//  THE SHOULDERED SET IS WIRED, AND IT IS THE ONLY AIM THIS WEAPON HAS.
//
//  +attack2 plays `down_to_up`, holds `aimed`, and plays `up_to_down` on release.
//  Firing IS gated on that transition having finished — hold it to the end or the
//  trigger does nothing at all (silently: no click, no animation, see
//  SH_DodATTryFire).  The single `launch` take on each of these models is the
//  SHOULDERED one, so there was never an animation that fitted a hip shot.
//
//  THE POSE ADS IS OFF.  An earlier pass drove the pose from csqc_viewfx_ads_env
//  — the shared 0..1 ADS envelope — on the reasoning that reading the envelope
//  meant the pose could not drift from the view offset.  True, but it left the
//  launcher with TWO aims stacked: the model's authored down_to_up AND the
//  generic eye-offset slide the envelope applies to every pose-ADS weapon.
//  W_DodATEquip now passes eligible = FALSE, which turns the view offset and the
//  ADS spread tighten off together (cl_viewfx.qc:281, Weapon_IsADSActive), and
//  the shoulder became its own state: dodat_aim_start, a hold START TIME that
//  both the pose and the fire gate read.  One field, so the launcher can never
//  look shouldered while refusing to fire.
//
//  The PIAT's `_empty` SHOULDER TRANSITIONS ARE WIRED (down_to_up_empty,
//  up_to_down_empty — see SH_DodATSeqUpFor/DownFor).  Its idle_empty, draw_empty
//  and aimed_empty are still not: those three sit behind accessors that compile
//  into SSQC as well, so changing their arity ripples into the server, and they
//  want doing as their own change.  reload_aimed is unwired for a concrete reason — the
//  Panzerschreck's is 0.48 s SHORTER than its reload_idle and carries different
//  event marks, so selecting between them would need a second duration and a
//  second fraction table for one weapon.
//
//  FIRE SAMPLES.  dod/sound/weapons has piat_shoot.wav but NO bazooka or
//  Panzerschreck shot: the two rocket launchers get rocket1.wav and rocket2.wav,
//  which is the pair DoD itself ships for them.  The bazooka's cannot be reached
//  through the mount — see SH_DodATFireSound.  All three share the
//  bazookareload* set, which the models name in their own events.
//
//  THE SHOOTER SEES THE REAL ROCKET, not a predicted fake.  Every other
//  projectile in this tree hides the server copy from its owner
//  (projectile_SendEntity returns FALSE for self.owner) and draws a CSQC fake in
//  its place, so the shooter gets it with no latency.  These three deliberately
//  do not: an AT rocket is slow, it is fired at things far away, and the round
//  trip is not perceptible on it — whereas a fake would have to reproduce the
//  arc, the trail and the detonation, and any drift between the two shows up as
//  a rocket that explodes somewhere the player did not watch it go.  Hence
//  DodAT_SendEntity below, which is projectile_SendEntity minus the owner skip.

// --- Ammo fields ---
.float mag_dodbazooka;
.float ammo_dodbazooka;
.float mag_dodschreck;
.float ammo_dodschreck;
.float mag_dodpiat;
.float ammo_dodpiat;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODAT_SEQ_IDLE   = 0;
const float DODAT_SEQ_DRAW   = 1;
const float DODAT_SEQ_LAUNCH = 3;
const float DODAT_SEQ_RELOAD = 7;

const float DODAT_FRAME_INTERVAL = 0.0333334;
const float DODAT_DRYFIRE_DELAY  = 0.35;

const float DODAT_DRAW_F_SELECT = 0.032;

const float DODAT_IDLE_REARM_MIN = 10;
const float DODAT_IDLE_REARM_MAX = 15;

.float dodat_snd_stage;
// Which launcher fired a given rocket.  Carried ON THE ROCKET rather than read
// back off .owner at detonation, because the shooter may have switched weapons,
// dropped the launcher or died in the second the round was in the air — and the
// warhead that is about to go off is the one that was loaded, not the one they
// happen to be holding now.
.float proj_dod_wep;

// ============================================================
//  SHARED — per-weapon table
// ============================================================

string(float wep) SH_DodATViewModel =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return "models/v_bazooka.mdl";
    case WEP_DODSCHRECK: return "models/v_panzerschreck.mdl";
    case WEP_DODPIAT:    return "models/v_piat.mdl";
    }
    return "models/v_bazooka.mdl";
};

string(float wep) SH_DodATWorldModel =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return "models/w_bazooka.mdl";
    case WEP_DODSCHRECK: return "models/w_pschreck.mdl";   // NOT w_panzerschreck
    case WEP_DODPIAT:    return "models/w_piat.mdl";
    }
    return "models/w_bazooka.mdl";
};

string(float wep) SH_DodATDisplayName =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return "BAZOOKA";
    case WEP_DODSCHRECK: return "PANZERSCHRECK";
    case WEP_DODPIAT:    return "PIAT";
    }
    return "BAZOOKA";
};

string(float wep) SH_DodATClassname =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return "weapon_bazooka";
    case WEP_DODSCHRECK: return "weapon_pschreck";
    case WEP_DODPIAT:    return "weapon_piat";
    }
    return "weapon_bazooka";
};

// THE BAZOOKA'S SAMPLE IS A MOD-OWNED COPY AND IT HAS TO BE.  `weapons/rocket1.wav`
// is one of DoD's colliding sound names: svencoop, valve and bshift all ship a file
// of that name and all three outrank dod in fs_addons.txt, so the launcher was
// getting Half-Life's RPG FLIGHT loop instead of DoD's launch report.  That file
// carries a `cue ` chunk, and FTE reads cue points as loop points (snd_mem.c:1329),
// so it looped forever — the reported "repeating rocket firing sound until you
// +attack again", the next shot cutting the channel being the only thing that ever
// stopped it.  Measured: valve/svencoop rocket1.wav = fmt,data,LIST,cue,LIST;
// dod's = fmt,data, no cue.  QC cannot ask for a specific mount, and DoD sits at
// the bottom on purpose (it reuses ten HL model names), so the only fix that keeps
// the RIGHT audio is to ship DoD's copy under a name nothing else owns.  Same
// arrangement as RPG_FIRE_SOUND.  rocket2.wav and piat_shoot.wav are DoD-exclusive
// and do not loop, which is why only the bazooka was affected.
string(float wep) SH_DodATFireSound =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return "sounds/weapons/wpn_dodat/bazooka_fire.wav";
    case WEP_DODSCHRECK: return "weapons/rocket2.wav";
    case WEP_DODPIAT:    return "weapons/piat_shoot.wav";
    }
    return "sounds/weapons/wpn_dodat/bazooka_fire.wav";
};

float(float wep) SH_DodATProjType =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return PROJ_TYPE_DOD_BAZOOKA;
    case WEP_DODSCHRECK: return PROJ_TYPE_DOD_SCHRECK;
    case WEP_DODPIAT:    return PROJ_TYPE_DOD_PIAT;
    }
    return PROJ_TYPE_DOD_BAZOOKA;
};

// --- Balance ---
//
// ONE ROUND IN THE TUBE AND A THREE-SECOND RELOAD is the entire balance of this
// class — miss and you are holding a stick for three seconds — so the warheads
// are allowed to be genuinely lethal rather than nerfed into pointlessness.
// Peak damage kills an unarmoured player outright inside the inner radius and
// falls to a survivable graze at the edge, which is what the HL RPG in this tree
// already does; these sit slightly under it because they come with no guidance.
//
//   bazooka       120 / 25 over 300   1 loaded, 4 spare
//   Panzerschreck 130 / 26 over 310   1 loaded, 4 spare   heavier warhead
//   PIAT          100 / 22 over 275   1 loaded, 3 spare   arcs; no back-blast
//
// The Panzerschreck's edge is small and historical (the RPzB 54's 3.2 kg warhead
// against the bazooka's 1.6 kg) and its cost is a slower reload.  The PIAT gives
// up flat trajectory for the ability to shoot from inside a room without the
// back-blast that the two rocket launchers have — which this mod does not model,
// so the PIAT instead pays in damage and reserve rounds.
float(float wep) SH_DodATDamage =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return 120;
    case WEP_DODSCHRECK: return 130;
    case WEP_DODPIAT:    return 100;
    }
    return 120;
};

float(float wep) SH_DodATMinDamage =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return 25;
    case WEP_DODSCHRECK: return 26;
    case WEP_DODPIAT:    return 22;
    }
    return 25;
};

float(float wep) SH_DodATRadius =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return 300;
    case WEP_DODSCHRECK: return 310;
    case WEP_DODPIAT:    return 275;
    }
    return 300;
};

// Launch speed.  The two rockets fly flat and fast; the PIAT is a spring-thrown
// bomb and is both slower and subject to gravity (Projectile_TypeGravity 0.4).
float(float wep) SH_DodATSpeed =
{
    switch (wep)
    {
    case WEP_DODBAZOOKA: return 1400;
    case WEP_DODSCHRECK: return 1350;
    case WEP_DODPIAT:    return 1000;
    }
    return 1400;
};

float(float wep) SH_DodATFireDelay = { return 1.10; };

float(float wep) SH_DodATMaxMag  = { return 1; };
float(float wep) SH_DodATMaxAmmo = { return (wep == WEP_DODPIAT) ? 3 : 4; };

const float DODAT_KNOCKBACK_PUSH   = 480;
const float DODAT_KNOCKBACK_UPLIFT = 200;

const float DODAT_MUZZLE_FORWARD = 40;
const float DODAT_MUZZLE_RIGHT   = 6;
const float DODAT_MUZZLE_DOWN    = -2;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

// FALLBACKS ARE PER-WEAPON.  The single DODAT_SEQ_* set above is the bazooka's and
// the Panzerschreck's; the PIAT interleaves an `_empty` variant after every pose, so
// on that model the same numbers name idle_empty(1), draw_empty(3) and down_to_up(7).
// Only reached in the window before the view model is precached (SH_SeqForName
// returns the fallback while getmodelindex() <= 0), and range-checked either way, so
// this was never out of bounds — just the wrong art for that window.
float(float wep) SH_DodATFbIdle   = { return 0; };
float(float wep) SH_DodATFbDraw   = { return (wep == WEP_DODPIAT) ?  2 : DODAT_SEQ_DRAW; };
float(float wep) SH_DodATFbLaunch = { return (wep == WEP_DODPIAT) ?  6 : DODAT_SEQ_LAUNCH; };
float(float wep) SH_DodATFbReload = { return (wep == WEP_DODPIAT) ? 11 : DODAT_SEQ_RELOAD; };
float(float wep) SH_DodATFbAimed  = { return (wep == WEP_DODPIAT) ?  4 : 2; };
float(float wep) SH_DodATFbUp     = { return (wep == WEP_DODPIAT) ?  7 : 4; };
float(float wep) SH_DodATFbDown   = { return (wep == WEP_DODPIAT) ?  9 : 5; };

float(float wep) SH_DodATSeqIdle   = { return SH_SeqForName(SH_DodATViewModel(wep), "idle",        SH_DodATFbIdle(wep)); };
float(float wep) SH_DodATSeqDraw   = { return SH_SeqForName(SH_DodATViewModel(wep), "draw",        SH_DodATFbDraw(wep)); };
float(float wep) SH_DodATSeqLaunch = { return SH_SeqForName(SH_DodATViewModel(wep), "launch",      SH_DodATFbLaunch(wep)); };
float(float wep) SH_DodATSeqReload = { return SH_SeqForName(SH_DodATViewModel(wep), "reload_idle", SH_DodATFbReload(wep)); };

// The shouldered set.  `aimed` is the held pose; down_to_up / up_to_down are the
// transitions between hip and shoulder.  All three models carry all three.
float(float wep) SH_DodATSeqAimed  = { return SH_SeqForName(SH_DodATViewModel(wep), "aimed",       SH_DodATFbAimed(wep)); };
float(float wep) SH_DodATSeqUp     = { return SH_SeqForName(SH_DodATViewModel(wep), "down_to_up",  SH_DodATFbUp(wep)); };
float(float wep) SH_DodATSeqDown   = { return SH_SeqForName(SH_DodATViewModel(wep), "up_to_down",  SH_DodATFbDown(wep)); };

// THE PIAT SHOULDERS AN EMPTY TUBE DIFFERENTLY, and it has the art for it.
// Measured off dod/models/v_piat.mdl — 13 sequences, a full parallel pose set:
//     [7] down_to_up 37fps 31f    [8] down_to_up_empty 37fps 31f
//     [9] up_to_down 30fps 31f   [10] up_to_down_empty 30fps 31f
// The pairs are FRAME- AND FPS-IDENTICAL, which is what makes this safe: the
// durations below can keep resolving off the loaded take, and a swap mid-take
// cannot desync the sequence clock.
//
// v_bazooka.mdl and v_panzerschreck.mdl have 8 sequences and NO _empty takes at
// all, so this must be name-first-with-fallback rather than a branch on the
// weapon — SH_SeqForName2 tries the _empty name, then the loaded name, then the
// index.  On those two it simply lands back on the loaded take, unchanged.
//
// Worth knowing WHEN this shows: the auto-reload normally refills within about a
// tenth of a second of the launch take ending, so the empty pose is barely seen
// after an ordinary shot.  The case that matters is an empty tube with NO
// ROCKETS LEFT — SH_DodATWantsAutoReload returns FALSE on an exhausted reserve,
// so the weapon then holds the empty pose indefinitely, and until now it held
// the loaded one, rocket and all.
float(float wep) SH_DodATFbUpEmp   = { return (wep == WEP_DODPIAT) ?  8 : 4; };
float(float wep) SH_DodATFbDownEmp = { return (wep == WEP_DODPIAT) ? 10 : 5; };

float(float wep) SH_DodATSeqUpEmp   = { return SH_SeqForName2(SH_DodATViewModel(wep), "down_to_up_empty", "down_to_up", SH_DodATFbUpEmp(wep)); };
float(float wep) SH_DodATSeqDownEmp = { return SH_SeqForName2(SH_DodATViewModel(wep), "up_to_down_empty", "up_to_down", SH_DodATFbDownEmp(wep)); };

float(float wep, float mag) SH_DodATSeqUpFor   = { return (mag > 0) ? SH_DodATSeqUp(wep)   : SH_DodATSeqUpEmp(wep); };
float(float wep, float mag) SH_DodATSeqDownFor = { return (mag > 0) ? SH_DodATSeqDown(wep) : SH_DodATSeqDownEmp(wep); };

float(float wep) SH_DodATDrawDuration   = { return SH_SeqDuration(SH_DodATViewModel(wep), SH_DodATSeqDraw(wep),   1.000); };
float(float wep) SH_DodATLaunchDuration = { return SH_SeqDuration(SH_DodATViewModel(wep), SH_DodATSeqLaunch(wep), 1.000); };
float(float wep) SH_DodATReloadDuration = { return SH_SeqDuration(SH_DodATViewModel(wep), SH_DodATSeqReload(wep), 3.028); };
float(float wep) SH_DodATUpDuration     = { return SH_SeqDuration(SH_DodATViewModel(wep), SH_DodATSeqUp(wep),     0.794); };
float(float wep) SH_DodATDownDuration   = { return SH_SeqDuration(SH_DodATViewModel(wep), SH_DodATSeqDown(wep),   1.000); };

// The three reload events, as fractions.  Unlike the machine guns these differ
// only in their marks, not in their count or their samples, so one small table
// covers all three.
float(float wep, float n) SH_DodATReloadStageFrac =
{
    if (wep == WEP_DODSCHRECK)
    {
        if (n == 1) return 0.250;
        if (n == 2) return 0.339;
        if (n == 3) return 0.556;
        return -1;
    }
    if (wep == WEP_DODPIAT)
    {
        if (n == 1) return 0.220;
        if (n == 2) return 0.516;
        if (n == 3) return 0.758;
        return -1;
    }
    if (n == 1) return 0.182;
    if (n == 2) return 0.373;
    if (n == 3) return 0.618;
    return -1;
};

string(float n) SH_DodATReloadStageSound =
{
    if (n == 1) return "weapons/bazookareloadgetrocket.wav";
    if (n == 2) return "weapons/bazookareloadrocketin.wav";
    if (n == 3) return "weapons/bazookareloadshovehome.wav";
    return "";
};

// ============================================================
//  SHARED — state machine
// ============================================================

// Defined below — SH_DodATTickState calls it for the auto-reload.
float(float now) SH_DodATTryReload;

float(float wep) SH_DodATMag =
{
    switch (wep)
    {
    case WEP_DODSCHRECK: return self.mag_dodschreck;
    case WEP_DODPIAT:    return self.mag_dodpiat;
    }
    return self.mag_dodbazooka;
};

// SAME READ, ARBITRARY ENTITY — the render path needs this and SH_DodATMag above
// cannot serve it.  CSQC_GetWeaponDisplayFrame calls the display function through
// an entity FIELD (client/cl_weapons.qc:1950), and a field-function call does not
// rebind self, so `self` in a display frame is whatever the caller left it as —
// not predicted_player, which is where the predicted magazine actually lives.
// Kept as a separate function rather than turning SH_DodATMag into a wrapper, so
// the SSQC and prediction call sites stay byte-identical.
float(entity e, float wep) SH_DodATMagOf =
{
    switch (wep)
    {
    case WEP_DODSCHRECK: return e.mag_dodschreck;
    case WEP_DODPIAT:    return e.mag_dodpiat;
    }
    return e.mag_dodbazooka;
};

float(float wep) SH_DodATReserve =
{
    switch (wep)
    {
    case WEP_DODSCHRECK: return self.ammo_dodschreck;
    case WEP_DODPIAT:    return self.ammo_dodpiat;
    }
    return self.ammo_dodbazooka;
};

// ONE ROUND IN THE TUBE MEANS EVERY SHOT ENDS EMPTY, so the reload is the normal
// case and making the player press a key for it is just a tax.  Requested.
float(float now) SH_DodATWantsAutoReload =
{
    float wep = self.weapon;
    if (SH_DodATMag(wep) > 0)         return FALSE;   // still loaded
    if (SH_DodATReserve(wep) <= 0)    return FALSE;   // nothing to load
    if (now < self.attack_finished)   return FALSE;   // post-shot debounce
    return TRUE;
};

// The round goes in at stage 3, `shovehome` — the point the loader slaps it into
// the tube.  Before that the launcher genuinely is empty.
float(float now) SH_DodATTickState =
{
    float wep = self.weapon;
    float rel = SH_DodATReloadDuration(wep);
    float dr  = SH_DodATDrawDuration(wep);
    float fd  = SH_DodATLaunchDuration(wep);
    float ap  = rel * SH_DodATReloadStageFrac(wep, 3);
    float r   = 0;   // explicit: fteqcc's flow analysis does not see a switch's default arm

    switch (wep)
    {
    case WEP_DODSCHRECK:
        r = SH_StandardTickState(now, mag_dodschreck, ammo_dodschreck, SH_DodATMaxMag(wep),
                                 dr, fd, rel, ap);
        break;
    case WEP_DODPIAT:
        r = SH_StandardTickState(now, mag_dodpiat, ammo_dodpiat, SH_DodATMaxMag(wep),
                                 dr, fd, rel, ap);
        break;
    default:
        r = SH_StandardTickState(now, mag_dodbazooka, ammo_dodbazooka, SH_DodATMaxMag(wep),
                                 dr, fd, rel, ap);
        break;
    }

    // A POLL, NOT AN EDGE.  Bit 0 of the result ("this tick retired the weapon
    // to idle") is raised when the LAUNCH ANIMATION ends, at 1.000 s, but the
    // auto-reload is gated on attack_finished = fire time + SH_DodATFireDelay =
    // 1.10 s.  An edge-triggered version would test 0.10 s too early, exactly
    // once, and never get a second chance.  The RPG's version of this is at
    // sh_wpn_hlrpg.qc:160 and the reasoning is identical.
    //
    // AND IT RUNS ON BOTH SIDES.  It used to be `#ifdef SSQC`, to stop a double
    // reload: the client predicted WS_RELOAD, the server's next snapshot still
    // showed the pre-reload state and OVERWROTE it, and the client — seeing an
    // empty tube again — started a second one.  That mechanism no longer exists.
    // Reconcile deliberately does not write fire-decision state back any more
    // (client/cl_player.qc:1022, "FIRE-DECISION STATE NO LONGER RECONCILED FROM
    // SERVER"); `sv_confirmed_weaponstate` is now WRITTEN AND NEVER READ.
    //
    // Which turned server-only into the actual reported bug — "the other rockets
    // don't auto reload after being fired".  They did reload; the launcher just
    // never MOVED.  With the server owning the only copy of WS_RELOAD and no
    // route for it to reach predicted_player, CSQC_DodATDisplayFrame never
    // entered its reload branch: the gun held its idle pose for three seconds
    // and the ammo counter refilled on its own.  Both halves of the pair — mortar
    // and RPG — had it too, and none of it is visible from a server-side test.
    //
    // Sound does not double.  The reload marks below are played by
    // CSQC_PredictDodATCommand's WS_RELOAD branch through localsound() +
    // CSQC_RecordPredictedAutoSound(), and the server's CHAN_AUTO copies to the
    // firing player are muted for one second afterwards (client/cl_main.qc:1408).
    // That is exactly the path a MANUAL reload has always taken; this only makes
    // the automatic one take it too.
    //
    // Clearing bit 0 when a reload starts is load-bearing: leaving it set lets
    // W_DodATFrame zero wep_nextframe on the same tick, the server stops calling
    // wepframe, and the reload never completes.
    if (SH_DodATWantsAutoReload(now) && SH_DodATTryReload(now))
    {
#ifdef SSQC
        // Server-side stamping only: .weaponframe is the third-person/
        // authoritative sequence and .wep_nextframe is what keeps W_DodATFrame
        // being called.  The client picks its own sequence from weaponstate in
        // CSQC_DodATDisplayFrame and is ticked every frame regardless, and its
        // sound latch is a global that wep_action_id re-arms.
        self.weaponframe     = SH_DodATSeqReload(wep);
        self.wep_nextframe   = now + DODAT_FRAME_INTERVAL;
        self.dodat_snd_stage = 0;
#endif
        r = r & ~1;
    }

    return r;
};

// ---- The shoulder hold ----
//
// +attack2 SHOULDERS the launcher, and firing is gated on the down_to_up take
// having finished.  The old shape let +attack fire at any time and treated the
// shot as shouldered for pose purposes; the line in the header offering "one line
// in SH_DodATTryFire if that is wanted" is now that gate, spelled out.
//
// The hold is a START TIME, not a flag, so "is the transition complete" is a
// subtraction rather than a second piece of state that could disagree with the
// animation.  Both sides derive it from their own copy of the +attack2 bit — the
// server from self.button1 in W_DodATAim (bound to BOTH altfire and altrelease,
// because sv_weapons.qc calls one or the other every frame and the altfire branch
// is skipped while attack_finished is pending), CSQC from input_buttons in its
// predict command.
//
// DELIBERATELY NOT ON THE PREDICTION PROXY.  It is derived every frame from a
// button both sides already receive, so it re-converges on its own; the only
// divergence is the client leading by about one RTT, and the worst that costs is
// a shot taken within a few milliseconds of the boundary being refused by the
// server.  A proxy byte would buy nothing a subtraction does not already give.
.float dodat_aim_start;

// TRUE once the launcher is fully on the shoulder.  `now` is each side's own
// clock, which is why the field holds a start time in that clock rather than an
// absolute both sides would have to agree on.
float(float now, float wep) SH_DodATIsShouldered =
{
    if (self.dodat_aim_start <= 0)
        return FALSE;
    return (now - self.dodat_aim_start) >= SH_DodATUpDuration(wep);
};

// SEMI-AUTO, and with one round in the tube that is not pedantry: without the
// rising-edge gate a player holding +attack through the three-second reload
// fires again the instant it completes, which is not a decision they made.
float(float now) SH_DodATTryFire =
{
    float wep = self.weapon;
    float fd  = SH_DodATFireDelay(wep);

    // NOT SHOULDERED, NO SHOT.  Returns 0 rather than -1 so an unshouldered
    // trigger pull is silent and animation-free — there is no dry-fire click for
    // a decision the weapon simply is not taking, which is the same rule the
    // medkit and the tripmine follow.  DoD gates its launchers this way and the
    // single `launch` take on each of these models is the SHOULDERED one, so a
    // hip shot never had an animation that fitted it in the first place.
    if (!SH_DodATIsShouldered(now, wep))
        return 0;

    switch (wep)
    {
    case WEP_DODSCHRECK: return SH_StandardTryFireSemiAuto(now, mag_dodschreck, fd, DODAT_DRYFIRE_DELAY);
    case WEP_DODPIAT:    return SH_StandardTryFireSemiAuto(now, mag_dodpiat,    fd, DODAT_DRYFIRE_DELAY);
    }
    return SH_StandardTryFireSemiAuto(now, mag_dodbazooka, fd, DODAT_DRYFIRE_DELAY);
};

float(float now) SH_DodATTryReload =
{
    float wep = self.weapon;
    float rel = SH_DodATReloadDuration(wep);

    switch (wep)
    {
    case WEP_DODSCHRECK:
        return SH_StandardTryReload(now, mag_dodschreck, ammo_dodschreck, SH_DodATMaxMag(wep), rel);
    case WEP_DODPIAT:
        return SH_StandardTryReload(now, mag_dodpiat, ammo_dodpiat, SH_DodATMaxMag(wep), rel);
    }
    return SH_StandardTryReload(now, mag_dodbazooka, ammo_dodbazooka, SH_DodATMaxMag(wep), rel);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// projectile_SendEntity minus the owner skip — see the note in the header about
// why these three have no CSQC fake.  Everything else about the wire format is
// identical, so the existing CSQC_ENT_PROJECTILE parser reads it unchanged.
float(entity playerent, float changedflags) DodAT_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_PROJECTILE);
    WriteByte(MSG_ENTITY, self.proj_type);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);
    WriteCoord(MSG_ENTITY, self.avelocity_x);
    WriteCoord(MSG_ENTITY, self.avelocity_y);
    WriteCoord(MSG_ENTITY, self.avelocity_z);
    return TRUE;
};

void(entity player) W_DodATPickupCopy =
{
    player.mag_dodbazooka  = self.mag_dodbazooka;
    player.ammo_dodbazooka = self.ammo_dodbazooka;
    player.mag_dodschreck  = self.mag_dodschreck;
    player.ammo_dodschreck = self.ammo_dodschreck;
    player.mag_dodpiat     = self.mag_dodpiat;
    player.ammo_dodpiat    = self.ammo_dodpiat;
};

void() W_DodATExplode =
{
    float wep = self.proj_dod_wep;

    te_explosion(self.origin + '0 0 8');

    W_RadiusExplode(self.origin, SH_DodATRadius(wep),
                    SH_DodATDamage(wep), SH_DodATMinDamage(wep),
                    DODAT_KNOCKBACK_PUSH, DODAT_KNOCKBACK_UPLIFT, self.owner);

    remove(self);
};

void() W_DodATRocketTouch =
{
    if (other == self.owner)
        return;             // never on the shooter — you are standing behind it
    W_DodATExplode();
};

void() W_DodATRocketThink =
{
    // Pulse SendFlags so cl_tosssmooth.qc gets a fresh sample each tick.
    self.SendFlags |= 1;
    // Inert for rendering (DodAT_SendEntity carries no angles), but kept correct
    // and routed through the shared helper — see Projectile_FlightAngles.
    self.angles = Projectile_FlightAngles(self.proj_type, self.velocity);
    self.nextthink = time + Toss_NextThinkInterval();
};

// Unlike the RPG's rocket there is no acceleration and no guidance: these fly at
// the speed they left the tube.
//
// THE MOVETYPE IS CHOSEN FROM THE GRAVITY, and the old comment here was wrong in
// the way that mattered.  It said the PIAT "is FLYMISSILE too and takes its arc
// from .gravity instead" — but sv_phys.c:1399 EXCLUDES MOVETYPE_FLYMISSILE from
// WPhys_AddGravity, so .gravity is never read for it and the PIAT bomb flew dead
// flat while the CSQC extrapolator curved it (cl_tosssmooth.qc:145 applies
// Projectile_TypeGravity regardless of movetype).  Same trap the mortar was in.
//
// So: anything with gravity gets MOVETYPE_TOSS, which actually arcs and makes
// the two sides integrate the same curve; the bazooka and the Panzerschreck are
// gravity 0 and are MEANT to be flat, so they keep FLYMISSILE.  Deriving it from
// Projectile_TypeGravity rather than testing for the PIAT by name means a future
// launcher cannot inherit the bug by copying this block.
//
// BOUNCEMISSILE stays wrong for all three: they detonate on contact.  Contact
// detonation survives TOSS — WPhys_PushEntity calls WPhys_Impact for any
// trace.ent including the world edict (sv_phys.c:684).
void() W_DodATLaunch =
{
    float wep = self.weapon;

    makevectors(self.v_angle);

    entity rocket = spawn();
    rocket.owner        = self;
    rocket.classname    = "dod_at_rocket";
    rocket.solid        = SOLID_BBOX;
    rocket.proj_type    = SH_DodATProjType(wep);
    rocket.proj_dod_wep = wep;
    rocket.gravity      = Projectile_TypeGravity(rocket.proj_type);
    // See above: FLYMISSILE gets no gravity, so a gravity-bearing round has to
    // be TOSS or it flies flat.  PIAT 0.4 -> TOSS; bazooka/schreck 0 -> FLYMISSILE.
    rocket.movetype     = (rocket.gravity > 0) ? MOVETYPE_TOSS : MOVETYPE_FLYMISSILE;
    setmodel(rocket, Projectile_TypeModel(rocket.proj_type));
    setsize(rocket, '0 0 0', '0 0 0');

    // Out of the tube on the shoulder, not the middle of the view — the same
    // correction sh_wpn_hlrpg.qc documents for the RPG.
    setorigin(rocket, self.origin + self.view_ofs
                      + v_forward * 20 + v_right * 6 + v_up * -4);
    rocket.velocity = v_forward * SH_DodATSpeed(wep)
                    + v_forward * (self.velocity * v_forward);
    rocket.angles   = Projectile_FlightAngles(rocket.proj_type, rocket.velocity);

    rocket.touch      = W_DodATRocketTouch;
    rocket.SendEntity = DodAT_SendEntity;
    rocket.SendFlags  = 1;
    rocket.think      = W_DodATRocketThink;
    rocket.nextthink  = time + Toss_NextThinkInterval();
};

void() W_DodATFire =
{
    float r = SH_DodATTryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_DodATSeqLaunch(self.weapon);
        self.wep_nextframe   = time + DODAT_FRAME_INTERVAL;
        self.dodat_snd_stage = 0;

        W_DodATLaunch();
        sound(self, CHAN_WEAPON, SH_DodATFireSound(self.weapon), 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodATReload =
{
    if (SH_DodATTryReload(time))
    {
        self.weaponframe     = SH_DodATSeqReload(self.weapon);
        self.wep_nextframe   = time + DODAT_FRAME_INTERVAL;
        self.dodat_snd_stage = 0;
    }
};

void() W_DodATFrame =
{
    float wep     = self.weapon;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODAT_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodATDrawDuration(wep) * DODAT_DRAW_F_SELECT
            && self.dodat_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodat_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodATReloadDuration(wep);
        float n;
        for (n = 1; n <= 3; n = n + 1)
        {
            float f = SH_DodATReloadStageFrac(wep, n);
            if (f < 0)
                break;
            if (elapsed >= rel * f && self.dodat_snd_stage < n)
            {
                sound(self, CHAN_AUTO, SH_DodATReloadStageSound(n), 1, ATTN_NORM);
                self.dodat_snd_stage = n;
            }
        }
    }

    float result = SH_DodATTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_DodATSeqIdle(wep);
        self.dodat_snd_stage = 0;

        // RETIRE ONLY WHEN THERE IS NOTHING LEFT TO POLL FOR.  This function is
        // the only thing that calls SH_DodATTickState server-side, and the
        // auto-reload is a poll inside it — so zeroing wep_nextframe here
        // unconditionally stopped the server ticking 0.10 s before the
        // post-shot debounce expired, and nothing would have restarted it.
        // An empty tube is a pending auto-reload, so keep ticking.  Empty tube
        // AND empty reserve keeps ticking too, deliberately: that is what makes
        // walking over a rocket load the launcher without a keypress.  It costs
        // one tick for one player holding one empty launcher.
        if (SH_DodATMag(wep) > 0)
            self.wep_nextframe = 0;
    }
};

// Bound to BOTH altfire and altrelease.  sv_weapons.qc calls altfire while
// button1 is held AND attack_finished has expired, and altrelease in every other
// case — including while a fire cooldown is still running with the button still
// down.  One function that reads button1 itself is therefore the only shape that
// keeps the hold alive across a shot; splitting it would drop the shoulder every
// time the launcher fired and force the player to re-press.
void() W_DodATAim =
{
    if (self.button1)
    {
        if (self.dodat_aim_start <= 0)
            self.dodat_aim_start = time;
    }
    else
        self.dodat_aim_start = 0;
};

void() W_DodATEquip =
{
    float wep = self.weapon;
    // NO POSE ADS.  The prefix stays so its cvars keep a reader, but eligibility
    // is off: with it on, +attack2 also drove csqc_viewfx_ads_env, which slides
    // the whole viewmodel to a hand-tuned eye offset ON TOP of the model's own
    // down_to_up.  Two aims at once, and the launcher has an authored one.
    // cl_viewfx.qc:281 and Weapon_IsADSActive both read weapon_ads_eligible, so
    // this one word turns the view offset and the spread tighten off together.
    W_SetADSProfile(FALSE, "cl_ads_dodat", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(SH_DodATViewModel(wep), SH_DodATDisplayName(wep), SH_DodATSeqDraw(wep),
        DODAT_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire       = W_DodATFire;
    self.altfire    = W_DodATAim;
    self.altrelease = W_DodATAim;
    self.reload     = W_DodATReload;
    self.wepframe   = W_DodATFrame;
    self.shoot      = __NULL__;      // no hitscan — the projectile IS the shot
    self.dodat_snd_stage = 0;
    // Always drawn from the hip: the draw take starts and ends unshouldered, so a
    // launcher that remembered being aimed would come out mid-pose.
    self.dodat_aim_start = 0;
    W_SetCrosshairProfile(0.01, 0.05, 300, 1.4, FALSE);
};

void() W_DodATDrop =
{
    entity tgt = weapon_drop_target;
    float  wep = self.weapon;

    tgt.mag_dodbazooka = self.mag_dodbazooka;  tgt.ammo_dodbazooka = self.ammo_dodbazooka;
    tgt.mag_dodschreck = self.mag_dodschreck;  tgt.ammo_dodschreck = self.ammo_dodschreck;
    tgt.mag_dodpiat    = self.mag_dodpiat;     tgt.ammo_dodpiat    = self.ammo_dodpiat;

    self.mag_dodbazooka = 0;  self.ammo_dodbazooka = 0;
    self.mag_dodschreck = 0;  self.ammo_dodschreck = 0;
    self.mag_dodpiat    = 0;  self.ammo_dodpiat    = 0;

    setmodel(tgt, SH_DodATWorldModel(wep));
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = SH_DodATClassname(wep);
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = wep;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodATEquip;
    tgt.weap_drop_func = W_DodATDrop;
    tgt.pickupcopy     = W_DodATPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void(float wep) W_DodATSpawnCommon =
{
    setmodel(self, SH_DodATWorldModel(wep));
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = SH_DodATClassname(wep);
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = wep;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodATEquip;
    self.weap_drop_func = W_DodATDrop;
    self.pickupcopy     = W_DodATPickupCopy;
    self.touch          = weapon_touch;

    switch (wep)
    {
    case WEP_DODSCHRECK:
        self.mag_dodschreck  = SH_DodATMaxMag(wep);
        self.ammo_dodschreck = SH_DodATMaxAmmo(wep);
        break;
    case WEP_DODPIAT:
        self.mag_dodpiat  = SH_DodATMaxMag(wep);
        self.ammo_dodpiat = SH_DodATMaxAmmo(wep);
        break;
    default:
        self.mag_dodbazooka  = SH_DodATMaxMag(wep);
        self.ammo_dodbazooka = SH_DodATMaxAmmo(wep);
        break;
    }
};

void() weapon_bazooka  = { W_DodATSpawnCommon(WEP_DODBAZOOKA); W_RegisterMapWeapon(weapon_bazooka); };
void() weapon_pschreck = { W_DodATSpawnCommon(WEP_DODSCHRECK); W_RegisterMapWeapon(weapon_pschreck); };
void() weapon_piat     = { W_DodATSpawnCommon(WEP_DODPIAT);    W_RegisterMapWeapon(weapon_piat); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodat_snd_stage;
float csqc_dodat_snd_action;

void() CSQC_PredictDodATCommand =
{
    float r;
    float wep = self.weapon;

    if (predicted_player.wep_action_id != csqc_dodat_snd_action)
    {
        csqc_dodat_snd_action = predicted_player.wep_action_id;
        csqc_dodat_snd_stage  = 0;
    }

    // The shoulder hold, mirrored from the server's W_DodATAim.  Runs BEFORE the
    // fire test so a press and a trigger pull in the same command are ordered the
    // same way both sides order them.
    if (input_buttons & 4)
    {
        if (self.dodat_aim_start <= 0)
            self.dodat_aim_start = csqc_pred_time;
    }
    else
        self.dodat_aim_start = 0;

    if (input_buttons & 1)
    {
        r = SH_DodATTryFire(csqc_pred_time);
        if (r == 1)
        {
            // The magazine and the animation are predicted; the ROCKET is not
            // (see the header).  So this branch fires the report and the flash
            // and stops — no CSQC_PredictedPenetratingImpact, no fake entity.
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, SH_DodATFireSound(wep), 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlashAtMuzzle(DODAT_MUZZLE_FORWARD, DODAT_MUZZLE_RIGHT,
                    DODAT_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODAT_MUZZLE_FORWARD, DODAT_MUZZLE_RIGHT,
                    DODAT_MUZZLE_DOWN, self.wep_action_id, 3);
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
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_dodat_snd_stage < 1
                && elapsed >= SH_DodATDrawDuration(wep) * DODAT_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodat_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodATReloadDuration(wep);
            float n;
            for (n = 1; n <= 3; n = n + 1)
            {
                float f = SH_DodATReloadStageFrac(wep, n);
                if (f < 0)
                    break;
                if (csqc_dodat_snd_stage < n && elapsed >= rel * f)
                {
                    localsound(SH_DodATReloadStageSound(n));
                    CSQC_RecordPredictedAutoSound();
                    csqc_dodat_snd_stage = n;
                }
            }
        }
    }

    SH_DodATTickState(csqc_pred_time);
};

void() CSQC_PredictDodATReload =
{
    if (SH_DodATTryReload(csqc_pred_time))
    {
        csqc_dodat_snd_stage  = 0;
        csqc_dodat_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// ---- The shouldered pose ----
//
// "is there an aim function for the gun? it goes from rest to fire and looks
// wrong" — and it did, because there is exactly ONE `launch` sequence on each of
// these models and it is the SHOULDERED one.  Firing from the hip therefore cut
// straight from a hip idle to a shoulder-fire animation with nothing in between.
//
// The pose is driven by csqc_viewfx_ads_env (client/cl_viewfx.qc:58), the same
// 0..1 envelope that already moves the VIEW on +attack2 — deliberately, so the
// sequence and the view offset cannot disagree, which is the objection the old
// "THE SHOULDERED SET IS NOT WIRED" comment raised.  That envelope is computed
// from csqc_live_buttons, which is the correct button source in the render path
// (masking input_buttons never reaches it — see the two-button-paths note in
// client/cl_weapons.qc).
//
// Firing counts as shouldered whatever the buttons say, so a hip shot still ends
// with a proper `up_to_down` back to rest instead of a snap.
// THE SHOULDERED POSE WAS NEVER REACHING THE SCREEN AT ALL, and that is why the
// _empty fix above would have been invisible on its own.
//
// The old shape computed `pose` correctly and then handed it to SH_SeqIdleDisplay
// as both seq_a and seq_b — and that helper returns a LATCHED sequence for every
// WS_IDLE frame, rewritten only on the non-idle -> idle EDGE or on the 10-15 s
// re-arm roll.  Holding +attack2 does not change the weapon state, so it never
// produced an edge: the latch went on returning whatever pose happened to be
// current at the last edge, `return pose` at the bottom was unreachable while
// idle, and down_to_up / aimed / up_to_down were effectively never rendered.
//
// Fixed by giving the shouldered states their own phase clock and letting the
// idle helper win only when the gun is actually at rest — the same pattern
// CSQC_ShieldDisplayFrame uses (client/cl_weapons.qc:1861).
float csqc_dodat_aim_up;       // 0/1 — the pose we are currently in or heading to
float csqc_dodat_aim_change;   // cltime the CURRENT pose (transition or hold) began
float csqc_dodat_aim_moving;   // TRUE while a down_to_up / up_to_down is still playing

// REWINDING.  > 0 means "we are playing the take we were ALREADY in, backwards,
// starting from this many seconds in".  0 means the normal forward transition.
//
// REVERSE PLAYBACK IS REAL AND COSTS NOTHING.  .frame1time is an absolute position
// into the take, not a delta — server/pr_cmds.c:13255 calls it "the absolute time
// into the animation" — and the studio renderer re-derives the frame pair from it
// on every render with no memory of the previous value
// (engine/gl/gl_hlmdl.c:1271-1277: `frametime *= sequence->timing; if (frametime <
// 0) frametime = 0; frame1 = (int)frametime;`).  The ONLY clamp is on negatives,
// and 0 is exactly where a rewind is meant to stop.  So feeding a DECREASING value
// plays a sequence backwards.  This mod already relies on a non-monotonic sequence
// time elsewhere — the M3's shell-by-shell insert drives a sawtooth.
//
// What it replaces: the edge handler used to stamp the change time unconditionally
// and start the OPPOSITE take from frame 0.  Frame 0 of `up_to_down` is bit-
// identical to `aimed`, so releasing +attack2 a fraction into the raise SNAPPED the
// launcher up to the full shoulder pose — on the Panzerschreck, 77% of the entire
// travel in a single render frame, in the wrong direction — and then took the whole
// 1.0 s lowering take to come back down.  The user asked for the take to run
// backwards from where it got to instead, and that is exactly what this does: an
// early release costs f * duration rather than a full transition.
//
// It cannot pop at either end: `down_to_up` frame 0 is bit-identical to `idle`, and
// `up_to_down` frame 0 is bit-identical to `aimed`, on all three models.
//
// A transition allowed to COMPLETE still plays the authored opposite take, which is
// not a time-mirror of the raise (the lowering takes are heavily eased out) and is
// the better art whenever there is time for it.
float csqc_dodat_aim_rev;

float(float wep, float firing, float mag) CSQC_DodATPoseSeq =
{
    // Was csqc_viewfx_ads_env, the shared ADS envelope.  That envelope is dead for
    // this weapon now (W_DodATEquip passes eligible = FALSE, so there is no view
    // offset to keep in step with) and the shoulder is its OWN state, held in
    // dodat_aim_start.  Reading it here means the pose on screen and the gate in
    // SH_DodATTryFire answer from one field: the launcher is never shouldered-
    // looking while refusing to fire, or firing while it looks lowered.
    float up = firing ? 1 : (predicted_player.dodat_aim_start > 0);

    if (up != csqc_dodat_aim_up)
    {
        // Reverse out of a transition that is still running, in EITHER direction:
        // let go part-way up and the raise rewinds; press again part-way down and
        // the lowering rewinds.  Either way the take on screen does not change, it
        // just starts counting the other way from where it had got to, so there is
        // no pose discontinuity at all.
        if (csqc_dodat_aim_moving)
        {
            float el = cltime - csqc_dodat_aim_change;
            float rd = csqc_dodat_aim_rev;      // already rewinding? invert again
            if (rd > 0)
                csqc_dodat_aim_rev = max(0, rd - el);
            else
                csqc_dodat_aim_rev = min(el, csqc_dodat_aim_up
                                             ? SH_DodATUpDuration(wep)
                                             : SH_DodATDownDuration(wep));
        }
        else
            csqc_dodat_aim_rev = 0;

        csqc_dodat_aim_up     = up;
        csqc_dodat_aim_change = cltime;
        csqc_dodat_aim_moving = TRUE;
    }

    if (csqc_dodat_aim_moving)
    {
        // Duration off the LOADED take deliberately: the PIAT's loaded/empty
        // pairs are frame- and fps-identical, so one clock serves both.
        //
        // While rewinding, the clock runs for exactly as long as the abandoned take
        // had been running — released at fraction f of the raise, the rewind takes
        // f * duration and lands on frame 0.  The seconds-to-frame mapping is
        // linear (`frametime *= sequence->timing`), so f of the time is f of the
        // frames.
        float rewinding = (csqc_dodat_aim_rev > 0);
        float dur = rewinding ? csqc_dodat_aim_rev
                              : (up ? SH_DodATUpDuration(wep) : SH_DodATDownDuration(wep));

        if ((cltime - csqc_dodat_aim_change) < dur)
        {
            // REWINDING KEEPS THE TAKE IT WAS ALREADY PLAYING — which is the take
            // belonging to the stance we are heading AWAY from, i.e. the opposite
            // of the usual pick.
            if (rewinding)
                return up ? SH_DodATSeqDownFor(wep, mag) : SH_DodATSeqUpFor(wep, mag);
            return up ? SH_DodATSeqUpFor(wep, mag) : SH_DodATSeqDownFor(wep, mag);
        }

        csqc_dodat_aim_moving = FALSE;
        csqc_dodat_aim_rev    = 0;
        csqc_dodat_aim_change = cltime;   // the HELD pose starts now, so the hold
                                          // has a clock of its own too
        // Deliberate poke at a shared CSQC global (shared/sh_weapon_standard.qc:539).
        // Settling back to the hip hands the sequence back to SH_SeqIdleDisplay,
        // whose latch is still holding whatever was current at the last idle edge
        // — typically `aimed`, after an ADS shot.  Without this the gun stays
        // visually shouldered until the next re-arm roll, up to 15 seconds later.
        // Safe: only one weapon is drawn at a time and a weapon switch zeroes this
        // anyway (sh_weapon_standard.qc:559).
        if (!up)
            csqc_seqidle_next = 0;
    }

    return up ? SH_DodATSeqAimed(wep) : SH_DodATSeqIdle(wep);
};

float(float elapsed) CSQC_DodATDisplayFrame =
{
    float wep    = predicted_player.weapon;
    float firing = (predicted_player.weaponstate == WS_FIRE);
    // Runs EVERY frame and for every state — it owns the transition latch, so
    // skipping it during a reload would leave a stale edge behind.
    float pose   = CSQC_DodATPoseSeq(wep, firing,
                                     SH_DodATMagOf(predicted_player, wep));

    // Still called FIRST and for EVERY state: it detects the return-to-idle edge
    // by comparing against the previous state it saw (contract at
    // shared/sh_weapon_standard.qc:543).  What changed is that its answer no
    // longer wins while the gun is shouldered or mid-transition — it can only
    // ever hand back a latch, never the live pose we pass it.
    float idle = SH_SeqIdleDisplay(cltime, wep, predicted_player.weaponstate,
                                   pose, pose,
                                   DODAT_IDLE_REARM_MIN, DODAT_IDLE_REARM_MAX);

    // These three are mutually exclusive with WS_IDLE, so moving them above the
    // `idle` return is behaviour-neutral — the helper already returned -1 for
    // them without touching the sequence-time override.
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodATSeqDraw(wep);
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodATSeqReload(wep);
    if (firing)
        return SH_DodATSeqLaunch(wep);

    // Shouldered, or moving either way: drive it from our own phase clock.  The
    // override is what actually reaches .frame1time (cl_weapons.qc:2040) and it
    // is written AFTER the helper so it wins over the helper's own write at
    // sh_weapon_standard.qc:599.  A monotonic phase suits both cases: a
    // non-looping `aimed` clamps to its end pose, a looping one loops.
    if (csqc_dodat_aim_up || csqc_dodat_aim_moving)
    {
        csqc_viewmodel_sequence_time_override = TRUE;
        if (csqc_dodat_aim_moving && csqc_dodat_aim_rev > 0)
            // COUNT DOWN.  See the long note on csqc_dodat_aim_rev — a decreasing
            // .frame1time plays the take backwards, and it reaches 0 after exactly
            // csqc_dodat_aim_rev seconds, on the take's frame 0, which is the pose
            // the gun is returning to.  Seamless at both ends.
            csqc_viewmodel_sequence_time =
                max(0, csqc_dodat_aim_rev - (cltime - csqc_dodat_aim_change));
        else
            csqc_viewmodel_sequence_time = max(0, cltime - csqc_dodat_aim_change);
        return pose;
    }

    if (idle >= 0)
        return idle;
    return pose;
};

void() CSQC_DodATDropClear =
{
    self.mag_dodbazooka = 0;  self.ammo_dodbazooka = 0;
    self.mag_dodschreck = 0;  self.ammo_dodschreck = 0;
    self.mag_dodpiat    = 0;  self.ammo_dodpiat    = 0;
};

void() CSQC_DodATEquipCommon =
{
    float wep = self.weapon;
    // Must match W_DodATEquip exactly — see the note there.  No pose ADS: the
    // launcher's own down_to_up IS the aim.
    W_SetADSProfile(FALSE, "cl_ads_dodat", SCOPE_CLASS_NONE);
    self.weapon_name         = SH_DodATDisplayName(wep);
    self.weapon_viewmodel    = SH_DodATViewModel(wep);
    self.weapon_worldmodel   = SH_DodATWorldModel(wep);
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd    = CSQC_PredictDodATCommand;
    self.csqc_predict_reload = CSQC_PredictDodATReload;
    self.csqc_display_frame  = CSQC_DodATDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodATDropClear;
    self.weapon_uses_sequences = TRUE;
    // DO NOT RESET csqc_dodat_snd_stage HERE.  A CSQC equip is not a one-shot:
    // CSQC_ResetToConfirmedState calls CSQC_WeaponEquip on every reconcile
    // (client/cl_player.qc:1051), i.e. several times a second, so zeroing the
    // sound latch here re-armed it continuously while `elapsed` kept growing —
    // every already-passed event in the draw and reload envelopes fired again on
    // the next frame, for as long as the animation lasted.  That is the reported
    // "repeating sound play when you draw the weapon".  The per-action guard in
    // CSQC_PredictDodATCommand re-arms it exactly once per wep_action_id, which
    // is the correct and sufficient place.  sh_wpn_butterfly.qc:760 documents the
    // same hazard for its idle anchor.
};

void() CSQC_DodBazookaEquip = { CSQC_DodATEquipCommon(); };
void() CSQC_DodSchreckEquip = { CSQC_DodATEquipCommon(); };
void() CSQC_DodPiatEquip    = { CSQC_DodATEquipCommon(); };

#endif // CSQC
