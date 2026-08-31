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

    // A GoldSrc door with no SF_DOOR_USE_ONLY is not in the player's use-trace
    // at all (CBaseDoor::ObjectCaps grants FCAP_IMPULSE_USE only with bit 256).
    // Report NOT-HANDLED rather than letting door_use reject it, because
    // returning TRUE here would consume the press: the through-walls trace
    // loop and the cone fallback both stop at the first "handled" entity, so
    // a locked door standing between the player and a real button would eat
    // every press aimed past it.
    if ((use_target.classname == "func_door"
         || use_target.classname == "func_door_rotating")
        && !use_target.door_player_usable
        && cvar("sv_door_use_only"))
        return FALSE;

    // func_water is LINK_ENTITY_TO_CLASS'd straight onto CBaseDoor
    // (doors.cpp:276), so the arm above applies to it verbatim — it just never
    // matched, because sv_water.qc keeps the classname "func_water" while
    // inheriting .use = door_use.  The press therefore fell through to door_use,
    // which answered a named pool with the buttons/button2.wav locked click that
    // Sven does not make.  CBaseDoor::Spawn also force-sets SF_DOOR_SILENT on any
    // door with skin != 0 (doors.cpp:291-295), i.e. on every func_water, so a pool
    // cannot emit ANY door sound in GoldSrc — locked click included.
    //
    // A SEPARATE `if` rather than a third || term, on purpose: sv_doors.qc:1411-1416
    // records a three-term || silently evaluating to 0 in this codebase with
    // logicops off.  Not worth re-testing that for one classname.
    if (use_target.classname == "func_water"
        && !use_target.door_player_usable
        && cvar("sv_door_use_only"))
        return FALSE;

    // Entities Half-Life keeps out of the player's use search entirely, by
    // withholding FCAP_IMPULSE_USE from ObjectCaps().  A press aimed past one
    // must reach whatever is behind it, so report NOT-HANDLED without consuming
    // it — the difference between "that door is locked" and "that button does
    // nothing".  See the note on .use_passthrough in sv_customdefs.qc.
    //
    // This used to test `onlytrigger`, which is a func_breakable key and never
    // meant this; see the same note for what that key actually is.
    if (use_target.use_passthrough)
        return FALSE;

    // Monsters carry a .use so that a trigger chain naming one by targetname
    // still passes THROUGH it - an entity with a spawn function loses the inert
    // relay that unimplemented classes get for free, and dropping the chain
    // there soft-locks progression on a campaign map.  That relay is for
    // TRIGGERS, though, not for players: without this gate a player could fire
    // a monster's target chain by walking up and pressing +use on it.
    //
    // monster_player_usable is the opt-in, mirroring door_player_usable
    // directly above.  The ally work sets it, because +use on a scientist or a
    // barney is a real interaction (follow / stop following).
    if ((use_target.flags & FL_MONSTER) && !use_target.monster_player_usable)
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
    // Prop Hunt: a weaponless hider must not have their +use CONSUMED by a gun they can
    // never pick up — returning FALSE here lets the use fall through to the door/button
    // behind it.  weapon_touch is the authoritative block; this is the UX half.
    // (`self` is the using player on every path that reaches here — SV_TryWeaponPickup
    // and SV_TryWeaponSwap are both called from SV_PlayerTryUse with self = player.)
    if (PropHunt_HiderNoWeapons(self)) return FALSE;
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

// Sven item_inventory +use collection (sv_item_inventory.qc, compiled just
// above).  Returns TRUE when the press was consumed by a pickup.
float(entity it, entity plyr) Inv_TryPickup;

// prop_car / func_car mount gate (defined in sv_prop_vehicle.qc, compiled later).
entity(entity plyr) Car_FindMountable;
float(entity plyr, entity car) Car_TryMount;
void(entity plyr) Car_Dismount;

// Trace forward from the player's eye; try the hit entity first, then fall
// back to a cone search so slightly off-center aims still register. Dispatches
// to use targets (buttons/doors) OR weapon pickups, whichever is in front.
void() SV_PlayerTryUse =
{
    vector use_start, use_end;
    entity best, e;
    float  best_dot, dot;
    float  best_is_weapon;

    // A player pressing +use carries no explicit use type — HL's PlayerUse
    // calls Use(..., USE_SET) for trains and USE_TOGGLE for everything else,
    // and the "everything else" default is what the entities below expect.
    // sub_use_type is a GLOBAL holding whatever the last trigger chain left in
    // it, so it must be re-seeded per press or a stale USE_ON/USE_OFF from an
    // unrelated map event decides what this button does.  Entities that read it
    // (func_tracktrain_use, func_train_use, momentary, multisource) see
    // USE_UNSET and take their toggle path, which is correct for a hand press.
    sub_use_type = USE_UNSET;

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

    // func_traincontrols: standing in a tracktrain's control zone and pressing
    // +use starts / stops it.  The zone brush is SOLID_NOT and invisible, so
    // the forward trace further down can never find it — it has to be an
    // explicit position test, exactly like the vehicle mount above.
    if (TrainControls_TryUse(self))
        return;

    // prop_car / func_car mount/dismount toggle (SEPARATE .car_driving field so it
    // never aliases func_vehicle). MUST run before the carry-grab trace below, or a
    // MOVETYPE_PHYSICS chassis would be grabbed like a filing cabinet.
    if (self.car_driving != world)
    {
        Car_Dismount(self);
        return;
    }
    {
        entity car = Car_FindMountable(self);
        if (car != world)
        {
            if (Car_TryMount(self, car))
                return;
        }
    }

    makevectors(self.v_angle);
    use_start = self.origin + self.view_ofs;
    use_end   = use_start + v_forward * PLAYER_USE_TRACE_LENGTH;

    // Prop Hunt: a HIDER's +use aimed at a prop POSSESSES it (become a copy of
    // it — model, hull, size-scaled HP).  Consumes the +use on success; a
    // non-prop hit falls through so hiders still open doors / press buttons.
    // Self-gates on gamemode + team (instant FALSE otherwise).
    if (PropHunt_TryPossess(self))
        return;

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
    // Hiders don't take THIS generic grab path: an UNdisguised hider's +use means
    // "become it" (handled above in PropHunt_TryPossess), and a DISGUISED hider's grab
    // is done inside PropHunt_TryPossess too (it picks up a carriable prop matching its
    // possess trace), so control never reaches here for them.
    if (!PropHunt_IsHider(self))
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
            if (Inv_TryPickup(trace_ent, self))
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
        if (Inv_TryPickup(trace_ent, self))
        {
            sv_use_is_player_direct = FALSE;
            return;
        }
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
            // Rank by AABB MIDPOINT, not .origin.  A GoldSrc brush entity
            // compiled without an ORIGIN brush keeps .origin == '0 0 0' —
            // its world position lives entirely in the baked BSP submodel —
            // so ranking on .origin scored every Half-Life func_door /
            // func_button as if it sat at the map origin and the cone could
            // never select one.  This also makes the RANKING basis agree
            // with findradius's own SELECTION basis: PF_findradius measures
            // to origin + (mins+maxs)*0.5, which is exactly this.
            // Keep identical to CSQC_PredictUse's cone in cl_brushsync.qc.
            vector to_e = ((e.absmin + e.absmax) * 0.5) - use_start;
            if (vlen(to_e) < 0.01) { e = e.chain; continue; }   // standing inside it
            dot = normalize(to_e) * v_forward;
            if (dot > best_dot)
            {
                best_dot       = dot;
                best           = e;
                best_is_weapon = is_weap;
            }
        }
        e = e.chain;
    }

    // The cone fallback is the path that actually matters for item_inventory,
    // and for exactly the reason the weapon comment above gives: an
    // item_inventory is SOLID_TRIGGER (Sven's `solid` key defaults to "touch on
    // edge, non-blocking"), and traceline MOVE_NORMAL does not collide with
    // SOLID_TRIGGER at all — so the two traces above will essentially never
    // return one.  findradius does see it.
    //
    // Tried BEFORE the use/weapon dispatch because item_inventory also carries
    // a .use, for the trigger-driven remote collect Sven documents.  Letting
    // SV_UseTarget reach that would collect the item while ignoring the
    // TOUCH_ONLY spawnflag, which is precisely what that flag exists to forbid.
    if (Inv_TryPickup(best, self))
    {
        sv_use_is_player_direct = FALSE;
        return;
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
    //     ...and MONSTERS, which is not a bonus feature bolted onto a trigger
    //     sweep but the only way a monster's .touch can ever run at all.
    //
    //     This mod does not use engine player physics.  Players run the custom QC
    //     pmove in sh_pmove.qc, so the engine generates no SV_Impact pairs for
    //     them and this function IS the touch dispatcher - and it only ever knew
    //     about SOLID_TRIGGER and func_button.  Every monster-side player-contact
    //     behaviour was therefore dead code: Cockroach_Touch (mon_cockroach.qc:47)
    //     is a faithful port of CRoach::Touch and had never once been called,
    //     which is exactly the reported "roaches don't get squished".
    //
    //     Reusing THIS sweep rather than adding a second findradius is deliberate:
    //     it runs after every player move, so a second walk would double a
    //     per-player per-frame cost for one extra test per candidate.
    e = findradius(self.origin, 128);
    while (e)
    {
        if ((e.flags & FL_MONSTER) && e.touch && e.deadflag == DEAD_NO
            && e.solid != SOLID_NOT)
        {
            if (self.absmin_x <= e.absmax_x && self.absmax_x >= e.absmin_x &&
                self.absmin_y <= e.absmax_y && self.absmax_y >= e.absmin_y &&
                self.absmin_z <= e.absmax_z && self.absmax_z >= e.absmin_z)
            {
                sv_dbg_monster_touch = sv_dbg_monster_touch + 1;
                oldself = self; oldother = other;
                other   = self;
                self    = e;
                self.touch();
                self  = oldself;
                other = oldother;
            }
        }
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

    // --- 3. func_breakable with the "Touch" spawnflag (HL SF_BREAK_TOUCH, bit 2) ---
    //
    // The handler has been installed on these brushes since the class was
    // written (sv_breakable.qc, `self.touch = func_breakable_touch`) and has
    // NEVER ONCE been called.  Players here are MOVETYPE_NONE with QC pmove
    // (sv_player.qc, "engine physics off; we run our own"), so the engine
    // generates no SV_Impact pairs for them; SV_LinkEdict's touch pass only
    // fires SOLID_TRIGGER entities and a func_breakable is SOLID_BSP; and a
    // MOVETYPE_PUSH brush that never moves never generates a touch from the
    // push side either.  This function IS the touch dispatcher, as its own
    // header says — and it only ever knew about SOLID_TRIGGER, FL_MONSTER and
    // func_button.  A grep for func_breakable_touch found the definition, two
    // `.touch =` assignments and zero call sites.
    //
    // A list rather than the findradius above, because that sweep ranks on the
    // brush centre and the corpus has touch breakables with a half-diagonal of
    // 163 units.  See breakable_touch_list in sv_breakable.qc.
    //
    // The +/-2 inflation is there for the same reason the func_button arm needs
    // it: a solid brush stops the player just OUTSIDE its bbox, so a strict
    // overlap test would barely ever fire (the engine only spreads submodel
    // bounds by 1 unit).
    // `e.touch == func_breakable_touch`, not merely `e.touch`.  func_pushable
    // calls func_breakable() verbatim and then DELIBERATELY overwrites the
    // handler with its own ("Touch has to win over func_breakable's TOUCH-flag
    // handler", sv_func_pushable.qc), so a pushable authored with bit 2 would
    // join this list and then get func_pushable_touch called once per player per
    // frame on top of its own hull-sweep dispatcher — a double shove.  No corpus
    // map does that today, so this is latent, but the identity test costs one
    // token and also disposes of the freed-edict concern in the list's own note.
    e = breakable_touch_list;
    while (e)
    {
        entity nxt = e.breakable_touch_next;
        if (e.touch == func_breakable_touch && !e.breakable_broken && e.solid != SOLID_NOT
         && self.absmin_x - 2 <= e.absmax_x && self.absmax_x + 2 >= e.absmin_x
         && self.absmin_y - 2 <= e.absmax_y && self.absmax_y + 2 >= e.absmin_y
         && self.absmin_z - 2 <= e.absmax_z && self.absmax_z + 2 >= e.absmin_z)
        {
            oldself = self; oldother = other;
            other   = self;
            self    = e;
            self.touch();
            self  = oldself;
            other = oldother;
        }
        e = nxt;
    }
};
