// server/sv_ai_gibs.qc
// ----------------------------------------------------------------------------
// Tearing a body apart.  Ported from dlls/combat.cpp:
//   CBaseMonster::GibMonster      :303-342
//   CBaseMonster::ShouldGibMonster:535-541
//   CBaseMonster::HasHumanGibs    :256-270
//   CBaseMonster::HasAlienGibs    :272-285
//   CGib::SpawnRandomGibs velocity:235-246
//
// Compiles AFTER the AI layer on purpose: picking which gib set a body throws
// needs its CLASS_* classification, and .ai_class lives in sv_ai_defs.qc.  The
// damage path reaches this through a forward declaration in sv_weapons.qc.
//
// THE MODEL SET IS CHOSEN BY CLASSIFY, NOT PER MONSTER.  combat.cpp:256-285 is
// two class lists, not a virtual: everything human-shaped throws hgibs.mdl and
// everything alien throws agibs.mdl, so a zombie (CLASS_ALIEN_MONSTER) throws
// alien gibs even though it is wearing a scientist.  That is Half-Life's
// answer and it is deliberate - the zombie is not a person any more.
// ----------------------------------------------------------------------------

const float GIBSET_HUMAN = 0;
const float GIBSET_ALIEN = 1;

// combat.cpp:679, GIB_HEALTH_VALUE.  A killing blow that drives health below
// this gibs the body outright rather than leaving a corpse.
const float GIB_HEALTH_VALUE = -30;

// combat.cpp:256-285.  Anything not in either list gets no gibs at all, which is
// how the machines (turrets, apache, osprey) and the gman avoid exploding into
// meat.
float(entity m) Gib_SetFor =
{
    float c = m.ai_class;

    if (c == CLASS_HUMAN_MILITARY || c == CLASS_PLAYER_ALLY
     || c == CLASS_HUMAN_PASSIVE  || c == CLASS_PLAYER)
        return GIBSET_HUMAN;

    if (c == CLASS_ALIEN_MILITARY || c == CLASS_ALIEN_MONSTER
     || c == CLASS_ALIEN_PASSIVE  || c == CLASS_INSECT
     || c == CLASS_ALIEN_PREDATOR || c == CLASS_ALIEN_PREY)
        return GIBSET_ALIEN;

    return -1;		// no gib set: fades or simply vanishes
};

// A robot, a helicopter or the gman must not spray meat.  The AI classes already
// carry .bloodcolor (-1 == DONT_BLEED, set by Robogrunt_ClassInit and friends),
// and that is exactly the same question, so it is the same test.
float(entity m) Gib_CanGib =
{
    if (m.bloodcolor < 0)
        return FALSE;
    return Gib_SetFor(m) >= 0;
};

void(entity body, entity attacker) Monster_Gib =
{
    if (!Gib_CanGib(body))
    {
        // combat.cpp:329-341 - a monster with no gib set does not explode, it
        // just goes away.  Removing it here is what stops a shot robot leaving
        // an indestructible pancake on the floor forever.
        remove(body);
        return;
    }

    // combat.cpp:235-246.  The launch speed is scaled by how far past death the
    // body was driven, in three bands.  This is why a satchel scatters a corpse
    // across the room and a crowbar just breaks it apart at your feet.
    float scale;
    if (body.health > -50)       scale = 0.7;
    else if (body.health > -200) scale = 2;
    else                         scale = 4;

    // combat.cpp:315-324 - four random gibs plus a head for humans, four for
    // aliens.  The head is submodel 0 of hgibs.mdl (combat.cpp:202 reserves it),
    // which is why the human count is one higher.
    float gset  = Gib_SetFor(body);
    float count = (gset == GIBSET_HUMAN) ? 5 : 4;

    vector org = body.origin + (body.mins + body.maxs) * 0.5;
    vector dir = normalize(body.origin - attacker.origin);
    if (dir == '0 0 0')
        dir = '0 0 1';

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_MONSTER_GIBS);
    WriteCoord(MSG_MULTICAST, org_x);
    WriteCoord(MSG_MULTICAST, org_y);
    WriteCoord(MSG_MULTICAST, org_z);
    WriteCoord(MSG_MULTICAST, dir_x);
    WriteCoord(MSG_MULTICAST, dir_y);
    WriteCoord(MSG_MULTICAST, dir_z);
    WriteByte(MSG_MULTICAST, count);
    WriteShort(MSG_MULTICAST, bound(0, 60 * scale, 32767));
    WriteByte(MSG_MULTICAST, gset);
    multicast(org, MULTICAST_PVS);

    // combat.cpp:329-341 - the body itself is gone.  Not hidden: gone, because a
    // gibbed monster has no corpse to shoot at any more and leaving an invisible
    // pancake behind would be a trap for the player and for every trace.
    //
    // The identity is torn down BEFORE the remove, and that is not tidiness.
    // A freed edict keeps returning its old field values for the rest of the
    // frame, so a caller still holding this entity - a shotgun applying its
    // remaining pellets, a radius blast walking its list - would sail straight
    // back into the corpse branch of W_ApplyDamage and gib the same body again.
    // Measured: a 60-iteration test loop kept "hitting" a body 59 times after
    // it had already come apart.
    body.deadflag   = DEAD_NO;
    body.takedamage = DAMAGE_NO;
    body.flags      = body.flags - (body.flags & FL_MONSTER);
    body.solid      = SOLID_NOT;
    remove(body);
};

// ---------------------------------------------------------------------------
// sv_ai_corpsetest  —  the corpse damage rules, measured
// ---------------------------------------------------------------------------
// Three claims, three numbers, one run:
//   1. a corpse can be HIT at all           (it used to be SOLID_NOT)
//   2. bullets bleed it and NEVER gib it    (DMG_BULLET is not in DMG_GIB_CORPSE)
//   3. club damage chips it and eventually  (the damage*0.1 accumulator,
//      DOES gib it                           combat.cpp:1013)
//
// Damage is applied directly rather than by shooting, because a bot that cannot
// aim at a one-unit-tall pancake would measure its own marksmanship instead of
// the rules under test.
float corpsetest_stage;
float corpsetest_next;
entity corpsetest_body;
// Hoisted: fteqcc scopes locals per FUNCTION, not per block, so a second
// `float i` in a sibling if-block is a Q207 duplicate that silently aliases.
float corpsetest_i;

void() AI_CorpseTest =
{
    if (!cvar("sv_ai_corpsetest"))
        return;
    if (time < corpsetest_next)
        return;
    corpsetest_next = time + 1;

    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
        return;

    if (corpsetest_stage == 0)
    {
        // Find a live monster and kill it cleanly — one point of damage against
        // one point of health, so nothing is overkilled into gibs by accident.
        entity m = findchain(classname, "monster_headcrab");
        entity best = world;
        while (m)
        {
            if (m.health > 0 && m.deadflag == DEAD_NO) { best = m; break; }
            m = m.chain;
        }
        if (!best)
        {
            entity e = nextent(world);
            while (e)
            {
                if ((e.flags & FL_MONSTER) && e.health > 0 && e.deadflag == DEAD_NO)
                { best = e; break; }
                e = nextent(e);
            }
        }
        if (!best)
        {
            dprint("[corpse] no live monster yet\n");
            return;
        }
        best.health = 1;
        W_ApplyDamage(p, best, 1);
        corpsetest_body = best;
        corpsetest_stage = 1;
        dprint(sprintf("[corpse] killed \"%s\": deadflag=%g solid=%g takedamage=%g health=%g size_z=%g\n",
                       best.classname, best.deadflag, best.solid, best.takedamage,
                       best.health, best.maxs_z - best.mins_z));
        return;
    }

    if (!corpsetest_body || corpsetest_body.deadflag != DEAD_DEAD)
    {
        dprint("[corpse] body vanished before the test finished\n");
        cvar_set("sv_ai_corpsetest", "0");
        return;
    }

    if (corpsetest_stage == 1)
    {
        // Ten bullets.  Every one should register as a corpse hit and NOT gib.
        float before = ai_dbg_corpse_gib;
        for (corpsetest_i = 0; corpsetest_i < 10; corpsetest_i = corpsetest_i + 1)
        {
            sv_dmg_bits = DMG_BULLET;
            W_ApplyDamage(p, corpsetest_body, 12);
        }
        dprint(sprintf("[corpse] 10 bullets: hits=%g gibs=%g (gibs MUST be 0) health=%g\n",
                       ai_dbg_corpse_hit, ai_dbg_corpse_gib - before, corpsetest_body.health));
        corpsetest_stage = 2;
        return;
    }

    if (corpsetest_stage == 2)
    {
        // Deliberately WEAK swings (2 damage).  A real crowbar does ~25 and a
        // headcrab corpse's whole pool is 5, so a realistic swing takes the
        // "health <= damage -> gib now" branch on the first hit and the chip
        // accumulator is never exercised at all.  Both branches are the rule
        // under test, so this drives the one a big weapon skips over.
        float swings = 0;
        for (corpsetest_i = 0; corpsetest_i < 60; corpsetest_i = corpsetest_i + 1)
        {
            if (!corpsetest_body || corpsetest_body.deadflag != DEAD_DEAD)
                break;
            sv_dmg_bits = DMG_CLUB;
            W_ApplyDamage(p, corpsetest_body, 2);
            swings = swings + 1;
        }
        dprint(sprintf("[corpse] club swings to gib: %g (chips=%g gibs=%g)\n",
                       swings, ai_dbg_corpse_chip, ai_dbg_corpse_gib));
        cvar_set("sv_ai_corpsetest", "0");
        corpsetest_stage = 0;
        return;
    }
};

// ---------------------------------------------------------------------------
// sv_ai_firetest  —  does this monster's attack actually reach a player?
// ---------------------------------------------------------------------------
// Spawns one of each reported-broken shooter in a ring around the first live
// player, waits, and prints the damage each one landed.  That single number is
// what separates the two failure modes that look identical in play and have
// completely different causes:
//
//   shots=0  dmg=0   the attack never fires        (male assassin: wrong event
//                                                   table; hwgrunt: fires on
//                                                   5001; shocktrooper: no
//                                                   cooldown, cycling forever)
//   shots>0  dmg=0   it fires and misses the player entirely
//                                                  (houndeye: AI_BlastAttack
//                                                   pre-filtered on takedamage,
//                                                   which players never have)
//
// The monsters are placed OUTSIDE melee reach and inside range-attack reach so
// the thing under test is the gun, not the kick.
float firetest_stage;
float firetest_next;
float firetest_i;
float firetest_armed;

// Marks the monsters this test spawned, so the report can ignore the map's own.
.float firetest_mark;

// The roster is every shooter that has been CAUGHT not firing, kept rather than
// pruned once each is fixed: the whole point of the test is that a regression
// here is silent in play (a monster that runs at you and does nothing reads as
// bad pathing, not as a broken gun) and loud in this number.
const float FIRETEST_COUNT = 8;

string(float i) FireTest_Class =
{
	if (i == 0) return "monster_male_assassin";
	if (i == 1) return "monster_shocktrooper";
	if (i == 2) return "monster_hwgrunt";
	if (i == 3) return "monster_houndeye";
	// Both of these carry a Desert Eagle, and the medic had never fired at all:
	// it runs Barney_ClassInit, whose handler shoots on code 3, while
	// hgrunt_medic.mdl fires on code 4.
	if (i == 4) return "monster_human_medic_ally";
	if (i == 5) return "monster_human_torch_ally";
	if (i == 6) return "monster_alien_slave";
	// The gargantua, whose FLAME had never fired in this port at all - Garg_Event
	// handled slash and stomp and nothing else.  It belongs on this roster by the
	// roster's own rule: it is a shooter that was caught not shooting.  The ring
	// distances happen to suit it exactly, 200 and 120 both sitting inside the
	// 80..330 band CheckMeleeAttack2 requires.
	return "monster_gargantua";
};

void() AI_FireTest =
{
	if (!cvar("sv_ai_firetest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	// KEEP THE TARGET ALIVE, every tick, BEFORE the timer gate.
	//
	// Without this the bot dies partway through and every monster loses its enemy
	// to COND_ENEMY_DEAD.  Measured: the houndeye selected range_attack1 once and
	// then reported alert_stand with dmg=0, which reads as "its blast is broken"
	// and actually meant the target stopped existing two seconds into a
	// 2.36-second wind-up.  The houndeye has the longest attack in the game, so
	// it is always the one this costs - which is exactly the monster the test was
	// added to clear.
	if (firetest_stage == 1)
		p.health = 1000;

	// ARM AND WAIT before placing anything.  A bot appears in player_chain within
	// a second of map load and is still standing at the map ORIGIN at that point,
	// so the ring of candidate spots gets measured against a position in the void
	// and every subject reports "COULD NOT BE PLACED anywhere" - which on the
	// console is indistinguishable from seven monsters that spawned fine and did
	// not shoot.  Reproduced on th_ep1_00 and pizza_ya_san1; the runs where this
	// test worked are the ones where the bot happened to have moved first.
	//
	// Found while building sv_ai_deathtest, which had the same failure for the
	// same reason.  sv_ai_spawntest documents the trap (sv_ai_core.qc:2353-2366)
	// and is the only one of the four that guarded against it.
	if (!firetest_armed)
	{
		firetest_armed = TRUE;
		firetest_next  = time + 5;
		return;
	}

	if (time < firetest_next)
		return;

	if (firetest_stage == 0)
	{
		// A houndeye's blast radius is 384 and its attack range is 384, so 260
		// puts every one of these inside its own range and outside GRU_MELEE_REACH.
		for (firetest_i = 0; firetest_i < FIRETEST_COUNT; firetest_i = firetest_i + 1)
		{
			// TRY CANDIDATE SPOTS UNTIL ONE ACTUALLY TAKES, and use the real
			// acceptance test rather than approximating it.
			//
			// Two earlier versions of this guessed at a spot - a traced ray with a
			// backoff, then a floor probe - and both reported
			// "could not be placed (movemode 0) - left inert" for all five, which
			// on the console looks exactly like "spawned fine and did not shoot".
			// An arbitrary map spawn point has no guarantee of clear ground in any
			// particular direction, so ASK: build it, and if AI_Spawn refused the
			// spot, throw it away and try the next one.
			//
			// Rings first (further is better - it keeps the range attack out of
			// Grunt_CheckAttack's melee veto), then closer, then the player's own
			// origin, which is standable by definition.
			float ft_ok = FALSE;
			float ft_los = FALSE;
			float ft_try;
			entity m = world;

			for (ft_try = 0; ft_try < 24 && !ft_ok; ft_try = ft_try + 1)
			{
				float ft_dist = 200;
				if (ft_try >= 8)  ft_dist = 120;
				if (ft_try >= 16) ft_dist = 64;

				makevectors('0 1 0' * (firetest_i * 72 + (ft_try & 7) * 45));
				vector spot = p.origin + v_forward * ft_dist;

				entity oldself = self;
				m = spawn();
				m.classname = FireTest_Class(firetest_i);
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
				{
					// PLACED, but that is not enough: this test is about the
					// ATTACK, and a monster with no line of sight never raises
					// COND_CAN_RANGE1 and spends the whole run in chase_enemy
					// instead.  Measured - the first four subjects all reported
					// dmg=0 with sched=chase_failed, which reads as "its gun is
					// broken" and actually meant "it is behind a wall".
					traceline(m.origin + '0 0 48', p.origin + p.view_ofs,
					          MOVE_NOMONSTERS, m);
					ft_los = (trace_fraction >= 1 || trace_ent == p);

					// Sight is REQUIRED while there are still spots to try, and
					// merely preferred on the last few.  A map whose player spawn
					// is a closet - hl_c01_a1 is one - has no spot at all that is
					// both standable and in view, and refusing every one of them
					// reports nothing, which is worse than reporting a subject that
					// has to walk first.  The flag is printed either way so the
					// reader can tell which kind of run this was.
					if (ft_los || ft_try >= 16)
						ft_ok = TRUE;
				}
				if (!ft_ok)
				{
					// Monster_Teardown BEFORE remove, and this is not optional:
					// Monster_Build calls monster_chain_add UNCONDITIONALLY, even
					// for a body AI_Spawn refused to place.  A bare remove() then
					// leaves a freed edict wired into a doubly-linked list that a
					// per-frame walker reads - which is precisely the hazard the
					// chain's own header comment warns about, and it cost this test
					// three of its four subjects before the report ran.
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!ft_ok)
			{
				dprint(sprintf("[firetest] %-24s COULD NOT BE PLACED anywhere\n",
				               FireTest_Class(firetest_i)));
				continue;
			}

			// ALLIES HAVE TO BE UN-ALLIED FIRST, and forgetting it produced a
			// result that read exactly like a broken gun.  The medic and the torch
			// are is_player_ally, so the faction matrix refuses the player as an
			// enemy no matter what ai_enemy is set to below - they turned on
			// whichever subject was standing nearest instead and reported
			// "dmg=0 sched=range_attack1", i.e. visibly attacking and landing
			// nothing.  This test measures the WEAPON; the faction matrix has its
			// own self-test and does not need to be re-measured here.
			m.is_player_ally = FALSE;
			m.ai_class       = CLASS_HUMAN_MILITARY;

			// Hand it the player directly: this measures the ATTACK, not the
			// acquisition, and waiting for sight lines on an arbitrary map would
			// measure the map.
			m.ai_enemy      = p;
			m.ai_state      = MS_COMBAT;
			m.firetest_mark = 1;

			// INVULNERABLE for the duration.  The first working run of this lost
			// every subject before the report: the harness runs with bot_minplayers
			// and the bot simply shot them, so "5 of 5 test monsters gone" was the
			// bot's marksmanship being measured instead of the monsters' attacks.
			// takedamage NO is enough - W_CanDamageTarget rejects any non-player
			// that is not DAMAGE_YES.
			m.takedamage = DAMAGE_NO;
			m.health     = 100000;

			dprint(sprintf("[firetest] spawned %-24s model=%-28s d=%g\n",
			               m.classname, m.model, rint(vlen(m.origin - p.origin))));
		}
		firetest_stage = 1;
		// 20, not 14.  The houndeye keeps reporting dmg=0 and it is the WINDOW, not
		// the blast: traced through the log, it selects range_attack1 for the first
		// time three seconds AFTER the report has already been printed, because it
		// spends the opening seconds in combat_face and then needs a 2.36 s wind-up
		// - by a wide margin the longest attack in the game.  The class this test
		// was added to clear was the one class it could not measure.
		firetest_next  = time + 20;
		return;
	}

	dprint("[firetest] --- damage landed on the player, per class ---\n");
	entity e = monster_chain_head;
	// Only the monsters THIS test spawned.  A live map carries hundreds of its own
	// and the first run of this drowned the five that mattered in scientists.
	float found = 0;
	while (e)
	{
		if (e.firetest_mark)
		{
			dprint(sprintf("[firetest] %-24s dmg=%-6g hp=%-5g state=%g sched=%s\n",
			               e.classname, e.ai_dbg_dmgdealt, e.health, e.ai_state,
			               Sched_Name(e.ai_sched)));
			found = found + 1;
		}
		e = e.monster_chain_next;
	}
	if (found < FIRETEST_COUNT)
		dprint(sprintf("[firetest] %g of %g test monsters gone (killed or unplaced)\n",
		               FIRETEST_COUNT - found, FIRETEST_COUNT));
	cvar_set("sv_ai_firetest", "0");
	firetest_stage = 0;
	firetest_armed = FALSE;
};

// ---------------------------------------------------------------------------
// sv_ai_walktest  —  does this monster's LOCOMOTION cycle actually play?
// ---------------------------------------------------------------------------
// The firetest deliberately places its subjects already in range, so every one of
// them stands still and shoots: a whole firetest run reports walkmove=0.  That
// leaves the entire moving half of the animation system unmeasured, and it is the
// half where the footstep events live.
//
// So: same scaffolding, opposite placement.  Subjects go far enough out that they
// must walk in, and what is read afterwards is DISTANCE MOVED and the shared-event
// counters, not damage.
//
// The roster is a pair on purpose - one rig of each footstep dialect:
//
//   monster_human_grunt   valve's hgrunt, which SPELLS its footsteps out as
//                         EVENT_SOUND naming common/npc_step*.wav.  The control:
//                         if this one is silent the fault is in walking, not in
//                         the new code.
//   monster_hwgrunt       the only rig in this install that reaches code 2003,
//                         which carries no name at all.  The subject.
//
// Both walk the same cycle, so `shared` moving while `step` stays at 0 localises
// the fault to the 2003 branch and nothing else.
float walktest_stage;
float walktest_next;
float walktest_i;

.float walktest_mark;
.vector walktest_start;

const float WALKTEST_COUNT = 2;

string(float i) WalkTest_Class =
{
	if (i == 0) return "monster_human_grunt";
	return "monster_hwgrunt";
};

void() AI_WalkTest =
{
	if (!cvar("sv_ai_walktest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	if (walktest_stage == 1)
		p.health = 1000;

	if (time < walktest_next)
		return;

	if (walktest_stage == 0)
	{
		for (walktest_i = 0; walktest_i < WALKTEST_COUNT; walktest_i = walktest_i + 1)
		{
			// FAR first and closing in, which is the mirror image of the firetest's
			// ring: there the retries move inward to find standable ground, here they
			// move inward only reluctantly, because a subject that spawns already in
			// range never takes a step and produces the exact zero this test exists
			// to distinguish from a broken handler.
			float wt_ok = FALSE;
			float wt_try;
			entity m = world;

			for (wt_try = 0; wt_try < 24 && !wt_ok; wt_try = wt_try + 1)
			{
				float wt_dist = 900;
				if (wt_try >= 8)  wt_dist = 640;
				if (wt_try >= 16) wt_dist = 420;

				makevectors('0 1 0' * (walktest_i * 144 + (wt_try & 7) * 45));
				vector spot = p.origin + v_forward * wt_dist;

				entity oldself = self;
				m = spawn();
				m.classname = WalkTest_Class(walktest_i);
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
					wt_ok = TRUE;
				else
				{
					// See the firetest's note: Monster_Build chains the body even when
					// AI_Spawn refuses the spot, so a bare remove() leaves a freed
					// edict wired into a list a per-frame walker reads.
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!wt_ok)
			{
				dprint(sprintf("[walktest] %-24s COULD NOT BE PLACED anywhere\n",
				               WalkTest_Class(walktest_i)));
				continue;
			}

			m.is_player_ally = FALSE;
			m.ai_class       = CLASS_HUMAN_MILITARY;
			m.ai_enemy       = p;
			m.ai_state       = MS_COMBAT;
			m.walktest_mark  = 1;
			m.walktest_start = m.origin;
			m.takedamage     = DAMAGE_NO;
			m.health         = 100000;

			dprint(sprintf("[walktest] spawned %-24s model=%-28s d=%g\n",
			               m.classname, m.model, rint(vlen(m.origin - p.origin))));
		}
		walktest_stage = 1;
		// Long enough to arrive AND then fight.  A subject starting 900 units out
		// spends the first ten seconds walking, so a shorter window measures only
		// the approach - and the approach is not the only thing worth reading here
		// (the grunt's grenade needs him stationary, in sight and past his own
		// 256-unit blast radius, which only happens after he has closed).
		walktest_next  = time + 24;
		return;
	}

	dprint("[walktest] --- distance moved, per class ---\n");
	entity e = monster_chain_head;
	float found = 0;
	while (e)
	{
		if (e.walktest_mark)
		{
			dprint(sprintf("[walktest] %-24s moved=%-6g d=%-5g act=%g seq=%s sched=%s\n",
			               e.classname, rint(vlen(e.origin - e.walktest_start)),
			               rint(vlen(e.origin - p.origin)), e.ai_activity,
			               e.ai_seqname, Sched_Name(e.ai_sched)));
			found = found + 1;
		}
		e = e.monster_chain_next;
	}
	if (found < WALKTEST_COUNT)
		dprint(sprintf("[walktest] %g of %g test monsters gone\n",
		               WALKTEST_COUNT - found, WALKTEST_COUNT));
	dprint(sprintf("[walktest] event totals this run: shared=%g star=%g step=%g swish=%g\n",
	               ai_dbg_ev_shared, ai_dbg_ev_star, ai_dbg_ev_step, ai_dbg_ev_swish));
	cvar_set("sv_ai_walktest", "0");
	walktest_stage = 0;
};

// ---------------------------------------------------------------------------
// sv_ai_deathtest  —  does a monster die the way it was shot?
// ---------------------------------------------------------------------------
// The one harness the other three cannot stand in for, and the reason is that
// this system fails SILENTLY BY DESIGN.  Every activity the death picker can
// choose already resolved to something before item G existed - ACT_DIE_HEADSHOT
// walks the fallback chain to ACT_DIESIMPLE, which is exactly what the old table
// constant asked for directly.  So "directional death works" and "directional
// death is dead code that degrades to the old behaviour on every rig" produce
// byte-identical logs, identical framerates and identical damage numbers.  Only a
// test that shoots a KNOWN monster from a KNOWN direction at a KNOWN hitgroup and
// reads back which sequence it actually chose can tell them apart.
//
// The roster spans the census deliberately - see the AI_ActivityFallback note for
// where those numbers come from - so a run exercises every branch of both HL
// functions rather than the happy path eight times:
//
//   subject       rig carries              asked for      exercises
//   hgrunt        head gut fwd back limbs  HEAD           the region pick outright
//   barney        head gut fwd back limbs  STOMACH        the other region pick
//   zombie        head gut fwd back limbs  GENERIC, shot from behind
//                                                         direction: falls forward
//   islave        head     fwd back limbs  GENERIC, shot from the front
//                                                         direction: falls backward
//   agrunt        head gut fwd back limbs  LEFTLEG        a limb is NOT a region:
//                                                         HL routes it to direction
//   bullsquid              fwd             HEAD, shot from behind
//                                                         region missing -> direction
//   houndeye               fwd back        GENERIC, shot from behind
//   headcrab      (nothing but DIESIMPLE)  HEAD           the control: must report
//                                                         die_simple whatever we do
//
// The flinch half asks every subject for HITGROUP_LEFTARM, which the first five
// rigs carry and the last three do not - so the same run reads both outcomes.
const float DEATHTEST_COUNT = 8;

float deathtest_stage;
float deathtest_next;
float deathtest_i;
float deathtest_armed;

.float  deathtest_mark;
.float  deathtest_flinch;	// .ai_dbg_hitact captured after the survivable hit
.float  deathtest_hg;		// the hitgroup this subject is shot in
.float  deathtest_behind;	// TRUE = shot from behind

// HELD BY REFERENCE, not found by walking monster_chain.  Monster_Killed calls
// Monster_Teardown, which unlinks the body from the chain before AI_Died has even
// started the death animation - so a report that walks the chain finds nothing
// and says "8 of 8 test monsters gone" about eight corpses lying right there.
entity  deathtest_ent[DEATHTEST_COUNT];

string(float i) DeathTest_Class =
{
	if (i == 0) return "monster_human_grunt";
	if (i == 1) return "monster_barney";
	if (i == 2) return "monster_zombie";
	if (i == 3) return "monster_alien_slave";
	if (i == 4) return "monster_alien_grunt";
	if (i == 5) return "monster_bullsquid";
	if (i == 6) return "monster_houndeye";
	return "monster_headcrab";
};

float(float i) DeathTest_Hitgroup =
{
	if (i == 0) return HITGROUP_HEAD;
	if (i == 1) return HITGROUP_STOMACH;
	if (i == 2) return HITGROUP_GENERIC;
	if (i == 3) return HITGROUP_GENERIC;
	if (i == 4) return HITGROUP_LEFTLEG;
	if (i == 5) return HITGROUP_HEAD;
	if (i == 6) return HITGROUP_GENERIC;
	return HITGROUP_HEAD;
};

// TRUE = the subject is turned AWAY from the player before the killing blow, so
// the shot arrives in its back and a directional death falls forward.
float(float i) DeathTest_Behind =
{
	if (i == 2) return TRUE;
	if (i == 5) return TRUE;
	if (i == 6) return TRUE;
	return FALSE;
};

string(float hg) DeathTest_HgName =
{
	if (hg == HITGROUP_HEAD)	return "head";
	if (hg == HITGROUP_CHEST)	return "chest";
	if (hg == HITGROUP_STOMACH)	return "stomach";
	if (hg == HITGROUP_LEFTARM)	return "leftarm";
	if (hg == HITGROUP_RIGHTARM)	return "rightarm";
	if (hg == HITGROUP_LEFTLEG)	return "leftleg";
	if (hg == HITGROUP_RIGHTLEG)	return "rightleg";
	return "generic";
};

// Point the subject at the player - always, regardless of which side the shot is
// meant to arrive from, because the shot's origin is controlled separately below.
// Pinning the ideal is not cosmetic: AI_DeathActivity reads .angles_y at the
// moment TASK_PLAY_DEATH runs, which is one or more decision ticks after the
// killing blow, and AI_ChangeYaw would happily rotate the body toward its old
// ideal in between and silently turn a back-shot into a front-shot.
void(entity m, entity p, float behind) DeathTest_Face =
{
	vector d = p.origin - m.origin;
	d_z = 0;
	if (d == '0 0 0')
		d = '1 0 0';
	float yaw = vectoyaw(d);
	m.angles       = [0, yaw, 0];
	m.ai_yaw_ideal = yaw;
};

// A DUMMY INFLICTOR RATHER THAN THE PLAYER, parked exactly where the shot is
// supposed to have come from.  Two things this buys that shooting from the
// player's actual position cannot:
//
//   THE DIRECTION IS EXACT.  .ai_attackdir is measured centre-to-centre from the
//   inflictor, so putting the dummy 100 units off the subject's own facing makes
//   the dot product +/-1 by construction instead of whatever angle the ring
//   placement happened to produce.
//
//   THE PLAYER STAYS OUT OF IT.  A player damaging an ally runs AI_Provoke, which
//   turns the subject hostile and puts it straight into a combat schedule - the
//   exact state that was delaying the flinch pick.  A bare entity is not a valid
//   enemy, so nothing is provoked and the subject stays in MS_ALERT where a flinch
//   is what the ladder actually selects.
entity deathtest_inflictor;

entity(entity m) DeathTest_Inflictor =
{
	if (!deathtest_inflictor)
		deathtest_inflictor = spawn();

	makevectors(m.angles);
	vector c = m.origin + (m.mins + m.maxs) * 0.5;
	// In front when the shot is meant to arrive from the front, behind when it is
	// meant to arrive from behind.  The +10 undoes the "pretend the inflictor is
	// ten units lower" that AI_ConsumeHit applies, so the vector is level.
	vector off = v_forward * 100 + '0 0 10';
	if (m.deathtest_behind)
		off = off - v_forward * 200;
	setorigin(deathtest_inflictor, c + off);
	return deathtest_inflictor;
};

void() AI_DeathTest =
{
	if (!cvar("sv_ai_deathtest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	// The player is the INFLICTOR for every blow here, so it has to survive the
	// whole run: .ai_attackdir is measured from its centre, and a dead player's
	// origin is not where the shot came from.
	if (deathtest_stage > 0)
		p.health = 1000;

	// THE PLAYER HAS TO BE SOMEWHERE REAL, not merely alive.  This is the trap
	// sv_ai_spawntest already documents (sv_ai_core.qc:2353-2366) and that the
	// firetest and the walktest do NOT guard against: a client put into the server
	// but not yet moved to a spawn point reads as perfectly valid - right health,
	// right solidity, in the player chain - while standing at the map origin, so
	// every candidate spot in the ring is measured against a position in the void.
	//
	// STATED PLAINLY, because the guard below is weaker than it looks: it does NOT
	// rescue every map.  On th_ep1_00 a bot_minplayers bot sits at '0 0 37' - the
	// map origin - for the whole run, and that map has nav nodes near the origin,
	// so the proximity test passes and all eight subjects still report "COULD NOT
	// BE PLACED anywhere".  The firetest reports the same thing on the same map for
	// the same reason, which is how this surfaced; its published roster comes from
	// maps where the bot does spawn properly.  2fort is one, and is what the
	// deathtest results were taken on.
	//
	// The guard is kept because it catches the case it can catch cheaply and turns
	// it into a named line instead of eight identical placement failures.
	if (nav_count > 0)
	{
		float dt_i, dt_near = -1;
		for (dt_i = 0; dt_i < nav_count; dt_i = dt_i + 1)
		{
			float dt_d = vlen(nav_pos[dt_i] - p.origin);
			if (dt_near < 0 || dt_d < dt_near)
				dt_near = dt_d;
		}
		if (dt_near > NAV_LINK_DIST * 2)
		{
			if (time >= deathtest_next)
			{
				deathtest_next = time + 5;
				dprint(sprintf("[deathtest] \"%s\" is at %v, %g units from the nearest nav node - waiting for a real spawn\n",
				               p.netname, p.origin, dt_near));
			}
			return;
		}
	}

	// ...and then let the map settle for a moment anyway, so the subject ring is
	// placed around where the player ENDED UP rather than where they arrived.
	if (!deathtest_armed)
	{
		deathtest_armed = TRUE;
		deathtest_next  = time + 3;
		return;
	}

	if (time < deathtest_next)
		return;

	if (deathtest_stage == 0)
	{
		for (deathtest_i = 0; deathtest_i < DEATHTEST_COUNT; deathtest_i = deathtest_i + 1)
		{
			// Same placement loop and same reasons as the firetest: ask
			// Monster_Build whether the spot took rather than guessing, and tear
			// the body out of the monster chain before removing a refused one.
			float dt_ok = FALSE;
			float dt_try;
			entity m = world;

			for (dt_try = 0; dt_try < 24 && !dt_ok; dt_try = dt_try + 1)
			{
				float dt_dist = 180;
				if (dt_try >= 8)  dt_dist = 120;
				if (dt_try >= 16) dt_dist = 64;

				makevectors('0 1 0' * (deathtest_i * 45 + (dt_try & 7) * 45));
				vector spot = p.origin + v_forward * dt_dist;

				entity oldself = self;
				m = spawn();
				m.classname = DeathTest_Class(deathtest_i);
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
					dt_ok = TRUE;
				else
				{
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!dt_ok)
			{
				dprint(sprintf("[deathtest] %-24s COULD NOT BE PLACED anywhere\n",
				               DeathTest_Class(deathtest_i)));
				continue;
			}

			// ONE FACTION FOR ALL EIGHT, and not the player's enemy either.  With
			// their own factions they fought each other the moment they landed -
			// measured as every subject in MS_COMBAT running range_attack1, with
			// health ticking down from crossfire - and a monster mid-attack takes
			// its schedule from the class virtual, which sits ABOVE the generic
			// flinch branch in AI_SelectSchedule.  So the flinch pick arrived
			// several seconds late and the run measured schedule precedence rather
			// than the picker.  Being shot from ambush is the ordinary case for a
			// flinch anyway.
			m.is_player_ally  = TRUE;
			m.ai_class        = CLASS_PLAYER_ALLY;
			m.ai_enemy        = world;
			m.ai_state        = MS_ALERT;
			m.deathtest_mark  = 1;
			m.deathtest_hg    = DeathTest_Hitgroup(deathtest_i);
			m.deathtest_behind = DeathTest_Behind(deathtest_i);
			m.health          = 1000;	// must survive the flinch hit
			m.max_health      = 1000;
			m.ai_lasthealth   = 1000;
			deathtest_ent[deathtest_i] = m;

			dprint(sprintf("[deathtest] spawned %-24s model=%-28s d=%g\n",
			               m.classname, m.model, rint(vlen(m.origin - p.origin))));
		}
		deathtest_stage = 1;
		deathtest_next  = time + 2;	// let them land and settle
		return;
	}

	entity e;
	float  k;

	if (deathtest_stage == 1)
	{
		// The survivable hit, in the arm.  25 damage against 1000 health cannot
		// kill anything, so every subject reaches the flinch branch.
		for (k = 0; k < DEATHTEST_COUNT; k = k + 1)
		{
			e = deathtest_ent[k];
			if (e && (e.flags & FL_MONSTER) && e.deathtest_mark && e.health > 0)
			{
				e.ai_dbg_hitact  = 0;
				e.ai_nextflinch  = 0;	// no cooldown left over from spawn
				e.death_hitgroup = HITGROUP_LEFTARM;
				DeathTest_Face(e, p, e.deathtest_behind);
				W_ApplyDamage(DeathTest_Inflictor(e), e, 25);
			}
		}
		deathtest_stage = 2;
		// 2.5 s, not 1.  Measured: at one second every subject still reported
		// flinch=- and then showed a flinch activity in the DEATH column, which is
		// the pick arriving late rather than not at all - a monster that has just
		// been placed is mid-schedule, and the flinch only reaches the front of
		// the queue once the current task yields.
		deathtest_next  = time + 2.5;
		return;
	}

	if (deathtest_stage == 2)
	{
		// Capture the flinch BEFORE the killing blow overwrites the latch, then
		// turn each subject and kill it.
		for (k = 0; k < DEATHTEST_COUNT; k = k + 1)
		{
			e = deathtest_ent[k];
			if (e && (e.flags & FL_MONSTER) && e.deathtest_mark && e.health > 0)
			{
				e.deathtest_flinch = e.ai_dbg_hitact;
				e.ai_dbg_hitact    = 0;
				DeathTest_Face(e, p, e.deathtest_behind);
				e.death_hitgroup   = e.deathtest_hg;
				// A SMALL killing blow, not a huge one.  The obvious 100000 gibs
				// every subject - Gib_ShouldGibOnDeath is exactly HL's "was the
				// killing blow far past zero" test - and a gibbed monster is
				// removed outright and never plays a death sequence at all, which
				// reported as eight subjects that died without choosing anything.
				// Drop the pool to ten and take it off with twelve instead.
				e.health     = 10;
				e.max_health = 80;
				W_ApplyDamage(DeathTest_Inflictor(e), e, 12);
			}
		}
		deathtest_stage = 3;
		deathtest_next  = time + 2.5;
		return;
	}

	dprint("[deathtest] --- flinch and death activity chosen, per class ---\n");
	float found = 0;
	for (k = 0; k < DEATHTEST_COUNT; k = k + 1)
	{
		e = deathtest_ent[k];
		if (e && e.deathtest_mark)
		{
			// `ideal` says whether the rig could do what the picker was asked for,
			// which is what separates "the plumbing is broken" from "this model
			// simply has no such sequence" - the two produce the same die_simple.
			float ideal = ACT_DIESIMPLE;
			if (e.deathtest_hg == HITGROUP_HEAD)         ideal = ACT_DIE_HEADSHOT;
			else if (e.deathtest_hg == HITGROUP_STOMACH) ideal = ACT_DIE_GUTSHOT;
			else if (e.deathtest_behind)                 ideal = ACT_DIEFORWARD;
			else                                         ideal = ACT_DIEBACKWARD;

			dprint(sprintf("[deathtest] %-22s hg=%-8s %s flinch=%-15s death=%-14s ideal=%-14s%s\n",
			               e.classname, DeathTest_HgName(e.deathtest_hg),
			               e.deathtest_behind ? "behind" : "front ",
			               AI_HitActName(e.deathtest_flinch),
			               AI_HitActName(e.ai_dbg_hitact),
			               AI_HitActName(ideal),
			               AI_HasActivity(e, ideal) ? "" : "(rig lacks it) "));
			// The state line: a death activity that never got picked and a subject
			// that never died look identical in the column above, and they are
			// completely different failures.
			dprint(sprintf("[deathtest]     hp=%g deadflag=%g state=%g sched=%s act=%g\n",
			               e.health, e.deadflag, e.ai_state,
			               Sched_Name(e.ai_sched), e.ai_activity));
			found = found + 1;
			deathtest_ent[k] = world;
		}
	}
	if (found < DEATHTEST_COUNT)
		dprint(sprintf("[deathtest] %g of %g test subjects unplaced or gibbed\n",
		               DEATHTEST_COUNT - found, DEATHTEST_COUNT));
	dprint(sprintf("[deathtest] totals: deaths group=%g dir=%g simple=%g (nowhere-to-fall=%g)  flinch limb=%g generic=%g\n",
	               ai_dbg_die_group, ai_dbg_die_dir, ai_dbg_die_simple,
	               ai_dbg_die_blocked, ai_dbg_flinch_group, ai_dbg_flinch_generic));
	cvar_set("sv_ai_deathtest", "0");
	deathtest_stage = 0;
	deathtest_armed = FALSE;
};

// ---------------------------------------------------------------------------
// sv_ai_squadtest  —  do four grunts behave like a squad or like four grunts?
// ---------------------------------------------------------------------------
// The self-test in sv_ai_core.qc proves the DATA STRUCTURE: recruit, ration,
// inherit, disband.  It cannot prove the behaviour, because it never lets the
// four bodies think - it calls the squad functions directly.
//
// This one is the other half.  Four grunts, one player, twenty seconds, and the
// three numbers that separate a squad from four individuals standing near each
// other:
//
//   callouts   one grunt seeing the player must hand the enemy to the other
//              three.  Zero here with a live fight going on means SquadMakeEnemy
//              never fires and the squad discovers you one man at a time.
//   denied     the attack ration doing its job.  Zero with four grunts and two
//              engage slots means every one of them is shooting at once, which
//              is the firing line the slots exist to prevent.
//   ff-holds   shots held because a squadmate was in the line of fire.
//
// The roster is deliberately ONE class four times over: two of a kind within
// 1024 units with line of sight is the entire precondition for a squad, and the
// firetest's one-of-each roster can never satisfy it.
const float SQUADTEST_COUNT = 4;

float squadtest_stage;
float squadtest_next;
float squadtest_i;
float squadtest_armed;

.float squadtest_mark;

void() AI_SquadTest =
{
	if (!cvar("sv_ai_squadtest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	if (squadtest_stage == 1)
		p.health = 1000;

	// Same arming delay and the same reason as the firetest above: a bot in
	// player_chain within a second of map load is still standing at the map
	// origin, and a ring measured against that is a ring in the void.
	if (!squadtest_armed)
	{
		squadtest_armed = TRUE;
		squadtest_next  = time + 5;
		return;
	}

	if (time < squadtest_next)
		return;

	if (squadtest_stage == 0)
	{
		for (squadtest_i = 0; squadtest_i < SQUADTEST_COUNT; squadtest_i = squadtest_i + 1)
		{
			float st_ok = FALSE;
			float st_try;
			entity m = world;

			for (st_try = 0; st_try < 24 && !st_ok; st_try = st_try + 1)
			{
				float st_dist = 220;
				if (st_try >= 8)  st_dist = 150;
				if (st_try >= 16) st_dist = 90;

				// AN ARC, not the firetest's even ring.  Squadmates have to be
				// able to SEE each other for recruitment to take, and four
				// monsters spread evenly around a player are as likely as not to
				// have the map between them.
				//
				// 40 degrees rather than 25.  This was an attempt to make the SLOT
				// ration the binding constraint rather than NoFriendlyFire, and
				// it did not work: the placement retry loop rejects most of the
				// wide angles as unstandable and lands the four in much the same
				// bunch either way (d=223..229 both times, ff-holds 193 then 194).
				//
				// Recorded rather than reverted, because the failed attempt is the
				// finding: in any arrangement where four grunts face one target
				// from one side, NOBODY is refused a slot, because the two without
				// a clear line are stopped by friendly fire first and never reach
				// the slot request.  `denied` is therefore 0 in this test and that
				// is a true reading of the code, not a broken ration - the ration
				// is proven deterministically by AI_SquadMonsterSelfTest (2 of 4
				// win a slot) and observably here by the two attackers holding
				// DISTINCT bits, 1 and 2.
				makevectors('0 1 0' * (squadtest_i * 40 + (st_try & 7) * 45));
				vector spot = p.origin + v_forward * st_dist;

				entity oldself = self;
				m = spawn();
				m.classname = "monster_human_grunt";
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
					st_ok = TRUE;
				else
				{
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!st_ok)
			{
				dprint("[squadtest] monster_human_grunt COULD NOT BE PLACED anywhere\n");
				continue;
			}

			m.is_player_ally = FALSE;
			m.ai_class       = CLASS_HUMAN_MILITARY;
			m.squadtest_mark = 1;
			m.takedamage     = DAMAGE_NO;
			m.health         = 100000;

			// NO ai_enemy handed over, unlike the firetest - the callout is one
			// of the three things under test, and giving all four the player up
			// front would make it unmeasurable.  They have to find him.
			dprint(sprintf("[squadtest] spawned grunt %g at d=%g\n",
			               squadtest_i, rint(vlen(m.origin - p.origin))));
		}
		squadtest_stage = 1;
		squadtest_next  = time + 20;
		return;
	}

	dprint("[squadtest] --- squad state, per grunt ---\n");
	entity e = monster_chain_head;
	float found = 0;
	while (e)
	{
		if (e.squadtest_mark)
		{
			dprint(sprintf("[squadtest] grunt squad=%g leader=%s slot=%i enemy=%s sched=%s\n",
			               Squad_Count(e),
			               Squad_IsLeader(e) ? "self" : (Squad_In(e) ? "other" : "none"),
			               e.ai_slot,
			               e.ai_enemy ? e.ai_enemy.classname : "-",
			               Sched_Name(e.ai_sched)));
			found = found + 1;
		}
		e = e.monster_chain_next;
	}
	if (found < SQUADTEST_COUNT)
		dprint(sprintf("[squadtest] %g of %g grunts unplaced\n",
		               SQUADTEST_COUNT - found, SQUADTEST_COUNT));
	dprint(sprintf("[squadtest] totals: squads=%g members=%g callouts=%g slots won=%g denied=%g ff-holds=%g friend-dmg=%g\n",
	               ai_dbg_squad_leaders, ai_dbg_squad_recruits,
	               ai_dbg_squad_callouts, ai_dbg_squad_slotwins,
	               ai_dbg_squad_slotdenied, ai_dbg_squad_ffholds,
	               ai_dbg_squad_frienddmg));
	cvar_set("sv_ai_squadtest", "0");
	squadtest_stage = 0;
	squadtest_armed = FALSE;
};

// ---------------------------------------------------------------------------
// sv_ai_covertest  —  does a monster under fire actually get out of the way?
// ---------------------------------------------------------------------------
// AI_CoverSelfTest proves the PIECES: spacing, the guard rail, the facing test,
// the schedule shapes.  It cannot prove the behaviour, because every one of its
// assertions is arithmetic and cover is a question about a MAP - "is there
// anywhere within 784 units that breaks this line of sight, and can this monster
// get to it".  No amount of geometry-independent testing answers that, and the
// five-map regression cannot either: nothing in it ever shoots a monster, so the
// whole system reports sched=0 tries=0 and looks identical to not existing.
//
// So: four monsters, one player, and a rifle round every two seconds.
//
// THE MEASUREMENT THAT MATTERS IS `hidden`, not `sched`.  A monster that selects
// cover forty times and is still standing in the open at the end has not taken
// cover; it has dithered, which is a worse picture than the charging it
// replaced.  Each subject's line of sight to the player is traced at the end and
// compared with the same trace taken at spawn, so the report says whether the
// monster is somewhere the player cannot see it - which is the entire point of
// the feature, stated as a number.
//
// The roster is four classes with four DIFFERENT triggers, so a single run
// exercises all of them:
//   monster_human_grunt   light damage, 90 % (hgrunt.cpp:2100-2124)
//   monster_human_grunt   ...twice, because the squad spacing rule only has
//                         anything to say when two subjects want cover at once
//   monster_alien_slave   damage, and the ENEMY_FACING_ME rule (islave.cpp:687)
//   monster_barney        heavy damage only (barney.cpp:720)
const float COVERTEST_COUNT  = 4;
const float COVERTEST_GAP    = 0.5;	// seconds between rounds
const float COVERTEST_PULSES = 40;	// ...so twenty seconds of sustained fire

string(float i) CoverTest_Class =
{
	if (i == 0)	return "monster_human_grunt";
	if (i == 1)	return "monster_human_grunt";
	if (i == 2)	return "monster_alien_slave";
	return "monster_barney";
};

// THE SLAVE HAS TO BE NEARLY DEAD OR ITS TRIGGER IS UNREACHABLE.
//
// islave.cpp:678 gates both of its cover branches on `health < 20`, so a subject
// held at the 2000 hit points the others need in order to survive the run can
// never take cover at all - the harness would exercise three triggers and report
// as though it had exercised four.  It is pinned just under the threshold and
// shot with a lighter round instead, and its health is restored after every
// pulse: the conditions come from the damage, not from the number.
float(float i) CoverTest_HP  = { if (i == 2) return 15; return 2000; };
float(float i) CoverTest_Dmg = { if (i == 2) return 5;  return 25; };

float covertest_stage;
float covertest_next;
float covertest_i;
float covertest_armed;
float covertest_pulses;
vector covertest_watch;		// where the player was when arming began

.float  covertest_mark;
.float  covertest_hp;		// health to hold this subject at between pulses
.vector covertest_home;
.float  covertest_seen;		// could the player see it where it started?

entity covertest_ent[COVERTEST_COUNT];

// Can the player see this monster right now?  Eye to eye, the same rule
// AI_CanSee and Cover_Hides both use - measuring cover with a different trace
// from the one that chose it would answer a different question.
float(entity p, entity m) CoverTest_Visible =
{
	vector pe = p.origin + p.view_ofs;
	vector me = m.origin;
	me_z = me_z + m.maxs_z * 0.8;
	traceline(pe, me, MOVE_NOMONSTERS, p);
	return (trace_fraction >= 1);
};

// CAN IT TAKE A STEP IN ANY DIRECTION AT ALL?
//
// Monster_Build setting FL_MONSTER means "this body fits here", which is a
// weaker claim than "this body can walk from here", and the gap between the two
// is where this harness lied to me for three runs.  On hl_c01_a1 a
// bot_minplayers bot never leaves the map origin - the trap sv_ai_spawntest
// documents and the deathtest guards against too loosely - and the origin region
// there is a sandwich of geometry that a grunt fits inside and cannot leave.
// All four subjects placed, all four reported moved=0, and the cover counters
// read sched=56 node=49 arrived=0: a perfect picture of a broken cover system,
// produced entirely by where the harness put its subjects.  The walktest control
// on the SAME map moved a grunt 956 units, which is what proved it.
//
// Four directions and a 64-unit step is the cheapest question that separates
// "wedged" from "shooting from a doorway": Cover_CanReach is the same hull sweep
// plus floor test the cover search itself uses, so a subject that passes here is
// one the search's own reachability rule would accept.
float(entity m) CoverTest_CanMove =
{
	float d;
	for (d = 0; d < 4; d = d + 1)
	{
		makevectors('0 1 0' * (d * 90));
		if (Cover_CanReach(m, m.origin + v_forward * 64))
			return TRUE;
	}
	return FALSE;
};

void() AI_CoverTest =
{
	if (!cvar("sv_ai_covertest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	if (covertest_stage > 0)
		p.health = 1000;

	// THE PLAYER HAS TO HAVE MOVED, which is a different and much stronger guard
	// than the one the deathtest carries, and it exists because the weaker one
	// let this harness produce three runs of confident nonsense.
	//
	// The trap is the one sv_ai_spawntest documents: a bot enters player_chain
	// within a second of map load - right health, right solidity - while still
	// standing at the map origin, so every subject is placed around a point in
	// the void.  The deathtest tests the player's distance to the nearest nav
	// node against NAV_LINK_DIST * 2, and that threshold is 4608 units, which
	// almost nothing fails; on hl_c01_a1 the bot sits at '0 0 37' for the whole
	// run with nodes well inside 4608 of it, so the guard passes and the harness
	// then reports sched=49 node=48 arrived=0 with every subject at moved=0 -
	// a perfect picture of broken cover, produced entirely by where the bot was
	// standing.  (The player position was not printed; it was recovered from the
	// subjects' own coordinates, which is a good reason to print it.)
	//
	// "Did it move" needs no map knowledge and no threshold to tune.  A bot that
	// spawned properly wanders; one that never left the origin does not.
	if (!covertest_armed)
	{
		covertest_armed = TRUE;
		covertest_next  = time + 5;
		covertest_watch = p.origin;
		return;
	}

	if (time < covertest_next)
		return;

	if (vlen(p.origin - covertest_watch) < 16)
	{
		dprint(sprintf("[covertest] \"%s\" has not moved from %v in five seconds - it never spawned properly, refusing to measure anything\n",
		               p.netname, p.origin));
		cvar_set("sv_ai_covertest", "0");
		covertest_armed = FALSE;
		return;
	}

	if (covertest_stage == 0)
		dprint(sprintf("[covertest] player at %v\n", p.origin));

	float k;
	entity e;

	if (covertest_stage == 0)
	{
		dprint(sprintf("[covertest] nav graph: %g nodes, grid %s\n",
		               nav_count, nav_grid_ready ? "ready" : "NOT READY"));

		for (covertest_i = 0; covertest_i < COVERTEST_COUNT; covertest_i = covertest_i + 1)
		{
			float ct_ok = FALSE;
			float ct_try;
			entity m = world;

			// THE SUBJECT MUST START WHERE THE PLAYER CAN SEE IT.  This is a
			// correction to the first version of this harness, which took any
			// standable spot: on th_ep1_01 three of the four subjects spawned
			// already out of sight, and "now=HIDDEN" for a monster that was never
			// exposed is not evidence of anything.  A harness that can report
			// success for a monster which did nothing is the same failure the
			// firetest's placement had, and it is worth refusing outright.
			//
			// The last third of the tries drop the requirement rather than lose
			// the class entirely - a subject placed blind is still worth having
			// for the counters - and the report prints was-visible either way, so
			// the reader can tell the two apart.
			for (ct_try = 0; ct_try < 36 && !ct_ok; ct_try = ct_try + 1)
			{
				// Further out than the squadtest's 220.  Cover is a MOVE, and a
				// monster spawned on top of the player has nowhere to go that is
				// not also within a step of him.
				float ct_dist = 320;
				if (ct_try >= 12) ct_dist = 240;
				if (ct_try >= 24) ct_dist = 160;

				makevectors('0 1 0' * (covertest_i * 50 + (ct_try & 11) * 30));
				vector spot = p.origin + v_forward * ct_dist;

				entity oldself = self;
				m = spawn();
				m.classname = CoverTest_Class(covertest_i);
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
					if (CoverTest_CanMove(m))
						if (ct_try >= 24 || CoverTest_Visible(p, m))
							ct_ok = TRUE;

				if (!ct_ok)
				{
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!ct_ok)
			{
				// Named, not silent, and it is worth being explicit about what
				// this line does and does not mean: it says the harness could
				// find nowhere around this player to run the experiment, which
				// is a statement about where the bot is standing, NOT about
				// whether cover works.  Reading it as the latter is exactly the
				// mistake the walktest control caught.
				dprint(sprintf("[covertest] %s COULD NOT BE PLACED anywhere standable, visible and walkable\n",
				               CoverTest_Class(covertest_i)));
				continue;
			}

			// One faction, all hostile to the player, barney included - he is an
			// ally by default and would otherwise never enter combat at all, and
			// his heavy-damage branch is one of the four triggers under test.
			m.is_player_ally = FALSE;
			m.ai_class       = CLASS_HUMAN_MILITARY;
			m.covertest_mark = 1;
			m.health         = CoverTest_HP(covertest_i);
			m.max_health     = 2000;
			m.covertest_hp   = m.health;

			// Handed the enemy up front, unlike the squadtest.  The callout is not
			// what is being measured here and making them find him first would
			// spend most of the twenty seconds on acquisition.
			m.ai_enemy = p;
			m.ai_state = MS_COMBAT;

			m.covertest_home = m.origin;
			m.covertest_seen = CoverTest_Visible(p, m);
			covertest_ent[covertest_i] = m;

			dprint(sprintf("[covertest] spawned %s at d=%g visible=%s\n",
			               m.classname, rint(vlen(m.origin - p.origin)),
			               m.covertest_seen ? "yes" : "no"));
		}
		covertest_stage  = 1;
		covertest_pulses = 0;
		covertest_next   = time + COVERTEST_GAP;
		return;
	}

	if (covertest_stage == 1)
	{
		// A round every half second, from the player, for twenty seconds.  25 is
		// over AI_HEAVY_DMG so it raises COND_HEAVY_DAMAGE as well as the light
		// bit, which is what makes barney's branch reachable in the same run as
		// the grunt's.
		//
		// HALF A SECOND, NOT TWO, and the reason is a measurement bug rather than
		// a preference.  COND_DAMAGE lives for a moment: it is raised when the
		// round lands and cleared by the next flinch, or by the selector itself
		// when the flinch cooldown is running.  Selection only happens at
		// schedule boundaries, so with a two-second gap whether cover is ever
		// CHOSEN comes down to the phase relationship between the pulses and
		// those boundaries - two consecutive runs on 2fort reported sched=28 and
		// sched=2 for that reason alone, which is not a measurement, it is a coin
		// toss with a number attached.
		//
		// It is also the more honest scenario.  Cover exists for a monster under
		// SUSTAINED fire; one round every two seconds is not what it is for.
		//
		// Fired from the PLAYER rather than a dummy inflictor, which is the one
		// place this harness differs from the deathtest on purpose: cover is about
		// getting away from the thing shooting at you, so the attacker has to be
		// the thing they are taking cover from.
		for (k = 0; k < COVERTEST_COUNT; k = k + 1)
		{
			e = covertest_ent[k];
			if (e && (e.flags & FL_MONSTER) && e.covertest_mark && e.health > 0)
			{
				W_ApplyDamage(p, e, CoverTest_Dmg(k));
				// Put the health back.  The damage has already done its work -
				// it raised the conditions and stamped the hitgroup - and the
				// number itself is a per-class trigger input that the harness
				// needs to hold still for twenty seconds.
				if (e.health > 0)
					e.health = e.covertest_hp;
			}
		}
		covertest_pulses = covertest_pulses + 1;
		if (covertest_pulses < COVERTEST_PULSES)
		{
			covertest_next = time + COVERTEST_GAP;
			return;
		}
		covertest_stage = 2;
		covertest_next  = time + 1;
		return;
	}

	dprint("[covertest] --- per subject ---\n");
	float exposed = 0, broke = 0;
	for (k = 0; k < COVERTEST_COUNT; k = k + 1)
	{
		e = covertest_ent[k];
		if (!e || !e.covertest_mark)
		{
			dprint(sprintf("[covertest] %s: never placed\n", CoverTest_Class(k)));
			continue;
		}
		float movedist = vlen(e.origin - e.covertest_home);
		float visnow   = CoverTest_Visible(p, e);
		if (e.covertest_seen)
		{
			exposed = exposed + 1;
			if (!visnow)
				broke = broke + 1;
		}
		dprint(sprintf("[covertest] %-22s moved=%g was-visible=%s now=%s sched=%s\n",
		               e.classname, rint(movedist),
		               e.covertest_seen ? "yes" : "no",
		               visnow ? "visible" : "HIDDEN",
		               Sched_Name(e.ai_sched)));
		// Where it was TRYING to go, and whether it had a route there.  A subject
		// that reports moved=0 with a goal 300 units away and no path is a
		// pathfinding failure; one with a goal 20 units away is a search picking
		// spots it is already standing on; one with a path and a distant goal is
		// a movement failure.  Three different bugs, identical moved=0.
		dprint(sprintf("[covertest]     goal=%g away, path=%s, stuck=%g, home=%v now=%v\n",
		               rint(vlen(e.ai_goalpos - e.origin)),
		               AI_HasPath(e) ? "yes" : "no",
		               e.ai_stuck, e.covertest_home, e.origin));
	}
	// THE HEADLINE, and the only line here that is about the feature rather than
	// about the machinery: of the subjects the player could see when the shooting
	// started, how many can he no longer see.  Everything else on this page can
	// be non-zero while that number is zero, and if it is, cover does not work.
	dprint(sprintf("[covertest] score: %g of %g started exposed, %g of those are now hidden\n",
	               exposed, COVERTEST_COUNT, broke));
	dprint(sprintf("[covertest] totals: asked=%g sched=%g floor=%g nodmg=%g\n",
	               ai_dbg_cover_asked, ai_dbg_cover_sched,
	               ai_dbg_cover_floor, ai_dbg_cover_nodmg));
	dprint(sprintf("[covertest] totals: sched=%g arrived=%g tries=%g lateral=%g node=%g\n",
	               ai_dbg_cover_sched, ai_dbg_cover_arrived, ai_dbg_cover_tries,
	               ai_dbg_cover_lateral, ai_dbg_cover_node));
	dprint(sprintf("[covertest] totals: none=%g refused=%g capped=%g noroute=%g spacing=%g cower=%g facing=%g\n",
	               ai_dbg_cover_none, ai_dbg_cover_refused, ai_dbg_cover_capped,
	               ai_dbg_cover_noroute, ai_dbg_cover_spacing, ai_dbg_cover_cower,
	               ai_dbg_cover_facing));

	cvar_set("sv_ai_covertest", "0");
	covertest_stage = 0;
	covertest_armed = FALSE;
};

// ---------------------------------------------------------------------------
// sv_ai_voicetest  —  does a .ai_snd_* family actually reach the mixer?
// ---------------------------------------------------------------------------
// Neither existing harness can answer this, and finding out why took longer than
// writing this one.  The firetest roster is the seven classes that SHOOT, and the
// walktest roster is two grunts; every one of the nine keeps a hand-written
// .ai_painsound function, so a whole firetest run reports voices played=0 whether
// the family path works or is dead code.  A harness that cannot fail is not a
// test.
//
// So: a roster of classes that have NOTHING BUT families, hurt on a timer.
//
//   monster_headcrab           valve, .ai_snd_pain - three files this class has
//                              had precached and unreachable since it was written
//   monster_alien_grunt        valve, a full set: idle/alert/pain/die
//   monster_alien_controller   valve, and the one whose ATTACK family was two
//                              filenames that have never existed
//   monster_bullchicken        valve, the SQUID_ATTN_IDLE case
//   monster_pitdrone           gearbox, and the model-guarded branch - on an
//                              install without Opposing Force this one must fall
//                              back to the bullsquid's voice rather than ask for
//                              a file it has not got
//
// They are hurt rather than shot: the pain family is the one every member of the
// roster has, damage is deterministic, and it needs no line of sight.  Two damage
// ticks a second for 12 seconds against a rate limit of one voice per second, so
// the expected count is bounded and a runaway is visible rather than plausible.
float voicetest_stage;
float voicetest_next;
float voicetest_hurt;
float voicetest_i;
float voicetest_base;		// ai_dbg_snd_voice when the run started

.float voicetest_mark;

const float VOICETEST_COUNT = 5;

string(float i) VoiceTest_Class =
{
	if (i == 0) return "monster_headcrab";
	if (i == 1) return "monster_alien_grunt";
	if (i == 2) return "monster_alien_controller";
	if (i == 3) return "monster_bullchicken";
	return "monster_pitdrone";
};

void() AI_VoiceTest =
{
	// One declaration for the whole function: fteqcc scopes locals per FUNCTION,
	// not per block, so a second `entity e` further down is a duplicate rather
	// than a shadow.
	entity vt_e;

	if (!cvar("sv_ai_voicetest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;

	// Keep the observer alive.  The roster is spawned at 220-460 units and then
	// repeatedly hurt, so it fights back; the first run of this harness lost its
	// player part-way through and the closing report never printed at all, because
	// every path here needs a live one.  The walktest keeps its player up for
	// exactly this reason.
	if (voicetest_stage >= 1)
		p.health = 1000;

	if (time < voicetest_next)
		return;

	if (voicetest_stage == 0)
	{
		// ai_dbg_snd_total, NOT ai_dbg_snd_voice: the periodic [ai] report zeroes
		// the interval counter every two seconds, so a delta taken against it would
		// measure whatever happened since the last print rather than since the run
		// began.  Reading a delta at all is what keeps the number attributable when
		// the map has monsters of its own.
		voicetest_base = ai_dbg_snd_total;

		for (voicetest_i = 0; voicetest_i < VOICETEST_COUNT; voicetest_i = voicetest_i + 1)
		{
			float vt_ok = FALSE;
			float vt_try;
			entity m = world;

			for (vt_try = 0; vt_try < 24 && !vt_ok; vt_try = vt_try + 1)
			{
				float vt_dist = 220;
				if (vt_try >= 8)  vt_dist = 320;
				if (vt_try >= 16) vt_dist = 460;

				makevectors('0 1 0' * (voicetest_i * 72 + (vt_try & 7) * 45));
				vector spot = p.origin + v_forward * vt_dist;

				entity oldself = self;
				m = spawn();
				m.classname = VoiceTest_Class(voicetest_i);
				setorigin(m, spot);
				self = m;
				Monster_Build(TRUE);
				self = oldself;

				if (m.flags & FL_MONSTER)
					vt_ok = TRUE;
				else
				{
					// Same trap the other two harnesses document: Monster_Build chains
					// the body even when AI_Spawn refuses the spot.
					Monster_Teardown(m);
					remove(m);
				}
			}

			if (!vt_ok)
			{
				dprint(sprintf("[voicetest] %-26s COULD NOT BE PLACED anywhere\n",
				               VoiceTest_Class(voicetest_i)));
				continue;
			}

			m.voicetest_mark = 1;
			m.health         = 100000;	// survive the whole run; this is not a gib test

			dprint(sprintf("[voicetest] spawned %-26s model=%-28s pain=[%s]\n",
			               m.classname, m.model,
			               (m.ai_snd_pain != "") ? m.ai_snd_pain : "<none>"));
		}
		voicetest_stage = 1;
		voicetest_hurt  = 0;
		voicetest_next  = time + 0.5;
		return;
	}

	if (voicetest_stage == 1)
	{
		// W_ApplyDamage(attacker, victim, amount) - the same entry the debug
		// ai_hurt command uses.  NOT AI_Damaged: that is the .on_damaged hook, a
		// void() acting on `self`, so calling it with arguments silently drops them
		// and skips the bookkeeping that stamps ai_nextpain.
		vt_e = monster_chain_head;
		while (vt_e)
		{
			if (vt_e.voicetest_mark && vt_e.health > 0)
				W_ApplyDamage(p, vt_e, 5);
			vt_e = vt_e.monster_chain_next;
		}
		voicetest_hurt = voicetest_hurt + 1;
		voicetest_next = time + 0.5;
		if (voicetest_hurt < 24)
			return;
		voicetest_stage = 2;
	}

	dprint("[voicetest] --- per class ---\n");
	vt_e = monster_chain_head;
	float found = 0;
	while (vt_e)
	{
		if (vt_e.voicetest_mark)
		{
			// nextpain is the rate limiter AI_Damaged stamps.  A class whose family
			// never fired leaves it at 0, which distinguishes "hurt but mute" from
			// "never hurt at all" - the two failures that look identical in a total.
			dprint(sprintf("[voicetest] %-26s hp=%-7g painstamp=%g families=%g\n",
			               vt_e.classname, vt_e.health, (vt_e.ai_nextpain > 0),
			               (vt_e.ai_snd_pain != "") + (vt_e.ai_snd_die != "")
			               + (vt_e.ai_snd_idle != "") + (vt_e.ai_snd_alert != "")));
			found = found + 1;
		}
		vt_e = vt_e.monster_chain_next;
	}
	if (found < VOICETEST_COUNT)
		dprint(sprintf("[voicetest] %g of %g test monsters gone\n",
		               VOICETEST_COUNT - found, VOICETEST_COUNT));
	dprint(sprintf("[voicetest] hurt ticks=%g  voices played this run=%g  registered=%g\n",
	               voicetest_hurt, ai_dbg_snd_total - voicetest_base, ai_sndreg_count));
	cvar_set("sv_ai_voicetest", "0");
	voicetest_stage = 0;
};

// combat.cpp:535-541 ShouldGibMonster.  Called on the KILLING blow, not on a
// corpse - the corpse path is W_DeadTakeDamage in sv_weapons.qc.
//
// The two ways in are HL's exactly:
//   health < -30                        overkill
//   the damage carried ALWAYSGIB        which FireBullets sets at per-pellet
//                                       damage > 16 (combat.cpp:1445), and which
//                                       is the rule behind "big guns gib"
float(entity m, float dmgbits, float lastdmg) Gib_ShouldGibOnDeath =
{
    if (!Gib_CanGib(m))
        return FALSE;
    if (m.health < GIB_HEALTH_VALUE)
        return TRUE;
    if (lastdmg > 16 && (dmgbits & DMG_BULLET))
        return TRUE;		// combat.cpp:1445, DMG_ALWAYSGIB
    if (dmgbits & (DMG_BLAST | DMG_SONIC))
        return TRUE;		// barnacle bite / houndeye / egon wide are ALWAYSGIB
    return FALSE;
};
