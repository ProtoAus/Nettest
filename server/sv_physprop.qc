//
//	sv_physprop.qc - server-authoritative ODE rigid-body props (BASELINE)
//
//	This file is intentionally minimal: ODE handles every collision — the
//	prop falls, rolls, contacts the world and other props, and gets pushed
//	by the player via ODE's own contact solver. There is no QC-side player
//	pushback, no QC-side depenetration, no dimension filter. Two external
//	hooks bolt onto that:
//	  - phys_barrel_use       +use → physics_addforce along view direction.
//	  - PhysProp_TryPushFromTrace  hitscan hit → physics_addforce at impact.
//
//	If the baseline feels lacking (weak player push, can't tip them over,
//	etc.), add back the specific behaviour deliberately. Don't put a
//	general-purpose "depen/push" system back in as a first instinct — it's
//	what this file was before, and it fought the engine.
//
//	Tunables (live, no recompile):
//	  sv_physprop_hit_force   bullet-hit force per damage point
//	  sv_physprop_use_force   base force on +use
//	  sv_physprop_use_velmult player-velocity multiplier on +use
//	  sv_physprop_mass        prop mass (applied on spawn only)
//	  sv_physprop_erp         ODE contact ERP offset
//	  sv_physprop_damp_lin    ODE linear damping (clamped to sane range)
//	  sv_physprop_damp_ang    ODE angular damping (clamped to sane range)
//	  sv_physprop_friction    ODE ground friction
//	  sv_debug_physprops      1 = log spawn/hit/use events
//
//	Useful engine cvars:
//	  physics_ode_contact_erp        default 0.96 — lower = softer contacts
//	  physics_ode_contactsurfacelayer default 0   — try 0.5 to reduce jitter
//	  physics_ode_iterationsperframe default 10   — solver cost dial
//	  physics_ode_autodisable        default 1    — sleep idle bodies
//	  r_showbboxes 1                              — draw AABBs (tuning aid)

// Dimension bit dedicated to physics props. Player has dim_solid/dim_hit
// without this bit — pmove notouches the prop, so the AABB doesn't block
// player movement. Hitscan paths OR this bit into the shooter's dim_hit
// for the duration of the trace so bullets still find the prop. ODE-vs-
// world contact bypasses the dim filter (com_phys_ode.c: only filters
// when both sides are non-world entnums), so prop physics is unaffected.
const float PHYSPROP_DIM = 2;

void() phys_barrel_use;
void(entity drop_ent) W_PhysDropWake;

// Hard upper limit on ODE per-substep damping. ODE applies this multiplicatively
// every ~10 ms substep (~100 substeps/s).
//   0.01 → (1-0.01)^100 ≈ 0.37 surviving vel/s — natural air
//   0.02 → (1-0.02)^100 ≈ 0.13                 — noticeably heavy but still falls
//   0.05 → (1-0.05)^100 ≈ 0.006                — floaty "treacle"
//   1.0  → zero velocity in a single substep   — instant hover
// Clamping at spawn means no stale cfg / rcon `set` can push props into the
// floaty band. Raise deliberately (in source, not cfg) for a heavier-air test.
const float PHYSPROP_DAMP_MAX = 0.02;

float(string cvar_name) PhysProp_SafeDamp =
{
	float v = cvar(cvar_name);
	if (v < 0)                    v = 0;
	if (v > PHYSPROP_DAMP_MAX)    v = PHYSPROP_DAMP_MAX;
	return v;
};

// Removal watchdog — ODE props have no self-destruct, so a prop that clips
// into the void keeps falling forever, accumulating huge origins / eventually
// NaN which destabilises the simulation (and can overflow the snapshot coord
// encoding on the wire). Every second we check origin and cull anything below
// the void floor or with an out-of-range coordinate. physics_enable(..FALSE)
// cleanly detaches the ODE body before remove() so we don't leave a dangling
// RBE pointer.
// -10000 ≈ 5s of free-fall before despawn. Far below any legit map
// gameplay floor. Mirror in sv_weapons.qc (PHYSDROP_VOID_Z) +
// cl_tosssmooth.qc void clamp.
const float PHYSPROP_VOID_Z    = -10000;
const float PHYSPROP_COORD_CAP = 65536;    // sanity cap for X/Y/Z — anything larger is runaway

void() PhysProp_VoidWatchdog =
{
	if (self.origin_z < PHYSPROP_VOID_Z
	 || fabs(self.origin_x) > PHYSPROP_COORD_CAP
	 || fabs(self.origin_y) > PHYSPROP_COORD_CAP
	 || fabs(self.origin_z) > PHYSPROP_COORD_CAP
	 // IEEE: NaN fails all comparisons with itself. Detect by self-compare.
	 || self.origin_x != self.origin_x
	 || self.origin_y != self.origin_y
	 || self.origin_z != self.origin_z)
	{
		if (cvar("sv_debug_physprops"))
			dprint(sprintf("[physprop] removing %s at %v (escaped world bounds)\n",
				self.classname, self.origin));
		physics_enable(self, FALSE);
		remove(self);
		return;
	}

	// Runtime stuck-despawn — if the prop's CENTER has been embedded in
	// BSP for >5 seconds (rare; happens when a moving brush shoves the
	// barrel into a wall), remove it rather than trying to unstick.
	// pointcontents-only check (W_PhysDropIsEmbedded uses center, not
	// bbox) so a barrel resting on its side with a slight floor overlap
	// doesn't get despawned. 5s is more lenient than the drop's 2s
	// because barrels are mapper-placed and worth keeping if possible.
	if (cvar("sv_phys_unstick") && W_PhysDropStuckDuration(self) > 5)
	{
		if (cvar("sv_debug_physprops"))
			dprint(sprintf("[physprop] removing %s at %v (stuck in BSP > 5s)\n",
				self.classname, self.origin));
		physics_enable(self, FALSE);
		remove(self);
		return;
	}

	self.nextthink = time + 1;
};

// phys_barrel_registercvars removed — physprop cvars are now in the
// shared table (shared/sh_cvar_table.qc CVar_Init under "ODE physics").

void() phys_barrel_precache =
{
	precache_model("models/props/barrel.iqm");
	precache_model("models/props/can.mdl");   // no can.iqm in models/props/ yet
	// ODE attach is deferred to the first StartFrame tick — the plug_load
	// localcmd queued in worldspawn hasn't run yet at precache time, so
	// calling physics_supported(TRUE) here returns 0 and the world's RBE
	// pointer stays null even after the plugin finishes loading.
};

// Common setup shared by barrel and can once the bbox + origin + solid/geomtype
// are in place. Caller must set b.solid and (if needed) b.geomtype before
// calling this — physics_enable() locks those in when the ODE body is built.
void(entity b) phys_prop_finalise =
{
	b.movetype = MOVETYPE_PHYSICS;

	b.friction = cvar("sv_physprop_friction");
	// Bouncing off — bouncefactor/stop combined with stiff contacts amplifies
	// numerical noise. Damping handles energy bleed-off cleanly instead.
	b.bouncefactor = 0;
	b.bouncestop = 0;
	b.erp = cvar("sv_physprop_erp");
	b.damp_linear = PhysProp_SafeDamp("sv_physprop_damp_lin");
	b.damp_angular = PhysProp_SafeDamp("sv_physprop_damp_ang");
	b.max_angular = 20;

	b.use = phys_barrel_use;
	b.think = PhysProp_VoidWatchdog;
	b.nextthink = time + 1;

	physics_enable(b, TRUE);
};

void(entity owner) phys_barrel_spawn_infront =
{
	entity b;
	vector fwd, target, start_high, end_low, ground;
	float dist = 128;
	float search_up = 256;
	float search_down = 4096;
	float drop_height = 32;

	makevectors(owner.v_angle);
	fwd = v_forward;
	fwd_z = 0;
	fwd = normalize(fwd);

	target = owner.origin + fwd * dist;
	start_high = target;
	start_high_z = target_z + search_up;
	end_low = start_high;
	end_low_z = start_high_z - search_down;

	traceline(start_high, end_low, MOVE_NORMAL, owner);
	if (trace_fraction >= 1.0)
	{
		sprint(owner, PRINT_HIGH, "spawnbarrel: no ground found in front\n");
		return;
	}
	ground = trace_endpos;

	b = spawn();
	b.classname = "phys_barrel";
	setmodel(b, "models/props/barrel.iqm");

	// Load-confirmation dprint — names the file FTE actually committed to and
	// the engine's modelindex slot, so any "is this really the file I edited?"
	// question is answered by reading console. Native mins/maxs let us
	// cross-check against viewthing.
	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] barrel loaded: model='%s' modelindex=%g native mins=%v maxs=%v\n",
			b.model, b.modelindex, b.mins, b.maxs));

	// SOLID_PHYSICS_TRIMESH — ODE uses the IQM's triangle mesh as its
	// collision shape, so prop-vs-world contacts track the visible mesh
	// exactly through any rotation.
	//
	// AABB sized to enclose the rotating mesh's bounding sphere.
	// Mesh half-extents (15.4, 14.4, 22.6) → bounding sphere radius
	// sqrt(15.4² + 14.4² + 22.6²) ≈ 31. Use ±32 with a 1qu safety margin
	// so any rotation stays inside the AABB. Dim filter (below) makes the
	// AABB non-blocking for the player, so the slack volume is invisible.
	setsize(b, '-32 -32 -32', '32 32 32');
	setorigin(b, ground + '0 0 1' * (-b.mins_z + drop_height));
	b.angles = '0 0 0';
	b.mass = cvar("sv_physprop_mass");
	b.solid = SOLID_PHYSICS_TRIMESH;
	// No dim filter — engine patch in world.c makes pmove use mesh narrowphase
	// for SOLID_PHYSICS_TRIMESH, so player passes through AABB empty space and
	// stops only at the actual mesh edge.

	phys_prop_finalise(b);

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] barrel spawned at %v\n", b.origin));
};

void(entity owner) phys_can_spawn_infront =
{
	entity b;
	vector fwd, target, start_high, end_low, ground;
	float dist = 64;
	float search_up = 256;
	float search_down = 4096;
	float drop_height = 16;

	makevectors(owner.v_angle);
	fwd = v_forward;
	fwd_z = 0;
	fwd = normalize(fwd);

	target = owner.origin + fwd * dist;
	start_high = target;  start_high_z = target_z + search_up;
	end_low    = start_high;  end_low_z  = start_high_z - search_down;

	traceline(start_high, end_low, MOVE_NORMAL, owner);
	if (trace_fraction >= 1.0)
	{
		sprint(owner, PRINT_HIGH, "spawncan: no ground found in front\n");
		return;
	}
	ground = trace_endpos;

	b = spawn();
	b.classname = "phys_can";
	setmodel(b, "models/props/can.mdl");   // change to .iqm when one exists

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] can loaded: model='%s' modelindex=%g native mins=%v maxs=%v\n",
			b.model, b.modelindex, b.mins, b.maxs));

	// Cube AABB enclosing the rotating mesh. Same TRIMESH+dim-filter pattern
	// as the barrel. GenerateCollisionMesh works with .mdl too (pulls verts
	// from the model object regardless of format), so the can gets accurate
	// mesh collision even without an .iqm.
	setsize(b, '-12 -12 -12', '12 12 12');
	setorigin(b, ground + '0 0 1' * (-b.mins_z + drop_height));
	b.angles = '0 0 0';
	b.mass = 2;  // can is light by design — hardcoded, not cvar-driven
	b.solid = SOLID_PHYSICS_TRIMESH;
	// No dim filter — engine patch handles mesh narrowphase.

	phys_prop_finalise(b);

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] can spawned at %v\n", b.origin));
};

// Called from hitscan paths after the weapon's traceline. If the hit ent is a
// physics prop, apply a world-space force at the hit point.
float(vector shot_dir, float damage) PhysProp_TryPushFromTrace =
{
	if (trace_ent == world) return FALSE;
	if (trace_ent.weapon && trace_ent.weapon_physdrop_sleeping)
		W_PhysDropWake(trace_ent);
	if (trace_ent.movetype != MOVETYPE_PHYSICS) return FALSE;

	vector force = shot_dir * (damage * cvar("sv_physprop_hit_force"));

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] bullet ent=%g force=%v at=%v\n",
			num_for_edict(trace_ent), force, trace_endpos));

	physics_addforce(trace_ent, force, trace_endpos);
	return TRUE;
};

// Radius-based explosion push.  Mirror of PhysProp_TryPushFromTrace for
// the bullet path, but iterates findradius and applies an outward
// impulse to every nearby phys-drop / phys-prop.  Sleeping weapon drops
// are woken first (so W_PhysDropWake flips movetype to MOVETYPE_PHYSICS
// and the impulse takes effect on the same frame).  Force scales with
// linear distance falloff and an upward bias proportional to radius,
// so a grenade lifts debris off the ground rather than just shoving
// it sideways.
//
// Called from W_GrenadeExplode / W_RPGExplode / W_HLGrenadeExplode /
// W_HLSMGGrenadeExplode etc.  `peak_damage` is the explosion's
// centre-blast damage (the same value used in the radius-damage loop).
void(vector center, float radius, float peak_damage) PhysProp_TryRadiusPush =
{
	if (radius <= 0 || peak_damage <= 0) return;

	float force_scale = cvar("sv_physprop_explosion_force");
	if (force_scale <= 0) force_scale = 25000;

	entity e = findradius(center, radius);
	while (e)
	{
		// Wake sleeping weapon drops first so the impulse below
		// actually takes effect (post-wake their movetype is
		// MOVETYPE_PHYSICS and ODE integrates the force).
		if (e.weapon && e.weapon_physdrop_sleeping)
			W_PhysDropWake(e);

		if (e.movetype == MOVETYPE_PHYSICS)
		{
			vector to_ent = e.origin - center;
			float dist = vlen(to_ent);
			float falloff = 1.0 - (dist / radius);
			if (falloff > 0)
			{
				// Upward bias proportional to radius — flat-ground props
				// lift instead of skidding.  The bias is added to the
				// raw vector before normalizing so it scales sensibly
				// with how far away the prop is.
				vector dir = to_ent;
				dir_z += radius * 0.3;
				dir = normalize(dir);

				vector force = dir * peak_damage * force_scale * falloff;

				if (cvar("sv_debug_physprops"))
					dprint(sprintf("[physprop] explosion ent=%g force=%v dist=%g falloff=%.2f\n",
						num_for_edict(e), force, dist, falloff));

				physics_addforce(e, force, e.origin);
			}
		}

		e = e.chain;
	}
};

// .use handler: fired by SV_UseTarget when the player presses +use aimed at
// the prop. `activator` is the player; `self` is the prop. Applies a push in
// the player's view direction, scaled by base force + player velocity. Applied
// at origin (centre of mass) so the push is pure translation, no tipping.
void() phys_barrel_use =
{
	vector fwd, force;
	float base = cvar("sv_physprop_use_force");
	float velk = cvar("sv_physprop_use_velmult");

	makevectors(activator.v_angle);
	fwd = v_forward;

	force = fwd * base + activator.velocity * velk;

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] +use prop=%g force=%v\n",
			num_for_edict(self), force));

	physics_addforce(self, force, self.origin);
};

float() PhysProp_CountActive =
{
	entity e;
	float n = 0;
	e = nextent(world);
	while (e)
	{
		if (e.movetype == MOVETYPE_PHYSICS
		 && (e.classname == "phys_barrel" || e.classname == "phys_can"))
			n = n + 1;
		e = nextent(e);
	}
	return n;
};
