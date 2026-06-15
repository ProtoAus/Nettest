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
.string globalname;         // accepted, ignored — env_global is OOS
.string globalstate;        // accepted, ignored
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

// ---------------------------------------------------------------------------
// SUB_KillTargets — find-by-name + remove.  GoldSrc semantics.
// ---------------------------------------------------------------------------
void(string name) SUB_KillTargets =
{
    entity e;
    if (name == "" || name == __NULL__) return;
    e = find(world, targetname, name);
    while (e)
    {
        entity nxt = find(e, targetname, name);
        remove(e);
        e = nxt;
    }
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
// IsMasterTriggered — gate check.  Empty master name passes.  Multi-
// source returns its accumulated AND-gate state.  game_team_master
// checks activator's team.  Unknown classname → permissive (TRUE) so
// mapper typos don't lock the map.
// ---------------------------------------------------------------------------
float(string master_name, entity who) IsMasterTriggered =
{
    if (master_name == "" || master_name == __NULL__)
        return TRUE;
    entity m = find(world, targetname, master_name);
    if (!m)
        return TRUE;       // mapper typo policy

    if (m.classname == "multisource")
        return m.ms_active;

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

