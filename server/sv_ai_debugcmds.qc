// server/sv_ai_debugcmds.qc
// ----------------------------------------------------------------------------
// The NPC test bench: `cmd ai_*` handlers, driven from binds in cfg/aidebug.cfg.
//
// Everything here exists because the headless harness cannot answer the
// questions that actually matter now - does it LOOK right, does it FEEL right -
// and doing that by hand through cvars means editing a config, restarting a map
// and hoping the spawn lands somewhere useful.  These put a monster in front of
// you, on demand, and tell you what it is thinking.
//
// GATED BEHIND sv_cheats.  Spawning a gargantua on a live server is not a thing
// a player gets to do, and the gate is checked per command rather than once at
// registration so flipping the cvar takes effect immediately.
//
// The spawn commands deliberately place monsters where you are LOOKING, not on a
// nav node: the whole point is to put the thing in front of your face and watch
// it, and a nav-node spawn is what the automated test wants, not a human.
// ----------------------------------------------------------------------------

float(entity p) AIDbg_Allowed =
{
	if (cvar("sv_cheats"))
		return TRUE;
	sprint(p, PRINT_HIGH, "ai debug commands need sv_cheats 1\n");
	return FALSE;
};

// Where the player is looking, dropped to the floor.  Traces from the eye so a
// monster lands on the surface under the crosshair rather than inside it.
vector(entity p, float maxdist) AIDbg_AimSpot =
{
	makevectors(p.v_angle);
	vector eye = p.origin + p.view_ofs;

	traceline(eye, eye + v_forward * maxdist, MOVE_NORMAL, p);
	vector hit = trace_endpos;

	// Back off the surface so the hull is not spawned inside it, then find the
	// floor beneath.  Both traces ignore the player, or standing close to a wall
	// would put the monster behind it.
	hit = hit - v_forward * 48;
	traceline(hit, hit - '0 0 512', MOVE_NORMAL, p);
	if (trace_fraction < 1)
		return trace_endpos + '0 0 8';
	return hit;
};

// `cmd ai_spawn <class> [count]`
void(entity p, string cls, float n) AIDbg_Spawn =
{
	if (cls == "" || !cls)
	{
		sprint(p, PRINT_HIGH, "usage: ai_spawn <monster_classname> [count]\n");
		return;
	}
	if (!AI_ClassHasAI(cls))
	{
		sprint(p, PRINT_HIGH, sprintf("\"%s\" has no AI - it would spawn as scenery. Try ai_list.\n", cls));
		return;
	}
	if (n < 1) n = 1;
	if (n > 16) n = 16;		// a hard cap: this is a test tool, not a spawner

	vector base = AIDbg_AimSpot(p, 1024);
	float i, made = 0;

	for (i = 0; i < n; i = i + 1)
	{
		// Fan them out so they do not spawn inside each other.
		makevectors('0 1 0' * (i * 47));
		vector org = base + v_forward * (i ? 48 + i * 8 : 0);

		entity oldself = self;
		entity m = spawn();
		m.classname = cls;
		setorigin(m, org);
		self = m;
		Monster_Build(TRUE);
		self = oldself;

		if (m.flags & FL_MONSTER)
			made = made + 1;
	}

	sprint(p, PRINT_HIGH, sprintf("spawned %g/%g %s at %v\n", made, n, cls, base));
};

// `cmd ai_clear` — remove every AI monster.  Uses the monster chain rather than
// a find() sweep, and walks it defensively because remove() unlinks as it goes.
void(entity p) AIDbg_Clear =
{
	entity e = monster_chain_head;
	float n = 0;
	while (e)
	{
		entity nxt = e.monster_chain_next;
		if (e.flags & FL_MONSTER)
		{
			// Teardown FIRST.  Walking with a stashed `nxt` keeps this loop safe,
			// but it does nothing for the removed entity's NEIGHBOURS, which keep
			// pointing at a freed edict - monster_chain_remove is what repairs the
			// links, and it lives inside Monster_Teardown along with the squad slot
			// and path slot releases.
			Monster_Teardown(e);
			remove(e);
			n = n + 1;
		}
		e = nxt;
	}
	sprint(p, PRINT_HIGH, sprintf("removed %g monsters\n", n));
};

// `cmd ai_status` — what every monster near you is thinking, right now.
//
// This is the single most useful thing in the file.  Every bug found in this
// programme so far showed up as the WRONG SCHEDULE rather than as a wrong task,
// and until now reading that meant grepping a headless log afterwards.
void(entity p) AIDbg_Status =
{
	entity e = monster_chain_head;
	float n = 0;

	sprint(p, PRINT_HIGH, "^3--- AI status (nearest first is not sorted; radius 1024) ---\n");
	while (e && n < 24)
	{
		if ((e.flags & FL_MONSTER) && vlen(e.origin - p.origin) < 1024)
		{
			string en = "-";
			if (e.ai_enemy)
				en = (e.ai_enemy.classname == "player") ? e.ai_enemy.netname : e.ai_enemy.classname;

			sprint(p, PRINT_HIGH, sprintf("%-22s hp=%-4g st=%g sch=%-14s cond=%i enemy=%s d=%g\n",
			                  e.classname, e.health, e.ai_state, Sched_Name(e.ai_sched),
			                  e.ai_cond, en, rint(vlen(e.origin - p.origin))));
			n = n + 1;
		}
		e = e.monster_chain_next;
	}
	if (!n)
		sprint(p, PRINT_HIGH, "(nothing within 1024 units)\n");
};

// `cmd ai_freeze` — stop/start every monster thinking, without removing them.
// Useful for lining up a screenshot or walking around something mid-animation.
float aidbg_frozen;

void(entity p) AIDbg_Freeze =
{
	aidbg_frozen = !aidbg_frozen;

	entity e = monster_chain_head;
	while (e)
	{
		if (e.flags & FL_MONSTER)
		{
			if (aidbg_frozen)
				e.nextthink = time + 86400;	// far future, restored below
			else
				e.nextthink = time + 0.05 + random() * 0.1;
		}
		e = e.monster_chain_next;
	}
	sprint(p, PRINT_HIGH, aidbg_frozen ? "monsters FROZEN\n" : "monsters running\n");
};

// `cmd ai_hurt [amount]` — damage whatever you are looking at.  Faster than
// shooting when what you want to test is the flinch/death path specifically.
void(entity p, float amt) AIDbg_Hurt =
{
	if (amt <= 0)
		amt = 25;

	makevectors(p.v_angle);
	vector eye = p.origin + p.view_ofs;
	traceline(eye, eye + v_forward * 2048, MOVE_NORMAL, p);

	if (trace_ent && (trace_ent.flags & FL_MONSTER))
	{
		W_ApplyDamage(p, trace_ent, amt);
		sprint(p, PRINT_HIGH, sprintf("hurt %s for %g (hp now %g)\n",
		                  trace_ent.classname, amt, trace_ent.health));
	}
	else
		sprint(p, PRINT_HIGH, "not looking at a monster\n");
};

// `cmd ai_follow` — toggle the escort on whatever ally you are looking at.
//
// This is the SAME code path +use runs, deliberately: a debug command that calls
// something else would verify a behaviour nobody can reach in play.  It exists
// because +use has to compete with doors, buttons and pickups for the trace, and
// when an ally will not follow you want to know whether the behaviour is broken
// or the press simply landed on a wall.
void(entity p) AIDbg_Follow =
{
	makevectors(p.v_angle);
	vector eye = p.origin + p.view_ofs;
	traceline(eye, eye + v_forward * 2048, MOVE_NORMAL, p);

	if (!trace_ent || !(trace_ent.flags & FL_MONSTER))
	{
		sprint(p, PRINT_HIGH, "not looking at a monster\n");
		return;
	}
	if (!trace_ent.is_player_ally)
	{
		sprint(p, PRINT_HIGH, sprintf("%s is not an ally - it will never follow you\n",
		                              trace_ent.classname));
		return;
	}
	AI_ToggleFollow(trace_ent, p);
};

// `cmd ai_list` — every class the AI registry actually knows.  Kept as a literal
// list rather than derived, because AI_ClassHasAI is a chain of string compares
// with nothing to enumerate; the self-test's model inventory is what catches the
// two drifting apart.
void(entity p) AIDbg_List =
{
	sprint(p, PRINT_HIGH, "^3AI classes:\n");
	sprint(p, PRINT_HIGH, "headcrab zombie zombie_barney zombie_soldier cockroach\n");
	sprint(p, PRINT_HIGH, "alien_slave houndeye alien_grunt bullchicken pitdrone gonome alien_voltigore\n");
	sprint(p, PRINT_HIGH, "human_grunt human_grunt_ally male_assassin human_assassin hwgrunt robogrunt\n");
	sprint(p, PRINT_HIGH, "shocktrooper bodyguard th_grunt_repel barney otis human_medic_ally\n");
	sprint(p, PRINT_HIGH, "human_torch_ally scientist\n");
	sprint(p, PRINT_HIGH, "sentry miniturret turret barnacle leech ichthyosaur alien_controller\n");
	sprint(p, PRINT_HIGH, "gargantua babygarg stukabat kingpin\n");
	sprint(p, PRINT_HIGH, "(prefix each with monster_)\n");
};

// Dispatcher.  Called from SV_ParseClientCommand; returns TRUE if it consumed
// the command.
float(entity p, string cmd) AIDbg_Command =
{
	if (cmd == "ai_spawn")
	{
		if (AIDbg_Allowed(p))
			AIDbg_Spawn(p, argv(1), stof(argv(2)));
		return TRUE;
	}
	if (cmd == "ai_clear")
	{
		if (AIDbg_Allowed(p)) AIDbg_Clear(p);
		return TRUE;
	}
	if (cmd == "ai_status")
	{
		AIDbg_Status(p);		// read-only: no cheat gate
		return TRUE;
	}
	if (cmd == "ai_freeze")
	{
		if (AIDbg_Allowed(p)) AIDbg_Freeze(p);
		return TRUE;
	}
	if (cmd == "ai_hurt")
	{
		if (AIDbg_Allowed(p)) AIDbg_Hurt(p, stof(argv(1)));
		return TRUE;
	}
	if (cmd == "ai_follow")
	{
		if (AIDbg_Allowed(p)) AIDbg_Follow(p);
		return TRUE;
	}
	if (cmd == "ai_list")
	{
		AIDbg_List(p);
		return TRUE;
	}
	return FALSE;
};
