//
// sv_trigger_createentity.qc — Sven Co-op trigger_createentity
//
// Spawns a child entity at runtime when used.  The child's class and name
// come from two named keys; everything else the mapper wants to set on it
// is written as an ordinary keyvalue with a '-' glued to the front, and is
// copied onto the child with the '-' stripped:
//
//     "m_iszCrtEntChildClass" "monster_barney"     <- what to create
//     "m_iszCrtEntChildName"  "barney"             <- its targetname
//     "-spawnflags"           "6"                  \
//     "-TriggerCondition"     "4"                   > replayed onto the child
//     "-origin"               "2437 142 -639"      /
//
// 7 placements across 6 maps (hc2_c2 x2, hc2_c4, hc2_c5, hc2_c6, hc2_c7,
// hc2_s2), creating monster_barney, func_breakable and ammo_rpgclip.
//
//
// WHY THE TWO NAMED KEYS ARE DECLARED ALL-LOWERCASE
// -------------------------------------------------
// Every map in the corpus spells them CamelCase and m_-prefixed, and
// ED_FindField is a plain strcmp — so the engine never binds them and the key
// falls through to ED_ParseUnknownEpair (server/sv_multi_manager.qc).  The
// FIRST thing that hook does is call GoldSrc_TryCaseFoldedField, which folds
// the key to lower case and retries the field lookup; it sits deliberately
// ABOVE the "m_" prefix discard for exactly this case.  Only a lowercase
// declaration can be hit that way.  server/sv_mapglobals.qc's
// .string m_iszlevelname is the same pattern, verified live by the
// "[keyfold] m_iszLevelName -> m_iszlevelname" line it prints.
//
//
// THE '-' KEYS
// ------------
// Harvested at parse time by the '-' branch in ED_ParseUnknownEpair onto a
// chain of "ce_key" nodes (gpe_first_item / gpe_next_item, with the payload in
// .ce_child_key / .ce_child_value — see the block in server/sv_customdefs.qc).
// Replayed here through findentityfield / putentityfieldstring, with the same
// two recoveries a key from the BSP would get if it missed: the case fold, then
// the unknown-key hook itself, both with `self` bound to the CHILD.  That is
// what makes a key behave identically whether it arrived from the entity lump
// or from here — "-$i_monsteramount", for instance, ends up in the Sven custom
// keyvalue store exactly as "$i_monsteramount" on a map-placed entity would.
//
// The corpus '-' set is: origin, angles, spawnflags, model, health, target,
// material, delay, movetype, rendercolor, TriggerCondition, TriggerTarget,
// UseSentence, UnUseSentence, m_flCustomRespawnTime.  All of them bind except
// UseSentence / UnUseSentence, which no field in the tree declares — a barney
// created this way will not carry its custom "+use" line.  Those are counted
// and reported as `dropped=N` under sv_debug_use rather than being discarded in
// silence, because the alternative is a key that fails invisibly for years.
//

// The two named keys.  ALL-LOWERCASE ON PURPOSE — see the header.
.string m_iszcrtentchildclass;
.string m_iszcrtentchildname;

// Apply one harvested key to `c`.  Returns TRUE if it provably landed on a
// declared field, FALSE if it only reached the unknown-key hook (which has no
// return value, so a claim there is indistinguishable from a drop and is
// counted as a drop — pessimistic on purpose).
float(entity c, string k, string v) CreateEnt_ApplyKey =
{
    float  ok    = FALSE;
    entity saved = self;

    float fld = findentityfield(k);
    if (fld > 0)
    {
        // Note findentityfield returns 0 both for "field zero" and for "no
        // such field"; > 0 is the same convention GoldSrc_TryCaseFoldedField
        // uses and for the same reason.
        putentityfieldstring(fld, c, v);
        return TRUE;
    }

    // `self` has to be the child for both fallbacks: GoldSrc_TryCaseFoldedField
    // writes through putentityfieldstring(fld, self, ...) and
    // ED_ParseUnknownEpair's harvest blocks assign onto self directly.
    self = c;
    ok = GoldSrc_TryCaseFoldedField(k, v);
    if (!ok)
        ED_ParseUnknownEpair(k, v);
    self = saved;

    return ok;
};

void() trigger_createentity_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    string cls = self.m_iszcrtentchildclass;
    if (cls == "" || cls == __NULL__)
    {
        dprint(sprintf("trigger_createentity \"%s\": no m_iszCrtEntChildClass, nothing to create\n",
                       self.targetname));
        return;
    }

    entity ce      = self;
    entity child   = spawn();
    entity saved   = self;
    entity n       = world;
    float  applied = 0;
    float  dropped = 0;
    // Captured before the dispatch: a child's spawn function is free to fire
    // things of its own and clobber the global.
    float  ut      = sub_use_type;

    self = child;

    // Classname and placement BEFORE the dispatch, exactly as
    // Breakable_SpawnObject (server/sv_goldsrc_ammo.qc) does it: the spawn
    // functions setmodel / setsize / floor-snap against wherever the entity
    // already is, and several of them never set a classname of their own
    // (a map-placed one gets it from the entity lump; a synthetic spawn has
    // no lump).  The child inherits the trigger's own placement, which
    // "-origin" / "-angles" then override if the mapper supplied them.
    self.classname = cls;
    self.angles    = ce.angles;
    setorigin(self, ce.origin);
    if (ce.m_iszcrtentchildname != "" && ce.m_iszcrtentchildname != __NULL__)
        self.targetname = ce.m_iszcrtentchildname;

    n = ce.gpe_first_item;
    while (n != world)
    {
        if (CreateEnt_ApplyKey(child, n.ce_child_key, n.ce_child_value))
            applied = applied + 1;
        else
            dropped = dropped + 1;
        n = n.gpe_next_item;
    }

    // putentityfieldstring writes the field and NOTHING else — it does not
    // relink the edict — so a "-origin" would leave absmin/absmax and the area
    // links sitting on the trigger's position while .origin said otherwise.
    // Re-link before the dispatch, while the spawn function can still see it.
    setorigin(self, self.origin);

    // Dispatch by name.  spawnfunc_<class> FIRST, because that is the order FTE
    // itself resolves a map's classname in (DP_SV_SPAWNFUNC_PREFIX,
    // engine/server/pr_cmds.c:1836) — see the note on spawnfunc_trigger_condition
    // in server/sv_th_entities.qc.  Trying the bare name first would call a
    // different function than the entity lump would for the same classname.
    string sfn = strcat("spawnfunc_", cls);
    if (isfunction(sfn))
        callfunction(sfn);
    else if (isfunction(cls))
        callfunction(cls);
    else
        SV_OnEntityNoSpawnFunction();   // same last-resort relay a map-placed
                                        // unknown classname gets

    self = saved;

    // modelindex is in the line on purpose.  A child created from a "-model"
    // key is the one case where the entity can come out fully wired and still
    // be invisible and non-solid — hc2_s2 passes "*158", a BSP submodel that
    // only resolves if the key landed BEFORE the spawn function's setmodel —
    // and 0 there is the single cheapest signal that it did not.
    if (cvar("sv_debug_use"))
        print(sprintf("[createentity] \"%s\" created %s \"%s\" at %v modelindex=%g (keys applied=%g dropped=%g)\n",
                      self.targetname, cls, child.targetname, child.origin,
                      child.modelindex, applied, dropped));

    // The harvested chain is deliberately KEPT — these fire more than once
    // (hc2_c5's create_barney is wired to two separate trigger_changevalues),
    // and a consumed chain would make every firing after the first produce a
    // bare, keyless child.

    SUB_UseTargets(self, activator, ut);
};

/*QUAKED trigger_createentity (.5 .5 .5) (-8 -8 -8) (8 8 8)
Sven Co-op: creates an entity at runtime each time it is used.

"m_iszCrtEntChildClass"  Classname to create (required).
"m_iszCrtEntChildName"   Targetname to give the created entity.
"-<key>"                 Any key prefixed with '-' is copied onto the created
                         entity with the '-' stripped, e.g. "-health" "96".
                         "-origin" / "-angles" override the placement the
                         child otherwise inherits from this entity.
"master"                 Multisource that must be active for this to fire.
"target"                 Fired after the child is created.

Can fire any number of times; the '-' key set is retained between firings.
*/
void() trigger_createentity =
{
    self.use = trigger_createentity_use;
};
