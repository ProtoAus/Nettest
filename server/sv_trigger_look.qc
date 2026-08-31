//
//  sv_trigger_look.qc — Sven Co-op th_escape's `trigger_look`
//
//  "Originally meant for jpolito's theyhunger map, now recycled in serious
//   sven!"  — the header of the original, by Zode, modified by GeckoN.
//
//  SOURCE.  Map-local AngelScript shipped beside the .bsp:
//      svencoop/scripts/maps/th_escape/trigger_look.as   (183 lines)
//  NOT a stock Sven entity.  sven-coop.fgd has a `trigger_lookat` — a
//  point-class "force one Ent to look at another Ent" — which is an entirely
//  different thing and is the reason a naive FGD grep says this class exists.
//  It does not; the .as is the whole specification and it was read, not guessed.
//
//  WHAT IT DOES.  Compares each contained player's VIEW YAW against the
//  trigger's own yaw and fires `target` USE_ON / USE_OFF depending on whether
//  they are looking at it or away from it.  th_escape places 7, and all 7 are
//  `trigger 0` / `difference 130` / `inverse 0`, i.e.
//
//      fire ON  when EVERY living player inside is facing more than 130 degrees
//               away from the trigger's angle
//      fire OFF the moment any of them turns back toward it
//
//  Six target a `squadmaker` and one targets a `func_door` (`lkzone01_dr`, the
//  door that only opens behind your back).  It is the other half of th_escape's
//  ambush system — trigger_playercheck handles "nobody is in the room", this
//  handles "nobody is looking".
//
//  ALL-OR-NOTHING IS NOT A SIMPLIFICATION.  The original tracks bCanUse and a
//  separate bUseLock, and the lock wins: one player facing the wrong way vetoes
//  the whole volume.  That is reproduced exactly below, because on a co-op
//  server it is the entire point — the ambush must not fire while ANY of four
//  players is watching the spot.
//

// ---------------------------------------------------------------------------
//  Keys.  There is no FGD for this class at all; these are the four szKey
//  comparisons in CTriggerLook::KeyValue, with the member initialisers as the
//  defaults:
//
//      difference   angle threshold, degrees                 default 16.0
//      trigger      0 = fire when NOT looking at, 1 = when looking at   default 0
//      delaychecks  seconds between re-evaluations           default 1.0
//      inverse      swap the ON and OFF sense                default 0
//
//  `difference` and `delaychecks` are .string because their defaults are
//  NON-ZERO and QC cannot tell a .float left at 0 from an explicit "0" — the
//  same rule the item_inventory port established.  `trigger` and `inverse`
//  default to 0, so a .float carries them correctly.
//
//  COLLISION CHECK, MEASURED: all 141 .bsp files under svencoop/maps and
//  svencoop_downloads/maps were scanned.  These four spellings appear on
//  trigger_look and on nothing else (7 occurrences each, all th_escape), with
//  zero targetname collisions and zero multi_manager slot collisions.  As with
//  the InventoryRules block, declaring them also stops them leaking into
//  ED_ParseUnknownEpair's MM_AddSlot allocation.
// ---------------------------------------------------------------------------
.string difference;
.float  trigger;
.string delaychecks;
.float  inverse;

const float LOOK_MODE_AWAY   = 0;   // "not looking at" fires
const float LOOK_MODE_TOWARD = 1;   // "looking at" fires

const float LOOK_DEFAULT_DIFFERENCE  = 16.0;
const float LOOK_DEFAULT_DELAYCHECKS = 1.0;

.float look_state;      // last use type we fired (USE_ON / USE_OFF)
.float look_primed;     // have we fired at all yet

void() trigger_look_think;

float(entity e) Look_Difference =
{
    if (e.difference == "" || e.difference == __NULL__)
        return LOOK_DEFAULT_DIFFERENCE;
    return stof(e.difference);
};

float(entity e) Look_DelayChecks =
{
    if (e.delaychecks == "" || e.delaychecks == __NULL__)
        return LOOK_DEFAULT_DELAYCHECKS;
    float v = stof(e.delaychecks);
    if (v < 0.05) return 0.05;          // never busy-loop on a hand-typed 0
    return v;
};

// ---------------------------------------------------------------------------
//  CTriggerLook::angledifference — TRUE when the yaw gap is at least the
//  threshold, i.e. when the player is looking AWAY.
//
//  Sven reads the player's yaw from pev->angles.y, which for a GoldSrc player
//  IS the view yaw.  In this tree .angles on a player is the MODEL/pose angle
//  (prop-hunt rewrites it outright, sv_player.qc:1406) and .v_angle is the
//  authoritative view — so v_angle_y is the faithful read here, not a
//  divergence.
// ---------------------------------------------------------------------------
float(entity e, entity plyr) Look_IsFacingAway =
{
    float d = e.angles_y - plyr.v_angle_y;
    while (d < -180) d = d + 360;
    while (d >  180) d = d - 360;
    return (fabs(d) >= Look_Difference(e));
};

// ---------------------------------------------------------------------------
//  Evaluate.  Returns the use type this volume wants to be asserting.
// ---------------------------------------------------------------------------
float(entity e) Look_Evaluate =
{
    float want_mode = e.trigger;              // 0 away, 1 toward
    float any_inside = FALSE;
    float can_use    = FALSE;
    float use_lock   = FALSE;

    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.health > 0)
        {
            vector pmin = p.origin + p.mins;
            vector pmax = p.origin + p.maxs;
            if (pmin_x <= e.absmax_x && pmax_x >= e.absmin_x
             && pmin_y <= e.absmax_y && pmax_y >= e.absmin_y
             && pmin_z <= e.absmax_z && pmax_z >= e.absmin_z)
            {
                any_inside = TRUE;

                float away = Look_IsFacingAway(e, p);
                // The original's four-way: a player in the WANTED state permits,
                // a player in the other state LOCKS, and the lock is checked
                // after the whole walk so it always wins.
                float wanted = (away && want_mode == LOOK_MODE_AWAY)
                            || (!away && want_mode == LOOK_MODE_TOWARD);
                if (wanted)
                    can_use = TRUE;
                else
                {
                    can_use  = FALSE;
                    use_lock = TRUE;
                }
            }
        }
        p = nxt;
    }

    // Empty volume: the original's toucherList-empty arm fires the OFF sense.
    if (!any_inside)
        return e.inverse ? USE_ON : USE_OFF;

    if (can_use && !use_lock)
        return e.inverse ? USE_OFF : USE_ON;

    return e.inverse ? USE_ON : USE_OFF;
};

// ---------------------------------------------------------------------------
//  DIVERGENCE, DELIBERATE — EDGE TRIGGERED.
//
//  CTriggerLook::LookThink calls FireTargets unconditionally on EVERY tick, so
//  at th_escape's delaychecks 0.5 each of the 7 volumes re-fires its chain twice
//  a second for the whole map.  That is harmless in Sven and harmless here (this
//  tree's squadmaker_use explicitly no-ops a re-asserted USE_ON,
//  sv_monsters.qc:1928, and a func_door does the same), but it is 14 chain walks
//  a second and 14 lines a second of [squadmaker] under sv_debug_monsters, which
//  makes the log useless for exactly the thing you would be reading it for.
//
//  So the state is latched and only transitions fire.  `look_primed` makes the
//  first evaluation count as a transition, so the initial OFF is still asserted
//  once — without it a spawner left ON by some other chain would never be told
//  to stop.  This is also what the same author's later trigger_playercheck does
//  natively (`if ( m_fState != fPrevState )`), so it is his own refinement
//  applied backwards to the older class.
// ---------------------------------------------------------------------------
void() trigger_look_think =
{
    self.nextthink = time + Look_DelayChecks(self);

    float want = Look_Evaluate(self);

    if (self.look_primed && want == self.look_state)
        return;

    self.look_primed = TRUE;
    self.look_state  = want;

    if (self.target == "" || self.target == __NULL__)
        return;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[trigger_look %s] -> \"%s\" %s (diff=%g mode=%g inv=%g)\n",
                       self.targetname, self.target,
                       (want == USE_ON) ? "ON" : "OFF",
                       Look_Difference(self), self.trigger, self.inverse));

    // SUB_UseTargets rather than a bare Trigger_UseTargets so `delay` and
    // `killtarget` work; the original fires self.pev.target with itself as both
    // activator and caller, which is what a caller-.target fire is here.
    SUB_UseTargets(self, self, want);
};

/*QUAKED trigger_look (.4 .6 .9) ?
Sven Co-op th_escape map-local entity (scripts/maps/th_escape/trigger_look.as).
Fires `target` depending on whether the players standing in the brush are
looking at it.  th_escape's other ambush primitive; distinct from Sven's stock
point-class `trigger_lookat`, which is unrelated.

"target"       toggled USE_ON / USE_OFF as the look state changes
"angles"       the yaw a player is compared against
"difference"   yaw gap in degrees that counts as "looking away" (default 16)
"trigger"      0 = fire when looking AWAY (th_escape uses this), 1 = when looking AT
"delaychecks"  seconds between re-evaluations (default 1.0)
"inverse"      1 swaps the ON and OFF sense
"delay" / "killtarget"  honoured via SUB_UseTargets

Every player inside must satisfy the condition: one player facing the wrong way
holds the whole volume OFF.  Fires on CHANGE only — see the note above.
*/
void() trigger_look =
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

    // No .touch.  The original installs one purely to build its toucher list;
    // the poll below covers the same ground without the list, and without the
    // index-shifting bug in its removeAt loop.
    self.look_state  = USE_OFF;
    self.look_primed = FALSE;

    self.think     = trigger_look_think;
    self.nextthink = time + 0.3;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[trigger_look %s] spawn target=\"%s\" yaw=%g diff=%g trigger=%g delay=%g inv=%g\n",
                       self.targetname, self.target, self.angles_y,
                       Look_Difference(self), self.trigger,
                       Look_DelayChecks(self), self.inverse));
};
