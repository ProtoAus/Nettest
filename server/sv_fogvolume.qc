//
//  sv_fogvolume.qc  –  func_fogvolume  (bounded fog region, FTE Q1)
//
//  A brush entity that marks a volume of engine fog.  The CLIENT engine reads
//  this brush's inline-submodel bbox straight from the BSP entity lump at map
//  load and builds the fog volume there (Mod_LoadQ1FogVolumes, ENGINE_PATCHES
//  Patch 77) — it does NOT depend on this server entity at all.  So server-side
//  there is nothing to do except exist as a spawn function (otherwise the server
//  logs "Couldn't find spawn function for func_fogvolume") and get out of the way:
//  the volume is a fog region you walk THROUGH, never solid or rendered.
//
//  Mapper: make a brush (invisible/skip texture) a func_fogvolume, then set:
//    "rendercolor"  fog colour "R G B", each 0..255   (read by the engine)
//    "fogdist"      fog distance in units (denser = smaller, e.g. 384)
//  Both keys are consumed by the ENGINE at map load, not here.
//
void() func_fogvolume =
{
    remove(self);   // client renders the fog from the BSP lump; server has no role
};
