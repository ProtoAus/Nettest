// ============================================================
//  client/cl_debuginfo.qc  -  Debug visualization tools
//
//  cl_debug_impacts 1  — shows where bullets land:
//      Green  = client-predicted hit
//      Purple = server-authoritative hit
// ============================================================

const float DEBUG_MAX_IMPACTS = 64;
const float DEBUG_IMPACT_LIFETIME = 10;
const float DEBUG_CROSS_SIZE = 4;
const float DEBUG_LINE_WIDTH = 2;

float debug_impact_count;
vector debug_impact_pos[DEBUG_MAX_IMPACTS];
vector debug_impact_eye[DEBUG_MAX_IMPACTS];
vector debug_impact_colour[DEBUG_MAX_IMPACTS];
float debug_impact_time[DEBUG_MAX_IMPACTS];

// Store a debug impact point to be drawn for DEBUG_IMPACT_LIFETIME seconds.
// eye_pos is the player's eye position at the moment of firing.
void(vector pos, vector eye_pos, vector colour) CSQC_AddDebugImpact =
{
    float idx = debug_impact_count % DEBUG_MAX_IMPACTS;
    debug_impact_pos[idx] = pos;
    debug_impact_eye[idx] = eye_pos;
    debug_impact_colour[idx] = colour;
    debug_impact_time[idx] = time;
    debug_impact_count += 1;
};

// Draw a 3D quad beam between two points (camera-facing, visible width).
void(vector p1, vector p2, float width, vector colour, float alpha) CSQC_DebugBeam =
{
    vector mid = (p1 + p2) * 0.5;
    vector dir = normalize(p2 - p1);
    vector cam_dir = normalize(mid - (vector)getproperty(VF_ORIGIN));
    vector side = normalize(crossproduct(dir, cam_dir)) * width * 0.5;

    R_BeginPolygon("", 0, 0);
    R_PolygonVertex(p1 - side, '0 0 0', colour, alpha);
    R_PolygonVertex(p1 + side, '1 0 0', colour, alpha);
    R_PolygonVertex(p2 + side, '1 1 0', colour, alpha);
    R_PolygonVertex(p2 - side, '0 1 0', colour, alpha);
    R_EndPolygon();
};

// Draw all active debug impact markers. Call from CSQC_UpdateView.
void() CSQC_DrawDebugImpacts =
{
    float i, total, age;
    vector pos, eye, colour;
    float s = DEBUG_CROSS_SIZE;
    float w = DEBUG_LINE_WIDTH;

    if (!cvar("cl_debug_impacts"))
        return;

    total = min(debug_impact_count, DEBUG_MAX_IMPACTS);

    for (i = 0; i < total; i++)
    {
        age = time - debug_impact_time[i];
        if (age > DEBUG_IMPACT_LIFETIME)
            continue;

        pos = debug_impact_pos[i];
        eye = debug_impact_eye[i];
        colour = debug_impact_colour[i];

        // Fade out over the last second
        float alpha = 1;
        if (age > DEBUG_IMPACT_LIFETIME - 1)
            alpha = DEBUG_IMPACT_LIFETIME - age;

        // Draw 3D cross at impact point
        CSQC_DebugBeam(pos - '1 0 0' * s, pos + '1 0 0' * s, w, colour, alpha);
        CSQC_DebugBeam(pos - '0 1 0' * s, pos + '0 1 0' * s, w, colour, alpha);
        CSQC_DebugBeam(pos - '0 0 1' * s, pos + '0 0 1' * s, w, colour, alpha);

        // Draw beam from eye position at time of firing to impact
        if (eye != '0 0 0')
            CSQC_DebugBeam(eye, pos, w * 0.3, colour, alpha * 0.15);
    }
};
