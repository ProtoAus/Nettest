// ============================================================================
//  server/sv_grapple.qc  —  grappling hook (sv_grappling)
//
//  Press WEAPON_IMPULSE_GRAPPLE to fire a gravity-affected hook
//  projectile.  On world contact the hook anchors, plays hook.wav, and
//  after sv_grappling_pull_delay seconds begins reeling the player
//  toward the anchor via an additive force (gravity still applies so
//  the player swings under it).  Re-press releases the hook; getting
//  within sv_grappling_release_dist of the anchor also releases.
//
//  Per-player state declared in sv_customdefs.qc:
//      .entity grapple_hook;
//      .float  grapple_attached;
//      .float  grapple_pull_sound_at;
//      .float  grapple_next_loop;
//
//  Hook entity classname "grapple_hook" + a precached visible model so
//  the standard SSQC→CSQC entity broadcast carries position to clients
//  for the rope visual.  Owner linkage is via the standard .owner
//  field plus an owner_entnum scalar that CSQC reads to look up the
//  rope's player-side endpoint.
// ============================================================================

// Tiny placeholder model so the engine assigns a real modelindex and
// broadcasts the entity to clients (without a valid modelindex, the
// entity never reaches CSQC and the rope can't be drawn).  Visibility
// of the bubble itself is suppressed via EF_NODRAW below — clients see
// only the rope.  progs/s_null.spr was tried first but isn't shipped
// with the gamedir; s_bubble.spr is confirmed-present.
const string GRAPPLE_HOOK_MODEL = "progs/s_bubble.spr";

// CSQC reads this to identify rope-owner pairs without needing access
// to .owner (which doesn't replicate).
.float owner_entnum;

void(entity player) W_GrappleRelease;
void()             W_GrappleHookTimeout;
void()             W_GrappleHookTouch;
void()             W_GrappleEngage;

// ----------------------------------------------------------------
//  Release path — used by re-press, attach-distance, miss-timeout,
//  player death / disconnect.
// ----------------------------------------------------------------
void(entity player) W_GrappleRelease =
{
    // Snapshot whether there was actually anything to release BEFORE
    // we tear it all down — used to gate the disconnect sound so
    // PlayerSpawn's defensive release-on-respawn doesn't play it on
    // every fresh life.
    float had_rope = (player.grapple_hook != world)
                  || player.grapple_rope_active
                  || player.grapple_attached;

    if (player.grapple_hook)
    {
        remove(player.grapple_hook);
        player.grapple_hook = world;
    }
    player.grapple_attached    = 0;
    player.grapple_pull_sound_at = 0;
    player.grapple_next_loop   = 0;
    // Clear the rope-render flag so CSQC stops drawing.  Anchor stays
    // at its last value — irrelevant once the flag is 0.
    player.grapple_rope_active = 0;
    if (had_rope)
    {
        // Announce the disconnect on a separate channel so it isn't
        // clobbered by the CHAN_BODY clear right below — CHAN_BODY is
        // the looping pull-sound channel, so silencing it cuts the
        // loop without cutting this one.
        sound(player, CHAN_AUTO,
            "sounds/player/grappledisconnect.wav", 1, ATTN_NORM);
    }
    // Cut any in-flight loop on CHAN_BODY.
    SV_StopChannel(player, CHAN_BODY);
};

// ----------------------------------------------------------------
//  Hook entity touch — invoked by the engine when the projectile
//  collides.  Self is the hook entity.
// ----------------------------------------------------------------
// What the hook is currently stuck in, when that is a movable object rather
// than world geometry.  world = anchored to level brushwork, the old behaviour.
//
// The hook used to discard `other` entirely and freeze itself at the contact
// point, which is why the rope stayed pinned to thin air where a moving crate
// used to be, and why the grapple could only ever pull the PLAYER.
.entity grapple_target;

// Can the hook reel this in rather than reel the player to it?
//
// Deliberately delegates every judgement to the physics layer already behind the
// gravity gun (sv_physprop.qc / sh_wpn_gravitygun.qc) instead of inventing a
// second opinion about what is grabbable.
float(entity e) W_GrappleTargetIsPullable =
{
    if (e == world) return FALSE;
    if (e.classname == "player") return FALSE;
    if (e.movetype == MOVETYPE_PHYSICS) return TRUE;
    if (e.classname == "corpse_ragdoll" && e.skeletonindex) return TRUE;
    // func_pushable and friends: pushable brushwork moves, level geometry does not.
    if (e.movetype == MOVETYPE_PUSH && e.classname == "func_pushable") return TRUE;
    return FALSE;
};

// IS `.weapon` ON THIS ENTITY ACTUALLY A WEAPON?
//
// `.weapon` is a STOCK entvars field (sv_defs.qc:334), so FTE's entity-lump parser
// writes it from any map key called "weapon" - and GoldSrc maps do exactly that.
// Every func_pushable on pizza_ya_san1 and pizza_ya_san2 ships `"weapon" "1"`, which
// lands as WEP_DEAGLE, and Weapon_PhysDropEligible says yes to any non-zero id.  The
// crate then went down the weapon path below: W_PhysDropStart swapped its SendEntity
// from solid_brush_SendEntity to dropped_weapon_SendEntity, the CSQC type byte
// changed under it, CSQC_Ent_CleanupTypeChange tore the brush down and re-dressed it
// as a pistol - "they turn into another model" - and W_PhysDropThink then removed it
// once the ODE body, sitting at the world origin because a GoldSrc submodel has
// .origin '0 0 0', tripped the stuck test.  That is "and then they vanished".
//
// weapon_touch is what this mod actually stamps on a gun; a replicated brush never
// carries it.  SV_IsPickableWeapon (sv_use.qc:91) asks the same question, but it
// also applies pickup UX gates (weapon_solid_time, PropHunt) that are wrong here.
float(entity e) W_GrappleIsWeaponEntity =
{
    if (!e || e == world)      return FALSE;
    if (e.weapon == WEP_NONE)  return FALSE;
    return (e.touch == weapon_touch);
};

// Is this a plain pickup — ammo box, health kit, battery — rather than a
// physics body?  These are authored as static SOLID_TRIGGER volumes with no ODE
// body at all, so Carry_TryGrab can never take them (Carry_IsCarriable requires
// MOVETYPE_PHYSICS).  They get tugged instead: see the touch handler.
float(entity e) W_GrappleTargetIsPickup =
{
    if (e == world) return FALSE;
    if (e.classname == "player") return FALSE;
    if (e.solid != SOLID_TRIGGER) return FALSE;
    // A pickup is something with a touch handler that gives you something.
    // .weapon covers dropped weapons and map weapons; .items / .aiment-free
    // ammo and health entities carry a touch and a model.
    return (e.touch != __NULL__) && (e.modelindex != 0);
};

void() W_GrappleHookTouch =
{
    // Players still can't be hooked — letting opponents be reeled around would
    // be a griefing tool, and it is not what the barnacle does in Opposing Force.
    if (other.classname == "player")
        return;

    // WAKE FIRST, THEN JUDGE.
    //
    // A settled weapon drop is SOLID_TRIGGER + MOVETYPE_NONE (weapon_become_solid
    // / the settle think in sv_weapons.qc), and W_GrappleTargetIsPullable only
    // says yes to MOVETYPE_PHYSICS.  So the reject below used to fire on exactly
    // the objects this feature exists for, BEFORE the W_PhysDropWake that would
    // have made them grabbable — "grab a dropped weapon and pull it to me" could
    // never work, quite apart from the fire gate that stopped the hook spawning
    // at all.  Waking here puts the object into MOVETYPE_PHYSICS first, so every
    // test after this point sees what it will actually be.
    if (W_GrappleIsWeaponEntity(other) && other.weapon_physdrop_sleeping)
        W_PhysDropWake(other);

    // A weapon that never became a physics body at all — a map spawn or a
    // `give`, which stay SOLID_TRIGGER + MOVETYPE_TOSS pickups because
    // W_SyncMapWeaponPhysics only converts the phys-eligible ones — gets
    // promoted here, so the tongue treats EVERY weapon the way it treats a crate.
    //
    // This is the reported behaviour gap: physics objects came to hand like a
    // +use carry, while weapons "simply disconnect and don't get picked up or
    // slung".  They were falling into the tug branch below, which set
    // MOVETYPE_TOSS on an entity whose client-side copy is drawn from a
    // SendEntity snapshot -- so the server moved something the client was never
    // told had moved, and from the player's side nothing happened at all.
    // Giving it a real body routes it through Carry_TryGrab, which owns the
    // SendFlags bookkeeping already.
    if (W_GrappleIsWeaponEntity(other) && other.model != ""
        && other.movetype != MOVETYPE_PHYSICS
        && W_PhysDropAllowed(other.weapon))
    {
        entity saved_self = self;
        self = other;
        other.owner     = world;
        other.velocity  = '0 0 0';
        other.avelocity = '0 0 0';
        W_PhysDropStart(other, 0);
        self = saved_self;
    }

    // SOLID_TRIGGER is not a blanket reject: dropped weapons, ammo boxes and
    // health kits all live there.  Triggers that are neither pullable nor a
    // pickup are still ignored, so walking a hook through a trigger_multiple or
    // a trigger_hurt does not stop it dead.
    if (other.solid == SOLID_TRIGGER
        && !W_GrappleTargetIsPullable(other)
        && !W_GrappleTargetIsPickup(other))
        return;

    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.touch    = __NULL__;
    self.nextthink = 0;             // cancel miss-timeout

    // ---- Hooked something movable?  Reel it in instead of reeling ourselves --
    //
    // This is a RANGED version of the gravity gun's grab, and it deliberately
    // reuses that machinery rather than growing a second physics path:
    // Carry_TryGrab latches the object and Carry_Tick (already driven every
    // frame from PlayerPreThink) floats it in to the carry pose, including the
    // smooth pull-in from wherever it was standing.
    //
    // A sleeping weapon drop is MOVETYPE_NONE until woken — still solid, so the
    // hook hits it, but nothing would ever move it.  That is exactly why resting
    // dropped weapons were ungrabbable for the gravity gun too, and the fix is
    // the same call.
    self.grapple_target = world;
    if (other != world && self.owner && self.owner.classname == "player")
    {
        float took = FALSE;
        // A dropped WEAPON deliberately skips the carry and goes to the tug
        // below, even though it is a perfectly grabbable ODE body.
        //
        // sv_phys_drops defaults to 1, so a dropped gun is MOVETYPE_PHYSICS and
        // Carry_TryGrab SUCCEEDED on it — which is why hooking one never reeled
        // it in: the grapple was not failing, it was quietly doing something
        // else.  You ended up holding the gun gravity-gun style, which lowers
        // the viewmodel and blocks firing, and the rope was torn down by that
        // success.  From the player's side that reads as "it just disconnects".
        //
        // Weapons are the one class where "collect it" is unambiguous, so they
        // get the tug the fallback below was written for.
        if (other.movetype == MOVETYPE_PHYSICS && !other.weapon)
        {
            // carry_allow_any widens Carry_IsCarriable from "cabinets only" to
            // "any ODE body" for this grab, matching W_GravGunFire's ranged grab.
            carry_allow_any = TRUE;
            took = Carry_TryGrab(self.owner, other);
            carry_allow_any = FALSE;
        }
        else if (other.classname == "corpse_ragdoll" && other.skeletonindex)
            took = Ragdoll_TryGrab(self.owner, other);

        // TUG FALLBACK — anything a carry could not take, but that the player
        // plainly meant to collect, still comes to them.
        //
        // Reached in three ways, and the first is the reported bug: a WEAPON
        // that reached Carry_TryGrab and was refused anyway.  Carry_TryGrab has
        // several independent reasons to say no (the object is already held, the
        // player is already carrying something, the ODE body is not live yet)
        // and the old code treated every one of them as "reel the player in
        // instead" — so the tongue hit a gun, said nothing, and yanked you at it.
        // Ammo boxes and health kits have no physics body at all and land here
        // too, as does a weapon on a server with sv_phys_drops off.
        if (!took && (W_GrappleIsWeaponEntity(other)
                      || W_GrappleTargetIsPickup(other)
                      || W_GrappleTargetIsPullable(other)))
        {
            vector to_me = (self.owner.origin + self.owner.view_ofs) - other.origin;
            float  d = vlen(to_me);

            // A REPLICATED BRUSH IS NEITHER TOSSED NOR SPUN.  A func_pushable is a
            // GoldSrc submodel with .origin '0 0 0' and its world position baked into
            // mins/maxs, so .angles rotates it about the MAP ORIGIN rather than
            // itself (sv_func_pushable.qc:41-46 documents this as unfixable for the
            // class) and MOVETYPE_TOSS hands the engine a brush that its own header
            // says must stay MOVETYPE_PUSH.  The crate has a velocity-driven tick of
            // its own and a moving_brush_list entry the client already mirrors, so a
            // horizontal impulse is the whole of what it needs - and it makes
            // "grapple a crate" and "+use-pull a crate" the same interaction.
            float is_brush = (other.solid == SOLID_BSP);

            if (!is_brush)
            {
                // A live ODE body must NOT be switched to MOVETYPE_TOSS — the
                // physics world keeps driving it and the movetype change is simply
                // ignored, which is a silent no-op.  Push the body instead.
                if (other.movetype != MOVETYPE_PHYSICS)
                    other.movetype = MOVETYPE_TOSS;
                else
                    PhysProp_Wake(other);   // a settled ODE body ignores .velocity
            }

            if (d > 1)
            {
                if (is_brush)
                {
                    // Horizontal only: a crate has no lift, and its own tick owns Z
                    // (gravity, ground probe, buoyancy).
                    vector flat = to_me;  flat_z = 0;
                    if (vlen(flat) > 1)
                        other.velocity = normalize(flat) * bound(120, d * 0.9, 400);
                    other.nextthink = other.ltime + 0.02;   // wake the crate's tick
                }
                else
                {
                    // Aim slightly above the player and scale with distance so a
                    // far pickup still arrives rather than falling short.
                    vector dir = normalize(to_me + '0 0 24');
                    other.velocity  = dir * bound(300, d * 1.6, 900);
                    other.avelocity = '0 240 0';
                }
            }
            // If this pickup draws itself through a SendEntity snapshot rather
            // than plain delta replication, the client will not notice it moved
            // unless the snapshot is dirtied.  Cheap, and silent to anything
            // that has no SendEntity.
            other.SendFlags |= 1;
            took = TRUE;
        }

        if (cvar("sv_debug_physprops"))
            dprint(sprintf("[grapple] hit %s ent=%g movetype=%g solid=%g weapon=%g took=%g\n",
                other.classname, num_for_edict(other), other.movetype,
                other.solid, other.weapon, took));

        if (took)
        {
            // The rope's job is done — the object is in hand.  Release rather
            // than leaving a rope stretched to something now floating in front
            // of the player's face.
            self.grapple_target = other;
            sound(self, CHAN_AUTO, "sounds/player/hook.wav", 1, ATTN_NORM);
            W_GrappleRelease(self.owner);
            return;
        }
    }

    if (self.owner && self.owner.grapple_hook == self)
    {
        self.owner.grapple_attached    = 1;
        self.owner.grapple_pull_sound_at = time + cvar("sv_grappling_pull_delay");
        self.owner.grapple_next_loop   = 0;
        sound(self, CHAN_AUTO, "sounds/player/hook.wav", 1, ATTN_NORM);

        // Ground-stick breaker: if the player is standing on the
        // floor when the hook lands, the per-tick pull's ~23 u/s
        // vertical component never exceeds PM_CategorizePosition's
        // `velocity_z > 180` cut-off, so the ground-snap trace
        // pins them every tick.  A one-shot jump-strength impulse
        // gets them airborne so the pull can take over.
        // ...but only when the PLAYER is the thing about to move.  With an
        // object hooked we reel it in and stay put, so launching the player off
        // the floor would be both wrong and disorienting.
        if ((self.owner.flags & FL_ONGROUND) && self.grapple_target == world)
        {
            float lift = cvar("sv_grappling_attach_lift");
            if (lift <= 0) lift = 270;
            self.owner.velocity_z = self.owner.velocity_z + lift;
            self.owner.flags = self.owner.flags & ~FL_ONGROUND;
        }
    }
};

// ----------------------------------------------------------------
//  Hook entity miss-timeout.  Self is the hook entity.
// ----------------------------------------------------------------
void() W_GrappleHookTimeout =
{
    if (self.owner && self.owner.grapple_hook == self)
        W_GrappleRelease(self.owner);
    else
        remove(self);
};

// ----------------------------------------------------------------
//  Engage — spawns the hook projectile + arms rope state.  Shared
//  body for the legacy `impulse 9` toggle (W_GrappleImpulse) and the
//  new press-and-hold rising-edge path (W_GrappleHeldTick).
// ----------------------------------------------------------------
void() W_GrappleEngage =
{
    entity h = spawn();
    h.classname  = "grapple_hook";
    h.owner      = self;
    h.owner_entnum = num_for_edict(self);
    h.movetype   = MOVETYPE_TOSS;       // gravity
    h.solid      = SOLID_BBOX;
    setmodel(h, GRAPPLE_HOOK_MODEL);
    setsize(h, '-2 -2 -2', '2 2 2');
    // Suppress the placeholder bubble visually — the entity still
    // broadcasts (CSQC needs to find it via modelindex to draw the
    // rope), but the sprite itself stays invisible.
    h.effects = h.effects | EF_NODRAW;
    makevectors(self.v_angle);
    // Spawn at waist, slightly forward so it doesn't immediately touch
    // the player's own bbox.
    setorigin(h, self.origin + self.view_ofs + '0 0 -16' + v_forward * 12);
    h.velocity   = self.velocity
                 + v_forward * cvar("sv_grappling_launch_speed");
    // Physics props and dropped weapons live on PHYSDROP_DIM, ragdolls on
    // RAGDOLL_DIM — dimensions the hook did not collide against, so it flew
    // straight through every one of them.  The gravity gun ORs the same bits
    // into its grab trace for the same reason (sh_wpn_gravitygun.qc).
    h.dimension_hit = h.dimension_hit | PHYSDROP_DIM | RAGDOLL_DIM;
    h.touch      = W_GrappleHookTouch;
    h.think      = W_GrappleHookTimeout;
    float life = cvar("sv_grappling_max_life");
    if (life <= 0) life = 5;
    h.nextthink  = time + life;

    self.grapple_hook = h;
    self.grapple_attached = 0;
    self.grapple_pull_sound_at = 0;
    self.grapple_next_loop = 0;
    // Set the CSQC-facing rope-active flag IMMEDIATELY on this tick so
    // Weapon_LowerBlocksFire sees rope_active=1 inside the same-tick
    // W_WeaponFrame (which runs in PlayerPreThink, AFTER CheckImpulses
    // dispatches us, but BEFORE W_GrapplePullTick would otherwise write
    // the flag on the next tick).  Anchor is set on the next PullTick
    // — the lower envelope only reads rope_active, so the anchor lag
    // doesn't affect the fire gate.
    self.grapple_rope_active = 1;

    sound(self, CHAN_WEAPON, "sounds/player/grappling.wav", 1, ATTN_NORM);
};

// ----------------------------------------------------------------
//  Impulse dispatch (legacy toggle) — called from W_CheckImpulses
//  with self = player.  Kept so existing `bind <key> "impulse 9"`
//  user binds keep working as the original press-to-fire /
//  press-to-release toggle.  The new press-and-hold path is
//  W_GrappleHeldTick below.
// ----------------------------------------------------------------
void() W_GrappleImpulse =
{
    if (!cvar("sv_grappling"))
        return;
    if (self.is_dead || self.health <= 0)
        return;

    // Re-press while a hook is alive — release and bail.  Matches the
    // legacy "press to fire, press to release" toggle behaviour.
    if (self.grapple_hook)
    {
        W_GrappleRelease(self);
        return;
    }

    W_GrappleEngage();
};

// ----------------------------------------------------------------
//  Press-and-hold edge tick — called from PlayerPreThink BEFORE
//  W_GrapplePullTick so a falling-edge release on the same tick
//  clears self.grapple_hook before PullTick re-asserts
//  grapple_rope_active = 1.
//
//  Rising edge (held, !was_held, no live hook): engage.
//  Falling edge (!held, was_held, hook alive): release.
//
//  Auto-release reasons (timeout, distance, respawn) still fire
//  independently — held_last latches the BUTTON state, so if the
//  hook auto-released while the player is still holding the bind,
//  pm_grapple_held_last stays 1 → no spurious re-engage every tick.
//  A new engage requires letting go and re-pressing.
// ----------------------------------------------------------------
void() W_GrappleHeldTick =
{
    if (!cvar("sv_grappling"))
    {
        // sv_grappling disabled mid-game: clear the latch so when it
        // re-enables, the next press registers as a fresh rising edge
        // instead of being eaten by stale was_held.
        self.pm_grapple_held_last = 0;
        return;
    }
    if (self.is_dead || self.health <= 0)
    {
        self.pm_grapple_held_last = 0;
        return;
    }

    float held     = (input_buttons & PM_BTN_GRAPPLE) ? 1 : 0;
    float was_held = self.pm_grapple_held_last;

    if (held && !was_held && !self.grapple_hook)
    {
        // Rising edge → spawn the hook.
        W_GrappleEngage();
    }
    else if (!held && was_held && self.grapple_hook)
    {
        // Falling edge → release the hook.  Mirrors what re-pressing
        // impulse 9 does under the legacy toggle path.
        W_GrappleRelease(self);
    }

    self.pm_grapple_held_last = held;
};

// ----------------------------------------------------------------
//  Per-tick pull — called from PlayerPreThink for every alive player.
//  Reads time-since-last-tick from `frametime` to keep the additive
//  acceleration framerate-independent.
// ----------------------------------------------------------------
void() W_GrapplePullTick =
{
    // ---- Rope-render state for CSQC ----
    // Maintain the synced (grapple_rope_active, grapple_anchor) pair
    // on EVERY tick the hook exists — during flight (gravity-affected
    // projectile) and attached.  CSQC reads these via the prediction
    // proxy to draw the rope without needing access to the server-only
    // hook entity.
    if (self.grapple_hook)
    {
        self.grapple_anchor      = self.grapple_hook.origin;
        self.grapple_rope_active = 1;
    }
    else
    {
        self.grapple_rope_active = 0;
    }

    if (!self.grapple_attached)
        return;
    if (!self.grapple_hook)
    {
        W_GrappleRelease(self);
        return;
    }

    vector to_anchor = self.grapple_hook.origin - self.origin;
    float  dist      = vlen(to_anchor);
    float  release   = cvar("sv_grappling_release_dist");
    if (release <= 0) release = 48;

    if (dist <= release)
    {
        W_GrappleRelease(self);
        return;
    }

    vector pull_dir = to_anchor * (1 / dist);


    // Add velocity along the rope, capped at sv_grappling_pull_max_speed
    // projected onto pull_dir.  Velocity perpendicular to the rope is
    // untouched, so gravity-driven fall and lateral swing are preserved.
    float v_along = self.velocity * pull_dir;
    float cap     = cvar("sv_grappling_pull_max_speed");
    if (cap <= 0) cap = 900;
    if (v_along < cap)
    {
        float add = cvar("sv_grappling_pull_force") * frametime;
        if (v_along + add > cap)
            add = cap - v_along;
        if (add > 0)
            self.velocity = self.velocity + pull_dir * add;
    }

    // Note: the per-tick FL_ONGROUND strip that previously sat here
    // was removed by user request.  It kept the player airborne for
    // the entire pull but as a side effect prevented PM_CheckJump
    // from firing on ground (pm_onground was always FALSE entering
    // pmove).  Now the one-shot lift impulse in W_GrappleHookTouch
    // gets the player airborne at attach time, and the categorize
    // ground-snap suppress in shared/sh_pmove.qc keeps them airborne
    // while pulling — unless they press jump, in which case the
    // suppress yields so the jump impulse + the post-jump grace
    // window takes over.  Net effect: a player who lands back on
    // ground mid-pull can jump again.

    // Looped pull sound: first emission delayed by
    // sv_grappling_pull_delay (so hook.wav is audible standalone), then
    // re-emit every sv_grappling_loop_interval seconds on CHAN_BODY.
    // Re-emitting on the same channel cleanly replaces the prior
    // instance — set the interval to your wav's exact length for a
    // seamless loop, or just under it for a slight crossfade.
    if (time >= self.grapple_pull_sound_at
     && time >= self.grapple_next_loop)
    {
        sound(self, CHAN_BODY, "sounds/player/grapplingpull.wav",
            1, ATTN_NORM);
        float loop_iv = cvar("sv_grappling_loop_interval");
        if (loop_iv < 0.05) loop_iv = 0.70;
        self.grapple_next_loop = time + loop_iv;
    }
};
