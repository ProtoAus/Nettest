// server/monsters/mon_bosses.qc
// ----------------------------------------------------------------------------
// W7, part one: monster_bigmomma (26) and the two air vehicles,
// monster_apache and monster_osprey.
//
// models/big_mom.mdl (20 sequences), read out of the file:
//   act  1  idle1 / idle2      code 5 SACK slosh
//   act  3  walk 49f @35: codes 1,2,3,4 - the four footfalls
//   act  4  run  23f @28: same four plus a sack
//   act 30  claw x3 variants:
//             [5] 41f: code 16 @0.43 (attack sound), 10 @0.57 (MELEE_ATTACK1), 5
//             [6] 20f: code 16, 14 (SCREAM), 8  (MELEE_ATTACKBR)
//             [7] 23f: code 9 (MELEE_ATTACKBL), 14
//   act 31  spawn 31f @20: code 12 @0.40 LAY_CRAB, 17 BIRTH_SOUND, 16
//   act 28  mortar 17f @20: code 11 @0.50 MORTAR_ATTACK, 16
//   act 36  death, code 6 DEATHSOUND
//   act 26  flinch, code 15 PAIN_SOUND
// bigmomma.cpp: 1-4 footsteps, 5 sack, 6 death, 8/9/10 melee, 11 mortar,
// 12 lay crab, 13 jump, 14 scream, 15 pain, 16 attack sound, 17 birth.
//
// SHE LAYS HEADCRABS.  Event 12 on the spawn sequence is HL's LAY_CRAB, and it
// is the whole reason this fight works the way it does - the boss is a spawner,
// not just a big melee monster.  That is implemented here because the headcrab
// class already exists and Monster_Build is reachable; it would have been the
// first thing to cut and the first thing anyone noticed missing.
//
// THE AIR VEHICLES HAVE ONE SEQUENCE EACH.  apache.mdl is a 7-frame "idle" rotor
// loop and osprey.mdl an 11-frame "rotor" loop - no activities, no events, no
// attacks, no deaths.  Everything they do has to come from QC, which is exactly
// what the plan predicted, and it means the animation layer has nothing to
// contribute: AI_SetActivity would resolve every activity to sequence 0 anyway.
// They are AIMODE_FLY hitscan platforms that hold altitude and shoot.
// ----------------------------------------------------------------------------

const float BM_AE_STEP1       = 1;	// left            (bigmomma.cpp:516-524)
const float BM_AE_STEP2       = 2;	// right
const float BM_AE_STEP3       = 3;	// back left
const float BM_AE_STEP4       = 4;	// back right
const float BM_AE_SACK        = 5;
const float BM_AE_DEATHSOUND  = 6;
const float BM_AE_MELEE_BR    = 8;
const float BM_AE_MELEE_BL    = 9;
const float BM_AE_MELEE1      = 10;
const float BM_AE_MORTAR      = 11;
const float BM_AE_LAY_CRAB    = 12;
const float BM_AE_JUMP        = 13;	// leap forward, off the ground
const float BM_AE_SCREAM      = 14;
const float BM_AE_PAIN        = 15;
const float BM_AE_ATTACK_SND  = 16;
const float BM_AE_BIRTH       = 17;
// The one event with a code outside the 1..17 block, and the only one that is
// not about sound or damage: it fires the CURRENT NODE's reachtarget partway
// through a sequence instead of at the end of it (bigmomma.cpp:543-550).  It
// exists because `breakwall` is a four-second animation whose whole point is the
// wall coming down as she hits it, not four seconds later.
const float BM_AE_EARLY_TARGET = 50;

// The gonarch's seven families, from bigmomma.cpp:328-378.  Three defects the
// audit turned up here, all of them from writing names out of memory rather than
// out of the mount:
//
//   gonarch/gon_pain3.wav DOES NOT EXIST.  It was precached (a failing slot on
//   every map that carries her) and it was one of the two arms of a coin flip, so
//   half of all gonarch pain events were silent.  Valve's own family is 2/4/5 -
//   there is no gon_pain1 or gon_pain3 in valve, gearbox or svencoop.
//
//   gon_die2 and gon_die3 do not exist either.  pDeathSounds is one entry.
//
//   Event 14 SCREAM played the ATTACK family.  It is the alert (bigmomma.cpp:492),
//   and gon_alert1-3 were neither precached nor reachable.
//
// Still unreached and deliberately so: pChildDieSounds, which HL plays when one of
// her laid crabs dies.  The sq_maker link that would carry it already exists; the
// hook does not, and inventing one is a behaviour change rather than a fix.
const string SND_GON_ATTACK   = "gonarch/gon_attack1.wav gonarch/gon_attack2.wav gonarch/gon_attack3.wav";
const string SND_GON_ALERT    = "gonarch/gon_alert1.wav gonarch/gon_alert2.wav gonarch/gon_alert3.wav";
const string SND_GON_PAIN     = "gonarch/gon_pain2.wav gonarch/gon_pain4.wav gonarch/gon_pain5.wav";
const string SND_GON_DIE      = "gonarch/gon_die1.wav";
const string SND_GON_BIRTH    = "gonarch/gon_birth1.wav gonarch/gon_birth2.wav gonarch/gon_birth3.wav";
const string SND_GON_SACK     = "gonarch/gon_sack1.wav gonarch/gon_sack2.wav gonarch/gon_sack3.wav";
const string SND_GON_STEP     = "gonarch/gon_step1.wav gonarch/gon_step2.wav gonarch/gon_step3.wav";

// The apache's chin gun.  It was firing apache/ap_whine1.wav - the ENGINE WHINE,
// a 75 KB turbine loop - once per burst.  HL fires turret/tu_fire1.wav at
// attenuation 0.3 (apache.cpp:834), which carries 3333 units: you are meant to
// hear a gunship shooting at someone else across a map.
const string SND_APACHE_GUN   = "turret/tu_fire1.wav";
const string SND_APACHE_ROTOR = "apache/ap_rotor2.wav";
const string SND_OSPREY_ROTOR = "apache/ap_rotor4.wav";	// osprey.cpp:450, atten 0.15

void() Bosses_Precache =
{
	precache_model("models/big_mom.mdl");
	precache_model("models/apache.mdl");
	precache_model("models/osprey.mdl");

	AI_SndPrecache(SND_GON_ATTACK);
	AI_SndPrecache(SND_GON_ALERT);
	AI_SndPrecache(SND_GON_PAIN);
	AI_SndPrecache(SND_GON_DIE);
	AI_SndPrecache(SND_GON_BIRTH);
	AI_SndPrecache(SND_GON_SACK);
	AI_SndPrecache(SND_GON_STEP);
	precache_sound("weapons/mortarhit.wav");

	AI_SndPrecache(SND_APACHE_GUN);
	// Literal precache_sound for the two rotors, not AI_SndPrecache: fteqcc's F210
	// "used but not directly precached" check only sees literal calls, and these
	// two are played by a direct sound() rather than through a family.  Keeping the
	// static check where it still works costs one line each.
	precache_sound("apache/ap_rotor2.wav");
	precache_sound("apache/ap_rotor4.wav");
	// The crabs she lays are ordinary monster_headcrabs, already precached by
	// the headcrab class - nothing extra is needed here.
};

// ---------------------------------------------------------------------------
// bigmomma
// ---------------------------------------------------------------------------
.float ai_crabtime;		// earliest time she may birth again

void() BigMomma_LayCrab =
{
	// One headcrab, dropped just behind her.  Monster_Build is the single
	// construction path, so the child gets a brain, a hull and a chain entry the
	// same way a map-placed crab does - no special case anywhere.
	//
	// Monster_Spawn is deliberately NOT used even though it exists for exactly
	// this shape: it copies the maker's health onto the child, and hers is 1000.
	// Every crab she laid would have arrived with a boss's hit points.
	makevectors('0 1 0' * self.angles_y);
	vector org = self.origin - v_forward * 48 + '0 0 16';

	// Refuse to birth into solid rather than dropping a crab inside the geometry
	// behind her.  She is enormous, so "behind" is frequently a wall.  The hull
	// comes from Monster_ClassHull rather than being written out here, so this
	// cannot drift from the hull the crab is actually built with.
	Monster_ClassHull("monster_headcrab");
	tracebox(self.origin + '0 0 16', monster_hull_min, monster_hull_max,
	         org, MOVE_NOMONSTERS, self);
	if (trace_startsolid || trace_allsolid)
		return;
	org = trace_endpos;

	entity oldself = self;
	entity c = spawn();
	c.classname = "monster_headcrab";
	setorigin(c, org);
	self = c;
	Monster_Build(TRUE);
	self = oldself;

	// Book the child against her own live-children count, using the squadmaker
	// latch rather than a private counter.  Monster_Teardown already releases the
	// slot from both the death handler and remove(), idempotently, and the squad
	// self-test already asserts that accounting - so the cap below cannot drift,
	// and a gonarch whose crabs are all killed can birth a fresh brood.
	//
	// Set AFTER Monster_Build so nothing inside construction can clobber it.
	c.sq_maker            = self;
	c.sq_counted          = 1;
	self.sq_live_children = self.sq_live_children + 1;

	// Reported separately from the schedule histogram on purpose: a laycrab
	// SELECTION only means the animation started.  The crab appears on an event
	// 0.4 of the way in, so selections and births are different numbers, and the
	// gap between them is precisely where this behaviour was broken before.
	if (cvar("sv_ai_debug"))
		dprint(sprintf("[ai] bigmomma birthed a headcrab (live=%g)\n",
		               self.sq_live_children));

	// CHAN_BODY, not CHAN_VOICE: HL keeps the birth grunt off her voice channel so
	// it can overlap the scream that usually precedes it (bigmomma.cpp:504).
	AI_SndPlay(self, CHAN_BODY, SND_GON_BIRTH);
};

// ---------------------------------------------------------------------------
// the node walk  (bigmomma.cpp CInfoBM / CBigMomma::NodeStart, NodeReach)
// ---------------------------------------------------------------------------
// hl_c15 IS this chain.  22 info_bigmomma nodes named goose1..goose14 and `end`,
// and every beat of the level hangs off her reaching one of them: the wall she
// smashes at goose4 (reachsequence breakwall, reachtarget web1), the ceiling
// collapse at goose5c, the two leaps at goose8b and goose10, and the pair of
// falltodeath managers that finish the map.  Nine of the nodes carry a `health`
// key, which is what turns the level into stages rather than a single fight.
//
// Without info_bigmomma all 22 of those were inert relays: the gonarch spawned,
// stood on her spawn point, and could be killed at her map health of 300 with no
// stage gate and no scripted beats at all.  The monster was never the missing
// half - the map's instructions to it were.
//
// The chain is seeded from the MONSTER's own `netname` key ("goose1" on hl_c15),
// which is Half-Life's way of saying "start here": CBigMomma keeps the name of
// the node it is heading for in pev->netname and overwrites it as it walks.  We
// keep it in .ai_bm_next instead, because .netname on a monster already means
// squad name everywhere else in this tree (sv_monsters.qc:1104).

// The per-stage health multiplier, HL's gSkillData.bigmommaHealthFactor.  Sven's
// shipped skill.cfg sets sk_bigmomma_health_factor to 1, so 1 is the default
// here and the cvar exists to let a server make the stages longer or shorter
// without touching the map.
float() BigMomma_HealthFactor =
{
	float f = cvar("sv_ai_bigmomma_healthfactor");
	return (f > 0) ? f : 1;
};

// HL returns 1e6 when there is NO node - "no limit", so a gonarch that has lost
// her node does not conclude she has arrived at it.  A node that merely carries
// no `radius` key gives 0, which is HL's behaviour too (pev->scale is simply
// left at zero) and is exactly why the arrival test needs its second arm:
// hl_c15's goose5b has no radius at all.
float(entity m) BigMomma_NodeRange =
{
	if (!m.ai_bm_node)
		return 1000000;
	return m.ai_bm_node.radius;
};

float(entity m) BigMomma_NodeDelay =
	{ return m.ai_bm_node ? m.ai_bm_node.reachdelay : 0; };
float(entity m) BigMomma_NodeWaits =
	{ return m.ai_bm_node ? (m.ai_bm_node.spawnflags & SF_INFOBM_WAIT) : 0; };
float(entity m) BigMomma_NodeRuns =
	{ return m.ai_bm_node ? (m.ai_bm_node.spawnflags & SF_INFOBM_RUN) : 0; };

// A node with angles 0 keeps her CURRENT facing rather than snapping her to due
// east (bigmomma.cpp:240-249).  Six of hl_c15's nodes set a yaw and the rest
// leave it, so the fallback is the common path, not the exception.
float(entity m) BigMomma_NodeYaw =
{
	if (m.ai_bm_node && m.ai_bm_node.angles_y != 0)
		return m.ai_bm_node.angles_y;
	return m.angles_y;
};

// Start the node's presequence (pre = TRUE) or its reachsequence.  Returns TRUE
// only if a sequence is actually now playing, so the caller can complete the
// task immediately for the far commoner "this node names nothing" case.
//
// Every name hl_c15 asks for was checked against the shipped big_mom.mdl rather
// than assumed - angry1, angry2, angry3, breakwall, claw and jump are all
// present in its 20 labels.  The dprint below is for the map that asks for one
// that is not; it degrades to "no pause here" rather than stalling the chain.
float(entity m, float pre) BigMomma_NodeSeq =
{
	if (!m.ai_bm_node)
		return FALSE;

	string nm = pre ? m.ai_bm_node.presequence : m.ai_bm_node.reachsequence;
	if (nm == "" || !nm)
		return FALSE;

	// Force the restart for the reason Script_StartPlay does: AI_SetSequenceNamed
	// is idempotent on the NAME, so two adjacent nodes naming the same sequence
	// would leave the second task parked on a sequence that had already ended.
	AI_ResetActivity(m);
	if (!AI_SetSequenceNamed(m, nm, FALSE))
	{
		dprint(sprintf("[bigmomma] node \"%s\": big_mom.mdl has no sequence \"%s\"\n",
		               m.ai_bm_node.targetname, nm));
		return FALSE;
	}
	if (ai_cached_debug)
		dprint(sprintf("[bigmomma] node \"%s\": playing %s \"%s\"\n",
		               m.ai_bm_node.targetname, pre ? "presequence" : "reachsequence", nm));
	return TRUE;
};

// bigmomma.cpp:713-736.  Resolve .ai_bm_next into the node entity, or declare the
// path finished - which is the flag that makes her killable again, so it is the
// single most consequential line in the file.
void(entity m) BigMomma_NodeStart =
{
	entity n = world;

	// The empty-name guard is not defensive tidying: find(world, targetname, "")
	// matches every entity whose targetname is unset, so the LAST node of any
	// chain - which is exactly the one whose target is empty - would otherwise
	// resolve to some arbitrary unnamed entity and she would set off across the
	// map towards it instead of finishing.
	if (m.ai_bm_next != "" && m.ai_bm_next)
		n = find(world, targetname, m.ai_bm_next);

	if (!n)
	{
		if (ai_cached_debug)
			dprint(sprintf("[bigmomma] path finished at \"%s\"\n",
			               m.ai_bm_node ? m.ai_bm_node.targetname : "<none>"));
		m.ai_bm_mem = m.ai_bm_mem | BMMEM_FINISHED;
		return;
	}

	// HL matches on targetname alone and does not check the classname, and that
	// is kept: a mapper pointing the chain at a path_corner or an info_target is
	// doing something unusual but not something to refuse - the node keys are
	// simply all zero and it degrades to "walk there and carry on".  The
	// classname is in the debug line so the unusual case is visible.
	m.ai_bm_node = n;
	if (ai_cached_debug)
		dprint(sprintf("[bigmomma] heading for \"%s\" (%s) at %v, radius %g%s\n",
		               n.targetname, n.classname, n.origin, n.radius,
		               (n.spawnflags & SF_INFOBM_RUN) ? ", running" : ""));
};

// bigmomma.cpp:739-761.  Arrival: take the stage's health, fire the map, and
// decide whether to move straight on or stand here until shot.
void(entity m) BigMomma_NodeReach =
{
	entity n = m.ai_bm_node;

	m.ai_bm_mem = m.ai_bm_mem - (m.ai_bm_mem & BMMEM_ADVANCE);
	if (!n)
		return;

	if (n.health)
	{
		m.max_health = n.health * BigMomma_HealthFactor();
		m.health     = m.max_health;
		// RESEAT THE DAMAGE BASELINE.  AI_Damaged sizes every hit from
		// (ai_lasthealth - health) because W_ApplyDamage does not pass the amount
		// - so raising her health without this makes the next hit compute as
		// NEGATIVE, clamp to zero, and count as "healed, not a hit": no pain
		// sound, no COND_DAMAGE, no provoke, for one shot after every single
		// stage change.  Nine stages on hl_c15, nine silent hits.
		m.ai_lasthealth = m.health;
	}

	// The reachtarget, unless the sequence already fired it early through
	// BM_AE_EARLY_TARGET.  The bit is cleared here whether or not it was set,
	// exactly as HL's Forget is, so it cannot leak into the next node.
	if (!(m.ai_bm_mem & BMMEM_FIRED))
		if (n.reachtarget != "" && n.reachtarget)
		{
			float fired = SV_FireTargetsByName(n.reachtarget, m, USE_TOGGLE);
			if (ai_cached_debug)
				dprint(sprintf("[bigmomma] node \"%s\": fired \"%s\" -> %g entity(s)\n",
				               n.targetname, n.reachtarget, fired));
		}
	m.ai_bm_mem = m.ai_bm_mem - (m.ai_bm_mem & BMMEM_FIRED);

	m.ai_bm_next = n.target;

	// A node with no health is a waypoint: reach it and keep walking.  A node
	// WITH health is a stage - she stops here, the schedule ends, and she goes
	// back to being an ordinary monster until the player has taken that health
	// off her, at which point the damage filter sets the advance bit again.
	if (n.health == 0)
		m.ai_bm_mem = m.ai_bm_mem | BMMEM_ADVANCE;
	else if (ai_cached_debug)
		dprint(sprintf("[bigmomma] node \"%s\": holding at %g health\n",
		               n.targetname, m.health));
};

// bigmomma.cpp:898-906, plus one test HL does not make.
float(entity m) BigMomma_ShouldGoToNode =
{
	if (!(m.ai_bm_mem & BMMEM_ADVANCE))
		return FALSE;
	// THE FINISHED TEST IS OURS.  Half-Life has none, and the consequence there
	// is a loop: the last node's target is empty, so NodeStart declares the path
	// finished but leaves m_hTargetEnt pointing at that same last node, whose
	// NodeReach then sets the advance bit all over again.  HL gets away with it
	// because on hl_c15 the final node's reachtarget ends the map a moment later.
	// We cannot: this schedule outranks the combat ladder, so the loop would mean
	// a gonarch who has finished her path stands at the last node re-facing it
	// forever instead of fighting - which is precisely the phase where the player
	// is finally allowed to kill her.
	if (m.ai_bm_mem & BMMEM_FINISHED)
		return FALSE;
	return (time >= m.ai_bm_nodetime);
};

// bigmomma.cpp:582-600, and it is the reason the fight has stages at all.
//
// While the path is unfinished she CANNOT die: a blow that would kill her is cut
// down to leave 1 health, and the node is marked complete instead.  Half-Life
// also zeroes DMG_ACID here so her own mortar cannot hurt her; that half is
// deliberately not transcribed, because this tree has no DMG_ACID bit and
// nothing that would set one - her mortar is AI_BlastAttack centred on the enemy
// (see BigMomma_Event) and so cannot reach her anyway.  Adding a damage type
// that nothing ever sets would be a constant pretending to be a behaviour.
float(entity m, float damage, float dmgbits) BigMomma_DamageFilter =
{
	if (m.ai_bm_mem & BMMEM_FINISHED)
		return damage;			// the path is done: she is mortal now
	if (damage < m.health)
		return damage;			// survivable anyway, nothing to do
	if (m.health <= 1)
		return 0;			// already floored; do not go negative

	m.ai_bm_mem = m.ai_bm_mem | BMMEM_ADVANCE | BMMEM_COMPLETED;
	if (ai_cached_debug)
		dprint(sprintf("[bigmomma] stage health spent at \"%s\": advancing\n",
		               m.ai_bm_node ? m.ai_bm_node.targetname : "<none>"));
	return m.health - 1;			// HL's health = damage + 1, same landing
};

// The whole reason SCHED_BIGMOMMA_LAYCRAB exists.  Her spawn sequence is tagged
// ACT_MELEE_ATTACK2, and the generic ladder selects ACT_MELEE_ATTACK1 or
// ACT_RANGE_ATTACK1 and nothing else - so without this virtual the event was
// wired to a sequence that never played.
float() BigMomma_SelectSched =
{
	// THE NODE WALK OUTRANKS EVERYTHING ELSE SHE COULD DO, including having an
	// enemy, and it has to sit above the `!ai_enemy` early-out below or the chain
	// would only ever advance while she had nobody to fight.  Half-Life puts it
	// above the entire combat ladder for the same reason (bigmomma.cpp:910-917):
	// she is a boss you chase, and hl_c15 cannot progress unless she keeps
	// walking while the player is shooting at her.
	if (BigMomma_ShouldGoToNode(self))
		return SCHED_BIGMOMMA_NODE;

	if (!self.ai_enemy)
		return SCHED_NONE;
	if (self.ai_state != MS_COMBAT)
		return SCHED_NONE;
	if (time < self.ai_crabtime)
		return SCHED_NONE;

	float cap = cvar("sv_ai_bigmomma_maxcrabs");
	if (cap <= 0)
		cap = 10;
	if (self.sq_live_children >= cap)
		return SCHED_NONE;

	// Stamped HERE, at selection, not in the event handler.  The event fires 0.4
	// of the way into the sequence; if the gap were stamped there, every tick
	// before it would re-select this schedule and restart the animation from the
	// top, so the birth frame would never be reached at all.  That is the same
	// restart-before-you-arrive failure the chase schedule had in B2.
	float gap = cvar("sv_ai_bigmomma_crabgap");
	if (gap <= 0)
		gap = 8;
	self.ai_crabtime = time + gap;

	return SCHED_BIGMOMMA_LAYCRAB;
};

void() BigMomma_Event =
{
	if (ai_event_code == BM_AE_MELEE1 || ai_event_code == BM_AE_MELEE_BR
	 || ai_event_code == BM_AE_MELEE_BL)
	{
		float d = cvar("sv_ai_bigmomma_dmg");
		if (d <= 0)
			d = 50;
		AI_MeleeHull(self, self.ai_melee_range, d, 32);
		return;
	}

	if (ai_event_code == BM_AE_MORTAR)
	{
		// The mortar, half a second into a short sequence.  HL lobs a real
		// projectile; this uses the blast primitive centred on the ENEMY rather
		// than on her, which is the same threat without a new projectile type -
		// and unlike a lob it cannot be dodged by the arc being wrong.
		if (self.ai_enemy)
		{
			float md = cvar("sv_ai_bigmomma_mortar_dmg");
			if (md <= 0)
				md = 40;
			vector saved = self.origin;
			// AI_BlastAttack centres on the attacker, so borrow her origin for
			// the call.  setorigin is deliberately NOT used: this is one function
			// call with no traces in between that could observe the move.
			self.origin = self.ai_enemy.origin;
			AI_BlastAttack(self, 200, md, md * 0.25);
			self.origin = saved;

			AI_Sound(self, CHAN_WEAPON, "weapons/mortarhit.wav", 1, ATTN_NORM);
		}
		self.ai_nextattack = time + 5.0;
		return;
	}

	if (ai_event_code == BM_AE_LAY_CRAB)
	{
		BigMomma_LayCrab();
		return;
	}

	// The leap (bigmomma.cpp:534-541).  Two of hl_c15's nodes name `jump` as
	// their reachsequence - goose8b and goose10 - and both of them are her
	// crossing a gap she cannot walk around, so without this she plays a leap
	// animation on the spot and the chain then asks her to walk to a node on the
	// far side of a hole.
	//
	// YAW ONLY, where HL uses the full angle set.  UTIL_MakeVectors(pev->angles)
	// there is safe because a Half-Life monster's pitch is always zero; ours can
	// carry one on a slope, and a pitched v_forward turns a forward leap into a
	// dive at the floor.  The horizontal and vertical components are HL's own
	// 200 and 500.
	if (ai_event_code == BM_AE_JUMP)
	{
		// Off the ground first, and one unit up with it: the engine re-seats
		// FL_ONGROUND for anything resting exactly on a surface, so clearing the
		// flag without the nudge has the launch cancelled on the same frame.
		self.flags = self.flags - (self.flags & FL_ONGROUND);
		setorigin(self, self.origin + '0 0 1');
		makevectors('0 1 0' * self.angles_y);
		self.velocity = v_forward * 200 + '0 0 500';
		return;
	}

	// Fire the node's reachtarget NOW rather than when the sequence ends
	// (bigmomma.cpp:543-550).  `breakwall` is the case it exists for: the wall is
	// a func_breakable fired by the node, and it has to come down as she hits it.
	// The bit is what stops NodeReach firing the same target a second time.
	if (ai_event_code == BM_AE_EARLY_TARGET)
	{
		entity n = self.ai_bm_node;
		if (n && n.reachtarget != "" && n.reachtarget)
		{
			float fired = SV_FireTargetsByName(n.reachtarget, self, USE_TOGGLE);
			if (ai_cached_debug)
				dprint(sprintf("[bigmomma] node \"%s\": EARLY fire \"%s\" -> %g entity(s)\n",
				               n.targetname, n.reachtarget, fired));
		}
		self.ai_bm_mem = self.ai_bm_mem | BMMEM_FIRED;
		return;
	}

	// 16 is the attack sound, on CHAN_WEAPON; 14 is the SCREAM, which is her ALERT
	// family on CHAN_VOICE (bigmomma.cpp:491-501).  These were one branch playing
	// one family, so gon_alert1-3 were unreachable and the scream sounded like a
	// second swing.
	if (ai_event_code == BM_AE_ATTACK_SND)
	{
		AI_SndPlay(self, CHAN_WEAPON, SND_GON_ATTACK);
		return;
	}
	if (ai_event_code == BM_AE_SCREAM)
	{
		AI_SndPlay(self, CHAN_VOICE, SND_GON_ALERT);
		return;
	}

	if (ai_event_code == BM_AE_SACK)
	{
		// 30 %, not every time.  The sack event sits on her idle AND her run cycle,
		// so at 100 % she sloshes continuously while walking (bigmomma.cpp:507-510).
		if (random() < 0.3)
			AI_SndPlay(self, CHAN_BODY, SND_GON_SACK);
		return;
	}

	// The four footfalls.  Left/back-left go out on CHAN_ITEM and right/back-right
	// on CHAN_BODY, which is how HL gets two steps to overlap instead of cutting
	// each other off (bigmomma.cpp:516-524).  These were unhandled: she is the
	// largest thing in the game and she walked in silence.
	if (ai_event_code == BM_AE_STEP1 || ai_event_code == BM_AE_STEP3)
	{
		AI_SndPlay(self, CHAN_ITEM, SND_GON_STEP);
		return;
	}
	if (ai_event_code == BM_AE_STEP2 || ai_event_code == BM_AE_STEP4)
	{
		AI_SndPlay(self, CHAN_BODY, SND_GON_STEP);
		return;
	}
	// PAIN (15) and DEATHSOUND (6) arrive through the .ai_snd_pain / .ai_snd_die
	// families instead, so they are rate-limited and cannot double up with the
	// damage path's own call.
};


// Per-activity turn rate, bigmomma.cpp:416-428.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) BigMomma_YawSpeed =
{
	if (act == ACT_IDLE)	return 100;
	return 90;
};

void(entity m) BigMomma_ClassInit =
{
	m.ai_yawspeed    = BigMomma_YawSpeed;
	m.ai_class       = CLASS_ALIEN_MONSTER;
	m.ai_melee_range = 120;			// she is enormous
	m.ai_range_range = 1024;		// the mortar
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   big_mom.mdl [2] walk 49f @35fps -> 130.1
	//   big_mom.mdl [3] run  23f @28fps -> 399.7
	m.ai_speed_walk  = 130;
	m.ai_speed_run   = 400;
	m.ai_yaw_speed   = 90;
	m.ai_dmg_scale   = 1;
	m.ai_event       = BigMomma_Event;
	m.ai_snd_pain    = SND_GON_PAIN;
	m.ai_snd_die     = SND_GON_DIE;
	m.ai_snd_alert   = SND_GON_ALERT;
	m.ai_selectsched = BigMomma_SelectSched;
	m.ai_damagefilter = BigMomma_DamageFilter;
	// First brood comes shortly after she engages, not on the opening tick: an
	// instant birth on sighting reads as a spawn glitch rather than a boss move.
	m.ai_crabtime    = time + 4;
	if (m.bloodcolor == 0)
		m.bloodcolor = 195;

	// Seed the node chain from the map's own key.  HL's CBigMomma::Activate does
	// the equivalent by setting bits_MEMORY_ADVANCE_NODE ("start 'er up",
	// bigmomma.cpp:707-711) against a pev->netname the engine already parsed.
	//
	// .netname is read here rather than .ai_bm_next because that IS the map's
	// spelling - hl_c15 puts "goose1" on the gonarch herself.  Monster_Build has
	// already copied it into .squadname by the time this runs, which is why that
	// translation now excludes this class (sv_monsters.qc:1104): a squad named
	// after a patrol node is meaningless, and leaving it would have made her a
	// one-member squad called goose1.
	//
	// A gonarch with no netname simply never enters the node schedule and behaves
	// exactly as she did before this existed - which is the correct outcome for
	// the 25 placements outside hl_c15, none of which authors a chain.
	m.ai_bm_next   = m.netname;
	m.ai_bm_node   = world;
	m.ai_bm_mem    = 0;
	m.ai_bm_nodetime = 0;
	if (m.ai_bm_next != "" && m.ai_bm_next)
		m.ai_bm_mem = BMMEM_ADVANCE;
	else
		m.ai_bm_mem = BMMEM_FINISHED;	// no chain: killable from the start
};

// ---------------------------------------------------------------------------
// apache / osprey
// ---------------------------------------------------------------------------
// One sequence each, so there is no animation to drive and no event to hang an
// attack on: the firing runs from the per-tick hook, the same mechanism the
// barnacle and the kingpin needed for the same reason.
void() Apache_Tick =
{
	if (!self.ai_enemy)
		return;
	if (time < self.ai_nextattack)
		return;
	if (vlen(self.ai_enemy.origin - self.origin) > self.ai_range_range)
		return;

	// A short burst rather than one round: a helicopter chin gun reads as
	// sustained fire, and AI_FireBullets already does the per-round spread roll.
	float d = cvar("sv_ai_apache_dmg");
	if (d <= 0)
		d = 10;
	AI_FireBullets(self, self.ai_enemy, 3, 0.08716, d);
	self.ai_nextattack = time + 1.0;

	// Attenuation 0.3, not ATTN_NORM: a gunship firing is a map-wide event in
	// Half-Life and 0.3 carries it 3333 units (apache.cpp:834).  Emitted directly
	// rather than through .ai_snd_atten because that field belongs to the voice
	// families, and this machine has none.
	if (!self.gag)
		AI_Sound(self, CHAN_WEAPON, SND_APACHE_GUN, 1, 0.3);
};

void(entity m) Apache_ClassInit =
{
	m.ai_class    = CLASS_HUMAN_MILITARY;
	m.ai_movemode = AIMODE_FLY;
	m.ai_flyheight = 320;			// it stays well up, out of easy reach

	m.ai_melee_range = 0;
	m.ai_range_range = 2048;
	m.ai_speed_walk  = 120;
	m.ai_speed_run   = 320;
	m.ai_yaw_speed   = 90;
	m.ai_dmg_scale   = 1;
	m.ai_tick        = Apache_Tick;
	m.bloodcolor     = -1;			// a machine

	// The rotor.  ap_rotor2.wav carries a `cue ` chunk, so it is a genuine loop
	// point rather than a one-shot, and FORCELOOP|FOLLOW makes it behave the way
	// HL's CHAN_STATIC emit at pitch 110 does (apache.cpp:708).  It was precached
	// and never played: an apache was completely silent until it opened fire.
	//
	// DATA ONLY here.  AI_Spawn starts it once placement has SUCCEEDED and AI_Died
	// stops it; nothing else can, because a forced loop runs until something
	// replaces it on this entity channel.
	m.ai_snd_loop      = SND_APACHE_ROTOR;
	m.ai_snd_loopchan  = CHAN_BODY;
	m.ai_snd_loopatten = 0.3;
};

// The osprey is a troop transport, not a gunship: in HL it drops grunts and does
// not shoot.  It flies and it can be destroyed, and that is deliberately all -
// the drop behaviour belongs with scripted_sequence (W8), which is what actually
// drives it on the maps that use it.
void(entity m) Osprey_ClassInit =
{
	m.ai_class    = CLASS_HUMAN_MILITARY;
	m.ai_movemode = AIMODE_FLY;
	m.ai_flyheight = 400;

	m.ai_melee_range = 0;
	m.ai_range_range = 0;			// unarmed
	m.ai_speed_walk  = 100;
	m.ai_speed_run   = 260;
	m.ai_yaw_speed   = 60;
	m.ai_dmg_scale   = 1;
	m.bloodcolor     = -1;

	// Its own rotor, a different sample and much quieter falloff than the apache's:
	// 0.15 reaches 6666 units, because an osprey is meant to be heard arriving from
	// the far side of a map (osprey.cpp:450).
	m.ai_snd_loop      = SND_OSPREY_ROTOR;
	m.ai_snd_loopchan  = CHAN_BODY;
	m.ai_snd_loopatten = 0.15;
};

float() BigMomma_DefaultHealth
	= { float h = cvar("sv_ai_bigmomma_health"); return (h > 0) ? h : 1000; };
float() Apache_DefaultHealth
	= { float h = cvar("sv_ai_apache_health");   return (h > 0) ? h : 250; };
float() Osprey_DefaultHealth
	= { float h = cvar("sv_ai_osprey_health");   return (h > 0) ? h : 400; };

// ---------------------------------------------------------------------------
// sv_bigmomma_selftest  —  is the patrol chain actually walkable?
// ---------------------------------------------------------------------------
// The node walk cannot be driven headlessly.  It needs the gonarch to physically
// cross hl_c15 — twenty-two legs, several of them through doors a script opens
// and two of them across gaps that need the leap event — and the harness has no
// player to fight her, no way to spend the nine stage-health gates, and no
// patience for the several minutes the walk would take even if it did.
//
// What CAN be checked without any of that is the thing most likely to be wrong:
// whether the chain the map authored actually resolves.  A broken link is
// completely silent at runtime — she simply declares the path finished early,
// which looks exactly like her having finished it properly — and it takes the
// rest of the map with it, because every downstream beat is fired by a node.
//
// So this validates the DATA and says so, rather than pretending to test the
// behaviour.  Same idiom and same one-shot cvar as sv_tank_selftest.
float bigmomma_selftest_done;

void() BigMomma_SelfTest =
{
	entity mom, n, e;
	float  bad, count, walked, orphan, guard;
	string want;

	if (bigmomma_selftest_done || !cvar("sv_bigmomma_selftest"))
		return;
	// Three seconds in, for the reason the tank test waits: every entity has
	// spawned and every targetname is linked, so an unresolved one is real.
	if (time < 3)
		return;

	bigmomma_selftest_done = 1;
	cvar_set("sv_bigmomma_selftest", "0");

	bad = 0;
	count = 0;

	// -----------------------------------------------------------------------
	// stage 1: the health gate, on a stand-in rather than on the real boss
	// -----------------------------------------------------------------------
	// The gate is the one piece of this behaviour that can silently invert: get
	// it wrong in one direction and the gonarch is immortal for the whole map,
	// get it wrong in the other and she dies on the first stage and hl_c15 stops
	// dead.  Neither shows up in a walk log, because both look like "she is
	// standing at a node".
	//
	// Driven through W_ApplyDamage rather than by calling the filter directly,
	// because the WIRING is the risky half - a filter that works perfectly and is
	// never reached looks identical to one that was never installed.  Same
	// reasoning as AI_SenseSelfTest's synthetic bodies, and it runs on a spawned
	// stand-in so no live boss is ever left at 1 health by a diagnostic.
	//
	// FIRST, and before the map checks bail out, so this arm is exercised on
	// every map the cvar is set on rather than only on the one with a chain.
	entity dummy = spawn();
	dummy.classname  = "bigmomma_selftest_body";
	dummy.solid      = SOLID_NOT;
	dummy.movetype   = MOVETYPE_NONE;
	dummy.takedamage = DAMAGE_YES;
	dummy.flags      = dummy.flags | FL_MONSTER;
	dummy.ai_damagefilter = BigMomma_DamageFilter;

	// Unfinished path, holding at a stage: no bits set at all.  A blow far past
	// her health must leave exactly 1 and mark the stage complete.
	dummy.health    = 300;
	dummy.ai_bm_mem = 0;
	W_ApplyDamage(world, dummy, 9999);
	if (dummy.health != 1)
	{
		print(sprintf("[bigmommatest] GATE: a 9999 hit on an unfinished path left %g health, expected 1\n",
		              dummy.health));
		bad = bad + 1;
	}
	if (!(dummy.ai_bm_mem & BMMEM_ADVANCE))
	{
		print("[bigmommatest] GATE: the killing blow did not advance the node - she would stall there forever\n");
		bad = bad + 1;
	}

	// Finished path: the filter must get out of the way completely.
	dummy.health    = 300;
	dummy.ai_bm_mem = BMMEM_FINISHED;
	W_ApplyDamage(world, dummy, 50);
	if (dummy.health != 250)
	{
		print(sprintf("[bigmommatest] GATE: a 50 hit on a FINISHED path left %g health, expected 250\n",
		              dummy.health));
		bad = bad + 1;
	}
	remove(dummy);

	// find(), not findchain(), and this is the lesson the func_tankmortar test
	// paid for: anything the loop body calls that builds a .chain of its own
	// rewrites the walk underneath it.  Nothing here does today, but a validator
	// that grows a "fire it and see" arm later would inherit the bug silently.
	e = find(world, classname, "info_bigmomma");
	while (e)
	{
		count = count + 1;
		e = find(e, classname, "info_bigmomma");
	}

	mom = find(world, classname, "monster_bigmomma");
	if (!mom && count == 0)
	{
		// No gonarch and no nodes.  Stage 1 still ran and is still worth
		// reporting - it is pure logic and does not need either to be present,
		// which is exactly why it goes first.
		print(sprintf("[bigmommatest] no monster_bigmomma and no nodes on this map; gate only, BAD=%g\n", bad));
		return;
	}

	if (!mom)
	{
		print(sprintf("[bigmommatest] %g node(s) but no monster_bigmomma on the map\n", count));
		bad = bad + 1;
		print(sprintf("[bigmommatest] %g node(s), BAD=%g\n", count, bad));
		return;
	}

	print(sprintf("[bigmommatest] monster_bigmomma at %v, health %g, seed \"%s\", %g node(s)\n",
	              mom.origin, mom.health, mom.ai_bm_next, count));

	if (mom.ai_bm_next == "" || !mom.ai_bm_next)
	{
		// Not a failure.  25 of the corpus's 26 gonarchs author no chain at all
		// and are ordinary boss monsters; only hl_c15 walks.
		print("[bigmommatest] no chain seeded (netname unset) - she will fight in place\n");
		print(sprintf("[bigmommatest] %g node(s), BAD=%g\n", count, bad));
		return;
	}

	// Walk the chain from the seed, bounded by the node count: a `target` that
	// points back up the chain would otherwise loop here forever, and a cycle is
	// itself a map bug worth naming.
	walked = 0;
	guard  = count + 1;
	want   = mom.ai_bm_next;
	while (want != "" && want && walked < guard)
	{
		n = find(world, targetname, want);
		if (!n)
		{
			print(sprintf("[bigmommatest] BROKEN LINK: \"%s\" does not exist - the path ends here\n", want));
			bad = bad + 1;
			want = "";
			break;
		}
		if (n.classname != "info_bigmomma")
		{
			// Half-Life does not check this either, so it is a warning rather
			// than a failure: the walk still works, the node keys are just all
			// zero and she treats it as "go there and carry on".
			print(sprintf("[bigmommatest] note: \"%s\" is a %s, not an info_bigmomma\n",
			              want, n.classname));
		}

		walked = walked + 1;
		// The two flags are folded into one string first because fteqcc caps a
		// varargs call at eight parameters INCLUDING the format, and this line
		// wants nine.  Not a style choice: it is a hard compile error otherwise.
		string nflags = "";
		if (n.spawnflags & SF_INFOBM_RUN)	nflags = "RUN ";
		if (n.spawnflags & SF_INFOBM_WAIT)	nflags = strcat(nflags, "WAIT ");
		print(sprintf("[bigmommatest]  %2g. %-12s %v r=%-5g delay=%-3g %shealth=%g\n",
		              walked, n.targetname, n.origin, n.radius, n.reachdelay,
		              nflags, n.health));

		if (n.reachtarget != "" && n.reachtarget)
		{
			if (!find(world, targetname, n.reachtarget))
			{
				print(sprintf("[bigmommatest]      reachtarget \"%s\" resolves to nothing\n",
				              n.reachtarget));
				bad = bad + 1;
			}
			else
				print(sprintf("[bigmommatest]      fires \"%s\"\n", n.reachtarget));
		}

		// The sequence names, against the model she is actually wearing rather
		// than against the ones big_mom.mdl is supposed to have.  This is the
		// check that catches a Sven map authored for a replacement rig.
		if (n.presequence != "" && n.presequence)
		{
			if (frameforname(mom.modelindex, n.presequence) < 0)
			{
				print(sprintf("[bigmommatest]      presequence \"%s\" is not on her model\n",
				              n.presequence));
				bad = bad + 1;
			}
		}
		if (n.reachsequence != "" && n.reachsequence)
		{
			if (frameforname(mom.modelindex, n.reachsequence) < 0)
			{
				print(sprintf("[bigmommatest]      reachsequence \"%s\" is not on her model\n",
				              n.reachsequence));
				bad = bad + 1;
			}
		}

		want = n.target;
	}

	if (walked >= guard)
	{
		print("[bigmommatest] CYCLE: the chain revisits a node - she would never finish the path\n");
		bad = bad + 1;
	}

	// Nodes that exist but nothing points at, and which are not the seed.  Not
	// necessarily an error - a mapper may leave a spare - but an unreachable node
	// is the usual shape of "I renamed one and missed a link".
	orphan = 0;
	e = find(world, classname, "info_bigmomma");
	while (e)
	{
		if (e.targetname != mom.ai_bm_next)
		{
			entity src = world;
			entity q = find(world, classname, "info_bigmomma");
			while (q)
			{
				if (q.target == e.targetname && q != e)
				{
					src = q;
					q = world;
				}
				else
					q = find(q, classname, "info_bigmomma");
			}
			if (!src)
			{
				print(sprintf("[bigmommatest] unreachable node \"%s\" at %v\n",
				              e.targetname, e.origin));
				orphan = orphan + 1;
			}
		}
		e = find(e, classname, "info_bigmomma");
	}

	print(sprintf("[bigmommatest] %g node(s), %g walked, %g unreachable, BAD=%g\n",
	              count, walked, orphan, bad));
};
