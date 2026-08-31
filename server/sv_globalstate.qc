// ============================================================
//  server/sv_globalstate.qc  -  Half-Life's global state table
//
//  Ported from dlls/world.cpp:280-430 (CGlobalState) and its three readers:
//      dlls/buttons.cpp:68-131    CEnvGlobal        (the writer)
//      dlls/buttons.cpp:232       CMultiSource::IsTriggered
//      dlls/triggers.cpp:178      CAutoTrigger::Think
//
//  WHAT WAS ACTUALLY WRONG.  env_global was implemented (sv_goldsrc_compat.qc)
//  but bound to the WRONG KEY.  Half-Life reads the state's name from the
//  `globalstate` key -- buttons.cpp:73, and the comment there is literally
//  "// State name".  This tree read `.globalname`, which is a completely
//  different Half-Life key: entity identity across a level transition
//  (cbase.cpp:158/344/405), 387 placements over 174 names in the map corpus.
//
//  Measured across all 233 Sven + valve maps: every one of the 36 env_global
//  placements sets `globalstate`, NOT ONE sets `globalname`, and the two key's
//  name sets do not intersect at all.  So EnvGlobal_Find could never match
//  anything -- and it did not matter, because EnvGlobal_IsOn had zero callers:
//  neither multisource nor trigger_auto ever tested a global.  Both halves were
//  missing, which is why nothing ever looked broken.
//
//  WHY A TABLE AND NOT PER-ENTITY STATE.  Two reasons, both measured:
//
//   1. One name, many entities.  -sp_campaign_portal carries two env_globals
//      that both name `generatorglobal`; HL has ONE table row for it, so the
//      second env_global updates the same state the first defined.  Storing the
//      value on the entity would give that map two independent globals.
//
//   2. 8 of the 24 distinct names in the corpus are CROSS-MAP -- defined by an
//      env_global on one map and read by a gate on another:
//          c2a1_train_power  def c2a1a         read c2a1, hl_c06
//          c1a4dfuel/doxy    def c1a4d         read c1a4b, c1a4i
//          sc2newglobal      def svencoop1     read svencoop2
//      HL gets this from the savegame, which carries the table through a level
//      change (world.cpp:439-446).
//
//  WHY THE TABLE IS ALSO A FILE.  Because a QC global array does NOT survive a
//  changelevel here, and the tree believed otherwise.  sv_mapglobals.qc:24-28
//  states that "FTE does not reload progs between map loads, so a plain global
//  array already survives a changelevel"; that is false.  SV_SpawnServer calls
//  PR_Deinit() unconditionally -- engine/server/sv_init.c:945, inside the
//  function at :839 -- so every QC global is destroyed on every map load,
//  changelevel included.  Measured directly before writing a line of this:
//
//      [globalstate] 4 entries on crystal
//      [globalstate] map start hl_c06: 0 entries carried in
//
//  So the state goes to cfg/globalstate.txt, the same directory and the same
//  shape sv_mapglobals.qc already uses (and which, on that measurement, is doing
//  all of that store's cross-map work rather than only the cross-restart half
//  its header claims).
//
//  Set sv_globalstate_persist 0 for a table that lives one map and is never
//  read from or written to disk.  That is the rollback path, not a tuning knob:
//  it turns every cross-map global off.
// ============================================================

// world.cpp:36-40 (GLOBALESTATE).  DEAD is a real third state, not a spare:
// SUB_Remove marks a globalname'd entity DEAD (subs.cpp:110) so it stays gone
// when the player walks back into the map, and toggle mode below refuses to
// bring a DEAD global back.
const float GLOBAL_OFF  = 0;
const float GLOBAL_ON   = 1;
const float GLOBAL_DEAD = 2;

// 24 distinct names across 233 maps, so 64 is roughly 2.5x the worst case a
// full campaign can reach.  The overflow arm still counts and reports rather
// than failing silently -- sv_sentences.qc's SENT_MAX taught that lesson the
// expensive way (it was dropping 83 lines a map and only said so in a log line
// nobody read).
const float GST_MAX = 64;

// gst_, not gs_: sv_goldsrc_ammo.qc:595 already owns gs_give_amount and QC has
// ONE global namespace across every compilation unit, which fteqcc merges
// SILENTLY.  See sv_mapglobals.qc:60-70 for the bug that cost.
string gst_name[GST_MAX];   // strzone'd -- see GlobalState_Add
string gst_level[GST_MAX];  // map the global was first defined on (world.cpp:315)
float  gst_state[GST_MAX];
float  gst_count;
float  gst_dropped;         // names that did not fit; reported, never silent
float  gst_loaded;          // this map's table has been hydrated from disk

// cfg/ for the reason sv_mapglobals.qc gives: it is the one directory this tree
// demonstrably writes into already (SV_WriteServerConfigFile), so it needs no
// creation step and no guessing about the gamedir layout.
//
// ONE file for every map, unlike func_global's per-series files, because that is
// what the mechanism is: HL's table is global to the game, not to a campaign,
// and the corpus names are already map-scoped by convention (`c1a4dfuel`,
// `sc2newglobal`).  A series split would have to guess which maps belong
// together and would break the c2a1a -> hl_c06 pair, which spans two mods.
const string GST_PATH = "cfg/globalstate.txt";

void() GlobalState_SaveFile;        // defined below; called on every write

// Read the same defensive way MapGlobal_PersistEnabled does (sv_mapglobals.qc:
// 91-105): cvar() reads 0 for a name that has not been registered yet, and this
// store's first touch is an env_global spawn during map load, which can be ahead
// of CVar_Init.  Absent means enabled; only an explicit 0 disables.
float() GlobalState_PersistEnabled =
{
    if (cvar_string("sv_globalstate_persist") == "")
        return TRUE;
    return cvar("sv_globalstate_persist") != 0;
};

// ---------------------------------------------------------------------------
//  Table primitives -- CGlobalState::Find / EntityAdd / EntitySetState /
//  EntityGetState / EntityInTable, world.cpp:288-345
// ---------------------------------------------------------------------------

// Hydrate from disk on first touch.  Called from GlobalState_Index, which every
// other entry point funnels through, so there is no "did you remember to load
// it" failure mode.  gst_loaded is set BEFORE the read for belt and braces —
// the loader appends through GlobalState_Insert, which does not go back through
// Index, but the latch should not depend on that staying true.
void() GlobalState_LoadFile;

void() GlobalState_Ensure =
{
    if (gst_loaded)
        return;
    gst_loaded = 1;
    if (GlobalState_PersistEnabled())
        GlobalState_LoadFile();
};

// Case-SENSITIVE, matching HL's FStrEq (a strcmp).  This was checked rather
// than assumed, because the identical assumption in Sentences_IndexOf was false
// and cost 27 missing lines across the corpus: of the 24 globalstate names,
// **zero** differ from a reader's spelling by case alone.  Mapper and reader are
// authored together here, so the two files agree.
float(string name) GlobalState_Index =
{
    float i;
    if (name == "" || name == __NULL__)
        return -1;
    GlobalState_Ensure();
    for (i = 0; i < gst_count; i = i + 1)
    {
        if (gst_name[i] == name)
            return i;
    }
    return -1;
};

float(string name) GlobalState_InTable =
{
    return GlobalState_Index(name) >= 0;
};

// world.cpp:335 — a name that is not in the table reads as OFF.  That is load
// bearing and not a defensive default: three corpus gates name a global that no
// env_global anywhere ever defines (hl_c06's `p_ms2` wants c2a1a_power_master,
// hl_c07_a2's two bay screens want c2a2bay*screen), and in real Half-Life those
// gates are therefore shut forever.  Returning OFF is what reproduces that.
float(string name) GlobalState_Get =
{
    float i = GlobalState_Index(name);
    if (i < 0)
        return GLOBAL_OFF;
    return gst_state[i];
};

// The raw append.  Split out from GlobalState_Add because the file loader has to
// keep the level name the row was WRITTEN with — passing mapname there would
// relabel every restored row as belonging to whatever map is loading now, and
// the level name is the only breadcrumb saying where a cross-map global came
// from.  Does not touch the file: the loader must not write back what it just
// read, and Add saves once on top.
float(string name, string level, float state) GlobalState_Insert =
{
    if (name == "" || name == __NULL__)
        return FALSE;

    if (gst_count >= GST_MAX)
    {
        gst_dropped = gst_dropped + 1;
        print(sprintf("[globalstate] table full (%g) — dropped \"%s\"\n",
                      GST_MAX, name));
        return FALSE;
    }

    // strzone is REQUIRED, not hygiene.  `name` arrives as a field string off a
    // map entity, or off a line fgets just returned, and both are freed out from
    // under us — the fgets buffer within the same function.  Never unzoned:
    // the rows live for the server's lifetime by design, and GlobalState_Clear
    // is the one path that releases them.
    gst_name[gst_count]  = strzone(name);
    gst_level[gst_count] = strzone(level);
    gst_state[gst_count] = state;
    gst_count = gst_count + 1;
    return TRUE;
};

void(string name, float state) GlobalState_Add =
{
    if (name == "" || name == __NULL__)
        return;
    if (GlobalState_InTable(name))
        return;                     // HL asserts !Find() here; we no-op instead

    if (!GlobalState_Insert(name, mapname, state))
        return;

    if (cvar("sv_debug_globalstate"))
        print(sprintf("[globalstate] + \"%s\" = %g (on %s)\n", name, state, mapname));

    GlobalState_SaveFile();
};

// world.cpp:330 — EntitySetState does NOTHING for a name that is not present.
// env_global_use handles the absent case itself by adding, exactly as
// buttons.cpp:127-130 does.
void(string name, float state) GlobalState_SetState =
{
    float i = GlobalState_Index(name);
    if (i < 0)
        return;
    if (gst_state[i] == state)
        return;                     // no change, no write (MapGlobal_Set's rule)
    if (cvar("sv_debug_globalstate"))
        print(sprintf("[globalstate] \"%s\" %g -> %g\n", name, gst_state[i], state));
    gst_state[i] = state;
    GlobalState_SaveFile();
};

// ---------------------------------------------------------------------------
//  Persistence -- CGlobalState::Save / Restore, world.cpp:370-412
//
//  Line format, one row each:   name=state levelname
//  e.g.                         c2a1_train_power=1 c2a1a
//
//  Split on the FIRST '=' and then the first space, so a level name with an
//  underscore or a digit reads back intact.  No corpus global name contains an
//  '=' or a space (they are all identifiers), and a line that does not parse is
//  skipped rather than guessed at.
// ---------------------------------------------------------------------------
void() GlobalState_LoadFile =
{
    filestream f;
    string     line;
    float      eq, sp, n;

    f = fopen(GST_PATH, FILE_READ);
    if (f < 0)
        return;                      // no file yet — every global starts off

    line = fgets(f);
    while (line)
    {
        // Strip a trailing CR so a file written on Windows reads on Linux —
        // the same fix MapGlobal_LoadFile carries, and for the same reason.
        n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
            line = substring(line, 0, n - 1);

        eq = strstrofs(line, "=", 0);
        if (eq > 0)
        {
            string nm  = substring(line, 0, eq);
            string rest = substring(line, eq + 1, -1);
            sp = strstrofs(rest, " ", 0);
            if (sp > 0)
                GlobalState_Insert(nm, substring(rest, sp + 1, -1),
                                   stof(substring(rest, 0, sp)));
            else
                GlobalState_Insert(nm, "?", stof(rest));
        }
        line = fgets(f);
    }
    fclose(f);

    if (gst_count && cvar("sv_debug_globalstate"))
        print(sprintf("[globalstate] loaded %g entr%s from %s\n",
                      gst_count, gst_count == 1 ? "y" : "ies", GST_PATH));
};

void() GlobalState_SaveFile =
{
    filestream f;
    float      i;

    if (!GlobalState_PersistEnabled())
        return;

    f = fopen(GST_PATH, FILE_WRITE);
    if (f < 0)
    {
        print(sprintf("[globalstate] cannot write %s — globals will not survive "
                      "the next changelevel this session\n", GST_PATH));
        return;
    }
    for (i = 0; i < gst_count; i = i + 1)
        fputs(f, sprintf("%s=%g %s\n", gst_name[i], gst_state[i], gst_level[i]));
    fclose(f);
};

// ---------------------------------------------------------------------------
//  The gate test, which all three readers share verbatim:
//      if ( !m_globalstate || gGlobalState.EntityGetState(m_globalstate) == GLOBAL_ON )
//  An unset key passes; anything else must be ON.  OFF and DEAD both fail.
// ---------------------------------------------------------------------------
float(string name) GlobalState_GateOpen =
{
    if (name == "" || name == __NULL__)
        return TRUE;
    return GlobalState_Get(name) == GLOBAL_ON;
};

// ---------------------------------------------------------------------------
//  Housekeeping
// ---------------------------------------------------------------------------
void() GlobalState_Clear =
{
    float i;
    for (i = 0; i < gst_count; i = i + 1)
    {
        // The zoned strings ARE ours to release here — this is the only path
        // that ever drops a row.
        if (gst_name[i])  strunzone(gst_name[i]);
        if (gst_level[i]) strunzone(gst_level[i]);
        gst_name[i]  = "";
        gst_level[i] = "";
        gst_state[i] = GLOBAL_OFF;
    }
    gst_count   = 0;
    gst_dropped = 0;

    // RE-ARM THE LOADER.  An empty table is an UNLOADED table, and forgetting
    // that destroyed data: worldspawn cleared the rows, gst_loaded stayed 1 so
    // nothing re-read the file, and the map's first env_global then wrote its
    // one row over everything the campaign had accumulated.  Caught by the
    // 10-map sweep — sandstone went `4 entries (from crystal)` -> `+
    // playercount_is_high` -> `1 entry`, and every map after it inherited the
    // wreckage. Anything that empties this table must let the file refill it.
    gst_loaded  = 0;
};

// CGlobalState::DumpGlobals, world.cpp — reachable in HL through a cheat
// impulse (player.cpp:3733).  Here it is a cvar, because the interesting moment
// is map load on a headless server rather than a keypress.
void() GlobalState_Dump =
{
    float i;
    if (!cvar("sv_debug_globalstate"))
        return;
    print(sprintf("[globalstate] %g entr%s on %s\n",
                  gst_count, gst_count == 1 ? "y" : "ies", mapname));
    for (i = 0; i < gst_count; i = i + 1)
    {
        print(sprintf("[globalstate]   %-28s %s   (from %s)\n", gst_name[i],
                      gst_state[i] == GLOBAL_ON   ? "ON  " :
                      gst_state[i] == GLOBAL_DEAD ? "DEAD" : "off ",
                      gst_level[i]));
    }
};

// One-shot dump per map, latched the same way FuncGlobal_Report's census line
// is.  Called from the per-frame hook rather than from worldspawn because
// worldspawn is entity 0 — every env_global on the map spawns AFTER it, so a
// dump taken there would show an empty table and none of this map's
// definitions.  Deferred by a second so the trigger_autos have run too.
float gst_reported;

void() GlobalState_Report =
{
    if (gst_reported || time < 1)
        return;
    gst_reported = 1;
    // Hydrate first.  GlobalState_Dump reads gst_count straight, so on a map
    // with no env_global and no gate fired yet the lazy load has not happened
    // and the dump would honestly report an empty table while the file holds
    // the campaign's state — which reads as "the carry broke".  Measured
    // exactly that on hl_c06 before this line existed.
    GlobalState_Ensure();
    GlobalState_Dump();
};

void() GlobalState_ResetPerMap =
{
    gst_reported = 0;
};

// Called from worldspawn, which is entity 0 and therefore runs before any
// env_global on the map.  Drops whatever is in memory and lets the FILE be the
// truth for the new map — which is not the same as "start empty", because
// GlobalState_Clear re-arms the lazy hydrate.  It is usually a no-op anyway
// (PR_Deinit has already wiped the array), but it is NOT always: some map loads
// reach worldspawn on a progs instance that has already read the file, and
// clearing without re-arming is what destroyed four rows on sandstone.
//
// Marking the table loaded WITHOUT reading is what "persist 0" means: one map's
// worth of globals and no disk at all.
void() GlobalState_MapStart =
{
    GlobalState_ResetPerMap();
    GlobalState_Clear();

    if (!GlobalState_PersistEnabled())
    {
        gst_loaded = 1;             // suppress the lazy hydrate in Ensure
        if (cvar("sv_debug_globalstate"))
            print(sprintf("[globalstate] persist off — %s starts with an empty "
                          "table and will not write one\n", mapname));
    }
};

// ---------------------------------------------------------------------------
//  Self-test — sv_globalstate_selftest 1
//
//  Unlike SV_ShakeSelfTest this needs no player and no wire, so it asserts
//  outright rather than printing state for a human to read — there is no
//  FL_ONGROUND-shaped hole here for the harness to fall into.
//
//  Stage 1 is the table contract.  Stage 2 is the ROUND TRIP through
//  cfg/globalstate.txt, and that is the one that matters: the file is not a
//  convenience here, it is the entire cross-map mechanism, so "the table works"
//  proves nothing on its own.
//
//  Safe to leave on.  It runs on a scratch name no map uses, rolls that row back
//  off the end, and rewrites the file from the true table before doing anything
//  destructive — so it cannot eat a campaign's progress the way
//  FuncGlobal_SelfTest had to guard against.
// ---------------------------------------------------------------------------
float globalstate_test_done;

void() GlobalState_SelfTest =
{
    if (!cvar("sv_globalstate_selftest") || globalstate_test_done)
        return;
    globalstate_test_done = 1;

    string  n   = "__gst_selftest";
    float   bad = 0;

    // Hydrate BEFORE the snapshot.  gst_count is 0 until something touches the
    // table, and the first thing that does is the Get() two lines below — so a
    // snapshot taken here without this read 0, the rollback's
    // `gst_count == before + 1` guard then failed silently, and the scratch row
    // shipped to disk.  Measured: __gst_selftest=2 in cfg/globalstate.txt.
    GlobalState_Ensure();
    float   before = gst_count;

    // Absent reads OFF and an absent gate is shut (the hl_c06 p_ms2 case).
    bad = bad + (GlobalState_Get(n) != GLOBAL_OFF);
    bad = bad + (GlobalState_GateOpen(n) != FALSE);
    // An unset key passes — the common case, every gate that names no global.
    bad = bad + (GlobalState_GateOpen("") != TRUE);

    GlobalState_Add(n, GLOBAL_ON);
    bad = bad + (GlobalState_InTable(n) != TRUE);
    bad = bad + (GlobalState_Get(n) != GLOBAL_ON);
    bad = bad + (GlobalState_GateOpen(n) != TRUE);

    // Add is idempotent on an existing name (HL asserts here), and must not
    // stomp the live value with the initial one — that is what would let a
    // re-entered map reset a global the player had already switched on.
    GlobalState_Add(n, GLOBAL_OFF);
    bad = bad + (GlobalState_Get(n) != GLOBAL_ON);

    GlobalState_SetState(n, GLOBAL_DEAD);
    bad = bad + (GlobalState_Get(n) != GLOBAL_DEAD);
    bad = bad + (GlobalState_GateOpen(n) != FALSE);   // DEAD is not ON

    // SetState on an absent name is a no-op, not an insert (world.cpp:330).
    GlobalState_SetState("__gst_absent", GLOBAL_ON);
    bad = bad + (GlobalState_InTable("__gst_absent") != FALSE);

    print(sprintf("[gsttest] stage 1 table contract BAD=%g (%g entr%s)\n",
                  bad, gst_count, gst_count == 1 ? "y" : "ies"));

    // Roll the scratch row back off the end.  Only valid because Insert appends
    // and nothing else ran in between.
    if (gst_count == before + 1)
    {
        strunzone(gst_name[before]);
        strunzone(gst_level[before]);
        gst_name[before]  = "";
        gst_level[before] = "";
        gst_state[before] = GLOBAL_OFF;
        gst_count = before;
    }

    // --- stage 2: the round trip, which is what a changelevel actually does ---
    if (!GlobalState_PersistEnabled())
    {
        print("[gsttest] stage 2 skipped — sv_globalstate_persist is 0\n");
        GlobalState_Dump();
        return;
    }

    // Write the TRUE table first, which also undoes the scratch row on disk.
    GlobalState_SaveFile();

    // Snapshot enough to compare against.  Names and levels are zoned strings
    // owned by the table and Clear is about to release them, so compare on the
    // count and on one representative row rather than holding pointers.
    float  n_before = gst_count;
    string first_name  = n_before ? strzone(gst_name[0])  : "";
    string first_level = n_before ? strzone(gst_level[0]) : "";
    float  first_state = n_before ? gst_state[0] : 0;
    float  bad2 = 0;

    GlobalState_Clear();            // ...which re-arms the hydrate, by contract
    GlobalState_Ensure();           // ...and take it, exactly as a new map would

    bad2 = bad2 + (gst_count != n_before);
    if (n_before && gst_count == n_before)
    {
        bad2 = bad2 + (gst_name[0]  != first_name);
        bad2 = bad2 + (gst_level[0] != first_level);
        bad2 = bad2 + (gst_state[0] != first_state);
    }
    if (n_before)
    {
        strunzone(first_name);
        strunzone(first_level);
    }

    print(sprintf("[gsttest] stage 2 file round trip BAD=%g (%g -> %g entries via %s)\n",
                  bad2, n_before, gst_count, GST_PATH));

    GlobalState_Dump();
};
