// ============================================================
//  shared/weapons/sh_wpn_csglock.qc  -  CS Glock 18
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 20-round magazine, 40 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : 3-round burst fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_glock;
.float ammo_glock;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS only.  Every one is resolved by NAME at runtime through
// SH_SeqForName, so a model swap that reorders sequences cannot silently point
// "reload" at add_silencer.  The numbers are the layout of
// cstrike/models/v_glock18.mdl and apply only to a model carrying no names.
//
//   idx  label          frames  fps     dur
//     0  idle1              11 16.0   0.625
//     1  idle2              11 20.0   0.500
//     2  idle3              11 18.0   0.556
//     3  shoot              31 40.0   0.750   ev5001 x3 @ 0.000/0.050/0.100 <- BURST
//     4  shoot2             31 40.0   0.750   ev5001 x3 @ 0.000/0.050/0.100 <- BURST
//     5  shoot3             21 40.0   0.500   ev5001 x1 @ 0.000            <- SEMI
//     6  shoot_empty        21 35.0   0.571   ev5001 x1 @ 0.000            <- SEMI, slide locked
//     7  reload             76 35.0   2.143   f16/f48/f62 clipout/clipin/slide
//     8  draw               50 45.0   1.089   f17 slideback
//     9  holster            27 25.0   1.040
//    10  add_silencer       27 20.0   1.300
//    11  draw2              50 45.0   1.089
//    12  reload2            76 30.0   2.500
//
// THE THREE SHOOT TAKES ARE NOT INTERCHANGEABLE, and this file used to treat
// them as three random variations of one shot.  They are two different
// ANIMATIONS OF TWO DIFFERENT FIRE MODES, and the model says so in its own
// event table: `shoot` and `shoot2` each carry THREE muzzle-flash events
// (ev5001) spaced 0.050s apart -- exactly GLOCK_BURST_FIRE_DELAY below --
// while `shoot3` and `shoot_empty` carry exactly one.  The hand motion agrees:
// the burst takes kick twice (Bone_Righthand pitch 3.7 -> 12.6 deg at t=0.20,
// settle, then 5.5 -> 18.8 deg at t=0.55), the semi take snaps once and is flat
// after 0.2s.
//
// Picking randomly among all three therefore drew a BURST take for 2 shots in 3
// of single fire, and the SEMI take for 1 burst in 3.  That is what "+attack
// looks like the burst animation but only fires one bullet, and +attack2 is
// sometimes not burst" was, in those exact proportions.
//
// So: +attack  -> shoot3 / shoot_empty   (SH_GlockSemiShootSeq)
//     +attack2 -> shoot / shoot2         (SH_GlockPickBurstSeq, latched once
//                                         per burst into .glock_burst_seq)
//
// This file previously drove a flat IDPO frame bake (wpn_csglock/v_glock.mdl,
// 187 frames named frame0..frame186) with hand-guessed ranges marked
// "placeholder — user will tune".  Those names hold no information: FTE groups
// Quake MDL frames by stripping trailing digits, so that model exposes exactly
// ONE group named "frame".  The ranges are not recoverable from it — the bake
// is 187 frames against the original's 443.  Same migration the crowbar made
// (sh_wpn_hlcrowbar.qc:12).
const float GLOCK_SEQ_IDLE   = 0;
const float GLOCK_SEQ_SHOOT1 = 3;
const float GLOCK_SEQ_SHOOT2 = 4;
const float GLOCK_SEQ_SHOOT3 = 5;
const float GLOCK_SEQ_SHOOTE = 6;   // shoot_empty — last round out, slide locks back
const float GLOCK_SEQ_RELOAD = 7;
const float GLOCK_SEQ_DRAW   = 8;

const float GLOCK_FRAME_INTERVAL      = 0.0333334;   // state-machine tick rate
const float GLOCK_FIRE_DELAY          = 0.15;

const float GLOCK_BURST_FIRE_DELAY    = 0.05;   // delay between burst shots
const float GLOCK_BURST_COOLDOWN      = 0.5;    // delay after burst completes
// How long WS_SPECIAL (and therefore the burst animation) is held.  Kept at the
// old frame-bake value rather than raised to the burst take's real 0.750s: the
// window is also the burst's rate limit, because SH_GlockTryBurst refuses while
// weaponstate is WS_SPECIAL, so lengthening it to fit the animation would slow
// the weapon down.  The cost is that the burst take is cut at 0.567s, part way
// through its second recoil settle.  Deliberate, and not what was reported.
const float GLOCK_BURST_DURATION      = 0.566668;

// Event marks as a FRACTION of their sequence, not absolute seconds — the
// reload's studio events are at frames 16/48/62 of 76 and draw's at 17 of 50,
// with frameduration dividing by (numframes-1).  Fractions matter because
// cstrike AND czero are both mounted (fs_addons.txt:16-17) and both ship
// models/v_glock18.mdl with the same sequence names at different fps.
const float GLOCK_RELOAD_F_CLIPOUT = 0.2133;   // frame 16 / 75
const float GLOCK_RELOAD_F_CLIPIN  = 0.6400;   // frame 48 / 75
const float GLOCK_RELOAD_F_SLIDE   = 0.8267;   // frame 62 / 75
const float GLOCK_RELOAD_F_APPLY   = 0.6800;   // just after the fresh mag seats
const float GLOCK_DRAW_F_SLIDEBACK = 0.3469;   // frame 17 / 49

const float MAX_MAG_GLOCK             = 20;
const float MAX_AMMO_GLOCK            = 40;

// --- Balance ---
const float GLOCK_BASE_SPREAD          = 0.01;
const float GLOCK_MOVE_SPREAD          = 0.05;
const float GLOCK_FULL_SPREAD_SPEED    = 320;
const float GLOCK_CLOSE_DAMAGE         = 18;
const float GLOCK_MIN_DAMAGE           = 10;
const float GLOCK_DAMAGE_FALLOFF_RANGE = 2048;
const float GLOCK_DRYFIRE_DELAY        = 0.2;
const float GLOCK_KICK_PITCH    = 0.55;   // sv_gunkick — light pistol.
const float GLOCK_KICK_VARIANCE = 2.25;
const float GLOCK_KICK_STRENGTH = 1.5;    // small light pistol.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float GLOCK_MUZZLE_FORWARD = 38;
const float GLOCK_MUZZLE_RIGHT   = 13.3;
const float GLOCK_MUZZLE_DOWN    = 9;

const float GLOCK_BURST_SPREAD         = 0.03;   // base spread during burst
const float GLOCK_BURST_DAMAGE         = 14;     // less damage per bullet in burst

// Resolves off the mounted cstrike gamedir (fs_addons.txt:16), exactly the way
// the crowbar takes models/v_crowbar.mdl from the valve mount.  The world model
// stays the mod's own — only the viewmodel needed its animations back.
const string GLOCK_VIEWMODEL    = "models/v_glock18.mdl";
const string GLOCK_WORLDMODEL   = "models/w_glock18.mdl";
const string GLOCK_DEPLOY_SOUND = "";
const string GLOCK_DISPLAY_NAME = "GLOCK";

// --- Burst state ---
.float glock_burst_count;     // shots remaining in current burst (0 = not bursting)
.float glock_burst_next;      // time of next burst shot
// The burst take, chosen ONCE when the burst starts.  It cannot be re-derived
// per shot: rounds 2 and 3 each bump .wep_action_id (they want their own muzzle
// flash and spread), so hashing the id at display time would flip the viewmodel
// between shoot and shoot2 mid-burst and restart the animation twice.  0 means
// "no burst latched" and is a safe sentinel -- sequence 0 is idle1, never a
// shoot take.
.float glock_burst_seq;

// Per-entity sound stages (server).  The old frame-stepping code compared
// weaponframe against absolute frame numbers; a sequence-driven model never
// steps weaponframe, so stages latch off elapsed time instead.
.float glock_reload_snd_stage;
.float glock_draw_snd_played;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_GlockSeqIdle   = { return SH_SeqForName(GLOCK_VIEWMODEL, "idle1",       GLOCK_SEQ_IDLE); };
float() SH_GlockSeqShoot1 = { return SH_SeqForName(GLOCK_VIEWMODEL, "shoot",       GLOCK_SEQ_SHOOT1); };
float() SH_GlockSeqShoot2 = { return SH_SeqForName(GLOCK_VIEWMODEL, "shoot2",      GLOCK_SEQ_SHOOT2); };
float() SH_GlockSeqShoot3 = { return SH_SeqForName(GLOCK_VIEWMODEL, "shoot3",      GLOCK_SEQ_SHOOT3); };
float() SH_GlockSeqShootE = { return SH_SeqForName(GLOCK_VIEWMODEL, "shoot_empty", GLOCK_SEQ_SHOOTE); };
float() SH_GlockSeqReload = { return SH_SeqForName(GLOCK_VIEWMODEL, "reload",      GLOCK_SEQ_RELOAD); };
float() SH_GlockSeqDraw   = { return SH_SeqForName(GLOCK_VIEWMODEL, "draw",        GLOCK_SEQ_DRAW); };

// SEMI-AUTO (+attack).  One bullet, one muzzle flash, one take.  `mag_left` is
// the magazine count AFTER this shot — at zero the model has a dedicated
// slide-locks-back take, which the old frame bake had no way to reach.
float(float mag_left) SH_GlockSemiShootSeq =
{
    if (mag_left <= 0)
        return SH_GlockSeqShootE();
    return SH_GlockSeqShoot3();
};

// BURST (+attack2).  Both takes carry the same three muzzle-flash events at the
// same cadence and differ only in a degree of wrist motion, so the pick is pure
// variety; it is deterministic off wep_action_id purely so a demo or a remote
// viewmodel reconstruction replays the same one.  Call this ONCE per burst and
// latch it — see .glock_burst_seq.
//
// Deliberately does NOT fall back to shoot_empty when the burst empties the
// magazine: the switch would land mid-burst, part way through a take whose
// clock (wep_anim_start) does not restart, and pop.  A burst that runs the gun
// dry keeps the burst take and skips the slide-lock pose.
float(float action_id) SH_GlockPickBurstSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_GlockSeqShoot1()
                                            : SH_GlockSeqShoot2();
};

// Durations come from the model that actually loaded, never a constant.
float() SH_GlockDrawDuration   = { return SH_SeqDuration(GLOCK_VIEWMODEL, SH_GlockSeqDraw(),   1.089); };
float() SH_GlockReloadDuration = { return SH_SeqDuration(GLOCK_VIEWMODEL, SH_GlockSeqReload(), 2.143); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GlockTickState =
{
    float elapsed;

    // WS_SPECIAL = burst fire animation
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= GLOCK_BURST_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_GlockReloadDuration();
    // fire_dur is how long WS_FIRE (and therefore the shoot animation) is held;
    // it does NOT gate refire, attack_finished does.  Read from the take the
    // display is actually going to show rather than from self.weaponframe: on
    // the client weaponframe is the SERVER's last value, arriving a round trip
    // late, so the two sides used to disagree about when the shot ended.
    return SH_StandardTickState(now, mag_glock, ammo_glock, MAX_MAG_GLOCK,
        SH_GlockDrawDuration(),
        SH_SeqDuration(GLOCK_VIEWMODEL, SH_GlockSemiShootSeq(self.mag_glock), 0.5),
        rel, rel * GLOCK_RELOAD_F_APPLY);
};

float(float now) SH_GlockTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_glock, GLOCK_FIRE_DELAY, GLOCK_DRYFIRE_DELAY);
};

float(float now) SH_GlockTryReload =
{
    return SH_StandardTryReload(now, mag_glock, ammo_glock, MAX_MAG_GLOCK,
        SH_GlockReloadDuration());
};

// Start a 3-round burst. Returns 1 if burst started, -1 dry, 0 blocked.
float(float now) SH_GlockTryBurst =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished)
        return 0;
    if (self.glock_burst_count > 0)
        return 0;

    if (self.mag_glock <= 0)
    {
        self.attack_finished = now + GLOCK_DRYFIRE_DELAY;
        return -1;
    }

    // Fire first bullet of burst immediately, use WS_SPECIAL for burst animation
    self.mag_glock       -= 1;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    // Latch the take here, while wep_action_id is still the burst's own id.
    self.glock_burst_seq  = SH_GlockPickBurstSeq(self.wep_action_id);
    self.glock_burst_count = 2;   // 2 more shots queued
    self.glock_burst_next  = now + GLOCK_BURST_FIRE_DELAY;
    self.attack_finished   = now + GLOCK_BURST_COOLDOWN;
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_GlockPickupCopy =
{
    player.mag_glock  = self.mag_glock;
    player.ammo_glock = self.ammo_glock;
};

void() W_GlockShoot =
{
    W_PenetratingHitscanShoot(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
        GLOCK_CLOSE_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE, 8, 0.94,
        GLOCK_KICK_PITCH, GLOCK_KICK_VARIANCE, GLOCK_KICK_STRENGTH);
};

void() W_GlockBurstShoot =
{
    W_PenetratingHitscanShoot(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
        GLOCK_BURST_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE, 8, 0.94,
        GLOCK_KICK_PITCH, GLOCK_KICK_VARIANCE, GLOCK_KICK_STRENGTH);
};

void() W_GlockFire =
{
    float r = SH_GlockTryFire(time);
    if (r == 1)
    {
        // mag_glock is already decremented by SH_StandardTryFire, so this is
        // the post-shot count — which is what selects shoot_empty.
        self.weaponframe   = SH_GlockSemiShootSeq(self.mag_glock);
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        W_GlockShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GlockAltFire =
{
    float r = SH_GlockTryBurst(time);
    if (r == 1)
    {
        self.weaponframe   = self.glock_burst_seq;
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        W_GlockBurstShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GlockReload =
{
    if (SH_GlockTryReload(time))
    {
        self.weaponframe   = SH_GlockSeqReload();
        self.wep_nextframe = time + GLOCK_FRAME_INTERVAL;
        self.glock_burst_count = 0;
        self.glock_reload_snd_stage = 0;
    }
};

void() W_GlockFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and
    // fires timed sound events.  CHAN_AUTO so the predicted-sound dedup
    // window matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += GLOCK_FRAME_INTERVAL;

    // Draw sound — slideback rides the draw sequence's own event mark.
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_GlockDrawDuration() * GLOCK_DRAW_F_SLIDEBACK
            && !self.glock_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/slideback.wav", 1, ATTN_NORM);
            self.glock_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_GlockReloadDuration();
        if (elapsed >= 0 && self.glock_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/reload.wav", 1, ATTN_NORM);
            self.glock_reload_snd_stage = 1;
        }
        if (elapsed >= rel * GLOCK_RELOAD_F_CLIPOUT && self.glock_reload_snd_stage < 2)
        {
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.glock_reload_snd_stage = 2;
        }
        if (elapsed >= rel * GLOCK_RELOAD_F_SLIDE && self.glock_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csglock/sliderelease.wav", 1, ATTN_NORM);
            self.glock_reload_snd_stage = 3;
        }
    }

    // Burst: fire remaining queued shots
    if (self.glock_burst_count > 0 && time >= self.glock_burst_next)
    {
        if (self.mag_glock > 0)
        {
            self.mag_glock -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            W_GlockBurstShoot();
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
            // Same latched take — NOT a fresh pick.  Rounds 2 and 3 have their
            // own wep_action_id, so re-deriving it here would swap the sequence
            // out from under an animation whose clock does not restart.
            self.weaponframe = self.glock_burst_seq;
        }
        self.glock_burst_count -= 1;
        self.glock_burst_next = time + GLOCK_BURST_FIRE_DELAY;
    }

    result = SH_GlockTickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_GlockSeqIdle();
        self.wep_nextframe = 0;
        self.glock_reload_snd_stage = 0;
    }
};

void() W_GlockEquip =
{
    W_StandardEquipSetup(GLOCK_VIEWMODEL, GLOCK_DISPLAY_NAME, SH_GlockSeqDraw(),
        GLOCK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_GlockFire;
    self.reload   = W_GlockReload;
    self.wepframe = W_GlockFrame;
    self.altfire  = W_GlockAltFire;
    self.shoot    = W_GlockShoot;
    self.glock_burst_count = 0;
    self.glock_burst_seq   = 0;
    self.glock_reload_snd_stage = 0;
    self.glock_draw_snd_played  = 0;
    W_SetCrosshairProfile(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_GlockDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_glock  = self.mag_glock;
    tgt.ammo_glock = self.ammo_glock;
    self.mag_glock  = 0;
    self.ammo_glock = 0;

    setmodel(tgt, "models/w_glock18.mdl");
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname    = "weapon_glock";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_GLOCK;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_GlockEquip;
    tgt.weap_drop_func = W_GlockDrop;
    tgt.pickupcopy   = W_GlockPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_glock =
{
    setmodel(self, "models/w_glock18.mdl");
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname     = "weapon_glock";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_GLOCK;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_GlockEquip;
    self.weap_drop_func = W_GlockDrop;
    self.pickupcopy    = W_GlockPickupCopy;
    self.touch         = weapon_touch;
    self.mag_glock     = MAX_MAG_GLOCK;
    self.ammo_glock    = MAX_AMMO_GLOCK;
    W_RegisterMapWeapon(weapon_glock);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_glock_reload_snd_stage;

void() CSQC_PredictGlockCommand =
{
    float r;

    // Primary fire (single shot)
    if (input_buttons & 1)
    {
        r = SH_GlockTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(GLOCK_BASE_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
                    GLOCK_CLOSE_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    GLOCK_KICK_PITCH, GLOCK_KICK_VARIANCE, GLOCK_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Alt-fire (burst)
    if (input_buttons & 4)
    {
        r = SH_GlockTryBurst(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
                    GLOCK_BURST_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    GLOCK_KICK_PITCH, GLOCK_KICK_VARIANCE, GLOCK_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Burst: fire remaining queued shots client-side
    if (self.glock_burst_count > 0 && csqc_pred_time >= self.glock_burst_next)
    {
        if (self.mag_glock > 0)
        {
            self.mag_glock -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csglock/fireburst.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(GLOCK_BURST_SPREAD, GLOCK_MOVE_SPREAD, GLOCK_FULL_SPREAD_SPEED,
                    GLOCK_BURST_DAMAGE, GLOCK_MIN_DAMAGE, GLOCK_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    GLOCK_KICK_PITCH, GLOCK_KICK_VARIANCE, GLOCK_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT,
                    GLOCK_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        self.glock_burst_count -= 1;
        self.glock_burst_next = csqc_pred_time + GLOCK_BURST_FIRE_DELAY;
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel = SH_GlockReloadDuration();
        if (csqc_glock_reload_snd_stage < 1 && reload_elapsed >= 0)
        {
            localsound("sounds/weapons/wpn_csglock/reload.wav"); CSQC_RecordPredictedAutoSound();
            csqc_glock_reload_snd_stage = 1;
        }
        if (csqc_glock_reload_snd_stage < 2 && reload_elapsed >= rel * GLOCK_RELOAD_F_CLIPOUT)
        {
            CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_glock_reload_snd_stage = 2;
        }
        if (csqc_glock_reload_snd_stage < 3 && reload_elapsed >= rel * GLOCK_RELOAD_F_SLIDE)
        { localsound("sounds/weapons/wpn_csglock/sliderelease.wav"); CSQC_RecordPredictedAutoSound(); csqc_glock_reload_snd_stage = 3; }
    }

    SH_GlockTickState(csqc_pred_time);
};

void() CSQC_PredictGlockReload =
{
    if (SH_GlockTryReload(csqc_pred_time))
    { csqc_glock_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
//
// WS_SPECIAL and WS_FIRE are the two fire MODES and get different takes — the
// model has a dedicated 3-flash burst animation and a dedicated 1-flash semi
// animation, and this is the split that makes +attack and +attack2 look like
// what they are.  See the sequence table at the top of the file.
float(float elapsed) CSQC_GlockDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_GlockSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_GlockSeqReload();
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // Sentinel: sequence 0 is idle1, so a zero here means no burst was ever
        // latched on this client (a snapshot arriving mid-burst, say).  Fall
        // back to a burst take rather than to the idle pose.
        if (predicted_player.glock_burst_seq)
            return predicted_player.glock_burst_seq;
        return SH_GlockSeqShoot1();
    }
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_GlockSemiShootSeq(predicted_player.mag_glock);

    return SH_GlockSeqIdle();
};

void() CSQC_GlockDropClear =
{
	self.mag_glock  = 0;
	self.ammo_glock = 0;
};

void() CSQC_GlockEquip =
{
	self.weapon_name         = GLOCK_DISPLAY_NAME;
	self.weapon_viewmodel    = GLOCK_VIEWMODEL;
	self.weapon_worldmodel   = GLOCK_WORLDMODEL;
	self.weapon_deploy_sound = GLOCK_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictGlockCommand;
	self.csqc_predict_reload = CSQC_PredictGlockReload;
	self.csqc_display_frame  = CSQC_GlockDisplayFrame;
	self.csqc_drop_clear     = CSQC_GlockDropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.  Without this flag
	// CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
	// sits frozen on the first frame of whatever sequence we set.
	self.weapon_uses_sequences = TRUE;
	// ============================================================
	//  THE CANONICAL NOTE ON weapon_viewmodel_flip FOR THE CS SET.
	//  The other five CS handguns point here rather than repeating it.
	//
	//  WHERE THE MESH SITS ALONG Y IS NOT HANDEDNESS, and this file used to
	//  reason as if it were.  Y decides which side of the SCREEN the model
	//  draws on — RF_XFLIP negates row 0 of the projection matrix
	//  (gl_backend.c, GLBE_SelectEntity), mirroring the entity about the
	//  screen centreline — and every GoldSrc viewmodel ever made puts its arm
	//  at negative Y, i.e. screen right.  Which ARM was modelled is a property
	//  of the geometry, not of its position, and nothing measurable off the
	//  file distinguishes the two.  The in-game look is the only authority.
	//
	//  IT HAS NOW BEEN REPORTED TWICE, ABOUT ONE SHARED MESH.  First the three
	//  CS grenades (fixed in sh_wpn_csgrenades.qc), now all six CS handguns.
	//  Those are not independent assets: measured across the mounted cstrike
	//  models, the arm geometry of v_glock18, v_p228, v_p90, v_mac10, v_tmp,
	//  v_hegrenade, v_flashbang and v_smokegrenade spans an IDENTICAL
	//  -27.3 .. -4.6 in Y.  One arm, drawn by every one of them, and it reads
	//  as a left hand.  So the two reports are one report, and the fix is the
	//  same flip the grenades already carry.
	//
	//  TEN MORE CS WEAPONS DRAW THE SAME ARM and are therefore also mirrored,
	//  but have not been reported and are deliberately left alone rather than
	//  changed on inference: aug, elite (elite shares the arm at -21.0..-4.1),
	//  famas, galil, g3sg1, mac10, p90, sg550, sg552, tmp, ump45, xm1014.
	//  Flip those the same way if they look wrong too.
	//
	//  cl_lefthand XORs against this, so a player who wants the other hand
	//  still gets it, and reverting any of these is one word.
	// ============================================================
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
