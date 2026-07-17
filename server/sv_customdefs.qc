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
.float  carry_grab_time;     // on prop: time the grab started (drives the pull-in lerp window)
.vector carry_grab_origin;   // on prop: prop.origin at grab time (lerp start position)
.vector carry_grab_angles;   // on prop: prop.angles at grab time (lerp start orientation)
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
.vector car_scrape_normal;   // on car: latched wall normal while grinding along BSP (0 0 0 = not grinding)

// Unified phys-object config (po_*) — set per object BEFORE PhysObj_Setup so the
// shared ODE core + the shared think branch to the right per-object behavior.
// Barrel / can / cabinet / weapon-drop all route through one setup + one FX path.
.float  po_is_phys;        // 1 on any unified phys object (helper / wake gate)
.float  po_fx_enabled;     // run contact-FX detection (impact/slide/scrape/smoke/spark)
.float  po_fx_soundset;    // FX sound set id (0 = metal_box_*)
.float  po_material;       // resolved prop-material index (PropMat_For, sh_propmaterials.qc); -1 = none (cvar fallback)
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

entity activator;       // entity that triggered the current use/touch
float sv_use_is_player_direct;  // TRUE only during SV_PlayerTryUse

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

// Apply the current on/off state to the lightmap via lightstyle().
// "m" (109) = full bright (BSP-baked level); "a" (97) = dark.
// Lights without a switchable style index are no-ops here.
void() Light_ApplyState =
{
	if (self.style <= 0) return;
	if (self.light_state)
		lightstyle(self.style, "m");
	else
		lightstyle(self.style, "a");
};

// .use callback — fires when something targets this light.  Each
// fire flips the on/off state.  Buttons re-fire on auto-return so
// non-toggle buttons produce a momentary-pulse effect; TOGGLE
// buttons stay pressed and the light keeps the new state.
void() Light_Use =
{
	if (self.style <= 0) return;
	self.light_state = self.light_state ? 0 : 1;
	Light_ApplyState();
};

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

// Per-player stats for gamemode system
.float sv_round_phase;
.float sv_freeze_timeleft;
.float sv_gamemode;
.float sv_winning_team;

// Death tracking
.float is_dead;             // TRUE if player died this round
.float death_time;          // server time when player died (0 = alive, -1 = past delay)
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
.float money_started;  // 1 once mp_cashstart granted (so first team-join inits once)
.float buyzone_time;   // last server time the player overlapped an allowed func_buyzone
.float sv_in_buyzone;  // clientstat mirror (STAT_IN_BUYZONE) — 1 when the player may buy
.float sv_can_plant_c4; // clientstat mirror (STAT_CAN_PLANT) — 1 when the C4 carrier may plant here
.float sv_bomb_planted; // clientstat mirror (STAT_BOMB_PLANTED) — 1 while a planted_c4 is live in Defuse

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
