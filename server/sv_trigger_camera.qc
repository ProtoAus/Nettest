//
//  sv_trigger_camera.qc  —  Sven Co-op trigger_camera + trigger_cameratarget
//
//  A cutscene camera: on trigger it takes over the view of one or all players
//  for `wait` seconds, optionally travelling a path_corner chain and aiming at
//  a target entity, then hands the view back.
//
//  DESIGN: the player's BODY NEVER MOVES.  Only the view is swapped, which is
//  what Sven does and what the map expects (players are frozen in place mid-
//  level, sometimes with monsters around them).  That is deliberately NOT how
//  sv_cameras.qc's team-select camera works — Camera_PlacePlayerAtCurrent
//  teleports the player edict to the camera, which is right for a pre-spawn
//  lobby and wrong here.  Keeping the body put also means prediction keeps
//  running untouched; the freeze is a separate, replicated concern.
//
//  So the split is:
//    server  — owns camera position/angles, path travel, hold time, binding
//    CSQC    — reads the bound camera's pose and overrides VF_ORIGIN/VF_ANGLES
//
//  and the wire is a CSQC_ENT_TRIGGER_CAMERA entity (the pose, broadcast) plus
//  the per-player STAT_CUTSCENE (which camera this player is bound to, and how
//  their HUD should look).
//
//  ANGLE CONVENTIONS — the one thing that will silently invert every cutscene:
//    - a map's `angles` key is already in VIEW convention (positive pitch =
//      down), so it is used as-is.
//    - vectoangles() returns ENTITY convention (positive pitch = up), so an
//      aim direction must have its pitch negated before it becomes a view
//      angle.  sv_cameras.qc does this same flip at its consumer
//      (Camera_PlacePlayerAtCurrent); we do it once here, at the source, and
//      everything downstream is view convention.
//

void(entity caller, entity who, float useType) SUB_UseTargets;    // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;          // sv_triggers.qc
entity(entity from) FuncTrain_NextCorner;                         // sv_func_train.qc
float() FuncTrain_TickInterval;                                   // sv_func_train.qc
void(entity player) PM_SyncPredictionProxy;                       // sv_player.qc
void() SV_InitReplicatedSolidBrush;                               // sv_brushsync.qc
float(entity attacker, entity target, float damage) W_ApplyDamage; // sv_weapons.qc

// ---------------------------------------------------------------------------
//  Spawnflags
// ---------------------------------------------------------------------------
const float CAMF_START_AT_PLAYER = 1;
const float CAMF_FOLLOW_PLAYER   = 2;
const float CAMF_FREEZE_PLAYER   = 4;
const float CAMF_ALL_PLAYERS     = 8;
const float CAMF_FORCE_VIEW      = 16;
// The wiki's own text for bit 32 contradicts itself — it is named "No Instant
// Turn" but the body says "it will turn instantaneously".  Implemented as
// flag-set = snap straight to the aim, flag-clear = start already facing the
// target and track it at `turnspeed`, which is the reading that makes
// `turnspeed` mean something in the common case.  No entity in either
// reference map sets it, so the blast radius of being wrong is nil.
const float CAMF_NO_INSTANT_TURN = 32;
const float CAMF_INSTANT_MOVE    = 64;
const float CAMF_MOUSE_CURSOR    = 128;
const float CAMF_INVULNERABLE    = 256;
const float CAMF_IGNORE_HOLDTIME = 512;

// ---------------------------------------------------------------------------
//  Keys
// ---------------------------------------------------------------------------
.string moveto;                 // first path_corner / path_track
.float  turnspeed;              // degrees/sec when tracking a moving target
.float  acceleration;           // units/sec^2
.float  deceleration;           // units/sec^2
.float  max_player_count;
.string max_player_target;      // fired when a player is turned away at the cap
.float  hud_health;             // Sven: 0 hides the element
.float  hud_flashlight;
.float  hud_weapons;
.string cursor_sprite;
.string m_iszoverrideplayertargetname;
.string m_isztargetwhenplayerstartsusing;
.string m_isztargetwhenplayerstopsusing;
.string m_iszturnedofftarget;
// Accepted and ignored — there is no AngelScript VM in this engine and there
// is not going to be one.  Declared so they bind instead of falling through to
// ED_ParseUnknownEpair and becoming junk multi_manager slots.
.string m_iszasmouseeventcallbackname;
.string m_iszaskeyinputcallbackname;

// ---------------------------------------------------------------------------
//  Live state
// ---------------------------------------------------------------------------
// Authored home pose.  A camera that plays a second time must start from its
// map position again, not from wherever the previous run's path left it.
.vector cam_start_origin;
.vector cam_start_angles;
.entity cam_path_target;        // corner we are travelling toward
.float  cam_path_wait;          // corner dwell timer
.float  cam_end_time;           // when the hold expires
.float  cam_cur_speed;          // current travel speed, for accel/decel
.vector cam_view_angles;        // VIEW-convention pose sent on the wire
.float  cam_bound_count;
.float  cam_serial;             // bumped per activation so CSQC can detect a restart

.entity cutscene_cam;           // player -> the camera they are bound to
.float  cutscene_saved_movetype; // player's pm_movetype before the freeze
.string cutscene_saved_targetname;
// .cutscene_immune is declared in sv_customdefs.qc — W_CanDamageTarget reads it
// and compiles far ahead of this file.

entity cutscene_active_cam;     // only one cutscene plays at a time

void() Cutscene_ResetState =
{
    cutscene_active_cam = world;
};

// ---------------------------------------------------------------------------
//  Binding / releasing players
// ---------------------------------------------------------------------------

// Compose the packed STAT_CUTSCENE value for one bound player.
float(entity cam) Cutscene_StatFor =
{
    float v = num_for_edict(cam) & CUTSCENE_ENT_MASK;

    if (cam.spawnflags & CAMF_FREEZE_PLAYER) v = v | CUTSCENE_SF_FREEZE;
    if (cam.spawnflags & CAMF_MOUSE_CURSOR)  v = v | CUTSCENE_SF_CURSOR;
    // Sven's hud_* keys are "0 = hide"; absent means show, and absent parses
    // as 0 — so an unset key would read as "hide everything".  Treat the
    // documented default (show) as anything other than an explicit -1/0 pair
    // by requiring the mapper to have set the key at all, which we detect by
    // the value being negative (Sven writes -1 for "no override").
    if (cam.hud_health     < 0) v = v | CUTSCENE_SF_NOHEALTH;
    if (cam.hud_flashlight < 0) v = v | CUTSCENE_SF_NOFLASH;
    if (cam.hud_weapons    < 0) v = v | CUTSCENE_SF_NOWEAPONS;

    return v;
};

void(entity p, entity cam) Cutscene_BindPlayer =
{
    if (p.cutscene_cam == cam)
        return;

    p.cutscene_cam      = cam;
    p.sv_cutscene_stat  = Cutscene_StatFor(cam);
    cam.cam_bound_count = cam.cam_bound_count + 1;

    // PUNCH THE SERVER'S PVS OPEN AT THE CAMERA.
    //
    // The cutscene view is entirely client-side (CSQC reads STAT_CUTSCENE and
    // overrides VF_ORIGIN/VF_ANGLES), so as far as the server is concerned the
    // player never left their spawn point.  SV_Snapshot_SetupPVS builds the
    // snapshot's PVS from the client edict's origin — which means every entity
    // the camera is pointed at gets culled unless it happens to share a leaf
    // with the frozen player.  The world BSP still draws (the client renders it
    // from its own viewleaf) so the shot looks "right but empty", and the usual
    // symptom is a missing brush entity: th_ep1_00's intro camera watches
    // func_tracktrain "pickup" from ~2900 qu away and the truck was never sent
    // at all.  Worse, brushsync sets PVSF_NOREMOVE, so a replica that HAD been
    // sent before the cutscene just froze at its last known position forever.
    //
    // .view2 is FTE's secondary-viewpoint field and its documented side effect
    // is exactly what's needed: SV_Snapshot_SetupPVS calls SV_AddCameraEntity
    // for it, unioning the camera's PVS into the player's.  Deliberately NOT
    // .clientcamera (DP_SV_CLIENTCAMERA): that one REPLACES the view entity —
    // it emits svc_setview, moves cl.viewentity (so CSQC's player_localentnum
    // stops matching the player) and forces pm_type PMC_NONE, disabling
    // prediction.  .view2 changes nothing about the view: it only sets
    // STAT_VIEW2, and the client's corner viewport stays unrendered unless the
    // user has explicitly set the v2_* sideview cvars (default off).
    p.view2 = cam;

    if (cam.spawnflags & CAMF_FREEZE_PLAYER)
    {
        // PM_MOVETYPE_NONE is the prediction-safe freeze: the field replicates
        // through PM_SF_MOVEMENT and is restored on every reconcile replay, so
        // the client stops moving on the same frame the server does.  Zeroing
        // input server-side instead would slide-then-snap.
        p.cutscene_saved_movetype = p.pm_movetype;
        p.pm_movetype = PM_MOVETYPE_NONE;
        p.velocity    = '0 0 0';
        PM_SyncPredictionProxy(p);
    }

    if (cam.spawnflags & CAMF_INVULNERABLE)
        p.cutscene_immune = 1;

    if (cam.m_iszoverrideplayertargetname != "")
    {
        p.cutscene_saved_targetname = p.targetname;
        p.targetname = cam.m_iszoverrideplayertargetname;
    }

    if (cvar("sv_debug_cutscene"))
        dprint(sprintf("[cutscene] bind %s -> \"%s\" stat=%g\n",
                       p.netname, cam.targetname, p.sv_cutscene_stat));
};

void(entity p) Cutscene_ReleasePlayer =
{
    entity cam = p.cutscene_cam;
    if (!cam)
        return;

    if (cam.spawnflags & CAMF_FREEZE_PLAYER)
    {
        // Restore whatever they had, not a hardcoded NORMAL — a player who was
        // in a vehicle or noclipping when the cutscene grabbed them must not be
        // silently reset to walking.
        p.pm_movetype = p.cutscene_saved_movetype;
        PM_SyncPredictionProxy(p);
    }

    if (cam.m_iszoverrideplayertargetname != "")
        p.targetname = p.cutscene_saved_targetname;

    p.cutscene_immune  = 0;
    p.cutscene_cam     = world;
    p.sv_cutscene_stat = 0;
    p.view2            = world;   // stop unioning the camera's PVS — see BindPlayer

    if (cam.cam_bound_count > 0)
        cam.cam_bound_count = cam.cam_bound_count - 1;
};

void(entity cam) Cutscene_ReleaseAll =
{
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.cutscene_cam == cam)
            Cutscene_ReleasePlayer(p);
        p = nxt;
    }
    cam.cam_bound_count = 0;
};

// ---------------------------------------------------------------------------
//  Aiming
// ---------------------------------------------------------------------------

// Resolve what this camera should be looking at right now, as a world point.
// Returns world (and leaves `out` untouched) when the camera has no aim, in
// which case its authored `angles` stand.
entity(entity cam) Cutscene_AimEntity =
{
    if (cam.spawnflags & CAMF_FOLLOW_PLAYER)
        return cam.enemy;               // the activator, stashed at trigger time
    if (cam.target == "")
        return world;
    return find(world, targetname, cam.target);
};

void(entity cam, float dt) Cutscene_UpdateAngles =
{
    entity aim = Cutscene_AimEntity(cam);
    if (!aim || aim == world)
        return;                         // authored angles stand

    // Aim at the target's CENTRE, not its origin.  A GoldSrc brush entity has
    // origin '0 0 0' unless it carries an ORIGIN brush, and a monster's origin
    // is at its feet — either way, framing on the origin points the camera at
    // the floor or at the map origin.
    vector aimpt = aim.origin;
    if (aim.absmin != aim.absmax)
        aimpt = (aim.absmin + aim.absmax) * 0.5;

    vector dir = aimpt - cam.origin;
    if (vlen(dir) < 0.01)
        return;

    vector want = vectoangles(normalize(dir));
    want_x = -want_x;                   // entity convention -> view convention
    want_z = 0;

    if (cam.spawnflags & CAMF_NO_INSTANT_TURN)
    {
        cam.cam_view_angles = want;     // snap
        return;
    }

    // Slew toward the aim at turnspeed.  On the first frame of a cutscene the
    // camera is already facing its target (Cutscene_Start seeds the angles), so
    // this only ever does work when the TARGET moves — which is exactly the
    // case that needs it (pizza_ya_san1's cam_mi films a walking monster).
    float rate = cam.turnspeed;
    if (rate <= 0)
    {
        cam.cam_view_angles = want;
        return;
    }

    float step = rate * dt;
    vector cur = cam.cam_view_angles;
    float dyaw   = anglemod(want_y - cur_y + 180) - 180;
    float dpitch = anglemod(want_x - cur_x + 180) - 180;

    if (fabs(dyaw)   > step) dyaw   = (dyaw   > 0) ? step : -step;
    if (fabs(dpitch) > step) dpitch = (dpitch > 0) ? step : -step;

    cam.cam_view_angles_x = cur_x + dpitch;
    cam.cam_view_angles_y = cur_y + dyaw;
    cam.cam_view_angles_z = 0;
};

// ---------------------------------------------------------------------------
//  Path travel
// ---------------------------------------------------------------------------
void(entity cam, float dt) Cutscene_UpdateMove =
{
    entity relay;       // QC locals are function-scoped
    if (!cam.cam_path_target)
        return;

    if (cam.cam_path_wait > time)
        return;                         // dwelling at a corner

    vector delta = cam.cam_path_target.origin - cam.origin;
    float  dist  = vlen(delta);

    // Per-corner speed override, same rule func_train uses.
    float target_speed = cam.speed;
    if (cam.cam_path_target.speed > 0)
        target_speed = cam.cam_path_target.speed;
    if (target_speed <= 0)
        target_speed = 100;

    if (cam.spawnflags & CAMF_INSTANT_MOVE)
    {
        setorigin(cam, cam.cam_path_target.origin);
        dist = 0;
    }
    else
    {
        // Accelerate toward the corner speed, and decelerate into the LAST
        // corner of the chain so the camera settles instead of stopping dead.
        // Neither func_train nor func_tracktrain implements accel at all, so
        // there is nothing to reuse here.
        float accel = cam.acceleration;
        float decel = cam.deceleration;

        float want = target_speed;
        if (decel > 0 && !FuncTrain_NextCorner(cam.cam_path_target))
        {
            // v = sqrt(2*a*d) is the fastest we can still stop in `dist`.
            float vmax = sqrt(2 * decel * max(dist, 0));
            if (vmax < want) want = vmax;
        }

        if (accel > 0 && cam.cam_cur_speed < want)
            cam.cam_cur_speed = min(want, cam.cam_cur_speed + accel * dt);
        else
            cam.cam_cur_speed = want;

        float advance = cam.cam_cur_speed * dt;
        if (advance >= dist)
        {
            setorigin(cam, cam.cam_path_target.origin);
            dist = 0;
        }
        else
        {
            setorigin(cam, cam.origin + (delta / dist) * advance);
            return;                     // still travelling
        }
    }

    // Arrived.  Honour the corner's dwell, fire its message, then advance.
    entity corner = cam.cam_path_target;

    if (corner.message != "")
    {
        relay = spawn();
        relay.classname = "cam_corner_fire";
        relay.target    = corner.message;
        SUB_UseTargets(relay, cam.enemy, USE_TOGGLE);
        remove(relay);
    }

    if (corner.wait > 0)
        cam.cam_path_wait = time + corner.wait;

    cam.cam_path_target = FuncTrain_NextCorner(corner);
    cam.cam_cur_speed   = 0;

    if (cvar("sv_debug_cutscene"))
        dprint(sprintf("[cutscene] \"%s\" reached corner \"%s\", next=\"%s\"\n",
                       cam.targetname, corner.targetname,
                       cam.cam_path_target ? cam.cam_path_target.targetname : "(end)"));
};

// ---------------------------------------------------------------------------
//  Per-tick driver
// ---------------------------------------------------------------------------
void() Cutscene_Stop;

void() trigger_camera_think =
{
    float dt = FuncTrain_TickInterval();
    self.nextthink = time + dt;

    if (cutscene_active_cam != self)
        return;                         // superseded by a later camera

    Cutscene_UpdateMove(self, dt);
    Cutscene_UpdateAngles(self, dt);

    self.angles    = self.cam_view_angles;
    self.SendFlags = 1;

    // Drop anyone who died mid-cutscene (unless Force View says otherwise) or
    // who left.  Without this their bind — and, worse, their FREEZE — outlives
    // the reason for it: a player who respawns still holding pm_movetype NONE
    // is stuck standing still with no way out.
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.cutscene_cam == self
            && p.is_dead && !(self.spawnflags & CAMF_FORCE_VIEW))
            Cutscene_ReleasePlayer(p);
        p = nxt;
    }

    if (!(self.spawnflags & CAMF_IGNORE_HOLDTIME) && time >= self.cam_end_time)
        Cutscene_Stop();
};

void() Cutscene_Stop =
{
    entity relay;       // QC locals are function-scoped
    entity cam = self;

    if (cvar("sv_debug_cutscene"))
        dprint(sprintf("[cutscene] stop \"%s\"\n", cam.targetname));

    Cutscene_ReleaseAll(cam);
    cam.nextthink = 0;

    if (cutscene_active_cam == cam)
        cutscene_active_cam = world;

    if (cam.m_isztargetwhenplayerstopsusing != "")
    {
        relay = spawn();
        relay.classname = "cam_stop_fire";
        relay.target    = cam.m_isztargetwhenplayerstopsusing;
        SUB_UseTargets(relay, cam.enemy, USE_TOGGLE);
        remove(relay);
    }
    if (cam.m_iszturnedofftarget != "")
    {
        relay = spawn();
        relay.classname = "cam_off_fire";
        relay.target    = cam.m_iszturnedofftarget;
        SUB_UseTargets(relay, cam.enemy, USE_TOGGLE);
        remove(relay);
    }
};

float(entity playerent, float changedflags) trigger_camera_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_TRIGGER_CAMERA);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    // WriteCoord, NOT WriteAngle, for the same reason sv_cameras.qc uses
    // coords for its camera angles: MSG_WriteAngle drops to 8 bits when the
    // protocol's anglesize is 1 (common.c MSG_WriteAngle8), i.e. 1.4 degrees
    // per step.  That is invisible on a player's yaw and glaring on a camera
    // the viewer is looking straight down.
    WriteCoord(MSG_ENTITY, self.cam_view_angles_x);
    WriteCoord(MSG_ENTITY, self.cam_view_angles_y);
    WriteCoord(MSG_ENTITY, self.cam_view_angles_z);
    WriteByte(MSG_ENTITY, self.cam_serial & 255);
    return TRUE;
};

// ---------------------------------------------------------------------------
//  Activation
// ---------------------------------------------------------------------------
void() trigger_camera_use =
{
    entity relay;       // QC locals are function-scoped
    if (!IsMasterTriggered(self.master, activator))
        return;

    // Re-triggering the camera that is already playing turns it OFF.  That is
    // the only way to end a camera flagged Ignore Hold Time.
    if (cutscene_active_cam == self)
    {
        Cutscene_Stop();
        return;
    }

    // "Triggering another camera when previous is still playing overrides
    // first camera" — release the old one before taking over, or its players
    // stay frozen forever.
    if (cutscene_active_cam)
    {
        entity oldself = self;
        self = cutscene_active_cam;
        Cutscene_Stop();
        self = oldself;
    }

    self.enemy = activator;             // Follow Player / chain activator

    // Build the audience.
    float want_all = (self.spawnflags & CAMF_ALL_PLAYERS);
    float cap = self.max_player_count;
    float bound = 0;
    float turned_away = 0;

    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        float take = want_all || (p == activator);

        // A dead player only gets the view with Force View; otherwise the
        // cutscene would fight the death cam for the camera.
        if (take && p.is_dead && !(self.spawnflags & CAMF_FORCE_VIEW))
            take = FALSE;

        // max_player_count applies only when All Players is off (Sven's own
        // wording), so the activator-only case is the one it can gate.
        if (take && !want_all && cap > 0 && bound >= cap)
        {
            take = FALSE;
            turned_away = 1;
        }

        if (take)
        {
            Cutscene_BindPlayer(p, self);
            bound = bound + 1;
        }
        p = nxt;
    }

    if (turned_away && self.max_player_target != "")
    {
        relay = spawn();
        relay.classname = "cam_full_fire";
        relay.target    = self.max_player_target;
        SUB_UseTargets(relay, activator, USE_TOGGLE);
        remove(relay);
    }

    if (!bound)
        return;                         // nobody to show it to

    cutscene_active_cam = self;
    self.cam_serial     = self.cam_serial + 1;
    self.cam_cur_speed  = 0;
    self.cam_path_wait  = 0;

    // Start at Player: begin at the activator's eye and fly onto the path.
    if ((self.spawnflags & CAMF_START_AT_PLAYER) && activator)
    {
        setorigin(self, activator.origin + activator.view_ofs);
        self.cam_view_angles = activator.v_angle;
    }
    else
    {
        setorigin(self, self.cam_start_origin);
        // A map's `angles` key is already view convention — use it as-is.
        self.cam_view_angles = self.cam_start_angles;
    }

    // Seed the angles onto the aim so the cutscene opens already framed, then
    // let turnspeed handle only the tracking from there.  Passing a huge dt
    // makes the slew a snap for this one call.
    Cutscene_UpdateAngles(self, 100000);

    self.cam_path_target = world;
    if (self.moveto != "")
    {
        self.cam_path_target = find(world, targetname, self.moveto);
        if (!self.cam_path_target && cvar("sv_debug_cutscene"))
            dprint(sprintf("[cutscene] \"%s\" moveto \"%s\" not found\n",
                           self.targetname, self.moveto));
    }

    float hold = self.wait;
    if (hold <= 0) hold = 10;
    self.cam_end_time = time + hold;

    self.think     = trigger_camera_think;
    self.nextthink = time + FuncTrain_TickInterval();
    self.SendFlags = 1;

    if (self.m_isztargetwhenplayerstartsusing != "")
    {
        relay = spawn();
        relay.classname = "cam_start_fire";
        relay.target    = self.m_isztargetwhenplayerstartsusing;
        SUB_UseTargets(relay, activator, USE_TOGGLE);
        remove(relay);
    }

    if (cvar("sv_debug_cutscene"))
        dprint(sprintf("[cutscene] start \"%s\" players=%g hold=%g path=%s flags=%g\n",
                       self.targetname, bound, hold,
                       self.moveto != "" ? self.moveto : "(static)", self.spawnflags));

    SUB_UseTargets(self, activator, USE_TOGGLE);
};

/*QUAKED trigger_camera (.3 .3 .8) (-8 -8 -8) (8 8 8) START_AT_PLAYER FOLLOW_PLAYER FREEZE_PLAYER ALL_PLAYERS FORCE_VIEW NO_INSTANT_TURN INSTANT_MOVE MOUSE_CURSOR INVULNERABLE IGNORE_HOLDTIME
Sven Co-op cutscene camera.  On trigger it takes over the view for `wait`
seconds.  The player's body does not move.

"wait"         hold time in seconds (default 10)
"target"       entity to aim at (info_target, a monster, a brush with an ORIGIN)
"moveto"       first path_corner / path_track of a travel path
"speed"        travel speed
"acceleration" units/sec^2 while speeding up
"deceleration" units/sec^2 into the final corner
"turnspeed"    degrees/sec when tracking a moving target
"angles"       start pose when not aiming at anything
"max_player_count" / "max_player_target"   audience cap (All Players off only)
"hud_health" / "hud_flashlight" / "hud_weapons"   set -1 to hide that element
"m_iszOverridePlayerTargetname"            renames bound players for the duration
"m_iszTargetWhenPlayerStartsUsing" / "...StopsUsing" / "m_iszTurnedOffTarget"
"cursor_sprite"                            cursor image with the MOUSE_CURSOR flag
"m_iszASMouseEventCallbackName" / "m_iszASKeyInputCallbackName"  accepted, ignored
*/
void() trigger_camera =
{
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    self.modelindex = 0;
    self.use        = trigger_camera_use;

    // Remember the authored pose: `origin`/`angles` are the camera's home, and
    // a camera that plays twice must start from there again rather than from
    // wherever the previous run's path left it.
    self.cam_start_origin = self.origin;
    self.cam_start_angles = self.angles;
    self.cam_view_angles  = self.angles;

    if (!self.turnspeed) self.turnspeed = 40;

    // Broadcast: the pose has to reach players who are nowhere near the camera
    // — that is the entire point of a cutscene.
    self.pvsflags   = PVSF_IGNOREPVS;
    self.SendEntity = trigger_camera_SendEntity;
    self.SendFlags  = 1;

    if (self.cursor_sprite != "")
        precache_model(self.cursor_sprite);
};

// ---------------------------------------------------------------------------
//  trigger_cameratarget
// ---------------------------------------------------------------------------
//  A brush you click during a MOUSE_CURSOR cutscene.  Three buttons x
//  single/double click, each with its own action, parameter and target.
//
//  Sven's key layout is mouse_<field>_<button>_<double>, e.g.
//  mouse_action_0_1 = left button, double click.
// ---------------------------------------------------------------------------
const float CAMTGT_SF_INVISIBLE = 1;
const float CAMTGT_SF_START_OFF = 2;

const float CAMTGT_ACT_NOTHING = 0;
const float CAMTGT_ACT_TRIGGER = 1;
const float CAMTGT_ACT_ON      = 2;
const float CAMTGT_ACT_OFF     = 3;
const float CAMTGT_ACT_HEAL    = 4;
const float CAMTGT_ACT_HURT    = 5;
const float CAMTGT_ACT_EXIT    = 6;

.float  mouse_action_0_0; .float mouse_param_0_0; .string mouse_target_0_0;
.float  mouse_action_0_1; .float mouse_param_0_1; .string mouse_target_0_1;
.float  mouse_action_1_0; .float mouse_param_1_0; .string mouse_target_1_0;
.float  mouse_action_1_1; .float mouse_param_1_1; .string mouse_target_1_1;
.float  mouse_action_2_0; .float mouse_param_2_0; .string mouse_target_2_0;
.float  mouse_action_2_1; .float mouse_param_2_1; .string mouse_target_2_1;

.float camtgt_enabled;

float(entity e, float btn, float dbl) CamTgt_Action =
{
    if (btn == 0) return dbl ? e.mouse_action_0_1 : e.mouse_action_0_0;
    if (btn == 1) return dbl ? e.mouse_action_1_1 : e.mouse_action_1_0;
    return dbl ? e.mouse_action_2_1 : e.mouse_action_2_0;
};
float(entity e, float btn, float dbl) CamTgt_Param =
{
    if (btn == 0) return dbl ? e.mouse_param_0_1 : e.mouse_param_0_0;
    if (btn == 1) return dbl ? e.mouse_param_1_1 : e.mouse_param_1_0;
    return dbl ? e.mouse_param_2_1 : e.mouse_param_2_0;
};
string(entity e, float btn, float dbl) CamTgt_Target =
{
    if (btn == 0) return dbl ? e.mouse_target_0_1 : e.mouse_target_0_0;
    if (btn == 1) return dbl ? e.mouse_target_1_1 : e.mouse_target_1_0;
    return dbl ? e.mouse_target_2_1 : e.mouse_target_2_0;
};

// Toggle enable/disable — what the Start Off flag waits for.
void() trigger_cameratarget_use =
{
    self.camtgt_enabled = !self.camtgt_enabled;
};

/*QUAKED trigger_cameratarget (.8 .5 .2) ? INVISIBLE START_OFF
Brush clickable during a trigger_camera cutscene that has the MOUSE_CURSOR
flag.  Keys are mouse_<action|param|target>_<button 0-2>_<0 single, 1 double>.

Actions: 0 nothing, 1 trigger, 2 on, 3 off, 4 heal, 5 hurt, 6 exit camera.
*/
void() trigger_cameratarget =
{
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_CAMTARGET;
    self.use        = trigger_cameratarget_use;
    self.camtgt_enabled = !(self.spawnflags & CAMTGT_SF_START_OFF);

    // Invisible still collides and is still clickable — Sven's own note is
    // that it behaves like a CLIP brush that bullets pass through.
    if (self.spawnflags & CAMTGT_SF_INVISIBLE)
        self.effects = self.effects | EF_NODRAW;
};

// ---------------------------------------------------------------------------
//  CSQC -> server click
// ---------------------------------------------------------------------------
//  `self` is the clicking player (engine-set).  Everything here is validated
//  server-side: the entnum arrives from the client and is never trusted.
// ---------------------------------------------------------------------------
.float camtgt_next_click;

void(float entnum, float btn, float dbl) CSEv_camtarget_fff =
{
    entity relay;       // QC locals are function-scoped
    if (self.classname != "player")
        return;
    // Rate limit, same discipline as CSEv_radio_f.  Not politeness: without it
    // a modified client could drive an arbitrary trigger chain at packet rate.
    if (time < self.camtgt_next_click)
        return;
    self.camtgt_next_click = time + 0.1;

    // Must actually be in a cursor-enabled cutscene.
    entity cam = self.cutscene_cam;
    if (!cam || !(cam.spawnflags & CAMF_MOUSE_CURSOR))
        return;

    entity e = edict_num(entnum);
    if (!e || e == world)
        return;
    if (e.classname != "trigger_cameratarget" || !e.camtgt_enabled)
        return;

    if (btn < 0 || btn > 2)
        return;

    float  act   = CamTgt_Action(e, btn, dbl);
    float  param = CamTgt_Param(e, btn, dbl);
    string tname = CamTgt_Target(e, btn, dbl);

    if (cvar("sv_debug_cutscene"))
        dprint(sprintf("[cutscene] click %s btn=%g dbl=%g act=%g target=\"%s\"\n",
                       e.targetname, btn, dbl, act, tname));

    if (act == CAMTGT_ACT_EXIT)
    {
        entity oldself = self;
        self = cam;
        Cutscene_Stop();
        self = oldself;
        return;
    }

    if (act == CAMTGT_ACT_NOTHING || tname == "")
        return;

    if (act == CAMTGT_ACT_HEAL || act == CAMTGT_ACT_HURT)
    {
        entity t = findchain(targetname, tname);
        while (t)
        {
            if (act == CAMTGT_ACT_HEAL)
                t.health = t.health + param;
            else
                W_ApplyDamage(self, t, param);
            t = t.chain;
        }
        return;
    }

    float usetype = USE_TOGGLE;
    if (act == CAMTGT_ACT_ON)  usetype = USE_ON;
    if (act == CAMTGT_ACT_OFF) usetype = USE_OFF;

    relay = spawn();
    relay.classname = "camtgt_fire";
    relay.target    = tname;
    SUB_UseTargets(relay, self, usetype);
    remove(relay);
};
