//
//  sv_triggers.qc  –  shared trigger infrastructure
//
//  Hosts the cross-entity helpers consumed by every trigger_* and
//  multi*_ entity in the GoldSrc port:
//   - useType constants (USE_OFF / USE_ON / USE_SET / USE_TOGGLE)
//   - shared field declarations (.master, .killtarget, .triggerstate,
//     .globalname, .globalstate, .count, .teamindex)
//   - SUB_UseTargets — full HL semantics (delay, killtarget, useType)
//     wrapping the existing Trigger_UseTargets walker in sv_doors.qc
//   - SUB_DelayedFire — temp-entity scheduler for caller.delay
//   - SUB_KillTargets — find-by-name + remove
//   - IsMasterTriggered — multisource / game_team_master gate check
//   - info_target / info_null stubs
//
//  Compile order in sv_progs.src: this file MUST load AFTER sv_doors.qc
//  because Trigger_UseTargets lives there and SUB_UseTargets calls it.
//

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void(entity caller, entity triggerer) Trigger_UseTargets;   // sv_doors.qc

// ---------------------------------------------------------------------------
// Shared field declarations.  None of these are pre-declared anywhere
// else in the codebase — the BSP entity-block parser drops keys whose
// fields aren't declared, so we MUST list every key the new triggers
// expect from .map / .ent data.
// ---------------------------------------------------------------------------
.string master;
.string killtarget;
.float  triggerstate;       // 0 off, 1 on, 2 toggle (HL convention)
.string globalname;         // HL entity identity across a level transition —
                            // accepted, ignored.  NOT the same key as below,
                            // despite the names: 387 placements in the corpus
                            // and not one of them shares a name with a
                            // globalstate.  See sv_globalstate.qc.
.string globalstate;        // names a row in HL's global state table.  Written
                            // by env_global, read as a gate by multisource and
                            // trigger_auto.  sv_globalstate.qc.
.float  count;              // trigger_counter "Count before activation"
.float  teamindex;          // game_team_master

// ms_active is the AND-gate state on a multisource entity.  Declared
// here so IsMasterTriggered can read it before sv_multisource.qc loads.
.float  ms_active;

// useType pass-through globals — declared authoritatively in sv_doors.qc
// (so its Trigger_UseTargets can reference them).  Re-declared here for
// readability of this file's logic; QC accepts identical re-decls.
float  sub_use_type;
entity sub_use_caller;

// server/sv_monsters.qc compiles far below this file (sv_progs.src :211 against
// :153), so the teardown SUB_KillTargets needs is forward-declared here.  It is
// idempotent and safe on a non-monster: every one of its four steps early-returns
// on an entity that never registered (Monster_ReleaseSquadSlot checks sq_counted,
// Squad_Remove checks Squad_In, Nav_PathSlot_Release checks ai_pathslot, and
// monster_chain_remove sees world on both links).
void(entity m) Monster_Teardown;
// sv_physprop.qc (compile pos 301, this file is 192 — QC forward-declares functions).
// Operates on `self`, like the two call sites it already has in PhysProp_VoidWatchdog.
void() PhysProp_TeardownForRemove;

// ---------------------------------------------------------------------------
// SUB_KillTargets — find-by-name + remove.  GoldSrc semantics.
// ---------------------------------------------------------------------------
// THE TEARDOWN IS LOAD-BEARING, and leaving it out was the cause of two
// "runaway loop error" crashes that looked completely unrelated.
//
// This function predates the monster list and was never brought into line with
// it.  A bare remove() on a monster leaves a FREED EDICT wired into
// monster_chain (server/sv_monsters.qc:161-193): its neighbours keep pointing at
// the slot.  FTE then makes that stick - ED_Free does NOT clear fields (the
// clearing block at engine/qclib/pr_edict.c:198-209 is commented out) and
// ED_Alloc re-issues the slot after only 0.5 s (:129-136), zeroed.  So the next
// monster built on that slot looks pristine, monster_chain_add's guard passes,
// it goes in at the head - and the stale neighbour link now points back at it.
// The list is circular, and the next walk over it never terminates.
//
// It is reached from SUB_UseTargets below, BEFORE Trigger_UseTargets, which is
// how a scripted_sequence carrying a killtarget corrupted the list one frame
// before Script_FindMonster walked it (server/sv_scripted.qc:229-235).  The
// other crash was AI_FindEnemy's sweep (server/sv_ai_core.qc:353-369) hitting
// the same cycle minutes later, from a completely different stack.
//
// The milder version of the same bug is worth knowing because nothing reports
// it: if the recycled slot becomes a NON-monster, the walk silently TRUNCATES
// there and every monster past that point stops being visible to the AI.
//
// Monster_Chain_Verify (server/sv_monsters.qc) is the backstop for whatever
// removal site is found next; this is the one that was actually firing.
// PHYS TEARDOWN IS AS MANDATORY HERE AS THE MONSTER ONE, AND FOR A HARDER REASON.
// killtarget matches on targetname, and every map-placed entity can carry one — so
// this reaches prop_physics (sv_props.qc:363 sets po_fx_enabled), phys_barrel /
// phys_can / phys_files, and any GoldSrc weapon_* that W_RegisterMapWeapon turned
// into an ODE drop (sv_weapons.qc:610-625 keeps the same edict and its targetname).
//
// A bare remove() on one of those that is mid-slide strands its CHAN_PHYSPROP_SCRAPE
// FORCELOOP *permanently*, and unlike every other leak this one is beyond reach of
// the watchdog in sv_physprop.qc: PF_nextent skips freed edicts (pr_bgcmd.c:4179-4181),
// so the sweep never walks the slot. ED_Alloc then re-issues it after 0.5 s
// (qclib/pr_edict.c:120,:134) to an unrelated entity that will never emit on channel 6
// — so nothing will ever replace the sample on that entnum either. The stop has to
// happen HERE, while the edict is still ours.
//
// PhysProp_TeardownForRemove also releases a carrier still holding the entity, which
// is the other half of the same hazard (see its comment: ED_Free does NOT clear
// fields, so Carry_Tick goes on servoing a freed slot with pm_carrying stuck TRUE).
// Both halves self-guard, so this costs a field read on the ordinary case.
void(string name) SUB_KillTargets =
{
    entity e;
    if (name == "" || name == __NULL__) return;
    e = find(world, targetname, name);
    entity saved = self;
    while (e)
    {
        entity nxt = find(e, targetname, name);
        Monster_Teardown(e);
        self = e;
        PhysProp_TeardownForRemove();
        if (e.movetype == MOVETYPE_PHYSICS)
            physics_enable(e, FALSE);   // detach the ODE body before the edict goes
        self = saved;
        remove(e);
        e = nxt;
    }
    self = saved;
};

// ---------------------------------------------------------------------------
// SUB_DelayedFire — temp-entity scheduler that mirrors HL's CBaseDelay.
// Captures the activator + useType + caller's target/killtarget at the
// time of firing so a delayed chain still hits the right list of
// entities even if the caller is removed in the meantime.
// ---------------------------------------------------------------------------
.string delayed_target;       // copied from caller.target at schedule time
.string delayed_killtarget;
.float  delayed_use_type;
.entity delayed_activator;
// .entity delayed_origcaller is declared in sv_doors.qc (which compiles
// first and needs it inside Trigger_UseTargets).  Set below.

void() SUB_DelayedFire_Think =
{
    if (self.delayed_killtarget != "")
        SUB_KillTargets(self.delayed_killtarget);

    // Treat self as the caller — its .target field carries the captured
    // target list and Trigger_UseTargets walks find-by-targetname.
    self.target = self.delayed_target;
    sub_use_type   = self.delayed_use_type;
    Trigger_UseTargets(self, self.delayed_activator);

    remove(self);
};

void(entity caller, entity who, float useType, float delay) SUB_DelayedFire =
{
    entity e = spawn();
    e.classname           = "delayed_use";
    e.delayed_target      = caller.target;
    e.delayed_killtarget  = caller.killtarget;
    e.delayed_use_type    = useType;
    e.delayed_activator   = who;
    e.delayed_origcaller  = caller;
    e.think               = SUB_DelayedFire_Think;
    e.nextthink           = time + delay;
};

// ---------------------------------------------------------------------------
// SUB_UseTargets — full GoldSrc semantics.  Replaces direct
// Trigger_UseTargets calls in the new triggers; existing call sites in
// sv_doors.qc / sv_buttons.qc / sv_breakable.qc / sv_trigger_hurt.qc
// keep using the two-arg Trigger_UseTargets form (which now stamps
// sub_use_caller and defaults sub_use_type to USE_TOGGLE).
// ---------------------------------------------------------------------------
void(entity caller, entity who, float useType) SUB_UseTargets =
{
    if (caller.killtarget != "" && caller.killtarget != __NULL__)
        SUB_KillTargets(caller.killtarget);

    if (caller.delay > 0)
    {
        // Spawn a temp entity that fires after delay seconds with the
        // captured useType + activator.  The caller is free to remove
        // itself without breaking the chain.
        SUB_DelayedFire(caller, who, useType, caller.delay);
        return;
    }

    sub_use_type = useType;
    Trigger_UseTargets(caller, who);
};

// ---------------------------------------------------------------------------
// SV_FireTargetsByName — fire every entity with this targetname, with no
// caller entity involved.  Half-Life's FireTargets(), which is a DIFFERENT
// thing from firing a caller's .target and is what the reserved names below
// need: there is no entity holding "game_playerspawn" in a .target field, the
// GAME fires the name directly (SDK dlls/player.cpp:4120,4124 and
// dlls/multiplay_gamerules.cpp:436,587,599).
//
// Returns how many entities were fired, so a caller can report or assert.
//
// THE EMPTY-NAME GUARD IS LOAD-BEARING, for the same reason it is in
// SUB_KillTargets above: find(world, targetname, "") matches every entity whose
// targetname is unset (engine/common/pr_bgcmd.c:1700-1716), so an unguarded call
// here would fire the entire map.
//
// This body was lifted out of AIDbg_FireTargetThink (sv_ai_debugcmds.qc), which
// had it inline; that harness now calls this, so `sv_debug_firetarget` and the
// shipped emitters exercise exactly the same path — which is what makes proving
// a chain by hand with that cvar mean anything.
// ---------------------------------------------------------------------------
float(string name, entity who, float useType) SV_FireTargetsByName =
{
    if (name == "" || name == __NULL__)
        return 0;

    float n = 0;
    entity e = find(world, targetname, name);
    while (e)
    {
        entity nxt = find(e, targetname, name);   // latched: e.use() may remove e
        if (e.use)
        {
            entity oldself = self;
            entity oldact  = activator;
            float  oldut   = sub_use_type;

            self         = e;
            activator    = who;
            sub_use_type = useType;
            e.use();

            self         = oldself;
            activator    = oldact;
            sub_use_type = oldut;
            n = n + 1;
        }
        e = nxt;
    }
    return n;
};

// ---------------------------------------------------------------------------
// SV_FireReservedName — the Half-Life reserved targetnames.
//
// These are TARGETNAMES the game fires at gameplay moments, not classnames a
// map spawns, and the mod never fired any of them.  On most maps that costs a
// flourish; on Sven's hl_c00 it costs the entire map, because all four of its
// `game_playerspawn` trigger_relays are the ONLY source for their targets and
// one of them starts the tram:
//
//     game_playerspawn -> start_titles1 -> fade_in1(0s), title_manager1(6s),
//                                          train(3s)          <-- the tram
//
// so the player spawned standing in a motionless tram in a dark bay and nothing
// ever happened.  Measured before and after: 9 chain events and 0 multi_manager
// activations before, 182 and 5 after, with the tram accelerating away through
// its path_tracks (300 -> 200 -> 300 -> 350 -> 400) exactly as authored.
//
// 90 placements across the map corpus, 31 of them game_playerspawn across 14
// maps.  USE_TOGGLE matches FireTargets()'s own useType argument.
// ---------------------------------------------------------------------------
// Latch for game_playerjoin, which HL fires on a player's FIRST spawn only
// (dlls/player.cpp:4120, inside the m_fGameHUDInitialized branch) whereas
// game_playerspawn fires on every spawn including respawns.
.float gp_joined_fired;

float(string name, entity who) SV_FireReservedName =
{
    float n = SV_FireTargetsByName(name, who, USE_TOGGLE);
    // Reports n == 0 too, on purpose.  "The emitter ran and this map has no
    // such entity" and "the emitter never ran" look identical from a silent
    // log, and telling them apart is the whole diagnostic value here.
    if (cvar("sv_debug_use"))
        print(sprintf("[reserved] fired \"%s\" for %s -> %g entities\n",
                      name, who.netname, n));
    return n;
};

// Called at the very end of PlayerSpawn, which is as close as this gets to
// UpdateClientData's position in HL — after both equip paths, the map script
// hook and the weapon bind, so a map that equips or arms the player from
// game_playerspawn sees a fully built player.
void(entity plyr) SV_FireSpawnReservedNames =
{
    if (!plyr.gp_joined_fired)
    {
        plyr.gp_joined_fired = TRUE;
        SV_FireReservedName("game_playerjoin", plyr);
    }
    SV_FireReservedName("game_playerspawn", plyr);
};

// ---------------------------------------------------------------------------
// GoldSrc_TriggerStateToUseType — map a mapper-authored `triggerstate` key
// onto our USE_* constants.  These are two DIFFERENT enums and 2/3 are
// transposed between them:
//
//     triggerstate (Sven FGD)      USE_* (sv_doors.qc)
//       0 Off                        USE_OFF    = 0
//       1 On                         USE_ON     = 1
//       3 Set   <-- note             USE_SET    = 2
//       2 Toggle <-- note            USE_TOGGLE = 3
//       4 Kill                       (no equivalent)
//
// Sven's FGD comments the 2/3 transposition as deliberate backwards
// compatibility.  The old code did `triggerstate ? triggerstate : USE_TOGGLE`,
// which passed 1 through correctly by luck and got 2 and 3 backwards.
//
// The `0` case stays USE_TOGGLE on purpose: QC cannot distinguish "key absent"
// from "key present and 0" on a .float, and the FGD default is 2 (Toggle), so
// treating a zero as Toggle matches the far more common unset case.  Nothing
// in the Sven map corpus authors an explicit `triggerstate 0`.
// ---------------------------------------------------------------------------
float(float ts) GoldSrc_TriggerStateToUseType =
{
    if (ts == 1) return USE_ON;
    if (ts == 3) return USE_SET;
    if (ts == 4) return USE_OFF;   // Sven "Kill" — closest we can express
    return USE_TOGGLE;             // 2 (Toggle) and 0/unset
};

// ---------------------------------------------------------------------------
// IsMasterTriggered — gate check.  Empty master name passes.  Multi-
// source returns its accumulated AND-gate state.  game_team_master
// checks activator's team.  Unknown classname → permissive (TRUE) so
// mapper typos don't lock the map.
// ---------------------------------------------------------------------------
float(string master_name, entity who) IsMasterTriggered =
{
    if (master_name == "" || master_name == __NULL__)
        return TRUE;

    // targetname is NOT unique, and real maps exploit that.  In
    // -sp_campaign_portal.bsp a multisource AND a func_door_rotating are
    // both named "WeDoNotGoThere", and a third door masters off that name.
    // find() returns matches in ascending edict order, so a bare find()
    // picks whichever the compiler happened to emit first — and the
    // permissive fallback at the bottom of this function means landing on
    // the wrong one silently reports UNLOCKED, disabling the gate.  Scan
    // the whole chain and prefer a real gate class; only fall back to the
    // first hit when none of the matches is one.
    entity m     = find(world, targetname, master_name);
    entity first = m;
    while (m)
    {
        if (m.classname == "multisource" || m.classname == "game_team_master")
            break;
        m = find(m, targetname, master_name);
    }
    if (!m)
        m = first;
    if (!m)
        return TRUE;       // mapper typo policy

    // CMultiSource::IsTriggered is TWO tests ANDed (buttons.cpp:216-236): every
    // input on, AND the named global ON.  ms_active caches the first; the second
    // has to be live, because the global can be flipped by an env_global on a
    // completely different entity — or on a completely different map — long
    // after this gate last saw an input.
    if (m.classname == "multisource")
        return m.ms_active && GlobalState_GateOpen(m.globalstate);

    if (m.classname == "game_team_master")
    {
        if (m.spawnflags & 2)             // SF_GTM_ANYTEAM
            return TRUE;
        if (!who || who.classname != "player")
            return FALSE;
        float want = (m.teamindex == 0) ? TEAM_BLUE :
                     (m.teamindex == 1) ? TEAM_RED  : -1;
        if (want == -1) return FALSE;
        return (who.player_team == want);
    }

    // Default: any other named entity is treated as ON.
    return TRUE;
};

// ---------------------------------------------------------------------------
// SUB_Remove — generic "remove(self) on next think" callback.
// ---------------------------------------------------------------------------
void() SUB_Remove =
{
    remove(self);
};

// ---------------------------------------------------------------------------
// Trigger_PlayerInBSPBrush — true if the player's hull actually overlaps
// the trigger's brush GEOMETRY (not just its AABB).  Mirrors the
// PM_BoxInTriggerBrush trick used in pmove for trigger_push: temporarily
// flip the trigger to SOLID_BSP, tag both ents with a private dimension
// bit so the tracebox only sees the brush, run a zero-length tracebox at
// the player's origin, then restore.
//
// PM_TRIGGER_PROBE_DIM (= 64) is defined canonically in sh_pmove.qc;
// hardcoded here because sh_pmove.qc compiles after this file in the
// server progs chain.
// ---------------------------------------------------------------------------
const float TRIGGER_BSP_PROBE_DIM = 64;

float(entity player, entity trig) Trigger_PlayerInBSPBrush =
{
    if (!trig.modelindex)
        return TRUE;   // no BSP submodel — caller falls back to AABB

    float saved_solid     = trig.solid;
    float saved_dim_solid = trig.dimension_solid;
    float saved_dim_hit   = player.dimension_hit;

    trig.solid            = SOLID_BSP;
    trig.dimension_solid |= TRIGGER_BSP_PROBE_DIM;
    player.dimension_hit  = TRIGGER_BSP_PROBE_DIM;

    tracebox(player.origin, player.mins, player.maxs, player.origin,
             MOVE_NORMAL, player);

    trig.solid           = saved_solid;
    trig.dimension_solid = saved_dim_solid;
    player.dimension_hit = saved_dim_hit;

    return trace_startsolid && trace_ent == trig;
};

// ---------------------------------------------------------------------------
// Trigger_FireOnOverlap — per-tick AABB scan for stationary touch.
//
// The engine's SOLID_TRIGGER touch test only fires when two entities'
// bboxes change overlap state — i.e. one entity is moving INTO or OUT
// OF the other.  A player who walked onto a small floor trigger and
// then stopped never re-fires .touch.  Same for thin Z-triggers when
// pmove's per-frame interpolation steps over them at high horizontal
// speed.  Calling this helper from a 0.1 s think on the trigger
// catches both cases — it walks the player list, AABB-tests each
// against the trigger's volume (with optional sub-unit inflation
// so floor-flush triggers register at their boundary), and invokes
// the trigger's existing .touch handler for each overlap.  Existing
// cooldown gates inside the touch (.attack_finished / .thurt_next_hit
// / etc.) safely dedup against the engine's own touch fire.
// ---------------------------------------------------------------------------
void(entity volume, vector inflate) Trigger_FireOnOverlap =
{
    if (!volume.touch) return;
    if (!player_chain_head) return;   // no live players → nothing to overlap-test

    vector cmin = volume.absmin - inflate;
    vector cmax = volume.absmax + inflate;

    entity oldself  = self;
    entity oldother = other;

    // Walk the player chain (<=32) instead of find()ing the whole edict list every
    // 0.1s tick — identical set (all connected players), far cheaper on prop-dense
    // maps.  Capture .player_chain_next BEFORE volume.touch() so a touch target that
    // ever removes an entity can't strand the iterator.
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.health > 0)
        {
            vector pmin = p.origin + p.mins;
            vector pmax = p.origin + p.maxs;
            if (pmin_x <= cmax_x && pmax_x >= cmin_x
             && pmin_y <= cmax_y && pmax_y >= cmin_y
             && pmin_z <= cmax_z && pmax_z >= cmin_z)
            {
                self  = volume;
                other = p;
                volume.touch();
            }
        }
        p = nxt;
    }

    self  = oldself;
    other = oldother;
};

// ---------------------------------------------------------------------------
// info_target — point-class anchor for trigger_camera / scripted_sequence
// / multi_manager calls that target a position-only entity.  Empty stub.
// info_null already exists below; both kept here for one-stop home.
// ---------------------------------------------------------------------------
void() info_target = {};

void() info_null =
{
};

void() func_illusionary =
{
    // CFuncIllusionary::Spawn zeroes angles first (bmodels.cpp:232), for the same
    // reason CFuncWall does - see the note in sv_brushsync.qc's func_wall.  A
    // decorative brush never rotates, and a leftover angles key on a GoldSrc submodel
    // with no origin brush relocates it (and its PVS box) about the world origin.
    // 12 placements in the corpus.
    self.angles = '0 0 0';

    // Only route through the replicated-brush (CSQC) pipeline when the mapper set
    // a GoldSrc rendermode that NEEDS translating (additive light rays etc., modes
    // 1-5).  A PLAIN func_illusionary — just `alpha` or pure defaults — renders
    // correctly via the simple direct path; pushing it through the CSQC brush path
    // (built for solid brushes) regressed TRANSLUCENT GoldSrc textures (palette /
    // fullbright artifacts), so keep the proven path for the common case.
    if (self.rendermode > 0)
    {
        // SV_InitReplicatedSolidBrush sets SOLID_BSP + MOVETYPE_PUSH and registers
        // the CSQC SendEntity; override to non-solid AFTER it (the send ships
        // wire_nonsolid from .solid, so CSQC keeps it pass-through) and static.
        SV_InitReplicatedSolidBrush();
        self.solid      = SOLID_NOT;       // illusionary = decorative, no collision
        self.movetype   = MOVETYPE_NONE;   // static (init set MOVETYPE_PUSH)
        self.brush_type = BRUSH_TYPE_STATIC;
    }
    else
    {
        setmodel(self, self.model);
        self.solid = SOLID_NOT;            // proven path: engine honours the .alpha key directly
    }
};

