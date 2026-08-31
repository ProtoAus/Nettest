// shared/sh_modellist.qc
// ----------------------------------------------------------------------------
// Sven Co-op's GLOBAL model replacement layer — worldspawn's `globalmodellist`.
//
// A map names one file of old/new pairs and every model matching the left
// column loads the right one instead:
//
//     "models/v_crowbar.mdl"  "models/pizza_ya_san/v_crowbar.mdl"
//     "models/w_battery.mdl"  "models/pizza_ya_san/bowl.mdl"
//
// This is how a Sven map reskins the PLAYER'S OWN kit without shipping a mod.
// pizza_ya_san1 uses it for 22 pairs: the medkit, crowbar, glock, m16, grenade
// and barnacle grapple in all three forms (v_/p_/w_), plus the HEV battery as a
// rice bowl.  The key was read by nothing at all, so the map ran with stock
// Half-Life weapons in a Japanese pizza shop.
//
// WHY THIS IS SHARED AND sv_soundlist.qc IS NOT.  Sound is emitted server-side
// through one wrapper, so that layer could live in server/.  Models are not:
// the first-person viewmodel is set ENTIRELY by CSQC (cl_weapons.qc's
// setmodel(csqc_viewmodel_ent, predicted_player.weapon_viewmodel)), from a
// compile-time constant in the weapon's own shared file, and .weapon_viewmodel
// is never networked.  A server-only table would remap monsters and brushes and
// leave every gun in your hands stock.  So the table is compiled into both VMs
// and each sources the path its own way — see Modellist_LoadFromWorld below.
//
// THE CHOKEPOINT IS THE BUILTIN ITSELF.  There are 401 precache_model and 321
// setmodel call sites across server/, shared/ and client/, and 231 of the
// setmodels are one-per-weapon inside shared/weapons/.  Wrapping them by hand
// would be 700 edits and would silently rot the moment someone added the 702nd.
// Instead sv_defs.qc and cl_defs.qc bind the builtins under _raw names and the
// ORIGINAL names are these QC functions.  Every existing call site is remapped
// with no edit at all, and so is every future one.  Both defs files are the
// first entry in their .src, and this unit is the second, so the wrappers exist
// before any caller is compiled.
//
// Inline BSP brush models ("*43") and setmodelindex() are untouched: the lookup
// is an exact string match and an index carries no path.
// ----------------------------------------------------------------------------

// One file, 512 pairs.  Unlike the per-monster soundlist there is exactly one
// of these per map (it lives on worldspawn), so there is no file table — just
// the pair pool.  pizza_ya_san1 uses 22; the largest globalmodellist shipped
// with Sven is ressya_no_tabi's, well under this.
const float ML_MAX_PAIRS = 512;

// Declared rather than harvested in ED_ParseUnknownEpair, so the engine binds
// the key straight onto worldspawn — the same route `.string soundlist` takes in
// sv_monsters.qc.  Harmless in CSQC, which never has a worldspawn entity and
// reads the lump directly instead.
.string globalmodellist;

string ml_from[ML_MAX_PAIRS];
string ml_to[ML_MAX_PAIRS];
float  ml_paircount;

float  ml_loaded;			// a load has been resolved for THIS map
float  ml_overflow;			// pairs that did not fit
float  ml_missing;			// replacement targets that are not on disk
string ml_srcpath;
float  ml_reported;

// Per-map reset.  NOT optional on the client: CSQC persists across a map change
// in FTE — CSQC_WorldLoaded opens by clearing "stale linked lists from previous
// map" for exactly that reason — so without this, map two would keep map one's
// replacements and leak every strzone'd pair.  The server reloads its progs per
// map and would be fine either way; it calls this too so there is one rule.
void() Modellist_Reset =
{
	float i;
	for (i = 0; i < ml_paircount; i = i + 1)
	{
		strunzone(ml_from[i]);
		strunzone(ml_to[i]);
	}
	ml_paircount = 0;
	if (ml_srcpath != "")
		strunzone(ml_srcpath);
	ml_srcpath = "";
	ml_loaded   = FALSE;
	ml_overflow = 0;
	ml_missing  = 0;
	ml_reported = FALSE;
};

// Trailing junk on a value.  fgets already drops \r (pr_bgcmd.c: "read up to the
// next \n, ignoring any \rs"), so what is left is the hand-edited case: a
// missing closing quote, a stray one, trailing spaces.  daikonfarmer.txt in this
// same map's SOUND lists has exactly that defect twice, so it is not
// hypothetical.  Tolerate it rather than desync the pair list.
string(string s) Modellist_Clean =
{
	float n = strlen(s);
	while (n > 0)
	{
		string c = substring(s, n - 1, 1);
		if (c != "\"" && c != " " && c != "\t" && c != "\r" && c != "\n")
			break;
		n = n - 1;
	}
	if (n <= 0)
		return "";
	if (n == strlen(s))
		return s;
	return substring(s, 0, n);
};

// The map writes the path relative to somewhere inside models/, with a leading
// "../" (pizza_ya_san1 writes "../pizza_ya_san/models.txt").  Strip the relative
// segments and try the places the file can actually be.
filestream(string path) Modellist_Open =
{
	filestream f;

	string rel = path;
	while (substring(rel, 0, 3) == "../" || substring(rel, 0, 2) == "./")
	{
		if (substring(rel, 0, 3) == "../")
			rel = substring(rel, 3, -1);
		else
			rel = substring(rel, 2, -1);
	}

	// As written, first — a map giving a real VFS path deserves to be taken at
	// its word.  SKIPPED when the path had relative segments, because FTE's
	// qcfopen refuses any name containing ".." and prints "Access denied" to the
	// console when it does.  Six of those on map load is a warning about
	// nothing, and a warning about nothing is how a real one gets ignored.
	if (rel == path)
	{
		f = fopen(path, FILE_READ);
		if (f >= 0)
			return f;
	}

	f = fopen(strcat("models/", rel), FILE_READ);
	if (f >= 0)
		return f;

	f = fopen(rel, FILE_READ);
	return f;
};

// Parse.  Safe to call twice (the client may retry once the world is up); the
// second call is a no-op.
void(string path) Modellist_Load =
{
	if (ml_loaded)
		return;
	ml_loaded = TRUE;

	if (path == "" || !path)
		return;

	filestream f = Modellist_Open(path);
	if (f < 0)
	{
		dprint(sprintf("[modellist] cannot open \"%s\"\n", path));
		return;
	}

	ml_srcpath = strzone(path);

	// TERMINATION IS NOT `while (line)`, for the reason spelled out at
	// sv_sentences.qc:161 — PF_fgets returns the NULL string at EOF and a real
	// tempstring containing "" for a blank line, and QC cannot tell the two
	// apart because both `!s` and `s != ""` compile to content tests.  This
	// file's blank lines are not hypothetical: models.txt separates its weapon
	// groups with them, so a naive loop would load three pairs and drop
	// nineteen.  Same fix as the sentence and sound loaders: stop only after a
	// RUN of empty reads.
	const float ML_EOF_RUN = 16;
	float empties = 0;
	string line;
	for (;;)
	{
		line = fgets(f);
		if (!line)
		{
			empties = empties + 1;
			if (empties >= ML_EOF_RUN)
				break;
			continue;
		}
		empties = 0;

		// tokenize is safe here: nothing this function calls tokenizes, and both
		// callers run at map load rather than inside an argv walk of their own.
		float n = tokenize(line);
		if (n < 2)
			continue;

		string from = Modellist_Clean(argv(0));
		string to   = Modellist_Clean(argv(1));
		if (from == "" || to == "" || substring(from, 0, 2) == "//")
			continue;

		// THE TARGET HAS TO EXIST BEFORE THE PAIR IS TAKEN.  A replacement
		// pointing at a file that is not on disk is worse than no replacement:
		// setmodel on a missing path gives you an invisible weapon, so one
		// mistyped line would delete a gun rather than reskin it.  Dropping the
		// pair leaves the canonical model loading, which is the graceful
		// direction, and the count is reported so the mistake stays visible.
		string pack = whichpack(to);
		if (pack == "" || !pack)
		{
			ml_missing = ml_missing + 1;
			continue;
		}

		if (ml_paircount >= ML_MAX_PAIRS)
		{
			ml_overflow = ml_overflow + 1;
			continue;
		}

		ml_from[ml_paircount] = strzone(from);
		ml_to[ml_paircount]   = strzone(to);
		ml_paircount = ml_paircount + 1;
	}
	fclose(f);
};

// The lookup.  Linear over the pool — 22 entries on this map, and it sits in
// front of every setmodel, so the early-out on an empty table is the case that
// matters: a map with no globalmodellist pays one float compare per call.
string(string mdl) Modellist_Remap =
{
	if (!ml_paircount)
		return mdl;
	if (mdl == "" || !mdl)
		return mdl;
	// Inline BSP submodels can never match a pair and are the single most
	// common argument setmodel sees on a Sven map (67 func_wall_toggle alone on
	// pizza_ya_san1), so reject them before the scan rather than inside it.
	if (substring(mdl, 0, 1) == "*")
		return mdl;

	float i;
	for (i = 0; i < ml_paircount; i = i + 1)
		if (ml_from[i] == mdl)
			return ml_to[i];
	return mdl;
};

// ----------------------------------------------------------------------------
// THE WRAPPERS.  These carry the builtins' original names; sv_defs.qc and
// cl_defs.qc bind the real builtins as *_raw.  Do not rename these without
// renaming those, or 722 call sites change meaning at once.
// ----------------------------------------------------------------------------
string(string s) precache_model =
{
	return precache_model_raw(Modellist_Remap(s));
};

void(entity e, string m) setmodel =
{
	setmodel_raw(e, Modellist_Remap(m));
};

// ----------------------------------------------------------------------------
// Sourcing the path.
//
// SERVER: worldspawn declares `.string globalmodellist`, so the engine binds
// the key directly and sv_main.qc's worldspawn() reads self.globalmodellist —
// worldspawn's keyvalues are all parsed before its spawn function body runs.
//
// CLIENT: there is no worldspawn entity in CSQC, so walk the BSP's own entity
// lump with getentitytoken.  That is its documented purpose and the mod already
// does it in cl_maplights.qc; no networking is involved.
//
// TEMPSTRING SAFETY, copied from MapLights_Load: getentitytoken returns
// tempstrings, so the key flag is captured BEFORE the value token is fetched and
// the value is consumed immediately.  Nothing string-typed is held across a
// further token read.
// ----------------------------------------------------------------------------
// Returns TRUE when the lump was READABLE — not when a key was found.  The
// caller needs that distinction: "no globalmodellist on this map" is a final
// answer, but "the worldmodel is not up yet" means try again later.
//
// CSQC ONLY.  getentitytoken (#355) is a client builtin — it is declared in
// cl_defs.qc and has no server counterpart, because SSQC has the real
// worldspawn entity and reads self.globalmodellist instead.
#ifdef CSQC
float() Modellist_LoadFromWorld =
{
	if (ml_loaded)
		return TRUE;

	float guard = 0;
	float sawtoken = 0;
	string t;

	getentitytoken("");			// reset to the worldmodel lump
	while ((t = getentitytoken()) != "")
	{
		sawtoken = 1;
		guard = guard + 1;
		if (guard > 400000) break;	// malformed-lump backstop
		if (t != "{")
			continue;

		float is_world = 0;
		string found = "";

		for (;;)
		{
			t = getentitytoken();		// key
			guard = guard + 1;
			if (guard > 400000) break;
			if (t == "" || t == "}") break;

			float k_class = (t == "classname");
			float k_list  = (t == "globalmodellist");

			t = getentitytoken();		// value
			guard = guard + 1;
			if (t == "") break;

			if (k_class && t == "worldspawn")
				is_world = 1;
			else if (k_list)
				found = strzone(t);	// must survive the next token read
		}

		// worldspawn is the first entity in the lump, so one block is all that
		// is ever inspected in practice — but do not ASSUME it, because a
		// compiler is free to emit classname last and this loop must still
		// recognise the block it has already finished reading.
		if (is_world)
		{
			// A worldspawn WITHOUT the key is no longer a final answer: Sven
			// takes it from maps/<name>.cfg too, and every They Hunger map uses
			// that spelling instead of this one.  The cfg is server-side, so it
			// reaches CSQC as serverinfo — leave ml_loaded alone here so the
			// caller's second source can still load.  Modellist_Load owns the
			// latch in both paths.
			if (found != "")
			{
				Modellist_Load(found);
				strunzone(found);
			}
			return TRUE;
		}
		if (found != "")
			strunzone(found);
		break;			// first block was not worldspawn — nothing to find
	}

	if (!sawtoken)
		return FALSE;		// worldmodel not up yet; caller should retry

	// Lump read, no key.  Deliberately does NOT latch — see the is_world branch
	// above: the serverinfo fallback is the other half of the answer.
	return TRUE;
};
#endif

// CLIENT ONLY, and only because of an ordering fact: CSQC's precache_everything()
// runs from CSQC_Init, which fires ONCE PER CONNECTION, while the entity lump is
// only readable per map from CSQC_WorldLoaded.  So on the client the wholesale
// precache has already happened under the canonical names by the time the pairs
// are known, and on map two it does not happen again at all.  Precaching the
// targets here closes both gaps.
//
// Not needed server-side: worldspawn parses its own key before its body runs, so
// the load lands ahead of precache_everything() and every canonical precache_model
// call is remapped as it happens.
//
// _raw deliberately: these ARE the final paths.  Sending them back through the
// wrapper would scan the table for a match that cannot exist.
void() Modellist_PrecacheTargets =
{
	float i;
	for (i = 0; i < ml_paircount; i = i + 1)
		precache_model_raw(ml_to[i]);
};

// One line at the end of map load.  Prints only once pairs actually loaded, so a
// map without the key never says anything and never pays.
void() Modellist_Report =
{
	if (ml_reported || !ml_paircount)
		return;
	ml_reported = TRUE;

	// print, not dprint, and deliberately — the same choice MapLights_Load makes
	// one line below the caller in CSQC_WorldLoaded, for the same reason.
	// cfg/default.cfg sets `developer 0` and RE-EXECS on every map load, after
	// any +set or bare +developer on the command line, so a developer-gated line
	// in a per-map hook is invisible on the client no matter how the client was
	// launched.  This only fires on a map that actually carries a
	// globalmodellist, so it is one line on the maps where it is the answer to
	// "why are my weapons the wrong models" and silence everywhere else.
	print(sprintf("[modellist] %s: %g pair(s)%s%s\n",
	              ml_srcpath, ml_paircount,
	              ml_overflow ? sprintf(", %g DROPPED (pool full)", ml_overflow) : "",
	              ml_missing  ? sprintf(", %g target(s) missing", ml_missing) : ""));

	// A LOOKUP CHECK, not just a count, because "22 pairs parsed" and "the gun
	// in your hands changed" are two different claims and only the second is the
	// feature.  Runs the first pair back through Modellist_Remap, and asserts
	// the pass-through case too — an unmapped path MUST come back unchanged, or
	// every model the list omits would resolve to nothing.
	string k   = ml_from[0];
	string got = Modellist_Remap(k);
	dprint(sprintf("[modellist]   \"%s\" -> \"%s\"%s\n", k, got,
	               (got == ml_to[0]) ? "" : "  LOOKUP FAILED"));
	if (Modellist_Remap("models/that/is/not/in/any/list.mdl")
	    != "models/that/is/not/in/any/list.mdl")
		dprint("[modellist]   PASS-THROUGH FAILED\n");
	if (Modellist_Remap("*43") != "*43")
		dprint("[modellist]   BRUSH PASS-THROUGH FAILED\n");
};
