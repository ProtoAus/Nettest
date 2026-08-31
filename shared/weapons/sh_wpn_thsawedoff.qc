// ============================================================
//  shared/weapons/sh_wpn_thsawedoff.qc  -  They Hunger sawed-off (TOZ-34)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 2-shell break action, 125 reserve
//  Fire  : one barrel, 8 pellets
//  Alt   : both barrels, 16 pellets
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_sawedoff.as and
//  hunger/weapons/dbarrel/v_dbarrel.mdl.  The most-placed They Hunger weapon
//  in the corpus (21 placements across 14 maps), and until now a pickup alias
//  onto WEP_HLSHOTGUN — an 8-shell pump gun wearing a two-shell break action.

// --- Ammo fields ---
.float mag_thsawoff;
.float ammo_thsawoff;

// Server-side reload sound latch; CSQC keeps its own single global.
.float thsawoff_reload_snd_stage;

// --- Sequence indices, out of hunger/weapons/dbarrel/v_dbarrel.mdl (5 seqs) -
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// CAREFUL WITH THE NAMES — the model's $sequence labels and the script's
// TheyHungerSAWEDOFFAnimation_e enum (weapon_sawedoff.as:22-29) disagree, the
// same trap the Half-Life crowbar sets:
//     idx  model label     script enum name
//      2   reload          TOZ34_RELOAD_SINGLE   <- the ONE-shell reload
//      3   reload_empty    TOZ34_RELOAD          <- the TWO-shell reload
// The script is the authority on meaning (:277-280 picks RELOAD_SINGLE when
// one shell is going in), the label is just what the animator typed, so the
// constants below are named after the script.  Note the consequence: the
// one-shell reload is the LONGER of the two (3.520 s vs 3.000 s), which reads
// as backwards until you see that the two-shell take breaks the gun open once
// and drops both in together.
//
// None of the five carries STUDIO_LOOPING.
const float THSAWOFF_SEQ_IDLE          = 0;   // idle,         2.000 s  ( 61f @ 30)
const float THSAWOFF_SEQ_DRAW          = 1;   // draw,         1.125 s  ( 46f @ 40)
const float THSAWOFF_SEQ_RELOAD_SINGLE = 2;   // reload,       3.520 s  (177f @ 50)  one shell
const float THSAWOFF_SEQ_RELOAD        = 3;   // reload_empty, 3.000 s  (151f @ 50)  two shells
const float THSAWOFF_SEQ_SHOOT         = 4;   // shoot1,       0.758 s  ( 26f @ 33)  both triggers share it

const float THSAWOFF_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
const float THSAWOFF_FIRE_DELAY        = 0.123;  // weapon_sawedoff.as:180
const float THSAWOFF_DBLFIRE_DELAY     = 0.60;   // weapon_sawedoff.as:256

// Idle re-send cadence — weapon_sawedoff.as:304.  The model has no looping
// sequence, so SH_SeqIdleDisplay has to re-send one or the viewmodel clamps to
// a still frame (gl_hlmdl.c:1076-1082).
// weapon_sawedoff.as:304 is SharedRandomFloat(random_seed, 5, 7).  These were
// 10/15, which did not match the citation directly above them: against a 2.0 s
// non-looping idle that left the gun sitting on a dead still frame for most of
// every re-arm window.
const float THSAWOFF_IDLE_REARM_MIN    = 5;
const float THSAWOFF_IDLE_REARM_MAX    = 7;

// Reload sound instants, elapsed from wep_anim_start.  The break action's
// three beats: crack it open, the spent cases come out, snap it shut.  The
// two-shell take runs half a second shorter, so its instants are scaled to it.
const float THSAWOFF_RELOAD1_OPEN_TIME  = 0.400;
const float THSAWOFF_RELOAD1_EJECT_TIME = 1.100;
const float THSAWOFF_RELOAD1_SHELL_TIME = 2.100;
const float THSAWOFF_RELOAD1_CLOSE_TIME = 3.100;
const float THSAWOFF_RELOAD2_OPEN_TIME  = 0.350;
const float THSAWOFF_RELOAD2_EJECT_TIME = 0.950;
const float THSAWOFF_RELOAD2_SHELL_TIME = 1.800;
const float THSAWOFF_RELOAD2_CLOSE_TIME = 2.650;

const float MAX_MAG_THSAWOFF           = 2;     // SAWEDOFF_MAX_CLIP,  weapon_sawedoff.as:15
const float MAX_AMMO_THSAWOFF          = 125;   // SAWEDOFF_MAX_CARRY, weapon_sawedoff.as:13

// --- Balance ---
// weapon_sawedoff.as:18-20 declares two ASYMMETRIC cones —
//     VECTOR_CONE_DM_SAWEDOFFS(0.08716, 0.04362, 0)   single: wide flat spray
//     VECTOR_CONE_DM_SAWEDOFFD(0.08716, 0.17365, 0)   double: wide and tall
// — and this mod's spread argument is a single scalar applied to both axes.
// The WIDER axis of each is used, so the pattern is never tighter than the
// script's, only rounder.
const float THSAWOFF_PELLETS              = 8;         // SAWEDOFF_SINGLE_PELLETCOUNTER
const float THSAWOFF_DBL_PELLETS          = 16;        // SAWEDOFF_DOUBLE_PELLETCOUNT
const float THSAWOFF_SPREAD               = 0.08716;
const float THSAWOFF_DBL_SPREAD           = 0.17365;
// :199 fires BULLET_PLAYER_BUCKSHOT, the same skill value the Half-Life
// shotgun uses, so the per-pellet numbers are WEP_HLSHOTGUN's rather than new
// ones.  Two barrels at 16 pellets hits very hard at contact range; that is
// what a sawed-off is, and the two-shell magazine is the price.
const float THSAWOFF_PELLET_CLOSE_DAMAGE  = 13;
const float THSAWOFF_PELLET_MIN_DAMAGE    = 4;
const float THSAWOFF_PELLET_FALLOFF_RANGE = 1024;
const float THSAWOFF_DRYFIRE_DELAY        = 0.2;
const float THSAWOFF_KICK_PITCH        = 2.5;   // sv_gunkick — .as:207 punches -3..-5 deg
const float THSAWOFF_KICK_VARIANCE     = 0.6;
const float THSAWOFF_KICK_STRENGTH     = 1.6;
const float THSAWOFF_DBL_KICK_STRENGTH = 3.0;   // .as:262 punches a flat -10 deg

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float THSAWOFF_MUZZLE_FORWARD = 34;
const float THSAWOFF_MUZZLE_RIGHT   = 5.5;
const float THSAWOFF_MUZZLE_DOWN    = 8.0;

// --- State durations, taken from the sequences themselves ---
const float THSAWOFF_DRAW_DURATION          = 1.125;   // draw
const float THSAWOFF_FIRE_DURATION          = 0.758;   // shoot1
const float THSAWOFF_RELOAD_SINGLE_DURATION = 3.520;   // reload       (one shell)
const float THSAWOFF_RELOAD_DURATION        = 3.000;   // reload_empty (two shells)

const string THSAWOFF_VIEWMODEL    = "models/hunger/weapons/dbarrel/v_dbarrel.mdl";
const string THSAWOFF_WORLDMODEL   = "models/hunger/weapons/dbarrel/w_dbarrel.mdl";
const string THSAWOFF_DEPLOY_SOUND = "";
const string THSAWOFF_DISPLAY_NAME = "SAWED-OFF";

// ============================================================
//  SHARED — state machine
// ============================================================

// How many shells this reload will actually seat.  Both sides compute it from
// the same replicated pair, so both pick the same sequence and the same
// duration without needing .weaponframe (which no file under client/ reads).
// Explicit-entity form.  REQUIRED for anything on the render path: a display
// callback runs with `self` set to whatever CSQC entity addentities() predrew
// last (cl_weapons.qc documents the contract — display callbacks get
// predicted_player, not self), so reading self.mag_* there samples a random
// entity's field slots and the answer changes from frame to frame.
float(entity e) SH_THSawoffReloadShellsFor =
{
    float shells = MAX_MAG_THSAWOFF - e.mag_thsawoff;
    if (shells > e.ammo_thsawoff)
        shells = e.ammo_thsawoff;
    return shells;
};

// Convenience form for the prediction/server paths, where self IS the player.
float() SH_THSawoffReloadShells =
{
    return SH_THSawoffReloadShellsFor(self);
};

// weapon_sawedoff.as:277 — one shell going in (either because a live round is
// still in the other barrel, or because that is all the reserve has left)
// plays the single take.
float() SH_THSawoffReloadIsSingle =
{
    return (SH_THSawoffReloadShells() <= 1);
};

float() SH_THSawoffReloadDuration =
{
    if (SH_THSawoffReloadIsSingle())
        return THSAWOFF_RELOAD_SINGLE_DURATION;
    return THSAWOFF_RELOAD_DURATION;
};

float(float now) SH_THSawoffTickState =
{
    float elapsed;

    // WS_SPECIAL = both barrels.  Same sequence as single fire, different
    // state, so the longer cooldown and the two-shell cost stay separable.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= THSAWOFF_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_THSawoffReloadDuration();
    return SH_StandardTickState(now, mag_thsawoff, ammo_thsawoff, MAX_MAG_THSAWOFF,
        THSAWOFF_DRAW_DURATION, THSAWOFF_FIRE_DURATION, rel, rel);
};

// Semi-auto.  weapon_sawedoff.as:175-178 counts m_iShotsFired and bails on the
// second call, and :288-295 only resets the counter once the player lets go of
// IN_ATTACK — an open-coded rising-edge gate, which is exactly what
// SH_StandardTryFireSemiAuto is.
float(float now) SH_THSawoffTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_thsawoff, THSAWOFF_FIRE_DELAY,
                                      THSAWOFF_DRYFIRE_DELAY);
};

// Both barrels.  Returns 1 = fired, -1 = not enough in the gun, 0 = blocked.
// .as:236 needs TWO live shells, and reloads instead of firing on one.
float(float now) SH_THSawoffTryDoubleFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_thsawoff <= 1)
    {
        self.attack_finished = now + THSAWOFF_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + THSAWOFF_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.mag_thsawoff    -= 2;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + THSAWOFF_DBLFIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = self.attack_finished;
#endif
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

float(float now) SH_THSawoffTryReload =
{
    return SH_StandardTryReload(now, mag_thsawoff, ammo_thsawoff, MAX_MAG_THSAWOFF,
                                SH_THSawoffReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THSawoffPickupCopy =
{
    player.mag_thsawoff  = self.mag_thsawoff;
    player.ammo_thsawoff = self.ammo_thsawoff;
};

// Same shape as W_ShotgunFirePellets in sh_wpn_hlshotgun.qc: one kick impulse
// per trigger pull, then every pellet traced along the kicked aim so the
// pattern lands where the crosshair ended up rather than where it started.
void(float pellets, float spread_val, float kick_strength) W_THSawoffFirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    SH_ApplyViewKick(THSAWOFF_KICK_PITCH, THSAWOFF_KICK_VARIANCE, kick_strength);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    // Tag every impact this loop emits as one pellet of a single blast, so
    // remote viewers bypass their per-shot decal/effect caps (all pellets
    // share one wep_action_id).  See sv_impact_is_blast in sv_weapons.qc.
    sv_impact_is_blast = 1;
    for (i = 0; i < pellets; i++)
    {
        sx = SH_SpreadJitter(self.wep_action_id + i, 0) * spread_val;
        sy = SH_SpreadJitter(self.wep_action_id + i, 1) * spread_val;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        // .as:199 traces to 2048, not 8192 — a sawed-off has no reach.
        end = src + dir * 2048;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist   = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist, THSAWOFF_PELLET_CLOSE_DAMAGE,
                                           THSAWOFF_PELLET_MIN_DAMAGE,
                                           THSAWOFF_PELLET_FALLOFF_RANGE);
            if (W_CanDamageTarget(trace_ent))
            {
                W_ApplyDamage(self, trace_ent, damage);
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

void() W_THSawoffShoot =
{
    W_THSawoffFirePellets(THSAWOFF_PELLETS, THSAWOFF_SPREAD, THSAWOFF_KICK_STRENGTH);
};

void() W_THSawoffFire =
{
    float r = SH_THSawoffTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = THSAWOFF_SEQ_SHOOT;
        self.wep_nextframe = time + THSAWOFF_FRAME_INTERVAL;

        W_THSawoffShoot();
        sound(self, CHAN_WEAPON, "hunger/weapons/dbarrel/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THSawoffAltFire =
{
    float r = SH_THSawoffTryDoubleFire(time);

    if (r == 1)
    {
        self.weaponframe   = THSAWOFF_SEQ_SHOOT;
        self.wep_nextframe = time + THSAWOFF_FRAME_INTERVAL;

        W_THSawoffFirePellets(THSAWOFF_DBL_PELLETS, THSAWOFF_DBL_SPREAD,
                              THSAWOFF_DBL_KICK_STRENGTH);
        sound(self, CHAN_WEAPON, "hunger/weapons/dbarrel/doublefire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THSawoffReload =
{
    if (SH_THSawoffTryReload(time))
    {
        self.weaponframe   = SH_THSawoffReloadIsSingle() ? THSAWOFF_SEQ_RELOAD_SINGLE
                                                         : THSAWOFF_SEQ_RELOAD;
        self.wep_nextframe = time + THSAWOFF_FRAME_INTERVAL;
        self.thsawoff_reload_snd_stage = 0;
    }
};

void() W_THSawoffFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THSAWOFF_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float single = (self.weaponframe == THSAWOFF_SEQ_RELOAD_SINGLE);
        float t_open  = single ? THSAWOFF_RELOAD1_OPEN_TIME  : THSAWOFF_RELOAD2_OPEN_TIME;
        float t_eject = single ? THSAWOFF_RELOAD1_EJECT_TIME : THSAWOFF_RELOAD2_EJECT_TIME;
        float t_shell = single ? THSAWOFF_RELOAD1_SHELL_TIME : THSAWOFF_RELOAD2_SHELL_TIME;
        float t_close = single ? THSAWOFF_RELOAD1_CLOSE_TIME : THSAWOFF_RELOAD2_CLOSE_TIME;

        float reload_elapsed = time - self.wep_anim_start;
        if (self.thsawoff_reload_snd_stage < 1 && reload_elapsed >= t_open)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/dbarrel/TOZ_open.wav", 1, ATTN_NORM);
            self.thsawoff_reload_snd_stage = 1;
        }
        if (self.thsawoff_reload_snd_stage < 2 && reload_elapsed >= t_eject)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/dbarrel/TOZ_shell_out.wav", 1, ATTN_NORM);
            self.thsawoff_reload_snd_stage = 2;
        }
        if (self.thsawoff_reload_snd_stage < 3 && reload_elapsed >= t_shell)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/dbarrel/TOZ_shell1.wav", 1, ATTN_NORM);
            self.thsawoff_reload_snd_stage = 3;
        }
        if (self.thsawoff_reload_snd_stage < 4 && reload_elapsed >= t_close)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/dbarrel/TOZ_close.wav", 1, ATTN_NORM);
            self.thsawoff_reload_snd_stage = 4;
        }
    }

    result = SH_THSawoffTickState(time);
    if (result & 1)
    {
        self.weaponframe = THSAWOFF_SEQ_IDLE;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_THSawoffEquip =
{
    W_StandardEquipSetup(THSAWOFF_VIEWMODEL, THSAWOFF_DISPLAY_NAME, THSAWOFF_SEQ_DRAW,
        THSAWOFF_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_THSawoffFire;
    self.altfire  = W_THSawoffAltFire;
    self.reload   = W_THSawoffReload;
    self.wepframe = W_THSawoffFrame;
    self.shoot    = W_THSawoffShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(THSAWOFF_SPREAD, THSAWOFF_SPREAD, 320, 2, TRUE);
};

void() W_THSawoffDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_thsawoff  = self.mag_thsawoff;
    tgt.ammo_thsawoff = self.ammo_thsawoff;

    self.mag_thsawoff  = 0;
    self.ammo_thsawoff = 0;

    setmodel(tgt, THSAWOFF_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sawedoff";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THSAWOFF;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_THSawoffEquip;
    tgt.weap_drop_func = W_THSawoffDrop;
    tgt.pickupcopy     = W_THSawoffPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thsawedoff =
{
    setmodel(self, THSAWOFF_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sawedoff";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THSAWOFF;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_THSawoffEquip;
    self.weap_drop_func = W_THSawoffDrop;
    self.pickupcopy     = W_THSawoffPickupCopy;
    self.touch          = weapon_touch;
    self.mag_thsawoff   = MAX_MAG_THSAWOFF;
    self.ammo_thsawoff  = MAX_AMMO_THSAWOFF;
    W_RegisterMapWeapon(weapon_thsawedoff);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_thsawoff_reload_snd_stage;

// One/two-shell reload variant, LATCHED at reload start and tagged with the
// action it belongs to.  The server latches the same decision into .weaponframe
// (W_THSawoffReload) and reads the latch back in W_THSawoffFrame; the client
// used to recompute it live from mag/reserve on every frame instead, which is
// two bugs in one:
//
//   * on the render path the live form read `self`, which during a display
//     callback is whatever entity was predrawn last, so the answer flipped
//     between frames and the viewmodel snapped between two different 50 fps
//     sequences while frame1time kept running — the reported "freak out";
//   * even with the right entity, a ping-window mag disagreement flips the
//     SOUND variant on one side only, giving mistimed or doubled shell sounds.
//
// Latching on both sides removes the whole class.
// (No initialiser on the action id — fteqcc turns an initialised global into a
// constant, so validity gets its own flag rather than a -1 sentinel.  0 would
// not do as "unset": it is a legal action id.)
float csqc_thsawoff_reload_single;
float csqc_thsawoff_reload_single_action;
float csqc_thsawoff_reload_single_valid;

// Resolve the variant for display/sound: prefer the latch when it belongs to
// the action being rendered, otherwise derive it from the correct entity.  The
// fallback covers a server-driven reload the client never predicted, and the
// spectated/killcam path where predicted_player is a scratch entity.
float(entity who) SH_THSawoffReloadSingleFor =
{
    if (csqc_thsawoff_reload_single_valid
        && csqc_thsawoff_reload_single_action == who.wep_action_id)
        return csqc_thsawoff_reload_single;
    return SH_THSawoffReloadShellsFor(who) <= 1;
};

void() CSQC_PredictTHSawoffCommand =
{
    float r;

    if (input_buttons & 4)
    {
        r = SH_THSawoffTryDoubleFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("hunger/weapons/dbarrel/doublefire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(THSAWOFF_DBL_PELLETS, THSAWOFF_DBL_SPREAD,
                    THSAWOFF_PELLET_CLOSE_DAMAGE, THSAWOFF_PELLET_MIN_DAMAGE,
                    THSAWOFF_PELLET_FALLOFF_RANGE,
                    THSAWOFF_KICK_PITCH, THSAWOFF_KICK_VARIANCE, THSAWOFF_DBL_KICK_STRENGTH);
                CSQC_MuzzleFlashAtMuzzle(THSAWOFF_MUZZLE_FORWARD, THSAWOFF_MUZZLE_RIGHT,
                    THSAWOFF_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THSAWOFF_MUZZLE_FORWARD, THSAWOFF_MUZZLE_RIGHT,
                    THSAWOFF_MUZZLE_DOWN, self.wep_action_id, 5);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/dryfire1.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_THSawoffTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("hunger/weapons/dbarrel/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(THSAWOFF_PELLETS, THSAWOFF_SPREAD,
                    THSAWOFF_PELLET_CLOSE_DAMAGE, THSAWOFF_PELLET_MIN_DAMAGE,
                    THSAWOFF_PELLET_FALLOFF_RANGE,
                    THSAWOFF_KICK_PITCH, THSAWOFF_KICK_VARIANCE, THSAWOFF_KICK_STRENGTH);
                CSQC_MuzzleFlashAtMuzzle(THSAWOFF_MUZZLE_FORWARD, THSAWOFF_MUZZLE_RIGHT,
                    THSAWOFF_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THSAWOFF_MUZZLE_FORWARD, THSAWOFF_MUZZLE_RIGHT,
                    THSAWOFF_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/dryfire1.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        // Mirrors the server's variant test, but off the LATCH rather than a
        // live mag/reserve read, so a mid-reload disagreement with the server
        // cannot retime the shell sounds half way through the take.
        float single = SH_THSawoffReloadSingleFor(self);
        float t_open  = single ? THSAWOFF_RELOAD1_OPEN_TIME  : THSAWOFF_RELOAD2_OPEN_TIME;
        float t_eject = single ? THSAWOFF_RELOAD1_EJECT_TIME : THSAWOFF_RELOAD2_EJECT_TIME;
        float t_shell = single ? THSAWOFF_RELOAD1_SHELL_TIME : THSAWOFF_RELOAD2_SHELL_TIME;
        float t_close = single ? THSAWOFF_RELOAD1_CLOSE_TIME : THSAWOFF_RELOAD2_CLOSE_TIME;

        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_thsawoff_reload_snd_stage < 1 && reload_elapsed >= t_open)
        {
            localsound("hunger/weapons/dbarrel/TOZ_open.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thsawoff_reload_snd_stage = 1;
        }
        if (csqc_thsawoff_reload_snd_stage < 2 && reload_elapsed >= t_eject)
        {
            localsound("hunger/weapons/dbarrel/TOZ_shell_out.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thsawoff_reload_snd_stage = 2;
        }
        if (csqc_thsawoff_reload_snd_stage < 3 && reload_elapsed >= t_shell)
        {
            localsound("hunger/weapons/dbarrel/TOZ_shell1.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thsawoff_reload_snd_stage = 3;
        }
        if (csqc_thsawoff_reload_snd_stage < 4 && reload_elapsed >= t_close)
        {
            localsound("hunger/weapons/dbarrel/TOZ_close.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thsawoff_reload_snd_stage = 4;
        }
    }

    SH_THSawoffTickState(csqc_pred_time);
};

void() CSQC_PredictTHSawoffReload =
{
    if (SH_THSawoffTryReload(csqc_pred_time))
    {
        csqc_thsawoff_reload_snd_stage = 0;
        // Latch the variant for the action SH_THSawoffTryReload just started.
        // Computed here, while self IS the player and the mag still holds its
        // pre-reload value — the same instant the server latches it into
        // .weaponframe.  A reconcile replay re-runs this command from the same
        // confirmed state and re-latches the identical value.
        csqc_thsawoff_reload_single        = SH_THSawoffReloadShells() <= 1;
        csqc_thsawoff_reload_single_action = self.wep_action_id;
        csqc_thsawoff_reload_single_valid  = 1;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_THSawoffDisplayFrame =
{
    // FIRST, for every state — see sh_weapon_standard.qc.  v_dbarrel.mdl has
    // no looping sequence, so without this the gun freezes on a still frame.
    float idle = SH_SeqIdleDisplay(cltime, WEP_THSAWOFF, predicted_player.weaponstate,
                                   THSAWOFF_SEQ_IDLE, THSAWOFF_SEQ_IDLE,
                                   THSAWOFF_IDLE_REARM_MIN, THSAWOFF_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return THSAWOFF_SEQ_DRAW;
    // predicted_player, NOT self — see SH_THSawoffReloadShellsFor.  Calling the
    // self-reading form here sampled a random predrawn entity and made the
    // sequence choice flip from frame to frame.
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_THSawoffReloadSingleFor(predicted_player) ? THSAWOFF_SEQ_RELOAD_SINGLE
                                                            : THSAWOFF_SEQ_RELOAD;
    // WS_FIRE and WS_SPECIAL both play the one fire sequence the model has.
    return THSAWOFF_SEQ_SHOOT;
};

void() CSQC_THSawoffDropClear =
{
    self.mag_thsawoff  = 0;
    self.ammo_thsawoff = 0;
};

void() CSQC_THSawoffEquip =
{
    self.weapon_name         = THSAWOFF_DISPLAY_NAME;
    self.weapon_viewmodel    = THSAWOFF_VIEWMODEL;
    self.weapon_worldmodel   = THSAWOFF_WORLDMODEL;
    self.weapon_deploy_sound = THSAWOFF_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHSawoffCommand;
    self.csqc_predict_reload = CSQC_PredictTHSawoffReload;
    self.csqc_display_frame  = CSQC_THSawoffDisplayFrame;
    self.csqc_drop_clear     = CSQC_THSawoffDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
