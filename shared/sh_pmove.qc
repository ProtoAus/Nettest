/*
==============================================================================
sh_pmove.qc  –  Shared player-movement code (SSQC + CSQC)

Port of EzQuake's pmove.c to FTE QuakeC.
Compiled into both server progs and client progs so that client-side
prediction exactly matches server physics.

Hull: mins = '-16 -16 0'  maxs = '16 16 56'  (origin at feet, GoldSrc style)
Eye : view_ofs.z = 48
==============================================================================
*/

#pragma warning disable Q302   // suppress uninitialised-variable warnings

// ============================================================================
//  Hull / physics constants
// ============================================================================

vector PM_MINS;             // standing hull bottom       — set by PM_ReadMovevars
vector PM_MAXS;             // standing hull top          — set by PM_ReadMovevars
vector PM_DUCK_MINS;        // duck hull bottom           — set by PM_ReadMovevars
vector PM_DUCK_MAXS;        // duck hull top              — set by PM_ReadMovevars
vector PM_VIEW_OFS;         // standing eye offset        — set by PM_ReadMovevars
vector PM_DUCK_VIEW_OFS;    // ducked eye offset          — set by PM_ReadMovevars

// Vertical shift applied to all hull/view constants when the player model's
// natural pivot is not at the feet. Set per-spawn from the loaded model's
// .mins_z (in PlayerSpawn) so GoldSrc-style player models — whose origins
// commonly sit at the body's center — render at the correct floor height
// without their feet sinking into the geometry. PM_ReadMovevars folds this
// into PM_MINS/PM_MAXS/PM_VIEW_OFS so every collision and view computation
// already accounts for it.
float  pm_player_z_offset;

float  PM_STEPSIZE         = 18;
float  PM_FLYFRICTION      = 4;
float  PM_STOP_EPSILON     = 0.1;
float  PM_MIN_STEP_NORMAL  = 0.7;   // floor normal.z must be >= this
float  PM_MAX_CLIP_PLANES  = 8;   // raised from 5 to match ramp-fix bump count
float  PM_MAX_JUMPFIX_DP   = -0.1;  // ramp-fix dot-product threshold
float  PM_BTN_JUMP         = 2;     // bit in input_buttons
float  PM_BTN_DUCK         = 32;    // +button6 via DP_INPUTBUTTONS
float  PM_BTN_SPRINT       = 8;     // +button4  — sv_shiftspeed multiplier: >1 sprint, <1 walk
float  PM_BTN_USE          = 128;   // +button8 / +use     — high friction
float  PM_BTN_FIRE         = 1;     // +attack — bit 0 of input_buttons
// Grapple held-bit — when set, the player is holding the +grapple bind
// (a.k.a. +button9, bit 256 in DP_INPUTBUTTONS).  Rising edge engages
// the hook (sv_grapple.qc), falling edge releases it.  Coexists with
// the legacy `impulse 9` toggle for users who bound that; the two
// systems share the same .grapple_hook / .grapple_rope_active state.
float  PM_BTN_GRAPPLE      = 256;   // +button9 / +grapple — press-and-hold

// Forward decl — sh_weapon_logic.qc is included AFTER sh_pmove.qc on
// the CSQC side (cl_progs.src), so the per-tick gunkick decay call
// inside PM_PlayerMove needs an explicit forward declaration here.
// SSQC progs.src has weapon_logic before pmove so the decl is
// redundant but harmless there.
void(float dt) SH_TickViewKickDecay;
float  PM_DUCK_TIME        = 0.4;
float  PM_DUCKING_MULTIPLIER = 0.333;
float  PM_FIXEDSTEP_EPSILON = 0.000001;

// ============================================================================
//  Blocked flags  (returned by slide / step functions)
// ============================================================================

float  PM_BLOCKED_FLOOR    = 1;
float  PM_BLOCKED_STEP     = 2;
float  PM_BLOCKED_OTHER    = 4;

// ============================================================================
//  Movement types  (stored in self.pm_movetype)
// ============================================================================

float  PM_MOVETYPE_NORMAL    = 0;
float  PM_MOVETYPE_DEAD      = 1;
float  PM_MOVETYPE_FLY       = 2;
float  PM_MOVETYPE_SPECTATOR = 3;
float  PM_MOVETYPE_NONE      = 4;
float  PM_MOVETYPE_NOCLIP    = 5;

// ============================================================================
//  Custom entity fields
// ============================================================================

.float pm_movetype;       // PM_MOVETYPE_*
.float pm_waterjumptime;  // seconds remaining in water-jump launch
.float pm_jump_held;      // true while jump button is held (prevent pogo)
.float pm_jump_msec;      // msec accumulator for jump timer (0 = expired)
.float pm_jump_strict_block;  // sv_jumpstyle 0 latch: TRUE between a successful jump and an on-ground release
.float pm_in_duck;        // true while transitioning into a crouch
.float pm_duck_msec;      // GoldSrc-style duck transition timer
.float pm_oldbuttons;     // previous input_buttons state for edge detection
.float pm_timecarry;      // leftover command time for fixed-step simulation
.entity pm_prediction_proxy; // owner-only SSQC->CSQC authoritative snapshot proxy

// Duck-land slide state.  Shared field: CSQC reads slide_friction_active
// during prediction so the friction reduction is mirrored locally;
// SSQC drives it authoritatively.  The slide sound is fire-and-forget
// — SSQC just picks a random slide1-5.wav at engage on CHAN_BODY and
// the engine handles playback length — so there's no phase state.
.float slide_friction_active;
.float slide_was_onground;   // tick-local edge tracker for landing detect

// Grappling hook (sv_grappling) rope-render state.  Synced via the
// prediction proxy so CSQC's cl_rope.qc can draw a rope from the local
// player to the anchor without depending on standard server-entity
// broadcast (which doesn't reliably reach CSQC for ad-hoc projectile
// entities — see notes in sv_grapple.qc).  Owner-only by construction:
// the proxy lives on the local predicted player.  Server-only state
// (.entity grapple_hook etc.) stays in sv_customdefs.qc.
.float  grapple_rope_active;
.vector grapple_anchor;
// True only while the hook is anchored AND the player is being
// actively reeled in (post-touch).  Distinct from grapple_rope_active
// which is also set during the hook's flight phase.  Replicated via
// the prediction proxy so CSQC's PM_CategorizePosition can gate the
// ground-snap suppress on actual pulling rather than rope-existence.
.float  grapple_attached;
// PM_BTN_GRAPPLE edge-detection latch.  Stored on the player ent so
// both SSQC (sv_grapple.qc W_GrappleHeldTick) and CSQC (rope-flag
// prediction mirror in cl_weapons.qc CSQC_PredictGrappleHeldEdge)
// read/write the same field — the field's value at the end of one
// tick is the "was held" reference for the next tick's edge check.
// Distinct from .grapple_hook so a hook that auto-released (timeout
// or arrived-at-anchor) while the button is still held doesn't
// re-engage every tick — held_last latches the button-state itself,
// not the rope state.
.float  pm_grapple_held_last;

// sv_jumplag — absolute world-time when the next jump becomes legal.
// Stamped to (time + cvar("sv_jumplag")) at every landing edge.  Stored
// as a timestamp rather than a remaining-duration so CSQC and SSQC
// can't accumulate per-tick decay drift; both sides gate against the
// same `time < self.pm_jump_lag_end` comparison and the wire format
// converts to relative-remaining at send time (mirroring
// attack_finished) so the value survives across-clock transmission.
.float pm_jump_lag_end;

// Ground-snap suppress window — absolute world-time until which
// PM_CategorizePosition will refuse to grab the ground.  Stamped
// inside PM_CheckJump's accepted-jump block to give the impulse a
// few ticks of "guaranteed airborne" so the snap-to-ground floor
// (pm_velocity_z <= 180 → onground) can't yank an underpowered or
// low-impulse jump back to the floor before it can climb.
// Also force-suppressed while grapple_rope_active is set so a
// player being yanked airborne by the grapple isn't fighting the
// snap on every tick.  See PM_CategorizePosition for the read site.
.float pm_jump_groundstick_off_until;

#ifdef CSQC
// Forward decl — pm_suppress_sounds is defined further down at line
// ~4044 inside its own #ifdef block, but PM_CheckJump (~1610) needs
// it earlier for the sv_codstamina jump-cost replay gate.
float pm_suppress_sounds;
#endif

// ----------------------------------------------------------------
//  Sprint-fire gate
//  Returns 1 when the player is currently in a sprinting stance AND
//  sv_sprintdisableshooting is on — used by every fire-entry function
//  (SH_StandardTryFire, the three grenade TryPinPull / TryReady
//  entries) so the block applies uniformly across hitscan, projectile
//  and grenade weapons without each weapon needing to know.
//
//  Conditions mirror the sprint multiplier in PM_PlayerMoveStep and
//  the cl_viewfx sprint envelope, so visual sprint state, the speed
//  boost, and the fire block all engage together.  cvar() reads keep
//  this self-contained — no dependency on mv_shiftspeed being live
//  (it's only populated inside the pmove tick).
// ----------------------------------------------------------------
float() Weapon_SprintBlocksFire =
{
    if (!cvar("sv_sprintdisableshooting"))
        return 0;
    if (!(input_buttons & PM_BTN_SPRINT))
        return 0;
    if (cvar("sv_shiftspeed") <= 1.001)
        return 0;
    if (self.flags & FL_DUCKING)
        return 0;
    if (input_movevalues_x <= 0)
        return 0;
    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
        return 0;
    return 1;
};

// ----------------------------------------------------------------
//  Lower-pose fire gate
//  Returns 1 when the player is doing something that visually drops
//  the viewmodel off-screen and should also block the trigger:
//    - grapple_rope_active: hook is in flight or attached and pulling
//    - sv_codladders + pm_on_ladder_cached: ladder climb, server gate
//  Mirrors Weapon_SprintBlocksFire's shape so SH_StandardTryFire and
//  the three grenade TryPinPull entries share the same one-line
//  insertion.  Both grapple_rope_active and pm_on_ladder_cached live
//  on self so CSQC and SSQC see the same value — CSQC reads them out
//  of predicted_player via the prediction-proxy sync + PM_PlayerMoveStep
//  latch; SSQC reads them off the player entity directly.  cvar()
//  for sv_codladders works on SSQC; CSQC uses PM_ReadMovevar so it
//  picks up the serverinfo value pushed from SV_UpdateMovementServerInfo.
// ----------------------------------------------------------------
float() Weapon_LowerBlocksFire =
{
    // Noclip bypass — mirrors Weapon_SprintBlocksFire's MOVETYPE_NOCLIP
    // escape so admin debug workflows keep working.  Without this, an
    // admin who fired a grapple before going noclip would have firing
    // disabled until manually releasing the grapple (because
    // W_GrappleImpulse has no noclip check either).
    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
        return 0;
    if (self.grapple_rope_active)
        return 1;
    // HL2 carry — both hands on the prop, weapon lowered + firing blocked
    // (+attack is repurposed as the throw in Carry_Tick).
    if (self.pm_carrying)
        return 1;
    // (Driving a func_vehicle does NOT block fire — drive-by shooting is allowed.)
#ifdef CSQC
    if (self.pm_on_ladder_cached
        && PM_ReadMovevar("sv_codladders", 0))
        return 1;
#else
    if (self.pm_on_ladder_cached
        && cvar("sv_codladders"))
        return 1;
#endif
    return 0;
};

// Ammo-changed bitmask stored on the prediction proxy.  v18 uses mb0/mb1
// for canonical primary/secondary slot ammo plus utility counts; the
// remaining bytes are kept as spare scratch fields for future expansion.
.float pm_ammo_mb0;
.float pm_ammo_mb1;
.float pm_ammo_mb2;
.float pm_ammo_mb3;
.float pm_ammo_mb4;
.float pm_ammo_mb5;
.float pm_ammo_mb6;

// ============================================================================
//  Per-move working globals  (loaded from self at the start of PM_PlayerMove)
// ============================================================================

vector pm_origin;
vector pm_velocity;
float  pm_onground;
float  pm_waterlevel;     // 0 = dry, 1 = feet, 2 = waist, 3 = eyes
float  pm_watertype;      // CONTENT_* of deepest touched water
vector pm_groundnormal;
float  pm_frametime;
vector pm_forward;
vector pm_right;
float  pm_on_ladder;      // TRUE if player overlaps a ladder trigger this step
vector pm_ladder_normal;  // outward-facing normal of the active ladder surface

// ============================================================================
//  Movevars  (populated from cvars each call via PM_ReadMovevars)
// ============================================================================

float  mv_gravity;
float  mv_maxspeed;
float  mv_shiftspeed;     // multiplier on input_movevalues + mv_maxspeed while PM_BTN_SPRINT held. >1 sprint, <1 walk, 1 = no-op, 0 = disabled.
float  mv_stopspeed;
float  mv_friction;
float  mv_waterfriction;
float  mv_accelerate;
float  mv_airaccelerate;    // separate air-strafe accel (GoldSrc-style)
float  mv_wateraccelerate;
float  mv_entgravity;
float  mv_spectatormaxspeed;
float  mv_stamina;              // 1 = CS 1.6 landing-fatigue enabled, 0 = disabled
float  mv_autohop;              // 1 = jump re-fires every landing while held, 0 = require release
float  mv_jumpstyle;            // 0 = GoldSrc strict (require on-ground release between jumps), 1 = Source lenient

void() PM_CategorizePosition;
void() PM_PlayerMove;
void() PM_PlayerMoveStep;
void() PM_CheckLadder;
void() PM_InheritRotatorTangent;
void(float snd_idx, float vol) PM_EmitStepSound;
// Forward decl — PM_Friction and the stamina-slide-bypass block call
// this before its definition further down the file (CSQC-side reads
// serverinfo-replicated values, SSQC-side falls through to cvar()).
float(string name, float fallback) PM_ReadMovevar;
// Forward decl — both the landing-edge handler and the crouch-press
// handler in PM_PlayerMoveStep call this; defined just before
// PM_PlayerMoveStep so it sees pm_* working globals.
float() PM_TryEngageSlide;

// Footstep sound catalogue — a flat byte enum so CSQC_EVENT_FOOTSTEP_SOUND
// can carry a 1-byte index instead of the full ~24-byte sound path.
// Layout: step1..step4, waterstep1..waterstep10, ladder1..ladder4, metal_box_footstep1..4.
// Keep FS_SoundName() below in lock-step with this layout.
const float FS_SOUND_STEP_BASE    = 0;
const float FS_SOUND_STEP_COUNT   = 4;
const float FS_SOUND_WATER_BASE   = 4;
const float FS_SOUND_WATER_COUNT  = 10;
const float FS_SOUND_LADDER_BASE  = 14;
const float FS_SOUND_LADDER_COUNT = 4;
const float FS_SOUND_METAL_BASE   = 18;   // walking on the phys_files cabinet
const float FS_SOUND_METAL_COUNT  = 4;
const float FS_SOUND_COUNT        = 22;

string(float idx) FS_SoundName =
{
    if (idx >= FS_SOUND_STEP_BASE && idx < FS_SOUND_STEP_BASE + FS_SOUND_STEP_COUNT)
        return strcat("sounds/player/step", itos(idx - FS_SOUND_STEP_BASE + 1), ".wav");
    if (idx >= FS_SOUND_WATER_BASE && idx < FS_SOUND_WATER_BASE + FS_SOUND_WATER_COUNT)
        return strcat("sounds/player/waterstep", itos(idx - FS_SOUND_WATER_BASE + 1), ".wav");
    if (idx >= FS_SOUND_LADDER_BASE && idx < FS_SOUND_LADDER_BASE + FS_SOUND_LADDER_COUNT)
        return strcat("sounds/player/ladder", itos(idx - FS_SOUND_LADDER_BASE + 1), ".wav");
    if (idx >= FS_SOUND_METAL_BASE && idx < FS_SOUND_METAL_BASE + FS_SOUND_METAL_COUNT)
        return strcat("sounds/impacts/metal_box_footstep", itos(idx - FS_SOUND_METAL_BASE + 1), ".wav");
    return "sounds/player/step1.wav";   // safe fallback on out-of-range idx
};

// ============================================================================
//  8.  PM_Trace  –  tracebox wrapper using the shared hull
// ============================================================================

vector PM_CurrentMaxs()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCK_MAXS;

    return PM_MAXS;
}

vector PM_CurrentMins()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCK_MINS;

    return PM_MINS;
}

// Keep the player entity at its true movement hull.  Expanded hit volume
// lives on a separate hit-proxy entity (see Player_HitProxy_Ensure in
// sv_player.qc) so weapon traces can reach outstretched limbs without
// inflating player-vs-player collision.
void(entity e, vector mn, vector mx) SetHitboxSize =
{
    setsize(e, mn, mx);
};

void PM_TraceHull(vector start, vector mins, vector maxs, vector end)
{
    tracebox(start, mins, maxs, end, MOVE_NORMAL, self);
}

void PM_Trace(vector start, vector end)
{
    PM_TraceHull(start, PM_CurrentMins(), PM_CurrentMaxs(), end);
}

// ============================================================================
//  Player-vs-player wall fix
//
//  Bbox-on-bbox slides snap their contact normal to the closest cardinal
//  axis (±X or ±Y), which makes brushing past another player feel
//  rubbery — tiny lateral wobbles flip the normal and the slide stutters.
//
//  When the slide trace hits a player AND the contact is mostly horizontal
//  (i.e. we hit their side, not their head/feet), recompute the normal as
//  the horizontal radial from their origin to ours. That gives the smooth
//  "cylinder" feel: walking into someone slides cleanly around them, like
//  brushing past a pillar. Vertical contacts (|normal.z| >= 0.7) are left
//  alone so jumping ON a player still triggers ground detection — you can
//  stand on their head as before.
//
//  Caller passes the trace_plane_normal AS-IS for non-player or vertical
//  contacts, REPLACED for player-side hits.
// ============================================================================
// An entity pmove should treat as a living-player wall.
// Accepts both the engine-replicated player ("player") and the CSQC
// visual proxy ("player_visual_proxy"). Dead bodies excluded — they must
// be transparent to live players' traces regardless of whether the next
// solid=SOLID_NOT snapshot has arrived yet (closes the one-snapshot gap
// between server-side death and client-side proxy update).
float PM_IsLivePlayerCollider(entity e)
{
    if (!e) return FALSE;
    if (e.classname != "player" && e.classname != "player_visual_proxy")
        return FALSE;
#ifdef SSQC
    if (e.is_dead) return FALSE;
#endif
#ifdef CSQC
    if (e.vis_is_dead) return FALSE;
#endif
    return TRUE;
}

// Auto-disentangle: at the end of pmove, if our bbox is embedded inside
// another live player (telefrag-grade overlap, e.g. spawning into a body
// or a server/client reconciliation snapping positions into each other),
// pop out along the axis with the smallest penetration. Position-only —
// no velocity impulse, so there's no "push" feel. Pure AABB response,
// matches BSP-wall slide behavior exactly.
// noblock gate, set once per cmd in PM_PlayerMove (SSQC cvar / CSQC serverkey).
// Declared file-scope HERE — ahead of its first users (PM_DisentangleFromPlayer
// below + PM_SoftDepenetrate) — because fteqcc resolves globals top-down; it was
// declared ~4750 lines lower, which fteqcc rejects as a forward reference.
float pm_noblock_active;

void PM_DisentangleFromPlayer()
{
    // noblock: skip the player pop-out entirely. The stash should already
    // have desolidified other players (so the tracebox below wouldn't hit
    // them), but this closes any stash-coverage gap — a proxy that hadn't
    // materialised at stash time, or one kept solid by the pre-death-snapshot
    // robustness in PM_IsLivePlayerCollider.
    if (pm_noblock_active) return;
    tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(), pm_origin, MOVE_NORMAL, self);
    if (!trace_startsolid) return;
    if (!PM_IsLivePlayerCollider(trace_ent)) return;

    // Compute the AABB overlap on each axis.
    vector my_mins = pm_origin + PM_CurrentMins();
    vector my_maxs = pm_origin + PM_CurrentMaxs();
    vector hi_mins = trace_ent.absmin;
    vector hi_maxs = trace_ent.absmax;

    float ox = min(my_maxs_x, hi_maxs_x) - max(my_mins_x, hi_mins_x);
    float oy = min(my_maxs_y, hi_maxs_y) - max(my_mins_y, hi_mins_y);
    float oz = min(my_maxs_z, hi_maxs_z) - max(my_mins_z, hi_mins_z);

    // Guard against degenerate overlap reads (shouldn't happen given
    // startsolid was true, but cheap to clamp).
    if (ox < 0) ox = 0;
    if (oy < 0) oy = 0;
    if (oz < 0) oz = 0;

    // "Standing on top" early-out: if my AABB bottom (feet) is at or
    // above the other player's vertical center (their hip), the contact
    // is unambiguously vertical — push Z+ to land on their head/
    // shoulders cleanly, regardless of which axis has the smallest
    // overlap.  Without this, near-edge cases (small ox/oy plus tiny
    // oz) eject horizontally — the "stuck floating on horizontal edge"
    // symptom from playtest.  Walking-into-from-front (feet at floor =
    // same Z as theirs) doesn't trigger because my_bottom < their_center
    // there.
    float my_bottom    = my_mins_z;
    float their_center = (hi_mins_z + hi_maxs_z) * 0.5;
    if (my_bottom >= their_center)
    {
        pm_origin_z += oz + 1;
        return;
    }

    // Nudge 1 unit past the overlap so the next tracebox clears.
    //
    // NEVER push DOWNWARD here.  The "above their center" branch above
    // already handled standing-on-top with Z+.  Any time we reach this
    // block we're at-or-below their center, so a Z- push would shove
    // us further into them or, worse, into the floor.  Concrete
    // playtest case: I'm standing on someone's head, they crouch.
    // Their pmove disentangles vs. me with smallest-axis = oz → tries
    // to push them DOWN by `oz + 1` → they sink visibly into the
    // floor before re-entering pmove next tick.
    //
    // If Z would be the smallest axis but its direction would be
    // downward, fall back to the smaller of the two horizontal axes.
    // We always have a viable horizontal push when overlap exists
    // (ox or oy must be > 0 for the AABBs to actually intersect).
    vector push = '0 0 0';
    if (ox <= oy && ox <= oz)
        push_x = (pm_origin_x >= trace_ent.origin_x) ? (ox + 1) : -(ox + 1);
    else if (oy <= oz)
        push_y = (pm_origin_y >= trace_ent.origin_y) ? (oy + 1) : -(oy + 1);
    else if (pm_origin_z >= trace_ent.origin_z)
        push_z = oz + 1;                    // Z smallest, going UP — fine
    else if (ox <= oy)
        push_x = (pm_origin_x >= trace_ent.origin_x) ? (ox + 1) : -(ox + 1);
    else
        push_y = (pm_origin_y >= trace_ent.origin_y) ? (oy + 1) : -(oy + 1);

    pm_origin = pm_origin + push;
}

// ============================================================================
//  9.  PM_TestPosition  –  returns true if the position is not solid
// ============================================================================

float PM_TestPositionExt(vector pos, vector mins, vector maxs)
{
    tracebox(pos, mins, maxs, pos, MOVE_NOMONSTERS, self);
    return !trace_startsolid;
}

// MOVE_NORMAL variant — also tests against non-BSP solids: physics props (the
// filing cabinet), breakables, other players.  MOVE_NOMONSTERS (above) skips ALL
// non-BSP entities, so an un-duck headroom check using it can't see a phys prop
// overhead and lets the player stand up straight INTO it and get stuck.
float PM_TestPositionExtFull(vector pos, vector mins, vector maxs)
{
    tracebox(pos, mins, maxs, pos, MOVE_NORMAL, self);
    return !trace_startsolid && !trace_allsolid;
}

float PM_TestPosition(vector pos)
{
    return PM_TestPositionExt(pos, PM_CurrentMins(), PM_CurrentMaxs());
}

// Entity-aware variant: uses MOVE_NORMAL so other players / breakables count.
float PM_TestPositionFull(vector pos)
{
    tracebox(pos, PM_CurrentMins(), PM_CurrentMaxs(), pos, MOVE_NORMAL, self);
    return !trace_startsolid && !trace_allsolid;
}

float PM_MoveScale()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCKING_MULTIPLIER;

    return 1;
}

float PM_SplineFraction(float value, float scale)
{
    float value_squared;

    value = value * scale;
    value_squared = value * value;

    return 3 * value_squared - 2 * value_squared * value;
}

void PM_SyncHull()
{
#if defined(SSQC) || defined(CSQC)
    if (self.flags & FL_DUCKING)
        SetHitboxSize(self, PM_DUCK_MINS, PM_DUCK_MAXS);
    else
        SetHitboxSize(self, PM_MINS, PM_MAXS);
#endif
}

void PM_UnDuck()
{
    vector new_origin;

    new_origin = pm_origin;
    // Undo the ground duck origin shift: restore feet to world floor level.
    // In air there was no shift, so don't compensate.
    // Use the *difference* between standing and ducked floor positions, not
    // PM_DUCK_MINS_z alone — this works whether PM_MINS_z is 0 (legacy: feet
    // at origin) or negative (player model with body-center origin).
    if (pm_onground)
        new_origin_z += PM_DUCK_MINS_z - PM_MINS_z;

    // MOVE_NORMAL (Full) so a physics prop overhead — the filing cabinet — blocks
    // standing up instead of being ignored, which let the player un-duck up into it
    // and get stuck.  (Also blocks standing up directly under another player.)
    if (!PM_TestPositionExtFull(new_origin, PM_MINS, PM_MAXS))
        return;

    pm_origin = new_origin;
    self.flags &= ~FL_DUCKING;
    self.pm_in_duck = FALSE;
    self.pm_duck_msec = 0;
    self.view_ofs = PM_VIEW_OFS;

    PM_SyncHull();
    PM_CategorizePosition();
}

void PM_CheckDuck()
{
    float buttons_changed;
    float buttons_pressed;
    float duck_down;
    float duck_time;
    float duck_fraction;

    duck_down = input_buttons & PM_BTN_DUCK;
    buttons_changed = self.pm_oldbuttons ^ input_buttons;
    buttons_pressed = buttons_changed & input_buttons;

    if (duck_down)
        self.pm_oldbuttons |= PM_BTN_DUCK;
    else
        self.pm_oldbuttons &= ~PM_BTN_DUCK;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
    {
        if ((self.flags & FL_DUCKING) || self.pm_in_duck)
            PM_UnDuck();
        return;
    }

    // ---- sv_slidingcrouch: press-crouch-while-fast slide entry ----
    // Unified path that combines "crouch-press trigger" and the
    // instant-crouch-jump lift.  When sv_slidingcrouch is on AND the
    // player presses crouch from standing on flat ground AND their
    // horizontal speed is already at slide threshold, skip the smooth
    // pm_duck_msec transition: lift the origin so the new ducked
    // hull's bottom sits at standing-eye-level, set view_ofs to
    // PM_DUCK_VIEW_OFS (camera ends up at the same world Y so it does
    // not visually snap), and clear pm_onground so gravity engages.
    // The player falls a short distance and the existing landing-edge
    // handler in PM_PlayerMoveStep engages the slide when their feet
    // touch down.
    //
    // Below sv_sliding_start_speed — or under a ceiling that won't fit
    // the lifted hull — we fall through to the normal smooth duck
    // path, so this never punishes a regular slow crouch.
    // Punished: fall through to normal smooth duck, no slide entry.
    if ((buttons_pressed & PM_BTN_DUCK)
        && !(self.flags & FL_DUCKING)
        && pm_onground
        && self.pm_movetype != PM_MOVETYPE_NOCLIP
        && PM_ReadMovevar("sv_sliding", 0)
        && PM_ReadMovevar("sv_slidingcrouch", 0)
        && !(PM_ReadMovevar("sv_codstamina", 0) > 0 && self.codstamina_punished))
    {
        vector cj_hvel = pm_velocity;
        cj_hvel_z = 0;
        if (vlen(cj_hvel) >= PM_ReadMovevar("sv_sliding_start_speed", 100))
        {
            float lift = PM_VIEW_OFS_z - PM_DUCK_VIEW_OFS_z;
            vector lifted = pm_origin;
            lifted_z += lift;
            if (PM_TestPositionExt(lifted, PM_DUCK_MINS, PM_DUCK_MAXS))
            {
                pm_origin = lifted;
                self.flags |= FL_DUCKING;
                self.pm_in_duck = FALSE;
                self.pm_duck_msec = 0;
                self.view_ofs = PM_DUCK_VIEW_OFS;
                PM_SyncHull();
                pm_onground = FALSE;
                return;
            }
            // Low ceiling — fall through to smooth duck.
        }
        // Below sv_sliding_start_speed — fall through to smooth duck.
    }

    if (!duck_down && !self.pm_in_duck && !(self.flags & FL_DUCKING))
    {
        self.view_ofs = PM_VIEW_OFS;
        return;
    }

    if (duck_down)
    {
        if ((buttons_pressed & PM_BTN_DUCK) && !(self.flags & FL_DUCKING))
        {
            self.pm_duck_msec = 1000;
            self.pm_in_duck = TRUE;
        }

        if (self.pm_in_duck)
        {
            if (self.pm_duck_msec < 0)
                self.pm_duck_msec = 0;

            duck_time = max(0, 1 - self.pm_duck_msec / 1000);

            // Match GoldSrc: finish instantly once the duck timer crosses the
            // threshold or if the player is airborne mid-transition.
            if (self.pm_duck_msec / 1000 <= (1 - PM_DUCK_TIME) || !pm_onground)
            {
                self.flags |= FL_DUCKING;
                self.pm_in_duck = FALSE;
                self.view_ofs = PM_DUCK_VIEW_OFS;

                // On ground: shift origin down so feet stay planted at the same
                // world position (mirrors GoldSrc origin -= duck_mins - stand_mins).
                // In air: no shift — hull bottom rises, enabling crouch-jump.
                // Formula uses both PM_MINS_z and PM_DUCK_MINS_z so it works
                // regardless of whether origin is at feet (PM_MINS_z=0, legacy)
                // or body center (PM_MINS_z=-36, GoldSrc model offset).
                if (pm_onground)
                {
                    pm_origin_z += PM_MINS_z - PM_DUCK_MINS_z;
                    // Unstick if the shift pushed us into geometry
                    if (!PM_TestPosition(pm_origin))
                    {
                        local float nudge;
                        for (nudge = 0; nudge < 36; nudge = nudge + 1)
                        {
                            pm_origin_z = pm_origin_z + 1;
                            if (PM_TestPosition(pm_origin))
                                break;
                        }
                    }
                }

                PM_SyncHull();
                PM_CategorizePosition();
            }
            else
            {
                // Animate view toward the post-duck eye position, anticipating the
                // origin shift the transition will apply on completion. The
                // PM_MINS_z term keeps this consistent for both legacy (origin at
                // feet) and GoldSrc model (origin at body center) hull setups —
                // collapses back to the original (PM_DUCK_VIEW_OFS_z - PM_DUCK_MINS_z)
                // when PM_MINS_z is 0.
                duck_fraction = PM_SplineFraction(duck_time, 1 / PM_DUCK_TIME);
                self.view_ofs_z = PM_VIEW_OFS_z * (1 - duck_fraction)
                                + (PM_DUCK_VIEW_OFS_z + PM_MINS_z - PM_DUCK_MINS_z) * duck_fraction;
            }
        }
        else if (self.flags & FL_DUCKING)
        {
            self.view_ofs = PM_DUCK_VIEW_OFS;
        }

        return;
    }

    PM_UnDuck();
}

// ============================================================================
//  10.  PM_ClipVelocity  –  reflect / clip velocity off a plane
// ============================================================================

vector PM_ClipVelocity(vector in, vector normal, float overbounce)
{
    float  backoff;
    vector out;

    backoff = (in * normal) * overbounce;

    out_x = in_x - normal_x * backoff;
    out_y = in_y - normal_y * backoff;
    out_z = in_z - normal_z * backoff;

    // kill tiny residual components to avoid drift
    if (out_x > -PM_STOP_EPSILON && out_x < PM_STOP_EPSILON) out_x = 0;
    if (out_y > -PM_STOP_EPSILON && out_y < PM_STOP_EPSILON) out_y = 0;
    if (out_z > -PM_STOP_EPSILON && out_z < PM_STOP_EPSILON) out_z = 0;

    // Residual penetration fix (Momentum Mod): ensure clipped velocity
    // doesn't still move into the plane due to float precision.
    float adjust = out * normal;
    if (adjust < 0)
        out = out - (normal * adjust);

    return out;
}

// ============================================================================
//  11.  PM_SlideMove  –  multi-plane clipped slide with ramp-seam fix
//
//  Changes from vanilla pmove:
//    · bump count raised from 4 to pm_ramp_bumpcount (default 8)
//    · stuck_on_ramp: when zero progress is made against a surface while
//      airborne, find a valid escape plane and retrace from fixed_origin
//      nudged off the seam, instead of clipping to a degenerate normal
//    · primal_velocity reversal: don't zero velocity, just break — lets the
//      player keep momentum through ramp seams (ramp_slope_fix "OppositeDirection")
//    · allFraction == 0: same — don't zero velocity at the end
// ============================================================================

float PM_SlideMove()
{
    local vector planes[8];
    vector  primal_velocity;
    vector  original_velocity;
    vector  new_velocity;
    vector  dir;
    vector  fixed_origin;       // ramp fix: retrace start, offset off seam
    vector  valid_plane;        // ramp fix: escape surface normal
    float   time_left;
    float   blocked;
    float   num_planes;
    float   i, j;
    float   d;
    float   numbumps;
    float   stuck_on_ramp;
    float   has_valid_plane;
    float   all_fraction;

    numbumps = cvar("pm_ramp_bumpcount");
    if (numbumps < 4)
        numbumps = 8;

    primal_velocity   = pm_velocity;
    original_velocity = pm_velocity;
    blocked           = 0;
    num_planes        = 0;
    time_left         = pm_frametime;
    fixed_origin      = pm_origin;
    valid_plane       = '0 0 0';
    stuck_on_ramp     = FALSE;
    has_valid_plane   = FALSE;
    all_fraction      = 0;

    for (i = 0; i < numbumps; i++)
    {
        if (pm_velocity == '0 0 0')
            break;

        // --- Ramp-seam fix: escape when completely blocked while airborne ---
        if (stuck_on_ramp)
        {
            if (!has_valid_plane)
            {
                // Search stored planes for a usable escape normal
                local float k;
                for (k = num_planes - 1; k >= 0; k--)
                {
                    if (planes[k] != '0 0 0' && planes[k] != valid_plane)
                    {
                        valid_plane     = planes[k];
                        has_valid_plane = TRUE;
                        break;
                    }
                }
            }

            if (has_valid_plane)
            {
                // Clip velocity to the escape plane and nudge origin off seam
                pm_velocity       = PM_ClipVelocity(pm_velocity, valid_plane, 1);
                original_velocity = pm_velocity;
                fixed_origin      = fixed_origin + valid_plane * 0.2;
            }
            else
            {
                stuck_on_ramp = FALSE;
            }
        }

        // --- Trace forward ---
        if (stuck_on_ramp && has_valid_plane)
            PM_TraceHull(fixed_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                         fixed_origin + pm_velocity * time_left);
        else
            PM_Trace(pm_origin, pm_origin + pm_velocity * time_left);

        // Pure AABB slide: the raw trace_plane_normal from tracebox is
        // one of the six cardinal face normals of the other player's
        // bbox, so velocity-clipping below behaves exactly like sliding
        // against a BSP wall. No cylinder remapping.

        if (trace_startsolid || trace_allsolid)
        {
            // Embedded in another player (live OR dead): don't zero
            // velocity. Live → end-of-step disentangle nudges us out.
            // Dead → corpse should be transparent, so bailing without
            // zeroing velocity prevents the local stutter while the
            // server's solid=SOLID_NOT snapshot reaches the proxy.
            if (trace_ent
                && (trace_ent.classname == "player"
                    || trace_ent.classname == "player_visual_proxy"))
                break;

            pm_velocity = '0 0 0';
            return PM_BLOCKED_FLOOR | PM_BLOCKED_STEP | PM_BLOCKED_OTHER;
        }

        if (trace_fraction > 0)
        {
            pm_origin         = trace_endpos;
            fixed_origin      = trace_endpos;
            original_velocity = pm_velocity;
            num_planes        = 0;
            stuck_on_ramp     = FALSE;
            has_valid_plane   = FALSE;
            all_fraction     += trace_fraction;
        }

        if (trace_fraction == 1)
        {
            // Stuck-on-arrival check (Momentum Mod): a swept trace can
            // report fraction==1 while the endpoint is embedded in terrain.
            // Re-test with an unswept box to catch this.
            if (i > 0)
            {
                PM_Trace(pm_origin, pm_origin);
                if (trace_startsolid || trace_fraction != 1)
                {
                    pm_velocity = '0 0 0';
                    break;
                }
            }
            break;   // moved the whole way, no collision
        }

        // Ramp-seam fix: zero progress against a surface while airborne —
        // the plane normal may be degenerate.  Store it and try the retrace.
        if (trace_fraction == 0 && !pm_onground && i > 0)
        {
            if (trace_plane_normal != '0 0 0')
            {
                valid_plane     = trace_plane_normal;
                has_valid_plane = TRUE;
            }
            stuck_on_ramp = TRUE;
        }

        // Classify the surface hit
        if (trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
            blocked |= PM_BLOCKED_FLOOR;
        else if (!trace_plane_normal_z)
            blocked |= PM_BLOCKED_STEP;
        else
            blocked |= PM_BLOCKED_OTHER;

        // Store the collision plane
        if (num_planes < PM_MAX_CLIP_PLANES)
        {
            planes[num_planes] = trace_plane_normal;
            num_planes++;
        }

        time_left -= time_left * trace_fraction;

        // First-impact airborne clip (Momentum Mod):
        // On the very first collision while airborne, do a plain slide clip
        // and skip the multi-plane resolution pass below.
        if (num_planes == 1 && !pm_onground)
        {
            pm_velocity = PM_ClipVelocity(original_velocity, planes[0], 1);
            original_velocity = pm_velocity;
            continue;
        }

        // Try each stored plane to find a compatible clip velocity
        for (j = 0; j < num_planes; j++)
        {
            new_velocity = PM_ClipVelocity(original_velocity, planes[j], 1);

            local float ok;
            ok = TRUE;
            local float kk;
            for (kk = 0; kk < num_planes; kk++)
            {
                if (kk == j)
                    continue;
                if ((new_velocity * planes[kk]) < 0)
                {
                    ok = FALSE;
                    break;
                }
            }

            if (ok)
            {
                pm_velocity = new_velocity;
                break;
            }
        }

        if (j == num_planes)
        {
            // all planes conflicted – try the crease direction
            if (num_planes != 2)
            {
                pm_velocity = '0 0 0';
                break;
            }
            dir = normalize(crossproduct(planes[0], planes[1]));
            d   = dir * pm_velocity;
            pm_velocity = dir * d;
        }

        // if velocity reversed against primal, just stop without zeroing —
        // keeping momentum avoids sticking in ramp seams (ramp_slope_fix patch)
        if ((pm_velocity * primal_velocity) <= 0)
            break;
    }

    // if we made no progress at all, preserve velocity (ramp_slope_fix patch)
    // — the original code zeroed it here, which caused sticking on seams

    // during a water-jump the horizontal speed is locked to primal
    if (self.pm_waterjumptime)
    {
        pm_velocity_x = primal_velocity_x;
        pm_velocity_y = primal_velocity_y;
        pm_velocity_z = pm_velocity_z;   // keep any vertical clip result
    }

    return blocked;
}

// ============================================================================
//  12.  PM_StepSlideMove  –  slide with optional step-up
//  Structure matches pmove.c exactly: run flat slide, SAVE that result,
//  then try the step path and compare the two saved positions.
// ============================================================================

float PM_StepSlideMove(float in_air)
{
    vector  original_origin;
    vector  original_velocity;
    vector  down_origin;     // flat-slide result (saved before step attempt)
    vector  down_velocity;
    vector  org;
    float   blocked;
    float   stepsize;
    float   dx, dy;
    float   down_dist_sq, up_dist_sq;

    original_origin   = pm_origin;
    original_velocity = pm_velocity;

    // --- 1. flat slide ---
    blocked = PM_SlideMove();

    if (!blocked)
        return blocked;   // moved freely, nothing to step over

    // --- 2. airborne guard: only step over actual walls with ground below ---
    if (in_air)
    {
        if (!(blocked & PM_BLOCKED_STEP))
            return blocked;

        org = (original_velocity_z < 0) ? pm_origin : original_origin;
        PM_Trace(org, org - '0 0 1' * PM_STEPSIZE);
        if (trace_fraction == 1 || trace_plane_normal_z < PM_MIN_STEP_NORMAL)
            return blocked;

        // Match pmove.c: shrink the upward retry by how far below us the
        // supporting floor actually is.
        stepsize = PM_STEPSIZE - (org_z - trace_endpos_z);
        if (stepsize < 4)
            return blocked;
    }
    else
    {
        stepsize = PM_STEPSIZE;
    }

    // --- 3. save the flat-slide result as the "down" path ---
    down_origin   = pm_origin;
    down_velocity = pm_velocity;

    // --- 4. reset and attempt the step-up path ---
    pm_origin   = original_origin;
    pm_velocity = original_velocity;

    // step up
    PM_Trace(pm_origin, pm_origin + '0 0 1' * stepsize);
    if (trace_startsolid && (blocked & PM_BLOCKED_STEP))
    {
        // Hull is flush with a wall face (NudgePosition grid-snapped us
        // onto the brush boundary).  Back off 0.125 units against our
        // movement direction and retry so the trace clears the seam.
        vector nudged = pm_origin - normalize(original_velocity) * 0.125;
        PM_Trace(nudged, nudged + '0 0 1' * stepsize);
    }
    if (!trace_startsolid && !trace_allsolid)
        pm_origin = trace_endpos;

    // in-air downward velocity zero (pmove.c does this before the elevated slide)
    if (in_air && original_velocity_z < 0)
        pm_velocity_z = 0;

    // slide at the elevated height
    PM_SlideMove();

    // Guard: if the elevated slide left us inside an entity (another player,
    // a breakable, etc.), discard the step path entirely.
    PM_TraceHull(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(), pm_origin);
    if (trace_startsolid)
    {
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }

    // step back down
    PM_Trace(pm_origin, pm_origin - '0 0 1' * stepsize);
    // Revert if step-down landed us inside a solid entity (e.g. another
    // player's hull).  Without this we'd stay 18u elevated and re-enter
    // the same state every frame.
    if (trace_startsolid || trace_allsolid)
    {
        pm_origin     = down_origin;
        pm_velocity   = down_velocity;
        pm_velocity_z = 0;
        return blocked;
    }
    if (trace_fraction != 1 && trace_plane_normal_z < PM_MIN_STEP_NORMAL)
    {
        // landed on a wall, not a floor – fall back to the flat path
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }
    if (!trace_startsolid && !trace_allsolid)
        pm_origin = trace_endpos;

    // reject if step landed us lower than we started (stepped into a dip)
    if (pm_origin_z < original_origin_z)
    {
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }

    // --- 5. compare horizontal coverage of flat vs step paths ---
    dx = down_origin_x - original_origin_x;
    dy = down_origin_y - original_origin_y;
    down_dist_sq = dx*dx + dy*dy;

    dx = pm_origin_x - original_origin_x;
    dy = pm_origin_y - original_origin_y;
    up_dist_sq = dx*dx + dy*dy;

    if (down_dist_sq > up_dist_sq)
    {
        // flat path covered strictly more ground – use it
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }

    // --- 6. step path was better: keep step position + step velocity,
    //        but borrow z-velocity from the flat slide (pmove.c convention) ---
    pm_velocity_z = down_velocity_z;

    // mid-air step penalty: lose a bit of horizontal speed proportional to
    // how high we stepped (pmove.c)
    if (!pm_onground && pm_waterlevel < 2 && (blocked & PM_BLOCKED_STEP))
    {
        float scale = 1 - 0.01 * (pm_origin_z - original_origin_z);
        pm_velocity_x *= scale;
        pm_velocity_y *= scale;
    }

    return blocked;
}

// ============================================================================
//  13.  PM_Friction
// ============================================================================

void PM_Friction()
{
    float speed, newspeed, control, drop, friction;
    vector vel2d;

    // water-jump in progress – don't interfere
    if (self.pm_waterjumptime)
        return;

    if (pm_waterlevel >= 2)
    {
        speed = vlen(pm_velocity);
        if (speed < 1)
        {
            pm_velocity = '0 0 0';
            return;
        }

        // water friction
        drop = 0;
        drop += speed * mv_waterfriction * pm_waterlevel * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
        return;
    }
    else if (self.pm_movetype == PM_MOVETYPE_FLY)
    {
        speed = vlen(pm_velocity);
        if (speed < 1)
        {
            pm_velocity = '0 0 0';
            return;
        }

        // fly friction
        drop = 0;
        drop += speed * PM_FLYFRICTION * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
        return;
    }
    else if (pm_onground)
    {
        // Ground friction is based on horizontal speed only. Slope-clipped
        // vertical velocity is not player input and should not add extra drag
        // while walking up clip ramps or other sloped floors.
        vel2d   = pm_velocity;
        vel2d_z = 0;
        speed = vlen(vel2d);
        if (speed < 1)
        {
            pm_velocity_x = 0;
            pm_velocity_y = 0;
            return;
        }

        friction = mv_friction;

        // Holding +use on the ground doubles friction so the player slows
        // down noticeably when leaning against a wall or object.
        if (input_buttons & PM_BTN_USE)
            friction = friction * 4;

        // Duck-land slide: drop friction sharply while the slide is
        // active.  Triggered / cleared in PM_PlayerMoveStep's landing
        // block.  Multiplier so the single sv_sliding_friction_mult cvar
        // does all the tuning; placed AFTER the +use boost so leaning on
        // a wall still bites harder than coasting in a slide.
        // PM_ReadMovevar for the same CSQC-side reason as the trigger.
        // Punished: skip the glide multiplier — full normal ground
        // friction so the latch clears naturally as hspeed bleeds off.
        if (self.slide_friction_active
            && !(PM_ReadMovevar("sv_codstamina", 0) > 0 && self.codstamina_punished))
            friction = friction * PM_ReadMovevar("sv_sliding_friction_mult", 0.1);

        drop = 0;
        control = max(speed, mv_stopspeed);
        drop += control * friction * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity_x *= newspeed;
        pm_velocity_y *= newspeed;
        return;
    }
    else
    {
        // airborne – no friction
        return;
    }
}

// ============================================================================
//  14.  PM_Accelerate
// ============================================================================

void PM_Accelerate(vector wishdir, float wishspeed, float accel)
{
    float currentspeed, addspeed, accelspeed;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
        return;
    if (self.pm_waterjumptime)
        return;

    currentspeed = pm_velocity * wishdir;
    addspeed     = wishspeed - currentspeed;

    if (addspeed <= 0)
        return;

    accelspeed = accel * pm_frametime * wishspeed;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    pm_velocity = pm_velocity + wishdir * accelspeed;
}

// ============================================================================
//  15.  PM_AirAccelerate
// ============================================================================

void PM_AirAccelerate(vector wishdir, float wishspeed, float accel)
{
    float currentspeed, addspeed, accelspeed, wishspeed2;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
        return;
    if (self.pm_waterjumptime)
        return;

    wishspeed2 = min(wishspeed, 30);   // clamp wish before dot

    currentspeed = pm_velocity * wishdir;
    addspeed     = wishspeed2 - currentspeed;

    if (addspeed <= 0)
        return;

    // note: uses original wishspeed (not clamped) for accelspeed magnitude
    accelspeed = accel * wishspeed * pm_frametime;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    pm_velocity = pm_velocity + wishdir * accelspeed;
}

// ============================================================================
//  16.  PM_WaterMove
// ============================================================================

float PM_WaterMove()
{
    vector wishvel;
    float  wishspeed;
    float  fmove, smove, upmove;
    float  scale;

    scale = PM_MoveScale();

    fmove = input_movevalues_x * scale;
    smove = input_movevalues_y * scale;
    upmove = input_movevalues_z * scale;

    wishvel = pm_forward * fmove + pm_right * smove;

    if (self.pm_movetype != PM_MOVETYPE_FLY && fmove == 0 && smove == 0 && upmove == 0)
    {
        if (!pm_onground)
            wishvel_z -= 60;   // sink slowly when stationary and airborne
    }
    else
        wishvel_z += upmove;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }
    wishspeed *= 0.7;

    PM_Accelerate(normalize(wishvel), wishspeed, mv_wateraccelerate);

    return PM_StepSlideMove(FALSE);
}

// ============================================================================
//  17.  PM_FlyMove
// ============================================================================

float PM_FlyMove()
{
    vector wishvel;
    float  wishspeed;
    float  scale;

    scale = PM_MoveScale();

    wishvel = pm_forward * (input_movevalues_x * scale)
            + pm_right   * (input_movevalues_y * scale)
            + v_up       * (input_movevalues_z * scale);

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }

    PM_Accelerate(normalize(wishvel), wishspeed, mv_accelerate);

    return PM_StepSlideMove(FALSE);
}

// Port of CGameMovement::StayOnGround (Source SDK / Momentum Mod).
// After horizontal movement, re-snap the player to walkable floor so they
// don't briefly leave ground when walking down a slope and don't slowly
// drift on a 45° slope when standing still.
//
// Algorithm: trace 2 units UP first (escapes minor floor penetration so
// the down trace starts from a guaranteed-clear position), then trace
// PM_STEPSIZE units DOWN. Snap to the hit position if walkable.
//
// Snap acceptance is intentionally LOOSER than CategorizePosition's: a
// hull trace whose first contact catches the edge of a 45° slope or an
// adjacent face can return normal_z slightly under 0.7. Refusing to snap
// in that case leaves the player floating fractionally above the slope,
// CategorizePosition flickers off-ground, gravity sneaks in for a tick,
// SlideMove projects velocity along the slope, and the player drifts
// downhill. Accepting any normal_z >= 0.5 (~60°) keeps them glued to
// surfaces they were already on without snapping onto walls.
void PM_StayOnGround()
{
    vector start;

    start = pm_origin + '0 0 2';

    // Up trace: find guaranteed safe space above. Hull-traced so it
    // handles ceilings — same as Source's TracePlayerBBox.
    PM_Trace(pm_origin, start);
    start = trace_endpos;

    // Down trace from the safe position.
    PM_Trace(start, pm_origin - '0 0 1' * PM_STEPSIZE);
    if (trace_fraction <= 0 || trace_fraction >= 1)
        return;
    if (trace_startsolid || trace_allsolid)
        return;
    if (trace_plane_normal_z < 0.5)
        return;

    pm_origin = trace_endpos;
}

void PM_FollowGroundPlane()
{
    // Feet-origin adaptation: keep the horizontal speed the player earned,
    // then solve the Z component needed to stay tangent to the current floor.
    // This prevents ramp collision from shaving X/Y speed while walking uphill.
    if (!pm_onground)
        return;
    if (pm_groundnormal_z < PM_MIN_STEP_NORMAL)
        return;
    if (pm_groundnormal_z <= PM_FIXEDSTEP_EPSILON)
        return;

    pm_velocity_z = -(
        pm_velocity_x * pm_groundnormal_x +
        pm_velocity_y * pm_groundnormal_y
    ) / pm_groundnormal_z;
}

// ============================================================================
//  18.  PM_AirMove
// ============================================================================

float PM_AirMove()
{
    vector wishvel, wishdir;
    vector fwd2d, right2d;
    vector walk_dest;
    float  wishspeed;
    float  fmove, smove;
    float  scale;

    scale = PM_MoveScale();
    fmove = input_movevalues_x * scale;
    smove = input_movevalues_y * scale;

    // flatten forward and right into the horizontal plane
    fwd2d   = pm_forward;
    fwd2d_z = 0;
    right2d   = pm_right;
    right2d_z = 0;

    if (fwd2d != '0 0 0')   fwd2d   = normalize(fwd2d);
    if (right2d != '0 0 0') right2d = normalize(right2d);

    wishvel   = fwd2d * fmove + right2d * smove;
    wishvel_z = 0;

    wishspeed = vlen(wishvel);

    // Diagonal-bug cap (grounded only): forward+strafe gives sqrt(2) ×
    // the single-axis wishspeed because both components add into vlen.
    // The mv_maxspeed cap below masks it for run speed (cl_forwardspeed
    // > mv_maxspeed makes the diagonal also clip to mv_maxspeed) but
    // not for ducking (scale shrinks fmove/smove well below mv_maxspeed,
    // so diagonal sneaks under the cap and ends up 1.41× faster).
    // Capping to the larger single-axis value normalises the speed.
    // Air movement is intentionally left alone — strafe-jumping needs
    // the uncapped wishspeed to drive PM_AirAccelerate.
    if (pm_onground)
    {
        float per_axis = max(fabs(fmove), fabs(smove));
        if (per_axis > 0 && wishspeed > per_axis)
        {
            wishvel   = wishvel * (per_axis / wishspeed);
            wishspeed = per_axis;
        }
    }

    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }
    wishdir = (wishspeed > 0) ? normalize(wishvel) : wishvel;

    if (pm_onground)
    {
        // Grounded movement in pmove.c zeroes z before the step-slide path
        // unless the separate slidefix branch is being used. Keeping a
        // residual negative z here causes forward+down traces and "sticky"
        // wall catches on brush seams and 45-degree walls.
        pm_velocity_z = 0;

        // CS 1.6 stamina: landing fatigue bleeds horizontal speed for ~1.3s
        // after each jump (fuser2 decays from 1315 to 0 over that window).
        // factor_ref is the per-tick multiplier CS uses at 100 Hz (dt=0.01).
        // Raising it to (pm_frametime/0.01) makes the effect framerate-independent:
        // same net slowdown regardless of tickrate.
        //
        // sv_sliding bypass: skip the fatigue drag when the player is in
        // a slide stance (ducked, fast, on ground, master toggle on).
        // Tested inline so the bypass kicks in on the landing tick itself
        // — slide_friction_active isn't set until end-of-tick, but the
        // movement state we're testing is true the moment they land.
        float slide_bypass = 0;
        if (PM_ReadMovevar("sv_sliding", 0) && (self.flags & FL_DUCKING))
        {
            vector slide_hv = pm_velocity;
            slide_hv_z = 0;
            if (vlen(slide_hv) >= PM_ReadMovevar("sv_sliding_start_speed", 100))
                slide_bypass = 1;
        }
        // codstamina owns the landing horizontal cost via a single-tick
        // velocity cut at the landing edge in PM_PlayerMoveStep, so skip
        // the CS 1.6 multi-tick taper when sv_codstamina is on.
        if (mv_stamina && self.pm_fuser2 > 0 && !slide_bypass
            && PM_ReadMovevar("sv_codstamina", 0) <= 0)
        {
            float factor_ref = (100 - self.pm_fuser2 * 0.001 * 19) * 0.01;
            float factor = pow(factor_ref, pm_frametime * 100);
            pm_velocity_x *= factor;
            pm_velocity_y *= factor;
        }

        PM_Accelerate(wishdir, wishspeed, mv_accelerate);

        // if we ended up with no horizontal movement, stop cleanly
        if (pm_velocity_x == 0 && pm_velocity_y == 0)
        {
            pm_velocity = '0 0 0';
            return 0;
        }

        // Horizontal-only walk trace, matching Source/Momentum Mod WalkMove.
        // Z is intentionally NOT projected onto the slope normal — a diagonal
        // down-trace on a narrow downward slope catches on adjacent edge
        // geometry (walls/steps the bbox overhangs), producing the "stuck on
        // a thin downhill ramp" bug that gets worse at low speed. The flat
        // horizontal trace stays clear; PM_StayOnGround in PM_PlayerMoveStep
        // pulls us back onto the slope after.
        walk_dest = [
            pm_origin_x + pm_velocity_x * pm_frametime,
            pm_origin_y + pm_velocity_y * pm_frametime,
            pm_origin_z
        ];

        PM_Trace(pm_origin, walk_dest);
        if (trace_fraction == 1 && !trace_startsolid && !trace_allsolid)
        {
            pm_origin = trace_endpos;
            return 0;   // PM_StayOnGround drops us back to slope
        }

        PM_FollowGroundPlane();

        return PM_StepSlideMove(FALSE);
    }
    else
    {
        // airborne – uses the separate air-acceleration value (GoldSrc-style)
        PM_AirAccelerate(wishdir, wishspeed, mv_airaccelerate);

        // gravity
        pm_velocity_z -= mv_entgravity * mv_gravity * pm_frametime;

        return PM_SlideMove();
    }
}

// ============================================================================
//  19.  PM_CategorizePosition
// ============================================================================

void PM_CategorizePosition()
{
    vector hull_maxs;
    float  hull_height;

    hull_maxs = PM_CurrentMaxs();
    vector hull_mins = PM_CurrentMins();
    hull_height = hull_maxs_z - hull_mins_z;

    // --- water level check ---
    // Done first so the ground snap below can be skipped while swimming.

    pm_waterlevel = 0;
    pm_watertype  = CONTENT_EMPTY;

    local vector wpt;
    local float  cont;
    wpt_x = pm_origin_x;
    wpt_y = pm_origin_y;

    wpt_z = pm_origin_z + hull_mins_z + 1;
    cont  = pointcontents(wpt);
    if (cont <= CONTENT_WATER)
    {
        pm_watertype  = cont;
        pm_waterlevel = 1;

        wpt_z = pm_origin_z + hull_mins_z + hull_height * 0.5;
        cont  = pointcontents(wpt);
        if (cont <= CONTENT_WATER)
        {
            pm_waterlevel = 2;

            wpt_z = pm_origin_z + self.view_ofs_z;
            cont  = pointcontents(wpt);
            if (cont <= CONTENT_WATER)
                pm_waterlevel = 3;
        }
    }

    // --- ground check ---
    // trace 2 units below origin (Momentum Mod uses 2 for more generous
    // ground detection, reducing ground-state flicker on uneven surfaces)
    PM_Trace(pm_origin, pm_origin - '0 0 2');

    // Capture the entity directly below the player NOW, before the groundsnap
    // quadrant traces below clobber trace_ent — PM_UpdateStepSound reads it to
    // play metal footsteps when standing on the phys_files cabinet.
    self.pm_ground_ent = trace_ent;

    // Ground-snap suppress — force airborne under three conditions:
    //   - briefly after PM_CheckJump fires (pm_jump_groundstick_off_until),
    //     so the impulse can clear the floor before the 180 u/s
    //     threshold yanks it back (low-impulse punished jumps, etc.).
    //   - while actively being reeled in by the grapple AND the player
    //     isn't pressing jump.  grapple_attached (not grapple_rope_active)
    //     scopes the suppress to the pull phase only: hook flight keeps
    //     normal ground stick so the player can still walk / jump while
    //     waiting for the hook to land.  The jump-button override lets
    //     the player jump off the ground mid-pull — categorize allows
    //     normal ground detection on this tick, PM_CheckJump fires, and
    //     the impulse + the post-jump grace window takes them airborne.
    float groundsnap_off = (time < self.pm_jump_groundstick_off_until)
                        || (self.grapple_attached
                            && !(input_buttons & PM_BTN_JUMP));

    if (pm_velocity_z > 180 || groundsnap_off)
    {
        pm_onground    = FALSE;
        pm_groundnormal = '0 0 1';
    }
    else if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
    {
        pm_onground     = TRUE;
        pm_groundnormal = trace_plane_normal;
        // Skip the floor snap while swimming — it would kill upward velocity each frame.
        // Only snap if within 1 unit to avoid visible popping off small ledges
        // (ground detection reaches 2 units but snap stays conservative).
        if (pm_waterlevel < 2 && (pm_origin_z - trace_endpos_z) <= 1)
            pm_origin   = trace_endpos;
        self.pm_waterjumptime = 0;        // cancel water-jump on landing
    }
    else
    {
        // Quadrant ground check (Momentum Mod): the center trace hit a
        // steep surface — test 4 quarter-hull sub-boxes at hull corners
        // to find walkable ground the center missed at terrain seams.
        float found_ground = FALSE;
        if (trace_fraction < 1)
        {
            vector full_mins = PM_CurrentMins();
            vector full_maxs = PM_CurrentMaxs();
            vector qmins, qmaxs;
            vector gcheck_end = pm_origin - '0 0 2';

            // -x, -y quadrant
            qmins = full_mins;
            qmaxs = [min(0, full_maxs_x), min(0, full_maxs_y), full_maxs_z];
            PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
            if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                found_ground = TRUE;

            if (!found_ground)
            {
                // +x, +y quadrant
                qmins = [max(0, full_mins_x), max(0, full_mins_y), full_mins_z];
                qmaxs = full_maxs;
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }

            if (!found_ground)
            {
                // -x, +y quadrant
                qmins = [full_mins_x, max(0, full_mins_y), full_mins_z];
                qmaxs = [min(0, full_maxs_x), full_maxs_y, full_maxs_z];
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }

            if (!found_ground)
            {
                // +x, -y quadrant
                qmins = [max(0, full_mins_x), full_mins_y, full_mins_z];
                qmaxs = [full_maxs_x, min(0, full_maxs_y), full_maxs_z];
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }
        }

        if (found_ground)
        {
            pm_onground     = TRUE;
            pm_groundnormal = trace_plane_normal;
            // Do NOT snap origin — quadrant endpos could push into wall
        }
        else
        {
            pm_onground     = FALSE;
            pm_groundnormal = trace_plane_normal;
        }
    }
}

// ============================================================================
//  20.  PM_CheckJump
// ============================================================================

void PM_CheckJump()
{
    float dp;
    float jump_down;

    jump_down = input_buttons & PM_BTN_JUMP;

    // flying players jump via PM_FlyMove
    if (self.pm_movetype == PM_MOVETYPE_FLY)
        return;

    // dead – latch the held flag and bail
    if (self.pm_movetype == PM_MOVETYPE_DEAD)
    {
        self.pm_jump_held = TRUE;
        return;
    }

    // button released – clear the held latch.  In sv_jumpstyle 0 (GoldSrc
    // strict) we additionally require the release to happen WHILE on the
    // ground before another jump is allowed: that's what kills the
    // "tap jump exactly on landing tick" buffered-jump trick that the
    // edge check alone can't catch (release happens 1 tick airborne, press
    // happens 1 tick after touchdown — both ticks see jump_held=FALSE).
    if (!jump_down)
    {
        self.pm_jump_held = FALSE;
        if (pm_onground)
            self.pm_jump_strict_block = FALSE;
        return;
    }

    // ladder jump: push away from wall + upward
    // GoldSrc: holding jump when you touch a ladder ejects you immediately —
    // the pm_jump_held guard is intentionally skipped here.
    if (pm_on_ladder)
    {
        // pm_ladder_normal may point toward OR away from the wall.
        // When no explicit movedir is set on the trigger, the normal is
        // derived from the player's view direction — which points INTO the
        // wall when the player is facing it (the common case).  Probe the
        // direction to find which side has open space.
        vector eject_dir;
        PM_Trace(pm_origin, pm_origin + pm_ladder_normal * 4);
        if (!trace_startsolid && trace_fraction == 1)
            eject_dir = pm_ladder_normal;   // open space ahead – kick this way
        else
            eject_dir = -pm_ladder_normal;  // wall ahead – reverse

        pm_velocity               = eject_dir * 270;
        pm_velocity_z             = 0;    // GoldSrc: purely horizontal, gravity takes over
        pm_onground               = FALSE;
        self.pm_jump_held         = TRUE;
        self.pm_ladder_detach_time = 0.1;
        pm_on_ladder              = FALSE;  // skip PM_LadderMove this step
        return;
    }

    // button is held from here onward

    // water-jump already in progress
    if (self.pm_waterjumptime)
    {
        if (!mv_autohop)
            self.pm_jump_held = TRUE;
        return;
    }

    // in water – do a water-jump
    if (pm_waterlevel >= 2)
    {
        if (pm_watertype == CONTENT_WATER)
            pm_velocity_z = 100;
        else if (pm_watertype == CONTENT_SLIME)
            pm_velocity_z = 80;
        else
            pm_velocity_z = 50;

        pm_onground = FALSE;
        return;
    }

    // not on the ground – can't jump
    if (!pm_onground)
    {
        // GoldSrc-style jump gating: if jump is pressed in the air while
        // autohop is off, consume that press so it does not queue for landing.
        if (!mv_autohop)
            self.pm_jump_held = TRUE;
        return;
    }

    // sv_jumplag: post-landing jump cooldown.  Stamped on every
    // landing edge in PM_PlayerMoveStep as an absolute end-timestamp
    // (time + sv_jumplag).  Both CSQC prediction and SSQC compare
    // against the same `time`, eliminating the per-tick decay drift
    // the old remaining-duration version produced under fast CSQC
    // prediction (which let 1-2 predicted jumps slip through before
    // the server gate released).
    if (time < self.pm_jump_lag_end)
        return;

    // pogo prevention: require button release between jumps unless autohop is on
    if (self.pm_jump_held && !mv_autohop)
        return;

    // sv_jumpstyle 0 (GoldSrc strict): block until we've observed an
    // on-ground release since the last jump.  Source-style (default, 1)
    // skips this gate so the canonical "press right at landing" buffer
    // works.  Autohop forces lenient regardless.
    if (mv_jumpstyle == 0 && !mv_autohop && self.pm_jump_strict_block)
        return;

    // ramp fix: if we have downward momentum along the ground normal, clip it
    dp = pm_velocity * pm_groundnormal;
    if (pm_velocity_z < 0 && dp < PM_MAX_JUMPFIX_DP)
        pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);

    // Inherit tangent velocity from a rotating ground brush — runs
    // BEFORE the jump-impulse Z bump so the launch trajectory carries
    // the orbital component into the air (lands offset from launch
    // by ω·r·airtime, the natural feel for a player jumping off a
    // spinning platform).  No-op if the surface isn't rotating.
    PM_InheritRotatorTangent();

    // jump sound: step at full volume (water sound if feet are wet)
    if (pm_waterlevel >= 1)
        PM_EmitStepSound(FS_SOUND_WATER_BASE + floor(random() * FS_SOUND_WATER_COUNT), 1.0);
    else
        PM_EmitStepSound(FS_SOUND_STEP_BASE  + floor(random() * FS_SOUND_STEP_COUNT),  1.0);

    pm_onground       = FALSE;
    // CS 1.6 jump impulse: sqrt(2 * sv_gravity * 45) — 45-unit apex at g=800
    // gives the canonical 268.328 u/s.  Scales correctly with custom gravity.
    pm_velocity_z    += sqrt(2 * mv_gravity * 45);
    self.spread_penalty = SPREAD_PENALTY_JUMP;

    // sv_codstamina: jumps eat a fixed slice of the pool (the user
    // spec says jumps should cost stamina too), and the per-jump
    // height is scaled while the player is in the punish window so
    // an exhausted player can't bunny-hop their way out of trouble.
    //
    // Spam guard: if the punish-scaled impulse would leave the player
    // BELOW the PM_CategorizePosition airborne threshold (~180 u/s at
    // default gravity), the categorize sticks them back on the ground
    // immediately — and under autohop + held +jump that means
    // PM_CheckJump re-fires every tick (user-reported "spam every
    // frame at sv_codstamina_punish_jump_scale 0.5 or below").  When
    // we'd fall below the threshold, REWIND the impulse and force a
    // pm_jump_held latch so the press is "spent" and the player has
    // to release to try again (or wait for the bar to refill).
    //
    // Replay gate: skip the cost during CSQC reconcile-replay and
    // preview steps.  Halving the *impulse* DOES need to run on
    // replays (otherwise the predicted apex would diverge from the
    // server), so the halve sits OUTSIDE the skip_drain guard.
    // sv_codstamina drain block — cost only (the apex-scale override
    // for the punished case is applied AFTER the CS 1.6 stamina taper
    // below so it determines the FINAL velocity instead of being
    // re-tapered into the ground-snap region).
    if (PM_ReadMovevar("sv_codstamina", 0) > 0)
    {
        float jump_skip = 0;
#ifdef CSQC
        if (pm_suppress_sounds) jump_skip = 1;
#endif
        if (!jump_skip)
        {
            float jc = PM_ReadMovevar("sv_codstamina_jump_cost", 0.10);
            if (jc < 0) jc = 0;
            self.codstamina -= jc;
            if (self.codstamina < 0) self.codstamina = 0;
            if (self.codstamina <= 0)
                self.codstamina_punished = 1;
        }
    }

    // CS 1.6 stamina latch + landing movement cap.  The Z velocity
    // taper at line ~1798 was previously compounding with sv_codstamina
    // (multiplying the codstamina punish-scale until the player
    // couldn't clear the 180 u/s ground-snap floor).  User asked to
    // decouple the two: keep the landing movement cap (pm_fuser2 still
    // latches → consumed in PM_AirMove at line 1430-1436 for the
    // horizontal-speed reduction) but let codstamina handle the
    // jump-height reduction exclusively when it's on.
    if (mv_stamina)
    {
        if (self.pm_fuser2 > 0
            && PM_ReadMovevar("sv_codstamina", 0) <= 0)
            pm_velocity_z *= (100 - self.pm_fuser2 * 0.001 * 19) * 0.01;
        self.pm_fuser2 = 1315.7894;
    }

    // sv_codstamina punish jump-scale — applied LAST so its absolute
    // target velocity isn't tapered down by anything.  Apex
    // multiplier semantics: 0.5 = half-apex height.
    if (PM_ReadMovevar("sv_codstamina", 0) > 0 && self.codstamina_punished)
    {
        float jh = PM_ReadMovevar("sv_codstamina_punish_jump_scale", 0.5);
        if (jh < 0) jh = 0;
        if (jh > 1) jh = 1;
        float target_vel = sqrt(2 * mv_gravity * 45 * jh);
        if (target_vel < 180)
        {
            // Below the 180 u/s ground-snap floor — block the jump
            // entirely (no spam, press is spent until release).
            pm_velocity_z -= sqrt(2 * mv_gravity * 45);
            pm_onground = TRUE;
            self.pm_jump_held = TRUE;
            return;
        }
        // Set absolute target: subtract the line-1751 impulse to
        // recover pre-jump z, then add the apex-derived target.
        // No CS taper inversion needed — it's gated off above.
        float pre_jump_z = pm_velocity_z - sqrt(2 * mv_gravity * 45);
        pm_velocity_z = pre_jump_z + target_vel;
    }

    self.pm_jump_held  = TRUE;
    self.pm_jump_msec  = pm_frametime * 1000;
    self.pm_jump_strict_block = TRUE;   // sv_jumpstyle 0 latch: needs on-ground release before next jump

    // sv_jumplag: stamp the cooldown stamp HERE on the jump itself,
    // not only on the landing edge in PM_PlayerMoveStep.  The landing-
    // edge stamp covered the typical "land → wait 150 ms → jump" flow,
    // but it left a hole open for the user-reported "double jump that
    // goes higher than a regular jump" symptom:
    //   - autohop bypasses the pm_jump_held early-return at line 1714
    //   - if PM_StayOnGround / PM_CategorizePosition re-categorises the
    //     player as grounded within the SAME input frame's later
    //     substeps (clip-brush stairs, ramp-fix clip, low-impulse
    //     punished jumps that barely clear 180 u/s), the next PM_CheckJump
    //     call sees pm_onground == TRUE, autohop bypasses pm_jump_held,
    //     pm_jump_lag_end was still 0 because landing hadn't fired,
    //     and a second impulse stacks on the first.
    // Stamping at jump time closes that window: any re-entry within
    // sv_jumplag seconds of the original jump is rejected at line 1709-1710.
    float jl_jump = PM_ReadMovevar("sv_jumplag", 0);
    if (jl_jump > 0)
        self.pm_jump_lag_end = time + jl_jump;

    // Ground-snap suppress: block PM_CategorizePosition's snap-to-
    // ground for a short window so the impulse actually leaves the
    // floor.  User-reported "low impulse / punished jump sticks to
    // ground" cases:
    //   - sv_codstamina_punish_jump_scale 0.5 leaves the jump just
    //     under the 180 u/s airborne threshold → categorize re-grabs
    //     the ground on the same tick.
    //   - grapple yank can drop pm_velocity_z below 180 before
    //     leaving the ground; the categorize then locks the player.
    // Window default tracks the user's "0.05 s after jumping" ask.
    float gs_off = PM_ReadMovevar("pm_groundstick_suppress_jump", 0.05);
    if (gs_off > 0)
        self.pm_jump_groundstick_off_until = time + gs_off;
}

// ============================================================================
//  21.  PM_CheckWaterJump
// ============================================================================

// GoldSrc/Momentum Mod style water jump: hull traces + landing validation
const float WJ_HEIGHT       = 8;     // waist-height offset for wall detection
const float WJ_FORWARD      = 24;    // forward trace distance
const float WJ_UPVEL        = 310;   // vertical launch velocity (EzQuake/Quake value)
const float WJ_HVEL         = 50;    // horizontal push speed (away from wall)
const float WJ_LAND_TRACE   = 1024;  // downward trace to verify landing surface
const float WJ_WALL_SLOPE   = 0.1;   // wall must be near-vertical (normal.z < this)
const float WJ_LAND_SLOPE   = 0.7;   // landing surface must be walkable (normal.z >= this)

void PM_CheckWaterJump()
{
    vector flat_fwd;
    vector trace_start, trace_end;
    vector wall_normal;

    if (self.pm_waterjumptime)
        return;
    if (pm_velocity_z < -180)
        return;

    // Flatten forward into horizontal
    flat_fwd   = pm_forward;
    flat_fwd_z = 0;
    if (flat_fwd == '0 0 0')
        return;
    flat_fwd = normalize(flat_fwd);

    // Step 1: Trace forward at waist height — look for a near-vertical wall
    trace_start = pm_origin;
    trace_start_z += WJ_HEIGHT;
    trace_end = trace_start + flat_fwd * WJ_FORWARD;

    // Use a point-size hull for precise wall detection (like GoldSrc usehull=2)
    tracebox(trace_start, '0 0 0', '0 0 0', trace_end, MOVE_NORMAL, self);

    if (trace_fraction >= 1.0)
        return;   // no wall found
    if (fabs(trace_plane_normal_z) >= WJ_WALL_SLOPE)
        return;   // surface is too sloped (floor/ceiling, not a wall)

    wall_normal = trace_plane_normal;

    // Step 2: Trace forward at eye level — must be clear above the wall
    // Always use STANDING maxs so ducking doesn't lower the check height
    trace_start = pm_origin;
    trace_start_z += PM_MAXS_z - WJ_HEIGHT;   // eye level (standing height)
    trace_end = trace_start + flat_fwd * WJ_FORWARD;

    tracebox(trace_start, '0 0 0', '0 0 0', trace_end, MOVE_NORMAL, self);

    if (trace_fraction < 1.0)
        return;   // blocked at eye level, can't climb over

    // Step 3 (Momentum Mod): Trace downward from the eye-level endpoint
    // to verify there's a walkable landing surface on top of the ledge
    trace_start = trace_end;
    trace_end = trace_start;
    trace_end_z -= WJ_LAND_TRACE;

    tracebox(trace_start, '0 0 0', '0 0 0', trace_end, MOVE_NORMAL, self);

    if (trace_fraction >= 1.0)
        return;   // no ground found — bottomless on the other side
    if (trace_plane_normal_z < WJ_LAND_SLOPE)
        return;   // landing surface too steep to stand on

    // All checks passed — launch the water jump
    // Horizontal velocity pushes away from the wall (GoldSrc style)
    pm_velocity_x          = wall_normal_x * -WJ_HVEL;
    pm_velocity_y          = wall_normal_y * -WJ_HVEL;
    pm_velocity_z          = WJ_UPVEL;
    self.pm_waterjumptime  = 2;
    self.pm_jump_held      = TRUE;
}

// ============================================================================
//  22.  PM_NudgePosition  –  un-stuck on 1/8-unit grid
// ============================================================================

// Soft entity-aware depenetration.  Runs only when the world-only nudge
// left us overlapping another solid entity (another player, breakable,
// etc.).  Pushes horizontally away from the nearest offender in 0.5u
// steps until clear, or accepts overlap if no clear spot is found
// within 8 units (brief overlap beats frozen players).
void PM_SoftDepenetrate()
{
    entity  e, best;
    float   best_dsq, dsq;
    vector  push, delta, try;
    float   i;

    best     = world;
    best_dsq = 4096;   // 64*64 search radius

    for (e = findradius(pm_origin, 64); e; e = e.chain)
    {
        if (e == self)
            continue;
        if (e.solid == SOLID_NOT || e.solid == SOLID_TRIGGER)
            continue;
        // noblock: never push off another player (still depenetrates walls,
        // breakables and props). Belt-and-suspenders for a stash-coverage gap
        // — a stashed player is already SOLID_NOT and skipped above.
        if (pm_noblock_active
            && (e.classname == "player" || e.classname == "player_visual_proxy"))
            continue;

        delta   = e.origin - pm_origin;
        delta_z = 0;
        dsq     = delta * delta;
        if (dsq < best_dsq)
        {
            best_dsq = dsq;
            best     = e;
        }
    }

    if (best == world)
        return;   // nothing nearby; accept current position

    push = pm_origin - best.origin;
    push_z = 0;
    if (push * push < 0.0001)
    {
        // exact overlap – pick a deterministic horizontal direction.
        // Derive from origin bits so it's identical on client + server.
        float ang = (pm_origin_x + pm_origin_y) * 0.1;
        push_x = cos(ang);
        push_y = sin(ang);
        push_z = 0;
    }
    push = normalize(push);

    for (i = 1; i <= 16; i++)
    {
        try = pm_origin + push * (i * 0.5);
        if (PM_TestPositionFull(try))
        {
            pm_origin = try;
            return;
        }
    }
    // no clear spot – leave pm_origin alone; next frame's slide will try again.
}

void PM_NudgePosition()
{
    vector  base, try;
    float   i, x, y, z;
    // sign table: 0, -0.125, +0.125
    local float sign[3];
    sign[0] = 0;
    sign[1] = -0.125;
    sign[2] =  0.125;

    // Fast path: if the current sub-pixel position is already valid, leave
    // it alone. The grid snap below destroys movement precision below 1/8
    // unit (catastrophic at low speeds — at 1 u/s and 100 Hz tickrate the
    // per-tick displacement is 0.01 unit, far below the grid resolution,
    // so off-axis components get rounded away every tick and direction
    // snaps to the dominant axis). The grid path is only needed when the
    // player is actually embedded in geometry.
    if (PM_TestPosition(pm_origin))
    {
        if (!PM_TestPositionFull(pm_origin))
            PM_SoftDepenetrate();
        return;
    }

    // snap to 1/8-unit grid
    base_x = rint(pm_origin_x * 8) / 8;
    base_y = rint(pm_origin_y * 8) / 8;
    base_z = rint(pm_origin_z * 8) / 8;

    // try 27 offsets (3 axes × 3 values)
    for (i = 0; i < 27; i++)
    {
        x = i - floor(i / 3) * 3;
        y = floor(i / 3) - floor(i / 9) * 3;
        z = floor(i / 9);

        try_x = base_x + sign[x];
        try_y = base_y + sign[y];
        try_z = base_z + sign[z];

        if (PM_TestPosition(try))
        {
            pm_origin = try;
            if (!PM_TestPositionFull(pm_origin))
                PM_SoftDepenetrate();
            return;
        }
    }

    // nudging on the grid failed – try pushing up 1-18 units
    try = base;
    for (i = 1; i <= 18; i++)
    {
        try_z = base_z + i;
        if (PM_TestPosition(try))
        {
            pm_origin = try;
            if (!PM_TestPositionFull(pm_origin))
                PM_SoftDepenetrate();
            return;
        }
    }

    // nothing worked – leave position on the grid snap and try entity push.
    pm_origin = base;
    if (!PM_TestPositionFull(pm_origin))
        PM_SoftDepenetrate();
}

// ============================================================================
//  23.  PM_SpectatorMove
// ============================================================================

void PM_SpectatorMove()
{
    vector wishvel, wishdir;
    float  wishspeed, speed, newspeed, drop;

    // friction
    speed = vlen(pm_velocity);
    if (speed > 0)
    {
        drop     = speed * mv_friction * 1.5 * pm_frametime;
        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
    }

    // build wish velocity
    wishvel = pm_forward * input_movevalues_x
            + pm_right   * input_movevalues_y
            + v_up       * input_movevalues_z;

    wishspeed = vlen(wishvel);

    // Diagonal-bug cap: forward+strafe (or +up) sums into vlen and gives
    // sqrt(2)–sqrt(3) × the single-axis speed. Cap to the largest single
    // axis so noclip flies the same speed in every direction.
    float per_axis = max(max(fabs(input_movevalues_x), fabs(input_movevalues_y)),
                         fabs(input_movevalues_z));
    if (per_axis > 0 && wishspeed > per_axis)
    {
        wishvel   = wishvel * (per_axis / wishspeed);
        wishspeed = per_axis;
    }

    if (wishspeed > mv_spectatormaxspeed)
    {
        wishvel   = wishvel * (mv_spectatormaxspeed / wishspeed);
        wishspeed = mv_spectatormaxspeed;
    }

    if (wishspeed > 0)
    {
        wishdir = normalize(wishvel);
        PM_Accelerate(wishdir, wishspeed, mv_accelerate);
        // cap to spectatormaxspeed after acceleration
        speed = vlen(pm_velocity);
        if (speed > mv_spectatormaxspeed)
            pm_velocity = pm_velocity * (mv_spectatormaxspeed / speed);
    }

    pm_origin += pm_velocity * pm_frametime;
}

// ============================================================================
//  23b. PM_NoclipMove  –  free fly through walls (noclip)
//
//  Free fly through walls with smooth acceleration and friction.
//  Origin is moved directly with no collision traces.
// ============================================================================

float PM_NOCLIP_ACCEL     = 10;   // acceleration rate (same as ground accel)
float PM_NOCLIP_FRICTION  = 5;    // friction when decelerating
float PM_NOCLIP_SPRINT    = 2.5;  // sprint multiplier (shift / +button4)
float PM_NOCLIP_DUCK      = 0.4;  // duck multiplier (ctrl / +button6)

void PM_NoclipMove()
{
    vector wishvel, wishdir;
    float  wishspeed, maxspeed, factor;
    float  speed, newspeed, control, drop;

    maxspeed = mv_maxspeed * 5;

    // speed multipliers from held buttons
    factor = 1.0;
    if (input_buttons & PM_BTN_SPRINT)
        factor *= PM_NOCLIP_SPRINT;
    if (input_buttons & PM_BTN_DUCK)
        factor *= PM_NOCLIP_DUCK;

    // wish velocity from full 3-D view (forward + right + up)
    wishvel = pm_forward * input_movevalues_x * factor
            + pm_right   * input_movevalues_y * factor
            + v_up       * input_movevalues_z * factor;

    wishdir  = wishvel;
    wishspeed = vlen(wishdir);
    if (wishspeed > 0)
        wishdir = wishdir * (1.0 / wishspeed);

    // Diagonal-bug cap: cap to the largest single-axis input so flying
    // forward+strafe+up can't sneak ~sqrt(3) × the cardinal speed past
    // the maxspeed clamp below.
    float per_axis = max(max(fabs(input_movevalues_x), fabs(input_movevalues_y)),
                         fabs(input_movevalues_z)) * factor;
    if (per_axis > 0 && wishspeed > per_axis)
        wishspeed = per_axis;

    // clamp to max noclip speed (with factor already baked into wish)
    if (wishspeed > maxspeed * factor)
        wishspeed = maxspeed * factor;

    // smooth acceleration towards wish velocity
    PM_Accelerate(wishdir, wishspeed, PM_NOCLIP_ACCEL);

    // friction — bleed off speed when not pushing or overshooting
    speed = vlen(pm_velocity);
    if (speed < 1)
    {
        pm_velocity = '0 0 0';
    }
    else
    {
        control = max(speed, maxspeed * 0.25);
        drop = control * PM_NOCLIP_FRICTION * pm_frametime;
        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
    }

    // move directly — no collision
    pm_origin += pm_velocity * pm_frametime;
}

// ============================================================================
//  24.  PM_ReadMovevars  –  populate movevars from engine cvars
// ============================================================================

// Helper: read a movement cvar from serverinfo (client) or local cvar (server).
// The server pushes movement cvars to serverinfo so clients auto-sync.
#ifdef CSQC
float pm_mv_cache_valid;
float pm_mv_cache_stamp;
float pm_mv_cache_hull_height;
float pm_mv_cache_eye_height;
float pm_mv_cache_gravity;
float pm_mv_cache_maxspeed;
float pm_mv_cache_shiftspeed;
float pm_mv_cache_wepswap_transition;
float pm_mv_cache_stopspeed;
float pm_mv_cache_friction;
float pm_mv_cache_waterfriction;
float pm_mv_cache_accelerate;
float pm_mv_cache_airaccelerate;
float pm_mv_cache_wateraccelerate;
float pm_mv_cache_spectatormaxspeed;
float pm_mv_cache_stamina;
float pm_mv_cache_autohop;
float pm_mv_cache_jumpstyle;
float pm_mv_cache_mintic;

// CoD / sliding / stamina gate movevars.  These were read once-per-pmove-step
// through PM_ReadMovevar but were NOT in the cache, so each fell through to a
// serverkeyfloat() — the PM_ReadMovevarUncached hot path (~0.13s self, the #6
// cost in profiling).  Cached RAW (fallback 0 = no substitution) because some
// names are read with DIFFERENT fallbacks at different call sites
// (e.g. sv_sliding_start_speed uses 100 in three places, 250 in one); the
// call-site's own fallback is applied at the ladder return below, keeping every
// read bit-identical to the old uncached path.  Refreshed on the SAME
// serverprevtime stamp as the core vars, so predicted/authoritative parity holds.
float pm_mv_cache_codstamina;
float pm_mv_cache_sliding;
float pm_mv_cache_slidingcrouch;
float pm_mv_cache_codladders;
float pm_mv_cache_codscopes;
float pm_mv_cache_jumplag;
float pm_mv_cache_sliding_start_speed;
float pm_mv_cache_sliding_friction_mult;
float pm_mv_cache_sliding_boost;
float pm_mv_cache_sliding_end_speed;
float pm_mv_cache_codstamina_jump_cost;
float pm_mv_cache_codstamina_punish_jump_scale;
float pm_mv_cache_codstamina_land_cost;
float pm_mv_cache_codstamina_ground_grace;
float pm_mv_cache_codstamina_fire_suppress_time;
float pm_mv_cache_groundstick_suppress_jump;
float pm_mv_cache_ads_spread_mult;

float(string name, float fallback) PM_ReadMovevarUncached =
{
    float val;
    val = serverkeyfloat(name, 0);
    if (!val) val = fallback;
    return val;
};

void() PM_RefreshMovevarCache =
{
    float cache_stamp;

    cache_stamp = serverprevtime;
    if (cache_stamp <= 0)
        cache_stamp = cltime;

    if (pm_mv_cache_valid && pm_mv_cache_stamp == cache_stamp)
        return;

    pm_mv_cache_valid = TRUE;
    pm_mv_cache_stamp = cache_stamp;
    pm_mv_cache_hull_height         = PM_ReadMovevarUncached("sv_hull_height", 72);
    pm_mv_cache_eye_height          = PM_ReadMovevarUncached("sv_eye_height", 56);
    pm_mv_cache_gravity             = PM_ReadMovevarUncached("sv_gravity", 800);
    pm_mv_cache_maxspeed            = PM_ReadMovevarUncached("sv_maxspeed", 270);
    pm_mv_cache_shiftspeed          = PM_ReadMovevarUncached("sv_shiftspeed", 1.0);
    pm_mv_cache_wepswap_transition  = PM_ReadMovevarUncached("sv_wepswap_speed_transition", 0.15);
    pm_mv_cache_stopspeed           = PM_ReadMovevarUncached("sv_stopspeed", 100);
    pm_mv_cache_friction            = PM_ReadMovevarUncached("sv_friction", 4);
    pm_mv_cache_waterfriction       = PM_ReadMovevarUncached("sv_waterfriction", 1);
    pm_mv_cache_accelerate          = PM_ReadMovevarUncached("sv_accelerate", 5);
    pm_mv_cache_airaccelerate       = PM_ReadMovevarUncached("sv_airaccelerate", 150);
    pm_mv_cache_wateraccelerate     = PM_ReadMovevarUncached("sv_wateraccelerate", 10);
    pm_mv_cache_spectatormaxspeed   = PM_ReadMovevarUncached("sv_spectatormaxspeed", 500);
    pm_mv_cache_stamina             = PM_ReadMovevarUncached("sv_stamina", 0);
    pm_mv_cache_autohop             = PM_ReadMovevarUncached("sv_autohop", 0);
    pm_mv_cache_jumpstyle           = PM_ReadMovevarUncached("sv_jumpstyle", 1);
    pm_mv_cache_mintic              = PM_ReadMovevarUncached("sv_mintic", 0.01);

    // Gate movevars — cached RAW (fallback 0 => no substitution); the read site
    // applies its own fallback so differing per-site fallbacks stay correct.
    pm_mv_cache_codstamina                    = PM_ReadMovevarUncached("sv_codstamina", 0);
    pm_mv_cache_sliding                       = PM_ReadMovevarUncached("sv_sliding", 0);
    pm_mv_cache_slidingcrouch                 = PM_ReadMovevarUncached("sv_slidingcrouch", 0);
    pm_mv_cache_codladders                    = PM_ReadMovevarUncached("sv_codladders", 0);
    pm_mv_cache_codscopes                     = PM_ReadMovevarUncached("sv_codscopes", 0);
    pm_mv_cache_jumplag                       = PM_ReadMovevarUncached("sv_jumplag", 0);
    pm_mv_cache_sliding_start_speed           = PM_ReadMovevarUncached("sv_sliding_start_speed", 0);
    pm_mv_cache_sliding_friction_mult         = PM_ReadMovevarUncached("sv_sliding_friction_mult", 0);
    pm_mv_cache_sliding_boost                 = PM_ReadMovevarUncached("sv_sliding_boost", 0);
    pm_mv_cache_sliding_end_speed             = PM_ReadMovevarUncached("sv_sliding_end_speed", 0);
    pm_mv_cache_codstamina_jump_cost          = PM_ReadMovevarUncached("sv_codstamina_jump_cost", 0);
    pm_mv_cache_codstamina_punish_jump_scale  = PM_ReadMovevarUncached("sv_codstamina_punish_jump_scale", 0);
    pm_mv_cache_codstamina_land_cost          = PM_ReadMovevarUncached("sv_codstamina_land_cost", 0);
    pm_mv_cache_codstamina_ground_grace       = PM_ReadMovevarUncached("sv_codstamina_ground_grace", 0);
    pm_mv_cache_codstamina_fire_suppress_time = PM_ReadMovevarUncached("sv_codstamina_fire_suppress_time", 0);
    pm_mv_cache_groundstick_suppress_jump     = PM_ReadMovevarUncached("pm_groundstick_suppress_jump", 0);
    pm_mv_cache_ads_spread_mult               = PM_ReadMovevarUncached("sv_ads_spread_mult", 0);
};
#endif

float(string name, float fallback) PM_ReadMovevar =
{
    float val;
#ifdef CSQC
    PM_RefreshMovevarCache();
    // Hottest gate vars first — read every pmove step in friction/categorize.
    // RAW cache + call-site fallback (see the pm_mv_cache_codstamina decl above).
    if (name == "sv_codstamina")               { val = pm_mv_cache_codstamina; if (!val) val = fallback; return val; }
    if (name == "sv_sliding")                  { val = pm_mv_cache_sliding;    if (!val) val = fallback; return val; }
    if (name == "sv_hull_height")              return pm_mv_cache_hull_height;
    if (name == "sv_eye_height")               return pm_mv_cache_eye_height;
    if (name == "sv_gravity")                  return pm_mv_cache_gravity;
    if (name == "sv_maxspeed")                 return pm_mv_cache_maxspeed;
    if (name == "sv_shiftspeed")               return pm_mv_cache_shiftspeed;
    if (name == "sv_wepswap_speed_transition") return pm_mv_cache_wepswap_transition;
    if (name == "sv_stopspeed")                return pm_mv_cache_stopspeed;
    if (name == "sv_friction")                 return pm_mv_cache_friction;
    if (name == "sv_waterfriction")            return pm_mv_cache_waterfriction;
    if (name == "sv_accelerate")               return pm_mv_cache_accelerate;
    if (name == "sv_airaccelerate")            return pm_mv_cache_airaccelerate;
    if (name == "sv_wateraccelerate")          return pm_mv_cache_wateraccelerate;
    if (name == "sv_spectatormaxspeed")        return pm_mv_cache_spectatormaxspeed;
    if (name == "sv_stamina")                  return pm_mv_cache_stamina;
    if (name == "sv_autohop")                  return pm_mv_cache_autohop;
    if (name == "sv_jumpstyle")                return pm_mv_cache_jumpstyle;
    if (name == "sv_mintic")                   return pm_mv_cache_mintic;
    // Remaining gate vars (read on transitions: jump/land/slide-engage/scope).
    if (name == "sv_slidingcrouch")                 { val = pm_mv_cache_slidingcrouch;                 if (!val) val = fallback; return val; }
    if (name == "sv_codladders")                    { val = pm_mv_cache_codladders;                    if (!val) val = fallback; return val; }
    if (name == "sv_codscopes")                     { val = pm_mv_cache_codscopes;                     if (!val) val = fallback; return val; }
    if (name == "sv_jumplag")                       { val = pm_mv_cache_jumplag;                       if (!val) val = fallback; return val; }
    if (name == "sv_sliding_start_speed")           { val = pm_mv_cache_sliding_start_speed;           if (!val) val = fallback; return val; }
    if (name == "sv_sliding_friction_mult")         { val = pm_mv_cache_sliding_friction_mult;         if (!val) val = fallback; return val; }
    if (name == "sv_sliding_boost")                 { val = pm_mv_cache_sliding_boost;                 if (!val) val = fallback; return val; }
    if (name == "sv_sliding_end_speed")             { val = pm_mv_cache_sliding_end_speed;             if (!val) val = fallback; return val; }
    if (name == "sv_codstamina_jump_cost")          { val = pm_mv_cache_codstamina_jump_cost;          if (!val) val = fallback; return val; }
    if (name == "sv_codstamina_punish_jump_scale")  { val = pm_mv_cache_codstamina_punish_jump_scale;  if (!val) val = fallback; return val; }
    if (name == "sv_codstamina_land_cost")          { val = pm_mv_cache_codstamina_land_cost;          if (!val) val = fallback; return val; }
    if (name == "sv_codstamina_ground_grace")       { val = pm_mv_cache_codstamina_ground_grace;       if (!val) val = fallback; return val; }
    if (name == "sv_codstamina_fire_suppress_time") { val = pm_mv_cache_codstamina_fire_suppress_time; if (!val) val = fallback; return val; }
    if (name == "pm_groundstick_suppress_jump")     { val = pm_mv_cache_groundstick_suppress_jump;     if (!val) val = fallback; return val; }
    if (name == "sv_ads_spread_mult")               { val = pm_mv_cache_ads_spread_mult;               if (!val) val = fallback; return val; }
    val = PM_ReadMovevarUncached(name, fallback);
#else
    val = cvar(name);
    if (!val) val = fallback;
#endif
    return val;
};

void PM_ReadMovevars()
{
#ifdef CSQC
    PM_RefreshMovevarCache();
#endif

    // Hull height cvar — set to 56 (default) or 72 (GoldSrc proportions).
    // All duck/view values are derived so crouching adjusts automatically.
    float h;
#ifdef CSQC
    h = pm_mv_cache_hull_height;
#else
    h = PM_ReadMovevar("sv_hull_height", 72);
#endif
    if (h < 32) h = 56;

    //  standing hull:  0 → h   (feet at origin), shifted down by pm_player_z_offset
    //  duck hull:    h/4 → 3h/4 (symmetric shrink — feet pull up h/4 in air)
    //  eye heights:  h-8 standing, 3h/4-4 ducked (after ground origin shift, eyes at h/4-4 from floor)
    //  All Z values get -pm_player_z_offset folded in so the entity .origin
    //  sits at the model's natural pivot height instead of its feet.
    //
    // Hardcoded to half-height (36 for default h=72) to match the GoldSrc CS
    // player model convention (origin at body center). Both server and client
    // compile this file, so this single assignment keeps the prediction hull
    // in sync with the server's authoritative hull — without it, the client
    // predicts with the wrong bounds and the view drifts under high ping.
    pm_player_z_offset = h * 0.5;
    float zo = pm_player_z_offset;
    PM_MINS_x = -16;        PM_MINS_y = -16;        PM_MINS_z = 0 - zo;
    PM_MAXS_x = 16;         PM_MAXS_y = 16;         PM_MAXS_z = h - zo;
    PM_DUCK_MINS_x = -16;   PM_DUCK_MINS_y = -16;   PM_DUCK_MINS_z = h * 0.25 - zo;
    PM_DUCK_MAXS_x = 16;    PM_DUCK_MAXS_y = 16;    PM_DUCK_MAXS_z = h * 0.75 - zo;
    // Standing eye height controlled by sv_eye_height (mod default 56).
     // Origin sits zo above the feet, so subtract zo to land the eye at
     // sv_eye_height units above the ground. Server pushes this cvar into
     // serverinfo via SV_UpdateMovementServerInfo; CSQC's PM_ReadMovevar
     // reads it back via serverkeyfloat — both sides converge on the
     // same value so prediction and view stay in sync.
    float eye_h;
#ifdef CSQC
    eye_h = pm_mv_cache_eye_height;
#else
    eye_h = PM_ReadMovevar("sv_eye_height", 56);
#endif
    PM_VIEW_OFS_x = 0;      PM_VIEW_OFS_y = 0;      PM_VIEW_OFS_z = eye_h - zo;
    PM_DUCK_VIEW_OFS_x = 0; PM_DUCK_VIEW_OFS_y = 0; PM_DUCK_VIEW_OFS_z = h * 0.75 - 4 - zo;

#ifdef CSQC
    mv_gravity           = pm_mv_cache_gravity;
    mv_maxspeed          = pm_mv_cache_maxspeed;
    mv_shiftspeed        = pm_mv_cache_shiftspeed;
#else
    mv_gravity           = PM_ReadMovevar("sv_gravity", 800);
    mv_maxspeed          = PM_ReadMovevar("sv_maxspeed", 270);
    mv_shiftspeed        = PM_ReadMovevar("sv_shiftspeed", 1.0);
#endif

    // Per-weapon weight scaling.  self is the player entity in both
    // SSQC and CSQC (= predicted_player during prediction), so reading
    // self.weapon converges identically.
    //
    // Weapon_SpeedFactor_Smooth ramps the factor from prev → new based
    // on .pm_weapon_blend_progress (0..1).  Switch resets progress to 0
    // and captures prev_factor (CSQC_PredictSelectWeapon / W_SelectWeapon).
    // Here we advance progress by input_timelength / transition each
    // pmove tick — input-tick-driven, deterministic between live, replay
    // and server, regardless of ping.  Mirrors how shift-walk's bit-flag
    // is replayed identically on both sides.
    float transition;
#ifdef CSQC
    transition = pm_mv_cache_wepswap_transition;
#else
    transition = PM_ReadMovevar("sv_wepswap_speed_transition", 0.15);
#endif
    if (transition > 0.001 && self.pm_weapon_blend_progress < 1.0)
    {
        self.pm_weapon_blend_progress = min(1.0,
            self.pm_weapon_blend_progress + (input_timelength / transition));
    }
    else if (transition <= 0.001)
    {
        // Disabled / instant switch — pin progress to 1 so the factor
        // is unconditionally the new weapon's full value.
        self.pm_weapon_blend_progress = 1.0;
    }

    float wep_spd_factor = Weapon_SpeedFactor_Smooth();
    mv_maxspeed   *= wep_spd_factor;
    // mv_shiftspeed is a sprint/walk multiplier; only let the weapon
    // speed factor scale it when it's actually active (away from the
    // 1.0 no-op zone), otherwise a heavy weapon with wep_spd_factor < 1
    // would silently turn the no-op default into a slow-walk.
    if (mv_shiftspeed > 1.001 || (mv_shiftspeed > 0 && mv_shiftspeed < 0.999))
        mv_shiftspeed *= wep_spd_factor;
#ifdef CSQC
    mv_stopspeed         = pm_mv_cache_stopspeed;
    mv_friction          = pm_mv_cache_friction;
    mv_waterfriction     = pm_mv_cache_waterfriction;
    mv_accelerate        = pm_mv_cache_accelerate;
#else
    mv_stopspeed         = PM_ReadMovevar("sv_stopspeed", 100);
    mv_friction          = PM_ReadMovevar("sv_friction", 4);
    mv_waterfriction     = PM_ReadMovevar("sv_waterfriction", 1);
    mv_accelerate        = PM_ReadMovevar("sv_accelerate", 5);
#endif

    // sv_airaccelerate: mod default 150 (high-accel strafe feel). If the
    // movevar is 0 for some reason, fall back to mv_accelerate rather
    // than leaving air control at zero.
#ifdef CSQC
    mv_airaccelerate     = pm_mv_cache_airaccelerate;
#else
    mv_airaccelerate     = PM_ReadMovevar("sv_airaccelerate", 150);
#endif
    if (!mv_airaccelerate)    mv_airaccelerate     = mv_accelerate;

#ifdef CSQC
    mv_wateraccelerate   = pm_mv_cache_wateraccelerate;
    mv_spectatormaxspeed = pm_mv_cache_spectatormaxspeed;
    mv_stamina           = pm_mv_cache_stamina;
    mv_autohop           = pm_mv_cache_autohop;
    mv_jumpstyle         = pm_mv_cache_jumpstyle;
#else
    mv_wateraccelerate   = PM_ReadMovevar("sv_wateraccelerate", 10);
    mv_spectatormaxspeed = PM_ReadMovevar("sv_spectatormaxspeed", 500);
    mv_stamina           = PM_ReadMovevar("sv_stamina", 0);
    mv_autohop           = PM_ReadMovevar("sv_autohop", 0);
    mv_jumpstyle         = PM_ReadMovevar("sv_jumpstyle", 1);
#endif
#ifdef CSQC
    // Client-side autohop: predicts bunnyhop locally even when the server
    // hasn't enabled it.  Will desync from the server if sv_autohop is 0
    // (server rejects the queued jump on landing) — that's by design.
    if (cvar("cl_autohop"))
        mv_autohop = 1;
#endif

    // per-entity gravity multiplier
    mv_entgravity = self.gravity ? self.gravity : 1;
}

// ============================================================================
//  PM_BoxInTriggerBrush — BSP-shape overlap test for an angled trigger brush
//
// The legacy AABB pre-filter still runs as a cheap reject (covers most
// triggers, costs only six float compares). Triggers that pass the AABB
// then go through this probe to confirm the player's hull actually
// overlaps the BSP geometry — not just the AABB enclosing it. Without
// this step, an angled / diagonally-cut brush behaves as its full bbox.
//
// Trick: temporarily swap the trigger to SOLID_BSP and tag it with a
// dedicated dimension bit. Set self.dimension_hit to ONLY that bit so
// the tracebox can't hit anything else (world brushes, other triggers,
// players) — only this one specific trigger's BSP geometry.
//
// SSQC: triggers carry their `*N` BSP submodel since trigger spawn no
// longer zeroes modelindex (sv_push.qc / sv_teleport.qc / sv_ladder.qc).
//
// CSQC: trigger SendEntity functions now ship the BSP modelindex too;
// CSQC_PushTrigger_Update / TeleportTrigger / LadderTrigger bind it via
// setmodelindex so the probe runs identically here and prediction
// matches the server on angled brushes. Falls through to AABB-only if
// modelindex hasn't arrived yet (very early in the connection).
// ============================================================================

const float PM_TRIGGER_PROBE_DIM = 64;   // dim bit reserved for this probe

float(entity trig) PM_BoxInTriggerBrush =
{
    if (!trig.modelindex)
        return TRUE;   // no BSP available — fall back to AABB result

    float saved_solid     = trig.solid;
    float saved_dim_solid = trig.dimension_solid;
    float saved_dim_hit   = self.dimension_hit;

    trig.solid            = SOLID_BSP;                 // make MOVE_NORMAL hit it
    trig.dimension_solid |= PM_TRIGGER_PROBE_DIM;      // tag for filter
    self.dimension_hit    = PM_TRIGGER_PROBE_DIM;      // only collide with tagged

    tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(), pm_origin,
             MOVE_NORMAL, self);

    trig.solid            = saved_solid;
    trig.dimension_solid  = saved_dim_solid;
    self.dimension_hit    = saved_dim_hit;

    return trace_startsolid && trace_ent == trig;
};

// ============================================================================
//  Conveyor list management — shared between SSQC and CSQC.  Both add to
//  the same list (server during func_conveyor spawn, client during
//  CSQC_SolidBrush_Update when btype == BRUSH_TYPE_CONVEYOR).  Idempotent
//  add lets the brushsync wire re-fire CSQC_Ent_Update on visibility
//  transitions without re-adding.  Cycle-safe iteration on remove
//  mirrors push_list_remove_csqc.
// ============================================================================

void(entity c) Conveyor_AddToList =
{
    entity scan;
    float i = 0;
    for (scan = conveyor_list; scan; scan = scan.conveyor_next)
    {
        if (scan == c) return;
        i = i + 1;
        if (i > 4096) { dprint("Conveyor_AddToList: cycle\n"); return; }
    }
    c.conveyor_next = conveyor_list;
    conveyor_list   = c;
};

void(entity c) Conveyor_RemoveFromList =
{
    entity cur, prev;
    float i = 0;
    if (conveyor_list == c)
    {
        conveyor_list   = c.conveyor_next;
        c.conveyor_next = world;
        return;
    }
    prev = world;
    for (cur = conveyor_list; cur; cur = cur.conveyor_next)
    {
        if (cur == c)
        {
            if (prev) prev.conveyor_next = cur.conveyor_next;
            cur.conveyor_next = world;
            return;
        }
        prev = cur;
        i = i + 1;
        if (i > 4096)
        {
            dprint("Conveyor_RemoveFromList: cycle\n");
            if (prev) prev.conveyor_next = world;
            return;
        }
    }
};

// ============================================================================
//  PM_CheckConveyors  –  per-frame positional displacement from conveyors
//
//  Mirrors HL's basevelocity behaviour: each pmove tick that the player
//  overlaps a conveyor's bbox, displace pm_origin by movedir*speed*dt
//  along the conveyor.  Bypasses friction (the velocity field isn't
//  touched), so even slow conveyors actually push the player at the
//  configured speed.  Tracebox guards against shoving them through
//  walls — partial movement on hit, no movement on stuck-against.
//
//  Runs on both SSQC (authoritative) and CSQC (predicted) in pmove,
//  reading the same conveyor_list in both, so the predicted client
//  position matches the server's before any reconciliation.
// ============================================================================

void() PM_CheckConveyors =
{
    entity conv;
    vector player_absmin, player_absmax;
    vector cmin, cmax;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    float iter = 0;
    for (conv = conveyor_list; conv; conv = conv.conveyor_next)
    {
        iter = iter + 1;
        if (iter > 256) break;

        if (conv.spawnflags & 1)              // SF_CONVEYOR_NOPUSH
            continue;

        // Inflate bbox same as the server-side scan: 8 qu sideways
        // and 2/16 in Z, generous on top so a player whose feet are
        // exactly at the brush top still register.
        cmin = conv.absmin - '8 8 2';
        cmax = conv.absmax + '8 8 16';

        if (player_absmin_x >= cmax_x) continue;
        if (player_absmax_x <= cmin_x) continue;
        if (player_absmin_y >= cmax_y) continue;
        if (player_absmax_y <= cmin_y) continue;
        if (player_absmin_z >= cmax_z) continue;
        if (player_absmax_z <= cmin_z) continue;

        // Hybrid (HL basevelocity model): do BOTH positional
        // displacement AND a per-tick velocity bump.
        //
        // Positional is required for slow conveyors (e.g. speed=10
        // for shoving AFK players into a death pit).  The per-tick
        // velocity bump alone (speed * pm_frametime per tick) is
        // drained by ground friction as fast as it's added — at
        // friction=4 and ~72 Hz, an AFK player reaches a steady
        // state of ~5 qu/s no matter how high the configured speed
        // is.  Positional bypasses friction entirely so the player
        // travels at exactly conv.speed while on the belt.
        //
        // Velocity-add still runs so jumping off carries momentum:
        // the player accumulates ~conv.speed of velocity per second
        // of contact (minus friction drain), which becomes free
        // velocity the moment they leave the ground.  Lets the
        // ride-jump-ride speed-stacking pattern survive.
        //
        // Tracebox guards positional from shoving players through
        // walls — partial move on hit, no move on stuck-against.
        vector cstep = conv.movedir * (conv.speed * pm_frametime);
        vector cnew  = pm_origin + cstep;
        tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                 cnew, MOVE_NORMAL, self);
        if (trace_fraction >= 1.0)
            pm_origin = cnew;
        else if (trace_fraction > 0)
            pm_origin = trace_endpos;

        pm_velocity = pm_velocity + conv.movedir * (conv.speed * pm_frametime);
    }
};

// ============================================================================
//  Rotating-brush carry list  –  shared SSQC + CSQC.  Server adds the
//  brush in Mover_RotateStart and removes in rotdoor_hit_top /
//  rotdoor_hit_bottom; CSQC adds in CSQC_SolidBrush_Update whenever
//  avelocity is non-zero and removes when it returns to zero.  Idempotent
//  add and cycle-safe remove mirror Conveyor_Add/RemoveFromList.
// ============================================================================

void(entity c) RotatingBrush_AddToList =
{
    entity scan;
    float i = 0;
    for (scan = rotating_brush_list; scan; scan = scan.rotating_brush_next)
    {
        if (scan == c) return;
        i = i + 1;
        if (i > 4096) { dprint("RotatingBrush_AddToList: cycle\n"); return; }
    }
    c.rotating_brush_next = rotating_brush_list;
    rotating_brush_list   = c;
};

void(entity c) RotatingBrush_RemoveFromList =
{
    entity cur, prev;
    float i = 0;
    if (rotating_brush_list == c)
    {
        rotating_brush_list   = c.rotating_brush_next;
        c.rotating_brush_next = world;
        return;
    }
    prev = world;
    for (cur = rotating_brush_list; cur; cur = cur.rotating_brush_next)
    {
        if (cur == c)
        {
            if (prev) prev.rotating_brush_next = cur.rotating_brush_next;
            cur.rotating_brush_next = world;
            return;
        }
        prev = cur;
        i = i + 1;
        if (i > 4096)
        {
            dprint("RotatingBrush_RemoveFromList: cycle\n");
            if (prev) prev.rotating_brush_next = world;
            return;
        }
    }
};

// ============================================================================
//  Linear-motion brush list  –  shared SSQC + CSQC.  Sliding func_door
//  and func_button add to this list when Mover_Start sets velocity and
//  remove when motion completes.  Mirrors RotatingBrush_*.
// ============================================================================

void(entity c) MovingBrush_AddToList =
{
    entity scan;
    float i = 0;
    for (scan = moving_brush_list; scan; scan = scan.moving_brush_next)
    {
        if (scan == c) return;
        i = i + 1;
        if (i > 4096) { dprint("MovingBrush_AddToList: cycle\n"); return; }
    }
    c.moving_brush_next = moving_brush_list;
    moving_brush_list   = c;
};

void(entity c) MovingBrush_RemoveFromList =
{
    entity cur, prev;
    float i = 0;
    if (moving_brush_list == c)
    {
        moving_brush_list   = c.moving_brush_next;
        c.moving_brush_next = world;
        return;
    }
    prev = world;
    for (cur = moving_brush_list; cur; cur = cur.moving_brush_next)
    {
        if (cur == c)
        {
            if (prev) prev.moving_brush_next = cur.moving_brush_next;
            cur.moving_brush_next = world;
            return;
        }
        prev = cur;
        i = i + 1;
        if (i > 4096)
        {
            dprint("MovingBrush_RemoveFromList: cycle\n");
            if (prev) prev.moving_brush_next = world;
            return;
        }
    }
};

// Rotate `pt` around `pivot` by `deg` on the picked axis.  Mirrors
// the server-side RotDoor_RotateAround in sv_doors_rotating.qc so
// client carry prediction lands at the same position the server's
// Brush_RotateCarry pass produces.
//   ax_idx 0 = pitch (X), 1 = yaw (Y, default), 2 = roll (Z)
vector(vector pt, vector pivot, float deg, float ax_idx) PM_RotateAroundPivot =
{
    float rad = deg * 0.017453293;
    float c = cos(rad);
    float s = sin(rad);
    vector rel = pt - pivot;
    vector r;

    if (ax_idx == 0)
    {
        r_x = rel_x * c + rel_z * s;
        r_y = rel_y;
        r_z = -rel_x * s + rel_z * c;
    }
    else if (ax_idx == 2)
    {
        r_x = rel_x;
        r_y = rel_y * c - rel_z * s;
        r_z = rel_y * s + rel_z * c;
    }
    else
    {
        r_x = rel_x * c - rel_y * s;
        r_y = rel_x * s + rel_y * c;
        r_z = rel_z;
    }

    return pivot + r;
};

vector(entity rb) PM_RotatorPivot =
{
    if (rb.has_custom_pivot)
        return rb.custom_pivot;
    return rb.origin;
};

// Tangent velocity inheritance — when the player leaves a rotating
// brush (jump or step-off), they should retain the orbital velocity
// they had while attached, otherwise the launch / drop happens with
// zero horizontal velocity (the carry is setorigin-based, doesn't
// touch pm_velocity).  Trace the hull down 4 qu, find the brush we're
// standing on, compute v_tan = ω × r at the player's offset from the
// brush pivot, and add to pm_velocity.  Same axis-pick convention as
// PM_CheckRotatingCarry.  Runs on both SSQC and CSQC pmove so the
// predicted launch trajectory matches the authoritative one.
void() PM_InheritRotatorTangent =
{
    if (!pm_onground) return;
    PM_TraceHull(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                 pm_origin - '0 0 4');
    if (trace_fraction >= 1) return;
    if (trace_ent == world || trace_ent.avelocity == '0 0 0') return;

    float ax_idx;
    if (fabs(trace_ent.avelocity_x) >= fabs(trace_ent.avelocity_y)
     && fabs(trace_ent.avelocity_x) >= fabs(trace_ent.avelocity_z))
        ax_idx = 0;
    else if (fabs(trace_ent.avelocity_z) >= fabs(trace_ent.avelocity_y))
        ax_idx = 2;
    else
        ax_idx = 1;

    float omega_rad =
        (ax_idx == 1) ? trace_ent.avelocity_y :
        (ax_idx == 0) ? trace_ent.avelocity_x :
                        trace_ent.avelocity_z;
    omega_rad = omega_rad * 0.017453293;
    vector rel = pm_origin - PM_RotatorPivot(trace_ent);
    vector tangent = '0 0 0';
    if (ax_idx == 1)
    {
        tangent_x = -rel_y * omega_rad;
        tangent_y =  rel_x * omega_rad;
    }
    else if (ax_idx == 0)
    {
        tangent_y = -rel_z * omega_rad;
        tangent_z =  rel_y * omega_rad;
    }
    else
    {
        tangent_x =  rel_y * omega_rad;
        tangent_y = -rel_x * omega_rad;
    }
    pm_velocity = pm_velocity + tangent;
};

#ifdef CSQC
// CSQC-only client-side prediction of the rotating-brush carry pass.
//
// Server runs Brush_RotateCarry once per server tick (RotDoor_CarryTick
// in sv_doors_rotating.qc) which authoritatively rotates carried
// players around the brush's pivot.  Without a client-side mirror,
// predicted_player.origin sat still while the server-acked origin
// rotated each snapshot — every reconcile captured the rotation as
// an "err" that the smoother in CSQC_SmoothLocal then faded over up
// to 1.5 s.  Visible to the user as the player pulling around the
// platform with a long catch-up tail after the rotation stopped.
//
// This pass mirrors the server math via PM_RotateAroundPivot at
// pmove cadence so predicted_player.origin advances in lockstep
// with the visible brush.  Reconcile err stays at zero, smoother
// stays idle, position is in tight lockstep with the brush visual.
//
// Gated to CSQC: the SERVER's pmove (running on input commands)
// must NOT also apply this carry — the server's separate
// physics-tick RotDoor_CarryTick is the authoritative carry, and
// running both would double-apply.
void() PM_CheckRotatingCarry =
{
    entity rb;
    vector p_min, p_max;
    p_min = pm_origin + PM_CurrentMins();
    p_max = pm_origin + PM_CurrentMaxs();

    float iter = 0;
    for (rb = rotating_brush_list; rb; rb = rb.rotating_brush_next)
    {
        iter = iter + 1;
        if (iter > 256) break;
        if (rb.avelocity == '0 0 0') continue;

        // Strict "standing on this brush" gate — bbox overlap alone
        // grabs jumping players whose hulls still overlap the brush
        // volume (or sit just above the slim z inflation we use), and
        // the user expectation is the natural one: jump off → no
        // carry.  Trace the player's hull down a few units and accept
        // only when rb is the surface immediately under us.  Mirrors
        // the server's `p.flags & FL_ONGROUND && p.groundentity == self`
        // gate (added to Brush_RotateCarry alongside this).
        PM_TraceHull(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     pm_origin - '0 0 4');
        entity ground_ent      = trace_ent;
        float  ground_frac     = trace_fraction;
        float  on_this_brush   = (ground_frac < 1 && ground_ent == rb);
        // "Standing on a DIFFERENT rotating brush" gate for Phase 3.
        // Without this, two adjacent func_rotating barrels (e.g. an
        // X-axis row) both act on a player straddling them: barrel A
        // Phase-1-carries them around its pivot AND barrel B Phase-3-
        // slides them tangentially.  Combined motion is the random
        // fling the user reported.  When the player is already on a
        // currently-rotating brush other than rb, skip Phase 3 — the
        // stand-on brush's own iteration will handle them via Phase 1.
        float on_other_rotator = (ground_frac < 1
                                  && ground_ent != world
                                  && ground_ent != rb
                                  && ground_ent.avelocity != '0 0 0');

        // Pick dominant axis — matches Mover_RotateStart's selection.
        float ax_idx;
        if (fabs(rb.avelocity_x) >= fabs(rb.avelocity_y)
         && fabs(rb.avelocity_x) >= fabs(rb.avelocity_z))
            ax_idx = 0;
        else if (fabs(rb.avelocity_z) >= fabs(rb.avelocity_y))
            ax_idx = 2;
        else
            ax_idx = 1;

        float avel_a = (ax_idx == 0) ? rb.avelocity_x :
                       (ax_idx == 1) ? rb.avelocity_y : rb.avelocity_z;
        float deg_step = avel_a * pm_frametime;
        if (deg_step == 0) continue;
        vector rb_pivot = PM_RotatorPivot(rb);

        if (on_this_brush)
        {
            // === Phase 1: standing on the brush — lockstep carry ===
            //
            // Overlap test.  Mirrors the server's Brush_RotateCarry
            // pattern: for func_door_rotating we have pos1 (closed
            // angles) replicated, so we can transform the player into
            // the brush's local frame at angles=pos1 and AABB-test
            // against the brush's local mins/maxs.  This correctly
            // captures players standing on parts of the brush that
            // stick OUTSIDE the static AABB once the brush has rotated
            // past 90° (e.g., a small protruding platform on a big disc):
            // the static absmin/absmax on a brushmodel are the model's
            // angles=0 bounds, which DON'T sweep with rotation.
            //
            // For non-door rotating brushes (func_rotating /
            // func_pendulum, BRUSH_TYPE_STATIC) pos1 isn't shipped via
            // brushsync, so we fall back to a swept-sphere bound around
            // the brush's pivot — over-permissive but still gated by
            // the tracebox check below.
            float on_brush;
            if (rb.brush_type == BRUSH_TYPE_DOOR)
            {
                float local_unrot;
                if (ax_idx == 0)      local_unrot = rb.angles_x - rb.pos1_x;
                else if (ax_idx == 2) local_unrot = rb.angles_z - rb.pos1_z;
                else                  local_unrot = rb.angles_y - rb.pos1_y;
                while (local_unrot > 180)  local_unrot = local_unrot - 360;
                while (local_unrot < -180) local_unrot = local_unrot + 360;

                vector local_pos = PM_RotateAroundPivot(pm_origin, rb_pivot,
                                                         -local_unrot, ax_idx);
                vector lp_min = local_pos + PM_CurrentMins();
                vector lp_max = local_pos + PM_CurrentMaxs();
                vector dmin = rb.origin + rb.mins;
                vector dmax = rb.origin + rb.maxs + '0 0 4';
                on_brush = (lp_min_x <= dmax_x && lp_max_x >= dmin_x
                         && lp_min_y <= dmax_y && lp_max_y >= dmin_y
                         && lp_min_z <= dmax_z && lp_max_z >= dmin_z);
            }
            else
            {
                // Swept-sphere bound for non-door rotators.
                vector model_size = rb.maxs - rb.mins;
                float sphere_radius = vlen(model_size) * 0.5 + 32;
                vector pivot_offset = pm_origin - rb_pivot;
                on_brush = (vlen(pivot_offset) <= sphere_radius);
                if (on_brush)
                {
                    float z_min = rb.absmin_z - 4;
                    float z_max = rb.absmax_z + 4;
                    if (p_max_z <= z_min) on_brush = 0;
                    if (p_min_z >= z_max) on_brush = 0;
                }
            }
            if (!on_brush) continue;

            // Apply rotation, traced against geometry to avoid clipping
            // the player into a wall on the inside of the swept arc.
            // Temporarily un-solid the brush itself (mirrors the server's
            // Brush_RotateCarry pattern) so a player's bbox sitting at the
            // brush surface doesn't make the trace hit the brush from the
            // inside and falsely report blocked.
            vector new_origin = PM_RotateAroundPivot(pm_origin, rb_pivot,
                                                      deg_step, ax_idx);
            float saved_solid = rb.solid;
            rb.solid = SOLID_NOT;
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     new_origin, MOVE_NORMAL, self);
            rb.solid = saved_solid;
            if (cvar("cl_debug_rotcarry"))
                print(sprintf("[rotcarry] avel=%v ax=%g step=%g traced frac=%g org=%v -> %v\n",
                              rb.avelocity, ax_idx, deg_step, trace_fraction,
                              pm_origin, new_origin));
            if (trace_fraction >= 1.0)
                pm_origin = new_origin;
            else if (trace_fraction > 0)
                // Partial motion — carry the player as far as the tracebox
                // allowed.  Mirrors PM_CheckConveyors: refusing motion
                // entirely on a partial block leaves the player visibly
                // detached from the brush, which is exactly the "I'm not
                // being taken with the rotation" symptom on slow rotators
                // where the per-substep arc is small but the trace can
                // still nick adjacent geometry on tight rotations.
                pm_origin = trace_endpos;
            // else: trace_fraction == 0 (started solid) — leave in place.

            // Mark rotator contact so reconcile suppresses smoother
            // fade for the small per-snapshot rate-mismatch err.
            self.rotcarry_active_cltime = cltime;
        }
        else if ((self.flags & FL_ONGROUND) && !on_other_rotator)
        {
            // === Phase 3: ground player swept by the rotating mesh ===
            //
            // Mirrors server-side Brush_RotateCarry Phase 3
            // (sv_doors_rotating.qc:442-521).  Without this, a player
            // standing on the floor while the brush's swept arc moves
            // into them gets phased through on the client — the server
            // detects the overlap and slides them tangentially every
            // RotDoor_CarryTick (sv_func_tickrate, ~15ms at 64Hz), but
            // the client never applies the slide so prediction stays
            // inside the brush until the next snapshot reconciles with
            // a visible snap.  User-reported "low tickrate = pushed,
            // high tickrate = phase through and desync" is exactly
            // this gap.
            //
            // Detect mesh overlap at pm_origin (brush is SOLID_BSP at
            // this point — we did NOT hide it for this trace).
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     pm_origin, MOVE_NORMAL, self);
            if (!(trace_startsolid && trace_ent == rb))
                continue;     // mesh isn't intersecting our bbox

            // Tangent at the player's position relative to the pivot,
            // using the same axis convention as the server.
            vector rel = pm_origin - rb_pivot;
            float omega_rad = avel_a * 0.017453293;
            vector tangent = '0 0 0';
            if (ax_idx == 1)        // yaw
            {
                tangent_x = -rel_y * omega_rad;
                tangent_y =  rel_x * omega_rad;
            }
            else if (ax_idx == 0)   // pitch
            {
                tangent_y = -rel_z * omega_rad;
                tangent_z =  rel_y * omega_rad;
            }
            else                    // roll
            {
                tangent_x =  rel_y * omega_rad;
                tangent_y = -rel_x * omega_rad;
            }
            float tan_speed = vlen(tangent);
            if (tan_speed <= 0.01)
                continue;

            // Slide displacement & velocity-add scaling.  Server applies
            // (tan_speed / func_hz + 4qu) of slide + tangent velocity
            // once per func_tickrate tick.  To produce the same per-
            // second slide rate at arbitrary client pmove tickrates,
            // scale by (pm_frametime * func_hz) so num_substeps_per_sec
            // * per_substep_amount equals the server's per_second_amount.
            //
            // Read the server's sv_func_tickrate via STAT_FUNC_TICKRATE
            // — cvar("sv_func_tickrate") on CSQC returns 0 because the
            // cvar is registered CVAR_SIDE_SV (sh_cvar_table.qc:996).
            // The stat is set per-frame in sv_main.qc's per-player loop
            // so it reflects the server's authoritative value within
            // one snapshot.  Fallback 64 covers the initial-snapshot
            // warmup before the first stat arrives.
            float func_hz = getstatf(STAT_FUNC_TICKRATE);
            if (func_hz <= 0)  func_hz = 64;
            if (func_hz > 200) func_hz = 200;
            float rate_scale = pm_frametime * func_hz;

            vector tan_dir = tangent * (1.0 / tan_speed);
            float slide_dist = (tan_speed / func_hz + 4) * rate_scale;
            vector new_pos = pm_origin + tan_dir * slide_dist;

            float saved_solid_3 = rb.solid;
            rb.solid = SOLID_NOT;
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     new_pos, MOVE_NORMAL, self);
            rb.solid = saved_solid_3;

            if (cvar("cl_debug_rotcarry"))
                print(sprintf("[rotcarry-p3] tan_speed=%g slide=%g frac=%g pm_org=%v -> %v\n",
                              tan_speed, slide_dist, trace_fraction,
                              pm_origin, new_pos));

            if (trace_fraction >= 1.0)
            {
                // Full slide — player cleared the brush's swept arc
                // into free space.  Origin-only slide; NO velocity
                // addition.  The previous code added `tangent *
                // rate_scale` to pm_velocity per substep, which at
                // 100-300 Hz pmove accumulated into a huge tangent
                // velocity that pmove integration carried between
                // Phase 3 calls — producing the "I get flung across
                // the map" symptom on rotating barrels in a row.
                // Sliding the origin is sufficient to prevent
                // phase-through; the player's existing pmove velocity
                // (gravity / input) is preserved.
                pm_origin = new_pos;
            }
            else
            {
                // Partial or fully stuck — player can't be slid to a
                // free spot.  Snap to trace_endpos for a clean visual
                // (flush against the obstacle) but DON'T add tangent
                // velocity and DON'T continue advancing.  The server
                // mirrors this by setting blocked=1 in Brush_RotateCarry
                // Phase 3 → RotDoor_CarryPlayers halts the rotation
                // for this tick.  Brushsync ships zero avelocity (or
                // unchanged-this-tick angles) so client's next pmove
                // substep sees avel == 0 and skips Phase 3 entirely.
                if (trace_fraction > 0)
                    pm_origin = trace_endpos;
                // else: leave in place (fully stuck).
            }

            // Mark rotator contact for reconcile smoother filter
            // regardless of slide outcome — the server still applies
            // its (matching) Phase 3 this moment, so a per-snapshot
            // delta is expected; suppress the fade to avoid the
            // push/snap-back oscillation.
            self.rotcarry_active_cltime = cltime;
        }
    }
};
#endif    // end CSQC-only block opened above for PM_CheckRotatingCarry

// PM_CheckMovingPushers — runs on BOTH server and client pmove.
//
//   TRAIN branch (any side):
//     - Carry + geometry-push for func_train / func_tracktrain.
//     - Server-side runs the same code as client-side so player.origin
//       converges per pmove substep on both sides — no reconcile snap.
//     - Replaces the previous server-tick `Mover_PlatformCarry` /
//       `Mover_GeometryBlockPush` calls from func_train_move_tick:
//       running carry from two different tick rates (train tick 64Hz
//       + pmove 60-300Hz) double-applied deltas at snapshot boundaries
//       and produced visible jitter on a riding player.  Single
//       source on pmove fixes it.
//
//   DOOR / BUTTON branch (CSQC only):
//     - Bbox-overlap push prediction.  Server runs the authoritative
//       push from each door's Mover_TravelTick (sv_doors.qc); running
//       it from server pmove too would double-apply, so the door
//       branch stays gated.
//
// Both branches walk the same moving_brush_list.  Static brushes
// (BRUSH_TYPE_STATIC) and conveyors (BRUSH_TYPE_CONVEYOR) are
// untouched by either branch — conveyors use PM_CheckConveyors, and
// static brushes never have velocity != 0 anyway.
void() PM_CheckMovingPushers =
{
    entity rb;
    float iter = 0;
    for (rb = moving_brush_list; rb; rb = rb.moving_brush_next)
    {
        iter = iter + 1;
        if (iter > 256) break;
        if (rb.velocity == '0 0 0') continue;

        // ----- TRAIN branch: carry + geometry-push prediction -----
        // Mirrors the server-side Mover_PlatformCarry + Mover_GeometryBlockPush
        // pass that runs from the train's tick (sv_func_train.qc /
        // sv_func_tracktrain.qc).  Without a CSQC predictor the
        // player only saw carry/push effects via snapshot reconcile,
        // which produced the lurch-on-jump and drift-on-landing the
        // user reported.  This pass keeps pm_origin / pm_velocity in
        // lockstep with the train each pmove substep.
        if (rb.brush_type == BRUSH_TYPE_TRAIN || rb.brush_type == BRUSH_TYPE_VEHICLE)
        {
            // func_vehicle rides this exact branch: it's a velocity-driven
            // brush with avelocity_y yaw, so the carry (rb.velocity*pm_frametime
            // + angles_y delta + snap-jump) glues the driver AND passengers to
            // the deck and turns them with it — no vehicle-specific carry code.
            //
            // Skip carry/push entirely for noclip / spectator / non-
            // pmove states (matches the server-side gate).
            if (self.pm_movetype == PM_MOVETYPE_NOCLIP
             || self.pm_movetype == PM_MOVETYPE_SPECTATOR
             || self.pm_movetype == PM_MOVETYPE_NONE)
            {
                if (self.platform_carry == rb)
                {
                    self.platform_carry          = world;
                    self.platform_carry_velocity = '0 0 0';
                }
                rb.platform_prev_origin = rb.origin;
                rb.platform_prev_yaw    = rb.angles_y;
                rb.platform_prev_seeded = 1;
                continue;
            }

            // "Standing on this brush" probe — same ground trace the
            // server's carry helper uses (Brush_RotateCarry pattern).
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     pm_origin - '0 0 4', MOVE_NORMAL, self);
            float on_this_brush = (trace_fraction < 1 && trace_ent == rb);

            // func_vehicle: the active DRIVER is carried whenever they're on the
            // vehicle they drive — NOT gated on FL_ONGROUND (which flickers when
            // the car climbs/launches, dropping the prediction carry so the
            // predicted player stays at the mount spot and reconciles → jitter).
            // on_this_brush engages it the first frame; platform_carry keeps it
            // through airborne arcs.  rb.velocity already includes the gravity Z,
            // so the driver rides the whole arc.  Passengers still need FL_ONGROUND.
            float driver_airlock = (self.pm_driving
                                 && rb.brush_type == BRUSH_TYPE_VEHICLE
                                 && (on_this_brush || self.platform_carry == rb));

            if ((((self.flags & FL_ONGROUND) && on_this_brush)) || driver_airlock)
            {
                // === RIGID SEAT-BOLT (func_vehicle DRIVER only) ===
                // The locked driver has no walk input to mask the velocity-carry's
                // per-tick reconcile drift, so the predicted body lags/holds at the
                // mount spot and reconciles every snapshot → jitter.  Worse, once it
                // drifts off the deck the carry stops engaging, so platform_carry
                // (the camera seat-lock's reference) drops and the view flickers
                // back to the held spot.  Fix: PIN the driver into the car's frame.
                // Capture the mount offset once (rotated into the car's local yaw
                // frame), then re-derive pm_origin = car + rotate(seat) EVERY pmove
                // substep.  Server pmove + CSQC prediction + preview all run this, so
                // the body tracks the car exactly (no reconcile) and on_this_brush
                // stays true → platform_carry stays latched → seat-lock stays solid.
                if (driver_airlock)
                {
                    if (!self.veh_seat_ofs_set && on_this_brush)
                    {
                        self.veh_seat_ofs = PM_RotateAroundPivot(pm_origin, rb.origin,
                                                                 -rb.angles_y, 1) - rb.origin;
                        self.veh_seat_ofs_set = 1;
                    }
                    if (self.veh_seat_ofs_set)
                    {
                        pm_origin   = PM_RotateAroundPivot(rb.origin + self.veh_seat_ofs,
                                                           rb.origin, rb.angles_y, 1);
                        pm_velocity = rb.velocity;   // ride the car's velocity (inc. gravity Z); dismount inherits it

                        self.platform_carry          = rb;
                        self.platform_carry_velocity = rb.velocity;
                        self.platform_carry_prev_yaw = rb.angles_y;
#ifdef CSQC
                        self.platform_carry_jump_origin_consumed = rb.brush_snap_origin_cumulative;
                        self.platform_carry_jump_yaw_consumed    = rb.brush_snap_yaw_cumulative;
#endif
                        continue;   // bolted — skip the velocity-based carry below
                    }
                    // not captured yet: fall through to the velocity carry until the
                    // driver is genuinely standing on the deck (on_this_brush).
                }

                // === CARRY: apply translation + yaw delta ===
                // First tick of a new carry has zero delta — just seed.
                float just_started_carry = (self.platform_carry != rb);

                // PER-SUBSTEP MOTION is velocity-based, not origin-based.
                //   delta = rb.velocity * pm_frametime
                // velocity * frametime is smooth at INPUT rate.  Using
                // origin-delta (rb.origin - prev) would jitter at render
                // rate, because rb.origin only updates when predraw
                // fires (and predraw runs at render rate, not input
                // rate).  Multiple pmove substeps between two render
                // frames would see prev_origin == rb.origin (delta=0),
                // then one substep gets the full render-frame's worth
                // of motion in a single tick — visible as back-and-forth
                // jitter at low fps.
                //
                // The downside of pure velocity-based: when the brush's
                // velocity changes (corner turns, speed ramps), CSQC's
                // extrapolation was using OLD velocity for one snapshot
                // window after the actual server-side change.  When the
                // new-velocity snapshot finally arrives, rb.origin
                // jumps to the authoritative position — but the player
                // has only been advancing at OLD velocity, so the cab
                // visually lurches forward (or back) while the player
                // stays put → "player drifts backward in the cab on
                // every speed change".  The snap-jump consumer below
                // captures exactly that discontinuity and applies it
                // to the player too, keeping them locked through
                // velocity transitions.  See sh_customdefs comments on
                // brush_snap_origin_cumulative for details.
                vector origin_delta = rb.velocity * pm_frametime;

                // Yaw delta — uses PER-PLAYER prev_yaw (not per-brush)
                // so the CSQC preview pmove doesn't poison the next
                // real pmove's tracking.  CSQC_BuildPresentationView
                // save/restores platform_carry_prev_yaw around the
                // preview loop so previews don't leak forward.
                float yaw_delta = 0;
                if (!just_started_carry)
                {
                    yaw_delta = rb.angles_y - self.platform_carry_prev_yaw;
                    if (yaw_delta > 180)  yaw_delta = yaw_delta - 360;
                    if (yaw_delta < -180) yaw_delta = yaw_delta + 360;
                }

#ifdef CSQC
                // === SNAP-JUMP CONSUMPTION (CSQC only) ===
                // Each brushsync snapshot arrival records the
                // discontinuous jump in rb.origin / rb.angles_y on the
                // brush's brush_snap_origin_cumulative /
                // brush_snap_yaw_cumulative counters.  In the
                // constant-velocity case the jump is ~0 (extrapolation
                // matched authoritative); when velocity changes between
                // snapshots, the cumulative grows by exactly the amount
                // the cab's authoritative position diverged from what
                // CSQC's velocity-based predicted.  Applying that
                // discontinuity here keeps the carried player locked
                // to the cab through velocity transitions.
                //
                // On first carry tick we seed `_consumed` to the
                // current cumulative so we don't replay every jump
                // since map-start when a new player mounts the cab.
                //
                // ORIGIN vs YAW asymmetry: jump_origin is added to
                // origin_delta because the player's per-substep advance
                // (`rb.velocity * pm_frametime`) is integrated
                // INDEPENDENTLY of rb.origin's extrapolation — both use
                // the same velocity but accumulate separately, and
                // jump_origin captures the snap-time discrepancy.
                // jump_yaw is NOT added to yaw_delta because yaw_delta
                // is computed directly from `rb.angles_y - prev_yaw`,
                // and rb.angles_y already reflects the snap jump
                // (brushsync updates it on snapshot arrival).  Adding
                // jump_yaw on top double-counts the discontinuity —
                // user-reported as "player drifts through cab walls
                // when func_tracktrain turns on tracks": tracktrain
                // sets avelocity_y = 0 and changes angles directly per
                // tick, so the snap delta = entire rotation that tick,
                // and the previous code rotated the player around the
                // cab pivot by 2x the cab's actual rotation each snap.
                // Still update _consumed each substep so the counter
                // tracks for any future use.
                if (just_started_carry)
                {
                    self.platform_carry_jump_origin_consumed = rb.brush_snap_origin_cumulative;
                    self.platform_carry_jump_yaw_consumed    = rb.brush_snap_yaw_cumulative;
                }
                else
                {
                    vector jump_origin = rb.brush_snap_origin_cumulative
                                       - self.platform_carry_jump_origin_consumed;
                    origin_delta = origin_delta + jump_origin;
                    self.platform_carry_jump_origin_consumed = rb.brush_snap_origin_cumulative;
                    self.platform_carry_jump_yaw_consumed    = rb.brush_snap_yaw_cumulative;
                }
#endif

                vector new_origin = pm_origin + origin_delta;
                if (yaw_delta != 0)
                    new_origin = PM_RotateAroundPivot(new_origin, rb.origin,
                                                      yaw_delta, 1);

                // Un-solid the brush during the destination trace
                // so the player's bbox sitting on the train floor
                // doesn't false-block on its own surface.
                float t_saved_solid = rb.solid;
                rb.solid = SOLID_NOT;
                tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                         new_origin, MOVE_NORMAL, self);
                rb.solid = t_saved_solid;

                if (trace_fraction >= 1.0)
                    pm_origin = new_origin;
                else if (trace_fraction > 0)
                    pm_origin = trace_endpos;
                // else: blocked — leave pm_origin (server crushes).

#ifdef SSQC
                // Server-side: send view-yaw event to this player so
                // their CSQC accumulates input_angles and the camera
                // rotates with the cab.
                //
                // NOT for the func_vehicle DRIVER: they don't walk (WASD steers),
                // so the cab-relative-forward reason doesn't apply, and auto-turning
                // the driver's view with a fast-yawing car felt like a double/over
                // rotation.  The driver looks freely with the mouse; passengers
                // still get the view-rot.
                if (yaw_delta != 0 && self.classname == "player" && !self.pm_driving)
                {
                    msg_entity = self;
                    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
                    WriteByte(MSG_ONE, CSQC_EVENT_DOOR_VIEWROT);
                    WriteShort(MSG_ONE, yaw_delta * 100);
                }
#endif

                self.platform_carry          = rb;
                self.platform_carry_velocity = rb.velocity;
                self.platform_carry_prev_yaw = rb.angles_y;
            }
            else if (self.platform_carry == rb)
            {
                // === OFF-TRANSITION: inherit train's xy velocity ===
                // (preserve z so the jump impulse / fall stays intact).
                // Replace not add — matches the server-side semantics
                // the user explicitly asked for ("you should go only
                // as fast as the train, not get more speed").
                pm_velocity_x = self.platform_carry_velocity_x;
                pm_velocity_y = self.platform_carry_velocity_y;
                self.platform_carry          = world;
                self.platform_carry_velocity = '0 0 0';
            }
            else
            {
                // === GEOMETRY PUSH: BSP-aware push for players in
                // the train's path (not riding on top).  AABB cull
                // first to skip the expensive dimension-bit trace.
                vector t_pmin = pm_origin + PM_CurrentMins();
                vector t_pmax = pm_origin + PM_CurrentMaxs();
                float aabb_overlap = 1;
                if (t_pmax_x <= rb.absmin_x || t_pmin_x >= rb.absmax_x) aabb_overlap = 0;
                if (t_pmax_y <= rb.absmin_y || t_pmin_y >= rb.absmax_y) aabb_overlap = 0;
                if (t_pmax_z <= rb.absmin_z || t_pmin_z >= rb.absmax_z) aabb_overlap = 0;

                if (aabb_overlap)
                {
                    // Dimension-bit probe — only fires if the brush's
                    // BSP geometry actually intersects the player
                    // bbox, NOT just the AABB.  This is what makes
                    // hollow trains stop spuriously shoving players
                    // who are inside the cabin's empty interior.
                    float t_g_solid    = rb.solid;
                    float t_g_dimsolid = rb.dimension_solid;
                    float t_g_dimhit   = self.dimension_hit;
                    rb.solid             = SOLID_BSP;
                    rb.dimension_solid  |= PM_TRIGGER_PROBE_DIM;
                    self.dimension_hit   = PM_TRIGGER_PROBE_DIM;

                    tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                             pm_origin, MOVE_NORMAL, self);

                    rb.solid            = t_g_solid;
                    rb.dimension_solid  = t_g_dimsolid;
                    self.dimension_hit  = t_g_dimhit;

                    if (trace_startsolid && trace_ent == rb)
                    {
                        // Geometry-overlap confirmed → push along
                        // velocity by exactly one tick + 1 qu bias
                        // (tight to wall, no per-tick padding
                        // accumulation).
                        float t_pspeed = vlen(rb.velocity);
                        if (t_pspeed > 0)
                        {
                            vector t_pdir = rb.velocity * (1.0 / t_pspeed);
                            vector t_newpos = pm_origin
                                + t_pdir * (t_pspeed * pm_frametime + 1);

                            rb.solid = SOLID_NOT;
                            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                                     t_newpos, MOVE_NORMAL, self);
                            rb.solid = t_g_solid;

                            if (trace_fraction >= 1.0)
                            {
                                pm_origin   = t_newpos;
                                pm_velocity = pm_velocity + t_pdir * t_pspeed;
                            }
                            // else: blocked, leave.
                        }
                    }
                }
            }

            // Update brush snapshot for next tick's delta calc.
            rb.platform_prev_origin = rb.origin;
            rb.platform_prev_yaw    = rb.angles_y;
            rb.platform_prev_seeded = 1;
            continue;        // skip the door-style processing below
        }

#ifdef CSQC
        // ----- DOOR / BUTTON branch (CSQC-only) -----
        // Server runs the authoritative geometry push from
        // sv_doors.qc Mover_TravelTick → Mover_GeometryBlockPush;
        // running it here on the server would double-apply.  This
        // block predicts the same push client-side so predicted_
        // player.origin advances in lockstep with the door's push,
        // eliminating the snapshot-reconcile delay.
        //
        // Geometry-aware: the dimension-bit tracebox confirms the
        // player's bbox actually intersects the door's BSP geometry
        // before applying a push.  Previously this branch used a
        // raw absmin/absmax overlap test, which on a thin sliding
        // door pushed players standing in the door's AABB even
        // when their bbox wasn't touching the brush — felt like a
        // trigger volume rather than a mover.  Mirrors the TRAIN
        // branch's pattern above.
        if (rb.brush_type == BRUSH_TYPE_DOOR
         || rb.brush_type == BRUSH_TYPE_BUTTON)
        {
            // Skip prediction during noclip / spectator / non-pmove
            // (engine handles those entirely on its own).
            if (self.pm_movetype == PM_MOVETYPE_NOCLIP
             || self.pm_movetype == PM_MOVETYPE_SPECTATOR
             || self.pm_movetype == PM_MOVETYPE_NONE)
                continue;

            // Don't predict push if the door has already reached
            // (or crossed) its destination.  The engine's
            // MOVETYPE_NOCLIP extrapolates rb.origin via velocity
            // until the server's stop-snap arrives, so without this
            // the client keeps shoving the player past the door's
            // intended endpoint and the next snapshot snaps both
            // back — the previously-reported overshoot.  pos1 /
            // pos2 / mover_state are replicated for
            // BRUSH_TYPE_DOOR / BUTTON, so we know where the door is
            // headed.
            vector dest;
            if (rb.mover_state == MOVER_STATE_UP)
                dest = rb.pos2;
            else if (rb.mover_state == MOVER_STATE_DOWN)
                dest = rb.pos1;
            else
                dest = rb.origin;          // unknown — don't gate
            if (dest != rb.origin)
            {
                vector to_dest = dest - rb.origin;
                if (to_dest * rb.velocity <= 0.5)
                    continue;              // at/past dest, push is over
            }

            // Velocity resolves push direction.  No fallback here —
            // a door with zero velocity isn't moving, so nothing to
            // predict.
            float push_speed = vlen(rb.velocity);
            if (push_speed <= 0) continue;
            vector push_dir = rb.velocity * (1.0 / push_speed);

            // ===== PLATFORM CARRY: standing on top of the door =====
            // Player whose feet trace down to this brush rides 1:1
            // with the brush's per-tick translation.  If the swept
            // path is partially blocked (wall in front), the player
            // stops at trace_endpos; the door keeps moving past
            // them and the ground trace eventually misses the
            // brush, dropping the carry latch → they fall.  Doors
            // don't have angular motion or velocity transitions, so
            // no yaw rotation or snap-jump consumption is needed
            // — simpler than the train carry above.
            float d_saved_solid = rb.solid;
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     pm_origin - '0 0 4', MOVE_NORMAL, self);
            // Standing-on-brush detection.  Must EXCLUDE trace_startsolid:
            // when the player's bbox is overlapping the brush's BSP (e.g.
            // the door's mesh is intersecting the player because they're
            // wedged inside), tracebox returns trace_fraction=0 +
            // trace_startsolid=1.  Without the startsolid exclusion, a
            // wedged-inside player would test as "on this brush" and the
            // carry would yank them up and down with the door's
            // oscillation — exactly the "I follow it up and down" report.
            float d_on_this_brush = (trace_fraction < 1
                                  && trace_ent == rb
                                  && !trace_startsolid);

            if ((self.flags & FL_ONGROUND) && d_on_this_brush)
            {
                vector d_origin_delta = rb.velocity * pm_frametime;
                vector d_new_origin   = pm_origin + d_origin_delta;

                // Un-solid the brush during the destination trace so
                // standing on its top surface doesn't false-block
                // the carry's tracebox against itself.
                rb.solid = SOLID_NOT;
                tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                         d_new_origin, MOVE_NORMAL, self);
                rb.solid = d_saved_solid;

                if (trace_fraction >= 1.0)
                    pm_origin = d_new_origin;
                else if (trace_fraction > 0)
                    pm_origin = trace_endpos;
                // else: blocked completely (player at wall).  Leave
                // pm_origin alone — the door slides past below; on
                // a later substep the ground trace will miss the
                // brush and the player drops off the back.

                self.platform_carry          = rb;
                self.platform_carry_velocity = rb.velocity;
                continue;        // carry handled this player — skip geometry push
            }
            else if (self.platform_carry == rb)
            {
                // Was riding last substep, no longer on the brush —
                // inherit the door's xy velocity once so they leave
                // with the door's motion (preserve z for jump/fall).
                pm_velocity_x = self.platform_carry_velocity_x;
                pm_velocity_y = self.platform_carry_velocity_y;
                self.platform_carry          = world;
                self.platform_carry_velocity = '0 0 0';
            }

            // ===== GEOMETRY PUSH: bbox intersects brush BSP =====
            // Players NOT on top — pressed against the brush face.
            // Dimension-bit probe: save + restore brush solid /
            // dimension_solid and player dimension_hit.  Zero-length
            // swept-box trace at pm_origin returns
            // trace_startsolid + trace_ent == rb iff the brush's
            // BSP body is overlapping the player's bbox THIS
            // substep.  AABB overlap alone is no longer enough.
            float d_g_solid    = rb.solid;
            float d_g_dimsolid = rb.dimension_solid;
            float d_g_dimhit   = self.dimension_hit;
            // LOOK-AHEAD: probe the brush at its NEXT-substep footprint, not its
            // current one.  The server pushes the player a tick AHEAD (it advances
            // the brush before probing), so its leading face never enters the
            // player.  The client (this CSQC-only branch) was probing the brush at
            // its CURRENT origin, so overlap was only detected AFTER the door had
            // already integrated into the player — the predicted origin sat inside
            // the brush until a later substep slid free ("phase into the door, then
            // correct a moment later").  Advance rb by one substep's motion for the
            // detection trace only, then restore — same temporary-mutate-and-restore
            // pattern as the solid/dimension bits here.  The push-slide trace below
            // intentionally stays at the restored (current) origin.
            vector d_g_saved_origin = rb.origin;
            // Lead by ONE SERVER TICK of door motion, not one pmove substep: at high
            // client fps a substep (pm_frametime) is far smaller than the door's
            // per-tick advance, so a substep-sized lead still detects the overlap
            // late and the player phases in.  The door's authoritative position moves
            // in server-tick steps, so a one-tick lead matches when the server
            // actually shoves the player.
            // STAT_FUNC_TICKRATE, NOT cvar() — sv_func_tickrate is CVAR_SIDE_SV
            // so cvar() returns 0 on CSQC and the 40-floor below would mis-clamp
            // the lead.  The stat carries the server's (auto-tied) real rate.
            float d_g_hz = getstatf(STAT_FUNC_TICKRATE);
            if (d_g_hz < 40)  d_g_hz = 40;
            if (d_g_hz > 200) d_g_hz = 200;
            setorigin(rb, d_g_saved_origin + push_dir * (push_speed / d_g_hz));
            rb.solid             = SOLID_BSP;
            rb.dimension_solid  |= PM_TRIGGER_PROBE_DIM;
            self.dimension_hit   = PM_TRIGGER_PROBE_DIM;

            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     pm_origin, MOVE_NORMAL, self);

            rb.solid            = d_g_solid;
            rb.dimension_solid  = d_g_dimsolid;
            self.dimension_hit  = d_g_dimhit;
            setorigin(rb, d_g_saved_origin);

            if (!(trace_startsolid && trace_ent == rb))
                continue;        // no geometry intersection → no push

            // Push along velocity by exactly one substep's worth of
            // motion — no bias, no velocity addition.  This MUST
            // match the server's Mover_GeometryBlockPush_Player
            // (sv_platform_carry.qc:281), which does only:
            //
            //   advance       = mover_planned_velocity / sv_func_tickrate
            //   pushed_origin = p.origin + advance
            //   setorigin(p, pushed_origin)
            //
            // No +1u bias and no `pm_velocity += push_speed`.  Earlier
            // versions of this branch had both, which produced two
            // bugs:
            //   (a) +1u accumulates ~Hz qu/second extra push (e.g.
            //       100 substeps × 1u = 100 qu/s) over the server.
            //       Visible as client over-shoots door's intended
            //       endpoint, then snap-back on reconcile.
            //   (b) Velocity addition stacks `push_speed` per
            //       substep into pm_velocity, growing >> sv_maxvel
            //       and getting clamped — when the door stops,
            //       leftover velocity drives the player past the
            //       floor edge or wedges them in odd places (the
            //       "I don't fall / sink slowly / unstick when the
            //       door moves back" symptom).
            //
            // The +1 was historical surface clearance; without bias
            // the player sits flush against the brush face, which is
            // fine — they're not pushed back into the brush because
            // pmove's own slide handling keeps them out.
            vector new_pos = pm_origin + push_dir * (push_speed * pm_frametime);

            rb.solid = SOLID_NOT;
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     new_pos, MOVE_NORMAL, self);
            rb.solid = d_g_solid;

            if (trace_fraction >= 1.0)
            {
                // Cleanly slid out — match the server's clean-slide
                // branch (sv_platform_carry.qc).  Origin only,
                // velocity untouched.
                pm_origin = new_pos;
            }

            // Mark mover-push contact for reconcile lock skip + err
            // zero filter.  Drift-lock would otherwise hold the
            // camera at pre-reset while pmove pushes the player,
            // visibly sinking them into the door brush even though
            // server has them in the right place.  Mark unconditionally
            // (even on partial / blocked) — we're in contact with the
            // brush this substep regardless of slide outcome.
            self.mover_push_active_cltime = cltime;
            // else: player can't fully escape this substep.  Server-
            // side Mover_GeometryBlockPush will invoke the door's
            // .blocked callback (damage + reverse-or-grind).  We
            // leave pm_origin alone here so the predicted client
            // stays in sync with the server's authoritative crush
            // location; the door slides past via its own motion
            // (no longer pauses on block).
        }
#endif    // end DOOR/BUTTON CSQC-only branch
    }
};

// ============================================================================
//  25.  PM_CheckTriggerPushes  –  velocity impulse from overlapping push triggers
// ============================================================================

void(entity trig) PM_ApplyTriggerPush =
{
    vector offset;
    float  current, delta;

    if (trig.spawnflags & PUSH_SOURCE)
    {
        // Jump-pad style — uncapped velocity add along movedir.  The
        // previous "set to max(current, speed)" clamp held player
        // velocity at exactly `speed` even when the player was
        // already moving fast in the launch direction, which felt
        // like the trigger "stopped them early" mid-arc.  Adding
        // unconditionally gives a real throw: a thin one-frame
        // trigger imparts +speed, a thicker volume stacks more
        // bumps, and existing velocity (jump impulse, fall speed)
        // is preserved instead of being trimmed.  Mappers tune the
        // arc by the trigger's `speed` key + brush thickness; the
        // pmove gravity / friction passes carry the rest.
        pm_velocity = pm_velocity + trig.movedir * trig.speed;
    }
    else if (trig.spawnflags & PUSH_ADDITIVE)
    {
        // Additive — keep adding velocity each tick.  Velocity path
        // because the mapper's intent here is sustained acceleration
        // (e.g. a wind that ramps the player up).
        pm_velocity = pm_velocity + trig.movedir * trig.speed;
    }
    else
    {
        // Default (HL basevelocity model).  Always do positional
        // displacement so slow horizontal triggers (e.g. speed=10 for
        // shoving AFK players into a death pit) actually push the
        // player at exactly the configured speed.  The velocity
        // treatment then splits on movedir.z because vertical and
        // horizontal pushes want fundamentally different things:
        //
        //  - Vertical pushes (jumppads, updrafts): need a velocity
        //    FLOOR along movedir, not a per-tick add.  Per-tick add
        //    can never overcome gravity (gravity = 800 qu/s² vs a
        //    push of speed*dt per tick), so the player exits with
        //    large negative vz and drops.  Floor sets the upward
        //    component of velocity to >= trig.speed each tick the
        //    player is in the trigger; on exit, they keep that
        //    upward velocity and arc back down naturally under
        //    gravity.  Mid-air players falling into a jumppad get
        //    their fall cancelled (vz bumped up to trig.speed)
        //    instead of riding through with downward momentum.
        //    max(current, trig.speed) — never slows a player who
        //    was already moving along movedir faster than the pad's
        //    rated speed.
        //
        //  - Horizontal pushes: per-tick cumulative add.  Player
        //    input adds independently and friction drains on the
        //    ground, so pushes stay fightable; the positional
        //    component is what actually moves AFK players.  A
        //    floor here would harshly wipe opposite motion (e.g.
        //    walking west against an east-pointing trigger would
        //    snap velocity to +trig.speed east — the "can't fight
        //    at all" symptom this code exists to avoid).
        //
        // Threshold 0.5 = 30° above horizontal — anything steeper
        // is treated as a vertical push.  Mappers angle their push
        // brushes either flat or straight up in practice; the
        // diagonal case is rare and 0.5 covers both intuitively.
        //
        // Tracebox guards positional from shoving players through
        // walls — partial move on hit, no move on stuck-against.
        vector tstep = trig.movedir * (trig.speed * pm_frametime);
        vector tnew  = pm_origin + tstep;
        tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                 tnew, MOVE_NORMAL, self);
        if (trace_fraction >= 1.0)
            pm_origin = tnew;
        else if (trace_fraction > 0)
            pm_origin = trace_endpos;

        if (trig.movedir_z >= 0.5)
        {
            // Vertical-ish — velocity floor along movedir.
            float along = pm_velocity * trig.movedir;
            if (along < trig.speed)
                pm_velocity = pm_velocity + trig.movedir * (trig.speed - along);
        }
        else
        {
            // Horizontal-ish — cumulative velocity-add.
            pm_velocity = pm_velocity + trig.movedir * (trig.speed * pm_frametime);
        }
    }

    if (trig.spawnflags & PUSH_TUNNEL)
    {
        // Tunnel — corrective force toward centerline, kept on the
        // velocity path so it's a gentle drift over many ticks rather
        // than a positional snap.  Stacks with whichever main mode
        // (velocity or positional) the trigger above already applied.
        offset = (trig.origin + (trig.mins + trig.maxs) * 0.5) - pm_origin;
        offset = offset - trig.movedir * (offset * trig.movedir);
        pm_velocity = pm_velocity + offset * trig.speed * 0.1;
    }
};

void() PM_CheckTriggerPushes =
{
    entity trig;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    // Safety cap — mirrors PM_CheckLadder.  Under heavy prediction replay
    // (sv_minping high forcing catch-up steps in CSQC_BuildPresentationView)
    // the cumulative walk has hit the VM runaway limit; a corrupted list
    // with a cycle would loop forever here too.
    float iter_count = 0;
    for (trig = push_trigger_list; trig; trig = trig.push_next)
    {
        iter_count = iter_count + 1;
        if (iter_count > 256)
            break;

        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        // BSP refinement — confirms the player actually overlaps the
        // brush geometry (handles angled / diagonally-cut trigger brushes).
        if (!PM_BoxInTriggerBrush(trig))
            continue;

        PM_ApplyTriggerPush(trig);
    }
};

// ============================================================================
//  26.  PM_CheckTeleportTriggers  –  instant position snap through teleporters
// ============================================================================

void() PM_CheckTeleportTriggers =
{
    entity trig;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;

    // guard: player recently teleported, don't re-fire
    if (self.pm_teleport_time > 0)
        return;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    // Safety cap — same rationale as PM_CheckLadder / PM_CheckTriggerPushes.
    float iter_count = 0;
    for (trig = teleport_trigger_list; trig; trig = trig.tele_next)
    {
        iter_count = iter_count + 1;
        if (iter_count > 256)
            break;

        if (!trig.tele_resolved) continue;

        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        // BSP refinement — only teleport if the player actually overlaps
        // the brush geometry (not just the AABB enclosing it).
        if (!PM_BoxInTriggerBrush(trig))
            continue;

        // snap to destination
        pm_origin   = trig.tele_dest_origin;
        pm_onground = FALSE;

        // GoldSrc info_teleport_destination convention is "origin at
        // the player's FEET", not hull center.  Quake-style players
        // have origin at the bbox center, so dest entities authored
        // for HL maps can leave us startsolid in the floor.  Probe
        // the snapped position; if our hull is in solid, trace
        // straight down a hull-height-and-change to find the surface
        // just below and lift the bbox onto it (+1 qu so we're not
        // resting exactly on the plane).  No-op when the dest origin
        // is already valid (Quake-authored maps and any HL map that
        // placed the dest at hull center).
        tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                 pm_origin, MOVE_NORMAL, self);
        if (trace_startsolid)
        {
            vector probe = pm_origin - '0 0 80';
            tracebox(pm_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                     probe, MOVE_NORMAL, self);
            if (trace_fraction < 1)
                pm_origin = trace_endpos + '0 0 1';
        }

        if (!(trig.spawnflags & TELEPORT_KEEPVEL))
            pm_velocity = '0 0 0';

        self.pm_teleport_time = 0.2;

        // only one teleport per step
        return;
    }
};

// ============================================================================
//  27.  PM_CheckLadder + PM_LadderMove  –  GoldSrc-style ladder movement
// ============================================================================

float PM_PointHasLadderContents(vector pos)
{
    float cont;

    cont = pointcontents(pos);
    if (cont == CONTENT_LADDER || cont == SOLID_LADDER)
        return TRUE;

    return FALSE;
}

float PM_HullHasLadderContents(vector mins, vector maxs)
{
    vector probe_origin;

    tracebox(pm_origin, mins, maxs, pm_origin, MOVE_NOMONSTERS, self);
    if ((trace_endcontents & CONTENTBIT_FTELADDER)
        || (trace_endcontents & CONTENTBIT_Q2LADDER))
        return TRUE;

    probe_origin = pm_origin + (mins + maxs) * 0.5;
    return PM_PointHasLadderContents(probe_origin);
}

vector PM_DefaultLadderNormal()
{
    vector flat_fwd;

    flat_fwd   = pm_forward;
    flat_fwd_z = 0;

    if (vlen(flat_fwd) > 0)
        return normalize(flat_fwd);

    return '1 0 0';
}

float PM_LadderWallProbe(vector start, vector dir, float dist)
{
    if (dir == '0 0 0')
        return 2;

    tracebox(start, '0 0 0', '0 0 0', start + dir * dist, MOVE_NOMONSTERS, self);
    if (trace_startsolid || trace_allsolid)
        return 2;

    if (trace_fraction < 1 && trace_plane_normal != '0 0 0')
        return trace_fraction;

    return 2;
}

vector PM_FindLadderNormal(vector probe_origin, float probe_dist)
{
    vector flat_fwd;
    vector flat_right;
    vector best_normal;
    float best_fraction;
    float frac;

    flat_fwd = PM_DefaultLadderNormal();

    flat_right   = pm_right;
    flat_right_z = 0;
    if (vlen(flat_right) > 0)
        flat_right = normalize(flat_right);
    else
    {
        flat_right_x = -flat_fwd_y;
        flat_right_y = flat_fwd_x;
        flat_right_z = 0;
    }

    best_normal = '0 0 0';
    best_fraction = 2;

    frac = PM_LadderWallProbe(probe_origin, flat_fwd, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_fwd * -1, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_right, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_right * -1, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    if (best_normal != '0 0 0')
        return best_normal;

    return flat_fwd;
}

// Derive the ladder's face normal from the brush's own geometry — no
// `angle` key required.  Picks the thinnest horizontal axis (a typical
// ladder is thin in one X/Y direction and tall in Z) and returns the
// outward-facing unit vector on that axis based on which side of the
// brush centre the player is on.  This replaces the old fallback to
// player view direction (PM_DefaultLadderNormal), which gave a
// face-normal unrelated to the brush whenever the player wasn't
// looking exactly at it.
vector(entity trig) PM_LadderNormalFromBrush =
{
    vector size   = trig.maxs - trig.mins;
    vector centre = trig.origin + (trig.mins + trig.maxs) * 0.5;

    // Compare absolute X vs Y extents — the smaller one is the face axis.
    if (fabs(size_x) < fabs(size_y))
    {
        if (pm_origin_x < centre_x) return '-1 0 0';
        return '1 0 0';
    }
    if (pm_origin_y < centre_y) return '0 -1 0';
    return '0 1 0';
};

void() PM_CheckLadder =
{
    entity trig;
    vector player_mins, player_maxs;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;
    vector probe_origin;
    float probe_dist;

    pm_on_ladder     = FALSE;
    pm_ladder_normal = '0 0 0';

    // recently jumped off — don't re-grab
    if (self.pm_ladder_detach_time > 0)
        return;

    player_mins = PM_CurrentMins();
    player_maxs = PM_CurrentMaxs();

    if (PM_HullHasLadderContents(player_mins, player_maxs))
    {
        probe_origin = pm_origin + (player_mins + player_maxs) * 0.5;
        probe_dist = max(max(fabs(player_mins_x), fabs(player_maxs_x)),
                         max(fabs(player_mins_y), fabs(player_maxs_y))) + 8;

        pm_on_ladder = TRUE;
        pm_ladder_normal = PM_FindLadderNormal(probe_origin, probe_dist);
        return;
    }

    player_absmin = pm_origin + player_mins;
    player_absmax = pm_origin + player_maxs;

    // Safety cap: the VM aborts on runaway instruction count, and under
    // heavy prediction replay (e.g. sv_minping 900 forcing lots of catch-up
    // steps in CSQC_BuildPresentationView) the cumulative ladder walk has
    // been seen to exceed that limit — plus a corrupted list with a cycle
    // would loop forever here.  No real map has hundreds of ladders, so a
    // hard cap at 256 iterations is a no-op for healthy state and a clean
    // escape hatch for the degenerate cases.
    float iter_count = 0;
    for (trig = ladder_trigger_list; trig; trig = trig.ladder_next)
    {
        iter_count = iter_count + 1;
        if (iter_count > 256)
            break;

        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        // BSP refinement — only attach to ladder if the player actually
        // overlaps the brush geometry (handles angled / cut ladder brushes).
        if (!PM_BoxInTriggerBrush(trig))
            continue;

        pm_on_ladder = TRUE;

        // Always derive the ladder face from brush geometry —
        // user spec: "angle of the func_ladder doesn't affect the
        // way you climb it".  Previously a mapper-supplied `angle`
        // keyvalue on the func_ladder entity would override the
        // brush-geometry derivation and force a specific normal,
        // which made identically-shaped ladders climb differently
        // depending on whether the mapper had remembered to clear
        // the angle.  Now the climb is purely a function of the
        // brush's shape + the player's position relative to it,
        // independent of any mapper-set angle.
        pm_ladder_normal = PM_LadderNormalFromBrush(trig);
        return;
    }
};

// GoldSrc-style ladder movement.
//
// Wish velocity uses the full 3D forward vector (pitch included) so looking
// up while pressing forward is already faster than looking horizontal.
// On top of that, GoldSrc redirects the component pressing INTO the wall as
// extra upward movement, and pressing AWAY from the wall as downward movement.
// This gives the signature HL feel:
//   - look horizontal + W  → climb up
//   - look up + W          → climb up fast
//   - S (or back)          → slide down
//   - look up + W + facing wall → maximum upward speed
void() PM_LadderMove =
{
    vector wishvel, climb;
    float  along_normal, wishspeed;
    float  scale;

    scale = PM_MoveScale();

    // Full 3D forward: looking up contributes positive wishvel.z already
    wishvel = pm_forward * (input_movevalues_x * scale)
            + pm_right   * (input_movevalues_y * scale);
    wishvel_z += input_movevalues_z * scale;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }

    // Decompose into tangential component (along the ladder surface)
    along_normal = wishvel * pm_ladder_normal;
    climb        = wishvel - pm_ladder_normal * along_normal;

    // GoldSrc: the into-wall component drives upward motion, the
    // away-from-wall component drives downward.  pm_ladder_normal
    // points OUTWARD (toward the player), so:
    //   wishvel · outward < 0  ⇔  player pressing INTO wall  → up
    //   wishvel · outward > 0  ⇔  player pressing AWAY       → down
    // Hence subtract along_normal from climb.z so the negative
    // (into-wall) value bumps climb.z UP and the positive (away)
    // value drives it DOWN.  The previous + had it inverted, which
    // forced mappers to set angle pointing INTO the wall to
    // accidentally get the right behaviour — `angle` is no longer
    // required, see PM_LadderNormalFromBrush below.
    climb_z -= along_normal;

    pm_velocity = climb;
    PM_StepSlideMove(FALSE);
};

// ============================================================================
//  28.  PM_StepSounds  –  GoldSrc-accurate footstep / ladder / water audio
//
//  Only SSQC emits sound() calls so there are no double-plays during CSQC
//  prediction replay.  The step timer (pm_step_time) is part of shared state
//  so both sides tick it identically for clean reconciliation.
// ============================================================================

// Set TRUE during CSQC prediction replay and the presentation preview so that
// step sounds fire only on the single live prediction pass per input frame.
#ifdef CSQC
float pm_suppress_sounds;
// cltime of the most recent localsound played by this client.
// Used by CSQC_Event_Sound to gate echo suppression on actual local playback.
float pm_last_local_step_time;

// cl_debug_footsteps cadence bookkeeping. Per-tag so each log line's `dt`
// field represents the interval since the last occurrence of that tag,
// letting the user read predicted-vs-replay-vs-server cadence at a glance
// without cross-line subtraction.
float cl_last_predicted_step_time;
float cl_last_replay_step_time;
#endif

// Step sound emission, predicted on the stepper's CSQC and attacker-
// excluded on the server so there's no ping-delayed echo layered on top
// of the predicted step. The shared PM_UpdateStepSound above runs on both
// sides and keeps pm_step_time in sync, so both paths hit this helper at
// the same cadence.
void(float snd_idx, float vol) PM_EmitStepSound =
{
#ifdef SSQC
    if (cvar("sv_debug_footsteps"))
    {
        float sv_dt = self.sv_last_step_time > 0 ? (time - self.sv_last_step_time) : 0;
        print(sprintf("^6[step-server]^7 ent=%g t=%.3f dt=%.3f snd=%s vol=%.2f ",
                      num_for_edict(self), time, sv_dt, FS_SoundName(snd_idx), vol),
              sprintf("pstep=%.3f ft=%.4f spd=%.0f grnd=%g\n",
                      self.pm_step_time, pm_frametime,
                      vlen([self.velocity_x, self.velocity_y, 0]),
                      (self.flags & FL_ONGROUND) ? 1 : 0));
        self.sv_last_step_time = time;
    }

    // Route through a multicast event with an attacker-exclude byte.
    // Every OTHER client in PVS hears the step at ping-latency; the
    // stepper's CSQC already played its own copy via localsound below
    // (the non-replay prediction pass, before pm_suppress_sounds flips).
    //
    // Sound index (FS_SOUND_*) is a 1-byte enum — the string is rebuilt on
    // the receiver via FS_SoundName().  Saves ~35 B/event over WriteString.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_FOOTSTEP_SOUND);
    WriteByte(MSG_MULTICAST, num_for_edict(self));
    WriteByte(MSG_MULTICAST, bound(0, vol * 255, 255));
    WriteByte(MSG_MULTICAST, snd_idx);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z);
    multicast(self.origin, MULTICAST_PVS);
#endif
#ifdef CSQC
    {
        // Verbosity levels:
        //   1 = only audible events (predict, recv-play, recv-skip, server)
        //   2 = also include replay internals (suppressed steps from
        //       reconciliation — useful for deep debugging, noisy at
        //       high ping because each reconcile covers ~ping ms of
        //       buffered input and replays N muted steps through it).
        float verbose = cvar("cl_debug_footsteps");
        float cl_speed = vlen([self.velocity_x, self.velocity_y, 0]);
        float cl_grnd  = (self.flags & FL_ONGROUND) ? 1 : 0;
        string snd = FS_SoundName(snd_idx);
        if (pm_suppress_sounds)
        {
            if (verbose >= 2)
            {
                float rp_dt = cl_last_replay_step_time > 0 ? (time - cl_last_replay_step_time) : 0;
                print(sprintf("^1[step-replay]^7 t=%.3f dt=%.3f snd=%s vol=%.2f ",
                              time, rp_dt, snd, vol),
                      sprintf("pstep=%.3f ft=%.4f spd=%.0f grnd=%g suppress=1\n",
                              self.pm_step_time, pm_frametime, cl_speed, cl_grnd));
                cl_last_replay_step_time = time;
            }
        }
        else if (verbose >= 1)
        {
            float pr_dt = cl_last_predicted_step_time > 0 ? (time - cl_last_predicted_step_time) : 0;
            print(sprintf("^5[step-predict]^7 t=%.3f dt=%.3f snd=%s vol=%.2f ",
                          time, pr_dt, snd, vol),
                  sprintf("pstep=%.3f ft=%.4f spd=%.0f grnd=%g suppress=0\n",
                          self.pm_step_time, pm_frametime, cl_speed, cl_grnd));
            cl_last_predicted_step_time = time;
        }
    }

    // Suppressed during reconciliation replays so repeated input ticks
    // don't re-fire the same step each tick. Only the fresh (non-replay)
    // prediction pass emits — that's the tick where pm_step_time crosses
    // zero in real time.
    if (pm_suppress_sounds) return;
    // FTE extended localsound: (snd, channel, volume). Purely listener-
    // relative — no 3D positioning, no reverb, no distance attenuation —
    // so it stays pinned to the player regardless of how fast they move
    // (the positional sound(self, …) path trails the visual position
    // because the audio engine samples the emitter origin on its own
    // cadence). CHAN_BODY keeps the auto-replace semantics so a new step
    // cuts any tail of the previous one. Volume is honored: duck 0.4,
    // walk 0.5, sprint 1.0, ladder 0.65, water 0.5 — set by the branch
    // in PM_UpdateStepSound above.
    localsound(snd, CHAN_BODY, vol);
#endif
};

// Called once per simulation step from PM_PlayerMoveStep.
// Advances pm_step_time and plays a sound when the interval expires.
void() PM_UpdateStepSound =
{
    float speed;
    float interval;
    float vol;
    float snd_idx;

    // advance the countdown
    if (self.pm_step_time > 0)
    {
        self.pm_step_time -= pm_frametime;
        if (self.pm_step_time < 0)
            self.pm_step_time = 0;
        return;
    }

    // timer expired — decide whether to play a step
    // Ladder movement is primarily vertical, so measure full 3D speed there.
    // Ground/water movement is horizontal, so strip z for those checks.
    speed = vlen([pm_velocity_x, pm_velocity_y, 0]);

    if (pm_on_ladder && pm_waterlevel < 2)
    {
        // ladder — use total 3D speed so climbing up/down registers
        if (vlen(pm_velocity) < 50) return;
        interval = 0.35;
        vol      = 0.65;
        snd_idx  = FS_SOUND_LADDER_BASE + floor(random() * FS_SOUND_LADDER_COUNT);
    }
    else if (pm_waterlevel >= 1)
    {
        // water
        if (speed < 80) return;
        interval = 0.35;
        vol      = 0.50;
        snd_idx  = FS_SOUND_WATER_BASE + floor(random() * FS_SOUND_WATER_COUNT);
    }
    else if (pm_onground)
    {
        // ground
        if (self.flags & FL_DUCKING)
        {
            if (speed < 50) return;
            interval = 0.60;
            vol      = 0.40;
        }
        else if (speed >= 220)
        {
            interval = 0.30;
            vol      = 1.00;
        }
        else
        {
            if (speed < 100) return;
            interval = 0.40;
            vol      = 0.50;
        }
        snd_idx = FS_SOUND_STEP_BASE + floor(random() * FS_SOUND_STEP_COUNT);
        // Standing on a metal phys prop → metal footsteps instead.  pm_ground_ent was
        // captured in PM_CategorizePosition; the cabinet/barrel/can keep their classname
        // both server-side (sv_physprop.qc) and as the CSQC mirror, so SSQC + CSQC agree.
        // (Dropped weapons are intentionally excluded — too small to stand on.)
        if (self.pm_ground_ent.classname == "phys_files"
            || self.pm_ground_ent.classname == "phys_barrel"
            || self.pm_ground_ent.classname == "phys_can")
            snd_idx = FS_SOUND_METAL_BASE + floor(random() * FS_SOUND_METAL_COUNT);
    }
    else
    {
        return;  // airborne — no step
    }

    self.pm_step_time = interval;
    PM_EmitStepSound(snd_idx, vol);
};

// ============================================================================
//  PM_TryEngageSlide  –  shared engage path for both slide triggers
//
//  Returns 1 if the slide was engaged this call.  Both the landing-edge
//  handler (duck-land) and the crouch-press handler (sv_slidingcrouch)
//  call this so the engage state — flag, boost velocity, sound chain —
//  stays consistent across both entry points.  Idempotent: returns 0
//  if the slide is already active or any condition fails, without
//  touching pm_velocity or emitting the random slide sound.
// ============================================================================

float() PM_TryEngageSlide =
{
    if (self.slide_friction_active)
        return 0;
    if (!PM_ReadMovevar("sv_sliding", 0))
        return 0;
    if (!(self.flags & FL_DUCKING))
        return 0;
    if (!pm_onground)
        return 0;
    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
        return 0;

    vector engage_hvel = pm_velocity;
    engage_hvel_z = 0;
    float engage_hspeed = vlen(engage_hvel);
    if (engage_hspeed < PM_ReadMovevar("sv_sliding_start_speed", 100))
        return 0;

    self.slide_friction_active = 1;

    // Boost: stamp once at engage along the current horizontal
    // direction.  Guard against /0 (engage_hspeed >= start_speed so
    // it's already nonzero in practice — defensive check costs nothing).
    // sv_codstamina punish lockout: zero the boost while the player
    // is in the punish window so an exhausted player can't slide-
    // boost their way out of the lockout — matches the sprint /
    // hold-breath / jump lockouts already applied elsewhere.
    float boost = PM_ReadMovevar("sv_sliding_boost", 0);
    if (PM_ReadMovevar("sv_codstamina", 0) > 0 && self.codstamina_punished)
        boost = 0;
    if (boost != 0 && engage_hspeed > 0.001)
    {
        vector hdir = engage_hvel * (1 / engage_hspeed);
        pm_velocity_x += hdir_x * boost;
        pm_velocity_y += hdir_y * boost;
    }

#ifdef SSQC
    // Random one-shot slide sound.  Picks a random sounds/player/slideN.wav
    // (N = 1..5) on CHAN_BODY; no chain, no loop — slides longer than the
    // sample just go silent for the remainder.  Cheap to vary so it
    // doesn't get monotonous when the player slides repeatedly.
    float sl_pick = 1 + floor(random() * 5);
    if (sl_pick > 5) sl_pick = 5;
    sound(self, CHAN_BODY,
        sprintf("sounds/player/slide%g.wav", sl_pick),
        1, ATTN_NORM);
#endif

    return 1;
};

// ============================================================================
//  28.  PM_PlayerMoveStep  –  single fixed-size simulation slice
// ============================================================================

void PM_PlayerMoveStep()
{
    float  blocked;
    float  dp;
    float  was_onground;

    // --- load working state from entity ---
    pm_origin   = self.origin;
    pm_velocity = self.velocity;
    pm_onground = (self.flags & FL_ONGROUND) ? TRUE : FALSE;
    was_onground = pm_onground;

    // Reset the per-step ladder global so the NONE/SPECTATOR/NOCLIP
    // goto-done paths below — which skip PM_CheckLadder — latch FALSE
    // into self.pm_on_ladder_cached at done: instead of inheriting the
    // value from a prior PM_PlayerMoveStep call (which on SSQC could
    // be a DIFFERENT player from the per-frame player chain).  Without
    // this, a noclipping admin would inherit a ladder-climber's TRUE
    // and a freshly-spectated player would see the fire gate fire
    // until their next non-early-out tick.
    pm_on_ladder = FALSE;

    pm_frametime = input_timelength;
    if (pm_frametime <= 0)
        return;

    // --- read cvars ---
    PM_ReadMovevars();

    // Shift speed multiplier (+button4): scales input magnitude AND
    // max speed by sv_shiftspeed.  Applied on both CSQC prediction and
    // SSQC so client/server agree.
    //   sv_shiftspeed  >1   = sprint  (e.g. 1.5 → 50 % faster)
    //   sv_shiftspeed  <1   = walk    (e.g. 0.5 → half speed)
    //   sv_shiftspeed  =1   = no-op   (key armed but no speed change)
    //   sv_shiftspeed  =0   = disabled (key has no effect)
    // Crouch bypasses it.  Noclip bypasses it — noclip uses its own
    // PM_NOCLIP_SPRINT multiplier in PM_NoclipMove; doubling up here
    // would compound them.  The 0.001 deadzone around 1.0 keeps float
    // round-off (and heavy-weapon factor stacking) from producing a
    // tiny silent walk/sprint when the user wanted the feature off.
    float shift_active = (mv_shiftspeed > 1.001) ||
                         (mv_shiftspeed > 0 && mv_shiftspeed < 0.999);
    // sv_codstamina lockout: when the player has burned through the
    // stamina pool while sprinting (codstamina_punished = 1) the
    // sprint multiplier is gated off until the pool refills past
    // STAMINA_PUNISH_RECOVER_AT.  Walk (<1) is always allowed.
    float stamina_lockout = PM_ReadMovevar("sv_codstamina", 0) > 0
                         && self.codstamina_punished
                         && mv_shiftspeed > 1.001;
    if ((input_buttons & PM_BTN_SPRINT) && !(self.flags & FL_DUCKING)
        && shift_active
        && !stamina_lockout
        && self.pm_movetype != PM_MOVETYPE_NOCLIP)
    {
        if (mv_shiftspeed > 1.0)
        {
            // Sprint: forward-only.  Strafing or backing up cancels the
            // multiplier — the player has to commit to going forward to
            // get the speed boost.  Walk (<1) intentionally ignores this
            // gate so a slow-walk shuffle in any direction still works.
            // Raises both input magnitude and the cap so wishspeed can
            // actually reach the higher mv_maxspeed.
            if (input_movevalues_x > 0)
            {
                input_movevalues_x *= mv_shiftspeed;
                input_movevalues_y *= mv_shiftspeed;
                mv_maxspeed        *= mv_shiftspeed;
            }
        }
        else
        {
            // Walk: leave input alone — wishspeed will clamp against the
            // lowered mv_maxspeed.  Scaling input here too would weaken
            // accel (which is force = accel*wishspeed*dt) below what
            // friction takes back each tick, producing speed oscillation.
            // Pull stopspeed down with the target so friction stays in
            // its speed-proportional regime instead of acting at the
            // (un-scaled) 100 u/s floor and dragging slow targets to 0.
            mv_stopspeed *= mv_shiftspeed;
            mv_maxspeed  *= mv_shiftspeed;
        }
    }

    // Sliding suppresses forward (W) acceleration so the player can
    // steer (A/D) and brake (S) but can't re-extend the slide by holding
    // forward — keeps the mechanic from devolving into an infinite glide.
    // Strafe + backward are left alone.  Runs after the sprint multiplier
    // so neither feature can leak into the other.
    if (self.slide_friction_active && input_movevalues_x > 0)
        input_movevalues_x = 0;

    // --- build movement axes ---
    makevectors(input_angles);
    pm_forward = v_forward;
    pm_right   = v_right;

    // --- shortcut for NONE / SPECTATOR ---
    if (self.pm_movetype == PM_MOVETYPE_NONE)
    {
        PM_CategorizePosition();
        goto done;
    }

    if (self.pm_movetype == PM_MOVETYPE_SPECTATOR)
    {
        PM_SpectatorMove();
        pm_onground = FALSE;
        goto done;
    }

    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
    {
        PM_NoclipMove();
        pm_onground = FALSE;
        goto done;
    }

    // --- general movement ---
    PM_NudgePosition();
    PM_CategorizePosition();

    // cancel water-jump when falling hard or dead
    if (pm_velocity_z < 0 || self.pm_movetype == PM_MOVETYPE_DEAD)
        self.pm_waterjumptime = 0;

    // decrement water-jump timer
    if (self.pm_waterjumptime > 0)
    {
        self.pm_waterjumptime -= pm_frametime;
        if (self.pm_waterjumptime < 0)
            self.pm_waterjumptime = 0;
    }

    // advance jump-msec accumulator (expires after 50 ms)
    if (self.pm_jump_msec)
    {
        self.pm_jump_msec += pm_frametime * 1000;
        if (self.pm_jump_msec > 50)
            self.pm_jump_msec = 0;
    }

    if (self.pm_duck_msec > 0)
    {
        self.pm_duck_msec -= pm_frametime * 1000;
        if (self.pm_duck_msec < 0)
            self.pm_duck_msec = 0;
    }

    if (self.pm_teleport_time > 0)
    {
        self.pm_teleport_time -= pm_frametime;
        if (self.pm_teleport_time < 0)
            self.pm_teleport_time = 0;
    }

    // (sv_jumplag uses pm_jump_lag_end — no decay block, the gate
    // comparison `time < self.pm_jump_lag_end` in PM_CheckJump handles
    // expiry naturally.)

    if (self.pm_ladder_detach_time > 0)
    {
        self.pm_ladder_detach_time -= pm_frametime;
        if (self.pm_ladder_detach_time < 0)
            self.pm_ladder_detach_time = 0;
    }

    if (self.pm_fuser2 > 0)
    {
        self.pm_fuser2 -= pm_frametime * 1000;
        if (self.pm_fuser2 < 0)
            self.pm_fuser2 = 0;
    }

    PM_CheckDuck();
    PM_CheckLadder();

    // check for wall-launched water jump (waist-deep)
    if (pm_waterlevel == 2 && self.pm_movetype != PM_MOVETYPE_FLY)
        PM_CheckWaterJump();

    PM_CheckJump();

    PM_Friction();

    if (pm_on_ladder && pm_waterlevel < 2)
        PM_LadderMove();
    else if (pm_waterlevel >= 2)
        blocked = PM_WaterMove();
    else if (self.pm_movetype == PM_MOVETYPE_FLY)
        blocked = PM_FlyMove();
    else
    {
        blocked = PM_AirMove();

        // Unconditional ground re-snap after horizontal movement, mirroring
        // Source/Momentum Mod's StayOnGround() call from WalkMove. Picks up
        // the cases the inline step-down snaps inside PM_AirMove miss:
        //   - velocity-zero early-return path (line ~1142) — fixes drift
        //     while standing on a 45° slope
        //   - airborne branch entered for one tick while walking down a
        //     slope — fixes stutter on thin downward ramps
        // Gated on was_onground so we don't snap a player who jumped off a
        // ledge mid-tick, and on pm_velocity_z to skip mid-jump cases
        // (matches CategorizePosition's own >180 threshold).
        // Also gated on the groundstick suppress window — a low-impulse
        // punished jump can land just under 180 u/s and would otherwise
        // be re-snapped here before the impulse leaves the floor, and
        // players being actively reeled in by the grapple stay airborne
        // unless they're pressing jump (mirrors the categorize gate).
        float gs_off_stay = (time < self.pm_jump_groundstick_off_until)
                         || (self.grapple_attached
                             && !(input_buttons & PM_BTN_JUMP));
        if (was_onground && pm_velocity_z <= 180 && !gs_off_stay)
            PM_StayOnGround();
    }

    // second categorize for landing detection
    PM_CategorizePosition();

    // Landing spread penalty: just transitioned from airborne to grounded.
    // Smaller than the jump penalty so touchdown doesn't bloom the crosshair
    // as hard — matches the intuition that jumping commits you to a bigger
    // disruption than a controlled landing.
    if (pm_onground && !was_onground)
    {
        self.spread_penalty = SPREAD_PENALTY_LAND;

        // codstamina landing cost: single-tick horizontal velocity cut
        // (replaces the multi-tick pm_fuser2 taper, which is gated off
        // in PM_AirMove when sv_codstamina > 0).  Clear pm_fuser2 so
        // the taper stays suppressed for this jump cycle even if it
        // got re-latched in the air.
        // Crouch-slide bypass: if the player is holding +duck on touchdown
        // with enough horizontal speed to engage the slide, skip the
        // velocity cut and fuser2 stomp — the slide friction system will
        // handle deceleration its own way, and the codstamina punch
        // would steal the slide's starting speed.
        vector land_hvel = pm_velocity; land_hvel_z = 0;
        // Mirror PM_TryEngageSlide's full precondition set so we don't
        // grant a free landing when no slide will actually engage:
        // master toggle, real ducked state (FL_DUCKING — input bit
        // alone may not have flipped it yet on a same-tick land), duck
        // bit, and speed threshold.
        float land_will_slide = PM_ReadMovevar("sv_sliding", 0)
                             && (self.flags & FL_DUCKING)
                             && (input_buttons & PM_BTN_DUCK)
                             && vlen(land_hvel) >= PM_ReadMovevar("sv_sliding_start_speed", 250);
        if (PM_ReadMovevar("sv_codstamina", 0) > 0 && !land_will_slide)
        {
            float lc = PM_ReadMovevar("sv_codstamina_land_cost", 0.15);
            if (lc < 0) lc = 0;
            if (lc > 1) lc = 1;
            pm_velocity_x *= (1 - lc);
            pm_velocity_y *= (1 - lc);
            self.pm_fuser2 = 0;
        }

        // sv_jumplag — stamp the absolute world-time at which the next
        // jump press becomes legal.  PM_CheckJump compares against
        // `time` directly so both CSQC and SSQC agree on the release
        // moment to within network sync, no per-tick decay drift.
        float jl = PM_ReadMovevar("sv_jumplag", 0);
        if (jl > 0)
            self.pm_jump_lag_end = time + jl;
    }

    // ---- Duck-land slide (landing-edge trigger) ----
    // PM_Friction read self.slide_friction_active at the start of this
    // tick, so the friction reduction begins NEXT tick (~1 server frame
    // delay, imperceptible).  The sv_slidingcrouch press-while-fast
    // path runs in PM_CheckDuck — it lifts the player up and clears
    // pm_onground so this same landing-edge handler engages the slide
    // when their feet touch down a moment later.
    if (pm_onground && !was_onground)
        PM_TryEngageSlide();

    // Cancel: speed gate, duck released, left the ground, or master
    // toggle turned off mid-slide.  Each is checked every tick.  The
    // engaged slide sound finishes naturally; we don't cut it short
    // when the friction releases.
    if (self.slide_friction_active)
    {
        vector pm_hvel2 = pm_velocity;
        pm_hvel2_z = 0;
        if (vlen(pm_hvel2) < PM_ReadMovevar("sv_sliding_end_speed", 60)
            || !(input_buttons & PM_BTN_DUCK)
            || !pm_onground
            || !PM_ReadMovevar("sv_sliding", 0))
        {
            self.slide_friction_active = 0;
        }
    }

    // Decay spread penalty over time, quantized to 0.05 steps
    // so client and server converge to the same discrete values
    if (self.spread_penalty > 0)
    {
        self.spread_penalty -= pm_frametime * 4.0;
        if (self.spread_penalty > 0)
            self.spread_penalty = floor(self.spread_penalty * 20) / 20;
        else
            self.spread_penalty = 0;
    }

    // Decay fire spread penalty (sustained fire inaccuracy).
    //
    // Two-component decay:
    //   - linear floor (FIRE_SPREAD_PENALTY_DECAY) — keeps a single-shot
    //     bump finite-time decaying instead of an exponential tail that
    //     never reaches 0.
    //   - proportional accelerator (FIRE_SPREAD_PENALTY_DECAY_K * penalty)
    //     — scales decay with the current penalty so sustained fire
    //     reaches a soft equilibrium below MAX rather than ramping
    //     linearly to the cap and parking there.
    //
    // For 10-shot/sec auto fire (PER_SHOT=3 → +30/sec accumulation), the
    // equilibrium is the penalty value where decay matches accumulation:
    //   30 = DECAY + penalty * DECAY_K
    //   penalty = (30 - DECAY) / DECAY_K = (30 - 2) / 4 = 7.0
    // i.e. spread asymptotes around penalty=7 instead of ramping to
    // MAX=10.  Slower-firing weapons settle even lower.
    if (self.fire_spread_penalty > 0)
    {
        float decay_rate = FIRE_SPREAD_PENALTY_DECAY
                           + self.fire_spread_penalty * FIRE_SPREAD_PENALTY_DECAY_K;
        self.fire_spread_penalty -= pm_frametime * decay_rate;
        if (self.fire_spread_penalty > 0)
            self.fire_spread_penalty = floor(self.fire_spread_penalty * 20) / 20;
        else
            self.fire_spread_penalty = 0;
    }

    // sv_gunkick decay was here — moved out into a per-frame
    // post-fire hook (SH_TickViewKickFrame, called from PlayerPostThink
    // on SSQC and the end of CSQC_PredictPlayer on CSQC). Reason: SSQC
    // calls pmove BEFORE PreThink-fire, while CSQC calls predict-fire
    // BEFORE pmove. With the decay inside pmove, SSQC's trace ran
    // against state that was already advanced by one (vel*dt) decay
    // step while CSQC's trace ran against the un-advanced state — the
    // server's bullet always landed at the peak of the client's
    // visible kick. Putting the decay AFTER fire on both sides keeps
    // the trace state synchronised.

    // ramp landing fix: if we just landed and had significant downward speed
    if (pm_onground && pm_velocity_z < -300)
    {
        dp = pm_velocity * pm_groundnormal;
        if (dp < PM_MAX_JUMPFIX_DP)
            pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);
    }

    // apply any push triggers the player is standing inside
    PM_CheckTriggerPushes();

    // displace by conveyors the player is standing on / inside —
    // runs after the main movement and before teleport so a conveyor
    // that pushes a player into a teleport trigger still triggers it.
    PM_CheckConveyors();

    // Predict the rotating-brush carry pass (CSQC only).  Server runs
    // its authoritative carry from RotDoor_CarryTick at sv_func_tickrate;
    // this client-side mirror keeps predicted_player.origin in lockstep
    // with the visible brush rotation so reconcile error stays at zero
    // and the smoother doesn't fade in a 0.5–1 s tail after the brush
    // stops.  Gated to CSQC to avoid double-applying server-side.
#ifdef CSQC
    PM_CheckRotatingCarry();
#endif
    // PM_CheckMovingPushers runs on BOTH server and client.  Train
    // branch is unconditional (single source on pmove fixes the
    // double-source jitter from server-tick + client-pmove carry);
    // the internal door / button branch is gated CSQC-only to avoid
    // double-applying on top of the server's Mover_TravelTick push.
    PM_CheckMovingPushers();

    // teleport if inside a trigger_teleport volume
    PM_CheckTeleportTriggers();

    // footstep / ladder / water step sounds
    PM_UpdateStepSound();

    // If we're embedded inside another player (e.g. just spawned into a
    // teammate's body, or a head-stand collapsed into overlap), nudge
    // outward so we resolve the overlap in 1–2 frames instead of getting
    // permanently stuck.
    PM_DisentangleFromPlayer();

done:
    // --- write results back to entity ---
    setorigin(self, pm_origin);
    self.velocity = pm_velocity;
    PM_SyncHull();

    if (pm_onground)
        self.flags = self.flags | FL_ONGROUND;
    else
        self.flags = self.flags & ~FL_ONGROUND;

    self.waterlevel = pm_waterlevel;

    // Latch pm_on_ladder onto the entity so post-pmove consumers
    // (Weapon_LowerBlocksFire fire-gate, cl_viewfx.qc lower envelope,
    // anything that doesn't run inside the pmove step) can read it.
    // Set inside the `done:` block so the early-out paths above
    // (nullmove etc.) reach here too and the value stays coherent.
    self.pm_on_ladder_cached = pm_on_ladder;

    // ---- sv_codstamina drain / refill ----
    // Drains during sprint (4.5 s capacity) AND during hold-breath
    // while scoped (8 s).  Refills at 1/3 per sec (3 s full refill)
    // when neither activity is active.  On reaching 0 the punish
    // flag latches; clears once the bar refills past 0.5.
    //   Drain heuristic for COD scope mode is "scout/awp +
    //   sv_codscopes + +attack2 held + +button4 held" — server can't
    //   see the CSQC state machine, but this matches what the player
    //   will be doing visually.  Symmetric on both sides so prediction
    //   tracks.  Disabled entirely when sv_codstamina <= 0.
    //
    // GATE: skip during CSQC reconcile-replay AND the render-rate
    // preview steps (both set pm_suppress_sounds = TRUE).  Without
    // this the CSQC value drains ~4-8× too fast — each replay tick
    // re-drains the same buffered command for the live field, and
    // the preview step on every render frame multiplies the rate
    // again.  Only the live input frame should advance the field;
    // replays read the confirmed state instead.  SSQC has no replay
    // / preview so the flag isn't defined there — gate it out.
    float skip_drain = 0;
#ifdef CSQC
    if (pm_suppress_sounds) skip_drain = 1;
#endif
    if (PM_ReadMovevar("sv_codstamina", 0) <= 0)
    {
        // Feature off — reset the field so the bar reads full and
        // the lockout never triggers.  Idempotent during replays
        // because the value is already 1.  IMPORTANT: this branch is
        // separate from the skip_drain gate so a replay tick doesn't
        // clobber the live value back to 1 every reconcile.
        self.codstamina = 1;
        self.codstamina_punished = 0;
    }
    else if (!skip_drain)
    {
        // Refresh the grounded-time stamp so the sprint drain's
        // grace window survives single-frame FL_ONGROUND drops on
        // clip-brush stairs.  Only stamp during live ticks (the
        // outer !skip_drain gate) — replay would otherwise overwrite
        // the live stamp with a stale buffered-command timestamp.
        if (pm_onground)
            self.pm_last_onground_time = time;
        float grace = PM_ReadMovevar("sv_codstamina_ground_grace", 0.1);
        float grounded_recent = pm_onground
                            || (time - self.pm_last_onground_time) < grace;
        // !codstamina_punished gates BOTH sprint and hold-breath drain
        // so a player whose pool is empty can't keep tapping +button4
        // to delay the refill — the bar must come back before the
        // button does anything (user spec: "let the bar refill before
        // the button can do anything").
        float not_punished = !self.codstamina_punished;
        float st_sprint = (mv_shiftspeed > 1.001)
                       && (input_buttons & PM_BTN_SPRINT)
                       && grounded_recent
                       && input_movevalues_x > 0
                       && !(self.flags & FL_DUCKING)
                       && self.pm_movetype != PM_MOVETYPE_NOCLIP
                       && not_punished;
        // Fire-suppression window (set by SH_StandardTryFire): treat
        // the player as un-scoped while we're inside it.  Otherwise
        // a +attack2-held player firing a shot would keep "scoping"
        // for stamina-drain purposes even though the gun visually
        // dropped out of ADS.
        // Semi-auto snipers (PSG1 / SG550) and the full-auto CFAUG
        // CoD-scope stay visually scoped through fire — cl_codscope.qc
        // exempts them from fire_blocks_ads — so suppressing breath
        // drain here would falsely pause it on every trigger pull
        // (catastrophic for full-auto CFAUG which bumps the timer every
        // shot).  Keep them draining.
        float fire_suppressed = time < self.pm_fire_suppress_until
                             && self.weapon_scope_class != SCOPE_CLASS_SNIPER_SEMI
                             && self.weapon_scope_class != SCOPE_CLASS_RIFLE_LOWPOWER;
        // Cod-scope fallback whitelist mirrors CodScope_Eligible in
        // cl_codscope.qc — the CF* sniper family drives ADS through
        // csqc_codscope_phase, never touches zoomstage, so the
        // zoomstage-only branch above would miss them and stamina
        // would refill while +button4 is held.
        // Legacy zoomstage snipers (e.g. G3SG1) keep draining via the
        // zoomstage>0 clause; CoD-scope weapons via weapon_scope_class.
        float st_scope = !fire_suppressed
                      && ( (self.zoomstage > 0)
                        || (self.weapon_scope_class != SCOPE_CLASS_NONE
                            && PM_ReadMovevar("sv_codscopes", 0)
                            && (input_buttons & 4)) );
        float st_holdbreath = st_scope
                           && (input_buttons & PM_BTN_SPRINT)
                           && !st_sprint
                           && not_punished;
        if (st_sprint)
            self.codstamina -= pm_frametime / 4.5;
        else if (st_holdbreath)
            self.codstamina -= pm_frametime / 8.0;
        else
        {
            // Refill at 1/3 per sec when standing still, half that
            // (1/6 per sec, ~6 s for a full refill) when the player
            // has any movement-intent input down.  Counts as movement:
            //   - WASD / arrows (input_movevalues_x / _y)
            //   - +jump (PM_BTN_JUMP) — user spec: "include holding of
            //     +jump as a movement key"
            // input_movevalues is the engine-normalised intent signal
            // so external pushes (conveyors, jumppads, knockback)
            // don't slow the refill on a stationary player.
            float refill_rate = 1.0 / 3.0;
            if (input_movevalues_x != 0 || input_movevalues_y != 0
                || (input_buttons & PM_BTN_JUMP))
                refill_rate *= 0.5;
            self.codstamina += pm_frametime * refill_rate;
        }
        if (self.codstamina < 0) self.codstamina = 0;
        if (self.codstamina > 1) self.codstamina = 1;
        if (self.codstamina <= 0)
            self.codstamina_punished = 1;
        // Punish clears only when the pool is FULL again — user spec:
        // "stamina bar only needs to refill half way before it becomes
        // white from red, can you make it need to fill up all the
        // way?".  Floor at 0.999 so a single tick's worth of refill
        // overshoot doesn't latch the player out forever.
        if (self.codstamina_punished && self.codstamina >= 0.999)
            self.codstamina_punished = 0;
    }
    // (Removed orphan else — used to reset codstamina=1 when sv_codstamina
    // > 0 AND skip_drain was true.  That ran on every CSQC reconcile-replay
    // tick and clobbered the live drain back to full, which is why the bar
    // never filled / drained on CSQC even though SSQC's value worked.
    // The sv_codstamina<=0 case is handled by the new if-branch above.)
}

// ============================================================================
//  26.  PM_PlayerMove  –  fixed-step wrapper around PM_PlayerMoveStep
// ============================================================================

// Capacity for the noblock stash. 32 = QW MAX_PLAYERS upper bound;
// we never need more than maxclients - 1 entries on either side
// (server: live players minus self; client: each remote slot's engine
// entity + visual proxy). PM_PMOVE_NOBLOCK_STASH_MAX is dimensioned
// generously so a 32-player server fully covers the dual-entity client
// case.
const float PM_PMOVE_NOBLOCK_STASH_MAX = 64;
entity pm_noblock_stash_ent  [PM_PMOVE_NOBLOCK_STASH_MAX];
float  pm_noblock_stash_solid[PM_PMOVE_NOBLOCK_STASH_MAX];
float  pm_noblock_stash_count;
float  pm_noblock_dbg_last;     // rate-limit for [noblock] dprints
// (pm_noblock_active is declared file-scope up near PM_DisentangleFromPlayer —
//  moved there so its earlier users resolve it; fteqcc is top-down on globals.)


// Make every OTHER live player non-solid so PM_PlayerMoveStep's traces
// pass through them. Restored unconditionally in PM_NoblockRestore.
//
// Server-side: the SSQC `player` entity carries the player's authoritative
// hull, so we just walk player_chain_head and stash live ones.
//
// Client-side: the visual proxy is the sole collider per remote player
// (SOLID_BBOX, set by CSQC_PlayerVisual_Update for live remotes).  An
// earlier engine-slot loop ran here too but turned out to be dead code
// in this CSQC mode — edict_num(n) for n=1..maxclients doesn't return
// engine player slots, only CSQC entities that happen to occupy those
// edicts (predicted_player, preview models, etc.).  Removed the
// engine-slot iteration; findchain over the proxy classname catches
// every real remote-player collider.
void() PM_NoblockStash =
{
    pm_noblock_stash_count = 0;

#ifdef SSQC
    entity p = player_chain_head;
    while (p && pm_noblock_stash_count < PM_PMOVE_NOBLOCK_STASH_MAX)
    {
        if (p != self && !p.is_dead && p.solid != SOLID_NOT
            && p.classname == "player")
        {
            pm_noblock_stash_ent  [pm_noblock_stash_count] = p;
            pm_noblock_stash_solid[pm_noblock_stash_count] = p.solid;
            p.solid = SOLID_NOT;
            pm_noblock_stash_count = pm_noblock_stash_count + 1;
        }
        p = p.player_chain_next;
    }
#else
    // CSQC stash: visual proxies ONLY.
    //
    // The earlier engine-slot loop (iterate `edict_num(n)` for n=1..
    // maxclients, stash anything with a player-model prefix) was dead
    // code in this CSQC config — `edict_num(n)` doesn't return engine
    // player slots here (those don't have CSQC edicts at all when the
    // mod renders remote players via player_visual_proxy entities).
    // Live diagnostic confirmed: every iteration returned either
    // predicted_player, a team-select preview model, a viewmodel slot,
    // or null — never a real per-player engine collider.  The proxy
    // IS the only collider for remote players, and the iteration
    // below catches it.
    entity vp = findchain(classname, "player_visual_proxy");
    while (vp && pm_noblock_stash_count < PM_PMOVE_NOBLOCK_STASH_MAX)
    {
        if (vp != self && vp.solid != SOLID_NOT)
        {
            pm_noblock_stash_ent  [pm_noblock_stash_count] = vp;
            pm_noblock_stash_solid[pm_noblock_stash_count] = vp.solid;
            vp.solid = SOLID_NOT;
            pm_noblock_stash_count = pm_noblock_stash_count + 1;
        }
        vp = vp.chain;
    }
#endif
};

void() PM_NoblockRestore =
{
    float i;
    for (i = 0; i < pm_noblock_stash_count; i = i + 1)
    {
        if (pm_noblock_stash_ent[i])
            pm_noblock_stash_ent[i].solid = pm_noblock_stash_solid[i];
        pm_noblock_stash_ent[i] = world;
    }
    pm_noblock_stash_count = 0;
};

void PM_PlayerMove()
{
    float fixedstep;
    float remaining;
    float saved_timelength;
    float noblock_active;

    // ---- func_vehicle driver lock (SERVER-SIDE ONLY) ----
    // While driving, the WASD axes steer the vehicle, NOT the driver's feet.
    // The throttle/steer intent is captured in SV_RunClientCommand (before this
    // runs); here we zero the walk so the driver can't stroll off the deck.
    //
    // CRITICAL: this MUST be server-only.  If the CLIENT also zeroed
    // input_movevalues, its *sent* usercmd would carry 0 movement, so the server
    // would never receive the throttle and the car would never drive (the
    // fwd=0-every-tick freeze).  The client keeps sending real WASD; on a listen
    // host the authoritative lock corrects the predicted walk with ~no latency.
    // (Phase 2 predicts the lock properly for remote drivers.)
#ifdef SSQC
    if (self.pm_driving)
    {
        // Self-heal: never lock a player who has no live .driving link, or this
        // input-zero would freeze them forever.  The cleared flag replicates
        // back via the proxy, recovering from any desync without a reconnect.
        if (self.driving == world)
            self.pm_driving = FALSE;
        else
            input_movevalues = '0 0 0';
    }
#endif

    // Rigid seat-bolt bookkeeping (shared): clear the captured seat offset the
    // moment we stop driving, so the next mount re-captures fresh.  Without this
    // a stale seat from a previous vehicle would teleport the body on remount.
    if (!self.pm_driving)
        self.veh_seat_ofs_set = 0;

    // Use sv_mintic as the physics step size so one cvar controls both
    // FTE's server tick rate and our internal simulation rate.
    // 0.015 = 66.67 Hz (standard CS 1.6), 0.01 = 100 Hz (competitive CS 1.6).
    //
    // Read via PM_ReadMovevar so CSQC pulls the server's pushed value
    // (via serverkey), not the client engine's local sv_mintic which
    // can drift from the server's value at non-default tickrates and
    // produce a different fixedstep iteration count per usercmd.  The
    // mismatch surfaces during jumps at >64 Hz tickrate as visible
    // camera bobbing — gravity accumulates differently between client
    // and server pmove → cl_driftlock fade absorbs the per-tick
    // divergence → fade keeps re-triggering per snapshot.
    fixedstep = PM_ReadMovevar("sv_mintic", 0.01);
    if (fixedstep < 0.001) fixedstep = 0.01;

    saved_timelength = input_timelength;
    remaining = max(self.pm_timecarry + input_timelength, 0);

    // mp_noblock: temporarily desolidify every other live player so the
    // pmove traces in this function (and its substep helpers) pass through
    // them. Restored after the move loop, before the function returns —
    // bullet traces in PreThink see the normal SOLID state again. Sampled
    // once per cmd so toggling the cvar mid-game applies on the next tick;
    // no respawn required.
    //
    // Source differs by VM:
    //   SSQC reads its own cvar() — the server is the authority and the
    //     cvar is registered SV-side via sh_cvar_table.qc.
    //   CSQC reads serverkey() — the cvar isn't registered on CSQC, so
    //     cvar() would return 0 and the client would predict full
    //     collision against other players while the server's trace
    //     passes through, causing visible rubber-banding.  The value
    //     is pushed by sv_main.qc SV_UpdateMovementServerInfo each tick
    //     it changes.
#ifdef SSQC
    noblock_active = cvar("mp_noblock") > 0;
#else
    noblock_active = stof(serverkey("mp_noblock")) > 0;
#endif
    pm_noblock_active = noblock_active;
    if (noblock_active)
        PM_NoblockStash();

    // Diagnostic: rate-limited dprint of noblock state every ~0.5 s so we
    // can confirm CSQC sees the serverinfo push and the stash actually
    // captured remote players.  Toggle via `cl_debug_noblock 1` (CSQC) or
    // `sv_debug_noblock 1` (SSQC).
#ifdef CSQC
    if (cvar("cl_debug_noblock"))
#else
    if (cvar("sv_debug_noblock"))
#endif
    {
        if (time - pm_noblock_dbg_last > 0.5)
        {
            pm_noblock_dbg_last = time;
#ifdef CSQC
            dprint(sprintf("[noblock CSQC] active=%g serverkey='%s' stashed=%g\n",
                noblock_active, serverkey("mp_noblock"), pm_noblock_stash_count));
#else
            dprint(sprintf("[noblock SSQC] active=%g cvar=%g stashed=%g\n",
                noblock_active, cvar("mp_noblock"), pm_noblock_stash_count));
#endif
            // Per-entity dump — confirms BOTH the engine player slot
            // AND the visual proxy are getting stashed on CSQC (or just
            // the player chain entry on SSQC).  If only one shows,
            // either the proxy bbox / classname check is filtering it
            // out or the entity hadn't materialised at stash time.
            float i;
            for (i = 0; i < pm_noblock_stash_count; i = i + 1)
            {
                entity ne = pm_noblock_stash_ent[i];
                if (!ne) continue;
                vector ofs = ne.origin - pm_origin;
                dprint(sprintf("   [%g] cn='%s' entnum=%g ofs='%v' solid_was=%g\n",
                    i, ne.classname, num_for_edict(ne),
                    ofs, pm_noblock_stash_solid[i]));
            }
        }
    }

    while (remaining + PM_FIXEDSTEP_EPSILON >= fixedstep)
    {
        input_timelength = fixedstep;
        PM_PlayerMoveStep();

        remaining -= fixedstep;
        if (remaining < PM_FIXEDSTEP_EPSILON)
        {
            remaining = 0;
            break;
        }
    }

    self.pm_timecarry = remaining;
    input_timelength = saved_timelength;

    if (noblock_active)
        PM_NoblockRestore();

    // Track +attack button state across pmove ticks for semi-auto
    // edge detection.  Lives in bit 0 of pm_oldbuttons (PM_BTN_FIRE)
    // so it rides the existing prediction-proxy sync that already
    // covers pm_oldbuttons for duck-edge tracking.  Read by
    // SH_StandardTryFireSemiAuto in sh_weapon_standard.qc — handguns
    // gate on "fresh press" (held this tick, was NOT held last tick)
    // so holding +attack doesn't auto-empty the mag.
    if (input_buttons & PM_BTN_FIRE)
        self.pm_oldbuttons |= PM_BTN_FIRE;
    else
        self.pm_oldbuttons &= ~PM_BTN_FIRE;
}
