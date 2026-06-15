// ============================================================
//  client/cl_throwtrail.qc  -  Particle trail behind thrown
//  projectiles (snowballs + grenades).
//
//  Each eligible projectile lays down a `type beam` particle RIBBON along
//  the path it travelled: ThrowTrail_Emit calls trailparticles() from the
//  stored anchor to the current origin once the projectile has moved at
//  least TT_MIN_SEG, and the engine connects the beam nodes into a
//  continuous textured ribbon that follows the arc.  This replaced an older
//  system that rebuilt the ribbon out of a per-projectile ring of sampled
//  origins via R_BeginPolygon every frame — same ribbon look, but carried
//  C-side by the engine particle simulator (no per-frame QC quads).
//
//  Tune the look in particles/weapons.cfg -> r_part throwtrail
//  (reloaddebris).  cl_throwtrail 0/1 still toggles it.
// ============================================================

const int TT_PROJ_MAX = 32;          // max simultaneously-tracked projectiles

// Per-slot state.  Slot is keyed by projectile entnum.
float  tt_proj_entnum [TT_PROJ_MAX];  // 0 = free
vector tt_last_origin [TT_PROJ_MAX];  // last origin we trailed FROM
float  tt_has_last    [TT_PROJ_MAX];  // 1 once tt_last_origin is valid
float  tt_proj_lru    [TT_PROJ_MAX];  // cltime of last write — LRU + stale detection

// Lazy-resolved weapons.throwtrail handle (weapons.cfg can load after CSQC init).
float pe_weapons_throwtrail;
float tt_reload_cooldown;     // rate-limit the self-heal namespace reload (cltime)

float() ThrowTrail_Resolve =
{
    float fx = pe_weapons_throwtrail;
    if (fx == 0)
        fx = particleeffectnum("weapons.throwtrail");

    // LIVENESS CHECK — query BODY (arg 1), not the name (arg 0).
    // PScript_Query (engine p_script.c): body=0 returns "config.name" and succeeds
    // even when the type is NOT loaded; body=1 returns an EMPTY string when the type
    // is unloaded.  So body=0 can't tell a dead handle from a live one — that was the
    // bug (we cached a -N whose particle type had been unloaded by the connect-time
    // particle flush, and pointparticles silently drew nothing for the session).
    if (fx != 0 && particleeffectquery(fx, 1) == "")
    {
        // The handle exists but its type is unloaded.  Re-exec the namespace to
        // reload it IN PLACE — the engine reuses the same part_type slot by name
        // (P_GetParticleType), so the existing handle REVIVES once reloaded.  Rate-
        // limited so a genuinely-missing recipe can't spam execs every frame.
        if (cltime >= tt_reload_cooldown)
        {
            tt_reload_cooldown = cltime + 1;
            localcmd("r_part namespace weapons 1\nexec particles/weapons.cfg\nr_part namespace \"\" 0\n");
        }
        pe_weapons_throwtrail = fx;   // remember it; it goes live after the reload
        return 0;                      // not drawable yet — skip until then
    }

    pe_weapons_throwtrail = fx;
    return fx;
};

// Eligibility — which projectile types get a trail.  Thrown / grenade-shaped
// only (crossbow bolts / RPGs / paintballs are shot, not thrown).
float(float ptype) ThrowTrail_TypeEligible =
{
    if (ptype == PROJ_TYPE_HLGRENADE)      return 1;
    if (ptype == PROJ_TYPE_GRENADE)        return 1;
    if (ptype == PROJ_TYPE_SNOWBALL)       return 1;
    if (ptype == PROJ_TYPE_CSHEGRENADE)    return 1;
    if (ptype == PROJ_TYPE_CSFLASHBANG)    return 1;
    if (ptype == PROJ_TYPE_CSSMOKEGRENADE) return 1;
    return 0;
};

// Find the slot for entnum, or allocate a free / LRU one.  Fresh slots start
// with no last-origin so the first frame just seeds it (no chest->throw segment).
int(float entnum) ThrowTrail_SlotFor =
{
    if (entnum <= 0) return -1;

    int i;
    int free_slot = -1;
    int lru_slot  = 0;
    float lru_t   = tt_proj_lru[0];
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        if (tt_proj_entnum[i] == entnum)
            return i;
        if (tt_proj_entnum[i] == 0 && free_slot < 0)
            free_slot = i;
        if (tt_proj_lru[i] < lru_t)
        {
            lru_slot = i;
            lru_t    = tt_proj_lru[i];
        }
    }
    int s = (free_slot >= 0) ? free_slot : lru_slot;
    tt_proj_entnum[s] = entnum;
    tt_has_last[s]    = 0;
    tt_proj_lru[s]    = cltime;
    return s;
};

// Public — called from CSQC_Ent_Remove when a projectile disappears.  Releases
// the slot so a reused entnum doesn't inherit a stale trail anchor.
void(float entnum) ThrowTrail_OnProjectileRemove =
{
    if (entnum <= 0) return;
    int i;
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        if (tt_proj_entnum[i] == entnum)
        {
            tt_proj_entnum[i] = 0;
            tt_has_last[i]    = 0;
            return;
        }
    }
};

// The trail is a `type beam` RIBBON (weapons.throwtrail): trailparticles() lays
// beam nodes from the anchor to the current origin and connects them into a
// continuous textured ribbon that follows the projectile's arc.  A beam needs a
// start AND end to orient its width, so this MUST be trailparticles() (a point
// emit can't make a ribbon).
//
// The historical gotcha with trailparticles() here: it spawns floor(seglen/step)
// nodes, and at 300-1000 fps a per-frame move is ~1-3 qu — under the recipe step —
// so a naive per-frame call floors to ZERO and draws nothing (local CSQC fakes
// have entnum 0 -> NULL trailstate -> no cross-frame accumulator to save them).
// We fix that here with a QC distance accumulator: hold the anchor still until the
// projectile has travelled >= TT_MIN_SEG, then emit one beam segment spanning the
// whole accumulated distance.  Keep TT_MIN_SEG >= the recipe `step` so every call
// lays at least one node.  (Earlier this path still drew nothing only because the
// effect HANDLE was dead — see ThrowTrail_Resolve's body-1 liveness fix; that is
// now resolved, so the beam renders.)
const float TT_MIN_SEG = 6;      // accumulate this far before emitting (>= recipe step)
const float TT_MAX_SEG = 256;    // teleport/respawn guard — re-anchor, no streak

// Emit the ribbon segment for one projectile (anchor -> current origin).
void(entity p, int slot) ThrowTrail_Emit =
{
    // Stale-slot guard: a reused entnum (no CSQC_Ent_Remove) leaves a slot anchored
    // at the previous projectile's last origin.  If untouched >0.5s, restart from
    // the current origin so we don't draw a beam across the gap.
    if (tt_has_last[slot] && cltime - tt_proj_lru[slot] > 0.5)
        tt_has_last[slot] = 0;

    tt_proj_lru[slot] = cltime;

    if (!tt_has_last[slot])
    {
        // Seed the anchor; no ribbon on the first frame.
        tt_last_origin[slot] = p.origin;
        tt_has_last[slot]    = 1;
        return;
    }

    vector anchor = tt_last_origin[slot];
    vector seg    = p.origin - anchor;
    float  dist   = vlen(seg);

    if (dist > TT_MAX_SEG)
    {
        // Origin jumped (respawn / smoothing snap) — re-anchor without a streak.
        tt_last_origin[slot] = p.origin;
        return;
    }
    if (dist < TT_MIN_SEG)
        return;                 // not far enough yet — let distance accumulate

    // Lay a beam ribbon segment over the accumulated path.  Consecutive segments
    // share the anchor point (= previous current), so the ribbon is continuous.
    trailparticles(pe_weapons_throwtrail, p, anchor, p.origin);
    tt_last_origin[slot] = p.origin;
};

// Idle-scan throttle.  The Tick used to walk the WHOLE edict list TWICE every
// render frame (two find() loops) even with zero grenades airborne — pure waste
// at uncapped fps (the LMG-spray profile had no thrown projectiles yet still paid
// it).  While eligible projectiles exist (tt_live_count > 0, re-derived from the
// scan each frame) we keep scanning every frame so trails stay smooth.  When none
// exist we drop to a low-rate poll.  Self-healing: the count comes from reality
// each scan so it can never drift into a stuck state, and a brand-new grenade
// starts its trail within one poll interval (~16ms; the first emit only seeds the
// anchor with no ribbon anyway, so the visible start is unaffected).
float tt_live_count;
float tt_next_idle_scan;
const float TT_IDLE_POLL_HZ = 60;

// Per-frame entry point — called from CSQC_UpdateView alongside the other FX ticks.
void() CSQC_ThrowTrail_Tick =
{
    if (cvar("cl_throwtrail") <= 0) return;

    // Idle early-out: nothing eligible was alive at the last scan and the poll
    // interval hasn't elapsed → skip the two full-edict find() walks.
    if (tt_live_count <= 0 && cltime < tt_next_idle_scan)
        return;
    tt_next_idle_scan = cltime + 1.0 / TT_IDLE_POLL_HZ;
    float found = 0;

    // Resolve the effect LAZILY — only once an eligible projectile actually
    // exists, NOT unconditionally every frame.  particleeffectnum() permanently
    // poisons its precache slot with P_INVALID if the "weapons" namespace isn't
    // loaded at the moment of the FIRST lookup (engine pr_csqc.c ~3769: the
    // validity guard is commented out, so a miss is cached for the whole session;
    // see also data/default.cfg's header note).  On a listen server the namespace
    // is briefly empty right after the local server spawns the map, so resolving
    // on frame 1 (before any throw) hit that window and killed the trail for the
    // session (it worked on dedicated, where no such reset happens).  Deferring
    // the lookup to the first thrown projectile — well after CSQC_WorldLoaded
    // re-execs the namespace — avoids the poison.  NOTE: && does NOT short-circuit
    // in QC, so Resolve() is a NESTED `if`, never &&'d with the eligibility test.
    int slot;
    entity p;

    p = find(world, classname, "csqc_projectile");
    while (p)
    {
        if (ThrowTrail_TypeEligible(p.csqc_projectile_type))
        {
            found = found + 1;   // re-derive the live eligible count from reality
            if (ThrowTrail_Resolve() != 0)
            {
                slot = ThrowTrail_SlotFor(num_for_edict(p));
                if (slot >= 0) ThrowTrail_Emit(p, slot);
            }
        }
        p = find(p, classname, "csqc_projectile");
    }
    // Owner-side CSQC fakes for CS-style grenades (tagged with the matching type).
    p = find(world, classname, "csqc_fake_csgrenade");
    while (p)
    {
        if (ThrowTrail_TypeEligible(p.csqc_projectile_type))
        {
            found = found + 1;
            if (ThrowTrail_Resolve() != 0)
            {
                slot = ThrowTrail_SlotFor(num_for_edict(p));
                if (slot >= 0) ThrowTrail_Emit(p, slot);
            }
        }
        p = find(p, classname, "csqc_fake_csgrenade");
    }

    tt_live_count = found;   // 0 → next frames idle-poll; >0 → scan every frame
};

// Map-change reset — clears all slots so trails don't carry across maps.
void() CSQC_ThrowTrail_Clear =
{
    int i;
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        tt_proj_entnum[i] = 0;
        tt_has_last[i]    = 0;
        tt_proj_lru[i]    = 0;
    }
    // Force a fresh effect resolve next map so the handle re-binds against the
    // current namespace (ThrowTrail_Resolve self-heals an unloaded type on its own,
    // but clearing here gives it a clean start across the level boundary).
    pe_weapons_throwtrail = 0;
    tt_reload_cooldown    = 0;
};
