// Forward decl — implemented in cl_viewfx.qc, which compiles AFTER
// this file in cl_progs.src.  Used by CSQC_ViewmodelAttachmentWorldPos
// to align the bone lookup with the rendered viewmodel pose.
void(vector view_pos, vector view_ang) CSQC_ViewFX_PoseViewmodelForBoneLookup;

// ============================================================
//  client/cl_muzzleflash.qc  -  Client-predicted muzzle flash
//
//  Spawns a brief dynamic light at the camera position when
//  a weapon fires. Called from CSQC prediction code so it
//  appears instantly regardless of ping.
//
//  Other players see the flash via the server's standard
//  EF_MUZZLEFLASH on the player entity.
//
//  Two systems share this file:
//    1. CSQC_MuzzleFlash / CSQC_DrawMuzzleFlash — the legacy
//       dynamic-light burst (gated on cl_muzzleflash_light).
//    2. CSQC_SpawnMuzzleFlashSprite / CSQC_DrawMuzzleFlashSprite
//       — a single-frame additive sprite billboard at the gun
//       muzzle (gated on cl_muzzleflash_sprite). Picks one of
//       four variants (gfx/muzzleflash1..4) per shot and
//       animates it: starts small and opaque, GROWS while it
//       FADES to zero alpha over its lifetime — gives a soft
//       "puff" feel without a second hand-authored frame.
// ============================================================

float csqc_muzzleflash_time;       // cltime when the last flash started
float csqc_muzzleflash_duration;   // how long the flash lasts

const float MUZZLE_FLASH_RADIUS   = 300;
const float MUZZLE_FLASH_DURATION = 0.1;

// --- Sprite muzzle flash state -------------------------------
//
// Action-ID keyed: each unique wep_action_id triggers exactly one
// spawn. Reconcile-replay sees the same action_id and is rejected
// at the ID-match guard, so reentrancy under high-ping replay
// can't double-fire the sequence.
//
// State: csqc_muzfx_active is 0 (idle) or 1 (animating). The
// animation runs from spawn_time → spawn_time + duration; size
// lerps small→large and alpha lerps full→zero across that window.
// Refire mid-animation restarts immediately with a new variant.
//
// `csqc_muzfx_offset` is the muzzle position in CAMERA-LOCAL
// space (x=forward, y=right, z=up). Stored at spawn time so the
// per-frame draw can recompute the world position from the
// CURRENT view origin/angles each frame — the sprite tracks the
// camera (you mouselook, the flash mouselooks with you for the
// duration it's on screen). Storing world coords would leave the
// flash hanging at the spawn-time position when the camera moves.
float  csqc_muzfx_action_id;
float  csqc_muzfx_active;
float  csqc_muzfx_start_time;
float  csqc_muzfx_variant;       // 1..4 — picks muzzleflash1..4 (static path)
float  csqc_muzfx_animated;      // 0 = static-variant, 1 = animated frame walk
vector csqc_muzfx_offset;        // (forward, right, up) in camera-local qu

// Animated muzzle flash (deagle test).  Frames live at
// gfx/muzzle/animated/animated_NN.png from FIRST..LAST inclusive.
// CSQC walks them at cl_muzzleflash_anim_fps (default below) so
// the framerate can be retuned live — total on-screen duration
// = FRAME_COUNT / fps and is computed in the draw fn.
const float MUZZLE_ANIM_FIRST_FRAME = 3;
const float MUZZLE_ANIM_LAST_FRAME  = 14;
const float MUZZLE_ANIM_FRAME_COUNT = 12;   // LAST - FIRST + 1
const float MUZZLE_ANIM_DEFAULT_FPS = 30;

// Tuning constants (mostly cvar-overridable).
//   _SIZE              base half-extent in qu — final is
//                      _SIZE * sprite_scale * (shrink - (shrink-1)*t)
//                      where t is normalised age 0..1.
//   _DEFAULT_DURATION  total seconds the flash is on screen.
//   _DEFAULT_SCALE     fallback for cl_muzzleflash_sprite_scale.
//   _DEFAULT_SHRINK    fallback for cl_muzzleflash_sprite_shrink —
//                      starting size multiplier at age=0; the sprite
//                      shrinks back to base size by age=1 (e.g. 2 =
//                      starts at 2x and contracts as it fades).
//   _DEFAULT_OPACITY   fallback for cl_muzzleflash_sprite_opacity —
//                      max alpha at age=0 (fades linearly to 0).
const float MUZZLE_SPRITE_SIZE             = 16;
const float MUZZLE_SPRITE_DEFAULT_DURATION = 0.06;
const float MUZZLE_SPRITE_DEFAULT_SCALE    = 0.4;
const float MUZZLE_SPRITE_DEFAULT_SHRINK   = 2.0;
const float MUZZLE_SPRITE_DEFAULT_OPACITY  = 1.0;

// Pre-load all muzzle-flash sprite shaders + their backing TGAs at
// CSQC init so the FIRST shot of any weapon doesn't render with a
// missing-texture pink/black checkerboard while the engine
// asynchronously parses the shader script and loads the file off
// disk. Uses shaderforname (#238) instead of precache_pic so the
// images don't get tagged UIPIC (which is what precache_pic does
// — caused the scorch + paintball texture-flag issues earlier in
// development; UIPIC textures get clamp + nomipmap which is wrong
// for 3D-rendered billboards).
void() CSQC_MuzzleFlash_Precache =
{
    shaderforname("gfx/muzzleflash1");
    shaderforname("gfx/muzzleflash2");
    shaderforname("gfx/muzzleflash3");
    shaderforname("gfx/muzzleflash4");

    // Deagle animated-flash frames. Same shaderforname() route as
    // the static set so the textures get tagged for 3D billboard
    // sampling (not UIPIC) and load synchronously before the first
    // shot — otherwise frame 1 renders pink/black checker.
    float fnum;
    for (fnum = MUZZLE_ANIM_FIRST_FRAME; fnum <= MUZZLE_ANIM_LAST_FRAME; fnum += 1)
        shaderforname(sprintf("gfx/muzzle/animated/animated_%02d", fnum));
};

// Called from weapon prediction when a shot fires.
// Triggers a dynamic light at the player's view position.
void() CSQC_MuzzleFlash =
{
    csqc_muzzleflash_time = cltime;
    csqc_muzzleflash_duration = MUZZLE_FLASH_DURATION;
    // Guarantee the peak (frac == 1.0) frame draws even when the
    // cl_dlight_update_hz throttle would have skipped this render.
    CSQC_DlightGate_ForceUpdate();
};

// Called every render frame from CSQC_UpdateView.
// Adds the dynamic light while the flash is active.
void() CSQC_DrawMuzzleFlash =
{
    float age;
    float frac;
    float radius;
    float scale;
    vector pos;

    if (!cvar("cl_muzzleflash_light"))
    {
        csqc_muzzleflash_time = 0;
        return;
    }

    if (csqc_muzzleflash_time <= 0)
        return;

    age = cltime - csqc_muzzleflash_time;
    if (age >= csqc_muzzleflash_duration)
    {
        csqc_muzzleflash_time = 0;
        return;
    }

    scale = bound(0, cvar("cl_muzzleflash_light_scale"), 2);
    if (scale <= 0)
    {
        csqc_muzzleflash_time = 0;
        return;
    }

    // Fade out over the duration
    frac = 1.0 - (age / csqc_muzzleflash_duration);
    radius = MUZZLE_FLASH_RADIUS * scale * frac;

    // Position at the camera (view origin)
    pos = getproperty(VF_ORIGIN);

    // Push forward and up from the camera to simulate muzzle position
    makevectors(getproperty(VF_ANGLES));
    pos = pos + v_forward * 8 + v_up * 4;

    // cl_dlight_update_hz throttle — see CSQC_DlightGate_Tick in
    // cl_main.qc.  Frame age/scale bookkeeping above always runs so
    // the timeline still advances; only the dynamiclight_add call is
    // skipped on non-update frames.
    if (csqc_dlight_update_this_frame)
        // PFLAGS_NOSHADOW: dlight is at camera origin so a shadow-casting
        // light here makes the viewmodel cast harsh shadows on itself.
        dynamiclight_add(pos, radius, '1 0.8 0.4' * frac, 0, "", PFLAGS_NOSHADOW);
};

// --- Sprite muzzle flash --------------------------------------
//
// Called from a weapon's CSQC fire-predict block. `local_offset` is
// the muzzle position in camera-local space (x=forward, y=right,
// z=up — same convention as v_forward / v_right / v_up). action_id
// is the firing player's wep_action_id for this shot — used to
// dedup against reconcile replays AND to seed the per-shot variant
// pick deterministically (so client and server agree which texture
// would appear if we ever networked this to remote viewers).
// Convenience wrapper for the common weapon-fire pattern: build the
// camera-local muzzle offset (with cl_lefthand mirroring) from per-
// weapon FORWARD/RIGHT/DOWN scalars and trigger the spawn. Reduces
// the call-site boilerplate at every weapon's fire-predict block to
// a single line. Forward decl below the spawn function so callers
// in weapon files can resolve it.
void(float fwd, float right_qu, float down, float action_id) CSQC_MuzzleFlashAtMuzzle;
void(float fwd, float right_qu, float down, float action_id) CSQC_MuzzleFlashAtMuzzleAnimated;

// Lazy-resolved weapons.muzzleflash handle (mirrors the tracer/smoke pattern).
float pe_weapons_muzzleflash;
float() MuzzleFlash_Resolve =
{
    if (pe_weapons_muzzleflash != 0)
        return pe_weapons_muzzleflash;
    pe_weapons_muzzleflash = particleeffectnum("weapons.muzzleflash");
    if (pe_weapons_muzzleflash != 0 && particleeffectquery(pe_weapons_muzzleflash, 0) == "")
        pe_weapons_muzzleflash = 0;   // not loaded YET — retry next call
    return pe_weapons_muzzleflash;
};

void(vector local_offset, float action_id) CSQC_SpawnMuzzleFlashSprite =
{
    // Default-on fallback so a fresh install / unregistered-cvar case
    // still works without the user having to type the command.
    float gate = cvar("cl_muzzleflash_sprite");
    if (gate == 0 && cvar_string("cl_muzzleflash_sprite") == "")
        gate = 1;
    if (gate == 0)
        return;

    // Single-frame flash → ONE engine particle (weapons.muzzleflash) at the muzzle
    // instead of a per-frame billboard quad.  (The ANIMATED variant still uses the
    // quad — a particle can't play a frame sequence.)  Falls back to the quad path
    // if the recipe isn't registered (stock engine / cfg not loaded yet).
    float fx = MuzzleFlash_Resolve();
    if (fx != 0)
    {
        // Dedup: one particle per shot (block reconcile replays of the same id).
        if (action_id == csqc_muzfx_action_id)
            return;
        csqc_muzfx_action_id = action_id;
        csqc_muzfx_active    = 0;   // particle path — the per-frame quad draw stays off

        vector view_pos = (vector)getproperty(VF_ORIGIN);
        makevectors((vector)getproperty(VF_ANGLES));
        vector muzzle = view_pos + v_forward * local_offset_x
                                 + v_right   * local_offset_y
                                 + v_up      * local_offset_z;
        pointparticles(fx, muzzle, '0 0 0', 1);
        return;
    }

    // --- Fallback: original per-frame billboard-quad path ---
    // Action-ID dedup against reconcile replays.  Refire (new id) restarts even if
    // the previous flash is mid-grow — the new shot picks a fresh variant.
    if (action_id == csqc_muzfx_action_id && csqc_muzfx_active != 0)
        return;
    csqc_muzfx_action_id  = action_id;
    csqc_muzfx_offset     = local_offset;
    csqc_muzfx_start_time = cltime;
    csqc_muzfx_active     = 1;
    csqc_muzfx_animated   = 0;
    csqc_muzfx_variant    = 1 + floor(SH_SpreadHash(action_id + 31.7) * 4);
    if (csqc_muzfx_variant > 4) csqc_muzfx_variant = 4;
};

// Animated-flash spawn — same dedup + state setup as the static
// path, but flags this firing for the animated-frame draw branch
// (gfx/muzzle/animated/animated_NN.png walked at
// cl_muzzleflash_anim_fps).  Used by the deagle as a test; other
// weapons keep the 4-variant static path until the animation is
// proven out.
void(vector local_offset, float action_id) CSQC_SpawnMuzzleFlashSpriteAnimated =
{
    float gate = cvar("cl_muzzleflash_sprite");
    if (gate == 0 && cvar_string("cl_muzzleflash_sprite") == "")
        gate = 1;
    if (gate == 0)
        return;
    if (action_id == csqc_muzfx_action_id && csqc_muzfx_active != 0)
        return;

    csqc_muzfx_action_id  = action_id;
    csqc_muzfx_offset     = local_offset;
    csqc_muzfx_start_time = cltime;
    csqc_muzfx_active     = 1;
    csqc_muzfx_animated   = 1;
};

// Last camera-local muzzle offset seen by the helper. Saved here so
// CSQC_DrawMuzzleDebug (cl_debug_muzzle 1) can render a marker at
// the world position every frame without each weapon needing its
// own per-frame setter. Updated whenever any weapon fires; persists
// until the next fire — so the user fires once with each weapon to
// "calibrate" the marker, then can live-tune the per-weapon
// _MUZZLE_FORWARD/RIGHT/DOWN constants and reload to see the move.
vector csqc_muzzle_debug_offset;
// Current weapon's muzzle attachment (stamped by CSQC_ViewmodelAttachmentWorldPos
// for AtWorld weapons; "" for AtMuzzle weapons → CSQC_MuzzleFlashWorldPos uses the
// cached offset instead).  Lets the tracer re-pose the muzzle fresh (ADS-correct).
string csqc_muzzle_attach_bone;
vector csqc_muzzle_attach_offset;

// Helper definition (forward-declared above). Per-weapon callers
// pass scalars; we build the camera-local vector and apply
// cl_lefthand mirroring on RIGHT once, in one place.
void(float fwd, float right_qu, float down, float action_id) CSQC_MuzzleFlashAtMuzzle =
{
    float side = cvar("cl_lefthand") ? -1 : 1;
    vector loc = [fwd, right_qu * side, 0 - down];
    csqc_muzzle_debug_offset = loc;   // save for CSQC_DrawMuzzleDebug
    csqc_muzzle_attach_bone = "";       // camera-offset path → no fresh re-pose
    CSQC_SpawnMuzzleFlashSprite(loc, action_id);
};

// Animated-flash twin of the helper above — identical offset math,
// just routes to the animated spawn.  Per-weapon callers swap to
// this when they want the animated frame walk instead of the
// 4-variant static sprite.
void(float fwd, float right_qu, float down, float action_id) CSQC_MuzzleFlashAtMuzzleAnimated =
{
    float side = cvar("cl_lefthand") ? -1 : 1;
    vector loc = [fwd, right_qu * side, 0 - down];
    csqc_muzzle_debug_offset = loc;
    csqc_muzzle_attach_bone = "";
    CSQC_SpawnMuzzleFlashSpriteAnimated(loc, action_id);
};

// Resolve the world position of the last-flashed muzzle.  Used by
// the tracer system so the ribbon's start lands at the gun barrel
// instead of the camera origin.  The cached `csqc_muzzle_debug_offset`
// is in CAMERA-LOCAL space (forward, right*lefthand, -down) — we
// transform it through the current view basis here.  Returns the
// camera origin if no muzzle flash has fired this session, which
// keeps the cl_tracers fallback path (camera-collinear detection)
// in charge of providing a usable start point.
vector(string bonename, vector bone_offset) CSQC_ViewmodelAttachmentWorldPos;   // fwd decl

vector() CSQC_MuzzleFlashWorldPos =
{
    // FRESH re-pose (current pose, ADS-aware).  The bone/offset are the current
    // weapon's (constant across shots), so re-posing last shot's values at THIS
    // frame's pose tracks ADS with no lag.  CSQC_ViewmodelAttachmentWorldPos falls
    // back to the eye on a bad/missing bone, which the tracer's near-camera hack
    // then turns into a usable muzzle.
    if (csqc_muzzle_attach_bone != "")
        return CSQC_ViewmodelAttachmentWorldPos(csqc_muzzle_attach_bone, csqc_muzzle_attach_offset);

    if (csqc_muzzle_debug_offset == '0 0 0')
        return (vector)getproperty(VF_ORIGIN);

    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    return view_pos
         + v_forward * csqc_muzzle_debug_offset_x
         + v_right   * csqc_muzzle_debug_offset_y
         + v_up      * csqc_muzzle_debug_offset_z;
};

// Look up an $attachment-style point on the active viewmodel and
// return its world position.  bonename is the parent bone of the HL
// $attachment (the .qc's second arg, e.g. "Bone 04"); bone_offset is
// the local-frame offset (the three float args).
//
// HL studio coordinates: +X forward, +Y left, +Z up.  Quake's
// gettaginfo returns axes with v_right = -left, so we negate the Y
// component when applying the offset.  If the muzzle ends up mirrored,
// flip Y's sign in the calling weapon.
//
// gettaginfo respects entity .origin/.angles; CSQC_AddPredictedViewmodel
// leaves them zero (the engine renders viewmodels via RF_VIEWMODEL),
// so we momentarily sync them to the camera before the lookup, then
// restore — RF_VIEWMODEL ignores .origin/.angles for rendering, but
// restoring keeps the entity in a predictable state for other code.
vector(string bonename, vector bone_offset) CSQC_ViewmodelAttachmentWorldPos =
{
    // Remember this weapon's muzzle attachment so CSQC_MuzzleFlashWorldPos can
    // re-pose it FRESH for the tracer (which spawns before the flash stamps it).
    csqc_muzzle_attach_bone   = bonename;
    csqc_muzzle_attach_offset = bone_offset;

    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);

    if (!csqc_viewmodel_ent || !csqc_viewmodel_ent.modelindex)
        return view_pos;

    vector saved_origin = csqc_viewmodel_ent.origin;
    vector saved_angles = csqc_viewmodel_ent.angles;
    // Save the full frame state — we'll override the entity to the
    // FIRST frame of the FIRING sequence so gettaginfo samples the bone
    // at the shot-start pose instead of the previous-tick idle pose.
    // Without this, the bone position lags by one render frame:
    // CSQC_PredictWeaponCommand fires (this code runs) BEFORE
    // CSQC_AddPredictedViewmodel re-stamps the entity, so the entity
    // still holds the LAST rendered (idle) frame from the prior tick.
    // Most visible on the elites because the dual-pistol idle holds
    // the muzzles wide while prefire snaps them inward — the flash
    // spawned visibly outside the firing barrel.
    float saved_frame      = csqc_viewmodel_ent.frame;
    float saved_frame1time = csqc_viewmodel_ent.frame1time;
    float saved_frame2     = csqc_viewmodel_ent.frame2;
    float saved_frame2time = csqc_viewmodel_ent.frame2time;

    // Compose the live cl_viewfx offsets (bob, sway pivot, weight,
    // sprint pose, ADS, etc.) into the entity's world transform so
    // gettaginfo below returns the bone at its VISIBLE position —
    // without this the muzzle flash and tracer spawn at the pose-less
    // baseline and visibly drift away from the rendered muzzle as
    // soon as any view-feel effect is active.  See cl_viewfx.qc.
    CSQC_ViewFX_PoseViewmodelForBoneLookup(view_pos, view_ang);

    // Snap the viewmodel to FRAME 0 of the firing animation.
    // self.csqc_display_frame(0) routes through the weapon's per-state
    // dispatcher and (when weaponstate == WS_FIRE) returns the chosen
    // shoot-sequence index, which is what SH_StandardTryFire just set.
    // For weapons that don't expose csqc_display_frame, fall through
    // to the entity's current frame — same behaviour as before.
    if (self.csqc_display_frame)
    {
        csqc_viewmodel_ent.frame         = self.csqc_display_frame(0);
        csqc_viewmodel_ent.frame1time    = 0;
        csqc_viewmodel_ent.frame2        = csqc_viewmodel_ent.frame;
        csqc_viewmodel_ent.frame2time    = 0;
    }

    float bidx = gettagindex(csqc_viewmodel_ent, bonename);
    if (bidx <= 0)
    {
        setorigin(csqc_viewmodel_ent, saved_origin);
        csqc_viewmodel_ent.angles       = saved_angles;
        csqc_viewmodel_ent.frame        = saved_frame;
        csqc_viewmodel_ent.frame1time   = saved_frame1time;
        csqc_viewmodel_ent.frame2       = saved_frame2;
        csqc_viewmodel_ent.frame2time   = saved_frame2time;
        return view_pos;
    }

    vector bone_world = gettaginfo(csqc_viewmodel_ent, bidx);
    // gettaginfo set v_forward/v_right/v_up to the bone's axes.
    vector attach_world = bone_world
                        + v_forward * bone_offset_x
                        + v_right   * (0 - bone_offset_y)
                        + v_up      * bone_offset_z;

    setorigin(csqc_viewmodel_ent, saved_origin);
    csqc_viewmodel_ent.angles       = saved_angles;
    csqc_viewmodel_ent.frame        = saved_frame;
    csqc_viewmodel_ent.frame1time   = saved_frame1time;
    csqc_viewmodel_ent.frame2       = saved_frame2;
    csqc_viewmodel_ent.frame2time   = saved_frame2time;

    // CSQC_AddPredictedViewmodel applies RF_XFLIP when
    // (weapon_viewmodel_flip XOR cl_lefthand) is true — the engine
    // mirrors the model across its local X axis at render time, but
    // gettaginfo above returned the un-mirrored bone.  Mirror the
    // result across the camera's right axis so the muzzle sits where
    // the player actually sees the barrel.
    float vm_flip = predicted_player.weapon_viewmodel_flip;
    if (cvar("cl_lefthand"))
        vm_flip = !vm_flip;
    if (vm_flip)
    {
        makevectors(view_ang);
        vector rel = attach_world - view_pos;
        float right_local = rel * v_right;
        attach_world = attach_world - v_right * (2 * right_local);
    }
    return attach_world;
};

// World-position muzzle flash entry — for weapons that source their
// muzzle from a model $attachment instead of hand-tuned camera-local
// constants.  Stashes the equivalent camera-local offset so the
// tracer system (CSQC_MuzzleFlashWorldPos) and cl_debug_muzzle marker
// keep working without changes.
void(vector world_pos, float action_id) CSQC_MuzzleFlashAtWorld =
{
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector rel = world_pos - view_pos;
    vector loc = [rel * v_forward, rel * v_right, rel * v_up];
    csqc_muzzle_debug_offset = loc;
    CSQC_SpawnMuzzleFlashSprite(loc, action_id);
};

// Same as CSQC_MuzzleFlashAtWorld but emits the 12-frame animated
// sprite path.  Used by weapons that source the muzzle from a bone
// (HDAK47) and want the deagle-style animation.
void(vector world_pos, float action_id) CSQC_MuzzleFlashAtWorldAnimated =
{
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector rel = world_pos - view_pos;
    vector loc = [rel * v_forward, rel * v_right, rel * v_up];
    csqc_muzzle_debug_offset = loc;
    CSQC_SpawnMuzzleFlashSpriteAnimated(loc, action_id);
};

// Forward decl from cl_debuginfo.qc — we draw the debug axes
// using the same beam helper hitbox debug uses.
void(vector p1, vector p2, vector col, float alpha) dbg_hitbox_line;

// Debug viz for tuning per-weapon muzzle offsets. When
// cl_debug_muzzle is on, draws a small RGB axis cross at the world
// position computed from the LAST-fired muzzle offset using the
// CURRENT view basis. Marker tracks the camera every frame so you
// can see the offset move as you tune cvars / reload progs.
//   X axis (red)    — view forward
//   Y axis (green)  — view right
//   Z axis (blue)   — view up
//   forward arrow (yellow) — extends along the barrel direction
void() CSQC_DrawMuzzleDebug =
{
    if (!cvar("cl_debug_muzzle"))
        return;
    if (csqc_muzzle_debug_offset == '0 0 0')
        return;   // nothing fired yet, nowhere to draw

    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector pos = view_pos
               + v_forward * csqc_muzzle_debug_offset_x
               + v_right   * csqc_muzzle_debug_offset_y
               + v_up      * csqc_muzzle_debug_offset_z;

    float L = 3;
    dbg_hitbox_line(pos - v_forward * L, pos + v_forward * L, '1 0 0', 1);
    dbg_hitbox_line(pos - v_right   * L, pos + v_right   * L, '0 1 0', 1);
    dbg_hitbox_line(pos - v_up      * L, pos + v_up      * L, '0 0 1', 1);
    // Forward arrow — barrel direction, extends 8qu past the cross.
    dbg_hitbox_line(pos, pos + v_forward * 8, '1 1 0', 1);
};

// Per-frame draw — called from CSQC_UpdateView before renderscene
// so the additive billboard composites into the scene properly.
//
// Single-frame variant: picks one of muzzleflash1..4 at spawn,
// then animates SIZE and ALPHA across cl_muzzleflash_sprite_time
// seconds. Size lerps from the base half-extent up to base*grow;
// alpha lerps from cl_muzzleflash_sprite_opacity down to 0. The
// flash starts tight and intense, ends large and gone — gives a
// soft puff feel without authoring more frames.
//
// Draw-then-expire ordering: render the current state first,
// THEN test if the lifetime has elapsed. At low FPS a tick can
// span more than the full duration; testing first would expire
// the sprite without ever rendering it.
void() CSQC_DrawMuzzleFlashSprite =
{
    if (csqc_muzfx_active == 0)
        return;

    // Resolve duration first so we can compute normalised age `t`
    // in [0,1] for size/alpha lerps below.  Animated path derives
    // duration from FRAME_COUNT / fps so the flash leaves the
    // screen exactly when the animation finishes.
    float duration;
    float anim_fps = 0;
    if (csqc_muzfx_animated)
    {
        anim_fps = cvar("cl_muzzleflash_anim_fps");
        if (anim_fps <= 0) anim_fps = MUZZLE_ANIM_DEFAULT_FPS;
        duration = MUZZLE_ANIM_FRAME_COUNT / anim_fps;
    }
    else
    {
        duration = cvar("cl_muzzleflash_sprite_time");
        if (duration <= 0) duration = MUZZLE_SPRITE_DEFAULT_DURATION;
    }

    float age = cltime - csqc_muzfx_start_time;
    float t = age / duration;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    float scale = cvar("cl_muzzleflash_sprite_scale");
    if (scale <= 0) scale = MUZZLE_SPRITE_DEFAULT_SCALE;
    float opacity = cvar("cl_muzzleflash_sprite_opacity");
    if (opacity <= 0) opacity = MUZZLE_SPRITE_DEFAULT_OPACITY;

    // Static path lerps size shrink+alpha fade across the lifetime
    // — the single TGA carries no animation of its own, so the
    // motion has to come from these envelopes.  Animated path
    // holds size + alpha constant; the per-frame artwork carries
    // its own brightness curve.
    float half;
    float alpha;
    // Apply the same shrink curve to BOTH the static fade-out path
    // and the animated multi-frame path so cl_muzzleflash_sprite_shrink
    // is a single knob for sprite size animation across all weapons.
    // Animated frames carry their own opacity so we don't multiply
    // alpha down here — only the size lerps with the shrink curve.
    float shrink = cvar("cl_muzzleflash_sprite_shrink");
    if (shrink <= 0) shrink = MUZZLE_SPRITE_DEFAULT_SHRINK;
    float size_mult = shrink - (shrink - 1) * t;
    half = MUZZLE_SPRITE_SIZE * scale * size_mult;
    if (csqc_muzfx_animated)
        alpha = opacity;
    else
        alpha = opacity * (1 - t);
    if (alpha <= 0)
    {
        csqc_muzfx_active = 0;
        return;
    }

    // Resolve world position from the stored local offset using
    // the current view basis. v_forward / v_right / v_up will be
    // overwritten — fine, no caller depends on their values here.
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector pos = view_pos + v_forward * csqc_muzfx_offset_x
                          + v_right   * csqc_muzfx_offset_y
                          + v_up      * csqc_muzfx_offset_z;

    string tex;
    if (csqc_muzfx_animated)
    {
        // age*fps picks the frame index.  Clamp to last frame at
        // the tail of the lifetime — the active=0 reset below
        // expires the sprite on the same tick so the clamp is only
        // hit on the final draw.
        float frame_idx = floor(age * anim_fps);
        if (frame_idx < 0) frame_idx = 0;
        if (frame_idx >= MUZZLE_ANIM_FRAME_COUNT)
            frame_idx = MUZZLE_ANIM_FRAME_COUNT - 1;
        tex = sprintf("gfx/muzzle/animated/animated_%02d",
                      MUZZLE_ANIM_FIRST_FRAME + frame_idx);
    }
    else if (csqc_muzfx_variant == 1) tex = "gfx/muzzleflash1";
    else if (csqc_muzfx_variant == 2) tex = "gfx/muzzleflash2";
    else if (csqc_muzfx_variant == 3) tex = "gfx/muzzleflash3";
    else                              tex = "gfx/muzzleflash4";

    // Camera-facing billboard quad. Additive blend in the shader
    // (scripts/effects.shader) treats the source TGA's black
    // pixels as transparent, so the flash composites cleanly over
    // whatever's behind it without an alpha channel.
    vector right = v_right * half;
    vector up    = v_up    * half;

    R_BeginPolygon(tex, 0, 0);
    R_PolygonVertex(pos - right - up, '0 1 0', '1 1 1', alpha);
    R_PolygonVertex(pos + right - up, '1 1 0', '1 1 1', alpha);
    R_PolygonVertex(pos + right + up, '1 0 0', '1 1 1', alpha);
    R_PolygonVertex(pos - right + up, '0 0 0', '1 1 1', alpha);
    R_EndPolygon();

    // Expire AFTER drawing the final tick so the user always
    // sees at least one frame at low FPS.
    if (age >= duration)
        csqc_muzfx_active = 0;
};
