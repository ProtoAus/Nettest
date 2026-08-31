// ============================================================
//  shared/weapons/sh_wpn_hlglock.qc  -  HL Glock (Semi-Auto Pistol)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 17-round magazine, 250 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlglock;
.float ammo_hlglock;

// Server-side reload sound latch.  CSQC keeps its own single global (there is
// only ever one predicted player); the server needs one per player.
.float hlglock_reload_snd_stage;

// Which reload drill is running: 1 = from empty (slide locked back).  Latched at
// reload start because the two takes are different lengths on the model that
// actually loads — see SH_HLGlockTickState.  Shared, not server-only: the client
// predicts the same reload and has to reach the same duration.
.float hlglock_reload_empty;

// --- Sequence indices, read out of valve/models/v_9mmhandgun.mdl (10 seqs) --
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/wpn_hlglock/
// v_glock.mdl, an 800-frame flat bake) by frame number.  It now drives Half-
// Life's own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: HLGLOCK_IDLE_FRAME was 124 and this
// model has ten sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// Indices and the empty/not-empty split are from the SDK, not guessed:
// glock.cpp:25-34 (the enum), :115 (draw), :146-149 (fire), :231 (reload).
//
// Durations below are (numframes - 1) / fps, which is what the ENGINE reports
// through frameduration() — engine/gl/gl_hlmdl.c:1542,
//     *duration = (sequence->numframes-1)/sequence->timing;
// — and what the SDK hardcodes for these same sequences (python.cpp:254 uses
// 70.0/30.0 for a 71-frame 30 fps sequence).  An N-frame animation spans N-1
// intervals.  Getting this wrong by the obvious numframes/fps overstates every
// duration by one frame period AND silently disagrees with SH_SeqDuration,
// which asks the engine.
const float HLGLOCK_SEQ_IDLE1            = 0;   // idle1,          3.750 s, looping
const float HLGLOCK_SEQ_IDLE2            = 1;   // idle2,          2.500 s, looping
const float HLGLOCK_SEQ_IDLE3            = 2;   // idle3,          3.500 s, looping
const float HLGLOCK_SEQ_SHOOT            = 3;   // shoot,          0.560 s
const float HLGLOCK_SEQ_SHOOT_EMPTY      = 4;   // shoot_empty,    0.560 s
const float HLGLOCK_SEQ_RELOAD           = 5;   // reload,         2.278 s  (slide locked back)
const float HLGLOCK_SEQ_RELOAD_NOTEMPTY  = 6;   // reload_noshot,  2.278 s  (round still chambered)
const float HLGLOCK_SEQ_DRAW             = 7;   // draw,           0.938 s
const float HLGLOCK_SEQ_HOLSTER          = 8;   // holster,        0.938 s
const float HLGLOCK_SEQ_ADD_SILENCER     = 9;   // add_silencer,   3.333 s

const float HLGLOCK_FRAME_INTERVAL       = 0.05;    // wepframe tick rate, not an anim rate
const float HLGLOCK_FIRE_DELAY           = 0.3;

// The clip-out / clip-in cues, as FRACTIONS of the reload take.  They used to be
// absolute times inherited from the old IDPO bake (0.556 / 1.667 of a 2.278 s
// reload, i.e. 0.244 / 0.732) and they were never checked against the model's own
// studio events, which are the frames the animator actually put the clip on:
//
//     valve     reload   f4/f23 of 42 @ 18   ->  0.098 / 0.561
//     svencoop  reload   f7/f27 of 56 @ 30   ->  0.127 / 0.491
//               reload_empty f8/f27 of 56 @ 28 -> 0.145 / 0.491
//
// So the magazine-out click was landing at the wrong end of the animation on
// EITHER model.  valve's numbers are the ones used — they are the canonical
// Half-Life timing and both models agree to within a tenth of the take — and
// holding them as fractions means the cue tracks whichever v_9mmhandgun.mdl is
// mounted (2.278 s on valve, 1.833/1.964 s on svencoop).
const float HLGLOCK_RELOAD_F_SND1        = 0.098;   // magazine out
const float HLGLOCK_RELOAD_F_SND2        = 0.561;   // magazine in

const float MAX_MAG_HLGLOCK              = 17;      // GLOCK_MAX_CLIP, glock.cpp
const float MAX_AMMO_HLGLOCK             = 250;

// --- Balance ---
const float HLGLOCK_BASE_SPREAD          = 0.01;
const float HLGLOCK_MOVE_SPREAD          = 0.04;
const float HLGLOCK_FULL_SPREAD_SPEED    = 320;
const float HLGLOCK_CLOSE_DAMAGE         = 16;
const float HLGLOCK_MIN_DAMAGE           = 8;
const float HLGLOCK_DAMAGE_FALLOFF_RANGE = 2048;
const float HLGLOCK_DRYFIRE_DELAY        = 0.2;
const float HLGLOCK_KICK_PITCH    = 0.5;   // sv_gunkick — light pistol.
const float HLGLOCK_KICK_VARIANCE = 0.25;
const float HLGLOCK_KICK_STRENGTH = 1.5;   // light pistol.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float HLGLOCK_MUZZLE_FORWARD = 38;
const float HLGLOCK_MUZZLE_RIGHT   = 6.4;
const float HLGLOCK_MUZZLE_DOWN    = 7.6;
const float HLGLOCK_ALT_FIRE_DELAY      = 0.2;   // auto-fire mode (faster)
const float HLGLOCK_ALT_SPREAD          = 0.04;  // wider spread in auto mode

// --- State durations, taken from the sequences themselves ---
// The old frame-bake values were 0.9375 / 0.55 / 2.278 — within a frame of
// these, because that IDPO conversion had been cut at Half-Life's own frame
// rates.  The reload is identical to three decimal places, which is why the
// sound offsets below carried across untouched.
//
// FALLBACKS ONLY.  valve's v_9mmhandgun.mdl is not the one that loads —
// svencoop ships its own and outranks valve in fs_addons.txt — and it is 0.800 s
// draw, 0.667 s shoot and TWO DIFFERENT reload lengths (1.833 s with a round
// still chambered, 1.964 s from empty) against the single 2.278 s hardcoded here.
// So the reload state outlived its animation by ~0.4 s and the pistol sat frozen
// on the last frame, unable to fire, for that whole window.
const float HLGLOCK_DRAW_DURATION        = 0.938;   // draw
const float HLGLOCK_FIRE_DURATION        = 0.560;   // shoot / shoot_empty
const float HLGLOCK_RELOAD_DURATION      = 2.278;   // reload / reload_noshot

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling - the SDK writes "v_9mmAR.mdl" in places but the shipped files are
// all lowercase, and FTE's VFS is case-sensitive against real files on Linux.
const string HLGLOCK_VIEWMODEL    = "models/v_9mmhandgun.mdl";
const string HLGLOCK_WORLDMODEL   = "models/w_9mmhandgun.mdl";
const string HLGLOCK_DEPLOY_SOUND = "";
const string HLGLOCK_DISPLAY_NAME = "HL GLOCK";

// ============================================================
//  SHARED — sequence resolution
//
//  THE TWO RELOAD NAMES ARE SWAPPED BETWEEN THE TWO MODELS, and resolving either
//  one by its own name alone hands back the OTHER variant:
//
//      index   valve             svencoop
//        5     reload            reload_empty     <- slide locked back
//        6     reload_noshot     reload           <- round still chambered
//
//  The INDICES agree by role, but "reload" means the empty drill on valve and
//  the not-empty drill on svencoop.  So each accessor asks for the spelling that
//  is unambiguous on the model that has it, and only then falls back.
// ============================================================

float() SH_HLGlockSeqIdle   = { return SH_SeqForName(HLGLOCK_VIEWMODEL, "idle1", HLGLOCK_SEQ_IDLE1); };
float() SH_HLGlockSeqDraw   = { return SH_SeqForName(HLGLOCK_VIEWMODEL, "draw",  HLGLOCK_SEQ_DRAW); };
float() SH_HLGlockSeqShoot  = { return SH_SeqForName(HLGLOCK_VIEWMODEL, "shoot", HLGLOCK_SEQ_SHOOT); };
float() SH_HLGlockSeqShootEmpty =
{
    return SH_SeqForName(HLGLOCK_VIEWMODEL, "shoot_empty", HLGLOCK_SEQ_SHOOT_EMPTY);
};

// Empty (slide locked back).  svencoop names it; valve calls it plain "reload".
float() SH_HLGlockSeqReloadEmpty =
{
    float s = SH_SeqTryName(HLGLOCK_VIEWMODEL, "reload_empty");
    if (s >= 0) return s;
    return SH_SeqForName(HLGLOCK_VIEWMODEL, "reload", HLGLOCK_SEQ_RELOAD);
};
// Round still chambered.  valve names it; svencoop calls it plain "reload".
float() SH_HLGlockSeqReloadNotEmpty =
{
    float s = SH_SeqTryName(HLGLOCK_VIEWMODEL, "reload_noshot");
    if (s >= 0) return s;
    s = SH_SeqTryName(HLGLOCK_VIEWMODEL, "reload_empty");   // svencoop shape
    if (s >= 0)
        return SH_SeqForName(HLGLOCK_VIEWMODEL, "reload", HLGLOCK_SEQ_RELOAD_NOTEMPTY);
    return HLGLOCK_SEQ_RELOAD_NOTEMPTY;
};

float(float mag) SH_HLGlockSeqReloadFor =
{
    return (mag > 0) ? SH_HLGlockSeqReloadNotEmpty() : SH_HLGlockSeqReloadEmpty();
};

float() SH_HLGlockDrawDuration = { return SH_SeqDuration(HLGLOCK_VIEWMODEL, SH_HLGlockSeqDraw(),  HLGLOCK_DRAW_DURATION); };
float() SH_HLGlockFireDuration = { return SH_SeqDuration(HLGLOCK_VIEWMODEL, SH_HLGlockSeqShoot(), HLGLOCK_FIRE_DURATION); };
// The two drills are DIFFERENT LENGTHS on svencoop's model, so this is keyed on
// the magazine exactly the way the sequence pick is.
float(float mag) SH_HLGlockReloadDurationFor =
{
    return SH_SeqDuration(HLGLOCK_VIEWMODEL, SH_HLGlockSeqReloadFor(mag), HLGLOCK_RELOAD_DURATION);
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_HLGlockTickState =
{
    // Which drill is running is LATCHED at reload start rather than derived from
    // the live magazine — same reason the SAW latches saw_reload_long.  The two
    // drills are different lengths on svencoop's model, and a client whose
    // magazine was topped up early by a server correction would otherwise flip
    // the answer mid-animation and retire the state 0.13 s early.
    float rel = SH_HLGlockReloadDurationFor(self.hlglock_reload_empty ? 0 : 1);
    return SH_StandardTickState(now, mag_hlglock, ammo_hlglock, MAX_MAG_HLGLOCK,
        SH_HLGlockDrawDuration(), SH_HLGlockFireDuration(),
        rel, rel);   // apply at the end of the take
};

float(float now) SH_HLGlockTryFire =
{
    return SH_StandardTryFire(now, mag_hlglock, HLGLOCK_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);
};

float(float now) SH_HLGlockTryReload =
{
    // Latch the drill BEFORE starting it.  Both sides compute this from the same
    // replicated magazine count, so client and server land on the same duration
    // and the same sequence — see SH_HLGlockTickState.
    self.hlglock_reload_empty = (self.mag_hlglock <= 0);
    return SH_StandardTryReload(now, mag_hlglock, ammo_hlglock, MAX_MAG_HLGLOCK,
        SH_HLGlockReloadDurationFor(self.hlglock_reload_empty ? 0 : 1));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLGlockPickupCopy =
{
    player.mag_hlglock  = self.mag_hlglock;
    player.ammo_hlglock = self.ammo_hlglock;
};

void() W_HLGlockShoot =
{
    W_PenetratingHitscanShoot(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
        HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        HLGLOCK_KICK_PITCH, HLGLOCK_KICK_VARIANCE, HLGLOCK_KICK_STRENGTH);
};

void() W_HLGlockFire =
{
    float r = SH_HLGlockTryFire(time);

    if (r == 1)
    {
        // SH_StandardTryFire has already decremented, so mag > 0 here means
        // "a round is still chambered" — the same post-decrement test the SDK
        // makes at glock.cpp:146.
        self.weaponframe   = (self.mag_hlglock > 0) ? SH_HLGlockSeqShoot()
                                                    : SH_HLGlockSeqShootEmpty();
        self.wep_nextframe = time + HLGLOCK_FRAME_INTERVAL;

        W_HLGlockShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlglock/fire.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_HLGlockAltFire =
{
    float r = SH_StandardTryFire(time, mag_hlglock, HLGLOCK_ALT_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);

    if (r == 1)
    {
        self.weaponframe   = (self.mag_hlglock > 0) ? SH_HLGlockSeqShoot()
                                                    : SH_HLGlockSeqShootEmpty();
        self.wep_nextframe = time + HLGLOCK_FRAME_INTERVAL;

        // Wider spread in auto mode
        W_PenetratingHitscanShoot(HLGLOCK_ALT_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
            HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
            HLGLOCK_KICK_PITCH, HLGLOCK_KICK_VARIANCE, HLGLOCK_KICK_STRENGTH);

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlglock/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLGlockReload =
{
    if (SH_HLGlockTryReload(time))
    {
        // glock.cpp:231 — the slide is only locked back when the magazine ran
        // dry, so a reload with a round left plays the shorter-looking variant.
        self.weaponframe   = SH_HLGlockSeqReloadFor(self.hlglock_reload_empty ? 0 : 1);
        self.wep_nextframe = time + HLGLOCK_FRAME_INTERVAL;
        self.hlglock_reload_snd_stage = 0;
    }
};

void() W_HLGlockFrame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of a ten-sequence model
    // within half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only has to decide
    // WHICH sequence is playing and when the state ends.
    self.wep_nextframe += HLGLOCK_FRAME_INTERVAL;

    // Reload sounds moved from frame numbers to elapsed time, which is what
    // the CSQC half of this file already did (it had no frame counter to key
    // off) — so the two sides now share one set of constants instead of two
    // representations of the same instants.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        float rel_dur = SH_HLGlockReloadDurationFor(self.hlglock_reload_empty ? 0 : 1);
        if (self.hlglock_reload_snd_stage < 1
            && reload_elapsed >= rel_dur * HLGLOCK_RELOAD_F_SND1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlglock/reload1.wav", 1, ATTN_NORM);
            self.hlglock_reload_snd_stage = 1;
        }
        if (self.hlglock_reload_snd_stage < 2
            && reload_elapsed >= rel_dur * HLGLOCK_RELOAD_F_SND2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlglock/reload2.wav", 1, ATTN_NORM);
            self.hlglock_reload_snd_stage = 2;
        }
    }

    result = SH_HLGlockTickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_HLGlockSeqIdle();
        self.wep_nextframe = 0;
    }
};

void() W_HLGlockEquip =
{
    W_StandardEquipSetup(HLGLOCK_VIEWMODEL, HLGLOCK_DISPLAY_NAME, SH_HLGlockSeqDraw(),
        HLGLOCK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HLGlockFire;
    self.altfire  = W_HLGlockAltFire;
    self.reload   = W_HLGlockReload;
    self.wepframe = W_HLGlockFrame;
    self.shoot    = W_HLGlockShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_HLGlockDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlglock  = self.mag_hlglock;
    tgt.ammo_hlglock = self.ammo_hlglock;

    self.mag_hlglock  = 0;
    self.ammo_hlglock = 0;

    setmodel(tgt, HLGLOCK_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname    = "weapon_hlglock";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLGLOCK;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_HLGlockEquip;
    tgt.weap_drop_func = W_HLGlockDrop;
    tgt.pickupcopy   = W_HLGlockPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlglock =
{
    setmodel(self, HLGLOCK_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname     = "weapon_hlglock";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLGLOCK;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_HLGlockEquip;
    self.weap_drop_func = W_HLGlockDrop;
    self.pickupcopy    = W_HLGlockPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlglock   = MAX_MAG_HLGLOCK;
    self.ammo_hlglock  = MAX_AMMO_HLGLOCK;
    W_RegisterMapWeapon(weapon_hlglock);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// HLGLOCK_RELOAD_SND1_TIME / _SND2_TIME are now declared once at the top of
// the file and shared with the server half — they used to be derived here from
// frame numbers that no longer exist.

float csqc_hlglock_reload_snd_stage;

void() CSQC_PredictHLGlockCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_HLGlockTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("sounds/weapons/wpn_hlglock/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(HLGLOCK_BASE_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
                    HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    HLGLOCK_KICK_PITCH, HLGLOCK_KICK_VARIANCE, HLGLOCK_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(HLGLOCK_MUZZLE_FORWARD, HLGLOCK_MUZZLE_RIGHT,
                    HLGLOCK_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(HLGLOCK_MUZZLE_FORWARD, HLGLOCK_MUZZLE_RIGHT,
                    HLGLOCK_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
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

    // Alt-fire: auto mode (button 4 = +attack2)
    if (input_buttons & 4)
    {
        r = SH_StandardTryFire(csqc_pred_time, mag_hlglock, HLGLOCK_ALT_FIRE_DELAY, HLGLOCK_DRYFIRE_DELAY);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("sounds/weapons/wpn_hlglock/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(HLGLOCK_ALT_SPREAD, HLGLOCK_MOVE_SPREAD, HLGLOCK_FULL_SPREAD_SPEED,
                    HLGLOCK_CLOSE_DAMAGE, HLGLOCK_MIN_DAMAGE, HLGLOCK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    HLGLOCK_KICK_PITCH, HLGLOCK_KICK_VARIANCE, HLGLOCK_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(HLGLOCK_MUZZLE_FORWARD, HLGLOCK_MUZZLE_RIGHT,
                    HLGLOCK_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(HLGLOCK_MUZZLE_FORWARD, HLGLOCK_MUZZLE_RIGHT,
                    HLGLOCK_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel_dur = SH_HLGlockReloadDurationFor(self.hlglock_reload_empty ? 0 : 1);
        if (csqc_hlglock_reload_snd_stage < 1
            && reload_elapsed >= rel_dur * HLGLOCK_RELOAD_F_SND1)
        {
            localsound("sounds/weapons/wpn_hlglock/reload1.wav"); CSQC_RecordPredictedAutoSound();
            csqc_hlglock_reload_snd_stage = 1;
        }
        if (csqc_hlglock_reload_snd_stage < 2
            && reload_elapsed >= rel_dur * HLGLOCK_RELOAD_F_SND2)
        { localsound("sounds/weapons/wpn_hlglock/reload2.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlglock_reload_snd_stage = 2; }
    }

    SH_HLGlockTickState(csqc_pred_time);
};

void() CSQC_PredictHLGlockReload =
{
    if (SH_HLGlockTryReload(csqc_pred_time))
    { csqc_hlglock_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so the `elapsed`
// argument is no longer used here — it stays in the signature because
// csqc_display_frame is a shared function pointer type.
float(float elapsed) CSQC_HLGlockDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_HLGlockSeqDraw();
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_hlglock > 0) ? SH_HLGlockSeqShoot()
                                                  : SH_HLGlockSeqShootEmpty();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_HLGlockSeqReloadFor(predicted_player.hlglock_reload_empty ? 0 : 1);
    return SH_HLGlockSeqIdle();
};

void() CSQC_HLGlockDropClear =
{
	self.mag_hlglock = 0;
	self.ammo_hlglock = 0;
};

void() CSQC_HLGlockEquip =
{
	self.weapon_name         = HLGLOCK_DISPLAY_NAME;
	self.weapon_viewmodel    = HLGLOCK_VIEWMODEL;
	self.weapon_worldmodel   = HLGLOCK_WORLDMODEL;
	self.weapon_deploy_sound = HLGLOCK_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLGlockCommand;
	self.csqc_predict_reload = CSQC_PredictHLGlockReload;
	self.csqc_display_frame  = CSQC_HLGlockDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLGlockDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
