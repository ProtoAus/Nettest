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

// Marks the monsters this test spawned, so the report can ignore the map's own.
.float firetest_mark;

// The roster is every shooter that has been CAUGHT not firing, kept rather than
// pruned once each is fixed: the whole point of the test is that a regression
// here is silent in play (a monster that runs at you and does nothing reads as
// bad pathing, not as a broken gun) and loud in this number.
const float FIRETEST_COUNT = 7;

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
	return "monster_alien_slave";
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
