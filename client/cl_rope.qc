// ============================================================================
//  client/cl_rope.qc  —  grappling hook rope visual (sv_grappling)
//
//  Owner-only rope.  Server maintains predicted_player.grapple_anchor and
//  predicted_player.grapple_rope_active via PM_SyncPredictionProxy each
//  tick (see sv_grapple.qc + cl_player.qc proxy reader); this code just
//  draws a tiled textured quad from the local player's waist to the
//  anchor whenever the flag is set.  Bypasses the standard server-entity
//  broadcast which doesn't reliably reach CSQC for ad-hoc projectile
//  entities.
//
//  Texture path: gfx/rope/rope (user-supplied tileable horizontal
//  PNG with "looping" UVs).  V2 (broadcast visibility for other players)
//  will need a SendEntity serializer on the hook entity.
// ============================================================================

const string ROPE_SHADER = "gfx/rope/rope";

// Inline Quake-3 shader script for the rope.  Using a custom shader is
// the only way to get REPEAT wrap on `R_BeginPolygon` in FTE — the
// engine's PF_CL_precache_pic explicitly disables the NOCLAMP flag with
// a "use a shader instead" comment (engine/client/pr_menu.c:828), and
// the built-in Shader_PolygonShader generator that R_BeginPolygon falls
// back to doesn't expose wrap mode.  R_LoadShader at gl_shader.c:7774
// reuses a previously-registered Shader_DefaultScript shader for the
// same name, so a shaderforname() up front overrides the polygon
// generator with this body.
//
// Body explanation: one stage, vertex rgb/alpha so our `colour, 1`
// args still control tint and opacity, blendfunc blend so the PNG's
// alpha channel renders correctly.  `map` defaults to REPEAT wrap
// (vs `clampmap` for clamp), which is exactly what we want.
const string ROPE_SHADER_BODY =
    "{\n"
    "  {\n"
    "    map gfx/rope/rope\n"
    "    rgbgen vertex\n"
    "    alphagen vertex\n"
    "    blendfunc blend\n"
    "  }\n"
    "}\n";

// Width + tile rate are runtime-tunable so the user can dial the rope's
// look without rebuilding.  Defaults (1.5 / 16) match a 187×32 rope.png
// rendered ~3 u thick with a roughly natural texture aspect.

// ----------------------------------------------------------------
//  Init — caches the texture once.  Called from CSQC_Init.
// ----------------------------------------------------------------
void() CSQC_Rope_Init =
{
    // Register the shader explicitly with our REPEAT-wrap body.  Done
    // ONCE at init — subsequent R_BeginPolygon(ROPE_SHADER, ...) calls
    // get this script via R_LoadShader's caching.
    shaderforname(ROPE_SHADER, ROPE_SHADER_BODY);
};

// Render-side smoothed anchor for REMOTE ropes: the networked grapple_anchor
// steps per snapshot during the hook's flight, so we ease toward it each frame
// (the player END is already the interp-smoothed proxy origin).  grapple_render_init
// snaps it on (re)activation so a new throw doesn't streak from a stale point.
.vector grapple_anchor_render;
.float  grapple_render_init;

// Remote waist offset from the proxy origin.  Remote proxies don't carry view_ofs,
// so approximate the standing waist (origin + ~eye(22) - 16).  Tunable to taste.
const vector ROPE_REMOTE_WAIST = '0 0 6';

// ----------------------------------------------------------------
//  Draw one rope segment (waist -> tip) as a screen-facing tiled
//  textured quad.  Shared by the local and remote rope paths.
// ----------------------------------------------------------------
void(vector p_waist, vector p_tip) Rope_DrawSegment =
{
    vector dir = p_tip - p_waist;
    float  len = vlen(dir);
    if (len < 1)
        return;
    dir = dir * (1 / len);

    // Screen-facing perpendicular — cross of rope direction with
    // camera-to-midpoint.  Mirrors the cl_tracers.qc:144-163 pattern.
    vector cam_pos = (vector)getproperty(VF_ORIGIN);
    vector mid = (p_waist + p_tip) * 0.5;
    vector cam_to_mid = mid - cam_pos;
    if (vlen(cam_to_mid) < 0.01)
        return;
    cam_to_mid = normalize(cam_to_mid);
    vector side = crossproduct(dir, cam_to_mid);
    // Fallback when rope is collinear with eye-to-rope — pick a world
    // axis perpendicular to the rope direction instead.
    if (vlen(side) < 0.01)
    {
        if (fabs(dir_z) < 0.95)
            side = crossproduct(dir, '0 0 1');
        else
            side = crossproduct(dir, '1 0 0');
        if (vlen(side) < 0.01)
            return;
    }
    float half_w = cvar("cl_grappling_rope_width");
    if (half_w <= 0) half_w = 1.5;
    side = normalize(side) * half_w;

    vector p1n = p_waist - side;
    vector p1p = p_waist + side;
    vector p2p = p_tip   + side;
    vector p2n = p_tip   - side;

    // Tile horizontally so the rope reads as repeating strand at any
    // length.  At least one full tile for short ropes.
    float tile_len = cvar("cl_grappling_rope_tile");
    if (tile_len < 1) tile_len = 16;
    float u_tile = len / tile_len;
    if (u_tile < 1) u_tile = 1;

    // UV mapping: U-axis (horizontal in the texture, 187 px on the
    // user's rope.png) follows the rope's LENGTH from waist→anchor,
    // tiling u_tile times so the loop repeats end-to-end as the rope
    // extends.  V-axis (vertical, 32 px) goes across the rope's
    // thin width.  The old assignment had U and V swapped, which
    // rotated the texture 90° and squashed it into a single tile
    // across the rope width.
    //
    //   p1n (waist, edge1) → U=0,        V=0
    //   p1p (waist, edge2) → U=0,        V=1
    //   p2p (anchor, edge2)→ U=u_tile,   V=1
    //   p2n (anchor, edge1)→ U=u_tile,   V=0
    vector colour = '1 1 1';
    R_BeginPolygon(ROPE_SHADER, 0, 0);
    R_PolygonVertex(p1n, '0 0 0',         colour, 1);
    R_PolygonVertex(p1p, '0 1 0',         colour, 1);
    R_PolygonVertex(p2p, [u_tile, 1, 0],  colour, 1);
    R_PolygonVertex(p2n, [u_tile, 0, 0],  colour, 1);
    R_EndPolygon();
};

// ----------------------------------------------------------------
//  Local player's rope — waist+anchor from the prediction proxy.
//  Called per-frame from CSQC_UpdateView.
// ----------------------------------------------------------------
void() CSQC_Rope_Draw =
{
    if (!predicted_player || !predicted_player.grapple_rope_active)
        return;
    Rope_DrawSegment(predicted_player.origin + predicted_player.view_ofs + '0 0 -16',
                     predicted_player.grapple_anchor);
};

// ----------------------------------------------------------------
//  Remote players' ropes — driven by the visual-proxy GRAPPLE section
//  (grapple_rope_active + grapple_anchor).  Waist follows the proxy's
//  already-interp-smoothed origin; the anchor is eased per frame so the
//  hook's per-snapshot flight reads smooth.  Called alongside CSQC_Rope_Draw.
// ----------------------------------------------------------------
void() CSQC_Rope_DrawRemotes =
{
    entity proxy = findchain(classname, "player_visual_proxy");
    while (proxy)
    {
        if (proxy.grapple_rope_active
            && proxy.vis_owner_entnum != player_localentnum
            && !proxy.vis_is_dead)
        {
            if (!proxy.grapple_render_init)
            {
                proxy.grapple_anchor_render = proxy.grapple_anchor;   // snap on activate
                proxy.grapple_render_init   = 1;
            }
            else
            {
                float k = bound(0, frametime * 18, 1);   // exp-ease toward the networked anchor
                proxy.grapple_anchor_render = proxy.grapple_anchor_render
                    + (proxy.grapple_anchor - proxy.grapple_anchor_render) * k;
            }
            Rope_DrawSegment(proxy.origin + ROPE_REMOTE_WAIST, proxy.grapple_anchor_render);
        }
        else
            proxy.grapple_render_init = 0;   // reset so the next throw snaps fresh
        proxy = proxy.chain;
    }
};
