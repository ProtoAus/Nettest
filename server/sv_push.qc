
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

// Is `other` something CTriggerPush::Touch would act on?  triggers.cpp:1842-1851,
// transcribed: four movetypes are skipped outright, and so are the two solidities
// that mean "not a physics body".  Sequential ifs rather than a chained || — the
// mod builds with logicops off.
float(entity e) TriggerPush_Affects =
{
    if (e.movetype == MOVETYPE_NONE)   return FALSE;
    if (e.movetype == MOVETYPE_PUSH)   return FALSE;
    if (e.movetype == MOVETYPE_NOCLIP) return FALSE;
    if (e.movetype == MOVETYPE_FOLLOW) return FALSE;
    if (e.solid    == SOLID_NOT)       return FALSE;
    if (e.solid    == SOLID_BSP)       return FALSE;
    return TRUE;
};

// Push an NPC.  Players are NOT handled here — they are pushed inside pmove
// (PM_ApplyTriggerPush) so the client can predict it; a monster has no predictor
// and no pmove, so this is where its half of the entity lives.
//
// SPLIT BY AXIS, exactly as the player path is, and for the same reason: HL's
// basevelocity is consumed differently per axis (see the long note at
// PM_ApplyTriggerPush).  `speed` is an ACCELERATION on Z and a carry velocity on XY.
//
// ONE DELIBERATE DIVERGENCE, forced by how monsters move here.  A GoldSrc entity
// gets its XY basevelocity applied by the engine whether or not it is standing;
// our monsters walk with walkmove(), which is POSITIONAL — SV_Physics_Step never
// integrates velocity for an entity that still has FL_ONGROUND.  So:
//
//   Z  — integrated into velocity and, when the result is upward, FL_ONGROUND is
//        cleared so the engine actually launches them.  This is the case the
//        entity is overwhelmingly used for (steam vents, updrafts, jump pads) and
//        it now behaves for an NPC exactly as it does for a player.
//   XY — added to velocity, but ground stick is NOT broken for a horizontal-only
//        push.  Carrying a walking NPC sideways would mean unsticking it from the
//        floor every frame it stood in the brush, and walkmove refuses outright
//        while airborne (sv_ai_move.qc:18-23) — a conveyor would freeze the NPC's
//        pathing altogether, which is worse than not carrying it.  Airborne NPCs
//        (already launched, or flyers) do get carried, because their velocity is
//        integrated normally.
// PUSH_ONCE is a separate branch in HL too (triggers.cpp:1853-1859) and is NOT
// integrated: it hands over the whole speed*movedir in one go and deletes the
// trigger, so scaling it by frametime would deliver ~1/70th of the intended kick.
void(entity trig, entity mon, float once) TriggerPush_ApplyToMonster =
{
    vector push = trig.movedir * trig.speed;
    float  dt   = once ? 1 : frametime;

    if (push_z != 0)
    {
        mon.velocity_z = mon.velocity_z + push_z * dt;
        if (mon.velocity_z > 0)
            mon.flags = mon.flags - (mon.flags & FL_ONGROUND);
    }

    mon.velocity_x = mon.velocity_x + push_x * dt;
    mon.velocity_y = mon.velocity_y + push_y * dt;
};

void() trigger_push_touch =
{
    // --- NPCs.  CTriggerPush::Touch does not special-case the player at all;
    // this mod does, because players are pushed in pmove for prediction. ---
    if (other.flags & FL_MONSTER)
    if (!(self.spawnflags & PUSH_NOMONSTERS))
    if (TriggerPush_Affects(other))
        TriggerPush_ApplyToMonster(self, other, self.spawnflags & PUSH_ONCE);

    if (!(self.spawnflags & PUSH_ONCE)) return;

    // PUSH_ONCE consumes the trigger for whoever tripped it, monster or player —
    // HL removes it from inside the same branch that applies the impulse
    // (triggers.cpp:1854-1859), with no classname test anywhere in the function.
    // Restricting the removal to players meant a monster could walk through a
    // once-only pad, take the push, and leave it armed for the next comer.
    if (other.classname != "player")
    if (!(other.flags & FL_MONSTER))
        return;

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

// Sven's "Mode of push" (sven-coop.fgd:6562-6567).  Declared so the engine
// binds the key; 0 = Regular (base velocity), 1 = Forced (minimum velocity),
// 2 = Forced (exact velocity).  Four entities in th_escape.bsp set pushmode 1
// and were getting the regular treatment.
.float pushmode;

/*QUAKED trigger_push (.5 .5 .5) ? Once Only, Start Off, -, No Clients, No Monsters
Pushes players and NPCs inside its volume in the direction set by angles.

Players are pushed inside pmove every physics step, so it is client-predicted.
NPCs are pushed from trigger_push_touch on the server (they have no predictor);
see TriggerPush_ApplyToMonster for the one axis where the two differ.

SPAWNFLAGS ARE SVEN'S, NOT THIS MOD'S — see the two vocabularies documented in
sh_customdefs.qc.  Only the bits below are read; every other bit a map sets is
discarded rather than aliased onto a mod-internal flag.

  1  Once Only    – remove after the first player OR NPC touch.
  2  Start Off    – do not push until a trigger fires this entity.
  8  No Clients   – do not push players.
 16  No Monsters  – do not push NPCs.
 64  Force push   – deprecated alias for pushmode 1.

KEYS
  speed    – qu/s for a horizontal push, qu/s^2 for a vertical one.  See
             PM_ApplyTriggerPush; this asymmetry is Half-Life's, not ours.
  pushmode – 0 regular (default), 1 forced-minimum, 2 forced-exact.
*/
void() trigger_push =
{
    if (self.angles == '0 0 0')
        self.angles = '0 360 0';

    SetMovedir();

    if (!self.speed)
        self.speed = 100;       // triggers.cpp:1825-1826.  Was 1000 — a 10x
                                // divergence for any map omitting the key.
                                // (Sven's FGD offers 40, but that is an editor
                                // default written into new entities, not the
                                // fallback the code applies.)

    // --- Map bits -> mod bits.  Nothing downstream may see a raw map bit. ---
    //
    // Before this, the map's spawnflags were used verbatim, so Sven's
    // "No Clients" (8) became PUSH_TUNNEL, "No Monsters" (16) became
    // PUSH_SOURCE, "Force push" (64) became PUSH_SILENT, and undefined-bit
    // garbage like th_ep1_03's spawnflags 6 became PUSH_ADDITIVE.  436 of the
    // corpus's 745 trigger_push entities carry at least one such bit.
    float raw = self.spawnflags;
    self.spawnflags = raw & (PUSH_ONCE | PUSH_START_OFF);

    if (raw & PUSHMAP_NOCLIENTS)
        self.spawnflags = self.spawnflags | PUSH_NOCLIENTS;
    // PUSHMAP_NOMONSTERS used to be DROPPED here, on the reasoning that
    // PM_ApplyTriggerPush only ever runs for players so the filter was implicit.
    // That reasoning expired the moment trigger_push_touch started pushing NPCs:
    // the bit now has to be carried across, or a mapper's "No Monsters" would be
    // silently ignored by the very feature it exists to switch off.  (It still
    // must not be passed through raw — as a raw bit it aliases PUSH_SOURCE.)
    if (raw & PUSHMAP_NOMONSTERS)
        self.spawnflags = self.spawnflags | PUSH_NOMONSTERS;

    float pmode = self.pushmode;
    if (!pmode && (raw & PUSHMAP_FORCE))
        pmode = 1;              // the deprecated spawnflag spelling
    if (pmode == 1)
        self.spawnflags = self.spawnflags | PUSH_FLOOR;
    else if (pmode >= 2)
        self.spawnflags = self.spawnflags | PUSH_EXACT;

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
