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
#ifdef CSQC
    // Client-local fire latch. See .csqc_fire_guard in sh_customdefs.qc.
    // Must sit before the attack_finished check so stale snaps can't bypass it.
    if (cltime < self.csqc_fire_guard)
        return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.(mag_fld) <= 0)
    {
        self.attack_finished = now + dryfire_delay;
#ifdef CSQC
        self.csqc_fire_guard = cltime + dryfire_delay;
#endif
        return -1;
    }

    self.(mag_fld)       -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + fire_delay;
#ifdef CSQC
    self.csqc_fire_guard  = cltime + fire_delay;
#endif
    // Queue penalty — applied AFTER this shot's spread is calculated
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// Generic reload validation for standard weapons.
// Returns: 1 = reload started, 0 = blocked.
float(float now, .float mag_fld, .float ammo_fld,
      float max_mag, float reload_dur) SH_StandardTryReload =
{
#ifdef CSQC
    // Client-local reload latch. See .csqc_reload_guard in sh_customdefs.qc.
    // Must sit before the weaponstate check so a stale replay that hasn't
    // seen WS_RELOAD ack'd yet can't re-fire reload on every reconcile.
    if (cltime < self.csqc_reload_guard)
        return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.(mag_fld) >= max_mag || self.(ammo_fld) <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
#ifdef CSQC
    self.csqc_reload_guard = cltime + reload_dur;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY — hitscan + equip helpers
// ============================================================

#ifdef SSQC

// Forward declarations — defined in sv_weapons.qc (compiled later)
float(entity target) W_CanDamageTarget;
float(entity attacker, entity target, float damage) W_ApplyDamage;
void(vector pos) W_ImpactEffect;
void(vector pos, vector normal) W_ImpactEffectAll;
void(vector pos, vector normal, float mat) W_ImpactEffectAllMat;
float(entity hit) W_ClassifyImpactMaterial;
float(float bone_id) W_BoneToHitgroup;
float(float hitgroup) W_HitgroupDamageMultiplier;
float(vector shot_dir, float damage) PhysProp_TryPushFromTrace;
void(vector start, vector end, float tracetype, entity ignore) PhysProp_TraceLine;
void(entity target) W_SendServerHitboxes;
void() W_PlayersExpandHitboxes;
void() W_PlayersRestoreHitboxes;

// Send debug impact marker to the shooter only.
// Includes the shooter's eye position, damage, and hitgroup.
void(vector hit_pos, float damage, float hitgroup) W_DebugImpact =
{
    float saved_dim = dimension_send;
    vector eye = self.origin + self.view_ofs;
    dimension_send = self.dimension_seen;
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBUG_IMPACT);
    WriteCoord(MSG_MULTICAST, hit_pos_x);
    WriteCoord(MSG_MULTICAST, hit_pos_y);
    WriteCoord(MSG_MULTICAST, hit_pos_z);
    WriteCoord(MSG_MULTICAST, eye_x);
    WriteCoord(MSG_MULTICAST, eye_y);
    WriteCoord(MSG_MULTICAST, eye_z);
    WriteByte(MSG_MULTICAST, bound(0, floor(damage), 255));
    WriteByte(MSG_MULTICAST, hitgroup);
    multicast(hit_pos, MULTICAST_PVS);
    dimension_send = saved_dim;
};

// Generic lag-compensated hitscan with spread and linear damage falloff.
void(float base_spread, float move_spread, float full_spread_speed,
     float close_dmg, float min_dmg, float falloff_range) W_StandardHitscanShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;

    float saved_dim_hit = self.dimension_hit;
    self.dimension_hit = saved_dim_hit | 2;

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

    // Expand all players' bbox so MOVE_HITMODEL can reach outstretched limbs.
    W_PlayersExpandHitboxes();

#ifdef SSQC
    Lagcomp_TraceLine(src, end, MOVE_NORMAL | MOVE_LAGGED | MOVE_HITMODEL, self);
#else
    traceline(src, end, MOVE_NORMAL | MOVE_LAGGED | MOVE_HITMODEL, self);
#endif

    W_PlayersRestoreHitboxes();

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        // Apply hitgroup damage multiplier
        float hitgroup = W_BoneToHitgroup(trace_bone_id);
        damage = damage * W_HitgroupDamageMultiplier(hitgroup);

        if (W_CanDamageTarget(trace_ent))
        {
            trace_ent.death_hitgroup = hitgroup;
            W_SendServerHitboxes(trace_ent);
            W_ApplyDamage(self, trace_ent, damage);
            // Players: pick the spark-splash variant for headshots and
            // killing blows; otherwise the calmer cloud-only flesh effect.
            // Breakables: auto-classify by material; if a flesh-style
            // breakable just took its killing blow, upgrade to the lethal
            // variant so it sparks like a player kill.
            if (trace_ent.classname == "player")
            {
                float mat = IMPACT_MAT_FLESH;
                if (hitgroup == HITGROUP_HEAD || trace_ent.health <= 0)
                    mat = IMPACT_MAT_FLESH_LETHAL;
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, mat);
            }
            else
            {
                float bmat = W_ClassifyImpactMaterial(trace_ent);
                if (bmat == IMPACT_MAT_FLESH && trace_ent.health <= 0)
                    bmat = IMPACT_MAT_FLESH_LETHAL;
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, bmat);
            }
        }
        else
        {
            PhysProp_TryPushFromTrace(dir, damage);
            W_ImpactEffect(trace_endpos);
        }

        W_DebugImpact(trace_endpos, damage, hitgroup);
    }

    self.dimension_hit = saved_dim_hit;
};

// Lag-compensated hitscan with spread, linear falloff, AND wall penetration.
// pen_power = max wall thickness the bullet can pierce (0 = no penetration).
// pen_dmg_mult = damage retained per unit of wall thickness (exponential decay).
void(float base_spread, float move_spread, float full_spread_speed,
     float close_dmg, float min_dmg, float falloff_range,
     float pen_power, float pen_dmg_mult) W_PenetratingHitscanShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;
    float pen_remaining, wall_thick;
    vector entry_pos, nudge_pos, exit_pos;
    float pen_count;

    float saved_dim_hit = self.dimension_hit;
    self.dimension_hit = saved_dim_hit | 2;

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

    pen_remaining = pen_power;
    pen_count = 0;

    // Expand player bboxes for MOVE_HITMODEL reach on outstretched limbs.
    // Only needed for the initial hitmodel trace; penetration re-traces use
    // MOVE_NORMAL (static BSP only) so we restore immediately after.
    W_PlayersExpandHitboxes();

    // First trace uses lag compensation + hitmodel; subsequent use MOVE_NORMAL (static BSP).
#ifdef SSQC
    Lagcomp_TraceLine(src, end, MOVE_NORMAL | MOVE_LAGGED | MOVE_HITMODEL, self);
#else
    traceline(src, end, MOVE_NORMAL | MOVE_LAGGED | MOVE_HITMODEL, self);
#endif

    W_PlayersRestoreHitboxes();

    while (trace_fraction < 1.0 && pen_count < 4)
    {
        dist = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        // Apply hitgroup damage multiplier
        float hitgroup = W_BoneToHitgroup(trace_bone_id);
        damage = damage * W_HitgroupDamageMultiplier(hitgroup);

        if (W_CanDamageTarget(trace_ent))
        {
            trace_ent.death_hitgroup = hitgroup;
            W_SendServerHitboxes(trace_ent);
            W_ApplyDamage(self, trace_ent, damage);
            // Players: flesh variant, upgrading to lethal on HS/kill.
            // Breakables: auto-classify; flesh breakables get the lethal
            // upgrade on their killing blow.
            if (trace_ent.classname == "player")
            {
                float mat = IMPACT_MAT_FLESH;
                if (hitgroup == HITGROUP_HEAD || trace_ent.health <= 0)
                    mat = IMPACT_MAT_FLESH_LETHAL;
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, mat);
            }
            else
            {
                float bmat = W_ClassifyImpactMaterial(trace_ent);
                if (bmat == IMPACT_MAT_FLESH && trace_ent.health <= 0)
                    bmat = IMPACT_MAT_FLESH_LETHAL;
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, bmat);
            }
        }
        else
        {
            PhysProp_TryPushFromTrace(dir, damage);
            // First impact: shooter sees it via CSQC prediction, others via server.
            // Post-penetration impacts: ALL players need them (CSQC can't predict).
            if (pen_count > 0)
                W_ImpactEffectAll(trace_endpos, trace_plane_normal);
            else
                W_ImpactEffect(trace_endpos);
        }

        W_DebugImpact(trace_endpos, damage, hitgroup);

        // --- Penetration logic ---
        if (pen_remaining <= 0)
            break;

        // Only penetrate world geometry and func_ entities (not players)
        if (trace_ent != world && W_CanDamageTarget(trace_ent))
            break;

        entry_pos = trace_endpos;

        // Find the exit point: trace backwards from max-depth to entry.
        nudge_pos = entry_pos + dir * pen_remaining;
        traceline(nudge_pos, entry_pos, MOVE_NORMAL, self);

        if (trace_fraction >= 1.0)
            break;  // no back face found (open sky or void)

        exit_pos = trace_endpos;
        // Save the actual wall surface normal for the exit decal
        vector exit_normal = trace_plane_normal;
        wall_thick = vlen(exit_pos - entry_pos);

        if (wall_thick < 1)
            wall_thick = 1;  // minimum 1 unit

        if (wall_thick > pen_remaining)
            break;  // wall too thick

        // Reduce penetration budget and damage
        pen_remaining -= wall_thick;
        close_dmg *= pow(pen_dmg_mult, wall_thick);
        min_dmg   *= pow(pen_dmg_mult, wall_thick);

        if (close_dmg < 1)
            break;  // bullet spent

        // Exit impact — uses the ACTUAL wall normal from the reverse trace,
        // not the bullet direction, so the decal sits flat on the surface.
        W_ImpactEffectAll(exit_pos, exit_normal);

        // Continue from exit point
        src = exit_pos + dir * 1;
        pen_count++;
        traceline(src, end, MOVE_NORMAL, self);
    }

    self.dimension_hit = saved_dim_hit;
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
