//
//  sv_func_trackvehicle.qc — Sven Co-op th_escape's drivable truck
//
//      func_trackvehicle          the vehicle
//      func_trackvehiclecontrols  the cab you stand in to drive it
//
//  "This is a vehicle that drives on path_tracks like a tracktrain, but is
//   controlled like a vehicle."  — the header of the original.
//
//  SOURCE.  Map-local AngelScript, not a stock Sven entity:
//      svencoop/scripts/maps/th_escape/func_trackvehicle.as   (1116 lines)
//  by Sam "Solokiller" Vanheer, modified by Tomas "GeckoN" Slavotinek.  There
//  is no `vehicle` of any spelling anywhere in sven-coop.fgd — zero hits across
//  its 7054 lines — and no wiki page.  The .as is the entire specification, and
//  it was read line by line rather than reasoned about from the classname.
//
//  WHY IT MATTERS.  th_escape places exactly one, `veh1_drivable`, and it is the
//  map: the whole objective is to find a battery, a gas can and a toolbox,
//  repair the truck, start it and drive it out before the timer runs down.  With
//  no spawn function the truck was an inert brush and the map had no ending.
//
//  WHAT THIS FILE IS AND IS NOT.  It is NOT a second mover.  The original class
//  is a copy of CFuncTrackTrain with three things changed:
//
//      1. a continuous accelerator instead of nine quarter-step notches,
//      2. an accelerator that DECAYS when you take your foot off,
//      3. an ignition state machine, so the truck cannot be driven until the
//         map script says the engine has been repaired and started.
//
//  Everything else — the path_track walk, the heading maths, the crush handler,
//  the dead-end fire, the per-node message/speed/DISABLE_TRAIN handling — is
//  identical, so this file reuses sv_func_tracktrain.qc's implementations of all
//  of it rather than forking them.  The one shared branch is `.tt_is_vehicle`,
//  declared over there because that file sets the think and compiles first.
//
//  COMPILE POSITION.  Immediately after sv_func_traincontrols.qc, and that is a
//  hard requirement rather than tidiness: this file reads sv_func_tracktrain.qc's
//  TT_* CONSTANTS and .tt_* / .train_* FIELDS, and QC forward-declares functions
//  but neither of those.  `.acceleration` had to move to sv_customdefs.qc for the
//  same reason — see the block there.
//
//  ---------------------------------------------------------------------------
//  THE ENGINE SOUND, AND WHY IT IS NOT THE AUTHORED ONE
//  ---------------------------------------------------------------------------
//  CTrackVehicle::Precache asks for `th_escape/diesel_idle_loop.flac`, and the
//  ignition and rev one-shots are .flac as well.  FTE CANNOT DECODE FLAC: the
//  loader's extension list is .wav / .opus / .ogg only
//  (engine/client/snd_mem.c:1044-1051) and snd_minimp3.c:137 explicitly rejects
//  a buffer whose magic is "fLaC".  The files are on disk and are real FLAC, so
//  precaching them buys a console warning and silence.
//
//  So the engine loop comes from func_tracktrain's own `sounds` enum instead,
//  which th_escape's vehicle already sets — `sounds 2` -> plats/ttrain2.wav, a
//  stock valve asset that is certain to be present.  The map's authored intent
//  (there IS an engine noise, keyed off `sounds`) is preserved; only the sample
//  differs.  This is recorded rather than silently accepted because it is the
//  one audible difference from Sven on this entity.
//

// ---------------------------------------------------------------------------
//  Keys unique to this class.  From CTrackVehicle::KeyValue, in its order:
//
//      wheels       -> m_length        (declared in sv_func_tracktrain.qc)
//      height       -> m_height        (ditto)
//      startspeed   -> m_startSpeed    (ditto)
//      sounds       -> m_sounds        (ditto)
//      volume       -> m_flVolume * 0.1 (ditto; same 0-10 scale)
//      bank         -> m_flBank        (ditto; not implemented, roll stays 0)
//      acceleration -> m_acceleration, CLAMPED TO 1..10 (sv_customdefs.qc)
//
//  th_escape's truck: speed 250, acceleration 10, wheels 50, height 0, bank 0,
//  sounds 2, volume 10, dmg 2000, startspeed 0, target ccc_01, rendermode 2.
// ---------------------------------------------------------------------------

// Ignition state.  Mirrors the original's m_state, which is a genuine enum
// despite being an int:
//
//     -2  engine off.  This is where a SF_TRACKTRAIN_STARTOFF vehicle spawns,
//         and the ONLY state IgnitionOn() will act from.
//     -1  cranking / idling, controls still locked.
//      1  running, controls released.
//
// The original also uses 0 and 2 for the non-KEEPRUNNING sound states, which
// cannot be reached here: CTrackVehicle::Spawn ends with a comment reading
// "GeckoN: HACK!" and then ORs KEEPRUNNING | STARTOFF | KEEPSPEED onto the
// spawnflags unconditionally, so every func_trackvehicle in existence is a
// keep-running, start-off, keep-speed one regardless of what the mapper set.
// That hack is reproduced verbatim in the spawn function below, and these three
// states are the whole reachable set as a result.
const float TV_STATE_OFF      = -2;
const float TV_STATE_CRANKING = -1;
const float TV_STATE_RUNNING  =  1;

// Half-Life's SF_TRACKTRAIN_* bits the vehicle adds on top of the four
// sv_func_tracktrain.qc already names (TT_NO_PITCH 1, TT_NO_USERCONTROL 2,
// TT_FORWARDS_ONLY 4, TT_PASSABLE 8).  Same layout, since the vehicle is a
// copy of the tracktrain class.
const float TV_SF_KEEPRUNNING = 16;   // engine keeps idling at speed 0
const float TV_SF_STARTOFF    = 32;   // spawn with the engine off
const float TV_SF_KEEPSPEED   = 64;   // a DISABLE_TRAIN node kills the decay too

.float tv_state;
// m_flAcceleratorDecay.  A timestamp on the `time` clock, or -1 meaning
// "decay permanently disabled" — which is what SF_TRACKTRAIN_KEEPSPEED plus a
// path_track carrying PT_DISABLE_TRAIN does.  On th_escape that is node
// `ccc_28` (spawnflags 10 = PT_FIRE_ONCE | PT_DISABLE_TRAIN): from there the
// truck stops answering the driver and runs on the authored per-node speeds
// (250 at ccc_29 and ccc_30) to the end of the line.  That is the escape.
.float tv_accel_decay;

// Ignition one-shots.  Both are .flac and therefore inaudible here; see the
// header.  The paths are still resolved and precached so that a future engine
// with a FLAC decoder, or a user who transcodes them, needs no code change —
// and so `sv_debug_func_train` reports what the map actually asked for.
const string TV_SND_IGNITION = "th_escape/diesel_ignition-rev.flac";
const string TV_SND_REV      = "th_escape/diesel_rev.flac";
const string TV_SND_IDLE     = "th_escape/diesel_idle_loop.flac";

void() func_trackvehicle_next;
void() func_trackvehicle_starting;

// ---------------------------------------------------------------------------
//  Idle tick — speed has reached exactly 0 but the engine is still running.
//
//  CFuncTrackTrain::Next halts outright at speed 0.  CTrackVehicle::Next does
//  not, when KEEPRUNNING is set (func_trackvehicle.as:399-416): it keeps the
//  loop playing and keeps thinking, which is what lets the accelerator decay
//  settle and what lets the next +forward pick the vehicle straight back up.
//
//  Deliberately does NOT call FuncTrackTrain_HaltMotion.  That would stop the
//  engine sound, and restarting it on every full stop is an audible stutter.
//  The two things HaltMotion does that DO matter here — leaving the moving-brush
//  list so the pmove carry pass stops trying to carry a stationary brush, and
//  dirtying the brushsync wire so CSQC stops projecting off a stale velocity —
//  are done inline.
// ---------------------------------------------------------------------------
void() FuncTrackVehicle_Idle =
{
    self.velocity               = '0 0 0';
    self.avelocity              = '0 0 0';
    self.mover_planned_velocity = '0 0 0';

    if (self.train_state)
    {
        self.train_state = 0;
        self.SendFlags   = 1;
        MovingBrush_RemoveFromList(self);
    }

    self.think     = func_trackvehicle_next;
    self.nextthink = self.ltime + 0.1;
};

// ---------------------------------------------------------------------------
//  The accelerator decay.
//
//  DIVERGENCE, DELIBERATE, AND THE ONLY PLACE A CONSTANT WAS CHANGED.
//
//  The original bleeds a flat 20 units off pev->speed each time Next() runs
//  with `g_Engine.time > m_flAcceleratorDecay`, then re-arms the gate to
//  time + 0.1 (func_trackvehicle.as:375-393).  That reads like a 10 Hz decay,
//  but Sven's Next() reschedules itself 0.5 s out, so the gate is never the
//  limiting factor and the OBSERVED rate in Sven is 20 units per 0.5 s — a flat
//  40 units/sec².
//
//  This tree's tracktrain re-aims every FuncTrain_TickInterval() (64 Hz at the
//  default sv_func_tickrate), deliberately, because a rider's carry has to be
//  exact for one tick at a time.  Porting the `+0.1` re-arm verbatim would
//  therefore decay at the full 10 Hz the author wrote but never got — 200
//  units/sec², five times Sven's brake — and the truck would stop dead the
//  instant you released the accelerator.
//
//  So the RATE is ported instead of the step: 40 units/sec, applied per tick.
//  Same curve as Sven, and independent of the tick rate, which is what the
//  original's coupling to its own think interval was always accidentally
//  standing in for.
// ---------------------------------------------------------------------------
const float TV_DECAY_RATE = 40;      // units/sec^2 — see above

void(float dt) FuncTrackVehicle_ApplyDecay =
{
    if (self.tv_accel_decay < 0)     // permanently disabled by DISABLE_TRAIN
        return;
    if (time <= self.tv_accel_decay) // foot still on the pedal (or just lifted)
        return;

    float bleed = TV_DECAY_RATE * dt;

    if (self.speed < 0)
    {
        self.speed = self.speed + bleed;
        if (self.speed > 0) self.speed = 0;
    }
    else if (self.speed > 0)
    {
        self.speed = self.speed - bleed;
        if (self.speed < 0) self.speed = 0;
    }
};

// ---------------------------------------------------------------------------
//  PT_DISABLE_TRAIN's second effect.
//
//  func_tracktrain_next already sets TT_NO_USERCONTROL when it crosses a node
//  carrying that flag.  The vehicle adds one thing on top: with KEEPSPEED set
//  it also kills the accelerator decay, so the authored per-node speeds are not
//  immediately bled away again (func_trackvehicle.as:494-499).
//
//  Polled from the move tick rather than hooked into the shared crossing code,
//  because the crossing code is func_tracktrain's and this is the one line that
//  is not.  The test is idempotent and costs one compare per tick.
//
//  On th_escape this fires at node `ccc_28` (spawnflags 10 = PT_FIRE_ONCE |
//  PT_DISABLE_TRAIN).  From there the truck stops answering the driver and runs
//  on the authored per-node speeds — 250 at ccc_29 and ccc_30 — to `ccc_31`,
//  whose pass-target is `winrars_script`, the trigger_script that ends the map.
// ---------------------------------------------------------------------------
void() FuncTrackVehicle_CheckControlLoss =
{
    // TV_STATE_RUNNING FIRST, and it is not a tidiness guard.  A
    // func_trackvehicle spawns with TT_NO_USERCONTROL set AND with KEEPSPEED
    // forced on, so without this the very first tick after ignition — while the
    // engine is cranking and long before anybody has touched the wheel — would
    // see both bits, latch tv_accel_decay to -1 and disable the accelerator
    // decay for the rest of the map.  The truck would then hold whatever speed
    // you last asked for instead of coasting down, forever.
    //
    // "Control loss" means losing control you HAD.  In the source that is not a
    // poll at all: it happens inside the path_track crossing, which can only
    // run on a moving vehicle.
    if (self.tv_state != TV_STATE_RUNNING)
        return;
    if (self.tv_accel_decay < 0)
        return;
    if (!(self.spawnflags & TT_NO_USERCONTROL))
        return;
    if (!(self.spawnflags & TV_SF_KEEPSPEED))
        return;

    self.tv_accel_decay = -1;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[trackvehicle %s] control lost — accelerator decay disabled, "
                       "path speeds now authoritative\n", self.targetname));
};

// ---------------------------------------------------------------------------
//  The move tick.  Decay first, then the shared tracktrain walk.
//
//  func_tracktrain_next re-installs the think through FuncTrackTrain_SetMoveThink,
//  which reads .tt_is_vehicle, so control comes back here on the next tick
//  without any post-hoc fixup — and its `waitdone` and `deadend` handoffs are
//  left alone, which a blind re-point would have clobbered.
// ---------------------------------------------------------------------------
void() func_trackvehicle_next =
{
    float dt = FuncTrain_TickInterval();

    FuncTrackVehicle_CheckControlLoss();
    FuncTrackVehicle_ApplyDecay(dt);

    // Engine running, wheels stopped: idle rather than shut down.
    if (self.speed == 0 && self.tv_state >= TV_STATE_CRANKING)
    {
        FuncTrackVehicle_Idle();
        return;
    }

    func_tracktrain_next();
};

// ---------------------------------------------------------------------------
//  CTrackVehicle::Use, the USE_SET arm — func_trackvehicle.as:235-314.
//
//  `delta` is +1 (accelerate) or -1 (brake / reverse).  The original also
//  receives 20 and 30 for strafe left / right and then throws them away at the
//  `if (delta < 10)` gate, so strafing is a documented no-op and there is
//  nothing here to port for it.
//
//  THE LADDER IS VERBATIM, TYPO INCLUDED.  Both halves are transcribed straight
//  out of the .as, including the fifteen VEHICLE_SPEEDn_ACCELERATION constants
//  at their full authored precision and including the brake table's
//  `flSpeedRatio -= - 0.0175` on the (-0.3, -0.22] rung, which adds instead of
//  subtracting.  That double negative is plainly a slip, but it is the shipped
//  behaviour of the shipped map: it is what makes reverse self-limit at about
//  -0.22 of maximum (an oscillation between the -0.01375 rung and the +0.0175
//  one) rather than running to the -0.35 clamp below it.  "Fixing" it would make
//  th_escape's truck reverse 60% faster than it does in Sven, which is a
//  divergence, not a repair.
//
//  Note also that the brake rungs after the second are unreachable as written —
//  `flSpeedRatio <= 0.05 && > -0.1` can only be entered by a value already
//  excluded by the rung above it for the positive half — so the discriminator
//  that actually runs is the negative bound of each. Transcribed as-is; the
//  reachable subset is what produces the curve.
// ---------------------------------------------------------------------------
const float TV_ACC_0  = 0.005000000000000000;
const float TV_ACC_1  = 0.002142857142857143;
const float TV_ACC_2  = 0.003333333333333334;
const float TV_ACC_3  = 0.004166666666666667;
const float TV_ACC_4  = 0.004000000000000000;
const float TV_ACC_5  = 0.003800000000000000;
const float TV_ACC_6  = 0.004500000000000000;
const float TV_ACC_7  = 0.004250000000000000;
const float TV_ACC_8  = 0.002666666666666667;
const float TV_ACC_9  = 0.002285714285714286;
const float TV_ACC_10 = 0.001875000000000000;
const float TV_ACC_11 = 0.001444444444444444;
const float TV_ACC_12 = 0.001200000000000000;
const float TV_ACC_13 = 0.000916666666666666;
const float TV_ACC_14 = 0.001444444444444444;

void(entity veh, float delta) FuncTrackVehicle_Accel =
{
    if (veh == world || wasfreed(veh))
        return;

    // The original guards the whole block on `delta < 10`; +1 and -1 both pass
    // and 20 / 30 both fail.  Kept explicitly so the reason 20 and 30 exist at
    // all stays legible.
    if (delta >= 10)
        return;

    float ratio = 0;

    if (veh.tt_maxspeed == 0)
    {
        veh.speed = 0;
    }
    else
    {
        float spd   = veh.speed;
        float accel = veh.acceleration;

        ratio = spd / veh.tt_maxspeed;

        if (delta > 0)
        {
            if      (spd <   0) ratio = accel * 0.0005 + ratio + TV_ACC_0;
            else if (spd <  10) ratio = accel * 0.0006 + ratio + TV_ACC_1;
            else if (spd <  20) ratio = accel * 0.0007 + ratio + TV_ACC_2;
            else if (spd <  30) ratio = accel * 0.0007 + ratio + TV_ACC_3;
            else if (spd <  45) ratio = accel * 0.0007 + ratio + TV_ACC_4;
            else if (spd <  60) ratio = accel * 0.0008 + ratio + TV_ACC_5;
            else if (spd <  80) ratio = accel * 0.0008 + ratio + TV_ACC_6;
            else if (spd < 100) ratio = accel * 0.0009 + ratio + TV_ACC_7;
            else if (spd < 150) ratio = accel * 0.0008 + ratio + TV_ACC_8;
            else if (spd < 225) ratio = accel * 0.0007 + ratio + TV_ACC_9;
            else if (spd < 300) ratio = accel * 0.0006 + ratio + TV_ACC_10;
            else if (spd < 400) ratio = accel * 0.0005 + ratio + TV_ACC_11;
            else if (spd < 550) ratio = accel * 0.0005 + ratio + TV_ACC_12;
            else if (spd < 800) ratio = accel * 0.0005 + ratio + TV_ACC_13;
            else                ratio = accel * 0.0005 + ratio + TV_ACC_14;
        }
        else if (delta < 0)
        {
            if      (ratio > 0)                        ratio = ratio - 0.0125;
            else if (ratio <= 0    && ratio > -0.05)   ratio = ratio - 0.0075;
            else if (ratio <= 0.05 && ratio > -0.1)    ratio = ratio - 0.01;
            else if (ratio <= 0.15 && ratio > -0.15)   ratio = ratio - 0.0125;
            else if (ratio <= 0.15 && ratio > -0.22)   ratio = ratio - 0.01375;
            else if (ratio <= 0.22 && ratio > -0.3)    ratio = ratio + 0.0175;  // sic: `-= -0.0175`
            else if (ratio <= 0.3)                     ratio = ratio - 0.0125;
        }

        if      (ratio >  1)    ratio = 1;
        else if (ratio < -0.35) ratio = -0.35;

        // Not TT_FORWARDS_ONLY-aware, and neither is the original — a
        // func_trackvehicle that set the flag would still reverse.  Left as the
        // source has it; no vehicle in the corpus sets it.
        veh.speed = veh.tt_maxspeed * ratio;
    }

    // Any pedal input pushes the decay a quarter second out, so coasting only
    // starts once the driver actually lets go (func_trackvehicle.as:312-313).
    // The `>= 0` test is what makes DISABLE_TRAIN's -1 stick permanently.
    if (veh.tv_accel_decay >= 0)
        veh.tv_accel_decay = time + 0.25;

    // The original calls Next() straight from here, on every input frame.  We
    // do not: re-entering the mover out of band would apply an extra velocity
    // and heading update inside the same server frame the scheduled tick is
    // about to run, and the rider carry integrates exactly one tick of velocity.
    // Ensuring the tick is SCHEDULED is the same thing minus the double step,
    // and it is what FuncTrackTrain_Throttle already does.
    entity oldself = self;
    self = veh;
    if (veh.speed != 0 && veh.train_state == 0)
        FuncTrackTrain_BeginMotion();
    self = oldself;
};

// ---------------------------------------------------------------------------
//  Ignition.  CTrackVehicle::IgnitionOn / ::Starting / ::EnableControls.
//
//  Called by the map script, not by a trigger:  th_escape's `veh1_ignsnd`
//  trigger_script calls VehicleIgnitionOn() and `veh1_moveto` calls
//  VehicleStarted().  See server/sv_mapscript.qc.
// ---------------------------------------------------------------------------
void(entity veh) FuncTrackVehicle_IgnitionOn =
{
    if (veh == world || wasfreed(veh))
        return;
    // `if ( m_state > -2 ) return;` — only from a cold engine, so a second call
    // (or a re-fired multi_manager) cannot restart the crank.
    if (veh.tv_state > TV_STATE_OFF)
        return;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[trackvehicle %s] ignition\n", veh.targetname));

    sound(veh, CHAN_VOICE, TV_SND_IGNITION, 1, ATTN_NORM);

    veh.think     = func_trackvehicle_starting;
    veh.nextthink = veh.ltime + 1.4;      // the original's crank length
};

void() func_trackvehicle_starting =
{
    if (self.tv_state != TV_STATE_OFF)
        return;

    self.tv_state = TV_STATE_CRANKING;

    // The original ramps the loop's pitch from 100 down to 60 over ~4 s here.
    // FTE's sound() takes no pitch argument on this path — sv_func_tracktrain.qc
    // documents the same limitation for the tracktrain's speed-pitch modulation
    // — so the loop simply starts.  Nothing downstream depends on the ramp.
    FuncTrackTrain_StartSound();

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[trackvehicle %s] engine running, controls still locked\n",
                       self.targetname));

    // Idle until EnableControls.  Speed is 0 and tv_state is CRANKING, so the
    // move tick takes the idle arm every time.
    self.think     = func_trackvehicle_next;
    self.nextthink = self.ltime + 0.1;
};

void(entity veh) FuncTrackVehicle_EnableControls =
{
    if (veh == world || wasfreed(veh))
        return;

    veh.spawnflags = veh.spawnflags - (veh.spawnflags & TT_NO_USERCONTROL);
    veh.tv_state   = TV_STATE_RUNNING;

    // Cover the case where VehicleStarted() arrives without a preceding
    // VehicleIgnitionOn() — the map fires them from two separate chains and a
    // player can reach the second by a route that skipped the first.  Sven has
    // the same hole; starting the loop here rather than assuming it is already
    // running costs nothing and closes it.
    entity oldself = self;
    self = veh;
    FuncTrackTrain_StartSound();
    self = oldself;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[trackvehicle %s] controls released — driveable\n",
                       veh.targetname));

    veh.think     = func_trackvehicle_next;
    veh.nextthink = veh.ltime + 0.1;
};

// ---------------------------------------------------------------------------
//  CTrackVehicle::SetDriver — func_trackvehicle.as:745-753.  A throttle blip the
//  moment somebody takes the wheel, and nothing at all when they let go (the
//  source only plays on a non-null driver).
//
//  Called from TrainControls_TryUse, which is where the mount actually happens.
//  Inaudible here because the sample is .flac — see the header — but wiring it
//  is a two-line job and it means the entity is complete rather than
//  almost-complete.
// ---------------------------------------------------------------------------
void(entity veh, entity driver) FuncTrackVehicle_SetDriver =
{
    if (veh == world || wasfreed(veh)) return;
    if (!veh.tt_is_vehicle)            return;
    if (driver == world)               return;

    sound(veh, CHAN_ITEM, TV_SND_REV, 0.8, ATTN_NORM);
};

// Find the map's vehicle by targetname, the way th_escape.as's GetVehicle()
// does.  Returns world and says so if it is missing, rather than letting a
// silent null propagate into the script stand-ins.
entity(string name) FuncTrackVehicle_Find =
{
    entity e = find(world, classname, "func_trackvehicle");
    while (e)
    {
        if (name == "" || e.targetname == name)
            return e;
        e = find(e, classname, "func_trackvehicle");
    }
    return world;
};

/*QUAKED func_trackvehicle (0 .6 .4) ? TT_NO_PITCH TT_NO_USERCONTROL TT_FORWARDS_ONLY TT_PASSABLE KEEPRUNNING STARTOFF KEEPSPEED
Sven Co-op th_escape map-local entity (scripts/maps/th_escape/func_trackvehicle.as).
A func_tracktrain with a car's accelerator instead of a train's notched
throttle, plus an ignition the map script controls.  Stand in the matching
func_trackvehiclecontrols and press +use to take the wheel; hold +forward to
accelerate and +back to brake and reverse.  Releasing both coasts to a stop.

Cannot be driven until the map script calls VehicleStarted() — it spawns with
TT_NO_USERCONTROL set, and Sven's own Spawn() forces STARTOFF on regardless of
what the mapper authored.

"target"        first-stop path_track targetname
"speed"         maximum speed (units/sec)
"acceleration"  1..10 engine responsiveness (clamped)
"wheels"        front-axle lookahead; steers into corners early
"height"        origin's ride height above the track
"dmg"           crush damage; riders exempt
"sounds"        engine loop enum 1..6 (see the FLAC note at the top of this file)
"volume"        engine volume 0-10
"bank"          NOT IMPLEMENTED, as on func_tracktrain — roll stays 0
"rendermode" / "renderamt" / "rendercolor"   as func_tracktrain
*/
void() func_trackvehicle =
{
    self.tt_is_vehicle = TRUE;

    if (self.speed == 0)  self.speed = 100;     // the original's TRAIN_DEFAULT_SPEED
    self.tt_maxspeed = self.speed;
    self.speed       = 0;
    self.tt_dir      = 1;

    // m_acceleration is clamped to 1..10 in KeyValue, and an unset key means 0,
    // which the clamp turns into 1.
    if (self.acceleration < 1)  self.acceleration = 1;
    if (self.acceleration > 10) self.acceleration = 10;

    if (self.wheels == 0) self.wheels = 100;
    if (self.dmg == 0)    self.dmg    = 2;
    if (self.volume > 1)  self.volume = bound(0, self.volume / 10, 1);
    if (self.volume == 0) self.volume = 0.85;

    // "GeckoN: HACK!" — func_trackvehicle.as:840-841 sets these three
    // unconditionally, after KeyValue and after reading spawnflags, so the
    // mapper's spawnflags cannot switch any of them off.  Reproduced verbatim
    // because every behaviour below assumes them: the engine idles at rest
    // (KEEPRUNNING), the vehicle spawns dead (STARTOFF), and crossing a
    // DISABLE_TRAIN node hands speed to the path for good (KEEPSPEED).
    self.spawnflags = self.spawnflags | TV_SF_KEEPRUNNING | TV_SF_STARTOFF | TV_SF_KEEPSPEED;

    self.tv_state       = TV_STATE_OFF;
    self.tv_accel_decay = 0;
    self.spawnflags     = self.spawnflags | TT_NO_USERCONTROL;

    // Before find_first teleports us onto ccc_01 — the controls brush is
    // measured against this.  See sv_func_tracktrain.qc's declaration.
    self.tt_authored_origin = self.origin;

    if (cvar("sv_debug_func_train"))
    {
        dprint(sprintf("[trackvehicle %s] spawn target=\"%s\" max=%g accel=%g wheels=%g\n",
                       self.targetname, self.target, self.tt_maxspeed,
                       self.acceleration, self.wheels));
        dprint(sprintf("             height=%g dmg=%g sounds=%g flags=%g origin=%v\n",
                       self.height, self.dmg, self.sounds, self.spawnflags, self.origin));
    }

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;

    if (self.spawnflags & TT_PASSABLE)
        self.solid = SOLID_NOT;

    // Default control volume, same as func_tracktrain: own bounds plus 72 units
    // of headroom.  th_escape does ship a func_trackvehiclecontrols, which
    // overrides this, but a vehicle without one must still be mountable.
    self.tt_ctrl_mins   = self.mins;
    self.tt_ctrl_maxs   = self.maxs;
    self.tt_ctrl_maxs_z = self.tt_ctrl_maxs_z + 72;

    self.train_movesound_path = FuncTrackTrain_Sound(self.sounds);
    if (self.train_movesound_path != "")
        precache_sound(self.train_movesound_path);

    // Precached even though FTE cannot decode them — see the header.  A missing
    // sound is a console warning here, not a hard error the way a missing model
    // is, and th_escape's own ambient_generic entities already reference seven
    // more .flac files, so this changes nothing about the map's boot behaviour.
    precache_sound(TV_SND_IGNITION);
    precache_sound(TV_SND_REV);
    precache_sound(TV_SND_IDLE);

    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    // Trigger use is the tracktrain's plain start/stop toggle — the original
    // inherits exactly that for any useType that is not USE_SET
    // (func_trackvehicle.as:215-233).  The USE_SET arm is the accelerator and
    // reaches us through FuncTrackVehicle_Accel instead.
    self.use     = func_tracktrain_use;
    self.blocked = func_tracktrain_blocked;

    self.think     = func_tracktrain_find_first;
    self.nextthink = self.ltime + 0.1;      // .ltime: MOVETYPE_PUSH, see func_tracktrain
};

// ---------------------------------------------------------------------------
//  func_trackvehiclecontrols — CTrackVehicleControls.
//
//  Identical in intent to func_traincontrols: a non-solid brush that overrides
//  the vehicle's control volume and then deletes itself.  Kept alive here for
//  the same reason func_traincontrols is — TrainControls_TryUse's zone-lookup
//  fallback walks these entities to find a vehicle the player is not literally
//  standing on, which is how you drive from a cab that sits forward of the bed.
// ---------------------------------------------------------------------------
void() func_trackvehiclecontrols_link =
{
    entity veh = (self.target != "") ? find(world, targetname, self.target) : world;

    // The original loops until it finds a match whose classname is
    // func_trackvehicle, because targetnames are not unique.  Same walk here.
    while (veh != world && veh.classname != "func_trackvehicle")
        veh = find(veh, targetname, self.target);

    if (veh == world)
    {
        self.tctrl_link_tries = self.tctrl_link_tries + 1;
        if (self.tctrl_link_tries < 40)
        {
            self.nextthink = time + 0.1;
            self.think     = func_trackvehiclecontrols_link;
        }
        else if (cvar("sv_debug_func_train"))
            dprint(sprintf("[trackvehiclecontrols] no func_trackvehicle named \"%s\"\n",
                           self.target));
        return;
    }

    veh.train_controls = self;
    self.tctrl_train   = veh;

    // CTrackVehicle::SetControls (func_trackvehicle.as:611-617) is
    // CFuncTrackTrain::SetControls unchanged — a translation into the vehicle's
    // AUTHORED frame, no rotation.  See the long note in
    // func_traincontrols_link (sv_func_traincontrols.qc) for why both of those
    // are load-bearing; th_escape is the map that made it observable, because
    // its truck is drawn at -630 1281 -496 and its first path_track is 3000
    // units away at 1646 -1350 16.
    //
    // Checked against the .bsp: the truck's brush model spans local
    // x -154..172, y -54..58, z -2..120, and this formula puts the cab at
    // x -58..10, y -46..7, z 30..96 — inside the hull, on the driver's side.
    vector offset = self.origin - veh.tt_authored_origin;

    vector lo = self.mins + offset;
    vector hi = self.maxs + offset;

    // Same sanity gate func_traincontrols applies; no func_trackvehicle in the
    // corpus needs it, but the two classes must not disagree about what a
    // usable control box is.
    if (!TrackTrain_ControlBoxSane(veh, lo, hi))
    {
        print(sprintf("[trackvehiclecontrols] \"%s\": control brush is %g units from "
                      "the vehicle hull — ignoring it, keeping the default box\n",
                      veh.targetname, rint(vlen((lo + hi) * 0.5))));
        self.tctrl_train = veh;
        return;
    }

    veh.tt_ctrl_mins = lo;
    veh.tt_ctrl_maxs = hi;

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[trackvehiclecontrols] \"%s\" control box mins=%v maxs=%v (authored org=%v)\n",
                       veh.targetname, veh.tt_ctrl_mins, veh.tt_ctrl_maxs,
                       veh.tt_authored_origin));
};

/*QUAKED func_trackvehiclecontrols (0 .6 .4) ?
Sven Co-op th_escape map-local entity.  Invisible, non-solid volume that marks
where a player must stand to drive the named func_trackvehicle.  OVERRIDES the
vehicle's default control box (its own bounds plus 72 units of headroom); it is
not required in order to drive one.

"target"   targetname of the func_trackvehicle this drives

No spawnflags, no targetname — same as func_traincontrols.
*/
void() func_trackvehiclecontrols =
{
    if (!self.model)
    {
        remove(self);
        return;
    }

    setmodel(self, self.model);
    vector bmin = self.mins;
    vector bmax = self.maxs;
    self.model      = "";
    self.modelindex = 0;
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    setsize(self, bmin, bmax);

    self.tctrl_link_tries = 0;
    self.think     = func_trackvehiclecontrols_link;
    self.nextthink = time + 0.2;      // after func_trackvehicle spawns and places
};
