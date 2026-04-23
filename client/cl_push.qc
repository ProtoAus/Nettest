
//
//  cl_push.qc  –  CSQC push trigger entity
//
//  Receives trigger_push data from the server and maintains the client-side
//  push_trigger_list walked by PM_CheckTriggerPushes (shared/sh_pmove.qc).
//

// Remove a push trigger from the CSQC list (called by CSQC_Ent_Remove).
// Iteration-capped to defend against a corrupt list with a cycle; observed
// in the wild when a push-trigger entity gets re-added after its push_next
// was cleared while still reachable from the head, producing an infinite
// walk and a runaway-loop client crash on the next CSQC_Ent_Remove call.
// The cap short-circuits the walk and breaks the chain so the client
// survives instead of aborting.
void(entity trig) push_list_remove_csqc =
{
	entity cur, prev;
	float  i;

	if (push_trigger_list == trig)
	{
		push_trigger_list = trig.push_next;
		trig.push_next = world;
		return;
	}

	prev = world;
	i = 0;
	for (cur = push_trigger_list; cur; cur = cur.push_next)
	{
		if (cur == trig)
		{
			if (prev)
				prev.push_next = cur.push_next;
			cur.push_next = world;
			return;
		}
		prev = cur;
		i = i + 1;
		if (i > 4096)
		{
			dprint("push_list_remove_csqc: cycle detected, breaking chain\n");
			if (prev)
				prev.push_next = world;
			return;
		}
	}
};

// Read a trigger_push entity update from the server and add to the list
void() CSQC_PushTrigger_Update =
{
	vector org, emins, emaxs;

	org   = readvector();
	emins = readvector();
	emaxs = readvector();
	self.movedir    = readvector();
	self.speed      = readfloat();
	self.spawnflags = readfloat();

	setorigin(self, org);
	setsize(self, emins, emaxs);

	// Only add if not already in the list.  Walk the whole list to
	// be sure — the old check (self.push_next == world) was fooled
	// when push_next had been stomped back to world while self was
	// still reachable from the head, creating a cycle on add.
	if (push_trigger_list != self)
	{
		entity scan;
		float  i = 0;
		float  already_present = 0;
		for (scan = push_trigger_list; scan; scan = scan.push_next)
		{
			if (scan == self)
			{
				already_present = 1;
				break;
			}
			i = i + 1;
			if (i > 4096)
			{
				dprint("CSQC_PushTrigger_Update: cycle detected during add-scan\n");
				break;
			}
		}
		if (!already_present)
		{
			self.push_next    = push_trigger_list;
			push_trigger_list = self;
		}
	}
};
