//
//  sv_prop_vehicle.qc — driveable raycast car: prop_car (model) [+ func_car brush, Stage 2].
//
//  The chassis is a MOVETYPE_PHYSICS rigid body set up exactly like prop_physics
//  (PhysObj_Setup + the phys_files CSQC mirror), so it renders, falls, and collides
//  for free.  We add: the raycast drive tick (Car_PhysStep, sh_vehicle_phys.qc), a
//  +use mount/exit lifecycle, and a clear-spot finder for exit.  Server-authoritative.
//
//  Driver while seated: non-solid + invisible + frozen, setorigin'd to the seat each
//  tick.  The client third-person camera follows (the hidden body is pinned to the
//  car, so predicted_player already tracks it — see cl_main.qc).
//

.float car_saved_solid;      // driver's solid/movetype stashed on mount, restored on exit
.float car_saved_movetype;

// Parked-car sleep thresholds (see the sleep gate in Car_Think).  Matched to the net
// rest-latch's own >1 qu/s cut just below, so a car only sleeps once that latch has already
// streamed its final parked pose to clients.
const float CAR_SLEEP_LIN   = 1;
const float CAR_SLEEP_ANG   = 1;
// Hold still this long before freezing the body.  Generous on purpose: a car that has just
// been parked is often still settling on its suspension springs, and re-freezing mid-settle
// would lock in a visibly leaning pose.
const float CAR_SLEEP_DELAY = 0.75;

float() Car_TickInterval =
{
	float t = car_cached_mintic;   // per-frame cache (StartFrame) — this runs per car per tick
	if (t <= 0) t = 0.0156;
	return t;
};

void() Car_Think;   // forward

// Shared setup for both car forms: physics body + drive think + CSQC mirror.
// Build the physics collision box from the raw model AABB, optionally rotated 90° (box_yaw / sv_car_box_yaw) so it
// lines up with the visible model.  CRITICAL: BOTH the SOLID_PHYSICS_BOX (setsize here) AND Car_WheelLocal read
// car.ab_mins/ab_maxs, so the collision shape and the wheel frame ALWAYS stay aligned — that unified box/wheel
// frame is exactly why the brush (func_car) sits still.  No height cap (the ×iter fix made the full box stable).
void(entity car) Car_ApplyCollisionBox =
{
	float by  = car.box_yaw + cvar("sv_car_box_yaw");
	float bym = by - floor(by / 180) * 180;         // fold to 0..180; ~90 = rotate the AABB a quarter turn
	vector sw_mins, sw_maxs;
	if (bym > 45 && bym < 135)
	{
		sw_mins = [car.raw_mins_y, car.raw_mins_x, car.raw_mins_z];   // swap X/Y extents
		sw_maxs = [car.raw_maxs_y, car.raw_maxs_x, car.raw_maxs_z];
	}
	else
	{
		sw_mins = car.raw_mins;
		sw_maxs = car.raw_maxs;
	}
	// RE-CENTRE the box's X/Y on the entity origin (keep Z) so the physics centre-of-mass (box geomcenter)
	// sits at the origin — same as the brush's ORIGIN brush.  Without this, a model whose origin isn't its
	// geometric centre loads the 4 wheels off-CG → it rests tilted → the tilted spring drifts it forward and
	// dances.  BOTH the box AND Car_WheelLocal read ab_*, so wheels stay centred on the CG too.
	float hx = (sw_maxs_x - sw_mins_x) * 0.5;
	float hy = (sw_maxs_y - sw_mins_y) * 0.5;
	// wheel_sink raises the box FLOOR (and, since Car_WheelLocal mounts at ab_mins_z, the wheel mounts) so the
	// whole car settles `sink` lower → the model's visual wheels drop toward the ground instead of floating on
	// the raycast springs.  The box wraps the body; the wheels poke out below it (fine — they're visual only).
	// OVERRIDE (per-car key wins, else the cvar) — like every other tuning key.  Was additive, which stacked a
	// baked FGD per-car value on top of the cvar so "set the cvar" never gave the clean value.
	float sink = (car.wheel_sink != 0) ? car.wheel_sink : cvar("sv_car_wheel_sink");
	if (sink < 0) sink = 0;
	float floorz = sw_mins_z + sink;
	if (floorz > sw_maxs_z - 1) floorz = sw_maxs_z - 1;    // never invert / collapse the box
	car.ab_mins = [-hx, -hy, floorz];
	car.ab_maxs = [ hx,  hy, sw_maxs_z];
	setsize(car, car.ab_mins, car.ab_maxs);
	car.applied_box_yaw    = by;
	car.applied_wheel_sink = sink;
};

void() Car_CommonSpawn =
{
	self.car_driver = world;

	// Resolve the model's pitch-scale class: the engine applies r_meshpitch ONLY to mod_alias
	// (IQM / Quake .mdl).  HL-studio .mdl (mod_halflife) and inline brushes (mod_brush) are NOT
	// scaled, so they need pitch-scale 1.  mesh_type FGD key overrides the extension auto-detect.
	// (logicops-off safe: nested ifs, never index a string inside a && — see fteqcc-logicops memory.)
	self.mesh_noscale = 0;
	if (self.mesh_type == 1)
		self.mesh_noscale = 0;                       // force alias (Quake .mdl edge case)
	else if (self.mesh_type == 2)
		self.mesh_noscale = 1;                       // force halflife
	else
	{
		string mn = self.model;
		float L = strlen(mn);
		if (L >= 1)
		{
			if (substring(mn, 0, 1) == "*")
				self.mesh_noscale = 1;               // inline brush model (func_car) → mod_brush
			else if (L >= 4)
			{
				if (substring(mn, L - 4, 4) == ".mdl")
					self.mesh_noscale = 1;           // HL studio .mdl → mod_halflife
			}
		}
	}

	float pmass = (self.mass > 0) ? self.mass : Car_Cvar(0, "sv_car_mass", 1200);
	self.po_material = -1;   // cars keep their own tuned physics (no prop-material)
	PhysObj_Setup(self, pmass, cvar("sv_physprop_friction"));   // MOVETYPE_PHYSICS + backend body
	// po_material -1 means PhysObj_Setup resolved no sound set — pin cars to sheet metal so
	// wall bangs (sh_vehicle_phys.qc) and the grind loop keep their timbre.
	self.po_sndset = MatSnd_SetIndex("metal");
	self.use = __NULL__;             // +use handled by the mount gate (sv_use.qc), not .use

	self.think     = Car_Think;
	self.nextthink = time + Car_TickInterval();

	// Reuse the prop_physics CSQC solid mirror (phys_files_Send): renders the chassis
	// on clients + lets the local pmove / bullets collide, no new wire needed.
	// PVS policy is centralised — see PhysProp_ApplyPvsPolicy (sv_physprop.qc).  Culling a
	// car mirror is what makes CSQC_Ent_Remove's wheel/driver cleanup mandatory (cl_main.qc).
	self.SendEntity = phys_files_Send;
	self.SendFlags  = 1;
	PhysProp_ApplyPvsPolicy(self);

	// Wheel model for the client-rendered spinning wheels: precache it and stash the network index
	// (0 = no wheelmodel key = wheels baked into the chassis, no separate wheels).  phys_files_Send
	// streams this index on the is-car branch; Car_DrawWheels (cl_physprop.qc) renders 4 of them.
	if (self.wheelmodel != "")
	{
		precache_model(self.wheelmodel);
		self.car_wheel_mdlidx = getmodelindex(self.wheelmodel);
	}

	// Resolve the wheel spacing the physics uses (Car_WheelLocal auto path) ONCE at spawn and network it,
	// so the client's visual wheels land where the physics wheels are — and respect the wheel_base/track
	// keys.  ab_* are set by Car_ApplyCollisionBox (before this).
	float myr = (self.model_yaw + cvar("sv_car_model_yaw")) * 0.0174533;
	float cy = fabs(cos(myr)), sy = fabs(sin(myr));
	float bx = self.ab_maxs_x - self.ab_mins_x;
	float by = self.ab_maxs_y - self.ab_mins_y;
	self.res_base  = Car_Cvar(self.wheel_base,  "sv_car_base",  0);  if (self.res_base  <= 0) self.res_base  = (bx * cy + by * sy) * 0.9;
	self.res_track = Car_Cvar(self.wheel_track, "sv_car_track", 0);  if (self.res_track <= 0) self.res_track = (bx * sy + by * cy) * 0.9;
	self.res_drop  = self.wheel_drop;
	self.res_fwd   = Car_Cvar(self.wheel_fwd, "sv_car_wheel_fwd", 0);   // fore/aft shift (key → global cvar → 0)
};

/*QUAKED prop_car (.35 .63 .78) ? — driveable raycast car (model chassis). +use to drive. */
void() prop_car =
{
	if (self.model == "")
	{
		dprint("prop_car with no model — removed\n");
		remove(self);
		return;
	}
	precache_model(self.model);
	// QW setmodel needs these to copy the REAL model bbox (else a ±16 stub) — see the
	// qw-setmodel-no-bbox trap; same as sv_props.qc.
	cvar_set("sv_gameplayfix_setmodelsize_qw", "1");
	cvar_set("sv_gameplayfix_setmodelrealbox", "1");
	setmodel(self, self.model);

	// The SCALED model AABB is the SOURCE; Car_ApplyCollisionBox derives ab_* (raw, optional 90° swap) which BOTH
	// the collision box AND the wheels use — kept aligned, exactly like the brush (that alignment = no bounce).
	float sc = self.scale; if (sc <= 0) sc = 1;
	self.raw_mins = self.mins * sc;
	self.raw_maxs = self.maxs * sc;
	// box_yaw is purely the mapper's key now (default 0) — no auto .mdl quarter-turn.  The auto-90 fought a
	// manually-set box_yaw (double-rotated the box 90° off the wheels).  Dial box_yaw in the editor / via the
	// live sv_car_box_yaw global instead.
	self.box_managed = 1;
	Car_ApplyCollisionBox(self);      // sets ab_* (= raw, optional 90° swap) + setsize — box == wheel frame

	// Body collision shape (sv_car_collision).  ab_* + the setsize above are the WHEEL-MOUNT frame and stay
	// put in BOTH modes (so the visual wheels never move); this only chooses the player/bullet/world collider.
	//   1 = ACD MESH (default): SOLID_PHYSICS_TRIMESH.  NO geomtype → the SIM body is the same convex-hull
	//       decomposition the player/bullets trace, so pmove and physics share one shape → a player standing/
	//       jumping on it rests on the hull (no fling), and the low body clears kerbs.  IQM/MD3 only.
	//   0 = oriented box (World_OBBTrace).  Also the fallback for a non-trimesh (.mdl) model.
	if (cvar("sv_car_collision") != 0 && Prop_IsTrimeshModel(self.model))
		self.solid = SOLID_PHYSICS_TRIMESH;   // player + bullets + world hit the exact ACD hull (sim body too)
	else
		self.solid = SOLID_PHYSICS_BOX;       // oriented-box collision (World_OBBTrace)

	Car_CommonSpawn();
};

/*QUAKED func_car (.35 .63 .78) ? — brush chassis. REQUIRES an ORIGIN-textured brush inside it (like
   func_rotating) to define the pivot; without one the brush's origin is 0 0 0 and the physics body,
   seat and camera all end up at the world origin. */
void() func_car =
{
	setmodel(self, self.model);       // inline brush model — sets mins/maxs; origin stays 0 0 0 w/o ORIGIN brush
	// A rotating physics brush needs a real pivot.  Inline brush geometry is baked in world space and offset
	// by .origin, so we CANNOT auto-centre (that double-offsets the geometry) — the mapper must add an ORIGIN
	// brush.  If origin is still 0 0 0, refuse rather than teleport the driver to the void.
	if (self.origin == '0 0 0')
	{
		dprint("func_car needs an ORIGIN-textured brush inside it (defines the pivot) — removed\n");
		remove(self);
		return;
	}
	setsize(self, self.mins, self.maxs);   // keep the brush box as-is (func_car already sits/drives fine)
	self.ab_mins  = self.mins;             // active collision box (= brush box)
	self.ab_maxs  = self.maxs;
	self.raw_mins = self.mins;             // raw AABB — Car_WheelLocal derives base/track from THIS
	self.raw_maxs = self.maxs;
	self.box_managed = 0;                  // don't re-manage a brush box
	self.solid = SOLID_PHYSICS_BOX;        // a physics brush collides as its bounding box
	Car_CommonSpawn();
};

// ---------------------------------------------------------------------------
// Mount / exit (called from the +use gate in sv_use.qc).
// ---------------------------------------------------------------------------
entity(entity plyr) Car_FindMountable =
{
	// standing on / touching a car?
	tracebox(plyr.origin, plyr.mins, plyr.maxs, plyr.origin - '0 0 8', MOVE_NOMONSTERS, plyr);
	if (trace_fraction < 1 && trace_ent != world && !trace_startsolid)
	{
		if (trace_ent.classname == "prop_car" || trace_ent.classname == "func_car")
		{
			if (trace_ent.car_driver == world)
				return trace_ent;
		}
	}
	// AIM: looking straight at a car's collision box (thin ray from the eye) → get in.  Makes +use
	// forgiving — you don't have to be standing on it, just aim at it within reach.
	makevectors(plyr.v_angle);
	vector eye = plyr.origin + plyr.view_ofs;
	traceline(eye, eye + v_forward * 160, MOVE_NORMAL, plyr);
	if (trace_fraction < 1 && trace_ent != world && !trace_startsolid)
	{
		if (trace_ent.classname == "prop_car" || trace_ent.classname == "func_car")
		{
			if (trace_ent.car_driver == world)
				return trace_ent;
		}
	}
	// else a short radius reach so you can walk up and press +use
	entity e = findradius(plyr.origin, 96);
	while (e != world)
	{
		if (e.classname == "prop_car" || e.classname == "func_car")
		{
			if (e.car_driver == world)
				return e;
		}
		e = e.chain;
	}
	return world;
};

// A clear player-hull spot beside the car to drop the driver; never void / in-solid.
vector(entity plyr, entity car) Car_FindClearSpot =
{
	// Start OUTSIDE the car: circumscribed planar radius (rotation-proof) + player radius + skin.
	float car_rad = 0.5 * vlen([car.maxs_x - car.mins_x, car.maxs_y - car.mins_y, 0]);
	float r = car_rad + 16 + 8;
	while (r <= 220)
	{
		float ang = 0;
		while (ang < 360)
		{
			makevectors([0, car.angles_y + ang, 0]);
			// Start the sweep ABOVE the car top, not near its origin.  The player hull is CENTER-origin
			// (mins_z ≈ −36), so a low start put the hull bottom below the floor → startsolid at the trace
			// START → every spot rejected → roof fallback.  Sweep from above, IGNORE THE CAR (world only).
			vector top = car.origin + v_forward * r + '0 0 1' * (car.maxs_z + 48);
			tracebox(top, plyr.mins, plyr.maxs, top - '0 0 256', MOVE_NORMAL, car);
			if (!trace_startsolid && !trace_allsolid && trace_fraction < 1)
			{
				vector cand = trace_endpos + '0 0 1';   // trace_endpos = center-origin resting pos; +1 skin
				tracebox(cand, plyr.mins, plyr.maxs, cand, MOVE_NORMAL, car);   // final: spot itself clear?
				if (!trace_startsolid && !trace_allsolid)
					return cand;
			}
			ang = ang + 45;
		}
		r = r + 40;
	}
	// Fallback: lifted above the car (validated).
	vector roof = car.origin + '0 0 1' * (car.maxs_z + 24);
	tracebox(roof, plyr.mins, plyr.maxs, roof, MOVE_NORMAL, car);
	if (!trace_startsolid && !trace_allsolid)
		return roof;
	// Last resort: a horizontal offset well outside the car.
	makevectors([0, car.angles_y + 45, 0]);
	return car.origin + v_forward * (car_rad + 48);
};

float(entity plyr, entity car) Car_TryMount =
{
	if (car == world) return FALSE;
	if (car.car_driver != world && car.car_driver != plyr) return FALSE;

	car.car_driver = plyr;

	// IGNITION: crank the engine — throttle stays dead in Car_PhysStep until this
	// passes (matches the client's car_start.wav one-shot, cl_vehicle_sound.qc).
	float igntime = cvar("sv_car_ignition_time");
	if (igntime <= 0) igntime = 1.2;
	car.car_ignition_until = time + igntime;
	car.car_gear_srv = 0;

	// stash + hide/freeze the driver (physprop-style)
	plyr.car_saved_solid    = plyr.solid;
	plyr.car_saved_movetype = plyr.movetype;
	plyr.car_driving        = car;
	plyr.car_in_fwd         = 0;
	plyr.car_in_side        = 0;
	plyr.solid              = SOLID_NOT;
	plyr.movetype           = MOVETYPE_NONE;
	// Keep the real player edict HIDDEN (the alive-player convention, PlayerApplyModel alpha -1) — its
	// standing body would be server-tick jittery and fight the low car.  The seated body is drawn
	// CLIENT-SIDE, glued to the interpolated car (Car_DrawDriver, cl_physprop.qc), and networked on the
	// is-car branch only when sv_car_show_driver.  So sv_car_show_driver now gates that client render,
	// not this edict's visibility.
	plyr.alpha              = -1;
	plyr.drawonlytoclient   = world;
	plyr.pm_incar           = TRUE;   // replicated LAST → pmove input-zero + fire-block + camera

	// Wake, don't just enable: a parked car may be asleep with its body explicitly disabled
	// AND the QC car_asleep latch set (Car_Think sleep gate).  physics_enable alone would
	// leave that latch set, so Car_PhysStep would stay skipped and the car you just got into
	// would have no suspension until its next tick noticed the driver — long enough to sag
	// onto its collision box, which is the exact pose that causes the explosive-spring
	// launch on the following step.  PhysProp_Wake clears the latch and the settle timer too.
	PhysProp_Wake(car);
	if (cvar("sv_debug_car"))
		dprint(sprintf("[car] %s mounted\n", plyr.netname));
	return TRUE;
};

void(entity plyr) Car_Dismount =
{
	entity car = plyr.car_driving;
	if (car == world) return;

	vector spot = Car_FindClearSpot(plyr, car);

	plyr.car_driving      = world;
	plyr.pm_incar         = FALSE;
	plyr.car_in_fwd       = 0;
	plyr.car_in_side      = 0;
	plyr.solid            = plyr.car_saved_solid;
	plyr.movetype         = plyr.car_saved_movetype;
	plyr.alpha            = -1;   // stay hidden (alive-player convention); the visual proxy renders the standing body again
	plyr.drawonlytoclient = world;
	setorigin(plyr, spot);
	plyr.velocity = car.velocity * 0.5;   // step off with a little of the car's momentum
	if (car.car_driver == plyr) car.car_driver = world;

	if (cvar("sv_debug_car"))
		dprint(sprintf("[car] %s dismounted\n", plyr.netname));
};

// ---------------------------------------------------------------------------
// Per-tick: run the physics, keep the driver seated, keep the mirror updating.
// ---------------------------------------------------------------------------
void() Car_Think =
{
	self.nextthink = time + Car_TickInterval();

	// live-tune the box orientation + ride height: re-apply only when box_yaw or wheel_sink changes.
	// (Cached cvars: this runs for EVERY car EVERY tick, parked or not — it is one of the few
	// things a sleeping car still pays for, so it must not hash-look-up cvars.)
	if (self.box_managed)
	{
		float wantsink = (self.wheel_sink != 0) ? self.wheel_sink : car_cached_wheel_sink;  if (wantsink < 0) wantsink = 0;
		if (self.box_yaw + car_cached_box_yaw != self.applied_box_yaw
		 || wantsink != self.applied_wheel_sink)
			Car_ApplyCollisionBox(self);
	}

	entity drv = self.car_driver;
	if (drv != world)
	{
		// eject a dead / desynced driver
		if (drv.health <= 0 || drv.car_driving != self)
		{
			Car_Dismount(drv);
			drv = world;
		}
	}

	// Skip the drive sim while the gravity gun is carrying this car — the carry servo is the sole
	// authority over the body then (otherwise the two fight).  Restored automatically on drop.
	if (self.carried_by == world)
	{
		// ==================== PARKED-CAR SLEEP ====================
		// A driverless, stopped car ran the whole raycast drive sim every tick forever: 4
		// suspension tracelines, ~40 cvar reads, steer easing, a yaw-damp torque — plus
		// Car_PhysStep's physics_enable(car, TRUE) (sh_vehicle_phys.qc), which re-woke the
		// rigid body EVERY tick and so permanently defeated the backend's autodisable.
		//
		// Why we must EXPLICITLY disable rather than just skip the sim and let the backend
		// autodisable it: this car is held at ride height ONLY by the per-tick QC suspension
		// forces — its collision box deliberately floats with NO ground contacts (that is
		// what stops the "explosive spring" remount bug; see Car_WheelMountLocal).  Stop the
		// forces on an ENABLED body and gravity has it moving faster than the sleep threshold
		// within a single tick, so it can never autodisable at ride height: it would either
		// oscillate against the resume test or sag until the box hit the floor.  An explicit
		// physics_enable(FALSE) freezes it exactly where it stands, at zero solver cost.
		//
		// Waking is centralised in PhysProp_Wake (sv_physprop.qc), which every push path
		// already calls via PhysProp_KickStream (bullet hit / explosion / +use / throw), plus
		// Car_TryMount and the carry grab.  The velocity test below is the backstop for
		// anything that moves the body without telling us.
		float car_moving = (drv != world);
		if (!car_moving) if (vlen(self.velocity)  > CAR_SLEEP_LIN) car_moving = TRUE;
		if (!car_moving) if (vlen(self.avelocity) > CAR_SLEEP_ANG) car_moving = TRUE;

		if (car_moving)
		{
			if (self.car_asleep)
			{
				physics_enable(self, TRUE);
				self.car_asleep = FALSE;
			}
			self.car_rest_since = 0;
		}
		else
		{
			if (!self.car_rest_since)
				self.car_rest_since = time;
			if (!self.car_asleep)
				if (car_cached_sleep_enable)
					if (time - self.car_rest_since >= CAR_SLEEP_DELAY)
					{
						PhysFiles_StopScrape(self);   // PhysStep owns the scrape loop; it stops now
						physics_enable(self, FALSE);  // freeze at ride height (see above)
						self.car_asleep = TRUE;
					}
		}

		if (!self.car_asleep)
			Car_PhysStep(self);
	}
	// CARRIED.  This used to unconditionally do
	//     else if (self.pp_scrape_active) PhysFiles_StopScrape(self);
	// on the reasoning that PhysStep owns the scrape and no longer runs.  While
	// the car is merely GRABBED and still that is correct, but the generic
	// Carry_Tick (sv_physprop.qc) calls PhysFiles_StartScrape on this same car
	// every tick it is dragged along a surface — and StartScrape only issues the
	// sound() when !pp_scrape_active, which the stop above had just cleared.
	// The two therefore alternated once per tick: stop, start, stop, start,
	// re-issuing a SOUNDFLAG_FORCELOOP sample from scratch every single tick.
	// That is exactly the machine-gunning StartScrape's own comment warns about,
	// and it is what a car dragged along the GROUND sounded like.
	//
	// So: only cut the loop when the carry is NOT itself driving it.  Carry_Tick
	// refreshes .pp_slide_active_until on every StartScrape and cuts the loop
	// itself 0.2 s after the drag stops, so nothing is stranded by deferring.
	else if (self.pp_scrape_active && time > self.pp_slide_active_until)
		PhysFiles_StopScrape(self);


	// bolt the (hidden, non-solid) driver to the seat
	drv = self.car_driver;
	if (drv != world)
	{
		// Per-car seat offsets (FGD key → sv_car_seat_* cvar → default).  Same values are networked to
		// the client's seated-driver render (phys_files_Send is-car branch) so the drawn body matches.
		float seatup   = Car_Cvar(self.seat_up,   "sv_car_seat_up",   24);
		float seatfwd  = Car_Cvar(self.seat_fwd,  "sv_car_seat_fwd",  0);
		float seatside = Car_Cvar(self.seat_side, "sv_car_seat_side", 0);
		makevectors(self.angles);
		setorigin(drv, self.origin + v_up * seatup + v_forward * seatfwd + v_right * seatside);
		drv.velocity = self.velocity;
		drv.angles = [0, self.angles_y + self.model_yaw, 0];   // logical facing (edict hidden; the client draws the seated body)
	}

	// NET REST-LATCH (review find): the old unconditional SendFlags meant a parked
	// driverless car full-streamed ~30 coords at tick rate forever.  Stream while
	// driven or moving, plus a 0.5s grace so the final rest pose lands on clients.
	if (drv != world || vlen(self.velocity) > 1 || vlen(self.avelocity) > 1)
		self.car_stream_until = time + 0.5;
	if (time < self.car_stream_until)
		self.SendFlags |= 1;
};

// ---------------------------------------------------------------------------
// Physics debug-overlay stream (sv_debug_car 1) — ONE global proxy streams every
// car's box + wheel rays + steering + velocity to CSQC (drawn in cl_prop_vehicle.qc).
// The wheel geometry + a ground raycast are recomputed HERE so the client draws the
// EXACT server geometry.  Off = writes count 0 (near-free).  Max 8 cars.
// ---------------------------------------------------------------------------
.entity car_debug_proxy;   // per-client debug-overlay proxy (nav-debug pattern; PVS-safe)

void(entity car) CarDbg_WriteOne =
{
	// mesh basis for the WHEELS/drive (matches Car_PhysStep): pitch ×r_meshpitch, roll ×r_meshroll, +
	// EFFECTIVE per-model yaw (per-car model_yaw + the live global sv_car_model_yaw) so the streamed wheel
	// points + drive line up with where the car actually drives.
	float rmp = cvar("r_meshpitch"); if (rmp == 0) rmp = -1;
	float rmr = cvar("r_meshroll");  if (rmr == 0) rmr =  1;
	float pscale = car.mesh_noscale ? 1 : rmp;   // HL-studio / brush cars: no r_meshpitch pitch-scale
	float myaw = car.model_yaw + cvar("sv_car_model_yaw");
	// SAME decoupling as Car_PhysStep: model_yaw rotates forward/right in the body's horizontal plane, never
	// the up-axis (baking it into the yaw tilts cU on any pitch/roll → the dance).  Keeps the overlay's wheel
	// mounts + drive arrow glued to where the physics actually pushes.
	makevectors([car.angles_x * pscale, car.angles_y, car.angles_z * rmr]);
	vector tF = v_forward, tR = v_right;
	vector cU = v_up;
	float myr = myaw * 0.0174533;
	float mc = cos(myr), ms = sin(myr);
	vector cF = tF * mc - tR * ms;
	vector cR = tR * mc + tF * ms;
	vector cgofs = tF * ((car.ab_mins_x + car.ab_maxs_x) * 0.5) - tR * ((car.ab_mins_y + car.ab_maxs_y) * 0.5);   // wheels on the box CG (matches Car_PhysStep)
	WriteCoord(MSG_ENTITY, car.origin_x);   WriteCoord(MSG_ENTITY, car.origin_y);   WriteCoord(MSG_ENTITY, car.origin_z);
	WriteCoord(MSG_ENTITY, car.angles_x);   WriteCoord(MSG_ENTITY, car.angles_y);   WriteCoord(MSG_ENTITY, car.angles_z);
	WriteCoord(MSG_ENTITY, car.mins_x);     WriteCoord(MSG_ENTITY, car.mins_y);     WriteCoord(MSG_ENTITY, car.mins_z);
	WriteCoord(MSG_ENTITY, car.maxs_x);     WriteCoord(MSG_ENTITY, car.maxs_y);     WriteCoord(MSG_ENTITY, car.maxs_z);
	WriteCoord(MSG_ENTITY, car.velocity_x); WriteCoord(MSG_ENTITY, car.velocity_y); WriteCoord(MSG_ENTITY, car.velocity_z);
	WriteCoord(MSG_ENTITY, car.car_steer);
	WriteCoord(MSG_ENTITY, myaw);              // effective drive-forward yaw (for the arrow)
	WriteCoord(MSG_ENTITY, pscale);            // pitch-scale (so the client box/arrow match this model type)
	WriteCoord(MSG_ENTITY, car.car_dbg_thr);   // throttle -1/0/1 (force panel)
	WriteCoord(MSG_ENTITY, car.car_dbg_brake); // handbrake 0/1 (force panel)

	float wc = car.wheelcount; if (wc < 1) wc = 4; if (wc > 4) wc = 4;
	WriteByte(MSG_ENTITY, wc);

	float rest   = Car_CvarZ(car.ride_height,        "sv_car_ride_height");
	float travel = Car_CvarZ(car.compression_travel, "sv_car_compression_travel");
	float raylen = rest + travel;

	float i = 0;
	while (i < wc)
	{
		vector lofs   = Car_WheelLocal(car, i);
		vector mountw = car.origin + cgofs + cF * lofs_x + cR * lofs_y + cU * lofs_z;
		traceline(mountw, mountw - cU * raylen, MOVE_NOMONSTERS, car);
		vector contact = mountw - cU * raylen;
		float  comp    = -1;                       // −1 = airborne (no ground)
		if (trace_fraction < 1)
		{
			contact = trace_endpos;
			comp = rest - (trace_fraction * raylen);
			if (comp < 0)      comp = 0;
			if (comp > travel) comp = travel;
		}
		vector wf;   // the REAL net force stashed by Car_PhysStep (no field arrays → dispatch by index)
		if      (i == 0) wf = car.car_wforce0;
		else if (i == 1) wf = car.car_wforce1;
		else if (i == 2) wf = car.car_wforce2;
		else             wf = car.car_wforce3;
		WriteCoord(MSG_ENTITY, mountw_x);  WriteCoord(MSG_ENTITY, mountw_y);  WriteCoord(MSG_ENTITY, mountw_z);
		WriteCoord(MSG_ENTITY, contact_x); WriteCoord(MSG_ENTITY, contact_y); WriteCoord(MSG_ENTITY, contact_z);
		WriteCoord(MSG_ENTITY, comp);
		WriteCoord(MSG_ENTITY, wf_x);      WriteCoord(MSG_ENTITY, wf_y);      WriteCoord(MSG_ENTITY, wf_z);
		i = i + 1;
	}
};

float(entity to, float sf) CarDbg_Send =
{
	WriteByte(MSG_ENTITY, CSQC_ENT_CAR);
	if (!cvar("sv_debug_car"))
	{
		WriteByte(MSG_ENTITY, 0);
		return TRUE;
	}
	// Only stream cars within sv_car_debug_dist of the viewer (0 = unlimited), capped at 16 — so many cars can
	// exist while the overlay draws just the nearby ones.  The count + write loops use the SAME filter/order.
	float dist = cvar("sv_car_debug_dist");
	vector vp  = to.origin;
	float n = 0;
	entity e = world;
	while ((e = find(e, classname, "prop_car"))) { if (n < 16 && (dist <= 0 || vlen(e.origin - vp) <= dist)) n = n + 1; }
	e = world;
	while ((e = find(e, classname, "func_car"))) { if (n < 16 && (dist <= 0 || vlen(e.origin - vp) <= dist)) n = n + 1; }
	WriteByte(MSG_ENTITY, n);

	float w = 0;
	e = world;
	while ((e = find(e, classname, "prop_car"))) { if (w < 16 && (dist <= 0 || vlen(e.origin - vp) <= dist)) { CarDbg_WriteOne(e); w = w + 1; } }
	e = world;
	while ((e = find(e, classname, "func_car"))) { if (w < 16 && (dist <= 0 || vlen(e.origin - vp) <= dist)) { CarDbg_WriteOne(e); w = w + 1; } }
	return TRUE;
};

// PER-CLIENT proxy repositioned to the viewer each frame so PVS delivery is
// guaranteed (a global proxy at 0,0,0 gets PVS-culled → SendEntity never fires).
// Mirrors NavDbg_EnsureProxy (sv_bots.qc:982).
void(entity client) CarDbg_EnsureProxy =
{
	entity proxy = client.car_debug_proxy;
	if (!proxy)
	{
		proxy = spawn();
		proxy.classname  = "car_debug_proxy";
		proxy.owner      = client;
		proxy.movetype   = MOVETYPE_NONE;
		proxy.solid      = SOLID_NOT;
		proxy.SendEntity = CarDbg_Send;
		client.car_debug_proxy = proxy;
	}
	proxy.drawonlytoclient = client;
	proxy.pvsflags  = PVSF_NOREMOVE;
	proxy.SendFlags = 1;                 // re-stream every frame (cars move)
	setorigin(proxy, client.origin);
	cardbg_proxies_exist = TRUE;         // something to tear down later (see CarDbg_Tick)
};

// Per-frame driver (called from StartFrame). sv_debug_car 0 => tear proxies down.
void() CarDbg_Tick =
{
	entity e;
	if (cvar("sv_debug_car") < 1)
	{
		// Fast path: with the debug cvar off (the normal case) there is nothing to tear
		// down, so skip the find() walk entirely.  This used to run a FULL edict-table
		// scan every single frame on every server just to discover that no proxy existed
		// — find() is O(num_edicts) with a string compare per edict, which on a
		// prop-dense map is thousands of compares/frame for nothing.  The latch is set
		// only where a proxy is actually created (CarDbg_EnsureProxy).
		if (!cardbg_proxies_exist)
			return;
		for (e = world; (e = find(e, classname, "player")); )
			if (e.car_debug_proxy)
			{
				remove(e.car_debug_proxy);
				e.car_debug_proxy = world;
			}
		cardbg_proxies_exist = FALSE;
		return;
	}
	for (e = world; (e = find(e, classname, "player")); )
	{
		if (!SV_PlayerHasNetchan(e))     // real humans only — bots have no client to draw on
			continue;
		CarDbg_EnsureProxy(e);
	}
};
