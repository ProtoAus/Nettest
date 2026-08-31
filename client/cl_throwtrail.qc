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

// --- Effect handles ------------------------------------------------------
//
// This started as one hardcoded handle for the thrown-object ribbon.  It now
// carries the SHOT-projectile trails too, because `.traileffectnum` -- which is
// what the RPG rocket and crossbow bolt were using -- does nothing whatsoever on
// a CSQC entity.  It is an entity_state_t field, read only by
// CL_LinkPacketEntities for server-networked packet entities (cl_ents.c:5601);
// CopyCSQCEdictToEntity never looks at it.  Every projectile in this mod is a
// SendEntity projectile, i.e. a CSQC entity on both the networked and the fake
// path, so those assignments were dead code and neither trail ever drew.
// trailparticles() -- this file -- is the mechanism that actually works.
const int TT_FX_THROW  = 0;   // weapons.throwtrail  — thrown/grenade ribbon
const int TT_FX_RPG    = 1;   // weapons.rpg_smoke   — RPG exhaust
const int TT_FX_XBOW   = 2;   // weapons.xbow_tracer — crossbow bolt streak
// The hornet is the ONE projectile in this mod that is a real server-networked
// packet entity (W_HornetSpawn sets no SendEntity, because it homes server-side),
// so it is the one case where .traileffectnum could in principle work.  It does
// not, and the reason is engine-side and unreachable from QC:
//
//   the server's particleeffectnum only RESERVES A NAME (SV_ParticlePrecache_Add);
//   the name list ships to each client at PRESPAWN; the client turns each name
//   into a local index once, there and then, with P_FindParticleType; and that
//   function returns P_INVALID on the FIRST lookup of any name whose config is
//   not currently loaded -- it kicks off P_LoadParticleSet as a side effect and
//   then falls through to the failure return WITHOUT re-searching, and cl_parse.c
//   stores that.  The connect-time particle flush is what leaves the config
//   unloaded at exactly that moment, so the slot is poisoned with P_INVALID for
//   the whole session and CL_LinkPacketEntities silently draws no trail.
//
// It happens before CSQC_Init, so there is no QC hook to re-resolve it -- the
// self-heal in ThrowTrail_Resolve below cannot reach a SERVER-side handle.  The
// fix is therefore to stop using .traileffectnum for the hornet and draw its
// ribbon here, where the handle IS self-healing.  See ThrowTrail_ScanHornets.
const int TT_FX_HORNET_RED    = 3;   // weapons.hornet_trail_red
const int TT_FX_HORNET_ORANGE = 4;   // weapons.hornet_trail_orange
const int TT_FX_COUNT  = 5;

float tt_fx_handle[TT_FX_COUNT];   // lazily resolved; 0 = not looked up yet
float tt_reload_cooldown;          // rate-limit the self-heal namespace reload (cltime)

string(int fxslot) ThrowTrail_FxName =
{
    if (fxslot == TT_FX_RPG)           return "weapons.rpg_smoke";
    if (fxslot == TT_FX_XBOW)          return "weapons.xbow_tracer";
    if (fxslot == TT_FX_HORNET_RED)    return "weapons.hornet_trail_red";
    if (fxslot == TT_FX_HORNET_ORANGE) return "weapons.hornet_trail_orange";
    return "weapons.throwtrail";
};

float(int fxslot) ThrowTrail_Resolve =
{
    float fx = tt_fx_handle[fxslot];
    if (fx == 0)
        fx = particleeffectnum(ThrowTrail_FxName(fxslot));

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
        tt_fx_handle[fxslot] = fx;   // remember it; it goes live after the reload
        return 0;                     // not drawable yet — skip until then
    }

    tt_fx_handle[fxslot] = fx;
    return fx;
};

// Which effect a projectile type trails with, or -1 for none.
//
// The thrown set gets the fat tumbling ribbon.  The two SHOT types get their own
// tighter recipes: an RPG's exhaust is a broad pale plume (HL rpg.cpp:196-227
// draws TE_BEAMFOLLOW with sprites/smoke.spr, life 4.0, rgb 224 224 255), while a
// crossbow bolt just needs enough of a streak to be followable -- HL gives the
// bolt no trail at all, but HL's bolt is a chunky sprite-lit prop and this one is
// a 25 x 3.8 x 1.5 unit sliver crossing a room in about seven frames.
float(float ptype) ThrowTrail_TypeFx =
{
    if (ptype == PROJ_TYPE_HLGRENADE)      return TT_FX_THROW;
    if (ptype == PROJ_TYPE_GRENADE)        return TT_FX_THROW;
    if (ptype == PROJ_TYPE_SNOWBALL)       return TT_FX_THROW;
    if (ptype == PROJ_TYPE_CSHEGRENADE)    return TT_FX_THROW;
    if (ptype == PROJ_TYPE_CSFLASHBANG)    return TT_FX_THROW;
    if (ptype == PROJ_TYPE_CSSMOKEGRENADE) return TT_FX_THROW;
    if (ptype == PROJ_TYPE_RPG_ROCKET)     return TT_FX_RPG;
    if (ptype == PROJ_TYPE_CROSSBOW_BOLT)  return TT_FX_XBOW;
    // The two DoD rockets get the RPG's smoke trail — same thing, a rocket motor
    // burning across a room.  The PIAT gets the THROWN trail instead: it has no
    // motor at all (a spring-launched spigot bomb), so a smoke plume behind it
    // would be inventing an exhaust the weapon does not have.
    if (ptype == PROJ_TYPE_DOD_BAZOOKA)    return TT_FX_RPG;
    if (ptype == PROJ_TYPE_DOD_SCHRECK)    return TT_FX_RPG;
    if (ptype == PROJ_TYPE_DOD_PIAT)       return TT_FX_THROW;
    return -1;
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
// whole accumulated distance.
//
// TT_MIN_SEG must be >= 2 * the LARGEST recipe `step`, not >= the step.  A `type
// beam` node is a vertex, and a quad needs a start AND an end: floor(seglen/step)
// == 1 is exactly as invisible as 0.  The old rule ("keep it >= the recipe step so
// every call lays at least one node") guaranteed one, which is one short, and the
// arithmetic then sorted the effects into working and dead purely by step size:
//
//   throwtrail  step 3 -> floor(6/3) = 2 nodes  -> drew  (grenades, snowball)
//   rpg_smoke   step 4 -> floor(6/4) = 1 node   -> DEAD  (RPG exhaust)
//   xbow_tracer step 6 -> floor(6/6) = 1 node   -> DEAD  (crossbow streak)
//
// All three share this one accumulator, so the LARGEST step sets the floor.
//
// AND NOTE WHAT THIS CONSTANT CANNOT DO.  It buys the second node that makes a
// quad possible; it does not buy COVERAGE.  A type-beam emit spans
// trunc(seglen/step)*step, never seglen, so the fraction of the path actually
// drawn is trunc(seglen/step)*step/seglen and depends only on `step` — raising
// TT_MIN_SEG raises both sides and leaves it unchanged.  That is why the same
// round-1 edit visibly rescued the RPG plume (step 4, ~80% covered, wide and
// long-lived) and did nothing for the crossbow bolt (step 6, ~60% covered with
// 6-unit holes, thin, faint and short-lived).  The bolt was fixed in the RECIPE
// (particles/trails.cfg), not here.
//
// xbow_tracer is now step 2, so rpg_smoke's 4 is the largest and the floor is 8;
// 12 keeps headroom.  Raising any recipe's `step` past 6 without raising this
// silently kills that trail again.
// (Earlier this path still drew nothing only because the effect HANDLE was dead —
// see ThrowTrail_Resolve's body-1 liveness fix; that is now resolved.)
const float TT_MIN_SEG = 12;     // accumulate this far before emitting (>= 2 * recipe step)
const float TT_MAX_SEG = 256;    // teleport/respawn guard — re-anchor, no streak

// Emit the ribbon segment for one projectile (anchor -> current origin).
void(entity p, int slot, float fx) ThrowTrail_Emit =
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
    trailparticles(fx, p, anchor, p.origin);
    tt_last_origin[slot] = p.origin;
};

// The same emit for something that is NOT a QC entity — a server-networked packet
// entity, reachable only through getentity().  `world` is passed as the trail
// entity, which means entnum 0 and therefore a NULL trailstate; that is exactly
// what the CSQC-local fakes already get, and the distance accumulator above is
// what compensates for it in both cases.
void(vector org, int slot, float fx) ThrowTrail_EmitAt =
{
    if (tt_has_last[slot] && cltime - tt_proj_lru[slot] > 0.5)
        tt_has_last[slot] = 0;

    tt_proj_lru[slot] = cltime;

    if (!tt_has_last[slot])
    {
        tt_last_origin[slot] = org;
        tt_has_last[slot]    = 1;
        return;
    }

    vector anchor = tt_last_origin[slot];
    float  dist   = vlen(org - anchor);

    if (dist > TT_MAX_SEG)
    {
        tt_last_origin[slot] = org;
        return;
    }
    if (dist < TT_MIN_SEG)
        return;

    trailparticles(fx, world, anchor, org);
    tt_last_origin[slot] = org;
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

// Walk one classname's entities, trailing every one whose type wants a trail.
// Returns how many eligible ones were alive, which drives the idle poll above.
float(string cname) ThrowTrail_ScanClass =
{
    float live = 0;
    entity p = find(world, classname, cname);
    while (p)
    {
        float fxslot = ThrowTrail_TypeFx(p.csqc_projectile_type);
        if (fxslot >= 0)
        {
            live = live + 1;   // re-derive the live eligible count from reality
            // NOTE: && does NOT short-circuit in QC, so Resolve() is a NESTED
            // `if` and never &&'d with the eligibility test — see the long note
            // in the Tick about poisoning the precache slot with an early lookup.
            float fx = ThrowTrail_Resolve((int)fxslot);
            if (fx != 0)
            {
                int slot = ThrowTrail_SlotFor(num_for_edict(p));
                if (slot >= 0) ThrowTrail_Emit(p, slot, fx);
            }
        }
        p = find(p, classname, cname);
    }
    return live;
};

// --- Hornets ----------------------------------------------------------------
// The hornet is a server-networked PACKET entity, so find() cannot see it: CSQC's
// edict list only contains entities the mod itself spawned or received through
// CSQC_Ent_Update, and W_HornetSpawn deliberately sets no SendEntity because the
// hornet homes server-side.  getentity() is the only way to read one, and
// GE_MAXENTS bounds the scan so this is not a 65k walk.
//
// Colour is INFERRED FROM MEASURED SPEED rather than networked.  The server picks
// red at 600 u/s and orange at 800 (hornet.h via sh_wpn_hlhornetgun.qc), on a
// field CSQC cannot see; but the speed itself is observable from the origin delta
// this function already has to compute for the ribbon.  700 is the midpoint.
float tt_hornet_modelindex;
float tt_hornet_mi_tried;

float() ThrowTrail_ScanHornets =
{
    float live = 0;
    float i, maxents;
    vector org;
    float mi, spd, dist;
    int slot, fxslot;
    float fx;

    // getmodelindex returns 0 until the model is actually precached on this
    // client; re-try until it resolves rather than latching a 0 forever.
    if (!tt_hornet_modelindex)
    {
        tt_hornet_modelindex = getmodelindex("models/hornet.mdl");
        if (!tt_hornet_modelindex)
            return 0;
    }

    // getentity returns __variant, so every read goes through a typed local
    // first — fteqcc will not apply `!` or a comparison to a variant directly.
    float act;

    maxents = getentity(0, GE_MAXENTS);
    for (i = 1; i < maxents; i = i + 1)
    {
        act = getentity(i, GE_ACTIVE);
        if (act == 0)
            continue;
        mi = getentity(i, GE_MODELINDEX);
        if (mi != tt_hornet_modelindex)
            continue;

        org = getentity(i, GE_ORIGIN);
        live = live + 1;

        // Entnums of packet entities and of CSQC edicts share this slot table.
        // They cannot collide in practice (a CSQC-local fake has entnum 0 and is
        // keyed by num_for_edict instead), and a wrong slot only costs one
        // re-anchored segment.
        slot = ThrowTrail_SlotFor(i);
        if (slot < 0)
            continue;

        // Speed from the accumulated delta, before ThrowTrail_EmitAt consumes it.
        fxslot = TT_FX_HORNET_ORANGE;
        if (tt_has_last[slot])
        {
            dist = vlen(org - tt_last_origin[slot]);
            spd  = (frametime > 0) ? dist / frametime : 0;
            if (spd > 0 && spd < 700)
                fxslot = TT_FX_HORNET_RED;
        }

        fx = ThrowTrail_Resolve(fxslot);
        if (fx != 0)
            ThrowTrail_EmitAt(org, slot, fx);
    }
    return live;
};

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
    // see also cfg/default.cfg's header note).  On a listen server the namespace
    // is briefly empty right after the local server spawns the map, so resolving
    // on frame 1 (before any throw) hit that window and killed the trail for the
    // session (it worked on dedicated, where no such reset happens).  Deferring
    // the lookup to the first thrown projectile — well after CSQC_WorldLoaded
    // re-execs the namespace — avoids the poison.  NOTE: && does NOT short-circuit
    // in QC, so Resolve() is a NESTED `if`, never &&'d with the eligibility test.
    // The three classnames that can carry a trail:
    //   csqc_projectile       — the networked twin everyone EXCEPT the shooter sees
    //   csqc_fake_csgrenade   — the CS grenades' owner-side fake
    //   csqc_fake_projectile  — every other weapon's owner-side fake
    // The shooter only ever sees a fake (projectile_SendEntity excludes the owner,
    // sv_weapons.qc:2568), so a trail that is only wired on the networked entity is
    // invisible to the person firing — which is exactly how the RPG's smoke and the
    // crossbow's tracer were reported missing.
    found  = ThrowTrail_ScanClass("csqc_projectile");
    found += ThrowTrail_ScanClass("csqc_fake_csgrenade");
    found += ThrowTrail_ScanClass("csqc_fake_projectile");
    // ...and the hornet, which is not a CSQC edict at all — see the note on
    // TT_FX_HORNET_RED for why its .traileffectnum could never work.
    found += ThrowTrail_ScanHornets();

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
    // Force a fresh effect resolve next map so the handles re-bind against the
    // current namespace (ThrowTrail_Resolve self-heals an unloaded type on its own,
    // but clearing here gives it a clean start across the level boundary).
    for (i = 0; i < TT_FX_COUNT; i = i + 1)
        tt_fx_handle[i] = 0;
    tt_reload_cooldown    = 0;
};
