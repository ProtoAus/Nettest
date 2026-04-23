//Various globals that are used in this FTEQW example are defined here, they are not used by the engine itself

//#pragma warning disable Q302
#pragma target fte_5768

.vector view_ofs;    /* eye position relative to entity origin */
.vector movedir;     /* push direction for trigger_push */
.float  spawnflags;  /* trigger/entity spawn flags (not in CSQC defs) */

// Standard QW player fields not present in cl_defs.qc
.float  weapon;
.float  weaponframe;
// attack_finished moved to shared/sh_weapons.qc

vector cursor_pos; /* Current mouse cursor position, updated in csqc_inputevent */
float g_width, g_height; /* Globals for screen width and height */

// Set by CSQC_PredictPickupWeapon when it plays the pickup sound
// locally.  The server's pickup-sound event handler reads this latch
// and only plays when WE are the excluded picker AND predict didn't
// already fire — robust against event/update processing order within
// a single snapshot.  Previous design (latch in event, gate in
// entity update) silently dropped the sound whenever the event
// happened to arrive AFTER the entity update in the same packet.
float cl_local_predict_sound_time;

//Menu stuff
float in_menu; //what menu are we in
float time_in_menu;

// for keybinding
float active_bind_index;
float menu_click_held;

const float MENU_NONE = 0;
const float MENU_MAIN = 1;
const float MENU_JOIN = 2;
const float MENU_SETTINGS = 4;
const float MENU_BUY = 8;
const float MENU_HOST = 16;
const float MENU_PREGAME = 32;
const float MENU_POSTGAME = 64;

float in_input_box;
float input_cursor;

vector campos;
vector camang;

float hud_font;
float hud_font_regular;
float hud_font_mono;     // monospace for scrolling numeric strips (debug graphs)

// Spectator freecam input (captured in cl_player.qc, used in cl_spectate.qc)
float spec_freecam_fwd;
float spec_freecam_side;

entity localplayer;
entity predicted_player;

// Declared here so any file compiled after cl_customdefs.qc can read
// them (cl_cameras.qc's sniper sway needs them, and they're still
// *written* from cl_player.qc).
float csqc_prediction_valid;    // TRUE once predicted_player can drive view
float csqc_live_buttons;        // live button bits captured by +cmd aliases

// Shared CSQC weapon-prediction bookkeeping.
float csqc_pred_sequence;
float csqc_weapon_pending_ack_sequence;

// Persistent CSQC viewmodel entity — driven by predicted_player
entity csqc_viewmodel_ent;

// Current "logical time" for weapon prediction.
// Set to cltime for live prediction, pred_cmd_timestamp[slot] for replay.
float csqc_pred_time;

// Time the last predicted local weapon sound was played, used to suppress
// the delayed server-side echo in CSQC_Event_Sound.
float csqc_last_predicted_weapon_sound_time;
float csqc_last_predicted_auto_sound_time;

// FTE CSQC time globals not present in the stock cl_defs.qc. serverprevtime
// ticks forward only when a new server snapshot is received, making it the
// canonical snapshot-arrival trigger (independent of the cltime-vs-time
// epoch offset that breaks naive `cltime - time` dt calculations).
// clframetime is real-time frame delta (for fps measurement in the net_graph).
float serverprevtime;
float clframetime;

// Forward-declared here so shared/sh_weapon_logic.qc (which compiles
// before client/cl_player.qc) can read it in CSQC_SendHitclaim. The
// actual use site is CSQC_PlayerVisual_Update; see cl_player.qc for the
// full set of vis_* fields.
.float vis_owner_entnum;

vector() readvector =
{
	vector r = '0 0 0';
	r_x = readcoord();
	r_y = readcoord();
	r_z = readcoord();
	return r;
};
