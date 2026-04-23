// ============================================================
//  client/cl_debuginfo.qc  -  Debug visualization tools
//
//  cl_debug_impacts 1   — shows where bullets land:
//      Green  = client-predicted hit
//      Purple = server-authoritative hit
//  cl_debug_bandwidth 1 — live inbound KB/s + per-category breakdown
// ============================================================

// ============================================================
//  Bandwidth instrumentation (CSQC_NetStat_*)
//
//  Called from CSQC_Ent_Update and CSQC_Parse_Event to attribute
//  inbound bytes to a category. 10 × 100ms bins = 1s rolling window.
//  Byte counts are *estimates* based on the known wire layout of
//  each section / event payload, not actual-read bytes.
// ============================================================

const float NET_STAT_BINS = 10;
const float NET_STAT_BIN_DUR = 0.1;  // 100 ms per bin → 1s window

// Byte sizes per section (updated if wire layout changes)
const float NET_SZ_PROXY_HEADER = 2;  // version byte + changedflags byte
const float NET_SZ_PROXY_MOVE   = 84; // 9 coords + 15 floats
const float NET_SZ_PROXY_WEAP   = 17; // 8 bytes + 2 floats + zoomstage
const float NET_SZ_PROXY_AMMO   = 45; // 45 mag/ammo/silencer bytes
const float NET_SZ_PLAYER_VIS   = 53;
const float NET_SZ_PUSH_TRIG    = 57;
const float NET_SZ_TELE_TRIG    = 69;
const float NET_SZ_LADDER_TRIG  = 49;
const float NET_SZ_SOLID_BRUSH  = 80;  // avg (static 74, door ~104)

float net_stat_bin_idx;
float net_stat_bin_time;

float net_stat_total[NET_STAT_BINS];
float net_stat_proxy_hdr[NET_STAT_BINS];
float net_stat_proxy_move[NET_STAT_BINS];
float net_stat_proxy_weap[NET_STAT_BINS];
float net_stat_proxy_ammo[NET_STAT_BINS];
float net_stat_visual[NET_STAT_BINS];
float net_stat_triggers[NET_STAT_BINS];
float net_stat_brushes[NET_STAT_BINS];
float net_stat_events[NET_STAT_BINS];

// Section-hit counts (how many ticks received SF_*)
float net_hit_move[NET_STAT_BINS];
float net_hit_weap[NET_STAT_BINS];
float net_hit_ammo[NET_STAT_BINS];
float net_hit_visual_self[NET_STAT_BINS];    // own player_visual_proxy
float net_hit_visual_remote[NET_STAT_BINS];  // other players' visuals
float net_hit_events[NET_STAT_BINS];
float net_hit_proxy_hdr[NET_STAT_BINS];       // raw snapshot cadence (1 per proxy packet)

void() CSQC_NetStat_Advance =
{
    if (net_stat_bin_time == 0)
        net_stat_bin_time = cltime;

    while (cltime - net_stat_bin_time > NET_STAT_BIN_DUR)
    {
        net_stat_bin_idx = (net_stat_bin_idx + 1) % NET_STAT_BINS;
        float i = net_stat_bin_idx;
        net_stat_total[i] = 0;
        net_stat_proxy_hdr[i] = 0;
        net_stat_proxy_move[i] = 0;
        net_stat_proxy_weap[i] = 0;
        net_stat_proxy_ammo[i] = 0;
        net_stat_visual[i] = 0;
        net_stat_triggers[i] = 0;
        net_stat_brushes[i] = 0;
        net_stat_events[i] = 0;
        net_hit_move[i] = 0;
        net_hit_weap[i] = 0;
        net_hit_ammo[i] = 0;
        net_hit_visual_self[i] = 0;
        net_hit_visual_remote[i] = 0;
        net_hit_events[i] = 0;
        net_hit_proxy_hdr[i] = 0;
        net_stat_bin_time += NET_STAT_BIN_DUR;
    }
};

void(float changedflags) CSQC_NetStat_RecordProxy =
{
    CSQC_NetStat_Advance();
    float i = net_stat_bin_idx;
    float b = NET_SZ_PROXY_HEADER;
    net_stat_proxy_hdr[i] += NET_SZ_PROXY_HEADER;
    net_hit_proxy_hdr[i] += 1;  // one packet = one snapshot, use this as send-rate proxy

    if (changedflags & PM_SF_MOVEMENT)
    {
        b += NET_SZ_PROXY_MOVE;
        net_stat_proxy_move[i] += NET_SZ_PROXY_MOVE;
        net_hit_move[i] += 1;
    }
    if (changedflags & PM_SF_WEAPON_STATE)
    {
        b += NET_SZ_PROXY_WEAP;
        net_stat_proxy_weap[i] += NET_SZ_PROXY_WEAP;
        net_hit_weap[i] += 1;
    }
    if (changedflags & PM_SF_AMMO)
    {
        b += NET_SZ_PROXY_AMMO;
        net_stat_proxy_ammo[i] += NET_SZ_PROXY_AMMO;
        net_hit_ammo[i] += 1;
    }
    net_stat_total[i] += b;
};

// owner_entnum = the server entnum the visual represents. Compare against
// player_localentnum to distinguish self vs. remote for the HUD.
void(float owner_entnum) CSQC_NetStat_RecordVisual =
{
    CSQC_NetStat_Advance();
    float i = net_stat_bin_idx;
    net_stat_visual[i] += NET_SZ_PLAYER_VIS;
    net_stat_total[i] += NET_SZ_PLAYER_VIS;
    if (owner_entnum == player_localentnum)
        net_hit_visual_self[i] += 1;
    else
        net_hit_visual_remote[i] += 1;
};

void(float bytes) CSQC_NetStat_RecordTrigger =
{
    CSQC_NetStat_Advance();
    net_stat_triggers[net_stat_bin_idx] += bytes;
    net_stat_total[net_stat_bin_idx] += bytes;
};

void() CSQC_NetStat_RecordBrush =
{
    CSQC_NetStat_Advance();
    net_stat_brushes[net_stat_bin_idx] += NET_SZ_SOLID_BRUSH;
    net_stat_total[net_stat_bin_idx] += NET_SZ_SOLID_BRUSH;
};

void(float bytes) CSQC_NetStat_RecordEvent =
{
    CSQC_NetStat_Advance();
    net_stat_events[net_stat_bin_idx] += bytes;
    net_stat_total[net_stat_bin_idx] += bytes;
    net_hit_events[net_stat_bin_idx] += 1;
};

const float DEBUG_MAX_IMPACTS = 64;
const float DEBUG_IMPACT_LIFETIME = 10;
const float DEBUG_CROSS_SIZE = 4;
const float DEBUG_LINE_WIDTH = 2;

// Damage text settings
float DEBUG_DMG_FONT_SIZE    = 8;    // font height in pixels
float DEBUG_DMG_OFFSET_UP    = 12;    // world units above impact point
float DEBUG_DMG_OFFSET_RIGHT = 2;     // screen pixels to the right

float debug_impact_count;
vector debug_impact_pos[DEBUG_MAX_IMPACTS];
vector debug_impact_eye[DEBUG_MAX_IMPACTS];
vector debug_impact_colour[DEBUG_MAX_IMPACTS];
float debug_impact_time[DEBUG_MAX_IMPACTS];
float debug_impact_damage[DEBUG_MAX_IMPACTS];
float debug_impact_hitgroup[DEBUG_MAX_IMPACTS];

// Hitgroup name for debug display (client-side).
string(float hg) dbg_hitgroup_str =
{
    if (hg == HITGROUP_HEAD)     return "HEAD";
    if (hg == HITGROUP_CHEST)    return "CHEST";
    if (hg == HITGROUP_STOMACH)  return "STOMACH";
    if (hg == HITGROUP_LEFTARM)  return "L ARM";
    if (hg == HITGROUP_RIGHTARM) return "R ARM";
    if (hg == HITGROUP_LEFTLEG)  return "L LEG";
    if (hg == HITGROUP_RIGHTLEG) return "R LEG";
    return "";
};

// Store a debug impact point to be drawn for DEBUG_IMPACT_LIFETIME seconds.
void(vector pos, vector eye_pos, vector colour, float damage, float hitgroup) CSQC_AddDebugImpact =
{
    float idx = debug_impact_count % DEBUG_MAX_IMPACTS;
    debug_impact_pos[idx] = pos;
    debug_impact_eye[idx] = eye_pos;
    debug_impact_colour[idx] = colour;
    debug_impact_time[idx] = time;
    debug_impact_damage[idx] = damage;
    debug_impact_hitgroup[idx] = hitgroup;
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

// Draw 2D damage text overlays. Must be called AFTER renderscene().
void() CSQC_DrawDebugImpactText =
{
    float i, total, age;
    vector pos, colour;

    if (!cvar("cl_debug_impacts"))
        return;

    total = min(debug_impact_count, DEBUG_MAX_IMPACTS);

    for (i = 0; i < total; i++)
    {
        age = time - debug_impact_time[i];
        if (age > DEBUG_IMPACT_LIFETIME)
            continue;

        float dmg = debug_impact_damage[i];
        if (dmg <= 0)
            continue;

        pos = debug_impact_pos[i];
        colour = debug_impact_colour[i];

        float alpha = 1;
        if (age > DEBUG_IMPACT_LIFETIME - 1)
            alpha = DEBUG_IMPACT_LIFETIME - age;

        vector screen = project(pos + '0 0 1' * DEBUG_DMG_OFFSET_UP);
        if (screen_z > 0)
        {
            // Show damage number + hitgroup name (e.g. "200 HEAD")
            float hg = debug_impact_hitgroup[i];
            string hg_str = dbg_hitgroup_str(hg);
            string dmg_text;
            if (hg_str != "")
                dmg_text = sprintf("%.0f %s", dmg, hg_str);
            else
                dmg_text = sprintf("%.0f", dmg);

            vector text_sz = [DEBUG_DMG_FONT_SIZE, DEBUG_DMG_FONT_SIZE];
            float sx = screen_x + DEBUG_DMG_OFFSET_RIGHT;
            float sy = screen_y - DEBUG_DMG_FONT_SIZE * 0.5;
            drawstring([sx + 1, sy + 1], dmg_text, text_sz, '0 0 0', alpha * 0.6, 0);
            drawstring([sx, sy], dmg_text, text_sz, colour, alpha, 0);
        }
    }
};

// ============================================================
//  Debug Panel System
//
//  cl_debug_net 1      — networking & prediction
//  cl_debug_weapon 1   — weapon state & animation
//  cl_debug_move 1     — movement & physics
//  cl_debug_game 1     — game state & round info
// ============================================================

// Forward declarations (defined in cl_player.qc and cl_weapons.qc, compiled later)
float pred_cmd_latest_sequence;
float sv_confirmed_cmdframe;
float pred_cmd_count;
float csqc_dbg_last_replay_count;
float csqc_dbg_ring_overflowed;
float csqc_dbg_ack_fell_out;
float csqc_dbg_seed_source;
float csqc_baseline_valid;
vector sv_confirmed_origin;
float() CSQC_GetWeaponDisplayFrame;

// Forward declarations for player model debug (defined in cl_player.qc)
.float vis_anim_top;
.float vis_anim_bottom;
.float vis_anim_top_time;
.float vis_anim_bottom_time;
.float vis_weapon_id;
.float vis_pitch;
.float vis_owner_entnum;

// ============================================================
//  Rolling-jitter ring buffers — drives CSQC_DrawDebugSmoothing
// ============================================================
//
//  Each metric gets SMOOTH_RING_LEN floats of history.  Storage is a
//  single flat array indexed by (metric * SMOOTH_RING_LEN + head) so we
//  don't have to enumerate seven parallel globals.  Sample sites live in
//  cl_player.qc / cl_main.qc (compiled after this file) and call
//  Smooth_Push directly.
//
const float SMOOTH_RING_LEN = 60;
const float SMOOTH_M_FT       = 0;  // frametime (ms)
const float SMOOTH_M_STEP     = 1;  // raw presentation-step magnitude (qu)
const float SMOOTH_M_REGULAR  = 2;  // step / (horiz speed * frametime) ratio
const float SMOOTH_M_FWDSTEP  = 3;  // step projected onto velocity direction (qu)
const float SMOOTH_M_SNAP     = 4;  // snapshot arrival dt (ms)
const float SMOOTH_M_RECONC   = 5;  // reconcile correction magnitude (qu)
const float SMOOTH_M_UNACK    = 6;  // unacked command count

float smooth_ring[420];   // 7 metrics * 60 samples
float smooth_head[7];
float smooth_count[7];

// Persistent reference points captured at sample sites.
vector smooth_last_present_origin;
float  smooth_last_snap_cltime;
vector smooth_pre_reset_origin;

// Flush all metric rings and persistent reference points.  Called from
// CSQC_WorldLoaded on map change so stale menu-phase / previous-map
// samples don't linger in the stats window.
void() Smooth_Reset =
{
    float i;
    for (i = 0; i < 420; i = i + 1)
        smooth_ring[i] = 0;
    for (i = 0; i < 7; i = i + 1)
    {
        smooth_head[i]  = 0;
        smooth_count[i] = 0;
    }
    smooth_last_present_origin = '0 0 0';
    smooth_last_snap_cltime    = 0;
    smooth_pre_reset_origin    = '0 0 0';
};

void(float metric, float sample) Smooth_Push =
{
    float base = metric * SMOOTH_RING_LEN;
    smooth_ring[base + smooth_head[metric]] = sample;
    smooth_head[metric] = smooth_head[metric] + 1;
    if (smooth_head[metric] >= SMOOTH_RING_LEN)
        smooth_head[metric] = 0;
    if (smooth_count[metric] < SMOOTH_RING_LEN)
        smooth_count[metric] = smooth_count[metric] + 1;
};

void(float metric, __inout float out_min, __inout float out_avg,
     __inout float out_max, __inout float out_stddev) Smooth_Stats =
{
    float n = smooth_count[metric];
    if (n <= 0)
    {
        out_min = 0; out_avg = 0; out_max = 0; out_stddev = 0;
        return;
    }

    float base = metric * SMOOTH_RING_LEN;
    float i;
    float v;
    float sum  = 0;
    float mn   =  999999999;
    float mx   = -999999999;

    for (i = 0; i < n; i = i + 1)
    {
        v = smooth_ring[base + i];
        sum = sum + v;
        if (v < mn) mn = v;
        if (v > mx) mx = v;
    }
    float avg = sum / n;

    float sqsum = 0;
    for (i = 0; i < n; i = i + 1)
    {
        v = smooth_ring[base + i] - avg;
        sqsum = sqsum + v * v;
    }

    out_min    = mn;
    out_avg    = avg;
    out_max    = mx;
    out_stddev = (n > 1) ? sqrt(sqsum / n) : 0;
};

// --- Helpers ---

vector DBG_TEXT = [8, 8, 0];
vector DBG_LABEL_COL = '0.5 0.55 0.6';
vector DBG_VALUE_COL = '0.9 0.9 0.9';
vector DBG_WARN_COL  = '1 0.7 0.2';
vector DBG_BAD_COL   = '1 0.3 0.3';
vector DBG_GOOD_COL  = '0.3 1 0.4';
float  DBG_LINE_H    = 10;

float(float x, float y, string label, string value, vector col) dbg_line =
{
    drawfill([x - 4, y, 0], [228, DBG_LINE_H, 0], '0.02 0.02 0.04', 0.75, 0);
    drawstring([x, y, 0], label, DBG_TEXT, DBG_LABEL_COL, 1, 0);
    drawstring([x + 80, y, 0], value, DBG_TEXT, col, 1, 0);
    return y + DBG_LINE_H;
};

float(float x, float y, string text, vector col) dbg_text =
{
    drawfill([x - 4, y, 0], [228, DBG_LINE_H, 0], '0.02 0.02 0.04', 0.75, 0);
    drawstring([x, y, 0], text, DBG_TEXT, col, 1, 0);
    return y + DBG_LINE_H;
};

string(float ws) dbg_weaponstate_str =
{
    if (ws == WS_IDLE)    return "IDLE";
    if (ws == WS_DRAW)    return "DRAW";
    if (ws == WS_FIRE)    return "FIRE";
    if (ws == WS_RELOAD)  return "RELOAD";
    if (ws == WS_SPECIAL) return "SPECIAL";
    return "???";
};

string(float mt) dbg_movetype_str =
{
    if (mt == PM_MOVETYPE_NORMAL)    return "NORMAL";
    if (mt == PM_MOVETYPE_DEAD)      return "DEAD";
    if (mt == PM_MOVETYPE_FLY)       return "FLY";
    if (mt == PM_MOVETYPE_SPECTATOR) return "SPECTATOR";
    if (mt == PM_MOVETYPE_NONE)      return "NONE";
    if (mt == PM_MOVETYPE_NOCLIP)    return "NOCLIP";
    return "???";
};

string(float rp) dbg_roundphase_str =
{
    if (rp == ROUND_PHASE_NONE)      return "NONE";
    if (rp == ROUND_PHASE_FREEZE)    return "FREEZE";
    if (rp == ROUND_PHASE_ACTIVE)    return "ACTIVE";
    if (rp == ROUND_PHASE_ROUND_END) return "ROUND_END";
    if (rp == ROUND_PHASE_MAP_END)   return "MAP_END";
    return "???";
};

string(float seq) dbg_csanim_str =
{
    if (seq == 0)  return "DUMMY1";
    if (seq == 1)  return "IDLE";
    if (seq == 2)  return "IDLE_CROUCH";
    if (seq == 3)  return "WALK";
    if (seq == 4)  return "RUN";
    if (seq == 5)  return "RUN_CROUCH";
    if (seq == 6)  return "JUMP";
    if (seq == 7)  return "LONGJUMP";
    if (seq == 8)  return "SWIM";
    if (seq == 9)  return "TREADWATER";
    if (seq >= 10 && seq <= 12) return "CR_CARBINE";
    if (seq >= 13 && seq <= 15) return "CARBINE";
    if (seq >= 16 && seq <= 18) return "CR_ONEHAND";
    if (seq >= 19 && seq <= 21) return "ONEHAND";
    if (seq >= 22 && seq <= 25) return "CR_DUALPIST";
    if (seq >= 26 && seq <= 29) return "DUALPIST";
    if (seq >= 30 && seq <= 32) return "CR_RIFLE";
    if (seq >= 33 && seq <= 35) return "RIFLE";
    if (seq >= 36 && seq <= 38) return "CR_MP5";
    if (seq >= 39 && seq <= 41) return "MP5";
    if (seq >= 42 && seq <= 44) return "CR_SHOTGUN";
    if (seq >= 45 && seq <= 47) return "SHOTGUN";
    if (seq >= 48 && seq <= 50) return "CR_PARA";
    if (seq >= 51 && seq <= 53) return "PARA";
    if (seq >= 56 && seq <= 57) return "GRENADE";
    if (seq >= 58 && seq <= 59) return "CR_GRENADE";
    if (seq >= 60 && seq <= 64) return "C4";
    if (seq >= 73 && seq <= 74) return "CR_KNIFE";
    if (seq >= 75 && seq <= 76) return "KNIFE";
    if (seq >= 77 && seq <= 79) return "CR_AK47";
    if (seq >= 80 && seq <= 82) return "AK47";
    if (seq >= 83 && seq <= 84) return "FLINCH";
    if (seq >= 85 && seq <= 94) return "DEATH";
    return sprintf("SEQ_%g", seq);
};

// ============================================================
//  cl_debug_net — Networking & Prediction
// ============================================================

float(float x, float y) CSQC_DrawDebugNet =
{
    float ping, pl, unacked, buf_used, fps;
    vector col;

    ping = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0);
    pl = getplayerkeyfloat(player_localnum, INFOKEY_P_PACKETLOSS, 0);
    unacked = pred_cmd_latest_sequence - sv_confirmed_cmdframe;
    buf_used = pred_cmd_count;
    fps = 1 / max(frametime, 0.001);

    y = dbg_text(x, y, "--- NET & PREDICTION ---", '0.4 0.7 1');

    col = (fps > 120) ? DBG_GOOD_COL : (fps > 60) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "FPS", sprintf("%.0f  (%.1fms)", fps, frametime * 1000), col);

    col = (ping < 80) ? DBG_GOOD_COL : (ping < 150) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Ping", sprintf("%.0f ms", ping), col);

    col = (pl == 0) ? DBG_GOOD_COL : (pl < 5) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Loss", sprintf("%.0f%%", pl), col);

    col = (unacked < 5) ? DBG_GOOD_COL : (unacked < 15) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Unacked", sprintf("%.0f cmds", unacked), col);

    col = (buf_used < 64) ? DBG_GOOD_COL : (buf_used < 100) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Buffer", sprintf("%.0f / 128", buf_used), col);

    y = dbg_line(x, y, "Replayed", sprintf("%.0f cmds", csqc_dbg_last_replay_count), DBG_VALUE_COL);
    y = dbg_line(x, y, "Cmd Frame", sprintf("cli %.0f  srv %.0f", clientcommandframe, servercommandframe), DBG_VALUE_COL);

    string seed_str = "none";
    if (csqc_dbg_seed_source == 1) seed_str = "engine";
    else if (csqc_dbg_seed_source == 2) seed_str = "proxy";
    y = dbg_line(x, y, "Seed", seed_str, DBG_VALUE_COL);

    if (predicted_player && csqc_baseline_valid)
    {
        float err = vlen(predicted_player.origin - sv_confirmed_origin);
        col = (err < 1) ? DBG_GOOD_COL : (err < 8) ? DBG_WARN_COL : DBG_BAD_COL;
        y = dbg_line(x, y, "Pred Error", sprintf("%.2f units", err), col);
    }

    if (csqc_dbg_ring_overflowed)
        y = dbg_text(x, y, "! RING OVERFLOW", DBG_BAD_COL);
    if (csqc_dbg_ack_fell_out)
        y = dbg_text(x, y, "! ACK FELL OUT", DBG_BAD_COL);

    return y + 6;
};

// ============================================================
//  cl_debug_weapon — Weapon & Animation
// ============================================================

float(float x, float y) CSQC_DrawDebugWeapon =
{

    if (!predicted_player)
    {
        y = dbg_text(x, y, "--- WEAPON (no player) ---", '1 0.6 0.3');
        return y + 6;
    }

    y = dbg_text(x, y, "--- WEAPON ---", '1 0.6 0.3');

    y = dbg_line(x, y, "Name", predicted_player.weapon_name, DBG_VALUE_COL);
    y = dbg_line(x, y, "ID", sprintf("%.0f", predicted_player.weapon), DBG_VALUE_COL);
    y = dbg_line(x, y, "State", dbg_weaponstate_str(predicted_player.weaponstate), DBG_VALUE_COL);
    y = dbg_line(x, y, "Action ID", sprintf("%.0f", predicted_player.wep_action_id), DBG_VALUE_COL);

    float disp = CSQC_GetWeaponDisplayFrame();
    y = dbg_line(x, y, "Frame", sprintf("%.2f", disp), DBG_VALUE_COL);

    if (predicted_player.wep_anim_start > 0)
    {
        float elapsed = cltime - predicted_player.wep_anim_start;
        y = dbg_line(x, y, "Anim Time", sprintf("%.3fs", elapsed), DBG_VALUE_COL);
    }

    float atk_left = predicted_player.attack_finished - cltime;
    if (atk_left > 0)
        y = dbg_line(x, y, "Cooldown", sprintf("%.2fs", atk_left), DBG_WARN_COL);
    else
        y = dbg_line(x, y, "Cooldown", "ready", DBG_GOOD_COL);

    y = dbg_line(x, y, "Spread", sprintf("%.3f", predicted_player.spread_penalty), DBG_VALUE_COL);
    y = dbg_line(x, y, "Fire Spread", sprintf("%.3f", predicted_player.fire_spread_penalty), DBG_VALUE_COL);

    if (predicted_player.zoomstage > 0)
        y = dbg_line(x, y, "Zoom", sprintf("%.0fx", predicted_player.zoomstage), DBG_WARN_COL);

    return y + 6;
};

// ============================================================
//  cl_debug_move — Movement & Physics
// ============================================================

float(float x, float y) CSQC_DrawDebugMove =
{

    if (!predicted_player)
    {
        y = dbg_text(x, y, "--- MOVE (no player) ---", '0.3 1 0.6');
        return y + 6;
    }

    y = dbg_text(x, y, "--- MOVEMENT ---", '0.3 1 0.6');

    vector vel = predicted_player.velocity;
    vector vel2d = vel; vel2d_z = 0;
    float hspeed = vlen(vel2d);
    float tspeed = vlen(vel);

    y = dbg_line(x, y, "Pos", sprintf("%.0f %.0f %.0f", predicted_player.origin_x, predicted_player.origin_y, predicted_player.origin_z), DBG_VALUE_COL);
    y = dbg_line(x, y, "Vel", sprintf("%.0f %.0f %.0f", vel_x, vel_y, vel_z), DBG_VALUE_COL);
    y = dbg_line(x, y, "H Speed", sprintf("%.1f u/s", hspeed), (hspeed > 300) ? DBG_WARN_COL : DBG_VALUE_COL);
    y = dbg_line(x, y, "Speed", sprintf("%.1f u/s", tspeed), DBG_VALUE_COL);

    y = dbg_line(x, y, "Movetype", dbg_movetype_str(predicted_player.pm_movetype), DBG_VALUE_COL);

    string ground_str = (predicted_player.flags & FL_ONGROUND) ? "YES" : "NO";
    vector ground_col = (predicted_player.flags & FL_ONGROUND) ? DBG_GOOD_COL : DBG_VALUE_COL;
    y = dbg_line(x, y, "On Ground", ground_str, ground_col);

    y = dbg_line(x, y, "Waterlevel", sprintf("%.0f", pm_waterlevel), DBG_VALUE_COL);

    string duck_str = (predicted_player.flags & FL_DUCKING) ? "DUCKED" : (predicted_player.pm_in_duck ? "TRANSITIONING" : "STANDING");
    y = dbg_line(x, y, "Duck", duck_str, DBG_VALUE_COL);

    if (predicted_player.pm_fuser2 > 0)
        y = dbg_line(x, y, "Stamina", sprintf("%.0f", predicted_player.pm_fuser2), DBG_WARN_COL);

    y = dbg_line(x, y, "View Ofs", sprintf("%.1f", predicted_player.view_ofs_z), DBG_VALUE_COL);

    // Active buttons
    string btns = "";
    if (input_buttons & PM_BTN_JUMP) btns = strcat(btns, "JUMP ");
    if (input_buttons & PM_BTN_DUCK) btns = strcat(btns, "DUCK ");
    if (input_buttons & PM_BTN_SPRINT) btns = strcat(btns, "SPRINT ");
    if (input_buttons & PM_BTN_USE) btns = strcat(btns, "USE ");
    if (btns == "") btns = "none";
    y = dbg_line(x, y, "Buttons", btns, DBG_VALUE_COL);

    return y + 6;
};

// ============================================================
//  cl_debug_game — Game State
// ============================================================

float(float x, float y) CSQC_DrawDebugGame =
{

    y = dbg_text(x, y, "--- GAME STATE ---", '1 1 0.3');

    y = dbg_line(x, y, "Health", sprintf("%.0f", (float)getstati(STAT_HEALTH)), DBG_VALUE_COL);

    float team = getstatf(STAT_PLAYERTEAM);
    string team_str = (team == TEAM_BLUE) ? "BLUE" : (team == TEAM_RED) ? "RED" : "NONE";
    vector team_col = (team == TEAM_BLUE) ? '0.4 0.6 1' : (team == TEAM_RED) ? '1 0.4 0.4' : DBG_VALUE_COL;
    y = dbg_line(x, y, "Team", team_str, team_col);

    float phase = getstatf(STAT_ROUND_PHASE);
    y = dbg_line(x, y, "Phase", dbg_roundphase_str(phase), DBG_VALUE_COL);

    y = dbg_line(x, y, "Round", sprintf("%.0f / %.0f", getstatf(STAT_ROUNDNUM), getstatf(STAT_MAXROUNDS)), DBG_VALUE_COL);

    float bs = getstatf(STAT_BLUE_SCORE);
    float rs = getstatf(STAT_RED_SCORE);
    y = dbg_line(x, y, "Score", sprintf("B:%.0f  R:%.0f", bs, rs), DBG_VALUE_COL);

    float gm = getstatf(STAT_GAMEMODE);
    string gm_label;
    if      (gm == GAMEMODE_ELIMINATION) gm_label = "Elimination";
    else if (gm == GAMEMODE_BHOP)        gm_label = "Bhop";
    else                                 gm_label = "TDM";
    y = dbg_line(x, y, "Gamemode", gm_label, DBG_VALUE_COL);

    float timeleft = getstatf(STAT_MAPTIMELEFT);
    float mins = floor(timeleft / 60);
    float secs = floor(timeleft - mins * 60);
    y = dbg_line(x, y, "Map Time", sprintf("%.0f:%02.0f", mins, secs), DBG_VALUE_COL);

    if (phase == ROUND_PHASE_FREEZE)
    {
        float freeze = getstatf(STAT_FREEZE_TIMELEFT);
        y = dbg_line(x, y, "Freeze", sprintf("%.1fs", freeze), DBG_WARN_COL);
    }

    float is_dead = getstatf(STAT_IS_DEAD);
    if (is_dead)
    {
        float delay = getstatf(STAT_DEATH_DELAY_LEFT);
        y = dbg_line(x, y, "Dead", sprintf("respawn %.1fs", delay), DBG_BAD_COL);
    }

    return y + 6;
};

// ============================================================
//  cl_debug_smoothing — Rolling jitter diagnostic panel
// ============================================================
//
//  Seven metrics, each with min / avg / max / stddev over the last 60
//  samples.  Samples are pushed from cl_player.qc + cl_main.qc at the
//  event sites (frametime, presentation step, snapshot arrival,
//  reconcile correction, unacked backlog).  The "regular" and
//  "fwdstep" rows are the cleanest straight-line-jitter indicators —
//  on flat ground walking forward they should read near-zero stddev;
//  anything above ~0.05 is visible to the eye.
//
float(float x, float y) CSQC_DrawDebugSmoothing =
{
    float mn = 0;
    float av = 0;
    float mx = 0;
    float sd = 0;

    y = dbg_text(x, y, "--- SMOOTHING ---", '0.5 0.9 1');
    y = dbg_text(x, y, "metric      min    avg    max    stddev", DBG_LABEL_COL);

    Smooth_Stats(SMOOTH_M_FT, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" frame   %6.2f %6.2f %6.2f %6.2f ms",
                               mn, av, mx, sd),
                 (sd > 2.0) ? DBG_BAD_COL : (sd > 0.5) ? DBG_WARN_COL : DBG_GOOD_COL);

    Smooth_Stats(SMOOTH_M_STEP, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" presen  %6.2f %6.2f %6.2f %6.2f qu",
                               mn, av, mx, sd), DBG_VALUE_COL);

    Smooth_Stats(SMOOTH_M_REGULAR, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" regular %6.2f %6.2f %6.2f %6.3f",
                               mn, av, mx, sd),
                 (sd > 0.15) ? DBG_BAD_COL : (sd > 0.05) ? DBG_WARN_COL : DBG_GOOD_COL);

    Smooth_Stats(SMOOTH_M_FWDSTEP, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" fwdstep %6.2f %6.2f %6.2f %6.2f qu",
                               mn, av, mx, sd), DBG_VALUE_COL);

    Smooth_Stats(SMOOTH_M_SNAP, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" snap    %6.2f %6.2f %6.2f %6.2f ms",
                               mn, av, mx, sd),
                 (sd > 20.0) ? DBG_BAD_COL : (sd > 5.0) ? DBG_WARN_COL : DBG_GOOD_COL);

    Smooth_Stats(SMOOTH_M_RECONC, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" reconc  %6.2f %6.2f %6.2f %6.2f qu",
                               mn, av, mx, sd),
                 (mx > 8.0) ? DBG_BAD_COL : (mx > 2.0) ? DBG_WARN_COL : DBG_GOOD_COL);

    Smooth_Stats(SMOOTH_M_UNACK, mn, av, mx, sd);
    y = dbg_text(x, y, sprintf(" unack   %6.0f %6.1f %6.0f %6.2f",
                               mn, av, mx, sd), DBG_VALUE_COL);

    // ---- Frametime bar graph ----
    // 60 vertical bars scrolling left→right, oldest→newest, matching the
    // ring order so a spike you feel now appears at the far right.
    // Panel width matches dbg_text (228 px starting at x-4) so the graph
    // lines up edge-to-edge with the numeric rows above.  Y-axis: 0 ms
    // at bottom, GRAPH_MS at top.  Reference lines at 5 / 10 / 16.67 ms
    // (200 / 100 / 60 fps).  Bars coloured by absolute frametime so a
    // 16 ms outlier at 300 fps pops visually without reading the number.
    {
        float PANEL_W   = 228;                       // matches dbg_text
        float PANEL_X   = x - 4;                     // matches dbg_text
        float GRAPH_X   = PANEL_X + 4;               // inner bar origin
        float GRAPH_W   = PANEL_W - 8;               // inner bar width
        float SLOT_W    = GRAPH_W / SMOOTH_RING_LEN; // float (~3.67)
        float BAR_W     = SLOT_W;                    // bars touch edge-to-edge
        float GRAPH_H   = 40;
        float GRAPH_MS  = 20.0;                      // cap (50 fps floor)
        float ms_to_px  = GRAPH_H / GRAPH_MS;

        drawfill([PANEL_X, y, 0], [PANEL_W, GRAPH_H + 4, 0],
                 '0.02 0.02 0.04', 0.8, 0);

        // Reference lines: 60 / 100 / 200 fps.
        float mark_60  = y + GRAPH_H - (16.67 * ms_to_px) + 2;
        float mark_100 = y + GRAPH_H - (10.00 * ms_to_px) + 2;
        float mark_200 = y + GRAPH_H - ( 5.00 * ms_to_px) + 2;
        drawfill([GRAPH_X, mark_60,  0], [GRAPH_W, 1, 0], '1 0.3 0.3', 0.25, 0);
        drawfill([GRAPH_X, mark_100, 0], [GRAPH_W, 1, 0], '1 0.7 0.2', 0.25, 0);
        drawfill([GRAPH_X, mark_200, 0], [GRAPH_W, 1, 0], '0.3 1 0.4', 0.25, 0);

        // Walk ring oldest→newest so newest is rightmost.  head points at
        // the next-write slot; oldest is head (when full) or 0 (filling).
        float n = smooth_count[SMOOTH_M_FT];
        float start;
        if (n < SMOOTH_RING_LEN)
            start = 0;
        else
            start = smooth_head[SMOOTH_M_FT];

        float base = SMOOTH_M_FT * SMOOTH_RING_LEN;
        float i, pos, sample;
        vector bar_col;
        for (i = 0; i < n; i = i + 1)
        {
            pos = start + i;
            if (pos >= SMOOTH_RING_LEN) pos -= SMOOTH_RING_LEN;
            sample = smooth_ring[base + pos];

            float h = min(sample * ms_to_px, GRAPH_H);
            if (sample >= 16.67)      bar_col = '1 0.3 0.3';    // sub-60 fps
            else if (sample >= 10.00) bar_col = '1 0.7 0.2';    // sub-100 fps
            else if (sample >=  5.00) bar_col = '0.8 0.9 0.3';  // sub-200 fps
            else                      bar_col = '0.3 1 0.4';    // 200 fps+

            float bx = GRAPH_X + i * SLOT_W;
            float by = y + GRAPH_H - h + 2;
            drawfill([bx, by, 0], [BAR_W, h, 0], bar_col, 0.9, 0);
        }

        y += GRAPH_H + 6;
    }

    // ---- Scrolling last-10 frametime strip ----
    // Text form of the same data, most recent first.  Uses the mono
    // font so digits stay column-aligned as values scroll — "2 2 2 10"
    // pops visually without the 10 shifting downstream columns.
    {
        string line = "last10:";
        float recent_head = smooth_head[SMOOTH_M_FT];
        float recent_base = SMOOTH_M_FT * SMOOTH_RING_LEN;
        float k, kpos;
        for (k = 1; k <= 10; k = k + 1)
        {
            kpos = recent_head - k;
            if (kpos < 0) kpos += SMOOTH_RING_LEN;
            if (smooth_count[SMOOTH_M_FT] >= k)
                line = sprintf("%s %4.1f", line, smooth_ring[recent_base + kpos]);
            else
                line = sprintf("%s    -", line);
        }

        float prev_font = drawfont;
        drawfont = hud_font_mono;
        y = dbg_text(x, y, line, DBG_VALUE_COL);
        drawfont = prev_font;
    }

    return y + 6;
};

// ============================================================
//  cl_debug_playermodel — Player Model & Animation
// ============================================================

float(float x, float y) CSQC_DrawDebugPlayerModel =
{
    entity vis = findchain(classname, "player_visual_proxy");
    if (!vis)
    {
        y = dbg_text(x, y, "--- PLAYERMODEL (none) ---", '0.8 0.5 1');
        return y + 6;
    }

    y = dbg_text(x, y, "--- PLAYERMODEL ---", '0.8 0.5 1');

    // Animation State
    y = dbg_text(x, y, "  Animation State", DBG_LABEL_COL);
    y = dbg_line(x, y, "Top Anim",
        sprintf("%.0f (%s)", vis.vis_anim_top, dbg_csanim_str(vis.vis_anim_top)),
        DBG_VALUE_COL);
    y = dbg_line(x, y, "Bot Anim",
        sprintf("%.0f (%s)", vis.vis_anim_bottom, dbg_csanim_str(vis.vis_anim_bottom)),
        DBG_VALUE_COL);
    y = dbg_line(x, y, "Top Time",
        sprintf("%.3fs", vis.vis_anim_top_time), DBG_VALUE_COL);
    y = dbg_line(x, y, "Bot Time",
        sprintf("%.3fs", vis.vis_anim_bottom_time), DBG_VALUE_COL);

    // Engine Fields
    y = dbg_text(x, y, "  Engine Fields", DBG_LABEL_COL);
    y = dbg_line(x, y, "frame",
        sprintf("%.0f  t=%.3f", vis.frame, vis.frame1time), DBG_VALUE_COL);
    y = dbg_line(x, y, "baseframe",
        sprintf("%.0f  t=%.3f", vis.baseframe, vis.baseframe1time), DBG_VALUE_COL);
    y = dbg_line(x, y, "basebone",
        sprintf("%.0f", vis.basebone),
        (vis.basebone > 0) ? DBG_GOOD_COL : DBG_BAD_COL);
    y = dbg_line(x, y, "lerpfrac",
        sprintf("%.3f / base %.3f", vis.lerpfrac, vis.baselerpfrac), DBG_VALUE_COL);

    // Blend Controls
    y = dbg_text(x, y, "  Blend Controls", DBG_LABEL_COL);
    y = dbg_line(x, y, "subblendf",
        sprintf("%.3f / %.3f", vis.subblendfrac, vis.subblend2frac), DBG_VALUE_COL);
    y = dbg_line(x, y, "basesubbl",
        sprintf("%.3f / %.3f", vis.basesubblendfrac, vis.basesubblend2frac), DBG_VALUE_COL);
    y = dbg_line(x, y, "bonectrl",
        sprintf("%.2f %.2f %.2f %.2f %.2f",
            vis.bonecontrol1, vis.bonecontrol2, vis.bonecontrol3,
            vis.bonecontrol4, vis.bonecontrol5),
        DBG_VALUE_COL);

    // Orientation
    y = dbg_text(x, y, "  Orientation", DBG_LABEL_COL);
    y = dbg_line(x, y, "angles",
        sprintf("%.1f %.1f %.1f", vis.angles_x, vis.angles_y, vis.angles_z),
        DBG_VALUE_COL);
    y = dbg_line(x, y, "vis_pitch",
        sprintf("%.2f  (sb=%.3f)", vis.vis_pitch, vis.vis_pitch / 90),
        DBG_VALUE_COL);

    makevectors([0, vis.angles_y, 0]);
    float fCorrect = dotproduct(vis.velocity, v_right) * 0.25;
    y = dbg_line(x, y, "fCorrect",
        sprintf("%.3f", fCorrect), DBG_VALUE_COL);

    vector vel2d = vis.velocity; vel2d_z = 0;
    y = dbg_line(x, y, "vel",
        sprintf("%.1f u/s  (%.0f %.0f %.0f)",
            vlen(vel2d), vis.velocity_x, vis.velocity_y, vis.velocity_z),
        DBG_VALUE_COL);

    // Model Info
    y = dbg_text(x, y, "  Model Info", DBG_LABEL_COL);
    y = dbg_line(x, y, "model", vis.model, DBG_VALUE_COL);
    y = dbg_line(x, y, "bones",
        sprintf("Sp1=%d LTh=%d RTh=%d Pel=%d",
            gettagindex(vis, "Bip01 Spine1"),
            gettagindex(vis, "Bip01 L Thigh"),
            gettagindex(vis, "Bip01 R Thigh"),
            gettagindex(vis, "Bip01 Pelvis")),
        DBG_VALUE_COL);
    y = dbg_line(x, y, "skin/cmap",
        sprintf("%.0f / %.0f", vis.skin, vis.colormap), DBG_VALUE_COL);

    return y + 6;
};

// ============================================================
//  cl_debug_hitboxes — Draw hitbox wireframes on player models
//
//  Uses gettaginfo to get bone world positions/orientations,
//  then draws the hitbox bounding boxes in bone-local space.
//  Hitbox data from the Arctic model (shared by all CS models).
// ============================================================

// Hitbox definitions: bone name, hitgroup, mins, maxs.
// Bone names looked up via gettagindex at runtime — works with any model.
// First 20 = normal hitboxes. Index 20 = shield (only shown with cl_debug_hitboxes 2).
const float HITBOX_COUNT = 20;       // normal hitboxes
const float HITBOX_COUNT_SHIELD = 21; // includes shield

string hitbox_bonename[] = {
    "Bip01 Pelvis",       // group 3 stomach
    "Bip01 L Thigh",      // group 6 left leg
    "Bip01 L Calf",       // group 6
    "Bip01 L Foot",       // group 6
    "Bip01 R Thigh",      // group 7 right leg
    "Bip01 R Calf",       // group 7
    "Bip01 R Foot",       // group 7
    "Bip01 Spine",        // group 3 stomach
    "Bip01 Spine1",       // group 2 chest
    "Bip01 Spine2",       // group 2
    "Bip01 Neck",         // group 2
    "Bip01 Head",         // group 1 head
    "Bip01 L Clavicle",   // group 4 left arm
    "Bip01 L UpperArm",   // group 4
    "Bip01 L Forearm",    // group 4
    "Bip01 L Hand",       // group 4
    "Bip01 R Clavicle",   // group 5 right arm
    "Bip01 R UpperArm",   // group 5
    "Bip01 R Forearm",    // group 5
    "Bip01 R Hand",       // group 5
    "Bip01 L Hand"        // group 8 shield (index 20)
};

float hitbox_group[] = {
    3, 6, 6, 6, 7, 7, 7, 3, 2, 2, 2, 1, 4, 4, 4, 4, 5, 5, 5, 5, 8
};

vector hitbox_mins[] = {
    '-4.69 -4.44 -6.75',
    '2.66 -3.69 -3.09',
    '0.38 -3.97 -2.84',
    '0.85 -3.24 -2.64',
    '2.47 -3.69 -3.16',
    '0.31 -3.97 -2.84',
    '0.85 -3.24 -2.64',
    '-3.25 -5.5 -5.5',
    '-0.06 -5.53 -7.59',
    '-2.25 -6.81 -6.31',
    '-3.11 -1.5 -3',
    '-0.33 -4.5 -2.5',
    '0.94 -2.88 -4.13',
    '-2.16 -2.34 -2.56',
    '0.59 -1.81 -2.19',
    '-0.13 -1.9 -2.24',
    '1.38 -2.84 -3.56',
    '-1.88 -2.47 -2.16',
    '0.44 -1.97 -2.34',
    '-0.13 -1.9 -2.24',
    '-16.1 -6.5 -19'    // shield (hitbox 21)
};

vector hitbox_maxs[] = {
    '4 5.56 6.75',
    '18.16 4.88 3.31',
    '17.6 4 2.94',
    '5.73 8.53 3.17',
    '18.13 4.88 3.38',
    '17.6 3.94 2.97',
    '5.73 8.53 3.17',
    '4.83 5.5 5.5',
    '8 7 7.59',
    '6.5 5.09 6.31',
    '2.05 3.5 3',
    '8 4.5 2.5',
    '5.44 4.28 3.5',
    '11.56 3.41 2.38',
    '10.75 2.84 2.41',
    '4.86 2.08 2.37',
    '5.69 4.31 4.31',
    '11.81 3.28 2.81',
    '10.59 2.72 2.22',
    '4.86 2.08 2.37',
    '10.6 1.5 33'       // shield (hitbox 21)
};

// Color per hitgroup for visualization
vector(float hg) dbg_hitbox_colour =
{
    if (hg == HITGROUP_HEAD)     return '1 0 0';      // red
    if (hg == HITGROUP_CHEST)    return '0 0.8 1';    // cyan
    if (hg == HITGROUP_STOMACH)  return '1 0.8 0';    // yellow
    if (hg == HITGROUP_LEFTARM)  return '0 1 0.3';    // green
    if (hg == HITGROUP_RIGHTARM) return '0 1 0.3';    // green
    if (hg == HITGROUP_LEFTLEG)  return '0.3 0.5 1';  // blue
    if (hg == HITGROUP_RIGHTLEG) return '0.3 0.5 1';  // blue
    if (hg == 8)                return '1 0 1';      // magenta = shield
    return '1 1 1';
};

// Draw a wireframe box edge
void(vector p1, vector p2, vector col, float alpha) dbg_hitbox_line =
{
    CSQC_DebugBeam(p1, p2, 0.5, col, alpha);
};

// Draw hitbox wireframes on all visible player_visual_proxy entities.
// Call BEFORE renderscene (adds to the polygon batch).
void() CSQC_DrawDebugHitboxes =
{
    float dbg_hb = cvar("cl_debug_hitboxes");
    if (!dbg_hb)
        return;

    // cl_debug_hitboxes 1 = normal hitboxes, 2 = include shield
    float count = (dbg_hb >= 2) ? HITBOX_COUNT_SHIELD : HITBOX_COUNT;

    float chase = cvar("chase_active");
    entity vis = findchain(classname, "player_visual_proxy");
    while (vis)
    {
        // Skip own hitboxes unless in chase cam
        if (vis.vis_owner_entnum == player_localentnum && !chase)
        {
            vis = vis.chain;
            continue;
        }
        if (vis.modelindex)
        {
            float i;
            for (i = 0; i < count; i++)
            {
                float bone = gettagindex(vis, hitbox_bonename[i]);
                if (bone <= 0) continue;  // bone not found in this model
                float hg = hitbox_group[i];
                vector bmins = hitbox_mins[i];
                vector bmaxs = hitbox_maxs[i];
                vector col = dbg_hitbox_colour(hg);

                // Get bone world transform
                vector bpos = gettaginfo(vis, bone);
                // v_forward, v_right, v_up now contain the bone's axes

                // Compute 8 corners of the OBB in world space
                vector c0 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmins_z;
                vector c1 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmins_z;
                vector c2 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmins_z;
                vector c3 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmins_z;
                vector c4 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmaxs_z;
                vector c5 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmaxs_z;
                vector c6 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmaxs_z;
                vector c7 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmaxs_z;

                // Draw 12 edges
                dbg_hitbox_line(c0, c1, col, 0.6);
                dbg_hitbox_line(c1, c2, col, 0.6);
                dbg_hitbox_line(c2, c3, col, 0.6);
                dbg_hitbox_line(c3, c0, col, 0.6);

                dbg_hitbox_line(c4, c5, col, 0.6);
                dbg_hitbox_line(c5, c6, col, 0.6);
                dbg_hitbox_line(c6, c7, col, 0.6);
                dbg_hitbox_line(c7, c4, col, 0.6);

                dbg_hitbox_line(c0, c4, col, 0.6);
                dbg_hitbox_line(c1, c5, col, 0.6);
                dbg_hitbox_line(c2, c6, col, 0.6);
                dbg_hitbox_line(c3, c7, col, 0.6);
            }
        }
        vis = vis.chain;
    }
};

// ============================================================
//  sv_debug_hitboxes — Server-side hitbox snapshots
//
//  When the server sends CSQC_EVENT_SERVER_HITBOXES, we create
//  a ghost entity with the exact server state and draw orange
//  wireframes from it. Fades out over 3 seconds.
// ============================================================

const float SV_HITBOX_MAX = 4;
const float SV_HITBOX_LIFETIME = 10;
entity sv_hitbox_ghost[SV_HITBOX_MAX];
float sv_hitbox_time[SV_HITBOX_MAX];
float sv_hitbox_show_shield[SV_HITBOX_MAX];
float sv_hitbox_count;

void(float mdlidx, vector org, vector ang, float fr, float bfr, float bb, float show_shield, float sbf, float sb2f, float bc1, float bc2, float bc3, float bc4) CSQC_AddServerHitbox =
{
    float idx = sv_hitbox_count % SV_HITBOX_MAX;

    if (!sv_hitbox_ghost[idx])
    {
        sv_hitbox_ghost[idx] = spawn();
        sv_hitbox_ghost[idx].classname = "sv_hitbox_ghost";
        sv_hitbox_ghost[idx].solid = SOLID_NOT;
        sv_hitbox_ghost[idx].drawmask = 0; // never rendered by engine
    }

    entity g = sv_hitbox_ghost[idx];
    setmodelindex(g, mdlidx);
    setorigin(g, org);
    g.angles = ang;
    g.frame = fr;
    g.baseframe = bfr;
    g.basebone = bb;
    g.subblendfrac = sbf;
    g.subblend2frac = sb2f;
    g.bonecontrol1 = bc1;
    g.bonecontrol2 = bc2;
    g.bonecontrol3 = bc3;
    g.bonecontrol4 = bc4;
    sv_hitbox_time[idx] = time;
    sv_hitbox_show_shield[idx] = show_shield;
    sv_hitbox_count += 1;
};

// Draw orange wireframe hitboxes from server state snapshots.
void() CSQC_DrawServerHitboxes =
{
    float i, total, age, j;
    total = min(sv_hitbox_count, SV_HITBOX_MAX);

    for (i = 0; i < total; i++)
    {
        age = time - sv_hitbox_time[i];
        if (age > SV_HITBOX_LIFETIME)
            continue;

        entity g = sv_hitbox_ghost[i];
        if (!g || !g.modelindex)
            continue;

        float alpha = 0.7;
        if (age > SV_HITBOX_LIFETIME - 1)
            alpha = 0.7 * (SV_HITBOX_LIFETIME - age);

        // sv_debug_hitboxes 2 on server → show shield on this snapshot
        float sv_count = (sv_hitbox_show_shield[i] >= 2) ? HITBOX_COUNT_SHIELD : HITBOX_COUNT;

        for (j = 0; j < sv_count; j++)
        {
            float bone = gettagindex(g, hitbox_bonename[j]);
            if (bone <= 0) continue;
            vector bmins = hitbox_mins[j];
            vector bmaxs = hitbox_maxs[j];

            // Orange for normal hitboxes, magenta for shield
            vector col = (hitbox_group[j] == 8) ? '1 0 1' : '1 0.5 0';

            vector bpos = gettaginfo(g, bone);

            vector c0 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmins_z;
            vector c1 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmins_z;
            vector c2 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmins_z;
            vector c3 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmins_z;
            vector c4 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmaxs_z;
            vector c5 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmaxs_z;
            vector c6 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmaxs_z;
            vector c7 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmaxs_z;

            dbg_hitbox_line(c0, c1, col, alpha);
            dbg_hitbox_line(c1, c2, col, alpha);
            dbg_hitbox_line(c2, c3, col, alpha);
            dbg_hitbox_line(c3, c0, col, alpha);
            dbg_hitbox_line(c4, c5, col, alpha);
            dbg_hitbox_line(c5, c6, col, alpha);
            dbg_hitbox_line(c6, c7, col, alpha);
            dbg_hitbox_line(c7, c4, col, alpha);
            dbg_hitbox_line(c0, c4, col, alpha);
            dbg_hitbox_line(c1, c5, col, alpha);
            dbg_hitbox_line(c2, c6, col, alpha);
            dbg_hitbox_line(c3, c7, col, alpha);
        }
    }
};

// ============================================================
//  Continuous server hitbox tracking (sv_debug_hitboxes 3)
//  One persistent ghost per player slot, updated every frame.
// ============================================================

const float CONT_HITBOX_MAX = 32;
const float CONT_HITBOX_STALE = 0.2; // hide if no update for this long
entity cont_hitbox_ghost[CONT_HITBOX_MAX];
float cont_hitbox_time[CONT_HITBOX_MAX];
float cont_hitbox_last_packet[CONT_HITBOX_MAX]; // cltime when last packet arrived
float cont_hitbox_pkt_f1t[CONT_HITBOX_MAX];     // frame1time at last packet
float cont_hitbox_pkt_bf1t[CONT_HITBOX_MAX];    // baseframe1time at last packet

void(float entnum, float mdlidx, vector org, vector ang, float fr, float bfr, float bb, float f1t, float bf1t, float sbf, float sb2f, float bc1, float bc2, float bc3, float bc4) CSQC_UpdateContinuousHitbox =
{
    if (entnum < 1 || entnum >= CONT_HITBOX_MAX)
        return;

    if (!cont_hitbox_ghost[entnum])
    {
        cont_hitbox_ghost[entnum] = spawn();
        cont_hitbox_ghost[entnum].classname = "cont_hitbox_ghost";
        cont_hitbox_ghost[entnum].solid = SOLID_NOT;
        cont_hitbox_ghost[entnum].drawmask = 0;
    }

    entity g = cont_hitbox_ghost[entnum];
    setmodelindex(g, mdlidx);
    setorigin(g, org);
    g.angles = ang;
    g.frame = fr;
    g.baseframe = bfr;

    // lerpfrac=1 makes gettaginfo() use .frame; default 0 would use .frame2 (= idle).
    g.lerpfrac = 1;
    g.baselerpfrac = 1;

    g.basebone = bb;
    g.subblendfrac = sbf;
    g.subblend2frac = sb2f;
    g.bonecontrol1 = bc1;
    g.bonecontrol2 = bc2;
    g.bonecontrol3 = bc3;
    g.bonecontrol4 = bc4;
    cont_hitbox_time[entnum] = time;

    // Store server's authoritative animation timestamp + when we received it,
    // so the draw loop can extrapolate between packets and stay in sync with
    // the visual model (which the engine animates on its own clock).
    cont_hitbox_pkt_f1t[entnum]  = f1t;
    cont_hitbox_pkt_bf1t[entnum] = bf1t;
    cont_hitbox_last_packet[entnum] = cltime;
};

void() CSQC_DrawContinuousHitboxes =
{
    float i, j;

    for (i = 1; i < CONT_HITBOX_MAX; i++)
    {
        if (!cont_hitbox_ghost[i])
            continue;
        if (time - cont_hitbox_time[i] > CONT_HITBOX_STALE)
            continue;

        entity g = cont_hitbox_ghost[i];
        if (!g.modelindex)
            continue;

        // Use server's frame1time as baseline + elapsed cltime since packet
        // for smooth interpolation between server updates.
        float since_pkt = max(0, cltime - cont_hitbox_last_packet[i]);
        g.frame1time     = cont_hitbox_pkt_f1t[i]  + since_pkt;
        g.baseframe1time = cont_hitbox_pkt_bf1t[i] + since_pkt;

        for (j = 0; j < HITBOX_COUNT; j++)
        {
            float bone = gettagindex(g, hitbox_bonename[j]);
            if (bone <= 0) continue;

            vector bmins = hitbox_mins[j];
            vector bmaxs = hitbox_maxs[j];
            vector col = '1 0.5 0'; // orange

            vector bpos = gettaginfo(g, bone);

            vector c0 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmins_z;
            vector c1 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmins_z;
            vector c2 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmins_z;
            vector c3 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmins_z;
            vector c4 = bpos + v_forward * bmins_x + v_right * bmins_y + v_up * bmaxs_z;
            vector c5 = bpos + v_forward * bmaxs_x + v_right * bmins_y + v_up * bmaxs_z;
            vector c6 = bpos + v_forward * bmaxs_x + v_right * bmaxs_y + v_up * bmaxs_z;
            vector c7 = bpos + v_forward * bmins_x + v_right * bmaxs_y + v_up * bmaxs_z;

            dbg_hitbox_line(c0, c1, col, 0.7);
            dbg_hitbox_line(c1, c2, col, 0.7);
            dbg_hitbox_line(c2, c3, col, 0.7);
            dbg_hitbox_line(c3, c0, col, 0.7);
            dbg_hitbox_line(c4, c5, col, 0.7);
            dbg_hitbox_line(c5, c6, col, 0.7);
            dbg_hitbox_line(c6, c7, col, 0.7);
            dbg_hitbox_line(c7, c4, col, 0.7);
            dbg_hitbox_line(c0, c4, col, 0.7);
            dbg_hitbox_line(c1, c5, col, 0.7);
            dbg_hitbox_line(c2, c6, col, 0.7);
            dbg_hitbox_line(c3, c7, col, 0.7);
        }
    }
};

// ============================================================
//  cl_debug_bandwidth — Live inbound network breakdown
// ============================================================

float(float offset_idx) _net_sum_bin =
{
    // Sum a per-category bin array over all 10 bins.
    float i, s = 0;
    for (i = 0; i < NET_STAT_BINS; i++)
    {
        if      (offset_idx == 0)  s += net_stat_total[i];
        else if (offset_idx == 1)  s += net_stat_proxy_hdr[i];
        else if (offset_idx == 2)  s += net_stat_proxy_move[i];
        else if (offset_idx == 3)  s += net_stat_proxy_weap[i];
        else if (offset_idx == 4)  s += net_stat_proxy_ammo[i];
        else if (offset_idx == 5)  s += net_stat_visual[i];
        else if (offset_idx == 6)  s += net_stat_triggers[i];
        else if (offset_idx == 7)  s += net_stat_brushes[i];
        else if (offset_idx == 8)  s += net_stat_events[i];
        else if (offset_idx == 9)  s += net_hit_move[i];
        else if (offset_idx == 10) s += net_hit_weap[i];
        else if (offset_idx == 11) s += net_hit_ammo[i];
        else if (offset_idx == 12) s += net_hit_visual_self[i];
        else if (offset_idx == 13) s += net_hit_visual_remote[i];
        else if (offset_idx == 14) s += net_hit_events[i];
        else if (offset_idx == 15) s += net_hit_proxy_hdr[i];
    }
    return s;
};

float(float x, float y) CSQC_DrawDebugBandwidth =
{
    CSQC_NetStat_Advance();  // make sure bins are fresh even when no packets arrive

    float total_bps  = _net_sum_bin(0);
    float proxy_hdr  = _net_sum_bin(1);
    float proxy_mv   = _net_sum_bin(2);
    float proxy_wp   = _net_sum_bin(3);
    float proxy_am   = _net_sum_bin(4);
    float visual     = _net_sum_bin(5);
    float triggers   = _net_sum_bin(6);
    float brushes    = _net_sum_bin(7);
    float events     = _net_sum_bin(8);
    float hit_mv     = _net_sum_bin(9);
    float hit_wp     = _net_sum_bin(10);
    float hit_am     = _net_sum_bin(11);
    float hit_vs_self   = _net_sum_bin(12);
    float hit_vs_remote = _net_sum_bin(13);
    float hit_ev     = _net_sum_bin(14);
    float hit_snap   = _net_sum_bin(15);

    float proxy_total = proxy_hdr + proxy_mv + proxy_wp + proxy_am;
    vector col;

    y = dbg_text(x, y, "--- BANDWIDTH IN (1s window) ---", '0.7 0.4 1');

    col = (total_bps < 10000) ? DBG_GOOD_COL : (total_bps < 25000) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Total", sprintf("%.2f KB/s", total_bps / 1024), col);

    // Raw snapshot cadence — how often a proxy packet arrived regardless of dirty bits.
    // This is the server's effective send rate for this client (sv_maxtic capped by cl_netfps/rate).
    col = (hit_snap >= 60) ? DBG_GOOD_COL : (hit_snap >= 40) ? DBG_WARN_COL : DBG_BAD_COL;
    y = dbg_line(x, y, "Send rate", sprintf("%.0f Hz", hit_snap), col);

    // Configured server tick (from sv_mintic, pushed as serverinfo by
    // SV_UpdateMovementServerInfo).  Reads the authoritative value rather
    // than the empirical snapshot-arrival measurement above — any gap
    // between them is network / scheduler jitter.
    float cfg_mintic = stof(serverkey("sv_mintic"));
    if (cfg_mintic > 0)
    {
        float cfg_hz = 1.0 / cfg_mintic;
        vector tcol = DBG_VALUE_COL;
        // Warn if measured send-rate drifts > 10% from configured tick.
        if (hit_snap > 0 && fabs(hit_snap - cfg_hz) / cfg_hz > 0.1)
            tcol = DBG_WARN_COL;
        y = dbg_line(x, y, "Tick cfg",
            sprintf("%.1f Hz (%.5fs)", cfg_hz, cfg_mintic), tcol);
    }

    y = dbg_line(x, y, "PM_Proxy", sprintf("%.2f KB/s", proxy_total / 1024), DBG_VALUE_COL);
    y = dbg_line(x, y, " movement", sprintf("%.2f KB/s  %.0f Hz", proxy_mv / 1024, hit_mv),
        hit_mv > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);
    y = dbg_line(x, y, " weapon",   sprintf("%.2f KB/s  %.0f Hz", proxy_wp / 1024, hit_wp),
        hit_wp > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);
    y = dbg_line(x, y, " ammo",     sprintf("%.2f KB/s  %.0f Hz", proxy_am / 1024, hit_am),
        hit_am > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);

    y = dbg_line(x, y, "Visuals",  sprintf("%.2f KB/s", visual / 1024), DBG_VALUE_COL);
    y = dbg_line(x, y, " self",    sprintf("%.0f Hz", hit_vs_self),
        hit_vs_self > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);
    y = dbg_line(x, y, " remotes", sprintf("%.0f Hz", hit_vs_remote),
        hit_vs_remote > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);

    y = dbg_line(x, y, "Triggers", sprintf("%.2f KB/s", triggers / 1024), DBG_VALUE_COL);
    y = dbg_line(x, y, "Brushes",  sprintf("%.2f KB/s", brushes / 1024), DBG_VALUE_COL);
    y = dbg_line(x, y, "Events",   sprintf("%.2f KB/s  %.0f /s", events / 1024, hit_ev),
        hit_ev > 0 ? DBG_VALUE_COL : DBG_LABEL_COL);

    return y + 6;
};

// ============================================================
//  Master debug panel draw — called from CSQC_UpdateView
// ============================================================

void() CSQC_DrawDebugPanels =
{
    float x = 8;
    float y = 8;

    // Render the debug overlays with the same font the engine console uses
    // (data/default.cfg sets con_textfont "gfx/RobotoEB") — that's what the
    // "hud" slot is loaded with in CSQC_Init, so point drawfont at it here
    // and restore afterwards so other drawstring callers are unaffected.
    float prev_font = drawfont;
    drawfont = hud_font;

    if (cvar("cl_debug_net"))
        y = CSQC_DrawDebugNet(x, y);
    if (cvar("cl_debug_bandwidth"))
        y = CSQC_DrawDebugBandwidth(x, y);
    if (cvar("cl_debug_weapon"))
        y = CSQC_DrawDebugWeapon(x, y);
    if (cvar("cl_debug_move"))
        y = CSQC_DrawDebugMove(x, y);
    if (cvar("cl_debug_game"))
        y = CSQC_DrawDebugGame(x, y);
    if (cvar("cl_debug_smoothing"))
        y = CSQC_DrawDebugSmoothing(x, y);
    if (cvar("cl_debug_playermodel"))
        y = CSQC_DrawDebugPlayerModel(x, y);

    drawfont = prev_font;
};

