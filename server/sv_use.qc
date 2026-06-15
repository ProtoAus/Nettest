//
//  sv_use.qc  –  +use activation and touch-trigger checks
//
//  SV_PlayerTryUse  : fired by "+use" client command; traces forward from
//                     the player's eye and calls .use on whatever it hits.
//  SV_CheckTouchTriggers: called every SV_RunClientCommand after PM_PlayerMove;
//                     fires SOLID_TRIGGER overlaps (door proximity triggers) and
//                     does a forward probe for func_button surface contact.
//

float PLAYER_USE_TRACE_LENGTH = 96;

// Forward decl from sv_weapons.qc — used by SV_TryWeaponPickup to identify
// pickable weapon entities (both map-placed and player-dropped wear it).
void() weapon_touch;

// Activate a usable entity on behalf of self (the player).
// Returns TRUE if the entity accepted the use.
float(entity use_target) SV_UseTarget =
{
    entity oldself, oldactivator;
    if (!use_target || use_target == world)
        return FALSE;
    if (!use_target.use)
        return FALSE;

    // sv_debug_use: print what we hit + its target chain so a mapper
    // can diagnose dead buttons (no target, locked master, etc.).
    if (cvar("sv_debug_use"))
    {
        print(sprintf("[+use] %s -> classname=\"%s\" target=\"%s\" targetname=\"%s\" master=\"%s\" killtarget=\"%s\" delay=%g\n",
                      self.netname,
                      use_target.classname,
                      use_target.target,
                      use_target.targetname,
                      use_target.master,
                      use_target.killtarget,
                      use_target.delay));
    }

    oldself      = self;
    oldactivator = activator;
    activator    = self;
    self         = use_target;
    self.use();
    self      = oldself;
    activator = oldactivator;
    return TRUE;
};

// Returns TRUE if `e` is a settled, pickable weapon (map or dropped).
// Dropped weapons remain pickup-gated after the toss so they cannot be
// re-grabbed mid-throw. Gate on both solid and weapon_solid_time.
float(entity e) SV_IsPickableWeapon =
{
    if (!e || e == world) return FALSE;
    if (e.touch != weapon_touch) return FALSE;
    if (e.solid == SOLID_NOT) return FALSE;
    if (e.weapon_solid_time > time) return FALSE;
    return TRUE;
};

// Pick up a weapon on behalf of the player. weapon_touch reads `other` as
// the receiving player and `self` as the pickup entity, so swap context
// before invoking.
float(entity weap) SV_TryWeaponPickup =
{
    if (!SV_IsPickableWeapon(weap)) return FALSE;

    entity oldself  = self;
    entity oldother = other;
    other = self;     // player becomes other
    self  = weap;
    self.touch();      // weapon_touch — slot/ammo/equip/cleanup
    self  = oldself;
    other = oldother;
    return TRUE;
};

// +use weapon swap: if the player already has a weapon in the pickup's
// slot, drop the held one and equip the new one in a single +use.
// Without this the duplicate-slot reject inside weapon_touch made
// +use no-op on a same-slot pickup, forcing the player to bind drop +
// pickup separately.  Utility is multi-carry and falls through to the
// normal pickup (weapon_touch handles utility duplicates per-weapon).
float(entity weap) SV_TryWeaponSwap =
{
    if (!SV_IsPickableWeapon(weap)) return FALSE;

    float pickup_slot = weap.weapon_slot;
    if (pickup_slot == SLOT_UTILITY)
        return SV_TryWeaponPickup(weap);

    float held_in_slot = WEP_NONE;
    if      (pickup_slot == SLOT_PRIMARY)   held_in_slot = self.slot_primary;
    else if (pickup_slot == SLOT_SECONDARY) held_in_slot = self.slot_secondary;
    else if (pickup_slot == SLOT_MELEE)     held_in_slot = self.slot_melee;

    // Fists are intrinsic — treat them as an empty melee slot for
    // pickup purposes.  Without this collapse the swap path below
    // tries to W_DropCurrentWeapon the fists, which is a no-op
    // (slot_melee_drop is NULL), leaving slot_melee = WEP_MELEE so
    // the subsequent SV_TryWeaponPickup re-rejects.  Net visible
    // effect was "weapon flickers on ground but never enters
    // inventory", the user's exact bug report.
    if (pickup_slot == SLOT_MELEE && held_in_slot == WEP_MELEE)
        held_in_slot = WEP_NONE;

    if (held_in_slot == WEP_NONE)
        return SV_TryWeaponPickup(weap);   // empty slot — normal pickup

    if (held_in_slot == weap.weapon)
        return SV_TryWeaponPickup(weap);   // identical weapon — let weapon_touch reject

    // Switch to the slot's currently-held weapon if we're not already
    // wielding it (W_DropCurrentWeapon drops `self.weapon`, so we must
    // be holding the one we want to drop).  W_DropCurrentWeapon then
    // calls W_SelectStrongest which equips whatever's left, and the
    // SV_TryWeaponPickup that follows runs weapon_touch's standard
    // auto-equip rules — primary auto-equips, secondary auto-equips
    // when no primary exists, etc., so the player ends up holding the
    // newly picked weapon as expected.
    if (self.weapon != held_in_slot)
        W_SelectWeapon(held_in_slot);

    W_DropCurrentWeapon();
    return SV_TryWeaponPickup(weap);
};

// Trace forward from the player's eye; try the hit entity first, then fall
// back to a cone search so slightly off-center aims still register. Dispatches
// to use targets (buttons/doors) OR weapon pickups, whichever is in front.
void() SV_PlayerTryUse =
{
    vector use_start, use_end;
    entity best, e;
    float  best_dot, dot;
    float  best_is_weapon;

    // func_vehicle mount/dismount toggle (HL2-carry-style: consume the +use).
    // Dismount if already driving; else mount if standing on a vehicle's deck
    // inside its controls zone (Vehicle_TryMount re-validates both).
    if (self.driving != world)
    {
        Vehicle_Dismount(self);
        return;
    }
    {
        // NOTE: QuakeC && does NOT short-circuit — both operands are always
        // evaluated.  Nest the calls so Vehicle_TryMount is reached only when a
        // real vehicle is under the player (else it'd run with veh==world and
        // try to write world's fields → "read-only entity 0").
        entity veh = Vehicle_FindMountable(self);
        if (veh != world)
        {
            if (Vehicle_TryMount(self, veh))
                return;
        }
    }

    makevectors(self.v_angle);
    use_start = self.origin + self.view_ofs;
    use_end   = use_start + v_forward * PLAYER_USE_TRACE_LENGTH;

    // HL2-style carry toggle (phys_files — see sv_physprop.qc Carry_*).  Otherwise
    // trace forward and try to grab a cabinet; on success consume the +use so it doesn't
    // also fire the prop's shove .use.  Non-carriables fall through to normal +use.
    if (self.carried_prop != world)
    {
        // While carrying, a +use aimed at a door/button activates IT (so you can open
        // doors / press buttons WITHOUT first dropping the prop, HL2-style).  Only a
        // +use that isn't aimed at a usable drops the prop.  Without this, every +use
        // while carrying dropped the prop and never reached the door/button logic below
        // — which is exactly the "+use stopped working on doors/buttons" regression.
        sv_use_is_player_direct = TRUE;
        traceline(use_start, use_end, MOVE_NORMAL, self);
        if (!Carry_IsCarriable(trace_ent) && SV_UseTarget(trace_ent))
        {
            sv_use_is_player_direct = FALSE;
            return;   // opened a door / pressed a button — keep carrying the prop
        }
        sv_use_is_player_direct = FALSE;
        Carry_Drop(self);
        return;
    }
    {
        vector grab_end;
        grab_end = use_start + v_forward * cvar("sv_carry_grab_dist");
        // Temporarily let the grab trace see the player-passthrough dimension
        // (PHYSDROP_DIM), so you can grab a prop that's still MOVING — just dropped,
        // thrown, or settling — not only once it has re-solidified at rest.
        float saved_dim_hit = self.dimension_hit;
        self.dimension_hit = self.dimension_hit | PHYSDROP_DIM;
        traceline(use_start, grab_end, MOVE_NORMAL, self);
        self.dimension_hit = saved_dim_hit;
        if (Carry_TryGrab(self, trace_ent))
            return;
    }

    sv_use_is_player_direct = TRUE;

    // sv_use_through_walls 1: same forward tracebox as the default
    // path, but iteratively skip past any non-usable solid entity
    // the trace hits (func_wall, func_illusionary, func_door
    // surfaces with no .use, decorative breakables) so the trace
    // continues to the next thing.  World BSP geometry still blocks
    // (worldspawn is not a func_* — it's the level's base brushwork).
    // This replaces the previous "skip trace, cone-search radius"
    // behaviour, which picked nearby-but-not-aimed-at entities and
    // felt arbitrary.  Off path keeps the existing single-trace
    // semantic so default play is unchanged.
    if (cvar("sv_use_through_walls"))
    {
        vector cur_start = use_start;
        entity ignore    = self;
        float  steps     = 0;
        while (steps < 16)
        {
            steps = steps + 1;
            traceline(cur_start, use_end, MOVE_NORMAL, ignore);
            if (trace_fraction >= 1.0)
                break;                   // trace ran clean to use_end
            if (!trace_ent || trace_ent == world)
                break;                   // hit world — wall blocks
            if (trace_ent.use && SV_UseTarget(trace_ent))
            {
                sv_use_is_player_direct = FALSE;
                return;
            }
            if (SV_TryWeaponSwap(trace_ent))
            {
                sv_use_is_player_direct = FALSE;
                return;
            }
            // Hit a non-usable solid entity (func_wall / decorative).
            // Step the trace start past it and ignore it on the next
            // iteration so we don't re-hit the same surface.
            ignore    = trace_ent;
            cur_start = trace_endpos + v_forward * 1;
        }
    }
    else
    {
        traceline(use_start, use_end, MOVE_NORMAL, self);
        if (SV_UseTarget(trace_ent))
        {
            sv_use_is_player_direct = FALSE;
            return;
        }
        // Direct hit on a weapon — tracebox MOVE_NORMAL skips SOLID_TRIGGER
        // weapons so this rarely fires, but covers the case where a weapon
        // sits on a clip-brush or other SOLID_BBOX surface that bumps it
        // into the trace's collision set.  Use the swap path so +use on a
        // weapon you already have in that slot drops yours and picks up
        // the targeted one.
        if (SV_TryWeaponSwap(trace_ent))
        {
            sv_use_is_player_direct = FALSE;
            return;
        }
    }

    // Radius fallback: pick the entity within the cone that is most aligned
    // with the player's view direction. Combines use-targets and weapon
    // pickups in one pass so whichever is more centered wins.
    best           = world;
    best_dot       = 0.7;   // ~45-degree half-cone
    best_is_weapon = FALSE;
    e = findradius(use_start, PLAYER_USE_TRACE_LENGTH);
    while (e)
    {
        if (e == self) { e = e.chain; continue; }

        float is_weap = SV_IsPickableWeapon(e);
        if (e.use || is_weap)
        {
            dot = normalize(e.origin - use_start) * v_forward;
            if (dot > best_dot)
            {
                best_dot       = dot;
                best           = e;
                best_is_weapon = is_weap;
            }
        }
        e = e.chain;
    }

    if (best_is_weapon)
        SV_TryWeaponSwap(best);
    else
        SV_UseTarget(best);

    sv_use_is_player_direct = FALSE;
};

// Called after PM_PlayerMove each frame.
// 1. Check every nearby SOLID_TRIGGER for box overlap and fire its .touch.
//    This covers door proximity triggers (which the engine normally fires for
//    MOVETYPE players but not for our MOVETYPE_NONE + custom-physics players).
// 2. Short forward probe to detect func_button surface contact so that
//    walking into a button activates it.
void() SV_CheckTouchTriggers =
{
    entity e;
    entity oldself, oldother;

    // --- 1. SOLID_TRIGGER overlap (door auto-open triggers) ---
    e = findradius(self.origin, 128);
    while (e)
    {
        if (e.solid == SOLID_TRIGGER && e.touch)
        {
            if (self.absmin_x <= e.absmax_x && self.absmax_x >= e.absmin_x &&
                self.absmin_y <= e.absmax_y && self.absmax_y >= e.absmin_y &&
                self.absmin_z <= e.absmax_z && self.absmax_z >= e.absmin_z)
            {
                oldself = self; oldother = other;
                other   = self;
                self    = e;
                self.touch();
                self  = oldself;
                other = oldother;
            }
        }
        e = e.chain;
    }

    // --- 2. func_button contact check ---
    // Expand the player bbox by 2 units; any func_button overlapping that
    // expanded box is considered "touched" regardless of approach direction.
    e = findradius(self.origin, vlen(self.maxs) + 16);
    while (e)
    {
        if (e.classname == "func_button" && e.touch)
        {
            if (self.absmin_x - 2 <= e.absmax_x && self.absmax_x + 2 >= e.absmin_x &&
                self.absmin_y - 2 <= e.absmax_y && self.absmax_y + 2 >= e.absmin_y &&
                self.absmin_z - 2 <= e.absmax_z && self.absmax_z + 2 >= e.absmin_z)
            {
                oldself = self; oldother = other;
                other   = self;
                self    = e;
                self.touch();
                self  = oldself;
                other = oldother;
                break;  // one button at a time
            }
        }
        e = e.chain;
    }
};
