
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

// Active byte on the wire — CSQC reads this and either adds itself to
// push_trigger_list (active=1) or removes itself (active=0).  Keeping
// the entity in the snapshot but flipping a byte is more reliable than
// trying to drop the entity entirely via SendEntity=NULL, which
// interacts badly with PVSF_NOREMOVE (the entity hangs around on
// clients in its last-known state, causing CSQC to keep pushing while
// the server says off → "clipping into walls" reports).
.float push_wire_active;

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

    // BSP submodel index — CSQC binds this with setmodelindex so its
    // PM_BoxInTriggerBrush probe tests against the actual angled brush
    // geometry (matching the server). Without it, CSQC predicts using
    // only the AABB pre-filter and disagrees with the server on cuts.
    WriteShort(MSG_ENTITY, self.modelindex);

    WriteByte(MSG_ENTITY, self.push_wire_active ? 1 : 0);

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

// Internal activation: links the trigger into the SERVER's
// push_trigger_list, installs the touch handler, and flips the wire
// active byte so CSQC adds itself to its OWN push_trigger_list.
// Called either directly from the spawn function (no START_OFF), or
// via trigger_push_use after a targeted activation.
void() trigger_push_activate =
{
    self.solid = SOLID_TRIGGER;
    self.touch = trigger_push_touch;

    // Add to server list ONLY if not already in it — a redundant
    // activate (USE_ON to an already-on trigger) would otherwise
    // double-link the entity and break the chain walker.
    entity scan;
    float in_list = 0;
    if (push_trigger_list == self)
        in_list = 1;
    else
    {
        for (scan = push_trigger_list; scan; scan = scan.push_next)
        {
            if (scan == self)
            {
                in_list = 1;
                break;
            }
        }
    }
    if (!in_list)
    {
        self.push_next    = push_trigger_list;
        push_trigger_list = self;
    }

    self.push_wire_active = 1;
    self.SendFlags        = 1;     // dirty so the active=1 byte goes out
};

// Deactivate: remove from the SERVER's push_trigger_list AND flip the
// wire byte to 0 so CSQC removes from ITS list too.  Keeps SendEntity
// installed (the entity stays in the snapshot, just inactive) so a
// later USE_ON / TOGGLE can bring it back up via the same wire path.
//
// Earlier version set self.SendEntity=NULL on deactivate.  That
// interacted badly with PVSF_NOREMOVE: the engine stopped sending
// updates but the client's cached entity stuck around in the
// push_trigger_list, so CSQC kept predicting pushes while the server
// said off.  Result: the player would partially-push into walls until
// reconcile snapped them back.  Wire-byte approach is deterministic
// because the same snapshot that flips the bit also gates the client
// list operation.
void() trigger_push_deactivate =
{
    push_list_remove(self);
    self.solid = SOLID_NOT;
    self.touch = sub_noop;

    self.push_wire_active = 0;
    self.SendFlags        = 1;     // dirty so the active=0 byte goes out
};

// Use handler honouring USE_ON / USE_OFF / USE_TOGGLE from the
// trigger chain (sub_use_type set by Trigger_UseTargets before
// calling .use()).  Buttons fire OFF/ON/TOGGLE depending on their
// configured spawnflags — without this we'd toggle on every press,
// which fights paired enable/disable buttons.
void() trigger_push_use =
{
    float wanted_on;
    if (sub_use_type == USE_ON)         wanted_on = 1;
    else if (sub_use_type == USE_OFF)   wanted_on = 0;
    else                                 wanted_on = !self.push_wire_active;   // toggle

    if (wanted_on)
        trigger_push_activate();
    else
        trigger_push_deactivate();
};

/*QUAKED trigger_push (.5 .5 .5) ? PUSH_ONCE PUSH_START_OFF PUSH_SILENT PUSH_ADDITIVE PUSH_TUNNEL PUSH_SOURCE
Pushes players inside its volume in the direction set by angles.

Velocity is applied every physics step (client-predicted).

PUSH_ONCE      – remove after the first player touch.
PUSH_START_OFF – do not push until a trigger fires this entity.
                 First trigger activates and is one-shot.
PUSH_SILENT    – no wind sound.
PUSH_ADDITIVE  – add to current velocity instead of replacing it.
PUSH_TUNNEL    – pull toward the trigger centerline while pushing.
PUSH_SOURCE    – boost along movedir up to speed without overwriting sideways motion.
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

    // setmodel binds the BSP submodel ("*N") and gives us BOTH the AABB
    // (for the cheap pre-filter) AND the actual angled brush geometry (for
    // the per-trigger BSP probe in PM_BoxInTriggerBrush). Previously this
    // line was followed by `self.modelindex = 0;` to hide the brush, which
    // also threw away the BSP geometry — every angled trigger collapsed
    // to its AABB. EF_NODRAW keeps it invisible while preserving the BSP.
    setmodel(self, self.model);
    self.effects |= EF_NODRAW;
    self.movetype = MOVETYPE_NONE;

    // .use handler installed unconditionally — buttons / relays
    // can still toggle the trigger off and back on at runtime
    // regardless of whether it started off.  Without this, a
    // start-on trigger was uncontrollable for the rest of the map.
    self.use = trigger_push_use;

    // SendEntity installed once and left in place forever — the wire
    // active byte (push_wire_active) gates client-side push, not the
    // SendEntity presence.  Avoids the PVSF_NOREMOVE-vs-deactivate
    // sync problem.
    self.pvsflags   = PVSF_NOREMOVE;
    self.SendEntity = trigger_push_SendEntity;

    if (self.spawnflags & PUSH_START_OFF)
    {
        // Stay dormant until a trigger fires us.  push_wire_active is
        // already 0 (default), so the first snapshot ships active=0
        // and the client knows to skip list-add.
        self.solid    = SOLID_NOT;
        self.SendFlags = 1;     // ensure the active=0 ships now
        return;
    }

    trigger_push_activate();
};
