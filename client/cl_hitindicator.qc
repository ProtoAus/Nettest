// ============================================================
//  client/cl_hitindicator.qc — 360° damage direction indicator
//
//  When the local player takes damage, the server sends the
//  attacker's world origin alongside the damage amount via
//  CSQC_EVENT_DAMAGE_FLASH (see cl_main.qc:CSQC_Parse_Event).
//  We stash the attacker position in a small ring buffer; each
//  frame the HUD pass walks the buffer and draws a 256×256
//  rotated sprite at screen centre for every active entry,
//  pointing toward the world-space direction of the source.
//
//  Multiple indicators can be active simultaneously — useful
//  for crossfire / multiple-attacker situations.  Each fades
//  to zero alpha over HITIND_DURATION seconds.
// ============================================================

const float  HITIND_MAX        = 8;        // simultaneous indicators
const float  HITIND_DURATION   = 3.0;      // seconds from spawn to fully faded
const float  HITIND_HALF_EXT   = 128;      // half-extent in screen px (256x256 total)
const string HITIND_PIC        = "gfx/360hitindicator.png";

// Ring buffer.  spawn_time <= 0 means "slot never used".
float  hitind_spawn[HITIND_MAX];
vector hitind_origin[HITIND_MAX];

// Called from the CSQC_EVENT_DAMAGE_FLASH parser when the
// attacker world position differs from the victim's (server
// sends '0 0 0' or victim's own origin for non-directional
// damage like fall / void, which we want to skip).
void(vector attacker_pos) Hitindicator_Spawn =
{
    // Pick a free slot first; if all are still alive, recycle
    // the OLDEST so the newest attacker is always visible.
    float i;
    float pick = 0;
    float oldest = hitind_spawn[0];
    for (i = 0; i < HITIND_MAX; i = i + 1)
    {
        if (cltime - hitind_spawn[i] >= HITIND_DURATION)
        {
            pick = i;
            oldest = -1;          // sentinel so the rest of the loop won't override
            break;
        }
        if (hitind_spawn[i] < oldest)
        {
            oldest = hitind_spawn[i];
            pick = i;
        }
    }
    hitind_spawn[pick]  = cltime;
    hitind_origin[pick] = attacker_pos;
};

// HUD pass — drawn after the pain flash so the rotating arrow
// composites over the red vignette but under the crosshair.
//
// Rotation math: vectoyaw() returns the world yaw of the
// "victim → attacker" 2D vector in DEGREES (0° = +X, 90° = +Y).
// We subtract the camera's yaw to get the bearing relative to
// where the player is looking.  drawrotpic's angle parameter is
// in degrees and rotates the image clockwise on screen as the
// value grows, so the formula is:
//      screen_rotation = -(world_bearing - view_yaw)
//                      =  view_yaw - world_bearing
// At rotation 0 the image renders as authored (arrow up = north
// = direction the player is facing).  If your source PNG has
// the arrow pointing somewhere other than up, add a constant
// offset here.  If the indicator spins the wrong way, flip the
// sign of `rotation` below.
void() HUD_DrawHitIndicators =
{
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    vector pivot    = [g_width * 0.5, g_height * 0.5, 0];

    float i;
    for (i = 0; i < HITIND_MAX; i = i + 1)
    {
        if (hitind_spawn[i] <= 0)
            continue;
        float age = cltime - hitind_spawn[i];
        if (age >= HITIND_DURATION)
            continue;

        vector to_atk = hitind_origin[i] - view_pos;
        to_atk_z = 0;
        if (vlen(to_atk) < 1)
            continue;                          // co-located, no meaningful direction

        float world_bearing = vectoyaw(to_atk);
        float rotation      = view_ang_y - world_bearing;
        float alpha         = 1.0 - age / HITIND_DURATION;

        drawrotpic(pivot,
                   [-HITIND_HALF_EXT, -HITIND_HALF_EXT, 0],
                   [ HITIND_HALF_EXT,  HITIND_HALF_EXT, 0],
                   HITIND_PIC, '1 1 1', alpha, rotation);
    }
};
