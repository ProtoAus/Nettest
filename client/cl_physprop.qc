// ============================================================
//  client/cl_physprop.qc  -  CSQC ray-vs-cylinder for phys props
//
//  The server-side phys_barrel / phys_can entities are engine-
//  replicated (no SendEntity).  CSQC's nextent() doesn't iterate
//  engine-replicated entities, so the phys props are invisible to
//  the QC entity world.  But FTE's getentity() builtin reads engine
//  entity slots directly — including those server-replicated ents —
//  so we can find phys props by modelindex and intersect bullet rays
//  against an approximation of the visible mesh.
//
//  Why a cylinder instead of an AABB: both props are essentially
//  vertical cylinders (barrel r=15 h=45.2, can r=12 h=24).  A loose
//  AABB (the previous ±32 box) accepts shots that should have flown
//  through empty space around the visible mesh — sparks fire, decals
//  get suppressed on the wall behind, and the user "lost" the impact
//  to a phantom hit.  Ray-vs-cylinder approximates the actual mesh
//  silhouette closely (~0% false-positive vs ~21% for a tight AABB).
//
//  Why a manual override instead of letting CSQC traceline hit them:
//  the server uses SOLID_PHYSICS_TRIMESH (engine patch handles mesh
//  narrowphase for player pmove).  Forcing SOLID_BBOX or similar on
//  the CSQC side would also affect CSQC pmove, breaking predicted
//  player collision.  This pass touches no entity state.
// ============================================================

// Resolved at first call so the lookup happens after the connection's
// model precache list has been pulled into the engine model table.
// Doing it at CSQC_Init returned a CSQC-local slot that didn't match
// the server's network-shared one.
// Barrels and cans are picked at RANDOM from a set of models per spawn
// (PhysBarrel_RandomModel / PhysCan_RandomModel, sv_physprop.qc), so each type needs its
// whole set resolved — matching ONE path can never identify them.
//
// This used to resolve "models/props/barrel.iqm" and "models/props/can.mdl", neither of which
// exists: both came back 0, so every `!= 0` guard below was permanently false and the CSQC
// ray-vs-cylinder hit-test for barrels and cans was SILENTLY DEAD (real barrels carry
// metal_barrel_mp_* indices, which nothing matched).  Shots at a barrel/can fell through to the
// generic path with no cylinder test, no per-type material and no fake trace-target.
float pp_idx_barrel_1, pp_idx_barrel_2, pp_idx_barrel_3;
float pp_idx_can_1, pp_idx_can_2, pp_idx_can_3, pp_idx_can_4, pp_idx_can_5;
float pp_idx_phys_files;
float pp_idx_resolved;

void() CSQC_PhysProp_ResolveIndexes =
{
    if (pp_idx_resolved) return;
    // MUST match PhysBarrel_RandomModel / PhysCan_RandomModel + phys_barrel_precache
    // (sv_physprop.qc) — a model missing from the precache list resolves 0 and is simply
    // never matched, which is safe (the type just falls back to the generic hit path).
    pp_idx_barrel_1 = (float)getmodelindex("models/props/containers/mega/metal_barrel_mp_1.iqm");
    pp_idx_barrel_2 = (float)getmodelindex("models/props/containers/mega/metal_barrel_mp_2.iqm");
    pp_idx_barrel_3 = (float)getmodelindex("models/props/containers/mega/metal_barrel_mp_3.iqm");
    pp_idx_can_1    = (float)getmodelindex("models/props/containers/mega/tin_can_mp_1_rusty.iqm");
    pp_idx_can_2    = (float)getmodelindex("models/props/containers/mega/tin_can_mp_1_rusty_1.iqm");
    pp_idx_can_3    = (float)getmodelindex("models/props/containers/bunkers/canned_food_3.iqm");
    pp_idx_can_4    = (float)getmodelindex("models/props/containers/bunkers/canned_food_4.iqm");
    pp_idx_can_5    = (float)getmodelindex("models/props/containers/bunkers/canned_food_5.iqm");
    // Filecabinet is a single IQM (the legacy .mdl fallback is gone — it never existed on disk).
    // Its bullet hit-test is a rotated oriented-box (see CSQC_PhysProp_RayBox), accurate when it tips.
    pp_idx_phys_files  = (float)getmodelindex("models/props/filecabinet/filecabinet.iqm");
    pp_idx_resolved = 1;
};

// Is this modelindex one of the barrel / can set?  A real model never has index 0, so the
// midx==0 test also covers "that model wasn't precached" without needing per-slot != 0 guards.
// (Nested ifs, not an || chain: logicops is OFF mod-wide so every operand would evaluate.)
float(float midx) PhysProp_IsBarrelIdx =
{
    if (midx == 0) return FALSE;
    if (midx == pp_idx_barrel_1) return TRUE;
    if (midx == pp_idx_barrel_2) return TRUE;
    if (midx == pp_idx_barrel_3) return TRUE;
    return FALSE;
};

float(float midx) PhysProp_IsCanIdx =
{
    if (midx == 0) return FALSE;
    if (midx == pp_idx_can_1) return TRUE;
    if (midx == pp_idx_can_2) return TRUE;
    if (midx == pp_idx_can_3) return TRUE;
    if (midx == pp_idx_can_4) return TRUE;
    if (midx == pp_idx_can_5) return TRUE;
    return FALSE;
};

// One persistent fake-target entity per prop type.  Bullet impact code
// checks trace_ent.classname for material classification + decal gating;
// we point trace_ent at one of these so the existing classname-based
// gates work without any changes.  Reused across shots.
entity pp_fake_barrel;
entity pp_fake_can;
entity pp_fake_files;

void() CSQC_PhysProp_EnsureFakeEnts =
{
    if (!pp_fake_barrel)
    {
        pp_fake_barrel = spawn();
        pp_fake_barrel.classname = "phys_barrel";
        pp_fake_barrel.solid = SOLID_NOT;
        pp_fake_barrel.drawmask = 0;     // never rendered, never collided
    }
    if (!pp_fake_can)
    {
        pp_fake_can = spawn();
        pp_fake_can.classname = "phys_can";
        pp_fake_can.solid = SOLID_NOT;
        pp_fake_can.drawmask = 0;
    }
    if (!pp_fake_files)
    {
        pp_fake_files = spawn();
        pp_fake_files.classname = "phys_files";
        pp_fake_files.solid = SOLID_NOT;
        pp_fake_files.drawmask = 0;
    }
};

// FTE getentity() field codes.  GE_FORWARD/RIGHT/UP give the prop's
// current world-space basis vectors directly (computed from its angles
// each tick by the engine), so we don't need to call makevectors.
const float GE_MAXENTS    = 0;
const float GE_ACTIVE     = 1;
const float GE_ORIGIN     = 3;
const float GE_FORWARD    = 4;
const float GE_RIGHT      = 5;
const float GE_UP         = 6;
const float GE_MODELINDEX = 15;

// Cylinder hit globals (QC has no real out-params).  pp_hit_t / normal
// describe the entry surface; pp_exit_t / normal describe the exit.
float  pp_hit_t;
vector pp_hit_normal;
float  pp_exit_t;
vector pp_exit_normal;

// Ray vs vertical cylinder, oriented in the local frame defined by
// vf / vr / vu (read from getentity GE_FORWARD/RIGHT/UP — these track
// the prop's ODE-driven angles, so a tipped barrel is hit precisely on
// the rotated cylinder).  Cylinder axis is local Z.
//
// Returns tnear in [0, dirlen] on hit (and writes pp_hit_normal world-
// space + pp_exit_t / pp_exit_normal).  Returns -1 on miss, on origin-
// inside-cylinder, or when the cylinder is entirely behind the ray —
// the origin-inside skip prevents trace_endpos collapsing onto the
// shooter's eye when the player stands inside the prop's volume.
float(vector ro_world, vector dir_unit, float dirlen,
      vector center, vector vf, vector vr, vector vu,
      float radius, float half_h) CSQC_PhysProp_RayCylinder =
{
    // Ray → local space.  delta · basis_vec gives the local component.
    vector delta = ro_world - center;
    vector ro_loc = '0 0 0';
    ro_loc_x = delta * vf;
    ro_loc_y = delta * vr;
    ro_loc_z = delta * vu;

    vector dir_loc = '0 0 0';
    dir_loc_x = dir_unit * vf;
    dir_loc_y = dir_unit * vr;
    dir_loc_z = dir_unit * vu;

    // Side slab — solve |ro_xy + t·dir_xy|² = r² for t.
    float a = dir_loc_x * dir_loc_x + dir_loc_y * dir_loc_y;
    float b = 2 * (ro_loc_x * dir_loc_x + ro_loc_y * dir_loc_y);
    float c = ro_loc_x * ro_loc_x + ro_loc_y * ro_loc_y - radius * radius;
    float t_side_near, t_side_far;
    if (a < 0.000001)
    {
        // Ray parallel to cylinder axis.  Inside the radial slab if c<=0.
        if (c > 0) return -1;
        t_side_near = -999999999;
        t_side_far  =  999999999;
    }
    else
    {
        float disc = b * b - 4 * a * c;
        if (disc < 0) return -1;
        float sq = sqrt(disc);
        t_side_near = (-b - sq) / (2 * a);
        t_side_far  = (-b + sq) / (2 * a);
    }

    // Cap slab — clip ro_z + t·dir_z to [-half_h, +half_h].
    float t_cap_near, t_cap_far;
    if (fabs(dir_loc_z) < 0.000001)
    {
        if (ro_loc_z < -half_h || ro_loc_z > half_h) return -1;
        t_cap_near = -999999999;
        t_cap_far  =  999999999;
    }
    else
    {
        float t1 = (-half_h - ro_loc_z) / dir_loc_z;
        float t2 = ( half_h - ro_loc_z) / dir_loc_z;
        if (t1 < t2) { t_cap_near = t1; t_cap_far = t2; }
        else         { t_cap_near = t2; t_cap_far = t1; }
    }

    // Combine the two slabs: ray inside cylinder for t in [tnear, tfar].
    float tnear = (t_side_near > t_cap_near) ? t_side_near : t_cap_near;
    float tfar  = (t_side_far  < t_cap_far ) ? t_side_far  : t_cap_far;

    if (tnear > tfar)   return -1;
    if (tfar  < 0)      return -1;
    if (tnear < 0)      return -1;   // origin inside — skip
    if (tnear > dirlen) return -1;

    // Entry-surface normal (local).  Whichever slab contributed the
    // larger near-t was the surface actually entered.
    vector entry_loc = ro_loc + tnear * dir_loc;
    vector entry_n_loc = '0 0 0';
    if (t_side_near >= t_cap_near)
    {
        // Entered through cylinder side → radial outward at hit point.
        float r_xy = sqrt(entry_loc_x * entry_loc_x + entry_loc_y * entry_loc_y);
        if (r_xy > 0.001)
        {
            entry_n_loc_x = entry_loc_x / r_xy;
            entry_n_loc_y = entry_loc_y / r_xy;
        }
        else
            entry_n_loc_z = 1;
    }
    else
    {
        // Entered through cap → opposite to local-Z heading.
        if (dir_loc_z > 0) entry_n_loc_z = -1;
        else               entry_n_loc_z =  1;
    }
    pp_hit_t = tnear;
    pp_hit_normal = entry_n_loc_x * vf + entry_n_loc_y * vr + entry_n_loc_z * vu;

    // Exit-surface normal (local).  Far slab is the surface exited.
    vector exit_loc = ro_loc + tfar * dir_loc;
    vector exit_n_loc = '0 0 0';
    if (t_side_far <= t_cap_far)
    {
        float r_xy2 = sqrt(exit_loc_x * exit_loc_x + exit_loc_y * exit_loc_y);
        if (r_xy2 > 0.001)
        {
            exit_n_loc_x = exit_loc_x / r_xy2;
            exit_n_loc_y = exit_loc_y / r_xy2;
        }
        else
            exit_n_loc_z = 1;
    }
    else
    {
        if (dir_loc_z > 0) exit_n_loc_z =  1;
        else               exit_n_loc_z = -1;
    }
    pp_exit_t = tfar;
    pp_exit_normal = exit_n_loc_x * vf + exit_n_loc_y * vr + exit_n_loc_z * vu;

    return tnear;
};

// Ray vs ORIENTED BOX, in the local frame vf/vr/vu (getentity basis — tracks
// the prop's ODE angles, so a tipped/rotated cabinet is hit on its real rotated
// faces, not the axis-aligned engine AABB).  The box spans [lmins, lmaxs] in
// local space anchored at `center` (the entity origin; for the filecabinet that
// is the feet, lmins_z 0).  Standard 3-slab test.  Writes pp_hit_t/normal +
// pp_exit_t/normal like RayCylinder.  Returns tnear in [0,dirlen] on hit, -1 on
// miss / origin-inside / behind-the-ray.
float(vector ro_world, vector dir_unit, float dirlen,
      vector center, vector vf, vector vr, vector vu,
      vector lmins, vector lmaxs) CSQC_PhysProp_RayBox =
{
    vector delta = ro_world - center;
    vector ro_loc, dir_loc;
    ro_loc_x  = delta * vf;     ro_loc_y  = delta * vr;     ro_loc_z  = delta * vu;
    dir_loc_x = dir_unit * vf;  dir_loc_y = dir_unit * vr;  dir_loc_z = dir_unit * vu;

    float tnear = -999999999, tfar = 999999999;
    float near_axis = 0, near_sign = 0;
    float far_axis  = 0, far_sign  = 0;
    float t1, t2, s, tt;

    // --- X slab ---
    if (fabs(dir_loc_x) < 0.000001)
    {
        if (ro_loc_x < lmins_x || ro_loc_x > lmaxs_x) return -1;
    }
    else
    {
        t1 = (lmins_x - ro_loc_x) / dir_loc_x;
        t2 = (lmaxs_x - ro_loc_x) / dir_loc_x;
        s = -1;                                   // entry through -X face
        if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; s = 1; }
        if (t1 > tnear) { tnear = t1; near_axis = 0; near_sign = s; }
        if (t2 < tfar)  { tfar  = t2; far_axis  = 0; far_sign  = 0 - s; }
    }
    // --- Y slab ---
    if (fabs(dir_loc_y) < 0.000001)
    {
        if (ro_loc_y < lmins_y || ro_loc_y > lmaxs_y) return -1;
    }
    else
    {
        t1 = (lmins_y - ro_loc_y) / dir_loc_y;
        t2 = (lmaxs_y - ro_loc_y) / dir_loc_y;
        s = -1;
        if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; s = 1; }
        if (t1 > tnear) { tnear = t1; near_axis = 1; near_sign = s; }
        if (t2 < tfar)  { tfar  = t2; far_axis  = 1; far_sign  = 0 - s; }
    }
    // --- Z slab ---
    if (fabs(dir_loc_z) < 0.000001)
    {
        if (ro_loc_z < lmins_z || ro_loc_z > lmaxs_z) return -1;
    }
    else
    {
        t1 = (lmins_z - ro_loc_z) / dir_loc_z;
        t2 = (lmaxs_z - ro_loc_z) / dir_loc_z;
        s = -1;
        if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; s = 1; }
        if (t1 > tnear) { tnear = t1; near_axis = 2; near_sign = s; }
        if (t2 < tfar)  { tfar  = t2; far_axis  = 2; far_sign  = 0 - s; }
    }

    if (tnear > tfar)   return -1;
    if (tfar  < 0)      return -1;
    if (tnear < 0)      return -1;   // origin inside the box — skip
    if (tnear > dirlen) return -1;

    vector n_loc = '0 0 0';
    if      (near_axis == 0) n_loc_x = near_sign;
    else if (near_axis == 1) n_loc_y = near_sign;
    else                     n_loc_z = near_sign;
    pp_hit_t = tnear;
    pp_hit_normal = n_loc_x * vf + n_loc_y * vr + n_loc_z * vu;

    vector ne_loc = '0 0 0';
    if      (far_axis == 0) ne_loc_x = far_sign;
    else if (far_axis == 1) ne_loc_y = far_sign;
    else                    ne_loc_z = far_sign;
    pp_exit_t = tfar;
    pp_exit_normal = ne_loc_x * vf + ne_loc_y * vr + ne_loc_z * vu;

    return tnear;
};

// Per-type cylinder dimensions.  Returns (radius, half_height, 0).
// Centralised so forward and back-trace agree.
// Cylinder half-extents per prop type — (radius, half_height, 0).
// Slightly larger than the documented mesh bounds (barrel mesh extents
// 15.4 / 14.4 / 22.6) so shots grazing the visible silhouette and the
// top/bottom rings still register.  Tighter than the ±32 / ±12 setsize
// so phantom hits in empty AABB volume don't fire either.
vector(float midx) CSQC_PhysProp_CylForType =
{
    if (PhysProp_IsBarrelIdx(midx)) return '16 23.6 0';
    if (PhysProp_IsCanIdx(midx))    return '13 13 0';
    return '0 0 0';
};

entity(float midx) CSQC_PhysProp_FakeForType =
{
    if (PhysProp_IsBarrelIdx(midx)) return pp_fake_barrel;
    if (PhysProp_IsCanIdx(midx))    return pp_fake_can;
    if (pp_idx_phys_files != 0)
        if (midx == pp_idx_phys_files) return pp_fake_files;
    return world;
};

void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideTrace =
{
    CSQC_PhysProp_ResolveIndexes();
    // Nothing of any known type precached on this map → no override to do.  (Barrel/can are now
    // model SETS, so this tests the first of each rather than a single index.)
    if (!pp_idx_barrel_1)
        if (!pp_idx_can_1)
            if (!pp_idx_phys_files)
                return;
    CSQC_PhysProp_EnsureFakeEnts();

    vector dir = trace_end - trace_src;
    float dirlen = vlen(dir);
    if (dirlen < 0.001) return;
    vector dir_unit = dir * (1 / dirlen);

    // Best (closest) hit so far in world units along the ray.  When the
    // engine traceline didn't hit anything, treat existing_t as dirlen
    // so any cylinder hit within range wins.
    float existing_t = trace_fraction * dirlen;
    if (trace_fraction >= 1.0) existing_t = dirlen;
    float best_t = existing_t;
    entity best_ent = world;
    vector best_normal = '0 0 0';

    float maxents = (float)getentity(0, GE_MAXENTS);
    if (maxents <= 0) return;
    if (maxents > 4096) maxents = 4096;

    float i;
    for (i = 1; i < maxents; i++)
    {
        if ((float)getentity(i, GE_ACTIVE) == 0) continue;

        float midx = (float)getentity(i, GE_MODELINDEX);
        entity fake_ent = CSQC_PhysProp_FakeForType(midx);
        if (fake_ent == world) continue;

        vector org = (vector)getentity(i, GE_ORIGIN);
        vector vf  = (vector)getentity(i, GE_FORWARD);
        vector vr  = (vector)getentity(i, GE_RIGHT);
        vector vu  = (vector)getentity(i, GE_UP);

        // Cabinet is a box → oriented-box test; barrel/can are cylinders.
        float tnear;
        if (pp_idx_phys_files != 0 && midx == pp_idx_phys_files)
            tnear = CSQC_PhysProp_RayBox(trace_src, dir_unit, dirlen,
                                         org, vf, vr, vu,
                                         '-11.31 -14.37 0', '11.29 14.39 62.79');
        else
        {
            vector cyl = CSQC_PhysProp_CylForType(midx);
            tnear = CSQC_PhysProp_RayCylinder(trace_src, dir_unit, dirlen,
                                              org, vf, vr, vu,
                                              cyl_x, cyl_y);
        }
        if (tnear < 0) continue;
        if (tnear >= best_t) continue;

        best_t = tnear;
        best_ent = fake_ent;
        best_normal = pp_hit_normal;
    }

    // The filing cabinet is a CSQC SendEntity MIRROR — NOT in the engine entity slots
    // getentity() reads (those are the engine-replicated barrel/can), so the loop above
    // never sees it.  Ray-test it here via findchain, regardless of solid state, so a
    // MOVING cabinet (SOLID_NOT while carried / just-thrown, before it re-solidifies)
    // still registers a bullet hit → metal spark.  At rest the normal traceline already
    // hits its SOLID_PHYSICS_BOX; this just takes the closer of the two (no double).
    // makevectors below clobbers v_forward/right/up — save the caller's set (e.g. the
    // shot direction) and restore it after, so penetration / later pellets are unaffected.
    vector pp_save_vf = v_forward, pp_save_vr = v_right, pp_save_vu = v_up;
    entity cab = findchain(classname, "phys_files");
    while (cab)
    {
        // A SOLID mirror (free SOLID_PHYSICS_BOX) is ALREADY hit by the engine traceline
        // above, so the RayBox here would be redundant.  It's only needed for a MOVING
        // mirror (SOLID_NOT while carried / just-thrown).  Skip solid ones so a prop-dense
        // Source map doesn't pay an O(props-in-PVS) RayBox scan on every pellet.
        if (cab.solid != SOLID_NOT)
        {
            cab = cab.chain;
            continue;
        }
        makevectors(cab.angles);   // raw-angle OBB axes (−v_right), matching World_OBBTrace + the debug box
        float ct = CSQC_PhysProp_RayBox(trace_src, dir_unit, dirlen,
                                        cab.origin, v_forward, v_right * -1, v_up,
                                        cab.mins, cab.maxs);
        if (ct >= 0 && ct < best_t)
        {
            best_t      = ct;
            best_ent    = pp_fake_files;
            best_normal = pp_hit_normal;
        }
        cab = cab.chain;
    }
    v_forward = pp_save_vf; v_right = pp_save_vr; v_up = pp_save_vu;

    if (best_ent != world)
    {
        trace_endpos       = trace_src + dir_unit * best_t;
        trace_plane_normal = best_normal;
        trace_ent          = best_ent;
        trace_fraction     = best_t / dirlen;
    }
};

// Penetration back-trace: same cylinder math reused.  The back-trace ray
// goes from `nudge_pos` (past the prop) back to `entry_pos`, so the
// cylinder NEAR-hit on this reversed ray is the bullet's exit point on
// the prop's back face.  Override semantics are identical to the
// forward override — any prop intersected closer than the engine
// traceline's hit wins, with trace_endpos / normal / ent / fraction
// all overridden.  Lets the penetration loop see exit_pos = barrel
// back surface and continue past the prop with reduced damage.
void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideBackTrace =
{
    CSQC_PhysProp_OverrideTrace(trace_src, trace_end);
};

// ============================================================
//  cl_debug_physprops — Draw the phantom hit cylinder
//
//  Shows the actual hit-test shape for every replicated phys prop —
//  rotated by getentity GE_FORWARD/RIGHT/UP so a tipped barrel's
//  cylinder rotates with it.  Useful to verify the cylinder lines up
//  with the visible mesh and to spot dimension mismatches.
// ============================================================

const float PP_CYL_SEGMENTS = 16;
void(vector p1, vector p2, vector col, float alpha) dbg_hitbox_line;

// Draw a CSQC phys-prop's ORIENTED collision box (OBB) — the rotated box the engine
// patch (World_OBBTrace) actually collides against.  Uses the SAME alias mesh-pitch/
// roll + right-hand flip the patch uses, so the wireframe lines up exactly with the
// real hull.  Green, to stand apart from the orange barrel/can cylinders.
void(entity e, vector col) CSQC_DrawPhysOBB =
{
    // Alias mesh-pitch/roll basis (r_meshpitch/r_meshroll) so the box tracks a TUMBLING prop the
    // same way the model renders + World_OBBTrace collides — raw angles diverged mid-tumble.  No-op
    // for an upright prop (pitch/roll 0), so upright cabinets/barrels are unchanged.
    makevectors([e.angles_x * cvar("r_meshpitch"), e.angles_y, e.angles_z * cvar("r_meshroll")]);
    vector ax0 = v_forward;
    vector ax1 = v_right * -1;   // right-hand flip, matching World_OBBTrace
    vector ax2 = v_up;

    vector lo = e.mins, hi = e.maxs;
    vector c0 = e.origin + lo_x*ax0 + lo_y*ax1 + lo_z*ax2;
    vector c1 = e.origin + hi_x*ax0 + lo_y*ax1 + lo_z*ax2;
    vector c2 = e.origin + hi_x*ax0 + hi_y*ax1 + lo_z*ax2;
    vector c3 = e.origin + lo_x*ax0 + hi_y*ax1 + lo_z*ax2;
    vector c4 = e.origin + lo_x*ax0 + lo_y*ax1 + hi_z*ax2;
    vector c5 = e.origin + hi_x*ax0 + lo_y*ax1 + hi_z*ax2;
    vector c6 = e.origin + hi_x*ax0 + hi_y*ax1 + hi_z*ax2;
    vector c7 = e.origin + lo_x*ax0 + hi_y*ax1 + hi_z*ax2;

    float  al  = 0.7;
    dbg_hitbox_line(c0, c1, col, al);  dbg_hitbox_line(c1, c2, col, al);   // bottom ring
    dbg_hitbox_line(c2, c3, col, al);  dbg_hitbox_line(c3, c0, col, al);
    dbg_hitbox_line(c4, c5, col, al);  dbg_hitbox_line(c5, c6, col, al);   // top ring
    dbg_hitbox_line(c6, c7, col, al);  dbg_hitbox_line(c7, c4, col, al);
    dbg_hitbox_line(c0, c4, col, al);  dbg_hitbox_line(c1, c5, col, al);   // verticals
    dbg_hitbox_line(c2, c6, col, al);  dbg_hitbox_line(c3, c7, col, al);
};

// Buoyancy debug mirror — populated ONLY while sv_debug_physprops is on (the server flags the payload
// with PP_PHASE_DBG_BIT); drives the cl_debug_physprops overlay.  Zero when the server isn't sending.
// Declared HERE, above the two draw functions below, rather than with the rest of the pp_* fields much
// further down — fteqcc resolves strictly top-down, so a field used by a function must precede it.
.float  pp_dbg_rest;       // PP_DBG_REST_* — none / float-rest / contact-rest
.float  pp_dbg_wet;        // 1 = server says this prop is in water
.float  pp_dbg_frac;       // current submerged fraction (0..1)
.float  pp_dbg_feq;        // submerged fraction it WANTS (f_eq); >= 1 means it sinks
.float  pp_dbg_since;      // cltime the rest state last changed (for the "held for" readout)
.float  pp_dbg_loaded;     // 1 = something stacked on it; it must keep being forced (not a failure)

// Active-prop chain (moving props only) — drives the prediction hull relink.  Own link field, NOT
// .chain, which findradius/findchain reuse as scratch.
.entity pp_active_next;
.float  pp_active_linked;

// All-props chain (EVERY phys_files mirror, moving OR settled) — drives the render cull sweep.
// The active chain above cannot be reused for that: it is deliberately moving-only, and the props
// that most need culling are exactly the settled ones it drops.  Own link field, NOT .chain.
.entity pp_all_next;
.float  pp_all_linked;
.float  pp_cull_hidden;     // 1 = the sweep has drawmask'd this prop out (hysteresis state)
.float  pp_cull_noshadow;   // 1 = the sweep set EF_NOSHADOW, so only the sweep may clear it again

// Debug colour for a prop's OBB / label.  With sv_debug_physprops on the server sends the AUTHORITATIVE
// rest state, so these are facts rather than the velocity guess this used to make:
//   YELLOW = carried / just-dropped passthrough (non-solid to players)
//   BLUE   = float-rest    — settled at its float line, gravity off, forcing off
//   GREY   = contact-rest  — held by the pond floor or a prop stacked on it, gravity still on
//   RED    = in water and STILL BEING FORCED — the state a prop should never be stuck in.  A prop that
//            stays red is the shallow-water / stacked-pair bug: it can never reach its float line, so it
//            is pushed upward forever and never sleeps.  This is the whole reason the overlay exists.
//   CYAN   = dry + settled (velocity ~0; inferred, no server state needed)
//   GREEN  = free + moving
vector(entity e) PhysProp_DebugColour =
{
    if (e.solid == SOLID_NOT)              return '1 0.85 0';
    if (e.pp_dbg_rest == PP_DBG_REST_FLOAT)   return '0.25 0.5 1';
    if (e.pp_dbg_rest == PP_DBG_REST_CONTACT) return '0.6 0.6 0.6';
    if (e.pp_dbg_loaded)                   return '1 0.6 0.1';   // orange: forced ON PURPOSE, holding a load
    if (e.pp_dbg_wet)                      return '1 0.2 0.2';
    if (vlen(e.velocity) < 0.5)
    if (vlen(e.avelocity) < 0.5)
        return '0 0.6 1';
    return '0 1 0';
};

// 2D state labels for the cl_debug_physprops overlay.  MUST be called AFTER renderscene — project()
// needs the finished view transform (same constraint NavDebug_DrawText documents and follows).
//
// Two lines per prop, deliberately terse so a stacked pile or a pond stays readable:
//   FLOAT 2.4s g:off          <- rest mode + how long it has held + whether gravity is zeroed
//   f .31/.35 v0.1 w          <- submerged fraction / what it WANTS, speed, and 'w' if wet
// A prop whose frac can never converge on f_eq is the one that will never settle, so putting the pair
// side by side is the fastest way to see it.
const float PP_DBGLBL_DIST = 1200;   // don't label props further than this (a labelled pond is unreadable)

void() CSQC_DrawDebugPhysPropText =
{
    if (!cvar("cl_debug_physprops")) return;

    // Deliberately the DEFAULT font at its native 8px, and drawn ONCE with no shadow pass.  The mono
    // hud font renders from baked sizes and came out far too heavy for a label that may be repeated
    // over every prop in a pond — this is meant to be readable at a glance, not to look designed.
    vector eye = getproperty(VF_ORIGIN);
    entity e = findchain(classname, "phys_files");
    while (e)
    {
        if (e.drawmask)
        if (vlen(e.origin - eye) < PP_DBGLBL_DIST)
        {
            vector scr = project(e.origin + '0 0 1' * (e.maxs_z + 4));
            if (scr_z > 0)          // skip anything behind the camera
            {
                string mode;
                if (e.solid == SOLID_NOT)                      mode = "CARRIED";
                else if (e.pp_dbg_rest == PP_DBG_REST_FLOAT)   mode = "FLOAT";
                else if (e.pp_dbg_rest == PP_DBG_REST_CONTACT) mode = "CONTACT";
                else if (e.pp_dbg_loaded)                      mode = "LOADED";
                else if (e.pp_dbg_wet)                         mode = "FORCED";
                else                                           mode = "-";

                // via a float local: cltime is a __double, so inlining the subtraction into the
                // ternary (and then into sprintf's %f) is a type mismatch.
                float held = 0;
                if (e.pp_dbg_rest)
                    held = cltime - e.pp_dbg_since;

                string l1 = sprintf("%s %.1fs g:%s", mode, held,
                                    (e.pp_dbg_rest == PP_DBG_REST_FLOAT) ? "off" : "on");
                string l2 = sprintf("f %.2f/%.2f v%.1f%s",
                                    e.pp_dbg_frac, e.pp_dbg_feq, vlen(e.velocity),
                                    e.pp_dbg_wet ? " w" : "");

                vector col = PhysProp_DebugColour(e);
                vector sz  = '8 8 0';
                drawstring([scr_x - stringwidth(l1, 1, sz) * 0.5, scr_y],
                           l1, sz, col, 1, 0);
                drawstring([scr_x - stringwidth(l2, 1, sz) * 0.5, scr_y + 8],
                           l2, sz, col, 1, 0);
            }
        }
        e = e.chain;
    }
};

void() CSQC_DrawDebugPhysProps =
{
    float show_obb = cvar("cl_debug_physprops");
    if (!show_obb) return;

    // Cabinet (and any phys_files) OBBs — the CSQC mirrors are real csqc edicts, so
    // findchain sees them.  Colour = state, see PhysProp_DebugColour.
    entity e = findchain(classname, "phys_files");
    while (e)
    {
        if (e.drawmask)
        {
            if (show_obb)
                CSQC_DrawPhysOBB(e, PhysProp_DebugColour(e));
        }
        e = e.chain;
    }

    // Legacy getentity() cylinder path (engine-replicated props) — now dead for the CSQC-mirror
    // barrels/cans; only runs for the OBB toggle, never for the new cyl overlay.
    if (!show_obb) return;
    CSQC_PhysProp_ResolveIndexes();
    if (!pp_idx_barrel_1)
        if (!pp_idx_can_1)
            return;

    float maxents = (float)getentity(0, GE_MAXENTS);
    if (maxents <= 0) return;
    if (maxents > 4096) maxents = 4096;

    vector col = '1 0.5 0';   // orange — distinct from the cyan hbexpand box
    float alpha = 0.6;

    float i;
    for (i = 1; i < maxents; i++)
    {
        if ((float)getentity(i, GE_ACTIVE) == 0) continue;

        float midx = (float)getentity(i, GE_MODELINDEX);
        vector cyl = CSQC_PhysProp_CylForType(midx);
        if (cyl_x == 0) continue;   // not a known phys prop

        vector org = (vector)getentity(i, GE_ORIGIN);
        vector vf  = (vector)getentity(i, GE_FORWARD);
        vector vr  = (vector)getentity(i, GE_RIGHT);
        vector vu  = (vector)getentity(i, GE_UP);

        float r = cyl_x;
        float h = cyl_y;

        vector first_top = '0 0 0', first_bot = '0 0 0';
        vector prev_top  = '0 0 0', prev_bot  = '0 0 0';

        float seg;
        for (seg = 0; seg < PP_CYL_SEGMENTS; seg++)
        {
            float ang_rad = seg * (2 * 3.14159265 / PP_CYL_SEGMENTS);
            float c_x = r * cos(ang_rad);
            float c_y = r * sin(ang_rad);

            // Local (c_x, c_y, ±h) → world via the prop's basis vectors.
            vector top_p = org + c_x * vf + c_y * vr + h * vu;
            vector bot_p = org + c_x * vf + c_y * vr - h * vu;

            if (seg == 0)
            {
                first_top = top_p;
                first_bot = bot_p;
            }
            else
            {
                dbg_hitbox_line(prev_top, top_p, col, alpha);
                dbg_hitbox_line(prev_bot, bot_p, col, alpha);
            }

            // Vertical struts every 4th segment (4 around the cylinder).
            if (seg == 0 || seg == 4 || seg == 8 || seg == 12)
                dbg_hitbox_line(top_p, bot_p, col, alpha);

            prev_top = top_p;
            prev_bot = bot_p;
        }

        // Close the rings.
        dbg_hitbox_line(prev_top, first_top, col, alpha);
        dbg_hitbox_line(prev_bot, first_bot, col, alpha);
    }
};

// ============================================================
//  CSQC-networked filing cabinet  (CSQC_ENT_PHYS_PROP)
//  ----------------------------------------------------------
//  The SERVER runs the real ODE body; THIS mirror is what the client's custom
//  QC pmove and the CSQC bullet traces actually collide with.  Without it the
//  client is blind to the engine-replicated prop (the QC pmove only sees CSQC
//  entities), so players fall through / driftlock on top of it and shots that
//  the engine trace would catch miss locally.  A SOLID_BBOX matching the
//  cabinet's hbox closes that gap; the model is still drawn at the streamed
//  tumble angles so it looks right while it rolls.  This also makes the carried
//  cabinet render smoothly (origin is streamed + extrapolated, not engine-
//  interpolated).  Wire layout MUST match phys_files_Send (sv_physprop.qc).
// ============================================================

// Own snapshot anchors (NOT the brushsync csqc_snap_* — cl_brushsync.qc is
// compiled AFTER this file, and keeping them separate avoids any cross-talk if
// a CSQC entity slot is recycled between a brush and this prop).
.vector pp_snap_origin;
.vector pp_snap_angles;
.float  pp_snap_time;
.vector pp_snap_origin_prev;   // 2-snapshot interpolation: the PREVIOUS authoritative snapshot
.vector pp_snap_angles_prev;
.float  pp_snap_time_prev;
// Smoothed observed stream interval (seconds between snapshots), maintained as a running average in
// CSQC_PhysProp_Update.  This is the RENDER DELAY; the raw prev→cur gap is only the lerp window.  Keeping
// those two separate is the whole point — see PhysProp_RenderDelay.  0 = not measured yet.
.float  pp_snap_interval;

// Carry state (from the wire) + client-prediction bookkeeping.
.float  pp_phase;          // PP_PHASE_* (was the csolid byte)
.float  pp_carrier;        // carrier edict (0 = free); == player_localentnum ⇒ predict locally
.float  pp_is_car;         // 1 = this mirror is a prop_car/func_car (engine-sound driver)
.entity pp_car_next;       // car chain link (g_car_chain_head) — every per-frame car loop walks THIS, not
                           //   find(classname "phys_files"), which walks every prop.  NOT .chain (scratch).
.float  pp_car_linked;     // 1 = currently on the car chain (Update fires per snapshot; this de-dupes the link)
.float  pp_hold_dist;      // networked sv_carry_hold_dist (remote clients have no server cvar)
.float  pp_hold_z;         // networked sv_carry_hold_z
.float  pp_was_predicting; // 1 if last frame drove this prop from the local view (drives the drop fade)
.vector pp_pred_origin;    // last client-predicted feet origin (the "predicted hand" pose)
.vector pp_err_offset;     // predicted − authoritative at the handoff edge; decays to 0
.float  pp_err_cltime;     // cltime the error offset was seeded (0 = none pending)

// Carried ORIENTATION (see shared/sh_carryrot.qc).  While THIS client is the carrier the
// basis is client-OWNED and predicted — inspect mode writes it locally and pushes it
// upstream, so the streamed copy is just our own echo and must NOT be read back or the
// two fight each other.  pp_rel_valid latches the seed on the ownership edge only.
.vector pp_rel_fwd;        // model +X in the carry frame (unit)
.vector pp_rel_up;         // model +Z in the carry frame (unit, ⊥ fwd)
.float  pp_rel_valid;      // 1 = pp_rel_* has been seeded from the stream
.vector pp_snap_rel;       // newest streamed carry-frame orientation (Euler), the seed
.vector pp_pred_fwd;       // predicted basis at the handoff edge (angular drop fade)
.vector pp_pred_up;

// Visual spinning-wheel state for prop_car mirrors (networked on the is-car branch; spin integrated locally).
.float  pp_car_steer;      // front-wheel steer angle (deg)
.float  pp_car_wheelidx;   // wheel model network index (0 = none / baked wheels)
.float  pp_car_myaw;       // per-car model_yaw (deg)
.float  pp_car_base;       // resolved wheelbase (fwd spacing), networked so visual wheels match physics
.float  pp_car_track;      // resolved track (L-R spacing)
.float  pp_car_drop;       // resolved wheel drop below the box bottom
.float  pp_car_fwd;        // resolved fore/aft wheel offset (wheel_fwd key + sv_car_wheel_fwd)
.float  pp_car_rest;       // resolved ride_height — caps the visual droop like the physics
.float  pp_car_travel;     // resolved compression_travel
.float  pp_car_maxspd;     // engine-sound scale: physics redline speed (sv_car_max_speed) — audio gears match physics
.float  pp_car_gears;      // engine-sound: virtual gear count (sv_car_gears)
.float  pp_car_shift;      // engine-sound: shift-cut window seconds (sv_car_shift_time) — drives the rev dip
.entity pp_wheel0, pp_wheel1, pp_wheel2, pp_wheel3;   // 4 cached wheel render entities
.float  pp_wheel_spin;     // accumulated roll angle (deg), shared by all 4 wheels
.float  pp_wheel_time;     // cltime of the last spin integration

// Seated driver render (networked on the is-car branch when a driver is present + sv_car_show_driver).
.float  pp_car_drv_ent;    // driver player slot (0 = none); matched against a proxy's vis_owner_entnum to suppress the standing body
.float  pp_car_drv_model;  // driver team_model_byte (decoded via SH_ModelPathForTeamByte)
.float  pp_car_drv_skin;   // driver skin index
.float  pp_car_drv_up, pp_car_drv_fwd, pp_car_drv_side;   // resolved seat offsets (u)
.entity pp_driver;         // cached seated-driver render entity
.float  pp_driver_bound;   // last-bound team_model_byte + 1 (0 = unbound) — rebind on change

// Tailpipe exhaust state (client-derived from the streamed velocity; works for remote cars too).
.float  pp_exhaust_time;    // cltime of the last exhaust integration
.float  pp_exhaust_prevfwd; // last frame's forward speed (for client-derived acceleration)
.float  pp_exhaust_accum;   // fractional puff accumulator (emit 1 puff per whole unit)

// Replay of Carry_Tick's hold-point resolve (sv_physprop.qc), run CLIENT-SIDE against
// the local predicted eye + view so the held prop tracks the crosshair with ZERO ping
// lag.  Returns the slid hold CENTRE (box centre; the model origin is at the feet).
// Mirrors the server's 4-bump clip-and-slide exactly (same MOVE_NOMONSTERS world/brush
// trace, same drop-the-into-plane-component slide) so the predicted pose matches the
// authoritative one → minimal handoff error on drop.
vector(entity prop) PhysProp_PredictedHoldCenter =
{
    vector eye;
    if (csqc_present_valid)
        eye = csqc_present_origin + csqc_present_view_ofs;   // freshest previewed local eye
    else
        eye = predicted_player.origin + predicted_player.view_ofs;   // camera's own fallback

    makevectors(view_angles);   // raw view_angles — matches the server's v_angle (NOT VF_ANGLES, which adds sway/kick)
    vector hold = eye + v_forward * prop.pp_hold_dist + '0 0 1' * prop.pp_hold_z;

    // Rotated footprint — mirrors the server's Carry_Tick.  Both sides read the pose from
    // the PREVIOUS frame/tick (angles are written at the end of the update on each side),
    // so while actively rotating they can differ by one frame of mouse motion; that is a
    // sub-unit difference in a deliberately conservative bound, and it is zero whenever
    // the prop is not being rotated.  (Safe here: v_forward was already consumed by
    // `hold` above and is not read again.)
    vector boxhalf = CarryRot_RotatedHalf(prop.angles, (prop.maxs - prop.mins) * 0.5);
    // Centre offset ROTATED by the prop's pose — mirrors Carry_Tick.  Adding it along
    // world Z unconditionally put an upside-down prop a box-height too low.
    vector cur = prop.origin + CarryRot_CenterOfs(prop.angles, prop.mins, prop.maxs);
    vector tgt = hold;
    float  bump;
    for (bump = 0; bump < 4; bump = bump + 1)
    {
        tracebox(cur, '0 0 0' - boxhalf, boxhalf, tgt, MOVE_NOMONSTERS, prop);
        if (trace_startsolid)
        {
            cur = tgt;   // embedded (resting-on-floor penetration) — aim at the raw hold so it lifts out (mirror of Carry_Tick)
            break;
        }
        cur = trace_endpos;
        if (trace_fraction >= 1)
            break;
        vector rem = tgt - cur;
        tgt = cur + rem - trace_plane_normal * (rem * trace_plane_normal);
    }
    return cur;   // slid hold centre
};

// Sanity bounds on the measured stream interval.  MIN also doubles as the sample-reject floor: a
// PhysProp_KickStream queue-jump (sv_physprop.qc) deliberately sends one packet early, and letting that
// artificially short gap into the average would yank the render delay down at exactly the moment of a
// violent motion change.  MAX keeps a pathological stream from parking the prop far in the past.
const float PP_DELAY_MIN = 0.004;   // 250 Hz ceiling
const float PP_DELAY_MAX = 0.25;
const float PP_DELAY_EMA = 0.15;    // running-average weight per accepted sample
// Assumed interval before we have measured one (one 64-tick frame).  Used for at most a frame or two:
// the first snapshot early-outs on dt=0 anyway, and the second one measures the real rate.
const float PP_DELAY_DEFAULT = 0.0156;

// RENDER DELAY — how far in the past this prop is drawn.  This used to be the raw prev→cur gap, which
// made ONE number do two unrelated jobs: the lerp window AND the render delay.  That coupling is what made
// props unsmooth:
//   * the wake repair compressed the gap to catch a woken prop up quickly, which dragged the render delay
//     with it for one frame and then snapped back on the next packet;
//   * the gap is the INSTANTANEOUS last interval, so a single dropped packet doubled the delay — at 8 Hz
//     that was a small fraction of 125 ms, but at 64 Hz it is a 100% swing.
// So the delay now comes from a smoothed average of how often packets ACTUALLY arrive (pp_snap_interval,
// measured in CSQC_PhysProp_Update), while the raw gap keeps its real job as the lerp window.  The client
// cannot just read sv_physprop_stream_hz — that cvar is server-side and never sent — and measuring is
// better anyway: it adapts to packet loss and to cars, which stream far faster than free props.
//
// MUST be the single source of the delay: PhysProp_InterpFrac and PhysProp_InterpOrigin both call this.
// If they ever computed it separately and disagreed, the angle lerp would desync from the origin lerp and
// the chase cam would unglue from the car it is anchored to (see cl_main.qc's invariant comment).
float(entity e) PhysProp_RenderDelay =
{
    float d, ratio;
    if (!cvar("cl_physprop_smoothinterp"))
        return e.pp_snap_time - e.pp_snap_time_prev;     // legacy: the raw gap, exactly as before
    // Deliberately NOT falling back to the raw gap here.  This is also called from the wake repair, where
    // the raw gap IS the multi-second rest silence — substituting that would make the repair a no-op and
    // bring back the slow ooze it exists to prevent.  An assumed tick-rate interval is always safe.
    d = e.pp_snap_interval;
    if (d <= 0) d = PP_DELAY_DEFAULT;
    ratio = cvar("cl_physprop_interp_ratio");
    if (ratio < 1) ratio = 1;                            // <1 would render into the future
    d = d * ratio;
    if (d < PP_DELAY_MIN) d = PP_DELAY_MIN;
    if (d > PP_DELAY_MAX) d = PP_DELAY_MAX;
    return d;
};

// Gap above which a silence counts as a WAKE (prop stopped streaming) rather than a stream interval.
// Derived from the measured rate instead of a fixed 0.3: at 64 Hz a literal 0.3 leaves a dead band from
// 16 ms to 300 ms where a stall got no repair and the prop oozed.
float(entity e) PhysProp_WakeGap =
{
    float g;
    if (e.pp_snap_interval <= 0)
        return 0.3;                                      // unmeasured: the historical threshold
    g = e.pp_snap_interval * 8;
    if (g < 0.1) g = 0.1;
    if (g > 0.5) g = 0.5;
    return g;
};

// 2-snapshot interpolation frac: lerp prev→cur across the REAL gap between them, sampled at a render time
// that sits PhysProp_RenderDelay in the past.  Drives the angle lerp and the settle test.
float(entity e) PhysProp_InterpFrac =
{
    float dt = e.pp_snap_time - e.pp_snap_time_prev;
    float d, f;
    if (dt <= 0.0001)
        return 1;                                       // first snapshot / no prev → sit on cur
    d = PhysProp_RenderDelay(e);
    if (d <= 0.0001)
        return 1;                                       // no usable delay → sit on cur
    f = (cltime - d - e.pp_snap_time_prev) / dt;
    if (f < 0) f = 0;
    if (f > 1) f = 1;
    return f;
};

// Smoothed render ORIGIN.  In the normal case this is the 2-snapshot interpolation above; but on the
// TAIL — when the render clock has run PAST the newest snapshot because the next 64-tick packet is even
// slightly late (the render-vs-tick beat, worse at high speed) — it COASTS along the streamed velocity
// instead of clamping to cur and FREEZING-then-jumping (that freeze was the fast-car stutter).  The coast
// is bounded by cl_physprop_extrap_max so a lost packet can't run away, and the correction when the real
// packet lands is only velocity×(sub-tick jitter) — invisible vs a whole frozen frame.  For a slow/resting
// prop velocity≈0 so this is a no-op (unchanged behaviour).  Used by BOTH the car predraw and the chase-cam
// anchor (cl_main.qc) so the model and camera stay glued — never one extrapolating while the other freezes.
vector(entity e) PhysProp_InterpOrigin =
{
    float dt = e.pp_snap_time - e.pp_snap_time_prev;
    float d, target, f, extra, cap;
    if (dt <= 0.0001)
        return e.pp_snap_origin;                         // first snapshot / no prev → sit on cur
    // SAME delay accessor PhysProp_InterpFrac uses — see the note there on why this must not be
    // recomputed independently.
    d = PhysProp_RenderDelay(e);
    if (d <= 0.0001)
        return e.pp_snap_origin;
    target = cltime - d;
    f = (target - e.pp_snap_time_prev) / dt;
    if (f < 0) f = 0;
    if (f <= 1)
        return e.pp_snap_origin_prev + (e.pp_snap_origin - e.pp_snap_origin_prev) * f;
    // tail: coast on the streamed velocity for up to cl_physprop_extrap_max instead of freezing at cur.
    // `extra` is clamped, so even if f lands far outside [0,1] (tiny dt against an independent delay)
    // the coast stays bounded — the decoupling can never turn into an unbounded jump.
    extra = target - e.pp_snap_time;
    cap = cvar("cl_physprop_extrap_max"); if (cap <= 0) cap = 0.05;
    if (extra > cap) extra = cap;
    return e.pp_snap_origin + e.velocity * extra;
};

// Client half of the prop rider-carry accessor (declared in sh_customdefs.qc; the SSQC half returns the
// live .velocity).  This returns the DERIVATIVE of the very interpolation PhysProp_InterpOrigin poses the
// collision hull with — deliberately NOT the streamed .velocity.
//
// Why it matters: the hull sits at cltime - RenderDelay.  If the carry integrated .velocity (the value at
// the newest snapshot) the player would advance at a slightly different rate than the surface beneath
// them, and would visibly slide off the back of a moving prop over a few hundred ms.  Differentiating the
// same piecewise-linear curve makes the two displacements identical by construction.
//
// This is NOT the origin-delta anti-pattern the train carry warns about (sh_pmove.qc): that concerns
// `ent.origin - prev_origin`, which is zero on most substeps because the entity only moves at render
// rate.  This is an analytic derivative — constant across a whole snapshot window, so it stays smooth at
// any pmove rate.
vector(entity prop) PhysProp_ContactVelocity =
{
    float dt = prop.pp_snap_time - prop.pp_snap_time_prev;
    if (dt <= 0.0001)
        return prop.velocity;                      // first snapshot — nothing to differentiate
    float f = (cltime - PhysProp_RenderDelay(prop) - prop.pp_snap_time_prev) / dt;
    if (f < 0)
        return '0 0 0';                            // parked before the window opened
    if (f > 1)
        return prop.velocity;                      // tail: the pose is coasting on the streamed velocity
    return (prop.pp_snap_origin - prop.pp_snap_origin_prev) * (1 / dt);
};

// Shortest-arc per-component angle lerp (handles 0/360 wrap) — client copy of Carry_AnglesLerp.
vector(vector a, vector b, float f) PhysProp_AnglesLerp =
{
    vector r;
    float d;
    d = b_x - a_x; d = d - 360 * floor((d + 180) / 360); r_x = a_x + d * f;
    d = b_y - a_y; d = d - 360 * floor((d + 180) / 360); r_y = a_y + d * f;
    d = b_z - a_z; d = d - 360 * floor((d + 180) / 360); r_z = a_z + d * f;
    return r;
};

// ============================================================
//  prop_car spinning/steering wheels — 4 cached render entities glued to the interpolated chassis.
//  Position replicates Car_WheelLocal + Car_PhysStep (sh_vehicle_phys.qc, server-only); spin is
//  integrated locally from the streamed velocity; steer comes from the networked car_steer byte.
// ============================================================

// Client copy of Car_WheelLocal's AUTO path (per-wheel override strings aren't networked — the outrun
// car uses none).  Returns the wheel mount in the chassis (forward,right,up) basis. 0=FL 1=FR 2=RL 3=RR.
vector(entity car, float i) Car_WheelMountLocal =
{
    float hx = car.pp_car_base * 0.5, hy = car.pp_car_track * 0.5;   // networked = the physics spacing (wheel_base key honoured)
    float fwd, rgt;
    if      (i == 0) { fwd =  hx; rgt = -hy; }
    else if (i == 1) { fwd =  hx; rgt =  hy; }
    else if (i == 2) { fwd = -hx; rgt = -hy; }
    else             { fwd = -hx; rgt =  hy; }
    return [fwd, rgt, car.mins_z - car.pp_car_drop];   // z = box bottom - drop (matches Car_WheelLocal)
};

// ---------------------------------------------------------------------------
// Per-frame cvar cache for the CAR RENDER path (Car_DrawWheels / _DrawDriver / _DrawExhaust).
// Refreshed once per frame from CSQC_UpdateViewFrameBegin (cl_main.qc), same pattern as
// bh_cache_* (cl_bulletholes.qc) and PlayerVis_RefreshCorpseCull (cl_player.qc).
//
// These were read with cvar() PER CAR PER FRAME — and cl_car_wheel_steer was read inside the
// 4-wheel loop, so twice more again.  ~10 string-hash lookups per car per frame for values
// that change only when someone types in the console (or drags the F3 tuning panel).
// ---------------------------------------------------------------------------
float carc_meshpitch, carc_meshroll, carc_model_yaw;
float carc_wheel_radius, carc_wheel_spin, carc_wheel_z, carc_wheel_fwd, carc_wheel_steer;
float carc_wheels_on;

void() Car_RefreshCvarCache =
{
    carc_meshpitch    = cvar("r_meshpitch");  if (carc_meshpitch == 0) carc_meshpitch = -1;
    carc_meshroll     = cvar("r_meshroll");   if (carc_meshroll  == 0) carc_meshroll  =  1;
    carc_model_yaw    = cvar("sv_car_model_yaw");
    carc_wheel_radius = cvar("cl_car_wheel_radius"); if (carc_wheel_radius <= 0) carc_wheel_radius = 12.64;
    carc_wheel_spin   = cvar("cl_car_wheel_spin");
    carc_wheel_z      = cvar("cl_car_wheel_z");
    carc_wheel_fwd    = cvar("cl_car_wheel_fwd");
    carc_wheel_steer  = cvar("cl_car_wheel_steer");
    carc_wheels_on    = cvar("cl_car_wheels");
};

void(entity car) Car_DrawWheels =
{
    if (!carc_wheels_on)           return;
    if (car.pp_car_wheelidx <= 0)  return;   // no wheelmodel key = wheels baked into the chassis

    // Lazy-spawn + cache 4 wheel render ents (weapon-attach pattern, cl_player.qc).
    if (!car.pp_wheel0)
    {
        car.pp_wheel0 = spawn();  car.pp_wheel1 = spawn();
        car.pp_wheel2 = spawn();  car.pp_wheel3 = spawn();
        car.pp_wheel0.classname = car.pp_wheel1.classname =
        car.pp_wheel2.classname = car.pp_wheel3.classname = "car_wheel";
    }
    if (car.pp_wheel1.modelindex != car.pp_car_wheelidx)   // (re)bind on first use / change (a RIGHT wheel gates it)
    {
        setmodelindex(car.pp_wheel1, car.pp_car_wheelidx);   // FR (right)
        setmodelindex(car.pp_wheel3, car.pp_car_wheelidx);   // RR (right)
        // LEFT wheels use the mirrored "<name>_l.iqm" so the rim faces OUTWARD on that side.
        string rp = modelnameforindex(car.pp_car_wheelidx);
        float  e  = strlen(rp) - 4;   // 4-char extension (.iqm / .mdl / .md3)
        string lp = strcat(substring(rp, 0, e), "_l", substring(rp, e, 4));
        setmodel(car.pp_wheel0, lp);   // FL (left, mirrored)
        setmodel(car.pp_wheel2, lp);   // RL (left, mirrored)
    }

    // Chassis basis at the INTERPOLATED pose (car.origin/car.angles were just set by the predraw).
    // Reproduces Car_PhysStep (sh_vehicle_phys.qc:150-176): pscale = r_meshpitch for alias/IQM cars,
    // build the TRUE basis with NO model_yaw (cU stays true), then rotate fwd/right by model_yaw.
    float rmp = carc_meshpitch;
    float rmr = carc_meshroll;
    float myaw = car.pp_car_myaw + carc_model_yaw;
    makevectors([car.angles_x * rmp, car.angles_y, car.angles_z * rmr]);
    vector tF = v_forward, tR = v_right, cU = v_up;
    float myr = myaw * 0.0174533, mc = cos(myr), ms = sin(myr);
    vector cF = tF * mc - tR * ms;
    vector cR = tR * mc + tF * ms;
    vector cgofs = tF * ((car.mins_x + car.maxs_x) * 0.5) - tR * ((car.mins_y + car.maxs_y) * 0.5);

    // Integrate the shared wheel roll from forward speed (v·cF).  dt clamped so a rest-gap can't spike it.
    float rad = carc_wheel_radius;   // world tyre radius at car.scale 1 (rolling radius)
    // rest/travel come from the NETWORKED resolved per-car values (pp_car_rest/travel) — NOT the global cvars.
    // The physics tunes these per-car (carset / FGD); reading the cvar left the visual wheels drooping on the
    // stale global (10/12) so they stretched 20-40u when the car was tuned to 1/1.  Use the networked value
    // DIRECTLY (0 is a legit tune now — ride height / travel can be 0); clamp only negatives.
    float rest   = car.pp_car_rest;   if (rest   < 0) rest   = 0;
    float travel = car.pp_car_travel; if (travel < 0) travel = 0;
    float cscale = (car.scale > 0) ? car.scale : 1;
    float rworld = rad * cscale;   // world-space tyre radius (placement + model render), scales with the car
    float dt = cltime - car.pp_wheel_time;
    if (dt < 0 || dt > 0.5) dt = 0;
    car.pp_wheel_time = cltime;
    float fwdspeed = car.velocity * cF;
    car.pp_wheel_spin += carc_wheel_spin * (fwdspeed * dt) / (6.283185 * rad) * 360;
    car.pp_wheel_spin = car.pp_wheel_spin - floor(car.pp_wheel_spin / 360) * 360;

    float zoff   = carc_wheel_z;
    float fwdofs = carc_wheel_fwd + car.pp_car_fwd;   // fore/aft nudge: live cvar + per-car wheel_fwd key
    float i;
    entity w;
    for (i = 0; i < 4; i = i + 1)
    {
        if      (i == 0) w = car.pp_wheel0;
        else if (i == 1) w = car.pp_wheel1;
        else if (i == 2) w = car.pp_wheel2;
        else             w = car.pp_wheel3;

        // Mount = top of the strut at the collision-box bottom.  Cast the suspension ray straight down
        // (along the car's up) and sit the tyre ON the ground (centre one radius above contact), but CAP the
        // extension by rest+travel so a stiff/low-travel tune tucks the wheels instead of stretching them.
        vector lofs  = Car_WheelMountLocal(car, i);
        vector mount = car.origin + cgofs + cF * (lofs_x + fwdofs) + cR * lofs_y + cU * lofs_z;   // zoff applied post-solve
        traceline(mount + cU * 4, mount - cU * (rest + rworld), MOVE_NOMONSTERS, car);
        float ext;
        if (trace_fraction < 1)
        {
            ext = (mount - trace_endpos) * cU - rworld;   // strut extension: centre one radius above the contact
            // NO `ext<0 → 0` clamp: if the visual tyre radius exceeds the ride-height gap the centre floats
            // ABOVE the mount so the tyre BOTTOM still sits exactly on the ground (was sinking through it).
            if (ext > rest) ext = rest;                   // droop CAPPED at ride_height — compression_travel is
                                                          // UP-room (landing squash), NOT extra droop, so the wheel
                                                          // never extends past the ride height (was rest+travel).
        }
        else
            ext = rest;                                   // airborne: droop to ride_height, no further
        vector wc = mount - cU * ext + cU * zoff;         // zoff (cl_car_wheel_z) offsets the wheel in BOTH states
        setorigin(w, wc);

        // Orientation, done DETERMINISTICALLY: the wheel MODEL's forward (+X) IS its axle (built that way),
        // so we point the model forward along the car's RIGHT (cR), steered about the car up (cU) on the
        // front pair.  The spin is a ROLL about that axle, composed as a REAL 3-D rotation BEFORE the Euler
        // decomposition (NOT a scalar add onto va_z).  Rotate the up-reference cU about the axle by the spin
        // angle (Rodrigues), then let ONE vectoangles derive all three angles of the fully-spun pose.  This
        // is bank-independent: the target pose is the flat wheel rigidly spun about its own axle at ANY
        // pitch/roll/steer, so the r_meshpitch/roll round-trip applies to a coherent orientation and can't
        // invert the roll (the old `va_z + spin` add leaked the car's bank into va_z → spin reversed on a
        // slope).  Since axle⟂cU the Rodrigues (1-cos) term vanishes.  No gimbal pole: axle≈cR stays
        // roughly horizontal.  Base spin/steer signs stay cvar-lockable (cl_car_wheel_spin / cl_car_wheel_steer).
        // SPIN SIGN is the SAME for BOTH sides: all 4 wheels share one world angular velocity (same axle cR),
        // so they render the same roll phase.  The mirrored `wheel_l.iqm` only flips the RIM to face outward —
        // it does NOT reverse the roll-about-axle (verified empirically: the old `(left?-1:1)` left the RIGHT
        // wheels spinning backward while the left looked right).  cl_car_wheel_spin still flips both globally.
        float sr = (i < 2) ? (car.pp_car_steer * carc_wheel_steer * 0.0174533) : 0;
        vector axle = cR * cos(sr) + cF * sin(sr);          // unit, and ⟂ cU (cR⟂cU, cF⟂cU)

        float spinrad = -car.pp_wheel_spin * 0.0174533;
        float cs = cos(spinrad), sn = sin(spinrad);
        vector cw;                                          // cw = axle × cU  (manual cross — no builtin dep)
        cw_x = axle_y*cU_z - axle_z*cU_y;
        cw_y = axle_z*cU_x - axle_x*cU_z;
        cw_z = axle_x*cU_y - axle_y*cU_x;
        vector uref = cU * cs + cw * sn;                    // Rodrigues; (1-cos) term = 0 because axle⟂cU

        // vectoangles() ALREADY bakes in r_meshpitch/roll (engine PF_vectoangles → VectorAngles(...,true):
        // pitch*=r_meshpitch, roll*=r_meshroll), and the RENDERER applies them AGAIN (AngleVectorsMesh) —
        // the two cancel, so set .angles = va DIRECTLY.  The old `va_x * rmp` DOUBLE-applied r_meshpitch
        // (-1) → negated the wheel PITCH: invisible on flat (a level axle has pitch 0) but INVERTED the
        // vertical tilt once the car banks → "wheels bank the wrong way."  (rmr=1, so the roll multiply was
        // a no-op; spin, baked into uref above, is unchanged.)
        vector va = vectoangles(axle, uref);
        w.angles = va;
        w.scale = cscale * (rad / 12.64);   // scale the MODEL by cl_car_wheel_radius (12.64 = baked radius) so it
                                        // renders at rworld — Vis-radius now RESIZES the tyre instead of just
                                        // nudging its centre up.  Bottom stays on the ground (centre at rworld).
        w.skin  = car.skin;                            // livery: dirty car → dirty wheels (needs wheel_<N>.skin)
        addentity(w);                                  // explicit draw from the car predraw — NO drawmask
    }
};

// ============================================================
//  Seated car driver — one render entity glued to the interpolated chassis (like the wheels), so it's
//  smooth (no server-tick jitter) and visible in first person.  The server keeps the real player edict
//  hidden (alpha -1) and its standing visual proxy is suppressed (Car_IsDriverSlot below), so there is
//  exactly ONE body: this one.  Non-solid (a render entity), so it never fights the ground.
// ============================================================
void(entity car) Car_DrawDriver =
{
    // Free field test FIRST — the overwhelmingly common case is a car with nobody in it, and
    // the cvar() hash lookup used to run for every one of them every frame before proving it.
    if (car.pp_car_drv_ent <= 0) return;   // no seated driver networked (or sv_car_show_driver 0)
    if (!cvar("cl_car_driver")) return;

    if (!car.pp_driver)
    {
        car.pp_driver = spawn();
        car.pp_driver.classname = "car_driver";
    }
    // (re)bind the model when the networked team_model_byte changes (encode 0 as unbound via +1).
    if (car.pp_driver_bound != car.pp_car_drv_model + 1)
    {
        setmodel(car.pp_driver, SH_ModelPathForTeamByte(car.pp_car_drv_model));
        car.pp_driver_bound = car.pp_car_drv_model + 1;
    }
    car.pp_driver.skin  = car.pp_car_drv_skin;
    car.pp_driver.frame = cvar("cl_car_driver_frame");   // static seated pose (112 = crouch, no-IK)
    car.pp_driver.scale = 1;

    // Chassis basis at the interpolated pose — same construction as Car_DrawWheels (kept inline so the
    // confirmed-good wheel code stays untouched).  cU/cF/cR are the banked chassis axes.
    float rmp = carc_meshpitch;
    float rmr = carc_meshroll;
    float myaw = car.pp_car_myaw + carc_model_yaw;
    makevectors([car.angles_x * rmp, car.angles_y, car.angles_z * rmr]);
    vector tF = v_forward, tR = v_right, cU = v_up;
    float myr = myaw * 0.0174533, mc = cos(myr), ms = sin(myr);
    vector cF = tF * mc - tR * ms;
    vector cR = tR * mc + tF * ms;
    vector cgofs = tF * ((car.mins_x + car.maxs_x) * 0.5) - tR * ((car.mins_y + car.maxs_y) * 0.5);

    // Seat point tracks the banked chassis; the body BANKS WITH the car by inheriting the car's pitch/roll
    // (same raw angles → the engine's r_meshpitch/roll treats the driver exactly like the car), with the
    // model_yaw added to face the nose.  The mapper dials seat_up/_fwd/_side per car (FGD) or via sv_car_seat_*.
    vector org = car.origin + cgofs
               + cU * car.pp_car_drv_up
               + cF * car.pp_car_drv_fwd
               + cR * car.pp_car_drv_side;
    setorigin(car.pp_driver, org);
    car.pp_driver.angles = [car.angles_x, car.angles_y + myaw, car.angles_z];
    addentity(car.pp_driver);              // explicit — renders in BOTH first and third person
};

// Resolved "weapons.metal_impact" effect id for the exhaust, cached once it comes back VALID
// (NON-ZERO — a particle-script effect id is NEGATIVE, see Car_DrawExhaust).  Never caches
// a failure.
float g_car_exhaust_eid;
// SAME effect, same caching rule, for the PROP contact smoke (CSQC_EVENT_PHYSPROP_IMPACT
// buckets 0/1/2 in cl_main.qc, which compiles later).  A separate global so a failed
// resolve in one path can never poison the other.
float g_prop_smoke_eid;

// Tailpipe exhaust — a metal-impact smoke puff (the one bullets use on metal) re-emitted each frame at
// the recomputed tailpipe world-point, so it tracks the interpolated car with zero lag.  Rate scales with
// speed + client-derived acceleration (so it works for remote cars, which have no networked throttle).
void(entity car) Car_DrawExhaust =
{
    if (!cvar("cl_car_exhaust")) return;

    // PARKED FAST-OUT — hoisted above the effect resolve + basis math below.  The engine is
    // "on" only while driven or still coasting, and the old code proved that at the BOTTOM of
    // the function, after paying for a particleeffectnum() string lookup, ~10 cvar reads, a
    // makevectors and a full Rodrigues basis solve — every frame, for every parked car.
    // (The velocity read is free; everything it skips is not.)
    if (car.pp_car_drv_ent <= 0)
        if (vlen(car.velocity) < 20)
        {
            car.pp_exhaust_accum = 0;
            car.pp_exhaust_time  = cltime;   // keep the dt anchor fresh so the first driven frame
                                             // sees a small dt instead of a seed-and-discard gap
            return;
        }

    // Resolve the smoke id EXACTLY like the working bullet/button emitters (cl_main.qc:2081) — Impact_ResolveAll
    // first, reuse impact_effect_metal, fall back to particleeffectnum.  The resolved id is CACHED once valid:
    // a FAILED id is still never cached (a -1 from an early frame, before the particle cfg was ready, used to
    // stick forever = "no smoke"), but re-running the string lookup every frame after it has succeeded bought
    // nothing.  metal_impact is a "+"-append-only effect so impact_effect_metal itself is 0 (query-validated)
    // → the particleeffectnum fallback is the one that actually yields a usable slot.
    //
    // ONLY 0 IS FAILURE.  particleeffectnum returns <0 for a client-side (particle-script)
    // effect and >0 only for a server precache — pr_csqc.c:3775-3777.  Every id this mod
    // ever resolves is therefore NEGATIVE, so the cache test must be `== 0` (with `<= 0` it
    // was always true and the string lookup ran every frame anyway, defeating the cache),
    // and -1 is a valid first client slot, not an error code.
    float eid = g_car_exhaust_eid;
    if (eid == 0)
    {
        Impact_ResolveAll();
        eid = impact_effect_metal;
        if (eid == 0) eid = particleeffectnum("weapons.metal_impact");
        if (eid == 0) return;
        g_car_exhaust_eid = eid;   // only ever cache a VALID id
    }

    // Chassis basis (same as the driver/wheels).
    float rmp = carc_meshpitch;
    float rmr = carc_meshroll;
    float myaw = car.pp_car_myaw + carc_model_yaw;
    makevectors([car.angles_x * rmp, car.angles_y, car.angles_z * rmr]);
    vector tF = v_forward, tR = v_right, cU = v_up;
    float myr = myaw * 0.0174533, mc = cos(myr), ms = sin(myr);
    vector cF = tF * mc - tR * ms;
    vector cR = tR * mc + tF * ms;
    vector cgofs = tF * ((car.mins_x + car.maxs_x) * 0.5) - tR * ((car.mins_y + car.maxs_y) * 0.5);

    // Client-derived forward speed + acceleration (dt clamped like the wheel spin so a rest-gap can't spike).
    float dt = cltime - car.pp_exhaust_time;
    car.pp_exhaust_time = cltime;
    float fwdspeed = car.velocity * cF;
    if (dt <= 0 || dt > 0.5) { car.pp_exhaust_prevfwd = fwdspeed; return; }   // first frame / big gap: seed only
    float accel = (fwdspeed - car.pp_exhaust_prevfwd) / dt;
    car.pp_exhaust_prevfwd = fwdspeed;
    float speed = vlen(car.velocity);
    // (The "engine is on" parked test that used to live here is now the fast-out at the top
    //  of this function, so a parked car never reaches the resolve/basis work above.)

    // Emit rate: a steady idle wisp plus a load term from speed and positive acceleration (blip → more smoke).
    float load = speed / 400;
    if (accel > 0) load += accel / 500;
    if (load > 1.5) load = 1.5;
    float rate = 12 + load * 40;       // ~12/s idle → ~72/s under hard accel (visible)
    car.pp_exhaust_accum += rate * dt;

    // Tailpipe = a pure offset from the car ORIGIN along the chassis basis (dialable per install).  cgofs has
    // no Z, and the origin sits at GROUND level, so cl_car_exhaust_z must stay POSITIVE or the puff is buried.
    vector pipe = car.origin + cgofs
                + cF * cvar("cl_car_exhaust_x")
                + cR * cvar("cl_car_exhaust_y")
                + cU * cvar("cl_car_exhaust_z");
    vector puffvel = cF * (-1 * (40 + speed * 0.35)) + cU * 10;   // trails rearward + drifts UP so it's seen

    while (car.pp_exhaust_accum >= 1)
    {
        car.pp_exhaust_accum -= 1;
        pointparticles(eid, pipe, puffvel, 1);
    }
};

// Count of car mirrors that currently have a seated driver (maintained in CSQC_PhysProp_Update, and
// decremented in CSQC_Ent_Remove for a car removed while driven).  Lets Car_IsDriverSlot skip its walk
// entirely in the common case (nobody driving).
float g_car_driver_count;

// ---------------------------------------------------------------------------
// CAR CHAIN — a dedicated linked list of just the car mirrors.
//
// EVERY physics prop (barrel, can, cabinet, prop_physics, prop_car) shares the classname
// "phys_files", so `find(world, classname, "phys_files")` walks the WHOLE CSQC entity list
// doing a string compare per entity, and then throws away all the non-cars.  Several
// per-frame loops did exactly that (cl_vehicle_sound.qc ×3, cl_main.qc's camera pass,
// Car_IsDriverSlot) — i.e. on a prop-dense map, thousands of compares per frame to find the
// 0-8 cars.  This is the client-side twin of the server's player_chain_head (sv_physprop.qc).
//
// Linked on the first snapshot that reports is_car (guarded by pp_car_linked, since
// CSQC_PhysProp_Update runs per snapshot), unlinked in CSQC_Ent_Remove.  Use .pp_car_next —
// NOT .chain, which findradius/findchain reuse as scratch.
// ---------------------------------------------------------------------------
entity g_car_chain_head;

void(entity car) Car_ChainLink =
{
    if (car.pp_car_linked)
        return;
    car.pp_car_next  = g_car_chain_head;
    g_car_chain_head = car;
    car.pp_car_linked = TRUE;
};

void(entity car) Car_ChainUnlink =
{
    if (!car.pp_car_linked)
        return;
    if (g_car_chain_head == car)
        g_car_chain_head = car.pp_car_next;
    else
    {
        entity p = g_car_chain_head;
        while (p)
        {
            if (p.pp_car_next == car)
            {
                p.pp_car_next = car.pp_car_next;
                break;
            }
            p = p.pp_car_next;
        }
    }
    car.pp_car_next   = world;
    car.pp_car_linked = FALSE;
};

// ---------------------------------------------------------------------------
// ACTIVE-PROP CHAIN — just the props that are currently MOVING.
//
// Same idiom and rationale as the car chain above, for a different consumer: the prediction hull
// relink (PhysProp_RelinkHullsForPrediction).  A settled prop must never be walked — it is already
// parked on its authoritative origin with zero velocity, so relinking it is both pointless and
// actively harmful (its predraw has unhooked, so nothing would put it back).
//
// Linked on the first snapshot that reports motion, unlinked on the settle edge and on removal.
// ---------------------------------------------------------------------------
entity g_pp_active_head;

void(entity p) PhysProp_ActiveLink =
{
    if (p.pp_active_linked)
        return;
    p.pp_active_next  = g_pp_active_head;
    g_pp_active_head  = p;
    p.pp_active_linked = TRUE;
};

void(entity p) PhysProp_ActiveUnlink =
{
    if (!p.pp_active_linked)
        return;
    if (g_pp_active_head == p)
        g_pp_active_head = p.pp_active_next;
    else
    {
        entity q = g_pp_active_head;
        while (q)
        {
            if (q.pp_active_next == p)
            {
                q.pp_active_next = p.pp_active_next;
                break;
            }
            q = q.pp_active_next;
        }
    }
    p.pp_active_next   = world;
    p.pp_active_linked = FALSE;
};

// ---------------------------------------------------------------------------
// ALL-PROPS CHAIN + RENDER CULL SWEEP
//
// Every phys_files mirror sets .drawmask = MASK_ENGINE (CSQC_PhysProp_Update) and until now there
// was no cull of ANY kind on it — no distance, no PVS, no LOD.  addentities(MASK_ENGINE) therefore
// hands the engine every prop on the map every frame, and BE_GenModelBatches walks the lot.  On a
// prop-dense open map that is the largest single thing the mod hands the renderer: fy_killzone is
// 66 props / ~272k triangles, all of them also shadow casters.
//
// Deliberately NOT done in .predraw.  A settled prop UNHOOKS its predraw (see the settle branch of
// CSQC_PhysProp_Predraw, "400 resting props cost ~0") precisely so resting props cost no QC call at
// all; re-hooking one per prop per frame to run a cull would spend more than the cull saves.
//
// Instead a sweep runs at PP_CULL_INTERVAL (NOT per frame) and toggles .drawmask.  66 props at
// 10 Hz is ~660 tests/second — nothing — and the per-frame cost stays exactly zero.  A prop with
// drawmask 0 is skipped by addentities, so it never reaches cl_visedicts, which also drops it out
// of the shadow caster walks (those iterate cl_visedicts raw, with no PVS test of their own).
//
// Linked on the first snapshot, unlinked in CSQC_Ent_Remove.
// ---------------------------------------------------------------------------
entity g_pp_all_head;

const float PP_CULL_INTERVAL = 0.1;   // 10 Hz.  Fast enough that a sprinting player never outruns
                                      // the sweep, slow enough that the sweep itself is free.
const float PP_CULL_HYST     = 192;   // distance hysteresis, applied BOTH ways, so a prop sitting
                                      // exactly on the radius cannot flicker in and out.

float pp_cull_next_time;

void(entity p) PhysProp_AllLink =
{
    if (p.pp_all_linked)
        return;
    p.pp_all_next   = g_pp_all_head;
    g_pp_all_head   = p;
    p.pp_all_linked = TRUE;
};

void(entity p) PhysProp_AllUnlink =
{
    if (!p.pp_all_linked)
        return;
    if (g_pp_all_head == p)
        g_pp_all_head = p.pp_all_next;
    else
    {
        entity q = g_pp_all_head;
        while (q)
        {
            if (q.pp_all_next == p)
            {
                q.pp_all_next = p.pp_all_next;
                break;
            }
            q = q.pp_all_next;
        }
    }
    p.pp_all_next   = world;
    p.pp_all_linked = FALSE;
};

// Undo whatever the sweep did to this prop.  Split out so the "culling was turned off at runtime"
// path and the per-prop "came back into view" path can never drift apart — turning the cvars off
// mid-game MUST restore every prop, or they stay invisible until the next map.
void(entity e) PhysProp_CullShow =
{
    if (e.pp_cull_hidden)
    {
        e.drawmask       = MASK_ENGINE;
        e.pp_cull_hidden = FALSE;
    }
    if (e.pp_cull_noshadow)
    {
        // Clear ONLY our own bit — never assume we own the whole field.
        e.effects          = e.effects - (e.effects & EF_NOSHADOW);
        e.pp_cull_noshadow = FALSE;
    }
};

void() PhysProp_CullSweep =
{
    if (cltime < pp_cull_next_time)
        return;
    pp_cull_next_time = cltime + PP_CULL_INTERVAL;

    // Cvars are read HERE, at 10 Hz — never per frame.  This is the whole point of the sweep.
    float use_pvs    = cvar("r_props_pvscull");
    float maxdist    = cvar("r_props_maxdist");
    float shadowdist = cvar("r_props_shadowdist");

    vector eye = getproperty(VF_ORIGIN);

    entity e     = g_pp_all_head;
    float  guard = 0;
    while (e)
    {
        guard = guard + 1;
        if (guard > 4096) break;      // paranoia: a corrupt link must never spin the frame

        // Never cull a car (its predraw stays hooked even when parked so a parked car still draws
        // its wheels), a prop somebody is carrying, or a prop that is currently MOVING — a moving
        // prop is client-predicted and few in number (0-5), so culling it buys nothing and risks
        // the hull and the model disagreeing.
        if (e.pp_is_car || e.pp_carrier > 0 || e.pp_active_linked)
        {
            PhysProp_CullShow(e);
            e = e.pp_all_next;
            continue;
        }

        float hide     = FALSE;
        float noshadow = FALSE;

        if (maxdist > 0 || use_pvs || shadowdist > 0)
        {
            // Measure to the prop's CENTRE, not its origin: a tall prop's origin sits at its base,
            // which would bias every distance test by its own height.
            vector c = e.origin + (e.mins + e.maxs) * 0.5;
            float  d = vlen(c - eye);

            if (maxdist > 0)
            {
                // Hysteresis: a hidden prop must come well INSIDE the radius before it is shown,
                // and a shown prop must go well OUTSIDE before it is hidden.
                float lim = maxdist + (e.pp_cull_hidden ? (0 - PP_CULL_HYST) : PP_CULL_HYST);
                if (d > lim)
                    hide = TRUE;
            }

            // checkpvs is fail-safe (reports visible when the map has no vis data), so this can
            // never hide a prop that is actually in your line of sight.
            if (!hide && use_pvs && !checkpvs(eye, e))
                hide = TRUE;

            // Same hysteresis as the hide test above, keyed off this test's OWN state bit.
            // Without it a prop hovering near the radius flips EF_NOSHADOW on and off at the
            // sweep rate (10Hz) as you walk, and a shadow popping in and out is far more
            // noticeable than one that is simply absent.  The hide test got this treatment
            // when it was written and this one did not, which was an oversight, not a
            // judgement that shadows need it less.
            if (!hide && shadowdist > 0)
            {
                float slim = shadowdist + (e.pp_cull_noshadow ? (0 - PP_CULL_HYST) : PP_CULL_HYST);
                if (d > slim)
                    noshadow = TRUE;
            }
        }

        if (hide)
        {
            if (!e.pp_cull_hidden)
            {
                e.drawmask       = 0;
                e.pp_cull_hidden = TRUE;
            }
        }
        else
        {
            // ONE restore path, shared with the exempt-prop branch above and with the
            // "cvars turned off mid-game" case.  This used to be re-implemented inline here,
            // which is exactly the drift PhysProp_CullShow's comment promises to prevent.
            PhysProp_CullShow(e);
            // Shadow budgeting only matters for props we are actually drawing.
            if (noshadow)
            {
                e.effects          = e.effects | EF_NOSHADOW;
                e.pp_cull_noshadow = TRUE;
            }
        }

        e = e.pp_all_next;
    }
};

// Re-pose every MOVING prop's collision hull immediately before the client runs prediction.
//
// The hull is otherwise positioned ONLY by CSQC_PhysProp_Predraw, which runs from addentities at
// RENDER rate — so the pmove traces of frame N collide with the pose predraw left at frame N-1.
// Against a continuously-moving player that reads as a staircase, and it is the shake that
// PM_SoftDepenetrate's comments already describe.  Re-posing here costs one setorigin per MOVING
// prop per frame (typically 0-5) and puts the hull exactly where this frame's render will draw it.
//
// Deliberately the SAME render-delayed pose the predraw uses, not an extrapolation to "now".  Undoing
// the delay would match the server more closely but would visibly separate the hull from the model —
// a barrel falling at 400 u/s would put the player's feet ~6 qu above where it is drawn.  The residual
// disagreement with the server is left to the carry (which is relative, so it cancels) and to the
// reconcile filter.  cl_physprop_hull_mode 0 restores the old render-rate-only behaviour for A/B.
void() PhysProp_RelinkHullsForPrediction =
{
    if (!cvar("cl_physprop_hull_mode"))
        return;

    entity e = g_pp_active_head;
    float guard = 0;
    while (e)
    {
        guard = guard + 1;
        if (guard > 256) break;          // paranoia: never let a corrupt link spin the frame
        if (e.solid != SOLID_NOT)
        {
            // angles BEFORE setorigin: linking only recomputes the ROTATED broadphase AABB with the
            // angles set at that moment (engine Patch 53/59) — the same ordering the reader documents.
            e.angles = PhysProp_AnglesLerp(e.pp_snap_angles_prev, e.pp_snap_angles,
                                           PhysProp_InterpFrac(e));
            setorigin(e, PhysProp_InterpOrigin(e));
        }
        e = e.pp_active_next;
    }
};

// Is this player slot the seated driver of ANY car mirror?  Called from the visual-proxy predraw to suppress
// a driver's standing body — the seated model is drawn by Car_DrawDriver instead, so there's no double.
float(float entnum) Car_IsDriverSlot =
{
    if (entnum <= 0)             return FALSE;
    if (g_car_driver_count == 0) return FALSE;   // O(1) fast path: no drivers → no scan
    entity e = g_car_chain_head;                 // cars only — not every phys_files prop
    while (e)
    {
        if (e.pp_car_drv_ent == entnum)
            return TRUE;
        e = e.pp_car_next;
    }
    return FALSE;
};

// All per-frame car render extras, driven from the 3 predraw branches below.
void(entity car) Car_DrawExtras =
{
    Car_DrawWheels(car);
    Car_DrawDriver(car);
    Car_DrawExhaust(car);
};

float() CSQC_PhysProp_Predraw =
{
    // CLIENT-SIDE PREDICTION: if the LOCAL player is the carrier and we're in steady
    // carry (NOT the server grab pull-in), drive the prop's pose from the local view
    // every render frame — zero ping lag, no 64-vs-fps beat, because nothing here waits
    // on the server.  The streamed snapshot is still ingested (anchored) but not drawn.
    if (predicted_player && predicted_player.pm_carrying
        && self.pp_carrier == player_localentnum
        && self.pp_phase  == PP_PHASE_STEADY)
    {
        vector center = PhysProp_PredictedHoldCenter(self);
        // Defensive: Update seeds pp_rel_* on the first held snapshot, so this should never
        // fire — but an unseeded basis would hand vectoangles a zero vector.
        if (self.pp_rel_fwd * self.pp_rel_fwd < 0.5)
        {
            self.pp_rel_fwd = '1 0 0';
            self.pp_rel_up  = '0 0 1';
        }
        // Orientation from the LOCAL carry-frame basis composed with the live view yaw —
        // the exact mirror of Carry_Tick's recompose.  (Was a hardcoded upright pose,
        // which is why every prop looked identical however it had been lying.)  Owning
        // this client-side is what makes inspect-mode rotation lag-free.
        float pyaw0 = view_angles_y + 180;
        self.angles = CarryRot_Angles(CarryRot_FromFrame(self.pp_rel_fwd, pyaw0),
                                      CarryRot_FromFrame(self.pp_rel_up,  pyaw0));
        // centre → feet, using the pose we just applied, so the prop pivots about its
        // middle rather than swinging around its base.
        vector org = center - CarryRot_CenterOfs(self.angles, self.mins, self.maxs);
        setorigin(self, org);
        BlobShadow_Emit(self);
        addentity(self);
        if (self.pp_is_car) Car_DrawExtras(self);
        self.pp_pred_origin    = org;          // remember the predicted hand pose for the drop fade
        self.pp_pred_fwd       = CarryRot_FromFrame(self.pp_rel_fwd, pyaw0);   // and the pose, for the ANGULAR fade
        self.pp_pred_up        = CarryRot_FromFrame(self.pp_rel_up,  pyaw0);
        self.pp_was_predicting = TRUE;
        return PREDRAW_NEXT;
    }

    // Just stopped predicting (dropped / thrown / handed to another player): seed an
    // error offset = where the predicted hand had it − the authoritative pose, so the
    // render STARTS exactly in the hand (no pop) and eases onto the server pose below.
    if (self.pp_was_predicting)
    {
        self.pp_was_predicting = FALSE;
        // Seed against the pose we are about to DRAW, not the raw newest snapshot.  The next frames render
        // at PhysProp_InterpOrigin — i.e. the snapshot delayed by the render delay — so measuring the error
        // against pp_snap_origin cancels a discontinuity that is not the one the player sees, leaving a
        // residual of roughly one interval of motion.  (Legacy path keeps the old seed so the A/B is clean.)
        if (cvar("cl_physprop_smoothinterp"))
            self.pp_err_offset = self.pp_pred_origin - PhysProp_InterpOrigin(self);
        else
            self.pp_err_offset = self.pp_pred_origin - self.pp_snap_origin;
        if (vlen(self.pp_err_offset) > 128)        // teleport-sized → don't smear it
            self.pp_err_offset = '0 0 0';
        self.pp_err_cltime = cltime;
    }

    // Decaying handoff offset (eases predicted→authoritative; 0 once expired / none pending).
    vector err = '0 0 0';
    float  ang_decay = 0;    // hoisted: the ANGULAR fade below rides the same decay curve
    if (self.pp_err_cltime > 0)
    {
        float st    = cvar("cl_carry_smooth_time");
        float decay = (st > 0) ? (1 - (cltime - self.pp_err_cltime) / st) : 0;
        if (decay > 0)
        {
            err = self.pp_err_offset * decay;
            ang_decay = decay;
        }
        else
            self.pp_err_cltime = 0;
    }

    // `cl_physprop_noextrap 1` = snap straight to the newest snapshot (no interpolation), so you
    // can SEE the raw send cadence (debug toggle; default off = interpolation ON).
    if (cvar("cl_physprop_noextrap"))
    {
        setorigin(self, self.pp_snap_origin + err);
        self.angles = self.pp_snap_angles;
        BlobShadow_Emit(self);
        addentity(self);
        if (self.pp_is_car) Car_DrawExtras(self);
        return PREDRAW_NEXT;
    }

    // Interpolate between the last two snapshots, rendering one interval in the past → smooth at ANY
    // stream rate; on the tail (late packet) coast on velocity instead of freezing (PhysProp_InterpOrigin).
    float f = PhysProp_InterpFrac(self);                 // still drives the angle lerp + settle test
    org = PhysProp_InterpOrigin(self);
    setorigin(self, org + err);
    self.angles = PhysProp_AnglesLerp(self.pp_snap_angles_prev, self.pp_snap_angles, f);

    // interactive water ripple: a prop dropping into liquid makes a splash (and a wake while it
    // skims the surface).  The predraw already runs once/frame and unhooks when the prop settles,
    // so a resting prop costs nothing here.  feet/head from the prop's own bbox.
    WaterFX_Track(self, self.origin, self.origin_z + self.mins_z + 1, self.origin_z + self.maxs_z - 1);

    // ANGULAR handoff fade — the rotational twin of the `err` offset above.  Without it a
    // prop dropped mid-inspection pops from the predicted orientation to the authoritative
    // one (the origin fade alone doesn't cover angles).  Done as a BASIS blend, NOT an
    // Euler difference: subtracting angles reintroduces every wrap/gimbal case the whole
    // orientation design exists to avoid.  Usually a no-op — releasing the rotate key
    // fires a final settle-send, so by drop time the server has already converged.
    if (ang_decay > 0)
    {
        CarryRot_Axes(self.angles);
        vector aF = crot_X;
        vector aU = crot_Z;
        // >90° apart = teleport-sized (re-grab, another player took it): snap, don't smear.
        if (aF * self.pp_pred_fwd > 0)
        {
            CarryRot_Nlerp(aF, aU, self.pp_pred_fwd, self.pp_pred_up, ang_decay);
            self.angles = CarryRot_Angles(crot_oF, crot_oU);
        }
    }

    // Caught up to the newest snapshot AND at rest (+ no handoff fade / prediction pending): park
    // exactly on it and UNHOOK.  The interp has reached cur, which == the raw origin the reader
    // set, so there's no snap; and a settled prop stops relinking (400 resting props cost ~0).
    // Evaluated BEFORE the blob emit: on the settle frame we bake the persistent blob INSTEAD of
    // emitting a dynamic one — emitting both draws two coincident quads (double-dark for a frame).
    float pp_settling = 0;
    if (f >= 1 && vlen(self.velocity) < 0.5 && vlen(self.avelocity) < 0.5
        && self.pp_err_cltime <= 0 && !self.pp_was_predicting)
        pp_settling = 1;

    if (pp_settling)
        BlobShadow_BakeStatic(self);   // persistent; freed on wake (Update re-hooks) or removal
    else
        BlobShadow_Emit(self);
    addentity(self);
    if (self.pp_is_car) Car_DrawExtras(self);

    // Leave the active chain on the settle edge — for CARS TOO.  A car keeps its predraw hooked (so a
    // parked car still draws its wheels), so gating the unlink on the same !pp_is_car test as the
    // unhook below would leave every parked car in the chain forever, relinking its hull each frame.
    if (pp_settling)
        PhysProp_ActiveUnlink(self);

    if (pp_settling && !self.pp_is_car)   // cars keep the predraw hooked so a PARKED car still draws its wheels
        self.predraw = __NULL__;

    return PREDRAW_NEXT;
};

void(float isnew) CSQC_PhysProp_Update =
{
    float  mdlindex = readshort();
    vector org      = readvector();
    vector ang      = readvector();
    vector emins    = readvector();
    vector emaxs    = readvector();
    vector vel      = readvector();
    vector avel     = readvector();
    // Per-channel colormod (R,G,B) — sequential reads to guarantee wire order matches the
    // 3 WriteBytes in phys_files_Send (a single grayscale byte black-out colored props).
    vector cmod;
    cmod_x           = readbyte() * (1.0 / 255.0);
    cmod_y           = readbyte() * (1.0 / 255.0);
    cmod_z           = readbyte() * (1.0 / 255.0);
    float  skn       = readbyte();   // livery skin index (selects <model>_<N>.skin). MUST match phys_files_Send.
    float  istrimesh = readbyte();   // 1 = mirror as SOLID_PHYSICS_TRIMESH (hull) when free; 0 = box. MUST match phys_files_Send wire order.
    float  sc        = readcoord();  // Patch 70: visual + narrowphase scale. MUST match phys_files_Send (after istrimesh, before phase).
    float  phasebyte = readbyte();   // PP_PHASE_* in the low bits + PP_PHASE_DBG_BIT on top
    float  has_dbg   = (phasebyte & PP_PHASE_DBG_BIT);  // buoyancy debug payload appended at the END
    float  phase     = (phasebyte & PP_PHASE_MASK);     // MUST mask — the raw byte is no longer the phase
    float  carrier   = readbyte();   // carrier edict (0 = free)
    float  hold_dist = readcoord();  // networked hold params (remote clients lack the server cvars).
                                     // Already includes the inspect-mode push/pull offset (folded server-side).
    float  hold_z    = readcoord();
    // Carry-frame orientation — present ONLY while the prop is held.  MUST match the
    // gated 3x WriteShort block in phys_files_Send byte-for-byte.
    vector rel_ang = '0 0 0';
    float  rel_valid = 0;
    if (phase == PP_PHASE_GRABBING || phase == PP_PHASE_STEADY)
    {
        rel_ang_x = readshort() * (1 / CROT_WIRE_SCALE);
        rel_ang_y = readshort() * (1 / CROT_WIRE_SCALE);
        rel_ang_z = readshort() * (1 / CROT_WIRE_SCALE);
        rel_valid = 1;
    }
    float  is_car    = readbyte();   // 1 = prop_car/func_car (engine-sound driver). Car extras follow ONLY when set.
    float  car_steer = 0, car_wheelidx = 0, car_myaw = 0, car_base = 0, car_track = 0, car_drop = 0, car_fwd = 0;
    float  car_rest = 0, car_travel = 0;
    float  car_maxspd = 0, car_gears = 0, car_shift = 0;
    float  drv_ent = 0, drv_model = 0, drv_skin = 0, drv_up = 0, drv_fwd = 0, drv_side = 0;
    if (is_car)                       // MUST match the is-car branch in phys_files_Send byte-for-byte
    {
        car_steer    = readbyte() - 90;    // front steer angle (deg)
        car_wheelidx = readshort();        // wheel model index (0 = none)
        car_myaw     = readbyte() - 128;   // per-car model_yaw (deg)
        car_base     = readcoord();        // resolved wheelbase / track / drop / fwd (visual wheels match physics)
        car_track    = readcoord();
        car_drop     = readcoord();
        car_fwd      = readcoord();
        car_rest     = readcoord();        // resolved ride_height + compression_travel → cap the visual droop
        car_travel   = readcoord();
        car_maxspd   = readshort();        // engine-sound scale: physics redline speed / gears / shift window
        car_gears    = readbyte();
        car_shift    = readbyte() * 0.01;
        if (readbyte())                    // driver present (else a single 0 byte)
        {
            drv_ent   = readbyte();        // driver player slot
            drv_model = readbyte();        // team_model_byte
            drv_skin  = readbyte();        // skin
            drv_up    = readshort() - 4096;   // resolved seat offsets (biased signed shorts)
            drv_fwd   = readshort() - 4096;
            drv_side  = readshort() - 4096;
        }
    }

    // Buoyancy debug payload — LAST on the wire, present only when the server flagged it in the phase
    // byte (sv_debug_physprops).  Must be read unconditionally-on-the-flag and in this exact order, or
    // every subsequent entity in the datagram decodes garbage.
    float dbg_rest = 0, dbg_wet = 0, dbg_frac = 0, dbg_feq = 0, dbg_loaded = 0;
    if (has_dbg)
    {
        float dbgstate = readbyte();
        dbg_rest   = (dbgstate & PP_DBG_REST_MASK);
        dbg_wet    = (dbgstate & PP_DBG_WET_BIT);
        dbg_loaded = (dbgstate & PP_DBG_LOADED_BIT);
        dbg_frac = readbyte() * (1.0 / 255.0);
        dbg_feq  = readbyte() * (1.0 / 255.0);
    }

    // classname drives Impact_ClassifyLocal → metal spark + no bullet decal.
    self.classname = "phys_files";
    setmodelindex(self, mdlindex);
    // Patch 70: engine renders the mirror model at self.scale + scales the predicted hull/box trace
    // by it (the scaled narrowphase, like the server) — set BEFORE setsize/setorigin link below.
    self.scale = (sc > 0) ? sc : 1;

    // angles + solid MUST be set BEFORE setsize/setorigin: those link the entity
    // (World_LinkEdict), which only computes the ROTATED broadphase AABB (engine Patch
    // 53/59) when solid is a PHYSICS_BOX/TRIMESH, and with THIS frame's angles.  Setting
    // them afterward left the broadphase un-rotated / one frame stale for a tumbling box.
    self.angles    = ang;
    // SOLID_PHYSICS_BOX ONLY for PP_PHASE_FREE_SOLID → the local QC pmove + CSQC bullet
    // traces collide with the box, which the engine OBB patch (world.c World_OBBTrace)
    // rotates by the streamed angles, so you walk on / shoot the real ORIENTED shape
    // smoothly at any tilt.  SOLID_NOT while carried (GRABBING/STEADY) or in the just-
    // dropped passthrough phase (NONSOLID, server non-solid via PHYSDROP_DIM) so
    // client+server agree and the carrier doesn't shove it.
    // nettest: when FREE_SOLID, an IQM/MD3 physics prop (istrimesh) mirrors as SOLID_PHYSICS_TRIMESH
    // so the local pmove + CSQC bullets predict the SAME generated hull / decomposition the server
    // uses (PM_HullTrace == World_HullTrace) -> no rubber-band; .mdl stays the oriented box.
    if (phase == PP_PHASE_FREE_SOLID)
        self.solid = istrimesh ? SOLID_PHYSICS_TRIMESH : SOLID_PHYSICS_BOX;
    else
        self.solid = SOLID_NOT;
    setsize(self, emins, emaxs);     // broadphase AABB (the cube when free); narrowphase = mesh
    setorigin(self, org);
    self.velocity  = vel;
    self.avelocity = avel;
    self.colormod  = cmod;
    self.skin      = skn;            // livery swap: selects <model>_<N>.skin (0 = clean, 1 = dirty, …)
    self.movetype  = MOVETYPE_NONE;  // origin is wire-authoritative (no engine integrate)
    // Respect the cull sweep.  A snapshot must NOT un-hide a prop the sweep culled, or every
    // distant prop that is still streaming would flicker back in on each update and the cull
    // would silently do nothing for exactly the props it exists to drop.
    self.drawmask  = self.pp_cull_hidden ? 0 : MASK_ENGINE;   // engine renders the CSQC entity
    PhysProp_AllLink(self);          // all-props chain — the cull sweep walks this

    // Captured BEFORE the assignment below — a carrier change is what re-seeds the
    // predicted orientation (see the rel block further down).
    float carrier_changed = (self.pp_carrier != carrier);

    self.pp_phase     = phase;
    self.pp_carrier   = carrier;
    self.pp_hold_dist = hold_dist;
    self.pp_hold_z    = hold_z;

    // Buoyancy debug mirror (cl_debug_physprops overlay).  Timestamp only the rest-state EDGE so the
    // overlay can show how long it has held — a per-snapshot stamp would always read ~0.
    if (self.pp_dbg_rest != dbg_rest)
        self.pp_dbg_since = cltime;
    self.pp_dbg_rest   = dbg_rest;
    self.pp_dbg_wet    = dbg_wet;
    self.pp_dbg_frac   = dbg_frac;
    self.pp_dbg_feq    = dbg_feq;
    self.pp_dbg_loaded = dbg_loaded;

    // Carry-frame orientation.  Latch the streamed value as the SEED only on the
    // ownership edge (or the first held snapshot); once we own it, inspect mode drives
    // pp_rel_* locally and the stream is merely our own echo arriving a round-trip late,
    // so reading it back every snapshot would fight the prediction and stutter.
    // Dropping the prop clears the latch so the next grab re-seeds.
    if (rel_valid)
    {
        self.pp_snap_rel = rel_ang;
        // Re-seed on a CARRIER CHANGE as well as on a missing latch.  Clearing the latch
        // when a free-prop snapshot arrives is not sufficient on its own: a mirror kept
        // across a PVS gap (PVSF_NOREMOVE) can be dropped and re-grabbed while we never
        // see a non-carry snapshot, and would then predict the whole new carry from the
        // PREVIOUS carry's stale basis.
        if (!self.pp_rel_valid || carrier_changed)
        {
            CarryRot_Axes(rel_ang);
            self.pp_rel_fwd   = crot_X;
            self.pp_rel_up    = crot_Z;
            self.pp_rel_valid = 1;
        }
    }
    else
        self.pp_rel_valid = 0;   // free prop — re-seed on the next grab
    self.pp_is_car       = is_car;
    if (is_car)
        Car_ChainLink(self);   // first is-car snapshot puts it on the car chain (idempotent)
    self.pp_car_steer    = car_steer;
    self.pp_car_wheelidx = car_wheelidx;
    self.pp_car_myaw     = car_myaw;
    self.pp_car_base     = car_base;
    self.pp_car_track    = car_track;
    self.pp_car_drop     = car_drop;
    self.pp_car_fwd      = car_fwd;
    self.pp_car_rest     = car_rest;
    self.pp_car_travel   = car_travel;
    self.pp_car_maxspd   = car_maxspd;
    self.pp_car_gears    = car_gears;
    self.pp_car_shift    = car_shift;
    if ((self.pp_car_drv_ent > 0) != (drv_ent > 0))   // maintain the driver count for Car_IsDriverSlot's fast path
        g_car_driver_count += (drv_ent > 0) ? 1 : -1;
    self.pp_car_drv_ent   = drv_ent;
    self.pp_car_drv_model = drv_model;
    self.pp_car_drv_skin  = drv_skin;
    self.pp_car_drv_up    = drv_up;
    self.pp_car_drv_fwd   = drv_fwd;
    self.pp_car_drv_side  = drv_side;

    // Roll the previous snapshot forward, then store this authoritative one (2-snapshot interp).
    self.pp_snap_origin_prev = self.pp_snap_origin;
    self.pp_snap_angles_prev = self.pp_snap_angles;
    self.pp_snap_time_prev   = self.pp_snap_time;
    self.pp_snap_origin = org;
    self.pp_snap_angles = ang;
    self.pp_snap_time   = cltime;
    if (isnew)   // no prev to interpolate from → sit on the first snapshot (dt=0 → frac 1)
    {
        self.pp_snap_origin_prev = org;
        self.pp_snap_angles_prev = ang;
        self.pp_snap_time_prev   = cltime;
    }

    // ---- measure the stream interval (this becomes the RENDER DELAY; see PhysProp_RenderDelay) ----
    // Only REAL, plausible packet gaps count.  Three sources would poison the average and are rejected:
    //   * isnew   — dt is forced to 0 above, and this fires on every PVS RE-ENTRY (the server resends a
    //               full baseline), so it would repeatedly drag the average toward zero;
    //   * a wake  — seconds of rest silence is not a stream interval;
    //   * a kick  — PhysProp_KickStream jumps the queue on shoot/blast/throw, sending one packet early;
    //               that artificially short gap arrives exactly when stability matters most.
    // Deliberately updated ONLY here, on a real packet — never per-frame.  If the delay could grow while
    // the stream is silent, InterpFrac's `f` would never saturate at 1 and the settle test below would
    // never fire, leaving resting props with their predraw hooked forever.
    if (!isnew)
    {
        float gap = self.pp_snap_time - self.pp_snap_time_prev;
        if (gap >= PP_DELAY_MIN && gap <= PhysProp_WakeGap(self))
        {
            if (self.pp_snap_interval <= 0)
                self.pp_snap_interval = gap;                                    // first sample: take it
            else
                self.pp_snap_interval += (gap - self.pp_snap_interval) * PP_DELAY_EMA;
        }
    }

    // Rest-wake repair: a rested prop stops streaming, so on the next wake pp_snap_time_prev is stale
    // (seconds old) and the jolt would lerp over the whole silence (a slow ooze).  Move ONLY the timestamp
    // (keep pp_snap_origin_prev = the current rest pose, so no pop) to bound the catch-up.
    //
    // WHAT to substitute is the whole point.  The legacy path used cl_physprop_wake_lerp — a hand-authored
    // CLIENT constant standing in for a SERVER-owned stream interval, so it was only ever right at one
    // stream rate (0.08 was tuned for 8 Hz; at 64 Hz it is 5x too long).  Because dt doubles as the render
    // delay in the legacy code, a wrong value there = the render target jumps on the next packet.  Feeding
    // it the MEASURED interval instead makes dt equal the render delay at the wake frame, so `f` starts at
    // 0 and sweeps to 1 over exactly one delay — and the delay itself never changed, so nothing jumps.
    if (!isnew && (self.pp_snap_time - self.pp_snap_time_prev) > PhysProp_WakeGap(self))
    {
        float wake;
        if (cvar("cl_physprop_smoothinterp"))
            wake = PhysProp_RenderDelay(self);
        else
            wake = cvar("cl_physprop_wake_lerp");
        self.pp_snap_time_prev = self.pp_snap_time - wake;
    }

    // Always hook the interpolator; it interpolates prev→cur over the real interval, then parks +
    // unhooks itself once caught up at rest (see CSQC_PhysProp_Predraw), so resting props cost ~0.
    self.predraw = CSQC_PhysProp_Predraw;

    // Join the active chain while this prop is actually moving, so the prediction hull relink walks it
    // (PhysProp_RelinkHullsForPrediction).  The predraw drops it out again on the settle edge.
    if (vel != '0 0 0' || avel != '0 0 0')
        PhysProp_ActiveLink(self);
    // The prop is live again (fresh snapshot) — drop any parked static blob; the per-frame
    // emit in the predraw takes over.  Early-outs when no slot, so steady streams cost ~0.
    BlobShadow_FreeStatic(self);
};

// ============================================================
//  Predicted-collision prop mirror  (CSQC_ENT_PRED_PROP)
//  ----------------------------------------------------------
//  A prop_static / prop_detail flagged "Predicted collision".  Rebuilds the
//  model + a LOCAL solid so the client's predicted pmove + CSQC bullet traces
//  collide client-side (no rubber-band).  Static: no extrapolation / predraw.
//  Wire layout MUST match predprop_Send (sv_props.qc) byte-for-byte.
// ============================================================
void(float isnew) CSQC_PredProp_Update =
{
    float  mdlindex  = readshort();
    vector org       = readvector();
    vector ang       = readvector();
    vector emins     = readvector();
    vector emaxs     = readvector();
    float  istrimesh = readbyte();
    float  sc        = readcoord();
    float  skn       = readbyte();
    vector cmod;
    cmod_x           = readbyte() * (1.0 / 255.0);
    cmod_y           = readbyte() * (1.0 / 255.0);
    cmod_z           = readbyte() * (1.0 / 255.0);
    float  alf       = readbyte() * (1.0 / 255.0);
    float  pshadow   = readbyte();        // bit1=NOSHADOW (no cast), bit2=NOSELFSHADOW (no receive) — see predprop_Send

    self.classname = "prop_predicted";
    setmodelindex(self, mdlindex);
    self.scale     = (sc > 0) ? sc : 1;   // engine reads xv->scale for the scaled trimesh narrowphase + render
    self.skin      = skn;
    self.colormod  = cmod;
    self.alpha     = (alf > 0) ? alf : 1; // 0 (unset) → opaque
    self.angles    = ang;
    self.movetype  = MOVETYPE_NONE;       // origin is wire-authoritative
    self.drawmask  = MASK_ENGINE;         // engine renders the CSQC entity
    // Re-apply the shadow bits the standard-net path gets for free (EF→RF mapping, cl_ents.c).  Set
    // explicitly each update (renderflags aren't sticky across a re-add).
    //   RF_NOSHADOW     — engine r_shadows-2 caster walk skips this ent (gl_alias.c) → no world CAST.
    //   RF_NOSELFSHADOW — CSQCRF_NOSELFSHADOW → RF_NOSHADOWRECV → e_noshadowrecv → no self-shadow RECEIVE.
    if (pshadow & 1)
        self.renderflags |= RF_NOSHADOW;
    else
        self.renderflags &= ~RF_NOSHADOW;
    if (pshadow & 2)
        self.renderflags |= RF_NOSELFSHADOW;
    else
        self.renderflags &= ~RF_NOSELFSHADOW;

    // Local solid → the predicted CSQC pmove + CSQC bullet traces collide.  TRIMESH for
    // IQM (the client has the mesh + NativeTrace, scaled by the engine via .scale); else
    // the oriented box (engine OBB patch rotates it by the streamed .angles).  MUST be set
    // BEFORE setsize/setorigin: those link the entity (World_LinkEdict), which only computes
    // the ROTATED broadphase AABB (engine Patch 53/59) when solid is a PHYSICS_BOX/TRIMESH.
    // With solid still SOLID_NOT at link time a ROTATED prop kept the UN-ROTATED AABB, so the
    // client prediction fell through the rotated hull OUTSIDE it and the server (which links
    // with solid set) snapped the player back.
    self.solid = istrimesh ? SOLID_PHYSICS_TRIMESH : SOLID_PHYSICS_BOX;
    setsize(self, emins, emaxs);          // scaled bbox (broadphase + PVS); trimesh narrowphase = mesh × scale
    setorigin(self, org);
};
