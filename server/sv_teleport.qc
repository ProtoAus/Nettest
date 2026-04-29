
//
//  sv_teleport.qc  –  trigger_teleport / info_teleport_destination
//
//  Position is snapped inside PM_PlayerMove (sh_pmove.qc) for client-side
//  prediction.  Destination data is resolved once, at spawn time, then
//  replicated to CSQC so the client list mirrors the server list.
//

// ---------------------------------------------------------------------------
//  Destination lookup  (shared with NewQuake original)
// ---------------------------------------------------------------------------

// Match any entity whose targetname equals target_name — not just
// info_teleport_destination.  Lets mappers point a teleport at e.g. a
// path_corner, info_player_deathmatch, or any other entity that
// happens to sit where they want the player to land, without having
// to drop a duplicate info_teleport_destination on top of it.  First
// match wins, which mirrors `find`'s iteration order (= entity-link
// order = roughly map-file order).
entity(string target_name) Teleport_FindDestination =
{
    return find(world, targetname, target_name);
};

// ---------------------------------------------------------------------------
//  CSQC replication
// ---------------------------------------------------------------------------

float(entity playerent, float changedflags) trigger_teleport_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_TELEPORT_TRIGGER);

    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);

    WriteCoord(MSG_ENTITY, self.mins_x);
    WriteCoord(MSG_ENTITY, self.mins_y);
    WriteCoord(MSG_ENTITY, self.mins_z);

    WriteCoord(MSG_ENTITY, self.maxs_x);
    WriteCoord(MSG_ENTITY, self.maxs_y);
    WriteCoord(MSG_ENTITY, self.maxs_z);

    WriteCoord(MSG_ENTITY, self.tele_dest_origin_x);
    WriteCoord(MSG_ENTITY, self.tele_dest_origin_y);
    WriteCoord(MSG_ENTITY, self.tele_dest_origin_z);

    WriteCoord(MSG_ENTITY, self.tele_dest_angles_x);
    WriteCoord(MSG_ENTITY, self.tele_dest_angles_y);
    WriteCoord(MSG_ENTITY, self.tele_dest_angles_z);

    WriteFloat(MSG_ENTITY, self.spawnflags);
    WriteFloat(MSG_ENTITY, self.tele_resolved);

    // BSP submodel index — CSQC binds via setmodelindex so prediction's
    // PM_BoxInTriggerBrush hits the same angled brush as the server.
    WriteShort(MSG_ENTITY, self.modelindex);

    return TRUE;
};

// ---------------------------------------------------------------------------
//  Deferred destination resolution  (fires one frame after spawn so all
//  info_teleport_destination entities are guaranteed to exist)
// ---------------------------------------------------------------------------

void() trigger_teleport_resolve =
{
    entity dest;

    if (!self.target)
        return;

    dest = Teleport_FindDestination(self.target);
    if (dest == world)
    {
        dprint(sprintf("trigger_teleport: no destination for target '%s'\n", self.target));
        return;
    }

    self.tele_dest_origin = dest.origin + '0 0 1';
    self.tele_dest_angles = dest.angles;
    self.tele_resolved    = TRUE;
    self.SendFlags        = 1;   // dirty: push update to CSQC
};

// ---------------------------------------------------------------------------
//  Entities
// ---------------------------------------------------------------------------

/*QUAKED info_teleport_destination (.5 .5 .5) (-8 -8 -8) (8 8 8)
Destination marker for trigger_teleport.  Set 'targetname' to match the
teleporter's 'target'.  Set 'angles' to control the player's view direction
after teleporting (leave at zero for no angle change).
*/
void() info_teleport_destination =
{
};

/*QUAKED trigger_teleport (.5 .5 .5) ? x x KEEPVEL KEEPANGLE
Teleports players that enter this brush to the matching info_teleport_destination.

KEEPVEL   (4) – preserve the player's velocity after teleporting.
KEEPANGLE (8) – keep the player's current view angle; ignore destination angles.
*/
void() trigger_teleport =
{
    if (!self.target)
    {
        dprint("trigger_teleport: no target set, removing\n");
        remove(self);
        return;
    }

    // Keep BSP submodel bound (don't zero modelindex) so angled trigger
    // brushes use their actual BSP geometry in PM_BoxInTriggerBrush, not
    // just the AABB. EF_NODRAW hides the brush visually.
    setmodel(self, self.model);
    self.effects   |= EF_NODRAW;
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_TRIGGER;  // kept so engine can fire touch if needed

    // add to shared list for PM_CheckTeleportTriggers
    self.tele_next        = teleport_trigger_list;
    teleport_trigger_list = self;

    // replicate to CSQC for client-side prediction
    self.pvsflags   = PVSF_NOREMOVE;
    self.SendEntity = trigger_teleport_SendEntity;
    self.SendFlags  = 1;

    // resolve destination after all map entities have spawned
    self.think     = trigger_teleport_resolve;
    self.nextthink = time + 0.1;
};
