//
//  sv_infodecal.qc  –  infodecal  (GoldSrc point entity)
//
//  Projects a decal texture onto the nearest world brush face.  The `texture`
//  key is a {-prefixed name from a mounted decals.wad (e.g. {gratedecal).  At
//  spawn we trace a few units in the 6 axis directions to find the surface the
//  mapper placed it against, then network the traced point + normal + texture
//  to EVERY client (PVSF_IGNOREPVS|NOREMOVE, so late joiners get it too) via a
//  CSQC SendEntity.  The client (cl_infodecal.qc) places it ONCE; r_decal_renderer
//  selects the renderer (1 = surface-clipped tri-soup, default; 0 = engine adddecal).
//
//  Keys (GoldSrc parity, compatibility not bug-for-bug):
//    "texture"     decal material name ({gratedecal). Required.
//    "targetname"  name it -> starts hidden, drawn when first triggered.
//
//  `angles` is intentionally unused (GoldSrc orients the decal from the face,
//  not the entity) — the client builds the frame from the surface normal.
//

.vector id_pos;     // traced surface point
.vector id_norm;    // traced surface normal
.float  id_visible; // 1 = client should draw it
.float  id_found;   // nearest-hit distance (large = nothing found)

// GoldSrc render keys (FTE auto-parses the matching spawn keys into these fields;
// same names/types the brush entities use, so the decls dedup across files).
//   rendermode  0..5  — blend (client: 4=solid alpha-test, 3/5=additive, else alpha)
//   renderamt   0..255 — opacity (client: amt/255; 0/unset -> opaque)
//   rendercolor R G B  — tint (client: /255 when non-zero, else surface light)
//   renderfx    0..16  — animation enum (networked + stored client-side; deferred)
.float  rendermode;
.float  renderamt;
.vector rendercolor;
.float  renderfx;

const float SF_INFODECAL_START_HIDDEN = 1;
const float INFODECAL_RANGE = 8;    // half-length of the search line through the origin (each axis).
                                    // The NEAREST surface wins, so a decal flush on a wall lands on the
                                    // WALL (distance ~0) not a floor several units away.

float(entity to, float fl) infodecal_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_INFODECAL);
    WriteCoord(MSG_ENTITY, self.id_pos_x);
    WriteCoord(MSG_ENTITY, self.id_pos_y);
    WriteCoord(MSG_ENTITY, self.id_pos_z);
    WriteCoord(MSG_ENTITY, self.id_norm_x);
    WriteCoord(MSG_ENTITY, self.id_norm_y);
    WriteCoord(MSG_ENTITY, self.id_norm_z);
    WriteByte(MSG_ENTITY, self.id_visible);
    WriteCoord(MSG_ENTITY, self.scale);     // per-entity size multiplier (1.0 = default)
    WriteString(MSG_ENTITY, self.texture);
    // GoldSrc render keys (read in the same order by cl_infodecal.qc).
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendermode),   16));
    WriteByte(MSG_ENTITY, bound(0, rint(self.renderamt),   255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_x), 255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_y), 255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_z), 255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.renderfx),     16));
    return TRUE;
};

// Trace a line ALONG this axis THROUGH the origin (from the far side back across it) and
// keep the nearest surface hit.  A line through the origin — NOT a ray FROM it — is what
// lets a decal placed FLUSH ON (or a hair inside) a wall still find that wall: a ray that
// starts on/in the surface is start-solid and finds nothing, which is why a flush decal
// was either removed ("no surface") or fell through to the floor.  The open (room) side of
// the line gives a clean, non-start-solid hit right at the wall.
void(vector dir) InfoDecal_TryDir =
{
    traceline(self.origin - dir * INFODECAL_RANGE,
              self.origin + dir * INFODECAL_RANGE, MOVE_NOMONSTERS, self);
    if (trace_startsolid || trace_fraction >= 1 || trace_plane_normal == '0 0 0')
        return;
    float d = vlen(trace_endpos - self.origin);
    if (d < self.id_found)
    {
        self.id_found = d;
        self.id_pos   = trace_endpos;
        self.id_norm  = trace_plane_normal;
    }
};

// Named decal triggered -> reveal it (GoldSrc: appears once, never hides again).
void() infodecal_use =
{
    if (self.id_visible)
        return;
    self.id_visible = 1;
    self.SendFlags  = 1;    // re-network so every client draws it now
};

/*QUAKED infodecal (.6 .5 .8) (-4 -4 -4) (4 4 4) START_HIDDEN
GoldSrc-style decal projector — paints "texture" on the nearest brush face.
"texture"     decal material name from a mounted decals.wad ({gratedecal).
"targetname"  name it to start hidden + appear when first triggered.
*/
void() infodecal =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;

    if (!self.texture || self.texture == "")
    {
        dprint("infodecal: no 'texture' key, removing\n");
        remove(self);
        return;
    }

    if (self.scale == 0)
        self.scale = 1.0;   // map "scale" key auto-parses into the engine .scale field; 0 = default

    // Find the host face (nearest hit across the 6 axis directions).
    self.id_found = INFODECAL_RANGE + 1;   // "nothing found" sentinel
    InfoDecal_TryDir('1 0 0');  InfoDecal_TryDir('-1 0 0');
    InfoDecal_TryDir('0 1 0');  InfoDecal_TryDir('0 -1 0');
    InfoDecal_TryDir('0 0 1');  InfoDecal_TryDir('0 0 -1');

    if (self.id_found > INFODECAL_RANGE)
    {
        dprint(sprintf("infodecal '%s': no surface within %g units, removing\n",
                       self.texture, INFODECAL_RANGE));
        remove(self);
        return;
    }

    // Named decals start hidden until triggered; unnamed are drawn immediately.
    if (self.targetname != "" || (self.spawnflags & SF_INFODECAL_START_HIDDEN))
    {
        self.id_visible = 0;
        self.use = infodecal_use;
    }
    else
        self.id_visible = 1;

    // Sent to every client once (incl. late joiners) — the decal is map state,
    // not a PVS-gated visible entity. NOREMOVE so a viewer leaving PVS keeps it.
    self.pvsflags   = PVSF_IGNOREPVS | PVSF_NOREMOVE;
    self.SendEntity = infodecal_SendEntity;
    self.SendFlags  = 1;
};
