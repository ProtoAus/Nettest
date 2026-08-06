//
//  sv_goldsrc_compat.qc  —  Half-Life / Sven Co-op entity compatibility
//
//  Two jobs:
//
//   1. SV_OnEntityNoSpawnFunction — the engine's last-resort hook for a
//      classname we have no spawn function for.  Without it those entities
//      are dropped, which silently SEVERS any target chain that referenced
//      them by targetname.  We keep them as inert pass-through relays
//      instead, so a chain routed through an unimplemented entity still
//      reaches the far side.
//
//   2. Spawn functions for the GoldSrc classes a real Sven campaign map
//      actually uses.  Reference map for the coverage work is
//      -sp_campaign_portal.bsp (BSP30, 1941 entities, 71 classnames);
//      counts in the comments below are from that map.
//
//  Conventions follow the rest of the GoldSrc port: SUB_UseTargets for
//  outbound chains (it handles .delay / .killtarget / useType),
//  IsMasterTriggered for `master` gating, sub_use_type / sub_use_caller for
//  useType pass-through.  See sv_triggers.qc.
//
//  Compile order: AFTER sv_triggers.qc (SUB_UseTargets, IsMasterTriggered)
//  and AFTER sv_teleport.qc (info_teleport_destination, aliased below).
//

// ---------------------------------------------------------------------------
// Shared field declarations.  The BSP entity parser drops keys whose fields
// aren't declared, so every key read below must appear here.
// ---------------------------------------------------------------------------
.string netname;            // trigger_random / game_zone_player target lists
.float  health;             // (already declared elsewhere; harmless re-decl)
.string message;

// game_zone_player
.string intarget;           // fired for players INSIDE the zone
.string outtarget;          // fired for players OUTSIDE the zone
.string incount;            // targetname whose .count receives the inside tally
.string outcount;
.float  zone_last_in;       // previous inside-count, for edge detection

// env_global
.float  initialstate;       // 0 off, 1 on, 2 dead
.float  globalstate_value;  // live state for this global
.float  triggermode;        // 0 off, 1 on, 2 dead, 3 toggle — Hammer spells
                            // this key WITHOUT an underscore; the field name
                            // must match the BSP key exactly or it never binds

// trigger_random / trigger_random_time
.float  target_count;       // how many of target1..target16 are populated
.string target1;  .string target2;  .string target3;  .string target4;
.string target5;  .string target6;  .string target7;  .string target8;
.string target9;  .string target10; .string target11; .string target12;
.string target13; .string target14; .string target15; .string target16;
.float  min_delay;
.float  max_delay;

// trigger_setorigin
.string copypointer;        // entity whose origin is copied FROM

// game_text: the styling keys (x / y / effect / fadein / fadeout / holdtime /
// fxtime / channel / color / color2) are deliberately NOT declared.  Our HUD
// message channel has no positioning or styling, so honouring them is
// impossible, and declaring `effect` in particular is a hard error — it
// collides with the `effect()` builtin in sv_defs.qc.  Undeclared keys fall
// through to ED_ParseUnknownEpair, whose classname fast-reject discards them.

// scripted_sequence / scripted_sentence
// m_iszEntity and the rest of the scripted_sequence keys now live in
// server/sv_scripted.qc, declared in LOWERCASE so that the case-folding fallback
// in ED_ParseUnknownEpair binds both the Hammer (m_iszEntity) and the
// lowercase-emitting compilers' spellings to one field.  The CamelCase
// declaration that used to be here only ever bound half the corpus.
.string sentence;
.float  delay;              // (already declared in sv_customdefs.qc)
// scripted_sentence's FGD 4-way sound radius: 0 small, 1 medium, 2 large,
// 3 everywhere -- the same bands as ambient_generic's radius spawnflags.
//
// NOTE the speaker key is spelled `entity` in the BSP, and that CANNOT be a QC
// field name ("entity" is a type keyword).  It is still unreachable - see
// ScriptedSentence_Speaker for why both escape hatches are closed server-side -
// so the speaker is now resolved as the nearest monster within `radius` instead
// of the line being emitted from the point entity.  On th_ep1_00 `announce` sits
// 42 units from its monster_scientist `onmybreak`, which is what makes that
// approximation land.  .volume is already declared by sv_func_train.qc, which
// compiles before this file.
.float  attenuation;

// ---------------------------------------------------------------------------
// Externs.
// ---------------------------------------------------------------------------
float(string msg, entity p) EnvMessage_SendOne;   // sv_env_hud.qc
float(string msg) EnvMessage_SendAll;             // sv_env_hud.qc
void(string msg) EnvHud_QueueMessage;             // sv_env_hud.qc
void() info_teleport_destination;                 // sv_teleport.qc

// ===========================================================================
//  1.  Unknown-classname fallback
// ===========================================================================

// Report each unhandled classname ONCE per map rather than once per entity —
// 44 monster_leech would otherwise be 44 identical lines.  The list is a
// single space-delimited string; map entity counts are small enough (a few
// dozen distinct unknown classes at worst) that a linear strstrofs beats
// spawning tracking entities.
string sv_compat_seen_classes;

void() GoldSrc_NoteUnhandled =
{
    string tok = strcat(" ", self.classname, " ");
    if (sv_compat_seen_classes != "" && strstrofs(sv_compat_seen_classes, tok) >= 0)
        return;
    sv_compat_seen_classes = strcat(sv_compat_seen_classes, tok);
    print(sprintf("[goldsrc-compat] no spawn function for \"%s\" — kept as inert relay\n",
                  self.classname));
};

// Inert relay .use: forward straight through to our target chain.
// SUB_UseTargets already honours .delay and .killtarget, so an unimplemented
// entity that the mapper gave a delay still contributes its timing.
void() GoldSrc_UnknownRelay_Use =
{
    SUB_UseTargets(self, activator, sub_use_type ? sub_use_type : USE_TOGGLE);
};

// Engine hook (engine/server/pr_cmds.c: looked up by name, called in place of
// a missing spawn function).  Reached only when neither spawnfunc_<class> nor
// <class> exists in the progs.
//
// Pass-through is deliberately chosen over "remove": on a campaign map a
// severed chain is a soft-lock, whereas an entity that fires its target
// early/unconditionally usually just makes progression more permissive.
// Set sv_compat_unknown_relay 0 to get the old drop-it behaviour.
void() SV_OnEntityNoSpawnFunction =
{
    GoldSrc_NoteUnhandled();

    if (!cvar("sv_compat_unknown_relay"))
    {
        remove(self);
        return;
    }

    // Keep the entity alive and addressable by targetname.  No model, no
    // solidity, no think — it exists purely so find(world, targetname, ...)
    // still resolves and the chain continues through it.
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = GoldSrc_UnknownRelay_Use;

    // Mark it.  Giving this entity a .use above is what lets a chain pass THROUGH
    // it, but it also makes it look like a working input to anything that waits on
    // its inputs — and nothing will ever fire it, because whatever would have done
    // so is the behaviour we did not implement.  multisource skips these when
    // registering, so one unimplemented class cannot lock a gate forever.
    self.gs_unimplemented = TRUE;
};

// ===========================================================================
//  2.  Tier 1 — trivial aliases and stubs
// ===========================================================================

// Sven spells the teleport destination without the "ination".  8 of these on
// the reference map; without the alias every trigger_teleport there resolves
// to nothing and players land at the world origin (or don't move at all).
void() info_teleport_dest =
{
    info_teleport_destination();
};

// Compile-time-only lighting entities.  ericw/VHLT bake these into the
// lightmap and leave the entity in the lump; they have no runtime behaviour.
// Declared so the engine stops reporting them as unhandled.
void() light_spot        = {};
void() light_environment = {};

// ammo_357 MOVED to server/sv_goldsrc_ammo.qc, which now owns every ammo class
// on one reserve mechanism.
//
// What was here spawned a whole .357 REVOLVER in place of a box of six rounds,
// because at the time there was nothing for standalone ammo to add to.  That is
// 389 placements of a free gun scattered through the campaign - generous, and not
// what any of those maps meant.
//
// The spawnfunc_ note that lived here is still true and still load-bearing, so it
// has gone with the class: `.float ammo_357` is the revolver's own ammo FIELD,
// and QC has one namespace for fields and functions, so the prefixed form is the
// only way to name the entity.  FTE resolves "spawnfunc_<classname>" ahead of
// "<classname>" (DP_SV_SPAWNFUNC_PREFIX).

// Sven's name for the Desert Eagle.
void() weapon_eagle =
{
    self.classname = "weapon_deagle";
    weapon_deagle();
};

// Monster-only clip brush.  531 of these across 81 Sven maps, and every one is a
// mapper saying "monsters may not go here" — the single richest navigation hint
// the corpus offers.  It used to be remove()d, which threw all of that away.
//
// It is now a real volume, using the same trick func_water documents at
// sv_water.qc:74-90: a NEGATIVE .skin makes FTE force every brush in the model to
// one contents value, and World_ClipMoveToEntity (engine world.c:1330-1369) only
// lets the model block a trace when the TRACE's own contents mask includes that
// value — otherwise it fabricates a clean fraction=1 result and the brush may as
// well not exist.
//
// Q1CONTENTS_MONSTERCLIP is -17 (engine bspfile.h:190) and maps to
// FTECONTENTS_MONSTERCLIP.  A player's trace mask never includes it: QC pmove
// traces with the player as passedict (sh_pmove.qc), and world.c:2844 gives a
// non-FL_MONSTER SOLID_SLIDEBOX box SOLID|WINDOW|BODY|PLAYERCLIP.  So players,
// bullets and grenades pass straight through with no per-trace work, exactly as
// they did when this was removed outright — while the nav builder, which traces
// with a probe whose mask DOES include it, finally sees the hint.
//
// Not routed through SV_InitReplicatedSolidBrush on purpose: there is nothing to
// draw and nothing for CSQC to collide with, and replicating it would risk client
// prediction disagreeing with the server about a brush players walk through.
void() func_monsterclip =
{
    if (self.model == "")
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    setorigin(self, self.origin);
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_BSP;
    self.skin     = CONTENT_MONSTERCLIP;
    self.effects  = self.effects | EF_NODRAW;
    nav_dbg_clipvols = nav_dbg_clipvols + 1;
};

// Sven surface-friction brush.  Real implementation needs a per-surface
// friction channel through pmove that doesn't exist yet; non-solid stub keeps
// the brush out of the way rather than blocking the player.
void() func_friction =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
};

// Monster navigation waypoint — pure data for AI that we don't have.
// Kept (not removed) so multi_manager chains naming one still resolve.
void() path_waypoint = {};

// ===========================================================================
//  Monsters have moved to server/sv_monsters.qc, which owns the single
//  Monster_Build() construction seam that GoldSrc AI will later plug into.
//  Do not re-add monster spawn functions here — one construction path only.
// ===========================================================================
void() GoldSrc_InertMonster =
{
    self.solid     = SOLID_NOT;
    self.movetype  = MOVETYPE_NONE;
    self.modelindex = 0;
    self.use       = GoldSrc_UnknownRelay_Use;
};

// ===========================================================================
//  Tier 3 — cosmetic / FX.  Accepted and inert so they neither spam the
//  console nor break chains.  Upgrade individually later if a map needs one.
// ===========================================================================
void() env_xenmaker          = { GoldSrc_InertMonster(); };
void() xen_plantlight_switch = { GoldSrc_InertMonster(); };
void() env_beverage          = { GoldSrc_InertMonster(); };
void() env_bubbles           = { self.solid = SOLID_NOT; self.movetype = MOVETYPE_NONE; };
void() env_shooter           = { GoldSrc_InertMonster(); };

// env_shake — screen shake on trigger.  We have no shake channel; forward the
// chain so anything downstream of it still fires.
void() env_shake =
{
    self.use = GoldSrc_UnknownRelay_Use;
};

// ===========================================================================
//  Tier 2 — progression logic.  These gate real map advancement, so they are
//  implemented rather than stubbed.
// ===========================================================================

// ---------------------------------------------------------------------------
// env_global — named global state, readable by multisource / trigger_condition
// and settable by any trigger.  Half-Life stores these in the save-game
// globalstate table and they survive level changes; we keep them per-map
// (cross-map persistence would need the changelevel transition code to carry
// them, which is out of scope) but the within-map behaviour is faithful.
//
// Keys:
//   globalname    the global's name
//   initialstate  0 off, 1 on, 2 dead
//   triggermode   what a trigger does to it: 0 off, 1 on, 2 dead, 3 toggle
// Flag 1: "Set initial state" — otherwise the global keeps whatever value it
//         already had (which for us, with no cross-map table, is off).
// ---------------------------------------------------------------------------
const float SF_GLOBAL_SET_INITIAL = 1;

// Look up the env_global entity that owns `name`.  Other entities read
// .globalstate_value off it.
entity(string name) EnvGlobal_Find =
{
    if (name == "" || name == __NULL__)
        return world;
    entity e = find(world, classname, "env_global");
    while (e)
    {
        if (e.globalname == name)
            return e;
        e = find(e, classname, "env_global");
    }
    return world;
};

float(string name) EnvGlobal_IsOn =
{
    entity g = EnvGlobal_Find(name);
    if (!g) return FALSE;
    return (g.globalstate_value == 1);
};

void() env_global_use =
{
    float mode = self.triggermode;

    if      (mode == 0) self.globalstate_value = 0;   // off
    else if (mode == 1) self.globalstate_value = 1;   // on
    else if (mode == 2) self.globalstate_value = 2;   // dead
    else                self.globalstate_value = self.globalstate_value ? 0 : 1;   // toggle

    if (cvar("sv_debug_use"))
        print(sprintf("[env_global] \"%s\" -> %g\n", self.globalname, self.globalstate_value));

    SUB_UseTargets(self, activator, USE_TOGGLE);
};

void() env_global =
{
    if (self.spawnflags & SF_GLOBAL_SET_INITIAL)
        self.globalstate_value = self.initialstate;
    else
        self.globalstate_value = 0;
    self.use = env_global_use;
};

// ---------------------------------------------------------------------------
// game_zone_player — counts players inside its brush volume and fires
// separate target chains for those in and out.  37 of these on the reference
// map, making it by far the most-used gameplay class we were missing.
//
// Half-Life fires intarget once per player inside and outtarget once per
// player outside, with that player as the activator, and writes the two
// tallies into the .count of the entities named by incount / outcount.
// ---------------------------------------------------------------------------
void() game_zone_player_use =
{
    float n_in  = 0;
    float n_out = 0;
    entity relay;       // QC locals are function-scoped — declare once up here
    entity counter;

    if (!IsMasterTriggered(self.master, activator))
        return;

    entity zone = self;
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;

        // AABB test against the brush volume.  Trigger_PlayerInBSPBrush
        // would be more precise, but a game_zone_player is usually a plain
        // box and the geometry probe costs a tracebox per player per fire.
        vector pmin = p.origin + p.mins;
        vector pmax = p.origin + p.maxs;
        float inside = (pmin_x <= zone.absmax_x && pmax_x >= zone.absmin_x
                     && pmin_y <= zone.absmax_y && pmax_y >= zone.absmin_y
                     && pmin_z <= zone.absmax_z && pmax_z >= zone.absmin_z);

        if (inside)
        {
            n_in = n_in + 1;
            if (zone.intarget != "")
            {
                relay = spawn();
                relay.classname = "zone_fire";
                relay.target    = zone.intarget;
                Trigger_UseTargets(relay, p);
                remove(relay);
            }
        }
        else
        {
            n_out = n_out + 1;
            if (zone.outtarget != "")
            {
                relay = spawn();
                relay.classname = "zone_fire";
                relay.target    = zone.outtarget;
                Trigger_UseTargets(relay, p);
                remove(relay);
            }
        }
        p = nxt;
    }

    // Publish the tallies onto the named counter entities.
    if (self.incount != "")
    {
        counter = findchain(targetname, self.incount);
        while (counter) { counter.count = n_in; counter = counter.chain; }
    }
    if (self.outcount != "")
    {
        counter = findchain(targetname, self.outcount);
        while (counter) { counter.count = n_out; counter = counter.chain; }
    }

    self.zone_last_in = n_in;

    if (cvar("sv_debug_use"))
        print(sprintf("[game_zone_player] \"%s\" in=%g out=%g\n",
                      self.targetname, n_in, n_out));
};

void() game_zone_player =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    // Same shape as trigger_multiple_init (sv_trigger_once_multi.qc): setmodel
    // for the bounds, EF_NODRAW so the AAATRIGGER placeholder texture doesn't
    // render.  Keep .model — clearing it after setmodel leaves the entity in a
    // half-initialised state.  SOLID_NOT rather than SOLID_TRIGGER: this is a
    // pure query volume, polled on .use, never a touch source.
    setmodel(self, self.model);
    self.effects |= EF_NODRAW;
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = game_zone_player_use;
};

// ---------------------------------------------------------------------------
// trigger_setorigin — teleports one entity onto another's origin.  Sven uses
// this to reposition brush entities and markers mid-map (8 on the reference
// map).
//
// Keys:  target      entity to move
//        copypointer entity whose origin is copied
// Flag 1: keep the target's angles instead of copying them.
// ---------------------------------------------------------------------------
const float SF_SETORIGIN_KEEP_ANGLES = 1;

void() trigger_setorigin_use =
{
    if (self.target == "" || self.copypointer == "")
        return;

    entity src = find(world, targetname, self.copypointer);
    if (!src)
        return;

    entity e = findchain(targetname, self.target);
    while (e)
    {
        setorigin(e, src.origin);
        if (!(self.spawnflags & SF_SETORIGIN_KEEP_ANGLES))
            e.angles = src.angles;
        e = e.chain;
    }
};

void() trigger_setorigin =
{
    self.use = trigger_setorigin_use;
};

// ---------------------------------------------------------------------------
// trigger_random / trigger_random_time — fire one randomly chosen target from
// target1..target16.  trigger_random fires once per activation;
// trigger_random_time re-fires on its own schedule between min_delay and
// max_delay seconds.
//
// Flag 1 (both): "Trigger once" — stop after the first fire.
// Flag 2 (random_time): "Start on".
// ---------------------------------------------------------------------------
const float SF_RANDOM_ONCE     = 1;
const float SF_RANDOMTIME_ON   = 2;

// Return slot `idx` (1-based) of the target1..target16 list.
string(entity e, float idx) TriggerRandom_Slot =
{
    if (idx == 1)  return e.target1;
    if (idx == 2)  return e.target2;
    if (idx == 3)  return e.target3;
    if (idx == 4)  return e.target4;
    if (idx == 5)  return e.target5;
    if (idx == 6)  return e.target6;
    if (idx == 7)  return e.target7;
    if (idx == 8)  return e.target8;
    if (idx == 9)  return e.target9;
    if (idx == 10) return e.target10;
    if (idx == 11) return e.target11;
    if (idx == 12) return e.target12;
    if (idx == 13) return e.target13;
    if (idx == 14) return e.target14;
    if (idx == 15) return e.target15;
    if (idx == 16) return e.target16;
    return "";
};

// Pick uniformly among the POPULATED slots.  Building the candidate list
// first (rather than retrying random draws) keeps this bounded and gives a
// true uniform distribution when the mapper leaves gaps in the list.
void() TriggerRandom_FireOne =
{
    float total = 0;
    float i = 1;
    while (i <= 16)
    {
        if (TriggerRandom_Slot(self, i) != "")
            total = total + 1;
        i = i + 1;
    }
    if (total <= 0)
        return;

    float pick = floor(random() * total);
    if (pick >= total) pick = total - 1;    // random() can return 1.0

    float seen = 0;
    i = 1;
    while (i <= 16)
    {
        string t = TriggerRandom_Slot(self, i);
        if (t != "")
        {
            if (seen == pick)
            {
                entity relay = spawn();
                relay.classname  = "random_fire";
                relay.target     = t;
                relay.delay      = self.delay;
                relay.killtarget = self.killtarget;
                SUB_UseTargets(relay, activator, USE_TOGGLE);
                remove(relay);
                return;
            }
            seen = seen + 1;
        }
        i = i + 1;
    }
};

void() trigger_random_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;
    TriggerRandom_FireOne();
    if (self.spawnflags & SF_RANDOM_ONCE)
        self.use = __NULL__;
};

void() trigger_random =
{
    self.use = trigger_random_use;
};

void() trigger_random_time_think =
{
    entity oldact = activator;
    activator = world;
    TriggerRandom_FireOne();
    activator = oldact;

    if (self.spawnflags & SF_RANDOM_ONCE)
        return;

    float lo = self.min_delay;
    float hi = self.max_delay;
    if (hi <= lo) hi = lo + 1;
    if (lo <= 0)  lo = 1;
    self.nextthink = time + lo + random() * (hi - lo);
};

void() trigger_random_time_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;
    // Toggle the schedule on/off.
    if (self.nextthink > time)
        self.nextthink = 0;
    else
    {
        self.think     = trigger_random_time_think;
        self.nextthink = time + 0.1;
    }
};

void() trigger_random_time =
{
    self.use = trigger_random_time_use;
    if (self.spawnflags & SF_RANDOMTIME_ON)
    {
        self.think     = trigger_random_time_think;
        self.nextthink = time + 1;
    }
};

// ---------------------------------------------------------------------------
// trigger_respawn — pull every player to the currently-active spawn points.
//
// This is the second half of Sven's checkpoint mechanism: the map toggles a
// set of info_player_deathmatch on (and the previous set off) by targetname,
// then fires a trigger_respawn to relocate everyone.  th_ep1_00 does exactly
// that after the intro — multi_manager `they2_respawn_change` enables
// `they2_respawn`, disables `they1_respawn`, then fires `they2_forcespawn`.
//
// Dead players get a full PlayerSpawn(); LIVE players are relocated in place,
// which is what makes the cutscene handoff work without killing anyone.  The
// trigger_teleport path deliberately isn't used — it is client-predicted and
// has no server-authoritative "teleport this player now" entry point, so a
// forced move has to go through PlayerPlaceAtSpawnPoint + a prediction resync.
// ---------------------------------------------------------------------------
// All defined in sv_player.qc, which compiles after this file.
void() PlayerPlaceAtSpawnPoint;
void() PlayerSpawn;
void(entity p) PlayerRefreshScoreboardInfo;
void(entity p) PM_SyncPredictionProxy;

void() trigger_respawn_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    float moved = 0;
    entity oldself = self;
    entity e = player_chain_head;
    while (e)
    {
        entity nxt = e.player_chain_next;      // e may be re-linked below
        if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
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
            else
            {
                PlayerPlaceAtSpawnPoint();
                e.fixangle = TRUE;
                PM_SyncPredictionProxy(e);     // or CSQC keeps the old origin
            }
            moved = moved + 1;
            self = oldself;
        }
        e = nxt;
    }

    if (cvar("sv_debug_spawns"))
        bprint(PRINT_HIGH, sprintf("[trigger_respawn] \"%s\" relocated %g player(s)\n",
                                   self.targetname, moved));

    SUB_UseTargets(self, activator, USE_TOGGLE);
};

void() trigger_respawn =
{
    self.use = trigger_respawn_use;
};

// trigger_vote now has a real implementation in server/sv_trigger_vote.qc.

// ---------------------------------------------------------------------------
// trigger_script — Sven's AngelScript hook.  There is no script VM here and
// there never will be, so this can only ever forward its chain.  Logged so
// the console makes clear which map behaviour is missing rather than leaving
// the mapper guessing.
// ---------------------------------------------------------------------------
void() trigger_script_use =
{
    if (cvar("sv_debug_use"))
        print(sprintf("[trigger_script] \"%s\" fired — AngelScript is not supported, forwarding chain\n",
                      self.targetname));
    GoldSrc_UnknownRelay_Use();
};

void() trigger_script =
{
    self.use = trigger_script_use;
};

// ---------------------------------------------------------------------------
// game_text — HUD text on trigger.
//
// env_message names a titles.txt entry and lets the client resolve the
// styling; game_text carries the styling INLINE on the map entity, so we ship
// the resolved values in CSQC_EVENT_GAME_TEXT and the client fills its message
// slot directly.
//
// `channel` is the important one: HL keeps each channel independent, and
// pizza_ya_san1 has 74 game_texts across channels 1 and 2 with every single
// one at y >= 0.  Routed by position (the old env_message rule) they all
// landed in the same slot and overwrote each other.
//
// Flag 1: "All players" (otherwise activator only).
// Flag 2: "No console echo" — accepted, ignored.
// ---------------------------------------------------------------------------
const float SF_GAMETEXT_ALLPLAYERS = 1;

float(entity p) GameText_SendOne =
{
    if (!p || p.classname != "player" || bot_adding
        || clienttype(p) != CLIENTTYPE_REAL)
        return FALSE;

    msg_entity = p;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_GAME_TEXT);
    WriteByte(MSG_ONE, bound(0, rint(self.channel), 255));
    // -1 is HL's "centre on this axis"; anything else is a 0..1 fraction.
    WriteCoord(MSG_ONE, self.gt_x ? self.gt_x : -1);
    WriteCoord(MSG_ONE, self.gt_y ? self.gt_y : -1);
    WriteByte(MSG_ONE, bound(0, rint(self.gt_effect), 255));
    // .color is the engine's realtime-light colour vector; the BSP `color`
    // key binds straight to it, which is why game_text needs no field of its
    // own.  Default to white when the mapper left it unset.
    vector c1 = self.color;
    if (c1 == '0 0 0') c1 = '255 255 255';
    vector c2 = self.color2;
    if (c2 == '0 0 0') c2 = c1;
    WriteByte(MSG_ONE, bound(0, rint(c1_x), 255));
    WriteByte(MSG_ONE, bound(0, rint(c1_y), 255));
    WriteByte(MSG_ONE, bound(0, rint(c1_z), 255));
    WriteByte(MSG_ONE, bound(0, rint(c2_x), 255));
    WriteByte(MSG_ONE, bound(0, rint(c2_y), 255));
    WriteByte(MSG_ONE, bound(0, rint(c2_z), 255));
    WriteFloat(MSG_ONE, self.fadein);
    WriteFloat(MSG_ONE, self.fadeout);
    WriteFloat(MSG_ONE, self.holdtime);
    WriteFloat(MSG_ONE, self.fxtime);
    WriteString(MSG_ONE, self.message);
    return TRUE;
};

float() GameText_SendAll =
{
    float sent = 0;
    entity p = find(world, classname, "player");
    while (p)
    {
        if (GameText_SendOne(p))
            sent = sent + 1;
        p = find(p, classname, "player");
    }
    return sent;
};

void() game_text_use =
{
    if (self.message == "")
        return;

    if (!IsMasterTriggered(self.master, activator))
        return;

    if (self.spawnflags & SF_GAMETEXT_ALLPLAYERS)
    {
        // The plain-text queue is the pre-spawn fallback: no styling, but a
        // message fired before anyone is connected still lands.
        if (GameText_SendAll() <= 0)
            EnvHud_QueueMessage(self.message);
    }
    else
    {
        entity p = activator;
        if (!p || p.classname != "player")
        {
            if (GameText_SendAll() <= 0)
                EnvHud_QueueMessage(self.message);
        }
        else if (!GameText_SendOne(p))
            EnvHud_QueueMessage(self.message);
    }

    SUB_UseTargets(self, activator, USE_TOGGLE);
};

void() game_text =
{
    // HL defaults, applied only where the mapper left the key out.
    if (!self.channel)  self.channel  = 1;
    if (!self.holdtime) self.holdtime = 4;
    if (!self.fxtime)   self.fxtime   = 0.25;
    self.use = game_text_use;
};

// ---------------------------------------------------------------------------
// scripted_sentence — the dialogue half of NPC choreography.
//
// scripted_SEQUENCE moved out to server/sv_scripted.qc when it stopped being a
// relay and became a real possession system; what stays here is the sentence
// entity, which never possesses anything - it only makes a monster speak.
//
// The relay pair below is still used by that: a scripted_sentence fires its own
// target chain when the line is done, and that chain is often what advances the
// map, so it keeps the same "fire it asynchronously whatever happens" guarantee
// it always had.
// ---------------------------------------------------------------------------
void() GoldSrc_ScriptFinish =
{
    entity oldact = activator;
    activator = self.delayed_activator;
    SUB_UseTargets(self, activator, USE_TOGGLE);
    activator = oldact;
};

void() GoldSrc_Script_Use =
{
    if (self.nextthink > time)
        return;                     // already running
    self.delayed_activator = activator;
    self.think     = GoldSrc_ScriptFinish;
    // HL's scripted_sequence has no single "duration" key — the length comes
    // from the animation.  Half a second is enough to keep the chain
    // asynchronous (so a sequence that targets its own trigger can't recurse)
    // without being a noticeable stall.
    self.nextthink = time + 0.5;
};

// Sven's `sentence` key has two forms and they are not interchangeable:
//
//   "+path/file.wav"   a literal sound path under sound/ -- play it directly
//   "!GROUP_NAME"      a sentences.txt group -- needs a lookup we do not have
//
// Measured over the 108-map Sven corpus: 353 scripted_sentence entities, 95
// use the '+' form (all 82 distinct paths exist under svencoop/sound/, none
// missing) and 258 use the '!' form.  Nothing uses a third form.  The '!'
// form is not implemented: Sven ships no sentences.txt (absent from both
// svencoop/sound/ and svencoop/), so the data would have to come from a
// Half-Life install plus a group->line table and a random picker.
//
// DELIBERATE DIVERGENCE FROM HL, so nobody "fixes" this later by accident.
// HL SDK dlls/scripted.cpp:1075 only speaks when FindEntity() locates a
// monster whose name/classname matches the `entity` key inside `radius`
// (:1140-1167) and then calls pTarget->PlayScriptedSentence (:1207).  With
// Monster_HasAI() off we have no such monster, so an HL-faithful port would
// be silent forever.  We emit from the scripted_sentence's own origin
// instead.  Also unimplemented: HL auto-fires a scripted_sentence that has no
// targetname 1 s after spawn (scripted.cpp:1040-1044).  3 of the 95 '+'
// entities corpus-wide have no targetname and will stay silent here.
//
// Attenuation bands follow AmbientGeneric_Attenuation() rather than HL's
// exact numbers: HL maps choice 2 ("Large") to ATTN_NORM 0.8 and we use 0.6,
// matching this mod's own ambient table.  Choices 0/1/3 do match HL
// (ATTN_IDLE 2.0 / ATTN_STATIC 1.25 / ATTN_NONE).
float() ScriptedSentence_Attn =
{
    if (self.attenuation >= 3) return ATTN_NONE;
    if (self.attenuation >= 2) return 0.6;
    if (self.attenuation >= 1) return 1.25;
    return 2.0;
};

// Who actually speaks.  HL looks up the monster named by the `entity` key (a
// targetname OR a classname) within `radius` and speaks from ITS mouth
// (scripted.cpp:1140-1207).  We used to emit from the scripted_sentence's own
// origin because there were no monsters to find; now there are, and the
// difference is audible - a line meant to come from the scientist beside you
// otherwise plays from a point entity across the room.
//
// Falls back to the sentence entity itself, which is what keeps a map whose
// speaker is missing (or is a class with no AI) audible instead of silent.
// The keys here are "entity" and "radius", NOT the m_isz*/m_fl* spellings
// scripted_SEQUENCE uses - measured across the corpus, where all 353
// scripted_sentences set "entity" and 342 set "radius", and not one uses
// m_iszEntity.  The two classes genuinely disagree.
//
// "entity" IS REACHABLE AFTER ALL, and the note that used to be here was wrong
// about why it wasn't.  There IS a QC keyvalue callback: the engine calls
// ED_ParseUnknownEpair(key, value) with self bound to the entity being parsed
// (engine/server/pr_cmds.c:487-506), which this mod has implemented since the
// multi_manager work.  The key is harvested there onto .m_iszentity - the same
// field scripted_SEQUENCE uses, because Half-Life stores both in the same
// member (CScriptedSentence::m_iszEntity) and only the BSP spelling differs.
//
// This is now HL's own CScriptedSentence::FindEntity, in its own order:
//   1. a MONSTER whose targetname is <entity>
//   2. failing that, a monster of CLASSNAME <entity> within radius
//   3. failing that, the nearest monster within radius
//   4. failing that, the sentence entity itself, so a map whose speaker is
//      missing stays audible instead of going silent
//
// Steps 1 and 2 are new and they are most of the value.  Measured over the map
// corpus - 758 scripted_sentences across 124 maps - the radius search alone
// finds NOTHING for 98 of them, and those lines played out of an invisible
// point entity, which is why no jaw moved: the mouth is driven by the amplitude
// of the voice channel on the SPEAKING ENTITY (engine cl_ents.c:4306-4309), and
// a point entity has neither a model nor a mouth controller to drive.  It also
// picked the WRONG monster for another 196.  Step 3 is kept underneath as the
// last resort for the 74 whose named speaker is spawned at runtime (squadmaker
// children), where there is no map entity to find.
entity() ScriptedSentence_Speaker =
{
    float rad = self.radius;
    if (rad <= 0)
        rad = 512;

    string want = self.m_iszentity;
    if (want != "" && want)
    {
        // 1. By targetname, ignoring radius entirely - HL's FindEntity does the
        //    same, and it is the case a mapper reaches for when the speaker is
        //    deliberately somewhere else (a gman down a corridor, a scientist
        //    behind glass).
        entity e = monster_chain_head;
        while (e)
        {
            if (e.health > 0 && (e.flags & FL_MONSTER) && e.targetname == want)
                return e;
            e = e.monster_chain_next;
        }

        // 2. By classname, nearest within radius.  HL's second pass is a sphere
        //    search on FClassnameIs, which is how "entity" "monster_scientist"
        //    picks whichever scientist happens to be standing there.
        entity bestc = world;
        float  bestcd = rad;
        e = monster_chain_head;
        while (e)
        {
            if (e.health > 0 && (e.flags & FL_MONSTER) && e.classname == want)
            {
                float d = vlen(e.origin - self.origin);
                if (d <= bestcd)
                {
                    bestcd = d;
                    bestc  = e;
                }
            }
            e = e.monster_chain_next;
        }
        if (bestc)
            return bestc;
    }

    // fteqcc scopes locals per FUNCTION, not per block, so these reuse the names
    // declared in the by-name search above rather than redeclaring them.
    entity best = self;
    float  bestd = rad;

    e = monster_chain_head;
    while (e)
    {
        if (e.health > 0 && (e.flags & FL_MONSTER))
        {
            d = vlen(e.origin - self.origin);
            if (d <= bestd)
            {
                bestd = d;
                best  = e;
            }
        }
        e = e.monster_chain_next;
    }
    return best;
};

void() GoldSrc_ScriptedSentence_Use =
{
    if (self.nextthink > time)
        return;                         // already speaking

    float vol = self.volume;
    if (vol <= 0)
        vol = 10;                       // FGD default
    vol = bound(0, vol * 0.1, 1);

    entity spk = ScriptedSentence_Speaker();
    string s   = self.sentence;

    if (substring(s, 0, 1) == "+")
    {
        // Sven's literal-path form: a real file under sound/, play it directly.
        sound(spk, CHAN_VOICE, substring(s, 1, -1), vol, ScriptedSentence_Attn());
    }
    else if (s != "")
    {
        // Half-Life's sentence form, both variants - see sv_sentences.qc.  A
        // failure here is now a genuinely missing sentence rather than a missing
        // FEATURE, so it stays a dprint and no longer spams a live console.
        if (!Sentences_Speak(spk, s, CHAN_VOICE, vol, ScriptedSentence_Attn()))
            dprint(sprintf("scripted_sentence \"%s\": sentence \"%s\" not in sentences.txt\n",
                           self.targetname, s));
    }

    GoldSrc_Script_Use();
};

// Boot-time proof that the `entity` key is being harvested at all.  Without a
// counter, "the speaker key now binds" is a claim about a code path that only
// runs when a mapper's trigger fires, which may be minutes into a map or never.
// These two numbers are printed with the AI report and must satisfy
// named == total on any GoldSrc map.  Declared in sv_customdefs.qc, which
// compiles ahead of the reporter that reads them.
void() scripted_sentence =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = GoldSrc_ScriptedSentence_Use;

    sv_dbg_sent_total = sv_dbg_sent_total + 1;
    if (self.m_iszentity != "" && self.m_iszentity)
        sv_dbg_sent_named = sv_dbg_sent_named + 1;

    if (substring(self.sentence, 0, 1) == "+")
        precache_sound(substring(self.sentence, 1, -1));
};

// ===========================================================================
//  pizza_ya_san1 coverage — pickups, func_plat, func_tank, game_end
// ===========================================================================

// Sven's name for the crowbar.
void() weapon_crowbar =
{
    self.classname = "weapon_hlcrowbar";
    weapon_hlcrowbar();
};

// 9mm ammo boxes MOVED to server/sv_goldsrc_ammo.qc.
//
// They used to be the one ammo class that worked, because 9mm was hand-wired to
// the glock and SMG pools right here.  That special case is now the general case:
// every calibre goes through one reserve mechanism, so a 9mm box behaves exactly
// like a box of buckshot and there is no longer a privileged calibre whose
// behaviour the others quietly fail to match.
//
// Its "fill BOTH consumers" rule survived the move intact - Half-Life shares one
// 9mm pool between the glock and the SMG and this mod does not, so a pickup that
// chose one of them would look broken to half the players.  See
// Ammo_GiveToCarried's CAL_9MM branch.

// ---------------------------------------------------------------------------
// Health pickups.  There is no existing health-item system in this mod, so
// this is the first one.  item_healthkit optionally carries its own model
// (pizza_ya_san1 overrides one of its three with a custom .mdl and leaves the
// other two to the default), plus scale / sequencename like item_generic.
//
// weapon_medkit is Sven's *healing tool* — a weapon you carry and fire at
// teammates.  With no weapon slot for it, a one-shot health pickup is the
// closest thing this build can honestly do; noted rather than silently
// aliased, because a player expecting a carryable medkit will be surprised.
// ---------------------------------------------------------------------------
const float HEALTHKIT_AMOUNT = 25;
const string HEALTHKIT_DEFAULT_MODEL = "models/w_medkit.mdl";

void() GoldSrc_Healthkit_Touch =
{
    if (other.classname != "player")
        return;
    if (other.health <= 0 || other.health >= 100)
        return;

    other.health = min(100, other.health + HEALTHKIT_AMOUNT);
    sound(other, CHAN_ITEM, "items/smallmedkit1.wav", 1, ATTN_NORM);

    if (self.target != "")
        SUB_UseTargets(self, other, USE_TOGGLE);
    remove(self);
};

void() item_healthkit =
{
    string mdl = self.model;
    if (mdl == "" || !mdl)
        mdl = HEALTHKIT_DEFAULT_MODEL;

    precache_model(mdl);
    precache_sound("items/smallmedkit1.wav");
    setmodel(self, mdl);
    setsize(self, '-16 -16 0', '16 16 32');
    self.solid    = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.touch    = GoldSrc_Healthkit_Touch;

    if (self.sequencename && self.sequencename != "")
    {
        float seq = frameforname(self.modelindex, self.sequencename);
        if (seq >= 0)
            self.frame = seq;
    }
};

void() weapon_medkit =
{
    self.classname = "item_healthkit";
    item_healthkit();
};

// ---------------------------------------------------------------------------
// func_plat — Half-Life's two-state lift.  Sits at the top, drops by `height`
// when a player stands on it (or when triggered), and returns.  Reuses the
// generic Mover_Start from sv_doors.qc rather than growing a third
// path-follower.
//
// HL derives the travel distance from the brush height minus `lip` when
// `height` is unset; pizza_ya_san1's two plats both set height explicitly
// (-210, i.e. downward), so that is the path exercised.
// ---------------------------------------------------------------------------
const float PLAT_SF_TOGGLE = 1;

.float plat_state;          // 0 = at top, 1 = at bottom
.float plat_moving;

void() plat_hit_top =
{
    self.plat_state  = 0;
    self.plat_moving = 0;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    Door_PlayStopSound();
};

void() plat_hit_bottom =
{
    self.plat_state  = 1;
    self.plat_moving = 0;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    Door_PlayStopSound();
};

void() plat_go_down =
{
    if (self.plat_moving || self.plat_state == 1)
        return;
    self.plat_moving = 1;
    self.mover_state = MOVER_STATE_DOWN;
    Door_PlayMoveSound();
    Mover_Start(self.pos2, self.speed, plat_hit_bottom);
};

void() plat_go_up =
{
    if (self.plat_moving || self.plat_state == 0)
        return;
    self.plat_moving = 1;
    self.mover_state = MOVER_STATE_UP;
    Door_PlayMoveSound();
    Mover_Start(self.pos1, self.speed, plat_hit_top);
};

void() plat_use =
{
    if (cvar("mp_disabledoors")) return;
    if (self.plat_state == 0)
        plat_go_down();
    else
        plat_go_up();
};

/*QUAKED func_plat (0 .5 .8) ? TOGGLE
Half-Life lift.  Starts at the top; moves `height` units (negative = down)
when triggered, and returns on the next trigger.

"speed"    movement speed (default 100)
"height"   travel distance along Z; negative moves down
"movesnd"  GoldSrc move-sound index
"volume"   parsed, not honoured (sound() uses full volume)
*/
void() func_plat =
{
    if (self.movesnd > 0) self.noise2 = Door_LookupMoveSound(self.movesnd);
    if (self.stopsnd > 0) self.noise1 = Door_LookupStopSound(self.stopsnd);
    Door_PrecacheIfReal(self.noise1);
    Door_PrecacheIfReal(self.noise2);

    if (!self.speed) self.speed = 100;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;   // rides the platform-carry branch so
                                          // players standing on it move with it
    self.use  = plat_use;
    self.pos1 = self.origin;

    // `height` is signed travel along Z.  Fall back to the brush's own height
    // when the mapper left it unset, which is HL's default derivation.
    float travel = self.height;
    if (travel == 0)
        travel = -(self.maxs_z - self.mins_z);
    self.pos2 = self.pos1 + [0, 0, travel];

    self.plat_state  = 0;
    self.mover_state = MOVER_STATE_TOP;
};

// ---------------------------------------------------------------------------
// func_tank / func_tankcontrols — a mounted gun the player takes control of by
// using the controls brush.  Implemented as a fixed emplacement: mounting
// locks you to it and your aim drives the barrel within the yaw/pitch ranges;
// firing traces a bullet with the tank's damage and rate.
//
// pizza_ya_san1's single tank has spawnflags 32 = SF_TANK_CANCONTROL, i.e. it
// is exactly the player-operated case.  The tank does NOT auto-target
// monsters here (there are none to target).
// ---------------------------------------------------------------------------
const float TANK_SF_CANCONTROL = 32;

.float  bullet;             // Sven bullet type index
.float  bullet_damage;
.float  firerate;
.float  barrel;
.float  yawrange;
.float  yawrate;
.float  yawtolerance;
.float  pitchrange;
.float  pitchrate;
.float  pitchtolerance;
.float  persistence;
.float  spritescale;
.entity tank_controller;    // player currently operating this tank
.entity tank_link;          // controls brush -> its tank
.float  tank_next_fire;
.vector tank_base_angles;

void() tank_fire =
{
    if (self.tank_controller == world)
        return;
    if (time < self.tank_next_fire)
        return;

    float rate = self.firerate;
    if (rate <= 0) rate = 4;
    self.tank_next_fire = time + 1.0 / rate;

    entity p = self.tank_controller;
    makevectors(p.v_angle);

    vector muzzle = self.origin + v_forward * self.barrel;
    traceline(muzzle, muzzle + v_forward * 8192, MOVE_NORMAL, self);

    float dmg = self.bullet_damage;
    if (dmg <= 0) dmg = 20;
    if (trace_ent && trace_ent != world)
        W_ApplyDamage(p, trace_ent, dmg);

    sound(self, CHAN_WEAPON, "weapons/turret_fire.wav", 1, ATTN_NORM);
};

void() tank_think =
{
    self.nextthink = time + 0.05;

    entity p = self.tank_controller;
    if (p == world)
        return;

    // Drop the player off the gun if they died or wandered out of range.
    if (p.health <= 0 || vlen(p.origin - self.origin) > 160)
    {
        p.pm_movetype = PM_MOVETYPE_NORMAL;
        self.tank_controller = world;
        return;
    }

    // Clamp the barrel to the mapper's arc, then follow the operator's aim.
    vector want = p.v_angle;
    float yaw_off   = anglemod(want_y - self.tank_base_angles_y + 180) - 180;
    float pitch_off = anglemod(want_x - self.tank_base_angles_x + 180) - 180;
    if (self.yawrange   > 0) yaw_off   = bound(-self.yawrange,   yaw_off,   self.yawrange);
    if (self.pitchrange > 0) pitch_off = bound(-self.pitchrange, pitch_off, self.pitchrange);

    self.angles_y  = self.tank_base_angles_y + yaw_off;
    self.angles_x  = self.tank_base_angles_x + pitch_off;
    self.SendFlags = 1;

    if (p.button0)
        tank_fire();
};

// Called from the controls brush's .use — mount or dismount.
void() tank_use =
{
    if (!(self.spawnflags & TANK_SF_CANCONTROL))
        return;

    if (self.tank_controller == activator)
    {
        activator.pm_movetype = PM_MOVETYPE_NORMAL;
        self.tank_controller  = world;
        return;
    }
    if (self.tank_controller != world)
        return;                     // someone else is on it

    self.tank_controller  = activator;
    activator.pm_movetype = PM_MOVETYPE_NONE;
    activator.velocity    = '0 0 0';

    if (self.target != "")
        SUB_UseTargets(self, activator, USE_TOGGLE);
};

/*QUAKED func_tank (0 .3 .8) ? x x x x x CANCONTROL
Player-operated mounted gun.  Mount it by +using a linked func_tankcontrols.

"barrel"        muzzle offset forward from the origin
"bullet_damage" damage per shot
"firerate"      shots per second
"yawrange" "pitchrange"  arc limits in degrees
"target"        fired when a player mounts
*/
void() func_tank =
{
    precache_sound("weapons/turret_fire.wav");
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
    self.use        = tank_use;
    self.tank_base_angles = self.angles;
    if (!self.barrel) self.barrel = 64;
    self.think     = tank_think;
    self.nextthink = time + 0.1;
};

void() tankcontrols_use =
{
    if (!self.tank_link)
        self.tank_link = find(world, targetname, self.target);
    if (!self.tank_link)
        return;

    entity oldself = self;
    self = self.tank_link;
    tank_use();
    self = oldself;
};

/*QUAKED func_tankcontrols (0 .3 .8) ?
Brush you +use to take control of the func_tank named by "target".
*/
void() func_tankcontrols =
{
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
    self.solid      = SOLID_BSP;
    self.use        = tankcontrols_use;
};

// ---------------------------------------------------------------------------
// game_end — ends the map when fired.  Routed through the existing round/map
// end path rather than a bare `changelevel`, so scoreboards and the map-end
// phase behave the same as a normal finish.
// ---------------------------------------------------------------------------
void() game_end_use =
{
    if (sv_game_end_requested)
        return;                     // already ending; don't re-announce
    sv_game_end_requested = 1;
    bprint(PRINT_HIGH, "Map objective complete.\n");
};

void() game_end =
{
    self.use = game_end_use;
};
