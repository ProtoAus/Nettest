// ============================================================
//  client/cl_bulletholes.qc  -  Client-side bullet hole decals
//
//  Spawns oriented sprite decals at bullet impact points.
//  Local player sees them instantly from prediction.
//  Other players see them from server multicast events.
//
//  Uses a linked list with a max cap — oldest holes are removed
//  when the cap is reached.
// ============================================================

const float BULLETHOLE_MAX             = 2048;
const float BULLETHOLE_MAX_PER_FRAME   = 30;
const float BULLETHOLE_OFFSET_MIN      = 0.3;
const float BULLETHOLE_OFFSET_JITTER   = 0.1;
const float BULLETHOLE_FRAME_START     = 1;
const float BULLETHOLE_FRAME_COUNT     = 2;
string BULLETHOLE_SPRITE               = "gfx/s_bullet.spr";

// --- Linked list fields ---
.entity bh_next;
.entity bh_prev;
.float  bh_dynamic;        // TRUE if attached to a moving BSP entity
.vector bh_local_offset;   // offset from owner.absmin for dynamic holes

entity bh_head;
entity bh_tail;
float  bh_count;
float  bh_frame_count;     // per-frame spawn cap

// --- Remove a hole from the linked list ---
void(entity hole) CSQC_BulletHoleRemove =
{
    if (hole == bh_head)
        bh_head = hole.bh_next;
    if (hole == bh_tail)
        bh_tail = hole.bh_prev;
    if (hole.bh_prev)
        hole.bh_prev.bh_next = hole.bh_next;
    if (hole.bh_next)
        hole.bh_next.bh_prev = hole.bh_prev;

    remove(hole);
    bh_count -= 1;
};

// --- Init (call from CSQC init) ---
void() CSQC_BulletHolesInit =
{
    bh_head = world;
    bh_tail = world;
    bh_count = 0;
    bh_frame_count = 0;
    precache_model(BULLETHOLE_SPRITE);
};

// --- Wipe all bullet holes (round restart) ---
void() CSQC_BulletHolesWipeAll =
{
    entity hole, next;
    hole = bh_head;
    while (hole)
    {
        next = hole.bh_next;
        remove(hole);
        hole = next;
    }
    bh_head = world;
    bh_tail = world;
    bh_count = 0;
};

// --- Per-frame: update dynamic holes, reset frame cap ---
void() CSQC_BulletHolesStartFrame =
{
    entity hole, next;

    bh_frame_count = 0;
    hole = bh_head;

    while (hole)
    {
        next = hole.bh_next;

        if (hole.bh_dynamic)
        {
            if (hole.owner && hole.owner.solid == SOLID_BSP)
                setorigin(hole, hole.owner.absmin + hole.bh_local_offset);
            else
                CSQC_BulletHoleRemove(hole);
        }

        hole = next;
    }
};

// --- Spawn a bullet hole decal at a hit point ---
void(vector hit_pos, vector hit_normal, entity hit_target) CSQC_SpawnBulletHole =
{
    entity hole;
    vector hole_normal, hole_angles, hole_origin;
    float hole_offset;

    // Only on world or BSP entities
    if (hit_target != world && (!hit_target || hit_target.solid != SOLID_BSP))
        return;

    if (bh_frame_count >= BULLETHOLE_MAX_PER_FRAME)
        return;

    if (vlen(hit_normal) <= 0)
        return;

    // Evict oldest if at cap
    if (bh_count >= BULLETHOLE_MAX && bh_head)
        CSQC_BulletHoleRemove(bh_head);

    hole = spawn();
    hole.movetype = MOVETYPE_NONE;
    hole.solid = SOLID_NOT;
    hole.classname = "bullethole";
    hole.drawmask = MASK_ENGINE;

    setmodel(hole, BULLETHOLE_SPRITE);
    hole.frame = BULLETHOLE_FRAME_START + floor(random() * BULLETHOLE_FRAME_COUNT);
    setsize(hole, '0 0 0', '0 0 0');
    hole.scale = 1;
    hole.alpha = 1;
    hole.effects = hole.effects | EF_FULLBRIGHT;

    hole.owner = hit_target;

    // Orient sprite to face outward from the surface
    hole_normal = normalize(hit_normal) * -1;
    hole_angles = vectoangles(hole_normal);
    hole_angles_x = 0 - hole_angles_x;
    hole.angles = hole_angles;
    hole.angles_z = floor(random() * 4) * 90;

    // Nudge slightly off the surface to prevent z-fighting
    makevectors(hole.angles);
    hole_offset = BULLETHOLE_OFFSET_MIN + (random() * BULLETHOLE_OFFSET_JITTER);
    hole_origin = hit_pos - (v_forward * hole_offset);
    setorigin(hole, hole_origin);

    // Track offset for dynamic (moving BSP) entities
    if (hit_target != world)
    {
        hole.bh_dynamic = TRUE;
        hole.bh_local_offset = hole_origin - hit_target.absmin;
    }

    // Append to linked list
    hole.bh_prev = bh_tail;
    hole.bh_next = world;

    if (bh_tail)
        bh_tail.bh_next = hole;
    else
        bh_head = hole;

    bh_tail = hole;
    bh_count += 1;
    bh_frame_count += 1;
};

// Convenience: spawn from trace globals (after a traceline)
void() CSQC_SpawnTraceBulletHole =
{
    CSQC_SpawnBulletHole(trace_endpos, trace_plane_normal, trace_ent);
};
