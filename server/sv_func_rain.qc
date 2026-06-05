//
// sv_func_rain.qc — brush volume that constrains cl_rain's drops to
// the volume's XY footprint instead of the default cylinder around
// the viewer.  Server only replicates the bbox + on/off state; CSQC
// (cl_rain.qc) tracks the list and picks random spawn points inside
// active volumes.
//
// Mapper places one or more brush volumes covering the area that
// should be raining (e.g. "outside the train cab") and ties the
// entity to func_rain.  cl_rain 1 then only spawns drops inside
// those volumes — the cylinder behaviour is the fallback when no
// volume is in PVS.
//
// Render is purely client-side; the brush isn't drawn, just used as
// an AABB.  Triggering the entity toggles its active state — letting
// a multi_manager / trigger_relay enable / disable per-region rain.
//

const float FUNC_RAIN_START_OFF = 1;   // spawnflag bit 0 — inactive on spawn

void() func_rain_use =
{
    self.frame = self.frame ? 0 : 1;   // toggle active flag (sent in .frame byte)
    self.SendFlags = 1;
};

float(entity p, float changedflags) func_rain_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_FUNC_RAIN);
    WriteCoord(MSG_ENTITY, self.absmin_x);
    WriteCoord(MSG_ENTITY, self.absmin_y);
    WriteCoord(MSG_ENTITY, self.absmin_z);
    WriteCoord(MSG_ENTITY, self.absmax_x);
    WriteCoord(MSG_ENTITY, self.absmax_y);
    WriteCoord(MSG_ENTITY, self.absmax_z);
    WriteByte(MSG_ENTITY, self.frame ? 1 : 0);
    return TRUE;
};

/*QUAKED func_rain (.4 .6 .9) ? START_OFF
Brush volume that constrains cl_rain effects to its bounding box.
Mappers place the brush over the area that should be rainy (typically
"outside" a covered area).  cl_rain 1 spawns drops only inside any
active func_rain volume in PVS; with no volumes, cl_rain falls back
to a cylinder around the viewer.

Use this entity via trigger / multi_manager to toggle the rain
on/off — handy for indoor / outdoor cinematics.

"targetname"  if set, can be triggered to toggle on/off
START_OFF     entity spawns inactive (trigger to enable)
*/
void() func_rain =
{
    setmodel(self, self.model);   // adopt brush bbox; brush isn't rendered
    self.solid = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.modelindex = 0;          // hide from server-side rendering
    self.pvsflags = PVSF_NOREMOVE;
    self.use = func_rain_use;
    self.SendEntity = func_rain_SendEntity;
    self.frame = (self.spawnflags & FUNC_RAIN_START_OFF) ? 0 : 1;
    self.SendFlags = 1;
};
