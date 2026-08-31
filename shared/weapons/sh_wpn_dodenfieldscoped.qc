// ============================================================
//  shared/weapons/sh_wpn_dodenfieldscoped.qc  -  DoD scoped Lee-Enfield No.4(T)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action, telescopic sight
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : scope in / out (SCOPE_CLASS_SNIPER_BOLT)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON — models/v_enfield_scoped.mdl and
//  models/w_enfield_scoped.mdl come from the mounted dod gamedir.  The player
//  model is models/p_enfields.mdl ("enfield, scoped"), NOT p_enfield_scoped.mdl,
//  which does not exist.
//
//  MEASURED FROM dod/models/v_enfield_scoped.mdl — 5 sequences, 58 bones:
//
//   [0] idle         10fps  121f  12.100s
//   [1] shoot        35fps   59f   1.686s
//         f1   5001 muzzleflash 41
//         f14  5004 "weapons/boltback.wav"     frac 0.237
//         f28  6002 shell eject 1              frac 0.475
//         f37  5004 "weapons/boltforward.wav"  frac 0.627
//   [2] reload       35fps  125f   3.571s   <- ONE five-round charger
//         f14  5004 "weapons/boltback.wav"             frac 0.112
//         f72  5004 "weapons/tommy_reload_clipin.wav"  frac 0.576
//         f93  5004 "weapons/boltforward.wav"          frac 0.744
//   [3] draw         30fps   25f   0.833s
//         f1   5004 "weapons/rifleselect.wav"          frac 0.040
//   [4] reload_long  35fps  179f   5.114s   <- TWO chargers, note two clipins
//         f14  5004 "weapons/boltback.wav"             frac 0.078
//         f72  5004 "weapons/tommy_reload_clipin.wav"  frac 0.402
//         f126 5004 "weapons/tommy_reload_clipin.wav"  frac 0.704
//         f157 5004 "weapons/boltforward.wav"          frac 0.877
//
//  TWO RELOADS AND THE MODEL TELLS YOU WHY.  The Enfield's magazine holds ten
//  and is filled from five-round chargers, so a rifle missing five rounds or
//  fewer takes one charger (`reload`, 3.571 s, one clipin event) and one missing
//  more takes two (`reload_long`, 5.114 s, TWO clipin events at 0.402 and 0.704).
//  Picking the take off the magazine is the whole point of the pair existing.
//
//  THE MAGAZINE MUST BE PINNED FOR THE WHOLE RELOAD or the take flips mid-
//  animation.  SH_StandardTickState normally applies the rounds partway through
//  (at the clipin), which would raise the magazine above the five-round boundary
//  while `reload_long` was still playing and make the display frame jump to
//  `reload`.  So reload_apply_time is passed as reload_dur — the rounds land at
//  the END of the state and nothing the display reads changes until then.  Same
//  device, same reason, as sh_wpn_dodcolt.qc's loaded/empty pair.
//
//  Fire sample is dod/sound/weapons/enfieldsniper_shoot.wav — DoD-exclusive.

// --- Ammo fields ---
.float mag_dodenfields;
.float ammo_dodenfields;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODENFS_SEQ_IDLE        = 0;
const float DODENFS_SEQ_SHOOT       = 1;
const float DODENFS_SEQ_RELOAD      = 2;
const float DODENFS_SEQ_DRAW        = 3;
const float DODENFS_SEQ_RELOAD_LONG = 4;

const float DODENFS_FRAME_INTERVAL = 0.0333334;
const float DODENFS_FIRE_DELAY     = 1.45;
const float DODENFS_DRYFIRE_DELAY  = 0.20;

const float DODENFS_SHOOT_F_BOLTBACK  = 0.237;
const float DODENFS_SHOOT_F_BOLTFWD   = 0.627;
const float DODENFS_DRAW_F_SELECT     = 0.040;

const float DODENFS_RELOAD_F_BOLTBACK = 0.112;
const float DODENFS_RELOAD_F_CLIPIN   = 0.576;
const float DODENFS_RELOAD_F_BOLTFWD  = 0.744;

const float DODENFS_LONG_F_BOLTBACK   = 0.078;
const float DODENFS_LONG_F_CLIPIN1    = 0.402;
const float DODENFS_LONG_F_CLIPIN2    = 0.704;
const float DODENFS_LONG_F_BOLTFWD    = 0.877;

const float DODENFS_IDLE_REARM_MIN = 10;
const float DODENFS_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODENFS  = 10;
const float MAX_AMMO_DODENFS = 30;

// One charger.  The boundary between the two reload takes: missing this many or
// fewer is a single-charger top-up.
const float DODENFS_CHARGER = 5;

// --- Balance ---
//
// The .303 sits a step BELOW the two 7.92/.30-06 bolt rifles in this set (80/60)
// and gets its ten-round magazine and quicker bolt in exchange — which is what
// the Lee-Enfield actually was, and what keeps three near-identical sniper
// rifles from being three copies of one weapon:
//
//   scoped K98   80 / 60   1.55 s   5 rounds
//   Springfield  80 / 60   1.70 s   5 rounds
//   Enfield      72 / 55   1.45 s  10 rounds   <- this one
//
// 72 still two-shots an unarmoured player and still one-shots a head, so the
// drop costs nothing against soft targets and only shows up against armour and
// at the far end of the falloff.
const float DODENFS_BASE_SPREAD          = 0.004;
const float DODENFS_MOVE_SPREAD          = 0.115;
const float DODENFS_FULL_SPREAD_SPEED    = 300;
const float DODENFS_CLOSE_DAMAGE         = 72;
const float DODENFS_MIN_DAMAGE           = 55;
const float DODENFS_DAMAGE_FALLOFF_RANGE = 4096;
const float DODENFS_KICK_PITCH    = 2.8;
const float DODENFS_KICK_VARIANCE = 0.55;
const float DODENFS_KICK_STRENGTH = 1.4;

const float DODENFS_MUZZLE_FORWARD = 50;
const float DODENFS_MUZZLE_RIGHT   = 3;
const float DODENFS_MUZZLE_DOWN    = 2;

const string DODENFS_VIEWMODEL    = "models/v_enfield_scoped.mdl";
const string DODENFS_WORLDMODEL   = "models/w_enfield_scoped.mdl";
const string DODENFS_DEPLOY_SOUND = "";
const string DODENFS_DISPLAY_NAME = "SCOPED ENFIELD";

.float dodenfs_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodEnfSSeqIdle       = { return SH_SeqForName(DODENFS_VIEWMODEL, "idle",        DODENFS_SEQ_IDLE); };
float() SH_DodEnfSSeqShoot      = { return SH_SeqForName(DODENFS_VIEWMODEL, "shoot",       DODENFS_SEQ_SHOOT); };
float() SH_DodEnfSSeqDraw       = { return SH_SeqForName(DODENFS_VIEWMODEL, "draw",        DODENFS_SEQ_DRAW); };
float() SH_DodEnfSSeqReload1    = { return SH_SeqForName(DODENFS_VIEWMODEL, "reload",      DODENFS_SEQ_RELOAD); };
float() SH_DodEnfSSeqReloadLong = { return SH_SeqForName(DODENFS_VIEWMODEL, "reload_long", DODENFS_SEQ_RELOAD_LONG); };

// TRUE when this reload needs two chargers.  Read off the magazine, which the
// tick state pins for the whole WS_RELOAD (see the header).
float(float mag) SH_DodEnfSNeedsLong =
{
    return ((MAX_MAG_DODENFS - mag) > DODENFS_CHARGER);
};

float(float mag) SH_DodEnfSSeqReload =
{
    return SH_DodEnfSNeedsLong(mag) ? SH_DodEnfSSeqReloadLong() : SH_DodEnfSSeqReload1();
};

float() SH_DodEnfSDrawDuration  = { return SH_SeqDuration(DODENFS_VIEWMODEL, SH_DodEnfSSeqDraw(),  0.833); };
float() SH_DodEnfSShootDuration = { return SH_SeqDuration(DODENFS_VIEWMODEL, SH_DodEnfSSeqShoot(), 1.686); };

float(float mag) SH_DodEnfSReloadDuration =
{
    if (SH_DodEnfSNeedsLong(mag))
        return SH_SeqDuration(DODENFS_VIEWMODEL, SH_DodEnfSSeqReloadLong(), 5.114);
    return SH_SeqDuration(DODENFS_VIEWMODEL, SH_DodEnfSSeqReload1(), 3.571);
};

// ============================================================
//  SHARED — state machine
// ============================================================

// reload_apply_time == reload_dur ON PURPOSE — see the header.  Applying the
// rounds early would push the magazine past DODENFS_CHARGER mid-animation and
// the display frame would cut from reload_long to reload.
float(float now) SH_DodEnfSTickState =
{
    float rel = SH_DodEnfSReloadDuration(self.mag_dodenfields);
    return SH_StandardTickState(now, mag_dodenfields, ammo_dodenfields, MAX_MAG_DODENFS,
        SH_DodEnfSDrawDuration(),
        SH_DodEnfSShootDuration(),
        rel, rel);
};

float(float now) SH_DodEnfSTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodenfields, DODENFS_FIRE_DELAY, DODENFS_DRYFIRE_DELAY);
};

float(float now) SH_DodEnfSTryReload =
{
    return SH_StandardTryReload(now, mag_dodenfields, ammo_dodenfields, MAX_MAG_DODENFS,
        SH_DodEnfSReloadDuration(self.mag_dodenfields));
};

float(float now) SH_DodEnfSTryAltFire =
{
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    self.zoomstage = (self.zoomstage >= 1) ? 0 : 1;
    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodEnfSPickupCopy =
{
    player.mag_dodenfields  = self.mag_dodenfields;
    player.ammo_dodenfields = self.ammo_dodenfields;
};

void() W_DodEnfSShoot =
{
    W_PenetratingHitscanShoot(DODENFS_BASE_SPREAD, DODENFS_MOVE_SPREAD, DODENFS_FULL_SPREAD_SPEED,
        DODENFS_CLOSE_DAMAGE, DODENFS_MIN_DAMAGE, DODENFS_DAMAGE_FALLOFF_RANGE, 44, 0.90,
        DODENFS_KICK_PITCH, DODENFS_KICK_VARIANCE, DODENFS_KICK_STRENGTH);
};

void() W_DodEnfSFire =
{
    float r = SH_DodEnfSTryFire(time);

    if (r == 1)
    {
        self.weaponframe       = SH_DodEnfSSeqShoot();
        self.wep_nextframe     = time + DODENFS_FRAME_INTERVAL;
        self.dodenfs_snd_stage = 0;

        W_DodEnfSShoot();

        sound(self, CHAN_WEAPON, "weapons/enfieldsniper_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodEnfSAltFire =
{
    if (SH_DodEnfSTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 1, ATTN_NORM);
    }
};

void() W_DodEnfSReload =
{
    // The take is chosen from the PRE-reload magazine and then held, because the
    // rounds do not land until the state ends.
    float wants_long = SH_DodEnfSNeedsLong(self.mag_dodenfields);

    if (SH_DodEnfSTryReload(time))
    {
        self.weaponframe       = wants_long ? SH_DodEnfSSeqReloadLong() : SH_DodEnfSSeqReload1();
        self.wep_nextframe     = time + DODENFS_FRAME_INTERVAL;
        self.dodenfs_snd_stage = 0;
    }
};

void() W_DodEnfSFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODENFS_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodEnfSDrawDuration() * DODENFS_DRAW_F_SELECT
            && self.dodenfs_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodenfs_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float sh = SH_DodEnfSShootDuration();
        if (elapsed >= sh * DODENFS_SHOOT_F_BOLTBACK && self.dodenfs_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dodenfs_snd_stage = 1;
        }
        if (elapsed >= sh * DODENFS_SHOOT_F_BOLTFWD && self.dodenfs_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dodenfs_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float lng = SH_DodEnfSNeedsLong(self.mag_dodenfields);
        float rel = SH_DodEnfSReloadDuration(self.mag_dodenfields);

        if (lng)
        {
            if (elapsed >= rel * DODENFS_LONG_F_BOLTBACK && self.dodenfs_snd_stage < 1)
            { sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);            self.dodenfs_snd_stage = 1; }
            if (elapsed >= rel * DODENFS_LONG_F_CLIPIN1  && self.dodenfs_snd_stage < 2)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenfs_snd_stage = 2; }
            if (elapsed >= rel * DODENFS_LONG_F_CLIPIN2  && self.dodenfs_snd_stage < 3)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenfs_snd_stage = 3; }
            if (elapsed >= rel * DODENFS_LONG_F_BOLTFWD  && self.dodenfs_snd_stage < 4)
            { sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);         self.dodenfs_snd_stage = 4; }
        }
        else
        {
            if (elapsed >= rel * DODENFS_RELOAD_F_BOLTBACK && self.dodenfs_snd_stage < 1)
            { sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);            self.dodenfs_snd_stage = 1; }
            if (elapsed >= rel * DODENFS_RELOAD_F_CLIPIN   && self.dodenfs_snd_stage < 2)
            { sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM); self.dodenfs_snd_stage = 2; }
            if (elapsed >= rel * DODENFS_RELOAD_F_BOLTFWD  && self.dodenfs_snd_stage < 3)
            { sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);         self.dodenfs_snd_stage = 3; }
        }
    }

    float result = SH_DodEnfSTickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodEnfSSeqIdle();
        self.wep_nextframe     = 0;
        self.dodenfs_snd_stage = 0;
    }
};

void() W_DodEnfSEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodenfields", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(DODENFS_VIEWMODEL, DODENFS_DISPLAY_NAME, SH_DodEnfSSeqDraw(),
        DODENFS_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodEnfSFire;
    self.altfire  = W_DodEnfSAltFire;
    self.reload   = W_DodEnfSReload;
    self.wepframe = W_DodEnfSFrame;
    self.shoot    = W_DodEnfSShoot;
    self.dodenfs_snd_stage = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(DODENFS_BASE_SPREAD, DODENFS_MOVE_SPREAD, DODENFS_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_DodEnfSDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodenfields  = self.mag_dodenfields;
    tgt.ammo_dodenfields = self.ammo_dodenfields;

    self.mag_dodenfields  = 0;
    self.ammo_dodenfields = 0;

    setmodel(tgt, DODENFS_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_enfield_scoped";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODENFIELDS;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodEnfSEquip;
    tgt.weap_drop_func = W_DodEnfSDrop;
    tgt.pickupcopy     = W_DodEnfSPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// As with the Sten and the Webley, DoD delivers the British kit from a class
// menu and never gave it map entities, so this classname is the mod's spelling.
void() weapon_enfield_scoped =
{
    setmodel(self, DODENFS_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_enfield_scoped";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODENFIELDS;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodEnfSEquip;
    self.weap_drop_func = W_DodEnfSDrop;
    self.pickupcopy     = W_DodEnfSPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodenfields  = MAX_MAG_DODENFS;
    self.ammo_dodenfields = MAX_AMMO_DODENFS;
    W_RegisterMapWeapon(weapon_enfield_scoped);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodenfs_snd_stage;
float csqc_dodenfs_snd_action;

void() CSQC_PredictDodEnfSCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodenfs_snd_action)
    {
        csqc_dodenfs_snd_action = predicted_player.wep_action_id;
        csqc_dodenfs_snd_stage  = 0;
    }

    // +attack2 — the LEGACY scope toggle.  See the long note at the same arm in
    // sh_wpn_dodspring.qc: .zoomstage is client-local and never reconciled, so a
    // server-only toggle never reached the copy the renderer reads.
    if (input_buttons & 4)
    {
        if (SH_DodEnfSTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (input_buttons & 1)
    {
        r = SH_DodEnfSTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/enfieldsniper_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODENFS_BASE_SPREAD, DODENFS_MOVE_SPREAD, DODENFS_FULL_SPREAD_SPEED,
                    DODENFS_CLOSE_DAMAGE, DODENFS_MIN_DAMAGE, DODENFS_DAMAGE_FALLOFF_RANGE, 44, 0.90,
                    DODENFS_KICK_PITCH, DODENFS_KICK_VARIANCE, DODENFS_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODENFS_MUZZLE_FORWARD, DODENFS_MUZZLE_RIGHT,
                    DODENFS_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODENFS_MUZZLE_FORWARD, DODENFS_MUZZLE_RIGHT,
                    DODENFS_MUZZLE_DOWN, self.wep_action_id, 2);
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
            if (csqc_dodenfs_snd_stage < 1
                && elapsed >= SH_DodEnfSDrawDuration() * DODENFS_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodenfs_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float sh = SH_DodEnfSShootDuration();
            if (csqc_dodenfs_snd_stage < 1 && elapsed >= sh * DODENFS_SHOOT_F_BOLTBACK)
            { localsound("weapons/boltback.wav");    CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 1; }
            if (csqc_dodenfs_snd_stage < 2 && elapsed >= sh * DODENFS_SHOOT_F_BOLTFWD)
            { localsound("weapons/boltforward.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 2; }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float lng = SH_DodEnfSNeedsLong(self.mag_dodenfields);
            float rel = SH_DodEnfSReloadDuration(self.mag_dodenfields);

            if (lng)
            {
                if (csqc_dodenfs_snd_stage < 1 && elapsed >= rel * DODENFS_LONG_F_BOLTBACK)
                { localsound("weapons/boltback.wav");            CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 1; }
                if (csqc_dodenfs_snd_stage < 2 && elapsed >= rel * DODENFS_LONG_F_CLIPIN1)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 2; }
                if (csqc_dodenfs_snd_stage < 3 && elapsed >= rel * DODENFS_LONG_F_CLIPIN2)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 3; }
                if (csqc_dodenfs_snd_stage < 4 && elapsed >= rel * DODENFS_LONG_F_BOLTFWD)
                { localsound("weapons/boltforward.wav");         CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 4; }
            }
            else
            {
                if (csqc_dodenfs_snd_stage < 1 && elapsed >= rel * DODENFS_RELOAD_F_BOLTBACK)
                { localsound("weapons/boltback.wav");            CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 1; }
                if (csqc_dodenfs_snd_stage < 2 && elapsed >= rel * DODENFS_RELOAD_F_CLIPIN)
                { localsound("weapons/tommy_reload_clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 2; }
                if (csqc_dodenfs_snd_stage < 3 && elapsed >= rel * DODENFS_RELOAD_F_BOLTFWD)
                { localsound("weapons/boltforward.wav");         CSQC_RecordPredictedAutoSound(); csqc_dodenfs_snd_stage = 3; }
            }
        }
    }

    SH_DodEnfSTickState(csqc_pred_time);
};

void() CSQC_PredictDodEnfSReload =
{
    if (SH_DodEnfSTryReload(csqc_pred_time))
    {
        csqc_dodenfs_snd_stage  = 0;
        csqc_dodenfs_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodEnfSDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodEnfSSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        // Safe to re-derive every frame ONLY because the magazine is pinned for
        // the whole state — see the header.
        return SH_DodEnfSSeqReload(predicted_player.mag_dodenfields);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodEnfSSeqShoot();

    float idle = SH_SeqIdleDisplay(cltime, WEP_DODENFIELDS, predicted_player.weaponstate,
                                   SH_DodEnfSSeqIdle(), SH_DodEnfSSeqIdle(),
                                   DODENFS_IDLE_REARM_MIN, DODENFS_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;
    return SH_DodEnfSSeqIdle();
};

void() CSQC_DodEnfSDropClear =
{
    self.mag_dodenfields  = 0;
    self.ammo_dodenfields = 0;
};

void() CSQC_DodEnfSEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodenfields", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = DODENFS_DISPLAY_NAME;
    self.weapon_viewmodel    = DODENFS_VIEWMODEL;
    self.weapon_worldmodel   = DODENFS_WORLDMODEL;
    self.weapon_deploy_sound = DODENFS_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodEnfSCommand;
    self.csqc_predict_reload = CSQC_PredictDodEnfSReload;
    self.csqc_display_frame  = CSQC_DodEnfSDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodEnfSDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
