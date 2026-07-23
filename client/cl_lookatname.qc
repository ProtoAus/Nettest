// =============================================================
//  client/cl_lookatname.qc  -  Look-at player name tag
// =============================================================
//
//  Pulses a forward tracebox at 10 Hz; when it hits a remote
//  player_visual_proxy, surfaces that player's name two ways:
//    1. small HUD label down-and-left of the crosshair (GoogleMed)
//    2. world-space label floating just above their head, scaled +
//       fading with distance from the viewer
//  When no remote player is in the crosshair, both labels vanish.
//
//  Flicker handling:
//    Each successful pulse stamps `lookat_last_seen`.  The labels
//    stay visible until that stamp is older than LOOKAT_HOLD_TIME
//    — a single missed pulse (trace briefly grazing a smoke puff,
//    bullet decal, or the proxy's bbox edge during interp) does
//    NOT wipe the name.  Only sustained loss of trace contact
//    (~0.5 s) clears.  Tracebox (small 4u cube) replaces the
//    bare traceline for the same forgiveness reason.
//
//  Coordination with the VOIP overhead icon: while a name is
//  showing for player N, the VOIP icon for the same player is
//  drawn LOOKAT_VOIP_OFFSET_BUMP pixels higher than usual so the
//  text + icon don't overlap.  cl_voip_hud.qc reads
//  `lookat_target_slot` to detect this and bump its z offset on
//  the matching slot only.

const float LOOKAT_PULSE_INTERVAL    = 0.1;      // 10 Hz traceline pulses (smoother than 5 Hz)
const float LOOKAT_MAX_RANGE         = 4096;
const float LOOKAT_HOLD_TIME         = 0.9;      // seconds to keep showing after last positive hit (raised from 0.45 — single-pulse blockers from prop/proj/door drift were dropping the name visibly)
const float LOOKAT_TRACE_HALF        = 4;        // tracebox half-extent (8u cube) — wider forgiveness when interp puts the proxy slightly off-axis
const float LOOKAT_RETRY_BUDGET      = 3;        // skip-through this many non-proxy SOLIDs before giving up

const float LOOKAT_VOIP_OFFSET_BUMP  = 12;       // VOIP icon shifts up by this when name is showing

// HUD label placement (relative to crosshair / screen centre).
const float LOOKAT_HUD_OFFSET_X      = -120;     // px LEFT of crosshair (further left)
const float LOOKAT_HUD_OFFSET_Y      = 56;       // px BELOW crosshair (further down)
const float LOOKAT_HUD_FONT_SIZE     = 12;       // native bucket (loadfont in cl_main.qc:108)

// World-space label sizing.  Drawn after projecting the player's
// head position to 2D screen coords.  Alpha falls off with
// distance; the font size SNAPS to one of three native buckets
// (8 / 12 / 16) so the rasteriser never has to scale the glyphs.
// Native sizes are pulled from hud_font's loadfont sizes list
// (cl_main.qc:106 = "8 12 16 18 24 32 36 48 60 72"); any value
// off-list forces FTE to stretch the cached glyph atlas and
// produces blurry / smeared text.
const float LOOKAT_WORLD_Z_OFFSET    = 48;       // base height above proxy.origin (then +BUMP)
const float LOOKAT_WORLD_NEAR_DIST   = 192;      // <= this → 16 px font, full alpha
const float LOOKAT_WORLD_MID_DIST    = 768;      // <= this → 12 px font
const float LOOKAT_WORLD_FAR_DIST    = 2048;     // >= this → 8 px font, min alpha
const float LOOKAT_WORLD_NEAR_ALPHA  = 0.85;     // alpha at NEAR_DIST (always a little transparent)
const float LOOKAT_WORLD_FAR_ALPHA   = 0.30;     // alpha at FAR_DIST

// --- State (file-scope) ---
//
// lookat_target_slot is 0-based player slot index; -1 = none.
// Exposed for cl_voip_hud.qc to read without forward decls; QC
// linker shares globals across files compiled in the same VM.
// `var` keyword forces mutable storage — bare `float x = expr;`
// at file scope is treated as a constant by fteqcc.
var float  lookat_target_slot = -1;
string lookat_target_name;
float  lookat_last_pulse;
float  lookat_last_seen;       // cltime stamp of the most recent successful pulse

// Helper: linear interp + clamp used by both size and alpha falloff.
float(float t, float a, float b) lookat_lerp =
{
    if (t <= 0) return a;
    if (t >= 1) return b;
    return a + (b - a) * t;
};

// Pulse — fire a forward tracebox from the view origin once every
// LOOKAT_PULSE_INTERVAL seconds.  Successful hits stamp
// `lookat_last_seen`; misses do NOT clear the slot — only the
// time-based hold check in CSQC_LookatName_ShouldShow does that.
//
// Retry chain: if the first trace lands on a non-proxy SOLID
// (dropped weapon, physprop, in-flight projectile, door brushwork,
// even our own player_visual_proxy when the local prediction shoves
// it briefly forward) we skip-trace from that hit point up to
// LOOKAT_RETRY_BUDGET times.  Without the chain, a single
// foreground prop on the listen-server host's spawn pad would steal
// every pulse and clear the name within LOOKAT_HOLD_TIME, producing
// the on/off flicker the user reported.
void() CSQC_LookatName_Pulse =
{
    if (cltime - lookat_last_pulse < LOOKAT_PULSE_INTERVAL)
        return;
    lookat_last_pulse = cltime;

    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector trace_end = view_pos + v_forward * LOOKAT_MAX_RANGE;

    vector mins = -LOOKAT_TRACE_HALF * '1 1 1';
    vector maxs =  LOOKAT_TRACE_HALF * '1 1 1';

    vector seg_start  = view_pos;
    entity skip_ent   = self;
    float  retries    = LOOKAT_RETRY_BUDGET;
    entity hit;

    for (;;)
    {
        tracebox(seg_start, mins, maxs, trace_end, MOVE_NORMAL, skip_ent);
        hit = trace_ent;

        if (hit == world || hit == self)
            return;   // hit nothing useful — hold timer will absorb

        // Prop Hunt: a disguised hider must behave EXACTLY like a real prop
        // here — fall through into the skip-trace retry below.  A hard stop
        // would let players A/B a suspect prop by whether a teammate's label
        // BEHIND it survives (real props resume the trace, so the label
        // does; a disguised proxy that swallowed the pulse would decay it).
        if (hit.classname == "player_visual_proxy" && !hit.ph_disguise_modelindex)
            break;     // resolved — fall through to slot bookkeeping

        if (retries <= 0)
            return;    // gave up — hold timer will absorb
        retries -= 1;

        // Resume the trace just past the blocker.  Nudge forward by
        // LOOKAT_TRACE_HALF + 1 so we don't immediately re-collide
        // with the same entity due to the box half-extent.
        seg_start = trace_endpos + v_forward * (LOOKAT_TRACE_HALF + 1);
        skip_ent  = hit;
    }

    // Corpses still carry the player_visual_proxy classname (they're
    // the same entity, just detached from the live player at death
    // — see Player_VisualProxy_DetachAsCorpse).  Live proxies are
    // SOLID_BBOX, corpses are SOLID_NOT so they normally don't halt
    // a trace, but the detach window leaves a brief solid+dead gap.
    // Don't force-clear the current target on a corpse hit — just
    // treat it as a non-proxy blocker (the previous behaviour
    // dropped the live target's name within one pulse if a corpse
    // happened to drift in front of them).
    if (hit.vis_is_dead)
        return;

    float slot = hit.vis_owner_entnum - 1;
    if (slot < 0 || slot == player_localnum)
        return;

    // Refresh slot/name and stamp last-seen — labels stay live.
    if (lookat_target_slot != slot)
    {
        lookat_target_slot = slot;
        string nm = getplayerkeyvalue(slot, "name");
        if (nm == "") nm = "?";
        lookat_target_name = nm;
    }
    lookat_last_seen = cltime;
};

// Time-based gate.  Returns 1 while the hold window is still
// open, 0 once we've gone LOOKAT_HOLD_TIME without a hit.
// Centralised so HUD + World draw + VOIP-bump check agree.
float() CSQC_LookatName_ShouldShow =
{
    if (lookat_target_slot < 0) return 0;
    if (cltime - lookat_last_seen > LOOKAT_HOLD_TIME)
    {
        lookat_target_slot = -1;
        return 0;
    }
    return 1;
};

// HUD label — small GoogleMed text down-and-left of the
// screen-centre crosshair.  Drawn during the 2D HUD pass.
void() CSQC_LookatName_DrawHUD =
{
    if (!CSQC_LookatName_ShouldShow()) return;

    float cx = g_width * 0.5;
    float cy = g_height * 0.5;
    float x = cx + LOOKAT_HUD_OFFSET_X;
    float y = cy + LOOKAT_HUD_OFFSET_Y;

    vector sz = [LOOKAT_HUD_FONT_SIZE, LOOKAT_HUD_FONT_SIZE, 0];
    float prev = drawfont;
    drawfont = hud_font_mono;       // GoogleMed
    // Single draw — readability border is the font's baked outline (outline=1).
    drawstring([x, y],         lookat_target_name, sz, '1 1 1', 1.0, 0);
    drawfont = prev;
};

// World-space label — projects the player's overhead position to
// 2D screen coords and draws the name there, scaled + faded by
// distance from the viewer.  Drawn in the 2D HUD pass (after
// renderscene) since project() returns 2D coords.
void() CSQC_LookatName_DrawWorld =
{
    if (!CSQC_LookatName_ShouldShow()) return;

    // Re-resolve the proxy each frame so the label tracks the
    // player's current position (not the stale cached pulse-time
    // position 0–100ms old).
    entity proxy;
    for (proxy = findchain(classname, "player_visual_proxy"); proxy; proxy = proxy.chain)
    {
        float slot = proxy.vis_owner_entnum - 1;
        if (slot != lookat_target_slot) continue;
        // Multiple proxies can share the same owner slot for a brief
        // window after a kill (the detached corpse + the freshly
        // respawned live proxy both report the same vis_owner_entnum).
        // Skip dead proxies so the label tracks the LIVE player's
        // head, not the body lying on the floor.  vis_is_corpse is
        // SSQC-only; CSQC sees the same state via vis_is_dead, which
        // the server sets via VP_SF_IDENTITY during DetachAsCorpse.
        if (proxy.vis_is_dead) continue;
        // Prop Hunt: if the target possessed a prop DURING the hold window,
        // drop the target outright — kills BOTH labels this frame instead of
        // floating the name over the disguise for the rest of the hold (the
        // pulse above already refuses to refresh a disguised hit).
        if (proxy.ph_disguise_modelindex)
        {
            lookat_target_slot = -1;
            return;
        }

        // Anchor at the VOIP icon's NORMAL height — when the name
        // tag is showing, cl_voip_hud.qc pushes the icon up by
        // LOOKAT_VOIP_OFFSET_BUMP so the text takes the icon's
        // original slot.  Result: icon sits 12 px above the name.
        float z_ofs = cvar("cl_voip_overhead_offset");
        if (z_ofs <= 0) z_ofs = LOOKAT_WORLD_Z_OFFSET;

        vector world_pos = proxy.origin + '0 0 1' * z_ofs;
        vector screen = (vector)project(world_pos);
        if (screen_z <= 0) return;     // behind camera

        // Alpha falls off linearly NEAR→FAR.  Font size SNAPS into
        // one of three native loadfont buckets (8 / 12 / 16) so the
        // glyph atlas isn't scaled — see LOOKAT_WORLD_*_DIST.  Any
        // off-list size forces FTE to stretch a cached bitmap and
        // smears the text; the visible "size step" at the bucket
        // boundaries is the cost of crisp glyphs.
        vector view_pos = (vector)getproperty(VF_ORIGIN);
        float dist = vlen(proxy.origin - view_pos);

        float font_h;
        if (dist <= LOOKAT_WORLD_NEAR_DIST)
            font_h = 16;
        else if (dist <= LOOKAT_WORLD_MID_DIST)
            font_h = 12;
        else
            font_h = 8;

        float t = (dist - LOOKAT_WORLD_NEAR_DIST)
                / (LOOKAT_WORLD_FAR_DIST - LOOKAT_WORLD_NEAR_DIST);
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        float alpha = lookat_lerp(t, LOOKAT_WORLD_NEAR_ALPHA, LOOKAT_WORLD_FAR_ALPHA);

        // Centre the text horizontally on the head's screen pos.
        vector sz = [font_h, font_h, 0];
        float text_w = stringwidth(lookat_target_name, FALSE, sz);
        float tx = screen_x - text_w * 0.5;
        float ty = screen_y - font_h * 0.5;

        float prev = drawfont;
        drawfont = hud_font;
        drawstring([tx, ty],         lookat_target_name, sz, '1 1 1', alpha,        0);
        drawfont = prev;
        return;
    }

    // Proxy not in chain right now (left PVS, mid-respawn, etc.).
    // Don't clear — the LOOKAT_HOLD_TIME gate will drop it cleanly
    // if the absence persists.  Bailing eagerly here was the main
    // source of single-frame flicker when proxies briefly re-link.
};
