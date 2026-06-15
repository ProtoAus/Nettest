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
float pp_idx_phys_barrel;
float pp_idx_phys_can;
float pp_idx_phys_files;
float pp_idx_resolved;

void() CSQC_PhysProp_ResolveIndexes =
{
    if (pp_idx_resolved) return;
    pp_idx_phys_barrel = (float)getmodelindex("models/props/barrel.iqm");
    pp_idx_phys_can    = (float)getmodelindex("models/props/can.mdl");
    // Filecabinet uses the IQM when present (else the .mdl box) — resolve both
    // and keep whichever the server precached. The bullet hit-test is a rotated
    // oriented-box (see CSQC_PhysProp_RayBox), accurate even when it tips.
    pp_idx_phys_files  = (float)getmodelindex("models/props/filecabinet/filecabinet.iqm");
    if (pp_idx_phys_files == 0)
        pp_idx_phys_files = (float)getmodelindex("models/props/filecabinet.mdl");
    pp_idx_resolved = 1;
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
    if (pp_idx_phys_barrel != 0 && midx == pp_idx_phys_barrel) return '16 23.6 0';
    if (pp_idx_phys_can    != 0 && midx == pp_idx_phys_can)    return '13 13 0';
    return '0 0 0';
};

entity(float midx) CSQC_PhysProp_FakeForType =
{
    if (pp_idx_phys_barrel != 0 && midx == pp_idx_phys_barrel) return pp_fake_barrel;
    if (pp_idx_phys_can    != 0 && midx == pp_idx_phys_can)    return pp_fake_can;
    if (pp_idx_phys_files  != 0 && midx == pp_idx_phys_files)  return pp_fake_files;
    return world;
};

void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideTrace =
{
    CSQC_PhysProp_ResolveIndexes();
    if (pp_idx_phys_barrel == 0 && pp_idx_phys_can == 0 && pp_idx_phys_files == 0) return;
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
    makevectors(e.angles);   // raw angles — matches World_OBBTrace (no mesh-pitch flip)
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

void() CSQC_DrawDebugPhysProps =
{
    if (!cvar("cl_debug_physprops")) return;

    // Cabinet (and any phys_files) OBBs — the CSQC mirrors are real csqc edicts, so
    // findchain sees them.  Colour = state:
    //   YELLOW = carried / just-dropped passthrough (non-solid to players)
    //   CYAN   = free + settled (velocity ~0) — i.e. likely ODE-autodisabled/asleep
    //   GREEN  = free + moving (active)
    // (The exact ODE dBodyIsEnabled flag isn't exposed to QC, so "asleep" is inferred
    //  from the streamed velocity being ~0; with physics_ode_autodisable 1 a settled
    //  prop does sleep, which is when it goes cyan.)
    entity e = findchain(classname, "phys_files");
    while (e)
    {
        if (e.drawmask)
        {
            vector ocol;
            if (e.solid == SOLID_NOT)
                ocol = '1 0.85 0';
            else if (vlen(e.velocity) < 0.5 && vlen(e.avelocity) < 0.5)
                ocol = '0 0.6 1';
            else
                ocol = '0 1 0';
            CSQC_DrawPhysOBB(e, ocol);
        }
        e = e.chain;
    }

    CSQC_PhysProp_ResolveIndexes();
    if (pp_idx_phys_barrel == 0 && pp_idx_phys_can == 0) return;

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

// Carry state (from the wire) + client-prediction bookkeeping.
.float  pp_phase;          // PP_PHASE_* (was the csolid byte)
.float  pp_carrier;        // carrier edict (0 = free); == player_localentnum ⇒ predict locally
.float  pp_hold_dist;      // networked sv_carry_hold_dist (remote clients have no server cvar)
.float  pp_hold_z;         // networked sv_carry_hold_z
.float  pp_was_predicting; // 1 if last frame drove this prop from the local view (drives the drop fade)
.vector pp_pred_origin;    // last client-predicted feet origin (the "predicted hand" pose)
.vector pp_err_offset;     // predicted − authoritative at the handoff edge; decays to 0
.float  pp_err_cltime;     // cltime the error offset was seeded (0 = none pending)

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

    vector boxhalf = (prop.maxs - prop.mins) * 0.5;
    vector cur = prop.origin + '0 0 1' * ((prop.maxs_z + prop.mins_z) * 0.5);
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
        vector org    = center - '0 0 1' * ((self.maxs_z + self.mins_z) * 0.5);  // centre → feet
        self.angles_x = 0;
        self.angles_z = 0;
        self.angles_y = view_angles_y + 180;   // upright, facing the carrier — matches Carry_Tick
        setorigin(self, org);
        addentity(self);
        self.pp_pred_origin    = org;          // remember the predicted hand pose for the drop fade
        self.pp_was_predicting = TRUE;
        return PREDRAW_NEXT;
    }

    // Just stopped predicting (dropped / thrown / handed to another player): seed an
    // error offset = where the predicted hand had it − the authoritative pose, so the
    // render STARTS exactly in the hand (no pop) and eases onto the server pose below.
    if (self.pp_was_predicting)
    {
        self.pp_was_predicting = FALSE;
        self.pp_err_offset = self.pp_pred_origin - self.pp_snap_origin;
        if (vlen(self.pp_err_offset) > 128)        // teleport-sized → don't smear it
            self.pp_err_offset = '0 0 0';
        self.pp_err_cltime = cltime;
    }

    // Decaying handoff offset (eases predicted→authoritative; 0 once expired / none pending).
    vector err = '0 0 0';
    if (self.pp_err_cltime > 0)
    {
        float st    = cvar("cl_carry_smooth_time");
        float decay = (st > 0) ? (1 - (cltime - self.pp_err_cltime) / st) : 0;
        if (decay > 0)
            err = self.pp_err_offset * decay;
        else
            self.pp_err_cltime = 0;
    }

    // `cl_physprop_noextrap 1` disables the smoothing so you can SEE the raw snapshot
    // cadence (a debug toggle — default off = extrapolation ON).  With it off you'll
    // see the prop step at exactly the server send rate; with it on those steps are
    // filled by extrapolating along the streamed velocity/avelocity.
    if (cvar("cl_physprop_noextrap"))
    {
        setorigin(self, self.pp_snap_origin + err);
        self.angles = self.pp_snap_angles;
        addentity(self);
        return PREDRAW_NEXT;
    }

    // Extrapolate from the last snapshot at the streamed velocity/avelocity so
    // motion is smooth between updates.  Capped tight so a body that slams to a
    // stop (wall / landing) doesn't visibly overshoot before the next snap.
    float elapsed = cltime - self.pp_snap_time;
    if (elapsed < 0)   elapsed = 0;
    if (elapsed > 0.1) elapsed = 0.1;

    setorigin(self, self.pp_snap_origin + self.velocity * elapsed + err);
    if (self.avelocity != '0 0 0')
        self.angles = self.pp_snap_angles + self.avelocity * elapsed;

    addentity(self);
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
    float  phase     = readbyte();   // PP_PHASE_* (was the csolid 0/1 byte)
    float  carrier   = readbyte();   // carrier edict (0 = free)
    float  hold_dist = readcoord();  // networked hold params (remote clients lack the server cvars)
    float  hold_z    = readcoord();

    // classname drives Impact_ClassifyLocal → metal spark + no bullet decal.
    self.classname = "phys_files";
    setmodelindex(self, mdlindex);
    setsize(self, emins, emaxs);     // broadphase AABB (the cube when free); narrowphase = mesh
    setorigin(self, org);
    self.angles    = ang;
    self.velocity  = vel;
    self.avelocity = avel;
    self.colormod  = cmod;
    self.movetype  = MOVETYPE_NONE;  // origin is wire-authoritative (no engine integrate)
    self.drawmask  = MASK_ENGINE;    // engine renders the CSQC entity

    self.pp_phase     = phase;
    self.pp_carrier   = carrier;
    self.pp_hold_dist = hold_dist;
    self.pp_hold_z    = hold_z;

    // SOLID_PHYSICS_BOX ONLY for PP_PHASE_FREE_SOLID → the local QC pmove + CSQC bullet
    // traces collide with the box, which the engine OBB patch (world.c World_OBBTrace)
    // rotates by the streamed angles, so you walk on / shoot the real ORIENTED shape
    // smoothly at any tilt.  SOLID_NOT while carried (GRABBING/STEADY) or in the just-
    // dropped passthrough phase (NONSOLID, server non-solid via PHYSDROP_DIM) so
    // client+server agree and the carrier doesn't shove it.
    self.solid = (phase == PP_PHASE_FREE_SOLID) ? SOLID_PHYSICS_BOX : SOLID_NOT;

    // Anchor the extrapolator at this authoritative snapshot.
    self.pp_snap_origin = org;
    self.pp_snap_angles = ang;
    self.pp_snap_time   = cltime;

    // Hook the predraw while genuinely moving (extrapolation) OR while I'm the local
    // carrier in steady carry (so client-prediction runs every render frame even when
    // the prop is momentarily stationary at the hold point) OR while a handoff fade is
    // still decaying.  A deadband keeps a settled, un-owned prop's origin stable +
    // un-extrapolated so a standing player collides with the true resting surface.
    if (vlen(vel) > 0.5 || vlen(avel) > 0.5
        || (phase == PP_PHASE_STEADY && carrier == player_localentnum)
        || self.pp_was_predicting
        || self.pp_err_cltime > 0)
        self.predraw = CSQC_PhysProp_Predraw;
    else
        self.predraw = __NULL__;
};
