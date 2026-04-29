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

const float CVAR_TABLE_MAX = 256;

string g_cvar_name   [CVAR_TABLE_MAX];
string g_cvar_default[CVAR_TABLE_MAX];
string g_cvar_section[CVAR_TABLE_MAX];
float  g_cvar_side   [CVAR_TABLE_MAX];
float  g_cvar_count;

void(string section, string name, string def, float side) CVar_Add =
{
    if (g_cvar_count >= CVAR_TABLE_MAX) return;
    g_cvar_section[g_cvar_count] = section;
    g_cvar_name   [g_cvar_count] = name;
    g_cvar_default[g_cvar_count] = def;
    g_cvar_side   [g_cvar_count] = side;
    g_cvar_count = g_cvar_count + 1;
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

    // ---------- Client ----------
    CVar_Add("Client", "cl_autohop",              "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_hitmarker",            "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_speedometer",          "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_predict_hits",         "1",     CVAR_SIDE_CL);
    // Predict the visual death of a remote player when our CSQC trace
    // computes a lethal hit (final damage ≥ vis_health). Drops the
    // body + plays the matching death animation immediately on the
    // shooter's screen; server's authoritative confirmation arrives
    // ~ping ms later and the prediction either matches (no snap) or
    // reverts (next snapshot's vis_is_dead=0 + alive anim restores).
    CVar_Add("Client", "cl_predict_death",        "1",     CVAR_SIDE_CL);
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
    CVar_Add("Client", "cl_interp_time",          "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_teamcolours",          "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_menu_backdrop",        "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairlength",      "6",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairthickness",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairgap",         "3",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshaircolour",      "0 1 0", CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairdynamic",     "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "cl_crosshairweapongap",   "1",     CVAR_SIDE_CL);
    CVar_Add("Client", "r_damageflash_intensity", "0",     CVAR_SIDE_CL);
    CVar_Add("Client", "net_graph",               "0",     CVAR_SIDE_CL);

    // ---------- Client debug ----------
    CVar_Add("Client debug", "cl_debug_impacts",     "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hitboxes",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_hbexpand",    "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_physprops",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_net",         "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_bandwidth",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_weapon",      "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_move",        "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_game",        "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_playermodel", "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_smoothing",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_footsteps",   "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_extrap",      "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_noblock",     "0", CVAR_SIDE_CL);
    CVar_Add("Client debug", "cl_debug_panelinput",  "0", CVAR_SIDE_CL);
    // Per-reconcile prediction-error trace.  dprints `elen pre post` so
    // you can see whether `cl_driftlock` even has anything to smooth
    // (elen consistently < 0.5 = the drift is coming from a non-
    // reconcile path and this smoother is dormant).
    CVar_Add("Client debug", "cl_debug_driftlock", "0", CVAR_SIDE_CL);
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

    // ---------- Multiplayer ----------
    CVar_Add("Multiplayer", "mp_cheats",            "0",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_falldamage",        "1",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_freezetime",        "3",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_friendlyfire",      "0",  CVAR_SIDE_SV);
    // 1 = leave every corpse on the ground until round-restart sweep
    //     (current default — visually richer, scoreboard of kills).
    // 0 = at most one corpse per player; the previous one is removed
    //     when the player respawns.  Cheaper at high kill counts in
    //     TDM, harmless in Elimination (one death/round anyway).
    CVar_Add("Multiplayer", "mp_deadbodys",         "1",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_maprestartdelay",   "10", CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_maxrounds",         "12", CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_noblock",           "0",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_nomapweapons",      "0",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_respawn",           "1",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_respawndelay",      "3",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_roundrestartdelay", "5",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_roundtime",         "5",  CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_timelimit",         "25", CVAR_SIDE_SV);
    CVar_Add("Multiplayer", "mp_weaponweight",      "1",  CVAR_SIDE_SV);
    // 1 = func_door / func_button activation is suppressed (use/touch
    // handlers early-return). Live toggle: changes apply mid-game with
    // no map restart. Bhop forces this on via the per-gamemode block in
    // sv_main.qc StartFrame; admins can also enable in any other mode.
    CVar_Add("Multiplayer", "mp_disabledoors",      "0",  CVAR_SIDE_SV);

    // ---------- Server ----------
    CVar_Add("Server", "sv_gamemode",                  "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_gravity",                   "800",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_maxspeed",                  "270",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_friction",                  "4",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_waterfriction",             "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_wateraccelerate",           "10",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_accelerate",                "5",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_airaccelerate",             "150",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_stopspeed",                 "100",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_shiftspeed",                "135",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_eye_height",                "56",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_hull_height",               "72",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_minpitch",                  "-90",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_maxpitch",                  "90",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_autohop",                   "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_stamina",                   "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_snipersway",                "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_lagcomp",                   "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_lagcomp_maxrewind",         "0.5",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_trust_clienthits",          "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_hitbox_expand",             "8",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_anim_qu_per_sec",           "240",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_anim_qu_per_sec_crouch",    "100",      CVAR_SIDE_SV);
    CVar_Add("Server", "sv_command_continuation",      "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_pose_keepalive_ticks",      "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_wepswap_speed_transition",  "0.15",     CVAR_SIDE_SV);
    CVar_Add("Server", "sv_player_basebone",           "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_default_primary",           "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_default_secondary",         "28",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_default_melee",             "20",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_default_utility",           "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_rcon_password_shadow",      "",         CVAR_SIDE_SV);
    CVar_Add("Server", "sv_roundrestart",              "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_saveconfig",                "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_writecvars",                "0",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_backdrop",                  "0",        CVAR_SIDE_SV);
    // Send rate (Hz) for in-flight items: dropped weapons during the
    // toss/settle window AND server-replicated projectiles. Higher = smoother
    // visible flight at small bandwidth cost. Pushed to serverinfo so CSQC
    // can read it (Toss_NextThinkInterval mirrors). Clamped 5..100 in code.
    CVar_Add("Server", "sv_toss_tickrate",             "20",       CVAR_SIDE_SV);
    CVar_Add("Server", "sv_ode_loaded",                "0",        CVAR_SIDE_SV);
    // Engine-pre-registered cvars (FTE registers these; we restate their
    // defaults so the cfg captures the mod's intended values and
    // CVar_ForceDefaults can rescue them after data/server.cfg exec).
    CVar_Add("Server", "sv_antilag",                   "3",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_bigcoords",                 "1",        CVAR_SIDE_SV);
    CVar_Add("Server", "sv_nqplayerphysics",           "0",        CVAR_SIDE_SV);

    // ---------- Server debug ----------
    CVar_Add("Server debug", "sv_debug_clienthits",   "0", CVAR_SIDE_SV);
    // Verbose server-side hitclaim trace — every cmd hitclaim received,
    // every accept/reject reason, and the resolved hitgroup + damage.
    // Pairs with cl_debug_hitclaim on the client. Print, not dprint.
    CVar_Add("Server debug", "sv_debug_hitclaim",     "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_lagcomp",      "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_camera",       "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_hitboxes",     "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_blendfracs",   "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_noblock",      "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_continuation", "0", CVAR_SIDE_SV);
    // Registered on BOTH so the client menu can discover them too.
    CVar_Add("Server debug", "sv_debug_ent_types",    "0", CVAR_SIDE_BOTH);
    CVar_Add("Server debug", "sv_debug_pickups",      "0", CVAR_SIDE_BOTH);
    CVar_Add("Server debug", "sv_debug_footsteps",    "0", CVAR_SIDE_BOTH);
    CVar_Add("Server debug", "sv_debug_physprops",    "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_spawns",       "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_weapons",      "0", CVAR_SIDE_SV);
    CVar_Add("Server debug", "sv_debug_wepswap",      "0", CVAR_SIDE_SV);

    // ---------- ODE physics ----------
    CVar_Add("ODE physics", "physics_ode_autodisable",        "0",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "physics_ode_iterationsperframe", "10",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "physics_ode_worldquickstep",     "0",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_hit_force",          "8000", CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_use_force",          "800",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_use_velmult",        "800",  CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_mass",               "20",   CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_erp",                "0",    CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_damp_lin",           "0.01", CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_damp_ang",           "0.01", CVAR_SIDE_SV);
    CVar_Add("ODE physics", "sv_physprop_friction",           "1.0",  CVAR_SIDE_SV);

    // ---------- Player movement ----------
    CVar_Add("Player movement", "pm_ramp_bumpcount", "8", CVAR_SIDE_SV);
};

// Iterate the table and registercvar() the entries flagged for the
// current VM. Called once at CSQC_Init / worldspawn.
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
            registercvar(g_cvar_name[i], g_cvar_default[i]);
    }
};

#ifdef SSQC
// Re-apply the table's default to any server-side cvar whose value
// got blanked by data/server.cfg's exec (replaces the long if-empty
// chain that used to live in SV_FixupEmptyDefaults).
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
