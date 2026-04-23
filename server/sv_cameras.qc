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
.vector cam_target_origin;  // resolved .target info_notnull origin, else zero
entity camera_list_head;
float  camera_count;

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
        // Log with developer dprint AND a one-shot bprint so the mapper
        // sees the failure without needing developer 1.
        bprint(PRINT_HIGH, sprintf("^1[camera]^7 target '%s' not found. Use info_notnull (info_null is stripped by most BSP compilers).\n",
                                   cam.target));
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
// to neutral cameras if no camera matches the requested phase.  Returns
// world if NOTHING matches (caller should skip placement instead of
// teleporting the player to 0,0,0).
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
        return world;  // no placement — caller handles

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
    float preview_flag = CAM_FLAG_TEAM_BLUE_PLAYER | CAM_FLAG_TEAM_RED_PLAYER;
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
        }
        c = c.camera_next;
    }
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
