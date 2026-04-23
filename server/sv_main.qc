//
//	Main.qc - mostly functions that will be called from the engine and are expected to exist
//

// Forward declarations
void() BreakableResetAll;
void() PhysProp_RunPlayerPush;

void() main =
{
};

// ============================================================
//  Round lifecycle helpers
// ============================================================

void() PlayerSpawn;  // forward declaration (defined in sv_player.qc)

void() RoundStart =
{
	float freezetime = cvar("mp_freezetime");

	round_winning_team = 0;

	if (freezetime > 0)
	{
		round_phase = ROUND_PHASE_FREEZE;
		freeze_end_time = time + freezetime;
	}
	else
	{
		round_phase = ROUND_PHASE_ACTIVE;
		round_end_time = time + cvar("mp_roundtime") * 60;
	}
};

void() RoundRestart =
{
	entity e, saved, next;

	round_number = round_number + 1;
	round_winning_team = 0;

	// Remove dropped weapons + respawn map-placed weapons at their original positions
	W_RespawnMapWeapons();

	// Restore all broken breakables
	BreakableResetAll();

	// Tell all clients to wipe bullet holes, shells, mags
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ROUND_CLEANUP);
	multicast('0 0 0', MULTICAST_ALL);

	// Respawn all players who have a playing team (not spectators)
	e = player_chain_head;
	while (e)
	{
		if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
		{
			// Latch survival BEFORE clearing is_dead so PlayerSpawn can
			// decide whether to preserve the player's inventory.
			e.survived_round = !e.is_dead;
			e.is_dead = FALSE;
			e.death_time = 0;
			PlayerRefreshScoreboardInfo(e);  // clear 'dead' flag on scoreboard
			saved = self;
			self = e;
			PlayerSpawn();
			self = saved;
		}
		e = e.player_chain_next;
	}

	RoundStart();
};

// Returns winning team, or 0 if no elimination occurred.
// Only meaningful during ROUND_PHASE_ACTIVE in elimination mode.
float() CheckTeamEliminated =
{
	entity e;
	float blue_total, red_total, blue_alive, red_alive;

	blue_total = 0; red_total = 0;
	blue_alive = 0; red_alive = 0;

	e = player_chain_head;
	while (e)
	{
		if (e.player_team == TEAM_BLUE)
		{
			blue_total = blue_total + 1;
			if (!e.is_dead)
				blue_alive = blue_alive + 1;
		}
		else if (e.player_team == TEAM_RED)
		{
			red_total = red_total + 1;
			if (!e.is_dead)
				red_alive = red_alive + 1;
		}
		e = e.player_chain_next;
	}

	// Need both teams to have players for elimination to trigger
	if (blue_total == 0 || red_total == 0)
		return 0;

	if (blue_alive == 0 && red_alive > 0)
		return TEAM_RED;
	if (red_alive == 0 && blue_alive > 0)
		return TEAM_BLUE;
	if (blue_alive == 0 && red_alive == 0)
		return -1;  // mutual elimination (draw)

	return 0;  // both teams still have alive players
};

float() MapTimeExpired =
{
	float map_remaining;
	map_remaining = (cvar("mp_timelimit") * 60) - (time - map_start_time);
	return map_remaining <= 0;
};

// ============================================================
//  StartFrame — round phase state machine
// ============================================================

// Cached last-pushed serverinfo values so we only emit when a cvar changes.
// CSQC prediction reads these via serverkeyfloat — if they don't update live,
// the client uses a stale value (or the default).
string sv_info_last_shiftspeed;
string sv_info_last_maxspeed;
string sv_info_last_accelerate;
string sv_info_last_airaccelerate;
string sv_info_last_friction;
string sv_info_last_gravity;
string sv_info_last_stopspeed;
string sv_info_last_hull_height;
string sv_info_last_eye_height;
string sv_info_last_autohop;
string sv_info_last_stamina;
string sv_info_last_snipersway;
string sv_info_last_mp_cheats;
string sv_info_last_mintic;

void(string key, __inout string last) sv_info_push_if_changed =
{
	string cur = cvar_string(key);
	if (cur != last)
	{
		localcmd(sprintf("serverinfo %s \"%s\"\n", key, cur));
		last = cur;
	}
};

void() SV_UpdateMovementServerInfo =
{
	sv_info_push_if_changed("sv_shiftspeed",    sv_info_last_shiftspeed);
	sv_info_push_if_changed("sv_maxspeed",      sv_info_last_maxspeed);
	sv_info_push_if_changed("sv_accelerate",    sv_info_last_accelerate);
	sv_info_push_if_changed("sv_airaccelerate", sv_info_last_airaccelerate);
	sv_info_push_if_changed("sv_friction",      sv_info_last_friction);
	sv_info_push_if_changed("sv_gravity",       sv_info_last_gravity);
	sv_info_push_if_changed("sv_stopspeed",     sv_info_last_stopspeed);
	sv_info_push_if_changed("sv_hull_height",   sv_info_last_hull_height);
	sv_info_push_if_changed("sv_eye_height",    sv_info_last_eye_height);
	sv_info_push_if_changed("sv_autohop",       sv_info_last_autohop);
	sv_info_push_if_changed("sv_stamina",       sv_info_last_stamina);
	sv_info_push_if_changed("sv_snipersway",    sv_info_last_snipersway);
	sv_info_push_if_changed("mp_cheats",        sv_info_last_mp_cheats);
	// Publish the server's authoritative tick interval (seconds per
	// server frame) so CSQC debug panels can read the exact configured
	// value rather than measuring it empirically from snapshot-arrival
	// jitter.  Use sv_mintic as the source of truth — sv_maxtic ≥
	// sv_mintic always, and in a properly configured server both are
	// identical.  Pushes only on change, so zero overhead steady-state.
	sv_info_push_if_changed("sv_mintic",        sv_info_last_mintic);
};

// Post-exec fixup: if data/server.cfg (now processed, since localcmd is
// queued) wrote empty strings for cvars that need real defaults, restore
// them here.  Mirrors Menu_FixupEmptyDefaults but runs server-side for
// dedicated servers where the menu VM never loads.  Runs once.
float sv_cfg_fixed_up;
void() SV_FixupEmptyDefaults =
{
	if (sv_cfg_fixed_up)
		return;
	sv_cfg_fixed_up = TRUE;

	if (cvar_string("sv_lagcomp")           == "") cvar_set("sv_lagcomp",           "1");
	if (cvar_string("sv_lagcomp_maxrewind") == "") cvar_set("sv_lagcomp_maxrewind", "0.5");
	if (cvar_string("sv_debug_lagcomp")     == "") cvar_set("sv_debug_lagcomp",     "0");
	if (cvar_string("sv_hitbox_expand")     == "") cvar_set("sv_hitbox_expand",     "32");
	if (cvar_string("sv_anim_qu_per_sec")   == "") cvar_set("sv_anim_qu_per_sec",   "240");
	if (cvar_string("sv_player_basebone")   == "") cvar_set("sv_player_basebone",   "0");
	if (cvar_string("sv_antilag")           == "") cvar_set("sv_antilag",           "3");
	if (cvar_string("sv_bigcoords")         == "") cvar_set("sv_bigcoords",         "1");
	if (cvar_string("sv_nqplayerphysics")   == "") cvar_set("sv_nqplayerphysics",   "0");
	if (cvar_string("sv_wateraccelerate")   == "") cvar_set("sv_wateraccelerate",   "10");
	if (cvar_string("sv_waterfriction")     == "") cvar_set("sv_waterfriction",     "1");
	if (cvar_string("pm_ramp_bumpcount")    == "") cvar_set("pm_ramp_bumpcount",    "8");
	if (cvar_string("sv_shiftspeed")        == "") cvar_set("sv_shiftspeed",        "135");
	if (cvar_string("sv_maxspeed")          == "") cvar_set("sv_maxspeed",          "270");
	if (cvar_string("sv_accelerate")        == "") cvar_set("sv_accelerate",        "5");
	if (cvar_string("sv_airaccelerate")     == "") cvar_set("sv_airaccelerate",     "150");
	if (cvar_string("sv_friction")          == "") cvar_set("sv_friction",          "4");
	if (cvar_string("sv_gravity")           == "") cvar_set("sv_gravity",           "800");
	if (cvar_string("sv_stopspeed")         == "") cvar_set("sv_stopspeed",         "100");
	if (cvar_string("sv_hull_height")       == "") cvar_set("sv_hull_height",       "72");
	if (cvar_string("sv_eye_height")        == "") cvar_set("sv_eye_height",        "56");
	if (cvar_string("sv_autohop")           == "") cvar_set("sv_autohop",           "0");
	if (cvar_string("sv_stamina")           == "") cvar_set("sv_stamina",           "0");
	if (cvar_string("sv_snipersway")        == "") cvar_set("sv_snipersway",        "0");
	if (cvar_string("mp_roundtime")         == "") cvar_set("mp_roundtime",         "5");
	if (cvar_string("mp_timelimit")         == "") cvar_set("mp_timelimit",         "25");
	if (cvar_string("mp_maxrounds")         == "") cvar_set("mp_maxrounds",         "12");
	if (cvar_string("mp_freezetime")        == "") cvar_set("mp_freezetime",        "3");
	if (cvar_string("mp_roundrestartdelay") == "") cvar_set("mp_roundrestartdelay", "5");
	if (cvar_string("mp_respawndelay")      == "") cvar_set("mp_respawndelay",      "3");
	if (cvar_string("mp_friendlyfire")      == "") cvar_set("mp_friendlyfire",      "0");
	if (cvar_string("mp_falldamage")        == "") cvar_set("mp_falldamage",        "1");
	if (cvar_string("mp_noblock")           == "") cvar_set("mp_noblock",           "0");
	if (cvar_string("mp_cheats")            == "") cvar_set("mp_cheats",            "0");
	if (cvar_string("sv_gamemode")          == "") cvar_set("sv_gamemode",          "0");
	if (cvar_string("sv_default_primary")   == "") cvar_set("sv_default_primary",   "0");
	if (cvar_string("sv_default_secondary") == "") cvar_set("sv_default_secondary", "28");
	if (cvar_string("sv_default_melee")     == "") cvar_set("sv_default_melee",     "20");
	if (cvar_string("sv_default_utility")   == "") cvar_set("sv_default_utility",   "0");
};

void() StartFrame =
{
	entity e, saved;
	float remaining, map_remaining, max_rounds, gamemode;
	float winner;

	// One-shot ODE attach.  `localcmd("plug_load ode")` queued in worldspawn
	// has fully processed by the first StartFrame tick, so the engine's
	// world_current_physics_engine pointer is now set.  physics_supported(TRUE)
	// invokes World_RBE_Start which uses that pointer to attach ODE to this
	// world — without this deferred call, world->rbe stays NULL and every
	// MOVETYPE_PHYSICS entity is inert (no gravity, no reaction to forces).
	// Guarded by sv_ode_loaded so it only runs once.
	if (cvar("sv_ode_loaded") == 0)
	{
		if (physics_supported(TRUE))
		{
			cvar_set("sv_ode_loaded", "1");
			// Soften ODE contact constraints so the LCP solver doesn't go singular.
			localcmd("physics_ode_contact_cfm 0.0001\n");
		}
		else
		{
			cvar_set("sv_ode_loaded", "-1");
		}
	}

	SV_FixupEmptyDefaults();

	gamemode = cvar("sv_gamemode");

	SV_UpdateMovementServerInfo();

	// Resolve any "camera .target" strings on the first tick (after all
	// info_null entities have spawned) and rotate the active team-select
	// camera when >CAMERA_CYCLE_SECONDS have elapsed.
	Camera_EnsureTargetsResolved();
	Camera_UpdateCyclingSpectators();

	PhysProp_RunPlayerPush();

	// Synthesize missed input ticks for low-cl_netfps players so other
	// clients see them move smoothly instead of freeze-then-jump.
	SV_RunCommandContinuation();

	// Admin trigger: "sv_roundrestart 1" in the server console queues a
	// round restart after mp_roundrestartdelay seconds. Resets itself to 0.
	// SSQC has no registercommand, so this cvar-toggle pattern is the
	// standard way to expose an admin-only server action.
	if (cvar("sv_roundrestart"))
	{
		cvar_set("sv_roundrestart", "0");
		float delay = cvar("mp_roundrestartdelay");
		if (delay <= 0) delay = 3;
		round_phase = ROUND_PHASE_ROUND_END;
		round_restart_time = time + delay;
		bprint(PRINT_HIGH, sprintf("Round restarting in %g seconds...\n", delay));
	}

	// --- Phase transitions ---
	if (round_phase == ROUND_PHASE_FREEZE)
	{
		if (time >= freeze_end_time)
		{
			// Freeze ended — start the round
			round_phase = ROUND_PHASE_ACTIVE;
			round_end_time = time + cvar("mp_roundtime") * 60;
		}
	}
	else if (round_phase == ROUND_PHASE_ACTIVE)
	{
		// Check round timer expiry
		if (time >= round_end_time)
		{
			round_winning_team = 0;
			round_phase = ROUND_PHASE_ROUND_END;
			round_restart_time = time + cvar("mp_roundrestartdelay");
		}
		// Check team elimination (elimination mode only)
		else if (gamemode == GAMEMODE_ELIMINATION)
		{
			winner = CheckTeamEliminated();
			if (winner != 0)
			{
				if (winner == -1)
					round_winning_team = 0;  // mutual elimination = draw
				else
				{
					round_winning_team = winner;
					if (winner == TEAM_BLUE)
						blue_team_score += 1;
					else if (winner == TEAM_RED)
						red_team_score += 1;
				}

				round_phase = ROUND_PHASE_ROUND_END;
				round_restart_time = time + cvar("mp_roundrestartdelay");
			}
			else
			{
				// All players dead (solo player or everyone wiped) — restart
				float any_alive = FALSE;
				entity check = player_chain_head;
				while (check)
				{
					if (check.player_team != TEAM_NONE && !check.is_dead)
					{
						any_alive = TRUE;
						break;
					}
					check = check.player_chain_next;
				}
				if (!any_alive && player_chain_head)
				{
					round_winning_team = 0;
					round_phase = ROUND_PHASE_ROUND_END;
					round_restart_time = time + cvar("mp_roundrestartdelay");
				}
			}
		}
	}
	else if (round_phase == ROUND_PHASE_ROUND_END)
	{
		if (time >= round_restart_time)
		{
			// Check if map should end
			if (MapTimeExpired() || round_number >= cvar("mp_maxrounds"))
			{
				round_phase = ROUND_PHASE_MAP_END;
				map_restart_time = time + cvar("mp_maprestartdelay");
			}
			else
			{
				RoundRestart();
			}
		}
	}
	else if (round_phase == ROUND_PHASE_MAP_END)
	{
		if (time >= map_restart_time)
		{
			localcmd(sprintf("changelevel %s\n", serverkey("mapname")));
		}
	}

	// --- Push stats to all players every frame ---
	if (round_phase == ROUND_PHASE_ACTIVE)
		remaining = max(0, round_end_time - time);
	else if (round_phase == ROUND_PHASE_ROUND_END)
		remaining = max(0, round_restart_time - time);
	else if (round_phase == ROUND_PHASE_MAP_END)
		remaining = max(0, map_restart_time - time);
	else
		remaining = 0;

	map_remaining = max(0, (cvar("mp_timelimit") * 60) - (time - map_start_time));
	max_rounds = cvar("mp_maxrounds");

	float deathdelay = cvar("mp_respawndelay");

	e = player_chain_head;
	while (e)
	{
		// Death delay processing
		if (e.is_dead && e.death_time > 0)
		{
			float elapsed = time - e.death_time;
			if (elapsed < deathdelay)
			{
				e.sv_death_delay_left = deathdelay - elapsed;
			}
			else
			{
				e.sv_death_delay_left = 0;
				if (gamemode == GAMEMODE_TDM)
				{
					// Auto-respawn after delay
					e.is_dead = FALSE;
					e.death_time = 0;
					PlayerRefreshScoreboardInfo(e);
					saved = self;
					self = e;
					PlayerSpawn();
					self = saved;
				}
				else
				{
					// Elimination: hide body, enter spectator phase
					e.modelindex = 0;
					e.death_time = -1;  // prevent re-triggering
				}
			}
		}
		else
		{
			e.sv_death_delay_left = 0;
		}
		e.sv_is_dead = e.is_dead;

		e.round_timer_remaining = remaining;
		e.sv_maptimeleft = map_remaining;
		e.sv_roundnum = round_number;
		e.sv_maxrounds = max_rounds;
		e.sv_round_phase = round_phase;
		e.sv_freeze_timeleft = (round_phase == ROUND_PHASE_FREEZE) ? max(0, freeze_end_time - time) : 0;
		e.sv_gamemode = gamemode;
		e.sv_winning_team = round_winning_team;
		e.sv_blue_score = blue_team_score;
		e.sv_red_score = red_team_score;
		e = e.player_chain_next;
	}

	// Append the current pose of every alive player to the lag-comp ring.
	// Runs once per tick, immediately after the per-player loop above — the
	// skeletal fields from the previous tick's PlayerPostThink are settled
	// at this point.
	Lagcomp_RecordAllAlive();

	// sv_debug_hitboxes 3: continuously send all player hitbox states
	if (cvar("sv_debug_hitboxes") >= 3)
	{
		e = player_chain_head;
		while (e)
		{
			if (e.classname == "player" && !e.is_dead && e.modelindex)
			{
				vector center = e.origin;
				WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
				WriteByte(MSG_MULTICAST, CSQC_EVENT_SERVER_HITBOXES);
				WriteByte(MSG_MULTICAST, num_for_edict(e));
				WriteShort(MSG_MULTICAST, e.modelindex);
				WriteCoord(MSG_MULTICAST, e.origin_x);
				WriteCoord(MSG_MULTICAST, e.origin_y);
				WriteCoord(MSG_MULTICAST, e.origin_z);
				WriteFloat(MSG_MULTICAST, e.angles_x);
				WriteFloat(MSG_MULTICAST, e.angles_y);
				WriteFloat(MSG_MULTICAST, e.angles_z);
				WriteByte(MSG_MULTICAST, e.frame);
				WriteByte(MSG_MULTICAST, e.baseframe);
				WriteByte(MSG_MULTICAST, e.basebone);
				WriteFloat(MSG_MULTICAST, e.frame1time);
				WriteFloat(MSG_MULTICAST, e.baseframe1time);
				WriteFloat(MSG_MULTICAST, e.subblendfrac);
				WriteFloat(MSG_MULTICAST, e.subblend2frac);
				WriteFloat(MSG_MULTICAST, e.bonecontrol1);
				WriteFloat(MSG_MULTICAST, e.bonecontrol2);
				WriteFloat(MSG_MULTICAST, e.bonecontrol3);
				WriteFloat(MSG_MULTICAST, e.bonecontrol4);
				WriteByte(MSG_MULTICAST, 3);
				multicast(center, MULTICAST_PVS);
			}
			e = e.player_chain_next;
		}
	}
};

void() worldspawn =
{
	// Load the ODE physics plugin before precache_everything() so that
	// phys_barrel_precache()'s physics_supported(TRUE) call sees it.
	// data/default.cfg used to handle this, but that file is client-only
	// now, so dedicated servers rely on this localcmd instead.
	// plug_load is idempotent — loading a plugin already loaded is a no-op.
	localcmd("plug_load ode\n");

	precache_everything();

	Lagcomp_Init();

	clientstat(STAT_CROSSHAIR_BASESPREAD, EV_FLOAT,   sv_crosshair_basespread);
	clientstat(STAT_CROSSHAIR_MOVESPREAD, EV_FLOAT,   sv_crosshair_movespread);
	clientstat(STAT_CROSSHAIR_FULLSPEED,  EV_FLOAT,   sv_crosshair_fullspeed);
	clientstat(STAT_CROSSHAIR_GAPSCALE,   EV_FLOAT,   sv_crosshair_gapscale);
	clientstat(STAT_CROSSHAIR_DISABLED,         EV_INTEGER,  sv_crosshair_disabled);

	clientstat(STAT_PLAYERTEAM, EV_FLOAT, player_team);
	clientstat(STAT_TEAMMENU_REQUEST, EV_FLOAT, team_menu_request_serial);
	clientstat(STAT_ROUNDTIMER, EV_FLOAT, round_timer_remaining);
	clientstat(STAT_MAPTIMELEFT, EV_FLOAT, sv_maptimeleft);
	clientstat(STAT_ROUNDNUM, EV_FLOAT, sv_roundnum);
	clientstat(STAT_MAXROUNDS, EV_FLOAT, sv_maxrounds);
	clientstat(STAT_ROUND_PHASE, EV_FLOAT, sv_round_phase);
	clientstat(STAT_FREEZE_TIMELEFT, EV_FLOAT, sv_freeze_timeleft);
	clientstat(STAT_GAMEMODE, EV_FLOAT, sv_gamemode);
	clientstat(STAT_WINNING_TEAM, EV_FLOAT, sv_winning_team);
	clientstat(STAT_DEATH_DELAY_LEFT, EV_FLOAT, sv_death_delay_left);
	clientstat(STAT_IS_DEAD, EV_FLOAT, sv_is_dead);
	clientstat(STAT_ZOOMSTAGE, EV_FLOAT, sv_zoomstage);
	clientstat(STAT_BLUE_SCORE, EV_FLOAT, sv_blue_score);
	clientstat(STAT_RED_SCORE, EV_FLOAT, sv_red_score);

	// Register ALL server cvars with their defaults FIRST, then exec
	// data/server.cfg to apply any persisted overrides.  If exec ran before
	// register, `set sv_X` lines in the cfg would auto-create cvars and
	// print "Created QC Cvar" warnings.
	registercvar("sv_gamemode", "0");
	registercvar("mp_roundtime", "5");
	registercvar("mp_timelimit", "25");
	registercvar("mp_maxrounds", "12");
	registercvar("mp_freezetime", "3");
	registercvar("mp_roundrestartdelay", "5");
	registercvar("mp_maprestartdelay", "10");
	registercvar("mp_respawndelay", "3");
	registercvar("mp_respawn", "1");
	registercvar("sv_debug_weapons", "0");
	registercvar("mp_cheats", "0");
	registercvar("sv_debug_physprops", "0");
	registercvar("sv_hitbox_expand", "8");
	registercvar("mp_noblock", "0");
	registercvar("mp_falldamage", "1");
	registercvar("mp_friendlyfire", "0");
	registercvar("sv_roundrestart", "0");

	// Netcode — replays a player's last input when no fresh command
	// arrives this tick, so low-cl_netfps players don't freeze in
	// snapshots sent to other clients (see PlayerPreThink in sv_player.qc).
	registercvar("sv_command_continuation", "1");
	registercvar("sv_debug_continuation",   "0");

	// Client-sided hit registration. 0=server-auth only (lagcomp trace
	// decides), 1=soft trust (accept client's claim with sanity caps),
	// 2=full trust (accept as-is, minimal dedup only). See
	// SV_HandleHitclaim in sv_player.qc.
	registercvar("sv_trust_clienthits",  "0");
	registercvar("sv_debug_clienthits",  "0");

	// How often (in server ticks) the pose keepalive resends a
	// stationary player's pose. 1 = every tick (safest for interp).
	// Raise to save bandwidth at the cost of looser interp bracket.
	registercvar("sv_pose_keepalive_ticks", "1");

	// Movement physics — mirrors pmove defaults so these no longer spam
	// "Created QC Cvar" on first read.
	registercvar("sv_autohop",         "0");
	registercvar("sv_stamina",         "1");
	registercvar("sv_snipersway",      "0");
	registercvar("sv_shiftspeed",      "135");
	registercvar("sv_maxspeed",        "270");
	registercvar("sv_accelerate",      "5");
	registercvar("sv_airaccelerate",   "150");
	registercvar("sv_friction",        "4");
	registercvar("sv_gravity",         "800");
	registercvar("sv_stopspeed",       "100");
	registercvar("sv_hull_height",     "72");
	registercvar("sv_eye_height",      "56");
	registercvar("pm_ramp_bumpcount",  "8");

	// FTE engine pre-registers sv_accelerate with "10" (see fteqw/engine/
	// server/sv_phys.c), which overrides our registercvar above. Force-set
	// the mod's intended default; data/server.cfg execs immediately after
	// this block so admins who want a different value still get their
	// override applied. Same reason for force-setting sv_stamina (not
	// engine-pre-registered, but upgrading installs may have 0 cached in
	// config.cfg from the previous default — we want the new default to
	// take effect).
	cvar_set("sv_accelerate",    "5");
	cvar_set("sv_airaccelerate", "150");
	cvar_set("sv_maxspeed",      "270");
	cvar_set("sv_eye_height",    "56");
	cvar_set("sv_stamina",       "1");

	// Tickrate default — 64 Hz (CS-standard). FTE's engine baseline is
	// 60 Hz and older install configs may have 100 Hz cached from
	// prior defaults. data/server.cfg execs immediately after this
	// block so admins can still override.
	cvar_set("sv_mintic",        "0.015625");
	cvar_set("sv_maxtic",        "0.015625");

	// Animation tuning + debug
	registercvar("sv_anim_qu_per_sec", "240");
	registercvar("sv_player_basebone", "0");
	registercvar("sv_debug_blendfracs","0");
	registercvar("sv_debug_hitboxes",  "0");
	registercvar("sv_debug_camera",    "0");
	registercvar("sv_debug_ent_types", "0");
	registercvar("sv_debug_spawns",    "0");

	// Lag compensation pose history (see server/sv_lagcomp.qc)
	registercvar("sv_lagcomp",           "1");
	registercvar("sv_lagcomp_maxrewind", "0.5");
	registercvar("sv_debug_lagcomp",     "0");
	registercvar("sv_ode_loaded",        "0");

	// Overkill gib threshold — killing blows >= this many damage spawn
	// flesh gibs + blood instead of leaving a corpse. 0 disables.
	registercvar("sv_gib_threshold",     "70");

	// Default starting loadout — WEP_* integer per slot.  Read by PlayerSpawn
	// when the player didn't survive the previous round (survivors keep their
	// inventory via .survived_round).  Defaults match the previously
	// hardcoded values so existing installs see no behaviour change.
	registercvar("sv_default_primary",   "0");   // WEP_NONE
	registercvar("sv_default_secondary", "28");  // WEP_CSUSP
	registercvar("sv_default_melee",     "20");  // WEP_WRENCH
	registercvar("sv_default_utility",   "0");   // WEP_NONE (no utility slot)

	// Now apply persisted overrides from data/server.cfg.
	localcmd("exec data/server.cfg\n");

	// Bhop gamemode — force bhop-specific settings before entities spawn.
	// Door/button inertness is read directly from sv_gamemode in
	// sv_doors.qc func_button / func_door, so no separate flag cvar needed.
	if (cvar("sv_gamemode") == GAMEMODE_BHOP)
	{
		cvar_set("mp_falldamage", "0");
		cvar_set("mp_noblock", "1");
	}

	// Force mapname serverinfo to the current map (engine may cache a stale value)
	localcmd(sprintf("serverinfo mapname \"%s\"\n", mapname));

	// NOTE: we previously pushed movement cvars to serverinfo here, but that
	// ran with stale pre-exec defaults (since exec is queued).  The real push
	// is done by SV_UpdateMovementServerInfo() each StartFrame with live
	// values, which correctly reflects whatever data/server.cfg set.

	map_start_time = time;
	round_number = 1;
	round_phase = ROUND_PHASE_NONE;
	blue_team_score = 0;
	red_team_score = 0;
};

void() SpectatorConnect =
{	
};

