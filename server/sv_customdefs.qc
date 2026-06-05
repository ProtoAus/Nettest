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

// Fall damage tracking
.float fall_velocity;       // current downward speed while airborne
.float was_onground;        // FL_ONGROUND state from previous frame

// Forward declarations
void(entity player) PlayerRefreshScoreboardInfo;  // sv_player.qc
void() RoundStart;                                 // sv_main.qc
// Drift-trace ring buffer (sv_player.qc).
void(float t_now, float msec, vector mv, float btn, float wep, vector org, vector vel) Drift_Append;
void(string label) Drift_Dump;

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
