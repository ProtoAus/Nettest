// ===========================================================================
//  sv_customkeys.qc — Sven Co-op's "$" custom keyvalues
// ===========================================================================
//
// Sven lets a mapper invent keyvalues on any entity so long as the name carries
// a type prefix:
//
//      $s_name   string      $i_name   integer
//      $f_name   float       $v_name   vector
//
// They are pure storage.  Nothing in the engine reads them; they exist so that
// trigger_condition can compare one and trigger_changevalue / trigger_copyvalue
// can write one, which together give a mapper a general-purpose variable.
//
// Until now this tree discarded them.  ED_ParseUnknownEpair's `$` prefix return
// (sv_multi_manager.qc) threw the pair away, and trigger_condition's own header
// said so in as many words: "Sven's own $i_ / $s_ / $f_ / $v_ custom keyvalues
// have no QC representation.  A check monitoring one of those resolves nothing
// and fires neither chain."
//
// WHY THIS CANNOT BE A FIELD.  A QC field has to be declared at compile time and
// these names are invented per map — 93 distinct ones across the corpus, and a
// mapper is free to coin a 94th tomorrow.  So they live in a side table keyed by
// (entity, name) instead, and every reader goes through CustomKey_Get.
//
// SIZING.  Measured over the whole map corpus, ignoring bspguy's tool metadata:
// 24 maps use them at all, and the heaviest (botparty) carries 348.  512 slots
// covers that with room to spare and costs 3 arrays of 512 — nothing next to the
// edict table.  An overflow is announced rather than silently dropped, because a
// silently-missing variable presents as a puzzle that never opens.
//
// ---------------------------------------------------------------------------

const float CKV_MAX = 512;

entity ckv_owner[CKV_MAX];
string ckv_key[CKV_MAX];
string ckv_val[CKV_MAX];
float  ckv_count;
float  ckv_overflow;        // announced once per map, not once per key
float  ckv_reported;        // census line is one-shot per map

// ---------------------------------------------------------------------------
// Is this key one of Sven's four custom-keyvalue spellings?
//
// The prefix test is deliberately strict.  A bare "$foo" is NOT a custom
// keyvalue in Sven — the type letter is what tells trigger_condition how to
// compare it — and claiming every $-prefixed key would also swallow bspguy's
// "$s_bspguy_map_source" metadata, which sits on hundreds of entities in the
// merged maps and would eat the table on its own.  That one is excluded by name
// below rather than by prefix, so a real "$s_bspguy..." variable would still
// work if a mapper ever coined one.
// ---------------------------------------------------------------------------
float(string key) CustomKey_IsCustom =
{
    string p;

    if (substring(key, 0, 1) != "$")
        return FALSE;

    p = substring(key, 1, 2);
    if (p != "s_" && p != "i_" && p != "f_" && p != "v_")
        return FALSE;

    // bspguy stamps every entity it merges.  Not a gameplay variable.
    if (substring(key, 0, 10) == "$s_bspguy_")
        return FALSE;

    return TRUE;
};

// The EV_* type the prefix implies, so trigger_condition knows whether to
// compare as a string, a number or a vector.
float(string key) CustomKey_Type =
{
    string p = substring(key, 1, 2);
    if (p == "s_") return EV_STRING;
    if (p == "v_") return EV_VECTOR;
    return EV_FLOAT;                    // $i_ and $f_ both compare numerically
};

// Slot index for (e, key), or -1.
float(entity e, string key) CustomKey_Slot =
{
    float i;

    i = 0;
    while (i < ckv_count)
    {
        if (ckv_owner[i] == e && ckv_key[i] == key)
            return i;
        i = i + 1;
    }
    return -1;
};

float(entity e, string key) CustomKey_Has =
{
    return CustomKey_Slot(e, key) >= 0;
};

// "" when the entity carries no such key.  Callers that need to tell "absent"
// from "present and empty" must use CustomKey_Has — the same distinction
// getentityfieldstring cannot make for a zero-valued field.
string(entity e, string key) CustomKey_Get =
{
    float s = CustomKey_Slot(e, key);
    if (s < 0)
        return "";
    return ckv_val[s];
};

void(entity e, string key, string value) CustomKey_Set =
{
    float s;

    s = CustomKey_Slot(e, key);
    if (s >= 0)
    {
        // Replacing a value: release the old zone before dropping the reference,
        // or a map that writes the same variable every tick leaks steadily.
        if (ckv_val[s] != "")
            strunzone(ckv_val[s]);
        ckv_val[s] = strzone(value);
        return;
    }

    if (ckv_count >= CKV_MAX)
    {
        if (!ckv_overflow)
        {
            ckv_overflow = TRUE;
            print(sprintf("[customkey] table full at %g entries — \"%s\" and any "
                          "further custom keyvalues on this map are DROPPED\n",
                          CKV_MAX, key));
        }
        return;
    }

    // strzone both halves: at parse time `key` and `value` are PR_TempStrings
    // owned by the engine's rotating buffer, exactly as sv_multi_manager.qc
    // documents for m_iszEntity.
    ckv_owner[ckv_count] = e;
    ckv_key[ckv_count]   = strzone(key);
    ckv_val[ckv_count]   = strzone(value);
    ckv_count            = ckv_count + 1;
};

// ---------------------------------------------------------------------------
// Per-map teardown.  Called from worldspawn.
//
// FTE does not reload progs between maps, so without this the table would carry
// the previous map's variables into the next one — and every string in it is
// zoned, so it would also leak a map's worth of allocations each level change.
// ---------------------------------------------------------------------------
void() CustomKey_ResetForMap =
{
    float i;

    i = 0;
    while (i < ckv_count)
    {
        if (ckv_key[i] != "") strunzone(ckv_key[i]);
        if (ckv_val[i] != "") strunzone(ckv_val[i]);
        ckv_key[i]   = "";
        ckv_val[i]   = "";
        ckv_owner[i] = world;
        i = i + 1;
    }
    ckv_count    = 0;
    ckv_overflow = FALSE;
    ckv_reported = FALSE;
};

// Census line, mirroring the other subsystems' load-time reports.
//
// Self-gating and one-shot per map (CustomKey_ResetForMap re-arms it), because
// the only place with an "every entity has spawned" guarantee is StartFrame,
// which runs every tick.  Same shape as mm_collide_done.
void() CustomKey_Report =
{
    if (ckv_reported)
        return;
    ckv_reported = TRUE;

    if (ckv_count)
        print(sprintf("[customkey] %g custom keyvalue(s) harvested\n", ckv_count));
};
