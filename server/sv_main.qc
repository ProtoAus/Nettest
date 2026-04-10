//
//	Main.qc - mostly functions that will be called from the engine and are expected to exist
//

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

	// Remove all loose weapon entities (dropped weapons, debug spawns)
	// Weapons have .weapon_slot set and .touch = weapon_touch
	e = nextent(world);
	while (e)
	{
		next = nextent(e);
		if (e.classname != "player"
			&& e.classname != "pm_csqc_proxy"
			&& e.weapon
			&& e.weapon != WEP_NONE)
		{
			remove(e);
		}
		e = next;
	}

	// Tell all clients to wipe bullet holes, shells, mags
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ROUND_CLEANUP);
	multicast('0 0 0', MULTICAST_ALL);

	// Respawn all players who have a team
	e = player_chain_head;
	while (e)
	{
		if (e.player_team != TEAM_NONE)
		{
			e.is_dead = FALSE;
			e.death_time = 0;
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

void() StartFrame =
{
	entity e, saved;
	float remaining, map_remaining, max_rounds, gamemode;
	float winner;

	gamemode = cvar("sv_gamemode");

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
					round_winning_team = winner;

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

	float deathdelay = cvar("mp_deathdelay");

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
		e = e.player_chain_next;
	}
};

void() worldspawn =
{
	precache_everything();

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

	registercvar("sv_gamemode", "0");
	registercvar("mp_roundtime", "5");
	registercvar("mp_timelimit", "25");
	registercvar("mp_maxrounds", "12");
	registercvar("mp_freezetime", "3");
	registercvar("mp_roundrestartdelay", "5");
	registercvar("mp_maprestartdelay", "10");
	registercvar("mp_deathdelay", "3");
	registercvar("mp_respawn", "1");

	map_start_time = time;
	round_number = 1;
	round_phase = ROUND_PHASE_NONE;
};

void() SpectatorConnect =
{	
};

