// ============================================================
//  shared/weapons/sh_wpn_dodmp40.qc  -  Day of Defeat MP40
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 32-round magazine, 96 reserve, full-auto 9x19mm Parabellum
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_mp40.mdl, models/w_mp40.mdl,
// models/p_mp40.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_mp40.mdl:
//   [0] idle        7fps   61f  8.571s
//   [1] reload     40fps  115f  2.850s
//         f12 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1053
//         f66 5004 "weapons/tommy_reload_clipin.wav"    frac 0.5789
//         f88 5004 "weapons/tommy_draw_slideback.wav"   frac 0.7719
//   [2] draw       30fps   31f  1.000s
//         f1  5004 "weapons/rifleselect.wav"            frac 0.0333
//         f12 5004 "weapons/tommy_draw_slideback.wav"   frac 0.4000
//   [3] shoot1     30fps   31f  1.000s   f1 5001 (flash) f1 6002 (shell)
//   [4] shoot2     30fps   31f  1.000s   f1 5001, f1 6002
//   [5] empty_idle 30fps    2f  0.033s
//
// The draw is a two-event sequence here where most of the set has one: the bolt
// is run at 40% of the way through.  That is the model's own data.

// --- Ammo fields ---
.float mag_dodmp40;
.float ammo_dodmp40;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODMP40_SEQ_IDLE   = 0;
const float DODMP40_SEQ_RELOAD = 1;
const float DODMP40_SEQ_DRAW   = 2;
const float DODMP40_SEQ_SHOOT1 = 3;
const float DODMP40_SEQ_SHOOT2 = 4;
// The bolt-open rest pose.  See SH_DodMP40SeqEmptyIdle.
const float DODMP40_SEQ_EMPTY_IDLE = 5;

const float DODMP40_FRAME_INTERVAL = 0.0333334;
const float DODMP40_FIRE_DELAY     = 0.109;   // ~550 rpm, the MP40's real rate
const float DODMP40_DRYFIRE_DELAY  = 0.20;

const float DODMP40_DRAW_F_SELECT    = 0.0333;   // frame 1  / 30
const float DODMP40_DRAW_F_BOLT      = 0.4000;   // frame 12 / 30
const float DODMP40_RELOAD_F_CLIPOUT = 0.1053;   // frame 12 / 114
const float DODMP40_RELOAD_F_CLIPIN  = 0.5789;   // frame 66 / 114
const float DODMP40_RELOAD_F_BOLT    = 0.7719;   // frame 88 / 114
const float DODMP40_RELOAD_F_APPLY   = 0.6000;   // just after the mag seats

const float DODMP40_IDLE_REARM_MIN = 10;
const float DODMP40_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODMP40  = 32;
const float MAX_AMMO_DODMP40 = 96;

// --- Balance ---
//
// The Axis answer to the Thompson, and the cartridge is the whole difference:
// 9mm Parabellum against .45 ACP.  23/13 against the Thompson's 26/14, over a
// longer 2000 falloff because the lighter bullet leaves the barrel faster, and
// a slower 550 rpm against 700.  What the MP40 gets back is control -- the
// tightest standing cone of the four DoD SMGs and the lightest kick -- which is
// exactly the reputation it has.
const float DODMP40_BASE_SPREAD          = 0.011;
const float DODMP40_MOVE_SPREAD          = 0.070;
const float DODMP40_FULL_SPREAD_SPEED    = 320;
const float DODMP40_CLOSE_DAMAGE         = 23;
const float DODMP40_MIN_DAMAGE           = 13;
const float DODMP40_DAMAGE_FALLOFF_RANGE = 2000;
const float DODMP40_KICK_PITCH    = 0.60;
const float DODMP40_KICK_VARIANCE = 0.28;
const float DODMP40_KICK_STRENGTH = 0.95;

const float DODMP40_MUZZLE_FORWARD = 36;
const float DODMP40_MUZZLE_RIGHT   = 4;
const float DODMP40_MUZZLE_DOWN    = 4;

const string DODMP40_VIEWMODEL    = "models/v_mp40.mdl";
const string DODMP40_WORLDMODEL   = "models/w_mp40.mdl";
const string DODMP40_DEPLOY_SOUND = "";
const string DODMP40_DISPLAY_NAME = "MP40";

.float dodmp40_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodMP40SeqIdle   = { return SH_SeqForName(DODMP40_VIEWMODEL, "idle",   DODMP40_SEQ_IDLE); };
// THE MODEL HAS A BOLT-OPEN IDLE AND NOTHING WAS ASKING FOR IT.  A sweep of all
// 84 viewmodels found nine DoD models carrying an `empty_idle`, of which exactly
// one — the Springfield — was wired; this is one of the other eight.  The gun
// rested with the bolt closed on an empty magazine, which is the same class of
// mistake as the PIAT holding its loaded pose with an empty tube.
float() SH_DodMP40SeqEmptyIdle = { return SH_SeqForName(DODMP40_VIEWMODEL, "empty_idle", DODMP40_SEQ_EMPTY_IDLE); };
float() SH_DodMP40SeqReload = { return SH_SeqForName(DODMP40_VIEWMODEL, "reload", DODMP40_SEQ_RELOAD); };
float() SH_DodMP40SeqDraw   = { return SH_SeqForName(DODMP40_VIEWMODEL, "draw",   DODMP40_SEQ_DRAW); };
float() SH_DodMP40SeqShoot1 = { return SH_SeqForName(DODMP40_VIEWMODEL, "shoot1", DODMP40_SEQ_SHOOT1); };
float() SH_DodMP40SeqShoot2 = { return SH_SeqForName(DODMP40_VIEWMODEL, "shoot2", DODMP40_SEQ_SHOOT2); };

float(float action_id) SH_DodMP40PickShootSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodMP40SeqShoot1() : SH_DodMP40SeqShoot2();
};

float() SH_DodMP40DrawDuration   = { return SH_SeqDuration(DODMP40_VIEWMODEL, SH_DodMP40SeqDraw(),   1.000); };
float() SH_DodMP40ReloadDuration = { return SH_SeqDuration(DODMP40_VIEWMODEL, SH_DodMP40SeqReload(), 2.850); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodMP40TickState =
{
    float rel = SH_DodMP40ReloadDuration();
    return SH_StandardTickState(now, mag_dodmp40, ammo_dodmp40, MAX_MAG_DODMP40,
        SH_DodMP40DrawDuration(),
        SH_SeqDuration(DODMP40_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODMP40_RELOAD_F_APPLY);
};

float(float now) SH_DodMP40TryFire =
{
    return SH_StandardTryFire(now, mag_dodmp40, DODMP40_FIRE_DELAY, DODMP40_DRYFIRE_DELAY);
};

float(float now) SH_DodMP40TryReload =
{
    return SH_StandardTryReload(now, mag_dodmp40, ammo_dodmp40, MAX_MAG_DODMP40,
        SH_DodMP40ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodMP40PickupCopy =
{
    player.mag_dodmp40  = self.mag_dodmp40;
    player.ammo_dodmp40 = self.ammo_dodmp40;
};

void() W_DodMP40Shoot =
{
    W_PenetratingHitscanShoot(DODMP40_BASE_SPREAD, DODMP40_MOVE_SPREAD, DODMP40_FULL_SPREAD_SPEED,
        DODMP40_CLOSE_DAMAGE, DODMP40_MIN_DAMAGE, DODMP40_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        DODMP40_KICK_PITCH, DODMP40_KICK_VARIANCE, DODMP40_KICK_STRENGTH);
};

void() W_DodMP40Fire =
{
    float r = SH_DodMP40TryFire(time);

    if (r == 1)
    {
        self.weaponframe       = SH_DodMP40PickShootSeq(self.wep_action_id);
        self.wep_nextframe     = time + DODMP40_FRAME_INTERVAL;
        self.dodmp40_snd_stage = 0;

        W_DodMP40Shoot();

        sound(self, CHAN_WEAPON, "weapons/mp40_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodMP40Reload =
{
    if (SH_DodMP40TryReload(time))
    {
        self.weaponframe       = SH_DodMP40SeqReload();
        self.wep_nextframe     = time + DODMP40_FRAME_INTERVAL;
        self.dodmp40_snd_stage = 0;
    }
};

void() W_DodMP40Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODMP40_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        float dr = SH_DodMP40DrawDuration();
        if (elapsed >= dr * DODMP40_DRAW_F_SELECT && self.dodmp40_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodmp40_snd_stage = 1;
        }
        if (elapsed >= dr * DODMP40_DRAW_F_BOLT && self.dodmp40_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodmp40_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodMP40ReloadDuration();

        if (elapsed >= rel * DODMP40_RELOAD_F_CLIPOUT && self.dodmp40_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodmp40_snd_stage = 1;
        }
        if (elapsed >= rel * DODMP40_RELOAD_F_CLIPIN && self.dodmp40_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodmp40_snd_stage = 2;
        }
        if (elapsed >= rel * DODMP40_RELOAD_F_BOLT && self.dodmp40_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodmp40_snd_stage = 3;
        }
    }

    result = SH_DodMP40TickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodMP40SeqIdle();
        self.wep_nextframe     = 0;
        self.dodmp40_snd_stage = 0;
    }
};

void() W_DodMP40Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodmp40", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODMP40_VIEWMODEL, DODMP40_DISPLAY_NAME, SH_DodMP40SeqDraw(),
        DODMP40_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodMP40Fire;
    self.reload   = W_DodMP40Reload;
    self.wepframe = W_DodMP40Frame;
    self.shoot    = W_DodMP40Shoot;
    self.dodmp40_snd_stage = 0;
    W_SetCrosshairProfile(DODMP40_BASE_SPREAD, DODMP40_MOVE_SPREAD, DODMP40_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_DodMP40Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodmp40  = self.mag_dodmp40;
    tgt.ammo_dodmp40 = self.ammo_dodmp40;

    self.mag_dodmp40  = 0;
    self.ammo_dodmp40 = 0;

    setmodel(tgt, DODMP40_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_mp40";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODMP40;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodMP40Equip;
    tgt.weap_drop_func = W_DodMP40Drop;
    tgt.pickupcopy     = W_DodMP40PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_mp40 =
{
    setmodel(self, DODMP40_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_mp40";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODMP40;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodMP40Equip;
    self.weap_drop_func = W_DodMP40Drop;
    self.pickupcopy     = W_DodMP40PickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodmp40    = MAX_MAG_DODMP40;
    self.ammo_dodmp40   = MAX_AMMO_DODMP40;
    W_RegisterMapWeapon(weapon_mp40);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodmp40_snd_stage;
float csqc_dodmp40_snd_action;

void() CSQC_PredictDodMP40Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodmp40_snd_action)
    {
        csqc_dodmp40_snd_action = predicted_player.wep_action_id;
        csqc_dodmp40_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodMP40TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/mp40_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODMP40_BASE_SPREAD, DODMP40_MOVE_SPREAD, DODMP40_FULL_SPREAD_SPEED,
                    DODMP40_CLOSE_DAMAGE, DODMP40_MIN_DAMAGE, DODMP40_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    DODMP40_KICK_PITCH, DODMP40_KICK_VARIANCE, DODMP40_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODMP40_MUZZLE_FORWARD, DODMP40_MUZZLE_RIGHT,
                    DODMP40_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODMP40_MUZZLE_FORWARD, DODMP40_MUZZLE_RIGHT,
                    DODMP40_MUZZLE_DOWN, self.wep_action_id, 1);
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
            float dr = SH_DodMP40DrawDuration();
            if (csqc_dodmp40_snd_stage < 1 && elapsed >= dr * DODMP40_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp40_snd_stage = 1;
            }
            if (csqc_dodmp40_snd_stage < 2 && elapsed >= dr * DODMP40_DRAW_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp40_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodMP40ReloadDuration();

            if (csqc_dodmp40_snd_stage < 1 && elapsed >= rel * DODMP40_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodmp40_snd_stage = 1;
            }
            if (csqc_dodmp40_snd_stage < 2 && elapsed >= rel * DODMP40_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp40_snd_stage = 2;
            }
            if (csqc_dodmp40_snd_stage < 3 && elapsed >= rel * DODMP40_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp40_snd_stage = 3;
            }
        }
    }

    SH_DodMP40TickState(csqc_pred_time);
};

void() CSQC_PredictDodMP40Reload =
{
    if (SH_DodMP40TryReload(csqc_pred_time))
    {
        csqc_dodmp40_snd_stage  = 0;
        csqc_dodmp40_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodMP40DisplayFrame =
{
    // Both takes go in as the SAME sequence deliberately: no DoD sequence carries
    // the looping flag, so a held idle freezes on its last frame and the fidget
    // roll must not be able to hand back the other half of the pair.
    float e = (predicted_player.mag_dodmp40 <= 0)
              ? SH_DodMP40SeqEmptyIdle() : SH_DodMP40SeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODMP40, predicted_player.weaponstate,
                                   e, e,
                                   DODMP40_IDLE_REARM_MIN, DODMP40_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodMP40SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodMP40SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodMP40PickShootSeq(predicted_player.wep_action_id);

    return e;
};

void() CSQC_DodMP40DropClear =
{
    self.mag_dodmp40  = 0;
    self.ammo_dodmp40 = 0;
};

void() CSQC_DodMP40Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodmp40", SCOPE_CLASS_NONE);
    self.weapon_name         = DODMP40_DISPLAY_NAME;
    self.weapon_viewmodel    = DODMP40_VIEWMODEL;
    self.weapon_worldmodel   = DODMP40_WORLDMODEL;
    self.weapon_deploy_sound = DODMP40_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodMP40Command;
    self.csqc_predict_reload = CSQC_PredictDodMP40Reload;
    self.csqc_display_frame  = CSQC_DodMP40DisplayFrame;
    self.csqc_drop_clear     = CSQC_DodMP40DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
