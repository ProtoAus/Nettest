// ============================================================
//  shared/weapons/sh_wpn_dodfcarb.qc  -  DoD M1A1 folding-stock carbine
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 15-round magazine, 45 reserve, semi-auto .30 Carbine
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : ADS (iron sights)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON — models/v_fcarb.mdl, models/w_fcarb.mdl and
//  models/p_fcarb.mdl all come from the mounted dod gamedir.
//
//  THIS IS THE PARATROOPER M1 CARBINE, the same rifle as sh_wpn_dodcarbine.qc
//  with a folding wire stock, so the ballistics are deliberately identical.  The
//  difference is stability: a folded steel stock against a wood one is worse to
//  shoot, so this one carries more move spread and more kick and nothing else
//  changes.  If the two ever feel the same in play, that is the bug.
//
//  MEASURED FROM dod/models/v_fcarb.mdl — 5 sequences, 55 bones.  Durations are
//  (frames-1)/fps; event marks are FRACTIONS of their own sequence.
//
//   [0] idle       9fps   81f  8.889s
//   [1] reload    35fps  111f  3.143s
//         f16  tommy_reload_clipout    frac 0.1454
//         f68  tommy_reload_clipin     frac 0.6182
//         f86  tommy_draw_slideback    frac 0.7817
//   [2] draw      70fps  117f  1.657s
//         f1   rifleselect             frac 0.0085
//         f48  tommy_reload_clipin     frac 0.4139
//   [3] shoot     20fps   46f  2.250s   f1 5001 flash 31, f1 6002 shell 1
//   [4] fast_draw 30fps   29f  0.933s
//
//  `fast_draw` IS NOT WIRED and that is deliberate: DoD uses it for a quick
//  swap-in, and this mod has one draw state, not two.  Using it as THE draw
//  would silently drop the second half of the deploy (the magazine slap at
//  frac 0.41 of the long take) that the model animates.
//
//  `shoot` RUNS 2.250 s, which is muzzle-climb recovery rather than one round —
//  the same arrangement as the BAR's up_shoot.  The fire STATE gets the trigger
//  delay instead, or SH_StandardTickState would park the carbine in WS_FIRE for
//  two and a quarter seconds after every shot and block the reload.

// --- Ammo fields ---
.float mag_dodfcarb;
.float ammo_dodfcarb;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODFCARB_SEQ_IDLE   = 0;
const float DODFCARB_SEQ_RELOAD = 1;
const float DODFCARB_SEQ_DRAW   = 2;
const float DODFCARB_SEQ_SHOOT  = 3;

const float DODFCARB_FRAME_INTERVAL = 0.0333334;
const float DODFCARB_FIRE_DELAY     = 0.15;
const float DODFCARB_DRYFIRE_DELAY  = 0.20;

const float DODFCARB_DRAW_F_SELECT    = 0.0085;
const float DODFCARB_DRAW_F_CLIPIN    = 0.4139;
const float DODFCARB_RELOAD_F_CLIPOUT = 0.1454;
const float DODFCARB_RELOAD_F_CLIPIN  = 0.6182;
const float DODFCARB_RELOAD_F_BOLT    = 0.7817;
const float DODFCARB_RELOAD_F_APPLY   = 0.6500;   // just after the mag seats

const float DODFCARB_IDLE_REARM_MIN = 10;
const float DODFCARB_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODFCARB  = 15;
const float MAX_AMMO_DODFCARB = 45;

// --- Balance --- (see the header: identical to the M1 carbine but less stable)
const float DODFCARB_BASE_SPREAD          = 0.010;
const float DODFCARB_MOVE_SPREAD          = 0.082;
const float DODFCARB_FULL_SPREAD_SPEED    = 320;
const float DODFCARB_CLOSE_DAMAGE         = 34;
const float DODFCARB_MIN_DAMAGE           = 22;
const float DODFCARB_DAMAGE_FALLOFF_RANGE = 2600;
const float DODFCARB_KICK_PITCH    = 1.25;
const float DODFCARB_KICK_VARIANCE = 0.42;
const float DODFCARB_KICK_STRENGTH = 1.10;

const float DODFCARB_MUZZLE_FORWARD = 40;
const float DODFCARB_MUZZLE_RIGHT   = 3;
const float DODFCARB_MUZZLE_DOWN    = 2.5;

const string DODFCARB_VIEWMODEL    = "models/v_fcarb.mdl";
const string DODFCARB_WORLDMODEL   = "models/w_fcarb.mdl";
const string DODFCARB_DEPLOY_SOUND = "";
const string DODFCARB_DISPLAY_NAME = "M1A1 CARBINE";

.float dodfcarb_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodFCarbSeqIdle   = { return SH_SeqForName(DODFCARB_VIEWMODEL, "idle",   DODFCARB_SEQ_IDLE); };
float() SH_DodFCarbSeqReload = { return SH_SeqForName(DODFCARB_VIEWMODEL, "reload", DODFCARB_SEQ_RELOAD); };
float() SH_DodFCarbSeqDraw   = { return SH_SeqForName(DODFCARB_VIEWMODEL, "draw",   DODFCARB_SEQ_DRAW); };
float() SH_DodFCarbSeqShoot  = { return SH_SeqForName(DODFCARB_VIEWMODEL, "shoot",  DODFCARB_SEQ_SHOOT); };

float() SH_DodFCarbDrawDuration   = { return SH_SeqDuration(DODFCARB_VIEWMODEL, SH_DodFCarbSeqDraw(),   1.657); };
float() SH_DodFCarbReloadDuration = { return SH_SeqDuration(DODFCARB_VIEWMODEL, SH_DodFCarbSeqReload(), 3.143); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_DodFCarbTickState =
{
    float rel = SH_DodFCarbReloadDuration();
    return SH_StandardTickState(now, mag_dodfcarb, ammo_dodfcarb, MAX_MAG_DODFCARB,
        SH_DodFCarbDrawDuration(),
        DODFCARB_FIRE_DELAY,
        rel, rel * DODFCARB_RELOAD_F_APPLY);
};

float(float now) SH_DodFCarbTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodfcarb, DODFCARB_FIRE_DELAY, DODFCARB_DRYFIRE_DELAY);
};

float(float now) SH_DodFCarbTryReload =
{
    return SH_StandardTryReload(now, mag_dodfcarb, ammo_dodfcarb, MAX_MAG_DODFCARB,
        SH_DodFCarbReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodFCarbPickupCopy =
{
    player.mag_dodfcarb  = self.mag_dodfcarb;
    player.ammo_dodfcarb = self.ammo_dodfcarb;
};

void() W_DodFCarbShoot =
{
    W_PenetratingHitscanShoot(DODFCARB_BASE_SPREAD, DODFCARB_MOVE_SPREAD, DODFCARB_FULL_SPREAD_SPEED,
        DODFCARB_CLOSE_DAMAGE, DODFCARB_MIN_DAMAGE, DODFCARB_DAMAGE_FALLOFF_RANGE, 40, 0.96,
        DODFCARB_KICK_PITCH, DODFCARB_KICK_VARIANCE, DODFCARB_KICK_STRENGTH);
};

void() W_DodFCarbFire =
{
    float r = SH_DodFCarbTryFire(time);

    if (r == 1)
    {
        self.weaponframe        = SH_DodFCarbSeqShoot();
        self.wep_nextframe      = time + DODFCARB_FRAME_INTERVAL;
        self.dodfcarb_snd_stage = 0;

        W_DodFCarbShoot();

        sound(self, CHAN_WEAPON, "weapons/carbine_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodFCarbReload =
{
    if (SH_DodFCarbTryReload(time))
    {
        self.weaponframe        = SH_DodFCarbSeqReload();
        self.wep_nextframe      = time + DODFCARB_FRAME_INTERVAL;
        self.dodfcarb_snd_stage = 0;
    }
};

void() W_DodFCarbFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODFCARB_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        float dr = SH_DodFCarbDrawDuration();
        if (elapsed >= dr * DODFCARB_DRAW_F_SELECT && self.dodfcarb_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodfcarb_snd_stage = 1;
        }
        if (elapsed >= dr * DODFCARB_DRAW_F_CLIPIN && self.dodfcarb_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodfcarb_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodFCarbReloadDuration();

        if (elapsed >= rel * DODFCARB_RELOAD_F_CLIPOUT && self.dodfcarb_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodfcarb_snd_stage = 1;
        }
        if (elapsed >= rel * DODFCARB_RELOAD_F_CLIPIN && self.dodfcarb_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodfcarb_snd_stage = 2;
        }
        if (elapsed >= rel * DODFCARB_RELOAD_F_BOLT && self.dodfcarb_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodfcarb_snd_stage = 3;
        }
    }

    float result = SH_DodFCarbTickState(time);
    if (result & 1)
    {
        self.weaponframe        = SH_DodFCarbSeqIdle();
        self.wep_nextframe      = 0;
        self.dodfcarb_snd_stage = 0;
    }
};

void() W_DodFCarbEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodfcarb", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODFCARB_VIEWMODEL, DODFCARB_DISPLAY_NAME, SH_DodFCarbSeqDraw(),
        DODFCARB_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodFCarbFire;
    self.reload   = W_DodFCarbReload;
    self.wepframe = W_DodFCarbFrame;
    self.shoot    = W_DodFCarbShoot;
    self.dodfcarb_snd_stage = 0;
    W_SetCrosshairProfile(DODFCARB_BASE_SPREAD, DODFCARB_MOVE_SPREAD, DODFCARB_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_DodFCarbDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodfcarb  = self.mag_dodfcarb;
    tgt.ammo_dodfcarb = self.ammo_dodfcarb;

    self.mag_dodfcarb  = 0;
    self.ammo_dodfcarb = 0;

    setmodel(tgt, DODFCARB_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_fcarb";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODFCARB;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodFCarbEquip;
    tgt.weap_drop_func = W_DodFCarbDrop;
    tgt.pickupcopy     = W_DodFCarbPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_fcarb =
{
    setmodel(self, DODFCARB_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_fcarb";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODFCARB;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodFCarbEquip;
    self.weap_drop_func = W_DodFCarbDrop;
    self.pickupcopy     = W_DodFCarbPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodfcarb   = MAX_MAG_DODFCARB;
    self.ammo_dodfcarb  = MAX_AMMO_DODFCARB;
    W_RegisterMapWeapon(weapon_fcarb);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodfcarb_snd_stage;
float csqc_dodfcarb_snd_action;

void() CSQC_PredictDodFCarbCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodfcarb_snd_action)
    {
        csqc_dodfcarb_snd_action = predicted_player.wep_action_id;
        csqc_dodfcarb_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodFCarbTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/carbine_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODFCARB_BASE_SPREAD, DODFCARB_MOVE_SPREAD, DODFCARB_FULL_SPREAD_SPEED,
                    DODFCARB_CLOSE_DAMAGE, DODFCARB_MIN_DAMAGE, DODFCARB_DAMAGE_FALLOFF_RANGE, 40, 0.96,
                    DODFCARB_KICK_PITCH, DODFCARB_KICK_VARIANCE, DODFCARB_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODFCARB_MUZZLE_FORWARD, DODFCARB_MUZZLE_RIGHT,
                    DODFCARB_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODFCARB_MUZZLE_FORWARD, DODFCARB_MUZZLE_RIGHT,
                    DODFCARB_MUZZLE_DOWN, self.wep_action_id, 2);
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
            float dr = SH_DodFCarbDrawDuration();
            if (csqc_dodfcarb_snd_stage < 1 && elapsed >= dr * DODFCARB_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodfcarb_snd_stage = 1;
            }
            if (csqc_dodfcarb_snd_stage < 2 && elapsed >= dr * DODFCARB_DRAW_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodfcarb_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodFCarbReloadDuration();

            if (csqc_dodfcarb_snd_stage < 1 && elapsed >= rel * DODFCARB_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodfcarb_snd_stage = 1;
            }
            if (csqc_dodfcarb_snd_stage < 2 && elapsed >= rel * DODFCARB_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodfcarb_snd_stage = 2;
            }
            if (csqc_dodfcarb_snd_stage < 3 && elapsed >= rel * DODFCARB_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodfcarb_snd_stage = 3;
            }
        }
    }

    SH_DodFCarbTickState(csqc_pred_time);
};

void() CSQC_PredictDodFCarbReload =
{
    if (SH_DodFCarbTryReload(csqc_pred_time))
    {
        csqc_dodfcarb_snd_stage  = 0;
        csqc_dodfcarb_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodFCarbDisplayFrame =
{
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODFCARB, predicted_player.weaponstate,
                                   SH_DodFCarbSeqIdle(), SH_DodFCarbSeqIdle(),
                                   DODFCARB_IDLE_REARM_MIN, DODFCARB_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodFCarbSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodFCarbSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodFCarbSeqShoot();

    return SH_DodFCarbSeqIdle();
};

void() CSQC_DodFCarbDropClear =
{
    self.mag_dodfcarb  = 0;
    self.ammo_dodfcarb = 0;
};

void() CSQC_DodFCarbEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodfcarb", SCOPE_CLASS_NONE);
    self.weapon_name         = DODFCARB_DISPLAY_NAME;
    self.weapon_viewmodel    = DODFCARB_VIEWMODEL;
    self.weapon_worldmodel   = DODFCARB_WORLDMODEL;
    self.weapon_deploy_sound = DODFCARB_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodFCarbCommand;
    self.csqc_predict_reload = CSQC_PredictDodFCarbReload;
    self.csqc_display_frame  = CSQC_DodFCarbDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodFCarbDropClear;
    self.weapon_uses_sequences = TRUE;
    // No csqc_dodfcarb_snd_stage reset here — CSQC_WeaponEquip re-runs on every
    // reconcile (client/cl_player.qc:1051), so it would replay every passed event.
};

#endif // CSQC
