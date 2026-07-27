//
//  sh_vehicle_phys.qc — Box3D/ODE raycast-vehicle CORE (prop_car / func_car).
//
//  Stage 1: SERVER-side physics.  A rigid-body chassis (MOVETYPE_PHYSICS, set up
//  via PhysObj_Setup like prop_physics) driven by an N-wheel RAYCAST model:
//  per wheel, cast down from a mount point and apply spring/damper SUSPENSION +
//  tire FRICTION (lateral grip) + DRIVE/BRAKE force with physics_addforce AT the
//  wheel's world position.  Applying force at the offset point gives weight
//  transfer / brake-dive / body roll for free.  Steering rotates the front
//  wheels' forward axis; the tires' lateral grip then redirects the heading —
//  we never write avelocity directly.
//
//  Server-authoritative (no client body prediction in v1).  See the plan.
//
//  CRITICAL: physics_addforce/physics_addtorque deliver their impulse on only the
//  FIRST of physics_ode_iterationsperframe substeps, so EVERY force is scaled by
//  Car_Iter() — exactly like sv_physprop.qc's hit forces — to stay independent of
//  the iteration count.  Forces are also no-ops on a SLEEPING body, so we
//  physics_enable(car,TRUE) at the top of every driven tick.
//

// --- FGD tuning keys (nettest.fgd prop_car/func_car), on the CAR entity. Each
//     falls back to the matching sv_car_* cvar via Car_Cvar when 0/blank.  NOTE:
//     `maxspeed` reuses the engine's .maxspeed field (sv_defs.qc:452 — inert on a
//     non-player physics body) so it is NOT redeclared here. ---
.float  caraccel, car_brakedecel;       // per-car override of sv_car_accel / sv_car_brake_decel (u/s²); 0 = use cvar
.float  suspension_softness, car_damping;   // softness = sink under own weight (u); damping = ratio (1=critical). wheel_radius REMOVED (folded into ride_height).
// ride_height + compression_travel are declared in sv_customdefs.qc (earlier than sv_physprop.qc's
// phys_files_Send, which networks the resolved values to cap the client visual wheel droop) — kept out of
// here to avoid a duplicate field definition.
.float  wheel_track, wheel_base, wheel_drop, wheelcount, wheel_sink, wheel_fwd;   // wheel_sink = raise box floor+mounts so the model rests on its wheels (u); wheel_fwd = fore/aft shift of the whole wheel set (u)
.string wheel_fl, wheel_fr, wheel_rl, wheel_rr, wheelmodel;
.float  steer_max, steer_rate, yaw_assist, grip, physengine;
// car_steer + model_yaw are declared in sv_customdefs.qc (earlier than sv_physprop.qc's phys_files_Send,
// which networks them for the visual wheels).  Kept out of here to avoid a duplicate field definition.
.float  mesh_type;      // FGD override: 0=auto (by extension), 1=alias/IQM/Quake, 2=halflife/GoldSrc
.float  mesh_noscale;   // resolved at spawn: 1 = HL studio (NO r_meshpitch pitch-scale), 0 = alias (use r_meshpitch)
.vector raw_mins, raw_maxs;   // the ORIGINAL model AABB (source for the swap; idempotent re-derive)
.vector ab_mins, ab_maxs;     // the ACTIVE AABB (raw, optionally 90°-swapped) — BOTH the collision box AND the wheels use THIS (kept aligned)
.float  box_yaw;        // FGD: collision-box yaw offset (0/90/180/270) to rotate the shared AABB so it lines up with the model
.float  applied_box_yaw;   // last-applied box_yaw sum (re-setsize only when it changes)
.float  applied_wheel_sink; // last-applied wheel_sink sum (re-setsize when the live sink changes)
.float  box_managed;    // 1 = prop_car (managed AABB); 0 = func_car (keep the brush box as-is)
// DEBUG stash (sv_debug_car): the REAL per-wheel net world force + throttle, filled in Car_PhysStep and
// streamed by CarDbg_WriteOne so the client can draw force arrows + a force panel (the recompute in
// CarDbg_WriteOne can't see the forces).
.vector car_wforce0, car_wforce1, car_wforce2, car_wforce3;
.float  car_dbg_thr;
.float  car_dbg_brake;   // debug: 0 off / 1 handbrake held (brake) / 2 latched drift
.float  car_hb_was;      // handbrake state last tick (edge detect for tap vs hold)
.float  car_hb_since;    // time the handbrake was pressed (tap = released quickly)
.float  car_drift_latch; // 1 = a TAP started a drift; holds low rear grip until the slide resolves
.float  car_ignition_until; // mount cranks the engine: throttle is DEAD until this time (sv_car_ignition_time)
.float  car_shift_until;    // gear-shift throttle cut window (sv_car_shift_time) — the "release, jerk, next gear"
.float  car_gear_srv;       // last whole virtual gear (speed-derived; audio derives the same client-side)
.float  car_stream_until;   // net rest-latch: keep the phys_files mirror streaming until this time

#ifdef SSQC

// Per-car FGD key OR the sv_car_* cvar OR a hard default (belt-and-suspenders,
// so the car drives even before the cvars are registered in the table).
float(float keyval, string cvarnm, float dflt) Car_Cvar =
{
	if (keyval != 0)
		return keyval;
	float v = cvar(cvarnm);
	if (v != 0)
		return v;
	return dflt;
};

// Like Car_Cvar but an explicit cvar value of 0 is HONORED (not treated as "inherit").  Used for the
// suspension knobs (ride_height/compression_travel) so they can be set to a literal 0 via the cvar — the cvars are
// always registered in sh_cvar_table.qc, so they carry their own default and no hard-default arg is needed.
// A NON-ZERO per-car field still wins (keeps per-car overrides); a 0 field means "inherit the cvar".
float(float keyval, string cvarnm) Car_CvarZ =
{
	if (keyval != 0)
		return keyval;
	return cvar(cvarnm);
};

// Force scale to keep the delivered impulse independent of the backend's sub-step count.
// BACKEND-AWARE (this was THE root bug): Box3D does ONE b3World_Step per frame, so a queued
// physics_addforce acts over the WHOLE frame → the correct magnitude is just F (scale = 1).
// ODE loops dWorldStep N times and the force is consumed by only the FIRST sub-step → scale = N.
// Multiplying every car force by physics_ode_iterationsperframe on Box3D made them ~10× too strong
// (spring launched the car off its wheels → bounce/flip; grip over-corrected → sideways push).
float() Car_Iter =
{
	if (cvar_string("sv_physics_engine") == "ode")   // ODE: force applies for 1 of N substeps → ×N
	{
		float it = cvar("physics_ode_iterationsperframe");
		if (it < 1) it = 1;
		return it;
	}
	return 1;   // Box3D (default): force applies over the whole frame → no scaling
};

// Local wheel mount as coefficients on the chassis (forward, right, up) basis.
// Explicit wheel_fl/fr/rl/rr overrides win (advanced / 3-wheel); else derive the
// 4 corners from track (width) / base (wheelbase) / drop (lower), auto-sized from
// the bbox when a dimension is 0.  Index 0=FL 1=FR 2=RL 3=RR (front pair steers).
vector(entity car, float i) Car_WheelLocal =
{
	string ov = "";
	if      (i == 0) ov = car.wheel_fl;
	else if (i == 1) ov = car.wheel_fr;
	else if (i == 2) ov = car.wheel_rl;
	else if (i == 3) ov = car.wheel_rr;
	if (ov != "")
		return stov(ov);

	float track = Car_Cvar(car.wheel_track, "sv_car_track", 0);
	float base  = Car_Cvar(car.wheel_base,  "sv_car_base",  0);
	float drop  = car.wheel_drop;               // 0 = mounts at chassis-centre height
	// Auto base/track: the wheels are PLACED in the model_yaw-rotated basis (Car_PhysStep uses
	// makevectors([…, angles_y + model_yaw, …])), so project the bbox extents onto that rotated
	// forward/right — otherwise a 90° model_yaw swaps width↔length and the car looks "fat/short".
	// (myaw 0 → base=X-extent, track=Y-extent as before; myaw 90 → swapped.)
	float myaw = (car.model_yaw + cvar("sv_car_model_yaw")) * 0.0174533;
	float cy = fabs(cos(myaw)), sy = fabs(sin(myaw));
	// Derive base/track from the ACTIVE (box_yaw-corrected) box so box_yaw rotates the wheels TO MATCH the box:
	// a GoldSrc .mdl's raw bbox is 90° off the mesh, so box_yaw=90 corrects box AND wheels together.  (The old
	// raw_ derivation left the wheels 90° off any .mdl.)  The residual box_yaw jitter is killed by the deadzone.
	float bx = car.ab_maxs_x - car.ab_mins_x;
	float by = car.ab_maxs_y - car.ab_mins_y;
	if (base  <= 0) base  = (bx * cy + by * sy) * 0.9;   // bbox extent along the model_yaw forward
	if (track <= 0) track = (bx * sy + by * cy) * 0.9;   // bbox extent along the model_yaw right

	float hx = base  * 0.5;     // half wheelbase (along forward)
	float hy = track * 0.5;     // half track (along right)
	float fwd, rgt;
	if      (i == 0) { fwd =  hx; rgt = -hy; }   // front-left
	else if (i == 1) { fwd =  hx; rgt =  hy; }   // front-right
	else if (i == 2) { fwd = -hx; rgt = -hy; }   // rear-left
	else             { fwd = -hx; rgt =  hy; }   // rear-right
	// z = the chassis box BOTTOM (mins_z), lowered further by `drop`. Mounting at the box
	// bottom (not the centre) makes the wheels extend BELOW the box so the chassis FLOATS on
	// them — only the wheels touch the floor. Mounting at the centre was the launch bug: the
	// box rested on the floor while the wheels raycast ~40u "into" it → explosive spring.
	return [fwd, rgt, car.ab_mins_z - drop];    // mount at the MODEL bottom (not the capped collision box)
};

// The per-tick raycast drive core.  Reads the driver's stashed WASD intent, casts
// each wheel, applies suspension + friction + drive/steer forces, then a low-speed
// yaw assist + a speed cap.  All forces × Car_Iter().
void(entity car) Car_PhysStep =
{
	float iter = Car_Iter();
	// diagnostic force scale: -1 disables the ×iter (test a CONTINUOUS spring without the one-shot
	// impulse scaling that bullet hits use); >0 scales ALL car forces; unset/0 = normal.
	float fis = cvar("sv_car_force_iterscale");
	if      (fis < 0) iter = 1;
	else if (fis > 0) iter = iter * fis;
	float dt   = cvar("sv_mintic");  if (dt <= 0) dt = 0.0156;

	physics_enable(car, TRUE);       // forces no-op on a sleeping body

	// post-integration transform + basis. MATCH the engine's rendered/collision basis
	// (AngleVectorsMesh, world.c): pitch ×r_meshpitch (default −1), roll ×r_meshroll, plus a
	// per-model yaw so the nose lines up. Raw makevectors was pitch-flipped vs the model, which
	// mis-placed the wheels + mis-aimed "up". (r_meshpitch/roll are engine cvars, valid server-side.)
	vector org = car.origin;
	float rmp = cvar("r_meshpitch"); if (rmp == 0) rmp = -1;
	float rmr = cvar("r_meshroll");  if (rmr == 0) rmr =  1;
	float pscale = car.mesh_noscale ? 1 : rmp;   // HL-studio .mdl / brush cars are NOT r_meshpitch-scaled by the backend
	float myaw = car.model_yaw + cvar("sv_car_model_yaw");   // per-car offset + live global (drive-dir dialing)
	// Build the TRUE body basis with NO model_yaw.  model_yaw must NEVER go into the makevectors yaw: the
	// AngleVectors up-vector is (sin(pitch)·cos(yaw+myaw), sin(pitch)·sin(yaw+myaw), cos(pitch)), so baking
	// model_yaw into the yaw ROTATES cU sideways the instant the car tilts → the spring pushes sideways →
	// positive-feedback "dance" on flat ground + pitch→roll bleed on ramps.  (The brush is calm only because
	// it has model_yaw=0.)  Instead take cU from the un-yawed basis, then rotate forward/right WITHIN the
	// body's own horizontal plane (around the true up) by model_yaw — so cU stays true and the wheels/drive
	// still follow the model's nose.  At rest (pitch=roll=0) this is identical to the old makevectors.
	makevectors([car.angles_x * pscale, car.angles_y, car.angles_z * rmr]);
	vector tF = v_forward, tR = v_right;
	vector cU = v_up;                                   // TRUE world up — the spring pushes along THIS
	float myr = myaw * 0.0174533;
	float mc = cos(myr), ms = sin(myr);
	vector cF = tF * mc - tR * ms;                      // nose dir (== forward@(yaw+myaw), but cU uncontaminated)
	vector cR = tR * mc + tF * ms;
	// Wheels mount symmetric about the COLLISION-BOX CENTRE (= the Box3D COM), not the entity origin.  For a
	// centred box (prop_car, re-centred in Car_ApplyCollisionBox) this is 0 → no change.  For a func_car whose
	// ORIGIN brush isn't at the brush centre, origin ≠ box centre, so without this the 4 springs load off-CG →
	// a steady torque the tyres fight → the phantom even wheel force.  Entity-frame X/Y offset (Z untouched —
	// wheels still mount at ab_mins_z).  Local +Y is −v_right in Quake, hence −tR.
	float bcx = (car.ab_mins_x + car.ab_maxs_x) * 0.5;
	float bcy = (car.ab_mins_y + car.ab_maxs_y) * 0.5;
	vector cgofs = tF * bcx - tR * bcy;
	vector vel  = car.velocity;
	// TRUE world angular velocity (rad/s) for the ω×r wheel-velocity term.  QC .avelocity is MANGLED by
	// the alias backend (com_phys_*): read-back gives avel_x = worldωx·r_meshpitch, avel_y = worldωz,
	// avel_z = worldωy (pitch scaled + yaw/roll SWAPPED).  Un-mangle: worldAvel = [avel_x·rmp, avel_z, avel_y].
	// Using the raw vector fed the grip a garbage tangential velocity → no friction / spin-in-place / drive
	// starved by the friction circle.
	vector avel = [car.avelocity_x * pscale, car.avelocity_z, car.avelocity_y] * 0.0174533;

	// ---- WORLD-IMPACT LENIENCY + FX -------------------------------------------------------------
	// The Box3D/ODE solver kills the into-wall velocity when the trimesh hull hits static BSP, so the
	// car pins and dies.  No QC touches car.velocity on contact — but writing it IS authoritative on
	// this MOVETYPE_PHYSICS body (the hardcap + NaN guard below do exactly that), so we detect the hit
	// from a one-tick HORIZONTAL speed drop (like the props' PhysObj_DetectContactFX) and: (1) play a
	// metal impact + smoke/spark FX at the wall, (2) re-project the pre-impact velocity onto the wall
	// TANGENT so the car GLANCES along it instead of stopping.  Vertical is ignored (suspension/gravity
	// swing it every tick → false landings).  Reuses the prop FX helpers (sv_physprop.qc, compiled first).
	if (cvar("sv_car_impact_fx"))
	{
		vector hprev  = [car.pp_prev_velocity_x, car.pp_prev_velocity_y, 0];
		float  prevsp = vlen(hprev);
		float  vdrop  = prevsp - vlen([vel_x, vel_y, 0]);
		float  imin   = cvar("sv_car_impact_min_speed"); if (imin <= 0) imin = 150;
		vector bcenter = org + cgofs + cU * ((car.ab_mins_z + car.ab_maxs_z) * 0.5);   // world box centre
		float  reach  = vlen(car.ab_maxs - car.ab_mins) * 0.5 + 16;

		// (1) discrete hard hit
		if (time >= car.pp_impact_cooldown && prevsp >= imin && vdrop >= imin)
		{
			float icd = cvar("sv_car_impact_cooldown"); if (icd <= 0) icd = 0.15;
			car.pp_impact_cooldown = time + icd;
			traceline(bcenter, bcenter + normalize(hprev) * reach, MOVE_NOMONSTERS, car);
			vector wp = trace_endpos, wn = trace_plane_normal;
			if (trace_fraction >= 1) { wp = bcenter; wn = normalize(hprev) * -1; }
			vector nn = normalize(wn);
			// Car body bang — po_sndset is "metal" (set in sv_prop_vehicle.qc; cars run
			// po_material -1 so PropMat_FxSound gives nothing).  Variant count from the table.
			string csnd = MatSnd_Pick(car.po_sndset, MSND_HARD);
			if (csnd != "")
				sound(car, CHAN_BODY, csnd, 1.0, ATTN_NORM);
			PhysFiles_SmokeEvent(wp, nn, 3);           // bucket 3 = car HARD hit (smoke + spark burst)
			vector vtan = hprev - (hprev * nn) * nn;   // strip the into-wall component
			float retain = cvar("sv_car_impact_slide_retain"); if (retain <= 0) retain = 0.85;
			car.velocity_x = vtan_x * retain;
			car.velocity_y = vtan_y * retain;          // leave velocity_z (gravity/suspension) alone
			car.car_scrape_normal = nn;                // latch the wall for the continuous grind below
		}

		// (2) continuous grind: while still pressed against that wall and moving, keep a looping metal
		// scrape + a thin spark/smoke stream, and hold the along-wall velocity so the solver can't bleed it.
		// Read the AUTHORITATIVE car.velocity (not the stale local `vel` captured up top) so on the same tick
		// as a discrete hit this sees the just-re-projected slide speed instead of clobbering it.
		float himp = vlen([car.velocity_x, car.velocity_y, 0]);
		float gmin = cvar("sv_car_grind_min_speed"); if (gmin <= 0) gmin = 120;
		if (car.car_scrape_normal != '0 0 0' && himp > gmin)
		{
			vector gn = normalize(car.car_scrape_normal);
			traceline(bcenter, bcenter - gn * (reach - 8), MOVE_NOMONSTERS, car);   // is the wall still there?
			if (trace_fraction < 1)
			{
				PhysFiles_StartScrape(car, himp);                  // start/refresh the loop (auto-volume)
				car.pp_slide_active_until = time + 0.15;           // keep it alive one more window
				// keep the along-wall speed, but ONLY strip the INTO-wall component (gn points away from the
				// wall toward the car) — if the driver has steered AWAY (gdn >= 0) leave velocity alone so the
				// car can peel off instead of being glued to the wall.
				vector ghv = [car.velocity_x, car.velocity_y, 0];
				float  gdn = ghv * gn;
				if (gdn < 0)
				{
					vector gtan = ghv - gdn * gn;
					car.velocity_x = gtan_x;
					car.velocity_y = gtan_y;
				}
				if (time >= car.pp_slide_next)
				{
					float gint = cvar("sv_car_grind_interval"); if (gint <= 0) gint = 0.08;
					car.pp_slide_next = time + gint;
					PhysFiles_SmokeEvent(trace_endpos, trace_plane_normal, 4);   // bucket 4 = thin grind FX
				}
			}
			else
				car.car_scrape_normal = '0 0 0';                   // separated: drop the latch
		}
		if (car.pp_scrape_active && time > car.pp_slide_active_until)   // mirror sv_physprop.qc:675-676
			PhysFiles_StopScrape(car);
	}

	// tuning (per-car key → cvar → default)
	float cmass   = (car.mass > 0) ? car.mass : Car_Cvar(0, "sv_car_mass", 1200);
	float maxsp   = Car_Cvar(car.maxspeed,       "sv_car_max_speed", 1100);
	// SUSPENSION MODEL (Car_CvarZ → an explicit 0 is honoured, not treated as inherit):
	//   rest   = RIDE HEIGHT: the spring's free length; the body settles at gap = rest − sag above the ground
	//            contact.  0 = the body rides down at the collision-box floor.  (Folds in the old wheel_radius:
	//            it only ever appeared as rest+wrad, so it was redundant with ride height — removed.)
	//   travel = COMPRESSION TRAVEL: EXTRA squash on top of the resting sag (landing cushion) — bump-stop is
	//            sag + travel.  NOT droop.
	//   sag    = SOFTNESS: how far the car sinks under its OWN weight (= the equilibrium compression).  suspk
	//            is derived from mass·g/(wheels·sag), so a heavier car auto-stiffens — there is NO separate
	//            spring-strength knob; sag IS the softness (bigger = softer).
	float rest    = Car_CvarZ(car.ride_height,       "sv_car_ride_height");
	float travel  = Car_CvarZ(car.compression_travel,"sv_car_compression_travel");
	float gripc   = Car_Cvar(car.grip,           "sv_car_grip", 4);
	float wcount  = car.wheelcount;  if (wcount < 1) wcount = 4;  if (wcount > 4) wcount = 4;

	// PHYSICAL-UNIT tuning (small readable numbers) → derive the internal force / spring k / damper c.
	//   accel  (u/s²) : engine force  = accel · mass        (5000·1200 = 6,000,000)
	//   ridesag(u)    : rest sink; k  = mass·g / (wheels·sag) so a heavier car auto-stiffens to the same sag
	//   damping(ratio): 1 = critical (no bounce); c = ratio · 2·√(k · mass/wheels)
	float grav    = cvar("sv_gravity"); if (grav <= 0) grav = 800;
	float accel   = Car_Cvar(car.caraccel,      "sv_car_accel", 3200);
	float enginef = accel * cmass;                                            // world-frame drive force
	float sag     = Car_Cvar(car.suspension_softness, "sv_car_suspension_softness", 1.2);  if (sag < 0.1) sag = 0.1;
	float suspk   = (cmass * grav) / (wcount * sag);                          // spring stiffness
	float dratio  = Car_Cvar(car.car_damping,   "sv_car_damping", 0.6);
	float suspc   = dratio * 2 * sqrt(suspk * (cmass / wcount));              // damper
	float brakeg  = Car_Cvar(car.car_brakedecel, "sv_car_brake_decel", 9000); // brake deceleration (u/s²)
	float revfrac = Car_Cvar(0, "sv_car_reverse_frac", 0.4);                  // reverse = fraction of drive force
	float driftg  = Car_Cvar(0, "sv_car_drift_grip", 0.35);                   // rear grip scale while handbraking
	// share of lateral slip cancelled per tick.  1 = the old deadbeat -(m_w·vlat/dt) whose C·dt/m_w = 1 sits ON
	// the oscillation boundary (wobble + crawl-lock); <1 pulls it into the stable region (mass-independent).
	float gripresp = cvar("sv_car_grip_response");  if (gripresp <= 0) gripresp = 0.5;  if (gripresp > 1) gripresp = 1;
	float hbdecel = Car_Cvar(0, "sv_car_handbrake_decel", 9000);             // hold-Space brake decel (u/s²)
	float parkdec = Car_Cvar(0, "sv_car_park_decel", 600);                    // driverless coast-to-stop decel (u/s²)
	float taptime = cvar("sv_car_drift_tap_time");   if (taptime <= 0)  taptime  = 0.2;   // < this held = a TAP
	float driftmn = cvar("sv_car_drift_min_speed");  if (driftmn <= 0)  driftmn  = 250;   // min speed to start a drift
	float driftex = cvar("sv_car_drift_exit");       if (driftex <= 0)  driftex  = 40;    // lateral speed the drift ends at

	// handbrake (Space) — read the driver's stashed jump intent (server-only capture in sv_player.qc)
	float hb_held = 0;

	// driver intent (stashed in the real cmd path — sv_player.qc)
	float in_fwd = 0, in_side = 0;
	entity drv = car.car_driver;
	if (drv != world)
	{
		in_fwd  = drv.car_in_fwd;
		in_side = drv.car_in_side;
		hb_held = drv.car_in_brake;   // Space = handbrake / drift
	}
	float thr = 0;
	if      (in_fwd >  1) thr =  1;   // W = drive forward
	else if (in_fwd < -1) thr = -1;   // S = brake / reverse
	float steerin = 0;
	if      (in_side >  1) steerin =  1;   // D (+moveright) = steer right
	else if (in_side < -1) steerin = -1;   // A (+moveleft)  = steer left

	// IGNITION: mounting cranks the engine (sv_prop_vehicle.qc sets car_ignition_until);
	// throttle is dead until the crank finishes — steer/handbrake still work.  Matches
	// the client's start one-shot (cl_vehicle_sound.qc holds the loops silent too).
	if (time < car.car_ignition_until)
		thr = 0;

	// GEAR SHIFT throttle-cut: gears are VIRTUAL (speed-derived — the exact sawtooth the
	// audio uses), but shifting UP cuts the drive for sv_car_shift_time so the car gets the
	// classic "lift, jerk, pull again" cadence and the revs audibly sag between gears.
	// TWO anti-hunting guards (the v1 cut oscillated: cut → engine-brake bled speed →
	// dropped below the boundary → re-crossed → cut again, forever):
	//   1. HYSTERESIS — the tracked gear only goes DOWN once speed is clearly (0.15 gear)
	//      below the boundary, so a tiny dip can't re-arm the upshift.
	//   2. CLUTCH-IN — during the cut the engine-brake is suppressed too (see the coast
	//      branch below), so the car coasts through the shift instead of slowing down.
	float shifting = 0;
	{
		float sgears = cvar("sv_car_gears");        if (sgears < 1)  sgears = 4;
		float shiftt = cvar("sv_car_shift_time");   if (shiftt <= 0) shiftt = 0.25;
		float maxsp_g = Car_Cvar(car.maxspeed, "sv_car_max_speed", 1100);
		float hs_g = vlen([vel_x, vel_y, 0]);
		float gpos = (hs_g / maxsp_g) * sgears;
		if (gpos > sgears - 0.001) gpos = sgears - 0.001;
		float gnow = floor(gpos);
		if (gnow > car.car_gear_srv)
		{
			if (thr > 0 && !car.car_drift_latch)
				car.car_shift_until = time + shiftt;
			car.car_gear_srv = gnow;
		}
		else if (gnow < car.car_gear_srv && gpos < car.car_gear_srv - 0.15)
			car.car_gear_srv = gnow;                 // hysteresis: only settle down once clearly below
		if (time < car.car_shift_until)
		{
			if (thr > 0) thr = 0;                    // drive cut
			shifting = 1;                            // clutch in (skip engine-brake below)
		}
	}

	// --- HANDBRAKE state machine: HOLD = brake to a stop; TAP (mid-turn at speed) = latch a drift that
	//     auto-ends when the slide resolves.  car_in_brake is captured server-side before PM_PlayerMove. ---
	float hspd_hb   = vlen([vel_x, vel_y, 0]);
	float vlat_body = vel * cR;                        // body-frame lateral (sideways) speed
	if (hb_held && !car.car_hb_was)
		car.car_hb_since = time;                       // press edge
	if (!hb_held && car.car_hb_was)                    // release edge
	{
		if (time - car.car_hb_since < taptime && hspd_hb > driftmn
		 && (fabs(car.car_steer) > 1 || fabs(vlat_body) > driftex))
			car.car_drift_latch = 1;                   // a TAP while turning/sliding at speed → start a drift
	}
	car.car_hb_was = hb_held;
	if (car.car_drift_latch)
	{
		if (fabs(vlat_body) < driftex || hspd_hb < driftmn * 0.4)
			car.car_drift_latch = 0;                   // slide resolved (or too slow) → drift ends
	}
	float drift_active = (hb_held || car.car_drift_latch);   // cut REAR grip while drifting or handbraking
	car.car_dbg_brake  = hb_held ? 1 : (car.car_drift_latch ? 2 : 0);

	// ease the front-wheel angle toward the target; self-centre when released
	float steermax  = Car_Cvar(car.steer_max,  "sv_car_steer_max", 35);
	float steerrate = Car_Cvar(car.steer_rate, "sv_car_steer_rate", 120);
	float starget = steerin * steermax;
	float sdif = starget - car.car_steer;
	float slim = steerrate * dt;
	if (sdif >  slim) sdif =  slim;
	if (sdif < -slim) sdif = -slim;
	car.car_steer = car.car_steer + sdif;
	if (steerin == 0)
	{
		float ret = 180 * dt;
		if      (car.car_steer >  ret) car.car_steer = car.car_steer - ret;
		else if (car.car_steer < -ret) car.car_steer = car.car_steer + ret;
		else                            car.car_steer = 0;
	}
	float steerrad = car.car_steer * 0.0174533;
	float scos = cos(steerrad), ssin = sin(steerrad);
	car.car_dbg_thr = thr;           // debug panel (car_dbg_brake set by the handbrake state machine above)

	// --- per wheel: raycast → spring suspension + grip + drive ---
	float onground = 0;
	float i = 0;
	while (i < wcount)
	{
		vector lofs   = Car_WheelLocal(car, i);
		vector mountw = org + cgofs + cF * lofs_x + cR * lofs_y + cU * lofs_z;

		// front pair steers: rotate the wheel forward axis by car_steer around up
		vector wF;
		if (i < 2)
			wF = cF * scos + cR * ssin;
		else
			wF = cF;
		vector wSide = normalize(crossproduct(cU, wF));

		// velocity at the contact = linear + ω × r
		vector rvec = mountw - org;
		vector vAt  = vel + crossproduct(avel, rvec);
		vector wforce = '0 0 0';   // net world force at this wheel (debug stash)

		// suspension raycast straight down the chassis-up axis (rest = ride-height datum; wheel_radius removed)
		float raylen = rest + travel;
		traceline(mountw, mountw - cU * raylen, MOVE_NOMONSTERS, car);
		if (trace_fraction < 1)
		{
			onground = 1;

			// SPRING suspension (force, not servo): compression against the rest extension, damped by the
			// mount's up-velocity (vAt·cU: compressing → vAt·cU<0 → +force resists it).  The car floats on
			// its wheels, balances gravity, and pitches onto ramps for free — no velocity_z servo.
			float gap = (mountw - trace_endpos) * cU;             // mount height above the contact
			float compression = rest - gap;                       // rest is the ride-height datum (wheel_radius folded in)
			if (compression < 0) compression = 0;
			// The spring MUST be able to compress by `sag` just to hold the car's own weight at rest
			// (equilibrium compression = sag).  So `travel` is the EXTRA compression on TOP of that (the
			// landing cushion) — the bump-stop is at `sag + travel`.  Clamping to `travel` alone made a
			// low travel (< sag) bottom out and the car SANK onto its collision box; now travel can be 0-2
			// and the car still holds up at ride height with that much extra squash for landings.
			float bumpstop = sag + travel;
			if (compression > bumpstop) compression = bumpstop;
			float Fsusp = suspk * compression - suspc * (vAt * cU);
			if (Fsusp < 0) Fsusp = 0;                             // springs only push
			float fmax = suspk * bumpstop * 3;                    // safety clamp (a mis-tune can't explode it; scales with travel so travel=0 still lifts)
			if (Fsusp > fmax) Fsusp = fmax;
			physics_addforce(car, cU * (Fsusp * iter), mountw);

			// Per-tyre GRIP + DRIVE only apply when someone's DRIVING.  An empty car has no tyre forces —
			// it's just a shoved sprung box (a bullet slides it naturally, no "two forces per tire"); the
			// whole-body coast decel below rolls it to a stop.
			if (drv != world)
			{
			float gripmax = gripc * Fsusp;        // grip ∝ this wheel's LOAD → turns don't saturate the circle
			if (drift_active && i >= 2)
				gripmax = gripmax * driftg;       // handbrake / drift cuts REAR grip → the tail slides out

			// lateral grip: a STABLE PROPORTION (gripresp) of the one-tick slip cancel, clamped by grip.  The
			// full cancel -(m_w·vlat/dt) is a deadbeat controller on the stability edge → it over-corrects
			// (wobble) and amplifies micro-slip to gripmax (crawl-lock).  gripresp<1 gives margin; proportional
			// force also means small slip → small force, so the friction circle keeps drive headroom at a crawl.
			float vlat = vAt * wSide;
			float Flat = -(cmass / wcount) * vlat / dt * gripresp;
			if (Flat >  gripmax) Flat =  gripmax;
			if (Flat < -gripmax) Flat = -gripmax;
			physics_addforce(car, wSide * (Flat * iter), mountw);

			// longitudinal: handbrake / drive (ease out near maxspeed) / brake-then-reverse (S) / engine-brake,
			// clamped by the friction circle against the lateral force already used.
			float vlong = vAt * wF;
			float Flong;
			if (hb_held)
			{
				// HOLD Space = brake every wheel to a stop (rear grip is also cut → it slides to a halt)
				if      (vlong >  5) Flong = -hbdecel * (cmass / wcount);
				else if (vlong < -5) Flong =  hbdecel * (cmass / wcount);
				else                 Flong = -vlong * (cmass / wcount);
			}
			else if (car.car_drift_latch && i >= 2)
			{
				Flong = -vlong * (cmass / wcount) * 2;         // latched drift: rear locked (no drive) → slide
			}
			else if (thr > 0)
			{
				float room = 1 - (vlong / maxsp);              // W: drive, ease out near top speed
				if (room < 0) room = 0;  if (room > 1) room = 1;
				Flong = enginef * room / wcount;
			}
			else if (thr < 0)
			{
				if (vlong > 20)                                // S while rolling forward → BRAKE to a stop
					Flong = -brakeg * (cmass / wcount);
				else                                           // stopped / already reversing → REVERSE
				{
					float rroom = 1 - (fabs(vlong) / (maxsp * 0.6));
					if (rroom < 0) rroom = 0;
					Flong = -revfrac * enginef * rroom / wcount;
				}
			}
			else
			{
				// coast: engine-brake / rolling resist — but nearly FREE while the gear
				// shift has the clutch in (bleeding speed here re-crossed the gear
				// boundary and made the shifter hunt up/down forever)
				Flong = -vlong * (cmass / wcount) * (shifting ? 0.03 : 0.6);
			}
			float rem = gripmax * gripmax - Flat * Flat;
			if (rem < 0) rem = 0;
			rem = sqrt(rem);
			if (Flong >  rem) Flong =  rem;
			if (Flong < -rem) Flong = -rem;
			physics_addforce(car, wF * (Flong * iter), mountw);

			wforce = wSide * Flat + wF * Flong;   // net (grip + drive), for the debug arrows/panel
			}
		}
		// stash the per-wheel force for the debug overlay (no field arrays → dispatch by index)
		if      (i == 0) car.car_wforce0 = wforce;
		else if (i == 1) car.car_wforce1 = wforce;
		else if (i == 2) car.car_wforce2 = wforce;
		else             car.car_wforce3 = wforce;
		i = i + 1;
	}

	// DRIVERLESS coast: one gentle whole-body decel opposing horizontal motion (no per-tyre grip) so a shoved
	// or hopped-out-of car slides in the push direction and rolls to a gentle stop.
	if (drv == world && onground)
	{
		vector vh = [vel_x, vel_y, 0];
		float vhs = vlen(vh);
		if (vhs > 4)
			physics_addforce(car, vh * (-parkdec * cmass * iter / vhs), org);
	}

	// NO anti-roll / no leveling — just gravity + 4 springs + drive + steer (stripped back per the user).
	// A low collision box (Car_ApplyCollisionBox) keeps the CG low so the springs alone hold it upright.

	// low-speed turn-in-place assist: grip-steering can't rotate a near-stationary car, so add a yaw torque
	// while steering below `fade` u/s (fades to 0 by fade).  Expressed as an angular acceleration (deg/s²) and
	// multiplied by the car's yaw moment of inertia (torque = I·α) so it's actually FELT regardless of the
	// force regime — the old raw 4000 torque was swamped by the car's inertia and did nothing.  0 = off.
	// Steer ALONE now pivots (no throttle required), so A/D turns the nose at a standstill.
	float assist = Car_Cvar(car.yaw_assist, "sv_car_yaw_assist", 200);   // deg/s² of yaw help at a standstill
	float speed  = vlen(vel);
	float fade   = 200;
	if (onground && steerin != 0 && speed < fade && assist > 0)
	{
		float lx = car.ab_maxs_x - car.ab_mins_x;
		float ly = car.ab_maxs_y - car.ab_mins_y;
		float Iz = cmass * (lx * lx + ly * ly) / 12;                     // box yaw moment of inertia
		// NOTE the -steerin: +steerin (D/right) must yaw the car CLOCKWISE (negative torque about the up axis)
		// to MATCH the grip-steer (front wheels rotate toward cR = right).  Using +steerin spun it the wrong way
		// and the steered wheels' rolling grip then shoved the car backward.
		float a  = (1 - speed / fade) * (assist * 0.0174533) * Iz * -steerin;   // torque = I·α, reinforces the steer
		physics_addtorque(car, cU * (a * iter));
	}

	// YAW SPIN DAMPING — stop a car pirouetting on its centre.  A driverless car has no per-tyre grip (3e.2) so
	// nothing bleeds its spin (it spins forever, and a residual spin saturates the grip the instant you get in →
	// friction circle → no drive).  Damp the spin about the car's own up (yawrate = avel·cU, correct on ramps)
	// with a rate `yd` (1/s → exponential decay), torque = −yawrate·yd·Iyaw.
	float ydamp = Car_Cvar(0, "sv_car_yaw_damp", 8);
	if (onground && ydamp > 0)
	{
		float yawrate = avel * cU;                                   // spin about the car's up (rad/s)
		float lyd = car.ab_maxs_x - car.ab_mins_x;
		float wyd = car.ab_maxs_y - car.ab_mins_y;
		float Iyaw = cmass * (lyd * lyd + wyd * wyd) / 12;           // box yaw moment of inertia
		float yd = 0;
		if (drv == world)
			yd = ydamp;                                             // driverless: always settle the spin
		else if (steerin == 0 && speed < fade)
			yd = ydamp * (1 - speed / fade);                        // driven: only when NOT steering + low speed
		if (yd > 0)                                                 // (so it never fights the yaw-assist pivot / turns)
			physics_addtorque(car, cU * (-yawrate * yd * Iyaw * iter));
	}

	// ROLL DAMPING — an anti-roll torque about the car's FORWARD axis (cF), exactly parallel to the yaw-damp
	// above but about roll instead of yaw.  The 4 corner springs are the only roll STIFFNESS the car has
	// (their ±half-track lateral offset); this adds roll DAMPING on top for a planted, low-body-roll
	// (TrackMania-style) feel WITHOUT reducing the spring count.  Roll doesn't fight steering (that's yaw),
	// so it applies whenever grounded.  0 = off (pure 4-spring roll — the original behaviour).
	float rdamp = Car_Cvar(0, "sv_car_roll_damp", 0);
	if (onground && rdamp > 0)
	{
		float rollrate = avel * cF;                                 // spin about the car's forward (rad/s)
		float wyr = car.ab_maxs_y - car.ab_mins_y;                  // width  (Y)
		float hzr = car.ab_maxs_z - car.ab_mins_z;                  // height (Z)
		float Iroll = cmass * (wyr * wyr + hzr * hzr) / 12;         // box roll moment of inertia (perp to fwd)
		physics_addtorque(car, cF * (-rollrate * rdamp * Iroll * iter));
	}

	// horizontal speed cap (leave the vertical/gravity velocity alone)
	float hspeed = vlen([vel_x, vel_y, 0]);
	float hardcap = maxsp * 1.15;
	if (hspeed > hardcap)
	{
		float hs = hardcap / hspeed;
		car.velocity_x = vel_x * hs;
		car.velocity_y = vel_y * hs;
	}

	// NaN / runaway guard: if the solver blew up, kill motion (driver ejects in Car_Think).
	if (car.origin != car.origin)
	{
		car.velocity  = '0 0 0';
		car.avelocity = '0 0 0';
	}

	// latch this tick's post-step velocity for next tick's impact drop-test (mirror sv_physprop.qc:809).
	car.pp_prev_velocity = car.velocity;
};

#endif
