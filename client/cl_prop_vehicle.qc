//
//  cl_prop_vehicle.qc — CSQC physics DEBUG overlay for prop_car / func_car (sv_debug_car 1).
//
//  Receives the per-frame car-debug stream (CSQC_ENT_CAR, from sv_prop_vehicle.qc
//  CarDbg_Send) and draws, per car: the collision BOX (faithful to the engine's
//  oriented box — NO model_yaw), each WHEEL ray (mount→ground contact, coloured by
//  suspension compression), the STEERING heading + drive-forward arrow (WITH the
//  effective model_yaw), the car's true UP (righting target), the VELOCITY vector,
//  and the REAL per-wheel force arrows.  It also draws a 2D force-data panel.
//
//  The server recomputes the wheel geometry + ground raycast and streams world points
//  + the stashed forces, so this file only draws them (no physics client-side).
//

float  cardbg_n;                 // cars in the last packet
float  cardbg_last;              // cltime of the last packet (staleness → off)
vector cardbg_org[16], cardbg_ang[16], cardbg_min[16], cardbg_max[16], cardbg_vel[16];
float  cardbg_steer[16], cardbg_wc[16], cardbg_myaw[16], cardbg_thr[16], cardbg_pscale[16], cardbg_brake[16];
vector cardbg_wmount[64], cardbg_wcontact[64], cardbg_wforce[64];   // [car*4 + wheel]
float  cardbg_wcomp[64];

// Line + arrowhead (no arrow helper exists in the codebase). World-space, uses CSQC_DebugLine.
void(vector p1, vector p2, vector col, float a) CSQC_DebugArrow =
{
	CSQC_DebugLine(p1, p2, col, a);
	vector d = p2 - p1;
	float L = vlen(d);
	if (L < 1) return;
	d = d * (1 / L);
	vector side = crossproduct(d, '0 0 1');
	if (vlen(side) < 0.01) side = crossproduct(d, '0 1 0');
	side = normalize(side);
	float hl = L * 0.25; if (hl > 10) hl = 10; if (hl < 3) hl = 3;
	vector back = p2 - d * hl;
	CSQC_DebugLine(p2, back + side * hl * 0.6, col, a);
	CSQC_DebugLine(p2, back - side * hl * 0.6, col, a);
};

// CSQC_Ent_Update handler (the CSQC_ENT_CAR byte was already consumed). Reads MUST
// mirror CarDbg_WriteOne exactly (byte-for-byte, in order).
void() CarDbg_EntUpdate =
{
	float n = readbyte();
	if (n > 16) n = 16;
	cardbg_n    = n;
	cardbg_last = cltime;

	float i = 0;
	while (i < n)
	{
		vector o, a, mn, mx, vv;
		o_x  = readcoord(); o_y  = readcoord(); o_z  = readcoord();
		a_x  = readcoord(); a_y  = readcoord(); a_z  = readcoord();
		mn_x = readcoord(); mn_y = readcoord(); mn_z = readcoord();
		mx_x = readcoord(); mx_y = readcoord(); mx_z = readcoord();
		vv_x = readcoord(); vv_y = readcoord(); vv_z = readcoord();
		cardbg_org[i] = o; cardbg_ang[i] = a; cardbg_min[i] = mn; cardbg_max[i] = mx; cardbg_vel[i] = vv;
		cardbg_steer[i]  = readcoord();
		cardbg_myaw[i]   = readcoord();
		cardbg_pscale[i] = readcoord();
		cardbg_thr[i]    = readcoord();
		cardbg_brake[i]  = readcoord();

		float wc = readbyte(); if (wc > 4) wc = 4;
		cardbg_wc[i] = wc;

		float k = 0;
		while (k < wc)
		{
			vector wm, ct, wf;
			wm_x = readcoord(); wm_y = readcoord(); wm_z = readcoord();
			ct_x = readcoord(); ct_y = readcoord(); ct_z = readcoord();
			cardbg_wcomp[i * 4 + k] = readcoord();
			wf_x = readcoord(); wf_y = readcoord(); wf_z = readcoord();
			cardbg_wmount[i * 4 + k]   = wm;
			cardbg_wcontact[i * 4 + k] = ct;
			cardbg_wforce[i * 4 + k]   = wf;
			k = k + 1;
		}
		i = i + 1;
	}
};

// Draw the 3D overlay — call in the CSQC scene pass (cl_main.qc).
void() CSQC_DrawDebugCar =
{
	if (cardbg_n <= 0)                  return;
	if (cltime - cardbg_last > 0.5)     return;   // stale → sv_debug_car turned off

	float rmp = cvar("r_meshpitch"); if (rmp == 0) rmp = -1;
	float rmr = cvar("r_meshroll");  if (rmr == 0) rmr =  1;

	float i = 0;
	while (i < cardbg_n)
	{
		vector o = cardbg_org[i];
		vector a = cardbg_ang[i];

		float ps = cardbg_pscale[i]; if (ps == 0) ps = rmp;   // per-car pitch-scale (HL/brush = 1, alias = r_meshpitch)
		// BOX basis = the engine's real oriented box: pitch ×pscale / roll, NO model_yaw. This is what the
		// model + collision actually use, so the wire box stays glued to the model.
		makevectors([a_x * ps, a_y, a_z * rmr]);
		vector bF = v_forward, bR = v_right, bU = v_up;
		// DRIVE basis = box basis + the effective model_yaw (where the car drives / steers).
		makevectors([a_x * ps, a_y + cardbg_myaw[i], a_z * rmr]);
		vector cF = v_forward, cR = v_right, cU = v_up;

		vector mn = cardbg_min[i], mx = cardbg_max[i];

		// --- collision box: 8 corners on the BOX basis → 12 edges ---
		vector bc = '0.4 0.7 1';
		vector b000 = o + bF*mn_x + bR*mn_y + bU*mn_z;
		vector b100 = o + bF*mx_x + bR*mn_y + bU*mn_z;
		vector b110 = o + bF*mx_x + bR*mx_y + bU*mn_z;
		vector b010 = o + bF*mn_x + bR*mx_y + bU*mn_z;
		vector b001 = o + bF*mn_x + bR*mn_y + bU*mx_z;
		vector b101 = o + bF*mx_x + bR*mn_y + bU*mx_z;
		vector b111 = o + bF*mx_x + bR*mx_y + bU*mx_z;
		vector b011 = o + bF*mn_x + bR*mx_y + bU*mx_z;
		CSQC_DebugLine(b000, b100, bc, 0.6); CSQC_DebugLine(b100, b110, bc, 0.6);
		CSQC_DebugLine(b110, b010, bc, 0.6); CSQC_DebugLine(b010, b000, bc, 0.6);
		CSQC_DebugLine(b001, b101, bc, 0.6); CSQC_DebugLine(b101, b111, bc, 0.6);
		CSQC_DebugLine(b111, b011, bc, 0.6); CSQC_DebugLine(b011, b001, bc, 0.6);
		CSQC_DebugLine(b000, b001, bc, 0.6); CSQC_DebugLine(b100, b101, bc, 0.6);
		CSQC_DebugLine(b110, b111, bc, 0.6); CSQC_DebugLine(b010, b011, bc, 0.6);

		// --- wheels: mount→contact ray (compression colour) + REAL force arrow (cyan) ---
		float wc = cardbg_wc[i];
		float k = 0;
		while (k < wc)
		{
			vector wm  = cardbg_wmount[i * 4 + k];
			vector ct  = cardbg_wcontact[i * 4 + k];
			float  cmp = cardbg_wcomp[i * 4 + k];
			vector wcol;
			if (cmp < 0)
				wcol = '0.5 0.5 0.5';           // airborne
			else
			{
				float t = cmp / 12; if (t > 1) t = 1;
				wcol = [t, 1 - t, 0.15];        // green → red by compression
			}
			CSQC_DebugLine(wm, ct, wcol, 0.9);
			CSQC_DebugLine(ct - '3 0 0', ct + '3 0 0', wcol, 0.9);
			CSQC_DebugLine(ct - '0 3 0', ct + '0 3 0', wcol, 0.9);
			CSQC_DebugLine(ct - '0 0 3', ct + '0 0 3', wcol, 0.9);

			// force arrow at the wheel (cyan) — length ∝ |force|, capped
			vector wf = cardbg_wforce[i * 4 + k];
			float  fl = vlen(wf);
			if (fl > 1)
			{
				float len = fl * 0.004; if (len > 80) len = 80;
				CSQC_DebugArrow(wm, wm + (wf / fl) * len, '0 1 1', 1);
			}
			k = k + 1;
		}

		// --- steering heading: yellow arrow from the front axle midpoint (drive basis) ---
		if (wc >= 2)
		{
			vector fmid = (cardbg_wmount[i * 4 + 0] + cardbg_wmount[i * 4 + 1]) * 0.5;
			float  sr   = cardbg_steer[i] * 0.0174533;
			vector sdir = cF * cos(sr) + cR * sin(sr);
			CSQC_DebugArrow(fmid, fmid + sdir * 48, '1 1 0', 1);
		}

		// --- true UP (righting target): orange arrow from the roof; points straight up when level,
		//     leans when tilted — shows the anti-flip at work.  bU is the real body up (no model_yaw). ---
		vector roof = o + bU * (mx_z + 6);
		CSQC_DebugArrow(roof, roof + bU * 24, '1 0.6 0.1', 1);

		// --- velocity: magenta arrow from the centre (0.3 s lookahead) ---
		vector vel = cardbg_vel[i];
		if (vlen(vel) > 1)
			CSQC_DebugArrow(o, o + vel * 0.3, '1 0.35 1', 1);

		i = i + 1;
	}
};

// 2D force-data panel — hooked into CSQC_DrawDebugPanels (cl_debuginfo.qc), HUD pass.
// Self-gates on a fresh car stream (i.e. sv_debug_car is on).  Reuses dbg_line + DBG_* from cl_debuginfo.qc.
float(float x, float y) Car_DrawForcePanel =
{
	if (cardbg_n <= 0)               return y;
	if (cltime - cardbg_last > 0.5)  return y;

	float ci = 0;   // default: first streamed car
	// If the local player is driving, show THAT car — the streamed car nearest the seat
	// (predicted_player.origin), the same nearest-match the chase camera uses in cl_main.qc.
	if (predicted_player && predicted_player.pm_incar)
	{
		float besti = -1, bestd = 1000000, ii = 0;
		while (ii < cardbg_n)
		{
			float dd = vlen(cardbg_org[ii] - predicted_player.origin);
			if (dd < bestd) { bestd = dd; besti = ii; }
			ii = ii + 1;
		}
		if (besti >= 0) ci = besti;
	}

	float rmp = cvar("r_meshpitch"); if (rmp == 0) rmp = -1;
	float rmr = cvar("r_meshroll");  if (rmr == 0) rmr =  1;
	vector a = cardbg_ang[ci];
	float ps = cardbg_pscale[ci]; if (ps == 0) ps = rmp;
	makevectors([a_x * ps, a_y, a_z * rmr]);
	vector bU = v_up;                                   // true body up
	float lean = vlen([bU_x, bU_y, 0]);                 // 0 = flat, ~0.71 = 45°, 1 = on its side

	vector vel = cardbg_vel[ci];
	float hspeed = vlen([vel_x, vel_y, 0]);

	float wc = cardbg_wc[ci];
	float ng = 0, k = 0;
	while (k < wc) { if (cardbg_wcomp[ci * 4 + k] >= 0) ng = ng + 1; k = k + 1; }

	float thr = cardbg_thr[ci];
	string thrs = "coast";
	if      (thr > 0) thrs = "FWD";
	else if (thr < 0) thrs = "REV/brake";

	y = dbg_line(x, y, "== CAR (forces) ==", "", DBG_WARN_COL);
	y = dbg_line(x, y, "Speed",    sprintf("%.0f u/s", hspeed), DBG_VALUE_COL);
	vector lcol = DBG_GOOD_COL;
	if (lean > 0.5)       lcol = DBG_BAD_COL;
	else if (lean > 0.15) lcol = DBG_WARN_COL;
	y = dbg_line(x, y, "Lean",     sprintf("%.2f (0=flat)", lean), lcol);
	vector gcol = (ng >= wc) ? DBG_GOOD_COL : DBG_WARN_COL;
	y = dbg_line(x, y, "Grounded", sprintf("%d / %d wheels", ng, wc), gcol);
	// per-wheel suspension compression (FL FR RL RR) — UNEVEN values = asymmetric load = the resting torque
	// that shows up as steady sideways wheel force.  Even here + ~0 wheel force = healthy.
	y = dbg_line(x, y, "Wheel comp", sprintf("%.1f %.1f %.1f %.1f",
		cardbg_wcomp[ci*4+0], cardbg_wcomp[ci*4+1], cardbg_wcomp[ci*4+2], cardbg_wcomp[ci*4+3]), DBG_VALUE_COL);
	// CG offset: horizontal distance of the collision-box centre from the origin.  >~2u on a func_car = an
	// off-centre ORIGIN brush (was the phantom-force cause); wheels now mount on the CG so it's cosmetic.
	vector mn = cardbg_min[ci], mx = cardbg_max[ci];
	float cgoff = vlen([(mn_x + mx_x) * 0.5, (mn_y + mx_y) * 0.5, 0]);
	y = dbg_line(x, y, "CG off", sprintf("%.1f u", cgoff), (cgoff > 2) ? DBG_WARN_COL : DBG_GOOD_COL);
	y = dbg_line(x, y, "Steer",    sprintf("%.0f deg", cardbg_steer[ci]), DBG_VALUE_COL);
	y = dbg_line(x, y, "Throttle", thrs, DBG_VALUE_COL);
	float hb = cardbg_brake[ci];
	string hbs = "off";
	if      (hb == 1) hbs = "BRAKE (hold)";
	else if (hb == 2) hbs = "DRIFT (latched)";
	y = dbg_line(x, y, "Handbrake", hbs, (hb != 0) ? DBG_WARN_COL : DBG_LABEL_COL);
	y = dbg_line(x, y, "Ride Vz",  sprintf("%.0f u/s", vel_z), DBG_VALUE_COL);
	// per-wheel net force, ÷1000 (the "(k)" = thousands) so the numbers are readable
	y = dbg_line(x, y, "Wheel force (k)", sprintf("%.1f %.1f %.1f %.1f",
		vlen(cardbg_wforce[ci*4+0]) * 0.001, vlen(cardbg_wforce[ci*4+1]) * 0.001,
		vlen(cardbg_wforce[ci*4+2]) * 0.001, vlen(cardbg_wforce[ci*4+3]) * 0.001), DBG_VALUE_COL);
	y = dbg_line(x, y, "Drive yaw", sprintf("%.0f deg", cardbg_myaw[ci]), DBG_LABEL_COL);
	// effective tuning (global cvars, read client-side) so you can see what you're dialing
	y = dbg_line(x, y, "Accel",    sprintf("%.0f u/s2",    cvar("sv_car_accel")),    DBG_VALUE_COL);
	y = dbg_line(x, y, "Softness", sprintf("%.2f u",       cvar("sv_car_suspension_softness")), DBG_VALUE_COL);
	y = dbg_line(x, y, "Damping",  sprintf("%.2f (1=crit)",cvar("sv_car_damping")),  DBG_VALUE_COL);
	y = dbg_line(x, y, "Grip",     sprintf("%.1f",         cvar("sv_car_grip")),     DBG_VALUE_COL);
	return y + 4;
};
