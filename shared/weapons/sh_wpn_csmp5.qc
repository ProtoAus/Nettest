// ============================================================
//  shared/weapons/sh_wpn_csmp5.qc  -  CS MP5
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 120 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_mp5;
.float ammo_mp5;

// --- Animation frames ---
const float MP5_FRAME_INTERVAL        = 0.0333334;   // 1/30

const float MP5_DRAW_START            = 1;
const float MP5_DRAW_END              = 18;
const float MP5_DRAW_SLIDE_FRAME      = 4;

const float MP5_FIRE_START            = 19;
const float MP5_FIRE_END              = 32;
const float MP5_FIRE_DELAY            = 0.1;

const float MP5_RELOAD_START          = 61;
const float MP5_RELOAD_END            = 113;
const float MP5_RELOAD_CLIPOUT_FRAME  = 66;
const float MP5_RELOAD_CLIPIN_FRAME   = 84;
const float MP5_RELOAD_SLIDE_FRAME    = 100;
const float MP5_RELOAD_APPLY          = 100;

const float MP5_IDLE_FRAME            = 33;

const float MAX_MAG_MP5               = 30;
const float MAX_AMMO_MP5              = 120;

// --- Balance ---
const float MP5_BASE_SPREAD           = 0.01;
const float MP5_MOVE_SPREAD           = 0.06;
const float MP5_FULL_SPREAD_SPEED     = 320;
const float MP5_CLOSE_DAMAGE          = 12;
const float MP5_MIN_DAMAGE            = 6;
const float MP5_DAMAGE_FALLOFF_RANGE  = 2048;
const float MP5_DRYFIRE_DELAY         = 0.2;

// --- Pre-computed state durations ---
const float MP5_DRAW_DURATION         = (MP5_DRAW_END - MP5_DRAW_START) * MP5_FRAME_INTERVAL;
const float MP5_FIRE_DURATION         = (MP5_FIRE_END - MP5_FIRE_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_DURATION       = (MP5_RELOAD_END - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_APPLY_TIME     = (MP5_RELOAD_APPLY - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_MP5TickState =
{
    float elapsed, result, needed;

    if (self.weaponstate == WS_IDLE) return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result = 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= MP5_DRAW_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= MP5_FIRE_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= MP5_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_MP5 - self.mag_mp5;
            if (needed > 0)
            {
                if (self.ammo_mp5 >= needed)
                { self.mag_mp5 += needed; self.ammo_mp5 -= needed; }
                else
                { self.mag_mp5 += self.ammo_mp5; self.ammo_mp5 = 0; }
                result = result | 2;
            }
        }
        if (elapsed >= MP5_RELOAD_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }
    return 0;
};

float(float now) SH_MP5TryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_mp5 <= 0)
    { self.attack_finished = now + MP5_DRYFIRE_DELAY; return -1; }

    self.mag_mp5         -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + MP5_FIRE_DELAY;
    return 1;
};

float(float now) SH_MP5TryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW) return 0;
    if (self.mag_mp5 >= MAX_MAG_MP5 || self.ammo_mp5 <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_MP5PickupCopy =
{ player.mag_mp5 = self.mag_mp5; player.ammo_mp5 = self.ammo_mp5; };

void() W_MP5Shoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    flat_vel = self.velocity; flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = MP5_BASE_SPREAD + (move_speed / MP5_FULL_SPREAD_SPEED) * MP5_MOVE_SPREAD;
    spread = min(spread, MP5_BASE_SPREAD + MP5_MOVE_SPREAD);

    sx = (random() * 2 - 1) * spread;
    sy = (random() * 2 - 1) * spread;
    dir = normalize(v_forward + v_right * sx + v_up * sy);
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);
        if (W_CanDamageTarget(trace_ent))
        { damage = W_LinearDamageFalloff(dist, MP5_CLOSE_DAMAGE, MP5_MIN_DAMAGE, MP5_DAMAGE_FALLOFF_RANGE); W_ApplyDamage(self, trace_ent, damage); }
        else
            W_ImpactEffect(trace_endpos);
    }
};

void() W_MP5Fire =
{
    float r = SH_MP5TryFire(time);
    if (r == 1)
    {
        self.weaponframe = MP5_FIRE_START;
        self.wep_nextframe = time + MP5_FRAME_INTERVAL;
        W_MP5Shoot();
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RED, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_MP5Reload =
{
    if (SH_MP5TryReload(time))
    { self.weaponframe = MP5_RELOAD_START; self.wep_nextframe = time + MP5_FRAME_INTERVAL; }
};

void() W_MP5Frame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += MP5_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW && self.weaponframe == MP5_DRAW_SLIDE_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == MP5_RELOAD_CLIPOUT_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == MP5_RELOAD_CLIPIN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/clipin.wav", 1, ATTN_NORM);
        if (self.weaponframe == MP5_RELOAD_SLIDE_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csmp5/slideback.wav", 1, ATTN_NORM);
    }

    result = SH_MP5TickState(time);
    if (result & 1)
    { self.weaponframe = MP5_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_MP5Equip =
{
    self.weaponmodel = SH_WeaponViewModel(WEP_CSMP5);
    self.weapon_name = "MP5";
    self.weapon_draw_start_frame = MP5_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_MP5Fire; self.reload = W_MP5Reload; self.wepframe = W_MP5Frame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = W_MP5Shoot; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = MP5_DRAW_START;
    self.wep_nextframe = time + MP5_FRAME_INTERVAL;
    W_SetCrosshairProfile(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED, 1.2, TRUE);
};

void() W_MP5Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_mp5 = self.mag_mp5; tgt.ammo_mp5 = self.ammo_mp5;
    self.mag_mp5 = 0; self.ammo_mp5 = 0;
    setmodel(tgt, "models/weapons/wpn_csmp5/w_mp5.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_csmp5"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSMP5; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_MP5Equip; tgt.weap_drop_func = W_MP5Drop;
    tgt.pickupcopy = W_MP5PickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csmp5 =
{
    setmodel(self, "models/weapons/wpn_csmp5/w_mp5.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_csmp5"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSMP5; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_MP5Equip; self.weap_drop_func = W_MP5Drop;
    self.pickupcopy = W_MP5PickupCopy; self.touch = weapon_touch;
    self.mag_mp5 = MAX_MAG_MP5; self.ammo_mp5 = MAX_AMMO_MP5;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float MP5_DRAW_SLIDE_TIME = (MP5_DRAW_SLIDE_FRAME - MP5_DRAW_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_CLIPOUT_TIME = (MP5_RELOAD_CLIPOUT_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_CLIPIN_TIME = (MP5_RELOAD_CLIPIN_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;
const float MP5_RELOAD_SLIDE_TIME = (MP5_RELOAD_SLIDE_FRAME - MP5_RELOAD_START) * MP5_FRAME_INTERVAL;

float csqc_mp5_draw_snd_played;
float csqc_mp5_reload_snd_stage;

void() CSQC_PredictMP5Command =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_MP5TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csmp5/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(MP5_BASE_SPREAD, MP5_MOVE_SPREAD, MP5_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/redcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }
    // Predicted draw slide sound
    if (self.weaponstate == WS_DRAW && !csqc_mp5_draw_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= MP5_DRAW_SLIDE_TIME)
        { localsound("sounds/weapons/wpn_csmp5/slideback.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_draw_snd_played = TRUE; }
    }
    else if (self.weaponstate != WS_DRAW)
        csqc_mp5_draw_snd_played = FALSE;

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_mp5_reload_snd_stage < 1 && reload_elapsed >= MP5_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csmp5/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_mp5_reload_snd_stage = 1;
        }
        if (csqc_mp5_reload_snd_stage < 2 && reload_elapsed >= MP5_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csmp5/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_reload_snd_stage = 2; }
        if (csqc_mp5_reload_snd_stage < 3 && reload_elapsed >= MP5_RELOAD_SLIDE_TIME)
        { localsound("sounds/weapons/wpn_csmp5/slideback.wav"); CSQC_RecordPredictedAutoSound(); csqc_mp5_reload_snd_stage = 3; }
    }

    SH_MP5TickState(csqc_pred_time);
};

void() CSQC_PredictMP5Reload =
{
    if (SH_MP5TryReload(csqc_pred_time))
    { csqc_mp5_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_MP5DisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = MP5_DRAW_START + elapsed / MP5_FRAME_INTERVAL; return bound(MP5_DRAW_START, frame, MP5_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = MP5_FIRE_START + elapsed / MP5_FRAME_INTERVAL; return bound(MP5_FIRE_START, frame, MP5_FIRE_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    { frame = MP5_RELOAD_START + elapsed / MP5_FRAME_INTERVAL; return bound(MP5_RELOAD_START, frame, MP5_RELOAD_END - 1); }
    return MP5_IDLE_FRAME;
};

#endif // CSQC
