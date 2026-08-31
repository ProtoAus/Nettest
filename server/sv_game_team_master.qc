//
//  sv_game_team_master.qc  –  game_counter + game_team_master
//
//  Two "game system" point entities from HL/CS:
//   - game_counter: increments .frags per .use; fires when .frags
//     reaches .health.  Resets to 0 on fire (vs trigger_counter
//     which removes itself).
//   - game_team_master: gates / fires based on the activator's team.
//     Acts both as a master (IsMasterTriggered reads its team-match
//     result) and as a relay (its own .use forwards triggerstate to
//     the target chain when the team check passes).
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;              // sv_triggers.qc
float(float ts) GoldSrc_TriggerStateToUseType;                        // sv_triggers.qc

// Spawnflags for game_team_master.  HL bit layout.
const float SF_GTM_REMOVEONFIRE = 1;
const float SF_GTM_ANYTEAM      = 2;

// ============================================================================
//  game_team_master
// ============================================================================

void() game_team_master_use =
{
    if (!(self.spawnflags & SF_GTM_ANYTEAM))
    {
        if (!activator || activator.classname != "player")
            return;
        // teamindex 0/1 → TEAM_BLUE/TEAM_RED in this mod's enum.
        // Anything else (-1 etc.) is rejected.
        float want = (self.teamindex == 0) ? TEAM_BLUE :
                     (self.teamindex == 1) ? TEAM_RED  : -1;
        if (want == -1)
            return;
        if (activator.player_team != want)
            return;
    }

    if (!IsMasterTriggered(self.master, activator))
        return;

    float us = GoldSrc_TriggerStateToUseType(self.triggerstate);
    SUB_UseTargets(self, activator, us);

    if (self.spawnflags & SF_GTM_REMOVEONFIRE)
        remove(self);
};

/*QUAKED game_team_master (.5 .5 .5) (-8 -8 -8) (8 8 8) REMOVEONFIRE ANYTEAM
Fires its target only when the activator is on the configured team.
Also acts as a master — entities with master=<this name> stay locked
unless the team match would pass.

"targetname"   name
"target"       chain to fire
"teamindex"    0=Blue, 1=Red
"triggerstate" 0=off / 1=on / 2=toggle (default toggle)
"master"       upstream gate
*/
void() game_team_master =
{
    self.use = game_team_master_use;
};

// ============================================================================
//  game_counter
// ============================================================================

// Sven spawnflags (sven-coop.fgd:2660-2670).  All three were previously
// ignored: the counter always reset and never removed itself.  Measured on the
// target maps: 12 counters in -sp_campaign_portal set RESET, and 16 in
// pizza_ya_san1 set REMOVE — those 16 should delete themselves after firing
// but instead fired forever.
const float SF_GCOUNTER_REMOVE   = 1;    // "Remove On fire"
const float SF_GCOUNTER_RESET    = 2;    // "Reset On fire"
const float SF_GCOUNTER_OVERLIMIT = 4;   // "Fire if over limit"

void() game_counter_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    // THE USE TYPE PICKS THE DIRECTION.  CGameCounter::Use, maprules.cpp:698-712:
    //     case USE_ON:
    //     case USE_TOGGLE:  CountUp();          break;
    //     case USE_OFF:     CountDown();        break;
    //     case USE_SET:     SetCountValue(...); break;
    // This used to count up unconditionally, which is why th_escape's opening
    // never ended.  Its `startbutt_ms_cnt` is seeded `frags 30` and fired once a
    // second with USE_OFF (the multi_manager value "1#0") — a thirty-second
    // COUNTDOWN to zero.  Counting up instead walked away from the limit and the
    // start button stayed mastered off forever, so the map reported "wait 30
    // seconds" no matter how long you waited.
    //
    // USE_SET is deliberately not handled here: HL takes its new value from the
    // Use call's `value` argument, which this tree's chain dispatch does not
    // carry.  game_counter_set (sv_th_entities.qc) is the entity that exists to
    // stamp a value and it is what every map in the corpus actually uses, so a
    // SET arriving here is left as a no-op rather than guessed at.
    if (sub_use_type == USE_OFF)
        self.frags = self.frags - 1;
    else if (sub_use_type != USE_SET)
        self.frags = self.frags + 1;

    // Bit 4 "Fire if over limit" only matters once the counter has been
    // pushed past the threshold without resetting — i.e. when RESET is off.
    float hit = (self.spawnflags & SF_GCOUNTER_OVERLIMIT)
                ? (self.frags >= self.health)
                : (self.frags == self.health);
    if (cvar("sv_debug_use"))
        dprint(sprintf("[game_counter] \"%s\": %g -> %g (limit %g)%s\n",
                       self.targetname, self.frags - ((sub_use_type == USE_OFF) ? -1 : 1),
                       self.frags, self.health, hit ? "  HIT" : ""));

    if (!hit)
        return;

    SUB_UseTargets(self, activator, USE_TOGGLE);

    if (self.spawnflags & SF_GCOUNTER_REMOVE)
    {
        remove(self);
        return;
    }
    if (self.spawnflags & SF_GCOUNTER_RESET)
        self.frags = 0;
};

/*QUAKED game_counter (.5 .5 .5) (-8 -8 -8) (8 8 8) REMOVE_ON_FIRE RESET_ON_FIRE FIRE_IF_OVER
Increments an internal counter on each .use; fires its target when
the counter reaches "health".

REMOVE_ON_FIRE (1):  delete the counter after it fires.
RESET_ON_FIRE (2):   zero the counter after it fires (otherwise it keeps
                     climbing and, without FIRE_IF_OVER, never fires again).
FIRE_IF_OVER (4):    fire on >= threshold rather than exactly == threshold.

"targetname"  name
"target"      chain to fire on threshold
"frags"       initial value (default 0)
"health"      activation threshold (default 1)
"master"      upstream gate

NOTE the default threshold stays 1, NOT the FGD's 10.  The FGD number is an
editor default that Hammer writes into the file; four counters in
-sp_campaign_portal ship no `health` key at all, and giving those a threshold
of 10 would stall the map.
*/
void() game_counter =
{
    // Limit Value.  Half-Life leaves pev->health at 0 when the key is absent and
    // tests CountValue() == LimitValue(), so an absent limit means "count to
    // zero" — which is exactly what a counter SEEDED with a non-zero Initial
    // Value is for.  th_escape's startbutt_ms_cnt is `frags 30` with no `health`,
    // fired once a second with USE_OFF: a thirty-second countdown to 0.
    //
    // The 1 fallback is kept for the other shape only: a counter that starts at 0
    // and counts UP can never reach a limit of 0, so 0 would stall it.  Measured
    // over the 612 game_counters in the mounted corpus, just 9 omit `health` — 6
    // of those also omit `frags` (the -sp_campaign_portal chapter-intro counters
    // this fallback was written for), and the 3 that seed it (th_escape's,
    // svencoop2's endzonecount, sc_robination's checknoobs_c) all want 0.
    //
    // `health 0` written explicitly is indistinguishable from absent here, and
    // that is harmless: both mean the same thing to Half-Life.
    if (!self.health && !self.frags)
        self.health = 1;
    self.use = game_counter_use;
};
