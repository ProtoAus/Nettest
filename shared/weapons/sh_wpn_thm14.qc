// ============================================================
//  shared/weapons/sh_wpn_thm14.qc  -  They Hunger M14
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 15 reserve, semi-auto marksman rifle
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_m14.as and
//  hunger/weapons/m14/v_m14.mdl.  Previously a pickup alias onto WEP_CSAWP —
//  which at least got the scope and the 7.62 pool right, but handed you a
//  Counter-Strike AWP wearing an M14 world model.

// --- Ammo fields ---
.float mag_thm14;
.float ammo_thm14;

// Server-side reload sound latch; CSQC keeps its own single global.
.float thm14_reload_snd_stage;

// --- Sequence indices, out of hunger/weapons/m14/v_m14.mdl (8 seqs) ---------
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// Indices match TheyHungerM14Animation_e (weapon_m14.as:18-28).  NONE of the
// eight carries STUDIO_LOOPING.
const float THM14_SEQ_IDLE1         = 0;   // idle1,        3.333 s  (101f @ 30)
const float THM14_SEQ_IDLE2         = 1;   // idle2,        3.333 s  (101f @ 30)
const float THM14_SEQ_IDLE3         = 2;   // idle3,        3.333 s  (101f @ 30)
const float THM14_SEQ_SHOOT         = 3;   // shoot,        1.000 s  ( 61f @ 60)
const float THM14_SEQ_SHOOT_LAST    = 4;   // shoot_last,   1.000 s  ( 61f @ 60)  (bolt holds open)
const float THM14_SEQ_RELOAD        = 5;   // reload,       3.000 s  ( 91f @ 30)
const float THM14_SEQ_RELOAD_EMPTY  = 6;   // reload_empty, 4.000 s  (121f @ 30)
const float THM14_SEQ_DEPLOY        = 7;   // deploy,       0.667 s  ( 21f @ 30)

const float THM14_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
const float THM14_FIRE_DELAY        = 0.25;   // weapon_m14.as:246

// Idle re-send cadence — weapon_m14.as:280.  No looping sequence exists in
// this model, so SH_SeqIdleDisplay has to re-send one or the viewmodel clamps
// to a still frame (gl_hlmdl.c:1076-1082).
const float THM14_IDLE_REARM_MIN    = 10;
const float THM14_IDLE_REARM_MAX    = 15;

// Reload sound instants, elapsed from wep_anim_start.  The empty variant runs
// a second longer because it also drops the bolt on a fresh magazine.
const float THM14_RELOAD_MAGOUT_TIME = 0.500;
const float THM14_RELOAD_MAGIN_TIME  = 1.900;
const float THM14_RELOAD_BOLT_TIME   = 3.400;   // reload_empty only

const float MAX_MAG_THM14           = 10;   // M14_MAX_CLIP,  weapon_m14.as:15
// M14_MAX_CARRY is 15 (:13) — one and a half spare magazines, and that
// scarcity IS the weapon's balance against 55 damage a shot.  Kept as-is.
const float MAX_AMMO_THM14          = 15;

// --- Balance ---
// weapon_m14.as:262/:266 switches cone on the scope: VECTOR_CONE_5DEGREES from
// the hip, VECTOR_CONE_1DEGREES scoped.  HL's cone constants are the sine of
// the half angle per axis, which is the same unit this mod's spread argument
// uses, so both carry across unchanged.
const float THM14_BASE_SPREAD          = 0.04362;   // VECTOR_CONE_5DEGREES (hip)
const float THM14_SCOPED_SPREAD        = 0.00873;   // VECTOR_CONE_1DEGREES (scoped)
const float THM14_MOVE_SPREAD          = 0.09;
const float THM14_FULL_SPREAD_SPEED    = 320;
// :258 is a flat `int m_iBulletDamage = 55` — no roll, unlike the pistols.
// Expressed here as this mod's falloff with a narrow band, so the script's
// figure is what lands at any usable range for a marksman rifle.
const float THM14_CLOSE_DAMAGE         = 55;
const float THM14_MIN_DAMAGE           = 45;
const float THM14_DAMAGE_FALLOFF_RANGE = 4096;
const float THM14_DRYFIRE_DELAY        = 0.2;
const float THM14_KICK_PITCH    = 1.6;   // sv_gunkick — full-power rifle cartridge
const float THM14_KICK_VARIANCE = 0.4;
const float THM14_KICK_STRENGTH = 2.0;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float THM14_MUZZLE_FORWARD = 46;
const float THM14_MUZZLE_RIGHT   = 4.5;
const float THM14_MUZZLE_DOWN    = 6.5;

// --- State durations, taken from the sequences themselves ---
const float THM14_DRAW_DURATION         = 0.667;   // deploy
const float THM14_FIRE_DURATION         = 1.000;   // shoot / shoot_last
const float THM14_RELOAD_DURATION       = 3.000;   // reload
const float THM14_RELOAD_EMPTY_DURATION = 4.000;   // reload_empty

const string THM14_VIEWMODEL    = "models/hunger/weapons/m14/v_m14.mdl";
const string THM14_WORLDMODEL   = "models/hunger/weapons/m14/w_m14.mdl";
const string THM14_DEPLOY_SOUND = "";
const string THM14_DISPLAY_NAME = "M14";

// ============================================================
//  SHARED — state machine
// ============================================================

// Which reload is playing, and therefore how long WS_RELOAD lasts.  Keyed off
// the magazine, which is replicated and reads the same on both sides, rather
// than .weaponframe, which no file under client/ can see.
float() SH_THM14ReloadDuration =
{
    if (self.mag_thm14 > 0)
        return THM14_RELOAD_DURATION;
    return THM14_RELOAD_EMPTY_DURATION;
};

float(float now) SH_THM14TickState =
{
    float rel = SH_THM14ReloadDuration();
    return SH_StandardTickState(now, mag_thm14, ammo_thm14, MAX_MAG_THM14,
        THM14_DRAW_DURATION, THM14_FIRE_DURATION, rel, rel);
};

float(float now) SH_THM14TryFire =
{
    // Zoom is NOT cleared here — W_THM14Shoot reads it for the spread, and
    // unlike the AWP nothing clears it after the shot either: weapon_m14.as
    // never touches m_iCurrentMode in PrimaryAttack, so the M14 stays scoped
    // through fire.  That is why it is a SCOPE_CLASS_SNIPER_SEMI below.
    //
    // Semi-auto: the script's ItemPostFrame fires for as long as +attack is
    // held at one shot per 0.25 s, but every other marksman rifle in this mod
    // takes a fresh trigger press per shot, and at 10 rounds with a 15-round
    // reserve the difference is one held click emptying the gun.  Matching the
    // mod here rather than the script is a deliberate deviation.
    return SH_StandardTryFireSemiAuto(now, mag_thm14, THM14_FIRE_DELAY, THM14_DRYFIRE_DELAY);
};

float(float now) SH_THM14TryReload =
{
    float r = SH_StandardTryReload(now, mag_thm14, ammo_thm14, MAX_MAG_THM14,
                                   SH_THM14ReloadDuration());
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

// Two scope stages then back out, the cycle weapon_m14.as:30-35 declares as
// ZOOM_NOSCOPE / ZOOM_SCOPED / ZOOM_SCOPED_2X.  Identical in shape to the
// AWP's, so it is written the same way.
float(float now) SH_THM14TryAltFire =
{
    // sv_codscopes short-circuit — CoD mode owns scope visuals via
    // cl_codscope.qc; see SH_AWPTryAltFire for the full rationale.
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THM14PickupCopy =
{
    player.mag_thm14  = self.mag_thm14;
    player.ammo_thm14 = self.ammo_thm14;
};

void() W_THM14Shoot =
{
    float spread = (self.zoomstage > 0) ? THM14_SCOPED_SPREAD : THM14_BASE_SPREAD;
    W_PenetratingHitscanShoot(spread, THM14_MOVE_SPREAD, THM14_FULL_SPREAD_SPEED,
        THM14_CLOSE_DAMAGE, THM14_MIN_DAMAGE, THM14_DAMAGE_FALLOFF_RANGE, 64, 0.97,
        THM14_KICK_PITCH, THM14_KICK_VARIANCE, THM14_KICK_STRENGTH);
};

void() W_THM14Fire =
{
    float r = SH_THM14TryFire(time);

    if (r == 1)
    {
        // SH_StandardTryFire has already decremented, so mag == 0 here is the
        // last round — weapon_m14.as sends M14_SHOOT_LAST for it, which is the
        // take where the bolt locks open.
        self.weaponframe   = (self.mag_thm14 > 0) ? THM14_SEQ_SHOOT
                                                  : THM14_SEQ_SHOOT_LAST;
        self.wep_nextframe = time + THM14_FRAME_INTERVAL;

        W_THM14Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "hunger/weapons/m14/m14_shot1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "hunger/weapons/m14/m14_shot2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THM14AltFire =
{
    if (SH_THM14TryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "hunger/weapons/m14/m14_zoom.wav", 1, ATTN_NORM);
    }
};

void() W_THM14Reload =
{
    if (SH_THM14TryReload(time))
    {
        self.weaponframe   = (self.mag_thm14 > 0) ? THM14_SEQ_RELOAD
                                                  : THM14_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = time + THM14_FRAME_INTERVAL;
        self.thm14_reload_snd_stage = 0;
        self.sv_zoomstage  = 0;
    }
};

void() W_THM14Frame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THM14_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        if (self.thm14_reload_snd_stage < 1 && reload_elapsed >= THM14_RELOAD_MAGOUT_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m14/m14_magout.wav", 1, ATTN_NORM);
            self.thm14_reload_snd_stage = 1;
        }
        if (self.thm14_reload_snd_stage < 2 && reload_elapsed >= THM14_RELOAD_MAGIN_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m14/m14_magin.wav", 1, ATTN_NORM);
            self.thm14_reload_snd_stage = 2;
        }
        // The bolt is only locked back after a dry magazine, so only the empty
        // reload has to release it.
        if (self.thm14_reload_snd_stage < 3 && reload_elapsed >= THM14_RELOAD_BOLT_TIME
            && self.weaponframe == THM14_SEQ_RELOAD_EMPTY)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m14/m14_boltrelease.wav", 1, ATTN_NORM);
            self.thm14_reload_snd_stage = 3;
        }
    }

    result = SH_THM14TickState(time);
    if (result & 1)
    {
        self.weaponframe = THM14_SEQ_IDLE1;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_THM14Equip =
{
    W_SetADSProfile(FALSE, "cl_ads_m14", SCOPE_CLASS_SNIPER_SEMI);
    W_StandardEquipSetup(THM14_VIEWMODEL, THM14_DISPLAY_NAME, THM14_SEQ_DEPLOY,
        THM14_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_THM14Fire;
    self.altfire  = W_THM14AltFire;
    self.reload   = W_THM14Reload;
    self.wepframe = W_THM14Frame;
    self.shoot    = W_THM14Shoot;
    self.weapon_uses_sequences = TRUE;
    W_ClearZoom();
    W_SetCrosshairProfile(THM14_BASE_SPREAD, THM14_MOVE_SPREAD, THM14_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_THM14Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_thm14  = self.mag_thm14;
    tgt.ammo_thm14 = self.ammo_thm14;

    self.mag_thm14  = 0;
    self.ammo_thm14 = 0;

    setmodel(tgt, THM14_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_m14";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THM14;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_THM14Equip;
    tgt.weap_drop_func = W_THM14Drop;
    tgt.pickupcopy     = W_THM14PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thm14 =
{
    setmodel(self, THM14_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_m14";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THM14;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_THM14Equip;
    self.weap_drop_func = W_THM14Drop;
    self.pickupcopy     = W_THM14PickupCopy;
    self.touch          = weapon_touch;
    self.mag_thm14      = MAX_MAG_THM14;
    self.ammo_thm14     = MAX_AMMO_THM14;
    W_RegisterMapWeapon(weapon_thm14);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_thm14_reload_snd_stage;

void() CSQC_PredictTHM14Command =
{
    float r;

    if (input_buttons & 4)
    {
        if (SH_THM14TryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("hunger/weapons/m14/m14_zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_THM14TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    localsound("hunger/weapons/m14/m14_shot1.wav");
                else
                    localsound("hunger/weapons/m14/m14_shot2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(
                    (self.zoomstage > 0) ? THM14_SCOPED_SPREAD : THM14_BASE_SPREAD,
                    THM14_MOVE_SPREAD, THM14_FULL_SPREAD_SPEED,
                    THM14_CLOSE_DAMAGE, THM14_MIN_DAMAGE, THM14_DAMAGE_FALLOFF_RANGE, 64, 0.97,
                    THM14_KICK_PITCH, THM14_KICK_VARIANCE, THM14_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THM14_MUZZLE_FORWARD, THM14_MUZZLE_RIGHT,
                    THM14_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THM14_MUZZLE_FORWARD, THM14_MUZZLE_RIGHT,
                    THM14_MUZZLE_DOWN, self.wep_action_id, 3);
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
        if (csqc_thm14_reload_snd_stage < 1 && reload_elapsed >= THM14_RELOAD_MAGOUT_TIME)
        {
            localsound("hunger/weapons/m14/m14_magout.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm14_reload_snd_stage = 1;
        }
        if (csqc_thm14_reload_snd_stage < 2 && reload_elapsed >= THM14_RELOAD_MAGIN_TIME)
        {
            localsound("hunger/weapons/m14/m14_magin.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm14_reload_snd_stage = 2;
        }
        if (csqc_thm14_reload_snd_stage < 3 && reload_elapsed >= THM14_RELOAD_BOLT_TIME
            && self.mag_thm14 <= 0)
        {
            localsound("hunger/weapons/m14/m14_boltrelease.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm14_reload_snd_stage = 3;
        }
    }

    SH_THM14TickState(csqc_pred_time);
};

void() CSQC_PredictTHM14Reload =
{
    if (SH_THM14TryReload(csqc_pred_time))
    { csqc_thm14_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_THM14DisplayFrame =
{
    // FIRST, for every state — see sh_weapon_standard.qc.  v_m14.mdl has three
    // idles and not one of them loops, so without this the rifle freezes on a
    // still frame.
    float idle = SH_SeqIdleDisplay(cltime, WEP_THM14, predicted_player.weaponstate,
                                   THM14_SEQ_IDLE1, THM14_SEQ_IDLE2,
                                   THM14_IDLE_REARM_MIN, THM14_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return THM14_SEQ_DEPLOY;
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_thm14 > 0) ? THM14_SEQ_SHOOT
                                                : THM14_SEQ_SHOOT_LAST;
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_thm14 > 0) ? THM14_SEQ_RELOAD
                                                : THM14_SEQ_RELOAD_EMPTY;
    return THM14_SEQ_IDLE1;
};

void() CSQC_THM14DropClear =
{
    self.mag_thm14  = 0;
    self.ammo_thm14 = 0;
};

void() CSQC_THM14Equip =
{
    // MUST mirror W_THM14Equip's call.  weapon_scope_class is NOT replicated —
    // each VM sets it in its own equip, and CSQC_WeaponEquip resets all three
    // ADS fields to zero on every weapon change.  With this missing, the client
    // left the M14 at SCOPE_CLASS_NONE, so CodScope_Eligible() rejected it; and
    // because SH_THM14TryAltFire deliberately steps aside when sv_codscopes is
    // set (it is, in cfg/server.cfg), the legacy zoom never ran either.  Result:
    // +attack2 fell between the two systems and did nothing at all.
    W_SetADSProfile(FALSE, "cl_ads_m14", SCOPE_CLASS_SNIPER_SEMI);

    self.weapon_name         = THM14_DISPLAY_NAME;
    self.weapon_viewmodel    = THM14_VIEWMODEL;
    self.weapon_worldmodel   = THM14_WORLDMODEL;
    self.weapon_deploy_sound = THM14_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHM14Command;
    self.csqc_predict_reload = CSQC_PredictTHM14Reload;
    self.csqc_display_frame  = CSQC_THM14DisplayFrame;
    self.csqc_drop_clear     = CSQC_THM14DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
