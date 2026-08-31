// put custom server-only globals and fields here
#pragma target fte_5768

// Worldspawn key cache — populated from the world entity's auto-filled
// .string fields below. Declared here so SV_WeatherStuffPlayer in
// sv_env_fog.qc (which compiles before sv_main.qc) can read them.
string sv_worldspawn_fog;
string sv_worldspawn_rain;
string sv_worldspawn_snow;

// BSP entity-block keys auto-populated by the engine spawner when the
// world entity is parsed.  Same pattern env_fog uses for `.float density`.
.string fog;
.string rain;
.string snow;

// Car fields declared HERE (not sh_vehicle_phys.qc, which compiles AFTER sv_physprop.qc) so that
// phys_files_Send can read them to network the visual wheels.  Used by the car code later.
.float car_steer;         // current front-wheel steer angle (deg), eased toward the input target
.float model_yaw;         // per-car yaw offset (deg) aligning the model nose with physics forward
.float car_wheel_mdlidx;  // wheel model's network index (0 = none); set at car spawn from the wheelmodel key
.float res_base;          // resolved wheelbase (fwd spacing) the physics uses — networked so visual wheels match
.float res_track;         // resolved track (L-R spacing)
.float res_drop;          // resolved wheel drop below the box bottom
.float res_fwd;           // resolved fore/aft wheel-set offset (wheel_fwd key + sv_car_wheel_fwd)

// Per-car driver-seat offsets (FGD keys, auto-parsed by name).  Declared here so phys_files_Send can
// read them to network the seated driver's seat position.  0 = fall back to sv_car_seat_* cvar (Car_Cvar).
.float seat_up;           // seat height above the car origin (u; +up)
.float seat_fwd;          // seat fore/aft offset (u; +forward)
.float seat_side;         // seat left/right offset (u; +right)

// Per-car suspension overrides (FGD keys, auto-parsed).  Declared here (not sh_vehicle_phys.qc, which
// compiles AFTER sv_physprop.qc) so phys_files_Send can network the resolved rest/travel → the CLIENT visual
// wheels cap their droop to the SAME value the physics uses (else they stretch on a per-car tune).
.float ride_height;        // spring free length / ride height (u); 0 = sv_car_ride_height
.float compression_travel; // extra compression on top of the resting sag (u); 0 = sv_car_compression_travel

const float FL_JUMPRELEASED = 4096;

// EF_NODRAW — hides an entity's model from the renderer while keeping
// SOLID and the AABB intact.  cl_defs.qc declares this const for CSQC
// (matches the value used by NQEF_NODRAW in the engine).  sv_defs.qc
// declares the DP_EF_NODRAW extension flag but not the constant
// itself, so server-side files that use it (sv_push.qc, sv_teleport.qc,
// sv_ladder.qc — all hide their brush-bbox triggers via this) need
// it declared somewhere reachable.  Bit value 16 mirrors the
// authoritative client + extension declarations.
const float EF_NODRAW   = 16;
const float EF_ADDITIVE = 32;

// Hitclaim dedup — written by W_ApplyDamage in sv_weapons.qc and read by
// SV_HandleHitclaim in sv_player.qc so server-auth hits and client
// claims don't double-damage the same target within a single shot.
// Declared here (earliest server-side file) so both users see them.
.entity last_damaged_target;
.float  last_damaged_time;

// Per-client flood cap for the hit-reporting stringcmds (hitclaim / breakclaim /
// paintprojhit / snowprojhit / cs).  The engine applies no flood protection to
// client stringcmds, so a buggy/cheating client could spam these toward a
// reliable-backbuf overflow.  SV_ClaimFloodOK (sv_player.qc) meters them in a 1s
// sliding window per player; sv_claim_flood_max bounds it (default 60, well above
// the ~26-30/s legit peak).  Fields on the player entity — self is the engine-set
// attacker for every metered cmd; respawn entity-reuse zeroes them (fresh budget).
.float claim_flood_window_start;   // time the current 1s window opened
.float claim_flood_count;          // metered msgs counted this window

// Grappling hook (sv_grappling) per-player state — server-only half.
// The CSQC-visible half (grapple_rope_active, grapple_anchor) lives in
// shared/sh_pmove.qc next to the slide state because predicted_player
// needs to read it during rope rendering.
.entity grapple_hook;
// grapple_attached moved to shared/sh_pmove.qc — CSQC needs to read
// it for the PM_CategorizePosition ground-snap suppress.
.float  grapple_pull_sound_at;
.float  grapple_next_loop;
// Forward decls for sv_grapple.qc — it compiles AFTER sv_weapons.qc
// and sv_player.qc, both of which need to call these.
void()             W_GrappleImpulse;
void()             W_GrapplePullTick;
void()             W_GrappleHeldTick;
void(entity player) W_GrappleRelease;

// HL2-style prop carry (phys_files filing cabinet) — server-only state.
// Functions live in sv_physprop.qc, but callers compile in varying order
// (sv_weapons PlayerKilled before sv_physprop, sv_use/sv_player after), so
// declare them up-front here.  The CSQC-visible half is .pm_carrying
// (shared/sh_customdefs.qc) replicated through the prediction proxy so the
// viewmodel lowers like a ladder while carrying.
.entity carried_prop;        // on player: prop being carried (world = none)
.entity carried_by;          // on prop:   carrier (world = free); two-grabber guard
// nettest server ragdoll gravity-gun carry (parallel to carried_prop; a corpse_ragdoll is a multi-body
// doll, not a single MOVETYPE_PHYSICS prop, so it can't use Carry_).  Sets pm_carrying so the CLIENT
// viewmodel/throw prediction reuses the existing gravgun flow with no new networking.
.entity carried_ragdoll;     // on player: corpse_ragdoll being carried (world = none)
.entity rag_carrier;         // on corpse_ragdoll: the holder (world = free); cleared on retire/drop
.float  rag_pelvis_tag;      // on corpse_ragdoll: cached "Bip01 Pelvis" tag index (the doll centroid)
.float  pm_carry_fire_last;  // +attack rising-edge latch (throw, not refire)
.float  carry_stuck_since;   // on prop: time the prop went over drop_dist (0 = not stuck)
.float  carry_resolidify_until; // on prop: timeout for the post-drop re-solidify watchdog
.float  pp_was_streaming;     // on prop: 1 if the last think dirtied the CSQC snapshot — drives the
                             //   moving→rest edge that sends one final velocity=0 snapshot
.float  pp_stream_next;      // on prop: earliest time the MOVING CSQC stream may re-flag SendFlags
                             //   (throttles free-prop streaming to sv_physprop_stream_hz)
.float  pp_rest_since;       // on prop: time this prop first went still (0 = moving/awake).  Once it has
                             //   held still for PHYSPROP_SLEEP_DELAY, PhysObj_Think drops from 64 Hz to
                             //   sv_physprop_sleep_hz — a settled map of props then costs ~1/8th.  Cleared
                             //   by PhysProp_Wake (every interaction path) and by any tick that sees motion.
// ---- Buoyancy (props float on water) ----------------------------------------------------------
// World BSP water is STATIC, so the surface plane is probed ONCE on entry and cached here.  A prop
// bobbing in a pond therefore costs ZERO pointcontents per tick — that caching is the whole reason
// this feature is affordable.
.float  pp_buoy_vol;         // on prop: bbox volume, cached at spawn (0 = buoyancy off for this prop)
.float  pp_water_state;      // on prop: 1 = currently in water (skip the per-tick entry probe)
.float  pp_water_z;          // on prop: cached water SURFACE height for the pool it is in
.vector pp_water_org;        // on prop: origin when pp_water_z was probed — re-probe when it moves off this
.float  pp_float_rest;       // on prop: 1 = settled at its float line with gravity zeroed and forcing OFF.
                             //   NOT the same as the sleep gate: see the comment on Buoy_EnterFloatRest for
                             //   why float-rest must latch on the BUOYANCY criterion instead.
.float  pp_float_since;      // on prop: time it first sat inside the equilibrium deadband (0 = not settling)
.float  pp_contact_rest;     // on prop: 1 = held by a CONTACT (pond floor, or a prop stacked on it) rather
                             //   than by buoyancy, so forcing is off but gravity stays ON.  See the
                             //   stuck-rest resolution in Buoy_Tick for why this second mode is needed.
.float  pp_stuck_since;      // on prop: time it first went still WITHOUT being able to reach its float line
.float  pp_loaded;           // on prop: 1 = something is stacked ON it, so its buoyancy is holding that
                             //   load up and it must KEEP being forced (float-rest would sink the stack)
.float  pp_drift_since;      // on prop: time a RESTED prop first started drifting (below the wake cut)
.float  pp_send_zero_vel;    // on prop: 1 = send velocity as zero in the next snapshot WITHOUT zeroing the
                             //   entity's own .velocity — writing it would wake the whole physics island.
.float  carry_grab_time;     // on prop: time the grab started (drives the pull-in lerp window)
.vector carry_grab_origin;   // on prop: prop.origin at grab time (lerp start position)
.vector carry_grab_angles;   // on prop: prop.angles at grab time (lerp start orientation)
// Carried ORIENTATION, stored as a basis in the CARRY FRAME (the pure-yaw frame at
// v_angle_y+180) rather than as Euler angles — see shared/sh_carryrot.qc for why.
// Latched at grab (snapped to the nearest upright/upside-down 90° pose) and then
// preserved for the whole carry; inspect mode rewrites it from client input.
.vector carry_rel_fwd;       // on prop: model +X in the carry frame (unit)
.vector carry_rel_up;        // on prop: model +Z in the carry frame (unit, ⊥ fwd)
.float  carry_dist_ofs;      // on prop: LIVE hold-distance offset (qu), glides toward want
.float  carry_dist_want;     // on prop: scroll-wheel target offset (qu)
.float  carry_rot_next;      // on PLAYER: rate-limit gate for CSEv_carryrot_v
// Contact-FX state (impact sounds + smoke).
.vector pp_prev_velocity;    // on prop: velocity last think — a sharp speed drop = a free-fall/tumble impact; its direction locates the contact surface
.vector pp_prev_origin;      // on prop: origin last Carry_Tick — origin-delta gives the carry-bang approach speed
.float  pp_impact_cooldown;  // on prop: no new impact sound/smoke before this time (anti machine-gun)
.float  pp_slide_next;       // on prop: next allowed slide-puff time
.float  pp_scrape_active;    // on prop: 1 while the looping scrape sound is playing
.float  pp_slide_active_until; // on prop: scrape loop cuts when time passes this (slide-stop grace)
.float  pp_was_touching;     // on prop (carried): 1 if the clip-slide hit a surface last Carry_Tick — distinguishes a fresh BANG from a sustained DRAG
.float  pp_scrape_vol;       // on prop: current scrape loop volume (speed-scaled)
.float  pp_scrape_revol_next; // on prop: next time the scrape volume may be re-issued (throttle)
.float  pp_scrape_var;       // on prop: which scrape variant the active loop is playing — latched at
                             // start and re-used on a volume re-issue, so a material with several
                             // scrape loops (wood 6, plastic 5, concrete 3) doesn't swap timbre mid-slide
.float  pp_scrape_deadline;  // on prop: watchdog stamp — refreshed on every tick that WANTS the loop
                             // playing, so it expires only when the thing that was refreshing it died.
                             // See PhysFiles_ScrapeWatchdog (sv_physprop.qc).
.float  pp_scrape_reissue_at; // on prop: next time to replay the (non-looping) sample for a long drag
.vector pp_scrape_prog_org;  // on prop: origin at the last progress sample — see the progress gate in
.float  pp_scrape_prog_next; // PhysFiles_StartScrape.  A prop that keeps asking to scrape while going
.float  pp_scrape_muted;     // nowhere (an ODE pile jittering in place) is muted until it really travels.
.vector car_scrape_normal;   // on car: latched wall normal while grinding along BSP (0 0 0 = not grinding)

// Unified phys-object config (po_*) — set per object BEFORE PhysObj_Setup so the
// shared ODE core + the shared think branch to the right per-object behavior.
// Barrel / can / cabinet / weapon-drop all route through one setup + one FX path.
.float  po_is_phys;        // 1 on any unified phys object (helper / wake gate)
.float  po_fx_enabled;     // run contact-FX detection (impact/slide/scrape/smoke/spark)
.float  po_material;       // resolved prop-material index (PropMat_For, sh_propmaterials.qc); -1 = none (cvar fallback)
.float  po_sndset;         // scripts/materialsounds.txt SET INDEX for this object's contact sounds
                           // (MatSnd_*, sh_matsounds.qc).  Resolved once in PhysObj_Setup from
                           // PropMat_FxSound(po_material); weapon drops get the "weapon" set and
                           // cars override to "metal".  Replaces the old 2-value po_fx_soundset.
.float  po_carry_enabled;  // cabinet only: +use carriable
.float  po_sleep_enabled;  // free props (barrel/can/weapons): QC sleep/wake at rest
.float  po_stuck_grace;    // seconds embedded in BSP before despawn (5 props / 2 drops)
.float  po_is_weapon_drop; // weapon drop: keep weapon_touch + dropped-weapon net path
.float  collision_shape;   // prop_physics FGD: 0=Auto(mesh/by-name) 1=Box 2=Cylinder 3=Sphere → .geomtype (cheap primitive sim)

// Gravity gun widens Carry_IsCarriable to ANY ODE body for the duration of one
// grab (the +use cabinet path leaves this 0).  See sh_wpn_gravitygun.qc.
float   carry_allow_any;

float(entity e)                   Carry_IsCarriable;
float(entity player, entity prop) Carry_TryGrab;
void(entity player)               Carry_Drop;
void(entity player)               Carry_Throw;
void(entity player)               Carry_Tick;
// Unified phys-object core — defined in sv_physprop.qc, which compiles AFTER
// sv_weapons.qc, so forward-declare here for the weapon-drop callers.
void(entity b, float obj_mass, float obj_friction) PhysObj_Setup;
void(float lin)                            PhysObj_DetectContactFX;  // weapon drops share the FX
void(entity e)                             PhysProp_Wake;        // resume the 64 Hz think on a slept prop
void(entity e)                             PhysProp_KickStream;  // Wake + un-throttle ONE mirror snapshot

// Debug-proxy existence latches.  CarDbg_Tick / NavDbg_Tick run EVERY frame (StartFrame /
// Bot_RunFrame) and, with their debug cvar off, used to walk the whole edict table via
// find() just to tear down proxies that had never been created.  These are set where a
// proxy is actually spawned (*Dbg_EnsureProxy) and cleared after teardown, so the common
// debug-off case costs one float test instead of an O(num_edicts) scan per frame.
float cardbg_proxies_exist;
float navdbg_proxies_exist;

// BSP entity-lump fields that map compilers (e.g. light, worldspawn) stamp
// onto entities but we don't consume. Declared as no-op stubs so the engine
// stops printing "'X' is not a field" warnings on map load. Do not reference.
// Note: mapname is NOT added here — it already exists as a global string
// (sv_defs.qc) which shadows any field named `mapname`, so declaring it
// here as `.string` errors with "Type mismatch on redeclaration".
.float  delay;      // light / trigger delayed-use timer
.string wad;        // worldspawn texture wad path(s)

// ---- map format latch ----
// TRUE when the loaded worldmodel is a GoldSrc (Half-Life / Sven Co-op)
// BSP30 rather than one of our own ericw-tools maps.  Entity code that has
// to interpret mapper-authored spawnflags needs this, because our FGD and
// Hammer's disagree about what several bits mean (see Door_NormaliseFlags
// in sv_doors.qc).
//
// The engine publishes the worldmodel's source game as serverinfo star key
// "*bspversion" in SV_SpawnServer (engine/server/sv_init.c, `fromgame ==
// fg_halflife` -> "30") BEFORE it runs PR_SpawnInitialEntities, so this is
// readable from inside every spawn function.
//
// NOT usable as a detector: worldspawn's "wad" key.  ericw-tools' qbsp
// passes it straight through into Quake BSPs too (WriteEntitiesToString
// strips only _tb_*), so our own TrenchBroom maps carry it as well.
//
// Cached because infokey() allocates a tempstring per call and door /
// button / trigger spawn functions would each pay for it.  0 = not yet
// probed, 1 = GoldSrc, -1 = native.  Reset per map in worldspawn()
// (sv_main.qc) — FTE does not reload progs between maps.
float sv_map_goldsrc_cache;

float() Map_IsGoldSrc =
{
    if (!sv_map_goldsrc_cache)
    {
        if (stof(infokey(world, "*bspversion")) == 30)
            sv_map_goldsrc_cache = 1;
        else
            sv_map_goldsrc_cache = -1;
    }
    return (sv_map_goldsrc_cache > 0);
};

// ---- mover / door / button fields ----
.vector pos1;           // closed/bottom position
.vector pos2;           // open/top position
.float  wait;           // seconds to wait at top before returning (-1 = stay)
.float  lip;            // units of lip remaining at end of move
.float  distance;       // explicit move distance (overrides lip calc)
// attack_finished moved to shared/sh_weapons.qc
.vector mangle;         // alternative angle spec for door direction
.string groupname;      // door group name for linked doors
.vector cmins;          // combined world-space bounding box (door group)
.vector cmaxs;
.float  button_state;   // BUTTON_STATE_*
.float  door_state;     // DOOR_STATE_*
.float  door_mark;      // flood-fill serial for door group activation
// Set at door spawn when the mapper gave the door a `master` key.  Read by
// sv_brushsync.qc (which compiles before sv_doors.qc) to suppress CSQC +use
// prediction: a multisource's locked/unlocked state is dynamic and isn't
// networked, so the client cannot know whether the press will be accepted.
.float  door_has_master;
// TRUE when a player's direct +use may open this door.  Half-Life grants that
// only with SF_DOOR_USE_ONLY (256); native maps stay permissive.  Computed at
// spawn, read by door_use / rotdoor_use, SV_UseTarget and the predict_block
// byte — declared here because SV_UseTarget and brushsync both compile before
// the door files.
.float  door_player_usable;
// Sven's "Only Trigger" (sven-coop.fgd:976).
//
// THIS IS A BREAKABLE KEY, NOT AN ACTIVATION KEY, and it used to be read as the
// latter — "the door answers its target chain and refuses the player outright".
// In sven-coop.fgd it lives in the Door base class inside a contiguous run of
// func_breakable keys re-exposed as keyvalues (breakable, fireonbreak, material,
// instantbreak, weapon, explosion, gibmodel, explodemagnitude, displayname,
// onlytrigger, breakontrigger, repairable, showhudinfo, immunetoclients,
// explosivesonly) — the Door base needs them as KEYS because its own spawnflag
// bits are already spoken for by the door flags.  `onlytrigger` carries the
// identical display string, "Only Trigger", as func_breakable's spawnflag 1,
// whose meaning is: only a trigger can BREAK it, damage cannot.
//
// Two independent checks agree.  func_train_fg entities carry the key (18 in the
// corpus), and a train is never "opened", so it cannot be an open-gate; on
// fallguys_s2 they carry it alongside `armorvalue 500` and `dmg 999999`, i.e. in
// a hit-points context.  And of the 65 corpus entities that set it, exactly ONE
// has no targetname — pizza_ya_san1's *38 func_door_rotating — which under the
// old reading could be opened by literally nothing: not +use, not a shoulder
// push, not damage (no health key), and not a trigger chain (no name to call).
// That is the reported "*38 barely opens" door.
//
// So it now gates the DAMAGE-open path only (rotdoor_killed), mirroring
// func_breakable's BREAKABLE_TRIGGER_ONLY, and no longer touches +use, touch, or
// CSQC prediction.  Caveat worth keeping: Sven Co-op is closed-source, so this
// rests on the FGD's key grouping plus the corpus distribution, not on
// decompiled behaviour.
.float  onlytrigger;

// "A press aimed at this entity must fall THROUGH to whatever is behind it."
//
// Split out of onlytrigger, which used to be borrowed for this.  The two are
// unrelated: this one is the QC spelling of Half-Life's ObjectCaps() withholding
// FCAP_IMPULSE_USE, so the entity is not in the player's use search at all and
// SV_UseTarget must report NOT-HANDLED rather than consume the press (the
// through-walls trace loop and the cone fallback both stop at the first handled
// entity).  Trigger chains still reach .use normally.  Set by trigger_btarget
// without SF_BTARGET_USE (sv_th_entities.qc); doors never set it.
.float  use_passthrough;

// Same shape, same reason: monsters carry a .use purely so trigger chains pass
// through them, and SV_UseTarget (which compiles before sv_monsters.qc) has to
// be able to tell that apart from a monster a player may genuinely interact
// with.  Off for every monster today; the ally work turns it on for the classes
// where +use means "follow me".
.float  monster_player_usable;

entity activator;       // entity that triggered the current use/touch
float sv_use_is_player_direct;  // TRUE only during SV_PlayerTryUse

// TRUE only while a door's proximity trigger is re-entering door_use /
// rotdoor_use.  Half-Life's CBaseDoor::DoorTouch gives the player the locked
// click on a refusal (doors.cpp:496-497, :502-507); a trigger chain hitting the
// same locked door stays silent.  sv_use_is_player_direct cannot make that
// distinction because the touch sweep runs from PM_PlayerMove, not
// SV_PlayerTryUse — hence a second flag rather than widening the first one,
// which NO_TRIGGER / USE_ONLY discriminate on.
float sv_use_is_player_touch;

// Player-vs-monster .touch dispatches, counted so "the roach is not squished"
// can be told apart from "the roach was never touched".  Before the monster
// branch was added to SV_CheckTouchTriggers this was structurally always 0:
// the mod's custom pmove means the engine emits no touch pairs for players.
float sv_dbg_monster_touch;

// scripted_sentence speaker binding, counted at spawn in sv_goldsrc_compat.qc
// and reported by the AI status line in sv_ai_talk.qc.  Here rather than beside
// either of them because sv_ai_talk.qc compiles at 202 and the spawn function at
// 209, and QC globals cannot be forward-declared.
float sv_dbg_sent_total;
float sv_dbg_sent_named;

// Set by the GoldSrc `game_end` entity (sv_goldsrc_compat.qc) to request an
// immediate map end.  Consumed by the round-phase machine in sv_main.qc, which
// owns round_phase / map_restart_time and compiles much later — routing the
// request through a flag avoids a forward declaration of that whole state.
float sv_game_end_requested;

// Packed trigger_camera binding + presentation bits for the owning client.
// See STAT_CUTSCENE / CUTSCENE_* in shared/sh_customdefs.qc.  Declared here so
// the clientstat() registration in sv_main.qc resolves it regardless of where
// sv_trigger_camera.qc lands in the compile order.
.float sv_cutscene_stat;

// trigger_camera "Player Invulnerable" (spawnflag 256).  Declared this early
// because the damage chokepoint that reads it, W_CanDamageTarget in
// sv_weapons.qc, compiles long before sv_trigger_camera.qc which sets it.
.float cutscene_immune;

// Damage callbacks (set on any entity that can take damage)
.void() on_damaged;     // called when health reduced but still > 0
.void() on_killed;      // called when health reaches 0

// FTE ODE physics fields not declared in the project's fteextensions.qc.
// Shared by sv_physprop.qc and optional physics-backed weapon drops.
.float damp_linear;
.float damp_angular;
.float max_angular;
.float dimension_solid;
.float dimension_hit;

// Server-side death ragdolls (sv_ragdoll.qc) — forward-declared here so PlayerKilled
// (sv_weapons.qc, compiled earlier than sv_ragdoll.qc) can call them.
void(entity p) Ragdoll_CaptureAlivePose;
void(entity attacker, entity victim) Ragdoll_SpawnFromDeath;
void(entity rd) Ragdoll_Free;
.entity sv_ragdoll_ent;     // corpse proxy -> its authoritative server ragdoll (world until spawned)
// gravity-gun carry (sv_ragdoll.qc, compiled late; called from sh_wpn_gravitygun.qc + sv_player.qc earlier)
float(entity player, entity rd) Ragdoll_TryGrab;
void(entity player) Ragdoll_CarryTick;
void(entity player) Ragdoll_CarryThrow;
void(entity player) Ragdoll_CarryDrop;
// black-hole (+attack2) pull/blast of corpse ragdolls — called from sh_wpn_gravitygun.qc (earlier)
void(vector center, float radius) Ragdoll_PullTick;
void(vector center, float radius, float speed) Ragdoll_BlastFrom;
// test spawner + sweep — called from SV_ParseClientCommand (sv_player.qc, earlier)
void(entity player) Ragdoll_SpawnTest;
void() Ragdoll_SweepAll;

// Player body paint (server/sv_paint.qc, compiled after sv_weapons/weapon files) —
// forward decls so the earlier files can call in: paintball player-hit splats
// (sh_wpn_paintball.qc) and the camo damage wash (sv_weapons.qc damage path).
void(entity victim, vector col, float seed) SV_Paint_PlayerSplat;
float() SV_Paint_NextSeed;
void(entity victim) SV_Paint_OnDamage;

// Map weapon tracking — for round reset
.float map_weapon;          // TRUE if this weapon was placed in the map (not dropped)
.void() map_weapon_spawn;   // spawn function to call on reset
entity map_weapon_chain;    // linked list of map weapon spawn records
// The entity SV_DebugSpawnWeapon most recently put on the floor.  That function
// builds the pickup on a temporary `self` and restores the caller's, so the
// handle was otherwise unrecoverable — which is fine for the debug menu it was
// written for, but not for squadmaker, which has to stamp .sq_ownerid onto the
// child it just dispensed.  A global rather than a return value because the
// call sites are spread across three compile units.  Declared HERE, ahead of
// both of them.  It is a global and not a field on purpose: a .field would
// claim that spelling in the BSP keyvalue namespace (sv_multi_manager.qc
// MM_CollisionScan explains what that costs).
entity sv_last_spawned_weapon;
.entity map_weapon_next;    // next in chain
.vector map_weapon_origin;  // original spawn position
.vector map_weapon_angles;  // original spawn angles

void() sub_remove =
{
	remove(self);
};

void() sub_noop = {};

void(float event) BeginEvent =
{
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, event);
};

void(vector vec) MulticastVector =
{
	WriteCoord(MSG_MULTICAST, vec_x);
	WriteCoord(MSG_MULTICAST, vec_y);
	WriteCoord(MSG_MULTICAST, vec_z);
};

void(float val) MulticastByte =
{
	WriteByte(MSG_MULTICAST, val);
};

void(float val) MulticastShort =
{
	WriteShort(MSG_MULTICAST, val);
};

void(float val) MulticastFloat =
{
	WriteFloat(MSG_MULTICAST, val);
};

void(entity e) MulticastEnt =
{
	WriteEntity(MSG_MULTICAST, e);
};

void(string s) MulticastString =
{
	WriteString(MSG_MULTICAST, s);
};

// Spawnflag 1 — START_OFF: at map load / round restart, the
// light's switchable style is set to "a" (dark) instead of "m"
// (full).  Triggers can then turn it on by retoggling.  Only
// meaningful on lights with a non-zero `style` key — style 0 is
// the static lightmap pass and isn't toggleable per-entity.
const float LIGHT_START_OFF = 1;

.float light_state;          // 0 = off, 1 = on (current)
.float light_default_state;  // re-applied at round restart

// "Custom Appearance" — a raw lightstyle string, a..z, where 'a' is black and
// 'z' is brightest.  Declared here rather than beside global_light_control (its
// other reader, sv_th_entities.qc) because `light` itself needs it and this file
// compiles at sv_progs.src:22 against that one's :428.
.string pattern;

// Bodies live further down this file, immediately after the USE_* constants:
// Light_Use needs them for CLight's ShouldToggle guard and they are declared at
// :923-953, below here.  Forward-declared rather than moved wholesale so `light`
// and Light_RoundReset stay beside the fields they drive.
void() Light_ApplyState;
void() Light_Use;

void() light =
{
	// Lights without a targetname AND without a switchable style
	// have no runtime role — the BSP compiler already baked their
	// contribution into the lightmap.  Drop them like the legacy
	// stub did so they don't consume an entity slot.
	if (self.targetname == "" && self.style <= 0)
	{
		remove(self);
		return;
	}

	self.light_default_state = (self.spawnflags & LIGHT_START_OFF) ? 0 : 1;
	self.light_state = self.light_default_state;
	self.use = Light_Use;
	Light_ApplyState();
};

// Walk every `light` entity and re-apply its default on/off state.
// Called from RoundRestart so a button-press-driven toggle from the
// previous round doesn't carry over.  Unconditionally re-issues the
// lightstyle() call even when the state matches — lightstyle's per-
// style global cache makes that a no-op on the engine side.
void() Light_RoundReset =
{
	entity e = find(world, classname, "light");
	while (e)
	{
		entity oldself = self;
		self = e;
		self.light_state = self.light_default_state;
		Light_ApplyState();
		self = oldself;
		e = find(e, classname, "light");
	}
};

// Per-player crosshair stat fields — auto-networked to each client via clientstat()
.float sv_crosshair_basespread;
.float sv_crosshair_movespread;
.float sv_crosshair_fullspeed;
.float sv_crosshair_gapscale;
.float sv_crosshair_disabled;
.float sv_zoomstage;

// The last point_checkpoint anybody touched, or world.  Read by
// PlayerPlaceAtSpawnPoint as a respawn override; written by Checkpoint_Touch.
//
// A GLOBAL rather than a field on the player because a checkpoint in a co-op
// campaign is a party-wide fact - one person reaching it moves everybody's
// respawn forward, which is the whole reason the entity exists.  Declared here
// rather than in sv_checkpoint.qc because sv_player.qc compiles first and QC
// forward-declares functions but not variables.
entity cp_respawn_at;

// The player's torch, as reported by that player's own CSQC (`cmd fl`, handled
// in SV_ParseClientCommand).  The flashlight is drawn entirely client-side, so
// this is the server's only knowledge of it and it exists for exactly one
// consumer: monster AI that is supposed to react to being lit.  Nothing
// authoritative reads it — see the note at the command handler.
.float player_flashlight;

// Per-player team fields — auto-networked to each client via clientstat()
.float player_team;
.float player_model_index;  // 0-3, which character model the player chose
.float team_menu_request_serial;
.float deaths;

// Round timer — per-player field synced from global each frame
.float round_timer_remaining;

// Defuse progress (0..CFC4_DEFUSE_TIME) — set per-frame by
// C4_TickDefuseInteraction in sh_wpn_cfc4.qc on the active defuser
// only; everyone else stays at 0.  Auto-networked via clientstat()
// so the HUD bar fills only on the defuser's own client.
.float defuse_progress_stat;

// Round timer globals
float round_end_time;     // server time when the current round expires
float round_active;       // TRUE once a round has started (legacy, use round_phase)
float round_number;       // current round (1-based)
float map_start_time;     // server time when the map started

// Gamemode / round phase globals
float round_phase;          // ROUND_PHASE_* — current phase of the round
float freeze_end_time;      // server time when freeze ends
float round_restart_time;   // server time when round will restart (during ROUND_END)
float map_restart_time;     // server time when map will restart (during MAP_END)
float round_winning_team;   // team that won the round (0=timer/draw, TEAM_BLUE, TEAM_RED)
float blue_team_score;      // rounds won by blue team
float red_team_score;       // rounds won by red team

// Per-player stats for map timer, round number, max rounds
.float sv_maptimeleft;
.float sv_roundnum;
.float sv_maxrounds;

// Per-player mirror of sv_func_tickrate cvar.  Updated each frame in
// SV_StartFrame's per-player loop.  Registered via STAT_FUNC_TICKRATE
// in clientstat so CSQC's PM_CheckRotatingCarry can scale Phase 3
// slide rates to match the server's per-tick rate.  Per-player only
// because clientstat works on a per-entity field — the value is the
// same global cvar copied into each player's slot.
.float sv_func_tickrate_value;

// ---------------------------------------------------------------------------
// THE MOVER TICK MUST NOT BE SHORTER THAN THE SERVER'S PHYSICS FRAME.
// ---------------------------------------------------------------------------
// Every mover in this mod is a MOVETYPE_PUSH brush that sets a velocity and
// re-aims on a fixed tick (sv_func_tickrate, 64 Hz for trains, 40 for doors).
// The engine advances such a brush by
//
//     movetime = min(host_frametime, nextthink - ltime)          sv_phys.c
//     if (WPhys_Push(...)) ltime += movetime;
//
// and it is called ONCE per physics frame.  So when the tick is SHORTER than the
// server's frame, the brush is handed one tick of travel per frame instead of one
// frame of travel, and it moves at
//
//     speed * tick * server_fps
//
// A 30 fps server ran every train, door, plat and lift in the game at HALF its
// authored speed, and nothing said so: the brush was internally consistent -
// 240 units per second of ITS OWN clock - it was its clock that had stopped
// keeping up.  Measured on th_ep1_00's intro truck: 99 mover ticks in 3.12
// real seconds against the 199 a 64 Hz tick asks for, ltime lagging `time` by a
// steadily growing 11 -> 21 seconds, and the truck arriving at its first corner
// 14 s after departure instead of 7.  That is the reported "the car doesn't move
// as early as it should - the title screen appears before it reaches the
// destination"; the title is on a multi_manager, which runs on the server clock
// and was never late.
//
// The fix is to schedule no faster than the server can actually run, so movetime
// is host_frametime instead of a clamp.  The mover then travels at exactly
// `speed` regardless of frame rate; only how often it RE-AIMS changes, which
// costs a little cornering accuracy on a slow server and nothing else.
//
// The interval is MEASURED rather than read from a cvar, because the QC
// `frametime` global is not the number that matters here (it reports the tick the
// pusher was given, not the frame it was given it in) and because a server's real
// frame rate moves with load.  StartFrame samples `time` once per physics frame;
// the value rises immediately and decays slowly, so one long hitch lengthens the
// tick for a moment and a sustained slowdown lengthens it for good.
float sv_mover_frame_interval;   // measured physics-frame length, seconds
float sv_mover_frame_lasttime;   // previous StartFrame's `time`

// `fallback_hz` is the per-class default used when sv_func_tickrate is unset:
// 64 for trains, 40 for doors and momentaries, matching what each site used
// before this was factored out.
float(float fallback_hz) Mover_TickInterval =
{
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = fallback_hz;
    if (hz > 200)  hz = 200;

    float iv = 1.0 / hz;
    if (sv_mover_frame_interval > iv)
        iv = sv_mover_frame_interval;

    // CAPPED AT 0.05, and the number is not arbitrary: it is the same bound
    // CSQC clamps its forward extrapolation of a mover to (cl_brushsync.qc).
    // Past that the client has nothing left to extrapolate and the brush visibly
    // freezes between snapshots, so lengthening the tick further would trade a
    // speed error the player cannot see for a stutter they can.  A server slower
    // than 20 Hz keeps the old behaviour - movers run slow - which is the lesser
    // of the two and is a server-performance problem, not a mover problem.
    if (iv > 0.05)
        iv = 0.05;
    return iv;
};

// Per-player stats for gamemode system
.float sv_round_phase;
.float sv_freeze_timeleft;
.float sv_gamemode;
.float sv_winning_team;

// Death tracking
.float is_dead;             // TRUE if player died this round
.float death_time;          // server time when player died (0 = alive, -1 = past delay)
// Latched TRUE by the lethal-headshot gib branch in sv_weapons.qc, cleared by
// PlayerSpawn.  The medkit's revive reads it: Sven's rule is that a gibbed body
// cannot be brought back, and once the corpse's modelindex has been zeroed there
// is nothing else left to ask.
.float death_was_gib;
.float sv_death_delay_left; // clientstat: seconds left in death delay
.float sv_is_dead;          // clientstat: 1 when dead, 0 when alive
.float sv_blue_score;       // clientstat: blue team round wins
.float sv_red_score;        // clientstat: red team round wins
.float pending_round_join;  // TRUE between mid-round Elimination join and next RoundRestart

// CS-style economy + armor + defuse kit (buy menu).  money/armor are
// server-authoritative and mirrored to the owning client via clientstat
// (STAT_MONEY / STAT_ARMOR) each frame.  money persists across deaths and
// rounds (reset to mp_cashstart only at match start); armor/helmet/kit
// clear on respawn (PlayerSpawn).
.float money;          // current cash
.float sv_money;       // clientstat mirror (STAT_MONEY)
.float armor;          // current Kevlar value 0..100
.float sv_armor;       // clientstat mirror (STAT_ARMOR)
.float has_helmet;     // Kevlar+Helmet — cuts headshot damage
.float has_defusekit;  // doubles bomb-defuse speed (defusing team only)
// The HEV suit, as a BOOLEAN, separate from .armor.  Half-Life's item_suit
// grants no armour at all - it sets pev->weapons & (1<<WEAPON_SUIT), which is
// what gates the HUD, the flashlight and the voice (dlls/items.cpp:174-201).
// This mod deliberately diverges and grants armour instead (see the long note
// on GoldSrc_Suit_Touch), because none of those things are gated here - but
// "did you pick up a suit" is still a question maps ask, and .armor cannot
// answer it because item_battery raises that too.  Sven's trigger_suitcheck
// reads exactly this bit.  NOTHING is gated on it; it is a signal, not a rule.
.float has_suit;
.float money_started;  // 1 once mp_cashstart granted (so first team-join inits once)
.float buyzone_time;   // last server time the player overlapped an allowed func_buyzone
.float sv_in_buyzone;  // clientstat mirror (STAT_IN_BUYZONE) — 1 when the player may buy
.float sv_can_plant_c4; // clientstat mirror (STAT_CAN_PLANT) — 1 when the C4 carrier may plant here
.float sv_can_medkit;   // clientstat mirror (STAT_CAN_MEDKIT) — MEDKIT_CAN_HEAL | MEDKIT_CAN_REVIVE
.float sv_can_soflam;   // clientstat mirror (STAT_CAN_SOFLAM) — 1 when a strike can be called
.float sv_bomb_planted; // clientstat mirror (STAT_BOMB_PLANTED) — 1 while a planted_c4 is live in Defuse
// clientstat mirror (STAT_SHIELD) — SHIELD_CARRIED | SHIELD_DEPLOYED.  The
// LOCAL player's copy: the shield decides their view model, their movement
// speed and whether their trigger works, and CSQC predicts all three.  Other
// players' shields ride the visual proxy's bodygroup bits instead (sv_player.qc),
// because that is what CSQC already reads to decide how to draw someone else.
.float sv_shield_state;

// nettest progression spine (Part 1) — persistent XP / levels.  Authoritative
// .prog_* fields load from / save to the sqlite player store (sv_progression.qc);
// the .sv_* mirrors are networked to the owning client via clientstat each frame.
.float prog_xp;          // XP banked toward the next level (0..prog_xp_next)
.float prog_level;       // current level (>=1)
.float prog_xp_next;     // XP required to reach the next level
.float prog_kills;       // lifetime kills (persisted)
.float prog_deaths;      // lifetime deaths (persisted)
.float prog_headshots;   // lifetime headshot kills (persisted)
.float prog_wins;        // lifetime round wins (persisted)
.float prog_playtime;    // lifetime seconds played (persisted)
.string prog_guid;       // identity key (engine GUID, or IP fallback; "" = unpersisted)
.float prog_loaded;      // 1 once the async DB load has applied
.float prog_pending_xp;  // XP earned during the load gap, folded in on load
.float prog_match_xp;    // XP earned this session (drives the match-end summary)
.float prog_dirty;       // 1 when there are unsaved changes (autosave gate)
.float prog_last_save;   // server time of the last DB flush
.float sv_xp;            // clientstat mirror (STAT_XP)
.float sv_level;         // clientstat mirror (STAT_LEVEL)
.float sv_xp_next;       // clientstat mirror (STAT_XP_NEXT)
.float sv_sessionxp;     // clientstat mirror (STAT_PROG_SESSIONXP)

// nettest bots (sv_bots.qc) — server-side AI fake clients (.is_bot is declared shared in sh_customdefs.qc)
float bot_adding;          // TRUE only while spawnclient() runs in Bot_Add — is_bot isn't set yet but the
                           // connect/spawn-time per-player unicasts already fire, so guard them on this too

// TRUE only for a slot the engine will actually deliver a per-player (MSG_ONE)
// message to.  clienttype()==CLIENTTYPE_REAL tests protocol!=SCP_BAD — the SAME
// condition the engine's Write_GetClient() uses (it returns NULL for a bot slot,
// which spams "Not a client" / "msg_entity: not a client").  This reads the
// ENGINE truth, so it stays correct even when .is_bot desyncs — which it does on
// a listen-server map change: the engine re-homes surviving bot slots and
// ED_Clear wipes .is_bot to FALSE while the slot is still a SCP_BAD bot, leaving
// a roster "player" with is_bot==FALSE that every !is_bot unicast then spams.
float(entity p) SV_PlayerHasNetchan =
{
	return p && p.classname == "player" && !bot_adding && clienttype(p) == CLIENTTYPE_REAL;
};
.entity bot_enemy;         // current target
.float  bot_enemy_time;    // last time the enemy was visible
.vector bot_enemy_lastpos; // last-known enemy position
.float  bot_repath_time;   // next allowed A* re-path
.float  bot_repath_fails;  // consecutive failed searches -> backoff (see Bot_Navigate)

// Monster path storage.  Monsters cannot use bot_pathnodes[] — that is indexed by
// edict slot and only players have reserved ones — so they allocate from the nav
// path pool instead.  ai_pathslot is slot+1 so that 0 means "holds nothing", which
// makes a released or never-allocated entity indistinguishable and release
// idempotent.  ai_path_serial pins the path to the graph build it was computed
// against: node indices do not survive a rebuild.
.float  ai_pathslot;
.float  ai_path_len;
.float  ai_path_cur;
.float  ai_path_serial;
// Set by SV_OnEntityNoSpawnFunction on any classname we have no spawn function
// for.  Those entities survive as inert relays so trigger chains routed THROUGH
// them still reach the far side — but nothing ever fires them on its own, so
// anything that waits for one to report in waits forever.  multisource reads this.
.float  gs_unimplemented;

.float  nav_req_slot;      // queued path request, slot+1 (0 = none). Dedup key:
                           // a re-request overwrites its own entry instead of
                           // appending, so N monsters can never queue more than N.
.vector bot_aim;           // smoothed aim angles
.vector bot_aimoff;        // slow human-like aim error offset (deg)
.float  bot_aimoff_time;   // when to re-roll bot_aimoff
.float  bot_fire_time;     // reaction gate before opening fire
.float  bot_path_len;      // waypoints in this bot's path slice
.float  bot_path_cur;      // cursor into the path slice
.float  bot_goal_node;     // current roam goal node index
.vector bot_lastpos;       // for stuck detection
.float  bot_stuck_time;    // time of last meaningful movement
.float  bot_strafe;        // -1/+1 strafe direction
.float  bot_strafe_time;   // when to flip strafe
.float  bot_jump_time;     // auto-jump-ledge cooldown (also gates the avoidance wall-steer mid-hop)
.float  bot_los_lost_time; // time LOS to bot_enemy was first lost (0 = currently have LOS) — anti-flicker grace
.float  bot_retarget_time; // next periodic "re-pick the nearest visible enemy" (Bot_Think)
.float  bot_lasthurt_time; // last time this bot took damage (gates the periodic re-pick; biases toward the attacker)

// IsBotEnemy is defined in sv_bots.qc (compiles after sv_weapons.qc); forward-declare
// here so the wake-when-shot reaction in W_ApplyDamage (sv_weapons.qc) can call it.
float(entity bot, entity t) IsBotEnemy;

// nav/bot debug overlay (sv_bots.qc NavDbg_*) — one per-client SendEntity proxy that
// streams the nav graph + per-bot state/path to that viewer (sv_debug_nav 1).
.entity nav_debug_proxy;     // the proxy entity owned by this client
.float  navdbg_cursor;       // on proxy: graph-stream cursor (nodes sent so far)
.float  navdbg_bottime;      // on proxy: next allowed bot-state/path push
.float  navdbg_build_serial; // on proxy: nav_build_serial last streamed (graph resend trigger)
.float  bot_roam_time;     // when to pick a new roam goal
.float  bot_state;         // debug: behaviour state 0 roam / 1 hunt / 2 engage
.float  bot_burst_end;     // end time of the current fire BURST
.float  bot_burst_cycle;   // end time of the burst+sidestep cycle (then start a new burst)
.float  bot_fire_held;     // fire-button pulse state (toggle so semi-auto re-triggers)
.float  bot_stuck_count;   // consecutive AntiStuck triggers (gate the path-thrashing repath/180s)

// Count of func_buyzone brushes on the current map (0 = buy anywhere fallback).
// Reset in worldspawn before entities spawn; incremented by each func_buyzone.
float buyzone_count;
// Latches round_phase so the round-end cash award fires exactly once on the
// edge into ROUND_PHASE_ROUND_END (covers timer/elimination/C4 paths).
float money_last_round_phase;

// Fall damage tracking
.float fall_velocity;       // current downward speed while airborne
.float was_onground;        // FL_ONGROUND state from previous frame

// Forward declarations
void(entity player) PlayerRefreshScoreboardInfo;  // sv_player.qc
void() RoundStart;                                 // sv_main.qc
// Drift-trace ring buffer (sv_player.qc).
void(float t_now, float msec, vector mv, float btn, float wep, vector org, vector vel) Drift_Append;
void(string label) Drift_Dump;

// Server-side killcam track (sv_killcam.qc, compiled after sv_weapons.qc which calls
// SendTrack — hence these forward decls, like Lagcomp_TraceLine in sh_customdefs.qc).
void() Killcam_SV_Init;
void() Killcam_SV_RecordAll;
void(entity attacker, entity victim) Killcam_SV_SendTrack;

// --- Prop Hunt (sv_prophunt.qc) ---------------------------------------------
// Server-only disguise state (the shared ph_* hull fields live in
// sh_customdefs.qc since CSQC prediction needs them too).
.float ph_maxhealth;			// disguise max HP; health fraction preserved across re-possess
.float ph_locked_yaw;			// carry-frame yaw (v_angle_y) frozen while committed; compose yaw0 = ph_locked_yaw + 180
.float ph_rot_next;				// rate gate for the CSEv_prop_rotate upstream (mirrors carry_rot_next)
.float ph_disguise_scale;		// prop .scale mirrored to the proxy render (0 treated as 1)
.float ph_disguise_skin;		// prop .skin mirrored to the proxy render
// Visual-proxy dirty-diff caches (live ON the proxy, Player_VisualProxy_Sync)
.float vps_last_disguise_mi;
.float vps_last_ph_hull_halfxy;
.float vps_last_ph_mesh_halfxy;
.float vps_last_ph_mesh_height;
.float vps_last_ph_hull_minz;
.float vps_last_ph_hull_height;
.float vps_last_ph_scale;
.float vps_last_ph_skin;
// Cross-file entry points (sv_prophunt.qc compiles after sv_weapons.qc /
// sv_use.qc / sv_player.qc, which all call in — same pattern as Killcam above).
float(entity pl) PropHunt_TryPossess;		// +use hook (sv_use.qc); TRUE = consumed the use
float(entity pl) PropHunt_ToggleYawLock;	// impulse-6 hook (sv_weapons.qc); TRUE = consumed
float(entity pl) PropHunt_TryDecloak;		// impulse-7 (Weapon Special) hook (sv_weapons.qc); TRUE = consumed
void(entity pl) PropHunt_ClearDisguise;		// PlayerSpawn / spectate / disconnect cleanup
float(entity pl) PropHunt_IsHider;			// gamemode==PROPHUNT && team==BLUE (carry gate etc.)
float(entity pl) PropHunt_HiderNoWeapons;	// mp_ph_hider_noweapons: hider may not pick up / fire guns
float(entity att, entity hit, float damage) PropHunt_Missfire;	// seeker-shot-a-real-prop reflect (PhysProp_TryPushFromTrace)
.float ph_missfire_gate_time;	// one reflect per blast: pellets/pen-chains land in one frame; this gates them to a single punish

entity player_chain_head;
.entity player_chain_next;
.entity player_chain_prev;

// Put an entity as the first of the linked list
void(entity adding) player_chain_add =
{
	if (adding.player_chain_prev || adding.player_chain_next || (adding == player_chain_head && !adding.player_chain_next)) 
	{
		print("Trying to adding an entity into player chain while it already is in chain!\n");
		return;
	}
	if (player_chain_head) player_chain_head.player_chain_prev = adding;
	adding.player_chain_next = player_chain_head;
	player_chain_head = adding;
};

// Remove entity from linked list
void(entity removing) player_chain_remove =
{
	if (removing == player_chain_head)
	{
		player_chain_head = removing.player_chain_next;
	}
	
	if (removing.player_chain_next) removing.player_chain_next.player_chain_prev = removing.player_chain_prev;
	if (removing.player_chain_prev) removing.player_chain_prev.player_chain_next = removing.player_chain_next;
	removing.player_chain_next = world;
	removing.player_chain_prev = world;
};

// ---------------------------------------------------------------------------
// GoldSrc useType constants.
//
// These live here rather than in sv_doors.qc (where the trigger suite that
// consumes them starts) because sv_breakable.qc compiles well before that and
// needs to name USE_TOGGLE when it fires its chain through SUB_UseTargets.
//
// NOTE these are NOT the same numbering as a mapper's `triggerstate` key --
// Sven transposes 2 and 3.  Always convert with
// GoldSrc_TriggerStateToUseType() (sv_triggers.qc); never assign a raw
// triggerstate value into one of these.
// ---------------------------------------------------------------------------
const float USE_OFF    = 0;
const float USE_ON     = 1;
const float USE_SET    = 2;
const float USE_TOGGLE = 3;

// USE_UNSET is NOT a GoldSrc value.  It exists because USE_OFF is 0, and 0 is
// also what a QC global reads before anyone assigns it -- so "the caller wants
// Off" and "the caller never said" were the same bit pattern, and
// Trigger_UseTargets (sv_doors.qc) resolved the ambiguity in favour of the
// latter by rewriting 0 to USE_TOGGLE.  Net effect: EVERY explicit Off in the
// mod was silently promoted to Toggle at the last dispatch hop.
//
// The visible casualty was th_ep1_00's intro.  Its `roadratmngr` multi_manager
// says `"pickup" "0#0"` (Off at t=0) and `"pickup#1" "8#1"` (On at t=8) to stop
// the truck while a headcrab crosses the road.  MM_ValueUseType
// (sv_multi_manager.qc:104-121) decoded both correctly; the Off then arrived at
// func_tracktrain_use as USE_TOGGLE, and the measured log line quoted in
// sv_func_tracktrain.qc says exactly that -- `useType=3`.
//
// -1 is chosen so the value is outside the GoldSrc range: every `== USE_OFF`
// test in the tree now means what it says.
//
// THE `sub_use_type ? sub_use_type : USE_TOGGLE` IDIOM IS STILL WRONG AND MUST
// BE CONVERTED EVERYWHERE.  Be clear about why, because it looks harmless: on
// USE_UNSET (-1) the ternary takes the truthy branch and passes -1 along, which
// Trigger_UseTargets then normalises back to USE_TOGGLE -- so the *unset* case
// still lands correctly and hides the problem.  The case it gets wrong is the
// one that matters: an explicit USE_OFF is 0, which is FALSY, so the ternary
// throws it away and substitutes USE_TOGGLE exactly as before.  Write
// `(sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type` instead.
const float USE_UNSET  = -1;

// ---------------------------------------------------------------------------
//  `light` — the two halves that need the USE_* constants above.
//  Forward-declared beside the light fields further up this file.
// ---------------------------------------------------------------------------
// useType pass-through global — declared authoritatively in sv_doors.qc:78.
// Re-declared here for the same reason sv_triggers.qc and sv_th_entities.qc do
// it: QC accepts identical re-decls, and this file compiles first.
float sub_use_type;

// Apply the current on/off state to the lightmap via lightstyle().
// "m" (109) = full bright (BSP-baked level); "a" (97) = dark.
// Lights without a switchable style index are no-ops here.
void() Light_ApplyState =
{
	if (self.style <= 0) return;
	if (self.light_state)
	{
		// THE PATTERN IS THE "ON" APPEARANCE, not full-bright.  CLight::Spawn:
		//     if (FBitSet(pev->spawnflags, SF_LIGHT_START_OFF))
		//         LIGHT_STYLE(m_iStyle, "a");
		//     else if (m_iszPattern)
		//         LIGHT_STYLE(m_iStyle, (char *)STRING(m_iszPattern));
		//     else
		//         LIGHT_STYLE(m_iStyle, "m");
		//                                   (halflife/dlls/lights.cpp:96-101)
		// A custom style index plus a `pattern` key is how GoldSrc authors a
		// flashing or pulsing SWITCHABLE lamp.  th_escape's start button is
		// style 70 with pattern "aaaaaaaazzzzzzzz" — eight frames dark, eight
		// bright, i.e. a slow yellow blink — and forcing "m" here is exactly why
		// it came up as a solid lamp instead.
		if (self.pattern && self.pattern != "")
			lightstyle(self.style, self.pattern);
		else
			lightstyle(self.style, "m");
	}
	else
		lightstyle(self.style, "a");
};

// .use callback — fires when something targets this light.
//
// KNOWN DIVERGENCE, kept deliberately: Half-Life gates all of this on
// `m_iStyle >= 32` (lights.cpp:94, :112), leaving styles 1..31 — the BSP
// compiler's own baked animation slots — alone.  This tree gates on `style > 0`
// instead, which also drives those.  Narrowing it to HL's rule would stop
// switchable lights on styles 1..31 responding at all, and native maps here may
// rely on them, so the wider gate stays until that is measured.
void() Light_Use =
{
	if (self.style <= 0) return;

	// CBaseToggle::ShouldToggle (applied at lights.cpp:114): an explicit ON to a
	// lamp already on, or an explicit OFF to one already off, is a no-op.  Only
	// TOGGLE/SET actually flip unconditionally.  Without this every fire flipped,
	// so th_escape's startbutt_ms_mm — which fires its lights with useType 1 (On)
	// — would turn one OFF whenever it happened to already be lit.
	float ut = sub_use_type;
	if (ut != USE_TOGGLE && ut != USE_SET && ut != USE_UNSET)
	{
		if (self.light_state && ut == USE_ON)   return;
		if (!self.light_state && ut == USE_OFF) return;
	}

	// HL flips unconditionally once ShouldToggle has passed — which lands on the
	// right state for an explicit ON/OFF precisely because the guard above has
	// already rejected the cases where a flip would be wrong.
	self.light_state = self.light_state ? 0 : 1;
	Light_ApplyState();
};

// ---------------------------------------------------------------------------
// GoldSrc game_text keys.
//
// Declared here (compile position 15) because the ED_ParseUnknownEpair hook
// that harvests some of them lives in sv_multi_manager.qc at position 99.
//
// `effect`, `x` and `y` are NOT in this list on purpose — see the harvest
// block in sv_multi_manager.qc.  `effect` cannot be a field name at all (it
// collides with the effect() builtin), and x/y are too generic to claim.
// Those three arrive as gt_effect / gt_x / gt_y below.
//
// Also not here, because they already bind to existing fields:
//   color     -> engine .vector color (sv_defs.qc)
//   holdtime  -> sv_env_hud.qc
//   fadein / fadeout -> sv_ambient_generic.qc
// ---------------------------------------------------------------------------
// scripted_sequence / scripted_sentence's speaker key, here for the same reason
// the game_text keys are: ED_ParseUnknownEpair (sv_multi_manager.qc, position
// 112) writes it, and sv_scripted.qc - where the rest of the m_isz* keys live -
// compiles at 208.  Lowercase so the case-folding fallback binds Hammer's
// "m_iszEntity" too; scripted_sentence's bare "entity" spelling is harvested by
// hand in that same hook, since `entity` cannot be a QC field name.
.string m_iszentity;    // monster to claim/speak: a targetname, or a classname

// Sven Co-op's `weaponbox` — a container whose keyvalues ARE its contents, one
// key per ammo pool.  Declared here for the same reason as the game_text keys:
// ED_ParseUnknownEpair harvests them and lives at compile position 112, while
// the class that reads them (sv_goldsrc_ammo.qc) is at 228.
//
// Deliberately NOT named after the BSP keys.  A `.float buckshot` or `.float
// uranium` would be claiming very generic words globally in a single-namespace
// language, and `tripmine`/`Snarks` would sit next to the real .ammo_tripmine /
// .ammo_snark fields waiting to be confused with them.  The wbox_ prefix keeps
// the mapping explicit and the collision surface at zero.
.float wbox_9mm;
.float wbox_357;
.float wbox_buckshot;
.float wbox_bolts;
.float wbox_556;
.float wbox_argren;
.float wbox_rockets;
.float wbox_uranium;
.float wbox_762;         // the BSP key is "m40a1" — Sven names it after the rifle
.float wbox_spore;
.float wbox_handgrenade;
.float wbox_satchel;
.float wbox_tripmine;
.float wbox_snarks;

// func_breakable / func_pushable "Spawn On Break": an index into the Sven FGD's
// 39-entry pickup table, dispatched by Breakable_SpawnObject.  Declared HERE
// rather than beside the rest of the breakable keys in sv_func_pushable.qc
// (position 151) because sv_breakable.qc reads it at position 28 - functions
// can be forward-declared in QC, fields cannot.
// .float, not .string: the FGD types it as choices, so the engine converts the
// "17" in the entity lump to 17 and the dispatch compares numerically.
.float spawnobject;

// func_breakable / func_pushable "Explode Magnitude (0=none)".  Same reason as
// spawnobject for living here: sv_breakable.qc (position 28) fires the explosion
// and sv_func_pushable.qc (position 151) is where the rest of the key block sits.
//
// HL stores it in pev->impulse via CBreakable::KeyValue (func_break.cpp:111) and
// reads it back through ExplosionMagnitude() (func_break.h:50); Explodable() is
// simply `> 0`, which is also the FGD default, so an unset brush never explodes.
//
// NOT to be confused with `ExplodeDamage`, which three hl_c05_a1 breakables set.
// That key appears in no FGD, no Sven manual page and nowhere in the HL SDK, so
// Sven ignores it too - honouring it here would be a divergence AWAY from the
// reference, not toward it.  Left unbound deliberately.
.float explodemagnitude;

// ---------------------------------------------------------------------------
//  Sven Co-op's InventoryRules baseclass (sven-coop.fgd:424-461).
//
//  Declared HERE and not in server/sv_item_inventory.qc (position 265), which
//  is where the rest of the inventory lives, because the entities that HONOUR
//  these keys all compile earlier: sv_doors.qc (185), sv_trigger_once_multi.qc
//  (193), sv_buttons.qc (215), sv_trigger_hurt.qc (221),
//  sv_trigger_changelevel.qc (241).  QC forward-declares functions but not
//  fields — same constraint, and the same resolution, as `spawnobject` above.
//
//  Sven's own list of the classes that carry this block is func_button,
//  func_rot_button, func_door, func_door_rotating, func_tankcontrols,
//  func_traincontrols, func_water, trigger_changelevel, trigger_once,
//  trigger_hurt and trigger_multiple.
//
//  item_inventory reuses the first six spellings for its OWN collect filters
//  (the FGD labels them "Collect: ..." there and "Inventory: ..." here, but
//  they are the same key names and the same meaning), so those are shared
//  rather than duplicated.
//
//  DECLARING THESE IS NOT COSMETIC.  ED_FindField runs before the
//  ED_ParseUnknownEpair hook, so until now every one of these keys fell
//  through to MM_AddSlot and allocated a junk mm_slot edict — and the three
//  bare `item_*` spellings fell into the game_player_equip harvest instead and
//  allocated a gpe_item child that nothing ever reaps.  Measured on th_escape:
//  36 permanently-leaked gpe_item edicts plus junk slots carrying
//  key="weight" value="16" and key="effect_damage" value="100.0".  Binding the
//  fields delivers the values AND stops the leak in one move.
// ---------------------------------------------------------------------------
.string item_name_required;         // activator must hold ALL of these
.string item_group_required;        // ...from these group(s)
.float  item_group_required_num;    // how many; 0 = every item that EXISTS in the group
.string item_name_canthave;         // activator must hold NONE of these
.string item_group_canthave;        // ...from these group(s)
.float  item_group_canthave_num;    // how many fails it; 0 = not even one
.string target_on_fail;             // fired when the rules reject the activator

.float  pass_ignore_use_triggers;   // suppress the matched items' target_on_use
.string pass_drop_item_name;        // on pass: force-drop these
.string pass_drop_item_group;
.float  pass_ignore_drop_triggers;
.string pass_return_item_name;      // on pass: send these home
.string pass_return_item_group;
.float  pass_ignore_return_triggers;
.string pass_destroy_item_name;     // on pass: destroy these  <- th_escape's drop-off pads
.string pass_destroy_item_group;
.float  pass_ignore_destroy_triggers;

// Why the holder is losing their inventory.  Passed to Inv_DropAll
// (sv_item_inventory.qc), and declared HERE because PlayerKilled is in
// sv_weapons.qc at position 45 — it can forward-declare the function but not
// these values.
//
// The two keep flags do not compose the way they read: holder_keep_on_respawn
// cannot save an item holder_keep_on_death already dropped, because the death
// comes first.  Surviving a full death -> respawn cycle needs both set.
const float INV_LEAVE_DEATH   = 0;   // honour the item's holder_keep_on_death
const float INV_LEAVE_RESPAWN = 1;   // honour the item's holder_keep_on_respawn
const float INV_LEAVE_GONE    = 2;   // holder is disconnecting; nothing stays

// `acceleration` is a SHARED BSP key spelling: trigger_camera reads it as its
// units/sec^2 dolly ramp, and func_trackvehicle reads it as the 1..10 engine
// responsiveness dial from Sven's func_trackvehicle.as.  Same name, same type,
// different classes — so one declaration, not two.
//
// A map script's override for the player model.  Empty means "use the team /
// model_index table", which is every map but one.  Set by th_escape's
// StartCharacters stand-in (server/sv_mapscript_thescape.qc) to one of the
// sixteen They Hunger character models, and read by PlayerApplyModel
// (sv_player.qc) — declared here because those two files are 63 apart in the
// compile order and neither can see the other's fields.
//
// Cleared on disconnect, NOT on respawn: the character you were assigned is
// yours for the map, and th_escape respawns players three times in its own
// ending sequence alone.
.string player_model_override;

// It used to live in sv_trigger_camera.qc, which compiles at position 433.
// sv_func_trackvehicle.qc has to sit immediately after sv_func_tracktrain.qc
// (position 255) because it inherits that file's TT_* constants and .tt_*
// FIELDS, and QC forward-declares functions but not fields — so the camera's
// declaration was 177 files too late to be visible.  Moving it up is the only
// resolution that keeps both classes reading the same bound key.
.float  acceleration;

.float  gt_effect;      // 0 fade in/out, 1 credits, 2 typewriter
.float  gt_x;           // 0..1 screen fraction, -1 = centre
.float  gt_y;
.float  channel;        // 1..4; HL keeps each channel independent
.vector color2;         // secondary colour (effects 1 and 2)
.float  fxtime;         // per-character time for the typewriter effect
// Re-declared from sv_env_hud.qc (position 112) so files that compile earlier
// can read it.  Identical re-decls share storage in QC.
.float  holdtime;

// ---------------------------------------------------------------------------
// game_player_equip item list.
//
// The mapper writes raw keyvalues whose KEY is a classname to give and whose
// VALUE is a quantity ("weapon_crowbar" "1").  Those can never be QC fields —
// a `.string weapon_crowbar` would collide with the weapon_crowbar() spawn
// function — so ED_ParseUnknownEpair harvests them onto a chain of child
// entities hanging off the game_player_equip.
// ---------------------------------------------------------------------------
.entity gpe_first_item;   // on the game_player_equip: head of the item chain
.entity gpe_next_item;    // on each gpe_item: next in chain
// netname holds the classname to give, count holds the quantity.

// ---------------------------------------------------------------------------
// trigger_createentity's harvested child keys (server/sv_trigger_createentity.qc).
//
// Same shape and same reason as the game_player_equip chain above: the mapper
// writes an arbitrary set of '-'-prefixed keyvalues ("-model" "*158") that are
// meant to be replayed onto a CHILD entity, so there is no fixed key set to
// declare and ED_ParseUnknownEpair has to harvest them onto a chain.
//
// The chain itself REUSES gpe_first_item / gpe_next_item rather than growing a
// second pair of link fields — a trigger_createentity and a game_player_equip
// are never the same edict, and a census of all 121 corpus maps finds a
// '-'-prefixed key on exactly two classnames (trigger_createentity and
// fallguys' trigger_create_ents), neither of which hands out equipment.  Only
// the key/value payload needs its own fields, and it needs BOTH as strings —
// the gpe node's `count` is a float.
//
// Declared here rather than in sv_trigger_createentity.qc because the harvest
// happens in server/sv_multi_manager.qc, which compiles far earlier, and QC
// forward-declares functions but not FIELDS.
// ---------------------------------------------------------------------------
.string ce_child_key;     // on each ce_key node: the key with its '-' stripped
.string ce_child_value;   // on each ce_key node: the value, verbatim

// Shared by func_vehicle (track width, for ground-follow roll sampling) and
// env_laser (Sven's beam-width key is `width`, not env_beam's `BoltWidth`).
// Declared here because sv_env_laser.qc compiles at 118 and sv_func_vehicle.qc
// at 132 — the laser needs it first.
.float  width;

// ---------------------------------------------------------------------------
// the `sound` map key, which CANNOT be a field
// ---------------------------------------------------------------------------
// `sound` is builtin #8 (ftedefs/fteextensions.qc:1693), and QuakeC puts fields
// and functions in ONE namespace — so `.float sound;` does not merely shadow the
// builtin, it makes every sound() call in the tree a compile error.  Exactly the
// collision sv_goldsrc_ammo.qc:504 documents for `ammo_357`, and it has the same
// shape of answer: the key cannot bind directly, so something else has to carry
// it.  There is no spawnfunc_-style prefix for a KEY, so the value is harvested
// in ED_ParseUnknownEpair (sv_multi_manager.qc) into the field below.
//
// A STRING, not a float, because the corpus disagrees about the type: 8 uses on
// monster_tentacle are the integer impact-material selector (tentacle.cpp:338-342
// reads it with atoi), while 37 on Sven's own trigger_qualifier and
// trigger_hudsprite are .ogg PATHS.  One field serves both; each reader converts.
//
// Declared here rather than beside its one consumer because the harvest happens
// in sv_multi_manager.qc at :177 and mon_tentacle.qc compiles at :293 — QC
// forward-declares functions but not fields, the same reason the ce_child_* pair
// above lives here.
.string hl_soundkey;
