// ============================================================
//  shared/weapons/sh_wpn_dodscoped98k.qc  -  DoD scoped Karabiner 98k
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round stripper clip, 25 reserve, bolt-action, telescopic sight
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : scope in / out (SCOPE_CLASS_SNIPER_BOLT)
//  Spcl  : bayonet stab (WS_SPECIAL) — the model carries `stab` and `stabslash`
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON.  models/v_scoped98k.mdl,
//  models/w_scoped98k.mdl and models/p_k98s.mdl all come from the mounted dod
//  gamedir, exactly like the twelve DoD guns added before it.
//
//  MEASURED FROM dod/models/v_scoped98k.mdl — 7 sequences, 58 bones.  Frame
//  fractions are given because every event mark below is stored as a fraction of
//  its sequence rather than an absolute time: FTE reports duration from the
//  model, so a mount that ships a differently-timed build stays in sync.
//
//   [0] idle       16fps    2f  0.125s
//   [1] shoot      35fps   57f  1.629s   <- the BOLT CYCLE IS IN THE SHOT
//         f1   5001 muzzleflash 41
//         f21  5004 "weapons/boltback.wav"     frac 0.368
//         f27  6002 shell eject 2             frac 0.474
//         f43  5004 "weapons/boltforward.wav"  frac 0.754
//   [2] reload     40fps  122f  3.050s
//         f14  5004 "weapons/boltback.wav"             frac 0.115
//         f72  5004 "weapons/tommy_reload_clipin.wav"  frac 0.590
//         f98  5004 "weapons/boltforward.wav"          frac 0.803
//   [3] draw       30fps   31f  1.033s
//         f1   5004 "weapons/rifleselect.wav"          frac 0.032
//   [4] stabslash  30fps   36f  1.200s
//   [5] stab       30fps   36f  1.200s
//   [6] outofway    1fps    2f  2.000s   (not used — a DoD team-play gesture)
//
//  THE BOLT IS PART OF THE FIRING ANIMATION, which is why FIRE_DELAY is 1.55 and
//  not something snappier: boltback lands at 0.60 s and boltforward at 1.23 s
//  INSIDE the shot take, so a faster refire would cut the rifle's own cycling in
//  half and play the bolt over the next shot.  The unscoped K98 in this tree
//  (sh_wpn_dod98k.qc) has the same arrangement at 1.05 s; the scope costs the
//  extra half second, which is the trade a sniper variant should carry.
//
//  ONE SHARED SOUND WORTH KNOWING: the reload's middle event is
//  `tommy_reload_clipin.wav`, not a k98-specific sample.  That set is shared
//  across most box-fed DoD weapons and the model names it explicitly — see the
//  same note in sh_wpn_dodk43.qc.
//
//  THE FIRE SAMPLE IS THE MOUNT'S, and the note that used to sit here was wrong.
//  It said dod/sound/weapons contains no K98 shot — true as spelled (there is no
//  k98_shoot.wav and no 98k_shoot.wav) and wrong in substance: DoD names the
//  sample after the rifle's German name, weapons/kar_shoot.wav.  Both this file
//  and sh_wpn_dod98k.qc played a mod-local sounds/weapons/wpn_dod98k/fire.wav on
//  the strength of that note; both now use the mount.

// --- Ammo fields ---
.float mag_dodscoped98k;
.float ammo_dodscoped98k;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODS98K_SEQ_IDLE      = 0;
const float DODS98K_SEQ_SHOOT     = 1;
const float DODS98K_SEQ_RELOAD    = 2;
const float DODS98K_SEQ_DRAW      = 3;
const float DODS98K_SEQ_STABSLASH = 4;
const float DODS98K_SEQ_STAB      = 5;

const float DODS98K_FRAME_INTERVAL = 0.0333334;
const float DODS98K_FIRE_DELAY     = 1.55;
const float DODS98K_DRYFIRE_DELAY  = 0.20;

// Event marks as FRACTIONS of their sequence — see the header.
const float DODS98K_SHOOT_F_BOLTBACK  = 0.368;
const float DODS98K_SHOOT_F_BOLTFWD   = 0.754;
const float DODS98K_RELOAD_F_BOLTBACK = 0.115;
const float DODS98K_RELOAD_F_CLIPIN   = 0.590;
const float DODS98K_RELOAD_F_BOLTFWD  = 0.803;
const float DODS98K_DRAW_F_SELECT     = 0.032;

// The stab lands at a quarter of its take, matching the unscoped K98's
// K98_STAB_STRIKE_FRAME sitting just after the swing starts.
const float DODS98K_STAB_F_STRIKE = 0.25;
const float DODS98K_STAB_DELAY    = 0.75;
const float DODS98K_STAB_DAMAGE   = 70;
const float DODS98K_STAB_RANGE    = 88;

const float DODS98K_IDLE_REARM_MIN = 10;
const float DODS98K_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODS98K  = 5;
const float MAX_AMMO_DODS98K = 25;

// --- Balance ---
//
// The unscoped K98 in this tree is 80 close / 60 min over 4096 units.  A scoped
// sniper variant should not out-damage its own parent rifle — the scope is the
// upgrade, and it is already worth a great deal — so the damage is IDENTICAL and
// the rate of fire is the price: 1.55 s between shots against 1.05.  That keeps
// the pair honest against each other and against the AWP (which this tree gives
// a far higher close figure and a one-hit body kill; this does not).
//
// Base spread is tighter than the K98's 0.01 because the weapon is meant to be
// fired scoped and standing still; move spread is correspondingly harsher, so
// running-and-sniping is worse with this than with the iron-sighted rifle.
const float DODS98K_BASE_SPREAD          = 0.004;
const float DODS98K_MOVE_SPREAD          = 0.120;
const float DODS98K_FULL_SPREAD_SPEED    = 300;
const float DODS98K_CLOSE_DAMAGE         = 80;
const float DODS98K_MIN_DAMAGE           = 60;
const float DODS98K_DAMAGE_FALLOFF_RANGE = 4096;
const float DODS98K_KICK_PITCH    = 3.0;
const float DODS98K_KICK_VARIANCE = 0.6;
const float DODS98K_KICK_STRENGTH = 1.5;

const float DODS98K_MUZZLE_FORWARD = 52;
const float DODS98K_MUZZLE_RIGHT   = 3;
const float DODS98K_MUZZLE_DOWN    = 2;

const string DODS98K_VIEWMODEL    = "models/v_scoped98k.mdl";
const string DODS98K_WORLDMODEL   = "models/w_scoped98k.mdl";
const string DODS98K_DEPLOY_SOUND = "";
const string DODS98K_DISPLAY_NAME = "SCOPED K98";

.float dods98k_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodS98KSeqIdle   = { return SH_SeqForName(DODS98K_VIEWMODEL, "idle",   DODS98K_SEQ_IDLE); };
float() SH_DodS98KSeqShoot  = { return SH_SeqForName(DODS98K_VIEWMODEL, "shoot",  DODS98K_SEQ_SHOOT); };
float() SH_DodS98KSeqReload = { return SH_SeqForName(DODS98K_VIEWMODEL, "reload", DODS98K_SEQ_RELOAD); };
float() SH_DodS98KSeqDraw   = { return SH_SeqForName(DODS98K_VIEWMODEL, "draw",   DODS98K_SEQ_DRAW); };
float() SH_DodS98KSeqStab   = { return SH_SeqForName(DODS98K_VIEWMODEL, "stab",   DODS98K_SEQ_STAB); };

float() SH_DodS98KDrawDuration   = { return SH_SeqDuration(DODS98K_VIEWMODEL, SH_DodS98KSeqDraw(),   1.033); };
float() SH_DodS98KShootDuration  = { return SH_SeqDuration(DODS98K_VIEWMODEL, SH_DodS98KSeqShoot(),  1.629); };
float() SH_DodS98KReloadDuration = { return SH_SeqDuration(DODS98K_VIEWMODEL, SH_DodS98KSeqReload(), 3.050); };
float() SH_DodS98KStabDuration   = { return SH_SeqDuration(DODS98K_VIEWMODEL, SH_DodS98KSeqStab(),   1.200); };

// ============================================================
//  SHARED — state machine
// ============================================================

// WS_SPECIAL (the bayonet) is handled here rather than by SH_StandardTickState,
// which knows nothing about it — the same split sh_wpn_dod98k.qc uses.
float(float now) SH_DodS98KTickState =
{
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodS98KStabDuration()) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    // The clip goes in at RELOAD_F_CLIPIN, not at the end: the last third of the
    // take is the bolt going forward on a rifle that is already loaded.
    float rel = SH_DodS98KReloadDuration();
    return SH_StandardTickState(now, mag_dodscoped98k, ammo_dodscoped98k, MAX_MAG_DODS98K,
        SH_DodS98KDrawDuration(),
        SH_DodS98KShootDuration(),
        rel, rel * DODS98K_RELOAD_F_CLIPIN);
};

float(float now) SH_DodS98KTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_dodscoped98k, DODS98K_FIRE_DELAY, DODS98K_DRYFIRE_DELAY);
};

float(float now) SH_DodS98KTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_dodscoped98k, ammo_dodscoped98k, MAX_MAG_DODS98K,
        SH_DodS98KReloadDuration());
};

// Bayonet.  Deliberately NOT on +attack2 — that button is the scope on every
// sniper in this tree, and taking it away here would make this the one scoped
// rifle that cannot zoom.  It sits on WEAPON_IMPULSE_SPECIAL instead.
float(float now) SH_DodS98KTryStab =
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
    self.attack_finished = now + DODS98K_STAB_DELAY;
    return 1;
};

// Scope toggle.  Identical shape to SH_AWPTryAltFire, including the
// sv_codscopes short-circuit — in CoD mode cl_codscope.qc owns scope visuals and
// a second zoom stage fighting it produces a doubled FOV step.
float(float now) SH_DodS98KTryAltFire =
{
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    // TWO stages, not the AWP's three: the real ZF41 is a single fixed 1.5x
    // sight.  Zoomed or not, nothing in between.
    if (self.zoomstage >= 1)
        self.zoomstage = 0;
    else
        self.zoomstage = 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodS98KPickupCopy =
{
    player.mag_dodscoped98k  = self.mag_dodscoped98k;
    player.ammo_dodscoped98k = self.ammo_dodscoped98k;
};

void() W_DodS98KShoot =
{
    W_PenetratingHitscanShoot(DODS98K_BASE_SPREAD, DODS98K_MOVE_SPREAD, DODS98K_FULL_SPREAD_SPEED,
        DODS98K_CLOSE_DAMAGE, DODS98K_MIN_DAMAGE, DODS98K_DAMAGE_FALLOFF_RANGE, 48, 0.90,
        DODS98K_KICK_PITCH, DODS98K_KICK_VARIANCE, DODS98K_KICK_STRENGTH);
};

void() W_DodS98KFire =
{
    float r = SH_DodS98KTryFire(time);

    if (r == 1)
    {
        self.weaponframe        = SH_DodS98KSeqShoot();
        self.wep_nextframe      = time + DODS98K_FRAME_INTERVAL;
        self.dods98k_snd_stage  = 0;

        W_DodS98KShoot();

        sound(self, CHAN_WEAPON, "weapons/kar_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodS98KStab =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * DODS98K_STAB_RANGE;

    W_MeleeTrace(src, end);

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, DODS98K_STAB_DAMAGE, W_BoneToHitgroup(trace_bone_id));
        if (W_CanDamageTarget(trace_ent))
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hit1.wav", 1, ATTN_NORM);
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, DODS98K_STAB_DAMAGE);
            }
        }
        else
        {
            sound(self, CHAN_WEAPON, "weapons/knife_hitwall1.wav", 1, ATTN_NORM);
            PhysProp_TryPushFromTrace(v_forward, DODS98K_STAB_DAMAGE);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
        sound(self, CHAN_WEAPON, "weapons/knife_slash1.wav", 1, ATTN_NORM);
};

void() W_DodS98KSpecial =
{
    if (SH_DodS98KTryStab(time))
    {
        self.weaponframe       = SH_DodS98KSeqStab();
        self.wep_nextframe     = time + DODS98K_FRAME_INTERVAL;
        self.dods98k_snd_stage = 0;
    }
};

void() W_DodS98KAltFire =
{
    if (SH_DodS98KTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 1, ATTN_NORM);
    }
};

void() W_DodS98KReload =
{
    if (SH_DodS98KTryReload(time))
    {
        self.weaponframe       = SH_DodS98KSeqReload();
        self.wep_nextframe     = time + DODS98K_FRAME_INTERVAL;
        self.dods98k_snd_stage = 0;
    }
};

void() W_DodS98KFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODS98K_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodS98KDrawDuration() * DODS98K_DRAW_F_SELECT
            && self.dods98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float sh = SH_DodS98KShootDuration();
        if (elapsed >= sh * DODS98K_SHOOT_F_BOLTBACK && self.dods98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 1;
        }
        if (elapsed >= sh * DODS98K_SHOOT_F_BOLTFWD && self.dods98k_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_DodS98KStabDuration() * DODS98K_STAB_F_STRIKE
            && self.dods98k_snd_stage < 1)
        {
            self.dods98k_snd_stage = 1;
            W_DodS98KStab();
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodS98KReloadDuration();

        if (elapsed >= rel * DODS98K_RELOAD_F_BOLTBACK && self.dods98k_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 1;
        }
        if (elapsed >= rel * DODS98K_RELOAD_F_CLIPIN && self.dods98k_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 2;
        }
        if (elapsed >= rel * DODS98K_RELOAD_F_BOLTFWD && self.dods98k_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dods98k_snd_stage = 3;
        }
    }

    float result = SH_DodS98KTickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodS98KSeqIdle();
        self.wep_nextframe     = 0;
        self.dods98k_snd_stage = 0;
    }
};

void() W_DodS98KEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodscoped98k", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(DODS98K_VIEWMODEL, DODS98K_DISPLAY_NAME, SH_DodS98KSeqDraw(),
        DODS98K_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodS98KFire;
    self.altfire  = W_DodS98KAltFire;
    self.reload   = W_DodS98KReload;
    self.wepframe = W_DodS98KFrame;
    self.shoot    = W_DodS98KShoot;
    // THE BAYONET WAS UNREACHABLE WITHOUT THIS LINE.  W_StandardEquipSetup above
    // nulls .special (sh_weapon_standard.qc:1368) along with .altfire/.shoot, and
    // this Equip never reassigned it — so impulse 7 found no hook and
    // W_DodS98KSpecial was dead code, on the one rifle in the tree whose header
    // advertises a weapon-special.  Everything else was already in place: the
    // display frame returns the stab sequence for WS_SPECIAL and the melee is
    // deliberately server-authoritative.
    self.special  = W_DodS98KSpecial;
    self.dods98k_snd_stage = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(DODS98K_BASE_SPREAD, DODS98K_MOVE_SPREAD, DODS98K_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_DodS98KDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodscoped98k  = self.mag_dodscoped98k;
    tgt.ammo_dodscoped98k = self.ammo_dodscoped98k;

    self.mag_dodscoped98k  = 0;
    self.ammo_dodscoped98k = 0;

    setmodel(tgt, DODS98K_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_scoped98k";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODSCOPED98K;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodS98KEquip;
    tgt.weap_drop_func = W_DodS98KDrop;
    tgt.pickupcopy     = W_DodS98KPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_scoped98k =
{
    setmodel(self, DODS98K_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_scoped98k";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODSCOPED98K;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodS98KEquip;
    self.weap_drop_func = W_DodS98KDrop;
    self.pickupcopy     = W_DodS98KPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodscoped98k  = MAX_MAG_DODS98K;
    self.ammo_dodscoped98k = MAX_AMMO_DODS98K;
    W_RegisterMapWeapon(weapon_scoped98k);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dods98k_snd_stage;
float csqc_dods98k_snd_action;

void() CSQC_PredictDodS98KCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dods98k_snd_action)
    {
        csqc_dods98k_snd_action = predicted_player.wep_action_id;
        csqc_dods98k_snd_stage  = 0;
    }

    // +attack2 — the LEGACY scope toggle.  See the long note at the same arm in
    // sh_wpn_dodspring.qc: .zoomstage is client-local and never reconciled, so a
    // server-only toggle never reached the copy the renderer reads.
    if (input_buttons & 4)
    {
        if (SH_DodS98KTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (input_buttons & 1)
    {
        r = SH_DodS98KTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/kar_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODS98K_BASE_SPREAD, DODS98K_MOVE_SPREAD, DODS98K_FULL_SPREAD_SPEED,
                    DODS98K_CLOSE_DAMAGE, DODS98K_MIN_DAMAGE, DODS98K_DAMAGE_FALLOFF_RANGE, 48, 0.90,
                    DODS98K_KICK_PITCH, DODS98K_KICK_VARIANCE, DODS98K_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODS98K_MUZZLE_FORWARD, DODS98K_MUZZLE_RIGHT,
                    DODS98K_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODS98K_MUZZLE_FORWARD, DODS98K_MUZZLE_RIGHT,
                    DODS98K_MUZZLE_DOWN, self.wep_action_id, 2);
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
            if (csqc_dods98k_snd_stage < 1
                && elapsed >= SH_DodS98KDrawDuration() * DODS98K_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float sh = SH_DodS98KShootDuration();
            if (csqc_dods98k_snd_stage < 1 && elapsed >= sh * DODS98K_SHOOT_F_BOLTBACK)
            {
                localsound("weapons/boltback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 1;
            }
            if (csqc_dods98k_snd_stage < 2 && elapsed >= sh * DODS98K_SHOOT_F_BOLTFWD)
            {
                localsound("weapons/boltforward.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodS98KReloadDuration();
            if (csqc_dods98k_snd_stage < 1 && elapsed >= rel * DODS98K_RELOAD_F_BOLTBACK)
            {
                localsound("weapons/boltback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 1;
            }
            if (csqc_dods98k_snd_stage < 2 && elapsed >= rel * DODS98K_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 2;
            }
            if (csqc_dods98k_snd_stage < 3 && elapsed >= rel * DODS98K_RELOAD_F_BOLTFWD)
            {
                localsound("weapons/boltforward.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dods98k_snd_stage = 3;
            }
        }
    }

    SH_DodS98KTickState(csqc_pred_time);
};

void() CSQC_PredictDodS98KReload =
{
    if (SH_DodS98KTryReload(csqc_pred_time))
    {
        csqc_dods98k_snd_stage  = 0;
        csqc_dods98k_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// THE BAYONET IS PREDICTED NOW.  This function was an EMPTY BODY, and the note
// above it — "not predicted; a melee verdict the server owns, and mispredicting
// one is worse than showing it a round-trip late" — described a trade that was
// never actually available: the stab was not shown a round trip late, it was
// never shown at all.
//
// A weaponstate the SERVER alone sets never reaches predicted_player (reconcile
// does not write fire-decision state back, client/cl_player.qc:1022, and
// sv_confirmed_weaponstate is written and never read), so the WS_SPECIAL arm in
// CSQC_DodS98KDisplayFrame below could not fire.  On top of that nothing called
// this: CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL arm is a hand-written
// weapon list and none of the three bayonet rifles was on it.  Both are fixed.
//
// The DAMAGE verdict is still the server's — this predicts the STATE and the
// swing sound only, which is what CSQC_PredictDodK43Special does and what its
// comment at :505 was warning about when it said "a prediction function that
// nothing calls is a function that silently does nothing".
void() CSQC_PredictDodS98KSpecial =
{
    if (SH_DodS98KTryStab(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            // The same three samples W_DodS98KStab plays, in the slots that
            // actually MEAN those things — see the long note on the same call in
            // sh_wpn_dod98k.qc.  The short CSQC_PredictedMeleeTrace form treats
            // its two hit slots as random variants of one MATERIAL sample, so
            // handing it a flesh sample and a wall sample coin-flipped between
            // them on every wall hit.  Flesh belongs in the Ex form's body tail.
            CSQC_PredictedMeleeTraceEx(DODS98K_STAB_RANGE, DODS98K_STAB_DAMAGE,
                "weapons/knife_hitwall1.wav", "",
                "weapons/knife_slash1.wav",
                "weapons/knife_hit1.wav", "", "");
            // Melee form — arms the echo mute only if the trace played something.
            // See the note at the same call in sh_wpn_dod98k.qc.
            CSQC_RecordPredictedMeleeSound();
        }
    }
};

float(float elapsed) CSQC_DodS98KDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodS98KSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodS98KSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodS98KSeqShoot();
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodS98KSeqStab();

    float idle = SH_SeqIdleDisplay(cltime, WEP_DODSCOPED98K, predicted_player.weaponstate,
                                   SH_DodS98KSeqIdle(), SH_DodS98KSeqIdle(),
                                   DODS98K_IDLE_REARM_MIN, DODS98K_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;
    return SH_DodS98KSeqIdle();
};

void() CSQC_DodS98KDropClear =
{
    self.mag_dodscoped98k  = 0;
    self.ammo_dodscoped98k = 0;
};

void() CSQC_DodS98KEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodscoped98k", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = DODS98K_DISPLAY_NAME;
    self.weapon_viewmodel    = DODS98K_VIEWMODEL;
    self.weapon_worldmodel   = DODS98K_WORLDMODEL;
    self.weapon_deploy_sound = DODS98K_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodS98KCommand;
    self.csqc_predict_reload = CSQC_PredictDodS98KReload;
    self.csqc_display_frame  = CSQC_DodS98KDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodS98KDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
