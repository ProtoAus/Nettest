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

    float us = self.triggerstate ? self.triggerstate : USE_TOGGLE;
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

void() game_counter_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;
    self.frags = self.frags + 1;
    if (self.frags >= self.health)
    {
        SUB_UseTargets(self, activator, USE_TOGGLE);
        self.frags = 0;          // resets — supersedes trigger_counter
    }
};

/*QUAKED game_counter (.5 .5 .5) (-8 -8 -8) (8 8 8)
Increments an internal counter on each .use; fires its target when
the counter reaches "health", then resets to "frags" (or 0).

"targetname"  name
"target"      chain to fire on threshold
"frags"       initial value (default 0)
"health"      activation threshold (default 1)
"master"      upstream gate
*/
void() game_counter =
{
    if (!self.health)
        self.health = 1;
    self.use = game_counter_use;
};
