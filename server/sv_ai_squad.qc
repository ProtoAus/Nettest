// server/sv_ai_squad.qc
// ----------------------------------------------------------------------------
// Squads.  Ported from dlls/squadmonster.cpp:
//   CSquadMonster::SquadRecruit    :308-386
//   CSquadMonster::SquadAdd        :189-214
//   CSquadMonster::SquadRemove     :146-187
//   CSquadMonster::SquadMakeEnemy  :244-276
//   CSquadMonster::OccupySlot      :52-102
//   CSquadMonster::VacateSlot      :104-115
//   CSquadMonster::NoFriendlyFire  :453-514
//   CSquadMonster::SquadEnemySplit :566-588
//
// WHAT THIS CHANGES, in one sentence each, because a squad system is not a
// visual and a reader deserves to know what to look for:
//
//   ONE GRUNT SEEING YOU MEANS ALL OF THEM DO.  SquadMakeEnemy is the callout.
//   Without it a squad discovers you one man at a time, in the order their
//   individual sight cones happen to sweep across you, which reads as four
//   separate stupid monsters rather than as a squad.
//
//   THEY TAKE TURNS.  Two engage slots per squad means at most two grunts fire
//   at once and the rest reposition.  This is the single largest difference
//   between Half-Life's grunts and a firing line, and it is a RATION, not a
//   restriction: the ones without a slot are free to do everything else.
//
//   THEY DO NOT SHOOT EACH OTHER.  NoFriendlyFire tests a wedge in front of the
//   shooter, not a ray, because a bullet spread is a cone.
//
// Compiled BEFORE sv_ai_core.qc, which calls into it on enemy acquisition and on
// every schedule change, and before the class files, which declare their slots.
// ----------------------------------------------------------------------------

// Counters.  A squad is invisible in a log otherwise: "the squad system is off"
// and "no map I tested has two of the same monster within 1024 units" produce
// identical behaviour and identical output.
float ai_dbg_squad_recruits;	// monsters pulled into a squad
float ai_dbg_squad_leaders;	// squads formed
float ai_dbg_squad_callouts;	// SquadMakeEnemy propagations
float ai_dbg_squad_slotwins;	// attacks allowed by a slot
float ai_dbg_squad_slotdenied;	// ...and refused for want of one
float ai_dbg_squad_ffholds;	// shots held because a squadmate was in the way
float ai_dbg_squad_frienddmg;	// COND_FRIEND_DAMAGED raises

float(entity m) Squad_In =
{
	return (m.ai_squad_leader != world);
};

entity(entity m) Squad_Leader =
{
	if (m.ai_squad_leader)
		return m.ai_squad_leader;
	return m;
};

float(entity m) Squad_IsLeader =
{
	return (m.ai_squad_leader == m);
};

float(entity m) Squad_Count =
{
	if (!Squad_In(m))
		return 0;

	float n = 0;
	entity e = Squad_Leader(m);
	while (e && n < 32)		// the 32 is a runaway guard, not a squad cap
	{
		n = n + 1;
		e = e.ai_squad_next;
	}
	return n;
};

// squadmonster.cpp:189-214.  The cap is enforced HERE rather than by the size of
// a handle array, so a map with nine grunts in a room forms two squads instead of
// silently dropping four of them.
float(entity leader, entity add) Squad_Add =
{
	if (!leader || !add || leader == add)
		return FALSE;
	if (Squad_In(add))
		return FALSE;
	if (Squad_Count(leader) >= SQUAD_MAX_MEMBERS)
		return FALSE;

	// Push onto the tail so the leader stays the head of its own chain.
	entity tail = leader;
	while (tail.ai_squad_next)
		tail = tail.ai_squad_next;

	tail.ai_squad_next   = add;
	add.ai_squad_next    = world;
	add.ai_squad_leader  = leader;
	ai_dbg_squad_recruits = ai_dbg_squad_recruits + 1;
	return TRUE;
};

// squadmonster.cpp:104-115.  Give up the attack slot.  Idempotent, and it has to
// be: it is called from schedule change, from death and from teardown, and any
// two of those can fire for the same monster in the same frame.
void(entity m) Squad_VacateSlot =
{
	if (m.ai_slot != SQSLOT_NONE && Squad_In(m))
	{
		entity l = Squad_Leader(m);
		l.ai_squad_slots = l.ai_squad_slots & ~m.ai_slot;
	}
	m.ai_slot = SQSLOT_NONE;
};

// squadmonster.cpp:146-187.  A member leaving, by death or by teardown.
//
// LEADERSHIP IS INHERITED, not disbanded.  Half-Life promotes the first
// surviving member and re-points everyone at it; the alternative - dropping the
// squad when its leader dies - would mean that shooting the right grunt first
// silently turns the other three back into individuals, which is a strange and
// invisible reward for an arbitrary choice.
void(entity m) Squad_Remove =
{
	if (!Squad_In(m))
		return;

	Squad_VacateSlot(m);
	entity l = Squad_Leader(m);

	if (l == m)
	{
		// The leader is leaving.  The second member becomes the new head, and
		// every remaining member is re-pointed at it - including the slot
		// bitfield, which lives on the leader and would otherwise be lost.
		entity heir = m.ai_squad_next;
		m.ai_squad_next   = world;
		m.ai_squad_leader = world;

		if (!heir)
			return;			// squad of one, now of none

		heir.ai_squad_slots = l.ai_squad_slots;

		entity e = heir;
		while (e)
		{
			e.ai_squad_leader = heir;
			e = e.ai_squad_next;
		}

		// squadmonster.cpp:180-186 - no single-member squads.  A lone survivor is
		// not a squad, and leaving it flagged as one would keep it rationing its
		// own attack slots against nobody.
		if (!heir.ai_squad_next)
		{
			heir.ai_squad_leader = world;
			heir.ai_slot         = SQSLOT_NONE;
			heir.ai_squad_slots  = 0;
		}
		return;
	}

	// An ordinary member: unlink it from the chain.
	entity p = l;
	while (p && p.ai_squad_next != m)
		p = p.ai_squad_next;
	if (p)
		p.ai_squad_next = m.ai_squad_next;

	m.ai_squad_next   = world;
	m.ai_squad_leader = world;

	if (!l.ai_squad_next)
	{
		l.ai_squad_leader = world;
		l.ai_slot         = SQSLOT_NONE;
		l.ai_squad_slots  = 0;
	}
};

// squadmonster.cpp:308-386.  Called once per monster, on its first decision tick
// rather than at spawn, and that timing is not incidental: a monster built while
// the map is still loading cannot see the squadmates that have not been spawned
// yet, so recruiting at build time would give the first entity in the .bsp an
// empty squad and every later one a squad of the wrong size.  Half-Life has the
// same structure - SquadRecruit runs from StartMonster, off the first think.
float(entity m, float radius) Squad_Recruit =
{
	if (Squad_In(m))
		return 0;

	// I am my own leader until somebody joins.
	m.ai_squad_leader = m;
	m.ai_squad_next   = world;
	float n = 1;

	entity e = findradius(m.origin, radius);
	while (e)
	{
		if (e != m && (e.flags & FL_MONSTER) && e.health > 0
		    && e.deadflag == DEAD_NO && !e.ai_script
		    && !Squad_In(e) && e.ai_class == m.ai_class
		    // squadmonster.cpp:357 - for the ALIEN classes the classname must
		    // match too.  CLASS_ALIEN_MONSTER is a broad bucket (a zombie, a
		    // gargantua and a bullsquid are all in it) and without this a
		    // gargantua would end up leading a squad of headcrabs.
		    && e.classname == m.classname
		    // A named squad is the map author's decision and outranks proximity;
		    // two differently-named squads standing in the same room stay
		    // separate.  squadmonster.cpp:328-346.
		    && e.squadname == m.squadname)
		{
			// squadmonster.cpp:361 - a traceline, so a "squad" cannot form
			// through a wall between two rooms that merely happen to be close.
			traceline(m.origin + m.view_ofs, e.origin + m.view_ofs, TRUE, e);
			if (trace_fraction == 1)
			{
				if (!Squad_Add(m, e))
					break;		// full
				n = n + 1;
			}
		}
		e = e.chain;
	}

	// squadmonster.cpp:380-384.  No single-member squads: a lone monster that
	// thinks it is a squad rations its own attack slots against nobody.
	if (n == 1)
	{
		m.ai_squad_leader = world;
		return 0;
	}

	ai_dbg_squad_leaders = ai_dbg_squad_leaders + 1;
	return n;
};

// squadmonster.cpp:566-588.  Are the members fighting different enemies?
float(entity m) Squad_EnemySplit =
{
	if (!Squad_In(m))
		return FALSE;

	entity l  = Squad_Leader(m);
	entity en = l.ai_enemy;
	entity e  = l;
	while (e)
	{
		if (e.ai_enemy && e.ai_enemy != en)
			return TRUE;
		e = e.ai_squad_next;
	}
	return FALSE;
};

// squadmonster.cpp:52-102.  Ask the leader for one of `desired`.  TRUE means go
// ahead; FALSE means somebody else is engaging and this member must do something
// else this tick.
float(entity m, int desired) Squad_OccupySlot =
{
	if (desired == SQSLOT_NONE)
		return TRUE;
	if (!Squad_In(m))
		return TRUE;		// solo monsters are never rationed

	if (Squad_EnemySplit(m))
	{
		// Slots OFF while the squad is split - see the SQSLOT_SQUAD_SPLIT note in
		// sv_ai_defs.qc.  Marking the slot rather than leaving it NONE is what
		// lets Squad_VacateSlot stay a single unconditional clear.
		m.ai_slot = SQSLOT_SQUAD_SPLIT;
		return TRUE;
	}

	entity l = Squad_Leader(m);

	// Already holding one of the slots asked for: keep it rather than churn.
	if (m.ai_slot != SQSLOT_NONE && (m.ai_slot & desired))
		return TRUE;

	float i;
	for (i = 0; i < SQUAD_NUM_SLOTS; i = i + 1)
	{
		int mask = (int)pow(2, i);
		if (!(desired & mask))
			continue;
		if (l.ai_squad_slots & mask)
			continue;		// taken

		Squad_VacateSlot(m);	// drop any slot from a different family first
		l.ai_squad_slots = l.ai_squad_slots | mask;
		m.ai_slot        = mask;
		ai_dbg_squad_slotwins = ai_dbg_squad_slotwins + 1;
		return TRUE;
	}

	ai_dbg_squad_slotdenied = ai_dbg_squad_slotdenied + 1;
	return FALSE;
};

// squadmonster.cpp:244-276.  The callout.
//
// Only members who are NOT already engaged are told, which is the part that
// makes it read as communication rather than as mind-reading: a grunt already
// shooting at you does not swap targets because someone shouted, and a grunt
// staring at a wall turns round.
void(entity m, entity en) Squad_MakeEnemy =
{
	if (!Squad_In(m) || !en || en == world)
		return;

	entity e = Squad_Leader(m);
	while (e)
	{
		if (e != m && e.health > 0 && e.deadflag == DEAD_NO
		    && e.ai_enemy != en && !(e.ai_cond & COND_SEE_ENEMY))
		{
			e.ai_enemy = en;
			// SquadCopyEnemyInfo's whole payload: where the enemy was last known
			// to be.  This mod calls it ai_lastseenpos, and handing it over is
			// what lets a called-out squadmate PATH to you rather than stand
			// there holding an enemy it has never seen - TASK_GET_PATH_LKP fails
			// outright when ai_lastseen is zero.
			e.ai_lastseenpos = en.origin;
			e.ai_lastseen    = time;
			// Wake a dormant squadmate the same way being shot does, or the
			// callout takes up to half a second to land on an idle monster and
			// the squad still trickles in one at a time.
			if (e.ai_state == MS_IDLE || e.ai_state == MS_NONE)
				e.ai_state = MS_ALERT;
			e.nextthink = time + 0.05;
			ai_dbg_squad_callouts = ai_dbg_squad_callouts + 1;
		}
		e = e.ai_squad_next;
	}
};

// Tell the squad something happened.  squadmonster.cpp's SquadAddConditions.
void(entity m, int cond) Squad_AddConditions =
{
	if (!Squad_In(m))
		return;

	entity e = Squad_Leader(m);
	while (e)
	{
		if (e != m)
			e.ai_cond = e.ai_cond | cond;
		e = e.ai_squad_next;
	}
};

// squadmonster.cpp:453-514.  Is the line of fire clear of squadmates?
//
// A WEDGE, NOT A RAY, and Valve's own comment calls the plane maths a bugbug.
// The three planes describe everything in front of the shooter within one and a
// half hull widths either side; anything inside that volume blocks the shot.
// That is deliberately coarser than a traceline down the barrel, because the
// thing being avoided is a SPREAD - AI_FireBullets throws its rounds inside a
// cone, so a shot that misses the squadmate down the centre line can still hit
// him with the edge of the group.
//
// Half-Life builds the planes from the direction of the ENEMY rather than from
// the monster's facing, and leaves a note saying that is wrong; it is kept,
// because the alternative changes which shots are refused and the whole value of
// this function is that it matches what Half-Life's grunts do.
float(entity m) Squad_NoFriendlyFire =
{
	if (!Squad_In(m))
		return TRUE;

	// squadmonster.cpp:475-480 - no enemy means "pretend a friendly is in the
	// way", so the grunt holds fire.  Not a guard clause: it is the answer.
	if (!m.ai_enemy)
		return FALSE;

	vector to = (m.ai_enemy.origin + (m.ai_enemy.mins + m.ai_enemy.maxs) * 0.5)
	          - m.origin;
	if (to == '0 0 0')
		return FALSE;
	makevectors(vectoangles(to));

	float halfw = (m.maxs_x - m.mins_x) * 1.5;

	entity e = Squad_Leader(m);
	while (e)
	{
		if (e != m && e.health > 0 && e.deadflag == DEAD_NO)
		{
			vector rel = e.origin - m.origin;
			// In front, and inside the wedge either side.  Same three tests as
			// HL's backPlane / leftPlane / rightPlane, expressed as dots because
			// a QC plane struct would buy nothing.
			if ((rel * v_forward) > 0)
			{
				float lat = rel * v_right;
				if (lat > -halfw && lat < halfw)
				{
					ai_dbg_squad_ffholds = ai_dbg_squad_ffholds + 1;
					return FALSE;
				}
			}
		}
		e = e.ai_squad_next;
	}
	return TRUE;
};

// The one line every attack decision needs: may this monster engage right now?
// Slots and friendly fire are asked together because they are always asked
// together, and a class that forgets one of them fails silently.
// Is there an attack slot this monster could take, WITHOUT taking it?
//
// Read-only twin of Squad_OccupySlot, and it has to be: the point of the caller
// (Cover_ScheduleIfCrowded) is to find out whether a monster is being denied, and
// asking with the real function would hand it the slot it is asking about and
// answer its own question wrong.
float(entity m) Squad_SlotsFree =
{
	int desired = m.ai_slots_attack;
	if (desired == SQSLOT_NONE)	return TRUE;
	if (!Squad_In(m))		return TRUE;
	if (Squad_EnemySplit(m))	return TRUE;	// rationing is off while split

	// Already holding one of them - Squad_OccupySlot would keep it.
	if (m.ai_slot != SQSLOT_NONE && (m.ai_slot & desired))
		return TRUE;

	entity l = Squad_Leader(m);
	float i;
	for (i = 0; i < SQUAD_NUM_SLOTS; i = i + 1)
	{
		int mask = (int)pow(2, i);
		if (!(desired & mask))		continue;
		if (l.ai_squad_slots & mask)	continue;	// taken
		return TRUE;
	}
	return FALSE;
};

// How many squadmates are shooting RIGHT NOW.  Counts the schedule rather than
// the slot bits, because the surplus engagers permitted below hold no bit at all
// and would otherwise be invisible to their own ration.
float(entity m) Squad_EngagingCount =
{
	float n = 0;
	entity e = Squad_Leader(m);
	while (e)
	{
		if (e != m && e.health > 0 && e.deadflag == DEAD_NO
		    && e.ai_sched == SCHED_RANGE_ATTACK1)
			n = n + 1;
		e = e.ai_squad_next;
	}
	return n;
};

float(entity m) Squad_MayEngage =
{
	if (!Squad_NoFriendlyFire(m))
		return FALSE;

	// Always ask for the bit, whatever the ration: the first two shooters then
	// hold real slots and every other consumer of ai_slot / ai_squad_slots
	// (Squad_VacateSlot, Squad_SlotsFree, Cover_ScheduleIfCrowded) keeps working
	// unchanged.  Only the ANSWER is re-rationed below.
	float got_bit = Squad_OccupySlot(m, m.ai_slots_attack);

	// 2 is Half-Life exactly - the two bits ARE the ration.
	if (ai_cached_engageslots == 2)
		return got_bit;
	// 0 disables rationing entirely.
	if (ai_cached_engageslots == 0)
		return TRUE;

	// Otherwise the COUNT is the ration, not the bitfield - which is the whole
	// reason this is not simply a wider mask.  All 11 slot bits in
	// sv_ai_defs.qc:441-461 are already allocated to the grenade / agrunt /
	// houndeye families, so widening SQSLOTS_ENGAGE would silently share bits
	// with another species: exactly the failure the per-family layout exists to
	// prevent.  A surplus engager holds no bit, so nothing has to be released.
	//
	// Counting the schedule rather than the bits is what makes a value BELOW 2
	// bite as well: Squad_OccupySlot would happily hand out both bits, so a
	// tighter ration can only be expressed here.
	return Squad_EngagingCount(m) < ai_cached_engageslots;
};
