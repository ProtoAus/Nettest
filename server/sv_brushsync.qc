//
//  sv_brushsync.qc  –  replicated solid brush entities
//
//  Replicates brush models to CSQC so shared tracebox prediction sees the
//  same func_wall geometry as the server.
//
//  Doors and buttons send additional parameters (pos1, pos2, speed, state)
//  so the client can predict their movement instantly.
//

.float brush_type;      // BRUSH_TYPE_* — set by func_door/func_button
.float mover_state;     // current movement state (shared with door_state/button_state)

float(entity playerent, float changedflags) solid_brush_SendEntity =
{
    if (cvar("sv_debug_ent_types") && self.classname == "func_breakable")
    {
        bprint(PRINT_HIGH, sprintf("[brush send] ent=%g model='%s' origin=%v\n",
                                   num_for_edict(self), self.model, self.origin));
    }

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

    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);

    // Door/button parameters for client-side prediction
    WriteByte(MSG_ENTITY, self.brush_type);
    if (self.brush_type == BRUSH_TYPE_DOOR || self.brush_type == BRUSH_TYPE_BUTTON)
    {
        WriteCoord(MSG_ENTITY, self.pos1_x);
        WriteCoord(MSG_ENTITY, self.pos1_y);
        WriteCoord(MSG_ENTITY, self.pos1_z);
        WriteCoord(MSG_ENTITY, self.pos2_x);
        WriteCoord(MSG_ENTITY, self.pos2_y);
        WriteCoord(MSG_ENTITY, self.pos2_z);
        WriteFloat(MSG_ENTITY, self.speed);
        WriteByte(MSG_ENTITY, self.mover_state);
        WriteByte(MSG_ENTITY, (self.brush_type == BRUSH_TYPE_DOOR && (self.spawnflags & 64)) ? 1 : 0);
    }

    // Material code (BREAKABLE_*). 0 = default/concrete for non-breakable
    // brushes — CSQC's local impact classifier reads .style off the
    // trace_ent so the shooter sees per-material bullet effects without
    // needing the server's CSQC_EVENT_IMPACT round-trip.
    WriteByte(MSG_ENTITY, self.style);

    // Current health. Clamped to [0, 32767] and written as a short so the
    // attacker's CSQC can subtract predicted damage and decide whether the
    // shot would break the brush, playing the break sound locally without
    // a server round-trip. Non-breakable brushes report 0 so CSQC can
    // distinguish "damageable breakable" (health > 0) from "static wall"
    // (health == 0) without a second flag.
    WriteShort(MSG_ENTITY, bound(0, self.health, 32767));

    // max_health + cnt let CSQC spawn matching debris gibs locally when
    // the attacker predicts a break. Same values the server would pass to
    // CSQC_SpawnGlassGibs / CSQC_SpawnDebrisGibs via the gib events.
    WriteShort(MSG_ENTITY, bound(0, self.max_health, 32767));
    WriteByte(MSG_ENTITY, bound(0, self.cnt, 255));

    // Broken flag — func_breakable flips this when destroyed. Client
    // uses it to toggle drawmask / solid so the brush cleanly reappears
    // on round restart without relying on engine to re-send after a
    // SendEntity = __NULL__ transition.
    WriteByte(MSG_ENTITY, self.breakable_broken ? 1 : 0);

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

    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = solid_brush_SendEntity;
    self.SendFlags = 1;
};

/*QUAKED func_wall (.5 .5 .5) ? TRIGGERSPAWN TOGGLE START_ON NOT_SOLID
Simple solid brush entity. Replicated to CSQC so client prediction collides
with it identically to the server.
*/
void() func_wall =
{
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
};
