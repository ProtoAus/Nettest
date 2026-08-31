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
// in-game save path writes the same cfg/server.cfg shape as Create
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
	filestream f = fopen("cfg/maps.txt", FILE_READ);
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

// Sven accepts `globalmodellist` / `globalsoundlist` in EITHER worldspawn or the
// map's own maps/<name>.cfg, and the They Hunger campaign uses the second
// spelling EXCLUSIVELY: not one of the 20 th_*.bsp entity lumps carries
// globalmodellist, while th_ep1_01.cfg, th_escape.cfg and 30 other shipped cfgs
// name one.  Read as a plain cvar assignment (SV_ApplyConfigFile's fall-through
// below) the line became a junk user cvar and the pair table stayed empty — so
// every They Hunger map ran with a stock crowbar instead of the umbrella that
// models/hunger/hungerglobal.txt swaps in, and sv_sentences.qc's "does
// globalsoundlist mention hunger" test failed on the eight th_ep3_* maps.
//
// This CANNOT be done from MapCfgEquip_Token: SV_ApplyMapConfigFile() runs a few
// hundred lines BELOW precache_everything(), and a remap installed after the
// wholesale precache leaves the canonical model precached and the replacement
// not.  So the cfg is read a second time, here, at the moment the table is built.
//
// Returns the worldspawn value untouched when there is one (that string is the
// engine's, already zoned); otherwise a freshly zoned copy of the cfg value,
// because SV_ReadConfigValue hands back an argv() tempstring that would not
// survive the frame.  Neither is ever freed — the server reloads its progs per
// map, so there is nothing to leak into.
string(string key, string fromworld) SV_ResolveGlobalList =
{
	if (fromworld && fromworld != "")
		return fromworld;

	string v = SV_ReadConfigValue(sprintf("maps/%s.cfg", mapname), key);
	if (v == "")
		return "";

	return strzone(v);
};

// Apply a cfg-style cvar snapshot directly during worldspawn. Relying on
// an engine-side `exec` here proved unreliable on the first map in normal
// SSQC, while these files are simple cvar-assignment lists.
//
// ismapcfg: a Sven maps/<name>.cfg is two languages in one file — the cvar
// list this parser was written for, plus an equipment manifest (bare weapon
// classnames, ammo clip counts, starthealth/startarmor) that is not cvars at
// all and used to be silently dropped or turned into junk cvars.  With the
// flag set, each line is offered to MapCfgEquip_Token first; anything it does
// not claim falls through to exactly the behaviour below.  cfg/server.cfg
// passes FALSE and is completely unaffected.
void(string cfgpath, float ismapcfg) SV_ApplyConfigFile =
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

		// Equipment manifest, map cfg only.  Ahead of the cvar branches so a
		// claimed token can never also become a cvar.
		if (ismapcfg && MapCfgEquip_Token(cmd, (argc >= 2) ? argv(1) : "", argc))
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
	SV_ApplyConfigFile("cfg/server.cfg", FALSE);
};

void() SV_WriteServerConfigFile =
{
	filestream f = fopen("cfg/server.cfg", FILE_WRITE);
	if (f < 0)
	{
		print("sv_saveconfig: fopen cfg/server.cfg FAILED\n");
		return;
	}

	fputs(f, "// cfg/server.cfg — server settings (auto-generated)\n\n");

	float i;
	for (i = 0; i < sv_servercfg_cvars.length; i = i + 1)
	{
		string name = sv_servercfg_cvars[i];
		string val = cvar_string(name);
		if (name == "rcon_password" && val == "")
			val = cvar_string("sv_rcon_password_shadow");
		if (name == "rcon_password" && val == "")
			val = SV_ReadConfigValue("cfg/server.cfg", name);
		fputs(f, sprintf("set %s \"%s\"\n", name, val));
	}

	fclose(f);
	print("sv_saveconfig: wrote cfg/server.cfg\n");
};

void() SV_ApplyMapConfigFile =
{
	// Clear the previous map's manifest first — FTE keeps progs globals across a
	// map change, so without this a map with no cfg of its own would inherit the
	// last one's loadout.
	MapCfgEquip_Reset();
	SV_ApplyConfigFile(sprintf("maps/%s.cfg", mapname), TRUE);
	MapCfgEquip_Report();
};

void() RoundStart =
{
	float freezetime = cvar("mp_freezetime");

	// Prop Hunt: the freeze phase IS the hide phase — hiders run free while
	// seekers are locked+blindfolded (SH_RoundFreezeLocksPlayer gates per-team).
	// Uses its own duration so normal mp_freezetime is untouched.
	if (cvar("sv_gamemode") == GAMEMODE_PROPHUNT)
		freezetime = cvar("mp_ph_hidetime");

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

	// nettest server ragdoll: this is the single retire path (mp_deadbodies cap, respawn,
	// RoundRestart), so tear the corpse's authoritative ragdoll down here alongside it.
	if (corpse.sv_ragdoll_ent)
		Ragdoll_Free(corpse.sv_ragdoll_ent);

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

	// Prop Hunt: force-shuffle SEEKERS/HIDERS before the respawn loop below, so
	// spawns and loadouts see the final teams.  Self-gates on the gamemode.
	PropHunt_ShuffleTeams();

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

	// nettest: backstop-free any server ragdoll whose corpse was already gone (the corpse
	// retire above already freed the owned ones via the VisProxy_RetireCorpse hook).
	Ragdoll_SweepAll();

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

string sv_info_last_nocarry;          // sv_physprop_nocarry      — prop rider carry (shared pmove)
string sv_info_last_carry_maxspeed;   // sv_physprop_carry_maxspeed
string sv_info_last_shiftspeed;
string sv_info_last_maxspeed;
string sv_info_last_ph_prop_speed;    // mp_ph_prop_speed — disguised-prop move scale (shared pmove)
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
string sv_info_last_deastrafing;
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
// Carry limits.  CSQC pickup prediction reads these through W_CarryLimit, so they
// have to reach the client as serverinfo rather than a cvar() read.
string sv_info_last_maxprimary;
string sv_info_last_maxsecondary;
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
// sv_crowbar_charged_swing.  MANDATORY, not a runtime convenience: CSQC's
// hitclaim is what applies crowbar damage to another player, so if the key is
// never pushed the client falls back on its own CVAR_SIDE_BOTH default and a
// server running 0 would take full-damage claims forever.
string sv_info_last_crowbar_charged;
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
string sv_info_last_mp_flashlight;
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
	// Prop rider carry — read inside the shared pmove (PM_CheckPhysPropCarry), so the client can only
	// see it through serverinfo.  Without the push, CSQC falls back to the default and the predicted
	// carry disagrees with the server's every tick.
	sv_info_push_if_changed("sv_physprop_nocarry",        sv_info_last_nocarry);
	sv_info_push_if_changed("sv_physprop_carry_maxspeed", sv_info_last_carry_maxspeed);
	sv_info_push_if_changed("sv_shiftspeed",    sv_info_last_shiftspeed);
	sv_info_push_if_changed("sv_maxspeed",      sv_info_last_maxspeed);
	sv_info_push_if_changed("mp_ph_prop_speed", sv_info_last_ph_prop_speed);	// disguised-prop move scale — read in the shared pmove, so CSQC needs it via serverinfo

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
	sv_info_push_if_changed("sv_deastrafing",   sv_info_last_deastrafing);	// Source airstrafe penalty; CSQC pmove reads it via serverkeyfloat so prediction matches
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
	// The flashlight is drawn entirely in CSQC (cl_flashlight.qc), so the only
	// way a server can switch it off is to publish the permission and have the
	// client read it here rather than from its own cvar.  Pushed on change like
	// the rest, which matters because trigger_setcvar flips it mid-map:
	// hl_c17 and hl_c18 both go dark this way.
	sv_info_push_if_changed("mp_flashlight",    sv_info_last_mp_flashlight);
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
	// Multi-carry limits — CSQC needs these to predict a pickup at the boundary.
	sv_info_push_if_changed("mp_maxprimary",        sv_info_last_maxprimary);
	sv_info_push_if_changed("mp_maxsecondary",      sv_info_last_maxsecondary);
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
	sv_info_push_if_changed("sv_crowbar_charged_swing", sv_info_last_crowbar_charged);
};

// Post-config fixup: if the persisted cfg/server.cfg snapshot leaves any
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

// ---------------------------------------------------------------------------
// sv_hlequip_test  —  fire each of the four HL equipment weapons once
// ---------------------------------------------------------------------------
// A satchel, a tripmine, a snark and a hivehand are all "press the button and
// something is supposed to exist in the world afterwards" weapons, and every
// one of the four has a different reason it might not: the satchel spawns from
// a throw, the tripmine from a traceline that must find a surface, the snark
// from a traceline that must find EMPTY space, and the hornet from neither.
// Reading the resulting entity counts is the difference between "it compiled"
// and "it works", and none of it needs a human at the keyboard.
//
// Runs the SSQC fire function directly, which is the same entry point the
// button takes (sv_weapons.qc's button0/button1 dispatch calls self.fire /
// self.altfire), so this is not a test-only code path.
float hlequip_test_stage;
float hlequip_test_next;

void() W_HLEquipTest =
{
    if (!cvar("sv_hlequip_test"))
        return;
    if (time < hlequip_test_next)
        return;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
        return;

    hlequip_test_next = time + 2;
    hlequip_test_stage = hlequip_test_stage + 1;

    entity oldself = self;
    self = p;

    if (hlequip_test_stage == 1)
    {
        self.ammo_satchel = MAX_AMMO_SATCHEL;
        self.slot_utility = WEP_SATCHEL;
        W_SatchelEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_SatchelFire();
    }
    else if (hlequip_test_stage == 2)
    {
        // The +attack2 detonator.  This comment used to say the detonator
        // "cannot be reached by pressing +attack" — true when written, false
        // now: +attack detonates once you have nothing left to throw.  Both
        // routes are covered in depth by sv_satchel_test below; this stage
        // keeps exercising the HL one so a regression there still shows up in
        // the equip test's satchels=0 assertion.
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_SatchelAltFire();
    }
    else if (hlequip_test_stage == 3)
    {
        self.ammo_tripmine = MAX_AMMO_TRIPMINE;
        self.slot_utility = WEP_TRIPMINE;
        W_TripmineEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        // Aim slightly DOWN and forward, not straight at the floor.  Aiming at
        // your own feet places a mine whose beam runs up through your own body,
        // so it arms and instantly detonates - which is correct HL behaviour and
        // exactly why nobody does it, but it tests the wrong thing.
        // 45 degrees down puts the mine on the floor about 64 units AHEAD of
        // the player, so its upward beam does not pass through them.  Aiming
        // at your own feet arms a mine inside your own hull, which detonates
        // instantly - correct, and not what this is testing.
        self.v_angle = '45 0 0';
        W_TripmineFire();
    }
    else if (hlequip_test_stage == 4)
    {
        self.ammo_snark = MAX_AMMO_SNARK;
        self.slot_utility = WEP_SNARK;
        W_SnarkEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        self.v_angle = '0 0 0';
        W_SnarkFire();
    }
    else if (hlequip_test_stage == 5)
    {
        self.ammo_hornet = MAX_AMMO_HORNET;
        self.slot_primary = WEP_HORNETGUN;
        W_HGunEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_HGunFire();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        self.hgun_alt_finished = 0;
        W_HGunAltFire();
    }
    else
    {
        cvar_set("sv_hlequip_test", "0");

        // Assigned one per line on purpose.  QC locals live in the progs
        // globals and are NOT zeroed on entry, and a comma-separated
        // declaration only applies the initialiser to the first name - so the
        // single-line version reported a leftover beam count from a previous
        // call and sent me hunting a tripmine bug that did not exist.
        float n_satchel; float n_mine; float n_snark; float n_hornet; float n_beam;
        n_satchel = 0; n_mine = 0; n_snark = 0; n_hornet = 0; n_beam = 0;
        entity e = findchain(classname, "monster_satchel");
        while (e) { n_satchel = n_satchel + 1; e = e.chain; }
        e = findchain(classname, "monster_tripmine");
        while (e) { n_mine = n_mine + 1; e = e.chain; }
        e = findchain(classname, "monster_snark");
        while (e) { n_snark = n_snark + 1; e = e.chain; }
        e = findchain(classname, "hornet");
        while (e) { n_hornet = n_hornet + 1; e = e.chain; }
        e = findchain(classname, "tripmine_beam");
        while (e)
        {
            n_beam = n_beam + 1;
            dprint(sprintf("[hlequip] leftover beam #%g org=%v owner=\"%s\" active=%g\n",
                           n_beam, e.origin, e.owner.classname, e.ebeam_active));
            e = e.chain;
        }

        // A satchel count of 0 here is the PASS for the satchel: stage 1 threw
        // one and stage 2 blew it up.  Everything else should still be alive.
        // Order matters and I got it wrong once: the label list and the
        // argument list have to agree, or a live snark reads as a leaked beam
        // and you go looking for a leak that was never there.
        dprint(sprintf("[hlequip] satchels=%g (0 = thrown AND detonated) mines=%g snarks=%g hornets=%g beams=%g\n",
                       n_satchel, n_mine, n_snark, n_hornet, n_beam));
        dprint(sprintf("[hlequip] tripmine beam ticks=%g\n", tripmine_dbg_beamticks));
        dprint(sprintf("[hlequip] ammo left: satchel=%g tripmine=%g snark=%g hornet=%g\n",
                       p.ammo_satchel, p.ammo_tripmine, p.ammo_snark, p.ammo_hornet));
    }

    self = oldself;
};


// ---------------------------------------------------------------------------
// sv_satchel_test  —  can you still set off the charges you have thrown?
// ---------------------------------------------------------------------------
// The reported bug was "I threw a satchel and +attack does not detonate it".
// The button mapping turned out to be correct and match Half-Life; what was
// broken was that the RIGHT button gave no feedback, and that throwing your
// last charge disowned the weapon so the charges could never be set off at all.
//
// Stage 2 is the one that fails on the old code: W_UtilityPlayerHasWeapon was
// `ammo_satchel > 0`, so a player at zero ammo with charges live did not own a
// satchel, W_SelectWeapon refused it, and the charges were stranded.
float satchel_test_stage;
float satchel_test_next;
float satchel_test_bad;
entity satchel_test_who;      // the player the run started on
float  satchel_test_restarts; // bounded, so a lethal map cannot loop forever

float(entity p) SatchelTest_LiveCount =
{
    float n = 0;
    entity e = findchain(classname, "monster_satchel");
    while (e)
    {
        if (e.owner == p) n = n + 1;
        e = e.chain;
    }
    return n;
};

// ===========================================================================
//  sv_inventory_test — Sven item_inventory + the InventoryRules gate
// ===========================================================================
// Written because almost everything this patch claims is a CLAIM about a chain
// that no headless run can otherwise reach: the map's own drop-off pads need a
// player standing in a brush volume holding a specific entity, and the harness
// has no hands.  So the test builds its own items and its own rules entity and
// drives the real functions — Inv_Collect, Inv_Drop, Inv_Gate — rather than
// re-deriving what they ought to do.
//
// The one thing it deliberately does NOT test is the +use route itself.  That
// needs a player aiming at something, and this mod's own note about the
// headless client (no harness player is both grounded and unicast-reachable)
// says that is not honestly reachable here.  What IS covered is everything the
// press would go on to do.
float inv_test_bad;
float inv_test_done;
float inv_test_stage;
float inv_test_next;
entity inv_test_a, inv_test_b, inv_test_rules;

void(string label, float got, float want) InvTest_Expect =
{
    if (got == want)
        dprint(sprintf("[invtest] %s: got=%g want=%g PASS\n", label, got, want));
    else
    {
        inv_test_bad = inv_test_bad + 1;
        dprint(sprintf("[invtest] %s: got=%g want=%g FAIL\n", label, got, want));
    }
};

// Build one item_inventory the way a BSP would: set the keys, then call the
// real spawn function.  Going through item_inventory() rather than hand-filling
// the fields is the point — it is what makes the sequence resolution, the hull
// and the think wiring part of what is under test.
entity(string nm, string grp, string cant, float wt, string spd, vector org) InvTest_MakeItem =
{
    entity it = spawn();
    it.classname     = "item_inventory";
    it.model         = "models/th_escape/item_carbattery.mdl";
    // USE_ONLY for the same reason th_escape sets it, and one more: without it
    // these fixtures are SOLID_TRIGGER and the per-frame touch sweep in
    // SV_CheckTouchTriggers (sv_use.qc:474) would collect them for whichever
    // player wandered past BEFORE the staged test got to try, turning stage 1
    // into a coin toss.
    it.spawnflags    = PICKUP_SF_USE_ONLY;
    it.item_name     = nm;
    it.item_group    = grp;
    it.item_name_canthave = cant;
    it.weight        = ftos(wt);
    it.effect_speed  = spd;
    it.effect_block_weapons = TRUE;
    it.return_timelimit = "1";        // short, so the return is testable in one run
    it.display_name  = nm;
    it.origin        = org;
    entity oldself = self;
    self = it;
    item_inventory();
    self = oldself;
    return it;
};

void() Inv_SelfTest =
{
    if (!cvar("sv_inventory_test")) return;
    if (inv_test_done)              return;
    if (time < 3)                   return;   // let the map settle, as the other tests do
    if (time < inv_test_next)       return;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p) return;

    inv_test_next = time + 0.5;

    if (inv_test_stage == 0)
    {
        // Two items in one group, each forbidding the other — th_escape's
        // one-quest-item-at-a-time rule, which is the whole reason
        // item_name_canthave exists on that map.
        // Spawned at the player's own feet, which is by definition a legal spot
        // on any map — '0 0 0' is inside solid on some and in open sky on
        // others, and neither makes for a stable fixture.
        inv_test_a = InvTest_MakeItem("test_itm1", "test_items", "test_itm2", 16, "50.0",  p.origin);
        inv_test_b = InvTest_MakeItem("test_itm2", "test_items", "test_itm1", 16, "100.0", p.origin);

        inv_test_rules = spawn();
        inv_test_rules.classname = "trigger_once";
        inv_test_rules.targetname = "invtest_gate";

        InvTest_Expect("item spawns idle and collectable", inv_test_a.inv_state, INV_IDLE);
        InvTest_Expect("holder starts empty",              p.inv_head != world,   FALSE);
        inv_test_stage = 1;
        return;
    }

    if (inv_test_stage == 1)
    {
        // Call results go into locals before being asserted, and the dprint
        // below reports the whole post-collect state in one line.
        //
        // Both exist because of how the first run of this test failed, which is
        // worth recording: it reported "collect succeeds: got=0" and "item is
        // now held: got=0" while simultaneously reporting weight 16 and weapons
        // blocked — a set of results with no consistent reading, and one that
        // invites blaming the assertion machinery.
        //
        // The machinery was fine.  The FIXTURE was collecting itself: the test
        // items spawned SOLID_TRIGGER with no spawnflags, and the per-frame
        // sweep in SV_CheckTouchTriggers (sv_use.qc:474) fires .touch for any
        // SOLID_TRIGGER near a player — so a bot picked the SECOND item up
        // during the half-second between stage 0 and stage 1.  Every number
        // then follows: item A refused because item_name_canthave listed the
        // item already held, the speed read 100 because it was B's effect_speed
        // and not A's, and the weight was real because something genuinely was
        // being carried.  InvTest_MakeItem now sets PICKUP_SF_USE_ONLY, which
        // is what th_escape's own items set and what closes that door.
        float got_collect = Inv_Collect(inv_test_a, p);
        float got_state   = inv_test_a.inv_state;
        float got_chain   = (p.inv_head == inv_test_a);
        float got_weight  = p.inv_weight;

        dprint(sprintf("[invtest] after collect: ret=%g state=%g weight=%g spd=%g blk=%g\n",
                       got_collect, got_state, got_weight,
                       p.pm_inv_speed_pct, p.pm_inv_blockfire));

        InvTest_Expect("collect succeeds",        got_collect, TRUE);
        InvTest_Expect("item is now held",        got_state,   INV_HELD);
        InvTest_Expect("holder chain has it",     got_chain,   TRUE);
        InvTest_Expect("weight accrued",          got_weight,  16);
        // The two that carry th_escape: half speed, no shooting.  Read off the
        // REPLICATED fields, because those are what pmove and the fire gate
        // actually consult on both sides.
        InvTest_Expect("effect_speed replicated", p.pm_inv_speed_pct,         50);
        InvTest_Expect("weapons blocked",         p.pm_inv_blockfire,         TRUE);
        inv_test_stage = 2;
        return;
    }

    if (inv_test_stage == 2)
    {
        // item_name_canthave: the second item must refuse while the first is held.
        float r_second = Inv_Collect(inv_test_b, p);
        float s_second = inv_test_b.inv_state;
        InvTest_Expect("canthave blocks 2nd item", r_second, FALSE);
        InvTest_Expect("2nd item still idle",      s_second, INV_IDLE);

        // The gate, in both directions, on the real entry point.
        inv_test_rules.item_name_required = "test_itm1";
        float r_hold = Inv_RulesPass(inv_test_rules, p);
        InvTest_Expect("gate passes for holder",   r_hold, TRUE);
        inv_test_rules.item_name_required = "test_itm_absent";
        float r_nohold = Inv_RulesPass(inv_test_rules, p);
        InvTest_Expect("gate blocks non-holder",   r_nohold, FALSE);

        // item_group_required_num: "carrying any one of the group", which is how
        // th_escape arms its ambushes.
        inv_test_rules.item_name_required  = "";
        inv_test_rules.item_group_required = "test_items";
        inv_test_rules.item_group_required_num = 1;
        float r_grp1 = Inv_RulesPass(inv_test_rules, p);
        InvTest_Expect("group_required_num 1 passes", r_grp1, TRUE);
        // _num 0 means "every item that EXISTS in the group" — two do, one is
        // held, so this must FAIL.  That asymmetry against the canthave side is
        // the easiest thing in the whole system to get backwards.
        inv_test_rules.item_group_required_num = 0;
        float r_grp0 = Inv_RulesPass(inv_test_rules, p);
        InvTest_Expect("group_required_num 0 needs all", r_grp0, FALSE);

        // canthave _num 0 means "not even one", NOT "all of them".
        inv_test_rules.item_group_required = "";
        inv_test_rules.item_group_required_num = 0;
        inv_test_rules.item_group_canthave = "test_items";
        inv_test_rules.item_group_canthave_num = 0;
        float r_cant0 = Inv_RulesPass(inv_test_rules, p);
        InvTest_Expect("group_canthave_num 0 blocks one", r_cant0, FALSE);
        inv_test_rules.item_group_canthave = "";
        inv_test_stage = 3;
        return;
    }

    if (inv_test_stage == 3)
    {
        // pass_destroy_item_name — how the battery leaves your hands at the truck.
        inv_test_rules.item_name_required     = "test_itm1";
        inv_test_rules.pass_destroy_item_name = "test_itm1";
        float r_gate  = Inv_Gate(inv_test_rules, p);
        float r_empty = (p.inv_head == world);
        InvTest_Expect("gate passes at the drop-off", r_gate,  TRUE);
        InvTest_Expect("delivered item destroyed",    r_empty, TRUE);
        InvTest_Expect("weight released",             p.inv_weight,       0);
        InvTest_Expect("speed penalty lifted",        p.pm_inv_speed_pct, 100);
        InvTest_Expect("fire block lifted",           p.pm_inv_blockfire, FALSE);
        inv_test_rules.pass_destroy_item_name = "";
        inv_test_rules.item_name_required     = "";
        inv_test_stage = 4;
        return;
    }

    if (inv_test_stage == 4)
    {
        // Drop and return.  return_timelimit is 1 s on these test items.
        float r_col  = Inv_Collect(inv_test_b, p);
        float r_drop = Inv_Drop(inv_test_b, p, FALSE, FALSE);
        float s_drop = inv_test_b.inv_state;
        float r_arm  = (inv_test_b.inv_return_at > 0);
        InvTest_Expect("collect 2nd item", r_col,  TRUE);
        InvTest_Expect("voluntary drop",   r_drop, TRUE);
        InvTest_Expect("dropped state",    s_drop, INV_DROPPED);
        InvTest_Expect("return armed",     r_arm,  TRUE);
        inv_test_next  = time + 1.5;      // outlive the return timer
        inv_test_stage = 5;
        return;
    }

    if (inv_test_stage == 5)
    {
        float s_home  = inv_test_b.inv_state;
        // "Went home" is asserted as inv_moved rather than as an origin
        // compare: Inv_Materialise restores MOVETYPE_TOSS, so by the time this
        // stage runs the item has had up to half a second to settle onto
        // whatever is under it and its origin legitimately differs from
        // inv_home.  inv_moved is the flag Inv_Return actually clears, and it
        // is what every item_name_not_moved rule reads.
        float m_home  = inv_test_b.inv_moved;
        InvTest_Expect("returned home",     s_home, INV_IDLE);
        InvTest_Expect("moved flag cleared", m_home, FALSE);

        // The hazard the header calls out: a multi_manager "#2" slot removes a
        // HELD item outright, and the holder must not keep paying for it.
        // th_escape does this on every delivery and at map load.
        float r_recol = Inv_Collect(inv_test_b, p);
        InvTest_Expect("re-collect for the kill test", r_recol, TRUE);
        remove(inv_test_b);
        Inv_Prune(p);
        float r_clean = (p.inv_head == world);
        InvTest_Expect("chain survives a killed item", r_clean, TRUE);
        InvTest_Expect("weight recovered",             p.inv_weight,        0);
        InvTest_Expect("effects recovered",            p.pm_inv_speed_pct,  100);

        if (inv_test_a)     if (!wasfreed(inv_test_a))     remove(inv_test_a);
        if (inv_test_rules) if (!wasfreed(inv_test_rules)) remove(inv_test_rules);

        // Everything above is synthetic — items this test built, on a rules
        // entity this test built.  That proves the LOGIC and proves nothing
        // about whether a real map's keys ever reach it, which is the other
        // half and the half that silently broke for years: the fields only
        // arrived at all once they were declared, and before that every one of
        // them was being swallowed into a junk mm_slot.
        //
        // So: if this map has entities carrying inventory rules, count them and
        // say so.  Conditional rather than asserted, because it has to be
        // harmless on the 130 maps that carry none.
        float real_rules = 0, real_items = 0, real_destroy = 0;
        entity re = nextent(world);
        while (re)
        {
            if (re.classname == "item_inventory")
                if (re.item_name != "" && re.item_name)
                    real_items = real_items + 1;
            if (re.item_name_required != "" && re.item_name_required)
                real_rules = real_rules + 1;
            if (re.pass_destroy_item_name != "" && re.pass_destroy_item_name)
                real_destroy = real_destroy + 1;
            re = nextent(re);
        }
        if (real_items || real_rules)
            dprint(sprintf("[invtest] map keys bound: %g item_inventory with a name, "
                           "%g entities with item_name_required, %g with pass_destroy_item_name\n",
                           real_items, real_rules, real_destroy));

        dprint(sprintf("[invtest] BAD=%g\n", inv_test_bad));
        inv_test_done = TRUE;
        cvar_set("sv_inventory_test", "0");
    }
};

// ===========================================================================
//  sv_thescape_test — th_escape's four missing classes and its map script
// ===========================================================================
// Same reason Inv_SelfTest exists: everything this patch adds is a claim about
// a chain a headless run cannot otherwise reach.  The truck needs a repaired
// engine and a driver, the ambush triggers need somebody to walk into a brush
// volume and look the wrong way, and the timer needs eight minutes.  So the
// test drives the REAL functions — FuncTrackVehicle_Accel, THEsc_Call,
// PCheck_Test, trigger_look_think — against fixtures it builds itself.
//
// Runs only on a map whose cfg names th_escape's script, because five of the
// six stages assert against that map's own entities.  It is destructive to the
// live script state (it arms and expires the timer), which is fine on a
// dedicated test run and is why it disarms the cvar when it finishes.
//
// NOT covered, for the same honest reason the inventory test lists: the +use
// press that mounts the truck.  TrainControls_TryUse needs a player who is
// FL_ONGROUND inside the control box, and no harness player is both grounded
// and reachable.  What IS covered is the control box the press tests against,
// the gate that keeps the press from working before VehicleStarted, and
// everything the throttle does afterwards.
float thesc_test_bad;
float thesc_test_done;
float thesc_test_stage;
float thesc_test_next;
entity thesc_test_probe;
entity thesc_test_vol;
float  thesc_test_fires;
float  thesc_test_last_ut;

void(string label, float got, float want) THEscTest_Expect =
{
    if (got == want)
        dprint(sprintf("[thesctest] %s: got=%g want=%g PASS\n", label, got, want));
    else
    {
        thesc_test_bad = thesc_test_bad + 1;
        dprint(sprintf("[thesctest] %s: got=%g want=%g FAIL\n", label, got, want));
    }
};

void() THEscTest_ProbeUse =
{
    thesc_test_fires   = thesc_test_fires + 1;
    thesc_test_last_ut = sub_use_type;
};

entity() THEscTest_Probe =
{
    if (thesc_test_probe && !wasfreed(thesc_test_probe))
        return thesc_test_probe;
    thesc_test_probe            = spawn();
    thesc_test_probe.classname  = "thesc_probe";
    thesc_test_probe.targetname = "thesc_probe_t";
    thesc_test_probe.use        = THEscTest_ProbeUse;
    thesc_test_probe.movetype   = MOVETYPE_NONE;
    thesc_test_probe.solid      = SOLID_NOT;
    return thesc_test_probe;
};

// Build a brush volume around `p` by borrowing a real BSP brush model and
// moving it.  Going through the class's own spawn function rather than
// hand-filling fields is deliberate — the spawnflag handling, the think install
// and the key defaulting are part of what is under test.
entity(string cls, string brushmodel, entity p) THEscTest_MakeVolume =
{
    entity v = spawn();
    v.classname = cls;
    v.model     = brushmodel;
    v.target    = "thesc_probe_t";
    return v;
};

void(entity v, entity p) THEscTest_CentreOn =
{
    vector c = (v.mins + v.maxs) * 0.5;
    setorigin(v, p.origin - c);
};

void() THEsc_SelfTest =
{
    if (!cvar("sv_thescape_test")) return;
    if (thesc_test_done)           return;
    if (time < 3)                  return;
    if (time < thesc_test_next)    return;

    if (!MapScript_IsTHEscape())
    {
        dprint("[thesctest] this map does not name th_escape's script — skipping\n");
        thesc_test_done = TRUE;
        cvar_set("sv_thescape_test", "0");
        return;
    }

    thesc_test_next = time + 0.5;

    // Hoisted, because QC locals are FUNCTION-scoped: a second `entity p` in a
    // later branch is a duplicate definition, not a shadow.
    entity ts_oldself, ts_p, ts_v;
    entity veh = FuncTrackVehicle_Find("veh1_drivable");

    if (thesc_test_stage == 0)
    {
        // --- the vehicle exists, spawned cold, and is parked on its track ---
        THEscTest_Expect("vehicle found", (veh != world) ? 1 : 0, 1);
        if (veh == world)
        {
            thesc_test_bad = thesc_test_bad + 1;
            thesc_test_stage = 90;
            return;
        }

        THEscTest_Expect("placed on ccc_01",
                         (veh.train_target != world && veh.train_target.targetname == "ccc_01") ? 1 : 0, 1);
        THEscTest_Expect("engine cold", veh.tv_state, TV_STATE_OFF);
        THEscTest_Expect("controls locked",
                         (veh.spawnflags & TT_NO_USERCONTROL) ? 1 : 0, 1);
        // Sven's Spawn() forces these three on regardless of the mapper.
        THEscTest_Expect("KEEPRUNNING|STARTOFF|KEEPSPEED forced",
                         ((veh.spawnflags & (TV_SF_KEEPRUNNING | TV_SF_STARTOFF | TV_SF_KEEPSPEED))
                          == (TV_SF_KEEPRUNNING | TV_SF_STARTOFF | TV_SF_KEEPSPEED)) ? 1 : 0, 1);
        THEscTest_Expect("max speed", veh.tt_maxspeed, 250);
        THEscTest_Expect("acceleration clamped 1..10", veh.acceleration, 10);
        THEscTest_Expect("live speed parked", veh.speed, 0);

        // The control box the +use press tests against.  Hand-computed from the
        // .bsp: brush *470 spans -688 1235 -466 .. -620 1288 -400 and the truck
        // is authored at -630 1281 -496, so HL's offset puts the cab inside the
        // truck hull (local x -154..172, y -54..58, z -2..120).  FTE inflates
        // brush bounds by one unit, hence the tolerance.
        THEscTest_Expect("cab box inside hull (x)",
                         (veh.tt_ctrl_mins_x >= -160 && veh.tt_ctrl_maxs_x <= 178) ? 1 : 0, 1);
        THEscTest_Expect("cab box inside hull (y)",
                         (veh.tt_ctrl_mins_y >= -60 && veh.tt_ctrl_maxs_y <= 64) ? 1 : 0, 1);
        THEscTest_Expect("cab box inside hull (z)",
                         (veh.tt_ctrl_mins_z >= -8 && veh.tt_ctrl_maxs_z <= 126) ? 1 : 0, 1);
        // The bug this replaced: measuring against the LIVE origin put the box
        // ~2300 units out.  Assert the authored origin was actually cached.
        THEscTest_Expect("authored origin cached",
                         (veh.tt_authored_origin != veh.origin) ? 1 : 0, 1);

        // A player must NOT be able to take the wheel yet.
        entity anyp = player_chain_head;
        if (anyp)
            THEscTest_Expect("undriveable before VehicleStarted",
                             TrainControls_PlayerInControls(anyp, veh) ? 1 : 0, 0);

        thesc_test_stage = 1;
        return;
    }

    if (thesc_test_stage == 1)
    {
        // --- the map script recognises all 17 names --------------------------
        float known = 0;
        if (MapScript_Call("SetCharacters"))       known = known + 1;
        if (MapScript_Call("EquipCharacters"))     known = known + 1;
        if (MapScript_Call("TargetItemBattery"))   known = known + 1;
        if (MapScript_Call("TargetItemGasCan"))    known = known + 1;
        if (MapScript_Call("TargetItemToolbox"))   known = known + 1;
        if (MapScript_Call("AllItemsDroppedOff"))  known = known + 1;
        if (MapScript_Call("ReadGameCounter"))     known = known + 1;
        if (MapScript_Call("NormalDifficulty"))    known = known + 1;
        if (MapScript_Call("NightmareDifficulty")) known = known + 1;
        if (MapScript_Call("AbortGame"))           known = known + 1;
        if (MapScript_Call("GameOutro"))           known = known + 1;
        if (MapScript_Call("ShowSurvivors"))       known = known + 1;
        if (MapScript_Call("ShowLosers"))          known = known + 1;
        if (MapScript_Call("VehicleIgnitionOn"))   known = known + 1;
        if (MapScript_Call("VehicleStarted"))      known = known + 1;
        if (MapScript_Call("EndGame"))             known = known + 1;
        // StartCharacters LAST: it is the one that arms the timer, and stage 3
        // measures that.  The rest above are safe to call out of order because
        // every one of them either early-outs on the gamestate or is idempotent.
        if (MapScript_Call("StartCharacters"))     known = known + 1;
        THEscTest_Expect("all 17 script functions recognised", known, 17);

        // Case folding, and a name that must NOT be claimed.
        THEscTest_Expect("case-insensitive", MapScript_Call("startcharacters") ? 1 : 0, 1);
        THEscTest_Expect("unknown name rejected", MapScript_Call("NoSuchFunction") ? 1 : 0, 0);

        // VehicleIgnitionOn / VehicleStarted above ran while the gamestate was
        // still NEW, so both were recognised-but-inert (that gate is Sven's).
        // The engine must still be cold.
        THEscTest_Expect("ignition inert before the run starts", veh.tv_state, TV_STATE_OFF);

        thesc_test_stage = 2;
        return;
    }

    if (thesc_test_stage == 2)
    {
        // --- ignition, now that StartCharacters has set RUNNING --------------
        MapScript_Call("VehicleIgnitionOn");
        // Starting() is scheduled 1.4 s out on .ltime; give it two seconds.
        thesc_test_next  = time + 2.0;
        thesc_test_stage = 3;
        return;
    }

    if (thesc_test_stage == 3)
    {
        THEscTest_Expect("engine cranking after ignition", veh.tv_state, TV_STATE_CRANKING);
        THEscTest_Expect("still locked while cranking",
                         (veh.spawnflags & TT_NO_USERCONTROL) ? 1 : 0, 1);

        // ~20 move ticks have run since ignition, every one of them with
        // TT_NO_USERCONTROL and KEEPSPEED both set.  The accelerator decay must
        // still be LIVE: "control loss" means losing control you had, and a
        // cranking engine has not handed any out yet.  Latching it here would
        // leave the truck holding whatever speed you last asked for, for the
        // rest of the map.  See FuncTrackVehicle_CheckControlLoss.
        THEscTest_Expect("decay still live after ignition",
                         (veh.tv_accel_decay >= 0) ? 1 : 0, 1);

        MapScript_Call("VehicleStarted");
        THEscTest_Expect("running after VehicleStarted", veh.tv_state, TV_STATE_RUNNING);
        THEscTest_Expect("controls released",
                         (veh.spawnflags & TT_NO_USERCONTROL) ? 1 : 0, 0);

        // --- the accelerator ladder -----------------------------------------
        veh.speed           = 0;
        veh.tv_accel_decay  = 0;
        float i;
        for (i = 0; i < 400; i = i + 1)
            FuncTrackVehicle_Accel(veh, 1);
        THEscTest_Expect("accelerates to the cap", (veh.speed == veh.tt_maxspeed) ? 1 : 0, 1);
        THEscTest_Expect("moving", (veh.train_state != 0) ? 1 : 0, 1);

        for (i = 0; i < 400; i = i + 1)
            FuncTrackVehicle_Accel(veh, -1);
        // The brake table's reachable rungs oscillate around -0.22 of maximum
        // rather than reaching the -0.35 clamp; see the note in
        // FuncTrackVehicle_Accel about the `-= -0.0175` in the source.
        THEscTest_Expect("reverses",
                         (veh.speed < 0) ? 1 : 0, 1);
        THEscTest_Expect("reverse self-limits above the -0.35 clamp",
                         (veh.speed > veh.tt_maxspeed * -0.35) ? 1 : 0, 1);

        // Strafe deltas are discarded by the source's `delta < 10` gate.
        float before = veh.speed;
        FuncTrackVehicle_Accel(veh, 20);
        FuncTrackVehicle_Accel(veh, 30);
        THEscTest_Expect("strafe is a no-op", (veh.speed == before) ? 1 : 0, 1);

        // --- the decay -------------------------------------------------------
        veh.speed          = 100;
        veh.tv_accel_decay = time - 1;         // pedal released a second ago
        ts_oldself = self;
        self = veh;
        FuncTrackVehicle_ApplyDecay(1.0);      // one second of coasting
        self = ts_oldself;
        THEscTest_Expect("coasts down 40 u/s^2", veh.speed, 60);

        // DISABLE_TRAIN + KEEPSPEED kills the decay for good.
        veh.spawnflags = veh.spawnflags | TT_NO_USERCONTROL;
        self = veh;
        FuncTrackVehicle_CheckControlLoss();
        FuncTrackVehicle_ApplyDecay(1.0);
        self = ts_oldself;
        THEscTest_Expect("decay disabled by control loss", veh.tv_accel_decay, -1);
        THEscTest_Expect("speed survives the path handover", veh.speed, 60);

        // Park it again so a follow-on run does not find a rolling truck.
        veh.speed = 0;

        thesc_test_stage = 4;
        return;
    }

    if (thesc_test_stage == 4)
    {
        // --- the escape timer ------------------------------------------------
        // StartCharacters armed the real one for 8 or 9 minutes; re-arm it short
        // so the fire is observable, at a target only this test owns.
        THEsc_SetTimerTarget(2, "thesc_probe_t");
        THEsc_SetWarningTarget(1, "thesc_probe_t");
        THEscTest_Probe();
        thesc_test_fires = 0;
        THEsc_ToggleTimer(FALSE);
        THEsc_ToggleTimer(TRUE);

        thesc_test_next  = time + 3.5;
        thesc_test_stage = 5;
        return;
    }

    if (thesc_test_stage == 5)
    {
        // The warning at 1 s left and the expiry at 0 are two separate fires.
        THEscTest_Expect("timer fired warning + expiry", thesc_test_fires, 2);
        THEscTest_Expect("timer hidden after expiry", thesc_timer_active, 0);

        thesc_test_stage = 6;
        return;
    }

    if (thesc_test_stage == 6)
    {
        // --- trigger_playercheck ---------------------------------------------
        ts_p = player_chain_head;
        while (ts_p && (ts_p.health <= 0 || ts_p.solid == SOLID_NOT))
            ts_p = ts_p.player_chain_next;

        if (!ts_p)
        {
            dprint("[thesctest] no live player — skipping the two volume triggers\n");
            thesc_test_stage = 9;
            return;
        }

        THEscTest_Probe();
        ts_v = THEscTest_MakeVolume("trigger_playercheck", "*161", ts_p);
        ts_v.mode       = PCHECK_CMP_EQUALS;
        ts_v.threshold  = 0;
        ts_v.interval   = "0.5";
        ts_v.spawnflags = 0;                 // start ON so the think installs
        ts_oldself = self;
        self = ts_v;
        trigger_playercheck();
        self = ts_oldself;
        THEscTest_CentreOn(ts_v, ts_p);
        thesc_test_vol = ts_v;

        THEscTest_Expect("playercheck enabled at spawn", ts_v.pcheck_enabled, 1);
        THEscTest_Expect("interval read through the string", PCheck_Interval(ts_v), 0.5);

        thesc_test_fires = 0;
        PCheck_Test(ts_v);
        // A player IS inside, and the rule is "exactly zero" — so the first
        // evaluation must latch FALSE and fire USE_OFF.
        THEscTest_Expect("occupied volume fires once", thesc_test_fires, 1);
        THEscTest_Expect("...as USE_OFF", thesc_test_last_ut, USE_OFF);

        // Nothing changed: no second fire.  This is the edge filter.
        PCheck_Test(ts_v);
        THEscTest_Expect("no re-fire while unchanged", thesc_test_fires, 1);

        // Move the volume off the player: the count drops to zero and the
        // spawner arms.
        setorigin(ts_v, ts_p.origin + '4096 0 0');
        PCheck_Test(ts_v);
        THEscTest_Expect("empty volume arms the spawner", thesc_test_fires, 2);
        THEscTest_Expect("...as USE_ON", thesc_test_last_ut, USE_ON);
        THEscTest_Expect("count is right", PCheck_CountInside(ts_v), 0);

        thesc_test_stage = 7;
        return;
    }

    if (thesc_test_stage == 7)
    {
        ts_p = player_chain_head;
        while (ts_p && (ts_p.health <= 0 || ts_p.solid == SOLID_NOT))
            ts_p = ts_p.player_chain_next;
        if (!ts_p) { thesc_test_stage = 9; return; }

        if (thesc_test_vol && !wasfreed(thesc_test_vol))
            remove(thesc_test_vol);

        // --- trigger_look -----------------------------------------------------
        ts_v = THEscTest_MakeVolume("trigger_look", "*161", ts_p);
        ts_v.difference  = "130";
        ts_v.trigger     = LOOK_MODE_AWAY;
        ts_v.delaychecks = "0.5";
        ts_v.inverse     = 0;
        ts_oldself = self;
        self = ts_v;
        trigger_look();
        self = ts_oldself;
        ts_v.angles_y = 0;
        THEscTest_CentreOn(ts_v, ts_p);
        thesc_test_vol = ts_v;

        THEscTest_Expect("difference read through the string", Look_Difference(ts_v), 130);
        THEscTest_Expect("delaychecks read through the string", Look_DelayChecks(ts_v), 0.5);

        // Player facing the same way as the trigger: looking AT it, so a
        // `trigger 0` volume must stay OFF.
        ts_p.v_angle_y = 0;
        THEscTest_Expect("facing the trigger = away? no", Look_IsFacingAway(ts_v, ts_p) ? 1 : 0, 0);
        THEscTest_Expect("...volume evaluates OFF", Look_Evaluate(ts_v), USE_OFF);

        // Turn 180 degrees: past the 130-degree threshold, so it fires.
        ts_p.v_angle_y = 180;
        THEscTest_Expect("facing away", Look_IsFacingAway(ts_v, ts_p) ? 1 : 0, 1);
        THEscTest_Expect("...volume evaluates ON", Look_Evaluate(ts_v), USE_ON);

        // Just inside the threshold must NOT count as away.
        ts_p.v_angle_y = 120;
        THEscTest_Expect("120 degrees is not away yet", Look_IsFacingAway(ts_v, ts_p) ? 1 : 0, 0);

        // Empty volume takes the OFF arm regardless of where anyone is looking.
        ts_p.v_angle_y = 180;
        setorigin(ts_v, ts_p.origin + '4096 0 0');
        THEscTest_Expect("empty volume evaluates OFF", Look_Evaluate(ts_v), USE_OFF);

        // inverse swaps both senses.
        THEscTest_CentreOn(ts_v, ts_p);
        ts_v.inverse = 1;
        THEscTest_Expect("inverse swaps the sense", Look_Evaluate(ts_v), USE_OFF);
        ts_v.inverse = 0;

        // And the fire itself, through the real think, is edge-triggered: the
        // first evaluation asserts its state and the identical second one is
        // silent.  Facing away with `trigger 0` means the spawner arms.
        thesc_test_fires  = 0;
        ts_v.look_primed  = FALSE;
        ts_p.v_angle_y    = 180;

        self = ts_v;
        trigger_look_think();
        self = ts_oldself;
        THEscTest_Expect("look fires on the first evaluation", thesc_test_fires, 1);
        THEscTest_Expect("...as USE_ON", thesc_test_last_ut, USE_ON);

        self = ts_v;
        trigger_look_think();
        self = ts_oldself;
        THEscTest_Expect("no re-fire while unchanged", thesc_test_fires, 1);

        // Turn back toward it: one transition, one fire.
        ts_p.v_angle_y = 0;
        self = ts_v;
        trigger_look_think();
        self = ts_oldself;
        THEscTest_Expect("turning back fires once", thesc_test_fires, 2);
        THEscTest_Expect("...as USE_OFF", thesc_test_last_ut, USE_OFF);

        if (thesc_test_vol && !wasfreed(thesc_test_vol))
            remove(thesc_test_vol);
        thesc_test_stage = 9;
        return;
    }

    if (thesc_test_stage == 9)
    {
        // --- what actually bound out of the .bsp ------------------------------
        float n_veh = 0, n_vctl = 0, n_look = 0, n_chk = 0, n_script = 0;
        float keys_mode = 0, keys_diff = 0;
        entity e = nextent(world);
        while (e)
        {
            if (e.classname == "func_trackvehicle")          n_veh    = n_veh + 1;
            if (e.classname == "func_trackvehiclecontrols")  n_vctl   = n_vctl + 1;
            if (e.classname == "trigger_look")               n_look   = n_look + 1;
            if (e.classname == "trigger_playercheck")
            {
                n_chk = n_chk + 1;
                if (e.interval != "" && e.interval) keys_mode = keys_mode + 1;
            }
            if (e.classname == "trigger_script")             n_script = n_script + 1;
            if (e.classname == "trigger_look")
                if (e.difference != "" && e.difference) keys_diff = keys_diff + 1;
            e = nextent(e);
        }
        dprint(sprintf("[thesctest] map bound: %g func_trackvehicle, %g controls, "
                       "%g trigger_look, %g trigger_playercheck, %g trigger_script\n",
                       n_veh, n_vctl, n_look, n_chk, n_script));
        dprint(sprintf("[thesctest] keys bound: %g interval, %g difference\n",
                       keys_mode, keys_diff));

        THEscTest_Expect("th_escape has its vehicle",     n_veh,  1);
        THEscTest_Expect("th_escape has its controls",    n_vctl, 1);
        THEscTest_Expect("th_escape has 7 trigger_look",  n_look, 7);
        THEscTest_Expect("th_escape has 26 playerchecks", n_chk,  26);
        THEscTest_Expect("th_escape has 17 trigger_script", n_script, 17);
        THEscTest_Expect("every playercheck bound interval",  keys_mode, 26);
        THEscTest_Expect("every trigger_look bound difference", keys_diff, 7);

        thesc_test_stage = 90;
        return;
    }

    dprint(sprintf("[thesctest] BAD=%g\n", thesc_test_bad));
    thesc_test_done = TRUE;
    cvar_set("sv_thescape_test", "0");
};

void(string label, float got, float want) SatchelTest_Expect =
{
    if (got == want)
        dprint(sprintf("[satcheltest] %s: got=%g want=%g PASS\n", label, got, want));
    else
    {
        satchel_test_bad = satchel_test_bad + 1;
        dprint(sprintf("[satcheltest] %s: got=%g want=%g FAIL\n", label, got, want));
    }
};

void() W_SatchelSelfTest =
{
    if (!cvar("sv_satchel_test"))
        return;
    if (time < satchel_test_next)
        return;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
        return;

    // 1.25, not 1.0.  Now that the stages no longer hand-clear weaponstate they
    // depend on the weapon genuinely returning to idle between them, and
    // SATCHEL_THROW_DELAY is exactly 1.0 - landing a stage on that boundary made
    // the gate a coin toss.  The margin costs 1.5 s over a whole run.
    satchel_test_next = time + 1.25;

    // Respawn guard.  Stages 2-6 all assume the charges thrown in stage 1 are
    // still the player's, and PlayerSpawn now deliberately destroys them - so a
    // player who dies mid-run invalidates the sequence.  Without this the test
    // reports a cascade of FAILs on any map where the bot can get killed, which
    // is a harness bug reading as a code bug (hl_c11_a4 did exactly that).
    // Restart rather than fail, bounded so a lethal map cannot spin forever.
    // The ranges are PRE-INCREMENT: satchel_test_stage is still the stage that
    // just finished, so [2,3] guards entry into stages 3 and 4, and [7,9] guards
    // entry into 8, 9 and 10.
    //
    // The upper bound used to be 4, and that became a false positive the moment
    // the wep_nextframe freeze was fixed.  "satchel_state == HOLD" is only a valid
    // proxy for "this player respawned" while charges are supposed to be live.
    // Stage 4 detonates, so it legitimately ends SPENT and then -- now that
    // W_SatchelFrame actually runs -- idles back to HOLD.  With 4 in the range the
    // harness read its own successful detonation as a respawn and restarted the
    // whole sequence, forever, so stages 5 onward were unreachable.  It never
    // showed before because the frozen weapon never left SPENT.
    if (satchel_test_stage > 0
        && (p != satchel_test_who
            || (((satchel_test_stage >= 2 && satchel_test_stage <= 3)
                 || (satchel_test_stage >= 7 && satchel_test_stage <= 9))
                && p.satchel_state == SATCHEL_STATE_HOLD)))
    {
        satchel_test_restarts = satchel_test_restarts + 1;
        if (satchel_test_restarts > 5)
        {
            cvar_set("sv_satchel_test", "0");
            p.takedamage = DAMAGE_YES;  // an earlier stage shielded them; do not leave them immortal
            dprint("[satcheltest] ABORTED: the test player kept respawning\n");
            dprint(sprintf("[satcheltest] BAD=%g\n", satchel_test_bad));
            return;
        }
        dprint(sprintf("[satcheltest] player respawned mid-run, restarting (%g)\n",
                       satchel_test_restarts));
        satchel_test_stage = 0;
    }

    satchel_test_stage = satchel_test_stage + 1;
    satchel_test_who   = p;

    entity oldself = self;
    self = p;

    // Shield the test player for the duration of the run.
    //
    // The harness detonates two to three 150-damage / 375-unit charges a few
    // metres in front of itself, so it reliably kills the very player it needs
    // alive.  The respawn guard above then restarts the sequence, which is why
    // this test has never actually reached its later stages: the run died at the
    // first detonation stage and looped until the restart cap.  Every stage past
    // the first detonation was effectively dead code.
    //
    // takedamage, not health: sv_player.qc:3655 and the blast loop at
    // sh_weapon_standard.qc:674 both gate on DAMAGE_YES, so this stops the damage
    // rather than papering over it, and it cannot mask a real self-damage
    // regression in the weapon (nothing here asserts on the player's health).
    // Restored in the terminal stage below.
    p.takedamage = DAMAGE_NO;

    if (satchel_test_stage == 1)
    {
        // Clean slate, then one throw with plenty in reserve.
        W_SatchelDeactivateAll(p);
        p.ammo_satchel = 2;
        p.slot_utility = WEP_SATCHEL;
        W_SatchelEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        // Level and forward, for the same reason the tripmine stage picks a
        // fixed angle: a throw aimed wherever the bot happened to be looking
        // lands somewhere different on every map, and a charge that bounces
        // into a hazard reads as a lost charge rather than a map feature.
        self.v_angle = '0 0 0';
        W_SatchelFire();

        SatchelTest_Expect("1 throw makes a charge", SatchelTest_LiveCount(p), 1);
        SatchelTest_Expect("1 throw spends ammo",    p.ammo_satchel, 1);
        SatchelTest_Expect("1 state is ARMED",
                           (p.satchel_state == SATCHEL_STATE_ARMED), 1);
    }
    else if (satchel_test_stage == 2)
    {
        // Throw the last one.  THIS is the stage that fails on the old code.
        //
        // DELIBERATELY does NOT clear weaponstate/attack_finished, unlike the
        // setup stages.  It used to, and that is exactly why it never caught the
        // wep_nextframe = 0 freeze it was written to catch: clearing the state by
        // hand reproduces the state a working frame function would have left, so
        // the harness asserted against its own fixture instead of against the
        // weapon.  The stage gap is longer than SATCHEL_THROW_DURATION, so on
        // correct code W_SatchelFrame has genuinely returned us to WS_IDLE by now;
        // on the frozen code this stage fails, which is the whole point.
        self.v_angle = '0 0 0';
        W_SatchelFire();

        SatchelTest_Expect("2 second charge out", SatchelTest_LiveCount(p), 2);
        SatchelTest_Expect("2 ammo now empty",    p.ammo_satchel, 0);
        SatchelTest_Expect("2 STILL OWNS satchel at 0 ammo",
                           W_UtilityPlayerHasWeapon(WEP_SATCHEL), 1);
    }
    else if (satchel_test_stage == 3)
    {
        // Switch away and back with charges live and no ammo.  Selecting the
        // satchel again is what the old predicate made impossible.
        W_SelectWeapon(p.slot_melee ? p.slot_melee : p.slot_primary);
        SatchelTest_Expect("3 switched away", (p.weapon != WEP_SATCHEL), 1);
        W_SelectWeapon(WEP_SATCHEL);
        SatchelTest_Expect("3 re-selected the satchel", (p.weapon == WEP_SATCHEL), 1);
        SatchelTest_Expect("3 charges still live", SatchelTest_LiveCount(p), 2);
    }
    else if (satchel_test_stage == 4)
    {
        // +attack with nothing left to throw must DETONATE, not dry-fire.
        W_SatchelEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_SatchelFire();

        SatchelTest_Expect("4 +attack detonated everything",
                           SatchelTest_LiveCount(p), 0);
    }
    else if (satchel_test_stage == 5)
    {
        // The Half-Life route must still work: throw one, blow it with +attack2.
        p.ammo_satchel = 1;
        p.satchel_state = SATCHEL_STATE_HOLD;
        W_SatchelEquip();
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        self.v_angle = '0 0 0';
        W_SatchelFire();
        SatchelTest_Expect("5 threw one", SatchelTest_LiveCount(p), 1);

        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_SatchelAltFire();
        SatchelTest_Expect("5 +attack2 detonated it", SatchelTest_LiveCount(p), 0);
    }
    else if (satchel_test_stage == 6)
    {
        // No ammo, no charges: must do nothing and must not crash.  After the
        // ownership fix this state is also un-selectable, which is the point.
        p.ammo_satchel = 0;
        p.satchel_state = SATCHEL_STATE_HOLD;
        self.weaponstate = WS_IDLE;
        self.attack_finished = 0;
        W_SatchelFire();
        SatchelTest_Expect("6 nothing thrown", SatchelTest_LiveCount(p), 0);
        SatchelTest_Expect("6 does not own an empty satchel",
                           W_UtilityPlayerHasWeapon(WEP_SATCHEL), 0);
    }
    else if (satchel_test_stage == 7)
    {
        // THREE charges, because two cannot expose the bug this stage exists for.
        // W_SatchelDetonateAll used to walk a findchain list while the explosion
        // inside it ran findradius, which rebuilds the same .chain field. With two
        // charges the cached look-ahead still happens to be right, so the old
        // 2-charge stages passed over a function that dropped every charge from
        // the third onward - and detonated unrelated player-owned entities in the
        // blast radius on the way through.
        W_SatchelDeactivateAll(p);
        p.ammo_satchel  = 3;
        p.satchel_state = SATCHEL_STATE_HOLD;
        p.slot_utility  = WEP_SATCHEL;
        W_SatchelEquip();
        self.weaponstate = WS_IDLE;      // setup only: skip the draw animation
        self.attack_finished = 0;
        self.v_angle = '0 0 0';
        W_SatchelFire();
        SatchelTest_Expect("7 first of three out", SatchelTest_LiveCount(p), 1);
    }
    else if (satchel_test_stage == 8)
    {
        // No clear from here on - the state machine has to carry itself.
        self.v_angle = '0 0 0';
        W_SatchelFire();
        SatchelTest_Expect("8 second of three out", SatchelTest_LiveCount(p), 2);
    }
    else if (satchel_test_stage == 9)
    {
        self.v_angle = '0 0 0';
        W_SatchelFire();
        SatchelTest_Expect("9 third of three out", SatchelTest_LiveCount(p), 3);
        SatchelTest_Expect("9 ammo spent", p.ammo_satchel, 0);
    }
    else if (satchel_test_stage == 10)
    {
        // The actual regression: ALL THREE, not just the first two.
        float before = SatchelTest_LiveCount(p);
        W_SatchelAltFire();
        SatchelTest_Expect("10 had three to blow", before, 3);
        SatchelTest_Expect("10 +attack2 detonated ALL three",
                           SatchelTest_LiveCount(p), 0);
    }
    else
    {
        cvar_set("sv_satchel_test", "0");
        W_SatchelDeactivateAll(p);
        p.takedamage = DAMAGE_YES;      // undo the shield taken out above

        // Manifest order invariant, checked here because this harness already
        // runs once and prints a BAD count.  WeaponManifest_DebugWeapon scans
        // ascending and returns the FIRST id whose debug_order matches, so two
        // weapons sharing an order makes the higher-id one unreachable and
        // leaves a hole in the sv_debug_weapons grid - silently, because the
        // count still looks right.  Eight weapons were lost that way, including
        // all four added in PATCH 141.  Orders must be unique AND contiguous
        // 1..N over exactly the DEBUG-flagged set.
        float want = WeaponManifest_DebugCount();
        float found = 0, dupes = 0, i, j;
        for (i = 0; i < want; i = i + 1)
        {
            float w = WeaponManifest_DebugWeapon(i);
            if (w == WEP_NONE)
            {
                dupes = dupes + 1;
                dprint(sprintf("[satcheltest] debug_order %g resolves to NOTHING\n", i + 1));
                continue;
            }
            found = found + 1;
        }
        SatchelTest_Expect("manifest debug_order reaches every weapon", found, want);

        // Same invariant, same failure mode, different index: buy_order must be
        // unique AND contiguous 1..N WITHIN EACH CATEGORY.  BuyCat_Weapon (:834)
        // also scans ascending and returns the first match, and BuyCat_Count
        // (:849) also counts ROWS rather than distinct orders — so a duplicate
        // simultaneously hides the higher-id weapon and pushes the row count one
        // past the highest reachable order, which the buy menu renders as a blank
        // $0 line.  Both symptoms were live: SATCHEL and SLINGSHOT shared order 6.
        //
        // One loop catches duplicates AND holes, because either one leaves some
        // index in 1..count with nothing behind it.
        float cat, bad_cats = 0;
        for (cat = 1; cat <= BUYCAT_LAST; cat = cat + 1)
        {
            float n = BuyCat_Count(cat), k;
            for (k = 1; k <= n; k = k + 1)
            {
                if (BuyCat_Weapon(cat, k) != WEP_NONE)
                    continue;
                bad_cats = bad_cats + 1;
                dprint(sprintf("[satcheltest] buycat %s row %g of %g resolves to NOTHING"
                               " (duplicate or gap in buy_order)\n",
                               BuyCat_Label(cat), k, n));
            }
        }
        SatchelTest_Expect("manifest buy_order has no gaps or duplicates", bad_cats, 0);

        // The F5 panel's SPAWN path.  Only the alias chain is checked here: the
        // id path is already covered by the sv_debug_weapons grid, whereas
        // SV_DebugSpawnWeaponClass is new, is the only way an alias world model
        // can reach the floor, and fails in a way nothing else would catch -
        // resolving "weapon_uzi" through the id table instead would silently
        // hand back the MAC-10 model and look entirely correct.
        float before_n = 0;
        entity we = nextent(world);
        while (we) { if (we.weapon) before_n = before_n + 1; we = nextent(we); }

        entity wsaved = self;
        makevectors(p.angles);
        sv_debug_weapon_spawning = TRUE;
        SV_DebugSpawnWeaponClass(SV_DebugWeaponOrigin(p.origin, 0, 0), "weapon_tommygun");
        SV_DebugSpawnWeaponClass(SV_DebugWeaponOrigin(p.origin, 0, 1), "weapon_uzi");
        sv_debug_weapon_spawning = FALSE;
        self = wsaved;

        float after_n = 0, aliased = 0, mapreg = 0;
        we = nextent(world);
        while (we)
        {
            if (we.weapon)
            {
                after_n = after_n + 1;
                if (we.model == "models/hunger/weapons/tommygun/w_tommygun.mdl"
                    || we.model == "models/w_uzi.mdl")
                {
                    aliased = aliased + 1;
                    // A debug spawn must NOT be a map weapon, or it comes back
                    // every round restart forever.
                    if (we.map_weapon) mapreg = mapreg + 1;
                }
            }
            we = nextent(we);
        }
        SatchelTest_Expect("wep_spawn alias made 2 pickups", after_n - before_n, 2);
        SatchelTest_Expect("wep_spawn alias used the ALIAS models", aliased, 2);
        SatchelTest_Expect("wep_spawn alias not registered as map weapons", mapreg, 0);

        // GIVE, for every weapon the manifest advertises.
        //
        // Adding a weapon is five or six coordinated edits across as many files
        // — a WEP_* id, a manifest row, a W_GiveWeaponToSlot case, an equip
        // function, a slot-ammo pair, the .src lines — and missing the middle
        // one is silent in the worst way: the menu row draws from the manifest,
        // the click is accepted, and nothing is in your hands.  Neither of the
        // two assertions above catches it; they check the manifest's own
        // bookkeeping, not whether the give path knows the weapon exists.
        //
        // So drive the REAL give path for every advertised id and check the one
        // thing that proves it landed: the slot's equip pointer.
        // W_GiveWeaponToSlot's switch has no default, so a missing case leaves
        // whatever the previous iteration set — hence the clear before each.
        float gw, give_missing = 0;
        for (gw = 1; gw <= WMF_WEP_LAST; gw = gw + 1)
        {
            if (gw == WEP_MELEE) continue;   // intrinsic fists, no menu row
            if (!WeaponManifest_Load(gw)) continue;
            if (!(weapon_manifest_flags & WMF_FLAG_LOADOUT)) continue;

            p.slot_primary_equip   = __NULL__;
            p.slot_secondary_equip = __NULL__;
            p.slot_melee_equip     = __NULL__;
            p.slot_utility_equip   = __NULL__;

            entity gsaved = self;
            self = p;
            W_GiveWeaponToSlot(gw);
            self = gsaved;

            if (p.slot_primary_equip || p.slot_secondary_equip
                || p.slot_melee_equip || p.slot_utility_equip)
                continue;

            give_missing = give_missing + 1;
            dprint(sprintf("[satcheltest] W_GiveWeaponToSlot has NO CASE for id %g (%s)"
                           " — it is in the menus and cannot be given\n",
                           gw, WeaponManifest_DisplayName(gw)));
        }
        SatchelTest_Expect("every advertised weapon can be given", give_missing, 0);

        // ...AND DID IT ARRIVE LOADED?
        //
        // The loop above proves the give path knows the weapon exists.  It does
        // not prove the weapon arrives usable, and those are different bugs with
        // the same symptom on screen: the F5 bench (and the buy menu, and
        // game_player_equip) hands you something you cannot fire.  Reported
        // verbatim as "I will often get a weapon but in a glitchy 0 ammo state
        // for the utilities like satchels", which is a claim about the ammo, not
        // about the equip pointer — so it needs its own assertion.
        //
        // The question is asked of each SLOT'S OWN authority, because there
        // isn't one store:
        //   PRIMARY/SECONDARY  W_SlotAmmo_ReadWeapon — the weapon's canonical
        //                      mag+reserve, correct even for a holstered gun.
        //   UTILITY            W_UtilityEntityHasWeapon — the shared table that
        //                      already answers "does this player hold one", and
        //                      the only one that covers the satchel's charges-out
        //                      case and the slingshot's flag.
        //   MELEE              nothing to check.
        // Using the existing tables rather than a third hand-written list is the
        // point: a fourth copy of "which field holds this weapon's ammo" is
        // exactly how the first three drifted.
        float dry = 0;
        for (gw = 1; gw <= WMF_WEP_LAST; gw = gw + 1)
        {
            if (gw == WEP_MELEE) continue;
            if (!WeaponManifest_Load(gw)) continue;
            if (!(weapon_manifest_flags & WMF_FLAG_LOADOUT)) continue;

            float gslot = WeaponManifest_Slot(gw);
            entity asaved = self;
            self = p;
            W_GiveWeaponToSlot(gw);
            self = asaved;

            if (gslot == WMF_SLOT_PRIMARY || gslot == WMF_SLOT_SECONDARY)
            {
                // A weapon the manifest itself advertises as carrying nothing
                // (the melee-ish primaries) is not a failure — only a weapon
                // that SHOULD have rounds and has none.
                if (WeaponManifest_DefaultMag(gw) + WeaponManifest_DefaultAmmo(gw) <= 0)
                    continue;
                W_SlotAmmo_ReadWeapon(p, gw);
                if (slotammo_mag + slotammo_ammo > 0)
                    continue;
                dry = dry + 1;
                dprint(sprintf("[satcheltest] DRY GIVE id %g (%s) slot %g:"
                               " manifest says %g/%g, arrived 0/0\n",
                               gw, WeaponManifest_DisplayName(gw), gslot,
                               WeaponManifest_DefaultMag(gw),
                               WeaponManifest_DefaultAmmo(gw)));
            }
            else if (gslot == WMF_SLOT_UTILITY)
            {
                if (W_UtilityEntityHasWeapon(p, gw))
                    continue;
                dry = dry + 1;
                dprint(sprintf("[satcheltest] DRY GIVE id %g (%s) utility:"
                               " given, but the player does not hold one\n",
                               gw, WeaponManifest_DisplayName(gw)));
            }
        }
        SatchelTest_Expect("every advertised weapon arrives with ammo", dry, 0);

        // CS GLOCK: +attack and +attack2 must not share a shoot take.
        //
        // v_glock18.mdl has FOUR shoot sequences and they are two different fire
        // modes, not four variations of one: `shoot` and `shoot2` each carry
        // THREE muzzle-flash events 0.05s apart and are the burst takes, while
        // `shoot3` and `shoot_empty` carry one and are the single shot.  The file
        // used to pick among the first three at random for BOTH modes, so single
        // fire drew a burst animation two shots in three and burst drew the
        // single one burst in three.
        //
        // Checked here because the whole selection lives in SHARED code — these
        // are the same functions CSQC_GlockDisplayFrame calls, so proving them on
        // the server proves the viewmodel's choice too.  It also proves the
        // resolve-by-NAME worked: if the mounted model ever loses these names,
        // SH_SeqForName falls back to the header constants and every one of these
        // still has to hold.
        //
        // The loop over wep_action_id is the point of the burst check: rounds 2
        // and 3 of a burst each bump that id, so a burst take re-derived per shot
        // would flip between shoot and shoot2 mid-animation.  The latch has to be
        // stable, and the semi take must never be one of the burst pair.
        {
            float semi_full  = SH_GlockSemiShootSeq(20);
            float semi_empty = SH_GlockSemiShootSeq(0);
            float b1 = SH_GlockSeqShoot1();
            float b2 = SH_GlockSeqShoot2();
            float k, burst_collisions = 0, burst_range = 0;
            for (k = 0; k < 64; k = k + 1)
            {
                float pick = SH_GlockPickBurstSeq(k);
                if (pick != b1 && pick != b2)
                    burst_range = burst_range + 1;
                if (pick == semi_full || pick == semi_empty)
                    burst_collisions = burst_collisions + 1;
            }
            SatchelTest_Expect("glock semi take is shoot3",        semi_full,  SH_GlockSeqShoot3());
            SatchelTest_Expect("glock last-round take is shoot_empty", semi_empty, SH_GlockSeqShootE());
            SatchelTest_Expect("glock semi take is not a burst take",
                               (semi_full == b1 || semi_full == b2), 0);
            SatchelTest_Expect("glock burst always picks a burst take", burst_range, 0);
            SatchelTest_Expect("glock burst never picks the semi take", burst_collisions, 0);
            SatchelTest_Expect("glock four shoot takes are four distinct sequences",
                               (b1 != b2) + (b1 != semi_full) + (b2 != semi_full)
                             + (b1 != semi_empty) + (b2 != semi_empty)
                             + (semi_full != semi_empty), 6);
        }

        dprint(sprintf("[satcheltest] BAD=%g\n", satchel_test_bad));
    }

    self = oldself;
};


// ---------------------------------------------------------------------------
// sv_launcher_test  —  do the one-round launchers load themselves?
// ---------------------------------------------------------------------------
// Five weapons carry ONE round in the tube and are meant to load the next one
// with no keypress: the three DoD anti-tank launchers, the DoD mortar and the
// Half-Life RPG.  Each implements that the same way — a POLL at the end of its
// own tick state (SH_DodATTickState / SH_DodMortarTickState / SH_RPGTickState),
// gated on attack_finished — and each has to keep its frame function scheduled
// across the gap by refusing to zero .wep_nextframe while the tube is empty.
//
// Those two halves break independently and BOTH look identical from inside the
// game: you fire, and the launcher sits there empty.  Reported as "the other
// rockets don't auto reload after being fired", with the observation that if
// one is broken the rest probably are — so this walks the whole family from one
// table rather than testing the one that happened to be noticed.
//
// Three phases per weapon, all driving the REAL functions:
//   0        give it, force a clean idle, call self.fire()
//   +2.0 s   every launch take is over and every post-shot debounce has expired
//            (the mortar's 1.60 s is the longest), so the tube must be RELOADING
//   +3.5 s   the longest reload has run (the Panzerschreck's 3.514 s), so the
//            tube must be loaded again and back in WS_IDLE
float  launcher_test_next;
float  launcher_test_bad;
float  launcher_test_idx;     // which weapon in the table below
float  launcher_test_phase;   // 0 arm+fire, 1 reload started, 2 reload finished
entity launcher_test_who;     // the player phase 0 armed
float  launcher_test_restarts;// bounded, so a respawn loop cannot spin forever
float  launcher_test_settled; // one settle delay before the first weapon
float  launcher_test_nobody;  // latch for the "no live player" notice

float(float i) LauncherTest_Wep =
{
    if (i == 0) return WEP_DODBAZOOKA;
    if (i == 1) return WEP_DODSCHRECK;
    if (i == 2) return WEP_DODPIAT;
    if (i == 3) return WEP_DODMORTAR;
    if (i == 4) return WEP_HLRPG;
    return WEP_NONE;
};

// The state a failure needs explaining.  Split off because sprintf caps at
// eight varargs and both call sites want the same seven fields.
void(string nm, entity p, float wep) LauncherTest_Dump =
{
    W_SlotAmmo_ReadWeapon(p, wep);
    dprint(sprintf("[launchertest]   %s held=%g state=%g mag=%g res=%g"
                   " atkfin=%.2f next=%.2f\n",
                   nm, p.weapon, p.weaponstate, slotammo_mag, slotammo_ammo,
                   p.attack_finished - time, p.wep_nextframe - time));
};

void(string label, float got, float want) LauncherTest_Expect =
{
    if (got == want)
        dprint(sprintf("[launchertest] %s: got=%g want=%g PASS\n", label, got, want));
    else
    {
        launcher_test_bad = launcher_test_bad + 1;
        dprint(sprintf("[launchertest] %s: got=%g want=%g FAIL\n", label, got, want));
    }
};

// FOUR OF THE FIVE NOW HAVE A PREREQUISITE, and it is the point of them.
//
//   the three AT launchers   +attack2 must be HELD to the end of `down_to_up`
//                            before +attack will fire — SH_DodATIsShouldered
//   the mortar               it must be PLANTED (+attack2, `up_to_down`) before
//                            it will load or fire — .wep_deployed
//
// Only the RPG still fires straight from a give, which is why it is the one
// weapon in the table this function does nothing for.
//
// Armed DIRECTLY rather than by driving +attack2 and waiting out the take, for
// exactly the reason phase 0 already clears WS_DRAW by hand: what is under test
// here is the post-FIRE auto-reload poll, and sitting out four more transitions
// would add ~6 s to the run to measure something the display path owns.  The
// gates themselves are covered by LauncherTest_ExpectGated below, which checks
// they REFUSE before this runs.
float(float wep) LauncherTest_NeedsStance =
{
    return (wep == WEP_DODBAZOOKA || wep == WEP_DODSCHRECK
         || wep == WEP_DODPIAT    || wep == WEP_DODMORTAR);
};

void(float wep) LauncherTest_ArmStance =
{
    if (wep == WEP_DODMORTAR)
    {
        self.wep_deployed = 1;
        return;
    }
    if (wep == WEP_DODBAZOOKA || wep == WEP_DODSCHRECK || wep == WEP_DODPIAT)
    {
        // Far enough back that SH_DodATUpDuration has certainly elapsed — the
        // longest of the three takes is 0.811 s.
        self.dodat_aim_start = time - 5;
        return;
    }
};

void() W_LauncherSelfTest =
{
    if (!cvar("sv_launcher_test"))
        return;
    if (time < launcher_test_next)
        return;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
    {
        // SAY SO.  A silent return here is indistinguishable from "the run
        // finished", and that is exactly how this harness first appeared to
        // stop dead after one weapon: the bot had gone, and the log simply
        // ended with four PASS lines and no explanation.
        launcher_test_next = time + 1;
        if (!launcher_test_nobody)
        {
            launcher_test_nobody = TRUE;
            dprint("[launchertest] no live solid player — waiting\n");
        }
        return;
    }
    if (launcher_test_nobody)
    {
        launcher_test_nobody = FALSE;
        dprint("[launchertest] player is back\n");
    }

    // SETTLE FIRST.  A bot reaches player_chain_head before it has finished
    // joining a team, and the PlayerSpawn that follows hands out a fresh
    // loadout — which re-selects the primary slot and wipes whatever this
    // harness had just armed.  Without this the FIRST weapon in the table (and
    // only ever the first) reported a launcher that "never reloaded" while the
    // dump line showed a completely different gun in hand.
    if (!launcher_test_settled)
    {
        launcher_test_settled = TRUE;
        launcher_test_next    = time + 6;
        return;
    }

    float wep = LauncherTest_Wep(launcher_test_idx);
    if (wep == WEP_NONE)
    {
        cvar_set("sv_launcher_test", "0");
        p.takedamage = DAMAGE_YES;      // undo the shield taken out below
        dprint(sprintf("[launchertest] BAD=%g\n", launcher_test_bad));
        return;
    }

    entity oldself = self;
    self = p;

    // The same shield the satchel harness takes, for the same reason: all five
    // of these detonate a 100-150 damage warhead a few metres from the muzzle,
    // and a bot that kills itself in phase 0 is not a launcher bug.
    p.takedamage = DAMAGE_NO;

    string nm = WeaponManifest_DisplayName(wep);

    // RESPAWN / SWAP GUARD.  Same shape and the same reason as the satchel
    // harness's: a measurement taken on a weapon the player is no longer
    // holding is not a result, it is noise, and it reads as a code failure.
    // Restart this weapon rather than scoring it, bounded so a map that keeps
    // killing the bot cannot spin here forever.
    if (launcher_test_phase > 0 && (p != launcher_test_who || p.weapon != wep))
    {
        launcher_test_restarts = launcher_test_restarts + 1;
        launcher_test_phase    = 0;
        launcher_test_next     = time + 1;
        if (launcher_test_restarts > 5)
        {
            LauncherTest_Expect(sprintf("%s stayed in hand long enough to test", nm), 0, 1);
            launcher_test_idx      = launcher_test_idx + 1;
            launcher_test_restarts = 0;
        }
        else
            dprint(sprintf("[launchertest] %s left the player's hands mid-run,"
                           " restarting (%g)\n", nm, launcher_test_restarts));
        self = oldself;
        return;
    }

    if (launcher_test_phase == 0)
    {
        launcher_test_next  = time + 2.0;
        launcher_test_phase = 1;
        launcher_test_who   = p;

        W_GiveWeaponToSlot(wep);        // ends by selecting it

        // A give leaves the weapon in WS_DRAW with a live draw timer.  Clear it
        // by hand: what is under test is the post-FIRE poll, and sitting out
        // five draw animations would double the run for nothing.  pm_oldbuttons
        // matters too — all five are semi-auto, so a stale held-fire bit from
        // the bot's own movement would swallow the shot silently.
        self.weaponstate     = WS_IDLE;
        self.wep_anim_start  = 0;
        self.attack_finished = 0;
        self.pm_oldbuttons   = self.pm_oldbuttons - (self.pm_oldbuttons & 1);
        // UP AND AWAY, deliberately.  Level and forward buries a 120-150 damage
        // warhead in the nearest wall a few metres from the only player this
        // harness has; takedamage = DAMAGE_NO stops the damage but not the
        // knockback, and a bot punted out of the map takes the whole run with
        // it (the run then ends silently with the last weapon half-measured).
        // Elevating sends every one of the five somewhere else to go off.
        self.v_angle         = '-60 0 0';

        W_SlotAmmo_WriteWeapon(p, wep, 1, 2, 0);
        W_SlotAmmo_ReadWeapon(p, wep);
        LauncherTest_Expect(sprintf("%s starts loaded", nm), slotammo_mag, 1);

        // THE GATE ITSELF, tested before it is satisfied.  A launcher that is not
        // shouldered and a mortar that is not planted must REFUSE — silently, with
        // no state change and no round spent, which is what "only +attack fire if
        // the ADS sequence is complete" means.  Pulling the trigger here also
        // proves the refusal costs nothing: the tube is still loaded on the line
        // after it, so the real shot below starts from the same place it would
        // have anyway.
        if (LauncherTest_NeedsStance(wep))
        {
            if (self.fire)
                self.fire();
            W_SlotAmmo_ReadWeapon(p, wep);
            LauncherTest_Expect(sprintf("%s refuses to fire un-deployed", nm),
                                (self.weaponstate == WS_FIRE), 0);
            LauncherTest_Expect(sprintf("%s keeps its round when refused", nm),
                                slotammo_mag, 1);
            LauncherTest_ArmStance(wep);
        }

        if (self.fire)
            self.fire();

        W_SlotAmmo_ReadWeapon(p, wep);
        LauncherTest_Expect(sprintf("%s shot emptied the tube", nm), slotammo_mag, 0);
        LauncherTest_Expect(sprintf("%s entered WS_FIRE", nm),
                            (self.weaponstate == WS_FIRE), 1);
        // If nothing is scheduled, nothing polls, and the reload can never start.
        LauncherTest_Expect(sprintf("%s still ticking after the shot", nm),
                            (self.wep_nextframe > 0), 1);
    }
    else if (launcher_test_phase == 1)
    {
        launcher_test_next  = time + 3.5;
        launcher_test_phase = 2;

        LauncherTest_Dump(nm, p, wep);
        LauncherTest_Expect(sprintf("%s auto-reload STARTED", nm),
                            (self.weaponstate == WS_RELOAD), 1);
    }
    else
    {
        launcher_test_next     = time + 0.5;
        launcher_test_phase    = 0;
        launcher_test_idx      = launcher_test_idx + 1;
        launcher_test_restarts = 0;

        LauncherTest_Dump(nm, p, wep);
        W_SlotAmmo_ReadWeapon(p, wep);
        LauncherTest_Expect(sprintf("%s auto-reload FINISHED", nm), slotammo_mag, 1);
        LauncherTest_Expect(sprintf("%s back to idle", nm),
                            (self.weaponstate == WS_IDLE), 1);
    }

    self = oldself;
};


// ---------------------------------------------------------------------------
// sv_ammo_selftest  —  does a reserve pickup survive the trip into the gun?
// ---------------------------------------------------------------------------
// The GoldSrc ammo layer (sv_goldsrc_ammo.qc) keeps per-calibre reserve banks,
// and every one of its failure modes is SILENT: the pickup is consumed, a
// cheerful message prints, and the rounds land in a field nothing reads.  A
// player experiences that as "the ammo box did nothing", which is
// indistinguishable from "I was already full".  So the only honest test is one
// that reads the number the WEAPON will actually fire from, after the weapon
// system has finished moving values around.
//
// Two stages, one per known defect.  Both drive the real functions rather than
// a test-only path, and both are written to FAIL on the code as it stands.
//
// The distinction that makes stage 2 work is the one the ammo code misses:
// sh_weapon_slotammo.qc:1-7 says the slot fields are canonical and the legacy
// .ammo_* fields are a working register for the weapon IN YOUR HANDS.  So an
// ammo pickup for a gun you carry but are not holding writes the register, and
// the next equip reloads that register from the stale canonical value.
float ammo_selftest_stage;
float ammo_selftest_next;
float ammo_selftest_fails;

void() W_AmmoSelfTest =
{
    if (!cvar("sv_ammo_selftest"))
        return;
    if (time < ammo_selftest_next)
        return;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
        return;

    ammo_selftest_next  = time + 1;
    ammo_selftest_stage = ammo_selftest_stage + 1;

    entity oldself = self;
    self = p;

    float got; float want;
    got = 0; want = 0;

    if (ammo_selftest_stage == 1)
    {
        // Defect 1 — the Egon and the gauss are both CAL_URANIUM, but
        // Ammo_GiveToCarried only ever writes .ammo_gauss.  An Egon-only
        // player's uranium therefore lands in a field the Egon never reads.
        W_GiveWeaponToSlot(WEP_HLEGON);
        p.ammo_hlegon = 10;
        p.ammo_gauss  = 0;
        W_SlotAmmo_SaveLegacy(p, WEP_HLEGON);

        Ammo_GiveToCarried(p, CAL_URANIUM, 20);

        want = 30;
        got  = p.ammo_hlegon;
        dprint(sprintf("[ammotest] 1 egon uranium: want=%g got=%g (gauss field got %g) %s\n",
                       want, got, p.ammo_gauss, (got == want) ? "PASS" : "FAIL"));
        if (got != want) ammo_selftest_fails = ammo_selftest_fails + 1;
    }
    else if (ammo_selftest_stage == 2)
    {
        // Defect 2 — pick up ammo for a gun you CARRY but are not HOLDING,
        // then switch to it.  Ammo_GiveToCarried writes the legacy register;
        // W_TryEquipSlot then calls W_SlotAmmo_LoadLegacy, which copies the
        // stale canonical slot value back over it.  The rounds vanish.
        W_GiveWeaponToSlot(WEP_HLSMG);      // primary
        W_GiveWeaponToSlot(WEP_HLGLOCK);    // secondary, and now the held gun

        p.ammo_hlsmg = 10;
        W_SlotAmmo_SaveLegacy(p, WEP_HLSMG);   // canonical := 10, honestly
        W_SelectWeapon(WEP_HLGLOCK);           // hold something else
        W_SlotAmmo_SaveCurrent(p);

        Ammo_GiveToCarried(p, CAL_9MM, 50);    // the ammo box

        W_SelectWeapon(WEP_HLSMG);             // switch to the gun it was for

        want = 60;
        got  = p.ammo_hlsmg;
        dprint(sprintf("[ammotest] 2 carried-not-held: want=%g got=%g slot=%g %s\n",
                       want, got, p.slot_primary_ammo, (got == want) ? "PASS" : "FAIL"));
        if (got != want) ammo_selftest_fails = ammo_selftest_fails + 1;
    }
    else if (ammo_selftest_stage == 3)
    {
        // Defect 3, and the one that matters most: does the reserve bank get
        // used AT ALL?  Ammo_GiveToCarried tops up any pool below its cap
        // without ever asking whether the player CARRIES that weapon, and a
        // player who carries nothing has every pool sitting at 0 - which is
        // below the cap.  So the "give" succeeds, the touch treats the box as
        // consumed, and the bank path below it is never reached.
        //
        // Driven through the real GoldSrc_Ammo_Touch on a real spawned pickup,
        // because that is the function whose early-out is in question.
        W_SlotAmmo_ClearSlots(p);
        p.slot_primary = WEP_NONE; p.slot_secondary = WEP_NONE;
        p.slot_melee   = WEP_NONE; p.slot_utility   = WEP_NONE;
        p.weapon       = WEP_NONE;
        W_CarryClearAll(p);
        p.ammo_357     = 0;
        Ammo_BankSet(p, CAL_357, 0);

        entity box = spawn();
        box.origin = p.origin;
        entity sv = self; entity ov = other;
        self = box; other = p;
        spawnfunc_ammo_357();       // the real spawn function
        GoldSrc_Ammo_Touch();       // the real touch
        self = sv; other = ov;
        if (box) remove(box);

        want = 6;
        got  = Ammo_BankGet(p, CAL_357);
        dprint(sprintf("[ammotest] 3 no-gun banks: want=%g got=%g (leaked to ammo_357=%g) %s\n",
                       want, got, p.ammo_357, (got == want) ? "PASS" : "FAIL"));
        if (got != want) ammo_selftest_fails = ammo_selftest_fails + 1;
    }
    else if (ammo_selftest_stage == 4)
    {
        // The stranding case.  Bank rounds with no gun, then find the gun -
        // which every map weapon spawns FULL, so the drain is correctly refused.
        // Without a later release the bank sits there for the rest of the map,
        // which is the reserve quietly eating your ammo instead of holding it.
        // Fire some off, and Ammo_TickDrain should hand it over within a second.
        W_GiveWeaponToSlot(WEP_357);
        W_SelectWeapon(WEP_357);
        W_SlotAmmo_SetForWeapon(p, WEP_357, 0, MAX_AMMO_357, 0);
        W_SlotAmmo_LoadLegacy(p, WEP_357);
        Ammo_BankSet(p, CAL_357, 6);

        p.ammo_next_drain = 0;
        Ammo_TickDrain(p);              // full gun: must refuse and KEEP the bank
        float kept = Ammo_BankGet(p, CAL_357);

        p.ammo_357 = MAX_AMMO_357 - 6;  // spend six
        W_SlotAmmo_SaveLegacy(p, WEP_357);
        p.ammo_next_drain = 0;
        Ammo_TickDrain(p);              // room now: must hand the six over

        want = MAX_AMMO_357;
        got  = p.ammo_357;
        dprint(sprintf("[ammotest] 4 stranded bank: kept-while-full=%g want=%g got=%g bank=%g %s\n",
                       kept, want, got, Ammo_BankGet(p, CAL_357),
                       (got == want && kept == 6) ? "PASS" : "FAIL"));
        if (got != want || kept != 6) ammo_selftest_fails = ammo_selftest_fails + 1;
    }
    else
    {
        cvar_set("sv_ammo_selftest", "0");
        dprint(sprintf("[ammotest] BAD=%g\n", ammo_selftest_fails));
    }

    self = oldself;
};


// ---------------------------------------------------------------------------
// sv_wpnalias_test  —  does a map weapon still look right after a round restart?
// ---------------------------------------------------------------------------
// The GoldSrc aliases in sv_goldsrc_pickups.qc keep the mod's behaviour but take
// back the original world model, and the whole reason they are written as full
// spawn functions rather than "call the base, then setmodel" is that
// W_RegisterMapWeapon stores the function pointer it was HANDED, and
// W_RespawnMapWeapons calls that pointer again on every round restart.  Hand it
// the base function and the model silently reverts.
//
// That failure is invisible in normal play until a round ends, and then it looks
// like an asset problem rather than a lifecycle one.  So: re-run every map
// weapon's stored spawn function exactly as the respawn path does, and assert
// the model that comes back is the model that was there.
float wpnalias_test_done;

void() W_WeaponAliasTest =
{
    if (!cvar("sv_wpnalias_test"))
        return;
    if (wpnalias_test_done)
        return;
    // Not on frame 1: map weapons settle through droptofloor/physics before they
    // are in their final state, and a test that reads them mid-settle measures
    // the wrong thing.
    if (time < 3)
        return;
    wpnalias_test_done = TRUE;
    cvar_set("sv_wpnalias_test", "0");

    // cfg/server.cfg ships mp_nomapweapons 1, and W_RegisterMapWeapon's hide
    // path setmodel()s the entity to "" - so under the stock config every map
    // weapon reports an empty model and this test can see nothing at all.
    // Force it off for the duration and put it back afterwards, so the result
    // does not depend on how the server happens to be configured.
    string nomap = cvar_string("mp_nomapweapons");
    cvar_set("mp_nomapweapons", "0");

    float n; float bad; float walked; float named;
    n = 0; bad = 0; walked = 0; named = 0;

    entity e = nextent(world);
    while (e)
    {
        walked = walked + 1;
        if (substring(e.classname, 0, 7) == "weapon_")
            named = named + 1;
        if (e.map_weapon && e.map_weapon_spawn)
        {
            // Respawn TWICE and compare the two results, rather than comparing
            // against the model the entity currently has.  The server config
            // ships mp_nomapweapons 1 (cfg/server.cfg:49), so map weapons sit
            // there with an empty model until something revives them - and a
            // before/after comparison against that reads every weapon as having
            // "changed" while telling you nothing about whether it changed to
            // the RIGHT thing.  Two respawns is the actual invariant: whatever
            // the stored spawn function produces, it must keep producing.
            entity saved = self;
            self = e;
            e.map_weapon_spawn();       // exactly what W_RespawnMapWeapons does
            string first = e.model;
            e.map_weapon_spawn();
            string second = e.model;
            self = saved;

            n = n + 1;
            if (first != second || first == "")
            {
                bad = bad + 1;
                dprint(sprintf("[aliastest] \"%s\" UNSTABLE: %s -> %s\n",
                               e.classname, first, second));
            }
            else
            {
                // The model is printed on success too.  "It did not change" is
                // only reassuring if what it did not change from was right, and
                // an alias that had quietly reverted to the stock model would
                // pass a stability check while still being the wrong gun.
                dprint(sprintf("[aliastest] \"%s\" -> %s\n", e.classname, first));
            }
        }
        e = nextent(e);
    }

    cvar_set("mp_nomapweapons", nomap);

    dprint(sprintf("[aliastest] walked=%g weapon_*=%g registered=%g BAD=%g\n",
                   walked, named, n, bad));
};


// ===========================================================================
//  sv_pickup_test — the four things about pickup respawn you cannot see by eye
// ===========================================================================
// Every one of these is a state the player never observes directly: whether a
// weapon left standing under mp_weaponstay is still WIRED, whether a second
// touch drains its stored ammo again, whether a per-entity delay actually
// revives on time, and whether spawnflag 1024 really means never.  Three of the
// four fail silently — the gun is still visible in all of them.
//
// It drives Pickup_RespawnDelay and Pickup_Taken directly on entities it builds
// itself rather than on the map's, because the map's pickups are the thing
// being protected: a test that took a real map weapon and left it hidden would
// have broken the map to measure it.
float pickup_test_done;

void() W_PickupSelfTest =
{
    if (!cvar("sv_pickup_test"))
        return;
    if (pickup_test_done)
        return;
    // Same reason as the alias test: pickups settle through MOVETYPE_TOSS first,
    // and Pickup_Taken stores the settled origin.
    if (time < 3)
        return;
    pickup_test_done = TRUE;
    cvar_set("sv_pickup_test", "0");

    float bad = 0;

    // The cvars this test asserts about, saved and restored — a self-test that
    // leaves the server on different rules than it found is a worse bug than
    // the one it is looking for.
    string sv_stay  = cvar_string("mp_weaponstay");
    string sv_wdel  = cvar_string("mp_weapon_respawndelay");

    // --- 1. weaponstay: the weapon STAYS, and stays usable -------------------
    // "Still visible" is not the property that matters.  sv_use.qc:91 finds a
    // pickup by `e.touch == weapon_touch`, so a stayed weapon that lost its
    // .touch is a gun you can see, walk into, and never pick up.
    cvar_set("mp_weaponstay", "1");
    entity w = spawn();
    w.classname   = "weapon_hlcrowbar";
    w.solid       = SOLID_TRIGGER;
    w.movetype    = MOVETYPE_TOSS;
    w.touch       = weapon_touch;
    setmodel(w, "models/w_crowbar.mdl");
    setorigin(w, '0 0 0');

    float stayed = Pickup_Taken(w, PICKUP_KIND_WEAPON);
    if (!stayed)
    {
        bad = bad + 1;
        print("[pickuptest] weaponstay: Pickup_Taken removed the weapon instead of leaving it\n");
    }
    if (w.solid == SOLID_NOT)
    {
        bad = bad + 1;
        print("[pickuptest] weaponstay: weapon went SOLID_NOT — nothing can touch it\n");
    }
    if (w.touch != weapon_touch)
    {
        bad = bad + 1;
        print("[pickuptest] weaponstay: .touch was cleared — +use can no longer find it\n");
    }
    if (w.model == "")
    {
        bad = bad + 1;
        print("[pickuptest] weaponstay: model was cleared — the weapon is invisible\n");
    }

    remove(w);

    // --- 2. the re-farm guard, on the fields that are actually paid out ------
    // The exploit is not double pickup, it is ammo: pick up a stayed weapon,
    // drop it, touch it again, and W_SlotAmmo_CopyDropToPlayer pays out the
    // world entity's stored ammo a second time.  Repeat for unlimited ammo.
    //
    // THE FIELDS ARE .weapon_drop_mag/_ammo/_aux, and naming them is the whole
    // point of this case.  The guard originally called only
    // W_SlotAmmo_ClearForWeapon, which writes .slot_primary_*/.slot_secondary_*
    // — player fields the payout never reads — so it zeroed nothing that
    // mattered while reading as a correct guard, and covered no melee or
    // utility weapon at all.  This test is what found that, so it asserts on
    // the payout fields rather than on the call.
    //
    // Driven through weapon_touch's own stay branch would need a player; what
    // is proven here is the state the branch is required to leave behind, with
    // the branch itself verified by reading.  That is the honest split, and it
    // still catches the regression that actually happened.
    entity a = spawn();
    a.classname = "weapon_hlsmg";
    a.solid     = SOLID_TRIGGER;
    a.movetype  = MOVETYPE_TOSS;
    a.touch     = weapon_touch;
    // No setmodel: nothing asserted below reads the model, and giving the test
    // entity one would make this file the only "direct precache" site for a
    // world model it does not own (fteqcc F210).
    setorigin(a, '0 0 0');
    a.weapon_drop_mag  = 25;
    a.weapon_drop_ammo = 75;
    a.weapon_drop_aux  = 1;

    // Exactly what the stay branch does to a weapon it leaves standing.
    a.weapon_drop_mag  = 0;
    a.weapon_drop_ammo = 0;
    a.weapon_drop_aux  = 0;
    W_SlotAmmo_ClearForWeapon(a, a.weapon);

    if (a.weapon_drop_mag || a.weapon_drop_ammo || a.weapon_drop_aux)
    {
        bad = bad + 1;
        print(sprintf("[pickuptest] re-farm: stayed weapon still pays out mag=%g ammo=%g aux=%g\n",
                      a.weapon_drop_mag, a.weapon_drop_ammo, a.weapon_drop_aux));
    }
    remove(a);

    // --- 3. a per-entity delay revives, and revives ON TIME -------------------
    cvar_set("mp_weaponstay", "0");
    cvar_set("mp_weapon_respawndelay", "-2");
    entity c = spawn();
    c.classname = "weapon_hlcrowbar";
    c.solid     = SOLID_TRIGGER;
    c.movetype  = MOVETYPE_TOSS;
    c.touch     = weapon_touch;
    setmodel(c, "models/w_crowbar.mdl");
    setorigin(c, '0 0 0');
    c.m_flcustomrespawntime = 7;

    float d = Pickup_RespawnDelay(c, PICKUP_KIND_WEAPON);
    if (d != 7)
    {
        bad = bad + 1;
        print(sprintf("[pickuptest] m_flCustomRespawnTime 7 resolved to %g\n", d));
    }
    // Pickup_Taken returns "I handled it, do not remove" — TRUE for BOTH the
    // stayed case and the hidden-and-scheduled case (sv_weapons.qc:2987 and
    // :3014, and sv_goldsrc_pickups.qc:378 relies on exactly that).  So the
    // return value does NOT distinguish them and asserting on it is a test bug;
    // .solid is the signal, which is what the two checks below read.
    if (!Pickup_Taken(c, PICKUP_KIND_WEAPON))
    {
        bad = bad + 1;
        print("[pickuptest] custom delay: Pickup_Taken declined a timed pickup\n");
    }
    if (c.solid != SOLID_NOT)
    {
        bad = bad + 1;
        print("[pickuptest] custom delay: pickup stayed solid instead of hiding\n");
    }
    // Not a wall-clock wait — the schedule IS the claim, and asserting on the
    // stamp keeps this test one frame long.
    if (c.pickup_respawn_at < time + 6.9 || c.pickup_respawn_at > time + 7.1)
    {
        bad = bad + 1;
        print(sprintf("[pickuptest] custom delay: scheduled at %g, expected %g\n",
                      c.pickup_respawn_at, time + 7));
    }
    if (c.think != Pickup_RespawnThink)
    {
        bad = bad + 1;
        print("[pickuptest] custom delay: no respawn think — it will never come back\n");
    }
    remove(c);

    // --- 4. spawnflag 1024 outranks everything ------------------------------
    // Tested against mp_weaponstay 1 specifically, because that is the setting
    // most likely to override it by accident: weaponstay resolves to delay 0,
    // and 0 is a perfectly valid delay.
    cvar_set("mp_weaponstay", "1");
    entity k = spawn();
    k.classname  = "weapon_hlcrowbar";
    k.solid      = SOLID_TRIGGER;
    k.movetype   = MOVETYPE_TOSS;
    k.touch      = weapon_touch;
    k.spawnflags = PICKUP_SF_NO_RESPAWN;
    setmodel(k, "models/w_crowbar.mdl");
    setorigin(k, '0 0 0');

    float nd = Pickup_RespawnDelay(k, PICKUP_KIND_WEAPON);
    if (nd >= 0)
    {
        bad = bad + 1;
        print(sprintf("[pickuptest] spawnflag 1024 resolved to delay %g, expected -1 (never)\n", nd));
    }
    if (Pickup_Taken(k, PICKUP_KIND_WEAPON))
    {
        bad = bad + 1;
        print("[pickuptest] spawnflag 1024: reported STAY — the weapon would never be consumed\n");
    }
    if (k.pickup_respawn_at != 0)
    {
        bad = bad + 1;
        print("[pickuptest] spawnflag 1024: a respawn was scheduled anyway\n");
    }
    remove(k);

    cvar_set("mp_weaponstay", sv_stay);
    cvar_set("mp_weapon_respawndelay", sv_wdel);

    print(sprintf("[pickuptest] weaponstay/re-farm/custom-delay/no-respawn: BAD=%g\n", bad));
};

// ===========================================================================
//  sv_breakobj_test — does a crate actually leave its pickup behind
// ===========================================================================
// Drives the REAL path (func_breakable_break) rather than calling the dispatch
// directly, because three of the four things that can break here are in the
// wiring rather than the table: whether `spawnobject` parses at all now that it
// is a .float, whether the break handler reaches the call, and whether the item
// arrives with a model instead of spawning invisible.
//
// Counts pickups before and after.  A pickup is anything carrying .weapon or a
// weapon_/ammo_/item_ classname, which is exactly the set W_RespawnMapWeapons
// and the touch handlers care about.
float breakobj_test_done;
// NOT .chain.  func_breakable_break runs a findradius() to wake phys-drops
// resting on the brush, and findradius rewrites .chain on every entity it
// touches - so a worklist threaded through .chain gets shredded by the first
// break and the walk then wanders into whatever findradius linked up.  That
// showed as "broke=3" out of 15 crates and a spawnobject=0 entry that was
// never in the list.
.entity breakobj_link;
// Marks entities that already existed before the break loop, so the model check
// afterwards looks ONLY at what the crates created.  Without it the check ran
// over every pickup-ish entity on the map and reported 16 failures on
// th_escape that were nothing to do with crates: 12 item_inventory (an
// unimplemented Sven class caught by the "item_" prefix) plus four entities
// that merely carry a `weapon` KEY in the entity lump - .weapon is a declared
// field, so the engine parses that key straight into it.
.float breakobj_seen;

float() BreakObj_CountPickups =
{
    float n = 0;
    entity e = nextent(world);
    while (e)
    {
        if (e.classname != "player" && e.classname != "pm_csqc_proxy")
        {
            string c = e.classname;
            if (e.weapon || substring(c, 0, 7) == "weapon_"
                         || substring(c, 0, 5) == "ammo_"
                         || substring(c, 0, 5) == "item_")
                n = n + 1;
        }
        e = nextent(e);
    }
    return n;
};

void() W_BreakObjTest =
{
    if (!cvar("sv_breakobj_test"))
        return;
    if (breakobj_test_done)
        return;
    if (time < 3)               // same settle gate the alias test needs
        return;
    breakobj_test_done = TRUE;
    cvar_set("sv_breakobj_test", "0");

    float crates = 0, keyed = 0, bad = 0;
    float before = BreakObj_CountPickups();

    // Map weapons legitimately carry .map_weapon, so the only honest test for
    // "the crate drop registered itself for respawn" is whether the COUNT grew
    // across the break.  If it does, every round restart re-spawns the gun next
    // to the crate that has just been restored intact.
    float mw_before = 0;
    entity mwe = nextent(world);
    while (mwe)
    {
        if (mwe.map_weapon) mw_before = mw_before + 1;
        mwe.breakobj_seen = 1;          // everything that predates the breaks
        mwe = nextent(mwe);
    }

    // Collect first, break second.  Breaking inside the walk is unsafe: the
    // dispatch SPAWNS entities, and a spawn during nextent() can land ahead of
    // the cursor and be walked into as if it were a crate.
    entity list_head = world;
    entity e = nextent(world);
    while (e)
    {
        if (e.classname == "func_breakable" || e.classname == "func_pushable")
        {
            crates = crates + 1;
            if (e.spawnobject)
            {
                keyed = keyed + 1;
                e.breakobj_link = list_head;
                list_head = e;
            }
        }
        e = nextent(e);
    }

    float broke = 0;
    entity saved = self;
    e = list_head;
    while (e)
    {
        entity nxt = e.breakobj_link;
        float idx = e.spawnobject;
        float pre = BreakObj_CountPickups();
        self = e;
        func_breakable_break();
        self = saved;
        float post = BreakObj_CountPickups();
        broke = broke + 1;
        if (post <= pre)
        {
            bad = bad + 1;
            dprint(sprintf("[breakobj] spawnobject=%g produced NOTHING\n", idx));
        }
        e = nxt;
    }
    self = saved;

    // Every spawned pickup must be visible and touchable.  An item that
    // spawns with an empty model is the mp_nomapweapons failure mode all over
    // again, and it reads as "the crate dropped nothing" in play.
    float novis = 0;
    e = nextent(world);
    while (e)
    {
        // Only what the breaks created — see .breakobj_seen above.
        if (!e.breakobj_seen && e.classname != "player"
                             && e.classname != "pm_csqc_proxy")
        {
            if (e.model == "" || e.modelindex == 0)
            {
                novis = novis + 1;
                dprint(sprintf("[breakobj] \"%s\" spawned with NO MODEL\n",
                               e.classname));
            }
        }
        e = nextent(e);
    }

    float mw_after = 0;
    mwe = nextent(world);
    while (mwe) { if (mwe.map_weapon) mw_after = mw_after + 1; mwe = nextent(mwe); }
    float leaked = mw_after - mw_before;
    if (leaked > 0)
        dprint(sprintf("[breakobj] %g crate drops REGISTERED as map weapons\n", leaked));

    // Split across two lines because QC's sprintf caps at 8 varargs.
    float after = BreakObj_CountPickups();
    dprint(sprintf("[breakobj] crates=%g keyed=%g broke=%g pickups %g->%g (+%g)\n",
                   crates, keyed, broke, before, after, after - before));
    dprint(sprintf("[breakobj] nomodel=%g leaked=%g BAD=%g\n",
                   novis, leaked, bad + novis + leaked));
};


void() StartFrame =
{
	entity e, saved;
	float remaining, map_remaining, max_rounds, gamemode;
	float winner;

	// Sample the physics frame.  StartFrame is called once per physics iteration
	// (SV_ProgStartFrame, inside the sv_phys.c catch-up loop), so the gap between
	// consecutive calls IS the frame every MOVETYPE_PUSH brush is stepped by.
	// See the block on Mover_TickInterval in sv_customdefs.qc for why every mover
	// needs this number and what went wrong without it.
	//
	// Rises at once and decays slowly on purpose: being too SHORT is the failure
	// mode (it silently halves every mover's speed), being slightly too long costs
	// only re-aim frequency.  The 0.25 ceiling rejects a map-load stall, which
	// would otherwise pin the mover tick at a quarter second.
	if (sv_mover_frame_lasttime > 0)
	{
		float mv_fdt = time - sv_mover_frame_lasttime;
		if (mv_fdt > 0 && mv_fdt < 0.25)
		{
			if (mv_fdt > sv_mover_frame_interval)
				sv_mover_frame_interval = mv_fdt;
			else
				sv_mover_frame_interval =
					sv_mover_frame_interval * 0.995 + mv_fdt * 0.005;
		}
	}
	sv_mover_frame_lasttime = time;

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

	// multi_manager post-spawn pass: recover slots that a declared QC field name
	// swallowed during parsing, then free the slot edicts that were captured
	// onto entities which turned out not to be multi_managers.  Must run here
	// rather than in multi_manager(): both halves need every entity to exist.
	// One-shot per map, self-gated on mm_collide_done.  See sv_multi_manager.qc.
	MM_PostSpawnPass();

	// Same "every entity exists" requirement, same one-shot-per-map gating.
	CustomKey_Report();
	FuncGlobal_Report();

	// Map-script periodic work.  Self-gated to 10 Hz and an immediate return
	// when the map names no script, which is all 100+ corpus maps but two.
	MapScript_Frame();

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

		// Phys-prop tick constants (sv_physprop.qc PhysObj_Think / _DetectContactFX /
		// Carry_Tick).  These ran cvar() per prop PER TICK — at a few hundred props that
		// is thousands of string-hash lookups a second for values that change ~never.
		pp_cached_impact_min_speed  = cvar("sv_physprop_impact_min_speed");
		pp_cached_impact_hard_speed = cvar("sv_physprop_impact_hard_speed");
		pp_cached_impact_cooldown   = cvar("sv_physprop_impact_cooldown");
		pp_cached_slide_min_speed   = cvar("sv_physprop_slide_min_speed");
		pp_cached_slide_interval    = cvar("sv_physprop_slide_interval");
		pp_cached_scrape_track      = cvar("sv_physprop_scrape_track");
		pp_cached_stream_hz         = cvar("sv_physprop_stream_hz");
		pp_cached_sleep_enable      = cvar("sv_physprop_sleep");
		pp_cached_sleep_hz          = cvar("sv_physprop_sleep_hz");
		if (pp_cached_sleep_hz <= 0) pp_cached_sleep_hz = 8;
		pp_cached_debug             = cvar("sv_debug_physprops");
		pp_cached_wep_trace_bbox    = [cvar("sv_physprop_weapon_trace_bbox_x"),
		                              cvar("sv_physprop_weapon_trace_bbox_y"),
		                              cvar("sv_physprop_weapon_trace_bbox_z")];
		// One-shot sanity dump of the contact-FX tuning.  An UNREGISTERED cvar reads as
		// the empty string here and as 0 through cvar(), which silently turns every
		// threshold into "no threshold" — the impact test then fires on any deceleration
		// at all, including ODE's resting jitter.  Printing the STRINGS (not the floats)
		// is the whole point: '' distinguishes "missing" from a real 0.
		// (StartFrame runs at least once BEFORE worldspawn, so g_cvar_count gates
		// this to a tick where the table actually exists — otherwise it latches on
		// the pre-worldspawn frame and reports four empty strings every time.)
		if (pp_cached_debug && !pp_dbg_cvars_reported && g_cvar_count > 0)
		{
			pp_dbg_cvars_reported = TRUE;
			dprint(sprintf("[physprop] tuning impact_min='%s' impact_cd='%s' slide_min='%s' slide_int='%s'\n",
			               cvar_string("sv_physprop_impact_min_speed"),
			               cvar_string("sv_physprop_impact_cooldown"),
			               cvar_string("sv_physprop_slide_min_speed"),
			               cvar_string("sv_physprop_slide_interval")));
		}
		pp_cached_buoyancy          = cvar("sv_prop_buoyancy");
		pp_cached_buoy_density      = cvar("sv_prop_buoyancy_density");
		if (pp_cached_buoy_density <= 0) pp_cached_buoy_density = 1.0;
		pp_cached_buoy_damping      = cvar("sv_prop_buoyancy_damping");
		if (pp_cached_buoy_damping <= 0) pp_cached_buoy_damping = 0.4;
		pp_cached_gravity           = cvar("sv_gravity");
		if (pp_cached_gravity <= 0) pp_cached_gravity = 800;
		pp_cached_force_iter        = Phys_ForceIter();   // cvar_string + compare — never per-prop
		pp_cached_meshpitch         = cvar("r_meshpitch");
		if (!pp_cached_meshpitch) pp_cached_meshpitch = -1;
		pp_cached_meshroll          = cvar("r_meshroll");
		if (!pp_cached_meshroll) pp_cached_meshroll = 1;

		// Car tick constants — the reads a PARKED car still makes every tick.
		car_cached_mintic       = cvar("sv_mintic");
		car_cached_wheel_sink   = cvar("sv_car_wheel_sink");
		car_cached_box_yaw      = cvar("sv_car_box_yaw");
		car_cached_sleep_enable = cvar("sv_car_sleep");
	}

	// Once-a-second sweep for stranded scrape loops.  Placed AFTER the cache refresh
	// above because it reports through pp_cached_debug.  Self-gating: costs a single
	// compare while nothing on the map is sliding.
	PhysFiles_ScrapeWatchdog();

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

		// mp_nomapweapons is set EXPLICITLY in every branch below, not just the
		// two that want the strip.  Paintgun and prophunt turn it on and have
		// never turned it off again, which was invisible while cfg/server.cfg
		// shipped "1" — leaving prophunt for TDM landed on the same value it
		// started at.  Now that the default is "0" that latch would strip every
		// subsequent mode until a map reload, so each branch states its own.
		if (gamemode == GAMEMODE_BHOP)
		{
			cvar_set("mp_falldamage",   "0");
			cvar_set("mp_noblock",      "1");
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "1");
			cvar_set("mp_nomapweapons", "0");
		}
		else if (gamemode == GAMEMODE_FFA)
		{
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "0");
			cvar_set("mp_nomapweapons", "0");
		}
		else if (gamemode == GAMEMODE_ELIMINATION)
		{
			cvar_set("mp_respawn",      "0");
			cvar_set("mp_disabledoors", "0");
			cvar_set("mp_nomapweapons", "0");
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
			cvar_set("mp_nomapweapons", "0");
		}
		else if (gamemode == GAMEMODE_PROPHUNT)
		{
			// One life per round (elimination round flow).
			cvar_set("mp_respawn",      "0");
			cvar_set("mp_disabledoors", "0");
			// A 1-HP tincan must survive hopping off a crate.
			cvar_set("mp_falldamage",   "0");
			// Hiders are weaponless by design; strip map pickups so they
			// can't arm themselves mid-round.
			cvar_set("mp_nomapweapons", "1");
		}
		else  // TDM
		{
			cvar_set("mp_respawn",      "1");
			cvar_set("mp_disabledoors", "0");
			cvar_set("mp_nomapweapons", "0");
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
	Vote_Frame();	// trigger_vote countdown — driven here, not from a think on
			// the entity, so a vote survives its trigger_vote being
			// killtargeted while the clock is still running.

	// Synthesize missed input ticks for low-cl_netfps players so other
	// clients see them move smoothly instead of freeze-then-jump.
	SV_RunCommandContinuation();

	// nettest bots: advance the incremental nav-graph build (sv_navnodes.qc),
	// then run the bot fill + per-bot AI (sv_bots.qc).
	Nav_Tick();
	// Service queued path requests BEFORE the AI that consumes them, and under a
	// per-frame cap: a squadmaker wave all deciding to repath on the same frame
	// would otherwise run one full A* per monster inside this single StartFrame.
	Nav_ServiceRequests();
	// Reset the AI layer's per-frame LOS trace budget and re-read its cvars.
	// Monsters run on their own .nextthink during PHYSICS, which happens after
	// StartFrame, so this is the point at which the budget is refreshed for the
	// thinks that are about to run.
	AI_Tick();
	W_ProjTest();		// sv_proj_test: one monster-owned projectile, for the CSQC receive path
	W_HLEquipTest();	// sv_hlequip_test: fire satchel/tripmine/snark/hivehand once each
	W_AmmoSelfTest();	// sv_ammo_selftest: does a reserve pickup reach the gun that fires it
	Tank_SelfTest();	// sv_tank_selftest: force one shot out of every func_tank* on the map
	BigMomma_SelfTest();	// sv_bigmomma_selftest: does the gonarch's info_bigmomma chain resolve
	Tent_SelfTest();	// sv_tentacle_selftest: do the tentacle's baked sequence indices still hold
	AI_AnimRateSelfTest();	// sv_animrate_selftest: does a reversed .animrate reach the client
	SV_ShakeSelfTest();	// sv_shake_selftest: does a UTIL_ScreenShake reach the client
	AI_SoundSelfTest();	// sv_ai_sound_selftest: world-sound masks + the scared-gait speed pick
	FuncPushable_SelfTest();	// sv_pushable_selftest: does a shoved crate stop at a wall
	GlobalState_SelfTest();	// sv_globalstate_selftest: add/set/gate on HL's global table
	GlobalState_Report();	// sv_debug_globalstate: one-shot table dump per map
	Flock_SelfTest();	// sv_flock_selftest: do the Xen boids form a squad and fly
	Nih_SelfTest();		// sv_nihilanth_selftest: rig names, hl_c17's n_* set, spheres, flight
	W_WeaponAliasTest();	// sv_wpnalias_test: do aliased world models survive a round restart
	W_BreakObjTest();	// sv_breakobj_test: does a crate leave its spawnobject pickup behind
	W_SatchelSelfTest();	// sv_satchel_test: can you still detonate what you threw
	W_LauncherSelfTest();	// sv_launcher_test: do the five one-round launchers reload themselves
	W_PickupSelfTest();	// sv_pickup_test: weaponstay stays wired, no ammo re-farm,
				// m_flCustomRespawnTime revives on time, spawnflag 1024 never does
	Inv_SelfTest();		// sv_inventory_test: item_inventory collect/drop/return + the InventoryRules gate
	THEsc_SelfTest();	// sv_thescape_test: func_trackvehicle + trigger_look + trigger_playercheck + the th_escape script
	Bot_RunFrame();
	CarDbg_Tick();		// prop_car physics debug overlay: per-client proxies when sv_debug_car 1
	PhysFlood_Tick();	// drain the spawnflood queue a few props/frame (no mass-spawn hitch)

	// Admin trigger: `sv_roundrestart 1` (or alias command
	// `restartround`) queues a round restart after
	// mp_roundrestartdelay seconds. Resets itself to 0. SSQC has no
	// registercommand, so this cvar-toggle pattern is still the
	// underlying implementation.
	// Self-test for the look-at NPC readout (sv_lookatnpc.qc).  Same cvar-toggle idiom
	// as sv_roundrestart below, and for the same reason — SSQC has no registercommand.
	//
	// It exists because that feature is CROSSHAIR-triggered, and a headless harness
	// player spawns facing wherever the map's info_player_start points and never moves.
	// Two full 175-second runs on monster-dense maps produced not one [lookat] line:
	// the code was never reached, which from a log is indistinguishable from the code
	// being broken.  AIDbg_Spawn puts the monster at AIDbg_AimSpot, i.e. exactly where
	// the player is already aiming, so the very next 10 Hz tick's trace lands on it and
	// both halves of the wire print.
	// SELF-CLEARS ONLY ONCE IT HAS ACTUALLY DONE SOMETHING.  A plain clear-on-read
	// would make `+set sv_lookatnpc_test 1` on the command line useless: the first
	// StartFrame runs long before any client finishes connecting (the headless client
	// needs ~2 minutes on a big Sven map), so the flag would be consumed against an
	// empty player chain and nothing would ever spawn.  Latching until there is a real
	// client to aim for is what makes it usable from the harness.
	if (cvar("sv_lookatnpc_test"))
	{
		float spawned_for = 0;
		entity tp = player_chain_head;
		while (tp)
		{
			if (SV_PlayerHasNetchan(tp) && !tp.is_dead)
			{
				AIDbg_Spawn(tp, "monster_zombie", 1, 0);
				spawned_for = spawned_for + 1;
			}
			tp = tp.player_chain_next;
		}
		if (spawned_for)
		{
			cvar_set("sv_lookatnpc_test", "0");
			dprint(sprintf("[lookat] self-test spawned a zombie for %g player(s)\n",
			               spawned_for));
		}
	}

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
	// settings into cfg/server.cfg, mirroring the menu-side save path.
	if (cvar("sv_saveconfig"))
	{
		cvar_set("sv_saveconfig", "0");
		SV_WriteServerConfigFile();
	}

	// Admin trigger: `sv_writecvars 1` (or alias command `writecvars`)
	// overwrites cfg/allcommands.cfg from the shared cvar table
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
	// GoldSrc `game_end` fired — the map's own objective says we're done.
	// Handled here, ahead of the per-phase machine, so it lands from any phase
	// and goes straight to MAP_END rather than waiting on the round clock or
	// mp_maxrounds (the two conditions that normally gate the MAP_END
	// transition below).  Guarded so re-firing it during the end delay can't
	// keep pushing map_restart_time out.
	if (sv_game_end_requested && round_phase != ROUND_PHASE_MAP_END)
	{
		sv_game_end_requested = 0;
		round_phase      = ROUND_PHASE_MAP_END;
		map_restart_time = time + cvar("mp_maprestartdelay");
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
			if (gamemode == GAMEMODE_PROPHUNT)
			{
				// Prop Hunt: surviving the round clock IS the hiders' win.
				round_winning_team = TEAM_BLUE;
				blue_team_score += 1;
			}
			else
				round_winning_team = 0;
			round_phase = ROUND_PHASE_ROUND_END;
			round_restart_time = time + cvar("mp_roundrestartdelay");
		}
		// Check team elimination — applies to elim, paintgun and prop hunt, all
		// of which use the "one team left wins the round" win flow.  (Prop Hunt:
		// all hiders dead -> seekers win; all seekers dead, e.g. from missfire
		// self-damage -> hiders win.)
		else if (gamemode == GAMEMODE_ELIMINATION || gamemode == GAMEMODE_PAINTGUN
			|| gamemode == GAMEMODE_PROPHUNT)
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
			// Carry the current map's game spec forward - see ChangeLevel_Issue in
			// sv_trigger_changelevel.qc for why a bare changelevel can hand the
			// next map a different game's copy of a same-named WAD.
			ChangeLevel_Issue(nextmap);
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
				         || gamemode == GAMEMODE_DEFUSE || gamemode == GAMEMODE_PROPHUNT)
				{
					// Elimination / Paintgun / Defuse / Prop Hunt: one life per
					// round — hide body, enter spectator phase (no mid-round respawn).
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
		// Mirror the server's real mover tick rate so CSQC prediction reads it via
		// getstatf(STAT_FUNC_TICKRATE).  The EFFECTIVE rate, not the cvar: on a
		// server whose frame is longer than the cvar asks for, movers actually run
		// at the frame rate (Mover_TickInterval, sv_customdefs.qc) and a client
		// scaling its carry-slide by the cvar would be predicting a door that
		// travels twice as fast as the one the server is moving.
		e.sv_func_tickrate_value = 1.0 / Mover_TickInterval(40);
		e.sv_blue_score = blue_team_score;
		e.sv_red_score = red_team_score;
		e.sv_money = e.money;
		e.sv_armor = e.armor;
		e.sv_in_buyzone = Player_CanBuy(e);
		// Look-at NPC readout.  Self-throttled to 10 Hz and change-gated, so for a
		// player not due a pulse this is one float compare (sv_lookatnpc.qc).
		LookatNPC_Tick(e);
		// C4 carrier only: whether a plant is allowed at their spot right now,
		// so the client can gate the plant prefire animation (STAT_CAN_PLANT).
		e.sv_can_plant_c4 = (e.ammo_cfc4 > 0 && C4_CanPlantHere(e)) ? 1 : 0;
		// Medkit carrier only, same shape and same reason: whether there is
		// anyone in front of them worth spending a charge on, so the client can
		// gate the heal/revive animation instead of playing it into thin air.
		// Two traces, and only while the medkit is actually in hand.
		e.sv_can_medkit = (e.weapon == WEP_MEDKIT) ? W_MedkitStatBits(e) : 0;
		// SOFLAM carrier only, same shape again.
		e.sv_can_soflam = (e.weapon == WEP_ASSOFLAM && e.ammo_soflam > 0
		                   && W_SoflamFindTarget(e)) ? 1 : 0;
		// Defuse-only: 1 while the bomb is down, so the HUD hides the round
		// timer (the round clock is suspended — see the timer-expiry guard).
		e.sv_bomb_planted = (gamemode == GAMEMODE_DEFUSE && bomb_planted) ? 1 : 0;
		// Tactical shield, packed into one stat — see STAT_SHIELD.
		e.sv_shield_state = (e.has_shield ? SHIELD_CARRIED : 0)
		                  | (e.shield_deployed ? SHIELD_DEPLOYED : 0);

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

		// ...and every NPC near a player.  Bounded, unlike the player walk above:
		// MULTICAST_PVS filters delivery but not the walk, and pizza_ya_san1 places
		// hundreds of monsters while this runs every tick.  Near-a-player + a hard
		// cap.  A vlen is free next to a multicast (same reasoning as
		// MON_CULL_MAX_DIST in sv_monsters.qc).
		float npc_hb_sent = 0;
		entity m = monster_chain_head;
		while (m && npc_hb_sent < 32)
		{
			if (m.solid != SOLID_NOT && m.modelindex && m.health > 0)
			{
				entity pp = player_chain_head;
				while (pp)
				{
					if (!pp.is_dead && vlen(pp.origin - m.origin) <= 1024)
						break;
					pp = pp.player_chain_next;
				}
				if (pp)
				{
					W_SendServerNPCHitbox(m, 2);
					npc_hb_sent = npc_hb_sent + 1;
				}
			}
			m = m.monster_chain_next;
		}
	}
};


void() worldspawn =
{

	// Reset per-map state that's held in QC file-scope globals — FTE
	// doesn't reload progs between map loads, so any global that
	// accumulates across a map (camera linked-list head, one-shot
	// flags, cycling RNG state) needs an explicit clear here.
	//
	// The GoldSrc latch MUST be cleared first: worldspawn is entity 0 and
	// its spawn function runs before any other entity's, so clearing here
	// guarantees the first Map_IsGoldSrc() caller re-probes serverinfo for
	// THIS map rather than inheriting the previous map's answer.
	sv_map_goldsrc_cache  = 0;

	// sv_ode_loaded is a THREE-state latch (0 = unprobed, 1 = ODE attached,
	// -1 = physics unavailable) and cvars survive a map change, so a "-1" stamped
	// on a map where plug_load had not finished yet would otherwise persist for the
	// whole server process.  The one-shot attach at :992 only retries on == 0, so
	// nothing would ever clear it and every phys prop stays inert until restart.
	// Re-arm it here, next to the GoldSrc latch and for the same reason: worldspawn
	// runs before any other entity, so each map gets exactly one fresh probe.
	cvar_set("sv_ode_loaded", "0");

	monster_chain_head    = world;   // rebuilt as this map's monsters spawn
	monster_chain_count   = 0;       // ...and its cap, which Monster_Chain_Verify walks against
	mon_socb_extra_n      = 0;       // the tentacle/nihilanth shot-cull side-list, same reason
	sv_game_end_requested = 0;

	// HL's MonsterInit / StartMonster split.  worldspawn is entity 0 and spawns
	// before anything else in the lump, so raising the latch here covers every
	// map-placed monster; AI_DeferredPlacePass lowers it again at time+0.001,
	// after ED_LoadFromFile has finished and before any other think has run.
	// Without this, a monster standing on a func_wall that comes LATER in the
	// entity lump drops straight through it — th_ep1_03's raft otis lands on the
	// lake bed 172 units down.
	ai_lump_parsing = TRUE;
	entity ai_place_pass = spawn();
	ai_place_pass.classname = "ai_deferred_place";
	ai_place_pass.think     = AI_DeferredPlacePass;
	ai_place_pass.nextthink = time + 0.001;
	mm_collide_done       = 0;       // re-arm the per-map multi_manager collision scan

	// Sven "$" custom keyvalues.  Every string in that table is strzone'd, so
	// without this the previous map's variables both leak and stay visible to
	// this map's trigger_conditions.  worldspawn is entity 0 and spawns before
	// anything else, so the clear cannot race a harvest — with one caveat: a "$"
	// key on worldspawn ITSELF is parsed before this runs and would be wiped.
	// No map in the corpus puts one there.
	CustomKey_ResetForMap();

	// func_global / trigger_save re-arm their census line only.  Their STORE is
	// deliberately not reset here — surviving a changelevel is the whole point
	// of it, and the FILE is what provides that.  Not the globals: PR_Deinit
	// runs on every map load (engine sv_init.c:945), so by the time worldspawn
	// executes there is nothing left in memory to reset anyway.  See the note in
	// server/sv_mapglobals.qc before adding anything mg_*/msave_* here.
	MapGlobal_ResetPerMap();

	// Half-Life's global state table, same story: cfg/globalstate.txt carries it,
	// and 8 of the 24 names in the corpus need that (set on one map, read on
	// another).  This call re-arms the per-map latches and decides whether the
	// file may be read at all — sv_globalstate_persist 0 is the opt-out.
	GlobalState_MapStart();

	// The map script's name and any per-map state it holds.  Cleared here so a
	// map with no cfg cannot inherit the previous map's script; the cfg is
	// applied later in the load, which is what re-establishes it.
	MapScript_ResetForMap();

	// The trigger dispatch's "nobody set a use type" sentinel.  A QC global
	// reads 0 before first assignment, and USE_OFF is 0, so this MUST be seeded
	// explicitly or the very first chain of the map would be dispatched as an
	// explicit Off instead of falling back to USE_TOGGLE.  See the USE_UNSET
	// note in sv_customdefs.qc.  worldspawn runs before any other entity's spawn
	// function, so this is early enough for all of them.
	sub_use_type          = USE_UNSET;

	// path_track's next/prev/alt graph is built lazily by the first consumer
	// that needs it (sv_path_track.qc).  The "already built" latch is a global,
	// so it survives a map change and would leave the new map's trains walking
	// links that were never resolved.
	pathtrack_links_built = 0;
	Cutscene_ResetState();           // sv_trigger_camera.qc
	Vote_ResetState();               // sv_trigger_vote.qc
	Camera_ResetState();
	Nav_Reset();		// nettest bots: clear the nav graph before this map's info_node entities spawn
	Monster_BuiltinProbe();	// sv_monster_probe 1: dump HL .mdl sequence data readable from SSQC
	// NOTE: AI_Init() is deliberately NOT here.  It reads its own cvars, and the
	// mod's cvar table is not registered until CVar_Init() ~160 lines below, so
	// every default would read as 0 — sv_ai_enable included, which silently left
	// every map-placed monster inert.  It is called just after CVar_Init(), which
	// is still inside worldspawn and therefore still before any entity spawns.
	// Sven's globalmodellist, BEFORE precache_everything() below and before
	// AI_Init() further down — both precache wholesale, and a remap installed
	// after them would leave the canonical model precached and the replacement
	// not.  Safe to read self.globalmodellist here: worldspawn's keyvalues are
	// all parsed before its spawn function body runs.
	//
	// ...but worldspawn is only ONE of the two places Sven takes the key, and the
	// They Hunger campaign uses the other one exclusively — see
	// SV_ResolveGlobalList above.  Resolve, then write the answer BACK onto
	// worldspawn's own field, because other readers key off it directly
	// (sv_sentences.qc tests world.globalsoundlist for "hunger" to pick the TH
	// sentence file).  Push both into serverinfo as well: CSQC builds the SAME
	// table for the first-person viewmodel and cannot read a server-side cfg.
	// forceinfokey rather than localcmd("serverinfo ...") so the key is live
	// immediately instead of after the command buffer drains — CSQC_WorldLoaded
	// on a listen server does not wait for that.
	self.globalmodellist = SV_ResolveGlobalList("globalmodellist", self.globalmodellist);
	forceinfokey(world, "globalmodellist", self.globalmodellist);
	Modellist_Reset();
	Modellist_Load(self.globalmodellist);
	// ...and the sound half, for the same reason and at the same moment: 12 of
	// the 20 They Hunger maps set globalsoundlist, and precache_everything()
	// below walks every canonical sound name through the wrapper.
	self.globalsoundlist = SV_ResolveGlobalList("globalsoundlist", self.globalsoundlist);
	forceinfokey(world, "globalsoundlist", self.globalsoundlist);
	GSoundlist_Reset();
	GSoundlist_Load(self.globalsoundlist);
	Surf_LoadMaterials();	// scripts/surfaceprops.txt -> texture material table (sh_surfaceprops.qc)
	PropMat_LoadMaterials();	// scripts/propmaterials.txt -> prop material+weight table (sh_propmaterials.qc)
	MatSnd_LoadSounds();	// scripts/materialsounds.txt -> per-material contact sound sets (sh_matsounds.qc).
				// MUST precede precache_everything() below, which walks this table.

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
	localcmd("serverinfo modname quakers\n");

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
	// applies. cfg/engine_tweaks.cfg has these listed too but that
	// file isn't auto-exec'd anywhere — pushing from QC is the only
	// reliable place that survives across map loads + server.cfg
	// reloads.
	localcmd("sv_maxrate 0\n");
	localcmd("sv_maxdrate 0\n");

	// Load the rigid-body physics plugin before precache_everything() so that
	// phys_barrel_precache()'s physics_supported(TRUE) call sees it.
	// cfg/default.cfg used to handle this, but that file is client-only
	// now, so dedicated servers rely on this localcmd instead.
	// plug_load is idempotent — loading a plugin already loaded is a no-op.
	//
	// nettest: the backend is selectable. Box3D (fteplug_box3d) is THE backend — every
	// prop, ragdoll and vehicle runs on it — and it is the only physics plugin the
	// release ships (see PLATFORM_ENGINE_FILES in launcher/publish.py).
	//
	// `sv_physics_engine ode` is a DEV-ONLY escape hatch and it is not safe on a normal
	// install: only one physics plugin can be active at a time (whichever registers
	// first wins), so selecting ODE has to plug_close box3d BEFORE loading it — and if
	// fteplug_ode_* is not beside the exe, that load fails and the server is left with
	// NO physics backend at all rather than falling back. Use it only on a machine that
	// still has the ODE plugin, and expect to restart to get back.
	//
	// This runs at server init before any physics body exists, so closing is safe.
	if (cvar_string("sv_physics_engine") == "ode")
	{
		localcmd("plug_close box3d\n");
		localcmd("plug_load ode\n");
	}
	else
	{
		// No plug_close ode here any more: nothing loads it at boot (cfg/default.cfg and
		// cfg/ftesrv.cfg plug_load box3d/hl2/cod only) and the release does not ship it,
		// so the close was tidying up a backend that was never there.
		localcmd("plug_load box3d\n");
		// Box3D is "the multicore backend" but ships single-threaded (physics_box3d_threads
		// default 1).  Fork/join the contact solver across cores so a dense settling pile
		// (e.g. spawnflood) doesn't grind one core into a 1-FPS plateau.  Live-tunable:
		// drop to 1 if any instability, raise toward core count for more.  (substeps stays 4.)
		localcmd("physics_box3d_threads 8\n");
	}
	localcmd("alias roundrestart \"sv_roundrestart 1\"\n");
	localcmd("alias roundreset \"sv_roundrestart 1\"\n");
	localcmd("alias resetround \"sv_roundrestart 1\"\n");
	localcmd("alias restartround \"sv_roundrestart 1\"\n");
	localcmd("alias writecvars \"sv_writecvars 1\"\n");

	precache_everything();
	precache_sound("sounds/effects/zipup.wav");   // Kevlar/helmet buy confirm
	// GoldSrc's own silence, and the only way QC can stop a looping sound on a
	// channel — see SV_StopChannel (sv_doors.qc).  Precached here rather than in
	// any one class because six unrelated subsystems stop loops (doors, plats,
	// func_train, func_tracktrain, func_guntarget, the grapple and the They
	// Hunger movers), and a per-class precache would leave whichever one runs on
	// a map with no doors to late-precache it.
	precache_sound(SND_SILENCE);

	Lagcomp_Init();
	Killcam_SV_Init();		// nettest: reset the server killcam ring on (re)spawn of the server

	clientstat(STAT_CROSSHAIR_BASESPREAD, EV_FLOAT,   sv_crosshair_basespread);
	clientstat(STAT_CROSSHAIR_MOVESPREAD, EV_FLOAT,   sv_crosshair_movespread);
	clientstat(STAT_CROSSHAIR_FULLSPEED,  EV_FLOAT,   sv_crosshair_fullspeed);
	clientstat(STAT_CROSSHAIR_GAPSCALE,   EV_FLOAT,   sv_crosshair_gapscale);
	// EV_FLOAT, matching the `.float` field — see the STAT_CUTSCENE note below
	// for why EV_INTEGER on a float field ships raw bits.  Nothing reads this
	// stat today (sh_weapons.qc), so the old EV_INTEGER was harmless, but it
	// would have bitten whoever wired it up next.
	clientstat(STAT_CROSSHAIR_DISABLED,         EV_FLOAT,    sv_crosshair_disabled);

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
	clientstat(STAT_CAN_MEDKIT, EV_FLOAT, sv_can_medkit);
	clientstat(STAT_CAN_SOFLAM, EV_FLOAT, sv_can_soflam);
	clientstat(STAT_BOMB_PLANTED, EV_FLOAT, sv_bomb_planted);
	clientstat(STAT_SHIELD, EV_FLOAT, sv_shield_state);
	// Defuse progress (0..CFC4_DEFUSE_TIME), set per-tick by
	// C4_TickDefuseInteraction on the active defuser — drives HUD_DrawDefuseBar.
	// Without this registration the field never networks and the bar never shows.
	clientstat(STAT_DEFUSE_PROGRESS, EV_FLOAT, defuse_progress_stat);

	// nettest progression spine (Part 1): persistent XP / level + session XP.
	clientstat(STAT_XP, EV_FLOAT, sv_xp);
	clientstat(STAT_LEVEL, EV_FLOAT, sv_level);
	clientstat(STAT_XP_NEXT, EV_FLOAT, sv_xp_next);
	clientstat(STAT_PROG_SESSIONXP, EV_FLOAT, sv_sessionxp);

	// Sven trigger_camera binding + presentation flags, packed into one stat.
	// EV_FLOAT because sv_cutscene_stat is a `.float` (sv_customdefs.qc).  The
	// EV_* argument declares the FIELD's storage type, not the desired wire
	// type: SV_UpdateQCStats reads the eval_t union with `eval->_int` for
	// EV_INTEGER, so registering a float field as EV_INTEGER ships the raw
	// IEEE-754 bits (65958 went out as 0x4780D300) and the client decodes a
	// nonsense entnum.  Floats hold integers exactly to 2^24 and this payload
	// peaks at 0x1FFFFF, so nothing rounds — the bitfield is safe in a float.
	clientstat(STAT_CUTSCENE, EV_FLOAT, sv_cutscene_stat);
	Prog_DBInit();	// open the sqlite player store + ensure schema (once)

	// All custom cvars are registered from a single shared table —
	// edit shared/sh_cvar_table.qc CVar_Init() to change defaults or
	// add new cvars. The table is the source of truth for the auto-
	// generated cfg/allcommands.cfg too.
	CVar_Init();
	CVar_RegisterMine();
	CVar_CheckOverflow();   // loud if the table could not fit — see sh_cvar_table.qc

	// Monster AI boot: build the schedule/task table and precache + warm the AI
	// classes' models.  Placed HERE, immediately after the cvar table exists,
	// because AI_Init caches sv_ai_* — read any earlier and every default is 0,
	// which switches the whole AI layer off without saying so.  Still inside
	// worldspawn, so it comfortably precedes every entity the map spawns; that
	// ordering is required both ways, since each monster's Monster_Build reads
	// the cache and SVPR_GetCModel BLOCKS on first model access.
	AI_Init();

	// Headless entity-fire hook — no-op unless sv_debug_firetarget names
	// something.  HERE and not at the top of worldspawn, for exactly the reason
	// spelled out for AI_Init above: it reads cvars, and before CVar_Init() the
	// mod's table does not exist, so cvar_string() came back empty and the hook
	// silently never armed.
	AIDbg_FireTargetInit();

	// Half-Life's dialogue table.  Must be here, in worldspawn, because every
	// word of every sentence needs precache_sound and that is the only place it
	// may be called - a sentence precached later plays as "not precached" and is
	// dropped, which is exactly how the body-drop sounds failed.
	Sentences_Precache();

	// FTE engine pre-registers a few cvars with values that disagree
	// with the mod's intended defaults (e.g., sv_accelerate "10",
	// sv_maxspeed "320"). registercvar() above can't override an
	// already-registered cvar, so force-set the mod's defaults here.
	// cfg/server.cfg is applied immediately after this block, so admins
	// who want to override still get their value applied.
	cvar_set("sv_accelerate",    "5");
	cvar_set("sv_airaccelerate", "150");
	cvar_set("sv_maxspeed",      "270");
	cvar_set("sv_eye_height",    "64");
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
	// explicitly. Admins can still override via cfg/server.cfg.
	cvar_set("sv_minpitch",      "-90");
	cvar_set("sv_maxpitch",      "90");

	// Tickrate default — 64 Hz (CS-standard). FTE's engine baseline is
	// 60 Hz and older install configs may have 100 Hz cached from
	// prior defaults. cfg/server.cfg is applied immediately after this
	// block so admins can still override.
	cvar_set("sv_mintic",        "0.015625");
	cvar_set("sv_maxtic",        "0.015625");

	// Now apply persisted overrides from cfg/server.cfg directly.
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
