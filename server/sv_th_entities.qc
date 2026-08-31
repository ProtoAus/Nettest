// ============================================================
//  server/sv_th_entities.qc  -  the last campaign entities
// ============================================================
//
//  The eleven classnames the 22-map census (20 They Hunger maps + pizza_ya_san1/2)
//  still reported as unimplemented.  Together they clear every campaign map except
//  th_escape, which is a separate project (a whole vehicle system plus Sven's
//  inventory subsystem, ~100 of its ~120 remaining placements).
//
//  Three of these are the th_ep3_07 ENDING and are why this file exists at all:
//    trigger_condition   watches count_in_heli's frags for >= 3, fires helispawn_on/off
//    ambient_music       plays the credits song
//    trigger_changesky   swaps the sky to 2VS
//
//  Compiled AFTER server/sv_goldsrc_entities.qc, so everything the goldsrc layer
//  defines (SUB_UseTargets, Trigger_UseTargets, IsMasterTriggered, the trigger
//  state mapping, func_tank, game_counter, target_cdaudio) is already visible.
//
//  NAMING TRAP, and it is load-bearing: some of these classnames collide with
//  FIELDS that already exist in this tree, and QC puts fields and functions in one
//  namespace.  Those use the spawnfunc_ prefix (DP_SV_SPAWNFUNC_PREFIX), which FTE
//  resolves ahead of the bare name -- the same mechanism sv_goldsrc_ammo.qc:426
//  already relies on for spawnfunc_ammo_357.
// ============================================================


// ============================================================
//  trigger_condition
//  FGD (authoritative for keys, enums, flags — quoted line numbers are in the comments):
//  "C:/Program Files (x86)/Steam/steamapps/common/Sven Co-op/svencoop/sven-coop.fgd":6210-6275
//  :6212-6233 spawnflags (1 Start Off, 2/4/8/16 Don't use X/Y/Z/W, 32 "Cyclic; no toggle",
//  64 "Keep '!activator'", 128 "Ignore initial result")
//  :6234-6238 target / m_iszValueName / m_iszSourceName / m_iszSourceKey / m_iszCheckValue
//  :6239-6261 m_iCheckType 0..6  == != < > <= >= &   ("Comparator; mon. val. -> comp.-val.")
// ============================================================

// ===========================================================================
//  trigger_condition — Sven Co-op only; there is no Half-Life SDK equivalent.
//
//  sven-coop.fgd:6210-6276.  It reads `m_iszValueName` off the entity named by
//  `target`, compares it against either a literal (`m_iszCheckValue`) or another
//  entity's key (`m_iszSourceName` + `m_iszSourceKey`), and fires `netname` when
//  the comparison is true, `message` when it is false.
//
//  THE ENTITY HAS TWO MODES, and spawnflag 32 picks between them:
//
//    CONSTANT mode (flag 32 clear) — polls every m_fCheckInterval seconds.  A
//      Use TOGGLES the polling; "Start Off" (flag 1) decides where it begins.
//      This is the mode m_iCheckBehaviour governs — the FGD names the key
//      "Constant mode trigger behaviour" (:6266) — and the mode "Ignore initial
//      result" (flag 128) exists for.  Branches fire on a CHANGE of result,
//      modulated by m_iCheckBehaviour.
//
//    CYCLIC mode (flag 32 set) — does NOT poll at all.  Each Use performs
//      exactly one evaluation and fires the matching branch, every time.  The
//      FGD comment above the flag says it outright: "Check once when fired - do
//      not toggle" (:6221).
//
//  That split is not a reading of the flag name, it is what the shipped maps
//  measure.  Entity lumps of the 108 BSP30 maps on the Sven mount hold 694
//  trigger_condition placements across 21 maps:
//
//    * m_fCheckInterval is TUNED ONLY IN CONSTANT MODE.  76 of the 81
//      placements carrying a non-default interval (0.2, 0.01, 1, 5, 15, 25, 45)
//      are non-cyclic.  530 of the 535 cyclic ones sit on the editor-written
//      default "0.1".  A poll nobody ever tunes across 535 placements is not a
//      poll.
//    * "Ignore initial result" (128) is 11 non-cyclic vs 2 cyclic — an "initial
//      result" is something only a self-starting poll has.
//    * Non-cyclic placements that start ON are, 70 times out of 76, targeted by
//      NOTHING in their map: they are pure pollers.  Non-cyclic placements that
//      start OFF are targeted 83 times out of 83: they are gated pollers.
//    * Cyclic placements are targeted 519 times out of 535.  Of the 16
//      leftovers, 15 are named game_playerkill / game_playerdie /
//      game_playerspawn / game_playerleave — reserved names the GAME fires, not
//      the entity lump (SDK dlls/multiplay_gamerules.cpp:436,587,599 and
//      dlls/player.cpp:4120,4124 FireTargets them with the player as activator).
//      Cyclic placements are, in practice, always fired.
//
//  The reason cyclic mode must fire on EVERY evaluation rather than on a change
//  is the same corpus: 249 of the 535 cyclic placements set `target` to
//  "!activator" and are hung off those reserved per-player names — ctf_warforts
//  checks $i_hasbflag on game_playerdie to drop the flag, bm_sts checks the
//  killer's targetname on game_playerkill to score a team.  A change-detecting
//  latch would fire for the first player who dies holding the flag and stay
//  silent for every player after, because the result did not change.
//
//  th_ep3_07 carries the campaign's single placement, `heli_condition`
//  (spawnflags 32, target count_in_heli, frags >= 3, true -> helispawn_off,
//  false -> helispawn_on).  NOTHING in that map's entity lump targets it and
//  the map_script named by maps/th_ep3_07.cfg (hunger/theyhunger) never mentions
//  it, so on the evidence above it is dead in Sven too — one of the handful of
//  genuine leftovers, alongside bm_sts's "tc1" test entity and two placements a
//  mapper renamed to end in "NULL".  It is NOT a reason to make 535 placements
//  poll.
//
//  Compile order: AFTER server/sv_triggers.qc (SUB_UseTargets, IsMasterTriggered,
//  GoldSrc_TriggerStateToUseType, .master / .triggerstate / .killtarget) and
//  AFTER server/sv_trigger_copyvalue.qc (TV_Mask, and the .m_iszValueName
//  declaration this section shares with it).  Both hold anywhere below
//  server/sv_goldsrc_entities.qc in sv_progs.src.
// ===========================================================================

// ---------------------------------------------------------------------------
// Externs from earlier compile units.  Identical re-declaration of an already
// defined prototype shares the slot — the same licence sv_trigger_logic.qc:10-12
// and sv_game_team_master.qc:15-17 take for these exact three.
// ---------------------------------------------------------------------------
void(entity caller, entity who, float useType) SUB_UseTargets;   // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;         // sv_triggers.qc
float(float ts) GoldSrc_TriggerStateToUseType;                   // sv_triggers.qc
vector(vector v, float fl) TV_Mask;                              // sv_trigger_copyvalue.qc

// ---------------------------------------------------------------------------
// Map keys.  The BSP entity parser drops keys whose fields aren't declared, so
// every key read below has to appear here, spelled exactly as the FGD spells it
// (sven-coop.fgd:6234-6274).
//
// m_iszValueName is ALREADY declared at server/sv_trigger_copyvalue.qc:22 and is
// repeated here only so this section reads on its own — QC shares one slot
// between identical field declarations, which is the same licence
// sv_goldsrc_compat.qc:31-33 takes for netname / health / message and
// sv_triggers.qc:43-47 documents.
// ---------------------------------------------------------------------------
.string m_iszValueName;      // "Monitored key"       — key read off `target`
.string m_iszSourceName;     // "Compare-entity"      — optional live compare side
.string m_iszSourceKey;      // "Compare-key"
.string m_iszCheckValue;     // "Compare-value (alternative)"
.float  m_iCheckType;        // comparator enum, fgd:6239-6261
.float  m_iCheckBehaviour;   // CONSTANT-mode retrigger policy, fgd:6266-6272

// Declared .string, NOT .float, and the type is load-bearing.  The FGD types the
// key (string) and documents "0.0 means to check every frame" (:6273-6274).  On
// a .float field the engine's epair parser atof()s the value and an absent key
// is indistinguishable from an explicit 0 — the wall sv_triggers.qc:146-149
// documents for `triggerstate`.  Held as a string, "" (absent) and "0"
// (authored) are different values, so both readings survive.
.string m_fCheckInterval;

// Runtime state.
.float  tcond_active;        // CONSTANT mode: polling latch
.float  tcond_haslast;       // CONSTANT mode: has tcond_last been filled in yet?
.float  tcond_last;          // CONSTANT mode: previous comparison result
.float  tcond_firing;        // re-entrancy latch, see TCond_FireNamed
.entity tcond_activator;     // last activator handed to us
.entity tcond_caller;        // last caller handed to us
.entity tcond_subject;       // cached find() of `target`

// ---------------------------------------------------------------------------
// spawnflags, sven-coop.fgd:6212-6233.
// ---------------------------------------------------------------------------
const float SF_TCOND_STARTOFF   = 1;   // "Start Off" — CONSTANT mode only
const float SF_TCOND_NOX        = 2;   // "Don't use X (R)" — vector keys only
const float SF_TCOND_NOY        = 4;   // "Don't use Y (G)"
const float SF_TCOND_NOZ        = 8;   // "Don't use Z (B)"
const float SF_TCOND_NOW        = 16;  // "Don't use W (A)" — QC vectors have no
                                       // W; accepted and ignored
const float SF_TCOND_CYCLIC     = 32;  // "Cyclic; no toggle" — on-demand mode
const float SF_TCOND_KEEPACT    = 64;  // "Keep '!activator'"
const float SF_TCOND_IGNOREINIT = 128; // "Ignore initial result" — CONSTANT only

// ---------------------------------------------------------------------------
// m_iCheckType, sven-coop.fgd:6239-6261.  The FGD spells the direction out —
// "Comparator; mon. val. -> comp.-val." — so TCOND_LT is "ent keyvalue is
// smaller than mappers value".
// ---------------------------------------------------------------------------
const float TCOND_EQ  = 0;
const float TCOND_NE  = 1;
const float TCOND_LT  = 2;
const float TCOND_GT  = 3;
const float TCOND_LE  = 4;
const float TCOND_GE  = 5;
const float TCOND_AND = 6;   // "(Ent keyvalue & mappers value) does not equal 0"

// ---------------------------------------------------------------------------
// Reading a keyvalue BY NAME.
//
// `frags` (311 of the 694 corpus placements) and `targetname` (43) are read
// straight off the entity.  `frags` is the right field and not a guess — HL's
// CGameCounter keeps its count in pev->frags (SDK dlls/maprules.cpp:669-679),
// which server/sv_game_team_master.qc:86 already mirrors.
//
// Everything else falls through to the DP_QC_ENTITYDATA path that
// server/sv_trigger_copyvalue.qc:264-270 already relies on (builtins declared
// sv_defs.qc:1608-1622).  That covers the rest of what the corpus monitors —
// model (44), health (20), skin (19), flags (6), angles (5), sequence (5),
// classname — and costs nothing when it is not used.  Sven's own custom
// keyvalues ($i_ / $s_ / $f_ / $v_ prefixed, 176 placements, all in the CTF and
// class-based maps) are a Sven engine feature with no QC representation and are
// unreachable on either path; TCond_ReadKey returns FALSE for them and the
// evaluation is skipped rather than guessed at.
//
// Results land in globals because QC has no out-parameters.  Callers copy the
// values into locals before the next TCond_ReadKey call overwrites the globals;
// the string is safe to hold across that call because FTE tempstrings are
// individually allocated and mark-and-sweep collected (qclib/initlib.c
// PR_AllocTempStringLen / PR_QCGC_Sweep), not a recycled fixed buffer.
// ---------------------------------------------------------------------------
float  tcond_g_num;          // value as a number
string tcond_g_str;          // value as text
float  tcond_g_isstr;        // TRUE when the field is a string field
float  tcond_g_isvec;        // TRUE when the field is a vector field
vector tcond_g_vec;

float(entity e, string key) TCond_ReadKey =
{
    float fn, ft;

    tcond_g_isstr = FALSE;
    tcond_g_isvec = FALSE;
    tcond_g_vec   = '0 0 0';

    // Sven's $s_/$i_/$f_/$v_ custom keyvalues are not fields — they cannot be,
    // since the names are invented per map — so they come out of the side table
    // in sv_customkeys.qc instead.  The type prefix supplies what
    // entityfieldtype would have: $s_ compares as a string, $v_ as a vector,
    // $i_/$f_ numerically.
    //
    // A key the entity does not carry returns FALSE, which skips the tick.  That
    // is deliberate and matches the m_iszSourceName miss below: comparing
    // against a fabricated 0 would fire a branch on evidence we do not have.
    if (CustomKey_IsCustom(key))
    {
        if (!CustomKey_Has(e, key))
            return FALSE;

        tcond_g_str = CustomKey_Get(e, key);
        tcond_g_num = stof(tcond_g_str);

        ft = CustomKey_Type(key);
        if (ft == EV_STRING)
            tcond_g_isstr = TRUE;
        else if (ft == EV_VECTOR)
        {
            tcond_g_isvec = TRUE;
            tcond_g_vec   = stov(tcond_g_str);
        }
        return TRUE;
    }

    if (key == "frags")
    {
        tcond_g_num = e.frags;
        tcond_g_str = ftos(e.frags);
        return TRUE;
    }
    if (key == "targetname")
    {
        tcond_g_str   = e.targetname;
        tcond_g_num   = stof(e.targetname);
        tcond_g_isstr = TRUE;
        return TRUE;
    }

    fn = findentityfield(key);
    if (fn <= 0)
        return FALSE;                // undeclared / unreachable key — skip the tick
    ft = entityfieldtype(fn);
    // NOTE getentityfieldstring returns the null string for a zero-valued field
    // (FTE common/pr_bgcmd.c:7807 short-circuits on !eval->_int), so "" here
    // means "0" / '0 0 0' / "" — which is exactly what stof and stov make of it.
    tcond_g_str = getentityfieldstring(fn, e);
    tcond_g_num = stof(tcond_g_str);
    if (ft == EV_STRING)
        tcond_g_isstr = TRUE;
    else if (ft == EV_VECTOR)
    {
        tcond_g_isvec = TRUE;
        tcond_g_vec   = stov(tcond_g_str);
    }
    return TRUE;
};

// ---------------------------------------------------------------------------
// The numeric half of the comparator table.
// ---------------------------------------------------------------------------
float(float ct, float a, float b) TCond_CompareNum =
{
    float ia, ib;

    switch (ct)
    {
    case TCOND_NE:  return (a != b);
    case TCOND_LT:  return (a <  b);
    case TCOND_GT:  return (a >  b);
    case TCOND_LE:  return (a <= b);
    case TCOND_GE:  return (a >= b);
    // Bitwise, through float locals — the same conversion dance TV_Calc does at
    // sv_trigger_copyvalue.qc:111-116.
    case TCOND_AND: ia = a; ib = b; return ((ia & ib) != 0);
    }
    return (a == b);                 // TCOND_EQ, and anything outside the enum
};

// ---------------------------------------------------------------------------
// Resolve an entity reference (`target`, or `m_iszSourceName`).
//
// The activator and caller come off the trigger rather than off the globals:
// Trigger_UseTargets saves and restores `activator` / `sub_use_caller` around
// every chain (sv_doors.qc:113-152), so outside a chain those globals hold
// whatever the last unrelated fire left in them.  A constant-mode poll runs
// outside any chain, so it must use the pair stamped by our own .use.
// ---------------------------------------------------------------------------
entity(entity src, string nm) TCond_Subject =
{
    entity e;

    if (nm == "" || nm == __NULL__)
        return world;

    // The same magic names trigger_changevalue honours at
    // sv_trigger_copyvalue.qc:225-234.  249 of the 535 cyclic corpus placements
    // aim `target` at !activator — the per-player checks hung off
    // game_playerdie / game_playerkill / game_playerspawn.  No constant-mode
    // placement in the corpus uses either name, so an unresolved one just
    // resolves to world and the evaluation is skipped rather than inventing a
    // subject.
    if (nm == "!activator")
    {
        e = src.tcond_activator;
        if (e && !wasfreed(e))
            return e;
        return world;
    }
    if (nm == "!caller")
    {
        e = src.tcond_caller;
        if (e && !wasfreed(e))
            return e;
        return world;
    }

    // Cache the find() for the common `target` case — find() is a linear edict
    // scan and the constant-mode pollers run it at up to 100 Hz.  Re-resolve if
    // the cached entity died or was renamed (trigger_changevalue can and does
    // write `targetname`).
    if (nm == src.target)
    {
        e = src.tcond_subject;
        if (e && !wasfreed(e) && e.targetname == nm)
            return e;
        e = find(world, targetname, nm);
        src.tcond_subject = e;
        return e;
    }
    return find(world, targetname, nm);
};

// ---------------------------------------------------------------------------
// Fire one of the two branch chains.
// ---------------------------------------------------------------------------
void(entity src, string nm, entity who) TCond_FireNamed =
{
    string saved;

    if (nm == "" || nm == __NULL__)
        return;

    // Aim .target at the branch chain for the duration of the call, the way
    // trigger_changevalue's TV_FireAfter does at sv_trigger_copyvalue.qc:204-212.
    // Going through SUB_UseTargets rather than Trigger_UseTargets keeps `delay`
    // and `killtarget` working if a mapper set them — the FGD exposes neither on
    // this class, but both fields are global in this tree.
    //
    // tcond_firing is a re-entrancy latch: a branch chain that loops back into
    // this same trigger (trivially possible in cyclic mode, where a Use runs an
    // immediate evaluation) would otherwise read the SWAPPED target as its
    // subject and then restore it over the real one, corrupting `target`
    // permanently.
    saved            = src.target;
    src.target       = nm;
    src.tcond_firing = TRUE;
    SUB_UseTargets(src, who, GoldSrc_TriggerStateToUseType(src.triggerstate));
    src.tcond_firing = FALSE;
    src.target       = saved;
};

// ---------------------------------------------------------------------------
// One evaluation.  `constmode` TRUE for a poll tick, FALSE for a cyclic Use.
// ---------------------------------------------------------------------------
void(entity src, float constmode) TCond_Check =
{
    entity subj, cmpent, who, act;
    float  ct, fl, res, changed, dofire;
    float  mnum, misstr, misvec, cnum;
    string mstr, cstr;
    vector mvec, cvec;

    if (src.tcond_firing)                    // a chain looped back into us
        return;
    if (src.m_iszValueName == "")
        return;

    act = src.tcond_activator;
    if (act && wasfreed(act))
        act = world;

    if (!IsMasterTriggered(src.master, act))
        return;

    subj = TCond_Subject(src, src.target);
    if (!subj)
        return;
    if (!TCond_ReadKey(subj, src.m_iszValueName))
        return;

    // Copy out before the compare side overwrites the globals.
    mnum   = tcond_g_num;
    mstr   = tcond_g_str;
    mvec   = tcond_g_vec;
    misstr = tcond_g_isstr;
    misvec = tcond_g_isvec;

    // Compare side.  The FGD offers two sources: another entity's live keyvalue
    // (m_iszSourceName + m_iszSourceKey, "Compare-entity" / "Compare-key", 46
    // corpus placements) or a literal typed into the map — which the FGD itself
    // labels the "(alternative)".  The pair therefore wins when it is set.  If it
    // is set and does NOT resolve, skip the evaluation: comparing against a
    // fabricated 0 would fire a branch on evidence we do not have.
    if (src.m_iszSourceName != "" && src.m_iszSourceKey != "")
    {
        cmpent = TCond_Subject(src, src.m_iszSourceName);
        if (!cmpent)
            return;
        if (!TCond_ReadKey(cmpent, src.m_iszSourceKey))
            return;
        cnum = tcond_g_num;
        cstr = tcond_g_str;
        cvec = tcond_g_vec;
    }
    else
    {
        cstr = src.m_iszCheckValue;          // "" -> 0, which is what the corpus's
        cnum = stof(cstr);                   // key-less "frags > 0" checks want
        cvec = stov(cstr);
    }

    ct = src.m_iCheckType;
    fl = src.spawnflags;

    if (misvec)
    {
        // "Don't use X/Y/Z" blank the extents the mapper excluded — 5 corpus
        // placements monitor `angles` and 5 carry the mask bits.  TV_Mask
        // (sv_trigger_copyvalue.qc:72-78) already does that masking, but ITS flag
        // bits are 1/2/4 where trigger_condition's are 2/4/8
        // (sven-coop.fgd:6217-6219) — hence the halving, rather than a second
        // copy of the same three lines.
        mvec = TV_Mask(mvec, floor(fl / 2));
        cvec = TV_Mask(cvec, floor(fl / 2));
        if (ct == TCOND_NE)
            res = (mvec != cvec);
        else if (ct == TCOND_EQ)
            res = (mvec == cvec);
        else
            res = TCond_CompareNum(ct, vlen(mvec), vlen(cvec));
    }
    else if (misstr && (ct == TCOND_EQ || ct == TCOND_NE))
    {
        // A string field under == / != is a NAME test, not arithmetic.  This is
        // the whole `targetname` / `model` / `classname` half of the corpus:
        // m_iszCheckValue holds things like "veh0_itm1_loc1", which stof()s to 0
        // and would therefore compare equal to every other unparseable name.
        res = (mstr == cstr);
        if (ct == TCOND_NE)
            res = !res;
    }
    else
    {
        res = TCond_CompareNum(ct, mnum, cnum);
    }

    if (!constmode)
    {
        // CYCLIC mode: "Check once when fired" (:6221).  Every Use announces its
        // result — no change latch, no m_iCheckBehaviour (the FGD scopes that key
        // to "Constant mode", :6266), no "Ignore initial result".  This is what
        // makes the 249 per-player !activator checks work: player after player
        // dies holding the flag and each one must drop it, even though the
        // comparison result never changed.
        dofire = TRUE;
    }
    else if (!src.tcond_haslast)
    {
        // First poll.  Fires by default, and that default is load-bearing: a
        // Start-Off constant check is switched on precisely to get an answer.
        // Spawnflag 128 "Ignore initial result" (:6232) is the mapper's opt-out,
        // and its existence is what says the default is to fire.
        dofire = !(fl & SF_TCOND_IGNOREINIT);
    }
    else
    {
        // m_iCheckBehaviour, the FGD's "Constant mode trigger behaviour"
        // (:6266-6272):
        //   0  fire true/false alternatingly  — only on a flip (default)
        //   1  only wait after false          — a true result repeats every tick
        //   2  only wait after true           — a false result repeats every tick
        //   3  always fire for both           — every tick, flip or not
        changed = (res != src.tcond_last);
        if (src.m_iCheckBehaviour == 1)
            dofire = changed || res;
        else if (src.m_iCheckBehaviour == 2)
            dofire = changed || !res;
        else if (src.m_iCheckBehaviour == 3)
            dofire = TRUE;
        else
            dofire = changed;
    }

    if (constmode)
    {
        src.tcond_last    = res;
        src.tcond_haslast = TRUE;
    }

    if (cvar("sv_debug_use"))
    {
        // Two calls because fteqcc caps a varargs call at 8 parameters — the
        // same split sv_func_pushable.qc:390 documents.
        print(sprintf("[trigger_condition] \"%s\" %s %s(%s)",
                      src.targetname, constmode ? "poll" : "fired",
                      src.m_iszValueName, mstr));
        print(sprintf(" op%g \"%s\" -> %s%s\n", ct, cstr,
                      res ? "true" : "false", dofire ? "" : " (held)"));
    }

    if (!dofire)
        return;

    // "Keep '!activator'" (:6225-6230) forwards the activator we were handed.
    // Without it Sven overwrites the activator with the trigger_condition itself,
    // and THAT is the default — the FGD explains why: by the time a constant-mode
    // check finally flips, the original activator may be long gone.
    who = src;
    if ((fl & SF_TCOND_KEEPACT) && act != world && act)
        who = act;

    if (res)
        TCond_FireNamed(src, src.netname, who);
    else
        TCond_FireNamed(src, src.message, who);
};

// ---------------------------------------------------------------------------
// Poll interval — CONSTANT mode only.
// ---------------------------------------------------------------------------
float(entity src) TCond_Interval =
{
    float v;

    // sven-coop.fgd:6273-6274: default "0.1", and "0.0 means to check every
    // frame".  Because the field is held as a .string, an absent key ("") is
    // distinguishable from an authored "0" and both readings are honoured.
    // frametime for the zero case is the same reading trigger_copyvalue's
    // constant mode already takes for its `dmg` (sv_trigger_copyvalue.qc:297).
    if (src.m_fCheckInterval == "" || src.m_fCheckInterval == __NULL__)
        return 0.1;
    v = stof(src.m_fCheckInterval);
    if (v > 0)
        return v;
    if (frametime > 0)
        return frametime;
    return 0.1;
};

void() trigger_condition_think =
{
    if (!self.tcond_active)
        return;                     // stopped; nextthink was cleared too

    // Reschedule BEFORE evaluating.  A branch chain is allowed to fire this
    // entity back and must not be able to lose the poll.
    self.nextthink = time + TCond_Interval(self);
    TCond_Check(self, TRUE);
};

void() trigger_condition_use =
{
    float us;

    // Remember who fired us.  Trigger_UseTargets restores both globals when the
    // chain unwinds (sv_doors.qc:146-149), so a later poll cannot read them —
    // and a constant-mode check aimed at !activator has to keep comparing
    // against that entity, which is exactly the lifetime hazard the FGD warns
    // about at :6226-6229.
    self.tcond_activator = activator;
    self.tcond_caller    = sub_use_caller;

    if (self.spawnflags & SF_TCOND_CYCLIC)
    {
        // "Cyclic; no toggle" (:6221-6222) — one evaluation, right now, and no
        // state change.  These never poll, so "Start Off" is a no-op on them.
        TCond_Check(self, FALSE);
        return;
    }

    // CONSTANT mode: a Use toggles the monitoring, honouring an explicit On when
    // the caller sent one.
    //
    // There used to be deliberately NO `us == USE_OFF` branch here, because
    // USE_OFF is 0 and 0 also meant "the caller never set a useType", so an
    // explicit Off was unreachable and the ambiguity was resolved as a toggle
    // (a spurious toggle-on is recoverable; a stuck-off would soft-lock
    // whatever waits on the branch).
    //
    // The ambiguity is gone — "unset" is USE_UNSET (-1) now, see
    // sv_customdefs.qc — so an explicit Off can and does reach us, and honouring
    // it is what the mapper asked for.  Unset still falls through to toggle,
    // which keeps the old safe reading for every direct .use() caller.
    us = sub_use_type;
    if (us == USE_ON)
        self.tcond_active = TRUE;
    else if (us == USE_OFF)
        self.tcond_active = FALSE;
    else
        self.tcond_active = !self.tcond_active;

    if (self.tcond_active)
        self.nextthink = time + TCond_Interval(self);
    else
        self.nextthink = 0;
};

/*QUAKED trigger_condition (.5 .7 .1) (-8 -8 -8) (8 8 8) START_OFF NO_X NO_Y NO_Z NO_W CYCLIC KEEP_ACTIVATOR IGNORE_INITIAL
Reads one keyvalue off one entity, compares it, and fires a true-chain /
false-chain.  Sven Co-op only; no Half-Life SDK equivalent.

Two modes, picked by CYCLIC (32):
  CYCLIC clear — CONSTANT mode.  Polls every "m_fCheckInterval" seconds and
    fires when the result CHANGES (see m_iCheckBehaviour).  A Use toggles the
    polling on/off; START_OFF says it begins stopped.
  CYCLIC set   — ON-DEMAND mode.  Never polls.  Each Use runs one evaluation
    and fires the matching chain, every time.  START_OFF, IGNORE_INITIAL and
    m_iCheckBehaviour do not apply.

"targetname"        name
"target"            monitored entity ("!activator" / "!caller" also accepted)
"m_iszValueName"    monitored key (corpus: frags, targetname, model, health,
                    skin, flags, angles, sequence, classname)
"m_iszCheckValue"   literal to compare against
"m_iszSourceName"   compare against THIS entity's key instead of the literal
"m_iszSourceKey"    ...this key on it
"m_iCheckType"      0 ==, 1 !=, 2 <, 3 >, 4 <=, 5 >=, 6 & (monitored OP compare)
"netname"           chain fired when the comparison is true
"message"           chain fired when it is false
"m_iCheckBehaviour" CONSTANT mode: 0 on flip, 1 repeat while true,
                    2 repeat while false, 3 always
"m_fCheckInterval"  CONSTANT mode: seconds between polls (default 0.1,
                    explicit 0 = every server frame)
"triggerstate"      useType handed to both chains (default toggle)
"master"            upstream gate

START_OFF (1)          CONSTANT mode: do not begin polling at spawn
NO_X / NO_Y / NO_Z     ignore that extent when the monitored key is a vector
  (2 / 4 / 8)
NO_W (16)              accepted, ignored — QC vectors have no W
CYCLIC (32)            on-demand mode: one evaluation per Use, never polls
KEEP_ACTIVATOR (64)    forward our activator to the chains instead of ourselves
IGNORE_INITIAL (128)   CONSTANT mode: do not fire on the first poll

Sven's own $i_ / $s_ / $f_ / $v_ custom keyvalues ARE supported — they are held
in the side table in server/sv_customkeys.qc, and the type prefix decides how
the comparison is made ($s_ string, $v_ vector, $i_/$f_ numeric).  A check
monitoring one the target entity does not carry skips the tick rather than
comparing against a fabricated 0.
*/
//
// The spawnfunc_ prefix is MANDATORY here and is not decoration: `.float
// trigger_condition` is squadmaker's own condition selector, declared at
// server/sv_monsters.qc:95, and QC has ONE namespace for fields and functions —
// a plain `void() trigger_condition` collides with it and will not compile.  FTE
// resolves "spawnfunc_<classname>" ahead of "<classname>"
// (DP_SV_SPAWNFUNC_PREFIX; engine server/pr_cmds.c:1836), which is the same
// escape hatch server/sv_goldsrc_ammo.qc:426-435 uses for ammo_357 /
// ammo_crossbow and that sv_goldsrc_compat.qc:185-189 documents.
//
void() spawnfunc_trigger_condition =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = trigger_condition_use;
    self.think    = trigger_condition_think;

    // Cyclic checks are purely on-demand — they must never schedule a think.
    if (self.spawnflags & SF_TCOND_CYCLIC)
        return;
    if (self.spawnflags & SF_TCOND_STARTOFF)
        return;

    self.tcond_active = TRUE;
    // The same 0.2 s trigger_copyvalue's constant mode uses
    // (sv_trigger_copyvalue.qc:327): the monitored entity has to have spawned
    // before the first find(), and that first poll already fires a branch.
    self.nextthink = time + 0.2;
};

// ============================================================
//  ambient_music
//  FGD (authoritative — this class has no HL SDK equivalent):
//  - "C:/Program Files (x86)/Steam/steamapps/common/Sven Co-op/svencoop/sven-coop.fgd":1444-1454 — the 
//  - sven-coop.fgd:279-282 — `@BaseClass base(Mandatory) = Targetname` is literally just `targetname`, 
//  - sven-coop.fgd:5565 — target_cdaudio, the same base(Targetname)-only shape, as the precedent for "r
//  - sven-coop.fgd:1330-1333 — ambient_generic's `health(integer) : "Volume (10 = loudest)" : 10`, conf
//  
// ============================================================

// ===========================================================================
//  ambient_music   —   streamed music track: volume / loop / activator-only
//
//  Compile order: needs server/sv_triggers.qc (USE_* and the sub_use_type
//  pass-through global) and server/sv_customdefs.qc (SV_PlayerHasNetchan),
//  both far above sv_th_entities.qc's slot.  target_cdaudio, the sibling this
//  mirrors, is in server/sv_goldsrc_entities.qc immediately above.
//
//  Sven-only.  There is NO Half-Life SDK equivalent — C:/msys64/home/Lex/
//  halflife/dlls/*.cpp has zero hits for the classname — so sven-coop.fgd and
//  the FTE engine source are the whole specification, and every decision below
//  cites one of them.
//
//  sven-coop.fgd:1444-1454
//      @PointClass iconsprite(...) base(Targetname) color(220 220 220)
//          = ambient_music : "Ambient Music"
//      message(sound)  : "Sound File"
//      volume(integer) : "Volume (10 = loudest)" : 10
//      spawnflags       1 : "Start Silent"   : 1     <- CHECKED by default
//                       2 : "Loop"           : 0
//                       4 : "Activator Only" : 0
//
//  base(Targetname) (fgd:279-282, which is just `targetname`) is the ONLY
//  baseclass.  So — exactly like target_cdaudio, whose FGD entry at fgd:5565 is
//  the same shape and which sv_goldsrc_entities.qc:69 implements with nothing
//  but a .use — this entity has no target, no delay, no killtarget, no master
//  and no triggerstate.  It only ever responds to being fired.  Nothing here
//  calls SUB_UseTargets or IsMasterTriggered, and that is deliberate.
//
//  CORPUS (all 108 .bsp on the Sven mount, entity lump parsed): 44 placements
//  across 29 maps.  Every single one sets Start Silent — 39x spawnflags 1,
//  4x spawnflags 3 (+Loop), 1x spawnflags 5 (+Activator Only, hl_c02_a1's
//  "suspense_track").  volume is 10 on 43 of the 44; the exception is
//  suspension.bsp's "lobby_music", spawnflags 3, volume 1.  th_ep3_07's
//  credits entity is:
//      "targetname" "endsong"  "spawnflags" "1"  "volume" "10"
//      "message" "hunger/song/loungemeat_youarewhatieat.mp3"
//
//  ---- PATH ----------------------------------------------------------------
//  `message` is a GoldSrc sound(...) key, i.e. relative to <mod>/sound/.  Proof
//  on disk, not from memory: all 33 distinct `message` values in the corpus
//  were pushed through AmbientMusic_TrackPath's exact algorithm and every one
//  of the 33 lands on a file that exists — th_ep3_07's
//  "hunger/song/loungemeat_youarewhatieat.mp3" at
//  svencoop/sound/hunger/song/loungemeat_youarewhatieat.mp3, and the twenty-
//  seven "../media/Half-LifeNN.mp3" at svencoop/media/.  The "../" is the map
//  climbing back OUT of sound/, so we resolve it here instead of handing the
//  engine a path containing ".." — which is also what sv_soundlist.qc:85-91
//  and shared/sh_modellist.qc:117-121 already do for the same reason.
//
//  It has to be resolved here because FTE's `music` command does not search
//  sound/ at all: Media_CleanupTrackName (engine/client/m_mp3.c:332-341) tries
//  the prefixes "music/", "sound/cdtracks/" and "" and nothing else.  That is
//  also why target_cdaudio's sv_cdaudio_pathfmt default is a bare
//  "media/Half-Life%02i.mp3" with no sound/ on the front, and works.
//
//  ---- LOOP ----------------------------------------------------------------
//  FTE's console command is `music <track> [looptrack]` (m_mp3.c:519-525).
//  With one argument looptrack becomes the track itself and it repeats forever
//  (Media_NamedTrack, m_mp3.c:471-472).  A literal "-" as the looptrack is the
//  engine's own documented "play once": m_mp3.c:474-475 rewrites it to the
//  empty string, and Media_EndedTrack (m_mp3.c:547) only restarts a track when
//  media_loopingtrack is non-empty.  So Loop set is `music "x"` and Loop clear
//  is `music "x" "-"`.  Stopping is the separate `stopmusic` command
//  (m_mp3.c:5228), which clears both slots.
//
//  ---- VOLUME --------------------------------------------------------------
//  FTE has no per-track music volume.  The only knob is the cvar registered at
//  engine/client/snd_dma.c:83 as `musicvolume` (legacy alias `bgmvolume`,
//  default string "0.3"), and it is CVAR_ARCHIVE — the player's own setting.
//  QC can stuff it but cannot read it back, so on the face of it any lowering
//  we do is unrecoverable.
//
//  It is recoverable, because the engine already solved this.  A cvar assigned
//  from a stuffcmd runs at RESTRICT_SERVER (cl_parse.c:7130), so
//  Cmd_FromGamecode() is true (cmd.h:239) and Cvar_Command takes its
//  server-override branch (cvar.c:1601-1626).  Three separate mechanisms give
//  the player their value back:
//    * setting the cvar to a NON-default string calls Cvar_LockFromServer
//      (cvar.c:1462-1485), which stashes the player's ORIGINAL value in
//      latched_string;
//    * setting it back to its DEFAULT string releases the override and restores
//      that latched value (cvar.c:1601-1610) — that is the second half of
//      AMUSIC_VOLUME_RELEASE below, and it is why that literal reads exactly
//      "0.3" and must keep matching snd_dma.c:83;
//    * Cvar_WriteVariables (cvar.c:1719-1721) writes latched_string, NOT the
//      live value, so even a config saved while we hold the lock records the
//      player's own number; and Cvar_ApplyLatches(CVAR_SERVEROVERRIDE, true)
//      runs on both disconnect and level change (cl_main.c:2286, 2494).
//
//  A BARE `musicvolume 0.3` IS NOT SAFE ON ITS OWN.  If the cvar is NOT
//  currently server-overridden, that string EQUALS defaultstr, so Cvar_Command's
//  `else if (Cmd_FromGamecode())` arm (cvar.c:1620-1626) declines to lock and
//  falls straight through to a plain Cvar_Set — silently overwriting whatever
//  the player had chosen with 0.3, and archiving it.  So the release is two
//  commands, and the pair is idempotent in BOTH states:
//      musicvolume 0.2999   -> not equal to defaultstr, so this always takes the
//                              lock branch.  Cvar_LockFromServer (cvar.c:1462-1485)
//                              keeps an EXISTING latched_string if we already held
//                              the cvar, and otherwise stashes the player's live
//                              value.  Either way latched_string is now the
//                              player's own number.
//      musicvolume 0.3      -> equals defaultstr, so this releases and sets the
//                              cvar to that latched value (cvar.c:1601-1610).
//  Priming like that matters because .am_vol_locked below rides on a PLAYER
//  edict, and this is a QuakeWorld progs: sv_user.c:2278-2279 only ED_Clear's a
//  disconnecting client's edict under PROG_NQ, so a recycled client slot can
//  inherit a stale TRUE (the same slot-recycling hazard sv_player.qc:3562
//  already resets .is_bot for).  With the priming command the worst a stale
//  latch can do is hand a player back their own value.
//
//  Two rules keep the blast radius tiny:
//    * volume 10 never lowers musicvolume at all.  "Loudest" means "as loud as
//      the player has it", and 43 of the 44 corpus placements are volume 10.
//    * sv_ambientmusic_volume is the musicvolume that stands in for volume 10
//      when we do have to scale, defaulting to FTE's own 0.3.  Set it to 0 to
//      switch the whole volume key off.
//
//  Note the ordering inside AmbientMusic_Send — musicvolume is settled BEFORE
//  the music command, because Media_NextTrack (m_mp3.c:181-182) bails out and
//  starts nothing at all while bgmvolume.value <= 0.
// ===========================================================================

const float SF_AMUSIC_START_SILENT   = 1;   // sven-coop.fgd:1450
const float SF_AMUSIC_LOOP           = 2;   // sven-coop.fgd:1451
const float SF_AMUSIC_ACTIVATOR_ONLY = 4;   // sven-coop.fgd:1452

// Latch on the SOURCE: does this entity believe its shared-channel track is
// playing?  Only the non-ACTIVATOR_ONLY toggle path reads it — see .am_src.
.float am_playing;

// Latch on the PLAYER: which ambient_music is currently playing for THIS
// client because it is ACTIVATOR_ONLY.  It cannot live on the source, because
// ACTIVATOR_ONLY is per-listener and Sven is a co-op game: with a single
// per-source flag, hl_c02_a1's "suspense_track" would toggle globally, so the
// SECOND player to cross the trigger would silence the FIRST player's music
// instead of starting their own, the third would start it again, and so on.
.entity am_src;

// Latch on the PLAYER: we currently hold this client's musicvolume down.  It
// only decides WHETHER to bother sending the release; the release itself is
// safe either way (see the VOLUME block), because this field can be stale on a
// recycled client slot.
.float am_vol_locked;

// The ambient_music that last claimed the shared music channel, or world.
// There is one music channel per client, so a second ambient_music starting a
// track silently takes the first one's playback away.  Without this latch,
// re-firing the OLD entity (toggle -> stop) would silence the NEW entity's
// track.  ACTIVATOR_ONLY plays deliberately do NOT claim it: they are one
// player's channel, not the shared one.
entity ambient_music_owner;

// Hand the player their own musicvolume back.  Two commands, and both are
// load-bearing — see "A BARE `musicvolume 0.3` IS NOT SAFE ON ITS OWN" above.
// The first is any non-default string, which forces Cvar_Command down the
// lock branch so latched_string is guaranteed to hold the player's own value;
// the second is EXACTLY musicvolume's registered default (snd_dma.c:83), which
// is what Cvar_Command (cvar.c:1601-1610) reads as "release and restore".
#define AMUSIC_VOLUME_RELEASE "musicvolume 0.2999\nmusicvolume 0.3\n"

// ---------------------------------------------------------------------------
// Resolve `message` into something FTE's `music` command can find.
//
// Base prefix is "sound/" (the GoldSrc sound(...) root).  A leading "../"
// pops it, which is how the hl_c* maps reach ../media/.  Extra "../" beyond
// that would climb out of the gamedir, so they are clamped away rather than
// passed through — the same clamp sv_soundlist.qc:85-91 applies, and for the
// same reason (FTE refuses any VFS name containing "..").
// sv_ambientmusic_prefix lets a server relocate the root without a rebuild,
// the same escape hatch sv_cdaudio_pathfmt gives target_cdaudio; empty means
// "use the built-in sound/".
// ---------------------------------------------------------------------------
string(string raw) AmbientMusic_TrackPath =
{
    string p;
    string base;

    if (raw == "")
        return "";

    base = cvar_string("sv_ambientmusic_prefix");
    if (base == "")
        base = "sound/";

    // Hammer writes backslashes into some sound keys; the engine's file system
    // wants forward slashes.
    p = strreplace("\\", "/", raw);

    while (substring(p, 0, 1) == "/")
        p = substring(p, 1, -1);
    while (substring(p, 0, 2) == "./")
        p = substring(p, 2, -1);
    while (substring(p, 0, 3) == "../")
    {
        p = substring(p, 3, -1);
        base = "";
    }

    if (p == "")
        return "";

    return strcat(base, p);
};

// Build the console command that starts this entity's track, or "" if the
// entity names no usable file.
string(entity src) AmbientMusic_PlayCommand =
{
    string path;

    path = AmbientMusic_TrackPath(src.message);
    if (path == "")
        return "";

    if (src.spawnflags & SF_AMUSIC_LOOP)
        return sprintf("music \"%s\"\n", path);

    return sprintf("music \"%s\" \"-\"\n", path);
};

// The musicvolume this entity's track wants, or 0 for "leave the player's own
// setting alone".  See the VOLUME block above.
float(entity src) AmbientMusic_WantVolume =
{
    float base;

    if (src.volume >= 10)
        return 0;                       // full = whatever the player has

    base = cvar("sv_ambientmusic_volume");
    if (base <= 0)
        return 0;                       // volume key switched off server-wide

    return base * (src.volume / 10);
};

// Push one music state change to one client.
//
// wantvol is the musicvolume this state needs, or 0 for "the player's own".
// Volume is settled FIRST: Media_NextTrack (m_mp3.c:181-182) refuses to start
// anything while bgmvolume.value <= 0.
//
// Deliberately the BARE `musicvolume <v>` form and not `set musicvolume <v>`:
// only the bare form reaches Cvar_Command, and only Cvar_Command implements the
// lock-and-release pair this depends on.  `set` (Cmd_set_f, cmd.c:4061-4068)
// locks unconditionally and never releases.
//
// The lower must never be the default STRING either, or it would take the same
// silent-overwrite path the release is primed against.  With the shipped
// sv_ambientmusic_volume 0.3 the largest lower is 0.27, but an admin who set
// sv_ambientmusic_volume 3 would make volume 1 land on exactly 0.3 — so the
// test is on the formatted command, which is precisely what Cvar_Command
// strcmp's against defaultstr, and not on the float (3 * 0.1 is not 0.3 in
// binary, yet %g prints it as "0.3", which is the string that matters).
//
// Because wantvol==0 emits the release whenever THIS CLIENT is still locked,
// every transition heals the volume: a volume-10 entity starting after a
// volume-1 entity restores the player, and so does any stop — including the
// stop of an entity that never lowered anything itself.
void(entity p, float wantvol, string cmd) AmbientMusic_Send =
{
    string volcmd;

    if (!SV_PlayerHasNetchan(p))
        return;

    if (wantvol > 0)
    {
        volcmd = sprintf("musicvolume %g\n", wantvol);
        if (volcmd == "musicvolume 0.3\n")
            volcmd = "musicvolume 0.2999\n";
        stuffcmd(p, volcmd);
        p.am_vol_locked = TRUE;
    }
    else if (p.am_vol_locked)
    {
        stuffcmd(p, AMUSIC_VOLUME_RELEASE);
        p.am_vol_locked = FALSE;
    }

    if (cmd != "")
        stuffcmd(p, cmd);
};

void(float wantvol, string cmd) AmbientMusic_Broadcast =
{
    entity p;

    p = find(world, classname, "player");
    while (p)
    {
        AmbientMusic_Send(p, wantvol, cmd);
        p = find(p, classname, "player");
    }
};

void(entity src, entity who) AmbientMusic_Play =
{
    string cmd;
    float  wantvol;

    cmd = AmbientMusic_PlayCommand(src);
    if (cmd == "")
        return;                         // warned about once, at spawn

    wantvol = AmbientMusic_WantVolume(src);

    if (src.spawnflags & SF_AMUSIC_ACTIVATOR_ONLY)
    {
        // Nothing to play to.  Happens when the chain that fired us started at
        // something with no player behind it (a multi_manager on a timer, say).
        // Sven's flag names one listener and we have none, so this is silence,
        // not a broadcast.
        if (!SV_PlayerHasNetchan(who))
        {
            if (cvar("sv_debug_use"))
                print(sprintf("[ambient_music] \"%s\" is ACTIVATOR_ONLY but the activator is not a client; ignored\n",
                              src.targetname));
            return;
        }
        AmbientMusic_Send(who, wantvol, cmd);
        who.am_src = src;
        if (cvar("sv_debug_use"))
            print(sprintf("[ambient_music] \"%s\" (activator only) -> %s",
                          src.targetname, cmd));
        return;
    }

    AmbientMusic_Broadcast(wantvol, cmd);
    src.am_playing      = TRUE;
    ambient_music_owner = src;

    if (cvar("sv_debug_use"))
        print(sprintf("[ambient_music] \"%s\" -> %s", src.targetname, cmd));
};

void(entity src, entity who) AmbientMusic_Stop =
{
    if (src.spawnflags & SF_AMUSIC_ACTIVATOR_ONLY)
    {
        // Only ever silence a client that is actually listening to US.  The
        // engine has ONE music channel per client, so an unconditional
        // stopmusic here would cut whatever else that player had going.
        if (who.am_src != src)
            return;
        AmbientMusic_Send(who, 0, "stopmusic\n");
        who.am_src = world;
        if (cvar("sv_debug_use"))
            print(sprintf("[ambient_music] \"%s\" (activator only) -> stopmusic\n",
                          src.targetname));
        return;
    }

    // Some other ambient_music has taken the channel since we started.  Drop
    // our latch, but do not silence a track we no longer own — and do not touch
    // musicvolume either: whoever took the channel set it for their own track.
    if (ambient_music_owner != src)
    {
        src.am_playing = FALSE;
        return;
    }

    AmbientMusic_Broadcast(0, "stopmusic\n");
    src.am_playing      = FALSE;
    ambient_music_owner = world;

    if (cvar("sv_debug_use"))
        print(sprintf("[ambient_music] \"%s\" -> stopmusic\n", src.targetname));
};

void() ambient_music_use =
{
    float ut;

    // Same read as trigger_entity_iterator (sv_goldsrc_entities.qc:251).
    //
    // This comment used to say an explicit "off" could not survive the chain,
    // and to recommend firing the entity twice instead.  That WAS true and is
    // no longer: the sentinel for "nobody set a use type" is USE_UNSET (-1)
    // rather than 0, so USE_OFF now arrives intact and the USE_OFF branch below
    // is genuinely reachable from a map.  See sv_customdefs.qc.
    ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

    if (ut == USE_OFF)
    {
        AmbientMusic_Stop(self, activator);
        return;
    }
    if (ut == USE_ON)
    {
        AmbientMusic_Play(self, activator);
        return;
    }

    // USE_SET has no meaning for a music track (there is no value to set), so
    // it falls in with USE_TOGGLE.
    //
    // ACTIVATOR_ONLY toggles against the ACTIVATOR's latch, not the entity's:
    // the state being flipped is "is this player hearing us", and in a co-op
    // game that differs per player.
    if (self.spawnflags & SF_AMUSIC_ACTIVATOR_ONLY)
    {
        if (activator.am_src == self)
            AmbientMusic_Stop(self, activator);
        else
            AmbientMusic_Play(self, activator);
        return;
    }

    if (self.am_playing)
        AmbientMusic_Stop(self, activator);
    else
        AmbientMusic_Play(self, activator);
};

// Start Silent clear => the track is playing from the moment the map starts.
//
// It cannot fire at spawn: no client has been put in the server yet, so the
// stuffcmd would go nowhere.  A fixed delay would be a guess about how long
// PutClientInServer takes, so poll for the first client with a netchan instead,
// and give up after 30s so an empty server does not poll forever.
void() ambient_music_autostart =
{
    entity p;
    float  ready;

    ready = FALSE;
    p = find(world, classname, "player");
    while (p)
    {
        if (SV_PlayerHasNetchan(p))
            ready = TRUE;
        p = find(p, classname, "player");
    }

    if (!ready)
    {
        if (time < 30)
            self.nextthink = time + 0.5;    // .think is still this function
        return;
    }

    AmbientMusic_Play(self, world);
};

/*QUAKED ambient_music (.6 .8 .4) (-8 -8 -8) (8 8 8) START_SILENT LOOP ACTIVATOR_ONLY
Sven Co-op streamed music track.  Fire it to start the track; fire it again to
stop it.

"targetname"  name
"message"     music file, relative to sound/ ("../" climbs back out, which is
              how the hl_c* maps reach ../media/Half-LifeNN.mp3)
"volume"      0..10, 10 = loudest (default 10).  10 leaves the player's own
              musicvolume alone; anything less scales it and hands it back on
              stop — see the VOLUME note at the top of this file.

START_SILENT (1):    do not start at map load.  Set on all 44 corpus placements.
LOOP (2):            repeat forever instead of playing once.
ACTIVATOR_ONLY (4):  only the activator hears it, and only the activator's own
                     second fire stops it.

Server cvars, both created here:
  sv_ambientmusic_prefix  path root for "message"          (default "sound/")
  sv_ambientmusic_volume  the client musicvolume that stands in for volume 10
                          when a placement asks for less; 0 switches the volume
                          key off entirely                     (default "0.3")
*/
void() ambient_music =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = ambient_music_use;

    // registercvar() never overwrites a cvar a config already set, so this is
    // safe to run once per placement.  Both reads are also written so that a
    // failed registration still degrades to something sane: cvar_string()
    // returns "" (-> the built-in "sound/") and cvar() returns 0 (-> the volume
    // key stays off rather than guessing at a client's audio settings).
    registercvar("sv_ambientmusic_prefix", "sound/");
    registercvar("sv_ambientmusic_volume", "0.3");   // FTE's own musicvolume default

    // FGD default is 10 and Hammer writes the key out, so all 44 corpus
    // placements carry it.  QC cannot tell "key absent" from "key present and
    // 0", and a deliberately silent music entity is not a thing any map wants,
    // so 0 is read as unset — the same call target_cdaudio makes for its own
    // FGD-defaulted `health` (sv_goldsrc_entities.qc:71-72).
    if (self.volume <= 0)
        self.volume = 10;
    if (self.volume > 10)
        self.volume = 10;

    if (self.message == "")
    {
        dprint(sprintf("ambient_music \"%s\" at %v: no 'message' key; entity will be silent\n",
                       self.targetname, self.origin));
        return;
    }

    // Sequential ifs rather than a && chain: logicops is off mod-wide, and
    // sv_ambient_generic.qc:650-656 spells its own three-term spawn gate the
    // same way.
    if (self.spawnflags & SF_AMUSIC_START_SILENT)
        return;
    if (self.spawnflags & SF_AMUSIC_ACTIVATOR_ONLY)
        return;             // no activator exists at map load

    self.think     = ambient_music_autostart;
    self.nextthink = time + 0.5;
};

// ============================================================
//  trigger_changesky
//  NO Half-Life SDK equivalent exists — `grep -rn "changesky" C:/msys64/home/Lex/halflife/` returns zer
//  
//  1) FGD — "C:/Program Files (x86)/Steam/steamapps/common/Sven Co-op/svencoop/sven-coop.fgd":6073-6083
//  @PointClass base(Targetname) color(160 192 255) = trigger_changesky : "Trigger Change Sky"
//  [ skyname(string) : "Sky Name"
//  color(color255) : "Color"
// ============================================================

// ===========================================================================
//  trigger_changesky
// ===========================================================================
//
//  PROVENANCE
//  ----------
//  There is NO Half-Life SDK equivalent: a recursive grep of
//  C:/msys64/home/Lex/halflife for "changesky" returns nothing.  The class is
//  Sven-only, so the behaviour below is reconstructed from three sources.
//
//  1) svencoop/sven-coop.fgd:6073-6083
//         @PointClass base(Targetname) color(160 192 255)
//             = trigger_changesky : "Trigger Change Sky"
//         [
//             skyname(string) : "Sky Name"
//             color(color255) : "Color"
//             spawnflags(flags) =
//             [ 1 : "All players" : 0
//               2 : "No clients"  : 0
//               4 : "Update server" : 0 ]
//         ]
//     base(Targetname) is targetname ONLY (sven-coop.fgd:279-282, whose own
//     base(Mandatory) at :58-61 adds just "ondestroyfn").  So this entity has
//     NO target, NO delay and NO master.  It is a pure sink - it never fires a
//     chain, which is why there is deliberately no SUB_UseTargets /
//     IsMasterTriggered call below.  Adding either would be inventing a key
//     the editor cannot even set.
//
//  2) svencoop/dlls/server.dll - Sven ships no source, so the
//     CTriggerChangeSky string block was read straight out of the binary at
//     file offset 0x442fa4.  In binary order:
//         "CTriggerChangeSky"
//         "skyname"
//         "trigger_changesky \"%s\": Sky not specified at %f %f %f."
//         "trigger_changesky \"%s\": Changes not specified at %f %f %f."
//         "Changing sky for all players to \"%s\" RGB %d %d %d."
//         "Changing sky for one player to \"%s\" RGB %d %d %d."
//         "Unable to change the sky, are you using a relay without the
//          spawnflag for updating all players?"
//         "Changing server sky name to \"%s\"."
//         "sv_skyname"
//         "Changing server sky color to RGB %d %d %d."
//     That block IS the control flow, and it pins down every flag:
//       - "for all players" vs "for one player" is spawnflag 1.  WITHOUT it
//         the change goes to the single ACTIVATOR.
//       - the "Unable to change the sky, are you using a relay..." line is the
//         no-flag-1 path finding no player activator - i.e. exactly what
//         happens when a trigger_relay or multi_manager fires it.
//       - spawnflag 4 writes the "sv_skyname" cvar.  That is the GoldSrc
//         server sky: dlls/world.cpp:674-677 is where worldspawn's own
//         "skyname" key sets the same cvar, and it reaches a client through
//         the connect handshake.  So flag 4 means "and this is what people who
//         JOIN LATER get" - it is not a retroactive push to players already in
//         the map.  Flag 2 ("No clients") suppresses the client half entirely,
//         leaving only that record update.
//
//  3) Corpus.  Exactly one instance ships in the target campaign.  Extracted
//     from lump 0 of th_ep3_07.bsp (BSP v30, ent lump at offset 1076824):
//         {
//         "origin" "8720 -6672 1768"
//         "skyname" "2VS"
//         "targetname" "th55_chgsky"
//         "spawnflags" "5"
//         "classname" "trigger_changesky"
//         }
//     spawnflags 5 = All players | Update server, fired from the
//     multi_manager "escape_mm" (slot "th55_chgsky" "3.5") - which is precisely
//     why the mapper had to set flag 1: a multi_manager carries no player
//     activator, so without it Sven would have printed the "Unable to change
//     the sky" line and done nothing.  The map's worldspawn sky is "cgs"; both
//     skies ship as svencoop/gfx/env/{cgs,2vs}{rt,lf,bk,ft,up,dn}.tga.
//
//  IN-TREE SIBLINGS MIRRORED
//  -------------------------
//  server/sv_env_fog.qc and server/sv_env_sun.qc - the two other server
//  entities that own a CLIENT-side renderer cvar.  Same shape as both: module
//  globals set by the entity, a stuffcmd-per-real-client push guarded with the
//  identical `!p || bot_adding || clienttype(p) != CLIENTTYPE_REAL` test
//  (sv_env_fog.qc:47, sv_env_sun.qc:184), and a re-push so arrivals converge.
//  Entity/debug shape follows target_cdaudio (sv_goldsrc_entities.qc:33-73):
//  find(world, classname, "player") walk, `cvar("sv_debug_use")` chatter.
//  The mapper key is bound by DECLARING it, which is how sh_modellist.qc binds
//  worldspawn's globalmodellist and how sv_env_sun.qc binds sundir/skylight -
//  and it also keeps the key out of ED_ParseUnknownEpair, whose own
//  globalmodellist/globalsoundlist early-out (sv_multi_manager.qc:508-513)
//  documents the same interaction.
//
//  `activator` is safe to read in the use function: Trigger_UseTargets
//  (sv_doors.qc:88-112) assigns the global from its `triggerer` argument and
//  restores it afterwards, immediately around the `self.use()` call.
//
//  Sky name form: send the GoldSrc name RAW, no prefix.  FTE resolves an
//  r_skybox value through Shader_ParseSkySides' pattern list, which includes
//  "gfx/env/%s%s" (engine/gl/gl_shader.c:669-676), so "2VS" finds
//  gfx/env/2VSrt.tga exactly as GoldSrc does.
//
//
//  =====================  WHO OWNS r_skybox  (THE HAZARD)  =================
//
//  CSQC ALREADY WRITES r_skybox.  client/cl_rain.qc's lightning storm flips
//  the sky to a white box for the duration of a strike.  Both halves must not
//  believe they own the cvar, so here is the exact division of ownership, read
//  off cl_rain.qc rather than assumed:
//
//    THE SERVER (this file) IS THE ONLY PERSISTENT OWNER OF r_skybox.
//    The lightning code is a TRANSIENT BORROWER holding a self-terminating
//    lease, and it never invents a value of its own to leave behind:
//
//      - it TAKES the lease at strike start by caching whatever is in the
//        cvar at that instant:
//            cl_rain.qc:1611   lightning_orig_sky = cvar_string("r_skybox");
//      - it RETURNS the lease by writing that cached string back, on every
//        exit path it has:
//            cl_rain.qc:1558-1562   flash ran to completion
//            cl_rain.qc:1543-1546   "not stuck on white" safety net
//            cl_rain.qc:1571-1573   the swap pattern's own low phases
//            cl_rain.qc:1584-1589   cl_lightning / weather turned off mid-flash
//                                   (forces lightning_flash_end = cltime)
//      - once returned, Rain_LightningTickSky's `lightning_flash_end <= 0`
//        branch (cl_rain.qc:1538-1548) finds lightning_sky_state already 0 and
//        writes NOTHING AT ALL until the next strike.
//
//    Two consequences follow, and they are what make this safe:
//
//      (1) A server write that lands while NO lease is held is permanent AND
//          re-bases the borrower.  The next strike re-reads the live cvar
//          (cl_rain.qc:1611), so it caches OUR new sky and later restores OUR
//          new sky.  Ownership transfers with zero coordination: no shared
//          variable, no new cvar, no edit to cl_rain.qc.
//      (2) A server write that lands DURING a lease is lost, and lost exactly
//          once - at the moment the lease is returned, which is at most
//          cl_lightning_flash_duration after the strike began (default 0.18s,
//          cl_rain.qc:1547-1548).
//
//    So the design is NOT to fight for the cvar, and NOT to poll it.  It is to
//    guarantee that at least one write lands OUTSIDE a lease.  Leases are
//    sub-second and rare - strikes are cl_lightning_min_interval ..
//    cl_lightning_max_interval apart, defaulting to 8..25s (cl_rain.qc:
//    1593-1596) - so every sky change is delivered as a RE-ASSERT TRAIN: the
//    same `r_skybox` write repeated at +0, +0.4, +1.2, +3.0 and +6.0 seconds
//    (CHGSKY_TRAIN_STEPS / Chgsky_StepDelay below).  Any single one of those
//    landing between leases is final, and it also fixes the borrower's cache
//    for every future strike.  For the entire train to be swallowed a client
//    would need cl_lightning_flash_duration >= 6 - 33x its default.
//
//    The train is deliberately NOT a heartbeat.  A periodic re-assert would
//    stomp the white sky mid-strike and visibly kill the lightning effect.
//    Once a player's train is spent this file stops writing r_skybox for that
//    player entirely, so the storm owns the cvar unchallenged during play.
//
//    Corollary worth stating plainly: the storm ending can no longer revert a
//    changesky, because by then "the original sky" the storm restores IS the
//    string the server put there.  The reversion the hazard describes is a
//    property of WHEN a write lands, not of who wrote last.
//
//    KNOWN WEAKNESS ON THE CLIENT SIDE, not fixable from here: cl_rain.qc:1611
//    stores an engine TEMP string (cvar_string) into a persistent global with
//    no strzone.  That buffer rotates, so the lease's restore write can put
//    garbage into r_skybox independently of anything this file does.  Worth a
//    separate fix in cl_rain.qc; it does not change the design above, which
//    only requires that a write land while no lease is held.
//
//  LATE JOINERS / MAP-START BASELINE
//  ---------------------------------
//  GoldSrc hands a connecting client sv_skyname through the connect handshake.
//  No PutClientInServer hook is available from this file (sv_player.qc is where
//  EnvSun_StuffPlayer is called from, and this file must not edit it), so the
//  same job is done by a small driver entity that RECONCILES instead: it walks
//  the real clients on a slow tick and pushes to anyone whose per-player
//  generation is behind the server record.  A freshly connected edict reads
//  generation 0, so it converges by itself - and that IS guaranteed rather than
//  assumed: SV_SetUpClientEdict calls ED_Clear on every connect
//  (engine/server/sv_user.c:5572-5590, reached from sv_main.c:2650), so even a
//  RECONNECTING client comes back with every field of this file zeroed.
//
//  The driver is also spawned at MAP LOAD with the map's own worldspawn
//  "skyname" as generation 1.  That is not cosmetic: a stuffed r_skybox
//  persists on the client across a map change (r_skybox is not archived, but
//  nothing resets it either - engine/gl/gl_warp.c:41), so without an explicit
//  re-base the previous map's sky would leak into this one.  Same clear-first
//  reasoning as SV_WeatherStuffPlayer's "so a map without weather keys doesn't
//  inherit the previous map's cl_rain / cl_snow state" (sv_env_fog.qc:74-77).
//

// Mapper key.  Declared so the BSP entity-block parser binds it directly.
// Bonus: worldspawn carries this key too ("skyname" "cgs" in th_ep3_07) and
// until now had no field to bind to, so it fell through to
// ED_ParseUnknownEpair (sv_multi_manager.qc:429) and - on a compiler that
// emits classname last - became a junk mm_slot edict on the world.  Declaring
// it here removes that too, and gives us world.skyname as the map baseline.
// Declaring the field cannot steal the map's own sky from the renderer: the
// client resolves that through cl.skyname / R_SetSky (engine/gl/gl_warp.c:88-101),
// which never consults an SSQC field.
//
// `color` needs no declaration: sv_defs.qc:448 already declares .vector color
// (the realtime-light tint), the engine binds the map's "color" key onto it,
// and it is inert on an entity with no pflags.
.string skyname;

// sven-coop.fgd:6077-6082
const float SF_CHANGESKY_ALLPLAYERS   = 1;   // "All players"   - broadcast instead of activator-only
const float SF_CHANGESKY_NOCLIENTS    = 2;   // "No clients"    - suppress the client half
const float SF_CHANGESKY_UPDATESERVER = 4;   // "Update server" - GoldSrc sv_skyname: what JOINERS get

// Re-assert train - see "WHO OWNS r_skybox" above.  Cumulative offsets from
// the change are 0, 0.4, 1.2, 3.0, 6.0 seconds.
const float CHGSKY_TRAIN_STEPS = 5;
const float CHGSKY_TICK_BUSY   = 0.1;   // driver tick while any train is running
const float CHGSKY_TICK_IDLE   = 0.5;   // driver tick once everyone has converged
                                        // (still needed - it is how a joiner is noticed)

// --- per-PLAYER convergence state -----------------------------------------
.string chgsky_want;    // sky this client should be showing ("" = the map's own)
.float  chgsky_armed;   // 1 once this client has ever been given a want
.float  chgsky_sends;   // writes of chgsky_want already delivered (train position)
.float  chgsky_next;    // server time of this client's next train write
.float  chgsky_seq;     // server-record generation this client has been seeded with

// --- per-ENTITY parsed state ----------------------------------------------
.string chgsky_sky;     // zoned, SCRUBBED copy of the skyname key
.float  chgsky_hassky;  // 1 = the map really set skyname (so "" means "revert", not "unset")
.float  chgsky_hascol;  // 1 = the map really set a non-black color
.float  chgsky_warned;  // latch for the one-shot mapper-error prints

// --- per-MAP latch.  Lives on the WORLD EDICT, deliberately NOT in a global.
// See Chgsky_MapInit for why that distinction is load-bearing.
.float  chgsky_boot;

// --- server record: the GoldSrc sv_skyname equivalent ---------------------
string changesky_record;        // sky a CONNECTING client should be given
float  changesky_record_seq;    // bumped whenever changesky_record changes
vector changesky_color;         // last sky colour a flag-4 change recorded (0..255)
float  changesky_color_set;     // 1 once a map has recorded a colour

entity changesky_driver;        // the reconcile / train worker

// The sky name is MAPPER-AUTHORED and ends up inside a QUOTED argument of a
// stuffcmd - i.e. inside a real console on every connected client, from a file
// that is routinely downloaded.  A value containing '"' closes the argument and
// ';' starts a new command, so `2VS"; quit; "` would be a remote console on the
// whole server.  '$' is FTE's console variable expansion.  Strip them once, at
// parse time, before the string is ever zoned.
//
// strreplace is sv_defs.qc:1600 and the tree already scrubs strings with it the
// same way (shared/sh_weapon_manifest.qc:522-525).  No legitimate GoldSrc sky
// prefix contains any of these characters - the corpus name is "2VS" and the
// baseline is "cgs" - so nothing real is lost.
string(string raw) Chgsky_SafeName =
{
    string s;

    s = raw;
    s = strreplace("\"", "", s);
    s = strreplace(";",  "", s);
    s = strreplace("$",  "", s);
    s = strreplace("\n", "", s);
    return s;
};

// Per-map (re)initialisation of everything this file owns at file scope.
//
// THE LATCH MUST BE AN EDICT FIELD, NOT A GLOBAL.  server/sv_main.qc:2738
// (worldspawn) states the rule outright - "FTE doesn't reload progs between map
// loads, so any global that accumulates across a map ... needs an explicit
// clear here" - and backs it with a whole reset battery, including
// `monster_chain_head = world;`, which is a global ENTITY reference reset for
// exactly the second hazard below.  Edicts, by contrast, are rebuilt for every
// map (Q_InitProgs -> PR_InitEnts, engine/server/pr_cmds.c:1970-1990), so
// world.chgsky_boot reads 0 on every map load whether or not the globals
// survived.  It is the only "this is a new map" edge this file can observe
// without editing worldspawn, which the output constraint forbids.
//
// What breaks if this is latched on `changesky_record_seq` instead:
//
//   1. The baseline block never re-runs, so changesky_record still holds the
//      PREVIOUS map's sky.  The driver then seeds every client on the new map
//      with it - turning the sky LEAK this design exists to prevent into an
//      active PUSH of the wrong sky.  (Cross-map leakage is real: r_skybox is
//      CVARFC with no CVAR_ARCHIVE and no map-load reset, gl_warp.c:41.)
//
//   2. changesky_driver still holds the previous map's edict INDEX.  Edict
//      slots are re-used from zero on each map, and a Sven map spawns hundreds,
//      so that slot is almost certainly a LIVE, UNRELATED entity.  wasfreed()
//      is therefore false, Chgsky_EnsureDriver returns early, and no driver is
//      ever spawned - the entity silently does nothing from the second map
//      onwards - while Chgsky_KickDriver writes .nextthink onto that unrelated
//      entity, firing its think early or waking an entity with no think at all.
//
// The strzone here is never freed: one short string per map load, matching the
// never-freed precedent scripted_sentence's speaker documents at
// sv_multi_manager.qc:588-593.  It cannot be strunzone'd on the next map init
// without a second flag to distinguish it from the "" literal, and the leak is
// smaller than that bookkeeping.
void() Chgsky_MapInit =
{
    if (world.chgsky_boot)
        return;
    world.chgsky_boot = 1;

    changesky_driver    = world;    // drop the stale cross-map edict reference
    changesky_color     = '0 0 0';
    changesky_color_set = 0;

    // world.skyname is worldspawn's own key; it reads "" on a map with no
    // skybox, and `r_skybox ""` is exactly the engine's "no user override, use
    // the map's own sky" state (gl_warp.c:100 - the cvar only overrides while
    // non-empty).  Scrubbed like any other mapper string; worldspawn is no more
    // trustworthy than the trigger.
    if (world.skyname != "" && world.skyname != __NULL__)
        changesky_record = strzone(Chgsky_SafeName(world.skyname));
    else
        changesky_record = "";

    changesky_record_seq = 1;
};

// Gap before train write number `sends` (1-based: the gap BEFORE the 2nd write
// is Chgsky_StepDelay(1)).  Geometric on purpose - flat spacing could put every
// write of a short train inside one long flash.
float(float sends) Chgsky_StepDelay =
{
    if (sends <= 0) return 0;
    if (sends == 1) return 0.4;
    if (sends == 2) return 0.8;
    if (sends == 3) return 1.8;
    return 3.0;
};

// Point one client at a sky and (re)arm its train.  Same real-client guard as
// EnvFog_StuffPlayer / EnvSun_StuffPlayer: bots have no netchan, and
// bot_adding covers the spawnclient window where is_bot is not set yet.
void(entity p, string sky) Chgsky_SetWant =
{
    if (!p || p == world || wasfreed(p))                return;
    if (bot_adding || clienttype(p) != CLIENTTYPE_REAL) return;

    p.chgsky_want  = sky;
    p.chgsky_armed = 1;
    p.chgsky_sends = 0;
    p.chgsky_next  = time;      // first write on the driver's very next tick

    // Stamp the generation as well, or the driver's SEED pass silently undoes
    // this.  Not theoretical: any client that connected since the last driver
    // tick still reads chgsky_seq 0, so it is "behind the record" even though we
    // just handed it the correct sky.  A spawnflag-1 fire does NOT bump the
    // record and therefore does NOT reach Chgsky_MarkAllSeeded, so within
    // CHGSKY_TICK_IDLE the driver would overwrite this want with
    // changesky_record - the map's ORIGINAL sky - and leave that player on the
    // wrong sky permanently, with nothing left to correct it.  Half a second is
    // a wide window for an entity whose whole job is a scripted cut.
    p.chgsky_seq   = changesky_record_seq;
};

// Mark every current client as already holding the current server record, so
// the driver's seed pass leaves them alone.  Called straight after a record
// bump: whoever was SUPPOSED to see this change has already been given a want
// by the client half, and GoldSrc's sv_skyname does not retroactively re-push
// to players who are already connected (dlls/world.cpp:674-677 - the cvar is
// consumed at connect time).
void() Chgsky_MarkAllSeeded =
{
    entity p;

    p = find(world, classname, "player");
    while (p)
    {
        p.chgsky_seq = changesky_record_seq;
        p = find(p, classname, "player");
    }
};

// Reconcile pass + train delivery.  This is the ONLY place r_skybox is
// written, and it writes for a client only while that client's train is
// unspent - never as a heartbeat.  See the ownership contract in the header.
void() Chgsky_DriverThink =
{
    entity p;
    float  pending;

    pending = 0;

    p = find(world, classname, "player");
    while (p)
    {
        if (!bot_adding && clienttype(p) == CLIENTTYPE_REAL)
        {
            // Seed: a client not yet converged to the current server record.
            // A freshly connected edict reads 0 (ED_Clear on connect,
            // sv_user.c:5572-5590), which is how joiners - and everyone present
            // at map load, against the generation-1 baseline - get picked up
            // without a connect hook.
            if (p.chgsky_seq != changesky_record_seq)
            {
                p.chgsky_seq = changesky_record_seq;
                Chgsky_SetWant(p, changesky_record);
            }

            if (p.chgsky_armed && p.chgsky_sends < CHGSKY_TRAIN_STEPS)
            {
                if (time >= p.chgsky_next)
                {
                    stuffcmd(p, sprintf("r_skybox \"%s\"\n", p.chgsky_want));
                    p.chgsky_sends = p.chgsky_sends + 1;
                    p.chgsky_next  = time + Chgsky_StepDelay(p.chgsky_sends);

                    if (cvar("sv_debug_use"))
                        print(sprintf("[trigger_changesky] %s -> r_skybox \"%s\" (%g/%g)\n",
                                      p.netname, p.chgsky_want,
                                      p.chgsky_sends, CHGSKY_TRAIN_STEPS));
                }
                if (p.chgsky_sends < CHGSKY_TRAIN_STEPS)
                    pending = 1;
            }
        }
        p = find(p, classname, "player");
    }

    if (pending)
        self.nextthink = time + CHGSKY_TICK_BUSY;
    else
        self.nextthink = time + CHGSKY_TICK_IDLE;
};

// Bring the driver up, running the per-map reset first so a map change can
// never inherit the previous map's record or a stale driver edict.  The
// generation-1 baseline established there is what re-bases every client off
// the sky the PREVIOUS map stuffed into their r_skybox.
void() Chgsky_EnsureDriver =
{
    Chgsky_MapInit();

    if (changesky_driver && !wasfreed(changesky_driver))
        return;

    changesky_driver           = spawn();
    changesky_driver.classname = "changesky_driver";
    changesky_driver.think     = Chgsky_DriverThink;
    changesky_driver.nextthink = time + 0.1;
};

// Pull the driver's next tick forward to the next server frame.  Without this
// a scripted swap could sit for a whole CHGSKY_TICK_IDLE (0.5s) before its
// first write, which is visible on a cut like th_ep3_07's.  Deliberately not a
// direct Chgsky_DriverThink() call: that would run with `self` bound to the
// trigger instead of the driver, and the think assigns self.nextthink.
// Only ever reached after Chgsky_EnsureDriver in the same call, so the entity
// it touches is always this map's driver.
void() Chgsky_KickDriver =
{
    if (changesky_driver && !wasfreed(changesky_driver))
        changesky_driver.nextthink = time + 0.01;
};

void() trigger_changesky_use =
{
    entity p;
    float  sf;

    sf = self.spawnflags;

    // server.dll: 'trigger_changesky "%s": Changes not specified at %f %f %f.'
    // Neither key set - the entity has nothing to do.  Latched so a
    // multi_manager firing it on a loop cannot flood the console.
    if (!self.chgsky_hassky && !self.chgsky_hascol)
    {
        if (!self.chgsky_warned)
        {
            self.chgsky_warned = 1;
            print(sprintf("trigger_changesky \"%s\": Changes not specified at %s.\n",
                          self.targetname, vtos(self.origin)));
        }
        return;
    }

    Chgsky_EnsureDriver();

    // ---- client half ----------------------------------------------------
    // Skipped entirely by "No clients" (2), and skipped when the entity only
    // carries a colour: with no skyname key there is no sky to push, and
    // pushing "" would wipe the map's own sky rather than leave it alone.
    if (!(sf & SF_CHANGESKY_NOCLIENTS) && self.chgsky_hassky)
    {
        if (sf & SF_CHANGESKY_ALLPLAYERS)
        {
            // server.dll: 'Changing sky for all players to "%s" RGB %d %d %d.'
            p = find(world, classname, "player");
            while (p)
            {
                Chgsky_SetWant(p, self.chgsky_sky);
                p = find(p, classname, "player");
            }
        }
        else if (activator && !wasfreed(activator) && activator.classname == "player")
        {
            // server.dll: 'Changing sky for one player to "%s" RGB %d %d %d.'
            Chgsky_SetWant(activator, self.chgsky_sky);
        }
        else if (!self.chgsky_warned)
        {
            // server.dll: 'Unable to change the sky, are you using a relay
            // without the spawnflag for updating all players?'  Reached when a
            // relay / multi_manager fires this with spawnflag 1 clear, so there
            // is no player activator to aim at.  A real map bug, so it prints
            // unconditionally - but only once per entity.  Sharing the latch
            // with the "Changes not specified" print above is safe: that branch
            // returns whenever BOTH keys are unset, and this branch is only
            // reachable with chgsky_hassky set, so the two are mutually
            // exclusive for any given entity.
            self.chgsky_warned = 1;
            print(sprintf("trigger_changesky \"%s\": Unable to change the sky, are you using a relay without the spawnflag for updating all players?\n",
                          self.targetname));
        }
    }

    // ---- server half: spawnflag 4 ---------------------------------------
    // GoldSrc writes sv_skyname here (dlls/world.cpp:674-677 sets the same cvar
    // from worldspawn).  Our equivalent is the record the driver seeds NEW
    // clients from.  MarkAllSeeded immediately afterwards keeps that
    // joiners-only: anyone already connected who was meant to see the change
    // has had their want set by the client half above.
    if (sf & SF_CHANGESKY_UPDATESERVER)
    {
        if (self.chgsky_hassky)
        {
            // server.dll: 'Changing server sky name to "%s".'
            changesky_record = self.chgsky_sky;
        }
        if (self.chgsky_hascol)
        {
            // server.dll: 'Changing server sky color to RGB %d %d %d.'
            // Recorded only - see the `color` note in the QUAKED block below.
            changesky_color     = self.color;
            changesky_color_set = 1;
        }
        changesky_record_seq = changesky_record_seq + 1;
        Chgsky_MarkAllSeeded();
    }

    Chgsky_KickDriver();

    if (cvar("sv_debug_use"))
        print(sprintf("[trigger_changesky] \"%s\" fired: sky=\"%s\" col=%s sf=%g\n",
                      self.targetname, self.chgsky_sky,
                      vtos(self.color), sf));
};

/*QUAKED trigger_changesky (.6 .75 1) (-8 -8 -8) (8 8 8) ALL_PLAYERS NO_CLIENTS UPDATE_SERVER
Swaps the skybox when fired.  Sven Co-op only - no Half-Life equivalent.

"targetname"  name.  This entity is a pure sink: the FGD gives it no target,
              no delay and no master (sven-coop.fgd:279-282), so it fires no chain.
"skyname"     GoldSrc sky prefix, e.g. "2VS" -> gfx/env/2VS{rt,lf,bk,ft,up,dn}
"color"       sky-light colour "R G B", 0..255 each.  RECORDED ONLY - FTE has no
              per-client equivalent of GoldSrc's sv_skycolor_r/g/b, and the
              nearest in-tree cvars (env_sun's r_shadows_color_*, sv_env_sun.qc:
              160-165) mean a SHADOW TINT, not a sky colour, so driving them from
              here would be a different effect wearing the same name.  "0 0 0" is
              treated as "key absent" - QC cannot see key presence, the same
              compromise game_counter documents for its own default.

ALL_PLAYERS (1):   broadcast.  WITHOUT it the change goes to the ACTIVATOR only,
                   and firing from a relay / multi_manager (which carries no
                   player activator) is an error - Sven prints "are you using a
                   relay without the spawnflag for updating all players?", so do we.
NO_CLIENTS (2):    suppress the client half; only the server record changes.
UPDATE_SERVER (4): also make this the sky handed to players who JOIN LATER
                   (GoldSrc's sv_skyname).  Not retroactive on its own.

th_ep3_07's "th55_chgsky" is spawnflags 5 = ALL_PLAYERS | UPDATE_SERVER,
skyname "2VS", fired by the multi_manager "escape_mm".
*/
void() trigger_changesky =
{
    // strzone rather than aliasing self.skyname directly: the want is parked on
    // PLAYER edicts for as long as the map runs, and a zoned copy makes that
    // lifetime unconditional.  Never freed - one string per trigger_changesky,
    // and there is exactly one in the whole campaign.  Same call and same
    // never-freed rationale as scripted_sentence's speaker
    // (sv_multi_manager.qc:588-593).  Scrubbed first: see Chgsky_SafeName.
    if (self.skyname != "" && self.skyname != __NULL__)
    {
        self.chgsky_sky    = strzone(Chgsky_SafeName(self.skyname));
        self.chgsky_hassky = 1;
    }

    // '0 0 0' == "no colour key".  See the QUAKED block above.
    if (self.color != '0 0 0')
        self.chgsky_hascol = 1;

    // server.dll: 'trigger_changesky "%s": Sky not specified at %f %f %f.'
    if (!self.chgsky_hassky && self.chgsky_hascol)
        print(sprintf("trigger_changesky \"%s\": Sky not specified at %s.\n",
                      self.targetname, vtos(self.origin)));

    // Spawn the driver now, not at first use: its generation-1 baseline is what
    // re-bases every client off the sky the PREVIOUS map stuffed into their
    // r_skybox.  See the LATE JOINERS note in the header above.
    Chgsky_EnsureDriver();

    self.use      = trigger_changesky_use;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};

// ============================================================
//  func_tankrocket
//  SDK (C:/msys64/home/Lex/halflife/dlls/):
//  - func_tank.cpp:883-918 — CFuncTankRocket: Precache (UTIL_PrecacheOther "rpg_rocket") and Fire (CBas
//  - func_tank.cpp:24-31 — SF_TANK_ACTIVE 1 / PLAYER 2 / HUMANS 4 / ALIENS 8 / LINEOFSIGHT 16 / CANCONT
//  - func_tank.cpp:66-67 — TankActivate/TankDeactivate clear m_fireLast; :67 CanFire() = (time - m_last
//  - func_tank.cpp:176-200 — Spawn: m_yawCenter/m_pitchCenter from angles, `if (m_fireRate <= 0) m_fire
//  - func_tank.cpp:214-320 — KeyValue: yawrate/yawrange/yawtolerance/pitchrate/pitchrange/pitchtoleranc
// ============================================================

// ---------------------------------------------------------------------------
//  func_tankrocket  —  GoldSrc / Sven Co-op brush rocket turret
// ---------------------------------------------------------------------------
//  dlls/func_tank.cpp:882-918, CFuncTankRocket.  It is CFuncTank with exactly
//  one method replaced: instead of FireBullets it creates an "rpg_rocket" at
//  BarrelPosition() carrying the TANK's angles, with the tank as owner
//  (func_tank.cpp:911).  Everything else — the keyvalues, the spawnflags, the
//  tracking loop, the fire cadence, the firing of `target` on every volley — is
//  inherited from CFuncTank, so most of this file is that base class.
//
//  WHY THIS IS NOT SIMPLY func_tank WITH A DIFFERENT SHOT.  The in-tree
//  func_tank (server/sv_goldsrc_compat.qc:1387) implements ONLY the
//  player-mounted case and says so in its own header: "The tank does NOT
//  auto-target monsters here".  That is a fair call for its single placement.
//  It is not a fair call here — in the Sven map corpus, seven of the eight
//  func_tankrocket entities are unmanned turrets (keys read out of the BSP
//  entity lumps on the Sven mount):
//
//    crystal2   "tower_turret"    sf 0     yaw 180/1000  pitch 180/1000  fr 0.2  no barrel key
//    th_ep2_00  "rpg"             sf 0     yaw  80/120   pitch  45/60    fr 1    barrel 30
//    toonrun1   "antrpg"          sf 32    yaw  45/500   pitch  15/500   fr 1    barrel 66
//    hl_c07_a2  "trackguardrocket"   x2, sf 3, yaw 30/20, NO pitchrange, barrel 52
//    hl_c11_a2  "brad_turret"     sf 3     yaw 360/20    barrel 116 barrely -48 maxRange 2600
//    uplink     "missile_turret"  sf 3     yaw 180/30    pitch 45/30     barrel 52
//    suspension "s7_apc_turret"   sf 1025  yaw 180/40    pitch  8/40     barrel 15 barrely -64 barrelz 4
//
//  A mount-only implementation leaves six of them inert.  So this file carries
//  CFuncTank::TrackTarget's acquire / slew / fire loop (func_tank.cpp:484-620)
//  as well, and hands the mounted case straight back to func_tank's own
//  tank_think so a rocket tank and a gun tank steer identically.
//
//  Note also that th_ep2_00 flips its tank's spawnflags to 32 at runtime with a
//  trigger_changevalue (server/sv_trigger_copyvalue.qc:214), so nothing here may
//  cache spawnflags at spawn time — every gate reads self.spawnflags live.
//
//  ALREADY DECLARED, DO NOT REDECLARE: sv_goldsrc_compat.qc:1226-1249 owns
//  .bullet .bullet_damage .firerate .barrel .yawrange .yawrate .yawtolerance
//  .pitchrange .pitchrate .pitchtolerance .persistence .spritescale
//  .tank_controller .tank_link .tank_next_fire .tank_base_angles
//  .tank_err_yaw .tank_err_pitch and TANK_SF_CANCONTROL / TANK_THINK_IV.
//  sv_doors.qc:68 / sv_triggers.qc:31 own .string master.
// ---------------------------------------------------------------------------

// Spawnflag bits, func_tank.cpp:24-31 plus the two Sven additions from the FGD
// (sven-coop.fgd:1010-1017).  Prefixed because TANK_SF_CANCONTROL is the only
// one sv_goldsrc_compat.qc declares and a const cannot be defined twice.
const float TANKROCKET_SF_ACTIVE       = 1;      // "Active"
const float TANKROCKET_SF_LINEOFSIGHT  = 16;     // "Only Direct"
const float TANKROCKET_SF_NOPLAYERFIRE = 1024;   // Sven "Player can't fire"

// CFuncTank::TrackTarget reschedules an unmanned but active tank at 0.1 s
// (func_tank.cpp:503).  The manned case is func_tank's own TANK_THINK_IV, set
// by tank_think itself.
const float TANKROCKET_TRACK_IV = 0.1;

const float TANKROCKET_RAD2DEG = 57.2957795;

// Mapper keys the sibling never needed.  barrely / barrelz complete
// BarrelPosition (func_tank.cpp:196-201 inline) and are live in the corpus —
// hl_c11_a2's brad_turret sets barrely -48, suspension's APC turret barrely -64
// and barrelz 4.  minRange / maxRange are CFuncTank::InRange
// (func_tank.cpp:459-467); hl_c11_a2 sets maxRange 2600.  Declared so the BSP
// entity parser populates them, the same way sv_env_explosion.qc:37 declares
// .iMagnitude.  CASING IS LOAD-BEARING: the BSP keys really are spelled
// "minRange"/"maxRange" and ED_FindField is case-sensitive — the same trap
// sv_env_beam.qc:75-79 documents.
.float barrely;
.float barrelz;
.float minRange;
.float maxRange;

// Per-turret tracking state.  m_lastSightTime / m_sightOrigin, func_tank.cpp:127
// and :112.  tankrocket_have_sight exists because '0 0 0' is a legal map
// coordinate and "never acquired anything" has to be distinguishable from it.
.float  tankrocket_last_sight;
.vector tankrocket_sight_origin;
.float  tankrocket_have_sight;

// Set on the ROCKET, not the tank: who to bill the kill to.  HL makes the tank
// itself the attacker (the rocket's pev->owner, func_tank.cpp:911), which in
// this tree would surface in the kill feed as KILLFEED_NO_ATTACKER
// (sv_weapons.qc:1290).  The sibling already credits the operator instead
// (sv_goldsrc_compat.qc:1272 passes the mounted player to W_ApplyDamage), so a
// player-fired rocket does the same here.  Stays world for an unmanned turret.
.entity tankrocket_operator;

// ---------------------------------------------------------------------------
//  Geometry
// ---------------------------------------------------------------------------

// The pivot.  A brush entity compiled WITHOUT an origin brush has origin
// (0 0 0) and its geometry only in absmin/absmax — the same fact that forced
// W_RadiusExplode to grow its own brushmodel scan (sh_weapon_standard.qc:759).
// All eight corpus entities do carry an origin key, so this is belt and braces;
// but the sibling reads self.origin raw, and launching a live rocket from the
// map origin is a good deal worse than tracing a hitscan from there.
vector() TankRocket_Base =
{
    if (self.origin != '0 0 0')
        return self.origin;
    return (self.absmin + self.absmax) * 0.5;
};

// func_tank.cpp:196-201, BarrelPosition(): origin + forward*barrel +
// right*barrely + up*barrelz.
//
// LEAVES v_forward / v_right / v_up SET FROM self.angles — callers rely on
// that instead of calling makevectors a second time.
vector() TankRocket_BarrelPosition =
{
    makevectors(self.angles);
    return TankRocket_Base()
           + v_forward * self.barrel
           + v_right   * self.barrely
           + v_up      * self.barrelz;
};

// func_tank.cpp:838-857, AdjustAnglesForBarrel().  With the muzzle offset off
// the pivot the gun has to lead slightly so that the MUZZLE, not the pivot,
// ends up pointing at the target.  Transcribed in HL's UTIL_VecToAngles
// convention (+pitch = UP, pm_math.c VectorAngles) because that is the
// convention the SDK applies it in — the caller negates pitch afterwards.
//
// The d2 > r2 guards are ours: HL feeds sqrt() a negative the moment the target
// is closer to the pivot than the barrel is long, and NaN angles on a brush
// entity do not recover.
vector(vector ang, float dist) TankRocket_AdjustAnglesForBarrel =
{
    float r2;
    float d2;

    if (self.barrely == 0 && self.barrelz == 0)
        return ang;

    dist = dist - self.barrelz;
    d2   = dist * dist;

    if (self.barrely != 0)
    {
        r2 = self.barrely * self.barrely;
        if (d2 > r2)
            ang_y = ang_y + TANKROCKET_RAD2DEG * atan2(self.barrely, sqrt(d2 - r2));
    }
    if (self.barrelz != 0)
    {
        r2 = self.barrelz * self.barrelz;
        if (d2 > r2)
            ang_x = ang_x + TANKROCKET_RAD2DEG * atan2(0 - self.barrelz, sqrt(d2 - r2));
    }
    return ang;
};

// ---------------------------------------------------------------------------
//  The rocket
// ---------------------------------------------------------------------------

// NOT W_RPGExplode (sh_wpn_hlrpg.qc:325).  That one narrows dimension_send by
// the OWNER's dimension_seen to hide the boom from the shooter, who is covered
// by a CSQC-predicted fake.  Our owner is a BRUSH, and a non-player edict keeps
// the engine default dimension_seen of 255 (pr_cmds.c:243 assigns
// dimension_default; only PutClientInServer overrides it, sv_player.qc:3545) —
// so `dimension_send & ~255` is 0 and the explosion would be sent to NOBODY.
// There is no predicted fake for a turret-launched rocket either way.
//
// CSQC_EVENT_ENV_EXPLOSION has no owner-exclude at all and carries the whole
// GoldSrc explosion (fireball + smoke + scorch decal + sparks + boom), which is
// what CGrenade::Explode gives an rpg_rocket (rpg.cpp:180-184).  Wire format
// and the 17-byte budget are fixed by cl_main.qc:1904 — do not add fields.
void() TankRocket_RocketExplode =
{
    entity atk;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_EXPLOSION);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 8);
    WriteShort(MSG_MULTICAST, RPG_EXPLOSION_DAMAGE);
    // Spawnflag byte is env_explosion's element mask (EE_NO_FIREBALL etc,
    // cl_env_explosion.qc:26-31).  ZERO, deliberately: passing the TANK's
    // spawnflags through would read bit 16 as NO_DECAL on every "Only Direct"
    // turret and bit 4 as NO_FIREBALL on nothing in particular.
    WriteByte(MSG_MULTICAST, 0);
    multicast(self.origin, MULTICAST_PVS);

    // Kill the SOUNDFLAG_FOLLOW motor loop on the channel that owns it, the
    // same way sh_wpn_hlrpg.qc:349 and sv_physprop.qc:686 cancel their loops.
    sound(self, CHAN_VOICE, "sounds/null.wav", 1, ATTN_NORM);

    // An operator who disconnected mid-flight leaves a recycled edict behind,
    // so re-verify rather than trust the stored reference.  world is what
    // env_explosion passes for an unattributed map blast
    // (sv_env_explosion.qc:74) and is the proven argument here.
    atk = self.tankrocket_operator;
    if (atk.classname != "player")
        atk = world;

    W_RadiusExplode(self.origin, RPG_EXPLOSION_RADIUS,
                    RPG_EXPLOSION_DAMAGE, RPG_EXPLOSION_MIN_DAMAGE,
                    RPG_KNOCKBACK_PUSH, RPG_KNOCKBACK_UPLIFT, atk);

    remove(self);
};

void() TankRocket_RocketTouch =
{
    // Same guard as W_RPGRocketTouch (sh_wpn_hlrpg.qc:361).  Belt and braces:
    // the engine already skips owner/ownee pairs in SV_ClipToLinks, so a rocket
    // launched from inside its own tank's brush passes out through it — which is
    // exactly what HL relies on for a tank with no `barrel` key at all, and why
    // this file does NOT invent a barrel default (see func_tankrocket below).
    if (other == self.owner)
        return;
    TankRocket_RocketExplode();
};

// One rocket out of the tube.  CFuncTankRocket::Fire (func_tank.cpp:911) does
// CBaseEntity::Create("rpg_rocket", barrelEnd, pev->angles, edict()); we build
// the same projectile the RPG builds (sh_wpn_hlrpg.qc:411-460) so it flies,
// trails, renders and networks identically to a player's rocket.
//
// DIVERGENCE, ON PURPOSE: CRpgRocket::Spawn (rpg.cpp:139-141) tips the launch
// vector up 30 degrees and idles on MOVETYPE_BOUNCE for 0.4 s before IgniteThink
// lights the motor, so a real HL tank rocket visibly lobs.  This tree's rocket
// has no ignition delay and no bounce phase; reproducing the lob would mean a
// second rocket entity that behaves unlike every other rocket in the mod.  One
// rocket implementation, launched straight down the barrel.
//
// W_RPGRocketThink is REUSED as-is rather than copied: its laser-guidance branch
// is gated on self.owner.rpg_laser_active, and a brush never sets that, so an
// unowned-by-a-player rocket falls straight through to the acceleration path —
// which is what CRpgRocket::FollowThink does with no laser_spot in the map.
void(entity operator, vector barrel_end, vector fwd) TankRocket_Launch =
{
    entity rocket;

    rocket = spawn();
    // The TANK, per func_tank.cpp:911 — this is what buys the pass-through
    // above.  Damage credit rides on .tankrocket_operator instead.
    rocket.owner     = self;
    rocket.classname = "proj_rpg_rocket";
    rocket.movetype  = MOVETYPE_FLYMISSILE;
    rocket.solid     = SOLID_BBOX;
    setmodel(rocket, RPG_ROCKET_MODEL);
    setsize(rocket, '-2 -2 -2', '2 2 2');
    setorigin(rocket, barrel_end);
    rocket.velocity  = fwd * RPG_INITIAL_SPEED;      // rpg.cpp:144
    rocket.angles    = W_ModelAngles(rocket.velocity, TRUE);  // IDST — pitch negated
    rocket.tankrocket_operator = operator;
    rocket.touch     = TankRocket_RocketTouch;
    // CSQC replication + the smoke trail keyed off proj_type in
    // cl_throwtrail.qc.  projectile_SendEntity hides the rocket from its owner
    // (sv_weapons.qc:2594); the owner here is a brush, so every player —
    // including the operator, who has no predicted fake — actually sees it.
    rocket.proj_type  = PROJ_TYPE_RPG_ROCKET;
    rocket.SendEntity = projectile_SendEntity;
    rocket.SendFlags  = 1;
    rocket.think      = W_RPGRocketThink;
    rocket.nextthink  = time + Toss_NextThinkInterval();

    // Broadcast, not unicast-minus-shooter as W_RPGFire does: nobody is
    // predicting this one locally, so everyone in earshot gets the real motor.
    sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0, SOUNDFLAG_FOLLOW);
};

// HL counts (time - m_fireLast) * m_fireRate rockets per Fire() and only
// launches once that reaches 1 (func_tank.cpp:903-907), which is a cooldown of
// 1/firerate.  Losing the firing solution sets m_fireLast = 0, and the next
// Fire() with m_fireLast == 0 launches NOTHING — it only restarts the clock
// (func_tank.cpp:915) — so re-acquiring costs a fresh full interval before the
// first rocket.  This is the reset half of that.
void() TankRocket_ResetBurst =
{
    float rate;

    rate = self.firerate;
    if (rate <= 0)
        rate = 1;
    self.tank_next_fire = time + 1.0 / rate;
};

// ---------------------------------------------------------------------------
//  The other two CFuncTank subclasses — func_tankmortar and func_tanklaser
//
//  CFuncTankMortar (func_tank.cpp:920-963) and CFuncTankLaser (:775-884) are the
//  same class as CFuncTankRocket: everything above — the arc, the slew, the
//  acquire, the tolerance gate, the mount — is CFuncTank and is already written.
//  Each subclass overrides ONE virtual, Fire(), and nothing else.  So they are
//  branches inside TankRocket_Fire below rather than parallel copies of 400
//  lines that would drift apart the first time one of them is touched.
//
//  THE `TankRocket_` PREFIX ON THE SHARED HALF IS THE FAMILY'S, NOT THE
//  ROCKET'S.  It was named when the rocket was the only subclass here; renaming
//  it now would churn every comment above that cites a func_tank.cpp line.
//  TankRocket_Track / _Fire / _FindTarget / _BarrelPosition are CFuncTank.
//  Only TankRocket_Launch, TankMortar_FireShot and TankLaser_FireShot are
//  per-subclass.
// ---------------------------------------------------------------------------
const float TANKVAR_ROCKET = 0;
const float TANKVAR_MORTAR = 1;
const float TANKVAR_LASER  = 2;

.float tank_variant;

// m_spread, the index into gTankSpread (func_tank.cpp:166-173).  The BSP key is
// spelled `firespread`, and the corpus really sets it: every func_tankmortar on
// hl_c11_* carries 2 or 3, and hl_c14's four flower turrets carry 3.
.float firespread;

// m_iszSpriteFlash / m_iszSpriteSmoke (func_tank.cpp:145-146), the muzzle
// visual CFuncTank::Fire spawns for EVERY subclass — so wiring it here also
// gives the already-shipping func_tankrocket a muzzle flash it never had.
.string spriteflash;
.string spritesmoke;

// CFuncTankLaser's m_pLaser / m_laserTime (func_tank.cpp:770-771).  The `message`
// key HL overloads for the laser's name is already spoken for in this tree
// (env_message, game_text, speaker), so the BSP key is read under its FGD
// spelling instead — `laserentity`, which is what all five corpus entities set.
.string laserentity;
.entity tanklaser_beam;
.float  tanklaser_off_time;

// gTankSpread, func_tank.cpp:166-173.  Returned rather than tabled: QC has no
// static array initialiser and five floats do not earn a spawn-time build.
float(float idx) Tank_SpreadFor =
{
    if (idx <= 0) return 0;         // perfect
    if (idx == 1) return 0.025;     // small cone
    if (idx == 2) return 0.05;      // medium cone
    if (idx == 3) return 0.1;       // large cone
    return 0.25;                    // extra-large cone
};

// CFuncTank::TankTrace, func_tank.cpp:680-696.  Leaves the trace_* globals set,
// exactly like the traceline it wraps.
//
// REQUIRES v_right / v_up TO ALREADY DESCRIBE self.angles — every caller here
// reaches this immediately after TankRocket_BarrelPosition(), which documents
// that it leaves them set.  Calling makevectors again would be free, but the
// SDK's own comment at :683 ("TankTrace needs gpGlobals->v_up, etc.") records
// the same contract and keeping it makes the two readable side by side.
//
// The SDK's rejection sampler is a do/while; QC has neither do/while nor any
// guarantee the loop terminates, so it is a bounded for with the last sample
// taken as-is.  Sixteen tries fail together with probability (1-pi/4)^16, about
// 1 in 2.6 billion, and the fallback is a corner of the square rather than the
// disc — i.e. very slightly wider, never invalid.
void(vector start, vector fwd, float spread) Tank_SpreadTrace =
{
    float  i;
    float  x;
    float  y;
    vector dir;

    x = 0;
    y = 0;
    for (i = 0; i < 16; i = i + 1)
    {
        x = (random() - 0.5) + (random() - 0.5);
        y = (random() - 0.5) + (random() - 0.5);
        if (x * x + y * y <= 1)
            i = 16;         // accepted — leave the loop with this sample
    }

    dir = fwd + v_right * (x * spread) + v_up * (y * spread);
    traceline(start, start + dir * 4096, MOVE_NORMAL, self);
};

// CFuncTank::Fire's muzzle sprites, func_tank.cpp:660-672.  SpriteCreate at the
// barrel end, additive, scaled by m_iSpriteScale, then AnimateAndDie(60) for the
// flash and a slow fade for the smoke.
//
// Server-side entities rather than a CSQC event: these are ordinary sprites at a
// fixed point for a tenth of a second, the same shape env_sprite already
// replicates, and inventing a wire event for them would buy nothing.  The frame
// does not animate — FTE's client owns the playback clock for a model's frames
// but a server sprite entity holds whatever .frame it is given, and a 3-frame
// muzzleflash at 60 fps is gone in 0.05 s anyway.
// `sz` rather than `scale`: QC keeps fields and locals in ONE namespace, so a
// parameter called `scale` shadows the engine's .scale field and s.scale below
// stops compiling ("scale is not a field").  Same trap as the mark/plantpos
// rename in sv_ai_core.qc.
void(string path, vector pos, float sz, float life) Tank_MuzzleSprite =
{
    entity s;

    if (path == "" || !path)
        return;

    s = spawn();
    s.classname = "tank_muzzle_sprite";
    s.movetype  = MOVETYPE_NONE;
    s.solid     = SOLID_NOT;
    setorigin(s, pos);
    setmodel(s, path);
    s.effects   = s.effects | EF_ADDITIVE;
    s.scale     = (sz > 0) ? sz : 1;
    s.think     = SUB_Remove;
    s.nextthink = time + life;
};

// ExplosionCreate(center, angles, owner, magnitude, TRUE), util.cpp — the same
// call env_explosion makes, so the scaling has to be the same scaling.  Lifted
// from env_explosion_fire (sv_env_explosion.qc:55-77) rather than re-derived:
// magnitude 100 must keep meaning "one HE grenade" wherever it is written.
void(vector pos, float magnitude, entity attacker) HL_ExplosionCreate =
{
    if (magnitude <= 0)
        magnitude = 100;            // ExplosionCreate's own default

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_EXPLOSION);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteShort(MSG_MULTICAST, magnitude);
    WriteByte(MSG_MULTICAST, 0);    // element mask: the full GoldSrc boom
    multicast(pos, MULTICAST_PVS);

    W_RadiusExplode(pos, magnitude * 2.6, magnitude, magnitude * 0.25,
                    800, 350, attacker);
};

// CFuncTankMortar::Fire, func_tank.cpp:942-963.  One explosion where the traced
// shot lands, and pev->impulse is the iMagnitude key.
void(entity operator, vector barrel_end, vector fwd) TankMortar_FireShot =
{
    entity atk;

    Tank_SpreadTrace(barrel_end, fwd, Tank_SpreadFor(self.firespread));

    // Same attribution split the rocket documents at :1920-1926: HL bills the
    // tank, this tree bills the operator so the kill feed has a name in it.
    atk = operator;
    if (atk.classname != "player")
        atk = world;

    HL_ExplosionCreate(trace_endpos, self.iMagnitude, atk);
};

// CLaser::FireAtPoint (effects.cpp) driven from the tank, func_tank.cpp:851-869.
//
// NOTE WHAT THIS DOES *NOT* DO: it never reads the env_laser's own LaserTarget.
// A tank laser overrides both endpoints — origin := barrel end, endpos := the
// tank's traced hit — and sets nextthink = 0 so the laser's own EnvLaser_Tick
// never re-aims it.  That matters on the live maps, because all five corpus
// lasers set LaserTarget "player", which names no entity at all: left to
// EnvLaser_AimAndDamage they would each point 64 units straight down.
void(entity laser, vector start, entity attacker) TankLaser_FireAtPoint =
{
    entity oself;
    entity hit;

    hit = trace_ent;

    oself = self;
    self  = laser;

    self.ebeam_active    = 1;
    self.ebeam_start_pos = start;
    self.ebeam_end_pos   = trace_endpos;
    self.nextthink       = 0;
    EnvBeam_MarkDirty();

    self = oself;

    // CBeam::BeamDamage bills pev->dmg * (time - dmgtime), and CFuncTankLaser
    // parks dmgtime a full second in the past before every pulse
    // (func_tank.cpp:864) — so a tank pulse is worth exactly the laser's whole
    // `damage` key, not the 0.1 s slice EnvLaser_AimAndDamage applies to a
    // free-running beam.
    //
    // Billed to the operator when there is one, same split as the mortar and
    // the rocket: HL names the beam as the inflictor, which would surface here
    // as an unattributed kill.
    if (attacker.classname != "player")
        attacker = laser;
    if (laser.damage > 0 && hit && hit != world)
        W_ApplyDamage(attacker, hit, laser.damage);
};

void(entity operator, vector barrel_end, vector fwd) TankLaser_FireShot =
{
    entity beam;

    // GetLaser(), func_tank.cpp:818-840.  Resolved lazily and cached: the
    // env_laser may be spawned after the tank, and find() over a name the mapper
    // typed once is not worth repeating at the fire rate.
    beam = self.tanklaser_beam;
    if (!beam)
    {
        beam = find(world, targetname, self.laserentity);
        while (beam && beam.classname != "env_laser")
            beam = find(beam, targetname, self.laserentity);
        if (!beam)
            return;                 // HL removes the tank; see func_tanklaser
        self.tanklaser_beam = beam;
    }

    Tank_SpreadTrace(barrel_end, fwd, Tank_SpreadFor(self.firespread));
    TankLaser_FireAtPoint(beam, barrel_end, operator);

    // m_laserTime = gpGlobals->time (func_tank.cpp:863).  CFuncTankLaser::Think
    // turns the beam off on the first tick where time has moved past it, so the
    // beam is a per-shot FLASH, not a sustained ray.
    self.tanklaser_off_time = time;
};

void(entity operator) TankRocket_Fire =
{
    float  rate;
    vector barrel_end;
    vector fwd;
    entity act;

    if (time < self.tank_next_fire)
        return;

    rate = self.firerate;
    if (rate <= 0)
        rate = 1;                       // func_tank.cpp:194 and FGD line 1035
    self.tank_next_fire = time + 1.0 / rate;

    barrel_end = TankRocket_BarrelPosition();   // leaves v_forward on self.angles
    fwd        = v_forward;

    // AIM DOWN THE BARREL, never down the operator's view.  Same reasoning the
    // sibling records at sv_goldsrc_compat.qc:1271-1277: tank_think clamps the
    // barrel to yawrange/pitchrange, so on any tank with an arc limit a shot
    // fired along v_angle leaves the visible arc.
    //
    // The subclass override, func_tank.cpp:911 / :942 / :851.  Everything
    // around it — the cooldown, the barrel solve, the target fire below — is
    // CFuncTank and is shared by all three.
    if (self.tank_variant == TANKVAR_MORTAR)
        TankMortar_FireShot(operator, barrel_end, fwd);
    else if (self.tank_variant == TANKVAR_LASER)
        TankLaser_FireShot(operator, barrel_end, fwd);
    else
        TankRocket_Launch(operator, barrel_end, fwd);

    // CFuncTank::Fire's muzzle sprites, func_tank.cpp:660-672.  Every subclass
    // gets these — the SDK spawns them in the base class before dispatching —
    // so func_tankrocket picks them up here too.  m_iSpriteScale is `spritescale`
    // and is already declared by the sibling; HL defaults it to 1
    // (func_tank.cpp:191).
    Tank_MuzzleSprite(self.spriteflash, barrel_end, self.spritescale, 0.1);
    Tank_MuzzleSprite(self.spritesmoke, barrel_end, self.spritescale, 0.5);

    // CFuncTank::Fire (func_tank.cpp:674) fires the tank's targets on EVERY
    // volley, and the corpus depends on it: hl_c07_a2 targets
    // "trackguardrocketsound", hl_c11_a2 "rocket_wav", th_ep2_00 "launch" and
    // toonrun1 "antrpg_s", each an ambient_generic holding a launch wav.  That
    // is where the launch report comes from — which is why nothing here plays
    // one.
    //
    // HL's activator is the tank itself (`SUB_UseTargets( this, ... )`); an
    // unmanned turret keeps that, but a manned one passes the operator so the
    // activator-aware entities in this tree (trigger_relay, game_counter,
    // trigger_changetarget) see a player rather than a brush.
    act = operator;
    if (act == world)
        act = self;
    if (self.target != "")
        SUB_UseTargets(self, act, USE_TOGGLE);
};

// ---------------------------------------------------------------------------
//  Unmanned tracking — CFuncTank::TrackTarget, func_tank.cpp:484-620
// ---------------------------------------------------------------------------

// HL's FindTarget is FIND_CLIENT_IN_PVS (func_tank.cpp:486) — base Half-Life
// tanks only ever shoot players, and never read SF_TANK_PLAYER / HUMANS /
// ALIENS at all.  Walking player_chain (sv_customdefs.qc:704) instead of
// checkclient() is both cheaper to reason about and immune to checkclient's
// dependence on self.origin, which a brush without an origin brush does not
// have.  Nearest visible living player wins.
//
// The LOS trace and the range test both run against the target's EYE
// (origin + view_ofs), which is what func_tank.cpp:517-519 measures; the point
// we then AIM at is the body centre, which is what UpdateTargetPosition ->
// BodyTarget -> Center() returns (cbase.h).
entity(vector barrel_end) TankRocket_FindTarget =
{
    entity c;
    entity best;
    float  bestdist;
    float  range;
    vector eye;

    best     = world;
    bestdist = 0;

    c = player_chain_head;
    while (c)
    {
        // SOLID_NOT covers spectators and the pre-team-pick idle state, which
        // sv_player.qc parks at SOLID_NOT rather than flagging separately.
        if (c.health > 0 && c.solid != SOLID_NOT)
        {
            eye   = c.origin + c.view_ofs;
            range = vlen(eye - barrel_end);

            // InRange(), func_tank.cpp:459-467.  maxRange 0 means unbounded.
            if (range >= self.minRange
                && (self.maxRange <= 0 || range <= self.maxRange))
            {
                traceline(barrel_end, eye, MOVE_NORMAL, self);
                if (trace_fraction == 1 || trace_ent == c)
                {
                    if (best == world || range < bestdist)
                    {
                        best     = c;
                        bestdist = range;
                    }
                }
            }
        }
        c = c.player_chain_next;
    }
    return best;
};

void() TankRocket_Track =
{
    entity targ;
    vector barrel_end;
    vector dir;
    vector want;
    float  yaw_off;
    float  pitch_off;
    float  dist_y;
    float  dist_x;
    float  update_sight;
    float  tol_ok;
    float  los_ok;

    barrel_end   = TankRocket_BarrelPosition();
    targ         = TankRocket_FindTarget(barrel_end);
    update_sight = FALSE;

    if (targ != world)
    {
        // m_sightOrigin is updated the moment we see them (func_tank.cpp:539);
        // m_lastSightTime is NOT — that is deferred past the yaw clamp below.
        self.tankrocket_sight_origin = (targ.absmin + targ.absmax) * 0.5;
        self.tankrocket_have_sight   = TRUE;
        update_sight                 = TRUE;
    }

    // Never seen anyone: sit still.  Zeroing avelocity is not cosmetic — the
    // engine integrates it for a MOVETYPE_PUSH brush (sv_phys.c WPhys_PushMove,
    // amove = avelocity * movetime) and cl_brushsync.qc:199 integrates the same
    // value again client-side, so a stale value sails the barrel away on both
    // ends.  Only dirty the entity when the value actually changed, or an idle
    // active turret resends its whole brush header at 10 Hz forever.
    if (!self.tankrocket_have_sight)
    {
        if (self.avelocity != '0 0 0')
        {
            self.avelocity = '0 0 0';
            self.SendFlags = 1;
        }
        return;
    }

    // func_tank.cpp:544-546 aims from the PIVOT, not the muzzle, and the SDK
    // leaves a comment saying so.  Kept, because the barrel lead is applied
    // separately just below.
    dir = self.tankrocket_sight_origin - TankRocket_Base();
    if (dir == '0 0 0')
        dir = '1 0 0';

    // HL's UTIL_VecToAngles convention: +pitch = UP (pm_math.c VectorAngles).
    // Spelled out with atan2 rather than the vectoangles builtin on purpose —
    // FTE's vectoangles runs its pitch through r_meshpitch (mathlib.c:334-338),
    // so whether it hands back +up or +down is a client cvar's business, not
    // something to build a turret on.  sv_ai_combat.qc:613 does the same.
    want_x = atan2(dir_z, sqrt(dir_x * dir_x + dir_y * dir_y)) * TANKROCKET_RAD2DEG;
    want_y = atan2(dir_y, dir_x) * TANKROCKET_RAD2DEG;
    want_z = 0;

    want = TankRocket_AdjustAnglesForBarrel(want, vlen(dir));

    // func_tank.cpp:564 — flip into the engine/makevectors convention
    // (+pitch = DOWN), which is what self.angles must hold for tank_fire's and
    // TankRocket_Fire's makevectors(self.angles) to aim down the barrel.
    want_x = 0 - want_x;

    // Fold relative to the mapper's centre, then clamp to the arc
    // (func_tank.cpp:567-608).
    //
    // RANGE 0 MEANS LOCKED HERE, NOT FREE, and that is a deliberate split from
    // the sibling.  sv_goldsrc_compat.qc:1310-1311 reads 0 as "no limit", which
    // is right for a gun a player is holding; but the SDK clamps to
    // centre +/- range unconditionally (the member comment at func_tank.cpp:102
    // claims "Zero is full rotation" and the code at :571-585 does not honour
    // it) and the FGD's own default for pitchrange is 0 (sven-coop.fgd:1026).
    // hl_c07_a2's two turrets omit pitchrange precisely to get a launcher that
    // only traverses — treating that as "free pitch" would have them tipping
    // down at the player.
    yaw_off   = anglemod(want_y - self.tank_base_angles_y + 180) - 180;
    pitch_off = anglemod(want_x - self.tank_base_angles_x + 180) - 180;

    // THE YAW CLAMP ALSO CANCELS THE SIGHTING, func_tank.cpp:574 and :580:
    // "Don't update if you saw the player, but out of range".  Without this the
    // barrel parks on the arc limit, the residual error falls inside
    // yawtolerance, CanFire() never expires, and the turret dumps rockets into
    // the wall forever at a player it physically cannot point at.  Live in the
    // corpus: hl_c07_a2's pair have yawrange 30 and no LINEOFSIGHT bit to save
    // them, and toonrun1 / th_ep2_00 are barely wider.  The PITCH clamp does
    // NOT cancel it — the SDK only guards yaw (:604-608 has no updateTime
    // write) — so this is asymmetric on purpose.
    if (yaw_off > self.yawrange)
    {
        yaw_off      = self.yawrange;
        update_sight = FALSE;
    }
    else if (yaw_off < 0 - self.yawrange)
    {
        yaw_off      = 0 - self.yawrange;
        update_sight = FALSE;
    }
    pitch_off = bound(0 - self.pitchrange, pitch_off, self.pitchrange);

    want_y = self.tank_base_angles_y + yaw_off;
    want_x = self.tank_base_angles_x + pitch_off;

    if (update_sight)
        self.tankrocket_last_sight = time;      // func_tank.cpp:592

    dist_y = anglemod(want_y - self.angles_y + 180) - 180;
    dist_x = anglemod(want_x - self.angles_x + 180) - 180;

    // func_tank.cpp:595-613: avelocity = error * 10 deg/s, clamped to the
    // mapper's rate.  Writing avelocity IS the movement — the engine's pusher
    // physics integrates it into self.angles (sv_phys.c WPhys_PushMove ->
    // WPhys_Push, amove = avelocity * movetime; sv_rotating.qc:135-142 exists to
    // revert exactly that integration), and cl_brushsync.qc:199 integrates the
    // same value for the client's frames between snapshots.  So this must NOT
    // also add the step to self.angles by hand: the pusher re-applies any
    // think-authored angle delta over 1/64 on top of the avelocity it already
    // integrated, which is how you get a turret that slews at double its rate.
    self.avelocity = [bound(0 - self.pitchrate, dist_x * 10, self.pitchrate),
                      bound(0 - self.yawrate,   dist_y * 10, self.yawrate),
                      0];
    self.SendFlags = 1;

    // CanFire(), func_tank.cpp:67 — keep shooting at the last known spot for
    // `persistence` seconds after losing sight of the target.
    if ((time - self.tankrocket_last_sight) >= self.persistence)
    {
        TankRocket_ResetBurst();
        return;
    }

    // func_tank.cpp:615: fire when (inside both tolerances) OR "Only Direct".
    tol_ok = (fabs(dist_x) < self.pitchtolerance && fabs(dist_y) < self.yawtolerance);
    if (!tol_ok && !(self.spawnflags & TANKROCKET_SF_LINEOFSIGHT))
    {
        TankRocket_ResetBurst();
        return;
    }

    // "Only Direct" (func_tank.cpp:621-628): ignore the tolerance angles and
    // instead demand that a trace straight down the barrel actually reaches the
    // target, so the turret never lobs a rocket into the cover in front of it.
    los_ok = TRUE;
    if (self.spawnflags & TANKROCKET_SF_LINEOFSIGHT)
    {
        makevectors(self.angles);
        traceline(barrel_end, barrel_end + v_forward * vlen(dir), MOVE_NORMAL, self);
        los_ok = (targ != world && trace_ent == targ);
    }
    if (!los_ok)
    {
        TankRocket_ResetBurst();
        return;
    }

    TankRocket_Fire(world);
};

// ---------------------------------------------------------------------------
//  Think / use / spawn
// ---------------------------------------------------------------------------

// CFuncTankLaser::Think, func_tank.cpp:843-849 — turn the beam off on the first
// tick past m_laserTime, then fall through to CFuncTank::Think.  Runs before
// EVERY branch below, including the mounted one, because a player who stops
// holding +attack must not leave the beam burning.
void() TankLaser_ThinkOff =
{
    entity oself;

    if (!self.tanklaser_beam || !self.tanklaser_beam.ebeam_active)
        return;
    if (time <= self.tanklaser_off_time)
        return;

    oself = self;
    self  = self.tanklaser_beam;
    self.ebeam_active = 0;
    self.nextthink    = 0;
    EnvBeam_MarkDirty();
    self = oself;
};

void() tankrocket_think =
{
    entity p;
    float  saved_next_fire;
    vector saved_angles;

    if (self.tank_variant == TANKVAR_LASER)
        TankLaser_ThinkOff();

    p = self.tank_controller;
    if (p != world)
    {
        // MOUNTED: hand the whole job to the sibling's think — mount validity,
        // the yaw/pitch clamp, the slew, the residual error the tolerance gate
        // reads, the avelocity handed to CSQC, and the reschedule.  Duplicating
        // it here would be forty lines that drift out of step the first time
        // sv_goldsrc_compat.qc is touched.
        //
        // TWO THINGS WE HAVE TO UNDO AFTERWARDS, both because we may not edit
        // the sibling:
        //
        // (1) tank_fire() is hitscan.  Its second statement is
        //     `if (time < self.tank_next_fire) return;`
        //     (sv_goldsrc_compat.qc:1255-1256) and it returns from there WITHOUT
        //     writing the field, so parking the cooldown in the future for the
        //     duration of the call suppresses it exactly and restores exactly.
        //     If that early-out is ever reordered this breaks LOUDLY — the tank
        //     starts firing bullets alongside its rockets — rather than silently.
        //
        // (2) tank_think writes self.angles BY HAND *and* sets self.avelocity.
        //     FTE's pusher already integrated the previous avelocity before
        //     calling us (sv_phys.c WPhys_Physics_Pusher: PushMove, then think),
        //     and then re-pushes any angle delta the think authored once it
        //     exceeds 1/64 — so a mounted tank would traverse at twice its
        //     stated yawrate/pitchrate while the unmanned branch below runs at
        //     one.  Restoring the pre-think angles leaves avelocity as the sole
        //     author of the motion, which is both the SDK rate and the value
        //     cl_brushsync.qc extrapolates from.  tank_err_yaw / tank_err_pitch
        //     are computed inside tank_think from the pre-step angles, so they
        //     are unaffected by the restore and the tolerance gate below still
        //     reads what the sibling intended.
        //
        //     THE `avelocity != 0` GUARD ON THAT RESTORE IS LOAD-BEARING, and
        //     getting it wrong freezes the gun.  tank_think ZEROES avelocity on
        //     the step where the barrel arrives exactly
        //     (sv_goldsrc_compat.qc:1338-1341, `err_yaw == 0 && err_pitch == 0`).
        //     On that step the hand-written delta is the ONLY carrier of the
        //     motion — the pusher applies it exactly once through its own
        //     restore-then-Push path — so reverting it would throw the step
        //     away.  Any tank whose rate is high enough to consume the whole
        //     error in one tick (toonrun1 runs yawrate 500 = 25 deg per 0.05 s
        //     tick) hits that branch on essentially every tick, and would never
        //     turn at all.  Restore only when avelocity is actually carrying it.
        saved_next_fire     = self.tank_next_fire;
        saved_angles        = self.angles;
        self.tank_next_fire = time + 1;
        tank_think();
        self.tank_next_fire = saved_next_fire;
        if (self.avelocity != '0 0 0')
            self.angles = saved_angles;

        // tank_think may have dismounted the operator (death, walked away).
        p = self.tank_controller;
        if (p == world)
            return;

        // Sven's "Player can't fire" bit — suspension's APC turret carries it.
        if (self.spawnflags & TANKROCKET_SF_NOPLAYERFIRE)
            return;

        if (!p.button0)
            return;

        // Same tolerance gate the sibling applies to a mounted gun, reading the
        // residual tank_think just left behind (sv_goldsrc_compat.qc:1259-1264).
        if (self.yawtolerance > 0 && fabs(self.tank_err_yaw) > self.yawtolerance)
            return;
        if (self.pitchtolerance > 0 && fabs(self.tank_err_pitch) > self.pitchtolerance)
            return;

        TankRocket_Fire(p);
        return;
    }

    self.nextthink = time + TANKROCKET_TRACK_IV;

    if (!(self.spawnflags & TANKROCKET_SF_ACTIVE))
    {
        // Deactivated: stop dead and stop bleeding SendFlags every tick.
        if (self.avelocity != '0 0 0')
        {
            self.avelocity = '0 0 0';
            self.SendFlags = 1;
        }
        return;
    }

    TankRocket_Track();
};

void() tankrocket_use =
{
    float ut;

    // sub_use_type is a GLOBAL that SUB_UseTargets / Trigger_UseTargets stamp
    // (sv_triggers.qc:126).  It used to be unreadable here: SV_UseTarget called
    // .use directly without touching it, and USE_OFF is 0, so a raw read could
    // not tell "player pressed +use" from "somebody explicitly said OFF" and an
    // inactive turret would refuse to switch on.
    //
    // Both halves are fixed now.  SV_PlayerTryUse seeds USE_UNSET per press
    // (sv_use.qc), and USE_UNSET (-1) is the "nobody said" sentinel instead of
    // 0 (sv_customdefs.qc) — so a hand press and an explicit Off are finally
    // distinguishable.  crystal2's tower_turret and th_ep2_00's rpg both ship
    // inactive and depend on the press taking the toggle path.
    ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

    // Player-controlled turret, func_tank.cpp:422-441.  Delegate the mount to
    // the sibling so both tank classes behave the same under a func_tankcontrols
    // — which is not optional anyway: tankcontrols_use calls tank_use() by name
    // (sv_goldsrc_compat.qc:1402), not through self.use, so that route reaches
    // tank_use whatever this function does.
    if (self.spawnflags & TANK_SF_CANCONTROL)
    {
        // UTIL_IsMasterTriggered gate on StartControl, func_tank.cpp:345-349.
        if (!IsMasterTriggered(self.master, activator))
            return;
        tank_use();
        return;
    }

    // Otherwise +use toggles the turret on and off (func_tank.cpp:442-450), the
    // ShouldToggle/TankActivate/TankDeactivate path.  crystal2 and th_ep2_00
    // both ship their tank inactive and switch it on from a multi_manager.
    if (ut == USE_ON  &&  (self.spawnflags & TANKROCKET_SF_ACTIVE))
        return;
    if (ut == USE_OFF && !(self.spawnflags & TANKROCKET_SF_ACTIVE))
        return;

    if (self.spawnflags & TANKROCKET_SF_ACTIVE)
    {
        self.spawnflags = self.spawnflags & ~TANKROCKET_SF_ACTIVE;
        self.avelocity  = '0 0 0';
        self.SendFlags  = 1;
    }
    else
        self.spawnflags = self.spawnflags | TANKROCKET_SF_ACTIVE;

    // Both TankActivate and TankDeactivate clear m_fireLast (func_tank.cpp:66-67),
    // so a turret switched back on waits a full interval and re-acquires.
    self.tank_next_fire        = 0;
    self.tankrocket_last_sight = 0;
    self.tankrocket_have_sight = FALSE;
};

// The explosion travels on env_explosion's CSQC event, so precache what its
// handler will reach for — mirrors sv_env_explosion.qc:104-108 verbatim, and
// for the same reason: a map may carry a turret and no env_explosion.
void() Tank_PrecacheExplosion =
{
    precache_model("gfx/eexplo.spr");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode3.wav");
};

// CFuncTank::Spawn (func_tank.cpp:177-212) — everything the three subclasses
// share, which is all of it bar the projectile.  Called by func_tankrocket,
// func_tankmortar and func_tanklaser; see the defaults block for why each
// number is the one Valve's own tooling writes.
void() Tank_CommonSpawn =
{
    if (self.spriteflash != "" && self.spriteflash)
        precache_model(self.spriteflash);
    if (self.spritesmoke != "" && self.spritesmoke)
        precache_model(self.spritesmoke);

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
    self.use        = tankrocket_use;

    // m_yawCenter / m_pitchCenter, func_tank.cpp:180-181.
    self.tank_base_angles = self.angles;

    // Defaults.  Each is the value Valve's own tooling writes:
    //   firerate       func_tank.cpp:194, FGD line 1035
    //   persistence    FGD line 1037 — CanFire() is a strict `<`, so a
    //                  persistence of 0 makes the fire gate unreachable even
    //                  on the tick the target was seen
    //   yawtolerance   FGD line 1024   pitchtolerance FGD line 1027
    // QC cannot tell an absent key from an explicit 0 on a .float, which is the
    // same trade sv_env_explosion.qc:50 documents for iMagnitude.
    //
    // NO `barrel` DEFAULT.  The sibling forces 64 (sv_goldsrc_compat.qc:1391);
    // that is safe for a hitscan and wrong here.  The SDK and the FGD both
    // default it to 0 (sven-coop.fgd:1032), meaning the muzzle sits ON the
    // pivot, INSIDE the tank's own brush — which is guaranteed clear because
    // the engine skips owner/ownee pairs when clipping.  Pushing it 64 units
    // forward instead can land the muzzle inside unrelated world geometry, and
    // for a live rocket that means detonating on frame one, while
    // TankRocket_FindTarget's LOS trace starts in solid and never acquires
    // anything.  crystal2's tower_turret is the one corpus entity with no
    // barrel key, and HL runs it at 0.
    if (self.firerate       <= 0) self.firerate       = 1;
    if (self.persistence    <= 0) self.persistence    = 1;
    if (self.yawtolerance   <= 0) self.yawtolerance   = 15;
    if (self.pitchtolerance <= 0) self.pitchtolerance = 5;

    self.think     = tankrocket_think;
    self.nextthink = time + 0.1;
};

/*QUAKED func_tankrocket (0 .3 .8) ? ACTIVE PLAYER HUMANS ALIENS ONLYDIRECT CANCONTROL
Brush rocket turret — func_tank that launches RPG rockets instead of bullets.
Unmanned and ACTIVE it acquires the nearest visible player and fires within its
arc; with CANCONTROL a player mounts it through a linked func_tankcontrols.

"barrel" "barrely" "barrelz"     muzzle offset forward / right / up of the pivot
"firerate"                       rockets per second (default 1)
"yawrange" "pitchrange"          arc limits in degrees; 0 locks that axis
"yawrate" "pitchrate"            slew speed in degrees/second; 0 locks that axis
"yawtolerance" "pitchtolerance"  don't fire until the barrel is this close
"persistence"                    seconds to keep firing after losing sight
"minRange" "maxRange"            target range window; maxRange 0 = unbounded
"spriteflash" "spritesmoke"      muzzle sprites, scaled by "spritescale"
"master"                         game_team_master / multisource gate on mounting
"target"                         fired on every rocket launched
ACTIVE       start switched on; +use toggles it otherwise
ONLYDIRECT   ignore the tolerance angles, require a clear shot down the barrel
CANCONTROL   player-operated via func_tankcontrols
*/
void() func_tankrocket =
{
    precache_model(RPG_ROCKET_MODEL);
    precache_sound(RPG_FLY_SOUND);
    precache_sound("sounds/null.wav");
    Tank_PrecacheExplosion();

    self.tank_variant = TANKVAR_ROCKET;
    Tank_CommonSpawn();
};

/*QUAKED func_tankmortar (0 .3 .8) ? ACTIVE PLAYER HUMANS ALIENS ONLYDIRECT CANCONTROL
Brush mortar turret — func_tank that detonates a shell where its shot lands
instead of firing bullets.  Six in the corpus: hl_c11_a2's `brad_cannon` and
`howie`, hl_c11_a4, hl_c11_a5 and hl_c12's `tank_turret`.

"iMagnitude"                     blast power (default 100 = one HE grenade)
"firespread"                     0 perfect .. 4 extra-large cone
plus every func_tankrocket key above.
*/
void() func_tankmortar =
{
    Tank_PrecacheExplosion();

    self.tank_variant = TANKVAR_MORTAR;
    Tank_CommonSpawn();
};

// ---------------------------------------------------------------------------
//  sv_tank_selftest — force one shot out of every turret on the map
//
//  A tank's Fire() is the only part of the class that a headless run cannot
//  otherwise reach.  Everything else runs on its own: an ACTIVE turret's think
//  ticks at 10 Hz from map load and TrackTarget runs with it.  Fire() needs a
//  LIVING PLAYER inside both the arc and the range window, and on the two maps
//  that carry the new subclasses the spawn points are nowhere near — measured
//  on hl_c14, where the player lands at 53 1959 1703 and the nearest flower
//  turret is at 264 712 -41 with maxRange 512.  Wandering never closes that.
//
//  So this fires them by hand and reports.  Consume-once, like every other
//  self-test in this tree (sv_ai_firetest, sv_ai_gibs.qc:475).
// ---------------------------------------------------------------------------
float tank_selftest_done;

void(string cls, __inout float n, __inout float bad) Tank_SelfTestClass =
{
    entity e;
    entity oself;
    float  had_beam;

    // find(), NOT findchain().  Firing a mortar turret reaches W_RadiusExplode,
    // which builds a chain of its own — so a .chain walk started here is
    // rewritten underneath us by the first shot and the second iteration lands
    // on whatever the explosion happened to touch.  Caught exactly that way:
    // hl_c11_a5 reported "func_tankmortar hangar_door", which is a door.
    e = find(world, classname, cls);
    while (e)
    {
        oself = self;
        self  = e;

        n = n + 1;
        had_beam = (self.tanklaser_beam != world);

        // Clear the cooldown so the shot is not swallowed, then aim the barrel
        // wherever it already points and pull the trigger with no operator —
        // exactly the unmanned path TrackTarget would have taken.
        self.tank_next_fire = 0;
        TankRocket_Fire(world);

        if (self.tank_variant == TANKVAR_LASER)
        {
            if (!self.tanklaser_beam)
            {
                bad = bad + 1;
                print(sprintf("[tanktest] %s \"%s\": laserentity \"%s\" resolved to no env_laser\n",
                              cls, self.targetname, self.laserentity));
            }
            else
                print(sprintf("[tanktest] %s \"%s\": %s env_laser \"%s\", beam %v -> %v, dmg %g\n",
                              cls, self.targetname,
                              had_beam ? "reused" : "resolved",
                              self.tanklaser_beam.targetname,
                              self.tanklaser_beam.ebeam_start_pos,
                              self.tanklaser_beam.ebeam_end_pos,
                              self.tanklaser_beam.damage));
        }
        else if (self.tank_variant == TANKVAR_MORTAR)
            print(sprintf("[tanktest] %s \"%s\": shell landed %v (%g units out), iMagnitude %g, spread %g\n",
                          cls, self.targetname, trace_endpos,
                          vlen(trace_endpos - TankRocket_Base()),
                          self.iMagnitude, self.firespread));
        else
            print(sprintf("[tanktest] %s \"%s\": rocket away from %v\n",
                          cls, self.targetname, TankRocket_BarrelPosition()));

        self = oself;
        e = find(e, classname, cls);
    }
};

void() Tank_SelfTest =
{
    float n;
    float bad;

    if (tank_selftest_done || !cvar("sv_tank_selftest"))
        return;
    // Three seconds in: every entity has spawned and any env_laser the tanks
    // name is linked, so a failure to resolve one is a real failure.
    if (time < 3)
        return;

    tank_selftest_done = 1;
    cvar_set("sv_tank_selftest", "0");

    n   = 0;
    bad = 0;
    Tank_SelfTestClass("func_tankmortar", n, bad);
    Tank_SelfTestClass("func_tanklaser",  n, bad);
    Tank_SelfTestClass("func_tankrocket", n, bad);

    print(sprintf("[tanktest] %g turret(s) fired, BAD=%g\n", n, bad));
};

/*QUAKED func_tanklaser (0 .3 .8) ? ACTIVE PLAYER HUMANS ALIENS ONLYDIRECT CANCONTROL
Brush laser turret — func_tank that pulses a named env_laser down its barrel.
The env_laser supplies the beam's look and its `damage`; the tank supplies both
endpoints, so the laser's own LaserTarget key is deliberately ignored.

"laserentity"                    targetname of the env_laser to drive (required)
"firespread"                     0 perfect .. 4 extra-large cone
plus every func_tankrocket key above.
*/
void() func_tanklaser =
{
    self.tank_variant = TANKVAR_LASER;
    Tank_CommonSpawn();

    // CFuncTankLaser::Activate (func_tank.cpp:792-803) removes a laser tank with
    // no env_laser and logs an error.  Only the diagnostic is kept: removing the
    // brush would take its geometry out of the map, and a silent turret is a far
    // smaller problem than a hole in the wall.  Deferred a tick because the
    // env_laser may not have spawned yet when we do.
    if (self.laserentity == "" || !self.laserentity)
        dprint(sprintf("[func_tanklaser] \"%s\" at %v has no laserentity key\n",
                       self.targetname, self.origin));
};

// ============================================================
//  game_counter_set
//  SDK (C:/msys64/home/Lex/halflife):
//  - dlls/maprules.cpp:731-760 — CGameCounterSet. Use() is: CanFireForActivator (:751), SUB_UseTargets(
//  - dlls/maprules.cpp:693-727 — CGameCounter::Use, the only receiver that reads the USE `value`: case 
//  - dlls/maprules.cpp:33-49 — class CRuleEntity : public CBaseEntity (NOT CBaseDelay), and :78-89 CanF
//  - dlls/maprules.cpp:100-105 — CRulePointEntity::Spawn (SOLID_NOT / MOVETYPE_NONE / EF_NODRAW / no mo
//  - dlls/subs.cpp:177-186 — CBaseEntity::SUB_UseTargets: FireTargets and nothing else. Because CRuleEn
// ============================================================

// ===========================================================================
//  game_counter_set — the write half of the game_counter pair.
//
//  Firing it stamps a fixed number onto every game_counter it targets, instead
//  of nudging one by +1.  Maps use it almost exclusively as "reset this
//  counter", with the value left unset (= 0).
//
//  SDK: dlls/maprules.cpp:748-760 (CGameCounterSet).  Its whole Use() is three
//       lines: master gate, SUB_UseTargets(pActivator, USE_SET, pev->frags),
//       optional self-removal.  The number travels as the `value` argument of
//       the USE call, and dlls/maprules.cpp:709-711 is the only receiver that
//       reads it — CGameCounter's USE_SET branch does pev->frags = value and
//       then falls into its normal HitLimit() check
//       (dlls/maprules.cpp:713-726; HitLimit is `CountValue() == LimitValue()`
//       at dlls/maprules.cpp:677).
//
//  Compile order in sv_progs.src: AFTER sv_doors.qc (Trigger_UseTargets),
//  sv_triggers.qc (SUB_KillTargets, IsMasterTriggered) and
//  sv_game_team_master.qc (game_counter itself).
// ===========================================================================

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void(entity caller, entity triggerer) Trigger_UseTargets;   // sv_doors.qc:88
void(string name) SUB_KillTargets;                          // sv_triggers.qc:51
float(string master_name, entity who) IsMasterTriggered;    // sv_triggers.qc:165

// useType pass-through global — declared authoritatively in sv_doors.qc:78.
// Re-declared here for readability; QC accepts identical re-decls (the same
// thing sv_triggers.qc:46 does, with the same comment).
float sub_use_type;

// Sven's FGD (sven-coop.fgd:2673-2681) gives this class exactly one spawnflag
// bit, matching SF_GAMECOUNTSET_FIREONCE at dlls/maprules.cpp:735.
const float SF_GCOUNTERSET_REMOVE = 1;    // "Remove On fire"

// ---------------------------------------------------------------------------
// WHY THIS ARMS THE COUNTER INSTEAD OF SETTING IT
//
// HL carries the new value in the USE call's `value` argument.  This tree's
// use protocol has no value channel: .use() is a nullary callback and the only
// thing Trigger_UseTargets passes down is the useType global
// (sv_doors.qc:88-154).  Adding one would mean touching every .use in the
// port, and game_counter_use (sv_game_team_master.qc:82-105) ignores useType
// regardless — it increments by exactly 1 on every call, whatever type it was
// fired with (sv_game_team_master.qc:86).
//
// So instead of fighting that, exploit it: stamp `value - 1` on each targeted
// counter, then fire the chain normally.  The counter's own .use adds the
// missing 1, lands on `value`, and — this is the point — runs ITS OWN
// threshold test, REMOVE / RESET / "fire if over limit" spawnflag handling and
// target chain.  None of that logic is duplicated here, so it cannot drift out
// of sync with the sibling.
//
// CORPUS (entity lump of EVERY .bsp on the Sven mount, parsed — 63
// game_counter_set placements, not the 20 an earlier partial scan reported):
//   - 63 of 63 target ONLY game_counter entities.  Nothing else is ever on the
//     far end, so the arming pass covers every shipping placement.
//   - 55 of 63 ship no `frags` key at all (= reset to 0); the 8 that do use
//     1 / 4 / 5 / 10 / 420 / 600 / 800 / 10000.
//   - ZERO set `delay`, `killtarget`, `master` or any spawnflag.  The only keys
//     that ever appear are origin / angles / target / targetname / frags.
//   - No targeted counter carries a `master` either, so the arm-time master
//     check below never actually skips one in shipping content.
//
// Hand-simulated against that data:
//   th_escape "veh0_repairreset": value 0 onto veh0_repaircount (health 100,
//     spawnflags 1) -> -1, +1 = 0, no fire.  Correct reset.
//   svencoop1 "checkfor2set": value 10 onto FIVE counters that all share the
//     name checkfor2count (health 2/3/4/5/6, spawnflags 1 = REMOVE_ON_FIRE, so
//     no OVERLIMIT bit) -> 9, +1 = 10, which equals none of them, so none fire
//     and none delete themselves.  That map is deliberately parking the
//     counters out of reach to disable them, and it only works because the
//     threshold test is `==` and not `>=` — which is exactly why the test has
//     to stay inside game_counter_use, where the FIRE_IF_OVER flag governs it.
//     Note also that five entities share that targetname: the arming pass must
//     walk the whole find() chain, not just the first hit.  Nine other sets in
//     the corpus fan out the same way (stadium4 mortarreset / powerreset,
//     svencoop2 resetxencount, tf_original + turretfortress spec_cam*_c_s).
//   judgement "rat_on_altar": value 1 onto deadboolean (frags 1, health 2) ->
//     0, +1 = 1, no fire.  Its partner "deadboolean_to0" writes 0 back.
//
// The arming pass is deliberately narrow:
//   - classname == "game_counter" only.  Anything else in the chain has a .use
//     that does not increment, so pre-decrementing it would just corrupt it;
//     those entities still get fired below, with USE_SET, exactly as HL's
//     FireTargets does (dlls/subs.cpp:189-210).
//   - the counter's own `master` must currently pass.  game_counter_use
//     re-checks it at sv_game_team_master.qc:84 and returns BEFORE the
//     increment if it fails, which would strand the counter at value-1.  HL
//     has the same early-out (CanFireForActivator, dlls/maprules.cpp:695), so
//     skipping the entity entirely is both the faithful and the safe answer.
//
// CAUTION for whoever edits game_counter_use next: turretfortress and
// tf_original wire a counter's `target` BACK at the game_counter_set that
// writes it (spec_cam1_c -> spec_cam1_c_s -> spec_cam1_c).  Today that loop is
// inert because the set writes 0 and none of those counters has health 0, but
// any change that makes them fire on a set will recurse — in stock HL too,
// since CGameCounter::Use calls SUB_UseTargets straight after SetCountValue.
// ---------------------------------------------------------------------------
void() game_counter_set_use =
{
    entity e;
    float  newval;
    float  dbg;
    float  oldut;

    // dlls/maprules.cpp:751 — CanFireForActivator on this entity's own master.
    if (!IsMasterTriggered(self.master, activator))
        return;

    // dlls/maprules.cpp:754 passes pev->frags straight through, and there is no
    // defaulting anywhere in CGameCounterSet.  An absent key is therefore 0,
    // NOT the FGD's editor default of 10 (sven-coop.fgd:2680) — 55 of the 63
    // placements in the corpus ship no `frags` key at all and mean "reset to
    // zero", so honouring the FGD number would break every one of them.  Same
    // call the sibling makes about game_counter's `health` at
    // sv_game_team_master.qc:122-125.
    newval = self.frags;
    dbg    = cvar("sv_debug_use");

    // Not in stock HL: CRuleEntity derives from CBaseEntity (dlls/maprules.cpp:33),
    // so this class gets CBaseEntity::SUB_UseTargets (dlls/subs.cpp:177-186),
    // which fires targets and nothing else — no killtarget, no delay.  Honour
    // killtarget anyway, because the sibling game_counter already does (it
    // routes through sv_triggers.qc:112 SUB_UseTargets, which kills first) and
    // because Sven's FGD exposes the key through the Targetx base
    // (sven-coop.fgd:418-422).  Diverging from the sibling would be more
    // surprising than diverging from stock.  No map in the corpus sets it, so
    // this can only ever help a map we have not seen.  SUB_KillTargets already
    // no-ops on an empty name (sv_triggers.qc:53).
    SUB_KillTargets(self.killtarget);

    if (self.target)
    {
        e = find(world, targetname, self.target);
        while (e)
        {
            if (e.classname == "game_counter" &&
                IsMasterTriggered(e.master, activator))
            {
                if (dbg)
                    print(sprintf("[game_counter_set] \"%s\": counter \"%s\" %g -> %g\n",
                                  self.targetname, e.targetname, e.frags, newval));
                e.frags = newval - 1;      // the +1 arrives from game_counter_use
            }
            e = find(e, targetname, self.target);
        }
    }

    // Synchronous on purpose.  Trigger_UseTargets is the direct equivalent of
    // HL's FireTargets; going through SUB_UseTargets instead would defer the
    // whole chain whenever a mapper set `delay`, which would split the arming
    // above from the increment that completes it and leave every targeted
    // counter sitting at value-1 for the length of that delay.  Stock HL
    // ignores `delay` on this class anyway (see the SUB_UseTargets note above),
    // so nothing is lost.
    //
    // SAVE AND RESTORE sub_use_type AROUND THE CALL.  Trigger_UseTargets does
    // save/restore (sv_doors.qc:102/152), but it restores the value it saw on
    // ENTRY — i.e. the USE_SET we just wrote — so without the restore below the
    // global stays at USE_SET after we return.  We are usually invoked from
    // inside a parent Trigger_UseTargets loop, and that loop does NOT re-stamp
    // sub_use_type per target: every SIBLING fired after us in the same chain
    // would then see USE_SET instead of the chain's real useType.  That is not
    // hypothetical — door_use (sv_doors.qc:911) and door_use_force
    // (sv_doors.qc:934) are exactly the "legacy callers" the sv_doors.qc:117
    // comment describes, relying on the 0 -> USE_TOGGLE default they would no
    // longer get; GoldSrc_UnknownRelay_Use (sv_goldsrc_compat.qc:123) and
    // trigger_entity_iterator_use (sv_goldsrc_entities.qc:251) would forward
    // the stale USE_SET down chains it has nothing to do with.  The tree has
    // already been bitten by a stale sub_use_type once — see the measured
    // tracktrain autostart failure documented at sv_func_tracktrain.qc:562.
    // sv_buttons.qc:113 gets away with the bare `set; call` idiom only because
    // it runs from a think, not from inside a chain.
    oldut        = sub_use_type;
    sub_use_type = USE_SET;
    Trigger_UseTargets(self, activator);
    sub_use_type = oldut;

    if (self.spawnflags & SF_GCOUNTERSET_REMOVE)
        remove(self);
};

/*QUAKED game_counter_set (.5 .5 .5) (-8 -8 -8) (8 8 8) REMOVE_ON_FIRE
Writes a fixed value into every game_counter named by "target", then fires the
chain.  The counter re-evaluates its threshold with the new value, so a set
that lands exactly on the counter's "health" makes it fire on the spot.

REMOVE_ON_FIRE (1):  delete this entity after it fires.

"targetname"  name
"target"      game_counter(s) to write, and the rest of the chain
"frags"       value to write (default 0 — the common "reset" case, 55 of the
              63 placements in the Sven corpus)
"master"      upstream gate
"killtarget"  removed before the chain fires

`delay` is accepted by the FGD but ignored, exactly as in stock HL, where
CRuleEntity is a CBaseEntity and so never reaches CBaseDelay's delay path.
*/
void() game_counter_set =
{
    // CGameCounterSet has no Spawn() of its own; CRulePointEntity::Spawn
    // (dlls/maprules.cpp:100-105) only makes it a non-solid, invisible point
    // entity, which is what a QC point entity already is.  Same shape as the
    // sibling at sv_game_team_master.qc:127.
    self.use = game_counter_set_use;
};

// ===========================================================================
//  trigger_numericdisplay  —  Sven Co-op "Numeric Display"
// ===========================================================================
//  sven-coop.fgd:6533-6547:
//      target   "Entity to track"      <- READ FROM.  Not a chain to fire.
//      netname  "Key to read"          (th_escape reads "frags")
//      message  "Base digit name"      -> brushes are <message>1 .. <message>10
//      frags    "Update delay"         (string, default "0.1")
//      spawnflags  1 Start On / 2 Cyclic / 4 Ignore leading zeroes
//                  8 Zero as leading
//
//  WHY THIS CLASS EXISTS HERE AT ALL, GIVEN IT DRAWS NOTHING.
//  Left unimplemented it fell through to GoldSrc_UnknownRelay_Use
//  (sv_goldsrc_compat.qc), whose whole job is to forward to `.target` so an
//  unported entity cannot sever a campaign chain.  That default is exactly wrong
//  for this class, because its `.target` is the entity it is supposed to READ:
//  th_escape's `startbutt_ms_numdsp` tracks `startbutt_ms_cnt`, the game_counter
//  that gates the start button, so the relay was firing that counter an extra
//  time every update — on top of the once-a-second countdown the map's own
//  multi_manager drives.  Two writers pulling in different directions is why the
//  opening never finished.  A class that does nothing is strictly better than
//  that; a `.use` that does nothing is what makes it do nothing.
//
//  THE DIGITS ARE NOT DRAWN, and that is an engine limit rather than an
//  omission.  Both of th_escape's digit brushes carry the GoldSrc animated
//  texture group "+0~lcdcount" (verified by reading the BSP's texinfo for models
//  *791 and *792), and FTE picks the frame inside such a group from a WALL
//  CLOCK — engine/gl/gl_model.c:3276-3278, `relative = (cl.time*10) %
//  anim_total` — with .frame selecting only the `+a` ALTERNATE set, never an
//  index into the group.  So "show a 7" is not expressible from QC on this
//  build.  The brushes keep free-running, which is what they already did and
//  reads as a counter ticking over.  Pinning them to a value needs an engine
//  change (a per-entity texture-group frame override); when that lands, this is
//  the entity that would drive it and `netname`/`message` are the keys it needs.
void() trigger_numericdisplay_use =
{
    // Start On / the Cyclic flag would gate the update loop.  With nothing to
    // update, on and off are the same thing — but the .use must still EXIST, so
    // that a chain aimed at this entity terminates here instead of walking on to
    // the tracked entity.
};

void() trigger_numericdisplay =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = trigger_numericdisplay_use;
};

// ============================================================
//  button_target
//  SDK (read on disk, C:/msys64/home/Lex/halflife):
//  - dlls/buttons.cpp:1230-1231 — SF_BTARGET_USE 0x0001 / SF_BTARGET_ON 0x0002
//  - dlls/buttons.cpp:1243 — LINK_ENTITY_TO_CLASS( button_target, CButtonTarget )
//  - dlls/buttons.cpp:1245-1254 — Spawn: MOVETYPE_PUSH, SOLID_BSP, SET_MODEL, takedamage = DAMAGE_YES, 
//  - dlls/buttons.cpp:1256-1265 — Use: ShouldToggle gate, `pev->frame = 1-pev->frame`, SUB_UseTargets w
//  - dlls/buttons.cpp:1268-1276 — ObjectCaps: FCAP_IMPULSE_USE only when SF_BTARGET_USE is set
// ============================================================

// ===========================================================================
//  button_target  —  Half-Life / GoldSrc "Target Button"
//
//  SDK: dlls/buttons.cpp:1230-1284 (CButtonTarget)
//  FGD: sven-coop.fgd:1495   @SolidClass base(Target, ZHLT) = button_target
//
//  A brush that is NOT a mover.  It holds one bit of state in pev->frame
//  (buttons.cpp:1260), flips that bit whenever it is used or SHOT, and fires
//  its target chain with USE_ON on the rising edge and USE_OFF on the falling
//  one.  The frame flip is also how GoldSrc swaps a "+0name"/"+Aname" texture
//  pair, so the brush LOOKS lit while it is on.
//
//  Shape borrowed from func_button (server/sv_buttons.qc): the master gate,
//  the shootable-brush idiom, and the .frame 0/1 state convention.  It needs
//  none of func_button's pos1/pos2 or Mover_Start machinery because it never
//  moves — but it IS a shootable-not-breakable brush, which is the property
//  that decides its brush_type on the wire (see the spawn function).
// ===========================================================================

// buttons.cpp:1230-1231.  Sven's FGD ships "Use Activates" defaulted to ON
// and "Start On" defaulted to off (sven-coop.fgd:1497-1501).
const float SF_BTARGET_USE = 1;
const float SF_BTARGET_ON  = 2;

// CButtonTarget::TakeDamage (buttons.cpp:1279-1284) never touches pev->health:
// ANY damage toggles the button, and the button can never be destroyed.  This
// tree has no equivalent hook — W_ApplyDamage (sv_weapons.qc:1646) always
// subtracts from .health — so the immortality is faked with a pool that is
// re-armed on every hit, the same way door_killed re-arms a shootable door
// (sv_doors.qc:958).
//
// Sized so that no single blow in the game can exhaust it.  That matters for
// two reasons: W_ApplyDamage clamps `damage` to the remaining health and then
// picks its dispatch on the SIGN of the result (sv_weapons.qc:2009 vs :2017),
// so an unexhaustable pool means .on_damaged is the only hook that ever runs;
// and W_CanDamageTarget (sv_weapons.qc:1229) rejects anything at health <= 0,
// so the pool must still be positive when the NEXT bullet arrives.
const float BTARGET_HEALTH_POOL = 1000000;

// Multi-damage debounce.  Half-Life batches a shotgun's pellets through
// ClearMultiDamage / ApplyMultiDamage, so one blast is ONE TakeDamage call and
// therefore exactly one toggle.  This tree calls W_ApplyDamage once per pellet,
// so without a debounce an 8-pellet blast would toggle eight times and the
// final state would depend on how many pellets happened to connect.  Same fix
// and same 0.1s window as the shootable-door path (sv_doors.qc:928-929).
.float btarget_dmg_time;

// ---------------------------------------------------------------------------
// The toggle itself — CButtonTarget::Use, buttons.cpp:1256-1265.
// `who` becomes the activator of the target chain.
// ---------------------------------------------------------------------------
void(float useType, entity who) BTarget_Toggle =
{
    // NOT in stock HL: CButtonTarget derives straight from CBaseEntity, which
    // never reads `master` — that key belongs to CBaseDelay/CBaseTrigger
    // (subs.cpp:372), and this class is in neither chain.  Sven's FGD DOES
    // expose master(string) on button_target (sven-coop.fgd:1502), and
    // func_button in this tree already honours its FGD master for exactly that
    // reason (sv_buttons.qc:177-190).  IsMasterTriggered returns TRUE for an
    // empty or unresolvable name, so a map that never sets the key is
    // unaffected and a mapper typo cannot brick the button.
    if (!IsMasterTriggered(self.master, who))
        return;

    // CBaseEntity::ShouldToggle, cbase.cpp:726-734.  Inlined rather than
    // factored into a helper because that is how the rest of this tree spells
    // it (sv_func_train.qc:451-452, sv_func_tracktrain.qc:405).
    if (useType != USE_TOGGLE && useType != USE_SET)
    {
        if (self.frame && (useType == USE_ON))
            return;
        if (!self.frame && (useType == USE_OFF))
            return;
    }

    self.frame = 1 - self.frame;                    // buttons.cpp:1260

    // Printed BEFORE the chain fires.  SUB_UseTargets applies `killtarget` and
    // hands control to arbitrary downstream .use functions, any of which may
    // remove US — reading self.targetname afterwards would be a read off a
    // freed edict.
    if (cvar("sv_debug_use"))
        print(sprintf("[button_target] \"%s\" frame=%g useType=%g target=\"%s\"\n",
                      self.targetname, self.frame, useType, self.target));

    // buttons.cpp:1261-1264 — the EDGE decides the useType handed downstream,
    // which is what lets a multisource or another latch see clean on/off input.
    //
    // SUB_UseTargets rather than the two-arg Trigger_UseTargets: it is this
    // tree's full-semantics walker and the only form that can carry a useType.
    // It also implements `killtarget` and `delay`, which CBaseEntity's
    // SUB_UseTargets (subs.cpp:177-185) does NOT — but Sven's FGD gives
    // button_target only base(Target), i.e. the bare `target` key
    // (sven-coop.fgd:284-287), so neither key is authorable on this class and
    // the extra handling stays inert.
    if (self.frame)
        SUB_UseTargets(self, who, USE_ON);
    else
        SUB_UseTargets(self, who, USE_OFF);
};

// ---------------------------------------------------------------------------
// .use — fired by a trigger chain, or by a player's +use when SF_BTARGET_USE
// put us in the use search at all (see the spawn function).
// ---------------------------------------------------------------------------
void() button_target_use =
{
    float ut;

    // How the press arrived decides the useType, exactly as it does in HL:
    //
    //  - A player pressing +use is HL's FCAP_IMPULSE_USE path, and
    //    CBasePlayer::PlayerUse hands the object USE_SET (player.cpp:1668-1673,
    //    `pObject->Use( this, this, USE_SET, 1 )`), which ShouldToggle accepts
    //    unconditionally.  sv_use_is_player_direct (sv_customdefs.qc:281) is
    //    TRUE only inside SV_PlayerTryUse, and Trigger_UseTargets clears it for
    //    everything it fires (sv_doors.qc:115), so it cannot leak into a
    //    chain-driven press.
    //  - A trigger chain arrives through Trigger_UseTargets, which has already
    //    normalised sub_use_type and rewritten a 0 to USE_TOGGLE
    //    (sv_doors.qc:120-121).
    //
    // The fallback below therefore only covers direct `e.use()` call sites that
    // bypass Trigger_UseTargets.  It used to test `ut == 0` and so could not
    // tell an explicit USE_OFF from "unset" — no longer true tree-wide: the
    // sentinel is USE_UNSET (-1) now (sv_customdefs.qc), so an Off survives and
    // only a genuinely unset value falls back to toggle.
    if (sv_use_is_player_direct)
        ut = USE_SET;
    else
        ut = sub_use_type;
    if (ut == USE_UNSET)
        ut = USE_TOGGLE;

    BTarget_Toggle(ut, activator);
};

// ---------------------------------------------------------------------------
// .on_damaged / .on_killed — CButtonTarget::TakeDamage, buttons.cpp:1279-1284.
//
// Both hooks land here.  W_ApplyDamage dispatches exactly ONE of them per hit
// (sv_weapons.qc:2009 and :2017 — the split is the sign of the post-hit
// health), which is precisely the "any damage toggles once" semantic.
//
// Wiring .on_killed matters for a second reason: the branch above it
// (sv_weapons.qc:1997) fires a dead entity's .use directly UNLESS the entity
// carries an .on_killed, and that would be a second toggle in the same frame.
// It is also the only hook that would run if a mover that subtracts .health
// directly (func_train_blocked / func_tracktrain / func_vehicle — see the
// W_CanDamageTarget comment at sv_weapons.qc:1236) ever drove the pool under.
// ---------------------------------------------------------------------------
void() button_target_damaged =
{
    // Re-arm first and unconditionally, so a hit swallowed by the debounce
    // still tops the pool back up.
    self.health = BTARGET_HEALTH_POOL;

    if (self.btarget_dmg_time > time)
        return;
    self.btarget_dmg_time = time + 0.1;

    // buttons.cpp:1281 — Use(Instance(pevAttacker), this, USE_TOGGLE, 0): the
    // ATTACKER becomes the activator of the target chain, and USE_TOGGLE means
    // a shot always flips regardless of the current state.  W_ApplyDamage
    // stamps .dmg_inflictor with the attacker before dispatching us
    // (sv_weapons.qc:1733) — the same source door_killed reads (sv_doors.qc:945).
    BTarget_Toggle(USE_TOGGLE, self.dmg_inflictor);
};

/*QUAKED button_target (0 .5 .8) ? USE_ACTIVATES START_ON
A shootable / pressable brush that latches ON and OFF.  It never moves.
Every flip fires "target": USE_ON when it latches on, USE_OFF when it latches
off, so a multisource or another latch downstream sees clean edges.

USE_ACTIVATES (1): a player may +use it.  Without this bit it can only be shot
                   or fired by name, and a +use aimed at it passes through to
                   whatever is behind.  Sven's FGD defaults this bit ON.
START_ON (2):      spawn already latched on.  Does NOT fire "target" at spawn.

"target"  chain fired on every flip
"master"  upstream gate (Sven FGD key; stock HL ignores it — see BTarget_Toggle)
Render keys (rendermode / renderamt / rendercolor / renderfx) all apply.
*/
void() button_target =
{
    // buttons.cpp:1247-1249 — MOVETYPE_PUSH + SOLID_BSP + SET_MODEL.  All
    // three, plus the GoldSrc render keys and the CSQC replica every other
    // brush class in this tree gets, come from the one brush initialiser
    // (sv_brushsync.qc:555).
    SV_InitReplicatedSolidBrush();
    if (wasfreed(self))             // it removes brushes that have no model
        return;

    // buttons.cpp:1250 — pev->takedamage = DAMAGE_YES.
    self.takedamage = DAMAGE_YES;
    self.health     = BTARGET_HEALTH_POOL;
    self.on_damaged = button_target_damaged;
    self.on_killed  = button_target_damaged;

    self.use = button_target_use;

    // ---- brush_type: BUTTON, not STATIC ----------------------------------
    // This entity never moves, so "static brush" is the intuitive answer and
    // it is the WRONG one.  On the wire, BRUSH_TYPE_STATIC + a non-zero
    // replicated health is this tree's definition of "func_breakable", and
    // three separate client paths act on that pair — all of them wrong here,
    // because a button_target can never be destroyed:
    //
    //   cl_bulletimpact.qc:1630-1632  plays the BREAKABLE MATERIAL thump on
    //       every bullet, for the shooter only.  Its own comment says
    //       shootable buttons/doors must be excluded and names the
    //       brush_type == BRUSH_TYPE_STATIC test as the thing that excludes
    //       them.
    //   cl_bulletimpact.qc:717-739    enters CSQC_PredictBreakableBreak, which
    //       emits one rejected `cmd breakclaim` stringcmd per PELLET
    //       (sv_trust_clientbreak defaults to 1, sh_cvar_table.qc:2848;
    //       SV_HandleBreakclaim rejects any classname != func_breakable at
    //       sv_player.qc:3892).
    //   cl_bulletimpact.qc:748-750    decrements the replicated brush_health
    //       locally with no way back: we never re-dirty SendFlags, and
    //       PVSF_NOREMOVE means no corrective snapshot ever arrives
    //       (cl_brushsync.qc:899-901 documents exactly that).  Once the
    //       accumulated local damage passes the wire's 32767 clamp the
    //       shooter's client hides the brush and sets it SOLID_NOT.
    //
    // BRUSH_TYPE_BUTTON is the existing, named type for "shootable brush that
    // is not a breakable" — the same reason func_button uses it
    // (sv_buttons.qc:387-390).  All three paths above gate it out.
    self.brush_type = BRUSH_TYPE_BUTTON;

    // ...and BUTTON drags in the mover-prediction half, which must be shut
    // off just as firmly: CSQC_PredictUse (cl_brushsync.qc:1001-1010) would
    // otherwise run CSQC_PredictMoverActivate and slide a brush the server
    // never budges — and a locally-predicted move the server never corrects
    // slides FOREVER, which is the failure cl_brushsync.qc:896-901 describes.
    //
    // door_has_master is the only lever the send function offers: for a
    // BUTTON it is the sole input to the `predict_block` byte CSQC reads as
    // door_locked (sv_brushsync.qc:452-457), and nothing else in the tree
    // reads the field (grep: sv_brushsync.qc:442/454 only).  Setting it is
    // honest as well as necessary — this class does carry a master gate.
    self.door_has_master = TRUE;

    // Belt and braces for the same thing.  If a future edit ever let the
    // prediction run, CSQC_MoverPredict bails to a zero-distance setorigin
    // when the destination equals the origin or speed is 0
    // (cl_brushsync.qc:880-885), so the worst case stays a no-op instead of
    // an unstoppable slide.  mover_state is left at its default 0
    // (MOVER_STATE_BOTTOM, sh_weapons.qc:793), which is the resting state the
    // rest of the client code tests for.
    self.pos1  = self.origin;
    self.pos2  = self.origin;
    self.speed = 0;

    // The cost of BUTTON over STATIC: when SF_BTARGET_USE is CLEAR, the
    // server's +use falls through to the weapon-pickup / cone paths while
    // CSQC_PredictUse returns at the door_locked test, so a weapon grab aimed
    // past this brush is not predicted and lands a round-trip late.  With the
    // flag SET — the FGD default — client and server agree exactly, because
    // the server also stops at this entity.  Cosmetic either way, and the
    // three break-path defects above are not.

    // buttons.cpp:1268-1276 — ObjectCaps() ORs in FCAP_IMPULSE_USE only when
    // SF_BTARGET_USE is set.  Without the bit the entity is not in the
    // player's use search at all in HL, so a press aimed at it must fall
    // THROUGH to whatever is behind rather than being silently eaten;
    // SV_UseTarget returns TRUE for anything it dispatches, and the trace loop
    // and the cone fallback both stop at the first handled entity
    // (sv_use.qc).  `.use_passthrough` is this tree's spelling of exactly that
    // contract: SV_UseTarget reports NOT-HANDLED without calling .use, while
    // trigger chains still reach .use normally.
    //
    // This used to borrow `onlytrigger` for the job.  It no longer can:
    // onlytrigger turned out to be a func_breakable key ("only a trigger can
    // BREAK it") that had been misread as an activation gate, and correcting
    // that would have silently taken this contract with it.  See the note on
    // both fields in sv_customdefs.qc.
    if (!(self.spawnflags & SF_BTARGET_USE))
        self.use_passthrough = TRUE;

    // buttons.cpp:1252-1253 — START_ON presets the state bit and fires nothing.
    if (self.spawnflags & SF_BTARGET_ON)
        self.frame = 1;
};

// ============================================================
//  trigger_monsterjump
//  HALF-LIFE SDK (C:/msys64/home/Lex/halflife), all read on disk:
//  dlls/triggers.cpp:596-653  CTriggerMonsterJump — class, Spawn, Think, Touch
//  dlls/triggers.cpp:607-623  Spawn: SetMovedir -> InitTrigger -> speed=200, m_flHeight=150, "if target
//  dlls/triggers.cpp:626-631  Think: solid=SOLID_NOT + SetThink(NULL) — the "!!!UNDONE" self-disable
//  dlls/triggers.cpp:633-653  Touch: FL_MONSTER gate, origin.z+=1, clear FL_ONGROUND, velocity = movedi
//  dlls/triggers.cpp:545-556  CBaseTrigger::InitTrigger (SOLID_TRIGGER / MOVETYPE_NONE / SET_MODEL / EF
// ============================================================

//
//  sv_th_entities.qc  —  trigger_monsterjump
//
//  A brush volume that launches any monster touching it.  Half-Life SDK:
//  dlls/triggers.cpp:596-653 (CTriggerMonsterJump), FGD: sven-coop.fgd:6521.
//
//  Compile order: anywhere AFTER server/sv_push.qc (SetMovedir), sv_triggers.qc
//  (IsMasterTriggered, .master), sv_ai_defs.qc (.ai_movemode) and
//  shared/sh_weapon_standard.qc (DEAD_NO).  The intended slot — after the
//  sv_goldsrc_* files — satisfies all four.
//
//  ---------------------------------------------------------------------------
//  WHAT THE CORPUS ACTUALLY SHIPS, because it decides two of the calls below.
//  Five placements across the Sven mount, entity lumps read straight out of the
//  .bsp files:
//
//    svencoop1  *4   angles "0 180 0"  speed 80   height 100
//    svencoop1  *6   angles "0 0 0"    speed 60   height 128   spawnflags 3
//    hl_c06     *30  angles "0 61 0"   speed 10   height 128   delay 0
//    hl_c06     *32  angles "0 120 0"  speed 10   height 128   delay 0
//    th_ep2_00  *258 angles "0 0 0"    speed 300  height 32
//
//  EVERY ONE OF THEM SETS BOTH KEYS, AND STOCK HALF-LIFE THROWS BOTH AWAY.
//  CTriggerMonsterJump::Spawn does `pev->speed = 200; m_flHeight = 150;`
//  (triggers.cpp:613-615) unconditionally, and Spawn runs after the keyvalue
//  parse — "speed" arrives through the entvars auto-parse and "height" is not
//  read at all (CBaseToggle::KeyValue, subs.cpp:360-384, handles only lip /
//  wait / master / distance).  So on stock HL these are dead keys and every
//  monsterjump in the game is identical.  Porting that bug would give
//  th_ep2_00's 300/32 launch and hl_c06's 10/128 the same trajectory, which is
//  not what either mapper drew.  Sven's FGD settles it: it documents its OWN
//  defaults, 40 and 128 (sven-coop.fgd:6524-6525), which only means anything if
//  the keys are read.  So the keys are honoured, and 200/150 survives as the
//  no-key fallback because that is the number stock HL would have produced.  No
//  corpus entity exercises it.
//
//  BOTH KEYS ARE VELOCITIES, NOT DISTANCES, however "height" reads.  HL:
//      velocity   = movedir * speed;
//      velocity_z = velocity_z + m_flHeight;      (triggers.cpp:650-651)
//  so height 128 at sv_gravity 800 is an apex of 128*128/1600 = ~10 units and
//  2*128/800 = ~0.32 s of air.  These are hops that clear a rail, not vaults —
//  and because the horizontal reach is speed * airtime, "speed" only buys
//  distance in proportion to "height".  th_ep2_00's loud-looking 300/32 is
//  0.08 s of air and therefore ~24 units of travel, not the ~120 that reading
//  "speed 300" alone suggests.  The one placement that actually moves a monster
//  any distance is the 200/150 no-key fallback: 0.375 s, ~75 units.
//
//  ---------------------------------------------------------------------------
//  THE ONE PLACE THIS IS DELIBERATELY NOT BUG-FOR-BUG, same policy as
//  sv_momentary.qc:12.  HL's Touch ends with `pev->nextthink = gpGlobals->time`,
//  and the Think it schedules is:
//
//      pev->solid = SOLID_NOT;   // kill the trigger for now !!!UNDONE
//      UTIL_SetOrigin(...); SetThink(NULL);      (triggers.cpp:626-631)
//
//  i.e. the volume goes non-solid after the FIRST monster jumps and, because
//  SetThink(NULL) leaves nothing to re-arm it, stays dead for the rest of the
//  map unless a trigger fires ToggleUse.  Valve's own comment calls it unfinished.
//  It is not portable here: Sven's FGD gives this class base(Angles, ZHLTbmodel)
//  with NO Targetname, so a Sven mapper cannot even name the entity, so ToggleUse
//  is unreachable, so a self-disabling volume would be permanently dead after one
//  monster — on co-op maps whose whole premise is the same route walked by
//  successive waves.  The volume therefore stays live, and the only job that
//  self-disable actually did — "do not re-launch the same monster on every frame
//  it overlaps" — is done by a per-monster cooldown instead.
//
//  That cooldown is NOT decoration.  A monster relinks with touch_triggers set
//  on every physics frame it spends airborne (WPhys_Physics_Step calls
//  World_LinkEdict(w, ent, true) straight after FlyMove, sv_phys.c:1548), so
//  without it the trigger's touch would fire again on the very next frame,
//  while the monster is still rising through the volume it was launched from,
//  and stack a second launch onto the first.
//
//  ---------------------------------------------------------------------------
//  HOW THE PUSH LANDS ON THIS MOD'S AI.  A monster here is MOVETYPE_STEP with no
//  FL_FLY, and sv_ai_move.qc:7-27 is explicit about what that means: the step
//  physics runs gravity + FlyMove only while the entity is NOT on the ground, so
//  writing .velocity on a grounded monster moves it exactly nowhere.  Clearing
//  FL_ONGROUND is what hands the monster to the physics, and lifting it a unit
//  first stops the ground trace re-grounding it on the same frame.  That is
//  precisely HL's sequence (triggers.cpp:642-647) and precisely what this tree's
//  own launch does — Headcrab_Event, mon_headcrab.qc:127-128.
//
//  Two consequences that stock HL does not have:
//
//   1. AIMODE_FLY / AIMODE_SWIM monsters carry FL_FLY, and the step physics
//      gates its ENTIRE integration on that flag —
//          if (fl & (FL_ONGROUND | FL_FLY)) freefall = false;   sv_phys.c:1537
//      — so with FL_FLY set there is no gravity and no FlyMove at all; they move
//      only when the AI calls setorigin.  Writing .velocity on one is a no-op
//      that leaves a stale field behind, and clearing FL_FLY to "fix" it would
//      just drop the flyer out of the air.  AIMODE_STATIC is MOVETYPE_NONE
//      (sv_ai_core.qc:2492) and has no physics at all.  So only AIMODE_GROUND is
//      launched.  HL's flyers were MOVETYPE_FLY and took the push; ours cannot.
//
//   2. AI_StopMoving zeroes velocity_x and velocity_y (sv_ai_move.qc:380-387),
//      and TASK_STOP_MOVING opens very nearly every schedule in sv_ai_sched.qc.
//      A monster that changes schedule mid-flight therefore loses the whole
//      horizontal half of its jump and drops straight down — and a chasing
//      monster WILL change schedule, because AI_StepToward refuses outright
//      while airborne (sv_ai_move.qc:222-223), which feeds ai_stuck and returns
//      AIMOVE_BLOCKED after AI_STUCK_TICKS.  That is exactly the monster
//      trigger_monsterjump exists to help across a gap.  A small guard entity
//      therefore watches the flight and puts the horizontal velocity back if it
//      is wiped; it touches velocity_z never, so gravity still owns the arc.
//

// ---------------------------------------------------------------------------
// From earlier compile units — nothing here is redefined:
//   SetMovedir()         server/sv_push.qc:14        angles -> .movedir, with
//                                                    HL's '0 -1 0' up / '0 -2 0'
//                                                    down cases (subs.cpp:298)
//   IsMasterTriggered()  server/sv_triggers.qc:165
//   .master              server/sv_triggers.qc:31
//   sub_use_type         server/sv_doors.qc:78       (USE_* in sv_customdefs.qc:747)
//   DEAD_NO              shared/sh_weapon_standard.qc:610
//   .speed               shared/sh_customdefs.qc:302
//   .ai_movemode         server/sv_ai_defs.qc:672
//   .movedir             sv_defs.qc:375
// ---------------------------------------------------------------------------

// "height" (sven-coop.fgd:6525).  Already declared by sv_func_tracktrain.qc:58
// and sv_func_trackautochange.qc:66, both of which compile above us; restated
// here for the same reason sv_trigger_hurt.qc:29 restates .dmg — an identical
// re-declaration shares storage and is free, and the BSP epair parser silently
// drops keys with no field, so a reader can see the key is really claimed.
.float height;

// Per-monster relaunch cooldown.  Replaces HL's self-disabling Think (see the
// header): long enough to cover any flight in the corpus — the biggest is
// height 128, which is 0.32 s of air at sv_gravity 800 — so a monster is never
// re-launched while still rising through the volume it was launched from.
const float MJ_RELAUNCH_WAIT = 0.5;

// Flight guard.  MJ_GUARD_TICK is a positive increment on purpose and must stay
// one: sv_gameplayfix_multiplethinks defaults to 1, so WPhys_RunThink loops
// while nextthink <= physicstime + host_frametime (sv_phys.c:234-240), and a
// think that re-arms with `nextthink = time` never terminates. Any positive step
// does. 1/64 s matches the fast-think rate already used at sv_physprop.qc:1242.
const float MJ_GUARD_TICK  = 0.0156;
const float MJ_GUARD_LIFE  = 2.0;   // hard ceiling; a jump off a ledge still fits
const float MJ_GUARD_PROBE = 16;    // "is the stop real?" trace length, units

.entity mj_guard;     // on the monster: its live guard, so it only ever has one
.vector mj_wantvel;   // on the guard: horizontal launch velocity to re-assert
.float  mj_expire;    // on the guard
.float  mj_next;      // on the monster: relaunch cooldown

// ---------------------------------------------------------------------------
// MJ_Launchable — the one liveness test, used by BOTH the touch and the guard so
// they cannot drift apart.
//
// BOTH HALVES ARE LOAD-BEARING, and this tree has already been bitten once by
// getting it wrong: sv_ai_core.qc:231-243 spells it out.  AI_Died ports HL's
// BecomeDead (combat.cpp:518-532) faithfully, which means a corpse is handed
// max_health/2 health as a gib pool and is clamped to a MINIMUM of 1
// (sv_ai_core.qc:2209-2213).  A `health <= 0` test therefore NEVER fires for a
// body in this mod — a barney corpse sits at ~17 health — and AI_Died does not
// clear FL_MONSTER either, so a corpse otherwise satisfies every gate below.
// deadflag is the half that actually reports death; HL's own IsAlive
// (cbase.h:204) is `deadflag == DEAD_NO && health > 0`, both halves, for exactly
// this reason.  The health test is kept for the one frame between a fatal hit
// and AI_Died running.
// ---------------------------------------------------------------------------
float(entity m) MJ_Launchable =
{
    if (!m || wasfreed(m))
        return FALSE;
    if (!(m.flags & FL_MONSTER))
        return FALSE;
    if (m.deadflag != DEAD_NO || m.health <= 0)
        return FALSE;
    // See header note 1: only a MOVETYPE_STEP-without-FL_FLY monster can be
    // moved by writing .velocity.  AI_Died clears FL_FLY from a dead flyer so it
    // falls (sv_ai_core.qc:2236-2238) but leaves ai_movemode alone, which is one
    // more reason the deadflag test above has to come first.
    if (m.ai_movemode != AIMODE_GROUND)
        return FALSE;
    return TRUE;
};

// ---------------------------------------------------------------------------
// Flight guard.
//
// Restores velocity_x/y after AI_StopMoving wipes them, and NOTHING else: it
// never writes velocity_z, so the arc, the landing and the FL_ONGROUND that ends
// the guard all stay with the engine.
//
// The (0,0) test is AI_StopMoving's signature, not a general "has it stopped"
// test, because the two axes are zeroed together and z is left alone there too.
// A head-on wall hit reads the same way, though, when the launch was axis-
// aligned — svencoop1's *6 and th_ep2_00's *258 both point straight down +X —
// so before restoring anything the guard traces the launch direction and gives
// up if the way is genuinely blocked.  Without that a monster shoved into a wall
// would be re-shoved into it 64 times a second for the whole guard window.
// ---------------------------------------------------------------------------
void() monsterjump_guard_think =
{
    entity m;
    vector probe;

    m = self.owner;

    // Flight over, monster gone or dead, or the guard timed out.  The death case
    // matters: AI_Died runs AI_StopMoving (sv_ai_core.qc:2166) and SCHED_DIE
    // opens with TASK_STOP_MOVING again (sv_ai_sched.qc:586-587), so without the
    // test in MJ_Launchable this guard would spend two full seconds re-shoving a
    // body sideways at 64 Hz against the schedule that is trying to lay it down.
    // A corpse that keeps being shoved sideways is not a corpse.
    if (!MJ_Launchable(m) || (m.flags & FL_ONGROUND) || time >= self.mj_expire)
    {
        if (m && !wasfreed(m) && m.mj_guard == self)
            m.mj_guard = world;
        remove(self);
        return;
    }

    self.nextthink = time + MJ_GUARD_TICK;

    // Still carrying horizontal motion: nothing has interfered.
    if (m.velocity_x != 0 || m.velocity_y != 0)
        return;

    probe = m.origin + normalize(self.mj_wantvel) * MJ_GUARD_PROBE;
    tracebox(m.origin, m.mins, m.maxs, probe, MOVE_NORMAL, m);
    if (trace_fraction < 1)
    {
        // The stop was geometry, not the schedule.  Stand down for good.
        m.mj_guard = world;
        remove(self);
        return;
    }

    m.velocity_x = self.mj_wantvel_x;
    m.velocity_y = self.mj_wantvel_y;
};

// ---------------------------------------------------------------------------
// Touch — CTriggerMonsterJump::Touch, triggers.cpp:633-653.
// ---------------------------------------------------------------------------
void() trigger_monsterjump_touch =
{
    vector jump;
    vector flat;
    entity g;

    // triggers.cpp:637 — monsters only, plus this tree's liveness and locomotion
    // gates (see MJ_Launchable).  Players never carry FL_MONSTER in this tree
    // either (sv_ai_core.qc:248 tests classname "player" separately), so the
    // FL_MONSTER half is the same filter HL applies and needs no player case.
    //
    // ONE DELIBERATE DIFFERENCE FROM HL, and it is the deadflag half: HL keeps
    // FL_MONSTER on a corpse and its Touch has no liveness test, so a stock
    // volume throws bodies.  It gets away with that because its Think disables
    // the volume after the first launch; ours stays live for the co-op reason in
    // the header, so the same permissiveness would mean every body that ever
    // lands in the volume gets flung, repeatedly, for the rest of the map.
    if (!MJ_Launchable(other))
        return;

    if (time < other.mj_next)
        return;

    // sven-coop.fgd:6523 adds a `master` this class does not have in HL.  No
    // corpus placement sets one, so this is a courtesy gate; `other` is passed
    // as the activator because it is the entity being acted on.
    if (!IsMasterTriggered(self.master, other))
        return;

    // Latched here, before the launch, because the monster relinks with
    // touch_triggers set on every airborne physics frame (World_LinkEdict(w,
    // ent, true) at sv_phys.c:1548) — so this touch fires again on the very next
    // frame while the monster is still inside the volume.  With the cooldown
    // already stamped that re-entry is a no-op instead of a second launch
    // stacked on the first.  (The setorigin below is NOT itself a re-entry
    // hazard: PF_setorigin calls World_LinkEdict with touch_triggers FALSE,
    // pr_cmds.c:2963.)
    other.mj_next = time + MJ_RELAUNCH_WAIT;

    jump   = self.movedir * self.speed;
    jump_z = jump_z + self.height;

    // triggers.cpp:642-647, and mon_headcrab.qc:127-128 for the same two lines
    // in this tree: come off the ground explicitly, then lift clear so the step
    // physics cannot re-ground the monster on the frame it launched.
    other.flags = other.flags - (other.flags & FL_ONGROUND);
    setorigin(other, other.origin + '0 0 1');
    other.velocity = jump;

    // Nothing horizontal to protect (angles '0 -1 0' / '0 -2 0', or speed 0):
    // gravity owns the whole trajectory and no guard is wanted.
    flat   = jump;
    flat_z = 0;
    if (flat == '0 0 0')
        return;

    g = other.mj_guard;
    if (!g || wasfreed(g))
    {
        g = spawn();
        g.classname    = "monsterjump_boost";
        g.owner        = other;
        g.think        = monsterjump_guard_think;
        other.mj_guard = g;
    }
    g.mj_wantvel = flat;
    g.mj_expire  = time + MJ_GUARD_LIFE;
    g.nextthink  = time + MJ_GUARD_TICK;
};

// ---------------------------------------------------------------------------
// CBaseTrigger::ToggleUse, triggers.cpp:897-911.  Unreachable from Sven's editor
// (the class has no Targetname base) but reachable from a hand-edited .ent or a
// Half-Life-era .bsp, and it costs nothing.
//
// USE_ON / USE_OFF are honoured rather than always toggling, for the reason
// spelled out at sv_push.qc:181-185: a pair of buttons wired to enable and
// disable would otherwise fight each other.  The old "unset" value was 0, which
// collided with USE_OFF; it is USE_UNSET (-1) now (sv_customdefs.qc), so the
// USE_OFF branch below is reachable from a map and anything unset still falls
// through to the toggle.
//
// HL's `force_retouch` has no QC equivalent; setorigin relinks the volume but
// passes touch_triggers FALSE (pr_cmds.c:2963), so a monster already standing
// inside jumps as soon as it next moves rather than the instant the volume
// comes back.
// ---------------------------------------------------------------------------
void() trigger_monsterjump_use =
{
    float wanted_on;

    if (sub_use_type == USE_ON)
        wanted_on = TRUE;
    else if (sub_use_type == USE_OFF)
        wanted_on = FALSE;
    else
        wanted_on = (self.solid == SOLID_NOT);

    self.solid = wanted_on ? SOLID_TRIGGER : SOLID_NOT;
    setorigin(self, self.origin);
};

/*QUAKED trigger_monsterjump (.5 .5 .5) ?
Brush volume that launches monsters standing in it.  Players are never affected,
and neither are corpses.

"angles"      launch direction ('0 -1 0' = straight up, '0 -2 0' = straight down)
"speed"       launch velocity along that direction, u/s (default 200)
"height"      EXTRA UPWARD velocity added on top, u/s — not a distance (default 150)
"master"      upstream multisource / game_team_master gate
"targetname"  if set, the volume spawns switched off and .use toggles it

No spawnflags.  svencoop1's second volume ships spawnflags 3 and hl_c06's two
ship "delay" "0"; HL's CTriggerMonsterJump reads neither, and neither does this.
*/
void() trigger_monsterjump =
{
    // No brush, no volume.  Same guard and same reason as sv_trigger_hurt.qc:200.
    if (!self.model)
    {
        remove(self);
        return;
    }

    // BEFORE setmodel, exactly as trigger_push does (sv_push.qc:217/231):
    // SetMovedir consumes .angles and zeroes it, so the engine does not then try
    // to rotate the bmodel by a value that was never a rotation.  Note HL calls
    // this unconditionally here (triggers.cpp:609), ahead of InitTrigger, whose
    // own "an angle of 0 means no restrictions, use 360" substitution
    // (triggers.cpp:547-549) is therefore skipped — angles "0 0 0" yields movedir
    // '1 0 0', which is what th_ep2_00's *258 and svencoop1's *6 are actually
    // asking for.  Do NOT copy trigger_push's '0 360 0' line here.
    SetMovedir();

    setmodel(self, self.model);
    // EF_NODRAW and not modelindex 0: the volume's mins/maxs have to stay valid
    // for SOLID_TRIGGER overlap.  sv_trigger_hurt.qc:206-213 has the long version.
    self.effects  |= EF_NODRAW;
    self.movetype  = MOVETYPE_NONE;
    self.solid     = SOLID_TRIGGER;
    self.touch     = trigger_monsterjump_touch;
    self.use       = trigger_monsterjump_use;

    // triggers.cpp:614-615.  Fallbacks only — see the header: HL assigns these
    // over whatever the map said, we assign them only when the map said nothing.
    if (!self.speed)
        self.speed = 200;
    if (!self.height)
        self.height = 150;

    // triggers.cpp:617-622 — "if targetted, spawn turned off".
    if (self.targetname != "" && self.targetname)
    {
        self.solid = SOLID_NOT;
        setorigin(self, self.origin);
    }
};

// ============================================================
//  trigger_autosave
//  SDK (on disk, read directly):
//  - C:/msys64/home/Lex/halflife/dlls/triggers.cpp:1957-1962  class CTriggerSave : public CBaseTrigger
//  - C:/msys64/home/Lex/halflife/dlls/triggers.cpp:1963       LINK_ENTITY_TO_CLASS( trigger_autosave, C
//  - C:/msys64/home/Lex/halflife/dlls/triggers.cpp:1965-1975  Spawn(): `if (g_pGameRules->IsDeathmatch(
//  - C:/msys64/home/Lex/halflife/dlls/triggers.cpp:1977-1989  SaveTouch(): master gate, player-only, th
//  - C:/msys64/home/Lex/halflife/dlls/multiplay_gamerules.cpp:284-287  CHalfLifeMultiplay::IsDeathmatch
// ============================================================

// ---------------------------------------------------------------------------
// trigger_autosave — spawned and immediately removed.  There is no behaviour
// here to port, and the SDK's own delete path is the closest match.
//
// dlls/triggers.cpp:1963 links this classname to CTriggerSave, whose Spawn
// (:1965) opens with
//
//     if ( g_pGameRules->IsDeathmatch() )
//     {
//         REMOVE_ENTITY( ENT(pev) );        // :1969
//         return;
//     }
//
// and only reaches InitTrigger()/SetTouch() below that.  Wherever the
// multiplayer rules are installed the edict is deleted before it is ever given
// a touch — CHalfLifeMultiplay::IsDeathmatch (multiplay_gamerules.cpp:284)
// returns TRUE unconditionally — which is the same shape
// CTriggerEndSection::Spawn uses at triggers.cpp:2019-2024.  This mod is always
// multiplayer, the branch sv_chargers.qc:66 already picks at the same kind of
// fork.
//
// No claim is made that HL co-op takes that branch, because the SDK does not
// support one: InstallGameRules (gamerules.cpp:317) forks on
// gpGlobals->deathmatch ALONE, so a deathmatch-0 co-op server gets
// CHalfLifeRules, whose IsDeathmatch (singleplay_gamerules.cpp:57) is FALSE and
// the entity survives — and Sven's rules are not the SDK's at all.
//
// It does not matter, because the surviving path is empty here too.  SaveTouch
// (:1977-1989) master-gates, rejects non-players, then SetTouch(NULL),
// UTIL_Remove(this) and SERVER_COMMAND("autosave\n") at :1988: one-shot,
// self-deleting, and its entire payload is a single-player savegame request.  A
// dedicated FTE server has no such command, and this mod already replaced the
// concept rather than emulating it — co-op progression is point_checkpoint /
// player_respawn_zone (sv_checkpoint.qc:290 / :420).  Both maps that carry a
// trigger_autosave already place both (th_ep1_05: 1 + 1, th_ep2_03: 2 + 1,
// counted in their entity lumps), so wiring this class into the checkpoint
// system would not restore lost progression, it would double-fire a checkpoint
// that is already there.  Terminal, empty, redundant; the only open question is
// what happens to the edict.
//
// Writing the class down at all is what stops the entity lump falling through
// to SV_OnEntityNoSpawnFunction (sv_goldsrc_compat.qc:134), which logs
// `no spawn function for "trigger_autosave" — kept as inert relay` and then
// keeps an edict alive with a .use nothing will ever fire.  Same reason
// light_spot / light_environment are written out at sv_goldsrc_compat.qc:174.
//
// remove() rather than this tree's inert-relay default (sv_goldsrc_compat.qc:130-133:
// a severed chain on a campaign map is a soft-lock) is safe for this class in
// particular:
//   - HalfLife.fgd:2482 is `@SolidClass base(Targetname) = trigger_autosave`
//     with a `master` key and NO `target` key.  Even on the surviving path it is
//     a chain TERMINATOR that runs a console command; it can never be a link in
//     the middle of anything.  (`master` is therefore dropped deliberately: it
//     gates only the savegame call that cannot happen.)
//   - Both corpus placements — th_ep1_05 ("*253") and th_ep2_03 ("*142") — ship
//     exactly `classname` + `model`: no targetname, no master, no target, so
//     nothing can address them either.
// Deleting hands the edict back and leaves the brush submodel unreferenced,
// which is precisely what HL does with it.  remove() from inside a spawn
// function is the shape func_monsterclip already uses
// (sv_goldsrc_compat.qc:222), and the engine tolerates it: after
// PR_DoSpawnInitialEntity runs the spawn function, the only further use of the
// edict is the post-spawn hook, which returns early on ereftype == ER_FREE
// (engine/server/pr_cmds.c:1899-1903).
// ---------------------------------------------------------------------------
void() trigger_autosave =
{
    remove(self);
};

// ============================================================
//  player_loadsaved
//  SDK (C:/msys64/home/Lex/halflife), all read on disk:
//  - dlls/player.cpp:4953-5044 — class CRevertSaved, LINK_ENTITY_TO_CLASS at :4980. KeyValue :4990-5014
//  - dlls/player.cpp:4965-4973 — the inline accessors proving duration/holdtime alias pev->dmg_take / p
//  - dlls/effects.cpp:1962-1970 — CFade::Use sets FFADE_OUT exactly when SF_FADE_IN is absent. This is 
//  - dlls/util.cpp:757-771 UTIL_ScreenFadeAll; :726-735 UTIL_ScreenFadeBuild, where FixedUnsigned16(t, 
//  - dlls/util.cpp:936-948 UTIL_ShowMessageAll -> gmsgHudText, i.e. a titles.txt KEY resolved client-si
// ============================================================

// ===========================================================================
//  player_loadsaved  -  stock Half-Life "you failed, reload" point entity
// ===========================================================================
//
//  CRevertSaved, dlls/player.cpp:4953-5044.  SDK behaviour, verbatim:
//
//      Use()          UTIL_ScreenFadeAll(rendercolor, duration, holdtime,   // util.cpp:757
//                                        renderamt, FFADE_OUT);            // player.cpp:5018
//                     nextthink = time + messagetime;  think = MessageThink
//      MessageThink() UTIL_ShowMessageAll(message);           // util.cpp:936
//                     next = loadtime - messagetime;
//                     if (next > 0) { nextthink = time + next;
//                                     think = LoadThink; }
//                     else            LoadThink();
//      LoadThink()    if (!gpGlobals->deathmatch) SERVER_COMMAND("reload\n");
//
//  Keys, sven-coop.fgd:5302-5311 - base(Targetname) ONLY, so the editor
//  offers no `target` and no spawnflags:
//      duration     fade time,           default "2"   (aliases pev->dmg_take)
//      holdtime     hold at full,        default "0"   (aliases pev->dmg_save)
//      renderamt    fade alpha,          default 255
//      rendercolor  fade colour,         default "0 0 0"
//      messagetime  delay before title,  default "0"
//      message      titles.txt key
//      loadtime     delay before reload, default "0"
//
//  duration/holdtime aliasing dmg_take/dmg_save (player.cpp:4965-4966) are the
//  SAME two pev slots CFade uses (effects.cpp:1920-1921), which is why both
//  halves of this entity map 1:1 onto the tree's existing env_fade/env_message
//  senders and nothing new was written for either.
//
//  ---------------------------------------------------------------------------
//  MEASURED CORPUS - every player_loadsaved on the Sven mount
//  ---------------------------------------------------------------------------
//  Dumped from the BSP entity lumps of every map in svencoop/maps.  Exactly six
//  placements in four maps.  "fired by" was resolved by scanning every key/value
//  pair in each lump, INCLUDING multi_manager key-names (where the target is the
//  KEY and the delay is the value, with any "#nn" disambiguator stripped):
//
//   hl_c10    dead_loadsave      duration 2.  Fired by multi_manager
//                                "deadend_old" at t+8 - but NOTHING in the lump
//                                references deadend_old, so the chain is dead.
//   hl_c13_a1 c3a2_restart       duration 2 holdtime 15 messagetime 4
//                                loadtime 5 message GAMEOVER.  Fired by
//                                monster_scientist "scientist_c3a2" via
//                                TriggerTarget + TriggerCondition 2 (death);
//                                killtargeted by func_door
//                                "retinal_scanner_door" once you are through.
//                                THE ONLY ONE REACHABLE FROM MAP DATA.
//   hl_c13_a4 c3a2d_load___      duration 2, every other key absent.  ORPHAN.
//   hl_c13_a4 c3a2d_restart___   duration 2 holdtime 15 messagetime 2
//                                loadtime 10 GAMEOVER.  ORPHAN.
//   hl_c13_a4 c3a2d_restart2___  duration 1 holdtime 30 messagetime 2
//                                loadtime 10 GAMEOVER.  ORPHAN.
//   th_ep3_06 pilot_dead         duration 3 holdtime 10 messagetime 3
//                                loadtime 9 message KILLPILOT.  Referenced ONLY
//                                as trigger_relay "kill_loadsave"'s killtarget;
//                                nothing fires it, and nothing under
//                                svencoop/scripts names it either.  ORPHAN.
//
//  Two consequences worth writing down, because they set the blast radius:
//
//   (a) The one reachable placement needs monster TriggerTarget/TriggerCondition,
//       which THIS TREE DOES NOT IMPLEMENT (sv_multi_manager.qc:490 mentions the
//       key names in passing and nothing reads them).  So on today's build no
//       player_loadsaved on the mount can fire at all.  This entity exists so
//       the classname spawns instead of erroring, and so it behaves correctly
//       once those monster keys land.
//   (b) hl_c13_a4's `c3a2d_load___` has loadtime 0 - an instant, unannounced map
//       restart if it ever fired.  It is an orphan, so it cannot.  No guard
//       against that specific case is load-bearing today.
//
//  ---------------------------------------------------------------------------
//  THE MULTIPLAYER DEGENERATE, AND WHY IT IS A MAP RESTART
//  ---------------------------------------------------------------------------
//  There is no savegame here, so `reload` has no meaning.
//
//  1. Valve already made half the decision.  LoadThink is gated on
//     !gpGlobals->deathmatch (player.cpp:5040), and the DMC and Ricochet builds
//     ship the class byte-for-byte identical (dmc/dlls/player.cpp:4783,
//     ricochet/dlls/player.cpp:4747).  So in every multiplayer build Valve
//     shipped, THE FADE AND THE MESSAGE STILL HAPPEN and only the reload is
//     dropped.  Both halves are implemented here exactly, not approximated.
//
//  2. Doing only that is not survivable on hl_c13_a1, the one reachable case:
//     the retinal-scanner scientist is dead, the door can never open, the map
//     can never be finished - and every player sits blind behind a black
//     GAMEOVER screen for duration+holdtime = 17 seconds first.
//
//  3. Sven Co-op's own campaign porters answered this exact question.
//     scripts/maps/hunger/leveldead_loadsaved.as (included by
//     hunger/theyhunger.as:14) and scripts/maps/hlsp/hl_c11_a3.as are the same
//     four lines:
//
//         if ( g_SurvivalMode.IsEnabled() ) g_SurvivalMode.EndRound();
//         else g_EntityFuncs.FireTargets( "leveldead_loadsaved", ... );
//
//     and the entity behind that name in hl_c11_a3.bsp and th_ep3_07.bsp is a
//     trigger_changelevel with keep_inventory 1 and `map` set to THE MAP IT IS
//     ALREADY IN.  A hand-authored restart-this-level standing in for the save.
//
//  So: fade and message exactly as the SDK does them, then at `loadtime`
//  restart the current map via ChangeLevel_Issue(mapname) - the same call and
//  the same argument sv_main.qc:2579-2585 already uses to reload the level it
//  is on when the map cycle file is empty.
//
//  Two escape hatches:
//    - A map that provides a FIRABLE chain named "leveldead_loadsaved" (Sven's
//      convention above) gets that fired instead; the author's recovery outranks
//      ours.  That name is NOT exclusive: in hl_c11_a3 it is carried by the
//      trigger_changelevel AND by two monster_headcrabs, which is why the probe
//      below screens for an entity the chain-walker will actually fire rather
//      than for the mere existence of the name.
//    - `sv_player_loadsaved_restart 0` drops the recovery entirely, leaving
//      precisely Valve's deathmatch branch: fade + message, nothing else.
//
//  ---------------------------------------------------------------------------
//  Compile position: after the sv_goldsrc_* files, therefore after
//  sv_triggers.qc (sv_progs.src:153), sv_env_hud.qc (:171) and
//  sv_trigger_changelevel.qc (:182).  Everything called here is DEFINED above,
//  so nothing is forward-declared - re-declaring an already-defined function in
//  fteqcc re-emits the global as an empty stub and every call silently returns
//  0 (the hazard documented at sv_checkpoint.qc:41-46).
//

// ---------------------------------------------------------------------------
// Fields.
//
// duration / holdtime  already declared in sv_env_hud.qc:20-21 (env_fade reads
//                      the same two keys, and CFade/CRevertSaved really do share
//                      pev->dmg_take / pev->dmg_save).
// renderamt            already declared in sv_breakable.qc:147.
// rendercolor          already declared in sv_brushsync.qc:36.
// message              already declared in sv_goldsrc_compat.qc:33.
// target/targetname/delay/killtarget are universal.
//
// Only these are new to the tree.  A plain field declaration is all that is
// needed: the engine binds BSP keys straight onto same-named fields, which is
// how env_fade's `duration` and `holdtime` already arrive.
// ---------------------------------------------------------------------------
.float  messagetime;    // seconds after firing before the title shows
.float  loadtime;       // seconds after firing before the "reload"

// Activator captured at .use time.  CRevertSaved's thinks take no activator
// (player.cpp:5024/5038 are plain EXPORT thinks), but this tree's SUB_UseTargets
// wants one and the global `activator` will have moved on by the time a think
// running `loadtime` seconds later fires.  Same capture SUB_DelayedFire makes
// into .delayed_activator (sv_triggers.qc:74).
.entity pls_activator;

// GoldSrc's screen-fade wire format is 4.12 fixed point - UTIL_ScreenFadeBuild
// runs both times through FixedUnsigned16(t, 1<<12) (util.cpp:728-729), which
// saturates at 65535/4096 = 15.999s.  So hl_c13_a4's `holdtime 30` is ALREADY
// ~16s inside GoldSrc; clamping here reproduces the engine rather than
// truncating the map.  Same clamp env_fade_use applies (sv_env_hud.qc:237-241).
const float PLS_FADE_MAX_SECONDS = 16;

// Flag word for EnvFade_SendAll.  This tree's wire flags are env_fade's
// SPAWNFLAG bits (ENV_FADE_FROM = 1 = "fade FROM the colour"; client branch at
// cl_env_hud.qc:914), which are the INVERSE sense of HL's FFADE_* bits.
// CRevertSaved passes FFADE_OUT (player.cpp:5018), and CFade sets FFADE_OUT
// exactly when SF_FADE_IN is absent (effects.cpp:1965-1966) - i.e. fade TO the
// colour and hold.  In this tree's vocabulary that is zero.
const float PLS_FADE_TO_COLOUR = 0;

// Sven's documented targetname for a map-authored "the level is dead" chain.
const string PLS_MAP_RECOVERY_NAME = "leveldead_loadsaved";

// Once per map.  Three player_loadsaved in one BSP (hl_c13_a4) or a re-fire of
// the same one must not stack a second changelevel - the same latch
// trigger_changelevel keeps in .changelevel_fired, global here because the
// entity that fires second is a different edict.
float pls_recovery_issued;

// Prototypes for this file's own two thinks.  Declaring a function DEFINED
// LATER IN THE SAME FILE is the ordinary QC prototype and is safe; the hazard
// is only re-declaring something an earlier compile unit already defined.
void() player_loadsaved_messagethink;
void() player_loadsaved_loadthink;

// ---------------------------------------------------------------------------
// Is the map-restart recovery enabled?
//
// Read with cvar_string, not cvar(), so "never set" and "explicitly 0" are
// distinguishable: FTE's PF_Cvar_FindOrGet creates an unknown QC cvar with the
// default string "" (engine/common/pr_bgcmd.c:1859-1876), so an empty result
// means the server has not spoken and we take the default.  Same
// ""-means-fall-back idiom target_cdaudio uses for sv_cdaudio_pathfmt
// (sv_goldsrc_entities.qc:41-46).
// ---------------------------------------------------------------------------
float() PlayerLoadSaved_RecoveryEnabled =
{
    string s;

    s = cvar_string("sv_player_loadsaved_restart");
    if (s == "" || s == __NULL__)
        return TRUE;                 // unset -> restart the map
    return (stof(s) != 0);
};

// ---------------------------------------------------------------------------
// Fire a map-authored "leveldead_loadsaved" chain, if the map has a FIRABLE
// one.  Returns TRUE when it did, in which case we do NOT restart.
//
// The probe deliberately mirrors Trigger_UseTargets' own filter
// (sv_doors.qc:128 - `target_entity != caller && target_entity.use`) instead of
// asking only whether the NAME exists.  Measured reason: in hl_c11_a3 the name
// "leveldead_loadsaved" is carried by the trigger_changelevel AND by two
// monster_headcrabs.  A bare find() would report "the map has a recovery" for a
// set of entities the chain-walker then skips entirely, swallowing the restart
// and leaving the players behind a black screen with no way out.
//
// The fire goes out under `self`, NOT a throwaway relay edict.  A relay would
// have to be removed straight after the call, and multisource_use stores its
// caller PERSISTENTLY by entity identity (ms_find_or_create_node,
// sv_multisource.qc:66-83, compared at :90) - so a recovery chain containing a
// multisource would keep a node pointing at a freed edict, and FTE recycling
// that edict later would satisfy the AND-gate spuriously.  Swapping self.target
// for the duration of the call avoids that: .delay is zeroed so SUB_UseTargets
// takes its synchronous path (sv_triggers.qc:117-127), which makes the restore
// unconditionally safe, and SUB_DelayedFire would snapshot target/killtarget at
// schedule time anyway (sv_triggers.qc:91-92).  killtarget is blanked for this
// synthetic fire because HL's CRevertSaved never routes through
// CBaseDelay::SUB_UseTargets at all, so a killtarget on a player_loadsaved has
// no SDK meaning and must not be fired a second time here.
// ---------------------------------------------------------------------------
float(entity who) PlayerLoadSaved_FireMapRecovery =
{
    entity e;
    entity firable;
    string oldtarget;
    string oldkilltarget;
    float  olddelay;

    firable = world;
    e = find(world, targetname, PLS_MAP_RECOVERY_NAME);
    while (e)
    {
        if (e != self && e.use)
        {
            firable = e;
            e = world;
        }
        else
            e = find(e, targetname, PLS_MAP_RECOVERY_NAME);
    }
    if (!firable)
        return FALSE;

    oldtarget     = self.target;
    oldkilltarget = self.killtarget;
    olddelay      = self.delay;

    self.target     = PLS_MAP_RECOVERY_NAME;
    self.killtarget = "";
    self.delay      = 0;
    SUB_UseTargets(self, who, USE_TOGGLE);

    self.target     = oldtarget;
    self.killtarget = oldkilltarget;
    self.delay      = olddelay;

    if (cvar("sv_debug_use"))
        print(sprintf("[player_loadsaved] deferred to map chain \"%s\"\n",
                      PLS_MAP_RECOVERY_NAME));
    return TRUE;
};

// ---------------------------------------------------------------------------
// LoadThink - player.cpp:5038-5044.
//
// In GoldSrc this is one line behind a deathmatch gate.  Here it is the
// no-savegame substitute argued for in the header.
// ---------------------------------------------------------------------------
void() player_loadsaved_loadthink =
{
    entity who;

    who = self.pls_activator;
    if (who && wasfreed(who))
        who = world;

    // The FGD gives player_loadsaved no `target` key, so this fires for nobody
    // in the measured corpus.  It costs one string compare, and it is the
    // tree's standing rule that a chain routed through an entity must not be
    // severed by it, so a hand-edited or Sven-authored .ent that does set one
    // still gets its chain, delay and killtarget honoured.
    if (self.target != "" && self.target != __NULL__)
        SUB_UseTargets(self, who, USE_TOGGLE);

    if (!PlayerLoadSaved_RecoveryEnabled())
    {
        // Exactly Valve's multiplayer branch: the fade and the title happened,
        // the reload did not.  player.cpp:5040.
        if (cvar("sv_debug_use"))
            print("[player_loadsaved] recovery disabled; fade+message only\n");
        return;
    }

    // The map's own fail-state chain outranks ours.
    if (PlayerLoadSaved_FireMapRecovery(who))
        return;

    if (pls_recovery_issued)
        return;
    pls_recovery_issued = TRUE;

    bprint(PRINT_HIGH, "Objective failed - restarting the map.\n");

    // Same call and same argument as sv_main.qc:2579-2585: ChangeLevel_Issue
    // re-attaches the "*mappref" game spec so the reloaded map resolves its WADs
    // out of the game it was started from (sv_trigger_changelevel.qc:75-100
    // documents why a bare changelevel does not).  `mapname` is the engine
    // global from sv_defs.qc:280.
    ChangeLevel_Issue(mapname);
};

// ---------------------------------------------------------------------------
// MessageThink - player.cpp:5024-5035.
// ---------------------------------------------------------------------------
void() player_loadsaved_messagethink =
{
    float sent;
    float nextdelay;

    sent = 0;

    // UTIL_ShowMessageAll(STRING(pev->message)) - a titles.txt KEY resolved on
    // the client, which is precisely what CSQC_EVENT_ENV_MESSAGE carries
    // (sv_env_hud.qc:84-92).  "GAMEOVER" is titles.txt:524 on the mount;
    // "KILLPILOT" is NOT anywhere under the mount, so th_ep3_06's would resolve
    // to nothing - which is exactly what GoldSrc does with an unknown key
    // (client-side TextMessageGet miss), not a defect here.
    //
    // Skipping the send on an empty message is behaviourally identical to the
    // SDK's unconditional call: UTIL_ShowMessageAll("") reaches the client's
    // titles lookup, misses, and draws nothing (util.cpp:925-948).
    //
    // Deliberately NOT env_message_use's `if (msg == "") msg = targetname;`
    // fallback (sv_env_hud.qc:288-289): CRevertSaved sends pev->message raw,
    // and four of the six corpus entities ship no message at all - falling back
    // would print "dead_loadsave" on their screens.
    //
    // Also deliberately NOT EnvHud_QueueMessage on a zero send.  That queue
    // replays MAP-START HUD events to players who connect later
    // (sv_env_hud.qc:216-233); a game-over title shown to someone who joins
    // twenty minutes into the next life of the map is a bug, not a rescue.
    if (self.message != "" && self.message != __NULL__)
        sent = EnvMessage_SendAll(self.message);

    if (cvar("sv_debug_use"))
        print(sprintf("[player_loadsaved] \"%s\" message='%s' sent=%g loadtime=%g\n",
                      self.targetname, self.message, sent, self.loadtime));

    nextdelay = self.loadtime - self.messagetime;
    if (nextdelay > 0)
    {
        self.think     = player_loadsaved_loadthink;
        self.nextthink = time + nextdelay;
    }
    else
        player_loadsaved_loadthink();
};

// ---------------------------------------------------------------------------
// Use - player.cpp:5016-5021.  Every use-type behaves the same; CRevertSaved
// ignores useType and value entirely.
//
// No re-fire latch, matching the SDK: a second Use just re-arms the think from
// the top.  The one thing that must not repeat is the changelevel, and that is
// latched in pls_recovery_issued instead.
// ---------------------------------------------------------------------------
void() player_loadsaved_use =
{
    float duration_s;
    float hold_s;
    float alpha;
    float sent;

    duration_s = bound(0, self.duration, PLS_FADE_MAX_SECONDS);
    hold_s     = bound(0, self.holdtime, PLS_FADE_MAX_SECONDS);

    alpha = self.renderamt;
    if (alpha <= 0)
        alpha = 255;

    self.pls_activator = activator;

    // A zero-duration fade is a no-op on the client anyway (cl_env_hud.qc:908
    // early-returns on it), so skip the wire traffic.  Unlike env_fade_use this
    // must NOT early-return out of the whole function - CRevertSaved schedules
    // MessageThink unconditionally, and hl_c13_a4's keyless "c3a2d_load___"
    // shape relies on the load half running.
    sent = 0;
    if (duration_s > 0)
        sent = EnvFade_SendAll(self.rendercolor, alpha, duration_s, hold_s,
                               PLS_FADE_TO_COLOUR);

    if (cvar("sv_debug_use"))
        print(sprintf("[player_loadsaved] \"%s\" fade dur=%g hold=%g amt=%g col=%v -> %g client(s)\n",
                      self.targetname, duration_s, hold_s, alpha,
                      self.rendercolor, sent));

    self.think     = player_loadsaved_messagethink;
    self.nextthink = time + max(0, self.messagetime);
};

/*QUAKED player_loadsaved (.5 .5 0) (-8 -8 -8) (8 8 8)
Half-Life's "you failed" fade-and-reload.  Fades every client's screen to
"rendercolor", shows a titles.txt message, then - since there is no savegame in
multiplayer - restarts the current map.

"targetname"   name; this entity is fired, it never self-triggers
"duration"     seconds to fade to the colour (default 2, clamped to 16)
"holdtime"     seconds to hold at full alpha (default 0, clamped to 16)
"renderamt"    fade alpha 0..255 (default 255)
"rendercolor"  fade colour (default "0 0 0")
"messagetime"  seconds after firing before the title shows (default 0)
"message"      titles.txt key, e.g. GAMEOVER.  Empty = no title.
"loadtime"     seconds after firing before the restart (default 0)

Flags: none.

A map that names a firable recovery chain "leveldead_loadsaved" (Sven's
convention - see the file header) gets that fired instead of the restart.  Set
`sv_player_loadsaved_restart 0` to drop the recovery altogether and leave stock
Half-Life multiplayer behaviour: the fade and the message, and nothing else.
*/
void() player_loadsaved =
{
    // FGD default is 255 and every measured corpus placement sets it
    // explicitly, but a hand-written .ent that omits it would otherwise fade to
    // fully transparent.  Same guard env_fade's spawn function applies
    // (sv_env_hud.qc:322-323).
    if (self.renderamt <= 0)
        self.renderamt = 255;

    // CPointEntity::Spawn (subs.cpp:38-42) - solid only.  MOVETYPE_NONE is
    // already the default; set both anyway, as player_weaponstrip does
    // (sv_player_weaponstrip.qc:77-78).
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;

    self.use = player_loadsaved_use;
};

// ============================================================
//  global_light_control
//  SVEN FGD (authoritative key list)
//  - "C:/Program Files (x86)/Steam/steamapps/common/Sven Co-op/svencoop/sven-coop.fgd":2803-2812
//  2803-2807 is the descriptive comment ("Alters appearance of switchable lights or sun
//  (light_environment) ... On trigger or map load (if no targetname specified), it updates the
//  light's style using the specified 'Custom Appearance' pattern.")
//  2809 @PointClass ... base(Targetname, Target) ... = global_light_control
// ============================================================

//
//  sv_th_entities.qc  —  They Hunger / Sven-only point entities
//
//  Compile order in sv_progs.src: AFTER server/sv_goldsrc_entities.qc.
//  That puts us after sv_customdefs.qc (which owns the `light` entity and the
//  USE_* constants), after sv_doors.qc (Trigger_UseTargets / sub_use_type),
//  after sv_triggers.qc (SUB_UseTargets) and after sv_goldsrc_compat.qc (which
//  owns the light_spot / light_environment stubs we can be pointed at).
//

// ===========================================================================
//  global_light_control  —  "Global Light Pattern"
//
//  Sven-only.  There is NO Half-Life SDK class for this: a full-tree grep of
//  C:/msys64/home/Lex/halflife for global_light_control / GlobalLight finds
//  nothing.  A grep of the whole Sven install turns up exactly three files
//  that know the name — svencoop/dlls/server.dll, svencoop/sven-coop.fgd and
//  svencoop/maps/th_ep2_04.bsp — so there is no AngelScript implementation
//  either; it is compiled into server.dll.
//
//  KEYS — sven-coop.fgd:2809, which is the complete list:
//      @PointClass ... base(Targetname, Target) ... = global_light_control
//      [ target_entity(target_destination) : "Light Entity Name"
//        pattern(string)                   : "Custom Appearance" ]
//  and fgd:2802-2806 above it:
//      "Alters appearance of switchable lights or sun (light_environment).
//       Set 'Light Entity Name' field to target a light entity.  On trigger or
//       map load (if no targetname specified), it updates the light's style
//       using the specified 'Custom Appearance' pattern."
//
//  BEHAVIOUR — decompiled out of svencoop/dlls/server.dll (x86, imagebase
//  0x10000000).  Reproduced here because the FGD blurb leaves the two cases
//  that matter unstated.  vtable @0x10426914, RTTI complete-object-locator at
//  vtable-4 = 0x104b736c -> type descriptor 0x104b7378 ".?AVCGlobalLightControl@@".
//  Slots: +0x04 Spawn = 0x101be650, +0x10 KeyValue = 0x101be590,
//         +0x104 Use = 0x101be6a0, +0x114 SUB_UseTargets = 0x10251060.
//
//    CGlobalLightControl::KeyValue  @0x101be590
//        "pattern"        -> this+0x144
//        "target_entity"  -> this+0x148
//
//    CGlobalLightControl::Spawn     @0x101be650
//        if (pev->targetname /*pev+0x1cc*/) return;  // sit and wait to be fired
//        this->Use(NULL, NULL, USE_TOGGLE, 0);       // vtable+0x104, usetype 3
//        REMOVE_ENTITY(pev);                         // one-shot, then gone
//
//    CGlobalLightControl::Use       @0x101be6a0
//        if (m_iszTargetEntity) {
//            CLight *l = dynamic_cast<CLight *>(   // RTTI ".?AVCBaseEntity@@"
//                UTIL_FindEntityByTargetname(NULL, // -> ".?AVCLight@@"
//                                            STRING(m_iszTargetEntity)));
//            if (!l) {
//                ALERT(at_console,
//                      "global_light_control: Couldn't find %s", ...);
//                return;                           // NOTE: before UseTargets
//            }
//            LIGHT_STYLE(l->m_iStyle /*+0x144*/, STRING(m_iszPattern));
//        } else {
//            LIGHT_STYLE(0, STRING(m_iszPattern)); // <-- style ZERO
//        }
//        SUB_UseTargets(pActivator, useType, value);   // vtable+0x114
//
//  The empty-target_entity branch is not a degenerate case, it is the one the
//  campaign actually ships.  th_ep2_04.bsp's only instance (and the only
//  placement in the entire install — svencoop, svencoop_addon and
//  svencoop_downloads together) is:
//        { "origin" "160 -10032 800"  "pattern" "aaaa"
//          "targetname" "lightsout"   "classname" "global_light_control" }
//  with no target_entity, fired by the "ep2_endmm" multi_manager alongside
//  "endfade".  Style 0 is the static lightmap pass, so "aaaa" on style 0
//  blacks out the whole level for the end-of-episode fade-out.  Anything that
//  only handled the named-light case would silently do nothing there.
//
//  An empty `pattern` is passed through rather than defaulted: a zero-length
//  lightstyle string means "normal" in both engines — GoldSrc's R_AnimateLight
//  and FTE's (engine/gl/gl_rlight.c:146-150, `if (!cl_lightstyle[j].length)`
//  -> the 'm' level) both special-case it — so "" already behaves the way
//  Sven's STRING(0) does.
// ===========================================================================

// BSP entity-lump keys.  The engine's entity parser resolves a key by looking
// its name up in the progs fielddefs, so both names have to exist verbatim,
// exactly the way sv_triggers.qc declares .master / .killtarget / .triggerstate
// for its own keys.  Neither name is declared anywhere else in the tree.
//
// Note `pattern` is NOT ours alone: it is a real CLight keyvalue too
// (halflife/dlls/lights.cpp:68 -> m_iszPattern, used by CLight::Spawn/Use at
// lights.cpp:96/113 to drive a switchable light's own animation).  This tree's
// `light` (sv_customdefs.qc:436) does not implement that yet; declaring the
// field here is a prerequisite for it ever doing so and costs nothing now.
// `.string pattern` ("Custom Appearance" — a raw lightstyle string, a..z) moved
// to sv_customdefs.qc: `light` itself needs it (CLight::Spawn pushes the pattern
// as the lamp's ON appearance) and that file compiles at sv_progs.src:22 against
// this one's :428.  A field can only be declared once.
.string target_entity;   // "Light Entity Name" — targetname of a light entity

// The classnames that are a CLight in Sven, i.e. the ones the dynamic_cast
// above accepts.  This list is COMPLETE, and it is complete by evidence from
// the shipped binary rather than by inference from the SDK:
//
//   * The RTTI class hierarchy in server.dll has exactly ONE class deriving
//     from CLight.  Only two structures in the image reference the CLight type
//     descriptor 0x104f0114: its own complete-object-locator (0x104b72c8) and
//     its base-class descriptor 0x104b72fc.  That BCD is referenced from just
//     two base-class arrays — CLight's own (0x104b72ec) and 0x104b733c, whose
//     first element is ".?AVCEnvLight@@".  Nothing else inherits CLight.
//   * server.dll's export table (403 exports; LINK_ENTITY_TO_CLASS emits one
//     export per classname) contains exactly three light classnames:
//     `light`, `light_spot`, `light_environment`.  The other "light"-ish
//     exports are `env_lightning`, `xen_plantlight` and `global_light_control`
//     itself, none of which is in the CLight hierarchy.
//
//   light                 -> the real switchable implementation, sv_customdefs.qc:436
//   light_spot            -> compile-time-only stub, sv_goldsrc_compat.qc:174
//   light_environment     -> compile-time-only stub, sv_goldsrc_compat.qc:175
//
// The last two are empty spawn functions, so the entity survives with its
// map-authored `style` key intact and can legitimately be named here — which
// is how the FGD's "or sun (light_environment)" case is reachable.
float(entity e) GlobalLight_IsLightEntity =
{
    if (e.classname == "light")             return TRUE;
    if (e.classname == "light_spot")        return TRUE;
    if (e.classname == "light_environment") return TRUE;
    return FALSE;
};

// The whole of CGlobalLightControl::Use, with the useType threaded through
// the way the rest of this port does it (sv_goldsrc_compat.qc:123).
void(float useType) GlobalLight_Apply =
{
    entity lit;
    float  sty;

    sty = 0;    // no target_entity -> Sven drives lightstyle 0, the baked pass

    // An ABSENT target_entity key is the style-0 case (Sven tests the string
    // offset at this+0x148 for zero, 0x101be6b4).  A key authored with an
    // empty VALUE is treated the same here; Hammer never writes one, and no
    // map in the corpus does, so the two are indistinguishable in practice.
    if (self.target_entity != "" && self.target_entity != __NULL__)
    {
        lit = find(world, targetname, self.target_entity);

        // Sven takes the FIRST targetname match and dynamic_cast<CLight*>s it
        // (single UTIL_FindEntityByTargetname call at 0x101be6cb with a NULL
        // start entity — there is no loop).  A name collision with a non-light
        // does NOT fall through to the next match there: the cast returns NULL
        // and the entity reports failure.  So don't "helpfully" keep scanning:
        // a map that works in Sven has to work the same way here, and a map
        // that is broken there should be visibly broken here rather than
        // quietly different.
        if (lit && !GlobalLight_IsLightEntity(lit))
            lit = world;

        if (!lit)
        {
            // ALERT(at_console, ...) at 0x101be6fb.  Printed on every fire,
            // exactly as Sven does — this is a mapper error worth seeing, and
            // deduping it would hide a chain that is firing more often than
            // the mapper thinks.
            print(sprintf("global_light_control: Couldn't find %s\n",
                          self.target_entity));
            return;     // and the target chain does NOT fire.  See 0x101be704.
        }

        // CLight::m_iStyle is the first member past CBaseEntity (this+0x144,
        // halflife/dlls/lights.cpp:39), which is what 0x101be70f reads off the
        // found entity.  Our `light` keeps the same value in .style
        // (sv_customdefs.qc:416 Light_ApplyState).
        sty = lit.style;
    }

    lightstyle(sty, self.pattern);

    SUB_UseTargets(self, activator, useType);
};

void() global_light_control_use =
{
    // == USE_UNSET, not truthiness: USE_OFF is 0 and a ternary discards it, so
    // "turn the global light control off" was unreachable.  See sv_customdefs.qc.
    GlobalLight_Apply((sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type);
};

// The untargeted "fire at map load" path.  Deferred by one think rather than
// run inside the spawn function, for two reasons that only bite in QC:
//
//   1. The light named by target_entity may be LATER in the entity lump, and
//      spawn functions run as the lump is parsed — so a spawn-time find()
//      would miss it and print "Couldn't find".
//   2. Even for a light that already exists, sv_customdefs.qc's `light` spawn
//      calls Light_ApplyState() unconditionally, which pushes "m" or "a" onto
//      that style.  A spawn-time lightstyle() from here would just be
//      overwritten by the light spawning after us.
//
// Note there is NO third reason: a spawn-time lightstyle() would NOT be lost
// to the server still loading.  PF_applylightstyle (engine/server/pr_cmds.c:4806)
// writes sv.lightstyles[style].str at :4823 and only THEN, at :4832, skips the
// live broadcast while sv.state != ss_active — and clients pick the stored
// styles up when they connect.  Only reasons 1 and 2 above are load-bearing.
//
// 0.1s and not trigger_auto's 0.2s (server/sv_trigger_logic.qc:107-111): in
// Half-Life this runs inside Spawn, so it lands BEFORE any trigger_auto chain
// (HL's own CAutoTrigger defers 0.1s — halflife/dlls/triggers.cpp:170-173),
// and a map that uses a trigger_auto to switch a light back on after the
// blackout has to keep that order.  It is still map-load time as far as any
// player is concerned.
void() global_light_control_think =
{
    entity oldact = activator;

    activator = world;                  // Spawn passes pActivator = NULL
    GlobalLight_Apply(USE_TOGGLE);      // ...and useType 3, at 0x101be669
    activator = oldact;

    remove(self);                       // REMOVE_ENTITY at 0x101be683
};

/*QUAKED global_light_control (.4 .4 .1) (-24 -24 -24) (24 24 24)
Overwrites a lightstyle with a mapper-authored animation string.

"targetname"     name.  WITHOUT one the entity fires itself once at map load
                 and then deletes itself; WITH one it does nothing until fired,
                 and can be fired any number of times.
"target_entity"  targetname of a light / light_spot / light_environment whose
                 `style` index gets the pattern.  LEAVE IT EMPTY to drive
                 lightstyle 0 instead, i.e. the entire baked lightmap — that is
                 what They Hunger's end-of-episode blackout does.
"pattern"        the lightstyle string: 'a' = black, 'm' = normal, 'z' = double
                 bright.  Empty means normal.
"target"         chain fired after the style is applied.  NOT fired when
                 target_entity names something that isn't a light.

No spawnflags, no delay, no killtarget.  Sven's FGD (sven-coop.fgd:2809)
carries no others.
*/
void() global_light_control =
{
    // `delay` and `killtarget` are NOT part of this entity, and clearing them
    // is what makes our firing path match the binary rather than merely
    // resemble it.  CGlobalLightControl is a CPointEntity — its RTTI base
    // array (0x104b7390) is exactly { CGlobalLightControl, CPointEntity,
    // CBaseEntity } — so vtable+0x114 resolves to CBaseEntity::SUB_UseTargets
    // @0x10251060, which is six instructions long: read pev->target (pev+0x1c8),
    // bail if null, call FireTargets.  That is all.  The delay/killtarget
    // machinery lives on CBaseDelay::SUB_UseTargets (halflife/dlls/subs.cpp:215),
    // which this class never inherits, and the FGD's base(Targetname, Target)
    // carries neither key.
    //
    // This tree's SUB_UseTargets (sv_triggers.qc:112) implements the CBaseDelay
    // form, so without these two lines a `delay` key would not just add timing
    // Sven does not have — on the untargeted path it would also make
    // SUB_DelayedFire stamp `delayed_origcaller = self` onto a temp entity one
    // statement before global_light_control_think calls remove(self), leaving
    // the temp reporting a freed (and possibly recycled) edict as
    // sub_use_caller to any multisource downstream.
    self.delay      = 0;
    self.killtarget = "";

    if (self.targetname != "" && self.targetname != __NULL__)
    {
        self.use = global_light_control_use;
        return;
    }

    self.think     = global_light_control_think;
    self.nextthink = time + 0.1;
};

// ============================================================
//  func_trackchange
//  SDK (read on disk at C:/msys64/home/Lex/halflife):
//  - dlls/plats.cpp:1618  class CFuncTrackChange : public CFuncPlatRot; LINK_ENTITY_TO_CLASS at :1662
//  - dlls/plats.cpp:1679  Spawn (Setup + SF_TRACK_DONT_MOVE override at :1681, START_AT_BOTTOM at :1687
//  - dlls/plats.cpp:1604-1606  SF_TRACK_ACTIVATETRAIN / SF_TRACK_RELINK / SF_TRACK_ROTMOVE — grepped th
//  - dlls/plats.cpp:1622  `// virtual void Blocked( void );` — commented out, so stock HL never crushes
//  - dlls/plats.cpp:1711  PRECACHE_SOUND("buttons/button11.wav")
// ============================================================

//
// sv_th_entities.qc — HL/GoldSrc entities that had no home in the existing
//                     sv_goldsrc_* / sv_func_* files.
//

// ===========================================================================
// func_trackchange — track-changing platform / train elevator.
//
// SDK: dlls/plats.cpp:1618 (class CFuncTrackChange : public CFuncPlatRot),
//      LINK_ENTITY_TO_CLASS at plats.cpp:1662.
// FGD: svencoop/sven-coop.fgd:2540 (@SolidClass base(Trackchange, ZHLT)),
//      whose keys live in the shared @BaseClass Trackchange at :1233
//      (height / rotation / train / toptrack / bottomtrack / speed), plus
//      PlatSounds' movesnd / stopsnd / volume at :1186 and BasePlat's dmg
//      at :1228.
//
// A rotating/moving platform that carries a parked func_tracktrain between the
// end of one path_track chain and the start of another, then RELINKS the train
// onto the chain it just arrived at.  func_trackautochange (already in this
// tree, server/sv_func_trackautochange.qc) is the SDK subclass of this class
// (plats.cpp:2013) — it shares the very same FGD @BaseClass, which is why this
// file reuses that file's spawnflag constants and keyvalue fields verbatim
// rather than declaring parallel ones.  The difference is the trigger model:
//   - func_trackchange     — fired by a button / multi_manager (this file).
//   - func_trackautochange — fired by the train arriving at a dead end.
//
// WHY THE RELINK IS THE LOAD-BEARING HALF, and not the platform movement:
// th_ep1_04 (They Hunger ep1) authors it as a pure junction switch — read out
// of the BSP entity lump, not assumed:
//     "targetname" "autochange_path"  "spawnflags" "24"   (START_AT_BOTTOM|ROTATE_ONLY)
//     "rotation" "3"   "speed" "100"   "origin" "730 1573 24"
//     "bottomtrack" "st_04"  "toptrack" "newpath"  "train" "steamer"
//     "rendermode" "2"                             (invisible: renderamt unset -> 0)
// path_track "st_04" is a DEAD END at that exact origin (it has no "target"
// key); path_track "newpath" sits at the same origin and targets "st_05".  So
// the platform travels 0 units and spins 3 degrees — everything this entity
// does for that map is move the train "steamer" (wheels 400) off the st_04
// chain and onto the newpath chain.  hl_c06 and hl_c07_a1 also ship one;
// hl_c07_a1's "trainlift" is a real 912-unit / 720-degree lift at speed 50.
//
// Sitting on what this tree ACTUALLY has (checked, not assumed):
//   - server/sv_path_track.qc has path_track as a pure data entity, and its
//     `.altpath` comment explicitly says the branch key is "DECLARED ONLY:
//     selecting it needs a func_trackchange to flip the branch".  This is that
//     entity — but the branch is flipped the way the SDK really does it
//     (CFuncTrackTrain::SetTrack, trains.h:96), by repointing the train at the
//     nearest node of the destination chain, NOT by consuming `.altpath`.
//   - server/sv_func_tracktrain.qc walks path_tracks by name through
//     FuncTrackTrain_NextTrack() and keeps the current node in `.train_target`.
//     That is this file's stand-in for CFuncTrackTrain::m_ppath.
//   - server/sv_func_trackautochange.qc owns the shared keyvalue fields
//     (`train` / `toptrack` / `bottomtrack` / `height` / `rotation`), the
//     tac_* runtime slots and the Trackauto_* helpers.  All reused here.
//   - shared/sh_pmove.qc owns MovingBrush_AddToList/RemoveFromList; the platform
//     joins that list while moving so riders are carried.  AddToList is
//     idempotent (sh_pmove.qc:3314 scans before inserting), which is what lets
//     the blocked handler below re-enter Trackchange_Go.
//
// Deliberately NOT implemented (accepted as map data, no effect):
//   - Sven's StartStopable / OpenClosable extras (fireonstart, fireonstop,
//     fireonopened, ... ).  All three reference maps ship only the companion
//     "*_triggerstate" "2" defaults with no target names set, so nothing in the
//     corpus would fire.
//   - `noise` / `noise1` / `noise2` sound-path overrides and `soundlist`.
//     The movesnd / stopsnd enums are honoured (via the func_train tables).
// ===========================================================================

// --- Toggle states.  Same encoding as func_trackautochange's `.tac_state`,
//     which this entity reuses, mapped onto the SDK's TS_* enum (util.h).
const float TC_AT_TOP      = 0;    // TS_AT_TOP
const float TC_AT_BOTTOM   = 1;    // TS_AT_BOTTOM
const float TC_GOING_UP    = 2;    // TS_GOING_UP
const float TC_GOING_DOWN  = 3;    // TS_GOING_DOWN

// --- TRAIN_CODE (plats.cpp:1612).
const float TC_TRAIN_SAFE      = 0;
const float TC_TRAIN_BLOCKING  = 1;
const float TC_TRAIN_FOLLOWING = 2;

const float TC_TICK      = 0.05;   // 20 Hz carry / bookkeeping tick
const float TC_CHAIN_MAX = 1000;   // Nearest() runaway guard (HL uses 9999)

// --- Runtime state.  Everything else this entity needs (train/toptrack/
//     bottomtrack/height/rotation and the tac_* slots) is already declared in
//     server/sv_func_trackautochange.qc, which compiles first.
.entity tc_track_top;      // CFuncTrackChange::m_trackTop    (post-Nearest)
.entity tc_track_bottom;   // CFuncTrackChange::m_trackBottom (post-Nearest)
.float  tc_code;           // CFuncTrackChange::m_code
.float  tc_use_enabled;    // CFuncTrackChange::m_use  (EnableUse/DisableUse)
.float  tc_resolved;       // Find() has run

// --- The trip.  The platform's whole state of motion is one scalar: a
//     progress fraction u along the fixed BOTTOM(0) -> TOP(1) path, recovered
//     from .ltime and the leg deadline.  Everything — the carry transform, a
//     mid-trip reversal, the arrival snap — is expressed in u, and NOTHING is
//     ever re-derived from the live .angles.  hl_c07_a1's trainlift turns 720
//     degrees; if the engine ever renormalises a MOVETYPE_PUSH entity's .angles
//     into 0..360 partway through, any angle-derived delta jumps a full turn.
.float  tc_full_time;      // seconds for the complete bottom<->top trip
.float  tc_deadline;       // .ltime at which the leg in flight reaches its end
.float  tc_last_block;     // .ltime of the last blocked-reversal (stall damper)
.vector tc_train_ang;      // carried train's angles expressed at u = 0
                           // (.tac_train_ofs likewise holds its offset at u = 0)

void() Trackchange_Find;
void() trackchange_arrive;
void() trackchange_move_tick;
void(float going_up) Trackchange_Go;

// ---------------------------------------------------------------------------
// find(world, targetname, "") matches the first entity that has NO targetname,
// so every lookup here goes through this guard.  func_trackchange is routinely
// authored with only one of toptrack/bottomtrack set.
// ---------------------------------------------------------------------------
entity(string nm) Trackchange_FindName =
{
    if (nm == "")
        return world;
    return find(world, targetname, nm);
};

// CPathTrack::Nearest (dlls/pathcorner.cpp:370).  Walks the chain FORWARD only
// (HL uses GetNext()), compares 2D distance, stops if it loops back to the head.
// Divergence: HL returns NULL on a runaway chain; returning the best node found
// so far is strictly safer here, because a NULL return would silently cancel
// the relink that is this entity's entire purpose.
entity(entity head, vector org) Trackchange_Nearest =
{
    entity ppath;
    entity nearest;
    vector delta;
    float  mindist;
    float  dist;
    float  guard;

    if (head == world)
        return world;

    delta   = org - head.origin;
    delta_z = 0;
    mindist = vlen(delta);
    nearest = head;

    ppath = FuncTrackTrain_NextTrack(head);
    guard = 0;
    while (ppath != world && ppath != head)
    {
        guard = guard + 1;
        if (guard > TC_CHAIN_MAX)
        {
            dprint(sprintf("func_trackchange \"%s\": bad path_track sequence from \"%s\"\n",
                           self.targetname, head.targetname));
            return nearest;
        }

        delta   = org - ppath.origin;
        delta_z = 0;
        dist    = vlen(delta);
        if (dist < mindist)
        {
            mindist = dist;
            nearest = ppath;
        }
        ppath = FuncTrackTrain_NextTrack(ppath);
    }
    return nearest;
};

// CPathTrack::m_pprevious.  path_track in this tree only stores the forward
// link (`target`), so the back-link is recovered by searching for whoever
// points AT us — the exact inverse of FuncTrackTrain_NextTrack().
//
// The classname filter is load-bearing.  A path_track is very often the target
// of a trigger or a multi_manager as well as of its predecessor, and a bare
// find() hands back whichever of those happens to be first in the edict list.
// HL's m_pprevious is built by CPathTrack::Link (pathcorner.cpp) and can only
// ever be a path_track, so anything else has to be skipped rather than accepted
// — otherwise EvaluateTrain silently loses the "train is on the previous node"
// case and reports SAFE while the train is sitting right next to the platform.
entity(entity trk) Trackchange_Prev =
{
    entity e;

    if (trk == world || trk.targetname == "")
        return world;

    e = find(world, target, trk.targetname);
    while (e != world && e.classname != "path_track")
        e = find(e, target, trk.targetname);

    return e;
};

// SetBits/ClearBits( ppath->pev->spawnflags, SF_PATH_DISABLED ).
// PT_DISABLED is func_tracktrain's constant (server/sv_func_tracktrain.qc:50).
void(entity trk, float on) Trackchange_SetPathDisabled =
{
    if (trk == world)
        return;

    if (on)
    {
        if (!(trk.spawnflags & PT_DISABLED))
            trk.spawnflags = trk.spawnflags + PT_DISABLED;
    }
    else
    {
        if (trk.spawnflags & PT_DISABLED)
            trk.spawnflags = trk.spawnflags - PT_DISABLED;
    }
};

// CFuncTrackChange::UpdateAutoTargets (plats.cpp:1924): the track under the
// platform's CURRENT end is enabled, the other is disabled.
//
// ADVISORY IN THIS TREE, ON PURPOSE.  FuncTrackTrain_NextTrack() walks the
// chain by name and does not filter on PT_DISABLED, so today these bits change
// no behaviour on their own — the working redirect is Trackchange_SetTrack()
// below, which is also how the SDK really moves the train (plats.cpp:1981).
// The bits are still maintained because they are the correct entity state, they
// are what a future chain-walk filter in sv_func_tracktrain.qc would read, and
// leaving them stale would make that later change misbehave in a way that would
// be very hard to trace back to here.
void(float toggle_state) Trackchange_UpdateAutoTargets =
{
    if (self.tc_track_top == world || self.tc_track_bottom == world)
        return;

    Trackchange_SetPathDisabled(self.tc_track_top,    toggle_state != TC_AT_TOP);
    Trackchange_SetPathDisabled(self.tc_track_bottom, toggle_state != TC_AT_BOTTOM);
};

// The chain the train is relinked onto for the leg in flight (or, once parked,
// the one it was relinked onto).  Derived from .tac_state rather than cached in
// a field so the blocked-reversal below cannot leave it stale.
entity() Trackchange_DestTrack =
{
    if (self.tac_state == TC_GOING_UP || self.tac_state == TC_AT_TOP)
        return self.tc_track_top;
    return self.tc_track_bottom;
};

// Where the platform is along its fixed path: 0 = BOTTOM, 1 = TOP.
//
// Recovered from the leg deadline instead of from .origin/.angles so it is
// exact for a >360-degree rotation and for a ROTATE_ONLY platform (whose origin
// never changes at all, leaving nothing to measure).  For a leg of length
// L = |u_target - u_start| * tc_full_time the engine advances .ltime by exactly
// L over the leg, so u is a pure function of the time remaining.
float() Trackchange_Progress =
{
    float remain;

    if (self.tac_state == TC_AT_TOP)
        return 1;
    if (self.tac_state == TC_AT_BOTTOM)
        return 0;
    if (self.tc_full_time <= 0)
        return (self.tac_state == TC_GOING_UP) ? 1 : 0;

    remain = self.tc_deadline - self.ltime;
    if (remain < 0)
        remain = 0;

    if (self.tac_state == TC_GOING_UP)
        return bound(0, 1 - (remain / self.tc_full_time), 1);
    return bound(0, remain / self.tc_full_time, 1);
};

// CFuncTrackChange::EvaluateTrain (plats.cpp:1802).  Answers "may the platform
// move right now, and is the train riding it?"
float(entity trk) Trackchange_EvaluateTrain =
{
    entity t;
    entity prev;
    entity next;
    vector delta;
    float  gap;
    float  trainlen;
    float  on_track;

    t = self.tac_train_ent;

    // "Go ahead and work, we don't have anything to switch, so just be an
    // elevator" — plats.cpp:1804.
    if (trk == world || t == world)
        return TC_TRAIN_SAFE;

    // Is the train on this track, or on either of its neighbours?  The
    // world-guards on prev/next are load-bearing: without them a train whose
    // .train_target is world would compare equal to a missing neighbour and be
    // treated as parked on the platform.
    prev = Trackchange_Prev(trk);
    next = FuncTrackTrain_NextTrack(trk);

    on_track = FALSE;
    if (t.train_target == trk)
        on_track = TRUE;
    else if (prev != world && t.train_target == prev)
        on_track = TRUE;
    else if (next != world && t.train_target == next)
        on_track = TRUE;

    if (!on_track)
        return TC_TRAIN_SAFE;

    // HL tests `m_train->pev->speed != 0` here, which reads as "is the train
    // configured with a speed" but is NOT: CFuncTrackTrain::Spawn stashes the
    // authored speed in m_speed and then does `pev->speed = 0` (plats.cpp:1492),
    // so pev->speed is the train's CURRENT speed and the test means "is it
    // moving".  CFuncTrackAuto::UpdateAutoTargets settles it — that one restarts
    // the train on `m_train->pev->speed == 0` (plats.cpp:2044).  This tree's
    // func_tracktrain keeps the authored speed in .speed permanently (it never
    // zeroes it), so porting the test literally would make every configured
    // train read as BLOCKING and this entity would never move.  .train_state is
    // the real equivalent (0 = stopped, 1 = moving, 2 = waiting).
    if (t.train_state != 0 || vlen(t.velocity) > 0)
        return TC_TRAIN_BLOCKING;

    delta   = self.origin - t.origin;
    delta_z = 0;
    gap     = vlen(delta);

    // m_train->m_length is the func_tracktrain "wheels" key (plats.cpp:960).
    // func_tracktrain defaults it to 100 at spawn in this tree; the guard is for
    // a train that was never spawned through that path.
    trainlen = t.wheels;
    if (trainlen <= 0)
        trainlen = 100;

    if (gap < trainlen)                     // "Empirically determined close distance"
        return TC_TRAIN_FOLLOWING;
    if (gap > (150 + trainlen))
        return TC_TRAIN_SAFE;

    return TC_TRAIN_BLOCKING;
};

// CFuncTrackTrain::SetTrack (dlls/trains.h:96) — `m_ppath = track->Nearest(pev->origin)`.
// This is the redirect that makes the whole entity work.
//
// Both .train_target and .target are written, matching what
// server/sv_func_trackautochange.qc's trackauto_arrive() does: .train_target is
// the live cursor func_tracktrain_move_tick() follows, while .target is what
// func_tracktrain_find_first() re-resolves from if the train is ever lazily
// re-initialised.  Leaving .target pointing at the OLD chain would silently
// undo the switch the next time anything triggered the train from a cold start.
void(entity t, entity head) Trackchange_SetTrack =
{
    entity node;

    if (t == world || head == world)
        return;

    // HL reaches the train through CFuncTrackTrain::Instance (plats.cpp:1467),
    // which returns NULL for anything that is not a func_tracktrain — so the
    // relink is a tracktrain-only operation there too.  A func_train named in
    // `train` still gets ferried by the carry code below; it just keeps its own
    // path_corner chain, which is correct, because path_corners and path_tracks
    // are not interchangeable (see the header of server/sv_path_track.qc).
    if (t.classname != "func_tracktrain")
        return;

    node = Trackchange_Nearest(head, t.origin);
    if (node == world)
        return;

    t.train_target = node;
    t.target       = node.targetname;
    t.SendFlags    = 1;
};

// CFuncTrackChange::UpdateTrain (plats.cpp:1828).  HL hands the train the
// platform's velocity and avelocity and then corrects the orbit about the
// pivot; here the platform is authoritative and the train is SNAPPED onto its
// captured offset each tick, with velocity/avelocity mirrored on top purely so
// the CSQC replica (cl_brushsync.qc extrapolates off .velocity) glides between
// snaps instead of teleporting 20 times a second.  plats.cpp:1831-1832 assigns
// exactly those two fields, so the mirroring is SDK behaviour, not invention.
//
// The offset and the train's orientation are both stored in the platform's
// u = 0 frame, so a mid-trip reversal needs no re-capture and cannot introduce
// a seam.  Rotating through the whole v_forward/v_right/v_up basis rather than
// yaw-only (which is all Trackauto_CarryTrain does) is what makes X_AXIS /
// Y_AXIS platforms — spawnflag 64 / 128 — carry an off-centre train correctly.
// `v_forward*x - v_right*y + v_up*z` is the engine's own local->world transform
// for a rotated bmodel (v_right points -Y), so the train tracks the brush.
void() Trackchange_CarryTrain =
{
    entity t;
    vector base;
    vector ofs;
    vector dang;

    if (!self.tac_train_ofs_known)
        return;

    t = self.tac_train_ent;
    if (t == world)
        return;

    dang = (self.tac_ang_top - self.tac_ang_bottom) * Trackchange_Progress();
    makevectors(dang);

    base = self.tac_train_ofs;
    ofs  = (v_forward * base_x) - (v_right * base_y) + (v_up * base_z);

    setorigin(t, self.origin + ofs);
    t.angles    = self.tc_train_ang + dang;
    t.velocity  = self.velocity;
    t.avelocity = self.avelocity;
    t.SendFlags = 1;
};

// Latch the carried train into the platform's u = 0 frame.  Runs once when a
// ride begins; the reversal path deliberately does NOT re-run it.
void(entity t) Trackchange_CaptureTrain =
{
    vector world_ofs;
    vector dang;
    vector base;

    dang = (self.tac_ang_top - self.tac_ang_bottom) * Trackchange_Progress();
    makevectors(dang);

    // Inverse of the local->world transform above.  The basis is orthonormal,
    // so the inverse is three dot products.
    world_ofs = t.origin - self.origin;
    base_x    =  (world_ofs * v_forward);
    base_y    = -(world_ofs * v_right);
    base_z    =  (world_ofs * v_up);

    self.tac_train_ofs       = base;
    self.tc_train_ang        = t.angles - dang;
    self.tac_train_ofs_known = 1;
};

// CFuncTrackChange::Find (plats.cpp:1758).  Deferred so the path_tracks and the
// train have spawned.  HL waits a full 2 seconds (plats.cpp:1700); this waits
// 0.5 and func_trackchange_use() re-runs it on demand if it has not happened
// yet, which is strictly more robust than a fixed delay.
void() Trackchange_Find =
{
    entity t;
    vector center;

    self.tc_resolved = TRUE;

    self.tc_track_top    = Trackchange_FindName(self.toptrack);
    self.tc_track_bottom = Trackchange_FindName(self.bottomtrack);
    t                    = Trackauto_FindTrain();

    // HL's three ALERT( at_error, ... ) branches, plats.cpp:1782-1795.  These
    // are map authoring errors, so they print without a debug cvar — same as
    // func_tracktrain's "first stop not found".  HL nests them and stops at the
    // first failure; reporting all three is strictly more useful and has no
    // behavioural consequence.
    if (self.tc_track_top == world)
        dprint(sprintf("func_trackchange \"%s\": can't find top track \"%s\"\n",
                       self.targetname, self.toptrack));
    if (self.tc_track_bottom == world)
        dprint(sprintf("func_trackchange \"%s\": can't find bottom track \"%s\"\n",
                       self.targetname, self.bottomtrack));
    if (t == world)
        dprint(sprintf("func_trackchange \"%s\": can't find train \"%s\"\n",
                       self.targetname, self.train));

    // Narrow each named chain to the node actually under the platform
    // (plats.cpp:1777-1779).  Unresolved tracks simply leave the entity working
    // as a plain elevator, because EvaluateTrain() returns SAFE on a null track.
    if (self.tc_track_top != world && self.tc_track_bottom != world)
    {
        center               = (self.absmin + self.absmax) * 0.5;
        self.tc_track_top    = Trackchange_Nearest(self.tc_track_top, center);
        self.tc_track_bottom = Trackchange_Nearest(self.tc_track_bottom, center);
    }

    Trackchange_UpdateAutoTargets(self.tac_state);

    self.think     = __NULL__;
    self.nextthink = 0;
};

// CFuncPlat::HitTop / HitBottom STOP the move sound before playing the stop
// sound (plats.cpp:451 / :478).  The reused Trackauto_PlayStopSound() emits on
// CHAN_BODY, which displaces a move sound already playing there — but only when
// stopsnd actually resolves to a path.  With "stopsnd" "0" (or unset) it returns
// without emitting anything and the move sample would run on past arrival, so
// the channel is cut explicitly.  `sound(ent, chan, "", 0, ...)` is this tree's
// stop idiom — server/sv_func_tracktrain.qc:332 / :386 / :463.
void() Trackchange_StopMoveSound =
{
    if (FuncTrain_StopSound(self.stopsnd) != "")
    {
        Trackauto_PlayStopSound();
        return;
    }
    if (FuncTrain_MoveSound(self.movesnd) != "")
        SV_StopChannel(self, CHAN_BODY);
};

// CFuncTrackChange::HitTop / HitBottom (plats.cpp:1975, 1995).
void() trackchange_arrive =
{
    entity t;
    entity dest_track;
    entity oldself;
    vector dest_origin;
    vector dest_angles;

    if (self.tac_state == TC_GOING_UP)
    {
        self.tac_state = TC_AT_TOP;
        dest_origin    = self.tac_pos_top;
        dest_angles    = self.tac_ang_top;
    }
    else if (self.tac_state == TC_GOING_DOWN)
    {
        self.tac_state = TC_AT_BOTTOM;
        dest_origin    = self.tac_pos_bottom;
        dest_angles    = self.tac_ang_bottom;
    }
    else
    {
        return;             // defensive: arrive() with no move in flight
    }
    dest_track = Trackchange_DestTrack();

    // Snap so per-tick error can't accumulate; CFuncPlatRot::HitTop assigns
    // m_end outright for the same reason (plats.cpp:606).
    setorigin(self, dest_origin);
    self.angles    = dest_angles;
    self.velocity  = '0 0 0';
    self.avelocity = '0 0 0';
    self.SendFlags = 1;

    // .tac_state is already the arrived state, so Trackchange_Progress() now
    // returns an exact 1 / 0 and this lands the train on the true end-of-trip
    // transform rather than wherever the last tick left it.
    Trackchange_CarryTrain();
    self.tac_train_ofs_known = 0;

    self.think     = __NULL__;
    self.nextthink = 0;
    MovingBrush_RemoveFromList(self);
    Trackchange_StopMoveSound();

    // Relink ONLY if the train actually rode over (plats.cpp:1979 / 1999).
    if (self.tc_code == TC_TRAIN_FOLLOWING)
    {
        t = self.tac_train_ent;
        Trackchange_SetTrack(t, dest_track);

        // SF_TRACK_ACTIVATETRAIN.  plats.cpp:1604 defines the bit and NOTHING
        // in stock HL ever reads it — but the FGD exposes it as "Auto Activate
        // train" (sven-coop.fgd:1238) and the CFuncTrackAuto subclass does
        // exactly this restart unconditionally (plats.cpp:2044), so honouring
        // the flag is the behaviour a mapper who ticks the box is asking for.
        // Flag-gated, so it cannot regress the reference maps: th_ep1_04's
        // spawnflags 24 leaves it clear and lets trigger_changevalue
        // "steamer_controlz" hand the train to the player one second later.
        if ((self.spawnflags & SF_TAC_AUTO_ACTIVATE)
            && t != world && t.classname == "func_tracktrain"
            && t.train_state == 0)
        {
            oldself = self;
            self    = t;
            // MANDATORY.  sub_use_type is a global holding whatever ran last;
            // if that is 0 (USE_OFF) then func_tracktrain_use's ShouldToggle
            // guard rejects the start outright.  Same trap documented at
            // server/sv_func_tracktrain.qc:562.
            sub_use_type = USE_ON;
            func_tracktrain_use();
            self = oldself;
        }
    }

    Trackchange_UpdateAutoTargets(self.tac_state);
    self.tc_use_enabled = TRUE;              // EnableUse()
};

// Per-tick bookkeeping.  Velocity and avelocity are set ONCE, in Trackchange_Go,
// the way CBaseToggle::LinearMove and CFuncPlatRot::RotMove do (plats.cpp:608)
// — this tick only runs the train carry, keeps the brushsync wire dirty, and
// watches the deadline.
//
// The last tick is pulled forward onto the deadline instead of landing on the
// next 0.05 boundary, so the platform is exactly on its endpoint when arrive()
// snaps.  Without that clamp a trip whose length is a whole multiple of the tick
// arrives a full tick early and jumps the last `speed * 0.05` units.
//
// .ltime, not time, throughout: this is a MOVETYPE_PUSH pusher whose .ltime
// only advances while it has a pending nextthink — and, as the blocked handler
// explains, only while its pushes actually succeed.  Mixing the two clocks is
// the bug called out at server/sv_func_tracktrain.qc:663.
void() trackchange_move_tick =
{
    float remain;

    if (self.tac_state != TC_GOING_UP && self.tac_state != TC_GOING_DOWN)
    {
        self.velocity  = '0 0 0';
        self.avelocity = '0 0 0';
        self.think     = __NULL__;
        self.nextthink = 0;
        MovingBrush_RemoveFromList(self);
        return;
    }

    remain = self.tc_deadline - self.ltime;
    if (remain <= 0.001)
    {
        trackchange_arrive();
        return;
    }

    self.SendFlags = 1;
    Trackchange_CarryTrain();

    self.think = trackchange_move_tick;
    if (remain < TC_TICK)
        self.nextthink = self.tc_deadline;     // remain > 0.001, so still ahead
    else
        self.nextthink = self.ltime + TC_TICK;
};

// CFuncTrackChange::GoUp / GoDown (plats.cpp:1889 / 1853), merged — the two
// differ only in which end they aim at.
//
// The leg is measured from wherever the platform actually IS (Progress()), not
// from the far endpoint, because CFuncPlat::GoDown/GoUp call LinearMove(dest,
// speed) — which derives its travel time from the CURRENT origin.  That only
// matters when a blocked reversal restarts the platform mid-trip, and getting
// it wrong there would make arrive() snap the platform across the whole shaft.
void(float going_up) Trackchange_Go =
{
    entity t;
    entity dest_track;
    float  u;
    float  leg;

    // "if ( m_code == TRAIN_BLOCKING ) return;" — plats.cpp:1855 / 1891.
    if (self.tc_code == TC_TRAIN_BLOCKING)
        return;

    u = Trackchange_Progress();     // read BEFORE .tac_state is rewritten

    // DisableUse() — plats.cpp:1968.  HL does this in Use() just BEFORE calling
    // GoDown/GoUp, which means an SDK path that took the TRAIN_BLOCKING bail
    // above would leave m_use stuck at 0 and brick the entity.  Unreachable in
    // both (Use tests the same m_code first), but there is no reason to
    // reproduce the hazard: the latch is cleared only once the trip is committed.
    self.tc_use_enabled = FALSE;

    if (going_up)
    {
        self.tac_state = TC_GOING_UP;
        leg            = (1 - u) * self.tc_full_time;
    }
    else
    {
        self.tac_state = TC_GOING_DOWN;
        leg            = u * self.tc_full_time;
    }
    dest_track = Trackchange_DestTrack();

    Trackchange_UpdateAutoTargets(self.tac_state);

    self.tc_deadline = self.ltime + leg;

    // LinearMove + RotMove, set once for the whole leg (plats.cpp:608).  Both
    // rates come from the FULL trip, so the platform always moves at `speed`
    // whatever fraction of the path this leg covers.
    if (going_up)
    {
        self.velocity  = (self.tac_pos_top - self.tac_pos_bottom) * (1 / self.tc_full_time);
        self.avelocity = (self.tac_ang_top - self.tac_ang_bottom) * (1 / self.tc_full_time);
    }
    else
    {
        self.velocity  = (self.tac_pos_bottom - self.tac_pos_top) * (1 / self.tc_full_time);
        self.avelocity = (self.tac_ang_bottom - self.tac_ang_top) * (1 / self.tc_full_time);
    }
    self.SendFlags = 1;

    // Latch the carry frame BEFORE moving.  On a reversal the train is already
    // latched and must NOT be re-latched — its offset is stored at u = 0, which
    // is frame-independent, and re-reading t.origin here would fold in the
    // half-frame of motion the engine is about to roll back (the rotating push
    // path calls .blocked before restoring the pusher, sv_phys.c:883).
    t = self.tac_train_ent;
    if (self.tc_code == TC_TRAIN_FOLLOWING && t != world)
    {
        if (!self.tac_train_ofs_known)
            Trackchange_CaptureTrain(t);

        // HL sets `m_train->m_ppath = NULL` here (plats.cpp:1881 / 1918) to take
        // the train off its path for the trip.  Doing that literally is NOT safe
        // in this tree: func_tracktrain_use() treats a world .train_target as
        // "not initialised yet" and calls func_tracktrain_find_first(), which
        // TELEPORTS the train back to its first path_track
        // (server/sv_func_tracktrain.qc:400 and :499).  Any stray trigger during
        // the trip would therefore fling the train across the map.  Pointing it
        // at the destination chain now reaches the same end state — off the old
        // path — and trackchange_arrive() re-snaps it to the true nearest node.
        Trackchange_SetTrack(t, dest_track);
    }
    else
    {
        self.tac_train_ofs_known = 0;
    }

    Trackauto_PlayMoveSound();

    // Join the moving-brush list so PM_CheckMovingPushers carries riders, the
    // same way func_tracktrain does while in motion.  Idempotent, so the
    // reversal path re-entering here is harmless (sh_pmove.qc:3314).
    MovingBrush_AddToList(self);

    // nextthink MUST land strictly after .ltime.  A reversal that fires while
    // the platform is still sitting on the end it came from produces leg == 0,
    // and WPhys_Physics_Pusher only runs a think when `thinktime > oldltime`
    // (sv_phys.c:1162) — scheduling it AT .ltime would stall the entity for
    // good.  Short legs are clamped down to the deadline for the same reason
    // trackchange_move_tick clamps its last tick: so the platform is not driven
    // past its endpoint and snapped back.
    self.think     = trackchange_move_tick;
    self.nextthink = self.ltime + TC_TICK;
    if (leg < TC_TICK)
        self.nextthink = self.ltime + leg;
    if (self.nextthink <= self.ltime)
        self.nextthink = self.ltime + 0.001;
};

// CFuncTrackChange::Use (plats.cpp:1941).
//
// NOTE there is deliberately no ShouldToggle / sub_use_type gate here.  Unlike
// func_tracktrain (which does have one), CFuncTrackChange::Use ignores useType
// entirely and discriminates purely on which end it is parked at — so a
// multi_manager firing USE_TOGGLE, USE_ON or USE_OFF all just swap ends.
// th_ep1_04's "steamer_mngr" fires it as a bare multi_manager entry.
//
// CFuncTrackChange::Use has no UseEnabled() check either — only the
// CFuncTrackAuto subclass does (plats.cpp:2054).  The m_use latch is still
// honoured here, because a platform that is mid-trip because it REVERSED off a
// blocker must not accept a fresh trigger, and .tac_state alone would let it.
void() func_trackchange_use =
{
    if (!self.tc_resolved)
        Trackchange_Find();

    // Only actionable while parked at one end (plats.cpp:1943).
    if (self.tac_state != TC_AT_TOP && self.tac_state != TC_AT_BOTTOM)
        return;

    // DisableUse() is in force for the whole trip (plats.cpp:1968).
    if (!self.tc_use_enabled)
        return;

    Trackauto_FindTrain();          // refresh/repopulate .tac_train_ent

    if (self.tac_state == TC_AT_TOP)
        self.tc_code = Trackchange_EvaluateTrain(self.tc_track_top);
    else
        self.tc_code = Trackchange_EvaluateTrain(self.tc_track_bottom);

    if (self.tc_code == TC_TRAIN_BLOCKING)
    {
        // "If train is in safe area, but not on the elevator, play alarm sound"
        // — plats.cpp:1956.
        sound(self, CHAN_VOICE, "buttons/button11.wav", 1, ATTN_NORM);
        return;
    }

    if (self.tac_state == TC_AT_TOP)
        Trackchange_Go(FALSE);      // at top -> go down
    else
        Trackchange_Go(TRUE);       // at bottom -> go up
};

// CFuncPlat::Blocked (plats.cpp:497) — which IS what a blocked func_trackchange
// runs.
//
// CFuncTrackChange's own `virtual void Blocked( void );` is COMMENTED OUT at
// plats.cpp:1622.  That means it does not OVERRIDE, so the inherited
// CFuncPlat::Blocked (declared virtual at plats.cpp:230; CFuncPlatRot adds no
// override) is what CBaseEntity::Blocked dispatches to.  Stock HL does crush
// here, and it does two things:
//   1. `pOther->TakeDamage( pev, pev, 1, DMG_CRUSH )` — a FIXED 1 point.
//      `dmg` is offered by the FGD (@BaseClass BasePlat, sven-coop.fgd:1228) and
//      hl_c07_a1's trainlift authors "dmg" "75", but CFuncPlat::Blocked never
//      reads it.  Honouring 75 would kill a player outright where HL grinds them
//      down 1 point per blocked frame, so the SDK constant is used.
//   2. Sends the platform back the way it came — GOING_UP -> GoDown(),
//      GOING_DOWN -> GoUp().
//
// Half (2) is not cosmetic, it is what stops this entity bricking itself.  FTE
// advances a pusher's .ltime ONLY when the push succeeds
// (engine/server/sv_phys.c:1125, `if (WPhys_Push(...)) pusher->v->ltime +=
// movetime;`) and both push paths restore the pusher and return false when
// something is in the way (sv_phys.c:1069 / :896).  Every deadline in this file
// lives in .ltime, so a platform stalled against an obstruction that never moves
// has a FROZEN clock: trackchange_move_tick never fires again, arrive() never
// runs, the train is never relinked, and tc_use_enabled is never restored.
// Reversing restarts the clock, and because Trackchange_Go() measures its leg
// from Trackchange_Progress() the return trip is the true remaining distance
// rather than a full-length one.
void() func_trackchange_blocked =
{
    // Raw .health path, same as func_train_blocked / func_tracktrain_blocked —
    // which is why the cutscene_immune check that W_CanDamageTarget would
    // otherwise apply has to be repeated here.
    if (other && other.takedamage != DAMAGE_NO && !other.cutscene_immune)
        other.health = other.health - 1;

    // Reverse at most once per stall.  HL re-runs Blocked (and therefore
    // GoDown/GoUp, and therefore EMIT_SOUND of noiseMovement) on every blocked
    // frame, which flips direction 60+ times a second and re-emits the move
    // sound each time.  .ltime is frozen for exactly as long as the push keeps
    // failing, so gating on it fires the reversal once and then again only
    // after the platform has actually made progress — which is all the
    // un-bricking needs, and keeps the crush ticking at HL's 1/frame.
    if (self.tc_last_block == self.ltime)
        return;
    self.tc_last_block = self.ltime;

    if (self.tac_state == TC_GOING_UP)
        Trackchange_Go(FALSE);
    else if (self.tac_state == TC_GOING_DOWN)
        Trackchange_Go(TRUE);
};

/*QUAKED func_trackchange (.5 .5 .5) ? AUTO_ACTIVATE RELINK_TRACK x START_AT_BOTTOM ROTATE_ONLY x X_AXIS Y_AXIS
Track-changing platform / train elevator.  Carries a parked func_tracktrain
between the ends of two path_track chains and relinks the train onto the chain
it arrives at.  Fired by a button / multi_manager (contrast func_trackautochange,
which is fired by the train reaching a dead end).

"train"        targetname of the func_tracktrain to switch
"toptrack"     a path_track on the chain served by the TOP position
"bottomtrack"  a path_track on the chain served by the BOTTOM position
"height"       vertical travel; 0 = (brush height - 8)
"rotation"     total degrees turned between the two positions
"speed"        units/sec, or degrees/sec when ROTATE_ONLY (default 150)
"movesnd"      PlatSounds move enum 0..13
"stopsnd"      PlatSounds stop enum 0..8
"volume"       sound volume 0.0..1.0 (default 0.85)
"dmg"          accepted, no effect — CFuncPlat::Blocked crushes for a fixed 1
"rendermode" / "renderamt" / "rendercolor"   standard GoldSrc render fields
"targetname"   name; this entity must be triggered to do anything

AUTO_ACTIVATE   restart the train once the switch completes
RELINK_TRACK    accepted, no effect (dead bit in stock HL too, plats.cpp:1605)
START_AT_BOTTOM spawn at the BOTTOM position instead of the TOP
ROTATE_ONLY     turn in place; no vertical travel
X_AXIS          rotate about world X (roll) instead of Z
Y_AXIS          rotate about world Y (pitch) instead of Z
*/
void() func_trackchange =
{
    vector axis;
    vector ang_start;
    vector ang_end;
    float  travel;
    string snd;

    if (!self.model)
    {
        remove(self);
        return;
    }

    // CFuncPlat::Setup DISCARDS the authored angles outright
    // (`pev->angles = g_vecZero;`, plats.cpp:1284) and SetupRotation then builds
    // the two end angles from zero.  Not an oversight to be "fixed": hl_c07_a1's
    // trackchange ships "angles" "90 0 0", and honouring it would put the
    // 720-degree lift 90 degrees out at both ends.  Zeroed BEFORE the model is
    // set so the brush is linked with the angles it will actually spawn at.
    self.angles = '0 0 0';

    // Brushsync wire.  This also performs the setmodel / MOVETYPE_PUSH /
    // SOLID_BSP / render-key work (server/sv_brushsync.qc:564-566), so none of
    // that is repeated here; CSQC needs it to see the motion and to run the
    // rider carry / push pass.  BRUSH_TYPE_TRAIN is what both func_train and
    // func_tracktrain use — there is no separate plat type.
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;

    if (self.speed <= 0)  self.speed  = 150;    // plats.cpp:1300
    if (self.volume <= 0) self.volume = 0.85;   // plats.cpp:1303.  0.0-1.0 here,
                                                // per the FGD's PlatSounds base
                                                // — NOT the 0-10 that
                                                // func_tracktrain has to rescale.

    // CFuncPlatRot::SetupRotation (plats.cpp:543).  The rotation axis comes from
    // the spawnflags via CBaseToggle::AxisDir (subs.cpp:544), which is exactly
    // what Trackauto_RotAxis() already implements — bit 64 ("X Axis" in the FGD)
    // maps to angles_z/roll, bit 128 ("Y Axis") to angles_x/pitch, default to
    // angles_y/yaw.  The FGD labels and the QC components genuinely do cross
    // over like that; see the note in server/sv_func_trackautochange.qc:87.
    ang_start = '0 0 0';
    ang_end   = '0 0 0';
    if (self.rotation != 0)
    {
        axis    = Trackauto_RotAxis();
        ang_end = axis * self.rotation;
    }

    // m_vecPosition1 is the TOP (the position the mapper placed the brush at),
    // m_vecPosition2 the BOTTOM (plats.cpp:1293).  START_AT_BOTTOM does NOT
    // redefine which is which — it only decides where the brush sits at spawn
    // (plats.cpp:1687).  This differs from func_trackautochange in this tree,
    // which treats the placed position as the bottom; the SDK reading is the one
    // that makes hl_c07_a1's 912-unit "trainlift" start down the shaft and rise
    // to the placed brush, rather than rising 912 units above it.
    self.tac_pos_top    = self.origin;
    self.tac_pos_bottom = self.origin;

    if (self.spawnflags & SF_TAC_ROTATE_ONLY)
        travel = 0;                             // SF_TRACK_DONT_MOVE, plats.cpp:1681
    else if (self.height != 0)
        travel = self.height;
    else
        travel = self.size_z - 8;               // plats.cpp:1299.  .size is valid:
                                                // SV_InitReplicatedSolidBrush has
                                                // already run setmodel.

    self.tac_pos_bottom_z = self.origin_z - travel;

    // m_start is the BOTTOM angle, m_end the TOP angle (plats.cpp:1689/1696).
    self.tac_ang_bottom = ang_start;
    self.tac_ang_top    = ang_end;

    // Duration of the complete bottom<->top trip.  With SF_TRACK_DONT_MOVE
    // ("Rotate Only") HL calls AngularMove(dest, pev->speed), which derives the
    // time from the ANGULAR distance (subs.cpp, CBaseToggle::AngularMove) —
    // speed is degrees/sec.  Otherwise LinearMove sets the time from the linear
    // distance and RotMove is paced to match it (plats.cpp:1862-1874, 608).
    // Floored at one tick so a degenerate trip (th_ep1_04 spins 3 degrees at
    // speed 100 => 0.03s) still gets an integrated frame instead of a deadline
    // that is already in the past.
    if (self.spawnflags & SF_TAC_ROTATE_ONLY)
        self.tc_full_time = vlen(self.tac_ang_top - self.tac_ang_bottom) / self.speed;
    else
        self.tc_full_time = vlen(self.tac_pos_top - self.tac_pos_bottom) / self.speed;
    if (self.tc_full_time < TC_TICK)
        self.tc_full_time = TC_TICK;

    if (self.spawnflags & SF_TAC_START_AT_BOTTOM)
    {
        setorigin(self, self.tac_pos_bottom);
        self.angles    = self.tac_ang_bottom;
        self.tac_state = TC_AT_BOTTOM;
    }
    else
    {
        setorigin(self, self.tac_pos_top);
        self.angles    = self.tac_ang_top;
        self.tac_state = TC_AT_TOP;
    }

    self.tc_use_enabled = TRUE;                 // EnableUse(), plats.cpp:1701
    self.tc_last_block  = -1;                   // never equal to a real .ltime

    // th_ep1_04's is rendermode 2 with renderamt unset, i.e. deliberately
    // invisible — it is a junction switch, not scenery.
    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    snd = FuncTrain_MoveSound(self.movesnd);
    if (snd != "")
        precache_sound(snd);
    snd = FuncTrain_StopSound(self.stopsnd);
    if (snd != "")
        precache_sound(snd);
    precache_sound("buttons/button11.wav");     // "Can't trigger" — plats.cpp:1711

    self.use     = func_trackchange_use;
    self.blocked = func_trackchange_blocked;

    // Deferred resolve.  .ltime, not time — see trackchange_move_tick.
    self.think     = Trackchange_Find;
    self.nextthink = self.ltime + 0.5;
};
