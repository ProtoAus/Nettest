// ============================================================
//  client/cl_serverpanel.qc  -  F2 in-game server-cvar panel
//
//  Sister to cl_debugpanel.qc.  Floating CSQC overlay (F2 toggles)
//  exposing Rcon controls plus Multiplayer / Server / Server-debug
//  / ODE-physics cvars as clickable buttons or text inputs. Five tabs
//  along the top — too many entries (~80+) for a single scroll list.
//
//  When the user is hosting a listen server, sets go through
//  `localcmd(name value)` directly — the engine's cvar table is
//  shared with SSQC.  When connected to a remote server, sets go
//  through `rcon name value` so the change reaches the actual
//  server cvar table (the user needs rcon_password set up
//  separately).  Remote/listen detection is handled below.
//
//  Reuses Debug_Button from cl_debugpanel.qc as the generic SUI
//  button helper — cl_debugpanel.qc compiles before this file in
//  cl_progs.src so its symbols are visible here.
// ============================================================

// --- Layout constants ---
const float SV_KIND_TOGGLE     = 0;
const float SV_KIND_SCALAR     = 1;
const float SV_KIND_ENUM       = 2;
const float SV_KIND_STRING     = 3;
const float SV_KIND_ACTION     = 4;
// Multi-select dropdown — same row layout as SV_KIND_ENUM, but the
// underlying cvar is a comma-separated list and the dropdown overlay
// renders checkboxes that toggle bits without closing.  Currently
// applied only to sv_default_utility (multi-grenade loadout).
const float SV_KIND_ENUM_MULTI = 5;
// Section header — renders a non-interactive bold label row in the
// scroll list.  No cvar binding; sv_entry_cvar holds the literal
// label text and the dispatcher draws it as a separator.
const float SV_KIND_HEADER     = 6;
const float SV_MAX_ENTRIES  = 128;

// Tab IDs — also doubles as ordering for the tab strip below.
const float SV_TAB_RCON     = 0;
const float SV_TAB_MULTI    = 1;
const float SV_TAB_SERVER   = 2;
const float SV_TAB_DEBUG    = 3;
const float SV_TAB_ODE      = 4;
const float SV_TAB_COUNT    = 5;

const float SV_SCOPE_SERVER = 0;
const float SV_SCOPE_LOCAL  = 1;

const float SV_TITLE_H      = 24;
const float SV_TAB_STRIP_H  = 20;
const float SV_ROW_H        = 18;
const float SV_PAD          = 6;
const float SV_GRIP_SIZE    = 12;
const float SV_VBAR_W       = 8;

const vector SV_FONT          = '8 8 0';
const vector SV_BG            = '0.07 0.08 0.10';
const vector SV_BG_DARKER     = '0.04 0.05 0.07';
const vector SV_BORDER        = '0.30 0.30 0.35';
const vector SV_TITLE_BG      = '0.05 0.06 0.08';
const vector SV_TAB_BG        = '0.06 0.07 0.09';
const vector SV_INPUT_BG      = '0.10 0.11 0.13';
const vector SV_BTN_OFF       = '0.18 0.18 0.20';
const vector SV_BTN_OFF_BORD  = '0.30 0.30 0.35';
const vector SV_BTN_ON        = '0.20 0.45 0.20';
const vector SV_BTN_ON_BORD   = '0.35 0.65 0.35';
const vector SV_BTN_ACTIVE    = '0.18 0.32 0.50';
const vector SV_BTN_ACTIVE_BORD = '0.35 0.55 0.80';
const vector SV_BTN_CLOSE     = '0.40 0.15 0.15';
const vector SV_BTN_CLOSE_BORD= '0.65 0.25 0.25';
const vector SV_TEXT_1        = '0.95 0.95 0.95';
const vector SV_TEXT_2        = '0.65 0.65 0.70';
const vector SV_TEXT_REMOTE   = '0.95 0.75 0.30';
const vector SV_GOLD_BG       = '0.18 0.14 0.06';
const vector SV_GOLD_BORDER   = '0.76 0.62 0.20';
const vector SV_GOLD_ACTIVE_BG = '0.22 0.17 0.08';
const vector SV_GOLD_ACTIVE_BORDER = '0.90 0.74 0.28';
const vector SV_GOLD_TEXT     = '0.98 0.86 0.38';
const vector SV_SHADOW        = '0 0 0';

// --- Cvar table ---
string sv_entry_label [SV_MAX_ENTRIES];
string sv_entry_cvar  [SV_MAX_ENTRIES];
float  sv_entry_kind  [SV_MAX_ENTRIES];
float  sv_entry_tab   [SV_MAX_ENTRIES];
float  sv_entry_scope [SV_MAX_ENTRIES];
float  sv_entry_accent[SV_MAX_ENTRIES];
float  sv_entry_no_local_fallback[SV_MAX_ENTRIES];
float  sv_entry_count;

// --- Single shared scalar-edit buffer ---
// File-scope strings, not array elements — FTEQCC's __inout doesn't
// reliably write back to array slots, so per-entry parallel arrays
// silently lost typed chars and the input boxes appeared empty.
string sv_edit_text;
float  sv_edit_cursor;
// `var` keeps this writable — bare `float foo = -1;` at file scope
// makes FTEQCC treat the symbol as const.
var float sv_active_idx = -1;

// --- Optimistic shadow for toggles on remote / dedicated servers ---
// Server cvars that aren't pushed via serverinfo would otherwise
// always read 0 on a non-listen client (cvar() reads the local CSQC
// table which never receives them), so toggles got stuck in "Off"
// after one click.  When the user flips a toggle, we store the new
// value here; subsequent reads prefer this shadow over the local
// cvar UNTIL serverkey() reports a real server-pushed value, at
// which point the shadow is cleared and the truth wins.
float  sv_entry_shadow    [SV_MAX_ENTRIES];
float  sv_entry_shadow_set[SV_MAX_ENTRIES];
string sv_entry_string_shadow[SV_MAX_ENTRIES];
float  sv_entry_string_shadow_set[SV_MAX_ENTRIES];

// --- Enum/dropdown state ---
float  sv_enum_open;
float  sv_enum_visible;
vector sv_enum_button_pos;
vector sv_enum_button_size;
var float sv_enum_entry_idx = -1;

// Default-loadout dropdown options come from shared/sh_weapon_manifest.qc.

// Tickrate dropdown data. Matches Create Server, but the underlying
// server cvar is sv_mintic (seconds per tick), so selections are
// converted to 1 / tickrate when sent.
float  sv_tickrate_values[] = { 64, 66, 72, 85, 100, 128, 200, 300 };
string sv_tickrate_labels[] = { "64 (CS:GO)", "66 (CS:S)", "72 (Quake)", "85 (CS:GO)", "100 (CS:S)", "128 (CS:GO)", "200 (FTE)", "300 (FTE)" };

// Map-cycle dropdown data. Loaded from cfg/maps.txt so the F2 Rcon
// panel can target the same pool file the server uses for end-of-map
// rotation.
strbuf sv_cycle_maps;
float  sv_cycle_maps_loaded;
float  sv_cycle_map_selected;

// --- Window state ---
float  sv_panel_open;
float  sv_panel_initialized;
vector sv_panel_pos;
vector sv_panel_size;
float  sv_panel_dragging;
vector sv_panel_drag_offset;
float  sv_panel_resizing;
vector sv_panel_resize_origin_size;
vector sv_panel_resize_origin_cursor;
float  sv_cursor_active;
vector sv_panel_scroll_offset;
float  sv_panel_current_tab;

// SUI cursor shared global (defined in sui_sys.qc).
vector _cursor_position;

// =============================================================
//  Cvar table builders
// =============================================================
void(string label, string cvarname, float kind, float tab,
     float scope, float accent, float no_local_fallback) Server_AddEntryEx =
{
    if (sv_entry_count >= SV_MAX_ENTRIES) return;
    sv_entry_label[sv_entry_count] = label;
    sv_entry_cvar [sv_entry_count] = cvarname;
    sv_entry_kind [sv_entry_count] = kind;
    sv_entry_tab  [sv_entry_count] = tab;
    sv_entry_scope[sv_entry_count] = scope;
    sv_entry_accent[sv_entry_count] = accent;
    sv_entry_no_local_fallback[sv_entry_count] = no_local_fallback;
    sv_entry_count = sv_entry_count + 1;
};

void(string cvarname, float kind, float tab) Server_AddEntry =
{
    Server_AddEntryEx(cvarname, cvarname, kind, tab,
        SV_SCOPE_SERVER, FALSE, FALSE);
};

void(string cvarname, float tab) Server_AddToggle =
{
    Server_AddEntry(cvarname, SV_KIND_TOGGLE, tab);
};

void(string cvarname, float tab) Server_AddScalar =
{
    Server_AddEntry(cvarname, SV_KIND_SCALAR, tab);
};

void(string cvarname, float tab) Server_AddEnum =
{
    Server_AddEntry(cvarname, SV_KIND_ENUM, tab);
};

void(string label, string cvarname, float kind, float tab,
     float scope, float accent, float no_local_fallback) Server_AddNamed =
{
    Server_AddEntryEx(label, cvarname, kind, tab, scope, accent, no_local_fallback);
};

void(string text, float tab) Server_AddHeader;  // forward — defined below near multi-enum helpers

string(float idx) Server_GetStringEffective;  // forward

float(float scope, string cvarname) Server_FindEntryIndex =
{
    float i;
    for (i = 0; i < sv_entry_count; i = i + 1)
    {
        if (sv_entry_scope[i] == scope && sv_entry_cvar[i] == cvarname)
            return i;
    }
    return -1;
};

string() Server_LocalRconPasswordText =
{
    float idx = Server_FindEntryIndex(SV_SCOPE_LOCAL, "rcon_password");
    if (idx >= 0 && sv_entry_string_shadow_set[idx])
        return sv_entry_string_shadow[idx];
    return cvar_string("rcon_password");
};

void(string val) Server_MirrorRconPasswordToServerEntry =
{
    float idx = Server_FindEntryIndex(SV_SCOPE_SERVER, "rcon_password");
    if (idx < 0)
        return;

    sv_entry_string_shadow[idx] = val;
    sv_entry_string_shadow_set[idx] = (val != "");
};

string(string line) Server_MapListEntryFromLine =
{
    float argc = tokenize(line);
    if (argc <= 0)
        return "";

    string token = argv(0);
    if (token == "//" || substring(token, 0, 1) == "#")
        return "";

    string lower = strtolower(token);
    float len = strlen(token);

    if (len > 5 && substring(lower, 0, 5) == "maps/")
    {
        token = substring(token, 5, len - 5);
        lower = strtolower(token);
        len = strlen(token);
    }

    if (len > 4 && substring(lower, len - 4, 4) == ".bsp")
        token = substring(token, 0, len - 4);

    return token;
};

string() Server_CurrentMapName =
{
    return serverkey("mapname");
};

string() Server_SelectedCycleMapName =
{
    float count = sv_cycle_maps_loaded ? buf_getsize(sv_cycle_maps) : 0;
    if (count <= 0)
        return "";

    sv_cycle_map_selected = bound(0, sv_cycle_map_selected, count - 1);
    return bufstr_get(sv_cycle_maps, sv_cycle_map_selected);
};

void() Server_LoadCycleMaps =
{
    string preferred = Server_SelectedCycleMapName();
    string current = Server_CurrentMapName();

    if (preferred == "")
        preferred = current;

    if (sv_cycle_maps_loaded)
        buf_del(sv_cycle_maps);

    sv_cycle_maps = buf_create();
    sv_cycle_maps_loaded = TRUE;
    sv_cycle_map_selected = 0;

    filestream f = fopen("cfg/maps.txt", FILE_READ);

    if (f >= 0)
    {
        string line = fgets(f);
        while (line)
        {
            string entry = Server_MapListEntryFromLine(line);
            if (entry != "")
                bufstr_add(sv_cycle_maps, entry, FALSE);
            line = fgets(f);
        }
        fclose(f);
    }

    float count = buf_getsize(sv_cycle_maps);
    if (count <= 0 && current != "")
        bufstr_add(sv_cycle_maps, current, FALSE);

    count = buf_getsize(sv_cycle_maps);
    for (float i = 0; i < count; i = i + 1)
    {
        if (bufstr_get(sv_cycle_maps, i) != preferred)
            continue;

        sv_cycle_map_selected = i;
        break;
    }
};

// Map a manifest tab bitmask to the panel's first matching SV_TAB_*
// ordinal.  Single cvar entries can have multiple TAB bits set (so
// they appear in both the F2 panel and the Create Server menu); for
// the F2 panel we pick the first F2-tab bit in priority order.
// Returns -1 if no F2-panel tab bit is set.
float(float tabs) Server_PanelTabFromMask =
{
         if (tabs & CVAR_TAB_RCON)   return SV_TAB_RCON;
    else if (tabs & CVAR_TAB_MULTI)  return SV_TAB_MULTI;
    else if (tabs & CVAR_TAB_SERVER) return SV_TAB_SERVER;
    else if (tabs & CVAR_TAB_DEBUG)  return SV_TAB_DEBUG;
    else if (tabs & CVAR_TAB_ODE)    return SV_TAB_ODE;
    return -1;
};

void() Server_PanelInit =
{
    if (sv_panel_initialized) return;
    sv_panel_initialized = 1;
    sv_panel_size = '280 360 0';
    sv_panel_pos  = '80 80 0';
    sv_panel_current_tab = SV_TAB_RCON;
    // Explicit init — see cl_debugpanel.qc for why `var float = -1`
    // file-scope initializers can't be relied on.
    sv_active_idx = -1;
    sv_entry_count = 0;
    sv_enum_entry_idx = -1;

    // The Rcon password row appears TWICE on the panel: first as the
    // user's local rcon password (gold accent, LOCAL scope, used to
    // authenticate when the panel is talking to a remote server),
    // then again as the server's rcon_password cvar (the real value
    // an admin can change).  The manifest holds one entry per cvar
    // — the first occurrence is added explicitly here so the row
    // ordering matches the prior hand-written init.
    Server_AddNamed("Rcon Pw",        "rcon_password",  SV_KIND_STRING, SV_TAB_RCON, SV_SCOPE_LOCAL,  TRUE,  FALSE);

    // Walk the manifest.  Entries with any panel tab bit set are
    // forwarded to Server_AddEntryEx with kind/scope/accent/
    // no_local_fallback translated from the CVAR_UI_* / CVAR_FLAG_*
    // fields.  Section transitions inside the ODE tab emit a header
    // (sv_physdrop_* lives in section "Drop Physics" so the writer +
    // panel both naturally separate it from sv_physprop_*).
    string last_section_in_tab[SV_TAB_COUNT];
    float i;
    for (i = 0; i < g_cvar_count; i = i + 1)
    {
        float kind_m = g_cvar_ui_kind[i];
        if (kind_m == CVAR_UI_NONE) continue;
        if (kind_m == CVAR_UI_HEADER) continue;   // headers are emitted by section-change below

        float tabs = g_cvar_ui_tabs[i];
        float tab  = Server_PanelTabFromMask(tabs);
        if (tab < 0) continue;

        // Emit a header row when we cross into a new section within
        // the same panel tab (only currently used for "Drop Physics"
        // in the ODE tab, but the mechanism is general so future
        // sub-sections light up automatically).
        if (last_section_in_tab[tab] != "" &&
            last_section_in_tab[tab] != g_cvar_section[i])
        {
            Server_AddHeader(g_cvar_section[i], tab);
        }
        last_section_in_tab[tab] = g_cvar_section[i];

        float flags = g_cvar_ui_flags[i];
        float scope             = (flags & CVAR_FLAG_SCOPE_LOCAL)        ? SV_SCOPE_LOCAL : SV_SCOPE_SERVER;
        float accent            = (flags & CVAR_FLAG_ACCENT_GOLD)        ? TRUE  : FALSE;
        float no_local_fallback = (flags & CVAR_FLAG_NO_LOCAL_FALLBACK)  ? TRUE  : FALSE;

        // Manifest CVAR_UI_TOGGLE..HEADER are off-by-one from the
        // panel's SV_KIND_* (SV_KIND_TOGGLE=0).  Subtract 1 to map.
        float kind_p = kind_m - 1;

        string label = (g_cvar_ui_label[i] != "") ? g_cvar_ui_label[i] : g_cvar_name[i];

        Server_AddEntryEx(label, g_cvar_name[i], kind_p, tab,
                          scope, accent, no_local_fallback);
    }

    // Pseudo-cvar rows (not real cvars, so not in the manifest).
    // Both live in the RCON tab and target the local engine, not the
    // remote server's cvar table.
    Server_AddNamed("Map",        "__cycle_map",   SV_KIND_ENUM,   SV_TAB_RCON, SV_SCOPE_LOCAL, FALSE, FALSE);
    Server_AddNamed("Change Map", "__changelevel", SV_KIND_ACTION, SV_TAB_RCON, SV_SCOPE_LOCAL, FALSE, FALSE);
};

// =============================================================
//  Helpers
// =============================================================

// Returns 1 if we're connected to a remote server (need rcon),
// 0 if we're hosting / on a listen server (direct cvar set works).
//
// Prefer the engine's serverkey("servername") view of the current
// connection target, with cl_servername as a fallback.  FTE uses the
// synthetic name "internalserver" for in-process listen/singleplayer
// connections; those share a cvar table and can be set directly.
//
// Important: "localhost" is NOT the same as "internalserver" here.
// If the user connected to a separate server process via
// `connect localhost`, that still needs rcon because the server's
// cvar table is remote from the client process.
float() Server_IsRemote =
{
    string s = serverkey("servername");
    if (s == "")
        s = cvar_string("cl_servername");
    if (s == "" || s == "loopback" || s == "internalserver")
        return 0;
    return 1;
};

void(string cmd) Server_RunCommand =
{
    if (Server_IsRemote())
        localcmd(sprintf("rcon %s\n", cmd));
    else
        localcmd(sprintf("%s\n", cmd));
};

// Set a server cvar, choosing direct-set vs rcon based on
// connection state.  rcon needs rcon_password set client-side
// for remote servers; we don't manage that here — user is
// expected to have configured it.
void(string name, string val) Server_Set =
{
    if (Server_IsRemote())
        localcmd(sprintf("rcon %s %s\n", name, val));
    else
        localcmd(sprintf("%s %s\n", name, val));
};

string(string val) Server_EscapeCommandArg =
{
    val = strreplace("\\", "\\\\", val);
    val = strreplace("\"", "\\\"", val);
    return val;
};

void(string name, string val) Server_SetQuoted =
{
    val = Server_EscapeCommandArg(val);
    if (Server_IsRemote())
        localcmd(sprintf("rcon %s \"%s\"\n", name, val));
    else
        localcmd(sprintf("%s \"%s\"\n", name, val));
};

void(string name, float v) Server_SetFloat =
{
    Server_Set(name, sprintf("%g", v));
};

void(string name, string val) Server_SetLocalQuoted =
{
    // Client-local settings like rcon_password should be set directly
    // so CSQC sees the new value immediately and we don't depend on the
    // engine's console command parser treating the name as a settable cvar.
    cvar_set(name, val);
};

void(string name, float v) Server_SetLocalFloat =
{
    localcmd(sprintf("%s %g\n", name, v));
};

void(float idx, float v) Server_SetEntryValue =
{
    float send_v = v;
    if (idx < 0 || idx >= SV_MAX_ENTRIES) return;
    if (sv_entry_cvar[idx] == "__cycle_map")
    {
        float count = sv_cycle_maps_loaded ? buf_getsize(sv_cycle_maps) : 0;
        if (count <= 0)
        {
            sv_cycle_map_selected = 0;
            return;
        }
        sv_cycle_map_selected = bound(0, floor(v + 0.5), count - 1);
        return;
    }
    if (sv_entry_cvar[idx] == "sv_mintic" && v > 0)
        send_v = 1.0 / v;
    if (sv_entry_scope[idx] == SV_SCOPE_LOCAL)
    {
        Server_SetLocalFloat(sv_entry_cvar[idx], send_v);
        if (sv_entry_cvar[idx] == "sv_mintic")
            Server_SetLocalFloat("sv_maxtic", send_v);
        return;
    }
    sv_entry_shadow[idx]     = send_v;
    sv_entry_shadow_set[idx] = 1;
    sv_entry_string_shadow[idx] = sprintf("%g", send_v);
    sv_entry_string_shadow_set[idx] = 1;
    Server_SetFloat(sv_entry_cvar[idx], send_v);
    if (sv_entry_cvar[idx] == "sv_mintic")
        Server_SetFloat("sv_maxtic", send_v);
};

void(float idx, string val) Server_SetEntryString =
{
    if (idx < 0 || idx >= SV_MAX_ENTRIES) return;
    if (sv_entry_scope[idx] == SV_SCOPE_LOCAL)
    {
        // Some client-side cvars (notably rcon_password) may not echo
        // their value back through cvar_string for security/privacy
        // reasons, so keep the typed text as the panel's source of truth.
        sv_entry_string_shadow[idx] = val;
        sv_entry_string_shadow_set[idx] = 1;
        if (sv_entry_cvar[idx] == "rcon_password")
            Server_MirrorRconPasswordToServerEntry(val);
        Server_SetLocalQuoted(sv_entry_cvar[idx], val);
        return;
    }
    sv_entry_string_shadow[idx] = val;
    sv_entry_string_shadow_set[idx] = 1;
    if (sv_entry_cvar[idx] == "rcon_password")
        Server_SetQuoted("sv_rcon_password_shadow", val);
    Server_SetQuoted(sv_entry_cvar[idx], val);
};

void(float idx) Server_FireEntryAction =
{
    if (idx < 0 || idx >= SV_MAX_ENTRIES) return;
    if (sv_entry_cvar[idx] == "__changelevel")
    {
        string selected_map = Server_SelectedCycleMapName();
        if (selected_map != "")
            Server_RunCommand(sprintf("changelevel %s", selected_map));
        return;
    }
    if (sv_entry_cvar[idx] == "sv_roundrestart")
    {
        Server_RunCommand("restartround");
        return;
    }
    if (sv_entry_cvar[idx] == "sv_writecvars")
    {
        Server_RunCommand("writecvars");
        return;
    }
    if (sv_entry_cvar[idx] == "sv_saveconfig")
    {
        float rcon_idx = Server_FindEntryIndex(SV_SCOPE_SERVER, "rcon_password");
        string save_pw = "";
        if (rcon_idx >= 0)
            save_pw = Server_GetStringEffective(rcon_idx);
        if (save_pw == "")
            save_pw = Server_LocalRconPasswordText();
        if (save_pw != "")
            Server_SetQuoted("sv_rcon_password_shadow", save_pw);
    }
    if (sv_entry_scope[idx] == SV_SCOPE_LOCAL)
        Server_SetLocalFloat(sv_entry_cvar[idx], 1);
    else
        Server_SetFloat(sv_entry_cvar[idx], 1);
};

// Commit the in-progress scalar edit buffer to its cvar AND update
// the shadow so the display reflects the new value immediately
// (without waiting for the rcon round-trip + serverinfo push, if
// any, on remote).  Caller is responsible for clearing sv_active_idx.
void(float idx) Server_CommitEdit =
{
    if (idx < 0 || idx >= SV_MAX_ENTRIES) return;
    if (sv_entry_kind[idx] == SV_KIND_STRING)
        Server_SetEntryString(idx, sv_edit_text);
    else
        Server_SetEntryValue(idx, stof(sv_edit_text));
};

// Read a server cvar's effective value.  On listen, the local cvar
// IS the server's value.  On remote, prefer serverkey() (server-
// pushed serverinfo from sv_main.qc SV_UpdateMovementServerInfo)
// since the local cvar may be stale or unset.
float(string name) Server_GetFloat =
{
    string s = serverkey(name);
    if (s != "")
        return stof(s);
    return cvar(name);
};

string(string name) Server_GetString =
{
    string s = serverkey(name);
    if (s != "")
        return s;
    return cvar_string(name);
};

// Per-entry effective read for the panel.  Layered as:
//   1. server-pushed serverinfo (server's truth)  → clear shadow + return
//   2. optimistic shadow (last user click)         → return cached value
//   3. local cvar                                  → fallback
//
// Lets toggles flip correctly on dedicated servers where the cvar
// isn't replicated: the shadow remembers what the user just sent
// via rcon so the button reflects the new state instead of staying
// stuck reading 0 from the unrelated local cvar.
float(float idx) Server_GetEffective =
{
    string cn = sv_entry_cvar[idx];
    if (sv_entry_scope[idx] == SV_SCOPE_LOCAL)
        return cvar(cn);

    string s  = serverkey(cn);
    if (s != "")
    {
        // Server replicated this — trust it, drop the shadow.
        sv_entry_shadow_set[idx] = 0;
        sv_entry_string_shadow_set[idx] = 0;
        return stof(s);
    }
    if (sv_entry_shadow_set[idx])
        return sv_entry_shadow[idx];
    if (Server_IsRemote() && sv_entry_no_local_fallback[idx])
        return 0;
    return cvar(cn);
};

string(float idx) Server_GetStringEffective =
{
    string cn = sv_entry_cvar[idx];
    if (sv_entry_scope[idx] == SV_SCOPE_LOCAL)
    {
        if (sv_entry_string_shadow_set[idx])
            return sv_entry_string_shadow[idx];
        return cvar_string(cn);
    }

    string s = serverkey(cn);
    if (s != "")
    {
        sv_entry_shadow_set[idx] = 0;
        sv_entry_string_shadow_set[idx] = 0;
        return s;
    }
    if (sv_entry_string_shadow_set[idx])
        return sv_entry_string_shadow[idx];
    if (cn == "rcon_password")
    {
        string local_pw = Server_LocalRconPasswordText();
        if (local_pw != "")
            return local_pw;
    }
    if (Server_IsRemote() && sv_entry_no_local_fallback[idx])
        return "";
    return cvar_string(cn);
};

float(float gm) Server_GamemodeIndex =
{
    // Clamp to the highest gamemode constant so newly-added modes
    // (e.g. Paintgun) don't get truncated to FFA — that was the
    // source of the F2 panel showing "Free For All" while the
    // server was actually running Paintgun.  Update this bound
    // whenever a new GAMEMODE_* is added.
    return bound(GAMEMODE_TDM, floor(gm + 0.5), GAMEMODE_PROPHUNT);
};

string(float gm) Server_GamemodeLabel =
{
    gm = Server_GamemodeIndex(gm);
    if (gm == GAMEMODE_ELIMINATION)
        return "Elimination";
    if (gm == GAMEMODE_BHOP)
        return "Bhop";
    if (gm == GAMEMODE_FFA)
        return "Free For All";
    if (gm == GAMEMODE_PAINTGUN)
        return "Paintball";
    if (gm == GAMEMODE_DEFUSE)
        return "Defuse";
    if (gm == GAMEMODE_PROPHUNT)
        return "Prop Hunt";
    return "Team Deathmatch";
};

float(float mintic) Server_TickrateValueFromMintic =
{
    float i;
    float best_value = sv_tickrate_values[0];
    float best_diff = 999999;
    float tickrate;

    if (mintic <= 0)
        return best_value;

    tickrate = 1.0 / mintic;
    for (i = 0; i < sv_tickrate_values.length; i = i + 1)
    {
        float diff = fabs(sv_tickrate_values[i] - tickrate);
        if (diff < best_diff)
        {
            best_diff = diff;
            best_value = sv_tickrate_values[i];
        }
    }
    return best_value;
};

float(float tickrate) Server_TickrateFindIndex =
{
    float i;
    for (i = 0; i < sv_tickrate_values.length; i = i + 1)
        if (sv_tickrate_values[i] == tickrate)
            return i;
    return 0;
};

// Lookup the enum source for an entry: the manifest's g_cvar_ui_enum
// for real cvars, plus hardcoded CVAR_ENUM_MAP_CYCLE for the pseudo-
// cvar `__cycle_map` (which isn't in the manifest because it doesn't
// correspond to a real cvar).
float(float idx) Server_EntryEnumSource =
{
    if (idx < 0 || idx >= sv_entry_count)
        return CVAR_ENUM_NONE;
    if (sv_entry_cvar[idx] == "__cycle_map")
        return CVAR_ENUM_MAP_CYCLE;
    float mi = CVar_FindIndex(sv_entry_cvar[idx]);
    if (mi < 0) return CVAR_ENUM_NONE;
    return g_cvar_ui_enum[mi];
};

// Loadout slot index used by Server_LoadoutOption* helpers below.
// Derived from the manifest's enum source so adding a new loadout
// slot is one line in the manifest + one branch in the helpers.
float(float idx) Server_EntryLoadoutKind =
{
    float src = Server_EntryEnumSource(idx);
    if (src == CVAR_ENUM_LOADOUT_PRIMARY)   return 0;
    if (src == CVAR_ENUM_LOADOUT_SECONDARY) return 1;
    if (src == CVAR_ENUM_LOADOUT_MELEE)     return 2;
    if (src == CVAR_ENUM_LOADOUT_UTILITY)   return 3;
    return -1;
};

float(float loadout_kind) Server_LoadoutOptionCount =
{
    if (loadout_kind == 0) return WeaponManifest_LoadoutCount(WMF_SLOT_PRIMARY);
    if (loadout_kind == 1) return WeaponManifest_LoadoutCount(WMF_SLOT_SECONDARY);
    if (loadout_kind == 2) return WeaponManifest_LoadoutCount(WMF_SLOT_MELEE);
    if (loadout_kind == 3) return WeaponManifest_LoadoutCount(WMF_SLOT_UTILITY);
    return 0;
};

float(float loadout_kind, float option_index) Server_LoadoutOptionId =
{
    if (loadout_kind == 0) return WeaponManifest_LoadoutWeapon(WMF_SLOT_PRIMARY, option_index);
    if (loadout_kind == 1) return WeaponManifest_LoadoutWeapon(WMF_SLOT_SECONDARY, option_index);
    if (loadout_kind == 2) return WeaponManifest_LoadoutWeapon(WMF_SLOT_MELEE, option_index);
    if (loadout_kind == 3) return WeaponManifest_LoadoutWeapon(WMF_SLOT_UTILITY, option_index);
    return 0;
};

string(float loadout_kind, float option_index) Server_LoadoutOptionLabel =
{
    if (loadout_kind == 0) return WeaponManifest_LoadoutLabel(WMF_SLOT_PRIMARY, option_index);
    if (loadout_kind == 1) return WeaponManifest_LoadoutLabel(WMF_SLOT_SECONDARY, option_index);
    if (loadout_kind == 2) return WeaponManifest_LoadoutLabel(WMF_SLOT_MELEE, option_index);
    if (loadout_kind == 3) return WeaponManifest_LoadoutLabel(WMF_SLOT_UTILITY, option_index);
    return "";
};

float(float loadout_kind, float weapon_id) Server_LoadoutFindIndex =
{
    if (loadout_kind == 0) return WeaponManifest_LoadoutFindIndex(WMF_SLOT_PRIMARY, weapon_id);
    if (loadout_kind == 1) return WeaponManifest_LoadoutFindIndex(WMF_SLOT_SECONDARY, weapon_id);
    if (loadout_kind == 2) return WeaponManifest_LoadoutFindIndex(WMF_SLOT_MELEE, weapon_id);
    if (loadout_kind == 3) return WeaponManifest_LoadoutFindIndex(WMF_SLOT_UTILITY, weapon_id);
    return 0;
};

// Enum-source-keyed dispatch.  All four helpers below switch on the
// CVAR_ENUM_* id that the manifest associated with the cvar (or the
// hardcoded value Server_EntryEnumSource returns for pseudo-cvars).
// Adding a new enum source = adding a constant in sh_cvar_table.qc
// + one branch in each helper.
float(float idx) Server_EntryOptionCount =
{
    if (idx < 0 || idx >= sv_entry_count) return 0;
    float src = Server_EntryEnumSource(idx);
    if (src == CVAR_ENUM_MAP_CYCLE) return sv_cycle_maps_loaded ? buf_getsize(sv_cycle_maps) : 0;
    if (src == CVAR_ENUM_TICKRATE)  return sv_tickrate_values.length;
    if (src == CVAR_ENUM_GAMEMODE)  return 7;
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind >= 0)          return Server_LoadoutOptionCount(loadout_kind);
    return 0;
};

float(float idx, float option_index) Server_EntryOptionValue =
{
    if (idx < 0 || idx >= sv_entry_count) return 0;
    float src = Server_EntryEnumSource(idx);
    if (src == CVAR_ENUM_MAP_CYCLE) return option_index;
    if (src == CVAR_ENUM_TICKRATE)  return sv_tickrate_values[option_index];
    if (src == CVAR_ENUM_GAMEMODE)  return option_index;
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind >= 0)          return Server_LoadoutOptionId(loadout_kind, option_index);
    return 0;
};

string(float idx, float option_index) Server_EntryOptionLabel =
{
    if (idx < 0 || idx >= sv_entry_count) return "";
    float src = Server_EntryEnumSource(idx);
    if (src == CVAR_ENUM_MAP_CYCLE) return bufstr_get(sv_cycle_maps, option_index);
    if (src == CVAR_ENUM_TICKRATE)  return sv_tickrate_labels[option_index];
    if (src == CVAR_ENUM_GAMEMODE)  return Server_GamemodeLabel(option_index);
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind >= 0)          return Server_LoadoutOptionLabel(loadout_kind, option_index);
    return "";
};

float(float idx) Server_EntryCurrentEnumValue =
{
    if (idx < 0 || idx >= sv_entry_count) return 0;
    float src = Server_EntryEnumSource(idx);
    if (src == CVAR_ENUM_MAP_CYCLE)
    {
        float count = sv_cycle_maps_loaded ? buf_getsize(sv_cycle_maps) : 0;
        if (count <= 0) return 0;
        sv_cycle_map_selected = bound(0, sv_cycle_map_selected, count - 1);
        return sv_cycle_map_selected;
    }
    if (src == CVAR_ENUM_TICKRATE) return Server_TickrateValueFromMintic(Server_GetEffective(idx));
    if (src == CVAR_ENUM_GAMEMODE) return Server_GamemodeIndex(Server_GetEffective(idx));
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind >= 0)
        return Weapon_IdFromStringOrDefault(Server_GetStringEffective(idx), WEP_NONE);
    return 0;
};

string(float idx) Server_EntryCurrentEnumLabel =
{
    if (idx < 0 || idx >= sv_entry_count) return "";
    float src = Server_EntryEnumSource(idx);
    float current_value = Server_EntryCurrentEnumValue(idx);
    if (src == CVAR_ENUM_MAP_CYCLE)
    {
        float count = sv_cycle_maps_loaded ? buf_getsize(sv_cycle_maps) : 0;
        if (count <= 0) return "(none)";
        return bufstr_get(sv_cycle_maps, current_value);
    }
    if (src == CVAR_ENUM_TICKRATE) return sv_tickrate_labels[Server_TickrateFindIndex(current_value)];
    if (src == CVAR_ENUM_GAMEMODE) return Server_GamemodeLabel(current_value);
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind >= 0)
        return Server_LoadoutOptionLabel(loadout_kind,
            Server_LoadoutFindIndex(loadout_kind, current_value));
    return "";
};

// -------- Multi-select enum (SV_KIND_ENUM_MULTI) --------
// Read the cvar value, parse as comma-separated weapon-id list, and
// return a bitmask of option indices (bit i set = option i checked).
float(float idx) Server_EntryEnumMultiMask =
{
    if (idx < 0 || idx >= sv_entry_count)
        return 0;
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind < 0)
        return 0;

    string list = Server_GetStringEffective(idx);
    if (list == "")
        return 0;

    float n = tokenizebyseparator(list, ",");
    float mask = 0;
    float i;
    for (i = 0; i < n; i++)
    {
        float wep_id = Weapon_IdFromStringOrDefault(argv(i), WEP_NONE);
        float opt    = Server_LoadoutFindIndex(loadout_kind, wep_id);
        float opt_count = Server_LoadoutOptionCount(loadout_kind);
        if (opt < 0 || opt >= opt_count)
            continue;
        mask = mask | pow(2, opt);
    }
    return mask;
};

// Build a comma-separated weapon-id list from a bitmask of option
// indices and write it back to the entry's cvar.  Empty mask becomes
// "0" (PlayerSpawn falls back to WEP_NONE).
void(float idx, float mask) Server_EntryEnumMultiSetMask =
{
    if (idx < 0 || idx >= sv_entry_count)
        return;
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind < 0)
        return;

    float opt_count = Server_LoadoutOptionCount(loadout_kind);
    string out = "";
    float n_set = 0;
    float i;
    for (i = 0; i < opt_count; i++)
    {
        if (!(mask & pow(2, i)))
            continue;
        float wep_id = Server_LoadoutOptionId(loadout_kind, i);
        if (n_set == 0)
            out = ftos(wep_id);
        else
            out = strcat(out, ",", ftos(wep_id));
        n_set++;
    }
    Server_SetEntryString(idx, n_set ? out : "0");
};

// Summary label for the closed-dropdown button.  "(none)" / one or
// two names joined / "N selected" for three+.
string(float idx) Server_EntryEnumMultiSummary =
{
    if (idx < 0 || idx >= sv_entry_count)
        return "(none)";
    float loadout_kind = Server_EntryLoadoutKind(idx);
    if (loadout_kind < 0)
        return "(none)";

    float mask = Server_EntryEnumMultiMask(idx);
    float opt_count = Server_LoadoutOptionCount(loadout_kind);
    float i, n_set = 0;
    string out = "";
    for (i = 0; i < opt_count; i++)
    {
        if (!(mask & pow(2, i)))
            continue;
        if (n_set == 0)
            out = Server_LoadoutOptionLabel(loadout_kind, i);
        else if (n_set < 2)
            out = strcat(out, ", ", Server_LoadoutOptionLabel(loadout_kind, i));
        n_set++;
    }
    if (n_set == 0)
        return "(none)";
    if (n_set > 2)
        return sprintf("%g selected", n_set);
    return out;
};

// -------- Section header (SV_KIND_HEADER) --------
// Adds a non-interactive separator row that displays `text` as a bold
// label.  Stored in sv_entry_cvar so the row dispatcher can read it
// without adding a new parallel array.
void(string text, float tab) Server_AddHeader =
{
    Server_AddEntryEx(text, text, SV_KIND_HEADER, tab,
        SV_SCOPE_LOCAL, FALSE, FALSE);
};

// =============================================================
//  Toggle / open / close
// =============================================================

float() Server_PanelOpen = { return sv_panel_open; };

void() Server_PanelToggle =
{
    Server_PanelInit();
    sv_panel_open = !sv_panel_open;
    sv_enum_open = 0;
    sv_enum_entry_idx = -1;

    if (sv_panel_open)
    {
        Server_LoadCycleMaps();
        Server_MirrorRconPasswordToServerEntry(Server_LocalRconPasswordText());
    }

    if (sv_panel_open && !sv_cursor_active)
    {
        setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
        sv_cursor_active = 1;
    }
    else if (!sv_panel_open && sv_cursor_active)
    {
        // Commit any in-progress scalar edit so the user's typing
        // isn't lost when they F2 / Esc out mid-edit.
        if (sv_active_idx >= 0)
        {
            Server_CommitEdit(sv_active_idx);
            sv_active_idx = -1;
        }
        setcursormode(FALSE);
        sv_cursor_active = 0;
    }
};

float(float evtype, float scanx, float chary, float devid) Server_PanelInputEvent =
{
    if (!sv_panel_open) return FALSE;

    if (evtype == IE_KEYDOWN && scanx == K_F2)
    {
        Server_PanelToggle();
        return TRUE;
    }
    if (evtype == IE_KEYDOWN && scanx == K_ESCAPE)
    {
        Server_PanelToggle();
        return TRUE;
    }

    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};

// =============================================================
//  Title bar — drag region, close, target indicator
// =============================================================
string() Server_TitleString =
{
    if (Server_IsRemote())
        return "Server Panel  (rcon)";
    return "Server Panel";
};

void() Server_DrawTitleBar =
{
    sui_push_frame([0, 0], [sv_panel_size_x, SV_TITLE_H]);

    sui_fill([0, 0], [sv_panel_size_x, SV_TITLE_H], SV_TITLE_BG, 1, 0);
    sui_fill([0, SV_TITLE_H - 1], [sv_panel_size_x, 1], SV_BORDER, 1, 0);

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    vector tcol = Server_IsRemote() ? SV_TEXT_REMOTE : SV_TEXT_1;
    sui_text([8, 9], SV_FONT, Server_TitleString(), tcol, 1, 0);

    float close_w = SV_TITLE_H;
    sui_action_element([0, 0],
        [sv_panel_size_x - close_w, SV_TITLE_H],
        "sv_titlebar", sui_noop);

    if (Debug_Button("sv_close",
        [sv_panel_size_x - close_w, 0],
        [close_w, SV_TITLE_H],
        "X", SV_BTN_CLOSE, SV_BTN_CLOSE_BORD))
    {
        Server_PanelToggle();
    }

    sui_pop_frame();
};

void() Server_HandleDrag =
{
    float held = sui_is_held("sv_titlebar");

    if (held && !sv_panel_dragging)
    {
        sv_panel_dragging = 1;
        sv_panel_drag_offset_x = _cursor_position_x - sv_panel_pos_x;
        sv_panel_drag_offset_y = _cursor_position_y - sv_panel_pos_y;
    }

    if (held && sv_panel_dragging)
    {
        sv_panel_pos_x = _cursor_position_x - sv_panel_drag_offset_x;
        sv_panel_pos_y = _cursor_position_y - sv_panel_drag_offset_y;
        if (sv_panel_pos_x < -sv_panel_size_x + 80)
            sv_panel_pos_x = -sv_panel_size_x + 80;
        if (sv_panel_pos_x > g_width - 80)
            sv_panel_pos_x = g_width - 80;
        if (sv_panel_pos_y < 0)
            sv_panel_pos_y = 0;
        if (sv_panel_pos_y > g_height - SV_TITLE_H)
            sv_panel_pos_y = g_height - SV_TITLE_H;
    }

    if (!held)
        sv_panel_dragging = 0;
};

// =============================================================
//  Tab strip
// =============================================================
void(string label, float tab_id, float x, float w) Server_DrawOneTab =
{
    string id = sprintf("sv_tab_%g", tab_id);
    vector col, bord;
    if (sv_panel_current_tab == tab_id)
    {
        col  = SV_BTN_ACTIVE;
        bord = SV_BTN_ACTIVE_BORD;
    }
    else
    {
        col  = SV_BTN_OFF;
        bord = SV_BTN_OFF_BORD;
    }

    if (Debug_Button(id, [x, 3], [w, SV_TAB_STRIP_H - 6], label, col, bord))
    {
        if (sv_panel_current_tab != tab_id)
        {
            if (sv_active_idx >= 0)
            {
                Server_CommitEdit(sv_active_idx);
                sv_active_idx = -1;
            }
            sv_panel_current_tab = tab_id;
            sv_panel_scroll_offset = '0 0 0';
            sv_enum_open = 0;
            sv_enum_entry_idx = -1;
        }
    }
};

void() Server_DrawTabStrip =
{
    float y0 = SV_TITLE_H;
    sui_push_frame([0, y0], [sv_panel_size_x, SV_TAB_STRIP_H]);
    sui_fill([0, 0], [sv_panel_size_x, SV_TAB_STRIP_H], SV_TAB_BG, 1, 0);
    sui_fill([0, SV_TAB_STRIP_H - 1], [sv_panel_size_x, 1], SV_BORDER, 1, 0);

    // Five tabs, evenly distributed across the available width.
    // Each tab is `tab_w` wide with `gap` between.  We compute tab_w
    // from the panel width so it adapts to resize.
    float gap = 2;
    float total_inset = SV_PAD * 2;
    float available   = sv_panel_size_x - total_inset - gap * (SV_TAB_COUNT - 1);
    float tab_w       = floor(available / SV_TAB_COUNT);
    if (tab_w < 32) tab_w = 32;   // minimum readable width

    float x = SV_PAD;
    Server_DrawOneTab("Rcon",   SV_TAB_RCON,   x, tab_w); x += tab_w + gap;
    Server_DrawOneTab("Multi",  SV_TAB_MULTI,  x, tab_w); x += tab_w + gap;
    Server_DrawOneTab("Server", SV_TAB_SERVER, x, tab_w); x += tab_w + gap;
    Server_DrawOneTab("Debug",  SV_TAB_DEBUG,  x, tab_w); x += tab_w + gap;
    Server_DrawOneTab("Phys",   SV_TAB_ODE,    x, tab_w);

    sui_pop_frame();
};

void() Server_DrawEnumOverlay =
{
    if (!sv_panel_open || !sv_enum_open || !sv_enum_visible
        || sv_enum_entry_idx < 0)
        return;

    float entry_idx = sv_enum_entry_idx;
    float kind = sv_entry_kind[entry_idx];
    float is_multi = (kind == SV_KIND_ENUM_MULTI);
    float current_value = is_multi ? 0 : Server_EntryCurrentEnumValue(entry_idx);
    float multi_mask = is_multi ? Server_EntryEnumMultiMask(entry_idx) : 0;
    float option_count = Server_EntryOptionCount(entry_idx);
    float item_h = 20;
    float list_h = item_h * option_count + 4;
    vector list_pos = [sv_enum_button_pos_x, sv_enum_button_pos_y + sv_enum_button_size_y + 2];

    if (list_pos_y + list_h > g_height - 4)
        list_pos_y = max(4, sv_enum_button_pos_y - list_h - 2);

    sui_push_frame(list_pos, [sv_enum_button_size_x, list_h]);
    sui_fill([0, 0], [sv_enum_button_size_x, list_h], SV_BG, 0.96, 0);
    sui_border_box([0, 0], [sv_enum_button_size_x, list_h], 1, SV_BORDER, 1, 0);

    for (float option_index = 0; option_index < option_count; option_index = option_index + 1)
    {
        float option_value = Server_EntryOptionValue(entry_idx, option_index);
        float bit = is_multi ? pow(2, option_index) : 0;
        float checked = is_multi ? ((multi_mask & bit) ? 1 : 0)
                                 : (option_value == current_value);
        vector col  = checked ? SV_BTN_ACTIVE      : SV_BTN_OFF;
        vector bord = checked ? SV_BTN_ACTIVE_BORD : SV_BTN_OFF_BORD;
        string label = is_multi
            ? strcat(checked ? "[x] " : "[ ] ", Server_EntryOptionLabel(entry_idx, option_index))
            : Server_EntryOptionLabel(entry_idx, option_index);

        if (!Debug_Button(sprintf("sv_enum_item_%g_%g", entry_idx, option_index),
            [2, 2 + option_index * item_h],
            [sv_enum_button_size_x - 4, item_h - 2],
            label, col, bord))
            continue;

        if (is_multi)
        {
            // Toggle just this bit; keep dropdown open so the user can
            // pick more options.
            float new_mask = checked ? (multi_mask - bit) : (multi_mask + bit);
            Server_EntryEnumMultiSetMask(entry_idx, new_mask);
            multi_mask = new_mask;
            // Don't return — let other rows respond to clicks on the
            // same frame (Debug_Button only reports the row that was
            // actually clicked, so the rest of the loop is no-ops).
            continue;
        }

        Server_SetEntryValue(entry_idx, option_value);
        sv_enum_open = 0;
        sv_enum_entry_idx = -1;
        sui_pop_frame();
        return;
    }

    sui_pop_frame();
};

// =============================================================
//  Body — scrollable list filtered by current tab
// =============================================================
void() Server_DrawBody =
{
    float body_y0 = SV_TITLE_H + SV_TAB_STRIP_H;
    float body_h  = sv_panel_size_y - body_y0 - SV_GRIP_SIZE;
    float body_w  = sv_panel_size_x;

    sui_push_frame([0, body_y0], [body_w, body_h]);
    sui_fill([0, 0], [body_w, body_h], SV_BG_DARKER, 1, 0);

    // Count visible rows (those whose tab matches sv_panel_current_tab).
    float visible_rows = 0;
    float i;
    for (i = 0; i < sv_entry_count; i = i + 1)
    {
        if (sv_entry_tab[i] == sv_panel_current_tab)
            visible_rows = visible_rows + 1;
    }

    float content_h = visible_rows * SV_ROW_H;

    sui_scroll_view_begin("sv_body_scroll",
        [0, 0],
        [body_w, body_h],
        [body_w - SV_VBAR_W, content_h],
        sv_panel_scroll_offset,
        [0, SV_VBAR_W]);

    float row_w     = body_w - SV_VBAR_W - SV_PAD * 2;
    float y         = 0;
    float vp_top    = sv_panel_scroll_offset_y - SV_ROW_H;
    float vp_bottom = sv_panel_scroll_offset_y + body_h + SV_ROW_H;
    sv_enum_visible = 0;

    for (i = 0; i < sv_entry_count; i = i + 1)
    {
        if (sv_entry_tab[i] != sv_panel_current_tab)
            continue;

        float kind  = sv_entry_kind[i];
        float row_y = y;

        if (row_y + SV_ROW_H < vp_top || row_y > vp_bottom)
        {
            y = y + SV_ROW_H;
            continue;
        }

        // Reset alignment per-iteration — see cl_debugpanel.qc for
        // full rationale.  Without this, a leaked CENTER alignment
        // from a previous scalar's input frame can drift the next
        // toggle's button into wrong screen coords.
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

        if (kind == SV_KIND_TOGGLE)
        {
            string cn  = sv_entry_cvar[i];
            float  v   = Server_GetEffective(i);
            string lab = sprintf("%s : %s", sv_entry_label[i],
                                  v ? "On" : "Off");
            vector col   = v ? SV_BTN_ON       : SV_BTN_OFF;
            vector bord  = v ? SV_BTN_ON_BORD  : SV_BTN_OFF_BORD;
            string id    = sprintf("sv_t_%s", cn);

            if (Debug_Button(id,
                [SV_PAD, row_y + 1],
                [row_w, SV_ROW_H - 2],
                lab, col, bord))
            {
                float new_v = v ? 0 : 1;
                sv_enum_open = 0;
                // Update the optimistic shadow first so the next
                // frame renders the new state immediately, even
                // before any rcon round-trip lands.
                Server_SetEntryValue(i, new_v);
            }
        }
        else if (kind == SV_KIND_ACTION)
        {
            if (Debug_Button(sprintf("sv_a_%s", sv_entry_cvar[i]),
                [SV_PAD, row_y + 1],
                [row_w, SV_ROW_H - 2],
                sv_entry_label[i], SV_BTN_ACTIVE, SV_BTN_ACTIVE_BORD))
            {
                sv_enum_open = 0;
                Server_FireEntryAction(i);
            }
        }
        else if (kind == SV_KIND_ENUM || kind == SV_KIND_ENUM_MULTI)
        {
            float enum_input_w = floor(row_w * 0.5);
            float enum_lbl_w   = row_w - enum_input_w;
            float option_count = Server_EntryOptionCount(i);
            string id_btn = sprintf("sv_e_%g", i);
            float this_open = (sv_enum_open && sv_enum_entry_idx == i);
            vector btn_col = this_open ? SV_BTN_ACTIVE : SV_BTN_OFF;
            vector btn_bord = this_open ? SV_BTN_ACTIVE_BORD : SV_BTN_OFF_BORD;

            sui_text([SV_PAD + 4, row_y + 6], SV_FONT,
                     sv_entry_label[i], SV_TEXT_2, 1, 0);

            if (this_open)
            {
                sv_enum_visible = 1;
                sv_enum_button_pos  = sv_panel_pos + [SV_PAD + enum_lbl_w, body_y0 + row_y + 1];
                sv_enum_button_size = [enum_input_w, SV_ROW_H - 2];
            }

            string btn_label = (kind == SV_KIND_ENUM_MULTI)
                ? Server_EntryEnumMultiSummary(i)
                : Server_EntryCurrentEnumLabel(i);

            if (Debug_Button(id_btn,
                [SV_PAD + enum_lbl_w, row_y + 1],
                [enum_input_w, SV_ROW_H - 2],
                strcat(btn_label, this_open ? " -" : " v"),
                btn_col, btn_bord))
            {
                if (option_count <= 0)
                {
                    y = y + SV_ROW_H;
                    continue;
                }
                if (sv_active_idx >= 0)
                {
                    Server_CommitEdit(sv_active_idx);
                    sv_active_idx = -1;
                }
                if (this_open)
                {
                    sv_enum_open = 0;
                    sv_enum_entry_idx = -1;
                }
                else
                {
                    sv_enum_open = 1;
                    sv_enum_entry_idx = i;
                    sv_enum_visible = 1;
                    sv_enum_button_pos  = sv_panel_pos + [SV_PAD + enum_lbl_w, body_y0 + row_y + 1];
                    sv_enum_button_size = [enum_input_w, SV_ROW_H - 2];
                }
            }
        }
        else if (kind == SV_KIND_HEADER)
        {
            // Bold separator row.  Slightly taller-feeling via a subtle
            // background tint so the eye picks out the section break in
            // a long scroll list.
            sui_fill([SV_PAD, row_y + 1], [row_w, SV_ROW_H - 2], '0.10 0.12 0.14', 0.85, 0);
            sui_text([SV_PAD + 6, row_y + 6], SV_FONT,
                     sv_entry_label[i], SV_GOLD_TEXT, 1, 0);
        }
        else // SV_KIND_SCALAR or SV_KIND_STRING
        {
            string sc_cn = sv_entry_cvar[i];
            float is_string = (kind == SV_KIND_STRING);
            float is_accent = sv_entry_accent[i];

            float input_w = floor(row_w * 0.5);
            float lbl_w   = row_w - input_w;

            sui_text([SV_PAD + 4, row_y + 6], SV_FONT,
                     sv_entry_label[i], is_accent ? SV_GOLD_TEXT : SV_TEXT_2, 1, 0);

            string id_input = sprintf("sv_s_%g", i);
            float input_x = SV_PAD + lbl_w;
            float input_h = SV_ROW_H - 2;

            sui_push_frame([input_x, row_y + 1], [input_w, input_h]);

            // Background uses pre-call active state.  See the matching
            // comment in cl_debugpanel.qc for the full rationale.
            float was_active = (sv_active_idx == i);
            vector inp_bg;
            vector inp_bord;
            if (is_accent)
            {
                inp_bg   = was_active ? SV_GOLD_ACTIVE_BG : SV_GOLD_BG;
                inp_bord = was_active ? SV_GOLD_ACTIVE_BORDER : SV_GOLD_BORDER;
            }
            else
            {
                inp_bg   = was_active ? '0.15 0.16 0.18' : SV_INPUT_BG;
                inp_bord = was_active ? '0.45 0.50 0.55' : SV_BORDER;
            }
            sui_fill([0, 0], [input_w, input_h], inp_bg, 0.85, 0);
            sui_border_box([0, 0], [input_w, input_h], 1, inp_bord, 1, 0);

            // Always call sui_text_input with the global buffer — the
            // earlier dummy-buffer-when-unfocused split caused typed
            // chars to vanish on the first click frame.
            //
            // sui_reread_input(): the surrounding scroll view drains
            // the input buffer when hovered (for mousewheel scroll),
            // so without rewinding _input_index, sui_text_input has
            // nothing left to read and typing only works when the
            // cursor is OFF the panel.  See cl_debugpanel.qc.
            sui_reread_input();
            sui_text_input(id_input, [3, 0], [input_w - 6, input_h],
                sv_edit_text, sv_edit_cursor);
            sui_cap_input_length(is_string ? 64 : 12, sv_edit_text, sv_edit_cursor);

            float now_focused = sui_is_last_clicked(id_input);

            if (now_focused && !was_active)
            {
                sv_enum_open = 0;
                sv_enum_entry_idx = -1;
                if (sv_active_idx >= 0)
                    Server_CommitEdit(sv_active_idx);
                sv_active_idx  = i;
                if (is_string)
                    sv_edit_text = Server_GetStringEffective(i);
                else
                    sv_edit_text = ftos(Server_GetEffective(i));
                sv_edit_cursor = strlen(sv_edit_text);
            }
            else if (!now_focused && was_active)
            {
                Server_CommitEdit(i);
                sv_active_idx = -1;
            }

            sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
            string display_text;
            if (sv_active_idx == i)
                display_text = sv_edit_text;
            else if (is_string)
                display_text = Server_GetStringEffective(i);
            else
                display_text = ftos(Server_GetEffective(i));
            sui_text([3, 1], SV_FONT, display_text, SV_TEXT_1, 1, 0);

            // Caret with explicit START align — see cl_debugpanel.qc
            // for why CENTER would push it 50% down the row.
            if (sv_active_idx == i)
            {
                sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
                float cursorx = stringwidth(
                    substring(sv_edit_text, 0, sv_edit_cursor),
                    1, SV_FONT);
                sui_fill([3 + cursorx, 4], [1, 8],
                         SV_TEXT_1, fabs(sin(time * 4)), 0);
            }

            sui_pop_frame();
        }

        y = y + SV_ROW_H;
    }

    if (!sv_enum_visible)
    {
        sv_enum_open = 0;
        sv_enum_entry_idx = -1;
    }

    sui_scroll_view_end();
    sui_pop_frame();
};

// =============================================================
//  Bottom bar — themed footer hosting the resize grip
// =============================================================
void() Server_DrawBottomBar =
{
    float by = sv_panel_size_y - SV_GRIP_SIZE;

    sui_push_frame([0, by], [sv_panel_size_x, SV_GRIP_SIZE]);

    sui_fill([0, 0], [sv_panel_size_x, SV_GRIP_SIZE], SV_TITLE_BG, 1, 0);
    sui_fill([0, 0], [sv_panel_size_x, 1], SV_BORDER, 1, 0);

    float gx = sv_panel_size_x - SV_GRIP_SIZE;
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    if (sui_is_hovered("sv_resize"))
        sui_fill([gx, 0], [SV_GRIP_SIZE, SV_GRIP_SIZE],
                 '0.18 0.18 0.20', 0.5, 0);

    float i;
    for (i = 2; i < SV_GRIP_SIZE; i = i + 3)
    {
        sui_fill([gx + SV_GRIP_SIZE - i - 1, i], [i + 1, 1],
                 SV_TEXT_2, 0.7, 0);
    }

    sui_action_element([gx, 0], [SV_GRIP_SIZE, SV_GRIP_SIZE],
        "sv_resize", sui_noop);

    sui_pop_frame();
};

void() Server_HandleResize =
{
    float held = sui_is_held("sv_resize");

    if (held && !sv_panel_resizing)
    {
        sv_panel_resizing = 1;
        sv_panel_resize_origin_size   = sv_panel_size;
        sv_panel_resize_origin_cursor = _cursor_position;
    }

    if (held && sv_panel_resizing)
    {
        sv_panel_size_x = sv_panel_resize_origin_size_x
            + (_cursor_position_x - sv_panel_resize_origin_cursor_x);
        sv_panel_size_y = sv_panel_resize_origin_size_y
            + (_cursor_position_y - sv_panel_resize_origin_cursor_y);

        // Min width is generous enough to fit the 5 tabs + scalar
        // input + close X without the layout breaking down.
        if (sv_panel_size_x < 280) sv_panel_size_x = 280;
        if (sv_panel_size_y < 200) sv_panel_size_y = 200;
        if (sv_panel_size_x > 720) sv_panel_size_x = 720;
        if (sv_panel_size_y > 600) sv_panel_size_y = 600;
    }

    if (!held)
        sv_panel_resizing = 0;
};

// =============================================================
//  Main draw — called from CSQC_UpdateView inside sui_begin/end.
// =============================================================
void() Server_PanelDraw =
{
    if (!sv_panel_open) return;
    Server_PanelInit();

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    // Drop shadow — same idiom as cl_debugpanel.qc.
    sui_fill([sv_panel_pos_x + 3, sv_panel_pos_y + 3],
             sv_panel_size, SV_SHADOW, 0.45, 0);

    // Defensive screen-edge clamp.
    if (sv_panel_pos_x > g_width - 80)
        sv_panel_pos_x = g_width - 80;
    if (sv_panel_pos_y > g_height - SV_TITLE_H)
        sv_panel_pos_y = g_height - SV_TITLE_H;

    sui_push_frame(sv_panel_pos, sv_panel_size);

    sui_fill([0, 0], sv_panel_size, SV_BG, 0.94, 0);
    sui_border_box([0, 0], sv_panel_size, 2, SV_BORDER, 1, 0);

    Server_DrawTitleBar();
    Server_DrawTabStrip();
    Server_DrawBody();
    Server_DrawBottomBar();

    Server_HandleDrag();
    Server_HandleResize();

    sui_pop_frame();
    Server_DrawEnumOverlay();
};
