// ============================================================
//  shared/weapons/sh_wpn_csxm1014.qc  -  Counter-Strike Benelli XM1014
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 7-shell tube, 32 reserve, SEMI-AUTOMATIC 12-gauge
//  Fire  : multi-pellet hitscan, linear damage falloff
//  Load  : shell by shell, enter -> N inserts -> exit
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// No asset ships with this weapon: models/v_xm1014.mdl, models/w_xm1014.mdl and
// every sound below resolve on the mounted cstrike gamedir (fs_addons.txt:16).
// See the header of shared/weapons/sh_wpn_csaug.qc for the full note.
//
// ============================================================
//  THE ONE THING THAT MAKES THIS FILE DIFFERENT
// ============================================================
//
// It is the first SEQUENCE-DRIVEN shell-by-shell reload in the tree.  The CS M3
// (sh_wpn_csm3.qc) already does shell-by-shell, but against a flat IDPO frame
// bake: it owns a frame counter, steps it every tick, and loops it back from
// M3_RELOAD_LOOP_END to M3_RELOAD_LOOP_RESTART.  cstrike/models/v_xm1014.mdl has
// no such range — the three parts of its reload are three separate SEQUENCES:
//
//     [5] start_reload   0.667s     the shooter brings the gun down
//     [3] insert         0.389s     ONE shell into the tube
//     [4] after_reload   0.400s     the gun comes back up
//
// so the loop has to be expressed as time rather than as frames.
//
// THE PLAN IS FIXED AT RELOAD START, exactly as the M3's is.  The moment the
// reload begins, both sides compute
//
//     shells = min(MAX_MAG - mag, ammo)
//
// from state they both already hold, and the whole reload becomes a timeline of
// known length:
//
//     enter + shells * insert + exit
//
// Nothing consults mag or ammo again mid-reload, so the server and the client
// walk the same timeline from the same start stamp and cannot disagree.  It also
// means, deliberately, that a reload cannot be cut short by firing partway
// through — the M3 behaves the same way and for the same reason, and making
// either interruptible is a change to both files, not to this one.
//
// The insert SEQUENCE has to be restarted for each shell, which a plain
// .frame = seq cannot do: the engine clamps a non-looping sequence to its final
// frame (gl_hlmdl.c:1076-1082), so the second shell onwards would show a frozen
// pose.  CSQC_XM1014DisplayFrame therefore drives
// csqc_viewmodel_sequence_time_override / csqc_viewmodel_sequence_time with the
// time INSIDE the current insert, which restarts the take each iteration.  That is
// the same mechanism SH_SeqIdleDisplay uses to re-send a non-looping idle.
//
// ============================================================
//  MEASURED FROM cstrike/models/v_xm1014.mdl
// ============================================================
//
//   [0] idle          12fps   9f  0.667s
//   [1] shoot1        40fps  21f  0.500s   f0 5001 muzzleflash
//   [2] shoot2        40fps  21f  0.500s   f0 5001
//   [3] insert        90fps  36f  0.389s   (no event — see the sound note below)
//   [4] after_reload  30fps  13f  0.400s   (no event)
//   [5] start_reload  30fps  21f  0.667s
//         f20 "items/cliprelease1.wav"   frac 1.0000
//   [6] draw          30fps  31f  1.000s
//         f1  "weapons/de_deploy.wav"    frac 0.0333
//
// TWO OF THE THREE RELOAD SEQUENCES CARRY NO SOUND EVENT, so unlike every other
// weapon in this set the QC has to supply those itself.  The only shell-insert
// sample anywhere on the mount is weapons/m3_insertshell.wav — Counter-Strike
// shares one shell-chambering sample across both of its shotguns — so that is
// what plays, and it is named here rather than silently borrowed.  after_reload
// gets nothing: the XM1014 is gas-operated and has no pump stroke to hear, which
// is exactly why its exit take is a third the length of the M3's.

// --- Ammo fields ---
.float mag_xm1014;
.float ammo_xm1014;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY — everything resolves by NAME through SH_SeqForName, because
// cstrike and czero are both mounted and ship this model at different fps.
const float CSXM1014_SEQ_IDLE    = 0;
const float CSXM1014_SEQ_SHOOT1  = 1;
const float CSXM1014_SEQ_SHOOT2  = 2;
const float CSXM1014_SEQ_INSERT  = 3;
const float CSXM1014_SEQ_AFTER   = 4;
const float CSXM1014_SEQ_START   = 5;
const float CSXM1014_SEQ_DRAW    = 6;

const float CSXM1014_FRAME_INTERVAL = 0.0333334;   // state-machine tick rate

// SEMI-AUTOMATIC.  This is the whole difference from the M3 in the hand: no pump
// stroke between shots, so the trigger can be pulled again as soon as the delay
// expires.  CS 1.6 cycles it in 0.25 s against the M3's 0.875; 0.30 here keeps
// the M3 comfortably slower without handing this gun the whole close range.
const float CSXM1014_FIRE_DELAY     = 0.30;
const float CSXM1014_DRYFIRE_DELAY  = 0.20;

// Event marks as a FRACTION of their sequence, never absolute seconds.
const float CSXM1014_DRAW_F_DEPLOY  = 0.0333;   // frame  1 / 30
const float CSXM1014_START_F_RELEASE = 0.97;    // model says frame 20/20 = 1.0000
// The model's own event sits on the LAST frame of start_reload.  A mark tested
// with `elapsed >= dur * 1.0` can be skipped entirely, because the timeline moves
// on to the first insert at exactly that instant and no tick is guaranteed to
// land on it.  Pulled just inside the end so it always fires once.
const float CSXM1014_INSERT_F_SHELL = 0.35;     // where in the take the shell seats

const float MAX_MAG_CSXM1014        = 7;
const float MAX_AMMO_CSXM1014       = 32;

// --- Balance ---
//
// Placed against the mod's own M3 (sh_wpn_csm3.qc: 12 pellets, 15/4, one shot a
// second) rather than against CS 1.6's raw numbers, and the placement is the
// whole point of the weapon:
//
//   M3       12 pellets x 15 = 180 a shell, every 1.00 s  ->  180 dps
//   XM1014    8 pellets x 11 =  88 a shell, every 0.30 s  ->  293 dps
//
// which reproduces CS 1.6's relationship — the XM1014 loses badly on the single
// shell (CS gives it 6 pellets of 20 against the M3's 9 of 26) and wins on
// sustained output because it does not pump.  It costs 3000 against the M3's
// 1800 for exactly that.  Spread is a shade wider and reach identical, so the
// trade is decided at range by the smaller pellet count rather than by falloff.
const float CSXM1014_PELLETS              = 8;
const float CSXM1014_SPREAD               = 0.085;
const float CSXM1014_PELLET_CLOSE_DAMAGE  = 11;
const float CSXM1014_PELLET_MIN_DAMAGE    = 3;
const float CSXM1014_PELLET_FALLOFF_RANGE = 1024;
const float CSXM1014_KICK_PITCH    = 2.2;   // sv_gunkick — one impulse per trigger
const float CSXM1014_KICK_VARIANCE = 0.55;  // pull, not per pellet.  Below the M3's
const float CSXM1014_KICK_STRENGTH = 1.40;  // 2.5/0.6/1.5: no pump means less heave.

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from the
// M3, which is the closest gun in the tree by length and grip.
const float CSXM1014_MUZZLE_FORWARD = 44;
const float CSXM1014_MUZZLE_RIGHT   = 8.0;
const float CSXM1014_MUZZLE_DOWN    = 4.2;

const string CSXM1014_VIEWMODEL    = "models/v_xm1014.mdl";
const string CSXM1014_WORLDMODEL   = "models/w_xm1014.mdl";
const string CSXM1014_DEPLOY_SOUND = "";
const string CSXM1014_DISPLAY_NAME = "XM1014";

// Reload bookkeeping.  `shells` is the plan fixed at reload start; `inserted` is
// how much of it has been paid out.  Both live on the entity because the SERVER
// walks them; CSQC keeps its own pair below for the predicted half.
.float csxm1014_shells;
.float csxm1014_inserted;
.float csxm1014_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSXM1014SeqIdle   = { return SH_SeqForName(CSXM1014_VIEWMODEL, "idle",         CSXM1014_SEQ_IDLE); };
float() SH_CSXM1014SeqShoot1 = { return SH_SeqForName(CSXM1014_VIEWMODEL, "shoot1",       CSXM1014_SEQ_SHOOT1); };
float() SH_CSXM1014SeqShoot2 = { return SH_SeqForName(CSXM1014_VIEWMODEL, "shoot2",       CSXM1014_SEQ_SHOOT2); };
float() SH_CSXM1014SeqInsert = { return SH_SeqForName(CSXM1014_VIEWMODEL, "insert",       CSXM1014_SEQ_INSERT); };
float() SH_CSXM1014SeqAfter  = { return SH_SeqForName(CSXM1014_VIEWMODEL, "after_reload", CSXM1014_SEQ_AFTER); };
float() SH_CSXM1014SeqStart  = { return SH_SeqForName(CSXM1014_VIEWMODEL, "start_reload", CSXM1014_SEQ_START); };
float() SH_CSXM1014SeqDraw   = { return SH_SeqForName(CSXM1014_VIEWMODEL, "draw",         CSXM1014_SEQ_DRAW); };

float() SH_CSXM1014DrawDuration   = { return SH_SeqDuration(CSXM1014_VIEWMODEL, SH_CSXM1014SeqDraw(),   1.000); };
float() SH_CSXM1014EnterDuration  = { return SH_SeqDuration(CSXM1014_VIEWMODEL, SH_CSXM1014SeqStart(),  0.667); };
float() SH_CSXM1014InsertDuration = { return SH_SeqDuration(CSXM1014_VIEWMODEL, SH_CSXM1014SeqInsert(), 0.389); };
float() SH_CSXM1014ExitDuration   = { return SH_SeqDuration(CSXM1014_VIEWMODEL, SH_CSXM1014SeqAfter(),  0.400); };

// Total length of a reload that pays out `shells` shells.  The single place that
// arithmetic is written; every other caller asks here.
float(float shells) SH_CSXM1014ReloadTotal =
{
    return SH_CSXM1014EnterDuration()
         + shells * SH_CSXM1014InsertDuration()
         + SH_CSXM1014ExitDuration();
};

// Deterministic shoot-take pick — parity of wep_action_id, the same idiom
// SH_M3FireVariantIsAlt uses, so server and client always agree.
float(float action_id) SH_CSXM1014PickShootSeq =
{
    return (action_id & 1) ? SH_CSXM1014SeqShoot2() : SH_CSXM1014SeqShoot1();
};

// ============================================================
//  SHARED — state machine
// ============================================================
//
// Hand-rolled rather than SH_StandardTickState, for the same reason the M3's is:
// the reload is not one sequence of one length, so there is no single duration to
// hand the standard driver.  WS_DRAW and WS_FIRE are ordinary and could use it;
// keeping all three arms here means one timeline to read.
//
// Returns 1 when it transitioned to idle, matching the standard driver's contract
// so the callers' `if (result & 1)` reads the same as every other weapon's.
float(float now, float shells) SH_CSXM1014TickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSXM1014DrawDuration()) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_SeqDuration(CSXM1014_VIEWMODEL, self.weaponframe, 0.5))
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_CSXM1014ReloadTotal(shells)) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_CSXM1014TryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished)  return 0;

    if (self.mag_xm1014 <= 0)
    { self.attack_finished = now + CSXM1014_DRYFIRE_DELAY; return -1; }

    self.mag_xm1014   -= 1;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;

    // Phase-locked advance, as SH_StandardTryFire does: a semi-auto shotgun held
    // down should keep an even cadence rather than drifting a tick at a time.
    if (now - self.attack_finished < CSXM1014_FIRE_DELAY)
        self.attack_finished += CSXM1014_FIRE_DELAY;
    else
        self.attack_finished  = now + CSXM1014_FIRE_DELAY;
    return 1;
};

float(float now) SH_CSXM1014TryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_xm1014 >= MAX_MAG_CSXM1014 || self.ammo_xm1014 <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// The plan, computed identically on both sides from pre-reload mag and ammo.
float() SH_CSXM1014PlannedShells =
{
    float n = min(MAX_MAG_CSXM1014 - self.mag_xm1014, self.ammo_xm1014);
    if (n < 1) n = 1;
    return n;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSXM1014PickupCopy =
{
    player.mag_xm1014  = self.mag_xm1014;
    player.ammo_xm1014 = self.ammo_xm1014;
};

void() W_CSXM1014FirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    // One kick impulse per trigger pull, not per pellet, applied before the
    // traces so they use the kicked aim — W_M3FirePellets' structure exactly.
    SH_ApplyViewKick(CSXM1014_KICK_PITCH, CSXM1014_KICK_VARIANCE, CSXM1014_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    // Every pellet of one blast shares a wep_action_id, so tag the whole loop and
    // remote viewers bypass their per-shot decal cap — see sv_impact_is_blast.
    sv_impact_is_blast = 1;
    for (i = 0; i < CSXM1014_PELLETS; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * CSXM1014_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * CSXM1014_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist   = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist, CSXM1014_PELLET_CLOSE_DAMAGE,
                                           CSXM1014_PELLET_MIN_DAMAGE,
                                           CSXM1014_PELLET_FALLOFF_RANGE);
            if (W_CanDamageTarget(trace_ent))
            {
                if (trace_ent.classname == "player")
                    trace_ent.death_hitgroup = W_BoneToHitgroup(trace_bone_id);

                W_ApplyDamage(self, trace_ent, damage);

                if (trace_ent.classname == "player")
                {
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
                }
                else
                {
                    float bmat = W_ClassifyImpactMaterial(trace_ent);
                    if (bmat == IMPACT_MAT_FLESH && trace_ent.health <= 0)
                        bmat = IMPACT_MAT_FLESH_LETHAL;
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, bmat);
                }
            }
            else
            {
                PhysProp_TryPushFromTrace(dir, damage);
                W_ImpactEffect(trace_endpos);
            }

            W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));
        }
    }
    sv_impact_is_blast = 0;
};

void() W_CSXM1014Shoot = { W_CSXM1014FirePellets(); };

void() W_CSXM1014Fire =
{
    float r = SH_CSXM1014TryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SH_CSXM1014PickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + CSXM1014_FRAME_INTERVAL;
        W_CSXM1014FirePellets();
        sound(self, CHAN_WEAPON, "weapons/xm1014-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_CSXM1014Reload =
{
    // The plan MUST be taken before SH_CSXM1014TryReload runs — it reads the
    // pre-reload magazine, and TryReload does not change mag, but taking it first
    // keeps the ordering obvious and matches the CSQC half below.
    float plan = SH_CSXM1014PlannedShells();

    if (SH_CSXM1014TryReload(time))
    {
        self.csxm1014_shells    = plan;
        self.csxm1014_inserted  = 0;
        self.csxm1014_snd_stage = 0;
        self.weaponframe        = SH_CSXM1014SeqStart();
        self.wep_nextframe      = time + CSXM1014_FRAME_INTERVAL;
    }
};

void() W_CSXM1014Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven: weaponframe holds the SEQUENCE, so it is switched at phase
    // boundaries rather than stepped every tick.
    self.wep_nextframe += CSXM1014_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSXM1014DrawDuration() * CSXM1014_DRAW_F_DEPLOY
            && self.csxm1014_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/de_deploy.wav", 1, ATTN_NORM);
            self.csxm1014_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float enter = SH_CSXM1014EnterDuration();
        float ins   = SH_CSXM1014InsertDuration();

        // Phase 1 — the gun comes down.  Its one event is the tube release.
        if (elapsed >= enter * CSXM1014_START_F_RELEASE && self.csxm1014_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "items/cliprelease1.wav", 1, ATTN_NORM);
            self.csxm1014_snd_stage = 1;
        }

        // Phase 2 — pay out the plan.  A `while` rather than an `if` so a frame
        // that arrives late (a hitch, a low tickrate) still credits every shell it
        // passed instead of silently dropping them and finishing the reload short.
        while (self.csxm1014_inserted < self.csxm1014_shells
               && elapsed >= enter + self.csxm1014_inserted * ins + ins * CSXM1014_INSERT_F_SHELL)
        {
            if (self.mag_xm1014 < MAX_MAG_CSXM1014 && self.ammo_xm1014 > 0)
            {
                self.mag_xm1014  += 1;
                self.ammo_xm1014 -= 1;
                sound(self, CHAN_AUTO, "weapons/m3_insertshell.wav", 1, ATTN_NORM);
            }
            self.csxm1014_inserted += 1;
            self.weaponframe = SH_CSXM1014SeqInsert();
        }

        // Phase 3 — the gun comes back up.  Silent: no pump on a gas gun.
        if (elapsed >= enter + self.csxm1014_shells * ins)
            self.weaponframe = SH_CSXM1014SeqAfter();
    }

    result = SH_CSXM1014TickState(time, self.csxm1014_shells);
    if (result & 1)
    {
        self.weaponframe        = SH_CSXM1014SeqIdle();
        self.wep_nextframe      = 0;
        self.csxm1014_snd_stage = 0;
        self.csxm1014_inserted  = 0;
    }
};

void() W_CSXM1014Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csxm1014", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSXM1014_VIEWMODEL, CSXM1014_DISPLAY_NAME, SH_CSXM1014SeqDraw(),
        CSXM1014_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSXM1014Fire;
    self.reload   = W_CSXM1014Reload;
    self.wepframe = W_CSXM1014Frame;
    self.shoot    = W_CSXM1014Shoot;
    self.csxm1014_snd_stage = 0;
    self.csxm1014_inserted  = 0;
    self.csxm1014_shells    = 0;
    W_SetCrosshairProfile(CSXM1014_SPREAD, 0, 320, 3, TRUE);
};

void() W_CSXM1014Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_xm1014  = self.mag_xm1014;
    tgt.ammo_xm1014 = self.ammo_xm1014;

    self.mag_xm1014  = 0;
    self.ammo_xm1014 = 0;

    setmodel(tgt, CSXM1014_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_xm1014";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSXM1014;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSXM1014Equip;
    tgt.weap_drop_func = W_CSXM1014Drop;
    tgt.pickupcopy     = W_CSXM1014PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_xm1014 =
{
    setmodel(self, CSXM1014_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_xm1014";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSXM1014;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSXM1014Equip;
    self.weap_drop_func = W_CSXM1014Drop;
    self.pickupcopy     = W_CSXM1014PickupCopy;
    self.touch          = weapon_touch;
    self.mag_xm1014   = MAX_MAG_CSXM1014;
    self.ammo_xm1014  = MAX_AMMO_CSXM1014;
    W_RegisterMapWeapon(weapon_xm1014);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// The predicted half's copy of the plan.  Globals rather than entity fields
// because only the local player is ever predicted, which is the same choice
// csqc_m3_reload_shells makes.
float csqc_csxm1014_shells;
float csqc_csxm1014_inserted;
float csqc_csxm1014_snd_stage;
float csqc_csxm1014_snd_action;
float csqc_csxm1014_casing_spawned;

void() CSQC_PredictCSXM1014Command =
{
    float r;

    if (predicted_player.wep_action_id != csqc_csxm1014_snd_action)
    {
        csqc_csxm1014_snd_action = predicted_player.wep_action_id;
        csqc_csxm1014_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSXM1014TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_csxm1014_casing_spawned = FALSE;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/xm1014-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(CSXM1014_PELLETS, CSXM1014_SPREAD,
                    CSXM1014_PELLET_CLOSE_DAMAGE, CSXM1014_PELLET_MIN_DAMAGE,
                    CSXM1014_PELLET_FALLOFF_RANGE,
                    CSXM1014_KICK_PITCH, CSXM1014_KICK_VARIANCE, CSXM1014_KICK_STRENGTH);
                CSQC_MuzzleFlashAtMuzzle(CSXM1014_MUZZLE_FORWARD, CSXM1014_MUZZLE_RIGHT,
                    CSXM1014_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSXM1014_MUZZLE_FORWARD, CSXM1014_MUZZLE_RIGHT,
                    CSXM1014_MUZZLE_DOWN, self.wep_action_id, CSXM1014_PELLETS);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Ejected shell, on the fire take rather than at the trigger pull.
    if (self.weaponstate == WS_FIRE && !csqc_csxm1014_casing_spawned
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start
            >= SH_SeqDuration(CSXM1014_VIEWMODEL, self.weaponframe, 0.5) * 0.25)
        {
            CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            csqc_csxm1014_casing_spawned = TRUE;
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_csxm1014_snd_stage < 1
                && elapsed >= SH_CSXM1014DrawDuration() * CSXM1014_DRAW_F_DEPLOY)
            {
                localsound("weapons/de_deploy.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csxm1014_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float snd_enter = SH_CSXM1014EnterDuration();
            float snd_ins   = SH_CSXM1014InsertDuration();

            if (csqc_csxm1014_snd_stage < 1
                && elapsed >= snd_enter * CSXM1014_START_F_RELEASE)
            {
                localsound("items/cliprelease1.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csxm1014_snd_stage = 1;
            }

            // The same while-loop the server runs, over the same timeline.
            while (csqc_csxm1014_inserted < csqc_csxm1014_shells
                   && elapsed >= snd_enter + csqc_csxm1014_inserted * snd_ins
                                 + snd_ins * CSXM1014_INSERT_F_SHELL)
            {
                localsound("weapons/m3_insertshell.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csxm1014_inserted += 1;
            }
        }
    }

    if (SH_CSXM1014TickState(csqc_pred_time, csqc_csxm1014_shells) & 1)
        csqc_csxm1014_inserted = 0;
};

void() CSQC_PredictCSXM1014Reload =
{
    // Take the plan BEFORE TryReload, from the same pre-reload mag and ammo the
    // server reads, so both sides walk an identical timeline.
    float plan = SH_CSXM1014PlannedShells();

    if (SH_CSXM1014TryReload(csqc_pred_time))
    {
        csqc_csxm1014_shells     = plan;
        csqc_csxm1014_inserted   = 0;
        csqc_csxm1014_snd_stage  = 0;
        csqc_csxm1014_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
//
// The reload arm also drives csqc_viewmodel_sequence_time, because the insert
// take has to play once PER SHELL and setting .frame alone would leave the second
// and later shells frozen on its final pose — the engine clamps a non-looping
// sequence there (gl_hlmdl.c:1076-1082).  Handing it the time inside the current
// insert restarts the take on every iteration.  cl_weapons.qc:1669 clears the
// override before each call, so this only affects the frames it is set on.
float(float elapsed) CSQC_CSXM1014DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSXM1014SeqDraw();

    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSXM1014PickShootSeq(predicted_player.wep_action_id);

    if (predicted_player.weaponstate == WS_RELOAD)
    {
        float enter = SH_CSXM1014EnterDuration();
        float ins   = SH_CSXM1014InsertDuration();
        float loops = csqc_csxm1014_shells * ins;

        if (elapsed < enter)
            return SH_CSXM1014SeqStart();

        float in_reload = elapsed - enter;
        if (in_reload < loops)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = in_reload - floor(in_reload / ins) * ins;
            return SH_CSXM1014SeqInsert();
        }

        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = in_reload - loops;
        return SH_CSXM1014SeqAfter();
    }

    return SH_CSXM1014SeqIdle();
};

void() CSQC_CSXM1014DropClear =
{
    self.mag_xm1014  = 0;
    self.ammo_xm1014 = 0;
};

void() CSQC_CSXM1014Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csxm1014", SCOPE_CLASS_NONE);
    self.weapon_name         = CSXM1014_DISPLAY_NAME;
    self.weapon_viewmodel    = CSXM1014_VIEWMODEL;
    self.weapon_worldmodel   = CSXM1014_WORLDMODEL;
    self.weapon_deploy_sound = CSXM1014_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSXM1014Command;
    self.csqc_predict_reload = CSQC_PredictCSXM1014Reload;
    self.csqc_display_frame  = CSQC_CSXM1014DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSXM1014DropClear;
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game.  sh_wpn_csglock.qc:664 already
    // listed this weapon as one of the ten drawing the same stock cstrike arm
    // and needing the same flip once it was reported.  The rhand/lhand meshes
    // here are byte-identical to the flipped handguns'.  cl_lefthand still XORs.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
