//
//  sv_item_inventory.qc  –  Sven Co-op "item_inventory" + the InventoryRules gate
//
//  Sven's inventory system is TWO things, and implementing only the first one
//  leaves every map that uses it visibly broken in the same way:
//
//    1. item_inventory — a carriable object.  A player picks it up (by touch,
//       by +use, or because a trigger handed it over), holds it, and can drop
//       it again.  While held it can modify the holder: slow them down, block
//       their weapons, change their gravity.
//
//    2. InventoryRules — a block of keys that ANY of eleven other entity
//       classes can carry, which gate whether that entity fires for the
//       activator.  "This door only opens if you are carrying the keycard."
//       "This trigger only fires if you have NO quest item on you."
//
//  th_escape is the map that made this worth writing, and it needs both.  It
//  places 12 item_inventory (a car battery, a gas can and a toolbox, each at
//  several alternative spawn points, for two vehicles) and then puts
//  `item_name_required` on 15 trigger_once and `item_group_required` on a
//  further 11 trigger_once/trigger_multiple.
//
//  Getting only half of it is WORSE than having neither, which is why they
//  land together.  Before this file, th_escape's three drop-off pads at the
//  truck were plain trigger_once with no gate: walking over them fired
//  veh1_itm1goalmm / veh1_itm2goalmm / veh1_itm3goalmm outright, drove the
//  veh1_itmcount game_counter (health 3) to its threshold and "repaired" the
//  truck the first time anybody wandered past — the entire fetch quest, which
//  is the whole map, completed itself in the first few seconds.  Adding the
//  item without the gate would have left that exactly as it was.
//
//  ---------------------------------------------------------------------------
//  SOURCES
//
//  Everything here is read out of Sven's own shipped files rather than
//  recalled:
//    - svencoop/sven-coop.fgd:  @PointClass ... = item_inventory  (the full
//      keyvalue table, with types and defaults), @BaseClass = InventoryRules
//      (the gate keys), @BaseClass = Pickup (the four collection spawnflags).
//    - svencoop/manual/changelog.html, the item_inventory release notes: the
//      collection rules, the 100-weight carry cap, the remote-control USE
//      semantics, and the list of the eleven classes that honour the gate.
//
//  The FGD is the authority for DEFAULTS, and the defaults are the reason
//  several keys below are .string rather than .float: an absent key leaves a
//  .float at 0, which is indistinguishable from an explicit "0", and four of
//  these keys have a non-zero default (carried_hidden 1, holder_can_drop 1,
//  holder_timelimit_wait_until_activated 1, return_timelimit 60, weight 1.0,
//  and the four effect_* percentages 100).  Reading those through a string
//  keeps "absent" and "zero" apart.  See Inv_Num / Inv_Pct / Inv_Bool.
//
//  ---------------------------------------------------------------------------
//  WHAT th_escape ACTUALLY EXERCISES
//
//  Of the ~60 keys the FGD lists, th_escape sets these — so this is the subset
//  that is proven by playing the map, and everything else is implemented from
//  the FGD but exercised by nothing on disk:
//
//    item_name, item_group, item_name_canthave, item_icon, display_name,
//    description, weight 16, return_timelimit (5 or 60),
//    holder_can_drop 1, holder_timelimit_wait_until_activated 1,
//    target_on_materialise, carried_sequence 2, carried_sequencename,
//    sequencename "not_carried", sequence 1, spawnflags 1280,
//    effect_block_weapons 1, effect_speed 50.0,
//    and effect_damage / effect_gravity / effect_friction at 100.0 and
//    effect_respiration at 0.0 — i.e. explicitly written no-ops.
//
//  spawnflags 1280 = 1024 (Disable Respawn) + 256 (USE Only).  So th_escape's
//  items are +use-only, exactly as reported, and they do not respawn where
//  they were taken from — they RETURN there on the return_timelimit instead.
//
//  Two effects therefore carry the map: effect_speed 50 (you move at half
//  speed with a car battery in your arms) and effect_block_weapons 1 (both
//  hands are full, so you cannot shoot).  Those two are the ones that had to
//  be right; see the prediction note below.
//
//  ---------------------------------------------------------------------------
//  PREDICTION
//
//  effect_speed changes how fast the player moves, and movement in this mod is
//  CLIENT-PREDICTED.  A server that quietly halves maxspeed while CSQC keeps
//  predicting the full value rubber-bands the player on every step.
//
//  So the aggregate is not applied here at all.  Inv_RecalcEffects folds every
//  held item down to four scalars on the PLAYER — pm_inv_speed_pct,
//  pm_inv_gravity_pct, pm_inv_friction_pct, pm_inv_blockfire — those ride the
//  CSQC prediction proxy (sv_player.qc's writer / cl_player.qc's reader, proxy
//  version 26), and shared/sh_pmove.qc reads them on BOTH sides.  That is the
//  same shape Prop Hunt's disguise hull already uses at sh_pmove.qc:3024 and
//  the reason its slowed cap does not rubber-band either.
//
//  effect_block_weapons rides the identical mechanism the HL2 carry already
//  had: pm_carrying lowers the viewmodel and blocks fire in one shared gate.
//  "Both hands on the prop" and Sven's "carried with both hands" are the same
//  statement, so pm_inv_blockfire is ORed in beside it rather than duplicating
//  the envelope.
//
//  ---------------------------------------------------------------------------
//  A HELD ITEM CAN BE DESTROYED OUT FROM UNDER US
//
//  th_escape's veh1_itm1_killmm is a multi_manager whose slots are
//  "veh1_itm1_loc1" "0#2", and Sven's "#2" suffix means KILL — which this mod
//  implements as SUB_KillTargets, i.e. find-by-name + remove()
//  (sv_multi_manager.qc:348).  That fires the moment an item is delivered, and
//  the item it removes may be the one a player is holding RIGHT NOW.
//
//  A hard remove() cannot be intercepted, so the holder's chain must survive
//  finding a freed entity in it.  Inv_Prune walks the chain, drops anything
//  wasfreed() reports, and recomputes the effects — otherwise a player whose
//  battery was killed mid-carry would keep the 50% speed penalty for the rest
//  of the round with nothing in their hands to explain it.  It runs from the
//  holder tick, so it is never more than one frame stale.
//

// ---------------------------------------------------------------------------
//  Externs from earlier compile units.
// ---------------------------------------------------------------------------
void(entity caller, entity who, float useType)  SUB_UseTargets;      // sv_triggers.qc
float(string name, entity who, float useType)   SV_FireTargetsByName;// sv_triggers.qc
void()                                          BrushSync_ApplyRenderKeys; // sv_brushsync.qc

// ---------------------------------------------------------------------------
//  Spawnflags come from @BaseClass = Pickup in sven-coop.fgd, which
//  item_inventory shares with every weapon and ammo pickup in the game — so
//  PICKUP_SF_TOUCH_ONLY / _USE_ONLY / _USE_NO_LOS / _NO_RESPAWN are already
//  declared at sv_weapons.qc:2902-2905 (position 45, well before this file)
//  and are REUSED rather than respelled.  item_generic declares its own copies
//  (sv_item_generic.qc:41-45), which is the thing not to imitate: three
//  spellings of one FGD block is how they drift.
//
//  The routing those flags describe is already implemented too, at
//  sv_weapons.qc:3113-3125, and this file follows the same discriminator:
//  sv_use_is_player_direct is TRUE only inside SV_PlayerTryUse, so it is what
//  separates "walked over it" from "pressed +use on it".  Sven's decision
//  table, for the record:
//
//      neither flag  ->  touch, +use and trigger all collect
//      TOUCH_ONLY    ->  touch only
//      USE_ONLY      ->  +use only (LoS required unless USE_NO_LOS)  <- th_escape
//      BOTH          ->  neither; only a trigger can hand it over
//
//  That last row is a genuine trap rather than a belt-and-braces setting, and
//  it is why the two checks below are separate early-outs rather than an
//  either/or.
// ---------------------------------------------------------------------------

// "Weight (players can carry up to 100 weight)" — changelog.html, the
// item_inventory release notes.  th_escape's items weigh 16 apiece, so the cap
// is not what stops you carrying two of them; item_name_canthave is.
const float INV_MAX_WEIGHT = 100;

// Item lifecycle.  IDLE is the only state a player can collect from.
const float INV_IDLE      = 0;   // sitting where it spawned (or where it was dropped and settled)
const float INV_HELD      = 1;   // in somebody's inventory
const float INV_DROPPED   = 2;   // on the ground, return_timelimit counting down
const float INV_AWAY      = 3;   // returned and waiting out return_delay_respawn

const float INV_TICK = 0.1;

// How many items the HUD event will describe.  The weight cap allows far more
// in principle (100 / weight 1.0); every map on disk carries at most one at a
// time, and a HUD strip is not the place to discover otherwise.  Overflow is
// counted, not silently dropped — see Inv_SendHud.
const float INV_HUD_MAX = 8;

// ---------------------------------------------------------------------------
//  Item fields.
//
//  The InventoryRules keys are NOT here — they live in sv_customdefs.qc
//  (position 22) because sv_doors.qc (185), sv_trigger_once_multi.qc (193),
//  sv_buttons.qc (215), sv_trigger_hurt.qc (221) and sv_trigger_changelevel.qc
//  (241) all read them, and every one of those compiles BEFORE this file.
//  Functions forward-declare in QC; fields do not.  Same reasoning, and the
//  same wording, as `spawnobject` at sv_customdefs.qc:852.
//
//  .sequencename / .minhullsize / .maxhullsize / .scale / .body come from
//  sv_item_generic.qc (position 264) and the engine defs — this file sits
//  immediately after it precisely so they can be shared rather than redeclared.
// ---------------------------------------------------------------------------
.string item_name;          // this item's identity, matched by item_name_required
.string item_group;         // one group per item; matched by item_group_required
.string display_name;       // HUD label
.string description;        // HUD sub-label
.string item_icon;          // HUD sprite, relative to sprites/ (see Inv_IconPath)
.float  activate_limit;     // self-activations before destruction (0 = infinite)
.float  collect_limit;      // collections before destruction (0 = infinite)
.string weight;             // 0..100, default 1.0

// Collection filters (FGD "Collect: ..."), evaluated against the would-be holder.
.string filter_targetnames; // semicolon list of player targetnames
.string filter_classnames;
.string item_name_moved;
.string item_name_not_moved;

// Carried appearance.
.string carried_hidden;     // default 1 (YES, hidden in third person)
.float  carried_skin;
.float  carried_body;
.string carried_sequencename;
// .string, not .float, and for a reason that bites nowhere else in this tree.
// The FGD types this "Sequence Number (overrides name)" with a default of ONE,
// so unlike the idle `sequence` key — whose default is 0, making "absent" and
// "0" mean the same thing — a numeric field here could not tell an absent key
// from a mapper who deliberately asked for sequence 0.  Read through a string,
// absent falls through to carried_sequencename and an explicit "0" selects
// sequence 0.  item_generic's `if (self.sequence > 0)` idiom
// (sv_item_generic.qc:121) has the latent version of this bug; it is harmless
// there because that key's default really is 0.
.string carried_sequence;

// Return / respawn.
.string return_timelimit;   // seconds after a drop before it goes home; -1 = never; default 60
.float  return_delay_respawn;

// Holder rules.
.string holder_timelimit;                        // 0 = no limit
.string holder_time_activate_wait;
.string holder_time_wearout;
.float  holder_can_activate;
.string holder_timelimit_wait_until_activated;   // default 1
.string holder_can_drop;                         // default 1
.float  holder_keep_on_death;
.float  holder_keep_on_respawn;

// Event targets.  Sven also defines _team and _other variants of most of these;
// they are parsed into the same fields' *_other/_team spellings only where a
// map on disk uses them, which today is none — see the header.
.string target_on_collect;
.string target_cant_collect;
.string target_on_drop;
.string target_cant_drop;
.string target_on_activate;
.string target_cant_activate;
.string target_on_use;
.string target_on_wearing_out;
.string target_on_return;
.string target_on_materialise;
.string target_on_destroy;

// Effects applied to the holder.
.float  effects_wait_until_activated;
.float  effects_permanent;
.vector effect_glow;
.float  effect_block_weapons;
.float  effect_invulnerable;
.float  effect_invisible;
.float  effect_nonsolid;
.string effect_respiration;
.string effect_friction;     // %, default 100
.string effect_gravity;      // %, default 100
.string effect_speed;        // %, default 100
.string effect_damage;       // %, default 100

// Runtime state on the ITEM.
.float  inv_state;
.entity inv_holder;          // the player carrying it (world when not held)
.entity inv_next;            // next item in the holder's chain
.vector inv_home;            // spawn origin, for the return
.vector inv_home_angles;
.float  inv_return_at;       // time the drop returns home (0 = not counting)
.float  inv_hold_until;      // time holder_timelimit expires (0 = no limit)
.float  inv_wearout_done;    // holder_time_wearout has already fired this hold
.float  inv_activated;       // has been self-activated at least once
.float  inv_collects;        // how many times it has been collected
.float  inv_activates;
.float  inv_moved;           // has ever left its spawn origin (item_name_moved)
.float  inv_idle_frame;      // resolved .frame for the not-carried pose
.float  inv_carried_frame;   // resolved .frame for the carried pose

// Runtime state on the PLAYER.
.entity inv_head;            // first carried item
.float  inv_weight;          // running sum of the chain's weights
.float  inv_serial;          // bumped on every change; drives the HUD send
.float  inv_sent_serial;
// effects_permanent latch.  The FGD calls it "Permanent? (Until respawn)", so
// these survive the item leaving and are cleared in Inv_PlayerReset.  0 means
// "nothing latched" rather than "latched a zero", which is why they are
// multipliers and not percentages.
.float  inv_perm_speed;
.float  inv_perm_gravity;
.float  inv_perm_friction;
.float  inv_perm_damage;
.float  inv_perm_block;
// The server-only half of the aggregate.  These are NOT replicated because
// nothing about them is predicted: damage scaling is applied where damage is
// dealt, and the other three are pure server state.
.float  inv_damage_scale;    // effect_damage, as a multiplier (1 = unchanged)
.float  inv_invulnerable;    // effect_invulnerable
.float  inv_air_bonus;       // effect_respiration, extra seconds before drowning
.float  inv_solid_saved;     // pre-effect_nonsolid .solid, so it can be put back
.float  inv_glow_on;         // effect_glow is currently painting this player
.float  inv_invis_on;        // effect_invisible is currently hiding this player
.float  inv_alpha_saved;     // pre-effect_invisible .alpha

// ---------------------------------------------------------------------------
//  Small readers.
// ---------------------------------------------------------------------------

// QC leaves an unset .string field as the null string, and this tree compares
// against BOTH spellings everywhere it matters (SUB_UseTargets does it at
// sv_triggers.qc:154).  One helper so the rest of the file reads cleanly.
float(string s) Inv_HasStr =
{
    if (s == __NULL__) return FALSE;
    if (s == "")       return FALSE;
    return TRUE;
};

// A numeric key whose FGD default is non-zero.  Absent → def; present → its
// value, INCLUDING an explicit 0.
float(string s, float def) Inv_Num =
{
    if (!Inv_HasStr(s)) return def;
    return stof(s);
};

// A percentage key (effect_speed and friends).  Returns a MULTIPLIER.
// Absent → 1.0, "100.0" → 1.0, "50.0" → 0.5.
float(string s) Inv_Pct =
{
    return Inv_Num(s, 100) * 0.01;
};

// A choices key whose FGD default is 1.
float(string s) Inv_BoolDefTrue =
{
    return (Inv_Num(s, 1) != 0);
};

// The list separator.
//
// Sven's two wiki pages disagree: the item_inventory page says "Use semicolon
// ' ; ' to separate multiple item/target/group names in filters and
// conditions", and the InventoryRules page says spaces.  Every multi-value key
// in th_escape settles it in favour of the semicolon — "veh1_itm2;veh1_itm3",
// no spaces anywhere — but the engine's own parser is a generic
// CheckTokenStringRule, so a map written against the other page must not break
// here.  Normalising spaces to semicolons up front accepts both without
// needing two code paths, and costs nothing on the values that are already
// well formed.  Item names in Sven do not contain spaces, so there is nothing
// for this to damage.
string(string list) Inv_NormList =
{
    return strreplace(" ", ";", list);
};

// Exact-token membership in the list, without tokenize().
//
// tokenizebyseparator writes GLOBAL parser state, so a tokenize inside a loop
// that is itself walking a tokenize result silently corrupts the outer walk.
// Every membership test in this file goes through here instead, which makes
// the whole file re-entrant with respect to argv().  The ";" padding is what
// makes it exact: without it "itm1" would match "veh1_itm12".
float(string list, string name) Inv_ListHas =
{
    if (!Inv_HasStr(list)) return FALSE;
    if (!Inv_HasStr(name)) return FALSE;
    return strstrofs(strcat(";", Inv_NormList(list), ";"), strcat(";", name, ";")) >= 0;
};

// Sven writes item_icon relative to sprites/ ("th_escape/item_battery_72.spr"
// resolves to svencoop/sprites/th_escape/item_battery_72.spr).  Accept a value
// that already carries the prefix so a map that spells it out still works.
string(string icon) Inv_IconPath =
{
    if (!Inv_HasStr(icon)) return "";
    if (substring(icon, 0, 8) == "sprites/") return icon;
    return strcat("sprites/", icon);
};

// ---------------------------------------------------------------------------
//  Chain maintenance.
// ---------------------------------------------------------------------------

void(entity plyr) Inv_RecalcEffects;
void(entity plyr) Inv_SendHud;

// Drop freed entities out of a holder's chain.  See the header: a multi_manager
// "#2" slot removes an item outright and cannot be intercepted, so the chain
// has to tolerate holes.  Also re-derives inv_weight, because that is the other
// thing a silent removal would leave permanently wrong.
void(entity plyr) Inv_Prune =
{
    entity prev = world;
    entity it   = plyr.inv_head;
    float  dirty = FALSE;
    float  w = 0;

    while (it)
    {
        entity nxt = it.inv_next;
        // A freed edict can be recycled into something else entirely, so
        // "still points at me" is checked as well as "still allocated".
        float gone = wasfreed(it);
        if (!gone)
            if (it.inv_holder != plyr)
                gone = TRUE;

        if (gone)
        {
            if (prev == world) plyr.inv_head = nxt;
            else               prev.inv_next = nxt;
            dirty = TRUE;
        }
        else
        {
            w = w + Inv_Num(it.weight, 1);
            prev = it;
        }
        it = nxt;
    }

    if (plyr.inv_weight != w)
    {
        plyr.inv_weight = w;
        dirty = TRUE;
    }
    if (dirty)
    {
        plyr.inv_serial = plyr.inv_serial + 1;
        Inv_RecalcEffects(plyr);
    }
};

// Does this player hold an item with this exact name?
float(entity plyr, string nm) Inv_HoldsName =
{
    entity it = plyr.inv_head;
    while (it)
    {
        if (it.item_name == nm)
            return TRUE;
        it = it.inv_next;
    }
    return FALSE;
};

// How many held items belong to any of these groups?
float(entity plyr, string groups) Inv_CountInGroups =
{
    float n = 0;
    entity it = plyr.inv_head;
    while (it)
    {
        if (Inv_ListHas(groups, it.item_group))
            n = n + 1;
        it = it.inv_next;
    }
    return n;
};

// How many item_inventory entities exist on the map in these groups, held or
// not.  This is what "0 = all" in the FGD's _num keys is measured against.
float(string groups) Inv_MapCountInGroups =
{
    float n = 0;
    entity e = find(world, classname, "item_inventory");
    while (e)
    {
        if (Inv_ListHas(groups, e.item_group))
            n = n + 1;
        e = find(e, classname, "item_inventory");
    }
    return n;
};

// The two _num keys read "0 = all" in the FGD but they do NOT mean the same
// thing, and reading them symmetrically is the easy mistake here:
//
//   item_group_required_num  0  ->  "all items that EXIST in that group"
//        (the engine exposes a dedicated ExistsInGroup() global counter next to
//         HaveNumFromGroup(), which is what makes this a map-wide total rather
//         than "any")
//   item_group_canthave_num  0  ->  "no single item from that group may be
//        held" — the InventoryRules docs say exactly that, so the failing
//        threshold is ONE, not "all of them".
//
// Reading the canthave side as a map-wide total would have inverted the rule:
// a player holding one of three quest items would have PASSED a gate meant to
// exclude them.
float(float num) Inv_CantHaveCap =
{
    if (num <= 0) return 1;
    return num;
};

// Have the named items left their spawn origin?  `want` selects which answer
// counts as a pass, so one walk serves both item_name_moved and
// item_name_not_moved.  Every named item must agree — this is a conjunction
// like the rest of the rule block.
float(string names, float want) Inv_NamedItemsMoved =
{
    entity e = find(world, classname, "item_inventory");
    while (e)
    {
        if (Inv_ListHas(names, e.item_name))
            if ((e.inv_moved != 0) != (want != 0))
                return FALSE;
        e = find(e, classname, "item_inventory");
    }
    return TRUE;
};

// ---------------------------------------------------------------------------
//  Effects.
//
//  Folds the chain (plus anything latched by effects_permanent) into the four
//  replicated player scalars, and applies the three that are purely
//  server-side.  Called on every inventory change and from Inv_Prune.
// ---------------------------------------------------------------------------

// Do this item's effects count right now?  effects_wait_until_activated holds
// them back until the item has been self-activated at least once.
float(entity it) Inv_EffectsLive =
{
    if (!it.effects_wait_until_activated) return TRUE;
    return (it.inv_activated != 0);
};

void(entity plyr) Inv_RecalcEffects =
{
    float spd  = 1, grav = 1, fric = 1, dmg = 1;
    float block = FALSE, invuln = FALSE, invis = FALSE, nonsolid = FALSE;
    float resp = 0;
    vector glow = '0 0 0';

    // The permanent latch is the base the live chain multiplies on top of.
    if (plyr.inv_perm_speed    > 0) spd  = plyr.inv_perm_speed;
    if (plyr.inv_perm_gravity  > 0) grav = plyr.inv_perm_gravity;
    if (plyr.inv_perm_friction > 0) fric = plyr.inv_perm_friction;
    if (plyr.inv_perm_damage   > 0) dmg  = plyr.inv_perm_damage;
    if (plyr.inv_perm_block)        block = TRUE;

    entity it = plyr.inv_head;
    while (it)
    {
        if (Inv_EffectsLive(it))
        {
            spd  = spd  * Inv_Pct(it.effect_speed);
            grav = grav * Inv_Pct(it.effect_gravity);
            fric = fric * Inv_Pct(it.effect_friction);
            dmg  = dmg  * Inv_Pct(it.effect_damage);
            if (it.effect_block_weapons) block    = TRUE;
            if (it.effect_invulnerable)  invuln   = TRUE;
            if (it.effect_invisible)     invis    = TRUE;
            if (it.effect_nonsolid)      nonsolid = TRUE;
            // effect_respiration is the ONE effect_* key that is NOT a
            // percentage: Sven's own doc string calls it "Extra/less breathing
            // time underwater in seconds", its FGD default is 0.0 rather than
            // 100.0, and the wiki notes it "can be negative!".  So it SUMS
            // across held items rather than multiplying, and 0 is the no-op.
            resp = resp + Inv_Num(it.effect_respiration, 0);
            if (it.effect_glow != '0 0 0') glow = it.effect_glow;
        }
        it = it.inv_next;
    }

    // The four that must be identical on both sides of prediction.  Stored as
    // PERCENTAGES because that is what the proxy sends (one byte each) — see
    // the prediction note in the header.  Clamped to the byte the wire carries;
    // a map asking for >255% speed gets 255% and a dprint rather than a value
    // that wraps to something arbitrary.
    float spd_pct  = floor(spd  * 100 + 0.5);
    float grav_pct = floor(grav * 100 + 0.5);
    float fric_pct = floor(fric * 100 + 0.5);
    if (spd_pct > 255 || grav_pct > 255 || fric_pct > 255)
        dprint(sprintf("item_inventory: %s effect percentages clamped to 255 (speed %g gravity %g friction %g)\n",
                       plyr.netname, spd_pct, grav_pct, fric_pct));
    plyr.pm_inv_speed_pct    = bound(0, spd_pct,  255);
    plyr.pm_inv_gravity_pct  = bound(0, grav_pct, 255);
    plyr.pm_inv_friction_pct = bound(0, fric_pct, 255);
    plyr.pm_inv_blockfire    = block;

    // The rest are server-only: nothing about them is predicted.
    plyr.inv_damage_scale = dmg;
    plyr.inv_invulnerable = invuln;
    plyr.inv_air_bonus    = resp;

    if (nonsolid)
    {
        if (plyr.solid == SOLID_SLIDEBOX) plyr.inv_solid_saved = plyr.solid;
        plyr.solid = SOLID_TRIGGER;
    }
    else if (plyr.inv_solid_saved)
    {
        plyr.solid = plyr.inv_solid_saved;
        plyr.inv_solid_saved = 0;
    }

    // Glow shell.  This tree renders a coloured shell through .colormod plus
    // the glow effect bits, exactly as BrushSync_ApplyRenderKeys does for
    // rendermode 3 (sv_brushsync.qc:161).
    if (glow != '0 0 0')
    {
        plyr.effects  = plyr.effects | EF_FULLBRIGHT;
        plyr.colormod = glow / 255;
    }
    else if (plyr.inv_glow_on)
    {
        plyr.effects  = plyr.effects - (plyr.effects & EF_FULLBRIGHT);
        plyr.colormod = '1 1 1';
    }
    plyr.inv_glow_on = (glow != '0 0 0');

    // Invisibility.  NOT EF_NODRAW: csqcsysdefs.qc:712 says in as many words
    // that it "does NOT work on QW players", and a player is exactly what this
    // is being applied to.  .alpha 0 does work, so the pre-effect value is
    // saved and restored rather than assumed to be 1.
    if (invis)
    {
        if (!plyr.inv_invis_on)
        {
            plyr.inv_alpha_saved = plyr.alpha;
            plyr.alpha = -1;          // FTE: fully transparent (0 means "unset")
        }
    }
    else if (plyr.inv_invis_on)
    {
        plyr.alpha = plyr.inv_alpha_saved;
    }
    plyr.inv_invis_on = invis;
};

// End the effects_permanent latch and re-derive what is left.
//
// Deliberately does NOT wipe inv_head.  Inv_DropAll runs first at both call
// sites and has already decided, per item, what leaves — and an item with
// holder_keep_on_respawn set is MEANT to still be there afterwards.  Zeroing
// the chain here would orphan it: the item's inv_holder would still point at
// the player while the player no longer knew about it, so its weight would
// never come back and Inv_Prune could not see it to clean up.
void(entity plyr) Inv_PlayerReset =
{
    plyr.inv_perm_speed    = 0;
    plyr.inv_perm_gravity  = 0;
    plyr.inv_perm_friction = 0;
    plyr.inv_perm_damage   = 0;
    plyr.inv_perm_block    = 0;
    plyr.inv_serial        = plyr.inv_serial + 1;
    Inv_Prune(plyr);
    Inv_RecalcEffects(plyr);
};

// ---------------------------------------------------------------------------
//  Presentation of the item itself.
// ---------------------------------------------------------------------------

// Put the item back into its world pose at `org`.
void(entity it, vector org) Inv_Materialise =
{
    it.inv_holder = world;
    it.inv_next   = world;
    setorigin(it, org);
    it.angles     = it.inv_home_angles;
    it.movetype   = MOVETYPE_TOSS;      // settle onto whatever is under it
    it.solid      = SOLID_TRIGGER;      // FGD "solid" 0: touch on edge, non-blocking
    it.effects    = it.effects - (it.effects & EF_NODRAW);
    it.frame      = it.inv_idle_frame;
    setsize(it, it.mins, it.maxs);
};

// Where a visibly-carried item rides on its holder.
//
// Was `plyr.origin + '0 0 8' + [0,0,plyr.maxs_z]` open-coded at BOTH call sites
// (Inv_Conceal for the instant placement on pickup, item_inventory_think for the
// 10 Hz follow), which is how they came to disagree in the first place.  One
// helper now, so they cannot drift again.
//
// The '0 0 8' is gone.  maxs_z already puts the item's origin level with the TOP
// of the holder's head, so the 8 was eight units of pure air ON TOP of that,
// before the model's own geometry even starts — and these models carry their
// origin at their own centre (item_carbattery/item_gascan/item_toolbox all have
// symmetric z extents about 0), so the visible box then started higher again.
// Reported as "the display model above head is to high. I think it already has
// an offset."  It did; this was it.
//
// Kept as a cvar rather than a constant because the right number is a look
// judgement that cannot be measured from the model files: the studiohdr min/max
// on all three of these models are zeroed, which is normal for HL models and
// leaves nothing authoritative to derive a clearance from.  0 = sit on the head.
float(entity plyr) Inv_CarryLift =
{
    return cvar("sv_inv_carry_lift");
};

vector(entity plyr) Inv_CarryOrigin =
{
    return plyr.origin + [0, 0, plyr.maxs_z + Inv_CarryLift(plyr)];
};

// ABSENT carried_hidden MEANS VISIBLE, and getting that backwards is why nothing
// ever appeared over a carrier's head.
//
// The FGD lists `carried_hidden(choices) ... : 1` (sven-coop.fgd:3469) and this
// used to read it through Inv_BoolDefTrue, i.e. "absent -> 1 -> hide".  That is
// the FGD-default trap this tree documents elsewhere, read the wrong way round:
// the number after the colon is what HAMMER OFFERS, and Hammer does not write a
// key the mapper never touched.  Sven's own C++ member is therefore left at its
// zero-initialised value for every such entity, which is NO — show it.
//
// th_escape settles it from the map side.  Its four item_inventory entities
// carry no carried_hidden key at all, yet every one of them ships an authored
// carried pose (`carried_sequencename "carried"` / `carried_sequence 2`) beside
// an idle pose (`sequencename "not_carried"`), and the car battery's own
// description is "A very heavy battery, carried with both hands."  A mapper does
// not model, name and select a carried pose for a model the game is never going
// to draw.
//
// Explicit `carried_hidden 1` still hides, which is the only thing the key was
// ever able to express.
void(entity it) Inv_Conceal =
{
    it.movetype = MOVETYPE_NONE;
    it.solid    = SOLID_NOT;
    it.frame    = it.inv_carried_frame;
    if (it.carried_skin) it.skin = it.carried_skin;
    if (it.carried_body) it.body = it.carried_body;
    if (Inv_HasStr(it.carried_hidden) && stof(it.carried_hidden) != 0)
        it.effects = it.effects | EF_NODRAW;
    else
    {
        it.effects = it.effects - (it.effects & EF_NODRAW);
        // Move it onto the holder NOW rather than waiting for the next 10 Hz
        // tick, or a visible carry leaves the model standing at the pickup spot
        // for up to a tenth of a second after it has been collected.  Same
        // placement as item_inventory_think, which owns it from here on.
        if (it.inv_holder && it.inv_holder != world)
        {
            setorigin(it, Inv_CarryOrigin(it.inv_holder));
            it.angles_y = it.inv_holder.angles_y;
        }
    }
};

// ---------------------------------------------------------------------------
//  Collect / drop / return / destroy.
// ---------------------------------------------------------------------------

void(entity it, entity who, float ignore_triggers)     Inv_Return;
void(entity it)                                        Inv_Detach;
float(entity it, entity who, float forced, float quiet) Inv_Drop;
// Defined down with the rules block, because it is the one place in this file
// that tokenizes and the note there explains why that has to stay isolated.
float(entity who, string names)                        Inv_HoldsAllNames;

// Fire one of the item's event targets with the holder as activator.
// Silently no-ops on an unset key, which is what almost every key is.
void(entity it, string tgt, entity who) Inv_Fire =
{
    if (!Inv_HasStr(tgt)) return;
    SV_FireTargetsByName(tgt, who, USE_TOGGLE);
};

// Can `who` collect `it` right now?  Sven evaluates the item's OWN
// "Collect: ..." rules here — which are the same six key names the
// InventoryRules block uses on other entities, hence the shared fields.
float(entity it, entity who) Inv_CanCollect =
{
    if (it.inv_state != INV_IDLE && it.inv_state != INV_DROPPED) return FALSE;
    if (who.classname != "player") return FALSE;
    if (who.health <= 0)           return FALSE;

    // Weight cap.
    if (who.inv_weight + Inv_Num(it.weight, 1) > INV_MAX_WEIGHT) return FALSE;

    // Never two copies of the same item.
    if (Inv_HoldsName(who, it.item_name)) return FALSE;

    // Player-targetname filter.
    if (Inv_HasStr(it.filter_targetnames))
        if (!Inv_ListHas(it.filter_targetnames, who.targetname))
            return FALSE;

    // Must have.  Inv_HoldsAllNames, not Inv_HoldsName: the key takes a
    // semicolon list and every name in it has to be held ("Require these
    // item(s)"), so a single-name lookup would silently accept a player holding
    // only the first of three.  th_escape never writes more than one here;
    // mustard and turretfortress do.
    if (Inv_HasStr(it.item_name_required))
        if (!Inv_HoldsAllNames(who, it.item_name_required))
            return FALSE;

    // Must NOT have.  This is the key th_escape leans on: every item lists the
    // other two, so you can only ever be carrying one of the three at a time.
    if (Inv_HasStr(it.item_name_canthave))
    {
        entity h = who.inv_head;
        while (h)
        {
            if (Inv_ListHas(it.item_name_canthave, h.item_name))
                return FALSE;
            h = h.inv_next;
        }
    }

    // Group counts.  "0 = all" is measured against how many items of that group
    // exist on the map, per the FGD's own wording.
    if (Inv_HasStr(it.item_group_required))
    {
        float need = it.item_group_required_num;
        if (need <= 0) need = Inv_MapCountInGroups(it.item_group_required);
        if (Inv_CountInGroups(who, it.item_group_required) < need)
            return FALSE;
    }
    if (Inv_HasStr(it.item_group_canthave))
    {
        if (Inv_CountInGroups(who, it.item_group_canthave)
            >= Inv_CantHaveCap(it.item_group_canthave_num))
            return FALSE;
    }

    // item_name_moved / item_name_not_moved.  "Moved" is Sven's word for
    // "no longer sitting on its spawn origin" — i.e. somebody has picked it up
    // or dropped it somewhere else.  The wiki's two labels for these are
    // swapped relative to the engine's own doc strings; the doc strings win.
    if (Inv_HasStr(it.item_name_moved))
        if (!Inv_NamedItemsMoved(it.item_name_moved, TRUE))
            return FALSE;
    if (Inv_HasStr(it.item_name_not_moved))
        if (!Inv_NamedItemsMoved(it.item_name_not_moved, FALSE))
            return FALSE;

    return TRUE;
};

// Hand `it` to `who`.  Returns TRUE if it actually changed hands.
float(entity it, entity who) Inv_Collect =
{
    if (!Inv_CanCollect(it, who))
    {
        Inv_Fire(it, it.target_cant_collect, who);
        return FALSE;
    }

    it.inv_holder = who;
    it.inv_next   = who.inv_head;
    who.inv_head  = it;
    who.inv_weight = who.inv_weight + Inv_Num(it.weight, 1);
    it.inv_state  = INV_HELD;
    it.inv_return_at = 0;
    it.inv_collects  = it.inv_collects + 1;

    // holder_timelimit — "forcibly dropped after" this many seconds, 0 = none.
    //
    // holder_timelimit_wait_until_activated defers the clock until the holder
    // self-activates the item, and the engine's own doc string adds the part
    // that matters: it is "ignored if m_fCanBeActivated is false".  So an item
    // that cannot be activated at all starts its clock immediately regardless
    // of what that key says.
    //
    // That combination is exactly what th_escape writes: all twelve items set
    // holder_timelimit_wait_until_activated 1 while leaving holder_can_activate
    // at 0 AND holder_timelimit at 0 — Hammer emitting an FGD default.  The
    // key is a complete no-op there, and reading it without the
    // holder_can_activate half would have made it look load-bearing.
    float lim  = Inv_Num(it.holder_timelimit, 0);
    float wait = Inv_BoolDefTrue(it.holder_timelimit_wait_until_activated)
                 && it.holder_can_activate;
    if (lim > 0 && !wait)
        it.inv_hold_until = time + lim;
    else
        it.inv_hold_until = 0;
    it.inv_wearout_done = FALSE;

    Inv_Conceal(it);

    who.inv_serial = who.inv_serial + 1;
    Inv_RecalcEffects(who);

    Inv_Fire(it, it.target_on_collect, who);

    // "Collection limit (item is destroyed once surpassed)".  Destroyed, not
    // returned — so this is a detach rather than an Inv_Return, which would
    // have put it back on its pedestal a frame before removing it.
    if (it.collect_limit > 0)
    {
        if (it.inv_collects > it.collect_limit)
        {
            Inv_Fire(it, it.target_on_destroy, who);
            Inv_Detach(it);
            remove(it);
            return TRUE;
        }
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[inventory] %s collected \"%s\" (group \"%s\", weight %g/%g)\n",
                      who.netname, it.item_name, it.item_group,
                      who.inv_weight, INV_MAX_WEIGHT));
    return TRUE;
};

// Unhook an item from whatever chain it is in.  Does NOT decide where it goes.
void(entity it) Inv_Detach =
{
    entity plyr = it.inv_holder;
    if (!plyr || plyr == world) return;

    entity prev = world;
    entity h    = plyr.inv_head;
    while (h)
    {
        if (h == it)
        {
            if (prev == world) plyr.inv_head = h.inv_next;
            else               prev.inv_next = h.inv_next;
            h = world;
        }
        else
        {
            prev = h;
            h = h.inv_next;
        }
    }

    plyr.inv_weight = max(0, plyr.inv_weight - Inv_Num(it.weight, 1));
    it.inv_holder   = world;
    it.inv_next     = world;

    // effects_permanent: the modifiers stay on the player after the item goes.
    // The FGD calls it "Permanent? (Until respawn)", so Inv_PlayerReset is what
    // clears it.
    if (it.effects_permanent)
    {
        float pspd  = (plyr.inv_perm_speed    > 0) ? plyr.inv_perm_speed    : 1;
        float pgrav = (plyr.inv_perm_gravity  > 0) ? plyr.inv_perm_gravity  : 1;
        float pfric = (plyr.inv_perm_friction > 0) ? plyr.inv_perm_friction : 1;
        float pdmg  = (plyr.inv_perm_damage   > 0) ? plyr.inv_perm_damage   : 1;
        plyr.inv_perm_speed    = pspd  * Inv_Pct(it.effect_speed);
        plyr.inv_perm_gravity  = pgrav * Inv_Pct(it.effect_gravity);
        plyr.inv_perm_friction = pfric * Inv_Pct(it.effect_friction);
        plyr.inv_perm_damage   = pdmg  * Inv_Pct(it.effect_damage);
        if (it.effect_block_weapons) plyr.inv_perm_block = TRUE;
    }

    plyr.inv_serial = plyr.inv_serial + 1;
    Inv_RecalcEffects(plyr);
};

// Put the item on the ground in front of the holder and start its return clock.
//
// `forced`  a drop the holder did not choose (death, a trigger's USE_OFF, a
//           pass_drop_ rule).  Bypasses holder_can_drop.
// `quiet`   suppress target_on_drop.  Only pass_ignore_drop_triggers sets it;
//           it is a parameter rather than a field on the item because the
//           SUPPRESSION belongs to the rules entity that asked for the drop,
//           not to the item being dropped.
float(entity it, entity who, float forced, float quiet) Inv_Drop =
{
    if (it.inv_state != INV_HELD) return FALSE;

    // holder_can_drop gates a VOLUNTARY drop only.  A forced drop (death, a
    // trigger's USE_OFF, a pass_drop_ rule) happens regardless — otherwise an
    // undroppable item would be impossible to take off a corpse.
    if (!forced && !Inv_BoolDefTrue(it.holder_can_drop))
    {
        Inv_Fire(it, it.target_cant_drop, who);
        return FALSE;
    }

    entity plyr = it.inv_holder;
    Inv_Detach(it);

    vector org = plyr.origin;
    makevectors(plyr.v_angle);
    org = org + v_forward * 32;
    org_z = plyr.absmin_z + 8;

    // Do not drop it inside geometry: fall back to the holder's own feet, which
    // are by definition in a legal spot.
    traceline(plyr.origin, org, MOVE_NORMAL, plyr);
    if (trace_fraction < 1)
        org = plyr.origin;

    Inv_Materialise(it, org);
    it.inv_state = INV_DROPPED;
    it.inv_moved = TRUE;

    float ret = Inv_Num(it.return_timelimit, 60);
    if (ret >= 0) it.inv_return_at = time + ret;
    else          it.inv_return_at = 0;      // -1 = never go home

    if (!quiet)
        Inv_Fire(it, it.target_on_drop, plyr);

    if (cvar("sv_debug_use"))
        print(sprintf("[inventory] %s dropped \"%s\"%s, returns in %gs\n",
                      plyr.netname, it.item_name, forced ? " (forced)" : "", ret));
    return TRUE;
};

// Send it home to where it spawned.
void(entity it, entity who, float ignore_triggers) Inv_Return =
{
    if (it.inv_state == INV_HELD)
        Inv_Detach(it);

    Inv_Materialise(it, it.inv_home);
    it.inv_return_at = 0;
    it.inv_moved     = FALSE;

    if (!ignore_triggers)
        Inv_Fire(it, it.target_on_return, who);

    if (it.return_delay_respawn)
    {
        // "Delay respawn (materialisation)" — weapon/ammo style: go away, then
        // reappear.  The reappearance is what fires target_on_materialise.
        it.inv_state = INV_AWAY;
        it.effects   = it.effects | EF_NODRAW;
        it.solid     = SOLID_NOT;
        it.inv_return_at = time + 5;
    }
    else
    {
        it.inv_state = INV_IDLE;
        if (!ignore_triggers)
            Inv_Fire(it, it.target_on_materialise, who);
    }
};

// ---------------------------------------------------------------------------
//  The InventoryRules gate.
//
//  Called by every class the changelog lists as honouring it.  Returns TRUE
//  when the entity may act for this activator.  The changelog's wording is
//  "All defined rules must pass in order for a pass to be given", so this is a
//  conjunction and an entity with no rules set always passes.
// ---------------------------------------------------------------------------

// Does `who` hold every name in this semicolon list?
//
// tokenizebyseparator is used HERE and nowhere else in this file, and the inner
// walk is Inv_HoldsName, which does not tokenize — so argv() stays valid across
// the whole loop.  See the note on Inv_ListHas.
float(entity who, string names) Inv_HoldsAllNames =
{
    float n = tokenizebyseparator(names, ";");
    float i = 0;
    while (i < n)
    {
        string want = argv(i);
        if (want != "")
            if (!Inv_HoldsName(who, want))
                return FALSE;
        i = i + 1;
    }
    return TRUE;
};

// Has the mapper configured ANY inventory rule on this entity?
//
// Exists because trigger_hurt inverts the sense of the gate — there, passing
// protects you — so it cannot use "no rules means pass" the way every other
// class safely can.  Without this distinction every unconfigured trigger_hurt
// in the corpus would stop hurting anyone.
float(entity rules) Inv_HasRules =
{
    if (Inv_HasStr(rules.item_name_required))  return TRUE;
    if (Inv_HasStr(rules.item_group_required)) return TRUE;
    if (Inv_HasStr(rules.item_name_canthave))  return TRUE;
    if (Inv_HasStr(rules.item_group_canthave)) return TRUE;
    return FALSE;
};

float(entity rules, entity who) Inv_RulesPass =
{
    // No activator means no inventory to test, so nothing can fail.  Map logic
    // that fires a gated entity through a trigger chain rather than a player
    // touch lands here, and Sven lets those through too.
    if (!who || who == world)         return TRUE;
    if (who.classname != "player")    return TRUE;

    // Cheap out: the overwhelming majority of entities in any map set none of
    // these, and this runs on every touch of every trigger in the world.
    if (!Inv_HasStr(rules.item_name_required)
     && !Inv_HasStr(rules.item_group_required)
     && !Inv_HasStr(rules.item_name_canthave)
     && !Inv_HasStr(rules.item_group_canthave))
        return TRUE;

    Inv_Prune(who);

    if (Inv_HasStr(rules.item_name_required))
        if (!Inv_HoldsAllNames(who, rules.item_name_required))
            return FALSE;

    if (Inv_HasStr(rules.item_name_canthave))
    {
        entity h = who.inv_head;
        while (h)
        {
            if (Inv_ListHas(rules.item_name_canthave, h.item_name))
                return FALSE;
            h = h.inv_next;
        }
    }

    if (Inv_HasStr(rules.item_group_required))
    {
        float need = rules.item_group_required_num;
        if (need <= 0) need = Inv_MapCountInGroups(rules.item_group_required);
        if (Inv_CountInGroups(who, rules.item_group_required) < need)
            return FALSE;
    }

    if (Inv_HasStr(rules.item_group_canthave))
    {
        if (Inv_CountInGroups(who, rules.item_group_canthave)
            >= Inv_CantHaveCap(rules.item_group_canthave_num))
            return FALSE;
    }

    return TRUE;
};

// The pass_* half: destroy / drop / return the named items once the rules have
// passed.  th_escape's three drop-off pads use pass_destroy_item_name, which is
// how the battery leaves your hands when you deliver it to the truck.
void(entity rules, entity who) Inv_RulesOnPass =
{
    if (!who || who == world)      return;
    if (who.classname != "player") return;

    if (!Inv_HasStr(rules.pass_destroy_item_name)
     && !Inv_HasStr(rules.pass_destroy_item_group)
     && !Inv_HasStr(rules.pass_drop_item_name)
     && !Inv_HasStr(rules.pass_drop_item_group)
     && !Inv_HasStr(rules.pass_return_item_name)
     && !Inv_HasStr(rules.pass_return_item_group))
        return;

    // Latch the chain before touching it — every branch below detaches, and a
    // walk that reads .inv_next after the detach has already rewritten it goes
    // somewhere arbitrary.
    entity it = who.inv_head;
    while (it)
    {
        entity nxt = it.inv_next;

        float destroy = Inv_ListHas(rules.pass_destroy_item_name,  it.item_name)
                     || Inv_ListHas(rules.pass_destroy_item_group, it.item_group);
        float drop    = Inv_ListHas(rules.pass_drop_item_name,     it.item_name)
                     || Inv_ListHas(rules.pass_drop_item_group,    it.item_group);
        float retn    = Inv_ListHas(rules.pass_return_item_name,   it.item_name)
                     || Inv_ListHas(rules.pass_return_item_group,  it.item_group);

        if (destroy)
        {
            if (!rules.pass_ignore_destroy_triggers)
                Inv_Fire(it, it.target_on_destroy, who);
            Inv_Detach(it);
            remove(it);
        }
        else if (drop)
        {
            Inv_Drop(it, who, TRUE, rules.pass_ignore_drop_triggers);
        }
        else if (retn)
        {
            Inv_Return(it, who, rules.pass_ignore_return_triggers);
        }

        // Every branch above can fire a map chain, and a map chain can remove
        // entities — including the one already latched as `nxt`.  A freed edict
        // is not null, so without this the walk would read .inv_next out of
        // recycled memory.  Same hazard SV_FireTargetsByName documents for its
        // own latched cursor (sv_triggers.qc:196).
        if (nxt) if (wasfreed(nxt)) nxt = world;
        it = nxt;
    }
};

// The failure half.  Sven fires target_on_fail with the activator that failed.
//
// RATE-LIMITED, and that is not tidiness.  A gated trigger is not touched once
// per attempt: trigger_multi_scan re-runs Trigger_FireOnOverlap every 0.1 s
// precisely so a player standing still inside a volume keeps registering
// (sv_trigger_once_multi.qc:78-81).  A player who walks into a gated
// trigger_once WITHOUT the required item and simply stands there — which is
// exactly what happens the first time anyone finds th_escape's drop-off pads —
// would otherwise fire target_on_fail ten times a second for as long as they
// stand on it.  On a map like polar_rescue, which actually uses target_on_fail,
// that is a game_text or a sound retriggering 10 Hz.
//
// One second is chosen to be comfortably longer than the scan period and short
// enough that a deliberate second attempt still reports.
const float INV_FAIL_REFIRE = 1.0;
.float inv_fail_next;        // on the RULES entity: next time it may report a failure

void(entity rules, entity who) Inv_RulesOnFail =
{
    if (time < rules.inv_fail_next) return;
    rules.inv_fail_next = time + INV_FAIL_REFIRE;

    if (cvar("sv_debug_use"))
        print(sprintf("[inventory] %s BLOCKED %s \"%s\" (inventory rules)\n",
                      who.netname, rules.classname, rules.targetname));

    if (!Inv_HasStr(rules.target_on_fail)) return;
    SV_FireTargetsByName(rules.target_on_fail, who, USE_TOGGLE);
};

// One call for the common shape: "may I act for this activator, and if so do
// the pass_* bookkeeping".  Every wiring site below is a two-line change
// because of this.
float(entity rules, entity who) Inv_Gate =
{
    if (!Inv_RulesPass(rules, who))
    {
        Inv_RulesOnFail(rules, who);
        return FALSE;
    }
    Inv_RulesOnPass(rules, who);
    return TRUE;
};

// ---------------------------------------------------------------------------
//  Per-item tick.
// ---------------------------------------------------------------------------
void() item_inventory_think =
{
    self.nextthink = time + INV_TICK;

    if (self.inv_state == INV_HELD)
    {
        entity plyr = self.inv_holder;
        if (!plyr || plyr == world || wasfreed(plyr) || plyr.health <= 0)
        {
            // The holder is gone or dead and the death path did not run (a
            // disconnect mid-frame, say).  Send it home rather than leaving it
            // attached to nothing.
            Inv_Return(self, world, FALSE);
            return;
        }

        // A visible carry.  Sven does NOT attach this to a hand bone or turn it
        // into a viewmodel — the wiki's description of carried_hidden 0 is that
        // "the item model is floating above player head when equipped", so that
        // is what this reproduces.  See Inv_Conceal for why an ABSENT
        // carried_hidden takes this branch rather than the hidden one.
        if (!(Inv_HasStr(self.carried_hidden) && stof(self.carried_hidden) != 0))
        {
            setorigin(self, Inv_CarryOrigin(plyr));
            self.angles_y = plyr.angles_y;
        }

        if (self.inv_hold_until > 0)
        {
            // holder_time_wearout is a warning shot fired this many seconds
            // BEFORE the hold limit expires, not at it — the wiki's worked
            // example is timelimit 10 + wearout 3 firing at t=7.  Latched so a
            // 10 Hz tick cannot fire it repeatedly across the window.
            float wear = Inv_Num(self.holder_time_wearout, 0);
            if (wear > 0 && !self.inv_wearout_done)
            {
                if (time >= self.inv_hold_until - wear)
                {
                    self.inv_wearout_done = TRUE;
                    Inv_Fire(self, self.target_on_wearing_out, plyr);
                }
            }
            if (time >= self.inv_hold_until)
                Inv_Drop(self, plyr, TRUE, FALSE);
        }
        return;
    }

    if (self.inv_state == INV_DROPPED && self.inv_return_at > 0 && time >= self.inv_return_at)
    {
        Inv_Return(self, world, FALSE);
        return;
    }

    if (self.inv_state == INV_AWAY && self.inv_return_at > 0 && time >= self.inv_return_at)
    {
        self.inv_state   = INV_IDLE;
        self.inv_return_at = 0;
        self.effects     = self.effects - (self.effects & EF_NODRAW);
        self.solid       = SOLID_TRIGGER;
        Inv_Fire(self, self.target_on_materialise, world);
    }
};

// ---------------------------------------------------------------------------
//  Touch / use / remote control.
// ---------------------------------------------------------------------------
void() item_inventory_touch =
{
    // "If both touch only or use only are set the entity can only be collected
    // via a trigger.  If neither is set it can be collected via touch, use, or
    // trigger." — changelog.html.
    if (self.spawnflags & PICKUP_SF_USE_ONLY)
        return;
    if (other.classname != "player")
        return;
    Inv_Collect(self, other);
};

// Player pressed +use on it.  Returns TRUE if the press was consumed, which is
// what sv_use.qc needs in order to stop looking for something else to activate.
float(entity it, entity plyr) Inv_TryPickup =
{
    if (it.classname != "item_inventory") return FALSE;
    if (it.spawnflags & PICKUP_SF_TOUCH_ONLY) return FALSE;
    return Inv_Collect(it, plyr);
};

// A trigger aimed at the item.  Sven's remote-control semantics, verbatim from
// changelog.html: On = collect for !activator, Off = force drop, Toggle = do
// whichever the current state calls for.
void() item_inventory_use =
{
    // A player pressing +use reaches the item through Inv_TryPickup, which is
    // where the TOUCH_ONLY / USE_ONLY spawnflags are enforced.  If it declined
    // the press, sv_use.qc falls through to the generic SV_UseTarget dispatch
    // and lands HERE — and honouring it would collect an item the mapper
    // explicitly marked touch-only, quietly defeating the flag.
    //
    // sv_use_is_player_direct is TRUE only for the duration of SV_PlayerTryUse
    // (sv_customdefs.qc:281) and is cleared before any chained trigger runs, so
    // it separates "a person is pressing this" from "a trigger is firing it"
    // without needing a second entry point.
    if (sv_use_is_player_direct)
        return;

    float ut = sub_use_type;

    if (ut == USE_ON)
    {
        if (activator && activator != world)
            Inv_Collect(self, activator);
        return;
    }
    if (ut == USE_OFF)
    {
        if (self.inv_state == INV_HELD)
            Inv_Drop(self, self.inv_holder, TRUE, FALSE);
        return;
    }

    // USE_TOGGLE / USE_SET / USE_UNSET.
    if (self.inv_state == INV_HELD)
        Inv_Drop(self, self.inv_holder, TRUE, FALSE);
    else if (activator && activator != world)
        Inv_Collect(self, activator);

    Inv_Fire(self, self.target_on_use, activator);
};

// ---------------------------------------------------------------------------
//  Player-side entry points, called from sv_player.qc (which compiles later).
// ---------------------------------------------------------------------------

// Force-drop what the player is holding.  Which items stay depends on WHY they
// are leaving, and Sven splits that three ways — so this takes a mode rather
// than a bool.  The keep flags are per-item, and both default to 0 (drop).
//
// Note the two keeps do not compose the way they read: holder_keep_on_respawn
// cannot save an item that holder_keep_on_death already dropped, because the
// death happens first.  A map that wants an item to survive a full death →
// respawn cycle has to set both.
// INV_LEAVE_DEATH / _RESPAWN / _GONE are declared in sv_customdefs.qc, not
// here: PlayerKilled lives in sv_weapons.qc (position 45) and calls this, and
// QC can forward-declare the FUNCTION from there but not the constants it
// needs to pass.  Same constraint the InventoryRules field block documents.
// The parameter is `leave` and NOT `mode`: `mode` is now a declared FIELD
// (trigger_playercheck's comparator, sv_trigger_playercheck.qc), and a QC field
// declaration is a global of that name — a parameter sharing it is a duplicate
// definition, not a shadow.
void(entity plyr, float leave) Inv_DropAll =
{
    Inv_Prune(plyr);
    entity it = plyr.inv_head;
    while (it)
    {
        entity nxt = it.inv_next;

        float keep = FALSE;
        if      (leave == INV_LEAVE_DEATH)   keep = it.holder_keep_on_death;
        else if (leave == INV_LEAVE_RESPAWN) keep = it.holder_keep_on_respawn;

        if (!keep)
            Inv_Drop(it, plyr, TRUE, FALSE);
        it = nxt;
    }
};

// ---------------------------------------------------------------------------
//  HUD.
//
//  Sven's own first release of this shipped with no HUD at all — the changelog
//  says the `inventory` console command "will print the player's inventory in
//  their console (a fancy UI will be added in a future release)".  This mod has
//  a CSQC HUD, so the item gets a real strip, but the console command is kept
//  as well because it is the only thing that can show the description text and
//  the weight, and because it is what a server admin can read over rcon.
//
//  Unicast to the holder on CHANGE, not per-frame — same shape and the same
//  two guards as TrackTrain_SendHud (sv_func_traincontrols.qc:64), including
//  the bot/netchan guard, without which every carrying bot spams
//  "msg_entity: not a client" once a frame.
// ---------------------------------------------------------------------------
void(entity plyr) Inv_SendHud =
{
    plyr.inv_sent_serial = plyr.inv_serial;

    if (plyr.is_bot) return;
    if (!SV_PlayerHasNetchan(plyr)) return;

    // Count first: the byte has to precede the run, and the chain has to be
    // walked twice rather than guessed at.
    float n = 0, extra = 0;
    entity it = plyr.inv_head;
    while (it)
    {
        if (n < INV_HUD_MAX) n = n + 1;
        else                 extra = extra + 1;
        it = it.inv_next;
    }

    msg_entity = plyr;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_INVENTORY);
    WriteByte(MSG_ONE, n);
    WriteByte(MSG_ONE, bound(0, extra, 255));

    float i = 0;
    it = plyr.inv_head;
    while (it)
    {
        if (i >= INV_HUD_MAX)
            it = world;
        else
        {
            WriteString(MSG_ONE, Inv_IconPath(it.item_icon));
            WriteString(MSG_ONE, Inv_HasStr(it.display_name) ? it.display_name : it.item_name);
            i = i + 1;
            it = it.inv_next;
        }
    }
};

// `inventory` console command.  Verbatim in spirit from Sven's own, which is
// the only inventory readout that release shipped with.
void(entity plyr) Inv_PrintToConsole =
{
    Inv_Prune(plyr);

    if (plyr.inv_head == world)
    {
        sprint(plyr, PRINT_HIGH, "You are not carrying anything.\n");
        return;
    }

    sprint(plyr, PRINT_HIGH,
           sprintf("Inventory (%g / %g weight):\n", plyr.inv_weight, INV_MAX_WEIGHT));
    entity it = plyr.inv_head;
    while (it)
    {
        string nm = Inv_HasStr(it.display_name) ? it.display_name : it.item_name;
        // Sven's own console listing formats the weight as "%.2f kG" — its doc
        // string calls the unit "KG if you like" — so the readout matches.
        sprint(plyr, PRINT_HIGH,
               sprintf("  %s  [%s]  %.2f kG\n",
                       nm, it.item_name, Inv_Num(it.weight, 1)));
        if (Inv_HasStr(it.description))
            sprint(plyr, PRINT_HIGH, sprintf("      %s\n", it.description));
        it = it.inv_next;
    }
};

// `dropitem <what>`.  Sven's parameter forms: "*" = everything droppable,
// a bare name = that item, "#N" = by entity index for an item with no name.
// Returns how many were actually dropped so the caller can report.
float(entity plyr, string what) Inv_DropByName =
{
    Inv_Prune(plyr);

    // STRZONE THE ARGUMENT.  It arrives as argv(1) from SV_ParseClientCommand,
    // i.e. a tokenize temp — and the loop below fires target_on_drop, which
    // runs arbitrary map logic, and a multi_manager in that chain tokenizes.
    // Reading `what` after that would compare against whatever the map's parse
    // left in the buffer.
    string want = strzone(what);

    float dropped = 0;
    entity it = plyr.inv_head;
    while (it)
    {
        entity nxt = it.inv_next;
        float match = FALSE;

        if (want == "" || want == "*")          match = TRUE;
        else if (it.item_name == want)          match = TRUE;
        else if (substring(want, 0, 1) == "#")
            match = (num_for_edict(it) == stof(substring(want, 1, strlen(want) - 1)));

        if (match)
            if (Inv_Drop(it, plyr, FALSE, FALSE))
                dropped = dropped + 1;

        // The fire above can remove entities, `nxt` among them.
        if (nxt) if (wasfreed(nxt)) nxt = world;
        it = nxt;
    }

    strunzone(want);
    return dropped;
};

// Per-frame holder upkeep.  Cheap when the player carries nothing, which is the
// case for every player on every map that does not use the system.
void(entity plyr) Inv_PlayerFrame =
{
    if (plyr.inv_head == world)
    {
        if (plyr.inv_serial != plyr.inv_sent_serial)
            Inv_SendHud(plyr);
        return;
    }
    Inv_Prune(plyr);
    if (plyr.inv_serial != plyr.inv_sent_serial)
        Inv_SendHud(plyr);
};

// ---------------------------------------------------------------------------
//  Spawn.
// ---------------------------------------------------------------------------

/*QUAKED item_inventory (.3 .6 .3) (-8 -8 0) (8 8 16) x x x x x x x TOUCH_ONLY USE_ONLY USE_NO_LOS NO_RESPAWN
Sven Co-op carriable inventory item.  A player picks it up and holds it; other
entities can gate themselves on whether the activator is carrying it.

"item_name"        this item's identity
"item_group"       group name, for the _group_ rules
"display_name"     HUD label
"description"      HUD sub-label
"item_icon"        HUD sprite, relative to sprites/
"weight"           0..100; a player can carry 100 total
"return_timelimit" seconds on the ground before it goes home (-1 = never)
"holder_can_drop"  may the holder drop it voluntarily (default 1)
"carried_hidden"   hide the model while carried (default 1)
"effect_speed"     holder speed, percent (100 = unchanged)
"effect_block_weapons"  1 = both hands full, no shooting
"target_on_collect" "target_on_drop" "target_on_return" "target_on_materialise"
"target_on_destroy" "target_cant_collect" "target_cant_drop"
"item_name_canthave" "item_name_required" "item_group_required(_num)"
                   collection rules, semicolon-separated
*/
void() item_inventory =
{
    if (!Inv_HasStr(self.model))
        self.model = "models/egg.mdl";     // the FGD's own default

    precache_model(self.model);
    setmodel(self, self.model);

    // The icon has to exist in the CLIENT's model list for spriteframe() to
    // resolve it, and a server-side precache_model is what puts it there.
    string icon = Inv_IconPath(self.item_icon);
    if (icon != "")
        precache_model(icon);

    self.classname = "item_inventory";
    self.inv_home        = self.origin;
    self.inv_home_angles = self.angles;
    self.inv_state       = INV_IDLE;
    self.inv_holder      = world;

    // `angle` is HL entdata's single-axis yaw shortcut — same fold cycler and
    // item_generic do.
    if (self.angles == '0 0 0' && self.angle != 0)
    {
        self.angles_y        = self.angle;
        self.angle           = 0;
        self.inv_home_angles = self.angles;
    }

    self.solid    = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;

    if (self.minhullsize != '0 0 0' && self.maxhullsize != '0 0 0')
        setsize(self, self.minhullsize, self.maxhullsize);
    else
        setsize(self, '-8 -8 0', '8 8 16');

    // Sequences.  The numeric key wins over the name, exactly as item_generic
    // documents, and a name miss falls back to 0 rather than erroring — Sven
    // maps routinely ask for a name the model does not carry.
    // QC locals are FUNCTION-scoped, not block-scoped, so the two lookups
    // below share one name rather than each declaring `s` (warning Q207).
    float seq;

    self.inv_idle_frame = 0;
    if (self.sequence > 0)
        self.inv_idle_frame = self.sequence;
    else if (Inv_HasStr(self.sequencename))
    {
        seq = frameforname(self.modelindex, self.sequencename);
        if (seq >= 0) self.inv_idle_frame = seq;
    }

    self.inv_carried_frame = self.inv_idle_frame;
    if (Inv_HasStr(self.carried_sequence))
        self.inv_carried_frame = stof(self.carried_sequence);
    else if (Inv_HasStr(self.carried_sequencename))
    {
        seq = frameforname(self.modelindex, self.carried_sequencename);
        if (seq >= 0) self.inv_carried_frame = seq;
    }
    self.frame = self.inv_idle_frame;

    BrushSync_ApplyRenderKeys();

    self.touch = item_inventory_touch;
    self.use   = item_inventory_use;

    self.think     = item_inventory_think;
    self.nextthink = time + INV_TICK;
};
