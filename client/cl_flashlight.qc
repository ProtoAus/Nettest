// ============================================================
//  client/cl_flashlight.qc  -  Player flashlight (dlight)
//
//  Toggle via WEAPON_IMPULSE_FLASHLIGHT (default 'l', rebindable
//  in the Settings → Controls list). Plays a click sound on
//  toggle and renders an FTE dlight every frame while on.
//
//  Two render styles, picked by `cl_flashlight_style`:
//
//    style 0 = SPOT
//      FOV-driven cone via dynamiclight_set(LFIELD_FOV). Engine
//      uses LSHADER_SPOT (gl_shadow.c:3760) which renders a single
//      2D shadowmap and a circular falloff — cheap. Cone width is
//      cl_flashlight_fov degrees. NO cookie texture (engine NULLs
//      it at gl_backend.c:4305: "if (lmode & LSHADER_SPOT)
//      lightcubemap = r_nulltex").
//
//    style 1 = CUBEMAP COOKIE
//      No FOV — light is omnidirectional, but the cubemap mask
//      ZEROES OUT directions where the cubemap is black, so the
//      visible result is cone-shaped. More expensive — engine
//      considers the full radius sphere and samples the 6-face
//      cubemap per fragment. Use when you want a textured beam
//      (logo, gobo, soft falloff) instead of a flat cone.
//
//  These two are MUTUALLY EXCLUSIVE in FTE's GL backend — you
//  can't have both a cone shadowmap AND a cubemap cookie. The
//  cvar picks one. There's no way to combine them in current
//  FTE without an engine change to register a SPOT|CUBE shader
//  permutation.
//
//  Cookie file layout (style 1 only): 6 cubemap faces at
//  gfx/cubemap/flashlight_{px,nx,py,ny,pz,nz}.tga (or .png/.jpg).
//  The flashlight pattern goes on +X (forward in Quake convention,
//  matches v_forward); other five faces black. FTE's image loader
//  (image.c:13981) tries px/nx scheme AND rt/lf/bk/ft/up/dn —
//  either naming works. Folder name is the prefix in
//  FLASHLIGHT_COOKIE_SHADER below; FTE doesn't search subpaths.
//
//  Important: rt-dlight rendering requires r_shadow_realtime_dlight.
//  Without it the dlight falls back to vertex lighting (the cookie
//  isn't sampled in style 1, the cone shadowmap isn't computed in
//  style 0). We force the cvar on the first time the flashlight
//  toggles on.
//
//  Client-only — not networked. Other players don't see the beam.
// ============================================================

// NOTE: this string IS the path prefix, not a folder to search in.
// R_LoadReplacementTexture hands it to Image_LoadCubemapTextureData,
// which builds each face as sprintf("%s_%s%s", <this>, "px", ".tga")
// (image.c:14102) with no base directory of its own — so the folder
// the cookie loads from is whatever this string says, and moving the
// files means editing this line in the same commit.
// Lived at `cubemap/` until 2026-07-28; now under gfx/ with the rest
// of the loose image content.
const string FLASHLIGHT_COOKIE_SHADER = "gfx/cubemap/flashlight";
const string FLASHLIGHT_TOGGLE_SOUND  = "sounds/player/flashlight.wav";

// Forward of the view origin where the dlight sits, so the
// cookie projects from "in front of" the camera rather than
// from the player's eye exactly. Small offset — far enough
// to skip the near-clip plane, close enough that walls
// directly in front still light up.
const float  FLASHLIGHT_FORWARD_OFFSET = 8;

float csqc_flashlight_on;
float csqc_flashlight_realtime_forced;   // one-shot: forced rt-dlight on first use

// TELLING THE SERVER, which until now knew nothing about the torch at all.
//
// The flashlight is pure CSQC — the server has no field for it and never had a
// reason to.  It has one now: Half-Life's cockroach bolts when the light on it
// changes (CRoach::MonsterThink samples GETENTITYILLUM), and the light that
// actually falls on a roach in a They Hunger cellar is the player's torch.  A
// server-side reaction needs a server-side fact.
//
// One `cmd` on the EDGE, and edge-only is safe here: `cmd` rides the client's
// RELIABLE stringcmd channel, so unlike a per-frame push there is nothing to
// re-assert against loss.  A torch is toggled a handful of times a map, so the
// whole feature costs a handful of short reliable messages.
//
// Latched to +1/+2 rather than 0/1 so the "never told" state is distinguishable
// from "told OFF" and the first press after connecting always sends.
float csqc_flashlight_told;

void() CSQC_Flashlight_Tell =
{
    float want = csqc_flashlight_on ? 2 : 1;
    if (csqc_flashlight_told == want)
        return;
    csqc_flashlight_told = want;
    localcmd(sprintf("cmd fl %g\n", csqc_flashlight_on ? 1 : 0));
};

void() CSQC_Flashlight_Precache =
{
    precache_sound(FLASHLIGHT_TOGGLE_SOUND);

    // Pre-load the cookie cubemap so the FIRST flashlight toggle
    // doesn't render as an unmasked sphere while the engine is
    // still loading the 6 face files off disk. dynamiclight_add
    // queues the cubemap load on its first call with a given name
    // (engine/gl/gl_rlight.c PF_R_DynamicLight_AddInternal calls
    // R_LoadReplacementTexture); we don't actually want the dlight
    // to render anything, so radius is 1 (effectively invisible),
    // origin is far from any player view, and the dlight expires
    // on the next frame anyway because dynamic dlights die at
    // cl.time - 0.1 unless re-issued. The cookie texture stays in
    // the engine's cache.
    dynamiclight_add('0 0 -16384', 1, '0 0 0', 0,
                     FLASHLIGHT_COOKIE_SHADER, PFLAGS_NOSHADOW);
};

// Toggle handler — called from CSQC_PredictWeaponImpulse on
// WEAPON_IMPULSE_FLASHLIGHT. Sound is gated on
// pm_suppress_sounds so prediction-replay doesn't spam clicks
// when a single keypress's command is replayed across the
// reconcile window.
// mp_flashlight, Sven's server-side permission for the flashlight
// (default_map_settings.cfg:138).  READ FROM SERVERINFO, NOT FROM A
// LOCAL CVAR: the light is drawn entirely here in CSQC, so a local
// cvar() lookup would let any client hand itself a torch on a server
// that has taken it away.  sv_main.qc publishes it on change; the
// same route mp_noblock takes for the same reason.
//
// serverkeyfloat returns 0 for a key that was never published, which
// would read as "banned", so an unset key is treated as ALLOWED —
// only an explicit "0" switches it off.  That also keeps demos and
// older servers working.
float() CSQC_Flashlight_Allowed =
{
    string v = serverkey("mp_flashlight");
    if (v == "" || !v)
        return TRUE;
    return (stof(v) != 0);
};

void() CSQC_Flashlight_Toggle =
{
    // Refuse the toggle rather than blanking it in the renderer, so
    // the player gets no click and no light and learns immediately
    // that the map has taken it off them.  hl_c17 and hl_c18 both
    // fire trigger_setcvar to do exactly this.
    if (!CSQC_Flashlight_Allowed())
    {
        csqc_flashlight_on = 0;
        CSQC_Flashlight_Tell();
        return;
    }

    csqc_flashlight_on = !csqc_flashlight_on;
    CSQC_Flashlight_Tell();

    if (!pm_suppress_sounds)
        localsound(FLASHLIGHT_TOGGLE_SOUND);

    // First-use force-on of realtime dlights — required for
    // spotlight cone rendering (otherwise the dlight falls back
    // to a vertex-lit sphere and ignores fov). One-shot so we
    // don't fight the user if they explicitly disabled it.
    if (csqc_flashlight_on && !csqc_flashlight_realtime_forced)
    {
        csqc_flashlight_realtime_forced = 1;
        if (cvar("r_shadow_realtime_dlight") <= 0)
            localcmd("r_shadow_realtime_dlight 1\n");
    }
};

// Per-frame render — called from CSQC_UpdateView's predicted-
// camera path AFTER setproperty(VF_ANGLES) so v_forward (set
// by the makevectors call below) matches the actual rendered
// camera direction. Skipped silently when off, when not in a
// live first-person game (predicted_player missing), or while
// in team-select.
void() CSQC_Flashlight_Render =
{
    if (!csqc_flashlight_on)
        return;
    // Revoked mid-map — hl_c17 and hl_c18 both switch mp_flashlight off
    // from a trigger_setcvar while the player may already have the light
    // on, so the permission has to be re-checked per frame and not only
    // at the toggle.  Latch it off so turning it back on later needs a
    // fresh press.
    if (!CSQC_Flashlight_Allowed())
    {
        csqc_flashlight_on = 0;
        CSQC_Flashlight_Tell();
        return;
    }
    // Sven's "hud_flashlight" on a trigger_camera.  Also covers the general
    // case: the beam is cast from VF_ORIGIN, which during a cutscene is the
    // camera, so leaving it on would light whatever the cutscene is filming
    // from an angle the player isn't standing at.
    if (Cutscene_HidesHud(CUTSCENE_SF_NOFLASH) || Cutscene_Active())
        return;
    if (!predicted_player || !csqc_prediction_valid)
        return;
    if (getstati(STAT_PLAYERTEAM) <= TEAM_NONE)
        return;
    if (getstatf(STAT_IS_DEAD))
        return;

    float radius     = cvar("cl_flashlight_radius");
    if (radius <= 0) radius = 400;
    float brightness = cvar("cl_flashlight_brightness");
    if (brightness <= 0) brightness = 1.5;

    // Colour cvar parsed as "r g b" (0..1 range). Defaults to
    // a warm white that reads as "flashlight" rather than the
    // pure-white you'd get from a fluorescent — matches Source.
    string col_text = cvar_string("cl_flashlight_color");
    vector col;
    if (col_text == "")
    {
        col = '1.0 0.95 0.85';
    }
    else
    {
        float n = tokenize(col_text);
        if (n >= 3)
            col = [stof(argv(0)), stof(argv(1)), stof(argv(2))];
        else
            col = '1.0 0.95 0.85';
    }
    col = col * brightness;

    // Camera origin + forward come from the rendered VF_ values
    // populated by cl_main.qc's predicted-camera setup. Reading
    // them here (instead of recomputing from view_angles) means
    // the flashlight tracks the EXACT camera (including sniper
    // sway + gunkick view bias) rather than diverging from it
    // by a frame or by those visual modifiers.
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);

    // Push the dlight slightly forward so the cone projects
    // from "in front of" the camera rather than from the eye
    // exactly (which would clip at the near plane).
    vector light_pos = view_pos + v_forward * FLASHLIGHT_FORWARD_OFFSET;

    // Style picks SPOT cone (cheap, no cookie) vs CUBEMAP cookie
    // (more expensive, textured beam). See file header for the
    // tradeoff. Pass the cookie cubemap path even in SPOT mode —
    // the engine ignores it for spotlights, but if the user toggles
    // back to cubemap mode the slot already has the path cached.
    float style = cvar("cl_flashlight_style");

    // PFLAGS_NOSHADOW skips shadow casting. Real shadows on a moving
    // dlight every frame are expensive; for SPOT the cone shadowmap
    // alone gives us reasonable occlusion in the cone, and for CUBE
    // the black cubemap faces mask out non-cone directions. If the
    // user wants proper light-blocking-by-walls occlusion, clear
    // PFLAGS_NOSHADOW and accept the per-frame cost.
    float h = dynamiclight_add(light_pos, radius, col, 0,
                               FLASHLIGHT_COOKIE_SHADER, PFLAGS_NOSHADOW);
    if (h >= 0)
    {
        // Orient the dlight: angles → axis basis (gl_rlight.c
        // PF_R_DynamicLight_Set lfield_angles). For SPOT this aims
        // the cone; for CUBE it picks which face of the cubemap is
        // "forward" — our +X face (flashlight_px.tga) is what the
        // engine samples in front of the camera.
        dynamiclight_set(h, LFIELD_ANGLES, view_ang);

        if (style == 0)
        {
            // Spotlight cone — fov in degrees (half-angle). Setting
            // any non-zero fov triggers LSHADER_SPOT in
            // gl_shadow.c:3760, which converts the omnidirectional
            // dlight into a true cone AND nulls out the cookie
            // cubemap (engine-side gl_backend.c:4305).
            float fov = cvar("cl_flashlight_fov");
            if (fov <= 0) fov = 35;
            dynamiclight_set(h, LFIELD_FOV, fov);
        }
        // style 1 (or any non-zero) — leave fov at 0 so the dlight
        // stays omnidirectional and the cubemap shapes the beam.
    }
};
