//
// sv_func_tracktrain.qc — HL/GoldSrc func_tracktrain brush entity
//
// Path-following brush train that rotates to face its direction of travel as
// it moves.  Walks path_track chains (vs func_train's path_corner chains).
// Aligned via origin brush (mapper places it); the brush model should face -X
// (west) in the editor, which is why the heading gets +180 yaw below — HL does
// the same thing with the comment "The train actually points west".
//
// REWRITTEN ONTO HL'S CONTINUOUS PATH WALK.  The previous version travelled
// node to node: it aimed at the next path_track, and when it got within
// 1.5 ticks of it, `setorigin`'d onto the node and started the next leg.  That
// shape caused three separate reported bugs and none of them could be fixed
// without replacing it:
//
//   1. RIDERS SLID OFF.  Player carry (PM_CheckMovingPushers, shared/sh_pmove.qc)
//      advances a rider by `brush.velocity * pm_frametime` and nothing else.
//      A setorigin moves the train and NOT the rider.  The compensating term
//      (brush_snap_origin_cumulative) is #ifdef CSQC and its counter is only
//      ever written in client/cl_brushsync.qc, so the SERVER never applied it —
//      sh_customdefs.qc says so outright.  At hl_c05_a1's speed 500 and 64 Hz
//      each snap was up to ~11.7 qu of un-carried slip, 28 nodes per ride.
//      HL never teleports a moving tracktrain; neither do we now, and the carry
//      is exact on both sides with no compensation at all.
//   2. NO REVERSE, THEREFORE NO DRIVING.  A driven train runs on a SIGNED
//      speed and walks the chain BACKWARDS when it is negative.  The old
//      forward-only find()-by-name had nowhere to walk back to.
//      sv_path_track.qc now owns the real graph, back-links included.
//   3. PT_DISABLE_TRAIN was implemented as "halt".  It is not; see below.
//
// The walk itself is CPathTrack::LookAhead (dlls/pathcorner.cpp:287-366), ported
// in sv_path_track.qc.  Ask it "where am I `speed * dt` further along the
// polyline?", then set velocity to arrive exactly there in one tick.
//
// DIVERGENCE FROM HL, DELIBERATE: HL re-aims every 0.5 s (plats.cpp:1164, :1266)
// and lets the train coast on a stale velocity in between, which is why HL
// trains visibly cut corners.  We re-aim every FuncTrain_TickInterval() (64 Hz
// by default, sv_func_tickrate).  That tracks the rails more tightly AND keeps
// each velocity valid for exactly one tick, which is what the rider carry needs.
//
// `train_target` IS NOW HL's m_ppath — THE NODE THE TRAIN IS ON / LAST CROSSED,
// not the node it is heading toward.  It used to mean the latter.  The external
// writers (sv_func_trackautochange.qc:209, sv_th_entities.qc:4682) both set it
// to the node a parked train sits on, which is the new meaning, so they are
// correct as written.
//
// What's implemented:
//   - Continuous path walking, forwards and backwards, with PT_DISABLED nodes
//     skipped by the movement walk (and deliberately NOT by the heading look).
//   - Full GoldSrc player driving: +use to mount, tap +forward / +back for a
//     quarter-step throttle over [-max, +max], movement locked while driving,
//     jump / strafe / step-off dismounts.  See sv_func_traincontrols.qc.
//   - PT_DISABLE_TRAIN as HL's "take control away from the driver", which also
//     switches per-node `speed` adoption on — the runaway-train pattern.
//   - Fire-on-pass `message`, cleared PER NODE on PT_FIRE_ONCE.
//   - Dead-end `netname` fire.
//   - Spawn-time orient toward the SECOND track (HL spec).
//   - Engine sound enum (1..6, with the HL idx-5→ttrain6 quirk preserved).
//   - Crush damage via .blocked, with HL's rider-bump exemption.
//   - path_track TELEPORT spawnflag, and Sven's per-node `wait`.
//   - Render modes (shares FuncTrain_ApplyRenderMode).
//
// Not implemented: "bank" (turn-banking roll).  Roll stays 0; see the note at
// the FaceTarget call.
//
// Shared fields with func_train (declared there, visible here because
// sv_func_train.qc compiles first): .train_target, .train_state,
// .train_fire_used, .train_movesound_path, .train_movesound_active,
// .train_stopsound_path, .avelocity_init.
// Helpers (sv_func_train.qc, global QC scope): FuncTrain_TickInterval(),
// FuncTrain_ApplyRenderMode().
// Path graph (sv_path_track.qc, compiles first): PT_* constants,
// PathTrack_LinkAll(), PathTrack_LookAhead(), PathTrack_GetNext/GetPrevious(),
// pathtrack_lookahead_org.
//

const float TT_NO_PITCH       = 1;
const float TT_NO_USERCONTROL = 2;    // HL SF_TRACKTRAIN_NOCONTROL
const float TT_FORWARDS_ONLY  = 4;
const float TT_PASSABLE       = 8;

// PT_* path_track spawnflags used to be duplicated here.  They live in
// sv_path_track.qc now, which compiles first (sv_progs.src:184 vs :188).

// Mapper-facing keys not declared elsewhere.
.float wheels;
.float height;
.float startspeed;
.float bank;
.float sounds;     // func_tracktrain engine sound enum

// HL m_speed: the authored maximum, cached at spawn because `speed` itself
// becomes the LIVE, SIGNED speed the moment the train can be driven.
// plats.cpp:1490-1496 does exactly this, and stashes the same value in
// pev->impulse for the HUD's denominator.
.float tt_maxspeed;
// HL m_dir: which way a plain trigger toggle starts the train.  Flipped by
// nothing today (HL only flips it from func_trackchange), but it is what makes
// `speed = m_speed * m_dir` meaningful.
.float tt_dir;
// HL m_oldSpeed: speed captured at the moment a dead end is detected, so the
// final partial tick can be timed.
.float tt_oldspeed;
// The player currently driving, or world.  Owned by sv_func_traincontrols.qc.
.entity tt_driver;
// Control volume in the train's LOCAL frame (x = forward, y = right, z = up),
// seeded from the brush bounds at spawn and overridden by a func_traincontrols
// if the map supplies one.  HL: plats.cpp:1516-1518.
.vector tt_ctrl_mins;
.vector tt_ctrl_maxs;
// Sven per-node `wait`: speed to restore when the pause ends.
.float tt_waitspeed;

// HL m_vecOrigin / pev->oldorigin: the origin the MAPPER authored, cached at
// spawn before Find() teleports the train onto its first path_track.
//
// This is what a func_traincontrols brush is measured against, and getting it
// wrong is not subtle.  CFuncTrackTrain::SetControls (plats.cpp:1344-1350) does
//
//     offset = pevControls->origin - m_vecOrigin;      <- AUTHORED
//     m_controlMins = pevControls->mins + offset;
//
// i.e. the control box is the controls brush expressed relative to where the
// train was DRAWN, because that is the only frame in which the two are in the
// same place.  Measured against the LIVE origin instead — which is what this
// file used to do — the box lands wherever the gap between the editor position
// and the first path_track happens to be.  Across the corpus that gap is 152 to
// 6160 units on 12 of the 13 func_traincontrols in existence, so the override
// was replacing a usable default box with an unreachable one on all but one map.
.vector tt_authored_origin;

// TRUE on a func_trackvehicle (server/sv_func_trackvehicle.qc, position 257).
// That class is a func_tracktrain with a different THROTTLE and an ignition
// state machine, not a different mover, so it reuses this file's path walk, its
// blocked handler, its dead-end handler and its heading maths wholesale.  The
// flag is the one thing the shared code has to branch on: the vehicle needs its
// own move-think wrapper so the accelerator decay runs, and it must not be
// halted at speed 0 because a running engine keeps idling.
//
// Declared HERE rather than in the vehicle's own file because these two
// functions set the think and they compile first — QC forward-declares
// functions but not fields.
.float tt_is_vehicle;

// Forward decls — defined in sv_func_train.qc / sv_platform_carry.qc.
float() FuncTrain_TickInterval;
void(float mode, float amt) FuncTrain_ApplyRenderMode;
float() Mover_PlatformCarry;
float() Mover_GeometryBlockPush;
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;

// Declared in sv_trigger_logic.qc — TRUE once a live player has reached
// PlayerSpawn.  Gates the startspeed-driven autostart below.

void() func_tracktrain_next;
void() func_tracktrain_deadend;
void() func_tracktrain_use;
void() func_tracktrain_find_first;
void() func_tracktrain_blocked;
void() func_tracktrain_waitdone;
void() func_trackvehicle_next;      // sv_func_trackvehicle.qc

// Which move-think does `self` want?  See .tt_is_vehicle above.  Written as a
// function rather than a ternary because fteqcc's ?: on a function-typed value
// is not something to rely on, and there are only two callers.
void() FuncTrackTrain_SetMoveThink =
{
    if (self.tt_is_vehicle)
        self.think = func_trackvehicle_next;
    else
        self.think = func_tracktrain_next;
};

// ---------------------------------------------------------------------------
// Is a control-zone override worth honouring?
//
// A func_traincontrols brush REPLACES the train's default control volume (its
// own bounding box plus 72 units of headroom), so a brush the mapper left in
// the wrong place does not merely fail to help — it takes away the box that
// would have worked.  Half-Life has the same hole and does not guard it.
//
// One map in the corpus needs the guard.  `infested`'s `entrancetruck1` is a
// 14x56x20 sliver — smaller than a player hull — sitting at world
// 2738 -2783 -156, while the truck it names is drawn at -567 1992 -560:
// FIVE THOUSAND units away, and 560 units from the train's first path_track
// too, so it is not "authored at the destination" either.  It is a leftover
// brush.  Under HL's own maths that map's truck is undriveable, and it was
// equally undriveable under the live-origin maths this file used before.
//
// So: honour the override when it lands anywhere on or near the train's hull,
// and keep the default when it is disjoint.  The four legitimate overrides in
// the corpus all pass — including th_ep1_00's, which sits ON the flatbed roof
// and overlaps the hull by a single unit, which is why the slack is small and
// the test is intersection rather than containment.
//
// `lo`/`hi` and `train.mins`/`maxs` are both in the train's AUTHORED local
// frame; see .tt_authored_origin.
// ---------------------------------------------------------------------------
float(entity train, vector lo, vector hi) TrackTrain_ControlBoxSane =
{
    vector hlo = train.mins - '8 8 8';
    vector hhi = train.maxs + '8 8 8';

    return (lo_x <= hhi_x && hi_x >= hlo_x
         && lo_y <= hhi_y && hi_y >= hlo_y
         && lo_z <= hhi_z && hi_z >= hlo_z);
};

// The two classes the driver code in sv_func_traincontrols.qc will mount.
// One place to add a third, rather than five classname compares.
float(entity e) TrackTrain_IsDriveableClass =
{
    if (e == world)                          return FALSE;
    if (e.classname == "func_tracktrain")    return TRUE;
    if (e.classname == "func_trackvehicle")  return TRUE;
    return FALSE;
};

// HL func_tracktrain engine sound enum.  Index 5 maps to ttrain6.wav
// (note the gap) — preserved verbatim from HL .fgd for asset compat.
string(float idx) FuncTrackTrain_Sound =
{
    if (idx == 1) return "plats/ttrain1.wav";
    if (idx == 2) return "plats/ttrain2.wav";
    if (idx == 3) return "plats/ttrain3.wav";
    if (idx == 4) return "plats/ttrain4.wav";
    if (idx == 5) return "plats/ttrain6.wav";
    if (idx == 6) return "plats/ttrain7.wav";
    return "";
};

// Where the train's ORIGIN belongs for a given path_track.
//
// THE `height` KEY.  In Half-Life m_height is a permanent vertical offset of the
// train's origin above the track it follows, and the path maths is done in track
// space with the offset stripped and re-added around it — CFuncTrackTrain::Next
// does `nextPos.z -= m_height; LookAhead(...); nextPos.z += m_height;`
// (plats.cpp:1186-1198) and ::Find snaps to `pevTarget->origin.z + m_height` at
// spawn (:1390, :1403).  The same sandwich is used in func_tracktrain_next below;
// this helper is the spawn/teleport half.
//
// Without it the train sits exactly `height` units too low: hl_c05_a1's `twain`
// has height 40 on a track at z -1844 (so it rides at -1804) and hl_c07_a1's
// `train` has height 30 on a track at -1352 (should be -1322).
//
// Note `.height` is shared with func_vehicle and func_trackautochange (declared
// twice, here and sv_th_entities.qc:3213) — reading it here is safe, renaming
// it is not.
vector(entity tt, entity pt) FuncTrackTrain_TrackPos =
{
    return pt.origin + '0 0 1' * tt.height;
};

// Compatibility shim.  This used to BE the chain walk — a forward-only
// find()-by-name.  The real graph lives in sv_path_track.qc now, but
// sv_th_entities.qc's func_trackchange calls this by name in two places
// (:4458, :4608) to ask "what is the next node", so it stays as a one-line
// forward to the graph.  Resolving links here rather than assuming them keeps
// func_trackchange working on a map that has no func_tracktrain at all.
entity(entity from) FuncTrackTrain_NextTrack =
{
    if (!from || from == world) return world;
    PathTrack_LinkAll();
    return PathTrack_GetNext(from);
};

// ---------------------------------------------------------------------------
// Engine sound.  HL modulates pitch with speed (plats.cpp:1122-1159); FTE's
// sound() has no pitch argument on this path, so we keep the loop flat and just
// start/stop it.  Deliberately NOT adding HL's ttrain_start1 / ttrain_brake1:
// a precache of a file the user's install may not carry is a hard error, and
// the extra sounds are not what any of the reports asked for.
// ---------------------------------------------------------------------------
void() FuncTrackTrain_StopSound =
{
    if (self.train_movesound_active)
    {
        SV_StopChannel(self, CHAN_BODY);
        self.train_movesound_active = 0;
    }
};

void() FuncTrackTrain_StartSound =
{
    if (self.train_movesound_path != "" && !self.train_movesound_active)
    {
        sound(self, CHAN_BODY, self.train_movesound_path, self.volume, ATTN_NORM);
        self.train_movesound_active = 1;
    }
};

// HL UTIL_AngleDistance — shortest signed distance from `cur` to `next`.
float(float next, float cur) FuncTrackTrain_AngleDistance =
{
    float delta = next - cur;
    if (delta < -180) delta = delta + 360;
    else if (delta > 180) delta = delta - 360;
    return delta;
};

// ---------------------------------------------------------------------------
// Heading.  HL takes a SECOND LookAhead of `wheels` units (m_length, the
// front-axle distance) with move=0, and points the train at it — which is what
// makes a long carriage start swinging into a corner before its origin reaches
// it, and what makes it swing the other way in reverse.
//
// move=0 is not a typo: the heading look must NOT skip PT_DISABLED nodes, or
// disabling a node ahead would snap the train's nose sideways.  See
// PathTrack_ValidPath in sv_path_track.qc.
//
// This replaces the hand-rolled two-segment spill calculation that used to live
// here.  Same intent, but it now works in reverse and past disabled nodes,
// because it is the same walker the movement uses.
// ---------------------------------------------------------------------------
void(entity pnext) FuncTrackTrain_FaceTravel =
{
    vector nextFront = self.origin;
    nextFront_z = nextFront_z - self.height;

    float look = self.wheels;
    if (look <= 0) look = 100;                 // HL's fallback, plats.cpp:1197
    // Look BACKWARDS down the track when reversing, so the nose leads the way
    // it is actually going.  HL gets this for free because m_ppath tracks the
    // travel direction; we pass the sign explicitly.
    if (self.speed < 0) look = -look;

    PathTrack_LookAhead(self.train_target, nextFront, look, 0);
    nextFront = pathtrack_lookahead_org;
    nextFront_z = nextFront_z + self.height;

    vector delta = nextFront - self.origin;

    // HL: if the path ran out, or the horizontal delta is degenerate, keep the
    // angles we already have rather than snapping to something meaningless
    // (plats.cpp:1209-1210).
    if (pnext == world || (delta_x == 0 && delta_y == 0))
        return;

    if (self.spawnflags & TT_NO_PITCH)
        delta_z = 0;
    if (vlen(delta) < 0.01)
        return;

    vector new_angles = vectoangles(delta);
    if (self.spawnflags & TT_NO_PITCH)
        new_angles_x = 0;
    // bank-on-turns not implemented; pin roll.  HL drives pev->avelocity.z from
    // m_flBank here (plats.cpp:1222-1230); we write angles directly rather than
    // through avelocity, so banking would need its own approach-angle state.
    new_angles_z = 0;

    // +180 YAW.  Not a hack — Half-Life does exactly this, with the comment
    // "The train actually points west", in CFuncTrackTrain::Next() right after
    // its UTIL_VecToAngles call (plats.cpp:1202-1203).  GoldSrc func_tracktrain
    // brushes are modelled facing -X, so a raw vectoangles() of the direction of
    // travel points the model's tail down the track: th_ep1_00's intro truck
    // drove the whole route backwards, boot first.
    //
    // Unconditional rather than GoldSrc-gated, because func_tracktrain IS a
    // GoldSrc-compat entity — no map in quakers/maps places one, so there is no
    // native authoring convention to preserve.
    new_angles_y = new_angles_y + 180;

    self.angles = new_angles;
};

// ---------------------------------------------------------------------------
// Begin / end motion.  Publishing to moving_brush_list is what lets
// PM_CheckMovingPushers's train branch run the carry each pmove substep, on
// both the server and the client predictor.
// ---------------------------------------------------------------------------
void() FuncTrackTrain_BeginMotion =
{
    self.train_state = 1;
    FuncTrackTrain_StartSound();
    MovingBrush_AddToList(self);
    FuncTrackTrain_SetMoveThink();
    self.nextthink = self.ltime + FuncTrain_TickInterval();
};

void() FuncTrackTrain_HaltMotion =
{
    self.velocity               = '0 0 0';
    self.avelocity              = '0 0 0';
    self.mover_planned_velocity = '0 0 0';
    self.train_state            = 0;
    // Tell CSQC we stopped.  Without this the client's newest snapshot still
    // carries the old velocity and the replica keeps projecting off it;
    // PVSF_NOREMOVE means no PVS-re-entry resend will correct it.
    self.SendFlags              = 1;
    FuncTrackTrain_StopSound();
    MovingBrush_RemoveFromList(self);
};

// ---------------------------------------------------------------------------
// CFuncTrackTrain::DeadEnd — plats.cpp:1298-1341.  Walk to the true terminal
// node and fire its `netname`.  28 path_tracks across 11 maps set it; nothing
// read it before.
// ---------------------------------------------------------------------------
void() func_tracktrain_deadend =
{
    entity pTrack = self.train_target;
    entity pnext;
    float iter = 0;

    FuncTrackTrain_HaltMotion();
    self.speed = 0;

    // Find the end of the line in whichever direction we were travelling.
    if (pTrack != world)
    {
        if (self.tt_oldspeed < 0)
        {
            pnext = PathTrack_GetPrevious(pTrack);
            while (pnext != world && iter < 512)
            {
                iter = iter + 1;
                pTrack = pnext;
                pnext  = PathTrack_GetPrevious(pTrack);
            }
        }
        else
        {
            pnext = PathTrack_GetNext(pTrack);
            while (pnext != world && iter < 512)
            {
                iter = iter + 1;
                pTrack = pnext;
                pnext  = PathTrack_GetNext(pTrack);
            }
        }
    }

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] dead end at \"%s\" netname=\"%s\"\n",
                       self.targetname,
                       pTrack != world ? pTrack.targetname : "",
                       pTrack != world ? pTrack.netname : ""));

    if (pTrack != world && pTrack.netname != "")
    {
        string saved_target = pTrack.target;
        pTrack.target = pTrack.netname;

        entity oldself = self;
        self = pTrack;
        sub_use_type = USE_TOGGLE;
        Trigger_UseTargets(self, oldself);
        self = oldself;

        pTrack.target = saved_target;
        sub_use_type = USE_UNSET;
    }
};

// Sven per-node `wait` — resume after the pause.
//
// Every one of the 36 `wait` keys on a path_track in the whole corpus is the
// value "0", so this path is effectively dead map data; it is implemented
// anyway because a 0 is indistinguishable from absent and a mapper writing a
// real one should get what the FGD promises.
void() func_tracktrain_waitdone =
{
    self.speed = self.tt_waitspeed;
    self.tt_waitspeed = 0;
    if (self.speed == 0)
    {
        FuncTrackTrain_HaltMotion();
        return;
    }
    FuncTrackTrain_BeginMotion();
};

// ---------------------------------------------------------------------------
// CFuncTrackTrain::Next — plats.cpp:1162-1295.  The whole movement tick.
// ---------------------------------------------------------------------------
// Diagnostic only: how many move ticks this train has actually been given.
// Compared against elapsed time it says whether a slow train is being starved of
// ticks or being given ticks that move it too little.  See the cross dprint.
.float tt_ticks;
.float tt_blocks;

void() func_tracktrain_next =
{
    float tick_dt = FuncTrain_TickInterval();
    self.tt_ticks = self.tt_ticks + 1;

    // HL bails on a zero speed and on a lost path (plats.cpp:1166-1180).  Both
    // are real states here: the throttle can land exactly on 0, and a
    // killtarget can take the chain out from under us.
    if (self.speed == 0)
    {
        FuncTrackTrain_HaltMotion();
        return;
    }
    if (self.train_target == world)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] lost path\n", self.targetname));
        FuncTrackTrain_HaltMotion();
        return;
    }

    // --- where will we be one tick from now? -------------------------------
    // The -= / += height sandwich is HL's: the path maths runs in TRACK space,
    // and the train's origin rides `height` above it.
    vector nextPos = self.origin;
    nextPos_z = nextPos_z - self.height;
    entity pnext = PathTrack_LookAhead(self.train_target, nextPos, self.speed * tick_dt, 1);
    nextPos = pathtrack_lookahead_org;
    nextPos_z = nextPos_z + self.height;

    if (pnext != world)
    {
        // NO setorigin.  Velocity only — this is the whole rider fix.  The
        // engine integrates exactly one tick of it before we run again, so the
        // train lands on nextPos and the carried player advances by the same
        // vector through PM_CheckMovingPushers.
        self.velocity               = (nextPos - self.origin) * (1 / tick_dt);
        self.mover_planned_velocity = self.velocity;

        FuncTrackTrain_FaceTravel(pnext);

        // --- crossing onto a new node --------------------------------------
        if (pnext != self.train_target)
        {
            // HL fires the node we are moving INTO when going forwards, and the
            // one we are leaving when going backwards (plats.cpp:1236-1241), so
            // a pass-target fires at the same physical place either way.
            entity pFire = (self.speed >= 0) ? pnext : self.train_target;

            // `lag` is time - ltime, and it is the number that tells a slow train
            // apart from a slow SERVER.  A MOVETYPE_PUSH brush advances by
            // min(host_frametime, nextthink - ltime) per frame, so if the server's
            // frame is longer than the mover tick this file schedules, the brush
            // moves one tick per frame and travels at speed * tick * fps - i.e.
            // proportionally slow, with the shortfall showing up here as a lag that
            // grows.  A steady lag means the train really is doing `speed`.
            if (cvar("sv_debug_func_train"))
            {
                dprint(sprintf("[tracktrain %s] cross \"%s\" -> \"%s\" speed=%g org=%v\n",
                               self.targetname, self.train_target.targetname,
                               pnext.targetname, self.speed, self.origin));
                // Split off its own line because sprintf takes at most 8 varargs.
                dprint(sprintf("[tracktrain %s]   t=%g ltime=%g ticks=%g iv=%g measft=%g blk=%g\n",
                               self.targetname, time, self.ltime, self.tt_ticks,
                               tick_dt, sv_mover_frame_interval, self.tt_blocks));
            }

            self.train_target = pnext;

            // Fire on pass.  Swap-restore around Trigger_UseTargets, which only
            // reads caller.target — same pattern func_train uses.
            //
            // ORDER MATTERS AND IT USED TO BE WRONG: this fires BEFORE the
            // PT_DISABLE_TRAIN handling below.  The old code returned out of the
            // function on DISABLE_TRAIN before ever reaching the message, so a
            // node carrying both flags silently lost its pass-target.
            if (pFire.message != "")
            {
                string saved_target = pFire.target;
                pFire.target = pFire.message;

                entity oldself = self;
                self = pFire;
                sub_use_type = USE_TOGGLE;
                Trigger_UseTargets(self, oldself);
                self = oldself;

                pFire.target = saved_target;
                sub_use_type = USE_UNSET;

                // PER-NODE latch, by clearing that node's message exactly as HL
                // does (plats.cpp:1247-1248).  The old code set one bit on the
                // TRAIN instead, so the first FIRE_ONCE node on a route
                // permanently muted every other FIRE_ONCE node on it.  53 nodes
                // across 8 maps set this flag.
                if (pFire.spawnflags & PT_FIRE_ONCE)
                    pFire.message = "";
            }

            // PT_DISABLE_TRAIN DOES NOT STOP THE TRAIN.  It takes control away
            // from the driver and hands speed authority to the path_tracks —
            // the runaway-train pattern (plats.cpp:1251-1252).
            //
            // Implementing it as a halt is what stranded hl_c05_a1: ridepath20
            // carries this flag, the train stopped dead there, and gatesmash /
            // horse1 / horse2 / stopbars — the breakable wall and the ejector
            // trigger_pushes — were never reached.  19 nodes across 8 maps set
            // it, th_ep1_00 among them.
            if (pFire.spawnflags & PT_DISABLE_TRAIN)
                self.spawnflags = self.spawnflags | TT_NO_USERCONTROL;

            // Per-node speed, ONLY while under path control (plats.cpp:1255).
            // A driver's throttle outranks the map's authored speeds; that is
            // the point of the gate, and the old code adopted node speeds
            // unconditionally.  A 0 is "uninitialised", not "stop" (:1257).
            if (self.spawnflags & TT_NO_USERCONTROL)
            {
                if (pFire.speed != 0)
                {
                    self.speed = pFire.speed;
                    if (cvar("sv_debug_func_train"))
                        dprint(sprintf("[tracktrain %s] \"%s\" sets speed %g\n",
                                       self.targetname, pFire.targetname, self.speed));
                }
            }

            // Sven extension: pause here.
            if (pFire.wait > 0)
            {
                self.tt_waitspeed           = self.speed;
                self.speed                  = 0;
                self.velocity               = '0 0 0';
                self.mover_planned_velocity = '0 0 0';
                self.SendFlags              = 1;
                self.think                  = func_tracktrain_waitdone;
                self.nextthink              = self.ltime + pFire.wait;
                return;
            }

            // Sven extension: snap onto this node.  This IS a teleport and it is
            // the only one left in the movement path — it is what the flag
            // means.  No map in the corpus sets it.
            if (pFire.spawnflags & PT_TELEPORT)
            {
                setorigin(self, FuncTrackTrain_TrackPos(self, pFire));
                self.velocity               = '0 0 0';
                self.mover_planned_velocity = '0 0 0';
            }
        }

        // Dirty the brushsync wire so CSQC sees the updated origin / angles /
        // velocity every tick — see sv_func_train.qc for the full reasoning.
        // Without this the train was visually frozen on clients even though it
        // moved server-side.
        self.SendFlags = 1;

        FuncTrackTrain_SetMoveThink();
        self.nextthink = self.ltime + tick_dt;
        return;
    }

    // --- end of path (plats.cpp:1268-1293) ---------------------------------
    // Coast the remaining fraction of a tick at the current speed, then run the
    // dead-end handler.  `nextPos` is where the walk gave up, which is the last
    // reachable point on the chain.
    FuncTrackTrain_StopSound();
    vector remain = nextPos - self.origin;
    self.avelocity = '0 0 0';
    float distance = vlen(remain);
    self.tt_oldspeed = self.speed;
    self.speed = 0;

    if (distance > 0)
    {
        float travel_speed = fabs(self.tt_oldspeed);
        self.velocity               = remain * (travel_speed / distance);
        self.mover_planned_velocity = self.velocity;
        self.SendFlags              = 1;
        self.think     = func_tracktrain_deadend;
        self.nextthink = self.ltime + (distance / travel_speed);
        return;
    }

    func_tracktrain_deadend();
};

// ---------------------------------------------------------------------------
// CFuncTrackTrain::Use, USE_SET branch — plats.cpp:1055-1069.  The driver's
// throttle, called from sv_func_traincontrols.qc on a +forward / +back tap.
//
// `delta` is +1 or -1.  The arithmetic is HL's verbatim, and the integer
// division is load-bearing: it quantises the current speed onto quarter steps
// of the maximum before adding the step, so the throttle has exactly nine
// states (-1, -0.75 ... 0 ... +0.75, +1) regardless of what a path_track may
// have set the speed to in the meantime.
// ---------------------------------------------------------------------------
void(entity train, float delta) FuncTrackTrain_Throttle =
{
    if (train.tt_maxspeed <= 0) return;

    // HL: ((int)(pev->speed * 4) / (int)m_speed) * 0.25 + 0.25 * delta
    // QC has no integer division; floor() toward zero on the quotient is the
    // same thing for both signs because C truncates toward zero.
    float q = (train.speed * 4) / train.tt_maxspeed;
    if (q >= 0) q = floor(q);
    else        q = ceil(q);

    float frac = q * 0.25 + 0.25 * delta;

    if (frac > 1)       frac = 1;
    else if (frac < -1) frac = -1;

    // FORWARDS_ONLY clamps the reverse half away entirely (plats.cpp:1064-1067).
    if (train.spawnflags & TT_FORWARDS_ONLY)
    {
        if (frac < 0) frac = 0;
    }

    train.speed = train.tt_maxspeed * frac;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] throttle %g -> frac=%g speed=%g\n",
                       train.targetname, delta, frac, train.speed));

    entity oldself = self;
    self = train;
    if (train.speed == 0)
        FuncTrackTrain_HaltMotion();
    else if (train.train_state == 0)
        FuncTrackTrain_BeginMotion();
    self = oldself;
};

// ---------------------------------------------------------------------------
// CFuncTrackTrain::Use, trigger branch — plats.cpp:1035-1053.
// ---------------------------------------------------------------------------
void() func_tracktrain_use =
{
    // Lazy first-stop init if find_first hasn't run yet.
    if (self.train_target == world && self.target != "")
    {
        func_tracktrain_find_first();
        if (self.train_target == world)
            return;
    }

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] use state=%g useType=%g at=\"%s\" speed=%g\n",
                       self.targetname, self.train_state, sub_use_type,
                       self.train_target ? self.train_target.targetname : "",
                       self.speed));

    // HL's CBaseToggle::ShouldToggle — an explicit ON to a moving train, or an
    // explicit OFF to a stopped one, is a NO-OP, not a toggle.
    //
    // This guard is finally trustworthy.  USE_OFF is 0 and "nobody set a use
    // type" used to be 0 as well, so every explicit Off arrived here as
    // USE_TOGGLE — see the USE_UNSET note in sv_customdefs.qc.  That is exactly
    // why th_ep1_00's `roadratmngr` could not stop the truck for its headcrab.
    if (sub_use_type == USE_ON  && self.train_state != 0) return;
    if (sub_use_type == USE_OFF && self.train_state == 0) return;

    if (self.train_state == 0)
    {
        // Start.  HL sets the live speed from the cached maximum and its
        // direction, then runs Next() — it does NOT advance the path cursor,
        // because m_ppath is where the train IS and LookAhead walks from there.
        // The old code advanced train_target by one node here, which under the
        // new (HL) meaning of the field would skip a node on every restart.
        self.speed = self.tt_maxspeed * (self.tt_dir ? self.tt_dir : 1);
        if (self.speed == 0)
        {
            if (cvar("sv_debug_func_train"))
                dprint(sprintf("[tracktrain %s] use start with zero max speed\n",
                               self.targetname));
            return;
        }
        FuncTrackTrain_BeginMotion();
        return;
    }

    // Triggered while moving — HL stops the train.  Re-trigger restarts via the
    // state==0 path above.
    //
    // THE STOP NOW STICKS.  It used to not: this zeroed velocity and
    // train_state but could not cancel the already-scheduled move tick, which
    // re-armed velocity ~1/64 s later and carried on with train_state reading
    // 0.  A guard against that was tried and reverted because it stalled
    // th_ep1_00's intro — but the real cause of that stall was the USE_OFF
    // clobber above, not the guard.  FuncTrackTrain_HaltMotion zeroes the speed
    // too, so even a stray pending think finds `speed == 0` and bails.
    self.speed = 0;
    FuncTrackTrain_HaltMotion();
};

void() func_tracktrain_blocked =
{
    self.tt_blocks = self.tt_blocks + 1;    // diagnostic; see the cross dprint
    if (!other) return;

    // A BLOCKED MOVETYPE_PUSH BRUSH FREEZES: the engine backs the move out and
    // does not advance .ltime, and every think here is scheduled on ltime — so
    // the train stops for good rather than for a moment.  Worth a loud
    // diagnostic, because from the outside it looks identical to "the path
    // walk gave up" and the two have completely different causes.
    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] BLOCKED by %s (health=%g) at %v\n",
                       self.targetname, other.classname, other.health, self.origin));

    // HL exempts anything STANDING ON the train: a rider who momentarily
    // reports as blocking gets a small upward nudge instead of 1500 crush
    // damage (plats.cpp:1008-1014).  Without this branch, hl_c05_a1's `twain`
    // (dmg 1500) instantly kills the passenger it is supposed to be carrying
    // the moment the carry trace and the pusher disagree for one frame.
    if ((other.flags & FL_ONGROUND) && other.groundentity == self)
    {
        float deltaSpeed = fabs(self.speed);
        if (deltaSpeed > 50) deltaSpeed = 50;
        if (!other.velocity_z)
            other.velocity_z = other.velocity_z + deltaSpeed;
        return;
    }

    if (self.dmg <= 0) return;
    if (other.cutscene_immune) return;

    // SHOVE FIRST, THEN DAMAGE — HL's order (plats.cpp:1022-1027).  The shove is
    // not decoration: a blocked MOVETYPE_PUSH brush freezes (see above), so if
    // the blocker is not removed from the path the train never moves again.
    vector away = other.origin - self.origin;
    away_z = 0;
    if (vlen(away) > 0.01)
    {
        away = normalize(away);
        other.velocity_x = away_x * self.dmg;
        other.velocity_y = away_y * self.dmg;
        other.velocity_z = other.velocity_z + 300;
    }

    // W_ApplyDamage, NOT a raw `other.health -= self.dmg`.
    //
    // The raw path was the whole reason hl_c05_a1's ride died halfway.  It
    // subtracts health and nothing else — no death, no gib, no unlink — so a
    // monster that wanders onto the track is driven to absurd negative health
    // and STAYS SOLID IN THE PATH.  Measured before this change: a
    // monster_houndeye at ridepath15 reached health -5,300,000, still being
    // decremented every frame, with the train frozen against it for the rest of
    // the map.  HL calls TakeDamage here (plats.cpp:1027) precisely so the
    // blocker dies and stops blocking.
    //
    // W_ApplyDamage is the mod's damage chokepoint and decides takedamage for
    // itself — sv_platform_carry.qc:164-166 makes the same call for the same
    // reason, noting that players are DAMAGE_NO in this tree so an early
    // takedamage test would wrongly skip them.
    W_ApplyDamage(self, other, self.dmg);
};

// ---------------------------------------------------------------------------
// CFuncTrackTrain::Find — plats.cpp:1375-1409.  Snap to the first track, orient
// toward the SECOND (HL spec: "orient itself to face the second path_track"),
// then apply startspeed.
// ---------------------------------------------------------------------------
// Placement half of Find, split out so it can be forced EARLY and run at most
// once.  Returns TRUE when .origin is on the track.
//
// The split exists because the snap is observable by other entities before the
// deferred think gets to it.  A tracktrain's authored `origin` is its origin
// BRUSH, which mappers routinely park in a closet nowhere near the track:
// hl_c00's `train` is authored at -3046 -2635 -2516 and belongs at
// 2983 2836 453, 6000 units away.  Anything that measures against the train in
// that window measures against the closet.
//
// hl_c00 does exactly that.  Its three trigger_setorigin followers are switched
// on by a trigger_auto at t+0.2 and capture a Lock Offsets gap on their first
// pass; this think runs on .ltime, which trails `time` by the map's first few
// frames, so the capture landed at t+0.2 and the snap at t+0.24.  The 6000-unit
// closet offset was baked into the lock, and since the spawn points ride those
// followers the player spawned at 9045 8339 3470 — outside the world, where
// nothing draws.  Ordering can't be tuned into correctness here, so the
// dependency is made explicit instead: see Mover_EnsureSpawnPlacement.
float() FuncTrackTrain_PlaceOnTrack =
{
    if (self.train_target != world)
        return TRUE;                    // already placed

    if (self.target == "")
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] no first stop target; staying at brush origin=%v\n",
                           self.targetname, self.origin));
        return FALSE;
    }

    // Resolve the path graph before anything walks it.  Idempotent and cheap;
    // this is the first consumer that needs it.
    PathTrack_LinkAll();

    entity pt = find(world, targetname, self.target);
    if (pt == world || pt.classname != "path_track")
    {
        dprint(sprintf("func_tracktrain \"%s\": first stop \"%s\" not found\n",
                       self.targetname, self.target));
        return FALSE;
    }

    setorigin(self, FuncTrackTrain_TrackPos(self, pt));
    self.train_target = pt;
    self.train_state  = 0;
    // MANDATORY.  The only snapshot the client has is the one queued by
    // SV_InitReplicatedSolidBrush at the end of the spawn frame — i.e. at the
    // EDITOR position, before this teleport.  pvsflags = PVSF_NOREMOVE means
    // there is no PVS-re-entry resend either, and the wire is otherwise only
    // re-dirtied from the move tick.  So a train that spawns and doesn't
    // immediately move stays visible at its pre-snap position forever, which
    // is why th_ep1_00's intro truck never appeared.
    self.SendFlags = 1;

    // Face the second track on spawn.  Temporarily pretend to be moving
    // forwards so FuncTrackTrain_FaceTravel looks the right way.
    entity second = PathTrack_GetNext(pt);
    if (cvar("sv_debug_func_train"))
    {
        // Both origins, because the whole point of `height` is that they differ:
        // track= is where the path_track sits, placed= is where the train's
        // origin now rides, and placed_z - track_z must equal height.
        //
        // Split across two prints: fteqcc warns past 8 varargs and SILENTLY
        // DROPS the rest, which is the same trap AI_ReportStats documents.
        dprint(sprintf("[tracktrain %s] first=\"%s\" track=%v placed=%v height=%g\n",
                       self.targetname, pt.targetname, pt.origin, self.origin, self.height));
        dprint(sprintf("             second=\"%s\" flags=%g max=%g startspeed=%g\n",
                       second != world ? second.targetname : "",
                       self.spawnflags, self.tt_maxspeed, self.startspeed));
    }
    if (second != world)
    {
        float saved_speed = self.speed;
        self.speed = 1;                        // "forwards" for the heading look
        FuncTrackTrain_FaceTravel(second);
        self.speed = saved_speed;
    }
    return TRUE;
};

void() func_tracktrain_find_first =
{
    if (!FuncTrackTrain_PlaceOnTrack())
        return;

    // GoldSrc compatibility autostart.  HL maps that begin with the player
    // already aboard a moving train (chapter intros, c0a0a's intro_train, etc.)
    // rely on either trigger_auto firing the train or the engine restoring its
    // previous-map .globalname state mid-motion.  Quake-style level transitions
    // don't carry entity state across maps and these maps rarely include a
    // trigger_auto — so the train sits motionless at its first path_track
    // instead of rolling away.
    //
    // Heuristic: if `startspeed` is non-zero, the mapper authored this train to
    // be moving at spawn.  Mappers who want a strictly stop-at-spawn train just
    // leave startspeed at 0 (the default), so this can't regress static-on-spawn
    // tracktrains.
    if (self.startspeed > 0 && self.train_state == 0)
    {
        // sv_waitforplayer: defer the autostart until a live player has spawned,
        // so an intro train on a listen server doesn't roll away before the
        // local user even joined a team.  Re-runs find_first in a short loop
        // until the gate releases.
        if (cvar("sv_waitforplayer") && !sv_first_player_spawned)
        {
            if (cvar("sv_debug_func_train"))
                dprint(sprintf("[tracktrain %s] autostart deferred — waiting for first player\n",
                               self.targetname));
            self.think     = func_tracktrain_find_first;
            self.nextthink = self.ltime + 0.25;   // .ltime — see the spawn comment
            return;
        }

        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] startspeed autostart speed=%g\n",
                           self.targetname, self.startspeed));

        // HL's Find() sets pev->speed = m_startSpeed and hands off to Next()
        // (plats.cpp:1406-1408).  Going through .use() instead would run the
        // ShouldToggle guard against a stale global use type, which is the
        // autostart failure this comment used to document.
        self.speed = self.startspeed;
        FuncTrackTrain_BeginMotion();
    }
};

/*QUAKED func_tracktrain (0 .5 .8) ? TT_NO_PITCH TT_NO_USERCONTROL TT_FORWARDS_ONLY TT_PASSABLE
HL/GoldSrc-style path-following brush train that auto-orients to face its
direction of travel.  Driveable: stand on it and press +use, then tap
+forward / +back to change speed (nine quarter steps from full reverse to full
forward).  Jumping, strafing or stepping off releases the controls.

"target"      First-stop path_track targetname.
"speed"       Max speed (units/sec, default 100).  The live speed is signed.
"startspeed"  Speed at map start (default 0 = parked).
"wheels"      Front-wheel lookahead distance; steers into corners early (HL m_length).
"height"      How far the train's origin rides ABOVE the track (HL m_height).
"dmg"         Crush damage on .blocked (default 2).  Riders are exempt.
"sounds"      Engine sound enum 1..6.
"volume"      Engine sound volume 0-10 (default 8.5).
"bank"        Turn-banking degrees (NOT IMPLEMENTED — roll stays 0).
"rendermode"  0=normal, 1=color, 2=texture, 3=glow, 4=solid, 5=additive.
"renderamt"   Alpha 0..255 for non-normal render modes.
"rendercolor" RGB for rendermode=1.

TT_NO_PITCH       Lock pitch to 0 (yaw-only rotation).
TT_NO_USERCONTROL Not driveable.  Also switches ON per-path_track `speed`
                  adoption — a path_track with DISABLE_TRAIN sets this flag at
                  runtime, which is the GoldSrc runaway-train pattern.
TT_FORWARDS_ONLY  Throttle clamps at 0; no reverse.
TT_PASSABLE       Train doesn't block players.
*/
void() func_tracktrain =
{
    if (self.speed == 0)      self.speed      = 100;
    // HL caches the authored speed as m_speed and zeroes the live one
    // (plats.cpp:1490-1496): a tracktrain is always parked at spawn, and
    // Find() applies startspeed afterwards.  NO `startspeed` default — it used
    // to fall back to `speed`, which made the autostart test always true and
    // contradicted its own comment.
    self.tt_maxspeed = self.speed;
    self.speed       = 0;
    self.tt_dir      = 1;

    if (self.wheels == 0)     self.wheels     = 100;
    if (self.dmg == 0)        self.dmg        = 2;
    // func_tracktrain's `volume` is 0-10 in the FGD ("Volume (10 = loudest)",
    // default 10), NOT the 0.0-1.0 that func_train's PlatSounds base uses.
    // sound() wants 0-1, so anything above 1 is a 0-10 authored value and gets
    // scaled.  All 7 tracktrains across the target maps store exactly 10,
    // which was being passed to sound() raw.
    //
    // The >1 test rather than an unconditional /10 is deliberate: it keeps
    // working if a mapper writes a 0-1 value by hand, and it is the same shape
    // sv_rotating.qc already uses.
    if (self.volume > 1)      self.volume     = bound(0, self.volume / 10, 1);
    if (self.volume == 0)     self.volume     = 0.85;

    if (cvar("sv_debug_func_train"))
    {
        dprint(sprintf("[tracktrain %s] spawn target=\"%s\" max=%g startspeed=%g flags=%g\n",
                       self.targetname, self.target, self.tt_maxspeed, self.startspeed,
                       self.spawnflags));
        dprint(sprintf("             height=%g wheels=%g origin=%v\n",
                       self.height, self.wheels, self.origin));
    }

    // Wire through brushsync so CSQC predicts our motion + the platform-carry /
    // geometry-push pass (sv_func_train.qc has the long-form comment for why).
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;
    // NO PVSF_IGNOREPVS HERE.  It was tried, to keep the snapshot stream
    // gap-free while a cutscene camera watches the train from thousands of
    // units away (PVSF_NOREMOVE only suppresses the removal event; it does NOT
    // keep updates flowing outside the PVS).  It works, but it also networks
    // the train unconditionally, and the CSQC replica then draws wherever it is
    // -- th_ep1_00's truck and its TT_PASSABLE headlight brush became visible
    // THROUGH the level geometry from the spawn room.
    //
    // The gap is now handled on the client instead: cl_brushsync.qc caps
    // extrapolation at 0.1 s, so a PVS drop-out costs at most ~13 units of
    // drift at 240 qu/s and the replica holds near the last authoritative
    // sample rather than coasting off the road.
    if (self.spawnflags & TT_PASSABLE)
        self.solid = SOLID_NOT;

    // Default driver control volume — the train's own bounds with 72 units of
    // headroom (plats.cpp:1516-1518).  HL's func_traincontrols is an OVERRIDE,
    // not a requirement, and having no default here is why hl_c05_a1's `twain`
    // (which ships without a controls brush) could never be driven.
    self.tt_ctrl_mins = self.mins;
    self.tt_ctrl_maxs = self.maxs;
    self.tt_ctrl_maxs_z = self.tt_ctrl_maxs_z + 72;

    // Engine sound enum → path resolution + precache.
    self.train_movesound_path = FuncTrackTrain_Sound(self.sounds);
    if (self.train_movesound_path != "")
        precache_sound(self.train_movesound_path);

    // Cache the editor position BEFORE find_first teleports us onto the track.
    // HL's Spawn does the same thing into pev->oldorigin (plats.cpp:1519).
    self.tt_authored_origin = self.origin;

    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    self.use     = func_tracktrain_use;
    self.blocked = func_tracktrain_blocked;

    self.think     = func_tracktrain_find_first;
    // .ltime, not time.  This is MOVETYPE_PUSH: the engine starts the map with
    // physicstime 1.0 / sv.time 1.1 and a pusher's .ltime stays frozen until
    // its first think, so `time + 0.1` here actually fires ~1.2s late.
    self.nextthink = self.ltime + 0.1;
};

// ---------------------------------------------------------------------------
// Mover_EnsureSpawnPlacement — force a path-following brush onto its first
// node NOW, if its deferred think hasn't got there yet.
//
// Both train classes spawn at their origin-brush position and snap onto their
// path from a think, because the path nodes may not exist while the entity
// list is still being spawned.  That leaves a window in which .origin is the
// editor position, and any entity that MEASURES a train (rather than just
// riding it) reads a value that is about to change out from under it.
//
// Rather than tune the two think times against each other — they run off
// different clocks (.ltime for a pusher, `time` for a trigger_auto), so the
// margin is not something a constant can hold — the consumer states the
// dependency and pays for it.  Idempotent, so calling it from several places
// costs one branch after the first.
//
// This lives here, at the end of the last mover file, so both classes'
// placement functions are already in scope.  func_train's find_first is
// already self-guarding (train_target == world), and func_tracktrain's
// placement half was split out of Find for exactly this call.
// ---------------------------------------------------------------------------
void(entity e) Mover_EnsureSpawnPlacement =
{
    if (!e || e == world || e.train_target != world || e.target == "")
        return;

    entity oldself = self;
    self = e;
    // func_trackvehicle included: it is placed by the same FuncTrackTrain_PlaceOnTrack,
    // and th_escape parks its truck's origin brush well off the track the same
    // way hl_c00 parks its tram's.
    if (TrackTrain_IsDriveableClass(e))
        FuncTrackTrain_PlaceOnTrack();
    else if (e.classname == "func_train")
        func_train_find_first();
    self = oldself;
};
