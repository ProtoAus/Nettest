// shared/sh_soundlist_global.qc
// ----------------------------------------------------------------------------
// Sven Co-op's GLOBAL sound replacement layer — worldspawn's `globalsoundlist`.
//
// The sound twin of sh_modellist.qc, and by breadth the bigger of the two: 18
// maps in the mounted corpus set globalsoundlist against globalmodellist's 6,
// and TWELVE of the twenty They Hunger maps set it — every one of them to
// "../hunger/hungerglobal.txt".
//
// THERE ARE TWO FILES CALLED hungerglobal.txt AND ONLY ONE OF THEM IS THIS ONE.
// models/hunger/hungerglobal.txt is a MODEL pair list; sound/hunger/hungerglobal.txt
// is this one.  The key's path is written "../hunger/hungerglobal.txt" and
// resolves under sound/ — so reading the models/ copy, which is the one that
// turns up first in a file search, gives you a table of .mdl pairs and the
// conclusion that the feature is about models.  It is not.
//
// What They Hunger's 20 pairs actually cover: the platform and train sounds,
// the outdoor ambience (crickets, burning, distant mortars, the waterfall),
// the snark set redirected to the zombie RAT, bullet ricochets
// (weapons/hks1-3.wav), the sniper report, and five "!HEV_*" entries pointed at
// null.wav to silence the HEV suit voice. That spread is why this cannot ride on
// the per-monster soundlist: almost none of it is a monster.
//
// LAYERING.  server/sv_soundlist.qc's per-monster `.soundlist` runs FIRST, in
// AI_Sound, and its result then passes through the wrapper below.  A path the
// per-monster table already rewrote will not match the global table, so the two
// compose rather than fight; per-entity wins, global is the fallback.
//
// The trap that layer documents at sv_soundlist.qc:19-26 applies here unchanged:
// the lookup is keyed on the path our own code EMITS, so a class emitting a
// different name than Half-Life's matches nothing however good the parser is.
// ----------------------------------------------------------------------------

const float GSL_MAX_PAIRS = 512;

// Declared rather than harvested in ED_ParseUnknownEpair, so the engine binds
// the key straight onto worldspawn — the same route .string globalmodellist and
// .string soundlist take.
.string globalsoundlist;

string gsl_from[GSL_MAX_PAIRS];
string gsl_to[GSL_MAX_PAIRS];
float  gsl_paircount;

float  gsl_loaded;
float  gsl_overflow;
float  gsl_missing;
float  gsl_reported;
string gsl_srcpath;

// Per-map reset, for the reason spelled out in sh_modellist.qc: CSQC survives a
// map change, so without this map two keeps map one's replacements and leaks
// every strzone'd pair.
void() GSoundlist_Reset =
{
	float i;
	for (i = 0; i < gsl_paircount; i = i + 1)
	{
		strunzone(gsl_from[i]);
		strunzone(gsl_to[i]);
	}
	gsl_paircount = 0;
	if (gsl_srcpath != "")
		strunzone(gsl_srcpath);
	gsl_srcpath = "";
	gsl_loaded   = FALSE;
	gsl_overflow = 0;
	gsl_missing  = 0;
	gsl_reported = FALSE;
};

// Same trailing-junk tolerance as the other two loaders — a hand-edited list
// leaves stray quotes and spaces, and one of pizza_ya_san's shipped lists really
// does have two unterminated quotes.
string(string s) GSoundlist_Clean =
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

filestream(string path) GSoundlist_Open =
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

	// Raw path only when it had no relative segments — FTE's qcfopen refuses any
	// name containing ".." and prints "Access denied" to the console, and every
	// globalsoundlist in the corpus is written with a leading "../".
	if (rel == path)
	{
		f = fopen(path, FILE_READ);
		if (f >= 0)
			return f;
	}

	f = fopen(strcat("sound/", rel), FILE_READ);
	if (f >= 0)
		return f;

	f = fopen(rel, FILE_READ);
	return f;
};

void(string path) GSoundlist_Load =
{
	if (gsl_loaded)
		return;
	gsl_loaded = TRUE;

	if (path == "" || !path)
		return;

	filestream f = GSoundlist_Open(path);
	if (f < 0)
	{
		dprint(sprintf("[gsoundlist] cannot open \"%s\"\n", path));
		return;
	}
	gsl_srcpath = strzone(path);

	// NOT `while (line)` — PF_fgets returns the NULL string at EOF and a real
	// tempstring for a blank line, and QC cannot tell them apart because both
	// `!s` and `s != ""` compile to content tests.  Stop only after a RUN of
	// empty reads.  Written up at sv_sentences.qc:161; the same fix is in
	// sv_soundlist.qc and sh_modellist.qc.
	const float GSL_EOF_RUN = 16;
	float empties = 0;
	string line;
	for (;;)
	{
		line = fgets(f);
		if (!line)
		{
			empties = empties + 1;
			if (empties >= GSL_EOF_RUN)
				break;
			continue;
		}
		empties = 0;

		float n = tokenize(line);
		if (n < 2)
			continue;

		string from = GSoundlist_Clean(argv(0));
		string to   = GSoundlist_Clean(argv(1));
		if (from == "" || to == "" || substring(from, 0, 2) == "//")
			continue;

		// The target must exist, or the replacement is worse than none: the
		// emitter loses its own sound and gains silence.  Dropping the pair
		// keeps the canonical sound, which is the graceful direction.
		//
		// A LEADING '!' IS A SENTENCE NAME, NOT A FILE.  They Hunger's list ends
		// with five "!HEV_*" entries pointed at null.wav to silence the suit
		// voice; whichpack would reject the key side out of hand.  Those are kept
		// - the lookup is a string match either way - but only when the TARGET
		// resolves, same as everything else.
		string pack = whichpack(strcat("sound/", to));
		if (pack == "" || !pack)
		{
			gsl_missing = gsl_missing + 1;
			continue;
		}

		if (gsl_paircount >= GSL_MAX_PAIRS)
		{
			gsl_overflow = gsl_overflow + 1;
			continue;
		}

		gsl_from[gsl_paircount] = strzone(from);
		gsl_to[gsl_paircount]   = strzone(to);
		gsl_paircount = gsl_paircount + 1;
	}
	fclose(f);
};

string(string samp) GSoundlist_Remap =
{
	if (!gsl_paircount)
		return samp;
	if (samp == "" || !samp)
		return samp;

	float i;
	for (i = 0; i < gsl_paircount; i = i + 1)
		if (gsl_from[i] == samp)
			return gsl_to[i];
	return samp;
};

// ----------------------------------------------------------------------------
// THE WRAPPERS.  sv_defs.qc and cl_defs.qc bind the real builtins as *_raw.
//
// NOTE THE DEFAULT VALUES, AND NOTE THAT THEY ARE NOT `optional`.  The builtin
// declares its tail as `optional float speedpct, optional float flags, optional
// float timeofs`, and `optional` is safe ONLY on builtins: on a QC function an
// omitted argument is not zero, it is whatever the previous call left in the
// parameter globals, and optional_audit.py exists because that has silently
// broken this codebase three times.  fteqcc's own comment (qcc.h:379) says to
// "use the defltvalue instead" for QC functions, and marking a parameter
// optional actively DEFEATS a declared default (qcc_pr_comp.c:9186's
// `&& !optional`).  So: real defaults, no optional keyword, audit stays clean.
//
// Passing 0 explicitly where the caller omitted the argument is identical to
// omitting it — FTE reads a pitch of 0 as "no pitch", which is the same note
// sv_soundlist.qc:249 records for AI_Sound vs AI_SoundEx.
// ----------------------------------------------------------------------------
void(entity e, float chan, string samp, float vol, float atten,
     float speedpct = 0, float flags = 0, float timeofs = 0) sound =
{
	sound_raw(e, chan, GSoundlist_Remap(samp), vol, atten, speedpct, flags, timeofs);
};

string(string s) precache_sound =
{
	return precache_sound_raw(GSoundlist_Remap(s));
};

// Client-side predicted audio.  Every weapon in shared/weapons/*.qc plays its
// own shot through this rather than sound(), so leaving it unwrapped would remap
// the sound everyone else hears and not the one the shooter does.
//
// THE VOLUME DEFAULT IS 1, NOT 0, AND THAT IS THE POINT OF THIS COMMENT.
// The builtin's own default is 1 (pr_clcmd.c PF_cl_localsound reads
// `vol = (callargc>2) ? PARM2 : 1`), so a wrapper defaulting it to 0 does not
// "pass the default through" — it mixes every one-argument call at silence.
//
// 363 of the 368 call sites here pass only the sample name, so a 0 muted every
// predicted weapon sound in the mod at once, while the five sites that DO pass a
// volume (cl_radio, the slide/footstep pair) kept working.  That is what it looks
// like from the outside: radio and footsteps fine, every gun silent — and for a
// weapon that predicts only PART of its audio, exactly that part missing.  The HL
// shotgun kept its fire, which uses sound(), and lost its pump and shell inserts,
// which use this.
//
// Worse than plain silence: each call site stamps CSQC_RecordPredictedWeaponSound
// on the next line, which mutes the authoritative server echo for a full second
// (cl_main.qc).  A zero-volume prediction does not merely go unheard — it
// suppresses the copy that would otherwise have covered for it.
//
// Unlike the sound() wrapper above, where 0 IS the neutral value for
// speedpct/flags/timeofs, 0 is not neutral for a volume.  Do not "make this
// consistent" with that one.
#ifdef CSQC
void(string s, float channel = 0, float volume = 1) localsound =
{
	localsound_raw(GSoundlist_Remap(s), channel, volume);
};
#endif

// Precache the replacement targets.  Server-side this is belt and braces (the
// wrapper above already remaps each canonical precache as it happens); on the
// client it is load-bearing, because CSQC's precache_everything runs from
// CSQC_Init — once per CONNECTION — while the entity lump is only readable per
// map from CSQC_WorldLoaded.
void() GSoundlist_PrecacheTargets =
{
	float i;
	for (i = 0; i < gsl_paircount; i = i + 1)
		precache_sound_raw(gsl_to[i]);
};

#ifdef CSQC
// CSQC has no worldspawn entity, so read the BSP's own lump — the same route
// cl_maplights.qc takes, and with the same tempstring discipline: the key flag
// is captured BEFORE the value token is fetched.
//
// Returns TRUE when the lump was READABLE, which is not the same as "a key was
// found" — the caller needs to tell "this map has none" from "the worldmodel is
// not up yet".
float() GSoundlist_LoadFromWorld =
{
	if (gsl_loaded)
		return TRUE;

	float guard = 0, sawtoken = 0;
	string t;

	getentitytoken("");
	while ((t = getentitytoken()) != "")
	{
		sawtoken = 1;
		guard = guard + 1;
		if (guard > 400000) break;
		if (t != "{")
			continue;

		float is_world = 0;
		string found = "";

		for (;;)
		{
			t = getentitytoken();
			guard = guard + 1;
			if (guard > 400000) break;
			if (t == "" || t == "}") break;

			float k_class = (t == "classname");
			float k_list  = (t == "globalsoundlist");

			t = getentitytoken();
			guard = guard + 1;
			if (t == "") break;

			if (k_class && t == "worldspawn")
				is_world = 1;
			else if (k_list)
				found = strzone(t);
		}

		if (is_world)
		{
			// Same rule as sh_modellist.qc's twin: a worldspawn without the key
			// is not a final answer, because Sven also takes it from
			// maps/<name>.cfg and the eight th_ep3_* maps use only that form.
			// Do not latch here — the caller's serverinfo fallback still needs
			// to run.  GSoundlist_Load owns the latch.
			if (found != "")
			{
				GSoundlist_Load(found);
				strunzone(found);
			}
			return TRUE;
		}
		if (found != "")
			strunzone(found);
		break;
	}

	if (!sawtoken)
		return FALSE;

	// Lump read, no key — deliberately unlatched, see the is_world branch above.
	return TRUE;
};
#endif

void() GSoundlist_Report =
{
	if (gsl_reported || !gsl_paircount)
		return;
	gsl_reported = TRUE;

	// print, not dprint — cfg/default.cfg sets `developer 0` and RE-EXECS on
	// every map load, so a developer-gated line in a per-map hook is invisible
	// on the client however it was launched.  Same call, same reason, as
	// sh_modellist.qc's report and MapLights_Load's.
	print(sprintf("[gsoundlist] %s: %g pair(s)%s%s\n",
	              gsl_srcpath, gsl_paircount,
	              gsl_overflow ? sprintf(", %g DROPPED (pool full)", gsl_overflow) : "",
	              gsl_missing  ? sprintf(", %g target(s) missing", gsl_missing) : ""));

	// A lookup check rather than only a count, for the reason sh_modellist.qc
	// gives: "20 pairs parsed" and "the sound changed" are different claims and
	// only the second is the feature.  Plus the pass-through case, without which
	// every sound the list omits would resolve to nothing.
	string k   = gsl_from[0];
	string got = GSoundlist_Remap(k);
	dprint(sprintf("[gsoundlist]   \"%s\" -> \"%s\"%s\n", k, got,
	               (got == gsl_to[0]) ? "" : "  LOOKUP FAILED"));
	if (GSoundlist_Remap("sound/that/is/not/in/any/list.wav")
	    != "sound/that/is/not/in/any/list.wav")
		print("[gsoundlist]   PASS-THROUGH FAILED\n");
};
