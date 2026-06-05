// ============================================================
//  client/cl_tracers.qc  -  Per-shot bullet tracers
//
//  Each fired shot leaves a brief ribbon between the muzzle
//  origin and the impact point that fades out over a configurable
//  lifetime.  The local player's predicted shots spawn from the
//  hitscan-predict path; remote players' shots spawn from the
//  CSQC_EVENT_IMPACT multicast (the server now appends a shooter
//  entnum byte so we can reconstruct the start point on the
//  receiving client).
//
//  All four visual knobs are CSQC-only — the server has no
//  authority over how tracers look:
//    cl_tracer           0/1 toggle (default 1)
//    cl_tracer_width     ribbon thickness in qu (default 1.5)
//    cl_tracer_color     "R G B" floats 0..1 (default "1 0.85 0.5")
//    cl_tracer_opacity   peak alpha 0..1 (default 0.7)
//    cl_tracer_time      lifetime seconds (default 0.12)
//
//  Storage is a fixed-size ring buffer; old entries are
//  overwritten when the buffer wraps.  At a typical 0.12 s
//  lifetime and 32 RPS the working set never exceeds ~4
//  entries — TRACER_MAX is sized to comfortably absorb spray
//  weapons across multiple shooters.
// ============================================================

const string TRACER_SHADER = "gfx/tracer";
const float  TRACER_MAX    = 256;

vector tr_start[TRACER_MAX];
vector tr_end[TRACER_MAX];
float  tr_spawn_time[TRACER_MAX];
// Per-slot travel mode: 0 = static ribbon, 1 = moving-head growing,
// 2 = full-length translating quad (whole segment moves forward).
// Latched at spawn from cl_tracer_travel / cl_tracer_travel_full so
// mid-flight mode flips don't mutate already-live tracers.
float  tr_travel[TRACER_MAX];
float  tr_count;       // total live entries (capped at TRACER_MAX)
float  tr_head_idx;    // next slot to write

void() CSQC_TracersInit =
{
    precache_pic(TRACER_SHADER);
    tr_count    = 0;
    tr_head_idx = 0;
};

void() CSQC_TracersWipeAll =
{
    tr_count    = 0;
    tr_head_idx = 0;
};

// Append a new tracer to the ring.  Cheap (no allocation, no
// linked-list link) — every fire path can call this without
// worrying about per-frame budgets.
void(vector start_pos, vector end_pos) CSQC_SpawnTracer =
{
    if (cvar("cl_tracer") <= 0)
        return;

    // Reject zero-length / sub-quake-unit traces; the camera
    // basis math degenerates and there's nothing visually useful
    // to draw.
    vector d = end_pos - start_pos;
    if ((d * d) < 4)        // < 2 qu length
        return;

    float slot = tr_head_idx;
    tr_start[slot]      = start_pos;
    tr_end[slot]        = end_pos;
    tr_spawn_time[slot] = cltime;
    // _full overrides _travel so a single cvar drives the new mode
    // without forcing the user to clear the older one.
    if (cvar("cl_tracer_travel_full") > 0)
        tr_travel[slot] = 2;
    else if (cvar("cl_tracer_travel") > 0)
        tr_travel[slot] = 1;
    else
        tr_travel[slot] = 0;

    tr_head_idx = tr_head_idx + 1;
    if (tr_head_idx >= TRACER_MAX)
        tr_head_idx = 0;
    if (tr_count < TRACER_MAX)
        tr_count = tr_count + 1;
};

// Per-frame draw — called from CSQC_UpdateView before
// renderscene so the ribbons composite into the world via the
// engine's regular polygon batch.  Walks the ring, builds a
// camera-facing quad per still-living tracer, and submits each
// via R_BeginPolygon against the gfx/tracer shader.  The shader
// declares additive blending + vertex colour, so the per-tracer
// alpha fade is what actually drives the visual decay.
void() CSQC_TracersDraw =
{
    if (cvar("cl_tracer") <= 0 || tr_count <= 0)
        return;

    float lifetime = cvar("cl_tracer_time");
    if (lifetime <= 0) lifetime = 0.12;
    float opacity  = bound(0, cvar("cl_tracer_opacity"), 1);
    if (opacity <= 0) return;
    float width    = cvar("cl_tracer_width");
    if (width <= 0) width = 1.5;

    // cl_tracer_color "" → no color overlay (pure white vertex tint,
    // shader texture renders untinted).  Any non-empty value parses
    // as a vector and modulates the shader output.
    string col_str = cvar_string("cl_tracer_color");
    vector colour;
    if (col_str == "")
        colour = '1 1 1';
    else
    {
        colour = stov(col_str);
        if (colour == '0 0 0') colour = '1 0.85 0.5';
    }

    // cl_tracer_sprite — when non-empty, render tracer quads using
    // this shader/texture path instead of the default gfx/tracer.
    // Lets users swap to gfx/rain/streak1.png or a custom streak.
    string sprite_path = cvar_string("cl_tracer_sprite");
    string tracer_tex  = (sprite_path != "") ? sprite_path : TRACER_SHADER;

    vector cam_pos = (vector)getproperty(VF_ORIGIN);
    vector cam_ang = (vector)getproperty(VF_ANGLES);
    float  half_w  = width * 0.5;

    // Lateral muzzle offset for the local player's first-person view.
    // The predicted tracer's start is the player's eye (= the camera
    // position), so the camera lies exactly ON the line, the side
    // vector cross-product degenerates and the quad culls itself.
    // Push the visible start forward + side + down so the camera is
    // off the line and the player reads the tracer as coming out of
    // the gun.  Only kicks in when the start is essentially the
    // camera; remote tracers aren't affected.
    makevectors(cam_ang);
    vector cam_fwd   = v_forward;
    vector cam_right = v_right;
    vector cam_up    = v_up;
    float  lh_sign   = cvar("cl_lefthand") ? -1 : 1;
    vector muzzle_offset = cam_fwd  * 16
                         + cam_right * (4 * lh_sign)
                         + cam_up    * (-4);

    // Travel-mode parameters resolved once per frame.
    float travel_speed = cvar("cl_tracer_travel_speed");
    if (travel_speed <= 0) travel_speed = 8000;
    float travel_alpha = cvar("cl_tracer_alpha");
    if (travel_alpha <= 0) travel_alpha = 0.9;
    float travel_size  = cvar("cl_tracer_travel_size");
    if (travel_size <= 0) travel_size = 1.5;
    float travel_half_w = (width * travel_size) * 0.5;

    float i;
    for (i = 0; i < tr_count; i = i + 1)
    {
        float age = cltime - tr_spawn_time[i];
        if (age < 0)
            continue;

        vector p1 = tr_start[i];
        vector p2 = tr_end[i];

        // First-person fix: if the start is at the camera (within a
        // few qu), shift it to a fake muzzle position offset from
        // the camera so the camera is no longer collinear with the
        // line.  Remote shooters' tracers start at THEIR eye, which
        // is far from our camera, so they fall through unmodified.
        if (vlen(p1 - cam_pos) < 8)
            p1 = cam_pos + muzzle_offset;

        // Init silences fteqcc's F302 — all three branches below
        // assign these, but the analyser doesn't see that.
        float a = 0;
        float quad_half_w = 0;

        // Shared scratch — fteqcc hoists branch-scope decls to function
        // scope and warns on dup, so declare once up here.
        vector seg;
        float  dist;
        vector dir_n;
        float  fade;
        if (tr_travel[i] == 2)
        {
            // Full-length-bullet mode: fixed-length bright streak that
            // flies from src to dst at travel_speed.  At t=0 the tail
            // sits at src and the head is at src + dir * length, so the
            // tracer is visible immediately at its full length.  Both
            // ends translate forward together; expires when the head
            // reaches dst.
            seg  = p2 - p1;
            dist = vlen(seg);
            if (dist < 0.01) continue;
            dir_n = seg * (1.0 / dist);
            float full_len = cvar("cl_tracer_travel_length");
            if (full_len <= 0) full_len = 256;
            float head_pos = travel_speed * age + full_len;
            if (head_pos > dist + full_len) continue;   // past impact + length
            vector head = p1 + dir_n * head_pos;
            vector tail = head - dir_n * full_len;
            // Clamp tail behind the muzzle (let the head escape past dst).
            float tail_t = (head_pos - full_len);
            float fade_in;
            if (tail_t < 0) fade_in = 1.0;
            else if (tail_t > dist) fade_in = 0.0;
            else fade_in = 1.0;
            p1 = tail;
            p2 = head;
            float head_t = head_pos / dist;
            fade = (head_t < 0.75) ? 1.0 : (1.0 - (head_t - 0.75) / 0.25);
            if (fade < 0) fade = 0;
            a = travel_alpha * fade * fade_in;
            quad_half_w = travel_half_w;
        }
        else if (tr_travel[i] == 1)
        {
            // Moving head: progress from 0..1 over (dist/speed) seconds,
            // alpha holds full until 75% then fades.  Stretched quad of
            // cl_tracer_travel_length qu from `head - dir*length` to head.
            seg     = p2 - p1;
            dist    = vlen(seg);
            if (dist < 0.01) continue;
            float  travel_time = dist / travel_speed;
            if (travel_time <= 0) continue;
            float  t       = age / travel_time;
            if (t >= 1) continue;
            dir_n   = seg * (1.0 / dist);
            vector head    = p1 + seg * t;
            float  head_len = cvar("cl_tracer_travel_length");
            if (head_len <= 0) head_len = 96;
            if (head_len > dist * t) head_len = dist * t;
            if (head_len < 1) head_len = 1;
            p1 = head - dir_n * head_len;
            p2 = head;
            fade = (t < 0.75) ? 1.0 : (1.0 - (t - 0.75) / 0.25);
            a = travel_alpha * fade;
            quad_half_w = travel_half_w;
        }
        else
        {
            if (age >= lifetime) continue;
            fade = 1.0 - (age / lifetime);
            a = opacity * fade;
            quad_half_w = half_w;
        }
        if (a <= 0) continue;

        vector dir = p2 - p1;
        if ((dir * dir) < 0.01) continue;
        dir = normalize(dir);

        // Build the camera-facing side vector — perpendicular to
        // both the line direction and the eye→midpoint vector,
        // mirrors CSQC_DebugBeam.
        vector mid     = (p1 + p2) * 0.5;
        vector cam_dir = mid - cam_pos;
        if (vlen(cam_dir) < 0.01) continue;
        cam_dir = normalize(cam_dir);
        vector side    = crossproduct(dir, cam_dir);
        // Hard fallback: if the line is still parallel to the camera
        // direction (extreme down-the-barrel angle even with the
        // muzzle offset applied), use world-up as the perpendicular.
        // World-right covers the case where the line is itself
        // near-vertical.
        if (vlen(side) < 0.01)
        {
            if (fabs(dir_z) < 0.95)
                side = crossproduct(dir, '0 0 1');
            else
                side = crossproduct(dir, '1 0 0');
            if (vlen(side) < 0.01) continue;
        }
        side = normalize(side) * quad_half_w;

        vector p1n = p1 - side;
        vector p1p = p1 + side;
        vector p2p = p2 + side;
        vector p2n = p2 - side;

        R_BeginPolygon(tracer_tex, 0, 0);
        R_PolygonVertex(p1n, '0 0 0', colour, a);
        R_PolygonVertex(p1p, '1 0 0', colour, a);
        R_PolygonVertex(p2p, '1 1 0', colour, a);
        R_PolygonVertex(p2n, '0 1 0', colour, a);
        R_EndPolygon();
    }
};
