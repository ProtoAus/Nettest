// ============================================================
//  shared/weapons/sh_wpn_csp228.qc  -  Counter-Strike SIG P228
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 13-round magazine, 52 reserve, semi-auto .357 SIG
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  ADS   : plain iron-sight ADS, no scope class
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_p228.mdl, models/w_p228.mdl,
// models/p_p228.mdl and every "weapons/..." sound below resolve through the
// mounted cstrike gamedir (fs_addons.txt), exactly the way sh_wpn_csaug.qc
// takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl
// from valve.  The mod's CrossFire P228 (sh_wpn_cfp228.qc) is a DIFFERENT
// weapon with its own shipped model set under models/weapons/wpn_cfp228/ and
// keeps the bare "p228" manifest key; this one answers to "csp228".
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_p228.mdl itself, not guessed.  The quoted
// names are the contents of each studio event's options[64] field — the model
// names its own sounds — and the fractions are eventframe/(numframes-1),
// which is the form SH_SeqDuration scales:
//
//   [0] idle1        16fps  11f  0.625s
//   [1] shoot1       34fps  26f  0.735s   f0 5001 muzzleflash
//   [2] shoot2       34fps  26f  0.735s   f0 5001
//   [3] shoot3       34fps  26f  0.735s   f0 5001
//   [4] shoot_empty  34fps  26f  0.735s   f0 5001
//   [5] reload       35fps  96f  2.714s
//         f24 "weapons/p228_clipout.wav"       frac 0.2526
//         f49 "weapons/p228_clipin.wav"        frac 0.5158
//         f81 "weapons/p228_sliderelease.wav"  frac 0.8526
//   [6] draw         30fps  31f  1.000s
//         f1  "weapons/de_deploy.wav"          frac 0.0333
//         f15 "weapons/p228_slidepull.wav"     frac 0.5000
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  FTE does NOT auto-play those markers; the timed sounds below are
// driven from QC against wep_anim_start elapsed time on both sides.

// --- Ammo fields ---
.float mag_p228;
.float ammo_p228;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt)
// and both ship models/v_p228.mdl with the same labels at different fps and
// frame counts.  Whichever mount wins, resolving by name and scaling every
// mark by that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does
// not, so an index-keyed lookup would be reading a sequence that is not there.
const float CSP228_SEQ_IDLE   = 0;
const float CSP228_SEQ_SHOOT1 = 1;
const float CSP228_SEQ_SHOOT2 = 2;
const float CSP228_SEQ_SHOOT3 = 3;
const float CSP228_SEQ_SHOOTE = 4;   // shoot_empty — last round out, slide locks back
const float CSP228_SEQ_RELOAD = 5;
const float CSP228_SEQ_DRAW   = 6;

const float CSP228_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSP228_FIRE_DELAY       = 0.15;        // semi-auto tap rate, CF twin's cadence
const float CSP228_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
// Never absolute seconds: czero's copy of this model runs the same labels at a
// different fps, and an absolute mark would drift off the animation there.
const float CSP228_DRAW_F_DEPLOY    = 0.0333;   // frame  1 / 30
const float CSP228_DRAW_F_SLIDEPULL = 0.5000;   // frame 15 / 30
const float CSP228_RELOAD_F_CLIPOUT = 0.2526;   // frame 24 / 95
const float CSP228_RELOAD_F_CLIPIN  = 0.5158;   // frame 49 / 95
const float CSP228_RELOAD_F_SLIDE   = 0.8526;   // frame 81 / 95
const float CSP228_RELOAD_F_APPLY   = 0.6000;   // just after the fresh mag seats

const float MAX_MAG_CSP228          = 13;
const float MAX_AMMO_CSP228         = 52;

// --- Balance ---
//
// Anchored on sh_wpn_cfp228.qc, which is the same real pistol already placed
// on this mod's ladder — 28/16 close/min, 0.011/0.058 spread, 13/52 ammo — and
// those carry over unchanged so the CF and CS P228s hit identically.  What
// moves is the tail: falloff goes 1900 -> 2048 to sit on the CS pistol family's
// range (sh_wpn_csglock.qc is 2048) rather than the CF ladder's, and the kick
// comes up a touch (0.55/0.7 -> 0.6/0.8) because this is the .357 SIG chambering
// the CS buy menu sells at 600 — noticeably punchier in the hand than the CF
// twin, while still far below the Deagle.  Against the CS Glock beside it in
// the slot (18/10) the P228 is the fewer-rounds/harder-hitting choice, which is
// the ordering CS 1.6 itself has.
const float CSP228_BASE_SPREAD          = 0.011;
const float CSP228_MOVE_SPREAD          = 0.058;
const float CSP228_FULL_SPREAD_SPEED    = 320;
const float CSP228_CLOSE_DAMAGE         = 28;
const float CSP228_MIN_DAMAGE           = 16;
const float CSP228_DAMAGE_FALLOFF_RANGE = 2048;
const float CSP228_KICK_PITCH    = 0.6;    // sv_gunkick — compact service pistol.
const float CSP228_KICK_VARIANCE = 0.35;
const float CSP228_KICK_STRENGTH = 0.8;

// Wall-penetration budget for W_PenetratingHitscanShoot: 8 units of pierce at
// 0.94 damage retained per unit.  These are the CS pistol values that
// sh_wpn_csglock.qc uses — NOT the CF twin's 28, which is a rifle-grade budget
// that would let a sidearm shoot through cover the AK47 respects.
const float CSP228_PEN_POWER    = 8;
const float CSP228_PEN_DMG_MULT = 0.94;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Camera-local
// (forward / right / down) rather than the CF twin's bone attachment, because
// the cstrike mesh is a different model with a different rig.
const float CSP228_MUZZLE_FORWARD = 34;
const float CSP228_MUZZLE_RIGHT   = 12.5;
const float CSP228_MUZZLE_DOWN    = 8.5;

const string CSP228_VIEWMODEL    = "models/v_p228.mdl";
const string CSP228_WORLDMODEL   = "models/w_p228.mdl";
const string CSP228_DEPLOY_SOUND = "";
const string CSP228_DISPLAY_NAME = "P228";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float p228_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSP228SeqIdle   = { return SH_SeqForName(CSP228_VIEWMODEL, "idle1",       CSP228_SEQ_IDLE); };
float() SH_CSP228SeqShoot1 = { return SH_SeqForName(CSP228_VIEWMODEL, "shoot1",      CSP228_SEQ_SHOOT1); };
float() SH_CSP228SeqShoot2 = { return SH_SeqForName(CSP228_VIEWMODEL, "shoot2",      CSP228_SEQ_SHOOT2); };
float() SH_CSP228SeqShoot3 = { return SH_SeqForName(CSP228_VIEWMODEL, "shoot3",      CSP228_SEQ_SHOOT3); };
float() SH_CSP228SeqShootE = { return SH_SeqForName(CSP228_VIEWMODEL, "shoot_empty", CSP228_SEQ_SHOOTE); };
float() SH_CSP228SeqReload = { return SH_SeqForName(CSP228_VIEWMODEL, "reload",      CSP228_SEQ_RELOAD); };
float() SH_CSP228SeqDraw   = { return SH_SeqForName(CSP228_VIEWMODEL, "draw",        CSP228_SEQ_DRAW); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CSGLOCK pattern.  `mag_left` is
// the magazine count AFTER this shot (SH_StandardTryFireSemiAuto has already
// decremented it): at zero the model has a dedicated slide-locks-back take, and
// both sides reach it from the same post-shot count so neither rubber-bands.
float(float action_id, float mag_left) SH_CSP228PickShootSeq =
{
    if (mag_left <= 0)
        return SH_CSP228SeqShootE();
    float r = SH_SpreadHash(action_id);
    if (r < 0.3333) return SH_CSP228SeqShoot1();
    if (r < 0.6667) return SH_CSP228SeqShoot2();
    return SH_CSP228SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSP228DrawDuration   = { return SH_SeqDuration(CSP228_VIEWMODEL, SH_CSP228SeqDraw(),   1.000); };
float() SH_CSP228ReloadDuration = { return SH_SeqDuration(CSP228_VIEWMODEL, SH_CSP228SeqReload(), 2.714); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSP228TickState =
{
    float rel = SH_CSP228ReloadDuration();
    return SH_StandardTickState(now, mag_p228, ammo_p228, MAX_MAG_CSP228,
        SH_CSP228DrawDuration(),
        SH_SeqDuration(CSP228_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSP228_RELOAD_F_APPLY);
};

float(float now) SH_CSP228TryFire =
{
    // Semi-auto: the trigger must be released between shots.  A real P228 is
    // not full-auto and holding +attack must not empty the magazine.
    return SH_StandardTryFireSemiAuto(now, mag_p228, CSP228_FIRE_DELAY, CSP228_DRYFIRE_DELAY);
};

float(float now) SH_CSP228TryReload =
{
    return SH_StandardTryReload(now, mag_p228, ammo_p228, MAX_MAG_CSP228,
        SH_CSP228ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSP228PickupCopy =
{
    player.mag_p228  = self.mag_p228;
    player.ammo_p228 = self.ammo_p228;
};

void() W_CSP228Shoot =
{
    W_PenetratingHitscanShoot(CSP228_BASE_SPREAD, CSP228_MOVE_SPREAD, CSP228_FULL_SPREAD_SPEED,
        CSP228_CLOSE_DAMAGE, CSP228_MIN_DAMAGE, CSP228_DAMAGE_FALLOFF_RANGE,
        CSP228_PEN_POWER, CSP228_PEN_DMG_MULT,
        CSP228_KICK_PITCH, CSP228_KICK_VARIANCE, CSP228_KICK_STRENGTH);
};

void() W_CSP228Fire =
{
    float r = SH_CSP228TryFire(time);

    if (r == 1)
    {
        // mag_p228 is already decremented by SH_StandardTryFireSemiAuto, so
        // this is the post-shot count — which is what selects shoot_empty.
        self.weaponframe    = SH_CSP228PickShootSeq(self.wep_action_id, self.mag_p228);
        self.wep_nextframe  = time + CSP228_FRAME_INTERVAL;
        self.p228_snd_stage = 0;

        W_CSP228Shoot();

        sound(self, CHAN_WEAPON, "weapons/p228-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSP228Reload =
{
    if (SH_CSP228TryReload(time))
    {
        self.weaponframe    = SH_CSP228SeqReload();
        self.wep_nextframe  = time + CSP228_FRAME_INTERVAL;
        self.p228_snd_stage = 0;
    }
};

void() W_CSP228Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSP228_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        // The draw carries TWO studio events, not one — the deploy clack and,
        // half a second later, the slide pull.  Two stages, therefore.
        float drw = SH_CSP228DrawDuration();

        if (elapsed >= drw * CSP228_DRAW_F_DEPLOY && self.p228_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/de_deploy.wav", 1, ATTN_NORM);
            self.p228_snd_stage = 1;
        }
        if (elapsed >= drw * CSP228_DRAW_F_SLIDEPULL && self.p228_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/p228_slidepull.wav", 1, ATTN_NORM);
            self.p228_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSP228ReloadDuration();

        if (elapsed >= rel * CSP228_RELOAD_F_CLIPOUT && self.p228_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/p228_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.p228_snd_stage = 1;
        }
        if (elapsed >= rel * CSP228_RELOAD_F_CLIPIN && self.p228_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/p228_clipin.wav", 1, ATTN_NORM);
            self.p228_snd_stage = 2;
        }
        if (elapsed >= rel * CSP228_RELOAD_F_SLIDE && self.p228_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/p228_sliderelease.wav", 1, ATTN_NORM);
            self.p228_snd_stage = 3;
        }
    }

    result = SH_CSP228TickState(time);
    if (result & 1)
    {
        self.weaponframe    = SH_CSP228SeqIdle();
        self.wep_nextframe  = 0;
        self.p228_snd_stage = 0;
    }
};

void() W_CSP228Equip =
{
    // Iron sights only — no scope class, so cl_codscope never engages and the
    // ADS pose comes straight off the shared cl_ads_csp228 profile.
    W_SetADSProfile(TRUE, "cl_ads_csp228", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSP228_VIEWMODEL, CSP228_DISPLAY_NAME, SH_CSP228SeqDraw(),
        CSP228_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSP228Fire;
    self.reload   = W_CSP228Reload;
    self.wepframe = W_CSP228Frame;
    self.shoot    = W_CSP228Shoot;
    self.p228_snd_stage = 0;
    W_SetCrosshairProfile(CSP228_BASE_SPREAD, CSP228_MOVE_SPREAD, CSP228_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_CSP228Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_p228  = self.mag_p228;
    tgt.ammo_p228 = self.ammo_p228;

    self.mag_p228  = 0;
    self.ammo_p228 = 0;

    setmodel(tgt, CSP228_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname      = "weapon_p228";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSP228;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_CSP228Equip;
    tgt.weap_drop_func = W_CSP228Drop;
    tgt.pickupcopy     = W_CSP228PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_p228 had zero references in
// this tree before this weapon existed — the CrossFire twin spawns as
// weapon_cfp228 — so nothing is displaced and a GoldSrc CS map placing one now
// gets the P228 rather than "no spawn function".
void() weapon_p228 =
{
    setmodel(self, CSP228_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname      = "weapon_p228";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSP228;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_CSP228Equip;
    self.weap_drop_func = W_CSP228Drop;
    self.pickupcopy     = W_CSP228PickupCopy;
    self.touch          = weapon_touch;
    self.mag_p228       = MAX_MAG_CSP228;
    self.ammo_p228      = MAX_AMMO_CSP228;
    W_RegisterMapWeapon(weapon_p228);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_p228_snd_stage;
float csqc_p228_snd_action;

void() CSQC_PredictCSP228Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_p228_snd_action)
    {
        csqc_p228_snd_action = predicted_player.wep_action_id;
        csqc_p228_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSP228TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/p228-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSP228_BASE_SPREAD, CSP228_MOVE_SPREAD, CSP228_FULL_SPREAD_SPEED,
                    CSP228_CLOSE_DAMAGE, CSP228_MIN_DAMAGE, CSP228_DAMAGE_FALLOFF_RANGE,
                    CSP228_PEN_POWER, CSP228_PEN_DMG_MULT,
                    CSP228_KICK_PITCH, CSP228_KICK_VARIANCE, CSP228_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSP228_MUZZLE_FORWARD, CSP228_MUZZLE_RIGHT,
                    CSP228_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSP228_MUZZLE_FORWARD, CSP228_MUZZLE_RIGHT,
                    CSP228_MUZZLE_DOWN, self.wep_action_id, 1);
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
            // Two draw events, mirroring W_CSP228Frame stage for stage.
            float drw = SH_CSP228DrawDuration();

            if (csqc_p228_snd_stage < 1 && elapsed >= drw * CSP228_DRAW_F_DEPLOY)
            {
                localsound("weapons/de_deploy.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p228_snd_stage = 1;
            }
            if (csqc_p228_snd_stage < 2 && elapsed >= drw * CSP228_DRAW_F_SLIDEPULL)
            {
                localsound("weapons/p228_slidepull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p228_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSP228ReloadDuration();

            if (csqc_p228_snd_stage < 1 && elapsed >= rel * CSP228_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/p228_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_p228_snd_stage = 1;
            }
            if (csqc_p228_snd_stage < 2 && elapsed >= rel * CSP228_RELOAD_F_CLIPIN)
            {
                localsound("weapons/p228_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p228_snd_stage = 2;
            }
            if (csqc_p228_snd_stage < 3 && elapsed >= rel * CSP228_RELOAD_F_SLIDE)
            {
                localsound("weapons/p228_sliderelease.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p228_snd_stage = 3;
            }
        }
    }

    SH_CSP228TickState(csqc_pred_time);
};

void() CSQC_PredictCSP228Reload =
{
    if (SH_CSP228TryReload(csqc_pred_time))
    {
        csqc_p228_snd_stage  = 0;
        csqc_p228_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  The
// shoot pick reads the SAME post-shot magazine count the server used, so an
// emptying shot shows the slide-locks-back take on both sides.
float(float elapsed) CSQC_CSP228DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSP228SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSP228SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSP228PickShootSeq(predicted_player.wep_action_id,
                                     predicted_player.mag_p228);

    return SH_CSP228SeqIdle();
};

void() CSQC_CSP228DropClear =
{
    self.mag_p228  = 0;
    self.ammo_p228 = 0;
};

void() CSQC_CSP228Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csp228", SCOPE_CLASS_NONE);
    self.weapon_name         = CSP228_DISPLAY_NAME;
    self.weapon_viewmodel    = CSP228_VIEWMODEL;
    self.weapon_worldmodel   = CSP228_WORLDMODEL;
    self.weapon_deploy_sound = CSP228_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSP228Command;
    self.csqc_predict_reload = CSQC_PredictCSP228Reload;
    self.csqc_display_frame  = CSQC_CSP228DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSP228DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED.  This used to read "the CrossFire viewmodels are mirrored and
    // set weapon_viewmodel_flip, the Counter-Strike ones are not" -- but the CS
    // handguns were reported left-handed in game, and they all draw the same
    // stock cstrike arm mesh.  Full reasoning in sh_wpn_csglock.qc.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
