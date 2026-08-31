// ============================================================
//  shared/weapons/sh_wpn_csp90.qc  -  Counter-Strike FN P90
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round magazine, 100 reserve, full-auto 5.7x28mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : none — plain ADS on +attack2, via the shared ADS profile
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_p90.mdl, models/w_p90.mdl,
// models/p_p90.mdl (named by the manifest row) and every "weapons/p90*.wav"
// below resolve through the mounted cstrike gamedir (fs_addons.txt:16), the
// same way sh_wpn_csaug.qc takes models/v_aug.mdl and sh_wpn_csglock.qc takes
// models/v_glock18.mdl.  Only the dry click is one of the mod's own files.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_p90.mdl itself, not guessed:
//
//   [0] idle     30fps   9 frames  0.267s
//   [1] reload   40fps 136 frames  3.375s
//         f17  5004 "weapons/p90_cliprelease.wav"  frac 0.1259
//         f35  5004 "weapons/p90_clipout.wav"      frac 0.2593
//         f75  5004 "weapons/p90_clipin.wav"       frac 0.5556
//         f108 5004 "weapons/p90_boltpull.wav"     frac 0.8000
//   [2] draw     30fps  31 frames  1.000s
//         f9   5004 "weapons/p90_boltpull.wav"     frac 0.3000
//   [3] shoot1   30fps  13 frames  0.400s   f0 5001 (muzzleflash)
//   [4] shoot2   30fps  15 frames  0.467s   f0 5001
//   [5] shoot3   30fps  15 frames  0.467s   f0 5001
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  Note that /c/tmp/seqlist.py CANNOT show you this: it walks the event
// array with a stride of 72 where mstudioevent_t is 76 bytes (int frame, int
// event, int type, char options[64]), so every event past the first is read
// from the middle of its predecessor and options is never read at all.  Use the
// corrected dumper if these need re-deriving.
//
// THE P90 HAS A FOUR-STAGE RELOAD where most of this set has three, and the
// first mark is NOT the magazine leaving the gun: p90_cliprelease is the
// magazine CATCH being thumbed, and it sits a full 0.13 of the sequence BEFORE
// p90_clipout.  The stage latch below must stay in frame order (cliprelease ->
// clipout -> clipin -> boltpull) or the catch clicks after the mag has already
// fallen out.  The mag-drop effect hangs off clipout, not off cliprelease.

// --- Ammo fields ---
.float mag_p90;
.float ammo_p90;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted (fs_addons.txt:16-17)
// and both ship models/v_p90.mdl with the same labels at different fps and frame
// counts.  Whichever mount wins, resolving by name and scaling every mark by
// that model's own duration keeps the sounds on the animation.
//
// The divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
const float CSP90_SEQ_IDLE   = 0;
const float CSP90_SEQ_RELOAD = 1;
const float CSP90_SEQ_DRAW   = 2;
const float CSP90_SEQ_SHOOT1 = 3;
const float CSP90_SEQ_SHOOT2 = 4;
const float CSP90_SEQ_SHOOT3 = 5;

const float CSP90_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSP90_FIRE_DELAY       = 0.087;       // CS 1.6 P90 is ~690 rpm
const float CSP90_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSP90_DRAW_F_BOLT      = 0.3000;   // frame   9 / 30
const float CSP90_RELOAD_F_RELEASE = 0.1259;   // frame  17 / 135  (mag catch)
const float CSP90_RELOAD_F_CLIPOUT = 0.2593;   // frame  35 / 135
const float CSP90_RELOAD_F_CLIPIN  = 0.5556;   // frame  75 / 135
const float CSP90_RELOAD_F_BOLT    = 0.8000;   // frame 108 / 135
const float CSP90_RELOAD_F_APPLY   = 0.7200;   // between clipin and the boltpull

const float MAX_MAG_CSP90          = 50;
const float MAX_AMMO_CSP90         = 100;

// --- Balance ---
//
// Anchored on sh_wpn_cfvector.qc, the other very-high-rate SMG on the ladder
// (22/11 close/min at 1800 falloff), and read against the SMGs either side of
// it: the CF MAC-10 at 14/7 / 1800, the CF MP5 at 20/10 / 1900 and the CS MP5
// at 12/6 / 2048.
//
// The P90 is deliberately the WEAKEST per-bullet gun of the four new SMGs at
// 10/5 — one point under the CS MP5's 12/6, which is the current floor — and it
// is the only one that earns that back on magazine size rather than on damage.
// A 50-round mag is the largest of any SMG in the game and roughly twice what
// the ladder's other SMGs carry, so the gun's damage-per-magazine (500 close)
// lands well above the CF MP5's 600-at-30 pace only in sustained fire, never in
// a first-burst trade.  At 0.087s between shots it is slower than the Vector's
// 0.05 but faster than either MP5's 0.075/0.1, so time-to-kill sits mid-pack.
//
// FALLOFF 2400 is the outlier and it is intentional: this fires 5.7x28mm, the
// same cartridge as the Five-seven, and the pair shares that round's signature —
// a small, fast, flat-shooting bullet that keeps its (small) damage far past
// where the .45 guns have given up.  2400 puts it a third beyond the MAC-10 and
// the Vector at 1800, and past every rifle-calibre falloff on the ladder except
// the marksman rifles.  That reach is what the P90 is bought for, and at 2350 it
// is the most expensive SMG in the game (sh_weapon_manifest.qc:1252).
const float CSP90_BASE_SPREAD          = 0.010;
const float CSP90_MOVE_SPREAD          = 0.065;
const float CSP90_FULL_SPREAD_SPEED    = 320;
const float CSP90_CLOSE_DAMAGE         = 10;
const float CSP90_MIN_DAMAGE           = 5;
const float CSP90_DAMAGE_FALLOFF_RANGE = 2400;
const float CSP90_KICK_PITCH    = 0.60;   // sv_gunkick — tiny round, very flat.
const float CSP90_KICK_VARIANCE = 0.30;
const float CSP90_KICK_STRENGTH = 1.10;   // builds over a long burst, per-shot low.

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  The P90 is a
// bullpup with the muzzle well back relative to the AUG's 44, so these are
// pulled in; treat them as a starting point rather than tuned values.
const float CSP90_MUZZLE_FORWARD = 36;
const float CSP90_MUZZLE_RIGHT   = 9.0;
const float CSP90_MUZZLE_DOWN    = 5.5;

const string CSP90_VIEWMODEL    = "models/v_p90.mdl";
const string CSP90_WORLDMODEL   = "models/w_p90.mdl";
const string CSP90_DEPLOY_SOUND = "";
const string CSP90_DISPLAY_NAME = "P90";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float p90_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSP90SeqIdle   = { return SH_SeqForName(CSP90_VIEWMODEL, "idle",   CSP90_SEQ_IDLE); };
float() SH_CSP90SeqReload = { return SH_SeqForName(CSP90_VIEWMODEL, "reload", CSP90_SEQ_RELOAD); };
float() SH_CSP90SeqDraw   = { return SH_SeqForName(CSP90_VIEWMODEL, "draw",   CSP90_SEQ_DRAW); };
float() SH_CSP90SeqShoot1 = { return SH_SeqForName(CSP90_VIEWMODEL, "shoot1", CSP90_SEQ_SHOOT1); };
float() SH_CSP90SeqShoot2 = { return SH_SeqForName(CSP90_VIEWMODEL, "shoot2", CSP90_SEQ_SHOOT2); };
float() SH_CSP90SeqShoot3 = { return SH_SeqForName(CSP90_VIEWMODEL, "shoot3", CSP90_SEQ_SHOOT3); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which take plays for this shot — the CFGLOCK pattern.
float(float action_id) SH_CSP90PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_CSP90SeqShoot1();
    if (r < 0.6667) return SH_CSP90SeqShoot2();
    return SH_CSP90SeqShoot3();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSP90DrawDuration   = { return SH_SeqDuration(CSP90_VIEWMODEL, SH_CSP90SeqDraw(),   1.000); };
float() SH_CSP90ReloadDuration = { return SH_SeqDuration(CSP90_VIEWMODEL, SH_CSP90SeqReload(), 3.375); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSP90TickState =
{
    float rel = SH_CSP90ReloadDuration();
    return SH_StandardTickState(now, mag_p90, ammo_p90, MAX_MAG_CSP90,
        SH_CSP90DrawDuration(),
        SH_SeqDuration(CSP90_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * CSP90_RELOAD_F_APPLY);
};

// FULL-AUTO: SH_StandardTryFire, not the SemiAuto variant.  Holding +attack
// keeps the gun cycling at CSP90_FIRE_DELAY.
float(float now) SH_CSP90TryFire =
{
    return SH_StandardTryFire(now, mag_p90, CSP90_FIRE_DELAY, CSP90_DRYFIRE_DELAY);
};

float(float now) SH_CSP90TryReload =
{
    return SH_StandardTryReload(now, mag_p90, ammo_p90, MAX_MAG_CSP90,
        SH_CSP90ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSP90PickupCopy =
{
    player.mag_p90  = self.mag_p90;
    player.ammo_p90 = self.ammo_p90;
};

void() W_CSP90Shoot =
{
    // 32 units of penetration at 0.96 retained per surface: 5.7x28mm was
    // designed to defeat soft armour, so it keeps almost all of its (small)
    // damage through a wall — the same trade the CF Vector takes at 32/0.95.
    W_PenetratingHitscanShoot(CSP90_BASE_SPREAD, CSP90_MOVE_SPREAD, CSP90_FULL_SPREAD_SPEED,
        CSP90_CLOSE_DAMAGE, CSP90_MIN_DAMAGE, CSP90_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        CSP90_KICK_PITCH, CSP90_KICK_VARIANCE, CSP90_KICK_STRENGTH);
};

void() W_CSP90Fire =
{
    float r = SH_CSP90TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CSP90PickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + CSP90_FRAME_INTERVAL;
        self.p90_snd_stage = 0;

        W_CSP90Shoot();

        sound(self, CHAN_WEAPON, "weapons/p90-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSP90Reload =
{
    if (SH_CSP90TryReload(time))
    {
        self.weaponframe   = SH_CSP90SeqReload();
        self.wep_nextframe = time + CSP90_FRAME_INTERVAL;
        self.p90_snd_stage = 0;
    }
};

void() W_CSP90Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSP90_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_CSP90DrawDuration() * CSP90_DRAW_F_BOLT
            && self.p90_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/p90_boltpull.wav", 1, ATTN_NORM);
            self.p90_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        // Four stages, kept in FRAME ORDER — the catch releases before the mag
        // comes out.  See the header note.
        float rel = SH_CSP90ReloadDuration();

        if (elapsed >= rel * CSP90_RELOAD_F_RELEASE && self.p90_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/p90_cliprelease.wav", 1, ATTN_NORM);
            self.p90_snd_stage = 1;
        }
        if (elapsed >= rel * CSP90_RELOAD_F_CLIPOUT && self.p90_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/p90_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.p90_snd_stage = 2;
        }
        if (elapsed >= rel * CSP90_RELOAD_F_CLIPIN && self.p90_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/p90_clipin.wav", 1, ATTN_NORM);
            self.p90_snd_stage = 3;
        }
        if (elapsed >= rel * CSP90_RELOAD_F_BOLT && self.p90_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "weapons/p90_boltpull.wav", 1, ATTN_NORM);
            self.p90_snd_stage = 4;
        }
    }

    result = SH_CSP90TickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_CSP90SeqIdle();
        self.wep_nextframe = 0;
        self.p90_snd_stage = 0;
    }
};

void() W_CSP90Equip =
{
    // No scope class: the P90's CS 1.6 altfire is a burst/zoom on some builds
    // but the stock gun has none, so it gets plain ADS eligibility and
    // SCOPE_CLASS_NONE, the way the CF SMGs do.
    W_SetADSProfile(TRUE, "cl_ads_csp90", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CSP90_VIEWMODEL, CSP90_DISPLAY_NAME, SH_CSP90SeqDraw(),
        CSP90_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSP90Fire;
    self.reload   = W_CSP90Reload;
    self.wepframe = W_CSP90Frame;
    self.shoot    = W_CSP90Shoot;
    self.p90_snd_stage = 0;
    // 1.45 gap scale — tighter than the AUG's 1.85 rifle spread but wider than
    // a pistol's, matching the low base / moderate move spread above.
    W_SetCrosshairProfile(CSP90_BASE_SPREAD, CSP90_MOVE_SPREAD, CSP90_FULL_SPREAD_SPEED, 1.45, TRUE);
};

void() W_CSP90Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_p90  = self.mag_p90;
    tgt.ammo_p90 = self.ammo_p90;

    self.mag_p90  = 0;
    self.ammo_p90 = 0;

    setmodel(tgt, CSP90_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_p90";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSP90;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSP90Equip;
    tgt.weap_drop_func = W_CSP90Drop;
    tgt.pickupcopy     = W_CSP90PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_p90 had zero references in
// this tree before this weapon existed, so nothing is displaced and a GoldSrc
// CS map placing one now gets the P90 rather than "no spawn function".
void() weapon_p90 =
{
    setmodel(self, CSP90_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_p90";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSP90;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSP90Equip;
    self.weap_drop_func = W_CSP90Drop;
    self.pickupcopy     = W_CSP90PickupCopy;
    self.touch          = weapon_touch;
    self.mag_p90        = MAX_MAG_CSP90;
    self.ammo_p90       = MAX_AMMO_CSP90;
    W_RegisterMapWeapon(weapon_p90);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_p90_snd_stage;
float csqc_p90_snd_action;

void() CSQC_PredictCSP90Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_p90_snd_action)
    {
        csqc_p90_snd_action = predicted_player.wep_action_id;
        csqc_p90_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CSP90TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/p90-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CSP90_BASE_SPREAD, CSP90_MOVE_SPREAD, CSP90_FULL_SPREAD_SPEED,
                    CSP90_CLOSE_DAMAGE, CSP90_MIN_DAMAGE, CSP90_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    CSP90_KICK_PITCH, CSP90_KICK_VARIANCE, CSP90_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSP90_MUZZLE_FORWARD, CSP90_MUZZLE_RIGHT,
                    CSP90_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSP90_MUZZLE_FORWARD, CSP90_MUZZLE_RIGHT,
                    CSP90_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_p90_snd_stage < 1
                && elapsed >= SH_CSP90DrawDuration() * CSP90_DRAW_F_BOLT)
            {
                localsound("weapons/p90_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p90_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            // Mirrors W_CSP90Frame stage for stage — same marks, same order,
            // same four sounds — or the reload rubber-bands audibly.
            float rel = SH_CSP90ReloadDuration();

            if (csqc_p90_snd_stage < 1 && elapsed >= rel * CSP90_RELOAD_F_RELEASE)
            {
                localsound("weapons/p90_cliprelease.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p90_snd_stage = 1;
            }
            if (csqc_p90_snd_stage < 2 && elapsed >= rel * CSP90_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/p90_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_p90_snd_stage = 2;
            }
            if (csqc_p90_snd_stage < 3 && elapsed >= rel * CSP90_RELOAD_F_CLIPIN)
            {
                localsound("weapons/p90_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p90_snd_stage = 3;
            }
            if (csqc_p90_snd_stage < 4 && elapsed >= rel * CSP90_RELOAD_F_BOLT)
            {
                localsound("weapons/p90_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_p90_snd_stage = 4;
            }
        }
    }

    SH_CSP90TickState(csqc_pred_time);
};

void() CSQC_PredictCSP90Reload =
{
    if (SH_CSP90TryReload(csqc_pred_time))
    {
        csqc_p90_snd_stage  = 0;
        csqc_p90_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_CSP90DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSP90SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSP90SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSP90PickShootSeq(predicted_player.wep_action_id);

    return SH_CSP90SeqIdle();
};

void() CSQC_CSP90DropClear =
{
    self.mag_p90  = 0;
    self.ammo_p90 = 0;
};

void() CSQC_CSP90Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csp90", SCOPE_CLASS_NONE);
    self.weapon_name         = CSP90_DISPLAY_NAME;
    self.weapon_viewmodel    = CSP90_VIEWMODEL;
    self.weapon_worldmodel   = CSP90_WORLDMODEL;
    self.weapon_deploy_sound = CSP90_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSP90Command;
    self.csqc_predict_reload = CSQC_PredictCSP90Reload;
    self.csqc_display_frame  = CSQC_CSP90DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSP90DropClear;
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
