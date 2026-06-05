// ============================================================
//  client/cl_scorch.qc  -  Ground-projected scorch decals
//
//  Spawned at grenade explosions:
//    kind 1  →  gfx/scorch1   (CS HE grenade)
//    kind 2  →  gfx/scorch2   (HL grenade / HL-style explosions)
//
//  Uses adddecal() per scorch per frame. adddecal() projects the
//  texture against the world model and CLIPS at surface boundaries
//  — a scorch on a stair step wraps the geometry instead of
//  floating as a flat quad. That clipping is the whole reason for
//  picking adddecal here instead of the cl_bulletholes trisoup
//  batcher (which submits flat 4-vertex quads and can't clip).
//
//  Cost: one adddecal call per active scorch per frame. With the
//  default cap of 32 scorches that's well under a millisecond on
//  any GPU we care about. For comparison, bullet-hole batching is
//  worth it because there can be hundreds of holes; scorches max
//  out in the dozens.
//
//  Lifecycle: spawn → 25 s opaque → 5 s linear fade → free.
//  Cap is FIFO (oldest evicted first when the list is full).
// ============================================================

const string SCORCH_SHADER_HE   = "gfx/scorch1";
const string SCORCH_SHADER_HL   = "gfx/scorch2";
const float  SCORCH_HALF_SIZE   = 64;
// Z-fight defeat lives in scripts/scorch.shader (polygonoffset 8).
// World-space bias here is a no-op for adddecal — Mod_ClipDecal
// outputs triangles ON the world surface regardless of where the
// projection origin sits, so biasing the origin only changes the
// alpha falloff math, never the depth of the rendered tris. Keep
// the origin coplanar with the hit and let the shader handle
// depth biasing properly.
const float  SCORCH_DECAL_BIAS  = 0;
const float  SCORCH_FADE_START  = 25;
const float  SCORCH_FADE_END    = 30;
const float  SCORCH_TRACE_DEPTH = 512;
const float  SCORCH_MAX         = 32;

entity scorch_head;
entity scorch_tail;
.entity sc_prev;
.entity sc_next;
.float  sc_kind;          // 1 = scorch1 (HE), 2 = scorch2 (HL)
.float  sc_spawn_time;
.vector sc_origin;        // hit point (trace_endpos)
.vector sc_normal;        // surface normal (outward)
.vector sc_tangent;       // pre-baked side axis perpendicular to normal
float   scorch_count;

void() CSQC_Scorch_Precache =
{
    precache_pic(SCORCH_SHADER_HE);
    precache_pic(SCORCH_SHADER_HL);
};

void(entity sc) CSQC_ScorchRemove =
{
    if (sc.sc_prev)
        sc.sc_prev.sc_next = sc.sc_next;
    else
        scorch_head = sc.sc_next;
    if (sc.sc_next)
        sc.sc_next.sc_prev = sc.sc_prev;
    else
        scorch_tail = sc.sc_prev;
    remove(sc);
    scorch_count = scorch_count - 1;
};

void() CSQC_ScorchWipeAll =
{
    while (scorch_head)
        CSQC_ScorchRemove(scorch_head);
};

// Trace from `pos` downward to find the floor and stamp a scorch
// there. Skips if the trace doesn't hit anything within
// SCORCH_TRACE_DEPTH (grenade exploded mid-air over a pit) or if
// the underlying surface is sky.
void(vector pos, float kind) CSQC_SpawnScorchDecal =
{
    if (!cvar("cl_scorch_decals"))
        return;
    if (kind != 1 && kind != 2)
        return;

    // Trace from a few units above the explosion origin, downward,
    // far enough to hit the floor of any reasonable map. Pass `self`
    // as the ignore arg so the trace isn't blocked by whatever ent
    // happens to be the QC self — usually the exploding grenade or
    // the event-handler context.
    vector start = pos + '0 0 16';
    vector end   = pos + [0, 0, 0 - SCORCH_TRACE_DEPTH];
    traceline(start, end, MOVE_NORMAL, self);

    if (trace_fraction >= 1.0)
        return;
    if (vlen(trace_plane_normal) <= 0)
        return;
    if (pointcontents(trace_endpos - trace_plane_normal * 2) == CONTENT_SKY)
        return;

    while (scorch_count >= SCORCH_MAX && scorch_head)
        CSQC_ScorchRemove(scorch_head);

    entity sc = spawn();
    sc.classname     = "scorch_decal";
    sc.sc_kind       = kind;
    sc.sc_spawn_time = cltime;
    sc.sc_origin     = trace_endpos;
    sc.sc_normal     = normalize(trace_plane_normal);

    // Pre-bake a side axis perpendicular to the surface normal so
    // the per-frame draw doesn't redo this. Pick a reference axis
    // that isn't parallel to the normal (otherwise crossproduct
    // degenerates to zero), then take the cross.
    vector ref;
    if (fabs(sc.sc_normal_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    sc.sc_tangent = normalize(crossproduct(sc.sc_normal, ref));

    sc.sc_prev = scorch_tail;
    sc.sc_next = world;
    if (scorch_tail)
        scorch_tail.sc_next = sc;
    else
        scorch_head = sc;
    scorch_tail = sc;
    scorch_count = scorch_count + 1;
};

void() CSQC_DrawScorchDecals =
{
    // Intentionally NO cvar gate here — the spawn function already
    // refuses to add new scorches when cl_scorch_decals is 0, so any
    // entries in the list are valid to draw. Re-checking the cvar
    // here would just freeze drawing whenever the user toggles it
    // off mid-game, leaving stale scorches frozen in place; better
    // to let them fade out naturally.

    entity sc = scorch_head;
    entity next_sc;
    float  age;
    float  alpha;
    vector decal_origin;
    vector side_arg;
    string shader;
    float  persistent = cvar("cl_scorch_persistent");

    while (sc)
    {
        next_sc = sc.sc_next;

        if (persistent)
        {
            // Skip the age-based fade and removal entirely. Scorches
            // hold full alpha until CSQC_EVENT_ROUND_CLEANUP fires
            // CSQC_ScorchWipeAll() (or the FIFO cap evicts them).
            alpha = 1.0;
        }
        else
        {
            age = cltime - sc.sc_spawn_time;
            if (age >= SCORCH_FADE_END)
            {
                CSQC_ScorchRemove(sc);
                sc = next_sc;
                continue;
            }

            if (age < SCORCH_FADE_START)
                alpha = 1.0;
            else
                alpha = 1.0 - (age - SCORCH_FADE_START) / (SCORCH_FADE_END - SCORCH_FADE_START);
        }

        // FTE adddecal arg semantics (cl_bulletholes.qc:420):
        //   up   → outward surface normal
        //   side → reciprocal texture axis (1 / full size)
        side_arg     = sc.sc_tangent / (SCORCH_HALF_SIZE * 2);
        decal_origin = sc.sc_origin  + sc.sc_normal * SCORCH_DECAL_BIAS;

        if (sc.sc_kind == 1)
            shader = SCORCH_SHADER_HE;
        else
            shader = SCORCH_SHADER_HL;

        adddecal(shader, decal_origin, sc.sc_normal, side_arg, '1 1 1', alpha);

        sc = next_sc;
    }
};
