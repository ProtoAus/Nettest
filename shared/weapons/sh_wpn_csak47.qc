// ============================================================
//  shared/weapons/sh_wpn_csak47.qc  -  CS AK47
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_ak47;
.float ammo_ak47;

// --- Animation frames ---
const float AK47_FRAME_INTERVAL      = 0.0333334;   // 1/30

const float AK47_DRAW_START          = 111;
const float AK47_DRAW_END            = 138;
const float AK47_DRAW_BOLTPULL_FRAME = 120;

const float AK47_FIRE_START          = 140;
const float AK47_FIRE_END            = 147;
const float AK47_FIRE_DELAY          = 0.1;

const float AK47_RELOAD_START        = 18;
const float AK47_RELOAD_END          = 108;
const float AK47_RELOAD_CLIPOUT      = 30;
const float AK47_RELOAD_CLIPIN       = 72;
const float AK47_RELOAD_APPLY        = 83;

const float AK47_IDLE_FRAME          = 20;

const float MAX_MAG_AK47             = 30;
const float MAX_AMMO_AK47            = 90;

// --- Balance ---
const float AK47_BASE_SPREAD          = 0.012;
const float AK47_MOVE_SPREAD          = 0.07;
const float AK47_FULL_SPREAD_SPEED    = 320;
const float AK47_CLOSE_DAMAGE         = 16;
const float AK47_MIN_DAMAGE           = 8;
const float AK47_DAMAGE_FALLOFF_RANGE = 2304;
const float AK47_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed state durations ---
const float AK47_DRAW_DURATION      = (AK47_DRAW_END - AK47_DRAW_START) * AK47_FRAME_INTERVAL;
const float AK47_FIRE_DURATION      = (AK47_FIRE_END - AK47_FIRE_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_DURATION    = (AK47_RELOAD_END - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_APPLY_TIME  = (AK47_RELOAD_APPLY - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_AK47TickState =
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
        if (elapsed >= AK47_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= AK47_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= AK47_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_AK47 - self.mag_ak47;
            if (needed > 0)
            {
                if (self.ammo_ak47 >= needed)
                {
                    self.mag_ak47  += needed;
                    self.ammo_ak47 -= needed;
                }
                else
                {
                    self.mag_ak47  += self.ammo_ak47;
                    self.ammo_ak47  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= AK47_RELOAD_DURATION)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

float(float now) SH_AK47TryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_ak47 <= 0)
    {
        self.attack_finished = now + AK47_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_ak47        -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + AK47_FIRE_DELAY;
    return 1;
};

float(float now) SH_AK47TryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.mag_ak47 >= MAX_MAG_AK47 || self.ammo_ak47 <= 0)
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

void(entity player) W_AK47PickupCopy =
{
    player.mag_ak47  = self.mag_ak47;
    player.ammo_ak47 = self.ammo_ak47;
};

void() W_AK47Shoot =
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

    spread = AK47_BASE_SPREAD + (move_speed / AK47_FULL_SPREAD_SPEED) * AK47_MOVE_SPREAD;
    spread = min(spread, AK47_BASE_SPREAD + AK47_MOVE_SPREAD);

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
                AK47_CLOSE_DAMAGE, AK47_MIN_DAMAGE, AK47_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }
    }
};

void() W_AK47Fire =
{
    float r = SH_AK47TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = AK47_FIRE_START;
        self.wep_nextframe = time + AK47_FRAME_INTERVAL;

        W_AK47Shoot();

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_AK47Reload =
{
    if (SH_AK47TryReload(time))
    {
        self.weaponframe   = AK47_RELOAD_START;
        self.wep_nextframe = time + AK47_FRAME_INTERVAL;
    }
};

void() W_AK47Frame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += AK47_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW && self.weaponframe == AK47_DRAW_BOLTPULL_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/boltpull.wav", 1, ATTN_NORM);

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == AK47_RELOAD_CLIPOUT)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == AK47_RELOAD_CLIPIN)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csak47/clipin.wav", 1, ATTN_NORM);
    }

    result = SH_AK47TickState(time);
    if (result & 1)
    {
        self.weaponframe   = AK47_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_AK47Equip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_AK47);
    self.weapon_name    = "AK47";
    self.weapon_draw_start_frame = AK47_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire           = W_AK47Fire;
    self.reload         = W_AK47Reload;
    self.wepframe       = W_AK47Frame;
    self.altfire         = __NULL__;
    self.altrelease      = __NULL__;
    self.shoot           = W_AK47Shoot;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = AK47_DRAW_START;
    self.wep_nextframe  = time + AK47_FRAME_INTERVAL;
    W_SetCrosshairProfile(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_AK47Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_ak47  = self.mag_ak47;
    tgt.ammo_ak47 = self.ammo_ak47;

    self.mag_ak47  = 0;
    self.ammo_ak47 = 0;

    setmodel(tgt, "models/weapons/wpn_csak47/w_ak47.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_ak47";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_AK47;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_AK47Equip;
    tgt.weap_drop_func = W_AK47Drop;
    tgt.pickupcopy   = W_AK47PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_ak47 =
{
    setmodel(self, "models/weapons/wpn_csak47/w_ak47.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_ak47";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_AK47;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_AK47Equip;
    self.weap_drop_func = W_AK47Drop;
    self.pickupcopy    = W_AK47PickupCopy;
    self.touch         = weapon_touch;
    self.mag_ak47      = MAX_MAG_AK47;
    self.ammo_ak47     = MAX_AMMO_AK47;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Pre-computed time for boltpull sound during draw
const float AK47_DRAW_BOLTPULL_TIME = (AK47_DRAW_BOLTPULL_FRAME - AK47_DRAW_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_CLIPOUT_TIME = (AK47_RELOAD_CLIPOUT - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;
const float AK47_RELOAD_CLIPIN_TIME = (AK47_RELOAD_CLIPIN - AK47_RELOAD_START) * AK47_FRAME_INTERVAL;

float csqc_ak47_draw_snd_played;
float csqc_ak47_reload_snd_stage;

void() CSQC_PredictAK47Command =
{
    float r;

    // Play draw boltpull sound at the correct frame time
    if (self.weaponstate == WS_DRAW && !pm_suppress_sounds && !csqc_ak47_draw_snd_played)
    {
        float elapsed = (self.wep_anim_start > 0) ? (csqc_pred_time - self.wep_anim_start) : 0;
        if (elapsed >= AK47_DRAW_BOLTPULL_TIME)
        {
            localsound("sounds/weapons/wpn_csak47/boltpull.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_ak47_draw_snd_played = TRUE;
        }
    }
    else if (self.weaponstate != WS_DRAW)
    {
        csqc_ak47_draw_snd_played = FALSE;
    }

    if (input_buttons & 1)
    {
        r = SH_AK47TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // CHAN_WEAPON cuts previous fire sound (no overlap)
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csak47/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(AK47_BASE_SPREAD, AK47_MOVE_SPREAD, AK47_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
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

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_ak47_reload_snd_stage < 1 && reload_elapsed >= AK47_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csak47/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_ak47_reload_snd_stage = 1;
        }
        if (csqc_ak47_reload_snd_stage < 2 && reload_elapsed >= AK47_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csak47/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_ak47_reload_snd_stage = 2; }
    }

    SH_AK47TickState(csqc_pred_time);
};

void() CSQC_PredictAK47Reload =
{
    if (SH_AK47TryReload(csqc_pred_time))
    { csqc_ak47_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_AK47DisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = AK47_DRAW_START + elapsed / AK47_FRAME_INTERVAL;
        return bound(AK47_DRAW_START, frame, AK47_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = AK47_FIRE_START + elapsed / AK47_FRAME_INTERVAL;
        return bound(AK47_FIRE_START, frame, AK47_FIRE_END - 1);
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        frame = AK47_RELOAD_START + elapsed / AK47_FRAME_INTERVAL;
        return bound(AK47_RELOAD_START, frame, AK47_RELOAD_END - 1);
    }
    return AK47_IDLE_FRAME;
};

#endif // CSQC
