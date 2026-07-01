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
// Defined in sv_weapons.qc, which compiles after this file.
void(entity drop_ent) W_PhysDropWake;
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

void() BreakableSpawnDebris =
{
    float damage_scale = max(self.max_health, 20);
    vector center      = (self.absmin + self.absmax) * 0.5;

    // Attacker-exclude entnum — mirrors the sound events. The shooter's
    // CSQC already spawned matching gibs in CSQC_PredictBreakableBreak,
    // so skipping them on the server broadcast prevents doubled debris.
    // 0 means "no predictor" (explosion, world trigger, etc.) → send to
    // everyone.
    float exclude = 0;
    if (self.dmg_inflictor)
        exclude = num_for_edict(self.dmg_inflictor);

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
    float exclude = 0;
    if (self.dmg_inflictor)
        exclude = num_for_edict(self.dmg_inflictor);

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

    entity oldactivator = activator;
    activator = other;
    func_breakable_break();
    activator = oldactivator;
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
    float exclude = 0;
    if (self.dmg_inflictor)
        exclude = num_for_edict(self.dmg_inflictor);

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
    Trigger_UseTargets(self, break_activator);
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

            // Re-arm the touch-break handler on TOUCH brushes.
            if (e.spawnflags & BREAKABLE_TOUCH)
                e.touch = func_breakable_touch;
            else
                e.touch = __NULL__;

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

    // BREAKABLE_TOUCH installs a .touch callback that routes player
    // collisions into the standard break path.  Independent from
    // takedamage — a TOUCH+TRIGGER_ONLY brush is bullet-proof but
    // breaks when the player walks into it.
    if (self.spawnflags & BREAKABLE_TOUCH)
        self.touch = func_breakable_touch;
};
