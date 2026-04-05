
//
//  sv_push.qc  –  trigger_push entity
//
//  Velocity is applied inside PM_PlayerMove (sh_pmove.qc) so both server
//  physics and client-side prediction run identical code.  The entity is
//  replicated to CSQC so the client list stays in sync with the server list.
//

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

void() SetMovedir =
{
    if (self.angles == '0 -1 0')
        self.movedir = '0 0 1';
    else if (self.angles == '0 -2 0')
        self.movedir = '0 0 -1';
    else
    {
        makevectors(self.angles);
        self.movedir = v_forward;
    }
    self.angles = '0 0 0';
};

void(entity trig) push_list_remove =
{
    entity cur, prev;

    if (push_trigger_list == trig)
    {
        push_trigger_list = trig.push_next;
        trig.push_next = world;
        return;
    }

    prev = world;
    for (cur = push_trigger_list; cur; cur = cur.push_next)
    {
        if (cur == trig)
        {
            if (prev)
                prev.push_next = cur.push_next;
            cur.push_next = world;
            return;
        }
        prev = cur;
    }
};

// ---------------------------------------------------------------------------
//  CSQC replication
// ---------------------------------------------------------------------------

float(entity playerent, float changedflags) trigger_push_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_PUSH_TRIGGER);

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

    WriteFloat(MSG_ENTITY, self.speed);
    WriteFloat(MSG_ENTITY, self.spawnflags);

    return TRUE;
};

// ---------------------------------------------------------------------------
//  PUSH_ONCE removal
// ---------------------------------------------------------------------------

void() trigger_push_touch =
{
    if (!(self.spawnflags & PUSH_ONCE)) return;
    if (other.classname != "player")    return;

    // prevent the touch from firing again before the entity is gone
    self.touch = sub_noop;

    push_list_remove(self);
    remove(self);   // fires CSQC_Ent_Remove on the client
};

// ---------------------------------------------------------------------------
//  Spawn
// ---------------------------------------------------------------------------

/*QUAKED trigger_push (.5 .5 .5) ? PUSH_ONCE PUSH_SILENT PUSH_ADDITIVE PUSH_TUNNEL PUSH_SOURCE
Pushes players inside its volume in the direction set by angles.

Velocity is applied every physics step (client-predicted).

PUSH_ONCE     – remove after the first player touch.
PUSH_SILENT   – no wind sound.
PUSH_ADDITIVE – add to current velocity instead of replacing it.
PUSH_TUNNEL   – pull toward the trigger centerline while pushing.
PUSH_SOURCE   – boost along movedir up to speed without overwriting sideways motion.
*/
void() trigger_push =
{
    if (self.angles == '0 0 0')
        self.angles = '0 360 0';

    SetMovedir();

    if (!self.speed)
        self.speed = 1000;

    if (!(self.spawnflags & PUSH_SILENT) && self.noise)
        precache_sound(self.noise);

    setmodel(self, self.model);
    self.modelindex  = 0;           // invisible brush, keep collision bounds
    self.movetype    = MOVETYPE_NONE;
    self.solid       = SOLID_TRIGGER;
    self.touch       = trigger_push_touch;

    // add to shared list so PM_CheckTriggerPushes finds it
    self.push_next    = push_trigger_list;
    push_trigger_list = self;

    // replicate to CSQC for client-side prediction
    self.pvsflags  = PVSF_NOREMOVE;
    self.SendEntity = trigger_push_SendEntity;
    self.SendFlags  = 1;
};
