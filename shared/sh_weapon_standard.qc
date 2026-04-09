// ============================================================
//  shared/sh_weapon_standard.qc  -  Generic weapon functions
//
//  Compiled by both sv_progs and cl_progs.
//  Standard hitscan weapons delegate to these instead of
//  duplicating the same logic in every sh_wpn_*.qc file.
//
//  Uses FTEQW field-reference parameters (.float) so the
//  generic functions can read/write per-weapon ammo fields.
// ============================================================

// Fire spread penalty constants are in sh_customdefs.qc
// (must be available before sh_pmove.qc in cl_progs compile order)

// ============================================================
//  SHARED — state machines
// ============================================================

// Generic tick state for weapons with draw/fire/reload cycle.
// Returns bitmask: bit 0 = transitioned to idle, bit 1 = reload ammo applied.
float(float now,
      .float mag_fld, .float ammo_fld, float max_mag,
      float draw_dur, float fire_dur,
      float reload_dur, float reload_apply_time) SH_StandardTickState =
{
    float elapsed, result, needed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result = 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= draw_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= fire_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= reload_apply_time)
        {
            needed = max_mag - self.(mag_fld);
            if (needed > 0)
            {
                if (self.(ammo_fld) >= needed)
                {
                    self.(mag_fld)  += needed;
                    self.(ammo_fld) -= needed;
                }
                else
                {
                    self.(mag_fld)  += self.(ammo_fld);
                    self.(ammo_fld)  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= reload_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

// Simple tick state for weapons with only draw + fire (no reload).
// Returns: 1 = transitioned to idle, 0 = no change.
float(float now, float draw_dur, float fire_dur) SH_SimpleTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= draw_dur)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= fire_dur)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

// ============================================================
//  SHARED — fire / reload validation
// ============================================================

// Generic fire validation for standard weapons.
// Returns: 1 = fired, -1 = dry fire, 0 = blocked.
float(float now, .float mag_fld,
      float fire_delay, float dryfire_delay) SH_StandardTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.(mag_fld) <= 0)
    {
        self.attack_finished = now + dryfire_delay;
        return -1;
    }

    self.(mag_fld)       -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + fire_delay;
    // Queue penalty — applied AFTER this shot's spread is calculated
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// Generic reload validation for standard weapons.
// Returns: 1 = reload started, 0 = blocked.
float(float now, .float mag_fld, .float ammo_fld,
      float max_mag) SH_StandardTryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.(mag_fld) >= max_mag || self.(ammo_fld) <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY — hitscan + equip helpers
// ============================================================

#ifdef SSQC

// Forward declarations — defined in sv_weapons.qc (compiled later)
float(entity target) W_CanDamageTarget;
float(float dist, float close_dmg, float min_dmg, float range) W_LinearDamageFalloff;
float(entity attacker, entity target, float damage) W_ApplyDamage;
void(vector pos) W_ImpactEffect;

// Generic lag-compensated hitscan with spread and linear damage falloff.
void(float base_spread, float move_spread, float full_spread_speed,
     float close_dmg, float min_dmg, float falloff_range) W_StandardHitscanShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = base_spread + (move_speed / full_spread_speed) * move_spread;
    spread = min(spread, base_spread + move_spread);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        sx  = SH_SpreadJitter(self.wep_action_id, 0) * spread;
        sy  = SH_SpreadJitter(self.wep_action_id, 1) * spread;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
    }
    else
        dir = v_forward;
    end = src + dir * 8192;

    traceline(src, end, MOVE_NORMAL | MOVE_LAGGED, self);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);

        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);
        }

        // Debug: send server hit position to shooter only
        {
            float saved_dim = dimension_send;
            dimension_send = self.dimension_seen;
            WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
            WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBUG_IMPACT);
            WriteCoord(MSG_MULTICAST, trace_endpos_x);
            WriteCoord(MSG_MULTICAST, trace_endpos_y);
            WriteCoord(MSG_MULTICAST, trace_endpos_z);
            multicast(trace_endpos, MULTICAST_PVS);
            dimension_send = saved_dim;
        }
    }
};

// Common equip setup — sets draw state, model, and timing.
// Call this first in each weapon's Equip function, then set
// the weapon-specific function pointers and crosshair profile.
void(string viewmodel, string wep_name, float draw_start,
     float frame_interval, float attack_anim) W_StandardEquipSetup =
{
    self.weaponmodel             = viewmodel;
    self.weapon_name             = wep_name;
    self.weapon_draw_start_frame = draw_start;
    self.weapon_player_attack_anim = attack_anim;
    self.weaponstate             = WS_DRAW;
    self.wep_action_id          += 1;
    self.wep_anim_start          = time;
    self.weaponframe             = draw_start;
    self.wep_nextframe           = time + frame_interval;

    // Clear optional function pointers — weapon sets the ones it uses
    self.altfire    = __NULL__;
    self.altrelease = __NULL__;
    self.shoot      = __NULL__;
    self.special    = __NULL__;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — display frame helper
// ============================================================

#ifdef CSQC

// Generic display frame for standard draw/fire/reload weapons.
// Pass reload_start == reload_end to skip the reload branch.
float(float elapsed, float frame_interval,
      float draw_start, float draw_end,
      float fire_start, float fire_end,
      float reload_start, float reload_end,
      float idle_frame) CSQC_StandardDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = draw_start + elapsed / frame_interval;
        return bound(draw_start, frame, draw_end - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = fire_start + elapsed / frame_interval;
        return bound(fire_start, frame, fire_end - 1);
    }
    if (reload_start != reload_end && predicted_player.weaponstate == WS_RELOAD)
    {
        frame = reload_start + elapsed / frame_interval;
        return bound(reload_start, frame, reload_end - 1);
    }
    return idle_frame;
};

#endif // CSQC
