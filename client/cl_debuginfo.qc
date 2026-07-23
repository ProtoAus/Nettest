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
const float NET_SZ_PROXY_MOVE   = 130; // movement section (grew: ~9 coords + many floats/bytes + optional +24 in-car block)
const float NET_SZ_PROXY_WEAP   = 17; // 8 bytes + 2 floats + zoomstage
const float NET_SZ_PROXY_AMMO   = 45; // 45 mag/ammo/silencer bytes
const float NET_SZ_PLAYER_VIS   = 53;
const float NET_SZ_PUSH_TRIG    = 57;
const float NET_SZ_TELE_TRIG    = 69;
const float NET_SZ_LADDER_TRIG  = 49;
const float NET_SZ_SOLID_BRUSH  = 80;  // avg (static 74, door ~104)
const float NET_SZ_PHYS_PROP    = 94;  // phys_files_Send: 21 WriteCoord×4 (sv_bigcoords) + colormod/istrimesh/phase/carrier/is_car bytes + modelindex short

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
float net_stat_props[NET_STAT_BINS];   // phys-prop CSQC mirrors (barrels/cans/cabinet) — the flood category

// Section-hit counts (how many ticks received SF_*)
float net_hit_move[NET_STAT_BINS];
float net_hit_weap[NET_STAT_BINS];
float net_hit_ammo[NET_STAT_BINS];
float net_hit_visual_self[NET_STAT_BINS];    // own player_visual_proxy
float net_hit_visual_remote[NET_STAT_BINS];  // other players' visuals
float net_hit_events[NET_STAT_BINS];
float net_hit_proxy_hdr[NET_STAT_BINS];       // raw snapshot cadence (1 per proxy packet)
float net_hit_props[NET_STAT_BINS];           // phys-prop updates received (updates/s — reveals server round-robin throttling)

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
        net_stat_props[i] = 0;
        net_hit_props[i] = 0;
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

// Phys-prop CSQC mirror update (barrel/can/cabinet) — one 93-byte snapshot per receive.
// Counts REAL received updates, so a spawnflood's Props row shows the true on-wire cost AND the
// updates/s (bytes÷93), which drops far below spawned×tickrate when the server throttles/round-robins.
void() CSQC_NetStat_RecordProp =
{
    CSQC_NetStat_Advance();
    net_stat_props[net_stat_bin_idx] += NET_SZ_PHYS_PROP;
    net_stat_total[net_stat_bin_idx] += NET_SZ_PHYS_PROP;
    net_hit_props[net_stat_bin_idx]  += 1;
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

// Draw a wireframe line between two 3D points.  Default (cl_debug_wire_thickness <= 1):
// submit EXACTLY two vertices so the engine flags the batch BEF_LINES and draws a real
// GL_LINES primitive (pr_csqc.c PF_R_PolygonEnd: nv==2 -> BEF_LINES) — no camera-facing
// quad, no orientation math, half the verts, 1 line vs 2 filled tris, ~1px.
//   cl_debug_wire_thickness > 1: fall back to a camera-facing quad of that width via
// CSQC_DebugBeam.  GL line width (glLineWidth) is unreliable — the CSQC batch never sets
// it and core profiles clamp it to 1px — so real thickness has to be geometry.  The cvar
// is read once per frame (cltime gate) so the per-edge cost is just a compare even across
// thousands of edges.
float dbg_wire_thick;       // cached cl_debug_wire_thickness, refreshed once per frame
float dbg_wire_thick_time;  // cltime of the last refresh
void(vector p1, vector p2, vector colour, float alpha) CSQC_DebugLine =
{
    if (cltime != dbg_wire_thick_time)
    {
        dbg_wire_thick_time = cltime;
        dbg_wire_thick = cvar("cl_debug_wire_thickness");
    }
    if (dbg_wire_thick > 1)
    {
        CSQC_DebugBeam(p1, p2, dbg_wire_thick, colour, alpha);  // thick = real quad geometry
        return;
    }
    R_BeginPolygon("", 0, 0);
    R_PolygonVertex(p1, '0 0 0', colour, alpha);
    R_PolygonVertex(p2, '0 0 0', colour, alpha);
    R_EndPolygon();
};

// Draw all active debug impact markers. Call from CSQC_UpdateView.
void() CSQC_DrawDebugImpacts =
{
    float i, total, age;
    vector pos, eye, colour;
    float s = DEBUG_CROSS_SIZE;

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

        // Draw 3D cross at impact point (thin wireframe lines)
        CSQC_DebugLine(pos - '1 0 0' * s, pos + '1 0 0' * s, colour, alpha);
        CSQC_DebugLine(pos - '0 1 0' * s, pos + '0 1 0' * s, colour, alpha);
        CSQC_DebugLine(pos - '0 0 1' * s, pos + '0 0 1' * s, colour, alpha);

        // Draw line from eye position at time of firing to impact
        if (eye != '0 0 0')
            CSQC_DebugLine(eye, pos, colour, alpha * 0.15);

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
// Trailing post-replay origin from the previous reconcile.  Used by the
// smooth-local lock to gate on per-snapshot server motion (catch-up tail
// vs sudden push) rather than cumulative live-vs-server divergence.
vector smooth_prev_post_origin;

// Live values exposed by CSQC_ReconcilePrediction's smoother block so
// the cl_debug_drift overlay (CSQC_DrawDebugDrift below) can show them.
// Updated once per reconcile, read every render frame.
float  smooth_local_dbg_elen;            // |pre - post| this reconcile
float  smooth_local_dbg_dpost;           // |post - prev_post| this reconcile
float  smooth_local_dbg_wants_motion;    // live input had movement / jump
float  smooth_local_dbg_lock_active;     // lock branch fired this reconcile
float  smooth_local_dbg_last_reconcile;  // cltime of most recent reconcile
float  smooth_local_dbg_last_snap;       // cltime of most recent teleport-snap branch fire

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
    smooth_prev_post_origin    = '0 0 0';
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
    else if (gm == GAMEMODE_FFA)         gm_label = "Free For All";
    else if (gm == GAMEMODE_PAINTGUN)    gm_label = "Paintball";
    else if (gm == GAMEMODE_DEFUSE)      gm_label = "Defuse";
    else if (gm == GAMEMODE_PROPHUNT)    gm_label = "Prop Hunt";
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
// The per-bone hitbox table (HITBOX_COUNT / hitbox_bonename / hitbox_group /
// hitbox_mins / hitbox_maxs) moved to shared/sh_weapons.qc so the SERVER can
// classify hitgroups by box too (W_HitgroupClassify SSQC path).  Still used
// here for the debug draws + the client OBB trace below.

// ============================================================
//  Full OBB hitbox DETECTION (player hit trace)
//  The bullet ray is tested against the same 20 per-bone oriented boxes drawn
//  above, so what you shoot matches what you see, and the hitgroup is the box
//  you hit — not a Z-height guess.  Drives CSQC_PredictedImpact under
//  sv_trust_clienthits.  Results go to the csqc_obb_* globals (cl_customdefs.qc).
// ============================================================

// Make every remote-player proxy non-solid (so the world traceline reports the
// WALL behind a player, letting the OBB pass own player detection).
void() CSQC_PlayersUnsolid =
{
    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        p.solid = SOLID_NOT;
        p = p.chain;
    }
};

// Restore the normal solidity policy (mirrors cl_player.qc: live remote players
// SOLID_BBOX, own + dead SOLID_NOT) after the world trace.
void() CSQC_PlayersResolid =
{
    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (p.modelindex
            && p.vis_owner_entnum != player_localentnum
            && !p.vis_server_is_dead)
            p.solid = SOLID_BBOX;
        p = p.chain;
    }
};

// Ray (src..end) vs every live remote proxy's per-bone OBBs.  Keeps the CLOSEST
// box hit strictly nearer than limit_frac (the world/wall fraction).  Writes the
// csqc_obb_* result globals.  Standard slab ray-vs-AABB done in each bone's local
// frame (gettaginfo gives the bone origin + orthonormal axes v_forward/right/up;
// the boxes are axis-aligned in that frame, exactly as the debug draw builds them).
void(vector src, vector end, float limit_frac) CSQC_TraceHitboxes =
{
    csqc_obb_hit  = FALSE;
    csqc_obb_ent  = world;
    csqc_obb_frac = limit_frac;
    vector dir = end - src;

    entity proxy = findchain(classname, "player_visual_proxy");
    while (proxy)
    {
        // Live remote players only (own + dead proxies aren't shootable).
        if (proxy.modelindex
            && proxy.vis_owner_entnum != player_localentnum
            && !proxy.vis_server_is_dead)
        {
            // Broad phase: skip the 20-box loop unless the ray passes within a
            // generous radius of the player's center (covers any pose + limbs).
            float tproj = ((proxy.origin - src) * dir) / (dir * dir);
            tproj = bound(0, tproj, 1);
            if (vlen((src + dir * tproj) - proxy.origin) > 80)
            {
                proxy = proxy.chain;
                continue;
            }

            float i;
            float matched = 0;
            for (i = 0; i < HITBOX_COUNT; i++)
            {
                float bone = gettagindex(proxy, hitbox_bonename[i]);
                if (bone <= 0)
                    continue;
                matched = matched + 1;
                vector bpos = gettaginfo(proxy, bone);
                vector vf = v_forward, vr = v_right, vu = v_up;
                vector bmn = hitbox_mins[i], bmx = hitbox_maxs[i];

                // Ray into the bone's local frame.
                vector rel = src - bpos;
                float lsx = rel * vf, lsy = rel * vr, lsz = rel * vu;
                float ldx = dir * vf, ldy = dir * vr, ldz = dir * vu;

                float tmin = 0, tmax = csqc_obb_frac;
                float ok = TRUE;
                float t1, t2, tt;

                // X slab
                if (ldx != 0)
                {
                    t1 = (bmn_x - lsx) / ldx; t2 = (bmx_x - lsx) / ldx;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (lsx < bmn_x || lsx > bmx_x) ok = FALSE;
                // Y slab
                if (ok && ldy != 0)
                {
                    t1 = (bmn_y - lsy) / ldy; t2 = (bmx_y - lsy) / ldy;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (ok && ldy == 0 && (lsy < bmn_y || lsy > bmx_y)) ok = FALSE;
                // Z slab
                if (ok && ldz != 0)
                {
                    t1 = (bmn_z - lsz) / ldz; t2 = (bmx_z - lsz) / ldz;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (ok && ldz == 0 && (lsz < bmn_z || lsz > bmx_z)) ok = FALSE;

                if (ok && tmin <= tmax && tmax >= 0)
                {
                    float ht = (tmin < 0) ? 0 : tmin;   // src inside box -> hit at entry
                    if (ht < csqc_obb_frac)
                    {
                        csqc_obb_hit   = TRUE;
                        csqc_obb_frac  = ht;
                        csqc_obb_group = hitbox_group[i];
                        csqc_obb_ent   = proxy;
                        csqc_obb_pos   = src + dir * ht;
                    }
                }
            }

            // Fallback: a model with NONE of the Bip01 bones (a custom rig such
            // as the chicken / number-key player models) would otherwise be
            // un-shootable.  Trace its hull AABB so it still registers — GENERIC
            // hitgroup (no per-zone boxes available for it).
            if (matched == 0)
            {
                vector amn = proxy.origin + proxy.mins;
                vector amx = proxy.origin + proxy.maxs;
                float tmin = 0, tmax = csqc_obb_frac, ok = TRUE;
                float t1, t2, tt;
                if (dir_x != 0)
                {
                    t1 = (amn_x - src_x) / dir_x; t2 = (amx_x - src_x) / dir_x;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (src_x < amn_x || src_x > amx_x) ok = FALSE;
                if (ok && dir_y != 0)
                {
                    t1 = (amn_y - src_y) / dir_y; t2 = (amx_y - src_y) / dir_y;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (ok && dir_y == 0 && (src_y < amn_y || src_y > amx_y)) ok = FALSE;
                if (ok && dir_z != 0)
                {
                    t1 = (amn_z - src_z) / dir_z; t2 = (amx_z - src_z) / dir_z;
                    if (t1 > t2) { tt = t1; t1 = t2; t2 = tt; }
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                }
                else if (ok && dir_z == 0 && (src_z < amn_z || src_z > amx_z)) ok = FALSE;

                if (ok && tmin <= tmax && tmax >= 0)
                {
                    float ht = (tmin < 0) ? 0 : tmin;
                    if (ht < csqc_obb_frac)
                    {
                        csqc_obb_hit   = TRUE;
                        csqc_obb_frac  = ht;
                        csqc_obb_group = HITGROUP_GENERIC;
                        csqc_obb_ent   = proxy;
                        csqc_obb_pos   = src + dir * ht;
                    }
                }
            }
        }
        proxy = proxy.chain;
    }
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
    return '1 1 1';
};

// nettest Patch 36: debug wireframe edges draw as immediate-mode lines via CSQC_DebugLine
// — R_BeginPolygon with exactly 2 verts, which the engine flags BEF_LINES and draws as true
// GL_LINES (pr_csqc.c:1635): cheaper than the old camera-facing quads (half the verts, no
// per-edge orientation math) and an actual 1px wireframe.  This was briefly switched to particle
// beams (particles/debug.cfg), but FTE 'type beam' segments come from a tiny HARDCODED
// 2048-slot pool (MAX_BEAMSEGS, p_script.c:396) shared with weapon tracers/gauss/egon —
// and each box edge subdivides into length/step segments, so once ~8 boxes filled the
// pool every box above the spine silently dropped, and it fought combat FX for slots.
// R_BeginPolygon has no such cap (32k verts/batch) — so the perf reason for the particle switch didn't hold.
void(vector p1, vector p2, vector col, float alpha) dbg_hitbox_line =
{
    CSQC_DebugLine(p1, p2, col, alpha);   // true 1px GL_LINES wireframe (was a camera-facing quad)
};

// Draw hitbox wireframes on all visible player_visual_proxy entities.
// Call BEFORE renderscene (adds to the polygon batch).
void() CSQC_DrawDebugHitboxes =
{
    if (!cvar("cl_debug_hitboxes"))
        return;

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
            for (i = 0; i < HITBOX_COUNT; i++)
            {
                float bone = gettagindex(vis, hitbox_bonename[i]);
                if (bone <= 0) continue;  // bone not found in this model
                float hg = hitbox_group[i];
                vector bmins = hitbox_mins[i];
                vector bmaxs = hitbox_maxs[i];
                vector col = dbg_hitbox_colour(hg);

                // Get bone world transform
                vector bpos = gettaginfo(vis, bone);
                // v_forward, v_right, v_up now contain the bone's axes.
                // nettest Patch 36: gettaginfo returns v_right = -col1 (bonemat_toqcvectors
                // negates it), but the engine hitbox trace uses the raw col1 — so the drawn box
                // was Y-mirrored vs the actual hitbox (backwards feet).  Negate to match the trace.
                v_right = -v_right;

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
//  cl_debug_hbexpand — Draw expanded server trace-bbox wireframe
//
//  Server-side, W_PlayersExpandHitboxes inflates each alive player's
//  bounding box by sv_hitbox_expand on X and Y (Z untouched) just before
//  weapon traces fire, so MOVE_HITMODEL can reach outstretched limbs.
//  This visualises the expanded box as a wireframe at each remote
//  player's predicted origin so you can see exactly what bullets are
//  testing against.
//
//  Source of truth for the box dimensions:
//    * standing  → PM_MINS / PM_MAXS  (sh_pmove.qc, set by PM_ReadMovevars)
//    * ducking   → PM_DUCK_MINS / PM_DUCK_MAXS
//    * inflation → cvar("sv_hitbox_expand") on X, Y, AND Z
//  Z expansion is critical for ducking — duck cap is +18u above origin,
//  the head bone often sits above that, and without Z forgiveness the
//  bbox cull rejects head shots before MOVE_HITMODEL's per-bone test.
//  Duck state per remote = vis.flags & FL_DUCKING (received via VP_SF_ANIM).
//  sv_hitbox_expand is read locally; on a remote (non-listen) server you'll
//  see your own configured value, not the server's authoritative value —
//  good enough for development against your own listen instance.
// ============================================================

void() CSQC_DrawDebugHitboxExpand =
{
    if (!cvar("cl_debug_hbexpand"))
        return;

    float expand = cvar("sv_hitbox_expand");
    if (expand < 0) expand = 0;

    float chase = cvar("chase_active");
    vector col   = '0 1 1';   // cyan — distinct from cl_debug_hitboxes' per-group palette
    float  alpha = 0.7;

    entity vis = findchain(classname, "player_visual_proxy");
    while (vis)
    {
        // Skip own hitbox unless in chase cam — same convention as
        // CSQC_DrawDebugHitboxes; in first-person you'd be inside the
        // box and the lines would just clutter the centre of the view.
        if (vis.vis_owner_entnum == player_localentnum && !chase)
        {
            vis = vis.chain;
            continue;
        }
        if (!vis.modelindex || vis.vis_is_dead)
        {
            vis = vis.chain;
            continue;
        }

        vector mn, mx;
        if (vis.flags & FL_DUCKING)
        {
            mn = PM_DUCK_MINS;
            mx = PM_DUCK_MAXS;
        }
        else
        {
            mn = PM_MINS;
            mx = PM_MAXS;
        }

        // Inflate all three axes — mirrors W_PlayersExpandHitboxes.
        mn_x -= expand; mn_y -= expand; mn_z -= expand;
        mx_x += expand; mx_y += expand; mx_z += expand;

        vector o = vis.origin;
        // 8 axis-aligned corners
        vector c0 = o + [mn_x, mn_y, mn_z];
        vector c1 = o + [mx_x, mn_y, mn_z];
        vector c2 = o + [mx_x, mx_y, mn_z];
        vector c3 = o + [mn_x, mx_y, mn_z];
        vector c4 = o + [mn_x, mn_y, mx_z];
        vector c5 = o + [mx_x, mn_y, mx_z];
        vector c6 = o + [mx_x, mx_y, mx_z];
        vector c7 = o + [mn_x, mx_y, mx_z];

        // 12 edges: bottom rect, top rect, four verticals
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

        vis = vis.chain;
    }
};

// ============================================================
//  cl_debug_physdrop_bbox — phys-drop bbox wireframes
//
//  0 = off, 1 = ODE tight box (rotated with .angles, green),
//  2 = trace-inflated AABB (axis-aligned, orange), 3 = both.
//  ODE-tight reconstructs from sv_physdrop_bbox_{x,y,z} (the same
//  cvars the server feeds W_PhysDropEnable's setsize) — CSQC's
//  self.mins/.maxs is the pickup-touch AABB, NOT the ODE collision
//  shape, so reading those directly would render a misleading box.
//  Trace-inflated reads sv_physdrop_trace_bbox_{x,y,z} (CVAR_SIDE_BOTH
//  so cvar() works clientside without serverinfo).
// ============================================================

void() CSQC_DrawDebugPhysDropBboxes =
{
    float mode = cvar("cl_debug_physdrop_bbox");
    if (mode <= 0) return;

    float bx = cvar("sv_physprop_weapon_bbox_x");
    float by = cvar("sv_physprop_weapon_bbox_y");
    float bz = cvar("sv_physprop_weapon_bbox_z");
    float tx = cvar("sv_physprop_weapon_trace_bbox_x");
    float ty = cvar("sv_physprop_weapon_trace_bbox_y");
    float tz = cvar("sv_physprop_weapon_trace_bbox_z");

    // Alias models render with their pitch multiplied by r_meshpitch (-1 by default — the
    // classic inverted-Quake-model pitch).  The rotated ODE box below must use the same
    // convention or it won't line up with the dropped-weapon model on a sloped floor.
    float mp = cvar("r_meshpitch");
    if (mp == 0) mp = -1;

    entity w = findchain(classname, "csqc_dropped_weapon");
    while (w)
    {
        if (w.modelindex && w.dropped_weapon_physdrop)
        {
            vector o = w.origin;

            if ((mode == 1 || mode == 3) && bx > 0 && by > 0 && bz > 0)
            {
                // ODE-tight half-extents from the server-side cvars,
                // rotated by the drop's current .angles so the visual
                // matches the physics body orientation.  Apply r_meshpitch
                // to the pitch so the box tracks the rendered model (which
                // the engine pitch-inverts for alias models).
                vector ang = w.angles;
                ang_x = ang_x * mp;
                makevectors(ang);
                vector mn = [-bx, -by, -bz];
                vector mx = [ bx,  by,  bz];
                vector gcol = '0 1 0';
                float galpha = 0.8;
                vector g0 = o + v_forward*mn_x + v_right*mn_y + v_up*mn_z;
                vector g1 = o + v_forward*mx_x + v_right*mn_y + v_up*mn_z;
                vector g2 = o + v_forward*mx_x + v_right*mx_y + v_up*mn_z;
                vector g3 = o + v_forward*mn_x + v_right*mx_y + v_up*mn_z;
                vector g4 = o + v_forward*mn_x + v_right*mn_y + v_up*mx_z;
                vector g5 = o + v_forward*mx_x + v_right*mn_y + v_up*mx_z;
                vector g6 = o + v_forward*mx_x + v_right*mx_y + v_up*mx_z;
                vector g7 = o + v_forward*mn_x + v_right*mx_y + v_up*mx_z;
                dbg_hitbox_line(g0,g1,gcol,galpha); dbg_hitbox_line(g1,g2,gcol,galpha);
                dbg_hitbox_line(g2,g3,gcol,galpha); dbg_hitbox_line(g3,g0,gcol,galpha);
                dbg_hitbox_line(g4,g5,gcol,galpha); dbg_hitbox_line(g5,g6,gcol,galpha);
                dbg_hitbox_line(g6,g7,gcol,galpha); dbg_hitbox_line(g7,g4,gcol,galpha);
                dbg_hitbox_line(g0,g4,gcol,galpha); dbg_hitbox_line(g1,g5,gcol,galpha);
                dbg_hitbox_line(g2,g6,gcol,galpha); dbg_hitbox_line(g3,g7,gcol,galpha);
            }

            if ((mode == 2 || mode == 3) && tx > 0 && ty > 0 && tz > 0)
            {
                // Trace-inflated AABB — always axis-aligned (server wraps
                // it around hitscan traces without rotation).
                vector ocol = '1 0.4 0';
                float oalpha = 0.5;
                vector t0 = o + [-tx, -ty, -tz];
                vector t1 = o + [ tx, -ty, -tz];
                vector t2 = o + [ tx,  ty, -tz];
                vector t3 = o + [-tx,  ty, -tz];
                vector t4 = o + [-tx, -ty,  tz];
                vector t5 = o + [ tx, -ty,  tz];
                vector t6 = o + [ tx,  ty,  tz];
                vector t7 = o + [-tx,  ty,  tz];
                dbg_hitbox_line(t0,t1,ocol,oalpha); dbg_hitbox_line(t1,t2,ocol,oalpha);
                dbg_hitbox_line(t2,t3,ocol,oalpha); dbg_hitbox_line(t3,t0,ocol,oalpha);
                dbg_hitbox_line(t4,t5,ocol,oalpha); dbg_hitbox_line(t5,t6,ocol,oalpha);
                dbg_hitbox_line(t6,t7,ocol,oalpha); dbg_hitbox_line(t7,t4,ocol,oalpha);
                dbg_hitbox_line(t0,t4,ocol,oalpha); dbg_hitbox_line(t1,t5,ocol,oalpha);
                dbg_hitbox_line(t2,t6,ocol,oalpha); dbg_hitbox_line(t3,t7,ocol,oalpha);
            }
        }
        w = w.chain;
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
float sv_hitbox_count;

void(float mdlidx, vector org, vector ang, float fr, float bfr, float bb, float f1t, float bf1t, float sbf, float sb2f, float bc1, float bc2, float bc3, float bc4) CSQC_AddServerHitbox =
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
    g.frame1time = f1t;
    g.baseframe = bfr;
    g.baseframe1time = bf1t;
    // cs_getframestate: weight(.frame) = 1-lerpfrac, weight(.frame2) = lerpfrac.
    // So lerpfrac MUST be 0 to use .frame; lerpfrac=1 selected .frame2 (unset = the
    // dummy sequence 0) — THAT was the "stuck on the bind pose" bug.  Same for base.
    g.lerpfrac = 0;
    g.baselerpfrac = 0;
    g.frame2 = 0;
    g.baseframe2 = 0;
    g.basebone = bb;
    g.subblendfrac = sbf;
    g.subblend2frac = sb2f;
    g.bonecontrol1 = bc1;
    g.bonecontrol2 = bc2;
    g.bonecontrol3 = bc3;
    g.bonecontrol4 = bc4;
    sv_hitbox_time[idx] = time;
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

        vector col = '1 0.5 0'; // orange

        for (j = 0; j < HITBOX_COUNT; j++)
        {
            float bone = gettagindex(g, hitbox_bonename[j]);
            if (bone <= 0) continue;
            vector bmins = hitbox_mins[j];
            vector bmaxs = hitbox_maxs[j];

            vector bpos = gettaginfo(g, bone);
            v_right = -v_right;   // Patch 36: match the engine trace's box frame (see CSQC_DrawDebugHitboxes)

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
//  Continuous server hitbox tracking (sv_debug_hitboxes 2)
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

    // cs_getframestate weights .frame by (1-lerpfrac) and .frame2 by lerpfrac, so
    // lerpfrac MUST be 0 to pose from .frame; lerpfrac=1 used .frame2 (unset = dummy
    // sequence 0) — the "stuck on bind pose" bug.  No QC skeleton on the ghost, so the
    // engine spine-bend (r_skel_spinebend) applies the lean = exactly the server trace.
    g.lerpfrac = 0;
    g.baselerpfrac = 0;
    g.frame2 = 0;
    g.baseframe2 = 0;

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
        // Skip own hitboxes unless in chase cam — mirrors CSQC_DrawDebugHitboxes
        if (i == player_localentnum && !cvar("chase_active"))
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
            v_right = -v_right;   // Patch 36: match the engine trace's box frame (see CSQC_DrawDebugHitboxes)

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
        else if (offset_idx == 16) s += net_stat_props[i];
        else if (offset_idx == 17) s += net_hit_props[i];
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
    float props      = _net_sum_bin(16);
    float hit_props  = _net_sum_bin(17);

    float proxy_total = proxy_hdr + proxy_mv + proxy_wp + proxy_am;
    vector col;

    y = dbg_text(x, y, "--- BANDWIDTH IN (1s window) ---", '0.7 0.4 1');

    // The bandwidth "cap" is only real on a ROUTED connection: the server enforces
    // SV_RateForClient = min(rate, sv_maxrate).  A listen-server LOCAL player is LOOPBACK, which the
    // engine EXEMPTS from the bandwidth choke (Netchan_CanPacket) — so rate/sv_maxrate are NOT
    // enforced for you; the real ceiling is the per-packet datagram size (entity round-robin) + CPU.
    // Detect loopback from the connection address ("...QLoopBack:0").
    float is_loop = (strstrofs(serverkey("ip"), "QLoopBack", 0) >= 0);
    float rc = cvar("rate");
    float mr = cvar("sv_maxrate");   // real on a listen server (same process); 0 on a pure client
    float eff_cap = rc;
    if (mr > 0 && (eff_cap <= 0 || mr < eff_cap)) eff_cap = mr;

    col = (total_bps < 10000) ? DBG_GOOD_COL : (total_bps < 25000) ? DBG_WARN_COL : DBG_BAD_COL;
    if (!is_loop && eff_cap > 0 && total_bps > eff_cap * 0.9) col = DBG_BAD_COL;   // near the enforced cap = saturated
    // %8.2f = fixed field (up to 5 integer digits) so the live value never shoves the following text.
    y = dbg_line(x, y, "Total", sprintf("%8.2f KB/s", total_bps / 1024), col);
    if (is_loop)
        y = dbg_line(x, y, "BW cap", "loopback: none (MTU+CPU limited)", DBG_LABEL_COL);
    else
        y = dbg_line(x, y, "BW cap", sprintf("%8.2f KB/s (min rate,maxrate)", eff_cap / 1024), DBG_VALUE_COL);

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

    // Phys-prop mirrors (barrels/cans/cabinet) — the spawnflood category.  The updates/s number is the
    // key tell: a big flood should stream spawned×tickrate, but the server caps it, so a low updates/s
    // with a high KB/s = the props are eating the budget and starving other updates.
    col = (props / 1024 > 8) ? DBG_BAD_COL : (props > 0 ? DBG_WARN_COL : DBG_LABEL_COL);
    y = dbg_line(x, y, "Props",    sprintf("%8.2f KB/s  %5.0f upd/s", props / 1024, hit_props), col);

    return y + 6;
};

// ============================================================
//  cl_debug_drift — live local-prediction-drift overlay
//
//  Summarises the state the cl_driftlock lock cares about:
//
//    Smoother on/off       — is cl_driftlock active.
//    Wants motion          — is the user pressing a movement / jump
//                            key on the live tick.  Drives the lock
//                            gate.  When 0 + smoother on, the camera
//                            is held at the live trajectory.
//    Lock                  — did the lock branch fire on the most
//                            recent reconcile.  ACTIVE = camera is
//                            being held; OFF = pass-through (smoother
//                            or snap path).
//    Drift (elen)          — |pre - post| this reconcile.  Cumulative
//                            divergence between live (camera) and
//                            post-replay (server view).  Grows while
//                            locked; resets when smoother absorbs.
//    dpost                 — |post - prev_post| this reconcile.  How
//                            much the server's authoritative origin
//                            advanced this snapshot.  Diagnostic only;
//                            no longer gates the lock.
//    Smooth offset         — magnitude of the in-flight smoother
//                            offset (decaying toward 0 over fade
//                            time).  Non-zero when smoother is fading.
//    Snap @                — teleport / respawn threshold.  Above this,
//                            the smoother branch is skipped and the
//                            camera snaps instantly.
// ============================================================

float(float x, float y) CSQC_DrawDebugDrift =
{
    y = dbg_text(x, y, "--- DRIFT ---", '0.5 0.8 1');

    // --- Smoother on/off ---
    float smooth_on = (cvar_string("cl_driftlock") == ""
                       || cvar("cl_driftlock"));
    y = dbg_line(x, y, "Smoother",
                 smooth_on ? "ON" : "OFF",
                 smooth_on ? DBG_GOOD_COL : DBG_WARN_COL);

    // --- Wants motion (live input) ---
    y = dbg_line(x, y, "Input",
                 smooth_local_dbg_wants_motion ? "MOVING" : "released",
                 smooth_local_dbg_wants_motion ? DBG_VALUE_COL : DBG_LABEL_COL);

    // --- Lock state ---
    string lock_str;
    vector lock_col;
    if (!smooth_on)
    {
        lock_str = "disabled";
        lock_col = DBG_LABEL_COL;
    }
    else if (smooth_local_dbg_lock_active)
    {
        lock_str = "ACTIVE";
        lock_col = DBG_GOOD_COL;
    }
    else
    {
        lock_str = "off";
        lock_col = DBG_LABEL_COL;
    }
    y = dbg_line(x, y, "Lock", lock_str, lock_col);

    // --- Drift (elen): |live - server| ---
    // Below 0.05 = noise floor; up to ~2 = decel-tail noise; up to ~10
    // = active-motion lag or short lock; > 10 = lock has accumulated
    // significant drift; near 32 = approaching snap threshold.
    vector elen_col;
    if (smooth_local_dbg_elen < 1)       elen_col = DBG_GOOD_COL;
    else if (smooth_local_dbg_elen < 8)  elen_col = DBG_VALUE_COL;
    else if (smooth_local_dbg_elen < 24) elen_col = DBG_WARN_COL;
    else                                 elen_col = DBG_BAD_COL;
    y = dbg_line(x, y, "Drift",
                 sprintf("%.2f qu", smooth_local_dbg_elen), elen_col);

    // --- Per-snapshot server motion (dpost) ---
    vector dpost_col;
    if (smooth_local_dbg_dpost < 0.5)    dpost_col = DBG_GOOD_COL;
    else if (smooth_local_dbg_dpost < 4) dpost_col = DBG_VALUE_COL;
    else                                 dpost_col = DBG_WARN_COL;
    y = dbg_line(x, y, "Server step",
                 sprintf("%.2f qu", smooth_local_dbg_dpost), dpost_col);

    // --- In-flight smoother offset ---
    float ofs_mag = 0;
    float ofs_age_ms = 0;
    float fade_ms    = 0;
    if (predicted_player && predicted_player.extrap_error_cltime > 0)
    {
        ofs_mag = vlen(predicted_player.extrap_error_offset);
        ofs_age_ms = (cltime - predicted_player.extrap_error_cltime) * 1000;
        // Mirror the smooth_time choice in CSQC_ApplyLocalSmoothOffset.
        float smooth_time;
        if (ofs_mag >= 1.0)
            smooth_time = 0.2;
        else
        {
            smooth_time = cvar("cl_extrap_smooth_time");
            if (smooth_time <= 0) smooth_time = 0.1;
        }
        fade_ms = smooth_time * 1000;
    }
    if (ofs_mag > 0.001)
    {
        y = dbg_line(x, y, "Smooth offset",
                     sprintf("%.2f qu", ofs_mag), DBG_VALUE_COL);
        y = dbg_line(x, y, "Fade",
                     sprintf("%.0f / %.0f ms", ofs_age_ms, fade_ms),
                     DBG_VALUE_COL);
    }
    else
    {
        y = dbg_line(x, y, "Smooth offset", "(idle)", DBG_LABEL_COL);
    }

    // --- Snap threshold ---
    y = dbg_line(x, y, "Snap @", "32 qu (teleport)", DBG_LABEL_COL);

    // --- Time since last reconcile (sanity: should be tens of ms) ---
    float since_ms = 0;
    if (smooth_local_dbg_last_reconcile > 0)
        since_ms = (cltime - smooth_local_dbg_last_reconcile) * 1000;
    y = dbg_line(x, y, "Last reconcile",
                 sprintf("%.0f ms ago", since_ms), DBG_LABEL_COL);

    // --- Time since last teleport-snap branch fired ---
    // Recent (< 500 ms) is amber so the user notices a fresh snap;
    // anything older fades back to the label colour.  "(none)" until
    // the first snap of the session.
    if (smooth_local_dbg_last_snap > 0)
    {
        float snap_ago_ms = (cltime - smooth_local_dbg_last_snap) * 1000;
        vector snap_col = (snap_ago_ms < 500) ? DBG_WARN_COL : DBG_LABEL_COL;
        y = dbg_line(x, y, "Last snap",
                     sprintf("%.0f ms ago", snap_ago_ms), snap_col);
    }
    else
    {
        y = dbg_line(x, y, "Last snap", "(none)", DBG_LABEL_COL);
    }

    return y + 6;
};

// ============================================================
//  cl_debug_surface — surface material under the crosshair + underfoot
// ============================================================

float(float x, float y) CSQC_DrawDebugSurface =
{
    y = dbg_text(x, y, "--- SURFACE ---", '0.3 1 0.6');

    // What the crosshair points at.
    vector vorg = getproperty(VF_ORIGIN);
    makevectors(getproperty(VF_CL_VIEWANGLES));
    traceline(vorg, vorg + v_forward * 8192, MOVE_NOMONSTERS, predicted_player);
    string look_tex = Surf_TexAtPoint(trace_ent, trace_endpos);   // Q1: resolve from the hit point
    float  look_mat = Surf_MaterialFor(look_tex);

    // What the player is standing on.
    string gnd_tex = "";
    float  gnd_mat = -1;
    if (predicted_player)
    {
        vector po = predicted_player.origin;
        traceline(po, po - '0 0 128', MOVE_NOMONSTERS, predicted_player);
        gnd_tex = Surf_TexAtPoint(trace_ent, trace_endpos);
        gnd_mat = Surf_MaterialFor(gnd_tex);
    }

    y = dbg_line(x, y, "Look tex",   (look_tex == "") ? "(none)" : look_tex, DBG_VALUE_COL);
    y = dbg_line(x, y, "Look mat",   sprintf("%s  (impact %g, footstep %s)", Surf_MatName(look_mat),
                    Surf_ImpactMat(look_mat), (Surf_FootstepName(look_mat) == "") ? "generic" : Surf_FootstepName(look_mat)), DBG_GOOD_COL);
    y = dbg_line(x, y, "Ground tex", (gnd_tex == "") ? "(none)" : gnd_tex, DBG_VALUE_COL);
    y = dbg_line(x, y, "Ground mat", sprintf("%s  (impact %g, footstep %s)", Surf_MatName(gnd_mat),
                    Surf_ImpactMat(gnd_mat), (Surf_FootstepName(gnd_mat) == "") ? "generic" : Surf_FootstepName(gnd_mat)), DBG_GOOD_COL);

    // The ACTUAL footstep set PM_UpdateStepSound plays — computed the SAME way it is (down-trace to
    // the floor surface, then the metal phys-prop override).  This line == what you hear, so if it
    // ever reads "metal" on a concrete/wood floor the Ground tex above names the offending surface.
    string foot = "n/a";
    if (predicted_player)
    {
        vector fg = predicted_player.gravshift_active ? predicted_player.gravitydir : '0 0 -1';
        traceline(predicted_player.origin, predicted_player.origin + fg * 8192, MOVE_NOMONSTERS, predicted_player);
        string ffset = Surf_FootstepName(Surf_MaterialAtPoint(trace_ent, trace_endpos));
        entity ge = predicted_player.pm_ground_ent;
        if (ge.classname == "phys_files" || ge.classname == "phys_barrel" || ge.classname == "phys_can")
            foot = "metal (phys prop)";
        else
            foot = strcat((ffset == "") ? "generic" : ffset, " (surface)");
    }
    y = dbg_line(x, y, "Foot set", foot, DBG_GOOD_COL);

    return y + 6;
};

// ============================================================
//  cl_debug_prop — physics prop under the crosshair (material/mass/physics tuning)
// ============================================================

// Find the CSQC phys-prop mirror the LOCAL player is carrying (gravgun grab / +use), or world.
// pp_carrier is the carrier edict, non-zero ONLY while held (GRABBING/STEADY); == our entnum = ours.
// (No client pointer to the held prop exists - carried_prop is server-only - so scan the mirrors.)
entity() CSQC_LocalCarriedProp =
{
    if (player_localentnum <= 0)
        return world;
    entity e = findchain(classname, "phys_files");
    while (e)
    {
        if (e.modelindex && e.pp_carrier == player_localentnum)
            return e;
        e = e.chain;
    }
    return world;
};

// Robust "prop under the crosshair" pick.  A plain CSQC traceline only sees the world, brush func_
// ents, and SOLID prop mirrors (free-settled phys_files + always-solid prop_predicted) - it MISSES a
// carried/just-thrown prop (SOLID_NOT) and dropped weapons.  So traceline first (for occlusion +
// solid hits), then oriented-box ray-test the real CSQC prop edicts a traceline can't see, keeping
// the closest hit that isn't behind whatever the traceline stopped at.  Same idea as the bullet path
// CSQC_PhysProp_OverrideTrace, but returns the REAL mirror (modelindex/velocity/pp_* fields) not the
// data-less fake trace-target.  `aim` MUST be a unit vector captured by the caller BEFORE this runs
// (the per-entity makevectors(e.angles) below clobbers v_forward/right/up).
entity(vector src, vector aim, float dirlen) Prop_FindForDebug =
{
    traceline(src, src + aim * dirlen, MOVE_NOMONSTERS, predicted_player);
    float  best_t   = (trace_fraction >= 1.0) ? dirlen : (trace_fraction * dirlen);
    entity best_ent = world;
    if (trace_ent != world && trace_ent != __NULL__)
    if (trace_ent.classname == "phys_files" || trace_ent.classname == "prop_predicted")
        best_ent = trace_ent;   // a solid mirror already under the crosshair

    float pass;
    for (pass = 0; pass < 3; pass = pass + 1)
    {
        string cls;
        if      (pass == 0) cls = "phys_files";
        else if (pass == 1) cls = "prop_predicted";
        else                cls = "csqc_dropped_weapon";

        entity e = findchain(classname, cls);
        while (e)
        {
            // Skip the invisible fake trace-target (pp_fake_files: classname "phys_files", no model
            // -> modelindex 0).  Real mirrors always setmodelindex, so modelindex 0 == not a prop.
            if (e.modelindex == 0) { e = e.chain; continue; }
            makevectors(e.angles);   // raw-angle OBB axes: v_forward, -v_right, v_up (World_OBBTrace basis)
            float t = CSQC_PhysProp_RayBox(src, aim, dirlen, e.origin,
                                           v_forward, v_right * -1, v_up, e.mins, e.maxs);
            if (t >= 0 && t < best_t)   // closer than the traceline stop => not occluded
            {
                best_t   = t;
                best_ent = e;
            }
            e = e.chain;
        }
    }
    return best_ent;
};

float(float x, float y) CSQC_DrawDebugProp =
{
    y = dbg_text(x, y, "--- PROP ---", '0.3 1 0.6');

    vector vorg = getproperty(VF_ORIGIN);
    makevectors(getproperty(VF_CL_VIEWANGLES));
    vector aim = v_forward;   // capture BEFORE Prop_FindForDebug's per-entity makevectors clobbers it

    // (1) A prop held by the local player is SOLID_NOT in-hand, so the crosshair ray can't hit it.
    entity held = CSQC_LocalCarriedProp();
    if (held != world)
    {
        string hmn = held.model;
        if (hmn == "" && held.modelindex) hmn = modelnameforindex(held.modelindex);
        y = dbg_line(x, y, "Carrying", (hmn == "") ? held.classname : hmn, DBG_GOOD_COL);
    }

    // (2) Robust pick under the crosshair: traceline (occlusion + solid hits) then OBB-test the
    //     SOLID_NOT prop mirrors a traceline misses.  Returns the real mirror, or world if none.
    entity pe = Prop_FindForDebug(vorg, aim, 8192);

    // No prop found (a wall or empty space leaves best_ent = world).
    if (pe == world || pe == __NULL__)
    {
        y = dbg_line(x, y, "Target", "(no prop under crosshair)", DBG_WARN_COL);
        return y + 6;
    }
    string mn = pe.model;
    if (mn == "" && pe.modelindex)
        mn = modelnameforindex(pe.modelindex);   // CSQC props use setmodelindex (empty .model)
    if (mn == "")
    {
        y = dbg_line(x, y, "Target", sprintf("%s (no model)", pe.classname), DBG_WARN_COL);
        return y + 6;
    }

    // Recompute material + derived weight locally — accurate for every derived-mass prop (the 584
    // auto-assigned models + barrel/can/cabinet).  A per-map explicit `mass` FGD key is NOT networked,
    // hence the "mat" tag: this is the material-derived mass, which the server also uses unless overridden.
    float mi = PropMat_For(mn);
    y = dbg_line(x, y, "Model",     mn, DBG_VALUE_COL);
    y = dbg_line(x, y, "Material",  PropMat_Name(mi), DBG_GOOD_COL);
    y = dbg_line(x, y, "Mass(mat)", sprintf("%.1f", PropMat_Mass(mi, pe)), DBG_VALUE_COL);
    y = dbg_line(x, y, "Fric/Rest", sprintf("%.2f / %.2f", PropMat_Friction(mi), PropMat_Restit(mi)), DBG_VALUE_COL);
    y = dbg_line(x, y, "Damp x",    sprintf("%.2f", PropMat_DampMult(mi)), DBG_VALUE_COL);

    // Live state off the CSQC mirror (CSQC_PhysProp_Update).  Statics read 0 / n/a, which is honest.
    string geom = "n/a";
    if (pe.solid == SOLID_PHYSICS_TRIMESH)   geom = "trimesh (hull)";
    else if (pe.solid == SOLID_PHYSICS_BOX)  geom = "box";
    float live = (pe.classname == "phys_files");
    y = dbg_line(x, y, "Type",    live ? "phys prop (live)" : pe.classname, live ? DBG_GOOD_COL : DBG_LABEL_COL);
    y = dbg_line(x, y, "Speed",   sprintf("%.0f  (ang %.0f)", vlen(pe.velocity), vlen(pe.avelocity)), DBG_VALUE_COL);
    y = dbg_line(x, y, "Geom",    geom, DBG_VALUE_COL);
    y = dbg_line(x, y, "Scale",   sprintf("%.2f", (pe.scale > 0) ? pe.scale : 1), DBG_VALUE_COL);
    y = dbg_line(x, y, "Carried", pe.pp_carrier ? "yes" : "no", pe.pp_carrier ? DBG_WARN_COL : DBG_VALUE_COL);

    // Push knobs, so the readout self-documents the "too much push" problem (server cvars).
    y = dbg_line(x, y, "hit_force",  sprintf("%g", cvar("sv_physprop_hit_force")), DBG_LABEL_COL);
    y = dbg_line(x, y, "use/expl",   sprintf("%g / %g", cvar("sv_physprop_use_force"), cvar("sv_physprop_explosion_force")), DBG_LABEL_COL);
    y = dbg_line(x, y, "mass_scale", sprintf("%g", cvar("sv_propmat_mass_scale")), DBG_LABEL_COL);
    y = dbg_line(x, y, "ode_iters",  sprintf("%g", cvar("physics_ode_iterationsperframe")), DBG_LABEL_COL);

    return y + 6;
};

// ============================================================
//  Master debug panel draw — called from CSQC_UpdateView
// ============================================================

float(float x, float y) Car_DrawForcePanel;   // defined in cl_prop_vehicle.qc (later); self-gates on the car stream

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
    if (cvar("cl_debug_surface"))
        y = CSQC_DrawDebugSurface(x, y);
    if (cvar("cl_debug_prop"))
        y = CSQC_DrawDebugProp(x, y);
    if (cvar("cl_debug_smoothing"))
        y = CSQC_DrawDebugSmoothing(x, y);
    if (cvar("cl_debug_playermodel"))
        y = CSQC_DrawDebugPlayerModel(x, y);
    if (cvar("cl_debug_drift"))
        y = CSQC_DrawDebugDrift(x, y);
    y = Car_DrawForcePanel(x, y);   // draws only while a fresh car-debug stream exists (sv_debug_car 1)

    drawfont = prev_font;
};

