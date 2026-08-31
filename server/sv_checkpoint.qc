//
//  sv_checkpoint.qc  –  point_checkpoint / player_respawn_zone
//
//  Sven Co-op's two co-op progression entities, and the two most-placed
//  unimplemented classnames in the They Hunger corpus:
//
//      point_checkpoint      32 placements / 16 of the 20 maps
//      player_respawn_zone   25 placements / 14 maps
//
//  Together they are how a Sven campaign handles death without a save game:
//  you walk into a checkpoint, it revives everyone who died before you got
//  there, and the respawn zone moves where future deaths come back.  With
//  neither implemented, a They Hunger death drops the player back at the
//  map's original info_player_deathmatch — which on th_ep3_04 is most of an
//  episode away.
//
//  point_checkpoint is NOT a Half-Life entity.  It is an AngelScript class that
//  ships with the game, and the behaviour below is read from the real source:
//      Sven Co-op/svencoop/scripts/maps/hunger/point_checkpoint.as
//  (the They Hunger-customised copy — there is a second, larger, generic one at
//  scripts/maps/point_checkpoint.as, and the campaign registers the hunger one).
//
//  THIS FILE DOES NOT INVENT A RESPAWN MECHANISM.  trigger_respawn already
//  solved the hard half (sv_goldsrc_compat.qc:612): dead players get a full
//  PlayerSpawn(), live players are relocated in place through
//  PlayerPlaceAtSpawnPoint + a prediction resync, because there is no
//  server-authoritative "teleport this player" entry point.  Both classes here
//  reuse that shape rather than growing a second one.
//

// All defined in sv_player.qc, which compiles after this file — the same
// forward-declaration block sv_goldsrc_compat.qc:626 carries.
void() PlayerPlaceAtSpawnPoint;
void() PlayerSpawn;
void(entity p) PlayerRefreshScoreboardInfo;
void(entity p) PM_SyncPredictionProxy;

// sv_triggers.qc — BSP-accurate "is this player really inside the brush",
// rather than inside its axis-aligned bounding box.
float(entity player, entity trig) Trigger_PlayerInBSPBrush;

// GoldSrcFX_Count (sv_goldsrc_effects.qc) is used below and is deliberately NOT
// re-declared here.  sv_goldsrc_effects.qc compiles at sv_progs.src:203, well
// above us, so the symbol is already defined — and a second declaration of an
// already-DEFINED function is not a harmless prototype in fteqcc: it re-emits
// the global as an empty function, so every call silently returns 0.  That is
// exactly what this census reported on its first run.

// Per-map census, one line, once, only on a map that has any.  Same shape and
// the same reasoning as GoldSrcFX_Report: a checkpoint that never spawned and a
// checkpoint that spawned but never fired look identical from the outside.
float cp_reported;

void() Checkpoint_Report =
{
    if (cp_reported)
        return;

    float a = GoldSrcFX_Count("point_checkpoint");
    float b = GoldSrcFX_Count("player_respawn_zone");
    if (!a && !b)
        return;      // latch AFTER this — see the note on GoldSrcFX_Report

    cp_reported = TRUE;
    print(sprintf("[checkpoint] point_checkpoint=%g player_respawn_zone=%g\n", a, b));
};

// ===========================================================================
//  point_checkpoint
// ===========================================================================
//  point_checkpoint.as, in order:
//
//    Spawn      SOLID_TRIGGER, models/hunger/umbrella.mdl unless the map gives
//               a model, hull (-64,-64,-36)..(64,64,36) unless minhullsize /
//               maxhullsize override it, sequence 1 ("idle_closed").
//    Touch      a player, once, if enabled: play hunger/checkpointjingle.mp3,
//               sequence 2, fire the target chain, and start reviving after
//               m_flDelayBeforeStart.
//    Revive     one player every m_flDelayBetweenRevive seconds — but ONLY
//               players who died BEFORE the checkpoint was touched.  That test
//               is not a detail, it is the anti-exploit: without it a party
//               could park on a checkpoint and use it as an infinite respawn.
//    Reusable   spawnflag 1 re-arms after m_flDelayBeforeReactivation seconds.
//
//  Every one of the 32 corpus placements leaves all three delays unset, so the
//  script's defaults (1.5 / 1 / 60) are the values that actually run.
// ===========================================================================

const float SF_CHECKPOINT_REUSABLE = 1;

// Script defaults, point_checkpoint.as:18-22.
const float CHECKPOINT_DELAY_START  = 1.5;
const float CHECKPOINT_DELAY_REVIVE = 1;
const float CHECKPOINT_DELAY_REARM  = 60;

const string CHECKPOINT_MODEL = "models/hunger/umbrella.mdl";
const string CHECKPOINT_JINGLE = "hunger/checkpointjingle.mp3";
const string CHECKPOINT_REVIVE_SND = "debris/beamstart15.wav";

// Map keys — lower case so GoldSrc_TryCaseFoldedField catches both spellings
// (see the note at the head of sv_goldsrc_effects.qc).
.float  m_fldelaybeforestart;
.float  m_fldelaybetweenrevive;
.float  m_fldelaybeforereactivation;

// .minhullsize / .maxhullsize are already declared and already parsed —
// sv_monsters.qc:905 uses the same two keys for a monster hull override, and
// point_checkpoint.as reads exactly those names.  Nothing to add.
.vector minhullsize;
.vector maxhullsize;

.float  cp_enabled;        // pev.health in the script
.float  cp_activated;      // pev.frags in the script
.float  cp_arm_time;       // when it was touched — the anti-exploit cutoff
.float  cp_next_index;     // resume point for the one-player-per-tick walk

void() Checkpoint_ReviveThink;
void() Checkpoint_RearmThink;

const string CHECKPOINT_BOLT_SPRITE = "sprites/lgtning.spr";

// Where the bolt comes from: an entity named by `netname` if the map gives one
// (20 of the 32 do — `chkpt1_targ`, `chkpt2_targ`, `lightningtarg`), otherwise
// straight up into the sky, which is what the script traces for.
vector(entity cp) Checkpoint_BoltOrigin =
{
    if (cp.netname != "" && cp.netname)
    {
        entity e = find(world, targetname, cp.netname);
        if (e)
            return e.origin;
    }
    traceline(cp.origin, cp.origin + '0 0 4096', TRUE, cp);
    return trace_endpos;
};

// point_checkpoint.as:296 writes a TE_BEAMPOINTS temp entity.  This engine has
// no such temp entity — shared/sh_hlbeamfx.qc exists precisely because the
// GoldSrc beam temp-entities are all missing, and it already owns the wire and
// the client draw.  Every value below is the script's: sprites/lgtning.spr,
// framerate 20, life 1 (tenths, so 0.1 s), width 24, noise 80,
// colour 172 255 255, brightness 255, scroll 0.
void(entity cp, entity p) Checkpoint_Bolt =
{
    HLBeam_EntFlash(cp, Checkpoint_BoltOrigin(cp), p.origin,
                    getmodelindex(CHECKPOINT_BOLT_SPRITE),
                    '172 255 255', 255, 24, 80, 0, 0.1, 0);
};

// Revive exactly ONE player per call, resuming where the last call stopped.
// The script walks player indices 1..maxClients and breaks on the first revive;
// this walks the mod's player chain and does the same, using cp_next_index as
// the resume cursor so a 32-player server does not rescan from the top each
// second.
//
// THE `died before we were touched` TEST IS THE WHOLE POINT.  Without it the
// checkpoint is an infinite respawn pad: die, get revived, die again, get
// revived again, forever.  cp_arm_time is stamped on touch and .death_time is
// what the player carries.
float(entity cp) Checkpoint_ReviveOne =
{
    entity oldself = self;
    entity e = player_chain_head;
    float idx = 0;
    while (e)
    {
        entity nxt = e.player_chain_next;
        idx = idx + 1;
        if (idx > cp.cp_next_index)
        if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
        if (e.is_dead)
        if (e.death_time < cp.cp_arm_time)
        {
            cp.cp_next_index = idx;

            self = e;
            e.is_dead            = FALSE;
            e.death_time         = 0;
            e.pending_round_join = FALSE;
            PlayerRefreshScoreboardInfo(e);
            PlayerSpawn();
            // PlayerSpawn put them on a spawn point; the checkpoint is where
            // they are supposed to come back.
            setorigin(e, cp.origin);
            e.fixangle = TRUE;
            PM_SyncPredictionProxy(e);
            self = oldself;

            Checkpoint_Bolt(cp, e);
            sound(e, CHAN_ITEM,
                  (cp.message != "" && cp.message) ? cp.message
                                                   : CHECKPOINT_REVIVE_SND,
                  1, ATTN_NORM);
            return TRUE;
        }
        e = nxt;
    }
    return FALSE;
};

void() Checkpoint_ReviveThink =
{
    if (Checkpoint_ReviveOne(self))
    {
        self.nextthink = time + (self.m_fldelaybetweenrevive > 0
                                 ? self.m_fldelaybetweenrevive
                                 : CHECKPOINT_DELAY_REVIVE);
        return;
    }

    // Nobody left to revive.  point_checkpoint.as:250 fades the portal out;
    // we just close the animation and either re-arm or go quiet for good.
    self.frame = 1;                       // idle_closed
    if (self.spawnflags & SF_CHECKPOINT_REUSABLE)
    {
        self.think     = Checkpoint_RearmThink;
        self.nextthink = time + (self.m_fldelaybeforereactivation > 0
                                 ? self.m_fldelaybeforereactivation
                                 : CHECKPOINT_DELAY_REARM);
        return;
    }
    self.think     = __NULL__;
    self.nextthink = 0;
};

void() Checkpoint_StartThink =
{
    self.frame            = 0;            // open idle
    self.cp_next_index    = 0;
    self.think            = Checkpoint_ReviveThink;
    self.nextthink        = time + 0.1;
};

void() Checkpoint_RearmThink =
{
    self.cp_activated = 0;
    self.frame        = 1;
    self.think        = __NULL__;
    self.nextthink    = 0;
};

void() Checkpoint_Touch =
{
    if (!self.cp_enabled || self.cp_activated)
        return;
    if (other.classname != "player" || other.is_dead)
        return;

    self.cp_activated = 1;
    self.cp_arm_time  = time;
    self.frame        = 2;

    // Latch the party's respawn here.  See the long note in
    // PlayerPlaceAtSpawnPoint for why this is not in the AngelScript and why it
    // is here anyway; `sv_checkpoint_respawn 0` makes it inert.
    cp_respawn_at = self;

    // ATTN_NONE, matching the script: a checkpoint jingle is a map-wide "you
    // made it" cue, not a positional sound.
    sound(self, CHAN_VOICE, CHECKPOINT_JINGLE, 1, ATTN_NONE);

    SUB_UseTargets(self, other, USE_TOGGLE);

    self.think     = Checkpoint_StartThink;
    self.nextthink = time + (self.m_fldelaybeforestart > 0
                             ? self.m_fldelaybeforestart
                             : CHECKPOINT_DELAY_START);
};

// A trigger naming the checkpoint enables/disables it (SetEnabled in the
// script).  Only one corpus placement is named at all, but the chain has to go
// somewhere or a multi_manager pointed at it stalls.
void() Checkpoint_Use =
{
    self.cp_enabled = self.cp_enabled ? 0 : 1;
    if (self.cp_enabled && !self.cp_activated)
        self.effects = self.effects - (self.effects & EF_NODRAW);
    else
        self.effects |= EF_NODRAW;
};

/*QUAKED point_checkpoint (0 .8 .8) (-64 -64 -36) (64 64 36) REUSABLE
Sven Co-op co-op checkpoint.  Touching it revives every player who died before
the touch, one per second, at this spot.

"model"                        override the umbrella model
"netname"                      entity the revive bolt comes from (else the sky)
"message"                      per-revive sound (default debris/beamstart15.wav)
"target"                       fired on the touch
"minhullsize" / "maxhullsize"  trigger hull override
"m_flDelayBeforeStart"         seconds before reviving starts (default 1.5)
"m_flDelayBetweenRevive"       seconds between revives (default 1)
"m_flDelayBeforeReactivation"  REUSABLE re-arm delay (default 60)
*/
void() point_checkpoint =
{
    string mdl = self.model;
    if (mdl == "" || !mdl)
        mdl = CHECKPOINT_MODEL;

    precache_model(mdl);
    precache_sound(CHECKPOINT_JINGLE);
    precache_sound(CHECKPOINT_REVIVE_SND);
    if (self.message != "" && self.message)
        precache_sound(self.message);
    precache_model(CHECKPOINT_BOLT_SPRITE);

    setmodel(self, mdl);
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_TRIGGER;

    // point_checkpoint.as:105 — the script's hull, not the model's.  Sven maps
    // write "0 0 0" for both keys to mean "no override", which this test
    // already handles (same convention sv_monsters.qc:905 relies on).
    if (self.minhullsize != '0 0 0' && self.maxhullsize != '0 0 0')
        setsize(self, self.minhullsize, self.maxhullsize);
    else
        setsize(self, '-64 -64 -36', '64 64 36');

    self.frame      = 1;        // idle_closed
    self.cp_enabled = 1;
    self.touch      = Checkpoint_Touch;
    self.use        = Checkpoint_Use;
};

// ===========================================================================
//  player_respawn_zone
// ===========================================================================
//  A brush volume (sven-coop.fgd:5334) with one key, `zonetype`:
//      0  "Respawn all outside"   (default — every corpus placement)
//      1  "Respawn all inside"
//
//  Fired by targetname, and the corpus names say plainly what the maps expect:
//  `spawn2force`, `spawn3_force`, `stairwell_forcespawn`, `churchrespawn`.
//  These are the campaign's "you have moved on, come back HERE now" markers,
//  triggered by the same multi_managers that toggle the info_player_deathmatch
//  sets.
//
//  So the implementation is trigger_respawn's, aimed at a volume: on trigger,
//  every player who is on the wrong side of the brush is brought to it —
//  zonetype 0 gathers the ones outside, zonetype 1 re-seats the ones inside.
//  Dead players get a full PlayerSpawn() first, exactly as trigger_respawn
//  does, so "respawn zone" means respawn and not merely teleport.
//
//  A DIVERGENCE WORTH STATING: Sven's zone also becomes the standing respawn
//  location for later deaths.  Reproducing that would mean a second, competing
//  spawn-point source alongside PlayerGetSpawnPointEntity's classname chain and
//  the .spawn_disabled toggles the maps already drive (sv_player.qc:39-46) —
//  two systems disagreeing about where a player belongs.  The maps that care
//  drive BOTH: they toggle their info_player_deathmatch sets AND fire the zone.
//  So the zone does the relocation and the existing spawn-point toggles keep
//  owning "where deaths come back", which is one system instead of two.
// ===========================================================================

.float zonetype;

// A point in the brush, on the floor, for a player to arrive at.  The brush's
// own origin is (0,0,0) for a BSP model, so it has to come from the bounds.
vector(entity zone) RespawnZone_Spot =
{
    vector c = (zone.absmin + zone.absmax) * 0.5;
    // Drop to the floor of the volume plus a player half-height, so nobody
    // arrives embedded in the ceiling of a tall trigger brush.
    c_z = zone.absmin_z + 36;
    return c;
};

void() RespawnZone_Use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    vector spot = RespawnZone_Spot(self);
    float moved = 0;
    entity oldself = self;
    entity zone = self;

    entity e = player_chain_head;
    while (e)
    {
        entity nxt = e.player_chain_next;
        if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
        {
            // Trigger_PlayerInBSPBrush is BSP-accurate; the AABB alone
            // over-reports for an angled or L-shaped volume, which here would
            // mean silently NOT moving a player who is really outside it.
            float inside = Trigger_PlayerInBSPBrush(e, zone) ? TRUE : FALSE;
            float wants  = zone.zonetype ? inside : !inside;

            if (wants)
            {
                self = e;
                if (e.is_dead)
                {
                    e.is_dead            = FALSE;
                    e.death_time         = 0;
                    e.pending_round_join = FALSE;
                    PlayerRefreshScoreboardInfo(e);
                    PlayerSpawn();
                }
                self = oldself;

                setorigin(e, spot);
                e.fixangle = TRUE;
                PM_SyncPredictionProxy(e);   // or CSQC keeps the old origin
                moved = moved + 1;
            }
        }
        e = nxt;
    }

    if (cvar("sv_debug_spawns"))
        bprint(PRINT_HIGH, sprintf("[respawn_zone] \"%s\" zonetype=%g moved %g player(s)\n",
                                   self.targetname, self.zonetype, moved));

    SUB_UseTargets(self, activator, USE_TOGGLE);
};

/*QUAKED player_respawn_zone (0 .6 .9) ?
Brush volume.  On trigger, brings players to it.

"zonetype"  0 gather everyone OUTSIDE the volume (default),
            1 re-seat everyone INSIDE it
*/
void() player_respawn_zone =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    // Invisible, but the bbox and BSP hull must stay linked — the same reason
    // trigger_hurt uses EF_NODRAW rather than clearing modelindex.
    self.effects |= EF_NODRAW;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_TRIGGER;
    self.use      = RespawnZone_Use;
};
