// ============================================================
//  shared/weapons/sh_wpn_dodmp44.qc  -  Day of Defeat StG44 (MP44)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto 7.92x33 Kurz
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_mp44.mdl, models/w_mp44.mdl,
// models/p_stg44.mdl come from the mounted dod gamedir.  Note the model set
// disagrees with itself about the name: the view and world models are mp44, the
// player model is stg44.  Both spellings are correct for the same rifle and
// both are wired here; the manifest key accepts either.
//
// MEASURED FROM dod/models/v_mp44.mdl:
//   [0] idle       11fps   71f  6.364s
//   [1] reload     40fps  126f  3.125s
//         f15 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1200
//         f68 5004 "weapons/tommy_reload_clipin.wav"    frac 0.5440
//         f99 5004 "weapons/tommy_draw_slideback.wav"   frac 0.7920
//   [2] draw       35fps   36f  1.000s
//         f1  5004 "weapons/rifleselect.wav"            frac 0.0286
//         f12 5004 "weapons/tommy_draw_slideback.wav"   frac 0.3429
//   [3] shoot1     30fps   31f  1.000s   f1 5001 (flash) f1 6002 (shell)
//   [4] shoot2     30fps   31f  1.000s   f1 5001, f1 6002
//   [5] empty_idle 30fps    2f  0.033s
//
// The first assault rifle, and the balance below treats it as one rather than
// as a big SMG -- see the note there.

// --- Ammo fields ---
.float mag_dodmp44;
.float ammo_dodmp44;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODMP44_SEQ_IDLE   = 0;
const float DODMP44_SEQ_RELOAD = 1;
const float DODMP44_SEQ_DRAW   = 2;
const float DODMP44_SEQ_SHOOT1 = 3;
const float DODMP44_SEQ_SHOOT2 = 4;

const float DODMP44_FRAME_INTERVAL = 0.0333334;
const float DODMP44_FIRE_DELAY     = 0.109;   // ~550 rpm, the StG44's real rate
const float DODMP44_DRYFIRE_DELAY  = 0.20;

const float DODMP44_DRAW_F_SELECT    = 0.0286;   // frame 1  / 35
const float DODMP44_DRAW_F_BOLT      = 0.3429;   // frame 12 / 35
const float DODMP44_RELOAD_F_CLIPOUT = 0.1200;   // frame 15 / 125
const float DODMP44_RELOAD_F_CLIPIN  = 0.5440;   // frame 68 / 125
const float DODMP44_RELOAD_F_BOLT    = 0.7920;   // frame 99 / 125
const float DODMP44_RELOAD_F_APPLY   = 0.5700;   // just after the mag seats

const float DODMP44_IDLE_REARM_MIN = 10;
const float DODMP44_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODMP44  = 30;
const float MAX_AMMO_DODMP44 = 90;

// --- Balance ---
//
// 7.92 Kurz is a SHORTENED rifle round -- the first intermediate cartridge --
// so this belongs with the M1 Carbine's 34/22 rather than with either the SMGs
// (23-27 close) or the full-power rifles (58-62).  36/22 over 2600 puts it a
// step above the carbine because it is a rifle-length barrel firing a heavier
// bullet, and it is the only full-auto weapon in this set that reaches out.
//
// That combination is strong, so the price is control: 550 rpm with the
// heaviest kick of any automatic here and a standing cone wider than either
// semi-auto rifle.  Tapping it is accurate; holding it is not, which is the
// whole design of the gun.
const float DODMP44_BASE_SPREAD          = 0.012;
const float DODMP44_MOVE_SPREAD          = 0.078;
const float DODMP44_FULL_SPREAD_SPEED    = 320;
const float DODMP44_CLOSE_DAMAGE         = 36;
const float DODMP44_MIN_DAMAGE           = 22;
const float DODMP44_DAMAGE_FALLOFF_RANGE = 2600;
const float DODMP44_KICK_PITCH    = 1.15;
const float DODMP44_KICK_VARIANCE = 0.42;
const float DODMP44_KICK_STRENGTH = 1.25;

const float DODMP44_MUZZLE_FORWARD = 42;
const float DODMP44_MUZZLE_RIGHT   = 3.5;
const float DODMP44_MUZZLE_DOWN    = 3;

const string DODMP44_VIEWMODEL    = "models/v_mp44.mdl";
const string DODMP44_WORLDMODEL   = "models/w_mp44.mdl";
const string DODMP44_DEPLOY_SOUND = "";
const string DODMP44_DISPLAY_NAME = "StG44";

.float dodmp44_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodMP44SeqIdle   = { return SH_SeqForName(DODMP44_VIEWMODEL, "idle",   DODMP44_SEQ_IDLE); };
// The bolt-open rest pose the model carries and nothing was asking for — see the
// note in sh_wpn_dodmp40.qc; eight DoD weapons shared this gap.
const float DODMP44_SEQ_EMPTY_IDLE = 5;
float() SH_DodMP44SeqEmptyIdle = { return SH_SeqForName(DODMP44_VIEWMODEL, "empty_idle", DODMP44_SEQ_EMPTY_IDLE); };
float() SH_DodMP44SeqReload = { return SH_SeqForName(DODMP44_VIEWMODEL, "reload", DODMP44_SEQ_RELOAD); };
float() SH_DodMP44SeqDraw   = { return SH_SeqForName(DODMP44_VIEWMODEL, "draw",   DODMP44_SEQ_DRAW); };
float() SH_DodMP44SeqShoot1 = { return SH_SeqForName(DODMP44_VIEWMODEL, "shoot1", DODMP44_SEQ_SHOOT1); };
float() SH_DodMP44SeqShoot2 = { return SH_SeqForName(DODMP44_VIEWMODEL, "shoot2", DODMP44_SEQ_SHOOT2); };

float(float action_id) SH_DodMP44PickShootSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodMP44SeqShoot1() : SH_DodMP44SeqShoot2();
};

float() SH_DodMP44DrawDuration   = { return SH_SeqDuration(DODMP44_VIEWMODEL, SH_DodMP44SeqDraw(),   1.000); };
float() SH_DodMP44ReloadDuration = { return SH_SeqDuration(DODMP44_VIEWMODEL, SH_DodMP44SeqReload(), 3.125); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodMP44TickState =
{
    float rel = SH_DodMP44ReloadDuration();
    return SH_StandardTickState(now, mag_dodmp44, ammo_dodmp44, MAX_MAG_DODMP44,
        SH_DodMP44DrawDuration(),
        SH_SeqDuration(DODMP44_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODMP44_RELOAD_F_APPLY);
};

float(float now) SH_DodMP44TryFire =
{
    return SH_StandardTryFire(now, mag_dodmp44, DODMP44_FIRE_DELAY, DODMP44_DRYFIRE_DELAY);
};

float(float now) SH_DodMP44TryReload =
{
    return SH_StandardTryReload(now, mag_dodmp44, ammo_dodmp44, MAX_MAG_DODMP44,
        SH_DodMP44ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodMP44PickupCopy =
{
    player.mag_dodmp44  = self.mag_dodmp44;
    player.ammo_dodmp44 = self.ammo_dodmp44;
};

void() W_DodMP44Shoot =
{
    // Penetration 56 / 0.97 -- between the carbine's 40 and the full-power
    // rifles' 80, matching where the cartridge sits.
    W_PenetratingHitscanShoot(DODMP44_BASE_SPREAD, DODMP44_MOVE_SPREAD, DODMP44_FULL_SPREAD_SPEED,
        DODMP44_CLOSE_DAMAGE, DODMP44_MIN_DAMAGE, DODMP44_DAMAGE_FALLOFF_RANGE, 56, 0.97,
        DODMP44_KICK_PITCH, DODMP44_KICK_VARIANCE, DODMP44_KICK_STRENGTH);
};

void() W_DodMP44Fire =
{
    float r = SH_DodMP44TryFire(time);

    if (r == 1)
    {
        self.weaponframe       = SH_DodMP44PickShootSeq(self.wep_action_id);
        self.wep_nextframe     = time + DODMP44_FRAME_INTERVAL;
        self.dodmp44_snd_stage = 0;

        W_DodMP44Shoot();

        sound(self, CHAN_WEAPON, "weapons/mp44_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodMP44Reload =
{
    if (SH_DodMP44TryReload(time))
    {
        self.weaponframe       = SH_DodMP44SeqReload();
        self.wep_nextframe     = time + DODMP44_FRAME_INTERVAL;
        self.dodmp44_snd_stage = 0;
    }
};

void() W_DodMP44Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODMP44_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        float dr = SH_DodMP44DrawDuration();
        if (elapsed >= dr * DODMP44_DRAW_F_SELECT && self.dodmp44_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodmp44_snd_stage = 1;
        }
        if (elapsed >= dr * DODMP44_DRAW_F_BOLT && self.dodmp44_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodmp44_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodMP44ReloadDuration();

        if (elapsed >= rel * DODMP44_RELOAD_F_CLIPOUT && self.dodmp44_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodmp44_snd_stage = 1;
        }
        if (elapsed >= rel * DODMP44_RELOAD_F_CLIPIN && self.dodmp44_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodmp44_snd_stage = 2;
        }
        if (elapsed >= rel * DODMP44_RELOAD_F_BOLT && self.dodmp44_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodmp44_snd_stage = 3;
        }
    }

    result = SH_DodMP44TickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodMP44SeqIdle();
        self.wep_nextframe     = 0;
        self.dodmp44_snd_stage = 0;
    }
};

void() W_DodMP44Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodmp44", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODMP44_VIEWMODEL, DODMP44_DISPLAY_NAME, SH_DodMP44SeqDraw(),
        DODMP44_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodMP44Fire;
    self.reload   = W_DodMP44Reload;
    self.wepframe = W_DodMP44Frame;
    self.shoot    = W_DodMP44Shoot;
    self.dodmp44_snd_stage = 0;
    W_SetCrosshairProfile(DODMP44_BASE_SPREAD, DODMP44_MOVE_SPREAD, DODMP44_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_DodMP44Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodmp44  = self.mag_dodmp44;
    tgt.ammo_dodmp44 = self.ammo_dodmp44;

    self.mag_dodmp44  = 0;
    self.ammo_dodmp44 = 0;

    setmodel(tgt, DODMP44_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_mp44";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODMP44;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodMP44Equip;
    tgt.weap_drop_func = W_DodMP44Drop;
    tgt.pickupcopy     = W_DodMP44PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_mp44 =
{
    setmodel(self, DODMP44_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_mp44";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODMP44;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodMP44Equip;
    self.weap_drop_func = W_DodMP44Drop;
    self.pickupcopy     = W_DodMP44PickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodmp44    = MAX_MAG_DODMP44;
    self.ammo_dodmp44   = MAX_AMMO_DODMP44;
    W_RegisterMapWeapon(weapon_mp44);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodmp44_snd_stage;
float csqc_dodmp44_snd_action;

void() CSQC_PredictDodMP44Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodmp44_snd_action)
    {
        csqc_dodmp44_snd_action = predicted_player.wep_action_id;
        csqc_dodmp44_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodMP44TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/mp44_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODMP44_BASE_SPREAD, DODMP44_MOVE_SPREAD, DODMP44_FULL_SPREAD_SPEED,
                    DODMP44_CLOSE_DAMAGE, DODMP44_MIN_DAMAGE, DODMP44_DAMAGE_FALLOFF_RANGE, 56, 0.97,
                    DODMP44_KICK_PITCH, DODMP44_KICK_VARIANCE, DODMP44_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODMP44_MUZZLE_FORWARD, DODMP44_MUZZLE_RIGHT,
                    DODMP44_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODMP44_MUZZLE_FORWARD, DODMP44_MUZZLE_RIGHT,
                    DODMP44_MUZZLE_DOWN, self.wep_action_id, 2);
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
            float dr = SH_DodMP44DrawDuration();
            if (csqc_dodmp44_snd_stage < 1 && elapsed >= dr * DODMP44_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp44_snd_stage = 1;
            }
            if (csqc_dodmp44_snd_stage < 2 && elapsed >= dr * DODMP44_DRAW_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp44_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodMP44ReloadDuration();

            if (csqc_dodmp44_snd_stage < 1 && elapsed >= rel * DODMP44_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodmp44_snd_stage = 1;
            }
            if (csqc_dodmp44_snd_stage < 2 && elapsed >= rel * DODMP44_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp44_snd_stage = 2;
            }
            if (csqc_dodmp44_snd_stage < 3 && elapsed >= rel * DODMP44_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmp44_snd_stage = 3;
            }
        }
    }

    SH_DodMP44TickState(csqc_pred_time);
};

void() CSQC_PredictDodMP44Reload =
{
    if (SH_DodMP44TryReload(csqc_pred_time))
    {
        csqc_dodmp44_snd_stage  = 0;
        csqc_dodmp44_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodMP44DisplayFrame =
{
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodmp44 <= 0)
              ? SH_DodMP44SeqEmptyIdle() : SH_DodMP44SeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODMP44, predicted_player.weaponstate,
                                   e, e,
                                   DODMP44_IDLE_REARM_MIN, DODMP44_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodMP44SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodMP44SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodMP44PickShootSeq(predicted_player.wep_action_id);

    return e;
};

void() CSQC_DodMP44DropClear =
{
    self.mag_dodmp44  = 0;
    self.ammo_dodmp44 = 0;
};

void() CSQC_DodMP44Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodmp44", SCOPE_CLASS_NONE);
    self.weapon_name         = DODMP44_DISPLAY_NAME;
    self.weapon_viewmodel    = DODMP44_VIEWMODEL;
    self.weapon_worldmodel   = DODMP44_WORLDMODEL;
    self.weapon_deploy_sound = DODMP44_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodMP44Command;
    self.csqc_predict_reload = CSQC_PredictDodMP44Reload;
    self.csqc_display_frame  = CSQC_DodMP44DisplayFrame;
    self.csqc_drop_clear     = CSQC_DodMP44DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
