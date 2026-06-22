// server/sv_progression.qc
// ----------------------------------------------------------------------------
// Part 1 of the "progression spine": persistent per-player XP / levels.
//
// Players earn XP for kills, headshots, bomb plant/defuse, round win/lose and
// match completion.  XP accumulates into levels (each with a rank title) and is
// PERSISTED to a sandboxed SQLite database keyed on the engine client GUID, so a
// player's progress follows them across reconnects and map changes.
//
// Pure QC: SQLite is compiled into this build (config_fteqw.h USE_SQLITE -> SQL),
// exposed via the FTE_SQL builtins (sqlconnect/sqlopenquery/sqlreadfield/...).
// The DB file is auto-created at  nettest/sqlite/nettest_stats.db  (FS_GAMEONLY
// sandbox — we only pass the bare name, the engine builds the path).
//
// Compile order: this file is listed in sv_progs.src BEFORE sv_money.qc, so the
// Prog_* functions exist before every call site (sv_money round-end, sv_weapons
// PlayerKilled, sh_wpn_cfc4 plant/defuse, sv_player connect/disconnect/spawn,
// sv_main start-frame).  The per-player .prog_* fields are declared in
// sv_customdefs.qc (compiled earlier still); the STAT_* consts in sh_customdefs.qc.
// ----------------------------------------------------------------------------

// --- XP award amounts (tunable; kept as consts for v1) ----------------------
const float PROG_XP_KILL      = 100;	// per enemy kill
const float PROG_XP_HEADSHOT  = 50;	// bonus on top of a kill when it's a headshot
const float PROG_XP_PLANT     = 150;	// completing a bomb plant
const float PROG_XP_DEFUSE    = 150;	// completing a defuse
const float PROG_XP_ROUNDWIN  = 250;	// on the winning team at round end
const float PROG_XP_ROUNDLOSE = 75;	// on the losing team at round end (time is never wasted)
const float PROG_XP_MATCHEND  = 200;	// match/map completion bonus

const float PROG_AUTOSAVE_SECS = 60;	// flush a dirty player to the DB at most this often

// --- DB handle --------------------------------------------------------------
float prog_db;		// sqlconnect server index; < 0 == unavailable
float prog_db_ready;	// 1 once connected and the schema is ensured

// No-op result callback for fire-and-forget writes (INSERT/UPDATE/CREATE).
void(float srv, float qid, float rows, float cols, float eof, float firstrow) Prog_WriteDone =
{
};

// Escape a string for safe embedding in a SQL literal.
string(string s) Prog_Esc =
{
	if (prog_db < 0)
		return s;
	return sqlescape(prog_db, s);
};

// XP needed to advance FROM <lvl> to <lvl+1>.  Gentle ramp (L1->2 = 800).
float(float lvl) Prog_XPForLevel =
{
	return 800 + (lvl - 1) * 400;
};

// Rank title for a level band (MW2-ish military ladder).
string(float lvl) Prog_RankName =
{
	if (lvl >= 50) return "Commander";
	if (lvl >= 40) return "Captain";
	if (lvl >= 30) return "Lieutenant";
	if (lvl >= 20) return "Sergeant";
	if (lvl >= 10) return "Corporal";
	if (lvl >= 5)  return "Private";
	return "Recruit";
};

// Seed a brand-new (or identity-less) player.
void(entity pl) Prog_InitDefaults =
{
	pl.prog_xp      = 0;
	pl.prog_level   = 1;
	pl.prog_xp_next = Prog_XPForLevel(1);
};

// Copy authoritative fields into their clientstat mirrors (immediate push;
// StartFrame also mirrors every tick).
void(entity pl) Prog_PushStats =
{
	pl.sv_xp        = pl.prog_xp;
	pl.sv_level     = pl.prog_level;
	pl.sv_xp_next   = pl.prog_xp_next;
	pl.sv_sessionxp = pl.prog_match_xp;
};

// Roll any banked XP into levels.  Level only ever increases; the client
// detects the STAT_LEVEL increase and plays the rank-up fanfare.
void(entity pl) Prog_CheckLevelUp =
{
	while (pl.prog_xp >= pl.prog_xp_next && pl.prog_level < 999)
	{
		pl.prog_xp      = pl.prog_xp - pl.prog_xp_next;
		pl.prog_level   = pl.prog_level + 1;
		pl.prog_xp_next = Prog_XPForLevel(pl.prog_level);
	}
};

// --- DB lifecycle -----------------------------------------------------------
void() Prog_DBInit =
{
	if (prog_db_ready)
		return;
	prog_db = sqlconnect("", "", "", "nettest_stats", "sqlite");
	if (prog_db < 0)
	{
		dprint("^1[prog] sqlite unavailable - progression will not persist\n");
		return;
	}
	sqlopenquery(prog_db, Prog_WriteDone, 0,
		"CREATE TABLE IF NOT EXISTS players (guid TEXT PRIMARY KEY, name TEXT, xp REAL, level REAL, xp_next REAL, kills REAL, deaths REAL, headshots REAL, wins REAL, playtime REAL, last_seen REAL);");
	prog_db_ready = 1;
	dprint("^2[prog] sqlite ready: nettest/sqlite/nettest_stats.db\n");
};

// Persist a player's current row (UPDATE; the row is guaranteed by Prog_Load's
// INSERT OR IGNORE).  Cheap to call repeatedly; clears the dirty flag.
void(entity pl) Prog_Save =
{
	if (!pl.prog_loaded || pl.prog_guid == "" || prog_db < 0)
		return;
	// Build the UPDATE in pieces: fteqcc passes at most 8 args to a varargs
	// builtin, so a single 11-arg sprintf would silently drop fields.
	string q = sprintf("UPDATE players SET name='%s', xp=%g, level=%g, xp_next=%g, ",
			Prog_Esc(pl.netname), pl.prog_xp, pl.prog_level, pl.prog_xp_next);
	q = strcat(q, sprintf("kills=%g, deaths=%g, headshots=%g, wins=%g, ",
			pl.prog_kills, pl.prog_deaths, pl.prog_headshots, pl.prog_wins));
	q = strcat(q, sprintf("playtime=%g, last_seen=%g WHERE guid='%s';",
			pl.prog_playtime, time, Prog_Esc(pl.prog_guid)));
	sqlopenquery(prog_db, Prog_WriteDone, 0, q);
	pl.prog_dirty = 0;
};

// Async SELECT result: self is restored to the originating player (or world if
// they already left).  Applies the DB row, then folds in any XP earned during
// the (sub-second) load gap.
void(float srv, float qid, float rows, float cols, float eof, float firstrow) Prog_LoadResult =
{
	if (self == world || self.classname != "player")
		return;
	if (rows > 0)
	{
		// columns: 0 guid, 1 name, 2 xp, 3 level, 4 xp_next, 5 kills,
		//          6 deaths, 7 headshots, 8 wins, 9 playtime
		self.prog_xp        = stof(sqlreadfield(srv, qid, firstrow, 2));
		self.prog_level     = stof(sqlreadfield(srv, qid, firstrow, 3));
		self.prog_xp_next   = stof(sqlreadfield(srv, qid, firstrow, 4));
		self.prog_kills     = stof(sqlreadfield(srv, qid, firstrow, 5));
		self.prog_deaths    = stof(sqlreadfield(srv, qid, firstrow, 6));
		self.prog_headshots = stof(sqlreadfield(srv, qid, firstrow, 7));
		self.prog_wins      = stof(sqlreadfield(srv, qid, firstrow, 8));
		self.prog_playtime  = stof(sqlreadfield(srv, qid, firstrow, 9));
		if (self.prog_level < 1)
			self.prog_level = 1;
		if (self.prog_xp_next <= 0)
			self.prog_xp_next = Prog_XPForLevel(self.prog_level);
	}
	// XP banked before the row arrived (Prog_AwardXP queues it while !loaded).
	if (self.prog_pending_xp > 0)
	{
		self.prog_xp       = self.prog_xp + self.prog_pending_xp;
		self.prog_match_xp = self.prog_match_xp + self.prog_pending_xp;
		self.prog_pending_xp = 0;
		Prog_CheckLevelUp(self);
	}
	self.prog_loaded = 1;
	Prog_PushStats(self);
};

// Begin loading a player's stats.  Call once the entity exists and userinfo is
// readable (PutClientInServer).  GUID-keyed; falls back to IP; bots / identity-
// less clients run unpersisted.
void(entity pl) Prog_Load =
{
	string g, ge, ne;

	pl.prog_loaded     = 0;
	pl.prog_pending_xp = 0;
	pl.prog_match_xp   = 0;
	pl.prog_last_save  = time;
	Prog_InitDefaults(pl);

	g = infokey(pl, "guid");
	if (g == "")
		g = infokey(pl, "ip");
	if (g == "" || g == "bot" || prog_db < 0)
	{
		// No stable identity (or no DB) — play unpersisted this session.
		pl.prog_guid   = "";
		pl.prog_loaded = 1;
		Prog_PushStats(pl);
		return;
	}

	pl.prog_guid = g;
	ge = Prog_Esc(g);
	ne = Prog_Esc(pl.netname);

	// Guarantee a row exists (no clobber on conflict), then read it back.
	// Queries run FIFO on the sqlite worker, so the INSERT lands first.
	sqlopenquery(prog_db, Prog_WriteDone, 0,
		sprintf("INSERT OR IGNORE INTO players (guid, name, xp, level, xp_next, kills, deaths, headshots, wins, playtime, last_seen) VALUES ('%s', '%s', 0, 1, %g, 0, 0, 0, 0, 0, %g);",
			ge, ne, Prog_XPForLevel(1), time));

	// The SELECT callback runs with self = pl (engine restores it).
	entity prev_self = self;
	self = pl;
	sqlopenquery(prog_db, Prog_LoadResult, 0,
		sprintf("SELECT guid, name, xp, level, xp_next, kills, deaths, headshots, wins, playtime FROM players WHERE guid='%s';", ge));
	self = prev_self;
};

// Award XP to a player.  Routed through here so all sources level-up uniformly.
// While stats are still loading, the amount is banked and applied by the load
// callback (avoids the DB row overwriting freshly-earned XP).
void(entity pl, float amt, string reason) Prog_AwardXP =
{
	if (pl.classname != "player" || amt <= 0)
		return;
	if (!pl.prog_loaded)
	{
		pl.prog_pending_xp = pl.prog_pending_xp + amt;
		return;
	}
	pl.prog_xp       = pl.prog_xp + amt;
	pl.prog_match_xp = pl.prog_match_xp + amt;
	Prog_CheckLevelUp(pl);
	pl.prog_dirty = 1;
};
