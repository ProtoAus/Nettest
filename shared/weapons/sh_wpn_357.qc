// ============================================================
//  shared/weapons/sh_wpn_357.qc  -  .357 Revolver
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 6-round cylinder, 18 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_357;
.float ammo_357;

// --- Animation frames ---
const float W357_FRAME_INTERVAL       = 0.05;   // 1/20

const float W357_DRAW_START           = 1;
const float W357_DRAW_END             = 10;

const float W357_FIRE_START           = 11;
const float W357_FIRE_END             = 31;
const float W357_FIRE_DELAY           = 0.75;

const float W357_RELOAD_START         = 139;
const float W357_RELOAD_END           = 200;
const float W357_RELOAD_SOUND_FRAME   = 180;
const float W357_RELOAD_APPLY         = 184;

const float W357_IDLE_FRAME           = 78;

const float MAX_MAG_357               = 6;
const float MAX_AMMO_357              = 18;

// --- Balance ---
const float W357_BASE_SPREAD          = 0.004;
const float W357_MOVE_SPREAD          = 0.03;
const float W357_FULL_SPREAD_SPEED    = 320;
const float W357_CLOSE_DAMAGE         = 70;
const float W357_MIN_DAMAGE           = 45;
const float W357_DAMAGE_FALLOFF_RANGE = 4096;
const float W357_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float W357_DRAW_DURATION      = (W357_DRAW_END - W357_DRAW_START) * W357_FRAME_INTERVAL;
const float W357_FIRE_DURATION      = (W357_FIRE_END - W357_FIRE_START) * W357_FRAME_INTERVAL;
const float W357_RELOAD_DURATION    = (W357_RELOAD_END - W357_RELOAD_START) * W357_FRAME_INTERVAL;
const float W357_RELOAD_APPLY_TIME  = (W357_RELOAD_APPLY - W357_RELOAD_START) * W357_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_357TickState =
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
        if (elapsed >= W357_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= W357_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= W357_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_357 - self.mag_357;
            if (needed > 0)
            {
                if (self.ammo_357 >= needed)
                {
                    self.mag_357  += needed;
                    self.ammo_357 -= needed;
                }
                else
                {
                    self.mag_357  += self.ammo_357;
                    self.ammo_357  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= W357_RELOAD_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

float(float now) SH_357TryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_357 <= 0)
    {
        self.attack_finished = now + W357_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_357         -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + W357_FIRE_DELAY;
    return 1;
};

float(float now) SH_357TryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;
    if (self.mag_357 >= MAX_MAG_357 || self.ammo_357 <= 0)
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

void(entity player) W_357PickupCopy =
{
    player.mag_357  = self.mag_357;
    player.ammo_357 = self.ammo_357;
};

void() W_357Shoot =
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

    spread = W357_BASE_SPREAD + (move_speed / W357_FULL_SPREAD_SPEED) * W357_MOVE_SPREAD;
    spread = min(spread, W357_BASE_SPREAD + W357_MOVE_SPREAD);

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
                W357_CLOSE_DAMAGE, W357_MIN_DAMAGE, W357_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }
    }
};

void() W_357Fire =
{
    float r = SH_357TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = W357_FIRE_START;
        self.wep_nextframe = time + W357_FRAME_INTERVAL;

        W_357Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NORM);
    }
};

void() W_357Reload =
{
    if (SH_357TryReload(time))
    {
        self.weaponframe   = W357_RELOAD_START;
        self.wep_nextframe = time + W357_FRAME_INTERVAL;
    }
};

void() W_357Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += W357_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == W357_RELOAD_SOUND_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hl357/reload.wav", 1, ATTN_NORM);
    }

    result = SH_357TickState(time);
    if (result & 1)
    {
        self.weaponframe   = W357_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_357Equip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_357);
    self.weapon_name    = ".357";
    self.weapon_draw_start_frame = W357_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire           = W_357Fire;
    self.reload         = W_357Reload;
    self.wepframe       = W_357Frame;
    self.altfire         = __NULL__;
    self.altrelease      = __NULL__;
    self.shoot           = W_357Shoot;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = W357_DRAW_START;
    self.wep_nextframe  = time + W357_FRAME_INTERVAL;
    W_SetCrosshairProfile(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED, 1.4, TRUE);
};

void() W_357Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_357  = self.mag_357;
    tgt.ammo_357 = self.ammo_357;

    self.mag_357  = 0;
    self.ammo_357 = 0;

    setmodel(tgt, "models/weapons/wpn_hl357/w_357.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_357";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_357;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_357Equip;
    tgt.weap_drop_func = W_357Drop;
    tgt.pickupcopy   = W_357PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_357 =
{
    setmodel(self, "models/weapons/wpn_hl357/w_357.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_357";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_357;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_357Equip;
    self.weap_drop_func = W_357Drop;
    self.pickupcopy    = W_357PickupCopy;
    self.touch         = weapon_touch;
    self.mag_357       = MAX_MAG_357;
    self.ammo_357      = MAX_AMMO_357;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_357_reload_snd_played;
const float W357_RELOAD_SND_TIME = (W357_RELOAD_SOUND_FRAME - W357_RELOAD_START) * W357_FRAME_INTERVAL;

void() CSQC_Predict357Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_357TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(W357_BASE_SPREAD, W357_MOVE_SPREAD, W357_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hl357/cock.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted reload sound
    if (self.weaponstate == WS_RELOAD && !csqc_357_reload_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= W357_RELOAD_SND_TIME)
        { localsound("sounds/weapons/wpn_hl357/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_357_reload_snd_played = TRUE; }
    }

    SH_357TickState(csqc_pred_time);
};

void() CSQC_Predict357Reload =
{
    if (SH_357TryReload(csqc_pred_time))
    { csqc_357_reload_snd_played = FALSE; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_357DisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = W357_DRAW_START + elapsed / W357_FRAME_INTERVAL;
        return bound(W357_DRAW_START, frame, W357_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = W357_FIRE_START + elapsed / W357_FRAME_INTERVAL;
        return bound(W357_FIRE_START, frame, W357_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = W357_RELOAD_START + elapsed / W357_FRAME_INTERVAL;
        return bound(W357_RELOAD_START, frame, W357_RELOAD_END - 1);
    }
    return W357_IDLE_FRAME;
};

#endif // CSQC
