//
//  sv_func_traincontrols.qc  –  func_traincontrols
//
//  GoldSrc/Sven "Train Controls": an invisible, non-solid brush glued to a
//  func_tracktrain.  Standing inside it and pressing +use drives the train.
//
//  Sven's FGD (sven-coop.fgd:2584) gives it exactly one key — `target`, the
//  tracktrain's targetname — and no spawnflags.  It does not even inherit
//  Targetname.
//
//  In the Half-Life SDK the brush hands its mins/maxs to the train via
//  SetControls() and then deletes itself; the train thereafter tests whether a
//  player's origin, rotated into train-local space, is inside that box.  We do
//  the same thing, except the zone entity survives to hold the box (removing it
//  would mean adding two more fields to func_tracktrain for no gain).
//
//  ORIENTED, not axis-aligned: FuncTrackTrain_FaceTarget rewrites the train's
//  .angles every tick, so an axis-aligned test would be wrong the moment the
//  train rounds a corner.  This is the same oriented-box treatment
//  func_vehiclecontrols already uses (sv_func_vehicle.qc:637), and the two
//  entities are close enough that the transform below is deliberately written
//  to match it line for line.
//
//  SCOPE: HL's controls give a quarter-step throttle over [-1, +1] x m_speed.
//  func_tracktrain here has no reverse and no variable speed
//  (sv_func_tracktrain.qc:24-33 says so), and adding them means implementing
//  reverse path-walking.  So +use maps onto the existing start/stop toggle,
//  which is what th_ep1_00's `pickup` truck actually wants — board it, press
//  use, drive off.  Throttle is noted in the QUAKED block as not implemented.
//

void() func_tracktrain_use;                 // sv_func_tracktrain.qc

.entity tctrl_train;        // zone -> train
.entity train_controls;     // train -> zone
.vector tctrl_offset;       // box CENTRE in the train's local frame (x=fwd, y=right, z=world-up)
.vector tctrl_half;         // box half-extents
.float  tctrl_link_tries;

// ---------------------------------------------------------------------------
// Is `plyr` standing in `train`'s control zone?  World -> train-local by
// projecting onto the train's yaw axes, i.e. the inverse yaw rotation.
// ---------------------------------------------------------------------------
float(entity plyr, entity train) TrainControls_PlayerInControls =
{
    entity z = train.train_controls;
    if (z == world)
        return FALSE;

    vector lc   = z.tctrl_offset;
    vector half = z.tctrl_half;

    vector rel = plyr.origin - train.origin;
    makevectors(train.angles_y * '0 1 0');
    vector lp;
    lp_x = rel * v_forward;
    lp_y = rel * v_right;
    lp_z = rel_z;

    // Z is generous the same way the vehicle test is: -8 lets a player standing
    // fractionally below the brush still count, +72 covers standing height.
    return (lp_x >= lc_x - half_x      && lp_x <= lc_x + half_x
         && lp_y >= lc_y - half_y      && lp_y <= lc_y + half_y
         && lp_z >= lc_z - half_z - 8  && lp_z <= lc_z + half_z + 72);
};

// ---------------------------------------------------------------------------
// +use entry point, called from sv_use.qc.  Returns TRUE if the press was
// consumed.  Walks every controls zone rather than the trains, because there
// are only ever a handful of them.
// ---------------------------------------------------------------------------
float(entity plyr) TrainControls_TryUse =
{
    entity z = find(world, classname, "func_traincontrols");
    while (z)
    {
        entity train = z.tctrl_train;
        if (train != world && TrainControls_PlayerInControls(plyr, train))
        {
            entity oldself = self;
            entity oldact  = activator;
            self      = train;
            activator = plyr;
            func_tracktrain_use();
            self      = oldself;
            activator = oldact;

            if (cvar("sv_debug_func_train"))
                dprint(sprintf("[traincontrols] %s toggled train \"%s\"\n",
                               plyr.netname, train.targetname));
            return TRUE;
        }
        z = find(z, classname, "func_traincontrols");
    }
    return FALSE;
};

// ---------------------------------------------------------------------------
// Deferred link.  The train may not exist yet when we spawn — entities are
// created one at a time during map load — so retry like
// func_vehiclecontrols_link does.
// ---------------------------------------------------------------------------
void() func_traincontrols_link =
{
    entity train = (self.target != "") ? find(world, targetname, self.target) : world;
    if (train == world || train.classname != "func_tracktrain")
    {
        self.tctrl_link_tries = self.tctrl_link_tries + 1;
        if (self.tctrl_link_tries < 40)
        {
            self.nextthink = time + 0.1;
            self.think     = func_traincontrols_link;
        }
        else if (cvar("sv_debug_func_train"))
            dprint(sprintf("[traincontrols] no func_tracktrain named \"%s\"\n",
                           self.target));
        return;
    }

    train.train_controls = self;
    self.tctrl_train     = train;

    makevectors(train.angles_y * '0 1 0');
    vector zcentre = self.origin + (self.mins + self.maxs) * 0.5;
    vector d = zcentre - train.origin;
    self.tctrl_offset_x = d * v_forward;
    self.tctrl_offset_y = d * v_right;
    self.tctrl_offset_z = d_z;
    self.tctrl_half     = (self.maxs - self.mins) * 0.5;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[traincontrols] linked to \"%s\" offset=%v half=%v\n",
                       train.targetname, self.tctrl_offset, self.tctrl_half));
};

/*QUAKED func_traincontrols (0 .5 .8) ?
Invisible, non-solid control zone for a func_tracktrain.  Stand inside it and
press +use to start / stop the train.

"target"   targetname of the func_tracktrain this drives

No spawnflags.  Sven's entity has no targetname either.

PARSED, NOT IMPLEMENTED: the InventoryRules keys (item_name_required,
item_group_required, pass_*, target_on_fail) and HL's quarter-step throttle —
this toggles the train's existing start/stop instead, because func_tracktrain
has no reverse or variable speed.
*/
void() func_traincontrols =
{
    if (!self.model)
    {
        remove(self);
        return;
    }

    // setmodel purely to harvest the brush bounds, then drop the visual —
    // HL's controls brush is never rendered and never collides.
    setmodel(self, self.model);
    vector bmin = self.mins;
    vector bmax = self.maxs;
    self.model      = "";
    self.modelindex = 0;
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    setsize(self, bmin, bmax);

    self.tctrl_link_tries = 0;
    self.think     = func_traincontrols_link;
    self.nextthink = time + 0.2;      // after func_tracktrain spawns
};
