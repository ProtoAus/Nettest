// ============================================================
//  shared/weapons/sh_wpn_dodenfield.qc  -  DoD Lee-Enfield No.4 Mk I
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action .303
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : ADS (iron sights)
//  Spcl  : bayonet stab (WS_SPECIAL, impulse 7)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON — models/v_enfield.mdl, models/w_enfield.mdl
//  and models/p_enfield.mdl all come from the mounted dod gamedir.
//
//  MEASURED FROM dod/models/v_enfield.mdl — 6 sequences, 59 bones.  Durations
//  are (frames-1)/fps; event marks are FRACTIONS of their own sequence.
//
//   [0] idle         10fps 121f 12.000s
//   [1] shoot        35fps  59f  1.657s   <- THE BOLT CYCLE IS IN THE SHOT
//         f1  5001 muzzleflash 41
//         f14 boltback.wav      frac 0.2414
//         f28 6002 shell eject  frac 0.4828
//         f37 boltforward.wav   frac 0.6379
//   [2] reload       35fps 129f  3.657s   <- ONE charger (5 rounds), two clipins
//         f14  boltback.wav             frac 0.1094
//         f71  tommy_reload_clipin.wav  frac 0.5548
//         f88  tommy_reload_clipin.wav  frac 0.6875
//         f107 boltforward.wav          frac 0.8359
//   [3] draw         30fps  25f  0.800s   f1 rifleselect  frac 0.0413
//   [4] reload_long  35fps 192f  5.457s   <- TWO chargers, FOUR clipins
//         f14  boltback.wav             frac 0.0733
//         f75  tommy_reload_clipin.wav  frac 0.3927
//         f92  tommy_reload_clipin.wav  frac 0.4818
//         f129 tommy_reload_clipin.wav  frac 0.6754
//         f147 tommy_reload_clipin.wav  frac 0.7697
//         f165 boltforward.wav          frac 0.8639
//   [5] stab         30fps  39f  1.267s   (no events; no `stabslash` on this model)
//
//  THE CLIPIN EVENTS COME IN PAIRS, which is what identifies the two takes: the
//  Lee-Enfield loads from five-round chargers, so `reload` is ONE charger (two
//  clipin marks — the charger going in and the empty being flicked out) and
//  `reload_long` is TWO (four marks).  The take is chosen off the magazine, the
//  same way sh_wpn_dodenfieldscoped.qc does it.
//
//  reload_apply_time IS PASSED AS reload_dur ON PURPOSE, carried over verbatim
//  from the scoped sibling.  Crediting the rounds mid-animation would push the
//  magazine past the five-round boundary while `reload_long` was still playing,
//  and CSQC_DodEnfDisplayFrame would cut to the short take on the next frame.
//
//  THE BAYONET IS ON IMPULSE 7, not +attack2 — +attack2 is the ADS button on
//  every DoD long arm in this tree.  Same call the two Kar98ks make.  NOTE that
//  self.special must be assigned AFTER W_StandardEquipSetup, which nulls it;
//  getting that order wrong is how the scoped K98's bayonet shipped dead.

// --- Ammo fields ---
.float mag_dodenfield;
.float ammo_dodenfield;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODENF_SEQ_IDLE        = 0;
const float DODENF_SEQ_SHOOT       = 1;
const float DODENF_SEQ_RELOAD      = 2;
const float DODENF_SEQ_DRAW        = 3;
const float DODENF_SEQ_RELOAD_LONG = 4;
const float DODENF_SEQ_STAB        = 5;

const float DODENF_FRAME_INTERVAL = 0.0333334;
const float DODENF_FIRE_DELAY     = 1.00;   // the Lee-Enfield's fast cock-on-close bolt
const float DODENF_DRYFIRE_DELAY  = 0.20;

const float DODENF_SHOOT_F_BOLTBACK  = 0.2414;
const float DODENF_SHOOT_F_BOLTFWD   = 0.6379;
const float DODENF_DRAW_F_SELECT     = 0.0413;

const float DODENF_RELOAD_F_BOLTBACK = 0.1094;
const float DODENF_RELOAD_F_CLIPIN1  = 0.5548;
const float DODENF_RELOAD_F_CLIPIN2  = 0.6875;
const float DODENF_RELOAD_F_BOLTFWD  = 0.8359;

const float DODENF_LONG_F_BOLTBACK   = 0.0733;
const float DODENF_LONG_F_CLIPIN1    = 0.3927;
const float DODENF_LONG_F_CLIPIN2    = 0.4818;
const float DODENF_LONG_F_CLIPIN3    = 0.6754;
const float DODENF_LONG_F_CLIPIN4    = 0.7697;
const float DODENF_LONG_F_BOLTFWD    = 0.8639;

const float DODENF_STAB_F_STRIKE = 0.25;
const float DODENF_STAB_DELAY    = 0.65;
const float DODENF_STAB_DAMAGE   = 70;
const float DODENF_STAB_RANGE    = 88;

const float DODENF_IDLE_REARM_MIN = 10;
const float DODENF_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODENF  = 10;
const float MAX_AMMO_DODENF = 30;
const float DODENF_CHARGER  = 5;

// --- Balance ---
//
// The scoped No.4(T) in this tree is 72/55 over 4096 at a 1.45 s trigger.  This
// is the same rifle without the sight, so it gets the same cartridge and a
// FASTER trigger — 1.00 s, the quickest bolt in the mod, which is the
// Lee-Enfield's actual claim to fame (cock-on-close, 60-degree throw, ten
// rounds).  It trades the scope's precision for that: base spread 0.011 against
// the scoped rifle's 0.004, and 4 fewer points of close damage than the Kar98k
// because it fires a lighter bullet faster.
const float DODENF_BASE_SPREAD          = 0.011;
const float DODENF_MOVE_SPREAD          = 0.090;
const float DODENF_FULL_SPREAD_SPEED    = 320;
const float DODENF_CLOSE_DAMAGE         = 76;
const float DODENF_MIN_DAMAGE           = 57;
const float DODENF_DAMAGE_FALLOFF_RANGE = 4096;
const float DODENF_KICK_PITCH    = 2.70;
const float DODENF_KICK_VARIANCE = 0.55;
const float DODENF_KICK_STRENGTH = 1.40;

const float DODENF_MUZZLE_FORWARD = 50;
const float DODENF_MUZZLE_RIGHT   = 3;
const float DODENF_MUZZLE_DOWN    = 2;

const string DODENF_VIEWMODEL    = "models/v_enfield.mdl";
const string DODENF_WORLDMODEL   = "models/w_enfield.mdl";
const string DODENF_DEPLOY_SOUND = "";
const string DODENF_DISPLAY_NAME = "LEE-ENFIELD";

.float dodenf_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodEnfSeqIdle       = { return SH_SeqForName(DODENF_VIEWMODEL, "idle",        DODENF_SEQ_IDLE); };
float() SH_DodEnfSeqShoot      = { return SH_SeqForName(DODENF_VIEWMODEL, "shoot",       DODENF_SEQ_SHOOT); };
float() SH_DodEnfSeqReload1    = { return SH_SeqForName(DODENF_VIEWMODEL, "reload",      DODENF_SEQ_RELOAD); };
float() SH_DodEnfSeqReloadLong = { return SH_SeqForName(DODENF_VIEWMODEL, "reload_long", DODENF_SEQ_RELOAD_LONG); };
float() SH_DodEnfSeqDraw       = { return SH_SeqForName(DODENF_VIEWMODEL, "draw",        DODENF_SEQ_DRAW); };
float() SH_DodEnfSeqStab       = { return SH_SeqForName(DODENF_VIEWMODEL, "stab",        DODENF_SEQ_STAB); };

// More than one charger missing => the long take.
float(float mag) SH_DodEnfNeedsLong =
{
    return ((MAX_MAG_DODENF - mag) > DODENF_CHARGER);
};

float() SH_DodEnfSeqReload =
{
    return SH_DodEnfNeedsLong(self.mag_dodenfield) ? SH_DodEnfSeqReloadLong() : SH_DodEnfSeqReload1();
};

float() SH_DodEnfDrawDuration  = { return SH_SeqDuration(DODENF_VIEWMODEL, SH_DodEnfSeqDraw(),  0.800); };
float() SH_DodEnfShootDuration = { return SH_SeqDuration(DODENF_VIEWMODEL, SH_DodEnfSeqShoot(), 1.657); };
float() SH_DodEnfStabDuration  = { return SH_SeqDuration(DODENF_VIEWMODEL, SH_DodEnfSeqStab(),  1.267); };

float() SH_DodEnfReloadDuration =
{
    if (SH_DodEnfNeedsLong(self.mag_dodenfield))
        return SH_SeqDuration(DODENF_VIEWMODEL, SH_DodEnfSeqReloadLong(), 5.457);
    return SH_SeqDuration(DODENF_VIEWMODEL, SH_DodEnfSeqReload1(), 3.657);
};

// ============================================================
//  SHARED — state machine
// ============================================================

// reload_apply_time == reload_dur ON PURPOSE — see the header.
float(float now) SH_DodEnfTickState =
{
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodEnfStabDuration()) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    float rel = SH_DodEnfReloadDuration();
    return SH_StandardTickState(now, mag_dodenfield, ammo_dodenfield, MAX_MAG_DODENF,
        SH_DodEnfDrawDuration(), SH_DodEnfShootDuration(), rel, rel);
};

float(float now) SH_DodEnfTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_dodenfield, DODENF_FIRE_DELAY, DODENF_DRYFIRE_DELAY);
};

float(float now) SH_DodEnfTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_dodenfield, ammo_dodenfield, MAX_MAG_DODENF,
        SH_DodEnfReloadDuration());
};

float(float now) SH_DodEnfTryStab =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (SH_ShieldBlocksFire())     return 0;
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + DODENF_STAB_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodEnfPickupCopy =
{
    player.mag_dodenfield  = self.mag_dodenfield;
    player.ammo_dodenfield = self.ammo_dodenfield;
};

void() W_DodEnfShoot =
{
    W_PenetratingHitscanShoot(DODENF_BASE_SPREAD, DODENF_MOVE_SPREAD, DODENF_FULL_SPREAD_SPEED,
        DODENF_CLOSE_DAMAGE, DODENF_MIN_DAMAGE, DODENF_DAMAGE_FALLOFF_RANGE, 80, 0.98,
        DODENF_KICK_PITCH, DODENF_KICK_VARIANCE, DODENF_KICK_STRENGTH);
};

void() W_DodEnfStab =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * DODENF_STAB_RANGE;

    W_MeleeTrace(src, end);

    if (trace_fraction < 1.0)
    {
        if (W_CanDamageTarget(trace_ent))
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hit1.wav", 1, ATTN_NORM);
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, DODENF_STAB_DAMAGE);
            }
        }
        else
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hitwall1.wav", 1, ATTN_NORM);
            PhysProp_TryPushFromTrace(v_forward, DODENF_STAB_DAMAGE);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
        sound(self, CHAN_WEAPON, "weapons/knife_slash1.wav", 1, ATTN_NORM);
};

void() W_DodEnfFire =
{
    float r = SH_DodEnfTryFire(time);

    if (r == 1)
    {
        self.weaponframe      = SH_DodEnfSeqShoot();
        self.wep_nextframe    = time + DODENF_FRAME_INTERVAL;
        self.dodenf_snd_stage = 0;

        W_DodEnfShoot();

        sound(self, CHAN_WEAPON, "weapons/enfield_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

// Weapon special (impulse 7) — the bayonet.
void() W_DodEnfSpecial =
{
    if (SH_DodEnfTryStab(time))
    {
        self.weaponframe      = SH_DodEnfSeqStab();
        self.wep_nextframe    = time + DODENF_FRAME_INTERVAL;
        self.dodenf_snd_stage = 0;
    }
};

void() W_DodEnfReload =
{
    if (SH_DodEnfTryReload(time))
    {
        // Read the take BEFORE the magazine changes — the rounds land at the end
        // of the state, so this is stable for the whole animation.
        self.weaponframe      = SH_DodEnfSeqReload();
        self.wep_nextframe    = time + DODENF_FRAME_INTERVAL;
        self.dodenf_snd_stage = 0;
    }
};

void() W_DodEnfFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODENF_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodEnfDrawDuration() * DODENF_DRAW_F_SELECT
            && self.dodenf_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodenf_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float sh = SH_DodEnfShootDuration();
        if (elapsed >= sh * DODENF_SHOOT_F_BOLTBACK && self.dodenf_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dodenf_snd_stage = 1;
        }
        if (elapsed >= sh * DODENF_SHOOT_F_BOLTFWD && self.dodenf_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dodenf_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_DodEnfStabDuration() * DODENF_STAB_F_STRIKE
            && self.dodenf_snd_stage < 1)
        {
            self.dodenf_snd_stage = 1;
            W_DodEnfStab();
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodEnfReloadDuration();

        if (SH_DodEnfNeedsLong(self.mag_dodenfield))
        {
            if (elapsed >= rel * DODENF_LONG_F_BOLTBACK && self.dodenf_snd_stage < 1)
            { sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 1; }
            if (elapsed >= rel * DODENF_LONG_F_CLIPIN1  && self.dodenf_snd_stage < 2)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 2; }
            if (elapsed >= rel * DODENF_LONG_F_CLIPIN2  && self.dodenf_snd_stage < 3)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 3; }
            if (elapsed >= rel * DODENF_LONG_F_CLIPIN3  && self.dodenf_snd_stage < 4)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 4; }
            if (elapsed >= rel * DODENF_LONG_F_CLIPIN4  && self.dodenf_snd_stage < 5)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 5; }
            if (elapsed >= rel * DODENF_LONG_F_BOLTFWD  && self.dodenf_snd_stage < 6)
            { sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 6; }
        }
        else
        {
            if (elapsed >= rel * DODENF_RELOAD_F_BOLTBACK && self.dodenf_snd_stage < 1)
            { sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 1; }
            if (elapsed >= rel * DODENF_RELOAD_F_CLIPIN1  && self.dodenf_snd_stage < 2)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 2; }
            if (elapsed >= rel * DODENF_RELOAD_F_CLIPIN2  && self.dodenf_snd_stage < 3)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 3; }
            if (elapsed >= rel * DODENF_RELOAD_F_BOLTFWD  && self.dodenf_snd_stage < 4)
            { sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM); self.dodenf_snd_stage = 4; }
        }
    }

    float result = SH_DodEnfTickState(time);
    if (result & 1)
    {
        self.weaponframe      = SH_DodEnfSeqIdle();
        self.wep_nextframe    = 0;
        self.dodenf_snd_stage = 0;
    }
};

void() W_DodEnfEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodenfield", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODENF_VIEWMODEL, DODENF_DISPLAY_NAME, SH_DodEnfSeqDraw(),
        DODENF_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodEnfFire;
    self.reload   = W_DodEnfReload;
    self.wepframe = W_DodEnfFrame;
    self.shoot    = W_DodEnfShoot;
    self.altfire  = __NULL__;         // +attack2 is ADS
    // AFTER W_StandardEquipSetup, which nulls .special — see the header.
    self.special  = W_DodEnfSpecial;  // impulse 7 = bayonet
    self.dodenf_snd_stage = 0;
    W_SetCrosshairProfile(DODENF_BASE_SPREAD, DODENF_MOVE_SPREAD, DODENF_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_DodEnfDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodenfield  = self.mag_dodenfield;
    tgt.ammo_dodenfield = self.ammo_dodenfield;

    self.mag_dodenfield  = 0;
    self.ammo_dodenfield = 0;

    setmodel(tgt, DODENF_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_enfield";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODENFIELD;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodEnfEquip;
    tgt.weap_drop_func = W_DodEnfDrop;
    tgt.pickupcopy     = W_DodEnfPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_enfield =
{
    setmodel(self, DODENF_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname       = "weapon_enfield";
    self.solid           = SOLID_TRIGGER;
    self.movetype        = MOVETYPE_TOSS;
    self.weapon          = WEP_DODENFIELD;
    self.weapon_slot     = SLOT_PRIMARY;
    self.weap_draw       = W_DodEnfEquip;
    self.weap_drop_func  = W_DodEnfDrop;
    self.pickupcopy      = W_DodEnfPickupCopy;
    self.touch           = weapon_touch;
    self.mag_dodenfield  = MAX_MAG_DODENF;
    self.ammo_dodenfield = MAX_AMMO_DODENF;
    W_RegisterMapWeapon(weapon_enfield);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodenf_snd_stage;
float csqc_dodenf_snd_action;

void() CSQC_PredictDodEnfCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodenf_snd_action)
    {
        csqc_dodenf_snd_action = predicted_player.wep_action_id;
        csqc_dodenf_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodEnfTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/enfield_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODENF_BASE_SPREAD, DODENF_MOVE_SPREAD, DODENF_FULL_SPREAD_SPEED,
                    DODENF_CLOSE_DAMAGE, DODENF_MIN_DAMAGE, DODENF_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    DODENF_KICK_PITCH, DODENF_KICK_VARIANCE, DODENF_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODENF_MUZZLE_FORWARD, DODENF_MUZZLE_RIGHT,
                    DODENF_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODENF_MUZZLE_FORWARD, DODENF_MUZZLE_RIGHT,
                    DODENF_MUZZLE_DOWN, self.wep_action_id, 4);
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
            if (csqc_dodenf_snd_stage < 1
                && elapsed >= SH_DodEnfDrawDuration() * DODENF_DRAW_F_SELECT)
            { localsound("weapons/rifleselect.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 1; }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float sh = SH_DodEnfShootDuration();
            if (csqc_dodenf_snd_stage < 1 && elapsed >= sh * DODENF_SHOOT_F_BOLTBACK)
            { localsound("weapons/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 1; }
            if (csqc_dodenf_snd_stage < 2 && elapsed >= sh * DODENF_SHOOT_F_BOLTFWD)
            { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 2; }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodEnfReloadDuration();

            if (SH_DodEnfNeedsLong(predicted_player.mag_dodenfield))
            {
                if (csqc_dodenf_snd_stage < 1 && elapsed >= rel * DODENF_LONG_F_BOLTBACK)
                { localsound("weapons/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 1; }
                if (csqc_dodenf_snd_stage < 2 && elapsed >= rel * DODENF_LONG_F_CLIPIN1)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 2; }
                if (csqc_dodenf_snd_stage < 3 && elapsed >= rel * DODENF_LONG_F_CLIPIN2)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 3; }
                if (csqc_dodenf_snd_stage < 4 && elapsed >= rel * DODENF_LONG_F_CLIPIN3)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 4; }
                if (csqc_dodenf_snd_stage < 5 && elapsed >= rel * DODENF_LONG_F_CLIPIN4)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 5; }
                if (csqc_dodenf_snd_stage < 6 && elapsed >= rel * DODENF_LONG_F_BOLTFWD)
                { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 6; }
            }
            else
            {
                if (csqc_dodenf_snd_stage < 1 && elapsed >= rel * DODENF_RELOAD_F_BOLTBACK)
                { localsound("weapons/boltback.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 1; }
                if (csqc_dodenf_snd_stage < 2 && elapsed >= rel * DODENF_RELOAD_F_CLIPIN1)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 2; }
                if (csqc_dodenf_snd_stage < 3 && elapsed >= rel * DODENF_RELOAD_F_CLIPIN2)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 3; }
                if (csqc_dodenf_snd_stage < 4 && elapsed >= rel * DODENF_RELOAD_F_BOLTFWD)
                { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenf_snd_stage = 4; }
            }
        }
    }

    SH_DodEnfTickState(csqc_pred_time);
};

void() CSQC_PredictDodEnfReload =
{
    if (SH_DodEnfTryReload(csqc_pred_time))
    {
        csqc_dodenf_snd_stage  = 0;
        csqc_dodenf_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// THE BAYONET IS PREDICTED NOW, and the note that used to sit here — "not
// predicted, a melee verdict the server owns; the display frame still shows the
// stab as soon as the authoritative WS_SPECIAL arrives" — was wrong on its second
// half, which is why this weapon read as having no bayonet at all.
//
// The authoritative WS_SPECIAL never arrives at predicted_player.  Reconcile does
// not write fire-decision state back (client/cl_player.qc:1022) and
// sv_confirmed_weaponstate is written and never read, so a weaponstate the SERVER
// alone sets is invisible to every display frame in the tree.  The stab happened
// — sound, damage, everything — and the viewmodel never moved.
//
// It was ALSO never dispatched: CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL
// arm is a hand-written weapon list, and the three bayonet rifles were not on it.
// sh_wpn_dodk43.qc:505 already warns that "a prediction function that nothing
// calls is a function that silently does nothing"; here there was no function to
// call in the first place.
//
// The verdict is still the server's: this predicts the STATE and the swing sound
// only, exactly as CSQC_PredictDodK43Special does, so the viewmodel moves at once
// and the damage stays authoritative.
void() CSQC_PredictDodEnfSpecial =
{
    if (SH_DodEnfTryStab(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            // Same three samples W_DodEnfStab plays.  DoD has no bayonet-specific
            // set — the knife's is what the server uses for this stab too.
            //
            // The Ex form, because the short one's two hit slots are random
            // variants of ONE material sample and flesh has to go in the body
            // tail; see the long note on the same call in sh_wpn_dod98k.qc.
            CSQC_PredictedMeleeTraceEx(DODENF_STAB_RANGE, DODENF_STAB_DAMAGE,
                "weapons/knife_hitwall1.wav", "",
                "weapons/knife_slash1.wav",
                "weapons/knife_hit1.wav", "", "");
            // Melee form — arms the echo mute only if the trace played something.
            // See the note at the same call in sh_wpn_dod98k.qc.
            CSQC_RecordPredictedMeleeSound();
        }
    }
};

float(float elapsed) CSQC_DodEnfDisplayFrame =
{
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODENFIELD, predicted_player.weaponstate,
                                   SH_DodEnfSeqIdle(), SH_DodEnfSeqIdle(),
                                   DODENF_IDLE_REARM_MIN, DODENF_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodEnfSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodEnfNeedsLong(predicted_player.mag_dodenfield)
               ? SH_DodEnfSeqReloadLong() : SH_DodEnfSeqReload1();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodEnfSeqShoot();
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodEnfSeqStab();

    return SH_DodEnfSeqIdle();
};

void() CSQC_DodEnfDropClear =
{
    self.mag_dodenfield  = 0;
    self.ammo_dodenfield = 0;
};

void() CSQC_DodEnfEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodenfield", SCOPE_CLASS_NONE);
    self.weapon_name         = DODENF_DISPLAY_NAME;
    self.weapon_viewmodel    = DODENF_VIEWMODEL;
    self.weapon_worldmodel   = DODENF_WORLDMODEL;
    self.weapon_deploy_sound = DODENF_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodEnfCommand;
    self.csqc_predict_reload = CSQC_PredictDodEnfReload;
    self.csqc_display_frame  = CSQC_DodEnfDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodEnfDropClear;
    self.weapon_uses_sequences = TRUE;
    // No csqc_dodenf_snd_stage reset here — CSQC_WeaponEquip re-runs on every
    // reconcile (client/cl_player.qc:1051), so it would replay every passed event.
};

#endif // CSQC
