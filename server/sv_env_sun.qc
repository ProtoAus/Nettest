//
//  sv_env_sun.qc  -  env_sun  (point entity: the map's SUN DIRECTION)
//
//  Mapper places one env_sun to give the map a sun.  We push the sun
//  direction to each client on three cvars:
//    r_sun_dir                  direction TOWARD the sun (consumed by the QC
//                               shadow blend in cl_maplights.qc + blob skew)
//    r_shadows_throwdirection   the fake-shadow direction for r_shadows 2 =
//                               the NEGATED sun dir, so model shadows fall
//                               away from the sun
//    _map_sun_active            client-side "this map has a sun" truth flag
//
//  The crepuscular god-ray visuals this entity used to enable are REMOVED
//  (r_sun_colour stays 0): the engine's ray-mask pass redraws models through
//  a non-skeletal black shader, so skinned players show up as t-posing
//  silhouettes in the rays - unfixable at mod level.  env_sun survives purely
//  as the sun-direction source for the shadow system.
//
//  IMPORTANT: r_sun_colour is an ARCHIVED cvar, so a player whose config
//  saved a non-zero value from the god-ray era would get rays back without
//  the clear below.  EnvSun_StuffPlayer therefore ALWAYS stuffs it to black
//  (same "clear-first" pattern as the weather stuffer in sv_env_fog.qc);
//  nothing ever raises it again.
//
//  Delivered from PutClientInServer (once per connect - reliable for
//  fresh joiners) AND from EnvSun_StuffAll at spawn (covers the map-
//  cycle case where players are already present when env_sun spawns).
//
//  Keys (first one set wins):
//    "sundir"   explicit direction TOWARD the sun, "X Y Z".
//    "mangle"   "YAW PITCH ROLL" — IDENTICAL to worldspawn's ericw-tools "_sun_mangle", so you
//               type the SAME numbers here that the lightmap was baked with and the dynamic sun
//               lands in the same place.  See EnvSun_DirFromMangle for the exact conversion.
//    "angles"   treated EXACTLY like "mangle" (see below) — a sun has no other meaningful
//               facing, and agreeing with the lightmap is the entity's whole purpose.
//    (none)     the ericw LIGHT default sun, mangle "230 -65 0" → toward-sun
//               "0.271654 0.323744 0.906308" (azimuth 50°, elevation 65°).
//

// Mapper key - declared so the BSP entity-block parser populates it.
// (angles is an engine builtin.)
.vector sundir;
.float  sun_brightness;   // legacy god-ray key: unused, declared only so old maps don't warn
.vector shadowcolor;      // env_sun key: the RGB a fully-shadowed sun pixel is multiplied by (the
                          //   ambient/sky tint of a shadow). 0-1 (0.5 0.5 0.5 = neutral grey = default),
                          //   or 0-255 and we normalise. Drives r_shadows_color_r/g/b (defaultwall.glsl).

// Globals - set by env_sun spawn, read by EnvSun_StuffPlayer.
float  env_sun_active;
vector env_sun_dir;      // normalized direction toward the sun
vector env_sun_shadowcolor;      // the shadow tint to push (already normalised to 0-1)
float  env_sun_shadowcolor_set;  // 1 = the map set a custom tint; 0 = leave the neutral default

// ---------------------------------------------------------------------------
// mangle -> direction TOWARD the sun, using ericw-tools LIGHT's EXACT convention, so an
// env_sun "mangle"/"angles" of "230 -65 0" lands the dynamic sun where worldspawn's
// "_sun_mangle" "230 -65 0" baked the lightmap.  THREE things differ from Quake angles, and
// getting any of them wrong flips the sun (this was the bug — see below):
//   1. ORDER is "YAW PITCH ROLL", NOT Quake's "PITCH YAW ROLL".
//   2. Z uses +sin(pitch); Quake's AngleVectors/makevectors uses -sin(pitch).
//   3. The resulting vector is the direction the LIGHT TRAVELS, not the direction to the sun —
//      hence ericw's default "0 -90 0" => (0,0,-1) = straight DOWN = sun overhead.  Negate it.
// ericw light/entities.cc vec_from_mangle():
//      v = (cos(yaw)*cos(pitch), sin(yaw)*cos(pitch), sin(pitch))
// THE OLD BUG: this file did `makevectors(self.angles); env_sun_dir = v_forward;`, i.e. it read
// "230 -65 0" as pitch=230/yaw=-65 with -sin and no negation -> "-0.271654 0.582563 0.766045"
// (azimuth 115°, elevation 50°) instead of "0.271654 0.323744 0.906308" (azimuth 50°, elevation
// 65°) — a 65° azimuth error with a flipped X, so dynamic shadows disagreed with the baked
// lightmap.  That same wrong vector had been copied into every default (cfg/fgd/engine).
vector(vector m) EnvSun_DirFromMangle =
{
    float myaw   = m_x * 0.0174532925;   // m_x = YAW   (NOT pitch)
    float mpitch = m_y * 0.0174532925;   // m_y = PITCH
    // direction the sunlight TRAVELS (ericw vec_from_mangle)
    vector travel = [cos(myaw) * cos(mpitch), sin(myaw) * cos(mpitch), sin(mpitch)];
    if (travel == '0 0 0') return '0.271654 0.323744 0.906308';   // degenerate guard
    return normalize(travel * -1);                                 // -> TOWARD the sun
};

// Build the cvar-set command string from the cached sun state.
// r_sun_dir feeds the QC consumers (cl_maplights.qc sun weight/fallback,
// blob-shadow skew); it no longer drives any visual by itself since
// r_sun_colour is held at 0 (god rays removed).
string() EnvSun_BuildCommand =
{
    return sprintf("set r_sun_dir \"%f %f %f\"\n",
                   env_sun_dir_x, env_sun_dir_y, env_sun_dir_z);
};

// Separate builder: fteqcc DROPS sprintf varargs beyond 8 (see the progression-spine
// lesson), so a merged single-string version silently mangled the last component.
// _map_sun_active 1 = the CLIENT-side "this map has a sun" truth for the shadow code
// (cl_maplights.qc).  This also drives the FAKE-SHADOW throw direction (r_shadows 2):
// the engine's own -r_sun_dir fallback in Sh_GenerateFakeShadows is DEAD CODE because
// r_shadows_throwdirection defaults to "0 0 -1" (non-empty string wins, gl_shadow.c) -
// so we stuff the negated sun dir explicitly.  Throw dir = the direction the light
// TRAVELS = away from the sun; the ortho shadowmap then gives height-proportional
// offset + skewed silhouettes for free.
string() EnvSun_BuildShadowDirCommand =
{
    return sprintf("set r_shadows_throwdirection \"%f %f %f\";set _map_sun_active 1\n",
                   0 - env_sun_dir_x, 0 - env_sun_dir_y, 0 - env_sun_dir_z);
};

// Push the shadow TINT (r_shadows_color_r/g/b, cvardf in defaultwall.glsl).  These are
// CVAR_SHADERSYSTEM, so the `set` auto-flushes the shader (cvar.c Shader_NeedReload) - no
// vid_reload needed.  4 args (format + 3 floats) is well under fteqcc's 8-vararg sprintf limit.
string() EnvSun_BuildShadowColorCommand =
{
    return sprintf("set r_shadows_color_r %f;set r_shadows_color_g %f;set r_shadows_color_b %f\n",
                   env_sun_shadowcolor_x, env_sun_shadowcolor_y, env_sun_shadowcolor_z);
};

// Push the sun config to one client.  ALWAYS clears r_sun_colour first
// (archived cvar, no map-load reset - see header; rays must stay dead).
// r_sun_dir + r_shadows_throwdirection get the same clear-first treatment: reset to
// an ANGLED default sun on every map (not straight down) so a sunless map doesn't keep
// the previous map's tilted fake shadows (stuffed `set` persists for the session).  The
// default matches the ericw-tools LIGHT sun that bakes the lightmap (worldspawn
// "_sun_mangle" "230 -65 0" -> toward-sun "0.271654 0.323744 0.906308"), so dynamic
// shadows fall the same way as the baked static lighting; throw = the negated toward-sun.
// (A top-down sun grazed vertical walls -> coplanar func_ brushes shimmered; the tilt fixes it.)
void(entity p) EnvSun_StuffPlayer =
{
    if (!p || bot_adding || clienttype(p) != CLIENTTYPE_REAL) return;	// bots have no netchan (engine-truth guard; bot_adding covers the spawnclient window)
    stuffcmd(p, "set r_sun_colour \"0 0 0\";set r_sun_dir \"0.271654 0.323744 0.906308\";set r_shadows_throwdirection \"-0.271654 -0.323744 -0.906308\";set _map_sun_active 0\n");   // rays dead + ericw default sun (_sun_mangle "230 -65 0") + no env_sun this map
    // Clear-first the shadow tint too (stuffed `set`s persist for the session, so a previous map's
    // tint would otherwise carry over).  0.5 grey = the neutral, pre-tint look.
    stuffcmd(p, "set r_shadows_color_r 0.5;set r_shadows_color_g 0.5;set r_shadows_color_b 0.5\n");
    if (!env_sun_active) return;
    stuffcmd(p, EnvSun_BuildCommand());            // sun dir for the QC shadow consumers
    stuffcmd(p, EnvSun_BuildShadowDirCommand());   // fake shadows (r_shadows 2) fall away from it
    if (env_sun_shadowcolor_set)
        stuffcmd(p, EnvSun_BuildShadowColorCommand()); // ambient/sky tint of the shadows
};

// Push to every currently-connected player (map-cycle case).
void() EnvSun_StuffAll =
{
    entity p = find(world, classname, "player");
    while (p)
    {
        EnvSun_StuffPlayer(p);
        p = find(p, classname, "player");
    }
};

/*QUAKED env_sun (.9 .9 .3) (-8 -8 -8) (8 8 8)
Defines the map's sun DIRECTION: fake model shadows (r_shadows 2) fall away
from it, and the QC shadow/blob code weights toward it.  No visual by itself
(the crepuscular god-ray effect was removed).

"mangle"  "YAW PITCH ROLL" — the SAME convention + numbers as worldspawn's ericw "_sun_mangle",
          so the dynamic sun matches the baked lightmap.  Default "230 -65 0".
"angles"  read exactly like "mangle" (a sun has no other meaningful facing).
"sundir"  explicit toward-the-sun vector "X Y Z"; overrides mangle/angles if set.
"shadowcolor" the RGB tint of a fully-shadowed sun pixel (r_shadows 2) — set it to the map's
          ambient/sky colour so shadows sink toward that instead of dead grey.  "0.5 0.5 0.5" =
          neutral (default).  Accepts 0-1 ("0.35 0.4 0.6") OR 0-255 ("90 102 153"); lower = darker.
*/
void() env_sun =
{
    env_sun_active = 1;

    // Direction toward the sun.  Explicit sundir wins; else mangle/angles (BOTH read with the
    // ericw "_sun_mangle" convention so the mapper types the SAME numbers as worldspawn); else
    // the ericw LIGHT default sun.
    if (self.sundir != '0 0 0')
        env_sun_dir = normalize(self.sundir);
    else if (self.mangle != '0 0 0')
        env_sun_dir = EnvSun_DirFromMangle(self.mangle);
    else if (self.angles != '0 0 0')
        env_sun_dir = EnvSun_DirFromMangle(self.angles);   // same convention as mangle — see the helper
    else
        env_sun_dir = '0.271654 0.323744 0.906308';   // ericw LIGHT default sun (_sun_mangle "230 -65 0")

    // Optional shadow TINT.  Forgiving on range: values >1 are read as 0-255 (Quake light-colour
    // convention) and normalised, so the mapper can type "90 100 150" OR "0.35 0.4 0.6".
    if (self.shadowcolor != '0 0 0')
    {
        env_sun_shadowcolor = self.shadowcolor;
        if (env_sun_shadowcolor_x > 1 || env_sun_shadowcolor_y > 1 || env_sun_shadowcolor_z > 1)
            env_sun_shadowcolor = env_sun_shadowcolor * (1 / 255);
        env_sun_shadowcolor_set = 1;
    }
    else
        env_sun_shadowcolor_set = 0;

    EnvSun_StuffAll();

    // No further runtime role; keep the entity for possible future use-chains.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
