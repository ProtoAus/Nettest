
//
//  sv_ladder.qc  –  trigger_ladder entity
//
//  Ladder detection and GoldSrc-style movement live in PM_PlayerMove
//  (sh_pmove.qc) so both server physics and client-side prediction run
//  identical code.  The entity is replicated to CSQC so the client list
//  stays in sync with the server list.
//

// ---------------------------------------------------------------------------
//  List helpers
// ---------------------------------------------------------------------------

void(entity trig) ladder_list_remove =
{
    entity cur, prev;

    if (ladder_trigger_list == trig)
    {
        ladder_trigger_list = trig.ladder_next;
        trig.ladder_next = world;
        return;
    }

    prev = world;
    for (cur = ladder_trigger_list; cur; cur = cur.ladder_next)
    {
        if (cur == trig)
        {
            if (prev)
                prev.ladder_next = cur.ladder_next;
            cur.ladder_next = world;
            return;
        }
        prev = cur;
    }
};

// ---------------------------------------------------------------------------
//  CSQC replication
// ---------------------------------------------------------------------------

float(entity playerent, float changedflags) trigger_ladder_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_LADDER_TRIGGER);

    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);

    WriteCoord(MSG_ENTITY, self.mins_x);
    WriteCoord(MSG_ENTITY, self.mins_y);
    WriteCoord(MSG_ENTITY, self.mins_z);

    WriteCoord(MSG_ENTITY, self.maxs_x);
    WriteCoord(MSG_ENTITY, self.maxs_y);
    WriteCoord(MSG_ENTITY, self.maxs_z);

    WriteCoord(MSG_ENTITY, self.movedir_x);
    WriteCoord(MSG_ENTITY, self.movedir_y);
    WriteCoord(MSG_ENTITY, self.movedir_z);

    return TRUE;
};

// ---------------------------------------------------------------------------
//  Spawn
// ---------------------------------------------------------------------------

/*QUAKED func_ladder (.5 .5 .5) ?
Climbable ladder volume.  This is the canonical classname (matches
GoldSrc/Source convention — the brush *is* the climbable volume, no
touch handler involved).

Set 'angles' to the direction a player faces when on the ladder (outward from
the wall surface).  Leave angles at '0 0 0' for an auto-detected normal based
on the player's view direction.

GoldSrc-style movement: looking up + pressing forward climbs up.  Jump pushes
away from the wall.
*/
void() func_ladder =
{
    if (self.angles != '0 0 0')
        SetMovedir();
    else
        self.movedir = '0 0 0';

    setmodel(self, self.model);
    self.modelindex = 0;
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_NOT;

    // prepend to shared list so PM_CheckLadder finds it
    self.ladder_next    = ladder_trigger_list;
    ladder_trigger_list = self;

    // replicate to CSQC for client-side prediction
    self.pvsflags   = PVSF_NOREMOVE;
    self.SendEntity = trigger_ladder_SendEntity;
    self.SendFlags  = 1;
};

/*QUAKED trigger_ladder (.5 .5 .5) ?
Backwards-compatibility alias for func_ladder.  Older maps in this mod
were authored with this classname; new maps should prefer func_ladder.
*/
void() trigger_ladder =
{
    func_ladder();
};
