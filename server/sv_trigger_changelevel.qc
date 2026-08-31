//
//  sv_trigger_changelevel.qc  –  HL/GoldSrc trigger_changelevel
//
//  Brush volume that issues a server `changelevel <map>` when a
//  player touches it (or when another entity triggers its .use, if
//  the USE_ONLY spawnflag is set).
//
//  Keys (HL parity):
//    "map"          — basename of the next map to load.
//    "landmark"     — info_landmark targetname.  Stored for future
//                     landmark-relative spawn handling; this version
//                     just changes level (players spawn at the new
//                     map's info_player_start / spawn points).
//    "changetarget" — entity to trigger in the next map.  Stored;
//                     cross-map dispatch is out of scope here (would
//                     need globals/savegame state plumbing).
//    "changedelay"  — delay before firing changetarget in the next
//                     map.  Stored; same caveat as above.
//    "targetname"   — name for being triggered externally.
//
//  Spawnflags (HL parity):
//    1   NO_INTERMISSION — documented as unused in HL.  We ignore it.
//    2   USE_ONLY        — disable touch; only fire via .use.
//
//  Scope choice — the user wants compatibility ("just so it works and
//  loads the next map").  We do NOT implement:
//    - Landmark-relative player position carryover (needs save/restore
//      state across map boundaries).
//    - changetarget firing in the next map (needs globals).
//    - trigger_transition coupling.
//  All those keys are parsed without errors so .bsp entdata loads
//  cleanly; the level-change itself works.
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;  // sv_triggers.qc
// Sven InventoryRules gate - defined in sv_item_inventory.qc (position 265), which
// compiles after this file; the KEY FIELDS it reads live in sv_customdefs.qc for
// exactly that reason.
float(entity rules, entity who) Inv_Gate;                            // sv_item_inventory.qc
float(entity rules) Inv_HasRules;                                    // sv_item_inventory.qc
float(string landmark_name) Trigger_Transition_PlayerInside;    // sv_trigger_transition.qc

// HL bit layout — keep so .bsp entdata decodes the spawnflags correctly.
const float SF_CHANGELEVEL_NO_INTERMISSION = 1;   // unused
const float SF_CHANGELEVEL_USE_ONLY        = 2;

// Per-map keys read from .bsp entdata.  Engine populates these
// fields automatically when the entdata block lists matching field
// names (FTE QC treats `.string` fields as map-keyable).
// `target` / `targetname` are already universal globals.
.string  map;
.string  landmark;
.string  changetarget;
.float   changedelay;

// Latch — once we've queued the level change, ignore further
// touches / uses so a player who lingers in the trigger doesn't
// fire `changelevel` repeatedly (which would warn the engine
// about an already-pending command).
.float   changelevel_fired;

// Sanity-check the map string.  Reject path traversal, absolute
// paths, and obviously-bad characters that could escape the
// `changelevel ` command.  Returns 1 if the name is safe to send.
float(string name) ChangeLevel_NameIsSafe =
{
    if (name == "") return 0;
    if (strlen(name) > 64) return 0;                // basename only
    if (strstrofs(name, "/",  0) >= 0) return 0;
    if (strstrofs(name, "\\", 0) >= 0) return 0;
    if (strstrofs(name, "..", 0) >= 0) return 0;
    if (strstrofs(name, "\"", 0) >= 0) return 0;
    if (strstrofs(name, "\n", 0) >= 0) return 0;
    if (strstrofs(name, ";", 0) >= 0) return 0;     // command separator
    return 1;
};

// Single fire path — both touch and use route through here.
// Issue a changelevel that STAYS IN THE SAME GAME.
//
// This is the fix for "the textures go to hell after a level transition", and the
// cause is not the renderer - it is which copy of a WAD the next map resolves.
//
// The create-server menu loads a map as `map "@<spec>/<name>"`, where <spec> names
// the mounted game.  SV_Map_f stashes that as sv_mappreferhint, SV_SpawnServer
// biases the worldmodel AND the texture WAD lookups to it, and publishes it as the
// "*mappref" serverinfo key so connecting clients agree.  A bare `changelevel foo`
// deliberately CLEARS that hint (sv_ccmds.c:751 says so, and naming changelevel as
// one of the paths that must not inherit a stale one) - so the next map's wads are
// resolved by plain mount priority instead.
//
// That matters because the names collide and the CONTENT DOES NOT.  Measured on
// this install: halflife.wad exists in Half-Life/valve, Half-Life/bshift and Sven
// Co-op/svencoop, all three exactly 37,914,096 bytes, and valve's MD5 differs from
// the other two.  Same name, same size, different texture data - so a map that
// loaded its wad from one game and then gets the other after a transition renders
// every brush face with the wrong pixels.  Half-Life's own chapter transitions
// (hl_c01_a1 -> a2) and the Opposing Force maps are exactly the maps that hit it.
//
// So: re-attach the spec the current map was loaded with.  The '@' form is
// explicitly exempted from the package-manager's "blocked from gamecode" guard
// (sv_ccmds.c:817 tests `*mangled != '@'`), so QC is allowed to use it.  Empty
// hint - a map started with a plain name - falls through to the old behaviour and
// changes nothing.
void(string nextmap) ChangeLevel_Issue =
{
    string spec = infokey(world, "*mappref");

    if (spec != "" && spec)
        localcmd(sprintf("changelevel \"@%s/%s\"\n", spec, nextmap));
    else
        localcmd(sprintf("changelevel %s\n", nextmap));
};

void() trigger_changelevel_fire =
{
    if (self.changelevel_fired) return;
    if (!ChangeLevel_NameIsSafe(self.map))
    {
        // Bad / missing map field — emit a server warning and
        // latch so we don't spam.  No client-visible effect.
        dprint(sprintf("trigger_changelevel: refusing unsafe map \"%s\"\n",
                       self.map));
        self.changelevel_fired = 1;
        return;
    }

    // trigger_transition gate — if our .landmark names a transition
    // volume, a player must be inside it.  Helper returns 1 ("allow")
    // when landmark is "" or no matching trigger_transition exists,
    // so the common no-gate case is unaffected.  DON'T latch on
    // failure — the player may walk into the transition area and
    // re-trigger us a moment later (covers the airlock / elevator
    // door-close case where the door fires us repeatedly).
    if (!Trigger_Transition_PlayerInside(self.landmark))
        return;

    self.changelevel_fired = 1;
    // Optional .target — fire it BEFORE issuing changelevel so any
    // map-end-cleanup logic gets to run.  Matches the HL behaviour
    // of trigger_changelevel firing its target chain on level exit.
    if (self.target != "")
        SUB_UseTargets(self, other, USE_TOGGLE);
    ChangeLevel_Issue(self.map);
};

void() trigger_changelevel_touch =
{
    if (self.spawnflags & SF_CHANGELEVEL_USE_ONLY)
        return;
    if (other.classname != "player")
        return;
    // Sven's InventoryRules — "Prevent level from changing".  The canonical use
    // is "you cannot leave without the objective in your hands".
    if (!Inv_Gate(self, other))
        return;
    trigger_changelevel_fire();
};

void() trigger_changelevel_use =
{
    trigger_changelevel_fire();
};

/*QUAKED trigger_changelevel (.5 .5 .5) ? NO_INTERMISSION USE_ONLY
Brush volume that issues `changelevel <map>` when a player touches
it (touch is disabled by USE_ONLY spawnflag).

"map"          basename of the next map to load (e.g. "c3l5")
"landmark"     parsed but unused (landmark-relative spawn not implemented)
"changetarget" parsed but unused (cross-map target dispatch not implemented)
"changedelay"  parsed but unused
"target"       fired once on level exit (before changelevel issues)
"targetname"   set this if you want to be .use-triggered
*/
void() trigger_changelevel =
{
    if (!self.model)
    {
        // Point-entity edge case — uncommon for trigger_changelevel
        // (HL uses brush ents) but don't crash.  Without a brush we
        // can still respond to .use; touch is impossible.
        self.solid = SOLID_NOT;
        self.use   = trigger_changelevel_use;
        return;
    }
    setmodel(self, self.model);
    self.effects   |= EF_NODRAW;       // hide the trigger texture
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_TRIGGER;
    self.touch      = trigger_changelevel_touch;
    self.use        = trigger_changelevel_use;
};
