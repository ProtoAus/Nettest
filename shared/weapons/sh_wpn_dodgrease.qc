// ============================================================
//  shared/weapons/sh_wpn_dodgrease.qc  -  Day of Defeat M3 "Grease Gun"
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto .45 ACP
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_greasegun.mdl,
// models/w_greasegun.mdl, models/p_grease.mdl come from the mounted dod gamedir.
//
// SPAWNS AS weapon_dodgreasegun, NOT weapon_greasegun.  They Hunger's M3 --
// sh_wpn_thgreasegun.qc, ported from svencoop's weapon_greasegun.as -- already
// owns that classname and the bare "greasegun" manifest key.  It is the same
// real gun from a different game with different numbers, exactly the
// relationship the CS/CrossFire pairs elsewhere in this tree have, and it is
// resolved the same way: this one answers to "dodgreasegun".
//
// MEASURED FROM dod/models/v_greasegun.mdl:
//   [0] idle       12fps  121f  10.000s
//   [1] reload     30fps  123f   4.067s
//         f13  5004 "weapons/tommy_reload_clipout.wav"  frac 0.1066
//         f81  5004 "weapons/tommy_reload_clipin.wav"   frac 0.6639
//         f101 5004 "weapons/tommy_draw_slideback.wav"  frac 0.8279
//   [2] draw       35fps   56f   1.571s
//         f1  5004 "weapons/rifleselect.wav"            frac 0.0182
//         f21 5004 "weapons/tommy_reload_clipin.wav"    frac 0.3750
//         f38 5004 "weapons/tommy_reload_clipin.wav"    frac 0.6786
//   [3] shoot1     25fps   33f   1.280s   f1 5001 (flash) f1 6002 (shell)
//   [4] shoot2     30fps   33f   1.067s   f1 5001, f1 6002
//   [5] empty_idle 30fps    2f   0.033s
//   [6] fast_draw  55fps   56f   1.000s   f1 5004 "weapons/rifleselect.wav"
//
// fast_draw IS NOT USED and that is deliberate: Day of Defeat plays it when the
// gun is re-selected within a short window, a concept this mod's weapon state
// machine does not have.  Wiring it to nothing rather than to something
// approximate keeps the draw honest.  It is listed here so the next person does
// not conclude the sequence was missed.

// --- Ammo fields ---
.float mag_dodgrease;
.float ammo_dodgrease;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODGREASE_SEQ_IDLE   = 0;
const float DODGREASE_SEQ_RELOAD = 1;
const float DODGREASE_SEQ_DRAW   = 2;
const float DODGREASE_SEQ_SHOOT1 = 3;
const float DODGREASE_SEQ_SHOOT2 = 4;

const float DODGREASE_FRAME_INTERVAL = 0.0333334;
const float DODGREASE_FIRE_DELAY     = 0.133;   // ~450 rpm — the slowest SMG here
const float DODGREASE_DRYFIRE_DELAY  = 0.20;

const float DODGREASE_DRAW_F_SELECT    = 0.0182;   // frame 1   / 55
const float DODGREASE_DRAW_F_CLIP1     = 0.3750;   // frame 21  / 55
const float DODGREASE_DRAW_F_CLIP2     = 0.6786;   // frame 38  / 55
const float DODGREASE_RELOAD_F_CLIPOUT = 0.1066;   // frame 13  / 122
const float DODGREASE_RELOAD_F_CLIPIN  = 0.6639;   // frame 81  / 122
const float DODGREASE_RELOAD_F_BOLT    = 0.8279;   // frame 101 / 122
const float DODGREASE_RELOAD_F_APPLY   = 0.6900;   // just after the mag seats

const float DODGREASE_IDLE_REARM_MIN = 10;
const float DODGREASE_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODGREASE  = 30;
const float MAX_AMMO_DODGREASE = 90;

// --- Balance ---
//
// The other .45 SMG, and the pairing with the Thompson is the point: same
// cartridge, same magazine, so nearly the same per-hit damage (27/15 against
// 26/14 -- a point up, because the M3's slower bolt lets it be) at two thirds
// the rate of fire.  450 rpm is the M3's real cyclic rate and the reason it was
// famously easy to shoot; the standing cone is the tightest of the four DoD
// SMGs to say so.  It is cheaper than the Thompson and strictly worse in a
// close-range trade, which is the correct relationship between the two.
const float DODGREASE_BASE_SPREAD          = 0.010;
const float DODGREASE_MOVE_SPREAD          = 0.068;
const float DODGREASE_FULL_SPREAD_SPEED    = 320;
const float DODGREASE_CLOSE_DAMAGE         = 27;
const float DODGREASE_MIN_DAMAGE           = 15;
const float DODGREASE_DAMAGE_FALLOFF_RANGE = 1800;
const float DODGREASE_KICK_PITCH    = 0.65;
const float DODGREASE_KICK_VARIANCE = 0.30;
const float DODGREASE_KICK_STRENGTH = 1.05;

const float DODGREASE_MUZZLE_FORWARD = 34;
const float DODGREASE_MUZZLE_RIGHT   = 4;
const float DODGREASE_MUZZLE_DOWN    = 4;

const string DODGREASE_VIEWMODEL    = "models/v_greasegun.mdl";
const string DODGREASE_WORLDMODEL   = "models/w_greasegun.mdl";
const string DODGREASE_DEPLOY_SOUND = "";
const string DODGREASE_DISPLAY_NAME = "M3 Grease Gun";

.float dodgrease_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodGreaseSeqIdle   = { return SH_SeqForName(DODGREASE_VIEWMODEL, "idle",   DODGREASE_SEQ_IDLE); };
// The bolt-open rest pose the model carries and nothing was asking for — see the
// note in sh_wpn_dodmp40.qc; eight DoD weapons shared this gap.
const float DODGREASE_SEQ_EMPTY_IDLE = 5;
float() SH_DodGreaseSeqEmptyIdle = { return SH_SeqForName(DODGREASE_VIEWMODEL, "empty_idle", DODGREASE_SEQ_EMPTY_IDLE); };
float() SH_DodGreaseSeqReload = { return SH_SeqForName(DODGREASE_VIEWMODEL, "reload", DODGREASE_SEQ_RELOAD); };
float() SH_DodGreaseSeqDraw   = { return SH_SeqForName(DODGREASE_VIEWMODEL, "draw",   DODGREASE_SEQ_DRAW); };
float() SH_DodGreaseSeqShoot1 = { return SH_SeqForName(DODGREASE_VIEWMODEL, "shoot1", DODGREASE_SEQ_SHOOT1); };
float() SH_DodGreaseSeqShoot2 = { return SH_SeqForName(DODGREASE_VIEWMODEL, "shoot2", DODGREASE_SEQ_SHOOT2); };

float(float action_id) SH_DodGreasePickShootSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodGreaseSeqShoot1() : SH_DodGreaseSeqShoot2();
};

float() SH_DodGreaseDrawDuration   = { return SH_SeqDuration(DODGREASE_VIEWMODEL, SH_DodGreaseSeqDraw(),   1.571); };
float() SH_DodGreaseReloadDuration = { return SH_SeqDuration(DODGREASE_VIEWMODEL, SH_DodGreaseSeqReload(), 4.067); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodGreaseTickState =
{
    float rel = SH_DodGreaseReloadDuration();
    return SH_StandardTickState(now, mag_dodgrease, ammo_dodgrease, MAX_MAG_DODGREASE,
        SH_DodGreaseDrawDuration(),
        SH_SeqDuration(DODGREASE_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODGREASE_RELOAD_F_APPLY);
};

float(float now) SH_DodGreaseTryFire =
{
    return SH_StandardTryFire(now, mag_dodgrease, DODGREASE_FIRE_DELAY, DODGREASE_DRYFIRE_DELAY);
};

float(float now) SH_DodGreaseTryReload =
{
    return SH_StandardTryReload(now, mag_dodgrease, ammo_dodgrease, MAX_MAG_DODGREASE,
        SH_DodGreaseReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodGreasePickupCopy =
{
    player.mag_dodgrease  = self.mag_dodgrease;
    player.ammo_dodgrease = self.ammo_dodgrease;
};

void() W_DodGreaseShoot =
{
    W_PenetratingHitscanShoot(DODGREASE_BASE_SPREAD, DODGREASE_MOVE_SPREAD, DODGREASE_FULL_SPREAD_SPEED,
        DODGREASE_CLOSE_DAMAGE, DODGREASE_MIN_DAMAGE, DODGREASE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        DODGREASE_KICK_PITCH, DODGREASE_KICK_VARIANCE, DODGREASE_KICK_STRENGTH);
};

void() W_DodGreaseFire =
{
    float r = SH_DodGreaseTryFire(time);

    if (r == 1)
    {
        self.weaponframe         = SH_DodGreasePickShootSeq(self.wep_action_id);
        self.wep_nextframe       = time + DODGREASE_FRAME_INTERVAL;
        self.dodgrease_snd_stage = 0;

        W_DodGreaseShoot();

        sound(self, CHAN_WEAPON, "weapons/greasegun_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodGreaseReload =
{
    if (SH_DodGreaseTryReload(time))
    {
        self.weaponframe         = SH_DodGreaseSeqReload();
        self.wep_nextframe       = time + DODGREASE_FRAME_INTERVAL;
        self.dodgrease_snd_stage = 0;
    }
};

void() W_DodGreaseFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODGREASE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        float dr = SH_DodGreaseDrawDuration();
        if (elapsed >= dr * DODGREASE_DRAW_F_SELECT && self.dodgrease_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodgrease_snd_stage = 1;
        }
        if (elapsed >= dr * DODGREASE_DRAW_F_CLIP1 && self.dodgrease_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodgrease_snd_stage = 2;
        }
        if (elapsed >= dr * DODGREASE_DRAW_F_CLIP2 && self.dodgrease_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodgrease_snd_stage = 3;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodGreaseReloadDuration();

        if (elapsed >= rel * DODGREASE_RELOAD_F_CLIPOUT && self.dodgrease_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodgrease_snd_stage = 1;
        }
        if (elapsed >= rel * DODGREASE_RELOAD_F_CLIPIN && self.dodgrease_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodgrease_snd_stage = 2;
        }
        if (elapsed >= rel * DODGREASE_RELOAD_F_BOLT && self.dodgrease_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodgrease_snd_stage = 3;
        }
    }

    result = SH_DodGreaseTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_DodGreaseSeqIdle();
        self.wep_nextframe       = 0;
        self.dodgrease_snd_stage = 0;
    }
};

void() W_DodGreaseEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodgrease", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODGREASE_VIEWMODEL, DODGREASE_DISPLAY_NAME, SH_DodGreaseSeqDraw(),
        DODGREASE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodGreaseFire;
    self.reload   = W_DodGreaseReload;
    self.wepframe = W_DodGreaseFrame;
    self.shoot    = W_DodGreaseShoot;
    self.dodgrease_snd_stage = 0;
    W_SetCrosshairProfile(DODGREASE_BASE_SPREAD, DODGREASE_MOVE_SPREAD, DODGREASE_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_DodGreaseDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodgrease  = self.mag_dodgrease;
    tgt.ammo_dodgrease = self.ammo_dodgrease;

    self.mag_dodgrease  = 0;
    self.ammo_dodgrease = 0;

    setmodel(tgt, DODGREASE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_dodgreasegun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODGREASE;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodGreaseEquip;
    tgt.weap_drop_func = W_DodGreaseDrop;
    tgt.pickupcopy     = W_DodGreasePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_dodgreasegun =
{
    setmodel(self, DODGREASE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_dodgreasegun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODGREASE;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodGreaseEquip;
    self.weap_drop_func = W_DodGreaseDrop;
    self.pickupcopy     = W_DodGreasePickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodgrease  = MAX_MAG_DODGREASE;
    self.ammo_dodgrease = MAX_AMMO_DODGREASE;
    W_RegisterMapWeapon(weapon_dodgreasegun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodgrease_snd_stage;
float csqc_dodgrease_snd_action;

void() CSQC_PredictDodGreaseCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodgrease_snd_action)
    {
        csqc_dodgrease_snd_action = predicted_player.wep_action_id;
        csqc_dodgrease_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodGreaseTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/greasegun_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODGREASE_BASE_SPREAD, DODGREASE_MOVE_SPREAD, DODGREASE_FULL_SPREAD_SPEED,
                    DODGREASE_CLOSE_DAMAGE, DODGREASE_MIN_DAMAGE, DODGREASE_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    DODGREASE_KICK_PITCH, DODGREASE_KICK_VARIANCE, DODGREASE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODGREASE_MUZZLE_FORWARD, DODGREASE_MUZZLE_RIGHT,
                    DODGREASE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODGREASE_MUZZLE_FORWARD, DODGREASE_MUZZLE_RIGHT,
                    DODGREASE_MUZZLE_DOWN, self.wep_action_id, 1);
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
            float dr = SH_DodGreaseDrawDuration();
            if (csqc_dodgrease_snd_stage < 1 && elapsed >= dr * DODGREASE_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgrease_snd_stage = 1;
            }
            if (csqc_dodgrease_snd_stage < 2 && elapsed >= dr * DODGREASE_DRAW_F_CLIP1)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgrease_snd_stage = 2;
            }
            if (csqc_dodgrease_snd_stage < 3 && elapsed >= dr * DODGREASE_DRAW_F_CLIP2)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgrease_snd_stage = 3;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodGreaseReloadDuration();

            if (csqc_dodgrease_snd_stage < 1 && elapsed >= rel * DODGREASE_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodgrease_snd_stage = 1;
            }
            if (csqc_dodgrease_snd_stage < 2 && elapsed >= rel * DODGREASE_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgrease_snd_stage = 2;
            }
            if (csqc_dodgrease_snd_stage < 3 && elapsed >= rel * DODGREASE_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgrease_snd_stage = 3;
            }
        }
    }

    SH_DodGreaseTickState(csqc_pred_time);
};

void() CSQC_PredictDodGreaseReload =
{
    if (SH_DodGreaseTryReload(csqc_pred_time))
    {
        csqc_dodgrease_snd_stage  = 0;
        csqc_dodgrease_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodGreaseDisplayFrame =
{
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodgrease <= 0)
              ? SH_DodGreaseSeqEmptyIdle() : SH_DodGreaseSeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODGREASE, predicted_player.weaponstate,
                                   e, e,
                                   DODGREASE_IDLE_REARM_MIN, DODGREASE_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodGreaseSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodGreaseSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodGreasePickShootSeq(predicted_player.wep_action_id);

    return e;
};

void() CSQC_DodGreaseDropClear =
{
    self.mag_dodgrease  = 0;
    self.ammo_dodgrease = 0;
};

void() CSQC_DodGreaseEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodgrease", SCOPE_CLASS_NONE);
    self.weapon_name         = DODGREASE_DISPLAY_NAME;
    self.weapon_viewmodel    = DODGREASE_VIEWMODEL;
    self.weapon_worldmodel   = DODGREASE_WORLDMODEL;
    self.weapon_deploy_sound = DODGREASE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodGreaseCommand;
    self.csqc_predict_reload = CSQC_PredictDodGreaseReload;
    self.csqc_display_frame  = CSQC_DodGreaseDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodGreaseDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
