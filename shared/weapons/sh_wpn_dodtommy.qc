// ============================================================
//  shared/weapons/sh_wpn_dodtommy.qc  -  Day of Defeat Thompson M1A1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto .45 ACP
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_tommy.mdl, models/w_tommy.mdl,
// models/p_tommy.mdl come from the mounted dod gamedir.
//
// NOT the same weapon as sh_wpn_thtommygun.qc.  They Hunger ships its own
// Thompson with its own model set and its own AngelScript-derived numbers; that
// one keeps the "tommygun" manifest key.  This one answers to "thompson" and to
// Day of Defeat's own classname, weapon_thompson.
//
// MEASURED FROM dod/models/v_tommy.mdl:
//   [0] idle       12fps  121f  10.000s
//   [1] reload     45fps  126f   2.778s
//         f24  5004 "weapons/tommy_reload_clipout.wav"  frac 0.1920
//         f100 5004 "weapons/tommy_reload_clipin.wav"   frac 0.8000
//   [2] draw       45fps   51f   1.111s   f1 5004 "weapons/rifleselect.wav"
//   [3] shoot1     25fps   31f   1.200s   f1 5001 (flash) f1 6002 (shell)
//   [4] shoot2     30fps   31f   1.000s   f1 5001, f1 6002
//   [5] empty_idle 30fps    2f   0.033s
//
// The fire sound is weapons/thompson_shoot.wav, NOT weapons/tommy_*.wav -- the
// tommy_ prefix in this model belongs to the three magazine sounds that DoD
// shares across most of its box-fed weapons, which is a naming trap worth
// knowing about before adding the rest of the set.

// --- Ammo fields ---
.float mag_dodtommy;
.float ammo_dodtommy;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODTOMMY_SEQ_IDLE   = 0;
const float DODTOMMY_SEQ_RELOAD = 1;
const float DODTOMMY_SEQ_DRAW   = 2;
const float DODTOMMY_SEQ_SHOOT1 = 3;
const float DODTOMMY_SEQ_SHOOT2 = 4;

const float DODTOMMY_FRAME_INTERVAL = 0.0333334;
const float DODTOMMY_FIRE_DELAY     = 0.086;   // ~700 rpm, the M1A1's real rate
const float DODTOMMY_DRYFIRE_DELAY  = 0.20;

const float DODTOMMY_DRAW_F_SELECT    = 0.0200;   // frame 1   / 50
const float DODTOMMY_RELOAD_F_CLIPOUT = 0.1920;   // frame 24  / 125
const float DODTOMMY_RELOAD_F_CLIPIN  = 0.8000;   // frame 100 / 125
const float DODTOMMY_RELOAD_F_APPLY   = 0.8200;   // just after the mag seats

const float DODTOMMY_IDLE_REARM_MIN = 10;
const float DODTOMMY_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODTOMMY  = 30;
const float MAX_AMMO_DODTOMMY = 90;

// --- Balance ---
//
// The .45 SMG bracket in this tree is the CS MAC-10 at 13/7 over 1800 and the
// UMP45 above it.  The Thompson is a much heavier gun firing the same round
// from a longer barrel with a wooden stock to hold it down, so it gets 26/14 --
// roughly double the MAC-10 and the top of the SMG bracket -- and pays for it
// with the slowest carry speed of the four DoD SMGs (0.96 in the manifest, and
// 8 lbs of it), the widest standing cone of the .45 pair, and a price above
// them all.  Against the DoD rifles it is still less than half a Garand hit.
const float DODTOMMY_BASE_SPREAD          = 0.013;
const float DODTOMMY_MOVE_SPREAD          = 0.075;
const float DODTOMMY_FULL_SPREAD_SPEED    = 320;
const float DODTOMMY_CLOSE_DAMAGE         = 26;
const float DODTOMMY_MIN_DAMAGE           = 14;
const float DODTOMMY_DAMAGE_FALLOFF_RANGE = 1800;
const float DODTOMMY_KICK_PITCH    = 0.75;   // heavy gun, heavy round: the
const float DODTOMMY_KICK_VARIANCE = 0.35;   // climb is steady rather than
const float DODTOMMY_KICK_STRENGTH = 1.10;   // violent, which is the point

const float DODTOMMY_MUZZLE_FORWARD = 36;
const float DODTOMMY_MUZZLE_RIGHT   = 4;
const float DODTOMMY_MUZZLE_DOWN    = 4;

const string DODTOMMY_VIEWMODEL    = "models/v_tommy.mdl";
const string DODTOMMY_WORLDMODEL   = "models/w_tommy.mdl";
const string DODTOMMY_DEPLOY_SOUND = "";
const string DODTOMMY_DISPLAY_NAME = "Thompson";

.float dodtommy_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodTommySeqIdle   = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "idle",   DODTOMMY_SEQ_IDLE); };
// The bolt-open rest pose the model carries and nothing was asking for — see the
// note in sh_wpn_dodmp40.qc; eight DoD weapons shared this gap.
const float DODTOMMY_SEQ_EMPTY_IDLE = 5;
float() SH_DodTommySeqEmptyIdle = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "empty_idle", DODTOMMY_SEQ_EMPTY_IDLE); };
float() SH_DodTommySeqReload = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "reload", DODTOMMY_SEQ_RELOAD); };
float() SH_DodTommySeqDraw   = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "draw",   DODTOMMY_SEQ_DRAW); };
float() SH_DodTommySeqShoot1 = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "shoot1", DODTOMMY_SEQ_SHOOT1); };
float() SH_DodTommySeqShoot2 = { return SH_SeqForName(DODTOMMY_VIEWMODEL, "shoot2", DODTOMMY_SEQ_SHOOT2); };

float(float action_id) SH_DodTommyPickShootSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodTommySeqShoot1() : SH_DodTommySeqShoot2();
};

float() SH_DodTommyDrawDuration   = { return SH_SeqDuration(DODTOMMY_VIEWMODEL, SH_DodTommySeqDraw(),   1.111); };
float() SH_DodTommyReloadDuration = { return SH_SeqDuration(DODTOMMY_VIEWMODEL, SH_DodTommySeqReload(), 2.778); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodTommyTickState =
{
    float rel = SH_DodTommyReloadDuration();
    return SH_StandardTickState(now, mag_dodtommy, ammo_dodtommy, MAX_MAG_DODTOMMY,
        SH_DodTommyDrawDuration(),
        SH_SeqDuration(DODTOMMY_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODTOMMY_RELOAD_F_APPLY);
};

// Full-auto: SH_StandardTryFire, not the SemiAuto wrapper.
float(float now) SH_DodTommyTryFire =
{
    return SH_StandardTryFire(now, mag_dodtommy, DODTOMMY_FIRE_DELAY, DODTOMMY_DRYFIRE_DELAY);
};

float(float now) SH_DodTommyTryReload =
{
    return SH_StandardTryReload(now, mag_dodtommy, ammo_dodtommy, MAX_MAG_DODTOMMY,
        SH_DodTommyReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodTommyPickupCopy =
{
    player.mag_dodtommy  = self.mag_dodtommy;
    player.ammo_dodtommy = self.ammo_dodtommy;
};

void() W_DodTommyShoot =
{
    W_PenetratingHitscanShoot(DODTOMMY_BASE_SPREAD, DODTOMMY_MOVE_SPREAD, DODTOMMY_FULL_SPREAD_SPEED,
        DODTOMMY_CLOSE_DAMAGE, DODTOMMY_MIN_DAMAGE, DODTOMMY_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        DODTOMMY_KICK_PITCH, DODTOMMY_KICK_VARIANCE, DODTOMMY_KICK_STRENGTH);
};

void() W_DodTommyFire =
{
    float r = SH_DodTommyTryFire(time);

    if (r == 1)
    {
        self.weaponframe        = SH_DodTommyPickShootSeq(self.wep_action_id);
        self.wep_nextframe      = time + DODTOMMY_FRAME_INTERVAL;
        self.dodtommy_snd_stage = 0;

        W_DodTommyShoot();

        sound(self, CHAN_WEAPON, "weapons/thompson_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodTommyReload =
{
    if (SH_DodTommyTryReload(time))
    {
        self.weaponframe        = SH_DodTommySeqReload();
        self.wep_nextframe      = time + DODTOMMY_FRAME_INTERVAL;
        self.dodtommy_snd_stage = 0;
    }
};

void() W_DodTommyFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODTOMMY_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodTommyDrawDuration() * DODTOMMY_DRAW_F_SELECT
            && self.dodtommy_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodtommy_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodTommyReloadDuration();

        if (elapsed >= rel * DODTOMMY_RELOAD_F_CLIPOUT && self.dodtommy_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodtommy_snd_stage = 1;
        }
        if (elapsed >= rel * DODTOMMY_RELOAD_F_CLIPIN && self.dodtommy_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodtommy_snd_stage = 2;
        }
    }

    result = SH_DodTommyTickState(time);
    if (result & 1)
    {
        self.weaponframe        = SH_DodTommySeqIdle();
        self.wep_nextframe      = 0;
        self.dodtommy_snd_stage = 0;
    }
};

void() W_DodTommyEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodtommy", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODTOMMY_VIEWMODEL, DODTOMMY_DISPLAY_NAME, SH_DodTommySeqDraw(),
        DODTOMMY_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodTommyFire;
    self.reload   = W_DodTommyReload;
    self.wepframe = W_DodTommyFrame;
    self.shoot    = W_DodTommyShoot;
    self.dodtommy_snd_stage = 0;
    W_SetCrosshairProfile(DODTOMMY_BASE_SPREAD, DODTOMMY_MOVE_SPREAD, DODTOMMY_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_DodTommyDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodtommy  = self.mag_dodtommy;
    tgt.ammo_dodtommy = self.ammo_dodtommy;

    self.mag_dodtommy  = 0;
    self.ammo_dodtommy = 0;

    setmodel(tgt, DODTOMMY_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_thompson";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODTOMMY;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodTommyEquip;
    tgt.weap_drop_func = W_DodTommyDrop;
    tgt.pickupcopy     = W_DodTommyPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thompson =
{
    setmodel(self, DODTOMMY_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_thompson";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODTOMMY;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodTommyEquip;
    self.weap_drop_func = W_DodTommyDrop;
    self.pickupcopy     = W_DodTommyPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodtommy   = MAX_MAG_DODTOMMY;
    self.ammo_dodtommy  = MAX_AMMO_DODTOMMY;
    W_RegisterMapWeapon(weapon_thompson);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodtommy_snd_stage;
float csqc_dodtommy_snd_action;

void() CSQC_PredictDodTommyCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodtommy_snd_action)
    {
        csqc_dodtommy_snd_action = predicted_player.wep_action_id;
        csqc_dodtommy_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodTommyTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/thompson_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODTOMMY_BASE_SPREAD, DODTOMMY_MOVE_SPREAD, DODTOMMY_FULL_SPREAD_SPEED,
                    DODTOMMY_CLOSE_DAMAGE, DODTOMMY_MIN_DAMAGE, DODTOMMY_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    DODTOMMY_KICK_PITCH, DODTOMMY_KICK_VARIANCE, DODTOMMY_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODTOMMY_MUZZLE_FORWARD, DODTOMMY_MUZZLE_RIGHT,
                    DODTOMMY_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODTOMMY_MUZZLE_FORWARD, DODTOMMY_MUZZLE_RIGHT,
                    DODTOMMY_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_dodtommy_snd_stage < 1
                && elapsed >= SH_DodTommyDrawDuration() * DODTOMMY_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodtommy_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodTommyReloadDuration();

            if (csqc_dodtommy_snd_stage < 1 && elapsed >= rel * DODTOMMY_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodtommy_snd_stage = 1;
            }
            if (csqc_dodtommy_snd_stage < 2 && elapsed >= rel * DODTOMMY_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodtommy_snd_stage = 2;
            }
        }
    }

    SH_DodTommyTickState(csqc_pred_time);
};

void() CSQC_PredictDodTommyReload =
{
    if (SH_DodTommyTryReload(csqc_pred_time))
    {
        csqc_dodtommy_snd_stage  = 0;
        csqc_dodtommy_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodTommyDisplayFrame =
{
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodtommy <= 0)
              ? SH_DodTommySeqEmptyIdle() : SH_DodTommySeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODTOMMY, predicted_player.weaponstate,
                                   e, e,
                                   DODTOMMY_IDLE_REARM_MIN, DODTOMMY_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodTommySeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodTommySeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodTommyPickShootSeq(predicted_player.wep_action_id);

    return e;
};

void() CSQC_DodTommyDropClear =
{
    self.mag_dodtommy  = 0;
    self.ammo_dodtommy = 0;
};

void() CSQC_DodTommyEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodtommy", SCOPE_CLASS_NONE);
    self.weapon_name         = DODTOMMY_DISPLAY_NAME;
    self.weapon_viewmodel    = DODTOMMY_VIEWMODEL;
    self.weapon_worldmodel   = DODTOMMY_WORLDMODEL;
    self.weapon_deploy_sound = DODTOMMY_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodTommyCommand;
    self.csqc_predict_reload = CSQC_PredictDodTommyReload;
    self.csqc_display_frame  = CSQC_DodTommyDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodTommyDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
