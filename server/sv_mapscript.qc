// ===========================================================================
//  sv_mapscript.qc — native stand-ins for a map's AngelScript
// ===========================================================================
//
// A Sven map cfg can name a script with `map_script <path>`, and Sven then loads
// that AngelScript and lets the map call into it through trigger_script.  There
// is no script VM here and there never will be one, so until now both halves
// were dead: `map_script` fell through SV_ApplyConfigFile's cvar branch and
// became a junk cvar, and trigger_script logged a line and forwarded its chain
// without ever reading which function it was supposed to call.
//
// This file is the small piece that closes the gap: a registry of script names
// to native behaviour, so a campaign whose script does something simple gets
// that something, and everything else still degrades to the old forward.
//
// It is deliberately NOT a general scripting layer.  The only thing it can do is
// recognise a (script, function) pair we have ported by hand.  An unknown pair
// prints once and forwards, exactly as before — so adding a map here is opt-in
// and nothing regresses for the 100+ corpus maps that name no script at all.
//
// ---------------------------------------------------------------------------
//  Hazardous Course 2  (`map_script hc2/HC2`, all 20 maps)
// ---------------------------------------------------------------------------
// scripts/maps/hc2/HC2.as registers a PlayerSpawn hook and two functions the
// maps call through trigger_script:
//
//      normal ()   DiffMode = 1  -> spawn with health 100, armour 100
//      extreme()   DiffMode = 2  -> spawn with health 1,   armour 1
//
// DiffMode starts at 0 and the hook returns early while it is 0, so an
// unselected difficulty means "leave the player alone" — which is why this
// resets per map rather than persisting.  Each map re-establishes it through
// its own trigger_load -> trigger_condition -> trigger_script chain, and the
// choice itself is carried between maps by trigger_save/trigger_load
// (server/sv_mapglobals.qc) as the "$s_difficulty" custom keyvalue.
//
// 22 trigger_script entities across 11 maps, and every one of them is one of
// these two functions — there is no third.
//
// ---------------------------------------------------------------------------
//  They Hunger: Escape  (`map_script th_escape/th_escape`)
// ---------------------------------------------------------------------------
// The second entry in the registry, and a much larger one: 17 trigger_script
// entities, all in the single map th_escape, covering the whole run — character
// assignment and equipment, the escape timer, the objective indicators, the
// truck's ignition and controls release, and all five endings.
//
// The stand-ins live in their own file, server/sv_mapscript_thescape.qc, which
// compiles immediately before this one.  Splitting them out keeps THIS file
// what its header says it is — a registry — rather than letting one campaign's
// 700 lines bury the dispatch.  See that file's header for what is and is not
// ported.
// ---------------------------------------------------------------------------

// trigger_script's keys.  Declared LOWERCASE: the maps spell them
// "m_iszScriptFunctionName" and "m_iMode", and GoldSrc_TryCaseFoldedField
// (server/sv_multi_manager.qc) folds a missed key to lower case and retries.
// Declaring the CamelCase spelling instead would bind Hammer's output and
// silently miss every other compiler's.
.string m_iszscriptfunctionname;
.float  m_imode;

string mapscript_name;          // strzone'd; whatever the cfg's map_script named
float  mapscript_have;

// HC2 difficulty: 0 unselected, 1 normal, 2 extreme.  Per map, see above.
float  mapscript_hc2_diff;

const float HC2_DIFF_NONE    = 0;
const float HC2_DIFF_NORMAL  = 1;
const float HC2_DIFF_EXTREME = 2;

// ---------------------------------------------------------------------------
// Consumed from the map cfg by MapCfgEquip_Token.
// ---------------------------------------------------------------------------
float() MapScript_IsTHEscape;

void(string path) MapScript_SetScript =
{
    if (mapscript_have && mapscript_name != "")
        strunzone(mapscript_name);

    mapscript_name = strzone(path);
    mapscript_have = TRUE;

    // MapInit equivalent.  Only the campaigns that need one have a hook; hc2's
    // MapInit does nothing but register the spawn hook, which is
    // MapScript_PlayerSpawn below.
    if (MapScript_IsTHEscape())
        THEsc_MapInit();
};

// Per-map re-arm, from worldspawn.  The script NAME is set by the map cfg, which
// is applied after worldspawn, so clearing it here is correct and stops a map
// with no cfg inheriting the previous map's script.
void() MapScript_ResetForMap =
{
    if (mapscript_have && mapscript_name != "")
        strunzone(mapscript_name);
    mapscript_name     = "";
    mapscript_have     = FALSE;
    mapscript_hc2_diff = HC2_DIFF_NONE;

    // Unconditional: a map that names no script must not inherit th_escape's
    // armed timer, and this runs from worldspawn BEFORE the new map's cfg has
    // been read, so there is nothing to gate on yet.
    THEsc_ResetForMap();
};

float() MapScript_IsHC2 =
{
    // The cfgs all say "hc2/HC2"; compare case-insensitively and accept either
    // slash so a hand-edited cfg still matches.
    string s = strtolower(mapscript_name);
    return (s == "hc2/hc2" || s == "hc2\\hc2");
};

float() MapScript_IsTHEscape =
{
    if (!mapscript_have)
        return FALSE;
    string s = strtolower(mapscript_name);
    return (s == "th_escape/th_escape" || s == "th_escape\\th_escape");
};

// ---------------------------------------------------------------------------
// The dispatch.  Returns TRUE if the call was recognised and handled, so
// trigger_script knows whether to fall back to its old forward-and-log.
// ---------------------------------------------------------------------------
float(string fn) MapScript_Call =
{
    if (!mapscript_have || fn == "" || fn == __NULL__)
        return FALSE;

    if (MapScript_IsHC2())
    {
        string f = strtolower(fn);

        if (f == "normal")
        {
            mapscript_hc2_diff = HC2_DIFF_NORMAL;
            print("[mapscript] hc2: difficulty NORMAL (spawn 100hp/100ap)\n");
            return TRUE;
        }
        if (f == "extreme")
        {
            mapscript_hc2_diff = HC2_DIFF_EXTREME;
            print("[mapscript] hc2: difficulty EXTREME (spawn 1hp/1ap)\n");
            return TRUE;
        }
    }

    if (MapScript_IsTHEscape())
        return THEsc_Call(fn);

    return FALSE;
};

// ---------------------------------------------------------------------------
// PlayerSpawn hook equivalent.  Called from PlayerSpawn AFTER the loadout and
// the map cfg manifest, because HC2.as's hook runs after Sven's own spawn
// handling and overwrites whatever health it set.
// ---------------------------------------------------------------------------
void(entity plyr) MapScript_PlayerSpawn =
{
    if (mapscript_hc2_diff == HC2_DIFF_NORMAL)
    {
        plyr.health     = 100;
        plyr.max_health = 100;
        plyr.armor      = 100;
    }
    else if (mapscript_hc2_diff == HC2_DIFF_EXTREME)
    {
        // HC2.as sets health, max_health and armortype to 1.  One point of
        // health is the entire premise of the mode, so it is applied verbatim.
        plyr.health     = 1;
        plyr.max_health = 1;
        plyr.armor      = 1;
    }

    // th_escape's CustomHUD::ClientPutInServer replay — a player joining or
    // respawning mid-run needs the timer and the objective list re-sent, since
    // both are game_text slots and a fresh client has none.
    if (MapScript_IsTHEscape())
        THEsc_PlayerSpawn(plyr);
};

// ---------------------------------------------------------------------------
// Hooks::Player::PlayerKilled and ::ClientDisconnect.  th_escape registers both
// and routes them to the same CheckEndConditions — "everybody is dead" is how
// the run FAILS, and it has to be noticed on a disconnect too or the last
// living player quitting would leave the map running forever with nobody in it.
//
// Called from PlayerKilled (server/sv_weapons.qc, position 45, by forward
// declaration) and from ClientDisconnect (server/sv_player.qc).
// ---------------------------------------------------------------------------
void() MapScript_PlayerDiedOrLeft =
{
    if (MapScript_IsTHEscape())
        THEsc_CheckEndConditions();
};

// ---------------------------------------------------------------------------
// Per-frame tick, from StartFrame (sv_main.qc).  Gated to 10 Hz here rather
// than at the call site because that is the cadence Sven's own scheduler uses
// for CustomHUD::Update, and because nothing else in the registry wants a
// frame hook at all.
// ---------------------------------------------------------------------------
float mapscript_next_tick;

void() MapScript_Frame =
{
    if (!mapscript_have)
        return;
    if (time < mapscript_next_tick)
        return;
    mapscript_next_tick = time + 0.1;

    if (MapScript_IsTHEscape())
        THEsc_Frame();
};

// ---------------------------------------------------------------------------
// trigger_script — Sven's "call a script function" entity.
//
// m_iMode selects what to call (1 = a plain function, which is all the corpus
// uses); m_iszScriptFunctionName is the name.  When we have a native stand-in
// the call is made and the chain still forwards; when we do not, the behaviour
// is exactly what it was before this file existed.
// ---------------------------------------------------------------------------
void() trigger_script_use =
{
    float handled = MapScript_Call(self.m_iszscriptfunctionname);

    if (!handled && cvar("sv_debug_use"))
        print(sprintf("[trigger_script] \"%s\" wants %s(\"%s\") — no native "
                      "stand-in, forwarding chain only\n",
                      self.targetname,
                      (self.m_imode == 1) ? "function" : sprintf("mode%g", self.m_imode),
                      self.m_iszscriptfunctionname));

    GoldSrc_UnknownRelay_Use();
};

/*QUAKED trigger_script (.9 .5 .1) (-8 -8 -8) (8 8 8)
Sven Co-op.  Calls a function in the map's AngelScript.  There is no script VM
here; instead server/sv_mapscript.qc holds hand-ported stand-ins keyed on the
cfg's "map_script" value, and anything without one just forwards its chain.

"m_iszScriptFunctionName"  function to call
"m_iMode"                  1 = plain function call (all the corpus uses)
"target"                   forwarded either way
*/
void() trigger_script =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = trigger_script_use;
};
