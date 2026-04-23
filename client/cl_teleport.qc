
//
//  cl_teleport.qc  –  CSQC teleport trigger entity
//
//  Receives trigger_teleport data from the server and maintains the client-side
//  teleport_trigger_list walked by PM_CheckTeleportTriggers (shared/sh_pmove.qc).
//

// Remove a teleport trigger from the CSQC list (called by CSQC_Ent_Remove)
// Iteration-capped to defend against cycle corruption — see matching
// commentary in cl_push.qc push_list_remove_csqc.
void(entity trig) tele_list_remove_csqc =
{
	entity cur, prev;
	float  i;

	if (teleport_trigger_list == trig)
	{
		teleport_trigger_list = trig.tele_next;
		trig.tele_next = world;
		return;
	}

	prev = world;
	i = 0;
	for (cur = teleport_trigger_list; cur; cur = cur.tele_next)
	{
		if (cur == trig)
		{
			if (prev)
				prev.tele_next = cur.tele_next;
			cur.tele_next = world;
			return;
		}
		prev = cur;
		i = i + 1;
		if (i > 4096)
		{
			dprint("tele_list_remove_csqc: cycle detected, breaking chain\n");
			if (prev)
				prev.tele_next = world;
			return;
		}
	}
};

// Read a trigger_teleport entity update from the server and add to the list
void() CSQC_TeleportTrigger_Update =
{
	vector org, emins, emaxs;

	org   = readvector();
	emins = readvector();
	emaxs = readvector();
	self.tele_dest_origin = readvector();
	self.tele_dest_angles = readvector();
	self.spawnflags       = readfloat();
	self.tele_resolved    = readfloat();

	setorigin(self, org);
	setsize(self, emins, emaxs);

	if (teleport_trigger_list != self)
	{
		entity scan;
		float  i = 0;
		float  already_present = 0;
		for (scan = teleport_trigger_list; scan; scan = scan.tele_next)
		{
			if (scan == self)
			{
				already_present = 1;
				break;
			}
			i = i + 1;
			if (i > 4096)
			{
				dprint("CSQC_TeleportTrigger_Update: cycle detected during add-scan\n");
				break;
			}
		}
		if (!already_present)
		{
			self.tele_next        = teleport_trigger_list;
			teleport_trigger_list = self;
		}
	}
};
