// ===========================================================================
// sh_matsounds.qc - per-MATERIAL contact sound sets (scripts/materialsounds.txt).
//
// Third leg of the material system.  sh_surfaceprops.qc maps a world TEXTURE ->
// material; sh_propmaterials.qc maps a prop MODEL PATH -> material; this maps a
// MATERIAL NAME -> the wav pool for each contact kind (hard / soft / bullet /
// scrape / break).  Both of the other two tables ALREADY carry a sound-set NAME
// column (surfaceprops col 3, propmaterials col 8 "fxsound"), so they are the
// foreign keys and NEITHER of their parsers changes.
//
// Shared unit - compiled into csprogs AND qwprogs.  MUST be listed AFTER
// shared/sh_weapons.qc (IMPACT_MAT_*), shared/sh_surfaceprops.qc (Surf_SoundSet /
// Surf_MaterialAtPoint) and shared/sh_propmaterials.qc (PropMat_For /
// PropMat_FxSound), and BEFORE shared/sh_pmove.qc, server/sv_physprop.qc,
// shared/sh_vehicle_phys.qc, client/cl_bulletimpact.qc and both *_main.qc.
//
// TEMPSTRING WARNING: MatSnd_Path/MatSnd_Pick build the path with strcat and
// return a TEMPSTRING.  Consume it IMMEDIATELY (sound / pointsound / localsound /
// precache_sound).  NEVER store one in a field or global - see the recycling war
// story in sh_surfaceprops.qc's header.  Everything the LOADER keeps is strzone'd,
// because argv()/strtolower() are tempstrings too.
//
// FOOTSTEPS ARE NOT IN THIS TABLE.  The footstep index is a 1-byte NETWORK value
// (sh_pmove.qc PM_EmitStepSound -> cl_main.qc), so its byte->path map has to be
// compile-time identical in both VMs; it lives in FS_SoundName() (sh_pmove.qc).
// See the note at the top of scripts/materialsounds.txt.
// ===========================================================================

// Contact kinds.  Order is arbitrary but MUST match MatSnd_KindCode below.
const float MSND_HARD   = 0;
const float MSND_SOFT   = 1;
const float MSND_BULLET = 2;
const float MSND_SCRAPE = 3;
const float MSND_BREAK  = 4;
const float MSND_KINDS  = 5;

const float MS_MAX_SET   = 24;
const float MS_MAX_ROW   = 160;
const float MS_MAX_ALIAS = 16;
const float MS_MAX_SLOT  = 120;   // == MS_MAX_SET * MSND_KINDS (literal: array sizes)

float  ms_set_count;
string ms_set_name [MS_MAX_SET];    // strzoned set name
float  ms_total    [MS_MAX_SLOT];   // variants per (set*MSND_KINDS + kind) - O(1) count

float  ms_row_n;
float  ms_row_set  [MS_MAX_ROW];
float  ms_row_kind [MS_MAX_ROW];
float  ms_row_count[MS_MAX_ROW];
float  ms_row_first[MS_MAX_ROW];
string ms_row_stem [MS_MAX_ROW];    // strzoned, relative to sounds/impacts/

float  ms_alias_n;
string ms_alias_from[MS_MAX_ALIAS]; // strzoned
float  ms_alias_to  [MS_MAX_ALIAS]; // -> set index

float  ms_default_set;   // "default" (aliased to metal), else set 0, else -1
float  ms_weapon_set;    // the weapon-drop set, resolved once at load
float  ms_loaded;

// kind token -> MSND_* (-1 unknown).
float(string k) MatSnd_KindCode =
{
    if (k == "hard")   return MSND_HARD;
    if (k == "soft")   return MSND_SOFT;
    if (k == "bullet") return MSND_BULLET;
    if (k == "scrape") return MSND_SCRAPE;
    if (k == "break")  return MSND_BREAK;
    return -1;
};

// MSND_* -> name, for the matsnd_dump readout.
string(float kind) MatSnd_KindName =
{
    if (kind == MSND_HARD)   return "hard";
    if (kind == MSND_SOFT)   return "soft";
    if (kind == MSND_BULLET) return "bullet";
    if (kind == MSND_SCRAPE) return "scrape";
    if (kind == MSND_BREAK)  return "break";
    return "?";
};

// Set name -> index WITHOUT following aliases (loader-side; -1 if absent).
float(string name) MatSnd_SetRaw =
{
    if (name == "") return -1;
    float i;
    for (i = 0; i < ms_set_count; i = i + 1)
        if (ms_set_name[i] == name)
            return i;
    return -1;
};

// Set name -> index, FOLLOWING sndalias (single level).  -1 = unknown / "".
// A real set always wins over an alias of the same name.
float(string name) MatSnd_SetIndex =
{
    if (name == "") return -1;
    float i = MatSnd_SetRaw(name);
    if (i >= 0) return i;
    for (i = 0; i < ms_alias_n; i = i + 1)
        if (ms_alias_from[i] == name)
            return ms_alias_to[i];
    return -1;
};

// Set index -> name ("default" when out of range).
string(float set) MatSnd_SetName =
{
    if (set < 0 || set >= ms_set_count) return "default";
    return ms_set_name[set];
};

// How many variants does (set, kind) have?  O(1).
float(float set, float kind) MatSnd_Count =
{
    if (set < 0 || set >= ms_set_count || kind < 0 || kind >= MSND_KINDS) return 0;
    return ms_total[set * MSND_KINDS + kind];
};

// i'th variant path of (set, kind), i = 0 .. MatSnd_Count-1.  "" when out of range.
// Walks the rows accumulating counts, so rows for the same (set,kind) need not be
// contiguous and each row keeps its own `first` (metal_solid_impact_hard{1,4,5}).
// Worst case ~87 float compares; cheaper than one Surf_MaterialFor pattern scan.
string(float set, float kind, float i) MatSnd_Path =
{
    if (i < 0 || i >= MatSnd_Count(set, kind)) return "";
    float r, acc = 0;
    for (r = 0; r < ms_row_n; r = r + 1)
    {
        if (ms_row_set[r] != set || ms_row_kind[r] != kind)
            continue;
        if (i < acc + ms_row_count[r])
            return strcat("sounds/impacts/", ms_row_stem[r],
                          itos(ms_row_first[r] + (i - acc)), ".wav");
        acc = acc + ms_row_count[r];
    }
    return "";
};

// One random variant of (set, kind), or "" when the set has none of that kind.
string(float set, float kind) MatSnd_PickOne =
{
    float n = MatSnd_Count(set, kind);
    if (n <= 0) return "";
    float i = floor(random() * n);
    if (i >= n) i = n - 1;      // random() is [0,1) but do not bet the table on it
    if (i < 0)  i = 0;
    return MatSnd_Path(set, kind, i);
};

// Which kind stands in when a set has none of the requested one?
// SCRAPE has NO fallback on purpose: a one-shot forced under SOUNDFLAG_FORCELOOP
// machine-guns.  A material with no scrape loop slides SILENTLY instead.
float(float kind) MatSnd_KindFallback =
{
    if (kind == MSND_SCRAPE) return -1;
    if (kind == MSND_HARD)   return MSND_SOFT;
    return MSND_HARD;   // soft / bullet / break -> hard
};

// Random variant with the full fallback chain:
//   (set,kind) -> (set,fallback-kind) -> (default,kind) -> (default,fallback-kind) -> ""
// "" is safe everywhere: sound("") is a no-op in this engine (see PhysFiles_StopScrape)
// and every caller here tests for it.  In practice step 1 always hits, because the
// materials missing a kind BORROW another material's file in materialsounds.txt --
// data-level borrowing is visible and per-material tunable; the chain below is pure
// defence against a typo'd or missing data file.
string(float set, float kind) MatSnd_Pick =
{
    string s = MatSnd_PickOne(set, kind);
    if (s != "") return s;
    float fk = MatSnd_KindFallback(kind);
    if (fk >= 0)
    {
        s = MatSnd_PickOne(set, fk);
        if (s != "") return s;
    }
    if (ms_default_set >= 0 && ms_default_set != set)
    {
        s = MatSnd_PickOne(ms_default_set, kind);
        if (s != "") return s;
        if (fk >= 0)
        {
            s = MatSnd_PickOne(ms_default_set, fk);
            if (s != "") return s;
        }
    }
    return "";
};

// Name-keyed convenience (surfaceprops col 3 / propmaterials col 8 hand you a name).
string(string setname, float kind) MatSnd_PickName =
{
    return MatSnd_Pick(MatSnd_SetIndex(setname), kind);
};

// prop-material index (sh_propmaterials.qc) -> sound-set index.
// PropMat_FxSound(-1) is "" -> -1 -> callers fall through to ms_default_set.
float(float propmat) MatSnd_SetForPropMat =
{
    return MatSnd_SetIndex(PropMat_FxSound(propmat));
};

// An entity's model path.  Server props are built with setmodel() so .model is
// populated; CSQC mirrors use setmodelindex() so .model is EMPTY there and the
// name has to come from the model index (proven at cl_debuginfo.qc:2153-2170).
// modelnameforindex (#334) is only declared for CSQC (cl_defs.qc:1518), hence the
// ifdef rather than a second builtin declaration on the server.
string(entity e) MatSnd_ModelPath =
{
    if (!e) return "";
#ifdef CSQC
    if (e.model == "" && e.modelindex)
        return modelnameforindex(e.modelindex);
#endif
    return e.model;
};

// Sound set for an impact at world point p on entity e.
//   - alias-model entities (phys props, statics): MODEL path -> propmaterials col 8.
//   - "*N" models are inline BSP submodels (func_door / func_breakable): fall through
//     to the surface path, which is what they actually are.
//   - everything else (world, brush ents, misses): the TEXTURE at p -> surfaceprops col 3.
//   - impactmat is the coarse IMPACT_MAT_* the impact event already carries; used ONLY
//     as a last-resort backstop when neither lookup resolves (e.g. a remote client whose
//     wire entnum no longer maps to a CSQC entity).  Pass -1 if you have no code.
// Callers gate FLESH out before calling.  Returns -1 when nothing resolves.
float(entity e, vector p, float impactmat) MatSnd_SetForImpact =
{
    float s;
    if (e && e != world)
    {
        // Dropped guns keep the light-metal "weapon" set - the same one they BANG with,
        // and its bullet run is borrowed from metal_solid_impact_bullet1-4, i.e. exactly
        // the sound they make today.  Their model paths would not resolve to metal.
        if (e.classname == "csqc_dropped_weapon" || e.classname == "dropped_weapon")
            return ms_weapon_set;
        string mn = MatSnd_ModelPath(e);
        if (mn != "" && substring(mn, 0, 1) != "*")
        {
            s = MatSnd_SetIndex(PropMat_FxSound(PropMat_For(mn)));
            if (s >= 0) return s;
        }
    }
    s = MatSnd_SetIndex(Surf_SoundSet(Surf_MaterialAtPoint(e, p)));
    if (s >= 0) return s;
    if (impactmat == IMPACT_MAT_METAL || impactmat == IMPACT_MAT_METAL_NODECAL)
        return MatSnd_SetIndex("metal");
    if (impactmat == IMPACT_MAT_WOOD)  return MatSnd_SetIndex("wood");
    if (impactmat == IMPACT_MAT_GLASS) return MatSnd_SetIndex("glass");
    return -1;
};

// Walk every row and precache every variant.  Replaces the hand-list that used to
// live in sv_physprop.qc, which was 1:1 coupled to the deleted PhysObj_FxSound.
//   SERVER: ALL kinds - anything played with sound() must be in the precache table.
//   CLIENT: BULLET only - prop bangs/scrapes are SERVER sound() calls that arrive as a
//           precache INDEX resolved from the server's soundlist by the client engine, so
//           CSQC never names them.  Footsteps come from FS_PrecacheAll (sh_pmove.qc).
// Duplicate names (the borrowed rows) are deduped by the engine's precache table.
void() MatSnd_PrecacheAll =
{
    float r, v;
    for (r = 0; r < ms_row_n; r = r + 1)
    {
#ifdef CSQC
        if (ms_row_kind[r] != MSND_BULLET)
            continue;
#endif
        for (v = 0; v < ms_row_count[r]; v = v + 1)
            precache_sound(strcat("sounds/impacts/", ms_row_stem[r],
                                  itos(ms_row_first[r] + v), ".wav"));
    }
};

// Console readout for tuning: per (set,kind) variant counts + the first path.
void() MatSnd_Dump =
{
    float s, k, n;
    print(sprintf("materialsounds: %g sets, %g rows, %g aliases%s\n",
                  ms_set_count, ms_row_n, ms_alias_n,
                  ms_loaded ? "" : "  (NOT LOADED)"));
    for (s = 0; s < ms_set_count; s = s + 1)
    {
        print(sprintf("  %s%s\n", ms_set_name[s],
                      (s == ms_default_set) ? "  (default)" : ""));
        for (k = 0; k < MSND_KINDS; k = k + 1)
        {
            n = MatSnd_Count(s, k);
            if (n > 0)
                print(sprintf("      %-7s %2g   %s\n", MatSnd_KindName(k), n,
                              MatSnd_Path(s, k, 0)));
        }
    }
    for (s = 0; s < ms_alias_n; s = s + 1)
        print(sprintf("  alias %-10s -> %s\n", ms_alias_from[s], MatSnd_SetName(ms_alias_to[s])));
};

// Find a set by name, creating it if there is room.  Loader-side only.
float(string name) MatSnd_SetEnsure =
{
    float i = MatSnd_SetRaw(name);
    if (i >= 0) return i;
    if (ms_set_count >= MS_MAX_SET)
    {
        dprint(sprintf("materialsounds: too many sets (max %g), dropping '%s'\n", MS_MAX_SET, name));
        return -1;
    }
    i = ms_set_count;
    ms_set_name[i] = strzone(name);
    float k;
    for (k = 0; k < MSND_KINDS; k = k + 1)
        ms_total[i * MSND_KINDS + k] = 0;
    ms_set_count = i + 1;
    return i;
};

// (Re)load scripts/materialsounds.txt.  Called at client + server init and from the
// `matsnd_reloadsounds` client command.  Missing file => every lookup returns "" and
// the callers no-op (props go silent, bullet rics fall back to sounds/weapons/ric*).
void() MatSnd_LoadSounds =
{
    float k;
    // Free the previous strzoned strings (reload) so we do not leak.
    if (ms_loaded)
    {
        for (k = 0; k < ms_set_count; k = k + 1)
            strunzone(ms_set_name[k]);
        for (k = 0; k < ms_row_n; k = k + 1)
            strunzone(ms_row_stem[k]);
        for (k = 0; k < ms_alias_n; k = k + 1)
            strunzone(ms_alias_from[k]);
    }

    ms_set_count   = 0;
    ms_row_n       = 0;
    ms_alias_n     = 0;
    ms_default_set = -1;
    ms_weapon_set  = -1;
    ms_loaded      = 0;

    filestream f = fopen("scripts/materialsounds.txt", FILE_READ);
    if (f < 0)
    {
        dprint("materialsounds: scripts/materialsounds.txt not found - contact sounds disabled\n");
        return;
    }

    string line = fgets(f);
    while (line)
    {
        float n = tokenize(line);
        // comment/blank lines have argv(0) != "snd"/"sndalias" and are skipped naturally.
        if (n >= 5 && argv(0) == "snd")
        {
            float kind = MatSnd_KindCode(strtolower(argv(2)));
            if (kind < 0)
                dprint(sprintf("materialsounds: unknown kind '%s' (set '%s') - row skipped\n",
                               argv(2), argv(1)));
            else if (ms_row_n >= MS_MAX_ROW)
                dprint(sprintf("materialsounds: too many rows (max %g) - '%s %s' skipped\n",
                               MS_MAX_ROW, argv(1), argv(2)));
            else
            {
                float set = MatSnd_SetEnsure(strtolower(argv(1)));
                float cnt = stof(argv(3));
                if (set >= 0 && cnt >= 1)
                {
                    float ri = ms_row_n;
                    ms_row_set[ri]   = set;
                    ms_row_kind[ri]  = kind;
                    ms_row_count[ri] = cnt;
                    ms_row_first[ri] = (n >= 6) ? stof(argv(5)) : 1;
                    // strzone: argv()/strtolower() are TEMPSTRINGS that get recycled
                    // during gameplay, which would corrupt the table.
                    ms_row_stem[ri]  = strzone(strtolower(argv(4)));
                    ms_row_n = ri + 1;
                    ms_total[set * MSND_KINDS + kind] = ms_total[set * MSND_KINDS + kind] + cnt;
                }
            }
        }
        else if (n >= 3 && argv(0) == "sndalias")
        {
            // Aliases live at the BOTTOM of the file, so the target set already exists.
            float tgt = MatSnd_SetRaw(strtolower(argv(2)));
            if (tgt < 0)
                dprint(sprintf("materialsounds: sndalias '%s' -> unknown set '%s' - ignored\n",
                               argv(1), argv(2)));
            else if (ms_alias_n >= MS_MAX_ALIAS)
                dprint(sprintf("materialsounds: too many aliases (max %g) - '%s' skipped\n",
                               MS_MAX_ALIAS, argv(1)));
            else
            {
                ms_alias_from[ms_alias_n] = strzone(strtolower(argv(1)));
                ms_alias_to  [ms_alias_n] = tgt;
                ms_alias_n = ms_alias_n + 1;
            }
        }
        line = fgets(f);
    }
    fclose(f);

    // "default" is an alias in the shipped file; fall back to set 0 (metal) if absent.
    ms_default_set = MatSnd_SetIndex("default");
    if (ms_default_set < 0 && ms_set_count > 0)
        ms_default_set = 0;
    ms_weapon_set = MatSnd_SetIndex("weapon");
    if (ms_weapon_set < 0)
        ms_weapon_set = ms_default_set;
    ms_loaded = 1;
};
