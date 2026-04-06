//
//  sv_use.qc  –  +use activation and touch-trigger checks
//
//  SV_PlayerTryUse  : fired by "+use" client command; traces forward from
//                     the player's eye and calls .use on whatever it hits.
//  SV_CheckTouchTriggers: called every SV_RunClientCommand after PM_PlayerMove;
//                     fires SOLID_TRIGGER overlaps (door proximity triggers) and
//                     does a forward probe for func_button surface contact.
//

float PLAYER_USE_TRACE_LENGTH = 96;

// Activate a usable entity on behalf of self (the player).
// Returns TRUE if the entity accepted the use.
float(entity use_target) SV_UseTarget =
{
    entity oldself, oldactivator;
    if (!use_target || use_target == world)
        return FALSE;
    if (!use_target.use)
        return FALSE;
    oldself      = self;
    oldactivator = activator;
    activator    = self;
    self         = use_target;
    self.use();
    self      = oldself;
    activator = oldactivator;
    return TRUE;
};

// Trace forward from the player's eye; try the hit entity first, then fall
// back to a cone search so slightly off-center aims still register.
void() SV_PlayerTryUse =
{
    vector use_start, use_end;
    entity best, e;
    float  best_dot, dot;

    makevectors(self.v_angle);
    use_start = self.origin + self.view_ofs;
    use_end   = use_start + v_forward * PLAYER_USE_TRACE_LENGTH;

    tracebox(use_start, '-8 -8 -8', '8 8 8', use_end, MOVE_NORMAL, self);
    if (SV_UseTarget(trace_ent))
        return;

    // Radius fallback: pick the entity within the cone that is most aligned
    // with the player's view direction.
    best     = world;
    best_dot = 0.7;   // ~45-degree half-cone
    e = findradius(use_start, PLAYER_USE_TRACE_LENGTH);
    while (e)
    {
        if (e.use && e != self)
        {
            dot = normalize(e.origin - use_start) * v_forward;
            if (dot > best_dot)
            {
                best_dot = dot;
                best     = e;
            }
        }
        e = e.chain;
    }
    SV_UseTarget(best);
};

// Called after PM_PlayerMove each frame.
// 1. Check every nearby SOLID_TRIGGER for box overlap and fire its .touch.
//    This covers door proximity triggers (which the engine normally fires for
//    MOVETYPE players but not for our MOVETYPE_NONE + custom-physics players).
// 2. Short forward probe to detect func_button surface contact so that
//    walking into a button activates it.
void() SV_CheckTouchTriggers =
{
    entity e;
    entity oldself, oldother;

    // --- 1. SOLID_TRIGGER overlap (door auto-open triggers) ---
    e = findradius(self.origin, 128);
    while (e)
    {
        if (e.solid == SOLID_TRIGGER && e.touch)
        {
            if (self.absmin_x <= e.absmax_x && self.absmax_x >= e.absmin_x &&
                self.absmin_y <= e.absmax_y && self.absmax_y >= e.absmin_y &&
                self.absmin_z <= e.absmax_z && self.absmax_z >= e.absmin_z)
            {
                oldself = self; oldother = other;
                other   = self;
                self    = e;
                self.touch();
                self  = oldself;
                other = oldother;
            }
        }
        e = e.chain;
    }

    // --- 2. func_button contact check ---
    // Expand the player bbox by 2 units; any func_button overlapping that
    // expanded box is considered "touched" regardless of approach direction.
    e = findradius(self.origin, vlen(self.maxs) + 16);
    while (e)
    {
        if (e.classname == "func_button" && e.touch)
        {
            if (self.absmin_x - 2 <= e.absmax_x && self.absmax_x + 2 >= e.absmin_x &&
                self.absmin_y - 2 <= e.absmax_y && self.absmax_y + 2 >= e.absmin_y &&
                self.absmin_z - 2 <= e.absmax_z && self.absmax_z + 2 >= e.absmin_z)
            {
                oldself = self; oldother = other;
                other   = self;
                self    = e;
                self.touch();
                self  = oldself;
                other = oldother;
                break;  // one button at a time
            }
        }
        e = e.chain;
    }
};
