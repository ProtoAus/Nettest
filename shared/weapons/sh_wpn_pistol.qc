// ============================================================
//  shared/weapons/sh_wpn_pistol.qc  -  Pistol
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 12-round magazine, 24 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_pistol;
.float ammo_pistol;

// --- Animation frames ---
const float PISTOL_FRAME_INTERVAL      = 0.05;

const float PISTOL_DRAW_START          = 1;
const float PISTOL_DRAW_END            = 10;

const float PISTOL_FIRE_START          = 11;
const float PISTOL_FIRE_END            = 33;
const float PISTOL_FIRE_DELAY          = 0.2;

const float PISTOL_RELOAD_START        = 34;
const float PISTOL_RELOAD_END          = 65;
const float PISTOL_RELOAD_SND_FRAME    = 35;
const float PISTOL_RELOAD_MAGDROP      = 44;
const float PISTOL_RELOAD_APPLY        = 53;

const float PISTOL_IDLE_FRAME          = 0;

const float MAX_MAG_PISTOL             = 12;
const float MAX_AMMO_PISTOL            = 24;
const float PISTOL_DRYFIRE_DELAY       = 0.2;

// --- Balance ---
const float PISTOL_BASE_SPREAD          = 0.004;
const float PISTOL_MOVE_SPREAD          = 0.045;
const float PISTOL_FULL_SPREAD_SPEED    = 320;
const float PISTOL_CLOSE_DAMAGE         = 20;
const float PISTOL_MIN_DAMAGE           = 8;
const float PISTOL_DAMAGE_FALLOFF_RANGE = 2048;

// --- Pre-computed state durations ---
const float PISTOL_DRAW_DURATION      = (PISTOL_DRAW_END - PISTOL_DRAW_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_FIRE_DURATION      = (PISTOL_FIRE_END - PISTOL_FIRE_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_RELOAD_DURATION    = (PISTOL_RELOAD_END - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_RELOAD_APPLY_TIME  = (PISTOL_RELOAD_APPLY - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_PistolTickState =
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
        if (elapsed >= PISTOL_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= PISTOL_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= PISTOL_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_PISTOL - self.mag_pistol;
            if (needed > 0)
            {
                if (self.ammo_pistol >= needed)
                {
                    self.mag_pistol  += needed;
                    self.ammo_pistol -= needed;
                }
                else
                {
                    self.mag_pistol  += self.ammo_pistol;
                    self.ammo_pistol  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= PISTOL_RELOAD_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

float(float now) SH_PistolTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_pistol <= 0)
    {
        self.attack_finished = now + PISTOL_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_pistol      -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + PISTOL_FIRE_DELAY;
    return 1;
};

float(float now) SH_PistolTryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.mag_pistol >= MAX_MAG_PISTOL || self.ammo_pistol <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_PistolPickupCopy =
{
    player.mag_pistol  = self.mag_pistol;
    player.ammo_pistol = self.ammo_pistol;
};

void() W_PistolShoot =
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

    spread = PISTOL_BASE_SPREAD + (move_speed / PISTOL_FULL_SPREAD_SPEED) * PISTOL_MOVE_SPREAD;
    spread = min(spread, PISTOL_BASE_SPREAD + PISTOL_MOVE_SPREAD);

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
                PISTOL_CLOSE_DAMAGE, PISTOL_MIN_DAMAGE, PISTOL_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }
    }
};

void() W_PistolFire =
{
    float r = SH_PistolTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = PISTOL_FIRE_START;
        self.wep_nextframe = time + PISTOL_FRAME_INTERVAL;

        W_PistolShoot();

        r = random();
        if (r < 0.25)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire1.wav", 1, ATTN_NORM);
        else if (r < 0.50)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire2.wav", 1, ATTN_NORM);
        else if (r < 0.75)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire3.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire4.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_PistolReload =
{
    if (SH_PistolTryReload(time))
    {
        self.weaponframe   = PISTOL_RELOAD_START;
        self.wep_nextframe = time + PISTOL_FRAME_INTERVAL;
    }
};

void() W_PistolFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += PISTOL_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == PISTOL_RELOAD_SND_FRAME)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/reload.wav", 1, ATTN_NORM);
        if (self.weaponframe == PISTOL_RELOAD_MAGDROP)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/magdrop.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == PISTOL_RELOAD_APPLY)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/deadlockreload.wav", 1, ATTN_NORM);
    }

    result = SH_PistolTickState(time);
    if (result & 1)
    {
        self.weaponframe   = PISTOL_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_PistolEquip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_PISTOL);
    self.weapon_name    = "PISTOL";
    self.weapon_draw_start_frame = PISTOL_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire           = W_PistolFire;
    self.reload         = W_PistolReload;
    self.wepframe       = W_PistolFrame;
    self.altfire         = __NULL__;
    self.altrelease      = __NULL__;
    self.shoot           = W_PistolShoot;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = PISTOL_DRAW_START;
    self.wep_nextframe  = time + PISTOL_FRAME_INTERVAL;
    W_SetCrosshairProfile(PISTOL_BASE_SPREAD, PISTOL_MOVE_SPREAD, PISTOL_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_PistolDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_pistol  = self.mag_pistol;
    tgt.ammo_pistol = self.ammo_pistol;

    self.mag_pistol  = 0;
    self.ammo_pistol = 0;

    setmodel(tgt, "models/weapons/wpn_pistol/w_pistol.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_pistol";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_PISTOL;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_PistolEquip;
    tgt.weap_drop_func = W_PistolDrop;
    tgt.pickupcopy   = W_PistolPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_pistol =
{
    setmodel(self, "models/weapons/wpn_pistol/w_pistol.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_pistol";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_PISTOL;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_PistolEquip;
    self.weap_drop_func = W_PistolDrop;
    self.pickupcopy    = W_PistolPickupCopy;
    self.touch         = weapon_touch;
    self.mag_pistol    = MAX_MAG_PISTOL;
    self.ammo_pistol   = MAX_AMMO_PISTOL;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float PISTOL_RELOAD_MAGDROP_TIME = (PISTOL_RELOAD_MAGDROP - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;
float csqc_pistol_reload_snd_stage;

void() CSQC_PredictPistolCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_PistolTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                r = random();
                if (r < 0.25)
                    localsound("sounds/weapons/wpn_pistol/fire1.wav");
                else if (r < 0.50)
                    localsound("sounds/weapons/wpn_pistol/fire2.wav");
                else if (r < 0.75)
                    localsound("sounds/weapons/wpn_pistol/fire3.wav");
                else
                    localsound("sounds/weapons/wpn_pistol/fire4.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(PISTOL_BASE_SPREAD, PISTOL_MOVE_SPREAD, PISTOL_FULL_SPREAD_SPEED);
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

    // Predicted reload sounds — mag drop
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_pistol_reload_snd_stage < 1 && reload_elapsed >= PISTOL_RELOAD_MAGDROP_TIME)
        {
            localsound("sounds/weapons/wpn_pistol/magdrop.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_pistol_reload_snd_stage = 1;
        }
    }

    SH_PistolTickState(csqc_pred_time);
};

void() CSQC_PredictPistolReload =
{
    if (SH_PistolTryReload(csqc_pred_time))
    { csqc_pistol_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_PistolDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = PISTOL_DRAW_START + elapsed / PISTOL_FRAME_INTERVAL;
        return bound(PISTOL_DRAW_START, frame, PISTOL_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = PISTOL_FIRE_START + elapsed / PISTOL_FRAME_INTERVAL;
        return bound(PISTOL_FIRE_START, frame, PISTOL_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = PISTOL_RELOAD_START + elapsed / PISTOL_FRAME_INTERVAL;
        return bound(PISTOL_RELOAD_START, frame, PISTOL_RELOAD_END - 1);
    }
    return PISTOL_IDLE_FRAME;
};

#endif // CSQC
