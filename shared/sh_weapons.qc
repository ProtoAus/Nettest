// ============================================================
//  shared/sh_weapons.qc  -  Cross-weapon system constants & fields
//  Included by both sv_progs and cl_progs.
//
//  Per-weapon constants and ammo fields live in each weapon's
//  own file: shared/weapons/sh_wpn_*.qc
// ============================================================

// --- Weapon IDs ---
const float WEP_NONE   = 0;
const float WEP_DEAGLE = 1;
const float WEP_KNIFE  = 2;
const float WEP_AK47         = 3;
const float WEP_M4A1         = 4;
const float WEP_FLAKSHOTGUN  = 5;
const float WEP_PISTOL       = 6;
const float WEP_GAUSS            = 7;
const float WEP_CROSSBOW         = 8;
const float WEP_357              = 9;
const float WEP_DOD98K           = 10;
const float WEP_SCOUT            = 11;
const float WEP_GRENADELAUNCHER  = 12;
const float WEP_M249             = 13;
const float WEP_HLCROWBAR        = 14;
const float WEP_HLSHOTGUN        = 15;
const float WEP_CSM3             = 16;
const float WEP_CSMP5            = 17;
const float WEP_REBAR            = 18;
const float WEP_CSAWP            = 19;
const float WEP_WRENCH           = 20;

// --- Slot IDs ---
const float SLOT_NONE      = 0;
const float SLOT_PRIMARY   = 1;
const float SLOT_SECONDARY = 2;
const float SLOT_MELEE     = 3;

// --- Weapon impulses ---
const float WEAPON_IMPULSE_PRIMARY   = 1;
const float WEAPON_IMPULSE_SECONDARY = 2;
const float WEAPON_IMPULSE_MELEE     = 3;
const float WEAPON_IMPULSE_DROP      = 5;
const float WEAPON_IMPULSE_RELOAD    = 6;
const float WEAPON_IMPULSE_NEXT      = 12;
const float WEAPON_IMPULSE_PREV      = 13;
const float WEAPON_IMPULSE_LASTINV   = 14;

// --- Weapon slot groups (broader category used by some weapons) ---
const float WSG_MELEE = 3;

// --- Weapon animation states ---
const float WS_IDLE    = 0;
const float WS_DRAW    = 1;
const float WS_FIRE    = 2;
const float WS_RELOAD  = 3;
const float WS_SPECIAL = 4;   // alt-fire / stab / throw

// --- CSQC event IDs (server→client multicast) ---
const float CSQC_EVENT_IMPACT  = 1;   // bullet impact effect
const float CSQC_EVENT_SHELL   = 2;   // shell casing eject
const float CSQC_EVENT_MAGDROP = 3;   // magazine drop

// --- Shell/mag type IDs (sent in multicast events) ---
const float SHELL_9MM       = 0;
const float SHELL_RED       = 1;
const float SHELL_RIFLE     = 2;
const float SHELL_RIFLE_BIG = 3;
const float SHELL_SHOTGUN1  = 4;   // shotgunshell1.mdl (CS M3)
const float SHELL_SHOTGUN2  = 5;   // shotgunshell2.mdl (HL shotgun, flak shotgun)
const float MAG_PISTOL      = 6;
const float MAG_PISTOL_HL   = 7;
const float MAG_RIFLE       = 8;

// --- Brush entity types (sent via brush sync) ---
const float BRUSH_TYPE_STATIC = 0;
const float BRUSH_TYPE_DOOR   = 1;
const float BRUSH_TYPE_BUTTON = 2;

// --- Door/button state (shared between server and client) ---
const float MOVER_STATE_BOTTOM = 0;
const float MOVER_STATE_UP     = 1;
const float MOVER_STATE_TOP    = 2;
const float MOVER_STATE_DOWN   = 3;

// --- Player attack animation hints ---
const float PLAYER_ATTACKANIM_SHOT  = 1;
const float PLAYER_ATTACKANIM_MELEE = 2;

// --- Player weapon slot fields ---
.float slot_primary;
.float slot_secondary;
.float slot_melee;

.void() slot_primary_equip;
.void() slot_secondary_equip;
.void() slot_melee_equip;

.void() slot_primary_drop;
.void() slot_secondary_drop;
.void() slot_melee_drop;

// --- Current weapon state ---
.float attack_finished;       // debounce timestamp — shared for prediction
.float previous_weapon;
.float weaponstate;
.float wep_action_id;    // increments whenever a new weapon action starts
.float wep_nextframe;    // server-side: absolute server time of next frame tick
.float wep_anim_start;   // absolute time when the current animation began
.float zoomstage;        // scope zoom level: 0=unscoped, 1=zoom1, 2=zoom2
                         // sent through proxy as elapsed time; used by CSQC to
                         // compute the display frame via cltime - wep_anim_start

// --- Active weapon function pointers (set by equip, valid for current weapon) ---
.void() fire;
.void() reload;
.void() wepframe;
.void() altfire;              // secondary/alt-fire action
.void() altrelease;           // called when alt-fire button released
.void() shoot;                // raw attack trace (called by frame at the hit frame)
.void() special;              // weapon-specific action (throw, inspect, etc.)

// --- World weapon entity fields ---
.float weapon_slot;           // SLOT_* this pickup belongs to
.float weapon_slot_group;     // WSG_* broader category
.string weapon_name;          // display name
.float  weapon_draw_start_frame;
.float  weapon_player_attack_anim;  // PLAYER_ATTACKANIM_*
.void() weap_draw;            // equip function: sets fire/reload/wepframe/weaponmodel on player
.void() weap_drop_func;       // drop function: copies ammo from player to weapon_drop_target, sets up world ent
.void(entity) pickupcopy;     // copies ammo FROM this world ent TO receiver player
.void() equip;                // equip function pointer (alternative to weap_draw)
.void() drop;                 // drop function pointer
.void() spawnitem;            // world spawn function for this weapon type
