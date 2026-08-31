
//
//  sv_teleport.qc  –  trigger_teleport / info_teleport_destination
//
//  Position is snapped inside PM_PlayerMove (sh_pmove.qc) for client-side
//  prediction.  Destination data is resolved once, at spawn time, then
//  replicated to CSQC so the client list mirrors the server list.
//

// Sven trigger_teleport / info_teleport_destination keys.
//
// DECLARING THESE IS NOT COSMETIC even where the behaviour is unimplemented.  An
// undeclared key falls through to ED_ParseUnknownEpair, which harvests it as a
// multi_manager slot - so every one of hl_c05_a2's silo teleports was booking a
// timed fire at a target literally named "teleport_cooldown":
//
//   [mm-parse] 'st_silo01_in' slot 1: target="teleport_cooldown" delay=0.001
//
// Harmless in that no such entity exists, but it burns manager slots and puts
// nonsense in the logs of anyone debugging a real chain.
//
// teleport_cooldown itself stays UNIMPLEMENTED and deliberately so - the reasoning
// is in TESTING.md under its own heading: 514 of its 770 uses are on the
// destination, where the clock is shared server state the client cannot predict,
// and a server-side refusal the client does not know about is a rubber-band.  The
// bounce this map suffered was never a cooldown problem anyway; see
// trigger_teleport_use below.
.float teleport_cooldown;
.float teleport_ignore_delay;
.float teleport_start_inactive;
.float teleport_if_blocked;

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
// Translate GoldSrc/Sven trigger_teleport spawnflags into the mod's vocabulary
// IN PLACE — see the bit table in sh_customdefs.qc.
//
// In place, rather than into a parallel field, because .spawnflags is what
// trigger_teleport_SendEntity puts on the wire and what the shared pmove reads
// on BOTH sides.  Rewriting it here means server and client agree with no
// protocol change at all.
//
// Native maps are untouched, so BSPs already compiled against nettest.fgd keep
// their existing 4/8 meanings exactly.
void() Teleport_NormaliseFlags =
{
    if (!Map_IsGoldSrc())
        return;

    float sven = self.spawnflags;
    float out  = 0;

    if (sven & 512) out = out | TELEPORT_KEEPVEL;     // Sven "Keep velocity"
    if (sven & 256) out = out | TELEPORT_KEEPANGLE;   // Sven "Keep Angles"
    if (sven & 128) out = out | TELEPORT_RELATIVE;    // Sven "Relative Teleport"
    if (sven & 2)   out = out | TELEPORT_NOCLIENTS;   // Sven "No Clients"

    // Dropped, all unimplemented here: 1 Monsters, 4 Pushables, 8 Everything
    // else, 16 Fire On Enter, 32 Fire On Exit, 64 Random Destination,
    // 1024 Rotate (Dest Angles).  Dropping 4 and 8 specifically MATTERS — left
    // set they read as our Keep Velocity and Keep Angle, which is how
    // -sp_campaign_portal's flag-909 teleports were accidentally preserving
    // velocity.
    self.spawnflags = out;

    // Sven's "Start Inactive".  Hammer cannot save a spawnflag past 2048, so Sven
    // moved this one out into a keyvalue and says so in a comment in its own FGD
    // (sven-coop.fgd:6843-6845, "Their respective properties below will add the
    // flag when the entity is created instead").  Folded onto the runtime bit here,
    // AFTER the assignment above, which would otherwise wipe it.
    if (self.teleport_start_inactive)
        self.spawnflags = self.spawnflags | TELEPORT_INACTIVE;

    if (cvar("sv_debug_use") && out != sven)
        dprint(sprintf("[teleport %s] flags %g -> %g (goldsrc)\n",
                       self.targetname, sven, out));
};

// CBaseTrigger::ToggleUse (halflife/dlls/triggers.cpp), which Sven extends to
// trigger_teleport - stock Half-Life installs no SetUse on this class at all, but
// Sven's FGD carries `teleport_start_inactive`, and a "start inactive" switch is
// meaningless without something to switch it back on.
//
// A TELEPORTER YOU CANNOT TURN OFF IS THE BUG.  hl_c05_a2's secret silo is a
// two-way pair whose destinations sit inside each other's brushes, and the map
// drives it entirely through this use function:
//
//   trigger_auto -> st_silo01_in    (triggerstate absent = USE_OFF)  } both OFF
//   trigger_auto -> st_silo01_out   (triggerstate absent = USE_OFF)  } at spawn
//   multi_manager "silod01in2out":  st_silo01_out  @1s usetype 1 (ON)
//                                   st_silo01_out  @4s usetype 0 (OFF)
//   multi_manager "silod01out2in":  st_silo01_in   @1s ON, @4s OFF
//
// With no .use at all, every one of those six commands was silently discarded and
// both halves stayed live forever - so arriving through one landed the player
// standing inside the other, which fired immediately and sent them back.  The
// reported symptom was "it keeps teleporting the player back and forth", and the
// reporter's own guess ("I think they are being enabled too quickly") names the
// delay 1 on that USE_ON exactly.
//
// HL's ToggleUse ignores useType and flips unconditionally; the explicit 0 and 1
// in the map data are honoured here rather than flattened, because a manager that
// fires OFF twice in a row must leave the trigger off, and a blind flip would turn
// it back on.
void() trigger_teleport_use =
{
    float was = (self.spawnflags & TELEPORT_INACTIVE);
    float now = was;

    if      (sub_use_type == USE_ON)  now = 0;
    else if (sub_use_type == USE_OFF) now = TELEPORT_INACTIVE;
    else                              now = was ? 0 : TELEPORT_INACTIVE;

    if (now == was)
        return;

    self.spawnflags = now ? (self.spawnflags | TELEPORT_INACTIVE)
                          : (self.spawnflags - (self.spawnflags & TELEPORT_INACTIVE));

    // The client predicts this teleport, so the client has to be told.  .spawnflags
    // is already the first thing trigger_teleport_SendEntity writes, so marking the
    // entity dirty is the whole of the replication.
    self.SendFlags = 1;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[teleport %s] now %s (usetype %g)\n", self.targetname,
                       now ? "INACTIVE" : "active", sub_use_type));
};

void() trigger_teleport =
{
    // MUST be first: everything below, plus the CSQC replication and the
    // shared pmove, reads .spawnflags.
    Teleport_NormaliseFlags();

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

    self.use = trigger_teleport_use;

    // replicate to CSQC for client-side prediction
    self.pvsflags   = PVSF_NOREMOVE;
    self.SendEntity = trigger_teleport_SendEntity;
    self.SendFlags  = 1;

    // resolve destination after all map entities have spawned
    self.think     = trigger_teleport_resolve;
    self.nextthink = time + 0.1;
};
