// ===========================================================================
//  sv_mapglobals.qc — cross-map persistent state
//     func_global            Sven/kmkz 50-slot flag store, shared by a series
//     trigger_save/_load     Sven's named value store, keyed by level
// ===========================================================================
//
// Half-Life keeps globals in the savegame globalstate table and they survive a
// level change.  This tree had no equivalent at all — sv_goldsrc_compat.qc says
// so where env_global is defined — so a campaign that remembers anything across
// its maps could not work here.  Hazardous Course 2 is exactly that: 74
// func_globals across 17 maps, read by 64 trigger_conditions.
//
// TWO STORES, ONE FILE EACH.
//
//   func_global  is 50 numbered on/off slots shared by every map in a "series"
//                (its map_series key).  Sven's kmkz implementation persists them
//                to a text file, so progress survives a server restart, and this
//                mirrors that.
//
//   trigger_save is a named string value, tagged with the level that saved it;
//                trigger_load reads it back on a later map.  HC2 carries the
//                Normal/Extreme difficulty choice across all 20 maps this way.
//
// WHY A FILE AND NOT JUST QC GLOBALS.  Because a QC global array does NOT
// survive a changelevel, and this comment used to say it did.
//
// SV_SpawnServer calls PR_Deinit() unconditionally — engine/server/sv_init.c:945,
// inside the function at :839 — so every QC global is destroyed on every map
// load, changelevel included.  Measured 2026-08-19 with a table printed on the
// way out of one map and on the way into the next: 4 entries became 0.
//
// So the file is not the "other half" that adds restart survival on top of an
// already-working in-memory carry.  It is the ENTIRE cross-map mechanism, and
// hc2_a1's "21 scientists collected" hub works because of it and only because of
// it.  Anything that needs to outlive a map here needs a file; see
// server/sv_globalstate.qc, which learned this the same way.
//
// The writes are tiny (50 short lines) and happen only when a value actually
// changes, which over a whole HC2 run is a few dozen times.
//
// ---------------------------------------------------------------------------

// map_series: which store a func_global belongs to.  Undeclared until now, so
// all 74 HC2 placements were dropping it.
.string map_series;

// trigger_load's two extra keys.  Declared LOWERCASE on purpose: the maps spell
// them "m_iszLevelName" / "m_iszTrigger", and GoldSrc_TryCaseFoldedField
// (sv_multi_manager.qc) folds a missed key to lower case and retries, so one
// lowercase declaration serves both spellings.  Declaring the CamelCase form
// instead would bind Hammer's spelling and silently miss every other compiler's.
.string m_iszlevelname;
.string m_isztrigger;

void() FuncGlobal_SelfTest;     // defined below; called from FuncGlobal_Report

const float MG_SLOTS = 50;

float  mg_state[MG_SLOTS];
string mg_series;           // strzone'd; the series currently in mg_state
float  mg_have_series;      // mg_series holds a real (possibly zoned) value
float  mg_reported;         // census line is one-shot per map
float  mg_backup[MG_SLOTS]; // self-test snapshot, so a test cannot eat real progress

// ---------------------------------------------------------------------------
// Named value store for trigger_save / trigger_load.
//
// The prefix is "msave_", not "ms_", and that is not cosmetic.  QC has ONE
// global namespace across every compilation unit and fteqcc does not warn when
// two files declare the same global — it silently merges them.  This store was
// written as ms_* first and its ms_loaded latch merged with the material-sound
// table's ms_loaded (shared/sh_matsounds.qc:59), which is set to 1 during map
// load.  The result was that trigger_load believed the file had already been
// read, never read it, and every saved value came back missing — with no
// warning at compile time and no error at runtime.
//
// Check a new global's name against the tree before adding one.
// ---------------------------------------------------------------------------
const float MSAVE_MAX = 64;

string msave_level[MSAVE_MAX];
string msave_name[MSAVE_MAX];
string msave_val[MSAVE_MAX];
float  msave_count;
float  msave_loaded;

// ---------------------------------------------------------------------------
// Paths.  cfg/ is used because it is the one directory this tree already
// demonstrably writes into (SV_WriteServerConfigFile), so it needs no creation
// step and no guessing about the gamedir layout.
// ---------------------------------------------------------------------------
string(string series) MapGlobal_Path =
{
    if (series == "" || series == __NULL__)
        return "cfg/mapglobals_default.txt";
    return sprintf("cfg/mapglobals_%s.txt", series);
};

float() MapGlobal_PersistEnabled =
{
    // NOT a plain cvar() test, and the difference is load-bearing.  cvar() reads
    // 0 for a name that has not been registered yet, and both of this file's
    // early callers run during map load — func_global's spawn and the
    // trigger_auto -> trigger_load at t=0 — which can be ahead of CVar_Init.  A
    // plain test therefore reported "persistence off" for exactly the two calls
    // that need it, and a saved value silently failed to come back.
    //
    // So: absent means enabled (the registered default is 1 anyway), and only an
    // explicit 0 disables.
    if (cvar_string("sv_mapglobals_persist") == "")
        return TRUE;
    return cvar("sv_mapglobals_persist") != 0;
};

// ---------------------------------------------------------------------------
// Load / save the 50-slot array.
//
// File format mirrors kmkz's so the two are recognisably the same thing:
//     global000=0
//     global001=1
// Parsing is by '=' rather than by fixed column so a hand-edited file with a
// two-digit index still reads.
// ---------------------------------------------------------------------------
void(string series) MapGlobal_LoadFile =
{
    filestream f;
    string     line;
    float      eq, idx, i;

    i = 0;
    while (i < MG_SLOTS)
    {
        mg_state[i] = 0;
        i = i + 1;
    }

    // Read is ungated, for the reason MapSave_LoadFile spells out: the persist
    // cvar governs writes.
    f = fopen(MapGlobal_Path(series), FILE_READ);
    if (f < 0)
        return;                      // no file yet — everything starts off

    line = fgets(f);
    while (line)
    {
        // Strip a trailing CR so a file written on Windows reads on Linux.
        float n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
            line = substring(line, 0, n - 1);

        eq = strstrofs(line, "=", 0);
        if (eq > 6 && substring(line, 0, 6) == "global")
        {
            idx = stof(substring(line, 6, eq - 6));
            if (idx >= 0 && idx < MG_SLOTS)
                mg_state[idx] = (stof(substring(line, eq + 1, -1)) != 0);
        }
        line = fgets(f);
    }
    fclose(f);
};

void() MapGlobal_SaveFile =
{
    filestream f;
    float      i;

    if (!MapGlobal_PersistEnabled() || !mg_have_series)
        return;

    f = fopen(MapGlobal_Path(mg_series), FILE_WRITE);
    if (f < 0)
    {
        print(sprintf("[func_global] cannot write %s — progress will not "
                      "survive a restart this session\n", MapGlobal_Path(mg_series)));
        return;
    }

    for (i = 0; i < MG_SLOTS; i = i + 1)
    {
        if (i < 10)
            fputs(f, sprintf("global00%g=%g\n", i, mg_state[i]));
        else
            fputs(f, sprintf("global0%g=%g\n", i, mg_state[i]));
    }
    fclose(f);
};

// Make sure mg_state holds `series`.  A no-op for every func_global after the
// first on a map, and across a whole campaign (the series never changes).
void(string series) MapGlobal_Ensure =
{
    if (mg_have_series && mg_series == series)
        return;

    if (mg_have_series && mg_series != "")
        strunzone(mg_series);

    mg_series      = strzone(series);
    mg_have_series = TRUE;
    MapGlobal_LoadFile(series);
};

float(float idx) MapGlobal_Get =
{
    if (idx < 0 || idx >= MG_SLOTS)
        return 0;
    return mg_state[idx];
};

void(float idx, float v) MapGlobal_Set =
{
    if (idx < 0 || idx >= MG_SLOTS)
        return;
    if (mg_state[idx] == v)
        return;                      // no change, no write
    mg_state[idx] = v;
    MapGlobal_SaveFile();
};

// ---------------------------------------------------------------------------
// func_global
//
// Keys (all from kmkz's func_global.as, which is the authority):
//   netname     "globalNNN", a 3-digit slot index — or the literal "!reset"
//   map_series  which store this belongs to
//   health      the live state, 0 or 1.  This is the ONLY thing map logic reads:
//               64 of HC2's trigger_conditions poll `health == 1` on one of
//               these, which is why the state has to live in a plain field
//               rather than a private one.
//
// Use types:  ON set 1 · OFF set 0 · TOGGLE flip · SET (or unset) reload
//
// It fires no target chain — the AngelScript does not, and neither does this.
// ---------------------------------------------------------------------------
float(entity e) FuncGlobal_Index =
{
    string nm = e.netname;
    float  n  = strlen(nm);

    if (n < 3)
        return -1;
    return stof(substring(nm, n - 3, 3));
};

// ---------------------------------------------------------------------------
// Push the store back onto every live func_global that reads a given slot.
//
// This is NOT optional bookkeeping.  The 64 trigger_conditions do not read the
// store — they poll `.health` on the entity — so any path that changes the array
// without touching the entities leaves every reader looking at a stale value.
// "!reset" is exactly that path: it zeroes 50 slots at once and would otherwise
// appear to do nothing at all.
//
// It also covers the case of two func_globals sharing one slot, which HC2 does
// on purpose — hc2_c2 names global043 "has_rpg" while hc2_s1 names it
// "rpg_global", and within hc2_a1 several slots are read by one entity and
// written by another.
// ---------------------------------------------------------------------------
void(float idx) MapGlobal_Resync =
{
    entity e = find(world, classname, "func_global");
    while (e)
    {
        if (e.netname != "!reset" && FuncGlobal_Index(e) == idx)
            e.health = MapGlobal_Get(idx);
        e = find(e, classname, "func_global");
    }
};

void() MapGlobal_ResyncAll =
{
    entity e = find(world, classname, "func_global");
    while (e)
    {
        if (e.netname != "!reset")
            e.health = MapGlobal_Get(FuncGlobal_Index(e));
        e = find(e, classname, "func_global");
    }
};

// The "!reset" arm, split out so the spawn path can reach it without going
// through func_global_use and its sub_use_type read.
void(entity fg) FuncGlobal_ResetAll =
{
    float i;

    for (i = 0; i < MG_SLOTS; i = i + 1)
        mg_state[i] = 0;
    MapGlobal_SaveFile();
    MapGlobal_ResyncAll();
    fg.health = 0;

    print(sprintf("[func_global] \"%s\" is !reset — all %g slots of series "
                  "\"%s\" cleared\n", fg.targetname, MG_SLOTS, fg.map_series));
};

void() func_global_use =
{
    float idx, us, v;

    // "!reset" is resolved before the use type, because it has no slot index.
    if (self.netname == "!reset")
    {
        FuncGlobal_ResetAll(self);
        return;
    }

    idx = FuncGlobal_Index(self);
    if (idx < 0 || idx >= MG_SLOTS)
    {
        print(sprintf("[func_global] \"%s\" has netname \"%s\", which is not "
                      "globalNNN — ignored\n", self.targetname, self.netname));
        return;
    }

    // USE_UNSET is this tree's "the caller set no use type" sentinel; kmkz's
    // switch has no default arm, so an unset call behaves as the load its Spawn
    // performs.  See the USE_UNSET note in sv_customdefs.qc.
    us = sub_use_type;

    if (us == USE_ON)
        v = 1;
    else if (us == USE_OFF)
        v = 0;
    else if (us == USE_TOGGLE)
        v = MapGlobal_Get(idx) ? 0 : 1;
    else
    {
        self.health = MapGlobal_Get(idx);       // USE_SET / unset — reload only
        return;
    }

    MapGlobal_Set(idx, v);
    MapGlobal_Resync(idx);           // covers any sibling entity on the same slot

    if (cvar("sv_debug_use"))
        print(sprintf("[func_global] '%s' %s[%g] -> %g\n",
                      self.targetname, self.map_series, idx, v));
};

/*QUAKED func_global (.3 .6 .8) (-8 -8 -8) (8 8 8)
Sven Co-op / kmkz persistent flag.  One of 50 numbered on/off slots shared by
every map naming the same "map_series", stored to disk so it survives both a
level change and a server restart.

Not a Half-Life class and not related to env_global, which is per-map.

"targetname"   name
"netname"      "globalNNN" — the slot index — or "!reset" to clear all 50
"map_series"   which store this belongs to
"health"       live state, 0 or 1.  Read by trigger_condition.

Fires no target chain.  Set it with a trigger (On / Off / Toggle); read it with
a trigger_condition polling "health".
*/
void() func_global =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.takedamage = DAMAGE_NO;      // .health is state here, not hit points
    self.use      = func_global_use;

    MapGlobal_Ensure(self.map_series);

    // kmkz's Spawn calls its own Use with USE_SET, which loads the stored value.
    // Reproduced directly rather than through func_global_use, because that
    // reads sub_use_type — a global holding whatever fired last.
    //
    // The "!reset" arm is reached from spawn too, and that is NOT a transcription
    // error: in kmkz's script the reset test sits above the use-type switch, so a
    // map carrying one wipes campaign progress the moment it loads.  HC2 has
    // exactly one, in hc2_a2, and uses it as a deliberate "start over" room.
    // It prints, because silently destroying 21 collectibles would be
    // impossible to diagnose from the symptom.
    if (self.netname == "!reset")
    {
        FuncGlobal_ResetAll(self);
        return;
    }

    self.health = MapGlobal_Get(FuncGlobal_Index(self));
};

// ---------------------------------------------------------------------------
// Per-map re-arm.  Called from worldspawn.
//
// Note carefully what is NOT here: mg_state, mg_series, msave_* and their loaded
// flags are all deliberately left alone.  Surviving a changelevel is the entire
// point of this file, and FTE not reloading progs between maps is the mechanism
// that provides it.  Only the one-shot report flag re-arms.
// ---------------------------------------------------------------------------
void() MapGlobal_ResetPerMap =
{
    float i;

    mg_reported = FALSE;

    // Re-arm the named-value store so the next trigger_load re-reads the file.
    //
    // This is not belt-and-braces: without it a single load attempt anywhere in
    // the session latches msave_loaded for good, and a value saved on map A is
    // invisible on map B even though it is sitting in the file. Re-reading costs
    // one small file open per map and is idempotent, because every store is
    // written through immediately.
    //
    // Skipped when persistence is off, where there is no file to re-read from
    // and the in-memory records are the only copy there is.
    if (!MapGlobal_PersistEnabled())
        return;

    for (i = 0; i < msave_count; i = i + 1)
    {
        if (msave_level[i] != "") strunzone(msave_level[i]);
        if (msave_name[i]  != "") strunzone(msave_name[i]);
        if (msave_val[i]   != "") strunzone(msave_val[i]);
        msave_level[i] = "";
        msave_name[i]  = "";
        msave_val[i]   = "";
    }
    msave_count  = 0;
    msave_loaded = FALSE;
};

// ---------------------------------------------------------------------------
// Load-time census, one-shot per map, in the shape the other subsystems use.
// Without it the only evidence that func_global is implemented at all is the
// ABSENCE of a "no spawn function" line, which is a poor thing to assert on.
// ---------------------------------------------------------------------------
void() FuncGlobal_Report =
{
    entity e;
    float  n, on;

    if (mg_reported)
        return;
    mg_reported = TRUE;

    if (cvar("sv_mapglobals_selftest"))
        FuncGlobal_SelfTest();

    n = 0; on = 0;
    e = find(world, classname, "func_global");
    while (e)
    {
        n = n + 1;
        if (e.health) on = on + 1;
        e = find(e, classname, "func_global");
    }
    if (!n)
        return;

    print(sprintf("[func_global] %g on this map, series \"%s\", %g set — store %s\n",
                  n, mg_series, on,
                  MapGlobal_PersistEnabled() ? MapGlobal_Path(mg_series) : "(memory only)"));
};

// ---------------------------------------------------------------------------
// Self-test — `sv_mapglobals_selftest 1`.
//
// Exists because the interesting half of this file is only reachable with a
// live player driving a map's logic, and the headless CLIENT is slow enough on
// a 1400-entity map that a plain dedicated-server run cannot get one spawned.
// This exercises store, entity resync, the real .use path and the file
// round-trip with no player at all.  Shape follows AI_SquadmakerKeySelfTest.
//
// It snapshots and restores the store, so running it on a real save is safe.
// ---------------------------------------------------------------------------
void() FuncGlobal_SelfTest =
{
    entity e, subject;
    float  i, bad, n;

    bad = 0;
    n   = 0;

    // No func_global has spawned, so no series is selected and there is no file
    // to round-trip.  Skip rather than fail: a map that simply does not use the
    // feature is not a defect, and reporting one here would train the reader to
    // ignore the line that matters.
    if (!mg_have_series)
    {
        print("[mgtest] no func_global on this map — store test skipped\n");
        return;
    }

    for (i = 0; i < MG_SLOTS; i = i + 1)
        mg_backup[i] = mg_state[i];

    // 1. store set/get
    mg_state[1] = 0;
    MapGlobal_Set(1, 1);
    if (MapGlobal_Get(1) != 1)
    {
        bad = bad + 1;
        print("[mgtest] FAIL: set/get slot 1\n");
    }

    // 2. entity resync — the half that "!reset" depends on and that a store-only
    //    implementation silently gets wrong.
    MapGlobal_Resync(1);
    e = find(world, classname, "func_global");
    while (e)
    {
        if (e.netname != "!reset" && FuncGlobal_Index(e) == 1)
        {
            n = n + 1;
            if (e.health != 1)
            {
                bad = bad + 1;
                print(sprintf("[mgtest] FAIL: resync missed '%s'\n", e.targetname));
            }
        }
        e = find(e, classname, "func_global");
    }

    // 3. the real entity .use path, with an explicit On then Off
    subject = world;
    e = find(world, classname, "func_global");
    while (e && !subject)
    {
        if (e.netname != "!reset" && FuncGlobal_Index(e) >= 0)
            subject = e;
        e = find(e, classname, "func_global");
    }
    if (subject)
    {
        entity oself = self;
        float  osub  = sub_use_type;
        float  slot  = FuncGlobal_Index(subject);

        self = subject;
        sub_use_type = USE_ON;
        func_global_use();
        if (subject.health != 1 || MapGlobal_Get(slot) != 1)
        {
            bad = bad + 1;
            print(sprintf("[mgtest] FAIL: USE_ON on '%s' (health %g store %g)\n",
                          subject.targetname, subject.health, MapGlobal_Get(slot)));
        }

        sub_use_type = USE_OFF;
        func_global_use();
        if (subject.health != 0 || MapGlobal_Get(slot) != 0)
        {
            bad = bad + 1;
            print(sprintf("[mgtest] FAIL: USE_OFF on '%s' (health %g store %g)\n",
                          subject.targetname, subject.health, MapGlobal_Get(slot)));
        }

        sub_use_type = osub;
        self = oself;
    }

    // 4. file round-trip: save, wipe memory, reload
    mg_state[1] = 1;
    MapGlobal_SaveFile();
    for (i = 0; i < MG_SLOTS; i = i + 1)
        mg_state[i] = 0;
    MapGlobal_LoadFile(mg_series);
    if (MapGlobal_Get(1) != 1)
    {
        bad = bad + 1;
        print("[mgtest] FAIL: file round-trip lost slot 1\n");
    }

    // restore whatever was really there
    for (i = 0; i < MG_SLOTS; i = i + 1)
        mg_state[i] = mg_backup[i];
    MapGlobal_SaveFile();
    MapGlobal_ResyncAll();

    print(sprintf("[mgtest] func_global self-test: %g entity(s) on slot 1, BAD=%g\n", n, bad));
};

// ---------------------------------------------------------------------------
// Reading and writing one keyvalue by name, covering both real fields and
// Sven's "$" custom keyvalues.  trigger_save/_load need both: HC2 saves
// "$s_difficulty", but the same entities are documented to work on plain keys.
// ---------------------------------------------------------------------------
string(entity e, string key) MapSave_ReadKey =
{
    float fn;

    if (CustomKey_IsCustom(key))
        return CustomKey_Get(e, key);

    fn = findentityfield(key);
    if (fn <= 0)
        return "";
    return getentityfieldstring(fn, e);
};

void(entity e, string key, string val) MapSave_WriteKey =
{
    float fn;

    if (CustomKey_IsCustom(key))
    {
        CustomKey_Set(e, key, val);
        return;
    }

    fn = findentityfield(key);
    if (fn <= 0)
        return;
    putentityfieldstring(fn, e, val);
};

// ---------------------------------------------------------------------------
// The named value store.  File format is one record per line:
//     <level> <name> "<value>"
// tokenize handles the quoting, which is the same reader shape
// SV_ApplyConfigFile uses for map cfgs.
// ---------------------------------------------------------------------------
float(string lvl, string nm) MapSave_Slot =
{
    float i;

    for (i = 0; i < msave_count; i = i + 1)
        if (msave_level[i] == lvl && msave_name[i] == nm)
            return i;
    return -1;
};

void() MapSave_LoadFile =
{
    filestream f;
    string     line;
    float      argc;

    msave_loaded = TRUE;

    // NO persist gate on the READ path.  Reading a file that is not there costs
    // one failed fopen, whereas gating it means a single early call — the server
    // spawns a startup map before the one you asked for — sets msave_loaded with
    // nothing loaded, and because QC globals survive a changelevel that poisons
    // every later map in the session.  sv_mapglobals_persist governs WRITES.
    f = fopen("cfg/mapsaves.txt", FILE_READ);
    if (f < 0)
    {
        if (cvar("sv_debug_use"))
            print("[trigger_load] cfg/mapsaves.txt not present — nothing restored\n");
        return;
    }

    line = fgets(f);
    while (line && msave_count < MSAVE_MAX)
    {
        // Strip a trailing CR: the writer emits \n, but a file that has been
        // hand-edited on Windows comes back CRLF and the CR would end up inside
        // the value, so "normal\r" != "normal" and every compare misses.
        float n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
            line = substring(line, 0, n - 1);

        argc = tokenize(line);
        if (argc >= 3)
        {
            msave_level[msave_count] = strzone(argv(0));
            msave_name[msave_count]  = strzone(argv(1));
            msave_val[msave_count]   = strzone(argv(2));
            msave_count = msave_count + 1;
        }
        line = fgets(f);
    }
    fclose(f);

    if (cvar("sv_debug_use"))
        print(sprintf("[trigger_load] cfg/mapsaves.txt: %g record(s) restored\n", msave_count));
};

void() MapSave_SaveFile =
{
    filestream f;
    float      i;

    if (!MapGlobal_PersistEnabled())
        return;

    f = fopen("cfg/mapsaves.txt", FILE_WRITE);
    if (f < 0)
        return;

    for (i = 0; i < msave_count; i = i + 1)
        fputs(f, sprintf("%s %s \"%s\"\n", msave_level[i], msave_name[i], msave_val[i]));
    fclose(f);
};

void() MapSave_Ensure =
{
    if (!msave_loaded)
        MapSave_LoadFile();
};

void(string lvl, string nm, string val) MapSave_Store =
{
    float s;

    MapSave_Ensure();
    s = MapSave_Slot(lvl, nm);
    if (s >= 0)
    {
        if (msave_val[s] == val)
            return;                  // no change, no write
        strunzone(msave_val[s]);
        msave_val[s] = strzone(val);
        MapSave_SaveFile();
        return;
    }

    if (msave_count >= MSAVE_MAX)
    {
        print(sprintf("[trigger_save] store full (%g) — \"%s\" dropped\n", MSAVE_MAX, nm));
        return;
    }

    msave_level[msave_count] = strzone(lvl);
    msave_name[msave_count]  = strzone(nm);
    msave_val[msave_count]   = strzone(val);
    msave_count = msave_count + 1;
    MapSave_SaveFile();
};

// ---------------------------------------------------------------------------
// trigger_save — copy one keyvalue off `target` into the named store.
//   netname   the save name
//   target    entity holding the value
//   message   which keyvalue to read
// ---------------------------------------------------------------------------
void() trigger_save_use =
{
    entity src;
    string val;

    if (self.netname == "" || self.target == "" || self.message == "")
        return;

    src = find(world, targetname, self.target);
    if (!src)
        return;

    val = MapSave_ReadKey(src, self.message);
    MapSave_Store(mapname, self.netname, val);

    if (cvar("sv_debug_use"))
        print(sprintf("[trigger_save] '%s' saved %s=\"%s\" as \"%s\" for level %s\n",
                      self.targetname, self.message, val, self.netname, mapname));
};

/*QUAKED trigger_save (.5 .5 .9) (-8 -8 -8) (8 8 8)
Sven Co-op.  Stores one keyvalue of another entity under a name, tagged with the
current level, so a trigger_load on a later map can read it back.  Persisted to
cfg/mapsaves.txt.

"netname"   the save name
"target"    entity to read from
"message"   which keyvalue to read (a field, or a "$" custom keyvalue)
*/
void() trigger_save =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = trigger_save_use;
};

// ---------------------------------------------------------------------------
// trigger_load — the other half.
//   netname          the save name
//   m_iszLevelName   which level's save to read
//   target           entity to write into
//   message          which keyvalue to write
//   m_iszTrigger     fired afterwards, once the value has landed
// ---------------------------------------------------------------------------
void() trigger_load_use =
{
    entity dst;
    float  s;
    string lvl;

    if (self.netname == "" || self.target == "" || self.message == "")
        return;

    MapSave_Ensure();

    lvl = self.m_iszlevelname;
    if (lvl == "" || lvl == __NULL__)
        lvl = mapname;

    s = MapSave_Slot(lvl, self.netname);
    if (s >= 0)
    {
        dst = find(world, targetname, self.target);
        while (dst)
        {
            MapSave_WriteKey(dst, self.message, msave_val[s]);
            dst = find(dst, targetname, self.target);
        }

        if (cvar("sv_debug_use"))
            print(sprintf("[trigger_load] '%s' loaded \"%s\" -> %s=\"%s\"\n",
                          self.targetname, self.netname, self.message, msave_val[s]));
    }
    else if (cvar("sv_debug_use"))
    {
        print(sprintf("[trigger_load] '%s' found no save \"%s\" for level %s\n",
                      self.targetname, self.netname, lvl));
    }

    // Fire the follow-up chain whether or not a value was found.  HC2's
    // Diff_Initialization relies on it: the trigger_condition it starts is what
    // decides between normal and extreme, and on a first playthrough there is
    // deliberately no saved value yet.
    if (self.m_isztrigger != "" && self.m_isztrigger != __NULL__)
    {
        string saved = self.target;
        self.target  = self.m_isztrigger;
        Trigger_UseTargets(self, activator);
        self.target  = saved;
    }
};

/*QUAKED trigger_load (.5 .5 .9) (-8 -8 -8) (8 8 8)
Sven Co-op.  Reads back a value stored by trigger_save and writes it onto an
entity, then fires a follow-up chain.

"netname"          the save name
"m_iszLevelName"   which level's save to read (default: this one)
"target"           entity to write into (all matches)
"message"          which keyvalue to write (a field, or a "$" custom keyvalue)
"m_iszTrigger"     fired after the load, found or not
*/
void() trigger_load =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = trigger_load_use;
};
