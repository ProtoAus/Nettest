// ============================================================
//  server/sv_lagcomp.qc  -  Pose + position history ring buffer for
//                           lag compensation.
//
//  Records every alive player's skeletal pose AND origin/angles each
//  server tick.  When a hitscan trace happens, we rewind every other
//  player to their interpolated historical state at the shooter's
//  view-time, run the trace, then restore.
//
//  We DO NOT use FTE's MOVE_LAGGED engine flag.  Reasons, after
//  reading sv_ents.c / sv_user.c / world.c carefully:
//
//    1. No pose / skeletal backdate.  sv_ents.c:1782 stores only
//       origin and angles per snapshot — the FIXME comment there is
//       explicit: `//FIXME: add framestate_t info.`  world.c:2661
//       calls `Event_Backdate` for HITMODEL traces, but that callback
//       is declared in world.h and NEVER ASSIGNED anywhere in the
//       engine, so per-bone hit detection runs against the LIVE pose
//       on a backdated origin — bones drift away from where the
//       shooter aimed, hits go sporadic.
//    2. Snapshot-time rewind, not render-time rewind.  Engine
//       rewinds to `frame->laggedtime` (= sv.time when the snapshot
//       was sent).  The client actually renders other players
//       ~cl_interp_time BEHIND the latest snapshot via interpolation,
//       so a snapshot-time rewind is still ~50–100 ms ahead of what
//       the shooter saw.  Our QC path uses `input_servertime`, which
//       FTE populates per usercmd as the exact view-time the client
//       computed when generating that input — pixel-accurate.
//    3. sv_antilag_frac is server-global (single tunable for the
//       interp blend) and can't be per-client.
//    4. There's a small forward-extrap term in sv_ents.c:1780
//       (origin += velocity * (sv.time - other.localtime)/8) that
//       adds a few units of noise on top of the rewind regardless.
//
//  We replace the engine path entirely with a QC-side rewind that
//  uses one consistent delta (`time - input_servertime`) for pose
//  AND origin, keyed off the shooter's exact visual time.
//
//  128 slots per player @ ~100 Hz covers 1.28 s of history — well
//  over the 350 ms cap on rewind.
// ============================================================

const float LAGCOMP_RING_SIZE   = 128;
const float LAGCOMP_MAX_PLAYERS = 32;
const float LAGCOMP_RING_TOTAL  = 4096;  // MAX_PLAYERS * RING_SIZE

float lagcomp_head[LAGCOMP_MAX_PLAYERS];
float lagcomp_head_time[LAGCOMP_MAX_PLAYERS];
float lagcomp_valid[LAGCOMP_MAX_PLAYERS];  // number of filled slots, capped at RING_SIZE

float lc_time              [LAGCOMP_RING_TOTAL];
float lc_frame             [LAGCOMP_RING_TOTAL];
float lc_frame1time        [LAGCOMP_RING_TOTAL];
float lc_frame2            [LAGCOMP_RING_TOTAL];
float lc_frame2time        [LAGCOMP_RING_TOTAL];
float lc_lerpfrac          [LAGCOMP_RING_TOTAL];
float lc_baseframe         [LAGCOMP_RING_TOTAL];
float lc_baseframe1time    [LAGCOMP_RING_TOTAL];
float lc_baseframe2        [LAGCOMP_RING_TOTAL];
float lc_baseframe2time    [LAGCOMP_RING_TOTAL];
float lc_baselerpfrac      [LAGCOMP_RING_TOTAL];
float lc_subblendfrac      [LAGCOMP_RING_TOTAL];
float lc_subblend2frac     [LAGCOMP_RING_TOTAL];
float lc_basesubblendfrac  [LAGCOMP_RING_TOTAL];
float lc_basesubblend2frac [LAGCOMP_RING_TOTAL];
float lc_bonecontrol1      [LAGCOMP_RING_TOTAL];
float lc_bonecontrol2      [LAGCOMP_RING_TOTAL];
float lc_bonecontrol3      [LAGCOMP_RING_TOTAL];
float lc_bonecontrol4      [LAGCOMP_RING_TOTAL];
float lc_basebone          [LAGCOMP_RING_TOTAL];

// Origin + angles tracked alongside pose so the rewound trace runs
// against the position the shooter saw, not the current server-time
// position.  Without this, hitscan would still need a per-ping lead.
vector lc_origin           [LAGCOMP_RING_TOTAL];
vector lc_angles           [LAGCOMP_RING_TOTAL];

// Bracket outputs (set by Lagcomp_FindBracket, consumed by Lagcomp_RewindPlayer)
float lc_bracket_newer_idx;
float lc_bracket_older_idx;
float lc_bracket_frac;

// Which players have been stashed for the current trace — restored after
entity lc_stashed_list[LAGCOMP_MAX_PLAYERS];
float  lc_stashed_count;

// Current trace's debug level (cached from cvar by Lagcomp_TraceLine so
// inner functions can inspect it without re-reading the cvar each call).
float lc_dbg_level;

void() Lagcomp_Init =
{
    float i;
    for (i = 0; i < LAGCOMP_MAX_PLAYERS; i++)
    {
        lagcomp_head[i] = 0;
        lagcomp_head_time[i] = 0;
        lagcomp_valid[i] = 0;
    }
    lc_stashed_count = 0;
};

void(entity p) Lagcomp_RecordPose =
{
    float pid = num_for_edict(p) - 1;
    if (pid < 0 || pid >= LAGCOMP_MAX_PLAYERS) return;

    float head = (lagcomp_head[pid] + 1) % LAGCOMP_RING_SIZE;
    float idx = pid * LAGCOMP_RING_SIZE + head;

    lc_time[idx]              = time;
    lc_frame[idx]             = p.frame;
    lc_frame1time[idx]        = p.frame1time;
    lc_frame2[idx]            = p.frame2;
    lc_frame2time[idx]        = p.frame2time;
    lc_lerpfrac[idx]          = p.lerpfrac;
    lc_baseframe[idx]         = p.baseframe;
    lc_baseframe1time[idx]    = p.baseframe1time;
    lc_baseframe2[idx]        = p.baseframe2;
    lc_baseframe2time[idx]    = p.baseframe2time;
    lc_baselerpfrac[idx]      = p.baselerpfrac;
    lc_subblendfrac[idx]      = p.subblendfrac;
    lc_subblend2frac[idx]     = p.subblend2frac;
    lc_basesubblendfrac[idx]  = p.basesubblendfrac;
    lc_basesubblend2frac[idx] = p.basesubblend2frac;
    lc_bonecontrol1[idx]      = p.bonecontrol1;
    lc_bonecontrol2[idx]      = p.bonecontrol2;
    lc_bonecontrol3[idx]      = p.bonecontrol3;
    lc_bonecontrol4[idx]      = p.bonecontrol4;
    lc_basebone[idx]          = p.basebone;
    lc_origin[idx]            = p.origin;
    lc_angles[idx]            = p.angles;

    lagcomp_head[pid] = head;
    lagcomp_head_time[pid] = time;
    if (lagcomp_valid[pid] < LAGCOMP_RING_SIZE)
        lagcomp_valid[pid] = lagcomp_valid[pid] + 1;
};

void() Lagcomp_RecordAllAlive =
{
    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.classname == "player")
            Lagcomp_RecordPose(p);
        p = p.player_chain_next;
    }
};

// Find (newer, older) pair bracketing target time t in player pid's ring.
// Writes lc_bracket_newer_idx, lc_bracket_older_idx, lc_bracket_frac (0 at newer).
// Returns 1 on success (even if clamped to one end), 0 only if ring is empty.
float(float pid, float t) Lagcomp_FindBracket =
{
    float valid = lagcomp_valid[pid];
    if (valid < 1) return 0;

    float head = lagcomp_head[pid];
    float head_flat = pid * LAGCOMP_RING_SIZE + head;

    // Newer than newest → use newest slot
    if (t >= lc_time[head_flat])
    {
        lc_bracket_newer_idx = head_flat;
        lc_bracket_older_idx = head_flat;
        lc_bracket_frac = 0;
        return 1;
    }

    // Walk back from head looking for bracket
    float newer = head;
    float steps = valid - 1;
    float i;
    for (i = 0; i < steps; i++)
    {
        float older = (newer - 1 + LAGCOMP_RING_SIZE) % LAGCOMP_RING_SIZE;
        float newer_flat = pid * LAGCOMP_RING_SIZE + newer;
        float older_flat = pid * LAGCOMP_RING_SIZE + older;
        float tn = lc_time[newer_flat];
        float to = lc_time[older_flat];

        if (to <= t && t <= tn)
        {
            lc_bracket_newer_idx = newer_flat;
            lc_bracket_older_idx = older_flat;
            float span = tn - to;
            lc_bracket_frac = (span > 0) ? (tn - t) / span : 0;
            return 1;
        }
        newer = older;
    }

    // Older than oldest → clamp to oldest
    lc_bracket_newer_idx = pid * LAGCOMP_RING_SIZE + newer;
    lc_bracket_older_idx = lc_bracket_newer_idx;
    lc_bracket_frac = 0;
    return 1;
};

void(entity p, float rewind_seconds) Lagcomp_RewindPlayer =
{
    float pid = num_for_edict(p) - 1;
    if (pid < 0 || pid >= LAGCOMP_MAX_PLAYERS) return;
    if (p.lc_stashed) return;  // already rewound in this trace

    float target_time = time - rewind_seconds;
    if (!Lagcomp_FindBracket(pid, target_time))
    {
        if (lc_dbg_level >= 2)
            dprint(sprintf("  [lagcomp] pid=%g EMPTY RING — no rewind applied\n", pid));
        return;
    }

    float a = lc_bracket_newer_idx;
    float b = lc_bracket_older_idx;
    float f = lc_bracket_frac;

    if (lc_dbg_level >= 2)
    {
        // Ring indices relative to ring start, not flat, for readability
        float a_slot = a - pid * LAGCOMP_RING_SIZE;
        float b_slot = b - pid * LAGCOMP_RING_SIZE;
        float newer_age_ms = (time - lc_time[a]) * 1000;
        float older_age_ms = (time - lc_time[b]) * 1000;
        dprint(sprintf("  [lagcomp] pid=%g  newer=slot%g(%.1fms ago)  older=slot%g(%.1fms ago)  frac=%.3f\n",
            pid, a_slot, newer_age_ms, b_slot, older_age_ms, f));
    }

    // Stash current pose + position
    p.lc_stash_frame             = p.frame;
    p.lc_stash_frame1time        = p.frame1time;
    p.lc_stash_frame2            = p.frame2;
    p.lc_stash_frame2time        = p.frame2time;
    p.lc_stash_lerpfrac          = p.lerpfrac;
    p.lc_stash_baseframe         = p.baseframe;
    p.lc_stash_baseframe1time    = p.baseframe1time;
    p.lc_stash_baseframe2        = p.baseframe2;
    p.lc_stash_baseframe2time    = p.baseframe2time;
    p.lc_stash_baselerpfrac      = p.baselerpfrac;
    p.lc_stash_subblendfrac      = p.subblendfrac;
    p.lc_stash_subblend2frac     = p.subblend2frac;
    p.lc_stash_basesubblendfrac  = p.basesubblendfrac;
    p.lc_stash_basesubblend2frac = p.basesubblend2frac;
    p.lc_stash_bonecontrol1      = p.bonecontrol1;
    p.lc_stash_bonecontrol2      = p.bonecontrol2;
    p.lc_stash_bonecontrol3      = p.bonecontrol3;
    p.lc_stash_bonecontrol4      = p.bonecontrol4;
    p.lc_stash_basebone          = p.basebone;
    p.lc_stash_origin            = p.origin;
    p.lc_stash_angles            = p.angles;
    p.lc_stashed = 1;

    // Apply rewound pose. Discrete fields (animation frame indices, basebone)
    // take the newer slot — they don't interpolate. Continuous fields lerp.
    p.frame             = lc_frame[a];
    p.frame2            = lc_frame2[a];
    p.baseframe         = lc_baseframe[a];
    p.baseframe2        = lc_baseframe2[a];
    p.basebone          = lc_basebone[a];

    p.frame1time        = lc_frame1time[a]        + (lc_frame1time[b]        - lc_frame1time[a])        * f;
    p.frame2time        = lc_frame2time[a]        + (lc_frame2time[b]        - lc_frame2time[a])        * f;
    p.lerpfrac          = lc_lerpfrac[a]          + (lc_lerpfrac[b]          - lc_lerpfrac[a])          * f;
    p.baseframe1time    = lc_baseframe1time[a]    + (lc_baseframe1time[b]    - lc_baseframe1time[a])    * f;
    p.baseframe2time    = lc_baseframe2time[a]    + (lc_baseframe2time[b]    - lc_baseframe2time[a])    * f;
    p.baselerpfrac      = lc_baselerpfrac[a]      + (lc_baselerpfrac[b]      - lc_baselerpfrac[a])      * f;
    p.subblendfrac      = lc_subblendfrac[a]      + (lc_subblendfrac[b]      - lc_subblendfrac[a])      * f;
    p.subblend2frac     = lc_subblend2frac[a]     + (lc_subblend2frac[b]     - lc_subblend2frac[a])     * f;
    p.basesubblendfrac  = lc_basesubblendfrac[a]  + (lc_basesubblendfrac[b]  - lc_basesubblendfrac[a])  * f;
    p.basesubblend2frac = lc_basesubblend2frac[a] + (lc_basesubblend2frac[b] - lc_basesubblend2frac[a]) * f;
    p.bonecontrol1      = lc_bonecontrol1[a]      + (lc_bonecontrol1[b]      - lc_bonecontrol1[a])      * f;
    p.bonecontrol2      = lc_bonecontrol2[a]      + (lc_bonecontrol2[b]      - lc_bonecontrol2[a])      * f;
    p.bonecontrol3      = lc_bonecontrol3[a]      + (lc_bonecontrol3[b]      - lc_bonecontrol3[a])      * f;
    p.bonecontrol4      = lc_bonecontrol4[a]      + (lc_bonecontrol4[b]      - lc_bonecontrol4[a])      * f;

    // Origin lerps linearly — short windows (≤350 ms) won't be visibly
    // distorted by linear interp even on curved jumps.  setorigin is
    // mandatory: bare `p.origin = ...` leaves the entity's BSP link
    // stale and the trace would still hit the current-frame bbox.
    vector new_origin = lc_origin[a] + (lc_origin[b] - lc_origin[a]) * f;
    setorigin(p, new_origin);

    // Angles use short-arc lerp on the yaw component — wrapping around
    // ±180° avoids the rare case where a player snap-rotates from -179°
    // to +179° between samples and the linear lerp swings them through
    // 0°.  Pitch and roll wrap rarely so are fine to lerp linearly.
    vector ang_a = lc_angles[a];
    vector ang_b = lc_angles[b];
    float dyaw = ang_b_y - ang_a_y;
    if (dyaw >  180) dyaw -= 360;
    if (dyaw < -180) dyaw += 360;
    p.angles_x = ang_a_x + (ang_b_x - ang_a_x) * f;
    p.angles_y = ang_a_y + dyaw            * f;
    p.angles_z = ang_a_z + (ang_b_z - ang_a_z) * f;

    if (lc_stashed_count < LAGCOMP_MAX_PLAYERS)
    {
        lc_stashed_list[lc_stashed_count] = p;
        lc_stashed_count = lc_stashed_count + 1;
    }
};

void(entity p) Lagcomp_RestorePlayer =
{
    if (!p.lc_stashed) return;
    p.frame             = p.lc_stash_frame;
    p.frame1time        = p.lc_stash_frame1time;
    p.frame2            = p.lc_stash_frame2;
    p.frame2time        = p.lc_stash_frame2time;
    p.lerpfrac          = p.lc_stash_lerpfrac;
    p.baseframe         = p.lc_stash_baseframe;
    p.baseframe1time    = p.lc_stash_baseframe1time;
    p.baseframe2        = p.lc_stash_baseframe2;
    p.baseframe2time    = p.lc_stash_baseframe2time;
    p.baselerpfrac      = p.lc_stash_baselerpfrac;
    p.subblendfrac      = p.lc_stash_subblendfrac;
    p.subblend2frac     = p.lc_stash_subblend2frac;
    p.basesubblendfrac  = p.lc_stash_basesubblendfrac;
    p.basesubblend2frac = p.lc_stash_basesubblend2frac;
    p.bonecontrol1      = p.lc_stash_bonecontrol1;
    p.bonecontrol2      = p.lc_stash_bonecontrol2;
    p.bonecontrol3      = p.lc_stash_bonecontrol3;
    p.bonecontrol4      = p.lc_stash_bonecontrol4;
    p.basebone          = p.lc_stash_basebone;
    setorigin(p, p.lc_stash_origin);
    p.angles            = p.lc_stash_angles;
    p.lc_stashed = 0;
};

void(float rewind_seconds) Lagcomp_RewindAllPlayers =
{
    lc_stashed_count = 0;
    entity p = player_chain_head;
    while (p)
    {
        // Skip dead players and the attacker themselves — attacker's own
        // hitbox is never the target of their own shot.
        if (!p.is_dead && p.classname == "player" && p != self)
            Lagcomp_RewindPlayer(p, rewind_seconds);
        p = p.player_chain_next;
    }
};

void() Lagcomp_RestoreAllPlayers =
{
    float i;
    for (i = 0; i < lc_stashed_count; i++)
    {
        entity p = lc_stashed_list[i];
        if (p)
            Lagcomp_RestorePlayer(p);
        lc_stashed_list[i] = world;
    }
    lc_stashed_count = 0;
};

// Compute rewind window in seconds for an attacker.
//
// Preferred: FTE engine populates `input_servertime` per usercmd with the
// EXACT server-time the client's interp state was anchored to when the
// input was generated (set in fteqw/engine/server/pr_cmds.c at SV_RunCmd).
// Rewinding to that time lands every player exactly where the shooter
// saw them — independent of ping jitter, cl_interp_time, or cl_extrap.
//
// Fallback (input_servertime == 0): a ping-based estimate, kept as a
// safety net for the rare frames where the engine hasn't populated the
// global yet (very early in a connection, or non-cmd-driven traces).
// Uses FULL round-trip ping (ping_ms * 0.001) plus cl_interp_time,
// because the trace runs at the server's current clock — one full
// transit AFTER the client sent the shot — so the visual is
// (ping/2 transit) + (ping/2 transit back) + interp behind. The
// previous half-ping formula was systematically short by ping/2,
// which manifested as "needing to lead" for high-ping shooters.
float(entity attacker) Lagcomp_GetRewindSeconds =
{
    if (!attacker) return 0;

    float client_view_time = input_servertime;
    float rewind;

    if (client_view_time > 0)
    {
        rewind = time - client_view_time;
    }
    else
    {
        float ping_ms = stof(infokey(attacker, "ping"));
        float client_interp = stof(infokey(attacker, "cl_interp_time"));
        if (client_interp < 0) client_interp = 0;
        if (client_interp > 0.2) client_interp = 0.2;  // sanity cap
        rewind = ping_ms * 0.001 + client_interp;      // full RTT
    }

    float cap = cvar("sv_lagcomp_maxrewind");
    if (cap <= 0) cap = 0.5;
    return bound(0, rewind, cap);
};

// Returns the effective on/off state, defaulting to ON when unset.
float() Lagcomp_Enabled =
{
    if (cvar_string("sv_lagcomp") == "") return 1;
    return cvar("sv_lagcomp");
};

// State so Begin/End can be paired across an arbitrary block of code
// (the weapon path needs to read trace_ent.origin for debug emit while
// players are still rewound).  rewind_active = 1 between Begin and End.
float lc_rewind_active;

// Begin a rewound window: rewind every other player's pose + origin
// to the attacker's view-time (`time - input_servertime`).  Pair with
// Lagcomp_EndRewind.  Calls between Begin/End see players in their
// historical state — tracelines, bbox queries, anything reading
// .origin / .frame / etc. observe the rewound values.
//
// `self` MUST be the attacker on entry (standard for weapon code).
void(entity attacker) Lagcomp_BeginRewind =
{
    lc_rewind_active = 0;

    if (!Lagcomp_Enabled())
        return;

    float rewind = Lagcomp_GetRewindSeconds(attacker);
    if (rewind <= 0)
        return;

    lc_dbg_level = cvar("sv_debug_lagcomp");

    if (lc_dbg_level >= 1)
    {
        float ping_ms = stof(infokey(attacker, "ping"));
        dprint(sprintf("[lagcomp] attacker=%s ping=%.0fms rewind=%.1fms\n",
            attacker.netname, ping_ms, rewind * 1000));
    }

    Lagcomp_RewindAllPlayers(rewind);
    lc_rewind_active = 1;
};

void() Lagcomp_EndRewind =
{
    if (lc_rewind_active && lc_dbg_level >= 1)
    {
        // Trace globals from the most recent traceline inside the
        // window — these are still set when a weapon path calls End
        // immediately after the trace.  Useful for confirming the hit
        // landed on the rewound entity.
        string hit_desc;
        if (trace_fraction >= 1.0)
            hit_desc = "miss";
        else if (trace_ent && trace_ent.classname == "player")
            hit_desc = sprintf("HIT player %s", trace_ent.netname);
        else if (trace_ent)
            hit_desc = sprintf("hit %s", trace_ent.classname);
        else
            hit_desc = "hit world";
        dprint(sprintf("[lagcomp] rewound=%g player(s)  frac=%.3f  %s\n",
            lc_stashed_count, trace_fraction, hit_desc));
    }

    Lagcomp_RestoreAllPlayers();
    lc_dbg_level = 0;
    lc_rewind_active = 0;
};

// Convenience wrapper for callers that just want a one-shot rewound
// trace and don't need to read entity state inside the window.
// `self` must be the attacker.
void(vector src, vector end, float moveflags, entity ignore) Lagcomp_TraceLine =
{
    Lagcomp_BeginRewind(self);
    traceline(src, end, moveflags, ignore);
    Lagcomp_EndRewind();
};
