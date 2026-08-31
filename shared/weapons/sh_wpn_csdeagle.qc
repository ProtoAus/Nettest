// ============================================================
//  shared/weapons/sh_wpn_csdeagle.qc  -  Desert Eagle
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 35 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
//  Shared logic runs on both sides; #ifdef gates server-only
//  and client-only sections.
// ============================================================

// --- Ammo fields ---
.float mag_deagle;
.float ammo_deagle;

// ============================================================
//  THE VIEWMODEL IS THE MOUNTED ONE NOW
// ============================================================
//
// This weapon used to load models/weapons/wpn_csdeagle/v_deagle.mdl, a 3.5 MB
// mod-bundled IDPO (Quake MDL) re-bake with 180 stepped frames — which is what
// every constant in the old version of this block indexed.  Reported as "the
// deagle still uses the games models and not the mounted models".
//
// models/v_deagle.mdl resolves through the mounted cstrike gamedir (fs_addons.txt)
// like the AWP, the P228 and the rest of the CS set, so the whole animation half
// of this file goes SEQUENCE-DRIVEN with the path, exactly as sh_wpn_csawp.qc did:
// no per-tick weaponframe stepping, every take resolved by NAME, every duration
// read off whichever copy actually loaded, every sound cue held as a FRACTION of
// its own take.  czero also ships a v_deagle.mdl at a different size, and the
// name+fraction form is what keeps the sounds on the animation if the mount order
// ever hands us that one instead.
//
// Read out of cstrike/models/v_deagle.mdl itself — 6 sequences, 43 bones:
//
//   [0] idle1        16fps   2f  0.062s
//   [1] shoot1       40fps  24f  0.575s   f0 5001 muzzleflash 21
//   [2] shoot2       40fps  24f  0.575s   f0 5001
//   [3] shoot_empty  40fps  24f  0.575s   f0 5001   <- last round out, slide back
//   [4] reload       30fps  66f  2.167s
//         f14 "weapons/de_clipout.wav"   frac 0.2154
//         f34 "weapons/de_clipin.wav"    frac 0.5231
//   [5] draw         30fps  31f  1.000s
//         f1  "weapons/de_deploy.wav"    frac 0.0333
//
// THE SOUNDS STAY OURS.  Only the model moved; sounds/weapons/wpn_csdeagle/*.wav
// still ship with the mod and are what plays, at the fractions the studio events
// mark.  FTE does not auto-play 5004 markers, so QC drives them on both sides.
//
// NOTE the shoot list is TWO takes plus shoot_empty, not three — this model has
// no shoot3, unlike the P228.  SH_DeaglePickShootSeq splits on the halfway point
// rather than in thirds because of it.

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DEAGLE_SEQ_IDLE   = 0;
const float DEAGLE_SEQ_SHOOT1 = 1;
const float DEAGLE_SEQ_SHOOT2 = 2;
const float DEAGLE_SEQ_SHOOTE = 3;   // shoot_empty
const float DEAGLE_SEQ_RELOAD = 4;
const float DEAGLE_SEQ_DRAW   = 5;

const float DEAGLE_FIRE_DELAY        = 0.3;
const float DEAGLE_FRAME_INTERVAL    = 0.0333334;   // state-machine tick rate

// Event marks as a FRACTION of their own sequence — never seconds.
const float DEAGLE_DRAW_F_DEPLOY     = 0.0333;   // frame  1 / 30
const float DEAGLE_RELOAD_F_CLIPOUT  = 0.2154;   // frame 14 / 65
const float DEAGLE_RELOAD_F_CLIPIN   = 0.5231;   // frame 34 / 65
// Just after the fresh magazine seats.  The old frame-stepped value was 0.875 of
// the take; 0.60 puts it a beat after clipin (0.523) instead of nearly at the end,
// which is where the round actually becomes available on this animation.
const float DEAGLE_RELOAD_F_APPLY    = 0.6000;

const float MAX_MAG_DEAGLE           = 7;
const float MAX_AMMO_DEAGLE          = 35;

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed draw/reload events latch off elapsed time instead of a frame number.
.float deagle_snd_stage;

// --- Balance ---
const float DEAGLE_BASE_SPREAD          = 0.01;
const float DEAGLE_MOVE_SPREAD          = 0.06;
const float DEAGLE_FULL_SPREAD_SPEED    = 320;
const float DEAGLE_CLOSE_DAMAGE         = 35;
const float DEAGLE_MIN_DAMAGE           = 18;
const float DEAGLE_DAMAGE_FALLOFF_RANGE = 4096;
const float DEAGLE_DRYFIRE_DELAY        = 0.2;
const float DEAGLE_KICK_PITCH    = 1.6;   // sv_gunkick — heavy pistol, big single kick.
const float DEAGLE_KICK_VARIANCE = 0.5;
const float DEAGLE_KICK_STRENGTH = 1.4;   // single-shot pistol — long delay.

// Camera-local muzzle offset for the two-frame sprite muzzle flash
// (cl_muzzleflash.qc CSQC_MuzzleFlashAtMuzzle). Pistol barrel sits
// closer to the camera than a rifle — shorter FORWARD value.
//   FORWARD  qu in front of the camera origin
//   RIGHT    qu to the right (cl_lefthand mirrors)
//   DOWN     qu below the camera origin
const float DEAGLE_MUZZLE_FORWARD = 38;
const float DEAGLE_MUZZLE_RIGHT   = 10.3;
const float DEAGLE_MUZZLE_DOWN    = 5;

const string DEAGLE_VIEWMODEL    = "models/v_deagle.mdl";
const string DEAGLE_WORLDMODEL   = "models/w_deagle.mdl";
// The DEPLOY SOUND stays the mod's own sample, and it is deliberately left on
// weapon_deploy_sound rather than moved onto the draw take's f1 event: the equip
// path plays it at the moment of the switch, which is what the rest of the tree
// does.  W_DeagleFrame therefore does NOT re-play it at DEAGLE_DRAW_F_DEPLOY.
const string DEAGLE_DEPLOY_SOUND = "sounds/weapons/wpn_csdeagle/deploy.wav";
const string DEAGLE_DISPLAY_NAME = "DEAGLE";

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DeagleSeqIdle   = { return SH_SeqForName(DEAGLE_VIEWMODEL, "idle1",       DEAGLE_SEQ_IDLE); };
float() SH_DeagleSeqShoot1 = { return SH_SeqForName(DEAGLE_VIEWMODEL, "shoot1",      DEAGLE_SEQ_SHOOT1); };
float() SH_DeagleSeqShoot2 = { return SH_SeqForName(DEAGLE_VIEWMODEL, "shoot2",      DEAGLE_SEQ_SHOOT2); };
float() SH_DeagleSeqShootE = { return SH_SeqForName(DEAGLE_VIEWMODEL, "shoot_empty", DEAGLE_SEQ_SHOOTE); };
float() SH_DeagleSeqReload = { return SH_SeqForName(DEAGLE_VIEWMODEL, "reload",      DEAGLE_SEQ_RELOAD); };
float() SH_DeagleSeqDraw   = { return SH_SeqForName(DEAGLE_VIEWMODEL, "draw",        DEAGLE_SEQ_DRAW); };

// Deterministic shoot-take pick from wep_action_id so both sides agree which one
// plays — the P228 / Glock pattern.  `mag_left` is the count AFTER this shot
// (SH_StandardTryFireSemiAuto has already decremented it): at zero the model has
// a dedicated slide-locks-back take, and both sides reach it from the same
// post-shot count, so neither rubber-bands into the wrong animation.
float(float action_id, float mag_left) SH_DeaglePickShootSeq =
{
    if (mag_left <= 0)
        return SH_DeagleSeqShootE();
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DeagleSeqShoot1() : SH_DeagleSeqShoot2();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_DeagleDrawDuration   = { return SH_SeqDuration(DEAGLE_VIEWMODEL, SH_DeagleSeqDraw(),   1.000); };
float() SH_DeagleReloadDuration = { return SH_SeqDuration(DEAGLE_VIEWMODEL, SH_DeagleSeqReload(), 2.167); };
// All three shoot takes are the same length on this model, so shoot1 answers for
// the pair.  Read by NAME, not from self.weaponframe: that field is stamped by
// the server and is never written client-side, so it reads 0 there — see the long
// note in sh_wpn_csawp.qc, where the same shortcut cut the bolt cycle in half.
float() SH_DeagleFireDuration   = { return SH_SeqDuration(DEAGLE_VIEWMODEL, SH_DeagleSeqShoot1(), 0.575); };

// ============================================================
//  SHARED — state machine (server & client identical)
// ============================================================

// Returns bitmask: bit 0 = transitioned to idle, bit 1 = reload ammo applied
float(float now) SH_DeagleTickState =
{
    float rel = SH_DeagleReloadDuration();
    return SH_StandardTickState(now, mag_deagle, ammo_deagle, MAX_MAG_DEAGLE,
        SH_DeagleDrawDuration(), SH_DeagleFireDuration(),
        rel, rel * DEAGLE_RELOAD_F_APPLY);
};

// Returns: 1 = fired, -1 = dry fire, 0 = blocked
float(float now) SH_DeagleTryFire =
{
    // Semi-auto: must release +attack between shots (matches CS 1.6 Deagle).
    return SH_StandardTryFireSemiAuto(now, mag_deagle, DEAGLE_FIRE_DELAY, DEAGLE_DRYFIRE_DELAY);
};

// Returns: 1 = reload started, 0 = blocked
float(float now) SH_DeagleTryReload =
{
    return SH_StandardTryReload(now, mag_deagle, ammo_deagle, MAX_MAG_DEAGLE,
        SH_DeagleReloadDuration());
};

// ============================================================
//  SERVER ONLY — authoritative fire, reload, frame, equip,
//  pickup, drop, world entity
// ============================================================

#ifdef SSQC

void(entity player) W_DeaglePickupCopy =
{
    player.mag_deagle  = self.mag_deagle;
    player.ammo_deagle = self.ammo_deagle;
};

void() W_DeagleShoot =
{
    W_PenetratingHitscanShoot(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED,
        DEAGLE_CLOSE_DAMAGE, DEAGLE_MIN_DAMAGE, DEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        DEAGLE_KICK_PITCH, DEAGLE_KICK_VARIANCE, DEAGLE_KICK_STRENGTH);
};

// Fire — called by W_WeaponFrame when button0 pressed (self = player)
void() W_DeagleFire =
{
    float r = SH_DeagleTryFire(time);

    if (r == 1)
    {
        // Sequence index, not a start frame.  mag_deagle has already been
        // decremented by the try-fire, so this is the post-shot count the client's
        // predictor also sees — the two pick the same take.
        self.weaponframe    = SH_DeaglePickShootSeq(self.wep_action_id, self.mag_deagle);
        self.wep_nextframe  = time + DEAGLE_FRAME_INTERVAL;
        self.deagle_snd_stage = 0;

        W_DeagleShoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

// Reload — called on impulse 6 / R key (self = player)
void() W_DeagleReload =
{
    if (SH_DeagleTryReload(time))
    {
        self.weaponframe      = SH_DeagleSeqReload();
        self.wep_nextframe    = time + DEAGLE_FRAME_INTERVAL;
        self.deagle_snd_stage = 0;
    }
};

// Frame — advances animation state machine (self = player)
void() W_DeagleFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += DEAGLE_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DeagleReloadDuration();

        if (elapsed >= rel * DEAGLE_RELOAD_F_CLIPOUT && self.deagle_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
            self.deagle_snd_stage = 1;
        }
        if (elapsed >= rel * DEAGLE_RELOAD_F_CLIPIN && self.deagle_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipin.wav", 1, ATTN_NORM);
            self.deagle_snd_stage = 2;
        }
    }

    // Shared state transitions (idle transition + reload ammo apply)
    result = SH_DeagleTickState(time);
    if (result & 1)
    {
        self.weaponframe      = SH_DeagleSeqIdle();
        self.wep_nextframe    = 0;
        self.deagle_snd_stage = 0;
    }
};

void() W_DeagleEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_deagle", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DEAGLE_VIEWMODEL, DEAGLE_DISPLAY_NAME, SH_DeagleSeqDraw(),
        DEAGLE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DeagleFire;
    self.reload   = W_DeagleReload;
    self.wepframe = W_DeagleFrame;
    self.shoot    = W_DeagleShoot;
    self.deagle_snd_stage = 0;
    W_SetCrosshairProfile(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

// Drop — called by W_DropCurrentWeapon (self = player)
void() W_DeagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_deagle  = self.mag_deagle;
    tgt.ammo_deagle = self.ammo_deagle;

    self.mag_deagle  = 0;
    self.ammo_deagle = 0;

    setmodel(tgt, "models/w_deagle.mdl");
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname    = "weapon_deagle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_DEAGLE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_DeagleEquip;
    tgt.weap_drop_func = W_DeagleDrop;
    tgt.pickupcopy   = W_DeaglePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

// World entity — spawned from map (classname "weapon_deagle")
void() weapon_deagle =
{
    setmodel(self, "models/w_deagle.mdl");
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname     = "weapon_deagle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_DEAGLE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_DeagleEquip;
    self.weap_drop_func = W_DeagleDrop;
    self.pickupcopy    = W_DeaglePickupCopy;
    self.touch         = weapon_touch;
    self.mag_deagle    = MAX_MAG_DEAGLE;
    self.ammo_deagle   = MAX_AMMO_DEAGLE;
    W_RegisterMapWeapon(weapon_deagle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

float csqc_deagle_reload_snd_stage;

void() CSQC_PredictDeagleCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_DeagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    localsound("sounds/weapons/wpn_csdeagle/fire1.wav");
                else
                    localsound("sounds/weapons/wpn_csdeagle/fire2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED,
                    DEAGLE_CLOSE_DAMAGE, DEAGLE_MIN_DAMAGE, DEAGLE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    DEAGLE_KICK_PITCH, DEAGLE_KICK_VARIANCE, DEAGLE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Animated frame-walk muzzle flash — deagle test.
                // Tune position via DEAGLE_MUZZLE_* above, framerate
                // via cl_muzzleflash_anim_fps (default 30).  Other
                // weapons still use the 4-variant static path.
                CSQC_MuzzleFlashAtMuzzleAnimated(DEAGLE_MUZZLE_FORWARD, DEAGLE_MUZZLE_RIGHT,
                    DEAGLE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DEAGLE_MUZZLE_FORWARD, DEAGLE_MUZZLE_RIGHT,
                    DEAGLE_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted reload sounds
    // Timed off the loaded model's own reload length now, not off frame numbers
    // that no longer exist.  Fractions, so czero's copy stays in sync too.
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel = SH_DeagleReloadDuration();
        if (csqc_deagle_reload_snd_stage < 1 && reload_elapsed >= rel * DEAGLE_RELOAD_F_CLIPOUT)
        {
            localsound("sounds/weapons/wpn_csdeagle/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_deagle_reload_snd_stage = 1;
        }
        if (csqc_deagle_reload_snd_stage < 2 && reload_elapsed >= rel * DEAGLE_RELOAD_F_CLIPIN)
        { localsound("sounds/weapons/wpn_csdeagle/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_deagle_reload_snd_stage = 2; }
    }

    SH_DeagleTickState(csqc_pred_time);
};

void() CSQC_PredictDeagleReload =
{
    if (SH_DeagleTryReload(csqc_pred_time))
    { csqc_deagle_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_DeagleDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DeagleSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DeagleSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DeaglePickShootSeq(predicted_player.wep_action_id,
                                     predicted_player.mag_deagle);
    return SH_DeagleSeqIdle();
};

void() CSQC_DeagleDropClear =
{
	self.mag_deagle = 0;
	self.ammo_deagle = 0;
};

void() CSQC_DeagleEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_deagle", SCOPE_CLASS_NONE);
	self.weapon_name         = DEAGLE_DISPLAY_NAME;
	self.weapon_viewmodel    = DEAGLE_VIEWMODEL;
	self.weapon_worldmodel   = DEAGLE_WORLDMODEL;
	self.weapon_deploy_sound = DEAGLE_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictDeagleCommand;
	self.csqc_predict_reload = CSQC_PredictDeagleReload;
	self.csqc_display_frame  = CSQC_DeagleDisplayFrame;
	self.csqc_drop_clear     = CSQC_DeagleDropClear;
    // The viewmodel is a GoldSrc studio model now, so the display frame returns a
    // SEQUENCE index.  Without this the renderer treats the return value as a
    // stepped frame number and the gun sits on frame 0 forever.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED.  The justification that used to sit here — "already
    // right-handed (100% of 4451 verts at negative Y, mean -10.19)" — measures
    // which side of the SCREEN the mesh draws on, not which arm was modelled;
    // every GoldSrc viewmodel is at negative Y.  Reported left-handed in game
    // along with the rest of the CS handguns.  Full reasoning in
    // sh_wpn_csglock.qc.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
