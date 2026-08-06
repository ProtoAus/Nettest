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
// - and the overflow report is the only reason that was visible at all.  2048
// leaves room for the sentences a map ships inside its own content.
const float SENT_MAX = 2048;

string sent_name[SENT_MAX];	// "SC_1MUMBLE", already uppercased
string sent_line[SENT_MAX];	// "scientist/c1a0_sci_mumble", modifiers stripped
float  sent_count;
float  sent_overflow;
float  sent_loaded;

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

// Load sound/sentences.txt once.  Called from worldspawn, which is also the only
// place precache_sound may run - and every word of every sentence has to be
// precached there or SV_StartSound refuses it at play time.  That is exactly the
// failure the body-drop sounds had.
void() Sentences_Load =
{
	if (sent_loaded)
		return;
	sent_loaded = TRUE;
	sent_count  = 0;

	float fh = fopen("sound/sentences.txt", FILE_READ);
	if (fh < 0)
	{
		// Not an error worth shouting about: a server with no Half-Life mounted
		// simply has no HL dialogue, and every caller below degrades to silence.
		dprint("[sentences] sound/sentences.txt not found - HL dialogue unavailable\n");
		return;
	}

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
	}
	fclose(fh);

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

float(string first) Sentences_SplitFirst =
{
	float slash = strstrofs(first, "/");
	if (slash < 0)
		return FALSE;
	sent_dir   = substring(first, 0, slash);
	sent_word0 = substring(first, slash + 1, -1);
	return (sent_dir != "" && sent_word0 != "");
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
		precache_sound(strcat(dir, "/", sent_word0, ".wav"));
		for (j = 1; j < n; j = j + 1)
			precache_sound(strcat(dir, "/", argv(j), ".wav"));
	}
};

// ---------------------------------------------------------------------------
// lookup
// ---------------------------------------------------------------------------
// Case-SENSITIVE, deliberately.  strtoupper is registered in pr_csqc.c and
// pr_menu.c but NOT in the server builtin table, so on SSQC it compiles happily
// and then does nothing useful at runtime - every name stored through it came out
// mangled and no lookup could match, which is what made "!SC_1MUMBLE" report
// missing while sitting at line 1061 of the very file we had just parsed.
// Both sides are uppercase in practice: HL's file is uppercase throughout, and so
// is every map reference in the corpus.
float(string nm) Sentences_IndexOf =
{
	float i;
	for (i = 0; i < sent_count; i = i + 1)
		if (sent_name[i] == nm)
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

	sound(e, e.ai_sent_chan, strcat(e.ai_sent_dir, "/", argv(0), ".wav"),
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
