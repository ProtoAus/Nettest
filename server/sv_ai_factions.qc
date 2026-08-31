// server/sv_ai_factions.qc
// ----------------------------------------------------------------------------
// Who hates whom.  Half-Life's IRelationship matrix, and the reason it is not
// optional: without it every monster in this mod treats every player as an enemy,
// which since W3 has meant monster_barney (319 placements), monster_otis (81),
// monster_human_grunt_ally (406) and monster_human_medic_ally (52) all shooting
// the people they are supposed to be escorting.  They were tagged
// CLASS_PLAYER_ALLY and is_player_ally when they were built; nothing read either
// field until this file.
//
// HL's matrix is a 2D table of R_AL/R_NO/R_DL/R_HT/R_FR (ally, no relationship,
// dislike, hate, fear).  QC has no 2D arrays, so it is expressed as a function -
// which is also more readable than a 13x13 grid of two-letter codes, and lets the
// asymmetric cases carry a comment explaining themselves.
//
// The `classify` map key overrides the class default, which is Sven's own
// behaviour: 2969 entities across the corpus carry one and until now not one of
// them was read.
// ----------------------------------------------------------------------------

const float R_FEAR    = -2;	// runs away
const float R_ALLY    = -1;	// will not attack, will follow
const float R_NONE    =  0;	// ignores
const float R_DISLIKE =  1;	// attacks if provoked or convenient
const float R_HATE    =  2;	// attacks on sight

// Where an entity sits in the matrix.  Players are CLASS_PLAYER; a monster uses
// its map `classify` override if one was supplied, else the class default set by
// its ClassInit.
float(entity e) AI_ClassOf =
{
	if (e.classname == "player")
		return CLASS_PLAYER;
	if (e.classify > 0)
		return e.classify;		// Sven's per-entity override wins
	return e.ai_class;
};

// The matrix itself, read as "how does `a` feel about `b`".
//
// Deliberately NOT symmetric.  A headcrab hates a scientist; a scientist FEARS a
// headcrab and runs rather than fighting, which is the entire behaviour that
// makes HL's scientists read as civilians instead of unarmed soldiers.
float(float a, float b) AI_Relationship =
{
	if (a == CLASS_NONE || b == CLASS_NONE)
		return R_NONE;

	// --- machines ---------------------------------------------------------
	// Turrets and robots shoot anything organic that is not military human.
	if (a == CLASS_MACHINE)
	{
		if (b == CLASS_PLAYER || b == CLASS_PLAYER_ALLY)	return R_HATE;
		if (b == CLASS_HUMAN_PASSIVE)				return R_HATE;
		if (b == CLASS_ALIEN_MILITARY || b == CLASS_ALIEN_MONSTER)	return R_HATE;
		return R_NONE;
	}

	// --- the player and their friends -------------------------------------
	if (a == CLASS_PLAYER || a == CLASS_PLAYER_ALLY)
	{
		if (b == CLASS_PLAYER || b == CLASS_PLAYER_ALLY)	return R_ALLY;
		if (b == CLASS_HUMAN_PASSIVE)				return R_ALLY;
		if (b == CLASS_INSECT)					return R_NONE;
		if (b == CLASS_ALIEN_PREY)				return R_DISLIKE;
		return R_HATE;			// military, aliens, machines
	}

	// Scientists and other unarmed humans.  They fear anything hostile rather
	// than hating it - AI_SelectSchedule turns R_FEAR into SCHED_FLEE_ENEMY.
	if (a == CLASS_HUMAN_PASSIVE)
	{
		if (b == CLASS_PLAYER || b == CLASS_PLAYER_ALLY)	return R_ALLY;
		if (b == CLASS_HUMAN_PASSIVE)				return R_ALLY;
		if (b == CLASS_INSECT)					return R_NONE;
		return R_FEAR;
	}

	// --- human military ---------------------------------------------------
	if (a == CLASS_HUMAN_MILITARY)
	{
		if (b == CLASS_HUMAN_MILITARY)				return R_ALLY;
		if (b == CLASS_MACHINE)					return R_ALLY;
		if (b == CLASS_INSECT)					return R_NONE;
		if (b == CLASS_ALIEN_PREY)				return R_DISLIKE;
		return R_HATE;			// players, allies, scientists, aliens
	}

	// --- aliens -----------------------------------------------------------
	// ALIENS MOSTLY DO NOT FIGHT EACH OTHER.  The broad rule still holds and is
	// worth keeping stated, because the tempting assumption is the wrong one:
	// Half-Life's table (monsters.cpp:2199-2216) is R_NO across nearly the whole
	// alien block, so a zombie ignores a headcrab and a bullsquid ignores an alien
	// grunt.  "Surely a predator eats prey" is exactly the kind of reasoning that
	// produces a map full of monsters killing each other before the player arrives.
	//
	// But HL does carry TWO deliberate exceptions inside that block, and this
	// matrix used to flatten both to R_NONE.  They are restored below.
	if (a == CLASS_ALIEN_MILITARY || a == CLASS_ALIEN_MONSTER
	 || a == CLASS_ALIEN_PREDATOR || a == CLASS_ALIEN_PREY
	 || a == CLASS_ALIEN_PASSIVE)
	{
		if (b == CLASS_PLAYER || b == CLASS_PLAYER_ALLY)	return R_HATE;
		if (b == CLASS_HUMAN_PASSIVE)
			return (a == CLASS_ALIEN_PREY) ? R_NONE : R_DISLIKE;
		if (b == CLASS_HUMAN_MILITARY)
			return (a == CLASS_ALIEN_MILITARY) ? R_HATE : R_DISLIKE;
		if (b == CLASS_MACHINE)
			return (a == CLASS_ALIEN_MILITARY) ? R_HATE : R_DISLIKE;

		// PREDATOR HUNTS PREY.  monsters.cpp:2212, the ALIENPREDATOR row, ALIENPREY
		// column, is R_HT - a bullsquid genuinely hunts headcrabs, and watching one
		// chase down a crab is a piece of Half-Life's world that was missing here.
		//
		// This is the one change in this patch that ADDS monster-on-monster combat,
		// so it wants keeping straight from the accidental kind: the headcrab's
		// missing LeapTouch Classify() guard (mon_headcrab.qc) and the unordered
		// enemy pick in AI_FindEnemy were bugs and are fixed; this is authored
		// behaviour and is deliberate.
		if (a == CLASS_ALIEN_PREDATOR && b == CLASS_ALIEN_PREY)		return R_HATE;

		// ...and predators squabble with each other (same row, ALIENPREDATOR column
		// is R_DL).  Dislike rather than hate: they will fight if nothing better is
		// available, but anything they actually hate outranks it - which is only
		// true now that AI_FindEnemy sorts by relationship before distance.
		if (a == CLASS_ALIEN_PREDATOR && b == CLASS_ALIEN_PREDATOR)	return R_DISLIKE;

		// Prey is afraid of predators - the mirror of the first exception.
		if (a == CLASS_ALIEN_PREY && b == CLASS_ALIEN_PREDATOR)		return R_FEAR;
		return R_NONE;			// every other alien-on-alien pairing
	}

	// Cockroaches and the like: afraid of everything, hostile to nothing.  This is
	// what SCHED_FLEE_ENEMY was built for back in W2.
	if (a == CLASS_INSECT)
		return R_FEAR;

	if (a == CLASS_ALIEN_PASSIVE)
		return R_NONE;

	return R_NONE;
};

// ---------------------------------------------------------------------------
// grudges
// ---------------------------------------------------------------------------
// The matrix above is a pure function of CLASSES, and a grudge is a property of
// an INDIVIDUAL - so it cannot live in there.  Half-Life has exactly the same
// split and solves it the same way, by overriding the relationship one level up:
// CTalkMonster::IRelationship (talkmonster.cpp:1355-1361) returns R_HT for a
// player when bits_MEMORY_PROVOKED is set, and otherwise defers to the base
// matrix.  This is that override.
//
// Every relationship question in the AI reaches one of the three functions below,
// so putting it here is what makes a provoked Barney hostile EVERYWHERE at once -
// enemy validity, target selection, squad calls - with no schedule work at all.
// That is the whole reason to override the relationship rather than special-case
// "shoot the player" in the damage handler.
//
// DIVERGENCE FROM HALF-LIFE, and a deliberate one.  HL's provoked bit is never
// cleared: shoot Barney once and he is your enemy for the rest of the map.  In a
// campaign where the scenes happen where you cannot start a fight, that is fine.
// In a co-op mod it means one stray round in a firefight permanently costs you
// the escort, with no way back short of reloading.  So the grudge EXPIRES, on a
// cvar (sv_ai_grudge_time, default 30s), and 0 or less restores HL's behaviour
// exactly for anyone who wants it.
float(entity m) AI_IsProvoked =
{
	if (!(m.ai_memory & MEMORY_PROVOKED))
		return FALSE;

	// ai_grudge_end == 0 means "no expiry", which is what a non-positive
	// sv_ai_grudge_time latches at provoke time.  Do not test it against `time`.
	if (m.ai_grudge_end > 0 && time >= m.ai_grudge_end)
	{
		m.ai_memory   = m.ai_memory & ~MEMORY_PROVOKED;
		m.ai_grudge_end = 0;
		ai_dbg_forgiven = ai_dbg_forgiven + 1;
		// SUSPICIOUS survives on purpose.  He has forgiven you, not forgotten:
		// the next stray round skips the warning and goes straight to MAD, which
		// is HL's own escalation rule (barney.cpp:525 tests the same bit).
		if (m.ai_enemy.classname == "player")
			m.ai_enemy = world;
		return FALSE;
	}
	return TRUE;
};

// "How does `m` feel about `e`" - the entity-level question, which is the one
// every caller actually has.  AI_Relationship stays class-level and pure.
float(entity m, entity e) AI_RelationshipEnt =
{
	if (e.classname == "player" && AI_IsProvoked(m))
	{
		// AN UNARMED MAN DOES NOT CHARGE YOU.  A provoked scientist has no melee
		// and no ranged attack - both ranges are 0 by design so the generic ladder
		// can never offer him one - so returning R_HATE would put him in a combat
		// state with nothing to do in it, and he would stand there staring at the
		// person shooting him.  R_FEAR routes him into SCHED_FLEE_ENEMY instead,
		// which is the schedule that already exists and the behaviour anyone would
		// expect.  Half-Life reaches the same place by a different road (its
		// scientists flee on m_fearTime rather than on the relationship), and the
		// visible result is identical: he runs.
		if (m.ai_melee_range <= 0 && m.ai_range_range <= 0)
			return R_FEAR;
		return R_HATE;
	}

	// THE LEECH IS AN EXCEPTION TO ITS OWN CLASS, in Half-Life too.  CLeech is
	// CLASS_INSECT for classification (leech.cpp:113) but overrides
	// IRelationship to return R_DL against the player (leech.cpp:268-272) — it
	// is the one insect that comes at you.  The mod copied the classification
	// and not the override, so the blanket `CLASS_INSECT -> R_FEAR` rule above
	// made every leech swim AWAY from the player and put its bite permanently
	// out of reach.
	//
	// Handled here, per entity, rather than by editing the CLASS_INSECT row:
	// the cockroach is that row's only other user and genuinely does want
	// R_FEAR.
	if (e.classname == "player" && m.classname == "monster_leech")
		return R_DISLIKE;

	return AI_Relationship(AI_ClassOf(m), AI_ClassOf(e));
};

// Convenience: does `m` consider `e` a target worth attacking?
float(entity m, entity e) AI_Hates =
{
	return AI_RelationshipEnt(m, e) >= R_DISLIKE;
};

float(entity m, entity e) AI_Fears =
{
	// A provoked monster is angry, not frightened.  Without this a provoked
	// scientist would return R_HATE from AI_RelationshipEnt and R_FEAR here at
	// the same time, and AI_SelectSchedule tests fear FIRST - so he would flee
	// from the player he had just decided to fight.
	return AI_RelationshipEnt(m, e) == R_FEAR;
};
