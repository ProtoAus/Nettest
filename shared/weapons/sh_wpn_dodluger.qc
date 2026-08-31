// ============================================================
//  shared/weapons/sh_wpn_dodluger.qc  -  Day of Defeat Luger P08
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 8-round magazine, 24 reserve, semi-automatic 9x19mm Parabellum
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_luger.mdl, models/w_luger.mdl,
// models/p_luger.mdl and every .wav below come from the mounted dod gamedir.
// See sh_wpn_dodcolt.qc for why that mount sits low in fs_addons.txt.
//
// MEASURED FROM dod/models/v_luger.mdl:
//   [0] idle           12fps    2f  0.083s
//   [1] idle           12fps    2f  0.083s   <- yes, three sequences all called
//   [2] idle           12fps    2f  0.083s      "idle"; see the note below
//   [3] shoot          40fps   41f  1.000s   f0 5001 (muzzleflash)
//   [4] shoot_empty    40fps   41f  1.000s   f0 5001
//   [5] reload_empty   35fps   75f  2.114s
//         f15 5004 "weapons/tommy_reload_clipout.wav"  frac 0.2027
//         f52 5004 "weapons/tommy_reload_clipin.wav"   frac 0.7027
//   [6] reload         35fps   75f  2.114s   (same two events, same instants)
//   [7] draw           35fps   31f  0.857s   f1 5004 "weapons/rifleselect.wav"
//   [8] empty_idle     30fps    2f  0.033s
//
// THREE SEQUENCES NAMED "idle".  frameforname returns the first, which is what
// this file wants, but it is worth knowing they exist: an index-keyed lookup
// written against a replacement model with one idle would land two sequences
// off and fire the gun instead.  Every lookup here is by name.
//
// The two reloads are visually distinct (the toggle-lock is held open when the
// magazine ran dry) but carry IDENTICAL events at identical instants, so unlike
// the Colt there is no sound branch — only the take changes.

// --- Ammo fields ---
.float mag_dodluger;
.float ammo_dodluger;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODLUGER_SEQ_IDLE      = 0;
const float DODLUGER_SEQ_SHOOT     = 3;
const float DODLUGER_SEQ_SHOOTEMP  = 4;
const float DODLUGER_SEQ_RELOADEMP = 5;
const float DODLUGER_SEQ_RELOAD    = 6;
const float DODLUGER_SEQ_DRAW      = 7;

const float DODLUGER_FRAME_INTERVAL = 0.0333334;
const float DODLUGER_FIRE_DELAY     = 0.17;
const float DODLUGER_DRYFIRE_DELAY  = 0.20;

const float DODLUGER_DRAW_F_SELECT    = 0.0333;   // frame 1  / 30
const float DODLUGER_RELOAD_F_CLIPOUT = 0.2027;   // frame 15 / 74
const float DODLUGER_RELOAD_F_CLIPIN  = 0.7027;   // frame 52 / 74

// Non-looping idle — see the note in sh_wpn_dodcolt.qc; it is true of all 37
// Day of Defeat viewmodels.
const float DODLUGER_IDLE_REARM_MIN = 10;
const float DODLUGER_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODLUGER  = 8;
const float MAX_AMMO_DODLUGER = 24;

// --- Balance ---
//
// 9mm Parabellum out of a service pistol.  Against the ladder: Deagle 35/18,
// M1911 34/18, P228 28/16, Five-seven 20/12.  The Luger is the same cartridge
// class as the P228 in a longer barrel, so 27/15 with a slightly longer falloff
// -- one round more in the magazine than the Colt and noticeably less per hit,
// which is the honest trade between .45 and 9mm and is also how the two sides
// read in Day of Defeat.
const float DODLUGER_BASE_SPREAD          = 0.007;
const float DODLUGER_MOVE_SPREAD          = 0.052;
const float DODLUGER_FULL_SPREAD_SPEED    = 320;
const float DODLUGER_CLOSE_DAMAGE         = 27;
const float DODLUGER_MIN_DAMAGE           = 15;
const float DODLUGER_DAMAGE_FALLOFF_RANGE = 2200;
const float DODLUGER_KICK_PITCH    = 0.85;   // toggle action, light round: the
const float DODLUGER_KICK_VARIANCE = 0.30;   // flattest-shooting pistol here
const float DODLUGER_KICK_STRENGTH = 0.95;

const float DODLUGER_MUZZLE_FORWARD = 23;
const float DODLUGER_MUZZLE_RIGHT   = 4.5;
const float DODLUGER_MUZZLE_DOWN    = 3.0;

const string DODLUGER_VIEWMODEL    = "models/v_luger.mdl";
const string DODLUGER_WORLDMODEL   = "models/w_luger.mdl";
const string DODLUGER_DEPLOY_SOUND = "";
const string DODLUGER_DISPLAY_NAME = "Luger P08";

.float dodluger_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodLugerSeqIdle      = { return SH_SeqForName(DODLUGER_VIEWMODEL, "idle",         DODLUGER_SEQ_IDLE); };
// The toggle-locked-open rest pose.  This file already wires shoot_empty and
// reload_empty, so the gap was the IDLE only — see the note in sh_wpn_dodmp40.qc.
const float DODLUGER_SEQ_EMPTY_IDLE = 8;
float() SH_DodLugerSeqEmptyIdle = { return SH_SeqForName(DODLUGER_VIEWMODEL, "empty_idle", DODLUGER_SEQ_EMPTY_IDLE); };
float() SH_DodLugerSeqShoot     = { return SH_SeqForName(DODLUGER_VIEWMODEL, "shoot",        DODLUGER_SEQ_SHOOT); };
float() SH_DodLugerSeqShootEmp  = { return SH_SeqForName(DODLUGER_VIEWMODEL, "shoot_empty",  DODLUGER_SEQ_SHOOTEMP); };
float() SH_DodLugerSeqReload    = { return SH_SeqForName(DODLUGER_VIEWMODEL, "reload",       DODLUGER_SEQ_RELOAD); };
float() SH_DodLugerSeqReloadEmp = { return SH_SeqForName(DODLUGER_VIEWMODEL, "reload_empty", DODLUGER_SEQ_RELOADEMP); };
float() SH_DodLugerSeqDraw      = { return SH_SeqForName(DODLUGER_VIEWMODEL, "draw",         DODLUGER_SEQ_DRAW); };

float(float mag) SH_DodLugerSeqReloadFor =
{
    return (mag <= 0) ? SH_DodLugerSeqReloadEmp() : SH_DodLugerSeqReload();
};

float() SH_DodLugerDrawDuration   = { return SH_SeqDuration(DODLUGER_VIEWMODEL, SH_DodLugerSeqDraw(),   0.857); };
float() SH_DodLugerReloadDuration = { return SH_SeqDuration(DODLUGER_VIEWMODEL, SH_DodLugerSeqReload(), 2.114); };

// ============================================================
//  SHARED - state machine
// ============================================================

// reload_apply_time == reload_dur so the magazine cannot flip mid-reload and
// swap the take out from under the render — the full rationale is in
// SH_DodColtTickState.
float(float now) SH_DodLugerTickState =
{
    float rel = SH_DodLugerReloadDuration();
    return SH_StandardTickState(now, mag_dodluger, ammo_dodluger, MAX_MAG_DODLUGER,
        SH_DodLugerDrawDuration(),
        SH_SeqDuration(DODLUGER_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel);
};

float(float now) SH_DodLugerTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodluger, DODLUGER_FIRE_DELAY, DODLUGER_DRYFIRE_DELAY);
};

float(float now) SH_DodLugerTryReload =
{
    return SH_StandardTryReload(now, mag_dodluger, ammo_dodluger, MAX_MAG_DODLUGER,
        SH_DodLugerReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodLugerPickupCopy =
{
    player.mag_dodluger  = self.mag_dodluger;
    player.ammo_dodluger = self.ammo_dodluger;
};

void() W_DodLugerShoot =
{
    W_PenetratingHitscanShoot(DODLUGER_BASE_SPREAD, DODLUGER_MOVE_SPREAD, DODLUGER_FULL_SPREAD_SPEED,
        DODLUGER_CLOSE_DAMAGE, DODLUGER_MIN_DAMAGE, DODLUGER_DAMAGE_FALLOFF_RANGE, 16, 0.95,
        DODLUGER_KICK_PITCH, DODLUGER_KICK_VARIANCE, DODLUGER_KICK_STRENGTH);
};

void() W_DodLugerFire =
{
    float r = SH_DodLugerTryFire(time);

    if (r == 1)
    {
        // Magazine read AFTER the shot: 0 means the toggle is locked open, which
        // is what shoot_empty draws.
        self.weaponframe        = (self.mag_dodluger <= 0) ? SH_DodLugerSeqShootEmp()
                                                           : SH_DodLugerSeqShoot();
        self.wep_nextframe      = time + DODLUGER_FRAME_INTERVAL;
        self.dodluger_snd_stage = 0;

        W_DodLugerShoot();

        sound(self, CHAN_WEAPON, "weapons/luger_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodLugerReload =
{
    if (SH_DodLugerTryReload(time))
    {
        self.weaponframe        = SH_DodLugerSeqReloadFor(self.mag_dodluger);
        self.wep_nextframe      = time + DODLUGER_FRAME_INTERVAL;
        self.dodluger_snd_stage = 0;
    }
};

void() W_DodLugerFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.
    self.wep_nextframe += DODLUGER_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodLugerDrawDuration() * DODLUGER_DRAW_F_SELECT
            && self.dodluger_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodluger_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodLugerReloadDuration();

        if (elapsed >= rel * DODLUGER_RELOAD_F_CLIPOUT && self.dodluger_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.dodluger_snd_stage = 1;
        }
        if (elapsed >= rel * DODLUGER_RELOAD_F_CLIPIN && self.dodluger_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodluger_snd_stage = 2;
        }
    }

    result = SH_DodLugerTickState(time);
    if (result & 1)
    {
        self.weaponframe        = SH_DodLugerSeqIdle();
        self.wep_nextframe      = 0;
        self.dodluger_snd_stage = 0;
    }
};

void() W_DodLugerEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodluger", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODLUGER_VIEWMODEL, DODLUGER_DISPLAY_NAME, SH_DodLugerSeqDraw(),
        DODLUGER_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodLugerFire;
    self.reload   = W_DodLugerReload;
    self.wepframe = W_DodLugerFrame;
    self.shoot    = W_DodLugerShoot;
    self.dodluger_snd_stage = 0;
    W_SetCrosshairProfile(DODLUGER_BASE_SPREAD, DODLUGER_MOVE_SPREAD, DODLUGER_FULL_SPREAD_SPEED, 1.3, TRUE);
};

void() W_DodLugerDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodluger  = self.mag_dodluger;
    tgt.ammo_dodluger = self.ammo_dodluger;

    self.mag_dodluger  = 0;
    self.ammo_dodluger = 0;

    setmodel(tgt, DODLUGER_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_luger";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODLUGER;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_DodLugerEquip;
    tgt.weap_drop_func = W_DodLugerDrop;
    tgt.pickupcopy     = W_DodLugerPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_luger =
{
    setmodel(self, DODLUGER_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_luger";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODLUGER;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_DodLugerEquip;
    self.weap_drop_func = W_DodLugerDrop;
    self.pickupcopy     = W_DodLugerPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodluger   = MAX_MAG_DODLUGER;
    self.ammo_dodluger  = MAX_AMMO_DODLUGER;
    W_RegisterMapWeapon(weapon_luger);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodluger_snd_stage;
float csqc_dodluger_snd_action;

void() CSQC_PredictDodLugerCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodluger_snd_action)
    {
        csqc_dodluger_snd_action = predicted_player.wep_action_id;
        csqc_dodluger_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodLugerTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/luger_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODLUGER_BASE_SPREAD, DODLUGER_MOVE_SPREAD, DODLUGER_FULL_SPREAD_SPEED,
                    DODLUGER_CLOSE_DAMAGE, DODLUGER_MIN_DAMAGE, DODLUGER_DAMAGE_FALLOFF_RANGE, 16, 0.95,
                    DODLUGER_KICK_PITCH, DODLUGER_KICK_VARIANCE, DODLUGER_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODLUGER_MUZZLE_FORWARD, DODLUGER_MUZZLE_RIGHT,
                    DODLUGER_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODLUGER_MUZZLE_FORWARD, DODLUGER_MUZZLE_RIGHT,
                    DODLUGER_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_dodluger_snd_stage < 1
                && elapsed >= SH_DodLugerDrawDuration() * DODLUGER_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodluger_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodLugerReloadDuration();

            if (csqc_dodluger_snd_stage < 1 && elapsed >= rel * DODLUGER_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodluger_snd_stage = 1;
            }
            if (csqc_dodluger_snd_stage < 2 && elapsed >= rel * DODLUGER_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodluger_snd_stage = 2;
            }
        }
    }

    SH_DodLugerTickState(csqc_pred_time);
};

void() CSQC_PredictDodLugerReload =
{
    if (SH_DodLugerTryReload(csqc_pred_time))
    {
        csqc_dodluger_snd_stage  = 0;
        csqc_dodluger_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodLugerDisplayFrame =
{
    // FIRST, for every state — see sh_wpn_dodcolt.qc.
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodluger <= 0)
              ? SH_DodLugerSeqEmptyIdle() : SH_DodLugerSeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODLUGER, predicted_player.weaponstate,
                                   e, e,
                                   DODLUGER_IDLE_REARM_MIN, DODLUGER_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodLugerSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodLugerSeqReloadFor(predicted_player.mag_dodluger);
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_dodluger <= 0) ? SH_DodLugerSeqShootEmp()
                                                    : SH_DodLugerSeqShoot();

    return e;
};

void() CSQC_DodLugerDropClear =
{
    self.mag_dodluger  = 0;
    self.ammo_dodluger = 0;
};

void() CSQC_DodLugerEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodluger", SCOPE_CLASS_NONE);
    self.weapon_name         = DODLUGER_DISPLAY_NAME;
    self.weapon_viewmodel    = DODLUGER_VIEWMODEL;
    self.weapon_worldmodel   = DODLUGER_WORLDMODEL;
    self.weapon_deploy_sound = DODLUGER_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodLugerCommand;
    self.csqc_predict_reload = CSQC_PredictDodLugerReload;
    self.csqc_display_frame  = CSQC_DodLugerDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodLugerDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
