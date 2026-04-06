//
//  sv_brushsync.qc  –  replicated solid brush entities
//
//  Replicates brush models to CSQC so shared tracebox prediction sees the
//  same func_wall geometry as the server.
//

float(entity playerent, float changedflags) solid_brush_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_SOLID_BRUSH);
    WriteString(MSG_ENTITY, self.model);

    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);

    WriteCoord(MSG_ENTITY, self.angles_x);
    WriteCoord(MSG_ENTITY, self.angles_y);
    WriteCoord(MSG_ENTITY, self.angles_z);

    WriteCoord(MSG_ENTITY, self.mins_x);
    WriteCoord(MSG_ENTITY, self.mins_y);
    WriteCoord(MSG_ENTITY, self.mins_z);

    WriteCoord(MSG_ENTITY, self.maxs_x);
    WriteCoord(MSG_ENTITY, self.maxs_y);
    WriteCoord(MSG_ENTITY, self.maxs_z);

    WriteFloat(MSG_ENTITY, self.alpha);
    WriteFloat(MSG_ENTITY, self.effects);

    // velocity: lets CSQC entities (doors, buttons) move in real-time
    // between network updates.  Static brushes always send '0 0 0'.
    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);

    return TRUE;
};

void() SV_InitReplicatedSolidBrush =
{
    if (!self.model)
    {
        dprint(sprintf("%s: no model, removing\n", self.classname));
        remove(self);
        return;
    }

    setmodel(self, self.model);
    self.movetype = MOVETYPE_PUSH;
    self.solid = SOLID_BSP;
    if (self.alpha <= 0)
        self.alpha = 1;

    // Replicate to CSQC so shared tracebox prediction sees this brush model.
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = solid_brush_SendEntity;
    self.SendFlags = 1;
};

/*QUAKED func_wall (.5 .5 .5) ? TRIGGERSPAWN TOGGLE START_ON NOT_SOLID
Simple solid brush entity. Replicated to CSQC so client prediction collides
with it identically to the server.

Keys:
"alpha" "0.01" makes the brush nearly invisible while keeping full collision.
*/
void() func_wall =
{
    SV_InitReplicatedSolidBrush();
};
