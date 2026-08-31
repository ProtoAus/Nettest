//
//  sv_trigger_playercheck.qc — Sven Co-op th_escape's `trigger_playercheck`
//
//  "Checks how many players are in the volume, and toggles the target entity
//   based on the set mode and threshold."  — the header of the original.
//
//  SOURCE.  This one is NOT a stock Sven entity: it is map-local AngelScript
//  shipped beside the .bsp, at
//      svencoop/scripts/maps/th_escape/trigger_playercheck.as   (281 lines)
//  with its own map-local .fgd at
//      svencoop/scripts/maps/th_escape/th_escape.fgd
//  Author Tomas "GeckoN" Slavotinek.  There is no entry in sven-coop.fgd and no
//  wiki page; the .as and that 16-line .fgd are the whole specification and both
//  were read rather than inferred.
//
//  WHAT IT IS FOR.  th_escape places 26 of them and every single one is the
//  same shape:  mode 2 (==), threshold 0, interval 0.5, spawnflags 1 (start
//  off), target a `squadmaker`.  "Exactly zero players are inside this box"
//  turns the spawner ON; a player walking in turns it OFF.  It is the map's
//  ambush primitive — zombies appear in the room you just left, never in front
//  of you.  The 27th, `dtown_chkmaster`, inverts it (mode 0 `>`, threshold 0,
//  starts ON) and is used as the `master` of the four downtown checks, so the
//  whole downtown ambush set only arms once somebody is actually in downtown.
//
//  Without this class those 26 squadmakers are never switched on by anything —
//  th_escape's `spawnflags 1` means they all start disabled — so the entire
//  back half of the map is empty of enemies.
//
//  DIVERGENCE, DELIBERATE: the original counts with
//  g_Utility.CountPlayersInBrushVolume, a real per-brush containment test.  This
//  uses an AABB overlap against .absmin/.absmax, which is what every other
//  volume trigger in this tree uses (Trigger_FireOnOverlap, sv_triggers.qc:419).
//  For a box brush the two are identical, and for a non-box brush the AABB is
//  the more GENEROUS answer — which on `mode 2, threshold 0` means "we think you
//  are still nearby, so hold the ambush", i.e. it errs toward not spawning
//  something in your face.  That is the safe direction for all 26.
//

// ---------------------------------------------------------------------------
//  Keys.  From the map-local FGD, verbatim:
//
//      mode(choices)      "Comparator"                default 0
//                             0 = > (Greater)
//                             1 = < (Less)
//                             2 = == (Equal)
//      threshold(integer) "Threshold"                 default 0
//      master(string)     "Master"                    (declared in sv_triggers.qc)
//      interval(string)   "Check-interval (seconds)"  default "0.5"
//      spawnflags         1 = "Start Off"
//
//  `interval` is a .string and that is not an accident.  Its FGD default is
//  "0.5", and a .float left at 0 cannot be told apart from an explicit "0" —
//  the same trap the item_inventory port documents at length.  Read through
//  PCheck_Interval() below so the default actually applies.
//
//  `mode` and `threshold` both default to 0 and 0 is a meaningful value for
//  each, so a plain .float is correct for those two.
//
//  COLLISION CHECK, MEASURED: all 141 .bsp files across svencoop/maps and
//  svencoop_downloads/maps were scanned for these three key spellings.  `mode`,
//  `threshold` and `interval` appear on trigger_playercheck and on NOTHING
//  else — 26 occurrences each, all in th_escape — with zero targetname
//  collisions and zero multi_manager slot collisions.  Declaring them is
//  therefore free, and it also stops them falling through ED_ParseUnknownEpair
//  into MM_AddSlot the way they do today.
// ---------------------------------------------------------------------------
.float  mode;
.float  threshold;
.string interval;

const float PCHECK_SF_START_OFF = 1;

const float PCHECK_CMP_GREATER = 0;
const float PCHECK_CMP_LESS    = 1;
const float PCHECK_CMP_EQUALS  = 2;

const float PCHECK_DEFAULT_INTERVAL = 0.5;

// Runtime state.  `pcheck_state` is the last comparator result we fired for and
// `pcheck_primed` says whether we have fired at all — the two together are the
// edge detector, and the original has exactly the same pair (m_fState plus the
// implicit false start).
.float pcheck_state;
.float pcheck_primed;
.float pcheck_enabled;

void() trigger_playercheck_think;

// ---------------------------------------------------------------------------
float(entity e) PCheck_Interval =
{
    if (e.interval == "" || e.interval == __NULL__)
        return PCHECK_DEFAULT_INTERVAL;
    float v = stof(e.interval);
    if (v < 0) return 0;
    return v;
};

// ---------------------------------------------------------------------------
//  How many LIVING players overlap this volume?
//
//  Walks the player chain rather than find()ing the edict list, for the same
//  reason Trigger_FireOnOverlap does: identical set, far cheaper, and 26 of
//  these tick at 2 Hz for the whole map.
// ---------------------------------------------------------------------------
float(entity vol) PCheck_CountInside =
{
    float n = 0;
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.health > 0)
        {
            vector pmin = p.origin + p.mins;
            vector pmax = p.origin + p.maxs;
            if (pmin_x <= vol.absmax_x && pmax_x >= vol.absmin_x
             && pmin_y <= vol.absmax_y && pmax_y >= vol.absmin_y
             && pmin_z <= vol.absmax_z && pmax_z >= vol.absmin_z)
                n = n + 1;
        }
        p = nxt;
    }
    return n;
};

// ---------------------------------------------------------------------------
//  GetNewState — the comparator.  CTriggerPlayerCheck::GetNewState.
// ---------------------------------------------------------------------------
float(entity e, float inside) PCheck_Compare =
{
    if (e.mode == PCHECK_CMP_LESS)   return (inside <  e.threshold);
    if (e.mode == PCHECK_CMP_EQUALS) return (inside == e.threshold);
    return (inside > e.threshold);           // 0 and anything unrecognised
};

// ---------------------------------------------------------------------------
//  ShouldUpdate — the master gate.
//
//  The original special-cases a master that is ITSELF a trigger_playercheck,
//  because Sven's IsMasterTriggered only understands multisource /
//  game_team_master and would otherwise report the permissive TRUE for one.
//  Its comment literally reads "GeckoN: TODO: Workaround".
//
//  th_escape needs that path: `dtown_chkmaster` is a trigger_playercheck and is
//  named as the `master` of four others.  IsMasterTriggered here has the same
//  permissive fallback (sv_triggers.qc:331), so the same special case is
//  required or the downtown ambushes arm from map start instead of when
//  somebody walks into downtown.
// ---------------------------------------------------------------------------
float(entity e) PCheck_ShouldUpdate =
{
    if (!e.pcheck_enabled)
        return FALSE;
    if (e.master == "" || e.master == __NULL__)
        return TRUE;

    // Prefer a trigger_playercheck match over any other, mirroring the
    // "prefer a real gate class" scan IsMasterTriggered does — targetnames are
    // not unique and the permissive fallback makes landing on the wrong one
    // silently disable the gate.
    entity m     = find(world, targetname, e.master);
    entity first = m;
    while (m)
    {
        if (m.classname == "trigger_playercheck")
            break;
        m = find(m, targetname, e.master);
    }

    if (m)
    {
        // A disabled master reports not-triggered, exactly as the original's
        // IsTriggered() does (it just returns m_fState, which a disabled check
        // never advances).
        return (m.pcheck_state != 0);
    }

    if (!first)
        return TRUE;                     // mapper typo policy, as everywhere

    return IsMasterTriggered(e.master, world);
};

// ---------------------------------------------------------------------------
//  FireTarget — USE_ON when the comparison holds, USE_OFF when it stops.
// ---------------------------------------------------------------------------
void(entity e) PCheck_FireTarget =
{
    if (e.target == "" || e.target == __NULL__)
        return;

    float ut = e.pcheck_state ? USE_ON : USE_OFF;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[playercheck %s] -> \"%s\" %s\n",
                       e.targetname, e.target, e.pcheck_state ? "ON" : "OFF"));

    // SUB_UseTargets, not SV_FireTargetsByName: the original fires self.pev.target
    // with self as both activator and caller, which is a caller-.target fire.
    // Going through SUB_UseTargets also picks up `delay` and `killtarget`, which
    // the shared base class gives every one of these entities.
    SUB_UseTargets(e, e, ut);
};

// ---------------------------------------------------------------------------
//  TestPlayersInVolume.
// ---------------------------------------------------------------------------
void(entity e) PCheck_Test =
{
    if (!PCheck_ShouldUpdate(e))
        return;

    float want = PCheck_Compare(e, PCheck_CountInside(e));

    // Edge only.  The original does the same (`if ( m_fState != fPrevState )`),
    // and pcheck_primed is what makes the very first evaluation count as an edge
    // so a volume that is already satisfied at spawn still arms its spawner.
    if (e.pcheck_primed && want == e.pcheck_state)
        return;

    e.pcheck_primed = TRUE;
    e.pcheck_state  = want;
    PCheck_FireTarget(e);
};

void() trigger_playercheck_think =
{
    PCheck_Test(self);

    float iv = PCheck_Interval(self);
    if (iv <= 0) iv = 0.05;              // a 0 interval must not busy-loop
    self.nextthink = time + iv;
};

// ---------------------------------------------------------------------------
//  Touch.  CTriggerPlayerCheck::Touch re-tests immediately, but only in the
//  three cases where an entry can flip the answer before the next tick:
//
//      state ON  and (threshold 0, ==)   -> somebody walked in, must go OFF now
//      state ON  and (threshold 1, <)    -> ditto
//      state OFF and (threshold 0, >)    -> somebody walked in, must go ON now
//
//  This is ShouldTouchToggle() verbatim.  It matters for th_escape's 26: a
//  player entering an ambush box has to disarm it on the frame they enter, not
//  up to half a second later with a zombie already materialising.
// ---------------------------------------------------------------------------
float(entity e) PCheck_ShouldTouchToggle =
{
    if (e.pcheck_state)
    {
        if (e.threshold == 0 && e.mode == PCHECK_CMP_EQUALS) return TRUE;
        if (e.threshold == 1 && e.mode == PCHECK_CMP_LESS)   return TRUE;
        return FALSE;
    }
    if (e.threshold == 0 && e.mode == PCHECK_CMP_GREATER) return TRUE;
    return FALSE;
};

void() trigger_playercheck_touch =
{
    if (other.classname != "player") return;
    if (!self.pcheck_enabled) return;
    if (!PCheck_ShouldTouchToggle(self)) return;
    PCheck_Test(self);
};

// ---------------------------------------------------------------------------
//  SetEnabled.  Disabling fires OFF once so a spawner does not stay armed
//  behind a switched-off check (CTriggerPlayerCheck::SetEnabled's
//  fFireOnDisable arm).  Enabling does NOT fire: the next tick decides.
// ---------------------------------------------------------------------------
void(entity e, float on, float fire_on_disable) PCheck_SetEnabled =
{
    if (e.pcheck_enabled == on)
        return;

    e.pcheck_enabled = on;

    if (on)
    {
        e.think     = trigger_playercheck_think;
        e.nextthink = time + 0.05;
        e.touch     = trigger_playercheck_touch;
        return;
    }

    e.think     = __NULL__;
    e.nextthink = 0;
    e.touch     = __NULL__;

    if (fire_on_disable && e.pcheck_state)
    {
        e.pcheck_state  = FALSE;
        e.pcheck_primed = TRUE;
        PCheck_FireTarget(e);
    }
};

void() trigger_playercheck_use =
{
    float ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

    float on = self.pcheck_enabled;
    if      (ut == USE_ON)  on = TRUE;
    else if (ut == USE_OFF) on = FALSE;
    else                    on = !self.pcheck_enabled;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[playercheck %s] use ut=%g -> %s\n",
                       self.targetname, sub_use_type, on ? "enabled" : "disabled"));

    PCheck_SetEnabled(self, on, TRUE);
};

/*QUAKED trigger_playercheck (.4 .8 .4) ?  START_OFF
Sven Co-op th_escape map-local entity (scripts/maps/th_escape/trigger_playercheck.as).
Counts LIVING players overlapping the brush and toggles `target` when the
comparison result changes.  th_escape's ambush primitive: mode 2 / threshold 0
means "nobody is in this room", which is when the squadmaker behind you starts
producing.

"target"     entity toggled USE_ON when the comparison holds, USE_OFF when it stops
"targetname" name (can itself be another check's `master`)
"master"     gate; may name another trigger_playercheck, which then gates on ITS state
"mode"       comparator: 0 = players > threshold, 1 = <, 2 = ==
"threshold"  the number compared against
"interval"   seconds between checks (default 0.5)
"delay" / "killtarget"  honoured via SUB_UseTargets

START_OFF (1)  spawn disabled; a trigger must USE it on.  All 26 in th_escape
               set this and all 26 are switched on by the map's own chains
               (`zspawn_mm` arms 22 of them with triggerstate 1).

USE_KILL: the original's fifth use type removes the entity outright.  This tree
has no USE_KILL — GoldSrc_TriggerStateToUseType maps the FGD's "Kill" (4) onto
USE_OFF, which disables the check and fires its target OFF, and no multi_manager
slot in the corpus asks for 4 on one of these.
*/
void() trigger_playercheck =
{
    if (!self.model)
    {
        remove(self);
        return;
    }

    setmodel(self, self.model);
    self.effects |= EF_NODRAW;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_TRIGGER;

    self.use = trigger_playercheck_use;

    // pcheck_enabled starts 0, so PCheck_SetEnabled's early-out means an
    // explicit "enable at spawn" has to be a real transition — pass the wanted
    // state and let it install the think.
    self.pcheck_enabled = FALSE;
    self.pcheck_state   = FALSE;
    self.pcheck_primed  = FALSE;

    if (!(self.spawnflags & PCHECK_SF_START_OFF))
        PCheck_SetEnabled(self, TRUE, FALSE);

    if (cvar("sv_debug_use"))
        dprint(sprintf("[playercheck %s] spawn mode=%g threshold=%g interval=%g master=\"%s\" startoff=%g\n",
                       self.targetname, self.mode, self.threshold,
                       PCheck_Interval(self), self.master,
                       (self.spawnflags & PCHECK_SF_START_OFF) ? 1 : 0));
};
