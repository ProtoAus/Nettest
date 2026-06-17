// ============================================================
//  shared/sh_cvar_table.qc  -  Single source of truth for every
//  custom cvar registered by the mod, on both CSQC and SSQC.
//
//  - CVar_Init() builds the table (sequential CVar_Add calls).
//    Edit the DEFAULT ZONE below to change any default.
//  - CVar_RegisterMine() iterates the table and registercvar()'s
//    only the entries flagged for the current VM (CL or SV).
//  - CVar_ForceDefaults() (SSQC only) re-applies the table's
//    defaults to any cvar blanked by data/server.cfg exec.
//  - CVar_WriteAllCommandsCfg() (SSQC only) overwrites
//    data/allcommands.cfg from the table, preserving section
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
// data/allcommands.cfg and the settings menu — it must list every cvar with
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

// CVar_AddSaved — like CVar_Add, but ALSO persisted to data/server.cfg by
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
// forward/right/down, defaulted to the shared baseline so a weapon's ADS
// is unchanged until tuned.  cl_viewfx.qc reads them via the weapon's
// weapon_ads_prefix field.
void(string prefix) ADS_RegisterPoseCvars =
{
    CVar_Add("Client", strcat(prefix, "_pitch"),   "0",    CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_yaw"),     "0",    CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_roll"),    "0",    CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_forward"), "-5",   CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_right"),   "6.69", CVAR_SIDE_CL);
    CVar_Add("Client", strcat(prefix, "_down"),    "2",    CVAR_SIDE_CL);
};

// ============================================================
//  ===  DEFAULT ZONE — edit here to change any default.  ===
//
//  Order within sections is the order the writer emits to
//  data/allcommands.cfg. Group new entries under an existing
//  section header or add a new section by passing a new label.
// ============================================================
void() CVar_Init =
{
    g_cvar_count = 0;

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
    CVar_Add("Client", "cl_camerabob",                 "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_amp_z",           "0.55",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_amp_x",           "0.35",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_cycle",           "120",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_speed_ref",       "250",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_camerabob_fade_time",       "0.18",  CVAR_SIDE_CL);

    CVar_Add("Client", "cl_viewmodelbob",              "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_pos_scale",    "1.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_ang_scale",    "1.0",   CVAR_SIDE_CL);
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

    CVar_Add("Client", "cl_viewmodelweight",           "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_threshold", "200",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_scale",     "0.02",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_max",       "8",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_stiffness", "65",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_damp",      "11",    CVAR_SIDE_CL);
    // Independent per-target scales so the camera and the gun can dip
    // by different amounts (e.g. cam_scale 1.0 + gun_scale 0.5 keeps
    // the gun mostly attached to the screen while the camera drops).
    CVar_Add("Client", "cl_viewmodelweight_cam_scale", "1.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelweight_gun_scale", "1.0",   CVAR_SIDE_CL);

    CVar_Add("Client", "cl_viewmodelsway",             "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_yaw_scale",   "0.06",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_pitch_scale", "0.05",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_pos_scale",   "0.50",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_recover",     "9",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_max_yaw",     "4",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelsway_max_pitch",   "3",     CVAR_SIDE_CL);
    // Pivot mode: when the current viewmodel has weapon_muzzle_bone
    // set, rotate the gun around the muzzle (CoD-style — butt swings,
    // muzzle stays put) instead of applying the default translation
    // parallax.  Models without a muzzle bone always fall back to the
    // translation path regardless of this cvar.
    CVar_Add("Client", "cl_viewmodelsway_pivot",       "0",     CVAR_SIDE_CL);

    // Speed-driven gun lowering — fades with the same envelope as the
    // walk/run bob so the gun drops as the player accelerates and
    // recovers when they stop.
    CVar_Add("Client", "cl_viewmodellowering",         "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_amount",  "4.0",   CVAR_SIDE_CL);
    // Sprint pose — when sv_shiftspeed > 1 and the player holds
    // +button4 while running, rotates and pulls the gun across the
    // chest (CoD-style).  Sub-cvars below tune the pose; the *_fade
    // controls how fast it ramps on/off.
    CVar_Add("Client", "cl_viewmodellowering_sprint",        "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_pitch",  "6",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_yaw",    "18",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_roll",   "12",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_forward","2",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_down",   "3",    CVAR_SIDE_CL);
    // Lateral shift while in the sprint pose.  +ve = right in viewmodel
    // space; the apply code negates this for XFLIP'd weapons so "right"
    // stays right on screen regardless of the per-weapon flip flag.
    CVar_Add("Client", "cl_viewmodellowering_sprint_right",  "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodellowering_sprint_fade",   "0.15", CVAR_SIDE_CL);

    // ADS (+attack2 hold to aim).  Mirrors the sprint-pose envelope
    // and offsets but with its own pose and a tighter ramp.  Sprint
    // wins if both are active.  All offsets are camera-relative; the
    // _right value is sign-flipped for XFLIP'd weapons (same convention
    // as the sprint pose).  Pose defaults pull the gun back-and-down
    // toward the camera and tilt slightly up so iron sights centre.
    // Subtracted from the base fov cvar while ADS engaged (envelope
    // scaled), added to base fov while sprinting.  Both stack
    // independently and clamp to [10, 170].
    CVar_Add("Client", "cl_ads_fov",                 "8",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_sprinting_fov",           "5",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_fade",      "0.5",  CVAR_SIDE_CL);
    // Shared ADS pose — the fallback pose for any weapon without its own
    // per-weapon cl_ads_<weapon>_* set (see cl_viewfx.qc ads_pfx select).
    CVar_Add("Client", "cl_ads_pitch",     "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_yaw",       "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_roll",      "0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_forward",   "-5",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_right",     "6.69", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_ads_down",      "2",    CVAR_SIDE_CL);

    // Per-weapon ADS pose overrides.  Each defaults to the shared pose
    // above, so a weapon's ADS is unchanged until tuned to align that
    // model's sights.  The weapon's Equip sets weapon_ads_prefix to the
    // matching prefix; cl_viewfx.qc reads it.
    ADS_RegisterPoseCvars("cl_ads_mp5");
    ADS_RegisterPoseCvars("cl_ads_vector");
    ADS_RegisterPoseCvars("cl_ads_type89");
    ADS_RegisterPoseCvars("cl_ads_ump45");
    ADS_RegisterPoseCvars("cl_ads_m249");
    ADS_RegisterPoseCvars("cl_ads_ks23");
    ADS_RegisterPoseCvars("cl_ads_m4");
    ADS_RegisterPoseCvars("cl_ads_galil");
    ADS_RegisterPoseCvars("cl_ads_glock");
    ADS_RegisterPoseCvars("cl_ads_elite");
    ADS_RegisterPoseCvars("cl_ads_p228");
    ADS_RegisterPoseCvars("cl_ads_msg90");
    ADS_RegisterPoseCvars("cl_ads_sg552");
    ADS_RegisterPoseCvars("cl_ads_sl8");
    ADS_RegisterPoseCvars("cl_ads_mk23");
    // Remaining ADS weapons — every gun gets its own pose set.
    ADS_RegisterPoseCvars("cl_ads_mac10");
    ADS_RegisterPoseCvars("cl_ads_famas");
    ADS_RegisterPoseCvars("cl_ads_m9");
    ADS_RegisterPoseCvars("cl_ads_anaconda");
    ADS_RegisterPoseCvars("cl_ads_ddeagle");
    ADS_RegisterPoseCvars("cl_ads_scar");
    ADS_RegisterPoseCvars("cl_ads_mauser");
    ADS_RegisterPoseCvars("cl_ads_spas12");
    ADS_RegisterPoseCvars("cl_ads_winchester");
    ADS_RegisterPoseCvars("cl_ads_barrett");
    ADS_RegisterPoseCvars("cl_ads_m700");
    ADS_RegisterPoseCvars("cl_ads_awm");
    ADS_RegisterPoseCvars("cl_ads_psg1");
    ADS_RegisterPoseCvars("cl_ads_dragunov");
    ADS_RegisterPoseCvars("cl_ads_aug");
    ADS_RegisterPoseCvars("cl_ads_ak47");
    ADS_RegisterPoseCvars("cl_ads_hdak47");
    ADS_RegisterPoseCvars("cl_ads_awp");
    ADS_RegisterPoseCvars("cl_ads_deagle");
    ADS_RegisterPoseCvars("cl_ads_m4a1");
    ADS_RegisterPoseCvars("cl_ads_scout");
    ADS_RegisterPoseCvars("cl_ads_usp");

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
    CVar_Add("Client", "cl_codscope_ads_threshold",   "0.85", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_codscope_sway_breath_amp",  "0.4",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_breath_rate", "0.18", CVAR_SIDE_CL);
    // Multiplier applied to ALL sway (classic + breathing) when the
    // player presses +button4 to hold breath while scoped.  Old code
    // used a hard 0.15 snap; the new envelope eases to this target
    // via cl_codscope_sway_breath_fade.
    CVar_Add("Client", "cl_codscope_sway_holdbreath_mult", "0.15", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_breath_fade",     "0.30", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_camerabob_sprint_mult",     "1.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_viewmodelbob_sprint_mult",  "1.0",   CVAR_SIDE_CL);

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
    CVar_Add("Client", "cl_dlight_update_hz",     "500", CVAR_SIDE_CL);

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
    CVar_Add("Client", "cl_player_spine_twist_scale", "0.55",  CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_twist_max",   "50",    CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_twist_waist_scale", "1", CVAR_SIDE_BOTH);
    // Scales the upper spine bones (spine2 + spine3) yaw fraction.
    // Lower values keep the waist leaning naturally while reducing how far
    // the head/shoulders rotate when strafing.  1.0 = original feel.
    CVar_Add("Client", "cl_player_spine_twist_upper_scale", "0.5", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_pitch_scale", "1",     CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_pitch_max",   "35",    CVAR_SIDE_BOTH);
    // Scales spine3 + neck pitch fractions so the head bobs less when
    // looking up/down.  1.0 = original feel.
    CVar_Add("Client", "cl_player_spine_pitch_upper_scale", "0.6", CVAR_SIDE_BOTH);
    // perf: skeleton rebuild rate (Hz) for STILL players (velocity <= 8).  A
    // standing crowd's breathing pose barely changes, so re-solving the ~50-bone
    // skeleton every frame is wasted; cap it.  Moving players always rebuild every
    // frame.  The trust-1 trace uses the SAME cached skeleton, so hit detection
    // stays consistent at this rate.  0 = always rebuild (off).
    CVar_Add("Client", "cl_player_skel_idle_rate", "25", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_backpedal_enter_angle", "150", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_backpedal_exit_angle",  "100", CVAR_SIDE_BOTH);
    CVar_Add("Client", "cl_player_spine_debug",       "0",     CVAR_SIDE_BOTH);
    // Length of the visual flinch reaction (CSANIM_GUT_FLINCH /
    // CSANIM_HEAD_FLINCH overrides the torso anim) after a player
    // takes damage.  CS flinch sequences are short (2 frames @ 30 fps
    // ≈ 0.066 s); the duration here should be close to that so the
    // sequence plays once instead of holding on the last frame.
    // Set to 0 to disable flinching entirely.
    CVar_Add("Client", "cl_player_flinch_time",    "0.10",  CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_impact_particle_offset", "2",    CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_impact_light_scale",   "1.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_light_offset",  "8",     CVAR_SIDE_CL); // units the impact dlight stands off the wall along its normal (0 = flush; pull back so the wall face lights up)
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
    CVar_Add("Client", "cl_explosion_light",      "1",     CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_tracer_width",         "1.5",       CVAR_SIDE_CL);
    // Empty string disables the color overlay entirely (vertex tint
    // = white, shader texture renders untinted).  Any non-empty value
    // parses as "R G B" floats 0..1.
    CVar_Add("Client", "cl_tracer_color",         "1 0.85 0.5", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_opacity",       "0.7",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_time",          "0.12",      CVAR_SIDE_CL);
    // Override texture/shader path for the tracer quad.  Empty falls
    // back to gfx/tracer; set e.g. "gfx/rain/streak1" to render a
    // sprite-streak in place of the default glow ribbon.
    CVar_Add("Client", "cl_tracer_sprite",        "",          CVAR_SIDE_CL);
    // "Travel" mode — instead of a static ribbon, the tracer is a
    // short stretched quad that flies from muzzle to impact at
    // _speed qu/s, fading near the end.  Slots tag themselves at
    // spawn so static and travel tracers can coexist mid-flight.
    CVar_Add("Client", "cl_tracer_travel",        "0",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_tracer_travel_speed",  "8000",      CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_tracer_travel_full",   "0",         CVAR_SIDE_CL);
    // 0 = off, nonzero = texture-backed decals.
    CVar_Add("Client", "cl_bulletholes",          "2",     CVAR_SIDE_CL);
    // Cap decal spawns per shot.  Penetration can spawn entry+exit
    // decals across multiple targets — 0 = unlimited (old behaviour),
    // 1 = entry decal only (no penetration exit holes), N = max N.
    CVar_Add("Client", "cl_bulletholes_per_shot", "0",     CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_impact_dlights_per_shot", "2",  CVAR_SIDE_CL);
    // Cap particle-effect spawns per shot (Impact_SpawnParticles — the
    // smoke / spark puff on every impact).  Penetration through walls
    // can stack 4+ exit smokes from a single shot; cap thins them.
    // 0 = unlimited (old behaviour); default 2 mirrors the dlight cap.
    CVar_Add("Client", "cl_impact_effects_per_shot", "2",  CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_impact_debris",          "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_mode",     "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_count",    "4",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_force",    "110", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_impact_debris_per_shot", "1",   CVAR_SIDE_CL);
    // Bullet-hole renderer path (read by cl_bulletholes.qc):
    //   1 = polygon-quad (default, fast — ~5-8x cheaper than adddecal,
    //       no decal corner-wrap on convex surfaces).
    //   0 = legacy FTE adddecal() — slow per-frame BSP clip+project, but
    //       wraps the decal across edges of convex world geometry.
    // Brushmodel-owned holes (func_door, func_breakable, etc.) ignore
    // this and always use the polygon path; adddecal can't reproject
    // onto a moving submodel.
    CVar_Add("Client", "cl_bullethole_renderer",  "1",     CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_flashlight_radius",     "400",          CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_fov",        "35",           CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_brightness", "1.5",          CVAR_SIDE_CL);
    CVar_Add("Client", "cl_flashlight_color",      "1.0 0.95 0.85", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_blood_decals_brightness",  "0.4", CVAR_SIDE_CL);
    // 0 = blood decals fade after BLOOD_FADE_END seconds (default).
    // 1 = full alpha forever, only the FIFO cap removes them.  Same
    //     semantics as cl_scorch_persistent.
    CVar_Add("Client", "cl_blood_persistent",         "0",   CVAR_SIDE_CL);
    // Source-style edge clipping for the BAKED blood-decal trisoup.  When
    // 1 (default) each splat's quad is clipped at spawn against the hit
    // BSP triangle's 3 edges so it conforms to the surface boundary
    // instead of overhanging.  One-shot CPU cost per splat — per-frame
    // render is one addtrisoup_simple per texture either way.  Mirrors
    // cl_bullethole_clip_geom; set 0 to see the raw axis-aligned quads.
    CVar_Add("Client", "cl_blood_decals_clip",        "1",   CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_debug_hitgroup",           "0",     CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_rain_intensity",           "0.5", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_radius",              "1024",CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_speed",               "800", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_angle_x",             "0.3", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_angle_y",             "0",   CVAR_SIDE_CL);
    // env_hud / titles.txt playback speed multiplier.  1.0 = author
    // timings; <1 = slower (longer hold / longer fades / slower
    // typewriter scroll-out); >1 = faster.  Affects every active
    // env_message simultaneously, so cinematic credit sequences can
    // be slowed down without re-authoring titles.txt.
    CVar_Add("Client", "cl_envhud_speed",             "1.0", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_rain_alpha",               "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_width",               "1.5", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_color",               "1 1 1", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_streak_texture",      "gfx/rain/streak", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_splash_texture",      "gfx/rain/splash", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_splash_alpha",        "1",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_splash_size",         "4",   CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_rain_fps",                 "0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_rain_length",              "64",  CVAR_SIDE_CL);
    // Splash frame-cycle rate (4-frame animation).  Default 12.5fps =
    // 80ms/frame = 0.32s total splash lifetime.  Bound 1..120 in code.
    CVar_Add("Client", "cl_rain_splash_fps",          "12.5",CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_lightning_max_interval",   "25",  CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_snow_speed",               "600",              CVAR_SIDE_CL);
    // Snow drop count multiplier — same scale as cl_rain_intensity
    // (1.0 = 128 flakes, 32 = the 4096-flake cap).  0 or unset falls
    // back to cl_rain_intensity so snow inherits rain's tuning.
    CVar_Add("Client", "cl_snow_intensity",           "0",                CVAR_SIDE_CL);
    // Snow-mode flake alpha override (separate from cl_rain_alpha).
    // Consumed in Rain_ResolveTuning when cl_snow != 0 and value > 0.
    CVar_Add("Client", "cl_snow_alpha",               "1",                CVAR_SIDE_CL);
    // Fullbright snow: forces flake vertex color to pure white in the
    // streak draw, bypassing any rain_tick_color tint path.
    CVar_Add("Client", "cl_snow_fullbright",          "0",                CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_weather_skycheck",         "1",                CVAR_SIDE_CL);
    // Water-surface rings: pop expanding weather.ringsplash quads where rain
    // lands on water (the engine can't detect water hits per-drop, so a QC
    // emitter traces for water near the camera).  _rate = rings/sec per unit
    // cl_rain_intensity (capped 8/frame).
    CVar_Add("Client", "cl_weather_waterring",        "1",                CVAR_SIDE_CL);
    CVar_Add("Client", "cl_weather_waterring_rate",   "40",               CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_throwtrail_length",        "0.4",                     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_width",         "2",                       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_alpha",         "0.6",                     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_color",         "1 1 1",                   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_throwtrail_texture",       "gfx/throwtrail/default",  CVAR_SIDE_CL);
    // Head-end width rampup: trail grows from 0 → cl_throwtrail_width
    // over this many seconds since the projectile was first sampled.
    // 0 disables the ramp (trail starts at full width immediately).
    // Default 0.25s — visible "tapering into existence" from the
    // throw moment.
    CVar_Add("Client", "cl_throwtrail_rampup",        "0.25",                    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_light",    "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_light_scale", "1.0", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_muzzleflash_sprite_time",    "0.06",  CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_scale",   "1.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_shrink",  "2.0",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzleflash_sprite_opacity", "1.0",   CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_muzzlesmoke_life",           "0.5",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_size",           "4",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_grow",           "4",         CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_opacity",        "0.5",       CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_drift_up",       "18",        CVAR_SIDE_CL);
    CVar_Add("Client", "cl_muzzlesmoke_drift_fwd",      "12",        CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_muzzlesmoke_wind_strength",  "18",        CVAR_SIDE_CL);
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
    CVar_Add("Client", "r_viewmodel_maxlight",    "180",   CVAR_SIDE_CL);
    // Brightness ceilings for non-viewmodel entities. Implemented QC-side
    // via a colormod scale at predraw time (cl_teamtint.qc + cl_weapons.qc),
    // not in the engine — the engine cap only applies to RF_WEAPONMODEL.
    // Same 0–255 byte semantics as r_viewmodel_maxlight; 0 disables the cap.
    //   _playermodels_  caps light on player_visual_proxy (remote bodies +
    //                   first-person body when shadow-casting). Stacks on
    //                   top of the team-tint colormod.
    //   _physdrops_     caps light on dropped weapon entities (CSQC entities
    //                   with predraw, not engine-replicated phys barrels).
    CVar_Add("Client", "r_playermodels_maxlight", "180",   CVAR_SIDE_CL);
    CVar_Add("Client", "r_physdrops_maxlight",    "180",   CVAR_SIDE_CL);
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
    CVar_Add("Client", "r_physdrops_pvscull",     "0",     CVAR_SIDE_CL);
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
    CVar_Add("Performance", "sys_clocktype",        "3",     CVAR_SIDE_CL);
    CVar_Add("Performance", "sys_framepacing",      "3",     CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_yieldcpu",          "0",     CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_maxfps",            "300",   CVAR_SIDE_CL);
    CVar_Add("Performance", "cl_idlefps",           "300",   CVAR_SIDE_CL);

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
    CVar_Add("Client", "cl_scoreboard_blur_radius", "0.0033", CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_crosshairlength",      "6",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairthickness",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairgap",         "3",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshaircolour",      "0 1 0", CVAR_SIDE_CL);
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
    // Defaults overlap with data/default.cfg's `set` lines for engine
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
    CVar_AddUI("Voice", "cl_voip_micamp",         "2",     CVAR_SIDE_CL,
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
    CVar_AddUI("Voice", "cl_voip_autogain",       "0",     CVAR_SIDE_CL,
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
    CVar_AddUI("Voice", "cl_voip_showmeter",      "0",     CVAR_SIDE_CL,
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
    CVar_Add("Client", "cl_voip_overhead_size",    "12",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_voip_overhead_offset",  "48",   CVAR_SIDE_CL);
    CVar_Add("Client", "cl_voip_fadeduration",     "2",    CVAR_SIDE_CL);

    // ---------- Client debug ----------
    CVar_Add("Client debug", "cl_debug_impacts",     "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hitboxes",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hbexpand",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_physprops",   "0", CVAR_SIDE_CL);
    // Debug: disable phys-prop extrapolation smoothing to see the raw server
    // send cadence (default 0 = extrapolation ON).  Read in cl_physprop.qc.
    CVar_Add("Client debug", "cl_physprop_noextrap", "0", CVAR_SIDE_CL);
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
    // Server-side VoIP toggles.  All three persist into data/server.cfg
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
    CVar_AddUI("Multiplayer", "mp_respawndelay",      "3",  CVAR_SIDE_SV,
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
    CVar_Add("Client", "cl_codstamina_bar",             "1",      CVAR_SIDE_CL);
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
    // = 3 → 3× normal scope sway amplitude at peak punish.  fade is
    // the EMA time constant for the onset (faster ramp-up than the
    // breath envelope so the punish hits hard).  Ramp-DOWN is tied
    // to the stamina refill in cl_codscope.qc — not driven by this
    // cvar.
    CVar_Add("Client", "cl_codscope_sway_punish_scale", "3.0",    CVAR_SIDE_CL);
    CVar_Add("Client", "cl_codscope_sway_punish_fade",  "0.20",   CVAR_SIDE_CL);
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
    //   cl_spray_style — 0 = flat double-sided textured quad
    //                      (trisoup, cheap, no edge clipping; the
    //                      spray clips into mid-air at brush corners
    //                      but renders correctly regardless of which
    //                      side the wall faces).  Works for any PNG
    //                      without needing a shader entry.
    //                    1 = adddecal() — engine BSP-wrapping decal,
    //                      matches scorch / bullet-hole behaviour and
    //                      survives stair-steps and corners.  Costs
    //                      one adddecal() call per spray per frame.
    //                      REQUIRES a shader script entry per PNG
    //                      (see scripts/effects.shader near
    //                      `gfx/sprays/nospray.png` for the template);
    //                      without one, the spray is invisible.
    //   Read at spawn time per spray; toggling mid-game doesn't
    //   restyle existing sprays.
    CVar_Add("Client", "cl_spray_style",           "0",             CVAR_SIDE_CL);
    CVar_Add("Server", "sv_sprayfrequency",        "10",            CVAR_SIDE_SV);
    CVar_Add("Server", "sv_spraymax",              "3",             CVAR_SIDE_SV);

    CVar_AddUI("Server", "sv_autohop",                   "0",      CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_SERVER | CVAR_TAB_CREATE_GAME, "Autohop",
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
    CVar_AddUI("Server", "sv_hitbox_expand",             "32",      CVAR_SIDE_SV,
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
    // CVar_ForceDefaults can rescue them after data/server.cfg exec).
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
    CVar_AddUI("Server debug", "sv_debug_hitclaim",     "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_lagcomp",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_camera",       "0", CVAR_SIDE_SV,
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
    CVar_AddUI("Server debug", "sv_debug_spawns",       "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_weapons",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);
    CVar_AddUI("Server debug", "sv_debug_wepswap",      "0", CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_DEBUG, "", 0, CVAR_ENUM_NONE, 0, 0);

    // ---------- ODE physics ----------
    CVar_AddUI("ODE physics", "physics_ode_autodisable",        "1",    CVAR_SIDE_SV,
        CVAR_UI_TOGGLE, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "ODE AutoDisable",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 0);
    // Source-like smoothness: more substeps/frame (was 2), a small contact-overlap
    // layer (the big anti-jitter knob), and a stiffer QuickStep solve.
    CVar_AddUI("ODE physics", "physics_ode_iterationsperframe", "8",   CVAR_SIDE_SV,
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
    CVar_AddUI("ODE physics", "sv_physprop_hit_force",          "128", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Hit Force",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2000);
    // Per-(damage × falloff) impulse magnitude applied by
    // PhysProp_TryRadiusPush when any explosion detonates near a phys
    // drop or prop.  Tuned in playtest — defaults that look reasonable
    // on paper (matching sv_physprop_hit_force scale) end up launching
    // props through the skybox because the radial spread compounds
    // with ODE's mass/damping.  512 keeps the blasts visceral but
    // controllable; bump higher for more chaos.  CVar_AddUI (not plain
    // CVar_Add) so it auto-saves to data/server.cfg and sits in the
    // physics tab next to Hit Force, its bullet-knockback sibling.
    CVar_AddUI("ODE physics", "sv_physprop_explosion_force",   "512", CVAR_SIDE_SV,
        CVAR_UI_SCALAR, CVAR_TAB_ODE | CVAR_TAB_CREATE_PHYS, "Explosion Force",
        CVAR_FLAG_SAVE_TO_SERVER_CFG, CVAR_ENUM_NONE, 0, 2000);  // ×100 in code (512 = old ~51200)
    CVar_AddUI("ODE physics", "sv_physprop_use_force",          "800", CVAR_SIDE_SV,
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
    // Unified phys-object core (PhysObj_Setup / PhysObj_Think): per-object mass
    // overrides + shared bounce + shared sleep/wake thresholds. The barrel uses
    // sv_physprop_mass (20); the can + weapons get their own mass; sleep_* gate the
    // QC sleep/wake-at-rest for ALL free props (barrel/can/weapon drops).
    CVar_Add("ODE physics", "sv_physprop_can_mass",       "2",    CVAR_SIDE_SV);
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
    CVar_AddSaved("ODE physics", "sv_carry_grab_dist",   "96",   CVAR_SIDE_SV);
    CVar_AddSaved("ODE physics", "sv_carry_grab_time",   "0.25", CVAR_SIDE_SV);  // pull-in animation duration on grab (0 = instant/snap)
    CVar_AddSaved("ODE physics", "sv_carry_throw_force", "300",  CVAR_SIDE_SV);  // throw speed (qu/s), velocity-set (+ player velocity)
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
    // Source/HL2 entity-lump props (server/sv_props.qc). enable = master switch for
    // every prop_* classname; physics = ODE rigid bodies + +use carry (set 0 for
    // NON-COLLIDABLE visual-only props — lighter/stabler on prop-dense Source maps,
    // where every prop_physics is otherwise a live ODE body); default_halfsize = the
    // fallback collision half-extent when a GoldSrc/Source .mdl ships no usable bbox.
    CVar_Add("ODE physics", "sv_props_enable",           "1",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_props_physics",          "1",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_props_default_halfsize", "16", CVAR_SIDE_SV);
    // Phys-prop contact FX (impact sounds + smoke).  Impact speed (qu/s) drives
    // soft-vs-hard sound + smoke size; below _min_speed nothing fires (gentle taps).
    // _cooldown stops a tumbling/bouncing prop machine-gunning sounds.  _slide_* drive
    // the periodic dust puffs while a prop scrapes along a surface.
    CVar_Add("ODE physics", "sv_physprop_impact_min_speed",  "70",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_impact_hard_speed", "260",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_impact_cooldown",   "0.11", CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_slide_min_speed",   "60",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_slide_interval",    "0.18", CVAR_SIDE_SV);
    // 1 = scrape-loop volume TRACKS slide speed (re-issues the loop on a notable speed
    // change — restarts the sample, ~inaudible for a rough scrape; throttled+deadbanded).
    // 0 = volume fixed at the speed it had when the scrape started.
    CVar_Add("ODE physics", "sv_physprop_scrape_track",      "1",    CVAR_SIDE_SV);

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
// got blanked by data/server.cfg's exec (replaces the long if-empty
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
// Overwrite data/allcommands.cfg from the table. Triggered by
// `sv_writecvars 1` in the server console (StartFrame catches it
// and calls here, then resets the cvar to 0 — same admin-trigger
// pattern as sv_roundrestart). SSQC has no registercommand so
// the cvar-toggle is the standard hook.
void() CVar_WriteAllCommandsCfg =
{
    filestream f = fopen("data/allcommands.cfg", FILE_WRITE);
    if (f < 0)
    {
        bprint(PRINT_HIGH, "sv_writecvars: fopen data/allcommands.cfg FAILED\n");
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
    bprint(PRINT_HIGH, "sv_writecvars: wrote data/allcommands.cfg\n");
};
#endif
