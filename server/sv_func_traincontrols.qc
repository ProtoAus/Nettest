//
//  sv_func_traincontrols.qc  –  func_traincontrols, and the tracktrain driver
//
//  GoldSrc/Sven "Train Controls": an invisible, non-solid brush glued to a
//  func_tracktrain.  Standing inside it and pressing +use drives the train.
//
//  Sven's FGD (sven-coop.fgd:2584) gives it exactly one key — `target`, the
//  tracktrain's targetname — and no spawnflags.  It does not even inherit
//  Targetname.
//
//  THE BRUSH IS AN OVERRIDE, NOT A REQUIREMENT.  This is the thing that was
//  missing.  In the Half-Life SDK every func_tracktrain gets a default control
//  volume at spawn — its own bounding box with 72 units of headroom
//  (plats.cpp:1516-1518) — and func_traincontrols merely replaces that box via
//  SetControls() before deleting itself (plats.cpp:1344-1350, :1579).  This
//  file previously required the brush, so hl_c05_a1's `twain`, which ships
//  without one, could never be driven at all.  The default now lives on the
//  train (tt_ctrl_mins / tt_ctrl_maxs, seeded in func_tracktrain) and this
//  entity overwrites it.
//
//  SCOPE, updated: this file used to map +use onto func_tracktrain_use, i.e.
//  the plain start/stop toggle, because the train had no reverse and no
//  variable speed.  It has both now (sv_func_tracktrain.qc rebuilt on HL's
//  path walk), so what lives here is the real driver: mount, a nine-step
//  throttle on the rising edge of +forward / +back, a movement lock, and HL's
//  four dismount conditions.
//

void() func_tracktrain_use;                                 // sv_func_tracktrain.qc
void(entity train, float delta) FuncTrackTrain_Throttle;     // sv_func_tracktrain.qc
// func_trackvehicle's accelerator ladder — sv_func_trackvehicle.qc, position
// 257, i.e. AFTER this file.  Legal by forward declaration; the .tt_is_vehicle
// FIELD it branches on could not be, which is why that one is declared up in
// sv_func_tracktrain.qc instead.
void(entity veh, float delta) FuncTrackVehicle_Accel;        // sv_func_trackvehicle.qc
void(entity veh, entity driver) FuncTrackVehicle_SetDriver;  // sv_func_trackvehicle.qc

// input_buttons jump bit.  shared/sh_pmove.qc owns the canonical PM_BTN_*
// table but compiles at sv_progs.src:307, well after this file at :189 — the
// same reason sv_chargers.qc keeps its own CHG_BTN_USE copy.  Must stay equal
// to PM_BTN_JUMP (sh_pmove.qc:42).
const float TCTRL_BTN_JUMP = 2;

.entity tctrl_train;        // zone -> train
.entity train_controls;     // train -> zone
.float  tctrl_link_tries;
// Last TRAIN_HUD_* state sent to this player, +1 so that 0 means "nothing sent
// yet" and TRAIN_HUD_OFF (0) is still transmissible.  HL gets the same effect
// from its TRAIN_NEW bit (player.cpp:4254-4263).
.float  tt_hud_sent;

// ---------------------------------------------------------------------------
// HL's TrainSpeed() — player.cpp:322-344.  Quantises the live signed speed
// against the train's authored maximum into the five HUD states.
// ---------------------------------------------------------------------------
float(float spd, float maxspd) TrackTrain_HudState =
{
    if (spd < 0)   return TRAIN_HUD_BACK;
    if (spd == 0)  return TRAIN_HUD_NEUTRAL;
    if (maxspd <= 0) return TRAIN_HUD_FAST;

    float f = spd / maxspd;
    if (f < 0.33) return TRAIN_HUD_SLOW;
    if (f < 0.66) return TRAIN_HUD_MEDIUM;
    return TRAIN_HUD_FAST;
};

// Unicast the readout, but only when it changes — this runs every frame for
// every driver and the state only moves on a throttle tap.
void(entity plyr, float state) TrackTrain_SendHud =
{
    if (plyr.tt_hud_sent == state + 1) return;
    plyr.tt_hud_sent = state + 1;

    // Bots have no netchan; writing to one spams "msg_entity: not a client"
    // every frame.  Same guard sv_platform_carry.qc uses for its view-rot send.
    if (plyr.is_bot) return;
    if (!SV_PlayerHasNetchan(plyr)) return;

    msg_entity = plyr;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_TRAIN_HUD);
    WriteByte(MSG_ONE, state);
};

// ---------------------------------------------------------------------------
// Is `plyr` inside `train`'s control volume?  World -> train-local by
// projecting onto the train's yaw axes, i.e. the inverse yaw rotation.
//
// HL's CFuncTrackTrain::OnControls (plats.cpp:1353-1372) uses the FULL angles
// and negates the right axis.  We use YAW ONLY, deliberately: the control box
// a func_traincontrols supplies is measured with the same yaw-only transform at
// link time, so the two must agree, and a yaw-only test is the more forgiving
// of the two on a pitching train (it cannot rotate the headroom allowance out
// from under a standing player when the train noses down a slope).
//
// Returns FALSE for a train the mapper marked undriveable, which is also the
// runtime effect of a path_track carrying PT_DISABLE_TRAIN — that flag sets
// TT_NO_USERCONTROL on the train as it passes, and this is where the driver
// stops qualifying.  HL checks the same flag in the same place (plats.cpp:1357).
// ---------------------------------------------------------------------------
float(entity plyr, entity train) TrainControls_PlayerInControls =
{
    // func_trackvehicle qualifies too — TrackTrain_IsDriveableClass
    // (sv_func_tracktrain.qc) is the single place that list lives.  th_escape's
    // truck spawns with TT_NO_USERCONTROL set and only clears it from the map
    // script's VehicleStarted(), so this same guard is what keeps the truck
    // undriveable until the engine has actually been repaired and started.
    if (!TrackTrain_IsDriveableClass(train))
        return FALSE;
    if (train.spawnflags & TT_NO_USERCONTROL)
        return FALSE;

    vector lo = train.tt_ctrl_mins;
    vector hi = train.tt_ctrl_maxs;

    vector rel = plyr.origin - train.origin;
    makevectors(train.angles_y * '0 1 0');
    vector lp;
    lp_x = rel * v_forward;
    // NEGATED, and it matters now.  makevectors' v_right is (0,-1,0) at yaw 0 —
    // Quake and Half-Life share that convention — and HL's OnControls therefore
    // writes `local.y = -DotProduct(offset, v_right)` (plats.cpp:1365) so that
    // local y runs the same way world y does, which is the frame SetControls
    // builds the box in.
    //
    // Without the negation the y axis is mirrored.  That was latent while the
    // only box in play was the train's own bounding box, which is near enough
    // symmetric in y on every mover in the corpus; it stops being latent the
    // moment a controls brush supplies a genuinely one-sided box, as
    // th_escape's cab does (local y -46..+7 on a hull that spans -54..+58).
    lp_y = 0 - (rel * v_right);
    lp_z = rel_z;

    // Z is generous the same way the vehicle test is: -8 lets a player standing
    // fractionally below the box still count.  The +72 headroom is already
    // baked into tt_ctrl_maxs at spawn (or into the zone's own bounds).
    return (lp_x >= lo_x     && lp_x <= hi_x
         && lp_y >= lo_y     && lp_y <= hi_y
         && lp_z >= lo_z - 8 && lp_z <= hi_z);
};

// ---------------------------------------------------------------------------
// What tracktrain, if any, is this player standing on?  Same downward probe
// Vehicle_FindMountable uses — the mod's players are MOVETYPE_NONE with custom
// physics, so .groundentity is not a reliable link to a MOVETYPE_PUSH brush.
// ---------------------------------------------------------------------------
entity(entity plyr) TrainControls_TrainUnderfoot =
{
    tracebox(plyr.origin, plyr.mins, plyr.maxs,
             plyr.origin - '0 0 8', MOVE_NORMAL, plyr);
    if (trace_fraction < 1 && TrackTrain_IsDriveableClass(trace_ent))
        return trace_ent;

    // A TT_PASSABLE train is SOLID_NOT and the trace goes straight through it
    // — th_ep1_00's truck has a second, passable brush for its headlight cone.
    // Fall back to the carry latch, which is set by the pmove carry pass and is
    // the authoritative "I am riding this brush" link.
    if (TrackTrain_IsDriveableClass(plyr.platform_carry))
        return plyr.platform_carry;

    return world;
};

void(entity plyr) TrainControls_Dismount =
{
    // Cheap no-op when there is nothing to release.  Load-bearing on the
    // ClientDisconnect path: without it every disconnect would reach
    // TrackTrain_SendHud on a client whose netchan is already going away.
    if (plyr.tt_driving == world && !plyr.pm_ontrain)
        return;

    entity train = plyr.tt_driving;
    if (train != world && !wasfreed(train) && train.tt_driver == plyr)
        train.tt_driver = world;

    plyr.tt_driving  = world;
    plyr.pm_ontrain  = FALSE;
    plyr.tt_in_fwd   = 0;
    plyr.tt_in_side  = 0;
    plyr.tt_prev_fwd = 0;
    TrackTrain_SendHud(plyr, TRAIN_HUD_OFF);

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[traincontrols] %s released the controls\n", plyr.netname));
};

// ---------------------------------------------------------------------------
// +use entry point, called from sv_use.qc.  Returns TRUE if the press was
// consumed.
//
// Mount conditions are HL's, in HL's order (CBasePlayer::PlayerUse,
// player.cpp:1595-1621): a rising-edge +use (which `impulse 11` already is —
// cl_player.qc gates it on the button not being held), the entity you are
// STANDING ON, jump not held, on the ground, and OnControls.
// ---------------------------------------------------------------------------
float(entity plyr) TrainControls_TryUse =
{
    // Already driving — this press releases.
    if (plyr.tt_driving != world)
    {
        TrainControls_Dismount(plyr);
        return TRUE;
    }

    if (plyr.health <= 0) return FALSE;
    if (!(plyr.flags & FL_ONGROUND)) return FALSE;
    // HL refuses the mount while jump is held so that a bunny-hopping player
    // doesn't grab the controls mid-air (player.cpp:1606).
    if (input_buttons & TCTRL_BTN_JUMP) return FALSE;

    entity train = TrainControls_TrainUnderfoot(plyr);

    // A func_traincontrols zone can name a train the player is not standing on
    // (a cab beside the flatbed, say).  Honour the zone as an alternative way
    // to find the candidate, then apply the same qualification below.
    if (train == world)
    {
        entity z = find(world, classname, "func_traincontrols");
        while (z)
        {
            if (z.tctrl_train != world
                && TrainControls_PlayerInControls(plyr, z.tctrl_train))
            {
                train = z.tctrl_train;
                z = world;
                continue;
            }
            z = find(z, classname, "func_traincontrols");
        }
    }

    // Same fallback for the vehicle's own control-zone class.  th_escape's
    // `*470` sits in the cab, forward of the flatbed the player is standing on,
    // so the underfoot probe alone would not find the truck from the driver's
    // seat.
    if (train == world)
    {
        entity zv = find(world, classname, "func_trackvehiclecontrols");
        while (zv)
        {
            if (zv.tctrl_train != world
                && TrainControls_PlayerInControls(plyr, zv.tctrl_train))
            {
                train = zv.tctrl_train;
                zv = world;
                continue;
            }
            zv = find(zv, classname, "func_trackvehiclecontrols");
        }
    }

    if (train == world) return FALSE;
    if (!TrainControls_PlayerInControls(plyr, train)) return FALSE;

    plyr.tt_driving  = train;
    plyr.pm_ontrain  = TRUE;
    plyr.tt_in_fwd   = 0;
    plyr.tt_prev_fwd = 0;
    train.tt_driver  = plyr;

    // CTrackVehicle::SetDriver's throttle blip.  No-ops on a plain
    // func_tracktrain, which has no such sound.
    FuncTrackVehicle_SetDriver(train, plyr);

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[traincontrols] %s took the controls of \"%s\" (max=%g)\n",
                       plyr.netname, train.targetname, train.tt_maxspeed));
    return TRUE;
};

// ---------------------------------------------------------------------------
// Per-frame driver poll, called from PlayerPreThink beside the other held-input
// pollers.  This is CBasePlayer::PreThink's train block (player.cpp:1999-2088).
//
// THE THROTTLE STEPS ON THE RISING EDGE, NOT WHILE HELD.  HL reads
// m_afButtonPressed, so one tap is one quarter step and holding +forward does
// nothing after the first frame.  Nothing in this tree tracked a rising edge for
// forward/back — they exist only as an analogue value in input_movevalues_x —
// so tt_prev_fwd is that tracker.
// ---------------------------------------------------------------------------
void(entity plyr) TrackTrain_DriverTick =
{
    if (plyr.tt_driving == world) return;

    entity train = plyr.tt_driving;

    if (wasfreed(train) || !TrackTrain_IsDriveableClass(train))
    {
        TrainControls_Dismount(plyr);
        return;
    }

    // HL's four eviction conditions (player.cpp:2028-2036):
    //   - left the ground (jumped, or the train dropped away)
    //   - the train stopped being driveable
    //   - strafing
    //   - no longer on/in the controls
    // The TT_NO_USERCONTROL case is the one that matters for hl_c05_a1: passing
    // ridepath20 sets that flag, which throws the player off the controls and
    // hands the throttle to the path_tracks.  That IS the runaway train.
    if (plyr.health <= 0
        || !(plyr.flags & FL_ONGROUND)
        || (train.spawnflags & TT_NO_USERCONTROL)
        || !TrainControls_PlayerInControls(plyr, train))
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[traincontrols] %s evicted (onground=%g nocontrol=%g)\n",
                           plyr.netname, (plyr.flags & FL_ONGROUND) ? 1 : 0,
                           (train.spawnflags & TT_NO_USERCONTROL) ? 1 : 0));
        TrainControls_Dismount(plyr);
        return;
    }

    // Strafing releases the controls in HL, for any non-vehicle train
    // (player.cpp:2033 tests IN_MOVELEFT|IN_MOVERIGHT).
    //
    // NOT for a func_trackvehicle.  Its own PreThink hook
    // (TrackVehicle::VehiclePlayerPreThink, func_trackvehicle.as:1068-1078)
    // forwards IN_MOVELEFT / IN_MOVERIGHT to the throttle as delta 20 and 30,
    // and the throttle's `if (delta < 10)` gate then discards both — so in Sven
    // strafing at the wheel is a NO-OP, not a dismount.  Evicting the driver
    // there would make the truck impossible to hold on to.
    if (plyr.tt_in_side != 0 && !train.tt_is_vehicle)
    {
        TrainControls_Dismount(plyr);
        return;
    }

    // Rising edge on forward / back.  input_movevalues is zeroed by the pmove
    // lock, so the value read here is the one stashed in the real command path
    // (sv_player.qc), the same trick func_vehicle uses.
    float fwd  = plyr.tt_in_fwd;
    float prev = plyr.tt_prev_fwd;
    plyr.tt_prev_fwd = fwd;

    if (train.tt_is_vehicle)
    {
        // WHILE HELD, not on the rising edge.  A tracktrain has nine discrete
        // quarter-step notches so one tap is one notch; a trackvehicle has a
        // continuous accelerator, and VehiclePlayerPreThink calls Use(USE_SET)
        // on EVERY frame the button is down.  Both are driven from the same
        // place in both engines — GoldSrc's CBasePlayer::PreThink and this
        // tree's PlayerPreThink each run once per client usercmd — so the
        // per-call ladder in FuncTrackVehicle_Accel lands at the same cadence
        // it was tuned at.
        if (fwd > 0)
            FuncTrackVehicle_Accel(train, 1);
        else if (fwd < 0)
            FuncTrackVehicle_Accel(train, -1);
    }
    else if (fwd > 0 && prev <= 0)
        FuncTrackTrain_Throttle(train, 1);
    else if (fwd < 0 && prev >= 0)
        FuncTrackTrain_Throttle(train, -1);

    TrackTrain_SendHud(plyr, TrackTrain_HudState(train.speed, train.tt_maxspeed));
};

// ---------------------------------------------------------------------------
// Deferred link.  The train may not exist yet when we spawn — entities are
// created one at a time during map load — so retry like
// func_vehiclecontrols_link does.
//
// Overwrites the train's DEFAULT control box with this brush's bounds,
// transformed into the train's local yaw frame.  HL's SetControls does exactly
// this and then removes the brush; we keep the entity alive because the two
// vectors now live on the train anyway and removing it would break the
// zone-lookup fallback in TryUse.
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

    // CFuncTrackTrain::SetControls, plats.cpp:1344-1350, verbatim:
    //
    //     offset        = pevControls->origin - m_vecOrigin;
    //     m_controlMins = pevControls->mins + offset;
    //     m_controlMaxs = pevControls->maxs + offset;
    //
    // A plain translation into the train's AUTHORED frame.  Two things this
    // used to get wrong:
    //
    //   * it measured against the LIVE origin, i.e. after find_first had
    //     teleported the train onto its first path_track.  Twelve of the
    //     thirteen func_traincontrols in the corpus sit 152-6160 units from
    //     that point, so the override put the control box somewhere the driver
    //     could never stand — and since it REPLACES the sensible default (the
    //     train's own bbox plus headroom), supplying a controls brush made a
    //     train harder to drive than not supplying one.
    //
    //   * it also rotated the box by the train's yaw at link time.  There is no
    //     rotation in SetControls, and there must not be: TrainControls_
    //     PlayerInControls already rotates the PLAYER's offset into the train's
    //     live frame, so rotating the box as well applies the transform twice.
    //     Every func_traincontrols in the corpus is attached to a train authored
    //     at angles 0 0 0, which is why the doubling never looked like anything
    //     other than the origin bug above.
    vector offset = self.origin - train.tt_authored_origin;

    vector lo = self.mins + offset;
    vector hi = self.maxs + offset;

    // Refuse an override that lands nowhere near the train — see
    // TrackTrain_ControlBoxSane.  Loud rather than silent: the train stays
    // driveable via its default box, but the mapper's brush is doing nothing
    // and that is worth saying out loud.
    if (!TrackTrain_ControlBoxSane(train, lo, hi))
    {
        print(sprintf("[traincontrols] \"%s\": control brush is %g units from the "
                      "train hull — ignoring it, keeping the default box\n",
                      train.targetname, rint(vlen((lo + hi) * 0.5))));
        self.tctrl_train = train;      // still usable as a zone-lookup anchor
        return;
    }

    train.tt_ctrl_mins = lo;
    train.tt_ctrl_maxs = hi;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[traincontrols] \"%s\" control box mins=%v maxs=%v (authored org=%v)\n",
                       train.targetname, train.tt_ctrl_mins, train.tt_ctrl_maxs,
                       train.tt_authored_origin));
};

/*QUAKED func_traincontrols (0 .5 .8) ?
Invisible, non-solid control zone for a func_tracktrain.  OVERRIDES the train's
default control volume (its own bbox plus 72 units of headroom); it is not
required in order to drive one.  Stand inside it and press +use to take the
controls, then tap +forward / +back to work the throttle.

"target"   targetname of the func_tracktrain this drives

No spawnflags.  Sven's entity has no targetname either.

PARSED, NOT IMPLEMENTED: the InventoryRules keys (item_name_required,
item_group_required, pass_*, target_on_fail).
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
