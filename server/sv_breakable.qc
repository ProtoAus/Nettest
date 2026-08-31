// ============================================================
//  server/sv_breakable.qc  -  func_breakable entity
//
//  A visible BSP brush that can be destroyed by shooting it.
//  Spawns debris on break, plays sounds, fires targets.
// ============================================================

// Forward declaration — defined in server/sv_brushsync.qc which
// compiles AFTER this file. Needed so func_breakable can replicate
// itself to CSQC for local-shooter per-material impact effects.
float(entity playerent, float changedflags) solid_brush_SendEntity;

// --- Spawnflags ---
const float BREAKABLE_NO_MONSTERS       = 1;
// Spawnflag 1 — TRIGGER_ONLY: shoot-proof, breaks only when its
//   targetname is fired (trigger_once / button / scripted use).
// Spawnflag 2 — TOUCH: breaks when a player physically touches the
//   brush (HL glass-pane behavior).  Phys props / dropped weapons /
//   projectiles do NOT trigger it — players only.
// Spawnflag 4 — ONLY_EXPLOSION: ignored by direct gunfire, but
//   participates in the radius-explosion damage loop via the
//   sv_in_radius_explosion override (sh_weapon_standard.qc).
// Spawnflag 8 — ALWAYS_SHOOTABLE: break when shot EVEN IF the brush has
//   a targetname.  By default a named breakable is trigger-only (a pure
//   `target`/`targetname` chain link, so it isn't shot away prematurely);
//   this flag opts back into shootable-while-named, letting a window pane
//   be both directly shootable AND fire/receive a `target` chain.
// Spawnflag 256 — INSTANT_CROWBAR: any melee weapon (knife / crowbar)
//   one-shots this brush regardless of HP.  Combines with the other
//   flags freely.
const float BREAKABLE_TRIGGER_ONLY      = 1;
const float BREAKABLE_TOUCH             = 2;
const float BREAKABLE_ONLY_EXPLOSION    = 4;
const float BREAKABLE_ALWAYS_SHOOTABLE  = 8;
const float BREAKABLE_INSTANT_CROWBAR   = 256;
// GoldSrc's SF_BREAK_PRESSURE is bit 4 (util.h:443) — "can be broken by a
// player standing on it".  Bit 4 is already spent here on ONLY_EXPLOSION, so it
// is rehomed onto free bit 16 and Break_NormaliseFlags does the translation.
// 122 brushes in the corpus set it, 55 of them WITHOUT the Touch bit (so they
// reach a dispatcher only through the registration gate below): hl_c03's 29
// Office Complex ceiling tiles, otokotati_no_kouzan's 35, th_ep1_02's 8.
const float BREAKABLE_PRESSURE          = 16;

// Every TOUCH-flagged func_breakable, in a spawn-time list that
// SV_CheckTouchTriggers walks once per player per frame.
//
// WHY A LIST AND NOT findradius: findradius ranks on the brush CENTRE, and 22 of
// the corpus's 215 touch breakables have a bbox half-diagonal larger than the
// 128-unit sweep SV_CheckTouchTriggers already uses (max 163, th_ep3_05's
// "elev_rail2"; 161 on hl_c11_a5), so a radius test would silently miss the big
// ones.  Same reasoning that made momentary_button_list a list.
//
// Built at spawn and never rebuilt, which is correct because BreakableResetAll
// restores brushes IN PLACE rather than removing them.  If a future code path
// ever remove()s a func_breakable this list would hold a freed edict — guard the
// walk on the classname at that point.
entity  breakable_touch_list;
.entity breakable_touch_next;

// The health the MAP authored, latched before func_breakable's `if (health <= 0)
// health = 20` default lands on it.  See the note where it is set.
.float  breakable_touch_health;

// ---------------------------------------------------------------------------
// Break_NormaliseFlags — translate GoldSrc/Sven spawnflags into the mod's
// vocabulary, IN PLACE, before anything reads them.
//
// Our FGD and Hammer's disagree on this entity:
//
//     bit   nettest.fgd (ours)      sven-coop.fgd:2129-2136
//      1    Only Trigger            Only Trigger          (same)
//      2    Touch                   Touch                 (same)
//      4    Only Explosion          Pressure              DIFFERENT
//      8    Always Shootable        Repairable            DIFFERENT
//     32    -                       Show HUD Info
//     64    -                       Immune To Clients
//    256    Instant Crowbar         Instant Break         (same)
//    512    -                       Explosives Only
//
// So a Sven "Pressure" plate (4) read as ours becomes bullet-proof, and a
// Sven "Explosives Only" crate (512) is not recognised at all and stays
// shootable — both backwards.  Measured on pizza_ya_san1: 9 brushes set
// bit 4 and 7 set bit 512.
//
// Rewriting .spawnflags in place (rather than adding a parallel .break_flags
// word like Door_NormaliseFlags does) is deliberate: these flags are read
// from SHARED code that also runs client-side — sh_weapon_standard.qc's
// radius-damage override and the two melee instant-break paths — so a new
// field would have to be replicated over the brushsync wire to be visible
// there.  Keeping the mod's vocabulary means every existing consumer, server
// and client, keeps working untouched.  func_pushable already establishes
// this exact pattern (sv_func_pushable.qc:551).
//
// Native maps are not touched at all, so the 29 BSPs already compiled
// against nettest.fgd behave bit-for-bit as before.
// ---------------------------------------------------------------------------
.float break_skip_normalise;   // set by func_pushable — different flag space

void() Break_NormaliseFlags =
{
    if (!Map_IsGoldSrc() || self.break_skip_normalise)
        return;

    float sven = self.spawnflags;

    // Bits 1 / 2 / 256 mean the same thing in both FGDs — carry them over.
    float out = sven & (BREAKABLE_TRIGGER_ONLY | BREAKABLE_TOUCH
                        | BREAKABLE_INSTANT_CROWBAR);

    // Sven 512 "Explosives Only" is what our bit 4 actually means.
    if (sven & 512)
        out = out | BREAKABLE_ONLY_EXPLOSION;

    // GoldSrc SF_BREAK_PRESSURE (util.h:443) is bit 4, which we spend on
    // ONLY_EXPLOSION — rehome it onto bit 16.
    //
    // ORDERING DEPENDENCY, do not break it: `out` is rebuilt from scratch at
    // the masked assignment above, which is what discards the junk bit 16 that
    // four corpus brushes already carry.  This line then puts 16 back only for
    // brushes that genuinely asked for Pressure.  If that mask is ever made
    // additive, those four silently become pressure plates.
    if (sven & 4)
        out = out | BREAKABLE_PRESSURE;

    // HL's CBreakable::Spawn derives takedamage from SF_BREAK_TRIGGER_ONLY
    // ALONE — a targetname does NOT make a brush bulletproof.  That rule is
    // a Quake-ism we apply below unless ALWAYS_SHOOTABLE is set, and Sven
    // maps name breakables precisely so they can fire a target WHEN SHOT,
    // so set it for everything that isn't trigger-only.
    if (!(sven & BREAKABLE_TRIGGER_ONLY))
        out = out | BREAKABLE_ALWAYS_SHOOTABLE;

    // Deliberately dropped, all unimplemented: 8 Repairable, 32 Show HUD Info,
    // 64 Immune To Clients.  Dropping matters — leaving 8 set would collide
    // with our own meaning for that bit.
    self.spawnflags = out;

    if (cvar("sv_debug_breakables") && out != sven)
        dprint(sprintf("[breakable %s] flags %g -> %g (goldsrc)\n",
                       self.targetname, sven, out));
};

// --- Material styles (set via "style" key in map editor) ---
//
// Numbering chosen by the user — note that this does NOT match the
// debris-model skin order baked into debris1/2/3.mdl (see the skin
// remap helper in cl_breakable.qc).  Several of these are aliases
// that route to existing assets:
//   CINDER → uses CONCRETE assets
//   TILE   → uses WOOD assets
//   COMPUTER → uses CIRCUIT assets
//   UNBREAKABLE_GLASS → looks like GLASS under fire but never breaks
//                       (gated in func_breakable_break)
//   ROCKS  → uses ROCK assets
const float BREAKABLE_GLASS              = 0;
const float BREAKABLE_WOOD               = 1;
const float BREAKABLE_METAL              = 2;
const float BREAKABLE_FLESH              = 3;
const float BREAKABLE_CINDER             = 4;
const float BREAKABLE_TILE               = 5;
const float BREAKABLE_COMPUTER           = 6;
const float BREAKABLE_UNBREAKABLE_GLASS  = 7;
const float BREAKABLE_ROCKS              = 8;

// --- Debris skin indices (match texture order in debris1/2/3.mdl) ---
// The MODEL's skins are baked in this order — independent of the
// style numbering above.  Server / CSQC must remap style→skin via
// the helper in cl_breakable.qc when spawning debris.
//   skin 0=concrete, 1=rock, 2=metal, 3=wood, 4=glass, 5=flesh, 6=machine, 7=circuit

// --- Debris frame indices ---
const float DEBRIS_FRAME_SMALL = 0;
const float DEBRIS_FRAME_BIG   = 1;
const float DEBRIS_FRAME_FLAT  = 2;

// --- Custom entity fields ---
.float cnt;                        // number of debris pieces to spawn
.string mdl;                       // optional custom debris model
.float alpha2;                     // optional alpha for debris
.float switchshadstyle;            // lightstyle index to toggle on break
.float breakable_next_impact_sound; // debounce timer for impact sounds
.float breakable_broken;           // TRUE if currently broken (hidden)
.string breakable_model;           // saved model path for reset
.float custom_mdl_idx;             // precached modelindex of self.mdl override (0 = none)
.float renderamt;                  // GoldSrc-convention 0..255 alpha key
// "material" is the GoldSrc map-editor key for the BREAKABLE_*
// style number.  We keep using `self.style` internally (rest of
// this file + CSQC mirror) but read `self.material` at spawn and
// copy it across — without this, `self.style` stayed at the QC
// default 0 (= GLASS) and every metal/wood/etc. breakable showed
// glass FX.  `style` is a reserved Quake1 lightstyle field so we
// can't simply rename to it; the spawn-time copy is the fix.
.float material;
// 0 = random gib velocities (default); 1 = throw gibs along the
// damage direction with magnitude scaled by self.dmg.  Read at
// break time and serialised onto the gib multicast so CSQC's
// debris/glass spawners apply the matching directional kick.
.float explosion;
// `.dmg` is declared in sv_doors.qc (block-damage key) but that
// file compiles after this one — forward-decl here so the
// directional-throw branch in BreakableSpawnDebris can read it.
// Sharing a slot with the door's dmg key is intentional; both
// uses are scoped to entity classes that don't overlap.
.float dmg;

// --- Forward declarations ---
void(entity caller, entity triggerer) Trigger_UseTargets;
// Defined in sv_triggers.qc, which compiles after this file.  Needed for
// the killtarget/delay-aware chain fire in func_breakable_break.
void(entity caller, entity who, float useType) SUB_UseTargets;
// Defined in sv_weapons.qc, which compiles after this file.
void(entity drop_ent) W_PhysDropWake;
// Defined in sv_goldsrc_ammo.qc (position 232 vs this file's 28).  It has to
// live that late because it dispatches to every weapon, ammo and item spawn
// function in the tree, which are spread from position 42 to 228.
void(vector org, float idx) Breakable_SpawnObject;
// Inter-call within this file — the .touch handler defined above
// invokes the break handler defined below.
void() func_breakable_break;
void() func_breakable_use;
// Defined in sv_brushsync.qc (compiled after this file) — handles
// the full rendermode/renderamt/rendercolor translation.
void() BrushSync_ApplyRenderKeys;
// Same file — detects fully-AAATRIGGER-textured brushes at spawn.
.float is_aaatrigger;
float() Brush_IsAATrigger;
// server/sv_func_pushable.qc (compiled later).  func_pushable runs this whole
// file's break pipeline but resets differently — it has to be put back at its
// SPAWN ORIGIN as well as restored, which no func_breakable ever needs.
void() FuncPushable_ResetAll;
// server/sv_env_explosion.qc (position 200; this file is 44).  A brush with
// `explodemagnitude` set detonates when it breaks — HL's CBreakable::Die tail
// (func_break.cpp:752-755).  Reached by forward declaration because .iMagnitude
// and the env_explosion spawn function are both declared in that later file.
void(vector center, float magnitude, entity expl_owner) ExplosionCreate;
void() Explosion_Precache;

// ============================================================
//  Helpers
// ============================================================

float(float value, float fallback) BreakableDefaultFloat =
{
    if (value)
        return value;
    return fallback;
};

// Returns a random break sound for the current material (called at play time)
string(float mat) BreakableRandomBreakSound =
{
    float v = random();

    // GLASS / UNBREAKABLE_GLASS share the glass break sounds
    // (UNBREAKABLE_GLASS never reaches the break path, but if a
    // future code path reads its sound, it should be glass).
    if (mat == BREAKABLE_GLASS || mat == BREAKABLE_UNBREAKABLE_GLASS)
    {
        if (v < 0.333) return "sounds/debris/break_glasshl1.wav";
        if (v < 0.666) return "sounds/debris/break_glasshl2.wav";
        return "sounds/debris/break_glasshl3.wav";
    }
    // CINDER and ROCKS use the concrete break set.
    if (mat == BREAKABLE_CINDER || mat == BREAKABLE_ROCKS)
    {
        if (v < 0.5) return "sounds/debris/break_concretehl1.wav";
        return "sounds/debris/break_concretehl2.wav";
    }
    // WOOD and TILE both route to the wood break set.
    if (mat == BREAKABLE_WOOD || mat == BREAKABLE_TILE)
    {
        if (v < 0.333) return "sounds/debris/break_woodhl1.wav";
        if (v < 0.666) return "sounds/debris/break_woodhl2.wav";
        return "sounds/debris/break_woodhl3.wav";
    }
    if (mat == BREAKABLE_FLESH)
    {
        if (v < 0.5) return "sounds/debris/break_fleshhl1.wav";
        return "sounds/debris/break_fleshhl2.wav";
    }
    // COMPUTER uses the electronic break sounds.
    if (mat == BREAKABLE_COMPUTER)
    {
        if (v < 0.125) return "sounds/debris/break_eletronichl1.wav";
        if (v < 0.250) return "sounds/debris/break_eletronichl2.wav";
        if (v < 0.375) return "sounds/debris/break_eletronichl3.wav";
        if (v < 0.500) return "sounds/debris/break_eletronichl4.wav";
        if (v < 0.625) return "sounds/debris/break_eletronichl5.wav";
        if (v < 0.750) return "sounds/debris/break_eletronichl6.wav";
        if (v < 0.875) return "sounds/debris/break_eletronichl7.wav";
        return "sounds/debris/break_eletronichl8.wav";
    }
    // METAL fallback.
    if (v < 0.5) return "sounds/debris/break_metalhl1.wav";
    return "sounds/debris/break_metalhl2.wav";
};

// Returns a random impact sound for the current material (called at play time)
string(float mat) BreakableRandomImpactSound =
{
    float v = random();

    if (mat == BREAKABLE_GLASS || mat == BREAKABLE_UNBREAKABLE_GLASS)
    {
        if (v < 0.25) return "sounds/debris/impact_glasshl1.wav";
        if (v < 0.50) return "sounds/debris/impact_glasshl2.wav";
        if (v < 0.75) return "sounds/debris/impact_glasshl3.wav";
        return "sounds/debris/impact_glasshl4.wav";
    }
    if (mat == BREAKABLE_CINDER || mat == BREAKABLE_ROCKS)
    {
        if (v < 0.333) return "sounds/debris/impact_concretehl1.wav";
        if (v < 0.666) return "sounds/debris/impact_concretehl2.wav";
        return "sounds/debris/impact_concretehl3.wav";
    }
    if (mat == BREAKABLE_WOOD || mat == BREAKABLE_TILE)
    {
        if (v < 0.25) return "sounds/debris/impact_woodhl1.wav";
        if (v < 0.50) return "sounds/debris/impact_woodhl2.wav";
        if (v < 0.75) return "sounds/debris/impact_woodhl3.wav";
        return "sounds/debris/impact_woodhl4.wav";
    }
    if (mat == BREAKABLE_FLESH)
    {
        if (v < 0.167) return "sounds/debris/impact_fleshhl1.wav";
        if (v < 0.333) return "sounds/debris/impact_fleshhl2.wav";
        if (v < 0.500) return "sounds/debris/impact_fleshhl3.wav";
        if (v < 0.667) return "sounds/debris/impact_fleshhl4.wav";
        if (v < 0.833) return "sounds/debris/impact_fleshhl5.wav";
        return "sounds/debris/impact_fleshhl6.wav";
    }
    // Metal, machine, circuit all use metal impact
    if (v < 0.167) return "sounds/debris/impact_metalhl1.wav";
    if (v < 0.333) return "sounds/debris/impact_metalhl2.wav";
    if (v < 0.500) return "sounds/debris/impact_metalhl3.wav";
    if (v < 0.667) return "sounds/debris/impact_metalhl4.wav";
    if (v < 0.833) return "sounds/debris/impact_metalhl5.wav";
    return "sounds/debris/impact_metalhl6.wav";
};

// ============================================================
//  Debris  (spawn logic lives client-side — see CSQC_SpawnDebrisGibs
//  in cl_breakable.qc.  Server only multicasts a one-shot event.)
// ============================================================

// The attacker-exclude entnum for the CSQC effect events below, or 0 meaning
// "nobody predicted this, send to everyone".
//
// Two reasons this is a function and not `num_for_edict(self.dmg_inflictor)`:
//
//   1. Only a CLIENT can have predicted the effect.  The whole point of the
//      exclude is to suppress the server's copy for the one player whose CSQC
//      already played it; a world entity never predicts anything, so naming one
//      here suppresses the effect for a player who never saw it.
//   2. Only a client's entnum is guaranteed to fit the byte it ships in.
//      .dmg_inflictor is whatever dealt the damage, which on a GoldSrc map is
//      routinely an env_laser / func_tank / trigger_hurt at an arbitrary edict
//      number.  hl_c12's lasers sit at edicts 456-593, and WriteByte WRAPS
//      rather than clamps — 526 went out as 14, silently muting breakable
//      impacts for whichever player held edict 14.  The engine logged it as
//      `Write*: value 526 is outside of the required 0 to 255 range`.
float() BreakableExcludeEntnum =
{
    if (self.dmg_inflictor && (self.dmg_inflictor.flags & FL_CLIENT))
        return num_for_edict(self.dmg_inflictor);
    return 0;
};

void() BreakableSpawnDebris =
{
    float damage_scale = max(self.max_health, 20);
    vector center      = (self.absmin + self.absmax) * 0.5;

    // Attacker-exclude entnum — mirrors the sound events. The shooter's
    // CSQC already spawned matching gibs in CSQC_PredictBreakableBreak,
    // so skipping them on the server broadcast prevents doubled debris.
    float exclude = BreakableExcludeEntnum();

    // Directional throw payload — only meaningful when self.explosion
    // is 1.  Direction is the unit vector from the attacker to the
    // brush centre; force is the brush's `dmg` key (defaulting to a
    // mild kick when unset so the gibs still get *something*).  When
    // explosion is 0 these bytes still ship but CSQC ignores them.
    // Direction is quantised to 3 signed bytes biased by 127.
    vector dir = '0 0 1';
    if (self.dmg_inflictor && self.dmg_inflictor != world)
        dir = normalize(center - self.dmg_inflictor.origin);
    float throw_force = (self.dmg > 0) ? self.dmg : 80;
    float throw_mode = (self.explosion > 0) ? 1 : 0;
    float dx = bound(0, rint(127 + dir_x * 127), 255);
    float dy = bound(0, rint(127 + dir_y * 127), 255);
    float dz = bound(0, rint(127 + dir_z * 127), 255);
    float force_byte = bound(0, rint(throw_force), 255);

    // Glass gibs use a separate event because they pick from a 7-submodel
    // glassgibs.mdl via setcustomskin (CSQC-only); all other debris share
    // the generic spawn path below.
    if (self.style == BREAKABLE_GLASS)
    {
        WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
        WriteByte(MSG_MULTICAST, CSQC_EVENT_GLASS_GIBS);
        WriteByte(MSG_MULTICAST, exclude);
        WriteCoord(MSG_MULTICAST, self.absmin_x);
        WriteCoord(MSG_MULTICAST, self.absmin_y);
        WriteCoord(MSG_MULTICAST, self.absmin_z);
        WriteCoord(MSG_MULTICAST, self.absmax_x);
        WriteCoord(MSG_MULTICAST, self.absmax_y);
        WriteCoord(MSG_MULTICAST, self.absmax_z);
        WriteByte(MSG_MULTICAST, self.cnt);
        WriteShort(MSG_MULTICAST, damage_scale);
        WriteByte(MSG_MULTICAST, throw_mode);
        WriteByte(MSG_MULTICAST, dx);
        WriteByte(MSG_MULTICAST, dy);
        WriteByte(MSG_MULTICAST, dz);
        WriteByte(MSG_MULTICAST, force_byte);
        multicast(center, MULTICAST_PVS);
        return;
    }

    // Non-glass debris: one-shot multicast, each client spawns its own
    // visual gibs. Keeps cosmetic-only state off the wire (no per-piece
    // entity deltas for 10+ s after each break).
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBRIS_GIBS);
    WriteByte(MSG_MULTICAST, exclude);
    WriteCoord(MSG_MULTICAST, self.absmin_x);
    WriteCoord(MSG_MULTICAST, self.absmin_y);
    WriteCoord(MSG_MULTICAST, self.absmin_z);
    WriteCoord(MSG_MULTICAST, self.absmax_x);
    WriteCoord(MSG_MULTICAST, self.absmax_y);
    WriteCoord(MSG_MULTICAST, self.absmax_z);
    WriteByte(MSG_MULTICAST, self.style);
    WriteByte(MSG_MULTICAST, self.cnt);
    WriteShort(MSG_MULTICAST, damage_scale);
    WriteShort(MSG_MULTICAST, self.custom_mdl_idx);  // 0 = use material default
    WriteByte(MSG_MULTICAST, self.alpha2 * 255);     // 0 = full opacity
    WriteByte(MSG_MULTICAST, throw_mode);
    WriteByte(MSG_MULTICAST, dx);
    WriteByte(MSG_MULTICAST, dy);
    WriteByte(MSG_MULTICAST, dz);
    WriteByte(MSG_MULTICAST, force_byte);
    multicast(center, MULTICAST_PVS);
};

// ============================================================
//  Callbacks
// ============================================================

void() BreakablePlayImpactSound =
{
    if (self.breakable_next_impact_sound > time)
        return;

    // Route through a CSQC multicast event so the attacker — who already
    // predicted and played the variant locally in CSQC_BulletImpact —
    // can skip the server-echoed copy. Everyone else in PVS picks a
    // variant themselves from the same BREAKABLE_* style byte, so the
    // sound still fires correctly for spectators / other players.
    // (The per-brush noise2 override is dropped in this path; attacker
    // hears a correct variant via prediction, remotes get the style
    // default. Rare enough to punt on exact parity.)
    float exclude = BreakableExcludeEntnum();

    // Brushes have origin '0 0 0' in most cases; use the bbox center so
    // pointsound on the client attenuates from the actual brush location.
    vector center = (self.absmin + self.absmax) * 0.5;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_BREAKABLE_IMPACT_SOUND);
    WriteByte(MSG_MULTICAST, exclude);
    WriteByte(MSG_MULTICAST, self.style);
    WriteCoord(MSG_MULTICAST, center_x);
    WriteCoord(MSG_MULTICAST, center_y);
    WriteCoord(MSG_MULTICAST, center_z);
    multicast(center, MULTICAST_PVS);

    self.breakable_next_impact_sound = time + 0.05;
};

void() BreakableDamaged =
{
    // Floor server-side HP to integer so the wire-format short matches
    // what we keep server-side.  solid_brush_SendEntity ships brush_health
    // via WriteShort, which truncates fractional values: a brush sitting at
    // 6.55 HP server-side reads as 6 on the client.  With sv_trust_clientbreak,
    // the client then predicts break (dmg=6.118 ≥ HP=6) and sends a claim,
    // but the server applies the same damage against 6.55 → 0.43 left, brush
    // alive, no BRUSH_DESTROY broadcast → client times out → rollback.
    // Flooring here keeps both sides in lockstep at every snapshot — the
    // brush breaks on the same shot count regardless of who computed the
    // damage.  Only func_breakable uses this on_damaged callback, so other
    // damageable entities (doors, buttons) keep their float-precision HP.
    self.health = floor(self.health);

    // Push the new health value to CSQC so the attacker's break prediction
    // in CSQC_BulletImpact sees fresh HP on the next shot. Bit 0 on
    // solid_brush_SendEntity is the "dirty" trigger — full payload resends
    // on every flip but payload is small (~60 B) and this only fires per
    // damaging shot landing on the brush, so bandwidth is negligible.
    self.SendFlags |= 1;
    BreakablePlayImpactSound();
};

// .touch handler installed on BREAKABLE_TOUCH-flagged brushes.
// Engine fires this whenever an entity collides with the brush;
// we filter for live players and route into the standard break
// path with the player as activator (so any `target` chain runs
// with the right context).  Subsequent touches are no-ops because
// func_breakable_break flips the brush to SOLID_NOT and the
// engine stops generating collision callbacks.
void() func_breakable_touch =
{
    if (other.classname != "player") return;
    if (other.is_dead)               return;
    if (self.breakable_broken)       return;

    // A NOCLIPPING PLAYER MUST NOT SHATTER THE MAP.  Half-Life cannot hit this
    // because noclip makes the player SOLID_NOT and BreakTouch is engine
    // dispatched; here the dispatcher is SV_CheckTouchTriggers, which a live
    // noclipper still runs (only DEAD players skip pmove).  Without this an
    // admin flying across the level breaks every touch brush he passes through,
    // and the speed gate below makes it worse rather than better because noclip
    // speed is high.  PM_MOVETYPE_NONE (frozen) is excluded for the same reason.
    //
    // 5 and 4 rather than the named constants: PM_MOVETYPE_NOCLIP and
    // PM_MOVETYPE_NONE are plain globals in shared/sh_pmove.qc, which compiles at
    // sv_progs.src:465, long after this file at :44 — QC forward-declares
    // functions but not constants.  The FIELD is fine (shared/sh_weapons.qc:28,
    // position 14).
    if (other.pm_movetype == 5 || other.pm_movetype == 4)
        return;

    // Unbreakable glass never sets .breakable_broken (func_breakable_break
    // returns early on it), so without this the arms below would re-enter the
    // whole break path every single frame the player is in contact with such a
    // brush.  Cheap per call, but unbounded.  This is HL's own !IsBreakable()
    // test (func_break.cpp:437, matUnbreakableGlass) and it gates BOTH arms.
    if (self.style == BREAKABLE_UNBREAKABLE_GLASS)
        return;

    // ---- ARM 1: SF_BREAK_TOUCH — "crashed through by a running player" ----
    //
    // CBreakable::BreakTouch (func_break.cpp:442-454):
    //     flDamage = pevToucher->velocity.Length() * 0.01;
    //     if (flDamage >= pev->health) { ...break... }
    // i.e. damage is speed/100, and the brush only goes if that reaches its
    // health.  Not optional now the handler is reachable: most corpus touch
    // breakables are health 1 (break at 100 u/s, which a walking player clears),
    // but the health 50/60/100 ones need a real impact — svencoop1's four
    // health-60 gruntsrepel* brushes and th_ep3_05's elev_rail2 are not meant to
    // shatter because somebody leaned on them.
    //
    // SPEED SOURCE.  `other.velocity` is the WRONG number here and reading it
    // was quietly defeating this whole arm.  HL dispatches BreakTouch from
    // inside the move, at the impact, so its velocity is the approach speed.
    // Ours is dispatched by SV_CheckTouchTriggers AFTER PM_PlayerMove, and
    // PM_SlideMove has already reflected the into-the-plane component out of
    // pm_velocity against this very brush — so a player sprinting head-on into
    // a pane arrived here reading near zero, and the harder he ran the more
    // completely the speed that should have broken it was erased first.
    // .pm_impact_speed is latched at the top of PM_PlayerMove for exactly this.
    //
    // Gate value: HL compares against the LIVE pev->health (func_break.cpp:446),
    // so a pane already shot down to 3 HP is crashable-through.  We cannot just
    // read self.health, because this class defaults a health-key-less brush to
    // 20 where HL leaves it at 0 and a 0-health brush is meant to shatter on any
    // contact (th_ep1_00's *69).  So: no authored health -> gate of 0; otherwise
    // track the live value.
    //
    // NOT ported: HL's `pOther->TakeDamage(pev, pev, flDamage/4, DMG_SLASH)` on
    // the player immediately afterwards.  This file's docstring promises break
    // on contact, not a mutual collision, and hurting the player for walking
    // through a health-1 pane is the sort of thing that gets noticed.
    if (self.spawnflags & BREAKABLE_TOUCH)
    {
        float gate = (self.breakable_touch_health <= 0) ? 0 : self.health;
        if (other.pm_impact_speed * 0.01 >= gate)
        {
            entity oldactivator = activator;
            activator = other;
            func_breakable_break();
            activator = oldactivator;
            return;
        }
    }

    // ---- ARM 2: SF_BREAK_PRESSURE — "broken by a player standing on it" ----
    //
    // func_break.cpp:456-472.  Two things about HL's version are easy to get
    // wrong and both matter:
    //
    //  1. The test is PURELY GEOMETRIC — `pevToucher->absmin.z >= pev->maxs.z - 2`,
    //     the toucher's feet at or above the brush top minus 2.  There is no
    //     FL_ONGROUND or groundentity test anywhere in it.
    //  2. It is a SEQUENTIAL `if`, not an `else` — a brush with both bits runs
    //     both arms in the same call, and 67 corpus brushes set both.
    //
    // absmax_z rather than maxs_z is a deliberate divergence: HL's pev->maxs.z
    // is model-relative, which agrees with world space only for a submodel with
    // no ORIGIN brush.  Three of the 122 corpus pressure brushes carry an
    // `origin` key, and for those absmax_z is right where the SDK's own field
    // would be wrong.
    if ((self.spawnflags & BREAKABLE_PRESSURE)
        && other.absmin_z >= self.absmax_z - 2)
    {
        BreakablePlayImpactSound();     // HL's DamageSound() — the creak first

        // ltime, NOT time.  This is a MOVETYPE_PUSH entity, and FTE schedules a
        // pusher's think against its OWN ltime clock (sv_phys.c), which for a
        // breakable never advances because nothing here ever sets nextthink —
        // so every func_breakable in the map sits at ltime 0 forever.  Writing
        // `time + delay` at t=240 would ask for a think 240 s of ltime away and
        // the tile would collapse minutes later, or never.  HL writes
        // `pev->nextthink = pev->ltime + m_flDelay` (func_break.cpp:469) for
        // precisely this reason.
        //
        // The zero-delay fudge is HL's too, complete with its own BUGBUG
        // comment at func_break.cpp:465-467.
        self.think     = func_breakable_break;
        self.nextthink = self.ltime + ((self.delay > 0) ? self.delay : 0.1);

        // HL's SetTouch(NULL) — stop re-arming the pending collapse every frame
        // the player keeps standing there.  SV_CheckTouchTriggers dispatches on
        // an identity test against func_breakable_touch, so clearing .touch
        // takes this brush out of the walk immediately.
        self.touch = __NULL__;
    }
};

// Use wrapper: a player pressing +use directly on a breakable is a
// common accident (mapper places a breakable adjacent to a button or
// door) — players shouldn't be able to delete map geometry by
// touching it.  Damage hits still break it (on_killed path), and
// Trigger_UseTargets-driven chain activation still breaks it
// (sv_use_is_player_direct is cleared inside Trigger_UseTargets so
// chained .use calls fall through this gate).
void() func_breakable_use =
{
    if (sv_use_is_player_direct)
        return;
    func_breakable_break();
};

void() func_breakable_break =
{
    entity break_activator;
    entity oldactivator;

    // Style 7 (UNBREAKABLE_GLASS) is a cosmetic glass panel that
    // never actually breaks — bullets produce glass impact FX via
    // the classify path, but the brush stays.  Single early-out
    // catches every activation source (damage, .use, trigger,
    // touch, scripted) so the gate doesn't have to be repeated at
    // each call site.
    if (self.style == BREAKABLE_UNBREAKABLE_GLASS)
        return;

    // Already broken — a self-referencing target chain (target == own
    // targetname, or two breakables aimed at each other) re-enters here via
    // Trigger_UseTargets -> func_breakable_use.  Guard AND mark broken
    // *before* firing the chain so the recursion ends after each brush breaks
    // once, instead of looping forever (runaway-loop crash).
    if (self.breakable_broken)
        return;
    self.breakable_broken = TRUE;

    // Save center for debris spawn before hiding
    vector center = (self.absmin + self.absmax) * 0.5;

    // Route the break sound through an attacker-exclude multicast so the
    // shooter (who predicted the break + sound locally via
    // CSQC_PredictBreakableBreak) doesn't double up with a ping-delayed
    // server echo. Remote clients each pick a variant from the style
    // byte and play at the brush center — same pattern the impact-sound
    // event uses. The map-editor noise1 override path is dropped here
    // (attacker's predicted variant is already correct; remote viewers
    // get the style default) — accept the drift for MVP since noise1
    // is rare in practice.
    float exclude = BreakableExcludeEntnum();

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_BREAKABLE_BREAK_SOUND);
    WriteByte(MSG_MULTICAST, exclude);
    WriteByte(MSG_MULTICAST, self.style);
    WriteCoord(MSG_MULTICAST, center_x);
    WriteCoord(MSG_MULTICAST, center_y);
    WriteCoord(MSG_MULTICAST, center_z);
    multicast(center, MULTICAST_PVS);

    BreakableSpawnDebris();

    if (self.switchshadstyle)
        lightstyle(self.switchshadstyle, "m");

    break_activator = activator;
    if (self.dmg_inflictor)
        break_activator = self.dmg_inflictor;

    oldactivator = activator;
    activator = break_activator;
    // SUB_UseTargets, not the two-arg walker: func_breakable inherits
    // Targetx in Sven's FGD, so `killtarget` and `delay` are real keys on
    // it and the bare walker silently drops both.  Measured: 21 of
    // pizza_ya_san1's 131 breakables carry a killtarget that never fired.
    SUB_UseTargets(self, break_activator, USE_TOGGLE);
    activator = oldactivator;

    // Wake any sleeping phys-drop weapons resting on / inside the
    // breakable's bbox so they actually fall when their support
    // disappears.  Without this, a drop that had settled on top of
    // the brush keeps its MOVETYPE_NONE sleep state (W_PhysDropSleep
    // sets that) and just hangs in mid-air after the brush is gone.
    //
    // Search radius is the bbox half-diagonal plus a small margin —
    // the bbox itself is already slightly inflated relative to the
    // visible brush, and the margin catches drops that are touching
    // the surface from outside (their origin sits one drop-radius
    // beyond the brush).  W_PhysDropWake is idempotent on already-
    // awake drops, so this is safe even if some of the matched
    // entities are mid-flight.
    {
        float wake_radius = vlen(self.maxs - self.mins) * 0.5 + 32;
        entity wake_e = findradius(center, wake_radius);
        while (wake_e)
        {
            if (wake_e.weapon && wake_e.weapon_physdrop_sleeping)
                W_PhysDropWake(wake_e);
            wake_e = wake_e.chain;
        }
    }

    // Tell clients to remove bullet holes AND the brush entity itself —
    // CSQC_EVENT_BRUSH_DESTROY handler (in cl_main.qc) removes both by
    // entnum, so the client no longer sees a ghost solid brush after the
    // server-side breakable is hidden.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_BRUSH_DESTROY);
    WriteFloat(MSG_MULTICAST, num_for_edict(self));
    multicast(center, MULTICAST_PVS);

    // Hide via broken flag rather than clearing the model. setmodel(self, "")
    // zeros modelindex and .mins/.maxs server-side; re-setting the model on
    // round reset wasn't propagating cleanly to already-networked clients
    // (brush came back solid but invisible). Keeping the model loaded and
    // just flipping the broken byte is reliable — client toggles
    // drawmask/solid based on the byte alone.
    self.solid = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.takedamage = DAMAGE_NO;
    self.breakable_broken = TRUE;
    self.SendFlags |= 1;

    // Sven's "Spawn On Break" pickup, dropped a little above the brush centre.
    //
    // LAST, and that ordering is load-bearing: the item is MOVETYPE_TOSS and
    // spawns inside the volume the crate occupied, so it has to be created
    // AFTER the brush goes SOLID_NOT or it starts the frame embedded in a
    // solid.  Everything above only reads self, so moving this to the end
    // costs nothing.
    if (self.spawnobject)
        Breakable_SpawnObject(center + '0 0 16', self.spawnobject);

    // Explode on break — HL's CBreakable::Die tail (func_break.cpp:752-755).
    //
    // LAST, and that ordering is the SDK's, not a convenience: Die() clears
    // pev->solid, fires its targets and creates the spawn object BEFORE
    // ExplosionCreate, so the blast's radius trace is not blocked by the brush
    // that produced it and the spawned pickup is already in the world to be
    // thrown.  Placing it above any of those would change who the explosion can
    // see.
    //
    // Explodable() is `ExplosionMagnitude() > 0` (func_break.h:49) and the FGD
    // default is 0, so a brush without the key is unaffected.  15 brushes across
    // 5 Sven hl_ maps carry it — hl_c07_a1's six 75s, hl_c07_a2's 2000 and two
    // 200s, hl_c11_a5's 200 — and until now every one of them broke silently.
    if (self.explodemagnitude > 0)
    {
        if (cvar("sv_debug_use"))
            print(sprintf("[breakable] \"%s\" detonating, magnitude %g at %v\n",
                          self.targetname, self.explodemagnitude, center));
        ExplosionCreate(center, self.explodemagnitude, self);
    }
};

// ============================================================
//  Round reset — restore all broken breakables
// ============================================================

void() BreakableResetAll =
{
    entity e = nextent(world);
    while (e)
    {
        if (e.classname == "func_breakable" && e.breakable_broken)
        {
            // Restore the brush
            setmodel(e, e.breakable_model);
            e.solid = SOLID_BSP;
            e.movetype = MOVETYPE_PUSH;
            e.health = e.max_health;
            e.breakable_broken = FALSE;
            e.breakable_next_impact_sound = 0;
            e.on_damaged = BreakableDamaged;
            e.use = func_breakable_use;
            e.on_killed = func_breakable_break;

            // Damageability rules (matches the spawn function):
            //   TRIGGER_ONLY or ONLY_EXPLOSION → DAMAGE_NO
            //   has targetname (no override flag exists anymore) → DAMAGE_NO
            //   otherwise → DAMAGE_YES
            if (e.spawnflags & (BREAKABLE_TRIGGER_ONLY | BREAKABLE_ONLY_EXPLOSION))
                e.takedamage = DAMAGE_NO;
            else if (e.targetname != "" && !(e.spawnflags & BREAKABLE_ALWAYS_SHOOTABLE))
                e.takedamage = DAMAGE_NO;
            else if (e.style == BREAKABLE_UNBREAKABLE_GLASS)
                e.takedamage = DAMAGE_NO;
            else
                e.takedamage = DAMAGE_YES;

            // Re-arm the contact handler on TOUCH / PRESSURE brushes, matching
            // the spawn-time gate.
            if ((e.spawnflags & (BREAKABLE_TOUCH | BREAKABLE_PRESSURE))
                && !(e.spawnflags & BREAKABLE_TRIGGER_ONLY))
                e.touch = func_breakable_touch;
            else
                e.touch = __NULL__;

            // Cancel any pending PRESSURE collapse.  A brush that was mid-creak
            // when the round reset would otherwise still fire its scheduled
            // break — the .touch re-arm above does not undo a queued think.
            e.think     = __NULL__;
            e.nextthink = 0;

            if (e.switchshadstyle)
                lightstyle(e.switchshadstyle, "a");

            // Force the engine to push a fresh baseline to every client.
            // `SendFlags |= 1` alone has been observed to not fire the
            // snapshot when the entity's delta state looks unchanged to
            // the engine between break and reset — so the client stays
            // on broken=1. Setting all bits forces a full resend.
            e.SendFlags = -1;
        }
        e = nextent(e);
    }

    // func_pushable rides this file's break pipeline but owns its own reset —
    // it also has to be shoved back to where the round started.
    FuncPushable_ResetAll();
};

// ============================================================
//  Spawn function — classname "func_breakable" in map editor
// ============================================================

/*QUAKED func_breakable (0 .5 .8) ? TRIGGER_ONLY TOUCH ONLY_EXPLOSION x x x x x INSTANT_CROWBAR
A visible brush that can be destroyed by shooting it.
TRIGGER_ONLY (1):     brush is bullet-proof, breaks only when its
                      targetname is fired.
TOUCH (2):            brush breaks when a player physically touches
                      it (HL glass-pane behavior).
ONLY_EXPLOSION (4):   brush takes radius-explosion damage only.
INSTANT_CROWBAR (256): any melee weapon hit one-shots this brush.
If it has a targetname, it isn't directly shootable. Use "target"
to fire something on break.

Keys:
  "health"     Hit points (default 20)
  "cnt"        Number of debris pieces (default 6, glass default 15)
  "material"   0=Glass 1=Wood 2=Metal 3=Flesh 4=CinderBlock 5=CeilingTile
                6=Computer 7=UnbreakableGlass 8=Rocks
  "explosion"  0=random gib throw, 1=directional (along damage vector)
  "mdl"        Custom debris model (omit for automatic material-based selection)
  "noise1"     Break sound override
  "noise2"     Impact sound override
  "alpha2"     Alpha for spawned debris
  "renderamt"  GoldSrc-style brush opacity, 0..255 (overrides "alpha" if both set)
  "switchshadstyle"  Lightstyle index to toggle on break
*/
void() func_breakable =
{
    // MUST be first — everything below reads .spawnflags.
    Break_NormaliseFlags();

    // CBreakable::Spawn stashes `m_angle = pev->angles.y` and then clears it
    // (func_break.cpp, immediately after the takedamage branch) — the yaw is the
    // GIB DIRECTION, not a rotation of the brush, and leaving it set is the same
    // bug the DONT_MOVE button had: a GoldSrc submodel with no ORIGIN brush carries
    // absolute bounds with .origin '0 0 0', so World_LinkEdict rotates its box about
    // the WORLD origin and the brush lands hundreds of units away.
    //
    // All three axes go, not just HL's yaw.  Nothing in this file reads .angles (the
    // gib spread is radial here), and of the 41 corpus breakables that carry a stray
    // angles key with no origin brush, 3 set pitch or roll — which HL leaves in place
    // and which displaces them just as badly.  Zeroing more than HL costs nothing
    // because a func_breakable never rotates in either engine.
    self.angles = '0 0 0';

    setmodel(self, self.model);
    self.breakable_model = self.model;   // save for round reset
    self.solid = SOLID_BSP;
    self.movetype = MOVETYPE_PUSH;
    self.on_damaged = BreakableDamaged;
    self.use = func_breakable_use;
    self.on_killed = func_breakable_break;
    self.breakable_next_impact_sound = 0;

    // GoldSrc-convention "material" key → internal `style` field.
    // Map editors save the breakable material under "material",
    // but `style` is a reserved Quake1 lightstyle field so we
    // can't bind to that name directly via map parsing.  Bridge
    // here: copy material onto style so the rest of the breakable
    // pipeline (sound/debris/decal switches) keeps working off
    // self.style.  Mappers writing the legacy "style" key still
    // win — material defaults to 0 if absent and the explicit
    // style stays untouched.
    if (self.material != 0)
        self.style = self.material;

    // Phys-drop ODE collision filter (see comment above).  OR rather
    // than assign so anything else upstream that touched dim_hit is
    // preserved.
    self.dimension_hit = self.dimension_hit | PHYSDROP_DIM;

    // ODE collision filter — phys drops have dim_solid=PHYSDROP_DIM
    // (256) and dim_hit=255|256.  The engine's nearCallback
    // (com_phys_ode.c:2625) requires both directions of the bitmask
    // intersect.  Default brushwork dim_hit is 255, which doesn't
    // include PHYSDROP_DIM, so phys.dim_solid (256) AND brush.dim_hit
    // (255) = 0 → contact rejected, phys drop tunnels through.
    // Setting the OR here at spawn time is the timing-safe fix; the
    // older BrushSyncODE deferred pass only ran once at first
    // ODE-loaded StartFrame and was vulnerable to race conditions
    // around when ODE attached vs when entities spawned.  ODE itself
    // doesn't need to be loaded at this point — these are plain QC
    // field assignments.  Filter check passes regardless of when ODE
    // first reads the field.

    // Replicate to CSQC so the local shooter's bullet trace can
    // identify this entity (and read .style for per-material
    // particle effects) without a server round-trip.
    //
    // BrushSync_ApplyRenderKeys handles the full rendermode +
    // renderamt + rendercolor → alpha / colormod / effects
    // translation.  Defined in sv_brushsync.qc which compiles
    // after this file.
    BrushSync_ApplyRenderKeys();
    self.is_aaatrigger = Brush_IsAATrigger();
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = solid_brush_SendEntity;
    self.SendFlags = 1;

    // noise1/noise2 are optional map-editor overrides for break/impact sounds.
    // If not set, sounds are randomized at play time by BreakableRandomBreakSound
    // and BreakableRandomImpactSound (all variants precached in sh_customdefs.qc).

    if (self.style == BREAKABLE_GLASS)
        self.cnt = BreakableDefaultFloat(self.cnt, 15);
    else
        self.cnt = BreakableDefaultFloat(self.cnt, 6);

    if (self.noise1 && self.noise1 != "") precache_sound(self.noise1);
    if (self.noise2 && self.noise2 != "") precache_sound(self.noise2);
    if (self.mdl && self.mdl != "")
    {
        precache_model(self.mdl);
        self.custom_mdl_idx = getmodelindex(self.mdl);
    }
    else
        self.custom_mdl_idx = 0;

    // Precache debris models
    precache_model("models/gibs/debris1.mdl");
    precache_model("models/gibs/debris2.mdl");
    precache_model("models/gibs/debris3.mdl");
    precache_model("models/gibs/woodgib1.mdl");
    precache_model("models/gibs/woodgib2.mdl");
    precache_model("models/gibs/woodgib3.mdl");

    // Only when the brush actually detonates — no reason to pull the explosion
    // sprite and its three samples onto every map that has a crate.
    if (self.explodemagnitude > 0)
        Explosion_Precache();

    // Latch the AUTHORED health before the default is applied.  HL's
    // CBreakable::Spawn has no such clamp, so a brush with no health key sits at
    // pev->health 0 and CBreakable::BreakTouch's `flDamage >= pev->health` is
    // trivially true — it breaks on any contact at all.  The touch speed gate
    // has to compare against that raw value, or the three corpus brushes with no
    // health key would need 2000 u/s to break something HL breaks by leaning on.
    self.breakable_touch_health = self.health;
    if (self.health <= 0)
        self.health = 20;
    self.max_health = self.health;

    if (self.switchshadstyle)
        lightstyle(self.switchshadstyle, "a");

    // Damageability rules:
    //   TRIGGER_ONLY        → bullet/explosion-proof (only .use breaks)
    //   ONLY_EXPLOSION      → bullet-proof, W_RadiusExplode override
    //                          still routes radius damage in
    //   has targetname      → DAMAGE_NO (chain target — break via .use)
    //   UNBREAKABLE_GLASS   → DAMAGE_NO regardless (cosmetic)
    //   otherwise           → DAMAGE_YES (default shootable breakable)
    // Impact FX still fire on DAMAGE_NO brushes because
    // W_ImpactEffect classifies on classname, not takedamage.
    if (self.spawnflags & (BREAKABLE_TRIGGER_ONLY | BREAKABLE_ONLY_EXPLOSION))
        self.takedamage = DAMAGE_NO;
    else if (self.targetname != "" && !(self.spawnflags & BREAKABLE_ALWAYS_SHOOTABLE))
        self.takedamage = DAMAGE_NO;
    else if (self.style == BREAKABLE_UNBREAKABLE_GLASS)
        self.takedamage = DAMAGE_NO;
    else
        self.takedamage = DAMAGE_YES;

    // BREAKABLE_TOUCH and BREAKABLE_PRESSURE both install a .touch callback that
    // routes player collisions into the standard break path.
    //
    // TRIGGER_ONLY suppresses BOTH, exactly as HL does: CBreakable::Spawn
    // installs BreakTouch on everything and then clears it again for
    // trigger-only brushes (func_break.cpp:167-169), so a trigger-only brush is
    // inert to contact of every kind.  This used to be a documented divergence
    // ("a TOUCH+TRIGGER_ONLY brush is bullet-proof but breaks when the player
    // walks into it"); it costs one clause to be right, and the corpus has one
    // brush that sets 1|4 and none that set 1|2.
    //
    // HL gates on nothing else — the flag tests live inside BreakTouch — but
    // enrolling only the two flags that can actually do something keeps the list
    // that SV_CheckTouchTriggers walks per player per frame short.
    if ((self.spawnflags & (BREAKABLE_TOUCH | BREAKABLE_PRESSURE))
        && !(self.spawnflags & BREAKABLE_TRIGGER_ONLY))
    {
        self.touch = func_breakable_touch;
        // ...and put it somewhere that will actually CALL that handler.  See the
        // note on breakable_touch_list, and the third arm of
        // SV_CheckTouchTriggers (sv_use.qc) which is the only thing that dispatches it.
        self.breakable_touch_next = breakable_touch_list;
        breakable_touch_list      = self;
    }
};
