// put custom server-only globals and fields here
#pragma target fte_5768

const float FL_JUMPRELEASED = 4096;

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

void() light =
{
	remove(self);
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
.float team_menu_request_serial;
.float deaths;

// Round timer — per-player field synced from global each frame
.float round_timer_remaining;

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

// Per-player stats for map timer, round number, max rounds
.float sv_maptimeleft;
.float sv_roundnum;
.float sv_maxrounds;

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

// Fall damage tracking
.float fall_velocity;       // current downward speed while airborne
.float was_onground;        // FL_ONGROUND state from previous frame

// Forward declarations
void(entity player) PlayerRefreshScoreboardInfo;  // sv_player.qc
void() RoundStart;                                 // sv_main.qc

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

