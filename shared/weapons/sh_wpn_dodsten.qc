// ============================================================
//  shared/weapons/sh_wpn_dodsten.qc  -  Day of Defeat Sten Mk II
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 32-round magazine, 96 reserve, full-auto 9x19mm Parabellum
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_sten.mdl, models/w_sten.mdl,
// models/p_sten.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_sten.mdl — four sequences, one of the leanest sets:
//   [0] idle    8fps   81f  10.000s
//   [1] reload 40fps  117f   2.900s
//         f22 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1897
//         f95 5004 "weapons/tommy_reload_clipin.wav"    frac 0.8190
//   [2] draw   40fps   36f   0.875s   f1 5004 "weapons/rifleselect.wav"
//   [3] shoot  25fps   46f   1.800s   f1 5001 (flash) f1 6002 (shell)
//
// ONE firing take, no empty_idle -- a Sten is a tube, a spring and a magazine
// well, and the model is as spare as the gun.

// --- Ammo fields ---
.float mag_dodsten;
.float ammo_dodsten;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODSTEN_SEQ_IDLE   = 0;
const float DODSTEN_SEQ_RELOAD = 1;
const float DODSTEN_SEQ_DRAW   = 2;
const float DODSTEN_SEQ_SHOOT  = 3;

const float DODSTEN_FRAME_INTERVAL = 0.0333334;
const float DODSTEN_FIRE_DELAY     = 0.109;   // ~550 rpm, as the MP40
const float DODSTEN_DRYFIRE_DELAY  = 0.20;

const float DODSTEN_DRAW_F_SELECT    = 0.0286;   // frame 1  / 35
const float DODSTEN_RELOAD_F_CLIPOUT = 0.1897;   // frame 22 / 116
const float DODSTEN_RELOAD_F_CLIPIN  = 0.8190;   // frame 95 / 116
const float DODSTEN_RELOAD_F_APPLY   = 0.8400;   // just after the mag seats

const float DODSTEN_IDLE_REARM_MIN = 10;
const float DODSTEN_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODSTEN  = 32;
const float MAX_AMMO_DODSTEN = 96;

// --- Balance ---
//
// Ballistically the MP40's twin -- same cartridge, same rate, same magazine --
// so it gets the same 23/13 over 2000 rather than an invented difference.  What
// separates them is handling, which is where the Sten's reputation lives: a
// side-mounted magazine and a stamped receiver make it noticeably less
// controllable, so the standing cone is wider (0.014 against 0.011), the moving
// cone is wider still, and the kick variance is up.  It is also the cheapest
// SMG in the DoD set, which is the trade being offered.
const float DODSTEN_BASE_SPREAD          = 0.014;
const float DODSTEN_MOVE_SPREAD          = 0.082;
const float DODSTEN_FULL_SPREAD_SPEED    = 320;
const float DODSTEN_CLOSE_DAMAGE         = 23;
const float DODSTEN_MIN_DAMAGE           = 13;
const float DODSTEN_DAMAGE_FALLOFF_RANGE = 2000;
const float DODSTEN_KICK_PITCH    = 0.70;
const float DODSTEN_KICK_VARIANCE = 0.45;
const float DODSTEN_KICK_STRENGTH = 1.05;

const float DODSTEN_MUZZLE_FORWARD = 38;
const float DODSTEN_MUZZLE_RIGHT   = 4;
const float DODSTEN_MUZZLE_DOWN    = 4;

const string DODSTEN_VIEWMODEL    = "models/v_sten.mdl";
const string DODSTEN_WORLDMODEL   = "models/w_sten.mdl";
const string DODSTEN_DEPLOY_SOUND = "";
const string DODSTEN_DISPLAY_NAME = "Sten";

.float dodsten_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodStenSeqIdle   = { return SH_SeqForName(DODSTEN_VIEWMODEL, "idle",   DODSTEN_SEQ_IDLE); };
float() SH_DodStenSeqReload = { return SH_SeqForName(DODSTEN_VIEWMODEL, "reload", DODSTEN_SEQ_RELOAD); };
float() SH_DodStenSeqDraw   = { return SH_SeqForName(DODSTEN_VIEWMODEL, "draw",   DODSTEN_SEQ_DRAW); };
float() SH_DodStenSeqShoot  = { return SH_SeqForName(DODSTEN_VIEWMODEL, "shoot",  DODSTEN_SEQ_SHOOT); };

float() SH_DodStenDrawDuration   = { return SH_SeqDuration(DODSTEN_VIEWMODEL, SH_DodStenSeqDraw(),   0.875); };
float() SH_DodStenReloadDuration = { return SH_SeqDuration(DODSTEN_VIEWMODEL, SH_DodStenSeqReload(), 2.900); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodStenTickState =
{
    float rel = SH_DodStenReloadDuration();
    return SH_StandardTickState(now, mag_dodsten, ammo_dodsten, MAX_MAG_DODSTEN,
        SH_DodStenDrawDuration(),
        SH_SeqDuration(DODSTEN_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODSTEN_RELOAD_F_APPLY);
};

float(float now) SH_DodStenTryFire =
{
    return SH_StandardTryFire(now, mag_dodsten, DODSTEN_FIRE_DELAY, DODSTEN_DRYFIRE_DELAY);
};

float(float now) SH_DodStenTryReload =
{
    return SH_StandardTryReload(now, mag_dodsten, ammo_dodsten, MAX_MAG_DODSTEN,
        SH_DodStenReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodStenPickupCopy =
{
    player.mag_dodsten  = self.mag_dodsten;
    player.ammo_dodsten = self.ammo_dodsten;
};

void() W_DodStenShoot =
{
    W_PenetratingHitscanShoot(DODSTEN_BASE_SPREAD, DODSTEN_MOVE_SPREAD, DODSTEN_FULL_SPREAD_SPEED,
        DODSTEN_CLOSE_DAMAGE, DODSTEN_MIN_DAMAGE, DODSTEN_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        DODSTEN_KICK_PITCH, DODSTEN_KICK_VARIANCE, DODSTEN_KICK_STRENGTH);
};

void() W_DodStenFire =
{
    float r = SH_DodStenTryFire(time);

    if (r == 1)
    {
        self.weaponframe      = SH_DodStenSeqShoot();
        self.wep_nextframe    = time + DODSTEN_FRAME_INTERVAL;
        self.dodsten_snd_stage = 0;

        W_DodStenShoot();

        sound(self, CHAN_WEAPON, "weapons/sten_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodStenReload =
{
    if (SH_DodStenTryReload(time))
    {
        self.weaponframe       = SH_DodStenSeqReload();
        self.wep_nextframe     = time + DODSTEN_FRAME_INTERVAL;
        self.dodsten_snd_stage = 0;
    }
};

void() W_DodStenFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODSTEN_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodStenDrawDuration() * DODSTEN_DRAW_F_SELECT
            && self.dodsten_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodsten_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodStenReloadDuration();

        if (elapsed >= rel * DODSTEN_RELOAD_F_CLIPOUT && self.dodsten_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodsten_snd_stage = 1;
        }
        if (elapsed >= rel * DODSTEN_RELOAD_F_CLIPIN && self.dodsten_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodsten_snd_stage = 2;
        }
    }

    result = SH_DodStenTickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodStenSeqIdle();
        self.wep_nextframe     = 0;
        self.dodsten_snd_stage = 0;
    }
};

void() W_DodStenEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodsten", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODSTEN_VIEWMODEL, DODSTEN_DISPLAY_NAME, SH_DodStenSeqDraw(),
        DODSTEN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodStenFire;
    self.reload   = W_DodStenReload;
    self.wepframe = W_DodStenFrame;
    self.shoot    = W_DodStenShoot;
    self.dodsten_snd_stage = 0;
    W_SetCrosshairProfile(DODSTEN_BASE_SPREAD, DODSTEN_MOVE_SPREAD, DODSTEN_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_DodStenDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodsten  = self.mag_dodsten;
    tgt.ammo_dodsten = self.ammo_dodsten;

    self.mag_dodsten  = 0;
    self.ammo_dodsten = 0;

    setmodel(tgt, DODSTEN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sten";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODSTEN;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodStenEquip;
    tgt.weap_drop_func = W_DodStenDrop;
    tgt.pickupcopy     = W_DodStenPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// As the Webley: a British weapon Day of Defeat delivers from the class menu
// rather than a map entity, so weapon_sten is this mod's spelling.  Unused here
// before now.
void() weapon_sten =
{
    setmodel(self, DODSTEN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sten";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODSTEN;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodStenEquip;
    self.weap_drop_func = W_DodStenDrop;
    self.pickupcopy     = W_DodStenPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodsten    = MAX_MAG_DODSTEN;
    self.ammo_dodsten   = MAX_AMMO_DODSTEN;
    W_RegisterMapWeapon(weapon_sten);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodsten_snd_stage;
float csqc_dodsten_snd_action;

void() CSQC_PredictDodStenCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodsten_snd_action)
    {
        csqc_dodsten_snd_action = predicted_player.wep_action_id;
        csqc_dodsten_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodStenTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/sten_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODSTEN_BASE_SPREAD, DODSTEN_MOVE_SPREAD, DODSTEN_FULL_SPREAD_SPEED,
                    DODSTEN_CLOSE_DAMAGE, DODSTEN_MIN_DAMAGE, DODSTEN_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    DODSTEN_KICK_PITCH, DODSTEN_KICK_VARIANCE, DODSTEN_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODSTEN_MUZZLE_FORWARD, DODSTEN_MUZZLE_RIGHT,
                    DODSTEN_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODSTEN_MUZZLE_FORWARD, DODSTEN_MUZZLE_RIGHT,
                    DODSTEN_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_dodsten_snd_stage < 1
                && elapsed >= SH_DodStenDrawDuration() * DODSTEN_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodsten_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodStenReloadDuration();

            if (csqc_dodsten_snd_stage < 1 && elapsed >= rel * DODSTEN_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodsten_snd_stage = 1;
            }
            if (csqc_dodsten_snd_stage < 2 && elapsed >= rel * DODSTEN_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodsten_snd_stage = 2;
            }
        }
    }

    SH_DodStenTickState(csqc_pred_time);
};

void() CSQC_PredictDodStenReload =
{
    if (SH_DodStenTryReload(csqc_pred_time))
    {
        csqc_dodsten_snd_stage  = 0;
        csqc_dodsten_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodStenDisplayFrame =
{
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODSTEN, predicted_player.weaponstate,
                                   SH_DodStenSeqIdle(), SH_DodStenSeqIdle(),
                                   DODSTEN_IDLE_REARM_MIN, DODSTEN_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodStenSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodStenSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodStenSeqShoot();

    return SH_DodStenSeqIdle();
};

void() CSQC_DodStenDropClear =
{
    self.mag_dodsten  = 0;
    self.ammo_dodsten = 0;
};

void() CSQC_DodStenEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodsten", SCOPE_CLASS_NONE);
    self.weapon_name         = DODSTEN_DISPLAY_NAME;
    self.weapon_viewmodel    = DODSTEN_VIEWMODEL;
    self.weapon_worldmodel   = DODSTEN_WORLDMODEL;
    self.weapon_deploy_sound = DODSTEN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodStenCommand;
    self.csqc_predict_reload = CSQC_PredictDodStenReload;
    self.csqc_display_frame  = CSQC_DodStenDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodStenDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
