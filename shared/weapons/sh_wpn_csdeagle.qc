// ============================================================
//  shared/weapons/sh_wpn_csdeagle.qc  -  Desert Eagle
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 35 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
//  Shared logic runs on both sides; #ifdef gates server-only
//  and client-only sections.
// ============================================================

// --- Ammo fields ---
.float mag_deagle;
.float ammo_deagle;

// --- Animation frames ---
const float DEAGLE_FIRE_DELAY        = 0.3;
const float DEAGLE_FRAME_INTERVAL    = 1/30;   // 1/30

const float DEAGLE_DRAW_START        = 151;
const float DEAGLE_DRAW_END          = 180;
const float DEAGLE_DRAW_SND_FRAME    = 155;

const float DEAGLE_FIRE_START        = 2;
const float DEAGLE_FIRE_END          = 32;

const float DEAGLE_RELOAD_START      = 84;
const float DEAGLE_RELOAD_END        = 148;
const float DEAGLE_RELOAD_CLIPOUT    = 87;
const float DEAGLE_RELOAD_CLIPIN     = 120;
const float DEAGLE_RELOAD_APPLY      = 140;

const float MAX_MAG_DEAGLE           = 7;
const float MAX_AMMO_DEAGLE          = 35;

// --- Balance ---
const float DEAGLE_BASE_SPREAD          = 0.008;
const float DEAGLE_MOVE_SPREAD          = 0.06;
const float DEAGLE_FULL_SPREAD_SPEED    = 320;
const float DEAGLE_CLOSE_DAMAGE         = 54;
const float DEAGLE_MIN_DAMAGE           = 34;
const float DEAGLE_DAMAGE_FALLOFF_RANGE = 4096;
const float DEAGLE_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float DEAGLE_DRAW_DURATION      = (DEAGLE_DRAW_END - DEAGLE_DRAW_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_FIRE_DURATION      = (DEAGLE_FIRE_END - DEAGLE_FIRE_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_DURATION    = (DEAGLE_RELOAD_END - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_APPLY_TIME  = (DEAGLE_RELOAD_APPLY - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine (server & client identical)
// ============================================================

// Returns bitmask: bit 0 = transitioned to idle, bit 1 = reload ammo applied
float(float now) SH_DeagleTickState =
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
        if (elapsed >= DEAGLE_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= DEAGLE_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= DEAGLE_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_DEAGLE - self.mag_deagle;
            if (needed > 0)
            {
                if (self.ammo_deagle >= needed)
                {
                    self.mag_deagle  += needed;
                    self.ammo_deagle -= needed;
                }
                else
                {
                    self.mag_deagle  += self.ammo_deagle;
                    self.ammo_deagle  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= DEAGLE_RELOAD_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

// Returns: 1 = fired, -1 = dry fire, 0 = blocked
float(float now) SH_DeagleTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_deagle <= 0)
    {
        self.attack_finished = now + DEAGLE_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_deagle      -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + DEAGLE_FIRE_DELAY;
    return 1;
};

// Returns: 1 = reload started, 0 = blocked
float(float now) SH_DeagleTryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.mag_deagle >= MAX_MAG_DEAGLE || self.ammo_deagle <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY — authoritative fire, reload, frame, equip,
//  pickup, drop, world entity
// ============================================================

#ifdef SSQC

void(entity player) W_DeaglePickupCopy =
{
    player.mag_deagle  = self.mag_deagle;
    player.ammo_deagle = self.ammo_deagle;
};

// Shoot — hitscan with lag compensation (self = player)
void() W_DeagleShoot =
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

    spread = DEAGLE_BASE_SPREAD + (move_speed / DEAGLE_FULL_SPREAD_SPEED) * DEAGLE_MOVE_SPREAD;
    spread = min(spread, DEAGLE_BASE_SPREAD + DEAGLE_MOVE_SPREAD);

    sx  = (random() * 2 - 1) * spread;
    sy  = (random() * 2 - 1) * spread;
    dir = normalize(v_forward + v_right * sx + v_up * sy);
    end = src + dir * 8192;

    traceline(src, end, MOVE_NORMAL | MOVE_LAGGED, self);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);

        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist,
                DEAGLE_CLOSE_DAMAGE, DEAGLE_MIN_DAMAGE, DEAGLE_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }
    }
};

// Fire — called by W_WeaponFrame when button0 pressed (self = player)
void() W_DeagleFire =
{
    float r = SH_DeagleTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = DEAGLE_FIRE_START;
        self.wep_nextframe = time + DEAGLE_FRAME_INTERVAL;

        W_DeagleShoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

// Reload — called on impulse 6 / R key (self = player)
void() W_DeagleReload =
{
    if (SH_DeagleTryReload(time))
    {
        self.weaponframe   = DEAGLE_RELOAD_START;
        self.wep_nextframe = time + DEAGLE_FRAME_INTERVAL;
    }
};

// Frame — advances animation state machine (self = player)
void() W_DeagleFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += DEAGLE_FRAME_INTERVAL;

    // Server-only: play sounds at specific frames
    if (self.weaponstate == WS_DRAW && self.weaponframe == DEAGLE_DRAW_SND_FRAME)
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csdeagle/deploy.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == DEAGLE_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL_HL, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == DEAGLE_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csdeagle/clipin.wav", 1, ATTN_NORM);
    }

    // Shared state transitions (idle transition + reload ammo apply)
    result = SH_DeagleTickState(time);
    if (result & 1)
    {
        self.weaponframe   = 2;
        self.wep_nextframe = 0;
    }
};

// Equip — called by W_ChangeWeapon (self = player)
void() W_DeagleEquip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_DEAGLE);
    self.fire           = W_DeagleFire;
    self.reload         = W_DeagleReload;
    self.wepframe       = W_DeagleFrame;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = DEAGLE_DRAW_START;
    self.wep_nextframe  = time + DEAGLE_FRAME_INTERVAL;
    W_SetCrosshairProfile(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED, 1, TRUE);
};

// Drop — called by W_DropCurrentWeapon (self = player)
void() W_DeagleDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_deagle  = self.mag_deagle;
    tgt.ammo_deagle = self.ammo_deagle;

    self.mag_deagle  = 0;
    self.ammo_deagle = 0;

    setmodel(tgt, "models/weapons/wpn_csdeagle/w_deagle.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_deagle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_DEAGLE;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_DeagleEquip;
    tgt.weap_drop_func = W_DeagleDrop;
    tgt.pickupcopy   = W_DeaglePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

// World entity — spawned from map (classname "weapon_deagle")
void() weapon_deagle =
{
    setmodel(self, "models/weapons/wpn_csdeagle/w_deagle.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_deagle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_DEAGLE;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_DeagleEquip;
    self.weap_drop_func = W_DeagleDrop;
    self.pickupcopy    = W_DeaglePickupCopy;
    self.touch         = weapon_touch;
    self.mag_deagle    = MAX_MAG_DEAGLE;
    self.ammo_deagle   = MAX_AMMO_DEAGLE;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

const float DEAGLE_RELOAD_CLIPOUT_TIME = (DEAGLE_RELOAD_CLIPOUT - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
const float DEAGLE_RELOAD_CLIPIN_TIME = (DEAGLE_RELOAD_CLIPIN - DEAGLE_RELOAD_START) * DEAGLE_FRAME_INTERVAL;
float csqc_deagle_reload_snd_stage;

void() CSQC_PredictDeagleCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_DeagleTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    localsound("sounds/weapons/wpn_csdeagle/fire1.wav");
                else
                    localsound("sounds/weapons/wpn_csdeagle/fire2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(DEAGLE_BASE_SPREAD, DEAGLE_MOVE_SPREAD, DEAGLE_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_deagle_reload_snd_stage < 1 && reload_elapsed >= DEAGLE_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csdeagle/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/pistolmaghl.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_deagle_reload_snd_stage = 1;
        }
        if (csqc_deagle_reload_snd_stage < 2 && reload_elapsed >= DEAGLE_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csdeagle/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_deagle_reload_snd_stage = 2; }
    }

    SH_DeagleTickState(csqc_pred_time);
};

void() CSQC_PredictDeagleReload =
{
    if (SH_DeagleTryReload(csqc_pred_time))
    { csqc_deagle_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Returns fractional display frame for viewmodel interpolation.
// Called from CSQC_GetWeaponDisplayFrame dispatcher.
float(float elapsed) CSQC_DeagleDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = DEAGLE_DRAW_START + elapsed / DEAGLE_FRAME_INTERVAL;
        return bound(DEAGLE_DRAW_START, frame, DEAGLE_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = DEAGLE_FIRE_START + elapsed / DEAGLE_FRAME_INTERVAL;
        return bound(DEAGLE_FIRE_START, frame, DEAGLE_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = DEAGLE_RELOAD_START + elapsed / DEAGLE_FRAME_INTERVAL;
        return bound(DEAGLE_RELOAD_START, frame, DEAGLE_RELOAD_END - 1);
    }
    return 2;   // idle frame
};

#endif // CSQC
