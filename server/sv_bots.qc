// server/sv_bots.qc
// ----------------------------------------------------------------------------
// Server-side bots (v1: navigate + fight).
//
// Bots are FTE fake clients (spawnclient()) that occupy real player slots and
// REUSE the human code paths: PlayerJoinTeam/PlayerSpawn for spawning + loadout,
// PlayerPreThink (weapon fire) + SV_RunClientCommand (PM_PlayerMove) + PlayerPostThink
// for movement/combat — driven each frame by AI that sets the same input_* globals
// a real client's usercmd would.  They navigate the nav graph (sv_navnodes.qc, A*)
// when they can't see an enemy, and aim+fire (skill-tunable) when they can.
//
// Admin control follows the mod's cvar-trigger convention (SSQC has no
// registercommand): bot_minplayers (persistent fill), botadd /
// botkick (momentary, reset to 0), bot_skill (0-100 aim/reaction).
//
// Compile order: after sv_player.qc (PlayerJoinTeam/PlayerSpawn/PlayerPreThink/
// SV_RunClientCommand) + sv_navnodes.qc (Nav_*), before sv_main.qc (StartFrame
// calls Bot_RunFrame).  Per-bot .fields are in sv_customdefs.qc.
// ----------------------------------------------------------------------------

const float BOT_MAXSLOT = 32;	// player slots (per-bot path slices indexed by slot)
const float BOT_PATHLEN = 24;	// max waypoints cached per bot
const float BOT_WALK    = 130;	// move magnitude when fine-aiming / strafing
const float BOT_RUN     = 240;	// normal travel magnitude (× weapon speed factor; no sprint).
				// NOTE: this is the bot's WISHSPEED — and pmove accel scales with
				// wishspeed (accelspeed = accel*frametime*wishspeed), so a low value
				// makes bots both SLOW to accelerate AND low top-speed.  180 felt
				// sluggish; 240 (≈89% of sv_maxspeed 270) is clearly below a human
				// but not crawling.  Verify with cl_speedometer in spectate.
const float BOT_MELEE_RANGE = 72;	// only swing the knife once this close
const float BOT_SPRAY_RANGE = 250;	// inside this, spray continuously instead of bursting
const float BOT_AVOID_RADIUS  = 56;	// avoidance: peel away from other players within this range
const float BOT_LOOKAHEAD     = 44;	// avoidance: wall lookahead trace distance ahead of the bot
const float BOT_JUMP_LOOKAHEAD = 30;	// auto-jump: forward probe distance for a blocking ledge
const float BOT_STEP_SKIP      = 20;	// auto-jump/avoid: raise the LOW trace floor above PM_STEPSIZE (18)
const float BOT_JUMP_CLEAR     = 40;	// auto-jump: tallest ledge the bot will hop onto (jump apex ~45)
const float BOT_WEDGE_DIST     = 24;	// avoidance: "wedged into another player" range (separate even an enemy; give way)
const float BOT_RETARGET_INT   = 0.5;	// targeting: re-pick the nearest VISIBLE enemy this often, even mid-fight
const float BOT_HURT_FOCUS     = 1.5;	// targeting: after being hit, hold off the periodic re-pick this long (let the attacker-snap stick)
float bot_pathnodes[BOT_MAXSLOT * BOT_PATHLEN];
float bot_dbg_filltime;	// throttle for the bot_debug fill print
float bot_dbg_acttime;	// throttle for the per-frame bot activity print
float bot_dbg_aimtime;	// throttle for the aim-trace debug

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
string(float n) Bot_PickName =
{
	n = n - floor(n / 12) * 12;
	if (n == 0)  return "Maverick";
	if (n == 1)  return "Ghost";
	if (n == 2)  return "Reaper";
	if (n == 3)  return "Viper";
	if (n == 4)  return "Hawk";
	if (n == 5)  return "Rook";
	if (n == 6)  return "Tango";
	if (n == 7)  return "Echo";
	if (n == 8)  return "Blaze";
	if (n == 9)  return "Frost";
	if (n == 10) return "Wraith";
	return "Nomad";
};

float(entity bot, entity t) IsBotEnemy =
{
	if (t == bot || t.classname != "player" || t.is_dead)
		return FALSE;
	if (t.player_team == TEAM_NONE || t.player_team == TEAM_SPEC)
		return FALSE;			// team-selecting / spectating = not in the game, never a target
	if (Gamemode_HasUnifiedTeams())
		return TRUE;			// FFA / Bhop: everyone is a target
	return (bot.player_team != t.player_team);
};

float() Bot_Count =
{
	entity e; float n = 0;
	for (e = world; (e = find(e, classname, "player")); )
		if (e.is_bot) n = n + 1;
	return n;
};

float() Bot_HumanCount =
{
	entity e; float n = 0;
	for (e = world; (e = find(e, classname, "player")); )
		if (!e.is_bot && e.player_team != TEAM_NONE) n = n + 1;
	return n;
};

float() Bot_AutoTeam =
{
	entity e; float b = 0, r = 0;
	for (e = world; (e = find(e, classname, "player")); )
	{
		if (e.player_team == TEAM_BLUE) b = b + 1;
		else if (e.player_team == TEAM_RED) r = r + 1;
	}
	return (r < b) ? TEAM_RED : TEAM_BLUE;
};

const float BOT_SIGHT = 3000;	// max acquisition distance (was the findradius)

// Acquire the nearest VISIBLE enemy inside the frontal vision cone (bot_fov).
// Walks the players-only chain with an explicit distance gate (replaces the
// findradius-over-all-entities scan).  The cone restricts NEW acquisition only —
// TRACKING an already-held bot_enemy stays 360-degree (the >5s memory window in
// Bot_Think keeps it, not this scan).  ignorecone TRUE skips the cone entirely.
entity(float ignorecone) Bot_FindEnemyEx =
{
	entity e, best = world; float bestd = BOT_SIGHT * BOT_SIGHT;
	vector eye = self.origin + self.view_ofs;

	// Frontal cone: half-angle cosine.  fov<=0 or >=360 -> full 360 (disabled).
	float fov = cvar("bot_fov");
	float use_cone = (!ignorecone && fov > 0 && fov < 360);
	float coscone = use_cone ? cos((fov * 0.5) * 0.0174532925) : -2;	// -2 = always passes the dot test
	vector fwd = '0 0 0';
	if (use_cone) { makevectors(self.v_angle); fwd = v_forward; }

	for (e = player_chain_head; e; e = e.player_chain_next)
	{
		if (!IsBotEnemy(self, e))
			continue;
		vector ep = e.origin + e.view_ofs;
		vector d  = ep - eye;
		float d2  = d * d;			// squared distance; the bestd seed also gates the BOT_SIGHT range
		if (d2 >= bestd)
			continue;			// farther than the best so far (or beyond sight range)
		if (use_cone && (normalize(d) * fwd) < coscone)
			continue;			// outside the frontal cone -> not acquired
		traceline(eye, ep, MOVE_NOMONSTERS, self);
		if (trace_fraction < 1 && trace_ent != e)
			continue;			// no line of sight
		bestd = d2; best = e;
	}
	return best;
};
entity() Bot_FindEnemy = { return Bot_FindEnemyEx(FALSE); };

// Visibility-first reselection with distance hysteresis.  `cur` is the held target.
// Returns the closest VISIBLE enemy, but won't abandon a still-valid current target
// for a near-equal-distance one (anti-thrash); a visible candidate is always
// preferred over an invisible/stale current target.
entity(entity cur) Bot_PickEnemy =
{
	entity best = Bot_FindEnemy();		// closest VISIBLE enemy (or world)
	if (!cur || cur.is_dead || !IsBotEnemy(self, cur))
		return best;			// no valid current -> take best (may be world)
	if (!best || best == cur)
		return cur;			// nothing better visible -> keep current
	float margin = cvar("bot_target_margin");
	if (margin <= 0 || margin > 1) margin = 0.85;
	float dnew = vlen(best.origin - self.origin);
	float dcur = vlen(cur.origin  - self.origin);
	if (dnew < dcur * margin)		// meaningfully closer -> swap
		return best;
	return cur;				// near-equal -> keep current (no flicker)
};

// ---------------------------------------------------------------------------
// spawn / remove
// ---------------------------------------------------------------------------
void(float team) Bot_Add =
{
	bot_adding = TRUE;			// is_bot is set below, but spawnclient() runs the connect/spawn
	entity bot = spawnclient();		// path NOW (env_fog/weather stuffcmd, env_hud) → flag it so those
	bot_adding = FALSE;			// per-player unicasts skip the not-yet-is_bot bot ("Not a client")
	if (!bot)
	{
		dprint("^1[bot] no free player slot\n");
		return;
	}
	entity saved = self;
	self = bot;

	bot.is_bot = TRUE;
	bot.netname = Bot_PickName(Bot_Count());
	forceinfokey(bot, "name", bot.netname);

	PutClientInServer();			// Prog_Load + PlayerBeginTeamSelection

	if (team != TEAM_BLUE && team != TEAM_RED)
		team = Bot_AutoTeam();
	// NB: leave player_team at TEAM_NONE (PlayerBeginTeamSelection set it) so
	// PlayerJoinTeam runs the full join+PlayerSpawn path, not the same-team
	// model-only fast-path (which would skip the spawn and leave the bot unspawned).
	PlayerJoinTeam(team, floor(random() * 4));	// team model 0..3; sets player_team + spawns

	self = saved;
};

void() Bot_KickOne =
{
	entity e;
	for (e = world; (e = find(e, classname, "player")); )
		if (e.is_bot)
		{
			e.is_bot = FALSE;		// stop counting it NOW — dropclient is async
			dropclient(e);			// engine fires ClientDisconnect (bot save = no-op)
			return;
		}
};

// ---------------------------------------------------------------------------
// motion primitives (set the same input_* globals a usercmd would)
// ---------------------------------------------------------------------------
// Steer toward a world position (relative to the current aim/input_angles).
void(vector target, float speed) Bot_MoveToward =
{
	vector d = target - self.origin; d_z = 0;
	if (vlen(d) < 2)
		return;
	d = normalize(d);
	makevectors(input_angles);
	vector fwd = v_forward; fwd_z = 0; fwd = normalize(fwd);
	vector rgt = v_right;   rgt_z = 0; rgt = normalize(rgt);
	// Weapon-weighted: heavier guns move the bot slower (matches the human
	// sv_maxspeed × weapon_factor clamp); the reduced BOT_RUN keeps the bot BELOW
	// the clamp so it doesn't saturate max speed and look like it's sprinting.
	float factor = WeaponManifest_SpeedFactor(self.weapon);
	if (factor <= 0) factor = 1;
	input_movevalues_x = (d * fwd) * speed * factor;
	input_movevalues_y = (d * rgt) * speed * factor;
	input_movevalues_z = 0;
};

// Move with EXPLICIT forward/side amounts in the AIM's frame (input_angles).  Lets the
// bot strafe / advance / back-pedal in any direction while its aim stays LOCKED on the
// target — it FACES the enemy and moves freely in 360, instead of facing wherever it
// walks (Bot_MoveToward steers toward a world point and faces it; that's for the
// navigator, and it's what made combat side-steps "slightly face away").
void(float fwdamt, float sideamt) Bot_StrafeMove =
{
	float factor = WeaponManifest_SpeedFactor(self.weapon);
	if (factor <= 0) factor = 1;
	input_movevalues_x = fwdamt  * factor;
	input_movevalues_y = sideamt * factor;
	input_movevalues_z = 0;
};

float(float cur, float want, float maxstep) Bot_AngleApproach1 =
{
	float d = want - cur;
	while (d > 180)  d = d - 360;
	while (d < -180) d = d + 360;
	if (d >  maxstep) d =  maxstep;
	if (d < -maxstep) d = -maxstep;
	return cur + d;
};

// Turn toward `want` with BOTH a per-tick speed cap AND proportional easing —
// step = clamp(remaining * ease, ±cap).  Far from target → the cap limits the
// speed (no instant snap); close → the proportional term shrinks the step so the
// aim glides onto the target and settles instead of snapping/overshooting.
float(float cur, float want, float ease, float cap) Bot_AngleEase =
{
	float d = want - cur;
	while (d > 180)  d = d - 360;
	while (d < -180) d = d + 360;
	float step = d * ease;
	if (step >  cap) step =  cap;
	if (step < -cap) step = -cap;
	return cur + step;
};

float() Bot_Skill =
{
	float s = cvar("bot_skill");
	if (s <= 0)   s = 50;
	if (s > 100)  s = 100;
	return s;
};

// Aim (smoothly, with skill-based error) at a world position.
void(vector targetpos) Bot_AimAt =
{
	vector want = vectoangles(targetpos - (self.origin + self.view_ofs));
	want_x = want_x * -1;			// vectoangles pitch -> v_angle pitch (down +)

	// Smooth turn toward the target; higher skill turns faster so it tracks
	// moving targets better.  The turn-rate LAG is the bot's "inaccuracy" — NOT
	// per-frame jitter, which would just spray the thin hitscan into walls.
	float skill = Bot_Skill();

	// Slow, human-like aim error: a per-bot offset re-rolled INFREQUENTLY (every
	// ~1-1.6s, was ~0.5s — the frequent re-roll read as twitchy "ADHD" aim) and
	// scaled smaller (miss less).  The eased turn below converges the aim onto it,
	// so the bot still lands hits; the slower re-roll makes the aim glide, not jitter.
	if (time >= self.bot_aimoff_time)
	{
		self.bot_aimoff_time = time + 1.0 + random() * 0.6;
		float emax = (100 - skill) * 0.032;	// up to ~3.2 deg of miss at skill 0 (was 5)
		self.bot_aimoff_x = (random() - 0.5) * 2 * emax;
		self.bot_aimoff_y = (random() - 0.5) * 2 * emax;
	}
	want_x = want_x + self.bot_aimoff_x;
	want_y = want_y + self.bot_aimoff_y;

	// Capped + eased turn: no instant snap onto a target, and it slows as the aim
	// closes in (scales with skill — higher skill turns a bit faster + tighter).
	float turn_cap = (200 + skill * 2.2) * frametime;	// max degrees this tick
	float ease     = bound(0.04, frametime * (3.5 + skill * 0.06), 0.5);
	self.bot_aim_x = Bot_AngleEase(self.bot_aim_x, want_x, ease, turn_cap);
	self.bot_aim_y = Bot_AngleEase(self.bot_aim_y, want_y, ease, turn_cap);
	self.bot_aim_z = 0;
	self.v_angle  = self.bot_aim;
	input_angles  = self.bot_aim;
};

float() Bot_React = { return (100 - Bot_Skill()) * 0.004 + 0.05; };

// Scoped/sniper weapon? (manifest WMF_FLAG_SCOPE) — those bots stop to shoot.
float(float wep) Bot_IsSniper =
{
	WeaponManifest_Load(wep);
	return (weapon_manifest_flags & WMF_FLAG_SCOPE) != 0;
};

// Aim toward a destination at EYE height (level) so a bot walking a path of
// floor-level nav nodes looks forward instead of staring at the ground.
void(vector pt) Bot_AimWalk =
{
	pt_z = self.origin_z + self.view_ofs_z;
	Bot_AimAt(pt);
};

// ---------------------------------------------------------------------------
// behaviours
// ---------------------------------------------------------------------------
// Follow an A* path toward goalpos (re-paths periodically / when exhausted).
void(vector goalpos) Bot_Navigate =
{
	float slot = num_for_edict(self) - 1;
	if (slot < 0 || slot >= BOT_MAXSLOT)
		return;

	// The `bot_path_len <= 0` clause means "path exhausted -> get another now".  It
	// must NOT fire after a FAILED search, because a failure also leaves
	// bot_path_len at 0: the clause was then true again on the very next frame and
	// the bot re-ran the single most expensive operation it has - two
	// Nav_NearestNode sweeps (each O(nav_count) with a traceline per improvement)
	// plus a full A* that drains the open set - every frame, forever, for a goal it
	// can never reach.  Bot_Roam holds an unreachable goal for 25s and AntiStuck
	// feeds it too, so this was reachable in ordinary play.  bot_repath_fails gates
	// the fast path off and backs the retry interval away.
	float want_repath = (time >= self.bot_repath_time);
	if (!want_repath)
		if (self.bot_path_len <= 0)
			if (self.bot_repath_fails <= 0)
				want_repath = TRUE;

	if (want_repath)
	{
		if (Nav_FindPath(self.origin, goalpos))
		{
			float n = nav_result_len;
			if (n > BOT_PATHLEN) n = BOT_PATHLEN;
			float i;
			for (i = 0; i < n; i = i + 1)
				bot_pathnodes[slot * BOT_PATHLEN + i] = nav_result[i];
			self.bot_path_len = n;
			self.bot_path_cur = 0;
			self.bot_repath_fails = 0;
			// Repath at 1.0s (was 0.6): the periodic full repath re-runs
			// Nav_NearestNode on self.origin, and near a node midpoint the chosen
			// START node can flip frame-to-frame, briefly pointing the path BACKWARD
			// (a pointless ~180).  A longer interval (the path still repaths
			// immediately when EXHAUSTED above) reduces that jitter.  The patrol goal
			// is stable, so this costs nothing.
			self.bot_repath_time = time + 1.0;
		}
		else
		{
			self.bot_path_len = 0;
			self.bot_repath_fails = self.bot_repath_fails + 1;
			float back = 0.5 * self.bot_repath_fails;
			if (back > 5) back = 5;		// unreachable goals settle at one try / 5s
			self.bot_repath_time = time + back;
		}
	}

	if (self.bot_path_len <= 0)
	{	// no graph here -> best-effort straight walk
		Bot_AimWalk(goalpos);
		Bot_MoveToward(goalpos, BOT_RUN);
		return;
	}

	float ci = self.bot_path_cur;
	if (ci >= self.bot_path_len)
	{
		self.bot_path_len = 0;
		Bot_MoveToward(goalpos, BOT_RUN);
		return;
	}
	float node = bot_pathnodes[slot * BOT_PATHLEN + ci];
	vector np = nav_pos[node];
	vector d = np - self.origin; d_z = 0;
	if (vlen(d) < 48)
		self.bot_path_cur = ci + 1;	// reached this waypoint
	Bot_AimWalk(np);			// face where we're walking (level, not down at the node)
	Bot_MoveToward(np, BOT_RUN);
};

void() Bot_Roam =
{
	// Roam the WHOLE map: head to a nav node; on arrival (or a long give-up timer for
	// an unreachable one) pick a NEW destination, sampled to be FAR and roughly AHEAD
	// so the bot keeps crossing the map (varied coverage) WITHOUT the constant ~180s
	// the old every-6s random reselection caused (a fresh node right behind = a U-turn).
	if (nav_count <= 0)
		return;

	// Range-check the goal index in its OWN statement BEFORE dereferencing nav_pos[] —
	// logicops is OFF mod-wide, so a combined `|| nav_pos[i]` would still index OOB
	// and boundcheck-crash if the nav graph rebuilt smaller under a stale goal.
	float need;
	if (self.bot_goal_node < 0 || self.bot_goal_node >= nav_count)
		need = TRUE;				// stale/uninit goal -> reselect (don't index OOB)
	else
	{
		vector gd = nav_pos[self.bot_goal_node] - self.origin; gd_z = 0;
		need = (vlen(gd) < 96 || time >= self.bot_roam_time);
	}
	if (need)
	{
		makevectors(self.v_angle);
		vector fdir = v_forward; fdir_z = 0;
		if (vlen(fdir) > 0.01) fdir = normalize(fdir);
		// Seed best with an IN-RANGE node: the <64u gate below can skip all 6 samples
		// (tiny / dense map), and the trailing Bot_Navigate(nav_pos[best]) must be safe.
		float best = floor(random() * nav_count), bestscore = -1000000;
		float t;
		for (t = 0; t < 6; t = t + 1)
		{
			float cand = floor(random() * nav_count);
			vector cd = nav_pos[cand] - self.origin; cd_z = 0;
			float clen = vlen(cd);
			if (clen < 64)
				continue;		// too close -> skip
			// FAR + forward bias: a node ahead beats one behind at similar range, but
			// a much-farther node behind can still win, so the back of the map gets
			// covered too — just not via a U-turn every few seconds.
			float score = clen + (normalize(cd) * fdir) * 700;
			if (score > bestscore) { bestscore = score; best = cand; }
		}
		self.bot_goal_node = best;
		self.bot_roam_time = time + 25;		// give-up for an unreachable node (NOT a re-randomize tick)
	}
	Bot_Navigate(nav_pos[self.bot_goal_node]);
};

void(float can_fire) Bot_Engage =
{
	vector epos = self.bot_enemy.origin + self.bot_enemy.view_ofs;
	// Lead a moving target slightly — lock onto where they'll BE, not where they are.
	epos = epos + self.bot_enemy.velocity * 0.10;
	Bot_AimAt(epos);

	makevectors(self.v_angle);
	vector toE = normalize(epos - (self.origin + self.view_ofs));
	float ontarget = (toE * v_forward) > 0.99;	// ~8 deg cone
	float reloading = (self.weaponstate == WS_RELOAD);
	float dist = vlen(self.bot_enemy.origin - self.origin);

	// Melee (knife): CHARGE straight at the enemy, but only SWING once actually in
	// range — don't flail from across the room.
	if (self.slot_melee && self.weapon == self.slot_melee)
	{
		if (can_fire && ontarget && dist < BOT_MELEE_RANGE)
		{
			self.bot_fire_held = !self.bot_fire_held;
			if (self.bot_fire_held) { self.button0 = 1; input_buttons = input_buttons | PM_BTN_FIRE; }
		}
		Bot_MoveToward(self.bot_enemy.origin, BOT_RUN);
		return;
	}

	// Reloading -> back away while the gun is down (don't just stand and tank it).
	if (reloading)
	{
		makevectors(input_angles);
		Bot_MoveToward(self.origin - v_forward * 256, BOT_RUN);
		self.bot_fire_time = 0;
		return;
	}

	// CLOSE range -> SPRAY (fire continuously) while strafing hard; no burst pauses,
	// since at close range you can't afford to stop shooting.  FARTHER -> a BURST /
	// SIDESTEP rhythm: fire a short burst holding to aim, then reposition without firing.
	float spray = (dist < BOT_SPRAY_RANGE);
	if (!spray && time >= self.bot_burst_cycle)
	{
		self.bot_burst_end   = time + 0.3  + random() * 0.22;		// burst 0.3-0.52s (50% longer = more rounds/burst)
		self.bot_burst_cycle = self.bot_burst_end + 0.16 + random() * 0.12;	// reposition 0.16-0.28s (short hop)
	}
	float firing = spray || (time < self.bot_burst_end);

	// FIRE (pulsed each think so a SEMI-AUTO pistol/knife re-triggers per shot; autos
	// stay rate-gated by attack_finished).
	if (can_fire && firing && ontarget)
	{
		if (self.bot_fire_time == 0)
			self.bot_fire_time = time + Bot_React();
		if (time >= self.bot_fire_time)
		{
			self.bot_fire_held = !self.bot_fire_held;
			if (self.bot_fire_held)
			{
				self.button0 = 1;
				input_buttons = input_buttons | PM_BTN_FIRE;
			}
		}
	}
	else
		self.bot_fire_time = 0;		// re-acquire reaction when not firing / off target

	// MOVEMENT — ALWAYS strafe relative to the LOCKED aim, near AND far.  Bot_StrafeMove
	// sets input_movevalues directly in the aim's frame, so the bot keeps FACING the
	// enemy and side-steps in 360 — no more "run straight in, then sidestep facing away".
	if (Bot_IsSniper(self.weapon) && dist > 200)
	{
		input_movevalues = '0 0 0';	// snipers plant to land the shot
		return;
	}

	// Hold a strafe side for a short "lock" (~0.4-0.9s) then re-roll — flipping every
	// frame just shuffles in place; a brief commit reads as a real dodge.
	if (time >= self.bot_strafe_time)
	{
		self.bot_strafe = (random() < 0.5) ? -1 : 1;
		self.bot_strafe_time = time + 0.4 + random() * 0.5;
	}

	// STOP while shooting at range; keep moving on CLOSE spray.  The request: moving
	// while spraying point-blank is fine, but at burst range PLANT to land the burst
	// (then strafe-reposition between bursts).
	if (spray)
	{
		// Close: strafe while firing.  Peel back if crowded, else pure strafe.
		float sfwd = (dist < 130) ? -BOT_RUN * 0.55 : 0;
		Bot_StrafeMove(sfwd, self.bot_strafe * BOT_RUN);
	}
	else if (time < self.bot_burst_end)
	{
		input_movevalues = '0 0 0';	// plant to land the burst (avoidance + ledge-jump skip while planted)
	}
	else
	{
		// Between bursts: strafe-approach — close in when far, hold ideal range,
		// peel back when crowded.
		float fwdamt;
		if (dist > 500)       fwdamt =  BOT_RUN * 0.6;	// far: close in WHILE strafing
		else if (dist > 240)  fwdamt =  BOT_RUN * 0.3;	// mid: drift in, mostly strafe
		else if (dist < 130)  fwdamt = -BOT_RUN * 0.55;	// crowded: peel back
		else                  fwdamt =  0;		// ideal range: pure strafe
		Bot_StrafeMove(fwdamt, self.bot_strafe * BOT_RUN);
	}
};

void() Bot_AntiStuck =
{
	if (vlen(self.origin - self.bot_lastpos) > 8 || input_movevalues == '0 0 0')
	{
		self.bot_lastpos = self.origin;
		self.bot_stuck_time = time;
		self.bot_stuck_count = 0;
		return;
	}
	if (time - self.bot_stuck_time > 1.0)	// was 0.5 — halved the stuck-jump rate so a
	{					// genuinely-wedged bot doesn't look like it's bunny-hopping
		self.bot_stuck_count = self.bot_stuck_count + 1;
		if (self.flags & FL_ONGROUND)
		{
			self.button2 = 1;
			input_buttons = input_buttons | PM_BTN_JUMP;
		}
		// Only FORCE a fresh path (which can return a node behind us -> a 180) after
		// we've been wedged for MULTIPLE ticks.  A single jump usually frees a bot,
		// and Bot_ApplyAvoidance now steers around oncoming bots, so don't thrash the
		// path on the first stuck tick — and no strafe flip (that was a 180 source).
		if (self.bot_stuck_count >= 2)
		{
			self.bot_repath_time = 0;	// force a fresh path
			self.bot_stuck_count = 0;
		}
		self.bot_stuck_time = time;
	}
};

// Run-time avoidance: fold a LATERAL sidestep into input_movevalues so bots steer
// around walls and oncoming bots instead of grinding into them — WITHOUT ever
// reversing (no 180).  Composes with the movement the behaviour state already set;
// the post-move velocity cap in Bot_RunFrame bounds the magnitude.  bot_avoid 0 off.
void() Bot_ApplyAvoidance =
{
	if (input_movevalues_x == 0 && input_movevalues_y == 0)
		return;				// not trying to move -> nothing to avoid
	if (cvar("bot_avoid") == 0)
		return;

	makevectors(input_angles);
	vector fwd = v_forward; fwd_z = 0;
	if (vlen(fwd) < 0.01)
		return;
	fwd = normalize(fwd);
	vector rgt = v_right;   rgt_z = 0; rgt = normalize(rgt);

	float steer = 0;			// lateral push: + = right, - = left
	float wedge_yield = 0;			// we're the give-way bot in a nose-to-nose wedge -> ease off forward

	// --- other players roughly AHEAD -> peel around them (head-on bots both pass) ---
	entity e;
	for (e = player_chain_head; e; e = e.player_chain_next)
	{
		if (e == self || e.is_dead ||
		    e.player_team == TEAM_NONE || e.player_team == TEAM_SPEC)
			continue;
		vector d = e.origin - self.origin; d_z = 0;
		float dist = vlen(d);
		if (dist < 1 || dist > BOT_AVOID_RADIUS)
			continue;
		// Exclude the current engage target at NORMAL range (peeling off it would fight
		// the deliberate combat strafe Bot_Engage set), BUT still push apart a WEDGED
		// enemy (<= BOT_WEDGE_DIST) so two bots fighting each other don't grind together.
		if (e == self.bot_enemy && dist > BOT_WEDGE_DIST)
			continue;
		vector dn = normalize(d);
		if ((dn * fwd) < 0.2)
			continue;		// behind / beside us -> not in the way
		float close = (BOT_AVOID_RADIUS - dist) / BOT_AVOID_RADIUS;
		float lat = dn * rgt;		// which side the other guy is on
		if (lat > 0.05)       steer = steer - close;	// they're on our right -> peel LEFT
		else if (lat < -0.05) steer = steer + close;	// on our left -> peel RIGHT
		else                  steer = steer + close;	// dead ahead -> right-hand rule (deterministic pass)

		// Deterministic right-of-way: nose-to-nose AND we're the HIGHER edict -> give way
		// (ease off forward below) so the pair doesn't deadlock in a corridor with no room
		// to sidestep.  The lower edict (incl. a human) keeps going.
		if (dist < BOT_WEDGE_DIST && (dn * fwd) > 0.6 && num_for_edict(self) > num_for_edict(e))
			wedge_yield = 1;
	}

	// --- wall directly ahead -> sidestep to the open side ---
	// Skip this WHILE mid-hop (we just triggered a ledge jump) so we don't veer off the
	// ledge in the air — the player-separation steer above still runs.  Floor raised
	// above step height so stairs/ledges (pmove climbs those) don't read as walls.
	if (time >= self.bot_jump_time)
	{
		vector tmins = self.mins; tmins_z = self.mins_z + BOT_STEP_SKIP;
		vector ahead = self.origin + fwd * BOT_LOOKAHEAD;
		tracebox(self.origin, tmins, self.maxs, ahead, MOVE_NORMAL, self);
		if (trace_fraction < 1)
		{
			float wlat = trace_plane_normal * rgt;		// wall normal points to open space
			float blk  = 1 - trace_fraction;
			if (wlat > 0.05)       steer = steer + blk;	// open to the right
			else if (wlat < -0.05) steer = steer - blk;	// open to the left
			else                   steer = steer + blk;	// dead-on wall -> right
		}
	}

	if (steer != 0)
	{
		steer = bound(-1, steer, 1);
		input_movevalues_y = input_movevalues_y + steer * BOT_RUN;	// pure lateral add (never reverses)
	}

	// Give way: ease our forward drive (keep the lateral steer) so the other bot passes —
	// no reverse, so no "180" look.  Rare true 1-wide deadlocks fall to Bot_AntiStuck.
	if (wedge_yield)
		input_movevalues_x = input_movevalues_x * 0.25;
};

// Proactive auto-jump: when the behaviour wants to move INTO a 20-40u ledge that pmove
// won't auto-step (taller than PM_STEPSIZE 18), hop it.  Called BEFORE avoidance so it
// reads the INTENDED move dir (toward the goal/ledge), not the post-steer direction.
void() Bot_TryJumpLedge =
{
	if (cvar("bot_avoid") == 0)
		return;
	if (!(self.flags & FL_ONGROUND))
		return;				// can only hop off the ground
	if (time < self.bot_jump_time)
		return;				// cooldown — also lets the jump-held latch release
	if (input_movevalues_x == 0 && input_movevalues_y == 0)
		return;				// not trying to move

	// World-space move direction from the aim-frame input.
	makevectors(input_angles);
	vector mv = v_forward * input_movevalues_x + v_right * input_movevalues_y;
	mv_z = 0;
	if (vlen(mv) < 0.01)
		return;
	mv = normalize(mv);
	vector ahead = self.origin + mv * BOT_JUMP_LOOKAHEAD;

	// LOW block trace: floor raised above step height so <=18u steps read as clear
	// (pmove climbs them); only a 20-40u obstacle blocks.
	vector lowmins = self.mins; lowmins_z = self.mins_z + BOT_STEP_SKIP;
	tracebox(self.origin, lowmins, self.maxs, ahead, MOVE_NORMAL, self);
	if (trace_fraction >= 1)
		return;				// nothing blocking ahead -> no ledge to hop

	// LANDING down-trace: drop the full hull onto the ledge TOP, sampled PAST the edge.
	// dtop feet start at feet+48 (above any <=40u ledge -> not startsolid).  landh =
	// trace_endpos_z - origin_z is the surface height above our current feet.
	vector land = self.origin + mv * (BOT_JUMP_LOOKAHEAD + 18);
	vector dtop = land; dtop_z = self.origin_z + BOT_JUMP_CLEAR + 8;
	vector dbot = land; dbot_z = self.origin_z + self.mins_z;
	tracebox(dtop, self.mins, self.maxs, dbot, MOVE_NORMAL, self);
	if (trace_startsolid)
		return;				// wall taller than the probe -> not a hop-able ledge
	if (trace_fraction >= 1)
		return;				// no surface found (railing/pillar with no stand-able top)
	float landh = trace_endpos_z - self.origin_z;
	if (landh < PM_STEPSIZE)
		return;				// pmove auto-steps this -> no hop needed
	if (landh > BOT_JUMP_CLEAR)
		return;				// too tall to reach -> let avoidance steer around it
	if (trace_plane_normal_z < 0.7)
		return;				// not a walkable top

	self.button2 = 1;
	input_buttons = input_buttons | PM_BTN_JUMP;
	self.bot_jump_time = time + 0.6;	// let the hop play out (and the latch release) before re-checking
};

// Per-bot AI tick.  self == the bot.  Sets input_* / button0 / button2 / v_angle.
void() Bot_Think =
{
	input_movevalues = '0 0 0';
	input_buttons = 0;
	self.button0 = 0;
	self.button2 = 0;
	self.impulse = 0;

	// sv_launcher_test owns the bot's weapon outright while it runs, so the AI
	// below has to keep its hands off.  Three separate ways it would otherwise
	// invalidate that harness, all of them silent:
	//   - the dry-mag block sends WEAPON_IMPULSE_RELOAD, which is a MANUAL reload
	//     and would mask a broken auto-reload as a pass;
	//   - a roaming bot walks over a map weapon, which swaps the primary slot and
	//     runs the launcher's drop function (zeroing its mag AND reserve);
	//   - firing at something re-arms attack_finished mid-measurement.
	// Returning here leaves the three zeroed inputs above in place, so the bot
	// stands still with no buttons held; Bot_RunFrame still calls PlayerPreThink
	// and SV_RunClientCommand for it, which is what keeps .wepframe ticking.
	if (cvar("sv_launcher_test"))
		return;

	// Weapon management.  Reload when the mag is dry but reserve remains; if the
	// weapon is FULLY dry (no reserve, can't reload) fall DOWN the slot chain to a
	// usable weapon instead of dry-firing forever: primary → secondary(if loaded) →
	// melee (melee never empties).  Switches via self.impulse (CheckImpulses in
	// PlayerPreThink does the actual select), same path the bot reload uses.
	W_SlotAmmo_GetForWeapon(self, self.weapon);
	float cur_mag = slotammo_mag, cur_ammo = slotammo_ammo;
	if (cur_mag <= 0 && cur_ammo > 0 && self.weaponstate != WS_RELOAD)
	{
		self.impulse = WEAPON_IMPULSE_RELOAD;
	}
	else if (cur_mag <= 0 && cur_ammo <= 0 && self.weaponstate != WS_RELOAD)
	{
		if (self.weapon == self.slot_primary && self.slot_secondary)
		{
			W_SlotAmmo_GetForWeapon(self, self.slot_secondary);
			if (slotammo_mag > 0 || slotammo_ammo > 0)
				self.impulse = WEAPON_IMPULSE_SECONDARY;
			else if (self.slot_melee)
				self.impulse = WEAPON_IMPULSE_MELEE;
		}
		else if (self.slot_melee && self.weapon != self.slot_melee)
		{
			self.impulse = WEAPON_IMPULSE_MELEE;	// secondary/other dry → knife
		}
	}

	// drop a dead / team-swapped target instantly (cheap, every frame)
	if (self.bot_enemy && (self.bot_enemy.is_dead || !IsBotEnemy(self, self.bot_enemy)))
		self.bot_enemy = world;

	// Re-pick the target.  FORCED when we have no / dead / stale enemy.  ALSO on a short
	// interval (BOT_RETARGET_INT) even mid-fight, so the bot switches to a CLOSER visible
	// in-cone enemy — the old code only re-picked every 5s, and the LOS refresh below kept
	// that timer from ever expiring, so the bot locked onto its first target.  Bot_PickEnemy
	// applies bot_target_margin (only swaps if meaningfully closer -> no jitter) and keeps the
	// current target when nothing closer is visible (never drops to world).  Suppress the
	// PERIODIC re-pick briefly after being hit (BOT_HURT_FOCUS) so the snap-to-attacker
	// (W_ApplyDamage) isn't overridden by a closer in-cone enemy before the bot turns to face
	// the shooter.  logicops is OFF, but every operand here is a comparison/field-read (no array).
	float force_repick = (!self.bot_enemy || self.bot_enemy.is_dead || (time - self.bot_enemy_time) > 5);
	float periodic_ok  = (time >= self.bot_retarget_time && (time - self.bot_lasthurt_time) > BOT_HURT_FOCUS);
	if (force_repick || periodic_ok)
	{
		self.bot_enemy = Bot_PickEnemy(self.bot_enemy);
		self.bot_retarget_time = time + BOT_RETARGET_INT;
	}

	float have_los = FALSE;
	if (self.bot_enemy && !self.bot_enemy.is_dead)
	{
		traceline(self.origin + self.view_ofs,
		          self.bot_enemy.origin + self.bot_enemy.view_ofs, MOVE_NOMONSTERS, self);
		if (trace_fraction >= 1 || trace_ent == self.bot_enemy)
		{
			have_los = TRUE;
			self.bot_enemy_time = time;
			self.bot_enemy_lastpos = self.bot_enemy.origin;
		}
	}

	// Track how long LOS to the enemy has been lost so a 1-tick break doesn't yank the
	// bot out of engage (the dominant source of the "flicker between options").
	if (have_los)
		self.bot_los_lost_time = 0;
	else if (self.bot_los_lost_time == 0)
		self.bot_los_lost_time = time;

	float grace = cvar("bot_los_grace");
	if (grace < 0) grace = 0; if (grace > 2) grace = 2;
	// engage-sticky: currently see them, OR lost LOS only momentarily and the target is alive.
	float engage_sticky = self.bot_enemy && !self.bot_enemy.is_dead &&
	                      (have_los || (self.bot_los_lost_time != 0 &&
	                                    (time - self.bot_los_lost_time) < grace));

	if (engage_sticky)
	{
		self.bot_state = 2;		// engage (movement: strafe / close the gap)
		Bot_Engage(have_los);		// FIRING is gated on real LOS so the grace never shoots through walls
	}
	else if (self.bot_enemy && (time - self.bot_enemy_time) < 6)
	{
		self.bot_state = 1;		// hunt last-seen spot
		Bot_Navigate(self.bot_enemy_lastpos);
	}
	else
	{
		self.bot_state = 0;		// roam
		Bot_Roam();
	}

	Bot_TryJumpLedge();		// proactive hop over a small ledge (reads the intended move dir)
	Bot_ApplyAvoidance();		// steer around walls + other bots (lateral, no 180)
	Bot_AntiStuck();
	input_timelength = frametime;
};

// ---------------------------------------------------------------------------
// admin triggers + per-frame driver (called from SV_StartFrame)
// ---------------------------------------------------------------------------
float bot_add_pending;		// queued botadd count, drained one bot per frame
void() Bot_FillTick =
{
	if (cvar("bot_debug") && time >= bot_dbg_filltime)
	{
		bot_dbg_filltime = time + 2;
		dprint(sprintf("^3[bot] fill: want=%g humans=%g bots=%g\n",
			cvar("bot_minplayers"), Bot_HumanCount(), Bot_Count()));
	}

	float add = cvar("botadd");
	if (add != 0)
	{
		cvar_set("botadd", "0");
		bot_add_pending = bot_add_pending + add;
	}
	// Drain the add queue ONE per frame.  Spawning many bots in a single frame
	// causes a same-frame multi-join that re-enters the round-restart precache
	// path and SV_Errors ("PF_precache_sound: Bad string"); gradual joins (like
	// the minplayers fill below) are crash-safe.
	if (bot_add_pending > 0)
	{
		if (Bot_Count() < BOT_MAXSLOT)
			Bot_Add(-1);
		bot_add_pending = bot_add_pending - 1;
	}

	float kick = cvar("botkick");
	if (kick != 0)
	{
		cvar_set("botkick", "0");
		float k;
		for (k = 0; k < kick && Bot_Count() > 0; k = k + 1)
			Bot_KickOne();
	}

	float want = cvar("bot_minplayers");
	if (want > 0)
	{
		if (Bot_HumanCount() + Bot_Count() < want)
			Bot_Add(-1);			// one per frame until filled
		else
		{	// kick ALL excess this frame — Bot_KickOne clears is_bot up-front so the
			// count drops immediately (dropclient itself is async).
			float guard = 0;
			while (Bot_Count() > 0 && Bot_HumanCount() + Bot_Count() > want && guard < BOT_MAXSLOT)
			{
				Bot_KickOne();
				guard = guard + 1;
			}
		}
	}
};

// ---------------------------------------------------------------------------
// Debug overlay (sv_debug_nav 1): nav graph + per-bot state/path, streamed to each
// viewer via a per-client SendEntity proxy (nav_debug_proxy).  Replaces the old
// multicast-from-StartFrame stream, which corrupted the message stream ("Illegible
// server message") because the NQ net-preparse buffer interleaved with the bot
// loop's own per-bot network writes.  MSG_ENTITY writes go into a dedicated CSQC
// buffer in the entity-write phase and never touch the preparser — the same proven
// channel the player_visual_proxy / prediction proxy use.  Zero cost off: no proxy
// spawned -> nothing streamed -> cl_navdebug caches go stale -> nothing drawn.
// ---------------------------------------------------------------------------
const float NAV_DBG_CHUNK   = 16;	// nodes per graph chunk (~720B worst case; FTE fragments) — fills the full graph in a few seconds
const float NAV_DBG_MAXLINK = 16;	// links streamed per node — must cover the client NAVDBG_LINKS cap

// SendEntity serializer for one nav_debug_proxy.  self = the proxy, owner = its
// viewer.  Writes only the sections the engine marked dirty (changedflags).
float(entity to, float changedflags) NavDbg_SendEntity =
{
	float bits = changedflags & (NAVDBG_SF_GRAPH | NAVDBG_SF_BOTS | NAVDBG_SF_PATHS);
	WriteByte(MSG_ENTITY, CSQC_ENT_NAV_DEBUG);
	WriteByte(MSG_ENTITY, bits);

	float i, k, n, c, lc, en, slot, plen, start;
	entity e;
	vector p;

	// GRAPH — one static chunk from the proxy cursor; NavDbg_Tick keeps the bit set
	// until the whole graph is sent, then stops (static graph, no re-stream).
	if (bits & NAVDBG_SF_GRAPH)
	{
		start = self.navdbg_cursor;
		if (start < 0 || start >= nav_count) start = 0;
		n = nav_count - start;
		if (n > NAV_DBG_CHUNK) n = NAV_DBG_CHUNK;
		WriteShort(MSG_ENTITY, nav_count);
		WriteShort(MSG_ENTITY, start);
		WriteByte(MSG_ENTITY, n);
		for (i = start; i < start + n; i = i + 1)
		{
			p = nav_pos[i];
			WriteCoord(MSG_ENTITY, p_x);
			WriteCoord(MSG_ENTITY, p_y);
			WriteCoord(MSG_ENTITY, p_z);
			lc = nav_linkcount[i];
			if (lc > NAV_DBG_MAXLINK) lc = NAV_DBG_MAXLINK;
			WriteByte(MSG_ENTITY, lc);
			for (k = 0; k < lc; k = k + 1)
				WriteShort(MSG_ENTITY, nav_link[i * NAV_LINK_MAX + k]);
		}
		self.navdbg_cursor = start + n;	// advance; Tick re-dirties GRAPH until cursor == nav_count
	}

	// BOTS — per-bot live state.
	if (bits & NAVDBG_SF_BOTS)
	{
		n = 0;
		for (e = world; (e = find(e, classname, "player")); )
			if (e.is_bot) n = n + 1;
		if (n > 32) n = 32;
		WriteByte(MSG_ENTITY, n);
		c = 0;
		for (e = world; (e = find(e, classname, "player")); )
		{
			if (!e.is_bot) continue;
			if (c >= n) break;
			c = c + 1;
			WriteByte(MSG_ENTITY, num_for_edict(e));
			WriteCoord(MSG_ENTITY, e.origin_x);
			WriteCoord(MSG_ENTITY, e.origin_y);
			WriteCoord(MSG_ENTITY, e.origin_z + 44);	// float the label above the head
			WriteByte(MSG_ENTITY, e.bot_state);
			en = 0;
			if (e.bot_enemy) en = num_for_edict(e.bot_enemy);
			WriteByte(MSG_ENTITY, en);
			WriteByte(MSG_ENTITY, e.weapon);
			W_SlotAmmo_GetForWeapon(e, e.weapon);
			WriteByte(MSG_ENTITY, bound(0, slotammo_mag, 255));
		}
	}

	// PATHS — per-bot A* path as node INDICES (client resolves via nav_pos), so the
	// payload stays tiny.  cursor + roam goal ride along.
	if (bits & NAVDBG_SF_PATHS)
	{
		n = 0;
		for (e = world; (e = find(e, classname, "player")); )
			if (e.is_bot && e.bot_path_len > 0) n = n + 1;
		if (n > 32) n = 32;
		WriteByte(MSG_ENTITY, n);
		c = 0;
		for (e = world; (e = find(e, classname, "player")); )
		{
			if (!e.is_bot || e.bot_path_len <= 0) continue;
			if (c >= n) break;
			c = c + 1;
			slot = num_for_edict(e) - 1;
			plen = e.bot_path_len;
			if (plen > BOT_PATHLEN) plen = BOT_PATHLEN;
			WriteByte(MSG_ENTITY, num_for_edict(e));
			WriteByte(MSG_ENTITY, plen);
			WriteByte(MSG_ENTITY, bound(0, e.bot_path_cur, plen));
			WriteShort(MSG_ENTITY, e.bot_goal_node);
			for (i = 0; i < plen; i = i + 1)
				WriteShort(MSG_ENTITY, bot_pathnodes[slot * BOT_PATHLEN + i]);
		}
	}

	return TRUE;
};

// Spawn / refresh one viewer's proxy (prediction-proxy pattern: owner-only +
// repositioned to the viewer each tick so PVS never culls it).
void(entity client) NavDbg_EnsureProxy =
{
	entity proxy = client.nav_debug_proxy;
	if (!proxy)
	{
		proxy = spawn();
		proxy.classname = "nav_debug_proxy";
		proxy.owner = client;
		proxy.movetype = MOVETYPE_NONE;
		proxy.solid = SOLID_NOT;
		proxy.SendEntity = NavDbg_SendEntity;
		proxy.navdbg_cursor = 0;
		proxy.navdbg_build_serial = nav_build_serial;
		client.nav_debug_proxy = proxy;
	}
	proxy.drawonlytoclient = client;
	proxy.pvsflags = PVSF_NOREMOVE;
	setorigin(proxy, client.origin);
	navdbg_proxies_exist = TRUE;   // something to tear down later (see NavDbg_Tick)
};

// Per-frame driver (called from Bot_RunFrame).  sv_debug_nav 0 => tear proxies down.
void() NavDbg_Tick =
{
	entity e;

	if (cvar("sv_debug_nav") < 1)
	{
		// Fast path: nothing was ever spawned, so skip the per-frame find() walk over the
		// whole edict table.  (Same latch pattern as CarDbg_Tick — see the note there.)
		if (!navdbg_proxies_exist)
			return;
		for (e = world; (e = find(e, classname, "player")); )
			if (e.nav_debug_proxy)
			{
				remove(e.nav_debug_proxy);
				e.nav_debug_proxy = world;
			}
		navdbg_proxies_exist = FALSE;
		return;
	}

	for (e = world; (e = find(e, classname, "player")); )
	{
		if (!SV_PlayerHasNetchan(e))
			continue;			// real humans only — bots have no client to draw on
		NavDbg_EnsureProxy(e);
		entity proxy = e.nav_debug_proxy;

		// graph: resend from scratch if the nav graph was (re)built since last sent
		if (proxy.navdbg_build_serial != nav_build_serial)
		{
			proxy.navdbg_cursor = 0;
			proxy.navdbg_build_serial = nav_build_serial;
		}
		// stream the static graph chunk-by-chunk until complete, then stop
		if (nav_state == NAVB_READY && proxy.navdbg_cursor < nav_count)
			proxy.SendFlags = proxy.SendFlags | NAVDBG_SF_GRAPH;

		// per-bot state + path at ~2 Hz
		if (time >= proxy.navdbg_bottime)
		{
			proxy.navdbg_bottime = time + 0.5;
			proxy.SendFlags = proxy.SendFlags | NAVDBG_SF_BOTS | NAVDBG_SF_PATHS;
		}

		setorigin(proxy, e.origin);
	}
};

void() Bot_RunFrame =
{
	Bot_FillTick();

	float dbg_n = 0, dbg_enemy = 0, dbg_fire = 0, dbg_move = 0, dbg_wep = 0;
	entity saved = self;
	entity e = player_chain_head;
	while (e)
	{
		entity nxt = e.player_chain_next;
		if (e.is_bot && e.classname == "player" && e.player_team != TEAM_NONE && !e.is_dead)
		{
			self = e;
			Bot_Think();
			if (self.bot_enemy)                 dbg_enemy = dbg_enemy + 1;
			if (self.button0)                   dbg_fire  = dbg_fire + 1;
			if (input_movevalues != '0 0 0')    dbg_move  = dbg_move + 1;
			dbg_wep = self.weapon;
			dbg_n = dbg_n + 1;
			PlayerPreThink();		// weapon fire, jump, grapple ticks
			SV_RunClientCommand();		// PM_PlayerMove
			// Stabilise bot speed: air-strafe / bhop can push a bot ABOVE its intended
			// wishspeed (the "~300 u/s, unstable" feel).  Hard-cap the HORIZONTAL
			// velocity to BOT_RUN × weapon_factor so bots run at a steady, sub-human
			// speed regardless of jumps/strafes.  Vertical (jump/gravity) untouched.
			float bot_maxh = BOT_RUN * WeaponManifest_SpeedFactor(self.weapon);
			if (bot_maxh <= 0) bot_maxh = BOT_RUN;
			vector bot_hv = self.velocity; bot_hv_z = 0;
			float bot_hs = vlen(bot_hv);
			if (bot_hs > bot_maxh)
			{
				bot_hv = bot_hv * (bot_maxh / bot_hs);
				self.velocity_x = bot_hv_x;
				self.velocity_y = bot_hv_y;
			}
			PlayerPostThink();		// fall damage, anim, visual proxy
		}
		e = nxt;
	}
	self = saved;

	NavDbg_Tick();		// bot/nav debug overlay via per-client SendEntity (sv_debug_nav 1)

	if (cvar("bot_debug") && time >= bot_dbg_acttime)
	{
		bot_dbg_acttime = time + 1.5;
		dprint(sprintf("^3[bot] active=%g enemy=%g firing=%g moving=%g lastwep=%g\n",
			dbg_n, dbg_enemy, dbg_fire, dbg_move, dbg_wep));
	}
};
