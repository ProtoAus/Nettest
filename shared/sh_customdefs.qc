//shared definitions

#define printf(x, ...) print(sprintf(x, __VA_ARGS__))

const float FL_DUCKING = 8192;
const float PM_CSQC_PROXY_VERSION = 1;
const float PM_CSQC_PROXY_SEND_STATE = 1;
const string PM_CSQC_PROXY_CLASSNAME = "pm_csqc_proxy";

// CSQC entity type IDs (first byte sent by SendEntity)
const float CSQC_ENT_PUSH_TRIGGER = 2;
const float CSQC_ENT_SOLID_BRUSH  = 5;

// trigger_push spawnflags
const float PUSH_ONCE     = 1;  // remove after first touch
const float PUSH_SILENT   = 2;  // no wind sound
const float PUSH_ADDITIVE = 4;  // add to velocity rather than replace
const float PUSH_TUNNEL   = 8;  // pull toward trigger centerline while pushing
const float PUSH_SOURCE   = 16; // boost along movedir up to speed, don't overwrite sideways

// Linked list fields for trigger chains
.entity push_next;
.entity tele_next;
.entity ladder_next;

// Generic movement/entity fields not declared in the engine-generated defs
.float speed;

// Trigger linked list heads (populated on server by spawn, on client by CSQC_Ent_Update)
entity push_trigger_list;
entity teleport_trigger_list;
entity ladder_trigger_list;

const float CSQC_ENT_LADDER_TRIGGER = 4;

// ---- trigger_push spawnflags already declared above ----

// trigger_teleport / info_teleport_destination
const float CSQC_ENT_TELEPORT_TRIGGER = 3;
const float TELEPORT_KEEPVEL          = 4;  // spawnflag: keep velocity through teleporter
const float TELEPORT_KEEPANGLE        = 8;  // spawnflag: keep current view angle (ignore dest angles)

// Per-teleport-trigger entity fields (cached destination, set at spawn time)
.vector tele_dest_origin;  // world-space destination position
.vector tele_dest_angles;  // destination view angles (zero = no snap)
.float  tele_resolved;     // TRUE once Teleport_FindDestination succeeded

// Per-player entity fields for teleport state
.float  pm_teleport_time;       // countdown guard: seconds remaining before player can re-teleport
.float  pm_ladder_detach_time;  // countdown guard: seconds remaining before player can re-grab a ladder
.float  pm_fuser2;              // CS 1.6 stamina: msec of landing fatigue remaining (0 = none)
.float  pm_step_time;           // seconds until next footstep sound fires


void() precache_everything =
{
	precache_sound("demon/dland2.wav");
	precache_model("models/testplayer.iqm");

	precache_sound("sounds/player/use.wav");
	precache_sound("sounds/player/step1.wav");
	precache_sound("sounds/player/step2.wav");
	precache_sound("sounds/player/step3.wav");
	precache_sound("sounds/player/step4.wav");
	precache_sound("sounds/player/ladder1.wav");
	precache_sound("sounds/player/ladder2.wav");
	precache_sound("sounds/player/ladder3.wav");
	precache_sound("sounds/player/ladder4.wav");
	precache_sound("sounds/player/waterstep1.wav");
	precache_sound("sounds/player/waterstep2.wav");
	precache_sound("sounds/player/waterstep3.wav");
	precache_sound("sounds/player/waterstep4.wav");
	precache_sound("sounds/player/waterstep5.wav");
	precache_sound("sounds/player/waterstep6.wav");
	precache_sound("sounds/player/waterstep7.wav");
	precache_sound("sounds/player/waterstep8.wav");
	precache_sound("sounds/player/waterstep9.wav");
	precache_sound("sounds/player/waterstep10.wav");
};
