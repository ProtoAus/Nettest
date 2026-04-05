
//
//  cl_push.qc  –  CSQC push trigger entity
//
//  Receives trigger_push data from the server and maintains the client-side
//  push_trigger_list walked by PM_CheckTriggerPushes (shared/sh_pmove.qc).
//

// Remove a push trigger from the CSQC list (called by CSQC_Ent_Remove)
void(entity trig) push_list_remove_csqc =
{
	entity cur, prev;

	if (push_trigger_list == trig)
	{
		push_trigger_list = trig.push_next;
		trig.push_next = world;
		return;
	}

	prev = world;
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

	if (self.push_next == world && push_trigger_list != self)
	{
		self.push_next    = push_trigger_list;
		push_trigger_list = self;
	}
};
