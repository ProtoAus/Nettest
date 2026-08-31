// ============================================================
//  shared/weapons/sh_wpn_opeagle.qc  -  Opposing Force Desert Eagle
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 36 reserve, semi-auto, .357
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6937 (weapon_eagle, "Desert Eagle"),
//  svencoop/models/{v,p,w}_desert_eagle.mdl and the five
//  svencoop/sound/weapons/desert_eagle_*.wav.
//
//  Previously an alias onto WEP_DEAGLE — Counter-Strike's Desert Eagle
//  (sv_goldsrc_compat.qc:192).  The closest of the eight aliases by a distance:
//  same gun, same calibre, wrong game.  It is here anyway because Opposing
//  Force's has a laser sight (the `desert_eagle_sight` samples) that CS's does
//  not, and because leaving one alias standing in a set that retired the other
//  seven is how the next person concludes the alias block is still load-bearing.

// --- Ammo fields ---
.float mag_eagle;
.float ammo_eagle;

// --- Sequence indices, read out of svencoop/models/v_desert_eagle.mdl (11) ---
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).  NONE of the eleven carries STUDIO_LOOPING.
const float EAGLE_SEQ_IDLE1         = 0;   // idle1,         2.500 s (151f @ 60)
const float EAGLE_SEQ_IDLE2         = 1;   // idle2,         2.550 s (154f @ 60)
const float EAGLE_SEQ_IDLE3         = 2;   // idle3,         1.700 s (103f @ 60)
const float EAGLE_SEQ_IDLE4         = 3;   // idle4,         2.500 s (151f @ 60)
const float EAGLE_SEQ_IDLE5         = 4;   // idle5,         2.000 s (121f @ 60)
const float EAGLE_SEQ_SHOOT         = 5;   // shoot,         0.400 s  (25f @ 60)
const float EAGLE_SEQ_SHOOT_EMPTY   = 6;   // shoot_empty,   0.400 s  (25f @ 60)
const float EAGLE_SEQ_RELOAD        = 7;   // reload,        1.700 s (103f @ 60)
const float EAGLE_SEQ_RELOAD_NOSHOT = 8;   // reload_noshot, 1.583 s  (96f @ 60)
const float EAGLE_SEQ_DRAW          = 9;   // draw,          0.750 s  (46f @ 60)
const float EAGLE_SEQ_HOLSTER       = 10;  // holster — no holster state here

const float EAGLE_FRAME_INTERVAL = 0.05;

// No looping sequence in this model, so the idle has to be re-sent periodically
// or the viewmodel clamps to a still frame (gl_hlmdl.c:1076-1082).
const float EAGLE_IDLE_REARM_MIN = 10;
const float EAGLE_IDLE_REARM_MAX = 15;

const float EAGLE_FIRE_DELAY    = 0.25;   // semi-auto, heavy slide
const float EAGLE_DRYFIRE_DELAY = 0.2;

const float MAX_MAG_EAGLE  = 7;
const float MAX_AMMO_EAGLE = 36;

// --- Balance ---
// .357 out of a pistol: this mod's own WEP_357 is the reference, not CS's
// Deagle, because the pool it draws from (CAL_357) is HL's and the two guns
// should not disagree about what a .357 round does.
const float EAGLE_BASE_SPREAD          = 0.01;
const float EAGLE_MOVE_SPREAD          = 0.07;
const float EAGLE_FULL_SPREAD_SPEED    = 320;
const float EAGLE_CLOSE_DAMAGE         = 40;
const float EAGLE_MIN_DAMAGE           = 20;
const float EAGLE_DAMAGE_FALLOFF_RANGE = 2048;
const float EAGLE_KICK_PITCH    = 2.2;
const float EAGLE_KICK_VARIANCE = 0.4;
const float EAGLE_KICK_STRENGTH = 3.0;

const float EAGLE_MUZZLE_FORWARD = 26;
const float EAGLE_MUZZLE_RIGHT   = 4.0;
const float EAGLE_MUZZLE_DOWN    = 5.0;

// --- State durations, taken from the sequences themselves ---
const float EAGLE_DRAW_DURATION          = 0.750;
const float EAGLE_FIRE_DURATION          = 0.400;
const float EAGLE_RELOAD_DURATION        = 1.700;   // reload (slide locked back)
const float EAGLE_RELOAD_NOSHOT_DURATION = 1.583;   // reload_noshot (round chambered)

const string EAGLE_VIEWMODEL    = "models/v_desert_eagle.mdl";
const string EAGLE_WORLDMODEL   = "models/w_desert_eagle.mdl";
const string EAGLE_DEPLOY_SOUND = "weapons/desert_eagle_sight.wav";
const string EAGLE_DISPLAY_NAME = "DESERT EAGLE";

// ============================================================
//  SHARED — state machine
// ============================================================

// Which reload is playing, and therefore how long WS_RELOAD lasts.  Keyed off
// the magazine, which is replicated and reads the same on both sides, rather
// than .weaponframe, which no file under client/ can see.
float() SH_EagleReloadDuration =
{
    if (self.mag_eagle > 0)
        return EAGLE_RELOAD_NOSHOT_DURATION;
    return EAGLE_RELOAD_DURATION;
};

float(float now) SH_EagleTickState =
{
    float rel = SH_EagleReloadDuration();
    return SH_StandardTickState(now, mag_eagle, ammo_eagle, MAX_MAG_EAGLE,
        EAGLE_DRAW_DURATION, EAGLE_FIRE_DURATION, rel, rel);
};

float(float now) SH_EagleTryFire =
{
    return SH_StandardTryFire(now, mag_eagle, EAGLE_FIRE_DELAY, EAGLE_DRYFIRE_DELAY);
};

float(float now) SH_EagleTryReload =
{
    return SH_StandardTryReload(now, mag_eagle, ammo_eagle, MAX_MAG_EAGLE,
                                SH_EagleReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_EaglePickupCopy =
{
    player.mag_eagle  = self.mag_eagle;
    player.ammo_eagle = self.ammo_eagle;
};

void() W_EagleShoot =
{
    W_PenetratingHitscanShoot(EAGLE_BASE_SPREAD, EAGLE_MOVE_SPREAD, EAGLE_FULL_SPREAD_SPEED,
        EAGLE_CLOSE_DAMAGE, EAGLE_MIN_DAMAGE, EAGLE_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        EAGLE_KICK_PITCH, EAGLE_KICK_VARIANCE, EAGLE_KICK_STRENGTH);
};

void() W_EagleFire =
{
    float r = SH_EagleTryFire(time);

    if (r == 1)
    {
        // shoot_empty on the LAST round — the slide locks back, and playing the
        // wrong one leaves the gun visually loaded while the HUD reads 0.
        self.weaponframe   = (self.mag_eagle > 0) ? EAGLE_SEQ_SHOOT : EAGLE_SEQ_SHOOT_EMPTY;
        self.wep_nextframe = time + EAGLE_FRAME_INTERVAL;

        W_EagleShoot();

        sound(self, CHAN_WEAPON, "weapons/desert_eagle_fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RED, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_EagleReload =
{
    if (SH_EagleTryReload(time))
    {
        self.weaponframe   = (self.mag_eagle > 0) ? EAGLE_SEQ_RELOAD_NOSHOT : EAGLE_SEQ_RELOAD;
        self.wep_nextframe = time + EAGLE_FRAME_INTERVAL;
        sound(self, CHAN_AUTO, "weapons/desert_eagle_reload.wav", 1, ATTN_NORM);
    }
};

void() W_EagleFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += EAGLE_FRAME_INTERVAL;

    result = SH_EagleTickState(time);
    if (result & 1)
    {
        self.weaponframe   = EAGLE_SEQ_IDLE1;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_EagleEquip =
{
    W_StandardEquipSetup(EAGLE_VIEWMODEL, EAGLE_DISPLAY_NAME, EAGLE_SEQ_DRAW,
        EAGLE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_EagleFire;
    self.reload   = W_EagleReload;
    self.wepframe = W_EagleFrame;
    self.shoot    = W_EagleShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(EAGLE_BASE_SPREAD, EAGLE_MOVE_SPREAD, EAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_EagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_eagle  = self.mag_eagle;
    tgt.ammo_eagle = self.ammo_eagle;
    self.mag_eagle  = 0;
    self.ammo_eagle = 0;

    setmodel(tgt, EAGLE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_eagle";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_EAGLE;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_EagleEquip;
    tgt.weap_drop_func = W_EagleDrop;
    tgt.pickupcopy     = W_EaglePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_eagle =
{
    setmodel(self, EAGLE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_eagle";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_EAGLE;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_EagleEquip;
    self.weap_drop_func = W_EagleDrop;
    self.pickupcopy     = W_EaglePickupCopy;
    self.touch          = weapon_touch;
    self.mag_eagle      = MAX_MAG_EAGLE;
    self.ammo_eagle     = MAX_AMMO_EAGLE;
    W_RegisterMapWeapon(weapon_eagle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictEagleCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_EagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("weapons/desert_eagle_fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(EAGLE_BASE_SPREAD, EAGLE_MOVE_SPREAD, EAGLE_FULL_SPREAD_SPEED,
                    EAGLE_CLOSE_DAMAGE, EAGLE_MIN_DAMAGE, EAGLE_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    EAGLE_KICK_PITCH, EAGLE_KICK_VARIANCE, EAGLE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(EAGLE_MUZZLE_FORWARD, EAGLE_MUZZLE_RIGHT,
                    EAGLE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(EAGLE_MUZZLE_FORWARD, EAGLE_MUZZLE_RIGHT,
                    EAGLE_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    SH_EagleTickState(csqc_pred_time);
};

void() CSQC_PredictEagleReload =
{
    if (SH_EagleTryReload(csqc_pred_time))
    {
        if (!pm_suppress_sounds)
        {
            localsound("weapons/desert_eagle_reload.wav");
            CSQC_RecordPredictedAutoSound();
        }
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_EagleDisplayFrame =
{
    // FIRST, for every state — v_desert_eagle.mdl has no looping sequence, so
    // without this the gun freezes on a still frame.  Two of its five idles are
    // used as the pair; the other three are unreachable, which matches how the
    // rest of this tree treats a model with more fidgets than the machine has
    // slots for.
    float idle = SH_SeqIdleDisplay(cltime, WEP_EAGLE, predicted_player.weaponstate,
                                   EAGLE_SEQ_IDLE1, EAGLE_SEQ_IDLE3,
                                   EAGLE_IDLE_REARM_MIN, EAGLE_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return EAGLE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_eagle > 0) ? EAGLE_SEQ_SHOOT : EAGLE_SEQ_SHOOT_EMPTY;
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_eagle > 0) ? EAGLE_SEQ_RELOAD_NOSHOT : EAGLE_SEQ_RELOAD;
    return EAGLE_SEQ_IDLE1;
};

void() CSQC_EagleDropClear =
{
    self.mag_eagle  = 0;
    self.ammo_eagle = 0;
};

void() CSQC_EagleEquip =
{
    self.weapon_name         = EAGLE_DISPLAY_NAME;
    self.weapon_viewmodel    = EAGLE_VIEWMODEL;
    self.weapon_worldmodel   = EAGLE_WORLDMODEL;
    self.weapon_deploy_sound = EAGLE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictEagleCommand;
    self.csqc_predict_reload = CSQC_PredictEagleReload;
    self.csqc_display_frame  = CSQC_EagleDisplayFrame;
    self.csqc_drop_clear     = CSQC_EagleDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
