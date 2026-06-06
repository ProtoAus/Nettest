// ============================================================
//  shared/sh_weapons.qc  -  Cross-weapon system constants & fields
//  Included by both sv_progs and cl_progs.
//
//  Per-weapon constants and ammo fields live in each weapon's
//  own file: shared/weapons/sh_wpn_*.qc
// ============================================================

// Forward decl — implemented in sh_pmove.qc.  SSQC's progs.src
// includes every weapon file before sh_pmove (because sh_pmove uses
// per-weapon ammo fields), so the fire-block helper has to be
// declared here, in a header included earlier than any weapon file.
// Body uses pm_movetype + PM_MOVETYPE_NOCLIP which live in sh_pmove
// — those don't escape the function body so a plain forward decl is
// enough.
float() Weapon_SprintBlocksFire;
// Lower-pose fire gate — same compile-order story.  Body references
// grapple_rope_active (shared field, declared in sh_customdefs.qc
// which compiles before this header) and pm_on_ladder_cached
// (declared right next to pm_ladder_detach_time in sh_customdefs.qc).
float() Weapon_LowerBlocksFire;
// Same compile-order story for the ADS gate — sh_weapon_logic.qc
// compiles before sh_pmove.qc on SSQC, so the helper's body
// references (pm_movetype, PM_MOVETYPE_NOCLIP, PM_BTN_SPRINT,
// PM_ReadMovevar) need to be visible to the SSQC compiler.  The
// helper itself is forward-declared so SH_GetSpreadScale (defined
// further down sh_weapon_logic.qc) can call it.
.float pm_movetype;
float  PM_MOVETYPE_NOCLIP = 5;
float  PM_BTN_SPRINT      = 8;
float(string name, float fallback) PM_ReadMovevar;
float() Weapon_IsADSActive;
// Grapple shared field is declared in sh_pmove.qc which compiles
// AFTER sh_weapon_logic.qc on SSQC (sv_progs.src), so the forward-
// decl here lets Weapon_IsADSActive's grapple-cancel branch see the
// field.  The .vector grapple_anchor that sits next to it isn't
// needed here — only the rope-active gate.
.float grapple_rope_active;

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
const float WEP_CSUSP            = 28;   // CS 1.6 USP-45 (semi-auto .45 pistol, secondary, silencer toggle)
// HD AK47 — sequence-driven GoldSrc viewmodel variant of WEP_AK47.
// Shares the same ammo pool (mag_ak47 / ammo_ak47) and balance numbers,
// only differs in v/w/p models + animation system.
const float WEP_HDAK47           = 29;
const float WEP_SNOWBALL         = 30;
const float WEP_SLINGSHOT        = 31;  // pickup-only snowball upgrade
const float WEP_PAINTBALL        = 32;
const float WEP_CSHEGRENADE      = 33;
const float WEP_CSFLASHBANG      = 34;
const float WEP_CSSMOKEGRENADE   = 35;
const float WEP_BUTTERFLY        = 36;
const float WEP_CFAUG            = 37;
const float WEP_CFFAMAS          = 38;
const float WEP_CFMAC10          = 39;
const float WEP_CFC4             = 40;
// Fists-only "weapon" — sequence-driven viewmodel only (no p_/w_model);
// random punch picks on +attack, random kick picks on +altattack,
// block_low on special.  Can't be dropped (no world model).
const float WEP_MELEE            = 41;
// Katana sword — sequence-driven, full p_/w_/v_ model set, droppable.
// Random slash on +attack (slash1/2/3), no-op block on +altattack.
const float WEP_KATANA           = 42;
// CF-series new weapons (Beretta M9, Colt Anaconda, Barrett, PSG1, Dual
// Desert Deagle).  Each gets its own ammo pool — no sharing across
// look-alike pairs (e.g. WEP_CFREVOLVER is independent from WEP_DEAGLE).
const float WEP_CFM9      = 43;   // Beretta M9 (pistol, secondary)
const float WEP_CFREVOLVER         = 44;   // Colt Anaconda (revolver, secondary)
const float WEP_CFBARRETT            = 45;   // Barrett M82 (bolt-action sniper, primary, CoD-scope)
const float WEP_CFPSG1          = 46;   // PSG1 (semi-auto sniper, primary, CoD-scope, no scope-out on fire)
const float WEP_CFDDEAGLE          = 47;   // Dual Desert Deagle (dual-wield pistol, secondary)
const float WEP_CFSPAS12         = 48;   // SPAS-12 (pump shotgun, primary)
const float WEP_CFM700      = 49;   // Remington M700 (bolt-action sniper, primary, CoD-scope)
const float WEP_CFM3             = 50;   // Winchester (pump shotgun, primary)
const float WEP_CFSCAR          = 51;   // FN SCAR (full-auto rifle, primary)
const float WEP_CFMAUSER          = 52;   // C96 Mauser (semi-auto pistol, secondary)
const float WEP_CFSVD          = 53;   // SVD Dragunov (semi-auto sniper, primary, CoD-scope, no scope-out on fire)
// CrossFire SMG/rifle additions — sequence-driven GoldSrc viewmodels,
// full-auto, penetrating hitscan.  Each has its own ammo pool.
const float WEP_CFMP5            = 54;   // CF MP5 (full-auto 9mm SMG, primary)
const float WEP_CFVECTOR         = 55;   // CF Vector (full-auto .45 SMG, primary)
const float WEP_CFTYPE89         = 56;   // CF Type 89 (full-auto 5.56 rifle, primary)
const float WEP_CFUMP45          = 57;   // CF UMP45 (full-auto .45 SMG, primary)
const float WEP_CFM249           = 58;   // CF M249 (full-auto 5.56 LMG, primary)
const float WEP_CFAWM            = 59;   // CF AWM (bolt-action sniper, primary, CoD-scope)
const float WEP_CFKS23           = 60;   // CF KS-23 (pump shotgun, primary, 3-shell big-bore)
const float WEP_CFM4             = 61;   // CF M4 Super 90 (auto shotgun, primary, shell-by-shell)
const float WEP_CFMK23           = 62;   // CF MK23 SOCOM (semi-auto .45 pistol, secondary, silencer toggle)
const float WEP_CFGALIL          = 63;   // CF Galil (full-auto rifle, primary)
const float WEP_CFGLOCK          = 64;   // CF Glock 18 (full-auto pistol, secondary)
const float WEP_CFELITE          = 65;   // CF Scout Elite (semi-auto scout sniper, primary, CoD-scope)
const float WEP_CFP228           = 66;   // CF P228 (semi-auto pistol, secondary)
const float WEP_CFMSG90          = 67;   // CF MSG90 (semi-auto sniper, primary, CoD-scope)
const float WEP_CFSG552          = 68;   // CF SG552 (full-auto scoped assault rifle, primary, CoD-scope like CFAUG)
const float WEP_CFSL8            = 69;   // CF SL8 (semi-auto marksman rifle, primary)

// --- Slot IDs ---
const float SLOT_NONE      = 0;
const float SLOT_PRIMARY   = 1;
const float SLOT_SECONDARY = 2;
const float SLOT_MELEE     = 3;
const float SLOT_UTILITY   = 4;

// Physics weapon drops live outside FTE's default dimension mask (255).
// dimension_solid = PHYSDROP_DIM (only) means player movement (which has
// dimension_hit = dimension_default) doesn't collide with their ODE bodies.
// dimension_hit = dimension_default | PHYSDROP_DIM means the drop CAN
// collide with regular brushwork (world, func_breakable, func_door,
// func_button …) and with other phys drops.  Server weapon traces
// temporarily OR PHYSDROP_DIM into self.dimension_hit when they need
// to shoot the drops themselves.
const float PHYSDROP_DIM = 256;

// Grace window before a player can pick their own toss back up. This is
// separate from fake-drop handoff: CSQC swaps to the real server entity as
// soon as that entity arrives, but pickup prediction stays locked until here.
const float WEAPON_DROP_PICKUP_DELAY = 0.5;

// Pickup zone — a fixed cube anchored at the dropped weapon's origin used
// to test "is the player close enough to pick this up?". Decoupled from
// the entity's setsize hull because ODE phys-drops have a setsize that
// can be much larger than the visible weapon (its trimesh hull) AND
// rotates with the body. Anchoring a fixed cube keeps pickup feel
// consistent across weapon types and lets client + server agree on the
// same authoritative reach. Both sides use these numbers — keep edits
// in sync naturally by keeping them here.
const float WEAPON_PICKUP_HALF_W    = 18;
const float WEAPON_PICKUP_HEIGHT_DN = 12;
const float WEAPON_PICKUP_HEIGHT_UP = 28;
// Slack pad on the pickup zone — keeps a player whose bbox grazes the
// authoritative cube from bouncing pickup-eligible state on/off when
// snapshot jitter wobbles their position by a unit or two. Same value
// on both sides so client predict and server +use agree on whether
// you're "in the zone".
const float WEAPON_PICKUP_PAD       = 4;

float(float wep) Weapon_PhysDropEligible =
{
    if (wep == WEP_NONE)
        return FALSE;
    return TRUE;
};

// --- Weapon impulses ---
const float WEAPON_IMPULSE_PRIMARY   = 1;
const float WEAPON_IMPULSE_SECONDARY = 2;
const float WEAPON_IMPULSE_MELEE     = 3;
// (impulse 4 = utility cycle — handled inline in the dispatcher)
// C4 select on impulse 5, mirroring the inventory-slot pattern of
// 1=primary / 2=secondary / 3=melee / 4=utility / 5=C4.  Drop got
// shifted to impulse 8 to keep this slot ordering clean — bind via
// `bind g "impulse 8"` (the default).
const float WEAPON_IMPULSE_C4        = 5;
const float WEAPON_IMPULSE_RELOAD    = 6;
const float WEAPON_IMPULSE_SPECIAL   = 7;
const float WEAPON_IMPULSE_DROP      = 8;
// Grappling hook — sv_grappling-gated.
//
//   `impulse 9`   — legacy toggle: press to fire, press again to release.
//                   Bind via `bind <key> "impulse 9"`.
//
//   `impulse 91`  — press-and-hold RELEASE half: paired with the
//                   +grapple / -grapple aliases registered in
//                   CSQC_Init.  `+grapple` fires impulse 9 on key
//                   press, `-grapple` fires impulse 91 on key release.
//                   Bind via `bind <key> "+grapple"`.
//
// The impulse-pair approach is used (rather than a held button bit)
// because the user-command button mask is byte-limited on the
// protocol in use here — bit 256 (+button9) wouldn't traverse the
// wire reliably.  Impulses are scalar and protocol-agnostic.
const float WEAPON_IMPULSE_GRAPPLE        = 9;
const float WEAPON_IMPULSE_GRAPPLE_RELEASE = 91;
const float WEAPON_IMPULSE_NEXT      = 12;
const float WEAPON_IMPULSE_PREV      = 13;
const float WEAPON_IMPULSE_LASTINV   = 14;
// Client-only flashlight toggle. Handled entirely on CSQC — toggles
// a local-render dlight + plays the click sound. Not networked, so
// other players don't see the cone in this version.
const float WEAPON_IMPULSE_FLASHLIGHT = 50;

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
const float CSQC_EVENT_DEATH_DROP = 19;              // visual fake-drop scatter for non-physics death drops; ODE drops use the real SendEntity immediately
const float CSQC_EVENT_GRENADE_EXPLODE = 20;         // grenade detonation FX — sprite + particles + light + boom sound. Server multicasts to PVS EXCEPT shooter (who handles all FX locally via CSQC_FakeHLGrenadeExplode). Carries a sample-variant byte for the boom; the dimension_send mask on the multicast does the filtering (sound() builtin doesn't honor dimension_send, so we route the audio via this event).
const float CSQC_EVENT_DAMAGE_REPORT   = 21;         // death-screen damage report (sent only to the dying player) — given/taken lists with each opponent's name + current HP. cl_playerdamage gates display.
const float CSQC_EVENT_GRENADE_BOUNCE  = 22;         // grenade surface bounce sound. Server multicasts to PVS EXCEPT shooter (who plays it locally via CSQC_FakeHLGrenadeBounce). Carries the sample-variant byte. Same rationale as CSQC_EVENT_GRENADE_EXPLODE — sound() doesn't honor dimension_send, multicast does.
const float CSQC_EVENT_HL_BEAM         = 23;         // HL Gauss/Egon beam segment. Shooter predicts locally; server event is attacker-excluded for remote viewers.
const float CSQC_EVENT_SNOWSPLAT       = 24;         // snowball impact sound/decal. Wall decals are attacker-excluded because the shooter predicts them locally.
const float CSQC_EVENT_PAINTSPLAT      = 25;         // paintball hit decal. Shooter predicts locally; server event is attacker-excluded for remote viewers.
const float CSQC_EVENT_CSGRENADE_EXPLODE = 26;       // CS grenade detonation FX. Payload carries type so HE/flash/smoke can share the multicast.
const float CSQC_EVENT_CSGRENADE_BOUNCE  = 27;       // CS grenade bounce sound. Shooter predicts locally, remote clients receive this.
const float CSQC_EVENT_C4_EXPLODE        = 28;       // C4 detonation FX — sprite gfx/fexplo.spr at 4x scale + boom sound.
const float CSQC_EVENT_DOOR_VIEWROT      = 29;       // private rotating-door yaw delta sent to a single carried player so their CSQC adds it to input_angles.
const float CSQC_EVENT_TRIGGER_HURT_HIT  = 30;       // (reserved, future use; kept here for the byte ordering reference)
const float CSQC_EVENT_BUTTON_SPARK      = 31;       // SPARKS-flagged func_button — server multicasts to PVS, CSQC fires "fx_spark.main" via pointparticles. te_spark didn't render in this engine config; pointparticles with the loaded particle config does.
const float CSQC_EVENT_ENV_EXPLOSION     = 32;       // env_explosion (HL point entity) — fireball sprite + smoke emitter + scorch decal + sparks + sound, masked by spawnflag bits NoDamage/NoFireball/NoSmoke/NoDecal/NoSparks.  Sound always plays per HL spec.
const float CSQC_EVENT_CLEANMODELS       = 33;       // server-console "cleanmodels" trigger — wipes shells/mags client-side (corpses are removed server-side and replicate naturally via SendEntity).
const float CSQC_EVENT_CLEANDECALS       = 34;       // server-console "cleandecals" trigger — wipes bullet holes, scorch decals, muzzle smoke, and CS smoke-grenade puffs client-side.
const float CSQC_EVENT_SPRAY             = 35;       // player spray decal spawn (impulse 19). Payload: spray_id short, owner entnum byte, pos 3×coord, normal 3×coord, name string. Multicast PVS.
const float CSQC_EVENT_SPRAY_REMOVE      = 36;       // FIFO eviction of a player's oldest spray when sv_spraymax is hit. Payload: spray_id short. Multicast ALL so any client that allocated the slot can free it.
const float CSQC_EVENT_PLAYER_FLINCH     = 37;       // visual flinch reaction when a player takes damage.  Payload: 1 byte victim slot, 1 byte hitgroup (HITGROUP_HEAD/GENERIC).  Server multicasts on every non-fatal player hit; the attacker also predicts locally via CSQC_SendHitclaim so they see flinch instantly without waiting for the server round-trip.
const float CSQC_EVENT_ENV_FADE          = 38;       // env_fade HUD overlay. Payload: rgb bytes, alpha byte, duration float, hold float, flags byte.
const float CSQC_EVENT_ENV_MESSAGE       = 39;       // env_message title text. Payload: message/title key string; client resolves titles.txt.
const float CSQC_EVENT_DAMAGE_VIEWKICK   = 40;       // private victim camera punch. Payload: signed short pitch*100, signed short roll*100.
const float CSQC_EVENT_RADIO_CALL        = 41;       // radio quick-chat playback. Payload: resolved voice-line path string. CSQC plays beep1 → voice → beep2 in sequence using soundlength() to time each stage.

// --- Kill-feed causes (byte payload of CSQC_EVENT_KILLFEED) ---
const float KILL_CAUSE_WEAPON       = 0;
const float KILL_CAUSE_FALL         = 1;
const float KILL_CAUSE_SUICIDE      = 2;
const float KILL_CAUSE_FRIENDLYFIRE = 3;
const float KILLFEED_NO_ATTACKER    = 255;

// --- Server-projectile types (CSQC_ENT_PROJECTILE sub-byte) ---
// Routed through the CSQC tosssmooth pipeline (cl_projectiles.qc parser
// + cl_tosssmooth.qc extrap+smooth predraw) so other players see the
// projectile fly smoothly instead of snapping at every server send tick.
// Each type carries its own model + gravity factor — see Projectile_Type
// helpers below. Add new entries here AND in those helpers.
const float PROJ_TYPE_HLGRENADE     = 0;   // hand grenade (gravity 0.5)
const float PROJ_TYPE_GRENADE       = 1;   // GL grenade   (gravity 1.0)
const float PROJ_TYPE_RPG_ROCKET    = 2;   // RPG rocket   (gravity 0.0)
const float PROJ_TYPE_CROSSBOW_BOLT = 3;   // crossbow     (gravity 0.0)
const float PROJ_TYPE_SNOWBALL      = 4;   // snowball     (gravity 0.65)
const float PROJ_TYPE_CSHEGRENADE   = 5;   // CS HE        (gravity 0.55)
const float PROJ_TYPE_CSFLASHBANG   = 6;   // CS flashbang (gravity 0.55)
const float PROJ_TYPE_CSSMOKEGRENADE = 7;  // CS smoke     (gravity 0.55)
const float PROJ_TYPE_PAINTBALL     = 8;   // paintball — sv_paintball_projectile mode. Reuses
                                           // w_snowball.mdl shrunk via .scale, tinted via
                                           // .colormod (3 extra wire bytes when ptype==8).

// Type → world model path. Matches the SSQC spawn site of each
// projectile. Used by the CSQC parser to setmodel the local entity
// once it knows the type byte.
string(float t) Projectile_TypeModel =
{
    if (t == PROJ_TYPE_HLGRENADE)     return "models/weapons/wpn_hlgrenade/w_grenade.mdl";
    if (t == PROJ_TYPE_GRENADE)       return "models/weapons/wpn_grenadelauncher/grenade.mdl";
    if (t == PROJ_TYPE_RPG_ROCKET)    return "models/weapons/wpn_hlrpg/rpgrocket.mdl";
    if (t == PROJ_TYPE_CROSSBOW_BOLT) return "models/weapons/wpn_hlcrossbow/bolt.mdl";
    if (t == PROJ_TYPE_SNOWBALL)      return "models/weapons/wpn_snowball/w_snowball.mdl";
    if (t == PROJ_TYPE_CSHEGRENADE)   return "models/weapons/wpn_cshegrenade/w_hegrenade.mdl";
    if (t == PROJ_TYPE_CSFLASHBANG)   return "models/weapons/wpn_csflashbang/w_flashbang.mdl";
    if (t == PROJ_TYPE_CSSMOKEGRENADE) return "models/weapons/wpn_cssmokegrenade/w_smokegrenade.mdl";
    if (t == PROJ_TYPE_PAINTBALL)     return "models/weapons/wpn_snowball/w_snowball.mdl";
    return "";
};

// Type → gravity factor for CSQC extrap. Must match the .gravity each
// projectile sets on its server-spawn site so the CSQC trajectory
// extrapolation curves the same way the server's MOVETYPE_TOSS path
// computes between snapshots.
float(float t) Projectile_TypeGravity =
{
    if (t == PROJ_TYPE_HLGRENADE)     return 0.5;
    if (t == PROJ_TYPE_GRENADE)       return 1.0;
    if (t == PROJ_TYPE_RPG_ROCKET)    return 0;
    if (t == PROJ_TYPE_CROSSBOW_BOLT) return 0;
    if (t == PROJ_TYPE_SNOWBALL)      return 0.65;
    if (t == PROJ_TYPE_CSHEGRENADE)   return 0.55;
    if (t == PROJ_TYPE_CSFLASHBANG)   return 0.55;
    if (t == PROJ_TYPE_CSSMOKEGRENADE) return 0.55;
    if (t == PROJ_TYPE_PAINTBALL)     return 0.45;   // PAINTBALL_PROJ_GRAVITY (sh_wpn_paintball.qc)
    return 0;
};

// Should the HUD crosshair render for this weapon?  Melees, utility
// items, and scope-capable snipers all hide it.  Must stay in sync with
// the `show_crosshair` parameter passed to W_SetCrosshairProfile in
// each weapon's equip function.  Used by cl_crosshair.qc so visibility
// tracks the predicted weapon switch instantly — server still networks
// STAT_CROSSHAIR_DISABLED but the client no longer reads it, avoiding
// the stale-crosshair-after-switch stutter at high ping.
float(float wep_id) Weapon_HasCrosshair =
{
    return WeaponManifest_HasCrosshair(wep_id);
};

// Can this weapon enter a scoped (zoomstage > 0) state via its alt-fire?
// Used by the HUD to suppress the scope overlay after a weapon switch
// leaves the server still reporting zoomstage > 0 (the real state catches
// up a moment later under high ping).  If a non-scope weapon is equipped
// we treat zoomstage as 0 for HUD gating, regardless of the stat.
float(float wep_id) Weapon_HasScope =
{
    // sv_codscopes mode reassigns +attack2 on scout / awp from the
    // CS-style stage-cycle to a CoD-style ADS-hold scope (state
    // machine in client/cl_codscope.qc).  Hiding the scope-capable
    // flag for those two weapons under codscopes mode automatically
    // suppresses the legacy zoom path: CSQC_UpdateViewAliveSensitivity
    // (cl_main.qc), HUD_DrawScope gate (cl_hud.qc), CSQC_ApplySniperSway
    // (cl_cameras.qc), and the predicted-shot zero-spread branch all
    // gate on Weapon_HasScope — when this returns 0 for scout/awp the
    // legacy stack treats them as unscoped weapons and the CoD
    // overlay / FOV / fog story owns the entire feel for them.
    if ((wep_id == WEP_SCOUT || wep_id == WEP_CSAWP)
        && PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    return WeaponManifest_HasScope(wep_id);
};

// Canonicalize a weapon token so console-friendly aliases like
// "desert eagle", "hl_shotgun", ".357", and "AK47" all collapse to a
// simple comparable key.
string(string raw) Weapon_NameKey =
{
    return WeaponManifest_NameKey(raw);
};

// Accept either a numeric weapon id or a short weapon alias. Unknown
// strings fall back to the caller-provided value so existing numeric
// cvar behavior remains intact.
float(string raw, float fallback) Weapon_IdFromStringOrDefault =
{
    return WeaponManifest_IdFromStringOrDefault(raw, fallback);
};

// Walk a comma-separated weapon-id list (e.g. "33,34" or "hegrenade,flashbang")
// and return the first valid weapon id, or `fallback` if the list is empty
// or contains only unknown tokens.  Whitespace inside tokens is allowed.
// Single-id strings ("33") still parse since tokenizebyseparator returns
// one token in that case.
float(string list, float fallback) Weapon_FirstIdFromList =
{
    if (list == "")
        return fallback;
    float n = tokenizebyseparator(list, ",");
    float i;
    for (i = 0; i < n; i++)
    {
        float id = Weapon_IdFromStringOrDefault(argv(i), WEP_NONE);
        if (id != WEP_NONE)
            return id;
    }
    return fallback;
};

// Iterate a comma-separated weapon-id list, calling `action(id)` once per
// valid weapon id (skipping unknowns).  Order preserved.  Caller passes a
// statically-known function pointer so QC's call indirection is one less
// hop than walking + dispatching by id at the call site.
//
// Usage: tokenize the cvar once, walk the tokens, give ammo per id.  See
// W_GiveStartingAmmo's utility post-pass.
float(string list) Weapon_TokenizeIdList =
{
    if (list == "")
        return 0;
    return tokenizebyseparator(list, ",");
};

// Short display name for a weapon ID — used by the kill feed and (potentially)
// future UI.  Matches the labels in menu/m_createserver.qc loadout arrays.
string(float wep_id) Weapon_DisplayName =
{
    return WeaponManifest_DisplayName(wep_id);
};

// Per-weapon walk/run-speed multiplier applied to mv_maxspeed and
// mv_shiftspeed in PM_PlayerMoveStep.  Heavier weapons feel slower in
// both run and shift-walk modes.  1.0 = full default speed (melee);
// 0.926 ≈ 250 qu/s when sv_maxspeed is the mod default of 270.
// Predicted automatically — both SSQC and CSQC read self.weapon.
float(float wep_id) Weapon_SpeedFactor =
{
    return WeaponManifest_SpeedFactor(wep_id);
};

// Definition moved below — Weapon_SpeedFactor_Smooth references .weapon
// and .pm_weapon_* fields that are declared further down in the file.
// See the function body after the field block.

// --- Bullet impact material codes (sent in CSQC_EVENT_IMPACT) ---
// Used by CSQC to pick the right particle effect per surface.
// Some materials allow decals on static BSP, while METAL_NODECAL is reserved
// for physics bodies that should spark but never receive a bullet hole.
const float IMPACT_MAT_DEFAULT      = 0;   // static wall/concrete (orange dust + decal)
const float IMPACT_MAT_FLESH        = 1;   // routine flesh hit (cloud only, no sparks)
const float IMPACT_MAT_METAL        = 2;   // BREAKABLE_METAL/MACHINE/CIRCUIT (sparks)
const float IMPACT_MAT_GLASS        = 3;   // BREAKABLE_GLASS (clear shards)
const float IMPACT_MAT_WOOD         = 4;   // BREAKABLE_WOOD (brown debris)
const float IMPACT_MAT_FLESH_LETHAL = 5;   // killing blow OR headshot (cloud + spark splash)
const float IMPACT_MAT_METAL_NODECAL = 6;  // physics metal hit (sparks, no decal)

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
const float BRUSH_TYPE_CONVEYOR = 4;   // ships movedir + speed in brushsync wire
const float BRUSH_TYPE_TRAIN    = 5;   // func_train / func_tracktrain — CSQC predicts platform carry + geometry push via PM_CheckMovingPushers train branch

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

// Canonical ammo state for single-weapon inventory slots.  Legacy
// per-weapon mag/ammo fields are still used as active-weapon working
// registers by the existing weapon implementations; sh_weapon_slotammo.qc
// mirrors them to/from these slot fields.
.float slot_primary_mag;
.float slot_primary_ammo;
.float slot_primary_aux;
.float slot_secondary_mag;
.float slot_secondary_ammo;
.float slot_secondary_aux;

// Utility inventory fields live here because sv_weapons.qc manages the
// utility slot before the individual utility weapon files are compiled.
.float ammo_hlgrenade;
.float ammo_snowball;
.float ammo_cshegrenade;
.float ammo_csflashbang;
.float ammo_cssmokegrenade;
.float ammo_cfc4;
.float snowball_has_slingshot;
.float snowball_use_slingshot;

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

// Server-side replay-protection ring for SV_HandleProjhitClaim.
// Stores the last 32 action_ids consumed by a successful projhit so
// the same shot can't claim twice.  We no longer require the live
// projectile entity to exist when the claim arrives — server-side
// physics often consumes the projectile (fuse, world touch) before
// the client's hit claim lands, which caused the "shot doesn't
// register" bug.  Window-based validation against wep_action_id
// proves the player actually fired that shot recently; this ring
// prevents replays.
.float proj_consumed_ids[32];
.float proj_consumed_ring_idx;
.float wep_nextframe;    // server-side: absolute server time of next frame tick
.float wep_anim_start;   // absolute time when the current animation began

// Speed-factor transition state (used by Weapon_SpeedFactor_Smooth in
// PM_ReadMovevars).  On weapon switch, both client and server reset
// pm_weapon_blend_progress to 0 and capture the CURRENT effective factor
// into pm_weapon_prev_factor.  PM_ReadMovevars advances progress by
// input_timelength / sv_wepswap_speed_transition per pmove tick.  The
// smooth helper interpolates from prev → new based on progress.
//
// Input-tick-driven (NOT wall-clock-driven): both sides advance progress
// using the same input_timelength per buffered command, so client live,
// client replay, and server pmove all reach the same progress at the
// same input frame.  Mirrors shift-walk's input-bit determinism — see
// the rewrite history in plans/radiant-popping-hollerith.md for context.
//
// Serialized via the prediction proxy (PM_SF_WEAPON_STATE section) so a
// reconcile mid-blend doesn't lose in-flight transition state.
.float pm_weapon_blend_progress;   // 0 = at prev_factor, 1 = at new_factor
.float pm_weapon_prev_factor;
.float zoomstage;        // scope zoom level: 0=unscoped, 1=zoom1, 2=zoom2
                         // sent through proxy as elapsed time; used by CSQC to
                         // compute the display frame via cltime - wep_anim_start

// Returns the player's CURRENT effective speed factor, smoothing the
// transition from the prior weapon's factor (pm_weapon_prev_factor) to
// the new weapon's factor based on pm_weapon_blend_progress (0..1).
// PM_ReadMovevars advances progress per pmove tick.
//
// Input-tick-driven so both client live, client replay, and server pmove
// reach the same progress at the same input frame — pmove output stays
// deterministic regardless of ping.
//
// The "prev factor" snapshot at switch time is intentionally the CURRENT
// effective factor (which may itself be mid-transition from a previous
// switch).  That makes rapid back-to-back switches blend smoothly
// instead of snapping back to an old reference point each time.
//
// Defined here, not earlier with Weapon_SpeedFactor, because it needs
// .pm_weapon_* and .weapon (declared above) to be in scope.
float() Weapon_SpeedFactor_Smooth =
{
    // mp_weaponweight 0 disables the per-weapon movement penalty entirely
    // (AWP / M249 / sniper rifles no longer slow you down). Server-pushed
    // via serverinfo so CSQC prediction reads the same value the SSQC
    // pmove uses — otherwise the predicted speed would diverge.
#ifdef CSQC
    float weight_on = serverkeyfloat("mp_weaponweight", 1);
#else
    float weight_on = cvar("mp_weaponweight");
#endif
    if (weight_on == 0)
        return 1.0;

    float new_factor = Weapon_SpeedFactor(self.weapon);
    float t = self.pm_weapon_blend_progress;

    if (t >= 1.0) return new_factor;
    if (t <= 0.0) return self.pm_weapon_prev_factor;

    // Smoothstep — zero slope at both endpoints so the factor leaves
    // prev_factor and reaches new_factor without slope discontinuities.
    // Rapid back-to-back switches blend continuously because each switch
    // captures prev_factor at the current effective value.
    float smooth_t = t * t * (3 - 2 * t);
    return self.pm_weapon_prev_factor
         + (new_factor - self.pm_weapon_prev_factor) * smooth_t;
};

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
.float  weapon_viewmodel_flip;         // TRUE to mirror the viewmodel horizontally (left-handed source models). Engine-side: RF_XFLIP flips projection X and inverts cull winding.
// Muzzle tag — set in the CSQC equip function for weapons whose
// viewmodel has a usable muzzleflash bone (e.g. HL studio MDLs with a
// $attachment).  Empty `weapon_muzzle_bone` = no tag → the sway pivot
// code in cl_viewfx.qc falls back to translation parallax.  Offset is
// in HL studio coords (+X forward, +Y left, +Z up) just like the
// existing muzzle-flash plumbing, so the same constants used for the
// flash also describe the pivot point.
.string weapon_muzzle_bone;
.vector weapon_muzzle_offset;

// --- ADS / scope classification (set per-weapon in Equip; read by the
//     shared ADS + CoD-scope logic in sh_weapon_logic.qc / sh_pmove.qc /
//     cl_viewfx.qc / cl_codscope.qc instead of hardcoded WEP_* lists). ---
.float  weapon_ads_eligible;   // 1 => pose-ADS on +attack2 without codscope
.string weapon_ads_prefix;     // cl_ads cvar prefix ("" => shared "cl_ads")
.float  weapon_scope_class;    // SCOPE_CLASS_*
const float SCOPE_CLASS_NONE           = 0;
const float SCOPE_CLASS_SNIPER_BOLT    = 1;  // post-fire scope-out (scout/awp/awm/elite)
const float SCOPE_CLASS_SNIPER_SEMI    = 2;  // stay scoped through fire (psg1/svd/msg90)
const float SCOPE_CLASS_RIFLE_LOWPOWER = 3;  // 1.2x FOV, full-auto, stay scoped (aug/sg552/sl8)

// Set a weapon's ADS/scope profile in one call from its Equip (both the
// SSQC W_*Equip and the CSQC CSQC_*Equip).  Compiled both sides.
void(float eligible, string prefix, float scope_class) W_SetADSProfile =
{
    self.weapon_ads_eligible = eligible;
    self.weapon_ads_prefix   = prefix;
    self.weapon_scope_class  = scope_class;
};

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

// Generic dropped-ammo payload.  SendEntity and CSQC pickup prediction read
// this directly; individual weapon drop funcs still populate their legacy
// fields for compatibility.
.float weapon_drop_mag;
.float weapon_drop_ammo;
.float weapon_drop_aux;

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
    return WeaponManifest_PlayerAnimFamily(wep);
};

// Maps weapon ID to the p_*.mdl path for third-person weapon attachment.
string(float wep) W_GetPModelPath =
{
    return WeaponManifest_PModelPath(wep);
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

// --- sv_hitbox_expand bookends ---
//
// Inflate every alive (CSQC: remote) player's bbox by sv_hitbox_expand
// for the duration of a hit trace, then restore.  Used by both the
// CSQC predicted trace and the SSQC authoritative trace so they agree
// on which limbs are reachable after lag rewind.  CSQC walks the
// player_visual_proxy chain; SSQC walks the live player chain (impl
// in server/sv_weapons.qc, declared here so callers compiled earlier
// in sv_progs.src — sh_weapon_logic.qc, sh_weapon_standard.qc — see
// the symbol without a per-file forward decl).
#ifdef SSQC
void() W_PlayersExpandHitboxes;
void() W_PlayersRestoreHitboxes;
#endif

#ifdef CSQC
void() W_PlayersExpandHitboxes =
{
    float expand = serverkeyfloat("sv_hitbox_expand");
    if (expand <= 0) expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (!p.vis_is_dead && p.solid == SOLID_BBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x -= expand; mn_y -= expand; mn_z -= expand;
            mx_x += expand; mx_y += expand; mx_z += expand;
            setsize(p, mn, mx);
        }
        p = p.chain;
    }
};

void() W_PlayersRestoreHitboxes =
{
    float expand = serverkeyfloat("sv_hitbox_expand");
    if (expand <= 0) expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (!p.vis_is_dead && p.solid == SOLID_BBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x += expand; mn_y += expand; mn_z += expand;
            mx_x -= expand; mx_y -= expand; mx_z -= expand;
            setsize(p, mn, mx);
        }
        p = p.chain;
    }
};
#endif
