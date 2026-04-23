
void() CSQC_Ent_Remove =
{
	if (self == csqc_authority_proxy)
	{
		csqc_authority_proxy = world;
		csqc_proxy_seen = FALSE;
		csqc_proxy_entnum = 0;
		csqc_baseline_valid = FALSE;
		csqc_prediction_valid = FALSE;
		csqc_present_valid = FALSE;
		csqc_dbg_seed_source = 0;
	}

	push_list_remove_csqc(self);
	tele_list_remove_csqc(self);
	ladder_list_remove_csqc(self);

	// Server removes a dropped_weapon entity when accepting a touch of a
	// player-dropped weapon (sv_weapons.qc remove() path).  Map-placed
	// weapons are hidden with setmodel("") instead, so they route through
	// CSQC_DroppedWeapon_Update's mdl=="" branch — but player-dropped
	// ones never fire that update.  Mirror the same confirm/catchup
	// semantics here so the debug trace isn't silent on the drop-and-
	// pickup path (where the predict was silently rejected because the
	// dropper's slot_primary is still stale on CSQC until the drop
	// server-acks).
	if (self.classname == "csqc_dropped_weapon" && !self.dropped_weapon_logged)
	{
		// Dedup: if the mdl=="" branch already printed/played for this
		// same entity, don't fire again on the remove.  Pickup sound
		// play lives in the CSQC_EVENT_WEAPON_PICKUP_SOUND handler;
		// see its comment for the predict-vs-catchup gate.
		if (self.dropped_weapon_predicted_taken)
		{
			if (cvar("sv_debug_pickups"))
				print(sprintf("^2[pickup-confirm]^7 weapon ^2%s^7 — server removed entity (player-drop accept)\n",
				              Weapon_DisplayName(self.dropped_weapon_id)));
		}
		else
		{
			if (cvar("sv_debug_pickups"))
				print(sprintf("^3[pickup-catchup]^7 weapon ^2%s^7 — server removed entity, no local prediction\n",
				              Weapon_DisplayName(self.dropped_weapon_id)));
		}
		self.dropped_weapon_logged = 1;
	}

	dropped_weapon_list_remove_csqc(self);

	remove(self);
};

void() CSQC_Shutdown =
{
	CSQC_ResetPredictionState();
};

void() CSQC_EnsureWorldSolid =
{
	world.solid = SOLID_BSP;
};

noref void(float apiver, string enginename, float enginever) CSQC_Init =
{
	CSQC_EnsureWorldSolid();
	drawfont = loadfont("", "Courier Prime Code", "12,16,24,32,64,72,128,256,512", -1, 0, 0);
	hud_font = loadfont("hud", "gfx/RobotoEB", "8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	hud_font_regular = loadfont("hud_regular", "gfx/Roboto", "8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	hud_font_mono = loadfont("hud_mono", "gfx/GoogleMed", "8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	// NOTE: we do NOT touch r_particledesc here. The cvar's reload callback
	// bails when the client is in ca_connected state (p_script.c:3799), so
	// setting it from CSQC_Init has no effect on the loaded set.  Instead,
	// every particleeffectnum() call uses the "weapons.foo" prefix syntax
	// which auto-loads particles/weapons.cfg on first miss (p_script.c:668).

	precache_everything();
	CSQC_PrecacheShells();
	CSQC_PrecacheBreakables();
	CSQC_BulletHolesInit();
	precache_pic("gfx/scope.png");
	registercommand("spectate");
	registercommand("spec");
	registercommand("probe");
	registercommand("edicts_near");
	registercommand("cl_edicts_near");

	// Gameplay toggles
	registercvar("cl_autohop",           "0");
	registercvar("cl_hitmarker",         "1");
	registercvar("cl_speedometer",       "0");
	// 1 = dim the world behind the scoreboard / team menu (original look).
	// 0 = no dimming, world stays fully visible behind menu panels.
	registercvar("cl_menu_backdrop",     "1");
	// 1 = tint remote player models with their team colour (faint wash).
	// Persisted to data/settings.cfg via client_config_cvars in m_menu.qc.
	registercvar("cl_teamcolours",       "1");
	// Driven by HUD_DrawPainFlash — read by glsl/damageflash.glsl via
	// `!!cvarf r_damageflash_intensity`.  Intensity 0 = no visible effect.
	registercvar("r_damageflash_intensity", "0");

	// Debug overlays
	registercvar("cl_debug_impacts",     "0");
	registercvar("cl_debug_hitboxes",    "0");
	registercvar("cl_debug_net",         "0");
	registercvar("cl_debug_bandwidth",   "0");
	registercvar("cl_debug_weapon",      "0");
	registercvar("cl_debug_move",        "0");
	registercvar("cl_debug_game",        "0");
	registercvar("cl_debug_playermodel", "0");
	registercvar("sv_debug_ent_types",   "0");
	registercvar("sv_debug_pickups",     "0");
	// Rolling-jitter diagnostic panel — min/avg/max/stddev over 60 samples
	// for frametime, presentation step, speed-normalised step regularity,
	// forward-projected step, snapshot arrival dt, reconcile correction,
	// and unacked command backlog.  See CSQC_DrawDebugSmoothing.
	registercvar("cl_debug_smoothing",   "0");
	// Footstep-prediction diagnostics. cl_debug_footsteps gates CSQC
	// predict/replay/recv logs; sv_debug_footsteps is registered here
	// for menu discoverability but is read by the server via cvar(),
	// so setting it in a listen-server console enables the server log.
	registercvar("cl_debug_footsteps",   "0");
	registercvar("sv_debug_footsteps",   "0");

	// Remote-player extrapolation + interpolation controls (see
	// CSQC_ExtrapolateRemotePlayers in cl_player.qc).
	registercvar("cl_extrap",                   "1");   // master on/off
	registercvar("cl_extrap_grounded",          "0");   // extrap grounded players too
	registercvar("cl_extrap_grounded_minspeed", "0");   // speed gate for grounded extrap
	registercvar("cl_extrap_max",               "3");   // max extrap window in ticrate multiples
	registercvar("cl_debug_extrap",             "0");   // console spam
	registercvar("cl_interp_time",              "0");   // lerp-behind window in seconds (0 = off)

	// net_graph HUD toggle (see HUD_DrawNetGraph in cl_hud.qc).
	registercvar("net_graph",                   "0");

	// Send predicted player hits to the server as a claim (see
	// CSQC_SendHitclaim in sh_weapon_logic.qc). Server gates acceptance
	// via sv_trust_clienthits — default 0 means claims are ignored, so
	// sending by default costs only a few bytes and does nothing.
	registercvar("cl_predict_hits",             "1");
};

noref void() CSQC_WorldLoaded =
{
	// Clear stale linked lists from previous map
	ladder_trigger_list = world;
	teleport_trigger_list = world;

	CSQC_EnsureWorldSolid();
	CSQC_ResetPredictionState();
	Smooth_Reset();

	// Clear any stale kill-feed entries carried over from the previous map.
	KillFeed_Clear();
};

// CSQC_Ent_Update is implemented in cl_player.qc

// CALLED EVERY CLIENT RENDER FRAME
void(float width, float height, float menushown) CSQC_UpdateView =
{
	//clear and update our global screen resolution vars
	clearscene();
	g_width = width;
	g_height = height;
	CSQC_BulletHolesStartFrame();

	//disable quake status bar and quake crosshair
	setproperty(VF_DRAWENGINESBAR, 0);
	setproperty(VF_DRAWCROSSHAIR, 0);

	// Smoothing diagnostics — push per-frame samples.  Gate frametime
	// on > 0 so engine-paused ticks (menu open, alt-tab) don't inject
	// zero-width samples that corrupt min / stddev.
	if (frametime > 0)
		Smooth_Push(SMOOTH_M_FT, frametime * 1000);
	Smooth_Push(SMOOTH_M_UNACK, pred_cmd_latest_sequence - sv_confirmed_cmdframe);

	// Backdrop mode: we're running the cl_menumap listen server purely as a
	// render backdrop for the main menu.  MenuQC sets cl_menu_backdrop_active
	// when launching the backdrop map and clears it when transitioning to a
	// real server (Connect / Create Server).  The flag is persistent across
	// menu open/close so ESC-closing the main menu leaves a clean view with
	// NO HUD, NO team-select overlay, NO scoreboard — just the cameras.
	float in_menu_backdrop = cvar("cl_menu_backdrop_active") > 0;

	CSQC_BuildPresentationView();

	// --- Spectator / death cam ---
	Spectate_UpdateState();

	if (Spectate_IsActive())
	{
		Spectate_CheckTargetAlive();
		Spectate_UpdateCamera();

		CSQC_SampleRemotePlayersForInterp();
		CSQC_ExtrapolateRemotePlayers();
		if (spec_mode == SPEC_MODE_FIRSTPERSON && spec_target > 0 && !Spectate_InDeathCam())
		{
			setproperty(VF_VIEWENTITY, spec_target);
			// Lock mouse — the target's view drives angles, the local mouse
			// delta would just accumulate as phantom drift to be resolved on
			// detach / freecam swap.
			setsensitivityscaler(0);
		}
		else
		{
			setproperty(VF_VIEWENTITY, 0);
			setsensitivityscaler(1);
		}
		addentities(MASK_ENGINE);
		CSQC_DrawMuzzleFlash();
		CSQC_DrawImpactLights();
		CSQC_DrawDebugHitboxes();
	CSQC_DrawServerHitboxes();
	CSQC_DrawContinuousHitboxes();
		renderscene();

		if (!in_menu_backdrop)
		{
			float spec_prev_font = drawfont;
			drawfont = hud_font;
			Spectate_DrawHUD();
			HUD_DrawCenterMessage();
			HUD_DrawRoundTimer();
			HUD_DrawKillFeed();
			drawfont = spec_prev_font;

			// Still allow scoreboard/team menu while spectating
			TeamMenuUpdateCursorState();
			if (HUD_ScoreboardVisible())
				HUD_DrawScoreboard();
			if (TeamMenuIsOpen())
			{
				float spec_team_font = drawfont;
				drawfont = hud_font;
				sui_begin(g_width, g_height);
				TeamMenuDraw();
				sui_menu_nav();
				sui_end();
				drawfont = spec_team_font;
			}
		}
		return;
	}

	// --- Normal alive camera ---
	// While the local player is still in team-select (player_team <= TEAM_NONE),
	// the server is driving their origin every tick via Camera_PlacePlayerAtCurrent.
	// We have no prediction proxy for them yet (PM_EnsurePredictionProxy doesn't run
	// until PlayerSpawn), so predicted_player can get seeded from a stale
	// engine_player.origin (often 0,0,0 on the very first frame), lock
	// csqc_prediction_valid = TRUE, and from then on its bogus origin overrides
	// the engine's authoritative view.  Skip the CSQC override while in team-select
	// and let the engine render from the real player entity.
	float in_team_select = getstati(STAT_PLAYERTEAM) <= TEAM_NONE;

	if (predicted_player && csqc_prediction_valid && !in_team_select)
	{
		if (csqc_present_valid)
			campos = csqc_present_origin + csqc_present_view_ofs;
		else
			campos = predicted_player.origin + predicted_player.view_ofs;
		camang = view_angles;
		// Sniper breathing sway — pure visual modifier.  view_angles is
		// untouched so input_angles / server-side v_angle stay authoritative.
		camang = CSQC_ApplySniperSway(camang);
		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, camang);
	}
	else
	{
		// Don't trust the engine's fallback camera — it can snap to the wrong
		// player on some maps. Keep the last known good position instead.
		camang = view_angles;

		// Client-side sway while the player is still in team-select — runs
		// at render rate against cltime so motion stays smooth regardless
		// of ping / server tick rate.  See cl_cameras.qc for the math.
		if (in_team_select)
			camang = CSQC_TeamSelectSwayAngles(camang);

		setproperty(VF_ANGLES, camang);
	}

	// CSQC-side camera debug — mirrors the server sv_debug_camera bprint so
	// we can see both sides of the origin-sync pipeline in the same log.
	// Mode 1 = one-shot on first frame; mode 2 = 1 Hz continuous.
	float cam_dbg_mode = cvar("sv_debug_camera");
	if (cam_dbg_mode)
	{
		static float cl_cam_last_dbg;
		static float cl_cam_printed_once;
		float show;
		if (cam_dbg_mode >= 2)
			show = (cltime - cl_cam_last_dbg > 1.0);
		else
			show = !cl_cam_printed_once;

		if (show)
		{
			cl_cam_last_dbg = cltime;
			cl_cam_printed_once = 1;
			vector pp_org = predicted_player ? predicted_player.origin : '0 0 0';
			vector pp_vof = predicted_player ? predicted_player.view_ofs : '0 0 0';
			print(sprintf("[camdbg CSQC] predicted.origin=%v view_ofs=%v present_valid=%g present_origin=%v campos=%v\n",
			              pp_org, pp_vof, csqc_present_valid, csqc_present_origin, campos));
		}
	}

	// Third-person chase cam — honour chase_active/chase_back/chase_up/chase_right
	if (cvar("chase_active"))
	{
		vector chase_fwd, chase_rt, chase_up;
		makevectors(camang);
		chase_fwd = v_forward;
		chase_rt = v_right;
		chase_up = v_up;

		float cb = cvar("chase_back");   if (!cb) cb = 100;
		float cr = cvar("chase_right");
		float cu = cvar("chase_up");     if (!cu) cu = 16;

		// chase_angle rotates the camera around the player (0 = behind, 180 = front)
		float ca = cvar("chase_angle");
		if (ca)
		{
			vector orbit_ang = camang;
			orbit_ang_y += ca;
			makevectors(orbit_ang);
			chase_fwd = v_forward;
			chase_rt = v_right;
			chase_up = v_up;
		}

		vector chase_pos = campos
			- chase_fwd * cb
			+ chase_rt * cr
			+ chase_up * cu;

		// Wall clip to prevent camera going through geometry
		traceline(campos, chase_pos, TRUE, world);
		if (trace_fraction < 1)
			chase_pos = trace_endpos + trace_plane_normal * 2;

		// Point camera at the player from the chase position
		vector player_eye = campos;
		campos = chase_pos;
		vector look_ang = vectoangles(normalize(player_eye - campos));
		look_ang_x = -look_ang_x;  // Quake pitch flip
		look_ang_z = 0;             // Never roll

		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, look_ang);
	}

	// Record the current server snapshot into the interp ring buffer
	// (no-op unless a new snapshot has arrived since last call), then
	// either lerp-behind (cl_interp_time > 0) or extrap.
	CSQC_PushInterpUserInfo();
	CSQC_SampleRemotePlayersForInterp();
	CSQC_ExtrapolateRemotePlayers();

	// CSQC submits its own predicted viewmodel, so keep the engine's
	// authoritative weaponmodel hidden to avoid double-rendering.
	setproperty(VF_VIEWENTITY, 0);

	// Zoom FOV override + sensitivity scaling for scoped weapons.
	// In team-select (TEAM_NONE) the server drives origin + angles through
	// the camera system via fixangle — zero the mouse scaler so the user's
	// mouse doesn't accumulate phantom deltas that would be committed the
	// moment they actually join a team.
	if (in_team_select)
	{
		setsensitivityscaler(0);
	}
	else if (predicted_player && csqc_prediction_valid && predicted_player.zoomstage > 0
	         && Weapon_HasScope(predicted_player.weapon))
	{
		// Same client-side gate as HUD_DrawScope in cl_hud.qc: if the
		// predicted weapon can't scope, ignore a lingering zoomstage
		// (stale from the previous weapon under high ping) and fall
		// through to the default sensitivity / unzoomed FOV branch.
		float zoom_fov;
		if (predicted_player.zoomstage == 1)
			zoom_fov = ZOOM_FOV_STAGE1;
		else
			zoom_fov = ZOOM_FOV_STAGE2;

		setproperty(VF_AFOV, zoom_fov);
		setsensitivityscaler(zoom_fov / cvar("fov"));
	}
	else
	{
		setsensitivityscaler(1);
	}

	// Paint team-colour tints on player entities BEFORE the engine adds
	// them for this frame — .colormod reaches the shader as e_colourident.
	CSQC_ApplyTeamTints();

	//autoadd entities received from servers for drawing
	addentities(MASK_ENGINE);
	CSQC_AddPredictedViewmodel();
	CSQC_CheckFakeDropRemoval();
	CSQC_DrawMuzzleFlash();
	CSQC_DrawImpactLights();
	CSQC_DrawDebugImpacts();
	CSQC_DrawDebugHitboxes();
	CSQC_DrawServerHitboxes();
	CSQC_DrawContinuousHitboxes();

	//does what you think it does
	renderscene();
	CSQC_DrawDebugImpactText();

	if (!in_menu_backdrop)
	{
		HUD_DrawPainFlash();
		HUD_DrawHitmarker();
		CSQC_DrawWeaponHUD();
		HUD_DrawSpeedometer();
		HUD_DrawNetGraph();
		HUD_DrawKillFeed();
		CSQC_DrawDebugPanels();

		// Update team menu cursor state every frame
		TeamMenuUpdateCursorState();

		// Draw scoreboard (raw draw calls, no SUI needed)
		if (HUD_ScoreboardVisible())
			HUD_DrawScoreboard();

		// Draw team select (needs SUI)
		if (TeamMenuIsOpen())
		{
			float team_prev_font = drawfont;
			drawfont = hud_font;
			sui_begin(g_width, g_height);
			TeamMenuDraw();
			sui_menu_nav();
			sui_end();
			drawfont = team_prev_font;
		}
	}
};

// Suppress the server echo of the local player's footstep and weapon sounds
// when CSQC already played them locally.  Suppression is gated on the last
// local playback timestamp so that prediction divergence still lets the
// authoritative server sound through.
//
// "sounds/player/" is the full path used in this mod.  FTE's QW protocol may
// strip the "sounds/" prefix on the wire, so both forms are accepted.
noref float(float entnum, float channel, string soundname, float vol,
            float attenuation, vector pos, float pitchmod, float flags)
CSQC_Event_Sound =
{
    float ping_est;
    float age;

    if (entnum != player_localentnum || player_localentnum <= 0)
        return FALSE;

    // Suppress predicted weapon echoes on the local player.
    // Use a fixed 1-second window — covers slow weapons (shotgun pump)
    // and avoids ping-estimation edge cases that cause double sounds.
    if (channel == CHAN_WEAPON)
    {
        age = cltime - csqc_last_predicted_weapon_sound_time;
        if (csqc_last_predicted_weapon_sound_time > 0 && age < 1.0)
            return TRUE;
        return FALSE;
    }

    // Suppress predicted CHAN_AUTO echoes (bolt, reload, pump sounds)
    if (channel == CHAN_AUTO)
    {
        age = cltime - csqc_last_predicted_auto_sound_time;
        if (csqc_last_predicted_auto_sound_time > 0 && age < 1.0)
            return TRUE;
        return FALSE;
    }

    if (channel != CHAN_BODY)
        return FALSE;
    if (substring(soundname, 0, 14) != "sounds/player/"
        && substring(soundname, 0, 7) != "player/")
        return FALSE;

    return FALSE;
};

float(string cmd) CSQC_ConsoleCommand =
{
	tokenize(cmd);
	switch(argv(0))
	{
		case "spectate":
		case "spec":
			localcmd("cmd spectate\n");
			return TRUE;
		case "probe":
		{
			// Diagnostic: fire a player-hull tracebox forward from the
			// local eye, print what CSQC sees, then ask the server to
			// do the same. Mismatch between the two lines identifies
			// invisible-collider / prediction-drift bugs.
			vector eye = predicted_player.origin + predicted_player.view_ofs;
			makevectors(view_angles);
			vector end = eye + v_forward * 1024;
			tracebox(eye, '-16 -16 0', '16 16 56', end, MOVE_NORMAL, predicted_player);
			if (trace_fraction < 1)
			{
				print(sprintf("^3[probe]^7 client: hit classname='%s' ent=%g origin=%v solid=%g\n",
					trace_ent.classname, trace_ent.entnum, trace_ent.origin, trace_ent.solid));
				print(sprintf("              mins=%v maxs=%v model='%s' frac=%.3f endpos=%v\n",
					trace_ent.mins, trace_ent.maxs, trace_ent.model, trace_fraction, trace_endpos));
			}
			else
				print(sprintf("^3[probe]^7 client: no hit (full 1024 trace, endpos=%v)\n", trace_endpos));
			localcmd("cmd probe\n");
			return TRUE;
		}
		case "edicts_near":
		{
			// Diagnostic: forward the whole arg line to the server so it
			// can dump every SSQC edict whose origin lies within radius R
			// of point P. Catches non-networked colliders the client
			// never learns about. Usage: edicts_near "0 0 0" 16
			localcmd(sprintf("cmd edicts_near \"%s\" %s\n",
				argv(1), argv(2)));
			return TRUE;
		}
		case "cl_edicts_near":
		{
			// CSQC-side mirror: walk every CSQC entity and dump any whose
			// world bbox is within radius of the search point. This is
			// what to use when the server scan is empty but pmove still
			// blocks — a stale CSQC entity (PVSF_NOREMOVE leftover, bad
			// snapshot, etc.) is the only thing left that could have a
			// solid hull on this side without one on the server.
			vector p = stov(argv(1));
			float  r = stof(argv(2));
			if (r <= 0)
				r = 32;
			print(sprintf("^3[cl_edicts_near]^7 scanning bbox within %g of %v:\n", r, p));
			float hits = 0;
			entity e = world;
			while ((e = nextent(e)))
			{
				if (e.classname == "" && e.model == "" && e.solid == 0)
					continue;
				vector amin = e.origin + e.mins;
				vector amax = e.origin + e.maxs;
				vector closest;
				closest_x = max(amin_x, min(p_x, amax_x));
				closest_y = max(amin_y, min(p_y, amax_y));
				closest_z = max(amin_z, min(p_z, amax_z));
				if (vlen(closest - p) > r)
					continue;
				print(sprintf(" ent=%g class='%s' origin=%v solid=%g\n",
					e.entnum, e.classname, e.origin, e.solid));
				print(sprintf("    absmin=%v absmax=%v model='%s' drawmask=%g\n",
					amin, amax, e.model, e.drawmask));
				hits = hits + 1;
			}
			print(sprintf("^3[cl_edicts_near]^7 done, %g matched\n", hits));
			return TRUE;
		}
		case "noclip":
		{
			// Cheats gate — read the serverinfo mirror the server publishes
			// each StartFrame.  If off, forward the text command so the
			// server's existing "noclip requires mp_cheats 1" sprint fires.
			string cheats = serverkey("mp_cheats");
			if (cheats == "" || cheats == "0")
			{
				localcmd("cmd noclip\n");
				return TRUE;
			}

			// Route through impulse 10 — the CSQC_PredictWeaponImpulse path
			// at cl_weapons.qc:544 already toggles pm_movetype during replay,
			// and the impulse is stored in the buffered usercmd ring so
			// CSQC_ReconcilePrediction re-applies it every frame until the
			// server ack catches up.  Directly mutating predicted_player
			// .pm_movetype does not survive — CSQC_ResetToConfirmedState
			// restores the last ack'd value on every reconcile (which is
			// why at 999 ping the local flip was instantly wiped, but in
			// the void — where no snapshots arrive — it appeared to work).
			localcmd("impulse 10\n");

			// Local feedback this frame; the server's matching sprint
			// lands ~RTT later.
			if (predicted_player)
			{
				if (predicted_player.pm_movetype == PM_MOVETYPE_NOCLIP)
					print("noclip OFF\n");
				else
					print("noclip ON\n");
			}

			return TRUE;
		}
		default:
			return FALSE;
	}
	return TRUE;
};

float(float evtype, float scanx, float chary, float devid) CSQC_InputEvent =
{
	// Team menu takes priority when open
	if (TeamMenuIsOpen())
		return TeamMenuInputEvent(evtype, scanx, chary, devid);

	// Spectator input (post-deathdelay only, not during death cam)
	if (Spectate_IsActive() && !Spectate_InDeathCam())
	{
		if (Spectate_HandleInput(evtype, scanx, chary, devid))
			return TRUE;
	}

	// Scoreboard intercepts TAB/+showscores
	if (HUD_ScoreboardInputEvent(evtype, scanx, chary, devid))
		return TRUE;

	switch(evtype)
	{
	case IE_KEYDOWN:
		CSQC_UpdateLiveInputFromBind(scanx, TRUE);
		return FALSE;
	case IE_KEYUP:
		CSQC_UpdateLiveInputFromBind(scanx, FALSE);
		return FALSE;
	case IE_MOUSEDELTA:
		return FALSE;
	case IE_MOUSEABS:
		cursor_pos_x = scanx;
		cursor_pos_y = chary;
		return FALSE;
	}
	return FALSE;
};


// Estimated wire bytes per event ID (SVC + event byte + payload).
// POINTSOUND is a string → rough average. Use for the debug bandwidth HUD.
float(float ev) _net_event_bytes =
{
	if (ev == CSQC_EVENT_IMPACT)          return 27;  // svc+ev+pos[3]+normal[3]+mat byte
	if (ev == CSQC_EVENT_SHELL)           return 39;
	if (ev == CSQC_EVENT_MAGDROP)         return 27;
	if (ev == CSQC_EVENT_POINTSOUND)      return 34;
	if (ev == CSQC_EVENT_DEBUG_IMPACT)    return 28;
	if (ev == CSQC_EVENT_ROUND_CLEANUP)   return 2;
	if (ev == CSQC_EVENT_DAMAGE_FLASH)    return 3;
	if (ev == CSQC_EVENT_HITMARKER)       return 2;
	if (ev == CSQC_EVENT_BRUSH_DESTROY)   return 6;
	if (ev == CSQC_EVENT_SERVER_HITBOXES) return 55;
	if (ev == CSQC_EVENT_GLASS_GIBS)      return 30;  // +1 exclude byte vs prior
	if (ev == CSQC_EVENT_PLAYER_GIBS)     return 31;  // 2 + 12 + 12 + 1 + 2 + 2 svc/event hdr
	if (ev == CSQC_EVENT_DEBRIS_GIBS)     return 34;  // +1 exclude byte vs prior
	if (ev == CSQC_EVENT_KILLFEED)        return 7;   // 2 svc hdr + 5 kill-feed bytes
	if (ev == CSQC_EVENT_WEAPON_PICKUP_SOUND) return 15;  // 2 svc hdr + 1 exclude + 12 origin
	if (ev == CSQC_EVENT_BREAKABLE_IMPACT_SOUND) return 16;  // 2 svc hdr + 1 exclude + 1 style + 12 origin
	if (ev == CSQC_EVENT_BREAKABLE_BREAK_SOUND)  return 16;  // same wire layout as impact sound
	if (ev == CSQC_EVENT_FOOTSTEP_SOUND)         return 40;  // 2 svc hdr + 1 exclude + 1 vol + ~24 string + 12 origin (estimate; string length varies by file path)
	if (ev == CSQC_EVENT_DEATH_DROP)             return 61;  // 2 svc hdr + 1 weapon + 1 slot + 24 origin/vel + ~32 model path (variable)
	return 2;
};

// Last-time bookkeeping for cl_debug_footsteps cadence logs. Set to the
// event's receive time each time the CSQC_EVENT_FOOTSTEP_SOUND handler
// processes a payload (play or skip), so the `dt` field in subsequent
// lines shows the interval between received step events.
float cl_last_recv_step_time;

// (cl_local_pickup_exclude_time lives in client/cl_customdefs.qc so both
// cl_weapons.qc — compiled earlier — and cl_main.qc can see it.)

void() CSQC_Parse_Event =
{
	float first = readbyte();
	CSQC_NetStat_RecordEvent(_net_event_bytes(first));
	switch(first) {
		case CSQC_EVENT_KILLFEED:
			KillFeed_Parse();
			break;
		case CSQC_EVENT_IMPACT:
		{
			vector pos, normal;
			pos_x = readcoord();
			pos_y = readcoord();
			pos_z = readcoord();
			normal_x = readcoord();
			normal_y = readcoord();
			normal_z = readcoord();
			float rem_mat = readbyte();
			CSQC_BulletImpactRemote(pos, normal, rem_mat);
			break;
		}
		case CSQC_EVENT_SHELL:
		{
			float sh_type = readbyte();
			vector sh_org = readvector();
			vector sh_vel = readvector();
			vector sh_avel = readvector();
			string sh_mdl = CSQC_ShellModelForType(sh_type);
			CSQC_SpawnRemoteCasing(sh_mdl, sh_org, sh_vel, sh_avel);
			break;
		}
		case CSQC_EVENT_MAGDROP:
		{
			float mg_type = readbyte();
			vector mg_org = readvector();
			vector mg_vel = readvector();
			string mg_mdl = CSQC_MagModelForType(mg_type);
			CSQC_SpawnRemoteMag(mg_mdl, mg_org, mg_vel, '0 180 0');
			break;
		}
		case CSQC_EVENT_POINTSOUND:
		{
			vector snd_pos;
			snd_pos_x = readcoord();
			snd_pos_y = readcoord();
			snd_pos_z = readcoord();
			string snd_path = readstring();
			pointsound(snd_pos, snd_path, 1, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_DEBUG_IMPACT:
		{
			vector dbg_pos, dbg_eye;
			float dbg_dmg, dbg_hitgroup;
			dbg_pos_x = readcoord();
			dbg_pos_y = readcoord();
			dbg_pos_z = readcoord();
			dbg_eye_x = readcoord();
			dbg_eye_y = readcoord();
			dbg_eye_z = readcoord();
			dbg_dmg = readbyte();
			dbg_hitgroup = readbyte();
			if (cvar("cl_debug_impacts"))
			{
				// Color by hitgroup: red=head, yellow=stomach, white=chest, grey=limbs
				vector dbg_col;
				if (dbg_hitgroup == HITGROUP_HEAD)
					dbg_col = '1 0.2 0.2';
				else if (dbg_hitgroup == HITGROUP_STOMACH)
					dbg_col = '1 0.8 0.2';
				else if (dbg_hitgroup == HITGROUP_CHEST)
					dbg_col = '1 1 1';
				else if (dbg_hitgroup >= HITGROUP_LEFTARM)
					dbg_col = '0.6 0.6 0.7';
				else
					dbg_col = '0.6 0 1';  // generic/world = purple

				CSQC_AddDebugImpact(dbg_pos, dbg_eye, dbg_col, dbg_dmg, dbg_hitgroup);
			}
			break;
		}
		case CSQC_EVENT_ROUND_CLEANUP:
		{
			CSQC_BulletHolesWipeAll();
			CSQC_ShellsWipeAll();
			break;
		}
		case CSQC_EVENT_DAMAGE_FLASH:
		{
			float dmg = readbyte();
			csqc_pain_flash_time = cltime;
			csqc_pain_flash_alpha = bound(0.1, dmg * 0.01, 0.6);
			// Play bullet hit pain sound for the victim
			if (random() < 0.5)
				localsound("sounds/player/bullethit1.wav");
			else
				localsound("sounds/player/bullethit2.wav");
			break;
		}
		case CSQC_EVENT_DEATH_DROP:
		{
			// Server-authoritative scatter visual for the dying local
			// player.  The real SendEntity version pops in at the
			// matching settled origin after weapon_become_solid fires
			// at +0.7s, at which point the fake expires.
			float dd_weapon = readbyte();
			float dd_slot   = readbyte();
			vector dd_org, dd_vel;
			dd_org_x = readcoord();
			dd_org_y = readcoord();
			dd_org_z = readcoord();
			dd_vel_x = readcoord();
			dd_vel_y = readcoord();
			dd_vel_z = readcoord();
			string dd_mdl = readstring();
			float dd_ping = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
			dd_ping = bound(0.05, dd_ping, 1.0);
			CSQC_SpawnFakeDropAt(dd_weapon, dd_slot, dd_mdl, dd_org, dd_vel, dd_ping + 0.75);
			break;
		}
		case CSQC_EVENT_GLASS_GIBS:
		{
			// Attacker-exclude: the shooter's CSQC_PredictBreakableBreak
			// already spawned matching gibs locally, so skip the server
			// copy to avoid doubled debris.
			float gb_exclude = readbyte();
			vector gb_mins, gb_maxs;
			gb_mins_x = readcoord();
			gb_mins_y = readcoord();
			gb_mins_z = readcoord();
			gb_maxs_x = readcoord();
			gb_maxs_y = readcoord();
			gb_maxs_z = readcoord();
			float gb_count = readbyte();
			float gb_dmg = readshort();
			if (gb_exclude == 0 || gb_exclude != player_localentnum)
				CSQC_SpawnGlassGibs(gb_mins, gb_maxs, gb_count, gb_dmg, 0);
			break;
		}
		case CSQC_EVENT_PLAYER_GIBS:
		{
			vector pg_pos, pg_dir;
			pg_pos_x = readcoord();
			pg_pos_y = readcoord();
			pg_pos_z = readcoord();
			pg_dir_x = readcoord();
			pg_dir_y = readcoord();
			pg_dir_z = readcoord();
			float pg_count = readbyte();
			float pg_dmg = readshort();
			CSQC_SpawnPlayerGibs(pg_pos, pg_dir, pg_count, pg_dmg);
			break;
		}
		case CSQC_EVENT_DEBRIS_GIBS:
		{
			// Attacker-exclude: same pattern as CSQC_EVENT_GLASS_GIBS.
			float db_exclude = readbyte();
			vector db_mins, db_maxs;
			db_mins_x = readcoord();
			db_mins_y = readcoord();
			db_mins_z = readcoord();
			db_maxs_x = readcoord();
			db_maxs_y = readcoord();
			db_maxs_z = readcoord();
			float db_style    = readbyte();
			float db_count    = readbyte();
			float db_dmg      = readshort();
			float db_idx      = readshort();
			float db_alpha    = readbyte();
			if (db_exclude == 0 || db_exclude != player_localentnum)
				CSQC_SpawnDebrisGibs(db_mins, db_maxs, db_style, db_count,
				                     db_dmg, db_idx, db_alpha, 0);
			break;
		}
		case CSQC_EVENT_WEAPON_PICKUP_SOUND:
		{
			// Server-routed pickup sound. The pickup-er's entnum is in
			// the payload — that client already played the sound via
			// CSQC_PredictPickupWeapon, so they skip. Everyone else in
			// PVS plays pointsound at the pickup origin.
			float ps_exclude = readbyte();
			vector ps_pos;
			ps_pos_x = readcoord();
			ps_pos_y = readcoord();
			ps_pos_z = readcoord();
			if (ps_exclude == player_localentnum)
			{
				// WE are the picker.  Play locally unless CSQC_Predict
				// PickupWeapon already fired recently — the latch
				// stores cltime so the window needs to exceed the
				// RTT for a high-ping predict→confirm round trip
				// (up to ~2s at sv_minping 999).  Derive the gate
				// from actual ping so rapid successive catchup
				// pickups don't get suppressed by a stale latch at
				// low ping.
				float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
				ping_est = bound(0.05, ping_est, 1.5);
				float predict_window = ping_est * 2 + 0.5;
				if ((cltime - cl_local_predict_sound_time) > predict_window)
					localsound("sounds/weapons/pickup1.wav");
			}
			else
			{
				pointsound(ps_pos, "sounds/weapons/pickup1.wav", 1, ATTN_NORM);
			}
			break;
		}
		case CSQC_EVENT_BREAKABLE_IMPACT_SOUND:
		{
			// Attacker-excluded breakable thump. The shooter already
			// predicted the variant via Impact_PlayBreakableSound
			// inside CSQC_BulletImpact, so they skip. Remote clients
			// pick a variant from the same BREAKABLE_* style byte and
			// play it at the brush center.
			float bi_exclude = readbyte();
			float bi_style   = readbyte();
			vector bi_pos;
			bi_pos_x = readcoord();
			bi_pos_y = readcoord();
			bi_pos_z = readcoord();
			if (bi_exclude == 0 || bi_exclude != player_localentnum)
				Impact_PlayBreakableSound(bi_pos, bi_style);
			break;
		}
		case CSQC_EVENT_BREAKABLE_BREAK_SOUND:
		{
			// Same attacker-exclude pattern as the impact thump. The
			// shooter's CSQC_PredictBreakableBreak already fired the
			// break sound the moment they landed the lethal shot —
			// skip here so they don't hear a ping-delayed second copy.
			float bk_exclude = readbyte();
			float bk_style   = readbyte();
			vector bk_pos;
			bk_pos_x = readcoord();
			bk_pos_y = readcoord();
			bk_pos_z = readcoord();
			if (bk_exclude == 0 || bk_exclude != player_localentnum)
				Impact_PlayBreakableBreakSound(bk_pos, bk_style);
			break;
		}
		case CSQC_EVENT_FOOTSTEP_SOUND:
		{
			// Stepper's CSQC already played this via localsound in
			// PM_EmitStepSound on the non-replay prediction tick. Remote
			// clients receive it here via the normal PVS multicast path.
			float fs_exclude = readbyte();
			float fs_vol     = readbyte() / 255;
			string fs_snd    = readstring();
			vector fs_pos;
			fs_pos_x = readcoord();
			fs_pos_y = readcoord();
			fs_pos_z = readcoord();

			float fs_is_own_echo = (fs_exclude != 0 && fs_exclude == player_localentnum);

			if (cvar("cl_debug_footsteps"))
			{
				float fs_dt = cl_last_recv_step_time > 0 ? (time - cl_last_recv_step_time) : 0;
				if (fs_is_own_echo)
					print(sprintf("^3[step-recv-skip]^7 t=%.3f dt=%.3f exclude=%g me=%g snd=%s (own echo dropped)\n",
					              time, fs_dt, fs_exclude, player_localentnum, fs_snd));
				else
					print(sprintf("^2[step-recv-play]^7 t=%.3f dt=%.3f exclude=%g me=%g snd=%s vol=%.2f\n",
					              time, fs_dt, fs_exclude, player_localentnum, fs_snd, fs_vol));
				cl_last_recv_step_time = time;
			}

			if (!fs_is_own_echo)
				pointsound(fs_pos, fs_snd, fs_vol, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_BRUSH_DESTROY:
		{
			// Server-side func_breakable was destroyed.  Hide the replicated
			// CSQC brush immediately (drawmask + solid) and drop its
			// bullet-hole decals.  Keep the model loaded — the next
			// SendEntity snapshot carries broken=1 and on round restart
			// flips to 0, so drawmask/solid snap back on with no setmodel
			// round-trip needed.  Do NOT remove() — PVSF_NOREMOVE and the
			// server-entnum→CSQC-slot link must survive the break/reset
			// cycle.
			float sv_entnum = readfloat();
			entity ent = findfloat(world, entnum, sv_entnum);
			if (ent)
			{
				CSQC_BulletHolesRemoveByOwner(ent);

				// Catch-up path for client-miss / server-hit. The break-
				// sound and gib events are attacker-excluded, so if the
				// attacker's local trace missed (but the server's lag-
				// compensated trace connected), they'd otherwise see the
				// brush vanish silently. Fire the missing feedback here
				// using the replicated brush fields. Skip when our own
				// prediction already handled it — otherwise correctly-
				// predicted breaks double up with a ping-delayed echo.
				if (!ent.brush_broken_predicted)
				{
					if (cvar("developer"))
						print(sprintf("^3[break-catchup]^7 brush ^2#%g^7 style=%g — server broke it, no local prediction, firing delayed fx\n",
						              sv_entnum, ent.brush_material));

					vector cd_center = (ent.absmin + ent.absmax) * 0.5;
					Impact_PlayBreakableBreakSound(cd_center, ent.brush_material);

					float cd_ds = max(ent.brush_max_health, 20);
					if (ent.brush_material == 4 /*BREAKABLE_GLASS*/)
						CSQC_SpawnGlassGibs(ent.absmin, ent.absmax,
						                    ent.brush_cnt, cd_ds, 0);
					else
						CSQC_SpawnDebrisGibs(ent.absmin, ent.absmax,
						                     ent.brush_material, ent.brush_cnt,
						                     cd_ds, 0, 0, 0);
				}
				else if (cvar("developer"))
				{
					print(sprintf("^2[break-confirm]^7 brush ^2#%g^7 style=%g — server confirmed prediction\n",
					              sv_entnum, ent.brush_material));
				}

				// Server-confirmed truth. brush_broken_confirmed short-
				// circuits the prediction-timeout rollback in
				// CSQC_BreakPredict_Expire so a legitimate slow
				// confirmation doesn't get un-hidden.
				ent.brush_broken_confirmed = 1;

				ent.drawmask = 0;
				ent.solid    = SOLID_NOT;
			}
			break;
		}
		case CSQC_EVENT_HITMARKER:
		{
			// Server-confirmed hit — debounce to avoid double-play if client already triggered
			if (cvar("cl_hitmarker") && (cltime - csqc_hitmarker_time > 0.2))
			{
				localsound("sounds/weapons/hitmarker.wav");
				HUD_TriggerHitmarker();
			}
			break;
		}
		case CSQC_EVENT_SERVER_HITBOXES:
		{
			float hb_entnum = readbyte();
			float sv_mdlidx = readshort();
			vector sv_org;
			sv_org_x = readcoord();
			sv_org_y = readcoord();
			sv_org_z = readcoord();
			vector sv_ang;
			sv_ang_x = readfloat();
			sv_ang_y = readfloat();
			sv_ang_z = readfloat();
			float sv_fr = readbyte();
			float sv_bfr = readbyte();
			float sv_bb = readbyte();
			float sv_f1t = readfloat();
			float sv_bf1t = readfloat();
			float sv_sbf = readfloat();
			float sv_sb2f = readfloat();
			float sv_bc1 = readfloat();
			float sv_bc2 = readfloat();
			float sv_bc3 = readfloat();
			float sv_bc4 = readfloat();
			float sv_show_shield = readbyte();
			if (sv_show_shield >= 3)
				CSQC_UpdateContinuousHitbox(hb_entnum, sv_mdlidx, sv_org, sv_ang, sv_fr, sv_bfr, sv_bb, sv_f1t, sv_bf1t, sv_sbf, sv_sb2f, sv_bc1, sv_bc2, sv_bc3, sv_bc4);
			else
				CSQC_AddServerHitbox(sv_mdlidx, sv_org, sv_ang, sv_fr, sv_bfr, sv_bb, sv_show_shield, sv_sbf, sv_sb2f, sv_bc1, sv_bc2, sv_bc3, sv_bc4);
			break;
		}
		default:
			printf("No action for byte %f\n", first);
			break;
	}
};


float(string key, string val) find_player_id =
{
	for (int currentindex = 0; currentindex < maxclients; currentindex++)
	{
		if (getplayerkeyvalue(currentindex, key) == val) return currentindex;
	}
	return -1;
}

void(string printmsg, float printlvl) CSQC_Parse_Print =
{
	print(printmsg);
};
