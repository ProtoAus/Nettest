// ============================================================
//  shared/weapons/sh_wpn_thgreasegun.qc  -  They Hunger M3 "Grease Gun"
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 250 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_greasegun.as and
//  hunger/weapons/greasegun/v_greasegun.mdl.  Previously a pickup alias onto
//  WEP_HLSMG — see sh_wpn_th1911.qc for the note on what that meant.

// --- Ammo fields ---
.float mag_thgrease;
.float ammo_thgrease;

// Server-side reload sound latch; CSQC keeps its own single global.
.float thgrease_reload_snd_stage;

// --- Sequence indices, out of hunger/weapons/greasegun/v_greasegun.mdl (8) --
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps — what frameduration() reports (gl_hlmdl.c:1542) —
// because an N-frame animation spans N-1 intervals.
//
// Indices match TheyHungerM3GREASEGUNAnimation_e (weapon_greasegun.as:18-28).
// NONE of the eight carries STUDIO_LOOPING.
const float THGREASE_SEQ_LONGIDLE      = 0;   // longidle,    3.000 s  (91f @ 30)
const float THGREASE_SEQ_IDLE          = 1;   // idle,        2.000 s  (61f @ 30)
const float THGREASE_SEQ_RELOAD        = 2;   // reload,      2.000 s  (61f @ 30)
const float THGREASE_SEQ_RELOAD_EMPTY  = 3;   // reloadempty, 3.000 s  (91f @ 30)
const float THGREASE_SEQ_DRAW          = 4;   // draw,        1.000 s  (31f @ 30)
const float THGREASE_SEQ_SHOOT1        = 5;   // fire1,       1.000 s  (31f @ 30)
const float THGREASE_SEQ_SHOOT2        = 6;   // fire2,       1.000 s  (31f @ 30)
const float THGREASE_SEQ_SHOOT3        = 7;   // fire3,       1.000 s  (31f @ 30)

const float THGREASE_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
const float THGREASE_FIRE_DELAY        = 0.147;  // weapon_greasegun.as:139 — the M3's famously slow cyclic rate

// Idle re-send cadence — weapon_greasegun.as:178.  No looping sequence exists
// in this model, so SH_SeqIdleDisplay has to re-send one or the viewmodel
// clamps to a still frame (gl_hlmdl.c:1076-1082).
const float THGREASE_IDLE_REARM_MIN    = 10;
const float THGREASE_IDLE_REARM_MAX    = 15;

// Reload sound instants, elapsed from wep_anim_start.  The empty variant runs
// a second longer because it also cycles the bolt.
const float THGREASE_RELOAD_MAGOUT_TIME = 0.350;
const float THGREASE_RELOAD_MAGIN_TIME  = 1.300;
const float THGREASE_RELOAD_BOLT_TIME   = 2.500;   // reloadempty only

const float MAX_MAG_THGREASE           = 20;    // GREASEGUN_MAX_CLIP,  weapon_greasegun.as:15
const float MAX_AMMO_THGREASE          = 250;   // GREASEGUN_MAX_CARRY, weapon_greasegun.as:13

// --- Balance ---
// weapon_greasegun.as:182 fires VECTOR_CONE_3DEGREES flat — no accuracy
// stance switch, unlike the Thompson.  HL's cone constants are the sine of the
// half angle per axis and this mod's spread scales v_right/v_up the same way,
// so the constant carries across unchanged; the move spread is this mod's own
// addition, kept modest because the script does not widen at all.
const float THGREASE_BASE_SPREAD          = 0.02618;   // VECTOR_CONE_3DEGREES
const float THGREASE_MOVE_SPREAD          = 0.06;
const float THGREASE_FULL_SPREAD_SPEED    = 320;
// :182 fires BULLET_PLAYER_MP5, i.e. the same skill value the Half-Life MP5
// uses — so this takes WEP_HLSMG's numbers rather than inventing new ones.
const float THGREASE_CLOSE_DAMAGE         = 10;
const float THGREASE_MIN_DAMAGE           = 5;
const float THGREASE_DAMAGE_FALLOFF_RANGE = 2048;
const float THGREASE_DRYFIRE_DELAY        = 0.2;
const float THGREASE_KICK_PITCH    = 0.65;   // sv_gunkick
const float THGREASE_KICK_VARIANCE = 0.3;
const float THGREASE_KICK_STRENGTH = 1.5;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float THGREASE_MUZZLE_FORWARD = 40;
const float THGREASE_MUZZLE_RIGHT   = 4.5;
const float THGREASE_MUZZLE_DOWN    = 6.5;

// --- State durations, taken from the sequences themselves ---
const float THGREASE_DRAW_DURATION         = 1.000;   // draw
const float THGREASE_FIRE_DURATION         = 1.000;   // fire1/2/3 (all the same length)
const float THGREASE_RELOAD_DURATION       = 2.000;   // reload
const float THGREASE_RELOAD_EMPTY_DURATION = 3.000;   // reloadempty

const string THGREASE_VIEWMODEL    = "models/hunger/weapons/greasegun/v_greasegun.mdl";
const string THGREASE_WORLDMODEL   = "models/hunger/weapons/greasegun/w_greasegun.mdl";
const string THGREASE_DEPLOY_SOUND = "";
const string THGREASE_DISPLAY_NAME = "GREASE GUN";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// Three fire sequences, cycled off wep_action_id rather than rolled, so the
// predicted viewmodel and the server's .weaponframe agree — see the longer
// note on the same helper in sh_wpn_thtommygun.qc.  `x - floor(x/n)*n` is this
// codebase's fmod idiom (sh_pmove.qc:2578); there is no `%` operator.
float(float shot_id) SH_THGreasePickShootSeq =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return THGREASE_SEQ_SHOOT1;
    if (n == 1) return THGREASE_SEQ_SHOOT2;
    return THGREASE_SEQ_SHOOT3;
};

// Which reload is playing, and therefore how long WS_RELOAD lasts.  Keyed off
// the magazine, which is replicated and reads the same on both sides, rather
// than .weaponframe, which no file under client/ can see.
float() SH_THGreaseReloadDuration =
{
    if (self.mag_thgrease > 0)
        return THGREASE_RELOAD_DURATION;
    return THGREASE_RELOAD_EMPTY_DURATION;
};

float(float now) SH_THGreaseTickState =
{
    float rel = SH_THGreaseReloadDuration();
    return SH_StandardTickState(now, mag_thgrease, ammo_thgrease, MAX_MAG_THGREASE,
        THGREASE_DRAW_DURATION, THGREASE_FIRE_DURATION, rel, rel);
};

float(float now) SH_THGreaseTryFire =
{
    return SH_StandardTryFire(now, mag_thgrease, THGREASE_FIRE_DELAY, THGREASE_DRYFIRE_DELAY);
};

float(float now) SH_THGreaseTryReload =
{
    return SH_StandardTryReload(now, mag_thgrease, ammo_thgrease, MAX_MAG_THGREASE,
                                SH_THGreaseReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THGreasePickupCopy =
{
    player.mag_thgrease  = self.mag_thgrease;
    player.ammo_thgrease = self.ammo_thgrease;
};

void() W_THGreaseShoot =
{
    W_PenetratingHitscanShoot(THGREASE_BASE_SPREAD, THGREASE_MOVE_SPREAD, THGREASE_FULL_SPREAD_SPEED,
        THGREASE_CLOSE_DAMAGE, THGREASE_MIN_DAMAGE, THGREASE_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        THGREASE_KICK_PITCH, THGREASE_KICK_VARIANCE, THGREASE_KICK_STRENGTH);
};

void() W_THGreaseFire =
{
    float r = SH_THGreaseTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_THGreasePickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + THGREASE_FRAME_INTERVAL;

        W_THGreaseShoot();

        sound(self, CHAN_WEAPON, "hunger/weapons/greasegun/M3_shoot1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THGreaseReload =
{
    if (SH_THGreaseTryReload(time))
    {
        self.weaponframe   = (self.mag_thgrease > 0) ? THGREASE_SEQ_RELOAD
                                                     : THGREASE_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = time + THGREASE_FRAME_INTERVAL;
        self.thgrease_reload_snd_stage = 0;
    }
};

void() W_THGreaseFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THGREASE_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        if (self.thgrease_reload_snd_stage < 1 && reload_elapsed >= THGREASE_RELOAD_MAGOUT_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/greasegun/M3_magout.wav", 1, ATTN_NORM);
            self.thgrease_reload_snd_stage = 1;
        }
        if (self.thgrease_reload_snd_stage < 2 && reload_elapsed >= THGREASE_RELOAD_MAGIN_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/greasegun/M3_magin.wav", 1, ATTN_NORM);
            self.thgrease_reload_snd_stage = 2;
        }
        if (self.thgrease_reload_snd_stage < 3 && reload_elapsed >= THGREASE_RELOAD_BOLT_TIME
            && self.weaponframe == THGREASE_SEQ_RELOAD_EMPTY)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/greasegun/M3_boltpull.wav", 1, ATTN_NORM);
            self.thgrease_reload_snd_stage = 3;
        }
    }

    result = SH_THGreaseTickState(time);
    if (result & 1)
    {
        self.weaponframe = THGREASE_SEQ_IDLE;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_THGreaseEquip =
{
    W_StandardEquipSetup(THGREASE_VIEWMODEL, THGREASE_DISPLAY_NAME, THGREASE_SEQ_DRAW,
        THGREASE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_THGreaseFire;
    self.reload   = W_THGreaseReload;
    self.wepframe = W_THGreaseFrame;
    self.shoot    = W_THGreaseShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(THGREASE_BASE_SPREAD, THGREASE_MOVE_SPREAD, THGREASE_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_THGreaseDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_thgrease  = self.mag_thgrease;
    tgt.ammo_thgrease = self.ammo_thgrease;

    self.mag_thgrease  = 0;
    self.ammo_thgrease = 0;

    setmodel(tgt, THGREASE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_greasegun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THGREASE;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_THGreaseEquip;
    tgt.weap_drop_func = W_THGreaseDrop;
    tgt.pickupcopy     = W_THGreasePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thgreasegun =
{
    setmodel(self, THGREASE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_greasegun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THGREASE;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_THGreaseEquip;
    self.weap_drop_func = W_THGreaseDrop;
    self.pickupcopy     = W_THGreasePickupCopy;
    self.touch          = weapon_touch;
    self.mag_thgrease   = MAX_MAG_THGREASE;
    self.ammo_thgrease  = MAX_AMMO_THGREASE;
    W_RegisterMapWeapon(weapon_thgreasegun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_thgrease_reload_snd_stage;

void() CSQC_PredictTHGreaseCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_THGreaseTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("hunger/weapons/greasegun/M3_shoot1.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(THGREASE_BASE_SPREAD, THGREASE_MOVE_SPREAD, THGREASE_FULL_SPREAD_SPEED,
                    THGREASE_CLOSE_DAMAGE, THGREASE_MIN_DAMAGE, THGREASE_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    THGREASE_KICK_PITCH, THGREASE_KICK_VARIANCE, THGREASE_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THGREASE_MUZZLE_FORWARD, THGREASE_MUZZLE_RIGHT,
                    THGREASE_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THGREASE_MUZZLE_FORWARD, THGREASE_MUZZLE_RIGHT,
                    THGREASE_MUZZLE_DOWN, self.wep_action_id, 1);
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
        if (csqc_thgrease_reload_snd_stage < 1 && reload_elapsed >= THGREASE_RELOAD_MAGOUT_TIME)
        {
            localsound("hunger/weapons/greasegun/M3_magout.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thgrease_reload_snd_stage = 1;
        }
        if (csqc_thgrease_reload_snd_stage < 2 && reload_elapsed >= THGREASE_RELOAD_MAGIN_TIME)
        {
            localsound("hunger/weapons/greasegun/M3_magin.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thgrease_reload_snd_stage = 2;
        }
        if (csqc_thgrease_reload_snd_stage < 3 && reload_elapsed >= THGREASE_RELOAD_BOLT_TIME
            && self.mag_thgrease <= 0)
        {
            localsound("hunger/weapons/greasegun/M3_boltpull.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thgrease_reload_snd_stage = 3;
        }
    }

    SH_THGreaseTickState(csqc_pred_time);
};

void() CSQC_PredictTHGreaseReload =
{
    if (SH_THGreaseTryReload(csqc_pred_time))
    { csqc_thgrease_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_THGreaseDisplayFrame =
{
    // FIRST, for every state — see sh_weapon_standard.qc.  v_greasegun.mdl has
    // no looping sequence, so without this the gun freezes on a still frame.
    float idle = SH_SeqIdleDisplay(cltime, WEP_THGREASE, predicted_player.weaponstate,
                                   THGREASE_SEQ_IDLE, THGREASE_SEQ_LONGIDLE,
                                   THGREASE_IDLE_REARM_MIN, THGREASE_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return THGREASE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_THGreasePickShootSeq(predicted_player.wep_action_id);
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_thgrease > 0) ? THGREASE_SEQ_RELOAD
                                                   : THGREASE_SEQ_RELOAD_EMPTY;
    return THGREASE_SEQ_IDLE;
};

void() CSQC_THGreaseDropClear =
{
    self.mag_thgrease  = 0;
    self.ammo_thgrease = 0;
};

void() CSQC_THGreaseEquip =
{
    self.weapon_name         = THGREASE_DISPLAY_NAME;
    self.weapon_viewmodel    = THGREASE_VIEWMODEL;
    self.weapon_worldmodel   = THGREASE_WORLDMODEL;
    self.weapon_deploy_sound = THGREASE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHGreaseCommand;
    self.csqc_predict_reload = CSQC_PredictTHGreaseReload;
    self.csqc_display_frame  = CSQC_THGreaseDisplayFrame;
    self.csqc_drop_clear     = CSQC_THGreaseDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
