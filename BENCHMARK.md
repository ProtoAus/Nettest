# FPS benchmarking brief — Quakers / FTE

Audience: an autonomous agent with shell access on the machine under test. Written after a full
frame decomposition on the reference desktop (2026-07-30), so most of this document is the list of
traps that silently corrupt results. Read the WHY on each one — several of them produce
plausible-looking numbers rather than errors, and an agent that works around them without
understanding them will report confident nonsense.

Target machine for this round: **Intel N100 laptop** (4 Gracemont E-cores, no SMT, Intel UHD Gen12
24 EU, ~6 W). Reference desktop numbers are at the bottom for comparison.

---

## 0. Prerequisites — you probably do not have a runnable build

Cloning the repos is **not** enough:

| needed | where it comes from | in git? |
|---|---|---|
| `fteqw64.exe` (or Linux binary) | built from the engine repo | **no** |
| `csprogs.dat` / `qwprogs.dat` / `menu.dat` | `fteqcc64.exe -srcfile {cl,sv,m}_progs.src` | **no** — outputs land outside `src/` |
| `quakers_csprogs.pk3` | `python pack_csprogs.py` after compiling | **no** |
| gamedir assets (maps, textures, models) | the R2 mirror via the launcher | **no** |

So either run the launcher against the live mirror, or build progs locally and obtain the engine
binary separately. **Confirm you have a working game that reaches the map before touching any
benchmark cvar.** If `fy_killzone` does not load, everything below produces garbage.

QC build, if you need it (paths must be absolute — the batch wrapper silently no-ops in agent
shells):

```bash
cd <repo>/src
./fteqcc64.exe -srcfile cl_progs.src   # expect "Done. 0 warnings"
./fteqcc64.exe -srcfile sv_progs.src
./fteqcc64.exe -srcfile m_progs.src
python pack_csprogs.py                 # REQUIRED — skipping it leaves a stale pk3 that shadows the new .dat
```

---

## 1. The autonomous harness

Do not drive this interactively. Launch, let a deferred chain do the work, dump numbers as text,
quit, then parse the log.

```bash
fteqw64.exe -condebug +set sv_cheats 1 +map fy_killzone +exec bench.cfg
```

Every token must be a **separate argv word**. `"+exec bench.cfg"` as one quoted argument produces
`Unknown command "exec bench.cfg"`.

**`+map` must be on the command line, not in the cfg.** The mod's menu backdrop boots a listen
server on `menumap` unless the engine set `cl_launchintogame`, which it only does for a
command-line `+map` / `+connect` / demo (`cl_main.c:8097`, `m_main.qc:124`). A cfg-issued `map` gets
clobbered and you will sample the 46-draw-call menu background instead of the 340-draw-call map.
This cost two full runs before it was noticed. **Always verify the draw-call count is in the right
order of magnitude before believing any result.**

`-condebug` mirrors the console to `qconsole.log` in the gamedir. That is how you read numbers —
never from screenshots.

### bench.cfg template

```
// Delays are SECONDS from exec. The client is not connected for the first ~15s;
// commands fired earlier fail with `Can't "cmd", not connected`.
// The N100 loads slower than the reference desktop — scale these UP and verify
// from the log rather than assuming they landed.

defer 30 "cl_idlefps 0"
defer 30 "cl_maxfps 0"
defer 30 "r_speeds 2"
defer 31 "setpos 20 320 211"
defer 32 "cl_setangles 2.8 121.8 0"
defer 35 "r_speeds_dump"
defer 36 "quit"
```

`defer` is `Cmd_In_f` and is **disabled when `ruleset_allow_in` is 0** — check that before assuming
a silent chain means a silent failure elsewhere.

`r_speeds_dump` prints the whole sample table as text (`µs/frame`, 100-frame average) plus the quant
counters. It requires `r_speeds 2` or higher and is one-shot: it sets a flag consumed by the next
`RSpeedShow`.

---

## 2. Traps that silently corrupt results

These all produce believable numbers, not errors.

### 2.1 The CSQC cvar table overwrites anything set at exec time

`sh_cvar_table.qc` is the single source of truth for mod cvars and is re-applied at CSQC init.
`cl_maxfps`, `cl_idlefps` (`sh_cvar_table.qc:1488-1489`) and `cl_debug_move` are all reset. Anything
you `set` in a cfg *before* CSQC comes up is silently reverted.

**Set them inside the deferred chain**, after CSQC init. Two tells that this bit you: a frame
interval that does not match the cap you think you set, and a `Frame pacing` bucket reading exactly
`0.00`.

### 2.2 An unfocused window renders at 60 fps with idle gaps

`cl_main.c:7199` computes `idle = !vid.activeapp` and returns **before** `SCR_UpdateScreen`. With
`cl_idlefps` at its default 60, an unfocused window renders at 60 fps with real idle time between
frames — which also lets the GPU fully drain, so any GPU-stall measurement reads ~0 for entirely the
wrong reason.

**The window must be focused for the whole run.** `cl_idlefps 0` mitigates but focus is still the
safe state. If you cannot guarantee focus on this machine, say so in the report rather than
silently shipping the numbers.

### 2.3 `setpos` angles are silently discarded

`Cmd_SetPos_f` sets `.angles` + `FIXANGLE_FIXED`, the server sends them once, then `sv_send.c:1651`
clears `fixangle` immediately and client prediction overwrites the view from `pred_cmd_angles`.
Position sticks; **angles never do.**

Use `cl_setangles <pitch> <yaw> <roll>` — a CSQC command that writes `VF_CL_VIEWANGLES`, the real
client angle accumulator that survives prediction. Called with no arguments it prints the current
angles in copy-pasteable form.

`cl_debug_move 1` also draws a `View Ang` line and a ready-made `setpos` line. Note it reports
`view_angles`, not `VF_ANGLES` — the latter is only the render camera and is rebuilt from
bob/sway/gunkick every frame.

Reading `0.0 0.0 0.0` is a clean spawn value, i.e. the angle was never applied — not drift.

### 2.4 `r_speeds 2` structurally cannot see a GPU stall

`render.h:860`:

```c
#define RSpeedEnd(spt) do {if(r_speeds.ival > 1){if(r_speeds.ival > 2 && qglFinish)qglFinish(); ...
```

The `qglFinish` only fires at `r_speeds > 2`. **At `r_speeds 2` no child bucket contains a GPU sync
at all**, so GPU-tail time is forced into the parent's unattributed remainder.

Consequence for you: if the child buckets sum to well under `Total refresh`, **do not conclude there
is unbucketed CPU work.** Suspect a GPU stall. Three rounds of new buckets were added chasing a
1138 µs residual and all read near zero; the residual was a fence, not CPU work.

`r_speeds 3` gives per-bucket syncs but serialises the pipeline and changes what you are measuring.
Use 2 for attributing CPU work; use 3 only to test whether a gap is GPU-side, and never compare a
2-run against a 3-run.

### 2.5 Run-to-run drift is ~7–18% and trends upward within a session

This is the single most important methodological point. Frame time creeps monotonically upward the
longer a session runs (thermals, on a 6 W part especially).

- **Never trust a delta under ~100 µs from single samples.**
- **Interleave A/B/A/B**, never A,A,A then B,B,B — a monotonic drift turns the latter into a fake effect.
- Minimum 3 repeats per configuration; report all of them, not the mean alone.
- **Never restart the game between A and B.** Change one cvar in the running session.

Several small effects quoted during the desktop session (e.g. a 29 µs difference between two
`r_props_shadowdist` values) were inside this noise floor and should not have been quoted as real.

### 2.6 The sample is a 100-frame rolling average

`cl_screen.c:110` divides by `frameinterval = 100`. After changing anything, **wait ≥ 2 s** before
sampling or you get a blend of both configurations.

### 2.7 Do not move

Stand still. All buckets are viewpoint-dependent; `World walking` and `Opaque Batches` especially.
Re-issue `setpos` + `cl_setangles` before each sample rather than trusting that nothing nudged.

---

## 3. Reference viewpoint

```
setpos 20 320 211
cl_setangles 2.8 121.8 0
```

Map `fy_killzone`, all 66 `prop_physics` present. Sanity check: `Draw Calls` ≈ 340,
`Draw Indicies` ≈ 2.0 M. An order of magnitude below that means you are in the menu backdrop
(see 2.1).

---

## 4. What to actually answer on this machine

Prioritised. H1 is the one that matters most, because it determines whether the desktop conclusions
transfer at all.

### H1 — Is this machine GPU-bound? (do this first)

On the reference desktop, `r_renderscale 2` vs `1` cost **14.7 µs** — four times the pixels for
free, because that GPU had headroom. **On a 24-EU UHD this prediction is expected to fail.**

Test: at the reference viewpoint, `r_renderscale 2` → wait 2 s → dump → `r_renderscale 1` → wait
2 s → dump → back to 2. Interleave, 3 repeats.

- Small delta (< ~100 µs) → CPU-bound like the desktop; desktop conclusions transfer.
- Large delta → **GPU-bound, and the desktop conclusions invert.** Renderscale becomes the first
  lever in a low-end preset, and supersampling must not be the shipped default on hardware like this.

Note `r_renderscale` 1 and 2 are the only sensible values: at 2.0 the resolve is a clean 2:1
downsample where the bilinear tap lands exactly between four texels. 1.5 weights texels unevenly
and looks soft for the cost.

### H2 — Frame pacer: help or hurt? (Windows-native builds only)

**`sys_framepacing` lives entirely in `sys_win.c` and both call sites are gated
`#if defined(_WIN32) && !defined(FTE_SDL)`.** On Linux, or on any SDL build, the pacer does not
exist, `sys_framepacing_drain` is not registered, and H2 is unanswerable. Say so rather than
reporting zeros.

On a Windows-native build, sweep `sys_framepacing_drain` 0 / 1 / 2 / 3 **with `cl_maxfps 300`** —
the paced hold early-returns on `fps <= 0`, so at `cl_maxfps 0` mode 4 does nothing but drain and
you are not measuring pacing at all.

Report per depth: mean frame interval, **stddev of the interval** (cadence quality is the point, not
peak fps), and the `Frame pacing` bucket. Depth 2 (N−1 fence) is the shipped default; it won on the
desktop because it bounds queue depth without forbidding CPU/GPU overlap. On a machine where the GPU
is the limiter this balance may differ — that is the interesting part.

`sys_framepacing_stats` prints the active drain depth.

### H3 — Does the bucket *shape* change?

Dump the full table at the reference viewpoint and compare proportions against §5. On a 4-core
no-SMT part expect the CPU buckets to scale up roughly uniformly. **A bucket that grows
disproportionately is the low-end-specific target** and is more valuable than any absolute number
here.

### H4 — 1% lows (never measured on any machine)

`show_fps 2` draws a frame-time graph. This has never been captured and is one of the three stated
goals. Static samples cannot show it — capture a full round crossing: a respawn, a shotgun blast
into a prop pile, and walking into a newly lit room. Decal accumulation is the main suspect
(`cl_blood_persistent 1` never frees) and only shows over a full round.

---

## 5. Reference desktop baseline (2026-07-30)

Same viewpoint, shipped defaults, `r_renderscale 2`. That GPU had substantial headroom — do not
assume this machine does.

**Headline:** `Total refresh` **2178.95 µs → 458.94 fps** (was 2764.51 µs / 361.73 fps before the
frame-pacer fix).

Decomposition, sampled with `sys_framepacing_drain 0` so the pacing bucket does not mask the rest
(`Total refresh` 2473.67 µs in that state — a different config from the headline, do not mix them):

| bucket | µs | share |
|---|---|---|
| `Opaque Batches` | 724.99 | 29% |
| `World walking` | 433.07 | 18% |
| `QC UpdateView` residual (mod HUD) | 419.96 | 17% |
| `Shadow generation` | 290.16 | 12% |
| `Present` | ~160 | 6% |
| `2d Elements` | ~100 | 4% |
| `Transparent Batches` | 90.86 | |
| `Entity setup` | 70.79 | |
| `Postproc/resolve` | 23.38 | |
| `Prediction` | 16.70 | |
| `RT Lights` | 2.26 | |

Reconciles with `Total refresh` to ~1 µs. Counters: `Draw Calls` ≈ 340, `Draw Indicies` ≈ 2.0 M,
`Shadowmap Sides` 3.

Note `QC UpdateView` is the mod's HUD pass and does **not** appear in `2d Elements` — it runs inside
`CSQC_UpdateView`. `Lightmap updates` is genuinely 0 at `r_dynamic 0`; do not treat it as missing data.

---

## 6. Command reference

| command / cvar | notes |
|---|---|
| `r_speeds 2` | enables the sampler. `3` adds per-bucket `qglFinish` and perturbs the measurement |
| `r_speeds_dump` | prints the table as text; needs `r_speeds ≥ 2`; one-shot |
| `show_fps 1` \| `2` | 1 = averaged fps, 2 = frame-time graph (use for 1% lows) |
| `setpos x y z` | position only — angles are discarded (see 2.3) |
| `cl_setangles p y r` | CSQC; sets the real view angles. No args = print current |
| `cl_debug_move 1` | on-screen pos + `View Ang` + copy-pasteable `setpos` line |
| `cl_idlefps 0` | stops the 60 fps unfocused path; set inside the deferred chain |
| `cl_maxfps` | `300` for pacing tests, `0` for peak; set inside the deferred chain |
| `r_renderscale 1` \| `2` | integer values only |
| `sys_framepacing_drain 0..3` | Windows-native only. 2 = shipped default (N−1 fence) |
| `sys_framepacing_stats` | prints active drain depth |
| `r_props_shadowdist` | **effective radius is `value + 192`** (`PP_CULL_HYST`). Caused two sizing errors |
| `defer <s> "cmd"` | disabled if `ruleset_allow_in` is 0 |
| `-condebug` | mirrors console to `qconsole.log` — the only trustworthy readout |

---

## 7. Report format

For each configuration, give the **raw repeats**, not just a mean:

```
CONFIG: <cvars that differ from shipped defaults>
PLATFORM: <OS, build target, GL renderer string, focused y/n>
run 1: Total refresh <µs>  fps <n>  | Draw Calls <n>  Draw Indicies <n>
run 2: ...
run 3: ...
FULL TABLE (one representative run): <paste the r_speeds_dump block verbatim>
```

Then, explicitly:

1. **H1 verdict** — CPU-bound or GPU-bound, with the renderscale delta that decides it.
2. Any bucket whose *share* differs from §5 by more than a few points.
3. Anything you could not measure, and why (e.g. no pacer on this build, could not hold focus).

**Flag every number you could not obtain rather than substituting an estimate.** On the reference
desktop, estimates were wrong by 5× in one case (a predicted 60–120 µs cost measured 17 µs) and
wrong in direction twice. Measured-or-absent is the standard; do not interpolate.
