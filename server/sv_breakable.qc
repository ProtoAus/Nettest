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
const float BREAKABLE_ALWAYS_SHOOTABLE  = 2;
const float BREAKABLE_ONLY_EXPLOSION    = 4;

// --- Material styles (set via "style" key in map editor) ---
const float BREAKABLE_CONCRETE   = 0;
const float BREAKABLE_ROCK       = 1;
const float BREAKABLE_METAL      = 2;
const float BREAKABLE_WOOD       = 3;
const float BREAKABLE_GLASS      = 4;
const float BREAKABLE_FLESH      = 5;
const float BREAKABLE_MACHINE    = 6;
const float BREAKABLE_CIRCUIT    = 7;

// --- Debris skin indices (match texture order in debris1/2/3.mdl) ---
// skin 0=concrete, 1=rock, 2=metal, 3=wood, 4=glass, 5=flesh, 6=machine, 7=circuit

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

// --- Forward declarations ---
void(entity caller, entity triggerer) Trigger_UseTargets;

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

    if (mat == BREAKABLE_GLASS)
    {
        if (v < 0.333) return "sounds/debris/break_glasshl1.wav";
        if (v < 0.666) return "sounds/debris/break_glasshl2.wav";
        return "sounds/debris/break_glasshl3.wav";
    }
    if (mat == BREAKABLE_ROCK || mat == BREAKABLE_CONCRETE)
    {
        if (v < 0.5) return "sounds/debris/break_concretehl1.wav";
        return "sounds/debris/break_concretehl2.wav";
    }
    if (mat == BREAKABLE_WOOD)
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
    if (mat == BREAKABLE_CIRCUIT)
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
    // Metal, machine fallback
    if (v < 0.5) return "sounds/debris/break_metalhl1.wav";
    return "sounds/debris/break_metalhl2.wav";
};

// Returns a random impact sound for the current material (called at play time)
string(float mat) BreakableRandomImpactSound =
{
    float v = random();

    if (mat == BREAKABLE_GLASS)
    {
        if (v < 0.25) return "sounds/debris/impact_glasshl1.wav";
        if (v < 0.50) return "sounds/debris/impact_glasshl2.wav";
        if (v < 0.75) return "sounds/debris/impact_glasshl3.wav";
        return "sounds/debris/impact_glasshl4.wav";
    }
    if (mat == BREAKABLE_ROCK || mat == BREAKABLE_CONCRETE)
    {
        if (v < 0.333) return "sounds/debris/impact_concretehl1.wav";
        if (v < 0.666) return "sounds/debris/impact_concretehl2.wav";
        return "sounds/debris/impact_concretehl3.wav";
    }
    if (mat == BREAKABLE_WOOD)
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
    // Push the new health value to CSQC so the attacker's break prediction
    // in CSQC_BulletImpact sees fresh HP on the next shot. Bit 0 on
    // solid_brush_SendEntity is the "dirty" trigger — full payload resends
    // on every flip but payload is small (~60 B) and this only fires per
    // damaging shot landing on the brush, so bandwidth is negligible.
    self.SendFlags |= 1;
    BreakablePlayImpactSound();
};

void() func_breakable_break =
{
    entity break_activator;
    entity oldactivator;

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
            e.use = func_breakable_break;
            e.on_killed = func_breakable_break;

            if (!(e.spawnflags & BREAKABLE_ONLY_EXPLOSION)
                && (e.targetname == "" || (e.spawnflags & BREAKABLE_ALWAYS_SHOOTABLE)))
                e.takedamage = DAMAGE_YES;
            else
                e.takedamage = DAMAGE_NO;

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

/*QUAKED func_breakable (0 .5 .8) ? NO_MONSTERS ALWAYS_SHOOTABLE ONLY_EXPLOSION
A visible brush that can be destroyed by shooting it.
If it has a targetname, it won't be directly shootable unless
ALWAYS_SHOOTABLE is set. Use "target" to fire something on break.

Keys:
  "health"  Hit points (default 20)
  "cnt"     Number of debris pieces (default 6, glass default 15)
  "style"   Material: 0=concrete, 1=rock, 2=metal, 3=wood, 4=glass, 5=flesh, 6=machine, 7=circuit
  "mdl"     Custom debris model (omit for automatic material-based selection)
  "noise1"  Break sound override
  "noise2"  Impact sound override
  "alpha2"  Alpha for spawned debris
  "switchshadstyle"  Lightstyle index to toggle on break
*/
void() func_breakable =
{
    setmodel(self, self.model);
    self.breakable_model = self.model;   // save for round reset
    self.solid = SOLID_BSP;
    self.movetype = MOVETYPE_PUSH;
    self.on_damaged = BreakableDamaged;
    self.use = func_breakable_break;
    self.on_killed = func_breakable_break;
    self.breakable_next_impact_sound = 0;

    // Replicate to CSQC so the local shooter's bullet trace can
    // identify this entity (and read .style for per-material
    // particle effects) without a server round-trip.
    if (self.alpha <= 0)
        self.alpha = 1;
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

    if (!(self.spawnflags & BREAKABLE_ONLY_EXPLOSION)
        && (self.targetname == "" || (self.spawnflags & BREAKABLE_ALWAYS_SHOOTABLE)))
        self.takedamage = DAMAGE_YES;
    else
        self.takedamage = DAMAGE_NO;
};
