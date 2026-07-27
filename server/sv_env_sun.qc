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
.vector shadowcolor;      // env_sun key: MANUAL override of the RGB a fully-shadowed sun pixel is multiplied
                          //   by. 0-1 (0.5 0.5 0.5 = neutral grey), or 0-255 and we normalise. Wins over the
                          //   auto calc below. Drives r_shadows_color_r/g/b (defaultwall.glsl).
// AUTO shadow-tint inputs: copy the SAME values you gave the light compiler (worldspawn _sunlight* keys —
// the engine hides underscore keys from QC, so they're duplicated here). When set, the shadow tint is
// COMPUTED as sky/(sky+sun) per channel — see EnvSun_ShadowMul — instead of typed by hand.
.float  sunlight;         // env_sun: direct sun brightness   (copy worldspawn _sunlight)
.vector suncolor;         // env_sun: direct sun colour        (copy _sunlight_color; 0-255 or 0-1)
.float  skylight;         // env_sun: sky/ambient brightness   (copy _sunlight2)
.vector skycolor;         // env_sun: sky/ambient colour       (copy _sunlight2_color; 0-255 or 0-1)
.float  shadowdarken;     // env_sun: optional extra darkening of the COMPUTED tint (1=physical/blends with
                          //   the bake; <1 = punchier but darker than the baked shadows next to it). 0=unset=1.

// Globals - set by env_sun spawn, read by EnvSun_StuffPlayer.
float  env_sun_active;
vector env_sun_dir;      // normalized direction toward the sun
vector env_sun_shadowcolor;      // the shadow tint to push (already normalised to 0-1)
float  env_sun_shadowcolor_set;  // 1 = the map set a custom tint; 0 = leave the neutral default
float  env_sun_brightness;       // the map's sun brightness (env_sun "sunlight" key = worldspawn _sunlight);
                                 //   0 = key absent -> don't push, client keeps its r_shadows_sunbrightness
                                 //   default.  Drives the SUNLIT-washout of lamp shadows (the engine compares
                                 //   it against each lamp's `light` value -- same units -- so a lamp brighter
                                 //   than the sun keeps its shadow on sunlit ground, a weak one loses it).

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

// Physical shadow tint from the map's sun + sky ambient (the SAME values the light compiler baked with):
// a fully-shadowed sun pixel is lit by the SKY ambient only; a sunlit one by sky + sun.  The shader
// MULTIPLIES a sunlit surface by this to make it read as shadowed, so the correct multiplier is
//     mul = skyRadiance / (skyRadiance + sunRadiance)   per channel
// which lands the dynamic shadow at exactly the brightness AND hue the BAKED shadows already sit at
// (they are sky-lit too) — that is what makes the dynamic and baked shadows blend instead of the dynamic
// one being a random tint.  WHY the user's "type the sky colour as shadowcolor" looked wrong: shadowcolor
// is a raw MULTIPLIER, so 200 200 255 -> (0.78,0.78,1.0) barely darkens and turns blue; the ratio below
// is the physically-meaningful value.  NOTE if the sky ambient is strong vs the sun (e.g. _sunlight2 600
// vs _sunlight 250) the shadows are GENUINELY bright — that is the lighting, not a bug; use shadowdarken
// to force them darker at the cost of matching the bake.
// Colours accept 0-255 (Quake convention) or 0-1; unset (0 0 0) = white.
vector(float sunb, vector sunc, float skyb, vector skyc) EnvSun_ShadowMul =
{
    if (sunc == '0 0 0') sunc = '1 1 1';
    if (skyc == '0 0 0') skyc = '1 1 1';
    if (sunc_x > 1 || sunc_y > 1 || sunc_z > 1) sunc = sunc * (1 / 255);
    if (skyc_x > 1 || skyc_y > 1 || skyc_z > 1) skyc = skyc * (1 / 255);
    vector sunr = sunb * sunc;   // sun radiance per channel
    vector skyr = skyb * skyc;   // sky/ambient radiance per channel
    // A real baked shadow does NOT keep the full sky: whatever casts it also occludes the slice of sky AROUND
    // the sun, so the baked shadow sits a touch darker than the ideal sky/(sky+sun) ratio.  Keep ~85% of the
    // sky to match -- otherwise the DYNAMIC shadow reads slightly too BRIGHT next to the baked ones.  (Colour
    // is preserved, just dimmer; use shadowdarken for further taste.)
    skyr = skyr * 0.85;
    vector mul = '1 1 1';
    if (skyr_x + sunr_x > 0.0001) mul_x = skyr_x / (skyr_x + sunr_x);
    if (skyr_y + sunr_y > 0.0001) mul_y = skyr_y / (skyr_y + sunr_y);
    if (skyr_z + sunr_z > 0.0001) mul_z = skyr_z / (skyr_z + sunr_z);
    // never pitch black: a real shadow is lit by SOME sky/bounce, and a near-zero result usually means a
    // mis-entered value (sky far below sun).  Floor each channel so the shadow can't crush to pure black.
    if (mul_x < 0.12) mul_x = 0.12;
    if (mul_y < 0.12) mul_y = 0.12;
    if (mul_z < 0.12) mul_z = 0.12;
    return mul;
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

// Push the sun BRIGHTNESS (r_shadows_sunbrightness, plain engine cvar - no shader flush involved,
// the engine reads it per frame when building the lamp-shadow atlas).  The engine compares it to each
// lamp's `light` value to decide how much SUNLIT ground washes that lamp's shadow out.
string() EnvSun_BuildSunBrightnessCommand =
{
    return sprintf("set r_shadows_sunbrightness %f\n", env_sun_brightness);
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
    // NB the shadow TINT (r_shadows_color_*) is deliberately NOT cleared here.  This fn runs from
    // PutClientInServer = EVERY RESPAWN, and a clear-first would wipe any value the player set in the
    // console the instant they died -> "I set it but it reads 0.5 again".  So we only ever PUSH a tint
    // (below), and only when the map's env_sun actually carries a shadowcolor key; otherwise the client
    // keeps whatever it has (its 0.5 cvardf default on a fresh client, or the player's own console value).
    // Cost: a keyed map A followed by a keyless map B keeps A's tint until B sets its own key or the
    // player resets it -- an acceptable trade for letting console experiments survive a respawn.
    if (!env_sun_active) return;
    stuffcmd(p, EnvSun_BuildCommand());            // sun dir for the QC shadow consumers
    stuffcmd(p, EnvSun_BuildShadowDirCommand());   // fake shadows (r_shadows 2) fall away from it
    if (env_sun_shadowcolor_set)
        stuffcmd(p, EnvSun_BuildShadowColorCommand()); // ambient/sky tint of the shadows (map opted in)
    if (env_sun_brightness > 0)
        stuffcmd(p, EnvSun_BuildSunBrightnessCommand()); // sun brightness for the lamp-shadow sunlit washout
                                                         // (push-only, same trade as the tint NB above)
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
"shadowcolor" MANUAL RGB multiplier for a fully-shadowed sun pixel (r_shadows 2).  "0.5 0.5 0.5" =
          neutral grey (default).  Accepts 0-1 ("0.35 0.4 0.6") OR 0-255 ("90 102 153"); lower = darker.
          NOTE this is a raw multiplier, so typing your sky COLOUR here (e.g. "200 200 255") barely
          darkens and tints blue — for a shadow that matches the bake, prefer the auto keys below.
--- AUTO shadow tint (recommended): copy the SAME values you gave the light compiler and the shadow
    colour is COMPUTED as sky/(sky+sun) so dynamic shadows sit at the baked shadows' brightness+hue ---
"sunlight"  direct sun brightness   — copy worldspawn _sunlight        (e.g. 250)
"suncolor"  direct sun colour        — copy _sunlight_color             (e.g. "255 230 160"; 0-255 or 0-1)
"skylight"  sky/ambient brightness   — copy _sunlight2                  (e.g. 600)
"skycolor"  sky/ambient colour       — copy _sunlight2_color            (e.g. "200 200 255")
"shadowdarken" optional extra darkening of the computed tint.  1 = physical (blends with the bake);
          <1 = punchier but darker than the baked shadows beside it.  Leave unset for physical.
          (If your shadows come out bright, it's because your sky ambient is strong vs the sun — that's
           the lighting; lower shadowdarken to force them darker.)
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

    // Shadow TINT.  Precedence: (1) an explicit shadowcolor is a MANUAL raw multiplier and wins; (2) else
    // if the map gave us its sun/sky light values, COMPUTE the physical tint = sky/(sky+sun) so dynamic
    // shadows match the baked ones; (3) else leave the neutral default.
    if (self.shadowcolor != '0 0 0')
    {
        // manual override.  Forgiving on range: >1 is read as 0-255 and normalised ("90 100 150" or "0.35 0.4 0.6").
        env_sun_shadowcolor = self.shadowcolor;
        if (env_sun_shadowcolor_x > 1 || env_sun_shadowcolor_y > 1 || env_sun_shadowcolor_z > 1)
            env_sun_shadowcolor = env_sun_shadowcolor * (1 / 255);
        env_sun_shadowcolor_set = 1;
    }
    else if (self.sunlight > 0 && self.skylight > 0)
    {
        // auto: derive the shadow tint from the bake's sun + sky ambient (see EnvSun_ShadowMul).  BOTH are
        // required -- sunlight alone gives sky/(sky+sun)=0 (pitch black) and skylight alone gives 1 (no
        // shadow); a half-config falls through to the neutral default instead of producing a broken tint.
        env_sun_shadowcolor = EnvSun_ShadowMul(self.sunlight, self.suncolor, self.skylight, self.skycolor);
        float dk = self.shadowdarken;
        if (dk <= 0) dk = 1;   // 0 = unset field -> physical (no extra darkening)
        env_sun_shadowcolor = env_sun_shadowcolor * dk;
        env_sun_shadowcolor_set = 1;
    }
    else
        env_sun_shadowcolor_set = 0;

    // Sun brightness for the lamp-shadow SUNLIT washout (engine r_shadows_sunbrightness).  Reuses the
    // same "sunlight" key the auto-tint reads (copy worldspawn _sunlight) but needs only that one key.
    if (self.sunlight > 0)
        env_sun_brightness = self.sunlight;

    EnvSun_StuffAll();

    // No further runtime role; keep the entity for possible future use-chains.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
