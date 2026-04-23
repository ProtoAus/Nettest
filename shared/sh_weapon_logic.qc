// ============================================================
//  shared/sh_weapon_logic.qc  -  Cross-weapon shared utilities
//  Compiled by both sv_progs and cl_progs.
//
//  Per-weapon state machines live in shared/weapons/sh_wpn_*.qc.
//  This file provides utilities used by all weapons.
// ============================================================

// --- Shared utilities ---

// Flat spread bonus set by SH_GetSpreadScale — add to spread after multiplying by scale.
float sh_spread_flat;

// Deterministic spread random — produces the same value on client and server
// for the same seed (wep_action_id). Use different offsets for sx vs sy.
float(float seed) SH_SpreadHash =
{
    float val;
    val = sin(seed * 12.9898 + 78.233) * 43758.5453;
    return val - floor(val);   // fractional part, range [0, 1)
};

// Returns a spread jitter value in [-1, 1] for the given shot and axis.
// shot_id = self.wep_action_id, axis = 0 for X, 1 for Y, etc.
float(float shot_id, float axis) SH_SpreadJitter =
{
    return SH_SpreadHash(shot_id + axis * 0.7193) * 2 - 1;
};

// Returns a spread multiplier based on player stance (crouch, airborne, landing).
// Also sets sh_spread_flat for a flat additive bonus (ensures low-spread guns still feel penalties).
// Called by both server hitscan and client prediction to keep spread in sync.
float() SH_GetSpreadScale =
{
    float scale = 1.0;
    sh_spread_flat = 0;

    // Crouching: 60% accuracy improvement (only on ground)
    if ((self.flags & FL_DUCKING) && (self.flags & FL_ONGROUND))
        scale *= 0.4;

    // Jump/landing penalty: percentage + flat bonus, both decay together
    if (self.spread_penalty > 0)
    {
        scale *= 1.0 + self.spread_penalty;
        sh_spread_flat = self.spread_penalty * 0.04;
    }

    // Sustained fire penalty: builds up when spamming, decays when resting
    if (self.fire_spread_penalty > 0)
    {
        scale *= 1.0 + self.fire_spread_penalty;
        sh_spread_flat += self.fire_spread_penalty * 0.02;
    }

    // Flush pending fire penalty AFTER using the current value for this shot.
    // This ensures the bullet being fired right now isn't penalized by its own shot.
    if (self.fire_spread_pending > 0)
    {
        self.fire_spread_penalty = min(self.fire_spread_penalty + self.fire_spread_pending,
                                       FIRE_SPREAD_PENALTY_MAX);
        self.fire_spread_pending = 0;
    }

    return scale;
};

void() SH_WeaponEnterIdle =
{
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
};

// SH_WeaponViewModel, SH_WeaponWorldModel, and SH_WeaponDeploySound
// have been removed — each weapon file now defines its own string
// constants (e.g. AK47_VIEWMODEL, AK47_WORLDMODEL, AK47_DEPLOY_SOUND)
// and the per-weapon equip functions set them on the player entity.

// --- CSQC-only prediction bookkeeping ---
// On cl_progs.src this file is placed after sh_pmove.qc so
// pm_suppress_sounds is available.

#ifdef CSQC
void() CSQC_MuzzleFlash;
void(vector pos, vector eye_pos, vector colour, float damage, float hitgroup) CSQC_AddDebugImpact;
void(vector pos, vector normal, float damage) CSQC_BulletImpact;
void() HUD_TriggerHitmarker;
void(vector pos, vector normal) CSQC_BulletImpactSilent;

// Send a hitclaim to the server. Fires when a predicted weapon trace hits
// a remote player's visual proxy or engine slot. Server gates acceptance
// on sv_trust_clienthits (1=soft: apply claim + sanity checks, 2=full:
// apply without checks, 0=ignore). Client gate cl_predict_hits default on.
// Gated on !pm_suppress_sounds so the claim isn't re-sent on reconcile
// replay passes for the same shot.
//
// `bone_id` is FTE's trace_bone_id from a MOVE_HITMODEL traceline — 1-based
// index into the target's skeleton; 0 means "no bone info" (body damage
// only). The server looks up the hitgroup multiplier so headshot bonuses
// carry through claim-rescued hits.
void(entity target, float damage, float bone_id) CSQC_SendHitclaim =
{
    if (pm_suppress_sounds) return;
    if (!cvar("cl_predict_hits")) return;

    float target_slot;
    if (target.classname == "player_visual_proxy")
        target_slot = target.vis_owner_entnum;
    else
        target_slot = target.entnum;

    if (target_slot <= 0 || target_slot > 32) return;

    // Wire format: "hitclaim <slot> <body_damage> <bone_id>". Body damage
    // is the pre-multiplier falloff value; server applies hitgroup scale.
    localcmd(sprintf("cmd hitclaim %g %g %g\n", target_slot, damage, bone_id));
};

// Fire a predicted traceline and show impact effect instantly.
// Called from per-weapon CSQC prediction after a successful fire.
// Damage params are passed through to CSQC_BulletImpact so breakable-break
// prediction can subtract the shot's damage from the brush's replicated HP.
void(float spread_base, float spread_move, float spread_fullspeed,
     float close_dmg, float min_dmg, float falloff_range) CSQC_PredictedImpact =
{
    vector src, dir, end, flat_vel;
    float move_speed, spread, sx, sy;

    CSQC_MuzzleFlash();

    makevectors(input_angles);
    vector fwd = v_forward;
    vector rt  = v_right;
    vector up  = v_up;
    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = spread_base + (move_speed / spread_fullspeed) * spread_move;
    spread = min(spread, spread_base + spread_move);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        sx  = SH_SpreadJitter(self.wep_action_id, 0) * spread;
        sy  = SH_SpreadJitter(self.wep_action_id, 1) * spread;
        dir = normalize(fwd + rt * sx + up * sy);
    }
    else
        dir = fwd;
    end = src + dir * 8192;

    // MOVE_HITMODEL refines into model hitboxes (bones) when the trace
    // enters a SOLID entity. Visual proxies on CSQC are SOLID_BBOX with
    // the player MDL — so trace_endpos lands on the actual hit bone if a
    // bone was hit, or continues to the wall behind if all bones were
    // missed. Either way the visual matches reality.
    traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);

    if (trace_fraction < 1.0)
    {
        // Player hit if we landed on the engine player entity (entnum
        // 1..maxclients) OR on a visual proxy. Hitmarker only — server's
        // CSQC_EVENT_IMPACT delivers the flesh particle at the same
        // hitbox-precise position ~ping ms later.
        float is_player_hit =
            (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
            || (trace_ent.classname == "player_visual_proxy");

        // Falloff result is the same number the server will apply (before
        // hitgroup multiplier) — compute once, use for both breakable HP
        // prediction and the player hitclaim.
        float dist   = vlen(trace_endpos - src);
        float damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        if (is_player_hit)
        {
            if (cvar("cl_hitmarker") && !pm_suppress_sounds)
            {
                localsound("sounds/weapons/hitmarker.wav");
                HUD_TriggerHitmarker();
            }
            CSQC_SendHitclaim(trace_ent, damage, trace_bone_id);
        }
        else
        {
            CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage);
        }
        if (cvar("cl_debug_impacts"))
            CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
    }
};

// Fire N predicted pellets (shotgun). Damage params match the server's
// per-pellet falloff so break prediction agrees with authoritative HP math.
void(float pellets, float spread_val,
     float close_dmg, float min_dmg, float falloff_range) CSQC_PredictedShotgunImpact =
{
    vector src, dir, end;
    vector fwd, rt, up;
    float sx, sy, i;

    CSQC_MuzzleFlash();

    makevectors(input_angles);
    fwd = v_forward;
    rt  = v_right;
    up  = v_up;
    src = self.origin + self.view_ofs;

    for (i = 0; i < pellets; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * spread_val;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * spread_val;
        dir = normalize(fwd + rt * sx + up * sy);
        end = src + dir * 8192;

        traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);

        if (trace_fraction < 1.0)
        {
            float is_player_hit =
                (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
                || (trace_ent.classname == "player_visual_proxy");

            float dist   = vlen(trace_endpos - src);
            float damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

            if (is_player_hit)
            {
                if (cvar("cl_hitmarker") && !pm_suppress_sounds)
                {
                    localsound("sounds/weapons/hitmarker.wav");
                    HUD_TriggerHitmarker();
                }
                CSQC_SendHitclaim(trace_ent, damage, trace_bone_id);
            }
            else
            {
                CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage);
            }
            if (cvar("cl_debug_impacts"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        }
    }
};

// Fire a predicted melee trace and show hit effect / play hit sound.
// Returns TRUE if something was hit.
//
// `damage` is used to (a) send a hitclaim to the server when a player
// proxy is hit, and (b) predict func_breakable destruction locally so
// crates/glass break instantly on the attacker's screen — matches the
// bullet feel at high ping. Melee uses MOVE_NORMAL (no hitbox refine),
// so trace_bone_id is 0 and claims register as body damage — no melee
// headshot multiplier. Upgrade to MOVE_HITMODEL if you want that later.
void(entity target, float damage) CSQC_PredictBreakableBreak;
float(float range, float damage,
      string hit_snd1, string hit_snd2, string miss_snd) CSQC_PredictedMeleeTrace =
{
    vector src, end;

    makevectors(input_angles);
    src = self.origin + self.view_ofs;
    end = src + v_forward * range;

    traceline(src, end, MOVE_NORMAL, self);

    if (trace_fraction < 1.0)
    {
        float is_player_hit =
            (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
            || (trace_ent.classname == "player_visual_proxy");

        if (is_player_hit)
        {
            CSQC_SendHitclaim(trace_ent, damage, 0);   // melee = body damage only
        }
        else
        {
            // Predict breakable destruction locally so the attacker sees
            // the crate / glass hide instantly instead of waiting ~ping ms
            // for the server's solid_brush_SendEntity update.
            CSQC_PredictBreakableBreak(trace_ent, damage);
        }

        CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
        if (cvar("cl_debug_impacts"))
            CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        if (hit_snd2 != "" && random() < 0.5)
            localsound(hit_snd2);
        else if (hit_snd1 != "")
            localsound(hit_snd1);
        return TRUE;
    }

    if (miss_snd != "")
        localsound(miss_snd);
    return FALSE;
};

void() CSQC_RecordPredictedWeaponSound =
{
    csqc_last_predicted_weapon_sound_time = cltime;
};

void() CSQC_RecordPredictedAutoSound =
{
    csqc_last_predicted_auto_sound_time = cltime;
};

void() CSQC_MarkPendingWeaponAck =
{
    if (pm_suppress_sounds)
        return;

    csqc_weapon_pending_ack_sequence
        = max(csqc_weapon_pending_ack_sequence, csqc_pred_sequence);
};
#endif
