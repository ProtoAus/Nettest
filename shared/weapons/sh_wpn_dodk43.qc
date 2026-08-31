// ============================================================
//  shared/weapons/sh_wpn_dodk43.qc  -  Day of Defeat Gewehr 43
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, semi-automatic 7.92x57 Mauser
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : rifle-butt smash (melee, WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_k43.mdl, models/w_k43.mdl,
// models/p_k43.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_k43.mdl:
//   [0] idle        8fps    2f  0.125s   -- a static pose, not a fidget
//   [1] shoot1     23fps   31f  1.304s   f1 5001 (flash) f1 6002 (shell)
//   [2] shoot2     23fps   31f  1.304s
//   [3] reload     23fps  102f  4.391s
//         f13 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1287
//         f51 5004 "weapons/tommy_reload_clipin.wav"    frac 0.5050
//         f72 5004 "weapons/tommy_draw_slideback.wav"   frac 0.7129
//   [4] draw       38fps   31f  0.789s   f1 5004 "weapons/rifleselect.wav"
//   [5] empty_idle 30fps    2f  0.033s
//   [6] smash      75fps   86f  1.133s
//
// THE RELOAD SOUNDS ARE THE MODEL'S OWN, and they are the Thompson's.  DoD does
// ship weapons/gewehr_reload_clipin.wav and _clipout.wav, which look like they
// belong here, but v_k43.mdl's events name the tommy_* set and the model is the
// authority on what plays and when -- that is the rule the rest of this tree
// follows and swapping them would be a guess dressed up as a fix.
//
// The Axis counterpart to the Garand: the same role, one more round, no ping,
// no empty-clip discard (it takes a detachable box magazine, so a partial
// reload keeps what is left).

// --- Ammo fields ---
.float mag_dodk43;
.float ammo_dodk43;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODK43_SEQ_IDLE   = 0;
const float DODK43_SEQ_SHOOT1 = 1;
const float DODK43_SEQ_SHOOT2 = 2;
const float DODK43_SEQ_RELOAD = 3;
const float DODK43_SEQ_DRAW   = 4;
const float DODK43_SEQ_SMASH  = 6;

const float DODK43_FRAME_INTERVAL = 0.0333334;
const float DODK43_FIRE_DELAY     = 0.28;
const float DODK43_DRYFIRE_DELAY  = 0.20;

const float DODK43_DRAW_F_SELECT    = 0.0333;   // frame 1  / 30
const float DODK43_RELOAD_F_CLIPOUT = 0.1287;   // frame 13 / 101
const float DODK43_RELOAD_F_CLIPIN  = 0.5050;   // frame 51 / 101
const float DODK43_RELOAD_F_BOLT    = 0.7129;   // frame 72 / 101
const float DODK43_RELOAD_F_APPLY   = 0.5500;   // just after the mag seats

const float DODK43_IDLE_REARM_MIN = 10;
const float DODK43_IDLE_REARM_MAX = 15;

const float DODK43_SMASH_DELAY  = 0.80;
const float DODK43_SMASH_DAMAGE = 55;
const float DODK43_SMASH_RANGE  = 80;
const float DODK43_SMASH_F_HIT  = 0.2500;

const float MAX_MAG_DODK43  = 10;
const float MAX_AMMO_DODK43 = 30;

// --- Balance ---
//
// Deliberately a hair under the Garand (62/44): 58/42 over the same 4096.  The
// two rifles do the same job and the K43 gets two more rounds in the magazine
// and a slightly quicker trigger (0.28 against 0.30), so it pays for that at
// the target.  Both sit far below the bolt-action K98's 80/60 -- semi-auto
// convenience is the thing being bought.
const float DODK43_BASE_SPREAD          = 0.0065;
const float DODK43_MOVE_SPREAD          = 0.080;
const float DODK43_FULL_SPREAD_SPEED    = 320;
const float DODK43_CLOSE_DAMAGE         = 58;
const float DODK43_MIN_DAMAGE           = 42;
const float DODK43_DAMAGE_FALLOFF_RANGE = 4096;
const float DODK43_KICK_PITCH    = 2.10;
const float DODK43_KICK_VARIANCE = 0.45;
const float DODK43_KICK_STRENGTH = 1.28;

const float DODK43_MUZZLE_FORWARD = 48;
const float DODK43_MUZZLE_RIGHT   = 3;
const float DODK43_MUZZLE_DOWN    = 2;

const string DODK43_VIEWMODEL    = "models/v_k43.mdl";
const string DODK43_WORLDMODEL   = "models/w_k43.mdl";
const string DODK43_DEPLOY_SOUND = "";
const string DODK43_DISPLAY_NAME = "Gewehr 43";

.float dodk43_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodK43SeqIdle   = { return SH_SeqForName(DODK43_VIEWMODEL, "idle",   DODK43_SEQ_IDLE); };
// The bolt-open rest pose the model carries and nothing was asking for — see the
// note in sh_wpn_dodmp40.qc; eight DoD weapons shared this gap.
const float DODK43_SEQ_EMPTY_IDLE = 5;
float() SH_DodK43SeqEmptyIdle = { return SH_SeqForName(DODK43_VIEWMODEL, "empty_idle", DODK43_SEQ_EMPTY_IDLE); };
float() SH_DodK43SeqShoot1 = { return SH_SeqForName(DODK43_VIEWMODEL, "shoot1", DODK43_SEQ_SHOOT1); };
float() SH_DodK43SeqShoot2 = { return SH_SeqForName(DODK43_VIEWMODEL, "shoot2", DODK43_SEQ_SHOOT2); };
float() SH_DodK43SeqReload = { return SH_SeqForName(DODK43_VIEWMODEL, "reload", DODK43_SEQ_RELOAD); };
float() SH_DodK43SeqDraw   = { return SH_SeqForName(DODK43_VIEWMODEL, "draw",   DODK43_SEQ_DRAW); };
float() SH_DodK43SeqSmash  = { return SH_SeqForName(DODK43_VIEWMODEL, "smash",  DODK43_SEQ_SMASH); };

float(float action_id) SH_DodK43PickShootSeq =
{
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodK43SeqShoot1() : SH_DodK43SeqShoot2();
};

float() SH_DodK43DrawDuration   = { return SH_SeqDuration(DODK43_VIEWMODEL, SH_DodK43SeqDraw(),   0.789); };
float() SH_DodK43ReloadDuration = { return SH_SeqDuration(DODK43_VIEWMODEL, SH_DodK43SeqReload(), 4.391); };
float() SH_DodK43SmashDuration  = { return SH_SeqDuration(DODK43_VIEWMODEL, SH_DodK43SeqSmash(),  1.133); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodK43TickState =
{
    float elapsed;
    float rel;

    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= SH_DodK43SmashDuration())
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    // Nothing here branches on the magazine (one reload take, one smash take,
    // two shoot takes picked by hash), so the rounds can land where they
    // physically do -- just after the fresh magazine seats.
    rel = SH_DodK43ReloadDuration();
    return SH_StandardTickState(now, mag_dodk43, ammo_dodk43, MAX_MAG_DODK43,
        SH_DodK43DrawDuration(),
        SH_SeqDuration(DODK43_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * DODK43_RELOAD_F_APPLY);
};

float(float now) SH_DodK43TryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_dodk43, DODK43_FIRE_DELAY, DODK43_DRYFIRE_DELAY);
};

float(float now) SH_DodK43TryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_dodk43, ammo_dodk43, MAX_MAG_DODK43,
        SH_DodK43ReloadDuration());
};

float(float now) SH_DodK43TrySmash =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished) return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + DODK43_SMASH_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodK43PickupCopy =
{
    player.mag_dodk43  = self.mag_dodk43;
    player.ammo_dodk43 = self.ammo_dodk43;
};

void() W_DodK43Shoot =
{
    W_PenetratingHitscanShoot(DODK43_BASE_SPREAD, DODK43_MOVE_SPREAD, DODK43_FULL_SPREAD_SPEED,
        DODK43_CLOSE_DAMAGE, DODK43_MIN_DAMAGE, DODK43_DAMAGE_FALLOFF_RANGE, 80, 0.98,
        DODK43_KICK_PITCH, DODK43_KICK_VARIANCE, DODK43_KICK_STRENGTH);
};

void() W_DodK43Smash =
{
    vector src, end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * DODK43_SMASH_RANGE;

    W_MeleeTrace(src, end);

    if (trace_fraction < 1.0)
    {
        sound(self, CHAN_WEAPON, "weapons/butt_hit.wav", 1, ATTN_NORM);
        if (W_CanDamageTarget(trace_ent))
        {
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
                W_ApplyDamage(self, trace_ent, DODK43_SMASH_DAMAGE);
        }
        else
            W_ImpactEffect(trace_endpos);
    }
};

void() W_DodK43Fire =
{
    float r = SH_DodK43TryFire(time);

    if (r == 1)
    {
        self.weaponframe      = SH_DodK43PickShootSeq(self.wep_action_id);
        self.wep_nextframe    = time + DODK43_FRAME_INTERVAL;
        self.dodk43_snd_stage = 0;

        W_DodK43Shoot();

        sound(self, CHAN_WEAPON, "weapons/k43_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

// Weapon special (impulse 7) — the rifle butt.  It used to be the ALT-FIRE, and
// that made the K43 an ADS-eligible rifle whose ADS button was taken: +attack2
// is the iron-sights button on every other DoD long arm (weapon_ads_eligible,
// set in the Equips below), and W_SetADSProfile has said TRUE here all along.
// Aiming is a far more common action than a butt-stroke, so the butt moved to
// the third weapon verb — the same call sh_wpn_dodscoped98k.qc made for its
// bayonet, and now sh_wpn_dod98k.qc for its.  Requested directly.
void() W_DodK43Special =
{
    if (SH_DodK43TrySmash(time))
    {
        self.weaponframe      = SH_DodK43SeqSmash();
        self.wep_nextframe    = time + DODK43_FRAME_INTERVAL;
        self.dodk43_snd_stage = 0;
    }
};

void() W_DodK43Reload =
{
    if (SH_DodK43TryReload(time))
    {
        self.weaponframe      = SH_DodK43SeqReload();
        self.wep_nextframe    = time + DODK43_FRAME_INTERVAL;
        self.dodk43_snd_stage = 0;
    }
};

void() W_DodK43Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODK43_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodK43DrawDuration() * DODK43_DRAW_F_SELECT
            && self.dodk43_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodk43_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodK43ReloadDuration();

        if (elapsed >= rel * DODK43_RELOAD_F_CLIPOUT && self.dodk43_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodk43_snd_stage = 1;
        }
        if (elapsed >= rel * DODK43_RELOAD_F_CLIPIN && self.dodk43_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodk43_snd_stage = 2;
        }
        if (elapsed >= rel * DODK43_RELOAD_F_BOLT && self.dodk43_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodk43_snd_stage = 3;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_DodK43SmashDuration() * DODK43_SMASH_F_HIT
            && self.dodk43_snd_stage < 1)
        {
            W_DodK43Smash();
            self.dodk43_snd_stage = 1;
        }
    }

    result = SH_DodK43TickState(time);
    if (result & 1)
    {
        self.weaponframe      = SH_DodK43SeqIdle();
        self.wep_nextframe    = 0;
        self.dodk43_snd_stage = 0;
    }
};

void() W_DodK43Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodk43", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODK43_VIEWMODEL, DODK43_DISPLAY_NAME, SH_DodK43SeqDraw(),
        DODK43_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodK43Fire;
    self.altfire  = __NULL__;            // +attack2 belongs to ADS now
    self.special  = W_DodK43Special;     // impulse 7 = rifle butt
    self.reload   = W_DodK43Reload;
    self.wepframe = W_DodK43Frame;
    self.shoot    = W_DodK43Shoot;
    self.dodk43_snd_stage = 0;
    W_SetCrosshairProfile(DODK43_BASE_SPREAD, DODK43_MOVE_SPREAD, DODK43_FULL_SPREAD_SPEED, 1.7, TRUE);
};

void() W_DodK43Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodk43  = self.mag_dodk43;
    tgt.ammo_dodk43 = self.ammo_dodk43;

    self.mag_dodk43  = 0;
    self.ammo_dodk43 = 0;

    setmodel(tgt, DODK43_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_gewehr";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODK43;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodK43Equip;
    tgt.weap_drop_func = W_DodK43Drop;
    tgt.pickupcopy     = W_DodK43PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// dod.fgd calls it weapon_gewehr, which is the German name for the rifle; the
// mod's display name and manifest key are "Gewehr 43" / "k43" to match what
// players call it.
void() weapon_gewehr =
{
    setmodel(self, DODK43_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_gewehr";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODK43;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodK43Equip;
    self.weap_drop_func = W_DodK43Drop;
    self.pickupcopy     = W_DodK43PickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodk43     = MAX_MAG_DODK43;
    self.ammo_dodk43    = MAX_AMMO_DODK43;
    W_RegisterMapWeapon(weapon_gewehr);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodk43_snd_stage;
float csqc_dodk43_snd_action;

void() CSQC_PredictDodK43Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodk43_snd_action)
    {
        csqc_dodk43_snd_action = predicted_player.wep_action_id;
        csqc_dodk43_snd_stage  = 0;
    }

    // NOTE: no `input_buttons & 4` branch any more.  +attack2 is the ADS button
    // and is consumed by the shared ADS envelope; the butt-stroke moved to
    // WEAPON_IMPULSE_SPECIAL and predicts through CSQC_PredictDodK43Special.

    if (input_buttons & 1)
    {
        r = SH_DodK43TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/k43_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODK43_BASE_SPREAD, DODK43_MOVE_SPREAD, DODK43_FULL_SPREAD_SPEED,
                    DODK43_CLOSE_DAMAGE, DODK43_MIN_DAMAGE, DODK43_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    DODK43_KICK_PITCH, DODK43_KICK_VARIANCE, DODK43_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODK43_MUZZLE_FORWARD, DODK43_MUZZLE_RIGHT,
                    DODK43_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODK43_MUZZLE_FORWARD, DODK43_MUZZLE_RIGHT,
                    DODK43_MUZZLE_DOWN, self.wep_action_id, 4);
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
            if (csqc_dodk43_snd_stage < 1
                && elapsed >= SH_DodK43DrawDuration() * DODK43_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodk43_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodK43ReloadDuration();

            if (csqc_dodk43_snd_stage < 1 && elapsed >= rel * DODK43_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodk43_snd_stage = 1;
            }
            if (csqc_dodk43_snd_stage < 2 && elapsed >= rel * DODK43_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodk43_snd_stage = 2;
            }
            if (csqc_dodk43_snd_stage < 3 && elapsed >= rel * DODK43_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodk43_snd_stage = 3;
            }
        }
    }

    SH_DodK43TickState(csqc_pred_time);
};

void() CSQC_PredictDodK43Reload =
{
    if (SH_DodK43TryReload(csqc_pred_time))
    {
        csqc_dodk43_snd_stage  = 0;
        csqc_dodk43_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Weapon special (impulse 7) — the butt-stroke, moved off +attack2.  Predicted
// exactly as the old alt-fire branch was: the swing state and its sound are
// local, the damage verdict stays the server's (CSQC_PredictedMeleeTrace does
// not apply damage).  Dispatched from CSQC_PredictWeaponImpulse in
// client/cl_weapons.qc — a prediction function that nothing calls is a function
// that silently does nothing, which is exactly how the scoped K98's bayonet
// ended up unpredicted.
void() CSQC_PredictDodK43Special =
{
    if (SH_DodK43TrySmash(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            CSQC_PredictedMeleeTrace(DODK43_SMASH_RANGE, DODK43_SMASH_DAMAGE,
                "weapons/butt_hit.wav", "", "");
            // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
            CSQC_RecordPredictedMeleeSound();
        }
    }
};

float(float elapsed) CSQC_DodK43DisplayFrame =
{
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodk43 <= 0)
              ? SH_DodK43SeqEmptyIdle() : SH_DodK43SeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODK43, predicted_player.weaponstate,
                                   e, e,
                                   DODK43_IDLE_REARM_MIN, DODK43_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodK43SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodK43SeqReload();
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodK43SeqSmash();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodK43PickShootSeq(predicted_player.wep_action_id);

    return e;
};

void() CSQC_DodK43DropClear =
{
    self.mag_dodk43  = 0;
    self.ammo_dodk43 = 0;
};

void() CSQC_DodK43Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodk43", SCOPE_CLASS_NONE);
    self.weapon_name         = DODK43_DISPLAY_NAME;
    self.weapon_viewmodel    = DODK43_VIEWMODEL;
    self.weapon_worldmodel   = DODK43_WORLDMODEL;
    self.weapon_deploy_sound = DODK43_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodK43Command;
    self.csqc_predict_reload = CSQC_PredictDodK43Reload;
    self.csqc_display_frame  = CSQC_DodK43DisplayFrame;
    self.csqc_drop_clear     = CSQC_DodK43DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
