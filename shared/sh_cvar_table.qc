// ============================================================
//  shared/sh_cvar_table.qc  -  Single source of truth for every
//  custom cvar registered by the mod, on both CSQC and SSQC.
//
//  - CVar_Init() builds the table (sequential CVar_Add calls).
//    Edit the DEFAULT ZONE below to change any default.
//  - CVar_RegisterMine() iterates the table and registercvar()'s
//    only the entries flagged for the current VM (CL or SV).
//  - CVar_ForceDefaults() (SSQC only) re-applies the table's
//    defaults to any cvar blanked by cfg/server.cfg exec.
//  - CVar_WriteAllCommandsCfg() (SSQC only) overwrites
//    cfg/allcommands.cfg from the table, preserving section
//    headers. Triggered by `sv_writecvars 1` in the console
//    (the cvar self-resets to 0 after writing — same admin-
//    trigger pattern as sv_roundrestart in StartFrame).
//
//  Compiled by both sv_progs.src and cl_progs.src.
// ============================================================

const float CVAR_SIDE_CL   = 1;
const float CVAR_SIDE_SV   = 2;
const float CVAR_SIDE_BOTH = 3;

// The cvar registry (g_cvar_* parallel arrays below) is what auto-generates
// cfg/allcommands.cfg and the settings menu — it must list every cvar with
// its default.  QuakeC has no dynamic arrays, so the arrays are STATICALLY
// sized to this cap, and CVar_Add's overflow guard SILENTLY drops everything
// past it (a dropped cl_ads_* shows up as the "cl_ads_<weapon> missing" bug).
// So this must stay comfortably above the live entry count
//   (grep -cE "^\s*CVar_Add(UI)?\(" sh_cvar_table.qc, plus 6 per
//    ADS_RegisterPoseCvars call).  ~705 used at 1280 → lots of headroom for
// the growing weapon roster.  History: 256 → 512 → 768 → 1280.
const float CVAR_TABLE_MAX = 1280;

// ---------- UI metadata constants ----------
//
// Optional per-cvar UI annotations.  Entries added with the legacy
// CVar_Add() leave these at 0/empty and don't appear in any menu;
// CVar_AddUI() takes the same args plus the UI fields below.
//
// Two consumers iterate the UI metadata:
//   • CSQC F2 server panel        (client/cl_serverpanel.qc)
//   • Menu Create Server screen   (menu/m_createserver.qc)
// Each consumer reads only the rows whose CVAR_TAB_* bit is set in
// the entry's ui_tabs mask.

// Control kinds.  Match the SV_KIND_* constants in cl_serverpanel.qc
// in numeric value AND order (TOGGLE=0, SCALAR=1, ENUM=2, STRING=3,
// ACTION=4, ENUM_MULTI=5, HEADER=6) so the panel can pass the kind
// through verbatim without remapping.
const float CVAR_UI_NONE       = 0;   // not exposed in any menu
const float CVAR_UI_TOGGLE     = 1;   // 0/1 button
const float CVAR_UI_SCALAR     = 2;   // numeric text-input or slider
const float CVAR_UI_ENUM       = 3;   // single-select dropdown (uses ui_enum)
const float CVAR_UI_STRING     = 4;   // free-form string input
const float CVAR_UI_ACTION     = 5;   // momentary button (cvar acts as trigger)
const float CVAR_UI_ENUM_MULTI = 6;   // bitmask multi-select (utility loadout)
const float CVAR_UI_HEADER     = 7;   // section separator (no cvar binding)

// Tab bitmask.  A single cvar can appear in multiple tabs/menus by
// OR'ing the relevant bits.  First five bits map to the F2 panel's
// tabs (RCON/MULTI/SERVER/DEBUG/ODE); the higher bits map to the
// Create Server menu's tabs.
const float CVAR_TAB_RCON          = 1;
const float CVAR_TAB_MULTI         = 2;
const float CVAR_TAB_SERVER        = 4;
const float CVAR_TAB_DEBUG         = 8;
const float CVAR_TAB_ODE           = 16;
const float CVAR_TAB_CREATE_SERVER = 32;
const float CVAR_TAB_CREATE_GAME   = 64;
const float CVAR_TAB_CREATE_MOVE   = 128;
const float CVAR_TAB_CREATE_PHYS   = 256;
const float CVAR_TAB_VOICE         = 512;  // F1 settings menu's "Voice" tab (client-side only)
// Convenience masks for "any F2-panel tab" / "any Create Server tab".
const float CVAR_TAB_PANEL_ANY  = 31;    // RCON|MULTI|SERVER|DEBUG|ODE
const float CVAR_TAB_CREATE_ANY = 480;   // CREATE_SERVER|CREATE_GAME|CREATE_MOVE|CREATE_PHYS

// Per-row flag bits.
const float CVAR_FLAG_SCOPE_LOCAL        = 1;   // listen-only / client cvar (no rcon route)
const float CVAR_FLAG_ACCENT_GOLD        = 2;   // gold styling (rcon password row)
const float CVAR_FLAG_NO_LOCAL_FALLBACK  = 4;   // remote read uses serverkey only, never local cvar()
const float CVAR_FLAG_SAVE_TO_SERVER_CFG = 8;   // include in CVar_WriteServerCfg dump
const float CVAR_FLAG_HIDE_FROM_RCON     = 16;  // F2-panel hides on remote sessions

// Enum source IDs.  Each consumer translates these to its own option
// list (gamemode names, tickrate values, weapon-manifest loadouts,
// map cycle entries).  Adding an enum source = adding a constant
// here + a case in each consumer's dispatch.
const float CVAR_ENUM_NONE              = 0;
const float CVAR_ENUM_TICKRATE          = 1;   // sv_mintic — values from sv_tickrate_values[]
const float CVAR_ENUM_GAMEMODE          = 2;   // sv_gamemode — labels via Server_GamemodeLabel
const float CVAR_ENUM_LOADOUT_PRIMARY   = 3;
const float CVAR_ENUM_LOADOUT_SECONDARY = 4;
const float CVAR_ENUM_LOADOUT_MELEE     = 5;
const float CVAR_ENUM_LOADOUT_UTILITY   = 6;   // multi-select (CVAR_UI_ENUM_MULTI)
const float CVAR_ENUM_MAP_CYCLE         = 7;   // pseudo-source for __cycle_map row

string g_cvar_name   [CVAR_TABLE_MAX];
string g_cvar_default[CVAR_TABLE_MAX];
string g_cvar_section[CVAR_TABLE_MAX];
float  g_cvar_side   [CVAR_TABLE_MAX];
float  g_cvar_count;

// UI metadata, parallel to the registration arrays above.  Indexed by
// the same i.  Entries added via CVar_Add() leave all these at 0/"".
string g_cvar_ui_label[CVAR_TABLE_MAX];
float  g_cvar_ui_kind [CVAR_TABLE_MAX];
float  g_cvar_ui_tabs [CVAR_TABLE_MAX];
float  g_cvar_ui_flags[CVAR_TABLE_MAX];
float  g_cvar_ui_enum [CVAR_TABLE_MAX];
float  g_cvar_ui_min  [CVAR_TABLE_MAX];
float  g_cvar_ui_max  [CVAR_TABLE_MAX];

void(string section, string name, string def, float side) CVar_Add =
{
    if (g_cvar_count >= CVAR_TABLE_MAX) return;
    g_cvar_section[g_cvar_count] = section;
    g_cvar_name   [g_cvar_count] = name;
    g_cvar_default[g_cvar_count] = def;
    g_cvar_side   [g_cvar_count] = side;
    g_cvar_count = g_cvar_count + 1;
};

// CVar_AddUI — register AND attach UI metadata in one call.  Pass an
// empty label to fall back to the cvar name.  Pass min == max to
// disable range hints.
void(string section, string name, string def, float side,
     float ui_kind, float ui_tabs, string label, float ui_flags,
     float ui_enum, float ui_min, float ui_max) CVar_AddUI =
{
    if (g_cvar_count >= CVAR_TABLE_MAX) return;
    float i = g_cvar_count;
    CVar_Add(section, name, def, side);
    g_cvar_ui_label[i] = label;
    g_cvar_ui_kind [i] = ui_kind;
    g_cvar_ui_tabs [i] = ui_tabs;
    g_cvar_ui_flags[i] = ui_flags;
    g_cvar_ui_enum [i] = ui_enum;
    g_cvar_ui_min  [i] = ui_min;
    g_cvar_ui_max  [i] = ui_max;
};

// CVar_AddSaved — like CVar_Add, but ALSO persisted to cfg/server.cfg by
// CVar_WriteServerCfg (no menu UI).  Use for server-side cvars that should be
// admin-saveable but aren't worth a Create-Server menu entry (e.g. sv_carry_*).
void(string section, string name, string def, float side) CVar_AddSaved =
{
    float i = g_cvar_count;
    CVar_Add(section, name, def, side);
    if (i < g_cvar_count)
        g_cvar_ui_flags[i] = g_cvar_ui_flags[i] | CVAR_FLAG_SAVE_TO_SERVER_CFG;
};

// Find the manifest index for a cvar name.  Returns -1 if not in the
// table.  Linear scan — table size is bounded (151 entries today,
// CVAR_TABLE_MAX of 256 ceiling) so this is fine for menu init paths.
float(string name) CVar_FindIndex =
{
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
        if (g_cvar_name[i] == name)
            return i;
    return -1;
};

// Register a per-weapon ADS pose override set: <prefix>_pitch/yaw/roll/
// forward/right/down.  cl_viewfx.qc reads them via the weapon's
// weapon_ads_prefix field.
//
// These used to be registered at a generic baseline here and then OVERRIDDEN by
// 93 `set cl_ads_*` lines in cfg/default.cfg — which meant the real, tuned sight
// alignment for 29 guns lived in a cfg while the table advertised numbers nobody
// used.  They survived the cvar purge only because cvar_audit.py cannot see names
// built with strcat (it says so in its own header).  The tuned values now live
// here; default.cfg carries no cl_ads_* at all.
void(string prefix, string pitch, string yaw, string roll,
     string fwd, string right, string down) ADS_RegisterPose =
{
    CVar_Add("Client", strcat(prefix, "_pitch"),   pitch, CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_yaw"),     yaw,   CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_roll"),    roll,  CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_forward"), fwd,   CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_right"),   right, CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_down"),    down,  CVAR_SIDE_CL);
};

// Baseline pose — for a weapon that has never been tuned.  Must stay in sync
// with the shared cl_ads_* fallback set registered in CVar_Init.
void(string prefix) ADS_RegisterPoseCvars =
{
    ADS_RegisterPose(prefix, "0", "0", "0", "-5", "6.69", "2");
};

// ============================================================
//  ===  DEFAULT ZONE — edit here to change any default.  ===
//
//  Order within sections is the order the writer emits to
//  cfg/allcommands.cfg. Group new entries under an existing
//  section header or add a new section by passing a new label.
// ============================================================
void() CVar_Init =
{
    g_cvar_count = 0;

    // ---------- Bots / Navigation ----------
    CVar_Add("Bots", "bot_minplayers",    "0",  CVAR_SIDE_SV);  // fill total players up to N with bots (0 = off)
    CVar_Add("Bots", "botadd",            "0",  CVAR_SIDE_SV);  // momentary: add this many bots, then resets to 0
    CVar_Add("Bots", "botkick",           "0",  CVAR_SIDE_SV);  // momentary: kick this many bots, then resets to 0
    CVar_Add("Bots", "bot_skill",         "50", CVAR_SIDE_SV);  // 0-100: reaction time + aim turn-rate
    CVar_Add("Bots", "bot_fov",           "150",CVAR_SIDE_SV);  // frontal ACQUISITION cone, full angle deg (<=0 or >=360 = 360/off); tracking stays 360
    CVar_Add("Bots", "bot_los_grace",     "0.35",CVAR_SIDE_SV); // keep engaging this long (s) after a momentary LOS break (anti-flicker)
    CVar_Add("Bots", "bot_target_margin", "0.85",CVAR_SIDE_SV); // only swap to a new enemy if it is <this fraction of the current target's distance
    CVar_Add("Bots", "bot_debug",         "0",  CVAR_SIDE_SV);  // developer: log bot fill/activity
    CVar_Add("Bots", "bot_avoid",         "1",  CVAR_SIDE_SV);  // bots sidestep walls + each other (run-time lookahead trace + separation)
    CVar_Add("Bots", "sv_nav_gridstep",   "96", CVAR_SIDE_SV);  // auto-grid node spacing (units)
    CVar_Add("Bots", "sv_debug_nav",      "0",  CVAR_SIDE_SV);  // stream nav graph + bot state to clients (debug draw)
    CVar_Add("Bots", "cl_navdebug_range", "0",  CVAR_SIDE_CL);  // sv_debug_nav draw: only nav nodes within this many units of the camera (0 = whole network)

    // --- Vehicles (prop_car / func_car raycast physics) — a per-car FGD key of 0 falls back to these ---
    CVar_Add("Vehicles", "sv_debug_car",             "0",     CVAR_SIDE_SV);  // draw the car physics overlay (box/wheels/steer/velocity)
    CVar_Add("Vehicles", "sv_car_debug_dist",        "2500",  CVAR_SIDE_SV);  // overlay only draws cars within this of the viewer (0 = unlimited); nearest 16 max
    CVar_Add("Vehicles", "sv_car_mass",              "1200",  CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_accel",             "3200",  CVAR_SIDE_SV);  // throttle ACCELERATION (u/s²); engine force = accel × mass. 3200 paces the gears (5000 = instant redline)
    CVar_Add("Vehicles", "sv_car_brake_decel",       "9000",  CVAR_SIDE_SV);  // brake DECELERATION (u/s²) — holding S while rolling forward stops you
    CVar_Add("Vehicles", "sv_car_reverse_frac",      "0.4",   CVAR_SIDE_SV);  // reverse strength as a fraction of drive force (S once stopped)
    CVar_Add("Vehicles", "sv_car_max_speed",         "1100",  CVAR_SIDE_SV);  // KEEP cl_car_sound_maxspeed matched (audio redline)
    // Virtual gearbox (audio-visible drive cadence; physics has no real transmission):
    // shifting UP cuts the throttle for shift_time (the "lift, jerk, pull" between gears);
    // ignition_time = throttle dead after mounting while the starter cranks.
    CVar_Add("Vehicles", "sv_car_gears",             "4",     CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_shift_time",        "0.25",  CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_ignition_time",     "1.2",   CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_suspension_softness","1.2",  CVAR_SIDE_SV);  // SOFTNESS = how far the car sinks under its OWN weight at rest (bigger = softer); spring k = mass·g/(wheels·softness) so it's mass-derived — there is NO separate strength knob (was sv_car_ride_sag / sv_car_susp_k)
    CVar_Add("Vehicles", "sv_car_damping",           "0.6",   CVAR_SIDE_SV);  // suspension damping RATIO (1 = critical / no bounce; <1 = bouncier). 0.6 ≈ near-critical (was sv_car_susp_c)
    CVar_Add("Vehicles", "sv_car_ride_height",       "18",    CVAR_SIDE_SV);  // spring free length: how high the body rides above the ground (the single ground-clearance datum; folds in the old wheel_radius)
    CVar_Add("Vehicles", "sv_car_compression_travel","12",    CVAR_SIDE_SV);  // EXTRA compression on top of the resting sag — the landing cushion (bump-stop = softness + this)
    CVar_Add("Vehicles", "sv_car_wheel_sink",        "18",    CVAR_SIDE_SV);  // raise the box floor + wheel mounts so the model rests on its wheels — dial until the tyres touch
    CVar_Add("Vehicles", "sv_car_grip",              "1",     CVAR_SIDE_SV);  // tire lateral grip (× per-wheel load); lower = more drift / less turn-scrub
    CVar_Add("Vehicles", "sv_car_drift_grip",        "0.35",  CVAR_SIDE_SV);  // REAR grip scale while drifting/handbraking — lower = looser drift
    CVar_Add("Vehicles", "sv_car_grip_response",     "0.5",   CVAR_SIDE_SV);  // share of lateral slip cancelled per tick (0..1); 1 = stiff/wobbly, lower = softer/driftier + stable
    CVar_Add("Vehicles", "sv_car_handbrake_decel",   "9000",  CVAR_SIDE_SV);  // HOLD Space brake deceleration (u/s²) — stop quickly
    CVar_Add("Vehicles", "sv_car_park_decel",        "600",   CVAR_SIDE_SV);  // driverless coast-to-stop deceleration (u/s²) after you hop out
    // Parked-car sleep.  DEFAULT 0 = OFF: this is BROKEN ON BOX3D (the default backend) and the
    // damage is much worse than "a parked car doesn't get nudged" — parked cars go COMPLETELY
    // NON-COLLIDABLE and other cars drive straight through them.
    //
    // Why: a raycast-suspended car is held at ride height ONLY by per-tick QC suspension forces and
    // has no ground contacts, so simply skipping Car_PhysStep makes it free-fall — it can never
    // reach the backend's own sleep threshold at ride height.  The only way to freeze it in place is
    // an explicit physics_enable(car, FALSE).  But Box3D is a Box2D-3D fork, and b2/b3Body_Disable
    // REMOVES THE BODY FROM THE SIMULATION (shapes leave the broadphase) — so it stops colliding
    // with everything, not just stops moving.  (ODE differs: dBodyDisable leaves the geom in the
    // space, colliding as static — so this would be safe-ish there, hence a cvar and not a delete.)
    //
    // The win was small anyway (~1% of a server core: Car_PhysStep/Car_Cvar/Car_WheelLocal for
    // parked cars), and the parked-car cvar reads it also saved are already cached per-frame.
    // Do NOT set 1 on Box3D.  Fixing it properly needs a freeze that keeps the body collidable —
    // e.g. a kinematic/static swap, or zeroing gravity + velocity while leaving the body enabled.
    CVar_Add("Vehicles", "sv_car_sleep",             "0",     CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_drift_tap_time",    "0.2",   CVAR_SIDE_SV);  // Space held under this = a TAP (latches a drift)
    CVar_Add("Vehicles", "sv_car_drift_min_speed",   "250",   CVAR_SIDE_SV);  // min speed to TAP-start a drift
    CVar_Add("Vehicles", "sv_car_drift_exit",        "40",    CVAR_SIDE_SV);  // lateral speed the latched drift ends at (slide resolved)
    CVar_Add("Vehicles", "sv_car_box_yaw",           "0",     CVAR_SIDE_SV);  // live GLOBAL collision-box yaw (0/90/180/270) added to each car's box_yaw — dial until the box matches the model
    CVar_Add("Vehicles", "sv_car_steer_max",         "25",    CVAR_SIDE_SV);  // front-wheel steer angle (deg); lower = gentler turns, less speed scrub
    CVar_Add("Vehicles", "sv_car_steer_rate",        "120",   CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_yaw_assist",        "150",   CVAR_SIDE_SV);  // low-speed turn-in-place help (deg/s²); steer at a standstill to pivot; 0 = off
    CVar_Add("Vehicles", "sv_car_yaw_damp",          "8",     CVAR_SIDE_SV);  // yaw spin damping RATE (1/s) — stops a parked/shot car pirouetting; 0 = off (never fights the pivot/turns)
    CVar_Add("Vehicles", "sv_car_roll_damp",         "0",     CVAR_SIDE_SV);  // anti-ROLL damping RATE (1/s) about the car's forward axis — planted/low-body-roll TrackMania feel; 0 = off (pure 4-spring roll). Adds to, doesn't replace, the 4 corner springs.
    CVar_Add("Vehicles", "sv_car_seat_up",           "24",    CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_seat_fwd",          "0",     CVAR_SIDE_SV);  // driver seat fore/aft offset from the car origin (u; +forward)
    CVar_Add("Vehicles", "sv_car_seat_side",         "0",     CVAR_SIDE_SV);  // driver seat left/right offset (u; +right)
    CVar_Add("Vehicles", "sv_car_show_driver",       "1",     CVAR_SIDE_SV);  // 1 = render the seated driver's player model (facing forward) instead of hiding it
    CVar_Add("Vehicles", "sv_car_wheel_fwd",         "0",     CVAR_SIDE_SV);  // GLOBAL fore/aft shift of every car's visual wheel set (u); the per-car wheel_fwd key overrides
    CVar_Add("Vehicles", "sv_car_hit_force",         "4",     CVAR_SIDE_SV);  // bullet/melee push multiplier on a car
    CVar_Add("Vehicles", "sv_car_occupied_push_scale","0.4",  CVAR_SIDE_SV);  // push scale while a driver is seated
    CVar_Add("Vehicles", "sv_car_force_iterscale",   "0",     CVAR_SIDE_SV);  // 0 = normal ×iter; -1 disables; >0 scales all car forces
    CVar_Add("Vehicles", "sv_car_model_yaw",         "0",     CVAR_SIDE_SV);  // live GLOBAL drive-forward yaw offset added to every car's model_yaw (for dialing)
    // Car body collision shape (read at spawn in prop_car(); IQM/MD3 only — .mdl always stays box):
    //   1 = ACD MESH (default): SOLID_PHYSICS_TRIMESH for the player/bullet trace AND the sim body (no
    //       geomtype) — player + bullets + world all hit the exact ACD hull, so nothing flings (pmove and sim
    //       share one shape) and the low body clears kerbs.  The wheel-mount box (ab_*) and setsize are kept,
    //       so the visual wheels don't move.  Caveat: the sim COM sits at the mesh centroid, so a model far off
    //       origin-centre can rest slightly tilted — set 0 if a specific car dances.
    //   0 = oriented box (World_OBBTrace) — the old behaviour; players stand on the bounding box.
    CVar_Add("Vehicles", "sv_car_collision",         "1",     CVAR_SIDE_SV);
    CVar_Add("Vehicles", "sv_car_carry_dist",        "120",   CVAR_SIDE_SV);  // gravity-gun hold distance for a CAR (bigger than props so the big body sits clear in front)
    CVar_Add("Vehicles", "sv_car_carry_z",           "50",    CVAR_SIDE_SV);  // gravity-gun hold height for a CAR (lift it off the ground so it's flippable)
    // World-impact leniency + FX: instead of stopping dead on the BSP, the car SLIDES along the wall (keeps its
    // along-wall speed) and plays a metal impact/scrape sound + spark + smoke at the contact.
    CVar_Add("Vehicles", "sv_car_impact_fx",          "1",     CVAR_SIDE_SV);  // master toggle for the whole slide+FX feature
    CVar_Add("Vehicles", "sv_car_impact_min_speed",   "150",   CVAR_SIDE_SV);  // min pre-impact horizontal speed AND one-tick drop to register a wall hit (u/s)
    CVar_Add("Vehicles", "sv_car_impact_cooldown",    "0.15",  CVAR_SIDE_SV);  // min seconds between hard-hit sounds (anti machine-gun)
    CVar_Add("Vehicles", "sv_car_impact_slide_retain","0.85",  CVAR_SIDE_SV);  // fraction of along-wall speed kept on a hard hit (1 = clean glance, lower = more scrub)
    CVar_Add("Vehicles", "sv_car_grind_min_speed",    "120",   CVAR_SIDE_SV);  // min horizontal speed to keep the continuous scrape (loop + spark/smoke stream) alive against a wall
    CVar_Add("Vehicles", "sv_car_grind_interval",     "0.08",  CVAR_SIDE_SV);  // seconds between grind spark/smoke puffs while scraping
    CVar_Add("Vehicles", "cl_car_cam_dist",          "160",   CVAR_SIDE_CL);  // third-person chase distance
    CVar_Add("Vehicles", "cl_car_cam_height",        "64",    CVAR_SIDE_CL);

    CVar_Add("Client", "cl_killcam",      "1",  CVAR_SIDE_CL);  // rewind-replay killcam on death
    CVar_Add("Client", "cl_killcam_lookback", "2.0", CVAR_SIDE_CL); // seconds rewound before the kill
    CVar_Add("Client", "cl_killcam_duration", "3.5", CVAR_SIDE_CL); // total killcam length (seconds)
    CVar_Add("Client", "cl_killcam_delay",    "1.5", CVAR_SIDE_CL); // third-person death cam seconds before the killcam
    CVar_Add("Client", "cl_killcam_slowmo",   "0.4", CVAR_SIDE_CL); // slow-mo aftermath PAST the kill (0 = off, lower = slower)
    CVar_Add("Client", "cl_killcam_aftermath","1.2", CVAR_SIDE_CL); // seconds of post-kill death anim to replay in slow-mo
    CVar_Add("Client", "cl_killcam_tickrate", "64",  CVAR_SIDE_CL); // killcam record/replay sample rate (Hz, 10..60)
    CVar_Add("Client", "cl_killcam_fade",     "1",   CVAR_SIDE_CL); // killcam cinematic fade in/out
    CVar_Add("Client", "cl_killcam_scanlines","1",   CVAR_SIDE_CL); // killcam CRT scanline overlay
    CVar_Add("Client", "cl_killcam_debug",    "0",   CVAR_SIDE_CL); // killcam on-screen readout: which camera source (green SERVER TRACK = server killcam filling an out-of-PVS gap) + server frame count
    CVar_Add("Client", "cl_killcam_hideragdolls", "0", CVAR_SIDE_CL); // driven by CSQC each frame (1 while a killcam replay is active) — the engine skips rendering server ragdolls so the present-time flop doesn't show over the rewound scene

    // ---------- Engine ----------
    // FTE pre-registers these — registercvar() here is a harmless
    // re-register so menus can read defaults via the manifest and so
    // CVar_FindIndex resolves them.  Persisted to server.cfg.
    CVar_AddUI("Engine", "hostname",       "FTE Server", CVAR_SIDE_SV,
        CVAR_UI_STRING, CVAR_TAB_RCON | CVAR_TAB_CREATE_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Engine", "maxclients",     "255",         CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_RCON | CVAR_TAB_CREATE_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 4, 255);
    CVar_AddUI("Engine", "password",       "",           CVAR_SIDE_SV,
        CVAR_UI_STRING, CVAR_TAB_RCON | CVAR_TAB_CREATE_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 0, 0);
    // rcon_password: only the LOCAL/gold "admin's own password" row
    // is surfaced — that one is added explicitly in Server_PanelInit
    // (cl_serverpanel.qc) ahead of the manifest walk.  The duplicate
    // server-scoped row that used to live here was redundant: the
    // local-scope row already proxies through `rcon name value` to
    // change the actual server cvar when the user is connected to
    // a remote server, so a separate "change server rcon" field
    // wasn't doing anything different.
    //
    // The cvar itself is an FTE engine built-in, so dropping the
    // manifest entry only removes its UI appearance — the value
    // still exists and is reachable via cvar()/cvar_set/`rcon`.
    CVar_AddUI("Engine", "sv_port",        "27500",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_CREATE_SERVER, "Port",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 1, 65535);
    CVar_AddUI("Engine", "fraglimit",      "30",         CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_RCON | CVAR_TAB_CREATE_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 0, 999);
    CVar_AddUI("Engine", "sv_maxvelocity", "3500",       CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_CREATE_SERVER, "Max Velocity",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 100, 10000);
    CVar_AddUI("Engine", "sv_pure",        "0",          CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_SERVER, "SV Pure",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // ---------- Client ----------
    CVar_Add("Client", "cl_autohop",              "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_hitmarker",            "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_speedometer",          "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_predict_hits",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_envhud_debug",         "0",     CVAR_SIDE_CL);
    // When 0, the local CSQC bullet trace passes through dropped-
    // weapon AABBs (which sit around the visible mesh and are
    // larger than the gun silhouette).  When 1, the AABB blocks
    // bullets the same as a real surface — produces "sparks
    // floating beside the gun" because the bbox extends past the
    // visible model.  Default 0 for the cleanest look.
    CVar_Add("Client", "cl_dropped_weapon_blocks_bullets", "0", CVAR_SIDE_CL);

    // ---------- Client / View Feel ----------
    // Four togglable feel features.  Each has a master 0/1 toggle plus
    // tuning scalars so the same build can play either CS-rigid (all 0)
    // or CoD/Q3-style alive (1+).  See client/cl_viewfx.qc.
    //
    // bob: cadence-based oscillation of camera + viewmodel while walking.
    // weight: spring-damped camera dip on heavy landings.
    // sway: viewmodel angle lag when the camera turns.
    //
    // All four read but never write predicted_player or input_angles, so
    // bullets still fire from the player's real aim direction.
    CVar_Add("Client", "cl_camerabob",                 "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_amp_z",           "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_amp_x",           "2",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_cycle",           "240",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_speed_ref",       "250",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_fade_time",       "0.18",  CVAR_SIDE_CL);

    CVar_Add("Client", "cl_viewmodelbob",              "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_pos_scale",    "0.2",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_ang_scale",    "0.15",  CVAR_SIDE_CL);
    // Seconds after a real ground tick during which the bob/sprint
    // envelopes still treat the player as grounded.  Smooths the gun
    // pose over single-frame FL_ONGROUND flicker on clip-brush slopes.
    CVar_Add("Client", "cl_viewfx_ground_grace",       "0.1",   CVAR_SIDE_CL);
    // Grappling-hook rope visual tuning.  Half-width of the screen-
    // facing quad (~3 u total thickness) and the length (in u) per
    // texture repeat along the rope.  Tile length is the rope's "look"
    // dial — lower = denser strands per unit, higher = stretched.
    CVar_Add("Client", "cl_grappling_rope_width",      "1.5",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_grappling_rope_tile",       "16",    CVAR_SIDE_CL);
    // Waist-anchor offset — nudges the player-side rope end off the BBOX
    // centre toward the (right) hand so it reads as held, not navel-mounted.
    // Applied in facing-yaw space (view yaw for the local player, model yaw
    // for remotes): right = lateral, fwd = toward facing, up = vertical.
    CVar_Add("Client", "cl_grappling_rope_hand_right", "6",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_grappling_rope_hand_fwd",   "2",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_grappling_rope_hand_up",    "0",     CVAR_SIDE_CL);

    CVar_Add("Client", "cl_viewmodelweight",           "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_threshold", "80",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_scale",     "0.02",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_max",       "8",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_stiffness", "65",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_damp",      "11",    CVAR_SIDE_CL);
    // Independent per-target scales so the camera and the gun can dip
    // by different amounts (e.g. cam_scale 1.0 + gun_scale 0.5 keeps
    // the gun mostly attached to the screen while the camera drops).
    CVar_Add("Client", "cl_viewmodelweight_cam_scale", "2.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_gun_scale", "1.0",   CVAR_SIDE_CL);

    CVar_Add("Client", "cl_viewmodelsway",             "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_yaw_scale",   "-0.08", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_pitch_scale", "-0.13", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_pos_scale",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_recover",     "9",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_max_yaw",     "10",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_max_pitch",   "10",    CVAR_SIDE_CL);
    // Pivot mode: when the current viewmodel has weapon_muzzle_bone
    // set, rotate the gun around the muzzle (CoD-style — butt swings,
    // muzzle stays put) instead of applying the default translation
    // parallax.  Models without a muzzle bone always fall back to the
    // translation path regardless of this cvar.
    CVar_Add("Client", "cl_viewmodelsway_pivot",       "1",     CVAR_SIDE_CL);

    // Speed-driven gun lowering — fades with the same envelope as the
    // walk/run bob so the gun drops as the player accelerates and
    // recovers when they stop.
    CVar_Add("Client", "cl_viewmodellowering",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_amount",  "1",     CVAR_SIDE_CL);
    // Sprint pose — when sv_shiftspeed > 1 and the player holds
    // +button4 while running, rotates and pulls the gun across the
    // chest (CoD-style).  Sub-cvars below tune the pose; the *_fade
    // controls how fast it ramps on/off.
    CVar_Add("Client", "cl_viewmodellowering_sprint",        "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_pitch",  "7",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_yaw",    "35",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_roll",   "7",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_forward","1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_down",   "2",    CVAR_SIDE_CL);
    // Lateral shift while in the sprint pose.  +ve = right in viewmodel
    // space; the apply code negates this for XFLIP'd weapons so "right"
    // stays right on screen regardless of the per-weapon flip flag.
    CVar_Add("Client", "cl_viewmodellowering_sprint_right",  "-6",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_fade",   "0.35", CVAR_SIDE_CL);

    // ADS (+attack2 hold to aim).  Mirrors the sprint-pose envelope
    // and offsets but with its own pose and a tighter ramp.  Sprint
    // wins if both are active.  All offsets are camera-relative; the
    // _right value is sign-flipped for XFLIP'd weapons (same convention
    // as the sprint pose).  Pose defaults pull the gun back-and-down
    // toward the camera and tilt slightly up so iron sights centre.
    // Subtracted from the base fov cvar while ADS engaged (envelope
    // scaled), added to base fov while sprinting.  Both stack
    // independently and clamp to [10, 170].
    CVar_Add("Client", "cl_ads_fov",                 "15",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_sprinting_fov",           "8",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_fade",      "0.5",  CVAR_SIDE_CL);
    // Shared ADS pose — the fallback pose for any weapon without its own
    // per-weapon cl_ads_<weapon>_* set (see cl_viewfx.qc ads_pfx select).
    CVar_Add("Client", "cl_ads_pitch",     "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_yaw",       "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_roll",      "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_forward",   "-5",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_right",     "6.69", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_down",      "2",    CVAR_SIDE_CL);

    // Per-weapon ADS pose overrides — sight alignment for each viewmodel.  The
    // weapon's Equip sets weapon_ads_prefix to the matching prefix; cl_viewfx.qc
    // reads it, falling back to the shared cl_ads_* set above.
    //
    //                                  pitch    yaw      roll     forward  right    down
    ADS_RegisterPose("cl_ads_mp5",       "-1.5",  "0",     "0",     "-4.5",  "2.44",  "0.2");
    ADS_RegisterPose("cl_ads_vector",    "0",     "0",     "0",     "-5",    "8.6",   "3.75");
    ADS_RegisterPose("cl_ads_type89",    "2.5",   "0",     "0",     "-5",    "8.55",  "2.75");
    ADS_RegisterPose("cl_ads_ump45",     "0",     "0",     "0",     "-5",    "7.74",  "2.05");
    ADS_RegisterPose("cl_ads_m249",      "0.5",   "0",     "0",     "-5",    "7.155", "3.83");
    ADS_RegisterPose("cl_ads_ks23",      "0",     "0",     "0",     "-5",    "6.13",  "1.8");
    ADS_RegisterPose("cl_ads_m4",        "1.35",  "0",     "0",     "-5",    "6.72",  "3.5");
    ADS_RegisterPose("cl_ads_galil",     "0",     "1.85",  "0",     "-5",    "5.61",  "1.7");
    ADS_RegisterPose("cl_ads_glock",     "0",     "0",     "0",     "-5",    "5",     "1.9");
    ADS_RegisterPose("cl_ads_elite",     "0",     "0",     "-15",   "-9",    "8.9",   "-0.85");
    ADS_RegisterPose("cl_ads_p228",      "0",     "0",     "0",     "-5",    "8.5",   "2.95");
    ADS_RegisterPose("cl_ads_msg90",     "0",     "0",     "-15",   "-5",    "6.1",   "-1.2");
    ADS_RegisterPose("cl_ads_sg552",     "0",     "0",     "0",     "-5",    "8.8",   "0.9");
    ADS_RegisterPose("cl_ads_sl8",       "0",     "0",     "-15",   "-6",    "4.75",  "-1");
    ADS_RegisterPose("cl_ads_mk23",      "1",     "0",     "0",     "-5",    "4.3",   "1.4");
    // Remaining ADS weapons — every gun gets its own pose set.
    ADS_RegisterPose("cl_ads_mac10",     "0",     "0",     "0",     "-5",    "5.7",   "2.2");
    ADS_RegisterPose("cl_ads_famas",     "0",     "0",     "0",     "-5",    "8.85",  "0.9");
    ADS_RegisterPoseCvars("cl_ads_m9");                 // untuned — baseline pose
    ADS_RegisterPose("cl_ads_anaconda",  "2",     "0",     "0",     "-5",    "6.8",   "1.78");
    ADS_RegisterPoseCvars("cl_ads_ddeagle");            // untuned
    ADS_RegisterPose("cl_ads_scar",      "-1",    "0",     "0",     "-5",    "7.05",  "0.7");
    ADS_RegisterPose("cl_ads_mauser",    "-1.5",  "0",     "0",     "-5",    "4.9",   "0.65");
    ADS_RegisterPose("cl_ads_spas12",    "0",     "0",     "0",     "-5",    "5.8",   "1");
    ADS_RegisterPose("cl_ads_winchester","0",     "0",     "0",     "-5",    "6.9",   "1.9");
    ADS_RegisterPose("cl_ads_barrett",   "0",     "0",     "-15",   "-8",    "7.2",   "1");
    ADS_RegisterPose("cl_ads_m700",      "0",     "0",     "-15",   "-7.5",  "8.2",   "1");
    ADS_RegisterPoseCvars("cl_ads_awm");                // untuned
    ADS_RegisterPose("cl_ads_psg1",      "0",     "0",     "-15",   "-9",    "8.8",   "1.25");
    ADS_RegisterPose("cl_ads_dragunov",  "0",     "0",     "-15",   "-2.5",  "5.5",   "0");
    ADS_RegisterPose("cl_ads_aug",       "0",     "0",     "-15",   "-8",    "7",     "-1.4");
    ADS_RegisterPoseCvars("cl_ads_ak47");               // untuned
    ADS_RegisterPoseCvars("cl_ads_hdak47");             // untuned
    ADS_RegisterPoseCvars("cl_ads_awp");                // untuned
    ADS_RegisterPose("cl_ads_deagle",    "0",     "0",     "0",     "-2",    "4.15",  "1.35");
    ADS_RegisterPoseCvars("cl_ads_m4a1");               // untuned
    ADS_RegisterPoseCvars("cl_ads_scout");              // untuned
    ADS_RegisterPose("cl_ads_usp",       "0",     "0",     "0",     "-5",    "9",     "4.9");

    // Weapon-lower pose — drives the off-screen viewmodel offset when
    // the player is grappling or (with sv_codladders 1) climbing a
    // ladder.  Defaults pull the gun down + tilt forward enough that
    // it disappears below the screen at FOV 90 on standard player-
    // height viewmodel rigs.  Sign convention matches the ADS block:
    // _right is sign-flipped for XFLIP'd weapons.  _fade is the time
    // to reach ~98% of the target — slightly slower than sprint so
    // the drop reads as "heavy" rather than snappy.
    CVar_Add("Client", "cl_viewmodel_lower_fade",    "0.45", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_pitch",   "30",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_yaw",     "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_roll",    "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_forward", "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_right",   "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodel_lower_down",    "-40",  CVAR_SIDE_CL);

    // CoD-style scope (cl_codscope.qc) phase-duration knobs.  These
    // tune the timing of the four animated sub-stages between OFF and
    // SCOPED:
    //   fade_in       — quick fade to black after the gun reaches ADS
    //   unfade        — slower unfade + overlay reveal (ease-out)
    //   fade_out      — quick fade to black on release + overlay drop
    //   unfade_out    — final unfade back to clear vision as gun lowers
    // All in seconds.  Adjust to taste; the defaults aim for snappy
    // engage / slightly slower disengage.
    CVar_Add("Client", "cl_codscope_fade_in_time",    "0.08", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_unfade_time",     "0.35", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_fade_out_time",   "0.08", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_unfade_out_time", "0.15", CVAR_SIDE_CL);
    // ADS-envelope crossing past this threshold during RAISING
    // commits the state machine to FADING_IN (no return to RAISING
    // / FALLING — closes the +attack2 spam exploit).  Lower = scope
    // commits earlier into the ADS rise.
    CVar_Add("Client", "cl_codscope_ads_threshold",   "0.75", CVAR_SIDE_CL);
    // Fraction of g_height the scope overlay slides through during
    // the rise / fall animation.  Lower = subtler movement, higher =
    // more theatrical.  Default 0.30 puts the start position with
    // the hole top still on-screen so the user gets a continuous
    // visual instead of a slam-up from off-screen.
    CVar_Add("Client", "cl_codscope_overlay_travel",  "0.10", CVAR_SIDE_CL);
    // Breathing oscillation amplitude (degrees) and rate (Hz) applied
    // to the camera angles while sv_snipersway is on AND the player
    // is scoped in either CS or CoD mode.  Slow rate ≈ 1 breath per
    // 5.5 s; amplitude is the peak pitch contribution.
    CVar_Add("Client", "cl_codscope_sway_breath_amp",  "1.5",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_breath_rate", "0.18", CVAR_SIDE_CL);  // Hz (one breath ≈ 5.5s)
    // Multiplier applied to ALL sway (classic + breathing) when the
    // player presses +button4 to hold breath while scoped.  Old code
    // used a hard 0.15 snap; the new envelope eases to this target
    // via cl_codscope_sway_breath_fade.
    CVar_Add("Client", "cl_codscope_sway_holdbreath_mult", "0.02", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_breath_fade",     "1.00", CVAR_SIDE_CL);  // ease time for hold-breath
    // Overlay vertical step kick amplitude (pixels) while walking /
    // running.  Scales with horizontal velocity and breath envelope
    // so a held-breath stationary player gets near-zero step bob.
    CVar_Add("Client", "cl_codscope_sway_step_amp",   "8",   CVAR_SIDE_CL);
    // Overlay vertical landing-impact kick scale.  Hit detected on
    // ground-touch edge with downward velocity; spring recovers via
    // semi-implicit Euler (constants in cl_codscope.qc).
    CVar_Add("Client", "cl_codscope_sway_land_amp",   "0.6", CVAR_SIDE_CL);

    // Bob amplitude multipliers that lerp in/out with the sprint
    // envelope — 1.0 = no change, >1 = bigger steps while sprinting.
    CVar_Add("Client", "cl_camerabob_sprint_mult",     "1.4",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_sprint_mult",  "1.6",   CVAR_SIDE_CL);

    // Max Hz at which CSQC re-issues per-frame-mutable dynamic lights
    // (muzzle-flash + bullet-impact + explosion).  At 1000 fps render
    // each of those calls dynamiclight_add() on every frame; the
    // engine's lightmap-hack path runs MarkLights+lightmap-rebuild for
    // every live dlight every render frame (sv_phys.c / r_surf.c:2320),
    // so the wall-clock cost scales linearly with render rate even
    // though nothing visually changes.  Capping the QC re-issue rate
    // lets the dlight be absent on some render frames — the engine
    // sees nothing to mark, and the per-frame lightmap-rebuild work
    // for that dlight is skipped on those frames.
    //
    // Tradeoff: on frames the dlight is skipped it isn't visible,
    // which can produce a strobe pattern when the cap is much lower
    // than the monitor refresh.  500 Hz keeps the dlight live ≥50% of
    // frames on a 240 Hz display and is imperceptible there; drop to
    // 250 or 120 for bigger savings at the cost of visible flicker on
    // brief flashes (muzzle, impact).  0 = uncapped (every frame).
    //
    // Does NOT throttle: flashlight (must track camera every frame),
    // C4 idle pulse (already 0.15s rate), HL beam dlights (one-shot
    // per beam-trail parse).
    CVar_Add("Client", "cl_dlight_update_hz",     "0",   CVAR_SIDE_CL);

    // Inter-sequence anim blend (legs / torso) on remote player
    // visual proxies.  Higher = longer, smoother transitions when
    // a player goes from running to idle, switches weapons, etc.
    // 0 disables the lerp (snap behaviour).  See
    // CSQC_PlayerVisual_Predraw.
    CVar_Add("Client", "cl_player_anim_lerp_time", "0.067", CVAR_SIDE_CL);
    // IQM spine deformer — when 1, applies the HL-style body twist
    // (legs face movement direction, torso stays facing aim) and
    // pitch-aim (torso bends up/down with view pitch) to spine bones
    // via skel_set_bone.  HL bone-controllers and aim subblend are
    // dead on mod_alias models; this is the IQM replacement.  Set
    // to 0 to disable for A/B testing.
    CVar_Add("Client", "cl_player_spine_deform",   "1",     CVAR_SIDE_BOTH);
    // IQM spine deformer tuning.  Twist is applied to the lower-body
    // yaw delta after the whole player model turns toward movement;
    // negative keeps the torso facing aim on the current CS IQM axes.
    // Pitch scales view pitch before distributing it across the spine.
    //
    // SIDES: _deform / _twist_scale / _pitch_scale / _pitch_max are BOTH because
    // shared/sh_player_anims.qc reads them and is in sv_progs.src.  Every other
    // spine cvar below is read ONLY by client/cl_player.qc, so it is CL — marking
    // those BOTH made the server register a default the client never used, which
    // is how the _upper_scale pair ended up at 0.5/0.6 on the server and 1 on the
    // client.  `python cvar_audit.py` re-checks this.
    CVar_Add("Client", "cl_player_spine_twist_scale", "0.55",  CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_twist_max",   "50",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_player_spine_twist_waist_scale", "1", CVAR_SIDE_CL);
    // Scales the upper spine bones (spine2 + spine3) yaw fraction.
    // Lower values keep the waist leaning naturally while reducing how far
    // the head/shoulders rotate when strafing.  1.0 = original feel.
    CVar_Add("Client", "cl_player_spine_twist_upper_scale", "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_player_spine_pitch_scale", "1",     CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_pitch_max",   "55",    CVAR_SIDE_BOTH);
    // Scales spine3 + neck pitch fractions so the head bobs less when
    // looking up/down.  1.0 = original feel.
    CVar_Add("Client", "cl_player_spine_pitch_upper_scale", "1",   CVAR_SIDE_CL);
    // Orthonormalize the spine's parents (pelvis + Bip01 root) before the strafe
    // yaw.  The yaw rotates each spine bone's local basis and the engine rebuilds
    // model space through the parent's actual matrix; IQM frame-blend leaves that
    // parent skewed (large on a deep CROUCH forward-lean), which shears the yaw
    // into PITCH (the strafe-direction up/down tilt).  Cleaning the parents makes
    // the yaw a true horizontal turn.  1 = on (default).  Set 0 if it ever
    // disturbs the legs (they hang off the pelvis) — reverts to the prior
    // clean-standing / slight-crouch-leak behaviour.
    CVar_Add("Client", "cl_player_spine_orthoparents", "1",  CVAR_SIDE_BOTH);
    // perf: skeleton rebuild rate (Hz) for STILL players (velocity <= 8).  A
    // standing crowd's breathing pose barely changes, so re-solving the ~50-bone
    // skeleton every frame is wasted; cap it.  Moving players always rebuild every
    // frame.  The trust-1 trace uses the SAME cached skeleton, so hit detection
    // stays consistent at this rate.  0 = always rebuild (off).
    CVar_Add("Client", "cl_player_skel_idle_rate", "25", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_player_backpedal_enter_angle", "150", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_backpedal_exit_angle",  "100", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_debug",       "0",     CVAR_SIDE_BOTH);
    // First-person body (CS2-style "look down and see your legs").  The local player's
    // visual proxy is ALREADY drawn every frame for the shadow depth pass, tagged
    // RF_EXTERNALMODEL so the main view skips it; this just stops hiding it.  The upper
    // chest and head are dithered away by a height band so they can never clip the camera.
    //
    // The band is in the MODEL's own bind-pose space, which is NOT the same origin as the
    // player HULL: the hull is origin-at-body-centre (feet -36 .. crown +36, sh_pmove.qc)
    // but these player models are authored FEET-AT-ZERO, so the usable band sits up around
    // 30-40, not around 2-14.  Values below are the measured-good ones; tune by eye.
    // These are cvardf shader constants — changing them needs a vid_reload to re-take.
    CVar_Add("Client", "cl_fpbody",             "1",  CVAR_SIDE_CL);   // 0 = classic invisible-body first person
    CVar_Add("Client", "cl_fpbody_fade_start",  "30", CVAR_SIDE_CL);   // model Z where the dither fade begins (solid below)
    CVar_Add("Client", "cl_fpbody_fade_end",    "40", CVAR_SIDE_CL);   // model Z where it is fully gone
    // "Crane your neck": nobody can look straight down their own spine, so as the view
    // pitches down the body slides to fake the head pivoting forward over the chest.
    // Live cvars (not shader constants) — tune these in-game with no reload.
    CVar_Add("Client", "cl_fpbody_pitch_start", "20", CVAR_SIDE_CL);   // view pitch (deg down) where the lean starts; above this, nothing changes
    CVar_Add("Client", "cl_fpbody_pitch_fwd",   "-15", CVAR_SIDE_CL);  // qu the body slides at full lookdown. NEGATIVE = BACKWARD, which is the
                                                                       // direction that actually reads right (measured): the eye craning forward
                                                                       // over the chest is equivalent to the torso sliding back under it.
    CVar_Add("Client", "cl_fpbody_pitch_up",    "0",  CVAR_SIDE_CL);   // qu the body slides UP at full lookdown
    CVar_Add("Client", "cl_skel_debug",               "0",     CVAR_SIDE_CL);  // draw each player's bone skeleton live (bone->parent beams)
    // Length of the visual flinch reaction (CSANIM_GUT_FLINCH /
    // CSANIM_HEAD_FLINCH overrides the torso anim) after a player
    // takes damage.  CS flinch sequences are short (2 frames @ 30 fps
    // ≈ 0.066 s); the duration here should be close to that so the
    // sequence plays once instead of holding on the last frame.
    // Set to 0 to disable flinching entirely.
    CVar_Add("Client", "cl_player_flinch_time",    "0.067", CVAR_SIDE_CL);
    // Predict func_breakable destruction the moment local damage
    // exceeds remaining brush_health, so the shooter sees the brush
    // disappear instantly. CSQC_BreakPredict_Expire rolls back if the
    // server doesn't confirm. Off = wait for the server's destroy
    // event (adds ~1 RTT of latency, no rollback flicker).
    CVar_Add("Client", "cl_predict_breaks",       "1",     CVAR_SIDE_CL);
    // CSQC weapon traces temporarily skip playerclip so predicted
    // impacts/decals land on the visible surface instead of invisible
    // stair ramps and other clip-only brushes. Movement still uses clip.
    CVar_Add("Client", "cl_weapontrace_ignore_playerclip", "1", CVAR_SIDE_CL);
    // Predict the visual death of a remote player when our CSQC trace
    // computes a lethal hit (final damage ≥ vis_health). Drops the
    // body + plays the matching death animation immediately on the
    // shooter's screen; server's authoritative confirmation arrives
    // ~ping ms later and the prediction either matches (no snap) or
    // reverts (next snapshot's vis_is_dead=0 + alive anim restores).
    CVar_Add("Client", "cl_predict_death",        "1",     CVAR_SIDE_CL);
    // Bullet-impact particles on/off.  0 = none, >=1 = full smoke + spark
    // particles.  (The old "1 = cheap _fast" tier was collapsed to a single
    // quality; the per-impact dynamic light is gated separately by
    // cl_impact_light.)
    CVar_Add("Client", "cl_impact_quality",       "1",     CVAR_SIDE_CL);
    // Single offset knob for impact smoke/spark particles.  Floor
    // 2 u keeps the puff from z-fighting the bullet-hole decal;
    // higher values lift the smoke further off the wall.  Dlight
    // lives at the raw impact position independent of this.
    CVar_Add("Client", "cl_impact_particle_offset", "0",    CVAR_SIDE_CL);
    // Counterpart for muzzle particles.  Currently a no-op because
    // this mod's muzzle flash is a sprite (already `sort additive`
    // in scripts/effects.shader, so it never darkens its own
    // dlight) and no QC pointparticles call spawns at the gun
    // barrel.  Registered so the toggle is in place if a future
    // weapon adds muzzle smoke / sparks via pointparticles — author
    // _additive siblings of those effects and they'll be picked up
    // here.
    CVar_Add("Client", "cl_muzzleflash_particles_additive", "0", CVAR_SIDE_CL);
    // Dedicated bullet-impact dlight toggle (split off from
    // cl_impact_quality 3 so users can keep full particle FX while
    // killing the lightmap-rebuild storm under sustained fire).
    CVar_Add("Client", "cl_impact_light",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_light_scale",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_light_offset",  "8",     CVAR_SIDE_CL); // units the impact dlight stands off the wall along its normal (0 = flush; pull back so the wall face lights up)
    // Realtime shadows on transient combat lights (bullet impacts, explosions, C4
    // flashes).  0 = NOSHADOW (default): these sub-second flashes don't need cast
    // shadows, and a shadow-casting dlight makes the engine re-skin every entity in
    // its volume — the per-frame render-pass multiplier under sustained fire.  1 =
    // restore shadows (fine on a quiet server).  Muzzle flash / flashlight are
    // always NOSHADOW regardless.
    CVar_Add("Client", "cl_combat_light_shadows", "0",     CVAR_SIDE_CL);
    // Shell-ejection visual gate.  Server still sends the multicast and
    // local prediction still spawns nothing — both paths short-circuit
    // inside the CSQC SpawnCasing helpers, no gameplay effect.
    CVar_Add("Client", "cl_ejectcasing",          "1",     CVAR_SIDE_CL);
    // Mag-drop visual gate (paired with cl_ejectcasing).  Same
    // short-circuit pattern — gate inside SpawnMag / SpawnRemoteMag.
    CVar_Add("Client", "cl_ejectmag",             "1",     CVAR_SIDE_CL);
    // Viewmodel lighting kill-switch.  Sets EF_FULLBRIGHT on the
    // viewmodel each frame, skipping LightPointValues + dlight loop
    // (gl_alias.c:1395 early-out).  Big perf win when firing near
    // walls — muzzleflash dlight self-lighting on the viewmodel is the
    // single most expensive per-frame mesh relight cluster.
    CVar_Add("Client", "cl_viewmodel_nolight",    "0",     CVAR_SIDE_CL);
    // Toggle the dynamic light spawned at every grenade / RPG / C4 /
    // env_explosion blast.  Lights aren't gated by cl_impact_quality
    // (that controls per-bullet impacts only), so this gives a
    // separate kill-switch for users on weak GPUs or those who find
    // the warm-orange flash distracting in tight rooms.  Off only
    // suppresses NEW lights — already-active fades play out naturally.
    CVar_Add("Client", "cl_explosion_light",      "0",     CVAR_SIDE_CL);
    // Forward extrapolation budget (seconds) for rotating brushwork —
    // func_door_rotating, func_pendulum, etc.  The CSQC predraw projects
    // visible angles as `snap_angles + avelocity * elapsed`, with elapsed
    // capped at this cvar.  The mover entities only ship a fresh snapshot
    // at the start of each swing phase, so a value of 0 freezes the
    // visible brush at the start pose until the apex snapshot arrives —
    // looks like a jump-cut.  A value high enough to cover one full swing
    // (~1 s) lets the client smoothly follow the rotation; the predraw's
    // pos1/pos2 clamp prevents visible overshoot at the swing extremes.
    // The previous default of 0 was set to lockstep door visuals with
    // the player-carry pass at the old 40 Hz tickrate; at 64 Hz the
    // residual carry-vs-render lag is imperceptible even at 1 s lookahead.
    CVar_Add("Client", "cl_brushsync_lookahead",  "1",     CVAR_SIDE_CL);
    // Hide func_ brushes that are fully textured with the HL
    // "AAATRIGGER" mapping placeholder.  Off by default so the
    // engine matches HL's "trigger texture is invisible in-game"
    // convention; flip on to see clip / trigger / cosmetic-helper
    // brushes during mapping or debugging.  Server still treats
    // these brushes as solid for traces and collisions either way
    // — only the visual changes.
    CVar_Add("Client", "cl_aaatrigger",           "0",     CVAR_SIDE_CL);
    // Per-shot bullet tracers — see client/cl_tracers.qc.  Visual-only
    // (no gameplay effect), so all tunables are CSQC-side.  Tracer
    // start/end come from CSQC_PredictedImpact / CSQC_BulletImpactRemote
    // (server tags the IMPACT multicast with a shooter entnum).
    CVar_Add("Client", "cl_tracer",               "1",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_width",         "0.5",       CVAR_SIDE_CL);
    // Empty string disables the color overlay entirely (vertex tint
    // = white, shader texture renders untinted).  Any non-empty value
    // parses as "R G B" floats 0..1.
    CVar_Add("Client", "cl_tracer_color",         "1 0.5 0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_opacity",       "0.2",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_time",          "0.05",      CVAR_SIDE_CL);
    // Override texture/shader path for the tracer quad.  Empty falls
    // back to gfx/tracer; set e.g. "gfx/rain/streak1" to render a
    // sprite-streak in place of the default glow ribbon.
    CVar_Add("Client", "cl_tracer_sprite",        "",          CVAR_SIDE_CL);
    // "Travel" mode — instead of a static ribbon, the tracer is a
    // short stretched quad that flies from muzzle to impact at
    // _speed qu/s, fading near the end.  Slots tag themselves at
    // spawn so static and travel tracers can coexist mid-flight.
    CVar_Add("Client", "cl_tracer_travel",        "1",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_travel_speed",  "4000",      CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_impact_delay",  "1",         CVAR_SIDE_CL); // 1 = delay the bullet-impact FX until the tracer streak reaches the wall; 0 = instant impact
    CVar_Add("Client", "cl_tracer_alpha",         "0.9",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_travel_size",   "1.5",       CVAR_SIDE_CL);
    // Stretched-quad length (qu) — both modes use this:
    //   cl_tracer_travel 1  → head grows from src to this length, then
    //                         the fixed-length quad slides toward dst.
    //   cl_tracer_travel_full 1 → fixed-length quad appears at src
    //                             and slides forward as a moving bullet.
    CVar_Add("Client", "cl_tracer_travel_length", "256",       CVAR_SIDE_CL);
    // Full-length instant mode: emit a fixed-length tracer at the
    // muzzle and slide it forward to the impact point.  Overrides
    // cl_tracer_travel when set.
    CVar_Add("Client", "cl_tracer_travel_full",   "1",         CVAR_SIDE_CL);
    // 0 = off, nonzero = texture-backed decals.
    CVar_Add("Client", "cl_bulletholes",          "1",     CVAR_SIDE_CL);
    // Cap decal spawns per shot.  Penetration can spawn entry+exit
    // decals across multiple targets — 0 = unlimited (old behaviour),
    // 1 = entry decal only (no penetration exit holes), N = max N.
    CVar_Add("Client", "cl_bulletholes_per_shot", "1",     CVAR_SIDE_CL);
    // PVS reachability test — skip decals whose hit surface ends up in
    // a leaf that's not in the PVS from the local camera.  Catches
    // penetration exit decals in sealed-off voids that the pointcontents
    // SOLID check misses.  Set to 0 on maps with bad vis data if you
    // see decals disappearing legitimately.
    CVar_Add("Client", "cl_bulletholes_pvs_check","1",     CVAR_SIDE_CL);
    // Cap impact dlight spawns per shot.  cl_impact_quality 3 spawns
    // one dlight per hit; with penetration that compounds quickly.
    // 0 = unlimited; default 2 keeps the visual punch on entry + one
    // penetration without quadratic light blow-up.
    CVar_Add("Client", "cl_impact_dlights_per_shot", "1",  CVAR_SIDE_CL);
    // Cap particle-effect spawns per shot (Impact_SpawnParticles — the
    // smoke / spark puff on every impact).  Penetration through walls
    // can stack 4+ exit smokes from a single shot; cap thins them.
    // 0 = unlimited (old behaviour); default 2 mirrors the dlight cap.
    CVar_Add("Client", "cl_impact_effects_per_shot", "3",  CVAR_SIDE_CL);
    // Bullet-impact DEBRIS — rock chunks / brown squares thrown off the first
    // impact (CSQC_SpawnImpactDebris, cl_bulletimpact.qc; effects in
    // particles/weapons.cfg).  Needs r_bouncysparks 1 (engine default) for the
    // chunks to bounce off the floor instead of falling through it.
    //   cl_impact_debris          master on/off
    //   cl_impact_debris_mode     0 = textured rock chunks, 1 = brown squares
    //                             (toggle with the `impactdebris` command)
    //   cl_impact_debris_count    chunks per impact
    //   cl_impact_debris_force    launch speed along the surface normal
    //   cl_impact_debris_per_shot bursts per shot (caps shotgun/penetration)
    CVar_Add("Client", "cl_impact_debris",          "0",   CVAR_SIDE_CL);  // default OFF (2026-07 declutter): impacts = smoke + physical chips only
    CVar_Add("Client", "cl_impact_debris_mode",     "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_count",    "4",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_force",    "110", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_per_shot", "1",   CVAR_SIDE_CL);
    // Bullet wall-bang EXIT dust smoke (CSQC_BulletExitSmoke, cl_bulletimpact.qc):
    //   cl_impact_exitsmoke        master toggle (puffs where a penetrating shot leaves a surface)
    //   cl_impact_exitsmoke_count  puffs per exit (each leaves faster + thicker)
    CVar_Add("Client", "cl_impact_exitsmoke",       "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_exitsmoke_count", "2",   CVAR_SIDE_CL);
    // Impact debris CHIPS (CSQC_SpawnImpactChips, cl_bulletimpact.qc): small material-
    // matched IQM chips (models/gibs/impact/) that bounce, settle, and fade out.
    // TWO spawn sites: EXIT (fast, thrown along the bullet's exit line where the exit
    // smoke plays) and ENTRY (every impact: slow spall back out of the wall along the
    // surface normal in a wide random cone).  Each has its own force/count; per-shot
    // caps are separate per side so a wallbang shows both bursts.
    //   cl_impact_chips            master toggle
    //   cl_impact_chips_mode       0 = CSQC entities (default; full control: scale/life
    //                              cvars, per-chip geomset pick, last-0.8s fade)
    //                              1 = engine model-particles (weapons.impactchips_* in
    //                              particles/impacts.cfg; sim in C, cheaper at high counts;
    //                              count/force cvars still apply, but life/scale are baked
    //                              in the cfg — tune there + `reloadweapons`; fade is
    //                              linear over the whole life)
    //   cl_impact_chips_count      chips per EXIT burst
    //   cl_impact_chips_force      EXIT launch speed along the bullet's exit direction
    //   cl_impact_chips_entry      entry-side spall toggle (chips on EVERY impact)
    //   cl_impact_chips_entry_count  chips per ENTRY burst
    //   cl_impact_chips_entry_force  ENTRY launch speed (slow; scatter scales with it)
    //   cl_impact_chips_per_shot   bursts per shot PER SIDE (caps shotgun/multi-pen)
    //   cl_impact_chips_walltex    entity mode (_mode 0) only: chips WEAR THE WALL —
    //                              the struck surface's texture is sampled at the hit
    //                              point and applied to the chip via .forceshader.
    //                              Falls back to the painted chip texture when the
    //                              wall has no loose textures/<name>.png or in _mode 1
    //                              (model-particles have no per-spawn material hook).
    //   cl_impact_chips_life       seconds a chip lies around before its fade-out
    //   cl_impact_chips_scale_min/max  random per-chip .scale (assets authored 5x
    //                              since the 2026-07 regen — same cvar values render
    //                              HALF the old on-screen size; tune here, not the bake)
    CVar_Add("Client", "cl_impact_chips",           "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_mode",      "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_count",     "2",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_force",     "80",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_entry",       "1",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_entry_count", "1",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_entry_force", "40", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_per_shot",  "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_walltex",   "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_life",      "10",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_scale_min", "0.16", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_chips_scale_max", "0.4",  CVAR_SIDE_CL);
    // Debris entities (impact chips + breakable chunks) cast r_shadows-2 shadows.
    // Cost per caster = ONE extra depth-only draw of a ~20-tri mesh into the fixed
    // shadow map (no extra passes/memory) — cheap; this is the off switch anyway.
    CVar_Add("Client", "cl_debris_shadows",         "1",    CVAR_SIDE_CL);
    // prop_car engine audio (cl_vehicle_sound.qc): CSQC-synthesized RPM ladder —
    // 4 crossfaded loop anchors + fake gear sawtooth, per-frame soundupdate().
    //   cl_car_sound_maxspeed  speed (u/s) treated as redline in top virtual gear
    //   cl_car_sound_gears     virtual gears (AUDIO sawtooth only, physics has none)
    CVar_Add("Client", "cl_car_sound",          "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_car_sound_volume",   "0.8",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_car_sound_maxspeed", "1100", CVAR_SIDE_CL);  // MUST track sv_car_max_speed (mismatch = wrong gear mapping, e.g. reverse sounding like idle)
    CVar_Add("Client", "cl_car_sound_gears",    "4",    CVAR_SIDE_CL);  // MUST track sv_car_gears (the shift cut + audio sawtooth derive the same gears from speed)
    CVar_Add("Client", "cl_car_sound_gearstep", "5",    CVAR_SIDE_CL);  // % pitch each gear steps UP so an up-shift sounds like a higher gear (0 = default 5; clamped 30% max)
    CVar_Add("Client", "cl_car_sound_coastvol", "0.5",  CVAR_SIDE_CL);  // engine volume at ZERO throttle (coasting/idle) as a fraction of the powered volume — the LOAD half of "loudness = revs x load". Fixes a no-throttle DOWNSHIFT blaring at ~full volume (the sawtooth jumps to the lower gear's redline, which is correct, but volume used to follow revs ALONE with no load term). 1 = old revs-only behaviour; lower = quieter gliding/idle. Local driver only (remote cars carry no throttle on the wire).
    CVar_Add("Client", "cl_car_sound_revfloor", "0.28", CVAR_SIDE_CL);  // how far the THROTTLE alone lifts the revs at ZERO speed (0..1). This is a FLOOR on the rev level, so it IS the note a standing start begins on: 0.8 (the old hardcoded value) landed straight on the rev_mid/rev_high loops = "sounds mid-speed before it moves"; 0.28 starts low and lets SPEED build it. Higher = revvier standing rev, but masks more of the launch build-up.
    CVar_Add("Client", "cl_car_sound_debug",    "0",    CVAR_SIDE_CL);  // 2 Hz console print of the driver's state (islocal match, env, ignition)
    // BIG breakable-destruction chunks (CSQC_SpawnChunkGibs, cl_breakable.qc):
    // large IQM pieces that REPLACE the legacy gibs for glass + wood/tile
    // breakables — wood planks/splinters (models/gibs/wood/wood_chunk1..9.iqm)
    // and big flat window panes (models/gibs/glass/glass_chunk1..9.iqm).
    // 1 (default) = chunks only; 0 = the legacy glassgibs/woodgib .mdl look.
    // Count: a mapper "cnt" key wins verbatim (wire count != the material's
    // server default 15/6 means mapper-set); else min(6 + count*2/3, 16).
    //   cl_breakable_chunks_mode  0 = CSQC entities (default: rollback-sweepable
    //                             on mispredicted breaks, QC-controlled scale/alpha)
    //                             1 = engine model-particles (weapons.breakchunks_*
    //                             in particles/impacts.cfg; sim in C; scale/alpha/
    //                             life baked in the cfg — tune + `reloadweapons`;
    //                             NOT swept on break rollback)
    CVar_Add("Client", "cl_breakable_chunks",       "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_breakable_chunks_mode",  "0",    CVAR_SIDE_CL);
    // Bullet-hole renderer path (read by cl_bulletholes.qc):
    //   1 = polygon-quad (default, fast — ~5-8x cheaper than adddecal,
    //       no decal corner-wrap on convex surfaces).
    //   0 = legacy FTE adddecal() — slow per-frame BSP clip+project, but
    //       wraps the decal across edges of convex world geometry.
    // Brushmodel-owned holes (func_door, func_breakable, etc.) ignore
    // this and always use the polygon path; adddecal can't reproject
    // onto a moving submodel.
    // r_bullethole_renderer REMOVED — unified into r_decal_renderer (ONE decal renderer for bulletholes/sprays/infodecals/blood).
    // r_bullethole_offset REMOVED — unified into r_decal_offset (one off-surface lift for all decals).
    // World/BSP bullet-hole decal size (full units across) for the random gfx/impacts/impactN
    // art. Read per hit at spawn; affects NEW holes (tune it + shoot fresh holes, no rebuild).
    CVar_Add("Client", "cl_bullethole_impact_size", "6",    CVAR_SIDE_CL);
    // Source-style edge clipping for renderer 1.  When 1 (default), the
    // decal quad is clipped at spawn time against the hit BSP triangle's
    // 3 edges so it conforms to the surface boundary instead of
    // overhanging.  One-shot CPU cost per decal — per-frame render is
    // unchanged (still one addtrisoup_simple per material).  Set 0 to
    // see the raw axis-aligned quads (the pre-clipping behaviour).
    CVar_Add("Client", "cl_bullethole_clip_geom", "1",     CVAR_SIDE_CL);
    // Dedupe radius scale for new bullet holes / paint-splats / snow-
    // splats. Multiplied by the new decal's half-size to compute the
    // distance under which existing decals get removed when a new one
    // spawns at almost the same spot. Read by CSQC_BulletHole_DedupeNearby.
    //   0   = off (decals stack)
    //   1   = default (~half-overlap removes the old)
    //   1.5 = ~75% overlap removes
    //   2   = aggressive (any overlap removes the old)
    CVar_Add("Client", "cl_bullethole_dedupe_scale", "0.5",  CVAR_SIDE_CL);
    // Maximum number of bullet holes / splats kept on the client at
    // once. When exceeded, the oldest hole is evicted before the new
    // one is appended. Lower this for big perf wins on cluttered
    // servers — each visible hole costs ~25 QC ops + 5 engine vertex
    // submits per frame. 512 is a reasonable middle ground; 2048 (the
    // pre-cvar hard limit) is the upper ceiling for competitive setups
    // that don't mind the cost.
    CVar_Add("Client", "cl_bulletholes_max",       "1024",  CVAR_SIDE_CL);
    // Distance LOD — bullet holes / splats farther than this from the
    // camera are skipped at draw time (squared-distance compare; no
    // sqrt). 0 disables the cull. Brushmodel-owned holes (on doors /
    // breakables) bypass this check because their stored origin is
    // stale (the parent moves) — they always draw if not behind the
    // camera. Recommended 1500–3000 depending on map scale.
    CVar_Add("Client", "cl_bullethole_distance",   "1500",  CVAR_SIDE_CL);
    // HUD recompute throttle — caps the rate at which the per-frame
    // HUD work (utility-dropdown ammo eval, manifest lookups, etc.)
    // is rebuilt. Drawing itself still runs every frame; only the
    // input-state recompute is throttled. Pickups / weapon switches
    // force an instant cache refresh via per-element fingerprints,
    // so this only affects the steady-state idle cost. 30 Hz is
    // imperceptible vs per-frame for any human-paced state change.
    CVar_Add("Client", "cl_hud_fps",              "30",    CVAR_SIDE_CL);
    // Net-graph recompute throttle — same idea for the debug net
    // panel. The displayed values are EMA-smoothed already, so 10 Hz
    // refresh of the formatted strings is visually identical to per-
    // frame. Per-frame cost drops from ~12 ms / 0.2 s to ~1/6 of that
    // with the default. Set to 0 to disable throttling (per-frame).
    CVar_Add("Client", "cl_netgraph_fps",         "10",    CVAR_SIDE_CL);
    // Flashlight (impulse 50, default key 'l') — client-only Source-style
    // dlight from the camera. Read by cl_flashlight.qc when toggled on;
    // takes effect on the next frame.
    //   _style      0 = SPOT cone (FOV-based circle, no cookie texture).
    //               Cheap — uses a single 2D shadowmap. Cone width is
    //               driven by cl_flashlight_fov.
    //               1 = CUBEMAP cookie (texture-shaped beam from
    //               cubemap/flashlight_*.tga). More expensive — uses
    //               an omnidirectional light + 6-face cubemap. Cone
    //               shape is whatever's bright on the +X face.
    //               These two modes are mutually exclusive in FTE
    //               (gl_backend.c:4305 forces cubemap to NULL when
    //               LSHADER_SPOT is active), so the cvar picks one.
    //   _radius     light range in qu — caps how far the beam reaches.
    //               OUTER FALLOFF distance, not cone width.
    //   _fov        Spot-mode cone half-angle in degrees. Only used
    //               when style = 0. 35 ≈ Maglite, 20 ≈ tac-light,
    //               60 ≈ lantern.
    //   _brightness multiplier on the colour (>1 = HDR bloom on bright shaders)
    //   _color      "r g b" floats 0..1, warm white by default to read as flashlight
    CVar_Add("Client", "cl_flashlight_style",      "1",            CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_radius",     "1000",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_fov",        "50",           CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_brightness", "3",            CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_color",      "0.9 0.9 1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_decal_opacity",        "1",     CVAR_SIDE_CL);
    // Grenade scorch decals — projected via adddecal() so they
    // wrap stair / wall geometry instead of clipping flat. Capped
    // at SCORCH_MAX in cl_scorch.qc; FIFO eviction. 0 disables.
    CVar_Add("Client", "cl_scorch_decals",        "1",     CVAR_SIDE_CL);
    // 0 = scorches fade out over SCORCH_FADE_END seconds (default).
    // 1 = scorches persist with full alpha until the round resets
    //     (CSQC_EVENT_ROUND_CLEANUP wipes them along with bullet
    //     holes / shells). FIFO eviction at SCORCH_MAX still
    //     applies — bump the constant in cl_scorch.qc if you want
    //     more than 32 simultaneous persistent scorches.
    CVar_Add("Client", "cl_scorch_persistent",    "0",     CVAR_SIDE_CL);
    // Blood-splat decals.  Flesh impacts in cl_bulletimpact.qc fire
    // tracelines from the wound — along the bullet exit direction and
    // straight down — and stamp gfx/blood/bloodsplatN onto whatever
    // BSP each trace hits.  Real adddecal() projection, wraps geometry
    // like the scorch system.  0 disables; lifetime + cap live in
    // cl_bloodsplat.qc.
    CVar_Add("Client", "cl_blood_decals",             "1",   CVAR_SIDE_CL);
    // Per-impact spawn budgets — how many wall-spray vs. floor-pool
    // tracelines to attempt for each flesh hit.  0 falls back to the
    // BLOOD_SPAWN_* constants in cl_bloodsplat.qc.
    CVar_Add("Client", "cl_blood_decals_wall_count",  "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_blood_decals_floor_count", "1",   CVAR_SIDE_CL);
    // RGB tint multiplier applied to every blood decal at draw time
    // (1.0 = full bright source PNG; 0.4 = dried-blood maroon).  Pure
    // black collapses to invisible because SRC_ALPHA blend pulls the
    // surface toward 0,0,0 which then alpha-blends to no change.
    CVar_Add("Client", "cl_blood_decals_brightness",  "0.25", CVAR_SIDE_CL);
    // 0 = blood decals fade after BLOOD_FADE_END seconds (default).
    // 1 = full alpha forever, only the FIFO cap removes them.  Same
    //     semantics as cl_scorch_persistent.
    CVar_Add("Client", "cl_blood_persistent",         "1",   CVAR_SIDE_CL);
    // Source-style edge clipping for the BAKED blood-decal trisoup.  When
    // 1 (default) each splat's quad is clipped at spawn against the hit
    // BSP triangle's 3 edges so it conforms to the surface boundary
    // instead of overhanging.  One-shot CPU cost per splat — per-frame
    // render is one addtrisoup_simple per texture either way.  Mirrors
    // cl_bullethole_clip_geom; set 0 to see the raw axis-aligned quads.
    CVar_Add("Client", "cl_blood_decals_clip",        "1",   CVAR_SIDE_CL);
    // Blob shadows (cl_blobshadow.qc): batched soft dark quads projected under models
    // (players/props/ragdolls) along the active gravity dir.  EXPERIMENT — default off;
    // auto-disabled while the engine's r_shadows >= 1 is active (no double shadows).
    CVar_Add("Client", "cl_blobshadows",         "0",    CVAR_SIDE_CL);  // 1 = draw blob shadows
    CVar_Add("Client", "cl_blobshadow_scale",    "1.0",  CVAR_SIDE_CL);  // blob size multiplier (bbox-derived base)
    CVar_Add("Client", "cl_blobshadow_alpha",    "0.5",  CVAR_SIDE_CL);  // max darkness (scaled by local light + height fade)
    CVar_Add("Client", "cl_blobshadow_maxdist",  "256",  CVAR_SIDE_CL);  // trace length: above this height no blob
    CVar_Add("Client", "cl_blobshadow_sunskew",  "0",    CVAR_SIDE_CL);  // skew blobs away from each entity's dominant light (0..1)
    // Light-aware fake-shadow direction (cl_maplights.qc): with r_shadows 2, steer
    // r_shadows_throwdirection each frame toward the weighted blend of nearby map
    // lights, smoothed — shadows swing as you walk past lamps.  SUNLESS MAPS ONLY:
    // on env_sun maps the stuffed sun direction is authoritative and swing hard-disables.
    CVar_Add("Client", "cl_lightshadow_swing",     "0",   CVAR_SIDE_CL);  // 1 = swing the r_shadows-2 direction by map lights (sunless maps)
    CVar_Add("Client", "cl_lightshadow_smooth",    "0.3", CVAR_SIDE_CL);  // direction smoothing time (seconds)
    CVar_Add("Client", "cl_lightshadow_sunweight", "2",   CVAR_SIDE_CL);  // sun term weight (~= a 200 lamp at 141qu; 0 = lamps only)
    // Max simultaneous blood splats (FIFO — oldest evicted past the cap).  Now
    // that decals are baked to a trisoup batch (cheap per-frame), this can go
    // well above the old 96.  Clamped to the compile-time buffer ceiling
    // BLOOD_HARD_MAX (256); raise that + BLOOD_TRISOUP_MAX together for more.
    CVar_Add("Client", "cl_blood_decals_max",         "96",  CVAR_SIDE_CL);
    // Verbose per-shot hitgroup classifier trace.  Prints bone_id,
    // bone-name lookup result, Z fraction inside the target's bbox,
    // and the final classification for every player hit.  Toggle on
    // briefly when verifying head/body multipliers are landing where
    // you aim; off otherwise (chatty).
    CVar_Add("Client", "cl_debug_hitgroup",           "0",   CVAR_SIDE_BOTH);
    // Client-side rain effect.  Drops trace from an upwind sky-anchor
    // down along (cl_rain_angle_x, 0, -1) to the world surface, animate
    // as textured streaks, and stamp small water-drop decals on impact.
    // cl_rain_intensity is a multiplier: 1.0 = 128 simultaneous drops,
    // 32.0 = the internal 4096-drop cap. Texture cvars can point at PNGs,
    // e.g. gfx/rain/heavy_streak.png and gfx/rain/drop_ring.png.
    // cl_rain_reseed_per_frame caps new world traces per rendered frame.
    // cl_rain_fps caps the rain simulation/update rate; 0 = render fps.
    // Fully CSQC; no server cooperation required.
    CVar_Add("Client", "cl_rain",                     "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_intensity",           "0.25", CVAR_SIDE_CL);  // supports up to 32.0 = 4096 active drops
    CVar_Add("Client", "cl_rain_radius",              "1200", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_speed",               "2000", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_angle_x",             "0.4", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_angle_y",             "0.4", CVAR_SIDE_CL);
    // env_hud / titles.txt playback speed multiplier.  1.0 = author
    // timings; <1 = slower (longer hold / longer fades / slower
    // typewriter scroll-out); >1 = faster.  Affects every active
    // env_message simultaneously, so cinematic credit sequences can
    // be slowed down without re-authoring titles.txt.
    CVar_Add("Client", "cl_envhud_speed",             "0.5", CVAR_SIDE_CL);
    // Debug: force every env_message into the screen centre,
    // ignoring titles.txt $position.  Use to verify whether an
    // invisible message is actually firing (centred = renders fine,
    // problem is positional) vs. broken upstream.
    CVar_Add("Client", "cl_envhud_force_center",      "0",   CVAR_SIDE_CL);
    // Server: hold trigger_auto and func_tracktrain startspeed-driven
    // autostart until a live player reaches PlayerSpawn.  Useful on
    // listen servers + single-player maps so intro sequences (the
    // train roll in c0a0a, scripted env_message chains, etc.) don't
    // fire to an empty world before the local user finishes loading.
    CVar_Add("Server", "sv_waitforplayer",            "0",   CVAR_SIDE_SV);
    // Server: skip team-select UI on player connect — pick a random
    // team + player model and drop the joiner directly into the
    // world.  For single-player / story maps where the menu is just
    // friction.
    CVar_Add("Server", "sv_directspawn",              "0",   CVAR_SIDE_SV);
    // Skip the in-game character phase of team-select.  When 1, the
    // main-menu player-model picker (menu/m_playermodels.qc) is the
    // source of truth and clicking a team button joins immediately;
    // impulse 28 (Team Menu binding) is also gated off so the legacy
    // picker can't be re-opened mid-life.  Persisted to server.cfg so
    // it survives map changes during testing.
    CVar_AddUI("Server", "sv_playerselect",           "0",   CVAR_SIDE_SV,
        0, 0, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG,
        CVAR_ENUM_NONE, 0, 0);
    // Sticky main-menu pick — holds a player_model_index value
    // (6, 7, or 8 for the current restricted list).  Read at team-
    // join time when sv_playerselect > 0; default numberK.
    CVar_Add("Client", "cl_player_model_choice",      "7",   CVAR_SIDE_CL);
    // GoldSrc spawn-point Z compatibility.  HL/GoldSrc places
    // info_player_start at the player's feet, but Quake CS-style
    // hulls in this mod centre origin at body mid-height — so on
    // imported HL maps (c0a0/c0a0a/c1a0/...) the player ends up
    // hull_height/2 too high (head clipped through cab roof).  When
    // 1, PlayerPlaceAtSpawnPoint drops the spawn Z by sv_hull_height
    // / 2 so the feet land where the mapper authored them.  Default
    // 0 = native Quake placement (no offset).
    CVar_Add("Server", "sv_goldsrcspawnfix",          "0",   CVAR_SIDE_SV);
    CVar_Add("Client", "cl_rain_center_impacts",      "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_alpha",               "0.35", CVAR_SIDE_CL);  // streak transparency
    CVar_Add("Client", "cl_rain_width",               "0.35", CVAR_SIDE_CL);  // streak thickness
    CVar_Add("Client", "cl_rain_color",               "0.75 0.9 1", CVAR_SIDE_CL);  // RGB, white-blue example
    CVar_Add("Client", "cl_rain_streak_texture",      "gfx/rain/streak", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_splash_texture",      "gfx/rain/splash", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_splash_alpha",        "0.85", CVAR_SIDE_CL);  // splash/drop transparency
    CVar_Add("Client", "cl_rain_splash_size",         "10",  CVAR_SIDE_CL);  // splash/drop size
    // 0 = no splash effect drawn on raindrop impact, 1 = splash quad
    // animates through cl_rain_splash_texture frames at cl_rain_splash_fps.
    CVar_Add("Client", "cl_rain_splash",              "1",   CVAR_SIDE_CL);
    // CSQC-pool (cl_weather_engine 0) LAND impacts now throw the engine
    // weather.splash droplet spray instead of the animated sprite; this is the
    // droplet count per land impact.  (Water impacts still use the ring.)
    CVar_Add("Client", "cl_rain_splash_droplets",     "5",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_reseed_per_frame",    "64",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_stagger",             "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_draw_distance",       "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_fps",                 "40",  CVAR_SIDE_CL);  // rain simulation FPS; 0 = render FPS
    CVar_Add("Client", "cl_rain_length",              "64",  CVAR_SIDE_CL);
    // Splash frame-cycle rate (4-frame animation).  Default 12.5fps =
    // 80ms/frame = 0.32s total splash lifetime.  Bound 1..120 in code.
    CVar_Add("Client", "cl_rain_splash_fps",          "30",  CVAR_SIDE_CL);
    // 1 = additive blend (DRAWFLAG_ADD) on both the upright sprite and
    // the ground ring so splashes pop on dark/foggy maps.  0 = normal
    // alpha blend.  Mirrors cl_snow_fullbright.
    CVar_Add("Client", "cl_rain_splash_fullbright",   "0",   CVAR_SIDE_CL);
    // Weather ambient audio — looped non-positional samples that play
    // whenever cl_rain / cl_snow is on.  Volume 0..1.
    CVar_Add("Client", "cl_rain_ambient_volume",      "0.5", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_snow_ambient_volume",      "0.5", CVAR_SIDE_CL);
    // Lightning — periodic fullscreen white flash + delayed thunder
    // one-shot from sounds/rain/thunder.wav.  Active only while
    // cl_lightning is on AND weather (cl_rain || cl_snow) is on.
    CVar_Add("Client", "cl_lightning",                "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_lightning_min_interval",   "8",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_lightning_max_interval",   "12",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_lightning_flash_duration", "0.25",CVAR_SIDE_CL);
    CVar_Add("Client", "cl_lightning_thunder_min_delay","1", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_lightning_thunder_max_delay","4", CVAR_SIDE_CL);
    // Snow mode: swap streak texture for the snow PNG and change
    // fall trajectory from straight-line streak to slower vertical
    // drop + per-drop sinusoidal horizontal drift.  Texture is
    // configurable via cl_snow_texture (default gfx/rain/snow) so
    // the user doesn't have to drop a file at that exact path —
    // they can point at any existing PNG.  Drift speed governs how
    // far each flake wobbles side-to-side.
    CVar_Add("Client", "cl_snow",                     "0",                CVAR_SIDE_CL);
    CVar_Add("Client", "cl_snow_drift",               "30",               CVAR_SIDE_CL);
    // Default "gfx/rain/snow" — resolved by the shader entry in
    // scripts/effects.shader (alpha-blended, vertex tinted).  If the
    // user clears this cvar to "" the renderer falls back to a
    // $whiteimage-backed shader registered at runtime so flakes
    // still render as plain white squares (see Rain_ResolveMedia).
    CVar_Add("Client", "cl_snow_texture",             "gfx/rain/snow",    CVAR_SIDE_CL);
    // Snow-mode flake half-edge override (separate from cl_rain_width so
    // rain streak width and snow flake size can be tuned independently).
    // Consumed in Rain_ResolveTuning when cl_snow != 0.
    CVar_Add("Client", "cl_snow_width",               "4",                CVAR_SIDE_CL);
    // Snow-mode fall speed override (units/sec). When >0, replaces the
    // legacy 0.15× cl_rain_speed scaling in Rain_ResolveTuning so snow
    // can be tuned independently of rain. Default 600 ≈ slow drift.
    CVar_Add("Client", "cl_snow_speed",               "60",               CVAR_SIDE_CL);
    // Snow drop count multiplier — same scale as cl_rain_intensity
    // (1.0 = 128 flakes, 32 = the 4096-flake cap).  0 or unset falls
    // back to cl_rain_intensity so snow inherits rain's tuning.
    CVar_Add("Client", "cl_snow_intensity",           "0.5",              CVAR_SIDE_CL);
    // Snow-mode flake alpha override (separate from cl_rain_alpha).
    // Consumed in Rain_ResolveTuning when cl_snow != 0 and value > 0.
    CVar_Add("Client", "cl_snow_alpha",               "1",                CVAR_SIDE_CL);
    // Fullbright snow: forces flake vertex color to pure white in the
    // streak draw, bypassing any rain_tick_color tint path.
    CVar_Add("Client", "cl_snow_fullbright",          "1",                CVAR_SIDE_CL);
    // Cheapest snow path — when 1, skip the camera-facing billboard
    // basis entirely and emit world-axis-aligned (+X / +Z) squares
    // instead.  Flakes still draw at their tracked positions but
    // their orientation is fixed in world space rather than tracking
    // the camera.  Saves the per-flake cross + normalize work in
    // Rain_DrawStreak (snow path); visible difference is small on
    // tiny squares.  Use when snow is the framerate bottleneck.
    CVar_Add("Client", "cl_snow_simple",              "0",                CVAR_SIDE_CL);
    // Toggle weather backend.
    //   0 — CSQC pool path (default).  Per-flake QC, supports the
    //       bullet-water-splash slot hijack, water-surface ring on
    //       rain impacts, and tight tuning via the cl_rain_* /
    //       cl_snow_* cvars.
    //   1 — FTE engine particle path.  pointparticles() spawns
    //       weather.snow / weather.rain effects defined in
    //       particles/weather.cfg.  Engine handles particle motion
    //       in C — substantially faster per particle at high
    //       intensity.  Bullet-water splashes still work in engine mode;
    //       the legacy CSQC-pool look (per-flake streaks, cull cvars)
    //       needs cl_weather_engine 0.  DEFAULT: 1 (engine).
    //       Tune visuals by editing particles/weather.cfg.
    CVar_Add("Client", "cl_weather_engine",           "1",                CVAR_SIDE_CL);
    // Engine-mode spawn FOOTPRINT lead: centre the spawn volume this many
    // seconds of player velocity AHEAD so fast movement stays filled (snow,
    // which lingers, uses half).  0 = no lead.  Density is driven by
    // cl_rain_intensity / cl_snow_intensity now (the old
    // cl_weather_engine_density cvar was removed; radius = cl_rain_radius).
    CVar_Add("Client", "cl_weather_lead",             "0.5",              CVAR_SIDE_CL);
    // Engine weather spawn-grid: 1 = skip spawn cells with no sky above the
    // player (no rain/snow under roofs / indoors), via one up-trace per cell.
    // 0 = solid-cell skip only (still no drops inside walls, but rain falls on
    // roofs above you).  Turn off if a map's sky brushes confuse the up-trace.
    CVar_Add("Client", "cl_weather_skycheck",         "0",                CVAR_SIDE_CL);
    // Water-surface rings: pop expanding weather.ringsplash quads where rain
    // lands on water (the engine can't detect water hits per-drop, so a QC
    // emitter traces for water near the camera).  _rate = rings/sec per unit
    // cl_rain_intensity (capped 8/frame).
    CVar_Add("Client", "cl_weather_waterring",        "1",                CVAR_SIDE_CL);
    CVar_Add("Client", "cl_weather_waterring_rate",   "64",               CVAR_SIDE_CL);
    // Live top-left overlay: active weather backend (engine vs CSQC pool),
    // selected effect, spawn rate / target population, pool cap, resolved
    // handles, and the engine's own dump of the effect (type/blend/texture/
    // alpha/rgb/scale).  See CSQC_Weather_DebugDraw in client/cl_rain.qc.
    CVar_Add("Client", "cl_debug_weather",            "0",                CVAR_SIDE_CL);

    // Projectile trail (cl_throwtrail).  Fading polygonal ribbon that
    // follows thrown projectiles (grenades + snowballs).  Same shape
    // as the cl_rain_* cluster — runtime-configurable, no map work
    // needed.  Implementation in client/cl_throwtrail.qc.
    CVar_Add("Client", "cl_throwtrail",               "1",                       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_length",        "1",                       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_width",         "6",                       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_alpha",         "0.15",                    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_color",         "1 1 1",                   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_texture",       "gfx/throwtrail/default",  CVAR_SIDE_CL);
    // Head-end width rampup: trail grows from 0 → cl_throwtrail_width
    // over this many seconds since the projectile was first sampled.
    // 0 disables the ramp (trail starts at full width immediately).
    // Default 0.25s — visible "tapering into existence" from the
    // throw moment.
    CVar_Add("Client", "cl_throwtrail_rampup",        "0.3",                     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_light",    "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_light_scale", "1",   CVAR_SIDE_CL);
    // Playback rate for the ANIMATED flash frames (gfx/muzzle/animated/animated_NN),
    // used by the deagle test path.  Total on-screen time = FRAME_COUNT / this.
    CVar_Add("Client", "cl_muzzleflash_anim_fps", "240",   CVAR_SIDE_CL);
    // Single-frame additive sprite muzzle flash (cl_muzzleflash.qc
    // CSQC_SpawnMuzzleFlashSprite). Picks one of gfx/muzzleflash1..4
    // per shot, then animates SIZE growing while ALPHA fades over
    // the lifetime — soft "puff" without a second hand-authored
    // frame. Refire mid-animation restarts with a new variant.
    //
    //   _sprite          0 = off, 1 = on.
    //   _sprite_time     total seconds the flash is on screen.
    //                    Default 0.06 = 60 ms. Bump higher to
    //                    lengthen, lower to shorten.
    //   _sprite_scale    multiplier on the BASE half-extent
    //                    (16 qu in cl_muzzleflash.qc). Final size
    //                    on screen is base * scale * grow_lerp.
    //   _sprite_shrink   starting size multiplier at age=0 (the
    //                    sprite contracts back to 1x by t=1). 1.0 =
    //                    no shrink; 2.0 = starts twice as big.
    //   _sprite_opacity  starting alpha at t=0 (linearly fades to
    //                    0 by t=1). Per-channel multiplier on the
    //                    additive intensity — 0 = invisible.
    CVar_Add("Client", "cl_muzzleflash_sprite",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_time",    "0.05",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_scale",   "0.35",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_shrink",  "2.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_opacity", "0.7",   CVAR_SIDE_CL);
    // Muzzle smoke "heat" producer (cl_muzzlesmoke.qc). Single
    // global accumulator: every shot bumps `heat`, heat decays
    // exponentially each frame, and emission rate + per-puff
    // thickness both scale with heat through a soft-saturation
    // curve.  No per-shot entities — spam-firing can't stack
    // chains the way the old chain-per-shot system did.
    //
    // Per-puff appearance (orthogonal to the heat model):
    //   _ life        seconds before removal (per-puff jitter applied).
    //   _ size        base half-extent at spawn (qu).
    //   _ grow        end_size / start_size — final puff size at t=1.
    //   _ opacity     peak alpha at fade-in apex.
    //   _ drift_up    upward velocity (qu/sec).
    //   _ drift_fwd   forward velocity (qu/sec, away from camera).
    //   _ texture     shader name passed to R_BeginPolygon — swap
    //                 for a custom puff TGA without recompile.
    //
    // Heat model (drives emission rate + thickness):
    //   _ heat_per_shot   added to heat on every shot.
    //   _ heat_halflife   seconds for heat to halve (exp decay).
    //   _ heat_half       heat value at which rate + thickness
    //                     hit 50% of max (soft-saturation knee).
    //   _ emit_max_hz     puffs/sec at saturation.
    //   _ thick_max       additional per-puff size mult at sat.
    //                     (1 + heat_norm * thick_max).
    //   _ life_bonus      additional per-puff life mult at sat.
    CVar_Add("Client", "cl_muzzlesmoke",                "1",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_life",           "0.35",      CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_size",           "1",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_grow",           "6",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_opacity",        "0.1",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_drift_up",       "4",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_drift_fwd",      "0",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_texture",        "gfx/smoke", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_heat_per_shot",  "1.0",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_heat_halflife",  "0.3",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_heat_half",      "3.0",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_emit_max_hz",    "24",        CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_thick_max",      "0.7",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_life_bonus",     "0.4",       CVAR_SIDE_CL);
    // Cry-of-Fear-style wind drift.  _strength is the qu/sec peak of
    // the world-space oscillator (zero = wind off, matches old behaviour).
    // _inherit bakes a fraction of the current wind into each puff's
    // spawn velocity; _continuous re-samples wind every draw frame and
    // accumulates an offset on top of the linear ms_drift trajectory.
    CVar_Add("Client", "cl_muzzlesmoke_wind_strength",  "90",        CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_wind_inherit",   "1",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_wind_continuous","1",         CVAR_SIDE_CL);
    // Debug visualization for muzzle position tuning. When 1, draws
    // an RGB axis cross at the LAST-fired muzzle offset every frame
    // so you can see how far off the per-weapon _MUZZLE_FORWARD/
    // RIGHT/DOWN constants are from the visible barrel. Fire once
    // with each weapon to "calibrate" the marker, then iterate on
    // the constants with reloads.
    CVar_Add("Client", "cl_debug_muzzle",           "0",         CVAR_SIDE_CL);
    // Brightness ceiling for the viewmodel's lighting sample (engine-side
    // patch). 0–255 byte; 180 keeps a slight ambient cap so the viewmodel
    // doesn't go fully blown-out under bright effects/lights.
    CVar_Add("Client", "r_viewmodel_maxlight",    "0",     CVAR_SIDE_CL);
    // Brightness ceilings for non-viewmodel entities. Implemented QC-side
    // via a colormod scale at predraw time (cl_teamtint.qc + cl_weapons.qc),
    // not in the engine — the engine cap only applies to RF_WEAPONMODEL.
    // Same 0–255 byte semantics as r_viewmodel_maxlight; 0 disables the cap.
    //   _playermodels_  caps light on player_visual_proxy (remote bodies +
    //                   first-person body when shadow-casting). Stacks on
    //                   top of the team-tint colormod.
    //   _physdrops_     caps light on dropped weapon entities (CSQC entities
    //                   with predraw, not engine-replicated phys barrels).
    CVar_Add("Client", "r_playermodels_maxlight", "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "r_physdrops_maxlight",    "0",     CVAR_SIDE_CL);
    // Soft-knee rolloff for the two _maxlight caps above (player models +
    // dropped weapons). Fraction of the cap where brightness starts to
    // roll off smoothly toward the ceiling instead of hard-clamping flat:
    //   1.0 = original hard clamp (a tile above the cap renders exactly at
    //         the cap, losing highlight detail)
    //   0.8 = gentle rolloff near the top (default — softens the blow-out
    //         without dimming midtones much)
    //   lower = softer / dimmer (the rolloff reaches further into midtones)
    CVar_Add("Client", "r_maxlight_softknee",     "0.8",   CVAR_SIDE_CL);
    // Optional distance cull for dropped-weapon rendering. Dropped weapons
    // persist map-wide (PVSF_NOREMOVE) and each re-submits a full engine
    // entity-copy every frame with no built-in cull, so a busy map with
    // hundreds of accumulated drops pays for all of them every frame.
    // Beyond this radius (Quake units) a settled drop is skipped at predraw.
    // 0 = disabled (no cull, default — avoids any pop-in); set e.g. 3000 on
    // drop-heavy maps. Keep it past real engagement sightlines.
    CVar_Add("Client", "r_physdrops_maxdist",     "0",     CVAR_SIDE_CL);
    // Optional PVS occlusion cull for dropped weapons (complements the
    // distance cull above): skip drops that are within range but behind walls
    // / out of the potentially-visible set. 0 = off (default). Safe on all map
    // formats (the engine CoD checkpvs NULL-deref is fixed). Cheap on Quake
    // maps; on Source/CoD maps each test decompresses vis, so it costs a little
    // more per nearby drop — enable where a map accumulates many occluded drops.
    CVar_Add("Client", "r_physdrops_pvscull",     "1",     CVAR_SIDE_CL);
    // Corpse render cull — the only client lever on the engine scene-render
    // floor (an off-screen corpse still costs a full edict-copy + ~50-bone skin
    // every frame with no engine pre-cull). Scoped to SETTLED corpses, keyed off
    // the same death-anim freeze, so a body mid-fall is never culled.
    //   r_corpses_pvscull 1 (default): don't draw a settled corpse that is behind
    //     walls / out of the potentially-visible set. checkpvs is fail-safe
    //     (returns visible when vis data is missing) so it NEVER hides a body in
    //     your line of sight — no pop-in. Biggest win on large maps with bodies
    //     scattered across rooms; ~0 on small maps where everything is in view.
    //   r_corpses_maxdist 0 (default off): also drop settled corpses past this
    //     many units. Opt-in (a distant body can pop in at the radius boundary);
    //     set ~1500-2000 on very open maps if corpse skinning still dominates.
    CVar_Add("Client", "r_corpses_pvscull",       "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "r_corpses_maxdist",       "0",     CVAR_SIDE_CL);
    // Live-player render cull — the same idea for LIVING player proxies (the 16-bot
    // firefight / free-spectator-cam floor). An off-screen / behind-wall living body
    // still costs the full IQM spine deform + ~50-bone skin every frame with no engine
    // pre-cull. checkpvs from the view origin (the spectator cam when spectating) drops
    // it. Fail-safe (never hides a body in your line of sight, no pop-in) and a near-no-op
    // in first person (your networked proxies are already in your PVS). NEVER culls the
    // spectated target or a killcam-posed proxy.
    CVar_Add("Client", "r_players_pvscull",       "1",     CVAR_SIDE_CL);
    // Mirror the viewmodel horizontally for left-handed weapon view.
    // XOR'd against the per-weapon `weapon_viewmodel_flip` default so a
    // model that is already left-handed in its source data flips back
    // to right-handed when this is on.
    CVar_Add("Client", "cl_lefthand",             "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_playerdamage",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_extrap",               "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_extrap_grounded",      "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_extrap_smooth",        "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_extrap_smooth_time",   "0.031", CVAR_SIDE_CL);
    // Fade per-reconcile prediction error on the local view origin so
    // tiny replay-vs-live-pmove biases don't pump the camera in the
    // movement direction every snapshot at high ping.  Mirrors the
    // remote-proxy smoother that uses cl_extrap_smooth_time as its
    // decay constant.  Set 0 to revert to the old snap behaviour.
    CVar_Add("Client", "cl_driftlock",         "1",     CVAR_SIDE_CL);
    // Decay time (s) for the dropped-weapon / projectile snap-correction
    // smoothing in cl_tosssmooth.qc. Longer = smoother but more visible
    // catch-up; shorter = snappier but more visible micro-snaps. Held
    // separate from cl_extrap_smooth_time so item smoothing can be tuned
    // without affecting remote-player smoothing.
    CVar_Add("Client", "cl_toss_smooth_time",     "0.05",  CVAR_SIDE_CL);
    // ODE weapon-drop render smoothing. By default physics drops smooth
    // between authoritative samples without client-side velocity/angle
    // prediction, which avoids visible wobble when ODE settles.
    CVar_Add("Client", "cl_physdrop_smooth_time", "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_physdrop_extrap",      "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_physdrop_angextrap",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_interp_time",          "0",     CVAR_SIDE_CL);
    // Maximum extrapolation horizon (snapshots) before frozen — 10 keeps
    // ~150 ms of cover for high-jitter links without letting an entity
    // drift forever after a packet loss spike.
    CVar_Add("Client", "cl_extrap_max",           "10",    CVAR_SIDE_CL);

    // ---------- Performance / Frame pacing (engine cvars) ----------
    // Registered here so they appear in the Perf & Net settings tab and
    // get persisted via client_config_cvars[]. The engine owns the
    // actual cvar; CVar_Add just forwards the default + flags.
    CVar_Add("Performance", "sys_highpriority",     "1",     CVAR_SIDE_CL);
    CVar_Add("Performance", "sys_clockprecision",   "1",     CVAR_SIDE_CL);
    CVar_Add("Performance", "sys_clocktype",        "2",     CVAR_SIDE_CL);
    CVar_Add("Performance", "sys_framepacing",      "4",     CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_yieldcpu",          "0",     CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_maxfps",            "300",   CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_idlefps",           "64",    CVAR_SIDE_CL);

    // ---------- Renderer (engine cvars) ----------
    CVar_Add("Renderer", "vid_conautoscale",      "2",     CVAR_SIDE_CL);
    CVar_Add("Renderer", "r_renderscale",         "2",     CVAR_SIDE_CL);
    // Texture filtering modes — single-char codes per axis. Defaults
    // chosen for crisp pixel-art look:
    //   gl_texturemode2d = "n.l"  (nearest min, no mip, linear mag)
    //   gl_texturemode   = "nll"  (nearest min, linear mip, linear mag)
    CVar_Add("Renderer", "gl_texturemode2d",      "n.l",   CVAR_SIDE_CL);
    CVar_Add("Renderer", "gl_texturemode",        "nll",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_teamcolours",          "1",     CVAR_SIDE_CL);
    // Prop Hunt "march" bob — the disguised-prop South-Park waddle
    // (client/cl_player.qc disguise predraw).  Purely cosmetic; scales with
    // movement speed.  Master toggle + roll amplitude (deg), vertical hop
    // (qu), and stride length (qu of travel per half-step of the sine phase).
    CVar_Add("Client", "cl_prop_bob",             "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_prop_bob_roll",        "4",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_prop_bob_hop",         "1.5",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_prop_bob_stride",      "20",    CVAR_SIDE_CL);
    // Seconds of low-pass on the wire velocity that drives the march-bob cadence.  The
    // proxy's .velocity arrives as a per-packet snap, which stepped the stride; 0 uses
    // the 0.08 default.  Cosmetic only — nothing physical reads the filtered value.
    CVar_Add("Client", "cl_prop_bob_smooth",      "0.08",  CVAR_SIDE_CL);
    // Prop Hunt disguise POSE interpolation (client/cl_player.qc, PlayerVis_PoseAngles).
    // 1 = blend the last two received poses with CarryRot_Nlerp so another player's prop
    // rotates continuously instead of stepping once per packet.  0 = the old hard snap
    // to the newest pose, for A/B.  Ratio is the render delay in MEASURED packet
    // intervals — 1 is the minimum that never renders into the future; raise it for more
    // buffer against packet loss at the cost of visual lag.  (Mirrors
    // cl_physprop_smoothinterp / cl_physprop_interp_ratio, which solve the same problem
    // for physics props.)
    CVar_Add("Client", "cl_prop_smoothrot",       "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_prop_interp_ratio",    "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_menu_backdrop",        "1",     CVAR_SIDE_CL);
    // Scoreboard backdrop blur — when 1, HUD_DrawScoreboard runs a
    // 2-pass separable Gaussian blur of $currentrender via two
    // drawpic calls (screen_blur_h then screen_blur_v) before
    // drawing the scoreboard, so the world behind the scoreboard
    // looks soft-focused.  Costs ~18 texture samples per screen
    // pixel ONLY while the scoreboard is open — zero cost during
    // gameplay since drawpic only fires inside the scoreboard
    // draw path.  Toggle off if perf is tight on weak GPUs.
    CVar_Add("Client", "cl_scoreboard_blur",        "1",     CVAR_SIDE_CL);
    // Per-tap offset in normalized texture-coord space — the user-
    // facing TARGET radius (what blur looks like at full open-state).
    // 4 taps on each side of center, so peak offset = 4 * radius.
    // 0.0033 ≈ ~6 px at 1080p, ~9 px at 1440p — soft "menu backdrop"
    // blur.  Higher = more pronounced blur.
    //
    // The GLSL shaders DON'T read this directly.  HUD_DrawScoreboard
    // multiplies it by the slide-in animation's eased visibility
    // each frame and writes the result into sb_blur_radius_dyn,
    // which is what the shaders' !!cvarf bindings actually sample.
    // Result: blur radius glides from 0 → this value as the
    // scoreboard rises into place, and back to 0 as it falls out.
    CVar_Add("Client", "cl_scoreboard_blur_radius", "0.001",  CVAR_SIDE_CL);
    // Internal — per-frame animated blur radius written by
    // HUD_DrawScoreboard, read by the screen_blur_h/v shaders via
    // !!cvarf binding.  Underscore prefix marks it as not user-
    // facing; users tune cl_scoreboard_blur_radius (the target)
    // instead.
    CVar_Add("Client", "sb_blur_radius_dyn",       "0",      CVAR_SIDE_CL);
    // Scoreboard slide-in animation tunables.  cl_scoreboard_time is
    // the IN duration (seconds, 0 = snap); the OUT duration is
    // computed as 1.2 * cl_scoreboard_time so the close is always 20%
    // slower than the open — a hand-tuned ratio that gives weight to
    // the "going-away" feel without making the user wait.
    // cl_scoreboard_raise is the vertical distance (px) the board
    // starts BELOW its rest position before sliding up.
    CVar_Add("Client", "cl_scoreboard_time",       "0.18",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_scoreboard_raise",      "20",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshair",            "1",     CVAR_SIDE_CL);
    // Server gate on the entire crosshair draw — mirrored to CSQC via
    // serverinfo (sv_main.qc).  Default 1 so legacy servers don't blank
    // crosshairs for new clients.
    CVar_Add("Server", "sv_crosshair",            "1",     CVAR_SIDE_SV);
    CVar_Add("Client", "cl_crosshairlength",      "7",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairthickness",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairgap",         "4",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshaircolour",      "0 255 0", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairdynamic",     "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairweapongap",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "r_damageflash_intensity", "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "net_graph",               "0",     CVAR_SIDE_CL);

    // ---------- Voice / VoIP (client) ----------
    // All cvars below are pre-registered by the engine.  Listing them in
    // the QC table attaches mod-side UI metadata so the F1 settings
    // menu's "Voice" tab can render widgets, and the existing per-client
    // settings.cfg writer persists user picks across launches.
    //
    // Defaults overlap with cfg/default.cfg's `set` lines for engine
    // cvars (the QC manifest's registercvar() is a no-op for cvars the
    // engine pre-registered, so default.cfg is what actually applies
    // them on a fresh install — these defaults are documentation /
    // fallback only).
    CVar_AddUI("Voice", "cl_voip_send",           "0",     CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Send Mode (0=PTT 1=VAD 2=Always)",
        0, CVAR_ENUM_NONE, 0, 2);
    CVar_AddUI("Voice", "cl_voip_codec",          "2",     CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Codec (2=Opus 4=Speex16k)",
        0, CVAR_ENUM_NONE, 0, 7);
    CVar_AddUI("Voice", "cl_voip_capturedevice",  "",      CVAR_SIDE_CL,
        CVAR_UI_STRING, CVAR_TAB_VOICE, "Capture Device",
        0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Voice", "cl_voip_micamp",         "1",     CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Mic Gain",
        0, CVAR_ENUM_NONE, 0, 10);
    CVar_AddUI("Voice", "cl_voip_play",           "1",     CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Receive Volume",
        0, CVAR_ENUM_NONE, 0, 2);
    CVar_AddUI("Voice", "cl_voip_capturingvol",   "0.5",   CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "My Voice Sidetone",
        0, CVAR_ENUM_NONE, 0, 1);
    CVar_AddUI("Voice", "cl_voip_ducking",        "0.5",   CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Game Audio Duck",
        0, CVAR_ENUM_NONE, 0, 1);
    CVar_AddUI("Voice", "cl_voip_noisefilter",    "1",     CVAR_SIDE_CL,
        CVAR_UI_TOGGLE, CVAR_TAB_VOICE, "Noise Filter",
        0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Voice", "cl_voip_autogain",       "1",     CVAR_SIDE_CL,
        CVAR_UI_TOGGLE, CVAR_TAB_VOICE, "Auto Gain",
        0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Voice", "cl_voip_vad_threshhold", "15",    CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "VAD Threshold",
        0, CVAR_ENUM_NONE, 0, 50);
    CVar_AddUI("Voice", "cl_voip_bitrate",        "24000", CVAR_SIDE_CL,
        CVAR_UI_SCALAR, CVAR_TAB_VOICE, "Bitrate",
        0, CVAR_ENUM_NONE, 6000, 32000);
    CVar_AddUI("Voice", "cl_voip_test",           "0",     CVAR_SIDE_CL,
        CVAR_UI_TOGGLE, CVAR_TAB_VOICE, "Mic Test (loopback)",
        0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Voice", "cl_voip_showmeter",      "1",     CVAR_SIDE_CL,
        CVAR_UI_TOGGLE, CVAR_TAB_VOICE, "Engine Meter",
        0, CVAR_ENUM_NONE, 0, 0);
    // Mod-side cvar — gates our custom HUD widget (the green "+VOIP"
    // indicator + speaker list in the bottom-left, drawn by
    // HUD_VoIP_Draw in client/cl_voip_hud.qc).
    CVar_AddUI("Voice", "hud_voip_show",          "1",     CVAR_SIDE_CL,
        CVAR_UI_TOGGLE, CVAR_TAB_VOICE, "Show VoIP HUD",
        0, CVAR_ENUM_NONE, 0, 0);

    // VOIP iconography tuning.
    //   cl_voip_overhead         — draw the speaker icon floating
    //                              above each remote player in the
    //                              3D world.  0 disables for cinematic
    //                              modes; HUD icons stay regardless.
    //   cl_voip_overhead_size    — half-extent of the in-world quad
    //                              in quake units (32 = 64u tall).
    //   cl_voip_overhead_offset  — Z offset above proxy.origin where
    //                              the icon centres.  Tuned to sit
    //                              just above the player's head.
    //   cl_voip_fadeduration     — seconds before the speaker icon
    //                              fully fades after they stop.
    CVar_Add("Client", "cl_voip_overhead",         "1",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_voip_overhead_size",    "8",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_voip_overhead_offset",  "36",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_voip_fadeduration",     "2",    CVAR_SIDE_CL);

    // ---------- Client debug ----------
    CVar_Add("Client debug", "cl_debug_impacts",     "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hitboxes",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hbexpand",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_physprops",   "0", CVAR_SIDE_CL);
    // Wireframe line thickness for ALL debug overlays (nav, hitboxes, impacts, bboxes,
    // physprops, etc.).  1 (default) = cheap true 1px GL_LINES.  >1 = that many units of
    // thickness, drawn as camera-facing quads instead (GL line width isn't reliable, so
    // thickness reverts to real geometry — costs more, only when you ask for it).
    CVar_Add("Client debug", "cl_debug_wire_thickness", "1", CVAR_SIDE_CL);
    // Debug: disable phys-prop extrapolation smoothing to see the raw server
    // send cadence (default 0 = extrapolation ON).  Read in cl_physprop.qc.
    CVar_Add("Client debug", "cl_physprop_noextrap", "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_physprop_wake_lerp", "0", CVAR_SIDE_CL);  // seconds a prop woken from rest lerps to catch up to its first update (bounds the stale-gap crawl so a jolt looks prompt+smooth). 0 = instant snap.
    CVar_Add("Client debug", "cl_physprop_extrap_max", "0.25", CVAR_SIDE_CL);  // max seconds a moving prop/car coasts on its streamed velocity when the next snapshot is late (instead of FREEZING at the last one — the fast-car stutter). Bounds runaway on packet loss. 0 = old freeze behaviour.
    // Smoothed render delay.  The prop interpolator used to derive BOTH its lerp window and its render
    // delay from the gap between the last two packets — one number doing two jobs.  That made the delay
    // move whenever the packet cadence moved: a dropped packet doubled it (a 100% swing at 64 Hz), and the
    // wake repair deliberately shrank it for one frame and then snapped back.  Now the delay comes from a
    // running average of the OBSERVED arrival rate (measured per entity, so cars and free props each get
    // their own), while the raw gap keeps its real job as the lerp window.
    // 0 = exact previous behaviour, for A/B: instantaneous gap + cl_physprop_wake_lerp + the old fixed
    // 0.3 s wake threshold + the old carry-handoff seed.
    CVar_Add("Client debug", "cl_physprop_smoothinterp", "1", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_physprop_interp_ratio", "1", CVAR_SIDE_CL);  // render delay = this MANY measured intervals. 1 = one interval back (minimum that never renders into the future). Raise for more buffer against packet loss, at the cost of more visual lag.
    // Relink carried/falling prop collision hulls at prediction rate instead of render
    // rate (PhysProp_RelinkHullsForPrediction).  0 = the old render-rate-only path,
    // kept for A/B.  Was unregistered and therefore stuck at 0 — the feature had
    // never actually run.
    CVar_Add("Client debug", "cl_physprop_hull_mode", "1", CVAR_SIDE_CL);
    CVar_Add("Vehicles", "cl_car_wheels",        "1",     CVAR_SIDE_CL);  // render prop_car spinning/steering wheels from the wheelmodel key (0 = off / baked wheels)
    CVar_Add("Vehicles", "cl_car_wheel_radius",  "12.64", CVAR_SIDE_CL);  // visual wheel rolling radius (qu) driving the spin rate; match your wheel model
    CVar_Add("Vehicles", "cl_car_wheel_z",       "0",     CVAR_SIDE_CL);  // vertical nudge (qu) of the visual wheels along the car's up axis (tune so tyres meet the ground)
    CVar_Add("Vehicles", "cl_car_wheel_spin",    "1",     CVAR_SIDE_CL);  // spin direction/scale (set -1 if the wheels roll backward)
    CVar_Add("Vehicles", "cl_car_wheel_steer",   "-1",    CVAR_SIDE_CL);  // steer direction (set -1 if the wheels turn the wrong way vs +moveleft/right)
    CVar_Add("Vehicles", "cl_car_wheel_fwd",     "0",     CVAR_SIDE_CL);  // live fore/aft nudge of the visual wheel set (u); added to the per-car wheel_fwd key
    // Client-side seated driver model (rendered glued to the interpolated car pose — smooth, first-person visible).
    CVar_Add("Vehicles", "cl_car_driver",        "1",     CVAR_SIDE_CL);  // render the seated driver model client-side (0 = off)
    CVar_Add("Vehicles", "cl_car_driver_frame",  "112",   CVAR_SIDE_CL);  // static pose frame for the seated driver (112 = CSANIM_LEGS_CROUCH_STATIC, no-IK crouch)
    // Client-side tailpipe exhaust puff (reuses the bullet metal-impact smoke effect).  The pipe point is a
    // pure offset from the car's box centre along its chassis basis, so dial these to your model's real pipe.
    CVar_Add("Vehicles", "cl_car_exhaust",       "1",     CVAR_SIDE_CL);  // render tailpipe exhaust smoke (0 = off)
    CVar_Add("Vehicles", "cl_car_exhaust_x",     "-70",   CVAR_SIDE_CL);  // fore/aft from the car origin along chassis fwd (qu; - = rear)
    CVar_Add("Vehicles", "cl_car_exhaust_y",     "25",    CVAR_SIDE_CL);  // left/right from the car origin (qu; + = right)
    CVar_Add("Vehicles", "cl_car_exhaust_z",     "12",    CVAR_SIDE_CL);  // height ABOVE the car origin (qu) — origin sits at ground, so keep this positive or the puff is underground
    // 0=off, 1=ODE tight rotated box, 2=trace inflated AABB, 3=both.
    // Draws every csqc_dropped_weapon's bbox so the user can verify
    // the ODE collision shape matches the visible mesh and that the
    // inflated traceline AABB encloses it at every rotation.
    CVar_Add("Client debug", "cl_debug_physdrop_bbox", "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_net",         "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_bandwidth",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_weapon",      "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_move",        "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_game",        "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_surface",     "0", CVAR_SIDE_CL);   // live material readout: look-at + underfoot (surfaceprops tuning)
    CVar_Add("Client debug", "cl_debug_prop",        "0", CVAR_SIDE_CL);   // live phys-prop readout under the crosshair (material/mass/friction + live speed + push knobs)
    CVar_Add("Client debug", "cl_debug_playermodel", "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_smoothing",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_spikes",      "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_spike_ms",    "2.0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_footsteps",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_extrap",      "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_noblock",     "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_spray",       "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_panelinput",  "0", CVAR_SIDE_CL);
    // Per-reconcile prediction-error trace.  dprints `elen pre post` so
    // you can see whether `cl_driftlock` even has anything to smooth
    // (elen consistently < 0.5 = the drift is coming from a non-
    // reconcile path and this smoother is dormant).
    CVar_Add("Client debug", "cl_debug_driftlock", "0", CVAR_SIDE_CL);
    // Per-substep trace of the rotating-brush carry pass — prints the
    // brush's avelocity, picked axis, deg_step, tracebox fraction, and
    // pre/post pm_origin each time PM_CheckRotatingCarry applies a
    // rotation to the predicted player.  Goes silent the moment the
    // ground gate rejects (player off the brush / jumping), which is
    // the natural confirmation that detection is firing only when the
    // player is standing on a rotating brush.
    CVar_Add("Client debug", "cl_debug_rotcarry",    "0", CVAR_SIDE_CL);
    // Live overlay summarising local-prediction drift state: cumulative
    // and per-snapshot divergence between live (camera) and post-replay
    // (server view), input state, lock state, smoother offset, and the
    // teleport-snap threshold.  Use to understand at a glance why the
    // camera is or isn't tracking the bbox at high ping.
    CVar_Add("Client debug", "cl_debug_drift",       "0", CVAR_SIDE_CL);
    // Verbose hit-prediction trace: every CSQC bullet/melee predicted
    // hit prints its trace_ent, classification (player vs not), bone,
    // and SEND/skip outcome. Use to diagnose "splash but no damage" or
    // headshot-detection issues. Print, not dprint — works without
    // `developer 1`.
    CVar_Add("Client debug", "cl_debug_hitclaim",    "0", CVAR_SIDE_CL);
    // Debug-draw the WEAPON_PICKUP_* zone cube around every dropped
    // weapon (real + CSQC fake). Authoritative on the server (used by
    // W_PhysDropPlayerClose) and mirrored in CSQC predict, so this
    // cube IS what +use considers "in range" — independent of the
    // entity's setsize physics body that r_showbboxes shows.
    CVar_Add("Client debug", "cl_debug_pickupzone",  "0", CVAR_SIDE_CL);

    // ---------- Multiplayer ----------
    // Every entry below appears in the F2 panel (MULTI tab); the ones
    // also visible in the Create Server menu's "Game" tab carry the
    // CVAR_TAB_CREATE_GAME bit.  All persist to server.cfg.
    CVar_AddUI("Multiplayer", "mp_cheats",            "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_falldamage",        "1",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_freezetime",        "3",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 60);
    CVar_AddUI("Multiplayer", "mp_friendlyfire",      "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // --- Prop Hunt (GAMEMODE_PROPHUNT) ---
    // Hide-phase length in seconds (the round-freeze IS the hide phase; only
    // seekers are locked).  Separate from mp_freezetime so other modes keep
    // their short freeze.
    CVar_AddUI("Multiplayer", "mp_ph_hidetime",       "30", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Hide Time",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 120);
    // Hiders per seeker for the forced round-start shuffle (4 = 1v4, 2v8...).
    CVar_AddUI("Multiplayer", "mp_ph_ratio",          "4",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Hiders/Seeker",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 8);
    // Fraction of the weapon's damage a seeker takes for shooting a REAL prop
    // (per pellet, so sprayed shotguns punish hard).  0 disables missfire.
    CVar_AddUI("Multiplayer", "mp_ph_missfire_scale", "0.5", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Missfire Dmg",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2);
    // HP restored to a seeker for killing a hider (capped at 100).
    CVar_AddUI("Multiplayer", "mp_ph_killheal",       "50", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Kill Heal",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 100);
    // Hider max-HP scale: HP = bound(1, rint(prop bbox volume / 1000 * this), mp_ph_maxhp).
    // Tincan (~360qu^3) -> 1hp; big crate (~33000qu^3) -> ~100hp.
    CVar_AddUI("Multiplayer", "mp_ph_hpscale",        "3",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH HP Scale",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 20);
    CVar_AddUI("Multiplayer", "mp_ph_maxhp",          "100", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Max HP",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 200);
    // How far a hider's +use possess trace reaches (world units).
    CVar_AddUI("Multiplayer", "mp_ph_possess_dist",   "160", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Possess Range",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 32, 512);
    // 1 = Prop Hunt HIDERS stay weaponless: they cannot pick up a gun (walk-over
    // or +use) and cannot fire one.  They already SPAWN empty (PlayerSpawn pins
    // the loadout), but nothing stopped a hider strolling over a dead seeker's
    // dropped rifle and shooting back, which is not the game.  0 = armed hiders.
    CVar_AddUI("Multiplayer", "mp_ph_hider_noweapons", "1", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "PH Hiders Weaponless",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Defuse mode: when 1, the bomb-carrier can plant the C4 anywhere
    // (testing default).  When 0 + the map has func_bomb_target brushes,
    // plant is gated to inside those volumes.  Maps without bomb_target
    // entities always allow plant anywhere regardless of this value.
    CVar_AddUI("Multiplayer", "mp_plantanywhere",     "1",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Plant Anywhere",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Diagnostic prints for the C4 defuse interaction — set 1 to dump
    // [c4-defuse] / [c4-bomb] traces to the server console.  Useful
    // for diagnosing why a defuse isn't progressing.  Off by default.
    CVar_AddUI("Server debug", "sv_debug_c4",         "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, 0, "",
        0, CVAR_ENUM_NONE, 0, 0);
    // Per-player corpse cap.  0 = no persistent corpses (the body is removed
    // the moment the player respawns); >=1 = keep at most ONE body per player
    // — when a player dies, THEIR previous corpse is retired so only the latest
    // remains (the body survives respawn).  Values >1 currently behave the same
    // as 1 (single-corpse tracking; true N-per-player would need a per-player
    // corpse list).  Round restart still wipes everything regardless.
    CVar_AddUI("Multiplayer", "mp_deadbodies",        "1",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 8);
    CVar_Add("Multiplayer", "mp_deadbody_sink_depth", "64",  CVAR_SIDE_SV); // COD despawn: units a corpse sinks into the ground
    CVar_Add("Multiplayer", "mp_deadbody_sink_time",  "1.0", CVAR_SIDE_SV); // seconds the sink takes (0 = instant removal)
    CVar_Add("Multiplayer", "sv_killcam",             "1",   CVAR_SIDE_SV); // server records every player's camera track + unicasts the killer's to the victim on death (fills the killcam's out-of-PVS approach gap; 0 = client-buffer killcam only)
    // Server-side authoritative death ragdolls (sv_ragdoll.qc) — everyone sees the flop, bullets shove them.
    CVar_Add("Multiplayer", "sv_ragdoll_enable",        "1",   CVAR_SIDE_SV); // 1 = spawn a server-simulated ragdoll on weapon/FF kills (replaces the client-side cosmetic one)
    CVar_Add("Multiplayer", "sv_ragdoll_death_impulse", "220", CVAR_SIDE_SV); // knockback (u/s) along the shot dir seeded into the limbs at death
    CVar_Add("Multiplayer", "sv_ragdoll_hit_force",     "3",   CVAR_SIDE_SV); // bullet shove = shot_dir * damage * this (whole-doll)
    CVar_Add("Multiplayer", "sv_ragdoll_throwspeed",    "700", CVAR_SIDE_SV); // `cmd throwragdollsv` test-spawner launch speed (mp_cheats)
    // CSQC cosmetic-ragdoll equivalents (client/cl_ragdoll.qc).  Separate from the
    // sv_ragdoll_* pair above: these drive the client-only doll used when
    // sv_ragdoll_enable is 0 and the `spawnragdoll` / `throwragdoll` test commands.
    CVar_Add("Client", "cl_ragdoll_death_impulse",      "220", CVAR_SIDE_CL); // knockback (u/s) along the shot dir seeded into the client doll
    CVar_Add("Client", "cl_ragdoll_throwspeed",         "500", CVAR_SIDE_CL); // `throwragdoll` launch speed from the eye
    // Server-console trigger cvars — set to non-zero from the server
    // console (or via rcon) to invoke a one-shot cleanup pass.  The
    // server StartFrame (sv_main.qc) detects the non-zero value, runs
    // the corresponding sweep, and resets the cvar to 0.  No UI
    // exposure (CVAR_TAB_NONE-equivalent zero flag) — these aren't
    // user-facing options, they're admin commands typed as
    //   cleanmodels 1
    //   cleandecals 1
    // at the server console.
    //   cleanmodels — wipes corpses (server-side) + casings + mags
    //                 (CSQC) in one frame.  Decals/scorch/smoke survive.
    //   cleandecals — wipes bullet holes + scorch + muzzle smoke +
    //                 CS smoke-grenade puffs (all CSQC).  Corpses +
    //                 casings survive.
    CVar_AddUI("Server", "cleanmodels",               "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, 0, "",
        0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "cleandecals",               "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, 0, "",
        0, CVAR_ENUM_NONE, 0, 0);
    // Server-side VoIP toggles.  All three persist into cfg/server.cfg
    // (the CVar_WriteServerCfg writer keys off CVAR_FLAG_SAVE_TO_SERVER_CFG)
    // and surface in the F2 server panel + Create Server menu.
    //   sv_voip        — master receive; if 0, voice packets dropped.
    //   sv_voip_record — record voice into MVD demos (0=off / 1=all /
    //                    2=spectators-only).
    //   sv_voip_echo   — debug; echo voice packets back to sender.
    CVar_AddUI("Server", "sv_voip",                   "1",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_SERVER, "Voice Chat",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_voip_record",            "0",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_SERVER, "Voice MVD Record (0/1/2)",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2);
    CVar_AddUI("Server", "sv_voip_echo",              "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_SERVER, "Voice Echo (debug)",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_maprestartdelay",   "10", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_maxrounds",         "12", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 999);
    CVar_AddUI("Multiplayer", "mp_noblock",           "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_nomapweapons",      "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Multiplayer", "mp_respawn",           "1",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // mp_dropweapons — what gear the player drops on death.
    //   0 = nothing
    //   1 = primary + secondary only
    //   2 = everything (current default — primary, secondary, melee,
    //       active utility, and every leftover grenade variant)
    CVar_AddUI("Multiplayer", "mp_dropweapons",       "2",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2);
    CVar_AddUI("Multiplayer", "mp_respawndelay",      "7",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 30);
    CVar_AddUI("Multiplayer", "mp_roundrestartdelay", "5",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 60);
    CVar_AddUI("Multiplayer", "mp_roundtime",         "5",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 999);
    CVar_AddUI("Multiplayer", "mp_timelimit",         "25", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 999);
    CVar_AddUI("Multiplayer", "mp_weaponweight",      "1",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // 1 = func_door / func_button activation is suppressed (use/touch
    // handlers early-return). Live toggle: changes apply mid-game with
    // no map restart. Bhop forces this on via the per-gamemode block in
    // sv_main.qc StartFrame; admins can also enable in any other mode.
    CVar_AddUI("Multiplayer", "mp_disabledoors",      "0",  CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // func_door / func_door_rotating proximity auto-open.  0 (default) = doors open ONLY on +use /
    // target-chain / damage — never on walk-near (and no every-frame direction reversal that the
    // per-frame proximity re-fire caused).  1 = restore the legacy proximity trigger.  Read at door
    // spawn (map load), so a map restart is needed for a change to take effect.
    CVar_Add("Server", "sv_door_proximity", "0", CVAR_SIDE_SV);

    // ---------- Economy / buy menu (mp_cash*) ----------
    // CS-style cash.  Server-authoritative — the client greys out
    // unaffordable buy-menu items from the synced money stat, never these.
    CVar_AddUI("Multiplayer", "mp_cashstart",         "800",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Starting Cash",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 16000);
    CVar_AddUI("Multiplayer", "mp_cashreward",        "300",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Cash Per Kill",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 16000);
    CVar_AddUI("Multiplayer", "mp_cashwin",           "3250",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Cash Round Win",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 16000);
    CVar_AddUI("Multiplayer", "mp_cashlose",          "1400",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Cash Round Loss",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 16000);
    CVar_AddUI("Multiplayer", "mp_cashheadshot",      "0",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Headshot Bonus Cash",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 16000);
    CVar_AddUI("Multiplayer", "mp_cashmax",           "16000", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Max Cash",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 999999);
    // 1 = buy anywhere (ignore func_buyzone brushes).  0 = must stand in an
    // allowed buy zone; maps with NO func_buyzone fall back to buy-anywhere.
    CVar_AddUI("Multiplayer", "mp_buyanywhere",       "0",     CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_MULTI | CVAR_TAB_CREATE_GAME, "Buy Anywhere",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // ---------- Server ----------
    // Gamemode dropdown — RCON tab + Create Server's Game tab.
    CVar_AddUI("Server", "sv_gamemode",                  "0",      CVAR_SIDE_SV,
        CVAR_UI_ENUM, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_GAMEMODE, 0, 0);
    CVar_AddUI("Server", "sv_gravity",                   "800",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_maxspeed",                  "270",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_MOVE, "Max Speed",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 50, 2000);
    CVar_AddUI("Server", "sv_friction",                  "4",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_MOVE, "Friction",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 50);
    CVar_AddUI("Server", "sv_waterfriction",             "1",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_wateraccelerate",           "10",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_accelerate",                "5",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_MOVE, "Accelerate",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 100);
    CVar_AddUI("Server", "sv_airaccelerate",             "150",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_MOVE, "Air Accel",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 1000);
    CVar_AddUI("Server", "sv_stopspeed",                 "100",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Multiplier on input + max speed while +button4 is held.  >1 sprint,
    // <1 walk, 1 = no-op (key armed but inert), 0 = disabled.  Migration:
    // old absolute-qu/s default was 135 — anyone with that value carried
    // forward will now sprint at 135× speed, so update server.cfg.
    CVar_AddUI("Server", "sv_shiftspeed",                "1.3",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Blocks +attack while the player is in a sprinting stance
    // (sv_shiftspeed>1, +button4 held, moving forward on the ground,
    // not ducking).  Applies uniformly to hitscan, projectile and
    // grenade weapons via Weapon_SprintBlocksFire in sh_pmove.qc.
    CVar_AddUI("Server", "sv_sprintdisableshooting",     "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Duck-land slide: engages on landing edge when crouched at
    // hspeed >= sv_sliding_start_speed, friction is multiplied by
    // sv_sliding_friction_mult until hspeed drops below
    // sv_sliding_end_speed or the duck key / ground are released.
    CVar_AddUI("Server", "sv_sliding",                   "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_sliding_start_speed",       "250",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_sliding_end_speed",         "128",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_sliding_friction_mult",     "0.3",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Post-landing jump cooldown — blocks PM_CheckJump for this many
    // seconds after every landing edge (anti-bhop).  0 = disabled.
    // Synced via the prediction proxy so the client doesn't predict
    // a jump the server will reject.
    CVar_AddUI("Server", "sv_jumplag",                   "0.15",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Disable PM_CategorizePosition's snap-to-ground for this many
    // seconds after every accepted jump impulse.  Without this, low-
    // impulse jumps (sv_codstamina_punish_jump_scale low values land
    // just under the 180 u/s airborne threshold) get yanked back to
    // the floor on the same tick they leave it.  The grapple yank is
    // also gated separately on grapple_rope_active in PM_CategorizePosition
    // (no cvar — always on while the rope is active).
    CVar_Add("Server", "pm_groundstick_suppress_jump", "0.05",    CVAR_SIDE_SV);
    // Extra velocity along the current horizontal direction stamped
    // once when a slide engages (either landing-edge or crouch-press
    // trigger).  0 = no boost.
    CVar_AddUI("Server", "sv_sliding_boost",             "80",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Crouch-press slide entry.  When the player presses crouch from
    // standing on flat ground at hspeed >= sv_sliding_start_speed,
    // the hull instant-lifts (no smooth duck animation) so its bottom
    // is at standing eye-level; camera stays where it was; player
    // falls a short distance and the landing-edge handler engages the
    // slide.  Below sv_sliding_start_speed the press does a normal
    // smooth crouch — no special behaviour.
    CVar_AddUI("Server", "sv_slidingcrouch",             "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Grappling hook (WEAPON_IMPULSE_GRAPPLE).  Disabled by default;
    // server admin opts in.  Tuning knobs follow.
    CVar_AddUI("Server", "sv_grappling",                 "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_launch_speed",    "900",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_pull_force",      "1400",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_pull_max_speed",  "900",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_release_dist",    "48",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_pull_delay",      "0.15",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Seconds between re-emissions of grapplingpull.wav.  Set this to
    // the exact wav length for a seamless loop; over-shoot leaves
    // brief silence between iterations.
    CVar_AddUI("Server", "sv_grappling_loop_interval",   "0.70",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // One-shot upward velocity stamped on the player when the hook
    // anchors AND they're currently on the ground.  Has to exceed
    // PM_CategorizePosition's `pm_velocity_z > 180` cutoff or the
    // ground-snap trace re-grabs them and the per-tick pull can't get
    // them airborne.  Default matches the standard jump impulse.
    CVar_AddUI("Server", "sv_grappling_attach_lift",     "270",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_grappling_max_life",        "5",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // CoD-style ladders: when 1, climbing a ladder drops the viewmodel
    // off-screen (via the cl_viewfx lower envelope) AND disables firing
    // (via Weapon_LowerBlocksFire).  Server-authoritative so a fire
    // gate can't be bypassed by a client cvar.  Replicated through the
    // serverinfo push in SV_UpdateMovementServerInfo so CSQC reads it
    // via PM_ReadMovevar regardless of listen/remote.
    CVar_AddUI("Server", "sv_codladders",                "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // CoD-style scopes: when 1, scout / awp swap the CS 1.6 stage-
    // cycle zoom for a CoD-style hold-ADS scope-in sequence:
    //   press +attack2  →  gun raises (ADS envelope)
    //                  →  quick fade to black
    //                  →  unfade + scope overlay rises (ease-out)
    //                  →  fully scoped while held
    //   release +attack2 →  quick fade to black + overlay lowers
    //                  →  unfade as gun lowers
    // Server-authoritative so a client can't cheat their way into a
    // tighter ADS spread on scout / awp.  Replicated via serverinfo
    // and read by cl_codscope.qc / cl_viewfx.qc / Weapon_HasScope /
    // Weapon_IsADSActive / SH_ScoutTryAltFire / SH_AWPTryAltFire via
    // PM_ReadMovevar.
    CVar_AddUI("Server", "sv_codscopes",                 "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Scoped FOV in degrees for the CoD scope path (cl_codscope.qc).
    // Replaces the hardcoded ZOOM_FOV_STAGE2 (12°).  0 falls back to
    // 12 — keep above 5 to avoid the engine clamping into a weird
    // micro-zoom.
    CVar_AddUI("Server", "sv_codscope_fov",              "12",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // sv_codstamina: enable a sprint / hold-breath stamina pool that
    // depletes during sprint (~4.5 s of sprinting), depletes during
    // hold-breath while scoped (~8 s), and refills otherwise.  When
    // depleted the player can't re-engage the corresponding action
    // until the bar refills to a threshold — sprint locks out sprint
    // (red bar), hold-breath locks out breath-hold + applies a
    // heavy-breathing punish (full-amplitude breathing sway,
    // red bar).
    CVar_AddUI("Server", "sv_codstamina",                "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // cl_codstamina_bar: stamina bar opacity multiplier (0..1).
    //   0   = bar hidden
    //   0.7 = ~70 % opaque (slightly faded)
    //   1.0 = fully opaque
    // Client-only so each player picks their own visibility even on
    // a server that has stamina enabled.  Replaces the old
    // sv_codstamina_bar (0/1) toggle.
    CVar_Add("Client", "cl_codstamina_bar",             "0.8",    CVAR_SIDE_CL);
    // Grace window (seconds) for the sprint drain — pmove single-
    // frame FL_ONGROUND drops on clip-brush stairs no longer pause
    // the drain inside this window.  Mirrors the cl_viewfx ground
    // grace pattern but uses absolute `time` so SSQC + CSQC agree
    // across reconcile-replay.
    CVar_Add("Server", "sv_codstamina_ground_grace",    "0.1",    CVAR_SIDE_SV);
    // Fraction of the pool a single jump costs.  Default 0.10 = 10
    // jumps to fully deplete from full if nothing else is running.
    CVar_Add("Server", "sv_codstamina_jump_cost",       "0.20",   CVAR_SIDE_SV);
    // Jump-height multiplier applied while codstamina_punished is
    // set.  Default 0.5 = half height.  Composes with the existing
    // CS 1.6 pm_fuser2 stamina taper.
    CVar_Add("Server", "sv_codstamina_punish_jump_scale","0.55",   CVAR_SIDE_SV);
    // CoD-stamina single-tick landing speed cost (replaces the CS 1.6
    // pm_fuser2 horizontal taper). 0.15 = lose 15% of horizontal velocity
    // on touchdown; applied once per landing edge in sh_pmove.qc.
    CVar_Add("Server", "sv_codstamina_land_cost",       "0.15",   CVAR_SIDE_SV);
    // Post-fire scope-suppression window (seconds).  Set on the
    // player entity as pm_fire_suppress_until when SH_StandardTryFire
    // succeeds; gates the pmove stamina drain (st_scope = 0 while
    // suppressed), the cl_viewfx ADS envelope (target = 0), and the
    // CoD scope state machine's OFF→RAISING re-entry.  When the
    // window expires with +attack2 still held, the scope auto-re-
    // engages — the "return to ADS scoping in after the shot is
    // complete" behaviour.  Tune to match the weapon's recoil
    // recover time (~0.4 s for scout / awp burst-fire cadence).
    CVar_Add("Server", "sv_codstamina_fire_suppress_time","0.4",  CVAR_SIDE_SV);
    // Punish-sway amplification scale (client) and fade.  punish_scale
    // = 10 → 10× normal scope sway amplitude at peak punish.  fade is
    // the EMA time constant for the onset (faster ramp-up than the
    // breath envelope so the punish hits hard).  Ramp-DOWN is tied
    // to the stamina refill in cl_codscope.qc — not driven by this
    // cvar.
    CVar_Add("Client", "cl_codscope_sway_punish_scale", "10.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_punish_fade",  "1.0",    CVAR_SIDE_CL);  // EMA time-constant for punish onset
    // Per-scope fog tweak — base fog now comes from the worldspawn
    // "fog" key ("density r g b [a [bias]]"), pushed to clients via
    // `serverinfo sv_worldfog` from worldspawn(). cl_codscope.qc adds
    // +1 to the bias slot while the player is scoped (CoD/CS style).
    // No fog key on the map = scope fog hookup is skipped entirely.
    // ADS — multiplicative scale on SH_GetSpreadScale when the
    // local player is actively aiming.  < 1 tightens hit spread.
    // Pushed to clients via serverinfo so CSQC prediction sees the
    // same value the server enforces.
    CVar_AddUI("Server", "sv_ads_spread_mult",           "0.35",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_eye_height",                "56",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_hull_height",               "72",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_MOVE, "Hull Height",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 32, 128);
    CVar_AddUI("Server", "sv_minpitch",                  "-90",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_maxpitch",                  "90",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Per-tick rate (Hz) for func_door_rotating's carry / block-
    // check think.  Higher = smoother player-with-door sweep and
    // earlier block detection at higher server CPU cost.  Range
    // is clamped to (0, 200] in sv_doors.qc; default 64 matches
    // CS-style hitbox / mover tickrates.  Render-side smoothing of
    // the door is in lockstep with this rate by default — see
    // cl_brushsync_lookahead for the forward-extrapolation budget.
    CVar_Add("Server", "sv_func_tickrate",         "64",            CVAR_SIDE_SV);

    // Debug trace for door / mover wedge handling.  When 1, each
    // tick prints: the brush's look-ahead origin (where it WILL be
    // after this tick's engine integration), whether any player's
    // bbox would intersect that future position, whether .blocked
    // applied damage, and which branch (slide / damage / reverse /
    // UNBLOCKABLE) the .blocked callback took.  Helps diagnose
    // "door doesn't stop / doesn't damage" symptoms — read the
    // server console while a player walks into the closing door.
    CVar_Add("Server", "sv_debug_doors",           "0",             CVAR_SIDE_SV);

    // ---------- func_vehicle drive feel ----------
    // Weighty/semi-sim driving for func_vehicle.  All live-tunable.  The drive
    // model runs at sv_func_tickrate (above).  See server/sv_func_vehicle.qc.
    CVar_Add("Server", "sv_vehicle_accel",         "700",           CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // ease-out accel (u/s^2 at standstill)
    CVar_Add("Server", "sv_vehicle_brake",         "1400",          CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // active brake decel (u/s^2)
    CVar_Add("Server", "sv_vehicle_decel",         "220",           CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // engine-brake when no throttle (~CS 200u/s/s)
    CVar_Add("Server", "sv_vehicle_reverse_frac",  "0.35",          CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // reverse cap as fraction of max speed
    CVar_Add("Server", "sv_vehicle_steer_rate",    "3.0",           CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // how fast the wheel turns toward target (per s)
    CVar_Add("Server", "sv_vehicle_steer_return",  "4.0",           CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // wheel self-center rate when released (per s)
    CVar_Add("Server", "sv_vehicle_max_yaw",       "180",           CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // max yaw rate (deg/s) at ideal speed
    CVar_Add("Server", "sv_vehicle_ground_follow", "1",             CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // 1 = terrain physics (ramps + pitch + gravity/air); 0 = flat drive
    CVar_Add("Server", "sv_vehicle_pitch",         "1",             CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // deck pitch on ramps (deg per deg of slope); flip sign if nose tilts wrong; 0 = no pitch
    CVar_Add("Server", "sv_vehicle_shotnudge",     "12",            CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // units a func_vehicle is shoved per shot (along the shot, into clear space) — shoot a stuck car free
    CVar_Add("Server", "sv_vehicle_step",          "18",            CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // max step/curb height (units) a vehicle drives up without it counting as a wall (stairs)
    CVar_Add("Server", "sv_vehicle_suspension",    "28",            CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // suspension travel (units): beyond this above the ground the car free-falls under gravity
    CVar_Add("Server", "sv_vehicle_wallcollide",   "1",             CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // 1 = oriented corner wall collision (stop/slide at walls); 0 = drive through walls
    CVar_Add("Client", "cl_vehicle_seatlock",      "1",             CVAR_SIDE_CL); // 1 = lock the driver's camera to the car's smooth visual position (kills carry jitter); 0 = off
    CVar_Add("Server", "sv_debug_func_vehicle",    "0",             CVAR_SIDE_SV | CVAR_FLAG_SAVE_TO_SERVER_CFG); // mount/dismount + drive prints

    // Player spray system.
    //   cl_spray           — basename of the player's chosen PNG in gfx/sprays/.
    //                        Picked via the main-menu Sprays panel; also pushed
    //                        to the server as the `_spray` userinfo key (via
    //                        setinfo) so SV_PlayerSpray can read it back.
    //   sv_sprayfrequency  — minimum seconds between two sprays from the same
    //                        player.  Enforced in SV_PlayerSpray via
    //                        self.spray_last_time + frequency vs time.
    //   sv_spraymax        — per-player FIFO cap on active sprays.  When the
    //                        cap is reached the oldest spray is multicast as
    //                        a REMOVE event before the new one spawns.  Hard
    //                        upper bound of 16 enforced server-side.
    CVar_Add("Client", "cl_spray",                 "nospray",       CVAR_SIDE_CL);
    //   r_spray_renderer — standardised with r_bullethole_renderer / r_decal_renderer:
    //     1 = tri-soup quad (default) — cheap, no edge clipping; the spray clips into
    //         mid-air at brush corners but renders from either side regardless of which
    //         way the wall faces.  Works for any PNG without a shader entry.
    //     0 = adddecal() — engine BSP-wrapping decal (matches scorch / bullet holes,
    //         survives stair-steps and corners), one adddecal() call per spray per frame.
    //         REQUIRES a shader script entry per PNG (scripts/effects.shader near
    //         `gfx/sprays/nospray.png`); without one the spray is invisible.
    //   Polled per-frame at draw, so toggling re-renders existing sprays LIVE (both
    //   representations are stored at placement; the draw dispatcher picks one).
    // r_spray_renderer REMOVED — unified into r_decal_renderer.
    // r_spray_offset REMOVED — unified into r_decal_offset.
    CVar_Add("Server", "sv_sprayfrequency",        "10",            CVAR_SIDE_SV);
    CVar_Add("Server", "sv_spraymax",              "3",             CVAR_SIDE_SV);
    // --- Player body paint (sv_paint.qc / cl_paint.qc) ---
    // CAMO: hold +camo (alias -> impulse 21/22, default.cfg) aiming at a wall;
    // your skin fills with THAT WALL'S texture over sv_camo_time seconds —
    // stand against it to blend in.  Damage scrubs sv_camo_damage_loss per hit;
    // respawn clears.  SPLATS: paintball hits paint the victim (no cvar; rides
    // cl_paint).  cl_paint 0 disables all client-side skin painting/uploads.
    CVar_Add("Server", "sv_camo_enable",           "1",             CVAR_SIDE_SV);
    CVar_Add("Server", "sv_camo_time",             "2.5",           CVAR_SIDE_SV);  // seconds of holding +camo to reach full coverage
    CVar_Add("Server", "sv_camo_range",            "96",            CVAR_SIDE_SV);  // max distance (qu) to the wall being copied
    CVar_Add("Server", "sv_camo_damage_loss",      "0.35",          CVAR_SIDE_SV);  // coverage scrubbed off per hit taken
    CVar_Add("Client", "cl_paint",                 "1",             CVAR_SIDE_CL);
    // Global multiplier on every infodecal's size (final size = entity "scale" key * this).
    CVar_Add("Client", "cl_infodecal_scale",       "1.0",           CVAR_SIDE_CL);
    // UNIFIED decal renderer — ONE cvar for ALL decal systems (bullet holes, sprays, infodecals, blood).
    // Polled per-frame at draw, so toggling re-renders everything LIVE:
    //   2 = PERSISTENT LIT (default) — clip ONCE + cache in the engine, re-emit cheaply every frame, keeps
    //       the per-pixel lightmap (fastest; engine Patch 79 adddecal_static).  Blood joins here too.
    //   1 = tri-soup projector — surface-clipped baked quad, no per-pixel lightmap.
    //   0 = engine adddecal() — wraps convex world edges, re-projected per frame (slowest).  Blood has no
    //       adddecal path, so mode 0 leaves blood on tri-soup.
    CVar_Add("Client", "r_decal_renderer",         "2",             CVAR_SIDE_CL);
    // UNIFIED off-surface lift (qu) of a TRI-SOUP decal (mode 1) for ALL decal systems — one cvar (was
    // r_bullethole_offset / r_spray_offset / r_decal_offset).  Mode 2 (persistent, default) ignores it and
    // uses the shader's polygonoffset 8, so this only matters in mode 1.  Live: re-shifts existing quads.
    CVar_Add("Client", "r_decal_offset",           "0.4",           CVAR_SIDE_CL);
    // ===== DECAL CVARS — quick reference =====================================
    //  r_decal_renderer  = THE renderer for ALL decals (bullet holes + sprays + infodecals + blood):
    //                      2 persistent-lit (default) / 1 tri-soup / 0 adddecal.  (Was 3 separate cvars.)
    //  r_decal_offset    = tri-soup (mode 1) off-surface lift for ALL decals.  (Was 3 separate cvars.)
    //  GLOBAL:
    //    r_decal_lightmap     per-pixel surface lightmap (persistent + adddecal paths; blood follows it too)
    //    cl_decal_surflight   1 = tint by surface light (getlight) / 0 = full-bright
    //    cl_decal_lightscale  surface-tint brightness scale
    //  PER-TYPE extras: cl_bulletholes* + cl_decal_opacity (BH alpha); cl_spray (image); cl_infodecal_scale;
    //    cl_blood_decals* + cl_blood_decals_brightness (blood tint).
    // =========================================================================
    // 1 (default) = bullet holes + sprays sample the surface lightmap brightness at
    // placement (getlight, scaled by cl_decal_lightscale) so they dim/brighten with the
    // surface, like infodecals.  0 = legacy full-bright.  (Per-pixel gradient = the
    // engine r_decal_lightmap on the adddecal path.)
    CVar_Add("Client", "cl_decal_surflight",       "1",             CVAR_SIDE_CL);
    // Scales the surface-light tint sample (getlight * this/255) for all decals.  ~1.5
    // ≈ the lightmap overbright getlight() omits; lower if decals look too bright.
    CVar_Add("Client", "cl_decal_lightscale",      "1.5",           CVAR_SIDE_CL);

    CVar_AddUI("Server", "sv_autohop",                   "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Autohop",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // sv_deastrafing: replicate the undocumented Source 1/2 airstrafe penalty
    // (absent in GoldSrc/CS1.6) — while airborne and rising slowly (0<vz<=140),
    // air acceleration is cut to 25%.  1 = Source-accurate (default), 0 = full
    // GoldSrc-style airstrafe.  Networked to all clients via serverinfo so
    // prediction matches; toggling live updates everyone with no reconnect.
    CVar_AddUI("Server", "sv_deastrafing",               "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "De-Astrafing (Source airstrafe)",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // sv_jumpstyle: 0 = GoldSrc-strict (must release jump while standing on
    // ground before the next +jump counts — kills the press-at-landing
    // buffer trick), 1 = Source/lenient (current default; allows the buffer
    // and matches CS:S/CS:GO feel).  Autohop overrides this when on.
    CVar_AddUI("Server", "sv_jumpstyle",                 "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Jump Style (0=GoldSrc, 1=Source)",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 1);
    CVar_AddUI("Server", "sv_stamina",                   "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Stamina",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_snipersway",                "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // sv_gunkick — server-authoritative + client-predicted view-kick
    // recoil. Spring-damped per-shot pitch + yaw impulses on the
    // player's view; bullets follow the kicked aim. Per-weapon
    // KICK_PITCH / KICK_VARIANCE constants live in
    // shared/weapons/sh_wpn_*.qc. Read on every fire by
    // SH_ApplyViewKick (sh_weapon_logic.qc) and every pmove tick by
    // SH_TickViewKickDecay.
    CVar_AddUI("Server", "sv_gunkick",                   "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "Gun-kick recoil",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_gunkick_strength",          "10",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Gun-kick strength",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 50);
    CVar_AddUI("Server", "sv_gunkick_decay_rate",        "25",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Gun-kick spring K",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 100);
    CVar_AddUI("Server", "sv_gunkick_damping",           "10",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Gun-kick damping",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 30);
    // sv_gunkick_instant: 0 (default) = velocity-impulse arch — the
    // shot adds upward velocity, spring smooths it into a rise+fall
    // arch.  1 = displacement-impulse — the kick is set to its peak
    // immediately on the firing tick (no rise phase) so the view only
    // ever decays downward from there.
    CVar_AddUI("Server", "sv_gunkick_instant",           "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "Gun-kick instant peak",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_headkick",                  "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "Damage view punch",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_headkick_strength",         "0.12",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Damage pitch per HP",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 1);
    CVar_AddUI("Server", "sv_headkick_max",              "8",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Damage pitch max",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 30);
    CVar_AddUI("Server", "sv_headkick_fall_roll_strength", "0.18", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Fall roll per HP",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 1);
    CVar_AddUI("Server", "sv_headkick_fall_roll_max",    "14",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Fall roll max",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 45);
    CVar_AddUI("Server", "sv_headkick_return_rate",      "24",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "Damage view return",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 80);
    CVar_AddUI("Server", "sv_lagcomp",                   "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_lagcomp_maxrewind",         "1.0",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // sv_trust_clienthits: 0/1/2 — scalar so the panel exposes mode 2.
    CVar_AddUI("Server", "sv_trust_clienthits",          "1",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Trust Client Hits",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2);
    // 0 = paintball is hitscan (legacy). 1 = paintball fires a small
    // colourful projectile (gravity + drag) instead. The projectile is
    // CSQC-predicted on the shooter and reports player hits via
    // `cmd paintprojhit` so sv_trust_clienthits can use the shooter's
    // local projectile path for damage. Server still spawns a mirror
    // projectile for remote-viewer visuals + fallback damage when
    // trust mode is off. See sh_wpn_paintball.qc for tuning constants.
    CVar_AddUI("Server", "sv_paintball_projectile",      "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Paintball projectile mode",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Trust the client's predicted damage to func_breakable brushes —
    // when ON, client emits `cmd breakclaim` per damaging shot and server
    // applies that damage; when OFF (default), server-auth via its own
    // hitscan trace as today.  Mirrors sv_trust_clienthits.
    CVar_AddUI("Server", "sv_trust_clientbreak",         "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "Trust Client Breakable Hits",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_hitbox_expand",             "32",    CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Pose-refresh keepalive interval in server ticks (1 = every tick).
    // Read by sv_main.qc / sv_player.qc. Registered here so it exists at
    // table-init time instead of being auto-created on first cvar() read.
    CVar_Add("Server", "sv_pose_keepalive_ticks",        "1",      CVAR_SIDE_SV);
    CVar_AddUI("Server", "sv_anim_qu_per_sec",           "240",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_anim_qu_per_sec_crouch",    "100",    CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_command_continuation",      "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_anim_resend_ticks",         "1",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_wepswap_speed_transition",  "0.15",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_player_basebone",           "0",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Default loadout dropdowns — enum sources delegate to WeaponManifest
    // in each consumer.  Saved so admin loadout choices persist.
    CVar_AddUI("Server", "sv_default_primary",           "0",      CVAR_SIDE_SV,
        CVAR_UI_ENUM, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "Default Primary",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_LOADOUT_PRIMARY, 0, 0);
    CVar_AddUI("Server", "sv_default_secondary",         "28",     CVAR_SIDE_SV,
        CVAR_UI_ENUM, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "Default Secondary",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_LOADOUT_SECONDARY, 0, 0);
    CVar_AddUI("Server", "sv_default_melee",             "20",     CVAR_SIDE_SV,
        CVAR_UI_ENUM, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "Default Melee",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_LOADOUT_MELEE, 0, 0);
    CVar_AddUI("Server", "sv_default_utility",           "0",      CVAR_SIDE_SV,
        CVAR_UI_ENUM_MULTI, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "Default Utility",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_LOADOUT_UTILITY, 0, 0);
    // Internal stash for the menu's offline rcon password recall.  No UI.
    CVar_Add("Server", "sv_rcon_password_shadow",      "",         CVAR_SIDE_SV);
    // Admin-trigger cvars: self-resetting in StartFrame; never persisted.
    CVar_AddUI("Server", "sv_roundrestart",              "0",      CVAR_SIDE_SV,
        CVAR_UI_ACTION, CVAR_TAB_RCON, "Restart Round",
        CVAR_FLAG_NO_LOCAL_FALLBACK, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_saveconfig",                "0",      CVAR_SIDE_SV,
        CVAR_UI_ACTION, CVAR_TAB_RCON, "Save Config",
        CVAR_FLAG_NO_LOCAL_FALLBACK, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_writecvars",                "0",      CVAR_SIDE_SV,
        CVAR_UI_ACTION, CVAR_TAB_SERVER, "Write AllCommand",
        CVAR_FLAG_NO_LOCAL_FALLBACK, CVAR_ENUM_NONE, 0, 0);
    // sv_backdrop is a transient runtime flag, NOT a persisted config.
    // It's "1" while the menu's listen-server is running as a render
    // backdrop and "0" for any real game (set explicitly by
    // create_server_launch's localcmd before `map`).  Persisting it to
    // server.cfg would make every Create-Server launch start with
    // sv_backdrop=1 (because the writer captures the live value while
    // the menu backdrop is still up), which suppresses HUD +
    // team-select on the new server.  No SAVE flag — flag stays out of
    // server.cfg.
    CVar_AddUI("Server", "sv_backdrop",                  "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        0, CVAR_ENUM_NONE, 0, 0);
    // Send rate (Hz) for in-flight items: dropped weapons during the
    // toss/settle window AND server-replicated projectiles. Higher = smoother
    // visible flight at small bandwidth cost. Pushed to serverinfo so CSQC
    // can read it (Toss_NextThinkInterval mirrors). Clamped 5..100 in code.
    CVar_AddUI("Server", "sv_toss_tickrate",             "64",     CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_RCON, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 5, 100);
    // Lower-rate replication for map/round-start weapon spawn settling.
    // Player drops and projectiles still use sv_toss_tickrate.
    CVar_AddUI("Server", "sv_roundtoss_tickrate",        "20",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_RCON, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_NONE, 1, 100);
    CVar_AddUI("Server", "sv_ode_loaded",                "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        0, CVAR_ENUM_NONE, 0, 0);
    // Engine-pre-registered cvars (FTE registers these; we restate their
    // defaults so the cfg captures the mod's intended values and
    // CVar_ForceDefaults can rescue them after cfg/server.cfg exec).
    CVar_AddUI("Server", "sv_antilag",                   "3",      CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 3);
    CVar_AddUI("Server", "sv_bigcoords",                 "1",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server", "sv_nqplayerphysics",           "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Tickrate selector — ENUM kind, sv_mintic stores seconds-per-tick
    // (the panel converts via CVAR_ENUM_TICKRATE values).
    CVar_AddUI("Server", "sv_mintic",                    "0.015625", CVAR_SIDE_SV,
        CVAR_UI_ENUM, CVAR_TAB_RCON | CVAR_TAB_CREATE_GAME, "Tickrate",
        CVAR_FLAG_SAVE_TO_SERVER_CFG | CVAR_FLAG_NO_LOCAL_FALLBACK,
        CVAR_ENUM_TICKRATE, 0, 0);
    // Sister cvar — engine clamps each physics frame's dt into
    // [sv_mintic, sv_maxtic]. Pinning sv_maxtic == sv_mintic gives a
    // fixed-step physics loop (no jitter under load). Setting it higher
    // lets the server's catch-up loop run a longer dt per tick if a
    // frame stalls. Persisted so admins can tune the catch-up budget.
    CVar_AddUI("Server", "sv_maxtic",                    "0.015625", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // ---------- Server debug ----------
    // All routed to F2 panel DEBUG tab.  Not persisted.
    CVar_AddUI("Server debug", "sv_debug_clienthits",   "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // Verbose server-side hitclaim trace — every cmd hitclaim received,
    // every accept/reject reason, and the resolved hitgroup + damage.
    // Pairs with cl_debug_hitclaim on the client.  Registered with
    // plain CVar_Add so the engine sees a cvar at launch even before
    // the debug-UI builder runs (so `+set sv_debug_hitclaim 1` on
    // the command line works).
    CVar_Add("Server", "sv_debug_hitclaim",            "0", CVAR_SIDE_SV);
    // Per-client flood cap (msgs/sec) for the hit-reporting stringcmds
    // (hitclaim/breakclaim/paintprojhit/snowprojhit/cs).  The engine has no
    // stringcmd flood protection, so this bounds spam toward a reliable-backbuf
    // overflow.  60 is well above the ~26-30/s legit peak (a `cs` per shot + a
    // `hitclaim` per hit on a sustained-fire SMG); 0 disables.  See
    // SV_ClaimFloodOK in sv_player.qc.
    CVar_Add("Server", "sv_claim_flood_max",           "60", CVAR_SIDE_SV);
    CVar_AddUI("Server debug", "sv_debug_hitclaim",     "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_lagcomp",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_camera",       "0", CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // sv_debug_hitboxes is 0/1/2 — scalar so all three modes are reachable.
    CVar_AddUI("Server debug", "sv_debug_hitboxes",     "0", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 2);
    CVar_AddUI("Server debug", "sv_debug_blendfracs",   "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_noblock",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_continuation", "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // Registered on BOTH so the client menu can discover them too.
    CVar_AddUI("Server debug", "sv_debug_ent_types",    "0", CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_pickups",      "0", CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // Print +use trace hits and the trigger chain that fires:
    //   "[+use] <player> -> classname=... target=... master=..."
    //   "[chain] <caller> -> <target> useType=..."  (one per link)
    CVar_AddUI("Server debug", "sv_debug_use",          "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // Print func_conveyor bbox + per-player overlap / groundentity match
    // each tick — diagnoses why a particular conveyor isn't pushing
    // (e.g. degenerate bounds from a NULL-textured brushmodel).
    CVar_AddUI("Server debug", "sv_debug_conveyor",     "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_func_train",   "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // +use ignores forward wall hits and resolves purely via the cone
    // scan — lets mappers place buttons behind windows/grates and
    // still have them activate from the room.
    CVar_AddUI("Server", "sv_use_through_walls",        "1", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_footsteps",    "0", CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_physprops",    "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    // env_beam endpoint/target resolution + path_corner chain walking.
    CVar_AddUI("Server debug", "sv_debug_env_beam",     "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_spray",        "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_spawns",       "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_weapons",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_wepswap",      "0", CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);

    // ---------- ODE physics ----------
    CVar_AddUI("ODE physics", "physics_ode_autodisable",        "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE AutoDisable",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Source-like smoothness: more substeps/frame (was 2), a small contact-overlap
    // layer (the big anti-jitter knob), and a stiffer QuickStep solve.
    CVar_AddUI("ODE physics", "physics_ode_iterationsperframe", "8", CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE Iter",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 60);
    CVar_AddUI("ODE physics", "physics_ode_contactsurfacelayer", "0.15", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE Contact Layer",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("ODE physics", "physics_ode_worldquickstep",     "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE QuickStep",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("ODE physics", "physics_ode_worldquickstep_iterations", "40", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE QuickStep Iter",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 200);
    // Patch 65-68: prop collision + ODE sim shape, server.cfg-editable. sv_prop_collision/_decomp
    // build the player-collision geometry at model load (SERVERINFO, engine-owned); physics_ode_*
    // pick the ODE rigid-body shape (1=low-poly hull default, use_decomp 1=concave soup) + the
    // settled-prop dCollide skip. The engine/plugin own the real cvars; these rows just register the
    // defaults + emit them to server.cfg so admins can tune them per server start.
    CVar_AddSaved("ODE physics", "sv_prop_collision",             "3",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_prop_decomp",                "2",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_prop_decomp_concavity",      "0.06",CVAR_SIDE_SV);  // runtime-ACD (sv_prop_decomp 1) concavity threshold, fraction of model extent (clamped 0.01-0.5)
    // Engine Patch 102: model-path prefixes that skip collision-hull + ACD construction at LOAD.
    // These are pure load-time waste for models that are never SOLID_PHYSICS_* props:
    //   models/player/  - highly concave, thousands of verts -> pays the FULL recursive ACD for nothing
    //   models/gibs/    - 122 debris models, bounce-boxed, never prop-collided
    //   models/nature/grass|fern|wheat - prop_detail, i.e. already SOLID_NOT, yet grass_2/grass_3/
    //     fern_1/wheat_1 each carried THIRTY-TWO convex pieces the engine built and never used.
    // Prefix match (Q_strncasecmp in Mod_SkipCollisionHulls), so "models/nature/grass" catches
    // grass_2.iqm etc. stone/tree/tree_log/tree_stump/mushroom deliberately NOT listed - they stay
    // collidable. A listed model used as a prop anyway degrades to the normal alias trace (the hull
    // trace is gated on numhullplanes>=4), so this can't punch holes in the world.
    // Read at model LOAD -> reload the map to apply.
    // NOTE the value below is NOT what takes effect -- the real default lives in the ENGINE
    // (gl_model.c mod_prop_hull_exclude), because this table's registercvar() is a documented no-op
    // for cvars the engine already registered, and Mod_Init registers this one long before QC runs.
    // This row exists so the value is VISIBLE and editable in server.cfg; keep the two in sync.
    CVar_AddSaved("ODE physics", "sv_prop_hull_exclude",
                  "models/player/;models/gibs/;models/nature/grass;models/nature/fern;models/nature/wheat",
                  CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_trimesh_from_hull", "1",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_use_decomp",        "0",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_restingskip",       "1",   CVAR_SIDE_SV);
    // The remaining ODE solver / contact / auto-disable knobs, exposed at the plugin's own defaults
    // (the plugin owns the live cvars; these rows just emit them to server.cfg for admins). Most
    // should stay default: lowering movelimit/iterations -> tunneling, raising contact_erp ->
    // instability; world_* -1 = "use ODE built-in". Tune at your own risk.
    CVar_AddSaved("ODE physics", "physics_ode_movelimit",                      "0.5",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_spinlimit",                      "10000", CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_maxspeed",                       "0",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_quadtree_depth",                 "5",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_autodisable_steps",              "10",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_autodisable_time",               "0",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_autodisable_threshold_linear",   "0.2",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_autodisable_threshold_angular",  "0.3",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_autodisable_threshold_samples",  "5",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_contact_mu",                     "1",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_contact_erp",                    "0.96",  CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_contact_cfm",                    "0",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_damping",                  "1",     CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_damping_linear",           "-1",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_damping_linear_threshold", "-1",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_damping_angular",          "-1",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_damping_angular_threshold","-1",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_erp",                      "-1",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "physics_ode_world_cfm",                      "-1",    CVAR_SIDE_SV);
    CVar_AddUI("ODE physics", "sv_phys_drops",                  "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Whether dropped phys-weapons should collide with moving
    // brushwork (func_door / func_button).  Default ON — the
    // historical LCP-crash this gate was added for required FTE engine
    // updates that ship static-geom position sync per-frame.  Flip to
    // 0 if a phys-drop landing on a moving door triggers
    // dxNormalize4 / "s <= 0" errors on a dedicated server.
    CVar_AddUI("ODE physics", "sv_phys_drops_movers",           "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE, "Phys drops collide w/ movers",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Pre-physics + per-tick BSP unstick for phys-drops + phys props.
    // When ON (default), a tracebox-based search nudges any prop that
    // would start (or end up) inside BSP geometry to a clear nearby
    // position before ODE sees the penetration — prevents the violent
    // "fling out" that ODE's contact-recovery solver applies otherwise.
    // 0 = disabled (legacy behaviour, ODE handles penetration). Useful
    // for A/B testing whether the unstick helps a specific case.
    CVar_AddUI("ODE physics", "sv_phys_unstick",                "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE, "Phys Unstick",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // NOTE: the force code multiplies these by 100 now, so values are ~100x smaller
    // than before (128 here ≈ the old 12800).  See PhysProp_TryPushFromTrace.
    CVar_AddUI("ODE physics", "sv_physprop_hit_force",          "128", CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Hit Force",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2000);
    // Per-(damage × falloff) impulse magnitude applied by
    // PhysProp_TryRadiusPush when any explosion detonates near a phys
    // drop or prop.  Tuned in playtest — defaults that look reasonable
    // on paper (matching sv_physprop_hit_force scale) end up launching
    // props through the skybox because the radial spread compounds
    // with ODE's mass/damping.  512 keeps the blasts visceral but
    // controllable; bump higher for more chaos.  CVar_AddUI (not plain
    // CVar_Add) so it auto-saves to cfg/server.cfg and sits in the
    // physics tab next to Hit Force, its bullet-knockback sibling.
    CVar_AddUI("ODE physics", "sv_physprop_explosion_force",   "512", CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Explosion Force",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2000);  // ×100 in code (512 = old ~51200)
    CVar_AddUI("ODE physics", "sv_physprop_use_force",          "800", CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Use Force",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 100000);
    CVar_AddUI("ODE physics", "sv_physprop_use_velmult",        "800", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Use VelMult",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 10000);
    CVar_AddUI("ODE physics", "sv_physprop_mass",               "20",  CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Mass",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 1, 1000);
    CVar_AddUI("ODE physics", "sv_physprop_erp",                "0",   CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ERP",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("ODE physics", "sv_physprop_damp_lin",           "0.01", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Damp Lin",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("ODE physics", "sv_physprop_damp_ang",           "0.01", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Damp Ang",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("ODE physics", "sv_physprop_friction",           "1.0", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Friction",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_Add("ODE physics", "sv_physprop_flood_per_frame",      "1",   CVAR_SIDE_SV);  // spawnflood: props spawned per SERVER FRAME (1 = clean trickle + self-throttles to server health; raise for a faster dump)
    CVar_Add("ODE physics", "sv_physprop_stream_hz",            "64",   CVAR_SIDE_SV);  // free phys-prop CSQC mirror stream rate while MOVING (Hz). 8 = smooth + low bandwidth (client INTERPOLATES between snapshots). 0 = every tick (~64). Lower = cheaper big floods.
    CVar_Add("ODE physics", "sv_physprop_stream_instant",       "0",   CVAR_SIDE_SV);  // 1 = on interaction (shoot/explode/gravgun/+use/throw) jump the queue and push ONE mirror update on the next tick instead of waiting up to 1/stream_hz. Ongoing rate still capped by stream_hz.
    CVar_Add("ODE physics", "sv_physprop_flood_dist",           "200", CVAR_SIDE_SV);  // spawnflood: forward distance of the pile from the player (near edge = dist-144 clears the player hull so barrels don't spawn ON you).
    // Unified phys-object core (PhysObj_Setup / PhysObj_Think): per-object mass
    // overrides + shared bounce + shared sleep/wake thresholds. The barrel uses
    // sv_physprop_mass (20); the can + weapons get their own mass; sleep_* gate the
    // QC sleep/wake-at-rest for ALL free props (barrel/can/weapon drops).
    CVar_Add("ODE physics", "sv_physprop_can_mass",       "2",    CVAR_SIDE_SV);
    // Prop material+weight (scripts/propmaterials.txt, sh_propmaterials.qc): global weight
    // multiplier on the per-material density*volume mass for map prop_physics.  1 = as-authored.
    CVar_Add("ODE physics", "sv_propmat_mass_scale",      "1",  CVAR_SIDE_BOTH);
    CVar_Add("ODE physics", "sv_physprop_bounce",         "0",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_bouncestop",     "0.5",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_sleep_speed",    "8",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_sleep_angspeed", "30",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_sleep_delay",    "0.2",  CVAR_SIDE_SV);
    // Dropped weapons: a bit of heft + grippy (move when hit/blasted, settle quickly).
    CVar_Add("ODE physics", "sv_physprop_weapon_mass",     "5",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_weapon_friction", "0.5",  CVAR_SIDE_SV);

    // HL2-style carry (phys_files filing cabinet — see sv_physprop.qc Carry_*).
    // The carried prop is driven by a per-tick velocity servo toward a hold
    // point in front of the player; ODE resolves world collisions so it
    // slides on walls.  drop_dist + stuck_time together force a drop only when
    // the prop is genuinely wall-blocked (distance stays large), not on a fast
    // turn where it briefly lags then catches up.
    // Mass: a filing cabinet is heavy, but at 80 a bullet's impulse (force/mass)
    // was imperceptible — 40 keeps it heavier than a barrel (sv_physprop_mass 20)
    // while still visibly reacting to shots/explosions.  Raise sv_physprop_hit_force
    // too if you want even more kick.
    CVar_AddSaved("ODE physics", "sv_carry_mass",        "40",   CVAR_SIDE_SV);
    // Speed (qu/s) the prop is shoved horizontally OUT of a player it was dropped
    // overlapping, so it comes to rest in the clear (HL2 push-apart) before it
    // becomes solid to you.  See phys_files_think.
    CVar_AddSaved("ODE physics", "sv_carry_separate_speed", "140", CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_hold_dist",   "96",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_hold_z",      "4",    CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_max_speed",   "1000", CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_drop_dist",   "80",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_stuck_time",  "0.35", CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_wall_deadband","2",   CVAR_SIDE_SV);  // Patch 70: kill the into-wall carry servo within this many qu of a contacted wall so a held prop RESTS at the wall (no r_showhull jitter vs the visual)
    CVar_AddSaved("ODE physics", "sv_carry_grab_dist",   "96",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_grab_time",   "0.25", CVAR_SIDE_SV);  // pull-in animation duration on grab (0 = instant/snap)
    CVar_AddSaved("ODE physics", "sv_carry_throw_force", "300",  CVAR_SIDE_SV);  // throw speed (qu/s), velocity-set (+ player velocity)
    // Carried-prop ORIENTATION + inspect mode (hold the Reload key while carrying to
    // lock the view, rotate the prop with the mouse and scroll it nearer/further).
    // snap 1 = on grab, snap the prop's real pose to the nearest 90° pose that is
    // upright or upside-down (never on its side), measured relative to your view so it
    // presents a flat face to the camera.  0 = keep the raw grab pose (A/B).
    CVar_AddSaved("ODE physics", "sv_carry_rot_snap",     "1",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_rot_dropsnap", "0",   CVAR_SIDE_SV);  // 1 = re-snap to the nearest 90° pose on drop (escape hatch if free-angle drops annoy)
    CVar_AddSaved("ODE physics", "sv_carry_rot_maxrate",  "40",  CVAR_SIDE_SV);  // max accepted CSEv_carryrot_v rate (Hz) — this value reaches the physics body
    // Scroll offset bounds, ADDED to sv_carry_hold_dist (96).  CVAR_SIDE_BOTH, not SV:
    // CVar_RegisterMine only registers a side's own cvars, so an SV-only cvar reads back
    // as 0 in CSQC — which would collapse the client's scroll clamp to [0,0] and make the
    // wheel do nothing.  The server re-clamps authoritatively in CSEv_carryrot_vf; the
    // client copy only exists to bound local accumulation.
    CVar_AddSaved("ODE physics", "sv_carry_dist_min",     "-48", CVAR_SIDE_BOTH);
    CVar_AddSaved("ODE physics", "sv_carry_dist_max",     "120", CVAR_SIDE_BOTH);
    CVar_AddSaved("ODE physics", "sv_carry_dist_rate",    "220", CVAR_SIDE_SV);  // qu/s glide toward the scroll target — a raw STEP would spike the servo error into the instant force-drop
    CVar_Add     ("ODE physics", "cl_carry_rotate_speed", "0.35",CVAR_SIDE_CL);  // degrees of prop rotation per mouse count
    CVar_Add     ("ODE physics", "cl_carry_rotate_invert","0",   CVAR_SIDE_CL);
    CVar_Add     ("ODE physics", "cl_carry_dist_step",    "12",  CVAR_SIDE_CL);  // qu per wheel click
    CVar_Add     ("ODE physics", "cl_carry_rotate_sendrate","20",CVAR_SIDE_CL);  // upstream orientation sends per second while rotating
    // Prop Hunt disguise-rotate gestures (client/cl_prophunt_rotate.qc).  Both are
    // read with NO inline fallback, so while they went unregistered they read 0 —
    // holdtime 0 makes `(cltime - press_time) >= holdtime` true on the very first
    // down-frame, latching HOLD instantly and leaving the TAP (lock toggle) and
    // DOUBLE-TAP (reset upright) branches unreachable.  The gesture model in that
    // file's header only works with real values here.
    CVar_Add     ("ODE physics", "cl_prop_rotate_holdtime","0.25",CVAR_SIDE_CL);  // key held past this = HOLD free-rotate, not a tap
    CVar_Add     ("ODE physics", "cl_prop_rotate_taptime", "0.3", CVAR_SIDE_CL);  // second press within this of a release = DOUBLE-TAP reset
    // Client: when the LOCAL player carries a prop, the client PREDICTS its hold pose
    // from the local view (zero ping lag).  On drop/throw the predicted→authoritative
    // handoff eases over this time so it doesn't pop (0 = instant snap).
    CVar_Add("ODE physics", "cl_carry_smooth_time", "0.06", CVAR_SIDE_CL);
    // Static brightness multiplier on the carried prop (colormod). 1 = none;
    // ~0.7 ≈ the r_physdrops_maxlight 180/255 feel (uniform, not adaptive).
    CVar_AddSaved("ODE physics", "sv_carry_lightscale",  "0.7",  CVAR_SIDE_SV);
    // Gravity gun (shared/weapons/sh_wpn_gravitygun.qc).  grab_range = how far the
    // primary reaches to grab a prop (held at the normal sv_carry_hold_dist).
    // pull_dist = how far in front the black-hole gather point sits; radius = its
    // reach.  pull_accel = black-hole ACCELERATION (qu/s²) toward the point — the
    // force is scaled by each prop's mass so all weights accelerate the same
    // (uniform-gravity feel) while still arcing in naturally through ODE.
    // blast_speed = release fling VELOCITY outward; throw_speed = the +attack
    // throw velocity (more aggressive than the bare-hands +use heave).
    CVar_AddSaved("ODE physics", "sv_gravgun_grab_range", "600",  CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_gravgun_pull_dist",  "200",  CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_gravgun_radius",     "512",  CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_gravgun_pull_accel", "2500", CVAR_SIDE_SV);  // qu/s² toward the point (mass-scaled force)
    CVar_AddSaved("ODE physics", "sv_gravgun_blast_speed","700",  CVAR_SIDE_SV);  // release fling velocity outward
    CVar_AddSaved("ODE physics", "sv_gravgun_throw_speed","1200", CVAR_SIDE_SV);  // +attack throw velocity (aggressive)
    CVar_AddSaved("ODE physics", "sv_gravgun_rest_radius", "48",  CVAR_SIDE_SV);  // Patch 68: a gathered prop within this of the pull centre AND below rest_speed gets NO pull force, so ODE auto-disables it and the settled pile costs ~0 even while held. 0 = off.
    CVar_AddSaved("ODE physics", "sv_gravgun_rest_speed",  "40",  CVAR_SIDE_SV);  // Patch 68: speed (qu/s) below which a centred prop counts as settled for the rest deadzone above
    CVar_AddSaved("ODE physics", "sv_gravgun_ragdoll_pull_speed", "600", CVAR_SIDE_SV);  // black-hole (+attack2) pull-servo cap for corpse ragdolls (pelvis toward the gather point)
    // Source/HL2 entity-lump props (server/sv_props.qc). enable = master switch for
    // every prop_* classname; physics = ODE rigid bodies + +use carry (set 0 for
    // NON-COLLIDABLE visual-only props — lighter/stabler on prop-dense Source maps,
    // where every prop_physics is otherwise a live ODE body); default_halfsize = the
    // fallback collision half-extent when a GoldSrc/Source .mdl ships no usable bbox.
    CVar_Add("ODE physics", "sv_props_enable",           "1",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_props_physics",          "1",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_props_default_halfsize", "16", CVAR_SIDE_SV);
    // 1 = NON-SOLID decorative props (prop_detail: bushes/grass/scatter) get EF_NOSHADOW
    // at spawn, so they never enter the r_shadows-2 fake-sun depth pass (which re-renders
    // EVERY caster in the ortho box each frame with no PVS).  Cosmetic only — the sun N.L
    // shade term is independent of the shadow map, so they keep unlit-side shading and just
    // stop throwing a ground shadow.  Per-prop escapes: spawnflags 16 (Never Cast Shadow) /
    // 32 (Always Cast Shadow).  0 = every prop casts (the pre-optimisation behaviour).
    CVar_Add("ODE physics", "sv_props_foliage_noshadow", "1",  CVAR_SIDE_SV);
    // Phys-prop contact FX (impact sounds + smoke).  Impact speed (qu/s) drives
    // soft-vs-hard sound + smoke size; below _min_speed nothing fires (gentle taps).
    // _cooldown stops a tumbling/bouncing prop machine-gunning sounds.  _slide_* drive
    // the periodic dust puffs while a prop scrapes along a surface.
    CVar_Add("ODE physics", "sv_physprop_impact_min_speed",  "70",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_impact_hard_speed", "260",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_impact_cooldown",   "0.11", CVAR_SIDE_SV);
    // _slide_min_speed 35 (was 60): 60 only caught a prop still travelling fast, so most
    // real slides — a shoved crate settling, a dragged prop — never smoked at all.
    // _slide_interval 0.09 (was 0.18): ~11 puffs/s, in the same league as the car tailpipe's
    // 12/s idle, which is what makes the shared metal_impact effect actually read as a plume
    // rather than an occasional lone puff.  Each tick is one PVS-culled ~13-byte multicast.
    CVar_Add("ODE physics", "sv_physprop_slide_min_speed",   "35",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_slide_interval",    "0.09", CVAR_SIDE_SV);
    // 1 = scrape-loop volume TRACKS slide speed (re-issues the loop on a notable speed
    // change — restarts the sample, ~inaudible for a rough scrape; throttled+deadbanded).
    // 0 = volume fixed at the speed it had when the scrape started.
    CVar_Add("ODE physics", "sv_physprop_scrape_track",      "1",    CVAR_SIDE_SV);
    // Prop think sleep.  A prop that has held still for ~0.35s drops from the 64 Hz
    // PhysObj_Think to _sleep_hz — on a prop-dense map that think was the single biggest
    // server cost, re-scheduling itself 64x/s for props that had not moved in minutes.
    // Every QC-visible interaction (bullet / explosion / +use / throw / carry / gravgun)
    // wakes the prop the SAME tick via PhysProp_Wake; a contact QC cannot see (prop-on-prop,
    // a door shoving it — ODE gives QC no contact callback) is caught within 1/_sleep_hz.
    // Set _sleep 0 to restore the always-64 Hz behaviour.
    CVar_Add("ODE physics", "sv_physprop_sleep",             "1",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_sleep_hz",          "8",    CVAR_SIDE_SV);
    // BUOYANCY — props float on water, per MATERIAL density (propmaterials.txt).  A prop displaces its
    // bbox volume of water; whether it floats is pm_density vs _density below, so with the shipped table
    // wood/fabric/plastic/glass float and metal/rock sink with NO retuning.  Cost: a DRY SETTLED prop pays
    // ~5 float compares and zero builtins; the water surface is probed ONCE on entry and cached (world BSP
    // water is static); a prop settled at its float line stops being forced entirely so the rigid body
    // still autodisables.  NOTE this floats props on BAKED BSP water only — pointcontents is worldmodel
    // -only, so func_water brush entities float nothing.  0 = off (props sink as before).
    CVar_Add("ODE physics", "sv_prop_buoyancy",              "1",    CVAR_SIDE_SV);
    // Density of water in the same arbitrary scale as pm_density (propmaterials.txt). Raise to float more
    // materials (>1.30 floats even metal), lower to sink more. 1.0 puts the line between glass and rock.
    CVar_Add("ODE physics", "sv_prop_buoyancy_density",      "1.0",  CVAR_SIDE_SV);
    // Fluid damping, expressed as the DAMPING RATIO of the heave spring (the classic zeta), not as a
    // raw coefficient.  Buoy_Tick derives the actual drag from the prop's own natural frequency, so this
    // one number means the same thing on a matchbox and on a shipping crate: they settle in the same
    // NUMBER OF BOBS regardless of size or material.  1.0 = critically damped (sinks to the line and
    // stops dead), 0.4 = a few visible bobs, 0.1 = wallows.  This replaced sv_prop_buoyancy_drag, which
    // was a fixed coefficient: that made the real ratio scale as density*sqrt(height), so a small light
    // prop landed near 0.07 and bounced in and out of the water indefinitely ("like a frog") while a big
    // crate at 0.20 looked passable.  See Buoy_Tick for the derivation.
    CVar_Add("ODE physics", "sv_prop_buoyancy_damping",      "0.4",  CVAR_SIDE_SV);
    // Player RIDER CARRY on physics props — stand on a drifting crate or a floating raft and move with
    // it.  Named for the DISABLE case on purpose: it is read inside the shared pmove via PM_ReadMovevar,
    // which falls back to its default whenever the serverinfo value reads 0, so a default-ON toggle
    // could never be switched off.  Keeping the default at zero makes both states read correctly on the
    // client.  Set 1 to restore the old behaviour (the prop slides out from under you).
    CVar_Add("ODE physics", "sv_physprop_nocarry",           "0",    CVAR_SIDE_SV);
    // Clamp on the carry contact velocity (qu/s) — anti-fling, so a physics glitch that launches or
    // spins a prop cannot throw the rider across the map.
    CVar_Add("ODE physics", "sv_physprop_carry_maxspeed",    "400",  CVAR_SIDE_SV);
    // 1 = prop_physics / prop_car CSQC mirrors are PVS-culled AND removed on PVS exit, like
    // prop_static.  0 = legacy PVSF_NOREMOVE: once a client has seen the mirror it is never
    // removed, so props/cars linger frozen in the void (and a driven car leaks its client
    // wheel/driver entities).  The mirror is the client's only collision hull, so culling
    // means a prop just outside your (fat) PVS is not client-solid — the same trade
    // prop_static already makes.  Set 0 if that ever bites.  See PhysProp_ApplyPvsPolicy.
    CVar_Add("ODE physics", "sv_physprop_pvscull",           "1",    CVAR_SIDE_SV);

    // Weapon-drop SHAPE tunables (sv_physprop_weapon_*) — the ODE collision box +
    // hitscan trace-AABB for dropped guns.  Mass / friction / bounce / damping /
    // sleep are now the SHARED phys-object family (sv_physprop_*), applied in
    // PhysObj_Setup — only the weapon-specific COLLISION SHAPE lives here.
    // CVAR_SIDE_BOTH so the F2 panel (CSQC) sees the defaults via the local cvar()
    // fallback when the server hasn't pushed serverinfo for these knobs.
    // 0 = SOLID_PHYSICS_BOX (model $bbox — stable for GoldSrc .mdl, default).
    // 1 = SOLID_PHYSICS_TRIMESH (accurate rest on the mesh — good for IQM, can
    //     flicker / stick on GoldSrc meshes with gaps or duplicate verts).
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_geom",         "0",     CVAR_SIDE_BOTH,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Tight gun-shaped half-extents used as the ODE collision shape (so dropped
    // guns rest on their silhouette, not on AABB corners).  Set any axis to 0 to
    // fall back to the model's natural mins/maxs.
    // Gun-shaped (long X, thin Y, low Z) so a sliding gun stops at its silhouette,
    // not at a fat square box's edge ("phantom wall").  ODE rotates the box with the
    // tumbling body, so these are the gun's rest-pose half-extents.
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_bbox_x",       "12",    CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_bbox_y",       "5",     CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_bbox_z",       "3",     CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Inflated traceline-AABB half-extents wrapped around hitscan traces by
    // W_PhysDrops{Expand,Restore}TraceBboxes (mirrors the sv_hitbox_expand
    // playermodel pattern).  Must enclose the tight ODE box at any rotation.
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_trace_bbox_x", "32",    CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_trace_bbox_y", "32",    CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Drop Physics", "sv_physprop_weapon_trace_bbox_z", "32",    CVAR_SIDE_BOTH,
        CVAR_UI_SCALAR, CVAR_TAB_ODE, "", CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);

    // ---------- Player movement ----------
    CVar_AddUI("Player movement", "pm_ramp_bumpcount", "8", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_SERVER, "",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
};

// Cross-VM registercvar wrapper — the menu VM's registercvar takes a
// third `flags` argument, the CSQC/SSQC versions take only two.
// Wrap it here so the body of CVar_RegisterMine doesn't need an
// #ifdef per call.
//
// FTE's DP_REGISTERCVAR (SSQC/CSQC #93) creates a QC-readable cvar
// but doesn't reliably surface it in the engine's console-visible
// cvar table — typing the name in console produces "Unknown command"
// until some QC code calls cvar()/cvar_set on it.  Symptom users
// hit: `sv_debug_hitclaim` is "Unknown" at launch and only becomes
// available after the first hit (because W_ApplyDamage finally calls
// cvar() on it).  Force materialization with cvar_set when the cvar
// has no value yet — preserves +set on command line and any value
// already loaded from a cfg (cvar_string returns the existing value
// in those cases, so the gate skips the override).
void(string name, string def) CVar_DoRegister =
{
#ifdef MENU
    registercvar(name, def, 0);
#else
    registercvar(name, def);
#endif
    if (cvar_string(name) == "")
        cvar_set(name, def);
};

// Iterate the table and registercvar() the entries flagged for the
// current VM. Called once at CSQC_Init / worldspawn / Menu_Init.
//
// Per-VM side selection:
//   • CSQC  → CVAR_SIDE_CL
//   • SSQC  → CVAR_SIDE_SV
//   • Menu  → CVAR_SIDE_SV  — the menu only manages server cvars
//     (Create Server screen, server.cfg writer).  CL-side cvars are
//     CSQC's domain; auto-registering them here would create them in
//     the menu engine with the manifest's default and TURN ON things
//     like cl_menu_backdrop that the user previously left unregistered
//     (cvar() returned 0 → backdrop hidden).  CL cvars the menu
//     genuinely needs are still registered via client_config_cvars[]
//     in Menu_RegisterCvars below.
void() CVar_RegisterMine =
{
#ifdef CSQC
    float my_side = CVAR_SIDE_CL;
#else
    float my_side = CVAR_SIDE_SV;
#endif
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
    {
        if (g_cvar_side[i] & my_side)
            CVar_DoRegister(g_cvar_name[i], g_cvar_default[i]);
    }
};

// CVar_WriteServerCfg — overwrite a config file (typically the root
// server.cfg) from the manifest, filtered to entries that should be
// persisted across server restarts: SV-side AND
// CVAR_FLAG_SAVE_TO_SERVER_CFG set.  Skips transient/admin-trigger
// cvars (sv_writecvars, sv_roundrestart, sv_saveconfig, ...)
// because they don't want to be sticky.
//
// Called from two places:
//   • SSQC: `sv_writecvars 1` toggle in the server console.
//   • Menu: create_server_launch in m_createserver.qc — gives admins
//     a one-click "configure + persist" flow.
//
// Defined outside the SSQC #ifdef so the menu VM can link to it.
// fopen / fputs / sprintf / cvar_string are available in all VMs.
void(string path) CVar_WriteServerCfg =
{
    filestream f = fopen(path, FILE_WRITE);
    if (f < 0)
    {
        print(sprintf("CVar_WriteServerCfg: fopen %s FAILED\n", path));
        return;
    }

    fputs(f, "// server.cfg — AUTO-GENERATED.\n");
    fputs(f, "// Source of truth: shared/sh_cvar_table.qc (CVAR_FLAG_SAVE_TO_SERVER_CFG).\n");
    fputs(f, "// Regenerated by `sv_writecvars 1` or by launching from the Create Server menu.\n");
    fputs(f, "// Hand-edits are preserved only if you don't trigger a regen.\n");

    // Engine-only cvars not managed by the table.  Kept at the top
    // so the engine still sees them on `exec server.cfg`.  Mirrors
    // the original 2-line server.cfg the project shipped with.
    // nettest: use `set` (not bare `cvar value`).  A DEDICATED server execs server.cfg at STARTUP, before the
    // SSQC/ODE-plugin register their cvars — so bare `physics_ode_* / sv_physprop_* / sv_carry_*` lines hit
    // "Unknown command" and are dropped (the admin's tuning is lost).  `set` CREATES the cvar with the value,
    // and FTE preserves that value when the cvar is later registered, so the setting survives.
    fputs(f, "\n// ---------- Engine ----------\n");
    fputs(f, "set sv_maxrate 0\n");
    fputs(f, "set sv_maxdrate 0\n");
    // QW setmodel does NOT copy the model bbox to the entity unless these are set, so IQM/MD3
    // props would get the degenerate +-16 fallback cube (player walks INTO the model).
    fputs(f, "set sv_gameplayfix_setmodelsize_qw 1\n");
    fputs(f, "set sv_gameplayfix_setmodelrealbox 1\n");

    string current = "";
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
    {
        if (!(g_cvar_side[i] & CVAR_SIDE_SV))            continue;
        if (!(g_cvar_ui_flags[i] & CVAR_FLAG_SAVE_TO_SERVER_CFG)) continue;

        if (g_cvar_section[i] != current)
        {
            current = g_cvar_section[i];
            fputs(f, sprintf("\n// ---------- %s ----------\n", current));
        }
        // Persist the LIVE value, not the default — admins want their
        // current settings saved, not a wipe-back to manifest defaults.
        fputs(f, sprintf("set %s \"%s\"\n", g_cvar_name[i], cvar_string(g_cvar_name[i])));
    }

    fclose(f);
    print(sprintf("CVar_WriteServerCfg: wrote %s\n", path));
};

// Re-apply the table's default to any server-side cvar whose value
// got blanked by cfg/server.cfg's exec (replaces the long if-empty
// chain that used to live in SV_FixupEmptyDefaults / Menu_FixupEmptyDefaults).
//
// Defined outside any #ifdef so SSQC and the menu VM can both call
// it after their respective cfg-exec phases.  cvar_string and cvar_set
// are available in every VM.
void() CVar_ForceDefaults =
{
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
    {
        if (!(g_cvar_side[i] & CVAR_SIDE_SV)) continue;
        if (cvar_string(g_cvar_name[i]) == "")
            cvar_set(g_cvar_name[i], g_cvar_default[i]);
    }
};

#ifdef SSQC
// Overwrite cfg/allcommands.cfg from the table. Triggered by
// `sv_writecvars 1` in the server console (StartFrame catches it
// and calls here, then resets the cvar to 0 — same admin-trigger
// pattern as sv_roundrestart). SSQC has no registercommand so
// the cvar-toggle is the standard hook.
void() CVar_WriteAllCommandsCfg =
{
    filestream f = fopen("cfg/allcommands.cfg", FILE_WRITE);
    if (f < 0)
    {
        bprint(PRINT_HIGH, "sv_writecvars: fopen cfg/allcommands.cfg FAILED\n");
        return;
    }

    fputs(f, "// allcommands.cfg — AUTO-GENERATED by `sv_writecvars 1`.\n");
    fputs(f, "// Source of truth: shared/sh_cvar_table.qc CVar_Init().\n");
    fputs(f, "// Edit defaults there, then re-run `sv_writecvars 1` to refresh.\n");

    string current = "";
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
    {
        if (g_cvar_section[i] != current)
        {
            current = g_cvar_section[i];
            fputs(f, sprintf("\n// ---------- %s ----------\n", current));
        }
        fputs(f, sprintf("%s %s\n", g_cvar_name[i], g_cvar_default[i]));
    }

    fclose(f);
    bprint(PRINT_HIGH, "sv_writecvars: wrote cfg/allcommands.cfg\n");
};
#endif
