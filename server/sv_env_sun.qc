//
//  sv_env_sun.qc  –  env_sun  (point entity, enables FTE crepuscular "god rays")
//
//  Mapper places one env_sun.  We push the engine's sun cvars to each
//  client:  r_sun_dir  (direction TOWARD the sun) and  r_sun_colour
//  (ray colour/brightness).  With a non-zero r_sun_colour the engine
//  renders crepuscular light shafts wherever SKY surfaces are visible
//  (gl_shadow.c Sh_DrawCrepuscularLight, sun path).  No sky in view =>
//  no rays; that's an engine constraint, not a bug.
//
//  IMPORTANT: r_sun_colour is an ARCHIVED cvar and is NOT reset on map
//  load, so a map WITHOUT an env_sun must actively switch the rays OFF
//  or they'd linger from a previously-played map.  EnvSun_StuffPlayer
//  therefore ALWAYS clears r_sun_colour first, then re-enables it only
//  when this map has an env_sun (same "clear-first" pattern as the
//  weather stuffer in sv_env_fog.qc).
//
//  Delivered from PutClientInServer (once per connect — reliable for
//  fresh joiners) AND from EnvSun_StuffAll at spawn (covers the map-
//  cycle case where players are already present when env_sun spawns).
//
//  Keys:
//    "sundir"        direction toward the sun, "X Y Z" (engine default "0.2 0.5 0.8").
//                    If unset, derived from the entity's "angles" (aim it at the sun).
//    "rendercolor"   ray colour, RGB 0..255 each (HL "FX Color" key).  Black => white.
//    "sun_brightness" brightness multiplier on rendercolor (default 1; >1 = HDR-bright rays).
//

// Mapper keys — declared so the BSP entity-block parser populates them.
// (rendercolor + angles are declared elsewhere / are engine builtins.)
.vector sundir;
.float  sun_brightness;

// Globals — set by env_sun spawn, read by EnvSun_StuffPlayer.
float  env_sun_active;
vector env_sun_dir;      // normalized direction toward the sun
vector env_sun_colour;   // 0..1+ per component (rendercolor/255 * brightness)

// Build the cvar-set command string from the cached sun state.
string() EnvSun_BuildCommand =
{
    return sprintf("set r_sun_dir \"%f %f %f\";set r_sun_colour \"%f %f %f\"\n",
                   env_sun_dir_x, env_sun_dir_y, env_sun_dir_z,
                   env_sun_colour_x, env_sun_colour_y, env_sun_colour_z);
};

// Push the sun config to one client.  ALWAYS clears r_sun_colour first
// (archived cvar, no map-load reset), then re-enables when active.
void(entity p) EnvSun_StuffPlayer =
{
    if (!p || bot_adding || clienttype(p) != CLIENTTYPE_REAL) return;	// bots have no netchan (engine-truth guard; bot_adding covers the spawnclient window)
    stuffcmd(p, "set r_sun_colour \"0 0 0\"\n");   // rays OFF by default this map
    if (!env_sun_active) return;
    stuffcmd(p, EnvSun_BuildCommand());            // ...on if this map has an env_sun
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
Enables FTE crepuscular "god rays" from the sky for all players.
Requires visible sky surfaces in view to render (engine sun path).

"sundir"         direction toward the sun "X Y Z" (default "0.2 0.5 0.8"); else from "angles"
"rendercolor"    ray colour "R G B", each 0..255 (black => white)
"sun_brightness" brightness multiplier (default 1; >1 = brighter/HDR rays)
*/
void() env_sun =
{
    env_sun_active = 1;

    // Direction toward the sun.  Prefer an explicit sundir; else aim via the
    // entity's angles; else the engine's default up-ish direction.
    if (self.sundir != '0 0 0')
        env_sun_dir = normalize(self.sundir);
    else if (self.angles != '0 0 0')
    {
        makevectors(self.angles);
        env_sun_dir = v_forward;
    }
    else
        env_sun_dir = normalize('0.2 0.5 0.8');

    // Colour/brightness.  rendercolor is 0..255; sun_brightness scales it
    // (values >1 push the rays HDR-bright).  Black rendercolor => white.
    float inten = self.sun_brightness;
    if (inten <= 0) inten = 1;
    env_sun_colour = (self.rendercolor / 255) * inten;
    if (env_sun_colour == '0 0 0')
        env_sun_colour = '1 1 1' * inten;

    EnvSun_StuffAll();

    // No further runtime role; keep the entity for possible future use-chains.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
