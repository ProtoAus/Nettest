//
//	Main.qc - mostly functions that will be called from the engine and are expected to exist
//

// Forward declarations
void() BreakableResetAll;

void() main =
{
};

// ============================================================
//  Round lifecycle helpers
// ============================================================

void() PlayerSpawn;  // forward declaration (defined in sv_player.qc)

// Keep in sync with menu/m_menu.qc server_config_cvars[] so the
// in-game save path writes the same data/server.cfg shape as Create
// Server / menu-side saves.
string sv_servercfg_cvars[] =
{
	"hostname",
	"maxclients",
	"password",
	"rcon_password",
	"sv_pure",
	"fraglimit",
	"mp_roundtime",
	"mp_timelimit",
	"mp_maxrounds",
	"mp_friendlyfire",
	"mp_falldamage",
	"mp_nomapweapons",
	"mp_freezetime",
	"mp_roundrestartdelay",
	"mp_respawndelay",
	"sv_autohop",
	"sv_stamina",
	"sv_gamemode",
	"sv_maxvelocity",
	"sv_hull_height",
	"sv_eye_height",
	"sv_maxspeed",
	"sv_accelerate",
	"sv_airaccelerate",
	"sv_friction",
	"sv_shiftspeed",
	"sv_mintic",
	"sv_maxtic",
	"sv_minpitch",
	"sv_maxpitch",
	"mp_cheats",
	"sv_cheats",
	"mp_noblock",
	"sv_trust_clienthits",
	"sv_lagcomp",
	"sv_lagcomp_maxrewind",
	"sv_hitbox_expand",
	"sv_anim_qu_per_sec",
	"sv_anim_qu_per_sec_crouch",
	"sv_player_basebone",
	"sv_antilag",
	"sv_bigcoords",
	"sv_nqplayerphysics",
	"sv_wateraccelerate",
	"sv_waterfriction",
	"sv_toss_tickrate",
	"sv_roundtoss_tickrate",
	"pm_ramp_bumpcount",
	"sv_phys_drops",
	"sv_physprop_hit_force",
	"sv_physprop_mass",
	"sv_physprop_erp",
	"sv_physprop_damp_lin",
	"sv_physprop_damp_ang",
	"sv_physprop_friction",
	"sv_physprop_use_force",
	"sv_physprop_use_velmult",
	"physics_ode_iterationsperframe",
	"physics_ode_worldquickstep",
	"physics_ode_autodisable",
	"sv_default_primary",
	"sv_default_secondary",
	"sv_default_melee",
	"sv_default_utility",
};

string(string line) SV_MapListEntryFromLine =
{
	float argc = tokenize(line);
	if (argc <= 0)
		return "";

	string token = argv(0);
	if (token == "//" || substring(token, 0, 1) == "#")
		return "";

	string lower = strtolower(token);
	float len = strlen(token);

	if (len > 5 && substring(lower, 0, 5) == "maps/")
	{
		token = substring(token, 5, len - 5);
		lower = strtolower(token);
		len = strlen(token);
	}

	if (len > 4 && substring(lower, len - 4, 4) == ".bsp")
		token = substring(token, 0, len - 4);

	return token;
};

string() SV_NextMapFromCycleFile =
{
	filestream f = fopen("data/maps.txt", FILE_READ);
	if (f < 0)
		return "";

	string first = "";
	string current = strtolower(mapname);
	float found_current = FALSE;

	string line = fgets(f);
	while (line)
	{
		string entry = SV_MapListEntryFromLine(line);
		if (entry != "")
		{
			string entry_lower = strtolower(entry);

			if (first == "")
				first = entry;

			if (found_current)
			{
				fclose(f);
				return entry;
			}

			if (entry_lower == current)
				found_current = TRUE;
		}

		line = fgets(f);
	}

	fclose(f);
	return first;
};

string(string cfgpath, string target_name) SV_ReadConfigValue =
{
	filestream f = fopen(cfgpath, FILE_READ);
	if (f < 0)
		return "";

	string found = "";
	string line = fgets(f);
	while (line)
	{
		float n = strlen(line);
		if (n > 0 && substring(line, n - 1, 1) == "\r")
			line = substring(line, 0, n - 1);

		float argc = tokenize(line);
		if (argc <= 0)
		{
			line = fgets(f);
			continue;
		}

		string cmd = argv(0);
		if (cmd == "//" || substring(cmd, 0, 1) == "#")
		{
			line = fgets(f);
			continue;
		}

		if ((cmd == "set" || cmd == "seta" || cmd == "setfl") && argc >= 3)
		{
			if (argv(1) == target_name)
				found = argv(2);
		}
		else if (argc >= 2)
		{
			if (argv(0) == target_name)
				found = argv(1);
		}

		line = fgets(f);
	}

	fclose(f);
	return found;
};

// Apply a cfg-style cvar snapshot directly during worldspawn. Relying on
// an engine-side `exec` here proved unreliable on the first map in normal
// SSQC, while these files are simple cvar-assignment lists.
void(string cfgpath) SV_ApplyConfigFile =
{
	filestream f = fopen(cfgpath, FILE_READ);
	if (f < 0)
		return;

	print(sprintf("applying %s\n", cfgpath));

	string line = fgets(f);
	while (line)
	{
		float n = strlen(line);
		if (n > 0 && substring(line, n - 1, 1) == "\r")
			line = substring(line, 0, n - 1);

		float argc = tokenize(line);
		if (argc <= 0)
		{
			line = fgets(f);
			continue;
		}

		string cmd = argv(0);
		if (cmd == "//" || substring(cmd, 0, 1) == "#")
		{
			line = fgets(f);
			continue;
		}

		// These cfg files are intended for cvar assignments, not general
		// console scripting. Ignore command-only lines instead of creating
		// accidental user cvars named `exec`, `wait`, etc.
		if (cmd == "exec" || cmd == "alias" || cmd == "wait")
		{
			line = fgets(f);
			continue;
		}

		if ((cmd == "set" || cmd == "seta" || cmd == "setfl") && argc >= 3)
		{
			cvar_set(argv(1), argv(2));
			if (argv(1) == "rcon_password")
				cvar_set("sv_rcon_password_shadow", argv(2));
		}
		else if (argc >= 2)
		{
			cvar_set(argv(0), argv(1));
			if (argv(0) == "rcon_password")
				cvar_set("sv_rcon_password_shadow", argv(1));
		}

		line = fgets(f);
	}

	fclose(f);
};

void() SV_ApplyServerConfigFile =
{
	SV_ApplyConfigFile("data/server.cfg");
};

void() SV_WriteServerConfigFile =
{
	filestream f = fopen("data/server.cfg", FILE_WRITE);
	if (f < 0)
	{
		print("sv_saveconfig: fopen data/server.cfg FAILED\n");
		return;
	}

	fputs(f, "// data/server.cfg — server settings (auto-generated)\n\n");

	float i;
	for (i = 0; i < sv_servercfg_cvars.length; i = i + 1)
	{
		string name = sv_servercfg_cvars[i];
		string val = cvar_string(name);
		if (name == "rcon_password" && val == "")
			val = cvar_string("sv_rcon_password_shadow");
		if (name == "rcon_password" && val == "")
			val = SV_ReadConfigValue("data/server.cfg", name);
		fputs(f, sprintf("set %s \"%s\"\n", name, val));
	}

	fclose(f);
	print("sv_saveconfig: wrote data/server.cfg\n");
};

void() SV_ApplyMapConfigFile =
{
	SV_ApplyConfigFile(sprintf("maps/%s.cfg", mapname));
};

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

	// Defuse: hand the C4 to one random alive terrorist (RED) this round.
	// Self-gates on sv_gamemode==GAMEMODE_DEFUSE (no-op otherwise).  Runs AFTER
	// RoundRestart has respawned all teamed players (it calls us last), so the
	// alive-RED pass sees fresh spawns; if no RED is alive yet it defers via
	// sv_defuse_pending_red_pickup and the first RED to spawn picks it up
	// (see PlayerSpawn).
	Defuse_AssignBombAtRoundStart();
};

// COD-style corpse despawn: SINK the body slowly into the ground over
// mp_deadbody_sink_time seconds (re-networking the falling origin each tick like
// VisProxy_CorpseSettleThink), then do the real removal.  ~64u clears the ~56u model
// below the floor.  Reuses the settle-think's SendFlags|=VP_SF_POSE re-network pattern.
void() VisProxy_CorpseSinkThink =
{
	if (self.classname != "player_visual_proxy")	// repurposed — remove safely
	{
		self.pvsflags = 0; self.think = SUB_Remove; self.nextthink = time + 0.1;
		return;
	}
	float depth = cvar("mp_deadbody_sink_depth"); if (depth <= 0) depth = 64;
	float stime = cvar("mp_deadbody_sink_time");  if (stime <= 0) stime = 1.0;
	self.origin_z = self.origin_z - (depth / stime) * VISCORPSE_SETTLE_DT;
	setorigin(self, self.origin);
	self.SendFlags |= VP_SF_POSE;			// re-network the sinking origin

	if (time >= self.vis_sink_endtime)		// sunk — now the NOREMOVE-safe removal
	{
		self.pvsflags  = 0;			// drop NOREMOVE so the remove networks
		self.think     = SUB_Remove;
		self.nextthink = time + 0.1;
		return;
	}
	self.nextthink = time + VISCORPSE_SETTLE_DT;
};

// Retire a visual-proxy corpse so it disappears on ALL clients.  The corpse
// carries PVSF_NOREMOVE (kept during the round so it doesn't blink when a
// viewer briefly looks away), and the proxy's MODEL is rebuilt CSQC-side from
// networked identity fields — there is NO networked modelindex to zero (unlike
// the gib path, whose body-suppression actually rides a separate multicast).
// So the ONLY way to make a corpse vanish is a real CSQC_Ent_Remove, which
// PVSF_NOREMOVE suppresses: a bare remove() leaves the model cached on clients
// until the entnum slot is reused — the "player models left standing around the
// map until the next update" symptom.  Fix: clear pvsflags (drop NOREMOVE) so an
// out-of-PVS viewer culls it immediately, and an in-PVS viewer gets a proper
// remove when SUB_Remove frees it next frame (deferred one tick so the
// flag-clear is in effect before the edict is freed).
//
// COD-style polish: instead of an instant removal, kick off VisProxy_CorpseSinkThink
// to slide the body into the ground first (NOREMOVE stays set DURING the sink so it
// doesn't blink out for a viewer who looks away — it's cleared at the final removal
// inside the sink think).  mp_deadbody_sink_time <= 0 keeps the old instant removal.
void(entity corpse) VisProxy_RetireCorpse =
{
	if (corpse.vis_sinking)		// idempotent: a double-retire (RoundRestart racing
		return;			// DetachAsCorpse) must not restart/double the sink

	float stime = cvar("mp_deadbody_sink_time");
	if (stime <= 0 || cvar("mp_deadbody_sink_depth") <= 0)
	{
		corpse.pvsflags  = 0;          // sink disabled — original instant removal
		corpse.think     = SUB_Remove;
		corpse.nextthink = time + 0.1;
		return;
	}

	corpse.vis_sinking      = TRUE;
	corpse.velocity         = '0 0 0';	// stop any in-progress settle drop (Part E)
	corpse.vis_sink_endtime = time + stime;
	corpse.think            = VisProxy_CorpseSinkThink;	// overrides the settle think if mid-fall
	corpse.nextthink        = time + VISCORPSE_SETTLE_DT;
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

	// Return func_vehicles to spawn, eject drivers, clear momentum
	Vehicle_RoundReset();

	// Tell all clients to wipe bullet holes, shells, mags
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ROUND_CLEANUP);
	multicast('0 0 0', MULTICAST_ALL);

	// Sweep corpses (proxies detached by Player_VisualProxy_DetachAsCorpse
	// in PlayerKilled). remove() during a find() walk is unsafe in QC,
	// so collect first then bulk-remove. Cap at 32 (MAX_PLAYERS) — corpses
	// are 1:1 with kills so this comfortably covers any sane round.
	{
		entity corpses[32];
		float ccount = 0;
		entity ce = find(world, classname, "player_visual_proxy");
		while (ce && ccount < 32)
		{
			if (ce.vis_is_corpse)
				corpses[ccount++] = ce;
			ce = find(ce, classname, "player_visual_proxy");
		}
		float i;
		for (i = 0; i < ccount; i = i + 1)
			VisProxy_RetireCorpse(corpses[i]);   // networked remove, NOT a silent bare remove()
	}

	// Sweep any planted C4 (Defuse).  The bomb persists from plant until it
	// explodes or is defused — a defused bomb is deliberately left as a blue
	// prop for the round-end screen, and a still-ticking bomb can reach here if
	// the round ended another way.  Either would carry into the next round
	// (stale planted_c4 -> bomb_planted stays TRUE -> the round clock stays
	// suspended and the new round can't start cleanly), so remove them all.
	// Collect-then-remove (remove() during a find() walk is unsafe in QC).
	{
		entity bombs[8];
		float bcount = 0;
		entity be = find(world, classname, "planted_c4");
		while (be && bcount < 8)
		{
			bombs[bcount++] = be;
			be = find(be, classname, "planted_c4");
		}
		float bi;
		for (bi = 0; bi < bcount; bi = bi + 1)
			remove(bombs[bi]);
	}

	// Sweep cheat-spawned filing cabinets (phys_files, via `cmd spawnfiles`).
	// They are ODE rigid bodies + an always-on PVSF_NOREMOVE CSQC mirror, so
	// they persist across rounds unless removed.  Proper teardown (mirrors the
	// void-cull in sv_physprop.qc): if one is being carried, drop it so the
	// carrier's pm_carrying / carried_prop linkage is cleared (otherwise a
	// respawned carrier keeps a lowered weapon + a dangling predicted carry);
	// stop any looping scrape sound; detach the ODE body (physics_enable FALSE)
	// before remove() — a bare remove() orphans the rigid body.  The cabinet is a
	// box geom (not trimesh), so no dGeomTriMeshDataDestroy is needed.
	// Collect-then-remove (remove() during a find() walk is unsafe in QC).
	{
		entity cabs[32];
		float cabcount = 0;
		entity ce2 = find(world, classname, "phys_files");
		while (ce2 && cabcount < 32)
		{
			cabs[cabcount++] = ce2;
			ce2 = find(ce2, classname, "phys_files");
		}
		float ci;
		for (ci = 0; ci < cabcount; ci = ci + 1)
		{
			entity cab = cabs[ci];
			if (cab.carried_by != world)
				Carry_Drop(cab.carried_by);   // clears carried_prop + pm_carrying
			PhysFiles_StopScrape(cab);
			physics_enable(cab, FALSE);       // detach ODE box body now
			// The cabinet's CSQC mirror is PVSF_NOREMOVE too (sv_physprop.qc:818),
			// so a bare remove() is silent on clients — drop the flag and free it
			// next frame so the CSQC_Ent_Remove actually reaches them (exactly the
			// corpse case; see VisProxy_RetireCorpse).
			cab.pvsflags  = 0;
			cab.think     = SUB_Remove;
			cab.nextthink = time + 0.1;
		}
	}

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
			e.pending_round_join = FALSE;
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
		// Skip mid-round joiners — they're queued for the next RoundRestart
		// and shouldn't flip a 0→1 team-total transition into instant elim.
		if (!e.pending_round_join)
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

// Defuse win-condition check.  Returns the winning team (TEAM_RED / TEAM_BLUE),
// -1 for a mutual draw, or 0 to keep the round going.  Mirrors
// CheckTeamEliminated's pending_round_join skip + is_dead counting, but the
// planted bomb changes the rules:
//   - Bomb DOWN: a living defuser (BLUE) can still disarm and a living
//     terrorist (RED) is just guarding the tick, so let the fuse / defuse path
//     resolve those.  Only short-circuit when NOBODY is alive — otherwise the
//     bomb would burn down in an empty arena.  RED wins (uncontested detonation).
//   - Bomb NOT down: one-life elimination.  A side that fielded players and is
//     now fully dead loses; the other side wins even if it fielded nobody, so a
//     lone player's death still ends the round and awards the empty other team.
float(float bomb_is_down) Defuse_CheckWinCondition =
{
	entity e;
	float blue_total, red_total, blue_alive, red_alive;

	blue_total = 0; red_total = 0;
	blue_alive = 0; red_alive = 0;

	e = player_chain_head;
	while (e)
	{
		// Skip mid-round joiners (queued for the next RoundRestart) — same as
		// CheckTeamEliminated, so a fresh join can't flip an instant win.
		if (!e.pending_round_join)
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
		}
		e = e.player_chain_next;
	}

	// Nobody teamed yet (warmup / nobody spawned) — nothing to decide.
	if (blue_total == 0 && red_total == 0)
		return 0;

	if (bomb_is_down)
	{
		// Bomb ticking — only end early if the arena is empty of life (the fuse
		// can't be raced and nobody is left to watch it).  RED wins.  If anyone
		// is alive, let the bomb explode / be defused naturally.
		if (blue_alive == 0 && red_alive == 0)
			return TEAM_RED;
		return 0;
	}

	// Bomb not planted — one-life elimination.  A side is "out" only if it
	// fielded players this round and they're all dead (an empty enemy team is
	// not "eliminated", but the death of the last fielded player still ends it).
	float red_out  = (red_total  > 0 && red_alive  == 0);
	float blue_out = (blue_total > 0 && blue_alive == 0);

	if (red_out && blue_out)
		return -1;          // both fielded sides wiped on the same tick -> draw
	if (red_out)
		return TEAM_BLUE;   // terrorists wiped before the plant -> CTs win
	if (blue_out)
		return TEAM_RED;    // defenders wiped, no plant -> terrorists win
	return 0;
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
// Tracks the previous tick's sv_gamemode value so StartFrame can detect a
// switch and respawn all players (handles admin live-switching between
// TDM / Bhop / FFA). _inited gates the first-tick comparison so we don't
// trigger a spurious respawn on map load.
float sv_prev_gamemode;
float sv_gamemode_inited;

string sv_info_last_shiftspeed;
string sv_info_last_maxspeed;
string sv_info_last_accelerate;
string sv_info_last_airaccelerate;
string sv_info_last_friction;
string sv_info_last_waterfriction;
string sv_info_last_wateraccelerate;
string sv_info_last_gravity;
string sv_info_last_stopspeed;
string sv_info_last_hull_height;
string sv_info_last_eye_height;
string sv_info_last_autohop;
string sv_info_last_stamina;
string sv_info_last_snipersway;
string sv_info_last_mp_cheats;
string sv_info_last_mp_noblock;
string sv_info_last_playerselect;
string sv_info_last_mintic;
string sv_info_last_wepswap_speed_transition;
string sv_info_last_weaponweight;
string sv_info_last_backdrop;
string sv_info_last_toss_tickrate;
string sv_info_last_phys_drops;
string sv_info_last_default_primary;
string sv_info_last_default_secondary;
string sv_info_last_default_melee;
string sv_info_last_default_utility;
// Pushed so the server-browser hostcache (menu/m_serverbrowser.qc)
// can read the gamemode value via gethostcachestring(.., "sv_gamemode")
// without parsing it from the hostname.
string sv_info_last_gamemode;
// Pushed so client-side hitmarker prediction (sh_weapon_logic.qc) can
// gate on the server's authoritative trust mode.  trust>=1 → client
// predicts hitmarker locally and server suppresses its own; trust=0 →
// server is the sole source.  Without serverinfo push, the client
// has no way to know which side owns the marker and double-fires.
string sv_info_last_trust_clienthits;
// Mirrors sv_trust_clienthits but for breakable damage.  Pushed so the
// client knows whether to emit `cmd breakclaim` (and the server knows
// to defer its own trace damage on those targets).
string sv_info_last_trust_clientbreak;

// CoD-style movement / scope / kick feature cvars.  CSQC reads each of
// these via PM_ReadMovevar / serverkey, so they MUST be pushed to
// serverinfo or the client-side feature (sniper scope, gunkick, sliding,
// codstamina, grapple, …) silently no-ops with a 0 fallback.
string sv_info_last_jumpstyle;
string sv_info_last_jumplag;
string sv_info_last_groundstick_suppress_jump;
string sv_info_last_sliding;
string sv_info_last_sliding_start_speed;
string sv_info_last_sliding_end_speed;
string sv_info_last_sliding_friction_mult;
string sv_info_last_sliding_boost;
string sv_info_last_slidingcrouch;
string sv_info_last_grappling;
string sv_info_last_ads_spread_mult;
string sv_info_last_crosshair;
string sv_info_last_gunkick;
string sv_info_last_gunkick_strength;
string sv_info_last_gunkick_decay_rate;
string sv_info_last_gunkick_damping;
string sv_info_last_gunkick_instant;
string sv_info_last_headkick;
string sv_info_last_headkick_return_rate;
string sv_info_last_mp_friendlyfire;
string sv_info_last_hitbox_expand;
string sv_info_last_codladders;
string sv_info_last_codscopes;
string sv_info_last_codscope_fov;
string sv_info_last_codstamina;
string sv_info_last_codstamina_ground_grace;
string sv_info_last_codstamina_jump_cost;
string sv_info_last_codstamina_punish_jump_scale;
string sv_info_last_codstamina_fire_suppress_time;
string sv_info_last_codstamina_land_cost;

// Per-frame cvar cache globals (sv_cached_*) live in shared/sh_customdefs.qc
// inside #ifdef SSQC, because sh_player_anims.qc references them and
// compiles earlier in sv_progs.src than this file.

// Phase counter for SV_UpdateMovementServerInfo throttle (every 8 ticks).
float sv_info_push_phase;
float sv_phys_mapweapon_sync_done;

// Change-tracker for the sv_func_tickrate auto-tie (only cvar_set on change).
string sv_info_last_func_tickrate;

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
	// FTE engine registers sv_waterfriction with default "4" (sv_phys.c).
	// Without publishing it, CSQC's PM_ReadMovevar falls back to 1, while
	// the server-side QC reads the engine value (4) directly via cvar() —
	// at high ping the per-tick water deceleration mismatch accumulates
	// over the unacked prediction window and pops as a "whiplash" snap on
	// reconcile after the player exits a push trigger underwater. Pushing
	// it (and sv_wateraccelerate) keeps both sides on the same value.
	sv_info_push_if_changed("sv_waterfriction", sv_info_last_waterfriction);
	sv_info_push_if_changed("sv_wateraccelerate", sv_info_last_wateraccelerate);
	sv_info_push_if_changed("sv_gravity",       sv_info_last_gravity);
	sv_info_push_if_changed("sv_stopspeed",     sv_info_last_stopspeed);
	sv_info_push_if_changed("sv_hull_height",   sv_info_last_hull_height);
	sv_info_push_if_changed("sv_eye_height",    sv_info_last_eye_height);
	sv_info_push_if_changed("sv_autohop",       sv_info_last_autohop);
	sv_info_push_if_changed("sv_stamina",       sv_info_last_stamina);
	sv_info_push_if_changed("sv_snipersway",    sv_info_last_snipersway);
	sv_info_push_if_changed("mp_cheats",        sv_info_last_mp_cheats);
	// CSQC pmove reads this via serverkey to gate PM_NoblockStash on the
	// client side (sh_pmove.qc).  Without it the client uses a local-only
	// cvar() lookup that returns 0, predicts solid collision against
	// other players, and the player visually rubber-bands when the server
	// reconciles to the no-block trace result.  Server-auth for this
	// value also prevents clients from forcing noblock prediction
	// against a server that has it disabled.
	sv_info_push_if_changed("mp_noblock",       sv_info_last_mp_noblock);
	// Server-authoritative model-pick mode: publish so the client team-select
	// menu reads the SERVER's sv_playerselect (via serverkeyfloat) instead of
	// each client's local cvar() — otherwise the setting acts per-client.
	sv_info_push_if_changed("sv_playerselect",  sv_info_last_playerselect);

	// Gravity Shift: publish the GLOBAL gravity direction (set by the arbiter in
	// GravShift_UpdateActivation) so every client reads it via serverkey("gravdir").
	// MUST be pushed HERE at StartFrame, NOT from inside PM_PlayerMove — a localcmd
	// serverinfo issued mid-client-command-processing interleaves a reliable message
	// into the per-client stream and corrupts it ("Illegible server message" crash
	// on release/fall).  On-change only, like the cvar pushes above.
	if (gravshift_world_dir != gravshift_world_dir_last)
	{
		localcmd(sprintf("serverinfo gravdir \"%v\"\n", gravshift_world_dir));
		gravshift_world_dir_last = gravshift_world_dir;
	}
	// Publish the server's authoritative tick interval (seconds per
	// server frame) so CSQC debug panels can read the exact configured
	// value rather than measuring it empirically from snapshot-arrival
	// jitter.  Use sv_mintic as the source of truth — sv_maxtic ≥
	// sv_mintic always, and in a properly configured server both are
	// identical.  Pushes only on change, so zero overhead steady-state.
	sv_info_push_if_changed("sv_mintic",        sv_info_last_mintic);

	// Auto-tie sv_func_tickrate to the REAL server tick rate (1/sv_mintic).
	// Func movers (func_rotating/door/pendulum/train/vehicle) integrate their
	// carry/push physics at sv_func_tickrate Hz; when that disagrees with the
	// server's actual tick (e.g. a 66-tick server left at the 64 default) the
	// mover cadence drifts against pmove → visible double-rotation + jitter.
	// Round 1/sv_mintic and overwrite the cvar only on change — the same
	// always-auto model as the client stuffing cl_netfps from sv_mintic
	// (Sync_NetFPS_To_Tickrate).  Every SSQC mover read of cvar("sv_func_tickrate")
	// is then correct by construction; CSQC gets it via STAT_FUNC_TICKRATE below.
	// Bounded 40..200 to match the consumer clamps.
	{
		float ftr_mintic = cvar("sv_mintic");
		if (ftr_mintic > 0.0001)
		{
			float ftr_hz = floor(1.0 / ftr_mintic + 0.5);
			if (ftr_hz < 40)  ftr_hz = 40;
			if (ftr_hz > 200) ftr_hz = 200;
			string ftr_hzs = ftos(ftr_hz);
			if (ftr_hzs != sv_info_last_func_tickrate)
			{
				cvar_set("sv_func_tickrate", ftr_hzs);
				sv_info_last_func_tickrate = ftr_hzs;
			}
		}
	}
	// Weapon-switch speed transition window — read by Weapon_SpeedFactor_Smooth
	// on both client and server. Pushed via serverinfo so the client always
	// uses the server's authoritative value (no local drift).
	sv_info_push_if_changed("sv_wepswap_speed_transition", sv_info_last_wepswap_speed_transition);
	// Per-weapon movement penalty toggle — Weapon_SpeedFactor_Smooth on
	// CSQC reads this via serverkeyfloat so prediction matches the server.
	sv_info_push_if_changed("mp_weaponweight",  sv_info_last_weaponweight);
	// Backdrop flag — CSQC reads this to suppress HUD / team-select while
	// the listen server is just rendering the menu's background map. Set
	// to 1 by the menu's backdrop launcher, 0 by any real-game launcher.
	// Server-authoritative so console `connect` paths also work correctly.
	sv_info_push_if_changed("sv_backdrop",      sv_info_last_backdrop);
	// Default loadout cvars — pushed so the in-game rcon panel can render
	// human-readable dropdowns that reflect the remote server's current
	// values instead of falling back to local client-side defaults.
	sv_info_push_if_changed("sv_default_primary",   sv_info_last_default_primary);
	sv_info_push_if_changed("sv_default_secondary", sv_info_last_default_secondary);
	sv_info_push_if_changed("sv_default_melee",     sv_info_last_default_melee);
	sv_info_push_if_changed("sv_default_utility",   sv_info_last_default_utility);
	// Send rate (Hz) for in-flight items — dropped weapons + projectiles.
	// Read by Toss_NextThinkInterval (sv_weapons.qc) and the CSQC predraw
	// helper (cl_tosssmooth.qc) for matching dt-cap math.
	sv_info_push_if_changed("sv_toss_tickrate", sv_info_last_toss_tickrate);
	// Lets CSQC suppress fake weapon-drop tosses when the server is using ODE.
	sv_info_push_if_changed("sv_phys_drops",    sv_info_last_phys_drops);
	// Server browser column: gamemode (TDM / Elim / Bhop / FFA).
	sv_info_push_if_changed("sv_gamemode",      sv_info_last_gamemode);
	// Hitmarker ownership: client-side hitmarker prediction reads this
	// to decide whether to fire locally (trust>=1) or wait for the
	// server's CSQC_EVENT_HITMARKER (trust=0).  Server's own marker
	// emit is gated on the same value so the two don't double up.
	sv_info_push_if_changed("sv_trust_clienthits", sv_info_last_trust_clienthits);
	// Breakable-damage trust: when ON, client owns the damage source
	// (sends `cmd breakclaim`) and server defers its own trace damage
	// on func_breakable targets.  Mirrors sv_trust_clienthits.
	sv_info_push_if_changed("sv_trust_clientbreak", sv_info_last_trust_clientbreak);

	// CoD-style movement / scope / kick replication.  Without these the
	// CSQC side reads 0 and the features are off client-side: sniper
	// +attack2 ADS-scope (sv_codscopes / sv_codscope_fov), grapple
	// (sv_grappling), sliding, codstamina, gunkick / headkick, etc.
	sv_info_push_if_changed("sv_jumpstyle",     sv_info_last_jumpstyle);
	sv_info_push_if_changed("sv_jumplag",       sv_info_last_jumplag);
	sv_info_push_if_changed("pm_groundstick_suppress_jump", sv_info_last_groundstick_suppress_jump);
	sv_info_push_if_changed("sv_codladders",    sv_info_last_codladders);
	sv_info_push_if_changed("sv_codscopes",     sv_info_last_codscopes);
	sv_info_push_if_changed("sv_codscope_fov",  sv_info_last_codscope_fov);
	sv_info_push_if_changed("sv_codstamina",    sv_info_last_codstamina);
	sv_info_push_if_changed("sv_codstamina_ground_grace",      sv_info_last_codstamina_ground_grace);
	sv_info_push_if_changed("sv_codstamina_jump_cost",         sv_info_last_codstamina_jump_cost);
	sv_info_push_if_changed("sv_codstamina_punish_jump_scale", sv_info_last_codstamina_punish_jump_scale);
	sv_info_push_if_changed("sv_codstamina_fire_suppress_time", sv_info_last_codstamina_fire_suppress_time);
	sv_info_push_if_changed("sv_codstamina_land_cost",          sv_info_last_codstamina_land_cost);
	sv_info_push_if_changed("sv_sliding",       sv_info_last_sliding);
	sv_info_push_if_changed("sv_sliding_start_speed",    sv_info_last_sliding_start_speed);
	sv_info_push_if_changed("sv_sliding_end_speed",      sv_info_last_sliding_end_speed);
	sv_info_push_if_changed("sv_sliding_friction_mult",  sv_info_last_sliding_friction_mult);
	sv_info_push_if_changed("sv_sliding_boost",          sv_info_last_sliding_boost);
	sv_info_push_if_changed("sv_slidingcrouch",          sv_info_last_slidingcrouch);
	sv_info_push_if_changed("sv_grappling",              sv_info_last_grappling);
	sv_info_push_if_changed("sv_ads_spread_mult",        sv_info_last_ads_spread_mult);
	sv_info_push_if_changed("sv_crosshair",     sv_info_last_crosshair);
	sv_info_push_if_changed("sv_gunkick",            sv_info_last_gunkick);
	sv_info_push_if_changed("sv_gunkick_strength",   sv_info_last_gunkick_strength);
	sv_info_push_if_changed("sv_gunkick_decay_rate", sv_info_last_gunkick_decay_rate);
	sv_info_push_if_changed("sv_gunkick_damping",    sv_info_last_gunkick_damping);
	sv_info_push_if_changed("sv_gunkick_instant",    sv_info_last_gunkick_instant);
	sv_info_push_if_changed("sv_headkick",           sv_info_last_headkick);
	sv_info_push_if_changed("sv_headkick_return_rate", sv_info_last_headkick_return_rate);
	sv_info_push_if_changed("mp_friendlyfire",  sv_info_last_mp_friendlyfire);
	sv_info_push_if_changed("sv_hitbox_expand",     sv_info_last_hitbox_expand);
};

// Post-config fixup: if the persisted data/server.cfg snapshot leaves any
// registered cvar empty when it should have a real default, restore it
// from the shared cvar table. Runs once.
float sv_cfg_fixed_up;
void() SV_FixupEmptyDefaults =
{
	if (sv_cfg_fixed_up)
		return;
	sv_cfg_fixed_up = TRUE;
	CVar_ForceDefaults();
};

// `cleanmodels` / `cleandecals` server-console commands, implemented as
// cvars a StartFrame watcher polls + resets.  Admin `cleanmodels 1` bulk-
// wipes corpses + client casings/mags; `cleandecals 1` wipes bullet holes
// / scorch / muzzle smoke / CS smoke puffs (all pure CSQC visuals).
void() SV_DoCleanModels =
{
	// Server-side: bulk-remove every corpse on the map.  Collect-then-
	// remove (safe against remove() during a find() walk).  32-cap
	// matches the MAX_PLAYERS-derived corpse ceiling per round.
	entity corpses[32];
	float ccount = 0;
	entity ce = find(world, classname, "player_visual_proxy");
	while (ce && ccount < 32)
	{
		if (ce.vis_is_corpse)
			corpses[ccount++] = ce;
		ce = find(ce, classname, "player_visual_proxy");
	}
	float i;
	for (i = 0; i < ccount; i = i + 1)
		VisProxy_RetireCorpse(corpses[i]);   // networked remove (PVSF_NOREMOVE makes bare remove() silent)

	// Tell every client to wipe their CSQC casings + mags.
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_CLEANMODELS);
	multicast('0 0 0', MULTICAST_ALL);
};

void() SV_DoCleanDecals =
{
	// All decals are pure CSQC visual entities — just broadcast the wipe.
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_CLEANDECALS);
	multicast('0 0 0', MULTICAST_ALL);
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

	// Map weapons spawn before ODE is attached on the first StartFrame.
	// If sv_phys_drops was already enabled at map load, convert those
	// initial pickups once after ODE is ready. Later cvar flips intentionally
	// do not rewrite existing pickup state.
	if (!sv_phys_mapweapon_sync_done && cvar("sv_ode_loaded") > 0)
	{
		sv_phys_mapweapon_sync_done = TRUE;
		if (cvar("sv_phys_drops") > 0)
			W_SyncMapWeaponPhysics();
		// Add brushwork (func_breakable / func_door / func_button) to
		// ODE's collision world so phys drops can rest on / collide
		// with them.  Must run AFTER ODE plug_load completes (gated
		// by sv_ode_loaded above) — calling physics_enable before
		// ODE is ready is a no-op.
		BrushSyncODE();
	}

	// Refresh per-frame cvar cache — single read per tick for constants
	// that hot-path code (Player_VisualProxy_Sync, SH_PlayerAnim_Update)
	// would otherwise re-read on every call.
	{
		float ticks = cvar("sv_pose_keepalive_ticks");
		if (ticks < 1) ticks = 1;
		sv_cached_pose_keepalive_interval = cvar("sv_mintic") * ticks;
		if (sv_cached_pose_keepalive_interval < 0.005)
			sv_cached_pose_keepalive_interval = 0.015;

		sv_cached_anim_qu_per_sec        = cvar("sv_anim_qu_per_sec");
		if (sv_cached_anim_qu_per_sec        <= 0) sv_cached_anim_qu_per_sec        = 240;
		sv_cached_anim_qu_per_sec_crouch = cvar("sv_anim_qu_per_sec_crouch");
		if (sv_cached_anim_qu_per_sec_crouch <= 0) sv_cached_anim_qu_per_sec_crouch = 100;
	}

	gamemode = cvar("sv_gamemode");

	// Detect sv_gamemode change.  Two things happen on (init OR transition):
	//   1. Per-gamemode cvar enforcement — toggles (mp_respawn, mp_falldamage,
	//      mp_noblock, mp_disabledoors) snap to the new mode's defaults.
	//   2. On transition into a respawn-friendly mode (TDM / Bhop / FFA),
	//      respawn every teamed player so they land at the new mode's
	//      spawn pool with clean state.
	//
	// Previously the enforcement ran every tick (4× cvar_set every server
	// frame) — that dominated StartFrame self-time in profiling.  Since
	// the only thing that should change these cvars is a gamemode flip,
	// running once per transition is functionally identical and ~128× cheaper.
	float gamemode_changed = (!sv_gamemode_inited) || (gamemode != sv_prev_gamemode);
	if (gamemode_changed)
	{
		float was_inited = sv_gamemode_inited;
		sv_prev_gamemode  = gamemode;
		sv_gamemode_inited = TRUE;

		if (gamemode == GAMEMODE_BHOP)
		{
			cvar_set("mp_falldamage",   "0");
			cvar_set("mp_noblock",      "1");
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "1");
		}
		else if (gamemode == GAMEMODE_FFA)
		{
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "0");
		}
		else if (gamemode == GAMEMODE_ELIMINATION)
		{
			cvar_set("mp_respawn",      "0");
			cvar_set("mp_disabledoors", "0");
		}
		else if (gamemode == GAMEMODE_PAINTGUN)
		{
			// Same round flow as elimination — no respawn until round end.
			cvar_set("mp_respawn",      "0");
			cvar_set("mp_disabledoors", "0");
			// Falldamage off so a stray drop doesn't end your round
			// before anyone tags you.  Paintgun is light-stakes by design.
			cvar_set("mp_falldamage",   "0");
			// Strip map weapons — paintgun is paintball + snowball only,
			// any pickup of a "real" weapon would break the loadout
			// constraint (and you'd just see slot rejection on touch
			// anyway since all four slots are pinned by the gamemode).
			cvar_set("mp_nomapweapons", "1");
		}
		else if (gamemode == GAMEMODE_DEFUSE)
		{
			// One life per round (same round flow as Elimination).  Required
			// for the defuse win conditions below — a team wipe / empty arena
			// only ends the round if dead players STAY dead this round.
			cvar_set("mp_respawn",      "0");
			cvar_set("mp_disabledoors", "0");
		}
		else  // TDM
		{
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "0");
		}

		// Respawn-friendly mass-respawn — only on a real transition, not
		// the first-tick init (no players yet at that point).
		if (was_inited
			&& (gamemode == GAMEMODE_TDM
				|| gamemode == GAMEMODE_BHOP
				|| gamemode == GAMEMODE_FFA))
		{
			entity ge_e, ge_saved;
			ge_e = player_chain_head;
			while (ge_e)
			{
				if (ge_e.player_team == TEAM_BLUE
					|| ge_e.player_team == TEAM_RED)
				{
					ge_e.is_dead    = FALSE;
					ge_e.death_time = 0;
					PlayerRefreshScoreboardInfo(ge_e);
					ge_saved = self;
					self     = ge_e;
					PlayerSpawn();
					self     = ge_saved;
				}
				ge_e = ge_e.player_chain_next;
			}
			bprint(PRINT_HIGH, "Gamemode changed - respawning all players.\n");
		}
	}

	// Movement-cvar serverinfo push: rate-limit to ~16 Hz.  These cvars
	// only change on admin commands; 23 cvar_string() compares per tick
	// at 128 Hz dominated SSQC self-time in profiling.  At 8-tick stride
	// the publish latency is at most 62 ms — invisible to clients.
	sv_info_push_phase = (sv_info_push_phase + 1) & 7;
	if (sv_info_push_phase == 0)
		SV_UpdateMovementServerInfo();

	// Admin cleanup commands (cvars polled + auto-reset).  `cleanmodels 1`
	// wipes corpses + client casings/mags; `cleandecals 1` wipes bullet
	// holes / scorch / muzzle smoke / CS smoke puffs.
	if (cvar("cleanmodels") != 0)
	{
		SV_DoCleanModels();
		cvar_set("cleanmodels", "0");
	}
	if (cvar("cleandecals") != 0)
	{
		SV_DoCleanDecals();
		cvar_set("cleandecals", "0");
	}

	// Resolve any "camera .target" strings on the first tick (after all
	// info_null entities have spawned) and rotate the active team-select
	// camera when >CAMERA_CYCLE_SECONDS have elapsed.
	Camera_EnsureTargetsResolved();
	Camera_UpdateCyclingSpectators();

	// Synthesize missed input ticks for low-cl_netfps players so other
	// clients see them move smoothly instead of freeze-then-jump.
	SV_RunCommandContinuation();

	// nettest bots: advance the incremental nav-graph build (sv_navnodes.qc),
	// then run the bot fill + per-bot AI (sv_bots.qc).
	Nav_Tick();
	Bot_RunFrame();

	// Admin trigger: `sv_roundrestart 1` (or alias command
	// `restartround`) queues a round restart after
	// mp_roundrestartdelay seconds. Resets itself to 0. SSQC has no
	// registercommand, so this cvar-toggle pattern is still the
	// underlying implementation.
	if (cvar("sv_roundrestart"))
	{
		cvar_set("sv_roundrestart", "0");
		float delay = cvar("mp_roundrestartdelay");
		if (delay <= 0) delay = 3;
		round_phase = ROUND_PHASE_ROUND_END;
		round_restart_time = time + delay;
		bprint(PRINT_HIGH, sprintf("Round restarting in %g seconds...\n", delay));
	}

	// Admin trigger: "sv_saveconfig 1" snapshots the current live server
	// settings into data/server.cfg, mirroring the menu-side save path.
	if (cvar("sv_saveconfig"))
	{
		cvar_set("sv_saveconfig", "0");
		SV_WriteServerConfigFile();
	}

	// Admin trigger: `sv_writecvars 1` (or alias command `writecvars`)
	// overwrites data/allcommands.cfg from the shared cvar table
	// (shared/sh_cvar_table.qc CVar_Init). Same self-resetting
	// cvar-toggle pattern as sv_roundrestart.
	if (cvar("sv_writecvars"))
	{
		cvar_set("sv_writecvars", "0");
		CVar_WriteAllCommandsCfg();
	}

	// Is a planted bomb live this frame?  Used to suspend the round clock in
	// Defuse (the bomb fuse owns the round once it's down) and to hide the
	// HUD round timer.  The planted_c4 exists from plant until explode/defuse/
	// round-restart sweep, so its presence is the authoritative "bomb is down".
	float bomb_planted = (find(world, classname, "planted_c4") != world);

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
		// Check round timer expiry.  In Defuse, once the bomb is planted the
		// round clock is suspended — the bomb fuse decides the round (explode =
		// RED win via Defuse_TriggerRoundEnd, defuse = BLUE win).  Without this
		// the clock would end the round mid-fuse and the bomb detonated into the
		// next round.
		if (time >= round_end_time
			&& !(gamemode == GAMEMODE_DEFUSE && bomb_planted))
		{
			round_winning_team = 0;
			round_phase = ROUND_PHASE_ROUND_END;
			round_restart_time = time + cvar("mp_roundrestartdelay");
		}
		// Check team elimination — applies to elim and paintgun, both
		// of which use the "one team left wins the round" win flow.
		else if (gamemode == GAMEMODE_ELIMINATION || gamemode == GAMEMODE_PAINTGUN)
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
		else if (gamemode == GAMEMODE_DEFUSE)
		{
			// Defuse one-life + bomb win conditions (see Defuse_CheckWinCondition).
			// Chained off the timer-expiry `if` above, so this runs whenever the
			// round clock hasn't ended things — including the suspended-clock
			// window while the bomb is planted, where condition A can still fire.
			winner = Defuse_CheckWinCondition(bomb_planted);
			if (winner != 0)
			{
				if (winner == -1)
				{
					// Mutual elimination — draw, no score awarded.
					round_winning_team = 0;
					round_phase = ROUND_PHASE_ROUND_END;
					round_restart_time = time + cvar("mp_roundrestartdelay");
				}
				else
				{
					// Funnel through the canonical defuse award so the bomb-explode,
					// defuse-complete, and elimination paths all end the round the
					// same way (score++ + phase flip + double-trigger guard).
					round_winning_team = winner;
					Defuse_TriggerRoundEnd();
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

				// nettest progression: match-completion XP + force-save everyone
				// (the autosave cadence may not have flushed recent gains).
				for (e = world; (e = find(e, classname, "player")); )
				{
					if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
						Prog_AwardXP(e, PROG_XP_MATCHEND, "matchend");
					Prog_Save(e);
				}
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
			string nextmap = SV_NextMapFromCycleFile();
			if (nextmap == "")
				nextmap = mapname;
			localcmd(sprintf("changelevel %s\n", nextmap));
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
				if (cvar("mp_respawn"))
				{
					// Auto-respawn after delay. mp_respawn is the universal
					// gate now (was hardcoded to gamemode == TDM); TDM /
					// Bhop / FFA force it on per-mode in the StartFrame
					// gamemode-force block below, Elimination forces it off.
					e.is_dead = FALSE;
					e.death_time = 0;
					PlayerRefreshScoreboardInfo(e);
					saved = self;
					self = e;
					PlayerSpawn();
					self = saved;
				}
				else if (gamemode == GAMEMODE_ELIMINATION || gamemode == GAMEMODE_PAINTGUN
				         || gamemode == GAMEMODE_DEFUSE)
				{
					// Elimination / Paintgun / Defuse: one life per round — hide
					// body, enter spectator phase (no mid-round respawn).
					e.modelindex = 0;
					e.death_time = -1;  // prevent re-triggering
				}
				// (mp_respawn=0 in any other mode just leaves the body in
				// place — admin choice, no special handling needed.)
			}
		}
		else
		{
			e.sv_death_delay_left = 0;
		}
		e.sv_is_dead = e.is_dead;

		e.round_timer_remaining = floor(remaining);	// nettest: quantize to whole seconds (client renders floor MM:SS) so this global stat deltas once/sec to every client, not every tick
		e.sv_maptimeleft = floor(map_remaining);	// nettest: ditto (debug MM:SS uses floor)
		e.sv_roundnum = round_number;
		e.sv_maxrounds = max_rounds;
		e.sv_round_phase = round_phase;
		e.sv_freeze_timeleft = (round_phase == ROUND_PHASE_FREEZE) ? ceil(max(0, freeze_end_time - time)) : 0;	// nettest: quantize to whole seconds (client renders ceil) - delta once/sec to every client, not every tick
		e.sv_gamemode = gamemode;
		e.sv_winning_team = round_winning_team;
		// Mirror the (auto-tied) sv_func_tickrate so CSQC prediction reads the
		// server's real mover tick rate via getstatf(STAT_FUNC_TICKRATE).
		e.sv_func_tickrate_value = cvar("sv_func_tickrate");
		e.sv_blue_score = blue_team_score;
		e.sv_red_score = red_team_score;
		e.sv_money = e.money;
		e.sv_armor = e.armor;
		e.sv_in_buyzone = Player_CanBuy(e);
		// C4 carrier only: whether a plant is allowed at their spot right now,
		// so the client can gate the plant prefire animation (STAT_CAN_PLANT).
		e.sv_can_plant_c4 = (e.ammo_cfc4 > 0 && C4_CanPlantHere(e)) ? 1 : 0;
		// Defuse-only: 1 while the bomb is down, so the HUD hides the round
		// timer (the round clock is suspended — see the timer-expiry guard).
		e.sv_bomb_planted = (gamemode == GAMEMODE_DEFUSE && bomb_planted) ? 1 : 0;

		// nettest progression: mirror XP/level to clientstats, accrue playtime,
		// and flush a dirty player to the DB at most once per PROG_AUTOSAVE_SECS.
		e.sv_xp         = e.prog_xp;
		e.sv_level      = e.prog_level;
		e.sv_xp_next    = e.prog_xp_next;
		e.sv_sessionxp  = e.prog_match_xp;
		e.prog_playtime = e.prog_playtime + frametime;
		if (e.prog_dirty && (time - e.prog_last_save) > PROG_AUTOSAVE_SECS)
		{
			Prog_Save(e);
			e.prog_last_save = time;
		}
		e = e.player_chain_next;
	}

	// Pay round-end cash once, on the edge into ROUND_END (covers timer /
	// elimination / C4 win paths uniformly without touching each site).
	Money_CheckRoundAward();

	// Append the current pose of every alive player to the lag-comp ring.
	// Runs once per tick, immediately after the per-player loop above — the
	// skeletal fields from the previous tick's PlayerPostThink are settled
	// at this point.
	Lagcomp_RecordAllAlive();
	Killcam_SV_RecordAll();		// nettest: server-side killcam camera-track ring (sv_killcam.qc)

	// sv_debug_hitboxes 2: continuously send all player hitbox states
	if (cvar("sv_debug_hitboxes") == 2)
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
				WriteByte(MSG_MULTICAST, 2); // mode: 2 = continuous
				multicast(center, MULTICAST_PVS);
			}
			e = e.player_chain_next;
		}
	}
};

void() worldspawn =
{
	// Reset per-map state that's held in QC file-scope globals — FTE
	// doesn't reload progs between map loads, so any global that
	// accumulates across a map (camera linked-list head, one-shot
	// flags, cycling RNG state) needs an explicit clear here.
	Camera_ResetState();
	Nav_Reset();		// nettest bots: clear the nav graph before this map's info_node entities spawn
	Surf_LoadMaterials();	// scripts/surfaceprops.txt -> texture material table (sh_surfaceprops.qc)

	// Backdrop latch — the menu backdrop launchers (m_main / m_menu) set
	// sv_backdrop_pending 1 immediately before `map <menumap>`. Consume it
	// into the live sv_backdrop here, so the menu backdrop keeps its HUD +
	// team-select suppression while ANY other map load (console `map X`,
	// the map cycle, create-server) comes up as a real game with
	// sv_backdrop 0 instead of inheriting the sticky backdrop flag. CSQC
	// gates the spectator/team-select view + HUD on
	// serverkeyfloat("sv_backdrop") (cl_main.qc). cvar() returns 0 for the
	// never-set case (dedicated server, direct +map) — the correct default.
	cvar_set("sv_backdrop", cvar("sv_backdrop_pending") ? "1" : "0");
	cvar_set("sv_backdrop_pending", "0");

	// Mod-identity beacon for clients.  Our CSQC drives spawn flow
	// through STAT_PLAYERTEAM + the team-select menu — vanilla QW
	// servers don't push those stats, so when our client connects
	// to a vanilla server the team menu hijacks the cursor forever
	// waiting for STAT_PLAYERTEAM to flip.  Publishing this key
	// lets the menu detect "this is our mod's server" and skip
	// itself entirely on anything else (m_teamselect.qc
	// TeamMenuIsOpen).
	localcmd("serverinfo modname nettest\n");

	// Lift the per-client packet-rate cap. cls.maxfps defaults to 72
	// (cl_main.c:3172-3174 — falls back if serverinfo "maxfps" is unset
	// or <20), which is the ceiling cl_netfps gets clamped against in
	// cl_pred.c:936. Without this push, our cl_netfps 100 in
	// engine_tweaks.cfg silently runs at 72. 1000 is just "uncapped" —
	// the actual send rate stays bounded by each client's own
	// cl_netfps. Live-configurable: clients re-read on next userinfo
	// parse so no reconnect needed if this value ever changes.
	localcmd("serverinfo maxfps 1000\n");

	// Lift the per-client byte/s caps to "no limit". Engine defaults
	// are sv_maxrate 50000 (caps client `rate` userinfo to 50 KB/s) and
	// sv_maxdrate 500000 (caps download bandwidth to 500 KB/s); both
	// applied per-client in SV_RateForClient (sv_main.c:5354). Setting
	// them to 0 disables the clamp entirely, so each client's own
	// `rate` userinfo (default.cfg pushes 100000) is what actually
	// applies. data/engine_tweaks.cfg has these listed too but that
	// file isn't auto-exec'd anywhere — pushing from QC is the only
	// reliable place that survives across map loads + server.cfg
	// reloads.
	localcmd("sv_maxrate 0\n");
	localcmd("sv_maxdrate 0\n");

	// Load the rigid-body physics plugin before precache_everything() so that
	// phys_barrel_precache()'s physics_supported(TRUE) call sees it.
	// data/default.cfg used to handle this, but that file is client-only
	// now, so dedicated servers rely on this localcmd instead.
	// plug_load is idempotent — loading a plugin already loaded is a no-op.
	//
	// nettest: the backend is selectable. Box3D (the new multicore backend,
	// fteplug_box3d) is the default; set `sv_physics_engine ode` in server.cfg to
	// use the original ODE backend instead. Only ONE physics plugin can be active
	// at a time (whichever registers first wins). default.cfg / ftesrv.cfg still
	// `plug_load ode` at startup, so we must plug_close the OTHER backend first,
	// else the desired one's RegisterPhysicsEngine fails with "already active".
	// This runs at server init before any physics body exists, so closing is safe.
	if (cvar_string("sv_physics_engine") == "ode")
	{
		localcmd("plug_close box3d\n");
		localcmd("plug_load ode\n");
	}
	else
	{
		localcmd("plug_close ode\n");
		localcmd("plug_load box3d\n");
	}
	localcmd("alias roundrestart \"sv_roundrestart 1\"\n");
	localcmd("alias roundreset \"sv_roundrestart 1\"\n");
	localcmd("alias resetround \"sv_roundrestart 1\"\n");
	localcmd("alias restartround \"sv_roundrestart 1\"\n");
	localcmd("alias writecvars \"sv_writecvars 1\"\n");

	precache_everything();
	precache_sound("sounds/effects/zipup.wav");   // Kevlar/helmet buy confirm

	Lagcomp_Init();
	Killcam_SV_Init();		// nettest: reset the server killcam ring on (re)spawn of the server

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
	clientstat(STAT_FUNC_TICKRATE, EV_FLOAT, sv_func_tickrate_value);
	clientstat(STAT_DEATH_DELAY_LEFT, EV_FLOAT, sv_death_delay_left);
	clientstat(STAT_IS_DEAD, EV_FLOAT, sv_is_dead);
	clientstat(STAT_ZOOMSTAGE, EV_FLOAT, sv_zoomstage);
	clientstat(STAT_BLUE_SCORE, EV_FLOAT, sv_blue_score);
	clientstat(STAT_RED_SCORE, EV_FLOAT, sv_red_score);
	clientstat(STAT_MONEY, EV_FLOAT, sv_money);
	clientstat(STAT_CSARMOR, EV_FLOAT, sv_armor);
	clientstat(STAT_IN_BUYZONE, EV_FLOAT, sv_in_buyzone);
	clientstat(STAT_CAN_PLANT, EV_FLOAT, sv_can_plant_c4);
	clientstat(STAT_BOMB_PLANTED, EV_FLOAT, sv_bomb_planted);
	// Defuse progress (0..CFC4_DEFUSE_TIME), set per-tick by
	// C4_TickDefuseInteraction on the active defuser — drives HUD_DrawDefuseBar.
	// Without this registration the field never networks and the bar never shows.
	clientstat(STAT_DEFUSE_PROGRESS, EV_FLOAT, defuse_progress_stat);

	// nettest progression spine (Part 1): persistent XP / level + session XP.
	clientstat(STAT_XP, EV_FLOAT, sv_xp);
	clientstat(STAT_LEVEL, EV_FLOAT, sv_level);
	clientstat(STAT_XP_NEXT, EV_FLOAT, sv_xp_next);
	clientstat(STAT_PROG_SESSIONXP, EV_FLOAT, sv_sessionxp);
	Prog_DBInit();	// open the sqlite player store + ensure schema (once)

	// All custom cvars are registered from a single shared table —
	// edit shared/sh_cvar_table.qc CVar_Init() to change defaults or
	// add new cvars. The table is the source of truth for the auto-
	// generated data/allcommands.cfg too.
	CVar_Init();
	CVar_RegisterMine();

	// FTE engine pre-registers a few cvars with values that disagree
	// with the mod's intended defaults (e.g., sv_accelerate "10",
	// sv_maxspeed "320"). registercvar() above can't override an
	// already-registered cvar, so force-set the mod's defaults here.
	// data/server.cfg is applied immediately after this block, so admins
	// who want to override still get their value applied.
	cvar_set("sv_accelerate",    "5");
	cvar_set("sv_airaccelerate", "150");
	cvar_set("sv_maxspeed",      "270");
	cvar_set("sv_eye_height",    "56");
	cvar_set("sv_stamina",       "1");

	// mp_weaponweight + sv_wepswap_speed_transition: feed the speed-factor
	// blend in PM_ReadMovevars.  registercvar's default isn't reliably
	// reflected in cvar_string() across all FTE engine versions — if
	// cvar_string returns "" while client serverkeyfloat falls back to 1,
	// the two sides compute different mv_maxspeed and walk-speed diverges
	// (e.g. AK47 + weight=1 produced ~14 qu overshoot when stopping at
	// 850 ms ping until the user manually flipped the cvar).  Force-set
	// here so cvar_string is definitive before SV_UpdateMovementServerInfo
	// pushes via serverinfo.
	cvar_set("mp_weaponweight",            "1");
	cvar_set("sv_wepswap_speed_transition","0.15");

	// FTE engine clamps player v_angle[0] to [sv_minpitch, sv_maxpitch] in
	// sv_user.c; default range is [-70, 80] which feels limited for a
	// modern shooter (can't look at your feet, can't aim at high targets
	// from below). Open it up to the full ±90.  Empty string also works
	// — sv_user.c falls back to the -70/80 defaults — so we set the cvar
	// explicitly. Admins can still override via data/server.cfg.
	cvar_set("sv_minpitch",      "-90");
	cvar_set("sv_maxpitch",      "90");

	// Tickrate default — 64 Hz (CS-standard). FTE's engine baseline is
	// 60 Hz and older install configs may have 100 Hz cached from
	// prior defaults. data/server.cfg is applied immediately after this
	// block so admins can still override.
	cvar_set("sv_mintic",        "0.015625");
	cvar_set("sv_maxtic",        "0.015625");

	// Now apply persisted overrides from data/server.cfg directly.
	// The menu-generated file is a cvar snapshot, so reading it here
	// avoids relying on an engine-side `exec` path that may be deferred
	// or unavailable during first-map worldspawn.
	//
	// Note: engine CVAR_MAPLATCH vars like sv_cheats still cannot affect
	// the already-spawning first map from here; they need to be set
	// before the initial `map` command to apply immediately.
	SV_ApplyServerConfigFile();

	// Backdrop server must NEVER occupy 27500 — it blocks a real local/dedicated
	// server from binding it.  server.cfg just set sv_port (to 27500), which is
	// why the menu-launcher's earlier `sv_port 0` had no effect (the boot log
	// showed "Unable to bind to port 27500, bound to 27501").  Override it back
	// to 0 HERE — AFTER server.cfg has run — so the engine binds an OS-assigned
	// ephemeral port instead.  Real servers (sv_backdrop 0) keep their port.
	// sv_backdrop was consumed from sv_backdrop_pending earlier in this spawn.
	if (cvar("sv_backdrop"))
		cvar_set("sv_port", "0");

	// Bhop gamemode — force bhop-specific settings before entities spawn.
	// Door/button inertness is read directly from sv_gamemode in
	// sv_doors.qc func_button / func_door, so no separate flag cvar needed.
	if (cvar("sv_gamemode") == GAMEMODE_BHOP)
	{
		cvar_set("mp_falldamage", "0");
		cvar_set("mp_noblock", "1");
	}

	// Optional per-map overrides: maps/<mapname>.cfg sits next to the BSP
	// and is applied after the shared server snapshot, so map-specific
	// settings can override the pool-wide defaults.
	SV_ApplyMapConfigFile();

	// Force mapname serverinfo to the current map (engine may cache a stale value)
	localcmd(sprintf("serverinfo mapname \"%s\"\n", mapname));

	// NOTE: movement cvars are pushed by SV_UpdateMovementServerInfo() each
	// StartFrame rather than here, so the serverinfo path stays centralized.

	map_start_time = time;
	round_number = 1;
	round_phase = ROUND_PHASE_NONE;
	blue_team_score = 0;
	red_team_score = 0;
	money_last_round_phase = ROUND_PHASE_NONE;
	Money_ResetMatch();   // reset cash to mp_cashstart at match/map start
	buyzone_count = 0;    // func_buyzone entities re-count themselves on spawn
};

void() SpectatorConnect =
{	
};
