// ============================================================
//  shared/weapons/sh_wpn_csm4a1.qc  -  CS M4A1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : silencer toggle (WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo & state fields ---
.float mag_m4a1;
.float ammo_m4a1;
.float m4a1_silenced;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_m4a1.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName; see sh_wpn_csaug.qc.
//
// ONE MODEL, TWO SETS.  The old bake needed two separate files (v_m4a1.mdl and
// v_m4a1_unsil.mdl) because a Quake-format model has no sequence table to hold
// both.  The stock cstrike model carries the silenced set at 0-6 and the whole
// unsilenced set again at 7-13, so the weapon now swaps SEQUENCE rather than
// MODEL and SH_M4A1ViewModel collapses to a single path.
//
//   [0] idle             16fps   9f  0.500s
//   [1..3] shoot1..3     20fps  31f  1.500s   f0 5001 (muzzleflash)
//   [4] reload           37fps 114f  3.054s   clipout/clipin/boltpull
//   [5] draw             40fps  41f  1.000s   f1 "m4a1_deploy" f17 "m4a1_boltpull"
//   [6] add_silencer     30fps  61f  2.000s   f28 "m4a1_silencer_on"
//   [7] idle_unsil       16fps   9f  0.500s
//   [8..10] shoot*_unsil 20fps  31f  1.500s   f0 5021 (loud muzzleflash)
//   [11] reload_unsil    37fps 114f  3.054s   (same three)
//   [12] draw_unsil      40fps  41f  1.000s   (same two)
//   [13] detach_silencer 30fps  61f  2.000s   f21 "m4a1_silencer_off"
const float M4A1_SEQ_IDLE          = 0;
const float M4A1_SEQ_SHOOT1        = 1;
const float M4A1_SEQ_SHOOT2        = 2;
const float M4A1_SEQ_SHOOT3        = 3;
const float M4A1_SEQ_RELOAD        = 4;
const float M4A1_SEQ_DRAW          = 5;
const float M4A1_SEQ_ADDSIL        = 6;
const float M4A1_SEQ_IDLE_UNSIL    = 7;
const float M4A1_SEQ_SHOOT1_UNSIL  = 8;
const float M4A1_SEQ_SHOOT2_UNSIL  = 9;
const float M4A1_SEQ_SHOOT3_UNSIL  = 10;
const float M4A1_SEQ_RELOAD_UNSIL  = 11;
const float M4A1_SEQ_DRAW_UNSIL    = 12;
const float M4A1_SEQ_DETACHSIL     = 13;

const float M4A1_FRAME_INTERVAL       = 0.0333334;   // state-machine tick rate
const float M4A1_FIRE_DELAY           = 0.1;

// Event marks as a FRACTION of their sequence.
const float M4A1_DRAW_F_DEPLOY        = 0.0250;   // frame   1 / 40
const float M4A1_DRAW_F_BOLT          = 0.4250;   // frame  17 / 40
const float M4A1_RELOAD_F_CLIPOUT     = 0.2212;   // frame  25 / 113
const float M4A1_RELOAD_F_CLIPIN      = 0.4690;   // frame  53 / 113
const float M4A1_RELOAD_F_BOLT        = 0.7788;   // frame  88 / 113
const float M4A1_RELOAD_F_APPLY       = 0.5000;   // just after the fresh mag seats
const float M4A1_SILENCER_F_SWAP      = 0.4667;   // frame  28 / 60 (add); the detach
                                                  // take's own event is at 0.35, but
                                                  // one mark keeps both sides in step
                                                  // and the takes are the same length

const float MAX_MAG_M4A1              = 30;
const float MAX_AMMO_M4A1             = 90;

// --- Balance ---
const float M4A1_BASE_SPREAD            = 0.01;
const float M4A1_MOVE_SPREAD            = 0.06;
const float M4A1_FULL_SPREAD_SPEED      = 320;
const float M4A1_CLOSE_DAMAGE           = 24;
const float M4A1_MIN_DAMAGE             = 14;
const float M4A1_SILENCED_CLOSE_DAMAGE  = 22;
const float M4A1_SILENCED_MIN_DAMAGE    = 12;
const float M4A1_DAMAGE_FALLOFF_RANGE   = 3072;
const float M4A1_DRYFIRE_DELAY          = 0.2;

// sv_gunkick — slightly tamer than the AK; M4 trades raw kick for
// a tighter base spread.
const float M4A1_KICK_PITCH    = 1.4;
const float M4A1_KICK_VARIANCE = 0.4;
const float M4A1_KICK_STRENGTH = 1.0;   // baseline auto rifle.

// Muzzle offset (cl_muzzleflash.qc CSQC_MuzzleFlashAtMuzzle +
// cl_muzzlesmoke.qc CSQC_MuzzleSmokeAtMuzzle). Live-tune via
// cl_debug_muzzle 1 to see the marker.
const float M4A1_MUZZLE_FORWARD = 42;
const float M4A1_MUZZLE_RIGHT   = 10;
const float M4A1_MUZZLE_DOWN    = 6.6;
// Silenced offset — suppressor extends the muzzle further forward.
// When m4a1_silenced is on, the flash is suppressed entirely; only
// smoke seeps out, and from this offset rather than the bare-barrel
// one above. Same convention as USP.
const float M4A1_SILENCED_MUZZLE_FORWARD = 54;
const float M4A1_SILENCED_MUZZLE_RIGHT   = 10;
const float M4A1_SILENCED_MUZZLE_DOWN    = 6.5;

// v_/w_/p_ all resolve through the mounted cstrike gamedir.  The two-file
// silencer split is gone — one model, two sequence sets (see the table above).
const string M4A1_VIEWMODEL       = "models/v_m4a1.mdl";
const string M4A1_WORLDMODEL      = "models/w_m4a1.mdl";
const string M4A1_DEPLOY_SOUND    = "sounds/weapons/wpn_csm4a1/deploy.wav";
const string M4A1_DISPLAY_NAME    = "M4A1";

// Sound stage latch — a sequence-driven model never steps weaponframe.
.float m4a1_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

// One model now, so this is a constant — kept as a function because the equip
// paths and W_M4A1Frame both call it and the shape reads the same as before.
string() SH_M4A1ViewModel = { return M4A1_VIEWMODEL; };

// The silenced/unsilenced pair for every state.  `sil` is passed rather than read
// off self, because the display frame runs with `self` set to the viewmodel.
float(float sil) SH_M4A1SeqIdle =
{
    if (sil) return SH_SeqForName(M4A1_VIEWMODEL, "idle",       M4A1_SEQ_IDLE);
    return           SH_SeqForName(M4A1_VIEWMODEL, "idle_unsil", M4A1_SEQ_IDLE_UNSIL);
};
float(float sil) SH_M4A1SeqReload =
{
    if (sil) return SH_SeqForName(M4A1_VIEWMODEL, "reload",       M4A1_SEQ_RELOAD);
    return           SH_SeqForName(M4A1_VIEWMODEL, "reload_unsil", M4A1_SEQ_RELOAD_UNSIL);
};
float(float sil) SH_M4A1SeqDraw =
{
    if (sil) return SH_SeqForName(M4A1_VIEWMODEL, "draw",       M4A1_SEQ_DRAW);
    return           SH_SeqForName(M4A1_VIEWMODEL, "draw_unsil", M4A1_SEQ_DRAW_UNSIL);
};

// The toggle take.  Attaching plays add_silencer, detaching plays
// detach_silencer — so the one that plays is decided by the CURRENT state, which
// is the state we are leaving.
float(float sil) SH_M4A1SeqToggle =
{
    if (sil) return SH_SeqForName(M4A1_VIEWMODEL, "detach_silencer", M4A1_SEQ_DETACHSIL);
    return           SH_SeqForName(M4A1_VIEWMODEL, "add_silencer",    M4A1_SEQ_ADDSIL);
};

float(float sil, float action_id) SH_M4A1PickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    if (sil)
    {
        if (r < 0.3334) return SH_SeqForName(M4A1_VIEWMODEL, "shoot1", M4A1_SEQ_SHOOT1);
        if (r < 0.6667) return SH_SeqForName(M4A1_VIEWMODEL, "shoot2", M4A1_SEQ_SHOOT2);
        return               SH_SeqForName(M4A1_VIEWMODEL, "shoot3", M4A1_SEQ_SHOOT3);
    }
    if (r < 0.3334) return SH_SeqForName(M4A1_VIEWMODEL, "shoot1_unsil", M4A1_SEQ_SHOOT1_UNSIL);
    if (r < 0.6667) return SH_SeqForName(M4A1_VIEWMODEL, "shoot2_unsil", M4A1_SEQ_SHOOT2_UNSIL);
    return               SH_SeqForName(M4A1_VIEWMODEL, "shoot3_unsil", M4A1_SEQ_SHOOT3_UNSIL);
};

float(float sil) SH_M4A1DrawDuration     = { return SH_SeqDuration(M4A1_VIEWMODEL, SH_M4A1SeqDraw(sil),   1.000); };
float(float sil) SH_M4A1ReloadDuration   = { return SH_SeqDuration(M4A1_VIEWMODEL, SH_M4A1SeqReload(sil), 3.054); };
float(float sil) SH_M4A1SilencerDuration = { return SH_SeqDuration(M4A1_VIEWMODEL, SH_M4A1SeqToggle(sil), 2.000); };

// Gameplay cooldown for the toggle — the animation's own length, so the two can
// never drift apart the way a hand-written constant did.
float() SH_M4A1SilencerDelay = { return SH_M4A1SilencerDuration(self.m4a1_silenced); };

// ============================================================
//  SHARED — state machine
// ============================================================

// Returns bitmask: bit 0 = idle, bit 1 = reload ammo applied
float(float now) SH_M4A1TickState =
{
    float elapsed, result;
    float sil = self.m4a1_silenced;

    // WS_SPECIAL (silencer toggle) — handle locally
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= SH_M4A1SilencerDuration(sil))
        {
            self.m4a1_silenced = !self.m4a1_silenced;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_M4A1ReloadDuration(sil);
    return SH_StandardTickState(now, mag_m4a1, ammo_m4a1, MAX_MAG_M4A1,
        SH_M4A1DrawDuration(sil),
        SH_SeqDuration(M4A1_VIEWMODEL, self.weaponframe, 1.500),
        rel, rel * M4A1_RELOAD_F_APPLY);
};

float(float now) SH_M4A1TryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_m4a1, M4A1_FIRE_DELAY, M4A1_DRYFIRE_DELAY);
};

float(float now) SH_M4A1TryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_m4a1, ammo_m4a1, MAX_MAG_M4A1,
        SH_M4A1ReloadDuration(self.m4a1_silenced));
};

float(float now) SH_M4A1TryAltFire =
{
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + SH_M4A1SilencerDelay();
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M4A1PickupCopy =
{
    player.mag_m4a1      = self.mag_m4a1;
    player.ammo_m4a1     = self.ammo_m4a1;
    player.m4a1_silenced = self.m4a1_silenced;
};

void() W_M4A1Shoot =
{
    float close_dmg, min_dmg;

    if (self.m4a1_silenced)
    {
        close_dmg = M4A1_SILENCED_CLOSE_DAMAGE;
        min_dmg   = M4A1_SILENCED_MIN_DAMAGE;
    }
    else
    {
        close_dmg = M4A1_CLOSE_DAMAGE;
        min_dmg   = M4A1_MIN_DAMAGE;
    }

    W_PenetratingHitscanShoot(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED,
        close_dmg, min_dmg, M4A1_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        M4A1_KICK_PITCH, M4A1_KICK_VARIANCE, M4A1_KICK_STRENGTH);
};

void() W_M4A1Fire =
{
    float r = SH_M4A1TryFire(time);

    if (r == 1)
    {
        self.weaponframe    = SH_M4A1PickShootSeq(self.m4a1_silenced, self.wep_action_id);
        self.wep_nextframe  = time + M4A1_FRAME_INTERVAL;
        self.m4a1_snd_stage = 0;

        W_M4A1Shoot();

        if (self.m4a1_silenced)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/sfire1.wav", 1, ATTN_NORM);
        }
        else
        {
            if (random() < 0.5)
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/fire1.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/fire2.wav", 1, ATTN_NORM);
        }

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_M4A1Reload =
{
    if (SH_M4A1TryReload(time))
    {
        self.weaponframe    = SH_M4A1SeqReload(self.m4a1_silenced);
        self.wep_nextframe  = time + M4A1_FRAME_INTERVAL;
        self.m4a1_snd_stage = 0;
    }
};

void() W_M4A1AltFire =
{
    if (SH_M4A1TryAltFire(time))
    {
        self.weaponframe    = SH_M4A1SeqToggle(self.m4a1_silenced);
        self.wep_nextframe  = time + M4A1_FRAME_INTERVAL;
        self.m4a1_snd_stage = 0;
    }
};

void() W_M4A1Frame =
{
    float result;
    float sil = self.m4a1_silenced;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += M4A1_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        float drw = SH_M4A1DrawDuration(sil);

        if (elapsed >= drw * M4A1_DRAW_F_DEPLOY && self.m4a1_snd_stage < 1)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm4a1/deploy.wav", 1, ATTN_NORM);
            self.m4a1_snd_stage = 1;
        }
        if (elapsed >= drw * M4A1_DRAW_F_BOLT && self.m4a1_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/boltpull.wav", 1, ATTN_NORM);
            self.m4a1_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_M4A1ReloadDuration(sil);

        if (elapsed >= rel * M4A1_RELOAD_F_CLIPOUT && self.m4a1_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.m4a1_snd_stage = 1;
        }
        if (elapsed >= rel * M4A1_RELOAD_F_CLIPIN && self.m4a1_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/clipin.wav", 1, ATTN_NORM);
            self.m4a1_snd_stage = 2;
        }
        if (elapsed >= rel * M4A1_RELOAD_F_BOLT && self.m4a1_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/boltpull.wav", 1, ATTN_NORM);
            self.m4a1_snd_stage = 3;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_M4A1SilencerDuration(sil) * M4A1_SILENCER_F_SWAP
            && self.m4a1_snd_stage < 1)
        {
            if (sil)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/silenceroff.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm4a1/silenceron.wav", 1, ATTN_NORM);
            self.m4a1_snd_stage = 1;
        }
    }

    result = SH_M4A1TickState(time);

    if (result & 1)
    {
        // m4a1_silenced may have just flipped inside the tick, so read it again
        // rather than reusing `sil` from the top of the frame.
        self.weaponframe    = SH_M4A1SeqIdle(self.m4a1_silenced);
        self.wep_nextframe  = 0;
        self.m4a1_snd_stage = 0;
    }
};

void() W_M4A1Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m4a1", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(M4A1_VIEWMODEL, M4A1_DISPLAY_NAME, SH_M4A1SeqDraw(self.m4a1_silenced),
        M4A1_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.m4a1_snd_stage = 0;
    self.fire     = W_M4A1Fire;
    self.reload   = W_M4A1Reload;
    self.wepframe = W_M4A1Frame;
    self.special  = W_M4A1AltFire;   // silencer toggle on weapon-special (impulse 7)
    self.shoot    = W_M4A1Shoot;
    W_SetCrosshairProfile(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED, 1.9, TRUE);
};

void() W_M4A1Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_m4a1      = self.mag_m4a1;
    tgt.ammo_m4a1     = self.ammo_m4a1;
    tgt.m4a1_silenced = self.m4a1_silenced;

    self.mag_m4a1      = 0;
    self.ammo_m4a1     = 0;
    self.m4a1_silenced = 0;

    setmodel(tgt, "models/w_m4a1.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_m4a1";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_M4A1;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_M4A1Equip;
    tgt.weap_drop_func = W_M4A1Drop;
    tgt.pickupcopy   = W_M4A1PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_m4a1 =
{
    setmodel(self, "models/w_m4a1.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_m4a1";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_M4A1;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_M4A1Equip;
    self.weap_drop_func = W_M4A1Drop;
    self.pickupcopy    = W_M4A1PickupCopy;
    self.touch         = weapon_touch;
    self.mag_m4a1      = MAX_MAG_M4A1;
    self.ammo_m4a1     = MAX_AMMO_M4A1;
    self.m4a1_silenced = TRUE;
    W_RegisterMapWeapon(weapon_m4a1);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_m4a1_snd_stage;
float csqc_m4a1_snd_action;

void() CSQC_PredictM4A1Command =
{
    float r;

    if (predicted_player.wep_action_id != csqc_m4a1_snd_action)
    {
        csqc_m4a1_snd_action = predicted_player.wep_action_id;
        csqc_m4a1_snd_stage  = 0;
    }

    // Try fire
    if (input_buttons & 1)
    {
        r = SH_M4A1TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (self.m4a1_silenced)
                    localsound("sounds/weapons/wpn_csm4a1/sfire1.wav");
                else
                {
                    if (random() < 0.5)
                        localsound("sounds/weapons/wpn_csm4a1/fire1.wav");
                    else
                        localsound("sounds/weapons/wpn_csm4a1/fire2.wav");
                }
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(M4A1_BASE_SPREAD, M4A1_MOVE_SPREAD, M4A1_FULL_SPREAD_SPEED,
                    self.m4a1_silenced ? M4A1_SILENCED_CLOSE_DAMAGE : M4A1_CLOSE_DAMAGE,
                    self.m4a1_silenced ? M4A1_SILENCED_MIN_DAMAGE   : M4A1_MIN_DAMAGE,
                    M4A1_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    M4A1_KICK_PITCH, M4A1_KICK_VARIANCE, M4A1_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Silenced suppresses the flash and uses an extended
                // muzzle offset for the smoke (suppressor moves the
                // visible barrel forward). Same convention as USP.
                if (self.m4a1_silenced)
                {
                    CSQC_MuzzleSmokeAtMuzzle(
                        M4A1_SILENCED_MUZZLE_FORWARD,
                        M4A1_SILENCED_MUZZLE_RIGHT,
                        M4A1_SILENCED_MUZZLE_DOWN, self.wep_action_id, 1);
                }
                else
                {
                    CSQC_MuzzleFlashAtMuzzle(M4A1_MUZZLE_FORWARD, M4A1_MUZZLE_RIGHT,
                        M4A1_MUZZLE_DOWN, self.wep_action_id);
                    CSQC_MuzzleSmokeAtMuzzle(M4A1_MUZZLE_FORWARD, M4A1_MUZZLE_RIGHT,
                        M4A1_MUZZLE_DOWN, self.wep_action_id, 1);
                }
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


    // Predicted draw / reload / silencer-toggle sounds, timed off the loaded
    // model's own sequence durations rather than a stepped frame number.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float sil     = self.m4a1_silenced;
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            float drw = SH_M4A1DrawDuration(sil);

            if (csqc_m4a1_snd_stage < 1 && elapsed >= drw * M4A1_DRAW_F_DEPLOY)
            { localsound("sounds/weapons/wpn_csm4a1/deploy.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_snd_stage = 1; }
            if (csqc_m4a1_snd_stage < 2 && elapsed >= drw * M4A1_DRAW_F_BOLT)
            { localsound("sounds/weapons/wpn_csm4a1/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_snd_stage = 2; }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_M4A1ReloadDuration(sil);

            if (csqc_m4a1_snd_stage < 1 && elapsed >= rel * M4A1_RELOAD_F_CLIPOUT)
            {
                localsound("sounds/weapons/wpn_csm4a1/clipout.wav"); CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_m4a1_snd_stage = 1;
            }
            if (csqc_m4a1_snd_stage < 2 && elapsed >= rel * M4A1_RELOAD_F_CLIPIN)
            { localsound("sounds/weapons/wpn_csm4a1/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_snd_stage = 2; }
            if (csqc_m4a1_snd_stage < 3 && elapsed >= rel * M4A1_RELOAD_F_BOLT)
            { localsound("sounds/weapons/wpn_csm4a1/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_m4a1_snd_stage = 3; }
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            if (csqc_m4a1_snd_stage < 1
                && elapsed >= SH_M4A1SilencerDuration(sil) * M4A1_SILENCER_F_SWAP)
            {
                if (sil)
                    localsound("sounds/weapons/wpn_csm4a1/silenceroff.wav");
                else
                    localsound("sounds/weapons/wpn_csm4a1/silenceron.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m4a1_snd_stage = 1;
            }
        }
    }

    SH_M4A1TickState(csqc_pred_time);
};

void() CSQC_PredictM4A1Reload =
{
    if (SH_M4A1TryReload(csqc_pred_time))
    {
        csqc_m4a1_snd_stage  = 0;
        csqc_m4a1_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  Every arm
// picks from the silenced or unsilenced half of the one model.
float(float elapsed) CSQC_M4A1DisplayFrame =
{
    float sil = predicted_player.m4a1_silenced;

    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_M4A1SeqToggle(sil);
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_M4A1SeqDraw(sil);
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_M4A1SeqReload(sil);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_M4A1PickShootSeq(sil, predicted_player.wep_action_id);

    return SH_M4A1SeqIdle(sil);
};

void() CSQC_M4A1DropClear =
{
	self.mag_m4a1 = 0;
	self.ammo_m4a1 = 0;
	self.m4a1_silenced = 0;
};

// Weapon special (impulse 7) — silencer toggle, predicted client-side so
// the viewmodel swap is responsive.  Dispatched from CSQC_PredictWeaponImpulse.
void() CSQC_PredictM4A1Special =
{
    if (SH_M4A1TryAltFire(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_m4a1_snd_stage  = 0;
        csqc_m4a1_snd_action = predicted_player.wep_action_id;
    }
};

void() CSQC_M4A1Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m4a1", SCOPE_CLASS_NONE);
	self.weapon_name         = M4A1_DISPLAY_NAME;
	self.weapon_viewmodel    = M4A1_VIEWMODEL;
	self.weapon_worldmodel   = M4A1_WORLDMODEL;
	self.weapon_deploy_sound = M4A1_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM4A1Command;
	self.csqc_predict_reload = CSQC_PredictM4A1Reload;
	self.csqc_display_frame  = CSQC_M4A1DisplayFrame;
	self.csqc_drop_clear     = CSQC_M4A1DropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — models/v_m4a1.mdl draws the same stock cstrike arm as v_aug /
	// v_glock18 / v_usp, all of which are flipped.  cl_lefthand XORs against it.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
