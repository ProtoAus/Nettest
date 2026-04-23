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
const float WEP_GLOCK            = 21;
const float WEP_G3SG1            = 22;
const float WEP_HLSMG            = 23;
const float WEP_HLRPG            = 24;
const float WEP_HLGRENADE        = 25;
const float WEP_HLGLOCK          = 26;
const float WEP_HLEGON           = 27;
const float WEP_CSUSP            = 28;

// --- Slot IDs ---
const float SLOT_NONE      = 0;
const float SLOT_PRIMARY   = 1;
const float SLOT_SECONDARY = 2;
const float SLOT_MELEE     = 3;
const float SLOT_UTILITY   = 4;

// --- Weapon impulses ---
const float WEAPON_IMPULSE_PRIMARY   = 1;
const float WEAPON_IMPULSE_SECONDARY = 2;
const float WEAPON_IMPULSE_MELEE     = 3;
const float WEAPON_IMPULSE_DROP      = 5;
const float WEAPON_IMPULSE_RELOAD    = 6;
const float WEAPON_IMPULSE_SPECIAL   = 7;
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
const float CSQC_EVENT_POINTSOUND = 4; // positioned sound (respects dimension masking)
const float CSQC_EVENT_DEBUG_IMPACT = 5; // debug: server bullet hit position
const float CSQC_EVENT_ROUND_CLEANUP = 6; // wipe all client-side debris (bulletholes, shells, mags)
const float CSQC_EVENT_DAMAGE_FLASH = 7; // pain flash HUD element (sent only to victim)
const float CSQC_EVENT_HITMARKER = 8;   // hitmarker confirmation (sent only to attacker)
const float CSQC_EVENT_BRUSH_DESTROY = 9; // remove bullet holes on a destroyed brush entity
const float CSQC_EVENT_SERVER_HITBOXES = 10; // debug: server-side hitbox state snapshot
const float CSQC_EVENT_GLASS_GIBS = 11;     // glass breakable gib spawn (client-side for submodel selection)
const float CSQC_EVENT_PLAYER_GIBS = 12;    // player gibbed by overkill damage — flesh chunks + blood
const float CSQC_EVENT_DEBRIS_GIBS = 13;    // non-glass breakable debris (concrete/wood/metal/etc.) — purely cosmetic CSQC entities
const float CSQC_EVENT_KILLFEED    = 14;    // kill-feed entry (attacker slot, victim slot, cause, weapon, headshot)
const float CSQC_EVENT_WEAPON_PICKUP_SOUND = 15;  // pickup confirm sound routed to all PVS clients EXCEPT the pickup-er (who already played it via CSQC prediction)
const float CSQC_EVENT_BREAKABLE_IMPACT_SOUND = 16;  // breakable material thump routed to PVS clients except the attacker (who predicted it locally in CSQC_BulletImpact)
const float CSQC_EVENT_BREAKABLE_BREAK_SOUND = 17;   // breakable destruction sound routed to PVS clients except the attacker (who predicted it via replicated brush_health)
const float CSQC_EVENT_FOOTSTEP_SOUND = 18;          // player footstep, routed to PVS clients except the stepper (whose CSQC pmove plays it via localsound as the predicted step fires)
const float CSQC_EVENT_DEATH_DROP = 19;              // visual fake-drop scatter for the dying local player; server-authoritative origin/velocity so the fake matches the server's rng scatter until weapon_become_solid wires the real SendEntity at +0.7s

// --- Kill-feed causes (byte payload of CSQC_EVENT_KILLFEED) ---
const float KILL_CAUSE_WEAPON       = 0;
const float KILL_CAUSE_FALL         = 1;
const float KILL_CAUSE_SUICIDE      = 2;
const float KILL_CAUSE_FRIENDLYFIRE = 3;
const float KILLFEED_NO_ATTACKER    = 255;

// Should the HUD crosshair render for this weapon?  Melees, utility
// items, and scope-capable snipers all hide it.  Must stay in sync with
// the `show_crosshair` parameter passed to W_SetCrosshairProfile in
// each weapon's equip function.  Used by cl_crosshair.qc so visibility
// tracks the predicted weapon switch instantly — server still networks
// STAT_CROSSHAIR_DISABLED but the client no longer reads it, avoiding
// the stale-crosshair-after-switch stutter at high ping.
float(float wep_id) Weapon_HasCrosshair =
{
    if (wep_id == WEP_NONE)      return 0;
    if (wep_id == WEP_KNIFE)     return 0;
    if (wep_id == WEP_WRENCH)    return 0;
    if (wep_id == WEP_HLCROWBAR) return 0;
    if (wep_id == WEP_HLGRENADE) return 0;
    // Snipers — use scope, no crosshair.
    if (wep_id == WEP_CSAWP)     return 0;
    if (wep_id == WEP_SCOUT)     return 0;
    if (wep_id == WEP_G3SG1)     return 0;
    if (wep_id == WEP_CROSSBOW)  return 0;
    return 1;
};

// Can this weapon enter a scoped (zoomstage > 0) state via its alt-fire?
// Used by the HUD to suppress the scope overlay after a weapon switch
// leaves the server still reporting zoomstage > 0 (the real state catches
// up a moment later under high ping).  If a non-scope weapon is equipped
// we treat zoomstage as 0 for HUD gating, regardless of the stat.
float(float wep_id) Weapon_HasScope =
{
    if (wep_id == WEP_CSAWP)    return 1;
    if (wep_id == WEP_SCOUT)    return 1;
    if (wep_id == WEP_G3SG1)    return 1;
    if (wep_id == WEP_CROSSBOW) return 1;
    return 0;
};

// Short display name for a weapon ID — used by the kill feed and (potentially)
// future UI.  Matches the labels in menu/m_createserver.qc loadout arrays.
string(float wep_id) Weapon_DisplayName =
{
    if (wep_id == WEP_AK47)            return "AK47";
    if (wep_id == WEP_M4A1)            return "M4A1";
    if (wep_id == WEP_CSAWP)           return "AWP";
    if (wep_id == WEP_G3SG1)           return "G3SG1";
    if (wep_id == WEP_CSM3)            return "M3";
    if (wep_id == WEP_CSMP5)           return "MP5";
    if (wep_id == WEP_DOD98K)          return "K98";
    if (wep_id == WEP_FLAKSHOTGUN)     return "Flak Shotgun";
    if (wep_id == WEP_GAUSS)           return "Gauss";
    if (wep_id == WEP_GRENADELAUNCHER) return "Grenade Launcher";
    if (wep_id == WEP_CROSSBOW)        return "Crossbow";
    if (wep_id == WEP_HLEGON)          return "Egon";
    if (wep_id == WEP_HLRPG)           return "RPG";
    if (wep_id == WEP_HLSHOTGUN)       return "HL Shotgun";
    if (wep_id == WEP_HLSMG)           return "HL SMG";
    if (wep_id == WEP_M249)            return "M249";
    if (wep_id == WEP_REBAR)           return "Rebar";
    if (wep_id == WEP_SCOUT)           return "Scout";
    if (wep_id == WEP_CSUSP)           return "USP";
    if (wep_id == WEP_DEAGLE)          return "Desert Eagle";
    if (wep_id == WEP_GLOCK)           return "Glock";
    if (wep_id == WEP_357)             return ".357";
    if (wep_id == WEP_HLGLOCK)         return "HL Glock";
    if (wep_id == WEP_PISTOL)          return "9mm";
    if (wep_id == WEP_WRENCH)          return "Wrench";
    if (wep_id == WEP_KNIFE)           return "Knife";
    if (wep_id == WEP_HLCROWBAR)       return "Crowbar";
    if (wep_id == WEP_HLGRENADE)       return "Grenade";
    return "?";
};

// Per-weapon walk/run-speed multiplier applied to mv_maxspeed and
// mv_shiftspeed in PM_PlayerMoveStep.  Heavier weapons feel slower in
// both run and shift-walk modes.  1.0 = full default speed (melee);
// 0.926 ≈ 250 qu/s when sv_maxspeed is the mod default of 270.
// Predicted automatically — both SSQC and CSQC read self.weapon.
float(float wep_id) Weapon_SpeedFactor =
{
    // melee — no weight penalty
    if (wep_id == WEP_KNIFE)           return 1.0;
    if (wep_id == WEP_WRENCH)          return 1.0;
    if (wep_id == WEP_HLCROWBAR)       return 1.0;
    if (wep_id == WEP_HLGRENADE)       return 1.0;
    if (wep_id == WEP_REBAR)           return 1.0;

    // light pistols
    if (wep_id == WEP_PISTOL)          return 0.985;
    if (wep_id == WEP_HLGLOCK)         return 0.985;
    if (wep_id == WEP_GLOCK)           return 0.985;
    if (wep_id == WEP_CSUSP)           return 0.985;

    // heavy pistols / crossbow
    if (wep_id == WEP_DEAGLE)          return 0.97;
    if (wep_id == WEP_357)             return 0.97;
    if (wep_id == WEP_CROSSBOW)        return 0.97;

    // SMGs
    if (wep_id == WEP_CSMP5)           return 0.96;
    if (wep_id == WEP_HLSMG)           return 0.96;

    // assault rifles / shotguns / mid-weight long arms
    if (wep_id == WEP_AK47)            return 0.945;
    if (wep_id == WEP_M4A1)            return 0.945;
    if (wep_id == WEP_CSM3)            return 0.945;
    if (wep_id == WEP_HLSHOTGUN)       return 0.945;
    if (wep_id == WEP_FLAKSHOTGUN)     return 0.945;
    if (wep_id == WEP_SCOUT)           return 0.945;
    if (wep_id == WEP_DOD98K)          return 0.945;
    if (wep_id == WEP_GAUSS)           return 0.945;
    if (wep_id == WEP_HLEGON)          return 0.945;
    if (wep_id == WEP_GRENADELAUNCHER) return 0.945;
    if (wep_id == WEP_HLRPG)           return 0.945;

    // heavy — ~250 qu/s at default sv_maxspeed 270
    if (wep_id == WEP_CSAWP)           return 0.926;
    if (wep_id == WEP_G3SG1)           return 0.926;
    if (wep_id == WEP_M249)            return 0.926;

    return 1.0;  // empty hands / unknown
};

// --- Bullet impact material codes (sent in CSQC_EVENT_IMPACT) ---
// Used by CSQC to pick the right particle effect per surface.
// Anything > IMPACT_MAT_DEFAULT is "no decal" (player body or breakable
// brush — both move/destroy and bullet holes would orphan).
const float IMPACT_MAT_DEFAULT      = 0;   // static wall/concrete (orange dust + decal)
const float IMPACT_MAT_FLESH        = 1;   // routine flesh hit (cloud only, no sparks)
const float IMPACT_MAT_METAL        = 2;   // BREAKABLE_METAL/MACHINE/CIRCUIT (sparks)
const float IMPACT_MAT_GLASS        = 3;   // BREAKABLE_GLASS (clear shards)
const float IMPACT_MAT_WOOD         = 4;   // BREAKABLE_WOOD (brown debris)
const float IMPACT_MAT_FLESH_LETHAL = 5;   // killing blow OR headshot (cloud + spark splash)

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
.float slot_utility;

.void() slot_primary_equip;
.void() slot_secondary_equip;
.void() slot_melee_equip;
.void() slot_utility_equip;

.void() slot_primary_drop;
.void() slot_secondary_drop;
.void() slot_melee_drop;
.void() slot_utility_drop;

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

// --- CSQC prediction function pointers (set by per-weapon CSQC equip) ---
.void() csqc_predict_cmd;             // per-frame weapon logic (fire, sounds, etc.)
.void() csqc_predict_reload;          // reload initiation
.void() csqc_drop_clear;              // zero this weapon's ammo fields on drop
.float(float elapsed) csqc_display_frame;  // returns viewmodel animation frame

// --- Weapon data fields (set during equip, used by HUD/viewmodel/drop) ---
.string weapon_viewmodel;              // view model path
.string weapon_worldmodel;             // world model path
.string weapon_deploy_sound;           // deploy sound (empty string = none)
.float  weapon_uses_sequences;         // TRUE for GoldSrc-format MDLs (sequence-driven, not frame-driven)

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

// --- Player animation family constants ---
const float PANIM_NONE     = 0;
const float PANIM_ONEHAND  = 1;
const float PANIM_CARBINE  = 2;
const float PANIM_RIFLE    = 3;
const float PANIM_MP5      = 4;
const float PANIM_SHOTGUN  = 5;
const float PANIM_PARA     = 6;
const float PANIM_KNIFE    = 7;
const float PANIM_GRENADE  = 8;
const float PANIM_AK47     = 9;

// Maps weapon ID to animation family for player model sequences.
float(float wep) W_GetPlayerAnimFamily =
{
    switch (wep)
    {
    case WEP_CSUSP:
    case WEP_DEAGLE:
    case WEP_PISTOL:
    case WEP_357:
    case WEP_HLGLOCK:
        return PANIM_ONEHAND;
    case WEP_AK47:
        return PANIM_AK47;
    case WEP_M4A1:
    case WEP_SCOUT:
    case WEP_DOD98K:
    case WEP_CROSSBOW:
    case WEP_GAUSS:
    case WEP_REBAR:
    case WEP_HLSMG:
    case WEP_HLRPG:
    case WEP_HLEGON:
        return PANIM_CARBINE;
    case WEP_G3SG1:
    case WEP_CSAWP:
        return PANIM_RIFLE;
    case WEP_CSMP5:
        return PANIM_MP5;
    case WEP_CSM3:
    case WEP_HLSHOTGUN:
    case WEP_FLAKSHOTGUN:
        return PANIM_SHOTGUN;
    case WEP_M249:
        return PANIM_PARA;
    case WEP_KNIFE:
    case WEP_WRENCH:
    case WEP_HLCROWBAR:
        return PANIM_KNIFE;
    case WEP_GRENADELAUNCHER:
    case WEP_HLGRENADE:
        return PANIM_GRENADE;
    case WEP_GLOCK:
        return PANIM_ONEHAND;
    default:
        return PANIM_ONEHAND;
    }
};

// Maps weapon ID to the p_*.mdl path for third-person weapon attachment.
string(float wep) W_GetPModelPath =
{
    switch (wep)
    {
    case WEP_AK47:   return "models/weapons/wpn_csak47/p_ak47.mdl";
    case WEP_CSAWP:  return "models/weapons/wpn_csawp/p_awp.mdl";
    case WEP_DEAGLE: return "models/weapons/wpn_csdeagle/p_deagle.mdl";
    case WEP_G3SG1:  return "models/weapons/wpn_csg3sg1/p_g3sg1.mdl";
    case WEP_GLOCK:  return "models/weapons/wpn_csglock/p_glock.mdl";
    case WEP_KNIFE:  return "models/weapons/wpn_csknife/p_knife.mdl";
    case WEP_CSM3:   return "models/weapons/wpn_csm3/p_m3.mdl";
    case WEP_M4A1:   return "models/weapons/wpn_csm4a1/p_m4a1.mdl";
    case WEP_M249:   return "models/weapons/wpn_csm249/p_m249.mdl";
    case WEP_CSMP5:  return "models/weapons/wpn_csmp5/p_mp5.mdl";
    case WEP_SCOUT:  return "models/weapons/wpn_csscout/p_scout.mdl";
    case WEP_DOD98K: return "models/weapons/wpn_dod98k/p_k98.mdl";
    case WEP_CSUSP:  return "models/weapons/wpn_csusp/p_usp.mdl";
    default:         return "";
    }
};

// Linear damage falloff from close_dmg at point-blank to min_dmg at `range`.
// Shared between SSQC (authoritative shot) and CSQC (predicted shot), so both
// sides agree on the damage dealt — critical for breakable-break prediction.
float(float dist, float close_dmg, float min_dmg, float range) W_LinearDamageFalloff =
{
    float t;
    if (range <= 0)
        return close_dmg;
    t = bound(0, dist / range, 1);
    return close_dmg + (min_dmg - close_dmg) * t;
};
