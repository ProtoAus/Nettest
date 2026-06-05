//
//  sv_env_fog.qc  –  env_fog  (point entity, sets FTE engine fog)
//
//  Mapper places one env_fog with `density` and `rendercolor` keys.
//  At map load (or whenever the entity spawns) we stuff each
//  connected client with FTE's `fog <density> <r> <g> <b>` console
//  command, which the engine applies to that client's renderer.
//
//  Re-stuffed on every PutClientInServer so a player joining
//  mid-map, respawning, or rejoining gets the fog re-applied —
//  the engine's fog state can otherwise drift back to defaults
//  on map reload or full reconnect.
//
//  Multiple env_fog entities: last-spawn wins.  HL convention is
//  one per map.
//
//  Keys:
//    "density"     fog density (FTE convention: 0..0.1 typical, larger = thicker)
//    "rendercolor" RGB 0..255 each component (HL "FX Color" key)
//

// Mapper key — declared so the BSP entity-block parser populates it.
.float density;

// Globals — set by env_fog spawn, read by PutClientInServer hook.
float  env_fog_active;
float  env_fog_density;
vector env_fog_color;     // 0..1 each component (already converted from rendercolor)

// Build the FTE console command string from the cached fog state.
// Color is in 0..1 floats; FTE's `fog` command takes that range.
string() EnvFog_BuildCommand =
{
    return sprintf("fog %f %f %f %f\n",
                   env_fog_density,
                   env_fog_color_x,
                   env_fog_color_y,
                   env_fog_color_z);
};

// Send the active fog config to one client.  Called from
// PutClientInServer for every spawn so respawns / map-cycle re-fires
// re-apply the fog.  No-ops if no env_fog has spawned this map.
void(entity p) EnvFog_StuffPlayer =
{
    if (!env_fog_active) return;
    if (!p) return;
    stuffcmd(p, EnvFog_BuildCommand());
};

// Push the current fog config to every currently-connected player.
// Called when env_fog spawns (covers maps where env_fog isn't the
// first entity processed and the worldspawn-time players are
// already ready).
void() EnvFog_StuffAll =
{
    entity p = find(world, classname, "player");
    while (p)
    {
        EnvFog_StuffPlayer(p);
        p = find(p, classname, "player");
    }
};

// Stuff cl_rain / cl_snow tunables when worldspawn carries rain/snow
// keys. Co-located with env_fog so the per-player atmospheric-state
// stuff calls live in one place.
//   "rain" value format: "A R G B I"
//       A = cl_rain_alpha, R G B = cl_rain_color, I = cl_rain_intensity.
//   "snow" presence alone forces cl_snow 1 (CSQC_Rain_Tick OR-gates
//       cl_rain || cl_snow, so snow no longer needs to ride cl_rain).
void(entity p) SV_WeatherStuffPlayer =
{
    if (!p) return;
    // Always clear first so a map without weather keys doesn't inherit
    // the previous map's cl_rain / cl_snow state.
    stuffcmd(p, "set cl_rain 0;set cl_snow 0\n");
    if (sv_worldspawn_rain != "")
    {
        float n = tokenize(sv_worldspawn_rain);
        if (n >= 5)
        {
            stuffcmd(p, sprintf(
                "set cl_rain_alpha %s;set cl_rain_color \"%s %s %s\";set cl_rain_intensity %s;set cl_rain 1\n",
                argv(0), argv(1), argv(2), argv(3), argv(4)));
        }
        else
        {
            stuffcmd(p, "set cl_rain 1\n");
        }
    }
    if (sv_worldspawn_snow != "")
        stuffcmd(p, "set cl_snow 1\n");
};

/*QUAKED env_fog (.5 .5 0) (-8 -8 -8) (8 8 8)
Sets engine fog for all players.

"density"     fog density (0..1, FTE typical 0.005..0.05)
"rendercolor" RGB color "R G B" with each component 0..255
*/
void() env_fog =
{
    env_fog_active  = 1;
    // GoldSrc env_fog density values are tuned for that engine's
    // exponential-fog formula; FTE's `fog` command needs a much
    // larger coefficient to produce the same visible thickness.
    // Multiply by 100 so a HL map's "density 0.001" reads as the
    // expected thin-fog look here instead of being barely visible.
    env_fog_density = self.density * 100;
    // rendercolor is mapper-set in 0..255 byte range; convert to 0..1
    // floats for FTE's fog command.
    env_fog_color   = self.rendercolor / 255;
    EnvFog_StuffAll();
    // The entity itself has no further runtime role, but we keep it
    // around so a future trigger / use-chain can query / re-fire it.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
