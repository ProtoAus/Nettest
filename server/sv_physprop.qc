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

// Overlap tests — forward-declared so phys_files_think (above their definitions)
// can call them for the post-drop re-solidify / shove-apart pass.
float(entity a, entity b) Carry_BBoxOverlap;
float(entity prop, entity player) Carry_OBBOverlap;

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
	// Properly-made MP barrels (each ships a .acd convex-decomposition sidecar); spawnbarrel +
	// spawnflood pick one at random via PhysBarrel_RandomModel().  MUST be precached before setmodel.
	// (The old models/props/barrel.iqm precache is gone: that file does not exist and was never
	//  setmodel'd — it only produced an "Unable to load" on every map load.)
	precache_model("models/mega/containers/metal_barrel_mp_1.iqm");
	precache_model("models/mega/containers/metal_barrel_mp_2.iqm");
	precache_model("models/mega/containers/metal_barrel_mp_3.iqm");
	// Cans — same deal as the barrels (random pick, each ships a .acd).  Replaces the old
	// models/props/can.mdl, which did not exist: spawncan was setmodel'ing a missing file and
	// spawning an invisible null-model prop.  See PhysCan_RandomModel.
	precache_model("models/mega/props/tin_can_mp_1_rusty.iqm");
	precache_model("models/mega/props/tin_can_mp_1_rusty_1.iqm");
	precache_model("models/bunkers/canned_food_3.iqm");
	precache_model("models/bunkers/canned_food_4.iqm");
	precache_model("models/bunkers/canned_food_5.iqm");
	// Carriable filecabinet — IQM only.  The legacy models/props/filecabinet.mdl fallback is gone
	// (the file does not exist), which is also a collision UPGRADE: HL-studio .mdl can't build an
	// ODE collision mesh (the engine has no mod_halflife case) so it fell back to a BOX, whereas
	// the IQM (mod_alias) supports both an ODE collision mesh and NativeTrace player collision —
	// the player collides with the actual ROTATED mesh.
	precache_model("models/props/filecabinet/filecabinet.iqm");
	// Cabinet contact sounds — soft on gentle contact, hard on fast (see
	// PhysFiles_EmitImpact).  Played server-side via sound() so all players hear.
	precache_sound("sounds/impacts/metal_box_impact_soft1.wav");
	precache_sound("sounds/impacts/metal_box_impact_soft2.wav");
	precache_sound("sounds/impacts/metal_box_impact_soft3.wav");
	precache_sound("sounds/impacts/metal_box_impact_hard1.wav");
	precache_sound("sounds/impacts/metal_box_impact_hard2.wav");
	precache_sound("sounds/impacts/metal_box_impact_hard3.wav");
	precache_sound("sounds/impacts/metal_box_scrape_rough_loop1.wav");   // looping scrape while sliding
	precache_sound("sounds/null.wav");                                   // silent sample to cancel the scrape loop
	// Cabinet +use grab "clunk" (Carry_TryGrab).
	precache_sound("sounds/impacts/metal_solid_impact_soft1.wav");
	precache_sound("sounds/impacts/metal_solid_impact_soft2.wav");
	precache_sound("sounds/impacts/metal_solid_impact_soft3.wav");
	// Weapon-drop FX sound set (po_fx_soundset 1): impacts + looping scrape.
	precache_sound("sounds/impacts/weapon_impact_soft1.wav");
	precache_sound("sounds/impacts/weapon_impact_soft2.wav");
	precache_sound("sounds/impacts/weapon_impact_soft3.wav");
	precache_sound("sounds/impacts/weapon_impact_hard1.wav");
	precache_sound("sounds/impacts/weapon_impact_hard2.wav");
	precache_sound("sounds/impacts/weapon_impact_hard3.wav");
	precache_sound("sounds/impacts/soda_can_scrape_rough_loop1.wav");
	// ODE attach is deferred to the first StartFrame tick — the plug_load
	// localcmd queued in worldspawn hasn't run yet at precache time, so
	// calling physics_supported(TRUE) here returns 0 and the world's RBE
	// pointer stays null even after the plugin finishes loading.
};

// ---------------------------------------------------------------------------
// PVS policy for the phys_files_Send CSQC mirror (barrel / can / cabinet /
// prop_physics / prop_car).  Call AFTER assigning SendEntity.
//
// These mirrors used to be hard-coded PVSF_NOREMOVE.  That flag does NOT exempt them from
// PVS on the send side — its mode bits are 0 == PVSF_NORMALPVS, so the server already
// stopped SENDING updates once the prop left your PVS — it only suppresses the REMOVE
// message (sv_ents.c).  So the client never got CSQC_Ent_Remove, kept the last snapshot
// forever, and its predraw went on re-adding it every frame: fly into the void and every
// prop_physics / prop_car hangs there frozen, while prop_static (a plain packet entity with
// no SendEntity) correctly despawns.  That asymmetry is the bug.
//
// The original intent was real, though: this mirror is the CLIENT's only collision hull for
// the prop (the engine-side rigid body is invisible to the CSQC pmove), so a mirror removed
// while you are near-but-just-outside PVS goes silently non-solid under you.  In practice
// that is the same trade prop_static already makes, and PVS here is the FAT PVS (adjacent
// leafs included), so the window is small.  sv_physprop_pvscull 0 restores the old
// always-resident behaviour if it ever bites.
//
// Re-entry needs no special handling: the engine clears the per-client PRESENT bit on a
// culled entity, so coming back into PVS forces a FULL baseline resend (not a delta) — a
// prop that came to rest while you were away arrives at its true resting pose even though
// the mod's own rest-latch fired long ago.  CSQC_PhysProp_Update's isnew branch reseeds the
// interpolation anchors, so there is no lerp-from-stale pop.  See CSQC_Ent_Remove
// (cl_main.qc) for the child-entity cleanup that culling makes mandatory.
// ---------------------------------------------------------------------------
void(entity b) PhysProp_ApplyPvsPolicy =
{
	if (cvar("sv_physprop_pvscull"))
		b.pvsflags = PVSF_NORMALPVS;   // PVS-culled AND removed on exit (like prop_static)
	else
		b.pvsflags = PVSF_NOREMOVE;    // legacy: once seen, never removed
};

// Common setup shared by barrel and can once the bbox + origin + solid/geomtype
// are in place. Caller must set b.solid and (if needed) b.geomtype before
// calling this — physics_enable() locks those in when the ODE body is built.
// Unified ODE setup for EVERY phys object — barrel, can, cabinet, weapon drop.
// The caller sets the per-object `po_*` flags + bbox + solid (+ angles/origin)
// FIRST, then calls this with the per-object mass + friction; this locks in the
// shared ODE tuning (bounce/erp/damping/dimension), picks .use by capability, and
// wakes the body.  The caller then sets max_angular + think + nextthink.
// (Was phys_prop_finalise — now also drives weapon drops via PhysObj_Setup.)
void(entity b, float obj_mass, float obj_friction) PhysObj_Setup =
{
	b.movetype = MOVETYPE_PHYSICS;
	b.mass     = obj_mass;
	b.friction = obj_friction;

	// Bouncing is shared + off by default (bounce 0 — stiff contacts + bounce
	// amplify numerical noise; damping bleeds energy cleanly).  bouncestop only
	// matters when bounce > 0.
	// Per-material bounce when a prop-material is resolved (sh_propmaterials.qc), else the shared cvar.
	b.bouncefactor = (b.po_material >= 0) ? PropMat_Restit(b.po_material) : cvar("sv_physprop_bounce");
	b.bouncestop   = cvar("sv_physprop_bouncestop");
	b.erp = cvar("sv_physprop_erp");
	// Divide damping by physics_ode_iterationsperframe: ODE applies damping ONCE PER
	// SUBSTEP (v *= 1-damp each substep), so N substeps/frame compound it ~N×.  Without
	// this, a high iterationsperframe over-damps the prop into a slow crawl ("stuck
	// moving slowly").  Dividing keeps the per-frame damping constant, so the cvar is
	// tuned once and stays consistent across iteration changes (like the hit force).
	float iter = cvar("physics_ode_iterationsperframe"); if (iter < 1) iter = 1;
	// Per-material damping multiplier (fabric damps hard = dead thud; metal least = rings/spins).
	float dmul = (b.po_material >= 0) ? PropMat_DampMult(b.po_material) : 1;
	b.damp_linear  = PhysProp_SafeDamp("sv_physprop_damp_lin")  * dmul / iter;
	b.damp_angular = PhysProp_SafeDamp("sv_physprop_damp_ang") * dmul / iter;
	b.max_angular  = 20;   // caller may override (weapon drops use 35)

	b.po_is_phys = TRUE;

	// +use: free props (barrel/can) get the shove; the cabinet (grabbed in
	// SV_PlayerTryUse before .use) and weapon drops (+use = pickup-swap) carry no
	// .use, so +use falls through to their own handling.
	if (b.po_carry_enabled || b.po_is_weapon_drop)
		b.use = __NULL__;
	else
		b.use = phys_barrel_use;

	// Dimension masks.  Weapon drops sit in PHYSDROP_DIM (player-passthrough so you
	// aren't blocked walking over a dropped gun); props are player-solid via the
	// default dimension (the cabinet moves to PHYSDROP_DIM only when grabbed).  Both
	// keep PHYSDROP_DIM in dimension_hit so a CARRIED prop still collides with them —
	// ODE's contact filter needs BOTH sides' hit-mask to overlap the other's
	// solid-mask (com_phys_ode.c nearCallback), else a carried prop phases through
	// resting ones and they only shove apart once it goes solid.
	if (b.po_is_weapon_drop)
		b.dimension_solid = PHYSDROP_DIM;
	else
		b.dimension_solid = dimension_default;
	b.dimension_hit = dimension_default | PHYSDROP_DIM;

	physics_enable(b, TRUE);
};

// Unified think (defined below, after the FX helpers) — forward-declared so the
// barrel/can/cabinet spawners above their definition can wire it as .think.
void() PhysObj_Think;

// Pick one of the three properly-made MP barrel models at random (each ships a .acd
// convex-decomposition sidecar). if/else, not a static array, per fteqcc quirks.
string() PhysBarrel_RandomModel =
{
	float pick = floor(random() * 3);
	if (pick <= 0)
		return "models/mega/containers/metal_barrel_mp_1.iqm";
	if (pick == 1)
		return "models/mega/containers/metal_barrel_mp_2.iqm";
	return "models/mega/containers/metal_barrel_mp_3.iqm";
};

// Same idea for the can (spawncan / phys_can).  This replaces the old hardcoded
// "models/props/can.mdl", which DID NOT EXIST — spawncan was setmodel'ing a missing file, so it
// spawned an invisible prop with a null model (and an "Unable to load" on every map load).
// Same quality bar as the barrels: only models that ship a .acd convex-decomposition sidecar.
// This list and phys_barrel_precache's can block are the only two places to edit to change the mix.
string() PhysCan_RandomModel =
{
	float pick = floor(random() * 5);
	if (pick <= 0)
		return "models/mega/props/tin_can_mp_1_rusty.iqm";
	if (pick == 1)
		return "models/mega/props/tin_can_mp_1_rusty_1.iqm";
	if (pick == 2)
		return "models/bunkers/canned_food_3.iqm";
	if (pick == 3)
		return "models/bunkers/canned_food_4.iqm";
	return "models/bunkers/canned_food_5.iqm";
};

float(entity playerent, float changedflags) phys_files_Send;   // defined below; used by the barrel spawner

// Flood-spawn queue (drained a few per frame in PhysFlood_Tick / StartFrame) so a big `spawnflood`
// doesn't build N Box3D bodies in ONE tick → the frame hitch.  Single spawns stay immediate.
float  phys_flood_left;      // barrels still to spawn
float  phys_flood_index;     // next grid slot
vector phys_flood_ground;    // ground contact under the pile
entity phys_flood_owner;

// Spawn ONE physics barrel resting on `base` (base = the ground XY+Z its bottom should sit at).
// Shared by spawnbarrel + spawnflood so the CSQC-predict mirror AND the primitive collision shape
// live in ONE place (both were the missing/expensive bits vs a mapped prop_physics).
entity(vector base) PhysBarrel_SpawnAt =
{
	entity b = spawn();
	b.classname = "phys_barrel";
	// Copy the prop_physics model setup (Props_SetupModel): enable the QW-setmodel real-box transfer so setmodel
	// hands us the TRUE model bounds, then setsize a TIGHT box that COVERS the model.  The old hardcoded ±32
	// "sidestep" was ~2× oversized (model floated inside it) + offset the origin by the box mins (−32, not the
	// real −22.6) → the barrel floated ~9u and the box never matched the model.
	cvar_set("sv_gameplayfix_setmodelsize_qw", "1");
	cvar_set("sv_gameplayfix_setmodelrealbox", "1");
	setmodel(b, PhysBarrel_RandomModel());      // now copies the real model bounds → b.mins/maxs
	vector rmn = b.mins, rmx = b.maxs;
	if ((rmx_x - rmn_x) < 1 || (rmx_z - rmn_z) < 1)
		setsize(b, '-32 -32 -32', '32 32 32');  // degenerate/zero model bbox → fallback cube (belt-and-suspenders)
	else
		setsize(b, rmn, rmx);                   // tight box that COVERS the model
	setorigin(b, base + '0 0 1' * (0 - b.mins_z));   // model bottom rests ON `base` (real mins_z → no float)
	b.angles   = '0 0 0';
	b.solid    = SOLID_PHYSICS_TRIMESH;         // player TRACE + SIM = the real mesh hull (accurate, rolls); the
	                                            // engine expands the TRIMESH broadphase for rotation so a tight box
	                                            // is fine, exactly like prop_physics.
	b.po_fx_enabled    = TRUE;
	b.po_sleep_enabled = TRUE;
	b.po_stuck_grace   = 5;
	b.po_material = PropMat_For(b.model);   // per-material bounce/damp (+ future sound/impact); keeps the tuned cvar mass
	PhysObj_Setup(b, cvar("sv_physprop_mass"), cvar("sv_physprop_friction"));
	b.think     = PhysObj_Think;
	b.nextthink = time + 0.05;
	// CSQC predict mirror — the local pmove collides client-side (no rubber-band).  THIS is what the
	// console spawns were missing vs prop_physics.
	b.SendEntity = phys_files_Send;
	b.SendFlags  = 1;
	PhysProp_ApplyPvsPolicy(b);
	return b;
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

	b = PhysBarrel_SpawnAt(ground + '0 0 1' * drop_height);   // shared setup (mirror + cylinder shape)

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] barrel loaded: model='%s' modelindex=%g native mins=%v maxs=%v spawned at %v\n",
			b.model, b.modelindex, b.mins, b.maxs, b.origin));
};

// nettest: worst-case physics stress test. Rains `count` barrels down in a grid
// in front of the player so they pile on each other + the world (the O(n^2) prop
// pile that stresses the physics backend). Pair with the gravity-gun black hole
// and compare `physics_box3d_threads 1` vs `4` for the Box3D multicore win.
void(entity owner, float count) phys_flood_spawn =
{
	vector fwd, base;
	float dist = cvar("sv_physprop_flood_dist");  if (dist < 1) dist = 200;  // forward offset; near edge = dist-144 clears the player

	if (count < 1) count = 1;
	if (count > 400) count = 400;	// safety cap (400 barrels is already a brutal pile)

	makevectors(owner.v_angle);
	fwd = v_forward;
	fwd_z = 0;
	fwd = normalize(fwd);

	base = owner.origin + fwd * dist;
	traceline(base + '0 0 256', base - '0 0 4096', MOVE_NORMAL, owner);
	if (trace_fraction >= 1.0)
	{
		sprint(owner, PRINT_HIGH, "spawnflood: no ground found in front\n");
		return;
	}
	// ENQUEUE — PhysFlood_Tick drains a few per frame (StartFrame) so N Box3D body builds
	// don't all land in ONE tick (the frame hitch).  New flood replaces any in progress.
	phys_flood_ground = trace_endpos;
	phys_flood_owner  = owner;
	phys_flood_left   = count;
	phys_flood_index  = 0;
	sprint(owner, PRINT_HIGH, sprintf("spawnflood: queued %g props\n", count));
};

// A flood cell whose column overlaps a player would drop a barrel INSIDE them → the solver
// ejects it violently (chaos/lag).  TRUE = skip that cell.  Walk the player chain (the norm
// here — not findradius); axis check vs the ±16 player hull + ±14.74 barrel + margin.
float PHYSFLOOD_CLEAR = 48;
float(vector pos) PhysFlood_ColumnBlocked =
{
	entity p = player_chain_head;
	while (p)
	{
		if (p.classname == "player" && !p.is_dead
		    && fabs(pos_x - p.origin_x) < PHYSFLOOD_CLEAR
		    && fabs(pos_y - p.origin_y) < PHYSFLOOD_CLEAR)
			return TRUE;
		p = p.player_chain_next;
	}
	return FALSE;
};

// Drain the flood queue a few props per frame — called every StartFrame (sv_main.qc).
void() PhysFlood_Tick =
{
	if (phys_flood_left <= 0)
		return;
	if (phys_flood_owner == world)          // requester gone → drop the rest
	{
		phys_flood_left = 0;
		return;
	}
	float cols = 5, spacing = 72, per_layer = 25;   // 5×5 per stacked layer
	float perf = cvar("sv_physprop_flood_per_frame");  if (perf < 1) perf = 1;
	float n = 0;
	while (n < perf && phys_flood_left > 0)
	{
		float i  = phys_flood_index;
		float gz = floor(i / per_layer);            // stacked layer
		float within = i - gz * per_layer;
		float gy = floor(within / cols);            // row
		float gx = within - gy * cols;              // column
		vector pos = phys_flood_ground
			+ '1 0 0' * ((gx - (cols - 1) * 0.5) * spacing)
			+ '0 1 0' * ((gy - (cols - 1) * 0.5) * spacing)
			+ '0 0 1' * (48 + gz * spacing);
		phys_flood_index = phys_flood_index + 1;
		phys_flood_left  = phys_flood_left - 1;
		// Skip a cell that would drop onto a player (gap in the pile); NOT counted against the
		// per-frame budget (a skip is cheap), so the drain still spawns `perf` real barrels/frame.
		if (PhysFlood_ColumnBlocked(pos))
			continue;
		PhysBarrel_SpawnAt(pos);
		n = n + 1;
	}
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
	// Real model bounds (copy prop_physics / the barrel, Stage 4c/4d): enable the QW
	// setmodel real-box transfer BEFORE setmodel so b.mins/maxs get the TRUE can bounds.
	cvar_set("sv_gameplayfix_setmodelsize_qw", "1");
	cvar_set("sv_gameplayfix_setmodelrealbox", "1");
	setmodel(b, PhysCan_RandomModel());   // random .acd-backed can IQM (was the missing can.mdl)

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] can loaded: model='%s' modelindex=%g native mins=%v maxs=%v\n",
			b.model, b.modelindex, b.mins, b.maxs));

	// TRIMESH mesh collision.  TIGHT real box that COVERS the model + degenerate fallback,
	// exactly like the barrel (Stage 4c).
	vector cmn = b.mins, cmx = b.maxs;
	if ((cmx_x - cmn_x) < 1 || (cmx_z - cmn_z) < 1)
		setsize(b, '-12 -12 -12', '12 12 12');   // degenerate model bbox → fallback cube
	else
		setsize(b, cmn, cmx);                     // tight box that COVERS the model
	setorigin(b, ground + '0 0 1' * (drop_height - b.mins_z));
	b.angles = '0 0 0';
	b.solid = SOLID_PHYSICS_TRIMESH;
	// No dim filter — engine patch handles mesh narrowphase.

	b.po_fx_enabled    = TRUE;
	b.po_sleep_enabled = TRUE;
	b.po_stuck_grace   = 5;
	b.po_material = PropMat_For(b.model);   // per-material bounce/damp; keeps the tuned cvar mass
	PhysObj_Setup(b, cvar("sv_physprop_can_mass"), cvar("sv_physprop_friction"));
	b.think     = PhysObj_Think;   // void cull + metal contact FX (free prop)
	b.nextthink = time + 0.05;
	// CSQC predict mirror (same as the barrel) — the relocated stream rest-latch feeds it
	// so the client collides locally (no sink-and-snap).
	b.SendEntity = phys_files_Send;
	b.SendFlags  = 1;
	PhysProp_ApplyPvsPolicy(b);

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] can spawned at %v\n", b.origin));
};

// Per-prop tick for the filecabinet: keep it UPRIGHT (yaw free) while not
// carried so its axis-aligned collision box always matches the model — a box
// that tips onto its side leaves the AABB hull floating where the model isn't,
// and the player walks through it.  Only corrects past a small threshold so a
// settled-upright box can still autodisable.  Also culls into-the-void props.
// Velocity below this (qu/s, lin or ang) counts as "stopped" — above ODE's
// autodisable residual (~0.2 lin / 0.3 ang) so a settled body isn't treated as
// still moving (which would leave the client extrapolating a stale velocity).
const float PHYSFILES_STILL_LIN = 8;
const float PHYSFILES_STILL_ANG = 16;

// Sleep gate (PhysObj_Think).  Deliberately TIGHTER than the STILL_* thresholds above:
// those decide "settled enough to re-solidify / stop streaming", whereas these decide
// "settled enough to stop looking at for 125 ms", which wants a prop that is genuinely
// dead-stopped, not merely slow.  Matched to the rest-latch's own 0.5 qu/s cut so a prop
// only sleeps once the latch has already sent its final velocity=0 snapshot.
const float PHYSPROP_SLEEP_LIN   = 0.5;
const float PHYSPROP_SLEEP_ANG   = 0.5;
// Hold still this long before sleeping — long enough that a bounce apex / toss peak (a
// single near-zero MID-AIR tick) never triggers it.
const float PHYSPROP_SLEEP_DELAY = 0.35;

// ============================================================================
//  Contact FX — impact metal sounds (server sound(), so all players hear) + a
//  networked smoke puff.  The smoke goes through CSQC_EVENT_PHYSPROP_IMPACT →
//  CSQC pointparticles("weapons.physprop_smoke") because the particle config is
//  only loaded into the CLIENT VM (server pointparticles can't resolve it).
//  Shared by the free-prop path (phys_files_think) and the carry path (Carry_Tick).
// ============================================================================

// Broadcast a smoke puff at point with surface normal; bucket = 0 slide / 1 soft / 2 hard.
// Normal is sent as 3 bytes (-1..1 → 0..255, 128 = 0), mirroring CSQC_EVENT_BUTTON_SPARK.
void(vector point, vector normal, float bucket) PhysFiles_SmokeEvent =
{
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_PHYSPROP_IMPACT);
	WriteCoord(MSG_MULTICAST, point_x);
	WriteCoord(MSG_MULTICAST, point_y);
	WriteCoord(MSG_MULTICAST, point_z);
	WriteByte(MSG_MULTICAST, bound(0, rint(normal_x * 127 + 128), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(normal_y * 127 + 128), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(normal_z * 127 + 128), 255));
	WriteByte(MSG_MULTICAST, bucket);
	multicast(point, MULTICAST_PVS);
};

// Dedicated channel for the looping scrape sound — kept off CHAN_BODY (the impact
// one-shots) so an impact doesn't cut the loop and vice-versa.
const float CHAN_PHYSPROP_SCRAPE = 6;

// Trace from the box CENTRE along `dir` to the struck surface and spawn the smoke puff
// THERE (on the floor/wall the model actually contacts), not at the model centre.  Falls
// back to the base if the trace misses.  Shared by impacts (dir = impact direction) and
// scrape puffs (dir = into the scraped surface).
void(entity prop, vector dir, float bucket) PhysFiles_SmokeAlong =
{
	vector point  = prop.origin + '0 0 1' * prop.mins_z;   // fallback: base of the model
	vector normal = '0 0 1';
	if (dir != '0 0 0')
	{
		vector c     = prop.origin + '0 0 1' * ((prop.maxs_z + prop.mins_z) * 0.5);
		float  reach = vlen(prop.maxs - prop.mins) * 0.5 + 12;
		traceline(c, c + normalize(dir) * reach, MOVE_NOMONSTERS, prop);
		if (trace_fraction < 1)
		{
			point  = trace_endpos;
			normal = trace_plane_normal;
		}
	}
	PhysFiles_SmokeEvent(point, normal, bucket);
};

// Per-object FX sound SET — impact (soft/hard, idx 1-3) + the scrape loop — picked by
// prop.po_fx_soundset so different objects sound different.  Smoke/spark PARTICLES are
// universal; only these SOUND paths vary.
//   setid 0 = metal box (barrel / can / cabinet): metal_box_impact_*, metal_box_scrape
//   setid 1 = weapon drop                        : weapon_impact_*,    soda_can_scrape
const float FXSND_IMPACT_SOFT = 0;
const float FXSND_IMPACT_HARD = 1;
const float FXSND_SCRAPE      = 2;
string(float setid, float kind, float idx) PhysObj_FxSound =
{
	if (setid == 1)   // weapon drops
	{
		if (kind == FXSND_SCRAPE)      return "sounds/impacts/soda_can_scrape_rough_loop1.wav";
		if (kind == FXSND_IMPACT_HARD) return sprintf("sounds/impacts/weapon_impact_hard%g.wav", idx);
		return sprintf("sounds/impacts/weapon_impact_soft%g.wav", idx);
	}
	// 0 = metal box (default — barrel / can / cabinet)
	if (kind == FXSND_SCRAPE)      return "sounds/impacts/metal_box_scrape_rough_loop1.wav";
	if (kind == FXSND_IMPACT_HARD) return sprintf("sounds/impacts/metal_box_impact_hard%g.wav", idx);
	return sprintf("sounds/impacts/metal_box_impact_soft%g.wav", idx);
};

// A real surface impact: a soft or hard sound (by speed, from the object's sound set) +
// a smoke puff at the struck surface.  Rate-limited by pp_impact_cooldown so a tumbling/
// bouncing prop makes one sound.  `dir` is the impact direction (approach velocity).
void(entity prop, float speed, vector dir) PhysFiles_EmitImpact =
{
	prop.pp_impact_cooldown = time + pp_cached_impact_cooldown;
	float hard = (speed >= pp_cached_impact_hard_speed);
	float n = bound(1, floor(random() * 3) + 1, 3);
	string snd = PhysObj_FxSound(prop.po_fx_soundset,
	                             hard ? FXSND_IMPACT_HARD : FXSND_IMPACT_SOFT, n);
	sound(prop, CHAN_BODY, snd, 1.0, ATTN_NORM);
	PhysFiles_SmokeAlong(prop, dir, hard ? 2 : 1);
};

// A free prop scraping along a surface: a periodic dust puff at the floor it's scraping
// (trace straight down), rate-limited.  The looping scrape SOUND is separate (StartScrape).
void(entity prop) PhysFiles_DoSlide =
{
	prop.pp_slide_next = time + pp_cached_slide_interval;
	PhysFiles_SmokeAlong(prop, '0 0 -1', 0);
};

// Map slide speed → scrape volume (faster = louder).
float(float speed) PhysFiles_ScrapeVol =
{
	return bound(0.3, speed * (1.0 / 400), 1.0);
};

// Start (or keep alive) the looping scrape sound at a speed-scaled volume, and refresh
// the slide-stop grace.  Shared by the free-slide (phys_files_think) and carry-drag
// (Carry_Tick) paths.  The volume can TRACK speed (sv_physprop_scrape_track 1) by
// re-issuing the loop on a notable speed change — but re-issuing RESTARTS the sample (the
// engine has no in-place volume control from QC), so it's throttled + deadbanded (a
// steady-speed drag never re-issues) and for a rough scrape the re-trigger is ~inaudible.
void(entity prop, float speed) PhysFiles_StartScrape =
{
	prop.pp_slide_active_until = time + 0.2;   // grace before the loop cuts after sliding stops
	float vol = PhysFiles_ScrapeVol(speed);
	string scrapesnd = PhysObj_FxSound(prop.po_fx_soundset, FXSND_SCRAPE, 0);
	if (!prop.pp_scrape_active)
	{
		sound(prop, CHAN_PHYSPROP_SCRAPE, scrapesnd,
		      vol, ATTN_NORM, 100, SOUNDFLAG_FORCELOOP | SOUNDFLAG_FOLLOW);
		prop.pp_scrape_active     = TRUE;
		prop.pp_scrape_vol        = vol;
		prop.pp_scrape_revol_next = time + 0.12;
	}
	else if (pp_cached_scrape_track && time >= prop.pp_scrape_revol_next
	         && fabs(vol - prop.pp_scrape_vol) >= 0.12)
	{
		sound(prop, CHAN_PHYSPROP_SCRAPE, scrapesnd,
		      vol, ATTN_NORM, 100, SOUNDFLAG_FORCELOOP | SOUNDFLAG_FOLLOW);
		prop.pp_scrape_vol        = vol;
		prop.pp_scrape_revol_next = time + 0.12;
	}
};

// Stop the looping scrape sound if it's playing.  Empty-string sound() is a NO-OP in
// this engine (sfx==NULL guard — see cl_rain.qc), and stopsound() is client-only, so we
// cancel a FORCELOOP by playing a real silent sample (null.wav) on the same channel,
// which replaces it.
void(entity prop) PhysFiles_StopScrape =
{
	if (prop.pp_scrape_active)
	{
		sound(prop, CHAN_PHYSPROP_SCRAPE, "sounds/null.wav", 1, ATTN_NORM);
		prop.pp_scrape_active = FALSE;
	}
};

// Cheap confirming trace: is the prop resting on / just above a surface (vs airborne)?
// Gates the slide test so a fast AIRBORNE prop isn't mistaken for "sliding".
float(entity prop) PhysFiles_OnSurface =
{
	tracebox(prop.origin, prop.mins, prop.maxs, prop.origin - '0 0 3', MOVE_NOMONSTERS, prop);
	return (trace_fraction < 1);
};

// Free-prop contact FX — infer impacts/slides from the ODE body's motion (ODE
// gives QC no contact callback).  A sharp one-tick speed DROP = the body slammed
// into a surface (pre-drop speed = approach speed → grades soft/hard); a sustained
// HORIZONTAL speed on a surface with no sharp drop = sliding → scrape loop + dust
// puffs.  Only for FREE props (carried props are handled in Carry_Tick).  Shared by
// barrel / can / cabinet / weapon drops via PhysObj_Think.  pp_prev_velocity is
// latched at the end of the think.
void(float lin) PhysObj_DetectContactFX =
{
	if (self.carried_by != world)
		return;

	float imin      = pp_cached_impact_min_speed;   // per-frame cache, not a per-prop cvar() hash
	float prevspeed = vlen(self.pp_prev_velocity);
	float drop      = prevspeed - lin;
	if (time >= self.pp_impact_cooldown && prevspeed >= imin && drop >= imin)
	{
		// Hard contact — pass the pre-impact velocity as the impact DIRECTION so
		// EmitImpact traces along it to the actual contacted surface.
		PhysFiles_EmitImpact(self, prevspeed, self.pp_prev_velocity);
	}
	else if (drop < imin)
	{
		// SLIDE TEST — deliberately NESTED, not a single `&&` chain.
		//
		// `#pragma flag enable logicops` is OFF mod-wide, so fteqcc does NOT
		// short-circuit: every operand of an `&&` is evaluated.  The old form
		//     else if (drop < imin && vlen(horiz) >= cvar(...) && PhysFiles_OnSurface(self))
		// therefore ran the cvar hash lookup AND PhysFiles_OnSurface's TRACEBOX for
		// every FX prop on every 64 Hz tick — including props sitting perfectly still,
		// forever.  That was the single biggest server cost on a prop-dense map
		// (PhysFiles_OnSurface topped the profile at ~0.147s self / 5s with ~800
		// traceboxes per tick).  Nesting reaches the trace only for props that are
		// actually moving horizontally.  See [[fteqcc-logicops-off-no-shortcircuit]].
		float horizspeed = vlen([self.velocity_x, self.velocity_y, 0]);
		if (horizspeed >= pp_cached_slide_min_speed)
		{
			if (PhysFiles_OnSurface(self))
			{
				// Sliding along a surface: keep the scrape loop alive (volume by speed) + puffs.
				PhysFiles_StartScrape(self, horizspeed);
				if (time >= self.pp_slide_next)
					PhysFiles_DoSlide(self);
			}
		}
	}
	// Cut the scrape loop once sliding has stopped for the grace window (or the prop
	// impacted / went airborne — the slide branch stops refreshing pp_slide_active_until).
	if (self.pp_scrape_active && time > self.pp_slide_active_until)
		PhysFiles_StopScrape(self);
};

// Unified per-tick think for free + cabinet phys objects (barrel, can, cabinet).
// (Weapon drops keep W_PhysDropThink until the weapon migration repoints them here.)
//   - 64 Hz tick + void cull        (all)
//   - contact-FX detection          if po_fx_enabled
//   - re-solidify-on-drop + CSQC stream rest-latch   if po_carry_enabled (cabinet)
// (Was phys_files_think — generalized so barrel/can gain the same metal contact FX.)
void() PhysObj_Think =
{
	// Tick at the server rate (~64 Hz) not 20 Hz: a FREE falling/tumbling cabinet
	// streams to clients from here (the rest-latch below), so a slow tick is exactly
	// the "large steps" you see in slow-mo.  Carried props already stream every frame
	// via Carry_Tick.  Streaming + FX are motion-gated, so a resting prop costs ~0.
	//
	// ...except that "costs ~0" was only true per-prop-per-tick: at a few hundred
	// settled props this function alone topped the server profile (6.3M statements /
	// 5 s) purely re-scheduling itself 64×/s to look at props that had not moved in
	// minutes.  The sleep gate at the bottom of this function drops a prop that has
	// held still for PHYSPROP_SLEEP_DELAY down to sv_physprop_sleep_hz (default 8 Hz).
	self.nextthink = time + 0.0156;

	// Void cull (escaped world / NaN) — detach the ODE body before remove().
	if (self.origin_z < PHYSPROP_VOID_Z
	    || fabs(self.origin_x) > PHYSPROP_COORD_CAP
	    || fabs(self.origin_y) > PHYSPROP_COORD_CAP)
	{
		if (self.po_fx_enabled)
			PhysFiles_StopScrape(self);   // don't leave the scrape loop playing on a removed ent
		physics_enable(self, FALSE);
		remove(self);
		return;
	}

	float lin = vlen(self.velocity);
	float ang = vlen(self.avelocity);

	// --- Contact FX (FREE prop) --- impact/slide inferred from motion.
	if (self.po_fx_enabled)
		PhysObj_DetectContactFX(lin);

	// ==================== CARRIABLE-ONLY (re-solidify) ====================
	// The carry re-solidify-on-drop below is cabinet/prop_physics only.  The CSQC
	// mirror's stream rest-latch used to live here too, but it's now relocated OUT
	// (just past this block) so EVERY mirror prop — barrel & can included — re-streams.
	if (self.po_carry_enabled)
	{

	// RE-SOLIDIFY to players (HL2 "shove apart on drop, then go solid").  A dropped
	// or thrown cabinet is held in the player-passthrough dimension (PHYSDROP_DIM,
	// set at grab) so it doesn't shove the carrier as it leaves the hands.  While it
	// is still in that phase: if it OVERLAPS a player, push it horizontally OUT of
	// them so it can come to rest in the clear; once it is settled AND clear (or the
	// 5 s safety timeout fires) restore normal player-solidity so you can walk on it.
	// No solid-type swap anymore — it's SOLID_PHYSICS_BOX throughout, and the engine
	// OBB patch (world.c World_OBBTrace) gives smooth oriented collision at any tilt.
	if (self.carried_by == world && (self.dimension_solid & PHYSDROP_DIM))
	{
		entity op = world;
		// Walk the player chain (<=32) instead of findradius() over every edict —
		// Carry_OBBOverlap is the real test; the old 128u radius was only a coarse
		// pre-filter (far players OBB-test false), so the result is identical and a
		// full-list scan is dropped.  Use .player_chain_next, NOT the shared .chain
		// temp field that findradius/findchain reuse.
		entity p = player_chain_head;
		while (p)
		{
			// OBB (rotated-box) overlap, NOT the axis-aligned bbox — when the cabinet
			// is mid-tumble the real collision box pokes outside the upright hbox, and
			// a player standing in that poke-out must still be shoved clear so it
			// doesn't eject them when it goes solid.
			if (p.classname == "player" && !p.is_dead && Carry_OBBOverlap(self, p))
			{
				op = p;
				break;
			}
			p = p.player_chain_next;
		}

		float solidify;
		if (op != world)
		{
			// Shove away from the overlapping player (HORIZONTAL only — keep the ODE
			// fall velocity on Z).  physics_enable wakes the body so it integrates.
			vector away = self.origin - op.origin;
			away_z = 0;
			if (vlen(away) < 1) away = '1 0 0';   // exactly co-located → arbitrary dir
			away = normalize(away) * cvar("sv_carry_separate_speed");
			physics_enable(self, TRUE);
			self.velocity_x = away_x;
			self.velocity_y = away_y;
			solidify = (time > self.carry_resolidify_until);   // hard safety cap only
		}
		else
			solidify = (lin < PHYSFILES_STILL_LIN && ang < PHYSFILES_STILL_ANG)
			        || (time > self.carry_resolidify_until);

		if (solidify)
		{
			self.dimension_solid = dimension_default;
			self.dimension_hit   = dimension_default | PHYSDROP_DIM;   // keep colliding carried props
		}
	}

	}   // end if (po_carry_enabled) — carry re-solidify-on-drop (cabinet/prop_physics)

	// CSQC stream rest-latch — EVERY prop with the custom CSQC mirror (barrel, can,
	// cabinet, prop_physics), NOT just carriables.  Stream every tick while moving/carried;
	// on the moving→rest edge send ONE final snapshot with velocity zeroed so the client
	// clears its predraw and parks the hull at the true resting origin.  Without it the
	// client keeps extrapolating the last non-zero velocity → the collision hull drifts off
	// the model → "server-solid but client-non-solid" (sink-and-snap) + mesh off the hull.
	if (self.SendEntity == phys_files_Send)
	{
		if (lin > 0.5 || ang > 0.5 || self.carried_by != world)
		{
			// Throttle the MOVING stream to sv_physprop_stream_hz (default 8) — the client
			// predraw extrapolates between snapshots, so 30 Hz keeps collision smooth while a
			// big flood pays ~2× fewer Sends + client relinks.  The rest snapshot below stays
			// IMMEDIATE, so the hull still parks exactly on the model at rest (Stage 4d intact).
			float stream_hz = pp_cached_stream_hz;
			if (stream_hz <= 0 || time >= self.pp_stream_next)
			{
				self.SendFlags     |= 1;
				if (stream_hz > 0)
					self.pp_stream_next = time + 1 / stream_hz;
			}
			self.pp_was_streaming  = TRUE;
		}
		else if (self.pp_was_streaming)
		{
			self.velocity          = '0 0 0';
			self.avelocity         = '0 0 0';
			self.SendFlags        |= 1;
			self.pp_was_streaming  = FALSE;
		}
	}

	self.pp_prev_velocity = self.velocity;   // latch for next think's impact-drop test + contact direction

	// ==================== SLEEP GATE ====================
	// A prop that has held still for PHYSPROP_SLEEP_DELAY drops from the 64 Hz tick to
	// sv_physprop_sleep_hz.  Everything above this point is already motion-gated, so a
	// slow tick on a settled prop does the same (nothing) work — just 8× less often.
	//
	// Why a sustained rest DELAY and not an instant "lin < x" test: a prop at the apex of
	// a bounce, or at the top of a gravity-gun toss, is momentarily near-zero velocity in
	// MID-AIR.  Sleeping there would slow the tick exactly when the landing impact needs
	// detecting.  The delay means only a genuinely settled prop sleeps.
	//
	// Wake latency: an interaction we can SEE from QC (bullet, explosion, +use, throw,
	// carry, gravity gun) calls PhysProp_Wake and resumes the fast tick the same tick.
	// A contact we CANNOT see (another prop rolls into this one, a door shoves it — ODE
	// gives QC no contact callback) is caught by the next slow tick, i.e. within
	// 1/sleep_hz.  That is the same order as the stream throttle this system already
	// runs at (sv_physprop_stream_hz default 8), so it costs no additional fidelity that
	// the mirror stream was not already spending.  Set sv_physprop_sleep 0 to disable.
	float atrest = (lin <= PHYSPROP_SLEEP_LIN && ang <= PHYSPROP_SLEEP_ANG
	                && self.carried_by == world);
	// Still in the post-drop re-solidify phase?  That block above must keep running at
	// full rate until it goes solid (it polls player overlap + a 5 s safety timeout).
	if (atrest && self.po_carry_enabled)
		if (self.dimension_solid & PHYSDROP_DIM)
			atrest = FALSE;

	if (!atrest)
		self.pp_rest_since = 0;                 // moving (or busy) — stay on the fast tick
	else if (!self.pp_rest_since)
		self.pp_rest_since = time;              // first still tick — start the settle timer

	if (pp_cached_sleep_enable)
		if (atrest)
			if (time - self.pp_rest_since >= PHYSPROP_SLEEP_DELAY)
				self.nextthink = time + 1 / pp_cached_sleep_hz;
};

// Resume the full 64 Hz tick on a prop that may be asleep (see the sleep gate in
// PhysObj_Think).  Call this from EVERY path that applies a force / velocity / carry to a
// prop, BEFORE (or right after) the force — a sleeping prop would otherwise not notice it
// moved until its next slow tick.  Safe on non-sleeping props and on non-PhysObj_Think
// entities (weapon drops run their own think cadence) — it only ever schedules sooner.
void(entity e) PhysProp_Wake =
{
	e.pp_rest_since = 0;

	// Cars (Car_Think, sv_prop_vehicle.qc) sleep differently: their body is EXPLICITLY
	// disabled, so re-enable it here.  Both backends already auto-enable on a force
	// (ODE dBodyEnable before dBodyAddForceAtPos; Box3D b3Body_ApplyForce wake=true), but
	// that only wakes the BODY — the QC-side car_asleep latch would still skip
	// Car_PhysStep, so the shoved car would coast with NO suspension until its next tick
	// noticed.  Worse, the settle timer would still be armed, so the very next Car_Think
	// could re-disable the body and swallow the impulse outright.  Clearing both here (on
	// the same call the push paths already make) keeps it a one-tick resume.
	e.car_rest_since = 0;
	if (e.car_asleep)
	{
		physics_enable(e, TRUE);
		e.car_asleep = FALSE;
	}

	if (e.think == PhysObj_Think)
	{
		e.nextthink       = time;      // run the real tick again immediately
		// Re-latch the impact reference: a prop that slept with velocity 0 and is now being
		// shoved must not read the stale latch as a giant one-tick speed DROP (= a phantom
		// impact bang the moment it wakes).
		e.pp_prev_velocity = e.velocity;
	}
};

// Instant-react: force the NEXT PhysObj_Think (64 Hz) to emit this free prop's mirror snapshot, bypassing
// the sv_physprop_stream_hz gate for that ONE send, so a shot/blast/throw reacts within ~1 tick instead of
// waiting up to 1/stream_hz.  Clears the timer only — the think runs AFTER the ODE step, so the snapshot
// carries the INTEGRATED velocity/origin (not a pre-step dead pose).  The ongoing cap is preserved: the
// moving branch re-arms pp_stream_next = time + 1/stream_hz.  No-op on weapon drops (own un-throttled stream).
void(entity e) PhysProp_KickStream =
{
	// The WAKE is unconditional: it must happen even with sv_physprop_stream_instant 0,
	// because that cvar only tunes the mirror SEND rate — it has nothing to do with
	// whether the prop's think is asleep.  (Wiring the wake behind the early-out below
	// would leave shot props frozen for up to 1/sleep_hz with stream_instant 0.)
	PhysProp_Wake(e);
	if (!cvar("sv_physprop_stream_instant")) return;
	if (e.SendEntity != phys_files_Send) return;
	e.pp_stream_next = 0;
};

// CSQC-networked solid mirror of the filing cabinet.  The server keeps running
// the real ODE body (solid box, full physics, pushable); this just streams its
// origin/angles to every client so the CLIENT's custom QC pmove and the CSQC
// bullet traces collide with a matching SOLID_BBOX.  Closing that gap is what
// stops players falling through / driftlocking on top, and what makes shots
// register locally (the engine-replicated body was invisible to both).
// Wire layout MUST match CSQC_PhysProp_Update (cl_physprop.qc) byte-for-byte —
// see [[prediction-proxy-serialization-split]].
float(entity playerent, float changedflags) phys_files_Send =
{
	WriteByte(MSG_ENTITY, CSQC_ENT_PHYS_PROP);
	WriteShort(MSG_ENTITY, self.modelindex);

	WriteCoord(MSG_ENTITY, self.origin_x);
	WriteCoord(MSG_ENTITY, self.origin_y);
	WriteCoord(MSG_ENTITY, self.origin_z);

	// Full-range tumble angles (any value 0..360 on each axis).
	WriteCoord(MSG_ENTITY, self.angles_x);
	WriteCoord(MSG_ENTITY, self.angles_y);
	WriteCoord(MSG_ENTITY, self.angles_z);

	// The tight hbox — on the client this is the SOLID_PHYSICS_BOX collision box,
	// which the engine OBB patch rotates by the streamed angles (oriented box).
	WriteCoord(MSG_ENTITY, self.mins_x);
	WriteCoord(MSG_ENTITY, self.mins_y);
	WriteCoord(MSG_ENTITY, self.mins_z);
	WriteCoord(MSG_ENTITY, self.maxs_x);
	WriteCoord(MSG_ENTITY, self.maxs_y);
	WriteCoord(MSG_ENTITY, self.maxs_z);

	// Linear + angular velocity → the client predraw extrapolates between
	// snapshots so motion (tumble / carry / throw) renders smoothly.
	WriteCoord(MSG_ENTITY, self.velocity_x);
	WriteCoord(MSG_ENTITY, self.velocity_y);
	WriteCoord(MSG_ENTITY, self.velocity_z);

	WriteCoord(MSG_ENTITY, self.avelocity_x);
	WriteCoord(MSG_ENTITY, self.avelocity_y);
	WriteCoord(MSG_ENTITY, self.avelocity_z);

	// Per-channel colormod (R,G,B) → 3 bytes.  The cabinet/weapon-drops use a grayscale
	// dim (sv_carry_lightscale, e.g. '0.7 0.7 0.7') that round-trips identically; Source
	// props (sv_props.qc) can carry a COLORED rendercolor tint via BrushSync_ApplyRenderKeys,
	// which a single grayscale byte would flatten — a zero-red tint (e.g. '0 0.5 1') streamed
	// as colormod_x=0 turned the prop BLACK on the client.
	WriteByte(MSG_ENTITY, bound(0, rint(self.colormod_x * 255), 255));
	WriteByte(MSG_ENTITY, bound(0, rint(self.colormod_y * 255), 255));
	WriteByte(MSG_ENTITY, bound(0, rint(self.colormod_z * 255), 255));

	// Skin index (livery swap) — the client mirror renders self.skin, which selects a `<model>_<N>.skin`
	// file (surface→shader remap).  For the outrun car: 0 = clean, 1 = dirty (models/outrun/car_1.skin).
	// MUST be read in the SAME wire position in CSQC_PhysProp_Update (cl_physprop.qc).
	WriteByte(MSG_ENTITY, bound(0, rint(self.skin), 255));

	// nettest: 1 = client mirrors as SOLID_PHYSICS_TRIMESH (player collides with the generated
	// convex hull / decomposition) when FREE_SOLID; 0 = oriented box. Derived from this prop's
	// own solid, so the cabinet (always BOX) + weapon drops send 0 automatically. MUST be read
	// in the SAME wire position in CSQC_PhysProp_Update (cl_physprop.qc).
	WriteByte(MSG_ENTITY, (self.solid == SOLID_PHYSICS_TRIMESH) ? 1 : 0);

	// nettest Patch 70: visual + client-trimesh-narrowphase scale (default ~1). The engine renders
	// the CSQC mirror at self.scale and scales the predicted hull trace by it — without this the
	// model drew at 1.0 even for a scale 0.8 prop. MUST be read at the SAME wire position in
	// CSQC_PhysProp_Update (after istrimesh, before phase). cabinet/weapon-drops send ~1.
	WriteCoord(MSG_ENTITY, self.scale);

	// Carry-phase byte (this is the former csolid 0/1 flag, widened to a 0..3 enum —
	// see PP_PHASE_*).  0/1 keep the old solidity meaning; 2 (GRABBING) and 3 (STEADY)
	// distinguish the carry sub-states so the client knows when it may PREDICT the hold
	// pose.  Client mirror is SOLID_PHYSICS_BOX only for FREE_SOLID (1); everything else
	// is SOLID_NOT (carried / flying / grab pull-in) so client+server agree.
	float pp_phase_out;
	if (self.carried_by != world)
		pp_phase_out = (time - self.carry_grab_time < cvar("sv_carry_grab_time"))
		             ? PP_PHASE_GRABBING : PP_PHASE_STEADY;
	else
		pp_phase_out = (self.dimension_solid & PHYSDROP_DIM) ? PP_PHASE_NONSOLID : PP_PHASE_FREE_SOLID;
	WriteByte(MSG_ENTITY, pp_phase_out);

	// Carrier edict (0 = not carried).  The client compares this to player_localentnum
	// to decide "is THIS prop mine?" → client-predict its hold pose with zero ping lag.
	WriteByte(MSG_ENTITY, (self.carried_by != world) ? num_for_edict(self.carried_by) : 0);

	// Hold params, networked so a REMOTE client (no server cvars) predicts the hold
	// point with the EXACT server values — a mismatch here would pop on drop.  A CAR streams its
	// larger car-carry values so the client-predicted hold matches the (un-clip-slid) server body.
	float sc_is_car = (self.classname == "prop_car" || self.classname == "func_car");
	WriteCoord(MSG_ENTITY, sc_is_car ? cvar("sv_car_carry_dist") : cvar("sv_carry_hold_dist"));
	WriteCoord(MSG_ENTITY, sc_is_car ? cvar("sv_car_carry_z")    : cvar("sv_carry_hold_z"));

	// Is-car byte: lets CSQC pick the CAR mirrors out of the generic phys_files
	// stream (engine-sound driver cl_vehicle_sound.qc). MUST be read LAST in
	// CSQC_PhysProp_Update (after hold_z).
	WriteByte(MSG_ENTITY, sc_is_car ? 1 : 0);

	// Visual spinning-wheel data — read ONLY when is-car, so the wire stays byte-symmetric and every
	// non-car prop pays zero extra bytes.  Front steer angle (±90 at 1° res), wheel model index, and
	// per-car model_yaw.  Consumed by Car_DrawWheels (cl_physprop.qc).  MUST match the client read order.
	if (sc_is_car)
	{
		WriteByte (MSG_ENTITY, bound(0, rint(self.car_steer) + 90, 180));
		WriteShort(MSG_ENTITY, self.car_wheel_mdlidx);
		WriteByte (MSG_ENTITY, bound(0, rint(self.model_yaw) + 128, 255));
		WriteCoord(MSG_ENTITY, self.res_base);    // resolved wheel spacing → visual wheels match physics + wheel_base key
		WriteCoord(MSG_ENTITY, self.res_track);
		WriteCoord(MSG_ENTITY, self.res_drop);
		WriteCoord(MSG_ENTITY, self.res_fwd);     // fore/aft wheel-set shift (wheel_fwd key + sv_car_wheel_fwd)
		// Resolved suspension (ride_height + compression_travel) so the CLIENT visual wheels cap their droop to
		// the SAME per-car value the physics uses.  Resolved INLINE (Car_CvarZ lives in sh_vehicle_phys.qc which
		// compiles AFTER this file — same trap as the seat offsets; ride_height/compression_travel are declared
		// in sv_customdefs.qc so they're reachable here) and LIVE, so a mid-drive `carset ride_height/…` (F3
		// panel) reflects at once.  Car_CvarZ semantics: non-zero per-car field wins, else the cvar — an
		// explicit cvar 0 IS honoured so the client visual can go to 0 too.  MUST match the client read order.
		float sr = (self.ride_height        != 0) ? self.ride_height        : cvar("sv_car_ride_height");
		float st = (self.compression_travel != 0) ? self.compression_travel : cvar("sv_car_compression_travel");
		WriteCoord(MSG_ENTITY, sr);
		WriteCoord(MSG_ENTITY, st);
		// Engine-sound scale — the CLIENT audio's virtual gears + shift-dip must land on the SAME speeds as the
		// physics gearbox (removes the fragile cl_car_sound_maxspeed "MUST track sv_car_max_speed" coupling).
		// Read in the SAME order in CSQC_PhysProp_Update.
		WriteShort(MSG_ENTITY, bound(0, rint((self.maxspeed != 0) ? self.maxspeed : cvar("sv_car_max_speed")), 30000));
		WriteByte (MSG_ENTITY, bound(1, rint(cvar("sv_car_gears")), 12));                  // virtual gear count
		WriteByte (MSG_ENTITY, bound(0, rint(cvar("sv_car_shift_time") * 100), 255));       // shift-cut window (×100 s)

		// Seated-driver render payload — the client draws the driver's player model glued to the
		// interpolated car pose (Car_DrawDriver, cl_physprop.qc), so it's smooth (no server-tick
		// jitter) and visible in first person.  Sent only when a driver is seated AND
		// sv_car_show_driver; otherwise a single 0 byte keeps the wire byte-symmetric.
		entity drv = self.car_driver;
		if (drv != world && cvar("sv_car_show_driver"))
		{
			WriteByte(MSG_ENTITY, 1);
			WriteByte(MSG_ENTITY, num_for_edict(drv));   // driver player slot (matches the visual proxy's vis_owner_entnum → proxy suppressed)
			// team_model_byte — inline copy of the canonical encoder in sv_player.qc (PlayerVisual writer).
			float dtm;
			if      (drv.player_model_index == 5) dtm = 255;   // sini
			else if (drv.player_model_index == 6) dtm = 254;   // chickenman
			else if (drv.player_model_index == 7) dtm = 253;   // numberK
			else if (drv.player_model_index == 8) dtm = 252;   // kilmer
			else dtm = (drv.player_team - 1) * 4 + bound(0, drv.player_model_index, TEAM_MODEL_COUNT - 1);
			WriteByte(MSG_ENTITY, dtm);
			WriteByte(MSG_ENTITY, bound(0, drv.skin, 255));
			// Resolved seat offsets (per-car key → sv_car_seat_* cvar → default), biased into signed shorts.
			float su = self.seat_up;   if (su == 0) { su = cvar("sv_car_seat_up");   if (su == 0) su = 24; }
			float sf = self.seat_fwd;  if (sf == 0) sf = cvar("sv_car_seat_fwd");
			float ss = self.seat_side; if (ss == 0) ss = cvar("sv_car_seat_side");
			WriteShort(MSG_ENTITY, bound(-32768, rint(su) + 4096, 32767));
			WriteShort(MSG_ENTITY, bound(-32768, rint(sf) + 4096, 32767));
			WriteShort(MSG_ENTITY, bound(-32768, rint(ss) + 4096, 32767));
		}
		else
			WriteByte(MSG_ENTITY, 0);
	}
	return TRUE;
};

// Filing cabinet — a carriable ODE prop. SOLID_PHYSICS_BOX *always*: the velocity
// servo carries a box (it can't translate a trimesh body), and the engine OBB patch
// (world.c World_OBBTrace) makes a rotated box collide as its real oriented shape,
// so the player walks on / shoots the cabinet smoothly at any tilt — no solid swap,
// no per-triangle mesh bumpiness. While carried/just-dropped it's moved to the
// player-passthrough dimension (PHYSDROP_DIM) instead.
void(entity owner) phys_files_spawn_infront =
{
	entity b;
	vector fwd, target, start_high, end_low, ground;
	float dist = 96;
	float search_up = 256;
	float search_down = 4096;
	float drop_height = 8;

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
		sprint(owner, PRINT_HIGH, "spawnfiles: no ground found in front\n");
		return;
	}
	ground = trace_endpos;

	b = spawn();
	b.classname = "phys_files";

	// IQM only — the old HL-studio models/props/filecabinet.mdl fallback is gone (the file does not
	// exist, so the else-branch could only ever produce an "Unable to load"; the whichpack() guard
	// made it unreachable in practice anyway).  See phys_barrel_precache for why IQM-only is also
	// the better collision path.
	setmodel(b, "models/props/filecabinet/filecabinet.iqm");

	// SOLID_PHYSICS_BOX always (tight model hbox).  The velocity-servo carry needs
	// a box body, and the engine OBB patch (world.c World_OBBTrace) makes a rotated
	// SOLID_PHYSICS_BOX collide as its real oriented shape for the player + bullets
	// — smooth at any tilt, no trimesh bumpiness, no swap.  Solid to players via the
	// default dimension; carry moves it to PHYSDROP_DIM (passthrough) instead.
	b.solid = SOLID_PHYSICS_BOX;   // dimension masks set in PhysObj_Setup below
	// Static brightness dim (sv_carry_lightscale; 1 = no dim). colormod is a
	// networked engine-applied multiplier — uniform, not an adaptive cap.
	b.colormod = '1 1 1' * cvar("sv_carry_lightscale");

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] filecabinet loaded: model='%s' modelindex=%g native mins=%v maxs=%v solid=%g\n",
			b.model, b.modelindex, b.mins, b.maxs, b.solid));

	// Tight hbox = the ODE box geom AND the OBB collision box. Origin at the feet
	// (mins_z 0); the engine auto-centres the ODE box on the AABB centre.
	// NOTE: X and Y are SWAPPED vs the model's $hbox (-11.31 -14.37 0 / 11.29 14.39
	// 62.79).  That $hbox came out X/Y-transposed — the same transposition the IQM's
	// ofs_bounds had — so using it verbatim rotated the collision box 90° from the
	// visible model (obvious under cl_debug_physprops).  Swapped here so it lines up.
	setsize(b, '-14.37 -11.31 0', '14.39 11.29 62.79');
	setorigin(b, ground + '0 0 1' * drop_height);
	b.angles = '0 0 0';

	// Carriable metal prop: contact FX on, carry on, NO QC sleep (always-live
	// during carry; relies on its rest-latch + engine autodisable when free).
	b.po_fx_enabled    = TRUE;
	b.po_carry_enabled = TRUE;
	b.po_stuck_grace   = 5;
	b.po_material = PropMat_For(b.model);   // per-material bounce/damp; keeps the tuned cvar carry mass
	PhysObj_Setup(b, cvar("sv_carry_mass"), cvar("sv_physprop_friction"));
	b.think     = PhysObj_Think;   // void cull + contact FX + (carry) re-solidify + CSQC stream
	b.nextthink = time + 0.05;

	// CSQC-networked solid mirror so the client's custom QC pmove + bullet traces
	// collide with the cabinet (engine-replicated props are invisible to it).
	// PVS policy (cull-on-exit vs stay-resident) is centralised — see PhysProp_ApplyPvsPolicy.
	b.SendEntity = phys_files_Send;
	b.SendFlags  = 1;
	PhysProp_ApplyPvsPolicy(b);

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] filecabinet spawned at %v\n", b.origin));
};

// ============================================================================
//  HL2-style carry (phys_files)
//  ---------------------------------------------------------------------------
//  +use grabs the cabinet (toggle: +use again drops); while carried it is
//  driven by a per-tick VELOCITY servo toward a hold point in front of the
//  player.  Driving by velocity (never setorigin) lets ODE resolve world
//  collisions during dWorldStep, so the cabinet slides along walls instead of
//  clipping; when a wall jams it the prop-to-holdpoint distance stays large
//  and (after sv_carry_stuck_time) it auto-drops — the "force it off you and
//  it drops" behaviour.  +attack throws it forward.  Firing is blocked and the
//  viewmodel lowers via the replicated .pm_carrying flag (Weapon_LowerBlocksFire).
// ============================================================================

float(entity e) Carry_IsCarriable =
{
	// Flag-gated (was a "phys_files" classname literal) so any prop that opts in
	// with po_carry_enabled — the filing cabinet AND Source prop_physics (see
	// server/sv_props.qc) — is carriable.  Still require an active ODE body, as
	// the carry velocity-servo drives .velocity on a MOVETYPE_PHYSICS rigid body.
	// carry_allow_any: the gravity gun grabs ANY ODE body (cabinet, barrel, can,
	// weapon drop), not just po_carry_enabled cabinets.  +use leaves it 0.
	// Driveable cars: the GRAVITY GUN (carry_allow_any) may grab an EMPTY car to lift / rotate /
	// flip it (Carry_Tick forces it upright → drop = back on its wheels), but +use (carry_allow_any=0)
	// must NOT carry one — it MOUNTS via the sv_use.qc gate.  Never grab a car with a seated driver.
	// carry_allow_any is only TRUE during the grab call; a HELD car must also stay carriable each
	// Carry_Tick (carried_by != world) or the stale-link check would instant-drop it.
	if (e.classname == "prop_car" || e.classname == "func_car")
		return (carry_allow_any || e.carried_by != world) && (e.car_driver == world);
	return e && e != world && e.movetype == MOVETYPE_PHYSICS
	       && (e.po_carry_enabled || carry_allow_any);
};

// World-space AABB overlap of two entities, computed from origin+mins/maxs
// directly (ODE moves the prop's origin, so we don't trust relinked absmin).
float(entity a, entity b) Carry_BBoxOverlap =
{
	return (a.origin_x + a.mins_x <= b.origin_x + b.maxs_x)
	    && (a.origin_x + a.maxs_x >= b.origin_x + b.mins_x)
	    && (a.origin_y + a.mins_y <= b.origin_y + b.maxs_y)
	    && (a.origin_y + a.maxs_y >= b.origin_y + b.mins_y)
	    && (a.origin_z + a.mins_z <= b.origin_z + b.maxs_z)
	    && (a.origin_z + a.maxs_z >= b.origin_z + b.mins_z);
};

// Player(AABB)-vs-prop ORIENTED-box (OBB) overlap, matching the engine's
// World_OBBTrace exactly: the prop box (prop.mins/maxs) is ROTATED by prop.angles
// (raw angles + right-hand flip, same as the patch — no mesh-pitch), then the
// player's box is tested against it.  This is what the shove-out / re-solidify needs —
// when the cabinet tumbles, the real collision box pokes OUTSIDE the axis-aligned
// hbox, so the old AABB test (Carry_BBoxOverlap) missed a player standing in that
// poke-out and the cabinet then ejected them on going solid.
float(entity prop, entity player) Carry_OBBOverlap =
{
	// Raw angles — matches World_OBBTrace exactly (the IQM uses NO mesh-pitch flip).
	makevectors(prop.angles);   // v_forward, v_right, v_up — box local axes are [vf, -vr, vu]

	vector phalf = (player.maxs - player.mins) * 0.5;
	vector pc    = player.origin + (player.maxs + player.mins) * 0.5;
	vector d     = pc - prop.origin;

	// player centre expressed in the box's local frame
	float lx =  (d * v_forward);
	float ly = -(d * v_right);
	float lz =  (d * v_up);

	// player half-extent projected onto each local axis (rotated-AABB expansion),
	// so the point-vs-box test below is the full box-vs-OBB overlap.
	float ex = fabs(v_forward_x)*phalf_x + fabs(v_forward_y)*phalf_y + fabs(v_forward_z)*phalf_z;
	float ey = fabs(v_right_x)  *phalf_x + fabs(v_right_y)  *phalf_y + fabs(v_right_z)  *phalf_z;
	float ez = fabs(v_up_x)     *phalf_x + fabs(v_up_y)     *phalf_y + fabs(v_up_z)     *phalf_z;

	return (lx >= prop.mins_x - ex && lx <= prop.maxs_x + ex
	     && ly >= prop.mins_y - ey && ly <= prop.maxs_y + ey
	     && lz >= prop.mins_z - ez && lz <= prop.maxs_z + ez);
};

void() Car_Think;   // sv_prop_vehicle.qc (compiled later) — restored on drop so a carried car drives again

void(entity player) Carry_Drop =
{
	entity prop = player.carried_prop;
	if (prop != world)
	{
		prop.carried_by        = world;
		prop.carry_stuck_since = 0;
		prop.gravity           = 0;   // restore normal gravity (was disabled while carried)
		// nettest Patch 71: clamp the released velocity. The carry servo is now UNCAPPED in open space
		// (so the collision hull tracks the client-predicted visual), which can leave a huge
		// prop.velocity mid-swing -> a plain drop would FLING the prop. Cap the release to
		// sv_carry_max_speed. Carry_Throw sets its (intentional) throw velocity AFTER this, so a throw
		// is unaffected.
		float dropcap = cvar("sv_carry_max_speed");
		if (vlen(prop.velocity) > dropcap)
			prop.velocity = normalize(prop.velocity) * dropcap;
		// Stays non-solid to players (PHYSDROP_DIM) so the +attack throw velocity
		// integrates without shoving you, then phys_files_think shoves it clear and
		// restores player-solidity once it settles away from you (or after the
		// carry_resolidify_until timeout).  It's SOLID_PHYSICS_BOX throughout.
		// Weapon drops (grabbable by the gravity gun) resume their OWN settle/sleep
		// think so they come to rest, sleep, and the scrape loop stops; cabinets
		// and generic props use PhysObj_Think.  Without this a gravity-gun-thrown
		// weapon ran the cabinet think, never slept, and scraped forever.
		if (prop.classname == "prop_car" || prop.classname == "func_car")
		{
			// A car owns Car_Think (drive physics) — the generic carry replaced it with the void
			// watchdog on grab, so restore it here or the car is dead after a drop.  Also restore full
			// player-solidity (grab moved it to the PHYSDROP passthrough dimension).
			prop.think           = Car_Think;
			prop.nextthink       = time + 0.05;
			prop.dimension_solid = dimension_default;
			prop.dimension_hit   = dimension_default;
		}
		else if (prop.po_is_weapon_drop)
		{
			prop.think     = W_PhysDropThink;
			prop.nextthink = time + WeaponDrop_NextThinkInterval(prop);
		}
		else
		{
			prop.think     = PhysObj_Think;
			prop.nextthink = time + 0.05;
		}
		prop.carry_resolidify_until = time + 5;
		prop.SendFlags             |= 1;   // flip carrier→0 on the next snapshot (ends client predict)
		// Re-baseline the impact-drop tracker to the CURRENT speed: phys_files_think is
		// paused while carried, so pp_prev_speed is stale from before the grab.  Without
		// this, grabbing a fast-moving prop then dropping it would read a huge phantom
		// "drop" on the first free think and fire a false impact.
		prop.pp_prev_velocity = prop.velocity;
		prop.pp_was_touching  = FALSE;
		PhysFiles_StopScrape(prop);   // end any carry-drag scrape; the free think restarts it if it slides
	}
	player.carried_prop       = world;
	player.pm_carrying        = FALSE;
	player.pm_carry_fire_last = 0;
};

void(entity player) Carry_Throw =
{
	entity prop = player.carried_prop;
	float  tf   = 0;
	// Direct velocity set (not addforce) — predictable oomph regardless of mass; view-directed so
	// looking up throws it up.  Inherits the player's own velocity so a running throw carries momentum.
	// The gravity gun throws much harder than a bare-hands +use heave.
	if (prop != world && prop.movetype == MOVETYPE_PHYSICS)
	{
		makevectors(player.v_angle);   // sets v_forward (used after Carry_Drop; Carry_Drop won't touch it)
		tf = (player.weapon == WEP_GRAVITYGUN)
		   ? cvar("sv_gravgun_throw_speed") : cvar("sv_carry_throw_force");
	}
	// nettest Patch 71: release FIRST. Carry_Drop now clamps the residual servo velocity (drop-fling
	// guard), so the THROW velocity must be set AFTER it — else the throw would be clamped too. Drop
	// also stops the servo (carried_by=world) so the throw isn't overwritten next tick.
	Carry_Drop(player);
	if (prop != world && prop.movetype == MOVETYPE_PHYSICS)
	{
		physics_enable(prop, TRUE);   // wake so the throw velocity is integrated
		prop.velocity = v_forward * tf + player.velocity;
		prop.pp_prev_velocity = prop.velocity;   // re-baseline impact tracker to the throw (Carry_Drop set it to the clamped residual)
		PhysProp_KickStream(prop);   // push the throw velocity to clients on the next tick
		if (cvar("sv_debug_physprops"))
			dprint(sprintf("[carry] throw prop=%g vel=%v\n", num_for_edict(prop), prop.velocity));
	}
};

// Per-component SHORTEST-PATH angle lerp — normalises each delta to [-180,180) so the
// prop rotates the short way into the carry orientation during the grab pull-in (a raw
// lerp from e.g. 350->10 would spin almost all the way round the long way).
vector(vector a, vector b, float f) Carry_AnglesLerp =
{
	vector r;
	float d;
	d = b_x - a_x; d = d - 360 * floor((d + 180) / 360); r_x = a_x + d * f;
	d = b_y - a_y; d = d - 360 * floor((d + 180) / 360); r_y = a_y + d * f;
	d = b_z - a_z; d = d - 360 * floor((d + 180) / 360); r_z = a_z + d * f;
	return r;
};

float(entity player, entity prop) Carry_TryGrab =
{
	if (!Carry_IsCarriable(prop))     return FALSE;
	if (prop.carried_by != world)     return FALSE;   // already held by someone
	if (player.carried_prop != world) return FALSE;   // already carrying

	player.carried_prop    = prop;
	prop.carried_by        = player;
	prop.carry_stuck_since = 0;
	prop.avelocity         = '0 0 0';
	PhysProp_Wake(prop);   // a settled prop is on the slow sleep tick — grabbing it must resume
	                       // the full-rate think NOW (it drives the carry re-solidify + mirror stream)
	// Record the floor pose + start time so Carry_Tick can smoothly PULL the prop
	// into the carry pose over sv_carry_grab_time instead of snapping (Source-like).
	prop.carry_grab_time   = time;
	prop.carry_grab_origin = prop.origin;
	prop.carry_grab_angles = prop.angles;
	prop.pp_prev_origin    = prop.origin;   // seed so the first steady-carry frame's delta is clean (no false bang)
	prop.pp_impact_cooldown = time + cvar("sv_carry_grab_time");  // no bang during the pull-in
	PhysFiles_StopScrape(prop);   // if it was sliding when grabbed, the think stops — kill the loop now
	// Grab "clunk" — a soft solid-metal thunk as you heft the cabinet.  CHAN_BODY is
	// free here: the impact detector is suppressed during the pull-in (cooldown set
	// above), so this is the only CHAN_BODY one-shot on grab.
	sound(prop, CHAN_BODY, sprintf("sounds/impacts/metal_solid_impact_soft%g.wav",
	      bound(1, floor(random() * 3) + 1, 3)), 1.0, ATTN_NORM);
	prop.pp_was_touching = FALSE; // first carry contact is a fresh bang, not a continued drag
	// Disable gravity while carried (FTE: gravity scale in (0, 0.01] = OFF).  The
	// velocity servo positions the prop, so gravity is just a downward disturbance —
	// against the floor it sank the prop a hair each frame and the servo popped it
	// back, a 2-frame fight that read as bouncing in/out of the ground.  With gravity
	// off the prop holds steady at the (wall/floor-clamped) hold point. Restored on drop.
	prop.gravity = 0.005;
	// Move to the player-passthrough dimension (PHYSDROP_DIM): non-solid to the
	// carrier so it doesn't shove them, but still world-collides (ODE contact
	// ignores the dim filter) so it slides on walls.  Wake the ODE body — a resting
	// body is autodisabled and .velocity alone wouldn't wake it, so the servo would
	// be ignored ("locks in place").  No solid swap — it's SOLID_PHYSICS_BOX already.
	prop.dimension_solid = PHYSDROP_DIM;
	prop.dimension_hit   = dimension_default | PHYSDROP_DIM;
	physics_enable(prop, TRUE);
	// Keep the void watchdog while held; re-solidify to players happens after drop
	// (in phys_files_think, once it settles and is clear of you).
	prop.think     = PhysProp_VoidWatchdog;
	prop.nextthink = time + 1;
	player.pm_carrying     = TRUE;
	// Seed the throw latch with the current fire state so holding +attack at
	// grab time doesn't immediately fire a throw.
	player.pm_carry_fire_last = (player.button0 != 0);
	prop.SendFlags |= 1;   // flip the carry-phase + carrier bytes on the next snapshot

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[carry] grab prop=%g by=%g\n",
			num_for_edict(prop), num_for_edict(player)));
	return TRUE;
};

void(entity player) Carry_Tick =
{
	entity prop = player.carried_prop;
	if (prop == world)
		return;

	// Stale link — prop removed by the void watchdog, class swapped, or
	// re-grabbed by someone else.  Release cleanly.
	if (!Carry_IsCarriable(prop) || prop.carried_by != player)
	{
		Carry_Drop(player);
		return;
	}

	// Keep the body awake so the velocity servo is integrated (autodisable
	// would freeze it when momentarily stationary at the hold point), and stop
	// the stuck-despawn timer from accumulating while the prop is held in air.
	// (+attack throw is handled in PlayerPreThink before the weapon frame.)
	physics_enable(prop, TRUE);
	prop.phys_stuck_since = 0;

	// A CAR is far bigger than a cabinet: hold it further out + higher so the big body sits clear
	// in front (not embedded in the ground/player), and — critically — take the RAW hold with NO
	// clip-slide so the ODE body reaches the SAME point the client predicts (phys_files_Send streams
	// these same car values), which is what stops the model-vs-hitbox disconnect on a grabbed car.
	float is_car = (prop.classname == "prop_car" || prop.classname == "func_car");

	makevectors(player.v_angle);
	float hdist = is_car ? cvar("sv_car_carry_dist") : cvar("sv_carry_hold_dist");
	float hz    = is_car ? cvar("sv_car_carry_z")    : cvar("sv_carry_hold_z");
	vector hold = player.origin + player.view_ofs
	            + v_forward * hdist
	            + '0 0 1'   * hz;
	// Aim the box CENTRE at the hold point (the model origin is at the feet).
	vector center = prop.origin + '0 0 1' * ((prop.maxs_z + prop.mins_z) * 0.5);

	// Resolve the hold point against geometry with a CLIP-AND-SLIDE (the same scheme
	// the player pmove uses): trace the prop's box toward the hold point; if it hits a
	// surface, drop the into-surface component of the remaining motion and re-trace, up
	// to 4 planes.  This lets the carried prop SLIDE along floors/walls instead of
	// sticking at the first contact (the "sticks to the ground, only rotates" you saw),
	// while never being driven into geometry.  MOVE_NOMONSTERS = world + brushwork only,
	// so a carried prop still pushes OTHER phys props aside rather than clamping on them.
	vector boxhalf = (prop.maxs - prop.mins) * 0.5;
	vector cur = center;
	vector tgt = hold;
	float  bump;
	float  hit_surface = FALSE;        // did the clip-slide bump a real surface? (carry-bang)
	float  was_startsolid = FALSE;     // Patch 71: trace started embedded (resting grab / mid-carry shove-in)
	vector hit_point   = '0 0 0';
	vector hit_normal  = '0 0 1';
	if (!is_car)   // cars take the RAW hold (no clip-slide) so the body matches the client-predicted hold
	for (bump = 0; bump < 4; bump = bump + 1)
	{
		tracebox(cur, '0 0 0' - boxhalf, boxhalf, tgt, MOVE_NOMONSTERS, prop);
		if (trace_startsolid)
		{
			// Box already overlaps geometry — almost always a prop resting upright on
			// the floor with ODE's tiny contact penetration, so a trace from its centre
			// is startsolid.  The old `break` left hold=centre, freezing the grab in
			// place (the "upright prop won't pick up, only rotates until you shoot it"
			// bug).  Aim straight at the raw hold so the carry LIFTS it out; once it's
			// clear the next frames clip-slide normally.  A HELD prop is kept off
			// surfaces by the clamp, so this only fires on the resting grab, not mid-carry.
			cur = tgt;
			was_startsolid = TRUE;   // Patch 71: keep the servo CAPPED here (aim is the RAW hold) so an
			                         // embedded prop is eased out at sv_carry_max_speed, not flung.
			break;
		}
		cur = trace_endpos;        // advance to the contact (or all the way if clear)
		if (trace_fraction >= 1)
			break;                 // reached the target
		// A real surface contact this bump — remember it for the carry-bang test below.
		hit_surface = TRUE;
		hit_point   = trace_endpos;
		hit_normal  = trace_plane_normal;
		// Slide: remove the part of the remaining motion that goes INTO the plane.
		vector rem = tgt - cur;
		tgt = cur + rem - trace_plane_normal * (rem * trace_plane_normal);
	}
	if (!is_car)
		hold = cur;                // slid, reachable hold point (cars keep the raw hold above)

	// GRAB PULL-IN: for the first sv_carry_grab_time after grabbing, smoothly lerp the
	// prop from its floor pose into the carry pose (Source-like "pull + rotate into
	// position") instead of the servo snapping/flinging it there.  Scripted move
	// (setorigin + angles, zero velocity) toward the LIVE (slid) hold so it still tracks
	// if you move; the velocity servo + stuck logic take over once the window elapses.
	float gtime = cvar("sv_carry_grab_time");
	if (gtime > 0 && time - prop.carry_grab_time < gtime)
	{
		float gf = (time - prop.carry_grab_time) / gtime;
		gf = gf * gf * (3 - 2 * gf);                       // smoothstep ease in/out
		vector tgt_org   = hold - '0 0 1' * ((prop.maxs_z + prop.mins_z) * 0.5);
		vector carry_ang = '0 0 0';
		carry_ang_y      = player.v_angle_y + 180;
		setorigin(prop, prop.carry_grab_origin + (tgt_org - prop.carry_grab_origin) * gf);
		prop.angles            = Carry_AnglesLerp(prop.carry_grab_angles, carry_ang, gf);
		prop.velocity          = '0 0 0';
		prop.avelocity         = '0 0 0';
		prop.carry_stuck_since = 0;            // don't accrue "stuck" during the pull-in
		prop.pp_prev_origin    = prop.origin;  // track the lerp so the first steady frame's delta is clean
		prop.SendFlags        |= 1;            // stream the animation to clients
		return;
	}

	vector delta  = hold - center;
	float  dist   = vlen(delta);

	// Force-drop: distance stays past drop_dist for sv_carry_stuck_time (the
	// cabinet is jammed on geometry and can't follow), OR a hard far-cap for
	// pathological cases.  A brief over-distance from a fast turn resets as
	// soon as the servo catches up, so normal carrying never trips this.
	// Cars skip the stuck/far auto-drop (a big body legitimately sits far from centre + can't clip-slide
	// to a nearer point) — you drop it deliberately.  Cabinets/props keep the jam-detect drop.
	float drop_dist = cvar("sv_carry_drop_dist");
	if (!is_car && dist > drop_dist * 3)
	{
		Carry_Drop(player);
		return;
	}
	if (!is_car && dist > drop_dist)
	{
		if (prop.carry_stuck_since == 0)
			prop.carry_stuck_since = time;
		else if (time - prop.carry_stuck_since > cvar("sv_carry_stuck_time"))
		{
			if (cvar("sv_debug_physprops"))
				dprint(sprintf("[carry] drop (stuck dist=%g) prop=%g\n",
					dist, num_for_edict(prop)));
			Carry_Drop(player);
			return;
		}
	}
	else
		prop.carry_stuck_since = 0;

	// --- Carry contact FX ---  The servo velocity is clamped near a wall, so the speed
	// comes from the prop's ACTUAL motion (origin delta).  Distinguish a BANG from a DRAG
	// by contact DURATION: the FIRST tick of contact (you swung it into the surface) at
	// speed = a bang (impact sound); SUSTAINED contact while still moving = dragging along
	// the surface (you'd otherwise hear a string of impacts) = the looping scrape + puffs.
	// The grab pull-in returned above, so we're in steady carry.
	float cft = frametime; if (cft <= 0) cft = 0.013;
	float actual_speed = vlen(prop.origin - prop.pp_prev_origin) / cft;
	if (hit_surface)
	{
		if (prop.pp_was_touching && actual_speed >= cvar("sv_physprop_slide_min_speed"))
		{
			// Sustained contact + moving = dragging → scrape loop (volume by speed) + puffs
			// at the actual contacted surface.
			PhysFiles_StartScrape(prop, actual_speed);
			if (time >= prop.pp_slide_next)
			{
				prop.pp_slide_next = time + cvar("sv_physprop_slide_interval");
				PhysFiles_SmokeAlong(prop, hit_normal * -1, 0);
			}
		}
		else if (!prop.pp_was_touching && time >= prop.pp_impact_cooldown
		         && actual_speed >= cvar("sv_physprop_impact_min_speed"))
		{
			// First contact at speed = a bang → impact sound + smoke (dir = into surface).
			PhysFiles_EmitImpact(prop, actual_speed, hit_normal * -1);
		}
	}
	prop.pp_was_touching = hit_surface;
	if (prop.pp_scrape_active && time > prop.pp_slide_active_until)
		PhysFiles_StopScrape(prop);
	prop.pp_prev_origin = prop.origin;

	// Velocity servo toward the hold point, clamped.  ODE integrates this and
	// resolves wall contacts → slide.
	float ft = frametime;
	if (ft <= 0) ft = 0.013;
	vector desired = delta * (1 / ft);
	// nettest Patch 71: only CAP the servo when a wall is in the hold path (hit_surface). The
	// clip-slide already clamped the hold to the nearest wall, so in OPEN space (!hit_surface) the
	// full straight path to the target is clear -> UNCAP so the ODE body reaches the clip-slid hold
	// THIS frame and tracks the client-predicted visual ~1:1 (was capped at sv_carry_max_speed, ~15.6
	// qu/frame @ 64Hz -> the hull trailed on fast mouse swings + tunnelled on a fast pickup-swing).
	// Tunnel-safe: !hit_surface means nothing was hit along the whole path. Still an ODE body, so it
	// still pushes other props on contact. (Remote clients keep a ping/2 floor — server-authoritative.)
	float  maxsp   = cvar("sv_carry_max_speed");
	if ((hit_surface || was_startsolid) && vlen(desired) > maxsp)
		desired = normalize(desired) * maxsp;

	// nettest Patch 70: wall deadband — when the clip-slide clamped the hold against a surface
	// (hit_surface) and the prop is essentially AT it (dist < band), remove the INTO-wall component
	// of the servo so ODE RESTS the body at the wall instead of oscillating. That kills the
	// r_showhull jitter vs the steady client-predicted visual (server now matches the clamped hold
	// 1:1). Tangential slide-along survives; the away component (into>=0) is untouched so backing
	// the view away grows `dist` past the band and the full servo resumes (instant un-stick).
	if (hit_surface && dist < cvar("sv_carry_wall_deadband"))
	{
		float into = desired * hit_normal;   // hit_normal points OUT of the wall; into<0 = driving in
		if (into < 0)
			desired = desired - hit_normal * into;
	}
	prop.velocity = desired;

	// Locked orientation: upright, facing the carrier.  Writing .angles each
	// tick re-orients the live ODE body (engine pushes it via dBodySetRotation).
	prop.angles    = '0 0 0';
	prop.angles_y  = player.v_angle_y + 180;
	prop.avelocity = '0 0 0';

	// Stream every server frame while held so the CSQC mirror tracks the hold
	// point smoothly (the 20 Hz think gate alone reads choppy on a fast strafe).
	prop.SendFlags |= 1;
};

// Called from hitscan paths after the weapon's traceline. If the hit ent is a
// physics prop, apply a world-space force at the hit point.
float(vector shot_dir, float damage) PhysProp_TryPushFromTrace =
{
	if (trace_ent == world) return FALSE;
	if (trace_ent.weapon && trace_ent.weapon_physdrop_sleeping)
		W_PhysDropWake(trace_ent);
	if (trace_ent.movetype != MOVETYPE_PHYSICS) return FALSE;

	// ×100 so the cvar can be 100x smaller (sv_physprop_hit_force ~128 instead of
	// ~12800).  × iter so the delivered impulse is INDEPENDENT of
	// physics_ode_iterationsperframe: physics_addforce applies the force for only the
	// first of N=iterations substeps (impulse = force*frametime/iterations,
	// com_phys_ode.c World_ODE_Frame), so without the × iter, raising iterations for
	// smoothness shrinks the kick.  Baseline is iterations=1 (× iter, NOT × iter/4 —
	// the old /4 assumed iterations=4 and quartered the force for anyone running 1).
	// Backend-aware: xN on ODE (cancels its per-substep force divide), 1 on Box3D where the
	// force applies over the whole frame (else physics_ode_iterationsperframe = phantom push).
	float iter = Phys_ForceIter();
	vector force = shot_dir * (damage * cvar("sv_physprop_hit_force") * 100 * iter);

	// Cars are heavy — give them a stronger, tunable "punch" so a hit visibly shoves them,
	// scaled DOWN when someone's driving (don't fling a car with a passenger). Bullets and
	// melee both route through here (sh_wpn_melee.qc), so this covers both.
	if (trace_ent.classname == "prop_car" || trace_ent.classname == "func_car")
	{
		float cf = cvar("sv_car_hit_force"); if (cf <= 0) cf = 4;
		if (trace_ent.car_driver != world)
		{
			float os = cvar("sv_car_occupied_push_scale"); if (os <= 0) os = 0.4;
			cf = cf * os;
		}
		force = force * cf;
	}

	if (cvar("sv_debug_physprops"))
		dprint(sprintf("[physprop] bullet ent=%g force=%v at=%v\n",
			num_for_edict(trace_ent), force, trace_endpos));

	physics_addforce(trace_ent, force, trace_endpos);
	PhysProp_KickStream(trace_ent);   // snappy mirror update on the hit (instant react), still stream_hz-capped
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
	// Same ×100 (smaller cvar) + ×iter (impulse iter-independent, baseline 1) as the
	// bullet push (see PhysProp_TryPushFromTrace).
	float iter = Phys_ForceIter();   // backend-aware (xN on ODE, 1 on Box3D — see sh_weapon_logic.qc)
	force_scale = force_scale * 100 * iter;

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
				PhysProp_KickStream(e);   // snappy mirror update on the explosion jolt
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
	PhysProp_KickStream(self);   // snappy mirror update on the +use shove
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
