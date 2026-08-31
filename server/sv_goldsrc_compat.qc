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

// env_global.  The NAME of the global is the `globalstate` key, declared in
// sv_triggers.qc, and the live value lives in sv_globalstate.qc's table rather
// than on this entity — one name can have several env_globals writing it, and
// the value has to outlive the map.  There is deliberately no
// .globalstate_value field any more.
.float  initialstate;       // 0 off, 1 on, 2 dead
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
    // == USE_UNSET, not a truthiness test: USE_OFF is 0 and would be discarded
    // by a ternary, which is the tree-wide bug USE_UNSET exists to close
    // (sv_customdefs.qc).  An unimplemented entity relaying an explicit Off
    // must pass the Off through.
    SUB_UseTargets(self, activator,
                   (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type);
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

// Same family, and the FGD says so out loud: sven-coop.fgd:3373 declares
// info_texlights as a @PointClass with an EMPTY key list.  Its real payload is
// authored with SmartEdit off - one raw keyvalue per emissive texture, the KEY
// being the texture name and the VALUE "R G B brightness" (desertcircle's single
// instance carries "+0~light6a" "255 0 0 500").  VHLT's RAD reads those at
// compile time and bakes them; at runtime there is nothing to do.
//
// Declaring it stops the inert-relay path logging it as unhandled.  The texture
// keyvalues themselves still reach ED_ParseUnknownEpair and are reaped by
// MM_ReapOrphanSlots like any other unowned capture - harmless, and not worth a
// name-prefix skip when the key is an arbitrary texture name.
void() info_texlights    = {};

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

// weapon_eagle is now a REAL weapon - shared/weapons/sh_wpn_opeagle.qc, with
// Opposing Force's own v_/p_/w_desert_eagle models and its five sounds.  This
// alias onto Counter-Strike's Deagle was the closest of the eight by a
// distance (same gun, same calibre, wrong game) and is retired with them.

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
// env_shooter WAS here, inert.  It is now real — server/sv_goldsrc_effects.qc,
// sharing gibshooter's code exactly as HL's CEnvShooter derives from
// CGibShooter (effects.cpp:1520).  55 placements across 15 of the 22 They
// Hunger / pizza maps, and the reason it never appeared on the "unimplemented
// classnames" list is that A STUB COUNTS AS IMPLEMENTED: only a census that
// dumped per-class KEYS rather than per-class presence could find it.

// env_shake WAS here, forwarding its trigger and doing nothing because this
// tree had no shake channel.  It is now real — server/sv_screenshake.qc, with
// the receiving half in client/cl_screenshake.qc.  Exactly the same lesson as
// env_shooter directly above: 184 placements across 28 of the 36 Sven hl_ maps,
// and it never once appeared on an "unimplemented classnames" list because a
// stub reports as implemented to every presence-based audit.

// ===========================================================================
//  Tier 2 — progression logic.  These gate real map advancement, so they are
//  implemented rather than stubbed.
// ===========================================================================

// ---------------------------------------------------------------------------
// env_global — the WRITER for Half-Life's global state table (buttons.cpp:68).
// The table itself, and the reasoning behind it, is in sv_globalstate.qc.
//
// This used to keep the value on the entity and look it up by `.globalname`,
// which is the wrong key: HL reads the state's name from `globalstate`
// (buttons.cpp:73, commented "// State name" in the SDK), and `globalname` is an
// unrelated HL key for entity identity across a level transition.  Every one of
// the 36 env_global placements in the corpus sets `globalstate` and none sets
// `globalname`, so the old lookup could never match — and nothing called it
// anyway.  See sv_globalstate.qc's header for the measurement.
//
// Keys:
//   globalstate   the global's NAME (required; HL removes the entity without it)
//   initialstate  0 off, 1 on, 2 dead
//   triggermode   what a trigger does to it: 0 off, 1 on, 2 dead, 3 toggle
// Flag 1: "Set initial state" — WITHOUT it the entity defines nothing at spawn
//         and only writes when triggered, which is how a global set on an
//         earlier map survives being walked back into.
// ---------------------------------------------------------------------------
const float SF_GLOBAL_SET_INITIAL = 1;

void() env_global_use =
{
    float old = GlobalState_Get(self.globalstate);
    float mode = self.triggermode;
    float newstate;

    // buttons.cpp:99-121.  Note what case 3 does NOT do: a DEAD global stays
    // dead under toggle.  Only OFF<->ON flip.
    if      (mode == 0) newstate = GLOBAL_OFF;
    else if (mode == 1) newstate = GLOBAL_ON;
    else if (mode == 2) newstate = GLOBAL_DEAD;
    else if (old == GLOBAL_ON)  newstate = GLOBAL_OFF;
    else if (old == GLOBAL_OFF) newstate = GLOBAL_ON;
    else                        newstate = old;

    // buttons.cpp:127-130 — set if present, otherwise define it here.  A map
    // whose env_global has no "Set initial state" flag reaches the table for the
    // first time on this line.
    if (GlobalState_InTable(self.globalstate))
        GlobalState_SetState(self.globalstate, newstate);
    else
        GlobalState_Add(self.globalstate, newstate);

    if (cvar("sv_debug_use"))
        print(sprintf("[env_global] \"%s\" %g -> %g (mode %g)\n",
                      self.globalstate, old, newstate, mode));

    // NOT in Half-Life: CEnvGlobal::Use does not chain onward, it only writes
    // the table.  Kept because this tree has shipped it since the entity was
    // added and a map that targets through an env_global would break without it;
    // harmless in the reference maps, which give env_global no `target` at all.
    SUB_UseTargets(self, activator, USE_TOGGLE);
};

void() env_global =
{
    // buttons.cpp:83-88 — an env_global with no state name is REMOVED.  Keeping
    // it would leave a use-handler that writes to the empty name on every fire.
    if (self.globalstate == "" || self.globalstate == __NULL__)
    {
        if (cvar("sv_debug_use"))
            print(sprintf("[env_global] \"%s\" has no globalstate — removed\n",
                          self.targetname));
        remove(self);
        return;
    }

    // buttons.cpp:89-93 — the flag means "define it", and the InTable guard is
    // the whole point: re-entering a map must NOT reset a global the player
    // already changed on a previous visit.  GlobalState_Add no-ops on a name
    // that is present, so the guard is implicit, but it is stated here because
    // the SDK states it.
    if (self.spawnflags & SF_GLOBAL_SET_INITIAL)
    {
        if (!GlobalState_InTable(self.globalstate))
            GlobalState_Add(self.globalstate, self.initialstate);
    }

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
// trigger_setorigin — moves one entity onto another's, per-axis, optionally
// FOLLOWING it every frame.
//
// This was a one-shot .use handler that copied the whole origin and read flag 1
// as "keep angles".  Flag 1 is not that, and the one-shot shape is not the one
// the corpus mostly uses.  From sven-coop.fgd:6774-6801:
//
//      1 Constant           follow every frame, not once
//      4 Set Once           remove this entity after firing
//      8 Lock Offsets       keep the gap between target and pointer (needs 1)
//     16 Copy X Angle    32 Copy Y Angle    64 Copy Z Angle
//    128 Copy X Axis    256 Copy Y Axis    512 Copy Z Axis
//   1024 Skip Initial Set   do not move it up front; follow from where it is
//
//   copypointer   entity whose position is copied
//   offset        manual offset added to the copied position
//   angleoffset   manual offset added to the copied angles
//
// desertcircle's four flag movers are 1545 = Constant | Lock Offsets |
// Copy Z Axis | Skip Initial Set, which reads as "leave the flag sprite where I
// put it on the pole, then follow this hidden brush's HEIGHT forever".  That is
// the whole flag-raising mechanism: the momentary_rot_button drives a
// momentary_door parked out of sight, and this carries the visible flag up with
// it.  Under the old code none of those four bits meant anything, nothing ever
// triggered the entity, and the flag could not move at all.
//
// The lock is stored on the TARGET, not on this entity, because one
// trigger_setorigin may name several and each has its own gap to keep.
// ---------------------------------------------------------------------------
const float SF_SETORIGIN_CONSTANT    = 1;
const float SF_SETORIGIN_SETONCE     = 4;
const float SF_SETORIGIN_LOCKOFFSET  = 8;
const float SF_SETORIGIN_ANG_X       = 16;
const float SF_SETORIGIN_ANG_Y       = 32;
const float SF_SETORIGIN_ANG_Z       = 64;
const float SF_SETORIGIN_AXIS_X      = 128;
const float SF_SETORIGIN_AXIS_Y      = 256;
const float SF_SETORIGIN_AXIS_Z      = 512;
const float SF_SETORIGIN_SKIPINITIAL = 1024;
const float SF_SETORIGIN_AXIS_ALL    = 896;    // 128|256|512

.vector offset;              // manual position offset  ("x y z" map key)
.vector angleoffset;         // manual angle offset     ("x y z" map key)
.vector setorigin_lock;      // ON THE TARGET: gap to hold under Lock Offsets
.float  setorigin_locked;    // ON THE TARGET: gap has been captured

// Write one target from one source, honouring the axis and angle masks.
void(entity trg, entity src, entity cfg) SetOrigin_ApplyOne =
{
    // No axis bits at all means "all three".  The FGD ticks 128/256/512 by
    // default, so a map that never touched the flags still means every axis -
    // and that is also what this entity did before it had masks, which is what
    // keeps the maps already relying on it working.
    float ax = cfg.spawnflags & SF_SETORIGIN_AXIS_ALL;
    if (!ax)
        ax = SF_SETORIGIN_AXIS_ALL;

    vector base = src.origin + cfg.offset;
    if (cfg.spawnflags & SF_SETORIGIN_LOCKOFFSET)
        base = base + trg.setorigin_lock;

    vector prev = trg.origin;
    vector o    = trg.origin;
    if (ax & SF_SETORIGIN_AXIS_X) o_x = base_x;
    if (ax & SF_SETORIGIN_AXIS_Y) o_y = base_y;
    if (ax & SF_SETORIGIN_AXIS_Z) o_z = base_z;
    setorigin(trg, o);

    vector a  = trg.angles;
    vector sa = src.angles + cfg.angleoffset;
    if (cfg.spawnflags & SF_SETORIGIN_ANG_X) a_x = sa_x;
    if (cfg.spawnflags & SF_SETORIGIN_ANG_Y) a_y = sa_y;
    if (cfg.spawnflags & SF_SETORIGIN_ANG_Z) a_z = sa_z;
    trg.angles = a;

    // Harmless on a plain networked entity (env_sprite), required for anything
    // replicated through solid_brush_SendEntity.
    trg.SendFlags = -1;

    // Only when it actually MOVED.  A Constant follower re-writes the same
    // position 40 times a second while its source sits still, and four of them
    // (desertcircle has exactly four) drown every other line in the log -
    // including the one that says the base was captured.
    if (o != prev && cvar("sv_debug_use"))
        dprint(sprintf("[setorigin] \"%s\" <- \"%s\" src=%v lock=%v -> %v\n",
                       trg.targetname, src.targetname, src.origin,
                       trg.setorigin_lock, trg.origin));
};

// One pass over every named target.  Captures the Lock Offsets gap the first
// time it sees each one.
void(entity cfg) SetOrigin_Pass =
{
    entity src = find(world, targetname, cfg.copypointer);
    if (!src)
        return;

    // A path-following brush sits at its origin-brush position until its own
    // deferred think snaps it onto the track, and that snap can land AFTER the
    // trigger_auto that switches this follower on.  Measuring the Lock Offsets
    // gap in that window bakes the editor-to-track distance into the offset
    // permanently — on hl_c00 that is ~6000 units, and it put the tram spawn
    // points (and therefore the player) outside the map.  Force the source
    // into place first; idempotent, and a no-op for every other source class.
    Mover_EnsureSpawnPlacement(src);

    entity e = findchain(targetname, cfg.target);
    while (e)
    {
        if (!e.setorigin_locked)
        {
            // The target can be an unplaced mover too (a follower gluing one
            // train to another), and its gap is just as wrong if it is.
            Mover_EnsureSpawnPlacement(e);
            // Skip Initial Set is what makes the gap worth anything: without it
            // the FGD says the entity is moved onto the pointer FIRST and the
            // difference is computed after, which leaves a gap of zero.
            if (!(cfg.spawnflags & SF_SETORIGIN_SKIPINITIAL))
                SetOrigin_ApplyOne(e, src, cfg);
            e.setorigin_lock   = e.origin - src.origin;
            e.setorigin_locked = TRUE;
        }
        else
            SetOrigin_ApplyOne(e, src, cfg);
        e = e.chain;
    }
};

// CONSTANT MODE IS A SWITCH, and that is the other half of desertcircle's flag.
//
// Sven's changelog lists both halves as bugs it fixed -- "trigger_setorigin not
// accepting explicit off input in constant mode" and "trigger_setorigin in
// constant mode forgetting the copy/source entity when activated more than
// once" -- so a Constant one is started, stopped and restarted by triggering it,
// and keeps its pairing across all of that.
//
// The map is built on exactly that.  `startmm` switches all four flag followers
// ON at map start; when a base is captured its multi_manager fires the same
// entity a SECOND time, which switches the follower OFF and leaves the flag
// sprite standing at the masthead while the button's auto-return quietly winds
// the hidden door back down underneath it.  That is the "it stops and stays
// there" the mapper wrote, and without the off input the flag instead sailed
// past the top of its pole to wherever the door's full travel put it.
.float setorigin_on;

void() trigger_setorigin_think =
{
    if (!self.setorigin_on)
        return;                 // switched off - stop thinking, keep the lock
    SetOrigin_Pass(self);
    self.nextthink = time + Momentary_TickInterval();
};

void() trigger_setorigin_use =
{
    if (self.target == "" || self.copypointer == "")
        return;

    if (self.spawnflags & SF_SETORIGIN_CONSTANT)
    {
        // USE_ON / USE_OFF are explicit; a plain trigger (USE_TOGGLE, what a
        // multi_manager sends) flips it.  The lock captured on the way up is
        // deliberately NOT cleared: it belongs to the target/pointer pairing,
        // and re-arming with a fresh gap is what "forgetting the copy entity"
        // was.
        float want;
        if      (sub_use_type == USE_ON)  want = TRUE;
        else if (sub_use_type == USE_OFF) want = FALSE;
        else                              want = !self.setorigin_on;

        self.setorigin_on = want;
        if (!want)
        {
            self.nextthink = 0;
            return;
        }

        SetOrigin_Pass(self);
        self.think     = trigger_setorigin_think;
        self.nextthink = time + Momentary_TickInterval();
        return;
    }

    SetOrigin_Pass(self);

    if (self.spawnflags & SF_SETORIGIN_SETONCE)
        remove(self);
};

void() trigger_setorigin =
{
    self.use = trigger_setorigin_use;

    // An UNNAMED Constant one starts on its own, because nothing can ever
    // trigger it and the FGD does describe the flag as a property of the entity
    // ("will constantly update position if set").  A NAMED one waits to be
    // switched on: it is the only reading under which firing it twice can mean
    // anything, and every named one in this corpus is fired at map start by the
    // same multi_manager that later fires it again to stop it.
    if ((self.spawnflags & SF_SETORIGIN_CONSTANT) && self.targetname == "")
    {
        self.setorigin_on = TRUE;
        self.think        = trigger_setorigin_think;
        self.nextthink    = time + 0.1;
    }
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

// sven-coop.fgd:6660-6669, the trigger_respawn spawnflag block.
const float SF_RESPAWN_TARGETONLY  = 1;   // "Respawn Target" — NOT implemented, see below
const float SF_RESPAWN_DEADPLAYERS = 2;   // "Respawn dead players"
const float SF_RESPAWN_KEEPLIVING  = 4;   // "Don't move living players"

void() trigger_respawn_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    // CACHED BEFORE THE LOOP, and that is load-bearing rather than tidy: `self` is
    // reassigned to each PLAYER inside the loop below (PlayerSpawn and
    // PlayerPlaceAtSpawnPoint are both self-driven), so a `self.spawnflags` read in
    // there would be asking the player about its spawnflags, not the trigger.
    float sf = self.spawnflags;

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
                moved = moved + 1;
            }
            // "DON'T MOVE LIVING PLAYERS" IS A REAL FLAG AND WAS BEING DISCARDED.
            //
            // This function never read spawnflags at all, so it yanked everyone
            // alive to a spawn point regardless of what the mapper asked for.
            // th_ep1_01's `churchrespawn` is spawnflags 6 = 2|4, i.e. "revive the
            // dead, do NOT move the living" — so walking into the radio trigger
            // teleported you across the church for no reason.
            //
            // Gated on bit 4 ONLY, deliberately, not on 2|4.  The corpus settles
            // it: flag 4 never appears alone anywhere, six maps set it on top of
            // 2, and hl_c08_a2 / th_ep3_00 / th_ep3_03 each ship BOTH a plain
            // "respawn" and a separate flag-6 "respawn_dead" — which only makes
            // sense if 2 by itself still relocates the living.  Widening the mask
            // would silently stop th_ep1_05, th_ep2_04, th_ep3_00, th_ep3_03,
            // hl_c05_a2, hl_c08_a2, mustard and snd from working.
            //
            // th_ep1_00's `they2_forcespawn` is spawnflags 0, so the post-intro
            // cutscene handoff this function was originally written for keeps
            // moving living players exactly as before.
            //
            // STILL NOT IMPLEMENTED, left in place knowingly: bit 2 clear should
            // mean "do not revive corpses" (20 corpus maps use spawnflags 0), and
            // bit 1 "Respawn Target" should restrict the whole thing to one named
            // player (th_escape's respawn_winnars / respawn_ghosts /
            // respawn_lastlive). Both are separate patches; bit 1 in particular
            // needs the player-.targetname machinery.
            else if (!(sf & SF_RESPAWN_KEEPLIVING))
            {
                PlayerPlaceAtSpawnPoint();
                e.fixangle = TRUE;
                PM_SyncPredictionProxy(e);     // or CSQC keeps the old origin
                moved = moved + 1;
            }
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

// trigger_script moved to server/sv_mapscript.qc, which compiles just after this
// file.  It still forwards its chain through GoldSrc_UnknownRelay_Use below, but
// it now also reads m_iszScriptFunctionName and looks for a native stand-in, so
// a campaign whose AngelScript does something simple can get that something.

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

    // This inlines GoldSrc_PickupTaken's body rather than calling it, and has
    // since it was written.  Kept inline, but the respawn hook has to be here
    // too or item_healthkit would be the one pickup in the set that ignores
    // mp_item_respawndelay - which is the sort of gap nobody finds by reading.
    if (self.target != "")
        SUB_UseTargets(self, other, USE_TOGGLE);
    if (Pickup_Taken(self, PICKUP_KIND_ITEM))
        return;
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

// weapon_medkit is now a REAL weapon - shared/weapons/sh_wpn_svmedkit.qc, a
// carryable healing tool with its own charge pool, exactly as the note above
// said it should be.  item_healthkit stays: it is a different entity
// (sven-coop.fgd:3414) wearing a different world model, and maps place both.

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
// CFuncPlatRot's axis bits.  Same numbering and the same FGD-name-vs-world-axis
// inversion as func_door_rotating; the decode below is copied from
// sv_doors_rotating.qc:1082-1095 rather than re-derived.
const float PLATROT_X_AXIS = 64;
const float PLATROT_Y_AXIS = 128;

.float  plat_state;          // 0 = at top, 1 = at bottom
.float  plat_moving;
.float  plat_isrot;          // this is a func_platrot
// THE ROTATED END IS THE TOP, and this pair used to hold it the other way round.
// CFuncPlatRot::SetupRotation (plats.cpp:543-560):
//
//     m_start = pev->angles;                                  // zero: Setup cleared it
//     m_end   = pev->angles + pev->movedir * m_vecFinalAngle.x;
//     if ( !FStringNull(pev->targetname) )   // Start at top
//         pev->angles = m_end;
//
// and GoUp rotates toward m_end while GoDown rotates toward m_start
// (plats.cpp:569-576).  So TOP carries the `rotation` key and BOTTOM is zero.
// Holding it inverted left every named platrot - which is all 9 in the corpus -
// resting 90 degrees off Half-Life and spinning the wrong way round.
.vector plat_ang1;           // angles at the TOP position    (= HL's m_end)
.vector plat_ang2;           // angles at the BOTTOM position (= HL's m_start, zero)

// Sven's OpenClosable back-compat aliases, per sven-coop.fgd:844 and :853:
//   `fireonopen` == fireonopened  (Fire On Open End)   -> we are at the BOTTOM
//   `netname`    == fireonclosed  (Fire On Close End)  -> we are at the TOP
// Only two entities in the corpus set them (hl_c01_a1 and hl_c02_a1, both `ele_2`),
// and on both they drive the trigger_changetargets that re-aim the call button, so
// the elevator is unusable without them.  Declaring the field is enough for the
// engine to bind it: sv_multi_manager.qc's blanket "fireon" discard sits BELOW the
// declared-field lookup, so it only ever sees keys nothing claimed.
// `.string fireonopen;` moved to sv_doors.qc, which compiles first and needs it
// for func_door's own copy of this chain pair — a field can only be declared
// once, and the earlier declaration is the one both readers can see.
.float  fireonopen_triggerstate;
.float  netname_triggerstate;   // not a real key; keeps the two paths symmetrical

// The volume-aware sound pair.  The door helpers hardcode volume 1 on CHAN_VOICE;
// HL's CBasePlatTrain emits movement on CHAN_STATIC and arrival on CHAN_WEAPON, both
// at m_volume (plats.cpp:433-437, :455-465).  Every plat and platrot in the corpus
// sets `volume` explicitly, so honouring it is not cosmetic.
void() Plat_PlayMoveSound =
{
    if (!Door_IsSilentSound(self.noise2))
        sound(self, CHAN_VOICE, self.noise2, self.volume, ATTN_NORM);
};

void() Plat_PlayStopSound =
{
    Door_StopMoveSound();
    if (!Door_IsSilentSound(self.noise1))
        sound(self, CHAN_WEAPON, self.noise1, self.volume, ATTN_NORM);
};

// Fire one of the two Sven end-of-travel chains.  GoldSrc_TriggerStateToUseType
// already maps this enum (0 Off / 1 On / 2 Toggle, sven-coop.fgd:810-815); the
// corpus value is 2 on all twelve keys, which comes out as USE_TOGGLE.
void(string targ, float state) Plat_FireChain =
{
    if (targ == "" || targ == __NULL__)
        return;
    // Throwaway relay, the same shape sv_monsters.qc:1655-1660 uses for
    // squadmaker's trigger_target: SUB_UseTargets walks the CALLER's .target, and
    // the plat's own .target is a different chain we must not disturb.
    entity relay = spawn();
    relay.classname = "plat_fire";
    relay.target    = targ;
    SUB_UseTargets(relay, self, GoldSrc_TriggerStateToUseType(state));
    remove(relay);
};

// Forward decls: plat_hit_top re-arms the descent and plat_blocked reverses, so
// both halves of the travel pair are referenced before either is defined.
void() plat_go_down;
void() plat_go_up;

void() plat_hit_top =
{
    self.plat_state  = 0;
    self.plat_moving = 0;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    if (self.plat_isrot)
    {
        // Snap and stop, exactly as CFuncPlatRot::HitTop does (plats.cpp:599-602).
        // Leaving avelocity running would let the cage drift past its end angle by
        // however much of a tick was left over.
        //
        // No RotatingBrush_RemoveFromList: Plat_RotStart no longer adds us to that
        // list.  Kept as a paired comment rather than a defensive call, because a
        // remove on a brush that was never added is a walk of the whole list to
        // find nothing - and because the pairing is what a reader checks first.
        self.avelocity = '0 0 0';
        self.angles    = self.plat_ang1;
    }
    Plat_PlayStopSound();
    // "Closed" is the TOP for a plat.  See the .fireonopen note above.
    Plat_FireChain(self.netname, self.netname_triggerstate);

    // Non-toggle plats re-arm a descent 3 seconds after arriving (plats.cpp:467-483).
    if (!(self.spawnflags & PLAT_SF_TOGGLE))
    {
        self.think     = plat_go_down;
        self.nextthink = self.ltime + 3;
    }
};

void() plat_hit_bottom =
{
    self.plat_state  = 1;
    self.plat_moving = 0;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    if (self.plat_isrot)
    {
        self.avelocity = '0 0 0';
        self.angles    = self.plat_ang2;   // see plat_hit_top on the absent remove
    }
    Plat_PlayStopSound();
    // ...and "open" is the BOTTOM.
    Plat_FireChain(self.fireonopen, self.fireonopen_triggerstate);
};

// Start the rotation half in lockstep with the translation, which is all
// CFuncPlatRot::RotMove is (plats.cpp:608-620): a constant avelocity sized so the
// spin finishes exactly when the lift arrives.  Mover_Start owns the think, so this
// must NOT go through Mover_RotateStart - that installs its own think and the two
// would fight over .nextthink.
void(vector dest_ang, vector dest_org) Plat_RotStart =
{
    if (!self.plat_isrot)
        return;

    float dist = vlen(dest_org - self.origin);
    float tt   = 0;
    if (self.speed > 0)
        tt = dist / self.speed;
    if (tt <= 0)
    {
        self.angles    = dest_ang;
        self.avelocity = '0 0 0';
        return;
    }
    // HL's own short-travel guard (plats.cpp:614-620): under a tenth of a second it
    // stops dividing and just takes the delta as the rate, which spreads the spin
    // over a second instead of producing a colossal one-tick avelocity.  The lift
    // arrives long before that and HitTop/HitBottom snap the angle, so the visible
    // result is the same as the reference - it is the spike that is avoided.
    if (tt < 0.1)
        self.avelocity = dest_ang - self.angles;
    else
        self.avelocity = (dest_ang - self.angles) * (1 / tt);
    // NOT PUBLISHED TO rotating_brush_list, and the line that used to do that is
    // the reported "player rotates twice as far as the lift does".
    //
    // The comment on it claimed it was needed "so PM_CheckMovingPushers mirrors
    // the yaw carry on the client", but those are two different lists:
    // RotatingBrush_AddToList feeds PM_CheckRotatingCarry, while
    // PM_CheckMovingPushers walks moving_brush_list - which Mover_Start's
    // MovingBrush_AddToList has already handled, and whose TRAIN branch carries
    // the yaw itself (sh_pmove.qc:3952-4015, `yaw_delta` into
    // PM_RotateAroundPivot).  A plat is BRUSH_TYPE_TRAIN, so it took that branch
    // AND the rotating one, and each orbited pm_origin by the full step.
    //
    // PM_CheckRotatingCarry is also CSQC-only by design ("the server's separate
    // physics-tick carry is the authoritative one, running both would
    // double-apply"), so this only doubled on the client - the predicted body
    // swung twice as far as the server said and fought reconcile the whole ride.
    //
    // Visual rotation is unaffected: brushsync ships .avelocity independently of
    // either carry list.  PM_InheritRotatorTangent also still works - it reads
    // trace_ent.avelocity directly rather than walking the list - so stepping off
    // a spinning cage still throws you tangentially.
};

void() plat_go_down =
{
    if (self.plat_moving || self.plat_state == 1)
        return;
    self.plat_moving = 1;
    self.mover_state = MOVER_STATE_DOWN;
    Plat_PlayMoveSound();
    Plat_RotStart(self.plat_ang2, self.pos2);
    Mover_Start(self.pos2, self.speed, plat_hit_bottom);
};

void() plat_go_up =
{
    if (self.plat_moving || self.plat_state == 0)
        return;
    self.plat_moving = 1;
    self.mover_state = MOVER_STATE_UP;
    Plat_PlayMoveSound();
    Plat_RotStart(self.plat_ang1, self.pos1);
    Mover_Start(self.pos1, self.speed, plat_hit_top);
};

// CFuncPlat::Blocked, plats.cpp:497-512: one point of DMG_CRUSH, kill the movement
// sound, and REVERSE.  The 1 is hardcoded in the SDK and `dmg` is never read on a
// plat, which is the same call sv_th_entities.qc:5103-5107 already documents making
// for the other movers here - so the key stays parsed-and-unused on purpose.
//
// The stop/resume half is already handled: Mover_TravelTick zeroes velocity for the
// tick whenever it is wedged (sv_doors.qc:420-444) and resumes when clear. What was
// missing is only the crush and the reversal.
void() plat_blocked =
{
    if (other.cutscene_immune)
        return;
    W_ApplyDamage(self, other, 1);

    if (self.mover_state == MOVER_STATE_DOWN)
    {
        self.plat_moving = 0;
        self.plat_state  = 1;     // let go_up's state gate pass
        plat_go_up();
    }
    else if (self.mover_state == MOVER_STATE_UP)
    {
        self.plat_moving = 0;
        self.plat_state  = 0;
        plat_go_down();
    }
};

void() plat_use =
{
    if (cvar("mp_disabledoors")) return;

    // HL's PlatUse, plats.cpp:402-427.  TOGGLE plats honour the use type through
    // ShouldToggle with "top is off, bottom is on"; non-toggle plats are ONE-SHOT -
    // the first use clears .use and sends the lift down, and it comes back only on
    // the 3-second re-arm in plat_hit_top.
    //
    // USE_UNSET, not a truthy ternary: an explicit Off is 0 and the ternary would
    // discard it (sv_customdefs.qc).  hl_c01_a1 depends on this - its `ele_x_btm`
    // multi_manager fires `ele_2 "1#0"`, and that Off is what sends the cage home.
    float ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

    if (self.spawnflags & PLAT_SF_TOGGLE)
    {
        float on = (self.plat_state == 1);      // "top is off, bottom is on"
        if (ut == USE_ON  && on)  return;
        if (ut == USE_OFF && !on) return;

        if (self.plat_state == 0)
            plat_go_down();
        else
            plat_go_up();
        return;
    }

    self.use = sub_noop;
    if (self.plat_state == 0)
        plat_go_down();
};

// The auto-call field.  CPlatTrigger::SpawnInsideTrigger (plats.cpp:339-395) wraps a
// non-toggle plat in a trigger volume 25 units wider on each horizontal axis, 8 units
// tall above the top position and extending down over the whole travel; stepping into
// it calls the lift up, and standing on the plat at the top re-arms the descent.
// 29 of the corpus's 37 plats are non-toggle and had none of this.
void() plat_trigger_touch =
{
    entity p = self.owner;
    if (other.classname != "player")  return;
    if (other.health <= 0)            return;
    if (!p || p == world)             { remove(self); return; }

    entity oldself = self;
    self = p;
    if (self.plat_state == 1)
        plat_go_up();
    else if (self.plat_state == 0 && !self.plat_moving)
    {
        // Standing on it at the top - push the auto-descend out, HL's 1 second.
        self.think     = plat_go_down;
        self.nextthink = self.ltime + 1;
    }
    self = oldself;
};

void() Plat_SpawnInsideTrigger =
{
    entity t = spawn();
    t.classname = "plat_trigger";
    t.owner     = self;
    t.solid     = SOLID_TRIGGER;
    t.movetype  = MOVETYPE_NONE;
    t.touch     = plat_trigger_touch;

    vector mn = self.absmin, mx = self.absmax;
    mn_x = mn_x - 25;  mn_y = mn_y - 25;
    mx_x = mx_x + 25;  mx_y = mx_y + 25;
    // Down over the whole travel, up 8 above the resting top - plats.cpp:352-360.
    mn_z = mn_z - fabs(self.pos1_z - self.pos2_z);
    mx_z = self.absmax_z + 8;
    setorigin(t, '0 0 0');
    setsize(t, mn, mx);
};

// Shared spawn body for func_plat and func_platrot.  `isrot` adds the rotation
// half; everything else — travel, sounds, use semantics, the auto-call field — is
// identical, exactly as CFuncPlatRot derives from CFuncPlat (plats.cpp:515).
void(float isrot) Plat_SpawnCommon =
{
    // THE PLAT SOUND TABLES, NOT THE DOOR ONES.  CBasePlatTrain::Precache uses
    // plats/*.wav over 13 move and 8 stop indices (plats.cpp:96-260); the door table
    // is doors/doormoveN and only reaches 10, so movesnd 11/12/13 fell off the end
    // into silence — and hl_c01_a1's and hl_c02_a1's elevators are both movesnd 12.
    // FuncTrain_MoveSound/StopSound already implement HL's table and compile at
    // sv_progs.src:187, well ahead of this file at :273.
    if (self.movesnd > 0) self.noise2 = FuncTrain_MoveSound(self.movesnd);
    if (self.stopsnd > 0) self.noise1 = FuncTrain_StopSound(self.stopsnd);
    // Explicit overrides win, per the PlatSounds FGD block (sven-coop.fgd:1224-1225).
    if (self.noise  != "" && self.noise  != __NULL__) self.noise2 = self.noise;
    if (self.noise1 != "" && self.noise1 != __NULL__) self.noise1 = self.noise1;
    Door_PrecacheIfReal(self.noise1);
    Door_PrecacheIfReal(self.noise2);

    if (!self.speed)  self.speed  = 150;   // plats.cpp:300
    if (!self.volume) self.volume = 0.85;  // plats.cpp:305

    // A plat never rotates its brushwork off the mapper's angles key - HL clears it
    // in Setup (plats.cpp:285) BEFORE SetupRotation runs, which is also why a
    // func_platrot always spins from zero.  Must happen before the brush is linked.
    self.angles     = '0 0 0';
    self.plat_ang2  = '0 0 0';        // BOTTOM = HL's m_start, which Setup just zeroed
    self.plat_isrot = isrot;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;   // rides the platform-carry branch so
                                          // players standing on it move with it
    self.use     = plat_use;
    self.blocked = plat_blocked;
    // Same ObjectCaps reasoning as func_train (sv_func_train.qc): CFuncPlat and
    // CFuncPlatRot both derive from CBasePlatTrain, whose caps come out ZERO
    // (plats.cpp:35), so neither is in the player's +use search.  A plat is
    // ridden or triggered; the thing you press is its call button.
    self.use_passthrough = TRUE;
    self.pos1    = self.origin;

    // TRAVEL DIRECTION.  HL: m_vecPosition2.z = pev->origin.z - m_flHeight
    // (plats.cpp:296-299), so a NEGATIVE height moves the plat UP.  This used to add
    // the key instead of subtracting it, which drove 33 of the corpus's 37 plats
    // backwards - pizza_ya_san1's two shop shutters are 220-tall brushes with
    // height -210 that are supposed to roll up out of the doorway, and they sank into
    // the floor instead.
    float travel = -self.height;
    if (self.height == 0)
        travel = -((self.maxs_z - self.mins_z) - 8);   // plats.cpp:298, incl. HL's +8
    self.pos2 = self.pos1 + [0, 0, travel];

    if (isrot)
    {
        // CBaseToggle::AxisDir's bit map, copied from sv_doors_rotating.qc:1082-1095
        // rather than re-derived: the FGD flag NAMES refer to which movedir slot HL
        // sets, not to the world axis.  None of the 7 corpus platrots uses either
        // bit, so this is for completeness.
        float rot = self.rotation;
        if (self.spawnflags & PLATROT_X_AXIS)
            self.plat_ang1 = [0, 0, rot];        // roll,  around world X
        else if (self.spawnflags & PLATROT_Y_AXIS)
            self.plat_ang1 = [rot, 0, 0];        // pitch, around world Y
        else
            self.plat_ang1 = [0, rot, 0];        // yaw
    }

    // A NAMED plat starts at the TOP and is brought down by whatever names it; an
    // UNNAMED one starts at the BOTTOM and is called up by the trigger field
    // (plats.cpp:318-336).  All 37 corpus plats are named, so the second case is
    // dormant today - it is here because the first one is meaningless without it.
    if (self.targetname != "" && self.targetname != __NULL__)
    {
        // "Start at top" - and the top is the ROTATED end, so a named platrot has
        // to be placed at that angle, not at zero (plats.cpp:557-560).  This is the
        // line that made hl_c01_a1's elevator cage sit square to the shaft instead
        // of turned 90 degrees the way Half-Life leaves it.
        if (isrot)
        {
            self.angles = self.plat_ang1;
            // SV_InitReplicatedSolidBrush linked this brush at the old angle, so the
            // PVS box would be built from geometry rotated about (0,0,0) until its
            // first move.  Same relink func_door_rotating and momentary_door do.
            BrushSync_RelinkAngles();
        }
        self.plat_state  = 0;
        self.mover_state = MOVER_STATE_TOP;
    }
    else
    {
        setorigin(self, self.pos2);
        // The bottom IS m_start, which is zero, and .angles is already zero.
        self.plat_state  = 1;
        self.mover_state = MOVER_STATE_BOTTOM;
    }

    // Non-toggle plats get HL's auto-call volume.  After the origin is settled, so
    // the box is sized around where the brush actually rests.
    if (!(self.spawnflags & PLAT_SF_TOGGLE))
        Plat_SpawnInsideTrigger();

    // The plat family had no debug print of its own, which is why the inverted
    // rotation endpoints survived: `sv_debug_doors` reaches Mover_TravelTick (which
    // a plat does use) but nothing ever said what the two ends WERE.
    if (cvar("sv_debug_doors"))
        dprint(sprintf("[plat] \"%s\" rot=%g top=%v bottom=%v pos1=%v pos2=%v ang=%v\n",
                       self.targetname, self.rotation, self.plat_ang1, self.plat_ang2,
                       self.pos1, self.pos2, self.angles));
};

/*QUAKED func_plat (0 .5 .8) ? TOGGLE
Half-Life lift.  A named plat starts at the top and is brought down by its
trigger; an unnamed one starts at the bottom and is called up by stepping into
the volume around it.

"speed"    movement speed (default 150)
"height"   travel along Z.  HL subtracts it, so NEGATIVE moves the plat UP.
"movesnd"  GoldSrc plat move-sound index (1..13, the plats sound table)
"stopsnd"  GoldSrc plat stop-sound index (1..8)
"volume"   0..1, honoured on both
*/
void() func_plat =
{
    Plat_SpawnCommon(FALSE);
};

/*QUAKED func_platrot (0 .5 .8) ? TOGGLE x x x x x X_AXIS Y_AXIS
func_plat that also spins while it travels.  Needs an ORIGIN brush - the origin
key is the axis it turns about.  CFuncPlatRot, plats.cpp:515-620.

"rotation" total degrees turned between the top and bottom positions
"height"   travel along Z (negative moves UP, as func_plat)
"speed"    movement speed
64/128     spin about world X / Y instead of Z

`netname` and `fireonopen` are Sven's back-compat aliases for fireonclosed and
fireonopened (sven-coop.fgd:844, :853) and fire on arrival at the top and the
bottom respectively.  hl_c01_a1's elevator drives its own call button through
them, so they are not decoration.
*/
void() func_platrot =
{
    Plat_SpawnCommon(TRUE);
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
// How often tank_think runs.  Named because the slew rate is expressed in
// degrees per SECOND and has to be converted to degrees per step, and because
// the avelocity handed to CSQC is that step divided by the same number.
const float TANK_THINK_IV = 0.05;
// Angle still to travel after the current step, for the tolerance gate.
.float  tank_err_yaw;
.float  tank_err_pitch;
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

    // Sven/HL's yawtolerance / pitchtolerance: the gun will not fire until the
    // barrel has caught up with where the operator is looking.  Without a slew
    // rate these were meaningless (the barrel was always already there); with
    // one they are what stops a slow turret shooting sideways while it swings.
    if (self.yawtolerance > 0 && fabs(self.tank_err_yaw) > self.yawtolerance)
        return;
    if (self.pitchtolerance > 0 && fabs(self.tank_err_pitch) > self.pitchtolerance)
        return;

    float rate = self.firerate;
    if (rate <= 0) rate = 4;
    self.tank_next_fire = time + 1.0 / rate;

    entity p = self.tank_controller;
    // THE BARREL'S ANGLE, NOT THE OPERATOR'S VIEW.  This read p.v_angle, which
    // was wrong before the slew rate existed and is glaring now: tank_think
    // clamps the barrel to yawrange/pitchrange, so on any tank with an arc limit
    // the shots already left the visible arc — you could stand behind the gun,
    // look backwards, and shoot through it.  Aiming down the barrel is also what
    // makes the tolerance gate above mean anything.
    makevectors(self.angles);

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
    self.nextthink = time + TANK_THINK_IV;

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

    float want_yaw   = self.tank_base_angles_y + yaw_off;
    float want_pitch = self.tank_base_angles_x + pitch_off;

    // SLEW, rather than snap.  yawrate / pitchrate are degrees per second and
    // were declared and never read, so every mounted gun in the corpus tracked
    // the operator's crosshair perfectly and instantly — which is not what a
    // heavy weapon on a mount is.  Rate 0 keeps the old snap, so a map that
    // never set the key behaves exactly as it did.
    float dy = anglemod(want_yaw   - self.angles_y + 180) - 180;
    float dp = anglemod(want_pitch - self.angles_x + 180) - 180;

    float maxy = (self.yawrate   > 0) ? self.yawrate   * TANK_THINK_IV : 360;
    float maxp = (self.pitchrate > 0) ? self.pitchrate * TANK_THINK_IV : 360;

    float sy = bound(-maxy, dy, maxy);
    float sp = bound(-maxp, dp, maxp);

    self.angles_y = self.angles_y + sy;
    self.angles_x = self.angles_x + sp;

    // What is LEFT after this step — read by tank_fire's tolerance gate.
    self.tank_err_yaw   = dy - sy;
    self.tank_err_pitch = dp - sp;

    // Hand the motion to CSQC as angular velocity.  cl_brushsync.qc extrapolates
    // any brush shipping a non-zero avelocity between snapshots, so the barrel
    // moves smoothly instead of stepping at this think's 20Hz — and ZEROING it
    // on arrival is not optional: the client integrates blindly, so a stale
    // avelocity sails the barrel past the stop and then snaps it back.
    if (self.tank_err_yaw == 0 && self.tank_err_pitch == 0)
        self.avelocity = '0 0 0';
    else
        self.avelocity = [sp / TANK_THINK_IV, sy / TANK_THINK_IV, 0];

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
"yawrate" "pitchrate"    slew speed in degrees/second (0 = snap instantly)
"yawtolerance" "pitchtolerance"  don't fire until the barrel is this close
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
