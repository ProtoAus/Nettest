// ============================================================
//  shared/weapons/sh_wpn_thtommygun.qc  -  They Hunger Thompson M1921
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round drum, 250 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_tommygun.as (what
//  the campaign runs) and hunger/weapons/tommygun/v_tommygun.mdl (sequence
//  indices, frame counts, frame rates).  Previously a pickup alias onto
//  WEP_HLSMG — a Half-Life MP5 wearing a Thompson world model, with an M203
//  it does not have.  See sh_wpn_th1911.qc for the full note on that.

// --- Ammo fields ---
.float mag_thtommy;
.float ammo_thtommy;

// Server-side reload sound latch; CSQC keeps its own single global.
.float thtommy_reload_snd_stage;

// --- Sequence indices, out of hunger/weapons/tommygun/v_tommygun.mdl (8) ----
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what the engine reports through frameduration()
// (gl_hlmdl.c:1542) — an N-frame animation spans N-1 intervals.
//
// Indices match TheyHungerTHOMPSONM1Animation_e (weapon_tommygun.as:18-28)
// one for one.  NONE of the eight carries STUDIO_LOOPING.
const float THTOMMY_SEQ_LONGIDLE      = 0;   // longidle,     5.000 s  (301f @ 60)
const float THTOMMY_SEQ_IDLE          = 1;   // idle1,        3.000 s  (181f @ 60)
const float THTOMMY_SEQ_RELOAD_EMPTY  = 2;   // reload_empty, 2.067 s  (125f @ 60)
const float THTOMMY_SEQ_RELOAD        = 3;   // reload,       1.550 s  ( 94f @ 60)
const float THTOMMY_SEQ_DEPLOY        = 4;   // deploy,       0.600 s  ( 31f @ 50)
const float THTOMMY_SEQ_SHOOT1        = 5;   // shoot_1,      0.500 s  ( 31f @ 60)
const float THTOMMY_SEQ_SHOOT2        = 6;   // shoot_2,      0.500 s  ( 31f @ 60)
const float THTOMMY_SEQ_SHOOT3        = 7;   // shoot_3,      0.500 s  ( 31f @ 60)

const float THTOMMY_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
const float THTOMMY_FIRE_DELAY        = 0.09;   // weapon_tommygun.as:143 — 11 rounds/s

// Idle re-send cadence — weapon_tommygun.as:164 (10..15 after a shot).  The
// model has no looping sequence, so SH_SeqIdleDisplay has to re-send or the
// viewmodel clamps to a still frame (gl_hlmdl.c:1076-1082).
const float THTOMMY_IDLE_REARM_MIN    = 10;
const float THTOMMY_IDLE_REARM_MAX    = 15;

// Reload sound instants, elapsed from wep_anim_start.  The empty variant runs
// half a second longer because it also has to pull the bolt back.
const float THTOMMY_RELOAD_MAGOUT_TIME = 0.300;
const float THTOMMY_RELOAD_MAGIN_TIME  = 1.100;
const float THTOMMY_RELOAD_BOLT_TIME   = 1.800;   // reload_empty only

const float MAX_MAG_THTOMMY           = 50;    // THOMPSON_MAX_CLIP,  weapon_tommygun.as:15
const float MAX_AMMO_THTOMMY          = 250;   // THOMPSON_MAX_CARRY, weapon_tommygun.as:13

// --- Balance ---
// weapon_tommygun.as:167 asks BulletAccuracy for one of three HL cone
// constants depending on how the player is moving: 4 degrees running,
// 2 walking, 1 standing still.  This mod expresses the same idea as a base
// spread that grows toward a move spread at FULL_SPREAD_SPEED, and HL's cone
// constants are already in this mod's units (they are the sine of the half
// angle per axis, util.h), so the endpoints transfer directly.
const float THTOMMY_BASE_SPREAD          = 0.00873;   // VECTOR_CONE_1DEGREES  (still)
const float THTOMMY_MOVE_SPREAD          = 0.03491;   // VECTOR_CONE_4DEGREES  (running)
const float THTOMMY_FULL_SPREAD_SPEED    = 320;
// RandomLong(10, 13) per bullet (:169) becomes this mod's falloff, top of the
// script's range at the muzzle to the bottom of it at range.
const float THTOMMY_CLOSE_DAMAGE         = 13;
const float THTOMMY_MIN_DAMAGE           = 10;
const float THTOMMY_DAMAGE_FALLOFF_RANGE = 2048;
const float THTOMMY_DRYFIRE_DELAY        = 0.2;
const float THTOMMY_KICK_PITCH    = 0.55;   // sv_gunkick — heavy gun, mild per-shot climb
const float THTOMMY_KICK_VARIANCE = 0.3;
const float THTOMMY_KICK_STRENGTH = 1.4;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float THTOMMY_MUZZLE_FORWARD = 44;
const float THTOMMY_MUZZLE_RIGHT   = 4.5;
const float THTOMMY_MUZZLE_DOWN    = 6.5;

// --- State durations, taken from the sequences themselves ---
const float THTOMMY_DRAW_DURATION         = 0.600;   // deploy
const float THTOMMY_FIRE_DURATION         = 0.500;   // shoot_1/2/3 (all the same length)
const float THTOMMY_RELOAD_DURATION       = 1.550;   // reload
const float THTOMMY_RELOAD_EMPTY_DURATION = 2.067;   // reload_empty

const string THTOMMY_VIEWMODEL    = "models/hunger/weapons/tommygun/v_tommygun.mdl";
const string THTOMMY_WORLDMODEL   = "models/hunger/weapons/tommygun/w_tommygun.mdl";
const string THTOMMY_DEPLOY_SOUND = "";
const string THTOMMY_DISPLAY_NAME = "TOMMYGUN";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// The model carries three shoot sequences and the script picks one per shot
// at random (weapon_tommygun.as:154, SHOOT1 + RandomLong(0, 2)).  A raw
// random() would roll independently on each side and leave the predicted
// viewmodel playing a different variant from the one the server recorded, so
// this cycles off wep_action_id instead — bumped once per shot on both sides
// by SH_StandardTryFire, and REWOUND to the server's value at reconcile
// (sh_customdefs.qc:454).  Visually indistinguishable from random; the three
// differ only in barrel shake.
//
// No `%` operator exists in this codebase; `x - floor(x/n)*n` is the
// established fmod idiom (sh_pmove.qc:2578).
float(float shot_id) SH_THTommyPickShootSeq =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return THTOMMY_SEQ_SHOOT1;
    if (n == 1) return THTOMMY_SEQ_SHOOT2;
    return THTOMMY_SEQ_SHOOT3;
};

// Which reload is playing, and therefore how long WS_RELOAD lasts.  Keyed off
// the magazine rather than .weaponframe: no file under client/ reads
// .weaponframe, while mag_thtommy is replicated and reads the same on both
// sides, and it cannot flip mid-reload (the transfer happens at
// reload_apply_time, which is the instant the state ends).
float() SH_THTommyReloadDuration =
{
    if (self.mag_thtommy > 0)
        return THTOMMY_RELOAD_DURATION;
    return THTOMMY_RELOAD_EMPTY_DURATION;
};

float(float now) SH_THTommyTickState =
{
    float rel = SH_THTommyReloadDuration();
    return SH_StandardTickState(now, mag_thtommy, ammo_thtommy, MAX_MAG_THTOMMY,
        THTOMMY_DRAW_DURATION, THTOMMY_FIRE_DURATION, rel, rel);
};

float(float now) SH_THTommyTryFire =
{
    return SH_StandardTryFire(now, mag_thtommy, THTOMMY_FIRE_DELAY, THTOMMY_DRYFIRE_DELAY);
};

float(float now) SH_THTommyTryReload =
{
    return SH_StandardTryReload(now, mag_thtommy, ammo_thtommy, MAX_MAG_THTOMMY,
                                SH_THTommyReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THTommyPickupCopy =
{
    player.mag_thtommy  = self.mag_thtommy;
    player.ammo_thtommy = self.ammo_thtommy;
};

void() W_THTommyShoot =
{
    W_PenetratingHitscanShoot(THTOMMY_BASE_SPREAD, THTOMMY_MOVE_SPREAD, THTOMMY_FULL_SPREAD_SPEED,
        THTOMMY_CLOSE_DAMAGE, THTOMMY_MIN_DAMAGE, THTOMMY_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        THTOMMY_KICK_PITCH, THTOMMY_KICK_VARIANCE, THTOMMY_KICK_STRENGTH);
};

void() W_THTommyFire =
{
    float r = SH_THTommyTryFire(time);

    if (r == 1)
    {
        // SH_StandardTryFire has already bumped wep_action_id
        // (sh_weapon_standard.qc:227), so this seeds off the new shot's id and
        // CSQC_THTommyDisplayFrame reproduces the same pick from the same id.
        self.weaponframe   = SH_THTommyPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + THTOMMY_FRAME_INTERVAL;

        W_THTommyShoot();

        sound(self, CHAN_WEAPON, "hunger/weapons/tommygun/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THTommyReload =
{
    if (SH_THTommyTryReload(time))
    {
        self.weaponframe   = (self.mag_thtommy > 0) ? THTOMMY_SEQ_RELOAD
                                                    : THTOMMY_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = time + THTOMMY_FRAME_INTERVAL;
        self.thtommy_reload_snd_stage = 0;
    }
};

void() W_THTommyFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THTOMMY_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        if (self.thtommy_reload_snd_stage < 1 && reload_elapsed >= THTOMMY_RELOAD_MAGOUT_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/tommygun/M1921_magout.wav", 1, ATTN_NORM);
            self.thtommy_reload_snd_stage = 1;
        }
        if (self.thtommy_reload_snd_stage < 2 && reload_elapsed >= THTOMMY_RELOAD_MAGIN_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/tommygun/M1921_magin.wav", 1, ATTN_NORM);
            self.thtommy_reload_snd_stage = 2;
        }
        // The bolt only gets pulled on the empty reload.
        if (self.thtommy_reload_snd_stage < 3 && reload_elapsed >= THTOMMY_RELOAD_BOLT_TIME
            && self.weaponframe == THTOMMY_SEQ_RELOAD_EMPTY)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/tommygun/M1921_boltback.wav", 1, ATTN_NORM);
            self.thtommy_reload_snd_stage = 3;
        }
    }

    result = SH_THTommyTickState(time);
    if (result & 1)
    {
        self.weaponframe = THTOMMY_SEQ_IDLE;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).  The
        // idle CYCLE is driven from CSQC_THTommyDisplayFrame.
        self.wep_nextframe = 0;
    }
};

void() W_THTommyEquip =
{
    W_StandardEquipSetup(THTOMMY_VIEWMODEL, THTOMMY_DISPLAY_NAME, THTOMMY_SEQ_DEPLOY,
        THTOMMY_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_THTommyFire;
    self.reload   = W_THTommyReload;
    self.wepframe = W_THTommyFrame;
    self.shoot    = W_THTommyShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(THTOMMY_BASE_SPREAD, THTOMMY_MOVE_SPREAD, THTOMMY_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_THTommyDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_thtommy  = self.mag_thtommy;
    tgt.ammo_thtommy = self.ammo_thtommy;

    self.mag_thtommy  = 0;
    self.ammo_thtommy = 0;

    setmodel(tgt, THTOMMY_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_tommygun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THTOMMY;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_THTommyEquip;
    tgt.weap_drop_func = W_THTommyDrop;
    tgt.pickupcopy     = W_THTommyPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thtommygun =
{
    setmodel(self, THTOMMY_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_tommygun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THTOMMY;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_THTommyEquip;
    self.weap_drop_func = W_THTommyDrop;
    self.pickupcopy     = W_THTommyPickupCopy;
    self.touch          = weapon_touch;
    self.mag_thtommy    = MAX_MAG_THTOMMY;
    self.ammo_thtommy   = MAX_AMMO_THTOMMY;
    W_RegisterMapWeapon(weapon_thtommygun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_thtommy_reload_snd_stage;

void() CSQC_PredictTHTommyCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_THTommyTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("hunger/weapons/tommygun/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(THTOMMY_BASE_SPREAD, THTOMMY_MOVE_SPREAD, THTOMMY_FULL_SPREAD_SPEED,
                    THTOMMY_CLOSE_DAMAGE, THTOMMY_MIN_DAMAGE, THTOMMY_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    THTOMMY_KICK_PITCH, THTOMMY_KICK_VARIANCE, THTOMMY_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THTOMMY_MUZZLE_FORWARD, THTOMMY_MUZZLE_RIGHT,
                    THTOMMY_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THTOMMY_MUZZLE_FORWARD, THTOMMY_MUZZLE_RIGHT,
                    THTOMMY_MUZZLE_DOWN, self.wep_action_id, 1);
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

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_thtommy_reload_snd_stage < 1 && reload_elapsed >= THTOMMY_RELOAD_MAGOUT_TIME)
        {
            localsound("hunger/weapons/tommygun/M1921_magout.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thtommy_reload_snd_stage = 1;
        }
        if (csqc_thtommy_reload_snd_stage < 2 && reload_elapsed >= THTOMMY_RELOAD_MAGIN_TIME)
        {
            localsound("hunger/weapons/tommygun/M1921_magin.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thtommy_reload_snd_stage = 2;
        }
        if (csqc_thtommy_reload_snd_stage < 3 && reload_elapsed >= THTOMMY_RELOAD_BOLT_TIME
            && self.mag_thtommy <= 0)
        {
            localsound("hunger/weapons/tommygun/M1921_boltback.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thtommy_reload_snd_stage = 3;
        }
    }

    SH_THTommyTickState(csqc_pred_time);
};

void() CSQC_PredictTHTommyReload =
{
    if (SH_THTommyTryReload(csqc_pred_time))
    { csqc_thtommy_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_THTommyDisplayFrame =
{
    // FIRST, for every state — SH_SeqIdleDisplay needs the non-idle frames to
    // catch the return-to-idle edge, and v_tommygun.mdl has no looping
    // sequence to fall back on.
    float idle = SH_SeqIdleDisplay(cltime, WEP_THTOMMY, predicted_player.weaponstate,
                                   THTOMMY_SEQ_IDLE, THTOMMY_SEQ_LONGIDLE,
                                   THTOMMY_IDLE_REARM_MIN, THTOMMY_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return THTOMMY_SEQ_DEPLOY;
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_THTommyPickShootSeq(predicted_player.wep_action_id);
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_thtommy > 0) ? THTOMMY_SEQ_RELOAD
                                                  : THTOMMY_SEQ_RELOAD_EMPTY;
    return THTOMMY_SEQ_IDLE;
};

void() CSQC_THTommyDropClear =
{
    self.mag_thtommy  = 0;
    self.ammo_thtommy = 0;
};

void() CSQC_THTommyEquip =
{
    self.weapon_name         = THTOMMY_DISPLAY_NAME;
    self.weapon_viewmodel    = THTOMMY_VIEWMODEL;
    self.weapon_worldmodel   = THTOMMY_WORLDMODEL;
    self.weapon_deploy_sound = THTOMMY_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHTommyCommand;
    self.csqc_predict_reload = CSQC_PredictTHTommyReload;
    self.csqc_display_frame  = CSQC_THTommyDisplayFrame;
    self.csqc_drop_clear     = CSQC_THTommyDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
