// ============================================================
//  shared/weapons/sh_wpn_csmac10.qc  -  Counter-Strike Ingram MAC-10
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 100 reserve, full-auto .45 ACP SMG
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : none - hipfire only, the shared ADS profile with
//          SCOPE_CLASS_NONE (eligible for iron-sight pull-in, no zoom)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_mac10.mdl, models/w_mac10.mdl,
// models/p_mac10.mdl and every .wav below resolve through the mounted cstrike
// gamedir (fs_addons.txt:16), exactly the way sh_wpn_csaug.qc takes
// models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl from
// valve.  The mod's CrossFire MAC-10 (sh_wpn_cfmac10.qc) is a DIFFERENT weapon
// with its own shipped model set under models/weapons/wpn_cfmac10/ and keeps
// the bare "mac10" manifest key; this one answers to "csmac10" and to its own
// GoldSrc classname key "weaponmac10" (sh_weapon_manifest.qc:868).
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_mac10.mdl itself, not guessed:
//
//   [0] idle1    12fps   9 frames  0.667s
//   [1] reload   35fps 111 frames  3.143s
//         f22  5004 "weapons/mac10_clipout.wav"   frac 0.2000
//         f55  5004 "weapons/mac10_clipin.wav"    frac 0.5000
//         f87  5004 "weapons/mac10_boltpull.wav"  frac 0.7909
//   [2] draw     33fps  31 frames  0.909s
//         f22  5004 "items/cliprelease1.wav"      frac 0.7333
//   [3] shoot1   27fps  26 frames  0.926s   f0 5001 (muzzleflash)
//   [4] shoot2   27fps  26 frames  0.926s   f0 5001
//   [5] shoot3   27fps  26 frames  0.926s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.
//
// The idle sequence is labelled "idle1" here, NOT "idle" the way the AUG's is -
// so the by-name lookup below asks for "idle1".  cstrike and czero both ship
// this model and they do NOT agree on its timing: czero's idle1 is 2 frames
// (0.083s) against cstrike's 9 (0.667s), and its reload runs at 34fps for
// 3.235s against cstrike's 35fps for 3.143s.  Both were dumped from the two
// installed copies before this file was written.

// --- Ammo fields ---
.float mag_mac10;
.float ammo_mac10;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted
// (fs_addons.txt:16-17) and both ship models/v_mac10.mdl with the same labels
// at different fps and frame counts - see the idle1/reload divergence measured
// above.  Whichever mount wins, resolving by name and scaling every mark by
// that model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSMAC10_SEQ_IDLE   = 0;
const float CSMAC10_SEQ_RELOAD = 1;
const float CSMAC10_SEQ_DRAW   = 2;
const float CSMAC10_SEQ_SHOOT1 = 3;
const float CSMAC10_SEQ_SHOOT2 = 4;
const float CSMAC10_SEQ_SHOOT3 = 5;

const float CSMAC10_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSMAC10_FIRE_DELAY       = 0.09;        // see the balance note below
const float CSMAC10_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence - see the fps note above.
const float CSMAC10_DRAW_F_RELEASE   = 0.7333;   // frame 22 / 30
const float CSMAC10_RELOAD_F_CLIPOUT = 0.2000;   // frame 22 / 110
const float CSMAC10_RELOAD_F_CLIPIN  = 0.5000;   // frame 55 / 110
const float CSMAC10_RELOAD_F_BOLT    = 0.7909;   // frame 87 / 110
const float CSMAC10_RELOAD_F_APPLY   = 0.7200;   // after the fresh mag seats,
                                                 // just before the bolt is run

const float MAX_MAG_CSMAC10          = 30;
const float MAX_AMMO_CSMAC10         = 100;

// --- Balance ---
//
// Anchored on sh_wpn_cfmac10.qc, which is the same real gun already placed on
// this mod's ladder (14/7 close/min, falloff 1800).  Dropped one point to 13/7
// so the CS pair orders the way CS 1.6 orders it - the MAC-10 is the cheap
// T-side starter SMG that the UMP45 and P90 are bought to replace - while
// staying above the 9mm-class pistols and well below every rifle (the CS AUG is
// 32/21).  Min damage and falloff match the CF twin exactly: .45 ACP out of a
// 5-inch barrel sheds energy fast, and 1800 is already this tree's SMG number.
//
// THE NEXT SIX LINES ARE ONE STATEMENT.  The MAC-10 is the fastest-firing and
// least accurate SMG in CS 1.6, and it is priced (1400,
// sh_weapon_manifest.qc:1250) as the gun you take when you cannot afford
// control.  So it gets the shortest fire delay of the four CS SMGs in this set
// (0.09), the worst standing spread of them (0.014 against the CF twin's
// 0.010), the widest moving spread (0.090), and the heaviest kick - all three
// kick terms sit above the CF twin's 0.8/0.4/1.3.  Trimming any one of these
// toward "reasonable" turns it into a cheaper UMP45 and deletes the reason to
// ever buy the other three.
const float CSMAC10_BASE_SPREAD          = 0.014;
const float CSMAC10_MOVE_SPREAD          = 0.090;
const float CSMAC10_FULL_SPREAD_SPEED    = 320;
const float CSMAC10_CLOSE_DAMAGE         = 13;
const float CSMAC10_MIN_DAMAGE           = 7;
const float CSMAC10_DAMAGE_FALLOFF_RANGE = 1800;
const float CSMAC10_KICK_PITCH    = 0.90;   // sv_gunkick - notoriously
const float CSMAC10_KICK_VARIANCE = 0.50;   // uncontrollable, and the variance
const float CSMAC10_KICK_STRENGTH = 1.35;   // term is what makes it feel it

// Muzzle offset - see cl_debug_muzzle for the live-tune marker.  Seeded from
// the CF twin's bone attachment converted to a camera-relative offset; the CS
// mesh is a different model, so treat these as a starting point rather than
// tuned values.
const float CSMAC10_MUZZLE_FORWARD = 34;
const float CSMAC10_MUZZLE_RIGHT   = 9.5;
const float CSMAC10_MUZZLE_DOWN    = 6.5;

const string CSMAC10_VIEWMODEL    = "models/v_mac10.mdl";
const string CSMAC10_WORLDMODEL   = "models/w_mac10.mdl";
const string CSMAC10_DEPLOY_SOUND = "";
const string CSMAC10_DISPLAY_NAME = "MAC-10";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float mac10_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_CSMac10SeqIdle   = { return SH_SeqForName(CSMAC10_VIEWMODEL, "idle1",  CSMAC10_SEQ_IDLE); };
float() SH_CSMac10SeqReload = { return SH_SeqForName(CSMAC10_VIEWMODEL, "reload", CSMAC10_SEQ_RELOAD); };
float() SH_CSMac10SeqDraw   = { return SH_SeqForName(CSMAC10_VIEWMODEL, "draw",   CSMAC10_SEQ_DRAW); };
float() SH_CSMac10SeqShoot1 = { return SH_SeqForName(CSMAC10_VIEWMODEL, "shoot1", CSMAC10_SEQ_SHOOT1); };
float() SH_CSMac10SeqShoot2 = { return SH_SeqForName(CSMAC10_VIEWMODEL, "shoot2", CSMAC10_SEQ_SHOOT2); };
float() SH_CSMac10SeqShoot3 = { return SH_SeqForName(CSMAC10_VIEWMODEL, "shoot3", CSMAC10_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot - the CFGLOCK pattern.
float(float action_id) SH_CSMac10PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSMac10SeqShoot1();
    if (r < 0.6667) return SH_CSMac10SeqShoot2();
    return SH_CSMac10SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSMac10DrawDuration   = { return SH_SeqDuration(CSMAC10_VIEWMODEL, SH_CSMac10SeqDraw(),   0.909); };
float() SH_CSMac10ReloadDuration = { return SH_SeqDuration(CSMAC10_VIEWMODEL, SH_CSMac10SeqReload(), 3.143); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_CSMac10TickState =
{
    float rel = SH_CSMac10ReloadDuration();
    return SH_StandardTickState(now, mag_mac10, ammo_mac10, MAX_MAG_CSMAC10,
        SH_CSMac10DrawDuration(),
        SH_SeqDuration(CSMAC10_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSMAC10_RELOAD_F_APPLY);
};

// Full-auto: SH_StandardTryFire, not the SemiAuto wrapper.  Holding +attack
// empties the magazine, which is the entire character of this gun.
float(float now) SH_CSMac10TryFire =
{
    return SH_StandardTryFire(now, mag_mac10, CSMAC10_FIRE_DELAY, CSMAC10_DRYFIRE_DELAY);
};

float(float now) SH_CSMac10TryReload =
{
    return SH_StandardTryReload(now, mag_mac10, ammo_mac10, MAX_MAG_CSMAC10,
        SH_CSMac10ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSMac10PickupCopy =
{
    player.mag_mac10  = self.mag_mac10;
    player.ammo_mac10 = self.ammo_mac10;
};

void() W_CSMac10Shoot =
{
    // Penetration 32 / 0.96: half the AUG's 64 and a steeper per-unit decay.
    // A pistol-calibre round punches thin plywood and crate lids and dies in
    // anything structural, which is the CS 1.6 behaviour for the .45 SMGs.
    W_PenetratingHitscanShoot(CSMAC10_BASE_SPREAD, CSMAC10_MOVE_SPREAD, CSMAC10_FULL_SPREAD_SPEED,
        CSMAC10_CLOSE_DAMAGE, CSMAC10_MIN_DAMAGE, CSMAC10_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CSMAC10_KICK_PITCH, CSMAC10_KICK_VARIANCE, CSMAC10_KICK_STRENGTH);
};

void() W_CSMac10Fire =
{
    float r = SH_CSMac10TryFire(time);

    if (r == 1)
    {
        self.weaponframe      = SH_CSMac10PickShootSeq(self.wep_action_id);
        self.wep_nextframe    = time + CSMAC10_FRAME_INTERVAL;
        self.mac10_snd_stage  = 0;

        W_CSMac10Shoot();

        sound(self, CHAN_WEAPON, "weapons/mac10-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSMac10Reload =
{
    if (SH_CSMac10TryReload(time))
    {
        self.weaponframe     = SH_CSMac10SeqReload();
        self.wep_nextframe   = time + CSMAC10_FRAME_INTERVAL;
        self.mac10_snd_stage = 0;
    }
};

void() W_CSMac10Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model - DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSMAC10_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSMac10DrawDuration() * CSMAC10_DRAW_F_RELEASE
            && self.mac10_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "items/cliprelease1.wav", 1, ATTN_NORM);
            self.mac10_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSMac10ReloadDuration();

        if (elapsed >= rel * CSMAC10_RELOAD_F_CLIPOUT && self.mac10_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/mac10_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.mac10_snd_stage = 1;
        }
        if (elapsed >= rel * CSMAC10_RELOAD_F_CLIPIN && self.mac10_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/mac10_clipin.wav", 1, ATTN_NORM);
            self.mac10_snd_stage = 2;
        }
        if (elapsed >= rel * CSMAC10_RELOAD_F_BOLT && self.mac10_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/mac10_boltpull.wav", 1, ATTN_NORM);
            self.mac10_snd_stage = 3;
        }
    }

    result = SH_CSMac10TickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSMac10SeqIdle();
        self.wep_nextframe   = 0;
        self.mac10_snd_stage = 0;
    }
};

void() W_CSMac10Equip =
{
    // No optics of any kind on the real gun and none in CS 1.6, so the ADS
    // profile is eligible-but-unscoped: SCOPE_CLASS_NONE gives the iron-sight
    // pull-in without a zoom stage, exactly as the CF twin does it.
    W_SetADSProfile(TRUE, "cl_ads_csmac10", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSMAC10_VIEWMODEL, CSMAC10_DISPLAY_NAME, SH_CSMac10SeqDraw(),
        CSMAC10_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSMac10Fire;
    self.reload   = W_CSMac10Reload;
    self.wepframe = W_CSMac10Frame;
    self.shoot    = W_CSMac10Shoot;
    self.mac10_snd_stage = 0;
    // 1.5 crosshair scale - tighter on screen than the rifles' 1.85 because the
    // gun is a close-range weapon, even though its cone is the widest here.
    W_SetCrosshairProfile(CSMAC10_BASE_SPREAD, CSMAC10_MOVE_SPREAD, CSMAC10_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_CSMac10Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_mac10  = self.mag_mac10;
    tgt.ammo_mac10 = self.ammo_mac10;

    self.mag_mac10  = 0;
    self.ammo_mac10 = 0;

    setmodel(tgt, CSMAC10_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_mac10";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSMAC10;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSMac10Equip;
    tgt.weap_drop_func = W_CSMac10Drop;
    tgt.pickupcopy     = W_CSMac10PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_mac10 had zero references in
// this tree before this weapon existed - the CrossFire MAC-10 spawns as
// weapon_cfmac10 - so nothing is displaced and a GoldSrc CS map placing one now
// gets this gun rather than "no spawn function".
void() weapon_mac10 =
{
    setmodel(self, CSMAC10_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_mac10";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSMAC10;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSMac10Equip;
    self.weap_drop_func = W_CSMac10Drop;
    self.pickupcopy     = W_CSMac10PickupCopy;
    self.touch          = weapon_touch;
    self.mag_mac10    = MAX_MAG_CSMAC10;
    self.ammo_mac10   = MAX_AMMO_CSMAC10;
    W_RegisterMapWeapon(weapon_mac10);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_mac10_snd_stage;
float csqc_mac10_snd_action;

void() CSQC_PredictCSMac10Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_mac10_snd_action)
    {
        csqc_mac10_snd_action = predicted_player.wep_action_id;
        csqc_mac10_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSMac10TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/mac10-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSMAC10_BASE_SPREAD, CSMAC10_MOVE_SPREAD, CSMAC10_FULL_SPREAD_SPEED,
                    CSMAC10_CLOSE_DAMAGE, CSMAC10_MIN_DAMAGE, CSMAC10_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CSMAC10_KICK_PITCH, CSMAC10_KICK_VARIANCE, CSMAC10_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSMAC10_MUZZLE_FORWARD, CSMAC10_MUZZLE_RIGHT,
                    CSMAC10_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSMAC10_MUZZLE_FORWARD, CSMAC10_MUZZLE_RIGHT,
                    CSMAC10_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_mac10_snd_stage < 1
                && elapsed >= SH_CSMac10DrawDuration() * CSMAC10_DRAW_F_RELEASE)
            {
                localsound("items/cliprelease1.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mac10_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSMac10ReloadDuration();

            if (csqc_mac10_snd_stage < 1 && elapsed >= rel * CSMAC10_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/mac10_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_mac10_snd_stage = 1;
            }
            if (csqc_mac10_snd_stage < 2 && elapsed >= rel * CSMAC10_RELOAD_F_CLIPIN)
            {
                localsound("weapons/mac10_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mac10_snd_stage = 2;
            }
            if (csqc_mac10_snd_stage < 3 && elapsed >= rel * CSMAC10_RELOAD_F_BOLT)
            {
                localsound("weapons/mac10_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_mac10_snd_stage = 3;
            }
        }
    }

    SH_CSMac10TickState(csqc_pred_time);
};

void() CSQC_PredictCSMac10Reload =
{
    if (SH_CSMac10TryReload(csqc_pred_time))
    {
        csqc_mac10_snd_stage  = 0;
        csqc_mac10_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSMac10DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSMac10SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSMac10SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSMac10PickShootSeq(predicted_player.wep_action_id);

    return SH_CSMac10SeqIdle();
};

void() CSQC_CSMac10DropClear =
{
    self.mag_mac10  = 0;
    self.ammo_mac10 = 0;
};

void() CSQC_CSMac10Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csmac10", SCOPE_CLASS_NONE);
    self.weapon_name         = CSMAC10_DISPLAY_NAME;
    self.weapon_viewmodel    = CSMAC10_VIEWMODEL;
    self.weapon_worldmodel   = CSMAC10_WORLDMODEL;
    self.weapon_deploy_sound = CSMAC10_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSMac10Command;
    self.csqc_predict_reload = CSQC_PredictCSMac10Reload;
    self.csqc_display_frame  = CSQC_CSMac10DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSMac10DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game.  sh_wpn_csglock.qc:664 already
    // listed this weapon as one of the ten drawing the same stock cstrike arm
    // and needing the same flip once it was reported.  The rhand/lhand meshes
    // here are byte-identical to the flipped handguns'.  cl_lefthand still XORs.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
