// ============================================================
//  client/cl_muzzlesmoke.qc  -  Muzzle smoke "heat" producer
//
//  Single-producer model: one global file-scope `heat` scalar
//  bumps on every shot and decays exponentially every frame.
//  Heat drives BOTH the puff emission rate AND per-puff
//  thickness through a soft-saturation curve, so:
//
//    - single shot   → one small puff, fades in ~1 s
//    - burst (3rnd)  → visibly thicker, brief plume
//    - sustained     → plume thickens and emit rate climbs,
//                      both saturate (no runaway)
//    - release       → heat decays, emitter goes silent on its own
//
//  Previously every shot spawned a fresh muzzlesmoke_pending chain;
//  spamming m249/auto-glock stacked dozens of chains in parallel
//  and dumped an unbounded cloud.  This rewrite replaces the
//  per-shot entity-chain machinery with a single accumulator.
//
//  Per-puff physics (life, drift, alpha curve, billboard draw) is
//  UNCHANGED from the previous system — only the spawn scheduler
//  is replaced.  MS_SpawnOnePuff is still public because
//  cl_sprays.qc's CSQC_SpawnSpraySmoke calls it directly.
//
//  Pattern reference: shared/weapons/sh_wpn_csgrenades.qc
//  CSQC_SpawnSmokePuff / CSQC_DrawSmokePuff / CSQC_DrawSmokeClouds.
//  Re-uses the same gfx/smoke shader (alpha-blended, vertex-color,
//  sort-transparent — see scripts/effects.shader) so no new
//  textures or shader entries are needed.
// ============================================================

// --- Drifting-puff fields (entities of class "muzzlesmoke") ---
.float  ms_spawn_time;     // cltime when this puff was actually born
.float  ms_life;           // seconds before removal (per-puff jitter on life)
.float  ms_start_size;     // qu half-extent at age=0 (post-taper)
.float  ms_end_size;       // qu half-extent at age=ms_life
.float  ms_phase;          // sin/cos wobble offset
.vector ms_drift;          // qu/sec velocity in WORLD space (up + fwd bias)
.vector ms_colour;         // RGB tint, slight per-puff variance
.vector ms_wind_accum;     // integrated wind displacement since spawn
.float  ms_wind_last;      // cltime of last wind integration step
.entity ms_next;           // list link

entity muzzlesmoke_list;
float  csqc_ms_last_action;   // last wep_action_id we incremented heat for

// --- Heat producer state (file-scope, not entities) ---
//
// `var float` keyword forces mutable storage — bare `float x = 0;`
// at file scope is a constant in fteqcc.
var float ms_heat        = 0;     // current intensity; 0 = idle
var float ms_last_tick   = 0;     // for dt-based decay
var float ms_emit_accum  = 0;     // sub-frame puff scheduling accumulator
var float ms_chain_fwd   = 0;     // muzzle offsets of the most-recently-fired weapon
var float ms_chain_right = 0;
var float ms_chain_down  = 0;
var float ms_chain_side  = 1;
var float ms_has_offsets = 0;     // set on first shot so we know if offsets are valid
// World-space muzzle stashed at the most-recent fire (AtMuzzle/AtWorld).
// Producer's MS_CurrentMuzzle returns this directly so puffs after the
// first one land at the SAME spot as the first one — no camera-relative
// reconstruction error.  Tradeoff: puffs stay at last-fire position
// instead of following the gun as the camera moves between shots, which
// actually matches how real powder smoke behaves (stays where fired).
var vector ms_chain_world_muzzle = '0 0 0';

// Per-puff appearance defaults (cvar overrides via cl_muzzlesmoke_* below).
const float MUZZLESMOKE_DEFAULT_LIFE = 0.5;
const float MUZZLESMOKE_DEFAULT_SIZE = 4;
const float MUZZLESMOKE_DEFAULT_GROW = 4;
const float MUZZLESMOKE_DEFAULT_OPAC = 0.5;

// Heat model defaults.  Each parameter has a `cl_muzzlesmoke_*`
// cvar override that falls back to the const when 0/unset.
//
// HEAT_HALFLIFE — seconds for heat to halve.  0.3 s → heat drops to
// 6% after 1 s of no firing (4 half-lives), so the plume fades out
// in roughly that time.  The actual visible plume can linger a bit
// longer because already-spawned puffs keep aging out.
//
// HEAT_HALF_RATE — heat value at which emit rate hits 50% of max
// AND per-puff thickness hits 50% of bonus.  Smaller value =
// emitter saturates sooner (e.g. pistol single-shots already feel
// thick); larger = pistol stays subtle, only m249/spam saturates.
const float MUZZLESMOKE_HEAT_PER_SHOT  = 1.0;
const float MUZZLESMOKE_HEAT_HALFLIFE  = 0.30;
const float MUZZLESMOKE_HEAT_HALF_RATE = 3.0;
const float MUZZLESMOKE_EMIT_MAX_HZ    = 24;     // puffs/sec at infinite heat
const float MUZZLESMOKE_EMIT_FLOOR     = 0.05;   // heat below this → snap to 0
const float MUZZLESMOKE_THICK_MAX      = 0.7;    // +70% per-puff size at saturation
const float MUZZLESMOKE_LIFE_BONUS     = 0.4;    // +40% per-puff life at saturation

// Per-puff alpha curve. Fast attack (full alpha by t=0.15),
// slow decay (linear from t=0.5 to t=1). Matches real powder
// smoke — quick puff out, lingering tail.
float(float t) MS_FadeCurve =
{
    if (t < 0)    return 0;
    if (t > 1)    return 0;
    if (t < 0.15) return t / 0.15;
    if (t < 0.50) return 1.0;
    return 1.0 - ((t - 0.50) / 0.50);
};

// Pseudo-Perlin wind oscillator — sum of two coprime sinusoids per
// axis, gives a low-octave "breath" without a LUT. World-space qu/sec.
// Cry-of-Fear-style drift: smoke wanders back/forth on the shot axis
// plus a gentle lateral sway and upward breath.
vector() MS_Wind =
{
    float s = cvar("cl_muzzlesmoke_wind_strength");
    if (s <= 0) return '0 0 0';
    float t = cltime;
    return [
        (sin(t * 1.7) * 0.6 + sin(t * 0.9) * 0.4) * s,
        (cos(t * 2.1) * 0.5 + sin(t * 1.3) * 0.5) * s,
        (sin(t * 0.7) * 0.3 + cos(t * 1.1) * 0.2) * s
    ];
};

// Smoothstep — Hermite interpolation for size lerp.
float(float t) MS_Smoothstep =
{
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t * (3 - 2 * t);
};

// Spawns one puff at the given world position and links it onto
// muzzlesmoke_list.  Still public — cl_sprays.qc uses this
// directly for the spray-can burst effect.
// Hard list-length cap so pathological cvars (high emit_max_hz +
// long life) can't grow the entity chain unbounded.  When full, drop
// the tail (oldest puff) before linking the new head — natural FIFO
// eviction without per-frame scans.
const float MUZZLESMOKE_MAX_PUFFS = 128;
float muzzlesmoke_count;

void(vector muzzle, vector vfwd, vector vup, float scale,
     float life, float base_size, float grow,
     float drift_u, float drift_f) MS_SpawnOnePuff =
{
    if (muzzlesmoke_count >= MUZZLESMOKE_MAX_PUFFS)
    {
        // Walk to the tail and unlink it.  List is short by construction
        // (≤MAX), so this is O(MAX) once per excess-shot, not per-frame.
        entity prev = muzzlesmoke_list;
        if (!prev || !prev.ms_next)
        {
            // 0 or 1 entries — shouldn't hit the cap but be defensive:
            // remove the single head if it exists.
            if (prev)
            {
                muzzlesmoke_list = __NULL__;
                remove(prev);
                muzzlesmoke_count = 0;
            }
        }
        else
        {
            while (prev.ms_next.ms_next)
                prev = prev.ms_next;
            entity tail = prev.ms_next;
            prev.ms_next = __NULL__;
            remove(tail);
            muzzlesmoke_count = muzzlesmoke_count - 1;
        }
    }

    entity p = spawn();
    p.classname = "muzzlesmoke";
    setorigin(p, muzzle);
    p.ms_spawn_time = cltime;
    p.ms_life       = life * (0.85 + random() * 0.3);
    p.ms_start_size = base_size * scale * (0.8 + random() * 0.4);
    p.ms_end_size   = p.ms_start_size * grow;
    p.ms_phase      = random() * 6.28;
    p.ms_drift      = vup * drift_u + vfwd * drift_f
                    + [(random() - 0.5) * 2,
                       (random() - 0.5) * 2,
                       random() * 1];
    // Bake current wind into the spawn velocity so each puff inherits
    // a slightly different bias — gives the plume the per-puff scatter
    // CoF-style smoke has even before the per-frame integrator kicks in.
    if (cvar("cl_muzzlesmoke_wind_inherit"))
        p.ms_drift = p.ms_drift + MS_Wind() * 0.25;
    p.ms_colour     = '0.55 0.55 0.55'
                    + '1 1 1' * (random() * 0.15);
    p.ms_wind_accum = '0 0 0';
    p.ms_wind_last  = cltime;
    p.ms_next       = muzzlesmoke_list;
    muzzlesmoke_list = p;
    muzzlesmoke_count = muzzlesmoke_count + 1;
};

// Soft-saturation map: heat → 0..1.  Used by both the emit rate
// (Hz multiplier) and the per-puff thickness/life bonuses.
float(float heat, float half_rate) MS_HeatNorm =
{
    if (heat <= 0) return 0;
    return heat / (heat + half_rate);
};

// Resolve current muzzle position from stashed weapon offsets and
// the live posed viewmodel basis.  The flash sprite samples its
// world position via CSQC_ViewmodelAttachmentWorldPos which poses
// csqc_viewmodel_ent through CSQC_ViewFX_PoseViewmodelForBoneLookup
// first (composing bob/sway/weight/sprint/ADS).  Doing the same
// pose here is what keeps the smoke and the flash co-located.  On
// return v_forward / v_right / v_up are left set to the POSED basis
// — callers (MS_SpawnPuffAtCurrentMuzzle) rely on this for drift.
vector() MS_CurrentMuzzle =
{
    // Return the stashed world muzzle position directly.  Stamped by
    // both per-shot entry points (CSQC_MuzzleSmokeAtMuzzle stores
    // view_pos + camera-relative offsets, CSQC_MuzzleSmokeAtWorld
    // stores world_pos as-is).  Producer's per-tick puffs use the
    // same value the first puff was spawned at, eliminating the
    // "first at muzzle, rest at view origin" symptom from the prior
    // camera-relative reconstruction path.
    return ms_chain_world_muzzle;
};

// Spawn one puff at the current muzzle using the heat-derived
// thickness / life multipliers.  Reads life / size / grow / drift
// cvars internally so each puff picks up live-tuned values.
void(float thick, float life_bonus) MS_SpawnPuffAtCurrentMuzzle =
{
    float life    = cvar("cl_muzzlesmoke_life");
    if (life <= 0) life = MUZZLESMOKE_DEFAULT_LIFE;
    float size    = cvar("cl_muzzlesmoke_size");
    if (size <= 0) size = MUZZLESMOKE_DEFAULT_SIZE;
    float grow    = cvar("cl_muzzlesmoke_grow");
    if (grow <= 0) grow = MUZZLESMOKE_DEFAULT_GROW;
    float drift_u = cvar("cl_muzzlesmoke_drift_up");
    float drift_f = cvar("cl_muzzlesmoke_drift_fwd");

    vector muzzle = MS_CurrentMuzzle();
    MS_SpawnOnePuff(muzzle, v_forward, v_up, thick,
                    life * life_bonus, size, grow, drift_u, drift_f);
};

// Equip-time stash: prime ms_chain_* the moment a weapon is drawn
// so the per-frame producer has the correct muzzle basis BEFORE the
// first shot updates it.  Without this the first puff of a new
// weapon emits from the previous weapon's offsets.
void(float fwd, float right_qu, float down) CSQC_MuzzleSmokeSetOffsets =
{
    ms_chain_fwd   = fwd;
    ms_chain_right = right_qu;
    ms_chain_down  = down;
    ms_chain_side  = cvar("cl_lefthand") ? -1 : 1;
    ms_has_offsets = 1;
};

// Per-shot entry — bumps heat and emits one immediate puff so
// even a single pistol tap shows visible smoke.  Stashes the
// firing weapon's muzzle offsets for the per-frame emitter to
// use until the next shot updates them.  `scale` multiplies the
// per-shot heat bump — snipers pass >1 for thicker plume, shotguns
// pass pellet count so the multi-projectile burst registers as
// proportional smoke.  Pass 1 for the default per-shot bump.
void(float fwd, float right_qu, float down, float action_id, float scale) CSQC_MuzzleSmokeAtMuzzle =
{
    // Default-on fallback so a fresh install / unregistered cvar
    // case still works without the user typing the command.
    float gate = cvar("cl_muzzlesmoke");
    if (gate == 0 && cvar_string("cl_muzzlesmoke") == "")
        gate = 1;
    if (gate == 0)
        return;
    // Stamp offsets BEFORE the dedup check so the per-frame producer
    // always sees fresh values even when the dedup blocks the immediate
    // puff/heat bump (reconcile-replay or same-action retries).
    ms_chain_fwd   = fwd;
    ms_chain_right = right_qu;
    ms_chain_down  = down;
    ms_chain_side  = cvar("cl_lefthand") ? -1 : 1;
    ms_has_offsets = 1;
    // Stash the world muzzle so producer puffs land at the SAME spot
    // the per-shot puff goes (MS_CurrentMuzzle returns this verbatim).
    vector view_pos_ws = (vector)getproperty(VF_ORIGIN);
    vector view_ang_ws = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang_ws);
    ms_chain_world_muzzle = view_pos_ws
                          + v_forward * fwd
                          + v_right   * (right_qu * ms_chain_side)
                          - v_up      * down;

    // Action-ID dedup: one heat bump per shot, no double-spawn
    // under reconcile replay.  Same model as
    // CSQC_SpawnMuzzleFlashSprite.
    if (action_id == csqc_ms_last_action)
        return;
    csqc_ms_last_action = action_id;

    // Bump heat.  Tuneable via cvar; falls back to the const.
    // Per-call `scale` is the weapon-specific multiplier (snipers >1,
    // shotguns = pellet count, others = 1).
    float per_shot = cvar("cl_muzzlesmoke_heat_per_shot");
    if (per_shot <= 0) per_shot = MUZZLESMOKE_HEAT_PER_SHOT;
    if (scale <= 0) scale = 1;
    ms_heat = ms_heat + per_shot * scale;

    // Heat-derived per-puff scaling for the immediate puff.
    // Reads cvars so live-tuning is responsive.
    float half_rate = cvar("cl_muzzlesmoke_heat_half");
    if (half_rate <= 0) half_rate = MUZZLESMOKE_HEAT_HALF_RATE;
    float thick_max = cvar("cl_muzzlesmoke_thick_max");
    if (thick_max <= 0) thick_max = MUZZLESMOKE_THICK_MAX;
    float life_max  = cvar("cl_muzzlesmoke_life_bonus");
    if (life_max <= 0) life_max = MUZZLESMOKE_LIFE_BONUS;

    float norm  = MS_HeatNorm(ms_heat, half_rate);
    float thick = 1 + norm * thick_max;
    float life_bonus = 1 + norm * life_max;

    // Emit ONE puff immediately at the muzzle.  Re-resolves the
    // basis using THIS frame's view so the puff lines up with the
    // muzzle flash that fires alongside.
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    MS_SpawnPuffAtCurrentMuzzle(thick, life_bonus);
};

// World-position entry for weapons sourcing their muzzle from a
// model $attachment.  Converts to the camera-local representation
// CSQC_MuzzleSmokeAtMuzzle expects (cl_lefthand is applied there;
// pass the unmirrored offset).
void(vector world_pos, float action_id, float scale) CSQC_MuzzleSmokeAtWorld =
{
    // Stash the real world position FIRST — AtMuzzle's camera-relative
    // reconstruction is slightly lossy when the view is pitched, but
    // ms_chain_world_muzzle (read by MS_CurrentMuzzle) takes priority
    // and is exact here.
    ms_chain_world_muzzle = world_pos;
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);
    vector rel = world_pos - view_pos;
    float fwd   = rel * v_forward;
    float right = rel * v_right;
    float up    = rel * v_up;
    float side  = cvar("cl_lefthand") ? -1 : 1;
    CSQC_MuzzleSmokeAtMuzzle(fwd, right * side, 0 - up, action_id, scale);
    // AtMuzzle overwrote ms_chain_world_muzzle with the reconstructed
    // value; restore the exact world_pos so the producer uses it.
    ms_chain_world_muzzle = world_pos;
};

// Per-frame heat tick — decays heat, then emits puffs at a rate
// proportional to the heat-normalised intensity.  Called at the
// top of CSQC_DrawMuzzleSmoke so new puffs participate in this
// frame's draw walk.
void() CSQC_TickMuzzleSmokeProducer =
{
    // First-frame guard: on the very first call ms_last_tick=0,
    // so dt would equal cltime (huge).  Stamp + return.
    if (ms_last_tick <= 0)
    {
        ms_last_tick = cltime;
        return;
    }

    float dt = cltime - ms_last_tick;
    ms_last_tick = cltime;
    if (dt <= 0)
        return;        // paused / first frame after stall

    // Exponential decay.  Half-life parameterisation — heat halves
    // every `halflife` seconds: heat *= pow(0.5, dt/halflife).
    // pow() is in DP_QC_SINCOSSQRTPOW which FTE provides.
    float halflife = cvar("cl_muzzlesmoke_heat_halflife");
    if (halflife <= 0) halflife = MUZZLESMOKE_HEAT_HALFLIFE;
    ms_heat = ms_heat * pow(0.5, dt / halflife);

    if (ms_heat < MUZZLESMOKE_EMIT_FLOOR)
    {
        // Below the noise floor — snap to 0 and reset the
        // sub-frame accumulator so the next burst starts clean.
        ms_heat = 0;
        ms_emit_accum = 0;
        return;
    }

    // Nothing to emit from until we know where the gun is.
    if (!ms_has_offsets)
        return;

    // Soft-saturation curve for both rate and per-puff intensity.
    float half_rate = cvar("cl_muzzlesmoke_heat_half");
    if (half_rate <= 0) half_rate = MUZZLESMOKE_HEAT_HALF_RATE;
    float max_hz    = cvar("cl_muzzlesmoke_emit_max_hz");
    if (max_hz <= 0) max_hz = MUZZLESMOKE_EMIT_MAX_HZ;
    float thick_max = cvar("cl_muzzlesmoke_thick_max");
    if (thick_max <= 0) thick_max = MUZZLESMOKE_THICK_MAX;
    float life_max  = cvar("cl_muzzlesmoke_life_bonus");
    if (life_max <= 0) life_max = MUZZLESMOKE_LIFE_BONUS;

    float norm = MS_HeatNorm(ms_heat, half_rate);
    float rate_hz = max_hz * norm;

    // Accumulate fractional puffs so emission rate is independent
    // of framerate (60 fps emits the same Hz as 240 fps).
    ms_emit_accum = ms_emit_accum + rate_hz * dt;

    // Per-puff thickness/life climb with heat — gun "fills up"
    // visibly during sustained fire.
    float thick      = 1 + norm * thick_max;
    float life_bonus = 1 + norm * life_max;

    // Resolve the view basis once for all emissions this frame
    // (all emit from the current muzzle in this frame's facing).
    vector view_ang = (vector)getproperty(VF_ANGLES);
    makevectors(view_ang);

    // Hard cap on per-frame puff spawns to avoid pathological cases
    // (e.g. user typed `cl_muzzlesmoke_emit_max_hz 10000` then held
    // fire — we shouldn't try to spawn 10 000 entities in one frame).
    float spawned = 0;
    while (ms_emit_accum >= 1.0 && spawned < 16)
    {
        MS_SpawnPuffAtCurrentMuzzle(thick, life_bonus);
        ms_emit_accum = ms_emit_accum - 1.0;
        spawned = spawned + 1;
    }
};

// Per-puff draw — only called from the puff walk below after
// `self` has been set to the puff entity.
void() CSQC_DrawMuzzleSmokePuff =
{
    float age = cltime - self.ms_spawn_time;
    float t   = age / self.ms_life;

    float opacity = cvar("cl_muzzlesmoke_opacity");
    if (opacity <= 0) opacity = MUZZLESMOKE_DEFAULT_OPAC;
    float alpha = opacity * MS_FadeCurve(t);
    if (alpha <= 0)
        return;

    float size = self.ms_start_size
               + (self.ms_end_size - self.ms_start_size) * MS_Smoothstep(t);

    // Wobble ramps in over the first ~30% of life so it doesn't
    // scatter the puff at spawn.
    float wobble = t * 3.33;
    if (wobble > 1) wobble = 1;

    // Per-frame wind integration — accumulates a world-space offset on
    // top of the linear ms_drift trajectory.  Re-sampling each draw is
    // intentional (not dt-correct momentum, just visual drift) so the
    // plume responds to live cvar tuning and the oscillator phase.
    if (cvar("cl_muzzlesmoke_wind_continuous"))
    {
        float wdt = cltime - self.ms_wind_last;
        if (wdt > 0)
        {
            // Ramp wind in over puff lifetime so freshly-spawned puffs
            // sit near the muzzle and older puffs drift the most.
            self.ms_wind_accum = self.ms_wind_accum + MS_Wind() * wdt * t;
        }
        self.ms_wind_last = cltime;
    }

    vector pos = self.origin + self.ms_drift * age + self.ms_wind_accum;
    pos_x = pos_x + sin(cltime * 0.9 + self.ms_phase) * 1.5 * wobble;
    pos_y = pos_y + cos(cltime * 0.8 + self.ms_phase) * 1.5 * wobble;

    vector right = v_right * size;
    vector up    = v_up    * size;

    string tex = cvar_string("cl_muzzlesmoke_texture");
    if (tex == "")
        tex = "gfx/smoke";

    R_BeginPolygon(tex, 0, 0);
    R_PolygonVertex(pos - right - up, '0 1 0', self.ms_colour, alpha);
    R_PolygonVertex(pos + right - up, '1 1 0', self.ms_colour, alpha);
    R_PolygonVertex(pos + right + up, '1 0 0', self.ms_colour, alpha);
    R_PolygonVertex(pos - right + up, '0 0 0', self.ms_colour, alpha);
    R_EndPolygon();
};

// Per-frame entry point — called from CSQC_UpdateView before
// renderscene, next to CSQC_DrawMuzzleFlashSprite + CSQC_DrawSmokeClouds.
void() CSQC_DrawMuzzleSmoke =
{
    entity puff;
    entity prev;
    entity next_puff;
    entity old_self;

    // Decay heat + emit new puffs BEFORE the draw walk so they
    // appear in the same frame (no one-frame lag).
    CSQC_TickMuzzleSmokeProducer();

    if (!muzzlesmoke_list)
        return;

    old_self = self;
    makevectors(view_angles);

    puff = muzzlesmoke_list;
    prev = world;
    while (puff)
    {
        next_puff = puff.ms_next;
        if (cltime - puff.ms_spawn_time > puff.ms_life)
        {
            if (prev)
                prev.ms_next = next_puff;
            else
                muzzlesmoke_list = next_puff;
            remove(puff);
            muzzlesmoke_count = muzzlesmoke_count - 1;
            puff = next_puff;
            continue;
        }

        self = puff;
        CSQC_DrawMuzzleSmokePuff();

        prev = puff;
        puff = next_puff;
    }

    self = old_self;
};

// Stop the producer.  Called when the smoke source disconnects
// from the player's gun: weapon switch, reload start, etc.
// Wipes heat so no further puffs emit, but leaves drifting puffs
// alone (they keep fading naturally — the SOURCE went away, not
// the smoke itself).
void() CSQC_MuzzleSmokeStopChain =
{
    ms_heat = 0;
    ms_emit_accum = 0;
    // Intentionally leave ms_has_offsets/ms_chain_* alone — the equip
    // hook re-stamps them with the NEW weapon's offsets, so clearing
    // here would force the first shot of the new weapon to re-derive
    // (it does, but the producer's `if (!ms_has_offsets) return;`
    // guard previously masked stale offsets that no longer matter
    // once we stamp at equip).

    // Reset the action-id dedup so the very next fire after a
    // reload/switch doesn't get spuriously blocked.
    csqc_ms_last_action = 0;
};

// Wipe-all hook — invoked from round restart cleanup so leftover
// puffs from the previous round don't bleed into the new one.
void() CSQC_MuzzleSmokeWipeAll =
{
    entity puff;
    entity next_puff;
    puff = muzzlesmoke_list;
    while (puff)
    {
        next_puff = puff.ms_next;
        remove(puff);
        puff = next_puff;
    }
    muzzlesmoke_list = world;
    muzzlesmoke_count = 0;

    // Reset producer state too — otherwise heat from before the
    // round restart would keep dribbling puffs into the new round.
    ms_heat = 0;
    ms_emit_accum = 0;
    ms_has_offsets = 0;
    csqc_ms_last_action = 0;
};
