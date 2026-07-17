// ============================================================
//  client/cl_carpanel.qc  -  F3 in-game CAR dev/tuning panel
//
//  Floating CSQC overlay (F3 toggles) exposing every car cvar with
//  < / > stepper arrows + a click-to-type value box, across tabs.
//
//  Edit routing (the point of the panel):
//    - while DRIVING  → per-car live override on THE car you're in
//      (`cmd carset <field> <v>`), leaving the server default + other
//      cars untouched.  A "Save as default" button then pushes the
//      current values to the sv_car_* cvars.
//    - while OUTSIDE  → edits the server-default cvar directly
//      (sv_car_* via rcon/local, cl_car_* via cvar_set).
//
//  Forks the structure of cl_debugpanel.qc (F1) — reuses its
//  Debug_Button + the SUI widgets, and cl_serverpanel.qc's rcon send
//  helpers (Server_IsRemote / Server_Set / Server_SetFloat).  Must be
//  compiled AFTER both in cl_progs.src.  CSQC only.
// ============================================================

const float TUNE_SV = 0;   // side: server-authoritative cvar (sv_car_*)
const float TUNE_CL = 1;   // side: client-only cvar (cl_car_*)

const float TUNE_MAX_ENTRIES = 96;

const float TUNE_TAB_DRIVE    = 0;
const float TUNE_TAB_HANDLING = 1;
const float TUNE_TAB_WHEELS   = 2;
const float TUNE_TAB_FX       = 3;
const float TUNE_TAB_BODY     = 4;
const float TUNE_TAB_COUNT    = 5;

const float TUNE_TITLE_H     = 24;
const float TUNE_TAB_STRIP_H = 20;
const float TUNE_ROW_H       = 18;
const float TUNE_FOOT_H      = 40;   // bottom bar: buttons + rcon box
const float TUNE_PAD         = 6;
const float TUNE_VBAR_W      = 8;
const float TUNE_ARROW_W     = 16;

const vector TUNE_FONT   = '8 8 0';

// Warm amber "workshop" palette — distinct from the blue F1/F2 panels.
const vector TUNE_BG          = '0.10 0.08 0.05';
const vector TUNE_BG_DARKER   = '0.06 0.05 0.03';
const vector TUNE_BORDER      = '0.42 0.34 0.20';
const vector TUNE_TITLE_BG    = '0.08 0.06 0.04';
const vector TUNE_HEADER_BG   = '0.13 0.11 0.07';
const vector TUNE_BTN_OFF     = '0.20 0.17 0.12';
const vector TUNE_BTN_OFF_BORD= '0.35 0.30 0.20';
const vector TUNE_BTN_ON      = '0.55 0.40 0.12';
const vector TUNE_BTN_ON_BORD = '0.82 0.62 0.26';
const vector TUNE_ARROW_BG    = '0.26 0.22 0.14';
const vector TUNE_ARROW_BORD  = '0.46 0.38 0.22';
const vector TUNE_BTN_CLOSE   = '0.40 0.15 0.15';
const vector TUNE_BTN_CLOSE_B = '0.65 0.25 0.25';
const vector TUNE_TEXT_1      = '0.98 0.94 0.85';
const vector TUNE_TEXT_2      = '0.72 0.64 0.52';
const vector TUNE_MODE_CAR    = '0.45 0.95 0.45';   // green: "THIS CAR"
const vector TUNE_MODE_SRV    = '0.98 0.78 0.30';   // amber: "SERVER DEFAULT"
const vector TUNE_SHADOW      = '0 0 0';

// --- Entry table (parallel arrays, populated once on first open) ---
string tune_label[TUNE_MAX_ENTRIES];
string tune_cvar [TUNE_MAX_ENTRIES];
float  tune_side [TUNE_MAX_ENTRIES];   // TUNE_SV / TUNE_CL
string tune_field[TUNE_MAX_ENTRIES];   // per-car override field name ("" = cvar-only)
float  tune_step [TUNE_MAX_ENTRIES];
float  tune_mn   [TUNE_MAX_ENTRIES];
float  tune_mx   [TUNE_MAX_ENTRIES];   // clamp applied only when mx > mn
float  tune_tab  [TUNE_MAX_ENTRIES];
string tune_desc [TUNE_MAX_ENTRIES];   // hover tooltip text ("" = no tooltip)
string tune_tip_line[8];               // word-wrapped tooltip lines (file scope — FTEQCC local arrays are flaky)
float  tune_count;
var float tune_hover_idx = -1;         // row the cursor is over this frame (for the tooltip); reset each draw

// Client display shadow — "the value I last set" — so the row updates instantly even on a remote server
// (whose cvar table CSQC can't read) or for a per-car override (carset).  Cleared on panel open.
float  tune_shadow    [TUNE_MAX_ENTRIES];
float  tune_shadow_set[TUNE_MAX_ENTRIES];

// carvals reply cache (from the server's carget → the driven car's real current values, keyed by cvar name).
const float TUNE_CARVAL_MAX = 32;
string g_carval_name[TUNE_CARVAL_MAX];
float  g_carval     [TUNE_CARVAL_MAX];
float  g_carval_count;

// --- Single shared edit buffer (FTEQCC __inout can't write array slots — same note as cl_debugpanel.qc) ---
string tune_edit_text;
float  tune_edit_cursor;
var float tune_active_idx = -1;

// --- Window state ---
float  tune_panel_open;
float  tune_panel_initialized;
vector tune_panel_pos;
vector tune_panel_size;
float  tune_panel_dragging;
vector tune_panel_drag_offset;
float  tune_panel_resizing;
vector tune_panel_resize_origin_size;
vector tune_panel_resize_origin_cursor;
float  tune_cursor_active;
vector tune_panel_scroll_offset;
float  tune_panel_current_tab;

// rcon password edit buffer (bottom bar, remote servers only).
string tune_rcon_text;
float  tune_rcon_cursor;
float  tune_rcon_active;

// _cursor_position, g_width, g_height, predicted_player, Debug_Button, Server_* are all declared/defined in
// earlier-compiled files — referenced directly here (no redeclare).

// =============================================================
//  Entry table builders
// =============================================================
void(string label, string cvarname, float side, string field,
     float step, float mn, float mx, float tab) Tune_Add =
{
    if (tune_count >= TUNE_MAX_ENTRIES) return;
    tune_label[tune_count] = label;
    tune_cvar [tune_count] = cvarname;
    tune_side [tune_count] = side;
    tune_field[tune_count] = field;
    tune_step [tune_count] = step;
    tune_mn   [tune_count] = mn;
    tune_mx   [tune_count] = mx;
    tune_tab  [tune_count] = tab;
    tune_desc [tune_count] = "";
    tune_count = tune_count + 1;
};

// Attach a hover tooltip to an already-added row (found by cvar name).  Called after the Tune_Add block so
// only the non-obvious rows get documented — the rest hover with no tooltip.
void(string cvarname, string desc) Tune_SetDesc =
{
    float i;
    for (i = 0; i < tune_count; i = i + 1)
        if (tune_cvar[i] == cvarname)
        {
            tune_desc[i] = desc;
            return;
        }
};

void() Tune_PanelInit =
{
    if (tune_panel_initialized) return;
    tune_panel_initialized = 1;
    tune_panel_size = '432 400 0';
    tune_panel_pos  = '60 48 0';
    tune_panel_current_tab = TUNE_TAB_DRIVE;
    tune_active_idx = -1;

    // ---- DRIVE ----
    Tune_Add("Mass",                    "sv_car_mass",           TUNE_SV, "mass",          50,  50, 8000, TUNE_TAB_DRIVE);
    Tune_Add("Acceleration",            "sv_car_accel",          TUNE_SV, "caraccel",      100, 0,  12000,TUNE_TAB_DRIVE);
    Tune_Add("Brake deceleration",      "sv_car_brake_decel",    TUNE_SV, "car_brakedecel",250, 0,  30000,TUNE_TAB_DRIVE);
    Tune_Add("Reverse fraction",        "sv_car_reverse_frac",   TUNE_SV, "",              0.05,0,  1,    TUNE_TAB_DRIVE);
    Tune_Add("Maximum speed",           "sv_car_max_speed",      TUNE_SV, "",              50,  100,5000, TUNE_TAB_DRIVE);
    Tune_Add("Gears",                   "sv_car_gears",          TUNE_SV, "",              1,   1,  8,    TUNE_TAB_DRIVE);
    Tune_Add("Shift time",              "sv_car_shift_time",     TUNE_SV, "",              0.05,0,  2,    TUNE_TAB_DRIVE);
    Tune_Add("Ignition time",           "sv_car_ignition_time",  TUNE_SV, "",              0.1, 0,  5,    TUNE_TAB_DRIVE);

    // ---- HANDLING (suspension + grip + steering) ----
    Tune_Add("Suspension softness",     "sv_car_suspension_softness",TUNE_SV,"suspension_softness",0.1,0.1,10, TUNE_TAB_HANDLING);
    Tune_Add("Suspension damping",      "sv_car_damping",        TUNE_SV, "car_damping",   0.05,0,  2,    TUNE_TAB_HANDLING);
    Tune_Add("Roll damping",            "sv_car_roll_damp",      TUNE_SV, "",              0.5, 0,  40,   TUNE_TAB_HANDLING);
    Tune_Add("Ride height",             "sv_car_ride_height",    TUNE_SV, "ride_height",       1, 0, 60, TUNE_TAB_HANDLING);
    Tune_Add("Compression travel",      "sv_car_compression_travel",TUNE_SV,"compression_travel",1,0,60, TUNE_TAB_HANDLING);
    Tune_Add("Grip",                    "sv_car_grip",           TUNE_SV, "grip",          0.25,0,  20,   TUNE_TAB_HANDLING);
    Tune_Add("Drift grip",              "sv_car_drift_grip",     TUNE_SV, "",              0.05,0,  1,    TUNE_TAB_HANDLING);
    Tune_Add("Grip response",           "sv_car_grip_response",  TUNE_SV, "",              0.05,0,  1,    TUNE_TAB_HANDLING);
    Tune_Add("Handbrake deceleration",  "sv_car_handbrake_decel",TUNE_SV, "",              250, 0,  30000,TUNE_TAB_HANDLING);
    Tune_Add("Park deceleration",       "sv_car_park_decel",     TUNE_SV, "",              50,  0,  5000, TUNE_TAB_HANDLING);
    Tune_Add("Drift tap time",          "sv_car_drift_tap_time", TUNE_SV, "",              0.02,0,  1,    TUNE_TAB_HANDLING);
    Tune_Add("Drift minimum speed",     "sv_car_drift_min_speed",TUNE_SV, "",              10,  0,  2000, TUNE_TAB_HANDLING);
    Tune_Add("Drift exit speed",        "sv_car_drift_exit",     TUNE_SV, "",              5,   0,  500,  TUNE_TAB_HANDLING);
    Tune_Add("Steering max angle",      "sv_car_steer_max",      TUNE_SV, "steer_max",     1,   1,  90,   TUNE_TAB_HANDLING);
    Tune_Add("Steering rate",           "sv_car_steer_rate",     TUNE_SV, "steer_rate",    5,   1,  720,  TUNE_TAB_HANDLING);
    Tune_Add("Yaw assist",              "sv_car_yaw_assist",     TUNE_SV, "yaw_assist",    10,  0,  1000, TUNE_TAB_HANDLING);
    Tune_Add("Yaw damping",             "sv_car_yaw_damp",       TUNE_SV, "",              0.5, 0,  40,   TUNE_TAB_HANDLING);

    // ---- WHEELS (physics + visual) ----
    Tune_Add("Wheel sink",              "sv_car_wheel_sink",     TUNE_SV, "wheel_sink",    1,   0,  60,   TUNE_TAB_WHEELS);
    Tune_Add("Wheel fore/aft",          "sv_car_wheel_fwd",      TUNE_SV, "wheel_fwd",     1,  -60, 60,   TUNE_TAB_WHEELS);
    Tune_Add("Render wheels",           "cl_car_wheels",         TUNE_CL, "",              1,   0,  1,    TUNE_TAB_WHEELS);
    Tune_Add("Visual tyre radius",      "cl_car_wheel_radius",   TUNE_CL, "",              0.5, 1,  40,   TUNE_TAB_WHEELS);
    Tune_Add("Visual height nudge",     "cl_car_wheel_z",        TUNE_CL, "",              0.5,-40, 40,   TUNE_TAB_WHEELS);
    Tune_Add("Spin direction",          "cl_car_wheel_spin",     TUNE_CL, "",              1,  -1,  1,    TUNE_TAB_WHEELS);
    Tune_Add("Steer direction",         "cl_car_wheel_steer",    TUNE_CL, "",              1,  -1,  1,    TUNE_TAB_WHEELS);
    Tune_Add("Visual fore/aft nudge",   "cl_car_wheel_fwd",      TUNE_CL, "",              1,  -60, 60,   TUNE_TAB_WHEELS);

    // ---- FX (driver, exhaust, camera, sound) ----
    Tune_Add("Show driver (server)",    "sv_car_show_driver",    TUNE_SV, "",              1,   0,  1,    TUNE_TAB_FX);
    Tune_Add("Render driver",           "cl_car_driver",         TUNE_CL, "",              1,   0,  1,    TUNE_TAB_FX);
    Tune_Add("Driver pose frame",       "cl_car_driver_frame",   TUNE_CL, "",              1,   0,  300,  TUNE_TAB_FX);
    Tune_Add("Exhaust smoke",           "cl_car_exhaust",        TUNE_CL, "",              1,   0,  1,    TUNE_TAB_FX);
    Tune_Add("Exhaust fore/aft",        "cl_car_exhaust_x",      TUNE_CL, "",              2,  -200,200,  TUNE_TAB_FX);
    Tune_Add("Exhaust left/right",      "cl_car_exhaust_y",      TUNE_CL, "",              2,  -100,100,  TUNE_TAB_FX);
    Tune_Add("Exhaust height",          "cl_car_exhaust_z",      TUNE_CL, "",              2,  -50, 100,  TUNE_TAB_FX);
    Tune_Add("Camera distance",         "cl_car_cam_dist",       TUNE_CL, "",              8,   0,  600,  TUNE_TAB_FX);
    Tune_Add("Camera height",           "cl_car_cam_height",     TUNE_CL, "",              4,  -100,300,  TUNE_TAB_FX);
    Tune_Add("Engine sound",            "cl_car_sound",          TUNE_CL, "",              1,   0,  1,    TUNE_TAB_FX);
    Tune_Add("Engine sound volume",     "cl_car_sound_volume",   TUNE_CL, "",              0.05,0,  1,    TUNE_TAB_FX);
    Tune_Add("Engine gear pitch step",  "cl_car_sound_gearstep", TUNE_CL, "",              1,   0,  30,   TUNE_TAB_FX);
    Tune_Add("Standing rev level",      "cl_car_sound_revfloor", TUNE_CL, "",              0.02,0,  1,    TUNE_TAB_FX);
    Tune_Add("Coasting engine volume",  "cl_car_sound_coastvol", TUNE_CL, "",              0.05,0,  1,    TUNE_TAB_FX);
    Tune_Add("Impact FX + slide",       "sv_car_impact_fx",      TUNE_SV, "",              1,   0,  1,    TUNE_TAB_FX);
    Tune_Add("Impact min speed",        "sv_car_impact_min_speed",TUNE_SV,"",              10,  0,  2000, TUNE_TAB_FX);
    Tune_Add("Impact cooldown",         "sv_car_impact_cooldown",TUNE_SV, "",              0.05,0,  2,    TUNE_TAB_FX);
    Tune_Add("Impact slide retain",     "sv_car_impact_slide_retain",TUNE_SV,"",           0.05,0,  1,    TUNE_TAB_FX);
    Tune_Add("Grind min speed",         "sv_car_grind_min_speed",TUNE_SV, "",              10,  0,  2000, TUNE_TAB_FX);
    Tune_Add("Grind FX interval",       "sv_car_grind_interval", TUNE_SV, "",              0.02,0.02,1,   TUNE_TAB_FX);

    // ---- BODY (collision, orientation, seat) ----
    Tune_Add("Collision (0 box/1 mesh)","sv_car_collision",      TUNE_SV, "",              1,   0,  1,    TUNE_TAB_BODY);
    Tune_Add("Collision box yaw",       "sv_car_box_yaw",        TUNE_SV, "",              90, -270,270,  TUNE_TAB_BODY);
    Tune_Add("Model yaw",               "sv_car_model_yaw",      TUNE_SV, "",              5,  -180,180,  TUNE_TAB_BODY);
    Tune_Add("Hit force",               "sv_car_hit_force",      TUNE_SV, "",              0.5, 0,  50,   TUNE_TAB_BODY);
    Tune_Add("Occupied push scale",     "sv_car_occupied_push_scale",TUNE_SV,"",           0.05,0,  2,    TUNE_TAB_BODY);
    Tune_Add("Seat height",             "sv_car_seat_up",        TUNE_SV, "seat_up",       1,  -40, 80,   TUNE_TAB_BODY);
    Tune_Add("Seat fore/aft",           "sv_car_seat_fwd",       TUNE_SV, "seat_fwd",      1,  -80, 80,   TUNE_TAB_BODY);
    Tune_Add("Seat left/right",         "sv_car_seat_side",      TUNE_SV, "seat_side",     1,  -60, 60,   TUNE_TAB_BODY);

    // Tooltips (hover a row) — only the non-obvious knobs.
    Tune_SetDesc("sv_car_acceleration",       "Engine pull, u/s^2. Engine force = accel x mass.");
    Tune_SetDesc("sv_car_suspension_softness","How far the car sinks under its OWN weight at rest. Bigger = softer. The spring strength is derived from mass, so this IS the softness knob.");
    Tune_SetDesc("sv_car_damping",            "Bounce control. 1 = critical (no bounce), <1 bouncier. Raise toward 1 for a planted feel.");
    Tune_SetDesc("sv_car_roll_damp",          "Anti-roll: damps body roll in corners (TrackMania-style planted feel). 0 = off / pure springs.");
    Tune_SetDesc("sv_car_ride_height",        "How high the body rides / ground clearance (spring free length). 0 = rides at the collision-box floor.");
    Tune_SetDesc("sv_car_compression_travel", "EXTRA squash on top of the resting sag - the landing cushion. Bump-stop = softness + this. Must be >0 or the car bottoms out.");
    Tune_SetDesc("sv_car_grip",               "Tyre lateral grip. Higher = sticks in corners; lower = slides/drifts.");
    Tune_SetDesc("sv_car_grip_response",      "How hard grip corrects sideways slip. Lower if the car shimmies side to side.");
    Tune_SetDesc("sv_car_drift_grip",         "Rear grip while drifting/handbraking. Lower = looser, longer slides.");
    Tune_SetDesc("sv_car_yaw_assist",         "Low-speed turn-in-place help (deg/s^2). Steer at a standstill to pivot.");
    Tune_SetDesc("sv_car_yaw_damp",           "Stops a parked/shot car spinning on its centre. 0 = off.");
    Tune_SetDesc("sv_car_collision",          "0 = oriented box; 1 = exact ACD mesh hull (player + world + bullets). Set 0 if a car dances.");
    Tune_SetDesc("sv_car_wheel_sink",         "Raises the box floor + wheel mounts so the model rests on its wheels. Dial until the tyres touch.");
    Tune_SetDesc("cl_car_exhaust_z",          "Tailpipe height ABOVE the car origin (origin sits at ground). Keep positive or the smoke is underground.");
    Tune_SetDesc("cl_car_driver_frame",       "Seated-driver pose animation frame (112 = crouch).");
    Tune_SetDesc("cl_car_wheel_radius",       "VISUAL tyre size (renders + sits the tyre on the ground). Match it to the physics ride height for a clean look.");
    Tune_SetDesc("cl_car_sound_maxspeed",     "Override the audio redline speed. 0 = auto-track the car's real sv_car_max_speed (recommended).");
    Tune_SetDesc("cl_car_sound_gearstep",     "How much higher each gear sounds on an up-shift (% pitch per gear). 0 = default (5). Raise if gears sound too similar; clamped to 30%.");
    Tune_SetDesc("cl_car_sound_revfloor",     "Rev level the THROTTLE alone reaches at ZERO speed - i.e. the note a standing start BEGINS on. Low (0.28) = launches start low and build with speed. High (0.8) = sounds mid-speed the moment you touch W.");
    Tune_SetDesc("cl_car_sound_coastvol",     "Engine volume when you're OFF the throttle (gliding/idle), vs full power. A downshift while coasting DOES raise the revs (engine braking is real) - this stops it also going LOUD, since no power is going in. 1 = old behaviour.");
    Tune_SetDesc("sv_car_impact_fx",          "Master toggle: when the car hits the world it SLIDES along the wall (keeps along-wall speed) and plays a metal impact/scrape + sparks + smoke. 0 = off (stops dead, no FX).");
    Tune_SetDesc("sv_car_impact_min_speed",   "How hard a wall hit must be to register (min speed AND one-tick speed drop, u/s). Lower = more sensitive.");
    Tune_SetDesc("sv_car_impact_cooldown",    "Minimum seconds between hard-hit clang sounds so a bounce doesn't machine-gun.");
    Tune_SetDesc("sv_car_impact_slide_retain","Fraction of along-wall speed kept on a hard hit. 1 = clean glance (most lenient), lower = more scrub.");
    Tune_SetDesc("sv_car_grind_min_speed",    "Minimum speed to keep the continuous scrape (looping sound + spark/smoke stream) going while pressed against a wall.");
    Tune_SetDesc("sv_car_grind_interval",     "Seconds between spark/smoke puffs while scraping along a wall. Lower = denser stream.");
};

// =============================================================
//  Value model
// =============================================================
float() Tune_InCar =
{
    return (predicted_player && predicted_player.pm_incar) ? TRUE : FALSE;
};

// Look a cvar name up in the carvals cache (the driven car's real values). Returns TRUE + sets *out via a
// file-global (QC has no out-params here) — we just return the value and use a sentinel found-flag global.
float tune_carval_found;
float(string cvarname) Tune_CarVal =
{
    float i;
    tune_carval_found = FALSE;
    for (i = 0; i < g_carval_count; i = i + 1)
    {
        if (g_carval_name[i] == cvarname)
        {
            tune_carval_found = TRUE;
            return g_carval[i];
        }
    }
    return 0;
};

// The value to DISPLAY for row i: the shadow (what you last set) wins; else, in a car, the car's real value
// (carvals) for SV rows with a per-car field; else the plain cvar.
float(float i) Tune_GetValue =
{
    if (tune_shadow_set[i])
        return tune_shadow[i];
    if (tune_side[i] == TUNE_SV && Tune_InCar() && tune_field[i] != "")
    {
        float cv = Tune_CarVal(tune_cvar[i]);
        if (tune_carval_found)
            return cv;
    }
    return cvar(tune_cvar[i]);
};

// Route a value edit for row i (the core of the panel — see file header).
void(float i, float v) Tune_SetValue =
{
    if (tune_mx[i] > tune_mn[i])
        v = bound(tune_mn[i], v, tune_mx[i]);

    tune_shadow[i]     = v;      // optimistic display shadow (immediate feedback everywhere)
    tune_shadow_set[i] = 1;

    if (tune_side[i] == TUNE_CL)
    {
        cvar_set(tune_cvar[i], ftos(v));          // client-only cvar — direct, immediate
        return;
    }

    // sv_car_* (server-authoritative)
    if (Tune_InCar() && tune_field[i] != "")
        localcmd(sprintf("cmd carset %s %g\n", tune_field[i], v));   // per-car live override
    else
        Server_SetFloat(tune_cvar[i], v);          // server default (rcon on remote, direct on listen)
};

// "Save as default": push every row's current value to its cvar (writes the tuned car as the server/client
// default for all cars).  cl_ rows are already their cvar; sv_ rows go through the rcon/local path.
void() Tune_SaveDefaults =
{
    float i;
    for (i = 0; i < tune_count; i = i + 1)
    {
        float v = Tune_GetValue(i);
        if (tune_side[i] == TUNE_CL)
            cvar_set(tune_cvar[i], ftos(v));
        else
            Server_SetFloat(tune_cvar[i], v);
    }
};

// Ask the server for the driven car's real current values, so the rows seed accurately.
void() Tune_RequestCarVals =
{
    if (Tune_InCar())
        localcmd("cmd carget\n");
};

void() Tune_ClearShadows =
{
    float i;
    for (i = 0; i < TUNE_MAX_ENTRIES; i = i + 1)
        tune_shadow_set[i] = 0;
};

// =============================================================
//  Toggle / open / close
// =============================================================
float() Tune_PanelOpen = { return tune_panel_open; };

void() Tune_PanelToggle =
{
    Tune_PanelInit();
    tune_panel_open = !tune_panel_open;

    if (tune_panel_open && !tune_cursor_active)
    {
        Tune_ClearShadows();          // reseed rows from live cvars / the car
        Tune_RequestCarVals();
        tune_rcon_text = cvar_string("rcon_password");
        tune_rcon_cursor = strlen(tune_rcon_text);
        setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
        tune_cursor_active = 1;
    }
    else if (!tune_panel_open && tune_cursor_active)
    {
        if (tune_active_idx >= 0)
        {
            Tune_SetValue(tune_active_idx, stof(tune_edit_text));
            tune_active_idx = -1;
        }
        setcursormode(FALSE);
        tune_cursor_active = 0;
    }
};

// Is this bind one of the car drive commands we let through so WASD still drives with the panel open?
float(string b) Tune_IsDriveBind =
{
    if (b == "+forward")   return TRUE;
    if (b == "+back")      return TRUE;
    if (b == "+moveleft")  return TRUE;
    if (b == "+moveright") return TRUE;
    if (b == "+moveup")    return TRUE;   // jump / handbrake
    if (b == "+movedown")  return TRUE;
    if (b == "+jump")      return TRUE;
    if (b == "+use")       return TRUE;   // dismount
    return FALSE;
};

float(float evtype, float scanx, float chary, float devid) Tune_PanelInputEvent =
{
    if (!tune_panel_open) return FALSE;
    if (evtype == IE_KEYDOWN && scanx == K_F3)     { Tune_PanelToggle(); return TRUE; }
    if (evtype == IE_KEYDOWN && scanx == K_ESCAPE) { Tune_PanelToggle(); return TRUE; }

    // Let car DRIVE keys fall through to the engine (return FALSE → the bind runs → the usercmd carries the
    // movement) so WASD still drives while tuning — UNLESS a value / rcon box is focused, where the keys type.
    // Only key up/down; the mouse (cursor/clicks) and typed characters stay captured by the panel.
    float typing = (tune_active_idx >= 0 || tune_rcon_active);
    if (!typing)
    {
        if (evtype == IE_KEYDOWN || evtype == IE_KEYUP)
        {
            if (Tune_IsDriveBind(getkeybind(scanx)))
                return FALSE;
        }
    }

    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};

// =============================================================
//  Title bar (mode indicator) + drag
// =============================================================
void() Tune_DrawTitleBar =
{
    sui_push_frame([0, 0], [tune_panel_size_x, TUNE_TITLE_H]);
    sui_fill([0, 0], [tune_panel_size_x, TUNE_TITLE_H], TUNE_TITLE_BG, 1, 0);
    sui_fill([0, TUNE_TITLE_H - 1], [tune_panel_size_x, 1], TUNE_BORDER, 1, 0);

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([8, 9], TUNE_FONT, "Car Tuning", TUNE_TEXT_1, 1, 0);

    // Mode indicator — where an edit lands right now.
    string mode; vector mcol;
    if (Tune_InCar()) { mode = "THIS CAR";       mcol = TUNE_MODE_CAR; }
    else              { mode = "SERVER DEFAULT";  mcol = TUNE_MODE_SRV; }
    float mw = stringwidth(mode, FALSE, TUNE_FONT);
    float close_w = TUNE_TITLE_H;
    sui_text([tune_panel_size_x - close_w - mw - 8, 9], TUNE_FONT, mode, mcol, 1, 0);

    sui_action_element([0, 0], [tune_panel_size_x - close_w, TUNE_TITLE_H], "tune_titlebar", sui_noop);
    if (Debug_Button("tune_close", [tune_panel_size_x - close_w, 0], [close_w, TUNE_TITLE_H],
                     "X", TUNE_BTN_CLOSE, TUNE_BTN_CLOSE_B))
        Tune_PanelToggle();

    sui_pop_frame();
};

void() Tune_HandleDrag =
{
    float held = sui_is_held("tune_titlebar");
    if (held && !tune_panel_dragging)
    {
        tune_panel_dragging = 1;
        tune_panel_drag_offset_x = _cursor_position_x - tune_panel_pos_x;
        tune_panel_drag_offset_y = _cursor_position_y - tune_panel_pos_y;
    }
    if (held && tune_panel_dragging)
    {
        tune_panel_pos_x = _cursor_position_x - tune_panel_drag_offset_x;
        tune_panel_pos_y = _cursor_position_y - tune_panel_drag_offset_y;
        if (tune_panel_pos_x < -tune_panel_size_x + 80) tune_panel_pos_x = -tune_panel_size_x + 80;
        if (tune_panel_pos_x > g_width - 80)            tune_panel_pos_x = g_width - 80;
        if (tune_panel_pos_y < 0)                       tune_panel_pos_y = 0;
        if (tune_panel_pos_y > g_height - TUNE_TITLE_H)  tune_panel_pos_y = g_height - TUNE_TITLE_H;
    }
    if (!held) tune_panel_dragging = 0;
};

// =============================================================
//  Tab strip
// =============================================================
void(string label, float tab_id, float x, float w) Tune_DrawOneTab =
{
    string id = sprintf("tune_tab_%g", tab_id);
    vector col  = (tune_panel_current_tab == tab_id) ? TUNE_BTN_ON      : TUNE_BTN_OFF;
    vector bord = (tune_panel_current_tab == tab_id) ? TUNE_BTN_ON_BORD : TUNE_BTN_OFF_BORD;
    if (Debug_Button(id, [x, 3], [w, TUNE_TAB_STRIP_H - 6], label, col, bord))
    {
        if (tune_panel_current_tab != tab_id)
        {
            if (tune_active_idx >= 0) { Tune_SetValue(tune_active_idx, stof(tune_edit_text)); tune_active_idx = -1; }
            tune_panel_current_tab = tab_id;
            tune_panel_scroll_offset = '0 0 0';
        }
    }
};

void() Tune_DrawTabStrip =
{
    sui_push_frame([0, TUNE_TITLE_H], [tune_panel_size_x, TUNE_TAB_STRIP_H]);
    sui_fill([0, 0], [tune_panel_size_x, TUNE_TAB_STRIP_H], TUNE_TITLE_BG, 1, 0);
    sui_fill([0, TUNE_TAB_STRIP_H - 1], [tune_panel_size_x, 1], TUNE_BORDER, 1, 0);

    float gap = 2;
    float available = tune_panel_size_x - TUNE_PAD * 2 - gap * (TUNE_TAB_COUNT - 1);
    float tab_w = floor(available / TUNE_TAB_COUNT);
    float x = TUNE_PAD;
    Tune_DrawOneTab("Drive",    TUNE_TAB_DRIVE,    x, tab_w); x += tab_w + gap;
    Tune_DrawOneTab("Handling", TUNE_TAB_HANDLING, x, tab_w); x += tab_w + gap;
    Tune_DrawOneTab("Wheels",   TUNE_TAB_WHEELS,   x, tab_w); x += tab_w + gap;
    Tune_DrawOneTab("FX",       TUNE_TAB_FX,       x, tab_w); x += tab_w + gap;
    Tune_DrawOneTab("Body",     TUNE_TAB_BODY,     x, tab_w);
    sui_pop_frame();
};

// =============================================================
//  One tuning row:  label   [<]  value(click-to-type)  [>]
// =============================================================
void(float i, float row_y, float row_w) Tune_DrawRow =
{
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    float ctl_w   = floor(row_w * 0.38);           // arrows + value box on the right (labels get the wider left)
    float lbl_w   = row_w - ctl_w;
    float ctl_x   = TUNE_PAD + lbl_w;
    float val_x   = ctl_x + TUNE_ARROW_W + 2;
    float val_w   = ctl_w - (TUNE_ARROW_W + 2) * 2;
    float row_h   = TUNE_ROW_H;

    // label (+ a hover zone over the label area → drives the tooltip; registered BEFORE the arrows/box so
    // those keep click/hover priority over their own sub-areas)
    sui_text([TUNE_PAD + 2, row_y + 6], TUNE_FONT, tune_label[i], TUNE_TEXT_2, 1, 0);
    if (tune_desc[i] != "")
    {
        string hid = sprintf("tune_lbl_%g", i);
        sui_action_element([TUNE_PAD, row_y], [lbl_w, row_h], hid, sui_noop);
        if (sui_is_hovered(hid))
            tune_hover_idx = i;
    }

    // < decrement
    if (Debug_Button(sprintf("tune_dec_%g", i), [ctl_x, row_y + 1], [TUNE_ARROW_W, row_h - 2],
                     "<", TUNE_ARROW_BG, TUNE_ARROW_BORD))
        Tune_SetValue(i, Tune_GetValue(i) - tune_step[i]);

    // > increment
    if (Debug_Button(sprintf("tune_inc_%g", i), [ctl_x + ctl_w - TUNE_ARROW_W, row_y + 1],
                     [TUNE_ARROW_W, row_h - 2], ">", TUNE_ARROW_BG, TUNE_ARROW_BORD))
        Tune_SetValue(i, Tune_GetValue(i) + tune_step[i]);

    // value box (click to type an exact number)
    sui_push_frame([val_x, row_y + 1], [val_w, row_h - 2]);
    float was_active = (tune_active_idx == i);
    vector inp_bg   = was_active ? '0.20 0.17 0.10' : TUNE_HEADER_BG;
    vector inp_bord = was_active ? '0.60 0.50 0.28' : TUNE_BORDER;
    sui_fill([0, 0], [val_w, row_h - 2], inp_bg, 0.85, 0);
    sui_border_box([0, 0], [val_w, row_h - 2], 1, inp_bord, 1, 0);

    sui_reread_input();
    string id_input = sprintf("tune_v_%g", i);
    sui_text_input(id_input, [3, 0], [val_w - 6, row_h - 2], tune_edit_text, tune_edit_cursor);
    sui_cap_input_length(12, tune_edit_text, tune_edit_cursor);

    float now_focused = sui_is_last_clicked(id_input);
    if (now_focused && !was_active)
    {
        if (tune_active_idx >= 0) Tune_SetValue(tune_active_idx, stof(tune_edit_text));
        tune_active_idx  = i;
        tune_edit_text   = sprintf("%g", Tune_GetValue(i));
        tune_edit_cursor = strlen(tune_edit_text);
    }
    else if (!now_focused && was_active)
    {
        Tune_SetValue(i, stof(tune_edit_text));
        tune_active_idx = -1;
    }

    // When editing, LEFT-align the text at [3,…] so it lines up with the caret (which is drawn from x=3);
    // when just displaying a value, CENTER it for a tidy read-out.
    if (tune_active_idx == i)
    {
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
        sui_text([3, 1], TUNE_FONT, tune_edit_text, TUNE_TEXT_1, 1, 0);
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
        float cx = stringwidth(substring(tune_edit_text, 0, tune_edit_cursor), 1, TUNE_FONT);
        sui_fill([3 + cx, 4], [1, 8], TUNE_TEXT_1, fabs(sin(time * 4)), 0);
    }
    else
    {
        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        sui_text([0, 1], TUNE_FONT, sprintf("%g", Tune_GetValue(i)), TUNE_TEXT_1, 1, 0);
    }
    sui_pop_frame();
};

// =============================================================
//  Body — scrollable rows filtered by current tab
// =============================================================
void() Tune_DrawBody =
{
    float body_y0 = TUNE_TITLE_H + TUNE_TAB_STRIP_H;
    float body_h  = tune_panel_size_y - body_y0 - TUNE_FOOT_H;
    float body_w  = tune_panel_size_x;

    sui_push_frame([0, body_y0], [body_w, body_h]);
    sui_fill([0, 0], [body_w, body_h], TUNE_BG_DARKER, 1, 0);

    float content_h = 0;
    float i;
    for (i = 0; i < tune_count; i = i + 1)
        if (tune_tab[i] == tune_panel_current_tab)
            content_h = content_h + TUNE_ROW_H;

    sui_scroll_view_begin("tune_body_scroll", [0, 0], [body_w, body_h],
        [body_w - TUNE_VBAR_W, content_h], tune_panel_scroll_offset, [0, TUNE_VBAR_W]);

    float row_w = body_w - TUNE_VBAR_W - TUNE_PAD * 2;
    float y = 0;
    float vp_top    = tune_panel_scroll_offset_y - TUNE_ROW_H;
    float vp_bottom = tune_panel_scroll_offset_y + body_h + TUNE_ROW_H;

    for (i = 0; i < tune_count; i = i + 1)
    {
        if (tune_tab[i] != tune_panel_current_tab) continue;
        float row_y = y;
        if (row_y + TUNE_ROW_H >= vp_top && row_y <= vp_bottom)
            Tune_DrawRow(i, row_y, row_w);
        y = y + TUNE_ROW_H;
    }

    sui_scroll_view_end();
    sui_pop_frame();
};

// =============================================================
//  Bottom bar — Save as default / Write config + rcon box + resize grip
// =============================================================
void() Tune_DrawBottomBar =
{
    float by = tune_panel_size_y - TUNE_FOOT_H;
    sui_push_frame([0, by], [tune_panel_size_x, TUNE_FOOT_H]);
    sui_fill([0, 0], [tune_panel_size_x, TUNE_FOOT_H], TUNE_TITLE_BG, 1, 0);
    sui_fill([0, 0], [tune_panel_size_x, 1], TUNE_BORDER, 1, 0);

    // Row 1: action buttons.
    float bw = floor((tune_panel_size_x - TUNE_PAD * 3) * 0.5);
    if (Debug_Button("tune_savedef", [TUNE_PAD, 4], [bw, 16], "Save as default", TUNE_BTN_ON, TUNE_BTN_ON_BORD))
        Tune_SaveDefaults();
    if (Debug_Button("tune_writecfg", [TUNE_PAD * 2 + bw, 4], [bw, 16], "Write config", TUNE_BTN_OFF, TUNE_BTN_OFF_BORD))
        Server_RunCommand("writecvars");

    // Row 2: rcon password (only meaningful for a remote server).
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    if (Server_IsRemote())
    {
        sui_text([TUNE_PAD + 2, 26], TUNE_FONT, "rcon pw:", TUNE_TEXT_2, 1, 0);
        float rx = TUNE_PAD + 56;
        float rw = tune_panel_size_x - rx - TUNE_PAD;
        sui_push_frame([rx, 24], [rw, 14]);
        sui_fill([0, 0], [rw, 14], TUNE_HEADER_BG, 0.85, 0);
        sui_border_box([0, 0], [rw, 14], 1, TUNE_BORDER, 1, 0);
        sui_reread_input();
        sui_text_input("tune_rconpw", [3, 0], [rw - 6, 14], tune_rcon_text, tune_rcon_cursor);
        sui_cap_input_length(64, tune_rcon_text, tune_rcon_cursor);
        if (sui_is_last_clicked("tune_rconpw"))
            tune_rcon_active = 1;
        else if (tune_rcon_active)
        {
            cvar_set("rcon_password", tune_rcon_text);   // commit on focus loss
            tune_rcon_active = 0;
        }
        // masked display (dots)
        string masked = "";
        float k; for (k = 0; k < strlen(tune_rcon_text); k = k + 1) masked = strcat(masked, ".");
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
        sui_text([3, 1], TUNE_FONT, masked, TUNE_TEXT_1, 1, 0);
        sui_pop_frame();
    }
    else
    {
        sui_text([TUNE_PAD + 2, 27], TUNE_FONT, "listen server - local set", TUNE_TEXT_2, 1, 0);
    }

    // Resize grip (bottom-right hatch).
    float gx = tune_panel_size_x - 12;
    if (sui_is_hovered("tune_resize"))
        sui_fill([gx, TUNE_FOOT_H - 12], [12, 12], '0.22 0.19 0.12', 0.5, 0);
    float j;
    for (j = 2; j < 12; j = j + 3)
        sui_fill([gx + 12 - j - 1, TUNE_FOOT_H - 12 + j], [j + 1, 1], TUNE_TEXT_2, 0.7, 0);
    sui_action_element([gx, TUNE_FOOT_H - 12], [12, 12], "tune_resize", sui_noop);

    sui_pop_frame();
};

void() Tune_HandleResize =
{
    float held = sui_is_held("tune_resize");
    if (held && !tune_panel_resizing)
    {
        tune_panel_resizing = 1;
        tune_panel_resize_origin_size   = tune_panel_size;
        tune_panel_resize_origin_cursor = _cursor_position;
    }
    if (held && tune_panel_resizing)
    {
        tune_panel_size_x = tune_panel_resize_origin_size_x + (_cursor_position_x - tune_panel_resize_origin_cursor_x);
        tune_panel_size_y = tune_panel_resize_origin_size_y + (_cursor_position_y - tune_panel_resize_origin_cursor_y);
        if (tune_panel_size_x < 300) tune_panel_size_x = 300;
        if (tune_panel_size_y < 220) tune_panel_size_y = 220;
        if (tune_panel_size_x > 640) tune_panel_size_x = 640;
        if (tune_panel_size_y > 600) tune_panel_size_y = 600;
    }
    if (!held) tune_panel_resizing = 0;
};

// Draw the hover tooltip: word-wrap `text` to ~34 chars/line and box it near the cursor (screen space).
void(string text) Tune_DrawTooltip =
{
    float maxc = 34;
    float nl = 0;
    string cur = "";
    float ntok = tokenize(text);   // splits on whitespace
    float k;
    for (k = 0; k < ntok; k = k + 1)
    {
        string w = argv(k);
        string trial = (cur == "") ? w : strcat(cur, " ", w);
        if (strlen(trial) > maxc && cur != "")
        {
            if (nl < 8) { tune_tip_line[nl] = cur; nl = nl + 1; }
            cur = w;
        }
        else
            cur = trial;
    }
    if (cur != "" && nl < 8) { tune_tip_line[nl] = cur; nl = nl + 1; }
    if (nl < 1) return;

    float lh   = 10;
    float boxw = maxc * 6 + 8;
    float boxh = nl * lh + 6;
    float tx = _cursor_position_x + 14;
    float ty = _cursor_position_y + 14;
    if (tx + boxw > g_width)  tx = g_width - boxw - 2;
    if (ty + boxh > g_height) ty = _cursor_position_y - boxh - 6;
    if (tx < 0) tx = 0;
    if (ty < 0) ty = 0;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_fill([tx, ty], [boxw, boxh], '0.05 0.04 0.02', 0.96, 0);
    sui_border_box([tx, ty], [boxw, boxh], 1, TUNE_BTN_ON_BORD, 1, 0);
    for (k = 0; k < nl; k = k + 1)
        sui_text([tx + 4, ty + 3 + k * lh], TUNE_FONT, tune_tip_line[k], TUNE_TEXT_1, 1, 0);
};

// =============================================================
//  Main draw — called from CSQC_UpdateView inside sui_begin/end.
// =============================================================
void() Tune_PanelDraw =
{
    if (!tune_panel_open) return;
    Tune_PanelInit();

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_fill([tune_panel_pos_x + 3, tune_panel_pos_y + 3], tune_panel_size, TUNE_SHADOW, 0.45, 0);

    if (tune_panel_pos_x > g_width - 80)            tune_panel_pos_x = g_width - 80;
    if (tune_panel_pos_y > g_height - TUNE_TITLE_H)  tune_panel_pos_y = g_height - TUNE_TITLE_H;

    sui_push_frame(tune_panel_pos, tune_panel_size);
    sui_fill([0, 0], tune_panel_size, TUNE_BG, 0.94, 0);
    sui_border_box([0, 0], tune_panel_size, 2, TUNE_BORDER, 1, 0);

    tune_hover_idx = -1;              // recomputed by Tune_DrawRow's hover zones this frame
    Tune_DrawTitleBar();
    Tune_DrawTabStrip();
    Tune_DrawBody();
    Tune_DrawBottomBar();
    Tune_HandleDrag();
    Tune_HandleResize();

    sui_pop_frame();

    // Tooltip LAST, in screen space (outside the panel frame) so it floats over everything at the cursor.
    // NESTED ifs (NOT `idx>=0 && desc[idx]`): fteqcc has logic-ops-off, so `&&` evaluates BOTH sides →
    // `tune_desc[-1]` would run when nothing is hovered and crash on the array boundcheck.
    if (tune_hover_idx >= 0)
        if (tune_desc[tune_hover_idx] != "")
            Tune_DrawTooltip(tune_desc[tune_hover_idx]);
};

// Store the server's carget reply "carvals <cvar> <val> <cvar> <val> …" (called from CSQC_ConsoleCommand).
void(string cmd) Tune_StoreCarVals =
{
    float n = tokenize(cmd);
    g_carval_count = 0;
    float i;
    for (i = 1; i + 1 < n; i = i + 2)
    {
        if (g_carval_count >= TUNE_CARVAL_MAX) break;
        g_carval_name[g_carval_count] = argv(i);
        g_carval     [g_carval_count] = stof(argv(i + 1));
        g_carval_count = g_carval_count + 1;
    }
};
