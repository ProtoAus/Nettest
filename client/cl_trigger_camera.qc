//
//  cl_trigger_camera.qc  —  CSQC half of the Sven trigger_camera cutscene
//
//  The server owns the camera (position, angles, path travel, hold time) and
//  publishes it two ways:
//    - a CSQC_ENT_TRIGGER_CAMERA entity carrying the pose, broadcast to
//      everyone (PVSF_IGNOREPVS on the server side, because a cutscene camera
//      is usually nowhere near the players watching it)
//    - the per-player STAT_CUTSCENE, whose low bits name the bound camera's
//      entnum and whose high bits carry the HUD/cursor/freeze presentation
//
//  This file turns that into a view override, plus the cursor and world
//  picking that trigger_cameratarget needs.
//
//  Angles arriving here are already VIEW convention — the pitch flip happens
//  once, server-side, in Cutscene_UpdateAngles.  Do not flip again.
//

// Received pose for each camera, keyed by entnum.  A cutscene only ever has
// one active camera, but the entity can arrive before the stat that binds us
// to it (or after), so both halves are kept independently and reconciled at
// read time.
.float  cutcam_entnum;
.float  cutcam_serial;
.vector cutcam_angles;

entity cutcam_list_head;
.entity cutcam_list_next;
.float  cutcam_in_list;

// Smoothed pose actually rendered.  The server sends at its tick rate; a
// static camera needs no smoothing at all, but the travelling case would
// otherwise step visibly at packet boundaries.
vector cutscene_smooth_org;
vector cutscene_smooth_ang;
float  cutscene_smooth_valid;
float  cutscene_last_serial;

// Cursor ownership, kept idempotent the way every other cursor site in this
// codebase does it.
float  cutscene_cursor_active;
vector cutscene_cursor_pos;

// ---------------------------------------------------------------------------
//  Entity reception
// ---------------------------------------------------------------------------
void() CSQC_TriggerCamera_Update =
{
    vector org;
    org_x = readcoord();
    org_y = readcoord();
    org_z = readcoord();
    setorigin(self, org);

    // Coords, not angles — see the WriteCoord comment in
    // trigger_camera_SendEntity.  These two must stay paired.
    self.cutcam_angles_x = readcoord();
    self.cutcam_angles_y = readcoord();
    self.cutcam_angles_z = readcoord();
    self.cutcam_serial   = readbyte();
    self.cutcam_entnum   = self.entnum;

    // Same hazard CSQC_Camera_Update documents: re-adding on every update
    // builds a circular list that the lookup below then loops on forever.
    if (!self.cutcam_in_list)
    {
        self.cutcam_in_list   = 1;
        self.cutcam_list_next = cutcam_list_head;
        cutcam_list_head      = self;
    }
};

entity(float entnum) Cutscene_FindCamera =
{
    entity e = cutcam_list_head;
    while (e)
    {
        if (e.cutcam_entnum == entnum)
            return e;
        e = e.cutcam_list_next;
    }
    return world;
};

// ---------------------------------------------------------------------------
//  Stat decoding
// ---------------------------------------------------------------------------
// getstatf, not getstati — the stat is registered EV_FLOAT against a `.float`
// field (sv_main.qc).  Both readers would work here because FTE keeps stats[]
// and statsf[] numerically in sync, but matching the registered type is what
// keeps the two ends honest.  The packed value stays exact: floats represent
// every integer up to 2^24 and this payload peaks at 0x1FFFFF.
float() Cutscene_Stat =
{
    return getstatf(STAT_CUTSCENE);
};

// TRUE when this client is bound to a camera AND that camera's pose has
// actually arrived.  Both halves are required: binding to a camera we cannot
// place yet would snap the view to the world origin for a frame.
float() Cutscene_Active =
{
    float s = Cutscene_Stat();
    if (!(s & CUTSCENE_ENT_MASK))
        return FALSE;
    return (Cutscene_FindCamera(s & CUTSCENE_ENT_MASK) != world);
};

float() Cutscene_WantsCursor =
{
    return Cutscene_Active() && (Cutscene_Stat() & CUTSCENE_SF_CURSOR);
};

float(float bit) Cutscene_HidesHud =
{
    if (!Cutscene_Active())
        return FALSE;
    return (Cutscene_Stat() & bit) != 0;
};

// A cutscene with Force View must play over the death cam / spectator, so
// CSQC_UpdateView has to test it before Spectate_IsActive().  Every other
// cutscene defers to being dead, which the server already enforces by not
// binding dead players — this is only the client-side half of the same rule.
float() Cutscene_OverridesSpectator =
{
    return Cutscene_Active();
};

// ---------------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------------
void() Cutscene_ApplyView =
{
    entity cam = Cutscene_FindCamera(Cutscene_Stat() & CUTSCENE_ENT_MASK);
    if (!cam)
        return;

    // A serial bump means a new activation (or the same camera restarted), so
    // snap rather than sliding across the map from the previous cutscene's
    // last pose.
    if (!cutscene_smooth_valid || cam.cutcam_serial != cutscene_last_serial)
    {
        cutscene_smooth_org   = cam.origin;
        cutscene_smooth_ang   = cam.cutcam_angles;
        cutscene_smooth_valid = 1;
        cutscene_last_serial  = cam.cutcam_serial;
    }
    else
    {
        // Exponential approach, framerate-independent.  17 of the 18 cameras
        // in pizza_ya_san1 are static so this does nothing there; it exists
        // for the travelling case, where the server's tick-rate updates would
        // otherwise be visible as steps.
        float f = 1 - pow(0.01, frametime * 8);
        cutscene_smooth_org = cutscene_smooth_org + (cam.origin - cutscene_smooth_org) * f;

        // Angles must be lerped the short way round or a camera crossing the
        // 0/360 seam spins the long way.
        float dyaw   = anglemod(cam.cutcam_angles_y - cutscene_smooth_ang_y + 180) - 180;
        float dpitch = anglemod(cam.cutcam_angles_x - cutscene_smooth_ang_x + 180) - 180;
        cutscene_smooth_ang_x = cutscene_smooth_ang_x + dpitch * f;
        cutscene_smooth_ang_y = cutscene_smooth_ang_y + dyaw   * f;
        cutscene_smooth_ang_z = cam.cutcam_angles_z;
    }

    setproperty(VF_ORIGIN, cutscene_smooth_org);
    setproperty(VF_ANGLES, cutscene_smooth_ang);
    setproperty(VF_VIEWENTITY, 0);
};

void() Cutscene_Reset =
{
    cutscene_smooth_valid = 0;
    cutscene_last_serial  = -1;
};

// ---------------------------------------------------------------------------
//  Cursor + world picking (trigger_cameratarget)
// ---------------------------------------------------------------------------
//  This is the first screen-to-world picking in the codebase — `unproject` is
//  declared in cl_defs.qc but had no callers.  Everything else traces forward
//  from the crosshair, which is exactly what a cursor must NOT do.
// ---------------------------------------------------------------------------

void() Cutscene_UpdateCursorMode =
{
    float want = Cutscene_WantsCursor();

    if (want && !cutscene_cursor_active)
    {
        setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
        cutscene_cursor_active = 1;
        // Start the cursor centred rather than at 0,0 — the first IE_MOUSEABS
        // only arrives once the player actually moves the mouse.
        cutscene_cursor_pos = [g_width * 0.5, g_height * 0.5, 0];
    }
    else if (!want && cutscene_cursor_active)
    {
        setcursormode(FALSE);
        cutscene_cursor_active = 0;
    }
};

// Build a world ray through the cursor and return the entity under it.
//
// unproject() reads the CURRENT view properties, so this must be called after
// Cutscene_ApplyView has set VF_ORIGIN/VF_ANGLES for this frame and before
// anything else re-points them (the team-select preview viewport in
// m_teamselect.qc re-sets VF_MIN/VF_SIZE/VF_ORIGIN, which would poison the
// unprojection if it ran in between).
entity() Cutscene_PickUnderCursor =
{
    // Two depths give a ray direction without having to know the projection.
    vector near_pt = unproject([cutscene_cursor_pos_x, cutscene_cursor_pos_y, 1]);
    vector far_pt  = unproject([cutscene_cursor_pos_x, cutscene_cursor_pos_y, 4096]);

    vector dir = far_pt - near_pt;
    if (vlen(dir) < 0.01)
        return world;
    dir = normalize(dir);

    vector start = getproperty(VF_ORIGIN);
    traceline(start, start + dir * 8192, MOVE_NORMAL, world);

    if (trace_ent && trace_ent != world
        && trace_ent.brush_type == BRUSH_TYPE_CAMTARGET)
        return trace_ent;

    return world;
};

// Fired from CSQC_InputEvent on a mouse press while a cursor cutscene is up.
// Double-click detection is local — the server only ever sees the resolved
// single/double flag.
float  cutscene_last_click_time;
float  cutscene_last_click_btn;
const float CUTSCENE_DOUBLECLICK_SECS = 0.35;

void(float btn) Cutscene_ClickAt =
{
    entity hit = Cutscene_PickUnderCursor();
    if (!hit || hit == world)
        return;

    float dbl = 0;
    if (btn == cutscene_last_click_btn
        && (cltime - cutscene_last_click_time) < CUTSCENE_DOUBLECLICK_SECS)
        dbl = 1;
    cutscene_last_click_time = cltime;
    cutscene_last_click_btn  = btn;

    // The server re-validates all of this — that we are in a cursor cutscene,
    // that the entnum really is an enabled trigger_cameratarget — so a forged
    // entnum here buys nothing.
    sendevent("camtarget", "fff", hit.entnum, btn, dbl);
};

// Returns TRUE when the event was consumed.  Deliberately narrow: only the
// mouse is taken, so a cutscene with a cursor still lets the player type,
// open the console and hit escape.
float(float evtype, float scanx, float chary, float devid) Cutscene_InputEvent =
{
    if (!Cutscene_WantsCursor())
        return FALSE;

    if (evtype == IE_MOUSEABS)
    {
        cutscene_cursor_pos_x = scanx;
        cutscene_cursor_pos_y = chary;
        return TRUE;
    }

    if (evtype == IE_KEYDOWN)
    {
        if (scanx == K_MOUSE1) { Cutscene_ClickAt(0); return TRUE; }
        if (scanx == K_MOUSE2) { Cutscene_ClickAt(1); return TRUE; }
        if (scanx == K_MOUSE3) { Cutscene_ClickAt(2); return TRUE; }
    }
    if (evtype == IE_KEYUP)
    {
        // Swallow the matching release too, so it can't leak out as a stray
        // -attack after the cutscene consumed the press.
        if (scanx == K_MOUSE1 || scanx == K_MOUSE2 || scanx == K_MOUSE3)
            return TRUE;
    }

    return FALSE;
};

// Draw the cursor.  setcursormode's own image only renders in some
// configurations, so draw it explicitly at the tracked position — this also
// keeps the hotspot consistent with what Cutscene_PickUnderCursor unprojects.
void() Cutscene_DrawCursor =
{
    if (!cutscene_cursor_active)
        return;
    drawpic(cutscene_cursor_pos - '8 8 0', "gfx/xhair", '16 16 0', '1 1 1', 1, 0);
};
