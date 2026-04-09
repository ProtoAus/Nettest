// ============================================================
//  shared/weapons/sh_wpn_scout.qc  -  CS Scout
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 30 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_scout;
.float ammo_scout;

// --- Animation frames ---
const float SCOUT_FRAME_INTERVAL      = 0.0333334;   // 1/30

const float SCOUT_DRAW_START          = 175;
const float SCOUT_DRAW_END            = 194;

const float SCOUT_FIRE_START          = 12;
const float SCOUT_FIRE_END            = 56;
const float SCOUT_FIRE_BOLT_FRAME     = 30;
const float SCOUT_FIRE_DELAY          = 1.0;

const float SCOUT_RELOAD_START        = 105;
const float SCOUT_RELOAD_END          = 163;
const float SCOUT_RELOAD_CLIPOUT      = 125;
const float SCOUT_RELOAD_CLIPIN       = 143;
const float SCOUT_RELOAD_APPLY        = 149;

const float SCOUT_IDLE_FRAME          = 1;

const float MAX_MAG_SCOUT             = 10;
const float MAX_AMMO_SCOUT            = 30;

// --- Balance ---
const float SCOUT_BASE_SPREAD          = 0.02;
const float SCOUT_MOVE_SPREAD          = 0.08;
const float SCOUT_FULL_SPREAD_SPEED    = 320;
const float SCOUT_CLOSE_DAMAGE         = 90;
const float SCOUT_MIN_DAMAGE           = 65;
const float SCOUT_DAMAGE_FALLOFF_RANGE = 4096;
const float SCOUT_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float SCOUT_DRAW_DURATION      = (SCOUT_DRAW_END - SCOUT_DRAW_START) * SCOUT_FRAME_INTERVAL;
const float SCOUT_FIRE_DURATION      = (SCOUT_FIRE_END - SCOUT_FIRE_START) * SCOUT_FRAME_INTERVAL;
const float SCOUT_RELOAD_DURATION    = (SCOUT_RELOAD_END - SCOUT_RELOAD_START) * SCOUT_FRAME_INTERVAL;
const float SCOUT_RELOAD_APPLY_TIME  = (SCOUT_RELOAD_APPLY - SCOUT_RELOAD_START) * SCOUT_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_ScoutTickState =
{
    float elapsed;
    float result;
    float needed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result = 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SCOUT_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SCOUT_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SCOUT_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_SCOUT - self.mag_scout;
            if (needed > 0)
            {
                if (self.ammo_scout >= needed)
                {
                    self.mag_scout  += needed;
                    self.ammo_scout -= needed;
                }
                else
                {
                    self.mag_scout  += self.ammo_scout;
                    self.ammo_scout  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= SCOUT_RELOAD_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

float(float now) SH_ScoutTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_scout <= 0)
    {
        self.attack_finished = now + SCOUT_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_scout       -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + SCOUT_FIRE_DELAY;
    self.zoomstage        = 0;   // unscope on fire
    return 1;
};

float(float now) SH_ScoutTryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.mag_scout >= MAX_MAG_SCOUT || self.ammo_scout <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.zoomstage       = 0;   // unscope on reload
    return 1;
};

float(float now) SH_ScoutTryAltFire =
{
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.attack_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_ScoutPickupCopy =
{
    player.mag_scout  = self.mag_scout;
    player.ammo_scout = self.ammo_scout;
};

void() W_ScoutShoot =
{
    vector src, dir, end;
    vector flat_vel;
    float  spread, sx, sy;
    float  move_speed, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    if (self.zoomstage > 0)
        spread = 0;
    else
    {
        spread = SCOUT_BASE_SPREAD + (move_speed / SCOUT_FULL_SPREAD_SPEED) * SCOUT_MOVE_SPREAD;
        spread = min(spread, SCOUT_BASE_SPREAD + SCOUT_MOVE_SPREAD);
    }

    sx  = (random() * 2 - 1) * spread;
    sy  = (random() * 2 - 1) * spread;
    dir = normalize(v_forward + v_right * sx + v_up * sy);
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);

        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist,
                SCOUT_CLOSE_DAMAGE, SCOUT_MIN_DAMAGE, SCOUT_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }
    }
};

void() W_ScoutFire =
{
    float r = SH_ScoutTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SCOUT_FIRE_START;
        self.wep_nextframe = time + SCOUT_FRAME_INTERVAL;

        W_ScoutShoot();
        self.sv_zoomstage = 0;

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csscout/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_ScoutAltFire =
{
    if (SH_ScoutTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_ScoutReload =
{
    if (SH_ScoutTryReload(time))
    {
        self.weaponframe   = SCOUT_RELOAD_START;
        self.wep_nextframe = time + SCOUT_FRAME_INTERVAL;
        self.sv_zoomstage  = 0;
    }
};

void() W_ScoutFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += SCOUT_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE && self.weaponframe == SCOUT_FIRE_BOLT_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/bolt.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == SCOUT_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == SCOUT_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csscout/clipin.wav", 1, ATTN_NORM);
    }

    result = SH_ScoutTickState(time);
    if (result & 1)
    {
        self.weaponframe   = SCOUT_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_ScoutEquip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_SCOUT);
    self.weapon_name    = "SCOUT";
    self.weapon_draw_start_frame = SCOUT_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire           = W_ScoutFire;
    self.reload         = W_ScoutReload;
    self.wepframe       = W_ScoutFrame;
    self.altfire         = W_ScoutAltFire;
    self.altrelease      = __NULL__;
    self.shoot           = W_ScoutShoot;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = SCOUT_DRAW_START;
    self.wep_nextframe  = time + SCOUT_FRAME_INTERVAL;
    W_ClearZoom();
    W_SetCrosshairProfile(SCOUT_BASE_SPREAD, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED, 1.45, FALSE);
};

void() W_ScoutDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_scout  = self.mag_scout;
    tgt.ammo_scout = self.ammo_scout;

    self.mag_scout  = 0;
    self.ammo_scout = 0;

    setmodel(tgt, "models/weapons/wpn_csscout/w_scout.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_scout";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_SCOUT;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_ScoutEquip;
    tgt.weap_drop_func = W_ScoutDrop;
    tgt.pickupcopy   = W_ScoutPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_scout =
{
    setmodel(self, "models/weapons/wpn_csscout/w_scout.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_scout";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_SCOUT;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_ScoutEquip;
    self.weap_drop_func = W_ScoutDrop;
    self.pickupcopy    = W_ScoutPickupCopy;
    self.touch         = weapon_touch;
    self.mag_scout     = MAX_MAG_SCOUT;
    self.ammo_scout    = MAX_AMMO_SCOUT;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_scout_reload_snd_stage;
float csqc_scout_bolt_played;

const float SCOUT_FIRE_BOLT_TIME = (SCOUT_FIRE_BOLT_FRAME - SCOUT_FIRE_START) * SCOUT_FRAME_INTERVAL;
const float SCOUT_RELOAD_CLIPOUT_TIME = (SCOUT_RELOAD_CLIPOUT - SCOUT_RELOAD_START) * SCOUT_FRAME_INTERVAL;
const float SCOUT_RELOAD_CLIPIN_TIME = (SCOUT_RELOAD_CLIPIN - SCOUT_RELOAD_START) * SCOUT_FRAME_INTERVAL;

void() CSQC_PredictScoutCommand =
{
    float r;

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_ScoutTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_csawp/zoom.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_ScoutTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_scout_bolt_played = FALSE;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csscout/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(SCOUT_BASE_SPREAD, SCOUT_MOVE_SPREAD, SCOUT_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Predicted bolt sound during fire cycle
    if (self.weaponstate == WS_FIRE && !csqc_scout_bolt_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= SCOUT_FIRE_BOLT_TIME)
        {
            localsound("sounds/weapons/wpn_csscout/bolt.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_scout_bolt_played = TRUE;
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;

        if (csqc_scout_reload_snd_stage < 1 && reload_elapsed >= SCOUT_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csscout/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_scout_reload_snd_stage = 1;
        }
        if (csqc_scout_reload_snd_stage < 2 && reload_elapsed >= SCOUT_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csscout/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_scout_reload_snd_stage = 2; }
    }

    SH_ScoutTickState(csqc_pred_time);
};

void() CSQC_PredictScoutReload =
{
    if (SH_ScoutTryReload(csqc_pred_time))
    {
        csqc_scout_reload_snd_stage = 0;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_ScoutDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = SCOUT_DRAW_START + elapsed / SCOUT_FRAME_INTERVAL;
        return bound(SCOUT_DRAW_START, frame, SCOUT_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = SCOUT_FIRE_START + elapsed / SCOUT_FRAME_INTERVAL;
        return bound(SCOUT_FIRE_START, frame, SCOUT_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = SCOUT_RELOAD_START + elapsed / SCOUT_FRAME_INTERVAL;
        return bound(SCOUT_RELOAD_START, frame, SCOUT_RELOAD_END - 1);
    }
    return SCOUT_IDLE_FRAME;
};

#endif // CSQC
