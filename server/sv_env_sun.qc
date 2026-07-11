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
//  Keys:
//    "sundir"   direction toward the sun, "X Y Z" (engine default "0.2 0.5 0.8").
//               If unset, derived from the entity's "angles" (aim it at the sun).
//

// Mapper key - declared so the BSP entity-block parser populates it.
// (angles is an engine builtin.)
.vector sundir;
.float  sun_brightness;   // legacy god-ray key: unused, declared only so old maps don't warn

// Globals - set by env_sun spawn, read by EnvSun_StuffPlayer.
float  env_sun_active;
vector env_sun_dir;      // normalized direction toward the sun

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

// Push the sun config to one client.  ALWAYS clears r_sun_colour first
// (archived cvar, no map-load reset - see header; rays must stay dead).
// r_shadows_throwdirection gets the same clear-first treatment: reset to the
// engine-default straight-down on every map so a sunless map doesn't keep the
// previous map's tilted fake shadows (stuffed `set` persists for the session).
void(entity p) EnvSun_StuffPlayer =
{
    if (!p || bot_adding || clienttype(p) != CLIENTTYPE_REAL) return;	// bots have no netchan (engine-truth guard; bot_adding covers the spawnclient window)
    stuffcmd(p, "set r_sun_colour \"0 0 0\";set r_shadows_throwdirection \"0 0 -1\";set _map_sun_active 0\n");   // rays dead + shadows top-down + no sun by default this map
    if (!env_sun_active) return;
    stuffcmd(p, EnvSun_BuildCommand());            // sun dir for the QC shadow consumers
    stuffcmd(p, EnvSun_BuildShadowDirCommand());   // fake shadows (r_shadows 2) fall away from it
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

"sundir"  direction toward the sun "X Y Z" (default "0.2 0.5 0.8"); else from "angles"
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

    EnvSun_StuffAll();

    // No further runtime role; keep the entity for possible future use-chains.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
