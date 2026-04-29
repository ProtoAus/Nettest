// ============================================================
//  server/sv_cameras.qc  -  Team-select camera point entities
//
//  Entity: "camera" — fixed viewpoint used while a player is still
//  picking a team. Either set .angles directly in the .map, or set
//  .target to an info_notnull's .targetname and the camera will aim
//  at it on first use. When multiple cameras exist, they cycle every
//  CAMERA_CYCLE_SECONDS seconds across all team-selecting players.
//
//  Fields read from the map:
//      origin      — camera position
//      angles      — direct view angles (used if .target is empty)
//      target      — targetname of an info_notnull to look at
//      spawnflags  — CAM_FLAG_TEAM_BLUE (1)         filter: blue team picked
//                    CAM_FLAG_TEAM_RED (2)          filter: red team picked
//                    CAM_FLAG_TEAM_BLUE_PLAYER (4)  filter: picking blue char
//                    CAM_FLAG_TEAM_RED_PLAYER (8)   filter: picking red char
//                    (no flags = neutral — shown on initial team-pick screen
//                     and used as a fallback when no flagged camera exists)
//
//  NOTE: use "info_notnull" (not "info_null") for aim targets.  Many BSP
//  compilers strip info_null entities at compile time (classic Quake
//  convention — info_null is a light-target helper, not a runtime entity).
//  info_notnull is the compiler-safe equivalent that survives to SSQC.
// ============================================================

const float CAMERA_CYCLE_SECONDS = 7;

// (Sway used to live here — moved to CSQC so the motion runs at render
// rate regardless of ping.  See client/cl_cameras.qc
// CSQC_TeamSelectSwayAngles.)

.entity camera_next;   // linked-list chain
.float  cam_resolved;  // per-camera: 1 once .target resolution has been attempted
.float  cam_target_warned;  // per-camera: 1 once we've bprint'd a "really missing" warning
.vector cam_target_origin;  // resolved .target info_notnull origin, else zero
entity camera_list_head;
float  camera_count;
float  cam_synth_done;    // one-shot guard for Camera_SynthesizeFromSpawns
float  cam_synth_active;  // 1 if synth spawned at least one camera (gates the
                          // cross-phase last-resort fallback so authored maps
                          // never have their team-pick view land on a player-
                          // preview camera the mapper hid inside a wall).

// Per-phase random-cycle state.  Replaces the old sequential
// `floor(time / CAMERA_CYCLE_SECONDS) % count` march with a fresh
// random pick every cycle boundary, and suppresses immediate repeats
// when count > 1 so the same camera never shows twice in a row.
//
// FTEQCC folds `float x = -1;` at file scope into a const, so the
// -1 sentinel (needed so the first call actually picks at cycle 0)
// is assigned lazily on first use via camera_cycle_initialized.
float camera_cycle_initialized;
float camera_cycle_num_p0; float camera_cycle_idx_p0;
float camera_cycle_num_p1; float camera_cycle_idx_p1;
float camera_cycle_num_p2; float camera_cycle_idx_p2;
float camera_cycle_num_p3; float camera_cycle_idx_p3;
float camera_cycle_num_p4; float camera_cycle_idx_p4;

float(float phase, float count) Camera_RandomIdxForPhase =
{
    if (!camera_cycle_initialized)
    {
        camera_cycle_initialized = 1;
        camera_cycle_num_p0 = -1;
        camera_cycle_num_p1 = -1;
        camera_cycle_num_p2 = -1;
        camera_cycle_num_p3 = -1;
        camera_cycle_num_p4 = -1;
    }

    float cycle_num = floor(time / CAMERA_CYCLE_SECONDS);
    float last_num, last_idx;

    if      (phase == CAM_PHASE_TEAM_BLUE)   { last_num = camera_cycle_num_p1; last_idx = camera_cycle_idx_p1; }
    else if (phase == CAM_PHASE_TEAM_RED)    { last_num = camera_cycle_num_p2; last_idx = camera_cycle_idx_p2; }
    else if (phase == CAM_PHASE_BLUE_PLAYER) { last_num = camera_cycle_num_p3; last_idx = camera_cycle_idx_p3; }
    else if (phase == CAM_PHASE_RED_PLAYER)  { last_num = camera_cycle_num_p4; last_idx = camera_cycle_idx_p4; }
    else                                     { last_num = camera_cycle_num_p0; last_idx = camera_cycle_idx_p0; }

    if (cycle_num != last_num)
    {
        float new_idx = floor(random() * count);
        if (new_idx < 0)        new_idx = 0;
        if (new_idx >= count)   new_idx = count - 1;
        // Avoid showing the same camera twice in a row.
        if (count > 1 && new_idx == last_idx)
            new_idx = (new_idx + 1) - floor((new_idx + 1) / count) * count;

        last_idx = new_idx;
        last_num = cycle_num;

        if      (phase == CAM_PHASE_TEAM_BLUE)   { camera_cycle_num_p1 = last_num; camera_cycle_idx_p1 = last_idx; }
        else if (phase == CAM_PHASE_TEAM_RED)    { camera_cycle_num_p2 = last_num; camera_cycle_idx_p2 = last_idx; }
        else if (phase == CAM_PHASE_BLUE_PLAYER) { camera_cycle_num_p3 = last_num; camera_cycle_idx_p3 = last_idx; }
        else if (phase == CAM_PHASE_RED_PLAYER)  { camera_cycle_num_p4 = last_num; camera_cycle_idx_p4 = last_idx; }
        else                                     { camera_cycle_num_p0 = last_num; camera_cycle_idx_p0 = last_idx; }
    }

    return last_idx;
};

void(entity cam) Camera_ResolveTarget =
{
    cam.cam_resolved = 1;  // mark attempted so we don't retry every frame
    if (!cam.target || cam.target == "")
        return;
    entity tgt = find(world, targetname, cam.target);
    if (!tgt)
    {
        // Missing target is expected on the first few resolve attempts
        // — info_notnulls may spawn after this camera in entity order.
        // Camera_EnsureTargetsResolved keeps retrying each StartFrame;
        // only warn if the retry is still failing after the grace period,
        // which means the target genuinely doesn't exist in the map.
        if (cvar("sv_debug_camera"))
            dprint(sprintf("[camera] target '%s' not found (may retry)\n", cam.target));
        return;
    }
    // vectoangles returns angles directly compatible with the player
    // .v_angle convention (positive pitch = looking down), so no flip.
    vector dir = normalize(tgt.origin - cam.origin);
    vector ang = vectoangles(dir);
    ang_z = 0;
    cam.angles = ang;
    cam.cam_target_origin = tgt.origin;  // for CSQC preview model placement
    cam.SendFlags |= 1;                   // re-send to clients if networked
    if (cvar("sv_debug_camera"))
        bprint(PRINT_HIGH, sprintf("[camera] aimed at '%s' (%s @ %v) angles=%v flag=%g\n",
                                   cam.target, tgt.classname, tgt.origin, cam.angles, cam.spawnflags));
};

// Does this camera match the given phase?
// Phase 0 (neutral) = cameras with NO team flags set.
// Phase 1/2/3/4 = cameras with the corresponding flag set.
float(entity c, float p) Camera_MatchesPhase =
{
    float required;
    if      (p == CAM_PHASE_TEAM_BLUE)   required = CAM_FLAG_TEAM_BLUE;
    else if (p == CAM_PHASE_TEAM_RED)    required = CAM_FLAG_TEAM_RED;
    else if (p == CAM_PHASE_BLUE_PLAYER) required = CAM_FLAG_TEAM_BLUE_PLAYER;
    else if (p == CAM_PHASE_RED_PLAYER)  required = CAM_FLAG_TEAM_RED_PLAYER;
    else                                 required = 0;

    if (required == 0)
    {
        // Neutral phase: accept only cameras with zero team flags.
        float any_flag = CAM_FLAG_TEAM_BLUE | CAM_FLAG_TEAM_RED
                       | CAM_FLAG_TEAM_BLUE_PLAYER | CAM_FLAG_TEAM_RED_PLAYER;
        return (c.spawnflags & any_flag) == 0;
    }
    return (c.spawnflags & required) != 0;
};

float(float p) Camera_CountForPhase =
{
    float n = 0;
    entity c = camera_list_head;
    while (c)
    {
        if (Camera_MatchesPhase(c, p)) n = n + 1;
        c = c.camera_next;
    }
    return n;
};

// Pick the nth matching camera for a phase (cycling by time).  Falls back
// to neutral cameras if no camera matches the requested phase.  As a last
// resort, returns ANY camera regardless of team flags — covers the case
// where the map has only synthesised team-flagged cameras (see
// Camera_SynthesizeFromSpawns) and the requesting player is in the
// neutral phase, which would otherwise return world.  Returns world only
// when there are NO cameras at all (caller skips placement instead of
// teleporting to 0,0,0).
//
// Implementation note: uses a local `effective_phase` instead of mutating
// the parameter, because some QC call conventions can stub parameter
// reassignment out.
entity(float req_phase) Camera_GetCurrentForPhase =
{
    float effective_phase = req_phase;
    float count = Camera_CountForPhase(effective_phase);
    if (count == 0 && effective_phase != CAM_PHASE_NEUTRAL)
    {
        effective_phase = CAM_PHASE_NEUTRAL;
        count = Camera_CountForPhase(effective_phase);
    }
    if (count == 0)
    {
        // Last-resort fallback: any camera, regardless of team flags.
        // Gated on cam_synth_active so this ONLY applies to maps that
        // got synth cameras (where every camera origin is pointcontents-
        // validated and safe to land on).  On AUTHORED maps the mapper
        // is the authority on which cameras serve which phase — falling
        // back across phases there could place the player at a hidden
        // BLUE_PLAYER / RED_PLAYER camera the mapper deliberately
        // tucked inside a wall ("viewing pocket" trick), giving a
        // full-screen void overlay when their view lands inside solid.
        // For authored maps with partial flag coverage, return world
        // and let the caller skip placement (player keeps last position).
        if (!cam_synth_active) return world;
        if (!camera_list_head) return world;

        float any_idx;
        if (camera_count <= 1) any_idx = 0;
        else                   any_idx = Camera_RandomIdxForPhase(req_phase, camera_count);
        entity any_c = camera_list_head;
        float any_i = 0;
        while (any_c)
        {
            if (any_i == any_idx) return any_c;
            any_i = any_i + 1;
            any_c = any_c.camera_next;
        }
        return camera_list_head;
    }

    float idx;
    if (count <= 1) idx = 0;
    else            idx = Camera_RandomIdxForPhase(effective_phase, count);

    entity c = camera_list_head;
    float i = 0;
    while (c)
    {
        if (Camera_MatchesPhase(c, effective_phase))
        {
            if (i == idx) return c;
            i = i + 1;
        }
        c = c.camera_next;
    }
    return world;
};

// Snap a player's view to the current cycle camera for their phase.  Also
// zeroes velocity and re-locks fixangle so the player can't drift or rotate
// the view.  A small time-based sway is added on top of the camera angles
// so the scene doesn't feel frozen.
// Returns 1 if a camera was applied, 0 if no suitable camera was found (in
// which case the player is left where they were — never teleport to 0,0,0).
float(entity p) Camera_PlacePlayerAtCurrent =
{
    entity cam = Camera_GetCurrentForPhase(p.cam_phase);
    // Belt-and-braces: reject world and anything that isn't actually a
    // camera entity (protects against recycled-entity aliasing).
    if (cam == world || cam.classname != "camera")
        return 0;

    // Lazy target resolution — handles the case where info_notnull spawned
    // after us in entity order, or where a later change added/changed targets.
    if (!cam.cam_resolved)
        Camera_ResolveTarget(cam);

    // vectoangles returns entity-pitch convention (+pitch = up), but
    // self.v_angle uses view-pitch convention (+pitch = down).  Flip X
    // before assigning to v_angle so a camera aimed at a target BELOW it
    // actually makes the player look DOWN in-view, not up.
    //
    // Sway used to be added here — moved to client-side so high-ping
    // players get smooth motion (see client/cl_cameras.qc
    // CSQC_TeamSelectSwayAngles).
    vector applied = cam.angles;
    applied_x = -applied_x;

    entity saved = self;
    self = p;
    setorigin(self, cam.origin);
    self.angles   = applied;
    self.v_angle  = applied;
    self.fixangle = TRUE;
    self.velocity = '0 0 0';
    // Force-sync the prediction proxy — PlayerPreThink returns early for
    // team-selecting players and wouldn't otherwise push the updated origin
    // to the client.  Without this, the CSQC-side viewpoint stays frozen
    // at whatever proxy origin existed when the player first connected.
    PM_SyncPredictionProxy(self);
    self = saved;

    // Debug — sv_debug_camera 1 prints once per player on first placement
    // (i.e. right after joining the map); 2 prints at 1 Hz continuously.
    // Shows the full selection state so bugs like "player stuck at 0,0,0"
    // can be traced to either the camera side (cam.origin wrong) or the
    // player side (player.origin overwritten after setorigin).
    float cam_dbg = cvar("sv_debug_camera");
    if (cam_dbg)
    {
        float show;
        if (cam_dbg >= 2)
            show = (time - p.cam_last_dbg_time > 1.0);
        else
            show = (p.cam_last_dbg_time == 0);

        if (show)
        {
            p.cam_last_dbg_time = time;
            bprint(PRINT_HIGH, sprintf("[camdbg] p=%g match=%g cam.origin=%v cam.angles=%v player.origin=%v\n",
                                       p.cam_phase,
                                       Camera_CountForPhase(p.cam_phase),
                                       cam.origin, cam.angles, p.origin));
        }
    }
    return 1;
};

// Called every server tick from StartFrame. Re-places every team-selecting
// player at the current cycle camera every frame — this is both the cycle
// rotation mechanism AND the anti-drift lock (pmove runs per tick and will
// apply small gravity/friction even with movetype set, so without this the
// player slowly slides down).
void() Camera_UpdateCyclingSpectators =
{
    if (!camera_list_head) return;

    entity p = player_chain_head;
    while (p)
    {
        if (p.player_team <= TEAM_NONE)
            Camera_PlacePlayerAtCurrent(p);
        p = p.player_chain_next;
    }
};

// Forward decl — defined further down.  Synthesised cameras need to
// wire SendEntity at spawn (just like authored preview cameras do).
float(entity playerent, float changedflags) camera_SendEntity;

// Reset all camera-system state.  Called from worldspawn so each map
// load starts clean — without this, FTE's QC progs keep file-scope
// globals across map changes, so the previous map's cam_synth_done
// flag and camera_list_head pointer leak into the new map.  The
// existing code "happened to work" because entity reuse zeroes
// fields (the stale list-head's .camera_next becomes world when
// the slot is reclaimed by another entity), but synth bails on
// `if (camera_list_head)` so a stale non-zero head silently
// suppresses synthesis on every map after the first.
// TRUE once Camera_EnsureTargetsResolved has walked the chain and found
// nothing left to do (synth ran, every preview camera is either resolved
// or has fired its grace-period warning).  Lets the per-tick StartFrame
// call early-out instead of iterating the camera list every frame for
// the entire match.  Cleared by any mutation that adds a new camera.
float cam_targets_stable;

void() Camera_ResetState =
{
    camera_list_head         = world;
    camera_count             = 0;
    cam_synth_done           = 0;
    cam_synth_active         = 0;
    camera_cycle_initialized = 0;
    cam_targets_stable       = 0;
};

// =============================================================
//  Synthesised cameras — fallback for maps with no `camera` ents
// =============================================================
//
// CS-style maps (no authored team-select cameras) get one runtime
// camera per spawn point so the team-pick UI + character-preview
// viewport have something to render.  Each synth camera carries
// both the team-pick AND the player-preview flag, so the existing
// 7-second cycling code drives both UIs from the same set.
//
// Real authored cameras override entirely — synthesis bails on
// the first `if (camera_list_head)` if anything is already in the
// list when this fires.

// Side preview camera (for the player-pick model viewport).  Tiered
// radii — the algorithm tries the largest first and falls back to
// shorter distances if the candidate position is in solid or the LOS
// to the spawn is blocked.  Strict full-LOS required (fraction == 1)
// since the menu's preview viewport renders FROM the camera, so being
// "behind a wall" gives the player a water-overlay-like full-screen
// solid colour.
const float CAM_SYNTH_BACK_125 = 125;
const float CAM_SYNTH_BACK_96  = 96;
const float CAM_SYNTH_BACK_64  = 64;
const float CAM_SYNTH_BACK_48  = 48;
const float CAM_SYNTH_UP       = 36;   // half player height above spawn

// Overhead team-pick camera (used when the player is choosing BLUE/RED).
// Camera is offset BOTH horizontally and vertically from the spawn so
// the resulting look angle is ~45° downward — not straight down.
// Reasoning: a straight-down camera produces pitch ±90 from
// vectoangles, which is the singularity in the view-pitch convention.
// Engine clamping at ±89 oscillates between adjacent values and
// causes a per-frame up/down flicker.  Equal H/V offset (45° look)
// keeps the pitch well inside the clamp range.
//
// Tiered fallback — descends through three offset sizes if the larger
// candidate is in solid or has its LOS to the spawn blocked.
const float CAM_SYNTH_OVER_FAR  = 150;
const float CAM_SYNTH_OVER_MED  = 100;
const float CAM_SYNTH_OVER_NEAR = 64;

// Map a spawn classname to the camera flags that team would use.
// Returns 0 for unknown classes (callers skip those spawns).  CS
// fallbacks (info_player_start / info_player_deathmatch) inherit
// the same BLUE/RED side mapping as PlayerGetSpawnPointEntity.
float(string cls) Camera_SynthFlagsForSpawnClass =
{
    if (cls == "info_player_blue"
     || cls == "info_player_start_blue"
     || cls == "info_player_team1"
     || cls == "info_player_start")
        return CAM_FLAG_TEAM_BLUE | CAM_FLAG_TEAM_BLUE_PLAYER;

    if (cls == "info_player_red"
     || cls == "info_player_start_red"
     || cls == "info_player_team2"
     || cls == "info_player_deathmatch")
        return CAM_FLAG_TEAM_RED | CAM_FLAG_TEAM_RED_PLAYER;

    return 0;
};

// Pick a side-preview camera placement around the spawn.  Tries 8
// angles at 45° intervals; for each angle, descends through 4 radii
// (125, 96, 64, 48) and uses the first that's both in empty space
// (`pointcontents == CONTENT_EMPTY`) AND has full LOS to the model
// torso (trace_fraction == 1).  Across all angles, picks the one
// whose best valid radius is largest — gives the longest possible
// camera distance while guaranteeing the camera isn't inside a wall
// and can actually see the model.  Returns radius (0 = no valid).
float pp_synth_side_radius;
float pp_synth_side_idx;
float(entity sp, vector look_at) Camera_SynthPickSidePlacement =
{
    pp_synth_side_radius = 0;
    pp_synth_side_idx    = 0;

    float i;
    for (i = 0; i < 8; i++)
    {
        float rad = i * 45 * (3.14159265 / 180);
        vector dir = '0 0 0';
        dir_x = cos(rad);
        dir_y = sin(rad);

        float r;
        for (r = 0; r < 4; r++)
        {
            float radius;
            if      (r == 0) radius = CAM_SYNTH_BACK_125;
            else if (r == 1) radius = CAM_SYNTH_BACK_96;
            else if (r == 2) radius = CAM_SYNTH_BACK_64;
            else             radius = CAM_SYNTH_BACK_48;

            vector cand = sp.origin + dir * radius
                                    + '0 0 1' * CAM_SYNTH_UP;

            if (pointcontents(cand) != CONTENT_EMPTY)
                continue;
            traceline(cand, look_at, MOVE_NORMAL, world);
            if (trace_fraction < 1.0)
                continue;

            // Valid placement at this radius.  Score by radius — keep
            // the angle whose best valid radius is largest globally.
            if (radius > pp_synth_side_radius)
            {
                pp_synth_side_radius = radius;
                pp_synth_side_idx    = i;
            }
            break;   // try next angle
        }
    }

    return pp_synth_side_radius;
};

// Pick an overhead team-pick camera placement.  Same 8-angle / tiered-
// radius search as the side-preview placement, but the candidate is
// offset BOTH horizontally AND vertically by the same amount — so the
// final look angle to the spawn is a clean 45° down, avoiding the
// pitch ±90 singularity that causes the per-frame up/down flicker.
//
// Returns offset distance on success (0 = no valid).
float pp_synth_over_dist;
float pp_synth_over_idx;
float(entity sp, vector look_at) Camera_SynthPickOverheadPlacement =
{
    pp_synth_over_dist = 0;
    pp_synth_over_idx  = 0;

    float i;
    for (i = 0; i < 8; i++)
    {
        float rad = i * 45 * (3.14159265 / 180);
        vector dir = '0 0 0';
        dir_x = cos(rad);
        dir_y = sin(rad);

        float r;
        for (r = 0; r < 3; r++)
        {
            float dist;
            if      (r == 0) dist = CAM_SYNTH_OVER_FAR;
            else if (r == 1) dist = CAM_SYNTH_OVER_MED;
            else             dist = CAM_SYNTH_OVER_NEAR;

            // Equal H / V offset → 45° pitch when looking back at the
            // spawn.  Far clear of the ±90 singularity.
            vector cand = sp.origin + dir * dist + '0 0 1' * dist;

            if (pointcontents(cand) != CONTENT_EMPTY)
                continue;
            traceline(cand, look_at, MOVE_NORMAL, world);
            if (trace_fraction < 1.0)
                continue;

            if (dist > pp_synth_over_dist)
            {
                pp_synth_over_dist = dist;
                pp_synth_over_idx  = i;
            }
            break;   // try next angle
        }
    }

    return pp_synth_over_dist;
};

// Spawn one side-preview camera + (optionally) one overhead team-pick
// camera per spawn point.  The two carry disjoint flag sets so the
// player-pick phase only sees side cameras and the team-pick phase
// only sees overhead cameras.  When the overhead can't fit (low
// ceiling), the side camera adopts the team-pick flag so the
// team-pick phase still has SOMETHING to cycle through.
void(entity sp) Camera_SynthOneFromSpawn =
{
    float combined = Camera_SynthFlagsForSpawnClass(sp.classname);
    if (!combined) return;

    float team_flag   = combined & (CAM_FLAG_TEAM_BLUE | CAM_FLAG_TEAM_RED);
    float player_flag = combined & (CAM_FLAG_TEAM_BLUE_PLAYER | CAM_FLAG_TEAM_RED_PLAYER);

    vector look_at = sp.origin + '0 0 32';

    float side_radius = Camera_SynthPickSidePlacement(sp, look_at);
    if (side_radius <= 0)
    {
        if (cvar("developer"))
            dprint(sprintf("^3[cam-synth]^7 ^1skip^7 ^6%s^7 at %v — no valid side placement\n",
                           sp.classname, sp.origin));
        return;
    }

    float deg = pp_synth_side_idx * 45;
    float rad2 = deg * (3.14159265 / 180);
    vector dir2 = '0 0 0';
    dir2_x = cos(rad2);
    dir2_y = sin(rad2);
    vector side_origin = sp.origin + dir2 * side_radius
                                   + '0 0 1' * CAM_SYNTH_UP;
    vector side_angles = vectoangles(look_at - side_origin);
    side_angles_z = 0;

    // Try to place an overhead camera for the team-pick phase.  If
    // it fits, side camera carries ONLY the player_flag; otherwise
    // it adopts the team_flag too so team-pick still has coverage.
    float overhead_dist = Camera_SynthPickOverheadPlacement(sp, look_at);
    float side_flags = player_flag;
    if (overhead_dist <= 0)
        side_flags = side_flags | team_flag;   // fallback: side covers both

    // ---- Side preview camera ----
    entity side_cam = spawn();
    side_cam.classname  = "camera";
    side_cam.spawnflags = side_flags;
    setorigin(side_cam, side_origin);
    side_cam.angles     = side_angles;
    side_cam.solid      = SOLID_NOT;
    side_cam.movetype   = MOVETYPE_NONE;
    side_cam.modelindex = 0;
    // Model placement target — menu's DrawCharacterPreview reads this
    // and renders the player model at cam_target_origin + (0, 0, 32).
    side_cam.cam_target_origin = sp.origin;
    side_cam.cam_resolved      = 1;   // synth; no .target lookup needed

    side_cam.camera_next = camera_list_head;
    camera_list_head     = side_cam;
    camera_count         = camera_count + 1;
    cam_targets_stable   = 0;

    // Side cameras carry the *_PLAYER flag → CSQC replication wired
    // (menu's preview viewport reads cam.origin / cam_target_origin).
    side_cam.pvsflags   = PVSF_IGNOREPVS;
    side_cam.SendEntity = camera_SendEntity;
    side_cam.SendFlags  = 1;

    if (cvar("developer"))
        dprint(sprintf("^3[cam-synth]^7 side ^6%s^7 yaw=%g radius=%g\n",
                       sp.classname, deg, side_radius));

    // ---- Overhead team-pick camera ----
    if (overhead_dist <= 0)
    {
        if (cvar("developer"))
            dprint(sprintf("^3[cam-synth]^7 overhead ^1skip^7 ^6%s^7 — no clearance\n",
                           sp.classname));
        return;
    }

    float over_deg = pp_synth_over_idx * 45;
    float over_rad = over_deg * (3.14159265 / 180);
    vector over_dir = '0 0 0';
    over_dir_x = cos(over_rad);
    over_dir_y = sin(over_rad);
    vector overhead_origin = sp.origin + over_dir * overhead_dist
                                       + '0 0 1' * overhead_dist;
    vector overhead_angles = vectoangles(sp.origin - overhead_origin);
    overhead_angles_z = 0;

    entity over_cam = spawn();
    over_cam.classname  = "camera";
    over_cam.spawnflags = team_flag;   // team-pick only, no _PLAYER
    setorigin(over_cam, overhead_origin);
    over_cam.angles     = overhead_angles;
    over_cam.solid      = SOLID_NOT;
    over_cam.movetype   = MOVETYPE_NONE;
    over_cam.modelindex = 0;
    over_cam.cam_resolved = 1;

    over_cam.camera_next = camera_list_head;
    camera_list_head     = over_cam;
    camera_count         = camera_count + 1;
    cam_targets_stable   = 0;

    // Team-pick cameras stay server-side — the player view is moved to
    // cam.origin via Camera_PlacePlayerAtCurrent, no menu replication
    // needed.  Skip SendEntity wiring.

    if (cvar("developer"))
        dprint(sprintf("^3[cam-synth]^7 overhead ^6%s^7 yaw=%g dist=%g\n",
                       sp.classname, over_deg, overhead_dist));
};

void(string cls) Camera_SynthChainByClass =
{
    entity sp = find(world, classname, cls);
    while (sp)
    {
        Camera_SynthOneFromSpawn(sp);
        sp = find(sp, classname, cls);
    }
};

void() Camera_SynthesizeFromSpawns =
{
    if (cam_synth_done) return;
    cam_synth_done = 1;

    // Real authored cameras win — no synthesis when the map already
    // has cameras (even partial coverage).  Mapper intent respected.
    if (camera_list_head)
        return;

    Camera_SynthChainByClass("info_player_blue");
    Camera_SynthChainByClass("info_player_start_blue");
    Camera_SynthChainByClass("info_player_team1");
    Camera_SynthChainByClass("info_player_red");
    Camera_SynthChainByClass("info_player_start_red");
    Camera_SynthChainByClass("info_player_team2");
    Camera_SynthChainByClass("info_player_start");
    Camera_SynthChainByClass("info_player_deathmatch");

    // Mark synth-active so the cross-phase last-resort fallback in
    // Camera_GetCurrentForPhase only applies to this map.  Authored
    // maps (which bailed at the early return above) leave this 0.
    if (camera_count > 0)
        cam_synth_active = 1;

    if (cvar("developer") && camera_count > 0)
        dprint(sprintf("^3[cam-synth]^7 created ^6%g^7 synth cameras (no map cameras found)\n",
                       camera_count));
};

// Called every StartFrame.  For neutral cameras the lazy per-use resolve in
// Camera_PlacePlayerAtCurrent is enough, but preview-flagged cameras are
// networked to CSQC and need their .target resolved BEFORE the first
// SendEntity — otherwise the client receives cam_target_origin = 0,0,0 and
// the preview viewport renders from void.  MOVETYPE_NONE entities don't
// always get their .think called in QW protocol, so we can't rely on the
// deferred-think retry in camera().  Keep retrying preview cameras here
// each tick until cam_target_origin is non-zero (success).
void() Camera_EnsureTargetsResolved =
{
    // Early-out once everything has settled (synth done, every preview
    // camera either resolved or warned).  Cleared by any mutation that
    // adds a new camera (synth helpers + map `camera` spawnfunc).
    if (cam_targets_stable)
        return;

    // First-tick synthesis — runs once per map.  By the time StartFrame
    // first fires, every map entity (including spawn points) has been
    // parsed, so find() reliably reaches every candidate.
    Camera_SynthesizeFromSpawns();

    // Grace period: info_notnulls may take a few ticks to spawn relative
    // to cameras. After this many seconds of uptime, if a camera's target
    // is STILL unresolved, it really doesn't exist in the map — warn once
    // so the mapper sees the typo (without needing sv_debug_camera).
    const float GRACE_SEC = 2.0;
    float map_uptime = time - map_start_time;

    float preview_flag = CAM_FLAG_TEAM_BLUE_PLAYER | CAM_FLAG_TEAM_RED_PLAYER;
    float still_pending = 0;
    entity c = camera_list_head;
    while (c)
    {
        if ((c.spawnflags & preview_flag) && c.target && c.target != ""
            && !c.cam_target_origin_x && !c.cam_target_origin_y && !c.cam_target_origin_z)
        {
            c.cam_resolved = 0;          // force Camera_ResolveTarget to try
            Camera_ResolveTarget(c);
            // On success, push a SendEntity refresh so CSQC gets the
            // updated angles/cam_target_origin.
            if (c.cam_target_origin_x || c.cam_target_origin_y || c.cam_target_origin_z)
                c.SendFlags |= 1;
            // Still unresolved after grace period → genuine map error,
            // print once so the mapper sees it without needing debug.
            else if (map_uptime > GRACE_SEC && !c.cam_target_warned)
            {
                c.cam_target_warned = 1;
                bprint(PRINT_HIGH, sprintf("^1[camera]^7 target '%s' not found in map. Use info_notnull (info_null is stripped by most BSP compilers).\n",
                                           c.target));
            }
            // Within grace period and still unresolved — try again next
            // tick, don't latch stable yet.
            else if (!c.cam_target_warned)
                still_pending = 1;
        }
        c = c.camera_next;
    }

    if (!still_pending)
        cam_targets_stable = 1;
};

// Self-target resolver — used as a .think so preview cameras can defer
// their target lookup to a frame after initial spawn (info_notnull may
// spawn after us in entity order).
void() Camera_ResolveTarget_Self =
{
    Camera_ResolveTarget(self);
};

// ---------------------------------------------------------------------------
//  CSQC replication — only Team_Blue_Player / Team_Red_Player cameras are
//  sent to clients.  The menu's DrawCharacterPreview uses them to drive the
//  small spinning-model viewport on the character-select screen.  All other
//  cameras stay server-side (used for the full-screen world view only).
// ---------------------------------------------------------------------------
float(entity playerent, float changedflags) camera_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_CAMERA);

    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);

    WriteCoord(MSG_ENTITY, self.angles_x);
    WriteCoord(MSG_ENTITY, self.angles_y);
    WriteCoord(MSG_ENTITY, self.angles_z);

    WriteCoord(MSG_ENTITY, self.cam_target_origin_x);
    WriteCoord(MSG_ENTITY, self.cam_target_origin_y);
    WriteCoord(MSG_ENTITY, self.cam_target_origin_z);

    WriteByte(MSG_ENTITY, self.spawnflags);

    return TRUE;
};

// Map entity spawn function: "camera"
void() camera =
{
    self.classname = "camera";
    self.solid = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.modelindex = 0;

    self.camera_next = camera_list_head;
    camera_list_head = self;
    camera_count = camera_count + 1;
    cam_targets_stable = 0;

    // Network preview-flagged cameras to CSQC for the menu's character
    // preview viewport.  Non-preview cameras stay server-only.
    float preview_flag = CAM_FLAG_TEAM_BLUE_PLAYER | CAM_FLAG_TEAM_RED_PLAYER;
    if (self.spawnflags & preview_flag)
    {
        // Try to resolve now — works if info_notnull spawned before us.
        Camera_ResolveTarget(self);
        // If the lookup failed (target not yet spawned), retry once next
        // tick.  Camera_ResolveTarget_Self clears cam_resolved first so the
        // retry actually runs.
        if (!self.cam_target_origin_x && !self.cam_target_origin_y && !self.cam_target_origin_z
            && self.target && self.target != "")
        {
            self.cam_resolved = 0;
            self.think = Camera_ResolveTarget_Self;
            self.nextthink = time + 0.05;
        }

        // PVSF_IGNOREPVS (not NOREMOVE) — NOREMOVE only takes effect once the
        // entity has already been visible to a client, which fails for preview
        // cameras placed outside the player-spawn PVS cluster (skybox pockets,
        // detail rooms, etc.).  IGNOREPVS tells the engine to send the entity
        // unconditionally regardless of PVS/PHS.
        self.pvsflags   = PVSF_IGNOREPVS;
        self.SendEntity = camera_SendEntity;
        self.SendFlags  = 1;
    }
};

// info_notnull — positional marker target for cameras.  Use this instead
// of info_null, which many BSP compilers strip at compile time.
void() info_notnull =
{
    // Persist as a do-nothing entity — only .origin and .targetname matter.
};
