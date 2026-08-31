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
// The optional third argument is the map's `weapons` key, which is the only way
// to reach a loadout from in front of the monster instead of from a map that
// happens to place one.  The grunt family reads it for the gun, the bodygroup,
// the cadence and the range (sven-coop.fgd:5508 for the bit table), and two of
// those bits - 64 Rocket Launcher and 128 Sniper Rifle - existed on exactly two
// squadmakers in the whole corpus, on a map where they spawn behind a flag
// capture.  Testing them meant playing to them.
void(entity p, string cls, float n, float loadout) AIDbg_Spawn =
{
	if (cls == "" || !cls)
	{
		sprint(p, PRINT_HIGH, "usage: ai_spawn <monster_classname> [count] [weapons]\n");
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
		// BEFORE Monster_Build, because AI_ClassInit runs inside it and every
		// reader of .weapons - Grunt_RigOverride, Grunt_LoadoutInit,
		// Grunt_BodyInit - is downstream of that call.
		if (loadout > 0)
			m.weapons = loadout;
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

// `cmd ai_hurt [amount] [hitgroup]` — damage whatever you are looking at.  Faster
// than shooting when what you want to test is the flinch/death path specifically.
//
// The hitgroup argument exists because that path is now driven by one
// (HITGROUP_* 0..7, default 0 = generic): a bullet resolves its own through
// W_HitgroupClassify, but hitting a specific limb on purpose with a real weapon
// is fiddly, and a headshot flinch you cannot reproduce is a headshot flinch you
// cannot debug.  The line printed back names the sequence the monster CHOSE, not
// the one asked for, which is the whole difference worth seeing - a rig that
// carries no such animation reports the fallback it took instead.
// The pick happens on the monster's next decision tick, inside TASK_PLAY_DEATH /
// TASK_PLAY_FLINCH, so it cannot be read back at the moment damage is applied.
// One deferred think is cheaper than threading a pending-report list through the
// per-frame path, and it self-destructs.
void() AIDbg_HurtReport =
{
	entity t = self.owner;
	entity p = self.enemy;
	if (t && p)
		sprint(p, PRINT_HIGH, sprintf("  -> %s chose %s\n",
		                  t.classname, AI_HitActName(t.ai_dbg_hitact)));
	remove(self);
};

void(entity p, float amt, float hg) AIDbg_Hurt =
{
	if (amt <= 0)
		amt = 25;
	if (hg < HITGROUP_GENERIC || hg > HITGROUP_RIGHTLEG)
		hg = HITGROUP_GENERIC;

	makevectors(p.v_angle);
	vector eye = p.origin + p.view_ofs;
	traceline(eye, eye + v_forward * 2048, MOVE_NORMAL, p);

	if (trace_ent && (trace_ent.flags & FL_MONSTER))
	{
		entity t = trace_ent;
		t.ai_dbg_hitact  = 0;
		t.death_hitgroup = hg;
		W_ApplyDamage(p, t, amt);
		sprint(p, PRINT_HIGH, sprintf("hurt %s for %g at hitgroup %g (hp now %g)\n",
		                  t.classname, amt, hg, t.health));

		entity r = spawn();
		r.owner     = t;
		r.enemy     = p;
		r.think     = AIDbg_HurtReport;
		r.nextthink = time + 0.3;	// two decision ticks of slack
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

// ---------------------------------------------------------------------------
// ent_fire <targetname> [usetype] — fire a map entity by name, the way a
// trigger would.
//
// Added because there was no way to exercise a map's trigger graph without
// physically walking a player into the trigger_once that starts it, which makes
// half the entity logic in this port untestable headlessly.  th_ep1_00's whole
// opening hangs off one gated trigger_once; hl_c05_a1's train ride hangs off a
// +use on the carriage.
//
// `usetype` is the raw USE_* value (0 Off / 1 On / 2 Set / 3 Toggle), defaulting
// to USE_UNSET so the entity takes its own default path — the same thing a
// player's +use now supplies.  It is passed straight through rather than
// converted from a mapper `triggerstate`, because the point of the command is to
// test the dispatch layer itself.
void(entity p, string name, string usetype_str) AIDbg_EntFire =
{
    if (name == "")
    {
        sprint(p, PRINT_HIGH, "usage: ent_fire <targetname> [usetype 0=off 1=on 2=set 3=toggle]\n");
        return;
    }

    float ut = (usetype_str == "") ? USE_UNSET : stof(usetype_str);
    float n  = 0;

    entity e = find(world, targetname, name);
    while (e)
    {
        entity nxt = find(e, targetname, name);
        if (e.use)
        {
            entity oldself = self, oldact = activator;
            self         = e;
            activator    = p;
            sub_use_type = ut;
            e.use();
            self         = oldself;
            activator    = oldact;
            n = n + 1;
        }
        else
        {
            sprint(p, PRINT_HIGH, sprintf("  %s \"%s\" has no .use — skipped\n",
                                          e.classname, e.targetname));
        }
        e = nxt;
    }
    sub_use_type = USE_UNSET;

    sprint(p, PRINT_HIGH, sprintf("ent_fire \"%s\" usetype=%g -> %g entit%s\n",
                                  name, ut, n, (n == 1) ? "y" : "ies"));
};

// ---------------------------------------------------------------------------
// Headless counterpart of ent_fire.  `ent_fire` is a CLIENT command, and the
// headless harness (/c/tmp/hlclient.sh) has no way to type one into a connected
// client mid-run — it can only pass cvars on the server command line.  Without
// this, any map whose logic begins at a trigger_once the player must walk into
// is untestable without a human.
//
//   +set sv_debug_firetarget roadratmngr
//   +set sv_debug_firedelay 6          (seconds after the first player spawns)
//   +set sv_debug_fireusetype 3        (USE_*; -1 / absent = USE_UNSET)
//   +set sv_debug_fire_noplayer 1      (fire from map load; no player needed)
//
// Fires exactly once.  Gated on sv_first_player_spawned by default, for the same
// reason the tracktrain autostart is: entity chains that move the world before
// anyone is in it are impossible to OBSERVE from a client.
//
// sv_debug_fire_noplayer lifts that gate, and it is not a workaround — it is
// what makes pure server-side logic (a func_global store, a trigger_save, a
// multi_manager schedule) testable on a dedicated server alone.  The headless
// CLIENT needs ~2 minutes to reach a spawn on a 1400-entity Sven map, which is
// far longer than the logic under test takes to run.
// ---------------------------------------------------------------------------
void() AIDbg_FireTargetThink =
{
    if (!sv_first_player_spawned && !cvar("sv_debug_fire_noplayer"))
    {
        self.nextthink = time + 0.25;
        return;
    }

    if (!self.count)
    {
        // First tick after the player is live: arm the delay.
        self.count     = 1;
        self.nextthink = time + max(0, cvar("sv_debug_firedelay"));
        return;
    }

    string name = cvar_string("sv_debug_firetarget");
    float  ut   = cvar("sv_debug_fireusetype");
    if (ut == 0 && cvar_string("sv_debug_fireusetype") == "") ut = USE_UNSET;
    if (ut < 0) ut = USE_UNSET;

    // Fire AS a player when there is one.  A large share of the entities worth
    // poking this way read `activator` and do nothing useful without it —
    // trigger_suitcheck asks whether the activator has the HEV suit,
    // game_player_equip equips the activator, trigger_changevalue's "!activator"
    // form has no destination at all — so firing from `world` made exactly the
    // entities this harness exists for untestable.  Falls back to world when the
    // gate was lifted with sv_debug_fire_noplayer and no one has joined.
    entity who = find(world, classname, "player");
    if (!who) who = world;

    // Shared with the reserved-name emitters (sv_triggers.qc).  Deliberately the
    // SAME function, so proving a chain by hand with sv_debug_firetarget and
    // watching the shipped code fire it are the same code path — which is what
    // made the hl_c00 game_playerspawn diagnosis conclusive rather than a guess.
    float n = SV_FireTargetsByName(name, who, ut);
    sub_use_type = USE_UNSET;

    // REPEATS, because some entities only mean anything when pulsed.  Sven's own
    // documentation for momentary_rot_button says so outright - "you can remote
    // control it by triggering it in 0.1 s intervals" - and one fire moves such a
    // wheel by about a degree, which is indistinguishable from nothing.  Default
    // 1 repeat, so every existing invocation behaves exactly as before.
    self.frags = self.frags + 1;
    float reps = cvar("sv_debug_firerepeat");
    if (reps < 1) reps = 1;
    if (self.frags < reps)
    {
        float iv = cvar("sv_debug_fireinterval");
        if (iv <= 0) iv = 0.1;
        self.nextthink = time + iv;
        if (self.frags == 1)
            print(sprintf("[dbgfire] fired \"%s\" usetype=%g -> %g entities at t=%g (x%g)\n",
                          name, ut, n, time, reps));
        return;
    }

    print(sprintf("[dbgfire] fired \"%s\" usetype=%g -> %g entities, %g pulses, done t=%g\n",
                  name, ut, n, self.frags, time));
    remove(self);
};

void() AIDbg_FireTargetInit =
{
    print(sprintf("[dbgfire] init: target=\"%s\" delay=%g usetype=%g\n",
                  cvar_string("sv_debug_firetarget"),
                  cvar("sv_debug_firedelay"), cvar("sv_debug_fireusetype")));
    if (cvar_string("sv_debug_firetarget") == "") return;
    entity e = spawn();
    e.classname = "dbg_firetarget";
    e.think     = AIDbg_FireTargetThink;
    e.nextthink = time + 0.5;
};

// ---------------------------------------------------------------------------
// ai_hitgroups — fire real bullets at every live monster's bones and report
// which hitgroup each one actually resolves to.
//
// WHY A PROBE AND NOT A READ OF THE MODEL.  A monster's hitgroup comes out of
// the engine's per-bone hitbox trace, and a .mdl can hold several boxes on ONE
// bone with DIFFERENT groups - barney's head is three boxes, one tagged 1 and
// two tagged 10 - so "the model has a head hitgroup" and "shooting him in the
// head is a headshot" are separate questions.  Only a trace answers the second,
// because only a trace picks the box the way a bullet does.  Reading the file
// says what exists; this says what happens.
//
// Eight compass rays per bone at 48 units, each aimed at the bone's own origin
// from outside the model, through W_WeaponTraceLine + W_HitgroupClassify - the
// exact pair every hitscan weapon uses (sh_weapon_standard.qc:1037).  The count
// that comes back IS the answer to "what fraction of shots at his head are
// headshots": 8/8 is a clean rig, 2/8 is barney before this was fixed.
//
// Rays that hit nothing, or hit something else on the way in, are reported as
// `miss` rather than folded into the total - a monster standing against a wall
// legitimately cannot be shot from behind, and silently counting that as a
// failed headshot would make a clean rig look broken.
string(float hg) AIDbg_HgName =
{
	if (hg == HITGROUP_HEAD)     return "HEAD";
	if (hg == HITGROUP_CHEST)    return "chest";
	if (hg == HITGROUP_STOMACH)  return "stomach";
	if (hg == HITGROUP_LEFTARM)  return "Larm";
	if (hg == HITGROUP_RIGHTARM) return "Rarm";
	if (hg == HITGROUP_LEFTLEG)  return "Lleg";
	if (hg == HITGROUP_RIGHTLEG) return "Rleg";
	return "GENERIC";
};

// One bone, eight rays.  Returns the number that resolved to `want`; the caller
// prints.  `hit` and `miss` come back through globals because QC has no way to
// return three numbers and a struct type here would be worse than two globals
// that live for the length of one print.
float aidbg_hg_hits, aidbg_hg_miss, aidbg_hg_other, aidbg_hg_lastother;

// `rise` lifts the aim point in WORLD Z above the bone's own origin, and it is
// not a fudge factor - it is the difference between the bone and the thing the
// player shoots at.  Bip01 Head sits at the BASE OF THE NECK; the skull is
// above it.  Aiming at the bone origin itself lands in the neck, where on a
// broad rig (hgrunt's Spine2 box is 6628 cubic units against barney's 1626) the
// chest box legitimately still reaches - so the first version of this probe
// reported "no headshot" on every grunt and it was the probe that was wrong.
// Sampling several rises and printing all of them says where the head actually
// begins instead of asserting one number.
float(entity m, string bone, float want, float rise) AIDbg_HgBone =
{
	aidbg_hg_hits = 0;
	aidbg_hg_miss = 0;
	aidbg_hg_other = 0;
	aidbg_hg_lastother = HITGROUP_GENERIC;

	float ti = gettagindex(m, bone);
	if (ti <= 0)
		return -1;			// rig does not carry this bone at all

	vector org = gettaginfo(m, ti);
	org_z = org_z + rise;
	float i;
	for (i = 0; i < 8; i = i + 1)
	{
		// Ring of eight around the bone, level with it.  Level rather than
		// spherical because a bullet arrives roughly horizontally, and a ray
		// coming steeply down onto a skull strikes a different box than any
		// shot a player can actually take.
		float a = i * (M_PI * 2 / 8);
		vector src;
		src_x = org_x + cos(a) * 48;
		src_y = org_y + sin(a) * 48;
		src_z = org_z;

		W_WeaponTraceLine(src, org);
		if (trace_ent != m)
		{
			aidbg_hg_miss = aidbg_hg_miss + 1;
			continue;
		}

		float hg = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
		if (hg == want)
			aidbg_hg_hits = aidbg_hg_hits + 1;
		else
		{
			aidbg_hg_other = aidbg_hg_other + 1;
			aidbg_hg_lastother = hg;
		}
	}
	return aidbg_hg_hits;
};

void(entity p) AIDbg_Hitgroups =
{
	sprint(p, PRINT_HIGH, "^3[hitgroups] 8 rays per bone; hit/other/miss\n");

	float n = 0;

	// monster_chain_head is the mod's own linked list of live AI, so the probe
	// reports exactly what this map spawned, in spawn order, with no class
	// table to keep in step with the roster.
	entity m = monster_chain_head;
	while (m)
	{
		// Skip the dead: a corpse's skeleton is frozen on whatever frame it
		// died on and its boxes moved with it, so the numbers would describe a
		// pose nobody can shoot at.
		if (m.health > 0)
		{
			float r0 = AIDbg_HgBone(m, "Bip01 Head", HITGROUP_HEAD, 0);
			float h0 = aidbg_hg_hits;
			string o0 = AIDbg_HgName(aidbg_hg_lastother);

			AIDbg_HgBone(m, "Bip01 Head", HITGROUP_HEAD, 4);
			float h4 = aidbg_hg_hits;

			AIDbg_HgBone(m, "Bip01 Head", HITGROUP_HEAD, 8);
			float h8 = aidbg_hg_hits;
			float hm = aidbg_hg_miss;

			AIDbg_HgBone(m, "Bip01 Spine1", HITGROUP_CHEST, 0);
			float ch = aidbg_hg_hits;
			float co = aidbg_hg_other;

			// Built in pieces: sprintf takes at most 8 varargs, and one line
			// carrying all of this wanted eleven.  Same reason mon_grunt.qc's
			// bodygroup probe prints two lines instead of one.
			string hs = sprintf("head +0/+4/+8 %g/%g/%g of 8", h0, h4, h8);
			string cs = sprintf("chest %g/%g miss %g", ch, co, hm);
			float best = (h8 > h4) ? h8 : h4;
			if (h0 > best) best = h0;

			if (r0 < 0)
				sprint(p, PRINT_HIGH, sprintf("  %-24s %-26s no Bip01 rig\n",
				                              m.classname, m.model));
			else
				sprint(p, PRINT_HIGH,
				       sprintf("  %-24s %-26s %-20s %s\n",
				               m.classname, hs, cs,
				               (best > 0) ? strcat("(near-bone ", o0, ")")
				                          : "^1NO HEADSHOT ANYWHERE^7"));
			n = n + 1;
		}
		m = m.monster_chain_next;
	}

	sprint(p, PRINT_HIGH, sprintf("^3[hitgroups] %g live monster(s) probed\n", n));
};

// Dispatcher.  Called from SV_ParseClientCommand; returns TRUE if it consumed
// the command.
float(entity p, string cmd) AIDbg_Command =
{
    if (cmd == "ai_hitgroups")
    {
        AIDbg_Hitgroups(p);		// read-only: no cheat gate
        return TRUE;
    }
    if (cmd == "ent_fire")
    {
        if (AIDbg_Allowed(p)) AIDbg_EntFire(p, argv(1), argv(2));
        return TRUE;
    }
	if (cmd == "ai_spawn")
	{
		if (AIDbg_Allowed(p))
			AIDbg_Spawn(p, argv(1), stof(argv(2)), stof(argv(3)));
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
		if (AIDbg_Allowed(p)) AIDbg_Hurt(p, stof(argv(1)), stof(argv(2)));
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
