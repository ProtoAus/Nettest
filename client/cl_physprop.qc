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
float pp_idx_resolved;

void() CSQC_PhysProp_ResolveIndexes =
{
    if (pp_idx_resolved) return;
    pp_idx_phys_barrel = (float)getmodelindex("models/props/barrel.iqm");
    pp_idx_phys_can    = (float)getmodelindex("models/props/can.mdl");
    pp_idx_resolved = 1;
};

// One persistent fake-target entity per prop type.  Bullet impact code
// checks trace_ent.classname for material classification + decal gating;
// we point trace_ent at one of these so the existing classname-based
// gates work without any changes.  Reused across shots.
entity pp_fake_barrel;
entity pp_fake_can;

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
    return world;
};

void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideTrace =
{
    CSQC_PhysProp_ResolveIndexes();
    if (pp_idx_phys_barrel == 0 && pp_idx_phys_can == 0) return;
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

        vector cyl = CSQC_PhysProp_CylForType(midx);
        vector org = (vector)getentity(i, GE_ORIGIN);
        vector vf  = (vector)getentity(i, GE_FORWARD);
        vector vr  = (vector)getentity(i, GE_RIGHT);
        vector vu  = (vector)getentity(i, GE_UP);

        float tnear = CSQC_PhysProp_RayCylinder(trace_src, dir_unit, dirlen,
                                                org, vf, vr, vu,
                                                cyl_x, cyl_y);
        if (tnear < 0) continue;
        if (tnear >= best_t) continue;

        best_t = tnear;
        best_ent = fake_ent;
        best_normal = pp_hit_normal;
    }

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

void() CSQC_DrawDebugPhysProps =
{
    if (!cvar("cl_debug_physprops")) return;
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
