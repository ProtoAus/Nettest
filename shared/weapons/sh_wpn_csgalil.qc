// ============================================================
//  shared/weapons/sh_wpn_csgalil.qc  -  Counter-Strike IMI Galil
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 35-round magazine, 90 reserve, full-auto 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : none — plain ADS only, SCOPE_CLASS_NONE
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_galil.mdl, models/w_galil.mdl,
// models/p_galil.mdl and every "weapons/galil*.wav" below resolve through the
// mounted cstrike gamedir (fs_addons.txt:16), exactly the way sh_wpn_csaug.qc
// takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl
// from valve.  The mod's CrossFire Galil (sh_wpn_cfgalil.qc) is a DIFFERENT
// pickup with its own shipped model set under models/weapons/wpn_cfgalil/ and
// keeps the bare "cfgalil" manifest key; this one answers to "csgalil".
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_galil.mdl itself, not guessed:
//
//   [0] idle     30fps   2 frames  0.033s   <- two frames; a static pose
//   [1] reload   35fps  91 frames  2.571s
//         f15 5004 "weapons/galil_clipout.wav"   frac 0.1667
//         f47 5004 "weapons/galil_clipin.wav"    frac 0.5222
//         f65 5004 "weapons/galil_boltpull.wav"  frac 0.7222
//   [2] draw     35fps  36 frames  1.000s
//         f10 5004 "weapons/galil_boltpull.wav"  frac 0.2857
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
//
// Unlike the AUG the Galil has no dedicated boltslap sample — the same
// galil_boltpull.wav plays for the draw's charging handle and for the
// end-of-reload rack, which is what the two 5004 events actually name.

// --- Ammo fields ---
.float mag_galil;
.float ammo_galil;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted
// (fs_addons.txt:16-17) and both ship models/v_galil.mdl with the same labels
// at different fps and frame counts.  Whichever mount wins, resolving by name
// and scaling every mark by that model's own duration keeps the sounds on the
// animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSGALIL_SEQ_IDLE   = 0;
const float CSGALIL_SEQ_RELOAD = 1;
const float CSGALIL_SEQ_DRAW   = 2;
const float CSGALIL_SEQ_SHOOT1 = 3;
const float CSGALIL_SEQ_SHOOT2 = 4;
const float CSGALIL_SEQ_SHOOT3 = 5;

const float CSGALIL_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSGALIL_FIRE_DELAY       = 0.09;        // CS 1.6 Galil is ~666 rpm
const float CSGALIL_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSGALIL_DRAW_F_BOLT     = 0.2857;   // frame 10 / 35
const float CSGALIL_RELOAD_F_CLIPOUT = 0.1667;  // frame 15 / 90
const float CSGALIL_RELOAD_F_CLIPIN  = 0.5222;  // frame 47 / 90
const float CSGALIL_RELOAD_F_BOLT    = 0.7222;  // frame 65 / 90
// Ammo lands between the fresh mag seating (0.5222) and the closing rack
// (0.7222) — the round is chambered by the rack, but the player has the
// magazine in the gun before it, and crediting there keeps a cancelled reload
// from feeling like it stole the mag.
const float CSGALIL_RELOAD_F_APPLY   = 0.6800;

const float MAX_MAG_CSGALIL          = 35;
const float MAX_AMMO_CSGALIL         = 90;

// --- Balance ---
//
// 30/20 close/min is NOT a nudge off anything — it is copied exactly from
// sh_wpn_cfgalil.qc, because it is literally the same rifle already placed on
// this mod's ladder and two pickups of one gun should not hit differently.
// That places it at the bottom of the rifle band on purpose: the CS AUG sits at
// 32/21, the SG-552 at 33, the AK47 at 34 and the M4A1 at 24, and the Galil is
// the 2000-dollar T-side entry rifle (manifest price line: galil 2000 against
// famas 2250 and aug/sg552 3500 apiece).  What it buys for the money is the
// magazine — 35 rounds, the largest of any rifle here — and what it pays is
// accuracy and reach: BASE_SPREAD 0.012 is the loosest of the four new CS
// rifles (AUG 0.010) and FALLOFF_RANGE 2200 is the shortest (AUG and AK47 both
// 2304), so it wins the close room and loses the long hall.  Falloff matches
// the CF twin exactly for the same reason the damage does.
const float CSGALIL_BASE_SPREAD          = 0.012;
const float CSGALIL_MOVE_SPREAD          = 0.070;
const float CSGALIL_FULL_SPREAD_SPEED    = 320;
const float CSGALIL_CLOSE_DAMAGE         = 30;
const float CSGALIL_MIN_DAMAGE           = 20;
const float CSGALIL_DAMAGE_FALLOFF_RANGE = 2200;
const float CSGALIL_KICK_PITCH    = 1.45;  // sv_gunkick — climbs harder than
const float CSGALIL_KICK_VARIANCE = 1.35;  // the AUG's 1.3/1.2; the cheap gun
const float CSGALIL_KICK_STRENGTH = 1.0;   // is the one that walks off target.

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the AUG's numbers and shifted for the Galil's longer, lower-held mesh; treat
// these as a starting point rather than tuned values.
const float CSGALIL_MUZZLE_FORWARD = 43;
const float CSGALIL_MUZZLE_RIGHT   = 9.2;
const float CSGALIL_MUZZLE_DOWN    = 5.8;

const string CSGALIL_VIEWMODEL    = "models/v_galil.mdl";
const string CSGALIL_WORLDMODEL   = "models/w_galil.mdl";
const string CSGALIL_DEPLOY_SOUND = "";
const string CSGALIL_DISPLAY_NAME = "Galil";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float galil_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSGalilSeqIdle   = { return SH_SeqForName(CSGALIL_VIEWMODEL, "idle",   CSGALIL_SEQ_IDLE); };
float() SH_CSGalilSeqReload = { return SH_SeqForName(CSGALIL_VIEWMODEL, "reload", CSGALIL_SEQ_RELOAD); };
float() SH_CSGalilSeqDraw   = { return SH_SeqForName(CSGALIL_VIEWMODEL, "draw",   CSGALIL_SEQ_DRAW); };
float() SH_CSGalilSeqShoot1 = { return SH_SeqForName(CSGALIL_VIEWMODEL, "shoot1", CSGALIL_SEQ_SHOOT1); };
float() SH_CSGalilSeqShoot2 = { return SH_SeqForName(CSGALIL_VIEWMODEL, "shoot2", CSGALIL_SEQ_SHOOT2); };
float() SH_CSGalilSeqShoot3 = { return SH_SeqForName(CSGALIL_VIEWMODEL, "shoot3", CSGALIL_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CFGLOCK pattern.
float(float action_id) SH_CSGalilPickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSGalilSeqShoot1();
    if (r < 0.6667) return SH_CSGalilSeqShoot2();
    return SH_CSGalilSeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSGalilDrawDuration   = { return SH_SeqDuration(CSGALIL_VIEWMODEL, SH_CSGalilSeqDraw(),   1.000); };
float() SH_CSGalilReloadDuration = { return SH_SeqDuration(CSGALIL_VIEWMODEL, SH_CSGalilSeqReload(), 2.571); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSGalilTickState =
{
    float rel = SH_CSGalilReloadDuration();
    return SH_StandardTickState(now, mag_galil, ammo_galil, MAX_MAG_CSGALIL,
        SH_CSGalilDrawDuration(),
        SH_SeqDuration(CSGALIL_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSGALIL_RELOAD_F_APPLY);
};

float(float now) SH_CSGalilTryFire =
{
    // Full-auto rifle: FIRE_DELAY paces the cyclic rate and holding +attack
    // keeps firing.  Standard (NOT SemiAuto) try-fire gate.
    return SH_StandardTryFire(now, mag_galil, CSGALIL_FIRE_DELAY, CSGALIL_DRYFIRE_DELAY);
};

float(float now) SH_CSGalilTryReload =
{
    return SH_StandardTryReload(now, mag_galil, ammo_galil, MAX_MAG_CSGALIL,
        SH_CSGalilReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSGalilPickupCopy =
{
    player.mag_galil  = self.mag_galil;
    player.ammo_galil = self.ammo_galil;
};

void() W_CSGalilShoot =
{
    W_PenetratingHitscanShoot(CSGALIL_BASE_SPREAD, CSGALIL_MOVE_SPREAD, CSGALIL_FULL_SPREAD_SPEED,
        CSGALIL_CLOSE_DAMAGE, CSGALIL_MIN_DAMAGE, CSGALIL_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        CSGALIL_KICK_PITCH, CSGALIL_KICK_VARIANCE, CSGALIL_KICK_STRENGTH);
};

void() W_CSGalilFire =
{
    float r = SH_CSGalilTryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSGalilPickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSGALIL_FRAME_INTERVAL;
        self.galil_snd_stage = 0;

        W_CSGalilShoot();

        sound(self, CHAN_WEAPON, "weapons/galil-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSGalilReload =
{
    if (SH_CSGalilTryReload(time))
    {
        self.weaponframe     = SH_CSGalilSeqReload();
        self.wep_nextframe   = time + CSGALIL_FRAME_INTERVAL;
        self.galil_snd_stage = 0;
    }
};

void() W_CSGalilFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSGALIL_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSGalilDrawDuration() * CSGALIL_DRAW_F_BOLT
            && self.galil_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/galil_boltpull.wav", 1, ATTN_NORM);
            self.galil_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSGalilReloadDuration();

        if (elapsed >= rel * CSGALIL_RELOAD_F_CLIPOUT && self.galil_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/galil_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.galil_snd_stage = 1;
        }
        if (elapsed >= rel * CSGALIL_RELOAD_F_CLIPIN && self.galil_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/galil_clipin.wav", 1, ATTN_NORM);
            self.galil_snd_stage = 2;
        }
        if (elapsed >= rel * CSGALIL_RELOAD_F_BOLT && self.galil_snd_stage < 3)
        {
            // Same sample as the draw's charging handle — the model's third
            // reload event names galil_boltpull.wav, there is no boltslap file.
            sound(self, CHAN_AUTO, "weapons/galil_boltpull.wav", 1, ATTN_NORM);
            self.galil_snd_stage = 3;
        }
    }

    result = SH_CSGalilTickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSGalilSeqIdle();
        self.wep_nextframe   = 0;
        self.galil_snd_stage = 0;
    }
};

void() W_CSGalilEquip =
{
    // No scope of any kind on the Galil in CS 1.6 — plain iron-sight ADS, so
    // SCOPE_CLASS_NONE and the ADS-eligible flag set, unlike the AUG which
    // hands its low-power sight to the shared scope path.
    W_SetADSProfile(TRUE, "cl_ads_csgalil", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSGALIL_VIEWMODEL, CSGALIL_DISPLAY_NAME, SH_CSGalilSeqDraw(),
        CSGALIL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSGalilFire;
    self.reload   = W_CSGalilReload;
    self.wepframe = W_CSGalilFrame;
    self.shoot    = W_CSGalilShoot;
    self.galil_snd_stage = 0;
    W_SetCrosshairProfile(CSGALIL_BASE_SPREAD, CSGALIL_MOVE_SPREAD, CSGALIL_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_CSGalilDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_galil  = self.mag_galil;
    tgt.ammo_galil = self.ammo_galil;

    self.mag_galil  = 0;
    self.ammo_galil = 0;

    setmodel(tgt, CSGALIL_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_galil";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSGALIL;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSGalilEquip;
    tgt.weap_drop_func = W_CSGalilDrop;
    tgt.pickupcopy     = W_CSGalilPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_galil had zero references in
// this tree before this weapon existed — the CrossFire twin spawns as
// weapon_cfgalil — so nothing is displaced and a GoldSrc CS map placing one now
// gets the Galil rather than "no spawn function".
void() weapon_galil =
{
    setmodel(self, CSGALIL_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_galil";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSGALIL;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSGalilEquip;
    self.weap_drop_func = W_CSGalilDrop;
    self.pickupcopy     = W_CSGalilPickupCopy;
    self.touch          = weapon_touch;
    self.mag_galil      = MAX_MAG_CSGALIL;
    self.ammo_galil     = MAX_AMMO_CSGALIL;
    W_RegisterMapWeapon(weapon_galil);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_galil_snd_stage;
float csqc_galil_snd_action;

void() CSQC_PredictCSGalilCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_galil_snd_action)
    {
        csqc_galil_snd_action = predicted_player.wep_action_id;
        csqc_galil_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSGalilTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/galil-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSGALIL_BASE_SPREAD, CSGALIL_MOVE_SPREAD, CSGALIL_FULL_SPREAD_SPEED,
                    CSGALIL_CLOSE_DAMAGE, CSGALIL_MIN_DAMAGE, CSGALIL_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    CSGALIL_KICK_PITCH, CSGALIL_KICK_VARIANCE, CSGALIL_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSGALIL_MUZZLE_FORWARD, CSGALIL_MUZZLE_RIGHT,
                    CSGALIL_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSGALIL_MUZZLE_FORWARD, CSGALIL_MUZZLE_RIGHT,
                    CSGALIL_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted draw / reload sounds — the marks below are the same fractions
    // of the same resolved durations W_CSGalilFrame uses, so the dedup window
    // suppresses the server's CHAN_AUTO echo instead of double-playing it.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_galil_snd_stage < 1
                && elapsed >= SH_CSGalilDrawDuration() * CSGALIL_DRAW_F_BOLT)
            {
                localsound("weapons/galil_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_galil_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSGalilReloadDuration();

            if (csqc_galil_snd_stage < 1 && elapsed >= rel * CSGALIL_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/galil_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_galil_snd_stage = 1;
            }
            if (csqc_galil_snd_stage < 2 && elapsed >= rel * CSGALIL_RELOAD_F_CLIPIN)
            {
                localsound("weapons/galil_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_galil_snd_stage = 2;
            }
            if (csqc_galil_snd_stage < 3 && elapsed >= rel * CSGALIL_RELOAD_F_BOLT)
            {
                // Same sample as the draw — see W_CSGalilFrame.
                localsound("weapons/galil_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_galil_snd_stage = 3;
            }
        }
    }

    SH_CSGalilTickState(csqc_pred_time);
};

void() CSQC_PredictCSGalilReload =
{
    if (SH_CSGalilTryReload(csqc_pred_time))
    {
        csqc_galil_snd_stage  = 0;
        csqc_galil_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSGalilDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSGalilSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSGalilSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSGalilPickShootSeq(predicted_player.wep_action_id);

    return SH_CSGalilSeqIdle();
};

void() CSQC_CSGalilDropClear =
{
    self.mag_galil  = 0;
    self.ammo_galil = 0;
};

void() CSQC_CSGalilEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_csgalil", SCOPE_CLASS_NONE);
    self.weapon_name         = CSGALIL_DISPLAY_NAME;
    self.weapon_viewmodel    = CSGALIL_VIEWMODEL;
    self.weapon_worldmodel   = CSGALIL_WORLDMODEL;
    self.weapon_deploy_sound = CSGALIL_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSGalilCommand;
    self.csqc_predict_reload = CSQC_PredictCSGalilReload;
    self.csqc_display_frame  = CSQC_CSGalilDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSGalilDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game, and sh_wpn_csglock.qc:664 lists
    // this weapon among the ten to flip once reported.
    //
    // LESS CERTAIN THAN THE OTHER EIGHT, same caveat as the FAMAS: v_galil.mdl
    // is built on a Bip01 biped, not the stock rhand/lhand arm shared
    // byte-for-byte by the rest of the CS set, so the "same arm, therefore same
    // flip" argument does not carry.  Set to match the set; one word to revert.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
