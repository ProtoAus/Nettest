float hud_scoreboard_held;
float hud_scoreboard_teamselect;   // TRUE when drawing as team select screen

// Set by CSQC_WorldLoaded to (cltime + grace) on every map load.  While
// cltime < this timestamp, Scoreboard_PlayerName returns "" for every
// slot — the row-counting and row-drawing loops then act as if the map
// has zero players, which suppresses the stale userinfo carried over
// from the previous map until the new server pushes fresh SETINFO
// updates (frags/deaths/topcolor/etc.).
float scoreboard_grace_until;
const float SCOREBOARD_GRACE_AFTER_LOAD = 0.5;

// Wrapped getplayerkeyvalue(.., INFOKEY_P_NAME) — the single chokepoint
// every count + draw site uses to decide whether a slot has a player.
// Returning "" during the grace period filters out every row + spectator
// without touching the loop bodies themselves.
string(float slot) Scoreboard_PlayerName =
{
    if (cltime < scoreboard_grace_until)
        return "";
    return getplayerkeyvalue(slot, INFOKEY_P_NAME);
};

float HUD_SCOREBOARD_ROW_HEIGHT = 24;
float HUD_SCOREBOARD_HEADER_HEIGHT = 22;
float HUD_SCOREBOARD_TITLE_SIZE = 18;
float HUD_SCOREBOARD_TEXT_SIZE = 12;
float HUD_SCOREBOARD_COLUMN_WIDTH = 220;
float HUD_SCOREBOARD_COLUMN_GAP = 16;
float HUD_SCOREBOARD_OUTER_PADDING = 14;
float HUD_SCOREBOARD_PICTURE_SIZE = 16;
float HUD_SCOREBOARD_SHADOW_OFFSET = 1;

// ============================================================
//  Slide-in / slide-out + fade animation
// ============================================================
// The scoreboard rises from below + fades in over SB_ANIM_IN seconds
// when +scoreboard is held, and falls back down + fades out over
// SB_ANIM_OUT seconds when released.  Easing curves match the user's
// described feel:
//   • Rising:  ease-OUT cubic — moves quickly at first, slows to
//              a stop at rest position (1 - (1-t)^3).
//   • Falling: ease-IN cubic  — starts slow, accelerates downward
//              as it leaves the rest position (t^3).
//
// sb_anim_progress is the linear 0..1 progress through the active
// transition (0 = fully hidden, 1 = fully shown).  The eased value
// derived from it drives both the Y offset and the alpha multiplier
// applied across every drawing helper in this file.
//
// HUD_ScoreboardVisible reports TRUE while sb_anim_progress > 0 so
// HUD_DrawScoreboard keeps being invoked during the fade-out tail
// (even after hud_scoreboard_held returns to 0).
// Animation timing is driven by cvars so the user can tune it without
// recompiling.  SB_ANIM_IN_DEFAULT / SB_RISE_DEFAULT are the fallback
// values used when the cvar is unset or non-positive.  The OUT
// animation is always 20% slower than the IN — derived rather than
// surfaced as its own cvar because the two ratios shouldn't drift
// independently (the close should always have a bit more weight than
// the open).
const float SB_ANIM_IN_DEFAULT  = 0.18;
const float SB_OUT_RATIO        = 1.2;     // OUT = IN * 1.2 = 20% slower
const float SB_RISE_DEFAULT     = 20;

// cl_scoreboard_time / cl_scoreboard_raise both default to non-zero
// (set in shared/sh_cvar_table.qc), but EXPLICITLY allowing 0 lets
// the user disable the animation entirely — board snaps in/out
// instantly, no rise.  Negative values are clamped to 0 (treated as
// "disabled").  The animation tick reads these and skips the lerp
// when the duration is 0.
float() SB_AnimIn =
{
    float v = cvar("cl_scoreboard_time");
    if (v < 0) v = 0;
    return v;
};

float() SB_AnimOut = { return SB_AnimIn() * SB_OUT_RATIO; };

float() SB_RiseDistance =
{
    float v = cvar("cl_scoreboard_raise");
    if (v < 0) v = 0;
    return v;
};
float sb_anim_progress;                // 0..1 linear, advances toward target each frame
float sb_anim_last_cltime;             // dt accumulator anchor
float sb_alpha_mult;                   // global alpha multiplier — set per-frame in HUD_DrawScoreboard, read by helpers
float sb_y_offset;                     // px added to board_y this frame (positive = below rest)
// Latched while the team-select picker is open OR fading out.  Set TRUE
// each frame TeamMenuIsOpen() is true; only cleared once the animation
// reaches 0 with the menu closed.  Lets the title stay "Select a Team"
// and keeps the Join buttons rendering through the fade-out tail (so
// they fade out via sb_alpha_mult instead of vanishing instantly).
float sb_anim_is_teamselect;

float() HUD_ScoreboardVisible =
{
    // Keep reporting visible during the fade-out so the draw fn
    // gets called and the animation can finish.  TeamMenuIsOpen() is
    // the persistent "team picker is up" state — referenced here
    // (instead of the per-call hud_scoreboard_teamselect flag) so
    // both the cl_main.qc draw path and the TeamMenuDraw draw path
    // agree on the showing condition each frame.  Without that
    // agreement the two paths fight each other within a single
    // frame: cl_main ticks the anim down (showing=false) and
    // TeamMenuDraw can't tick it back up because dt=0 the second
    // time through.
    return hud_scoreboard_held || TeamMenuIsOpen() || sb_anim_progress > 0;
};

// Snap the scoreboard's slide / fade animation straight to fully
// hidden.  Called from CharacterMenuSelect when the user confirms a
// model — the team menu is about to close as the join completes,
// and the user wants the picker to vanish instantly rather than
// playing the usual fade-out tail (which would be a redundant
// "going-away" animation right when they're trying to spawn).
//
// Setting sb_anim_progress to 0 is enough to skip the fade-out, but
// we must ALSO clear sb_anim_is_teamselect — otherwise the latch carries
// over into the next +showscores press and the regular scoreboard
// renders as the team picker (title says "Select a Team" + Join Blue/Red
// buttons appear) until the bail-out branch finally fires.
void() HUD_ScoreboardSnapHidden =
{
    sb_anim_progress = 0;
    sb_anim_is_teamselect = FALSE;
};

// Drop-shadowed text helper.  Multiplies through the scoreboard
// animation's global alpha multiplier so every text element on the
// scoreboard fades together — no need to plumb an alpha arg through
// every call site.
void(vector pos, string text, vector sz, vector col, float alpha) HUD_ShadowString =
{
    float a = alpha * sb_alpha_mult;
    drawstring(pos + '1 1 0' * HUD_SCOREBOARD_SHADOW_OFFSET, text, sz, '0 0 0', a * 0.5, 0);
    drawstring(pos, text, sz, col, a, 0);
};

float(float player_index) HUD_ScoreboardPlayerTeam =
{
    float team_id;
    float topcolor;
    float bottomcolor;
    string team_value;
    string topcolor_value;
    string bottomcolor_value;

    team_value = getplayerkeyvalue(player_index, "modteam");
    if (team_value != "")
    {
        team_id = stof(team_value);
        if (team_id != TEAM_NONE)
            return team_id;
    }

    topcolor = -1;
    bottomcolor = -1;
    topcolor_value = getplayerkeyvalue(player_index, INFOKEY_P_TOPCOLOR);
    bottomcolor_value = getplayerkeyvalue(player_index, INFOKEY_P_BOTTOMCOLOR);
    if (topcolor_value != "")
        topcolor = stof(topcolor_value);
    if (bottomcolor_value != "")
        bottomcolor = stof(bottomcolor_value);

    if (topcolor == 11 && bottomcolor == 2)
        return TEAM_BLUE;

    if (topcolor == 14 && bottomcolor == 5)
        return TEAM_RED;

    return TEAM_NONE;
};

string(float team_id) HUD_ScoreboardPicturePath =
{
    if (team_id == TEAM_RED)
        return "gfx/displaypicturered.png";

    if (team_id == TEAM_BLUE)
        return "gfx/displaypictureblue.png";

    return "gfx/displaypicture.png";
};

float(float team_id) HUD_ScoreboardCountTeamPlayers =
{
    float currentindex;
    float count;
    string player_name;

    count = 0;
    currentindex = 0;
    while (currentindex <= maxclients)
    {
        player_name = Scoreboard_PlayerName(currentindex);
        if (player_name != "" && HUD_ScoreboardPlayerTeam(currentindex) == team_id)
            count = count + 1;

        currentindex = currentindex + 1;
    }

    return count;
};

// Cheap rounded-corner helper — 2 px chamfer built from 3 axis-aligned
// drawfill rects.  At UI sizes (24 px row height) the eye reads it as
// "rounded".  Real anti-aliased corners would need an alpha-mask pic
// per corner; not worth the asset overhead for the scoreboard plates.
//
//             top strip (W-2 wide, 1 tall, +1px x)
//   row 0     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
//   1..H-2   ░░░░░  middle (W wide, H-2 tall) ░░░░░
//   H-1       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
//             bottom strip (W-2 wide, 1 tall, +1px x)
void(vector pos, vector size, vector colour, float alpha) HUD_DrawChamferRect =
{
    float a = alpha * sb_alpha_mult;
    drawfill([pos_x + 1, pos_y, 0],                 [size_x - 2, 1, 0],          colour, a, 0);
    drawfill([pos_x,     pos_y + 1, 0],             [size_x,     size_y - 2, 0], colour, a, 0);
    drawfill([pos_x + 1, pos_y + size_y - 1, 0],    [size_x - 2, 1, 0],          colour, a, 0);
};

// Per-player plate: chamfered translucent backdrop tinted by team,
// with optional 1 px brighter outline if this is the local player,
// then name + K/D/P stats on top.  Slot index is 0-based (matches
// the Scoreboard_PlayerName / getplayerkeyfloat convention).
//
// `fill` is the plate base colour; `outline` is the brighter team
// edge tint used for the local-player border ring.
void(float slot, vector pos, vector size, vector fill, vector outline) HUD_DrawScoreboardPlate =
{
    float row_h = size_y;
    float text_y = pos_y + (row_h - HUD_SCOREBOARD_TEXT_SIZE) * 0.5;
    float pic_y  = pos_y + (row_h - HUD_SCOREBOARD_PICTURE_SIZE) * 0.5;

    float kills_x  = pos_x + size_x - 90;
    float deaths_x = pos_x + size_x - 62;
    float ping_x   = pos_x + size_x - 34;

    float is_local = (slot + 1 == player_localentnum);
    float is_dead  = getplayerkeyfloat(slot, "dead", 0);
    float pteam    = HUD_ScoreboardPlayerTeam(slot);

    // Plate fill — dim slightly when dead so death visually reads
    // through the team tint without losing team identification.
    vector plate_col = is_dead ? (fill * 0.5) : fill;

    // Local-player outline: draw a chamfer 1 px larger on every side
    // FIRST in the brighter team-edge colour, then the actual plate
    // overdraws the centre.  Result: 1 px ring visible only at the
    // chamfer band — looks like a subtle highlight.
    if (is_local)
        HUD_DrawChamferRect([pos_x - 1, pos_y - 1, 0],
                            [size_x + 2, size_y + 2, 0],
                            outline, 0.85);

    HUD_DrawChamferRect(pos, size, plate_col, 0.55);

    // Dim text on dead rows but keep the plate fully drawn.
    float row_alpha = is_dead ? 0.45 : 1.0;

    drawfont = hud_font_regular;
    vector text_sz = [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0];

    // Speaker-state icon sits to the LEFT of the name — replaces
    // the older team-picture column.  Always shows speaking_off
    // by default, swaps to speaking while that slot's voipspeaking
    // flag is 1, replaced by muted whenever this client has muted
    // that slot.  Resolution lives in HUD_VoIP_PickIcon
    // (client/cl_voip_hud.qc).
    string mic_icon;
    if (HUD_VoIP_IsMuted(slot))             mic_icon = "gfx/mic/muted.png";
    else if (HUD_VoIP_IsSpeakingNow(slot))  mic_icon = "gfx/mic/speaking.png";
    else                                    mic_icon = "gfx/mic/speaking_off.png";
    drawpic([pos_x + 8, pic_y, 0],
            mic_icon,
            [HUD_SCOREBOARD_PICTURE_SIZE, HUD_SCOREBOARD_PICTURE_SIZE, 0],
            '1 1 1', row_alpha * sb_alpha_mult, 0);

    // Click-to-mute hit zone.  Active only while the user has
    // entered mute mode by pressing +attack2 while the scoreboard
    // is held — see HUD_VoIP_EnterMuteMode in cl_voip_hud.qc.
    // Gated by hud_voipmute_mode so the rest of the scoreboard
    // doesn't register stray SUI elements every frame.  Click
    // toggles the slot's mute; HUD_VoIP_ToggleMute also forwards
    // to the engine's cl_voip_mute command so audio is silenced.
    // Allow muting slot 0 (listen-server host from a connecting
    // client's POV — the host is their slot 0).  Only block your
    // OWN slot (player_localnum), since muting yourself is a no-op.
    if (hud_voipmute_mode && slot != player_localnum)
    {
        string mute_id = sprintf("sb_mute_%d", slot);
        sui_action_element(pos, size, mute_id, sui_noop);
        if (sui_is_clicked(mute_id))
            HUD_VoIP_ToggleMute(slot);
    }

    // Name (slight green tint for the local player, else white).
    string name = Scoreboard_PlayerName(slot);
    vector name_col = is_local ? '0.7 1 0.7' : '1 1 1';
    HUD_ShadowString([pos_x + 30, text_y, 0], name, text_sz, name_col, row_alpha);

    // Stats — same column anchor positions the old code used so all
    // rows line up with the K/D/P header drawn above the plate list.
    float frags  = getplayerkeyfloat(slot, INFOKEY_P_FRAGS, 0);
    float deaths = getplayerkeyfloat(slot, "deaths", 0);
    float ping   = getplayerkeyfloat(slot, INFOKEY_P_PING, 0);
    HUD_ShadowString([kills_x,  text_y, 0], ftos(frags),  text_sz, '1 1 1', row_alpha);
    HUD_ShadowString([deaths_x, text_y, 0], ftos(deaths), text_sz, '1 1 1', row_alpha);
    HUD_ShadowString([ping_x,   text_y, 0], ftos(ping),   text_sz, '1 1 1', row_alpha);
};

void() HUD_DrawScoreboard =
{
    float prev_font = drawfont;
    drawfont = hud_font;

    // ---- Tick the slide-in / fade animation ----
    // sb_anim_progress is the linear 0..1 advance through the active
    // transition.  hud_scoreboard_held drives the target: 1 while
    // held (rising), 0 once released (falling).  dt is wall-clock
    // since the previous draw; clamp to 0.5 to absorb pauses /
    // first-frame initialization without making the scoreboard
    // teleport open.
    float dt = cltime - sb_anim_last_cltime;
    sb_anim_last_cltime = cltime;
    if (dt < 0 || dt > 0.5) dt = 0;

    // The "show" condition combines +showscores AND the persistent
    // TeamMenuIsOpen() state — using TeamMenuIsOpen() (set by
    // TeamMenuOpen / cleared by TeamMenuClose) instead of the per-
    // call hud_scoreboard_teamselect flag is critical because
    // HUD_DrawScoreboard runs from TWO paths each frame: cl_main's
    // generic visibility check, AND TeamMenuDraw's team-pick path.
    // The two paths must agree on the showing state, otherwise
    // they fight: cl_main ticks down (teamselect flag is briefly
    // off), TeamMenuDraw ticks up but with dt=0 second time
    // through, and the animation never makes progress in either
    // direction.
    float showing = hud_scoreboard_held || TeamMenuIsOpen();

    // Latch the team-select state: TRUE while the picker is up, and
    // hold it through the fade-out tail (until sb_anim_progress hits 0)
    // so the title + join buttons keep rendering as team-select while
    // the menu is closing.
    if (TeamMenuIsOpen())
        sb_anim_is_teamselect = TRUE;

    if (showing)
    {
        float in_dur = SB_AnimIn();
        if (in_dur <= 0)
            sb_anim_progress = 1;          // snap mode — instant show
        else
            sb_anim_progress = sb_anim_progress + (dt / in_dur);
        if (sb_anim_progress > 1) sb_anim_progress = 1;
    }
    else
    {
        float out_dur = SB_AnimOut();
        if (out_dur <= 0)
            sb_anim_progress = 0;          // snap mode — instant hide
        else
            sb_anim_progress = sb_anim_progress - (dt / out_dur);
        if (sb_anim_progress < 0) sb_anim_progress = 0;
    }

    // Eased visibility:
    //   • Rising  (showing): visual = 1 - (1 - p)^3   — fast then slow
    //   • Falling (hidden):  visual = p^3             — slow then fast
    // The cube curve gives a satisfying "lifts up and settles" feel
    // on the way in and a "drops away with weight" feel on the way out.
    float visual;
    if (showing)
    {
        float inv = 1.0 - sb_anim_progress;
        visual = 1.0 - inv * inv * inv;
    }
    else
    {
        visual = sb_anim_progress * sb_anim_progress * sb_anim_progress;
    }

    // Bail out completely once fully hidden — no draws, no blur.
    // Reset sb_alpha_mult so the helpers fall back to no-op if any
    // late-binding path tries to draw outside this guard.
    if (sb_anim_progress <= 0 && !showing)
    {
        sb_alpha_mult = 0;
        sb_y_offset = SB_RiseDistance();
        sb_anim_is_teamselect = FALSE;
        drawfont = prev_font;
        return;
    }

    sb_alpha_mult = visual;
    sb_y_offset   = (1.0 - visual) * SB_RiseDistance();

    // Backdrop blur — chained drawpic of two GLSL shaders runs a
    // 2-pass separable Gaussian blur of $currentrender (the scene +
    // HUD as drawn so far this frame).  Engine refreshes
    // $currentrender between drawpic calls (SHADER_HASCURRENTRENDER
    // in gl_shader.c), so the second pass sees the first pass's
    // output and the result is a true 2D Gaussian, not a cross-
    // sample approximation.
    //
    // Blur RADIUS glides between 0 and the user's target each frame
    // — at visual=0 the kernel collapses to all-samples-at-center
    // (identity, no perceptible blur), at visual=1 it samples at the
    // full target offset.  Drawpic alpha stays at 1.0 because the
    // shader ALREADY produces the right intensity (identity → fully
    // blurred).  This avoids the "translucent blur ghost over a
    // sharp underlying image" look you'd get from blending instead
    // of ramping the kernel itself.
    //
    // Cost: O(2N) = 18 samples per screen pixel for the 9-tap kernel,
    // run only while the scoreboard is open OR fading.  At 1080p that's
    // ~37 M samples per frame — sub-millisecond on any GPU made this
    // decade.  Skipped entirely when cl_scoreboard_blur == 0.
    if (cvar("cl_scoreboard_blur"))
    {
        // Drive the shader-bound dynamic radius from the user's
        // target * eased visibility.  cvar_set is cheap (a hash
        // lookup + string write); doing it once per frame while the
        // scoreboard is open is negligible.
        float target_r = cvar("cl_scoreboard_blur_radius");
        cvar_set("sb_blur_radius_dyn", ftos(target_r * visual));

        drawpic([0, 0], "screen_blur_h", [g_width, g_height, 0], '1 1 1', 1.0, 0);
        drawpic([0, 0], "screen_blur_v", [g_width, g_height, 0], '1 1 1', 1.0, 0);
    }

    float gamemode_now = getstatf(STAT_GAMEMODE);
    float ffa_mode = Gamemode_HasUnifiedTeams();

    // ---- Layout dimensions ----
    // Reuse FFA's 1.5× column width as the floating board width — wider
    // than the old per-team column, narrower than the old two-column
    // board.  All plates and floating text render inside this band.
    float board_w  = floor(HUD_SCOREBOARD_COLUMN_WIDTH * 1.5);
    float plate_h  = 18;                                // slimmer than HUD_SCOREBOARD_ROW_HEIGHT (24): 12 px text + 3 px top/bottom padding
    float intra_gap = 2;                                // gap between plates within a team
    float inter_gap = 4;                                // gap between blue and red sections

    // Header strip above the plate list: title (18) + gamemode (12) +
    // map/timer/round line (12) + K/D/P column header line (12) + paddings.
    float header_h = 70;

    // ---- Player counts ----
    float blue_count = HUD_ScoreboardCountTeamPlayers(TEAM_BLUE);
    float red_count  = HUD_ScoreboardCountTeamPlayers(TEAM_RED);

    // Spectators (rendered as a small line under the plate list).
    float spec_count = 0;
    float si;
    for (si = 0; si < maxclients; si++)
    {
        if (HUD_ScoreboardPlayerTeam(si) == TEAM_SPEC
            && Scoreboard_PlayerName(si) != "")
            spec_count++;
    }
    float spec_h = (spec_count > 0) ? 16 : 0;

    // ---- Total content height + vertical centering ----
    float plates_h;
    if (ffa_mode)
    {
        float ffa_count = blue_count + red_count;
        plates_h = ffa_count * (plate_h + intra_gap);
    }
    else
    {
        plates_h = blue_count * (plate_h + intra_gap)
                 + red_count  * (plate_h + intra_gap);
        // Bump the final blue→red gap from intra to inter (only if both
        // teams actually have players to separate).
        if (blue_count > 0 && red_count > 0)
            plates_h = plates_h + (inter_gap - intra_gap);
    }
    float board_h = header_h + plates_h + spec_h;

    float board_x = (g_width  - board_w) * 0.5;
    // Add sb_y_offset (set by the animation tick above) so the board
    // visually rises into place when shown and slides back down when
    // hidden.  At rest (visual == 1) sb_y_offset == 0.
    float board_y = ((g_height - board_h) * 0.5) + sb_y_offset;

    // ---- Title (hostname OR "Select a Team") — floating ----
    // Use the latched flag so "Select a Team" stays during the fade-out
    // tail.  The per-call hud_scoreboard_teamselect arg is only set when
    // TeamMenuDraw drives the draw — once the menu closes, that path
    // stops firing, but cl_main keeps drawing the fade-out frames and
    // would otherwise revert the title to the server hostname.
    float as_teamselect = hud_scoreboard_teamselect || sb_anim_is_teamselect;
    string title_text;
    if (as_teamselect)
        title_text = "Select a Team";
    else
    {
        title_text = serverkey("hostname");
        if (title_text == "")
            title_text = "Server";
    }
    vector title_sz = [HUD_SCOREBOARD_TITLE_SIZE, HUD_SCOREBOARD_TITLE_SIZE, 0];
    float title_width = stringwidth(title_text, 1, title_sz);
    HUD_ShadowString([board_x + (board_w - title_width) * 0.5, board_y + 4, 0],
        title_text, title_sz, '1 1 1', 1.0);

    // ---- Gamemode label — floating, dim cyan ----
    string gamemode_str;
    if      (gamemode_now == GAMEMODE_ELIMINATION) gamemode_str = "Elimination";
    else if (gamemode_now == GAMEMODE_BHOP)        gamemode_str = "Bhop";
    else if (gamemode_now == GAMEMODE_FFA)         gamemode_str = "Free For All";
    else if (gamemode_now == GAMEMODE_PAINTGUN)    gamemode_str = "Paintball";
    else if (gamemode_now == GAMEMODE_DEFUSE)      gamemode_str = "Defuse";
    else                                           gamemode_str = "Team Deathmatch";
    vector text_sz = [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0];
    float text_w = stringwidth(gamemode_str, 1, text_sz);
    HUD_ShadowString([board_x + (board_w - text_w) * 0.5, board_y + 24, 0],
        gamemode_str, text_sz, '0.6 0.7 0.8', 0.85);

    // ---- Map name (left), timer (center), round (right) — floating row ----
    float info_y = board_y + 40;

    string map_name = serverkey("mapname");
    if (map_name == "") map_name = serverkey("map");
    if (map_name == "") map_name = infokey(world, "mapname");
    if (map_name == "") map_name = infokey(world, "map");
    if (map_name == "") map_name = "unknown";
    HUD_ShadowString([board_x, info_y, 0], map_name, text_sz, '0.8 0.8 0.8', 0.9);

    float map_timeleft = getstatf(STAT_MAPTIMELEFT);
    float map_minutes  = floor(map_timeleft / 60);
    float map_seconds  = floor(map_timeleft - map_minutes * 60);
    string map_timer_str = sprintf("%g:%02g", map_minutes, map_seconds);
    text_w = stringwidth(map_timer_str, 1, text_sz);
    HUD_ShadowString([board_x + (board_w - text_w) * 0.5, info_y, 0],
        map_timer_str, text_sz, '0.8 0.8 0.8', 0.9);

    float cur_round  = getstatf(STAT_ROUNDNUM);
    float max_rounds = getstatf(STAT_MAXROUNDS);
    string round_str = sprintf("Round: %g / %g", cur_round, max_rounds);
    text_w = stringwidth(round_str, 1, text_sz);
    HUD_ShadowString([board_x + board_w - text_w, info_y, 0],
        round_str, text_sz, '0.8 0.8 0.8', 0.9);

    // ---- K / D / P column headers — floating, dim ----
    float header_y = board_y + 56;
    float kills_x  = board_x + board_w - 90;
    float deaths_x = board_x + board_w - 62;
    float ping_x   = board_x + board_w - 34;
    HUD_ShadowString([kills_x,    header_y, 0], "K",    text_sz, '0.65 0.65 0.7', 0.85);
    HUD_ShadowString([deaths_x,   header_y, 0], "D",    text_sz, '0.65 0.65 0.7', 0.85);
    HUD_ShadowString([ping_x,     header_y, 0], "P",    text_sz, '0.65 0.65 0.7', 0.85);

    // ---- Player plates ----
    // Palette per the design spec: dark navy blue plate + brighter team
    // edge tint (used for the local-player outline ring).  Same red
    // counterparts.  FFA mode uses a neutral grey palette and skips
    // the inter-team gap.
    vector blue_fill    = '0.05 0.12 0.30';
    vector blue_outline = '0.45 0.7 1';
    vector red_fill     = '0.30 0.06 0.08';
    vector red_outline  = '1 0.42 0.42';
    vector ffa_fill     = '0.18 0.21 0.25';     // dark steel
    vector ffa_outline  = '0.55 0.62 0.70';     // brighter steel for local-player ring

    float plate_x = board_x;
    float plate_y = board_y + header_h;
    vector plate_sz = [board_w, plate_h, 0];

    // Single shared loop counter — QC function-scope locals don't allow
    // re-declaring `i` in each branch (Q207 warning).
    float i;
    if (ffa_mode)
    {
        // Single neutral list — both teams collapsed (FFA / Bhop /
        // Paintgun).  No team separator gap.
        for (i = 0; i < maxclients; i = i + 1)
        {
            if (Scoreboard_PlayerName(i) == "") continue;
            float t = HUD_ScoreboardPlayerTeam(i);
            if (t != TEAM_BLUE && t != TEAM_RED) continue;
            HUD_DrawScoreboardPlate(i, [plate_x, plate_y, 0], plate_sz, ffa_fill, ffa_outline);
            plate_y = plate_y + plate_h + intra_gap;
        }
    }
    else
    {
        // Blue first
        for (i = 0; i < maxclients; i = i + 1)
        {
            if (Scoreboard_PlayerName(i) == "") continue;
            if (HUD_ScoreboardPlayerTeam(i) != TEAM_BLUE) continue;
            HUD_DrawScoreboardPlate(i, [plate_x, plate_y, 0], plate_sz, blue_fill, blue_outline);
            plate_y = plate_y + plate_h + intra_gap;
        }
        // Bump intra to inter gap before the first red plate (only if
        // both teams have players — otherwise we'd add a phantom gap).
        if (blue_count > 0 && red_count > 0)
            plate_y = plate_y + (inter_gap - intra_gap);
        // Red second
        for (i = 0; i < maxclients; i = i + 1)
        {
            if (Scoreboard_PlayerName(i) == "") continue;
            if (HUD_ScoreboardPlayerTeam(i) != TEAM_RED) continue;
            HUD_DrawScoreboardPlate(i, [plate_x, plate_y, 0], plate_sz, red_fill, red_outline);
            plate_y = plate_y + plate_h + intra_gap;
        }
    }

    // Local layout vars used by the spectator + team-select sections
    // below — they originally referenced the deleted column layout.
    float blue_col_x = board_x;
    float red_col_x  = board_x + (board_w * 0.5) + 4;   // right half of the board
    float column_w   = (board_w * 0.5) - 4;             // half-width per join button

    // --- "In Spectate:" section under the plate list ---
    if (spec_count > 0)
    {
        string spec_names = "";
        float n;
        for (n = 0; n < maxclients; n++)
        {
            if (HUD_ScoreboardPlayerTeam(n) == TEAM_SPEC)
            {
                string pname = Scoreboard_PlayerName(n);
                if (pname != "")
                {
                    if (spec_names != "")
                        spec_names = strcat(spec_names, ", ");
                    spec_names = strcat(spec_names, pname);
                }
            }
        }

        string spec_line = strcat("In Spectate: ", spec_names);
        vector spec_sz = [12, 12, 0];
        float spec_x = board_x;
        float spec_y = board_y + board_h - 14;
        drawstring([spec_x + 1, spec_y + 1], spec_line, spec_sz, '0 0 0', 0.4, 0);
        drawstring([spec_x, spec_y], spec_line, spec_sz, '0.6 0.6 0.6', 0.75, 0);
    }

    // Team select join buttons — placed UNDER the floating board.
    // Skipped in FFA: the team-select panel is the only entry path and
    // there's no Join Blue / Join Red split for the user to make.
    if (as_teamselect && !ffa_mode)
    {
        float btn_y = board_y + board_h + 8;
        // Match the player plate height so the buttons read as "two more
        // plates" attached to the bottom of the list.  Text fits cleanly
        // at 12 px inside an 18 px button.
        float btn_h = plate_h;
        // EB font at one of its prerasterised native sizes (8 / 12 / 16
        // / 18 / 24 …) — the previous 14 px request fell between native
        // sizes and the engine had to scale, hence the blurry look.
        // 12 reads close to the old visual weight without scaling.
        float btn_text_sz = 12;
        vector btn_sz = [column_w, btn_h, 0];

        drawfont = hud_font;   // EB — native sizes only, no scaling

        vector btn_text_size = [btn_text_sz, btn_text_sz, 0];
        float blue_tw = stringwidth("Join Blue Team", 1, btn_text_size);
        float red_tw = stringwidth("Join Red Team", 1, btn_text_size);
        float blue_tx = blue_col_x + (column_w - blue_tw) * 0.5;
        float red_tx = red_col_x + (column_w - red_tw) * 0.5;
        float btn_text_y = btn_y + (btn_h - btn_text_sz) * 0.5 + 1;

        // Join buttons styled to match the scoreboard player plates:
        // chamfered translucent backdrop (HUD_DrawChamferRect) with
        // the same dark navy / dark crimson team palette + brighter
        // outline ring, instead of the old opaque SUI box look.
        // Hover / held states tint the fill brighter / darker so the
        // button still feels clickable.
        //
        // Drop shadow is gone — the chamfer outline ring serves the
        // same visual depth purpose at lower fill cost.  All alpha
        // values flow through HUD_DrawChamferRect (which already
        // multiplies by sb_alpha_mult) so the buttons fade in/out
        // with the rest of the scoreboard automatically.

        // Same palette as the scoreboard plates above.
        vector blue_plate_fill    = '0.05 0.12 0.30';
        vector blue_plate_outline = '0.45 0.7 1';
        vector red_plate_fill     = '0.30 0.06 0.08';
        vector red_plate_outline  = '1 0.42 0.42';

        // SUI input registration (sui_action_element / sui_is_*) MUST be
        // bracketed by sui_pre_draw / sui_draw — that bracket is only set
        // up by TeamMenuDraw's path while TeamMenuIsOpen() is true.
        // During the fade-out tail cl_main becomes the draw path (no SUI
        // bracket), so we draw the buttons visually for the fade but
        // skip the input registration.  Calling sui_action_element
        // outside the bracket spams "adding sui elements before
        // sui_pre_draw" to the console every frame.
        float sui_active = TeamMenuIsOpen();

        // --- Blue Join Button ---
        if (sui_active)
            sui_action_element([blue_col_x, btn_y], btn_sz, "ts_join_blue", sui_noop);

        vector b_fill = blue_plate_fill;
        if (sui_active && sui_is_hovered("ts_join_blue")) b_fill = blue_plate_fill + '0.06 0.10 0.18';
        if (sui_active && sui_is_held("ts_join_blue"))    b_fill = b_fill * 0.65;
        // Outline ring drawn 1 px larger, then fill on top — gives a
        // subtle 1 px brighter rim around the chamfer.
        HUD_DrawChamferRect([blue_col_x - 1, btn_y - 1, 0],
                            [btn_sz_x + 2, btn_sz_y + 2, 0],
                            blue_plate_outline, 0.85);
        HUD_DrawChamferRect([blue_col_x, btn_y, 0], btn_sz, b_fill, 0.55);

        HUD_ShadowString([blue_tx, btn_text_y, 0], "Join Blue Team", btn_text_size, '1 1 1', 1.0);

        if (sui_active && sui_is_clicked("ts_join_blue"))
            TeamMenuSelect(TEAM_BLUE);

        // --- Red Join Button ---
        if (sui_active)
            sui_action_element([red_col_x, btn_y], btn_sz, "ts_join_red", sui_noop);

        vector r_fill = red_plate_fill;
        if (sui_active && sui_is_hovered("ts_join_red")) r_fill = red_plate_fill + '0.18 0.06 0.06';
        if (sui_active && sui_is_held("ts_join_red"))    r_fill = r_fill * 0.65;
        HUD_DrawChamferRect([red_col_x - 1, btn_y - 1, 0],
                            [btn_sz_x + 2, btn_sz_y + 2, 0],
                            red_plate_outline, 0.85);
        HUD_DrawChamferRect([red_col_x, btn_y, 0], btn_sz, r_fill, 0.55);

        HUD_ShadowString([red_tx, btn_text_y, 0], "Join Red Team", btn_text_size, '1 1 1', 1.0);

        if (sui_active && sui_is_clicked("ts_join_red"))
            TeamMenuSelect(TEAM_RED);

        if (sui_active)
            sui_set_default_kb_focus("ts_join_blue");
    }

    drawfont = prev_font;
};

float(float evtype, float scanx, float chary, float devid) HUD_ScoreboardInputEvent =
{
    string cmd;

    if (evtype != IE_KEYDOWN && evtype != IE_KEYUP)
        return FALSE;

    cmd = getkeybind(scanx);
    if (scanx != K_TAB && cmd != "+showscores" && cmd != "showscores")
        return FALSE;

    if (evtype == IE_KEYDOWN)
    {
        // Always restart the fade-in animation on every fresh press,
        // even when the panel is mid-fade-out — reset progress to 0
        // so the user always sees the full fade-in sweep instead of
        // a snap or a half-way ease.  Gated on !hud_scoreboard_held
        // so OS-level auto-repeat KEYDOWNs while the key is held
        // don't continuously reset the animation mid-fade-in.
        if (!hud_scoreboard_held)
            sb_anim_progress = 0;
        hud_scoreboard_held = TRUE;
    }
    else
    {
        hud_scoreboard_held = FALSE;
    }

    return TRUE;
};
