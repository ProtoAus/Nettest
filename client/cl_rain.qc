// ============================================================
//  client/cl_rain.qc  -  Client-side rain effect
//
//  Spawns N raindrops in a cylindrical column around the viewer:
//      1. trace from sky-height down along RAIN_FALL_VEC to find
//         where the drop will land on the world
//      2. animate the drop's position along that pre-traced
//         segment over RAIN_FALL_SPEED qu/s
//      3. when it reaches the endpoint, stamp a small water-drop
//         decal on the surface that wraps geometry like the
//         scorch / blood decals do (adddecal projection)
//
//  Drops live in a fixed pool of RAIN_MAX slots, each cycling
//  through (idle -> falling -> splashing -> idle).  No per-frame
//  spawn/remove; the only allocation is the precache + the pool
//  arrays.  Per-frame cost is 1 polygon per falling drop and 1
//  adddecal per splashing drop — both negligible.
//
//  Toggle / tune via cvars:
//    cl_rain                  master on/off (default 0)
//    cl_rain_intensity        drop multiplier. 1.0 = 128 simultaneous
//                             drops, 32.0 = the internal 4096-drop cap
//    cl_rain_radius           XY impact radius around the viewer
//    cl_rain_speed            fall speed in qu/s
//    cl_rain_angle_x          fall direction X (0 = straight down)
//    cl_rain_center_impacts   offset starts upwind so impacts stay centred
//    cl_rain_alpha            streak transparency, 0..1
//    cl_rain_width            streak quad width in qu
//    cl_rain_color            RGB vector, e.g. "0.75 0.9 1"
//    cl_rain_streak_texture   texture/shader path for falling streaks
//    cl_rain_splash_texture   texture/shader path for impact decals
//    cl_rain_splash_alpha     impact decal alpha multiplier, 0..1
//    cl_rain_splash_size      impact decal half-size in qu
//    cl_rain_reseed_per_frame max new traced drops per rendered frame
//    cl_rain_stagger          randomise new-drop progress for even rain
//    cl_rain_draw_distance    max streak draw distance, 0 = unlimited
//    cl_rain_fps              rain simulation/update rate, 0 = render fps
//
//  Not currently gated by a func_brush volume — feature lives in a
//  TODO marker below.  The mapper-volume gate is a small extension:
//  on Rain_Restart, replace the unconditional traceline with a
//  pointcontents()-style check against a brush entity flagged as
//  weather, then skip the drop when the spawn point isn't inside it.
// ============================================================

const float  RAIN_MAX             = 4096;
const float  RAIN_INTENSITY_UNIT  = 128;
const float  RAIN_SKY_OFFSET      = 1024;
const float  RAIN_STREAK_LEN      = 64;
const float  RAIN_STREAK_WIDTH    = 1.5;
const float  RAIN_SPLASH_FRAMES     = 13;
const float  RAIN_SPLASH_SIZE     = 4;
// Ground-ring grow + fade duration.  Ring starts at radius 0 and
// expands to its final radius while alpha fades from full to 0 over
// this window.  Independent of the sprite's 13-frame animation so
// the ring can be short-lived even when the sprite is set to a
// slower fps.
const float  RAIN_SPLASH_RING_TIME  = 0.4;
// Ring final radius as a fraction of the splash sprite half-size —
// 0.8 reads as "ring sits inside the sprite's footprint".
const float  RAIN_SPLASH_RING_SCALE = 0.8;
// Minimum surface verticality (rd_normal.z) for the ring to draw.
// cos(45°) ≈ 0.707 — floors and gentle ramps pass; steep ramps,
// walls, and ceilings skip the ring.  The upright sprite still
// renders on all surfaces.
const float  RAIN_SPLASH_RING_MIN_Z = 0.707;
const string RAIN_STREAK_TEX      = "gfx/rain/streak";
const string RAIN_SPLASH_TEX      = "gfx/rain/splash";
const string RAIN_SPLASHRING_TEX  = "gfx/rain/splashring";
const vector RAIN_COLOR           = '1 1 1';

// Engine-particle (cl_weather_engine 1) handles.  Resolved LAZILY on
// first tick because:
//   1. weather.cfg may exec after CSQC's Precache runs (the menu VM's
//      Menu_LoadConfig timing varies by FTE build), and
//   2. FTE's particleeffectnum returns a NEGATIVE slot index even for
//      unregistered effects (see comment in cl_bulletimpact.qc:74-80) —
//      so we MUST validate with particleeffectquery before trusting
//      the handle.  Otherwise pointparticles becomes a silent no-op
//      and the user sees neither engine particles nor the CSQC pool.
float pe_weather_snow;
float pe_weather_snow_bright;  // additive blend variant for cl_snow_fullbright
float pe_weather_rain;
float pe_weather_resolved;     // 1 once a successful lookup completes

string rain_streak_tex_current;
string rain_splash_tex_current;
// Pre-resolved per-frame shader name for each splash animation frame.
// Populated by Rain_ResolveMedia whenever rain_splash_tex_current changes;
// indexed [0..RAIN_SPLASH_FRAMES-1] (frame number - 1).  Avoids the
// sprintf per active splash drop in Rain_DrawSplash that profile showed
// as ~7M opcodes at intensity 32 — biggest single hotspot in rain-on
// frames.
string rain_splash_tex_frame[RAIN_SPLASH_FRAMES];
float  rain_reseed_cursor;
float  rain_next_update_time;
float  rain_update_time;
float  rain_update_now;
vector rain_tick_view_pos;
vector rain_tick_color;
float  rain_tick_radius;
float  rain_tick_speed;
float  rain_tick_angx;
float  rain_tick_angy;
float  rain_tick_center_impacts;
float  rain_tick_width;
float  rain_tick_alpha;
float  rain_tick_splash_size;
float  rain_tick_splash_alpha;
// Splash animation timing — driven by cl_rain_splash_fps each tick so the
// frame cycle and decal lifetime stay in lock-step when fps changes.
float  rain_tick_splash_frame_time;
float  rain_tick_splash_total;
float  rain_tick_reseed_per_frame;
float  rain_tick_stagger;
float  rain_tick_draw_dist2;
float  rain_tick_fps;
// Per-frame resolved length + snow-mode state.  Replaces the use of
// the RAIN_STREAK_LEN constant in Rain_DrawStreak.  Snow mode swaps
// the streak texture for a square (gfx/rain/snow), shrinks the size,
// slows the fall, and gives each drop a per-drop phase offset for
// sinusoidal horizontal wobble.
float  rain_tick_length;
float  rain_tick_snow_mode;
float  rain_tick_snow_drift;
float  rain_tick_snow_fullbright;
float  rain_tick_splash_fullbright;
// Snow-mode shared billboard basis — populated by Rain_ResolveTuning
// once per frame based on the current camera angles, then reused by
// every flake in Rain_DrawStreak instead of re-doing per-flake cross
// products + normalizes against a per-flake eye→drop vector.  For
// tiny white squares the visual is indistinguishable in motion.
//
// Stored as 4 PRE-SUMMED corner offset vectors (already include the
// rain_tick_width × 0.5 scale + the +/- vR ± vU combinations) so the
// per-flake draw is 4 vector additions to cur_pos, vs the prior 2
// scalar multiplies + 8 vector adds/subs.
vector rain_tick_snow_off_BL;   // bottom-left  = -vR - vU
vector rain_tick_snow_off_BR;   // bottom-right = +vR - vU
vector rain_tick_snow_off_TR;   // top-right    = +vR + vU
vector rain_tick_snow_off_TL;   // top-left     = -vR + vU
// cl_snow_simple — when 1, skip even the camera-facing billboard and
// emit world-axis-aligned squares using a cheap append helper that
// skips writing the (constant) UV + RGB fields per vert.  Those
// fields are pre-initialised once at startup and re-initialised on
// transition from rain → snow_simple (rain may have stamped non-white
// RGB into the buffer).
float  rain_tick_snow_simple;
float  rain_was_snow_simple;   // edge-detect for the RGB reset on entry
// Per-drop state arrays.  rd_active values:
//   0 = unused (slot free)
//   1 = falling — between rd_fall_start and rd_fall_start+rd_fall_time
//   2 = splashing — between (rd_splash_end - SPLASH_TIME) and rd_splash_end
//
// NOTE on globals budget: an earlier attempt to wrap these in fteqcc's
// `auto` storage class (which moves the alloc from compile-time globals
// to runtime memalloc) failed — this codebase's fteqcc revision 6202
// (Mar 2022) predates the auto-as-global feature.  The pragmatic
// alternative is that src/qcc.cfg already raises MAX_REGS to 1,048,576
// (1M slots), so the per-drop pools fit at compile time without needing
// auto.  If you upgrade fteqcc and want to free the compile slots,
// prepend `auto` to these declarations.
float  rd_active[RAIN_MAX];
vector rd_start[RAIN_MAX];
vector rd_end[RAIN_MAX];
vector rd_normal[RAIN_MAX];
float  rd_fall_start[RAIN_MAX];
float  rd_fall_time[RAIN_MAX];
float  rd_splash_end[RAIN_MAX];
// Snapshot of rain_tick_splash_total at splash spawn — used so a mid-
// splash cl_rain_splash_fps change doesn't desync the frame index / alpha
// calc for already-active splashes (they finish on their spawn-time
// schedule; the cvar change applies to the next splash).
float  rd_splash_total[RAIN_MAX];
// Per-slot flag: 1 = bullet-water splash (no falling streak, no settle
// streak, sprite+ring only).  Cleared when the slot returns to idle.
float  rd_bullet_splash[RAIN_MAX];

// Live count of slots with rd_active != 0.  Maintained as an invariant
// at every site that mutates rd_active so CSQC_Rain_Tick can skip the
// 4096-slot scan when nothing's alive — including the bullet-water
// splash case (those hijack idle slots into state 2 and bump this counter
// via the +1 in CSQC_Rain_SpawnBulletWaterSplash, so the scan re-engages
// the moment a bullet splash spawns even with weather toggled off).
// Profile baseline showed CSQC_Rain_Tick burning ~60ms self time with
// rain disabled, which is purely the cost of this scan over inactive
// slots; the counter gate eliminates that.
float  rd_total_active;

// Cache of CSQC_FuncRain_HasActive(), refreshed once per CSQC_Rain_Tick
// before the reseed loop.  Rain_Restart fires up to 64 times per frame
// (cl_rain_reseed_per_frame default) and previously walked the 16-slot
// volume table inside HasActive on every call — pulling the check up to
// once-per-tick saves ~100k–137k QC opcodes at intensity 32.
float  rain_volumes_active_cached;

// --- Weather ambient audio (rainloop / snowloop) ---
entity rain_audio_ent;       // dedicated emitter for looped ambient + thunder
float  rain_ambient_state;   // 0=none, 1=rain, 2=snow
float  rain_ambient_volume;  // last vol used (re-trigger on cvar change)
// Dedicated non-zero channel for the looped ambient so stopsound() has
// a specific channel to target. CHAN_AUTO (0) cannot be stopped — each
// call allocates a fresh channel. Thunder still uses CHAN_VOICE on the
// same entity without conflict.
const float CHAN_RAIN_AMBIENT = 8;

// --- Lightning ---
// White skybox prefix the user authored at gfx/env/skywhite{bk,ft,up,dn,lf,rt}.
// During a strike the engine's r_skybox cvar is flipped to this and
// back to the cached original, producing a flicker that lights the
// sky AND every brushface tinted by it without overlaying the player's
// view directly.
const string LIGHTNING_WHITE_SKY = "gfx/env/skywhite";
float  lightning_next_strike;       // cltime at which next strike fires
float  lightning_flash_start;       // cltime at strike instant
float  lightning_flash_end;         // cltime at which the strike's swap pattern ends
float  lightning_sky_state;         // 0 = original sky active, 1 = white sky active
string lightning_orig_sky;          // cached r_skybox prefix at strike start
float  lightning_thunder_at;        // cltime at which the queued thunder plays
float  lightning_thunder_played;    // 1 once the current strike's thunder fired
// Per-drop phase offset for snow-mode horizontal wobble.  Filled at
// Rain_Restart; each drop gets a random phase so flakes don't all
// wobble in unison.  Not read in rain mode.
float  rd_drift_phase[RAIN_MAX];
// Per-drop water-impact flag.  Set in Rain_Restart when the drop's
// path crosses a CONTENT_WATER volume before hitting a solid surface;
// makes Rain_DrawSplash render gfx/rain/watersplash at 2× size
// instead of the default splash decal.
float  rd_water[RAIN_MAX];

// === Trisoup batching buffers ============================================
// Replaces the per-drop R_BeginPolygon / R_PolygonVertex × 4 / R_EndPolygon
// emission for STREAKS and RINGS with a single addtrisoup_simple call per
// material per frame (or per chunk when the buffer fills mid-frame).
// FTE auto-pools same-shader polygons into one scenetris_t draw call
// already, so the GPU side is unchanged — what's saved is the QC→engine
// builtin dispatch overhead, which at intensity 32 was running ~16k
// trips per frame just for streaks.
//
// Splash SPRITES ARE batched by animation-frame bucket (rain_splash_*
// below).  Each drop's splash sprite uses shader path
// "<prefix><spl_frame>" where spl_frame is 1..13; routing each drop's
// quad into a per-frame bucket lets the flush emit one
// addtrisoup_simple per bucket per tick instead of one
// R_BeginPolygon chain per drop.
//
// Layout:
//   - rain_streak_*  : single bucket, cap RAIN_MAX quads (every active
//                      drop can fit; no mid-frame flush-on-fill needed
//                      at any intensity).
//   - rain_ring_*    : single bucket, cap 1024 quads (water-surface
//                      hits only — sized generously since rings are
//                      visually expensive and we want every active
//                      one to render).
//   - rain_splash_*  : 13 buckets of 256 quads each, addressed via
//                      offset math in the flat verts/idx arrays.
//                      256 per bucket is well above the ~RAIN_MAX/13
//                      = 315 steady-state splash population per frame.
const float RAIN_STREAK_MAX_QUADS = RAIN_MAX;
const float RAIN_RING_MAX_QUADS   = 1024;
const float RAIN_SPL_BUCKET_QUADS = 256;

trisoup_simple_vert_t rain_streak_verts[RAIN_MAX * 4];
int                   rain_streak_idx  [RAIN_MAX * 6];
int                   rain_streak_quads;
int                   rain_streak_flags_cur;   // resolved per tick

trisoup_simple_vert_t rain_ring_verts[1024 * 4];
int                   rain_ring_idx  [1024 * 6];
int                   rain_ring_quads;

// Per-animation-frame splash sprite buckets.  Flat verts/idx arrays
// addressed as buckets via `bucket * RAIN_SPL_BUCKET_QUADS * 4`
// (verts) / `* 6` (idx) — same pattern cl_sprays.qc uses.
trisoup_simple_vert_t rain_splash_verts[RAIN_SPLASH_FRAMES * 256 * 4];
int                   rain_splash_idx  [RAIN_SPLASH_FRAMES * 256 * 6];
int                   rain_splash_quads[RAIN_SPLASH_FRAMES];
int                   rain_splash_flags_cur;   // resolved per tick

// Forward decl — Rain_DrawStreak calls Rain_FlushStreaks on overflow
// and is defined earlier in the file than the flush helper.
void() Rain_FlushStreaks;

// Specialised streak-buffer append.  Replaces the generic Rain_WriteQuad
// at the 2 hot call sites in Rain_DrawStreak (snow + rain modes).
// Hard-codes the streak vertex/index buffers and standard quad UVs so
// the function takes fewer arguments (5 vs 9) and avoids pointer-arg
// indirection on every per-vert write.  Profile baseline showed
// Rain_WriteQuad as the snow-case hot spot at 56M opcodes / 230ms —
// trimming arg-copy + indirection saves roughly the 5-10 opcodes of
// per-call frame setup × millions of calls.  The ring + (potential
// future) splash paths still use Rain_WriteQuad — far cooler.
// Pre-initialise the streak buffer's constant fields once at startup:
//   - UVs (0,1)(1,1)(1,0)(0,0) — always the same for snow + rain
//   - RGB (1,1,1) — used by the cheap-snow path so flakes render
//     white without re-stamping the color per flake
//   - Indices for every slot — the pattern (4N, 4N+1, 4N+2, 4N, 4N+2,
//     4N+3) depends only on the slot index, never the contents.  Both
//     append helpers skip the 6 index writes + ibase computation per
//     call by relying on these pre-stamped values.
//
// Rain_AppendStreakQuad still overwrites RGB per call with
// rain_tick_color (rain mode may use a non-white tint).  Snow mode
// always forces rain_tick_color to white anyway so the overwrite is
// a no-op functionally — it's just wasted CPU we want to skip via
// the cheap variant below.
void() Rain_PreInitStreakBuffer =
{
    int i;
    for (i = 0; i < (int)RAIN_STREAK_MAX_QUADS; i = i + 1)
    {
        int vb = i * 4;
        int ib = i * 6;
        rain_streak_verts[vb + 0].st[0] = 0; rain_streak_verts[vb + 0].st[1] = 1;
        rain_streak_verts[vb + 1].st[0] = 1; rain_streak_verts[vb + 1].st[1] = 1;
        rain_streak_verts[vb + 2].st[0] = 1; rain_streak_verts[vb + 2].st[1] = 0;
        rain_streak_verts[vb + 3].st[0] = 0; rain_streak_verts[vb + 3].st[1] = 0;
        rain_streak_verts[vb + 0].rgba[0] = 1; rain_streak_verts[vb + 0].rgba[1] = 1; rain_streak_verts[vb + 0].rgba[2] = 1;
        rain_streak_verts[vb + 1].rgba[0] = 1; rain_streak_verts[vb + 1].rgba[1] = 1; rain_streak_verts[vb + 1].rgba[2] = 1;
        rain_streak_verts[vb + 2].rgba[0] = 1; rain_streak_verts[vb + 2].rgba[1] = 1; rain_streak_verts[vb + 2].rgba[2] = 1;
        rain_streak_verts[vb + 3].rgba[0] = 1; rain_streak_verts[vb + 3].rgba[1] = 1; rain_streak_verts[vb + 3].rgba[2] = 1;
        rain_streak_idx[ib + 0] = vb + 0;
        rain_streak_idx[ib + 1] = vb + 1;
        rain_streak_idx[ib + 2] = vb + 2;
        rain_streak_idx[ib + 3] = vb + 0;
        rain_streak_idx[ib + 4] = vb + 2;
        rain_streak_idx[ib + 5] = vb + 3;
    }

    // Pre-stamp the 13 splash buckets the same way — UVs, RGB(1,1,1),
    // and slot-relative indices.  Per-bucket indices reference the
    // bucket-LOCAL vert offset (slot * 4 + 0..3) so each bucket's
    // index range can be handed to addtrisoup_simple with
    // &rain_splash_verts[bucket_v_base] / &rain_splash_idx[bucket_i_base]
    // — same convention cl_sprays.qc uses.
    int b;
    for (b = 0; b < (int)RAIN_SPLASH_FRAMES; b = b + 1)
    {
        int base_v = b * (int)RAIN_SPL_BUCKET_QUADS * 4;
        int base_i = b * (int)RAIN_SPL_BUCKET_QUADS * 6;
        int s;
        for (s = 0; s < (int)RAIN_SPL_BUCKET_QUADS; s = s + 1)
        {
            int vb = base_v + s * 4;
            int ib = base_i + s * 6;
            int vrel = s * 4;
            rain_splash_verts[vb + 0].st[0] = 0; rain_splash_verts[vb + 0].st[1] = 1;
            rain_splash_verts[vb + 1].st[0] = 1; rain_splash_verts[vb + 1].st[1] = 1;
            rain_splash_verts[vb + 2].st[0] = 1; rain_splash_verts[vb + 2].st[1] = 0;
            rain_splash_verts[vb + 3].st[0] = 0; rain_splash_verts[vb + 3].st[1] = 0;
            rain_splash_verts[vb + 0].rgba[0] = 1; rain_splash_verts[vb + 0].rgba[1] = 1; rain_splash_verts[vb + 0].rgba[2] = 1;
            rain_splash_verts[vb + 1].rgba[0] = 1; rain_splash_verts[vb + 1].rgba[1] = 1; rain_splash_verts[vb + 1].rgba[2] = 1;
            rain_splash_verts[vb + 2].rgba[0] = 1; rain_splash_verts[vb + 2].rgba[1] = 1; rain_splash_verts[vb + 2].rgba[2] = 1;
            rain_splash_verts[vb + 3].rgba[0] = 1; rain_splash_verts[vb + 3].rgba[1] = 1; rain_splash_verts[vb + 3].rgba[2] = 1;
            rain_splash_idx[ib + 0] = vrel + 0;
            rain_splash_idx[ib + 1] = vrel + 1;
            rain_splash_idx[ib + 2] = vrel + 2;
            rain_splash_idx[ib + 3] = vrel + 0;
            rain_splash_idx[ib + 4] = vrel + 2;
            rain_splash_idx[ib + 5] = vrel + 3;
        }
    }
};

// Append a splash sprite quad into the bucket for animation frame
// `bucket` (0..RAIN_SPLASH_FRAMES-1).  UVs and RGB pre-stamped at init;
// the per-call work is xyz × 4 + alpha × 4 — same shape as the cheap
// streak helper.  Drops overflow silently (per-bucket cap 256 quads
// is well above the steady-state ~315/frame at intensity 32, and the
// dropped quads would have been visually small / occluded anyway).
void(int bucket, vector p0, vector p1, vector p2, vector p3, float alpha) Rain_AppendSplashQuad =
{
    if (rain_splash_quads[bucket] >= (int)RAIN_SPL_BUCKET_QUADS)
        return;
    int base_v = bucket * (int)RAIN_SPL_BUCKET_QUADS * 4;
    int vbase  = base_v + rain_splash_quads[bucket] * 4;

    rain_splash_verts[vbase + 0].xyz[0] = p0_x; rain_splash_verts[vbase + 0].xyz[1] = p0_y; rain_splash_verts[vbase + 0].xyz[2] = p0_z;
    rain_splash_verts[vbase + 0].rgba[3] = alpha;
    rain_splash_verts[vbase + 1].xyz[0] = p1_x; rain_splash_verts[vbase + 1].xyz[1] = p1_y; rain_splash_verts[vbase + 1].xyz[2] = p1_z;
    rain_splash_verts[vbase + 1].rgba[3] = alpha;
    rain_splash_verts[vbase + 2].xyz[0] = p2_x; rain_splash_verts[vbase + 2].xyz[1] = p2_y; rain_splash_verts[vbase + 2].xyz[2] = p2_z;
    rain_splash_verts[vbase + 2].rgba[3] = alpha;
    rain_splash_verts[vbase + 3].xyz[0] = p3_x; rain_splash_verts[vbase + 3].xyz[1] = p3_y; rain_splash_verts[vbase + 3].xyz[2] = p3_z;
    rain_splash_verts[vbase + 3].rgba[3] = alpha;

    rain_splash_quads[bucket] = rain_splash_quads[bucket] + 1;
};

// Re-set every vert slot's RGB to (1,1,1).  Called on transition from
// rain → snow_simple so any non-white rgb left behind by rain doesn't
// tint the cheap snow's flakes (the cheap helper deliberately skips
// the per-flake RGB write).  ~12k QC ops one-shot per transition —
// trivial against the per-frame savings the cheap path then yields.
void() Rain_ResetStreakRGB =
{
    int i;
    for (i = 0; i < (int)RAIN_STREAK_MAX_QUADS * 4; i = i + 1)
    {
        rain_streak_verts[i].rgba[0] = 1;
        rain_streak_verts[i].rgba[1] = 1;
        rain_streak_verts[i].rgba[2] = 1;
    }
};

// Cheapest possible streak append — only writes xyz + alpha + indices.
// UVs and RGB are pre-initialised at startup and never touched here.
// Used by snow_simple mode where every flake is a white square.
// Saves ~20 QC opcodes per flake vs Rain_AppendStreakQuad.
void(vector p0, vector p1, vector p2, vector p3, float alpha) Rain_AppendStreakQuadCheap =
{
    if (rain_streak_quads >= (int)RAIN_STREAK_MAX_QUADS)
        Rain_FlushStreaks();
    int vbase = rain_streak_quads * 4;

    // Indices pre-stamped by Rain_PreInitStreakBuffer; UVs and RGB
    // pre-stamped too.  Per-flake work is xyz × 4 + alpha × 4 only.
    rain_streak_verts[vbase + 0].xyz[0] = p0_x; rain_streak_verts[vbase + 0].xyz[1] = p0_y; rain_streak_verts[vbase + 0].xyz[2] = p0_z;
    rain_streak_verts[vbase + 0].rgba[3] = alpha;
    rain_streak_verts[vbase + 1].xyz[0] = p1_x; rain_streak_verts[vbase + 1].xyz[1] = p1_y; rain_streak_verts[vbase + 1].xyz[2] = p1_z;
    rain_streak_verts[vbase + 1].rgba[3] = alpha;
    rain_streak_verts[vbase + 2].xyz[0] = p2_x; rain_streak_verts[vbase + 2].xyz[1] = p2_y; rain_streak_verts[vbase + 2].xyz[2] = p2_z;
    rain_streak_verts[vbase + 2].rgba[3] = alpha;
    rain_streak_verts[vbase + 3].xyz[0] = p3_x; rain_streak_verts[vbase + 3].xyz[1] = p3_y; rain_streak_verts[vbase + 3].xyz[2] = p3_z;
    rain_streak_verts[vbase + 3].rgba[3] = alpha;

    rain_streak_quads = rain_streak_quads + 1;
};

void(vector p0, vector p1, vector p2, vector p3, float alpha) Rain_AppendStreakQuad =
{
    if (rain_streak_quads >= (int)RAIN_STREAK_MAX_QUADS)
        Rain_FlushStreaks();
    int vbase = rain_streak_quads * 4;

    // Indices pre-stamped by Rain_PreInitStreakBuffer (slot-relative
    // pattern is deterministic).  UVs ALSO pre-stamped — we still
    // overwrite RGB per call because rain mode can tint via
    // cl_rain_color.  Snow mode forces white, so the writes are
    // no-op-functionally; cheap variant skips them entirely.
    rain_streak_verts[vbase + 0].xyz[0] = p0_x; rain_streak_verts[vbase + 0].xyz[1] = p0_y; rain_streak_verts[vbase + 0].xyz[2] = p0_z;
    rain_streak_verts[vbase + 0].rgba[0] = rain_tick_color_x; rain_streak_verts[vbase + 0].rgba[1] = rain_tick_color_y; rain_streak_verts[vbase + 0].rgba[2] = rain_tick_color_z; rain_streak_verts[vbase + 0].rgba[3] = alpha;

    rain_streak_verts[vbase + 1].xyz[0] = p1_x; rain_streak_verts[vbase + 1].xyz[1] = p1_y; rain_streak_verts[vbase + 1].xyz[2] = p1_z;
    rain_streak_verts[vbase + 1].rgba[0] = rain_tick_color_x; rain_streak_verts[vbase + 1].rgba[1] = rain_tick_color_y; rain_streak_verts[vbase + 1].rgba[2] = rain_tick_color_z; rain_streak_verts[vbase + 1].rgba[3] = alpha;

    rain_streak_verts[vbase + 2].xyz[0] = p2_x; rain_streak_verts[vbase + 2].xyz[1] = p2_y; rain_streak_verts[vbase + 2].xyz[2] = p2_z;
    rain_streak_verts[vbase + 2].rgba[0] = rain_tick_color_x; rain_streak_verts[vbase + 2].rgba[1] = rain_tick_color_y; rain_streak_verts[vbase + 2].rgba[2] = rain_tick_color_z; rain_streak_verts[vbase + 2].rgba[3] = alpha;

    rain_streak_verts[vbase + 3].xyz[0] = p3_x; rain_streak_verts[vbase + 3].xyz[1] = p3_y; rain_streak_verts[vbase + 3].xyz[2] = p3_z;
    rain_streak_verts[vbase + 3].rgba[0] = rain_tick_color_x; rain_streak_verts[vbase + 3].rgba[1] = rain_tick_color_y; rain_streak_verts[vbase + 3].rgba[2] = rain_tick_color_z; rain_streak_verts[vbase + 3].rgba[3] = alpha;

    rain_streak_quads = rain_streak_quads + 1;
};

// Write one quad (4 verts, 6 indices) into the given buffer at the
// supplied slot.  Indices are RELATIVE to the buffer base so callers
// can pass &buf[bucket_base] to addtrisoup_simple — same convention
// cl_sprays.qc uses to support multi-bucket buffers.
void(int slot, vector p0, vector p1, vector p2, vector p3,
     vector col, float alpha,
     trisoup_simple_vert_t *verts, int *idx) Rain_WriteQuad =
{
    int vbase = slot * 4;
    int ibase = slot * 6;

    verts[vbase + 0].xyz[0] = p0_x; verts[vbase + 0].xyz[1] = p0_y; verts[vbase + 0].xyz[2] = p0_z;
    verts[vbase + 0].st[0]  = 0;    verts[vbase + 0].st[1]  = 1;
    verts[vbase + 0].rgba[0] = col_x; verts[vbase + 0].rgba[1] = col_y; verts[vbase + 0].rgba[2] = col_z; verts[vbase + 0].rgba[3] = alpha;

    verts[vbase + 1].xyz[0] = p1_x; verts[vbase + 1].xyz[1] = p1_y; verts[vbase + 1].xyz[2] = p1_z;
    verts[vbase + 1].st[0]  = 1;    verts[vbase + 1].st[1]  = 1;
    verts[vbase + 1].rgba[0] = col_x; verts[vbase + 1].rgba[1] = col_y; verts[vbase + 1].rgba[2] = col_z; verts[vbase + 1].rgba[3] = alpha;

    verts[vbase + 2].xyz[0] = p2_x; verts[vbase + 2].xyz[1] = p2_y; verts[vbase + 2].xyz[2] = p2_z;
    verts[vbase + 2].st[0]  = 1;    verts[vbase + 2].st[1]  = 0;
    verts[vbase + 2].rgba[0] = col_x; verts[vbase + 2].rgba[1] = col_y; verts[vbase + 2].rgba[2] = col_z; verts[vbase + 2].rgba[3] = alpha;

    verts[vbase + 3].xyz[0] = p3_x; verts[vbase + 3].xyz[1] = p3_y; verts[vbase + 3].xyz[2] = p3_z;
    verts[vbase + 3].st[0]  = 0;    verts[vbase + 3].st[1]  = 0;
    verts[vbase + 3].rgba[0] = col_x; verts[vbase + 3].rgba[1] = col_y; verts[vbase + 3].rgba[2] = col_z; verts[vbase + 3].rgba[3] = alpha;

    idx[ibase + 0] = vbase + 0;
    idx[ibase + 1] = vbase + 1;
    idx[ibase + 2] = vbase + 2;
    idx[ibase + 3] = vbase + 0;
    idx[ibase + 4] = vbase + 2;
    idx[ibase + 5] = vbase + 3;
};

// --- func_rain volume table (filled by CSQC_FuncRain_Update) ------
// Each slot tracks one networked func_rain entity's bbox + active
// state.  When any slot is active, Rain_Restart picks spawn XYs
// inside one of the volumes instead of the default cylinder around
// the viewer.
const float CL_RAIN_VOLUME_MAX = 16;
float  cl_rain_vol_used[CL_RAIN_VOLUME_MAX];     // 1 if slot holds a known func_rain
float  cl_rain_vol_active[CL_RAIN_VOLUME_MAX];   // toggle state from server
float  cl_rain_vol_entnum[CL_RAIN_VOLUME_MAX];   // CSQC entnum for re-find
vector cl_rain_vol_mins[CL_RAIN_VOLUME_MAX];
vector cl_rain_vol_maxs[CL_RAIN_VOLUME_MAX];

float() CSQC_FuncRain_HasActive =
{
    float i;
    for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
        if (cl_rain_vol_used[i] && cl_rain_vol_active[i])
            return 1;
    return 0;
};

// Pick a random active volume + random XY inside it.  Caller wraps
// the resulting (x, y) with a sky-Z to derive the drop start point.
// Returns 1 + writes to fr_pick_* on success.
vector fr_pick_xy;
vector fr_pick_mins;
vector fr_pick_maxs;
float() CSQC_FuncRain_PickVolume =
{
    // Area-weighted volume pick.  Sum XY footprint of every active
    // volume, draw a random value in [0, total), then walk the list
    // accumulating until we cross the threshold.  Result: a 1000x1000
    // volume gets 100x the drop spawns of a 100x100 one — rain stays
    // visually uniform across the world, large outdoor regions don't
    // appear weirdly sparse just because they share the slot count
    // with a small alcove.
    //
    // Zero-area degenerate volumes (mins == maxs on x or y) are
    // skipped during accumulation so they can't bias the pick toward
    // themselves with zero contribution.
    float i;
    float total_area = 0;
    for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
    {
        if (cl_rain_vol_used[i] && cl_rain_vol_active[i])
        {
            float dx = cl_rain_vol_maxs[i].x - cl_rain_vol_mins[i].x;
            float dy = cl_rain_vol_maxs[i].y - cl_rain_vol_mins[i].y;
            float a = dx * dy;
            if (a > 0)
                total_area = total_area + a;
        }
    }
    if (total_area <= 0)
        return 0;

    float roll = random() * total_area;
    float pick = -1;
    float accum = 0;
    for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
    {
        if (cl_rain_vol_used[i] && cl_rain_vol_active[i])
        {
            float dx = cl_rain_vol_maxs[i].x - cl_rain_vol_mins[i].x;
            float dy = cl_rain_vol_maxs[i].y - cl_rain_vol_mins[i].y;
            float a = dx * dy;
            if (a <= 0)
                continue;
            accum = accum + a;
            if (roll < accum)
            {
                pick = i;
                break;
            }
        }
    }
    if (pick < 0)
        return 0;

    fr_pick_mins = cl_rain_vol_mins[pick];
    fr_pick_maxs = cl_rain_vol_maxs[pick];
    fr_pick_xy_x = fr_pick_mins_x + random() * (fr_pick_maxs_x - fr_pick_mins_x);
    fr_pick_xy_y = fr_pick_mins_y + random() * (fr_pick_maxs_y - fr_pick_mins_y);
    fr_pick_xy_z = fr_pick_maxs_z;   // top of volume = drop start Z
    return 1;
};

void(float isnew) CSQC_FuncRain_Update =
{
    vector mins, maxs;
    mins_x = readcoord(); mins_y = readcoord(); mins_z = readcoord();
    maxs_x = readcoord(); maxs_y = readcoord(); maxs_z = readcoord();
    float active = readbyte();

    // Locate this entity's slot (by entnum) or grab a free one.
    float i, slot = -1;
    for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
    {
        if (cl_rain_vol_used[i] && cl_rain_vol_entnum[i] == self.entnum)
        {
            slot = i;
            break;
        }
    }
    if (slot < 0)
    {
        for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
        {
            if (!cl_rain_vol_used[i])
            {
                slot = i;
                break;
            }
        }
    }
    if (slot < 0)
        return;   // table full, drop silently

    cl_rain_vol_used[slot]   = 1;
    cl_rain_vol_entnum[slot] = self.entnum;
    cl_rain_vol_mins[slot]   = mins;
    cl_rain_vol_maxs[slot]   = maxs;
    cl_rain_vol_active[slot] = active;

    // Make the CSQC entity itself non-solid + invisible — only its
    // bbox info matters, the brush model itself isn't rendered.
    self.classname = "csqc_func_rain";
    self.solid     = SOLID_NOT;
    self.drawmask  = 0;
};

void() CSQC_FuncRain_Remove =
{
    float i;
    for (i = 0; i < CL_RAIN_VOLUME_MAX; i = i + 1)
    {
        if (cl_rain_vol_used[i] && cl_rain_vol_entnum[i] == self.entnum)
        {
            cl_rain_vol_used[i]   = 0;
            cl_rain_vol_active[i] = 0;
            cl_rain_vol_entnum[i] = 0;
            return;
        }
    }
};

void() CSQC_Rain_Precache =
{
    precache_pic(RAIN_STREAK_TEX);
    // cl_rain_splash_texture is a path PREFIX — the splash animator
    // cycles through <prefix>1..<prefix>N at rain_tick_splash_frame_time
    // each (driven by cl_rain_splash_fps).
    float fi;
    for (fi = 0; fi < RAIN_SPLASH_FRAMES; fi = fi + 1)
        rain_splash_tex_frame[fi] = precache_pic(sprintf("%s%g", RAIN_SPLASH_TEX, fi + 1));
    precache_pic(RAIN_SPLASHRING_TEX);
    rain_streak_tex_current = RAIN_STREAK_TEX;
    rain_splash_tex_current = RAIN_SPLASH_TEX;

    // Weather ambient loops + thunder one-shot.
    precache_sound("sounds/rain/rainloop.wav");
    precache_sound("sounds/rain/snowloop.wav");
    precache_sound("sounds/rain/thunder.wav");

    // Pre-init the streak trisoup buffer's constant fields (UVs +
    // white RGB) so the cheap snow-simple append path can skip
    // re-stamping them per flake.
    Rain_PreInitStreakBuffer();

    // NOTE: engine-particle handles (pe_weather_snow / pe_weather_rain)
    // resolve LAZILY on first tick — particleeffectnum here would
    // return a negative slot even when the effect isn't registered,
    // and we can't rely on weather.cfg having loaded yet.  See
    // Rain_EngineActive().
};

void() CSQC_Rain_WipeAll =
{
    float i;
    for (i = 0; i < RAIN_MAX; i = i + 1)
    {
        rd_active[i] = 0;
        rd_bullet_splash[i] = 0;
    }
    rd_total_active = 0;
    rain_reseed_cursor = 0;
    rain_next_update_time = 0;
    rain_update_time = 0;
};

// Inline shader registered when cl_snow_texture is empty (or missing
// on disk) — backed by FTE's built-in $whiteimage so the snow always
// has a visible white square to render instead of going invisible or
// magenta.  rgbGen/alphaGen vertex preserves per-vertex tint + alpha.
const string SNOW_WHITE_SHADER = "csqc_snow_white";
float snow_white_registered;

void() Rain_RegisterSnowWhite =
{
    if (snow_white_registered) return;
    shaderforname(SNOW_WHITE_SHADER,
        "{\n"
        "    nopicmip\n"
        "    cull none\n"
        "    {\n"
        "        map $whiteimage\n"
        "        rgbGen vertex\n"
        "        alphaGen vertex\n"
        "        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n"
        "    }\n"
        "}\n");
    snow_white_registered = 1;
};

void() Rain_ResolveMedia =
{
    string streak_tex;
    if (cvar("cl_snow"))
    {
        // Snow mode reads its own texture cvar.  Empty → register a
        // $whiteimage-backed shader so the flake renders as a plain
        // white square instead of vanishing.  Default cvar value is
        // gfx/rain/snow, served by the shader entry in
        // scripts/effects.shader.
        streak_tex = cvar_string("cl_snow_texture");
        if (streak_tex == "")
        {
            Rain_RegisterSnowWhite();
            streak_tex = SNOW_WHITE_SHADER;
        }
    }
    else
    {
        streak_tex = cvar_string("cl_rain_streak_texture");
        if (streak_tex == "")
            streak_tex = RAIN_STREAK_TEX;
    }

    string splash_tex = cvar_string("cl_rain_splash_texture");
    if (splash_tex == "")
        splash_tex = RAIN_SPLASH_TEX;

    if (streak_tex != rain_streak_tex_current)
    {
        precache_pic(streak_tex);
        rain_streak_tex_current = streak_tex;
    }
    if (splash_tex != rain_splash_tex_current)
    {
        // Precache all N animation frames whenever the prefix changes
        // and cache the persistent shader-name strings so the per-drop
        // splash draw doesn't sprintf every frame.
        float pi;
        for (pi = 0; pi < RAIN_SPLASH_FRAMES; pi = pi + 1)
            rain_splash_tex_frame[pi] = precache_pic(sprintf("%s%g", splash_tex, pi + 1));
        rain_splash_tex_current = splash_tex;
    }
};

void() Rain_ResolveTuning =
{
    rain_tick_view_pos = (vector)getproperty(VF_ORIGIN);

    rain_tick_radius = cvar("cl_rain_radius");
    if (rain_tick_radius <= 0)
        rain_tick_radius = 1024;

    rain_tick_speed = cvar("cl_rain_speed");
    if (rain_tick_speed <= 0)
        rain_tick_speed = 800;

    rain_tick_angx = cvar("cl_rain_angle_x");
    rain_tick_angy = cvar("cl_rain_angle_y");
    rain_tick_center_impacts = cvar("cl_rain_center_impacts");

    rain_tick_width = cvar("cl_rain_width");
    if (rain_tick_width <= 0)
        rain_tick_width = RAIN_STREAK_WIDTH;
    rain_tick_width = bound(0.1, rain_tick_width, 16);

    rain_tick_alpha = bound(0, cvar("cl_rain_alpha"), 1);

    rain_tick_splash_size = cvar("cl_rain_splash_size");
    if (rain_tick_splash_size <= 0)
        rain_tick_splash_size = RAIN_SPLASH_SIZE;
    rain_tick_splash_size = bound(0.5, rain_tick_splash_size, 32);

    rain_tick_splash_alpha = bound(0, cvar("cl_rain_splash_alpha"), 1);

    // cl_rain_splash_fps drives both the per-frame cycle rate and the total
    // splash lifetime (frames × frame_time).  Bound to a sane range so
    // pathological values can't stall (≈0fps) or strobe (>120fps).
    float spl_fps = cvar("cl_rain_splash_fps");
    if (spl_fps <= 0) spl_fps = 12.5;
    spl_fps = bound(1, spl_fps, 120);
    rain_tick_splash_frame_time = 1.0 / spl_fps;
    rain_tick_splash_total      = RAIN_SPLASH_FRAMES * rain_tick_splash_frame_time;

    // Splash fullbright (additive blend) — same semantics as snow.
    rain_tick_splash_fullbright = cvar("cl_rain_splash_fullbright") != 0;

    rain_tick_reseed_per_frame = cvar("cl_rain_reseed_per_frame");
    if (rain_tick_reseed_per_frame <= 0)
        rain_tick_reseed_per_frame = 64;
    rain_tick_reseed_per_frame = bound(1, rain_tick_reseed_per_frame, RAIN_MAX);

    rain_tick_stagger = cvar("cl_rain_stagger");

    float draw_dist = cvar("cl_rain_draw_distance");
    if (draw_dist <= 0)
        rain_tick_draw_dist2 = 0;
    else
        rain_tick_draw_dist2 = draw_dist * draw_dist;

    rain_tick_fps = cvar("cl_rain_fps");
    if (rain_tick_fps < 0)
        rain_tick_fps = 0;
    if (rain_tick_fps > 240)
        rain_tick_fps = 240;

    // cl_rain_color "" → white ('1 1 1'), which is a 1.0× multiply on
    // the streak/splash/decal vertex colors and adddecal rgb — i.e. no
    // tint applied.  Set non-white to mood-tint the weather.
    string s = cvar_string("cl_rain_color");
    if (s == "")
        rain_tick_color = RAIN_COLOR;  // identity multiplier, no tint
    else
        rain_tick_color = stov(s);

    rain_tick_color_x = bound(0, rain_tick_color_x, 4);
    rain_tick_color_y = bound(0, rain_tick_color_y, 4);
    rain_tick_color_z = bound(0, rain_tick_color_z, 4);

    // Streak length (was hardcoded RAIN_STREAK_LEN = 64).  In snow
    // mode this becomes the square flake's edge length, so apply a
    // 0.1× scale and clamp to a tighter range — a 64qu square flake
    // looks like a wallpaper sheet floating past the camera.
    float user_len = cvar("cl_rain_length");
    if (user_len <= 0)
        user_len = RAIN_STREAK_LEN;
    rain_tick_length = bound(8, user_len, 256);

    rain_tick_snow_mode = cvar("cl_snow") != 0;
    if (rain_tick_snow_mode)
    {
        // Snow defaults to white regardless of cl_rain_color — flake
        // tint reads as material, not a "blue snow" worldspawn mood.
        // User can still override per-snow with cl_snow_color if
        // ever exposed; today the rain color cvar is the only knob
        // and overriding it for snow keeps the rest of the rain mode
        // settings untouched.
        rain_tick_color = '1 1 1';
        // Snow falls slower than rain so the drift wobble has time to
        // read as deliberate motion instead of jitter.  cl_snow_speed
        // is now fully independent of cl_rain_speed: when set use it
        // directly, when unset use a fixed default (120 qu/s — roughly
        // 0.15× the rain default but as a literal so changing rain
        // speed doesn't drag snow speed with it).
        float ss = cvar("cl_snow_speed");
        if (ss > 0)
            rain_tick_speed = ss;
        else
            rain_tick_speed = 120;

        // Flake half-edge from cl_snow_width (independent of rain
        // streak width); fall back to cl_rain_width when unset/<=0.
        float sw = cvar("cl_snow_width");
        if (sw > 0)
            rain_tick_width = bound(0.1, sw, 32);

        // Flake alpha override; fall back to cl_rain_alpha when <=0.
        float sa = cvar("cl_snow_alpha");
        if (sa > 0)
            rain_tick_alpha = bound(0, sa, 1);

        // cl_snow_drift = peak horizontal wobble in qu (per axis).
        // Bound to 4096 — practically unlimited for any sane setup,
        // but the cap prevents pathological cvar values from making
        // flakes teleport across the entire map between renders.
        // Previous 200qu cap was way too tight (user reported "9000
        // does nothing" — the cap silently swallowed it).
        rain_tick_snow_drift = cvar("cl_snow_drift");
        if (rain_tick_snow_drift < 0)
            rain_tick_snow_drift = 0;
        rain_tick_snow_drift = bound(0, rain_tick_snow_drift, 4096);

        rain_tick_snow_fullbright = cvar("cl_snow_fullbright") != 0;

        // cl_snow_simple — world-aligned squares + cheap append path
        // (skips per-flake UV/RGB writes, relying on the pre-init
        // values).  Transition from non-simple to simple resets the
        // RGB column so any rain-mode tint doesn't bleed through.
        rain_tick_snow_simple = cvar("cl_snow_simple") != 0;
        if (rain_tick_snow_simple && !rain_was_snow_simple)
            Rain_ResetStreakRGB();
        rain_was_snow_simple = rain_tick_snow_simple;

        // Per-frame shared billboard basis collapsed into 4 corner
        // offsets so the per-flake draw is 4 vector ADDS instead of
        // 2 multiplies + 8 add/subs.
        float half = rain_tick_width * 0.5;
        if (rain_tick_snow_simple)
        {
            // World-axis-aligned square — flake faces world +Y by
            // construction (cheapest path, no view tracking).
            rain_tick_snow_off_BL = [0 - half, 0, 0 - half];
            rain_tick_snow_off_BR = [    half, 0, 0 - half];
            rain_tick_snow_off_TR = [    half, 0,     half];
            rain_tick_snow_off_TL = [0 - half, 0,     half];
        }
        else
        {
            // Camera-facing — build the basis once from view angles.
            makevectors((vector)getproperty(VF_ANGLES));
            vector cam_fwd = v_forward;
            vector up_ref  = '0 0 1';
            if (fabs(cam_fwd_z) > 0.95) up_ref = '0 1 0';
            vector r_axis = normalize(crossproduct(cam_fwd, up_ref));
            vector u_axis = normalize(crossproduct(r_axis, cam_fwd));
            vector vR = r_axis * half;
            vector vU = u_axis * half;
            rain_tick_snow_off_BL = (0 - vR) + (0 - vU);
            rain_tick_snow_off_BR =      vR  + (0 - vU);
            rain_tick_snow_off_TR =      vR  +      vU;
            rain_tick_snow_off_TL = (0 - vR) +      vU;
        }
    }
    else
    {
        rain_tick_snow_drift = 0;
        rain_tick_snow_fullbright = 0;
        rain_tick_snow_simple = 0;
        rain_was_snow_simple = 0;
    }

    // Cache per-frame batching flags so the flush call doesn't need to
    // re-derive them.  Snow streaks can be additive when fullbright is
    // set; rain streaks are always plain alpha.  Splash sprites use
    // DRAWFLAG_TWOSIDED (1024) plus optional ADD (1) for fullbright.
    rain_streak_flags_cur = rain_tick_snow_mode
        ? (rain_tick_snow_fullbright ? 1 : 0)
        : 0;
    rain_splash_flags_cur = 1024 | (rain_tick_splash_fullbright ? 1 : 0);
};

// Pick a fresh sky-anchor XY around the viewer, trace down, store
// the resolved segment in slot `i`.  Sets rd_active to 1 (falling)
// on success, leaves it 0 (idle) if the trace finds no usable
// surface (sky pit, void).
void(float i) Rain_Restart =
{
    // Rain_Restart is only called on idle slots (rd_active==0) from
    // CSQC_Rain_Tick's reseed loop, so we only need to count up when
    // it successfully promotes to state 1 below.  Every code path that
    // returns early without setting rd_active=1 leaves the slot
    // counter untouched.
    // Clear any leftover bullet-water flag so the slot's new rain
    // drop renders its falling/settle streaks correctly.
    rd_bullet_splash[i] = 0;
    // Fall direction in world space: (angle_x, angle_y, -1) normalised.
    // Tilt values bias the streak horizontally so rain reads as wind-
    // blown rather than straight down.  Both axes independently
    // tunable via cl_rain_angle_x / cl_rain_angle_y.
    vector dir = normalize([rain_tick_angx, rain_tick_angy, -1]);
    vector start;

    // If any mapper-placed func_rain volumes are active, pick a spawn
    // XY inside one of them instead of the default viewer-centred
    // cylinder.  Volume top = drop start Z.  Falls back to the
    // cylinder when no volumes exist (single-zone vs map-driven
    // weather coexist cleanly via this gate).
    float use_volume = rain_volumes_active_cached && CSQC_FuncRain_PickVolume();
    if (use_volume)
    {
        start = fr_pick_xy;       // already includes maxs_z as start Z
    }
    else
    {
        // sqrt(random()) gives a uniform XY distribution across the disc
        // — without it, drops cluster at the centre because random() is
        // a linear radius pick.
        float theta = random() * 6.2831853;
        float r     = sqrt(random()) * rain_tick_radius;
        vector impact_center = [rain_tick_view_pos_x + cos(theta) * r,
                                rain_tick_view_pos_y + sin(theta) * r,
                                rain_tick_view_pos_z];

        if (rain_tick_center_impacts && dir_z < -0.001)
        {
            // The rain falls diagonally, so a sky-centred spawn disc lands
            // downwind from the player.  Back-project the intended impact
            // point to the start height so cl_rain_radius describes where
            // drops hit, not where they begin.
            start = impact_center - dir * (RAIN_SKY_OFFSET / -dir_z);
        }
        else
        {
            start = impact_center;
            start_z = rain_tick_view_pos_z + RAIN_SKY_OFFSET;
        }
    }

    // Trace far enough to reach any reasonable floor below the sky.
    traceline(start, start + dir * (RAIN_SKY_OFFSET * 4), MOVE_NORMAL, world);

    if (trace_fraction >= 1.0)
    {
        rd_active[i] = 0;
        return;
    }
    // Skip sky-hitting drops (open ceilings — the rain shouldn't
    // appear to "exit" through the sky brush).
    if (pointcontents(trace_endpos - trace_plane_normal * 2) == CONTENT_SKY)
    {
        rd_active[i] = 0;
        return;
    }

    // Default = land splash at the BSP hit.  Water override below
    // can shorten rd_end / flip rd_water / replace the surface normal.
    vector  impact_pos    = trace_endpos;
    vector  impact_normal = trace_plane_normal;
    float   impact_water  = 0;

    // Water detection — traceline doesn't stop at water surfaces
    // (CONTENT_WATER is a non-solid contents), so walk the fall
    // segment in fixed steps looking for the first empty→water
    // transition.  Coarse pass keeps it cheap (rain spawn isn't free
    // — this only runs at slot-restart, not per frame per drop).
    // 16 samples gives ~8qu resolution on a 128qu fall; binary refine
    // gets us within ~0.5qu of the actual surface.
    if (pointcontents(start) != CONTENT_WATER)
    {
        float seg_total = vlen(trace_endpos - start);
        if (seg_total > 0)
        {
            vector seg_dir = (trace_endpos - start) * (1 / seg_total);
            const float WATER_COARSE_STEPS = 16;
            float step_len  = seg_total / WATER_COARSE_STEPS;
            float hit_t = -1;
            float sample_t;
            float k;
            for (k = 1; k <= WATER_COARSE_STEPS; k = k + 1)
            {
                sample_t = step_len * k;
                if (pointcontents(start + seg_dir * sample_t) == CONTENT_WATER)
                {
                    hit_t = sample_t;
                    break;
                }
            }
            if (hit_t > 0)
            {
                // Binary-refine the water surface between the last
                // empty sample and the first water sample.
                float lo = hit_t - step_len;   // known empty (or start)
                float hi = hit_t;              // known water
                float bi;                       // bi-section iterator (named to avoid shadowing `r` above)
                for (bi = 0; bi < 6; bi = bi + 1)
                {
                    float mid = (lo + hi) * 0.5;
                    if (pointcontents(start + seg_dir * mid) == CONTENT_WATER)
                        hi = mid;
                    else
                        lo = mid;
                }
                impact_pos    = start + seg_dir * hi;
                impact_normal = '0 0 1';   // water surface is horizontal
                impact_water  = 1;
            }
        }
    }

    rd_start[i]      = start;
    rd_end[i]        = impact_pos;
    rd_normal[i]     = impact_normal;
    rd_water[i]      = impact_water;
    rd_fall_time[i]  = vlen(impact_pos - start) / rain_tick_speed;
    if (rd_fall_time[i] <= 0)
    {
        rd_active[i] = 0;
        return;
    }

    if (rain_tick_stagger)
        rd_fall_start[i] = rain_update_time - random() * rd_fall_time[i];
    else
        rd_fall_start[i] = rain_update_time;
    rd_active[i]     = 1;
    rd_total_active  = rd_total_active + 1;
    // Random phase so flakes don't all wobble in sync in snow mode.
    // 2π = 6.2831853.  Cheap and only matters when cl_snow != 0.
    rd_drift_phase[i] = random() * 6.2831853;
};

// alpha_mul lets the splash/settled phase fade the streak out while it
// lingers at rd_end (callers in the falling phase pass 1).  Computing
// frac here keeps the math co-located with the snow drift / cull logic
// below — the splash caller passes frac=1 to pin cur_pos at rd_end.
void(float i, float frac_override, float alpha_mul) Rain_DrawStreak =
{
    float frac;
    if (frac_override >= 0)
        frac = frac_override;
    else
    {
        float elapsed = rain_update_time - rd_fall_start[i];
        if (elapsed < 0) elapsed = 0;
        frac = elapsed / rd_fall_time[i];
        if (frac > 1) frac = 1;
    }

    float draw_alpha = rain_tick_alpha * alpha_mul;
    if (draw_alpha <= 0) return;

    vector path = rd_end[i] - rd_start[i];
    vector cur_pos = rd_start[i] + path * frac;

    // Snow mode: apply per-drop sinusoidal horizontal drift around
    // the fall line.  Uses the per-drop phase seeded at Rain_Restart
    // so flakes don't wobble in unison.  Drift magnitude is bounded
    // by cl_snow_drift; period ~4 seconds for a calm-blizzard feel.
    if (rain_tick_snow_mode && rain_tick_snow_drift > 0)
    {
        // cl_snow_drift is peak wobble in qu — sin axes oscillate ±drift
        // around the natural fall line.  Two axes at slightly different
        // frequencies (1.5 / 1.5*0.73) so flakes trace a Lissajous-style
        // path instead of a flat line.  Per-drop phase keeps each flake
        // out of sync with the others.
        float t = rain_update_time * 1.5 + rd_drift_phase[i];
        cur_pos_x = cur_pos_x + sin(t)        * rain_tick_snow_drift;
        cur_pos_y = cur_pos_y + sin(t * 0.73) * rain_tick_snow_drift;
    }

    // Distance cull (cheap dot product, no normalize required).  This
    // is the only camera-relative work the snow path needs to do per
    // flake — the billboard basis came pre-computed from
    // Rain_ResolveTuning, so snow returns out of here without ever
    // calling normalize() / crossproduct().
    if (rain_tick_draw_dist2 > 0)
    {
        vector eye_off = cur_pos - rain_tick_view_pos;
        if (dotproduct(eye_off, eye_off) > rain_tick_draw_dist2)
            return;
    }

    if (rain_tick_snow_mode)
    {
        // === SNOW MODE ===
        // Per-flake draw is now just 4 vector ADDs + the buffer write.
        // The 4 corner offsets are pre-summed in Rain_ResolveTuning
        // (either world-aligned for simple mode, or camera-facing).
        if (rain_tick_snow_simple)
            // Cheap append path — UV + RGB pre-stamped at init, so
            // the helper only writes xyz + alpha + indices.
            Rain_AppendStreakQuadCheap(cur_pos + rain_tick_snow_off_BL,
                                       cur_pos + rain_tick_snow_off_BR,
                                       cur_pos + rain_tick_snow_off_TR,
                                       cur_pos + rain_tick_snow_off_TL,
                                       draw_alpha);
        else
            Rain_AppendStreakQuad(cur_pos + rain_tick_snow_off_BL,
                                  cur_pos + rain_tick_snow_off_BR,
                                  cur_pos + rain_tick_snow_off_TR,
                                  cur_pos + rain_tick_snow_off_TL,
                                  draw_alpha);
        return;
    }

    // === RAIN MODE: elongated streak quad behind the drop ===
    // dir, eye_to_drop, and their normalized forms are only needed
    // here — kept out of the snow path entirely.
    vector dir = normalize(path);
    vector eye_to_drop = cur_pos - rain_tick_view_pos;
    if (vlen(eye_to_drop) <= 0)
        eye_to_drop = '1 0 0';
    eye_to_drop = normalize(eye_to_drop);

    // Streak tail trails behind the drop along the travel direction.
    // Clamp the tail to rd_start so the visible streak appears to
    // emerge from the sky instead of starting in the geometry above.
    float tail_back = rain_tick_length;
    if (tail_back > vlen(cur_pos - rd_start[i]))
        tail_back = vlen(cur_pos - rd_start[i]);
    vector tail_pos = cur_pos - dir * tail_back;

    // Camera-facing quad: pick a perpendicular axis aligned with the
    // viewer's right so the streak presents max width on screen.
    vector right = normalize(crossproduct(dir, eye_to_drop)) * rain_tick_width;

    Rain_AppendStreakQuad(tail_pos - right, tail_pos + right,
                          cur_pos + right,  cur_pos - right,
                          draw_alpha);
};

// Public: spawn a one-off splash visual at the given world point.
// Called from CSQC_BulletImpact when a hitscan impact lands in water.
// Hijacks an idle slot in the rain drop pool — the existing tick/draw
// loop animates it through the same 13-frame sprite + ring as a rain
// drop hitting water.  Gated on cl_rain_splash so the splash visual
// toggle suppresses it the same way it suppresses raindrop splashes.
void(vector pos) CSQC_Rain_SpawnBulletWaterSplash =
{
    if (cvar("cl_rain_splash") <= 0) return;
    if (rain_tick_splash_total <= 0) return;   // tuning not yet resolved
    float i;
    for (i = 0; i < RAIN_MAX; i = i + 1)
    {
        if (rd_active[i] == 0)
        {
            rd_active[i]        = 2;           // splashing
            rd_end[i]           = pos;
            rd_normal[i]        = '0 0 1';     // water surface always faces up
            rd_water[i]         = 1;           // water-mode rendering (2× scale)
            rd_splash_total[i]  = rain_tick_splash_total;
            rd_splash_end[i]    = cltime + rd_splash_total[i];
            rd_bullet_splash[i] = 1;           // skip settle streak
            rd_total_active     = rd_total_active + 1;
            return;
        }
    }
};

void(float i) Rain_DrawSplash =
{
    // Use the per-drop snapshot of total (and derived frame_time) so a
    // mid-splash cl_rain_splash_fps change doesn't desync the frame index
    // or alpha for splashes already in flight.
    float drop_total      = rd_splash_total[i];
    float drop_frame_time = drop_total / RAIN_SPLASH_FRAMES;
    float remaining = rd_splash_end[i] - rain_update_time;
    float alpha = remaining / drop_total;
    if (alpha <= 0)
    {
        rd_active[i] = 0;
        rd_total_active = rd_total_active - 1;
        return;
    }
    if (alpha > 1) alpha = 1;

    // Frame index from elapsed age — cycles 1..RAIN_SPLASH_FRAMES at
    // drop_frame_time each, then stays on the last frame as alpha
    // fades through the remaining time.
    float spl_age = drop_total - remaining;
    float spl_frame = floor(spl_age / drop_frame_time) + 1;
    if (spl_frame < 1) spl_frame = 1;
    if (spl_frame > RAIN_SPLASH_FRAMES) spl_frame = RAIN_SPLASH_FRAMES;
    string spl_tex = rain_splash_tex_frame[(int)spl_frame - 1];

    alpha = alpha * rain_tick_splash_alpha;

    // Shared geometry inputs for both halves of the splash.
    // 2× scale on water hits per the user spec — applies to both the
    // sprite's final size AND the ring's final size, so a water hit
    // gets a 2× bigger sprite and a 2× bigger ring at every animation
    // step.
    float size_mul = rd_water[i] ? 2 : 1;
    float half_sz  = rain_tick_splash_size * 2 * size_mul;

    // === Upright camera-facing sprite (13-frame animation) ===
    // Vertical axis is world-up; horizontal axis rotates yaw-only to
    // face the viewer (classic SPR_VP_PARALLEL_UPRIGHT billboard).
    // Sprite sits just off the surface and rises half its height above
    // it so the visible quad reads as "splash erupting from the floor"
    // rather than buried in the geometry.
    // Sprite flags: TWOSIDED (1024) + optional ADD (1) when
    // cl_rain_splash_fullbright is set — bright on dark/foggy maps.
    // The ring uses normal alpha blend regardless (additive ring on a
    // bright background goes invisible because the dark texels around
    // the ring shape add zero contribution).
    float sprite_flags = 1024 | (rain_tick_splash_fullbright ? 1 : 0);
    vector base_pos = rd_end[i] + rd_normal[i] * 0.5;
    vector to_view  = rain_tick_view_pos - base_pos;
    to_view_z = 0;
    if (vlen(to_view) < 0.001) to_view = '1 0 0';
    vector face_h = normalize(to_view);
    vector face_r = normalize(crossproduct('0 0 1', face_h));
    vector ax_h   = face_r * half_sz;
    vector ax_v   = '0 0 1' * half_sz;
    vector sprite_c = base_pos + ax_v;   // bottom of sprite at base_pos

    // Splash sprites are now batched by animation-frame bucket — each
    // drop's quad appends to rain_splash_verts in the bucket matching
    // its spl_frame.  Rain_FlushBatches emits one addtrisoup_simple
    // per bucket per tick, so the per-drop R_BeginPolygon chain that
    // used to live here is gone.
    //
    // Snow drops on water render the RING ONLY — the upward billboard
    // sprite (rain splash up-flick) doesn't read as a "snowflake
    // touched water" cue.  The ring still grows + fades below to
    // signal contact.  Land hits in snow mode never reach here (the
    // tick-loop short-circuits them straight to idle); this gate
    // covers only the water + snow case.
    if (!(rain_tick_snow_mode && rd_water[i]))
    {
        Rain_AppendSplashQuad((int)spl_frame - 1,
            sprite_c - ax_h - ax_v, sprite_c + ax_h - ax_v,
            sprite_c + ax_h + ax_v, sprite_c - ax_h + ax_v,
            alpha);
    }

    // === Ground ring (splashring.png, flat on surface) ===
    // Water hits ONLY — the ring reads as a "ripple on the water"
    // cue, which only makes physical sense on a water surface.  Land
    // hits get just the upright sprite.
    // Still gated on surface verticality (≤ 45° from horizontal) for
    // sanity — a near-vertical "water" hit shouldn't get a ring.
    // Grows from radius 0 to half_sz × RAIN_SPLASH_RING_SCALE × the
    // water size_mul, fades full→0 alpha over RAIN_SPLASH_RING_TIME
    // (~400ms).  Normal alpha blend (TWOSIDED only) — additive on the
    // ring texture's dark texels would drop the whole ring on bright
    // backgrounds.
    float ring_spawn = rd_splash_end[i] - rd_splash_total[i];
    float ring_age   = rain_update_time - ring_spawn;
    if (rd_water[i]
        && ring_age >= 0 && ring_age < RAIN_SPLASH_RING_TIME
        && rd_normal[i].z >= RAIN_SPLASH_RING_MIN_Z)
    {
        float ring_t   = ring_age / RAIN_SPLASH_RING_TIME;   // 0..1
        float ring_max = half_sz * RAIN_SPLASH_RING_SCALE;   // 20% smaller
        float ring_sz  = ring_max * ring_t;                  // grow 0 → final
        float ring_a   = (1 - ring_t) * rain_tick_splash_alpha;  // fade 1 → 0
        vector ref;
        if (fabs(rd_normal[i].z) < 0.9)
            ref = '0 0 1';
        else
            ref = '1 0 0';
        vector tangent  = normalize(crossproduct(rd_normal[i], ref));
        vector bitan    = normalize(crossproduct(rd_normal[i], tangent));
        vector ring_c   = rd_end[i] + rd_normal[i] * 0.25;
        vector ring_tx  = tangent * ring_sz;
        vector ring_bx  = bitan   * ring_sz;

        if (rain_ring_quads < (int)RAIN_RING_MAX_QUADS)   // 256 — water hits only
        {
            Rain_WriteQuad(rain_ring_quads,
                ring_c - ring_tx - ring_bx, ring_c + ring_tx - ring_bx,
                ring_c + ring_tx + ring_bx, ring_c - ring_tx + ring_bx,
                rain_tick_color, ring_a,
                &rain_ring_verts[0], &rain_ring_idx[0]);
            rain_ring_quads = rain_ring_quads + 1;
        }
    }
};

// Weather ambient — start / stop / swap the looped rainloop /
// snowloop on a dedicated CSQC entity.  Idempotent: re-runs each tick
// but only retriggers sound() when the desired state or volume
// changed.  Sound flags: SOUNDFLAG_FORCELOOP (loops forever) +
// SOUNDFLAG_NOSPACIALISE (heard at full vol from any view direction).
void() CSQC_Rain_AmbientUpdate =
{
    float want_state = 0;
    string want_sample = "";
    float want_vol = 0;
    if (cvar("cl_snow"))
    {
        want_state = 2;
        want_sample = "sounds/rain/snowloop.wav";
        want_vol = cvar("cl_snow_ambient_volume");
        if (want_vol <= 0) want_vol = 0.5;
    }
    else if (cvar("cl_rain"))
    {
        want_state = 1;
        want_sample = "sounds/rain/rainloop.wav";
        want_vol = cvar("cl_rain_ambient_volume");
        if (want_vol <= 0) want_vol = 0.5;
    }

    if (want_state == rain_ambient_state && want_vol == rain_ambient_volume)
        return;

    if (!rain_audio_ent)
    {
        rain_audio_ent = spawn();
        rain_audio_ent.classname = "rain_audio";
    }

    if (want_state == 0)
    {
        // Empty-string sound() is a silent no-op (engine sfx==NULL guard),
        // so use stopsound on the dedicated channel.
        stopsound(rain_audio_ent, CHAN_RAIN_AMBIENT);
    }
    else
    {
        sound(rain_audio_ent, CHAN_RAIN_AMBIENT, want_sample, want_vol, ATTN_NONE,
              100, SOUNDFLAG_FORCELOOP | SOUNDFLAG_NOSPACIALISE);
    }
    rain_ambient_state  = want_state;
    rain_ambient_volume = want_vol;
};

// Should the white sky be active at this point in the flash?  Pattern
// is a brief 3-pulse stutter (white-orig-white-orig) over the first
// ~130ms, then sustained white for the remainder of flash_dur.  That
// reads as the natural multi-pulse signature of a real lightning
// strike rather than a single binary flicker.
float(float age, float flash_dur) Rain_LightningWantWhite =
{
    if (age >= flash_dur) return 0;
    if (age < 0.03) return 1;
    if (age < 0.06) return 0;
    if (age < 0.10) return 1;
    if (age < 0.13) return 0;
    return 1;
};

// Issue the r_skybox swap when the desired state differs from the
// engine's current state.  Cheap when no flash is in progress (one
// state-equality check + early return).
void() Rain_LightningTickSky =
{
    if (lightning_flash_end <= 0)
    {
        // No flash active — make sure we're not stuck on white.
        if (lightning_sky_state != 0)
        {
            localcmd(sprintf("r_skybox \"%s\"\n", lightning_orig_sky));
            lightning_sky_state = 0;
        }
        return;
    }

    float flash_dur = cvar("cl_lightning_flash_duration");
    if (flash_dur <= 0) flash_dur = 0.18;
    float age = cltime - lightning_flash_start;

    if (age >= flash_dur)
    {
        // Flash done — restore original sky and clear the flash gate.
        if (lightning_sky_state != 0)
        {
            localcmd(sprintf("r_skybox \"%s\"\n", lightning_orig_sky));
            lightning_sky_state = 0;
        }
        lightning_flash_end = 0;
        return;
    }

    float want = Rain_LightningWantWhite(age, flash_dur);
    if (want != lightning_sky_state)
    {
        if (want)
            localcmd(strcat("r_skybox ", LIGHTNING_WHITE_SKY, "\n"));
        else
            localcmd(sprintf("r_skybox \"%s\"\n", lightning_orig_sky));
        lightning_sky_state = want;
    }
};

// Lightning state tick — schedule next strike, drive the skybox swap
// pattern, queue delayed thunder.  Active only when cl_lightning is on
// AND weather (cl_rain || cl_snow) is on; the skybox is restored when
// either of those flips off mid-flash.
void() CSQC_Rain_LightningUpdate =
{
    if (!cvar("cl_lightning")
        || (!cvar("cl_rain") && !cvar("cl_snow")))
    {
        lightning_next_strike = 0;
        // Force any in-flight flash to terminate so the sky restores.
        if (lightning_flash_end > 0)
            lightning_flash_end = cltime;
        Rain_LightningTickSky();
        return;
    }

    float min_int = cvar("cl_lightning_min_interval");
    float max_int = cvar("cl_lightning_max_interval");
    if (min_int <= 0) min_int = 8;
    if (max_int <= min_int) max_int = min_int + 17;

    // First-time arm — pick a random delay from now.
    if (lightning_next_strike <= 0)
        lightning_next_strike = cltime + min_int + random() * (max_int - min_int);

    // Strike: cache original sky, fire the swap pattern, schedule
    // thunder, arm the next strike.
    if (cltime >= lightning_next_strike)
    {
        float flash_dur = cvar("cl_lightning_flash_duration");
        if (flash_dur <= 0) flash_dur = 0.18;

        lightning_orig_sky    = cvar_string("r_skybox");
        lightning_flash_start = cltime;
        lightning_flash_end   = cltime + flash_dur;

        float min_d = cvar("cl_lightning_thunder_min_delay");
        float max_d = cvar("cl_lightning_thunder_max_delay");
        if (min_d <= 0) min_d = 1;
        if (max_d <= min_d) max_d = min_d + 3;
        lightning_thunder_at      = cltime + min_d + random() * (max_d - min_d);
        lightning_thunder_played  = 0;

        lightning_next_strike = cltime + min_int + random() * (max_int - min_int);
    }

    // Thunder fires once when its delay elapses.
    if (lightning_thunder_at > 0 && !lightning_thunder_played
        && cltime >= lightning_thunder_at)
    {
        if (!rain_audio_ent)
        {
            rain_audio_ent = spawn();
            rain_audio_ent.classname = "rain_audio";
        }
        sound(rain_audio_ent, CHAN_VOICE, "sounds/rain/thunder.wav",
              1.0, ATTN_NONE, 100, SOUNDFLAG_NOSPACIALISE);
        lightning_thunder_played = 1;
    }

    Rain_LightningTickSky();
};

// Flush the streak buffer alone — split out so Rain_DrawStreak can
// call it mid-frame when the 1024-quad cap fills (e.g. intensity 32
// peaks at ~3000 falling drops, which means 3 mid-frame flushes).
void() Rain_FlushStreaks =
{
    if (rain_streak_quads <= 0) return;
    addtrisoup_simple(rain_streak_tex_current, (float)rain_streak_flags_cur,
                      &rain_streak_verts[0], &rain_streak_idx[0],
                      rain_streak_quads * 6);
    rain_streak_quads = 0;
};

// Submit every populated batch in one addtrisoup_simple call per
// material and reset the counters.  Called at the end of
// CSQC_Rain_Tick after Rain_DrawStreak / Rain_DrawSplash have
// finished appending verts for the frame.
void() Rain_FlushBatches =
{
    Rain_FlushStreaks();

    if (rain_ring_quads > 0)
    {
        addtrisoup_simple(RAIN_SPLASHRING_TEX, 1024,
                          &rain_ring_verts[0], &rain_ring_idx[0],
                          rain_ring_quads * 6);
        rain_ring_quads = 0;
    }

    // Flush each populated splash bucket — one addtrisoup_simple per
    // active animation frame.  At most 13 calls per tick (vs
    // ~RAIN_MAX/13 × 13 = ~RAIN_MAX per-drop R_BeginPolygon trips
    // before batching).  Each bucket's verts/idx pointers offset into
    // the shared flat buffer so the indices (slot-relative, see
    // Rain_PreInitStreakBuffer) work for each bucket independently.
    int b;
    for (b = 0; b < (int)RAIN_SPLASH_FRAMES; b = b + 1)
    {
        if (rain_splash_quads[b] <= 0) continue;
        int base_v = b * (int)RAIN_SPL_BUCKET_QUADS * 4;
        int base_i = b * (int)RAIN_SPL_BUCKET_QUADS * 6;
        addtrisoup_simple(rain_splash_tex_frame[b],
                          (float)rain_splash_flags_cur,
                          &rain_splash_verts[base_v],
                          &rain_splash_idx[base_i],
                          rain_splash_quads[b] * 6);
        rain_splash_quads[b] = 0;
    }
};

// Lazy-resolve the engine particle handles and validate them.  Called
// every tick so a console `exec particles/weather.cfg` mid-session
// takes effect immediately.  Once a handle resolves valid, we cache
// it and skip future lookups via pe_weather_resolved.
//
// FTE's particleeffectnum (engine pr_csqc.c) returns a slot index
// even when the named effect isn't registered — `> 0` or `!= 0` on
// the raw return tells you NOTHING about validity.  particleeffectquery
// returns "" for unregistered slots; non-empty means real effect.
float() Rain_EngineActive =
{
    if (!cvar("cl_weather_engine")) return 0;

    if (!pe_weather_resolved)
    {
        if (pe_weather_snow == 0)
            pe_weather_snow = particleeffectnum("weather.snow");
        if (pe_weather_snow_bright == 0)
            pe_weather_snow_bright = particleeffectnum("weather.snow_bright");
        if (pe_weather_rain == 0)
            pe_weather_rain = particleeffectnum("weather.rain");

        float snow_ok        = (pe_weather_snow        != 0 && particleeffectquery(pe_weather_snow,        0) != "");
        float snow_bright_ok = (pe_weather_snow_bright != 0 && particleeffectquery(pe_weather_snow_bright, 0) != "");
        float rain_ok        = (pe_weather_rain        != 0 && particleeffectquery(pe_weather_rain,        0) != "");
        if (!snow_ok)        pe_weather_snow        = 0;   // scrub so retry happens next tick
        if (!snow_bright_ok) pe_weather_snow_bright = 0;
        if (!rain_ok)        pe_weather_rain        = 0;
        if (snow_ok || rain_ok)
            pe_weather_resolved = 1;   // bright is optional — base snow is enough to declare active
        else
            return 0;   // weather.cfg not loaded yet — fall back to CSQC pool
    }
    return 1;
};

// Engine-particle weather tick — replacement for the CSQC pool when
// cl_weather_engine is 1.  Skips the 4096-slot scan entirely; just
// spawns N FTE particles per frame at sky height around the camera.
// The engine moves them autonomously via the velocity / gravity /
// friction values in particles/weather.cfg, so QC's per-flake work
// becomes ZERO during fall — only the spawn call costs anything.
//
// Trade-offs vs CSQC pool:
//   - Bullet-water splash hijack of rd_* slots does NOT fire (those
//     slots aren't allocated in engine mode).
//   - Water-surface ring on rain impact is not produced (the pool
//     was where the water-detect ran).
//   - cl_rain_draw_distance / cl_rain_stagger / per-flake tuning
//     don't apply — visuals are entirely the r_part config's job.
//   - Bonus: every per-frame CPU savings recovered here can be spent
//     on much higher intensity than the CSQC pool sustains.
void() Rain_TickEngine =
{
    if (!cvar("cl_rain") && !cvar("cl_snow")) return;

    // Pick the right r_part variant for the current mode + fullbright
    // toggle.  Handles validated by Rain_EngineActive — non-zero here
    // means real registered effect.
    float effectnum;
    if (cvar("cl_snow"))
    {
        if (cvar("cl_snow_fullbright") && pe_weather_snow_bright != 0)
            effectnum = pe_weather_snow_bright;
        else if (pe_weather_snow != 0)
            effectnum = pe_weather_snow;
        else
            return;
    }
    else
    {
        if (pe_weather_rain != 0)
            effectnum = pe_weather_rain;
        else
            return;
    }

    // Spawn-rate model: target a steady population of
    // (intensity × RAIN_INTENSITY_UNIT) particles.  With an average
    // particle lifetime LIFE seconds (set in the r_part `die` field)
    // the per-second spawn rate is pop / LIFE.  Per-frame is
    // pop / LIFE × frametime.
    float intensity;
    if (cvar("cl_snow"))
    {
        intensity = cvar("cl_snow_intensity");
        if (intensity <= 0) intensity = cvar("cl_rain_intensity");
    }
    else
        intensity = cvar("cl_rain_intensity");
    if (intensity <= 0) intensity = 0.5;
    if (intensity > 32) intensity = 32;

    // LIFE chosen to roughly match the r_part template's die value
    // (8s snow / 1s rain).  If you change `die` in weather.cfg, update
    // both branches here so the population math tracks.
    float lifetime = cvar("cl_snow") ? 8.0 : 1.0;
    float pop = intensity * RAIN_INTENSITY_UNIT;
    float spawn_count = (pop * frametime) / lifetime;
    if (spawn_count < 1) spawn_count = 1;   // avoid sub-1 floor losing rate
    if (spawn_count > pop) spawn_count = pop;

    // Velocity comes from the speed cvars + the rain angle cvars
    // (wind direction) — passed through pointparticles' `dir` arg so
    // every spawned particle inherits this initial velocity on top of
    // whatever per-particle randomness the r_part's spawnvel adds.
    // The r_part's veladd is intentionally zeroed in weather.cfg so
    // this dir is authoritative.
    float speed;
    if (cvar("cl_snow"))
    {
        speed = cvar("cl_snow_speed");
        if (speed <= 0) speed = 120;
    }
    else
    {
        speed = cvar("cl_rain_speed");
        if (speed <= 0) speed = 800;
    }
    vector vel = normalize([cvar("cl_rain_angle_x"), cvar("cl_rain_angle_y"), -1]) * speed;

    // Spawn at sky height above the camera.  spawnorg in the r_part
    // config scatters them across the desired XY radius.
    vector view_pos = (vector)getproperty(VF_ORIGIN);
    vector spawn_pos = view_pos + [0, 0, RAIN_SKY_OFFSET];

    pointparticles(effectnum, spawn_pos, vel, spawn_count);
};

// Per-frame entry point — call from CSQC_UpdateView.  Cheap when
// cl_rain is 0 (single cvar read + return).
void() CSQC_Rain_Tick =
{
    // Audio / lightning state must update BEFORE any early-return so
    // the ambient loop tears down cleanly when the user toggles
    // cl_rain off.  Both are cheap when nothing's running.
    CSQC_Rain_AmbientUpdate();
    CSQC_Rain_LightningUpdate();

    // Engine-particle backend fork — when cl_weather_engine is 1 and
    // weather.cfg's effects resolve valid, skip the CSQC pool entirely
    // (Rain_TickEngine handles spawning; engine moves the particles
    // in C).  Rain_EngineActive does lazy resolve + validity check.
    if (Rain_EngineActive())
    {
        Rain_TickEngine();
        return;
    }

    // Always resolve so bullet-water splashes (spawned via
    // CSQC_Rain_SpawnBulletWaterSplash) have valid tuning even when
    // cl_rain / cl_snow is off — they hijack idle slots in the rd_*
    // pool and need the existing tick/draw loop to advance them.
    Rain_ResolveMedia();
    Rain_ResolveTuning();

    if (rain_tick_fps <= 0)
    {
        rain_update_now = 1;
        rain_update_time = cltime;
        rain_next_update_time = 0;
    }
    else if (rain_next_update_time <= 0 || cltime >= rain_next_update_time)
    {
        rain_update_now = 1;
        rain_update_time = cltime;
        rain_next_update_time = cltime + (1 / rain_tick_fps);
    }
    else
    {
        rain_update_now = 0;
    }

    // Snow mode reads its own intensity cvar (0 → fall back to rain
    // intensity so legacy configs work unchanged).
    float intensity;
    if (cvar("cl_snow"))
    {
        intensity = cvar("cl_snow_intensity");
        if (intensity <= 0) intensity = cvar("cl_rain_intensity");
    }
    else
        intensity = cvar("cl_rain_intensity");
    if (intensity <= 0) intensity = 0.5;
    if (intensity > 32) intensity = 32;
    float target = floor(intensity * RAIN_INTENSITY_UNIT);
    if (target > RAIN_MAX)
        target = RAIN_MAX;

    float i;
    float active_count = 0;

    // Per-tick cvar reads — pulled out of the 4096-iter loop.  Saves
    // ~3-4 cvar() trips per slot per frame at the cost of one tick-
    // scoped local each.  cl_rain_splash gates the land-splash sprite
    // emission AND the streak→splash state transition below; capturing
    // the value once keeps both consistent within a tick.
    float tick_want_splash = cvar("cl_rain_splash") > 0;
    // Snow drops on land hit the floor and just vanish — no splash
    // animation (the rain splash sprite is wrong-looking for snow,
    // and snow doesn't actually splash in real life).  Water hits
    // KEEP the splash (rd_water tracked at restart) so the ring
    // animation still plays on water surfaces.
    float tick_snow_kill_land_splash = rain_tick_snow_mode;

    // Active-slot fast-path — when no drop is alive AND no bullet-water
    // splash is in flight, skip the entire 4096-iter scan.  Profile
    // showed ~60ms self time in CSQC_Rain_Tick when rain was off; this
    // gate removes it.  When CSQC_Rain_SpawnBulletWaterSplash spawns a
    // splash mid-game, it increments rd_total_active so the scan
    // re-engages on the next tick.
    float skip_tick_scan = (rd_total_active <= 0);

    // Tick + draw existing drops.
    if (!skip_tick_scan)
    for (i = 0; i < RAIN_MAX; i = i + 1)
    {
        if (rd_active[i] == 1)
        {
            if (rain_update_now && rain_update_time >= rd_fall_start[i] + rd_fall_time[i])
            {
                // Transition to splashing.  Gated on cl_rain_splash AND
                // (in snow mode) on whether the drop hit water.  Land
                // hits in snow mode go straight to idle so the rain-
                // style splash sprite doesn't play on snow.
                float drop_can_splash = tick_want_splash;
                if (tick_snow_kill_land_splash && !rd_water[i])
                    drop_can_splash = 0;
                if (drop_can_splash)
                {
                    rd_active[i] = 2;
                    rd_splash_total[i] = rain_tick_splash_total;
                    rd_splash_end[i]   = rain_update_time + rd_splash_total[i];
                    // Slot stays active (1 → 2) — no counter change.
                }
                else
                {
                    rd_active[i] = 0;
                    rd_total_active = rd_total_active - 1;
                }
            }
            else
            {
                Rain_DrawStreak(i, -1, 1);
                if (rain_update_now)
                    active_count = active_count + 1;
            }
        }
        if (rd_active[i] == 2)
        {
            // Settled streak — pinned at rd_end, fading out over
            // exactly one rain-update tick (1/cl_rain_fps, or one
            // render frame when cl_rain_fps is 0).  Splash decal then
            // takes over for the rest of its own window.
            // Skipped for bullet-water splashes (rd_bullet_splash flag)
            // because their rd_start is uninitialised and the streak
            // would draw from (0,0,0) to the impact — a long diagonal
            // line across the map.
            if (!rd_bullet_splash[i])
            {
                float settle_dur = (rain_tick_fps > 0)
                    ? 1.0 / rain_tick_fps
                    : frametime;
                if (settle_dur <= 0) settle_dur = 0.05;
                float splash_age = rain_update_time - (rd_splash_end[i] - rain_tick_splash_total);
                if (splash_age >= 0 && splash_age < settle_dur)
                {
                    float settle_alpha = 1 - (splash_age / settle_dur);
                    Rain_DrawStreak(i, 1, settle_alpha);
                }
            }
            Rain_DrawSplash(i);
        }
    }

    // Flush the per-frame trisoup batches — one addtrisoup_simple per
    // shader instead of the ~16k–50k R_BeginPolygon trips the per-drop
    // emission used to make.  Safe to do here because the reseed loop
    // below only spawns new tracelines, no drawing.
    Rain_FlushBatches();

    // Re-arm idle slots until we hit the target.  The cursor avoids
    // rescanning from slot 0 every frame, while the cvar limits new
    // tracelines so a hitch cannot refill thousands of drops at once.
    if (!rain_update_now)
        return;
    // Gate the reseed loop ONLY on weather state — the tick loop above
    // continues to advance any in-flight bullet-water splashes even
    // when both weather cvars are off.
    if (!cvar("cl_rain") && !cvar("cl_snow"))
        return;

    // Cache once per tick — Rain_Restart reads this on every reseed
    // (up to cl_rain_reseed_per_frame times per frame).
    rain_volumes_active_cached = CSQC_FuncRain_HasActive();

    float reseed_budget = rain_tick_reseed_per_frame;
    float scans;
    for (scans = 0; scans < RAIN_MAX && active_count < target && reseed_budget > 0; scans = scans + 1)
    {
        i = rain_reseed_cursor;
        rain_reseed_cursor = rain_reseed_cursor + 1;
        if (rain_reseed_cursor >= RAIN_MAX)
            rain_reseed_cursor = 0;

        if (rd_active[i] == 0)
        {
            Rain_Restart(i);
            if (rd_active[i] == 1)
                active_count = active_count + 1;
            reseed_budget = reseed_budget - 1;
        }
    }
};
