// ============================================================
//  shared/sh_weapon_logic.qc  -  Cross-weapon shared utilities
//  Compiled by both sv_progs and cl_progs.
//
//  Per-weapon state machines live in shared/weapons/sh_wpn_*.qc.
//  This file provides utilities used by all weapons.
// ============================================================

// --- Shared utilities ---

// Backend-aware force scale for one-shot physics_addforce impulses (props, gravity gun).
// ODE consumes a queued force in only the FIRST of physics_ode_iterationsperframe substeps
// (delivered impulse = F*frametime/N), so xN keeps that impulse constant across the cvar.
// Box3D applies the force over the WHOLE frame (one b3World_Step; its substeps are internal,
// controlled by physics_box3d_substeps), so there is nothing to cancel -> scale is 1.
// Multiplying by the ODE cvar on Box3D (the default backend) was a phantom multiplier that
// made props + the gravgun push far too hard.  Mirrors Car_Iter (sh_vehicle_phys.qc), which
// learned the same lesson on vehicles.
float() Phys_ForceIter =
{
    if (cvar_string("sv_physics_engine") == "ode")   // ODE: force applies for 1 of N substeps -> xN
    {
        float it = cvar("physics_ode_iterationsperframe");
        if (it < 1) it = 1;
        return it;
    }
    return 1;   // Box3D (default): force applies over the whole frame -> no scaling
};

// W_PlayersExpandHitboxes / W_PlayersRestoreHitboxes bodies live
// outside this file:
//   • SSQC — server/sv_weapons.qc walks the live player chain.
//   • CSQC — shared/sh_weapons.qc walks the player_visual_proxy chain
//            (compiled BEFORE this file in cl_progs.src, so callers
//            here see the symbol without a per-file forward decl).
// The shared decl that used to live here was duplicating the CSQC body
// and producing "redeclaration of function body" at link time.

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

// sv_gunkick — apply a per-shot view-kick impulse. Adds an upward
// pitch impulse + a small yaw jitter to the player's view-kick
// integrator; the spring decay in pmove (sh_pmove.qc) then settles
// it back to zero. Called from each weapon's fire helper BEFORE the
// hitscan trace, so the trace direction includes the kick the user
// is about to see (W_StandardHitscanShoot biases v_angle by the
// integrated kick state right after this).
//
// Both client (predict) and server (authority) call this on the same
// pmove tick with the same wep_action_id — the yaw jitter is
// SH_SpreadJitter axis 2 so it's deterministic without needing to
// be replicated. The integrator state IS replicated via PM_CSQC_PROXY
// (4 floats + 1 byte) for cheap drift insurance under packet loss.
//
// Parameters:
//   kick_pitch    : per-shot pitch impulse magnitude (degrees/sec on the velocity).
//                   Negative pitch = view rotates UP (Quake convention).
//   kick_variance : ± degrees/sec yaw jitter range. Random per shot.
// Cvar accessor — sv_gunkick_* are SV-side cvars. SSQC reads via
// cvar() (authoritative local lookup). CSQC reads via serverkeyfloat()
// because the cvars aren't registered on the client; the server
// publishes them in serverinfo from SV_UpdateMovementServerInfo so
// both sides see identical values without per-tick replication.
// Without this split, CSQC's cvar() returns 0 → falls through to
// defaults → integrator diverges from the server.
float(string name, float default_val) SH_GunkickCvar =
{
#ifdef SSQC
    return cvar(name);
#else
    return serverkeyfloat(name, default_val);
#endif
};

void(float kick_pitch, float kick_variance, optional float weapon_strength) SH_ApplyViewKick =
{
    if (SH_GunkickCvar("sv_gunkick", 1) <= 0)
        return;

    float global_strength = SH_GunkickCvar("sv_gunkick_strength", 1.0);
    if (global_strength <= 0) global_strength = 1.0;
    // weapon_strength is a per-weapon multiplier on top of the global
    // — single-shot weapons (snipers, deagle, shotguns) want a larger
    // kick than auto rifles because the per-shot delay gives the
    // spring time to fully decay before the next shot. Caller passes
    // 1.0 (or omits) for a baseline weapon; >1 for heavier kicks.
    if (weapon_strength <= 0) weapon_strength = 1.0;
    float strength = global_strength * weapon_strength;

    float pitch_impulse = -kick_pitch    * strength;
    float yaw_impulse   = SH_SpreadJitter(self.wep_action_id, 2) * kick_variance * strength;

    // Diminishing-returns soft cap. Each shot adds less impulse the
    // more the view is already kicked — replaces the role the
    // quadratic spring used to play (capping sustained-fire
    // accumulation) without the under-damped overshoot it caused.
    // GUNKICK_SOFT_CAP_DEG is the displacement at which new impulses
    // contribute zero; the linear ramp from 1.0 at displacement=0 to
    // 0.0 at the cap is the standard CS-style recoil response.
    float curr_disp = fabs(self.view_kick_pitch);
    float diminish  = 1.0 - bound(0, curr_disp / GUNKICK_SOFT_CAP_DEG, 1.0);
    pitch_impulse = pitch_impulse * diminish;
    yaw_impulse   = yaw_impulse   * diminish;

    // sv_gunkick_instant: skip the velocity-impulse arch entirely and
    // jump the displacement straight to where the spring would have
    // peaked.  Conversion uses the undamped peak formula
    //     peak_displacement = velocity_impulse / sqrt(k)
    // (k is the spring constant from sv_gunkick_decay_rate).
    //
    // The peak is staged into view_kick_pending_pitch/yaw rather than
    // applied directly: the hitscan trace runs immediately after this
    // call and reads view_kick_pitch / view_kick_yaw to bias its
    // direction.  In velocity-impulse mode the displacement is still
    // zero on the firing tick (only velocity changed), so the trace
    // naturally goes through the un-kicked crosshair.  If we wrote
    // the displacement here, the trace would go through the post-kick
    // crosshair and bullets would track the visible kick instead of
    // where the player aimed.  SH_TickViewKickFrame folds the pending
    // value into the displacement once per frame, AFTER the fire
    // path runs, so the visible kick still snaps to peak the same
    // tick — just on the other side of the trace.
    if (SH_GunkickCvar("sv_gunkick_instant", 0) > 0)
    {
        float k_for_peak = SH_GunkickCvar("sv_gunkick_decay_rate", GUNKICK_SPRING_K_DEFAULT);
        if (k_for_peak <= 0) k_for_peak = GUNKICK_SPRING_K_DEFAULT;
        float omega = sqrt(k_for_peak);
        self.view_kick_pending_pitch += pitch_impulse / omega;
        self.view_kick_pending_yaw   += yaw_impulse   / omega;
    }
    else
    {
        self.view_kick_pitch_vel += pitch_impulse;
        self.view_kick_yaw_vel   += yaw_impulse;
    }
    // Cap at 255: this counter is networked as a BYTE (sv_player.qc:1544
    // PM_PredictionProxy_SendEntity).  A sustained belt spray held across
    // reloads (e.g. the cfm249) would otherwise climb past 255 and WriteByte
    // would truncate it + spam "value N outside 0..255" warnings.  Per-weapon
    // recoil patterns plateau long before 255 shots, so the cap is invisible.
    if (self.view_kick_burst_idx < 255)
        self.view_kick_burst_idx += 1;
    self.view_kick_release_ticks = 0;
};

// Per-pmove-tick spring-damper integration. Pulls view_kick_pitch /
// view_kick_yaw back toward zero with rate proportional to current
// displacement (Hooke), damped to prevent oscillation. Runs every
// tick on both sides — same dt (pm_frametime = input_timelength)
// so client live, client replay, and server pmove integrate
// identically.
//
// Spring formulation gives the user-requested non-linear stacking:
// each shot adds a fixed velocity impulse, but the spring's
// pull-back grows with displacement so sustained fire reaches a
// steady-state instead of climbing forever.
void(float dt) SH_TickViewKickDecay =
{
    if (dt <= 0) return;

    // Same SSQC-vs-CSQC cvar source split as SH_ApplyViewKick — see
    // SH_GunkickCvar comment for why.
    float k = SH_GunkickCvar("sv_gunkick_decay_rate", GUNKICK_SPRING_K_DEFAULT);
    if (k <= 0) k = GUNKICK_SPRING_K_DEFAULT;
    float c = SH_GunkickCvar("sv_gunkick_damping", GUNKICK_DAMPING_DEFAULT);
    if (c <= 0) c = GUNKICK_DAMPING_DEFAULT;

    // Semi-implicit Euler — LINEAR Hooke spring (force = -k*x).
    //
    // Asymmetric damping: full `c` while the kick is being driven
    // OUTWARD (vel and disp same sign — a fresh shot impulse, or the
    // sustained-fire phase where new shots keep adding outward
    // velocity), but ZERO damping during RECOVERY (vel and disp
    // opposite sign — spring is pulling back to zero). This gives
    // the snappy "gun returns to rest fast" feel while keeping
    // sustained fire from oscillating: damping rejects the outward
    // pump but doesn't slow the bounce-back.
    //
    // Without the sign-cross clamp below, no-damping recovery would
    // overshoot zero and the spring would oscillate forever. The
    // clamp catches the moment displacement crosses zero on the
    // recovery half-cycle and snaps the integrator clean.
    float pitch_outward = (self.view_kick_pitch * self.view_kick_pitch_vel) > 0;
    float yaw_outward   = (self.view_kick_yaw   * self.view_kick_yaw_vel)   > 0;
    float c_pitch = pitch_outward ? c : 0;
    float c_yaw   = yaw_outward   ? c : 0;

    float old_pitch = self.view_kick_pitch;
    float old_yaw   = self.view_kick_yaw;

    self.view_kick_pitch_vel += (-k * self.view_kick_pitch
                                 - c_pitch * self.view_kick_pitch_vel) * dt;
    self.view_kick_yaw_vel   += (-k * self.view_kick_yaw
                                 - c_yaw   * self.view_kick_yaw_vel)   * dt;
    self.view_kick_pitch     += self.view_kick_pitch_vel * dt;
    self.view_kick_yaw       += self.view_kick_yaw_vel   * dt;

    // Sign-cross clamp during recovery: if displacement just crossed
    // through zero (old and new have opposite signs), the spring is
    // about to overshoot — kill velocity and snap to zero so we don't
    // bounce. Only relevant when we were recovering (no damping
    // applied this tick), but cheap to test unconditionally.
    if (old_pitch != 0 && (old_pitch * self.view_kick_pitch < 0))
    { self.view_kick_pitch = 0; self.view_kick_pitch_vel = 0; }
    if (old_yaw   != 0 && (old_yaw   * self.view_kick_yaw   < 0))
    { self.view_kick_yaw   = 0; self.view_kick_yaw_vel   = 0; }

    // Snap-to-zero floor — once both displacement and velocity are
    // imperceptible, clamp to clean zero so the integrator doesn't
    // chase float dust across snapshots.
    if (fabs(self.view_kick_pitch) < 0.001 && fabs(self.view_kick_pitch_vel) < 0.01)
    { self.view_kick_pitch = 0; self.view_kick_pitch_vel = 0; }
    if (fabs(self.view_kick_yaw) < 0.001 && fabs(self.view_kick_yaw_vel) < 0.01)
    { self.view_kick_yaw = 0; self.view_kick_yaw_vel = 0; }
};

// Once-per-frame post-fire hook. Called AFTER fire on both sides
// (SSQC: PlayerPostThink; CSQC: end of CSQC_PredictPlayer). Putting
// the decay tick + burst-idx reset here — instead of inside pmove
// — keeps the trace direction consistent between server and client:
// fire reads pre-decay state on both sides, then we decay once per
// frame at the same logical point. Without this, SSQC's
// pmove-then-fire vs CSQC's fire-then-pmove ordering left the
// server's trace one decay step ahead of the client's, and bullet
// impacts landed at the peak of the visible kick instead of where
// the predicted crosshair pointed.
void() SH_TickViewKickFrame =
{
#ifdef SSQC
    float gunkick_on = cvar("sv_gunkick");
#else
    float gunkick_on = serverkeyfloat("sv_gunkick", 1);
#endif
    if (gunkick_on <= 0)
        return;

    // sv_gunkick_instant: fold any pending displacement (staged by
    // SH_ApplyViewKick this frame) into the live displacement before
    // the decay step.  Done here so the prior hitscan trace already
    // ran against pre-kick angles (see SH_ApplyViewKick comment) but
    // the visible view still snaps to peak on the same frame.
    if (self.view_kick_pending_pitch != 0 || self.view_kick_pending_yaw != 0)
    {
        self.view_kick_pitch += self.view_kick_pending_pitch;
        self.view_kick_yaw   += self.view_kick_pending_yaw;
        self.view_kick_pending_pitch = 0;
        self.view_kick_pending_yaw   = 0;
    }

    SH_TickViewKickDecay(input_timelength);

    // Burst-index reset: 2 consecutive frames of !+attack restarts
    // the per-burst counter so per-weapon recoil patterns sync to
    // the start of every spray. Bit 1 = +attack on input_buttons —
    // can't reference PM_BTN_FIRE directly because sh_pmove.qc is
    // included AFTER this file on the SSQC side (sv_progs.src).
    if (!(input_buttons & 1))
    {
        self.view_kick_release_ticks += 1;
        if (self.view_kick_release_ticks >= 2)
            self.view_kick_burst_idx = 0;
    }
    else
    {
        self.view_kick_release_ticks = 0;
    }
};

#ifdef CSQC
// Forward decls — both reset hooks live in CSQC-only files
// (cl_bulletholes.qc, cl_bulletimpact.qc) that compile after this
// one.  The CSQC predict-impact functions below call them at the top
// of every shot to scope the per-shot caps.  Wrapped in #ifdef CSQC
// because the symbols don't exist on the SSQC side; the matching
// call sites are also #ifdef CSQC'd.
void() CSQC_BulletHoles_ResetShot;
void() CSQC_Impact_ResetShot;
// Shotgun-blast bypass flags — see CSQC_PredictedShotgunImpact and the
// cap / ric gates in cl_bulletholes.qc and cl_bulletimpact.qc.
float bh_shotgun_blast;
float bh_shotgun_ric_played;
#endif

// Both sides compute the same hard ADS state from the live input
// bits — the CSQC visual envelope in cl_viewfx.qc is purely cosmetic
// and the spread reduction at fire time uses this gate so server and
// client agree.  v1 hardwires the weapon list (just HDAK47); extend
// by adding to the weapon test.
float() Weapon_IsADSActive =
{
    // ADS/scope eligibility comes from per-weapon fields set in each
    // weapon's Equip (W_SetADSProfile) — no hardcoded WEP_* lists.
    //  - weapon_ads_eligible: pose-ADS weapons that aim on +attack2.
    //  - weapon_scope_class != NONE: CoD-scope weapons (snipers + scoped
    //    rifles), gated on sv_codscopes for the gun-raise spread tighten.
    float is_ads_weapon = 0;
    if (self.weapon_ads_eligible)
        is_ads_weapon = 1;
    if (self.weapon_scope_class != SCOPE_CLASS_NONE && PM_ReadMovevar("sv_codscopes", 0))
        is_ads_weapon = 1;
    if (!is_ads_weapon)
        return 0;
    if (!(input_buttons & 4))               // +attack2 bit
        return 0;
    // Ducking is allowed — CoD-style hold-aim works crouched.
    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
        return 0;
    // Sprint cancels ADS — same gate the sprint multiplier in
    // PM_PlayerMoveStep enforces.  Reading sv_shiftspeed via
    // PM_ReadMovevar so CSQC sees the serverinfo-replicated value.
    if (PM_ReadMovevar("sv_shiftspeed", 1.0) > 1.001
        && (input_buttons & PM_BTN_SPRINT)
        && (self.flags & FL_ONGROUND)
        && input_movevalues_x > 0)
        return 0;
    // Grapple / carry / codladder cancel — the gun has been dropped
    // off-screen by the lower envelope, ADS spread tightening
    // shouldn't apply either.
    if (self.grapple_rope_active)
        return 0;
    if (self.pm_carrying)
        return 0;
    if (self.pm_incar)      // driving a prop_car — gun lowered, fire blocked
        return 0;
    if (PM_ReadMovevar("sv_codladders", 0)
        && self.pm_on_ladder_cached)
        return 0;
    return 1;
};

// Returns a spread multiplier based on player stance (crouch, airborne, landing).
// Also sets sh_spread_flat for a flat additive bonus (ensures low-spread guns still feel penalties).
// Called by both server hitscan and client prediction to keep spread in sync.
float() SH_GetSpreadScale =
{
    float scale = 1.0;
    sh_spread_flat = 0;

    // ADS — tightens spread while the player is aiming.  Multiplicative
    // so it stacks with the existing crouch / landing / sustained-fire
    // gates.  Pulled via PM_ReadMovevar so CSQC's predicted fire sees
    // the same value the server enforces.
    if (Weapon_IsADSActive())
        scale *= PM_ReadMovevar("sv_ads_spread_mult", 0.35);

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

    // CoD scope: bullets land EXACTLY on the crosshair while scoped in (ADS through
    // a cod scope), regardless of movement/jumping.  Computed AFTER the normal
    // crouch/jump/sustained-fire logic + the fire_spread_pending flush above so the
    // shared state stays consistent with the unscoped path; this just overrides the
    // returned scale.  Both server and client reach here with the same scoped state
    // (Weapon_IsADSActive + the synced weapon_scope_class), so they agree on zero
    // spread.  Applies to any cod-scope weapon (weapon_scope_class != NONE), not
    // plain red-dot/iron-sight ADS.  The crosshair (cl_crosshair.qc) calls this too,
    // so the reticle reads tight to confirm the pinpoint accuracy.
    if (self.weapon_scope_class != SCOPE_CLASS_NONE
        && Weapon_IsADSActive()
        && PM_ReadMovevar("sv_codscopes", 0))
    {
        sh_spread_flat = 0;
        return 0;
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
void(vector pos, vector normal, float damage, float is_exit) CSQC_BulletImpact;
void() HUD_TriggerHitmarker;
void(vector pos, vector normal) CSQC_BulletImpactSilent;
void(vector pos, vector normal) Impact_SpawnSmokeOnly;
float() Impact_ParticleOffset;
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

    // Head: HL studio "Bip01 Head" carries over to the IQM rig too.
    // Neck is folded into HEAD because the IQM player models extend
    // the head/neck hitbox down to the collarbone — a hit that lands
    // on the neck bone visually reads as a headshot to the shooter,
    // so the multiplier should follow.  (Legacy MDLs had a tighter
    // head hitbox so neck-as-head wasn't a problem there.)
    if (bone_id == gettagindex(ent, "Bip01 Head")
     || bone_id == gettagindex(ent, "Bip01 Neck"))
        return HITGROUP_HEAD;

    if (bone_id == gettagindex(ent, "Bip01 Spine1")
     || bone_id == gettagindex(ent, "Bip01 Spine2")
     || bone_id == gettagindex(ent, "Bip01 Spine3"))
        return HITGROUP_CHEST;

    if (bone_id == gettagindex(ent, "Bip01 Pelvis")
     || bone_id == gettagindex(ent, "Bip01 Spine"))
        return HITGROUP_STOMACH;

    // Arms: legacy HL studio rig uses Clavicle/UpperArm/Forearm; the
    // IQM rig the mod converted to uses Arm/Arm1/Arm2 (see g_pbones
    // in cl_player.qc).  gettagindex returns 0 for any name that
    // doesn't exist in the current model, so listing both naming
    // schemes is safe — only the present bones can ever match.
    if (bone_id == gettagindex(ent, "Bip01 L Clavicle")
     || bone_id == gettagindex(ent, "Bip01 L UpperArm")
     || bone_id == gettagindex(ent, "Bip01 L Forearm")
     || bone_id == gettagindex(ent, "Bip01 L Arm")
     || bone_id == gettagindex(ent, "Bip01 L Arm1")
     || bone_id == gettagindex(ent, "Bip01 L Arm2")
     || bone_id == gettagindex(ent, "Bip01 L Hand"))
        return HITGROUP_LEFTARM;

    if (bone_id == gettagindex(ent, "Bip01 R Clavicle")
     || bone_id == gettagindex(ent, "Bip01 R UpperArm")
     || bone_id == gettagindex(ent, "Bip01 R Forearm")
     || bone_id == gettagindex(ent, "Bip01 R Arm")
     || bone_id == gettagindex(ent, "Bip01 R Arm1")
     || bone_id == gettagindex(ent, "Bip01 R Arm2")
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

// Classify a world hit point into a hitgroup by which per-bone OBB box (the
// boxes cl_debug_hitboxes / sv_debug_hitboxes draw) contains it — accurate
// head/chest/limb vs the Z-height guess.  Returns the box's hitgroup, or -1 if
// the point is in no box (caller falls back).  gettaginfo gives each bone's
// origin + orthonormal axes; the box is axis-aligned in that frame.  SHARED:
// works on the SERVER player (lag-comp-rewound pose) AND the CLIENT proxy (both
// carry the skeleton), so EVERY hit path — penetrating / shotgun / melee /
// standard, trust 0 or 1 — classifies identically (this is the fix for "head
// reads as chest" and "both legs read as left leg" on the penetrating guns).
float(entity target, vector hit_pos) HitgroupAtPoint =
{
    float i;
    for (i = 0; i < HITBOX_COUNT; i++)
    {
        float bone = gettagindex(target, hitbox_bonename[i]);
        if (bone <= 0)
            continue;
        vector bpos = gettaginfo(target, bone);
        vector vf = v_forward, vr = v_right, vu = v_up;
        vector bmn = hitbox_mins[i], bmx = hitbox_maxs[i];
        vector rel = hit_pos - bpos;
        float lx = rel * vf, ly = rel * vr, lz = rel * vu;
        if (lx >= bmn_x && lx <= bmx_x
         && ly >= bmn_y && ly <= bmx_y
         && lz >= bmn_z && lz <= bmx_z)
            return hitbox_group[i];
    }
    return -1;
};

// Damage multiplier per hitgroup (CS 1.6 style).
// Classify a hit into a hitgroup using bone names first, falling
// back to a vertical Z-height bin when bone-name lookup returns
// GENERIC.  The fallback covers two failure modes:
//   - trace_bone_id == 0 (engine couldn't refine to a bone — happens
//     on some IQM rigs depending on weight setup)
//   - bone_id points at a bone whose name isn't in the classifier
//     (renamed exports, custom rigs)
// hit_pos is the world-space impact point (trace_endpos).  target is
// the entity that was hit — used for its absmin/absmax to normalise
// the Z fraction across both standing (~56 qu) and crouching (~32 qu)
// player hulls without a hardcoded height.
//
// The Z fallback loses left/right arm distinction; both fold into the
// "limb" bucket (HITGROUP_LEFTLEG by convention).  That's acceptable
// because the multipliers for L/R arms + legs are all 0.75 — the
// distinction only affects flinch animation choice, not damage.
float(entity target, vector hit_pos, float bone_id) W_HitgroupClassify =
{
    if (!target || target == world)
        return HITGROUP_GENERIC;

    // Hitgroups are a player-anatomy concept (head / chest / stomach /
    // arms / legs).  Non-player targets — func_breakables, phys props,
    // dropped weapons, doors, anything else with a bbox — must NOT
    // route through the Z-zone classifier below, because:
    //   1. The Z-zone math just inspects the target's bbox; for a
    //      tall crate it'd report "HEAD" for top-22% hits, "STOMACH"
    //      for mid-low, etc.  Visually showed up in cl_debug_impacts
    //      as red/yellow labels on inanimate objects.
    //   2. Worse: W_HitgroupDamageMultiplier maps HITGROUP_HEAD to
    //      4× damage, so top-of-bbox hits on breakables were silently
    //      dealing 4× the intended damage — a stealth "crate
    //      headshot" buff.
    // GENERIC has a 1× multiplier and no debug label, which is what
    // we want for non-player hits.
    if (target.classname != "player"
        && target.classname != "player_visual_proxy")
        return HITGROUP_GENERIC;

    // Prop Hunt: a disguised hider is a prop-shaped player — no anatomy.
    // Flatten BEFORE the Z-zone math or the top ~22% of every crate is a
    // 4x "headshot" (and CSQC_TryPredictDeath's head branch would fire
    // gibs at player head height).  This is the classify every path uses:
    // CSQC hitclaims (the damage source under sv_trust_clienthits >= 1),
    // the server-auth trace, and projectile hits.  Field rides the proxy
    // IDENTITY wire client-side and lives on the player entity server-side.
    if (target.ph_disguise_modelindex)
        return HITGROUP_GENERIC;

    // nettest Patch 36 Part B: native per-bone hitbox collision.  When the engine traced the
    // player's registered hitboxes (MOVE_HITMODEL on a model with addmodelhitbox boxes — see
    // Hitbox_RegisterModel), it reports the EXACT struck box's hitgroup in trace_surface_id
    // (1=head..7=Rleg).  This is the box you hit on the leaned/twisted Part A pose — no
    // Z-height guess, no mesh-vs-render mismatch, and identical on the server (trust 0) and
    // client (trust 1) traces.  bone_id>0 confirms a hitmodel/box hit (brush traces leave it 0).
    // Falls through to the legacy Z-height classifier below for models without registered boxes
    // (e.g. the sini .mdl) or on an unpatched engine.
    if (bone_id > 0 && trace_surface_id >= HITGROUP_HEAD && trace_surface_id <= HITGROUP_RIGHTLEG)
        return trace_surface_id;

    // NOTE: a per-bone OBB box classifier (HitgroupAtPoint) was tried here this
    // session and REMOVED.  The boxes come from gettaginfo on the SERVER pose,
    // where the IQM player's view-pitch LEAN does not exist — it is a CLIENT-
    // render-only skel_set_bone spine deform (cl_player.qc PlayerVis_PitchBone),
    // and the server clears its own skeleton every tick (SH_PlayerAnim_Clear-
    // IQMSpine).  So a shot at a LEANED target landed outside the upright server
    // boxes -> -1 or a wrong box -> poisoned the result in both trust modes.
    // Classify off the mesh trace's bone_id + a Z-height fallback (below) which
    // is independent of box accuracy.  A box pass can only return once the
    // server carries the same spine-pitch skeleton the proxy does.

    // Z-fraction first.  On the IQM rig the bone-weight engine refine
    // can route a clean headshot to a neck/upper-spine bone because
    // the head triangle has higher weight on Bip01 Spine3 than on
    // Bip01 Head — and the legacy bone-name classifier dutifully
    // returns CHEST in that case, collapsing the head multiplier.
    // Use the hit Z relative to the target's vertical bbox to win
    // the head zone (top ~22%, generous CS-style head hitbox feel)
    // regardless of what bone the engine picked.
    float total_h = target.absmax_z - target.absmin_z;
    float frac = 0;
    if (total_h > 0)
    {
        frac = (hit_pos_z - target.absmin_z) / total_h;
        if (frac >= 0.78)
            return HITGROUP_HEAD;
    }

    // Bone-name lookup picks up specific arm/leg/spine distinctions
    // the Z fallback would lose.  Swap trace_ent so W_BoneToHitgroup
    // (which reads it as a global) sees our target without mutating
    // the caller's trace state.
    float hg;
    {
        entity saved_te = trace_ent;
        trace_ent = target;
        hg = W_BoneToHitgroup(bone_id);
        trace_ent = saved_te;
    }
    if (hg != HITGROUP_GENERIC)
        return hg;

    // Final Z fallback for non-head zones when bone-name returned
    // GENERIC (bone_id == 0 or unknown bone name).
    if (total_h <= 0)
        return HITGROUP_GENERIC;
    // L/R leg split: only the SPINE pitches with view-aim (client render only),
    // the LEGS never pitch, so the L/R thigh bones are accurate on both sides.
    // Pick whichever thigh the hit is closer to (robust, no axis-sign guess) —
    // the fix for "both legs read as left leg" when trace_bone_id was 0.
    float hg_z;
    float lthigh = gettagindex(target, "Bip01 L Thigh");
    float rthigh = gettagindex(target, "Bip01 R Thigh");
    vector lpos = gettaginfo(target, lthigh);
    vector rpos = gettaginfo(target, rthigh);
    float legside = HITGROUP_LEFTLEG;
    if (lthigh > 0 && rthigh > 0 && vlen(hit_pos - rpos) < vlen(hit_pos - lpos))
        legside = HITGROUP_RIGHTLEG;

    if      (frac >= 0.55) hg_z = HITGROUP_CHEST;
    else if (frac >= 0.35) hg_z = HITGROUP_STOMACH;
    else                   hg_z = legside;

    // Optional verbose trace.  Spam-heavy by design — flip
    // `cl_debug_hitgroup 1` for a shot or two when verifying that
    // headshots are landing on the head hitgroup at the expected Z.
    if (cvar("cl_debug_hitgroup"))
    {
        float bid_f = bone_id;
        print(sprintf("[hitgroup] bone=%g name_hg=%g frac=%.2f z=(%.1f..%.1f hit=%.1f) final=%g\n",
                      bid_f, hg, frac,
                      target.absmin_z, target.absmax_z, hit_pos_z,
                      hg_z));
    }
    return hg_z;
};

float(float hitgroup) W_HitgroupDamageMultiplier =
{
    switch (hitgroup)
    {
    // Prop Hunt / non-anatomy targets.  W_HitgroupClassify flattens every disguised
    // hider (and every non-player) to GENERIC, so this is THE prop-hunt damage
    // multiplier: flat body damage, no zone bonuses, anywhere on the prop.  Spelled out
    // as its own case rather than riding `default` so it reads as the deliberate
    // balance decision it is, and so a future zone tweak can't quietly change it.
    case HITGROUP_GENERIC:  return 1.0;
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
// Forward decl — bullet tracers, defined in client/cl_tracers.qc
// (compiled later in cl_progs.src order than this shared file).
void(vector start_pos, vector end_pos) CSQC_SpawnTracer;
// Forward decl — muzzle world-position resolver for tracer starts.
vector() CSQC_MuzzleFlashWorldPos;

void(vector src, vector end, float moveflags, entity ignore) CSQC_WeaponTraceLine =
{
    entity mask_ent;
    int saved_mask;

    if (!cvar("cl_weapontrace_ignore_playerclip"))
    {
        traceline(src, end, moveflags, ignore);
        return;
    }

    mask_ent = ignore;
    if (!mask_ent)
        mask_ent = self;

    if (!mask_ent || mask_ent == world)
    {
        traceline(src, end, moveflags, ignore);
        return;
    }

    saved_mask = mask_ent.hitcontentsmaski;
    if (saved_mask == 0i)
        mask_ent.hitcontentsmaski = CONTENTBITS_POINTSOLID;
    else
        mask_ent.hitcontentsmaski = saved_mask & ~CONTENTBIT_PLAYERCLIP;

    traceline(src, end, moveflags, ignore);
    mask_ent.hitcontentsmaski = saved_mask;
};

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
// in_hitgroup (optional): the hitgroup the caller classified at the moment of the hit, while
// the trace globals were still fresh.  CRITICAL — the lethality threshold below uses the
// hitgroup damage multiplier, so re-deriving it here would read FX-clobbered trace_endpos and
// (when the hand is raised to head height) Z-classify an ARM hit as a HEADSHOT -> 4x -> predict
// a kill the server never makes (victim "dies" on the shooter's screen but is alive with hp).
void(entity target, float body_dmg, float bone_id, optional float in_hitgroup) CSQC_TryPredictDeath =
{
    if (!target || target == world) return;
    if (target.classname != "player_visual_proxy") return;
    if (target.vis_is_dead) return;
    if (target.vis_health <= 0) return;   // no health sample → don't guess

    // Friendly-fire gate: mirror the server's W_ApplyDamage / SV_HandleHitclaim
    // FF rejection (sv_player.qc:2440, sv_weapons.qc:1039). When teams are
    // active and FF is off, the server discards friendly hitclaims — so
    // predicting the death here would flip vis_is_dead + play the death
    // anim locally even though the teammate keeps moving on the server.
    // Reads mp_friendlyfire from serverkey (server pushes it via serverinfo
    // in sv_main.qc); falls back to cvar() for listen-server / pre-handshake.
    if (!Gamemode_HasUnifiedTeams())
    {
        float local_team = getstati(STAT_PLAYERTEAM);
        if (local_team > TEAM_NONE
            && target.vis_team == local_team)
        {
            float ff = serverkeyfloat("mp_friendlyfire", -1);
            if (ff < 0) ff = cvar("mp_friendlyfire");
            if (!ff) return;
        }
    }

    // Paintgun gamemode: every player-targeted paintball / snowball
    // hit is a tag kill regardless of body damage.  Server bumps the
    // claim to 1000 in SV_HandleHitclaim's paintgun branch; mirror
    // the lethality decision here so cl_predict_death actually fires
    // (otherwise body_dmg = ~5 fails the < vis_health check and the
    // tag prediction never runs, leaving the local view "alive" for
    // a round-trip while the server already counted the kill).
    // Resolve hitgroup once.  In paintgun mode the multiplier doesn't
    // matter (every hit is a fixed-damage kill), but we still need
    // the hitgroup later to pick the matching death animation.
    // Patch 36: prefer the hitgroup the caller captured while the trace globals were fresh;
    // re-deriving here would read FX-clobbered trace_endpos and mis-classify (arm->headshot).
    float hitgroup;
    if (in_hitgroup >= HITGROUP_HEAD && in_hitgroup <= HITGROUP_RIGHTLEG)
        hitgroup = in_hitgroup;
    else
        hitgroup = W_HitgroupClassify(target, trace_endpos, bone_id);

    float is_paintgun_kill = (getstatf(STAT_GAMEMODE) == GAMEMODE_PAINTGUN);
    float final_dmg;
    if (is_paintgun_kill)
    {
        // Server bumps paintball claims to 1000 in SV_HandleHitclaim's
        // paintgun branch; mirror it here so cl_predict_death actually
        // fires.  Without this the body damage (~5) fails the < vis_health
        // check below and the predicted tag never plays.
        final_dmg = 1000;
    }
    else
    {
        // Compute final damage the same way the server will — keeps
        // the predicted death threshold aligned with the authoritative
        // hitgroup + multiplier the server applies post-claim.
        final_dmg = body_dmg * W_HitgroupDamageMultiplier(hitgroup);
    }

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

        // Matches the server's fixed gib count in sv_weapons.qc.
        float gib_count = 6;
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
// in_hitgroup (optional): the hitgroup classified by the CALLER at the moment of the hit,
// while the trace globals were still fresh.  REQUIRED for the engine per-bone hitbox path
// (Patch 36 Part B): the FX calls between the trace and this function (CSQC_BulletImpactSilent
// re-traces for the impact decal) clobber trace_bone_id/trace_surface_id to 0, so re-deriving
// the hitgroup HERE would lose the box and fall back to a Z-height guess (arms -> chest/stomach).
// If omitted/0, falls back to the (possibly stale) re-derivation for legacy callers (melee).
void(entity target, float damage, float bone_id, optional float in_hitgroup) CSQC_SendHitclaim =
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

    // (Removed the client-side vis_is_dead "ghost-corpse" gate that used to
    // bail here.  It was meant to avoid damaging a freshly-respawned player by
    // shooting their stale alive-pose proxy, but it FALSE-NEGATIVED legitimate
    // LIVE hits whenever a proxy's vis_is_dead was momentarily stale — the
    // "blood splatter but no damage with sv_trust_clienthits 1" bug.  Stale
    // claims are now rejected authoritatively SERVER-side via the life-serial
    // check in SV_HandleHitclaim, so the client always forwards the claim and
    // lets the server decide.  The life_serial sent below carries the proxy's
    // life so the server can tell a live hit from an old-life ghost.)

    // Compute the hitgroup right here on the client.  The client has
    // the player model loaded for rendering so gettagindex works
    // reliably, and W_HitgroupClassify's Z fallback covers IQM rigs
    // where bone-name lookup is unreliable.  Sending the classified
    // hitgroup means the server doesn't need to repeat the work in
    // a context (post-cmd-parse) where its own model state may not be
    // ready for tag queries.
    float claim_hg;
    if (in_hitgroup >= HITGROUP_HEAD && in_hitgroup <= HITGROUP_RIGHTLEG)
        claim_hg = in_hitgroup;                                  // caller captured it fresh (Patch 36)
    else
        claim_hg = W_HitgroupClassify(target, trace_endpos, bone_id);   // legacy/melee fallback

    // Wire format:
    //   hitclaim <slot> <body_damage> <bone_id> <hitgroup> <life_serial>
    // life_serial is mirrored from the visual proxy's owner slot and
    // lets the server reject stale old-life/corpse proxies after respawn.
    // Body damage is the pre-multiplier falloff value; the hitgroup
    // byte drives the multiplier on the server.  Older builds without
    // the 4th arg fall back to server-side bone lookup.
    if (dbg)
    {
        float bone_f = bone_id;   // coerce int→float for sprintf
        print(sprintf("[hitclaim-cl] SEND slot=%g dmg=%.0f bone=%g hg=%g life=%g classname='%s'\n",
                      target_slot, damage, bone_f, claim_hg,
                      target.vis_life_serial, target.classname));
    }
    localcmd(sprintf("cmd hitclaim %g %g %g %g %g\n",
                     target_slot, damage, bone_id, claim_hg,
                     target.vis_life_serial));

    // Predicted death — runs whenever the helper's lethality check
    // fires. Independent of sv_trust_clienthits because the death is a
    // pure visual (server's authoritative kill arrives ~ping ms later
    // either way). Gated on cl_predict_death so users can disable.
    // Runs BEFORE the flinch predict below so the flinch can check
    // vis_is_dead to skip itself on lethal hits.
    if (cvar("cl_predict_death"))
        CSQC_TryPredictDeath(target, damage, bone_id, claim_hg);

    // Predicted flinch — set vis_flinch_until on the target proxy
    // so the shooter sees the recoil instantly (without waiting for
    // the server's CSQC_EVENT_PLAYER_FLINCH multicast ~ping ms
    // later).  Server fires the same event for OTHER clients; the
    // shooter's prediction here is overwritten by the server event
    // when it arrives — harmless since both set the same value.
    //
    // Gated on:
    //   - target is a visual proxy
    //   - cl_player_flinch_time > 0 (cvar opt-out)
    //   - target is NOT dying — vis_is_dead set by CSQC_TryPredictDeath
    //     above when the predicted final_dmg >= vis_health.  Without
    //     this gate, lethal hits flinch the body briefly before the
    //     death anim kicks in, which the user reported as "the flinch
    //     messes with the death animation".
    //
    // Hitgroup derivation: bone_id 0 means "no bone info" (body shot,
    // GUT flinch).  We can't run W_BoneToHitgroup client-side, so we
    // default to GUT and let the server multicast overwrite with
    // HEAD when applicable.
    if (target.classname == "player_visual_proxy"
        && !target.vis_is_dead
        && cvar("cl_player_flinch_time") > 0)
    {
        float fdur = cvar("cl_player_flinch_time");
        target.vis_flinch_until    = cltime + fdur;
        target.vis_flinch_hitgroup = HITGROUP_GENERIC;
        // The server's CSQC_EVENT_PLAYER_FLINCH multicast is now tagged with the attacker slot
        // and skipped on the attacker's own client (cl_main.qc), so this prediction is NOT
        // double-stamped — timing-independent, unlike the old client-side time-window latch.
    }
};

// Send a breakclaim to the server.  Mirror of CSQC_SendHitclaim but for
// func_breakable targets — when sv_trust_clientbreak is ON, client owns
// the damage source (sends per-shot claims here) and server defers its
// own trace damage on those targets so they don't double-apply.
//
// Pre-conditions checked before sending:
//   - not in pmove replay (claim was already sent on the live tick)
//   - server pushed sv_trust_clientbreak >= 1 via serverinfo (otherwise
//     server would reject and we'd waste a packet)
//   - cl_predict_hits is on (W_ShouldDeferBreakToClaim mirrors this gate
//     so a player who opts out of prediction sees server-auth as today)
//   - target is a real damageable non-player entity with a valid entnum
//   - damage is positive
//
// Wire format: "breakclaim <target_entnum> <damage>".  Server validates
// classname == func_breakable and applies via W_ApplyDamage.
void(entity target, float damage) CSQC_SendBreakClaim =
{
    float dbg = cvar("cl_debug_hitclaim");

    if (pm_suppress_sounds)
    {
        if (dbg) print("[breakclaim-cl] skip: pm_suppress_sounds (replay)\n");
        return;
    }
    if (serverkeyfloat("sv_trust_clientbreak", 0) < 1)
        return;
    if (!cvar("cl_predict_hits"))
    {
        if (dbg) print("[breakclaim-cl] skip: cl_predict_hits=0\n");
        return;
    }
    if (!target || target == world)
        return;
    if (target.classname == "player" || target.classname == "player_visual_proxy")
        return;
    if (target.entnum <= 0)
        return;
    if (damage <= 0)
        return;

    if (dbg)
    {
        float ent_f = target.entnum;
        print(sprintf("[breakclaim-cl] SEND ent=%g dmg=%.0f classname='%s'\n",
                      ent_f, damage, target.classname));
    }
    localcmd(sprintf("cmd breakclaim %g %g\n", target.entnum, damage));
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

    // Scope the per-shot decal + impact-light caps to THIS predicted
    // shot.  W_PenetratingHitscanShoot's reset only runs on SSQC, so
    // without these the local shooter never resets and the very first
    // post-spawn shot leaves the counter pegged for the rest of the
    // session.
#ifdef CSQC
    CSQC_BulletHoles_ResetShot();
    CSQC_Impact_ResetShot();
#endif

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
    //
    // sv_hitbox_expand widens each remote proxy's bbox for the duration
    // of the trace so MOVE_HITMODEL can reach outstretched limbs — same
    // forgiveness the server-auth hitscan path already applies on its
    // side (server/sv_weapons.qc).  Without it, sv_trust_clienthits 1
    // shooters were missing limbs the server would have hit.
    // Detection is the engine MOVE_HITMODEL mesh trace (matches the server's
    // own hit path).  The OBB-ray detector tried this session was reverted: its
    // boxes are upright on the client-vs-server pose split (see W_HitgroupClassify
    // note) and it depended on the same un-tracking boxes.
    W_PlayersExpandHitboxes();
    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();

    // Phys props (barrel/can) are CSQC-replicated SOLID_NOT (so pmove ignores
    // them — server uses a tighter trimesh).  Manual ray-vs-AABB; overrides the
    // trace globals if any prop sits closer than the current hit.
    CSQC_PhysProp_OverrideTrace(src, end);
    CSQC_DroppedWeapon_OverrideTrace(src, end);

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

        // hoisted: also read in the cl_debug_impacts block below (same is_player_hit guard);
        // initialising here keeps fteqcc's F302 flow-analysis happy (it can't prove the two
        // separate is_player_hit branches are mutually consistent).
        float hit_hg = 0;
        if (is_player_hit)
        {
            // Patch 36: classify the hitgroup NOW, while the trace globals are fresh.  The FX
            // below (CSQC_BulletImpactSilent re-traces for the impact decal) clobber
            // trace_bone_id/trace_surface_id to 0, so deferring this to CSQC_SendHitclaim would
            // lose the engine per-bone box and fall back to a Z-height guess (arms -> chest).
            hit_hg  = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
            float hit_bid = trace_bone_id;
            CSQC_TryPlayPredictedHitmarker();
            // Local flesh splash + impact light. Impact_ClassifyLocal
            // classifies player_visual_proxy as flesh → particle matches
            // what func_breakable BREAKABLE_FLESH would produce. No
            // ricochet sound, no decal (Impact_ShouldSpawnHole excludes
            // flesh).
            CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
            CSQC_SendHitclaim(trace_ent, damage, hit_bid, hit_hg);
        }
        else
        {
            CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage, 0);
        }
        if (cvar("cl_debug_impacts"))
        {
            // Player hits: report the CLIENT'S predicted damage in
            // yellow with the resolved hitgroup label.  Under
            // sv_trust_clienthits the client is the authority on what
            // damage just landed; showing the server's auth number
            // would either double-report or worse, contradict the
            // client's own damage prediction.  Non-player hits keep
            // the simple green dot (no hitgroup, no damage).
            if (is_player_hit)
            {
                float pred_hg  = hit_hg;   // Patch 36: use the fresh-captured hitgroup, not a clobbered re-trace
                float pred_dmg = damage * W_HitgroupDamageMultiplier(pred_hg);
                CSQC_AddDebugImpact(trace_endpos, src, '1 1 0',
                                    pred_dmg, pred_hg);
            }
            else if (!(trace_ent && trace_ent.classname == "csqc_dropped_weapon"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        }
    }
    else if (cvar("cl_debug_hitclaim"))
    {
        // Trace went the full 8192 — completely missed. Helps distinguish
        // "missed everything" from "hit a non-player solid".
        print("[predict-impact] trace_fraction=1 (no hit)\n");
    }

    // Bullet tracer (visual only) — spawn from eye to wherever the
    // trace ended (impact point on hit, far end on miss).  Suppressed
    // during reconcile-replay so each shot only emits one ribbon.
    if (!pm_suppress_sounds)
    {
        // Tracer start = muzzle world position (set by the same
        // weapon's CSQC_MuzzleFlashAtMuzzle call earlier this
        // tick).  Falls back to camera origin if no muzzle flash
        // fired — the cl_tracers offset hack handles that case.
        vector tr_start = CSQC_MuzzleFlashWorldPos();
        CSQC_SpawnTracer(tr_start, (trace_fraction < 1.0) ? trace_endpos : end);
    }
};

// Predicted penetrating hitscan — mirrors W_PenetratingHitscanShoot for
// the visual half. Server stays authoritative for damage; this just gets
// every entry, exit, and post-pen entry decal on the shooter's screen at
// 0 ms so high-ping play doesn't see ping-delayed pops. Re-traces use
// MOVE_NORMAL only (no MOVE_HITMODEL) — re-traces are BSP-vs-bsp.
void(float spread_base, float spread_move, float spread_fullspeed,
     float close_dmg, float min_dmg, float falloff_range,
     float pen_power, float pen_dmg_mult,
     optional float kick_pitch, optional float kick_variance,
     optional float kick_strength) CSQC_PredictedPenetratingImpact =
{
    vector src, dir, end, flat_vel, entry_pos, exit_pos, exit_normal, nudge_pos;
    float move_speed, spread, sx, sy, dist, damage, wall_thick;
    float pen_remaining, pen_count, is_player_hit;

    // Per-shot reset — see comment in CSQC_PredictedImpact.
#ifdef CSQC
    CSQC_BulletHoles_ResetShot();
    CSQC_Impact_ResetShot();
#endif

    CSQC_MuzzleFlash();

    // Apply the per-shot kick impulse first so the trace direction
    // below uses the kicked aim (matches W_PenetratingHitscanShoot on
    // the server side). Without this, decals predicted on the client
    // would appear at the un-kicked direction and snap to the kicked
    // direction when the server snapshot arrives.
    SH_ApplyViewKick(kick_pitch, kick_variance, kick_strength);

    vector saved_input = input_angles;
    input_angles_x += self.view_kick_pitch;
    input_angles_y += self.view_kick_yaw;
    makevectors(input_angles);
    input_angles = saved_input;
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

    // sv_hitbox_expand around the MOVE_HITMODEL initial trace so the
    // engine's bbox-cull doesn't reject reach bones (outstretched
    // arms/legs that poke past the strict movement hull).  Mirrors
    // the wrapping already done in CSQC_PredictedImpact.  Penetration
    // back-traces below are MOVE_NORMAL only — they probe wall
    // thickness, not player hits, so they stay unexpanded to avoid
    // spurious hits on expanded bbox empty air.
    W_PlayersExpandHitboxes();
    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();
    CSQC_PhysProp_OverrideTrace(src, end);
    CSQC_DroppedWeapon_OverrideTrace(src, end);

    pen_remaining = pen_power;
    pen_count = 0;

    // Tracer from the muzzle to the FIRST impact (or the far end on
    // a clean miss).  Penetration re-traces overwrite trace_endpos
    // and `src` later in the loop, so capture it here.  Suppressed
    // during reconcile-replay.
    if (!pm_suppress_sounds)
    {
        // Tracer start = muzzle world position (set by the same
        // weapon's CSQC_MuzzleFlashAtMuzzle call earlier this
        // tick).  Falls back to camera origin if no muzzle flash
        // fired — the cl_tracers offset hack handles that case.
        vector tr_start = CSQC_MuzzleFlashWorldPos();
        CSQC_SpawnTracer(tr_start, (trace_fraction < 1.0) ? trace_endpos : end);
    }

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
             trace_ent.classname == "phys_can" ||
             trace_ent.classname == "csqc_dropped_weapon");

        dist   = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        if (is_player_hit)
        {
            // Patch 36: classify NOW (fresh globals) — FX below clobber trace_bone_id/surface_id.
            float hit_hg  = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
            float hit_bid = trace_bone_id;
            CSQC_TryPlayPredictedHitmarker();
            CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
            CSQC_SendHitclaim(trace_ent, damage, hit_bid, hit_hg);
            if (cvar("cl_debug_impacts"))
            {
                // Player hit in the penetration path — use the same
                // yellow + hitgroup-damage report the non-penetration
                // impact uses, so the user reads the actual landed damage.
                float pen_hg  = hit_hg;   // Patch 36: use the fresh-captured hitgroup, not a clobbered re-trace
                float pen_dmg = damage * W_HitgroupDamageMultiplier(pen_hg);
                CSQC_AddDebugImpact(trace_endpos, src, '1 1 0', pen_dmg, pen_hg);
            }
            break;   // bullets stop on player (matches server)
        }
        else
        {
            CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage, 0);
            // Skip the green-dot debug marker when the trace stopped on a
            // dropped weapon's AABB.  The bullet didn't really hit the
            // mesh; flagging it visually would just add noise around
            // every gun on the ground.
            if (cvar("cl_debug_impacts")
                && !(trace_ent && trace_ent.classname == "csqc_dropped_weapon"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        }

        if (pen_remaining <= 0) break;

        entry_pos = trace_endpos;
        nudge_pos = entry_pos + dir * pen_remaining;
        CSQC_WeaponTraceLine(nudge_pos, entry_pos, MOVE_NORMAL, self);
        // CSQC traceline can't see phys props (server-replicated, .solid=0
        // on the client side).  Reuse the cylinder hit-test here so the
        // back-trace lands on the prop's back face — lets penetration
        // continue past a barrel/can with the correct wall_thick chord.
        CSQC_PhysProp_OverrideBackTrace(nudge_pos, entry_pos);
        CSQC_DroppedWeapon_OverrideTrace(nudge_pos, entry_pos);
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
            CSQC_BulletImpact(exit_pos, exit_normal, close_dmg, 1);   // is_exit=1 -> exit dust smoke
        if (cvar("cl_debug_impacts")
            && !(trace_ent && trace_ent.classname == "csqc_dropped_weapon"))
            CSQC_AddDebugImpact(exit_pos, src, '0 1 0', 0, 0);

        src = exit_pos + dir * 1;
        pen_count++;
        CSQC_WeaponTraceLine(src, end, MOVE_NORMAL, self);
        // Cylinder check on the post-pen forward trace too — without it,
        // a bullet that pierces a wall and then hits a barrel beyond
        // would dead-end on the wall behind the barrel and decal there.
        CSQC_PhysProp_OverrideTrace(src, end);
        CSQC_DroppedWeapon_OverrideTrace(src, end);
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
     float close_dmg, float min_dmg, float falloff_range,
     optional float kick_pitch, optional float kick_variance,
     optional float kick_strength) CSQC_PredictedShotgunImpact =
{
    vector src, dir, end;
    vector fwd, rt, up;
    float sx, sy, i;

    // Per-shot reset — shotgun pellets are one shot.  See comment in
    // CSQC_PredictedImpact.
#ifdef CSQC
    CSQC_BulletHoles_ResetShot();
    CSQC_Impact_ResetShot();
#endif

    CSQC_MuzzleFlash();

    // sv_gunkick — one impulse per trigger pull (not per pellet),
    // mirroring the server's W_*FirePellets path. Bias input_angles
    // before makevectors so every predicted pellet uses the kicked
    // aim — same as the penetrating-hitscan equivalent.
    SH_ApplyViewKick(kick_pitch, kick_variance, kick_strength);

    vector saved_input = input_angles;
    input_angles_x += self.view_kick_pitch;
    input_angles_y += self.view_kick_yaw;
    makevectors(input_angles);
    input_angles = saved_input;
    fwd = v_forward;
    rt  = v_right;
    up  = v_up;
    src = self.origin + self.view_ofs;

#ifdef CSQC
    // Bypass cl_bulletholes_per_shot for the pellet loop — the user-
    // intuitive "shot" here is the trigger pull, not the individual
    // pellet trace.  Without this gate a per_shot_cap of 1 leaves only
    // the first pellet's decal and the rest of the spray invisible.
    // Also reset the ric-played latch so the FIRST pellet of this
    // blast plays its ricochet, then the rest stay silent.
    bh_shotgun_blast = 1;
    bh_shotgun_ric_played = 0;
#endif

    for (i = 0; i < pellets; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * spread_val;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * spread_val;
        dir = normalize(fwd + rt * sx + up * sy);
        end = src + dir * 8192;

        // Per-pellet expand/restore.  Slightly redundant inside the
        // loop (the player bboxes don't change between pellets), but
        // keeps the bookend pattern consistent with the other CSQC
        // hitscan paths and avoids leaving the world in expanded
        // state if a future early-return slips in.
        W_PlayersExpandHitboxes();
        CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
        W_PlayersRestoreHitboxes();
        CSQC_PhysProp_OverrideTrace(src, end);
        CSQC_DroppedWeapon_OverrideTrace(src, end);

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
                // Patch 36: classify NOW (fresh globals) — FX below clobber trace_bone_id/surface_id.
                float hit_hg  = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
                float hit_bid = trace_bone_id;
                CSQC_TryPlayPredictedHitmarker();
                // Per-pellet flesh splash (shotgun can spray multiple).
                CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
                CSQC_SendHitclaim(trace_ent, damage, hit_bid, hit_hg);
            }
            else
            {
                CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage, 0);
            }
            if (cvar("cl_debug_impacts")
                && !(trace_ent && trace_ent.classname == "csqc_dropped_weapon"))
                CSQC_AddDebugImpact(trace_endpos, src, '0 1 0', 0, 0);
        }

        // Tracer per pellet — common shotgun look has one streak per
        // pellet rather than a single ribbon, since each pellet
        // travels its own path through the spread.  Suppressed during
        // reconcile-replay so each pellet only emits one ribbon.
        if (!pm_suppress_sounds)
            CSQC_SpawnTracer(src, (trace_fraction < 1.0) ? trace_endpos : end);
    }

#ifdef CSQC
    bh_shotgun_blast = 0;
#endif
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

    // sv_hitbox_expand around the melee MOVE_HITMODEL trace too —
    // knife slashes against a player whose arm is mid-swing past the
    // movement hull were missing for the same bbox-cull reason.
    W_PlayersExpandHitboxes();
    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();

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

        // Visual impact effect — branch on hit type the same way
        // sh_wpn_melee.qc / sh_wpn_katana.qc do for their direct
        // CSQC_PredictMeleeStrike paths:
        //   player hit → flesh particle burst (CSQC_BulletImpactSilent
        //                routes via Impact_SpawnParticles, which already
        //                picks the flesh-lethal variant for players)
        //   wall hit   → smoke puff only, no sparks / chips, no decal.
        //                Impact_SpawnSmokeOnly is NOT quality-gated, so
        //                the melee smoke shows even when cl_impact_quality 0
        //                turns the bullet-impact particles off entirely.
        if (is_player_hit)
        {
            CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
        }
        else
        {
            vector ip_pos = trace_endpos + trace_plane_normal * Impact_ParticleOffset();
            Impact_SpawnSmokeOnly(ip_pos, trace_plane_normal);
        }
        if (cvar("cl_debug_impacts")
            && !(trace_ent && trace_ent.classname == "csqc_dropped_weapon"))
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

float csqc_fire_effect_restore_suppress;

float() CSQC_BeginFireActionEffects =
{
    // High-water-mark dedup on wep_action_id.  See the long comment on
    // .csqc_fire_effect_action_id in shared/sh_customdefs.qc for why
    // action_id is the right key (handles multi-fire-within-one-cmd
    // at high render rates) and why we use strict `>` comparison
    // (handles snapshot rewind without re-pinning).
    //
    // Self-heal for live ticks only.  If something rewound action_id
    // below the mark without going through the dedicated reset site
    // (the rewind-detector in cl_player.qc CSQC_Ent_Update), drop the
    // mark just below the new action_id so the next fire can proceed.
    // Examples that hit this path: a live `sv_mintic` change that
    // briefly re-seeds server-confirmed state, an out-of-band weapon
    // reset, anything else that leaves predicted_player.wep_action_id
    // stale-low against the mark.
    //
    // Reconcile replay must NOT take this branch — during replay the
    // mark legitimately exceeds the current action_id while replay
    // re-walks buffered commands oldest→newest, and self-healing
    // would re-emit effects for already-emitted shots.  Gated on
    // pm_suppress_sounds (TRUE during replay, FALSE during live —
    // checked at function entry before BeginFireActionEffects itself
    // temporarily unsuppresses for the effect block).
    if (!pm_suppress_sounds
        && self.wep_action_id < self.csqc_fire_effect_action_id)
        self.csqc_fire_effect_action_id = self.wep_action_id - 1;

    if (self.wep_action_id <= self.csqc_fire_effect_action_id)
    {
        // Verification diagnostic — set cl_debug_hitclaim 1 in console
        // and a sustained burst should produce ZERO of these lines if
        // the latch is working correctly.  Remove after confirming.
        if (cvar("cl_debug_hitclaim"))
            print(sprintf("[fire-gate-skip] action_id=%g mark=%g cltime=%g pm_suppress=%g\n",
                  self.wep_action_id, self.csqc_fire_effect_action_id,
                  cltime, pm_suppress_sounds));
        return FALSE;
    }
    self.csqc_fire_effect_action_id = self.wep_action_id;
    csqc_weapon_pending_ack_sequence
        = max(csqc_weapon_pending_ack_sequence, csqc_pred_sequence);

    // Reconcile replay normally runs with pm_suppress_sounds=TRUE so
    // old commands don't duplicate one-shot effects.  If replay is
    // the FIRST place we discover this action_id (i.e. it climbs PAST
    // the high-water mark during a replay tick — the original live
    // run hadn't seen it yet, e.g. freshly buffered cmds after a
    // snapshot reset), temporarily unsuppress so the replay-time
    // trace can spawn visuals and send the trust-client hit/break
    // claim exactly once.
    csqc_fire_effect_restore_suppress = pm_suppress_sounds;
    pm_suppress_sounds = FALSE;
    return TRUE;
};

void() CSQC_EndFireActionEffects =
{
    pm_suppress_sounds = csqc_fire_effect_restore_suppress;
};
#endif
