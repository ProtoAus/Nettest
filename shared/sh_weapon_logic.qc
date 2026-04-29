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
// Defined in client/cl_breakable.qc, called from CSQC_TryPredictDeath
// to mirror the server's CSQC_EVENT_PLAYER_GIBS overkill broadcast.
void(vector pos, vector dir, float count, float damage_scale) CSQC_SpawnPlayerGibs;
#endif

// ============================================================
//  Hitgroup helpers (shared — moved from server/sv_weapons.qc so CSQC
//  predicted-death can compute final damage with the same hitgroup
//  multipliers the server applies). Defined unconditionally so SSQC
//  hitscan in sh_weapon_standard.qc can call them too.
// ============================================================

// Map trace_bone_id (1-based) to hitgroup using bone names on the hit
// entity. Works with any model regardless of bone index layout.
// gettagindex is available in both SSQC and CSQC.
float(float bone_id) W_BoneToHitgroup =
{
    if (bone_id <= 0 || !trace_ent)
        return HITGROUP_GENERIC;

    entity ent = trace_ent;

    if (bone_id == gettagindex(ent, "Bip01 Head"))
        return HITGROUP_HEAD;

    if (bone_id == gettagindex(ent, "Bip01 Spine1")
     || bone_id == gettagindex(ent, "Bip01 Spine2")
     || bone_id == gettagindex(ent, "Bip01 Spine3")
     || bone_id == gettagindex(ent, "Bip01 Neck"))
        return HITGROUP_CHEST;

    if (bone_id == gettagindex(ent, "Bip01 Pelvis")
     || bone_id == gettagindex(ent, "Bip01 Spine"))
        return HITGROUP_STOMACH;

    if (bone_id == gettagindex(ent, "Bip01 L Clavicle")
     || bone_id == gettagindex(ent, "Bip01 L UpperArm")
     || bone_id == gettagindex(ent, "Bip01 L Forearm")
     || bone_id == gettagindex(ent, "Bip01 L Hand"))
        return HITGROUP_LEFTARM;

    if (bone_id == gettagindex(ent, "Bip01 R Clavicle")
     || bone_id == gettagindex(ent, "Bip01 R UpperArm")
     || bone_id == gettagindex(ent, "Bip01 R Forearm")
     || bone_id == gettagindex(ent, "Bip01 R Hand"))
        return HITGROUP_RIGHTARM;

    if (bone_id == gettagindex(ent, "Bip01 L Thigh")
     || bone_id == gettagindex(ent, "Bip01 L Calf")
     || bone_id == gettagindex(ent, "Bip01 L Foot")
     || bone_id == gettagindex(ent, "Bip01 L Leg")
     || bone_id == gettagindex(ent, "Bip01 L Leg1"))
        return HITGROUP_LEFTLEG;

    if (bone_id == gettagindex(ent, "Bip01 R Thigh")
     || bone_id == gettagindex(ent, "Bip01 R Calf")
     || bone_id == gettagindex(ent, "Bip01 R Foot")
     || bone_id == gettagindex(ent, "Bip01 R Leg")
     || bone_id == gettagindex(ent, "Bip01 R Leg1"))
        return HITGROUP_RIGHTLEG;

    return HITGROUP_GENERIC;
};

// Damage multiplier per hitgroup (CS 1.6 style).
float(float hitgroup) W_HitgroupDamageMultiplier =
{
    switch (hitgroup)
    {
    case HITGROUP_HEAD:     return 4.0;
    case HITGROUP_CHEST:    return 1.0;
    case HITGROUP_STOMACH:  return 1.25;
    case HITGROUP_LEFTARM:  return 0.75;
    case HITGROUP_RIGHTARM: return 0.75;
    case HITGROUP_LEFTLEG:  return 0.75;
    case HITGROUP_RIGHTLEG: return 0.75;
    default:                return 1.0;
    }
};

#ifdef CSQC
// Hitmarker prediction.  Trust-mode split:
//   sv_trust_clienthits >= 1 → client owns the hitmarker.  Predicted
//     trace fires it instantly here; the server's CSQC_EVENT_HITMARKER
//     emit for player targets is suppressed in W_ApplyDamage so the two
//     don't double up on the attacker's screen.
//   sv_trust_clienthits == 0  → server owns it.  Predicted trace skips
//     the local emit; the server's authoritative CSQC_EVENT_HITMARKER
//     handler in cl_main.qc (CSQC_EVENT_HITMARKER case) plays it on
//     receipt.
// Default 1 in serverkeyfloat fallback so a server that hasn't pushed
// the value yet (during connect bootstrap) still predicts — matches the
// default cvar value.
//
// Pulled out of three identical call sites in CSQC_PredictedImpact /
// CSQC_PredictedPenetratingImpact / CSQC_PredictedShotgunImpact so the
// gate logic lives in one place.
void() CSQC_TryPlayPredictedHitmarker =
{
    if (!cvar("cl_hitmarker"))                                return;
    if (pm_suppress_sounds)                                   return;  // replay
    if (serverkeyfloat("sv_trust_clienthits", 1) < 1)         return;  // server owns
    localsound("sounds/weapons/hitmarker.wav");
    HUD_TriggerHitmarker();
};

// CSQC predicted death — when a CSQC trace hit on a remote player is
// computed to be lethal, flip the visual proxy's vis_is_dead + queue
// the matching death animation locally so the shooter sees the body
// drop instantly instead of after one ping RTT. Server's authoritative
// state arrives ~ping ms later: if we predicted right, the visual is
// already in the death pose and there's no snap; if we predicted wrong
// (target had armor / regen we didn't know about) the next snapshot's
// vis_is_dead=0 + alive anim restores the pose.
//
// Requires:
//   - target.vis_health (synced from server in PlayerVisual_Update)
//   - body_dmg = pre-multiplier falloff damage (same number sent in
//     the hitclaim)
//   - bone_id = trace_bone_id from the predict trace (drives hitgroup)
//
// Skips when:
//   - target already dead (vis_is_dead set)
//   - vis_health unknown (0 — no sample arrived yet; we don't predict
//     because we'd over-fire on every hit)
//   - final damage < vis_health (non-lethal)
void(entity target, float body_dmg, float bone_id) CSQC_TryPredictDeath =
{
    if (!target || target == world) return;
    if (target.classname != "player_visual_proxy") return;
    if (target.vis_is_dead) return;
    if (target.vis_health <= 0) return;   // no health sample → don't guess

    // Compute final damage the same way the server will
    float hitgroup = W_BoneToHitgroup(bone_id);
    float final_dmg = body_dmg * W_HitgroupDamageMultiplier(hitgroup);

    if (final_dmg < target.vis_health) return;   // non-lethal

    // Predict death — flip the proxy's state. Solid drop matches the
    // server's PlayerKilled path (sets victim.solid = SOLID_NOT) so
    // tracelines stop hitting the corpse for the rest of the swing /
    // shotgun spread.
    target.vis_is_dead = 1;
    target.vis_health  = 0;
    target.solid       = SOLID_NOT;

    // Latch: tells CSQC_PlayerVisual_Update to ignore subsequent
    // VP_SF_ANIM updates so the server's late death-anim broadcast
    // (random sub-variant + same-frame restart) doesn't visually
    // re-trigger the death sequence we already played out.  The
    // matching at_time is consulted on rollback so a stale pre-kill
    // "still alive" snapshot can't yank the proxy back to a standing
    // pose before our shot has even round-tripped.
    target.vis_pred_dead_latch   = 1;
    target.vis_pred_dead_at_time = time;

    // Drop the weapon visually — server's PlayerKilled calls
    // W_DropAllWeaponsOnDeath which clears self.weapon, so the proxy
    // sync will eventually push vis_weapon_id=0. Predict it now so
    // the dead body doesn't snap from "armed" to "unarmed" when the
    // server snapshot arrives.
    target.vis_weapon_id = 0;

    // Pick the matching death animation. Mirrors SH_PlayerAnim_Death
    // (shared/sh_player_anims.qc) — head shot → head-snap death anim,
    // gut shot → gut-clutch, anything else → generic CSANIM_DEATH1.
    float deathframe;
    if      (hitgroup == HITGROUP_HEAD)    deathframe = CSANIM_DIE_HEAD;
    else if (hitgroup == HITGROUP_STOMACH) deathframe = CSANIM_DIE_GUT;
    else                                   deathframe = CSANIM_DEATH1;

    // Drive both anim slots (legs + torso). Predraw applies these to
    // the proxy's .frame and .baseframe each render.
    target.vis_anim_bottom = deathframe;
    target.vis_anim_top    = deathframe;

    // Headshot-kill gib prediction — mirrors the server's
    // CSQC_EVENT_PLAYER_GIBS broadcast in W_ApplyDamage. Trigger is
    // hitgroup-based: a lethal headshot gibs ("the head explodes")
    // regardless of weapon power; body-shot kills play the standard
    // death animation only.
    if (hitgroup == HITGROUP_HEAD)
    {
        vector gib_dir = target.origin - self.origin;
        if (vlen(gib_dir) > 0)
            gib_dir = normalize(gib_dir);
        else
            gib_dir = '0 0 1';

        // Same gib-count formula as the server.
        float gib_count = bound(4, 4 + final_dmg / 25, 12);
        CSQC_SpawnPlayerGibs(target.origin + '0 0 24', gib_dir, gib_count, final_dmg);

        // Latch so the server's late CSQC_EVENT_PLAYER_GIBS can be
        // suppressed for this proxy when it arrives ~ping ms later.
        target.vis_pred_gibs_at_time = time;

        // Don't hide the corpse on predicted gib.  The server's
        // PlayerKilled path sets target.player_visual_proxy.modelindex
        // = 0, but that does NOT actually hide the proxy on remote
        // clients — the proxy renders from team_model_byte (read in
        // the VP_SF_IDENTITY_CL parser via setmodel(self, mdl_path)),
        // not from .modelindex.  So third-party witnesses see the body
        // remain when someone is gibbed.  Hiding it locally on the
        // shooter would make their view inconsistent with everyone
        // else's: their kill silently vanishes the corpse while every
        // other player keeps seeing it.  Match the witness behaviour.
    }
};

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
//
// Also runs CSQC_TryPredictDeath on the target so lethal hits flip the
// proxy's vis_is_dead instantly (only when sv_trust_clienthits is on).
void(entity target, float damage, float bone_id) CSQC_SendHitclaim =
{
    // Diagnostics gated on cl_debug_hitclaim — uses print() so output
    // is visible without `developer 1`. Cheap to leave the cvar at 0
    // in production: a single integer cvar read per failed-hit attempt.
    float dbg = cvar("cl_debug_hitclaim");

    if (pm_suppress_sounds)
    {
        if (dbg) print("[hitclaim-cl] skip: pm_suppress_sounds (replay)\n");
        return;
    }
    if (!cvar("cl_predict_hits"))
    {
        if (dbg) print("[hitclaim-cl] skip: cl_predict_hits=0\n");
        return;
    }

    float target_slot;
    if (target.classname == "player_visual_proxy")
        target_slot = target.vis_owner_entnum;
    else
        target_slot = target.entnum;

    if (target_slot <= 0 || target_slot > 32)
    {
        if (dbg)
            print(sprintf("[hitclaim-cl] skip: target_slot=%g (classname='%s' entnum=%g)\n",
                          target_slot, target.classname, target.entnum));
        return;
    }

    // Wire format: "hitclaim <slot> <body_damage> <bone_id>". Body damage
    // is the pre-multiplier falloff value; server applies hitgroup scale.
    if (dbg)
    {
        float bone_f = bone_id;   // coerce int→float for sprintf
        print(sprintf("[hitclaim-cl] SEND slot=%g dmg=%.0f bone=%g classname='%s'\n",
                      target_slot, damage, bone_f, target.classname));
    }
    localcmd(sprintf("cmd hitclaim %g %g %g\n", target_slot, damage, bone_id));

    // Predicted death — runs whenever the helper's lethality check
    // fires. Independent of sv_trust_clienthits because the death is a
    // pure visual (server's authoritative kill arrives ~ping ms later
    // either way). Gated on cl_predict_death so users can disable.
    if (cvar("cl_predict_death"))
        CSQC_TryPredictDeath(target, damage, bone_id);
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

    // Phys props (barrel/can) are CSQC-replicated SOLID_NOT (so pmove
    // ignores them — server uses a tighter trimesh).  This pass does
    // a manual ray-vs-AABB against each prop and overrides the trace
    // globals if any prop sits closer than the current hit.
    CSQC_PhysProp_OverrideTrace(src, end);

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

        // Diagnostic — see cl_debug_hitclaim. Tells us whether the CSQC
        // trace classified the hit as a player. If is_player_hit=0,
        // no hitclaim is sent and bullets do no damage even though the
        // server's own trace landed the splash effect.
        if (cvar("cl_debug_hitclaim"))
        {
            // Coerce __int globals to float for sprintf %g (fteqcc warns
            // otherwise even though the runtime would print correctly).
            float mc_f   = maxclients;
            float bone_f = trace_bone_id;
            print(sprintf("[predict-impact] trace_ent classname='%s' entnum=%g maxclients=%g is_player_hit=%g bone=%g\n",
                          trace_ent.classname, trace_ent.entnum, mc_f,
                          is_player_hit, bone_f));
        }

        if (is_player_hit)
        {
            CSQC_TryPlayPredictedHitmarker();
            // Local flesh splash + impact light. Impact_ClassifyLocal
            // classifies player_visual_proxy as flesh → particle matches
            // what func_breakable BREAKABLE_FLESH would produce. No
            // ricochet sound, no decal (Impact_ShouldSpawnHole excludes
            // flesh).
            CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
            CSQC_SendHitclaim(trace_ent, damage, trace_bone_id);
        }
        else
        {
            CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage);
        }
        if (cvar("cl_debug_impacts"))
            CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
    }
    else if (cvar("cl_debug_hitclaim"))
    {
        // Trace went the full 8192 — completely missed. Helps distinguish
        // "missed everything" from "hit a non-player solid".
        print("[predict-impact] trace_fraction=1 (no hit)\n");
    }
};

// Predicted penetrating hitscan — mirrors W_PenetratingHitscanShoot for
// the visual half. Server stays authoritative for damage; this just gets
// every entry, exit, and post-pen entry decal on the shooter's screen at
// 0 ms so high-ping play doesn't see ping-delayed pops. Re-traces use
// MOVE_NORMAL only (no MOVE_HITMODEL) — re-traces are BSP-vs-bsp.
void(float spread_base, float spread_move, float spread_fullspeed,
     float close_dmg, float min_dmg, float falloff_range,
     float pen_power, float pen_dmg_mult) CSQC_PredictedPenetratingImpact =
{
    vector src, dir, end, flat_vel, entry_pos, exit_pos, exit_normal, nudge_pos;
    float move_speed, spread, sx, sy, dist, damage, wall_thick;
    float pen_remaining, pen_count, is_player_hit;

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

    traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    CSQC_PhysProp_OverrideTrace(src, end);

    pen_remaining = pen_power;
    pen_count = 0;

    while (trace_fraction < 1.0 && pen_count < 4)
    {
        // CRITICAL: outer parens around the entire RHS. fteqcc parses
        // `x = A || B` as `(x = A) || B` (assignment binds tighter than
        // ||), which silently discarded the player_visual_proxy branch
        // — every penetrating-hitscan bullet fired with entnum > 32
        // (visual proxies live above the player slot range) ended up
        // with is_player_hit=0 and never sent a hitclaim. The other
        // three trace helpers escape this by using `float is_player_hit
        // = ...` inline-declaration syntax where the entire RHS is the
        // initializer; here we have a pre-declared local so we MUST
        // parenthesize. Verified against user diagnostic output:
        //   classname='player_visual_proxy' entnum=38 maxclients=32
        //   is_player_hit=0   ← without these parens
        is_player_hit =
            ((trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
             || (trace_ent.classname == "player_visual_proxy"));

        // Diagnostic — see cl_debug_hitclaim. Mirrors CSQC_PredictedImpact
        // so every hitscan weapon (penetrating included) is traceable.
        if (cvar("cl_debug_hitclaim"))
        {
            float mc_f   = maxclients;
            float bone_f = trace_bone_id;
            print(sprintf("[predict-impact-pen] iter=%g classname='%s' entnum=%g maxclients=%g is_player_hit=%g bone=%g\n",
                          pen_count, trace_ent.classname, trace_ent.entnum,
                          mc_f, is_player_hit, bone_f));
        }

        // Capture before the back-trace overwrites trace_ent so the
        // exit decal can be suppressed when the bullet pierced a phys
        // prop (barrel/can).  The prop tips/rolls under ODE, so an
        // exit decal pinned to world space would slide off.
        float entry_was_physprop =
            (trace_ent.classname == "phys_barrel" ||
             trace_ent.classname == "phys_can");

        dist   = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        if (is_player_hit)
        {
            CSQC_TryPlayPredictedHitmarker();
            CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
            CSQC_SendHitclaim(trace_ent, damage, trace_bone_id);
            if (cvar("cl_debug_impacts"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
            break;   // bullets stop on player (matches server)
        }
        else
        {
            CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage);
            if (cvar("cl_debug_impacts"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        }

        if (pen_remaining <= 0) break;

        entry_pos = trace_endpos;
        nudge_pos = entry_pos + dir * pen_remaining;
        traceline(nudge_pos, entry_pos, MOVE_NORMAL, self);
        // CSQC traceline can't see phys props (server-replicated, .solid=0
        // on the client side).  Reuse the cylinder hit-test here so the
        // back-trace lands on the prop's back face — lets penetration
        // continue past a barrel/can with the correct wall_thick chord.
        CSQC_PhysProp_OverrideBackTrace(nudge_pos, entry_pos);
        if (trace_fraction >= 1.0) break;

        exit_pos    = trace_endpos;
        exit_normal = trace_plane_normal;
        wall_thick  = vlen(exit_pos - entry_pos);
        if (wall_thick < 1) wall_thick = 1;
        if (wall_thick > pen_remaining) break;

        pen_remaining -= wall_thick;
        close_dmg *= pow(pen_dmg_mult, wall_thick);
        min_dmg   *= pow(pen_dmg_mult, wall_thick);
        if (close_dmg < 1) break;

        if (!entry_was_physprop)
            CSQC_BulletImpact(exit_pos, exit_normal, close_dmg);
        if (cvar("cl_debug_impacts"))
            CSQC_AddDebugImpact(exit_pos, src, '0 1 0', 0, 0);

        src = exit_pos + dir * 1;
        pen_count++;
        traceline(src, end, MOVE_NORMAL, self);
        // Cylinder check on the post-pen forward trace too — without it,
        // a bullet that pierces a wall and then hits a barrel beyond
        // would dead-end on the wall behind the barrel and decal there.
        CSQC_PhysProp_OverrideTrace(src, end);
    }

    // If the loop exited without an `is_player_hit` break, the bullet
    // either hit world geometry (already handled inside the loop) or
    // missed entirely. Distinguishing helps diagnose "splash but no
    // damage" — a full miss means the trace never even reached the
    // target, so no hitclaim could possibly have been sent.
    if (trace_fraction >= 1.0 && pen_count == 0 && cvar("cl_debug_hitclaim"))
        print("[predict-impact-pen] trace_fraction=1 (no hit on any iter)\n");
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
        CSQC_PhysProp_OverrideTrace(src, end);

        if (trace_fraction < 1.0)
        {
            float is_player_hit =
                (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
                || (trace_ent.classname == "player_visual_proxy");

            // Per-pellet diagnostic — see cl_debug_hitclaim.
            if (cvar("cl_debug_hitclaim"))
            {
                float mc_f   = maxclients;
                float bone_f = trace_bone_id;
                print(sprintf("[predict-impact-shot] pellet=%g classname='%s' entnum=%g maxclients=%g is_player_hit=%g bone=%g\n",
                              i, trace_ent.classname, trace_ent.entnum,
                              mc_f, is_player_hit, bone_f));
            }

            float dist   = vlen(trace_endpos - src);
            float damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

            if (is_player_hit)
            {
                CSQC_TryPlayPredictedHitmarker();
                // Per-pellet flesh splash (shotgun can spray multiple).
                CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
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
// bullet feel at high ping. Trace uses MOVE_NORMAL | MOVE_HITMODEL so
// trace_bone_id is populated; the hitclaim then carries the bone to
// the server, where W_BoneToHitgroup → W_HitgroupDamageMultiplier
// applies the headshot multiplier (knife slash 20 × 4 = 80 to the head).
void(entity target, float damage) CSQC_PredictBreakableBreak;
float(float range, float damage,
      string hit_snd1, string hit_snd2, string miss_snd) CSQC_PredictedMeleeTrace =
{
    vector src, end;

    makevectors(input_angles);
    src = self.origin + self.view_ofs;
    end = src + v_forward * range;

    traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);

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
