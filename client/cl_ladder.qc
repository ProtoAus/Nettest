
//
//  cl_ladder.qc  –  CSQC ladder trigger entity
//
//  Receives trigger_ladder data from the server and maintains the client-side
//  ladder_trigger_list walked by PM_CheckLadder (shared/sh_pmove.qc).
//

void(entity trig) ladder_list_remove_csqc =
{
    entity cur, prev;

    if (ladder_trigger_list == trig)
    {
        ladder_trigger_list = trig.ladder_next;
        trig.ladder_next = world;
        return;
    }

    prev = world;
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

    if (self.ladder_next == world && ladder_trigger_list != self)
    {
        self.ladder_next    = ladder_trigger_list;
        ladder_trigger_list = self;
    }
};
