//
//  server/sv_func_pushable.qc  -  func_pushable  (GoldSrc / Sven Co-op)
//
//  "Similar to func_breakable, but this entity can also be pushed and carried
//  by players."  GoldSrc implements it exactly that way - CPushable DERIVES
//  from CBreakable - and this file does the same: the breakable half is
//  func_breakable() called verbatim, and only the physics half is new.
//
//  WHY THE FLAGS NEED TRANSLATING
//  Sven's func_pushable and this mod's func_breakable disagree on two bits:
//      Sven 512  Explosives Only   vs   mod 4    BREAKABLE_ONLY_EXPLOSION
//      Sven 256  1-Hit Break       ==   mod 256  BREAKABLE_INSTANT_CROWBAR  (match)
//  so 512 is folded onto bit 4 before the breakable spawn runs.  Bit 4 is unused
//  in Sven's func_pushable FGD, so nothing is lost by claiming it.
//
//  Sven also does NOT make a named brush trigger-only the way this mod's
//  func_breakable does; in GoldSrc a func_pushable with the Breakable flag is
//  shootable whatever its targetname, and most Sven crates are named (they get
//  fired by map logic).  Left alone, the mod's rule would have made almost
//  every Sven crate indestructible - so the flag that opts back in is set too.
//
//  PHYSICS
//  A replicated brush is MOVETYPE_PUSH, and a MOVETYPE_PUSH entity does NOT
//  collide with the world - the engine integrates its velocity straight through
//  walls (that is fine for doors, which run on rails).  So the crate has to
//  sweep its own hull and CLAMP velocity, never setorigin: the same division of
//  labour func_vehicle uses (sv_func_vehicle.qc, Vehicle_CollideWorld), for the
//  same reason - the engine stays the integrator, we only decide what velocity
//  is legal.
//
//  The think NEVER stops.  A MOVETYPE_PUSH entity with nextthink 0 has its
//  movetime clamped to 0 by WPhys_Physics_Pusher (engine sv_phys.c:1148), which
//  freezes .ltime - and .ltime is the clock nextthink is measured against, so a
//  crate that slept would need its ltime resynced before it could ever wake.
//  Ticking forever at a slow idle rate sidesteps that entirely; the idle body is
//  one tracebox.  For the same reason .blocked must zero velocity: PushMove
//  leaves ltime unadvanced when it is obstructed, and `thinktime > oldltime`
//  then never holds, so a blocked crate whose velocity kept pointing into the
//  obstruction would wedge permanently.
//
//  It stays AXIS-ALIGNED, and cannot reasonably do otherwise: a GoldSrc
//  func_pushable has no origin brush, so its BSP submodel geometry sits at
//  absolute world coordinates with .origin at 0 0 0, and FTE does not re-centre
//  submodels at load (gl_model.c:6480).  Setting .angles on one rotates it about
//  the WORLD origin, not about itself.  That is also why GoldSrc's own pushables
//  never tumble, so this is parity rather than a shortfall.
//
//  BRUSH_TYPE_TRAIN is not a lie of convenience - a pushable is precisely a
//  velocity-driven brush you can stand on, so it wants the carry + geometry-push
//  pass PM_CheckMovingPushers already runs for trains on BOTH sides, and the
//  train branch ships no extra wire fields (cl_brushsync.qc).
//

// Defined later in the compile order.
void(entity c) MovingBrush_AddToList;       // shared/sh_pmove.qc
void(entity c) MovingBrush_RemoveFromList;  // shared/sh_pmove.qc

// Sven "Buoyancy".  GoldSrc had no such key - CPushable::Spawn folds buoyancy
// into pev->skin - so `skin` is accepted as the legacy spelling.
.float buoyancy;
// Sven "Gib model": custom broken-parts model.  func_breakable already has this
// under the name `mdl`, so the key is bridged at spawn rather than reimplemented.
.string gibmodel;
// Parsed, deliberately inert - see the FGD entry, which says so to the mapper:
//   classify / weapon / spawnobject / explodemagnitude / soundlist / displayname
// need systems this mod does not have (monster relationships, an instant-break
// weapon table, item spawning, per-map sound replacement, a HUD info readout).
.float  classify;
.string spawnobject;
.float  explodemagnitude;
.string soundlist;
.string displayname;

// Sven spawnflags.
const float PUSH_REPAIRABLE       = 8;
const float PUSH_MONSTERS_IGNORE  = 16;
const float PUSH_SHOW_HUD_INFO    = 32;
const float PUSH_BREAKABLE        = 128;
const float PUSH_INSTANT_BREAK    = 256;
const float PUSH_EXPLOSIVES_ONLY  = 512;
const float PUSH_LIFTABLE         = 1024;

// GoldSrc constants.  MaxSpeed() = 400 - friction, friction clamped to 399 so a
// "400" crate still creeps rather than dividing by nothing (Sven documents 400
// as "unmovable by pushing", and one unit/sec is close enough to unmovable).
const float PUSH_BASE_SPEED    = 400;
const float PUSH_MAX_FRICTION  = 399;
// Touch push scale factors, straight from CPushable::Move.
const float PUSH_FACTOR_GROUND = 1.0;   // toucher on the ground
const float PUSH_FACTOR_WATER  = 0.1;   // airborne toucher, but the crate floats
const float PUSH_FACTOR_OTHER  = 0.25;  // non-player toucher
const float PUSH_SOUND_GAP     = 0.7;   // CPushable::m_soundTime debounce

const float PUSH_TICK_IDLE     = 0.1;   // at rest: one ground probe per tick
const float PUSH_STOP_SPEED    = 4;     // below this we just stop
const float PUSH_GROUND_DECEL  = 6.0;   // per-second velocity decay on the ground
const float PUSH_AIR_DECEL     = 0.4;   // barely any while falling
const float PUSH_WATER_DECEL   = 2.0;

// --- buoyancy --------------------------------------------------------------
// Sven exposes a "Buoyancy" key (GoldSrc folded it into pev->skin) with no
// documented units, so it is read as a DENSITY RATIO through a cvar scale: how
// many times its own weight of water the crate displaces when fully submerged.
// >1 floats and settles at 1/ratio submerged; sv_pushable_buoyancy 0.1 turns
// Sven's default 20 into 2.0 - half submerged, which is what a crate looks like
// in the reference game.  0 sinks, which is also GoldSrc's default.
const float PUSH_BUOY_ACCEL_MAX = 2.0;  // cap on net buoyant accel, in gravities:
                                        // stops a very buoyant crate rocketing out
const float PUSH_BUOY_SPLASH_V  = 60;   // entry speed that earns a splash sound
const float PUSH_REST_V         = 3.0;  // vertical speed below which a floating crate parks
const float PUSH_REST_A         = 0.08; // ...and the net accel (in gravities) that allows it

.float push_maxspeed;
.vector push_spawn_origin;   // restored by the round reset
.float push_sound_time;
.float push_moving;          // 1 while published to moving_brush_list
.float push_in_water;        // 1 while any part of the crate is under a waterline

void() func_breakable;                                  // sv_breakable.qc
float(entity playerent, float changedflags) solid_brush_SendEntity;

// World-space centre + half-extents.  A GoldSrc func_pushable usually has NO
// origin brush, so self.origin is '0 0 0' and mins/maxs hold the ABSOLUTE brush
// extents; with an origin brush they are relative instead.  Deriving the hull
// from the midpoint is correct either way, which tracebox(self.origin, mins,
// maxs, ...) is not.
vector() FuncPushable_Center =
{
    return self.origin + (self.mins + self.maxs) * 0.5;
};

// Sweep the planned move and clip velocity onto whatever it hits, so the crate
// slides along walls instead of tunnelling through them.  MOVE_NOMONSTERS on
// purpose: the player leaning on the crate must not count as an obstruction, or
// pushing it would immediately cancel itself.
void(float dt) FuncPushable_CollideWorld =
{
    vector planned = self.velocity * dt;
    if (planned == '0 0 0')
        return;

    vector half   = (self.maxs - self.mins) * 0.5;
    vector center = FuncPushable_Center();

    float ss   = self.solid;
    self.solid = SOLID_NOT;                 // never let the sweep hit ourselves
    tracebox(center, half * -1, half, center + planned, MOVE_NOMONSTERS, self);
    self.solid = ss;

    if (trace_fraction >= 1)
        return;

    // Clip onto the plane (slide), then re-test.  A second block means a corner
    // or a step the crate cannot round - stop dead rather than jitter into it.
    vector n = trace_plane_normal;
    self.velocity = self.velocity - n * (self.velocity * n);

    planned = self.velocity * dt;
    if (planned == '0 0 0')
        return;
    self.solid = SOLID_NOT;
    tracebox(center, half * -1, half, center + planned, MOVE_NOMONSTERS, self);
    self.solid = ss;
    if (trace_fraction < 1)
        self.velocity = '0 0 0';
};

// Waterline above `p`, or PUSH_NO_WATER when the point is dry.
//
// PM_ContentsAt (shared/sh_customdefs.qc) rather than pointcontents, so this
// sees BRUSH water as well as baked world water.  func_water is how GoldSrc
// maps normally hold a pool, and de_rats' only crate spawns directly above one
// of its two, which is exactly why it used to sink to the bottom of the sink.
// Both kinds now answer the same query, so the surface is found the same way for
// both: climb out of the liquid in coarse steps, then step back down a unit at a
// time to the last wet sample.  Same shape as Buoy_SurfaceZ in sv_physprop.qc,
// and it reads the mapper's real water plane - no bounding-box approximation,
// and none of the bounds-padding arithmetic an AABB test would have needed.
const float PUSH_NO_WATER   = -999999;
const float PUSH_SCAN_STEP  = 8;
const float PUSH_SCAN_LIMIT = 512;

float(float c) FuncPushable_IsLiquid =
{
    return (c == CONTENT_WATER || c == CONTENT_SLIME || c == CONTENT_LAVA);
};

// Probe points inside the crate's own volume, so the crate has to be taken out
// of the contents query first.  World_ContentsOfLinks ORs together the contents
// of EVERY linked entity containing the point and has no passedict to exclude,
// so a SOLID_BSP crate reports CONTENT_SOLID at its own centre and drowns out
// the water it is floating in.  Reading .solid is how that function decides to
// skip an entity, and it reads the live field rather than anything baked in at
// link time, so flipping it for the duration of the probe is enough - no
// relink, same trick as the sweep traces above.
float(vector p) FuncPushable_ContentsIgnoringSelf =
{
    float ss   = self.solid;
    self.solid = SOLID_NOT;
    float c    = PM_ContentsAt(p);
    self.solid = ss;
    return c;
};

float(vector p) FuncPushable_WaterSurfaceAt =
{
    if (!FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(p)))
        return PUSH_NO_WATER;

    // Coarse: climb until we leave the liquid, remembering the last wet sample.
    vector s   = p;
    float  wet = p_z;
    float  dry = 0;
    float  climbed = 0;
    while (climbed < PUSH_SCAN_LIMIT)
    {
        s_z     = s_z + PUSH_SCAN_STEP;
        climbed = climbed + PUSH_SCAN_STEP;
        if (!FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(s)))
            break;
        wet = s_z;
    }
    dry = s_z;

    // Fine: bisect the wet/dry bracket.  Stepping down a unit at a time (the
    // obvious version) quantises the answer to wherever the scan happened to
    // start, so the reported waterline SLID WITH THE CRATE as it bobbed -- a
    // moving target for a plane the mapper drew once.  Eight halvings pin an
    // 8-unit bracket to about 0.03qu, which is exact enough to be stationary.
    float i = 0;
    while (i < 8)
    {
        float mid = (wet + dry) * 0.5;
        s_z = mid;
        if (FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(s)))
            wet = mid;
        else
            dry = mid;
        i = i + 1;
    }
    return wet;
};

// TRUE when something solid is within a unit below the crate.
float() FuncPushable_OnGround =
{
    vector half   = (self.maxs - self.mins) * 0.5;
    vector center = FuncPushable_Center();
    float  ss     = self.solid;
    self.solid    = SOLID_NOT;
    tracebox(center, half * -1, half, center - '0 0 1', MOVE_NOMONSTERS, self);
    self.solid    = ss;
    return (trace_fraction < 1 || trace_startsolid);
};

void() func_pushable_tick =
{
    // Destroyed: nothing left to simulate, and rescheduling here would be a
    // per-frame busy loop.  func_breakable_break drops the brush to
    // MOVETYPE_NONE, whose think clock is world `time` while .ltime freezes -
    // so an ltime-based nextthink lands permanently in the past and the engine
    // re-fires the think every frame until the round reset re-arms it.
    if (self.breakable_broken)
    {
        if (self.push_moving)
        {
            MovingBrush_RemoveFromList(self);
            self.push_moving = 0;
        }
        self.velocity  = '0 0 0';
        self.nextthink = 0;
        return;
    }

    float dt   = FuncTrain_TickInterval();
    float grav = cvar("sv_gravity");  if (grav <= 0) grav = 800;

    vector center = FuncPushable_Center();
    float  half_z = (self.maxs_z - self.mins_z) * 0.5;
    float  bottom = center_z - half_z;
    float  height = half_z * 2;
    if (height < 1) height = 1;

    // Submerged FRACTION, not a boolean - a crate straddling the waterline has
    // to feel the part of itself that is actually under it, or it can never
    // settle: full buoyancy right up to the surface then none at all above it is
    // a step function, and a step function oscillates.
    float surf = FuncPushable_WaterSurfaceAt(center);
    if (surf == PUSH_NO_WATER)
        surf = FuncPushable_WaterSurfaceAt(center - '0 0 1' * (half_z - 1));  // bobbing: centre may be dry while the base is wet
    float submerged = 0;
    if (surf != PUSH_NO_WATER && surf > bottom)
        submerged = bound(0, (surf - bottom) / height, 1);

    float was_wet      = self.push_in_water;
    self.push_in_water = (submerged > 0);
    float in_water     = self.push_in_water;

    float grounded = FuncPushable_OnGround();

    // Vertical.  GoldSrc gets floating from the engine's FL_FLOAT handling of
    // pev->skin, which FTE has no equivalent for, so this is a real (if small)
    // buoyancy model rather than a transcription: net acceleration from the
    // displaced fraction, capped, plus damping so it comes to rest.
    float buoy_a = 0;
    if (submerged > 0)
    {
        float ratio = self.buoyancy * cvar("sv_pushable_buoyancy");
        buoy_a = grav * (submerged * ratio - 1);
        if (buoy_a >  grav * PUSH_BUOY_ACCEL_MAX) buoy_a =  grav * PUSH_BUOY_ACCEL_MAX;
        if (buoy_a < -grav) buoy_a = -grav;          // never sink faster than free-fall
        self.velocity_z = self.velocity_z + buoy_a * dt;

        // Damping as a RATIO, not a fixed coefficient.  Buoyancy is a spring:
        // the restoring accel changes by grav*ratio/height per unit of sink, so
        // the natural frequency is sqrt(grav*ratio/height) - which varies with
        // how tall and how buoyant each crate is.  A hardcoded drag constant is
        // therefore critically damped for exactly one crate and badly
        // under-damped for the rest (de_rats' 24-unit crate at buoyancy 25 came
        // out at zeta 0.09 - about ten visible bobs).  Deriving the coefficient
        // from the spring keeps every crate at the SAME feel:
        // sv_pushable_buoyancy_damping 1 = dead stop, 0.35 = a couple of bobs.
        // Same idea, and the same cvar spelling, as sv_prop_buoyancy_damping.
        float omega = sqrt(grav * ratio / height);
        float zeta  = cvar("sv_pushable_buoyancy_damping");
        self.velocity_z = self.velocity_z
                        - self.velocity_z * bound(0, 2 * zeta * omega * submerged * dt, 1);

        // Park it at equilibrium.  Damping alone only ever ASYMPTOTES to rest, so
        // without this the crate keeps a few units/sec of residual bob forever -
        // which would hold it at the fast tick rate and dirty the brushsync wire
        // every single tick for a crate that visually is not moving.
        if (fabs(self.velocity_z) < PUSH_REST_V && fabs(buoy_a) < grav * PUSH_REST_A)
            self.velocity_z = 0;
    }
    else if (!grounded)
        self.velocity_z = self.velocity_z - grav * dt;

    // Resting on something wins over a downward pull, but NOT over buoyancy -
    // a crate sitting on the bottom of a pool has to be able to rise off it.
    if (grounded && self.velocity_z < 0)
        self.velocity_z = 0;

    // Splash on entry, once, and only when it arrives with some speed - a crate
    // drifting across a waterline should be silent.
    if (in_water && !was_wet && fabs(self.velocity_z) > PUSH_BUOY_SPLASH_V)
        sound(self, CHAN_BODY, sprintf("player/pl_slosh%g.wav", floor(random() * 4) + 1),
              0.8, ATTN_NORM);

    // Horizontal decay.  GoldSrc leans on MOVETYPE_PUSHSTEP's engine friction;
    // FTE has no PUSHSTEP, so the crate damps itself.
    float decel = PUSH_AIR_DECEL;
    if (in_water)       decel = PUSH_WATER_DECEL;
    else if (grounded)  decel = PUSH_GROUND_DECEL;

    vector hv = self.velocity;  hv_z = 0;
    float  hs = vlen(hv);
    if (hs > 0)
    {
        float ns = hs - hs * decel * dt;
        if (ns < PUSH_STOP_SPEED)
            ns = 0;
        hv = (ns > 0) ? (hv * (ns / hs)) : '0 0 0';
        self.velocity_x = hv_x;
        self.velocity_y = hv_y;
    }

    FuncPushable_CollideWorld(dt);

    // Publish while in transit so the carry + geometry-push pass runs against
    // the player on both sides; drop out when parked so it costs nothing.
    float moving = (self.velocity != '0 0 0');
    if (moving != self.push_moving)
    {
        if (moving) MovingBrush_AddToList(self);
        else        MovingBrush_RemoveFromList(self);
        self.push_moving = moving;
    }

    if (moving)
        self.SendFlags = 1;     // ship the new origin/velocity to CSQC

    // sv_debug_pushable: the settle behaviour (does it land, does it jitter on
    // the floor, does it float or sink) is the part of this that a headless
    // server CAN be asked about, so make it askable.  Same idiom as
    // sv_debug_func_train / sv_debug_use.  Two lines because fteqcc caps
    // varargs at 8.
    if (cvar("sv_debug_pushable"))
    {
        dprint(sprintf("[pushable] t=%g org=%v vel=%v ground=%g\n",
                       time, self.origin, self.velocity, grounded));
        dprint(sprintf("           sub=%.2f surf=%g bottom=%g maxspd=%g buoy=%g\n",
                       submerged, (surf == PUSH_NO_WATER) ? 0 : surf,
                       bottom, self.push_maxspeed, self.buoyancy));
    }

    self.think     = func_pushable_tick;
    self.nextthink = self.ltime + (moving ? dt : PUSH_TICK_IDLE);
};

// CPushable::Move, kept structurally identical so the feel matches.
// `push` = 1 for the touch path (GoldSrc additionally requires the toucher to be
// holding +forward or +use there; the mod has no server-side movement-key state,
// so the toucher's own velocity stands in - which is the thing that flag was
// proxying for anyway, and it rejects a player merely resting against the box).
void(entity toucher, float push) FuncPushable_Move =
{
    if (!toucher || toucher == world)
        return;

    // Standing ON the crate is not pushing it - GoldSrc only lets a rider
    // transfer vertical motion, and only while it floats.  Gate on being IN
    // water rather than on the buoyancy key: a floatable crate sitting on dry
    // ground should not sink under someone's weight.
    if ((toucher.flags & FL_ONGROUND) && toucher.groundentity == self)
    {
        if (self.push_in_water)
            self.velocity_z = self.velocity_z + toucher.velocity_z * 0.1;
        return;
    }

    float is_player = (toucher.flags & FL_CLIENT) != 0;
    float factor;
    if (is_player)
    {
        if (!(toucher.flags & FL_ONGROUND))
        {
            // Jumping/falling players do not shove crates around - but a
            // swimmer pushing a raft does, which is the whole point of a
            // floating crate.
            if (!self.push_in_water)
                return;
            factor = PUSH_FACTOR_WATER;
        }
        else
            factor = PUSH_FACTOR_GROUND;

        if (push)
        {
            // Stand-in for GoldSrc's IN_FORWARD|IN_USE gate - a player who is
            // not actually moving is leaning, not pushing.
            vector tv = toucher.velocity;  tv_z = 0;
            if (vlen(tv) < 16)
                return;
        }
    }
    else
        factor = PUSH_FACTOR_OTHER;

    self.velocity_x = self.velocity_x + toucher.velocity_x * factor;
    self.velocity_y = self.velocity_y + toucher.velocity_y * factor;

    vector hv = self.velocity;  hv_z = 0;
    float  len = vlen(hv);
    if (push && len > self.push_maxspeed)
    {
        self.velocity_x = self.velocity_x * self.push_maxspeed / len;
        self.velocity_y = self.velocity_y * self.push_maxspeed / len;
    }

    if (is_player)
    {
        // GoldSrc glues the pusher's horizontal velocity to the crate's, which
        // is what stops the player from walking through it while it accelerates.
        toucher.velocity_x = self.velocity_x;
        toucher.velocity_y = self.velocity_y;

        if (time - self.push_sound_time > PUSH_SOUND_GAP)
        {
            self.push_sound_time = time;
            if (len > 0)
                sound(self, CHAN_WEAPON,
                      sprintf("debris/pushbox%g.wav", floor(random() * 3) + 1),
                      0.5, ATTN_NORM);
        }
    }

    // Wake the tick immediately rather than waiting out the idle interval.
    if (self.velocity != '0 0 0' && self.nextthink > self.ltime + FuncTrain_TickInterval())
        self.nextthink = self.ltime + FuncTrain_TickInterval();
};

void() func_pushable_touch =
{
    FuncPushable_Move(other, 1);
};

// CPushable::Use - a trigger breaks it (when breakable), a player shoves it.
//
// GoldSrc splits on `pActivator->IsPlayer()`, which a BUTTON chain also
// satisfies: the button forwards the pressing player as the activator, so a
// mapper's trigger->pushable link gets read as a shove.  sv_use_is_player_direct
// (set only inside SV_PlayerTryUse, cleared by Trigger_UseTargets) is the same
// question asked accurately, so the chain breaks it and a hand on the crate
// pushes it.
void() func_pushable_use =
{
    if (!sv_use_is_player_direct)
    {
        if ((self.spawnflags & PUSH_BREAKABLE) && self.on_killed)
            self.on_killed();
        return;
    }
    if (activator && (activator.flags & FL_CLIENT) && activator.velocity != '0 0 0')
        FuncPushable_Move(activator, 0);
};

// PushMove leaves .ltime unadvanced while obstructed, and the think only fires
// when thinktime > oldltime - so a crate that kept driving into whatever blocked
// it would wedge forever.  Dropping the velocity lets the next frame's zero-
// length push succeed, ltime advance, and the think resume.
void() func_pushable_blocked =
{
    self.velocity = '0 0 0';
};

/*QUAKED func_pushable (0 .5 .8) ? x x x REPAIRABLE MONSTERS_IGNORE SHOW_HUD_INFO x BREAKABLE INSTANT_BREAK EXPLOSIVES_ONLY LIFTABLE
Sven Co-op / GoldSrc pushable crate: a func_breakable you can shove around.
Walk into it to push it, or +use it while moving to nudge it sideways.
Falls under gravity and floats on water (baked BSP water and func_water alike).

  "health"          hit points (needs the BREAKABLE flag to matter)
  "material"        0=Glass 1=Wood 2=Metal 3=Flesh 4=CinderBlock 5=CeilingTile
                     6=Computer 7=UnbreakableGlass 8=Rocks
  "friction"        0-400, higher is heavier.  Max push speed is 400 - friction,
                     so 400 is effectively unpushable (Sven's own advice).
  "buoyancy"        how well it floats; 0 sinks (GoldSrc spelt this "skin")
  "gibmodel"        custom debris model (bridged onto func_breakable's "mdl")
  "target"/"delay"  fired when it breaks
  "rendermode" "renderamt" "rendercolor" "renderfx"  as func_wall

Flags:
  8    Repairable      PARSED, NOT IMPLEMENTED (no wrench-repair system)
  16   Monsters Ignore PARSED, NOT IMPLEMENTED (no monster AI)
  32   Show HUD Info   PARSED, NOT IMPLEMENTED (no "displayname" HUD readout)
  128  Breakable       full func_breakable behaviour: HP, debris, break sound, target
  256  1-Hit Break     any melee weapon destroys it in one hit
  512  Explosives Only bullet-proof; only radius explosions damage it
  1024 Liftable        PARSED, NOT IMPLEMENTED (Sven documents it as heavily bugged
                        and advises against using it)
*/
void() func_pushable =
{
    // Sven "Gib model" is func_breakable's "mdl" under another name - bridge it
    // BEFORE the breakable spawn, which is what precaches and indexes it.
    if (self.gibmodel != "" && self.mdl == "")
        self.mdl = self.gibmodel;

    // Flag translation (see the header) - must also happen before the breakable
    // spawn, which reads spawnflags to decide takedamage and the touch handler.
    //
    // Tell Break_NormaliseFlags to keep its hands off: func_pushable's Sven
    // flag space is NOT func_breakable's (128 Breakable / 512 Explosives Only /
    // 1024 Liftable vs 1 Only Trigger / 2 Touch / 4 Pressure), so running the
    // breakable translation over these bits would corrupt them.  We do our own
    // translation right here instead.
    self.break_skip_normalise = 1;

    if (self.spawnflags & PUSH_EXPLOSIVES_ONLY)
        self.spawnflags = self.spawnflags | BREAKABLE_ONLY_EXPLOSION;
    else if (self.spawnflags & PUSH_BREAKABLE)
        self.spawnflags = self.spawnflags | BREAKABLE_ALWAYS_SHOOTABLE;

    if (self.spawnflags & PUSH_BREAKABLE)
    {
        func_breakable();               // HP, material, debris, break sound, target chain
        if (wasfreed(self))
            return;                     // no model - func_breakable already removed it
    }
    else
    {
        // Not breakable: still a replicated brush, just not damageable.
        SV_InitReplicatedSolidBrush();
        if (wasfreed(self))
            return;
        if (self.material != 0)
            self.style = self.material;
        self.takedamage = DAMAGE_NO;
    }

    self.brush_type = BRUSH_TYPE_TRAIN;

    // GoldSrc: MaxSpeed() = 400 - friction, friction clamped to 399, then the
    // field is ZEROED so the engine's own friction handling can never see it.
    if (self.friction > PUSH_MAX_FRICTION)
        self.friction = PUSH_MAX_FRICTION;
    self.push_maxspeed = PUSH_BASE_SPEED - self.friction;
    self.friction      = 0;

    // Legacy spelling: GoldSrc stored buoyancy in pev->skin.  Clear it either
    // way - a NEGATIVE .skin on a brush entity is FTE's contents override, so
    // leaving one on a crate would turn it into a pool of water.
    if (self.buoyancy == 0 && self.skin > 0)
        self.buoyancy = self.skin;
    self.skin = 0;

    self.push_spawn_origin = self.origin;

    // Touch has to win over func_breakable's TOUCH-flag handler: a pushable is
    // pushed by walking into it, never shattered by it.  (A Sven pushable does
    // not expose the TOUCH flag at all, so nothing legitimate is being lost.)
    self.touch   = func_pushable_touch;
    self.use     = func_pushable_use;
    self.blocked = func_pushable_blocked;

    precache_sound("debris/pushbox1.wav");
    precache_sound("debris/pushbox2.wav");
    precache_sound("debris/pushbox3.wav");
    precache_sound("player/pl_slosh1.wav");   // water entry
    precache_sound("player/pl_slosh2.wav");
    precache_sound("player/pl_slosh3.wav");
    precache_sound("player/pl_slosh4.wav");

    self.think     = func_pushable_tick;
    self.nextthink = self.ltime + PUSH_TICK_IDLE;
};

// Round reset.  Called from BreakableResetAll (sv_breakable.qc) - a pushable
// needs its SPAWN ORIGIN back as well as its health, which a func_breakable
// never does because a func_breakable never moves.
void() FuncPushable_ResetAll =
{
    entity e = nextent(world);
    while (e)
    {
        if (e.classname == "func_pushable")
        {
            e.velocity  = '0 0 0';
            e.avelocity = '0 0 0';
            setorigin(e, e.push_spawn_origin);

            if (e.push_moving)
            {
                MovingBrush_RemoveFromList(e);
                e.push_moving = 0;
            }

            if (e.breakable_broken)
            {
                setmodel(e, e.breakable_model);
                e.solid                       = SOLID_BSP;
                e.movetype                    = MOVETYPE_PUSH;
                e.health                      = e.max_health;
                e.breakable_broken            = FALSE;
                e.breakable_next_impact_sound = 0;
                e.on_damaged                  = BreakableDamaged;
                e.on_killed                   = func_breakable_break;

                if (e.spawnflags & BREAKABLE_ONLY_EXPLOSION)
                    e.takedamage = DAMAGE_NO;
                else if (e.style == BREAKABLE_UNBREAKABLE_GLASS)
                    e.takedamage = DAMAGE_NO;
                else if (e.spawnflags & PUSH_BREAKABLE)
                    e.takedamage = DAMAGE_YES;
                else
                    e.takedamage = DAMAGE_NO;

                // Re-arm the pushable handlers - func_breakable_break cleared
                // solid/movetype and BreakableResetAll's own re-arm doesn't run
                // for this class.
                e.touch   = func_pushable_touch;
                e.use     = func_pushable_use;
                e.blocked = func_pushable_blocked;

                // .ltime froze the moment the break dropped it to MOVETYPE_NONE,
                // so it is now a whole round behind world time.  Resync before
                // scheduling - nextthink is measured against ltime once the
                // pusher physics resume, and the engine only fires a think when
                // thinktime > the ltime it had at the START of the frame.
                e.ltime     = time;
                e.think     = func_pushable_tick;
                e.nextthink = e.ltime + PUSH_TICK_IDLE;
            }

            e.SendFlags = -1;   // see BreakableResetAll: |= 1 can look unchanged
        }
        e = nextent(e);
    }
};
