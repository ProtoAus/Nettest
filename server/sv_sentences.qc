// server/sv_sentences.qc
// ----------------------------------------------------------------------------
// Half-Life's sentence system: the `!GROUP_NAME` half of `scripted_sentence`, and
// the voice of every talking monster.
//
// This was stubbed with "needs a sentences.txt lookup this build does not have",
// and that note was wrong about the reason.  SVEN ships no sentences.txt - but the
// mod has mounted the Half-Life install since the monster programme began, and
//     valve/sound/sentences.txt
// has been sitting there the whole time: 1379 lines, 405 groups.  The data was
// never missing, only unread.  The symptom was a live game printing a refusal per
// line of dialogue, several times a second, on hl_c01_a1.
//
// THE FILE FORMAT, from the real file:
//
//     SC_1MUMBLE scientist/c1a0_sci_mumble
//     HG_GREN0   hgrunt/clik(p120) grenade! clik
//
// A name, then the words.  The DIRECTORY IS GLUED TO THE FIRST WORD - "hgrunt/clik"
// is directory "hgrunt" plus word "clik", not a directory called "hgrunt/clik".
// Every later word is a bare name in that same directory.  Reading the first token
// as a plain directory produces "hgrunt//clik.wav" and "hgrunt/clik/grenade!.wav",
// both of which the engine rejects with "empty directory name" - which is exactly
// what the first version of this did, 74 times on one map.
//
// The parenthesised groups are Half-Life's inline pitch/volume/timing modifiers
// (p=pitch, v=volume, t=time shift, e=end pause, s=start pause); they attach to
// the word they follow and are stripped here - see SENT_WORD_GAP for what that
// costs and what it does not.
//
// THE TWO REFERENCE FORMS ARE NOT THE SAME, and conflating them is the classic
// bug in every reimplementation of this:
//
//     "!SC_1MUMBLE"   an EXACT entry.  Play that line and no other.
//     "SC_MUMBLE"     a GROUP.  Half-Life appends 0,1,2... and picks one at
//                     random from SC_MUMBLE0, SC_MUMBLE1, ...
//
// Both are implemented.  A map that writes "!FOO" and means it must not get a
// random sibling, and a monster asking for idle chatter must not repeat itself.
// ----------------------------------------------------------------------------

// Half-Life's own header claims "Max of 1023 sentences"; the shipped file
// actually holds 1065, counted both by this parser and independently outside the
// engine.  1024 was therefore not merely tight, it silently dropped 41 real lines
// - and the overflow report is the only reason that was visible at all.
//
// 2048 was not enough either, and unlike the 1024 case this was happening in the
// shipped build rather than in theory.  Every hc2_* map layers
// svencoop_downloads/sound/hc2/sentences.txt (1062 entries) on top of valve's
// 1065, and the log said so on every single run:
//     [sentences] sound/hc2/sentences.txt: 983 extra sentence(s)
//     [sentences] SENT_MAX (2048) overflowed: 83 line(s) dropped
// 2127 raw is the real worst case for a two-file load; the union of ALL six
// sentence files present on this install is 2149 distinct names.  4096 clears
// both with room for a map that ships its own, and the table is two string
// arrays, so the cost is address space rather than anything that runs.
//
// DE-DUPLICATING ON INSERT WAS CONSIDERED AND REJECTED.  It would be a linear
// scan per inserted line, i.e. ~1.1M string compares to layer hc2's 1062 entries
// on valve's 1065, paid at map load - and it would buy nothing a user can see.
// First-wins (below) already makes a later duplicate unreachable, so dedup only
// reclaims table slots, and at 4096 there are ~1900 spare.  If the extra sentence
// files are ever layered in (see Sentences_Load), revisit this together with the
// linear Sentences_IndexOf scan rather than on its own.
const float SENT_MAX = 4096;

string sent_name[SENT_MAX];	// "BA_BUTTON" as written in the file - see Sentences_IndexOf
string sent_line[SENT_MAX];	// "scientist/c1a0_sci_mumble", modifiers stripped
float  sent_count;
float  sent_overflow;
float  sent_loaded;

// Worldspawn key naming a SECOND sentences file the map ships - see the note on
// Sentences_Load.  Lower case, both because that is how th_ep3_04 spells it and
// because GoldSrc_TryCaseFoldedField (sv_multi_manager.qc:410) can only rescue a
// missed key by folding it DOWN.
.string sentence_file;

// Seconds between the words of a multi-word sentence.
//
// HONEST APPROXIMATION, and the only one in this file.  Half-Life chains words by
// their real duration; doing that here needs soundlength(), which FTE registers
// server-side as PF_Ignore (builtin 534, engine/server/pr_cmds.c:12237) - it
// returns 0, so a duration-driven chain would fire every word on the same frame.
//
// This matters far less than it sounds.  Monster speech - the reason this file
// exists - is overwhelmingly ONE word: "SC_1MUMBLE scientist/c1a0_sci_mumble" is
// the whole line, and so is every other *_MUMBLE, *_PAIN, *_FEAR and greeting.
// The multi-word entries are announcer and grunt callouts, which read acceptably
// on a fixed cadence.  The exact fix is to hand the word list to CSQC and chain it
// there, where soundlength is real; that is a follow-up, not a pretence.
// 0.85 is the measured MEDIAN word length (0.888 s over the 1448 words
// sentences.txt references that resolve to a real file in the mounted install),
// which is the right statistic for spacing: it makes the typical two-word line
// sound like speech rather than like two clips fired at once.
const float SENT_WORD_GAP = 0.85;

// How long to hold the mouth open per word.  The MEAN, not the median (2.02 s
// measured), because "how long is this entity still making noise" is a total and
// totals are sums of means - see the note in Sentences_Speak.
//
// Deliberately generous.  Being wrong by holding a jaw open half a second past
// the end of a line is invisible; being wrong the other way is what made the
// mouth look broken.  The exact fix is the same follow-up as the word chaining:
// real per-word durations, which need soundlength() and therefore CSQC.
const float SENT_MOUTH_EST = 2.0;

// ---------------------------------------------------------------------------
// parsing
// ---------------------------------------------------------------------------
// Strip Half-Life's inline "(p120 t30)" modifiers.  They are per-word and always
// parenthesised, so a depth counter is enough - and a depth counter rather than a
// find-the-close-paren is what keeps a malformed line from eating the rest of the
// sentence.
string(string s) Sentences_StripMods =
{
	string out = "";
	float i, n = strlen(s), depth = 0;
	for (i = 0; i < n; i = i + 1)
	{
		string c = substring(s, i, 1);
		if (c == "(")
			depth = depth + 1;
		else if (c == ")")
		{
			if (depth > 0)
				depth = depth - 1;
		}
		else if (!depth)
			out = strcat(out, c);
	}
	return out;
};

// Collapse runs of whitespace so tokenize() sees clean words.  HL's file uses a
// mix of spaces and tabs and leaves double spaces where a modifier was removed.
string(string s) Sentences_Squeeze =
{
	string out = "";
	float i, n = strlen(s), sp = 1;	// leading space suppressed
	for (i = 0; i < n; i = i + 1)
	{
		string c = substring(s, i, 1);
		if (c == " " || c == "\t" || c == "\r" || c == "\n")
		{
			if (!sp)
			{
				out = strcat(out, " ");
				sp = 1;
			}
		}
		else
		{
			out = strcat(out, c);
			sp = 0;
		}
	}
	// strip one trailing space
	n = strlen(out);
	if (n > 0 && substring(out, n - 1, 1) == " ")
		out = substring(out, 0, n - 1);
	return out;
};

// Append one sentences file to the table.  Returns how many entries it added.
//
// Split out of Sentences_Load so a SECOND, map-supplied file can be layered on
// top of Half-Life's - see Sentences_Load's `sentence_file` note.  Entries are
// appended rather than merged, and Sentences_IndexOf walks from 0, so the FIRST
// definition of a name wins.  That is the conservative order: a map cannot
// silently redefine a stock HL group out from under the monsters that use it.
float(string path) Sentences_LoadFile =
{
	float added = 0;

	float fh = fopen(path, FILE_READ);
	if (fh < 0)
		return 0;

	// TERMINATION IS NOT `while (line)`, and this cost two builds to pin down.
	//
	// PF_fgets (pr_bgcmd.c:3053) genuinely distinguishes the two cases - it
	// returns the NULL string at EOF and a real tempstring containing "" for a
	// blank line - but QC CANNOT SEE THE DIFFERENCE.  Both `!s` and `s != ""`
	// compile to content tests, so a blank line reads as end-of-file.  Line 2 of
	// Half-Life's sentences.txt is blank and line 1 is a comment, which is exactly
	// why the first two attempts loaded ZERO sentences out of 1065 while reporting
	// success.
	//
	// So: stop only after a RUN of empty reads.  Measured on the shipped file, the
	// longest run of genuine blank lines is 3; 16 is five times that and still
	// terminates instantly at the real end.  Ugly, but it is the honest shape of
	// the constraint rather than a guess that happens to work today.
	//
	// The read happens ONCE, at the top, so every skip path below is a plain
	// `continue` that cannot forget to advance the file and spin forever.
	const float SENT_EOF_RUN = 16;
	float empties = 0;
	string raw, line;
	for (;;)
	{
		raw = fgets(fh);
		if (!raw)
		{
			empties = empties + 1;
			if (empties >= SENT_EOF_RUN)
				break;
			continue;
		}
		empties = 0;

		line = Sentences_Squeeze(Sentences_StripMods(raw));
		if (line == "" || substring(line, 0, 2) == "//")
			continue;

		float sp = strstrofs(line, " ");
		if (sp <= 0)
			continue;			// a name with no words is not a sentence

		if (sent_count >= SENT_MAX)
		{
			sent_overflow = sent_overflow + 1;
			continue;
		}

		sent_name[sent_count] = strzone(substring(line, 0, sp));
		sent_line[sent_count] = strzone(substring(line, sp + 1, -1));
		sent_count = sent_count + 1;
		added = added + 1;
	}
	fclose(fh);
	return added;
};

// Load the sentence table once.  Called from worldspawn, which is also the only
// place precache_sound may run - and every word of every sentence has to be
// precached there or SV_StartSound refuses it at play time.  That is exactly the
// failure the body-drop sounds had.
//
// TWO FILES, and the second one is a worldspawn key.  Half-Life's own table
// comes from the mounted valve install; a map may add its own with
//
//     "sentence_file" "sound/hunger/hunger_sentences.txt"
//
// which is what th_ep3_04 does.  BE CLEAR ABOUT HOW LITTLE THIS BUYS, because
// the surrounding work was scoped on a claim that turned out to be wrong: the
// campaign's 73 scripted_sentence entities were supposed to be mute without it,
// and they are not.  69 of the 73 use Sven's `+path/file.wav` literal-sample
// form, which sv_goldsrc_compat.qc has implemented (and precached) all along.
// Of the remaining four, three name stock Half-Life groups (SC_TENT, BA_HEAR,
// BA_QUESTION) that already resolve out of valve's file.  Exactly ONE line in
// the whole campaign needs this - TH_SHERIFF on th_ep2_00 - and th_ep2_00 does
// not even set the key, which is why the load is not gated on the key alone.
//
// So: honour `sentence_file` when a map sets it, AND fall back to the campaign
// file when a map's globalsoundlist says it is a They Hunger map.  The second
// half is the part that makes TH_SHERIFF audible; without it the key would be
// correct and useless.
void() Sentences_Load =
{
	if (sent_loaded)
		return;
	sent_loaded = TRUE;
	sent_count  = 0;

	float n = Sentences_LoadFile("sound/sentences.txt");
	if (!n)
		// Not an error worth shouting about: a server with no Half-Life mounted
		// simply has no HL dialogue, and every caller below degrades to silence.
		dprint("[sentences] sound/sentences.txt not found - HL dialogue unavailable\n");

	string extra = world.sentence_file;
	if (extra == "" || !extra)
	{
		// No explicit key.  A They Hunger map is identifiable from the
		// globalsoundlist it already sets (12 of the campaign's maps do), and
		// that is a far better signal than the map name: it is the same key the
		// sound replacement layer keys off, so the two cannot disagree about
		// which maps are They Hunger.
		string gsl = world.globalsoundlist;
		if (gsl != "" && gsl && strstrofs(strtolower(gsl), "hunger") >= 0)
			extra = "sound/hunger/hunger_sentences.txt";
	}

	if (extra != "" && extra)
	{
		float m = Sentences_LoadFile(extra);
		if (m)
			dprint(sprintf("[sentences] %s: %g extra sentence(s)\n", extra, m));
		else
			dprint(sprintf("[sentences] %s: not found\n", extra));
	}

	if (sent_overflow)
		dprint(sprintf("[sentences] SENT_MAX (%g) overflowed: %g line(s) dropped\n",
		               SENT_MAX, sent_overflow));
	dprint(sprintf("[sentences] loaded %g sentence(s)\n", sent_count));
};

// Precache every word.  Separate from the load because it must run at worldspawn
// even if something else loaded the table earlier, and because the precache slot
// cost is worth stating: HL's file is 405 entries but many share words, and the
// engine dedupes by name, so the real cost is the distinct-file count.
// Split the first token into its directory and its first word.  Sets the two
// globals rather than returning a pair, because QC has no tuples and both callers
// want both halves.  Returns FALSE for a token with no '/', which is malformed.
string sent_dir, sent_word0;

// THE DIRECTORY IS OPTIONAL AND DEFAULTS TO vox/, which this used to treat as a
// parse failure — and it is the single largest silent gap the sentence layer has
// had.
//
// GoldSrc's format puts the directory on the FIRST word only and lets every
// later word inherit it:
//
//     BA_BUTTON  barney/c1a0_ba_button        <- explicit, "barney"
//     C1A3_0     buzwarn buzwarn attention.   <- none, so "vox"
//
// Returning FALSE on the second form dropped the whole sentence, at both
// precache time (Sentences_PrecacheWords skips it) and playback time
// (Sentences_Speak returns FALSE before saying a word).  Measured against the
// shipped valve/sound/sentences.txt: 238 of its 1065 entries have no directory,
// so 22% of the file was unreachable — and it is not a random 22%.  It is
// exactly the VOX set: every Black Mesa PA announcement, the C1A0_* chapter
// groups, C1A0_START (the announcement over hl_c00's tram ride), and the WILD*
// and C1A3_* groups the `speaker` entity reaches for by preset.
//
// Found by porting `speaker` — the new entity's own "no sentence or group"
// diagnostic fired on hl_c04 and hl_c09, and the groups it named turned out to
// be present in the file all along.
float(string first) Sentences_SplitFirst =
{
	float slash = strstrofs(first, "/");
	if (slash < 0)
	{
		// No directory on the first word: GoldSrc's default.
		sent_dir   = "vox";
		sent_word0 = first;
		return (sent_word0 != "");
	}
	sent_dir   = substring(first, 0, slash);
	sent_word0 = substring(first, slash + 1, -1);

	// AN EMPTY WORD AFTER THE SLASH IS LEGAL, and rejecting it cost another 69
	// entries on top of the 238 above.  The shape is a directory carrying only a
	// modifier, which Sentences_StripMods then empties:
	//
	//     WILD0     ambience/(v30) quail1(p103), quail1(t10), quail1(p101)
	//               -> "ambience/ quail1, quail1, quail1"
	//
	// so the directory applies from the first token and the first real WORD is
	// the next one.  Sentences_WordFile already returns "" for a token that names
	// no file and both the precache walk and Sentences_Pump skip those, so an
	// empty word0 costs nothing and needs no special case downstream.
	//
	// The 69 are not obscure: HEV_MED*, HEV_HEAL* (the HEV suit's own voice) and
	// the HG_ALERT* grunt radio set are all this shape.
	return (sent_dir != "");
};

// Turn a sentence WORD into the filename stem it actually refers to.
//
// HL's file carries prosody on the word itself: a trailing '.' is a full pause,
// ',' a shorter one, '!' emphasis.  They are timing markers, NOT part of the
// filename -- "attention." is played from vox/attention.wav.  Appending ".wav"
// without stripping them produced "vox/attention..wav", which the client's
// download guard then rejected as a path containing ".." (CL_CheckFile tests for
// the substring anywhere, so a malformed name trips a traversal check).
//
// The '.' cases at least announced themselves.  The ',' cases did not: they build
// "vox/sector,.wav", which contains no "..", so nothing warned and the word was
// simply dropped from every sentence using it.  Measured on the shipped file:
// 21 distinct words end in '.', 117 in ',' -- so roughly 85% of the breakage was
// silent, and the console errors were the small visible part of it.
//
// Strips any trailing character that cannot appear in one of these filenames
// rather than enumerating the punctuation, so a marker we have not seen cannot
// reintroduce this.  Parenthesised modifiers -- "clik(p120)" -- are already gone
// by here; Sentences_StripMods removes them at load.
string(string w) Sentences_WordFile =
{
	//str2chr, not substring+compare: QC has no ordering operators for strings, so a
	//range test has to be done on the character CODE.
	float n = strlen(w);
	while (n > 0)
	{
		float c = str2chr(w, n - 1);
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == '_' || c == '-')
			break;
		n = n - 1;
	}
	return (n == strlen(w)) ? w : substring(w, 0, n);
};

void() Sentences_Precache =
{
	Sentences_Load();

	float i, j;
	for (i = 0; i < sent_count; i = i + 1)
	{
		float n = tokenize(sent_line[i]);
		if (n < 1)
			continue;
		if (!Sentences_SplitFirst(argv(0)))
			continue;
		string dir = sent_dir;
		string w0 = Sentences_WordFile(sent_word0);
		if (w0 != "")
			precache_sound(strcat(dir, "/", w0, ".wav"));
		for (j = 1; j < n; j = j + 1)
		{
			string wj = Sentences_WordFile(argv(j));
			if (wj != "")	//a token that was ALL punctuation names no file
				precache_sound(strcat(dir, "/", wj, ".wav"));
		}
	}
};

// ---------------------------------------------------------------------------
// lookup
// ---------------------------------------------------------------------------
// Case-INSENSITIVE, matching Half-Life.  SENTENCEG_Lookup (SDK dlls/sound.cpp:
// 1390-1410) compares with stricmp, and maps rely on it: hl_c01_a1 writes
// "!BA_button" and "!BA_hevno" while the shipped file stores BA_BUTTON and
// BA_HEVNO, so a byte-exact compare made Barney mime his lines.
//
// THE OLD COMMENT HERE WAS WRONG ON BOTH COUNTS and is worth recording, because
// it is what kept the bug alive.  It claimed "every map reference in the corpus
// is uppercase" - hl_c01_a1 alone has seven that are not, and a corpus scan finds
// 14 such misses across the Sven maps and 27 counting the valve/OpFor/Blue Shift
// ones.  And it reasoned about strtoupper (#481), which really is client/menu
// only; but the right builtin was always strcasecmp (#229), which IS in the
// server table (engine/server/pr_cmds.c:11629) and does work here.
//
// Safe to fold case: valve's 1065 entries hold 1061 distinct names whether
// compared sensitively or insensitively, i.e. NO two entries differ only by case,
// so this can rescue a miss but can never make a lookup ambiguous.  The four
// duplicates are exact repeats, already governed by the first-wins rule below.
float(string nm) Sentences_IndexOf =
{
	float i;
	for (i = 0; i < sent_count; i = i + 1)
		if (!strcasecmp(sent_name[i], nm))
			return i;
	return -1;
};

// Resolve either reference form to a concrete index, or -1.
//
//   leading '!'  -> EXACT.  No random sibling, ever.
//   otherwise    -> GROUP.  Collect NAME0..NAME9 and pick one.
//
// The group scan stops at the first gap on purpose: HL's groups are contiguous
// from 0, and scanning past a gap would let SC_ANSWER0..2 accidentally pick up an
// unrelated SC_ANSWER7 if a mod added one.
float(string ref) Sentences_Resolve =
{
	if (ref == "" || !ref)
		return -1;

	if (substring(ref, 0, 1) == "!")
		return Sentences_IndexOf(substring(ref, 1, -1));

	float pick[10];
	float n = 0, k;
	for (k = 0; k < 10; k = k + 1)
	{
		float idx = Sentences_IndexOf(strcat(ref, ftos(k)));
		if (idx < 0)
			break;
		pick[n] = idx;
		n = n + 1;
	}
	if (!n)
		return Sentences_IndexOf(ref);	// a bare name that is itself an entry
	return pick[floor(random() * n)];
};

// ---------------------------------------------------------------------------
// playback
// ---------------------------------------------------------------------------
// Word chaining state.  Per-entity rather than global so two monsters can be
// mid-sentence at once, which on hl_c01_a1 is the normal case - the argument pair
// talk over each other by design.
.string ai_sent_words;		// remaining words, space separated
.string ai_sent_dir;
.float  ai_sent_next;		// time the next word plays
.float  ai_sent_chan;
.float  ai_sent_vol;
.float  ai_sent_attn;
.float  ai_sent_end;		// when the whole sentence finishes (for the mouth)

// Advance one word.  Driven from the talk tick rather than from a think, so a
// monster that dies mid-sentence simply stops - no orphaned think holding a
// removed entity alive.
void(entity e) Sentences_Pump =
{
	if (e.ai_sent_words == "" || !e.ai_sent_words)
		return;
	if (time < e.ai_sent_next)
		return;

	float n = tokenize(e.ai_sent_words);
	if (n < 1)
	{
		e.ai_sent_words = "";
		return;
	}

	//Same stripping as the precache, or playback would ask for a name that was never
	//precached and the word would be silent -- see Sentences_WordFile.
	string wnow = Sentences_WordFile(argv(0));
	if (wnow != "")
		sound(e, e.ai_sent_chan, strcat(e.ai_sent_dir, "/", wnow, ".wav"),
		      e.ai_sent_vol, e.ai_sent_attn);

	// Rebuild the tail.  strzone because argv()'s buffers are reused by the next
	// tokenize, and this string has to survive until the next tick.
	string tail = "";
	float i;
	for (i = 1; i < n; i = i + 1)
		tail = (i == 1) ? argv(i) : strcat(tail, " ", argv(i));

	if (e.ai_sent_words)
		strunzone(e.ai_sent_words);
	e.ai_sent_words = (tail == "") ? "" : strzone(tail);
	e.ai_sent_next  = time + SENT_WORD_GAP;
};

// Speak a sentence FROM an entity.  Returns TRUE if anything was found to say.
//
// `ref` is either form; `chan` lets a monster's voice occupy CHAN_VOICE so a new
// line cuts the previous one, which is what HL does and what stops a scientist
// stacking six overlapping mumbles when a trigger fires repeatedly.
float(entity e, string ref, float chan, float vol, float attn) Sentences_Speak =
{
	float idx = Sentences_Resolve(ref);
	if (idx < 0)
		return FALSE;

	float n = tokenize(sent_line[idx]);
	if (n < 1)
		return FALSE;
	if (!Sentences_SplitFirst(argv(0)))
		return FALSE;

	if (e.ai_sent_dir)
		strunzone(e.ai_sent_dir);
	e.ai_sent_dir = strzone(sent_dir);

	// word0 came glued to the directory; the rest are separate tokens.
	string words = sent_word0;
	float i;
	for (i = 1; i < n; i = i + 1)
		words = strcat(words, " ", argv(i));

	if (e.ai_sent_words)
		strunzone(e.ai_sent_words);
	e.ai_sent_words = strzone(words);

	e.ai_sent_chan = chan;
	e.ai_sent_vol  = vol;
	e.ai_sent_attn = attn;
	e.ai_sent_next = time;			// first word on this tick
	// The mouth envelope is a DIFFERENT estimate from the word spacing, and using
	// one number for both is why jaws looked welded shut.
	//
	// Spacing wants the typical word, so it uses the MEDIAN; total speaking time
	// is a sum, so it wants the MEAN.  Those are wildly different for this corpus:
	// measured over all 1448 resolvable words that sentences.txt actually
	// references, median 0.89 s against mean 2.02 s, with p90 at 4.17 s.  Driving
	// the mouth off the median shut it after 0.85 s of a line that is still going
	// four seconds later - which does not read as "a short jaw movement", it reads
	// as no jaw movement at all.
	e.ai_sent_end  = time + n * SENT_MOUTH_EST;

	Sentences_Pump(e);
	return TRUE;
};

// Is this entity mid-sentence?  The talk layer reads it to drive the mouth bone
// and to avoid interrupting itself.
float(entity e) Sentences_Speaking =
{
	return (e.ai_sent_words != "" && e.ai_sent_words) || time < e.ai_sent_end;
};
