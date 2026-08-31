// ============================================================
//  shared/weapons/sh_wpn_dodauto.qc  -  DoD bipod automatics: Bren, FG42, scoped FG42
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Fire  : lag-compensated hitscan, linear damage falloff, full auto
//  Alt   : ADS (scoped FG42 gets a low-power scope instead)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  ONE FILE, THREE WEAPONS, keyed on self.weapon — the arrangement
//  sh_wpn_dodmgs.qc and sh_wpn_dodat.qc already use.  It earns its keep here:
//  all three carry the IDENTICAL nine-sequence layout, the identical three
//  reload events and the identical draw event, and the FG42 and the scoped FG42
//  are the same model with a sight on it (their sequence tables differ only by
//  a tenth entry, `up_outofway`, which nothing reads).
//
//  NO ASSET SHIPS WITH ANY OF THEM.  Everything resolves out of the mounted dod
//  gamedir.
//
//  MEASURED.  Durations are (frames-1)/fps, which is what SH_SeqDuration
//  returns; every event below is stored as a FRACTION of its own sequence so a
//  differently-timed build of the mount stays in sync.
//
//    dod/models/v_bren.mdl          9 seqs, 57 bones
//      [0] up_idle    12fps 121f 10.000   [1] up_reload  35fps 133f 3.771
//            f22  tommy_reload_clipout    frac 0.1668
//            f92  tommy_reload_clipin     frac 0.6972
//            f108 tommy_draw_slideback    frac 0.8184
//      [2] up_draw    30fps  31f  1.000   f1 rifleselect  frac 0.033
//      [3] up_shoot   25fps  61f  2.400   f1 5001 flash 41, f1 6002 shell 2
//      [4] up_to_down [5] down_idle [6] down_reload [7] down_shoot [8] down_to_up
//    dod/models/v_fg42.mdl          9 seqs, 57 bones   (same layout)
//      up_reload 3.850  clipout 0.1818  clipin 0.6558  slideback 0.8182
//      up_draw   0.933  rifleselect 0.0236
//      up_shoot  2.400  flash 61
//    dod/models/v_scopedfg42.mdl   10 seqs, 52 bones   (v_fg42 + up_outofway)
//
//  THE down_* HALF IS THE BIPOD SET AND IT IS NOW WIRED.  This note used to say it
//  was not, "for exactly the reason sh_wpn_dodbar.qc gives: deploying is a movement
//  stance this mod has no framework for ... so hanging `down_shoot` off a button
//  would hand out the recoil reduction with none of the cost."  That reason has
//  expired: shared/sh_weapons.qc now carries .weapon_deployable / .wep_deployed /
//  SH_DeployLocksPlayer, the flag rides the prediction proxy, and the cost is real
//  and paid — a crouch to plant, and a hard freeze-grade movement lock while down.
//  Five other weapons were already using it when this was rewritten.
//
//  THE BUTTON IS WEAPON SPECIAL (impulse 7), not +attack2, and that is the one
//  place these three differ from the BAR and the machine guns: all three already
//  own +attack2 — the Bren and the FG42 for the ADS hold, the scoped FG42 for its
//  scope, which under sv_codscopes (shipped as 1) belongs to the CoD scope state
//  machine outright.  Putting the bipod on a button that already means something
//  would fight it, so it goes where nothing else is, and all three agree.
//
//  There is no down_draw on any of the three, which is why SH_DodAutoSeqDraw stays
//  single-armed and the guns always come out standing.
//
//  up_shoot RUNS 2.4 s, which is the full muzzle-climb recovery, not one round.
//  It is never seen to the end: at a 0.09-0.12 s trigger the sequence restarts
//  long before it finishes, which is how DoD plays it.  The fire STATE is given
//  the trigger delay instead of the sequence duration — handing 2.4 s to
//  SH_StandardTickState would park the weapon in WS_FIRE and block the reload.
//
//  THE SCOPED FG42 HAS NO WORLD MODEL.  dod/models has w_fg42.mdl but no
//  w_scopedfg42.mdl (checked), so the dropped/pickup model is the plain FG42's.
//  Do NOT "fix" this by naming models/w_scopedfg42.mdl: an unprecached setmodel
//  yields modelindex 0 and the engine drops the entity before it is drawn, which
//  is the invisible-weapon failure sh_customdefs.qc documents.  Its p_ model does
//  exist and is its own (p_fg42s.mdl).

// --- Ammo fields ---
.float mag_dodbren;
.float ammo_dodbren;
.float mag_dodfg42;
.float ammo_dodfg42;
.float mag_dodfg42s;
.float ammo_dodfg42s;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODAUTO_SEQ_IDLE    = 0;
const float DODAUTO_SEQ_RELOAD  = 1;
const float DODAUTO_SEQ_DRAW    = 2;
const float DODAUTO_SEQ_SHOOT   = 3;
// The bipod half, now wired — see the retraction in the header.
const float DODAUTO_SEQ_PLANT   = 4;   // up_to_down
const float DODAUTO_SEQ_DIDLE   = 5;   // down_idle
const float DODAUTO_SEQ_DRELOAD = 6;   // down_reload
const float DODAUTO_SEQ_DSHOOT  = 7;   // down_shoot
const float DODAUTO_SEQ_STANDUP = 8;   // down_to_up

// The bipod's whole point.  Same 0.30 the BAR gets, and for the same reason: it
// sits in the same base-spread bracket and is the same class of weapon.
const float DODAUTO_DEPLOY_SPREAD_SCALE = 0.30;

const float DODAUTO_FRAME_INTERVAL = 0.0333334;
const float DODAUTO_DRYFIRE_DELAY  = 0.20;

const float DODAUTO_IDLE_REARM_MIN = 10;
const float DODAUTO_IDLE_REARM_MAX = 15;

.float dodauto_snd_stage;

// ============================================================
//  SHARED — per-weapon table
// ============================================================

string(float wep) SH_DodAutoViewModel =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "models/v_fg42.mdl";
    case WEP_DODFG42S: return "models/v_scopedfg42.mdl";
    }
    return "models/v_bren.mdl";
};

string(float wep) SH_DodAutoWorldModel =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "models/w_fg42.mdl";
    case WEP_DODFG42S: return "models/w_fg42.mdl";   // no w_scopedfg42.mdl exists — see the header
    }
    return "models/w_bren.mdl";
};

string(float wep) SH_DodAutoDisplayName =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "FG42";
    case WEP_DODFG42S: return "SCOPED FG42";
    }
    return "BREN";
};

string(float wep) SH_DodAutoClassname =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "weapon_fg42";
    case WEP_DODFG42S: return "weapon_scopedfg42";
    }
    return "weapon_bren";
};

string(float wep) SH_DodAutoFireSound =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "weapons/fg42_shoot.wav";
    case WEP_DODFG42S: return "weapons/fg42_shoot.wav";
    }
    return "weapons/bren_shoot.wav";
};

string(float wep) SH_DodAutoADSPrefix =
{
    switch (wep)
    {
    case WEP_DODFG42:  return "cl_ads_dodfg42";
    case WEP_DODFG42S: return "cl_ads_dodfg42s";
    }
    return "cl_ads_dodbren";
};

// --- Balance ---
//
// Three automatics that have to be distinct from each other AND from the BAR
// already in this tree (46/32 over 3400, 20 rounds, 0.120 trigger).
//
//   Bren        30 rds, 0.120 trigger, 45/31 over 3400
//     The BAR with half again the magazine and noticeably less climb — which is
//     the Bren's actual reputation, and the top-mounted magazine is the visual
//     cue.  It pays for it in raw damage (45 vs 46 is nominal) and in carry
//     speed, 0.889, the slowest bracket in the mod.
//   FG42        20 rds, 0.090 trigger, 42/30 over 3200
//     The fastest full-power automatic here at ~670 rpm.  Twenty rounds at that
//     rate is three seconds of fire, and the recoil is the harshest in the file
//     (2.85 pitch against the BAR's 2.60) because a 4.2 kg rifle firing full
//     Mauser on automatic is exactly that unpleasant.
//   Scoped FG42 20 rds, 0.090 trigger, 42/30 over 3200
//     Identical ballistics; the scope IS the upgrade and it costs base spread
//     nothing but costs move spread a great deal (0.135) and carry speed the
//     same as the Bren.  SCOPE_CLASS_RIFLE_LOWPOWER — it stays scoped through
//     automatic fire, like the AUG and the SG552.
float(float wep) SH_DodAutoFireDelay  = { return (wep == WEP_DODBREN) ? 0.120 : 0.090; };
float(float wep) SH_DodAutoMaxMag     = { return (wep == WEP_DODBREN) ? 30 : 20; };
float(float wep) SH_DodAutoMaxAmmo    = { return (wep == WEP_DODBREN) ? 90 : 60; };
float(float wep) SH_DodAutoBaseSpread = { return (wep == WEP_DODBREN) ? 0.013 : 0.014; };
float(float wep) SH_DodAutoMoveSpread =
{
    switch (wep)
    {
    case WEP_DODFG42:  return 0.100;
    case WEP_DODFG42S: return 0.135;
    }
    return 0.092;
};
float(float wep) SH_DodAutoFullSpreadSpeed = { return 320; };
float(float wep) SH_DodAutoCloseDamage     = { return (wep == WEP_DODBREN) ? 45 : 42; };
float(float wep) SH_DodAutoMinDamage       = { return (wep == WEP_DODBREN) ? 31 : 30; };
float(float wep) SH_DodAutoFalloffRange    = { return (wep == WEP_DODBREN) ? 3400 : 3200; };
float(float wep) SH_DodAutoKickPitch       = { return (wep == WEP_DODBREN) ? 2.30 : 2.85; };
float(float wep) SH_DodAutoKickVariance    = { return (wep == WEP_DODBREN) ? 0.48 : 0.60; };
float(float wep) SH_DodAutoKickStrength    = { return (wep == WEP_DODBREN) ? 1.35 : 1.50; };

const float DODAUTO_MUZZLE_FORWARD = 46;
const float DODAUTO_MUZZLE_RIGHT   = 3.5;
const float DODAUTO_MUZZLE_DOWN    = 3;

// Event marks as fractions of their own sequence.  The Bren's reload is 3.771 s
// and the FG42 family's 3.850 s, and their marks do not line up, so this is a
// two-row table rather than one set of constants.
float(float wep) SH_DodAutoReloadFClipout   = { return (wep == WEP_DODBREN) ? 0.1668 : 0.1818; };
float(float wep) SH_DodAutoReloadFClipin    = { return (wep == WEP_DODBREN) ? 0.6972 : 0.6558; };
float(float wep) SH_DodAutoReloadFSlideback = { return (wep == WEP_DODBREN) ? 0.8184 : 0.8182; };
// Just after the magazine seats, before the bolt goes forward.
float(float wep) SH_DodAutoReloadFApply     = { return (wep == WEP_DODBREN) ? 0.7200 : 0.6800; };
float(float wep) SH_DodAutoDrawFSelect      = { return (wep == WEP_DODBREN) ? 0.0330 : 0.0236; };

// ============================================================
//  SHARED — sequence resolution
// ============================================================

// Every pose takes the stance as a PARAMETER rather than reading self, because the
// CSQC display path runs with self set to the viewmodel entity and has to pass
// predicted_player.wep_deployed in.  Same arrangement as sh_wpn_dodbar.qc.
float(float wep, float dep) SH_DodAutoSeqIdle =
{
    if (dep) return SH_SeqForName(SH_DodAutoViewModel(wep), "down_idle", DODAUTO_SEQ_DIDLE);
    return         SH_SeqForName(SH_DodAutoViewModel(wep), "up_idle",   DODAUTO_SEQ_IDLE);
};
float(float wep, float dep) SH_DodAutoSeqReload =
{
    if (dep) return SH_SeqForName(SH_DodAutoViewModel(wep), "down_reload", DODAUTO_SEQ_DRELOAD);
    return         SH_SeqForName(SH_DodAutoViewModel(wep), "up_reload",   DODAUTO_SEQ_RELOAD);
};
float(float wep, float dep) SH_DodAutoSeqShoot =
{
    if (dep) return SH_SeqForName(SH_DodAutoViewModel(wep), "down_shoot", DODAUTO_SEQ_DSHOOT);
    return         SH_SeqForName(SH_DodAutoViewModel(wep), "up_shoot",   DODAUTO_SEQ_SHOOT); };

// ONE draw take on all three models — there is no down_draw.  These are always
// picked up off the shoulder, exactly like the BAR.
float(float wep) SH_DodAutoSeqDraw   = { return SH_SeqForName(SH_DodAutoViewModel(wep), "up_draw",   DODAUTO_SEQ_DRAW); };

// The stance pair.  The take that plays is the one LEAVING the current stance,
// because .wep_deployed does not flip until it ends.
float(float wep) SH_DodAutoSeqPlant   = { return SH_SeqForName(SH_DodAutoViewModel(wep), "up_to_down", DODAUTO_SEQ_PLANT); };
float(float wep) SH_DodAutoSeqStandUp = { return SH_SeqForName(SH_DodAutoViewModel(wep), "down_to_up", DODAUTO_SEQ_STANDUP); };
float(float wep, float dep) SH_DodAutoSeqStance =
{ return dep ? SH_DodAutoSeqStandUp(wep) : SH_DodAutoSeqPlant(wep); };

float(float wep) SH_DodAutoDrawDuration =
{
    return SH_SeqDuration(SH_DodAutoViewModel(wep), SH_DodAutoSeqDraw(wep),
                          (wep == WEP_DODBREN) ? 1.000 : 0.933);
};
// The bipod reload is its OWN length on every model — the Bren's is 0.800 s longer
// than the standing one — so the stance has to reach this too, or the magazine
// lands at the wrong moment and the take is cut or held.
float(float wep, float dep) SH_DodAutoReloadDuration =
{
    float fb;
    if (wep == WEP_DODBREN) fb = dep ? 4.571 : 3.771;
    else                    fb = dep ? 3.714 : 3.850;
    return SH_SeqDuration(SH_DodAutoViewModel(wep), SH_DodAutoSeqReload(wep, dep), fb);
};

float(float wep, float dep) SH_DodAutoStanceDuration =
{
    if (dep) return SH_SeqDuration(SH_DodAutoViewModel(wep), SH_DodAutoSeqStandUp(wep),
                                   (wep == WEP_DODBREN) ? 1.575 : 0.978);
    return         SH_SeqDuration(SH_DodAutoViewModel(wep), SH_DodAutoSeqPlant(wep),
                                   (wep == WEP_DODBREN) ? 1.286 : 1.200);
};

// The LIVE spread — base, scaled by the bipod.  SH_DodAutoBaseSpread stays the
// standing number so the crosshair profile and the balance comments still read as
// one value per gun.
float(float wep) SH_DodAutoSpread =
{
    if (self.wep_deployed)
        return SH_DodAutoBaseSpread(wep) * DODAUTO_DEPLOY_SPREAD_SCALE;
    return SH_DodAutoBaseSpread(wep);
};

// +attack2 is NOT available on these three.  The Bren and the FG42 use it for the
// ADS hold, and the scoped FG42's is owned outright by the scope (and by the CoD
// scope state machine under sv_codscopes, which cfg/server.cfg ships as 1).  So the
// bipod goes on WEAPON SPECIAL — impulse 7 — for all three, which also keeps them
// consistent with each other.
//
// That means the hand-written else-if chain under WEAPON_IMPULSE_SPECIAL in
// client/cl_weapons.qc must carry all three, or the plant happens server-side and
// the viewmodel never moves.
float(float now) SH_DodAutoTryStance =
{
    if (Weapon_LowerBlocksFire()) return FALSE;
    if (self.weaponstate != WS_IDLE) return FALSE;
    if (now < self.attack_finished)  return FALSE;
    // CROUCH TO PLANT, and standing back up is always free — the same gate and the
    // same reasoning as SH_DodMortarTryStance.
    if (!self.wep_deployed
        && !((self.flags & FL_DUCKING) && (self.flags & FL_ONGROUND)))
        return FALSE;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SH_DodAutoStanceDuration(self.weapon, self.wep_deployed);
    return TRUE;
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float wep) SH_DodAutoMag =
{
    switch (wep)
    {
    case WEP_DODFG42:  return self.mag_dodfg42;
    case WEP_DODFG42S: return self.mag_dodfg42s;
    }
    return self.mag_dodbren;
};

// NOT the shoot sequence's duration for the fire state — see the header.
float(float now) SH_DodAutoTickState =
{
    float wep = self.weapon;

    // WS_SPECIAL is the plant / stand-up take.  Handled before the standard
    // driver, which has no arm for it and would leave the gun in an animation that
    // never ends.
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodAutoStanceDuration(wep, self.wep_deployed))
        {
            self.wep_deployed = !self.wep_deployed;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_DodAutoReloadDuration(wep, self.wep_deployed);
    float dr  = SH_DodAutoDrawDuration(wep);
    float fd  = SH_DodAutoFireDelay(wep);
    float ap  = rel * SH_DodAutoReloadFApply(wep);

    switch (wep)
    {
    case WEP_DODFG42:
        return SH_StandardTickState(now, mag_dodfg42, ammo_dodfg42, SH_DodAutoMaxMag(wep),
                                    dr, fd, rel, ap);
    case WEP_DODFG42S:
        return SH_StandardTickState(now, mag_dodfg42s, ammo_dodfg42s, SH_DodAutoMaxMag(wep),
                                    dr, fd, rel, ap);
    }
    return SH_StandardTickState(now, mag_dodbren, ammo_dodbren, SH_DodAutoMaxMag(wep),
                                dr, fd, rel, ap);
};

float(float now) SH_DodAutoTryFire =
{
    float wep = self.weapon;
    float fd  = SH_DodAutoFireDelay(wep);

    switch (wep)
    {
    case WEP_DODFG42:  return SH_StandardTryFire(now, mag_dodfg42,  fd, DODAUTO_DRYFIRE_DELAY);
    case WEP_DODFG42S: return SH_StandardTryFire(now, mag_dodfg42s, fd, DODAUTO_DRYFIRE_DELAY);
    }
    return SH_StandardTryFire(now, mag_dodbren, fd, DODAUTO_DRYFIRE_DELAY);
};

float(float now) SH_DodAutoTryReload =
{
    float wep = self.weapon;
    // Not mid-plant: the stance take owns both hands, and letting R cancel it
    // would leave .wep_deployed and the animation disagreeing.
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    float rel = SH_DodAutoReloadDuration(wep, self.wep_deployed);

    switch (wep)
    {
    case WEP_DODFG42:
        return SH_StandardTryReload(now, mag_dodfg42, ammo_dodfg42, SH_DodAutoMaxMag(wep), rel);
    case WEP_DODFG42S:
        return SH_StandardTryReload(now, mag_dodfg42s, ammo_dodfg42s, SH_DodAutoMaxMag(wep), rel);
    }
    return SH_StandardTryReload(now, mag_dodbren, ammo_dodbren, SH_DodAutoMaxMag(wep), rel);
};

// Scope toggle — the scoped FG42 only.  Same shape as SH_AWPTryAltFire including
// the sv_codscopes short-circuit: in CoD mode cl_codscope.qc owns scope visuals
// and a second zoom stage fighting it produces a doubled FOV step.
float(float now) SH_DodAutoTryAltFire =
{
    if (self.weapon != WEP_DODFG42S)
        return 0;
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    // Two stages — the ZF4 is a fixed 4x, there is no half-zoom.
    if (self.zoomstage >= 1)
        self.zoomstage = 0;
    else
        self.zoomstage = 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodAutoPickupCopy =
{
    player.mag_dodbren  = self.mag_dodbren;   player.ammo_dodbren  = self.ammo_dodbren;
    player.mag_dodfg42  = self.mag_dodfg42;   player.ammo_dodfg42  = self.ammo_dodfg42;
    player.mag_dodfg42s = self.mag_dodfg42s;  player.ammo_dodfg42s = self.ammo_dodfg42s;
};

void() W_DodAutoShoot =
{
    float wep = self.weapon;
    // SH_DodAutoSpread, not the base — the bipod is what this weapon's accuracy
    // is for.  The crosshair profile in the Equip keeps the STANDING number, the
    // same split sh_wpn_dodbar.qc uses.
    W_PenetratingHitscanShoot(SH_DodAutoSpread(wep), SH_DodAutoMoveSpread(wep),
        SH_DodAutoFullSpreadSpeed(wep),
        SH_DodAutoCloseDamage(wep), SH_DodAutoMinDamage(wep), SH_DodAutoFalloffRange(wep),
        80, 0.98,
        SH_DodAutoKickPitch(wep), SH_DodAutoKickVariance(wep), SH_DodAutoKickStrength(wep));
};

void() W_DodAutoFire =
{
    float r = SH_DodAutoTryFire(time);

    if (r == 1)
    {
        self.weaponframe       = SH_DodAutoSeqShoot(self.weapon, self.wep_deployed);
        self.wep_nextframe     = time + DODAUTO_FRAME_INTERVAL;
        self.dodauto_snd_stage = 0;

        W_DodAutoShoot();

        sound(self, CHAN_WEAPON, SH_DodAutoFireSound(self.weapon), 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodAutoAltFire =
{
    if (SH_DodAutoTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 1, ATTN_NORM);
    }
};

// Weapon special (impulse 7) — plant on the bipod, or pick the gun back up.
void() W_DodAutoStance =
{
    if (SH_DodAutoTryStance(time))
    {
        self.weaponframe       = SH_DodAutoSeqStance(self.weapon, self.wep_deployed);
        self.wep_nextframe     = time + DODAUTO_FRAME_INTERVAL;
        self.dodauto_snd_stage = 0;
    }
};

void() W_DodAutoReload =
{
    if (SH_DodAutoTryReload(time))
    {
        self.weaponframe       = SH_DodAutoSeqReload(self.weapon, self.wep_deployed);
        self.wep_nextframe     = time + DODAUTO_FRAME_INTERVAL;
        self.dodauto_snd_stage = 0;
    }
};

void() W_DodAutoFrame =
{
    float wep     = self.weapon;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODAUTO_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodAutoDrawDuration(wep) * SH_DodAutoDrawFSelect(wep)
            && self.dodauto_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodauto_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodAutoReloadDuration(wep, self.wep_deployed);

        if (elapsed >= rel * SH_DodAutoReloadFClipout(wep) && self.dodauto_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodauto_snd_stage = 1;
        }
        if (elapsed >= rel * SH_DodAutoReloadFClipin(wep) && self.dodauto_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodauto_snd_stage = 2;
        }
        if (elapsed >= rel * SH_DodAutoReloadFSlideback(wep) && self.dodauto_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodauto_snd_stage = 3;
        }
    }

    float result = SH_DodAutoTickState(time);
    if (result & 1)
    {
        // wep_deployed may have just flipped inside the tick, so it is re-read
        // rather than cached at the top of the frame.
        self.weaponframe       = SH_DodAutoSeqIdle(wep, self.wep_deployed);
        self.wep_nextframe     = 0;
        self.dodauto_snd_stage = 0;
    }
};

void() W_DodAutoEquip =
{
    float wep = self.weapon;
    if (wep == WEP_DODFG42S)
        W_SetADSProfile(FALSE, SH_DodAutoADSPrefix(wep), SCOPE_CLASS_RIFLE_LOWPOWER);
    else
        W_SetADSProfile(TRUE, SH_DodAutoADSPrefix(wep), SCOPE_CLASS_NONE);

    W_StandardEquipSetup(SH_DodAutoViewModel(wep), SH_DodAutoDisplayName(wep),
        SH_DodAutoSeqDraw(wep), DODAUTO_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodAutoFire;
    self.reload   = W_DodAutoReload;
    self.wepframe = W_DodAutoFrame;
    self.shoot    = W_DodAutoShoot;
    self.altfire  = (wep == WEP_DODFG42S) ? W_DodAutoAltFire : __NULL__;
    // THE BIPOD IS ON WEAPON SPECIAL (impulse 7), not +attack2 — see the note on
    // SH_DodAutoTryStance.  All three, so they behave the same as each other.
    self.special  = W_DodAutoStance;
    self.dodauto_snd_stage = 0;
    // ALWAYS COMES OUT STANDING.  There is only an up_draw take on all three, so a
    // gun that remembered its bipod would draw into a stance its own animation does
    // not depict — and would hand the player a movement lock they did not ask for
    // on a weapon switch.
    self.wep_deployed      = 0;
    self.weapon_deployable = TRUE;
    W_ClearZoom();
    W_SetCrosshairProfile(SH_DodAutoBaseSpread(wep), SH_DodAutoMoveSpread(wep),
                          SH_DodAutoFullSpreadSpeed(wep), 1.85, (wep != WEP_DODFG42S));
};

void() W_DodAutoDrop =
{
    entity tgt = weapon_drop_target;
    float  wep = self.weapon;

    tgt.mag_dodbren  = self.mag_dodbren;   tgt.ammo_dodbren  = self.ammo_dodbren;
    tgt.mag_dodfg42  = self.mag_dodfg42;   tgt.ammo_dodfg42  = self.ammo_dodfg42;
    tgt.mag_dodfg42s = self.mag_dodfg42s;  tgt.ammo_dodfg42s = self.ammo_dodfg42s;

    self.mag_dodbren  = 0;  self.ammo_dodbren  = 0;
    self.mag_dodfg42  = 0;  self.ammo_dodfg42  = 0;
    self.mag_dodfg42s = 0;  self.ammo_dodfg42s = 0;

    setmodel(tgt, SH_DodAutoWorldModel(wep));
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = SH_DodAutoClassname(wep);
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = wep;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodAutoEquip;
    tgt.weap_drop_func = W_DodAutoDrop;
    tgt.pickupcopy     = W_DodAutoPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void(float wep) W_DodAutoSpawnCommon =
{
    setmodel(self, SH_DodAutoWorldModel(wep));
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = SH_DodAutoClassname(wep);
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = wep;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodAutoEquip;
    self.weap_drop_func = W_DodAutoDrop;
    self.pickupcopy     = W_DodAutoPickupCopy;
    self.touch          = weapon_touch;
};

void() weapon_bren =
{
    W_DodAutoSpawnCommon(WEP_DODBREN);
    self.mag_dodbren  = SH_DodAutoMaxMag(WEP_DODBREN);
    self.ammo_dodbren = SH_DodAutoMaxAmmo(WEP_DODBREN);
    W_RegisterMapWeapon(weapon_bren);
};

void() weapon_fg42 =
{
    W_DodAutoSpawnCommon(WEP_DODFG42);
    self.mag_dodfg42  = SH_DodAutoMaxMag(WEP_DODFG42);
    self.ammo_dodfg42 = SH_DodAutoMaxAmmo(WEP_DODFG42);
    W_RegisterMapWeapon(weapon_fg42);
};

void() weapon_scopedfg42 =
{
    W_DodAutoSpawnCommon(WEP_DODFG42S);
    self.mag_dodfg42s  = SH_DodAutoMaxMag(WEP_DODFG42S);
    self.ammo_dodfg42s = SH_DodAutoMaxAmmo(WEP_DODFG42S);
    W_RegisterMapWeapon(weapon_scopedfg42);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodauto_snd_stage;
float csqc_dodauto_snd_action;

void() CSQC_PredictDodAutoCommand =
{
    float r;
    float wep = self.weapon;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodauto_snd_action)
    {
        csqc_dodauto_snd_action = predicted_player.wep_action_id;
        csqc_dodauto_snd_stage  = 0;
    }

    // +attack2 — the scoped FG42's LEGACY scope toggle (the other two carry the
    // ADS hold instead, and SH_DodAutoTryAltFire refuses for them).  See the long
    // note at the same arm in sh_wpn_dodspring.qc: .zoomstage is client-local and
    // never reconciled, so a server-only toggle never reached the copy the
    // renderer reads.
    if (input_buttons & 4)
    {
        if (SH_DodAutoTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (input_buttons & 1)
    {
        r = SH_DodAutoTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, SH_DodAutoFireSound(wep), 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SH_DodAutoSpread(wep), SH_DodAutoMoveSpread(wep),
                    SH_DodAutoFullSpreadSpeed(wep),
                    SH_DodAutoCloseDamage(wep), SH_DodAutoMinDamage(wep), SH_DodAutoFalloffRange(wep),
                    80, 0.98,
                    SH_DodAutoKickPitch(wep), SH_DodAutoKickVariance(wep), SH_DodAutoKickStrength(wep));
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODAUTO_MUZZLE_FORWARD, DODAUTO_MUZZLE_RIGHT,
                    DODAUTO_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODAUTO_MUZZLE_FORWARD, DODAUTO_MUZZLE_RIGHT,
                    DODAUTO_MUZZLE_DOWN, self.wep_action_id, 3);
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
            if (csqc_dodauto_snd_stage < 1
                && elapsed >= SH_DodAutoDrawDuration(wep) * SH_DodAutoDrawFSelect(wep))
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodauto_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodAutoReloadDuration(wep, self.wep_deployed);

            if (csqc_dodauto_snd_stage < 1 && elapsed >= rel * SH_DodAutoReloadFClipout(wep))
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodauto_snd_stage = 1;
            }
            if (csqc_dodauto_snd_stage < 2 && elapsed >= rel * SH_DodAutoReloadFClipin(wep))
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodauto_snd_stage = 2;
            }
            if (csqc_dodauto_snd_stage < 3 && elapsed >= rel * SH_DodAutoReloadFSlideback(wep))
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodauto_snd_stage = 3;
            }
        }
    }

    // Mark the ack at the stance FLIP as well as at the press, or reconcile stomps
    // the predicted flip for a full RTT — see the long note at the same place in
    // sh_wpn_dodbar.qc.
    float auto_pre_dep = self.wep_deployed;
    SH_DodAutoTickState(csqc_pred_time);
    if (self.wep_deployed != auto_pre_dep)
        CSQC_MarkPendingWeaponAck();
};

void() CSQC_PredictDodAutoReload =
{
    if (SH_DodAutoTryReload(csqc_pred_time))
    {
        csqc_dodauto_snd_stage  = 0;
        csqc_dodauto_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Weapon special (impulse 7) — the bipod.  Dispatched from
// CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL chain in client/cl_weapons.qc,
// which is a hand-written else-if over self.weapon: a predictor that is not added
// to that list never runs, and the plant then happens server-side only, where the
// viewmodel cannot see it.
void() CSQC_PredictDodAutoSpecial =
{
    if (SH_DodAutoTryStance(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_dodauto_snd_stage  = 0;
        csqc_dodauto_snd_action = predicted_player.wep_action_id;
    }
};

float(float elapsed) CSQC_DodAutoDisplayFrame =
{
    float wep  = predicted_player.weapon;
    float dep  = predicted_player.wep_deployed;
    float pose = SH_DodAutoSeqIdle(wep, dep);

    // The stance is folded into the latch key so a stance change that happens while
    // the weapon is already idle forces a re-pick — see the note at the same call
    // in sh_wpn_dodbar.qc.
    float idle = SH_SeqIdleDisplay(cltime, wep + (dep ? 4096 : 0),
                                   predicted_player.weaponstate,
                                   pose, pose,
                                   DODAUTO_IDLE_REARM_MIN, DODAUTO_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodAutoSeqDraw(wep);
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodAutoSeqReload(wep, dep);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodAutoSeqShoot(wep, dep);
    // The stance change.  The flag has not flipped yet — it flips when the take
    // ends — so SH_DodAutoSeqStance returns the one leaving the current stance.
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodAutoSeqStance(wep, dep);

    return pose;
};

void() CSQC_DodAutoDropClear =
{
    self.mag_dodbren  = 0;  self.ammo_dodbren  = 0;
    self.mag_dodfg42  = 0;  self.ammo_dodfg42  = 0;
    self.mag_dodfg42s = 0;  self.ammo_dodfg42s = 0;
};

// CSQC_WeaponEquip sets self.weapon BEFORE calling these, so the common body can
// read it.  DO NOT reset csqc_dodauto_snd_stage in here — CSQC_WeaponEquip runs
// on every reconcile (client/cl_player.qc:1051), so a latch cleared here is
// re-armed several times a second and every already-passed sound event replays.
// That was a real, shipped bug on the MGs and the AT launchers.
void() CSQC_DodAutoEquipCommon =
{
    float wep = self.weapon;
    if (wep == WEP_DODFG42S)
        W_SetADSProfile(FALSE, SH_DodAutoADSPrefix(wep), SCOPE_CLASS_RIFLE_LOWPOWER);
    else
        W_SetADSProfile(TRUE, SH_DodAutoADSPrefix(wep), SCOPE_CLASS_NONE);

    self.weapon_name         = SH_DodAutoDisplayName(wep);
    self.weapon_viewmodel    = SH_DodAutoViewModel(wep);
    self.weapon_worldmodel   = SH_DodAutoWorldModel(wep);
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd    = CSQC_PredictDodAutoCommand;
    self.csqc_predict_reload = CSQC_PredictDodAutoReload;
    self.csqc_display_frame  = CSQC_DodAutoDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodAutoDropClear;
    self.weapon_uses_sequences = TRUE;
    // Arms the shared movement lock on the client's copy too — CSQC runs
    // Weapon_SpeedFactor_Smooth and SH_DeployLocksPlayer in its own pmove.
    //
    // NOT accompanied by a wep_deployed reset: this function re-runs on every
    // reconcile, so zeroing the stance here would unplant the gun 20 times a
    // second.  The SERVER's W_DodAutoEquip clears it on a real weapon switch and
    // the prediction proxy carries that across.
    self.weapon_deployable = TRUE;
};

void() CSQC_DodBrenEquip    = { CSQC_DodAutoEquipCommon(); };
void() CSQC_DodFG42Equip    = { CSQC_DodAutoEquipCommon(); };
void() CSQC_DodFG42SEquip   = { CSQC_DodAutoEquipCommon(); };

#endif // CSQC
