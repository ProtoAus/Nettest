// server/sv_soundlist.qc
// ----------------------------------------------------------------------------
// Sven Co-op's per-monster sound REPLACEMENT layer.
//
// A monster or squadmaker carries `soundlist "../pizza_ya_san/ownershin.txt"`, and
// that file is a flat list of old/new pairs:
//
//     "fgrunt/death1.wav"  "pizza_ya_san/tasukete.wav"
//     "fgrunt/gr_pain1.wav" "pizza_ya_san/tasukete.wav"
//
// Every sound that body would have played under its canonical name plays the
// replacement instead.  This is how a Sven map dresses a stock monster as a
// character: pizza_ya_san1 turns two ally grunts into a Japanese shopkeeper and
// his chief, a babygargantua into a customer called "electro", a zombie into a
// daikon farmer, and eight houndeyes into stray dogs, entirely through this key
// plus a custom model.  The key was parsed and thrown away, so the map ran in
// English with Half-Life's own voices.
//
// The lookup is keyed on the LEFT column, which is the name Sven's own monster
// would emit - so a class of ours that emits a different name than Sven's simply
// never matches, silently.  That is a real trap and it has already caught three
// classes here: the ally grunts (hgrunt/* where Sven has fgrunt/*), the
// babygargantua (garg/* where Sven has babygarg/*), and any Opposing Force rig
// whose Sven counterpart moved folders.  Those are fixed at the emitting class,
// not here: matching Sven's sound paths is the correct behaviour independently of
// whether any map replaces them.
//
// Storage is flat arrays rather than one string per entity because QC has no
// dictionaries: each FILE gets a contiguous run of pairs, and a monster holds the
// file's index.  Files are parsed once and shared - pizza_ya_san1 has eight
// houndeye spawners naming the same list.
// ----------------------------------------------------------------------------

// 24 files / 1024 pairs.  pizza_ya_san1 uses 6 files and 156 pairs; the largest
// list shipped with it (a sniper voice set it does not reference) is 332 pairs on
// its own, so the pair pool is sized for one of those plus room.  Overflow is
// counted and reported rather than silently dropped.
const float SL_MAX_FILES = 24;
const float SL_MAX_PAIRS = 1024;

string sl_path[SL_MAX_FILES];		// as written in the map, for dedupe and reporting
float  sl_first[SL_MAX_FILES];		// index of this file's first pair
float  sl_num[SL_MAX_FILES];
float  sl_filecount;

string sl_from[SL_MAX_PAIRS];
string sl_to[SL_MAX_PAIRS];
float  sl_paircount;

float  sl_overflow;			// pairs that did not fit
float  sl_missing;			// replacement targets that are not on disk

// Trailing junk on a value.  The engine's fgets already drops \r (pr_bgcmd.c:
// "read up to the next \n, ignoring any \rs"), so what is left is the case
// daikonfarmer.txt actually contains: two lines whose closing quote is missing,
// e.g.  "zombie/zo_alert10.wav" "scientist/madness.wav
// tokenize runs an unterminated quote to the end of the line, which gives the
// right answer here, but a hand-edited list can just as easily leave a stray
// quote or spaces behind.  Tolerate it rather than desync the pair list.
string(string s) Soundlist_Clean =
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

// The map writes the path relative to somewhere inside sound/, and it writes it
// with a leading "../" (all ten lists in pizza_ya_san1 do).  Resolve by stripping
// the relative segments and trying the two places the file can actually be.
filestream(string path) Soundlist_Open =
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

	// As written, first - a map that gives a real VFS path deserves to be taken at
	// its word.  Skipped when the path had relative segments, because FTE's
	// qcfopen refuses any name containing ".." and prints "Access denied" to the
	// console when it does: six of those on map load is a warning about nothing,
	// and a warning about nothing is how a real one gets ignored.
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

// Returns the table index PLUS ONE, so 0 can mean "no list" in .sl_table without
// costing a sentinel field.
float(string path) Soundlist_Load =
{
	if (path == "" || !path)
		return 0;

	float i;
	for (i = 0; i < sl_filecount; i = i + 1)
		if (sl_path[i] == path)
			return i + 1;

	if (sl_filecount >= SL_MAX_FILES)
	{
		dprint(sprintf("[soundlist] table full, ignoring \"%s\"\n", path));
		return 0;
	}

	filestream f = Soundlist_Open(path);
	if (f < 0)
	{
		dprint(sprintf("[soundlist] cannot open \"%s\"\n", path));
		return 0;
	}

	float slot  = sl_filecount;
	sl_path[slot]  = strzone(path);
	sl_first[slot] = sl_paircount;
	sl_num[slot]   = 0;
	sl_filecount   = sl_filecount + 1;

	// TERMINATION IS NOT `while (line)`, for the reason spelled out at
	// sv_sentences.qc:161 - PF_fgets returns the NULL string at EOF and a real
	// tempstring containing "" for a blank line, and QC cannot tell the two apart
	// because both `!s` and `s != ""` compile to content tests.  A soundlist with a
	// blank line in it would load the pairs above the blank and silently drop
	// everything below.  Same fix as the sentence loader: stop only after a RUN of
	// empty reads.
	const float SL_EOF_RUN = 16;
	float added = 0, missing = 0, empties = 0;
	string line;
	for (;;)
	{
		line = fgets(f);
		if (!line)
		{
			empties = empties + 1;
			if (empties >= SL_EOF_RUN)
				break;
			continue;
		}
		empties = 0;

		// tokenize is safe here: nothing this function calls tokenizes, and the
		// only caller (Monster_Build / squadmaker, at map parse) is not inside an
		// argv walk of its own.
		float n = tokenize(line);
		if (n >= 2)
		{
			string from = Soundlist_Clean(argv(0));
			string to   = Soundlist_Clean(argv(1));
			// A leading // is a comment, not a sound.
			if (from != "" && to != "" && substring(from, 0, 2) != "//")
			{
				// THE TARGET HAS TO EXIST BEFORE THE PAIR IS TAKEN.  A
				// replacement pointing at a file that is not on disk is worse
				// than no replacement at all: the monster loses its own sound
				// and gains nothing, so a mistyped line in a map's list would
				// mute a class instead of redressing it.  Dropping the pair
				// leaves the canonical sound playing, which is the graceful
				// direction, and the count is reported so the mistake is still
				// visible.
				string pack = whichpack(strcat("sound/", to));
				if (pack == "" || !pack)
				{
					missing = missing + 1;
					sl_missing = sl_missing + 1;
				}
				else if (sl_paircount >= SL_MAX_PAIRS)
					sl_overflow = sl_overflow + 1;
				else
				{
					sl_from[sl_paircount] = strzone(from);
					sl_to[sl_paircount]   = strzone(to);
					sl_paircount = sl_paircount + 1;
					added = added + 1;

					// Precached here, at map parse, which is the whole reason
					// this runs when it does: a sound played through sound()
					// without a precache is dropped on the floor with no
					// diagnostic at all.
					precache_sound(to);
				}
			}
		}
	}
	fclose(f);

	sl_num[slot] = added;

	if (cvar("sv_debug_monsters") || missing)
		dprint(sprintf("[soundlist] %s: %g pair(s)%s\n", path, added,
		               missing ? sprintf(", %g replacement(s) MISSING on disk", missing) : ""));

	return slot + 1;
};

// The lookup.  Linear over one file's run - 61 entries at the worst on
// pizza_ya_san1, hit a few times a second per monster.
string(entity m, string sample) Soundlist_Remap =
{
	float t = m.sl_table - 1;
	if (t < 0 || t >= sl_filecount)
		return sample;

	float i = sl_first[t];
	float e = i + sl_num[t];
	for (; i < e; i = i + 1)
		if (sl_from[i] == sample)
			return sl_to[i];
	return sample;
};

// THE CHOKEPOINT.  A drop-in for sound() at every site that emits a monster's
// VOICE - pain, death, idle, alert, attack, footsteps - so the replacement layer
// has exactly one place to live.  It deliberately does NOT test .gag: the call
// sites already do, and folding that in here would silently change which sounds
// a gagged monster makes (HL gags speech, not footsteps or weapon reports).
void(entity m, float chan, string sample, float vol, float atten) AI_Sound =
{
	if (m.sl_table)
		sample = Soundlist_Remap(m, sample);
	sound(m, chan, sample, vol, atten);
};

// Same, with the pitch/flags tail that AI_SndPlay and a couple of class handlers
// need.  Two entry points rather than optional arguments because FTE's sound()
// treats a pitch of 0 as "no pitch" and an omitted optional float arrives as 0,
// which would silently mute the jitter on every call that did not pass one.
void(entity m, float chan, string sample, float vol, float atten,
     float pitch, float flags) AI_SoundEx =
{
	if (m.sl_table)
		sample = Soundlist_Remap(m, sample);
	sound(m, chan, sample, vol, atten, pitch, flags);
};

// One line at the end of map load.  Called from AI_Tick rather than AI_Init
// because worldspawn runs BEFORE the entity lump is parsed, so at AI_Init time no
// squadmaker has been seen yet and the totals would all be zero.
float sl_reported;

void() Soundlist_Report =
{
	// Not latched until there is something to say.  AI_Tick's first frame runs
	// BEFORE the entity lump has finished parsing - measured on pizza_ya_san1,
	// where the self-tests print two seconds ahead of the first squadmaker - so
	// latching on the first call would report a map's soundlists as zero, every
	// time.  A map with none costs two field reads per tick, forever, which is
	// the right price for a report that is never wrong.
	if (sl_reported || !sl_filecount)
		return;
	sl_reported = TRUE;
	dprint(sprintf("[soundlist] %g file(s), %g pair(s)%s%s\n",
	               sl_filecount, sl_paircount,
	               sl_overflow ? sprintf(", %g DROPPED (pool full)", sl_overflow) : "",
	               sl_missing  ? sprintf(", %g target(s) missing", sl_missing) : ""));

	// A LOOKUP CHECK, not just a count, because "158 pairs parsed" and "a monster
	// plays a Japanese line" are two different claims and only the second one is
	// the feature.  Prints the first pair of each file and runs it back through
	// Soundlist_Remap on a throwaway body bound to that table - so the log says
	// which canonical name each file is keyed on, which is the exact thing that
	// silently fails to match when a class emits a different path (hgrunt/* where
	// Sven has fgrunt/*, garg/* where Sven has babygarg/*).
	//
	// A pass-through case too: an unmapped name must come back unchanged, or a
	// monster with a soundlist would go silent on every sound the list omits.
	entity probe = spawn();
	float f;
	for (f = 0; f < sl_filecount; f = f + 1)
	{
		if (!sl_num[f])
		{
			dprint(sprintf("[soundlist]   %s: EMPTY\n", sl_path[f]));
			continue;
		}
		probe.sl_table = f + 1;
		string k   = sl_from[sl_first[f]];
		string got = Soundlist_Remap(probe, k);
		dprint(sprintf("[soundlist]   %s: %g pairs, \"%s\" -> \"%s\"%s\n",
		               sl_path[f], sl_num[f], k, got,
		               (got == sl_to[sl_first[f]]) ? "" : "  LOOKUP FAILED"));
		if (Soundlist_Remap(probe, "sound/that/is/not/in/any/list.wav")
		    != "sound/that/is/not/in/any/list.wav")
			dprint("[soundlist]   PASS-THROUGH FAILED\n");
	}
	remove(probe);
};
