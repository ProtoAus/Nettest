// ============================================================
//  client/cl_voip_hud.qc  -  VoIP icons + mute UI
//
//  Five surfaces drive speaker state, all keyed off
//  INFOKEY_P_VOIPSPEAKING per slot:
//
//    1. Local "talking" icon at bottom-left (above health, just
//       off the left edge).  talking.png while transmitting,
//       talking_off.png with a 2 s fade after release.
//    2. Per-speaker overlay stacked above the local icon — one
//       row per remote player currently in the (hold+fade)
//       window.  Icon prefix + name.
//    3. In-world floating icon above each speaking remote
//       player's head, billboarded to camera but kept vertical.
//    4. Scoreboard row icon (drawn from m_scoreboard.qc — this
//       file exposes IsSpeakingNow / IsMuted helpers).
//    5. Click-to-mute mode: while +showscores held + +attack2
//       toggled, the mouse cursor is enabled so the user can
//       click scoreboard rows.  Mute calls the engine's
//       cl_voip_mute console command and mirrors a local flag.
//
//  Per-slot state lives in voip_*_speak_time / hud_voipmute
//  parallel arrays keyed by 0-based slot index.  Slot 0 is the
//  local player — tracked here too so the local talking icon
//  uses the same fade math as remotes.
// ============================================================

const float VOIP_HUD_MAX_PLAYERS  = 32;
const float VOIP_HUD_HOLD_TIME    = 0.3;     // hold full alpha after last speech sample
const float VOIP_HUD_LINE_SIZE    = 12;      // text glyph height in the speaker list
const float VOIP_HUD_LINE_GAP     = 2;       // px between stacked rows
const float VOIP_HUD_ICON_SIZE    = 16;      // small inline icon for the speaker list
const float VOIP_HUD_LOCAL_SIZE   = 32;      // local talking indicator — doubled from 16 to take
                                              // advantage of the higher-res talking.png the user
                                              // upgraded.  Grows upward + rightward from the prior
                                              // bottom-left anchor, so the icon's BOTTOM edge stays
                                              // at the same screen-y as before.
const float VOIP_HUD_LOCAL_X      = 10;      // 10 px IN from the left edge.
const float VOIP_HUD_LOCAL_Y_GAP  = 108;     // distance from bottom of screen to icon-top.
                                              // 108 = 92 (previous gap when icon was 16 tall)
                                              // + 16 (size delta to keep bottom edge fixed).
                                              // Health sits at g_height-52; this puts the icon
                                              // top at g_height-108 and bottom at g_height-76,
                                              // clear of the 36u-tall health digits.

// PNG paths — gfx/mic/*.png.  Mirrors what the menu / scoreboard
// reference, so renaming flows through one place.
const string VOIP_PIC_TALKING      = "gfx/mic/talking.png";
const string VOIP_PIC_TALKING_OFF  = "gfx/mic/talking_off.png";
const string VOIP_PIC_SPEAKING     = "gfx/mic/speaking.png";
const string VOIP_PIC_SPEAKING_OFF = "gfx/mic/speaking_off.png";
const string VOIP_PIC_MUTED        = "gfx/mic/muted.png";
// Higher-res 3D-billboard icon — used ONLY for the in-world
// overhead floater (HUD / scoreboard keep the smaller PNGs above).
// The world icon sits in 3D space and is sampled at varying screen
// sizes depending on distance, so a higher-res source PNG gives
// cleaner mipmaps + better minification when remote players are
// far away.
const string VOIP_PIC_OVERHEAD       = "gfx/mic/overhead.png";
// Muted-overhead variant — drawn above muted players ALWAYS while
// they're in our scene (visible via a player_visual_proxy entity).
// Engine never delivers voice packets for muted slots, so we can't
// detect "they're trying to speak" — we just persistently advertise
// the muted state instead.
const string VOIP_PIC_OVERHEAD_MUTED = "gfx/mic/overhead_muted.png";

// Per-slot timestamps.  voip_last_speak_time == 0 means "never
// spoken in this session".  voip_first_speak_time anchors the
// sort order — refreshed only when the slot enters the list
// fresh (after a full hold+fade window of silence) so that
// brief mid-speech pauses don't reshuffle entries.
float voip_last_speak_time [VOIP_HUD_MAX_PLAYERS];
float voip_first_speak_time[VOIP_HUD_MAX_PLAYERS];
// Throttle stamp for HUD_VoIP_Tick's per-slot voipspeaking scan (the 32
// getplayerkeyvalue() lookups were running every render frame).
float voip_tick_next;
// Most recent moment ANY slot was stamped speaking (== max of
// voip_last_speak_time[], since both are set to the same cltime in
// HUD_VoIP_Tick).  Lets DrawSpeakerList / DrawWorldOverheads early-out their
// full scans when nobody has spoken within the (hold+fade) window — the common
// solo/idle case (DrawSpeakerList ran a 32-slot scan, DrawWorldOverheads a
// makevectors basis + findchain walk, every frame with no talkers).
float voip_last_any_speak;

// Authoritative local mute state.  Set / cleared via
// HUD_VoIP_ToggleMute; mirrored to the engine via the
// `cl_voip_mute` console command.  Synced lazily from the
// engine-side INFOKEY_P_VOIP_MUTED on first tick so reconnects
// inherit whatever the engine remembers.
float hud_voipmute        [VOIP_HUD_MAX_PLAYERS];
float hud_voipmute_synced;    // FALSE until first sync; sync happens once per session
float hud_voipmute_mode;      // TRUE while in scoreboard click-to-mute mode

// Cursor state — separate flag from team_menu_cursor_active so
// the two systems don't fight over setcursormode.  EnterMuteMode
// guards against double-setcursormode if it's already on (e.g.
// team menu open).
float hud_voipmute_cursor_active;

// ---------- Init ----------

void() HUD_VoIP_PrecachePics =
{
    precache_pic(VOIP_PIC_TALKING);
    precache_pic(VOIP_PIC_TALKING_OFF);
    precache_pic(VOIP_PIC_SPEAKING);
    precache_pic(VOIP_PIC_SPEAKING_OFF);
    precache_pic(VOIP_PIC_MUTED);
    precache_pic(VOIP_PIC_OVERHEAD);
    precache_pic(VOIP_PIC_OVERHEAD_MUTED);
};

// ---------- Helpers (called from m_scoreboard.qc + here) ----------

// "Is this slot's voipspeaking flag currently 1?"  Live query —
// doesn't depend on the fade window.
float(float slot) HUD_VoIP_IsSpeakingNow =
{
    if (slot < 0 || slot >= VOIP_HUD_MAX_PLAYERS) return 0;
    return stof(getplayerkeyvalue(slot, INFOKEY_P_VOIPSPEAKING));
};

float(float slot) HUD_VoIP_IsMuted =
{
    if (slot < 0 || slot >= VOIP_HUD_MAX_PLAYERS) return 0;
    return hud_voipmute[slot];
};

// Pick the right icon path for a slot at this instant.  Used by
// the scoreboard row + the speaker overlay + the world overhead.
string(float slot) HUD_VoIP_PickIcon =
{
    if (HUD_VoIP_IsMuted(slot))
        return VOIP_PIC_MUTED;
    if (HUD_VoIP_IsSpeakingNow(slot))
        return VOIP_PIC_SPEAKING;
    return VOIP_PIC_SPEAKING_OFF;
};

// Toggle local mute for a slot.  Refuses to mute the LOCAL player
// (player_localnum) — silencing yourself is meaningless — but
// every other slot including slot 0 is mutable.
//
// FTE's mute system has TWO separate commands:
//   cl_voip_mute   <userid|name>  — ADDS to mute list (not a toggle).
//                                   Says "User X is already mute" if
//                                   the slot is already muted.
//   cl_voip_unmute <userid|name>  — REMOVES from mute list.
// We track the desired state in `hud_voipmute[]` and dispatch the
// right command based on the new state.  Without dispatching the
// unmute command, the engine never removes the entry — clicking
// the muted player twice would just add them again and print
// "already mute".
//
// CSQC reads the engine's per-player userid via the "userid"
// infokey (no `*` prefix; that's the SSQC form).  See
// engine/client/pr_csqc.c:4372 — returns cl.players[slot].userid as
// a decimal string.  We send it as the cl_voip_mute / unmute arg.
// Falls back to the player's name (quoted) if userid is empty.
void(float slot) HUD_VoIP_ToggleMute =
{
    if (slot < 0 || slot >= VOIP_HUD_MAX_PLAYERS) return;
    if (slot == player_localnum) return;

    hud_voipmute[slot] = !hud_voipmute[slot];
    string verb = hud_voipmute[slot] ? "cl_voip_mute" : "cl_voip_unmute";

    string userid = getplayerkeyvalue(slot, "userid");
    if (userid != "" && stof(userid) > 0)
    {
        localcmd(sprintf("%s %s\n", verb, userid));
        return;
    }

    // Fallback — name with quoting in case it has spaces.
    string nm = getplayerkeyvalue(slot, "name");
    if (nm == "") return;
    localcmd(sprintf("%s \"%s\"\n", verb, nm));
};

// Click-to-mute mode entry / exit — enables the mouse cursor and
// flips the gate that scoreboard rows + cl_main.qc input routing
// read.  Safe to call multiple times; setcursormode is no-op if
// state already matches.
void() HUD_VoIP_EnterMuteMode =
{
    if (hud_voipmute_mode) return;
    hud_voipmute_mode = TRUE;
    if (!hud_voipmute_cursor_active)
    {
        setcursormode(TRUE, "gfx/xhair", [16, 16], cvar("vid_conautoscale"));
        hud_voipmute_cursor_active = TRUE;
    }
};

void() HUD_VoIP_ExitMuteMode =
{
    if (!hud_voipmute_mode) return;
    hud_voipmute_mode = FALSE;
    if (hud_voipmute_cursor_active)
    {
        setcursormode(FALSE);
        hud_voipmute_cursor_active = FALSE;
    }
};

// ---------- Per-frame tick ----------

// One-shot sync from engine's `vignored` infokey — so reconnecting
// to a session where you'd already muted players carries the
// state across.  Run on first tick.
void() HUD_VoIP_SyncMuteFromEngine =
{
    if (hud_voipmute_synced) return;
    float i;
    for (i = 0; i < VOIP_HUD_MAX_PLAYERS; i = i + 1)
        hud_voipmute[i] = stof(getplayerkeyvalue(i, INFOKEY_P_VOIP_MUTED));
    hud_voipmute_synced = TRUE;
};

// Poll every player slot's voipspeaking infokey and update the
// per-slot timestamps.  Local player (slot == player_localnum) is
// tracked too so the local talking icon shares the same fade math.
void() HUD_VoIP_Tick =
{
    HUD_VoIP_SyncMuteFromEngine();
    if (!cvar("hud_voip_show")) return;

    // Throttle the per-slot voipspeaking scan — 32 getplayerkeyvalue() info-key
    // lookups every render frame (250+ Hz) was the cost.  A "who's talking" overlay
    // at ~cl_hud_fps (30 Hz default) is imperceptible, and the fade/hold logic is
    // cltime-delta based so a coarser sample is fine.
    if (cltime < voip_tick_next)
        return;
    float hz = cvar("cl_hud_fps");
    if (hz <= 0) hz = 30;
    voip_tick_next = cltime + 1.0 / hz;

    float fade_dur = cvar("cl_voip_fadeduration");
    if (fade_dur <= 0) fade_dur = 2.0;

    // Only scan real player slots — slots past maxclients are never connected, so
    // getplayerkeyvalue() there is wasted (16 vs 32 with this server's maxclients).
    float maxp = serverkeyfloat("maxclients");
    if (maxp <= 0 || maxp > VOIP_HUD_MAX_PLAYERS) maxp = VOIP_HUD_MAX_PLAYERS;

    float i;
    for (i = 0; i < maxp; i = i + 1)
    {
        float speaking = stof(getplayerkeyvalue(i, INFOKEY_P_VOIPSPEAKING));
        if (speaking)
        {
            // Fresh entry — anchor sort order.  Refresh on long
            // silence so a player who stopped and resumed gets a
            // new spot at the bottom of the overlay list.
            float since_last = cltime - voip_last_speak_time[i];
            if (voip_last_speak_time[i] == 0
                || since_last > VOIP_HUD_HOLD_TIME + fade_dur)
                voip_first_speak_time[i] = cltime;
            voip_last_speak_time[i] = cltime;
            voip_last_any_speak     = cltime;   // drives the draw-side early-outs
        }
    }
};

// Compute the current alpha for a slot's icon based on the
// (hold + fade) window.  Returns 0..1.  0 means "fully faded —
// don't render".  Speaking-now → 1.  Within hold window → 1.
// Inside the fade ramp → linear fall.
float(float slot, float fade_dur) HUD_VoIP_AlphaForSlot =
{
    if (HUD_VoIP_IsSpeakingNow(slot)) return 1.0;
    if (voip_last_speak_time[slot] == 0) return 0.0;
    float age = cltime - voip_last_speak_time[slot];
    if (age <= VOIP_HUD_HOLD_TIME) return 1.0;
    if (age >= VOIP_HUD_HOLD_TIME + fade_dur) return 0.0;
    return 1.0 - (age - VOIP_HUD_HOLD_TIME) / fade_dur;
};

// ---------- HUD draws ----------

// Local "talking" icon — bottom-left, just above health.
// Active = talking.png at full alpha.  Recently stopped =
// talking_off.png fading over 2 s.  Idle = nothing drawn.
void() HUD_VoIP_DrawLocalIcon =
{
    if (!cvar("hud_voip_show")) return;

    float fade_dur = cvar("cl_voip_fadeduration");
    if (fade_dur <= 0) fade_dur = 2.0;

    float speaking_now = HUD_VoIP_IsSpeakingNow(player_localnum);
    float alpha = HUD_VoIP_AlphaForSlot(player_localnum, fade_dur);
    if (alpha <= 0) return;

    string icon = speaking_now ? VOIP_PIC_TALKING : VOIP_PIC_TALKING_OFF;
    vector sz = [VOIP_HUD_LOCAL_SIZE, VOIP_HUD_LOCAL_SIZE, 0];
    vector pos = [VOIP_HUD_LOCAL_X, g_height - VOIP_HUD_LOCAL_Y_GAP, 0];
    drawpic(pos, icon, sz, '1 1 1', alpha, 0);
};

// Speaker overlay — list of currently-speaking remote players,
// stacked upward above the local icon.  Newest entry sits
// closest to the local icon; oldest pushed highest.  Each row
// has an icon prefix (speaking / speaking_off / muted) and
// the player's name.
void() HUD_VoIP_DrawSpeakerList =
{
    if (!cvar("hud_voip_show")) return;

    float fade_dur = cvar("cl_voip_fadeduration");
    if (fade_dur <= 0) fade_dur = 2.0;

    // Nobody stamped speaking within the (hold+fade) window → every slot is aged
    // out, so candidate_count would be 0.  Skip the 32-slot scan + sort.
    if (cltime - voip_last_any_speak > VOIP_HUD_HOLD_TIME + fade_dur)
        return;

    float prev_font = drawfont;
    drawfont = hud_font_mono;

    vector text_sz = [VOIP_HUD_LINE_SIZE, VOIP_HUD_LINE_SIZE, 0];
    vector icon_sz = [VOIP_HUD_ICON_SIZE, VOIP_HUD_ICON_SIZE, 0];
    float row_h = max(VOIP_HUD_LINE_SIZE, VOIP_HUD_ICON_SIZE) + VOIP_HUD_LINE_GAP;
    // Stack starts immediately above the local talking icon's
    // top edge.  Local icon top = g_height - VOIP_HUD_LOCAL_Y_GAP,
    // so first stacked row's TOP sits at -row_h above that.
    float baseline_y = g_height - VOIP_HUD_LOCAL_Y_GAP - row_h;
    // Speaker icons share the same left-edge column as the local
    // talking icon (also 10 px off-screen).  Names start just past
    // the icon so they land at ~x=10 — fully on-screen.
    float x_icon = VOIP_HUD_LOCAL_X;
    float x_text = x_icon + VOIP_HUD_ICON_SIZE + 4;

    // --- Candidate list: slots inside the (hold + fade) window ---
    // Muted players don't get a persistent entry; they only appear
    // here when voipspeaking transitions to 1 (same path as normal
    // speakers).  In practice the engine blocks voice packets for
    // muted slots at the server (sv_user.c:3142), so voipspeaking
    // stays 0 and muted players don't surface in this overlay.
    // The scoreboard row icon is the persistent muted-state
    // indicator.
    float candidates[VOIP_HUD_MAX_PLAYERS];
    float candidate_count = 0;

    float i;
    for (i = 0; i < VOIP_HUD_MAX_PLAYERS; i = i + 1)
    {
        if (i == player_localnum) continue;   // local presence is the talking icon
        if (voip_last_speak_time[i] == 0) continue;
        float age = cltime - voip_last_speak_time[i];
        if (age > VOIP_HUD_HOLD_TIME + fade_dur)
        {
            voip_last_speak_time[i]  = 0;
            voip_first_speak_time[i] = 0;
            continue;
        }
        candidates[candidate_count] = i;
        candidate_count = candidate_count + 1;
    }

    if (candidate_count == 0)
    {
        drawfont = prev_font;
        return;
    }

    // --- Sort: newest first_speak_time first (drawn lowest) ---
    float a, b;
    for (a = 0; a < candidate_count - 1; a = a + 1)
    {
        float best_idx = a;
        for (b = a + 1; b < candidate_count; b = b + 1)
        {
            if (voip_first_speak_time[candidates[b]]
                > voip_first_speak_time[candidates[best_idx]])
                best_idx = b;
        }
        if (best_idx != a)
        {
            float tmp = candidates[a];
            candidates[a] = candidates[best_idx];
            candidates[best_idx] = tmp;
        }
    }

    // --- Render stacked upward ---
    float k;
    for (k = 0; k < candidate_count; k = k + 1)
    {
        float slot = candidates[k];
        float alpha = HUD_VoIP_AlphaForSlot(slot, fade_dur);
        if (alpha <= 0) continue;

        // Icon swap is the only thing the mute state changes in
        // this overlay — muted speakers show muted.png while their
        // speech is in the hold+fade window, same fade timing as
        // unmuted.  (In practice this branch only fires if mute is
        // toggled after the speaker started transmitting — once
        // they're fully muted, voipspeaking stops firing.)
        string icon = HUD_VoIP_PickIcon(slot);
        string name = getplayerkeyvalue(slot, "name");
        if (name == "") name = "?";

        // Icon (left), drop-shadow + white name (right).
        drawpic([x_icon, baseline_y, 0], icon, icon_sz, '1 1 1', alpha, 0);
        float text_y = baseline_y + (VOIP_HUD_ICON_SIZE - VOIP_HUD_LINE_SIZE) * 0.5;
        drawstring([x_text,     text_y],     name, text_sz, '1 1 1', alpha, 0);
        baseline_y = baseline_y - row_h;
    }

    drawfont = prev_font;
};

// Combined HUD draw — local icon + speaker list, called from
// CSQC_UpdateView after the rest of the HUD elements.
void() HUD_VoIP_Draw =
{
    HUD_VoIP_DrawLocalIcon();
    HUD_VoIP_DrawSpeakerList();
};

// ---------- In-world overhead icons ----------

// Iterate every visible player_visual_proxy and emit a billboard
// quad above the head of any slot that's currently inside the
// hold+fade window.  Called from CSQC_UpdateView BEFORE
// renderscene so the polygons participate in the scene.
//
// Billboard convention: camera-yaw-facing but world-upright —
// the icon stays vertical as the camera tilts (sprays its T-axis
// to world +Z, S-axis to a horizontal vector perpendicular to
// the camera's forward).  Matches how floating nametags read in
// most engines.
void() HUD_VoIP_DrawWorldOverheads =
{
    if (!cvar("hud_voip_show")) return;
    if (!cvar("cl_voip_overhead")) return;

    // No speech within the (hold+fade) window → nobody can be IsSpeakingNow, and
    // nothing draws here unless speaking.  Skip the billboard basis + findchain.
    float fade_dur = cvar("cl_voip_fadeduration");
    if (fade_dur <= 0) fade_dur = 2.0;
    if (cltime - voip_last_any_speak > VOIP_HUD_HOLD_TIME + fade_dur)
        return;

    float half = cvar("cl_voip_overhead_size");
    if (half <= 0) half = 12;
    float z_ofs = cvar("cl_voip_overhead_offset");
    if (z_ofs <= 0) z_ofs = 48;

    // Build the upright-billboard basis once for all icons.  The
    // camera angles come from VF_ANGLES (already populated by the
    // engine before CSQC_UpdateView runs).
    //
    // Right-vector convention: `cross(fwd_h, world_up)` matches
    // Quake's v_right (cross(forward, world_up) = -y for yaw=0).
    // The earlier version did `cross(world_up, fwd_h)` which gave
    // a vector pointing to the VIEWER's LEFT — that made the icon
    // appear horizontally mirrored because the UV S-axis ended up
    // running right-to-left in view space.
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector fwd_h = v_forward;
    fwd_h_z = 0;
    if (vlen(fwd_h) < 0.001)
        return;   // looking straight up/down — degenerate, skip frame
    fwd_h = normalize(fwd_h);
    vector right_h = crossproduct(fwd_h, '0 0 1');
    right_h = normalize(right_h);
    vector right_v = right_h * half;
    vector up_v    = '0 0 1' * half;

    entity proxy;
    for (proxy = findchain(classname, "player_visual_proxy");
         proxy;
         proxy = proxy.chain)
    {
        float slot = proxy.vis_owner_entnum - 1;
        if (slot < 0 || slot >= VOIP_HUD_MAX_PLAYERS) continue;
        if (slot == player_localnum) continue;   // skip self — first-person view

        // Binary on/off — only draw while voipspeaking==1.  Muted
        // players will (in practice) never trigger this branch
        // because cl_voip_mute → vignore tells the server to stop
        // forwarding their voice packets, so our local
        // s_voip.lastspoke[] never advances and voipspeaking stays
        // 0 forever.  That's a hard engine constraint
        // (engine/server/sv_user.c:3142 filters before send) — the
        // muted overhead can only swap-in on actual speech, which
        // we no longer receive.  The scoreboard row icon remains
        // the persistent muted-state indicator instead.
        if (!HUD_VoIP_IsSpeakingNow(slot))
            continue;

        string icon = HUD_VoIP_IsMuted(slot) ? VOIP_PIC_OVERHEAD_MUTED
                                             : VOIP_PIC_OVERHEAD;

        // If the look-at name tag is currently rendering this same
        // player's name above their head, shift the VOIP icon up so
        // the text fits cleanly below it.  Slot match is exact; the
        // name tag clears its slot to -1 when no player is hit, so
        // no false positives.  Mirrors the +BUMP applied in
        // cl_lookatname.qc::CSQC_LookatName_DrawWorld.
        float row_z = z_ofs;
        if (slot == lookat_target_slot)
            row_z = row_z + LOOKAT_VOIP_OFFSET_BUMP;

        vector pos = proxy.origin + '0 0 1' * row_z;

        R_BeginPolygon(icon, 0, 0);
        R_PolygonVertex(pos - right_v - up_v, '0 1 0', '1 1 1', 1.0);
        R_PolygonVertex(pos + right_v - up_v, '1 1 0', '1 1 1', 1.0);
        R_PolygonVertex(pos + right_v + up_v, '1 0 0', '1 1 1', 1.0);
        R_PolygonVertex(pos - right_v + up_v, '0 0 0', '1 1 1', 1.0);
        R_EndPolygon();
    }
};
