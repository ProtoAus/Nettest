// ============================================================
//  shared/weapons/sh_wpn_dodcarbine.qc  -  Day of Defeat M1 Carbine
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 15-round magazine, 45 reserve, semi-automatic .30 Carbine
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_m1carbine.mdl,
// models/w_m1carb.mdl, models/p_m1carb.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_m1carbine.mdl — four sequences:
//   [0] idle    10fps   81f   8.000s
//   [1] reload  35fps  111f   3.143s
//         f16 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1455
//         f68 5004 "weapons/tommy_reload_clipin.wav"    frac 0.6182
//         f86 5004 "weapons/tommy_draw_slideback.wav"   frac 0.7818
//   [2] draw    35fps   36f   1.000s   f1 5004 "weapons/rifleselect.wav"
//   [3] shoot   20fps   46f   2.250s   f1 5001 (flash) f1 6001 (shell)
//
// ONE firing take and NO shoot_empty, so nothing here branches on the magazine
// and the reload can apply mid-animation the way most weapons in this tree do.
// The 2.25s `shoot` is the full recoil recovery; at a 0.15s trigger pull only
// its first frames are ever seen, which is how Day of Defeat plays it too.
//
// The reload uses the Thompson's magazine sounds, not a carbine-specific set.
// That is the model's own event data, not a substitution made here -- DoD
// shares those three .wavs across most of its box-magazine weapons.

// --- Ammo fields ---
.float mag_dodcarbine;
.float ammo_dodcarbine;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODCARBINE_SEQ_IDLE   = 0;
const float DODCARBINE_SEQ_RELOAD = 1;
const float DODCARBINE_SEQ_DRAW   = 2;
const float DODCARBINE_SEQ_SHOOT  = 3;

const float DODCARBINE_FRAME_INTERVAL = 0.0333334;
const float DODCARBINE_FIRE_DELAY     = 0.15;
const float DODCARBINE_DRYFIRE_DELAY  = 0.20;

const float DODCARBINE_DRAW_F_SELECT    = 0.0286;   // frame 1  / 35
const float DODCARBINE_RELOAD_F_CLIPOUT = 0.1455;   // frame 16 / 110
const float DODCARBINE_RELOAD_F_CLIPIN  = 0.6182;   // frame 68 / 110
const float DODCARBINE_RELOAD_F_BOLT    = 0.7818;   // frame 86 / 110
const float DODCARBINE_RELOAD_F_APPLY   = 0.6600;   // just after the mag seats

const float DODCARBINE_IDLE_REARM_MIN = 10;
const float DODCARBINE_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODCARBINE  = 15;
const float MAX_AMMO_DODCARBINE = 45;

// --- Balance ---
//
// .30 Carbine is an INTERMEDIATE cartridge -- a pistol round with a rifle's
// manners -- and the numbers say so: 34/22 sits with the StG44's 36/22 and a
// long way under the Garand's 62/44, over a 2600 falloff rather than 4096.
// What it buys is rate and capacity: fifteen rounds at 0.15s is the fastest
// semi-auto in this set and the only one that can hold its own indoors.
const float DODCARBINE_BASE_SPREAD          = 0.009;
const float DODCARBINE_MOVE_SPREAD          = 0.070;
const float DODCARBINE_FULL_SPREAD_SPEED    = 320;
const float DODCARBINE_CLOSE_DAMAGE         = 34;
const float DODCARBINE_MIN_DAMAGE           = 22;
const float DODCARBINE_DAMAGE_FALLOFF_RANGE = 2600;
const float DODCARBINE_KICK_PITCH    = 1.00;
const float DODCARBINE_KICK_VARIANCE = 0.35;
const float DODCARBINE_KICK_STRENGTH = 1.00;

const float DODCARBINE_MUZZLE_FORWARD = 40;
const float DODCARBINE_MUZZLE_RIGHT   = 3;
const float DODCARBINE_MUZZLE_DOWN    = 2.5;

const string DODCARBINE_VIEWMODEL    = "models/v_m1carbine.mdl";
const string DODCARBINE_WORLDMODEL   = "models/w_m1carb.mdl";
const string DODCARBINE_DEPLOY_SOUND = "";
const string DODCARBINE_DISPLAY_NAME = "M1 Carbine";

.float dodcarbine_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodCarbineSeqIdle   = { return SH_SeqForName(DODCARBINE_VIEWMODEL, "idle",   DODCARBINE_SEQ_IDLE); };
float() SH_DodCarbineSeqReload = { return SH_SeqForName(DODCARBINE_VIEWMODEL, "reload", DODCARBINE_SEQ_RELOAD); };
float() SH_DodCarbineSeqDraw   = { return SH_SeqForName(DODCARBINE_VIEWMODEL, "draw",   DODCARBINE_SEQ_DRAW); };
float() SH_DodCarbineSeqShoot  = { return SH_SeqForName(DODCARBINE_VIEWMODEL, "shoot",  DODCARBINE_SEQ_SHOOT); };

float() SH_DodCarbineDrawDuration   = { return SH_SeqDuration(DODCARBINE_VIEWMODEL, SH_DodCarbineSeqDraw(),   1.000); };
float() SH_DodCarbineReloadDuration = { return SH_SeqDuration(DODCARBINE_VIEWMODEL, SH_DodCarbineSeqReload(), 3.143); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodCarbineTickState =
{
    float rel = SH_DodCarbineReloadDuration();
    return SH_StandardTickState(now, mag_dodcarbine, ammo_dodcarbine, MAX_MAG_DODCARBINE,
        SH_DodCarbineDrawDuration(),
        SH_SeqDuration(DODCARBINE_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODCARBINE_RELOAD_F_APPLY);
};

float(float now) SH_DodCarbineTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodcarbine, DODCARBINE_FIRE_DELAY, DODCARBINE_DRYFIRE_DELAY);
};

float(float now) SH_DodCarbineTryReload =
{
    return SH_StandardTryReload(now, mag_dodcarbine, ammo_dodcarbine, MAX_MAG_DODCARBINE,
        SH_DodCarbineReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodCarbinePickupCopy =
{
    player.mag_dodcarbine  = self.mag_dodcarbine;
    player.ammo_dodcarbine = self.ammo_dodcarbine;
};

void() W_DodCarbineShoot =
{
    // Penetration 40 / 0.96 -- between the SMGs' 32 and the full-power rifles'
    // 80, which is where an intermediate cartridge belongs.
    W_PenetratingHitscanShoot(DODCARBINE_BASE_SPREAD, DODCARBINE_MOVE_SPREAD, DODCARBINE_FULL_SPREAD_SPEED,
        DODCARBINE_CLOSE_DAMAGE, DODCARBINE_MIN_DAMAGE, DODCARBINE_DAMAGE_FALLOFF_RANGE, 40, 0.96,
        DODCARBINE_KICK_PITCH, DODCARBINE_KICK_VARIANCE, DODCARBINE_KICK_STRENGTH);
};

void() W_DodCarbineFire =
{
    float r = SH_DodCarbineTryFire(time);

    if (r == 1)
    {
        self.weaponframe          = SH_DodCarbineSeqShoot();
        self.wep_nextframe        = time + DODCARBINE_FRAME_INTERVAL;
        self.dodcarbine_snd_stage = 0;

        W_DodCarbineShoot();

        sound(self, CHAN_WEAPON, "weapons/carbine_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodCarbineReload =
{
    if (SH_DodCarbineTryReload(time))
    {
        self.weaponframe          = SH_DodCarbineSeqReload();
        self.wep_nextframe        = time + DODCARBINE_FRAME_INTERVAL;
        self.dodcarbine_snd_stage = 0;
    }
};

void() W_DodCarbineFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODCARBINE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodCarbineDrawDuration() * DODCARBINE_DRAW_F_SELECT
            && self.dodcarbine_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodcarbine_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodCarbineReloadDuration();

        if (elapsed >= rel * DODCARBINE_RELOAD_F_CLIPOUT && self.dodcarbine_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodcarbine_snd_stage = 1;
        }
        if (elapsed >= rel * DODCARBINE_RELOAD_F_CLIPIN && self.dodcarbine_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodcarbine_snd_stage = 2;
        }
        if (elapsed >= rel * DODCARBINE_RELOAD_F_BOLT && self.dodcarbine_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodcarbine_snd_stage = 3;
        }
    }

    result = SH_DodCarbineTickState(time);
    if (result & 1)
    {
        self.weaponframe          = SH_DodCarbineSeqIdle();
        self.wep_nextframe        = 0;
        self.dodcarbine_snd_stage = 0;
    }
};

void() W_DodCarbineEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodcarbine", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODCARBINE_VIEWMODEL, DODCARBINE_DISPLAY_NAME, SH_DodCarbineSeqDraw(),
        DODCARBINE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodCarbineFire;
    self.reload   = W_DodCarbineReload;
    self.wepframe = W_DodCarbineFrame;
    self.shoot    = W_DodCarbineShoot;
    self.dodcarbine_snd_stage = 0;
    W_SetCrosshairProfile(DODCARBINE_BASE_SPREAD, DODCARBINE_MOVE_SPREAD, DODCARBINE_FULL_SPREAD_SPEED, 1.6, TRUE);
};

void() W_DodCarbineDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodcarbine  = self.mag_dodcarbine;
    tgt.ammo_dodcarbine = self.ammo_dodcarbine;

    self.mag_dodcarbine  = 0;
    self.ammo_dodcarbine = 0;

    setmodel(tgt, DODCARBINE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_m1carbine";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODCARBINE;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodCarbineEquip;
    tgt.weap_drop_func = W_DodCarbineDrop;
    tgt.pickupcopy     = W_DodCarbinePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_m1carbine =
{
    setmodel(self, DODCARBINE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname       = "weapon_m1carbine";
    self.solid           = SOLID_TRIGGER;
    self.movetype        = MOVETYPE_TOSS;
    self.weapon          = WEP_DODCARBINE;
    self.weapon_slot     = SLOT_PRIMARY;
    self.weap_draw       = W_DodCarbineEquip;
    self.weap_drop_func  = W_DodCarbineDrop;
    self.pickupcopy      = W_DodCarbinePickupCopy;
    self.touch           = weapon_touch;
    self.mag_dodcarbine  = MAX_MAG_DODCARBINE;
    self.ammo_dodcarbine = MAX_AMMO_DODCARBINE;
    W_RegisterMapWeapon(weapon_m1carbine);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodcarbine_snd_stage;
float csqc_dodcarbine_snd_action;

void() CSQC_PredictDodCarbineCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodcarbine_snd_action)
    {
        csqc_dodcarbine_snd_action = predicted_player.wep_action_id;
        csqc_dodcarbine_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodCarbineTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/carbine_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODCARBINE_BASE_SPREAD, DODCARBINE_MOVE_SPREAD, DODCARBINE_FULL_SPREAD_SPEED,
                    DODCARBINE_CLOSE_DAMAGE, DODCARBINE_MIN_DAMAGE, DODCARBINE_DAMAGE_FALLOFF_RANGE, 40, 0.96,
                    DODCARBINE_KICK_PITCH, DODCARBINE_KICK_VARIANCE, DODCARBINE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODCARBINE_MUZZLE_FORWARD, DODCARBINE_MUZZLE_RIGHT,
                    DODCARBINE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODCARBINE_MUZZLE_FORWARD, DODCARBINE_MUZZLE_RIGHT,
                    DODCARBINE_MUZZLE_DOWN, self.wep_action_id, 2);
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
            if (csqc_dodcarbine_snd_stage < 1
                && elapsed >= SH_DodCarbineDrawDuration() * DODCARBINE_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcarbine_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodCarbineReloadDuration();

            if (csqc_dodcarbine_snd_stage < 1 && elapsed >= rel * DODCARBINE_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodcarbine_snd_stage = 1;
            }
            if (csqc_dodcarbine_snd_stage < 2 && elapsed >= rel * DODCARBINE_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcarbine_snd_stage = 2;
            }
            if (csqc_dodcarbine_snd_stage < 3 && elapsed >= rel * DODCARBINE_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcarbine_snd_stage = 3;
            }
        }
    }

    SH_DodCarbineTickState(csqc_pred_time);
};

void() CSQC_PredictDodCarbineReload =
{
    if (SH_DodCarbineTryReload(csqc_pred_time))
    {
        csqc_dodcarbine_snd_stage  = 0;
        csqc_dodcarbine_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodCarbineDisplayFrame =
{
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODCARBINE, predicted_player.weaponstate,
                                   SH_DodCarbineSeqIdle(), SH_DodCarbineSeqIdle(),
                                   DODCARBINE_IDLE_REARM_MIN, DODCARBINE_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodCarbineSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodCarbineSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodCarbineSeqShoot();

    return SH_DodCarbineSeqIdle();
};

void() CSQC_DodCarbineDropClear =
{
    self.mag_dodcarbine  = 0;
    self.ammo_dodcarbine = 0;
};

void() CSQC_DodCarbineEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodcarbine", SCOPE_CLASS_NONE);
    self.weapon_name         = DODCARBINE_DISPLAY_NAME;
    self.weapon_viewmodel    = DODCARBINE_VIEWMODEL;
    self.weapon_worldmodel   = DODCARBINE_WORLDMODEL;
    self.weapon_deploy_sound = DODCARBINE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodCarbineCommand;
    self.csqc_predict_reload = CSQC_PredictDodCarbineReload;
    self.csqc_display_frame  = CSQC_DodCarbineDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodCarbineDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
