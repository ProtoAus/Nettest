// ============================================================
//  shared/weapons/sh_wpn_dod98k.qc  -  DoD 98K Karabiner
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round stripper clip, 25 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : ADS (iron sights) — pose-only, W_SetADSProfile eligible
//  Spcl  : bayonet stab (WS_SPECIAL, impulse 7)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  IT SHIPS NOTHING OF ITS OWN ANY MORE.  This was the one DoD weapon in the
//  tree with mod-local copies under models/weapons/wpn_dod98k/ and
//  sounds/weapons/wpn_dod98k/, and those copies were not the DoD assets: the
//  view model was a 3.5 MB QUAKE MDL (`IDPO`) conversion with 300 concatenated
//  frames, against the mount's 605 KB GoldSrc studio model with six named
//  sequences.  Frame-driven animation is why the whole animation layer of this
//  file had to be rewritten rather than repointed — there is no frame 186 on a
//  studio model.  The world model differed too; only p_k98.mdl was byte-
//  identical to the mount's.  Everything now resolves through the dod gamedir
//  like the other 27 DoD weapons.
//
//  THE FIRE SAMPLE EXISTS IN THE MOUNT AND THE OLD NOTE WAS WRONG.  Both this
//  file and sh_wpn_dodscoped98k.qc used to say dod/sound/weapons contains no
//  K98 shot ("no k98_shoot.wav, no 98k_shoot.wav" — true as spelled).  DoD
//  names it after the rifle's German name: weapons/kar_shoot.wav, 108760 bytes.
//
//  MEASURED FROM dod/models/v_98k.mdl — 6 sequences, 58 bones, 0 attachments.
//  Event marks are stored as FRACTIONS of their sequence, not absolute times,
//  so a mount shipping a differently-timed build stays in sync (FTE reports the
//  real duration through SH_SeqDuration).
//
//   [0] idle       16fps    2f  0.062s
//   [1] shoot      35fps   57f  1.600s   <- THE BOLT CYCLE IS INSIDE THE SHOT
//         f1   5001 muzzleflash 41
//         f21  5004 "weapons/boltback.wav"      frac 0.375
//         f27  6002 shell eject 2               frac 0.464
//         f43  5004 "weapons/boltforward.wav"   frac 0.768
//   [2] reload     40fps  126f  3.125s
//         f14  5004 "weapons/boltback.wav"              frac 0.112
//         f72  5004 "weapons/tommy_reload_clipin.wav"   frac 0.576
//         f98  5004 "weapons/boltforward.wav"           frac 0.784
//   [3] draw       30fps   31f  1.000s
//         f1   5004 "weapons/rifleselect.wav"   frac 0.033
//   [4] stabslash  30fps   46f  1.500s
//   [5] stab       30fps   39f  1.267s
//
//  ONE SHARED SOUND WORTH KNOWING: the reload's middle event is
//  `tommy_reload_clipin.wav`, not a K98-specific sample.  That set is shared
//  across most box-fed DoD weapons and the model names it explicitly — the same
//  note is in sh_wpn_dodk43.qc and sh_wpn_dodscoped98k.qc.
//
//  THE BAYONET IS ON IMPULSE 7, NOT +attack2.  It used to be the alt-fire, which
//  meant this rifle was the one DoD long arm with no iron sights: +attack2 is the
//  ADS button everywhere else in the tree (weapon_ads_eligible), and a bayonet
//  stab is a far rarer action than aiming.  The scoped K98 already made the same
//  call for the same reason (its +attack2 is the scope).  Requested directly.

// --- Ammo fields ---
.float mag_98k;
.float ammo_98k;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float K98_SEQ_IDLE      = 0;
const float K98_SEQ_SHOOT     = 1;
const float K98_SEQ_RELOAD    = 2;
const float K98_SEQ_DRAW      = 3;
const float K98_SEQ_STABSLASH = 4;
const float K98_SEQ_STAB      = 5;

const float K98_FRAME_INTERVAL        = 0.0333334;   // 1/30 — the wepframe tick, not an animation rate

// Event marks as FRACTIONS of their sequence — see the header.
const float K98_SHOOT_F_BOLTBACK  = 0.375;
const float K98_SHOOT_F_BOLTFWD   = 0.768;
const float K98_RELOAD_F_BOLTBACK = 0.112;
const float K98_RELOAD_F_CLIPIN   = 0.576;
const float K98_RELOAD_F_BOLTFWD  = 0.784;
const float K98_DRAW_F_SELECT     = 0.033;

// The stab lands a quarter into its take, where the old frame-based version put
// K98_STAB_STRIKE_FRAME (just after the swing starts).
const float K98_STAB_F_STRIKE = 0.25;

const float K98_FIRE_DELAY            = 1.05;
const float K98_DRYFIRE_DELAY         = 0.2;
const float K98_STAB_DELAY            = 0.65;

const float K98_IDLE_REARM_MIN = 10;
const float K98_IDLE_REARM_MAX = 15;

const float MAX_MAG_98K               = 5;
const float MAX_AMMO_98K              = 25;

// --- Balance (unchanged by the asset move) ---
const float K98_BASE_SPREAD           = 0.01;
const float K98_MOVE_SPREAD           = 0.09;
const float K98_FULL_SPREAD_SPEED     = 320;
const float K98_CLOSE_DAMAGE          = 80;
const float K98_MIN_DAMAGE            = 60;
const float K98_DAMAGE_FALLOFF_RANGE  = 4096;
const float K98_KICK_PITCH    = 3.0;   // sv_gunkick — bolt sniper, big single kick.
const float K98_KICK_VARIANCE = 0.6;
const float K98_KICK_STRENGTH = 1.5;   // single-shot bolt — heaviest kick.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float K98_MUZZLE_FORWARD = 52;
const float K98_MUZZLE_RIGHT   = 3;
const float K98_MUZZLE_DOWN    = 2;
const float K98_STAB_DAMAGE           = 70;
const float K98_STAB_RANGE            = 88;

const string K98_VIEWMODEL    = "models/v_98k.mdl";
const string K98_WORLDMODEL   = "models/w_98k.mdl";
const string K98_DEPLOY_SOUND = "";
const string K98_DISPLAY_NAME = "98K";

.float dod98k_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_98KSeqIdle   = { return SH_SeqForName(K98_VIEWMODEL, "idle",   K98_SEQ_IDLE); };
float() SH_98KSeqShoot  = { return SH_SeqForName(K98_VIEWMODEL, "shoot",  K98_SEQ_SHOOT); };
float() SH_98KSeqReload = { return SH_SeqForName(K98_VIEWMODEL, "reload", K98_SEQ_RELOAD); };
float() SH_98KSeqDraw   = { return SH_SeqForName(K98_VIEWMODEL, "draw",   K98_SEQ_DRAW); };
// THE MODEL HAS TWO BAYONET TAKES AND ONLY ONE WAS EVER PLAYED.  `stab` (1.267 s)
// is the straight thrust and `stabslash` (1.500 s) sweeps the blade across; the
// second was declared at K98_SEQ_STABSLASH and then never referenced, so every
// bayonet attack in the game looked identical.  Alternated off wep_action_id
// rather than rolled, so the server and the client's prediction land on the same
// take — the same deterministic pick SH_SawPickShootSeq and SH_HLSMGPickShootSeq
// use.  Takes the counter as a parameter because SSQC reads it off `self` and the
// display path off `predicted_player`.
float(float action_id) SH_98KSeqStabFor =
{
    if (action_id - floor(action_id / 2) * 2)
    {
        float s = SH_SeqTryName(K98_VIEWMODEL, "stabslash");
        if (s >= 0) return s;
    }
    return SH_SeqForName(K98_VIEWMODEL, "stab", K98_SEQ_STAB);
};
float() SH_98KSeqStab   = { return SH_98KSeqStabFor(self.wep_action_id); };

float() SH_98KDrawDuration   = { return SH_SeqDuration(K98_VIEWMODEL, SH_98KSeqDraw(),   1.000); };
float() SH_98KShootDuration  = { return SH_SeqDuration(K98_VIEWMODEL, SH_98KSeqShoot(),  1.600); };
float() SH_98KReloadDuration = { return SH_SeqDuration(K98_VIEWMODEL, SH_98KSeqReload(), 3.125); };
// Per-take, because the two are 0.233 s apart — one flat number would either cut
// the slash off or freeze the thrust on its last frame.
float() SH_98KStabDuration   = { return SH_SeqDuration(K98_VIEWMODEL, SH_98KSeqStab(),   1.267); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_98KTickState =
{
    // WS_SPECIAL (bayonet stab) is handled here, not by SH_StandardTickState,
    // which knows nothing about it.
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_98KStabDuration()) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    // The clip goes in at RELOAD_F_CLIPIN, not at the end: the last fifth of the
    // take is the bolt going forward on a rifle that is already loaded.
    float rel = SH_98KReloadDuration();
    return SH_StandardTickState(now, mag_98k, ammo_98k, MAX_MAG_98K,
        SH_98KDrawDuration(), SH_98KShootDuration(),
        rel, rel * K98_RELOAD_F_CLIPIN);
};

float(float now) SH_98KTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_98k, K98_FIRE_DELAY, K98_DRYFIRE_DELAY);
};

float(float now) SH_98KTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_98k, ammo_98k, MAX_MAG_98K, SH_98KReloadDuration());
};

float(float now) SH_98KTryStab =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (SH_ShieldBlocksFire())     return 0;
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished) return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + K98_STAB_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_98KPickupCopy =
{ player.mag_98k = self.mag_98k; player.ammo_98k = self.ammo_98k; };

void() W_98KShoot =
{
    W_PenetratingHitscanShoot(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED,
        K98_CLOSE_DAMAGE, K98_MIN_DAMAGE, K98_DAMAGE_FALLOFF_RANGE, 80, 0.98,
        K98_KICK_PITCH, K98_KICK_VARIANCE, K98_KICK_STRENGTH);
};

void() W_98KStab =
{
    vector src, end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * K98_STAB_RANGE;

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    if (trace_fraction < 1.0)
    {
        if (W_CanDamageTarget(trace_ent))
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hit1.wav", 1, ATTN_NORM);
            // Defer player damage to attacker's hitclaim — see
            // sh_wpn_melee.qc for rationale.
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, K98_STAB_DAMAGE);
            }
        }
        else
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hitwall1.wav", 1, ATTN_NORM);
            PhysProp_TryPushFromTrace(v_forward, K98_STAB_DAMAGE);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
        sound(self, CHAN_WEAPON, "weapons/knife_slash1.wav", 1, ATTN_NORM);
};

void() W_98KFire =
{
    float r = SH_98KTryFire(time);
    if (r == 1)
    {
        self.weaponframe      = SH_98KSeqShoot();
        self.wep_nextframe    = time + K98_FRAME_INTERVAL;
        self.dod98k_snd_stage = 0;
        W_98KShoot();
        sound(self, CHAN_WEAPON, "weapons/kar_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

// Weapon special (impulse 7) — the bayonet.  See the header: this used to be
// W_98KAltFire, and +attack2 is now free for iron sights.
void() W_98KSpecial =
{
    if (SH_98KTryStab(time))
    {
        self.weaponframe      = SH_98KSeqStab();
        self.wep_nextframe    = time + K98_FRAME_INTERVAL;
        self.dod98k_snd_stage = 0;
    }
};

void() W_98KReload =
{
    if (SH_98KTryReload(time))
    {
        self.weaponframe      = SH_98KSeqReload();
        self.wep_nextframe    = time + K98_FRAME_INTERVAL;
        self.dod98k_snd_stage = 0;
    }
};

void() W_98KFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += K98_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_98KDrawDuration() * K98_DRAW_F_SELECT && self.dod98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float sh = SH_98KShootDuration();
        if (elapsed >= sh * K98_SHOOT_F_BOLTBACK && self.dod98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 1;
        }
        if (elapsed >= sh * K98_SHOOT_F_BOLTFWD && self.dod98k_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_98KStabDuration() * K98_STAB_F_STRIKE && self.dod98k_snd_stage < 1)
        {
            self.dod98k_snd_stage = 1;
            W_98KStab();
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_98KReloadDuration();
        if (elapsed >= rel * K98_RELOAD_F_BOLTBACK && self.dod98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 1;
        }
        if (elapsed >= rel * K98_RELOAD_F_CLIPIN && self.dod98k_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 2;
        }
        if (elapsed >= rel * K98_RELOAD_F_BOLTFWD && self.dod98k_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dod98k_snd_stage = 3;
        }
    }

    float result = SH_98KTickState(time);
    if (result & 1)
    {
        self.weaponframe      = SH_98KSeqIdle();
        self.wep_nextframe    = 0;
        self.dod98k_snd_stage = 0;
    }
};

void() W_98KEquip =
{
    // Iron sights on +attack2 (pose only, no scope overlay) — the button the
    // bayonet used to own.
    W_SetADSProfile(TRUE, "cl_ads_dod98k", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(K98_VIEWMODEL, K98_DISPLAY_NAME, SH_98KSeqDraw(),
        K98_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_98KFire;
    self.reload   = W_98KReload;
    self.wepframe = W_98KFrame;
    self.altfire  = __NULL__;      // +attack2 belongs to ADS now
    self.special  = W_98KSpecial;  // impulse 7 = bayonet
    self.shoot    = W_98KShoot;
    self.dod98k_snd_stage = 0;
    W_SetCrosshairProfile(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_98KDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_98k = self.mag_98k; tgt.ammo_98k = self.ammo_98k;
    self.mag_98k = 0; self.ammo_98k = 0;
    setmodel(tgt, K98_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_dod98k"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_DOD98K; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_98KEquip; tgt.weap_drop_func = W_98KDrop;
    tgt.pickupcopy = W_98KPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_dod98k =
{
    setmodel(self, K98_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_dod98k"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_DOD98K; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_98KEquip; self.weap_drop_func = W_98KDrop;
    self.pickupcopy = W_98KPickupCopy; self.touch = weapon_touch;
    self.mag_98k = MAX_MAG_98K; self.ammo_98k = MAX_AMMO_98K;
    W_RegisterMapWeapon(weapon_dod98k);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_98k_snd_stage;
float csqc_98k_snd_action;

void() CSQC_Predict98KCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_98k_snd_action)
    {
        csqc_98k_snd_action = predicted_player.wep_action_id;
        csqc_98k_snd_stage  = 0;
    }

    // NOTE: no `input_buttons & 4` branch.  +attack2 is the ADS button now and
    // is consumed by the shared ADS envelope (weapon_ads_eligible); the bayonet
    // moved to WEAPON_IMPULSE_SPECIAL.

    if (input_buttons & 1)
    {
        r = SH_98KTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_98k_snd_stage = 0;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/kar_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(K98_BASE_SPREAD, K98_MOVE_SPREAD, K98_FULL_SPREAD_SPEED,
                    K98_CLOSE_DAMAGE, K98_MIN_DAMAGE, K98_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    K98_KICK_PITCH, K98_KICK_VARIANCE, K98_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Sniper muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(K98_MUZZLE_FORWARD, K98_MUZZLE_RIGHT,
                    K98_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(K98_MUZZLE_FORWARD, K98_MUZZLE_RIGHT,
                    K98_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedAutoSound(); }
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_98k_snd_stage < 1 && elapsed >= SH_98KDrawDuration() * K98_DRAW_F_SELECT)
            { localsound("weapons/rifleselect.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 1; }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float sh = SH_98KShootDuration();
            if (csqc_98k_snd_stage < 1 && elapsed >= sh * K98_SHOOT_F_BOLTBACK)
            { localsound("weapons/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 1; }
            if (csqc_98k_snd_stage < 2 && elapsed >= sh * K98_SHOOT_F_BOLTFWD)
            { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 2; }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_98KReloadDuration();
            if (csqc_98k_snd_stage < 1 && elapsed >= rel * K98_RELOAD_F_BOLTBACK)
            { localsound("weapons/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 1; }
            if (csqc_98k_snd_stage < 2 && elapsed >= rel * K98_RELOAD_F_CLIPIN)
            { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 2; }
            if (csqc_98k_snd_stage < 3 && elapsed >= rel * K98_RELOAD_F_BOLTFWD)
            { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_98k_snd_stage = 3; }
        }
    }

    SH_98KTickState(csqc_pred_time);
};

void() CSQC_Predict98KReload =
{
    if (SH_98KTryReload(csqc_pred_time))
    {
        csqc_98k_snd_stage  = 0;
        csqc_98k_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// THE BAYONET IS PREDICTED NOW.  The stab reported as "only makes sound when you
// do the melee, no visuals" and both halves of that were the same bug: nothing
// dispatched a prediction (CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL arm
// is a hand-written weapon list and this rifle was not on it), and a weaponstate
// the SERVER alone sets never reaches predicted_player — reconcile does not write
// fire-decision state back (client/cl_player.qc:1022) and sv_confirmed_weaponstate
// is written and never read.  So the arm at the top of CSQC_98KDisplayFrame that
// tests WS_SPECIAL could not fire, and the swing was audible and invisible.
//
// The verdict stays the server's: this predicts the STATE and the swing sound
// only, exactly as CSQC_PredictDodK43Special does.
//
// THE Ex FORM, NOT THE SHORT ONE.  CSQC_PredictedMeleeTrace's hit_snd1/hit_snd2
// are two random variants of the SAME material sample (it picks between them with
// random() < 0.5); the FLESH set is the separate body_snd1..3 tail that only the
// Ex form takes.  Passing knife_hit1 as hit_snd1 and knife_hitwall1 as hit_snd2 -
// which is what this call did - therefore coin-flipped between the flesh sample
// and the wall sample on every WALL hit, which is the reported "randomly switches
// between human impact sound and wall impact sound when you hit a wall".  It was
// not audible as a doubling because CSQC_Event_Sound mutes the server's own
// CHAN_WEAPON echo for 1 s after a predicted weapon sound (client/cl_main.qc:1399),
// so the client's pick is the only one the attacker hears.
//
// The split now matches W_98KStab exactly: knife_hit1 into flesh, knife_hitwall1
// into the material slot, knife_slash1 on a miss.  dod/sound/weapons carries one
// wall sample and no second variant, so hit_snd2 is deliberately empty.
void() CSQC_Predict98KSpecial =
{
    if (SH_98KTryStab(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            CSQC_PredictedMeleeTraceEx(K98_STAB_RANGE, K98_STAB_DAMAGE,
                "weapons/knife_hitwall1.wav", "",
                "weapons/knife_slash1.wav",
                "weapons/knife_hit1.wav", "", "");
            // The MELEE form: it arms the predicted-echo mute only if the trace
            // above actually played something.  A stab that landed on a monster
            // plays nothing locally by design, and arming the window there ate the
            // server's real impact sample for a second - the swing went silent for
            // the attacker while everyone else heard it.
            CSQC_RecordPredictedMeleeSound();
        }
    }
};

float(float elapsed) CSQC_98KDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_98KSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_98KSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_98KSeqShoot();
    // The RENDERED entity's counter, so a spectated player's bayonet alternates
    // off their swing count rather than ours (cl_weapons.qc:1805 calls this with
    // predicted_player pointed at a scratch entity).
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_98KSeqStabFor(predicted_player.wep_action_id);

    float idle = SH_SeqIdleDisplay(cltime, WEP_DOD98K, predicted_player.weaponstate,
                                   SH_98KSeqIdle(), SH_98KSeqIdle(),
                                   K98_IDLE_REARM_MIN, K98_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;
    return SH_98KSeqIdle();
};

void() CSQC_98KDropClear =
{
	self.mag_98k = 0;
	self.ammo_98k = 0;
};

void() CSQC_98KEquip =
{
	W_SetADSProfile(TRUE, "cl_ads_dod98k", SCOPE_CLASS_NONE);
	self.weapon_name         = K98_DISPLAY_NAME;
	self.weapon_viewmodel    = K98_VIEWMODEL;
	self.weapon_worldmodel   = K98_WORLDMODEL;
	self.weapon_deploy_sound = K98_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_Predict98KCommand;
	self.csqc_predict_reload = CSQC_Predict98KReload;
	self.csqc_display_frame  = CSQC_98KDisplayFrame;
	self.csqc_drop_clear     = CSQC_98KDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
