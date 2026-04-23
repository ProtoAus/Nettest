// ============================================================
//  server/sv_lagcomp.qc  -  Pose history ring buffer for lag compensation
//
//  Complements FTE's MOVE_LAGGED engine flag, which only rewinds origin
//  and angles (see fteqw/engine/common/world.h:178-183). HLMDL skeletal
//  animation also needs frame/baseframe/frame1time/subblendfrac/bonecontrol
//  etc. to hit-register correctly; those we rewind here in QC.
//
//  128 slots per player @ 100 tick covers 1.28 s of history, well over
//  the 350 ms target ping. Hitscan wrappers call Lagcomp_TraceLine, which
//  swaps each player to their interpolated historical pose, performs the
//  trace, then restores. The engine's MOVE_LAGGED flag still handles
//  origin/angles rewind in parallel (no double-rewind — we don't touch
//  those fields).
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

    // Stash current pose
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

// Compute rewind window in seconds for an attacker based on reported ping
// plus the attacker's reported cl_interp_time. Without the interp offset,
// a shooter running cl_interp_time 0.031 at 200 ms ping sees the target
// 231 ms behind the server's current state but the server rewinds only
// 100 ms — the 131 ms gap manifests as phantom misses on moving targets.
// The client pushes cl_interp_time as userinfo (see CSQC_PushInterpUserInfo
// in cl_player.qc); we read it here and fold it into the rewind window,
// still bounded by sv_lagcomp_maxrewind to prevent ping-inflation exploits.
float(entity attacker) Lagcomp_GetRewindSeconds =
{
    if (!attacker) return 0;
    float ping_ms = stof(infokey(attacker, "ping"));
    float client_interp = stof(infokey(attacker, "cl_interp_time"));
    if (client_interp < 0) client_interp = 0;
    if (client_interp > 0.2) client_interp = 0.2;  // sanity cap

    float rewind = ping_ms * 0.0005 + client_interp;
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

// Drop-in replacement for traceline() that rewinds player poses to the
// attacker's perceived time before the trace, then restores. `self` must
// be set to the attacker (standard for weapon code).
void(vector src, vector end, float moveflags, entity ignore) Lagcomp_TraceLine =
{
    if (!Lagcomp_Enabled())
    {
        traceline(src, end, moveflags, ignore);
        return;
    }

    float rewind = Lagcomp_GetRewindSeconds(self);
    if (rewind <= 0)
    {
        traceline(src, end, moveflags, ignore);
        return;
    }

    lc_dbg_level = cvar("sv_debug_lagcomp");

    if (lc_dbg_level >= 1)
    {
        float ping_ms = stof(infokey(self, "ping"));
        dprint(sprintf("[lagcomp] attacker=%s ping=%.0fms rewind=%.1fms\n",
            self.netname, ping_ms, rewind * 1000));
    }

    Lagcomp_RewindAllPlayers(rewind);
    traceline(src, end, moveflags, ignore);

    if (lc_dbg_level >= 1)
    {
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
};
