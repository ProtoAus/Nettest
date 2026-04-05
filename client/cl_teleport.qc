
//
//  cl_teleport.qc  –  CSQC teleport trigger entity
//
//  Receives trigger_teleport data from the server and maintains the client-side
//  teleport_trigger_list walked by PM_CheckTeleportTriggers (shared/sh_pmove.qc).
//

// Remove a teleport trigger from the CSQC list (called by CSQC_Ent_Remove)
void(entity trig) tele_list_remove_csqc =
{
	entity cur, prev;

	if (teleport_trigger_list == trig)
	{
		teleport_trigger_list = trig.tele_next;
		trig.tele_next = world;
		return;
	}

	prev = world;
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

	if (self.tele_next == world && teleport_trigger_list != self)
	{
		self.tele_next        = teleport_trigger_list;
		teleport_trigger_list = self;
	}
};
