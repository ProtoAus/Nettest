// ============================================================
//  shared/weapons/sh_wpn_hl357.qc  -  HL .357 Revolver
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 18 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Model : Half-Life's own v_357.mdl / w_357.mdl (IDST, sequence-driven)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_357;
.float ammo_357;

// Server-side reload sound latch.  CSQC keeps its own single global (there is
// only ever one predicted player); the server needs one per player.
.float w357_reload_snd_played;

// --- Sequence indices, read out of valve/models/v_357.mdl (8 seqs) ---------
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/wpn_hl357/
// v_357.mdl, a flat 200-frame bake) by frame number.  It now drives Half-
// Life's own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: W357_IDLE_FRAME was 78 and this model
// has eight sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// Indices are the SDK's enum verbatim - python.cpp:26-35.  (The SDK file is
// python.cpp, not 357.cpp; python.cpp:37-38 links BOTH weapon_python and
// weapon_357 to CPython, which is why the mod's classname still works.)
// The pick sites are python.cpp:115 (DefaultDeploy -> PYTHON_DRAW), :130
// (holster) and :236 (DefaultReload -> PYTHON_RELOAD).
//
// Durations below are (numframes - 1) / fps, NOT numframes / fps: an N-frame
// animation spans N-1 intervals.  That is what the engine hands back, so it is
// what SH_SeqDuration() sees — gl_hlmdl.c:1542 `*duration =
// (sequence->numframes-1)/sequence->timing;` — and the SDK hardcodes the same
// convention for these exact sequences: python.cpp:254 uses (70.0/30.0) for
// the 71-frame idle1, :259 (60.0/30.0) for the 61-frame idle2, :264
// (88.0/30.0) for the 89-frame idle3 and :269 (170.0/30.0) for the 171-frame
// fidget1.
const float W357_SEQ_IDLE1            = 0;   // idle1,    2.333 s (71f @ 30), looping
const float W357_SEQ_FIDGET           = 1;   // fidget1,  5.667 s (171f @ 30)  (SDK idle variant, see below)
const float W357_SEQ_FIRE1            = 2;   // fire1,    1.000 s (31f @ 30)
const float W357_SEQ_RELOAD           = 3;   // reload,   3.056 s (111f @ 36) — the only reload variant
const float W357_SEQ_HOLSTER          = 4;   // holster,  0.500 s (16f @ 30)
const float W357_SEQ_DRAW             = 5;   // draw,     0.500 s (16f @ 30)
const float W357_SEQ_IDLE2            = 6;   // idle2,    2.000 s (61f @ 30), looping
const float W357_SEQ_IDLE3            = 7;   // idle3,    2.933 s (89f @ 30), looping

// Unlike the Glock the Python has NO shoot_empty / reload_noshot pair, and the
// SDK never branches on m_iClip for an animation: PrimaryAttack sends fire1
// unconditionally (python.cpp:184-207) and Reload always passes PYTHON_RELOAD
// (python.cpp:236).  So there is no post-decrement mag test to reproduce here.
//
// WeaponIdle (python.cpp:250-270) rolls between IDLE1/IDLE2/IDLE3/FIDGET on
// the shared random seed.  This mod has a single idle slot per weapon, so the
// three unused indices above are declared for completeness and idle parks on
// IDLE1 — the SDK's own 50% majority case.

const float W357_FRAME_INTERVAL       = 0.05;   // wepframe tick rate, not an anim rate
const float W357_FIRE_DELAY           = 0.75;

// The reload sound instant comes from the MODEL's own animation event rather
// than from the old bake: valve's sequence 3 carries exactly one event, a 5004
// (CL_EVENT_SOUND) at frame 70 of 111 @ 36 fps, firing weapons/357_reload1.wav
// — which is what sounds/weapons/wpn_hl357/reload.wav is a copy of.  The
// frame-number version cued at 2.05 s (frame 180 of 139..200 @ 20 fps), i.e.
// ~106 ms behind the animation it was scoring.
//
// HELD AS A FRACTION, NOT A TIME.  Frame 70 of 110 intervals is 0.636 of the
// take whichever v_357.mdl is mounted, and svencoop's — which is the one that
// actually wins, see the duration block below — is 2.500 s rather than 3.056 s.
// An absolute 1.944 s would land at 78 % of it.
const float W357_RELOAD_F_SOUND       = 0.636;

const float MAX_MAG_357               = 6;   // PYTHON_MAX_CLIP, python.cpp
const float MAX_AMMO_357              = 18;

// --- Balance ---
const float W357_BASE_SPREAD          = 0.01;
const float W357_MOVE_SPREAD          = 0.03;
const float W357_FULL_SPREAD_SPEED    = 320;
const float W357_CLOSE_DAMAGE         = 70;
const float W357_MIN_DAMAGE           = 45;
const float W357_DAMAGE_FALLOFF_RANGE = 4096;
const float W357_DRYFIRE_DELAY        = 0.2;
const float W357_KICK_PITCH    = 1.6;   // sv_gunkick — heavy magnum, one big kick per shot.
const float W357_KICK_VARIANCE = 0.5;
const float W357_KICK_STRENGTH = 1.4;   // single-shot pistol — long delay, big kick.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float W357_MUZZLE_FORWARD = 38;
const float W357_MUZZLE_RIGHT   = 9.25;
const float W357_MUZZLE_DOWN    = 7.9;

// --- State durations, taken from the sequences themselves ---
// (numframes - 1) / fps, matching frameduration() / SH_SeqDuration() exactly —
// see the note above the sequence table.  Anything else and this file's idea of
// when an animation ends disagrees with the engine's.
// The old derived values landed within ~50 ms of these because the IDPO bake
// had been resampled from these same animations onto a flat 20 fps timeline.
//
// FALLBACKS ONLY — and this weapon is why the whole family got looked at.  These
// are valve's numbers and valve's v_357.mdl is not what loads: svencoop ships its
// own (1.3 MB against 146 KB, same 8 sequences in the same order) and outranks
// valve in fs_addons.txt.  Its reload is 101f @ 40 fps = 2.500 s, so a state
// hardcoded to 3.056 s held the viewmodel FROZEN ON THE LAST FRAME for 0.556 s
// after every reload — a non-LOOP sequence clamps at numframes-1
// (gl_hlmdl.c:1076-1082) — and the gun could not be fired for that whole window.
// Also draw 0.500 -> 0.533.  Every state below now asks the live model.
const float W357_DRAW_DURATION      = 0.500;   // draw,   15/30
const float W357_FIRE_DURATION      = 1.000;   // fire1,  30/30
const float W357_RELOAD_DURATION    = 3.056;   // reload, 110/36

// Unlike most weapons here the rounds land MID-animation, and they always have.
// It used to be the absolute instant the frame-number version used —
// (184 - 139) * 0.05 = 2.25 s — but on a 2.500 s reload that is 90 % of the take
// rather than 74 %, so it now rides the take as a fraction: 2.25/3.056 = 0.736.
// It still sits after the model's own cylinder-close event and before the gun is
// back up on both candidate models.  (The SDK is close but not identical:
// python.cpp:236 passes fDelay 2.0 to DefaultReload.)
const float W357_RELOAD_F_APPLY     = 0.736;

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling — FTE's VFS is case-sensitive against real files on Linux, and
// these resolve through the Steam mount, not out of the mod dir.
// python.cpp:84-86 precaches v_/w_/p_357.mdl; the p_ model is the manifest's
// job, not this file's (see the migration notes).
const string W357_VIEWMODEL    = "models/v_357.mdl";
const string W357_WORLDMODEL   = "models/w_357.mdl";
const string W357_DEPLOY_SOUND = "";
const string W357_DISPLAY_NAME = ".357";

// ============================================================
//  SHARED — sequence resolution
//
//  By NAME, with the SDK index as the fallback, and lengths from the live model
//  — see the FALLBACKS ONLY note above the duration block.  The two candidate
//  models carry the same eight names in the same order, so only the lengths
//  differ, but resolving by name costs nothing and survives a third model.
// ============================================================

float() SH_357SeqDraw     = { return SH_SeqForName(W357_VIEWMODEL, "draw",   W357_SEQ_DRAW); };
float() SH_357SeqFire     = { return SH_SeqForName(W357_VIEWMODEL, "fire1",  W357_SEQ_FIRE1); };
float() SH_357SeqReload   = { return SH_SeqForName(W357_VIEWMODEL, "reload", W357_SEQ_RELOAD); };
float() SH_357SeqIdle     = { return SH_SeqForName(W357_VIEWMODEL, "idle1",  W357_SEQ_IDLE1); };

float() SH_357DrawDuration   = { return SH_SeqDuration(W357_VIEWMODEL, SH_357SeqDraw(),   W357_DRAW_DURATION); };
float() SH_357FireDuration   = { return SH_SeqDuration(W357_VIEWMODEL, SH_357SeqFire(),   W357_FIRE_DURATION); };
float() SH_357ReloadDuration = { return SH_SeqDuration(W357_VIEWMODEL, SH_357SeqReload(), W357_RELOAD_DURATION); };
float() SH_357ReloadSndTime  = { return SH_357ReloadDuration() * W357_RELOAD_F_SOUND; };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_357TickState =
{
    float rel = SH_357ReloadDuration();
    return SH_StandardTickState(now, mag_357, ammo_357, MAX_MAG_357,
        SH_357DrawDuration(), SH_357FireDuration(),
        rel, rel * W357_RELOAD_F_APPLY);
};

float(float now) SH_357TryFire =
{
    // Semi-auto: revolver — must release +attack between shots.
    return SH_StandardTryFireSemiAuto(now, mag_357, W357_FIRE_DELAY, W357_DRYFIRE_DELAY);
};

float(float now) SH_357TryReload =
{
    // 357 blocks reload during attack cooldown (unique to this weapon)
    if (now < self.attack_finished)
        return 0;
    return SH_StandardTryReload(now, mag_357, ammo_357, MAX_MAG_357, SH_357ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_357PickupCopy =
{
    player.mag_357  = self.mag_357;
    player.ammo_357 = self.ammo_357;
};

void() W_357Shoot =
{
    W_PenetratingHitscanShoot(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED,
        W357_CLOSE_DAMAGE, W357_MIN_DAMAGE, W357_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        W357_KICK_PITCH, W357_KICK_VARIANCE, W357_KICK_STRENGTH);
};

void() W_357Fire =
{
    float r = SH_357TryFire(time);

    if (r == 1)
    {
        // Single fire sequence — python.cpp:184-207 decrements m_iClip and then
        // plays the same animation whether or not a round is left, so there is
        // no empty variant to select against the post-decrement magazine.
        self.weaponframe   = SH_357SeqFire();
        self.wep_nextframe = time + W357_FRAME_INTERVAL;

        W_357Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NORM);
    }
};

void() W_357Reload =
{
    if (SH_357TryReload(time))
    {
        // python.cpp:236 — DefaultReload always gets PYTHON_RELOAD; the Python
        // has no reload_noshot counterpart to branch to.
        self.weaponframe   = SH_357SeqReload();
        self.wep_nextframe = time + W357_FRAME_INTERVAL;
        self.w357_reload_snd_played = FALSE;
    }
};

void() W_357Frame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of an eight-sequence model
    // inside half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only has to decide
    // WHICH sequence is playing and when the state ends.
    self.wep_nextframe += W357_FRAME_INTERVAL;

    // The reload sound moved from a frame number to elapsed time, which is
    // exactly what the CSQC half of this file already did — both sides now
    // read one W357_RELOAD_SND_TIME instead of two representations of the same
    // instant.  Latched, because this runs every W357_FRAME_INTERVAL for the
    // whole 3.056 s reload and would otherwise retrigger every tick past the
    // threshold.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        if (!self.w357_reload_snd_played
            && (time - self.wep_anim_start) >= SH_357ReloadSndTime())
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hl357/reload.wav", 1, ATTN_NORM);
            self.w357_reload_snd_played = TRUE;
        }
    }

    result = SH_357TickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_357SeqIdle();
        self.wep_nextframe = 0;
    }
};

void() W_357Equip =
{
    W_StandardEquipSetup(W357_VIEWMODEL, W357_DISPLAY_NAME, SH_357SeqDraw(),
        W357_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_357Fire;
    self.reload   = W_357Reload;
    self.wepframe = W_357Frame;
    self.shoot    = W_357Shoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED, 1.4, TRUE);
};

void() W_357Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_357  = self.mag_357;
    tgt.ammo_357 = self.ammo_357;

    self.mag_357  = 0;
    self.ammo_357 = 0;

    setmodel(tgt, W357_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname    = "weapon_357";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_357;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_357Equip;
    tgt.weap_drop_func = W_357Drop;
    tgt.pickupcopy   = W_357PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_357 =
{
    setmodel(self, W357_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname     = "weapon_357";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_357;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_357Equip;
    self.weap_drop_func = W_357Drop;
    self.pickupcopy    = W_357PickupCopy;
    self.touch         = weapon_touch;
    self.mag_357       = MAX_MAG_357;
    self.ammo_357      = MAX_AMMO_357;
    W_RegisterMapWeapon(weapon_357);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_357_reload_snd_played;
// W357_RELOAD_SND_TIME is declared once at the top of the file and shared with
// the server half — it used to be derived here from frame numbers that no
// longer exist, and the server used to key the same sound off a raw frame
// index instead.

void() CSQC_Predict357Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_357TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED,
                    W357_CLOSE_DAMAGE, W357_MIN_DAMAGE, W357_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    W357_KICK_PITCH, W357_KICK_VARIANCE, W357_KICK_STRENGTH);
                // Pistol muzzle flash — DEAGLE_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(W357_MUZZLE_FORWARD, W357_MUZZLE_RIGHT,
                    W357_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(W357_MUZZLE_FORWARD, W357_MUZZLE_RIGHT,
                    W357_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted reload sound
    if (self.weaponstate == WS_RELOAD && !csqc_357_reload_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= SH_357ReloadSndTime())
        { localsound("sounds/weapons/wpn_hl357/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_357_reload_snd_played = TRUE; }
    }

    SH_357TickState(csqc_pred_time);
};

void() CSQC_Predict357Reload =
{
    if (SH_357TryReload(csqc_pred_time))
    { csqc_357_reload_snd_played = FALSE; CSQC_MarkPendingWeaponAck(); }
};

// Returns a SEQUENCE index now, not an interpolated frame number, so
// CSQC_StandardDisplayFrame (which lerps a flat frame range) no longer
// applies.  The engine does the within-sequence advance itself from
// .frame1time, which is why `elapsed` goes unused here — it stays in the
// signature because csqc_display_frame is a shared function-pointer type.
//
// One sequence per state: the Python carries no empty/non-empty variants
// (python.cpp:184-207, :236), so unlike the Glock there is no magazine test
// to mirror here.
float(float elapsed) CSQC_357DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_357SeqDraw();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_357SeqFire();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_357SeqReload();
    return SH_357SeqIdle();
};

void() CSQC_357DropClear =
{
	self.mag_357 = 0;
	self.ammo_357 = 0;
};

void() CSQC_357Equip =
{
	self.weapon_name         = W357_DISPLAY_NAME;
	self.weapon_viewmodel    = W357_VIEWMODEL;
	self.weapon_worldmodel   = W357_WORLDMODEL;
	self.weapon_deploy_sound = W357_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_Predict357Command;
	self.csqc_predict_reload = CSQC_Predict357Reload;
	self.csqc_display_frame  = CSQC_357DisplayFrame;
	self.csqc_drop_clear     = CSQC_357DropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
