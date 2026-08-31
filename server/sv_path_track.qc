//
// sv_path_track.qc — HL/GoldSrc path_track point entity
//
// Same shape as path_corner, but used by func_tracktrain (which walks
// path_track chains) rather than func_train (which walks path_corner chains).
// Spawnflag bit layout differs from path_corner so the entities aren't
// interchangeable at the wire level.
//
// THIS FILE USED TO BE A PURE DATA STUB — it set MOVETYPE_NONE / SOLID_NOT and
// returned, and every semantic lived in func_tracktrain, which chased the chain
// with a forward-only `find(world, targetname, ...)`.  That was enough to drive
// a train forwards and nothing else.  It is now HL's actual path graph, ported
// from dlls/pathcorner.cpp, because three separate defects all reduced to not
// having one:
//
//   - REVERSE.  A player-driven tracktrain runs on a SIGNED speed and walks
//     GetPrevious() when it is negative (plats.cpp:1187 feeding LookAhead).
//     With no back-links there was no reverse, so there could be no driving.
//   - CONTINUOUS MOTION.  HL never stops at a node; it asks "where am I
//     `speed * dt` further along the polyline?" and sets velocity to get there.
//     The old node-to-node walk had to TELEPORT onto each node it reached,
//     which is what slid riders off the train (see sv_func_tracktrain.qc).
//   - DISABLED / ALTERNATE nodes.  PT_DISABLED was declared and filtered
//     nowhere, so sv_th_entities.qc's func_trackchange could flip the bit with
//     no effect (its own comment says so).  ValidPath() below is the filter.
//
// Compile order: this file is sv_progs.src:184, ahead of sv_func_train.qc :187
// and sv_func_tracktrain.qc :188, so the walker and the PT_* constants are
// defined here and simply referenced there.
//

// ---------------------------------------------------------------------------
// path_track spawnflags — HL dlls/trains.h:24-29.
//
// Canonical definitions.  They used to be duplicated at the top of
// sv_func_tracktrain.qc; that copy is gone, this is the one.
// ---------------------------------------------------------------------------
const float PT_DISABLED       = 1;
const float PT_FIRE_ONCE      = 2;
const float PT_BRANCH_REVERSE = 4;      // HL SF_PATH_ALTREVERSE
const float PT_DISABLE_TRAIN  = 8;
const float PT_TELEPORT       = 16;     // Sven extension, no HL equivalent
// HL SF_PATH_ALTERNATE.  RUNTIME-ONLY — not a mapper-facing flag.  CPathTrack::Use
// sets and clears it to swing the chain onto the alt branch (pathcorner.cpp:147-175).
const float PT_ALTERNATE      = 32768;  // 0x8000

// Sven path_track keys that were being dropped because no field existed.
//
// `speed` is labelled "(Legacy)" in Sven's FGD and `newspeed` supersedes it —
// but READ THE VALUES BEFORE USING newspeed: across th_ep1_00 and
// -sp_campaign_portal it is -1 on 100% of path_tracks (61/61 and 87/87), which
// is the FGD's "no change" sentinel.  A naive `if (t.newspeed) spd =
// t.newspeed;` would drive every train on both maps at -1 units/sec.  Only the
// legacy `speed` key is ever really set, and func_tracktrain already reads it.
// Any future consumer must guard on `> 0`.
.float newspeed;
.float maxspeed;
// Branch path for a track-change entity — HL's m_altName, the ONLY key
// CPathTrack::KeyValue handles specially (pathcorner.cpp:136-145).  Everything
// else (target / message / netname / speed) binds straight to entvars, which is
// also how FTE binds them here.
.string altpath;

// The link graph — HL's m_pnext / m_pprevious / m_paltpath (trains.h:37-72).
.entity pt_next;
.entity pt_prev;
.entity pt_alt;

// Set once per map by PathTrack_LinkAll; cleared in worldspawn (sv_main.qc).
float pathtrack_links_built;

// LookAhead's out-parameter.  QC has no by-reference args, so the projected
// position comes back here while the function itself returns the node.
vector pathtrack_lookahead_org;

// ---------------------------------------------------------------------------
// CPathTrack::SetPrevious — pathcorner.cpp:278-283.
// "Only set previous if this isn't my alternate path": a node reached AS an
// alternate must not back-link to the branch parent, or reversing off the alt
// path would walk back onto the main line at the wrong place.
// ---------------------------------------------------------------------------
void(entity node, entity prev) PathTrack_SetPrevious =
{
    if (!prev || prev == world) return;
    if (node.altpath != "" && prev.targetname == node.altpath) return;
    node.pt_prev = prev;
};

// ---------------------------------------------------------------------------
// CPathTrack::Link + Activate — pathcorner.cpp:178-212, 230-234.
//
// HL links from Activate(), which the engine calls after EVERY entity has
// spawned.  QC has no Activate, and path_tracks are created one at a time
// during map load, so a link attempted inside the spawn function would find
// half the chain missing.  Hence one idempotent pass over all of them, run
// lazily from the first consumer that needs it (func_tracktrain_find_first).
//
// HL only links nodes that HAVE a targetname (pathcorner.cpp:232).  Preserved:
// an anonymous path_track cannot be a chain member because nothing can name it.
// ---------------------------------------------------------------------------
void() PathTrack_LinkAll =
{
    if (pathtrack_links_built) return;
    pathtrack_links_built = 1;

    entity node = find(world, classname, "path_track");
    while (node)
    {
        node.pt_next = world;
        node.pt_prev = world;
        node.pt_alt  = world;
        node = find(node, classname, "path_track");
    }

    float dbg = cvar("sv_debug_func_train");
    float deadends = 0, linked = 0, alts = 0;

    node = find(world, classname, "path_track");
    while (node)
    {
        if (node.targetname != "")
        {
            if (node.target != "")
            {
                entity nxt = find(world, targetname, node.target);
                // HL takes whatever the name resolves to and null-checks the
                // CPathTrack cast (pathcorner.cpp:187).  The classname test is
                // that cast: a path_track whose `target` names a door must not
                // become a chain member.
                if (nxt != world && nxt.classname == "path_track")
                {
                    node.pt_next = nxt;
                    PathTrack_SetPrevious(nxt, node);
                    linked = linked + 1;
                }
                else
                {
                    deadends = deadends + 1;
                    if (dbg)
                        dprint(sprintf("[path_track] dead end link \"%s\" from \"%s\"\n",
                                       node.target, node.targetname));
                }
            }

            if (node.altpath != "")
            {
                entity alt = find(world, targetname, node.altpath);
                if (alt != world && alt.classname == "path_track")
                {
                    node.pt_alt = alt;
                    PathTrack_SetPrevious(alt, node);
                    alts = alts + 1;
                }
            }
        }
        node = find(node, classname, "path_track");
    }

    if (dbg)
        dprint(sprintf("[path_track] linked %g nodes, %g alt branches, %g dead ends\n",
                       linked, alts, deadends));
};

// ---------------------------------------------------------------------------
// CPathTrack::GetNext / GetPrevious — pathcorner.cpp:258-274.
//
// PT_BRANCH_REVERSE (HL SF_PATH_ALTREVERSE) does NOT mean "reverse the branch".
// It selects WHICH DIRECTION OF TRAVEL takes the alt path: without it the alt
// is taken going forwards, with it the alt is taken going backwards.
// ---------------------------------------------------------------------------
entity(entity node) PathTrack_GetNext =
{
    if (node.pt_alt != world
        && (node.spawnflags & PT_ALTERNATE)
        && !(node.spawnflags & PT_BRANCH_REVERSE))
        return node.pt_alt;
    return node.pt_next;
};

entity(entity node) PathTrack_GetPrevious =
{
    if (node.pt_alt != world
        && (node.spawnflags & PT_ALTERNATE)
        && (node.spawnflags & PT_BRANCH_REVERSE))
        return node.pt_alt;
    return node.pt_prev;
};

// ---------------------------------------------------------------------------
// CPathTrack::ValidPath — pathcorner.cpp:236-245.
//
// The PT_DISABLED filter applies ONLY when `move` is set.  That asymmetry is
// deliberate in HL and worth not "tidying": the train's MOVEMENT walk skips
// disabled nodes, but the front-axle heading look (move=0) runs straight
// through them, so disabling a node re-routes the train without making it
// snap its heading.
// ---------------------------------------------------------------------------
entity(entity ppath, float testFlag) PathTrack_ValidPath =
{
    if (!ppath || ppath == world) return world;
    if (testFlag && (ppath.spawnflags & PT_DISABLED)) return world;
    return ppath;
};

// ---------------------------------------------------------------------------
// CPathTrack::Project — pathcorner.cpp:248-256.  Extrapolate past a dead end
// along the last segment's direction, so a train's heading look doesn't
// collapse to zero when it runs out of track.
// ---------------------------------------------------------------------------
void(entity pstart, entity pend, float dist) PathTrack_Project =
{
    if (pstart != world && pend != world)
    {
        vector dir = pend.origin - pstart.origin;
        if (vlen(dir) > 0)
            pathtrack_lookahead_org = pend.origin + normalize(dir) * dist;
    }
};

// ---------------------------------------------------------------------------
// CPathTrack::LookAhead — pathcorner.cpp:287-366, ported line for line.
//
// Walk `dist` units along the polyline starting from `org` (which is assumed to
// lie on the segment at `node`), and report where you end up in the global
// pathtrack_lookahead_org.  Returns the node you ended up at, or world if the
// path ran out.
//
// NEGATIVE dist WALKS BACKWARDS.  That single property is the whole of reverse
// driving — plats.cpp:1187 passes `pev->speed * 0.1` straight in, and pev->speed
// is signed.
//
// `move` is HL's testFlag, forwarded to ValidPath: 1 for the movement walk
// (skips PT_DISABLED nodes), 0 for the heading look (doesn't).
//
// ITERATION CAP is mine, not HL's.  HL's loops are bounded only by the chain
// being acyclic; a map with a path_track cycle — or a chain corrupted by a
// killtarget — would spin here forever, and in FTE that means SV_Error "runaway
// loop" at 100M instructions (or, under a QCJIT build, a silent hard hang, see
// engine/qclib/pr_exec.c:1809-1815).  This mod has already been bitten once by
// an unbounded list walk; not doing that again.
// ---------------------------------------------------------------------------
entity(entity node, vector org, float dist, float move) PathTrack_LookAhead =
{
    entity pcurrent = node;
    vector currentPos = org;
    float  originalDist = dist;
    float  iter = 0;
    // fteqcc scopes locals per FUNCTION, not per block, so these are declared
    // once here rather than inside each of the two walk loops below.
    vector dir;
    float  length;

    pathtrack_lookahead_org = org;

    if (pcurrent == world) return world;

    if (dist < 0)                    // travelling backwards through the path
    {
        dist = -dist;
        while (dist > 0)
        {
            iter = iter + 1;
            if (iter > 512)
            {
                dprint(sprintf("[path_track] LookAhead ran away going BACK from \"%s\" — cyclic chain?\n",
                               node.targetname));
                pathtrack_lookahead_org = currentPos;
                return world;
            }

            dir = pcurrent.origin - currentPos;
            length = vlen(dir);

            if (!length)
            {
                if (PathTrack_ValidPath(PathTrack_GetPrevious(pcurrent), move) == world)
                {
                    if (!move)
                        PathTrack_Project(PathTrack_GetNext(pcurrent), pcurrent, dist);
                    return world;
                }
                pcurrent = PathTrack_GetPrevious(pcurrent);
            }
            else if (length > dist)          // enough left in this segment to move
            {
                pathtrack_lookahead_org = currentPos + (dir * (dist / length));
                return pcurrent;
            }
            else
            {
                dist = dist - length;
                currentPos = pcurrent.origin;
                pathtrack_lookahead_org = currentPos;
                if (PathTrack_ValidPath(PathTrack_GetPrevious(pcurrent), move) == world)
                    return world;
                pcurrent = PathTrack_GetPrevious(pcurrent);
            }
        }
        pathtrack_lookahead_org = currentPos;
        return pcurrent;
    }

    while (dist > 0)
    {
        iter = iter + 1;
        if (iter > 512)
        {
            dprint(sprintf("[path_track] LookAhead ran away going FORWARD from \"%s\" — cyclic chain?\n",
                           node.targetname));
            pathtrack_lookahead_org = currentPos;
            return world;
        }

        if (PathTrack_ValidPath(PathTrack_GetNext(pcurrent), move) == world)
        {
            if (!move)
                PathTrack_Project(PathTrack_GetPrevious(pcurrent), pcurrent, dist);
            return world;
        }

        entity nxt = PathTrack_GetNext(pcurrent);
        dir = nxt.origin - currentPos;
        length = vlen(dir);

        // HL's own comment: "HACK -- up against a dead end".  Two coincident
        // nodes at the very end of a chain would otherwise divide by zero.
        if (!length && PathTrack_ValidPath(PathTrack_GetNext(nxt), move) == world)
        {
            if (dist == originalDist)
                return world;
            return pcurrent;
        }

        if (length > dist)                   // enough left in this segment to move
        {
            pathtrack_lookahead_org = currentPos + (dir * (dist / length));
            return pcurrent;
        }

        dist = dist - length;
        currentPos = nxt.origin;
        pcurrent = nxt;
        pathtrack_lookahead_org = currentPos;
    }

    pathtrack_lookahead_org = currentPos;
    return pcurrent;
};

// ---------------------------------------------------------------------------
// CPathTrack::Nearest — pathcorner.cpp:370-405.  Closest node to a point,
// measured in 2D (z stripped) so a train under a bridge doesn't latch onto the
// track above it.  Used to re-acquire the chain after a teleport.
// ---------------------------------------------------------------------------
entity(entity node, vector org) PathTrack_Nearest =
{
    entity pcurrent = node;
    entity pnearest = node;
    float  iter = 0;

    vector delta = org - node.origin;
    delta_z = 0;
    float minDist = vlen(delta);

    // Walk forward from here to the end of the chain, keeping the closest.
    pcurrent = PathTrack_GetNext(node);
    while (pcurrent != world && iter < 512)
    {
        iter = iter + 1;
        delta = org - pcurrent.origin;
        delta_z = 0;
        float dist = vlen(delta);
        if (dist < minDist)
        {
            minDist = dist;
            pnearest = pcurrent;
        }
        pcurrent = PathTrack_GetNext(pcurrent);
    }
    return pnearest;
};

// ---------------------------------------------------------------------------
// CPathTrack::Use — pathcorner.cpp:147-175.
//
// A path_track had NO use handler at all before this, which is why
// sv_th_entities.qc's func_trackchange could set and clear PT_DISABLED with no
// observable effect (its comment at :4522 records the symptom without the
// cause).  Two modes, exactly as HL: if the node has an alt branch, +use swings
// the chain onto it; otherwise +use enables/disables the node itself.
//
// ShouldToggle is inlined — `on` is the state we would be moving TO, and an
// explicit USE_ON when already on (or USE_OFF when already off) is a no-op
// rather than a flip.  USE_OFF genuinely arrives here now; see the USE_UNSET
// note in sv_customdefs.qc for why it did not used to.
// ---------------------------------------------------------------------------
void() path_track_use =
{
    float ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;
    float on;

    if (self.pt_alt != world)
    {
        on = !(self.spawnflags & PT_ALTERNATE);
        if ((ut == USE_ON && !on) || (ut == USE_OFF && on))
            return;
        if (on) self.spawnflags = self.spawnflags |  PT_ALTERNATE;
        else    self.spawnflags = self.spawnflags - (self.spawnflags & PT_ALTERNATE);
    }
    else
    {
        on = !(self.spawnflags & PT_DISABLED);
        if ((ut == USE_ON && !on) || (ut == USE_OFF && on))
            return;
        if (on) self.spawnflags = self.spawnflags |  PT_DISABLED;
        else    self.spawnflags = self.spawnflags - (self.spawnflags & PT_DISABLED);
    }

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[path_track] \"%s\" use ut=%g -> spawnflags=%g\n",
                       self.targetname, ut, self.spawnflags));
};

/*QUAKED path_track (.5 .3 0) (-8 -8 -8) (8 8 8) DISABLED FIRE_ONCE BRANCH_REVERSE DISABLE_TRAIN TELEPORT
Node in a func_tracktrain path.  Chained through `target`; the chain is
back-linked at first use so trains can travel it in reverse.

"target"     targetname of the next path_track
"altpath"    targetname of a branch head; +use swings the chain onto it
"message"    fired as the train passes this node ("Fire On Pass")
"netname"    fired when a train dead-ends at this node
"speed"      train speed from here on — HONOURED ONLY while the train is under
             path control (TT_NO_USERCONTROL), matching plats.cpp:1255
"wait"       Sven extension: train pauses here this many seconds

DISABLED        skipped by the movement walk (not by the heading look)
FIRE_ONCE       `message` fires once, then is cleared on THIS node
BRANCH_REVERSE  the alt branch is taken travelling BACKWARDS, not forwards
DISABLE_TRAIN   takes control away from the driver; does NOT stop the train
TELEPORT        Sven extension: train snaps to this node
*/
void() path_track =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = path_track_use;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[path_track] spawn targetname=\"%s\" target=\"%s\" alt=\"%s\" origin=%v flags=%g\n",
                       self.targetname, self.target, self.altpath,
                       self.origin, self.spawnflags));
};
