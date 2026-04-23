
//
//  cl_ladder.qc  –  CSQC ladder trigger entity
//
//  Receives trigger_ladder data from the server and maintains the client-side
//  ladder_trigger_list walked by PM_CheckLadder (shared/sh_pmove.qc).
//

// Iteration-capped to defend against cycle corruption — see matching
// commentary in cl_push.qc push_list_remove_csqc.
void(entity trig) ladder_list_remove_csqc =
{
    entity cur, prev;
    float  i;

    if (ladder_trigger_list == trig)
    {
        ladder_trigger_list = trig.ladder_next;
        trig.ladder_next = world;
        return;
    }

    prev = world;
    i = 0;
    for (cur = ladder_trigger_list; cur; cur = cur.ladder_next)
    {
        if (cur == trig)
        {
            if (prev)
                prev.ladder_next = cur.ladder_next;
            cur.ladder_next = world;
            return;
        }
        prev = cur;
        i = i + 1;
        if (i > 4096)
        {
            dprint("ladder_list_remove_csqc: cycle detected, breaking chain\n");
            if (prev)
                prev.ladder_next = world;
            return;
        }
    }
};

void() CSQC_LadderTrigger_Update =
{
    vector org, emins, emaxs;

    org      = readvector();
    emins    = readvector();
    emaxs    = readvector();
    self.movedir = readvector();

    setorigin(self, org);
    setsize(self, emins, emaxs);

    if (ladder_trigger_list != self)
    {
        entity scan;
        float  i = 0;
        float  already_present = 0;
        for (scan = ladder_trigger_list; scan; scan = scan.ladder_next)
        {
            if (scan == self)
            {
                already_present = 1;
                break;
            }
            i = i + 1;
            if (i > 4096)
            {
                dprint("CSQC_LadderTrigger_Update: cycle detected during add-scan\n");
                break;
            }
        }
        if (!already_present)
        {
            self.ladder_next    = ladder_trigger_list;
            ladder_trigger_list = self;
        }
    }
};
