//
//	sv_physprop.qc - server-authoritative ODE rigid-body props
//
//	Tunable cvars (live, no recompile):
//	  sv_physprop_hit_force   force per damage point applied by bullets
//	  sv_physprop_push_force  force applied when a player walks into a prop
//	  sv_physprop_mass        barrel mass (only applied on spawn)
//	  sv_physprop_erp         contact ERP offset (negative softens contacts)
//	  sv_physprop_damp_lin    linear damping
//	  sv_physprop_damp_ang    angular damping
//	  sv_physprop_friction    ground friction
//	  sv_debug_physprops      1 prints hit + push diagnostics
//
//	Useful engine cvars:
//	  physics_ode_contact_erp        default 0.96 - lower = softer contacts globally
//	  physics_ode_contactsurfacelayer default 0   - set 0.5 to reduce jitter
//	  physics_ode_iterationsperframe default 10   - solver cost dial
//	  physics_ode_autodisable        default 1    - sleep idle bodies
//	  r_showbboxes 1                              - draw entity AABBs (essential for tuning)

// FTE physics fields not declared in the project's fteextensions.qc.
.float damp_linear;
.float damp_angular;
.float max_angular;
.float dimension_solid;
.float dimension_hit;

const float PHYSPROP_DIM = 2;  // dimension bit for physics props (player is on bit 1)

// Shape metadata stored on each prop for QC-side collision math.
const float PPSHAPE_BOX      = 0;
const float PPSHAPE_CYLINDER = 1;
const float PPSHAPE_CAPSULE  = 2;
const float PPSHAPE_SPHERE   = 3;
const float PPAXIS_X = 0;
const float PPAXIS_Y = 1;
const float PPAXIS_Z = 2;
.float ppshape;
.float ppaxis;
.float pp_radius;
.float pp_halflen;

// FTE explicit-axis shape constants (from ftedefs/fteextensions.qc).
const float GEOMTYPE_CAPSULE_X  = 6;
const float GEOMTYPE_CAPSULE_Y  = 7;
const float GEOMTYPE_CAPSULE_Z  = 8;
const float GEOMTYPE_CYLINDER_X = 9;
const float GEOMTYPE_CYLINDER_Y = 10;
const float GEOMTYPE_CYLINDER_Z_ = 11;  // trailing _ to avoid any header clash

void() phys_barrel_use;

void() phys_barrel_registercvars =
{
	registercvar("sv_physprop_hit_force", "8000");
	registercvar("sv_physprop_push_force", "8000");
	registercvar("sv_physprop_push_height", "0.6"); // 0=center, 1=top — lever arm for tipping
	registercvar("sv_physprop_passthrough", "1");
	registercvar("sv_physprop_mass", "20");
	registercvar("sv_physprop_erp", "0");
	// ODE applies damping per physics substep, not per second — values here
	// are multiplied (1-damp) each ~10ms tick.  0.01 bleeds velocity slowly
	// and looks like natural air resistance; 0.2 reads as "moving through
	// treacle" and was the cause of the slow-fall regression.
	registercvar("sv_physprop_damp_lin", "0.01");
	registercvar("sv_physprop_damp_ang", "0.01");
	// Player recoil on contact: bounce factor + minimum kick velocity (qu/s).
	registercvar("sv_physprop_player_bounce", "0.4");
	registercvar("sv_physprop_player_minkick", "100");
	// Player recoil scale: fraction of push_force converted to player velocity
	// when overlapping a prop. Lower than 1 because player mass is implicit.
	registercvar("sv_physprop_player_kickback", "0.005");
	registercvar("sv_physprop_friction", "1.0");
	// Shape: "box" | "capsule" | "cylinder" | "sphere"
	registercvar("sv_physprop_shape", "cylinder");
	// Explicit cylinder/capsule axis: "x" | "y" | "z" (default z).
	// Use this if your model's cylindrical axis isn't Z-aligned.
	registercvar("sv_physprop_axis", "y");
	// Proximity radius for player-push (in addition to strict bbox overlap).
	registercvar("sv_physprop_push_radius", "40");
	// +use push: base force + player-velocity boost (scaled by this factor).
	registercvar("sv_physprop_use_force", "800");
	registercvar("sv_physprop_use_velmult", "800");
	// 0 = disable QC-side player↔prop depenetration (revert to AABB-only).
	registercvar("sv_physprop_qc_collide", "1");
};

void() phys_barrel_precache =
{
	phys_barrel_registercvars();
	precache_model("models/props/barrel.mdl");
	precache_model("models/props/can.mdl");
	// ODE attach is deferred to the first StartFrame tick — the plug_load
	// localcmd queued in worldspawn hasn't run yet at precache time, so
	// calling physics_supported(TRUE) here returns 0 and the world's RBE
	// pointer stays null even after the plugin finishes loading.
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
	setmodel(b, "models/props/barrel.mdl");

	dprint(sprintf("[physprop] iqm native mins=%v maxs=%v\n", b.mins, b.maxs));

	// Symmetric bbox around entity.origin — model is authored origin-at-centre,
	// so geomcenter = 0 = entity.origin = model centre. Rotation pivots match.
	// FTE cylinder/capsule formula: radius = min(other two axes)*0.5,
	// length = geomsize[axis] - 2*radius. So the chosen axis must be the
	// longest of the bbox, otherwise length becomes 0 and ODE clamps to 1
	// (pancake), which falls through floors.
	string shape = cvar_string("sv_physprop_shape");
	string axis  = cvar_string("sv_physprop_axis");
	// Save shape metadata for QC-side depenetration. Numbers below match the
	// bbox half-extents and ODE's length = axisExtent - 2*radius formula.
	if      (axis == "x") b.ppaxis = PPAXIS_X;
	else if (axis == "y") b.ppaxis = PPAXIS_Y;
	else                  b.ppaxis = PPAXIS_Z;

	if (shape == "cylinder")
	{
		// radius 16, length 44 (bbox 32×32×76 on chosen axis).
		if      (axis == "x") setsize(b, '-38 -16 -16', '38 16 16');
		else if (axis == "y") setsize(b, '-16 -38 -16', '16 38 16');
		else                  setsize(b, '-16 -16 -38', '16 16 38');
		b.ppshape = PPSHAPE_CYLINDER;
		b.pp_radius = 16;
		b.pp_halflen = 22;  // length 44 / 2
	}
	else if (shape == "capsule")
	{
		if      (axis == "x") setsize(b, '-27 -18 -18', '27 18 18');
		else if (axis == "y") setsize(b, '-18 -27 -18', '18 27 18');
		else                  setsize(b, '-18 -18 -27', '18 18 27');
		b.ppshape = PPSHAPE_CAPSULE;
		b.pp_radius = 18;
		b.pp_halflen = 9;   // capsule total = 2*halflen + 2*radius = 18 + 36 = 54
	}
	else if (shape == "sphere")
	{
		setsize(b, '-23 -23 -23', '23 23 23');
		b.ppshape = PPSHAPE_SPHERE;
		b.pp_radius = 23;
		b.pp_halflen = 0;
	}
	else
	{
		setsize(b, '-23 -23 -23', '23 23 23');
		b.ppshape = PPSHAPE_BOX;
		b.pp_radius = 23;
		b.pp_halflen = 23;
	}

	// Half-extent below entity.origin — origin must be lifted so the bbox
	// bottom (mins.z) lands on/above the ground instead of below.
	float half_z = -b.mins_z;
	setorigin(b, ground + '0 0 1' * (half_z + drop_height));
	b.angles = '0 0 0';

	if (shape == "cylinder")
	{
		// ODE's cylinder-vs-cylinder collider is gated behind dLIBCCD_CYL_CYL
		// at engine build time and isn't compiled into the shipped FTE binary,
		// so two cylinders phase through each other. Cylinder-vs-world and
		// cylinder-vs-other-shapes still work — we accept the pass-through as
		// intentional here.
		b.solid = SOLID_PHYSICS_CYLINDER;
		if      (axis == "x") b.geomtype = GEOMTYPE_CYLINDER_X;
		else if (axis == "y") b.geomtype = GEOMTYPE_CYLINDER_Y;
		else                  b.geomtype = GEOMTYPE_CYLINDER_Z_;
	}
	else if (shape == "capsule")
	{
		b.solid = SOLID_PHYSICS_CAPSULE;
		if      (axis == "x") b.geomtype = GEOMTYPE_CAPSULE_X;
		else if (axis == "y") b.geomtype = GEOMTYPE_CAPSULE_Y;
		else                  b.geomtype = GEOMTYPE_CAPSULE_Z;
	}
	else if (shape == "sphere")   b.solid = SOLID_PHYSICS_SPHERE;
	else                           b.solid = SOLID_PHYSICS_BOX;
	b.movetype = MOVETYPE_PHYSICS;

	b.mass = cvar("sv_physprop_mass");
	b.friction = cvar("sv_physprop_friction");
	// Bouncing off — bouncefactor/stop combined with stiff contacts amplifies
	// numerical noise. Damping handles energy bleed-off cleanly instead.
	b.bouncefactor = 0;
	b.bouncestop = 0;
	b.erp = cvar("sv_physprop_erp");
	b.damp_linear = cvar("sv_physprop_damp_lin");
	b.damp_angular = cvar("sv_physprop_damp_ang");
	b.max_angular = 20;

	// Dimension filter. With passthrough=1 (default), drop bit 1 from both
	// fields so pmove notouch (sv_user.c:6970, uses player.dim_solid & ent.dim_hit)
	// AND tracebox clip (world.c:1561, uses passedict.dim_hit & ent.dim_solid)
	// both skip the barrel. Hitscans OR bit 2 into the shooter's dim_hit so
	// bullets still connect. Passthrough=0 restores classic blocking for A/B.
	if (cvar("sv_physprop_passthrough"))
	{
		// dim_solid = bit 2 only — player tracebox skips us (player.dim_hit=1
		// & barrel.dim_solid=2 = 0). dim_hit set wide so ODE's nearCallback
		// always passes both directions for barrel-vs-barrel and barrel-vs-world.
		b.dimension_solid = PHYSPROP_DIM;
		b.dimension_hit   = 255;
	}
	else
	{
		b.dimension_solid = 1;
		b.dimension_hit   = 1;
	}

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] spawn: dim_solid=%g dim_hit=%g | owner.dim_solid=%g dim_hit=%g\n",
			b.dimension_solid, b.dimension_hit,
			owner.dimension_solid, owner.dimension_hit));

	b.use = phys_barrel_use;

	physics_enable(b, TRUE);
};

// Small lightweight prop — cylinder standing upright on Z.  Hardcoded
// dimensions and mass; respects the shared damping/erp/push cvars so a
// can and a barrel tune together.  Shape isn't cvar-configurable like
// the barrel's — the can IS a small cylinder by design.
void(entity owner) phys_can_spawn_infront =
{
	entity b;
	vector fwd, target, start_high, end_low, ground;
	float dist = 64;
	float search_up = 256;
	float search_down = 4096;
	float drop_height = 16;

	dprint("[physprop] spawncan called\n");

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
	setmodel(b, "models/props/can.mdl");
	dprint(sprintf("[physprop] can setmodel: modelindex=%g mins=%v maxs=%v\n",
		b.modelindex, b.mins, b.maxs));

	// Cylinder, axis follows sv_physprop_axis so the .mdl's long direction
	// can match the physics length.  Bbox 8x8x20 on the long axis (radius 4,
	// length 12 after the FTE formula length = axisExtent - 2*radius).
	string axis = cvar_string("sv_physprop_axis");
	if      (axis == "x") { b.ppaxis = PPAXIS_X; setsize(b, '-10 -4 -4', '10 4 4'); b.geomtype = GEOMTYPE_CYLINDER_X;  }
	else if (axis == "y") { b.ppaxis = PPAXIS_Y; setsize(b, '-4 -10 -4', '4 10 4'); b.geomtype = GEOMTYPE_CYLINDER_Y;  }
	else                  { b.ppaxis = PPAXIS_Z; setsize(b, '-4 -4 -10', '4 4 10'); b.geomtype = GEOMTYPE_CYLINDER_Z_; }
	b.ppshape = PPSHAPE_CYLINDER;
	b.pp_radius = 4;
	b.pp_halflen = 6;

	setorigin(b, ground + '0 0 1' * (-b.mins_z + drop_height));
	b.angles = '0 0 0';

	b.solid = SOLID_PHYSICS_CYLINDER;
	b.movetype = MOVETYPE_PHYSICS;

	b.mass = 2;
	b.friction = cvar("sv_physprop_friction");
	b.bouncefactor = 0;
	b.bouncestop = 0;
	b.erp = cvar("sv_physprop_erp");
	b.damp_linear = cvar("sv_physprop_damp_lin");
	b.damp_angular = cvar("sv_physprop_damp_ang");
	b.max_angular = 20;

	if (cvar("sv_physprop_passthrough"))
	{
		b.dimension_solid = PHYSPROP_DIM;
		b.dimension_hit   = 255;
	}
	else
	{
		b.dimension_solid = 1;
		b.dimension_hit   = 1;
	}

	b.use = phys_barrel_use;
	physics_enable(b, TRUE);
	dprint(sprintf("[physprop] can spawned at %v (ode=%g)\n",
		b.origin, cvar("sv_ode_loaded")));
};

// Called from hitscan paths. Temporarily allow the shooter's traces to hit
// physprop dimension, run trace, restore. Returns nothing; trace_* globals hold the result.
void(vector start, vector end, float tracetype, entity ignore) PhysProp_TraceLine =
{
	float saved = ignore.dimension_hit;
	ignore.dimension_hit = saved | PHYSPROP_DIM;
	traceline(start, end, tracetype, ignore);
	ignore.dimension_hit = saved;
};

// Called from hitscan paths after the weapon's traceline. If the hit ent is a
// physics prop, apply a world-space force at the hit point.
float(vector shot_dir, float damage) PhysProp_TryPushFromTrace =
{
	if (trace_ent == world) return FALSE;
	if (trace_ent.movetype != MOVETYPE_PHYSICS) return FALSE;

	vector force = shot_dir * (damage * cvar("sv_physprop_hit_force"));

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] bullet ent=%g force=%v at=%v\n",
			num_for_edict(trace_ent), force, trace_endpos));

	physics_addforce(trace_ent, force, trace_endpos);
	return TRUE;
};

// Called from StartFrame each server tick. For every player with non-zero
// velocity, scan nearby physics props; if player's bbox overlaps the prop's
// bbox, push the prop in the direction of player motion. This replaces the
// ODE kinematic-contact that we disabled via dimension filtering.
void() PhysProp_RunPlayerPush =
{
	entity plr, prop;
	float force_scale = cvar("sv_physprop_push_force");
	float debug = cvar("sv_debug_physprops");
	if (force_scale <= 0) return;

	// Iterate the mod's explicit player chain (populated in sv_player.qc).
	plr = player_chain_head;
	while (plr)
	{
		if (!plr.is_dead)
		{
			// Expand search radius to cover player bbox + barrel half-extents.
			prop = findradius(plr.origin, 96);
			while (prop)
			{
				if (prop.movetype == MOVETYPE_PHYSICS)
				{
					vector pmin = plr.origin + plr.mins;
					vector pmax = plr.origin + plr.maxs;
					vector bmin = prop.origin + prop.mins;
					vector bmax = prop.origin + prop.maxs;

					// Fire push if bboxes overlap OR if player is within push_radius
					// of the prop centre — this keeps push working even when the
					// player is stopped at the AABB edge (dim passthrough not sticking).
					float push_radius = cvar("sv_physprop_push_radius");
					float close = vlen(prop.origin - plr.origin) <= push_radius;
					float overlap = (pmax_x >= bmin_x && pmin_x <= bmax_x
					              && pmax_y >= bmin_y && pmin_y <= bmax_y
					              && pmax_z >= bmin_z && pmin_z <= bmax_z);
					if (overlap || close)
					{
						// Direction = from player center to prop center (horizontal).
						vector dir = prop.origin - plr.origin;
						dir_z = 0;
						if (vlen(dir) < 0.01)
						{
							makevectors(plr.v_angle);
							dir = v_forward;
							dir_z = 0;
						}
						if (vlen(dir) > 0.01) dir = normalize(dir);

						// Only proximity-push if player is facing the prop.
						makevectors(plr.v_angle);
						vector fwd = v_forward; fwd_z = 0;
						if (vlen(fwd) > 0.01) fwd = normalize(fwd);
						float facing_ok = overlap || (dir * fwd >= 0.3);
						if (facing_ok) {

						// Full force while overlapping — no velocity scaling
						// (custom pmove's self.velocity is unreliable here).
						vector pushforce = dir * force_scale;

						// Apply force above the center of mass so a horizontal
						// push tips the prop forward. Height is a fraction of
						// the prop's upper half; 0=center, 1=top of bbox.
						float height_frac = cvar("sv_physprop_push_height");
						vector hitpoint = prop.origin;
						hitpoint_z = prop.origin_z + prop.maxs_z * height_frac;

						if (debug)
							dprint(sprintf("[physprop] push prop=%g vel=%g force=%v\n",
								num_for_edict(prop), vlen(plr.velocity), pushforce));

						physics_addforce(prop, pushforce, hitpoint);

						// Push the player AWAY from the prop's centre.
						// awayfromprop = player - prop, normalized.
						vector awayfromprop = plr.origin - prop.origin;
						awayfromprop_z = 0;
						if (vlen(awayfromprop) > 0.01)
						{
							awayfromprop = normalize(awayfromprop);
							float reaction = cvar("sv_physprop_player_kickback");
							plr.velocity = plr.velocity + awayfromprop * (force_scale * reaction);
						}
						} // facing_ok
					}
				}
				prop = prop.chain;
			}
		}
		plr = plr.player_chain_next;
	}
};

// .use handler: fired by SV_UseTarget when the player presses +use aimed at
// the prop. `activator` is the player; `self` is the prop. Applies a push in
// the player's view direction, scaled by base force + player velocity.
void() phys_barrel_use =
{
	vector fwd, force, hitpoint;
	float base  = cvar("sv_physprop_use_force");
	float velk  = cvar("sv_physprop_use_velmult");

	makevectors(activator.v_angle);
	fwd = v_forward;

	force = fwd * base + activator.velocity * velk;
	hitpoint = self.origin;
	hitpoint_z = self.origin_z + self.maxs_z * cvar("sv_physprop_push_height");

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] +use prop=%g force=%v\n",
			num_for_edict(self), force));

	physics_addforce(self, force, hitpoint);
};

// =====================================================================
//  PhysProp_DepenetratePlayer
//  Called from PM_PlayerMoveStep just before commit. Pushes the player
//  out of the actual rotated shape of nearby physics props (cylinder,
//  capsule, sphere). Box uses AABB fallback (no rotation handling).
//  Also applies an equal-and-opposite force to the prop so player
//  contact moves it.
//
//  Reads/writes pm_origin (global, defined in sh_pmove.qc).
// =====================================================================

// Local-axis world vector for a prop given its angles + which axis is its
// length axis. Returns unit vector in world space.
vector(entity prop) PhysProp_GetAxisVector =
{
	makevectors(prop.angles);
	if (prop.ppaxis == PPAXIS_X) return v_forward;
	if (prop.ppaxis == PPAXIS_Y) return v_right * -1;  // QC v_right is left-handed; flip
	return v_up;
};

void(entity plr) PhysProp_DepenetratePlayer =
{
	if (!cvar("sv_physprop_qc_collide")) return;

	entity prop;
	vector pcenter, ppos, pvel;
	float prad = 16;             // player capsule radius (matches std hull width)
	float phalfh;
	float push_force = cvar("sv_physprop_push_force");
	float debug = cvar("sv_debug_physprops");
	float iter;

	// Operate on plr.origin / plr.velocity directly — pmove has already
	// committed pm_origin/pm_velocity here, and this avoids cross-file
	// global aliasing concerns with pm_origin/pm_velocity.
	ppos = plr.origin;
	pvel = plr.velocity;
	phalfh = (plr.maxs_z - plr.mins_z) * 0.5;
	pcenter = ppos;
	pcenter_z += plr.mins_z + phalfh;

	// Run the depen pass twice so a push out of one prop into another resolves.
	iter = 0;
	while (iter < 2)
	{
		prop = findradius(pcenter, 96);
		while (prop)
		{
			if (prop.movetype == MOVETYPE_PHYSICS && prop.ppshape != PPSHAPE_BOX)
			{
				vector relp = pcenter - prop.origin;
				float overlap_amt = 0;
				vector pushdir = '0 0 0';
				vector contact = prop.origin;

				if (prop.ppshape == PPSHAPE_SPHERE)
				{
					float d = vlen(relp);
					float minsep = prop.pp_radius + prad;
					if (d < minsep && d > 0.0001)
					{
						pushdir = relp * (1.0 / d);
						overlap_amt = minsep - d;
						contact = prop.origin + pushdir * prop.pp_radius;
					}
				}
				else  // CYLINDER or CAPSULE
				{
					vector axis = PhysProp_GetAxisVector(prop);
					float ax_t = relp * axis;
					float ax_clamped = ax_t;
					if (ax_clamped >  prop.pp_halflen) ax_clamped =  prop.pp_halflen;
					if (ax_clamped < -prop.pp_halflen) ax_clamped = -prop.pp_halflen;

					vector axpoint = prop.origin + axis * ax_clamped;
					vector radv = pcenter - axpoint;
					radv_z = radv_z;  // keep 3D so tall player vs lying barrel resolves vertically too
					float rd = vlen(radv);
					float minsep_cy = prop.pp_radius + prad;

					// For cylinder, also require axial overlap (within halflen + player half).
					float axial_ok = TRUE;
					if (prop.ppshape == PPSHAPE_CYLINDER)
					{
						if (fabs(ax_t) > prop.pp_halflen + phalfh)
							axial_ok = FALSE;
					}

					if (axial_ok && rd < minsep_cy && rd > 0.0001)
					{
						pushdir = radv * (1.0 / rd);
						overlap_amt = minsep_cy - rd;
						contact = axpoint + pushdir * prop.pp_radius;
					}
				}

				if (overlap_amt > 0)
				{
					// Depenetrate along the surface normal.
					ppos = ppos + pushdir * (overlap_amt + 0.03125);
					pcenter = pcenter + pushdir * (overlap_amt + 0.03125);

					// Apply opposite force to the prop at contact point.
					if (push_force > 0)
						physics_addforce(prop, pushdir * -push_force, contact);

					// Player recoil: reverse the into-surface velocity component
					// scaled by restitution, with a minimum kick so even slow
					// approaches feel a bump.
					float restitution = cvar("sv_physprop_player_bounce");
					float minkick = cvar("sv_physprop_player_minkick");
					float vinto = pvel * pushdir;
					if (vinto < 0)
					{
						if (vinto > -minkick) vinto = -minkick;
						pvel = pvel - pushdir * vinto * (1 + restitution);
					}

					if (debug && iter == 0)
						dprint(sprintf("[physprop] depen prop=%g amt=%g push=%v\n",
							num_for_edict(prop), overlap_amt, pushdir));
				}
			}
			prop = prop.chain;
		}
		iter = iter + 1;
	}

	// Commit any position/velocity adjustment back to the player entity.
	if (ppos != plr.origin)
		setorigin(plr, ppos);
	plr.velocity = pvel;
};

float() PhysProp_CountActive =
{
	entity e;
	float n = 0;
	e = findchainfloat(movetype, MOVETYPE_PHYSICS);
	while (e) { n = n + 1; e = e.chain; }
	return n;
};
