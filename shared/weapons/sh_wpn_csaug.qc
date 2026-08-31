// ============================================================
//  shared/weapons/sh_wpn_csaug.qc  -  Counter-Strike Steyr AUG
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : low-power 1.2x on +attack2, via the shared ADS profile
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_aug.mdl, models/w_aug.mdl,
// models/p_aug.mdl and every sound below resolve through the mounted cstrike
// gamedir (fs_addons.txt:16), exactly the way sh_wpn_csglock.qc takes
// models/v_glock18.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl from
// valve.  The mod's CrossFire AUG (sh_wpn_cfaug.qc) is a DIFFERENT weapon with
// its own shipped model set and keeps the bare "aug" manifest key; this one
// answers to "csaug".
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_aug.mdl itself, not guessed:
//
//   [0] idle     30fps   9 frames  0.267s
//   [1] reload   40fps 133 frames  3.300s
//         f10  5004 "weapons/aug_boltpull.wav"   frac 0.0758
//         f50  5004 "weapons/aug_clipout.wav"    frac 0.3788
//         f88  5004 "weapons/aug_clipin.wav"     frac 0.6667
//         f112 5004 "weapons/aug_boltslap.wav"   frac 0.8485
//   [2] draw     35fps  31 frames  0.857s
//         f9   5004 "weapons/aug_forearm.wav"    frac 0.3000
//   [3] shoot1   35fps  31 frames  0.857s   f0 5001 (muzzleflash, attachment 2)
//   [4] shoot2   35fps  31 frames  0.857s   f0 5001
//   [5] shoot3   35fps  31 frames  0.857s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.

// --- Ammo fields ---
.float mag_aug;
.float ammo_aug;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt:16-17)
// and both ship models/v_aug.mdl with the same labels at different fps and frame
// counts — czero's idle is 2 frames where cstrike's is 9, and its reload events
// sit at different frames.  Whichever mount wins, resolving by name and scaling
// every mark by that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSAUG_SEQ_IDLE   = 0;
const float CSAUG_SEQ_RELOAD = 1;
const float CSAUG_SEQ_DRAW   = 2;
const float CSAUG_SEQ_SHOOT1 = 3;
const float CSAUG_SEQ_SHOOT2 = 4;
const float CSAUG_SEQ_SHOOT3 = 5;

const float CSAUG_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSAUG_FIRE_DELAY       = 0.09;        // CS 1.6 AUG is ~666 rpm
const float CSAUG_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSAUG_DRAW_F_FOREARM   = 0.3000;   // frame   9 / 30
const float CSAUG_RELOAD_F_BOLT    = 0.0758;   // frame  10 / 132
const float CSAUG_RELOAD_F_CLIPOUT = 0.3788;   // frame  50 / 132
const float CSAUG_RELOAD_F_CLIPIN  = 0.6667;   // frame  88 / 132
const float CSAUG_RELOAD_F_SLAP    = 0.8485;   // frame 112 / 132
const float CSAUG_RELOAD_F_APPLY   = 0.7000;   // just after the fresh mag seats

const float MAX_MAG_CSAUG          = 30;
const float MAX_AMMO_CSAUG         = 90;

// --- Balance ---
//
// Anchored on sh_wpn_cfaug.qc, which is the same real rifle already placed on
// this mod's ladder (31/22 close/min).  Nudged to 32/21 so the CS pair orders
// the way CS 1.6 orders it — the SG-552 is the slightly harder-hitting T-side
// mirror and sits at 33 — while staying below the AK47's 34 and above the
// M4A1's 24.  Falloff matches the CF twin and the AK47 at 2304.
const float CSAUG_BASE_SPREAD          = 0.010;
const float CSAUG_MOVE_SPREAD          = 0.07;
const float CSAUG_FULL_SPREAD_SPEED    = 320;
const float CSAUG_CLOSE_DAMAGE         = 32;
const float CSAUG_MIN_DAMAGE           = 21;
const float CSAUG_DAMAGE_FALLOFF_RANGE = 2304;
const float CSAUG_KICK_PITCH    = 1.3;   // sv_gunkick — very controllable rifle.
const float CSAUG_KICK_VARIANCE = 1.2;
const float CSAUG_KICK_STRENGTH = 1.0;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the CF twin; the CS mesh is a different model, so treat these as a starting
// point rather than tuned values.
const float CSAUG_MUZZLE_FORWARD = 44;
const float CSAUG_MUZZLE_RIGHT   = 8.9;
const float CSAUG_MUZZLE_DOWN    = 5.4;

const string CSAUG_VIEWMODEL    = "models/v_aug.mdl";
const string CSAUG_WORLDMODEL   = "models/w_aug.mdl";
const string CSAUG_DEPLOY_SOUND = "";
const string CSAUG_DISPLAY_NAME = "AUG";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float csaug_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSAugSeqIdle   = { return SH_SeqForName(CSAUG_VIEWMODEL, "idle",   CSAUG_SEQ_IDLE); };
float() SH_CSAugSeqReload = { return SH_SeqForName(CSAUG_VIEWMODEL, "reload", CSAUG_SEQ_RELOAD); };
float() SH_CSAugSeqDraw   = { return SH_SeqForName(CSAUG_VIEWMODEL, "draw",   CSAUG_SEQ_DRAW); };
float() SH_CSAugSeqShoot1 = { return SH_SeqForName(CSAUG_VIEWMODEL, "shoot1", CSAUG_SEQ_SHOOT1); };
float() SH_CSAugSeqShoot2 = { return SH_SeqForName(CSAUG_VIEWMODEL, "shoot2", CSAUG_SEQ_SHOOT2); };
float() SH_CSAugSeqShoot3 = { return SH_SeqForName(CSAUG_VIEWMODEL, "shoot3", CSAUG_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CFGLOCK pattern.
float(float action_id) SH_CSAugPickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSAugSeqShoot1();
    if (r < 0.6667) return SH_CSAugSeqShoot2();
    return SH_CSAugSeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSAugDrawDuration   = { return SH_SeqDuration(CSAUG_VIEWMODEL, SH_CSAugSeqDraw(),   0.857); };
float() SH_CSAugReloadDuration = { return SH_SeqDuration(CSAUG_VIEWMODEL, SH_CSAugSeqReload(), 3.300); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSAugTickState =
{
    float rel = SH_CSAugReloadDuration();
    return SH_StandardTickState(now, mag_aug, ammo_aug, MAX_MAG_CSAUG,
        SH_CSAugDrawDuration(),
        SH_SeqDuration(CSAUG_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSAUG_RELOAD_F_APPLY);
};

float(float now) SH_CSAugTryFire =
{
    return SH_StandardTryFire(now, mag_aug, CSAUG_FIRE_DELAY, CSAUG_DRYFIRE_DELAY);
};

float(float now) SH_CSAugTryReload =
{
    return SH_StandardTryReload(now, mag_aug, ammo_aug, MAX_MAG_CSAUG,
        SH_CSAugReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSAugPickupCopy =
{
    player.mag_aug  = self.mag_aug;
    player.ammo_aug = self.ammo_aug;
};

void() W_CSAugShoot =
{
    W_PenetratingHitscanShoot(CSAUG_BASE_SPREAD, CSAUG_MOVE_SPREAD, CSAUG_FULL_SPREAD_SPEED,
        CSAUG_CLOSE_DAMAGE, CSAUG_MIN_DAMAGE, CSAUG_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CSAUG_KICK_PITCH, CSAUG_KICK_VARIANCE, CSAUG_KICK_STRENGTH);
};

void() W_CSAugFire =
{
    float r = SH_CSAugTryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSAugPickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSAUG_FRAME_INTERVAL;
        self.csaug_snd_stage = 0;

        W_CSAugShoot();

        sound(self, CHAN_WEAPON, "weapons/aug-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSAugReload =
{
    if (SH_CSAugTryReload(time))
    {
        self.weaponframe     = SH_CSAugSeqReload();
        self.wep_nextframe   = time + CSAUG_FRAME_INTERVAL;
        self.csaug_snd_stage = 0;
    }
};

void() W_CSAugFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSAUG_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSAugDrawDuration() * CSAUG_DRAW_F_FOREARM
            && self.csaug_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/aug_forearm.wav", 1, ATTN_NORM);
            self.csaug_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSAugReloadDuration();

        if (elapsed >= rel * CSAUG_RELOAD_F_BOLT && self.csaug_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/aug_boltpull.wav", 1, ATTN_NORM);
            self.csaug_snd_stage = 1;
        }
        if (elapsed >= rel * CSAUG_RELOAD_F_CLIPOUT && self.csaug_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/aug_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.csaug_snd_stage = 2;
        }
        if (elapsed >= rel * CSAUG_RELOAD_F_CLIPIN && self.csaug_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/aug_clipin.wav", 1, ATTN_NORM);
            self.csaug_snd_stage = 3;
        }
        if (elapsed >= rel * CSAUG_RELOAD_F_SLAP && self.csaug_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "weapons/aug_boltslap.wav", 1, ATTN_NORM);
            self.csaug_snd_stage = 4;
        }
    }

    result = SH_CSAugTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSAugSeqIdle();
        self.wep_nextframe   = 0;
        self.csaug_snd_stage = 0;
    }
};

void() W_CSAugEquip =
{
    // The AUG's scope is the shared low-power rifle sight, driven off
    // weapon_scope_class by sh_pmove.qc / cl_codscope.qc — there is no altfire
    // hook and no per-weapon zoomstage, which is how the CF twin does it too.
    W_SetADSProfile(FALSE, "cl_ads_csaug", SCOPE_CLASS_RIFLE_LOWPOWER);
    W_StandardEquipSetup(CSAUG_VIEWMODEL, CSAUG_DISPLAY_NAME, SH_CSAugSeqDraw(),
        CSAUG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSAugFire;
    self.reload   = W_CSAugReload;
    self.wepframe = W_CSAugFrame;
    self.shoot    = W_CSAugShoot;
    self.csaug_snd_stage = 0;
    W_SetCrosshairProfile(CSAUG_BASE_SPREAD, CSAUG_MOVE_SPREAD, CSAUG_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CSAugDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_aug  = self.mag_aug;
    tgt.ammo_aug = self.ammo_aug;

    self.mag_aug  = 0;
    self.ammo_aug = 0;

    setmodel(tgt, CSAUG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_aug";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSAUG;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSAugEquip;
    tgt.weap_drop_func = W_CSAugDrop;
    tgt.pickupcopy     = W_CSAugPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_aug had zero references in
// this tree before this weapon existed, so nothing is displaced and a GoldSrc
// CS map placing one now gets the AUG rather than "no spawn function".
void() weapon_aug =
{
    setmodel(self, CSAUG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_aug";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSAUG;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSAugEquip;
    self.weap_drop_func = W_CSAugDrop;
    self.pickupcopy     = W_CSAugPickupCopy;
    self.touch          = weapon_touch;
    self.mag_aug      = MAX_MAG_CSAUG;
    self.ammo_aug     = MAX_AMMO_CSAUG;
    W_RegisterMapWeapon(weapon_aug);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_csaug_snd_stage;
float csqc_csaug_snd_action;

void() CSQC_PredictCSAugCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_csaug_snd_action)
    {
        csqc_csaug_snd_action = predicted_player.wep_action_id;
        csqc_csaug_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSAugTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/aug-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSAUG_BASE_SPREAD, CSAUG_MOVE_SPREAD, CSAUG_FULL_SPREAD_SPEED,
                    CSAUG_CLOSE_DAMAGE, CSAUG_MIN_DAMAGE, CSAUG_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSAUG_KICK_PITCH, CSAUG_KICK_VARIANCE, CSAUG_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSAUG_MUZZLE_FORWARD, CSAUG_MUZZLE_RIGHT,
                    CSAUG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSAUG_MUZZLE_FORWARD, CSAUG_MUZZLE_RIGHT,
                    CSAUG_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_csaug_snd_stage < 1
                && elapsed >= SH_CSAugDrawDuration() * CSAUG_DRAW_F_FOREARM)
            {
                localsound("weapons/aug_forearm.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csaug_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSAugReloadDuration();

            if (csqc_csaug_snd_stage < 1 && elapsed >= rel * CSAUG_RELOAD_F_BOLT)
            {
                localsound("weapons/aug_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csaug_snd_stage = 1;
            }
            if (csqc_csaug_snd_stage < 2 && elapsed >= rel * CSAUG_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/aug_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_csaug_snd_stage = 2;
            }
            if (csqc_csaug_snd_stage < 3 && elapsed >= rel * CSAUG_RELOAD_F_CLIPIN)
            {
                localsound("weapons/aug_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csaug_snd_stage = 3;
            }
            if (csqc_csaug_snd_stage < 4 && elapsed >= rel * CSAUG_RELOAD_F_SLAP)
            {
                localsound("weapons/aug_boltslap.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csaug_snd_stage = 4;
            }
        }
    }

    SH_CSAugTickState(csqc_pred_time);
};

void() CSQC_PredictCSAugReload =
{
    if (SH_CSAugTryReload(csqc_pred_time))
    {
        csqc_csaug_snd_stage  = 0;
        csqc_csaug_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSAugDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSAugSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSAugSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSAugPickShootSeq(predicted_player.wep_action_id);

    return SH_CSAugSeqIdle();
};

void() CSQC_CSAugDropClear =
{
    self.mag_aug  = 0;
    self.ammo_aug = 0;
};

void() CSQC_CSAugEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_csaug", SCOPE_CLASS_RIFLE_LOWPOWER);
    self.weapon_name         = CSAUG_DISPLAY_NAME;
    self.weapon_viewmodel    = CSAUG_VIEWMODEL;
    self.weapon_worldmodel   = CSAUG_WORLDMODEL;
    self.weapon_deploy_sound = CSAUG_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSAugCommand;
    self.csqc_predict_reload = CSQC_PredictCSAugReload;
    self.csqc_display_frame  = CSQC_CSAugDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSAugDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED.  The old claim here — "the CrossFire viewmodels are mirrored and
    // set weapon_viewmodel_flip, the Counter-Strike ones are not" — was wrong,
    // and sh_wpn_csglock.qc:664 already named this weapon as one of the ten that
    // draw the same stock cstrike arm and would need the same flip "if they look
    // wrong too".  Reported left-handed in game, so they do.
    //
    // Not inference from a Y measurement, which only tells you screen side: the
    // rhand/lhand meshes in this model are BYTE-IDENTICAL to the ones in
    // v_glock18 / v_usp / v_p228 / v_hegrenade, which are all flipped, with the
    // same bind pose.  One arm, drawn by all of them.
    //
    // cl_lefthand XORs against this, so a player who wants the other hand still
    // gets it, and reverting is one word.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
