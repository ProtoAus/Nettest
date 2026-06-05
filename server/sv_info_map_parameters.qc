//
//  sv_info_map_parameters.qc  –  info_map_parameters  (HL/CS bomb-defusal point entity)
//
//  Per-map override for C4 (cfc4) explosion radius.  Mapper places
//  one info_map_parameters with a `bombradius` key; we cache the
//  value in a server-VM global that C4_PlantedDetonate reads instead
//  of the hardcoded CFC4_RADIUS const.  No entity → fall back to the
//  weapon's compile-time default.
//
//  Multiple info_map_parameters: last spawn wins.  HL convention is
//  one per map.
//
//  Keys (per HL FGD):
//    "bombradius"  C4 blast radius in qu, clamped 100..2048.
//                   Default 500 if unset.
//

// `map_c4_radius` global is declared in sh_wpn_cfc4.qc (which
// compiles before this file in sv_progs.src) so C4_PlantedDetonate
// can read it directly.  Just assign here — no redeclaration.
float map_c4_radius;        // matches the prior decl, shares storage

// Mapper key — declared so the BSP entity-block parser populates it
// on the spawn entity.
.float bombradius;

/*QUAKED info_map_parameters (.5 .5 0) (-8 -8 -8) (8 8 8)
HL/CS bomb-defusal map parameter override.  Currently scoped to C4
explosion radius; future expansions (team-buy gates etc.) plug into
the same entity.

"bombradius"  C4 blast radius in qu (100..2048, default 500).
*/
void() info_map_parameters =
{
    float r = self.bombradius;
    if (r <= 0)    r = 500;
    if (r > 2048)  r = 2048;
    if (r < 100)   r = 100;
    map_c4_radius = r;

    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
