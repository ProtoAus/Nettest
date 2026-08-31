// ============================================================
//  shared/weapons/sh_wpn_dodspring.qc  -  DoD M1903 Springfield
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round stripper clip, 25 reserve, bolt-action, telescopic sight
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : scope in / out (SCOPE_CLASS_SNIPER_BOLT)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON — models/v_spring.mdl, models/w_spring.mdl
//  and models/p_spring.mdl come from the mounted dod gamedir.
//
//  MEASURED FROM dod/models/v_spring.mdl — 7 sequences, 57 bones:
//
//   [0] idle        10fps  121f  12.100s
//   [1] shoot1      35fps   66f   1.886s
//         f1   5001 muzzleflash 41
//         f20  5004 "weapons/boltback.wav"     frac 0.303
//         f34  6002 shell eject 2              frac 0.515
//         f42  5004 "weapons/boltforward.wav"  frac 0.636
//   [2] shoot2      35fps   66f   1.886s   (identical events — a second take)
//   [3] reload      35fps   96f   2.743s
//         f4   5004 "weapons/boltback.wav"             frac 0.042
//         f53  5004 "weapons/tommy_reload_clipin.wav"  frac 0.552
//         f70  5004 "weapons/boltforward.wav"          frac 0.729
//   [4] draw        30fps   41f   1.367s
//         f1   5004 "weapons/rifleselect.wav"          frac 0.024
//   [5] empty_idle  30fps    2f   0.067s
//   [6] outofway    12fps    2f   0.167s   (a DoD team-play gesture; unused)
//
//  TWO SHOOT TAKES, unlike the scoped K98's one, and they carry identical events
//  — so alternating between them is purely visual variety and cannot desync the
//  audio.  Picked off wep_action_id so both sides land on the same take.
//
//  IT HAS AN `empty_idle` AND THE K98 DOES NOT, so this rifle can show its bolt
//  held open on the last round.  Wired: CSQC_DodSpringDisplayFrame picks it on a
//  zero magazine, which is the whole reason the sequence exists.
//
//  Fire sample is dod/sound/weapons/spring_shoot.wav — DoD-exclusive, and one of
//  the 175 files this mount actually wins.

// --- Ammo fields ---
.float mag_dodspring;
.float ammo_dodspring;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODSPRING_SEQ_IDLE       = 0;
const float DODSPRING_SEQ_SHOOT1     = 1;
const float DODSPRING_SEQ_SHOOT2     = 2;
const float DODSPRING_SEQ_RELOAD     = 3;
const float DODSPRING_SEQ_DRAW       = 4;
const float DODSPRING_SEQ_EMPTY_IDLE = 5;

const float DODSPRING_FRAME_INTERVAL = 0.0333334;
const float DODSPRING_FIRE_DELAY     = 1.70;
const float DODSPRING_DRYFIRE_DELAY  = 0.20;

const float DODSPRING_SHOOT_F_BOLTBACK  = 0.303;
const float DODSPRING_SHOOT_F_BOLTFWD   = 0.636;
const float DODSPRING_RELOAD_F_BOLTBACK = 0.042;
const float DODSPRING_RELOAD_F_CLIPIN   = 0.552;
const float DODSPRING_RELOAD_F_BOLTFWD  = 0.729;
const float DODSPRING_DRAW_F_SELECT     = 0.024;

const float DODSPRING_IDLE_REARM_MIN = 10;
const float DODSPRING_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODSPRING  = 5;
const float MAX_AMMO_DODSPRING = 25;

// --- Balance ---
//
// The Allied opposite number to the scoped K98 and deliberately its equal in
// damage — 80/60 over 4096, the same figures the unscoped K98 already carries in
// this tree.  Two rifles that face each other across a map should not differ in
// lethality; they differ in HANDLING, which is where the numbers actually move:
// the Springfield's bolt throw is a fraction slower (1.70 against 1.55) and its
// standing spread a touch tighter, because the '03 is the heavier, steadier
// rifle of the pair and DoD plays it that way.
const float DODSPRING_BASE_SPREAD          = 0.0035;
const float DODSPRING_MOVE_SPREAD          = 0.125;
const float DODSPRING_FULL_SPREAD_SPEED    = 300;
const float DODSPRING_CLOSE_DAMAGE         = 80;
const float DODSPRING_MIN_DAMAGE           = 60;
const float DODSPRING_DAMAGE_FALLOFF_RANGE = 4096;
const float DODSPRING_KICK_PITCH    = 3.1;
const float DODSPRING_KICK_VARIANCE = 0.6;
const float DODSPRING_KICK_STRENGTH = 1.5;

const float DODSPRING_MUZZLE_FORWARD = 54;
const float DODSPRING_MUZZLE_RIGHT   = 3;
const float DODSPRING_MUZZLE_DOWN    = 2;

const string DODSPRING_VIEWMODEL    = "models/v_spring.mdl";
const string DODSPRING_WORLDMODEL   = "models/w_spring.mdl";
const string DODSPRING_DEPLOY_SOUND = "";
const string DODSPRING_DISPLAY_NAME = "SPRINGFIELD";

.float dodspring_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodSpringSeqIdle      = { return SH_SeqForName(DODSPRING_VIEWMODEL, "idle",       DODSPRING_SEQ_IDLE); };
float() SH_DodSpringSeqEmptyIdle = { return SH_SeqForName(DODSPRING_VIEWMODEL, "empty_idle", DODSPRING_SEQ_EMPTY_IDLE); };
float() SH_DodSpringSeqReload    = { return SH_SeqForName(DODSPRING_VIEWMODEL, "reload",     DODSPRING_SEQ_RELOAD); };
float() SH_DodSpringSeqDraw      = { return SH_SeqForName(DODSPRING_VIEWMODEL, "draw",       DODSPRING_SEQ_DRAW); };

float(float action_id) SH_DodSpringSeqShoot =
{
    float n = action_id - floor(action_id / 2) * 2;
    if (n == 0)
        return SH_SeqForName(DODSPRING_VIEWMODEL, "shoot1", DODSPRING_SEQ_SHOOT1);
    return SH_SeqForName(DODSPRING_VIEWMODEL, "shoot2", DODSPRING_SEQ_SHOOT2);
};

float() SH_DodSpringDrawDuration   = { return SH_SeqDuration(DODSPRING_VIEWMODEL, SH_DodSpringSeqDraw(),   1.367); };
float() SH_DodSpringShootDuration  = { return SH_SeqDuration(DODSPRING_VIEWMODEL, SH_DodSpringSeqShoot(0), 1.886); };
float() SH_DodSpringReloadDuration = { return SH_SeqDuration(DODSPRING_VIEWMODEL, SH_DodSpringSeqReload(), 2.743); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_DodSpringTickState =
{
    float rel = SH_DodSpringReloadDuration();
    return SH_StandardTickState(now, mag_dodspring, ammo_dodspring, MAX_MAG_DODSPRING,
        SH_DodSpringDrawDuration(),
        SH_DodSpringShootDuration(),
        rel, rel * DODSPRING_RELOAD_F_CLIPIN);
};

float(float now) SH_DodSpringTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodspring, DODSPRING_FIRE_DELAY, DODSPRING_DRYFIRE_DELAY);
};

float(float now) SH_DodSpringTryReload =
{
    return SH_StandardTryReload(now, mag_dodspring, ammo_dodspring, MAX_MAG_DODSPRING,
        SH_DodSpringReloadDuration());
};

// Two stages only — the M84 sight is a single fixed magnification.  See the same
// note in sh_wpn_dodscoped98k.qc, including the sv_codscopes short-circuit.
float(float now) SH_DodSpringTryAltFire =
{
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    self.zoomstage = (self.zoomstage >= 1) ? 0 : 1;
    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodSpringPickupCopy =
{
    player.mag_dodspring  = self.mag_dodspring;
    player.ammo_dodspring = self.ammo_dodspring;
};

void() W_DodSpringShoot =
{
    W_PenetratingHitscanShoot(DODSPRING_BASE_SPREAD, DODSPRING_MOVE_SPREAD, DODSPRING_FULL_SPREAD_SPEED,
        DODSPRING_CLOSE_DAMAGE, DODSPRING_MIN_DAMAGE, DODSPRING_DAMAGE_FALLOFF_RANGE, 48, 0.90,
        DODSPRING_KICK_PITCH, DODSPRING_KICK_VARIANCE, DODSPRING_KICK_STRENGTH);
};

void() W_DodSpringFire =
{
    float r = SH_DodSpringTryFire(time);

    if (r == 1)
    {
        self.weaponframe         = SH_DodSpringSeqShoot(self.wep_action_id);
        self.wep_nextframe       = time + DODSPRING_FRAME_INTERVAL;
        self.dodspring_snd_stage = 0;

        W_DodSpringShoot();

        sound(self, CHAN_WEAPON, "weapons/spring_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodSpringAltFire =
{
    if (SH_DodSpringTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 1, ATTN_NORM);
    }
};

void() W_DodSpringReload =
{
    if (SH_DodSpringTryReload(time))
    {
        self.weaponframe         = SH_DodSpringSeqReload();
        self.wep_nextframe       = time + DODSPRING_FRAME_INTERVAL;
        self.dodspring_snd_stage = 0;
    }
};

void() W_DodSpringFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODSPRING_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodSpringDrawDuration() * DODSPRING_DRAW_F_SELECT
            && self.dodspring_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float sh = SH_DodSpringShootDuration();
        if (elapsed >= sh * DODSPRING_SHOOT_F_BOLTBACK && self.dodspring_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 1;
        }
        if (elapsed >= sh * DODSPRING_SHOOT_F_BOLTFWD && self.dodspring_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodSpringReloadDuration();

        if (elapsed >= rel * DODSPRING_RELOAD_F_BOLTBACK && self.dodspring_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/boltback.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 1;
        }
        if (elapsed >= rel * DODSPRING_RELOAD_F_CLIPIN && self.dodspring_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 2;
        }
        if (elapsed >= rel * DODSPRING_RELOAD_F_BOLTFWD && self.dodspring_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/boltforward.wav", 1, ATTN_NORM);
            self.dodspring_snd_stage = 3;
        }
    }

    float result = SH_DodSpringTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_DodSpringSeqIdle();
        self.wep_nextframe       = 0;
        self.dodspring_snd_stage = 0;
    }
};

void() W_DodSpringEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodspring", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(DODSPRING_VIEWMODEL, DODSPRING_DISPLAY_NAME, SH_DodSpringSeqDraw(),
        DODSPRING_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodSpringFire;
    self.altfire  = W_DodSpringAltFire;
    self.reload   = W_DodSpringReload;
    self.wepframe = W_DodSpringFrame;
    self.shoot    = W_DodSpringShoot;
    self.dodspring_snd_stage = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(DODSPRING_BASE_SPREAD, DODSPRING_MOVE_SPREAD, DODSPRING_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_DodSpringDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodspring  = self.mag_dodspring;
    tgt.ammo_dodspring = self.ammo_dodspring;

    self.mag_dodspring  = 0;
    self.ammo_dodspring = 0;

    setmodel(tgt, DODSPRING_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_spring";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODSPRING;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodSpringEquip;
    tgt.weap_drop_func = W_DodSpringDrop;
    tgt.pickupcopy     = W_DodSpringPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_spring =
{
    setmodel(self, DODSPRING_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_spring";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODSPRING;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodSpringEquip;
    self.weap_drop_func = W_DodSpringDrop;
    self.pickupcopy     = W_DodSpringPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodspring  = MAX_MAG_DODSPRING;
    self.ammo_dodspring = MAX_AMMO_DODSPRING;
    W_RegisterMapWeapon(weapon_spring);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodspring_snd_stage;
float csqc_dodspring_snd_action;

void() CSQC_PredictDodSpringCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodspring_snd_action)
    {
        csqc_dodspring_snd_action = predicted_player.wep_action_id;
        csqc_dodspring_snd_stage  = 0;
    }

    // +attack2 — the LEGACY scope toggle, and it has to run here or it does not
    // happen at all on this side.  .zoomstage is deliberately client-LOCAL: the
    // reconcile block stopped writing it back with the rest of the fire-decision
    // state (client/cl_player.qc:1058, ":1144 zoomstage stays local"), so a
    // toggle that only ever ran in W_DodSpringAltFire never reached the copy the
    // renderer reads and the sight simply never came up.  Not "one round trip
    // late" — never.  The shared try-function's own 0.3 s altfire_finished gate
    // is the debounce, so no press latch is needed.
    //
    // It short-circuits under sv_codscopes (shipped 1 in cfg/server.cfg), where
    // cl_codscope.qc owns +attack2 outright — which is why this was invisible.
    if (input_buttons & 4)
    {
        if (SH_DodSpringTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (input_buttons & 1)
    {
        r = SH_DodSpringTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/spring_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODSPRING_BASE_SPREAD, DODSPRING_MOVE_SPREAD, DODSPRING_FULL_SPREAD_SPEED,
                    DODSPRING_CLOSE_DAMAGE, DODSPRING_MIN_DAMAGE, DODSPRING_DAMAGE_FALLOFF_RANGE, 48, 0.90,
                    DODSPRING_KICK_PITCH, DODSPRING_KICK_VARIANCE, DODSPRING_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODSPRING_MUZZLE_FORWARD, DODSPRING_MUZZLE_RIGHT,
                    DODSPRING_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODSPRING_MUZZLE_FORWARD, DODSPRING_MUZZLE_RIGHT,
                    DODSPRING_MUZZLE_DOWN, self.wep_action_id, 2);
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
            if (csqc_dodspring_snd_stage < 1
                && elapsed >= SH_DodSpringDrawDuration() * DODSPRING_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float sh = SH_DodSpringShootDuration();
            if (csqc_dodspring_snd_stage < 1 && elapsed >= sh * DODSPRING_SHOOT_F_BOLTBACK)
            {
                localsound("weapons/boltback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 1;
            }
            if (csqc_dodspring_snd_stage < 2 && elapsed >= sh * DODSPRING_SHOOT_F_BOLTFWD)
            {
                localsound("weapons/boltforward.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodSpringReloadDuration();
            if (csqc_dodspring_snd_stage < 1 && elapsed >= rel * DODSPRING_RELOAD_F_BOLTBACK)
            {
                localsound("weapons/boltback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 1;
            }
            if (csqc_dodspring_snd_stage < 2 && elapsed >= rel * DODSPRING_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 2;
            }
            if (csqc_dodspring_snd_stage < 3 && elapsed >= rel * DODSPRING_RELOAD_F_BOLTFWD)
            {
                localsound("weapons/boltforward.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodspring_snd_stage = 3;
            }
        }
    }

    SH_DodSpringTickState(csqc_pred_time);
};

void() CSQC_PredictDodSpringReload =
{
    if (SH_DodSpringTryReload(csqc_pred_time))
    {
        csqc_dodspring_snd_stage  = 0;
        csqc_dodspring_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodSpringDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodSpringSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodSpringSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodSpringSeqShoot(predicted_player.wep_action_id);

    // The bolt-open pose on an empty rifle — the reason the model carries
    // `empty_idle` at all.  Fed to SH_SeqIdleDisplay as BOTH takes so the
    // re-arm timer still runs on it: no DoD sequence carries the looping flag,
    // so an idle that is simply held freezes on its last frame.
    float e = (predicted_player.mag_dodspring <= 0)
              ? SH_DodSpringSeqEmptyIdle() : SH_DodSpringSeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODSPRING, predicted_player.weaponstate,
                                   e, e, DODSPRING_IDLE_REARM_MIN, DODSPRING_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;
    return e;
};

void() CSQC_DodSpringDropClear =
{
    self.mag_dodspring  = 0;
    self.ammo_dodspring = 0;
};

void() CSQC_DodSpringEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_dodspring", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = DODSPRING_DISPLAY_NAME;
    self.weapon_viewmodel    = DODSPRING_VIEWMODEL;
    self.weapon_worldmodel   = DODSPRING_WORLDMODEL;
    self.weapon_deploy_sound = DODSPRING_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodSpringCommand;
    self.csqc_predict_reload = CSQC_PredictDodSpringReload;
    self.csqc_display_frame  = CSQC_DodSpringDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodSpringDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
