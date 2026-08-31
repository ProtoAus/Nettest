//
//  mon_generic.qc  –  monster_generic  (Half-Life dlls/genericmonster.cpp)
//
//  THE CLASS THE MAPPERS USE WHEN THEY WANT AN ACTOR RATHER THAN A FIGHT.
//
//  CGenericMonster is a full CBaseMonster with the combat removed: no attacks, no
//  relationships worth speaking of, 8 health, and MonsterInit() called like any
//  other NPC (genericmonster.cpp:100-127).  That last line is the whole point of
//  the class - it is a monster, so a scripted_sequence can WALK it.
//
//  Here it was in the scenery list next to monster_furniture, which is the reading
//  its name invites and is wrong.  The cost was not that these NPCs stood still;
//  it is that they TELEPORTED.  Script_Claim (sv_scripted.qc:442-459) branches on
//  `ss_body = (m.think != AI_Think)` and, for an actor with no AI, turns every
//  travelling move mode into a snap:
//
//      if (bmv == 1 || bmv == 2 || bmv == 4) { setorigin(m, s.origin); ... }
//
//  ...with a comment reasoning that "0 and 4 are what these scripts use".  That
//  holds for the posed bodies the branch was written for and not at all for this
//  class.  hl_c00's two lobby scientists are `walker1` and `walker2`, each owned
//  by a pair of scripted_sequences that point at each other -
//
//      walk1 (m_fMoveTo 1, target walk2) <-> walk2 (m_fMoveTo 1, target walk1)
//
//  - so each one snapped 1192 units back and forth forever.  "They are very
//  teleporty, they jump very quickly, not moving like a scientist" is that loop,
//  described exactly.  Twelve of the map's twenty monster_generics are driven this
//  way, and the same shape appears across the corpus: 166 placements, of which 94
//  carry SF_GENERICMONSTER_NOTSOLID.
//
//  Nothing in this file makes the class fight.  It gains locomotion, a state
//  machine and the ability to be claimed as a real actor - which is all HL gives
//  it and all the maps ask for.
//

// Health.  genericmonster.cpp:117 is a flat `pev->health = 8`, with no skill cvar
// behind it - this is scenery that happens to walk, and Half-Life prices it that
// way.  Exposed through a cvar anyway for parity with every other class here; a
// map that wants a tougher one sets the `health` key, which Monster_Build honours
// over this.
float() Generic_DefaultHealth =
{
	float h = cvar("sv_ai_generic_health");
	return (h > 0) ? h : 8;
};

void(entity m) Generic_ClassInit =
{
	// CLASS_PLAYER_ALLY is deliberate and it is NOT the same choice as the
	// scientist's CLASS_HUMAN_PASSIVE.  CGenericMonster never overrides
	// Classify(), so it inherits CBaseMonster's CLASS_NONE - "nothing has an
	// opinion about me either way".  The nearest thing this tree has to that is an
	// ally with no weapon: it stops the lobby scientists being shot at by their own
	// map's monsters, which CLASS_NONE also achieves in HL because the relationship
	// table returns R_NO for every row against it.
	m.ai_class       = CLASS_PLAYER_ALLY;
	m.is_player_ally = TRUE;

	// m_flFieldOfView = 0.5 (genericmonster.cpp:118).  Half of the scientist's, and
	// it matters less than it looks: with no attacks there is nothing this class
	// does on sighting anybody.  Kept accurate rather than copied from a neighbour.
	m.ai_fov = 0.5;

	// NO ATTACKS AT ALL.  CGenericMonster declares neither CheckAttack override nor
	// any attack schedule, so both ranges stay zero and AI_CheckAttack can never
	// arm.  This is the line that keeps "give it AI" from also meaning "give it a
	// fight it was never meant to have".
	m.ai_melee_range = 0;
	m.ai_range_range = 0;

	// The gait numbers are the model's, not the class's, because the class has no
	// model of its own - the mapper supplies one through the `model` key and it is
	// scientist.mdl, barney.mdl, forklift.mdl or loader.mdl depending on the
	// placement.  These are scientist.mdl's measured cycles (walk 58.7, run 275.4),
	// which is what 14 of hl_c00's 20 placements use; a forklift never walks under
	// its own power (all three of them are m_fMoveTo 4, an instant placement) so
	// being wrong for it costs nothing.
	m.ai_speed_walk = 59;
	m.ai_speed_run  = 275;
	m.ai_yaw_speed  = 120;

	// NOT a talker.  monster_generic has no m_szGrp table in Half-Life and no voice
	// - AI_MakeTalker here would have hl_c00's lobby chattering in scientist
	// sentences at a player who is meant to be riding past them on a tram.
	//
	// It follows that the CTalkMonster behaviours added alongside this - the
	// COND_CLIENT_PUSH step-aside and the SCHED_STARTLE cower - do not apply to
	// this class either, which is correct: both are CScientist/CTalkMonster
	// overrides, not CBaseMonster ones.

	if (m.bloodcolor == 0)
		m.bloodcolor = 247;		// BLOOD_COLOR_RED

	// SF_GENERICMONSTER_NOTSOLID (genericmonster.cpp:25, :123-127).  94 of the 166
	// corpus placements set it, and it does two things, not one: the entity stops
	// colliding AND stops taking damage.  Applied here rather than in the spawn
	// function because AI_ClassInit runs after Monster_Build has decided solidity
	// for AI classes, so this is the last word on it.
	if (m.spawnflags & SF_GENERICMONSTER_NOTSOLID)
	{
		m.solid      = SOLID_NOT;
		m.takedamage = DAMAGE_NO;
	}
};
