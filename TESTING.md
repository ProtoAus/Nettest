# Owed in-game checks — monster AI programme

Things the headless harness **cannot** verify, listed newest-first. Everything not
listed here has been driven headlessly and is backed by numbers in the session log.

The harness limits that create this list:

- ~~**Bots have no netchan.**~~ **LIFTED in Patch 127** — see below. A real client
  now runs headlessly, so CSQC entity delivery, wire format, `setmodel` results and
  every `print()` in CSQC are all verifiable without a window.
- **Nothing renders.** Animation, model orientation, muzzle positions and beam
  visuals are still invisible: the headless renderer replaces `SCR_UpdateScreen`
  wholesale, so `CSQC_UpdateView` — and therefore every `predraw` — never runs.
- **Sound is not audible.** Precache is verifiable; playback is not.

---

## PATCH 171 — "r_shadows 0 does not fix it": four engine bugs behind black GoldSrc transparency, and `r_texdiag` so this stops being guesswork

**Report:** *"r_shadows 0 does not fix the bug, some GoldSrc models with transparency
textures has some planes blacks. `{stripeh` is still black in pizza_ya_san1, and some
other entities with transparency that use the GoldSrc maps/pallet are still glitched"*,
plus *"[the Patch 167 comment] might be a mistake comment?"*

Patch 170's `r_shadows 0` suggestion was wrong — it narrows by elimination and the user
had `r_shadows "0"` in `cfg/settings.cfg:28` already, so the test could never have said
anything. This patch measures instead. **Engine only; no QC changed.**

### The Patch 167 comment is not a mistake — re-derived independently, then confirmed in-engine

Every number in `client/wad.c:432-437` checks out. `{stripeh` is 128x32, its embedded
palette validates (marker 256), it holds **0 of 4096 index-255 texels**, `pal[255]` is
`(141,15,2)` and it is used on exactly **418 worldspawn faces**. Decoded masked it is a
100%-opaque near-white slab, mean RGB **(223.7,223.7,223.7)** — identical across all 11
copies of `decals.wad` on this machine. The new `r_texdiag` then confirmed it from inside
the running engine rather than from a Python decode:

```
[texdiag] {stripeh   128x32  src=wad/repl  shader={stripeh
[texdiag]   {stripeh   decode=masked keyed=0.0% visible=4096 mean RGB(224,224,224) luma 223.9
```

It resolves (Sven's own `svencoop/decals.wad` has it, and `wad.c:919` force-loads
`decals.wad` for every HL map), and it takes the ordinary alpha-tested `{` shader, not the
world-opaque one — `Mod_MaskedTextureIsWorldOnly` correctly declines it because submodels
`*160` and `*239` also use it. **No stage of the texture pipeline can make it black.** Its
418 faces do carry the dimmest lightmap on the map — mean luma **36.1** against a map mean
of 55.5 and **73.8–103.8** on the surrounding road (`out_pav3`, `out_pave2`) — so it draws
as a dark slab, but that is lighting, not the WAD. Reported unexplained rather than
guessed at again.

### Four bugs found and fixed

**1. `FULLBRIGHT|MASKED` silently lost its alpha test — this is the black planes.**
`gl_hlmdl.c` tested `HLMDLFL_FULLBRIGHT` first and `HLMDLFL_CHROME` in the same else-if
chain as `HLMDLFL_MASKED`, as though the flags were exclusive. They are not. Scanned all
**16497 studio models** in the HL/Sven corpus: 2816 masked textures are plain `MASKED`,
but **179 also set FULLBRIGHT** (129, +46 with FLAT, +2 with ADDITIVE, +2 CHROME|MASKED).
Every one of them got a shader with no discard — and because the masked upload deliberately
writes `RGBA(0,0,0,0)` into palette entry 255, the texels that exist only to be keyed out
are drawn as **opaque black**. They are overwhelmingly the 2D billboard models
(`2d_*.mdl`, `v_tesla`'s `bulb_masked.bmp`) whose whole silhouette is keyed, so the visible
result is a black card. Added `HLSHADER_FULLBRIGHTMASKED` / `CHROMEMASKED` /
`FULLBRIGHTCHROMEMASKED` and folded `masked` into the branch. The upload loop had the same
ordering bug the other way round (chrome before masked, uploading `TF_8PAL24`, which has no
alpha at all); masked now wins there too.

**2. Masked skins darken toward black down the mip chain, and the obvious fix would not have worked.**
Transparent texels carry RGB 0, and `Image_MipMap4X8` averages all four channels with a
flat `>>2` — no alpha weighting, no bleed. Measured on the two models named in the report,
mean RGB of the texels still passing `alphaFunc GE128`:

| texture | keyed | mip0 | mip3 | mip6 |
|---|---|---|---|---|
| `bush1.mdl` `{bush1_2.bmp` | 79.8% | luma 108.4 | 100.8 | **65.0** |
| `tree1.mdl` `branch.bmp` | 61.8% | luma 43.8 | 35.3 | **35.0** |

`branch.bmp` starts dark, so against any normal lighting mip6 reads as black. The trap:
`Image_MipMap4X8` is **dead code on this machine** — `image.c:8523` returns early whenever
`sh_config.can_genmips`, and `glGenerateMipmap` does the same unweighted box filter in
hardware. So the fix has to be applied to the mip-0 data, before either generator runs:
new `Image_BleedTransparentRGB` dilates opaque colour into the keyed texels pre-upload.
Same measurement after: **97.9** and **42.6**.

**3. World-only `{` textures from a WAD painted their keyed texels opaque black.**
`r_goldsrc_worldmask` drops the alpha test for a `{` texture no brush entity uses, matching
GoldSrc. It restored the colour only for **BSP-embedded** miptex (`gl_model.c:1758` rewrites
`TF_MIP4_8PAL24_T255`). A wad-resident texture never has `srcdata`, so it took
`W_ConvertWAD3Texture` instead, which zeroed RGB *and* alpha — with the discard now gone,
that is opaque black. `gl_model.c:1749` predicts this failure verbatim; it just could not
reach the decoder to prevent it. Not a corner: pizza_ya_san1 has **191 miptex and 0 with
embedded pixels**. The decoder now keeps the key colour and zeros only the alpha, which is
also what GoldSrc draws on a world face. Affects **6 of 145** Sven maps — `bm_sts`
(`{mo_fan1` 64% keyed, `{tension6` 69%), `hl_c02_a1`, `hl_c12`, `tf_original`,
`turretfortress`, `hc2_s2a`. Not pizza_ya_san1 or th_ep1.

**4. Latent: masked standalone uploads kept their atlas offsets.**
A masked texture is allocated an (x,y) slot in the shared atlas and then re-bound as a
*standalone* image, but `shaders[i].x/y` were left at the atlas slot while
`R_HL_BuildFrame` builds texcoords as `(texinfo->x + s) / boundtexture->width`. Correct
only when the atlas happens to place it at an exact multiple of its own size — which is why
power-of-two foliage has hidden it. Reset like the chrome branch already does.

### `r_texdiag` — new diagnostic

One line per world texture as a map loads: size, whether its pixels came with the BSP or
must be resolved from a wad, which shader it was given, and what the lump actually decoded
to (keyed %, surviving texel count, mean RGB/luma). Its own cvar, not `developer` —
`cfg/default.cfg` resets that after the command line. **It works headlessly**, so this
whole class of question is now one map load rather than a guess.

### Two things it immediately turned up, both needing Lex's eyes

- **`{blue` on pizza_ya_san1 decodes `keyed=100.0% visible=0`** — all 256 texels keyed, the
  GoldSrc "invisible but solid" idiom, on **492 worldspawn faces**. Because a brush entity
  also uses it, `Mod_MaskedTextureIsWorldOnly` bails and the *world* faces keep the mask, so
  all 492 are discarded and you see through the world there. GoldSrc masks per **entity
  render mode**, not per texture, so world faces should be opaque regardless. Fixing that
  needs a per-face decision (two shaders for one texture) rather than the current per-texture
  one — deliberately not attempted here.
- **`{BN_tree3` on th_ep1_01 renders black and the asset is why.** 256x256, 41.7% keyed,
  **38219 texels pass the alpha test and every one is black**: its palette in `neilm2.wad`
  has **1 of 256 entries non-black**, and that one is the blue key. It is the only copy on
  disk, and `{nm_they6` from the same wad decodes fine, so this is the texture, not the
  decoder — a black silhouette tree. Worth one look against Sven.

### Follow-up: `r_texdiag` printed nothing, and what the second round measured

The cvar prints from `Mod_FinishTexture`/`Mod_LoadHLModel`, i.e. **at map load**, so setting
it from the console after the map is up produces nothing — and FTE silently creates unknown
cvars, so there is no error either. Added **`r_texdiag_now`**, a command that walks
`mod_known` and dumps every loaded studio model's masked skins on demand. It has to be a
command: image uploads are asynchronous, so at model-load time `bound` is still `0x0` and the
one number worth reading does not exist yet.

**The headless harness cannot close this one.** The null renderer never uploads a texture and
never runs a fragment shader, so every headless run reports `bound=0x0` and no pixel is ever
shaded. Data going *in* is measurable; pixels coming *out* are not.

What the second round did establish:

- **`fern1.mdl` is not misconfigured.** `{shrub1.bmp` 512x512, **86.1% keyed** — it is a fern,
  mostly-transparent planes are the asset — palette healthy at 255/256 non-black, visible mean
  RGB **(96,95,75)** olive. Its 24 triangles span `s:0..511 t:4..511`, i.e. the whole skin, and
  the loader reports `uvbase=0,0 uvsize=512x512` matching source. Every foliage model on
  th_ep1_01 reports the same and **0 UV mismatches**. So "colour cut off horizontally" needs
  the `bound=` value from a real GL run.
- **`func_illusionary *247` (th_ep1_01) is in near-darkness.** `{ladder2` decodes to grey 150,
  but **3 of its 10 faces carry `styles=[255,255,255,255]` — no lightmap at all** — and the
  other 7 sit at lightmap luma **6–27 out of 255**.
- **21% of th_ep1_01's faces have no lightmap**: 3208 of 15263, including 53% of `nm_rock26`,
  76% of `nm_wall14`, 69% of `!nm_water3`. GoldSrc draws an unlit face **fullbright**. Whether
  FTE does is the open question, and it is a far bigger lever than any single texture.
  pizza_ya_san1 by contrast has only 2.6% unlit, all sky/aaatrigger, and `{stripeh` is 0/445.

Hypotheses eliminated this round, each by reading the shipped code rather than by guessing:
the `#MASKLT` arg (a valueless `#` arg *is* emitted as `#define MASKLT`, `gl_shader.c:2212`,
so the alpha test is **not** inverted); picmip (0 in every shipped cfg, so no rescale);
`Mod_LoadMiptex` supplying fallbackdata for wad-resident textures (guarded at
`gl_model.c:4313`); `decals.wad` being unreachable (Sven ships its own copy and it has the
lump); and the shipped `defaultwall`/`defaultskin`/`depthonly` MASK blocks, all three correct.

**Owed:** `r_fullbright 1` is the discriminator this time — it bypasses the lightmap outright,
so it separates "lit to near-zero" from "the texture/shader path is wrong". Plus one
`r_texdiag_now` + `condump` from in-game for the `bound=` numbers.

### Third round: `r_fullbright 1` does not fix it, so lighting is out

Lex ran it. **Nothing changed** — which eliminates the entire lighting hypothesis, including the
21%-unlit-faces lead above. Also reported: `func_door_rotating` **\*538** and **\*451** at the
start of th_ep1_01 show the same fault. All three reported brush entities measure identically:

| model | class | faces | textures | render keys |
|---|---|---|---|---|
| *538 | `func_door_rotating` | 6 | `nm_metal8` x4, **`{grate3a` x2** | mode 4, amt 255, colour 0 0 0 |
| *451 | `func_door_rotating` | 6 | `nm_metal8` x4, **`{grate3a` x2** | mode 4, amt 255, colour 0 0 0 |
| *247 | `func_illusionary` | 10 | **`{ladder2` x10** | mode 4, amt 255, colour 0 0 0 |

Only the `{` faces are wrong; the `nm_metal8` faces on the same brush are fine. So the fault
tracks the **masked texture**, not the entity, the render mode or the lighting. Verified the
CSQC path gives mode 4 a neutral tint (`cl_brushsync.qc:603-606` sets `colormod '1 1 1'`), so
that is not it either.

**The condump did turn up a real defect, just not this one.** Lex's decode lines disagree with
mine for the same texture on the same map and the same binary:

| texture | my run | Lex's run |
|---|---|---|
| `{ladder2` | keyed 56.2%, 448 visible, RGB(150,150,150) | keyed 66.0%, 348 visible, RGB(88,83,78) |
| `{grate3a` | keyed 41.0%, 2416 visible, luma 52.3 | keyed 32.6%, 2760 visible, luma 35.7 |
| `{icicle1` | keyed 63.0%, 1137 visible, luma 190.3 | keyed 68.3%, 975 visible, luma 185.2 |

Different keyed percentages are different pixel data, not gamma. Cause: **there are seven
copies of `{ladder2` on disk and the two `halflife.wad` files disagree** — `valve/halflife.wad`
has the light 32x32 at RGB(150,150,150), while `svencoop/halflife.wad` and `bshift/halflife.wad`
carry the darker CS-era one at RGB(88,83,78). Whichever wins the search path wins the texture.
Worth fixing on its own (a map should get the wad its author listed), but it cannot explain
black: **all 11 copies of `{stripeh` on disk are byte-identical near-white**, so there is no
wrong-copy story there.

### Positive control added — `r_maskdebug`

Every input has now been measured correct: wad decode, palette, embedded-palette validation,
shader selection, `#define MASK`/`MASKLT` emission (`gl_shader.c:2212` — a valueless `#` arg
*is* emitted, so the test is not inverted), colormod, lightmap, and `r_fullbright`. They still
draw black. Reading further is guessing, so the mod GLSL now carries a positive control:

`r_maskdebug 1` + `vid_reload` paints every alpha-tested **world** surface MAGENTA
(`defaultwall.glsl`) and every masked **studio skin** GREEN (`defaultskin.glsl`), ignoring
texture and lighting entirely. Two outcomes, and they split the whole remaining space:

- **turns magenta/green** — the surface rasterises and survives the alpha test, so the fault is
  in `col.rgb`, i.e. between the verified-correct texture data and the fragment.
- **stays black** — the surface never reaches the fragment shader at all, and the black is the
  void behind it. The fault is then upstream: batching, sort order, or the discard.

GLSL only, so no engine rebuild — the shipped exe already works with it.

### Fourth round: the control came back GREEN and MAGENTA — and that found the model bug

Lex ran it: masked model skins paint **green**, `func_*` brush surfaces paint **magenta**. So
every one of these surfaces **rasterises and survives the alpha test**. Nothing is being
discarded, nothing is missing from a batch, and the black is not the void behind it. The fault
is in `col.rgb`. That single answer eliminated the entire upstream half of the problem.

The `r_texdiag_now` dumps confirmed the other half. **All 16 masked studio skins report
`bound == src` and `uvbase=0,0`, with zero real mismatches** — the skin is the right image at
the right size and the texcoords are exact. (The 1743 "UV MISMATCH" lines in the dump are a bug
in *my* check, not the engine's: for **atlased** skins `bound` is legitimately the atlas, e.g.
2048x2048, and `uvbase` its slot offset. The flag is only meaningful for standalone masked and
chrome skins, and none of those are mismatched.)

**MODELS — found and fixed.** `defaultskin.glsl` computed vertex lighting as

```glsl
float d = dot(n, e_light_dir);
if (d < 0.0) d *= 13.0/44.0;   // glquake anorm_dots.h fudge
light.rgb += d * e_light_mul;  // d is NEGATIVE here, and added UNCLAMPED
```

so any surface angled away from the light lands at `e_light_ambient - 0.295*e_light_mul`, which
goes **negative and clamps to pure black** wherever the entity's ambient sample is low. Foliage
cards are double-sided with opposing normals, so this blacks out **half the planes of every bush
and fern** while the other half lights correctly — exactly the reported "only 2 faces out of the
8 have colour", and exactly why it survived every texture-side fix: the skin was never the
problem. It also explains why `r_fullbright 1` changed nothing on the trees — **that cvar fills
the world lightmap (`r_surf.c:1493`) and does not touch model lighting at all**, so it never
tested them.

GoldSrc's `R_StudioLighting` instead uses `illum = ambient + shade*(1 - max(0,(lightcos+(r-1))/r))`
with `r = lambert = 1.5`, which never falls below ambient and has a much flatter mid-range.
Reproduced verbatim behind `r_studio_lambert` (default 1.5; **0 restores the old behaviour**).
It can only brighten: identical at `d=1` and `d=-1`, `>=` between them.

**WORLD — narrowed, not yet solved.** `{stripeh`, `{ladder2` and `{grate3a` paint magenta, so
they draw; their `col.rgb` is black for a different reason (lightmap chain, not model lighting).
`r_maskdebug` gained two more modes to split it: **2** = the raw diffuse texel with nothing
multiplied in, **3** = `col / rawdiffuse`, i.e. only what the lightmap, colormod and the four
shadow terms did to it. One look at each names the term.

### Fifth round: trees CONFIRMED FIXED, and the flashlight leak the fixes exposed

**The lambert fix works** — Lex confirms `r_maskdebug 0` renders the trees correctly. The model
half of this report is closed.

**`r_maskdebug 2` is not a fix, it is the diagnosis.** It shows the raw diffuse with all lighting
removed, so "the doors and ladders look fine" proves two things and grants nothing: the bound
image is correct (as the wad decode always said), and the blackness is **entirely in the
multiplier**. Shipping it would leave every masked world surface fullbright in dark rooms.

**FLASHLIGHT — found and fixed.** `rtlight.glsl` had **no MASK handling at all**: it samples
`s_diffuse` and never discards on alpha. The engine made that unreachable anyway —
`gl_shader.c` registered the rtlight bemoverrides **only for tessellated shaders**, so an
alpha-tested surface lit by a dlight got a plain `rtlight` program with no discard, and the
additive pass deposited light across the whole quad including the keyed-out texels.

That leak is old, but it was **invisible while those texels were pure black** — adding light to
black adds nothing. Both halves of Patch 171 gave them a real colour (the wad decoder keeps the
GoldSrc key colour; `Image_BleedTransparentRGB` fills studio skins from their neighbours), so
the pre-existing bug surfaced the moment they were fixed: a **blue** hue on keyed brush faces
(the key colour is usually 0,0,255) and a **colour smear** across foliage cards, both only under
a dlight and worst at grazing angles where the light covers most of the surface. Fixed on both
sides — the engine now derives `mask` once and passes it to the rtlight overrides beside the
depthonly one, and `rtlight.glsl` discards on the same MASK/MASKLT convention.

**Still open:** the world masked surfaces are multiplied to black by something in the lightmap
chain. `r_maskdebug 3` on pizza_ya_san1 names it.

### Sixth round: why the flashlight fix landed on models but not on brushes

Lex confirms trees **and** their flashlight smear are fixed, but `func_*` brushes kept the blue
hue. The reason is a second, separate defect in the same helper.

`Shader_AlphaMaskProgArgs` derives the mask **only** from `passes[0].shaderbits`. Studio models
have a real pass — `HLSHADER_MASKED` writes `"alphaFunc GE128"` — so they matched, and every
override they spawn (depthonly, and now rtlight) got a mask. But the GoldSrc **world** shader
has no pass at all:

```
{ fte_program defaultwall#MASK=0.666#MASKLT }      // Shader_DefaultBSPQ1
```

Its alpha test lives purely in the program args, so the helper returned `""` for **every masked
GoldSrc world texture** — meaning neither the depthonly nor the rtlight override has *ever*
carried a mask for brush/world surfaces. That is precisely why one fix landed on trees and not
on ladders, and why the two were reported as separate bugs for weeks. Now recovered from
`s->prog->name` (rebuilt from the parsed values rather than returned as a substring, so
unrelated args like `#usemods` — which sets `calcgens` — cannot leak into the override), and
copied into a stack buffer because the rtlight loop calls `va()` once per lighting mode and
would otherwise recycle it mid-loop.

### Seventh round: modes 4/5 localise it to the lightmap, and one hypothesis A/B-disproved

Lex measured on pizza_ya_san1: **mode 5 (e_colourident) = WHITE**, **mode 4 (the lightmap term)
= BLACK**. So the entity tint is fine and the lightmap term is the only zero — the remaining
world fault is `lightmaps.rgb`, nothing else.

**Hypothesis raised and then disproved by A/B test.** The `{` world shader has no passes
(`{ fte_program defaultwall#MASK=0.666#MASKLT }`) while every working wall shader has
`{ map $diffuse }`; `Mod_LightmapAllocSurf` (`gl_model.c:3768`) denies a lightmap to any surface
whose shader lacks `SHADER_HASLIGHTMAP`, and that flag comes from passes. It fit perfectly.
**It is wrong.** Built both forms and measured: with *and* without the pass, `{` textures report
`lm=1 passes=3`, identical to `nm_metal8`/`nm_rock2` — the passes are synthesised from the
program's declared samplers at `gl_shader.c:6245`, not from the script. The change was reverted
rather than shipped, and a note left in place so it is not tried a third time.

Two further eliminations from the same round:

- **The surfaces are not denied lightmaps at all.** A new `r_texdiag` print in
  `Mod_LightmapAllocSurf` names every denial and its reason: on pizza_ya_san1 the only denials
  are `sky` (drawsky/tiled=1, texspecial=1). **No `{` texture is ever refused.**
- **`e_lmscale` cannot be the zero.** For lightstyle 255 the backend falls back to
  `identitylighting` for index 0 rather than zeroing it (`d3d11_backend.c:3090-3101`); only
  indices 1..3 go to zero.

So the lightmap is allocated, the shader is flagged, the scale is non-zero, and the sample still
comes out black. Added **mode 6** = the lightmap term amplified 20x, because "black on screen"
covers both an exact zero (nothing bound) and "lit to 0.5%", which have entirely different
causes and are indistinguishable by eye.

### Ninth round: the SAME model black on one class and correct on another — ambient is zero

Lex found `item_generic` using `models/hunger/vegitation/tree1.mdl` still showing black planes
while `monster_furniture` using **the same model** is fixed. Same model, same skin, same shader,
different entity class — so it was never the texture or the lambert falloff.

**`item_generic` DROPS TO FLOOR** (`sv_item_generic.qc:137-205`); `monster_furniture` is left
where the mapper put it. A dropped prop ends up with its origin *in* the ground, where
`R_SampleModelLight`'s sample fails and returns **zero**. The lambert fix guarantees
`light >= e_light_ambient` — which is the correct GoldSrc rule — but when ambient is itself zero
that floor is zero, so every face angled away from the light still lands on precisely black. On
double-sided foliage cards that is half the planes.

The knob for this **already existed and was shipped off**: `r_prop_minlight`, "minimum ambient
brightness ... so they never sit pure black in shadow. Opt-in (default 0)"
(`gl_alias.c:1593`), floors both the flat and directional terms for non-player, non-viewmodel
models. `cfg/default.cfg` set it to 0; now **0.08**, between FTE's own viewmodel floor
(24/255, "viewmodels may not be pure black", `gl_alias.c:1499`) and GoldSrc's model viewer
(`g_ambientlight = 32`). No engine change.

Note this is a *different* fault from the sun form-shade floor documented at `default.cfg:302`,
which was the same visible symptom ("some faces well lit, some black silhouettes") reached by a
different route — that one multiplies by zero *after* the ambient term; this one is the ambient
term being zero to begin with. Fixing either alone leaves the other.

### Eighth round: a true zero, and a flaw in the probe itself

**Mode 6 (lightmap x20) is still black**, so the lightmap term is an *exact* zero, not "lit to
0.5%". Lex also reports that a flashlight at an angle **does** reveal the texture on these
faces — which independently confirms the diffuse is correct and the rtlight path works, and that
the base pass's lightmap term is the only thing at fault.

**Answering the question directly: no, these are not meant to be fullbright.** In GoldSrc a `{`
texture on a world or brush face is lightmapped exactly like any other. `r_maskdebug 2` looks
right only because it is unlit; shipped, those surfaces would glow in every dark room. Not taken.

**A flaw in the probe, found before drawing another conclusion from it.** Modes 2-6 were inside
`#if defined(MASK)`, so every reading ever taken came from a masked face with nothing to compare
against. "Mode 4 is black" therefore had two readings needing opposite fixes — *the lightmap is
broken for masked faces*, or *this probe reads the wrong thing and is black everywhere* — and
the probe could not tell them apart. Moved out to run on every world surface, so a masked face
and the ordinary wall beside it are shaded by the same code and readable in one screenshot.
th_ep1_01's `func_door_rotating` **\*538** is the ideal subject: four `nm_metal8` faces and two
`{grate3a` faces on the same brush under the same light.

Also eliminated this round: the `tcgen`/pass theory. For an `fte_program` shader the script's
passes are discarded outright — `s->numpasses = s->prog->numsamplers` (`gl_shader.c:6238`)
overwrites them before the sampler-derived passes are appended — so the `{` shader and an
ordinary wall shader end up with **identical pass sets**, differing only in the MASK defines.
That is also why adding `{ map $diffuse }` changed nothing.

**Mode 3 came back black**, which confirms the remaining world fault is entirely in the
multiplier — `{stripeh`'s texture is right and something zeroes what it is multiplied by. Added
**4** (the lightmap term alone) and **5** (`e_colourident` alone) to name which; mode 3 being
black is explained by exactly one of them. `defaultskin` now only paints green for mode 1, so
models stop obscuring the map during the world probes.

### Tenth round: measured, not inferred — the lightmap is BRIGHT, not black

Lex confirms **`r_prop_minlight 0.08` fixes the models**; the `item_generic`/`monster_furniture`
divergence is closed. He also reports the `*538` doorway is too dark to judge by eye, but that
**the metal sides light up with the flashlight while the `{` part only lights at an angle**.
"Black head-on, visible at a grazing angle" is backwards for any diffuse term, so the remaining
work stopped being visual and became measurement.

**Three new engine diagnostics**, all additive, all usable headlessly:

* **`r_lightstyles [all]`** (`gl_rlight.c`) — every lightstyle's live value, and crucially whether
  it was ever *sent*. `d_lightstylevalue` is a zeroed global and `R_AnimateLight`'s
  "unset style reads as normal (264)" fallback only runs for `j < cl_max_lightstyles`, which grows
  solely as styles are received. So a style nobody announced is **0 and black**, not bright — and
  that is invisible from the map, the texture and the shader alike.
* **`r_surflm <model> [texture]`** (`gl_model.c`) — per surface: kept styles, lightmap page,
  `light_s/light_t`, luxel extent, whether bsp samples exist, and the **mean/peak of the texels
  `Surf_BuildLightMap` actually wrote**. This is the ground truth that no shader probe could reach.
* **`r_shaderpasses <name>`** (`gl_shader.c`) — the *resolved* passes: `texgen`, `tcgen`,
  `shaderbits`, sort, and whether `SHADER_HASLIGHTMAP` survived.

Plus a headless rig: `map` is deferred on the command line and `mod_batchlist` isn't registered
until `Mod_Init(false)`, so both are sidestepped with the `in <seconds> <command>` timer
(`cmd.c:264`). `c:\tmp\batchdump.sh`.

**What the measurements killed.** Each of these was a live hypothesis and each is now dead:

| Hypothesis | Measurement | Verdict |
|---|---|---|
| Switchable lightstyles never announced | `r_lightstyles`: style 32 = **264 "m"**, style 47 = **264 "m"** | dead — QC `light` works |
| `lmlightstyle` scales `e_lmscale` to zero | `mod_batchlist`: both batches `lm=399`, both `INVALID_LIGHTSTYLE` | dead — identical to the working metal |
| The masked face has no lightmap | `r_surflm`: `{grate3a` `lm=399`, `{stripeh` `lm=0` | dead — it has one |
| The lightmap data is black | `r_surflm`: grate **mean 140 peak 162**, stripeh **mean 190-229 peak 249-255** | dead — it is the *brightest* thing there |
| `VERTEXLIT` fallback reading unbound `v_colour` | `VERTEXLIT` is baked at registration (`gl_shader.c:7518`), not a runtime bit | dead |
| `SHADER_HASLIGHTMAP` denied (retested properly) | `r_texdiag` denials are only `white`/`!waterblue#LIT`/`black`/`aaatrigger`/`sky` | dead — `{` shaders keep it |

**So every input the shader consumes is correct and bright, and the shader still reads exactly
zero.** That moves the fault off the data entirely and onto what the batch *binds or emits* at
draw time for this shader specifically.

**Two real findings on the way:**

* `bound(64, width, sh_config.texture2d_maxsize)` collapses to **0** when the backend reports no
  texture size limit, because `bound` returns the max for any value >= the min. A zero-sized
  allocator then fails `smax > lmallocator->width` for *every* surface and the whole world
  silently loses its lightmaps. Harmless in the real renderer (the limit is non-zero) but it made
  the first headless readings say "418/418 `{stripeh` faces denied a lightmap", which was a lie.
  Now treated as "no limit". **This is why a headless lightmap reading was untrustworthy before.**
* `light_spot` and `light_environment` are empty stubs (`sv_goldsrc_compat.qc:182-183`), so their
  styles are never announced — on th_ep1_01 styles **37/38/39** sit at `256 ""`, never sent. No
  face on the problem doors uses them, so this is *not* the bug, but any face lit only by a
  `light_spot` is black by the mechanism above. Worth fixing separately.

**Also measured:** the four `styles=INVALID` faces on `*538` (3 metal + 1 grate) build to a
legitimate mean 0 — hlrad gave them no lightstyle at all. Those are unlit back-faces and are
*meant* to be black; the dark doorway made them easy to mistake for the bug.

**Still open, and now sharply scoped.** Headless can't finish this: the null renderer has no
programs (`r_shaderpasses` reports `prog=<none>`), so the pass layout it prints is the
fixed-function fallback, not the one that actually runs. What it *did* show is renderer-
independent and suggestive: `{grate3a` and `{ladder2` sort **SEETHROUGH (7)** where `nm_metal8`
sorts **OPAQUE (5)**, and the masked shaders put the diffuse pass at index 0 while the ordinary
wall puts the lightmap pass there. Needs one `r_shaderpasses` run in the real client.

Probes **7-11** added to `defaultwall.glsl` to split the product the earlier modes only ever read
as a whole: **7** = is this surface `VERTEXLIT` (red) or lightmapped (green), self-luminous so it
reads in a pitch-dark doorway; **8** = the vertex colour; **9** = the raw sampled lightmap texel
at 20x *without* `e_lmscale`; **10** = `e_lmscale` alone; **11** = the lightmap texcoord as a
gradient, which separates "the atlas texel is black" from "`lm0` is degenerate".

### Eleventh round: SOLVED — a deluxemap modulation on maps that have no deluxemaps

The black masked world surfaces were never a lightmap bug, a texture bug, a lightstyle bug or a
masking bug. `defaultwall.glsl` was multiplying the finished lightmap by a **deluxemap dot product
on maps that contain no deluxemaps**, and that dot came out negative.

**How it was actually found.** Every previous round reasoned about the lightmap and every one was
wrong. What settled it was splitting a single product into its factors and reading them separately
in one session, with `r_maskdebug` modes added for exactly that:

| probe | reads | result on the black face |
|---|---|---|
| 9  | `texel * 20`, **e_lmscale removed** | WHITE |
| 10 | `e_lmscale` alone | WHITE |
| 11 | `lm0` as a gradient | correct ramp |
| 6  | `lightmaps * 20` (the stored product) | **BLACK** |
| 16 | the same product **recomputed at the point of use** | WHITE |
| 15 | permutation report: BUMP / DELUXE / SPECULAR | **YELLOW = BUMP+DELUXE**, world black |

9 and 10 bright with 6 black is arithmetically impossible unless something mutates `lightmaps`
between its computation and its use. 16 vs 6 proved that it does; 15 named the mutator.

**Root cause.** `r_deluxemapping` is a RENDERER CAPABILITY flag, read straight off the cvar at
renderer init (`gl_draw.c:546`) and defaulting to 1. `gl_shader.c:1620` injected `#define DELUXE`
into any shader whose texture merely had a normalmap, with no reference to map contents — the
comment there was literally `//fixme: should be per-model really`. On a map with no deluxemap lump
`defaultwall.glsl:456-467` then ran

```glsl
lightmaps *= 2.0 / max(0.25, deluxe.z);
lightmaps *= dot(norm, deluxe);
```

against the placeholder `missing_texture_normal` that `gl_backend.c:1365` binds when a page has no
deluxe. With a degenerate normalmap `norm` is `normalize(vec3(0)-0.5)`, whose dot with a `(0,0,1)`
deluxe is **-0.577** — and a negative lightmap clamps to pure black. Half-Life BSPs never carry
deluxemaps, so this hit every GoldSrc world texture that had a normalmap.

That single mechanism explains **every** symptom, including the ones that misdirected six rounds:

* Pure black rather than dim — a negative multiply, not a small one.
* `r_fullbright` no help — it fills the lightmap, which was never the problem.
* Lightmap probes always healthy (`r_surflm` means 140-229) — the lightmap *was* healthy.
* Only a flashlight ever lit it, and seemingly "from an angle" — the rtlight pass is **additive**
  and has no deluxe term, so it was the only path that could put colour on the surface at all.
* Masked-only — `{` textures were the ones carrying normalmaps here, nothing to do with masking.

**Fix (two parts).**
1. `gl_shader.c` — gate the define on the loaded world actually having deluxemaps:
   `if (r_deluxemapping && cl.worldmodel && cl.worldmodel->lightmaps.deluxemapping)`.
   Only the DEFINE is gated, deliberately **not** the `!!samps =DELUXE deluxemap` declaration at
   `Com_PermuOrFloatArgument:1688` — suppressing the sampler too would change `numsamplers`, hence
   the synthesised pass list and every texture binding index after it. Leaving it declared but
   unused costs one ignored uniform and keeps the pass layout byte-identical.
2. `defaultwall.glsl` — `lightmaps *= max(dot(norm, deluxe), 0.0)`. Light cannot be negative. This
   is belt-and-braces so a map that genuinely HAS deluxemaps but ships a bad normalmap degrades to
   unlit instead of to a black hole.

`r_deluxemapping 0` is a valid workaround but is NOT the shipped fix — it would also disable
deluxemaps on maps that legitimately have them.

**Diagnostics added this patch, all additive and worth keeping:** `r_lightstyles [all]`,
`r_surflm <model> [texture]`, `r_shaderpasses <name>`, and `r_maskdebug` modes 7-16.

**Wrong turns, recorded so they are not retried:** unannounced switchable lightstyles (measured 264);
`e_lmscale` scaled to zero (measured white); no lightmap page (a denied lightmap binds
`r_whiteimage` and renders WHITE, `gl_backend.c:1355`); `SHADER_SORT_SEETHROUGH` (a headless
artefact — it is sort 5 in the real renderer); `tcgen` on the synthesised lightmap pass (identical
on the working shaders). Also note the null renderer takes a **different `{` shader branch**
(`gl_shader.c:7441` is gated on `sh_config.progs_supported`), so headless cannot reproduce this
class of bug at all.

### Twelfth round: the TRUE origin — my own `{` rescue was too broad

The DELUXE fix above is correct and stays, but it treats the symptom. The **origin** is a bug
introduced earlier in this same patch.

`image.c` gained a rescue this session: a masked texture that resolves from no wad and no
replacement is drawn as a 1x1 transparent texel rather than as `missing_texture` (th_ep1_01's
`func_wall *130` is five faces of `{invisible`, a lump whose 256 texels are all index 255). It was
keyed on `tex->ident[0] == '{'`.

But `R_BuildLegacyTexnums` builds every SECONDARY map's identifier by **appending** a suffix to the
diffuse name — `gl_shader.c:6799` `_pal`, `:6819` `_norm`, `:6843` `_gloss`, `:6851` `_reflect`,
`:6867` `"%s_luma:%s_glow"`. So `{grate3a` also asks for `{grate3a_norm`, `{grate3a_pal`,
`{grate3a_gloss`, `{grate3a_reflect` and `{grate3a_luma` — **every one of which also starts with
`{`**, and every one of which was therefore rescued into a valid 1x1 transparent image instead of
being allowed to fail.

`TEXLOADED()` then reported true for bump, fullbright, specular and reflectmask on every masked
texture in the map **and on nothing else**. The phantom normalmap is the fatal one:

```
{grate3a_norm rescued -> TEXLOADED(bump) -> PERMUTATION_BUMPMAP (gl_backend.c:4304)
   -> "#define DELUXE" (gl_shader.c, r_deluxemapping defaults 1)
   -> norm = normalize(vec3(0)-0.5) = (-0.577,-0.577,-0.577)
   -> lightmaps *= dot(norm, deluxe) = NEGATIVE -> clamped to PURE BLACK
```

That is the entire "masked world surfaces render black" bug, end to end, and it also explains the
`FULLBRIGHT` permutation that `r_maskdebug 14` found on `{` surfaces and nowhere else.

**My TF_TRANS8_FULLBRIGHT theory was wrong** and is recorded here so it is not retried:
`image.c:13245` already excludes index 255 as the FIRST clause of its fullbright test
(`if (rawdata[i] == 255 || rawdata[i] < 256-vid.fullbright) rgbadata[i] = 0;`), and
`gl_shader.c:6861` refuses to pass `srcdata` at all unless the palette is `host_basepal`, which is
never true for an HL texture carrying its own WAD3 palette.

**Fix:** `Image_IsSecondaryMapIdent()` in `image.c`, and the rescue now reads
`if (tex->ident[0] == '{' && !Image_IsSecondaryMapIdent(tex->ident))`. It handles the
`"%s_luma:%s_glow"` alternation by testing only the first alternative. Stringly-typed on purpose:
the exact alternative is a new `IF_` flag threaded through five `tex->base` call sites, and the
worst case of a false positive here is one texture drawing as *missing* rather than as *nothing*.

### Thirteenth round: func_door_rotating mispredicted close — and it is NOT the "One Way" flag

**Reported:** a one-way `func_door_rotating` snaps shut for one frame and then acts buggy when
walked into.

**The premise was wrong, and the map proves it.** Parsing th_ep1_01's entity lump for every
`func_door_rotating`:

```
spawnflags=0    wait=-1  count=1   bits: none          <- stays open, NO One Way flag
spawnflags=512  wait=-1  count=1   bits: TOUCH_ONLY    <- same
spawnflags=16   wait=-1  count=2   bits: ONE_WAY
spawnflags=528  wait=-1  count=3   bits: ONE_WAY|TOUCH_ONLY
...
```

Twelve of sixteen doors are `wait -1`, **none** sets TOGGLE (32), and **three carry no One Way flag
at all**. `DOORROT_ONE_WAY` (16) is HL's `SF_DOOR_ONEWAY`, referenced in `halflife/dlls/doors.cpp`
at exactly one site (`:590`, inside `DoorGoUp`) purely as a swing-DIRECTION restriction. What makes
these doors one-shot is `wait -1`: `rotdoor_hit_top` (`sv_doors_rotating.qc:696`) returns without
scheduling `rotdoor_go_down` when `wait < 0`. Gating on One Way would have fixed 9 of 12 doors and
wrongly gated the other 3.

**Root cause:** `CSQC_PredictMoverActivate` (`cl_brushsync.qc:993+`) predicted TOP -> DOWN for any
`BRUSH_TYPE_DOOR`, excluding only buttons. The server closes from TOP **only** for TOGGLE doors —
`rotdoor_use:906` and `Door_ActivateSingle` (`sv_doors.qc:1063`). The TOGGLE bit was never
networked, so CSQC could not tell a TOGGLE door from a `wait -1` one.

Symptom mechanism: the mispredicted rotation is frozen after ~0.05s by the lookahead cap in
`CSQC_SolidBrush_Predraw` (`cl_brushsync.qc:185`) — the one-frame close; the server's refusal dirties
no `SendFlags` so no correcting snapshot ever arrives; and the replica keeps a non-zero `avelocity`
on the rotating-brush list, so `PM_CheckRotatingCarry` keeps shoving anyone who walks into it.

**Fix:** one extra wire byte. `sv_brushsync.qc` forward-declares `.door_flags` (same pattern the file
already uses for `.door_movement_done`, since `sv_doors.qc` compiles later) and writes
`(self.door_flags & 32) ? 1 : 0` after `predict_block`; `cl_brushsync.qc` decodes it into
`.door_toggles` and returns early from the TOP branch unless it is set. Buttons never write
`.door_flags`, so it reads 0 for them, which is what CSQC already wants.

Rejected: folding it into `predict_block`, which also gates cone-fallback selection at
`cl_brushsync.qc:1055` — making it state-dependent would have the client's cone skip a parked-open
door the server's cone still selects, mispredicting a *different* nearby door.

### Fourteenth round: four reported issues

**1. Cockroach blood splat intermittent.** The reported guess (raise the downward trace) is wrong -
`mon_cockroach.qc:147-148` is byte-for-byte HL's `CRoach::Touch` (`roach.cpp:96-97`): same `+8` start,
same `-24` length, same ignore mode, and the origin is at the feet in both. The real cause is
client-side: `Impact_SpawnParticles` (`cl_bulletimpact.qc:201-206`) returns early on
`impact_per_shot_effect_count >= cl_impact_effects_per_shot` (default 3), and
`CSQC_SpawnBloodDecals` sits BELOW that return at :223-224. The counter is a free-running global
incremented by every impact effect but reset only by `CSQC_Impact_ResetShot`, whose five call sites
are all the LOCAL player firing. A squash is a shooterless server event, so it just inherits
whatever budget your last trigger pull left - a splat on the first up-to-3 squashes after a shot,
none after a shotgun blast spends it all. It still SOUNDED right because `rch_smash` is played
server-side unconditionally and the flesh ping fires outside the capped function.
**Fix:** reset the budget for shooterless impacts in `CSQC_BulletImpactRemote`. Also un-caps monster
gunfire and other players' impacts, which were silently limited the same way.

**2. HL model faces stretched (pizza shop owner limbs, scientist foot sole).** Not a scale bug -
`texscale` is already a correct vec2, and the atlas offset math is self-consistent. It is texel
CORNER sampling: `texbase + s*texscale == (x + s)/W`, so `s=0` lands exactly on the slot seam, and
the studio atlas (`gl_hlmdl.c:672-750`) packs slots with NO padding, making that tap a 50/50
bilinear blend with the NEIGHBOURING SKIN. Severity scales with how few source texels a mesh spans,
which is why it is per-mesh and reads as "only some faces".
Measured: `owner_shin.mdl` (the pizza shop owner) paints both legs and both arms from
**`black.bmp`, a 4x8 swatch**, packed beside `main.bmp` (248x253) - so half of every limb pixel was
the neighbour. `scientist.mdl`'s `Sci3(Shoe).bmp` is 68x29 with the sole's verts at t=0 and t=1.
**Fix:** clamp texcoords to the slot interior (`x+0.5 .. x+w-0.5`) at the vertices - a triangle's
interpolated st is a convex combination of its vertices, so it cannot escape that range. Standalone
uploads (chrome / DM_Base / masked) are left alone so deliberate tiling still works.
`r_2d.c` has always done this correctly (pad by one, `(x+0.5)/width` - r_2d.c:523, 528-529, 618).

**3. GoldSrc water: `r_wateralpha_extendpvs` inert, alpha water shows out of the map.** One cause,
both symptoms. `r_surf.c:3099` auto-enables the temporal scene cache when the world has >6000 leafs
(th_ep1_00 = 2452, works; **th_ep1_01 = 7328, dead**). The cache branch then RETURNS at :3324 before
`model->funcs.PrepareFrame`, and `Q1BSP_MarkLeaves` is the only place `r_wateralpha_extendpvs` is
read AND the only place the fluid PVS merge happens. So the cvar does nothing, and the leafs behind
the water are missing while the water is still drawn `sort underwater` with a blendfunc - blending
over an unpainted framebuffer. `q1bsp.c:2079` already documented this trap and said it had to be
fixed in `r_surf.c`.
**Fix:** force the cache off when `r_wateralpha_extendpvs` is on and `r_wateralpha < 1` on q1/hl
maps. **This costs the cache's FPS win on big maps** - `r_wateralpha_extendpvs 0` gets it back.

**4. NPCs not aggressive enough.** Two mechanisms, both real:
 - `TASK_GET_PATH_ENEMY` (`sv_ai_core.qc:1943`) fired an async nav request and parked the schedule
   on `time + 2` - the monster stood still for up to two seconds at the start of every chase leg.
   HL's `TASK_GET_PATH_TO_ENEMY` is synchronous (`schedule.cpp:990-1014`). Compounding it,
   `AI_PathRequest` returns BEFORE assigning `ai_goalpos` when its repath throttle refuses
   (`sv_ai_move.qc:561-589` vs the assignment at :591), so the chase goal was up to 1.0s stale -
   ~320 units at player run speed. HL's `FRefreshRoute` has no throttle.
   **Fix:** complete the task immediately and restate the goal.
 - `sv_ai_range_cadence` (default 1) added up to 0.8s of distance-scaled cooldown, and because it
   feeds `ai_nextattack` it SUPPRESSES `COND_CAN_RANGE1` itself (`sv_ai_core.qc:664`) rather than
   just delaying the shot - diverting shooters into `SCHED_COMBAT_FACE` instead of firing.
   **Fix:** default 1 -> 0. The cvar's own comment already says "0 is exactly Half-Life".
 - **NOT applied, deliberately:** HL's BuildRoute order (try a straight `CheckLocalMove` before the
   node graph, `monsters.cpp:1535-1590`). `sv_ai_move.qc:771` gives stored waypoints unconditional
   priority, which is the remaining half of the indirect-approach complaint. It is a bigger change
   to movement with real regression surface (monsters cutting across cover, grinding into walls
   below ledges) and is held back so a regression stays attributable.
 Attack constants were checked and are NOT at fault: conditions gather every 0.1s, COND_ATTACK_READY
 is already a chase interrupt, and melee ranges are 70 vs HL's 64.

### Fifteenth round: two confirmed fixed, and three theories killed by measurement

Reported back: roach splat **fixed**; pizza shop owner **fixed**; scientist shoes **not** fixed
(they are `models/hunger/scientist.mdl`, not the stock rig); water **still** not fixed; "do the
last change" on the NPCs; plus a new report of *"the water will create inside faces which all have
solid nodraw textures, flickering with other world surfaces"*.

**A. The NPC change that was held back is now in.** `AI_LocalMoveClear` (`sv_ai_move.qc`) is HL's
`CheckLocalMove`: step along the 2D line in increments, and at each step require both a clear
forward move (flat first, step-up only if that is blocked - `SV_movestep`'s order) *and* ground to
land on. `AI_PathRequest` tries it before touching the nav queue, exactly as `BuildRoute` does
(`monsters.cpp:1535-1590`), and grants `ai_directmove` for 0.6s; `AI_MoveAlongPath` consults that
before `AI_HasPath`, so a stored route is stepped over rather than freed and nothing has to reason
about nav-slot ownership. HL's `LOCALMOVE_INVALID_DONT_TRIANGULATE` guard is copied too - a ground
goal more than 64 units above or below goes straight to the graph, which is the "player on a ledge"
case. Behind `sv_ai_directmove` (default 1) so a regression stays attributable, and the
`[ai] route: direct= nodefall=` counter says how often it fires.
The step loop shortens its final step to land on the goal, so it carries a hard iteration guard:
once `dist-travelled` is small enough that `travelled+step == travelled` in single precision the
counter stops advancing, and that is a hung server rather than a bad route.

*Measured, and it caught my own bug.* First build shipped `direct=0` on both a tight map and an
open one, so the counters were split by refusal reason. th_ep1_01: `wall`, at a mean of **step 5**
(~120 units in), `solid=0` - the test was working and the map is simply cramped, which is what HL
would do too. desertcircle: **every refusal was `far`** (`far=8` of `nodefall=8`) - the 1024-unit
cap. That cap came from HL's `monsters.cpp:1327-1339`, which is **commented out**: 1024 is a limit
Half-Life does not apply, and copying it switched the feature off precisely where it helps most.
Raised to 2048, and the cost it was meant to bound is handled properly instead - the stride widens
on long lines so the walk is at most `AI_LOCAL_MAXSTEPS` (64) steps whatever the distance. At the
cap the stride is 32, i.e. the hull width: the sweep still cannot miss an obstacle (tracebox sweeps
the whole box), only the FLOOR sampling coarsens, and a gap narrower than the monster is one it
could straddle anyway. Average cost stays low because a blocked line fails at the first
obstruction; only a line that stays clear pays for the full walk, and that is the one worth having.
Also hardened: `AI_PathBlocked` now bars a new straight line for 3s (`ai_nodirect`). The local-move
test traces `MOVE_NOMONSTERS` - deliberately, so a crowd converging on one player does not push all
of them onto the graph - which means the one obstruction it cannot see is another monster, and
without the bar a monster blocked by its squadmate is re-granted the same still-"clear" line every
0.25s forever.
Final verification run, th_ep1_01 with two bots, 22 debug windows: **98 path requests, 2 granted a
straight line, 88 refused by geometry** at a mean of 4.5 steps (~110 units), and **far=0 zgate=0
ledge=0 solid=0** - i.e. every refusal was a real wall and not one of the guards misfiring. No
errors. 2-in-98 is the right order for a cramped They Hunger interior; the ratio is what
`[ai] route:` exists to report, so if it stays at zero during real combat that is the signal.

**B. Scientist shoe: the seam theory is DEAD for it, measured.** Replicated FTE's atlas packing
(`Mod_LightmapAllocBlock`, no padding) against the real file: `Sci3(Shoe).bmp` is 68x29 at slot
(124,0), touching `Sci3(L-Leg)` left, `Sci3(Chest)` right and `Sci2_Hd-Side` directly below at
(124,29). Then the mesh: `Headless_Body#2` spans **s 0..66, t 0..26 of a 68x29 slot** - it never
reaches the right or bottom boundary at all, and the sole's own triangles (the two 395- and
266-texel ones) sit at s 10..51, t 3..26, **entirely interior**. So the vertex clamp shipped last
round cannot have fixed the sole, and nothing about seam bleed can explain it.
What is left is **mip bleed**, which a texcoord clamp cannot touch: the atlas is 1024x1024 with 11
mip levels and is uploaded with no `IF_NOMIPMAP`, so at mip 4 a 68x29 slot is 4x1 texels and by mip
5 its colour is entirely its neighbours'. A dead body's shoe sole is small and distant - exactly
where a high mip is selected. That also explains the split result: the pizza owner's `black.bmp` is
4x8 with UVs 0..1, i.e. dominated by the seam (fixed), while the shoe spans its slot and is
dominated by the mip.
**Fix, two halves:** every slot now gets a **one-texel gutter of its own replicated edge** (what
`r_2d.c:523` has always done), and the atlas is uploaded **without mipmaps**. `r_hlmdl_atlasmips 1`
restores them - which is also the A/B test for whether a given artefact is this at all. Cost of the
default is aliasing on distant models; correct mipping would need the chain built per-slot rather
than over the whole page.

**C. Water: three more theories killed, and the honest state.** Measured on th_ep1_01:
 - **Not z-fighting.** Wrote a real separating-axis overlap test over coplanar faces (centre
   distance was too loose - a stream and its bank at the same height are adjacent, not overlapping).
   1374 genuinely overlapping coplanar pairs on the map, and **not one of them involves
   `!nm_water3`**. The top pairs are ordinary brush entities flush against the world.
 - **Not a drawn `nodraw` shader.** `SURF_NODRAW` becomes a `surfaceparm nodraw` shader at
   batch-build time (`gl_model.c:3605`), `gl_shader.c:5778` explicitly refuses to synthesise a pass
   for it, and both `gl_backend.c:5956` and `r_surf.c:2719` skip the batch. Honoured on both the
   cached and uncached world paths.
 - **The scene-cache override is present and correct** (`r_surf.c:3123-3127`), and the cache branch
   still returns at :3352 before `PrepareFrame`, so disabling it is the right lever.
 What the map data does say, and it is the most useful number here: `!nm_water3` is **92 worldspawn
 faces against 254 brush-entity faces**. The fluid merge only ever walks worldspawn clusters
 (`q1bsp.c:2157`, `nc = model->numclusters`), so **`r_wateralpha_extendpvs` structurally cannot
 affect ~73% of this map's water.** Leaf counts: 7328 total, 1902 worldspawn visleafs, 83 fluid.
 Note the >6000 auto-cache rule reads the *total*, so it trips on a map with only 1902 visible leafs.
 Also relevant and previously unrecorded: on a HL map `cls.allow_unmaskedskyboxes` defaults to true
 (`cl_main.c:3149`), so **the sky writes no depth** and anything the PVS admits draws straight
 through it - which is the amplifier for every "faces flickering in the distance" report, and would
 be expected to get *worse* the moment the PVS extension actually started running.
 **No further blind fix applied.** Instead: `r_waterinfo`, one command printing every independent
 off-switch - effective alpha, `cls.allow_watervis` (a *server* permission that forces alpha to 1,
 `gl_shader.c:7110`), the scene-cache decision and whether the override fired, whether
 `Q1BSP_MarkLeaves` is running per-frame at all, the merged/total fluid leaf counts, the
 worldspawn-vs-entity liquid face split, and the sky depth state. `surf_info` (already present, and
 built for the previous instance of this same "bright nodraw texture" report) names the texture and
 owner of whatever face is actually flickering.
 Verified headlessly on th_ep1_01 (`+in 60 r_waterinfo`, needs `ruleset_allow_in 1`): every figure
 it reports matches the offline BSP analysis exactly - 7328 leafs / 1902 clusters, 92 worldspawn vs
 254 brush-entity liquid faces, 104 drawn / 242 hidden, effective alpha 0.5, `allow_watervis YES`,
 sky writing no depth. Note it cannot be used to judge the *runtime* water path headlessly: the
 null renderer never walks the world, so `MarkLeaves has NEVER run` there is an artefact of the
 harness rather than a finding, and the message says so.

**D. Fixed in passing: the dedicated-server build was broken.** The `r_texdiag` studio-skin block
added in Patch 171 sits *outside* the `#ifndef SERVERONLY` that declares `tex[]`, so `make sv-rel`
failed with "'tex' undeclared". Unnoticed because nothing had rebuilt the sv target since 27 Aug -
every headless test since then measured a stale `fteqwsv64.exe`.

### Sixteenth round: `r_waterinfo` found it — the merge gate could never be true

`r_waterinfo` from two maps in-game:

    th_ep1_01: merging 0 of 83 worldspawn fluid leafs   (scene cache forced off, MarkLeaves per-frame)
    cs_rats2 : merging 0 of 8  worldspawn fluid leafs   (scene cache not needed, MarkLeaves per-frame)

Everything upstream was working - the cvar, the alpha, `allow_watervis`, the scene-cache
override from last round, `MarkLeaves` running every frame. And the merge still fired **zero**
times, on two unrelated maps. Zero is not a tuning result.

**Root cause: the gate is unsatisfiable on exactly the maps the feature is for.** It asked "is
this fluid leaf in the camera's PVS", justified as *"vis is symmetric - if no sight line reaches
the fluid leaf then its water surface is genuinely not visible"*. Symmetric it is, and that is
what makes it useless here: the feature exists for maps whose vis compiler treated water as an
**opaque boundary**, and such a compiler generates no portals through the water surface, so no air
leaf ever has a water leaf in its PVS. False for every fluid leaf, from every viewpoint, forever.
That reasoning replaced an unconditional bit-set which had its own (real) bug - distant water
rendering through walls - so the feature went straight from over-firing to never firing, and the
temporal-scene-cache kill fixed last round was masking it the whole time. Two independent kills on
the same feature.

**Fix: ask whether the SHORE is visible, not the water.** What the camera actually sees is the
water surface, from the air leaf on the near side. Adjacency is static geometry, so it is computed
once per map (`Q1BSP_BuildFluidAdjacency`): two leafs are adjacent when their bounding boxes touch.
Measured first, because adjacency alone is not enough - on th_ep1_01 only **37 of 83** fluid leafs
touch a non-fluid leaf at all; the other 46 are interior, surrounded by more water. So fluid leafs
are also union-found into connected **bodies**, and a body is visible when any member sees a shore.
Verified offline against the real BSPs before shipping:

    th_ep1_01: 83 fluid, 37 with a direct shore, 2 connected bodies -> 83 of 83 reachable
    cs_rats2 :  8 fluid,  8 with a direct shore, 1 connected body   ->  8 of 8  reachable

Grouping by geometry is what stops this becoming the old bug again: a body is one continuous volume
of water, so seeing into one end of a river legitimately means seeing along it, while a pool in
another room is a different body and never merges.

Two things fall out of the rewrite:
- **The fluid leaf's own bit now has to be set explicitly.** The old gate got it free from
  `basevis`; reaching a pool through its body's shore means it was never set, and without it the
  geometry filed *inside* the water leaf (the pool floor) stays culled. Set through the pointer
  `ClusterPVS` returns, since it may have reallocated `pvsbuf`.
- **A fluid leaf with no vis data of its own is now skipped.** `Q1BSP_DecompressVis` answers a NULL
  row with all-`0xff` and does it by OVERWRITING (`q1bsp.c:2709-2717`), so merging one such leaf is
  `r_novis` for the whole frame - the far end of the map drawn over a depth-less HL sky. That is a
  plausible mechanism for the "faces flickering in the distance" report and it is now impossible.
  Neither test map has any (`0 novis` on both), so this is a guard rather than a fix.

`r_waterinfo` now also reports the shore table size, the body count, and any skipped no-vis pools,
so "merging N of M" can be read against what was actually available.

**The first build of this CRASHED on `r_wateralpha_extendpvs 1`, and the reason is worth keeping.**
The union-find unioned in place and then flattened in place, writing each entry's final body id
over the parent pointer that the *next* entry's find() still had to walk through. The instant one
chain passed through an already-rewritten entry, the walk read a negative body id as a parent index
and indexed the array with it. Fixed by keeping the parent array separate from the output array -
the find() never reads anything the renumber has touched.

**And it should never have reached Lex.** The whole round was chased through the headless harness,
which cannot see this code at all: the null renderer never walks the world, so `Surf_DrawWorld`,
`Q1BSP_MarkLeaves` and the merge simply do not execute, and `r_waterinfo` there honestly reports
"MarkLeaves has NEVER run" as a harness artefact. A single real launch would have caught it. Real
client runs are self-terminating with `+set ruleset_allow_in 1 +in 45 r_waterinfo +in 55 quit`.

**Verified on the real renderer, both maps, no crash:**

    th_ep1_01: merging 78 of 83   shore table: 153 entries across 2 connected water bodies
    cs_rats2 : merging  8 of  8   shore table:  47 entries across 1 connected water body

Both match the offline BSP prediction exactly. 78-of-83 rather than 83-of-83 is the gate working
rather than failing: th_ep1_01's water is two bodies, and from the spawn area only the larger one
(78 leafs) has a visible shore - the other five stay culled, which is precisely the selectivity the
unconditional version lacked.

### Seventeenth round: the water surface has TWO facings, and hidesides was deleting one

**Report:** swim inside worldspawn water, look up at the "roof", and instead of the water surface
you get a flat solid you cannot see through at `r_wateralpha 0.5`. *"I swear this wasn't the case
at one point."*

**It was my regression, from the `&& i` removal.** The compiler emits the water TOP boundary
**twice, once in each facing**. Every generated shader defaults to `SHADER_CULL_FRONT`
(`gl_shader.c:7886`) and the water shader adds no `cull` override, so one facing is drawn from
above and the other from below and exactly one of the pair survives culling at any viewpoint -
which is also why they never z-fight. `r_hlwater_hidesides` kept only `up > 0.5`, so it deleted the
down-facing copy of every water surface in the world. Swim under it and there is simply nothing
there. Before the `&& i` removal this only affected brush entities, where it happens to be right.

Measured on th_ep1_01 - all 3 horizontal worldspawn liquid planes carry BOTH facings, in equal
counts and (independently checked) **identical polygon area**:

    plane n=(0,0,1) dist=-2168 : 42 up / 42 down   areaUp 1,193,154.9 == areaDown 1,193,154.9
    plane n=(0,0,1) dist=-2160 :  1 up /  1 down   areaUp    41,216.0 == areaDown    41,216.0
    plane n=(0,0,1) dist=  -96 :  3 up /  3 down

**The fix is NOT "hide only vertical faces", and a corpus scan is what settled that.** A
`func_water` is a closed box: its bottom is a face on its OWN plane with no up-facing twin, and
that one really is the "underside seen through the depth-less sky" this block was written to
suppress. Across all 108 Sven Co-op maps:

    worldspawn down-facing liquid faces:  991 of 991 (100%) are back-to-back twins of a kept face
    brush-entity down-facing liquid faces: 68 of 459        are twins; 391 are standalone bottoms

So a blanket vertical-only rule would have un-hidden 391 entity box-bottoms and reinstated the
original bug. The rule shipped is **keep a down-facing water face only when a coplanar up-facing
water face exists in the same submodel** - the twin is exactly what separates "the underside of a
surface" from "the bottom of a box", and no threshold on the normal alone ever could.

**Verified in the real client on th_ep1_01:** `liquid faces: 104 drawn, 242 hidden` becomes
**`150 drawn, 196 hidden`** - exactly the 46 worldspawn undersides restored (92 worldspawn + 58
entity tops = 150), with all 196 entity sides and bottoms still suppressed. No errors; the PVS
merge still reports `78 of 83`.

### Build

Engine rebuilt clean in UCRT64 (`make m-rel FTE_TARGET=win64`, no errors), deployed to
`C:\FTEQuake` and `Desktop\Quakers`, rollback kept as `fteqw64.prepatch171.exe`. Verified
the new symbols are actually in the shipped binary (`texdiag`, `hlmodel_fullbrightmasked`)
because three consecutive builds produced a byte-identical file size. Smoke-tested headless
on pizza_ya_san1 and th_ep1_01: 191 and 379 `[texdiag]` lines, no errors or crashes beyond
the pre-existing missing hgrunt/VOX sound downloads. **No QC changed, so progs are untouched.**

---

## PATCH 170 — th_ep1_01/02/03, thirteen reports: eight fixed, and two of the "why is this STILL broken" three were never asset bugs

**Reports (verbatim, th_ep1_01/02/03):** `monster_furniture` `tree1.mdl` / `bush1.mdl`
"black transparent textures", asked "like 5 times"; squadmaker `monster_zombie`
`crypt_monstr7` and a `spawnflags 544` headcrab both walk into a corner on spawn, the
zombie then despawns; worldspawn water "solid texture on the internal faces"; do
hitboxes have body damage multipliers; blood impact with no damage, and melee body
sound with no hitmarker until closer — "if they hit the hitbox it should deal damage,
anything else is NOT A HIT ... do not respond to hitting the bbox"; can scientists heal
players below 50 like GoldSrc; do zombies attack friendly NPCs; `env_explosion` smoke
too long; `monster_barnacle` tongue never picks anyone up, "after 3 attempts";
ADS on the colt1911; NPCs need to be affected by `trigger_push`; `func_wall` `*296`
"needs to be transparent", appears bright white, asked 5 times; `{stripeh` black on
pizza_ya_san1 worldspawn, "originally was transparent and you could see through the
world", asked 3-4 times.

### The three "still broken after N attempts" items, measured rather than re-guessed

**`{stripeh` was changed ON PURPOSE by PATCH 167, and this build's own engine comment
says so.** `client/wad.c:425-437` names this exact texture: pizza_ya_san1 draws zebra
crossings with `{stripeh` out of `decals.wad`, it decoded to dark red at alpha 24..58,
"all 418 worldspawn faces using it turned fully invisible and the sky showed through".
That invisibility is the "originally transparent, you could see through the world" in
the report — it was the bug, not the baseline. Decoded the lump both ways to confirm
what it is now: 128x32, lumptype 0x43, palette a greyscale ramp (pal[0] white,
pal[254] = 5,5,5) with the decal colour at pal[255] = (141,15,2), and **0 of 4096
texels use index 255**. Masked decode therefore keeps 100% of the texture at mean RGB
**(223.7, 223.7, 223.7)** — near-white road paint, exactly what Sven shows. So the
current *asset path* is right and nothing about the texture can render black; whatever
is making it black is downstream, which puts it with the foliage below rather than
with the WAD.

**`func_wall` `*296` is not a transparency bug: the brush is textured `white`.**
Dumped the model's faces — 19 faces, all one texture, `white` 32x32, and the entity is
`rendermode 4` + `rendercolor 0 0 0` with **no `renderamt` key at all**. `white` is not
a `{` texture, so it has no alpha channel, and `kRenderTransAlpha` is `src*srca`
(`common/const.h:689`) — the transparency comes from the texture, which has none.
Drawing it opaque white is a faithful read of the entity. Checked whether "mode 4 with
renderamt 0 means invisible" could be the rule instead, by scanning all 141 Sven/HL
maps: 4956 `rendermode 4` brush entities, of which only **141** are renderamt-0 on a
non-masked texture, while **91** are renderamt-0 on a `{` texture and must stay visible
(ctf_warforts' `{blue` flag bases, desertcircle's `{cashole`). So there is no safe
global rule, and this one entity needs a decision, not a semantics change — see below.

**The foliage is not the mask, not the palette, and not the mip chain.** Parsed the
models: `tree1.mdl` `branch.bmp` and both of `bush1.mdl`'s textures carry flags
**0x0040 (MASKED)**, so `HLSHADER_MASKED` (`gl/model_hl.h`) is selected and
`gl_hlmdl.c:750-775` builds the RGBA palette with index 255 at alpha 0. Then simulated
FTE's exact mip filter (`Image_MipMap4X8`, an unweighted RGBA box, integer `>>2`) over
the real texel data, reporting the mean colour of the texels that survive
`alphaFunc GE128` at every level:

| texture | mip0 | mip3 | mip6 |
|---|---|---|---|
| `bush1_1` | luma 100.0 | 89.6 | 75.4 |
| `bush1_2` | luma 108.4 | 100.8 | 65.0 |
| `branch` | luma 43.8 | 35.3 | 35.0 |

Nothing here is black — bush1 is a normal mid-green the whole way down. Also ruled out
by reading the shipped values: the model self-shadow floors at
`r_shadows_selfshadow_floor 0.4`, the sun form-shade is clamped at
`max(floor, 0.12)` with cfg 0.5/1.5, and `colormod '0 0 0'` is remapped to neutral by
the engine (`sv_ents.c:3878`). `BrushSync_ApplyRenderKeys` mode 4 is correct and
`monster_furniture` routes through it. **So five separate candidates are eliminated and
the fault is downstream of the texture, in the same place `{stripeh` now points.** Both
need one look with `r_shadows 0` — that is the single line that separates them.

### Fixed

1. **NPCs never had hitgroups — that is the answer to "check if hitboxes have body
   damage multipliers".** The multiplier table has always existed (head 4x, stomach
   1.25x, limbs 0.75x) and NPCs could never reach it: `W_HitgroupClassify` flattened
   *every* non-player to `HITGROUP_GENERIC`, so every shot on a monster was flat 1x and
   there was no such thing as a headshot on a headcrab. The engine has been reporting
   the real answer the whole time — `hlmdl_hitbox_t.body` is the studio format's
   `group` field, "value reported to gamecode on impact" (`gl/model_hl.h:199-205`),
   copied to `trace->surface_id` at `gl_hlmdl.c:1729`, and HL's group numbering is the
   same numbering our `HITGROUP_*` constants use. Monsters now take the per-bone answer.
   Deliberately asymmetric: a monster gets a hitgroup ONLY from the engine's per-bone
   result and never falls through to the Z-height classifier, so the crate-headshot bug
   that flatten was protecting against cannot come back through a monster-shaped door.

2. **Melee: the body sound came off the bounding box.** `CSQC_PredictedMeleeTraceEx`
   set `is_monster_hit` from `CSQC_Monster_OverrideTrace` — a ray-vs-AABB over
   `getentity(GE_ABSMIN/GE_ABSMAX)` — and used it to drive both the flesh burst and the
   `hitbody1/2/3` sample, while the server's `W_MeleeTrace` runs `MOVE_HITMODEL` through
   `HLMDL_Trace` against per-bone hitboxes. The box is a strict superset of the bones,
   so the shell of air around a zombie produced blood and a body sound for a swing that
   dealt zero damage. The BULLET path was given this exact treatment in a previous patch
   and the melee path was not, which is why the same defect kept coming back after the
   bullet half was fixed. Monster melee hits now produce no local blood and no local
   sound; the server plays `hitbody*` itself on `CHAN_WEAPON` and `W_ImpactEffectSend`
   already includes the shooter for monster targets. Explicit empty branches, so it
   cannot fall through to the wall sample (the old "melee on zombies makes a metal
   sound" bug).

   **Not attempted: a client-side hitbox trace.** It would need the monster's animation
   phase, and `getentity` exposes `GE_FRAME` and `GE_ANGLES` but there is no
   `GE_FRAME1TIME` (`client/pr_csqc.c:6035-6080`) — so a CSQC ghost would be posed at a
   different point in the animation than the server's and would just relocate the
   disagreement instead of removing it.

3. **The barnacle's grab was a one-shot latch, and that is why three passes missed it.**
   `Barnacle_Tick` guarded the grab with the bare edge test `self.ai_victim != v` while
   `self.ai_victim = v` below runs whether the grab SUCCEEDED or not. So one refusal was
   permanent: `ai_victim` pointed at a victim whose `barn_holder` was never set, the next
   tick saw `v == ai_victim`, skipped the attempt, and every tick after did the same.
   What hid it is that everything else keeps working in that state — the chew damage, the
   tongue length, the bite sound and `COND_SEE_ENEMY` all need only `v`, not a hold. The
   barnacle bites you, hurts you and drips its tongue on your head, and simply never lifts
   you. Every previous fix looked at the parts that were visibly working. Ruled out first
   by measurement, not assumption: `sv_ai_debug 2` on th_ep1_02 reports both barnacles at
   `ceil=349.963 ctrl=-249.963 extended=1`, so the floor trace, the tongue length and the
   extend latch were all healthy. Retried every tick now (every refusal reason is
   transient), and each refusal has a `sv_ai_debug 2` line naming the gate that said no,
   so a fourth report resolves in one run instead of a guess.

4. **Corner-walking is a nav-coverage bug with a precise cause: `srccomp 0` meant "no
   filter" when it means "not on the graph".** Component ids are 1-based
   (`Nav_ReportComponents` increments before assigning), so 0 is `Nav_ComponentAt`'s
   FAILURE value — and its failure case is routine, because it goes through
   `Nav_NearestNode`, which requires LINE OF SIGHT to a node and returns -1 without it.
   A monster spawned in a closed crypt or stairwell has exactly that.
   `Nav_PickRoamGoal` read that 0 as "don't filter" and picked from the whole graph.
   Measured on th_ep1_01: **40 components, largest 716 of 1264 nodes (56.6%), 19
   isolated**, and the build log counts **41 monster spawn points with no graph within
   256 units**. So an unfiltered pick lands somewhere unreachable about half the time;
   `AI_PathRequest` returns NOPATH and `AI_MoveAlongPath`'s no-waypoint fallback heads
   STRAIGHT FOR THE GOAL — walking the monster into whatever wall lies between it and a
   node it can never reach, where it grinds out its walk cycle. Both `crypt_monstr7`
   zombies carry `freeroam 2`. Now refuses instead and lets the 5 s throttle hold.
   `nav_comp_valid` FALSE is left alone — nobody can filter there.

5. **Scientists heal.** Ported `CScientist::CanHeal`/`Heal` (`scientist.cpp:1080-1100`)
   with HL's numbers intact: the 60-second cooldown, "health above half of max means you
   are fine" (which is where "below 50" comes from, max_health being 100), 128 units to
   start the schedule, 100 units to actually inject, and `sk_scientist_heal` 25 via a new
   `sv_ai_scientist_heal` cvar. `SCHED_HEAL` reproduces `tlHeal` — walk, face, ACT_ARM,
   TASK_HEAL, ACT_DISARM — with HL's interrupt mask of **0** and HL's own reason for it
   ("Don't interrupt or he'll end up running around with a needle all the time"). A
   refusal for range deliberately does NOT start the cooldown, exactly as HL leaves
   `m_healTime` alone on that path — that is what makes him keep walking toward you.
   ONE WIDENING: HL only heals `m_hTargetEnt`, the player who asked him to follow, so a
   scientist in a corridor watches you bleed; this prefers the escorted player and falls
   back to the nearest hurt player inside HL's own 128-unit radius. `TASK_GET_PATH_FOLLOW`
   resolves a `followlead` local rather than seating `ai_follow`, so one injection does
   not leave him trailing you for the rest of the map.

6. **NPCs are affected by `trigger_push`.** The entity lived entirely inside pmove, so
   only players ever saw it — the QUAKED block said so in as many words ("No Monsters —
   no-op here; pmove only ever moves players"). `trigger_push_touch` now applies
   `CTriggerPush::Touch` (`triggers.cpp:1837-1873`): the four skipped movetypes, the two
   skipped solidities, the instant `PUSH_ONCE` impulse vs the integrated push field, and
   ground-stick broken when the result is upward. `PUSHMAP_NOMONSTERS` is carried across
   instead of discarded, and `PUSH_ONCE` is consumed by a monster too (HL's removal is in
   the same branch as the impulse, with no classname test). ONE DIVERGENCE, forced by our
   locomotion: monsters walk with `walkmove()`, which is positional, and
   `SV_Physics_Step` never integrates velocity for something still holding FL_ONGROUND —
   so a horizontal-only push does not unstick a walking NPC, because doing that every
   frame it stood in the brush would freeze its pathing (walkmove refuses while
   airborne). Vertical pushes — steam vents, updrafts, jump pads, which is what the
   entity is overwhelmingly used for — now behave for an NPC exactly as for a player.

7. **`env_explosion` smoke was reusing the SMOKE-GRENADE puff.** `CSQC_SpawnSmokePuff`
   holds its spawn for up to **3.6 s** and then lives **11-17 s**, because a grenade's job
   is to deny a sightline for a round. Stacked on the emitter's 6 bursts x 0.5 s that put
   explosion smoke on screen for the better part of **twenty seconds** after the bang. New
   `CSQC_SpawnExplosionSmokePuff` — same entity, same draw path, same colour ramp, only
   the timing differs — starts within 0.18 s and lives 1.3-2.2 s, and the emitter drops to
   3 bursts at 0.18 s. Whole effect clears in a little over two seconds. Separate function
   rather than a parameter so nobody editing an explosion can reach the grenade's tuned
   numbers by accident; the smoke grenade is byte-identical.

8. **ADS on the colt1911.** It had no ADS profile at all — `weapon_ads_eligible` defaults
   to 0 and the shared ADS path reads that field rather than any weapon list, so the gun
   was never a candidate. `W_SetADSProfile(TRUE, "cl_ads_th1911", SCOPE_CLASS_NONE)` in
   BOTH Equips (the pose and FOV envelope are driven from the predicted player, so a
   server-only profile would leave the local viewmodel refusing to aim), plus
   `ADS_RegisterPoseCvars("cl_ads_th1911")`. Pose is the untuned baseline; the six
   `cl_ads_th1911_*` cvars are live, so alignment is a tuning pass, not a rebuild.

### Answered, no change

- **Zombies vs friendly NPCs.** The relationship is already right: zombie is
  `CLASS_ALIEN_MONSTER`, scientist `CLASS_HUMAN_PASSIVE`, the matrix returns `R_DISLIKE`
  and `AI_Hates` is `>= R_DISLIKE`. Monster-vs-monster acquisition exists and is throttled
  to 2 Hz. What actually stops it on the maps tested: **on th_ep1_03 the only live
  scientist carries the PRISONER spawnflag**, which HL makes universally ignorable
  (`AI_ValidEnemy` checks it both ways round), and th_ep1_01/02 have one prisoner and one
  non-prisoner each. With a player present a zombie also correctly prefers the player —
  `R_HATE` outranks `R_DISLIKE` — which is HL's own ordering. One real divergence remains
  and was left alone: HL's `Look()`/`BestVisibleEnemy()` re-picks continuously, ours only
  scans monsters when `!m.ai_enemy`. With a player nearby the visible behaviour is
  identical, so this is not worth churning the AI for.
- **Worldspawn water.** The `!` prefix IS handled — `Shader_DefaultBSPQ1` takes
  `*shortname == '*' || *shortname == '!'` into `Shader_DefaultBSPWater`, so GoldSrc water
  is not falling through to a wall shader. The opacity gate is not it either:
  `cls.allow_watervis` needs `watervis` serverinfo or `ruleset_allow_watervis`, both
  satisfied, and `cfg/default.cfg` ships `watervis 1` / `r_wateralpha 0.5` /
  `r_waterstyle 1`. Still needs the thing PATCH 166 asked for and did not get: one
  `surf_info` line off the offending face. The candidates are now named though —
  th_ep1_01 has exactly one water texture, `!nm_water3` (128x64, WAD-referenced).

### Build

Three VMs, 0 warnings: `qwprogs.dat` 9,969,582 B, `menu.dat` 833,246 B,
`quakers_csprogs.pk3` 1,720,867 B (loose `csprogs.dat` removed by the packer). No engine
change this patch. Smoke-tested 45 s headless on th_ep1_01 and th_ep1_02: both load
clean, no QC errors, barnacle diagnostics unchanged (`ceil=349.963 extended=1`), nav
report on th_ep1_01 `components=41 largest=710 (56.4% of 1259)`.

---

## PATCH 169 — th_escape, seven reports: four fixed, one is a new decoder, two are shader/renderer

**Reports (verbatim, th_escape):** `func_illusionary` `*788` bright red in Sven and
GoldSrc but "a black transparent silhouette" here, "still not fixed"; `func_illusionary`
`startwait_dig1`/`2` free-running through 0-9 instead of counting 30 down; the escape
timer "fades out or in? every second, it looks like it 'flashes'"; the carried-item HUD
strip drawn over the level progression and the above-head model too high; the
`startbutt_rel` button showing "blackness/void, and the same spot 3 times"; ten
`Format not recognised: sound/th_escape/*.flac`; and
`[script] "": still looking for "jail_sheriff" after 120 tries`.

### 1. `{nm_they5` is NOT a texture bug, and now there are numbers to say so

Patch 167 got as far as "the fault is in the shading, not the texture and not the
masking" and listed the measurements still needed. Three of them can be taken off the
machine without the renderer, and all three come back clean:

| what | measured | verdict |
|---|---|---|
| the WAD lump | `{nm_they5` in `neilm2.wad`, 192x64, 17 palette indices, **all pure red** (61,0,0)..(182,0,0), index 255 = (0,0,255) with 7207/12288 texels | decodes correctly |
| the mip chain | simulated FTE's RGBA box filter: the texels that survive `MASK=0.666` stay at mean **(126,0,0)** through mip 4 | not mip darkening |
| the lightmap | face 25031, styles `(0,70,255,255)`, style 0 block is a flat **119/255** everywhere (the entity's `_minlight 0.5`) | the face is lit at 47% |

A correctly-decoded red texture times a 47% lightmap is not black. **Everything between
the asset and the shader is verified good**, which leaves the shader.

**And there is exactly one multiply by zero left in it.** `quakers/glsl/defaultwall.glsl`
had, in the single-shadowmap path:

    col.rgb *= mix(1.0, ShadowmapFilter(s_shadowmap, vtexprojcoord), sunvis);

`ShadowmapFilter` returns a raw 0..1 occlusion and **0.0 is reachable**, so a
fully-shadowed wall pixel came out pure black regardless of lightmap, `_minlight` or
ambient — which is precisely why every one of these reports insisted the symptom was
"not related to brightness". This is the same defect Patch 167 found and fixed in
`defaultskin.glsl` for studio models (`r_shadows_sunshade_floor` 0 -> 0.5); the wall
shader kept its copy.

It is the shipped path, not a corner:

- `FAKESHADOWS_MULTI` needs `FAKESHADOWS_COUNT > 1` and `cfg/default.cfg` ships
  `r_shadows_slots 1`, so **every** wall goes through the `#else`.
- `sunvis` is 1.0 on every GoldSrc BSP (no SUNVIS lump -> `sunocc` reads 0), so the
  `mix()` gate was wide open.
- The `FAKESHADOWS_MULTI` branch 130 lines above it already floors at
  `r_shadows_color` (0.4). Only the single-slot path did not.

Now floored with the same triple, so the two paths agree and changing
`r_shadows_slots` no longer changes what a shadow looks like. **Cannot darken
anything**: `mix(shadowmul,1,f) >= f` for `shadowmul >= 0`.

Runtime file — `vid_reload` to take, no engine build needed.

**Not claimed as closed.** This is a shader fix that follows from a proof by
elimination, not from seeing the pixel. If `*788` is still black after `vid_reload`,
the one remaining discriminator costs a line: `r_shadows 0` — if it goes red, the
shadow path is the whole story and the floor needs raising; if it stays black, the
fault is upstream of the shadow term.

### 2. The digit brushes need an engine feature that does not exist yet

`startwait_dig1`/`2` carry the GoldSrc animated texture group `+0~lcdcount` (read off
the BSP texinfo for models `*791`/`*792`), and `trigger_numericdisplay` is meant to pin
each brush to one frame of it. FTE picks the frame from a wall clock —
`gl_model.c:3354`, `relative = (cl.time*10) % anim_total` — and `.frame` selects only
the `+a` **alternate** set, which GoldSrc already spends on `button_target`'s state bit.
So "show a 7" is still not expressible.

The engine already has the machinery, one function away: `Mod_UpdateBatchShader_Q2`
(`gl_model.c:3406`) indexes the same group from `batch->ent->framestate.g[FS_REG].frame[0]`
for Q2 BSPs. The Q1/HL variant needs the same, keyed off a field `.frame` is not
already using — `frame[1]` is the lerp-from slot and nothing reads it on a brush model.
Then `trigger_numericdisplay` (already stubbed, `sv_th_entities.qc:3286`, with
`netname`/`message` parsed and ready) drives it through brushsync. Not attempted this
patch.

### 3. The escape clock flashed because a clock was being sent as a message

`THEsc_SendClock` re-sends a `game_text` block every second with a **new string**, and
`THEsc_Hud` stamped `fadein 0.1` on every send — so the countdown restarted a fade-in on
every tick. A fade is right for a message that appears once and wrong for a field being
updated in place. Sven's own `CustomHUD` makes the same split: its countdown is a HUD
element it redraws, not a `HUDTextParams` message it re-sends.

`thesc_hud_nofade` is a self-clearing one-shot set immediately before the clock's send.
A global rather than two more parameters because `THEsc_Hud` is already at seven and QC's
fixed arity gives no cheap way to add optional ones. The seam is still covered by the
existing 1.4 s holdtime against a 1.0 s refresh, so the hard cut is invisible.

### 4. The carried-item strip and the rank widget were fighting over the same corner

`HUD_INV_MARGIN` was doing two jobs — left edge **and** bottom margin — so every past
adjustment moved the strip diagonally. Split.

Measured overlap: `HUD_DrawRankWidget` puts its XP bar at `g_height-116..-110` and its
"Lv N Rank" label at `g_height-132..-120`, both spanning x 24..192. The first icon row
at margin 82 spanned `g_height-124..-82` from x 82. Two axes, both overlapping.
`HUD_INV_BOTTOM 140` puts the lowest icon 8px clear of the top of the label.

The above-head model was `plyr.origin + '0 0 8' + [0,0,plyr.maxs_z]`, open-coded at
**both** placement sites (`Inv_Conceal` for the instant placement on pickup,
`item_inventory_think` for the 10 Hz follow) — which is how they came to disagree.
`maxs_z` already reaches the top of the head, so the `'0 0 8'` was eight units of pure
air on top of that, before the model's own geometry started. One `Inv_CarryOrigin`
helper now, and the lift is `sv_inv_carry_lift` (default **0** = sit on the head).

A cvar rather than a constant because the right number is a look judgement that cannot
be measured from the files: the studiohdr `min`/`max` on `item_carbattery`,
`item_gascan` and `item_toolbox` are all zeroed, which is normal for HL models and
leaves nothing authoritative to derive a clearance from.

### 5. The intro cameras: what the log proves, and what it does not

Driven headlessly (`sv_debug_firetarget introcams_mm`, `sv_debug_fire_noplayer 1`,
`sv_debug_cutscene 1`) because the real route needs a player to press a button behind a
30-second `multisource` gate. The server side is **working**:

    21:16:25 bind Player -> "itm1_loc3_cam"  start ... stop      <- stomped
    21:16:25 bind Player -> "itm1_loc2_cam"  start ... stop      <- stomped
    21:16:25 bind Player -> "itm1_loc1_cam"  start
    21:16:31 stop  "itm1_loc1_cam"                                <- ran the full 5.5 s
    ...same shape for itm2_* at +6 and itm3_* at +12

All three of an item's location cameras fire on the same tick (the map's own
`introcams_mm` keys them all at 1.5 / 7 / 13.5) and the last one wins, because
"triggering another camera while one is playing overrides the first" is Sven's
documented rule and is implemented. **That is not a bug**: HL's `CMultiManager::Spawn`
sorts by delay with a stable sort, all three delays are equal, so parse order stands —
and the BSP's parse order is loc3, loc2, loc1. loc1 wins in Half-Life too.

Also checked and clean: `MM_StripSuffix` handles the `cine_fadeto#1..#3` /
`cine_fadefrom#1..#2` duplicate-key suffixes; `Cutscene_AimEntity` already guards
`aim == world` and frames on the target's centre rather than its origin; model `*687`
(the func_train the camera tracks) is a **zero-face origin-brush-only marker**, so
`FuncTrain_DestOrigin`'s centre term is 0 and `func_train_find_first` lands it exactly
on `itm1_loc1_cam_p0` at (-5428,-600,276), 328 units from the camera; and the
`trigger_relay` that shares the name `itm1_loc1_cam` is what starts that train moving.

So the binding, the aiming, the path and the fade arithmetic are all correct on the
server, and **the reported blackness is a client-side render symptom that the headless
renderer cannot see** — the same class as report 1, and quite possibly the same cause,
since the camera is looking at brushwork from a fixed point in a dark yard.

Worth one line in-game before anything else is changed here: run the intro with
`r_shadows 0`. If the shots come back, reports 1 and 5 are one bug.

### 6. FLAC, decoded bit-exactly

FTE had **no** FLAC decoder. `fs.c:1667` lists "flac" among the extensions the
filesystem hands to the sound system and `snd_minimp3.c:137` goes out of its way to
*reject* a `fLaC` magic so the mp3 sniffer cannot steal the file — but nothing
downstream ever claimed it, so every `.flac` ended at "Format not recognised". That is
the whole audio track of th_escape's central set piece.

New `engine/client/snd_flac.c`, same shape as `snd_minimp3.c` beside it: one sniffer,
one entry point, decode up front into one PCM block, hand it to `ResampleSfx`. libFLAC
is not in the tree and not installed in the MSYS2 root this builds in, so linking it
would add a build dependency and a shipped DLL for one container; the format is small
enough not to need either. CONSTANT / VERBATIM / FIXED / LPC subframes, Rice and
escaped residuals, all three stereo decorrelations. Ogg FLAC, CRC verification and
seeking are deliberately out.

**Verified bit-exact, not merely audible.** FLAC's STREAMINFO carries an MD5 of the
unencoded audio, so the file checks the decoder. A standalone harness
(`scratchpad/flactest.c`, the same source with the FTE surface stubbed) over all ten:

    MD5 OK  diesel_idle_loop.flac           44100Hz 1ch 16bit  streaminfo=267573 decoded=267573
    MD5 OK  diesel_ignition-rev-idle.flac   44100Hz 1ch 16bit  streaminfo=609246 decoded=609246
    MD5 OK  diesel_ignition-rev.flac        44100Hz 1ch 16bit  streaminfo=153568 decoded=153568
    MD5 OK  diesel_rev.flac                 44100Hz 1ch 16bit  streaminfo=102146 decoded=102146
    MD5 OK  repairsnd01..06.flac            48000Hz 2ch 16bit  every sample count exact

    0 file(s) failed

Registration is three lines mirroring `S_RegisterMP3Plugin` (`snd_dma.c`, `sound.h`,
`Makefile`). **In-engine confirmation is still owed**: `snd_device none` means the
loaders never run, so the headless client cannot A/B this — the check is one map load
on a real client, where the ten "Format not recognised" lines should simply be gone.

### 7. `jail_sheriff` is the new watchdog working, not a fault

The unnamed `scripted_sequence` at (4701,-4285,-1032) holds `standing_idle` for
`jail_sheriff`, and the only `jail_sheriff` there will ever be is the `monster_gman`
that squadmaker `jail_sheriffspawn` spawns when `populate_jail` runs at the **end** of
the map. So it misses for the entire run and Patch 168's new one-shot notice fired.

Gated on `Script_MakerWillSupply`: squadmaker/monstermaker hand their `netname` to each
child as its targetname (`sv_monsters.qc:1877`, `:2118`), so a script waiting on a name
a maker declares is waiting for something nobody has asked to exist yet — the normal
case for a mid-map set piece. **Only the diagnostic is gated.** The retry itself keeps
running either way; gating that would reintroduce the give-up Patch 168 removed, for
every script whose actor is placed rather than made.

### Also read and found correct (no change)

- `th_escape.cfg` has **no weapon strip of its own**. `player_weaponstrip "weaponstrip"`
  exists but is fired only by `end_jail_mm`, at the losing ending. The per-character
  loadout is 100% AngelScript (`PlayerCharacters::Equip` -> `GiveNamedItem`), which
  `sv_mapscript_thescape.qc` already ports as `THEsc_EquipCharacters`. Keeping the
  weapons you spawned in with is therefore expected unless that runs.
- `MM_StripSuffix`, `Cutscene_AimEntity`'s world guard, `FuncTrain_DestOrigin`,
  `BrushSync_ApplyRenderKeys`' rendermode-4 branch (`alpha = 1`, no colormod — correct,
  HL ignores `rendercolor` for `kRenderTransAlpha`).

### Build

`qwprogs.dat` 9,963,974 B, `menu.dat` 833,154 B, `quakers_csprogs.pk3` 1,720,161 B
(loose `csprogs.dat` removed by the packer), all three **0 warnings**.
`fteqw64.exe` 8,021,159 B, `snd_flac.c` clean under `-Wall -Wextra`; deployed to
`C:\FTEQuake` and `C:\Users\Lex\Desktop\Quakers`. `fteqwsv64.exe` unchanged — the
decoder is `#ifndef SERVERONLY`. `glsl/defaultwall.glsl` is a runtime file: `vid_reload`.

---

## PATCH 168 — pizza_ya_san1, ten reports: nine fixed, one closed as correct

**Reports (verbatim):** func_wall_toggle `*287` not solid by default; weapon_medkit
cannot be dropped (impulse 8 replays the draw animation); `mp_weapon_respawndelay -1` /
`mp_item_respawndelay -1` do not respawn the crowbar or the healthkits; music does not
loop; func_water `*56` moves on +use when Sven's does not, and `*173` answers +use with a
locked-error sound when Sven is silent; the `mm_kyaku` / `mm_gomiclear` customers walk to
their chairs and then stand instead of sitting; `sv_debug_hitboxes` does not draw NPC
boxes, and do NPCs even pass the expansion check; shock_rifle ammo sticks at 1 unless
firing; `monster_alien_babyvoltigore` spawns passive and does not move; NPC "leader" makes
no sound and fires no bullets during his firing animation.

Ground truth for all ten came from the BSP itself — entity lump parsed to all 897
entities — plus the HL SDK, `sven-coop.fgd` and the Sven manual on disk. The map's own
`pizza_ya_san.as` is 14 lines and only registers `weapon_as_shotgun` / `weapon_as_soflam`,
so nothing here is script-driven.

### 1. func_wall_toggle `*287` — NOT A BUG, closed as correct

`*287` is `targetname wlt_cookarea`, `spawnflags 1`, `rendermode 5` / `rendercolor 0 0 0`
(the invisible-but-present idiom). In the SDK, `CFuncWallToggle::Spawn` calls `TurnOff()`
on flag 1 (`bmodels.cpp:98-103`), and `TurnOff()` is `solid = SOLID_NOT; effects |=
EF_NODRAW` (`:106-111`) — the flag clears **both**. `IsOn()` (`:122-127`) defines "on" as
`solid != SOLID_NOT`, so solidity is the canonical state, not visibility. Sven's FGD
declares the same single flag and its manual and changelog say nothing about
`func_wall_toggle` at all; our `sv_brushsync.qc:722-746` is a line-for-line port.

The map settles it independently: 51 of its 67 `func_wall_toggle` carry `spawnflags 1` and
the rest carry none, in deliberate complementary pairs sharing one targetname
(`wlt_kamadoonRU` / `wlt_kamadooffRU`, and the same for RM/RL/LL/LM/LU and every signal
light). Firing the shared name flips one on as the other goes off — an idiom that only
works if flag 1 means start-off.

Correct timeline for `*287`: spawns non-solid and invisible → `mm_kijikonestart` toggles
it solid (gated behind `ms_norainu`, i.e. both the meat-shop and vegetable-shop errands)
→ `mm_lastpizza` toggles it off again 69 s into the endgame.

**Open question, and the only thing needed to close this for good:** was it observed
non-solid *before* the dough-kneading sequence started (correct — nothing to fix), or
*after*? If after, the fault is upstream in `mm_meatshopend`/`mm_vegeshopend` →
`multisource ms_norainu` → `mm_norainuend` → `mm_beforepizza` → `mm_kijikonestart`, not in
func_wall_toggle. Free in-game discriminator: `mm_kijikonestart` also toggles `wlt_kijiL1`
(also `spawnflags 1`). Both still absent ⇒ the multi_manager never fired. `wlt_kijiL1`
appeared and `wlt_cookarea` did not ⇒ a genuine per-entity fault, and this diagnosis is
wrong.

### 2. func_water and +use — one bug, two symptoms

`CBaseDoor::ObjectCaps()` (`doors.cpp:42-48`) grants `FCAP_IMPULSE_USE` **only** with
spawnflags bit 256. `*56` has spawnflags 0 and `*173` has 33 (`START_OPEN|NO_AUTO_RETURN`);
neither has 256, so in GoldSrc neither is even a candidate for the player's use trace.
`CBaseDoor::Spawn` additionally force-sets `SF_DOOR_SILENT` on any door with `skin != 0`
(`doors.cpp:291-295`) — always true for water — so a pool cannot emit *any* door sound,
locked click included. Zero of the 22 `func_water` in the corpus (pizza_ya_san1 5,
th_ep1_01 3, th_ep1_03 1, th_escape 13) set 256.

Our `func_water` inherits `func_door`'s `.use = door_use` but was missing from both places
that model `FCAP_IMPULSE_USE`, so the +use cone fallback reached it: the unnamed pool
passed `func_door`'s "unnamed door is touch-openable, so let +use do it too" term
(`sv_doors.qc:1420`) and opened; the named one failed that term and got `door_use`'s
locked click.

`sv_water.qc` now drops that superset for water (both halves of its justification fail —
`func_water` forces PASS_THROUGH so no pool ever gets a touch field, and GoldSrc's water is
`SOLID_NOT` so its `DoorTouch` can never fire either), and `sv_use.qc` gets a `func_water`
arm beside the `func_door` one. **Deliberately not generalised to the door classes:** 15
doors across pizza_ya_san1 and th_ep1_01 are unnamed with no bit 256 and are +use-able
today only because of that term — for a solid door the superset is legitimate.

### 3. The medkit could not be dropped — and the draw animation was the tell

`W_DropCurrentWeapon` resolves a drop function from a hardcoded list plus the primary /
secondary / melee slot bindings. `WEP_MEDKIT` is in none of them, and `.slot_utility_drop`
— which `W_UtilityRefreshSlotBinding` (`sv_weapons.qc:3742`) does set to `W_MedkitDrop` —
was a **write-only field this dispatcher never read**. So impulse 8 hit the `if (!drop_func)
return;` early-out. CSQC had already predicted the drop; the correcting snapshot putting
the medkit back is what replayed the deploy animation on every press.

Four more edits were required to make the drop usable rather than merely happen:

- **Vacate before asking.** The medkit's ownership is "the utility slot holds it", not an
  ammo pool, and `W_UtilityNextCarried` walks the ring inclusive of `from_wep` on its last
  step — so asking what remains while the cursor still names the medkit hands the medkit
  straight back, and `W_SelectStrongest` re-deploys it. The ordnance needs no such step
  because their drop functions zero the pool that *is* their ownership test.
- **Hand the charge over.** Without `self.ammo_medkit = 0` in `W_MedkitDrop`, `weapon_touch`'s
  duplicate-utility reject means you could never pick your own medkit back up.
- Both mirrored on the client (`cl_weapons.qc`, `CSQC_MedkitDropClear`) or prediction
  disagrees with the server.

Left alone, filed separately: the SOFLAM and the penguin are undroppable for exactly the
same reason (this map's script registers `weapon_as_soflam`), and
`W_DropAllWeaponsOnDeath` carries its own copy of the same hardcoded list.

### 4. Respawn delays — **`-1` means "never" in Sven too**

Sven's encoding is `-2` = use the game default (it respawns), `-1` = never unless the
entity carries `m_flCustomRespawnTime`, `0` = instant, `>0` = seconds. `Pickup_RespawnDelay`
folded **both** negatives into "never", deliberately, so the campaign corpus would not start
respawning when the code landed. The side effect was that **no value at all asked for the
game's own schedule**, and a `server.cfg` copied from a Sven server read as "never".

`-2` now returns HL's own constants (`multiplay_gamerules.cpp:45-47` — 20 s weapons and
ammo, 30 s items), and the campaign protection moves to the **default**, which drops from
`-2` to `-1` in `sh_cvar_table.qc`. Net effect on a server that never touches these: none.
`cfg/server.cfg` moved to `-2` so this map behaves.

Note for the reporter: `-1` was never going to work — it means never in Sven as well.

Not fixed, noticed: `Pickup_RespawnThink` restores every non-weapon pickup at
`'-16 -16 0'..'16 16 16'` while `item_healthkit` spawns at `16 16 32`, and does not re-apply
`sequencename` or `scale`. This patch makes that visible for the first time, because before
it nothing ever respawned.

### 5. Music — FTE will not loop an mp3, and playmode was read by nothing

`bgm_main` & co. are `playmode 2` on an `.mp3` with `spawnflags 17` — bit 32 ("not
looped") is clear, so the map is asking for a loop. FTE self-loops a sample **only** when
the file carries WAV cue points; `snd_minimp3.c` hands `ResampleSfx` a hardcoded
`loopstart -1`, so every mp3 ambient played once and stopped. `AmbientGeneric_IsLoopMode`
was missing entirely — playmode's loop half was declared at the top of the file and read by
nothing.

`SOUNDFLAG_FORCELOOP` is now set at spawn for playmode 2/6 with bit 32 clear. It is tested
*after* `sfx->loopstart`, so it is inert on a cue-carrying WAV — the 22 playmode-2 WAV
ambients already measured across the corpus are unaffected in practice.

The stop needed its own fix: a volume-0 `sound()` does **not** end a `CF_FORCELOOP`
channel, and neither cancel that looks obvious reaches a client (an empty sample never
leaves the server; `stopsound`'s index-0 packet is dropped client-side before the stop
branch). `AmbientGeneric_Silence` issues `common/null.wav` reliably on the same
ent+channel, which is the only thing that works. This matters here because every `bgm_*` is
a toggle pair fired by two different multi_managers.

`playmode 0` is deliberately left alone: GoldSrc plays a cue-less sample once there.

### 6. The customers stood because the claim retry gave up

The seated pose is not set by the scripts that walk them to the chairs. Four *other*
`scripted_sequence`s — `scrp_jk2` / `scrp_farmer2` / `scrp_electro2` / `scrp_gamesaba2`,
plus `scrip_mi2` — carry `m_iszIdle "sit_pizza"` / `"sit_bigmac"`, `m_flRadius 512`, and
**nothing in the BSP targets any of them**. Their only route to an actor is `Script_Think`'s
claim-retry loop, and that loop gave up permanently after `SCRIPT_CLAIM_TRIES` = 120 tries
(~565 s of map time). Their actors are `sq_kyaku2` children, which cannot exist until the
players have voted the map open and pressed fifteen `ml_gomi*` buttons. Past the deadline
the customers stood at their chairs for the rest of the map with no recovery path.

HL's `CineThink` (`scripted.cpp:476-489`) retries at 1 Hz forever. So do we now; the old
threshold survives as a one-shot log line so a genuine mapper typo is still visible.

Headless run confirms the shape exactly: all five scripts print `cannot find` once at t≈2
and are still retrying when their actors appear at t≈67.

**Timing caveat, stated plainly:** whether this is the *whole* cause depends on how long
the run took to clear the fifteen buttons. Under ~8 minutes and there is a second cause
still to find; over ~9.5 and this is all of it.

### 7. NPC hitboxes — expansion was fine, the visualiser was player-only

Two separate answers, because the report asks two things:

- **Do NPCs pass the expansion check?** Yes. `W_MonstersExpandHitboxes` is a separate walk
  with no "is a player" gate, running inside the same bookend players use.
- **Why did nothing draw?** Both emit sites hard-filtered on `classname == "player"`, and
  they could not simply be widened: the player wire carries the entity id as a single
  **byte** and monster edicts routinely pass 255, the CSQC continuous ring is an array
  indexed by entnum sized 32, and the draw loop uses the 20-entry IQM **player** bone table,
  which is meaningless on an HL `.mdl`.

New event `CSQC_EVENT_SERVER_NPC_HITBOX` (65) carries a SHORT entnum plus the single
expanded cull AABB — recomputed server-side with a derivation kept identical to the expand
walk, because by the time a hit is processed the bracket has already restored. Drawn
yellow, to stay distinct from the orange player bone boxes and cyan `cl_debug_hbexpand`.
Mode 2 is bounded (NPCs within 1024 units of a player, at most 32 per tick) since
`MULTICAST_PVS` filters delivery but not the walk.

**Design note worth confirming:** this is the one box QC can know. An HL model's real
per-bone studio hitboxes are unreadable from QC — `addmodelhitbox` is the only hitbox
builtin in either VM and it is write-only — so per-bone wireframes on NPCs would need a new
engine builtin. Direct test of the expansion question: set `sv_hitbox_expand 0` and the
boxes must shrink to the raw hull.

### 8. Shock rifle — a server stall, not a HUD stall

`W_ShockFrame` set `wep_nextframe = 0` the instant the weapon went idle, and that frame
function is the **only** per-tick caller of `SH_ShockRegrow` (the other caller needs the
trigger). So the charge advanced for exactly the 0.333 s the fire animation lasts and then
froze. The client was faithfully rendering a stuck server value. The frame function now
retires only when idle **and** full.

Adjacent, not fixed: the hornetgun has the byte-identical defect, and the regrow still does
not run while the weapon is holstered (in OpFor the shock roach is a living creature that
recharges in your pocket — that needs a carrier-level tick, not a weapon frame).

### 9. Baby voltigore — it inherited an attack its rig does not have

`Voltigore_ClassInit` leaves `ai_range_range` at 1024, so `AI_CheckAttacks` raised
`COND_CAN_RANGE1` for any enemy in sight and the ladder returned `SCHED_RANGE_ATTACK1`
*before* it could ever fall through to `SCHED_CHASE_ENEMY`. That schedule is stop / face /
attack with no movement task in it. And the attack does not exist on this rig: read out of
the file, `baby_voltigore.mdl`'s `distanceattack` carries activity 0, actweight 0 and
**zero animation events**, where the adult's carries activity 28 and event code 1. So it
resolved to sequence 0 — idle1 — stood there 1.25 s, armed a cooldown, and repeated
forever. Sven's own manual agrees with the rig: baby "Weapons: Swipe" against adult
"Weapons: Lightning; swipe".

`ai_range_range = 0` removes the opportunity outright. Speeds were also wrong — 45/280 were
the garg pair's *ratios* applied to the adult's figures; measured off this rig with the
formula the adult's init states, walk is 12 and run is 111, so it had been skating at 3.7×
and 2.5× too fast.

### 10. "leader" fired his gun by holstering it

A replacement model keeps the rig and loses the name. `Grunt_RigOverride` tests model-name
stems, so `models/pizza_ya_san/emptake.mdl` matched nothing and the NPC kept `Barney_Event`
from `Barney_ClassInit`. `emptake.mdl` *is* the medic rig — weapons bodygroup `de` /
`pizzamed`, plus `pull_needle` / `give_shot` / `heal_crouch` — and its `crouching_mp5` and
`standing_mp5` each carry event code 4. Code 4 is `HGRUNT_AE_BURST1` (`hgrunt.cpp:81`); in
Barney's vocabulary it is `BARNEY_AE_HOLSTER` (`barney.cpp:37`). He played the firing pose,
the event arrived, and the handler put his gun away.

The branch now also claims `monster_human_medic_ally` when the model actually carries
`crouching_mp5`. Both halves are required: the classname is the mapper's statement of
intent, the sequence is proof the model can honour it, and a medic reskinned onto a
barney-rigged model must stay on `Barney_Event`. `weapons 1` on `monster_human_medic_ally`
is Desert Eagle per the FGD, which is what the branch already installs, and matches
`emptake.mdl`'s weapon submodel literally named `de`.

Not fixed, and the other half of "no sound" if pain/death lines were meant: the map's
`soundlist ../pizza_ya_san/emptake.txt` remaps `fgrunt/death*` and `fgrunt/pain*`, paths our
medic never emits because `Barney_ClassInit` gives him `barney/ba_pain*` and talk group
"BA". The map author writing an fgrunt-keyed list for this NPC is direct evidence that
Sven's `monster_human_medic_ally` is an fgrunt derivative rather than a Barney.

### Build

All three VMs rebuilt clean, 0 warnings: `qwprogs.dat`, `csprogs.dat` (packed to
`quakers_csprogs.pk3`, loose copy removed), `menu.dat`. No engine change this patch.
`pizza_ya_san1` loads headless with no QC errors.

---

## PATCH 167 — the black `{` faces are not the mask, and the proof is in decals.wad

**Report:** `cl_debug_surface` on `pizza_ya_san` reads `Look ent: worldspawn`,
`Any brush: (none)`, `Ground tex: {stripeh` — "supposed to be a solid normal texture,
but it's pitch black", offered as the same fault as th_ep1_01's black transparent faces.

### What the readout settles

`worldspawn` with no brush entity in the ray means the surface has **no rendermode at
all**. Every earlier theory that keyed on `rendermode 4` therefore cannot be the shared
cause of the black surfaces — a world face has nothing to key on.

### `{stripeh` decoded, and what it rules out

`{stripeh` is a real lump in `decals.wad`, and both copies on this machine were decoded
(Sven Co-op's `svencoop/decals.wad` and Half-Life's `valve/decals.wad`):

    128x32, offsets (40, 4136, 5160, 5416), 256-entry embedded palette
    index 255 used by 0 of 4096 texels
    MASKED decode -> mean RGB (223.7, 223.7, 223.7), alpha 255 everywhere

So under `W_ConvertWAD3Texture`'s masked path the texture comes out **near-white and
fully opaque**, exactly as the zebra-crossing paint it is. Two conclusions follow, both
negative and both worth having:

- **The texture data is not the fault.** It decodes correctly today. (The `asdecal`
  gate added earlier — `wad.c:422-437`, which names this very map and texture — is
  doing its job; the old "dark red at alpha 24..58, all 418 faces invisible, sky
  showing through" symptom is gone.)
- **The alpha test is not the fault either.** With alpha 255 on all 4096 texels,
  `MASK=0.666` + `MASKLT` discards *nothing* on this surface. A black `{stripeh` face
  is a fully-drawn face whose colour came out zero, which puts the fault in the
  **shading**, not in the texture and not in the masking.

### What was fixed anyway — `r_goldsrc_worldmask`

Found while chasing the above, and real regardless of it. GoldSrc alpha-tests a
`{`-masked texture **only** when the surface belongs to an entity whose Render Mode is
Solid (`kRenderTransAlpha`); on a world brush it draws palette index 255 as its literal
colour. That is precisely why every mapping guide tells you to tie a `{` brush to a
`func_wall`/`func_illusionary` before it will go see-through.

`Shader_DefaultBSPQ1` (`gl_shader.c:7387`) keys purely on the leading `{` and hands
every such texture `defaultwall#MASK=0.666#MASKLT`, world faces included — so a world
floor textured `{something` becomes a stencil and you look through it into the sealed
void. Now gated: a `{` texture that **no submodel uses** is registered through
`Shader_DefaultBSPLM` instead and loaded as `TF_MIP4_8PAL24` rather than `_T255`.

Both halves have to change together. The T255 decoder writes RGBA `0` for index 255
(`image.c:13275`), so dropping only the alpha test would paint those texels transparent
**black** — the same symptom by a different route.

New files/lines: `Mod_MaskedTextureIsWorldOnly` and the cvar in `gl_model.c`, extern in
`render.h`, `Cvar_Register` in `renderer.c`. `r_goldsrc_worldmask 0` restores the old
behaviour; takes effect on the next map load.

Deliberately narrow. Anything a submodel touches keeps the mask, so fences, ladders,
grates and hedges — always brush entities in a GoldSrc map — cannot be affected, and a
texture shared between world and entity is left alone rather than guessed at.

### Measured effect: nothing, on every map on this machine

Every GoldSrc BSP available locally was scanned for `{` textures per model:

| map | world-only (now opaque) | shared | entity-only (unchanged) |
|---|---|---|---|
| `css_dust2_go` / `_se` / `_sky` | none | `{invisible` | the rest |
| `th_ep1_01` | **none** | none | `{BN_tree3 {grate3a {grate3b {icicle1 {invisible {ladder2 {nm_they6` |
| `th_ep1_00` | **none** | none | `{invisible {nm_grate1 {nm_neonsign {nm_they5 {tension3` |

**th_ep1_01 has zero `{` textures on world faces**, so this fix cannot be the cause of
the black brush entities there either. It closes a class of bug; it does not close
this one.

### th_ep1_01's three black entities, named exactly

Read off the BSP rather than guessed:

    *247  10 faces, all {ladder2
    *292   6 faces: 4x nm_metal8 + 2x {grate3a
    *522   6 faces, all {grate3a

`*292` mixes a **plain** texture with a `{` one on the same entity, which is the cheapest
discriminator available: if the `nm_metal8` faces of that door are black too, `{` is not
the trigger at all.

Also ruled out: all six WADs the map asks for (`halflife liquids xeno decals neilm2
neilm4`) are present, so this is not a missing-WAD failure. And a `{` texture that fails
to resolve already draws as **nothing**, not black (`image.c:14787`), printing a
`developer 1` warning when it happens.

### Still needed to close it

One line each, and they separate the last two possibilities:

- `r_showshader {grate3a` (and `r_showshader {stripeh` on pizza_ya_san) — whether the
  masked shader is the one actually in use, and what its passes are.
- `r_imagelist_wad` / `r_imagelist` — whether the image resolved, at what size and format.
- Free, from what is already on screen: on `*292`, are the `nm_metal8` faces black as
  well, or only the `{grate3a` ones?

Built and deployed: `fteqw64.exe` 8,017,063 and `fteqwsv64.exe` 3,202,814, both targets
clean. No QC changed.

---

## PATCH 166 — twenty-one reports, and the two biggest were one word and one commented-out block

**Reports (verbatim, th_ep1_01 unless noted):** cockroaches not fleeing flashlights,
sounding like bullet ricochets when stepped on, and now vanishing; `monster_furniture`
foliage and three `rendermode 4` brush entities still drawing black faces;
`monster_scientist_dead`'s foot texture flickering and stretched; `env_shooter`'s
`gib_skull` half in the ground with a point-sized hull; `waitforscript` zombies showing
an HP tag while buried; an NPC apparently despawning after walking into another;
`func_water water_pool` making the player unable to swim up and snapping them down
10-20 units; `trigger_teleport lower_tp_dest`'s Relative flag behaving like a plain
teleport; `weapon_medkit` on friendly NPCs and on un-spawned players; worldspawn water
side faces drawing an invisible texture inward; NPCs not hearing the player and zombies
not waking from an eating sequence; NPCs re-dying on PVS re-entry; `whatare_mngr`'s
sequence playing in slightly wrong order; `func_button jp_telein` spawning the wrong
model; a switch for Half-Life's HD models; `monster_barney` firing with no glock
visible; `weapon_wrench` missing GoldSrc's charged `+attack2`; `point_checkpoint` not
moving where you respawn; `monster_barnacle` picking up nothing; leeches dead before
the player reaches them; and `func_monsterclip` blocking NPC attacks through it.

Seventeen were fixed, four are diagnosed and listed at the bottom with what they need.

---

### 1. The cockroach: three separate things, and one of them was mine

**"Sounds like bullet ricochets when stepped on."** It was a ricochet, and it always
has been for *every* flesh hit in the game. `CSQC_FireImpactCosmetics` skips
`MatSnd_SetForImpact` for `IMPACT_MAT_FLESH` (a body has no material entry), so
`ricsnd` stayed empty and flesh fell into the `ric1..5.wav` fallback below it — a
bullet PING off a person. Under gunfire the shot masks it, which is how it survived;
the squash splat added in Patch 165 fires one flesh impact into a silent room and
there is nothing to hide behind. Flesh now plays the HL flesh set
(`sounds/debris/impact_fleshhl1..6.wav`, already on disk and already precached at
`sh_customdefs.qc:1551` for the `func_breakable` FLESH style) at 0.7 volume.

**"Now vanish when stepped on, I don't want them to vanish."** That is Patch 165's
`UTIL_Remove` being faithful (`roach.cpp:182`) and not wanted. The problem removal was
solving is real, though: `roach.mdl` has no death sequence, so a corpse falls back to
its idle cycle and lies there scurrying — the earlier "their little antennae keep
moving". `.animrate` solves both. It is Half-Life's `pev->framerate`, networked under
`PEXT2_FRAMERATE`, and it multiplies playback **on the client**, which is where the
runaway cycle lives. The value is not arbitrary: the wire encoding is
`(rate - 1) * 64` truncated to a short (`sv_ents.c:3695`) and QC 0 is reserved to mean
"normal speed" (`:3694`), so zero cannot be asked for directly. `-0.001` encodes to
`(int)(-64.064) = -64`, which the client decodes as exactly `-64/64 + 1 = 0.0`
(`cl_ents.c:4418`). Frozen, not merely slow, for two payload bytes on the roaches that
actually die.

**"Doesn't run from flash lights."** The roach is the one class in the SDK whose
primary sense is light: `CRoach::MonsterThink` samples `GETENTITYILLUM` every think and
a rise of more than 10 sends it straight into its scared state (`roach.cpp:206-224`).
There is no `GETENTITYILLUM` here and it cannot be had cheaply — FTE's lightmap
sampling is a renderer concern and the light that matters is a **CSQC dlight the server
has never been told about**. So the fact is imported rather than measured:
`cl_flashlight.qc` sends `cmd fl <0|1>` on the toggle edge (reliable channel, so no
re-assert is needed), `SV_ParseClientCommand` records `.player_flashlight`, and the
roach's `.ai_tick` does the geometry — 600-unit range, ~68 degree cone, clear line —
and latches `roach_lit_until` for 3 s so a wobbling aim at the cone edge does not
flicker it between fleeing and idling. The command is purely informational: nothing
about the player's own state reads it, so the worst a lying client can do is spook a
cockroach that should not have been spooked.

---

### 2. `monster_barney` fires with an empty hand — one word

`Grunt_BodyInit` resolves the weapon submodel per rig, and its barney branch was

```qc
if (Rig_StemIs(mdl, "barney") || Rig_StemIs(mdl, "bodyguard"))
```

`Rig_StemIs` is a **prefix** test. Every reskin of that rig puts the family name at the
END of the filename — They Hunger's `hungerbarney.mdl` and `hungerotis.mdl`,
Half-Life's own `barney_helmet.mdl` and `barney_vest.mdl` — so the branch matched none
of them. A rig that matched nothing fell out of the ladder with `wb` still 0 and
`.ai_body_armed` still 0, and **0 on all four of those models is the HOLSTERED
submodel**. The guard drew, aimed, fired and killed you with the pistol still on his
hip.

Verified against the files rather than assumed: `barney.mdl` (valve, valve_hd and
svencoop), `hungerbarney.mdl`, `sheriff.mdl` and `pilot.mdl` all carry a 3-submodel
`gun` group at bodypart[1] base 1, ordered holstered / drawn / blank. `otis.mdl` and
`hungerotis.mdl` carry the same group in the same place with a DONUT where the blank
would be, which is why that branch keeps its own `gone`.

New `Rig_StemHas` (substring) is used **only** for the bodygroup layout — the question
where a reskin answers the same as its parent by construction, because a model that
borrowed barney's skeleton borrowed his gun group with it. The rig DISPATCH keeps
prefix matching, because that is where a wrong answer swaps an entire event handler
(`hgrunt_opfor` must never collapse into `hgrunt`).

---

### 3. `func_button jp_telein` spawns the wrong model — one filename

`sven-coop.fgd:4005` declares

```
@PointClass base(Monster) ... studio("models/bgman.mdl") = monster_bodyguard
```

and `Monster_ModelFor` asked for `models/bodyguard.mdl`. There is no such file anywhere
in the Sven mount — the only ones of that name are PLAYER models under
`svencoop_downloads/models/player/`, which this has no route to — so the primary always
missed and every bodyguard in the corpus silently fell through to Barney. th_ep1_01's
church button drives a squadmaker whose `monstertype` is `monster_bodyguard` and whose
`displayname` is JPolito, so pressing it produced a Barney with someone else's name
over his head.

`bgman.mdl` is **not** laid out like barney's: bodypart[1] is a 2-model HEAD group at
base 1 and bodypart[2] is an 8-model GUN group at base **2**, so the gun costs two per
index and submodel 0 is the blank rather than a holster. The eight guns are in the
FGD's own order — blank, pistol, deagle, shotgun, akimbo uzis, mp5, sniper, minigun —
which is also what its `weapons` key selects, so the key indexes the group directly
instead of going through the hgrunt bitfield. It gets its own branch, tested BEFORE
barney's, because "bodyguard" used to land there and take 0/1/2, which on this rig
means *empty-handed with the second head*.

---

### 4. NPCs re-die when you walk back into the room — Spike's own commented-out block

`CL_UpdateNetFrameLerpState` (`cl_ents.c`) carried this, commented out:

```c
//	if (force)
//	{
//		//if its new, we need to tweak the age of the animation. looping anims won't appear
//		//any different, while non-looping ones will clamp to the last pose when its new.
//		le->oldframestarttime[fst] -= Mod_GetFrameDuration(le->model, 0, le->oldframe[fst]);
//		le->newframestarttime[fst] -= Mod_GetFrameDuration(le->model, 0, le->newframe[fst]);
//	}
```

It could not be enabled as written because it asks for `le->model` and `lerpents_t` has
no such field. The symptom without it is exactly the report: a dead monster holds the
last frame of a non-looping death sequence, and the whole of that pose is a function of
`cl.servertime - newframestarttime`. Drop the entity out of the PVS and bring it back
and `isnew` is set, that timestamp is stamped to NOW, and the death plays from the top.
**The server is not involved and cannot be** — the animation clock for a networked
entity is entirely client-side, so no amount of QC could have fixed this.

The model is now passed in from the two callers that have an `entity_state_t` (and
therefore a modelindex); the player path passes NULL and is byte-identical. Back-dating
by one sequence duration puts a non-looping animation straight at its clamped final
pose and leaves a looping one on exactly the phase it would have had anyway — a whole
period earlier is the same place in the cycle. So idle and walk cycles are unchanged
and only the once-through animations move, which is precisely the set that was wrong.
`animphase` (the rate-scaled clock, Patch 155) is seeded to match.

---

### 5. `func_monsterclip` blocks bullets and line of sight — hull 0 does not exist here

GoldSrc compiles `CONTENTS_CLIP` into the COLLISION hulls only. Hull 0 — the point hull
that bullets, LOS checks, gunfire and every other traceline run through — contains no
clip geometry at all, which is why a Half-Life monster penned in by a monsterclip can
still shoot straight through it.

A forced-contents entity has no hulls of its own to differ: the same brush answers
every trace shape identically. `func_monsterclip` is `SOLID_BSP` with
`.skin = CONTENT_MONSTERCLIP`, a monster's trace mask DOES include MONSTERCLIP
(`world.c:2844` gives an `FL_MONSTER` `SOLID_SLIDEBOX` box that bit), so its bullets and
its sight stopped at the volume along with its feet.

`World_ClipMoveToEntity` now treats a forced contents that is **nothing but clip** as
absent from a POINT trace (`mins == maxs`, necessarily the origin — exactly the hull-0
case). Movement is a box trace and is untouched, and so is the nav builder, which sweeps
`NAV_SWEEP_MINS/MAXS`. A brush forcing water, solid, ladder or corpse keeps blocking
point traces exactly as before.

Measured: `th_ep1_01` nav went `components=41 largest=710 (1257 nodes) isolated=20` →
`components=41 largest=712 (1260 nodes) isolated=19`. Three more nodes placed, one
fewer island, same component count — the drop probes that place nodes are tracelines and
now see through the three clip volumes, while every link test still respects them
(`[nav] func_monsterclip volumes: 3` unchanged).

---

### 6. `func_water`: `PM_StayOnGround` was fighting the swim

`PM_StayOnGround` snaps the player down by up to `PM_STEPSIZE` — **18 units**, which is
exactly the reported 10-20 — and it is called from the WALK branch of `PM_PlayerMove`,
i.e. whenever `pm_waterlevel < 2`. At the surface of a pool the water level flips
between 1 and 2 tick by tick as the player bobs: on a level-2 tick `PM_WaterMove`
carries them up, and on the very next level-1 tick this call finds the pool floor within
a step and puts them straight back on it. The two fight, and the player cannot climb
out.

`water_pool` makes it unmissable because the pool RISES — the player starts standing on
a floor well inside step range, so the snap has something to grab from the moment the
water reaches them.

Vanilla Quake never had this problem because it has no `StayOnGround`; the call is
Source's, imported for slope walking, and a swimmer is not walking a slope. Gated on
"wet and moving up" (`pm_waterlevel >= 1 && pm_velocity_z > 0`), which keeps every
dry-land case byte-identical because `pm_waterlevel` is 0 out of water.

**Refuted on the way:** the obvious suspect was the client predicting the rising brush
as a pusher (`MovingBrush_AddToList` takes every `BRUSH_TYPE_DOOR` with velocity, and
`func_water` IS a `func_door`). It does not: both the carry probe and the geometry probe
are traces with the PLAYER as passedict, and a player's contents mask never includes
water, so the forced-contents arm of `World_ClipMoveToEntity` returns a clean miss on
both ends. The server's `Mover_GeometryBlockPush_Player` is the same shape and the same
answer. Nothing was changed there.

---

### 7. Relative teleport (`spawnflags 128`)

`Teleport_NormaliseFlags` explicitly dropped bit 128 as unimplemented. th_ep1_01's lift
shaft is built entirely on it: `*531` at origin `(1372 -160 70)` → `lower_tp_dest` and
`*528` at `(3808 -4816 -1906)` → `higher_tp_dest`, both `spawnflags 901`
= 512 Keep velocity | 256 Keep Angles | **128 Relative** | 4 Pushables | 1 Monsters.
Dropping 128 turned an endless shaft into two ordinary teleporters that slam you onto
one fixed spot.

A relative teleport moves you BY the offset between trigger and destination rather than
TO the destination, so you arrive holding the same position within the volume, the same
facing and the same velocity. The offset is measured from `.origin` — Sven works in
`pev->origin` and these triggers all carry an explicit origin key for exactly that
reason. Both ends are already on the `trigger_teleport` wire, so this needed no protocol
change. The `'0 0 1'` that `trigger_teleport_resolve` adds is taken back off (it is an
unstick nudge for an absolute arrival and must not accumulate over hundreds of shaft
passes), and the GoldSrc feet/centre hull lift is skipped because that convention
cancels out of a difference of two origins.

`TELEPORT_KEEPANGLE` turns out to be read by nothing at all — the mod has always kept
the player's view angle through a teleport — so relative arrives with angles preserved
for free.

---

### 8. The scientist's foot — `tcgen environment` is not GoldSrc chrome

`models/hunger/scientist.mdl` has 70 textures and exactly ONE with flags:
`tex[28] "Sci2_Chrome1.bmp" flags=0x3` = FLATSHADE|CHROME.

Patch 132 made chrome reachable at all (`#usemods`, without which the tcgen was silently
discarded). It routed it through `tcgen environment`, which is Q3's **reflection** map
computed in the ENTITY's own frame, taking components [1] and [2] of the reflection
vector. GoldSrc's `StudioSetupChrome` is a **matcap**: it builds the s/t axes from the
VIEW's right and up and maps the vertex NORMAL onto them, so the pattern is fixed to the
SCREEN and the model turns inside it. The difference is that FTE's pattern is fixed to
the MODEL and slides across it as the model rotates — which swims on a standing
scientist, and on a corpse, whose entity axis is rotated ninety degrees, picks the wrong
two axes entirely.

New `tcgen chrome` (`gl_backend.c`), used by `HLSHADER_CHROME` and
`HLSHADER_FULLBRIGHTCHROME`. Its own mode rather than a change to `tcgen_environment`,
because every Q3 map in the corpus uses `tcgen environment` for real reflections and
must not move. The per-bone refinement is deliberately not reproduced — it only bends
the mapping for bones well off the view centre — but the basis now follows the camera,
which is the part that was wrong.

`HLSHADER_FULLBRIGHTCHROME` also asked for `program defaultskin#CHROME`, and `#CHROME`
is not a permutation (Patch 132's own note says so). It was therefore failing the same
`calcgens` test that made plain chrome unreachable before that patch — fullbright-chrome
textures were drawing at their placeholder texcoords the whole time. It is `#usemods`
now, and the token that did nothing is gone.

---

### 9. Half-Life HD models — a switch that had to go in the engine

`valve_hd` is a sibling gamedir holding nothing but `models/`, `sprites/` and `sound/`
overrides (104 models). Mounting it is not enough on its own: every `fs_addons.txt` game
is added at the TAIL (`FS_Addon_Mount`'s `SPF_ADDON`), and `FS_Addon_SaveList` appends a
new line at the END of the file — so `fs_load steam:Half-Life/valve_hd` lands BELOW
`valve` and loses every lookup. The order that makes it work is the one thing an addon
list cannot express.

`fs_hdmodels` (archived, default 0) makes `FS_Addon_MountHD` mount each line's `_hd`
sibling immediately BEFORE the line itself, in both the eager (`FS_RemountAddons`) and
the lazy on-demand (`FS_UseAddons_f`) paths — the second is the one that matters, since
`fs_lazyaddons` defaults to 1. PROBED, not merely resolved: `FS_Addon_Resolve` succeeds
for `steam:Half-Life/valve_hd` purely because the STEAM GAME exists and `VFSOS_OpenPath`
does not validate the directory either, so without the `Sys_EnumerateFiles` probe every
game without an HD pack would mount a phantom empty searchpath apiece. It covers
`bshift_hd` and `anticlimax_hd` for free.

Settings → Graphics → **HD Models**. The toggle issues `fs_restart` only from the main
menu with nothing loaded — the engine's own note on the lazy-mount path says a rebuild
"would dangle the loaded content -> crash" — and otherwise records the choice for next
launch.

---

### 10. `point_checkpoint` as a respawn point — a deliberate divergence

Sven's `point_checkpoint.as` does exactly one thing with the dead: `RespawnThink` walks
the client list and revives players whose `m_fDeadTime` predates the touch, moving each
to `self.pev.origin` (`:214-219`). It never touches the spawn set, so a player who dies
AFTER the checkpoint goes back to the map's spawns and the checkpoint has no bearing on
them. On the They Hunger campaign that gap is papered over per-map by `trigger_respawn`
plus swapped spawn-point groups (`churchrespawn`, `spawn02`), which is a lot of map work
for a thing the checkpoint is already standing there to mean.

`cp_respawn_at` is latched on touch and read at the top of `PlayerPlaceAtSpawnPoint`,
ahead of the spawn-point search — there is nothing to blend, and running the search
anyway would fire `Spawn_NotifyUsed` on an `info_player_deathmatch` nobody arrived at
(spawnflag 32, "Trigger on spawn", is live on this corpus). A global rather than a
per-player field because a checkpoint in a co-op campaign is a party-wide fact.
`sv_checkpoint_respawn 0` restores the script-faithful behaviour.

---

### 11. `weapon_wrench`: the charged swing

Mirrors `sh_wpn_oppipewrench.qc`'s secondary, which was already the shape: hold
`+attack2` to wind, release to swing, damage decided by how long it was held, and
releasing early costs the charge. Numbers scaled rather than copied — the pipe wrench
swings for the crowbar's 25 and charges to 60 (2.4x for 2.4x the recovery); this wrench
already hits for 60, so the same ratio puts the charged swing at 150.

The viewmodel is a Quake MDL with 71 unnamed frames and no authored wind-up, so the hold
pose is frame 13, the last frame of the swing's own wind-back. Holding a frame is free
here precisely because the frames are numbered rather than sequenced: there is no
animation clock to clamp or loop.

The charge itself stays server-side for the reason the pipe wrench gives — what would be
predicted is a damage number that depends on how long a button was held. The **pose** is
predicted, though, and that is new for both weapons' shape: a charge you cannot SEE
reads as a button that does nothing, which is how the pipe wrench's identical secondary
has been shipping. The local client already knows whether `+attack2` is down and a pose
carries no damage, so predicting the hold cannot desync anything.

The button-up edge is caught in `W_WrenchFrame`, not in `.altrelease` — that is called
on EVERY frame the button is up (`sv_weapons.qc:4666`), not on the transition.

---

### 12. The barnacle caught nothing — another hull that does not exist

`Barnacle_FindVictim` swept a downward `tracebox` with the box `('-12 -12 0' ..
'12 12 0')`, and on a GoldSrc BSP there is no such hull. `Q1BSP_ChooseHull`
(`q1bsp.c:1554`) picks by width: 24 is over the 3-unit point threshold and under 32.1,
so every one of those traces silently became the **32x32x56 player hull**, and `:1570`
re-anchors it at the requested MIN corner — which for a box asking for zero height
shoves the hull 36 units down and 20 units UP, straight into the ceiling the barnacle is
bolted to. The trace started solid, `trace_ent` came back as the world, and the search
returned "nothing here" for the entire life of the map. `sv_compatiblehulls` is 1 by
default, so `World_Move` never even tries a best-fit.

The column is tested arithmetically now, against the two entity lists that can contain
prey: horizontal footprint overlap against the tongue radius, below the barnacle, no
further down than a `MOVE_NOMONSTERS` line reaches, and with a clear point trace to the
victim's top. Exact at any radius, needs no hull the BSP does not have, and cheap.

That also lifted the PLAYER-ONLY restriction, which was never Half-Life's —
`CBarnacle::TongueTouchEnt` tests `FL_MONSTER|FL_CLIENT` (`barnacle.cpp:407-425`).
Players and monsters are frozen by different mechanisms because they are moved by
different code: a player by the replicated `pm_movetype` freeze (or the client walks out
of the tongue and gets yanked back once a tick), a monster by parking its think, the
same lever `AIDbg_Freeze` pulls. A monster already under script control, or one bolted
down (`AIMODE_STATIC`), is refused.

---

### 13. `env_shooter`'s skull half in the ground

`CGib::BounceGibTouch` (`combat.cpp`) ends with three lines this had none of:

```c
pev->angles.x = 0;  pev->angles.z = 0;
pev->avelocity.x = 0;  pev->avelocity.z = 0;
```

Without them a piece keeps whatever pitch and roll the tumble left it with — and keeps
TUMBLING, because nothing else ever cleared `.avelocity` — so it comes to rest at an
arbitrary angle around an origin that is sitting on the floor. Every one of these models
is authored with its origin at its BASE (`gib_skull.mdl` spans z -0.4..14.0, `ribcage`
-1.3..9.1, `gib_legbone` 0..6, measured out of the sequence bboxes), so tipping it over
is exactly what buries half of it. `skull_shooter` is a 360-second scenery prop that has
to look placed rather than dropped. Yaw is kept, spin included, as HL does — six pieces
out of one furnace shooter should not look stamped from the same die.

The hull also moved off HL's `UTIL_SetSize(pev, g_vecZero, g_vecZero)` to
`('-4 -4 0' .. '4 4 8')`. A single mathematical point comes to rest wherever that one
point finds a floor, including on the lip of a step. `mins_z` is ZERO, which is the
load-bearing part: a box extending BELOW the origin would hold every gib up in the air
by that much, so keeping the box floor at the origin reproduces the point hull's resting
height exactly. Still `SOLID_NOT` — a gib must not push a player or eat a bullet trace.

---

### 14. The HP tag over a buried zombie

th_ep1_01 puts eleven zombies under the graveyard waiting for the `ventclimb` script,
and the turf over them is `func_illusionary` (75 of them on this map), which is
`SOLID_NOT` by definition and therefore invisible to a traceline. So the crosshair
reached straight through the ground, found a live zombie and floated a name and a health
bar over a patch of empty grass. The trace was the readout's only filter.

`SF_MON_WAIT_FOR_SCRIPT` is the exact statement of "this monster is not part of the map
yet" — Half-Life's `MonsterInit` refuses to start such a monster's AI until a script
claims it. New `.ai_script_played` latches the first time any script releases the actor,
which is what makes the spawnflag a runtime question rather than a permanent one:
`.ai_script` is `world` both BEFORE a script claims an actor and AFTER it lets go, so
neither field can tell those two states apart alone. `EF_NODRAW` is checked in the same
breath, being the other way a monster can be present and unseeable.

---

### 15. Zombies that ignore gunfire in the same room

Half-Life's `SCRIPT_BREAK_CONDITIONS` is `bits_COND_LIGHT_DAMAGE|bits_COND_HEAVY_DAMAGE`
and nothing else, so a scripted actor is deaf for the duration. Sven adds no interruption
keys — its `scripted_sequence` spawnflags are Half-Life's exactly. Damage already broke
an interruptible scene here (`AI_Damaged`); noise did not.

`sv_ai_script_wake` (default 1) lets a noise do it too. Three things keep it from eating
the choreography: only a script that already declared itself interruptible (22 of
th_ep1_01's 41 carry `SF_SCRIPT_NOINTERRUPT` and are untouched); only during
`SCRIPTST_WAIT`, so a scene that has been fired runs to the end and nothing a mapper
sequenced can be cut in half; and the cvar itself. 0 is Half-Life exactly, 1 adds combat
and danger noise, **2** adds player footsteps — which is what "when the player is nearby"
literally asks for, and is left off by default because it would also stand up every
interruptible seated scientist in Half-Life as you walk past him.

th_ep1_01's two eating zombies are `eatbody` (`spawnflags 2`) and `getuplad`
(`spawnflags 0`) — both interruptible, both holding `m_iszIdle`, both now woken by a
gunshot inside 1280 units.

---

### 16. Medkit on friendly NPCs

Sven's manual describes the medkit as healing "a player or friendly NPC" and that half
was simply missing — the classname test refused every monster. "Friendly" is asked of
the AI rather than of a spawnflag: `.is_player_ally` is the map's declaration and does
not cover a `monster_barney` who has not been provoked, nor a scientist, nor anything a
map cfg reclassified. A monster that does not HATE you is one you may patch up, which is
the same question the friendly-fire hold already asks. Prisoners are excluded —
`SF_MON_PRISONER` is "this one is scenery".

The cap is per-target now (`W_MedkitTargetMax`): a player's ceiling is 100, a monster's
is whatever `Monster_Build` seated, which ranges from a headcrab's 10 to a gargantua's
800. A fixed 100 would either refuse to touch a wounded grunt or over-heal a headcrab.

REVIVING an NPC stays out of scope for the reason `W_MedkitValidCorpse` already gives —
`sv_ai_gibs.qc` disposes of the body and there is no `AI_Revive` to rebuild it. Reviving
a **player** already works and is unchanged; a player who has not spawned in has no
corpse in the world to point a medkit at, which is a join question rather than a medkit
one.

---

### 17. The leech that was already dead

`AI_PlaceOnFloor` steps up in 4s and re-drops from the first height that is clear, on
the reasoning that "bodies that fail are usually embedded by a handful of units after an
editor nudge or a re-compile". That reasoning is not about gravity and applies to a
swimmer or a flyer word for word — but `AI_PlaceInVolume` gave up on the first probe.

Measured on th_ep1_01: `[ai] monster_leech at 3166 -4670 -2312 could not be placed
(movemode 2)`, and the AI volume report for that map read `clearance min=-1` — ONE unit
of overlap. A leech that fails there keeps its brain (it is map-placed) but can never
take a step, because `AI_StepVolume` refuses every move out of a startsolid position. It
hangs in the rock doing nothing, which is what a player swimming up to it reads as
"already dead".

Six directions per radius, nearest radius first, so the body comes out the shortest way
rather than always upward — a leech embedded in a ceiling and one embedded in a floor
want opposite answers. A swimmer freed into thin air is rejected and the search
continues, since it would only have traded one dead end for a worse one. After:
`[ai] monster_leech freed from geometry: 3166 -4670 -2312 -> 3166 -4670 -2300` and
`clearance min=0` for all three.

**This does not prove they were dying**, only that one of the three could never move.
See the open list.

---

### Build and verification

- All three VMs compile with **0 warnings**.
- Engine rebuilt for both targets: `make m-rel FTE_TARGET=win64` → `release/fteqw64.exe`
  and `make sv-rel FTE_TARGET=win64` → `release/fteqwsv64.exe`. Previous binaries kept
  as `fteqw64.prepatch166.exe` / `fteqwsv64.prepatch166.exe`.
- Headless: th_ep1_01, th_ep1_00 and hl_c01_a1, **0 QC faults** of any kind.
- Nav on th_ep1_01: `components=41 largest=712 (56.5079% of 1260 nodes) isolated=19`,
  against `41 / 710 / 1257 / 20` on the previous engine — three nodes gained and one
  island lost from the monsterclip point-trace change, component count unchanged.
- Volume placement on th_ep1_01: `clearance min=-1` → `min=0`.

### Owed in-game

The harness has no renderer, no audio and no player touching anything, so:

1. **Cockroach** — squash makes a wet flesh sound, not a ping; the body stays and stops
   moving; walking a torch across a floor of them scatters them.
2. **`monster_barney` / `monster_bodyguard`** — the glock is in his hand while he fires;
   the church button spawns JPolito on `bgman.mdl`, not Barney.
3. **Corpses** — leave the room, come back, and nobody dies twice.
4. **`func_water water_pool`** — swim up out of the rising pool without being yanked back.
5. **The lift shaft** — the two `spawnflags 901` teleports should now be invisible.
6. **Barnacles** — on a map that has one, walk under the tongue; it should take you, and
   it should take a headcrab too.
7. **`func_monsterclip`** — a grunt penned behind one should be able to shoot you.
8. **HD models** — Settings → Graphics → HD Models from the main menu, then load a map.
9. **Scientist corpse foot** — the chrome should sit still on the model instead of
   swimming.
10. **`weapon_wrench`** — hold `+attack2`, watch the wrench raise, release for a heavy hit.

### Still open, with what each needs

- **Worldspawn water side faces (report 10).** The engine already has the two tools for
  this: `surf_info` names the texture under the crosshair and `r_hidetextures
  <name>[,<name>]` suppresses it everywhere, world faces and brush entities alike. What
  is missing is the NAME — a scan of the corpus found no texture called `nodraw`, `NULL`
  or `skip`, so there is nothing general to key on. Needs one `surf_info` line off the
  offending face. Note also that worldspawn water is emitted by the compiler on BOTH
  sides of each plane and relies purely on GL backface culling, which is why the inward
  copy exists at all.
- **`rendermode 4` brush entities drawing black (report 2, second half).** `*247`
  `func_illusionary`, `*292` `func_door_rotating` and `*522` `func_breakable` share
  `rendermode 4` + `renderamt 255` + `rendercolor 0 0 0` with the `monster_furniture`
  foliage, but the two halves cannot share a cause: the brushsync path leaves `colormod`
  at `1 1 1` for mode 4, and only `defaultskin.glsl` reads the sunshade knobs that
  explain the models. Needs to be looked at with `r_showshader` on one black face.
  **Re-check the model half first with `vid_reload`** — Patch 165 changed
  `r_shadows_sunshade_floor` in `cfg/default.cfg`, and `!!cvardf` knobs are baked into
  the compiled shader from the live cvar (`gl_shader.c:1964`), so without a reload the
  old zero is still in there.
- **`whatare_mngr` timing (report 13).** The manager itself is two slots, `whatare` at
  t=0 and `zomb_cruisr_mstr` at t=7, and `multi_manager_think` schedules on an ABSOLUTE
  `attack_finished + delay` so it cannot drift or reorder. `whatare` is a
  `scripted_sentence` playing `+hunger/thambs/message_00.wav` with `duration 3`,
  `refire 3`, `radius 512`, `listener player` — the `+` prefix and the duration/refire
  handling are the parts worth suspecting. Needs the observed order versus the expected
  one, or a run with `sv_debug_use 1` (which prints `[mm-fire] '<name>' slot t=<elapsed>`
  for every slot).
- **An NPC despawning after walking into another (report 6).** There is no anti-stuck
  removal anywhere in the AI — `ai_stuck` only re-paths. The **one** path that removes a
  live monster is a squadmaker child that fails placement: `AI_Spawn` strips it
  (`SOLID_NOT`, `FL_MONSTER` cleared) and marks `.ai_placefail`, and the maker then drops
  it and retries next interval. th_ep1_01 has 94 squadmakers, so a wave emitted into a
  body already standing on the spot is very likely what was seen. Half-Life blocks the
  spawn instead of making one and deleting it; matching that is a squadmaker change, not
  an AI one. Needs confirmation that it happened at a spawn moment rather than mid-walk.
- **Leeches (report 20).** One of the three could not move at all and now can. Nothing in
  the tree damages a leech: there is no monster drowning, no out-of-water damage, the
  melee sweep already skips friends (`AI_Hates`), CLASS_INSECT vs CLASS_INSECT is not
  hostile, and no `trigger_hurt` on the map contains any of the three (checked against
  the BSP's own model bounds). A headless run cannot reproduce it because monsters stay
  dormant with no player present. If they are still dead on arrival, `sv_ai_debug 1` plus
  the `[ai] deaths:` counter block will say whether they died at all.

---

## PATCH 165 — eight reports, and four of them were one entity number away from correct

**Reports (verbatim, th_ep1_01):** cockroaches flashing between two positions ~5
units apart every 150-200 ms and never squishing; a `trigger_once → radio_mngr`
that respawns *living* players; the NPC name/HP tag vanishing after ~1 s; a
continuous scraping sound that outlives everything and was seen following an NPC;
`monster_furniture` foliage rendering as black silhouettes and the flashlight not
touching `.mdl` NPCs at all; hit splashes with no HP change, plus a request for a
hitbox debug display; `func_pushable` with no pushback, no working slide sound and
crates that slide into each other and bounce out; and `func_water` tinting the
screen orange with an invisible surface from below.

Eight areas were investigated in parallel and every root cause was then
adversarially re-checked against the source. Three of the first-pass diagnoses did
not survive that and are recorded below as refuted, because two of them are
plausible enough to be re-derived by the next person to look.

---

### 1. The cockroach was crossing an engine cliff nobody knew was there

`mon_cockroach.qc` set `ai_yaw_speed = 360` with the comment *"roaches turn on the
spot instantly"*. After the deliberate `x2` in `AI_ChangeYaw` (`sv_ai_move.qc:213`,
Half-Life's own doubling) that is **72 degrees in one 10 Hz AI tick** — and FTE
refuses to interpolate an entity *at all* on any packet where its facing moved more
than 45:

```
cl_ents.c:4809  cos_theta = CompareAngles(sold->angles, snew->angles);
cl_ents.c:4813  if (DotProduct(move,move) > maxdist || cos_theta < 0.707 || ...) isnew = true;
cl_ents.c:4830  → hard-assigns BOTH origin and angles, old==new, RENDER_STEP smoothing skipped
```

A grunt survives that because it covers a fraction of its own width per tick. A
cockroach is 2 units wide and covers ~11 units per tick — more than a body length —
so the same discarded interpolation reads as teleporting.

- `ai_yaw_speed` 360 → **120**, Half-Life's own number (`roach.cpp:107-114`).
- `AI_YAW_MAXSTEP = 44` now clamps the per-tick step for **every** class, so no
  monster can hand the client a delta it will refuse. It binds only on the four
  classes tuned above 220 and only on a genuinely sharp re-aim. Clamping the *step*
  rather than the *speed* is what makes it hold for a dormant monster too, which
  ticks at 0.5 s.
- `AI_ChangeYaw`'s in-tolerance case was `m.angles_y = m.ai_yaw_ideal;` — a free
  instantaneous rotation of up to 12 degrees every time a monster settled onto a
  heading. It is a clamped step now; the return value is unchanged for every caller
  (none of the four reads it).

**"Rotate toward the direction as you move":** `AI_MoveAlongPath` stepped along
`m.ai_yaw_ideal`, so the body translated along the *wanted* heading while the model
still faced the old one — a sideways slide, not an arc. It now steps along
`m.angles_y` under **`sv_ai_arcturns`** (default 1). This is a deliberate SDK
divergence (`roach.cpp:365` uses ideal_yaw), it makes monsters take wider lines
through doorways, and `sv_ai_arcturns 0` restores the old behaviour exactly.

**The squish nobody could see.** `Cockroach_Touch` passed `other` — the player who
just trod on the roach — as `W_ImpactEffectSend`'s `shooter` argument, and that
function deliberately *skips* the shooter (`sv_weapons.qc:1197`). The one person
standing over the roach was the only client excluded, and nothing client-side
predicts a squash. Now passes `world`, which the function's own comment says is
correct when no client predicted the event. The effect point is also lifted 2 units
off the surface: the decal sprayer traces along `-normal` from the point it is given
(`cl_bloodsplat.qc:329`), and a point sitting exactly *on* the floor started every
one of those traces inside the surface it was trying to mark.

**The antennae.** `roach.mdl` carries two sequences, `run_1` and `run_2`, and no
death. `AI_DeathActivity`'s fallback ladder bottoms out at `ACT_IDLE`, so a dead
roach was put onto its own gait cycle — and `TASK_PLAY_DEATH` then waited for that
cycle to finish before `TASK_DIE` (which removes the body) was allowed to run,
rounded up to whole half-seconds for a monster with no player nearby. `TASK_PLAY_DEATH`
now completes immediately when `AI_HasActivity` says the rig carries no death
activity at all, matching `roach.cpp:182` (`UTIL_Remove` in the same frame).

**Fleeing: yes, but not from across the church.** `CRoach::Look` is a 150-unit
sphere with the visibility trace commented out (`roach.cpp:425-430`). Ours inherited
the global `sv_ai_sight` 2048 and a 120-degree cone, so a roach fled a player it
could see anywhere on the map and did nothing else, ever. New per-class `.ai_sight`
(0 = use the global, so nothing else changes), set to 160 for the roach, with
`ai_fov = -1` for HL's 360-degree awareness.

**Refuted, and worth recording.** The first pass blamed an inverted sweep box in
`AI_LegClear` (`mins_z + 18` against a `maxs_z` of 1) for forcing the roach back onto
waypoints behind it. The box *is* inverted, but it cannot do that: `AI_LegClear`
traces `MOVE_NOMONSTERS`, which clips SOLID_BSP only, so it always goes through
`Q1BSP_ChooseHull` — which **discards the caller's box entirely** whenever
`size[0] < 3` (`q1bsp.c:1554`). The roach is 2 units wide, so that trace was always a
point trace and the inverted Z survives only as a probe offset. The proposed fix
would not have corrected the aim either. Not applied. (Consequence worth knowing
before anyone touches this area: *every* world trace a cockroach does is a point
trace, `walkmove` included, and `World_CheckBottom` collapses mins to maxs for a
hull-0 entity — so the roach effectively has no bottom check at all.)

---

### 2. `trigger_respawn` discarded the flag that says "don't move living players"

The chain is real and was traced end to end: `trigger_once` (`*235`) → multi_manager
`radio_mngr` → at t+3 s, targetname `churchrespawn`. Two map entities carry that
name; the `trigger_respawn` is **`spawnflags "6"`** = 2|4, and `sven-coop.fgd:6667`
defines those as *"Respawn dead players"* + *"Don't move living players"*.

`trigger_respawn_use` contained **no reference to `self.spawnflags` at all**. Its
`else` branch called `PlayerPlaceAtSpawnPoint()` on every living player
unconditionally. Now gated on bit 4, with the flags cached *before* the loop —
load-bearing, because `self` is reassigned to each player inside it and an in-loop
read would ask the player about its spawnflags.

Gated on **bit 4 only**, not on 2|4. The corpus settles it: flag 4 never appears
alone anywhere, six maps set it on top of 2, and hl_c08_a2 / th_ep3_00 / th_ep3_03
each ship *both* a plain `respawn` and a separate flag-6 `respawn_dead` — which only
makes sense if 2 by itself still relocates the living. th_ep1_00's `they2_forcespawn`
is spawnflags 0, so the post-intro cutscene handoff this function was written for is
untouched.

**Refuted.** The first pass insisted a second fix to `player_respawn_zone` was
*required* — that the zone sharing the targetname also teleports living players.
It does not, on this map: zone selection runs through `Trigger_PlayerInBSPBrush`,
which is a hull-overlap `tracebox` on the player's **origin**, not a feet-height
comparison, and decoding `*554`'s clipnodes puts every relevant point *inside* the
zone. With `zonetype` 0 ("respawn all outside") that means `wants` is FALSE and the
player is skipped entirely. The proposed change would also have broken 45 of the
corpus's 48 respawn zones, which stand alone and are the only thing pulling a living
player forward at a checkpoint. **Not applied.**

Still not implemented, deliberately, and named here rather than implied away: bit 2
clear should mean "do not revive corpses" (20 corpus maps), and bit 1 "Respawn
Target" should restrict the whole thing to one named player (th_escape's three).

---

### 3. The NPC name tag was a dead-man's switch with nothing to feed it

The server half is edge-driven — `sv_lookatnpc.qc:82` sends only when the target or
its health changes, and the file header calls that a feature. The client half stamps
`lookat_npc_last_seen` in exactly one place (`cl_lookatname.qc:115`, on packet
arrival) and clears the tag after `LOOKAT_HOLD_TIME` = **0.9 s**.

Aim at an idle, undamaged monster: one packet on acquire, then silence forever, then
0.9 s later the client gives up — and nothing can revive it, because from the
server's point of view nothing has changed. The 0.9 matches the reported ~1 s. That
hold window was copied from the *player* tag, where it is correct: that one
re-traces client-side at 10 Hz and re-stamps itself on every hit.

Fixed server-side with a 0.4 s heartbeat (`LOOKAT_NPC_REFRESH`), two inside the
client's window so one can be lost. The `!hit` term in the gate is load-bearing —
without it a player looking at a wall emits a 9-byte packet every 0.4 s forever.
Steady-state cost is ~23 B/s per player, and only while aiming at a live monster.

---

### 4. Two different runaway scrapes, and PATCH 163 fixed neither of them

**The physprop scrape** was issued `SOUNDFLAG_FORCELOOP`, which rewinds the channel
forever — so the *only* thing that can ever end it is a cancel message. That makes
every bug in the stop paths an unbounded bug, which is why this keeps recurring.

The stop was never issued because the server still believed the pile was sliding.
`PhysFiles_StartScrape` refreshes the watchdog deadline on **every** call, so the
watchdog structurally cannot fire while anything keeps asking; and a death
force-drops up to twelve weapon entities onto **one origin**
(`W_DropAllWeaponsOnDeath`), interpenetrating. The jitter out of resolving that pile
sits above `sv_physprop_slide_min_speed` (35) indefinitely while travelling nowhere,
and cannot fall below `sv_physprop_sleep_speed` (8) to sleep either — so the one path
that would have stopped the scrape is starved. N concurrent, permanently latched,
entirely "legitimate" loops at ≥0.3 volume each.

- **Progress gate**: measure displacement, not speed. A prop covering < 12 units in
  0.5 s is not sliding whatever its velocity says, and is muted until it demonstrably
  travels again. Self-healing in both directions.
- **`FORCELOOP` dropped**, so the worst case is bounded by one sample length instead
  of by the heat death of the map. Measured every scrape wav on disk: 1.84 s
  shortest, 5.13 s longest. A separate third `else if` re-issues at 1.6 s for a long
  drag — deliberately *not* folded into the existing latch branch, which re-rolls
  `pp_scrape_var` and increments `pp_scrape_live`.
- **One asset defeats the flag change**: `concrete_block_scrape_rough_loop1.wav` is
  the only scrape sample carrying a `cue ` chunk, and FTE reads cue points as loop
  points (`snd_mem.c:1329`), so it self-loops with no flag at all. It is `glass`'s
  borrowed sample too. Bounded by the progress gate rather than by the flag;
  `snd_ignorecueloops 1` is the escape hatch.
- **Volume**: `bound(0.3, speed/400, 1.0)` → `bound(0.10, speed/700, 0.55)`. Twelve
  scrapes at no less than 30% apiece, plus twelve full-volume impact one-shots, is
  what "very loud" was.
- `SOUNDFLAG_FOLLOW` **kept**. It is provably inert for these entities today (props
  are CSQC-networked, so they never enter `cl.lerpents`), deleting it fixes nothing,
  and it is correct the moment a client connects without CSQC up.
- Closed the hide trap PATCH 163 missed, in **two** places (`Pickup_Taken` and its
  sibling branch in `weapon_touch`): both park a possibly-sliding ODE body by
  clearing `.touch` and repointing `.think`, so anything latched on it has nothing
  left to cancel it. Mirrors the `mp_nomapweapons` block at `sv_weapons.qc:536-541`.

**The `func_pushable` scrape is a second, independent runaway**, and is the better
candidate for the sound the report actually heard. `debris/pushbox1-3.wav` are
~1.17-1.20 s and were re-triggered every 0.7 s, so consecutive plays *overlap and
replace each other on the same channel* — seamless and permanent, not repeating. The
SDK's two gates were both missing: HL tests `length > 0 && FL_ONGROUND`
(`func_break.cpp:996`), ours tested a `len` captured *before* `CollideWorld` had
clipped the velocity and nothing about the ground; and HL has an else-branch that
**cuts** the sound, which ours did not. Both restored. The cut is a null sample
rather than `stopsound()` — `sv_physprop.qc`'s sibling documents at length why
`stopsound` never reaches a client (`cl_parse.c:5616` bails on the precache lookup
before it can reach the stop branch) and why empty-string `sound()` never leaves the
server.

**Refuted.** The first pass blamed entity-slot reuse: a `FORCELOOP|FOLLOW` channel
outliving its emitter's edict and re-binding to whatever monster inherited the
entnum. The mechanism is real and the code *is* capable of it, but no reachable
death-drop path lacks a `StopScrape` — sleep, toss-fallback, escaped-world, stuck,
and deferred-pickup all stop first — and the "sound moved with the NPC" observation
has a simpler cause that needs no freed edict: `sv_physprop_scrape_track` (default 1)
re-issues the loop up to ~8x/sec, and `SVQ1_StartSound` takes the origin from the
emitter's live position at issue time. A dropped gun being kicked along the floor by
a walking monster emits a scrape that hops to the monster's feet several times a
second. The irony is that the first pass wanted to delete `FOLLOW` — the flag doing
nothing — to cure a symptom produced by the re-issue it wanted to keep.

---

### 5. Black foliage and a flashlight that skips `.mdl` are two bugs, not one

**The black faces are a multiply by zero, in this mod's own shader.**
`defaultskin.glsl:899` computes
`sunf = mix(r_shadows_sunshade_floor, r_shadows_sunshade_ceil, ...)` and
`cfg/default.cfg` ships **floor 0** / ceil 2. These are `!!cvardf` knobs baked into
the compiled shader as literals (`gl_shader.c:1964`), so the 0 really is a literal
zero. Any vertex facing away from the dominant light gets `col.rgb *= 0` — *after*
the ambient term, which is why `r_prop_minlight` cannot rescue it and why the report
says "it's not related to brightness".

Foliage makes it obvious rather than being a special case: leaf cards are
double-sided with mirrored normals (`tree1.mdl` carries 55 exact antipodal pairs out
of 155), so one side lands at 2x and the other at exactly 0, while a card edge-on to
the light gets ~1.0 on **both** sides — precisely the reported "some faces well lit,
some black silhouettes, and one face correct on both sides". GoldSrc cannot produce
this at all: `studio_render.cpp:405` builds illum *additively* from ambient and only
*subtracts*, so a model is floored at its ambient.

- `cfg/default.cfg`: floor 0 → **0.5**, ceil 2 → **1.5**. Mid-level stays exactly
  1.0 (no net brightness change anywhere), contrast halves, darkest possible face is
  half-lit. Needs `vid_reload`.
- `defaultskin.glsl`: floor clamped at 0.12 so no cvar value can annihilate a
  surface again.

**Checked and ruled out:** `STUDIO_NF_FLATSHADE`. FTE does ignore it (`HLMDLFL_FLAT`
is defined in `model_hl.h:18` and referenced nowhere), but every texture in
`models/hunger/vegitation/*.mdl` is flags `0x0040` (MASKED) or `0x0000` — not one
sets it. Not this bug.

**The flashlight is an engine bug and is now fixed in the engine.** FTE's HL studio
loader *allocates* `snormals_array`/`tnormals_array` and never fills them — the
`R_Generate_Mesh_ST_Vectors` call is commented out at `gl_hlmdl.c:273`, with a
matching `//FIXME: svector, tvector!` at `:1782`. Zero tangents are poison, not
merely wrong: `normalize(vec3(0))` is NaN, `lightvector.xy` become NaN, and
`colorscale = max(1.0 - dot(lightvector,lightvector)/r2, 0.0)` returns **0.0**
because GLSL's `max` is `y<x?x:y` and `NaN<0` is false. Every realtime light
contributes exactly nothing to every GoldSrc model. With `r_shadow_realtime_dlight 1`
and `r_dynamic 0` the rtlight pass is the only dlight route, so the flashlight
vanishes on `.mdl` and works on `.iqm`.

Fixed in **two** places, both worth keeping:

- `gl_hlmdl.c` — one whole-mesh `R_Generate_Mesh_ST_Vectors` after the body loop.
  Deliberately *not* by uncommenting `:273`: `HLMDL_DeDupe` returns absolute indices
  into the whole-model array while each submesh's arrays are offset by
  `vbofirstvert`, so a per-submesh call would index out of bounds. `st_array` is not
  built until `R_HL_BuildFrame`, so it borrows `lmst_array[0]` — the same UVs before
  the atlas scale, and that scale is positive and constant per mesh, so the
  *normalised* tangents come out bit-identical.
- `quakers/glsl/rtlight.glsl` — a degenerate-frame guard that synthesises an
  orthonormal basis around `n`. Exact for what this shader needs without a normalmap:
  `|lightvector|` is still the true distance and `lightvector.z` is still `N·L`. Kept
  as well as the engine fix so a rig that ever ships without tangents degrades to
  flat lighting instead of to black.

---

### 6. Hit splashes with no damage, and a hitbox display

The client and the server decided "did I hit that monster" with two different tests
against two different volumes, and the client's was always the more generous:

| | test | volume |
|---|---|---|
| client | `CSQC_Monster_OverrideTrace` / `cl_monstersolid` proxies | ray-vs-AABB over `GE_ABSMIN`/`GE_ABSMAX` |
| server | `traceline(... MOVE_HITMODEL)` → `HLMDL_Trace` | the model's own **per-bone** hitboxes |

`world.c:1411-1421` *overwrites* the bbox result with the mesh trace, and if
`HLMDL_Trace` returns fraction 1 then `trace.ent` is never set — a clean miss, zero
damage. The AABB is a strict superset of the bones, so every shot clipping a
shoulder-width of empty air drew blood and took no health.

Two further divergences pulled the same way, and one is fixed here:

- **Server hitboxes were frozen at frame 0.** The server poses a model for
  `MOVE_HITMODEL` from `.frame1time` (`pr_cmds.c:634` → `HL_SetupBones`, which
  derives the frame as `frametime * sequence->timing`). Nothing on the server ever
  wrote `.frame1time` for a monster — a grep of the whole server tree finds it only
  on players. Shoot a walking grunt in the arm and the server was checking where
  that arm was at the first frame of the walk cycle. `W_MonstersExpandHitboxes` now
  writes `e.frame1time = time - e.ai_seqstart`, the exact treatment players already
  got with a comment saying why (`sh_player_anims.qc:678-680`). `.ai_seqstart` is
  now also stamped at the two map-supplied `sequence`/`sequencename` overrides and
  in `mon_corpses.qc`, which wrote `.frame` without going through
  `AI_ApplySequence`. `.frame1time` appears nowhere in `sv_ents.c`, so this changes
  nothing about what any client renders.
- **Monsters are still not lag-compensated.** `Lagcomp_RewindAllPlayers` walks
  `player_chain_head` only, so a moving NPC is not in the same place server-side as
  the lerped position the client aimed at. Extending the ring is a separate and much
  larger patch; not attempted.

**The invariant** — *"either it hit or it didn't"* — is now enforced by making the
effect follow the authority. CSQC no longer draws the flesh burst for a
`csqc_monster_proxy` hit in either hitscan path, and `W_ImpactEffectSend` now
includes the shooter when the target is a monster, delivering the authoritative
effect at the hitbox-precise position ~ping later. The tracer still stops at the
body, so the ribbon does not overshoot while the confirmation is in flight.

**Cost, stated plainly:** one ping of latency on NPC hit feedback. That is the trade
the invariant requires; there is no version of "no false blood" that is also 0 ms
without making the client authoritative for monster damage (which would need a
monster hitclaim path, a defer-to-claim guard to stop double damage, and a new cheat
surface).

**Not changed: melee.** `CSQC_PredictedMeleeTraceEx` still predicts its flesh burst
and body sound for a monster hit. The same AABB-vs-bones divergence applies, but the
server melee path's effect delivery was not confirmed to reach the shooter, and
suppressing it without that would remove melee feedback entirely rather than delay
it. Left deliberately; flagged for a follow-up.

**Hitbox display: `r_showhitboxes 1`** (new engine cvar). QC genuinely cannot draw
these — `addmodelhitbox` *refuses* HL `.mdl` (`com_mesh.c:3786`, "HL .mdl has native
hitboxes") and no builtin exposes the model's own table. But
`HLMDL_DrawHitBoxes` already existed and already did exactly the right thing,
building bone matrices from `rent->framestate` — the same data `HLMDL_Trace` poses
from — and its only caller was the model viewer. Wired into the scene-add path in
`gl_alias.c`. Because it draws from the same framestate the trace consumes, the
overlay is self-validating: if the boxes look wrong, the hit detection **is** wrong.

**Model survey, so "the model has no hitboxes" is off the table:** all 1546 IDST
models under the Sven mount were parsed. zombie 20 boxes, hgrunt 17-24, scientist
19, barney 20-21, headcrab 13, houndeye 13-14. Only `uplant2.mdl` and `gun_mag.mdl`
have zero, and both are props.

---

### 7. `func_pushable`: a measurement error, not a tuning problem

**FTE cannot sweep a 42-unit box against a Q1/HL BSP.** `Q1BSP_ChooseHull`
(`q1bsp.c:1554`) quantises anything wider than 32.1 units to **hull 2** — 64×64×64 in
a GoldSrc BSP — and `:1570` anchors it at the requested **min corner** rather than
centring it. `sv_compatiblehulls` defaults to 1, so `World_Move` skips the best-fit
selector and goes straight to that threshold. There is no intermediate hull: the
choices are a point, 32 wide, or 64 wide.

A new spawn-time assertion (`sv_debug_pushable 1`, one line per crate) measures it
directly, printing what `tracebox` says beside what the crate's real AABB says. On
th_ep1_01:

```
jam-check box=-578 42 262..-534 86 292   w=42  hull=SOLID  exact=clear    ← world artefact
jam-check box=310 -235 -90..354 -191 -60 w=42  hull=SOLID  exact=SOLID    ← real overlap
jam-check box=306 -194 -90..350 -150 -60 w=42  hull=SOLID  exact=SOLID    ← real overlap
jam-check box=2646 -308 -400..2698 -256 -332 w=50 hull=clear exact=clear
jam-check box=2706 -286 -400..2758 -234 -348 w=50 hull=clear exact=clear
jam-check box=2490 -522 -397..2542 -470 -345 w=50 hull=clear exact=clear
jam-check box=2425 -673 -398..2487 -611 -346 w=60 hull=clear exact=clear
jam-check box=2314 -622 -398..2366 -570 -346 w=50 hull=SOLID exact=clear  ← world artefact
```

**Three of eight crates read as buried.** Two are pure quantisation artefacts against
walls they are merely standing beside; two genuinely overlap *each other* by a unit
from map load. Anything down that path had its velocity zeroed every frame, and both
recovery arms were unsatisfiable — the back-out gated on `!trace_startsolid` from
the *same start point* that had just been found solid (dead code, always), and the
climb gated on `!trace_allsolid`, which is FALSE whenever a neighbour makes the probe
allsolid (`world.c:2144` ORs it across entities). A crate that could not be pushed at
all, while the pushbox scrape re-triggered for as long as anyone leaned on it.

Four changes:

- **Exact crate-vs-crate.** A swept-AABB (Minkowski-sum slab) test over
  `pushable_rider_list`, all three axes — the Z axis is not optional, because the
  world sweep now masks other crates out and this test is the only thing letting a
  crate rest on another. Already-overlapping pairs are handled by the axis of least
  penetration: motion that **separates** is allowed, motion that **deepens** is
  clipped. Neither jitters a stack nor lets a shove drive one crate through another.
- **World artefact path.** When the fat sweep says startsolid but a *point* trace at
  the centre says otherwise and no crate overlaps, the reading is an artefact: fall
  through to a point-swept move (centre plus four horizontal mid-edges, inset a unit)
  rather than to the recovery. Less conservative than the fat sweep — a corner can
  clip a pillar — but the fat sweep's alternative here is not moving at all.
- **Both recovery arms now test the destination**, with the back-out walking outward
  in 4-unit steps and taking the nearest free spot, and both dirty `SendFlags`.

**The bounce-out is a networking bug, and it is the one with the widest blast
radius.** `if (moving) self.SendFlags = 1;` meant that on the frame a crate
*stopped* — the one frame whose contents the client most needs — `moving` was already
0 and nothing was sent. `SV_ProcessSendFlags` only re-transmits a CSQC entity when QC
dirties the flag (`sv_ents.c:4571`); `setorigin` alone never does, and the entity
carries `PVSF_NOREMOVE`, so there was no corrective path at all. Meanwhile
`cl_brushsync.qc:287` advances the replica by its last known velocity every frame —
and a collision zeroes velocity in **one step**, inside `FuncPushable_Move`, from
`PlayerPreThink`, outside the tick entirely. Worse, `cl_brushsync.qc:694` keeps a
crate with non-zero wire velocity on `moving_brush_list`, so `sh_pmove`'s carry and
geometry-push keep acting on the locally predicted player with a phantom velocity the
server does not have. Now compares against what was last *sent*, which covers every
writer rather than only the ones that remember to dirty the flag;
`func_pushable_blocked` dirties too.

**Pushback and speed.** Three changes, measured:

- The clamp was `if (push && len > push_maxspeed)`, so the **+use pull path had no
  cap at all** and adds up to `sv_maxspeed` per usercmd against a 6/s decay. The
  SDK's clamp is unconditional (`func_break.cpp:978`); ours is now too.
- The shove ran **once per usercmd** at full strength, so `cl_cmdrate` was a strength
  stat and the crate hit its cap in two commands with no ramp. Now scaled by
  `input_timelength * sv_pushable_tick_fudge` (default 15) — GoldSrc's own fix and
  its own default (`func_break.cpp:967`).
- The cap was a flat `400 - friction`, i.e. **370 and 350 on this map against an
  `sv_maxspeed` of 270**. A crate 30-37% faster than a person can walk runs away from
  you the instant you touch it, which is why pushing one felt weightless: the only
  thing braking the pusher is their own collision with the crate, and that only works
  while the crate is the slower body. Now `sv_maxspeed × sv_pushable_speed_frac ×
  ((400 - friction) / 400)`, measured on th_ep1_01 as **212.3** (friction 30) and
  **200.8** (friction 50). Heavier crates stay heavier. `sv_pushable_speed_frac 1.48`
  restores GoldSrc's numbers exactly.

The velocity glue (`func_break.cpp:990`) stays deleted, and the file's existing
warning about it stays correct — an unpredicted per-frame stamp on the authoritative
player velocity is exactly the rubber-band this file is trying not to cause. The cap
buys the same feel with no reconcile error.

**Client-side prediction: partly possible, no engine work needed, not done.** Today
pushables are replicated for rendering *and* for collision (SOLID_BSP in the CSQC
world, `physics_mode 2`, so the shared pmove's traceboxes hit them) but not
simulated — CSQC only linearly extrapolates the last wire velocity for at most 0.1 s.
The engine already runs full shared physics on CSQC entities
(`pr_csqc.c:8898`); what is missing is entirely QC — moving the horizontal half of
the tick into `shared/` and adding each touched crate's origin+velocity to the
reconcile baseline in `cl_player.qc` keyed on the acknowledged command frame. The
`SendFlags` fix above removes the divergence that *reads as* broken prediction, which
is the cheap 90%.

---

### 8. `func_water`: an amber constant and a one-sided box

**The orange is not a contents bug.** All three `func_water` on th_ep1_01 carry
`"skin" "-3"`, the value survives the brushsync wire intact
(`sv_brushsync.qc:387` → `cl_brushsync.qc:566`), and `pm_watertype` really is
`CONTENT_WATER`. `HUD_DrawSubmerged` simply hardcoded Quake's stock amber
`'0.51 0.31 0.20'` (130/80/50) — while `cfg/default.cfg:225` **overrides** the
engine's tint to `v_cshift_water "20 40 60 100"`, a blue. World water is drawn by the
engine from the cvar; `func_water` is drawn by CSQC from a default that no longer
applies. The comment justifying the constant claimed Half-Life inherits Quake's
cshift table verbatim; the HL SDK has no cshift table at all — grep it for `cshift`
or `SetContentsColor` and there is nothing, because in GoldSrc the tint is engine
side. Now parsed from `v_cshift_water` / `_slime` / `_lava` at draw time, scaled by
`v_contentblend`, with the constants as the fallback for a malformed string.

Worth knowing: fixing the colour does **not** make `func_water` look identical to
world water. `r_waterwarp` and `waterfog` are both gated on `RDF_UNDERWATER` /
`r_viewcontents`, which a CSQC-only brush entity can never set — `PM_ExtraBoxContents`
walks `pmove.physents`, which is filled solely from packet entity states. Inside a
`func_water` you get the tint and nothing else.

**Invisible from below** is a one-sided box plus a missing per-surface test. Dumping
the face lump: `*496` has six planes, **each single-sided outward**, no inward
counterpart — while worldspawn's `!nm_water3` has faces on **both** sides of all
three of its planes. `Shader_DefaultBSPWater` never writes a `cull` line, so the
shader inherits `SHADER_CULL_FRONT`, and a brush *entity* gets no per-surface plane
test at all (`Surf_GenBrushBatches` copies `model->batches` wholesale). The GPU is
the only culler, and from inside every face is backfacing.

Fixed in the engine by setting `BEF_FORCETWOSIDED` per entity in
`Surf_GenBrushBatches` when `ent->skinnum < 0` — the engine's own existing marker for
"this brush model is a contents volume" (`cl_ents.c` uses exactly that test to build
a forced-contents physent, and CSQC passes `.skin` through to `skinnum` at
`pr_csqc.c:920`). That reaches `func_water`/`_slime`/`_lava` and nothing else.

**Refuted.** The obvious fix — `cull none` in `Shader_DefaultBSPWater` — would be a
regression on this very map. `r_surf.c:3069-3074` auto-enables the temporal scene
cache when the world has >6000 leafs and `r_waterstyle <= 1`; th_ep1_01 has 7328
leafs and `default.cfg` sets `r_waterstyle 1`, so the live path is
`Surf_SimpleWorld_Q1BSP`, which walks marksurfaces with **no backface test**. GL
culling is the only thing stopping the world's doubled water quads from both
rasterizing at `r_wateralpha 0.5`. **Not applied.**

Expectation-setting: real GoldSrc also backface-culls `func_water` from below, so
this makes the mod better than Half-Life rather than more faithful to it.

---

### Build and verification

All three VMs compile with **0 warnings**; `quakers_csprogs.pk3` repacked. Engine
rebuilt 64-bit (`make m-rel FTE_TARGET=win64` — note `gl-rel` fails at link on this
toolchain with an unrecognised `--large-address-aware`, which is pre-existing) and
deployed to `C:\FTEQuake` and `Desktop\Quakers`, with the previous binary kept as
`fteqw64.prepatch165.exe`.

Headless th_ep1_01: no QC faults of any kind across five runs. Nav graph unchanged
from PATCH 164 (`components=41 largest=710 (56.44%) isolated=19`), so none of the AI
changes disturbed it. Pushable caps measured at 212.3 / 200.8 u/s. The jam-check
table above is the new permanent diagnostic.

### Owed in-game

The harness has no renderer, no audio and no player pushing anything, so the
following are the parts only you can confirm:

1. **The roach.** Does it glide now instead of flashing, does squashing one leave a
   mark, and does it stop panicking about a player across the room. Also whether
   `sv_ai_arcturns 1` reads as "turning while walking" or as monsters cutting wide
   through doorways — if the latter, `sv_ai_arcturns 0`.
2. **The scrape.** Die on a pile of weapons and confirm silence within a few seconds
   rather than forever. `sv_debug_physprops 1` prints `scrape muted (no progress)`
   when the progress gate fires.
3. **The foliage and the flashlight.** Needs `vid_reload` after the cfg change. The
   single decisive test for the black faces is `r_shadows_sunshade 0; vid_reload` —
   if they come back to normal brightness, the diagnosis is confirmed outright.
4. **`r_showhitboxes 1`** on a walking grunt — this is also the fastest way to see
   whether the `frame1time` fix actually posed the boxes onto the animation.
5. **The crates.** Push one into another and confirm it stops rather than sliding in
   and bouncing out; confirm the two jammed crates on th_ep1_01 (`hull=SOLID`) can
   now be pushed at all. `sv_debug_pushable 2` prints `hull artefact ... point-swept`
   when the artefact path is taken.
6. **`func_water`** — blue instead of orange, and a visible surface from underneath.

---

## PATCH 164 — the nav graph promised a 22-unit leg and walkmove only has 18

**Report:** *"NPCs thinking they can walk over objects, because the nav mesh will
place the next stop on top of the object... it's messing up NPC animations, not
being able to walk towards the correct locations."*

Correct on both counts, and the two halves are separate defects that happen to
compound. Nothing here is a tuning change; four gates were each wrong on their own
terms.

### 1. The builder's step height was never a number the engine agreed to

`NAV_STEP_HEIGHT` was **22**. `walkmove` steps by `movevars.stepheight`
(`server/sv_move.c:215`), which is `PM_DEFAULTSTEPHEIGHT` = **18**
(`common/bothdefs.h:1163`) unless `pm_stepheight` is set — and the runtime AI has
always known that, `AI_REACH_STEP` is 18 at `sv_ai_move.qc:57`. So every gate keyed
off the constant approved climbs the engine then refused. Now 18.

The same lie was baked into the sweep box. `NAV_SWEEP_MINS_z` was `-10` against a
node floating `NAV_NODE_HEIGHT` = 32 up, putting the bottom face at floor+22: the
one test most links ever get was **deliberately blind to 22 units of obstruction**.
That blind zone is the step allowance and therefore has to be it — `-14`.

### 2. Nodes were being planted on crate lids

`Nav_FloorDrop` traces down with `MOVE_NOMONSTERS, world`, so it stops on any solid
entity. `func_pushable` is `SOLID_BSP` (`sv_func_pushable.qc:1010`) — every crate on
the map got a node on its lid. Worse, a pushable is `brush_type` **TRAIN**
(`sv_func_pushable.qc:930`), so `Nav_EntBlocks` calls it a mover and the link sweep
walks *straight through it* to reach that node. The graph asserted a route over the
top of a box, and the player can shove the box out from under the node afterwards.

`Nav_EntBlocks` already asks exactly the right question, so the drop now consults
it: world and static brushes keep their nodes, doors/trains/pushables/vehicles and
every non-`SOLID_BSP` prop lose them. (`Nav_FloorDrop` moved below `Nav_EntBlocks`
for this — the file carries no forward references.)

### 3. Nothing anywhere could tell a ramp from a wall

This is the actual fix. `Nav_FloorProfile` samples ground every 48 units, and at
that spacing a 40-unit crate and a gentle ramp are the same reading: *"the floor is
40 higher than it was 48 units ago."* Its tolerance was ±70 **in both directions**,
so anything up to 70 units tall passed. The flood builder was no better — a flat
`dz > NAV_STEP_HEIGHT * 2` (44).

The discriminator is **resolution**: a ramp spreads its climb evenly and rises by
about the sample interval at *any* interval; a face puts its whole height between
two adjacent probes however finely you subdivide. New `Nav_ClimbRefine` re-walks
only the suspicious segment at leg scale (8 units) and demands that no sub-step
exceed the step height, and that every surface landed on is standable
(`normal_z >= 0.7`, the same threshold `Nav_FloorDrop` uses). Wired into the coarse
profile, into the flood, and — the one that mattered most — into the profile's
`dist <= NAV_PROFILE_STEP` early-out, which used to return TRUE before either
question was asked. A node on a crate lid is *very often* within one sample spacing
of the floor node beside it, so the gate's own front door was the biggest hole in it.

Cost is paid only where a rise exists. Flat ground and downhill never touch it.

### 4. The free height gate carried nonsense slack

`dz > run + NAV_STEP_HEIGHT` let a node a step-height above one directly overhead
count as reachable. Climbing faster than 45° averaged over a whole link is not a
walk under any arrangement of ground in between. Now `dz > NAV_STEP_HEIGHT && dz >
run`, which still allows a pure kerb.

### Measured — `svonly.sh <map> 40 <tag> +set sv_nav_linkdebug 1`

th_ep1_01, before → after:

| | before | after |
|---|---|---|
| nodes | 1294 | 1262 |
| links | 12948 | 12482 (**−466**) |
| components | 42 | 41 |
| largest component | 716 (55.3%) | 714 (**56.6%**) |
| isolated | 20 | 19 |
| build time | 17.48 s | 17.42 s |

Connectivity went **up** while 466 lying links were removed, and the refinement
costs nothing measurable. hl_c01_a1 pays about a point: 34.86% → 33.88%, components
6 → 7, nodes 588 → 549, links 6458 → 6004. That loss is the intended effect —
39 of those nodes were crate lids and prop tops — and `sv_nav_selftest 1` on it
reports `BAD=0`, `one-way=0`, grid-vs-linear `agree`.

New counters, both on by default via `dprint`:

```
[nav] flood reject: step=34 (rise is a face)  mover-lid=24 (crate/door/train top)
[navlink] of nofloor, refused as un-climbable step: 44
```

### Note

`sv_nav_linkfloor` now carries the step gate as well as the ground check, so its
comment in `sh_cvar_table.qc` says not to ship it off. Nothing in `quakers/` sets it;
the default of 1 applies.

**Not addressed, and not a bug:** a prop shoved into a doorway *after* the build
still blocks a link the (now immutable) graph asserts. That case is already handled
at runtime — the projected-progress check in `sv_ai_move.qc:1013-1026` reaches
`AIMOVE_BLOCKED` and re-paths, backing out of the aperture first. What this patch
removes is the *systematic* version, where the graph itself was the thing lying.

**Owed in-game:** watch a grunt approach a stack of crates and confirm it now walks
around rather than grinding its walk cycle into the face. The graph numbers above
prove the links are gone; they cannot prove the animation looks right.

---

## PATCH 163 — a PHS-filtered stop, 27 unbracketed traces, and a name tag that never saw a monster

Four reported items. Three were single mechanisms with wide blast radii; the fourth is a
new feature. One engine change.

### 1. The scrape loop that never stops — `SOUNDFLAG_RELIABLE`

**Root cause, proven from engine source, and it is not a lifecycle bug at all.**
`PhysFiles_StartScrape` issues the loop with `SOUNDFLAG_FORCELOOP|SOUNDFLAG_FOLLOW` and
`PhysFiles_StopScrape` cancelled it by playing `sounds/null.wav` on the same channel —
with no flags. `SV_StartSound` picks its multicast scope from exactly that:

```
sv_send.c:1319  if (reliable || !sv_phs.value || !attenuation) use_phs = false;
sv_send.c:1352  SV_MulticastCB(origin, reliable ? MULTICAST_PHS_R : MULTICAST_PHS, ...)
sv_send.c:1354  SV_MulticastCB(origin, reliable ? MULTICAST_ALL_R : MULTICAST_ALL, ...)
sv_send.c:936   case MULTICAST_ALL_R: ... mask = NULL;      // every client, no PHS test
```

So the **stop was filtered by the PHS of the prop's position, exactly like the start.**
Drop a gun, walk away while it is still sliding, and it comes to rest outside your PHS:
the server issues the stop, the PHS test drops it before it reaches you, and
`snd_mix.c` rewinds a `CF_FORCELOOP` channel forever. The server believes it stopped the
sound. No removal, no dead think, no lost latch — just distance. Fixed by flagging the
stop `SOUNDFLAG_RELIABLE`, which is documented as "without regard to phs" and is.

**FTE's own author documented this failure and applied this fix — to a different class of
entity.** `sv_send.c:1373`, verbatim: *"these sounds are often looped, and if the start is
in the phs and the end isn't/gets dropped, then you end up with an annoying infinitely
looping sample"*, followed at :1377 by `chflags |= CF_SV_RELIABLE;`. It sits inside
`if (solid == SOLID_BSP || solid == SOLID_BSPTRIGGER)` at :1364, so a dropped weapon
(`SOLID_PHYSICS_BOX`) never qualifies. The flag costs no wire bits: only `CF_NETWORKED`
bits reach the packet (`sv_send.c:1172`) and this is not one (`sound.h:130`).

Reachability is conditional and worth knowing: the PHS has to exist. `sv_init.c:481`
skips building it when `sv_calcphs` is 0, when it would exceed 1 MB, or when deathmatch
*and* coop are both 0 — and with no PHS, `case MULTICAST_PHS:` broadcasts anyway
(`sv_send.c:944-945`). The mod forces `deathmatch 1` from the menu, so on an ordinary map
the PHS is built and the bug is live; on a map big enough to blow the 1 MB cap it never was.

Correction to a comment this tree carried: `stopsound()` is **not** "client-only". SSQC has
it (`pr_cmds.c:11512`, `:11522`) and it ends in `SVQ1_StartSound(..., NULL, ..., CF_SV_RELIABLE)`.
It is inert because of the *client*: the extended parser bails on the precache lookup before
reaching the stop branch — `cl_parse.c:5616 if (!cl.sound_name[sound_num]) return;` runs ahead
of `:5623 if (!sound_num) S_StopSound(...)`, and `sound_name` is filled from index 1, so a stop
(index 0) is always dropped. `null.wav` remains correct, for that reason rather than the
recorded one.

Belt and braces on top, because the reliable stop still has to be *issued*:
- **`SUB_KillTargets` (sv_triggers.qc)** — bare `remove()` on every killtargeted entity.
  This is the one leak the watchdog structurally cannot reach: `PF_nextent` skips freed
  edicts (`pr_bgcmd.c:4179-4181`), and `ED_Alloc` re-issues the slot after 0.5 s
  (`qclib/pr_edict.c:120,:134`) to something that will never emit on channel 6. It now
  calls `PhysProp_TeardownForRemove` (which also releases a carrier still holding it —
  the hazard that function exists for) and detaches the ODE body.
- **`W_RespawnMapWeapons` revive branch** — the strip branch got a `StopScrape`; its
  sibling did not, so a map weapon mid-slide at round end kept its loop through the
  respawn, re-anchored at its original spawn point.
- `W_PhysDropFallbackToToss` (repoints `.think`, so the FX cut never runs again),
  `W_PhysDropSleep`, and the three `remove(self)` sites in `W_PhysDropThink`.
- **`PhysFiles_ScrapeWatchdog`** (`sv_main.qc` StartFrame, 1 Hz, skipped entirely while
  `pp_scrape_live` is 0): force-stops any latch whose `pp_scrape_deadline` has expired.
  The deadline is refreshed by *every* `StartScrape` call, so a legitimately long drag
  never trips it and a prop whose think died is cut 2 s later.

Latent, documented not fixed: `SOUNDFLAG_RELIABLE` clears the PHS test but **not** the
dimension test (`sv_send.c:751, :1017`, which sits *before* the `if (!mask) break;`
broadcast shortcut at :759). Benign only because players get `dimension_see 255` and
nothing writes `.dimension_seen` on a prop — note that is a different field from the
`.dimension_solid`/`.dimension_hit` this mod writes constantly.

### 2. NPC hitboxes — the audit, and what it found

Measured every Half-Life monster model's per-sequence bboxes straight out of the studio
headers (49 models; `mstudioseqdesc_t.bbmin` is at offset **96**, not 100 — `/c/tmp/mdl.py`
is off by one int on that field and every bbox ever read with it is wrong).

**Answering the two questions directly:**

- *Are they using the correct hitboxes for the models?* Yes, and they always were. 291 of
  296 HL character models ship per-bone hitboxes (the 5 that do not are effect props), and
  FTE traces them natively (`gl_hlmdl.c:1567-1710`, setting `trace_bone_id` and the
  hitgroup). `addmodelhitbox` is player-only and could not apply — `com_mesh.c:3786`
  refuses HL `.mdl` because it already has native boxes.
- *Is everything the player can hit inside the bbox?* **No, and this was the whole bug.**
  `World_ClipToLinks` rejects an entity on absmin/absmax *before* the per-bone test runs,
  and not one HL monster model fits the 32×32×72 human hull: a zombie's attack reaches
  x=+101 and z=+94, barney's reload x=−90, houndeye's leap z=+108 against a 36-tall hull.

Three separate defects, all now fixed:

- **27 trace sites ran unbracketed.** `sv_monsters.qc` asserted the expand/restore pair was
  "already bracketed correctly around every weapon trace in the mod". It was bracketed
  around three (`W_StandardHitscanShoot`, `W_PenetratingHitscanShoot`, paintball). Every
  melee weapon reaches the world through `W_MeleeTrace`, and the shotguns, gauss, egon,
  crossbow, tesla, rebar, wrench and medkit call `W_WeaponTraceLine` directly — 27 sites,
  every one tracing against the raw movement hull. A gargantua drawn 214 units tall was
  shootable to z=214 with a rifle and to z=64 with a shotgun. Bracketed at the two funnels
  rather than the 27 leaves (the original comment was right that 27 hand-written pairs is
  how one ends up unpaired) and the pair is now nest-safe via `mon_cull_depth`.
- **Monsters got no limb padding.** `sv_hitbox_expand` (default 32) has padded every
  *player* box around every weapon trace all along; monsters got zero. They now get the
  same. It cannot invent a hit — every trace in the bracket is `MOVE_HITMODEL` and the
  per-bone test still decides.
- **The two worst cull boxes did not exist, and adding them alone would have been dead
  code.** `monster_tentacle` and `monster_nihilanth` build themselves outside
  `Monster_Build`, so they are not on `monster_chain` and the inflation walk cannot see
  them. They get a side-list (`Monster_SOCBRegister`) that nothing else walks — putting
  them on `monster_chain` would expose them to ~25 AI functions that have never seen a
  tentacle. Their HL boxes are `tentacle.cpp:54` (±400 × 850) and `nihilanth.cpp:44`
  (±240 × −720..420) against a 64-unit hull: **786 of the tentacle's 850 units were not
  there to a bullet.** Also added: `monster_osprey` (1235 units wingtip-to-wingtip on a
  32-wide hull), `monster_ichthyosaur`, `monster_barnacle`, and `monster_th_boss` — an
  apache alias that got nothing because the table dispatches on classname.
- Their modelindexes were also never published to CSQC (`AI_PublishMonsterModels` walks
  the same chain), so the *shooter's own* bullets passed visually through them. Fixed.

Per-trace cost is bounded by `Monster_CullSegment`: callers publish the trace segment plus
its swept hull and the walk skips any monster whose inflated box cannot meet it. Without
it a shotgun blast on pizza_ya_san1 would be 8 × 419 × 2 `SV_LinkEdict`s.

**Still open, and it is a judgement call rather than a defect:** the four HL-sourced render
boxes are undersized against measurement (garg misses +X by 265, gonarch by 102, agrunt by
76, apache by 74). Those are Valve's own numbers and HL has the same gap. Left alone.

### 3. Look-at name tag, now for NPCs — `CSQC_EVENT_LOOKAT_NPC` (64)

The key is Sven's `displayname` ("In-game Name", `sven-coop.fgd:591` on the `Monster`
base class) — **not** `netname`, which on a monster is the *squad* name. The mod already
declared the field and parsed it; what was missing was a display helper with a sane
fallback and any way to get it to the client.

Server traces (10 Hz, 2048 units, change-gated), unicasts entnum + hp + max_hp, and the
name string only on the frame the target changes. **CSQC could have identified the monster
itself** — `getentity` plus the modelindex whitelist is exactly what `cl_monstertrace.qc`
does — but no `GE_*` property carries health (the engine's enum has 37 members and none is
one, `pr_common.h:1020-1060`), so the health has to be unicast regardless and a server
trace avoids the round trip. Client owns all drawing, the hold window, and a free
liveness re-check off the inverted `GE_ABSMIN`/`GE_ABSMAX` box that drops the tag the
instant the monster becomes a corpse. A player in the crosshair always wins.

`sv_lookatnpc_test 1` spawns a zombie exactly where each connected player is aiming —
without it the feature is unreachable from the harness, because a headless player faces
wherever `info_player_start` points and never moves. **Two full 175-second runs on
monster-dense maps produced not one `[lookat]` line**, which from a log is
indistinguishable from the code being broken. The flag latches until there is a real
client to aim for rather than clearing on first read.

### 4. `func_wall` rendermode 4 drawing as a solid block — engine, `client/image.c`

Excluded by direct evidence: the `{` → `defaultwall#MASK=0.666#MASKLT` assignment is
**not** path-dependent (`Mod_FinishTexture` registers from `tx->name` before any pixel data
exists and the external-WAD case returns *after* that); the WAD decode is correct (both
copies of `halflife.wad` have `{invisible` at 16×16 with all 256 texels index 255 and
pal[255] = 0,0,255, which `wad.c:459-461` turns into RGBA(0,0,0,0)); and the mod's CSQC is
right for rendermode 4 (alpha 1, colormod 1 1 1, no RF_ flags — and CSQC has *no* lever
over a brush model's alpha test in any case: `r_surf.c` reads none of `skinnum`,
`forcedshader`, `customskin`).

What is left is the **failure behaviour**, which is wrong regardless of whether it is this
map's proximate cause: a `{` texture that does not resolve binds `missing_texture`
(`gl_backend.c:1370-1375`), which is created `IF_NOALPHA` (`r_2d.c:290`), which rewrites
RGBA8→RGBX8 (`image.c:13408-13413`), so the sampler returns alpha 1.0 and the shader's
`discard` can never fire. A texture whose entire job is to be invisible renders as an
opaque block, silently and permanently. `Image_LoadHiResTextureWorker` now fails a `{`
image into a 1×1 transparent texel instead — which is what GoldSrc draws — and names any
unresolved texture under `developer`. **Deliberately at the failure tail, not as
`fallbackdata`:** the WAD probe runs only under `if (!tex->fallbackdata)`, so seeding a
fallback up front would stop the real lump from ever being found and turn every fence,
grate, ladder and vine in the corpus invisible.

**Not confirmed as the cause of the reported symptom.** `missing_texture` is a black/salmon
checkerboard (`renderer.c:725-728` fills it with palette indices 0 and 0xff), not "bright
white". Settle it in one map load: `imagelist {invisible` — a `FAILED` status confirms it —
and `r_showshader` on the surface, which must read
`{ fte_program defaultwall#MASK=0.666#MASKLT }`. If both are clean the fault is a sampler
binding and needs a frame capture, not more source reading. `r_hidetextures "{invisible"`
is a working per-map-cfg stopgap either way (`gl_model.c:1610`, archived, `surfaceparm
nodraw`, no image uploaded at all).

---

## PATCH 162 — the second half of the They Hunger report: a hull, a pose, a re-roll and a screen

Six reported defects, and every one of them turned out to be a **wrong constant or a missing
half-line**, not a missing system. Two more were diagnosed to the exact source line and are
deliberately **not** fixed here, because both are engine-side and neither can be seen from a
headless run.

### `item_generic` hung in the air because it dropped on the wrong hull

`models/skeleton.mdl` posed `s_sitting` floated where the mapper typed it. `droptofloor()` was
already being called; it was being called with the **studio model's own bbox**, which for a body
sprawled across most of a 64qu tile starts solid against the wall it was authored beside. The trace
returns 0, the drop is refused, and the prop keeps its raw Z.

`CItem::Spawn` (`halflife/dlls/items.cpp`) does not do that:

```cpp
UTIL_SetSize(pev, Vector(-16, -16, 0), Vector(16, 16, 16));
if (DROP_TO_FLOOR(ENT(pev)) == 0) ...
```

A **fixed 32x32x16 box**, set immediately before the drop, for every CItem-derived entity in the
game — `item_generic` included, via `ItemWithDefaultModel -> Pickup -> CItem`. So the drop now runs
on HL's hull and the display hull is restored afterwards (it is what feeds PVS culling here, and
clamping a 256qu tree to a 16qu box would pop it out of view at close range).

The degenerate-bbox skip went with it, and that mattered more than it looked: `w_satchel.mdl`,
`{invisible` and several vegetation models ship `bbmin == bbmax == 0,0,0` in the studio header, so
`maxs != mins` was refusing to drop them at all.

### The satchel was standing on end because nobody set its sequence

`w_satchel.mdl` has exactly two sequences: `0 idle` and **`1 onback`**. `CSatchelCharge::Spawn`
ends with `pev->sequence = 1` (satchel.cpp:88). `.frame` was never assigned, so every thrown charge
sat upright on the floor like a little tombstone. One line.

The slide is the same shape of bug. `SatchelSlide` gates its 0.95/0.9 damping behind an explicit
downward trace, comment and all:

```cpp
// HACKHACK - On ground isn't always set, so look for ground underneath
UTIL_TraceLine(pev->origin, pev->origin - Vector(0,0,10), ignore_monsters, edict(), &tr);
if (tr.flFraction < 1.0) { pev->velocity *= 0.95; pev->avelocity *= 0.9; }
```

Applying it on **every** contact — which is what this did — charges the static-friction tax to wall
grazes on the way out, so a charge lobbed down a corridor lands at your feet instead of skittering
away down it. `MOVE_NOMONSTERS` is `ignore_monsters`: a charge bouncing off a player must not count
as having found ground.

### The zombie froze mid-swing, and the reason is in this file's own header

Reported as three things — "I hear a zombie attacking but the attack animation is not being played",
"it did one swing animation, then reverted to nothing, but swing noises", "their swing misses and
they just hit each other". They are three separate bugs.

**The freeze.** `sv_ai_anim.qc`'s header already documents the mechanism: assigning the same
sequence index again does not restart playback, because the client only re-stamps its playback clock
when `.frame` *changes* (`cl_ents.c:4465`, `if (force || frame != le->newframe[fst])`). zombie.mdl
tags **two** sequences `ACT_MELEE_ATTACK1` — `attack1` at weight 5 and `attack2` at weight 1 — so
two consecutive swings both land on `attack1` about **69%** of the time. The server was fine
throughout: `ai_seqstart`/`ai_seqend` kept running, the event pump kept raising codes 1/2/3, the claw
kept dealing damage and playing `claw_strike`. Only the client had nothing to re-stamp.

There *was* an anti-repeat re-roll for this. It was unreachable:

```qc
if (seq == m.ai_seq && m.ai_activity != act)      // ai_seq is -1 here, always
```

Every attack task calls `AI_ResetActivity` immediately before `AI_SetActivity`, and
`AI_ResetActivity` sets `ai_seq = -1`. The test now compares against `m.frame` — the field the
client actually diffs, and the one `AI_ResetActivity` does not clear — and retries up to 16 times,
because `frameforaction` re-rolls a *weighted* random per call and a single flip only escapes a 5:1
weighting one time in six. Looping activities stay exempt: HL is explicit about not resetting frame
across the walk/run pair (`monsters.cpp:1225`).

Two counters, `[ai] seq replay: restart=N stuck=N`. `stuck` climbing means a model offers no second
variant for a one-shot being replayed back-to-back, which is a fact about the rig, not a fault here.

**The vertical miss.** The range test that *selects* the attack is a 3D distance, but
`AI_MeleeHull`'s GROUND branch was a strictly horizontal sweep pinned to the monster's eye plane and
spanning ±16 from it. A player one step up at 60 units is comfortably "in melee range" and utterly
unreachable. Half-Life gets away with a flat sweep because `UTIL_MakeAimVectors` (util.cpp:157) feeds
`pev->angles.x` into the forward vector; nothing in this tree sets pitch on a ground monster, so the
equivalent has to come from the target. The sweep now tilts toward the enemy, but **only** when the
enemy's centre is outside the hull's own vertical band — on flat ground the test never fires and the
sweep is byte-for-byte the one the zombie, grunt, islave and gargantua were verified against. The
hull's Z half-height also went 16 -> 18, which is HL's `head_hull`.

**Hitting each other.** `tracebox` stops at the first solid thing, and in a doorway that is another
zombie. The sweep now skips up to two entities the attacker does not `AI_Hates`, by clearing their
`.solid` and re-tracing from the same start — `World_ClipToLinks` reads `.solid` live, so it is exact
and costs no relink. Advancing the start point past the blocker instead needs its depth along the
sweep axis, which a trace does not report. The current enemy is never skipped.

### Corpses took damage in silence

Melee on a body already worked — `W_CorpseMaskBegin` opts the trace in, `W_DeadTakeDamage` chips the
gib pool, `W_MeleeHitIsBody` plays `cbar_hitbod`. There was no **blood**, and nothing in the tree
produced any: the crowbar's `W_ImpactEffect` is in its `else`, and the hitscan paths reach
`W_ClassifyImpactMaterial` only after `W_ApplyDamage`, which short-circuits to the corpse path first.

`CBaseMonster::TraceAttack` (combat.cpp:1113) sprays on **any** target whose `pev->takedamage` is
set, live or dead, and only then hands off to `DeadTakeDamage` — which is the same fact the return-
value comment in `W_DeadTakeDamage` was already describing from the other side. env_blood's existing
wire carries origin, direction, amount, colour and a decal flag, so no new event was needed.

### `func_water` swam correctly and never changed the screen

Not a half-implemented entity: the swim, the drowning and the movement are all right
(`PM_CategorizePosition` reads `PM_ContentsAt`, which sees brush entities, and writes
`self.waterlevel` for the drown timer). What is missing is structural. `r_viewcontents` is built from
exactly two sources (`client/r_surf.c:2255-2300`) — the **world model**, and `PM_ExtraBoxContents`,
which walks `pmove.physents`. On the client that array is filled **only from network packet entity
states**: `CL_SetSolidEntities` reads `state->skinnum` and turns `Q1CONTENTS_WATER` into a
`forcecontentsmask` (`cl_ents.c:7111-7135`). This mod replicates `func_water` over the CSQC brushsync
channel, so its brush is never in a packet entity state, never lands in `pmove.physents`, and the
engine has no way to know the camera is submerged no matter what the brush's `.skin` says.

So CSQC draws the tint, gated on `pointcontents()` at the eye — worldmodel-only in this VM, which is
the whole reason `PM_ContentsAt` exists — so world water keeps the engine's own tint and warp
untouched and the two never composite. The **warp** is not reproduced: it is a post-process gated on
the same `r_viewcontents` with no CSQC property, and forcing `r_waterwarp` from here would leave the
whole map warped the moment you climbed out.

### Carried items sat on top of the health number, and never appeared on the carrier

Two unrelated halves of one report.

The HUD list started at `g_height - 60`, straight through the health number (`g_height-52`) and the
money line (`g_height-74`). Raised to clear the whole bottom-left cluster, and tinted the cold blue
Sven uses.

The above-head carry was already written and gated on a key no map sets — because the gate read the
FGD default the wrong way round. `sven-coop.fgd:3469` lists `carried_hidden(choices) : 1`, but the
number after the colon is what **Hammer offers**, and Hammer does not write a key the mapper never
touched. Sven's own member is left zero-initialised, which is NO. th_escape settles it from the map
side: all four of its `item_inventory` entities carry no `carried_hidden` key at all, yet every one
ships an authored carried pose (`carried_sequencename "carried"`) beside an idle pose
(`sequencename "not_carried"`), and the car battery's description is *"A very heavy battery, carried
with both hands."* Nobody models, names and selects a carried pose for something the game will never
draw. Explicit `carried_hidden 1` still hides.

### Diagnosed, not fixed: two engine-side rendering defects

Both are pinned to a line. Neither is touched here, because both change global rendering and a
headless run cannot see either.

**Studio-model transparency drawing as pitch-black silhouettes** (`tree1.mdl` and every other
`{`-textured vegetation model). The mask is fine — the shape is right, so alpha-test is working. The
*lighting* is what goes to zero. `shaders/glsl/defaultskin.glsl`:

```glsl
light.rgba = vec4(e_light_ambient, 1.0);
float d = dot(n, e_light_dir);
if (d < 0.0) d *= 13.0/44.0;   // "a wtfery factor to approximate glquake's anorm_dots.h"
light.rgb += d * e_light_mul;
```

The floor for a back-facing normal is therefore `e_light_ambient - 0.295 * e_light_mul`, which goes
**negative** — black — whenever the directional term outweighs the flat one. Half-Life cannot do
that. `CStudioModelRenderer::StudioLighting` uses modified hemispherical lighting with
`m_fLambert = 1.5`:

```cpp
illum = ambientlight + shadelight;
lightcos = (lightcos + (r - 1.0)) / r;          // r = 1.5
if (lightcos > 0.0) illum -= shadelight * lightcos;
```

A face pointing at the light gets `ambient + shade`; a face pointing away gets **`ambient`**. The
back-face floor is the ambient term, never zero — which is precisely the property the two-sided leaf
cards on a tree model depend on.

There is already a partial mitigation in this engine tree, off by default:
`r_prop_minlight` (`client/renderer.c:182`, `gl_alias.c:1592`) floors both terms for world-placed
non-player models. It fixes the dark-area case; it does not fix a strongly-lit one, because the
directional term can still outrun the floor.

**`func_wall` rendermode 4 rendering bright white.** The brush is th_ep1_01 model `*130`, and its
six faces are `{invisible` x5 and `{nm_they6` x1. `{invisible` lives in `halflife.wad`, is 16x16,
and **all 256 of its texels are palette index 255** (which is `(0,0,255)`). Under rendermode 4 that
is a brush GoldSrc draws as literally nothing — the texture exists only to be invisible. FTE's own
`W_ConvertWAD3Texture` decodes index 255 to RGBA `(0,0,0,0)` for a non-decal `{` lump and the `{`
shader is `defaultwall#MASK=0.666#MASKLT`, so the correct result should already fall out. It does
not, so the failure is upstream of the decode (the external-WAD miptex resolve) and needs a running
client with a real rasteriser to pin down. The texture identification stands on its own and is the
half that was actually unknown.

---

## PATCH 161 — the escape truck, the two ambush triggers, and the script that starts the clock

The four gaps PATCH 160 found on the way and did not fix. With the fetch quest
working, th_escape still had no way to start the truck, no way to drive it, no
ambushes and no timer — the map ended when you finished the repairs and then
nothing happened, forever.

All four are **map-local AngelScript**, shipped beside the .bsp and registered by the
map's own `MapInit`. None of the four classes appears anywhere in `sven-coop.fgd`;
`trigger_look` in particular is easy to mistake for the stock point-class
`trigger_lookat`, which is an unrelated entity. The `.as` files are the entire
specification and each was read line by line:

| file | lines | what it is |
|---|---|---|
| `scripts/maps/th_escape/func_trackvehicle.as` | 1116 | the drivable truck + its control zone |
| `scripts/maps/th_escape/trigger_playercheck.as` | 281 | "nobody is in this room" |
| `scripts/maps/th_escape/trigger_look.as` | 183 | "nobody is looking at this spot" |
| `scripts/maps/th_escape/th_escape.as` | 620 | the 17 `trigger_script` entry points |
| `+ PlayerCharacters.as / CustomHUD.as / RandNumMath.as` | 750 | the roster, the HUD, the RNG |

### func_trackvehicle is func_tracktrain with a car's pedal

Not a second mover. The class is a copy of `CFuncTrackTrain` with three changes: a
continuous accelerator instead of nine quarter-step notches, an accelerator that
**decays** when you release it, and an ignition state machine so the truck is
undriveable until the map script says the engine is repaired and running. So the
port reuses `sv_func_tracktrain.qc`'s path walk, heading maths, crush handler and
dead-end fire wholesale, with one shared branch (`.tt_is_vehicle`).

`+use` in the cab, hold `+forward` to accelerate and `+back` to brake and reverse;
let go and it coasts down. **Strafing at the wheel is a no-op, not a dismount** —
Sven's PreThink forwards `IN_MOVELEFT`/`IN_MOVERIGHT` to the throttle as delta 20 and
30 and the throttle's `if (delta < 10)` gate discards both, so evicting the driver
there would make the truck impossible to hold on to.

The acceleration ladder — fifteen speed brackets, each with its own constant — is
transcribed verbatim, **including the brake table's `flSpeedRatio -= - 0.0175`**,
which adds where every other rung subtracts. That double negative is plainly a slip,
but it is the shipped behaviour: it makes reverse self-limit at about -0.22 of
maximum (an oscillation between two rungs) instead of running to the -0.35 clamp
below it. Repairing it would make th_escape's truck reverse 60 % faster than it does
in Sven, which is a divergence, not a fix.

**The one constant that was changed, deliberately.** The source bleeds a flat 20
units off the speed each time `Next()` runs past its gate, then re-arms the gate
`time + 0.1`. That reads like a 10 Hz decay, but Sven's `Next()` reschedules 0.5 s
out, so the gate never binds and the *observed* rate is 20 units per 0.5 s — a flat
40 units/sec². This tree's tracktrain re-aims at 64 Hz on purpose (the rider carry
needs one exact tick of velocity at a time), so porting the `+0.1` verbatim would
decay five times harder than Sven and stop the truck dead the moment you lifted off.
The **rate** is ported instead of the step: 40 units/sec, applied per tick. Same
curve, independent of the tick rate.

### A real bug found underneath: func_traincontrols has been putting its box in the wrong place

`CFuncTrackTrain::SetControls` (`plats.cpp:1344-1350`) measures the control brush
against `pev->oldorigin` — the origin the **mapper drew**, cached before `Find()`
teleports the train onto its first `path_track` — and applies **no rotation**. This
tree measured against the *live* origin and additionally rotated the box by the
train's post-placement yaw.

Measured across the corpus: **12 of the 13 `func_traincontrols` in existence** sit
152–6160 units from their train's first path_track, so on all twelve the override
was replacing a usable default box (the train's own bbox + 72 units of headroom)
with an unreachable one — supplying a controls brush made a train *harder* to drive
than not supplying one. th_escape is where it became visible: its truck is drawn at
`-630 1281 -496` and `ccc_01` is 3000 units away, and the computed box landed
~2300 units outside the vehicle.

Two fixes, both HL's own formula: cache the authored origin (`.tt_authored_origin`),
and drop the rotation. Verified against the .bsp by hand — brush `*470` spans
`-688 1235 -466 .. -620 1288 -400`, the truck hull is local `x -154..172,
y -54..58, z -2..120`, and the result is `x -59..11, y -47..8, z 29..97`: the
driver's seat, inside the cab.

**And one guard HL does not have.** Because the override *replaces* the default
box, a brush the mapper left in the wrong place does not merely fail to help — it
removes the box that would have worked. The sweep found the map that needs it:
`infested`'s `entrancetruck1` is a **14×56×20** sliver (smaller than a player
hull) at world `2738 -2783 -156`, while the truck it names is drawn at
`-567 1992 -560` — five thousand units away, and 560 units from the train's first
`path_track` too, so it is not "authored at the destination" either. It is a
leftover brush, and under Half-Life's own maths that truck is undriveable.

`TrackTrain_ControlBoxSane` now rejects an override that is disjoint from the
train's hull (8 units of slack) and keeps the default, loudly. All four legitimate
overrides in the corpus pass — including th_ep1_00's, which sits on the flatbed
roof and overlaps the hull by a **single unit**, which is why the test is
intersection with a small margin rather than containment.

A third fix, latent until now: `TrainControls_PlayerInControls` computed
`lp_y = rel * v_right` where HL writes `local.y = -DotProduct(offset, v_right)`.
`makevectors` returns `(0,-1,0)` at yaw 0 in both engines, so the axis was mirrored.
It never mattered while the only box in play was the train's own near-symmetric
bounding box; it stops being latent the moment a controls brush supplies a
genuinely one-sided box, which th_escape's cab does.

### The two ambush triggers

`trigger_playercheck` (26 placements) counts living players in a brush and toggles
its target when the comparison changes; every one on the map is `mode 2` (==),
`threshold 0` — *"nobody is in this room"* — targeting a `squadmaker`, which is why
th_escape's zombies appear behind you and never in front. The 27th,
`dtown_chkmaster`, inverts it and is the `master` of the four downtown checks, so
that whole ambush set only arms once somebody is actually in downtown. Sven's own
class special-cases a master that is itself a `trigger_playercheck`, because
`IsMasterTriggered` only understands `multisource` / `game_team_master` and would
otherwise report the permissive TRUE — the same special case is required here for the
same reason, and th_escape needs it.

`trigger_look` (7) fires on where the players inside are *facing*. All seven are
`trigger 0` / `difference 130` / `inverse 0`: fire when every living player inside is
more than 130° away from the trigger's yaw. Six target a `squadmaker`; the seventh
targets `lkzone01_dr`, the door that only opens behind your back. **All-or-nothing is
not a simplification** — the source tracks `bCanUse` and a separate `bUseLock` and
the lock wins, which on a co-op server is the entire point.

Two deliberate divergences, both documented in place:

- **Edge-triggered.** `CTriggerLook::LookThink` calls `FireTargets` unconditionally
  every tick, so at `delaychecks 0.5` the seven volumes re-fire their chains 14 times
  a second for the whole map. Harmless (this tree's `squadmaker_use` explicitly
  no-ops a re-asserted `USE_ON`) but it makes `sv_debug_monsters` useless for exactly
  the thing you would read it for. The same author's later `trigger_playercheck` is
  natively edge-triggered, so this is his own refinement applied backwards.
- **Player view yaw comes from `.v_angle`, not `.angles`.** Sven reads
  `pev->angles.y`, which for a GoldSrc player *is* the view yaw; in this tree
  `.angles` on a player is the model/pose angle (prop-hunt rewrites it outright at
  `sv_player.qc:1406`). `.v_angle_y` is the faithful read, not a divergence.

**Seven new BSP key spellings** — `mode`, `threshold`, `interval`, `difference`,
`trigger`, `delaychecks`, `inverse` — were scanned across all **141** maps in
`svencoop/maps` and `svencoop_downloads/maps` before being declared. Each appears on
its own class and on nothing else, with **0** targetname collisions and **0**
`multi_manager` slot collisions. As with the InventoryRules block, declaring them
also stops them leaking into `ED_ParseUnknownEpair`'s `MM_AddSlot` allocation.

### MapScript_Call: all 17 of th_escape's script functions

The registry gained its second entry, in its own file
(`server/sv_mapscript_thescape.qc`) so one campaign's 900 lines do not bury the
dispatch. `SetCharacters`, `EquipCharacters`, `StartCharacters`, `TargetItemBattery`,
`TargetItemGasCan`, `TargetItemToolbox`, `AllItemsDroppedOff`, `ReadGameCounter`,
`VehicleIgnitionOn`, `VehicleStarted`, `NormalDifficulty`, `NightmareDifficulty`,
`AbortGame`, `EndGame`, `GameOutro`, `ShowSurvivors`, `ShowLosers`.

The piece the map cannot do without is the **escape timer**. `StartCharacters` arms
it against `timesup_mm` — the multi_manager that blows the truck's engine and dumps
headcrabs — with a 60-second warning at `lastmin_mm_relay`. Neither name is reachable
from any trigger in the entity lump; the script is the *only* thing that fires them.
Eight minutes, seven on nightmare, plus one if four or fewer players.

**Player `.targetname` is load-bearing and must not be "tidied" into a private
field.** `PlayerCharacters::Set` writes the character name there and `SortPlayers`
later overwrites it with `winnars` / `lastliving` / `ghostboyes`, and th_escape's
entity lump addresses players by those names five different ways: `trigger_respawn
target`, `info_player_deathmatch message` (a group-restricted spawn),
`trigger_entity_iterator name_filter`, `trigger_changevalue target` and
`trigger_renameplayer netname`. A parallel field would look tidier and break every
one of them. The character *index* is cached separately, because `targetname` stops
naming a character once the sort runs.

**Character models work because they are the same skeleton.** All sixteen th_* player
models parse to 191 sequences with identical labels in identical order — and so does
`models/player/sini.mdl`, which this tree already ships as team model index 5. So the
mod's own `SH_PlayerAnim_*` drives them correctly. New `.player_model_override`
(`sv_customdefs.qc`) checked first in `PlayerApplyModel`, cleared on disconnect but
**not** on respawn, because th_escape respawns players three times in its ending
sequence alone.

Two things fell out of doing the equipment properly:

- `GoldSrc_GiveNamedItem` — HL's `CBasePlayer::GiveNamedItem` as one entry point,
  lifted out of `GamePlayerEquip_Apply` where the four-step chain (grant-item-class →
  give-by-classname → strip `weapon_` → weapon manifest) was previously the only
  copy. The characters' equip lists mix both halves in one string
  (`weapon_colt1911;ammo_9mmclip`), so re-implementing the walk would have been the
  second copy that drifts.
- `maps/<name>_skl.cfg` is now loaded, by `SetSkill()`. Nothing else in this tree
  ever loaded it, and th_escape ships one with 80-odd `sk_*` overrides.

### Not ported, and why

- **`RndBreakables`** (19.7 KB) — randomises what falls out of named breakables. It
  is driven from `MapInit`/`MapStart` and is not one of the 17 `trigger_script`
  functions, so it is outside what the registry is for.
- **`LowHealthFX` / `DrunkFX`** — screen effects. The two drunk characters still get
  their grenade; they just do not stagger.
- **`VehicleCustom`** (`func_vehicle_jp`, 36.7 KB) — the tutorial vehicle used before
  the truck. `StartCharacters` swaps Sven's PlayerUse hooks from it to the
  trackvehicle; here both classes are always driveable by their own code, so the swap
  has nothing to do. Its two classes (`func_vehicle_custom`,
  `func_vehiclecontrols_custom`) remain inert relays.
- **The three objective sprites.** Sven draws `sprites/th_escape/item_*_48_{on,off}.spr`
  as HUD sprite channels; this tree has no HUD-sprite wire format, so the same
  information goes out as a `game_text` objective list on its own channel.

### The FLAC problem, recorded rather than swallowed

`CTrackVehicle::Precache` asks for `th_escape/diesel_idle_loop.flac`, and the
ignition and rev one-shots are `.flac` too. **FTE cannot decode FLAC**: the loader's
extension list is `.wav` / `.opus` / `.ogg` only (`engine/client/snd_mem.c:1044-1051`)
and `snd_minimp3.c:137` explicitly rejects a buffer whose magic is `fLaC`. The files
are on disk and are real FLAC, so precaching them buys a console warning and silence.

The engine loop therefore comes from `func_tracktrain`'s own `sounds` enum, which
th_escape's vehicle already sets — `sounds 2` → `plats/ttrain2.wav`, a stock valve
asset certain to be present. The map's authored intent (there *is* an engine noise,
keyed off `sounds`) is preserved; only the sample differs. The `.flac` paths are
still resolved and precached so a future engine with a decoder needs no code change.
th_escape's own `ambient_generic` entities already reference seven more `.flac`
files, so this changes nothing about the map's boot behaviour.

### Verification

New `sv_thescape_test`: **61 assertions, BAD=0**, run on th_escape with bots. It
drives the real functions — `FuncTrackVehicle_Accel`, `MapScript_Call`,
`PCheck_Test`, `trigger_look_think` — against fixtures it builds itself, and it
asserts the cab box against numbers computed by hand from the .bsp. It is
destructive to the live script state (it arms and expires the timer against its own
probe) and disarms its own cvar when it finishes.

Also measured on th_escape, headless, `qcerr=0`:

- Unimplemented classnames **8 → 4**. What is left: `func_vehicle_custom` and
  `func_vehiclecontrols_custom` (the map-local tutorial vehicle, deliberately out
  of scope — see above) and the two stock Sven classes `trigger_numericdisplay`
  and `trigger_renameplayer`, both cosmetic on this map.
- `[thesctest] map bound: 1 func_trackvehicle, 1 controls, 7 trigger_look,
  26 trigger_playercheck, 17 trigger_script` — and `26 interval, 7 difference`
  keys bound, i.e. real BSP keys reaching the real fields.
- The **ending fires end to end**: the last living bot died,
  `CheckEndConditions` → `SortPlayers` (`0 winnars / 0 lastliving / 1 ghosts`) →
  `TriggerEnding` → `everyonedied_rel`.
- The timer fired both its warning and its expiry.
- **Ten-map sweep, every one `qcerr=0`**: crossfire, hl_c01_a1, desertcircle,
  svencoop2, crystal, th_escape, hl_c05_a1, th_ep1_00, hl_c08_a1, infested. The
  last four are the maps carrying a `func_traincontrols`, i.e. the widest-reaching
  edit here. Their control boxes now compute to train-local values that were
  checked against the BSPs by hand: th_ep1_00 `-7 -35 115 .. 67 41 221` on both
  trucks (the standing volume above the flatbed, whose top is local z 116),
  hl_c08_a1 `crashtrain` `-119 -61 7 .. -63 61 57`, infested `ladderlibrary`
  `-25 -25 37 .. 25 25 119` (a player-sized volume on top of a lift), th_escape
  `-59 -47 29 .. 11 8 97`. Every one predicted before the run. The fifth,
  infested's `entrancetruck1`, is rejected by the sanity gate at **5761 units**
  from the hull and falls back to the default box — so that truck is now
  driveable, which it was under neither the old maths nor HL's.
- `mm-collide` is unchanged and none of it is ours: hl_c01_a1's 2 (on `think`, an
  engine field, documented as unrecoverable in `sv_multi_manager.qc`'s header) and
  crystal's 1 — verified from the BSP to be `fadein` / `fadeout`, long-standing
  `game_text` fields, with the log reporting **0 unrecoverable**. Scanned crystal
  and hl_c01_a1 directly against all 18 field names this patch declares: **no
  collisions**.
- Character assignment is real and random: two bots drew `player_nurse` and
  `player_mechanic`, models `th_nurse` / `th_worker` resolved with no
  "not precached" warning, and both equip lists were consumed.

One bug was found by review after the first green run and is now guarded by an
assertion of its own: `FuncTrackVehicle_CheckControlLoss` had no `TV_STATE_RUNNING`
precondition, and since a vehicle spawns with `TT_NO_USERCONTROL` *and* KEEPSPEED
both set, the first tick after ignition would have latched the accelerator decay off
for the rest of the map — the truck would have held whatever speed you last asked
for instead of coasting. `decay still live after ignition` is the tripwire.

### Standing audits

`optional_audit.py` PASS (351 files, 0 findings). `cvar_audit.py` is back at its
**12-finding** baseline — the new `cvar_set("skill", …)` briefly made it 13, so
`skill` is now a declared table entry (nothing in this tree reads it; the `sk_*`
values live in the table rather than being picked by suffix, but Sven map cfgs set
it and the script writes it).

`check_serverfire.py` reports one FAIL, `WEP_CSXM1014` — **pre-existing and not
from this patch.** That weapon does not exist at HEAD; it is one of PATCH 159's
thirteen Counter-Strike guns and the finding belongs to that work. No weapon file
was touched here.

### Owed by eye

- Driving the truck. The `+use` mount needs a player who is `FL_ONGROUND` inside the
  control box, and no harness player is both grounded and unicast-reachable — so the
  box, the lock that keeps it undriveable before `VehicleStarted`, and everything the
  throttle does afterwards are all covered, but the press is not.
- Whether the accelerator *feels* like Sven's. The ladder is per-usercmd in both
  engines, so the cadence should match, but that is an argument, not a measurement.
- The character models rendering (the model paths are logged; the pixels are not).
- The `game_text` timer and objective list — position, colour, and whether the
  one-second refresh reads as a clock rather than a flicker.

---

## PATCH 160 — Sven's item_inventory, and the gate that makes it mean anything

th_escape places twelve `item_inventory` — a car battery, a gas can and a toolbox,
each at several alternative spawn points, for two vehicles — and the player carries
them to a truck with `+use`. The class had no spawn function, so all twelve were
inert relays.

### The half that is easy to miss

Sven's inventory system is two things, and shipping only the first leaves the map
worse than untouched. `item_inventory` is the carriable object; **InventoryRules**
is a block of keys that eleven *other* classes can carry (`func_button`,
`func_rot_button`, `func_door`, `func_door_rotating`, `func_water`,
`func_tankcontrols`, `func_traincontrols`, `trigger_changelevel`, `trigger_once`,
`trigger_hurt`, `trigger_multiple`) which gate whether they fire for the activator.

th_escape leans on both: `item_name_required` on 15 `trigger_once`,
`item_group_required` on a further 11, and `pass_destroy_item_name` on the six
drop-off pads at the trucks.

**What that meant before this patch:** the drop-off pads were ungated
`trigger_once`. Walking over the slab fired `veh1_itm{1,2,3}goalmm` outright, drove
the `veh1_itmcount` counter (`health 3`) to its threshold and opened the repair
gate the first time anybody wandered past — the entire fetch quest, which is the
map, skipped in the opening seconds. Same for the veh0 tutorial truck, for the nine
sewer relays (one descent fires all three, spawning the sewer beast immediately),
and for the eleven `item_group_required` ambushes, which all went off on first
traversal instead of being reserved for the item runs.

### Sources

Everything is read out of Sven's own shipped files, not recalled:
`svencoop/sven-coop.fgd` (`item_inventory` at :3422, `InventoryRules` at :424,
`Pickup` at :289 for the spawnflags) and the item_inventory release notes in
`svencoop/manual/changelog.html`. `spawnflags 1280` decodes as 1024 Disable Respawn
+ 256 **USE Only** — so th_escape's items really are `+use`-only, with line of
sight required (512 not set).

Two effects carry the map, and both are the ones that had to be right:
`effect_speed 50.0` (half speed with a car battery in your arms) and
`effect_block_weapons 1` (both hands full, no shooting). Every other `effect_*` on
those twelve entities is written at its neutral value.

### Prediction

`effect_speed` changes movement, and movement here is client-predicted, so the
aggregate is not applied server-side at all. `Inv_RecalcEffects` folds the held
chain into four scalars on the player — `pm_inv_speed_pct`, `pm_inv_gravity_pct`,
`pm_inv_friction_pct`, `pm_inv_blockfire` — which ride the CSQC prediction proxy
(**version 25 → 26**, four fixed bytes after `pm_longjump` and before the
conditional car block) and are read by `sh_pmove.qc` on both sides. Same shape as
the Prop Hunt disguise hull at `sh_pmove.qc:3024`. `effect_block_weapons` is ORed
into the existing `pm_carrying` lower/fire gate rather than duplicating it —
"carried with both hands" and the HL2 carry are the same statement.

### An edict leak that went away for free

`ED_FindField` runs before the `ED_ParseUnknownEpair` hook, so until these fields
were declared every `item_inventory` key fell through to `MM_AddSlot` and allocated
a junk `mm_slot`, while the three bare `item_*` spellings fell into the
`game_player_equip` harvest instead (its exclusion tests `item_name_`, with the
underscore, so `item_name` misses it) and allocated `gpe_item` children that nothing
reaps. Measured on th_escape: **27 leaked `gpe_item` edicts → 0**, and the junk slots
carrying `key="weight" value="16"` / `key="effect_damage" value="100.0"` → 0.

### Measured

- Three VMs, **0 warnings** each; `quakers_csprogs.pk3` repacked.
- **`sv_inventory_test` — 31 assertions, BAD=0.** Builds its own items and its own
  rules entity and drives `Inv_Collect` / `Inv_Drop` / `Inv_Gate` directly, because
  the map route needs a player standing in a brush volume holding a specific entity
  and the harness has no hands. Covers collect, `item_name_canthave`, the replicated
  `effect_speed 50` and fire block, the gate in both directions,
  `item_group_required_num` 1 **and** 0, `item_group_canthave_num` 0,
  `pass_destroy_item_name`, drop → return → materialise, and a held item being
  `remove()`d out from under the holder.
- th_escape headless: `item_inventory` no longer in the no-spawn-function list,
  0 QC errors.

**A note on how that test first failed**, because it is the more useful record: it
reported `collect succeeds: got=0` alongside `weight accrued: got=16 PASS` — an
incoherent set that invites blaming the assertion machinery. The machinery was fine.
The *fixture* was collecting itself: the test items spawned `SOLID_TRIGGER` with no
spawnflags, and `SV_CheckTouchTriggers` (`sv_use.qc:474`) fires `.touch` for any
`SOLID_TRIGGER` near a player, so a bot picked the second item up between stages.
`InvTest_MakeItem` now sets `PICKUP_SF_USE_ONLY`, which is what th_escape's own
items set.

### Two things worth knowing about the semantics

- **`item_group_required_num 0` and `item_group_canthave_num 0` are not symmetric.**
  Required-0 means "every item that exists in that group"; canthave-0 means "not even
  one". Reading them the same way inverts the rule — a player holding one of three
  quest items would pass a gate meant to exclude them. Both directions are asserted.
- **`trigger_hurt` inverts the gate.** Sven's entry for it is "Defend player from
  damage", so *passing* protects you. That needs `Inv_HasRules` as a precondition:
  `Inv_RulesPass` correctly returns true for an entity with no rules configured, and
  under the inverted sense that would have made every unconfigured `trigger_hurt` in
  the corpus stop hurting anybody.

### Also fixed here, because the item mechanic needs it

`trigger_multiple` / `trigger_once` spawnflag **bit 8, "Everything else"**. Sven adds
it to Half-Life's three; the mod knew only bits 1/2/4. Both `veh*_dropoffs`
`trigger_multiple` carry spawnflags 26 (2|8|16) — the map's *second* delivery route,
dropping the battery into the truck bed rather than walking it in — and with bit 8
unknown, bit 2 rejected the player and the absent bit 1 rejected the item, so the
volume could never fire for anything. Accepting bit 8 is additive (either bit works
for a non-player, non-monster, non-pushable) so no existing `ALLOWMONSTERS` trigger
loses anything. It also needs a sweep in `trigger_multi_scan`, because a dropped item
and a trigger volume are both `SOLID_TRIGGER` and the engine never generates a touch
pair between two of those. Bit 32 "Fire On Exit" is **not** implemented (needs
per-toucher edge tracking); bit 16 "Fire On Enter" is already this file's behaviour.

### Owed by eye

The harness replaces `SCR_UpdateScreen`, so nothing here has been *seen*:

- The HUD strip. The icon path is `drawpic(spriteframe(...))` — a `.spr`'s pixels are
  unreachable through `precache_pic`, and these icons are `SPRHL_ADDITIVE`, so they
  are drawn with `DRAWFLAG_ADD` or they paste an opaque black square. Verified by
  reading the engine, **not** by running it.
- The `+use` press itself. Everything it goes on to do is covered; the press is not,
  because no harness player is both grounded and unicast-reachable.
- Carrying at half speed feeling right, and the gun visibly lowering.

### Found on the way, NOT fixed — th_escape is still not completable

This patch does what was asked and the fetch quest now works end to end, but the map
has four further gaps that have nothing to do with inventory:

1. `func_trackvehicle` + `func_trackvehiclecontrols` — the escape truck itself — have
   no spawn function.
2. `MapScript_Call` (`sv_mapscript.qc:95`) only knows `hc2`, so the map's 17
   `trigger_script` entities never reach `StartCharacters` (which arms the timer and
   the fail path), `VehicleIgnitionOn` or `VehicleStarted`.
3. `trigger_playercheck` (26 instances, map-local AngelScript) gates every ambush
   spawner; as inert relays the "don't spawn in your face" logic is gone.
4. `trigger_look` (7, also map-local AngelScript) — the "spawn while you aren't
   looking" ambushes.

`trigger_numericdisplay` and `trigger_renameplayer` are stock Sven classes and also
missing, but both are cosmetic here.

### Corpus payoff

116 `item_inventory` across 11 maps; 12 maps carry at least one non-default
inventory key. `mustard` (32), `sc_robination_revised` (30), `snd` (22),
`turretfortress` (13) and th_escape (12) are the bulk. `sc_robination_revised` and
`grunts_party` use the item with no gating keys at all — pure carriable props.
`pass_return_item_name` (31 uses across `mustard`, `snd`, `bm_sts`, `judgement`) and
`target_on_fail` (2, `polar_rescue`) are implemented but exercised by nothing on
this map.

---

## PATCH 159 — the other thirteen Counter-Strike guns, and not one new asset

The mod already carried twelve of Counter-Strike 1.6's twenty-five weapons plus the
knife and all three grenades. This adds the remaining thirteen — P228, Five-Seven,
Dual Berettas, TMP, MAC-10, UMP45, P90, Galil, FAMAS, AUG, SG-552, SG-550 and
XM1014 — as ids 101-113, and every one of them appears in the F5 debug panel and
the buy menu.

### Nothing was shipped, because nothing needed to be

`cstrike` is mounted (`fs_addons.txt:16`) and carries `v_`, `w_` and `p_` models for
all thirteen plus their complete audio set, so each weapon points straight at
`models/v_aug.mdl` the way `sh_wpn_csglock.qc` already points at
`models/v_glock18.mdl` and `sh_wpn_hlcrowbar.qc` at valve's `models/v_crowbar.mdl`.
**Zero new files under `quakers/models` or `quakers/sounds`.**

They also take the REAL Counter-Strike classnames — `weapon_p228`, `weapon_aug`,
`weapon_xm1014` and so on. All thirteen had **zero references** in this tree before
the patch, so nothing is displaced and a GoldSrc CS map that places one now gets the
right gun instead of "no spawn function".

The bare manifest keys stay where they were. `"aug"`, `"famas"`, `"galil"`,
`"p228"`, `"elite"`, `"mac10"`, `"ump45"`, `"sg552"`, `"xm1014"`, `"fiveseven"` and
`"sg550"` are all already bound to CrossFire weapons that have owned them for
several patches; stealing one would silently redirect every existing `wep_give`,
map-cfg equip and buy alias that names it. These answer to `"cs<name>"`. Two keys
were written and then deleted as **dead code** rather than left looking live —
`"xm1014"` resolves to `WMF_WEP_CFSPAS12` and `"m4super90"` to `WMF_WEP_CFM4`
further up the chain, and first match wins.

### The models name their own sounds — and the tool that reads them was wrong

Every sequence index, every event fraction and every `.wav` name in these thirteen
files was read out of the model files, not guessed. A GoldSrc studio event of code
5004 carries its sound filename in `options[64]`:

```
== v_aug.mdl
  [1] reload   40fps 133f  3.300s
       ev f10   code=5004  frac=0.0758  "weapons/aug_boltpull.wav"
       ev f50   code=5004  frac=0.3788  "weapons/aug_clipout.wav"
       ev f88   code=5004  frac=0.6667  "weapons/aug_clipin.wav"
       ev f112  code=5004  frac=0.8485  "weapons/aug_boltslap.wav"
```

**`/c/tmp/seqlist.py` cannot show you any of that, and what it does show is wrong.**
It walks the event array with a stride of **72** bytes where `mstudioevent_t` is
**76** (`int frame; int event; int type; char options[64];`), so every event past
the first is read from the middle of its predecessor — which is where the phantom
`f0:code0` / `f0:code50` rows in its output come from — and it never reads
`options[]` at all. A corrected dumper is in this session's scratchpad as
`csseq.py`. Anything previously derived from `seqlist.py`'s event column should be
treated as unverified.

### Mount ambiguity is real here, and it is handled by name

**cstrike and czero both ship all thirteen filenames**, and they differ:

| | cstrike | czero |
|---|---|---|
| `v_aug` idle | 9 frames, 0.267 s | 2 frames, 0.033 s |
| `v_galil` reload | 35 fps | 34 fps |
| `v_ump45` | **6 sequences** | **7** — it has a `shoot_empty` cstrike lacks |

So every sequence resolves through `SH_SeqForName`, every duration through
`SH_SeqDuration`, and every sound mark is a **fraction** of the resolved duration
rather than a number of seconds. The UMP45 asks for `"shoot_empty"` unconditionally
with an ordinary shoot take as the range-checked fallback: on czero it gets the real
slide-locked take, on cstrike an ordinary one. That is the clearest demonstration in
the tree of why these files resolve by name.

### The four that are not just a reskinned rifle

- **Dual Berettas** alternate left and right, so the shoot take is picked from the
  parity of `wep_action_id` (`shoot_left1..5` / `shoot_leftlast` against
  `shoot_right1..5` / `shoot_rightlast`), which keeps server and client in step with
  nothing extra on the wire. Casing eject and muzzle flash mirror with it. Its
  reload is the longest of any pistol in the game at 4.567 s with **six** sound
  stages, two of them the same `elite_sliderelease.wav` at different fractions.
  `idle_leftempty` is deliberately unwired: there is no half-empty-dual state to
  hang it on and inventing one would need a wire field.
- **FAMAS** gets a real 3-round burst on alt-fire, shaped after the CS Glock's, with
  the mount's own `famas-burst.wav` for the burst shots.
- **SG-550** is the CT twin of the G3SG1 the mod already had, so it borrows that
  file wholesale — `SCOPE_CLASS_SNIPER_SEMI` (stays scoped through a shot, which is
  what makes an autosniper an autosniper), zero base spread while scoped, and the
  same `wpn_csawp/zoom.wav` so the two autosnipers sound alike.
- **XM1014** is the first **sequence-driven shell-by-shell reload** in the tree. The
  M3 does shell-by-shell against a flat frame bake and loops a frame range;
  `v_xm1014.mdl` has three separate sequences (`start_reload` 0.667 s, `insert`
  0.389 s, `after_reload` 0.400 s), so the loop is expressed as time. The plan —
  `shells = min(MAX_MAG - mag, ammo)` — is fixed at reload start on both sides from
  state they both hold, exactly as the M3's is, so nothing consults mag or ammo
  mid-reload and the two halves cannot drift. The `insert` take is restarted per
  shell through `csqc_viewmodel_sequence_time_override`, because the engine clamps a
  non-looping sequence to its final frame (`gl_hlmdl.c:1076-1082`) and shells two
  onward would otherwise show a frozen pose.

### Two model traps that would have been silent

- **`v_tmp.mdl` labels all three of its firing takes `"shoot"`.** `frameforname`
  returns the first, so a by-name lookup for `shoot2`/`shoot3` returns the same
  index three times. `sh_wpn_cstmp.qc` resolves `"shoot"` once and derives the other
  two as base+1 / base+2, and says why — otherwise a later reader "fixes" it into
  three lookups that all return the same number.
- **`v_tmp`'s draw event sits at fraction 1.0000** — the very last frame. A mark
  tested with `elapsed >= dur * 1.0` can be skipped entirely, because the state
  machine leaves `WS_DRAW` at that instant and no tick is guaranteed to land on it.
  Same for the XM1014's `start_reload`. Both are clamped just inside the end.

Two models carry **no draw sound event at all** (`v_ump45`, `v_sg550`) and two of the
XM1014's three reload sequences carry none either. Those branches are simply absent
rather than filled with a borrowed sample — except the XM1014's shell insert, where
`weapons/m3_insertshell.wav` is named explicitly with the note that Counter-Strike
shares one shell-chambering sample across both its shotguns.

### Balance: placed on the mod's ladder, not transcribed from CS

Raw CS damage values would be meaningless here — the mod's CS MP5 is 12/6 where CS
1.6's is 26. Each gun was placed against its existing neighbour and the CS
*relationship* preserved. Scaling the four new SMGs off the mod's MP5 by CS's own
base damages (MP5 26, TMP 20, MAC10 29, UMP45 30, P90 21) gives:

| | close/min | delay | reach |
|---|---|---|---|
| TMP | 9/5 | 0.11 | 1900 |
| P90 | 10/5 | 0.087 | 2400 |
| MP5 *(existing)* | 12/6 | 0.10 | 2048 |
| MAC-10 | 13/7 | 0.09 | 1800 |
| UMP45 | 14/7 | 0.11 | 1800 |

which reproduces every ordering CS has: the UMP45 hits hardest per bullet, the
MAC-10 fires fastest of the .45s and is the least accurate, and the P90 is the
fastest overall with the lowest per-bullet damage and — sharing the Five-Seven's
5.7×28mm — the longest reach of the five. The rifles take their CrossFire twins'
numbers nearly verbatim, because those are the same real guns already on this
ladder; AUG 32/21 and SG-552 33/22 keep them near-twins with the SG-552 slightly
harder-hitting, below the AK47's 34 and above the M4A1's 24. **Prices are the real
CS 1.6 ones**, which is the only defensible answer for a set this size.

### Verified

- Three VMs, **0 warnings** each; `quakers_csprogs.pk3` repacked.
- **`AI_WeaponRosterSelfTest`: 113 weapons, 0 missing rows, 0 mirror failures,
  BAD=0** — every id has a manifest row and every primary/secondary survives the
  slot-ammo round trip in both directions, which is what proves the two dispatch
  tables in `sh_weapon_slotammo.qc`.
- **`sv_satchel_test`: BAD=0**, including `every advertised weapon can be given: 0`
  and `manifest debug_order reaches every weapon: 112/112` and `buy_order has no
  gaps or duplicates: 0`.
- **`AI_SeqNameSelfTest` now probes all thirteen viewmodels.** Every sequence name
  each file resolves by is present, with durations matching the model byte for byte
  (`v_aug` reload 3.300, `v_elite` reload 4.567, `v_xm1014` insert 0.389). The lines
  also say which mount answered: `v_p228 idle1(0.625)` is cstrike's, czero's is
  0.062. The single `MISSING: shoot_empty` on `v_ump45` is the documented
  czero-only sequence and is probed for deliberately.
- Every `.wav` and model path in the thirteen files checked against the actual
  directory listing: **37 distinct sounds, 0 missing**. Headless client run: **0 QC
  errors, 0 "unable to load"**, so all thirteen viewmodels resolve CSQC-side too.
- Map sweep at **0 QC errors**: crossfire, hl_c01_a1, svencoop2, desertcircle,
  crystal.
- Symbol-collision scan across all weapon files and the shared headers: **0**.
- Credential scan of the diff and every untracked file, all seven patterns: **0**.

### Two things the harness caught that review had not

1. **The three pistols were advertised and ungiveable.** Their `case` arms landed in
   `W_RefreshPrimarySlot`'s switch, where they compile clean and are never reached —
   that function only runs for a primary. They drew in every menu and put nothing in
   your hands. `sv_satchel_test`'s give sweep named all three by id.
2. **`debug_order` had a hole at 100.** The existing run ends at 99 (100 weapons
   minus the intrinsic fists) and the new block started at 101, so
   `WeaponManifest_DebugWeapon(99)` resolved to `WEP_NONE` and the last weapon was
   unreachable from the F5 grid. Slid to 100-112.

### Found on the way, NOT fixed — pre-existing

**108 of the mod's 112 weapon world models are unprecached when the debug grid
spawns them.** Turning on `sv_debug_weapons 1` produces 108 `SV_ModelIndex: model
... not precached` warnings, and they are not this patch's: the list is every weapon
in the mod — `wpn_csak47/w_ak47.mdl`, `wpn_cfaug/w_aug.mdl`, `w_crowbar.mdl` — and
the only four that DO precache are exactly the OpFor/pizza models a previous patch
hand-moved into `precache_everything` for this reason (`w_displacer`, `w_shock`,
`w_bgrap`, `w_glock18jet`). It is not fatal — `SV_ModelIndex` (`pr_cmds.c:3069`)
adds the model and late-precaches when `sv.state != ss_loading` — and a normal run
without the grid shows 3 warnings, unchanged. But `precache_everything` visibly
reaches its OpFor block and visibly does not take effect for the weapon lines after
it, and nobody has explained why. Worth its own pass.

### Owed by eye

- Firing all thirteen. The build proves every model, sound and sequence name
  resolves and the roster/give tests prove they can be handed out, but the harness
  replaces `SCR_UpdateScreen`, so no viewmodel has been *seen*.
- **Muzzle offsets are seeded, not tuned.** Every one was derived from a neighbour
  rather than measured against the cstrike mesh; `cl_debug_muzzle` is the arbiter.
- **ADS poses are `ADS_RegisterPoseCvars` baselines** for all thirteen. The
  CrossFire twins' hand-tuned poses do not transfer — those are different meshes.
- The AUG's and SG-552's low-power scope, and the SG-550 staying scoped through a
  shot where the AWP does not.
- The Dual Berettas actually alternating hands, and the XM1014 loading shell by
  shell and stopping at seven.

---

## PATCH 158 — one untyped noise, one clip that ran too late, one class filed as scenery, and a teleporter nobody could switch off

Four reports from play-testing, and three of them turned out to be a *different*
defect than the symptom suggested.

### 1. The scientists follow you around, and gunfire does not scare them — ONE bug

Both faces of it are the same omission: **world sounds carried no type.**
`AI_HeardNoise(org, radius)` had a position and a radius and nothing else, so a
footstep and a gunshot arrived as the same event.

Half-Life filters heard sounds **twice** and both halves were missing.
`CBaseMonster::Listen` (`monsters.cpp:211-217`) ANDs the monster's own
`ISoundMask` with the mask of the schedule it is currently running —
`iMySounds &= m_pSchedule->iSoundMask` — under an SDK comment reading
*"!!!WATCH THIS SPOT IF YOU ARE HAVING SOUND RELATED BUGS! Make sure your schedule
AND personal sound masks agree!"*.

- **The phantom follow.** `AI_HeardFootstep` fires a 320/640-unit noise every
  0.35 s; `AI_HeardNoise` promoted `MS_IDLE` → `MS_ALERT` for it; and the ALERT
  ladder handed out `SCHED_INVESTIGATE_SOUND` — a WALK to wherever the player was
  standing, re-aimed every 0.35 s. No `+use`, no `ai_follow`, no enemy involved.
  Half-Life's alert branch investigates **`bits_SOUND_COMBAT` only**; everything
  else falls through to `ALERT_STAND`. That test now exists.
- **The deaf scientist.** `CScientist::GetSchedule` (`scientist.cpp:938-956`)
  ducks on `bits_SOUND_DANGER | bits_SOUND_COMBAT`, rate-limited to once per three
  seconds by `m_fearTime`. That predicate was **unwritable** here, because nothing
  could ask what kind of noise it was.
- Every `CTalkMonster` idle schedule carries `bits_SOUND_COMBAT | bits_SOUND_DANGER`
  with **`bits_SOUND_PLAYER` and `bits_SOUND_WORLD` commented out in the SDK source
  itself** (`talkmonster.cpp:287-291`), which is why an idling HL scientist cannot
  hear you walk past at all.

Shipped: `SND_COMBAT/WORLD/PLAYER/CARCASS/MEAT/DANGER` at Half-Life's own bit
values, `.ai_soundmask` / `.ai_soundtype`, `AI_SoundMaskNow`, the COMBAT gate on
investigate, `SCHED_STARTLE`, `SCHED_MOVE_AWAY` + `COND_CLIENT_PUSH` (bump an ally
and they step aside — `CTalkMonster::Touch`, `talkmonster.cpp:876-896`), and
`TASK_GET_PATH_AWAY` with the `FindCover` fallback that stops them retreating into
corners (`talkmonster.cpp:458-481`).

**And they fled at walking pace** because the mover asked
`ai_moveact == ACT_RUN` — an identity test. `ACT_RUN_SCARED` is **64**, not 4, so a
fleeing scientist was moved at `ai_speed_walk` 59 while playing a cycle drawn for
275, which is also why he skated. `AI_ActivityIsRun` replaces the test.

### 2. hl_c00's scientists "jump very quickly" — `monster_generic` was filed as scenery

`CGenericMonster::Spawn` calls `MonsterInit()` like any other NPC
(`genericmonster.cpp:100-127`). Here it sat in the scenery list beside
`monster_furniture`, so it had no AI — and `Script_Claim` turns **every travelling
move mode into a snap** for an actor without one:

```qc
if (bmv == 1 || bmv == 2 || bmv == 4) { setorigin(m, s.origin); ... }
```

hl_c00's lobby pair are `walker1`/`walker2`, each owned by two
`scripted_sequence`s that point at each other with `m_fMoveTo 1`, so each one
teleported 1192 units back and forth forever. Twelve of that map's twenty
`monster_generic`s are script-driven; the corpus has 166 placements.

Now a registered AI class (`server/monsters/mon_generic.qc`) — no attacks, health 8,
FOV 0.5, `SF_GENERICMONSTER_NOTSOLID` honoured, and explicitly **not** a talker.

### 3. Crates pushed through walls — the clip ran one engine step too late

`MOVETYPE_PUSH` gets no collision from the engine at all: `WPhys_PushMove`
integrates velocity straight through world geometry and ignores other `SOLID_BSP`
pushers entirely. The only thing standing between a crate and a wall is that
`FuncPushable_CollideWorld` refuses to leave a velocity that would cross one — and
it was being asked **after** the move it was supposed to authorise:

1. `PlayerPreThink` → `FuncPushable_Move` **adds** the shove
2. `SV_Physics` → `WPhys_PushMove` **moves** the crate by it
3. ...and only then the think ran the clip

A crate parked flush against a wall had its velocity zeroed by the tick, re-armed
to full push speed by step 1, and driven ~4 units into the brush by step 2 — about
250 u/s of steady penetration for as long as the player kept walking. The clip now
runs at the end of `FuncPushable_Move`, before the engine ever sees the velocity.

Second defect in the same function: a sweep that begins buried returns
`fraction 1` (FTE initialises the trace that way and `q1bsp.c:1018` returns at
`if (trace->allsolid)` before fraction is assigned), so an embedded crate read as
"nothing in the way" and travelled freely. The failure was self-sustaining — one
frame of penetration disabled the only thing that could stop the next. Now detected
explicitly, with the same trace-upward un-embed the teleport arrival probe uses.

### 4. hl_c05_a2's secret teleporter ping-pongs — it has an off switch nobody wired

The silo pair's destinations sit inside each other's brushes by design, and the map
drives the whole thing through `use`:

```
trigger_auto -> st_silo01_in     }  both switched OFF at map start
trigger_auto -> st_silo01_out    }
multi_manager "silod01in2out":  st_silo01_out @1s ON, @4s OFF
multi_manager "silod01out2in":  st_silo01_in  @1s ON, @4s OFF
```

`trigger_teleport` had **no `.use` at all**, so all six commands were discarded and
both halves stayed live — arriving through one landed the player inside the other,
which fired immediately. The reporter's own guess, *"I think they are being enabled
too quickly"*, names the `delay 1` on that `USE_ON` exactly.

Carried in `.spawnflags` as `TELEPORT_INACTIVE`, because that field is already on
the trigger_teleport wire and already read by the shared pmove — so a toggled
teleporter predicts correctly with **no protocol change**.

Also shipped: an arrival latch (`pm_teleport_org`, replicated alongside
`pm_teleport_time`) so a trigger cannot re-fire on a player who has not left it
since arriving. The map sets `teleport_cooldown 0.001` on both triggers and
`0.0001` on both destinations against an FGD default of `"1"` — every timer Sven
offers is deliberately disabled — which is proof the anti-bounce rule is positional
rather than temporal. `teleport_cooldown` itself **stays deferred** for the reasons
already recorded below; its four keys are now merely *declared*, which stops
`ED_ParseUnknownEpair` harvesting them as multi_manager slots
(`[mm-parse] 'st_silo01_in' slot 1: target="teleport_cooldown" delay=0.001`).

### Verified

- Three VMs, **0 warnings** each; `quakers_csprogs.pk3` repacked (the pmove and
  player-proxy changes are both positional wire edits — the VMs must ship together).
- **`sv_ai_sound_selftest`** — new. Asserts the mask algebra against its SDK
  sources and the scared-gait speed pick. `idle-talker=33` (COMBAT|DANGER),
  `default=39` (COMBAT|WORLD|PLAYER|DANGER), `plain=39`, **BAD=0** on six maps.
- **`sv_pushable_selftest`** — new, and it asserts the *invariant* rather than a
  drive: after `CollideWorld(dt)`, sweeping the hull along `velocity*dt` must be
  unobstructed. Three earlier end-to-end attempts were abandoned because the crates
  on both test maps sit on ledges — shoving one takes it over the edge, and what
  gets measured is a fall (subject 803 on svencoop2 reached -137 u/s in half a
  second), not a push. **30 crates over 5 maps, 120 probes, BAD=0**, with 3 probes
  genuinely clipped by geometry so the clip path is exercised rather than trivially
  passing.
- **hl_c00's walkers actually walk.** `walk2` claimed 03:48:24, planted 03:48:44 —
  1192 units in **20 s = 59.6 u/s**, which is scientist.mdl's measured walk cycle.
  Then again 03:48:44 → 03:49:04. Before, both claims landed in the same second.
- **hl_c01_a1 with a bot**: `investigate=0`, scientists `state=1 cond=0 ->
  "idle_stand"` — footsteps no longer wake them.
- **hl_c05_a2**: all six silo teleports `now INACTIVE (usetype 3)` at map start; the
  stray `teleport_cooldown` mm-parse lines are gone (6 → 0); 0 QC errors.
- `regress.sh`: **38 schedules built** (36 + the two new), 181/384 tasks, squad /
  squad-monster / cover all BAD=0, errors 0, crashaddr **2313 → 2313**.
- Six-map sweep (hl_c00, hl_c05_a2, svencoop2, desertcircle, crossfire, crystal):
  **0 QC errors** each.
- Credential scan of the diff and every untracked file: **0 hits**.

### Owed by eye

- A scientist actually ducking when you fire near him, and getting out of your way
  when you walk into him — both are animation, which the harness cannot see.
- Walking the hl_c05_a2 silo teleporter in both directions.
- Pushing a crate into a wall by hand. The invariant is asserted; the end-to-end
  feel is not.

---

## PATCH 157 — globalstate: env_global was reading the wrong key, nothing read it back, and QC globals do not survive a changelevel

The first of PATCH 156's "has a source — implementable now" keys, and the largest:
`globalstate`, Half-Life's cross-map global state machine. It turned out to be a
bug rather than a gap, and finding out how to make it work corrected a claim this
tree has been repeating in three places.

### env_global was bound to a key no map sets

Half-Life reads the state's **name** from the `globalstate` key — `buttons.cpp:73`,
where the SDK's own comment is literally `// State name`. This tree read
`.globalname`, which is an entirely different Half-Life key: entity identity
across a level transition (`cbase.cpp:158/344/405`).

Measured across all 233 Sven + valve maps:

| | |
|---|---|
| `env_global` placements | **36** across 18 maps |
| ...that set `globalstate` | **36** |
| ...that set `globalname` | **0** |
| `globalname` placements (a real key, on other classes) | 387 over 174 names |
| names shared between the two keys | **0** |

So `EnvGlobal_Find` could never match anything. And it did not matter, because
`EnvGlobal_IsOn` **had zero callers** — neither `multisource` nor `trigger_auto`
ever tested a global. Both halves were missing, which is exactly why nothing
looked broken: the writer wrote to a name no one asked for, and no one asked.

### The table, and why it had to become a file

New `server/sv_globalstate.qc` — `CGlobalState` (`world.cpp:280-430`). A table
rather than per-entity state for two measured reasons: `-sp_campaign_portal`
carries two env_globals that both name `generatorglobal` and HL has one row for
it; and **8 of the 24 distinct names in the corpus are cross-map**, defined by an
env_global on one map and read by a gate on another —

```
c2a1_train_power   def c2a1a      read c2a1, hl_c06
c1a4dfuel / doxy   def c1a4d      read c1a4b, c1a4i
sc2newglobal       def svencoop1  read svencoop2
```

The plan was a plain QC global array, on the basis of what `sv_mapglobals.qc:24-28`
has been asserting since PATCH 137: *"FTE does not reload progs between map loads,
so a plain global array already survives a changelevel."* **That is false.**
`SV_SpawnServer` calls `PR_Deinit()` unconditionally — `engine/server/sv_init.c:945`,
inside the function at `:839` — so every QC global is destroyed on every map load,
changelevel included. Measured before writing any code:

```
[globalstate] 4 entries on crystal
[globalstate] map start hl_c06: 0 entries carried in
```

So the state goes to `cfg/globalstate.txt`, and the same correction has been
applied to `sv_mapglobals.qc`, `sv_progs.src` and `sv_main.qc`'s worldspawn
comment. The consequence there is not cosmetic: **func_global's file is not the
"other half" that adds restart survival on top of a working in-memory carry — it
is the entire cross-map mechanism**, and HC2's scientist-count hub works because
of it and only because of it.

`sv_globalstate_persist 0` gives a table that lives one map and never touches
disk. That is the rollback path, not a tuning knob.

One property to know about: **the file is one table for every map**, matching
HL, where the table is global to the game rather than to a campaign. Two
unrelated campaigns that happened to pick the same global name would share a row.
The corpus does not do this — the 24 names are map-scoped by convention
(`c1a4dfuel`, `sc2newglobal`, `c2a2bay1screen`) — and a per-series split like
func_global's would have to guess which maps belong together, which would break
the `c2a1a` → `hl_c06` pair outright since it spans two mods.

### The two readers, and a divergence it closes

| reader | SDK | corpus |
|---|---|---|
| `multisource` — global must be ON *as well as* every input | buttons.cpp:232 | 25 |
| `trigger_auto` — global must be ON or it never fires | triggers.cpp:178 | 29 |

`IsMasterTriggered` re-tests the global **live** rather than folding it into
`ms_active`. That is deliberate: HL re-evaluates `IsTriggered()` on every
`UTIL_IsMasterTriggered` call, so a gate whose inputs are already satisfied opens
the instant an env_global elsewhere — or on an earlier map — flips the state ON.
Caching it would freeze such a gate shut, and for a cross-map global no input
would ever come along to unfreeze it. A multisource *with* a globalstate also
hands its chain `USE_ON` instead of `USE_TOGGLE` (buttons.cpp:207-210), because
these gates unlock things that must not re-lock on a second fire.

**Three corpus gates name a global that no env_global anywhere ever defines** —
hl_c06's `p_ms2` wants `c2a1a_power_master`, hl_c07_a2's two bay screens want
`c2a2bay*screen`. `EntityGetState` returns `GLOBAL_OFF` for an absent name
(`world.cpp:335`), so in real Half-Life those gates are shut forever. Checked
before implementing, because gating them faithfully could have broken two maps:

- `p_ms2` masters nothing and targets nothing. Dead either way.
- The two bay screens are `func_button`s the player presses. The trigger_autos
  were pressing them at map load for you. **That was the divergence**, and the
  gate removes it.

### What it looks like when it works: crystal's elevator interlock

crystal is the one Sven map that wires env_global and multisource to each other,
and reading it end to end is the clearest statement of what was missing:

```
env_global   button1_toggle  globalstate button1_state  initialstate 1  triggermode 3
env_global   button2_toggle  globalstate button2_state  (no initialstate)
multisource  button1_source  globalstate button1_state   <- masters the two
multisource  button2_source  globalstate button2_state      call buttons
multi_manager button1_manager  button1_toggle 0.001 · button2_toggle 3 · elev1 0.5
```

It is a two-ended elevator call: button 1 starts live and button 2 starts dead;
pressing 1 calls the lift, switches its own global **off** 1 ms later and the far
button's global **on** three seconds later. So the lift can only ever be called
from the end it is not at.

Neither multisource has a registerable input, so both take this tree's permissive
path (`ms_active = 1`, HL parity for `m_iTotal == 0`) — which meant that before
this patch **all four buttons were permanently live and the interlock did
nothing**. Nothing soft-locks now, either: the managers own the toggles, so the
puzzle drives itself.

Every gated map in the Sven set was read for soft-lock risk before shipping this,
because a faithful gate that nothing can open is a wall:

| map | shape | verdict |
|---|---|---|
| hl_c13_a2 | 4 env_globals (`triggermode 3`, no Set-initial) fired by multi_managers, gating 4 status multisources | fine — nothing masters those gates |
| th_ep2_01 / _03 | `trk_lit_global` gates `cryptmaster`, which masters a trigger_once | a real gate that now works, and the truck's multi_manager opens it |
| svencoop2 | `sc2newglobal` is defined on **svencoop1** | shut on a fresh svencoop2, open if you came from svencoop1 — the cross-map case, working as intended |
| hl_c10 | one env_global writes `c2a4e_alarms`, one trigger_auto reads it | the auto is suppressed at map start, which is right: the global is meant to arrive from an earlier map |
| sandstone | two env_globals **both named** `playercount_is_high`, both Set-initial, initialstates 0 and 1 | first to spawn defines the row and the second no-ops — HL's `EntityInTable` guard, and the reason the self-test asserts Add is idempotent |

One knock-on worth noting: sandstone's `playercount_low` is fired by a
`game_player_counter`, which is **still unimplemented** (it is on PATCH 156's
beyond-`hl_` list). That was harmless before and is now load-bearing on that one
map — the global cannot flip until the class exists.

### Corrections to PATCH 156's key table

Two of the six "implementable now" rows were wrong, and re-measuring says so:

- **`useType` — the source is right but the count was not.** It is not an SDK key
  at all (zero `FStrEq(..., "useType")` in the SDK); the ×43 hits were the C++
  `USE_TYPE` enum. The real key is Sven's **`use_type`**, FGD line 2174. Across
  the corpus the two spellings total **1,108 placements and exactly 2 are
  non-default** — a pair of `func_button`s on hl_c13_a2 at `use_type 1`. The 24
  `momentary_rot_button`s at `2` are at *their* default, which is 2 (FGD:3806),
  not 3. PATCH 156's "2 real of 42" reproduces exactly on a corpus 26× larger.
  Left alone deliberately: 2 placements against 914 default `func_button`s is the
  wrong risk trade for this patch, not a lack of source.
- **`WaveHeight` is not implementable here.** HL stores it as
  `pev->scale = value/8` (`doors.cpp:238`, and `world.cpp:685` for the worldspawn
  default, which also sets `sv_wateramp`) and the **renderer** draws the surface
  warp from it. FTE has no equivalent — zero hits for `wateramp` or `WaveHeight`
  anywhere in the engine — so honouring the key needs an engine feature that does
  not exist, not QC. Same standing as `SF_SHAKE_DISRUPT`. The key is captured on
  `.WaveHeight` and inert, which is now stated rather than implied.

### Not done

- `teleport_cooldown` (256 placements, 109 non-default). Real and sourced, but
  this tree's `trigger_teleport` is **client-predicted** — the snap happens in
  `PM_CheckTeleportTriggers` inside shared pmove — so a cooldown has to exist
  identically on both sides or prediction fights the server. That is a pmove
  change, not a keyvalue.
- `changetarget` / `changedelay` (22 / 16 real). Fully sourced and now cheap in
  principle: `CFireAndDie` carries `FCAP_FORCE_TRANSITION` and fires **on the
  destination map** after the delay (`triggers.cpp:1306-1334`, `:1503-1516`), so
  with `PR_Deinit` in the picture it needs the same file treatment the global
  table just got.
- `m_iAffected` on `player_weaponstrip` (3). FGD-documented and trivial in
  isolation, but this tree's `player_weaponstrip` deliberately diverges already —
  presence in the map activates it for **every** player forever, documented as a
  choice at `sv_player_weaponstrip.qc:73-77`. Sven's default is "activator only".
  Adding the enum means reopening that decision first, which is a behaviour
  question, not a key.
- `m_flDelayBeforeReset` (6), `m_iOpenFlags` (3). In the FGD with values but no
  prose: "Delay Before Reset" on a trigger_relay reads equally well as a re-arm
  after `Remove On fire` or as a fire cooldown, and nothing on disk decides it.
  Same standing as `pendistance` and friends until someone finds a source.

### Verified

- **Three VMs, 0 warnings each**, repacked.
- **`sv_globalstate_selftest`**: stage 1 (table contract — absent reads OFF, absent
  gate shut, unset key passes, add idempotent, DEAD is not ON, SetState on an
  absent name inserts nothing) **BAD=0**; stage 2 (the file round trip, which is
  what a changelevel actually does) **BAD=0**.
- **The cross-map carry, over a real changelevel**: crystal's four env_globals
  defined, then on hl_c06 `loaded 4 entries from cfg/globalstate.txt` and all four
  rows dumped `(from crystal)`. Then again on a **cold server** with only the file
  present, which is the case that matters for a campaign resumed later.
- **`initialstate` honoured**: crystal's `button1_state`/`button3_state` come up
  ON and `button2_state`/`button4_state` off, matching the entity lump.
- **The write path**: `env_global_use` in toggle mode drove
  `button1_state 1 -> 0` through the debug fire hook.
- **hl_c07_a2**: `[trigger_auto] -> "bay1screen" suppressed: globalstate
  "c2a2bay1screen" is 0, not ON`, both screens, 0 QC errors.
- **All 10 Sven maps that carry a `globalstate` key**, booted back to back
  against one shared file so the accumulating case is exercised: crystal, hl_c06,
  hl_c07_a2, hl_c10, hl_c13_a2, sandstone, svencoop1, svencoop2, th_ep2_01,
  th_ep2_03 — **0 QC errors and 0 failed assertions on every one**. The four
  `no spawn function` lines are pre-existing non-`hl_` classnames already listed
  in PATCH 156 (`trigger_random_unique`, `game_player_counter`, three
  `monster_*_dead`/`_repel` variants).
- **The sweep's end state is the proof it accumulates.** Ten maps in, the table
  holds six rows from three different maps:

  ```
  button2_state=0 crystal      button1_state=1 crystal
  button3_state=1 crystal      button4_state=0 crystal
  playercount_is_high=0 sandstone
  truck_gone_global=0 th_ep2_01
  ```

  Note the last row's provenance: th_ep2_03 ran **after** th_ep2_01 and carries
  its own env_global for the same name, and the row still says `th_ep2_01`. That
  is `EntityInTable` (buttons.cpp:92) doing its job — re-entering a map does not
  reset a global the player already changed. The same sweep before the clear fix
  ended with **one** row.
- **`regress.sh`**: 36 schedules / 168-384 tasks, squad / sqmon / cover all
  `BAD=0`, errors 0, **crashaddr 2313 → 2313**.
- **Audits at baseline**: `cvar_audit` 12 findings, `optional_audit` PASS (332
  files, up from 331 for the new file), `check_serverfire` 33/67.
- **Credential scan: 0** across the whole diff plus the new file.

### Three bugs the testing found in the testing's own subject

All three were invisible to "does it work" and visible to "print the number":

1. **The clear did not re-arm the loader, and it ate campaign state.**
   `GlobalState_MapStart` empties the table at worldspawn, but `gst_loaded`
   stayed 1 — so nothing re-read the file, and the map's first `env_global` wrote
   its single row over everything accumulated so far. Caught by the sweep, which
   showed sandstone going `4 entries (from crystal)` → `+ playercount_is_high` →
   **`1 entry`**, and then every map after it inheriting the wreckage. The
   invariant now stated in code: **an empty table is an unloaded table**, so
   `GlobalState_Clear` re-arms the hydrate itself and nothing can clear without
   it. This is exactly the class of bug a one-map test cannot see, and the reason
   the sweep runs the maps *sequentially against one shared file*.
2. **The scratch row leaked to disk.** `before = gst_count` was captured *ahead
   of* the lazy hydrate, so it read 0 while the table filled to 5, the rollback's
   `gst_count == before + 1` guard silently failed, and `__gst_selftest=2` shipped
   into `cfg/globalstate.txt`.
3. **The map dump lied.** `GlobalState_Dump` reads `gst_count` straight, so on a
   map with no env_global and no gate fired yet it reported an empty table while
   the file held the campaign's state — which reads exactly like "the carry
   broke". `GlobalState_Report` now hydrates first.

A fourth thing worth remembering, which cost a detour: `grep "loaded .* entries"`
misses `loaded 1 entry`. My own pluralisation hid a working load and sent me
looking for a filesystem problem that did not exist.

### Owed in-game checks (this patch)

1. **crystal's four button globals still drive their four multisources.** This is
   the one map in the Sven set where env_global and multisource are wired to each
   other, so it is the direct test of the gate.
2. **hl_c07_a2's two bay screens start UNPRESSED** and respond to `+use`. They
   used to be pressed for you at map load.
3. **A campaign carries state across a changelevel** — play c1a4d then c1a4b/c1a4i,
   or svencoop1 then svencoop2, and the far side should behave as though the
   near side happened.
4. **Nothing on hl_c06 got quieter.** Its `p_ms2` is now permanently shut; it
   masters nothing, so this should be invisible.

---

## PATCH 156 — the hl_ audit re-run: the entity gap is closed, and what was left was a stub, an explosion and a wrapped byte

A re-measurement of PATCH 151's audit against the current tree, then the three
real gaps it turned up. **The headline is that the classname gap is gone**: all
36 Sven `hl_*` maps now boot with **0 `no spawn function` reports and 0 QC
errors**, and a static census of all 141 Sven maps finds **zero** missing
classnames on any `hl_` map. Every Tier 1-4 item PATCH 151 listed as outstanding
has since landed, including `monster_nihilanth` and `monster_flyer_flock`.

What was left was not a missing classname, which is exactly why it needed
looking for a second time.

### env_shake was a stub, and a stub counts as implemented

`env_shake` existed as `{ self.use = GoldSrc_UnknownRelay_Use; }` — it forwarded
its trigger and did nothing. **184 placements across 28 of the 36 maps**
(hl_c12 ×25, hl_c06 ×19, hl_c05_a2 ×18), and it never appeared on any gap list
because presence-based auditing cannot see a stub. This is the same lesson
`env_shooter` taught in PATCH 131, in the same file, six classnames further down.

There was no shake channel at all, so this is new machinery in both VMs:

- **`server/sv_screenshake.qc`** — `UTIL_ScreenShake` (util.cpp:674) and `CShake`
  (effects.cpp:1835). Keeps HL's two real behaviours: only players **ON THE
  GROUND** are shaken, and the radius is a **hard edge, not a falloff** — the SDK
  removed the falloff and left the dead code at util.cpp:700 to show it.
- **`client/cl_screenshake.qc`** — `V_CalcShake` / `V_ApplyShake`. This half is in
  the GoldSrc **engine**, not the SDK, so it is reimplemented against the
  documented algorithm and hangs off the existing modifier stack in
  `CSQC_UpdateViewAliveCamera`. Roll only, as `V_ApplyShake` does.
- **`CSQC_EVENT_SCREENSHAKE` (62)**, unicast per player because the sender tests
  each player individually.

**HL's fixed-point ceiling is reproduced deliberately.** `FixedUnsigned16` clamps
at 0xFFFF, so Half-Life cannot express an amplitude above **15.99976** — and the
SDK asks for more in real code (`mortar.cpp:280` and `bullsquid.cpp:650` both
pass 25). That clamp is what a Half-Life player actually feels, so the quantiser
reproduces it rather than quietly shipping a harder shake. Quantisation happens
server-side and the result travels as a float, because QC's `WriteShort` is
signed and an ordinary amplitude of 12 encodes to 49152.

**All five SDK call sites are wired**, not just the entity:

| site | amplitude / freq / duration / radius | |
|---|---|---|
| `monster_mortar` impact | 25 / 150 / 1.0 / 750 | mortar.cpp:280 — **the carried TODO** |
| gargantua stomp | 12 / 100 / 2.0 / 1000 | gargantua.cpp:483 |
| gargantua footfall | 4 / 3 / 1.0 / 750 | gargantua.cpp:1008 — the arrival warning |
| bullsquid throw | 25 / 1.5 / 0.7 / **2** | bullsquid.cpp:650 — radius 2 = "only the victim" |
| egon beam | 5 / 150 / 0.75 / 250 | egon.cpp:379, at the **endpoint**, own 1.5 s throttle |

The mortar one closes the note at `sv_hl_entities.qc:262`, which deferred it
explicitly: *"left out rather than faked so the gap stays in one place and gets
fixed once."*

### Nothing on a Sven map exploded when you broke it

`func_breakable`'s `explodemagnitude` was declared in `sv_func_pushable.qc` and
**read nowhere**, and `sv_breakable.qc` had no `RadiusDamage` call on break at
any point. Its `.explosion` field is unrelated — that is the *gib throw mode*
(0 random / 1 directional), not HL's explode flag.

**15 brushes across 5 maps** ask to detonate and none did: hl_c07_a1's six 75s,
hl_c07_a2's **2000** plus two 200s and a 100, hl_c11_a5's 200, hl_c05_a1's three
110s. Now wired through a new `ExplosionCreate` (explode.cpp:258) in
`sv_env_explosion.qc`, which spawns the same `env_explosion` a mapper would place
— so a breakable's blast and a mapper's explosion cannot drift apart. Ordering is
the SDK's: `solid = SOLID_NOT` → targets → spawn object → **explosion last**, so
the blast is not blocked by the brush that made it.

**`ExplodeDamage` is deliberately NOT implemented.** hl_c05_a1's three breakables
set it, but it appears in **no FGD, no Sven manual page and nowhere in the HL
SDK** — Sven ignores it too, so honouring it would be a divergence *away* from
the reference. Recorded at `sv_customdefs.qc` so nobody chases it again.

### A wrapped byte that muted breakable effects for one player

`sv_breakable.qc` shipped `exclude = num_for_edict(self.dmg_inflictor)` as a
**byte** at four multicast sites. The exclude is meant to name the player whose
CSQC already predicted the effect — but `.dmg_inflictor` is whatever dealt the
damage, which on a GoldSrc map is routinely a world entity. hl_c12's `env_laser`s
sit at edicts **456-593**, and `WriteByte` **wraps rather than clamps**:

```
Write*: value 526 is outside of the required 0 to 255 range, truncating to 14
  sv_breakable.qc:409 BreakablePlayImpactSound  <- sv_env_laser.qc:97
```

526 went out as **14**, and the client tests `bi_exclude != player_localentnum` —
so whichever player held edict 14 silently lost breakable impact sounds. Fixed by
`BreakableExcludeEntnum()`, which returns 0 unless the inflictor is
`FL_CLIENT`: a world entity never predicts anything, so naming one was wrong on
its own terms as well as too large for the byte. **The other seven exclude
writers were audited and are all player-sourced**, so this was contained.

### Keys: what is real, and what PATCH 151 over-counted

Every key the 36 maps set was re-classified against the tree, through the real
resolution order (declared field → `ED_ParseUnknownEpair` skips →
`GoldSrc_TryCaseFoldedField` → prefix discards → mm_slot capture). **Several of
PATCH 151's outstanding keys are not gaps at all** — every corpus value is the
FGD default:

| key | uses | verdict |
|---|---|---|
| `physdamagescale` | 95 | **not a gap** — all 95 are `"1.0"`, the no-op default |
| `newspeed` | 310 | **not a gap** — all 310 are `-1`, the "no change" sentinel (already documented) |
| `healthvalue` | 117 | **not a gap** — all `0` |
| `gibdir` / `spawnorigin` | 51 / 125 | **not a gap** — all `0 0 0` |
| `linearmin` | 1582 | **not a gap** — all `2`, and the FGD confirms 2 is the default |

Four more that PATCH 151 listed have since been implemented: `attackrange`,
`new_skin`, `spriteflash`, `firespread` all bind now.

**Genuinely outstanding, with the defaults excluded.** Split by whether anything
authoritative actually describes them, because that decides whether the next
person can implement or must first go find a source — each was checked against
the Sven FGD, the shipped `svencoop/manual`, and the HL SDK:

**Has a source — implementable now:**

| key | real uses | entity | source |
|---|---|---|---|
| `globalstate` | 16 | env_global / multisource / trigger_auto | HL `globals.cpp` + Sven docs |
| `useType` | 2 (40 of 42 are `"3"`) | func_button | SDK ×43, Sven docs ×45 |
| `teleport_cooldown` | 18 (63 of 81 are the `"1"` default) | trigger_teleport | Sven FGD |
| `WaveHeight` | 4 (13 of 17 are the `3.2` default) | func_water | SDK + FGD |
| `changetarget` / `changedelay` | 3 / 2 | trigger_changelevel | SDK |
| `m_flDelayBeforeReset`, `m_iOpenFlags`, `m_iAffected` | 6 / 3 / 3 | assorted | Sven docs |

**Superseded in PATCH 157.** `globalstate` is done. Two of the rows above are
wrong and are corrected there: `useType` is not an SDK key (the real spelling is
Sven's `use_type`, and the ×43 hits were the C++ `USE_TYPE` enum), and
`WaveHeight` is a **renderer** value FTE has no equivalent for, so it is not
implementable in QC at all. The counts here are hl_-only; PATCH 157 has the
whole-corpus figures.

**No source found anywhere — needs research before code, do NOT guess:**

| key | uses | entity |
|---|---|---|
| `pendistance` | 45 | func_pendulum |
| `startdirection` | 9 | momentary_rot_button |
| `damagecap` | 7 | trigger_hurt |
| `StartDisabled` | 6 real (27 spawnflag-redundant) | trigger_once/multiple |

Zero hits in the FGD, zero in the manual, zero in the SDK. Same standing as
`ExplodeDamage` above and as fallguys' `env_studiomodel` — the honest answer is
that we do not know what they do, and inventing a meaning is how you diverge from
the reference while believing you are matching it.

PATCH 151's "6 real `StartDisabled`" reproduces **exactly**, which is a good sign
for that audit's method.

### Beyond the hl_ set

The other 105 Sven maps carry 109 unimplemented classnames / 4,602 placements,
but it is lopsided: `fallguys_s2`/`s3` alone are ~3,000 of them with a bespoke
entity set (`env_studiomodel` ×1900, `func_barrier` ×397) that has **no FGD, no
wiki page and no SDK behind it** — deliberately out of scope rather than guessed
at. The cross-map ones worth a future pass: `trigger_numericdisplay` (156 / 7
maps), `trigger_random_unique` (127 / 13), `item_inventory` (116 / 11),
`trigger_change_class` (34 / 10), `func_clip` (24 / 10), `trigger_renameplayer`
(20 / 9).

### Verified

- **Three VMs, 0 warnings each**, repacked.
- **Shake, end to end**: server `[shaketest] player Player at -109 1488 -1452`,
  client `[shake] amp 12 dur 2 freq 225` — exact values across the wire.
  Quantiser asserted in-test: `amp 12 -> 12`, `freq 225 -> 225` `BAD=0`, and the
  ceiling `amp 25 -> 15.9998` `BAD=0`.
- **The ONGROUND gate**, proven separately by the selection counters:
  `-> 0/2 shaken (2 airborne, 0 out of range)`, and a bot on the same server
  reporting `ground=1`.
- **Detonation**: `[breakable] "blast_tnt_launch" detonating, magnitude 2000 at
  2592 948 460` on hl_c07_a2, 0 new errors.
- **36-map sweep**: 0 unhandled classnames, 0 QC errors, and the hl_c12
  `Write*: value ... outside of the required 0 to 255 range` warnings **gone**.

### A harness limit worth knowing

**No headless player is both grounded and unicast-reachable.** The `hlclient.sh`
client spawns with a real origin and `health 100` but sends no movement input, so
the server never runs player physics for it and `FL_ONGROUND` is never set —
measured across four maps. Bots *are* grounded but have no netchan. Any feature
gated on a grounded player therefore looks completely dead in the harness while
being perfectly correct; it cost four round trips here before the counters made
it visible. `SV_ShakeSelfTest` deliberately bypasses the gate and says so, and
the gate is covered by the counters instead.

### Not done

- The outstanding keys in the two tables above. The six with a source are known
  quantities; `globalstate` is the largest of them, being HL's cross-map global
  state machine rather than a single key. The four without a source need someone
  to find one first.
- `fallguys_s2`/`s3`'s custom entity set, for want of any documentation.
- HL's `SF_SHAKE_DISRUPT` and `SF_SHAKE_INAIR` spawnflags are **intentionally**
  unimplemented: the SDK marks them "UNDONE: These don't work yet" and they do
  nothing in Half-Life either.

### Owed in-game checks (this patch)

1. **A mortar barrage shakes the screen.** `func_mortar_field` on hl_c07_a1 /
   hl_c11_a5. This is the one the old comment promised.
2. **The gargantua's footsteps shake the ground before you see it.** hl_c14.
   Low amplitude, very low frequency — a tremor, not a rattle.
3. **hl_c07_a2's TNT actually detonates**, with blast damage, rather than
   silently vanishing. The 2000-magnitude one is a set piece.
4. **A shake felt while airborne does not occur** — jump as one fires and it
   should skip you. That is HL behaviour, not a bug.
5. **Breakable impact sounds still play** for every player on hl_c12, where the
   `env_laser`s are the inflictor.

---

## PATCH 155 — reverse animation playback: an engine change, because it was an engine limit

PATCH 154 shipped the tentacle with a documented divergence: its node-graph walk
took **forward edges only**, cutting on the five transitions Half-Life plays
backwards. The reason given was that the server had no way to say "backwards".
That was true, and it is no longer.

**The renderer never needed anything.** `HL_SetupBones` (`gl/gl_hlmdl.c:1024`) is
a pure function of `frametime` — `frame1 = (int)(frametime * sequence->timing)`,
lerp to `frame1+1`, wrap or clamp — with no accumulator and no assumption that
time moves forwards. The only guard is `if (frametime < 0) frametime = 0` at
`:1066`, which is exactly where a reverse play ends anyway. A decreasing
frametime always played a sequence backwards, correctly interpolated. Nothing
could produce one.

The gap was one number on the wire. `CL_LerpNetFrameState` (`client/cl_ents.c`)
hardcoded `frametime[0] = cl.servertime - newframestarttime`, and
`newframestarttime` is stamped **client-side** whenever `.frame` changes. Rate
exactly 1, phase always from zero, and no field in `entity_state_t` to say
otherwise.

### The extension

`PEXT2_FRAMERATE` (0x2000), riding in the existing `UF_BONEDATA` payload under
flag bit `0x08` — the third rider after `PEXT2_BONECONTROLS` (Patch 125) and
`PEXT2_BODYGROUP` (Patch 131), and built to their shape deliberately. The strict
parser mask drops from `0x0f` to `0x07` to match.

The SSQC/CSQC field is **`.animrate`**, not `.framerate`, and that is not a
style choice. `.float framerate` is already declared four times in this tree
(`sh_hlbeamfx.qc`, `sv_cycler_sprite.qc`, `sv_env_beam.qc`,
`sh_wpn_hltripmine.qc`) as a **mapper key** — `cycler_sprite` sets 10,
`env_sprite` sets 15. QC has one namespace, so an engine field of that name would
bind the key to it and silently run every one of those entities at its own key
value as an animation multiplier. `sv_env_sprite.qc:223` states the old
assumption in as many words: *"`.framerate` is a mod-declared field, invisible to
the engine."* This keeps it true.

Wire encoding is a signed short at 1/64, **biased by 1.0** so that normal speed
encodes as zero. Baselines are memset to zero and almost nothing sets a rate, so
the field is a permanent delta miss without the bias and free with it.

Two things had to move to make room:

- **`framestate_t` gained `seqtime`** — raw wall-clock since the sequence
  changed. Patch 130's cross-fade read `frametime[0]` as that number, which was
  true only while the rate was fixed at 1. A reversed sequence *starts* at
  `frametime == duration`, so the fade weight would exceed 1 on its first frame
  and every reversed transition would snap — the exact artefact this patch
  exists to remove. Set at every `Get_FrameState` implementation
  (`pr_cmds.c`, `pr_csqc.c`, `pr_menu.c`, `pr_lua.c`, `pr_q1qvm.c`), because
  those fill the struct field-by-field and their callers keep a `framestate_t`
  on the **stack** — an unwritten new member is garbage, not zero.
- **Phase bookkeeping in `lerpents_t`** (`animphase`/`animphasetime`), so a rate
  change *mid-sequence* is continuous instead of teleporting the pose. The
  tentacle needs this: it sweeps faster the more recently it heard you.

### What it fixed beyond the five cuts

`pev->framerate` carries magnitude, not just sign, and all three of the
tentacle's uses were missing too — a ±0.2 per-transition jitter so a row of them
never beats in lockstep, 1.5× while a noise is under 2 s old, and a linear ramp
back to 1.0 over the next 3 s. Two other places in this tree had already written
this limit down as unfixable without an engine change and are now unblocked:
`sv_ai_core.qc:206-213` (Barney's `pev->framerate = 1.5`, his 0.84 s shootgun
against Half-Life's 0.56 s) and `sv_xen_flora.qc:207-209`.

`Tent_NextSeq` is now HL's `FindTransition` in full, including the detail that
the current sequence's **entry** node is the relevant end when it is playing
backwards, and that the forward and reversed tests sit in the *same* loop
iteration — the winner is whichever matches at the lower sequence index, not
"forward first".

### Verification

Three QC VMs and both engine targets at **0 warnings**.

- `[tentacletest] 53 seqs, 14/14 nodes fwd-reachable, 12 reversible links, 1259
  reversed routes, BAD=0` — every ordered pair of the 53 sequences is walked at
  boot, and the three descents Patch 154 had to cut (`Lev2→Lev1`, `Lev3→Lev2`,
  `Lev1→pit`) are asserted individually to come back with direction −1.
  `cuts=0` on every map now means what it says.
- **End to end, engine to engine**, which is the only claim that matters and the
  only one the server cannot make alone:
  `[sv animrate] ent 203: qc -1 -> wire -128` on the server and
  `[animrate] ent 203: REVERSE -1` on the client, under `hlclient.sh`.
  Live tentacles in the same run: server `qc 1.35996 -> wire 23` / `1.34781 -> 22`
  / `1.54767 -> 35` (three distinct rates, no lockstep), client
  `rate 0.84375 → 0.953125 → 1.1875 → 1.07812` as the agitation ramp decays.
- Negotiation confirmed: client reports `pext2 = 0x387F`, which carries `0x2000`.
- All five Tier 4 maps `BAD=0`, 0 QC errors. `regress.sh` 36 schedules /
  168-384 tasks / squad / sqmon / cover all `BAD=0`. `selftests.sh` `BAD=0`.
  **crashaddr 1973 → 1973.** Audits at baseline (cvar 12, optional 329/0,
  serverfire 33/67).

Two new diagnostics, `sv_debug_animrate` and `cl_debug_animrate`, both default
off and throttled to one line per second. They have their **own** cvars rather
than riding on `developer` for a measured reason: `cfg/default.cfg` sets
`developer 0` and execs during init, *after* every `+set` on the command line, so
a developer-gated print is invisible to exactly the harness that needs to read
it. Two runs were spent concluding the feature was broken when only the print was
off. `hlclient.sh` gained a `CLARGS` env var, since its positional args go to the
server only.

### Owed in-game checks

Everything here is a rendering claim, so the harness cannot close it:

- A tentacle **descending** — Lev2→Lev1 or Lev3→Lev2 — should now run the link
  smoothly backwards rather than snapping to the lower pose.
- Un-rearing and un-rotating, same thing.
- The agitation ramp: a tentacle should visibly speed up in the two seconds after
  it hears you and ease back over the next three.
- Three tentacles in one silo should not sweep in lockstep.
- The cross-fade should still be smooth *into* a reversed sequence (this is what
  `seqtime` is for; the failure mode would be a snap).

### Not done

- **`.animrate` is not applied to the server's own hitbox posing.**
  `pr_cmds.c:634` poses a model from `.frame1time`, which QC drives by hand; the
  rate is not folded in, so a `MOVE_HITMODEL` trace against a reversed sequence
  uses whatever `.frame1time` says rather than what the client is drawing. No
  monster in this tree currently reverses *and* relies on hitbox tracing — the
  tentacle does radius damage — but it is a real divergence and it is written
  down rather than discovered later.
- **A sign flip mid-sequence would pop.** The phase rebasing is exact for any
  rate change that keeps its sign; reversing direction without also changing
  sequence would need the duration at rebase time, which the parse path does not
  have. Half-Life always sets sequence and direction together
  (`tentacle.cpp:649-663`), so the case does not arise.
- **Barney's 1.5× firing speed-up and the Xen flora drift are still not wired
  up.** The blocker named in both files is gone, but changing either is a
  behaviour change with its own testing, not a free rider on this patch.

---

## PATCH 154 — Tier 4: the last three classnames in the hl_ campaign

**The Sven `hl_*` campaign now has a spawn function for every entity it places.**
Booting all 36 maps headless and harvesting the engine's own
`[goldsrc-compat] no spawn function for X` report returns nothing, and a static
parse of all 30,742 entities across those maps agrees: 188 distinct classnames,
188 implemented.

Before this patch, three were missing:

| classname | ents | maps |
|---|---|---|
| `monster_tentacle` | 8 | hl_c05_a2 (3), hl_c11_a1 (1), hl_c16_a2 (4) |
| `monster_flyer_flock` | 3 | hl_c18 |
| `monster_nihilanth` | 1 | hl_c17 |

Two of those maps were **unfinishable**: Blast Pit's middle act is three tentacles
you have to get past, and hl_c17's entire ending chain hangs off names the
Nihilanth fires.

All three are ported from the SDK as **self-driving entities**, not as schedule
monsters. Half-Life writes them that way too — `CTentacle` overrides
`GetIdealState` to return IDLE unconditionally and `CanPlaySequence` to return
TRUE unconditionally, which switches off the two things `CBaseMonster` exists to
do — and reproducing them on top of this tree's schedule layer would mean fighting
`AI_SetActivity` for ownership of `.frame` every tick. They borrow three pieces of
the AI layer and nothing else: `AI_ApplySequence`, `AI_AnimPump`, and the
`.ai_damagefilter` hook added in PATCH 153.

### monster_tentacle

Driven entirely by **hearing** — it is blind, and which level it climbs to, which
way it faces and whether it strikes, taps or rears all come out of one heard
noise. This tree's noise producers (`AI_HeardNoise` / `AI_HeardGunfire` /
`AI_DangerSound`) push straight onto `monster_chain_head` and keep nothing, and
each walk is gated on `m.think == AI_Think` — which excludes this class by
construction. So `sv_ai_core.qc` now records the most recent world noise in a
one-slot CSoundEnt equivalent (`ai_worldsnd_pos/_radius/_time`) that the tentacle
polls. One slot, because `PBestSound()` returns one sound and the tentacle uses
nothing else.

The pose ladder is the model's own **node graph**, parsed out of `tentacle2.mdl`
rather than transcribed: 53 sequences, entry/exit node and nodeflags each, plus
the 14×14 transition matrix. Checked byte-for-byte identical across all four
copies on this machine (valve, gearbox, bshift, svencoop) — Sven's is ten times
the size only because of geometry and textures.

**The one real divergence: forward-only playback.** ⚠️ **SUPERSEDED BY PATCH 155
— this section is kept for the record and its conclusion is now wrong.** The
limit was real, but the proposed fix below ("draw the tentacle from CSQC") was
the wrong shape: the renderer could already play backwards, and what was actually
missing was one networked field. See PATCH 155. `FindTransition` returns a
sequence *and a direction*, and a −1 means "play this link backwards"
(`pev->frame = 255`, `pev->framerate = -1`). This engine cannot do that from the
server: a networked HL model plays at the model's own fps from whenever `.frame`
last changed — the client stamps `newframestarttime` and derives `frame1time` from
it (`client/pr_csqc.c:5543`) — and nothing in `entity_state_t` carries a rate or a
direction. `.frame1time` *is* an SSQC field but the server uses it only for its own
hitbox posing (`server/pr_cmds.c:634`); it is never transmitted.

So the graph walk takes forward edges only, and where HL would reverse a link this
cuts to the goal. That is exactly five transitions: Lev2→Lev1, Lev3→Lev2,
Lev*n*→pit, un-rear and un-rotate. Every ascent, strike, tap, fidget, rear and the
whole engine-death sequence are exact — including Lev1→Floor, which has its own
forward link (`Temp1_to_Floor`) rather than reversing `Floor_to_Lev1`. A
`cuts=` counter in the self-test keeps that measurable rather than folklore.
Fixing it properly means drawing the tentacle from CSQC with `frame1time` driven
per frame — a separate and much larger patch.

**Touch damage** lands on the `bang` animation event in a radius around the
computed impact point, at `m_iHitDmg`, rather than through collision. HL reads
`tr.iHitgroup` off the global trace and can only do that because
`SetObjectCollisionBox` inflates `absmin/absmax` to ±400 × 850 while `pev->size`
stays 64 units at the base. FTE reports no hitgroup for a touch, and a `setsize`
to the full 800×800×850 would make the tentacle a solid block players cannot walk
under. Same numbers, same instants, applied by proximity.

**The `sound` map key cannot be a field.** `sound` is builtin #8 and QuakeC puts
fields and functions in one namespace, so `.float sound;` does not shadow the
builtin — it makes every `sound()` call in the tree a compile error. Exactly the
`ammo_357` collision, and with no `spawnfunc_`-style escape for a *key*. It is
harvested in `ED_ParseUnknownEpair` into `.string hl_soundkey` (a string, because
the corpus disagrees about the type: 8 uses on `monster_tentacle` are the integer
impact-material selector, 37 on Sven's `trigger_qualifier` / `trigger_hudsprite`
are `.ogg` paths).

### monster_flyer_flock

Leader plus followers. The leader flies forward, feels its way around obstacles
with three parallel forward traces, and turns toward whichever side has more room;
followers copy its heading, chase or hang back to hold station, and shove each
other apart when they crowd. `pev->framerate` drives the wing flap in HL and is
not reachable here (and `boid.mdl` carries exactly one sequence, `idle` — checked,
not assumed), but the lean and bank ride `.avelocity`, which is real, so they
still bank into their turns.

### monster_nihilanth

The full fight. Twenty orbiting energy spheres that double as a second health bar;
a three-crystal recharger ladder that heals him and escalates a level counter; zap
and teleport attacks; friend-summoning off the map's own `info_node_air` /
`info_node` entities; and the head-crack death sequence that fires `n_dead` and
sends the player to the credits.

`nihilanth_energy_ball` is one classname with six behaviours — orbit, zap,
teleport, green ball, absorb, dissipate — kept as one class because that is how
the SDK writes it.

**The kill gate is exact rather than approximated.** He is immortal unless the
killing blow lands on his open head. HL does that with `iHitgroup == 2` in
`TraceAttack` latching `m_irritation = 3`, consumed and cleared by `TakeDamage`.
This tree *does* have hitgroups — `.death_hitgroup` is stamped by every hitscan
path and by the client hit-claim path (`sv_player.qc:4108`) before
`W_ApplyDamage` runs, and `.ai_damagefilter` runs inside `W_ApplyDamage` early
enough to read it — so both halves fold into one filter with the same rule.

Approximated, and marked in the file header: `pev->framerate` (same engine limit
as the tentacle); `TE_ELIGHT`, the moving coloured light on every ball (no
dynamic-light temp entity is plumbed to CSQC here — the balls are additive
sprites); `DMG_SHOCK`, which has no bit in this tree
(`sh_weapon_standard.qc:633-638` is BULLET/CLUB/BLAST/SONIC/CRUSH/FALL and nothing
else, so the zap uses SONIC — the same call the Gonarch's `DMG_ACID` immunity
got); and the head sprite, moved by position each tick because nothing here
attaches a sprite to a studio attachment.

### Four bugs found before this shipped

- **The credits would have fired on the killing blow.** `W_ApplyDamage`
  (`sv_weapons.qc:2049`) calls `target.use()` on a death when the target has a
  `.use` and **no** `.on_killed` — and the Nihilanth's `.use` has a `USE_OFF` arm
  that shoves the player into `n_ending`. Fixed by giving him an `.on_killed`,
  which is the precedence that branch's own comment says is intended: `.on_killed`
  is the specific death handler, `.use` the generic activation one. It deliberately
  does not set `.deadflag`, because the gib path below it only runs for `DEAD_DEAD`
  and he must not come apart into gibs — he has his own five-second
  disintegration. (Found by reading, not by a test; the self-test passed either
  way, which is exactly why it is worth writing down.)
- **`DAMAGE_AIM` is not damageable in this tree.** `W_CanDamageTarget`
  (`sv_weapons.qc:1279`) rejects anything whose `.takedamage` is not exactly
  `DAMAGE_YES`, and every hitscan, pellet, melee, projectile and `trigger_hurt`
  path funnels through it. HL's `DAMAGE_AIM` means "damageable **and** an autoaim
  target", a distinction this tree does not draw — so both the tentacle and the
  Nihilanth were transcribed straight off the SDK as unshootable. Found by the
  Nihilanth self-test: a 9,999-damage hit left him on 800 health.
- **HL's `Vector::Normalize()` returns `(0,0,1)` for a zero vector; FTE's
  `normalize()` returns zero.** Everywhere else the two agree. That one case is
  load-bearing wherever SDK code normalises a velocity that can legitimately be
  zero, because zero-in/zero-out is an absorbing state: the flock spawns every
  bird at rest and then does `velocity = velocity.Normalize(); speed += 10;
  velocity = velocity * speed`, so a follower multiplies zero by a growing number
  forever and never moves. Measured at **8 of 9 boids flying**, varying run to run
  with which bird happened to be the leader. Now `HL_Normalize` in
  `sv_ai_move.qc`, named for what it is because the same pattern appears in the
  Nihilanth's orbit solver and will appear again.
- **A pass criterion that was wrong, not a monster that was.** The first tentacle
  self-test reported `BAD=1` on hl_c16_a2 because its fourth tentacle stayed in
  the pit. It is 3,700 units from the injected test noise — well outside the
  doubled 1024 radius — so staying put is correct. The assertion is now over the
  set actually in earshot, and out-of-earshot tentacles are marked `*` in the
  report.

### Verification

Three VMs, **0 warnings** each, deployed, stale-progs checks empty.

```
hl_c05_a2  [tentacletest] 53 sequences, 14/14 nodes reachable forward-only, BAD=0
           3 tentacle(s), 3/3 in earshot woke: 17/L1 18/L1 21/L1
           cuts=0 strikes=4 heard=3 dmg=800  BAD=0
hl_c11_a1  1 tentacle(s), 1/1 in earshot woke: 17/L1  dmg=800  BAD=0
hl_c16_a2  4 tentacle(s), 3/3 in earshot woke: 17/L1 21/L1 0/L-1* 13/L1  BAD=0
hl_c18     [flocktest] 9 boid(s) spawned=9 flying=9 linked=9 leaders=3 turns=3  BAD=0
hl_c17     [nihtest] seqs missing:[] recharger=3 draw=3 leaving=4 teleport=4
                     bounds=2/2 ending=2/2  BAD=0
           after a 9999 body hit: health=1        <- the immortality gate
           fired "n_draw1" -> 1                   <- the recharger ladder, on the real map
           moved=1 health=801 spheres=7 live=15 emitted=27 absorbed=20  BAD=0
           killgate: bodyshot survived=1 headshot killed=1 headhits=1  BAD=0
           dead at the ceiling: fired "n_dead" -> 2   <- the ending chain
```

The tentacle walk reads exactly like the SDK: with a noise injected at bearing 0°
and 400 units up, `tent3` picked `Lev1_Strike`, `tent2` at −117° picked `Lev1_Tap`
and `tent1` at 144° picked `Lev1_Rear_Idle` — routed through three forward node
hops (`Lev1_Rotate` → `Lev1_Rear` → `Lev1_Rear_Idle`). `dmg=800` is four
killing-swing impacts at HL's `m_iHitDmg` of 200.

`tentacle_die` on hl_c05_a2 resolves through the map's own `trigger_relay` chain
to `use 0 -> death` on all three — see the trigger_relay note below for why that
needed care.

Audits at baseline: `cvar_audit` 12, `optional_audit` 329 files / 0,
`check_serverfire` 33/67. Credential scan of every touched file: 0.

### Owed in-game checks

Nothing here renders headlessly:

- The tentacle's five cut transitions. They are a pose change instead of a reverse
  animation; the question is whether that reads as a jolt or goes unnoticed at the
  distances Blast Pit fights at.
- The boids actually looking like a flock — the spread, the bank, and whether the
  fake-block turn every ~6 s reads as natural or as a tic.
- The Nihilanth's twenty spheres forming a **ring** rather than a shell (the orbit
  solver zeroes z before the distance test, which is what should produce that),
  and the head sprite sitting on the head rather than lagging visibly at 10 Hz.
- The death sequence: beams from four attachments plus a green ball every tick for
  the whole climb to the ceiling.

### Not done

- **`teleport_cooldown`** — 770 uses / 53 maps, still the largest remaining key,
  still deferred because it lives in the client-predicted pmove path.
- **`trigger_relay` with no `triggerstate`.** Half-Life's `CTriggerRelay` leaves
  `m_triggerType` at 0 when the key is absent, so absent and an explicit `0` both
  mean **Off**. This tree's shared mapper (`GoldSrc_TriggerStateToUseType`,
  `sv_triggers.qc:287`) folds both onto `USE_TOGGLE` instead, on the grounds that a
  QC float cannot tell them apart and the Sven FGD's editor default is 2. Its
  comment also claims *"Nothing in the Sven map corpus authors an explicit
  `triggerstate 0`"* — **194 `trigger_relay`s do**, plus 2,096 across all classes.
  Measured blast radius: **1,335 corpus `trigger_relay`s omit the key**, and the
  resolvable ones target `env_beam` (121), `ambient_generic` (83), `env_sprite`
  (66), `squadmaker` (62), `func_door` (37), `func_train` (25) and
  `func_breakable` (25) — classes where Off and Toggle differ visibly. That is a
  corpus-wide behavioural change and wants its own patch and its own regression
  run, so it was **not** flipped here. `monster_tentacle` resolves its own use type
  by reading the raw `triggerstate` off `sub_use_caller`, which is exact for the
  one case that cannot tolerate the fold — hl_c05_a2 uses absent/1/2 to mean
  die/ping/thrash — and changes nothing outside that file.
- **`demon/dland2.wav` not precached**, seen on hl_c04 and hl_c16_a3 in the 36-map
  sweep. A Quake sound reaching a GoldSrc map; one line to find, unrelated to this
  work.

---

## PATCH 153 — Tier 3: the Gonarch gets somewhere to walk, and six "missing" keys turn out to be Half-Life 2's

`info_bigmomma`, plus the Tier 3 key gaps — which mostly resolved by measuring
rather than by writing code. See **The six keys that are not ours to implement**
below; that is the main finding of this patch and it removed more work than it
added.

### info_bigmomma — 22 nodes, all on hl_c15, and they are the level

`CInfoBM::Spawn` is an **empty function** (bigmomma.cpp:60). The class is pure
data; every behaviour lives on the monster. `monster_bigmomma` already existed
here, so the Gonarch was on hl_c15 with nowhere to go — she spawned, stood on her
spawn point, and could be killed at her map health of 300 with no stage gate and
none of the map's scripted beats.

The chain, read out of the BSP:

```
goose1 → goose1b → goose1c → goose2 → goose3 → goose4 → goose5 → goose5b →
goose5c → goose6 → goose7 → goose7b → goose8 → goose8b → goose9 → goose10 →
goose11 → goose11b → goose12 → goose13 → goose14 → end
```

Nine of those carry a `health` key, and that is what makes hl_c15 a staged chase
rather than a fight: she is **unkillable until the path is finished**, and each
health key is one stage the player has to shoot off before she moves on. Five
carry a `reachtarget` — `web1` (the wall she smashes), `c4a2_collapse`,
`falltodeath_mm`, `falltodeath2_mm`, `bm_yell`. All of that was inert.

**The chain is seeded from the monster's own `netname`** ("goose1" on hl_c15) —
Half-Life keeps the next node's name in `pev->netname` and overwrites it as she
walks. That collided with something real: `sv_monsters.qc:1104` translates a
monster's `netname` into `.squadname`, because Sven's FGD labels it "Squad Name"
on every other monster class. She was becoming a one-member squad called `goose1`.
Now excluded there, with the same shape of gate the `sq_maker` case already had.

### What it cost in the AI layer

Eight new task opcodes (43 → 50) and two schedules (35 → 37), transcribed from
`tlBigNode` / `tlNodeFail` (bigmomma.cpp:825-856). Eight opcodes for one monster
is a lot; the alternative was worse, because her boss fight **is** the node walk —
where she goes, when she stops, which wall she breaks, when the map may advance
and how much health she has at each stage are all `info_bigmomma` keys, so none of
it is expressible with the generic tasks.

Only the move was folded rather than transcribed. HL's single
`TASK_MOVE_TO_NODE_RANGE` both starts the walk and polls the distance; here
path-getting and walking are separate tasks by design, so `TASK_BM_PATH_NODE` does
the start half — **including picking walk or run from the node's own spawnflag**,
which is exactly why it cannot be `TASK_GET_PATH_*` plus a constant
`TASK_WALK_PATH` — and the ordinary `TASK_WAIT_FOR_MOVE` does the walking, with a
node-radius arrival test alongside the `moveto_radius` one that was already there.
16 of the 22 nodes set RUN, so the chase legs run and the set-piece legs stalk.

Also new: a `.ai_damagefilter` virtual — the pre-damage veto a class is allowed to
have. `.on_damaged` cannot serve, because it only fires *after* health is gone and
only while the target still has some, so nothing installed there can survive a
killing blow. Called from `W_ApplyDamage` above the clamp, forward-declared the
same way `Gib_ShouldGibOnDeath` already is.

### Two divergences from the SDK, both deliberate

- **`ShouldGoToNode` also tests "path finished"; HL has no such test.** Without it
  the last node loops: its `target` is empty, so `NodeStart` declares the path
  finished but leaves `m_hTargetEnt` on that same node, whose `NodeReach` sets the
  advance bit again. HL gets away with it because hl_c15's final node ends the map
  a moment later. We cannot — this schedule outranks the combat ladder, so the
  loop would leave a Gonarch who has finished her path standing at the last node
  re-facing it forever, in precisely the phase where the player is finally allowed
  to kill her.
- **`TASK_BM_FIND_NODE` fails rather than completes when the path just ended.** HL
  completes unconditionally and runs the remaining ten tasks against the finished
  node — including `TASK_PROCESS_NODE`, which fires its `reachtarget` a second
  time. Invisible on hl_c15 (the final node has no reachtarget), but not a
  behaviour to inherit just because one map does not notice.

### Three bugs the tests caught, not the reading

1. **`SCHED_BIGMOMMA_NODEFAIL` did not clear `COND_TASK_FAILED`.** HL's `tlNodeFail`
   does not either, but here the condition outranks the class virtual in
   `AI_SelectSchedule`, so she would have cycled through the two-task fail
   schedule for the rest of the map — never walking, never fighting, never
   retrying the leg. This is the exact failure `SCHED_FAIL`'s own comment records
   from the zombie histogram; the general rule of that table beat the
   transcription.
2. **`NodeReach` raised her health without reseating `.ai_lasthealth`.** `AI_Damaged`
   sizes every hit from `(ai_lasthealth - health)` because `W_ApplyDamage` does not
   pass the amount — so the first hit after every stage change computed as
   *negative*, clamped to zero and counted as "healed, not a hit": no pain sound,
   no `COND_DAMAGE`, no provoke. Nine stages, nine silent hits.
3. **`new_skin` forced skin 0 onto every spawned monster in the corpus** (see
   below).

### The Tier 3 keys

| key | corpus | verdict |
|---|---|---|
| `new_skin` | 565 / 9 maps | **done** — squadmaker only; 544 are the `-1` no-op, 21 real |
| `attackrange` | 202 / 31 maps | **done** — 186 write the 1200 default, 16 are real |
| `teleport_cooldown` | 770 / 53 maps | **deferred, with reason** |
| `StartDisabled` | 72 / 18 | not ours — Half-Life 2 |
| `physdamagescale` | 95 / 5 | not ours — Half-Life 2 (and all 95 are `1.0`) |
| `ExplodeDamage` | 12 / 7 | not ours — Half-Life 2 |
| `damagecap` | 7 / 1 | not ours — Half-Life 2 |
| `startdirection` | 9 / 7 | not ours — Half-Life 2 (and all 9 are `Forward`) |
| `pendistance` | 45 / 6 | not ours — in no FGD on disk; the real key is `distance` |

**`new_skin` is `new_body`'s sibling and was the only one of the pair missing.**
The first version used `>= 0` on the reasoning that skin 0 is a real skin while
bodygroup 0 is not. That is right about models and wrong about QC: an **absent**
key leaves the field at 0, so `>= 0` cannot tell "the mapper asked for skin 0"
from "the mapper said nothing" — and it forced skin 0 onto every child of every
maker in the corpus. The `[squadmaker]` diagnostic printed `skin=0` for
th_escape's cockroach spawners, which carry no `new_skin` key at all. `> 0` costs
nothing: no corpus entity writes `new_skin 0`.

**`attackrange` tunes a ranged attack, it does not grant one.** The override runs
last in `AI_ClassInit` — after everything we install, because a class default the
map explicitly disagreed with is not a default any more — but it is guarded on
`ai_range_range > 0`. `Grunt_BodyInit` two lines above zeroes that for
`HGRUNT_NOWEAPONS`, and a squadmaker setting both would otherwise hand a gun range
back to a grunt with no gun. The same guard covers the barnacle and the gargantua,
whose ranges are deliberately zero so the generic ladder can never offer them a
ranged schedule.

### The six keys that are not ours to implement

`StartDisabled`, `physdamagescale`, `ExplodeDamage`, `damagecap` and
`startdirection` are all in **`Half-Life 2/bin/base.fgd`** and in none of: the
Half-Life SDK, `sven-coop.fgd`, or any GoldSrc FGD on disk. They are in these BSPs
because mappers had the wrong FGD loaded in Hammer, and **Sven Co-op ignores them
too**. Implementing them would not close a gap — it would make this mod diverge
from the game it is matching. `pendistance` is the same shape without even an HL2
origin: `func_pendulum`'s real key is `distance` (1059 corpus uses, already
handled), and 42 of the 45 `pendistance` values are `90`, which *is* `distance`'s
default.

Two of them are self-evidently inert even on their own terms: all 95
`physdamagescale` values are `1.0`, and all 9 `startdirection` values are
`Forward`. Every one of those entities would behave identically implemented or
not.

### `teleport_cooldown` — deferred on purpose, and this is the reason

770 uses over 53 maps, the largest single key gap left, and it is a real Sven key
(sven-coop.fgd:3370, :6847). It is **not** a small job, because
**`PM_CheckTeleportTriggers` runs in shared pmove** (`sh_pmove.qc:4614`) — the
teleport is client-predicted, and both sides must agree or the player rubber-bands.

514 of the 770 are on `info_teleport_destination`, where the semantics are
*per-destination*: shared server state that no client can know. Adding a
server-side refusal without networking that clock means the client predicts a
teleport the server rejects. There is already a predictable per-player guard
(`pm_teleport_time`, 0.2 s) doing the job the key is usually reached for.

Half-implementing a behaviour in the predicted path is worse than not implementing
it, so this is written down rather than bodged. It is its own patch: one field on
`trigger_teleport_SendEntity`, a destination-side clock, and a client parity run.

### Verified

- Three VMs, **0 warnings** each, against the final source and deployed.
- `sv_bigmomma_selftest` on hl_c15: **22 nodes, 22 walked, 0 unreachable, BAD=0**.
  All five `reachtarget`s resolve; all six sequence names (`angry1/2/3`,
  `breakwall`, `claw`, `jump`) confirmed present on the shipped `big_mom.mdl`
  rather than assumed.
- **She actually walks.** hl_c15, 70 s, one bot, `sv_ai_sight 8192` to beat the
  dormancy gate: `heading for "goose1" … radius 64` → (9 s, its `reachdelay 8`) →
  `goose1b` → `playing reachsequence "claw"` → `fired "bm_yell" -> 1 entity(s)` →
  `goose1c` → `fired "bm_yell"` → **`holding at 200 health`**. That last line is
  the stage gate doing exactly its job with nobody shooting her.
- **The health gate, through `W_ApplyDamage` rather than by calling the filter**
  — the wiring is the risky half, and a filter that works perfectly but is never
  reached looks identical to one that was never installed. A 9999 hit on an
  unfinished path leaves exactly 1 health and sets the advance bit; a 50 hit on a
  finished path takes exactly 50. Runs on a spawned stand-in, before the map
  checks, so it is exercised on every map and never leaves a live boss at 1 HP.
- `attackrange`: ctf_warforts, **all six** miniturrets →
  `attackrange 1600 overrides class range 1200`.
- `new_skin`: th_escape, `slum_cop_spwn` → `monster_barney … skin=1`, and the
  unrelated cockroach and headcrab spawners print no skin at all.
- `regress.sh` five maps: **36 schedules built, 168/384 tasks, BAD=0**; squad,
  squad-monster and cover all BAD=0; errors 0; crashaddr **1973 → 1973**.
- `selftests.sh` six maps: `[ammotest] BAD=0`, `[aliastest] BAD=0`.
- Boot sweep of the ten affected maps — hl_c15, sc_tetris4, sc_tetris5, hplanet,
  toonrun3 (the five carrying a Gonarch), ctf_warforts, suspension, bm_sts
  (`attackrange`), th_escape, th_ep2_01 (`new_skin`): **0 QC errors on all ten**.
  The four Gonarch maps with no chain report `0 node(s), BAD=0`, i.e. they take the
  "no `netname`, killable from the start" path and behave exactly as before.
- Audits at baseline: `cvar_audit` **12**, `optional_audit` **326 files / 0**,
  `check_serverfire` **33/67**.
- Credential scan of every touched file: **0**. Nothing committed.

### Owed in-game checks (nothing renders headlessly)

- **The leap.** `BM_AE_JUMP` (event 13) was unhandled, so she played the `jump`
  animation on the spot; `goose8b` and `goose10` both name it as their
  reachsequence and both are her crossing a gap. The launch is HL's own 200
  forward / 500 up, but whether a `MOVETYPE_STEP` body of her size actually clears
  the gap is a physics question the harness cannot answer.
- The `breakwall` beat at `goose4` reading as the wall coming down *as she hits
  it* — that is what `BM_AE_EARLY_TARGET` (event 50) is for, and the early-fire is
  confirmed wired but its timing is a feel judgement.
- Whether she should keep walking while no player is near. She currently does not:
  the dormancy gate is left in place, so she waits for the player rather than
  running the chain ahead of them out of sight. Half-Life starts her at t=0. This
  is a one-line change either way and wants eyes on it before being decided.

### Not done

- **`teleport_cooldown`** — see above. The largest remaining key by a wide margin,
  and the one that needs its own patch because it lives in the predicted path.
- **Tier 4**: `monster_tentacle` (8), `monster_flyer_flock` (3),
  `monster_nihilanth` (1) — ~2,500 lines of SDK AI between them.
- Carried: no screen shake on a mortar impact (PATCH 152); the F5 variants tab
  (PATCH 148).

---

## PATCH 152 — Tier 2 finished: the turrets, the mortars, the funnel and the cvar entity

The rest of PATCH 151's Tier 2. Five classnames, 28 corpus placements in the `hl_`
set and 97 across the whole corpus, all of which were inert relays.

### What was built

| classname | placements | built on |
|---|---|---|
| `func_tankmortar` | 6 / 4 maps | the existing CFuncTank port |
| `func_tanklaser` | 5 / 2 maps | the same, driving a named `env_laser` |
| `func_mortar_field` + `monster_mortar` | 8 / 2 maps | new, `sv_hl_entities.qc` |
| `trigger_setcvar` | **69 / 10 maps** | new, `sv_hl_entities.qc` |
| `env_funnel` | 4 / 3 maps | new, `shared/sh_envfunnel.qc` + `particles/env.cfg` |

**The two tank subclasses are branches, not files.** `CFuncTankMortar`
(func_tank.cpp:920-963) and `CFuncTankLaser` (:775-884) each override exactly one
virtual — `Fire()` — and inherit the arc, the slew, the acquire, the tolerance gate
and the mount from `CFuncTank`, which `func_tankrocket` already implements in full.
So they are two branches inside `TankRocket_Fire` plus a `.tank_variant` field.
Writing them as parallel classes would have been ~400 duplicated lines that drift
apart the first time one is touched. `Tank_CommonSpawn` was factored out of
`func_tankrocket` for the same reason.

**`spriteflash` / `spritesmoke` came along for free.** `CFuncTank::Fire` spawns the
muzzle sprites in the BASE class before dispatching to the subclass
(func_tank.cpp:660-672), so wiring it in the shared path also gives the
already-shipping `func_tankrocket` a muzzle flash it never had. That is 26 corpus
entities, and it was on the Tier 3 key-gap list.

**`trigger_setcvar` is much bigger than the audit said.** PATCH 151 recorded 5 uses,
counting only `hl_` maps. The real figure is **69 over 10 maps**: `ctf_warforts` sets
nine at map start, `polar_rescue` picks a difficulty by setting eleven, `mommamesa`
maps its skill menu onto `skill`, and `deadsimpleneo2` and `toadsnatch` each rewrite
all thirteen `sk_player_*` hitgroup multipliers. Two findings that change the shape:

- **The allowlist is the entity.** `sven-coop.fgd:6705-6761` gives
  `m_iszCVarToChange` as a `choices` list of 54 exact names plus the `sk_` prefix —
  not a free text box. That bound is the only reason a map is allowed to touch
  server state, so it is transcribed verbatim and nothing is added to it.
- **Two keys carry the value.** The FGD documents `message`; `deadsimpleneo2` and
  `toadsnatch` write `m_iszNewValue` instead, from a newer editor. Both are read.
  Neither present means `"0"` — the common case, not an edge one, because
  `flashlightoff`, `noflashlight` and `mp_weaponstay` off are all spelled by leaving
  the box empty.

**`mp_flashlight` had to be invented to make it work.** All five `hl_` uses set that
cvar and it did not exist — the flashlight is a pure CSQC effect with no server gate
at all. Registered at Sven's default of 1, published to serverinfo on change, and
read in CSQC with `serverkey` rather than `cvar()` so a client cannot hand itself a
torch on a server that took it away. Re-checked per frame, not only at the toggle,
because `hl_c17` and `hl_c18` revoke it mid-map while the light may already be on.

### Three things the tests caught that the reasoning did not

1. **`monster_mortar()` inside `mortar_field_use` would have detonated the field.**
   A QC spawn function operates on `self`, and `self` there is the mortar field, not
   the shell just spawned. Caught by reading it back before the first run.
2. **`findchain` is unsafe in the tank self-test.** `W_RadiusExplode` builds a chain
   of its own, so a `.chain` walk is rewritten underneath the caller by the first
   shot. The tell was `hl_c11_a5` reporting `func_tankmortar "hangar_door"` — which
   is a door. Switched to `find()`.
3. **`MULTICAST_PVS` was wrong for `env_funnel`, and only the client run showed it.**
   HL uses `MSG_BROADCAST`. `hl_c01_a2`'s funnels fire from sealed rooms the player
   is not in, so a PVS send reached nobody and the effect never drew. Now
   `MULTICAST_ALL_R` — reliable too, because the entity deletes itself after one use,
   so a dropped packet is the effect never happening rather than a dropped frame.

### A trap worth recording

`particleeffectnum` returns a **negative** slot even when the effect is perfectly
valid — `pr_csqc.c:3735`'s `if (precache != P_INVALID)` guard is commented out, and
every impact effect in the tree resolves negative. `effect -1` in a log reads exactly
like a failure and is not one; `particleeffectquery` is the only real validator. The
`env_funnel` report prints the query string for that reason.

### New harness: `sv_tank_selftest`

A turret's `Fire()` is otherwise unreachable headlessly — it needs a living player
inside both the arc and the range window, and on `hl_c14` the player lands at
`53 1959 1703` while the nearest flower turret is at `264 712 -41` with `maxRange`
512. Wandering never closes that; a 170 s client run with a bot confirmed it does
not. So the self-test fires every `func_tank*` on the map once, three seconds in.

```
hl_c12      func_tankmortar "tank_turret": shell landed -2754 -1872 950 (1871 units out), iMagnitude 100, spread 3
            func_tanklaser  "alien_turret_2": resolved env_laser "alien_turret_2_beam", dmg 20
hl_c14      f1_kill -> flower_1 dmg 5    kill_f2 -> flower_2 dmg 10
            f3_kill -> flower_3 dmg 5    f4_kill -> flower_4 dmg 10      4 turret(s), BAD=0
hl_c11_a2   func_tankmortar "tank_turret" iMagnitude 60 + func_tankrocket "brad_turret"   BAD=0
hl_c11_a4   brad_cannon iMagnitude 100, howie iMagnitude 250            BAD=0
hl_c11_a5   two mortars, iMagnitude 250 and 200                          BAD=0
```

Every `damage` value matches the map's own `env_laser` keys, and `func_tankrocket`
still fires — the refactor is regression-checked by the same run.

### Verified

- Three VMs **0 warnings**; audits at baseline (`cvar_audit` **12**,
  `optional_audit` **326 files / 0**, `check_serverfire` **33/67**).
- `regress.sh` five maps: `34 built, 152/384 tasks, BAD=0`, squad/cover BAD=0,
  errors 0, crashaddr **1973 → 1973**. `selftests.sh` six maps: `[ammotest] BAD=0`,
  `[aliastest] BAD=0`.
- Boot sweep, 11 affected maps, **0 QC errors** and 0 unimplemented classnames
  except the two Tier 4 items left on purpose (`monster_nihilanth` on hl_c17,
  `monster_flyer_flock` on hl_c18).
- Fired by hand: `hl_c11_a5` `mortars` → `control=2: 6 shell(s) around
  -4420 -2020 -46, spread 96, last impact +4.77s`; `hl_c04` `c1a3_mortar01` →
  `control=1: 3 shell(s)`; `hl_c17` `noflashlights` → `mp_flashlight = "0"`.
- Client parity: `hl_c01_a2` 170 s with a real headless client →
  `[env_funnel] at 1664 623 -368, inward — 256 particles, effect -1
  "weapons.env_funnel"`, **0 client QC errors, no proxy mismatch**.
- Credential scan of every diff and every new file: **0**. Nothing committed.

### Owed in-game checks (nothing renders headlessly)

- The funnel actually looking like a funnel — 256 additive flares converging on
  (or streaming out of) the point over 2 s. The count, the geometry and the recipe
  are all confirmed; only the look is not.
- The tank muzzle flash sprite appearing at the barrel end at the right scale.
- A mortar salvo reading as "run" rather than as one bang — the 2.5 s first impact
  plus 0.2-0.5 s stagger is the SDK's, but the pacing is a feel judgement.

### Not done

- **Tier 3**: `info_bigmomma` (22 nodes on hl_c15 — `monster_bigmomma` already
  exists, so the Gonarch is on the map with nowhere to walk; still the cheapest
  remaining high-value item), plus the key gaps minus `spriteflash`/`firespread`,
  which this patch took.
- **Tier 4**: `monster_tentacle`, `monster_flyer_flock`, `monster_nihilanth` —
  ~2,500 lines of SDK AI between them, and genuinely its own pass.
- **No screen shake on a mortar impact.** `mortar.cpp:280` calls
  `UTIL_ScreenShake`; this tree has no shake channel at all and `env_shake` is a
  stub that only forwards its trigger. Left out rather than faked, so the gap stays
  in one place and gets fixed once.

---

## PATCH 151 — the hl_ entity audit, the Xen chapters, and 29% of the sentence file

An audit of all 36 Sven `hl_*` maps for entities we never implemented, plus the
first two tranches of the result. **This patch is partial by design** — see "Not
done" for exactly what remains.

### The audit (two independent passes, same answer)

Static: parsed every `hl_*` entity lump (**30,742 entities, 188 distinct
classnames**) and diffed against every `void()` / `void() spawnfunc_` in the tree.
Runtime: booted all 36 headless and harvested the engine's own
`[goldsrc-compat] no spawn function for "X"` report. Both give **17 classnames /
288 entities**.

Keys and flags were audited the same way, and two premises died:

- **`fireonclosed`/`fireonopened`/`fireonopening`/`fireonclosing`/`fireonstart`/
  `fireonstop`** looked like a 1,500-instance gap across 435 doors. **Zero real
  uses** — every one carries only the `_triggerstate` companion at Hammer's
  default with an empty target string. Editor noise.
- **`SF_TRIG_NOCLIENTS = 2`** on trigger_once/multiple is **correct**: the FGD's
  base `Trigger` class really does define bit 2 as *No Clients*. Only
  `trigger_hurt` and `trigger_push` override it to *Start Off*, and both already
  honour it (470 corpus uses).
- Genuinely unhandled and still outstanding: `StartDisabled` (6 real instances
  once spawnflag-redundant ones are excluded), `physdamagescale` (94),
  `pendistance` (42), `attackrange` (33), `new_skin` (15), `spriteflash` +
  `firespread` (26), `teleport_cooldown` (18), `startdirection` (9),
  `damagecap` (7), `ExplodeDamage` (3).

### Implemented and verified

- **Xen flora — 6 classnames, 180 entities** (`server/sv_xen_flora.qc`, a port of
  `dlls/xen.cpp`): xen_plantlight 75, xen_hair 35, xen_spore_small 28, xen_tree
  24, xen_spore_medium 14, xen_spore_large 4, plus the xen_ttrigger and xen_hull
  helpers. All five Xen maps boot with **0 unimplemented xen_ classnames, 0 QC
  errors, 0 model-load failures**.
- **`speaker`** (29 placements / 12 maps) and **`world_items`** (17 / 7)
  (`server/sv_hl_entities.qc`). Every affected map boots clean.

### The bug the speaker found — 29% of sentences.txt was unreachable

`speaker`'s own "no sentence or group" diagnostic fired on hl_c04 (`C1A3_`) and
hl_c09 (`WILD`). Both groups are present in the loaded file, so the fault was
ours: `Sentences_SplitFirst` **required a `/` in the first token** to derive the
directory, and returned FALSE otherwise — which drops the sentence at BOTH
precache and playback time. Measured against the shipped
`valve/sound/sentences.txt` (1065 entries):

| shape | count | examples |
|---|---|---|
| no directory at all → GoldSrc default `vox/` | **238** | `C1A0_START`, all `C1A0_*`, `C1A3_*`, the PA set |
| first token is a bare directory after modifier-stripping | **69** | `HEV_MED*`, `HEV_HEAL*`, `HG_ALERT*` |
| **total unreachable** | **307 (29%)** | |

Not a random 29%: it is the entire VOX announcement set, the HEV suit's own
voice, and the grunt radio chatter. Both shapes fixed; all speaker gripes gone,
0 sentence precache failures, `demon/dland2.wav` on hl_c04 is a pre-existing
unrelated warning.

### Verified

3 VMs **0 warnings**. `regress.sh` five maps: `schedules: 34 built, 152/384,
BAD=0`, squad/cover `BAD=0`, errors 0, crashaddr **1973 → 1973**. Audits:
optional_audit **325 files / 0** (up from 323 — the two new files),
check_serverfire **33 / 67**, cvar_audit **12**. Credential scan **0**, including
the two new untracked files.

### Not done, and why

The user approved all four tiers; two are outstanding plus most of a third.

- **Tier 2 remainder (5 classnames, ~28 entities)**: `env_funnel` (4),
  `trigger_setcvar` (5), `func_mortar_field` (8), `func_tankmortar` (6),
  `func_tanklaser` (5). Findings that matter for whoever takes them:
  - `trigger_setcvar` is **not just a spawn function**. All 5 hl_ uses set
    `mp_flashlight`, and that cvar does not exist in `sh_cvar_table.qc` — the
    flashlight is a pure CSQC effect (`client/cl_flashlight.qc`) with no server
    gate at all. Making the entity *work* means adding the gate too, which is
    what hl_c17/c18 use to enforce darkness.
  - `func_tankmortar`/`func_tanklaser` should be built on
    `sv_th_entities.qc`'s CFuncTank (which already has auto-targeting), not on
    `sv_goldsrc_compat.qc`'s mount-only `func_tank`.
- **Tier 3**: `info_bigmomma` (22 nodes on hl_c15). `monster_bigmomma` already
  exists, so the Gonarch is currently on the map with nowhere to walk — this is
  the cheapest remaining high-value item. Plus the 10 key gaps listed above.
- **Tier 4**: `monster_tentacle` (8), `monster_flyer_flock` (3),
  `monster_nihilanth` (1). Full AI ports of `tentacle.cpp` (~1000 lines),
  `aflock.cpp` and `nihilanth.cpp` (~1500). By far the largest piece.

---

## PATCH 150 — the guard who stopped halfway, an airlock that was never locked, a lift that would not stop grinding, and a rider spun twice

Four reports from hl_c01_a1, all measured before being changed. Three of them are
Half-Life SDK behaviour we had simply never ported; the fourth is an engine detail
that made six "stop the sound" calls in this tree do nothing at all.

### Owed in-game checks (this patch)

1. **The airlock guard reaches the retina scanner.** Walk into the airlock with the
   HEV suit and watch Barney: he should walk *to the panel*, put his face on it, play
   `retina`, and walk back. Before this patch he stopped a body-width short and
   scanned thin air. `sv_ai_debug 1` prints `[script] monster_barney planted <n> units
   onto "<script>"` for each leg.
2. **The airlock doors are LOCKED until he unlocks them.** `+use` the `lk1` doors
   before the scan: nothing should happen. They should open only after
   `airlockdoorbuzzmm1` fires, ~5 s into the scan chain. This is the reported bug.
3. **`ele_2` goes quiet when it arrives.** The rotating lift's movement loop must stop
   at both ends. Verified only as far as "the arrival callback runs and the stop is
   now actually transmitted" — playback is not audible headlessly.
4. **Riding `ele_2` turns you 90°, not 180°.** Stand on the lift and let it run. You
   should end up facing the way the cage faces. This is the "rotation is doubled up"
   report and it is the one change here that is purely a feel test.
5. **Nothing else on the corpus soft-locked behind a newly-closed gate.** 440 gates
   across the corpus changed from permanently-open to genuinely gated (see below).
   Seven of the heaviest-affected maps boot clean, but a gate that only matters
   mid-map cannot be reached headlessly. `sv_multisource_no_mm_inputs 1` restores the
   old behaviour without a rebuild if a map turns out to be stuck.

### Verified headlessly (numbers, not claims)

- **The plant.** `[ai] arrived:` showed the guard stopping **33.86** and **33.94**
  units short of his two marks on a **72-unit** walk — i.e. barely past halfway, every
  time, because `AI_ReachedGoal` accepts anything inside `AI_GOAL_REACH` (40). After
  porting HL's `TASK_PLANT_ON_SCRIPT`: `planted 38.60 units onto "control_retinal_1"`,
  `planted 34.00 onto "control_retinal_done"`, plus `gizmoscistart` and
  `introwalkerguy1mm` on the same map. Schedule table went 150 → **152/384 tasks**,
  `schedules: 34 built, BAD=0`.
- **The gate.** `[multisource] "lk1lock1" registered 1 input(s)` (was zero, therefore
  permissive) and `"lk1lock1" -> OPEN` only after
  `multi_manager("airlockdoorbuzzmm1")` fires it at the end of the scan chain. Full
  chain re-verified end to end: `airlockbarneylean1` → `control_retinal_1` →
  `control_retinal1mm_1` → `control_retinal2_1` + `retinal_scannermm_1` →
  `control_retinal_done` → `airlockdoorbuzzmm1` → `lk1lock1`.
- **Corpus impact of the gate change**, from the entity lumps of svencoop +
  svencoop_downloads + valve + gearbox + bshift: **1363** multisource gates, **565**
  with no `.target` input at all, **440** of those driven by a multi_manager and now
  correctly gated, **6** more gaining extra inputs alongside existing ones. Only
  **2** of the 440 are driven by a MULTITHREADED manager — the case that needs
  `MM_ResolveCaller`. Boot sweep: crystal 13 gated / 4 permissive, crystal2 39/0,
  deadsimpleneo2 14/0, hl_c01_a2 6/0, hl_c05_a2 9/1, hl_c06 8/0, pizza_ya_san1 8/0,
  **0 QC errors on all seven**.
- **`ms_norainu` now registers 2 inputs**, which is the case the old file header cited
  as proof that registering manager slots would soft-lock pizza_ya_san1. It is the
  map's intended puzzle (finish both shops), and it is what HL does.
- **The lift.** Still arrives and still fires its end-of-travel chain
  (`plat_fire("") -> trigger_changetarget("ele_at_btm")`), 0 QC errors.
  `common/null.wav` precached on every map in the sweep — no late-precache warnings.
- **Regression.** `regress.sh` five maps: `schedules: 34 built, 152/384, BAD=0`,
  `squad accounting BAD=0`, `squad monsters BAD=0`, `cover BAD=0`, `errors 0`,
  crashaddr **1973 → 1973**. `selftests.sh` six maps: `[ammotest] BAD=0`,
  `[aliastest] BAD=0` everywhere. Audits at baseline: optional_audit **323 files /
  0**, check_serverfire **33 / 67**, cvar_audit **12**. Client parity: 0 CSQC QC
  errors, no proxy version mismatch. Credential scan **0**. Three VMs, **0 warnings**.

### Behaviour changes worth knowing about

- **`sound(e, chan, "", 0, ...)` never stopped anything.** FTE's `SV_StartSound`
  (`sv_send.c:1300-1304`) treats a NULL sample as "stop this channel" but an EMPTY
  STRING as "return without sending", and QC cannot produce a NULL — `PR_StringToNative`
  (`qclib/initlib.c:1114`) returns `stringtable + 0`, a valid pointer to `""`. All six
  call sites in this tree were no-ops. Doors hid it by playing their arrival sound on
  the same channel, which is what was really cutting the loop. New `SV_StopChannel`
  plays `common/null.wav` instead; fixed in sv_doors, sv_func_train,
  sv_func_tracktrain, sv_func_guntarget, sv_grapple and sv_th_entities.
- **The plat family is no longer carried twice.** `Mover_TravelTick` runs
  `Mover_PlatformCarry` for everything it ticks, and a plat is `BRUSH_TYPE_TRAIN`, so
  pmove's train branch carried it as well — the double that `func_train` and
  `func_tracktrain` were moved off the tick to avoid. On a plain `func_plat` gravity
  hides it; on a `func_platrot` the extra orbit accumulates. The tick now applies only
  the **view** yaw for TRAIN brushes (pmove never touches angles). Doors and buttons
  are untouched — pmove's train branch skips them entirely, so the tick is still their
  only carry.
- **`func_platrot` is off `rotating_brush_list` on BOTH sides.** The server half alone
  would have fixed nothing: `cl_brushsync.qc` rebuilds that list purely from the
  wire's avelocity and never mirrors the server's membership.
- **440 gates that were always open are now gated.** This is the largest behaviour
  change in the patch. `sv_multisource_no_mm_inputs 1` is the rollback.

### Not done, and why

- **`sv_satchel_test` was not run this patch.** It must not share a session with
  `sv_ammo_selftest`, and nothing here touches weapon or ammo code — the four changes
  are multisource registration, one AI task, a sound helper and platform carry.
- **The remaining five stop-sound sites are fixed but only the plat is verified.**
  The grapple, guntarget, tracktrain, train and They Hunger movers all had the same
  dead call; playback is not audible headlessly, so those are corrected-by-inspection.
- **The F5 variants tab** is still not built (carried from PATCH 148).

---

## PATCH 149 — the void spawn on hl_c00, a gate that never closed, an invisible wall that wasn't, doors opening the wrong way, and the sniper's missing first half

Five follow-ups from play-testing PATCH 148. Four had a measurable root cause and are
verified below; the fifth (the rotating-door swing) is a straight SDK port whose
result is inherently visual.

### Owed in-game checks (this patch)

1. **Rotating doors, from both sides.** `+use` a swinging door standing on one side,
   then from the other, and confirm it opens **away** from you both times. The
   decision is logged: `sv_debug_doors 1` prints `[rotdoor <name>] activator <who>
   cross=<n> -> sign <±1>`. Doors carrying ONE_WAY (spawnflag 16) deliberately do not
   flip — five of pizza_ya_san1's seven kamado doors are in that set and were already
   behaving.
2. **The pizza_ya_san1 door that "shifts open slightly and is funky".** The likeliest
   cause was the door swinging into the wall behind it and jamming on every press;
   that direction is now fixed. If it still desyncs, the remaining suspect is the
   client's rotating-brush extrapolation rather than the door logic — the server
   dirties `SendFlags` on every halt path (`sv_doors_rotating.qc:577,618`), so the
   stop *is* reaching the wire.
3. **`wlt_komugiarea` is invisible but still blocks.** Both halves matter: it must not
   be drawn, and you must not be able to walk through it until the map's
   `mm_flourend` fires it at t=18.
4. **The M40A1 reload is now one drill in two stages.** Press reload and confirm you
   see the clip come out (stage 1, `reload1`) *and then* the bolt worked (stage 2,
   `reload2`) — roughly 4.2 s end to end on this install — with the two samples
   butted together rather than one playing over a still frame.
5. **hl_c00 from the tram.** The spawn point is verified headlessly; what is not is
   that the ride *looks* right — you should be inside the tram as it pulls away, not
   standing beside it or clipping through the floor.

### Verified headlessly (numbers, not claims)

- **The hl_c00 "0,0,0" spawn was a lock offset captured 40 ms too early.** A
  `func_tracktrain`'s authored `origin` is its origin BRUSH, which this map parks in a
  closet: `train` is authored at `-3046 -2635 -2516` and belongs at `2983 2836 453`.
  The map glues its spawn points to the trams with `trigger_setorigin` in Lock Offsets
  mode, and the follower's first pass ran **before** the train snapped onto its track
  — the two are on different clocks (`.ltime` for a pusher, `time` for the
  `trigger_auto` that switches the follower on). Measured, before → after:

  | | before | after |
  |---|---|---|
  | `spawn1` lock offset | `6062 5503 3017` | **`33 32 48`** |
  | `spawn3` lock offset | `2912 2149 -762` | **`31 32 48`** |
  | player spawn origin | `9045 8339 3470` (void) | **`3016 2868 502`** (in the tram) |

  Ordering confirmed directly in the log: the first `[setorigin]` line precedes the
  first `[tracktrain … placed=]` line. Fixed by making the dependency explicit
  (`Mover_EnsureSpawnPlacement`) rather than by tuning the two think times.
  The boot chain is unchanged: **611** chains, **17** multi_manager activations,
  `game_playerspawn` still fires 5 entities, 0 QC errors on both sides.

- **Every multisource whose inputs were touch triggers has been open since map load.**
  `ms_register` skipped any input without a `.use`, and a brush trigger has only a
  `.touch` — it reports in from `trigger_multi_touch` through `SUB_UseTargets`, exactly
  as a `trigger_relay` does. With no registerable inputs the gate fell through to
  PERMISSIVE, i.e. open. Measured on hl_c01_a1, before → after:
  `[multisource] "suit_ms" has no registerable inputs -> permissive` →
  `[multisource] "suit_ms" registered 1 input(s)`.
  Corpus reach, counted from the BSP entity lumps: **1073 multisource gates, 693 with
  at least one input**, and the input classnames that were being skipped are
  `trigger_once` **93**, `trigger_multiple` **10**, `item_battery` 3, `item_longjump` 1
  — **107 inputs**. (`item_security` ×4 stays excluded; it is `gs_unimplemented`.)
  HL's `CMultiSource::Register` tests nothing at all, so this is a step toward parity.
  The two gates on hl_c01_a1 that remain permissive (`ms1`, `lk1lock1`) genuinely have
  zero inputs, which HL also treats as satisfied.

- **The free HEV suit was that gate.** hl_c01_a1 has
  `game_player_equip { item_suit 1, master "suit_ms" }`, and PATCH 148 taught
  `GamePlayerEquip_Apply` to honour `item_suit` — so the open gate handed out the suit
  (and its 50 armour) on the first spawn, which is why `trigger_suitcheck` always
  passed. Measured with a real client after the fix:
  `[suitcheck] "check4suit": Player has_suit=0 armor=0 -> "" (0 ent)`.

- **`func_wall_toggle` was erasing the render keys' own answer.** Two unrelated
  mechanisms want `EF_NODRAW` on that class: `BrushSync_SetAlpha` sets it to express
  GoldSrc's "renderamt 0 on a non-Normal rendermode means invisible" (FTE cannot carry
  a zero through `.alpha`), and the toggle sets/clears it for its own state.
  `func_wall_toggle_show` cleared it unconditionally, so pizza_ya_san1's
  `wlt_komugiarea` — `rendermode 5`, no `renderamt`, the standard invisible-barrier
  idiom — spawned "shown", lost the bit, and drew as a fully opaque **additive** slab
  with `.alpha` still 1. CSQC's `fx_hide` guard could not catch it either: that tests
  `alpha <= 0`. Now latched at spawn (`fwt_keys_nodraw`) and restored by `_show`.

- **Rotating doors were testing the wrong vector.** `CBaseDoor::DoorGoUp`
  (`halflife/dlls/doors.cpp:583-597`) takes the 2D cross product of (pivot → activator)
  with the **activator's facing**; substituting out HL's redundant `vnext` leaves
  `10 * (vec.x*fwd.y - vec.y*fwd.x)`. Ours used `makevectors(self.pos1)` — the DOOR's
  angles — but on a `func_door_rotating` `angles` is the initial rotation, not a
  facing, and it is `0 0 0` on **all 11** rotating doors in pizza_ya_san1. `v_forward`
  came out `(1,0,0)`, so the test reduced to "is the player on the +X side of the
  hinge". Now axis-gated to yaw doors like HL's `pev->movedir.y` test.

- **The M40A1 reload is two stages, not two forms.** PATCH 148 read `reload1`/`reload2`
  as full-vs-short drills chosen by magazine state. The samples are named
  `first_seq`/`second_seq` — the first and second sequence of *one* reload — and
  `reload2` opens with the bolt already back, which is why a partial reload looked like
  "the bolt jumps back magically and he pushes it forward, no clip removal": the clip
  change is in `reload1`, which only ran when the magazine happened to be empty. Both
  mounts agree structurally (svencoop re-cut stage 2 as a bolt cycle). Now
  `reload1 → reload2` every time, 2.353 + 1.815 = **4.17 s** on the gearbox copy that
  wins here. Stage 2 gets its own animation clock via
  `csqc_viewmodel_sequence_time_override` rather than by re-stamping `wep_anim_start`,
  which is what `SH_StandardTickState` measures the whole reload against.

- **Regression, all at 0 QC errors:** desertcircle, hl_c00, hl_c01_a1, crossfire,
  crystal, sandstone, pizza_ya_san1, hc2_c2, th_ep1_00 — 9/9 `spawned=1 qcerrors=0`.
  `sv_ai_selftest` every line BAD=0 (roster 100 weapons, 0 missing rows, 0 mirror
  failures); `sv_ammo_selftest` BAD=0; `sv_satchel_test` 26 PASS BAD=0.
  Audits at baseline: `optional_audit` 323 files, `check_serverfire` 33/67,
  `cvar_audit` 12. Three VMs, 0 warnings. Credential scan of the diff: 0.

### Behaviour changes worth knowing about

- **`sv_debug_firetarget` now fires as a player** when one is connected, falling back
  to `world` only under `sv_debug_fire_noplayer`. Firing from `world` made exactly the
  entities the harness exists for untestable — `trigger_suitcheck`,
  `game_player_equip` and `trigger_changevalue`'s `!activator` form all read the
  activator and did nothing without it.
- **Gates that were silently open are now shut.** That is the fix, but it means any map
  whose progression depended on the leak will now require the trigger the mapper
  actually placed. Nine maps regressed clean; a wider sweep is the measured next step.
- **`PlayerPlaceAtSpawnPoint` reports under `sv_debug_spawns`** — either the chosen
  point and origin, or `NO ELIGIBLE SPAWN POINT … -> 0 0 1`. That fallback is
  indistinguishable in-game from "the map threw me into the void", which is what made
  this report hard to place.

### Not done, and why

- **`onlytrigger` is not a `+use` gate.** The report assumed it stops the door being
  opened by hand. It is Sven's brush-breakable extension key — the FGD lists it inside
  the `breakable`/`material`/`gibmodel`/`instantbreak` block, and it mirrors HL's
  `SF_BREAK_TRIGGER_ONLY` ("Only break on trigger", `dlls/func_break.cpp:148,168`). On
  all seven pizza_ya_san1 doors carrying it, `breakable` is **0**, so the key is inert.
  Nothing was changed for it.
- **The F5 variants tab** is still not built; unchanged from PATCH 148.
- **hl_c00's `trigger_changevalue "game_playerspawn"`** (which sets the player
  `solid` to 0 so players in the cramped tram do not shove each other) now fires,
  because PATCH 148 added the reserved-name emitter. It is implemented and behaves,
  but nothing here measured what a `SOLID_NOT` player does to FTE's prediction over a
  long ride. Worth an eye on the tram.

---

## PATCH 148 — hl_c00's dead map, Barney's silent lines, the ammo crates, the sniper reload, and a zero-ammo regression

### Owed in-game checks (this patch)

1. **The M40A1 reload, at BOTH magazine states.** This is the one the harness cannot
   see at all. Reload from **empty** (plays `reload1`) and reload with **1–4 rounds
   left** (plays `reload2`) and confirm the motion and the sound end together and the
   gun does not snap to `slowidle` part-way. Also watch the **draw** — the probe says
   gearbox won on this install, whose `draw` is 1.000 s against the 0.517 s the file
   used to hardcode, so the draw was previously ending at 52 % of its animation.
2. **The desertcircle crates, by hand.** Walk up to a crate and press `+use`. Before
   this patch nothing happened at all. Check the lids open, you get 9 mm + 7.62 +
   health, and — because `rotbtn_go_down` no longer re-fires the whole chain — that
   you are **not** equipped a second time ten seconds later when the button swings back.
3. **Barney's airlock nag.** On `hl_c01_a1`, walk into the airlock without the HEV
   suit and confirm he says the "no suit" line *audibly* (it used to fail the sentence
   lookup and mime). Then pick the suit up, walk back, and confirm the nag **stops**
   and he says the "yes" line instead — that is `trigger_suitcheck` working.
4. **hl_c00 end to end.** The tram departure is verified headlessly; what is not is
   the fade-in, the credit titles and the intro music actually appearing.
5. **Two primaries keep their own magazines.** Carry two with visibly different
   counts, cycle with key `1`, and confirm the HUD number tracks the gun. Buy or F5-give
   a third at the limit and confirm the new one arrives **full**. Die with two and
   confirm each drop carries its own count.

### Verified headlessly (numbers, not claims)

- **hl_c00 was not "unloading entities" — nothing ever started.** The mod never fired
  Half-Life's reserved targetnames. Measured on the same map, before → after:
  **9 → 600** `[chain]` events, **0 → 17** multi_manager activations, and the tram
  goes from parked to accelerating away through its path_tracks (300→200→300→350→400).
  The emitter reports `[reserved] fired "game_playerspawn" for Player -> 5 entities`.
  **The diagnosis was proved BEFORE any code was written**, by firing the name by hand
  with `sv_debug_firetarget game_playerspawn`; the shipped emitter and that harness now
  call the same `SV_FireTargetsByName`.
- **Two hypotheses killed on the way, both wrong.** (a) The April-Fools `hl_c00` is
  *not* winning the name collision — `SPF_ADDON` tail-appends (`fs.c:4492`), so an
  earlier `fs_addons.txt` line wins and the right map loads. (b) killtarget is not
  wiping the map — `SUB_KillTargets` guards the empty string in three places and is in
  fact *stricter than Half-Life*, whose `if (m_iszKillTarget)` index test would let an
  empty-but-present killtarget delete the world.
- **Sentences: 0 misses** on `hl_c01_a1` where `!BA_button` and `!BA_hevno` both failed
  before. `BA_BUTTON` was in the loaded file all along at line 747; the lookup used
  QuakeC `==` where GoldSrc uses `stricmp`. Corpus scan: **14** case-only misses across
  the Sven maps, **27** counting valve/OpFor/Blue Shift. Safe to fold case — valve's
  1065 entries hold 1061 distinct names *either way*, so no two differ only by case.
- **`SENT_MAX` 2048 → 4096.** The old cap was overflowing in the shipped build, not in
  theory: every hc2 map logged `SENT_MAX (2048) overflowed: 83 line(s) dropped`.
- **`v_m40a1.mdl`: gearbox wins on this install** — `seqprobe models/v_m40a1.mdl 9 seqs
  | have: draw(1.000) slowidle(4.348) fire(1.763) reload1(2.324) reload2(1.778) ...`.
  The QC hardcoded svencoop's numbers (0.517 / 2.683 / 1.250) for a model that is not
  the one loading. `AI_ProbeModelSeqs` now prints durations, which is the only way to
  tell these two apart — the labels and their order are identical.
- **Ammo/carry self-tests**: `sv_ammo_selftest` **BAD=0** all four stages, including
  stage 2 `carried-not-held: want=60 got=60 slot=60`; `sv_satchel_test` **26 PASS,
  BAD=0 at `mp_maxprimary` 1 and 2**; `sv_ai_selftest` every line **BAD=0**, roster
  100 weapons / 0 missing rows / 0 mirror failures.
- **Nine-map regression, 0 QC errors each**: desertcircle, hl_c00, hl_c01_a1, crossfire,
  crystal, sandstone, pizza_ya_san1, hc2_c2, th_ep1_00.
- Audits at baseline: `optional_audit` 323 files, `check_serverfire` 33/67,
  `cvar_audit` 12. Credential scan **0**. Three VMs, **0 warnings**.

### Behaviour changes worth knowing about

- **`game_playerspawn` / `game_playerjoin` now fire on every spawn.** 90 placements
  across the corpus, 31 of them `game_playerspawn` across 14 maps — so `bm_sts`,
  `botparty`, `ctf_warforts`, `stadium4`, `svencoop2`, `th_ep1_00` and friends will all
  do things they have never done in this mod before.
- **`game_player_equip` grants ammo, health, armour and the suit**, and honours the
  quantity. It previously understood weapons and `item_longjump` only and silently
  dropped everything else — which also means desertcircle's two class-select booths
  have been quietly losing their ammo lines this whole time.
- **A "Not solid" `func_rot_button` is usable again.** This is map-wide, not
  desertcircle-only: the flag sets `SOLID_NOT`, and FTE's `findradius` skips those
  without `FL_FINDABLE_NONSOLID` (`pr_bgcmd.c:4085`). Its sibling
  `momentary_rot_button` already carried the fix, with a comment describing this exact
  failure.
- **`item_suit` now sets a boolean** as well as granting armour, and sets it *before*
  the full-armour early-out — so picking the suit up at 100 armour still counts as
  having it. Nothing is gated on the flag.
- **The M40A1's refire cadence follows the model**, so it is 1.7 % slower on the
  gearbox copy than the old hardcoded 1.733 s.

### Not done, and why

- **The F5 variants tab is NOT built.** The inventory and the mechanism are both
  settled — `sh_modellist.qc` already hijacks `precache_model`/`setmodel` so one table
  remaps `v_`/`p_`/`w_` with zero call-site edits (512-pair capacity, 22 in use), and
  on disk there are exactly two shipped lists (`pizza_ya_san` 20 usable pairs including
  all three grapple models, `ressya_no_tabi` 5) plus three distinct grapple model sets
  (gearbox 255 KB, svencoop 441 KB, pizza_ya_san 278 KB). What is missing is the UI and
  a safe runtime swap: `Modellist_Load` early-returns once loaded, so a switch needs
  Reset + Load + `Modellist_PrecacheTargets`, and a **runtime** precache on a live
  server is the part that wants care. The safe shape is to precache every discovered
  variant target at map load so the switch is a table swap only.
- **Sven's extra sentence files are still not layered** (`default_sentences.txt` 1665
  entries, plus op4/bshift/tfc/hc2). Worth ~47 further misses including `!SC_COUNTING1`,
  `!SC_COUNTING2` and `!SC_WOKENUP`, which are absent from valve entirely — but it
  changes what many maps sound like, so it stays a deliberate next step.
- **De-duplicating the sentence table was considered and rejected**: ~1.1 M string
  compares at map load to reclaim table slots that 4096 already has spare.
- **`W_Refresh*Slot` is still not split** into bind-only and bind+fill halves. Measured
  at 78 case arms across 447 lines. The wrapper is correct now that it snapshots the
  weapon's own store rather than the slot cache, so the split is tidiness, not
  correctness.
- **The seven remaining ambiguous-mount weapons** (`v_saw`, `v_knife`,
  `v_spore_launcher`, `v_desert_eagle`, `v_satchel_radio`, `v_squeak`, `v_tripmine`)
  are documented but untouched. `v_knife` is the worst: `sh_wpn_opknife.qc` hardcodes
  indices up to 12 against a cstrike copy that has only 8 sequences.

---

## PATCH 147 — desertcircle pacing, multi-carry weapon slots, targeted sequence names

### 1. desertcircle: the prime suspect was wrong, and the measurement says so

The reported symptom was "they spawn after a flag, but really slowly, and don't move far".
The plan named `squadmaker_use`'s missing use-type handling as the likely cause. **It is a real
bug and it is fixed, but it is not this map's problem** — dumped from the BSP:

```
desertcircle squadmakers: CYCLIC=15  non-cyclic(stream)=3
```

15 of 18 carry `SQ_SF_CYCLIC`, which returns before the toggle branch entirely; the 3 that
don't are all `castlebosssm` (monstercount 1). So the toggle fix cannot move this map.

What actually paces it, read out of the entity lump:

```
base1iter  run_mode 2  delay_between_runs 14  delay_between_triggers 3  classname_filter "player"
base2iter                              18                            3
base3iter                              20 / castleiter 19
```

`classname_filter "player"` means the spawn relay fires **once per living player per pass**.
One player on base 1 = one grunt per 14 s. A full Sven server = eight. **The map scales its
own chaos with player count, and a small game is quiet by design.** Measured baseline: 3
`[squadmaker]` spawns in 60 s with one bot.

Two new cvars give that dial without editing maps — `sv_monster_spawnrate` (scales the
iterator's `delay_between_runs` / `delay_between_triggers` and squadmaker `delay`) and
`sv_monster_maxlive` (scales `m_imaxlivechildren`, which on this map is 1-3 per maker and is
the real ceiling on fight size). Measured:

| setting | spawns / 60 s | peak live per maker |
|---|---|---|
| defaults (1 / 1) | **3** | 3 |
| `spawnrate 4`, `maxlive 3` | **13** | 6 |

**`sv_monster_maxlive` 0 does NOT mean unlimited**, and that is load-bearing: `cvar()` answers
0 for a cvar the table has not applied yet, and the AI self-test runs early enough to see it.
The first version had an `0 == unlimited` arm and `sv_ai_selftest` caught it immediately as
`squad: cap breached, 4 live` / `killed 4 children, expected 3`. Same shape as the
USE_OFF-is-zero trap at `sv_customdefs.qc:767`.

Also in: `sv_ai_engageslots` (default 2 = Half-Life exactly). `SQSLOTS_ENGAGE` is a **two-bit**
mask and all 11 slot bits are already allocated per-family, so a bigger ration cannot be more
bits without colliding with the grenade / agrunt / houndeye sets — above 2 the surplus shooters
are let through **without a bit**, counted by schedule. And a monster denied a slot now closes
to `AI_DENIED_CLOSE_FRAC` of its range instead of posing at the edge of it; the stand-and-face
band is kept for the cooldown case, which is what it was measured for.

### 2. NAV_NODE_MAX 4096 was tried and reverted — do not redo it

desertcircle fills the 2048 array exactly and still comes out in 10 components. Doubling it:

```
largest component 90.7% -> 97.3%,  components 10 -> 9
BUT map-load nav build 0.364s -> 8.53s,  link-slot evictions 0 -> 93,
    qwprogs.dat 9.3MB -> 14.4MB,  fteqcc compile ~40s -> >300s
```

6.6% connectivity is not worth a 23x load stall on every map. The same symptom is addressed
free by a component filter in `Nav_PickRoamGoal`: component ids are now recorded per node as a
by-product of `Nav_ReportComponents`, which already floods every component to count them, so
"is this goal reachable" is O(1) instead of the flood its old comment said it would need.

### 3. Multi-carry: cursor + carry list, and no new ammo storage

`slot_primary` / `slot_secondary` keep their names and become **cursors** — "the primary I have
selected" — exactly as `slot_utility` already related to the `.ammo_*` counters. ~210 references
across 20 files stay correct verbatim; only the ownership/occupancy sites changed, and those go
through `W_CarryHas`. Inventory is `.float carry_primary[4]` / `carry_secondary[4]`, packed and
0-terminated, with no count field (a stored count is a second source of truth). Field arrays are
a shipping construct here — `.float proj_consumed_ids[32]` is read and written with a variable
index at 0 warnings.

**Zero new ammo fields and zero new ammo wire bytes.** A holstered weapon keeps its magazine in
its own legacy `.mag_x`/`.ammo_x`; the canonical registers belong to whatever the cursor names.
The `pm_ammo_mb*` mask, which has the worst failure history in the file, is untouched.

Wire: `PM_CSQC_PROXY_VERSION` 24 → 25, +8 bytes in `PM_SF_WEAPON_STATE` only, written after the
four cursor bytes and before `self.weapon`.

`mp_maxprimary` / `mp_maxsecondary` default **2** — GoldSrc maps hand out two primaries via
`game_player_equip` / map cfg, and at a limit of 1 `W_GiveWeaponToSlot` dropped the first on the
floor. At 1 the behaviour is bit-identical to before.

### Three bugs the self-tests caught in this patch's own code

1. **`W_DropSlotForBuy` nulls `slot_primary` itself**, so `W_CarryRemove(self, …, self.slot_primary)`
   after it removed `WEP_NONE` and the dropped gun stayed in the list forever. Latch the victim
   first. Found by `sv_satchel_test` (PASS=21/FAIL=5), and only above limit 1.
2. **`float victim` declared twice in one function** — QC scopes locals function-wide, so
   `Q207: duplicate definition ignored` meant the SECONDARY arm silently reused the PRIMARY's
   value. The warning was the only symptom; the satchel test still failed until it was renamed.
3. **The ammo hand-off was backwards.** The plan said to `W_SlotAmmo_SaveLegacy` the **incoming**
   weapon in `W_SelectWeapon`. That copies its stale LEGACY value over its canonical — and the
   canonical is the authority for a gun you carry but are not holding, because
   `Ammo_TopUpWeapon` writes there and deliberately skips the legacy register unless the gun is
   in hand. It must be the **outgoing** weapon. `sv_ammo_selftest` stage 2 went
   `want=60 got=10 FAIL` until this was reversed. TESTING.md:5623 recording that stage as
   previously PASSING is what proved it was a regression rather than a known defect.

### Measured

- three VMs **0 warnings**; `optional_audit` 323 files, `check_serverfire` 33/67,
  `cvar_audit` 12 — all baseline
- `sv_ai_selftest` every line **BAD=0** (roster still 100 weapons / 0 missing / 0 mirror)
- `sv_satchel_test` **PASS=26 FAIL=0** at limits 1 AND 2; `sv_ammo_selftest` **BAD=0**, all 4
- seven-map regression, **0 QC errors** each
- headless client on crossfire — **0 client QC errors, 0 server QC errors, no proxy version
  mismatch** over the new v25 wire
- `seqprobe models/v_9mmar.mdl 8 seqs | have: longidle idle1 grenade reload deploy shoot`
  — valve wins that path on this install, so the hardcoded 5/6/7 happened to be right here;
  the bug was latent for anyone whose gearbox/bshift mount wins, where index 5 is `deploy`

### Owed in-game checks

- **The carry HUD, by eye** — nothing renders headlessly. With two primaries, slot 1 should
  show both beneath its row, highlight the held one, and press-1 should walk down the list and
  wrap. At `mp_maxprimary 1` the HUD must be pixel-identical to before.
- **A GoldSrc map that equips two primaries** keeps both instead of dropping one.
- **Death with two primaries drops BOTH** — the loop drains the carry list now; a silent
  deletion here is indistinguishable from the drop physics eating it.
- **Ammo boxes fill a carried-but-holstered second primary.**
- **`sv_monster_spawnrate 4` on desertcircle** should feel like a Sven server; confirm nothing
  else on the map speeds up with it (it scales iterators and squadmakers only).

---

## PATCH 146 — the CS Glock and G3SG1 animations, by sequence NAME

PATCH 145 closed with these two guns marked unfixable: their viewmodels are flat IDPO frame
bakes whose frame names were destroyed, so the hand-guessed `// placeholder — user will tune`
ranges could not be recovered. That verdict was right about the bake and **wrong about the
remedy**, on two counts.

### 1. Name-based sequence lookup already exists, in the engine and in this tree

`frameforname(modelindex, name)` is FTE builtin **#276** (`pr_skelobj.c:2888`), declared in
both `cl_defs.qc:1283` and `sv_defs.qc:1295`, and already used throughout the monster AI —
`AI_SetSequenceNamed` at `sv_ai_anim.qc:505`, `AI_SeqNameExists` at `:526`.
`Mod_FrameNumForName` (`com_mesh.c:7053`) dispatches to `HLMDL_FrameForName` for IDST models,
reading the studio sequence labels straight out of the file. **No engine change was needed.**
Only the weapon layer had never adopted it: every `sh_wpn_*.qc` hardcodes indices read out of
a model by hand.

**55 of the 82 viewmodels in `models/weapons/` are IDST and carry names. 27 are IDPO and do
not.** These two guns are in the 27 — but that is a property of those two *files*, not of the
approach.

### 2. The originals are on the mount, and the crowbar already made this migration

`sh_wpn_hlcrowbar.qc:75` is `CROWBAR_VIEWMODEL = "models/v_crowbar.mdl"` — the Steam **valve**
original — and its header at `:12` records abandoning `wpn_hlcrowbar/v_crowbar.mdl` for being
"a flat frame bake whose idle alone spanned...". `sh_wpn_hlglock.qc:26` records the same move.
So this is house style, not a new risk. `fs_addons.txt:16` mounts `steam:Half-Life/cstrike`,
which carries both originals as IDST with clean labels.

| | old (IDPO bake) | new (IDST, cstrike mount) |
|---|---|---|
| Glock | `wpn_csglock/v_glock.mdl`, 187 frames, **1** group named `frame` | `models/v_glock18.mdl`, **13** named sequences, 443 frames |
| G3SG1 | `wpn_csg3sg1/v_g3sg1.mdl`, 157 frames, **1** group named `frame` | `models/v_g3sg1.mdl`, **5** named sequences, 215 frames |

FTE groups Quake MDL frames by stripping trailing digits, so `frame0..frame186` collapses to
one group called `frame` — that is *why* `frameforname` returns -1 on the bakes, and why the
ranges are unrecoverable rather than merely unknown (187 ≠ 443, 157 ≠ 215; the bake is neither
a concatenation nor a fixed-rate resample).

### 3. New shared helper

`SH_SeqForName(viewmodel, name, fallback)` in `sh_weapon_standard.qc`, beside `SH_SeqDuration`.
Range-checks the upper end against `modelframecount` for the same reason `AI_SeqForActivity`
does — `frameduration` silently clamps an out-of-range index and returns a *plausible* duration
for the wrong sequence, which reads as a timing bug rather than a missing animation. Passing
the old hardcoded index as `fallback` means a nameless model degrades to exactly the previous
behaviour. Nothing else in the tree was converted; the helper is there for the next weapon.

### 4. Why event times are FRACTIONS, not seconds

**`cstrike` and `czero` are both mounted (`fs_addons.txt:16-17`) and both ship
`models/v_glock18.mdl` and `models/v_g3sg1.mdl`** — same sequence names, same order, same
frame counts, **different fps**:

| | cstrike | czero |
|---|---|---|
| `v_g3sg1` reload | 141 f @ 30 fps = **4.667 s** | 141 f @ 39 fps = **3.590 s** |
| `v_glock18` idle1 | 11 f = 0.625 s | 2 f = 0.062 s |
| `v_glock18` reload2 | 76 f @ 30 = 2.500 s | 76 f @ 35 = 2.143 s |

This is the argument for the whole approach in one table: the **names** are stable across the
ambiguity, so lookup returns the same index either way, while every **duration** differs. So
durations come from `SH_SeqDuration` on the model that actually loaded, and reload sound marks
are stored as a fraction of that sequence (`*_RELOAD_F_CLIPOUT` etc.) rather than as absolute
seconds. Hardcoding either mount's timings would desync the sounds from the animation on the
other.

### 5. Incidental gain

`v_glock18.mdl` has a **`shoot_empty`** sequence — slide locks back on the last round — that
the flat bake had no way to reach. `SH_GlockPickShootSeq(action_id, mag_left)` now selects it
when the magazine hits zero. Burst fire (WS_SPECIAL) shares the shoot takes because the model
has no dedicated burst sequence, and neither does GoldSrc.

### Measured

- three VMs **0 warnings**; `optional_audit` PASS **323 files**, `check_serverfire` PASS
  **33/67**, `cvar_audit` **12** — all at baseline, no movement
- roster self-test **100 weapons, 0 missing rows, 0 mirror failures, BAD=0**; every
  `[ai-selftest]` line BAD=0; all `[satcheltest]` invariants PASS
- seven-map regression (`desertcircle`, `hl_c01_a1`, `crossfire`, `crystal`, `sandstone`,
  `pizza_ya_san1`, `hc2_c2`) — spawned=1, **0 QC errors** each
- headless client on `crossfire` — **0 client QC errors**, no viewmodel load failures
- **the lookup itself, measured.** Two `AI_ProbeModelSeqs` lines were added to
  `AI_SeqNameSelfTest` — the first viewmodels in it, everything else there is a monster rig:

  ```
  seqprobe models/__ai_probe_control__.mdl  0 seqs | have:                    | MISSING: idle walk
  seqprobe models/v_glock18.mdl            13 seqs | have: idle1 shoot shoot2 shoot3 shoot_empty reload draw | MISSING:
  seqprobe models/v_g3sg1.mdl               5 seqs | have: idle1 shoot shoot2 reload draw | MISSING:
  ```

  The control line is what makes the other two trustworthy: a path that cannot exist still
  reports NOT INSTALLED, so the engine is not substituting a stand-in model and reporting its
  names. A `MISSING:` entry on either gun is not fatal — `SH_SeqForName` falls back — but it is
  the difference between the guns animating correctly and animating the way they did before,
  and nothing else in the build would say so.

### Owed in-game checks

- **The animations themselves, by eye.** This is the whole point of the patch and the harness
  cannot see it: nothing renders headlessly, so `CSQC_UpdateView` and every `predraw` never
  run. Draw / fire / reload / idle must each play the right take on both guns, and the
  viewmodels will **look different** — they are now the stock CS models rather than the mod's
  converted bakes.
- **Glock `shoot_empty`** — fire the last round of a magazine; the slide must lock back.
- **Reload sound sync on both** — clipout / clipin / slide must land on the matching visual
  beat, not merely in the right order. This is the check that would catch a wrong fraction.
- **Which mount won.** If the reload feels notably fast, `czero` won the filename over
  `cstrike`; both are correct by construction, but it is worth knowing which is on screen.
- **Glock burst (`+attack2`)** — three rounds, sharing the shoot takes, then the cooldown.

---

## PATCH 145 — the Gauss ricochet balls, and closing the GoldSrc-era weapon roster

Two requests: recreate the Gauss's bouncing impact particles from the GoldSrc files, and
audit the HL / Opposing Force / Blue Shift arsenal for anything not mounted, loaded, or
reachable from the debug menu. Both turned out narrower than they looked, because in each
case the machinery already existed.

### 1. The Gauss balls — three of the four emissions were never wired

`ev_hldm.cpp` calls `R_Sprite_Trail` — the bouncing tempent — in **four** places. The mod
emitted at one. (`R_TempSprite`, which sits beside each of them, is a static glow flare that
never moves; the beam's EndSprite already covers that.)

| GoldSrc site | fires when | count | velocity | scatter | was here? |
|---|---|---|---|---|---|
| `ev_hldm.cpp:1016` | shallow reflect | 3 | `normal * 100` | ±50/axis | **yes** |
| `ev_hldm.cpp:1121` | **primary fire hits a wall** | **8** | **`normal * 200`** | ±50/axis | no |
| `ev_hldm.cpp:1081` | secondary punch, entry hole | 3 | `-forward * 100` | ±50/axis | no |
| `ev_hldm.cpp:1096` | secondary punch, exit hole | `damage * 0.3` (≤60) | `-forward * 40` | ±100/axis | no |

The comment at `sh_wpn_hlgauss.qc:260-263` claimed a square-on hit deliberately got no balls
"which is the tell that tells the two hit types apart". That was **wrong**, and it is the
whole bug: `ev_hldm.cpp:1114` says the opposite in the SDK's own words — *"slug doesn't punch
through ever with primary fire, so leave a little glowy bit and make some balls"*. The primary
branch is the common case and it `break`s out of the walk; that is why balls only ever
appeared on a lucky glancing shot.

**Wire.** The exit spray's count is the one in the game that is not a constant, so
`CSQC_EVENT_ALIEN_FX` grew **one magnitude byte** (16→19 bytes on the estimate table at
`cl_main.qc:2015`). `AlienFX_Multicast(kind,pos,dir)` is now a wrapper over a 4-arg form
passing 1, so the ~8 creature call sites are untouched. The parser reads the byte **before**
the kind bounds check, so an unknown kind cannot desync the packet.

**Engine constraint the tuning is bounded by:** `p_script.c:7667` — a particle can only come
to rest if it is textureless *and* `PT_NORMAL`. `gauss_balls` is a `texturedspark`, so it
bounces until `die`. GoldSrc's nominal 0.6 s life is deliberately **not** copied upward;
raising `die` brings back the floor jitter `impacts.cfg:828-835` documents.

### 2. Three Opposing Force weapons that were never built

gearbox declares ten in its own `sprites/weapon_*.txt`. Seven existed. All models for the
missing three were on the mount the whole time.

| new | based on | behaviour source |
|---|---|---|
| **Combat knife** (`sh_wpn_opknife.qc`) | crowbar + pipe wrench | Sven manual: *"a direct replacement for the crowbar … functions exactly the same … but has a higher attack rate due to its lower weight"* |
| **M249 SAW** (`sh_wpn_opsaw.qc`) | Sven UZI (sequence-driven) | Sven manual: *"a belt of 200 5.56 mm rounds, but suffers high reload time"* |
| **Penguin** (`sh_wpn_oppenguin.qc`) | snark | OpFor only — see the assumption below |

Every sequence index was **dumped out of the models**, not recalled. Two scratchpad tools
were written for it (`mdlseq.py` for IDST, `mdlframes.py` for IDPO). What that turned up:

- `v_knife.mdl` is the crowbar's model plus **`charge` (11)** and **`stab` (12)** — two
  sequences that exist for an attack the swing cycle never reaches. Its labels lie the same
  way the crowbar's do: sequences 4/5/7 carry the `knife1/2/3` whoosh events, so those are
  the MISS takes despite two of them being labelled plainly `attack2`/`attack3`.
- `v_saw.mdl` has **two sequences both labelled `reload1`** — 1.5 s firing `saw_reload.wav`
  and 2.444 s firing `saw_reload2.wav`. The events are what tell them apart: short top-up
  versus the dry-belt drill. Pairing them wrong makes the short reload run a second past its
  own animation.
- `v_penguin.mdl` is `v_squeak.mdl`'s six sequences exactly — the other half of the evidence
  that OpFor reskinned the squeak grenade.

**The penguin's live creature is deliberately the snark's, re-modelled.** `W_PenguinSpawn`
calls `W_SnarkSpawn` and swaps the model, and keeps the classname `monster_snark`. That is
load-bearing: `sh_wpn_hlsnark.qc:184` and `:244` use that exact string so a snark does not
bite or hunt another snark, and `sv_main.qc:1113` findchains it for round cleanup. Under a
separate classname, snarks and penguins would eat each other and a thrown penguin would
survive a round restart.

**Stated assumption:** there is no Opposing Force source on disk (verified — the SDK has no
`knife.cpp`/`saw.cpp`/`penguin.cpp`), and Sven ships no penguin so its manual does not cover
one. The penguin's behaviour and the knife's charged stab are inferences from the models'
own sequences, flagged as such in both file headers.

**The classname handover** (your call): `weapon_knife` and `weapon_m249` were held by the
Counter-Strike guns. A GoldSrc map placing either means the OpFor weapon, so those names now
spawn these, and the CS pair answers to `weapon_csknife` / `weapon_csm249`. No regression for
CS play — those guns are handed out by loadout, buy menu and debug spawn, none of which go
through a classname.

**Wiring an added weapon is nine coordinated hand edits, not five.** Beyond the manifest, the
two ID enums, `SV_DebugSpawnWeaponId` and the slot-ammo mirror, the ones with no compile-time
guard at all were: `cl_weapons.qc`'s CSQC equip chain, `sv_player.qc`'s per-slot equip
switches, `sv_weapons.qc`'s second utility table, `W_FireIsServerAutonomous`, and — the one
that would have been silent — **`sh_wpn_snowball.qc`'s utility ring**, whose own comment at
`:145-149` records the medkit and SOFLAM having shipped in neither of its two lists so that
`give medkit` "reported success and left you holding nothing".

### 3. Two folded-in findings

**The medkit's missing fire mode was misnamed.** Its comments called the gap "self-heal";
Sven's manual says self-heal is *impossible* (*"You cannot heal yourself with the medkit"*)
and that the secondary is **revive** — 50 stored health, dead players and friendly NPCs, and
*"you can only revive players and NPCs that haven't been gibed"*. So the note describing the
gap would have had us build the one behaviour Sven deliberately does not have. Revive is
implemented for **players**; NPCs are not, because a monster here does not survive its own
death in a revivable form (`sv_ai_gibs.qc` disposes of the body and there is no `AI_Revive`).
It reuses the respawn shape `sv_checkpoint.qc:175-187` established rather than inventing one,
and a new `.death_was_gib` latch implements the gib rule.

**A false alarm worth recording.** The pipe wrench and the new knife both test `self.button3`
to detect the charge release, while alt-fire is dispatched on `self.button1`
(`sv_weapons.qc:4216`) — which reads like the charged swing could never fire. It is fine:
`pr_cmds.c:190-193` maps `button3` to **bit 2**, the same bit `button1` is assigned from at
`:10394`. Checked before "fixing" it.

### Measured

- Three VMs **0 warnings**; seven-map regression (`desertcircle`, `hl_c01_a1`, `crossfire`,
  `crystal`, `sandstone`, `pizza_ya_san1`, `hc2_c2`) at **0 QC errors**.
- `[ai-selftest] weapon roster: **100 weapons, 0 missing rows, 0 mirror failures, BAD=0**`
  (was 97/0/0). Every other self-test BAD=0.
- `[satcheltest] manifest debug_order reaches every weapon: got=99 want=99 PASS`,
  `buy_order has no gaps or duplicates: 0 PASS`, and
  **`every advertised weapon can be given: got=0 want=0 PASS`** — the one that proves the
  three new guns are actually reachable, not merely listed.
- Audits: `optional_audit` **323 files** (was 320, +1 per new weapon), `check_serverfire`
  **33/67** (was 31/66: +2 server-autonomous for the knife and penguin, +1 client-notified
  for the SAW), `cvar_audit` **12** (baseline).
- The `sv_debug_weapons` grid spawns all three; their world models appear in the log beside
  the seven existing OpFor weapons, and all 97 weapon world models emit the same benign
  "not precached" warning there, so the new three are in the same position as their siblings.
- Credential scan **0** across the working tree.

### Owed in-game checks

- **The Gauss balls themselves.** Not measured: bots will not take the gauss
  (`sv_default_primary gauss` yields only a "model not precached" warning and the bot never
  fires it), and a headless client cannot be made to shoot. `sv_debug_weapons 1` now prints
  `[gauss] balls <site> at <pos> x<count>` at all four sites — fire primary at a wall and the
  `primary-wall` line must appear on **every** hit, which today never happens at all.
- **The ALIEN_FX wire change is verified by construction, not measured.** Two attempts to
  trigger a live alien effect headlessly failed (nothing attacked on pizza_ya_san1 over 180 s;
  a forced `cmd ai_spawn monster_alien_slave` never reached the server). It is a symmetric
  one-byte addition in a single file with the read placed before the early-return, but the
  check is owed: with `developer 1`, any creature attack must still print
  `[alienfx] events=N` with `noslot=0`.
- **Both new guns by eye** — the knife's charged stab (hold `+attack2` ≥0.8 s) playing seq 12
  rather than a normal swing, and the SAW's two reload drills picking the right sample: a
  top-up should run 1.5 s, a dry belt 2.444 s.
- **The penguin**: thrown penguins and thrown snarks must ignore each other, and both must
  clear on a round restart.
- **The medkit revive**: `+attack2` over a downed team-mate, 50 charge spent, `longuse`
  animation; and a gibbed (lethal-headshot) body must refuse.
- **The snark pickup is now a nest.** `w_sqknest.mdl` was on the mount all along —
  `sh_wpn_hlsnark.qc:53` recorded it as missing and that was wrong. Confirm the ground pickup
  looks like a nest rather than a lone snark.

### Not done, and why

**The CS Glock and G3SG1 animation placeholders cannot be fixed from static analysis.** Both
carry `// Animation frames (placeholder — user will tune)`. Their viewmodels in this tree are
**converted IDPO bakes whose frame names were destroyed** — every frame is literally
`frame0..frameN` — and the bakes do not correspond to their originals: `v_glock.mdl` has 187
frames against `cstrike/models/v_glock18.mdl`'s 443 across 13 sequences, and `v_g3sg1.mdl`
has 157 against 215 across 5. So the bake is neither a concatenation nor a fixed-rate
resample, and there is no way to recover the true ranges. The real fix is the migration the
crowbar already went through (`sh_wpn_hlcrowbar.qc:11-21`) — drive the mounted IDST model by
sequence index — but that **changes which model is displayed**, from the mod's own converted
asset to stock Counter-Strike, which is a visual change that was not asked for. Left alone
rather than replaced with another guess.

---

## PATCH 144 — func_platrot, NPC collision, the spore loader, the akimbo UZIs, pushables, the grapple, and two render options

Eight reports. Seven pinned to a line with the GoldSrc reference read off disk; the eighth
(water sides) could not be pinned because **no map in the corpus draws a texture named
`nodraw`, `NULL` or `skip`** — I scanned the texture and face lumps of every BSP in
`svencoop`, `svencoop_downloads`, `valve` and `quakers/maps`. It ships a diagnostic and the
general mechanism instead.

Two findings changed the shape of the work before a line was written:

- **The barnacle is innocent.** `mon_barnacle.qc` only ever calls `W_ApplyDamage` — it never
  `setmodel`s, moves or removes anything, and its victim filter already names `func_pushable`
  as something it exists to reject. What ate the crates is the **barnacle grapple weapon**,
  which pizza_ya_san2 carries three of. Same root cause as the pushable bug.
- **Teaching the touch dispatcher about crates would not have worked.**
  `SV_CheckTouchTriggers` runs *after* `PM_PlayerMove`, which has already clipped the
  into-the-crate component out of the player's velocity, so any handler reading
  `toucher.velocity` sees ≈0. The push had to come from **intent**.

### 1. `func_platrot` — the rotation was inverted, and it shipped two snapshots per trip

**The endpoints were swapped.** `CFuncPlatRot::SetupRotation` (plats.cpp:543-560) sets
`m_start = angles` (zero) and `m_end = angles + movedir*rotation`, then — for a **named**
plat, which all 9 in the corpus are — `pev->angles = m_end`. TOP carries the `rotation` key;
BOTTOM is zero; `GoUp` rotates toward `m_end`, `GoDown` toward `m_start`. The QC had
`plat_ang1` (TOP) `= '0 0 0'` and `plat_ang2` (BOTTOM) `= rotation` — exactly backwards, so
every named platrot rested 90° off Half-Life and spun the wrong way.

Measured on `hl_c01_a1` with the new `[plat]` probe (this class had no debug print of its own,
which is how the inversion survived):

```
[plat] "ele_2" rot=90 top=0 90 0 bottom=0 0 0 pos1=... pos2=... ang=0 90 0
```

`ang` is the spawn pose: the cage now rests turned, as GoldSrc leaves it.

**The static motion was a missing per-tick re-send.** `Mover_TravelTick` dirtied `SendFlags`
only on wedge / reverse / arrival — **the one mover tick in the tree that omitted it**.
`func_train` carries the same line with a comment describing this exact report; so do
`func_tracktrain`, `func_door_rotating`, `func_rotating` and `func_trackautochange`. So a plat
shipped **two** snapshots for a whole trip, and the client's TRAIN branch caps extrapolation
at 0.1 s — 216 units at speed 80 is 2.7 s, of which about 8 units were visible before it froze
and then teleported. Measured after: **172 mover ticks** for that trip, against a predicted
2.7 s × 64 Hz ≈ 170.

Also fixed on the same trip: the wedge pause stopped `velocity` but never `avelocity`, so a
blocked platrot kept turning while its translation was held.

### 2. Player↔NPC collision is now predicted

Monsters are `SOLID_SLIDEBOX` on the server and had **no CSQC representation at all** — not
one `SendEntity` in `sv_monsters.qc` — and CSQC traces run against a separate world, so the
predicted move walked through them and the snapshot shoved the player back out. `cl_driftlock`
does not cause that: its lock branch needs `!walking_on_ground`, so walking into a monster
always falls to the smoother, which *renders* the miss as a slide rather than a snap.

New `client/cl_monstersolid.qc`: a pool of `SOLID_BBOX` proxies driven from `getentity`,
reusing `cl_monstertrace.qc`'s existing modelindex whitelist, relinked in the same slot as
`PhysProp_RelinkHullsForPrediction` — immediately before `PM_PlayerMove`. Entities rather than
a trace wrapper because `sh_pmove.qc` has 29 raw `tracebox` sites and only one is inside
`PM_TraceHull`; a wrapper would have let you duck-stand-up into a grunt.

**The dead/corpse/scenery gate is exact and costs nothing.** `GE_ABSMIN`/`GE_ABSMAX` decode
from the networked `solidsize`, and `sv_ents.c:3580-3593` writes 0 for anything that is not
`SOLID_BBOX`/`SLIDEBOX`/`BSP` — which `COM_DecodeSize` turns into an **inverted** box. So
`absmax_z > absmin_z` is a same-frame read of `ent->v->solid` on the server. (Note this is not
`cl_monstertrace.qc:304`'s `bmin == bmax`, which does *not* catch these — the box is inverted,
not degenerate.)

Measured headlessly, `hl_c01_a1` then `pizza_ya_san1`:

```
[monsolid] on=1 pool=0 live=0 solid=0 flat=0  range=3 full=0     <- 3 live monsters, gated only by distance
[monsolid] on=1 pool=3 live=3 solid=3 flat=0  range=0 full=0     <- range cull lifted: 3 real hulls, every frame
[monsolid] on=1 pool=0 live=0 solid=0 flat=14 range=1 full=0     <- 14 rejected by the solidsize gate
```

The middle line is the feature working; the third is the corpse/non-solid gate discriminating
on a real map, not asserted.

**Server side: zero changes.** Every uncertainty — out of PVS, not whitelisted, inverted box,
pool full, out of range, cvar off — degrades to non-solid, which is today's behaviour, so it
cannot regress into the client-solid/server-not failure `cl_brushsync.qc:755-759` warns about.
`cl_monstersolid` defaults 1 and **is registered** (the cvar directly above it in the table
spent its whole life unregistered and therefore off).

### 3. The spore launcher credited five inserts as one

The animation was already per-spore; the ammo was not. `SH_SporeTickState` handed
`SH_StandardTickState` the same value for `reload_dur` and `reload_apply_time`, so the whole
magazine appeared in one statement at t = 6.5 s while five insert animations played. Now
credited one round per insert, from shared code both sides run off the same `wep_anim_start`,
with the `while` loop the shotgun uses so a frame hitch longer than one insert cannot eat a
spore. Firing mid-reload cancels, exactly as `CShotgun::PrimaryAttack` does — spores already
seated stay seated, which is the whole point of crediting them one at a time.

**Found while reading, fixed here:** `CAL_SPORE` pickups routed through `Ammo_TopUpMag`, which
only fills the magazine and caps at 5 — so the 20-round reserve the reload draws from was
**never refilled by any pickup in the game**. Inherited from when this classname aliased the
genuinely magazine-only grenade launcher.

### 4. Akimbo UZIs — one gun per shot, alternating

The weapon contradicted itself. `UZIAK_FIRE_DELAY 0.05` with the comment *"two guns
alternating… each barrel still cycles at its own 600 rpm"*, one hitscan per trigger tick, and
the server already ejecting brass from alternating sides — but the sequence pick returned the
**both-guns** animation every shot and the client nailed every effect to `+right`, so the
predicted casing side even contradicted the server's.

Now the tree's existing dual-wield convention (`cfddeagle`): `action_id & 1` → RIGHT, even →
LEFT, one expression consumed by the server fire path, the CSQC predict path and the display
frame. Sequences 13 (left) and 14 (right) are live for the first time, flash and smoke resolve
through `v_uzi.mdl`'s own two gun-root bones `Mini-uzi` / `Mini-uzi01` at the model's own
attachment offset, brass matches, and each shot plays a single-gun sample rather than the
both-barrels `fire_both` take. **Balance untouched** — the numbers were already written for it.

Sequences 10/11 (`reload_right` / `reload_left`) stay unused deliberately: they are for a gun
with two magazines, and this one has a single 64-round pool both barrels draw from, so there is
no state in which exactly one gun is empty.

### 5. `func_pushable` could not be pushed, at all

GoldSrc's `CPushable` is `SOLID_BBOX` + `MOVETYPE_PUSHSTEP`, so the **engine** generates the
touch while the player moves. This mod's players are `MOVETYPE_NONE` running the QC pmove, so
the engine produces no impact pairs for them, and the substitute dispatcher
(`SV_CheckTouchTriggers`) only knows `FL_MONSTER`, `SOLID_TRIGGER` and `func_button`. A
`SOLID_BSP` crate matches none — **`func_pushable_touch` has never once been called by a player
walking into one.**

Chasing GoldSrc's solid/movetype would not have fixed it (a player walking into a *stationary*
crate produces no engine motion on either body) and would have broken four things that work:
the CSQC replica is forced `SOLID_BSP`, the `.ltime` scheme the file header spends 20 lines on,
the self-sweeping world collision and buoyancy, and the `BRUSH_TYPE_TRAIN` carry.

So: a per-frame poll in `PlayerPreThink`, the fifth user of that slot, reading
`input_movevalues` while the intent still exists — before the pmove cancels it. Dispatch is
HL's: **push when NOT holding `+use`; `+use` is the pull path.** Two-arm target selection —
a short sweep of the player's own hull along the wish vector, then a flush-contact AABB test
with a direction gate for the case the player has *already* been stopped by the crate. Both
walk the spawn-time pushable list, and the whole poll early-outs on maps with no crates.

**The velocity glue is gone** (`sv_func_pushable.qc:469-470`). GoldSrc needs it because two
engine-moved bodies would interpenetrate; here the crate is genuinely solid on both sides, and
the write stamped the crate's speed onto the authoritative player every frame — clamping them
to as little as 60 u/s while CSQC predicted full walk speed, a guaranteed per-frame reconcile
error.

Measured with `sv_debug_pushable 2` (FORCE mode, added for exactly this — there is no way to
make anything walk into a crate on purpose on a headless server):

```
[pushable] shoved vel=27.8 -55.7 0 → 52.2 -105.5 0 → 73.8 -149.6 0 → 92.9 -188.2 0
crate origin      0 0 0 → 0.43 -0.87 → 1.25 -2.52 → 10.75 -1.60 → 102.65 -159.39
```

Intent → `Move` → velocity → the crate's own tick → the brush actually travels.

### 6. The grapple turned crates into weapons and then deleted them

**Measured, from the live map** rather than inferred:

```
[pushable] spawn: clearing stray map key weapon=1 (would read as a gun)   x5 on pizza_ya_san1
```

`.weapon` is a stock entvars field, so `"weapon" "1"` in the map lands as `WEP_DEAGLE`.
`W_GrappleHookTouch` read it and handed the crate to `W_PhysDropStart`, which swapped its
`SendEntity` from `solid_brush_SendEntity` to `dropped_weapon_SendEntity` — the CSQC type byte
changed, `CSQC_Ent_CleanupTypeChange` tore the brush down and re-dressed it as a pistol
("*they turn into another model*") — and `W_PhysDropThink` then removed it once the ODE body,
placed at the world origin because a GoldSrc submodel has `.origin '0 0 0'`, tripped the stuck
test ("*and then they vanished*").

Three narrow guards: clear `.weapon` at spawn (the file already documented that key as inert
for this class); gate the grapple's weapon paths on `e.touch == weapon_touch`, which is what
this mod stamps on a gun and a replicated brush never has; and never re-`movetype` or spin a
`SOLID_BSP` brush — pushables get a horizontal impulse instead, which is what
`W_GrappleTargetIsPullable` already declared them eligible for.

### 7. `r_shadows_bmodels` — models only, default on

`Surf_GenBrushBatches` already maps `RF_NOSHADOW → BEF_NOSHADOWS` and the depth/stencil passes
already skip those batches, and every brush-model entity passes through it whether CSQC or the
engine drew it. So one condition covers the class: `model->submodelof == r_worldentity.model`
is exactly "an inline `*N` submodel", the same test `r_pushdepth` uses three lines above. The
world keeps casting; only `func_*` stops. **Default 0 = models only.**

### 8. Water sides — `surf_info` and `r_hidetextures`

The name had to come from the surface, so: **`surf_info`** traces from the crosshair and prints
the texture name, the owning entity (worldspawn vs which `func_`, with its `*N` model), the
face normal and whether it is a top or a side, and the contents either side of it.
**`r_hidetextures`** is a comma-separated list of BSP texture names to draw as nothing —
consumed where FTE registers one shader per texture name, so it covers world faces and brush
entities alike, matches whole names case-insensitively (substring matching would make `water`
also hide `!water`, which is the distinction a mapper who textured the sides differently was
drawing), and can be set per-map from a map cfg.

**This item is not finished.** It needs one `surf_info` line from the water in question.

### Owed in-game checks

- **The platrot by eye.** Riding `hl_c01_a1`'s cage — carried up *and* around — and the
  360°/720° spirals on `hl_c16_a3`. The server numbers are right; smoothness is a client
  judgement.
- **Walking into a monster.** `cl_debug_driftlock 1`: the reconcile error should collapse to
  the noise floor. The hulls are proven to exist; nothing headless can walk into one.
- **The spore reload.** The magazine should step 1→2→3→4→5 about a second apart, and firing
  mid-reload should keep what is already seated. **Not measured** — bots would not take the
  weapon and the headless client cannot be made to press reload.
- **The akimbo.** Both guns flashing and ejecting alternately. In particular the two bone
  names must resolve on `v_uzi.mdl`; if `gettagindex` returns 0 the flash silently falls back
  to the camera-local position and the alternation is invisible. **Not measured** for the same
  reason as the spore.
- **Pushing a crate** by walking into it, and pulling one with held `+use`. The shove path is
  measured; the *contact* selection is not, because nothing headless will walk into a crate.
- **Grappling a crate** on pizza_ya_san1: it must move, not vanish.
- **`r_shadows_bmodels`** toggled on an `r_shadows 2` map.
- **`surf_info` at the water**, then one `r_hidetextures` value.

### Deliberately not in scope

- **The platrot's double carry and double rotation.** It is both `BRUSH_TYPE_TRAIN` (so
  `PM_CheckMovingPushers` carries server-side) and driven by `Mover_TravelTick` (which calls
  `Mover_PlatformCarry`), and client-side it is in both brush lists. Pre-existing, not what was
  reported, and each wants measuring before it is touched.
- **A monster `SendEntity` channel.** `getentity` already exposes the origin and the real hull
  losslessly; a new wire type would duplicate both for hundreds of monsters.
- **Client-predicted crate motion.** Needs the predicted-vs-authoritative arbitration doors
  have; the crate is capped at 400 u/s and the unpredicted half-RTT produces a *forward*
  correction the smoother already eats.
- **Asymmetric monster hulls.** `COM_EncodeSize` forces the networked hull square and
  symmetric in XY. Every `Monster_ClassHull` value already is; a map setting an asymmetric
  `minhullsize`/`maxhullsize` would give the client a different hull from the server's, and the
  client cannot detect it.

---

## PATCH 143 — desertcircle: the flag overshot its pole because the base never captured

Both halves of the report — "extended about 40 units too far" and "it's supposed to stop
and stay there and continue the level" — are **one fault with one cause**, and the cause
is nowhere near the flag.

### What the map actually does

Read out of the entity lump rather than guessed. Each of the four poles is a five-stage
chain, and only the first two of them were working:

| # | entity | what it does |
|---|--------|--------------|
| 1 | `momentary_rot_button flagbutton1` | the invisible lever you hold `+use` on |
| 2 | `momentary_door flag1` (`*14`) | a 64×64×24 lid **hidden in a shaft at z 1784**, nowhere near the pole |
| 3 | `func_pushable` (`*15`) | a 16×16×16 crate parked **on that lid** |
| 4 | `trigger_once` (`*16`), `spawnflags 4` | a volume **200 units above the crate**, `4` = "Pushables" |
| 5 | `multi_manager base1capmm` | the capture: 9 targets |

The lid rises, the **crate rides up with it**, and at 200 units the crate enters the
trigger. That is the capture — and it is also the only thing that stops the flag, because
one of `base1capmm`'s nine targets is `base1flagseto`, the `trigger_setorigin` that has
been carrying the visible flag sprite. Firing it a second time switches the follower
**off**, so the sprite stands at the masthead while the button's 1°/s auto-return quietly
winds the hidden lid back down underneath it.

Nothing lifted the crate, so stages 3-5 never happened: no capture, and no stop.

### Three faults, all on the crate's path

**(a) Moving brushes carried players and nothing else.** In GoldSrc the ENGINE carries
riders — `SV_PushMove` translates every entity whose groundentity is the pusher, or whose
box the pusher has swept into. Every mover in this tree is `setorigin`-driven (position-
exact, which is what a `momentary_door` needs) and `setorigin` does not run pusher
physics, so `Mover_PlatformCarry` had to do it by hand — and it walked the player list
only. The lid slid out from under the crate 264 units.
→ `Mover_PlatformCarry_Rider` in [sv_platform_carry.qc](server/sv_platform_carry.qc), over
a spawn-time list of `func_pushable`s.

**"Is it on us" is an AABB test, not a ground trace,** and that is not a shortcut — a
ground trace cannot answer it. The carry runs AFTER the brush has moved, so a lid that
rose 0.9 units this tick is now 0.9 units *inside* the crate resting on it: a downward
probe starts solid and reports nothing. GoldSrc has the same ordering and takes either of
two conditions, `groundentity == pusher` **or** box intersection. XY overlap plus a Z
window spans both.

**(b) The trigger would have thrown the crate away anyway.** `trigger_multi_touch` had two
arms of Half-Life's three-arm filter; the missing one is literally the map's only
spawnflag:

```c
(pev->spawnflags & SF_TRIGGER_PUSHABLES) && FClassnameIs(pevToucher, "func_pushable")
                                                          // triggers.cpp, MultiTouch
```

Its 0.1 s scan needed the same arm, and for a stronger reason than the player one: a
carried rider is repositioned with `setorigin`, and `PF_setorigin` relinks with
`SV_LinkEdict(ent, **false**)` — no trigger pass. A crate can be lifted clean through a
trigger volume without the engine ever calling `.touch`.

**(c) `trigger_setorigin` had no off switch.** Sven's changelog lists both halves as bugs
it fixed — *"not accepting explicit off input in constant mode"* and *"in constant mode
forgetting the copy/source entity when activated more than once"* — so a Constant one is
started, stopped and restarted by triggering it, and keeps its pairing across all of that.
`startmm` switches all four flag followers on at map load; each `baseNcapmm` switches its
own one off. PATCH 141's version self-started at spawn and ignored every later fire.
→ USE_ON / USE_OFF / USE_TOGGLE, and the self-start now only applies to an **unnamed**
Constant one, which is the only kind nothing can ever switch on.

### And a real 2 units, everywhere

`momentary_door`'s travel was `size - lip`. GoldSrc's is `size - 2 - lip`, and says why:

```c
// Subtract 2 from size because the engine expands bboxes by 1 in all directions
```

That expansion is `Mod_LoadSubmodels`' *"spread the mins / maxs by a pixel"*, which **FTE
inherits verbatim** ([gl_model.c:4513](../../../msys64/home/Lex/fteqw/engine/gl/gl_model.c#L4513)
and `:4551`) — so `.size` arrives padded here by exactly the 2 the reference game takes
back off. Measured on `flag1`: `pos2` z was 266, HL's is 264.

`func_door` and `func_button` had the identical line and are fixed the same way. **This is
the one change in this patch I cannot verify by eye headlessly** — it moves every
lip-derived door and button in the corpus 2 units, toward the reference. Say the word and
it comes back out; the momentary one is on the flag path and stays either way.

### Measured, end to end, on the final build

```
[chain] trigger_once("") -> multi_manager("base1capmm")   <- the capture, at last
[setorigin] "base1flagsprite" <- "flag1" src=0 0 200.64 -> 2800 -2548 320.64   <- frozen here
[momentary] door "flag1" frac=1.000 origin=0 0 264                             <- lid keeps going
[chain] multi_manager("base1capmm") -> trigger_changetarget("flagbuttonactivator1")
```

- Capture at lid z **200.64**; crate top 1824 + 200.64 = 2024.64 against a trigger floor of
  2024. The crate rides 1:1.
- Sprite freezes at z **320.64** and does not follow the lid to 264. The sprite is 256 px
  at `scale 0.2` = 51.2 tall about its centre, so its top lands at **346.2** against a
  flagpole that the BSP faces say runs z **96 → 352**. It stops just under the finial.
- Before: 120 + 266 = **386**, top at 411.6 — **~60 units above the pole**, which is the
  report.
- All nine capture targets fire: spawn push, both iterators, the objective text, the class
  teleporter's new destination, the fanfare, and `flagbuttonactivator1` at delay 1 —
  which writes `flag2` into `flagbutton2.target` and unlocks the next pole.

### Owed in-game checks

- **Pole 1 by hand.** Hold `+use` for ~7.5 s: flag climbs, stops at the top, fanfare,
  objective text changes, spawn moves to base 1.
- **Pole 2 through 4.** Proven by construction only — `flagbuttonactivator1` fires and
  `MomRotBtn_DriveDoors` reads `.target` live — but nobody has raised pole 2.
- **The flag does not sink.** Watch for 90 s after a capture; the lid returns underneath it
  and the sprite must not move.
- **A door and a button that use `lip`.** The 2-unit change, on anything with a tight
  recess.
- **A crate on a func_train / func_tracktrain.** The rider carry is not momentary-only.

### Deliberately not in scope

- **`8 "Everything else"`** on the trigger filter. Sven pairs it with `FilterIn` /
  `tinfiltertype`, which this tree has no equivalent of; honouring the bit bare would fire
  triggers off any stray gib. `base2`'s second trigger_once (`*12`, `spawnflags 10`,
  `tinfiltertype 1`) is an alternate capture path that needs it — base 2 still captures via
  its crate trigger `*19`, exactly like base 1.
- **Monsters and items as riders.** They have their own movement running against ours; a
  pushable is inert physics that only ever wanted the engine's carry.
- **`base1supply`.** `base1capmm` names it and the map contains no such entity — the
  mapper's dead reference, not ours. It logs `NO ENTITY WITH THAT TARGETNAME` and is
  correct to.

---

## PATCH 142 — the flag pole finder, and monster perception

### A correction to PATCH 141: SOLID_NOT made the flag pole worse

PATCH 141 made `momentary_rot_button` `SOLID_NOT` to match Half-Life
(`buttons.cpp:947-950`). That is correct, and it broke the button completely:
**`findradius` skips non-solid entities** (`world.c:1893`, unless
`FL_FINDABLE_NONSOLID`). So the tracebox missed the lever for being non-solid and the
cone fallback dropped it for the same reason. Between them, unfindable.

Three changes, and the mechanic question answered: **`+use` is the right mechanic, the
implementation was not.** Half-Life never traces for a use target — `PlayerUse` walks a
sphere and keeps the best facing dot — which is exactly why a non-solid invisible brush
is as usable there as a solid one.

- Every `momentary_rot_button` joins a spawn-time list (`sv_teleport.qc`'s pattern) which
  the aim poll walks. No solidity coupling left. `FL_FINDABLE_NONSOLID` set as well.
- The facing test measures to the brush's **nearest face**, HL's
  `UTIL_ClampVectorToBox`, not its centre. These levers are 8×8×128 poles: stand at the
  base of one and its centre is 60 units overhead, so both the range and the aim test
  were answering about somewhere the player is not looking.
- `momentary_rot_button` gained the `.use` remote control Sven documents ("trigger it in
  0.1 s intervals"), which it never had — one pulse is worth one 0.1 s tick, matching
  `CMomentaryRotButton::UpdateSelf`.

Driven headlessly with `sv_debug_firetarget flagbutton1` + the new
`sv_debug_firerepeat` / `sv_debug_fireinterval`:

```
door "flag1"              frac 0.013 -> 0.990   origin z 3.5 -> 263.4
sprite "base1flagsprite"  z 120 -> 386          X/Y untouched
```

The full 264-unit travel, Z only, from the authored position — `Constant | Lock Offsets |
Copy Z Axis | Skip Initial Set` doing exactly what the map asks.

### Vision: the distance was right, the cone did not exist

`sv_ai_sight` 2048 is Half-Life's own `m_flDistLook`. But `AI_CanSee` was a bare
line-of-sight trace with **no field of view anywhere** — the only `FInViewCone` reference
in the tree is the *reverse* test the alien slave uses. Monsters were not blind, they
were omniscient inside 2048, with no blind side to flank and no way to sneak past.

`AI_InViewCone` added, applied **only on acquisition**. HL draws the same line: `Look()`
tests `FInViewCone && FVisible` while `FVisible` alone has no cone, so once a monster has
you it tracks, shoots and validates cover from any angle. Values read out of the SDK
rather than guessed — `hgrunt.cpp:991` 0.2, `barney.cpp:418` and `scientist.cpp:682`
VIEW_FIELD_WIDE, `agrunt`/`bullsquid` 0.2, `controller.cpp:373` and `turret.cpp:271`
VIEW_FIELD_FULL. Default 0.5, CBaseMonster's own.

**The negative values are the trap**: `VIEW_FIELD_WIDE` is **-0.7** (270° across) and
`VIEW_FIELD_FULL` is **-1**, so the first version's `if (ai_fov <= 0) return TRUE` would
have silently given every talker a 360° head. New `AI_SenseSelfTest` asserts all seven
cases including both negative ones, plus pitch-independence and that the cone follows the
body yaw rather than the ideal. **BAD=0.** `Turret_CommonInit` carries the full cone so
all three turret variants get it — a ceiling turret with a forward cone would stop
covering its room and cannot walk round to look.

### Hearing: two inputs became a sense

Before: a gunshot within 1280 (rate-limited to 4 Hz) and being hit. That was all. No
footsteps, no world sounds, no danger, and hearing only ever produced
`SCHED_ALERT_FACE` — they turned their heads and never went to look.

- `AI_HeardNoise(org, radius)` is the general form; gunfire now goes through it.
- `AI_HeardFootstep` from `PlayerPreThink` — 640 units running, 320 walking, **silent
  crouched**, gated on `FL_ONGROUND`. Emitted from the server's own velocity rather than
  from wherever the footstep *sound* is played, because that is CSQC: the client decides
  what a footstep sounds like, the server decides who heard it.
- New `SCHED_INVESTIGATE_SOUND` + `TASK_GET_PATH_SOUND`: walk to the noise, look around,
  wait. Gated hard — no enemy, not scripted, not static, not escorting, not guarding, 8 s
  rate limit, and a 128-unit distance floor so a monster standing on the noise does not
  re-select for the whole wait. `ai_soundpos` is kept separate from `ai_lastseenpos`
  because "where that noise was" and "where I think my enemy is" are different questions,
  and conflating them is why hearing could only turn a head.

### Danger sounds — the grenade reaction

`COND_HEAR_DANGER`, distinct from `COND_HEAR_SOUND` because the responses are opposite: a
gunshot makes a monster look *towards* it, a live grenade makes it run *away*. Nothing in
the tree emitted one, so grenades have always been free damage against anything not
already moving.

`AI_DangerScan` runs at HL's own 0.2 s cadence (`CGrenade::DangerSoundThink`) and finds
live explosives by `.proj_type`, gated on `SendEntity == projectile_SendEntity` — **the
type alone cannot be the test, because `PROJ_TYPE_HLGRENADE` is 0 and so is every unset
float, which would declare all 568 entities on desertcircle a live hand grenade.** A scan
rather than a hook at each throw site: the throw sites are spread across a dozen shared
weapon files, and a hook in each is a hook someone forgets in the thirteenth.

Cover is taken **from the grenade, not from the thrower** — they are usually in opposite
directions. `Cover_Find` was split into `Cover_FindFrom(m, pos, eye)` so a place can be a
threat, which is how HL feeds `CSound::m_vecOrigin` into the same finder. It outranks
melee and the rationed shot in the combat ladder, and has its own rung below for a
grenade thrown into a room nobody has been alerted in yet.

### Cover when the squad will not let you shoot

**The missing GoldSrc behaviour.** The attack slots ration who may fire so a squad does
not form a firing line — that worked — but a monster *refused* a slot fell through to
"face, close, reposition" and stood in the open holding a rifle it was not allowed to use.
HL's grunt takes cover or establishes a line of fire instead, and that single rule is most
of what makes a GoldSrc squad look alive.

`Cover_ScheduleIfCrowded` added, with `Squad_SlotsFree` — a **read-only** twin of
`Squad_OccupySlot`, which it has to be: asking with the real function would hand the
monster the slot it is asking about and answer its own question wrong. Offered as a class
trigger, not put in the generic ladder, per the doctrine at the top of `sv_ai_cover.qc`.
Wired into the grunt.

### Also fixed

The schedule self-test has been reporting **BAD=2** on every boot: `TASK_GET_PATH_GUARD`
and `TASK_GET_PATH_ROAM` were missing from `AI_TaskOpHandled` while the interpreter has
had cases for both all along. Cosmetic, but a self-test that is permanently unhappy is a
self-test nobody reads. Now **BAD=0** across every suite.

### Verified headlessly

Three VMs 0 warnings. Seven maps 0 QC errors. All self-tests BAD=0 (`sense`, `cover`,
`schedules 34 built, 150/384 tasks`, squad, weapon roster, squadmaker keys). Audits at
baseline (319 / 31-66 / 12). Movement unchanged and healthy on desertcircle with a live
client: `moving=54-60`, `walkmove=54-60`, **`fails=0 sidestep=0 blocked=0`**.

### Owed in-game checks

**None of the perception work can be exercised headlessly** — the headless client
connects as a spectator, so `AI_ValidEnemy` rejects it, no monster ever attempts an
acquisition, and every `sense:` counter reads 0 by construction. The cone is covered by
the synthetic self-test; the rest is reviewed, not observed.

1. **Flag pole** — hold `+use` at pole 1 for 7.5 s. The remote-control path is proven; the
   *aim* path is not.
2. **Sneak up on a grunt** from behind, and be seen when you come at him from the side.
3. **Throw a grenade into a squad** and watch them scatter rather than stand in it.
4. **Pin a squad**: two should fire and the rest should break for cover, not queue.
5. **Run past an idle patrol** and see one walk over to look; then crouch past and see
   nobody react.
6. Everything owed by PATCH 141, which is unchanged.

---

## PATCH 141 — desertcircle: the wire, the doorway, the teleport, the UZI, the flag

Five reports from one session of play. Four were QC. The first was not, and it invalidates
part of what PATCH 139 and PATCH 140 claimed.

### THE BODYGROUP HAS NEVER BEEN NETWORKED — a correction to PATCH 131, 139 and 140

Reported as "there is a grunt who is sniping me but in the hands is an assault rifle", on
`desertcircle`'s squadmaker marksmen (`monster_male_assassin`, `models/descrcl/massnf.mdl`,
`weapons 8`).

The server was right the whole time. Measured with the new `[bodygroup]` probe line:

```
[bodygroup] monster_male_assassin rig=massnf(massn) weapons=128 m16=3 -> armed=3 gone=6
[bodygroup]   wb=3 head=0 | mp5=0 sg=-1 m40=1 rpg=-1 saw=-1
```

`armed=3` composes weapon submodel 1, and submodel 1 on that rig is genuinely a scoped
bolt-action — its six meshes skin to `mag+blob`, `recfinal`, `Stock`, **`bolt`**,
**`Scope`**, `mountingfinal`. The M16 is submodel 3 (`P_M16a1.bmp`). The rig table, the
bit-8→`HGRUNT_SNIPER` translation and the selector were all correct.

**The byte never left the machine.** `PEXT2_BODYGROUP` was defined (`protocol.h:112`),
written (`sv_ents.c:1067`, `:1390`), read (`cl_ents.c:934-943`), handed to the renderer
(`cl_ents.c:5406` → `gl_hlmdl.c:1791`, `:1927`) and listed in `PEXT2_CLIENTSUPPORT` — but
`PEXT2_CLIENTSUPPORT` is only the "warn about unknown bits" set, **not the advertised
one**. `Net_PextMask` never named it, so neither side ever offered it, negotiation always
returned 0, every `pext2 & PEXT2_BODYGROUP` gate was false, and **not one bodygroup byte
has ever been sent.** Every studiomodel in the game has always drawn submodel 0.

This is the *same bug* Patch 125 hit with `PEXT2_BONECONTROLS`, documented in a comment
five lines above the missing line. Patch 131 reproduced it exactly.

Consequences to be honest about:

- **PATCH 139's and PATCH 140's bodygroup work was never visible.** Every "now holds the
  right gun" claim in those two sections was verified server-side only. They were correct
  about what the server composes and wrong to imply anything reached the screen.
- The M4 that PATCH 140 said was "actually gone" was not gone. `armed=16` was being
  computed and `body 0` was being drawn.

Fixed in `common/net_chan.c` (advertise the bit, in the replacementdeltas block beside
`PEXT2_BONECONTROLS`) and `server/sv_ents.c:1129` (the `UF_BONEDATA` survival guard names
all three riders now, not two). Engine rebuilt, both binaries deployed; the previous ones
are kept as `*.prepatch141.exe`.

### weapons bit 4 — the M16 grunt was half-implemented

`HGRUNT_GRENADELAUNCHER` (4) has driven the M203's flat contact shot since this file was
written, but the **body** never moved, so a `weapons 5` grunt — Sven's "M16 + GL" — launched
rifle grenades while visibly holding an MP5. The M16 submodel exists on three of the four
rigs (descrcl `hgrunt` [0], Sven `hgrunt` [0], `massn`/`massnf` [3], `hgrunt_sniper` [3]);
Half-Life's own rig and gearbox's OpFor rig have none, so those keep the MP5, which is what
HL shows. `desertcircle` has two (`base2sm3`, `castlesm4`).

The selector tests it **last**, because bit 4 travels with bit 1 (5 = MP5|GL), so a map
writing 5|8 still gets the shotgun it asked for.

### The doorway jam

Three mechanisms, of which two were in the path-advance loop and had the same root: it
decided twice per tick whether to throw a waypoint away, and **both decisions were purely
about distance**. Distance cannot see a wall.

1. **The "already past it" skip** (`sv_ai_move.qc`) read "am I within one link-length of the
   next node, straight-line, through anything" — in a loop that can discard up to 24
   waypoints in one tick. On a room→door→doubling-back-corridor shape a monster in the room
   is routinely closer to the corridor node than the doorway node is, so the doorway was
   deleted and it aimed diagonally at wall. Now gated by `AI_LegClear`, a hull box-sweep.
2. **`AI_NODE_REACH` is 48 against a 32-wide hull**, so a node retires a body-and-a-half
   early, and because the step is taken along `ai_yaw_ideal` rather than the body angle the
   travel vector snaps to the next node on the *same tick* — 30 units of travel straight
   into the frame. Now a waypoint is held while the next leg is blocked from here and clear
   from the waypoint, which is exactly "the gap is still in front of me" and nothing else.
   **`AI_NODE_ONNODE` (16) is what makes it terminate** — without it this livelocks, and
   did: measured `holdveto=20` in a 20-tick window, one monster re-holding the same
   waypoint every tick.
3. **A blocked monster used to park solid in the aperture for a full second**
   (`SCHED_CHASE_ENEMY_FAILED` is `STOP_MOVING / ACT_IDLE / FACE_ENEMY / WAIT 1` while still
   `SOLID_SLIDEBOX`), which is what turned one badly-angled body into a plug for the whole
   squad. It now spends that tick backing out — straight back, then the two rear quarters.

Measured on `desertcircle` with a live headless client, per 20-tick window:

| | before guard | after |
|---|---|---|
| `moving` | 20 | **40** |
| `walkmove` / `fails` / `sidestep` | 20 / 0 / 0 | **40 / 0 / 0** |
| `blocked` | 0-1 | **0** |
| `legs: traces / skipveto / holdveto` | 40 / 0 / **20 every tick** | **bursts of 17 / 4 / 6, then 0** |

The vetoes firing in bursts and then dropping to zero is the shape wanted: they intervene
at tight geometry and cost nothing in open country.

### The teleport burial

`trigger_teleport_resolve` set `dest.origin + '0 0 1'`. Half-Life's `TeleportTouch` is
`tmp = target->origin; if (IsPlayer()) tmp.z -= pOther->pev->mins.z; tmp.z++;` — the `z++`
was here and the `-= mins.z` was not, which with `sv_hull_height 72` is **36 units out of a
72-unit hull**. The FGDs confirm the conventions differ on purpose: `info_player_start`
inherits `PlayerClass`'s `-36..+36` (origin at centre) while `info_teleport_destination`
**overrides** it to `-8 -8 0, 8 8 16` (origin at the feet). The mod's own spawn path already
honours the other half of that split (`sv_player.qc:3383-3393`).

Fixed in the shared pmove so it is duck-aware exactly as HL's `pev->mins` is, gated on
`Map_IsGoldSrcShared()` because `nettest.fgd:113` declares the destination as a symmetric
64-cube. Same one-line bug fixed in `sh_wpn_opdisplacer.qc` for the OpFor displacer targets.

**The old unstick probe had never fired once.** It traced *downward* from a point already
inside the floor, and FTE returns `fraction == 1` on an all-solid trace (`q1bsp.c:1018`
returns before `fraction` is assigned), so `trace_fraction < 1` was never true. Rewritten to
trace up, which is the direction that leaves solid.

### The UZI onto key 1

Moved with its akimbo twin from SECONDARY to PRIMARY. The table's own rule already said so:
buy categories *subdivide* the four slots and `BUYCAT_SMG` is a PRIMARY subdivision — these
two were the only weapons in the tree that were `BUYCAT_SMG` **and** `WMF_SLOT_SECONDARY`.
Sven files the UZI with the handguns, but that is a five-slot HUD where a slot holds several
weapons; here one slot holds one weapon, so "same slot as the pistol" meant "evicts the
pistol". Five places had to move together (manifest, both pickup entities' `.weapon_slot`,
and the refresh cases) or `weapon_touch` and the slot-ammo bridge disagree — the failure
`sv_goldsrc_pickups.qc:157-164` warns about. Both runs left contiguous: PRIMARY 1..61,
SECONDARY 1..16.

### The flag pole

`momentary_rot_button` / `momentary_door` / `trigger_setorigin` / `env_sprite` are all
implemented; the mechanism failed in four separate places.

1. **The button rotated about the map origin.** `flagbutton1..4` have no `origin` key and
   their BSP submodels carry `origin 0 0 0` with absolute baked bounds. Writing `.angles`
   swings the brush about `(0,0,0)`: model `*1` is 3806 units out, so at its authored 12°/s
   it moved **~80 units per tick**. The 96-unit aim trace lost it after one frame, the claim
   released, auto-return wound it back — holding `+use` moved the flag about half a unit.
   Now: rotate only when there is a real pivot; track the fraction either way.
2. **The levers were solid.** HL is `SOLID_NOT` unless Door Hack (`buttons.cpp:947-950`);
   `SV_InitReplicatedSolidBrush` forced `SOLID_BSP`, putting four invisible collidable posts
   at the flag poles.
3. **The aim cone ranked by `.origin`**, which for these is `(0,0,0)` — so the dot pointed at
   the map origin and the 0.6 gate could never pass. Now the AABB midpoint, the same
   correction `sv_use.qc:377` already carries.
4. **`trigger_setorigin` could not do what the map asks.** Its flag 1 was read as "keep
   angles"; Sven's flag 1 is **Constant**. desertcircle's four movers are **1545 = Constant |
   Lock Offsets | Copy Z Axis | Skip Initial Set** — "leave the flag sprite on the pole, then
   follow this hidden brush's height forever". Rewritten to the real flag set (all ten bits,
   plus `offset` / `angleoffset`), with the lock stored per-target. A Constant one self-starts,
   because nothing on that map ever triggers it.

The lever sound is also emitted now — it was resolved and precached and then never played.

The **sprite** was cleared: `sprites/descrcl/scteamflag.spr` is present and is a real HL
sprite (`IDSP` v2, 256×256, 20 frames, type 3 ORIENTED, texFormat 3 SPR_ALPHTEST), a format
FTE loads natively, and `env_sprite` honours its `spawnflags 1` START_ON. Nothing was wrong
with it that the frozen `trigger_setorigin` did not explain.

### Verified headlessly

Three VMs, 0 warnings. `optional_audit` PASS (319 files), `check_serverfire` PASS (31/66),
`cvar_audit` 12 = baseline. Manifest orders contiguous. Seven maps — `desertcircle`,
`hl_c01_a1`, `crossfire`, `crystal`, `sandstone`, `pizza_ya_san1`, `hc2_c2` — **0 QC
errors**; the `no spawn function` notices are the nine pre-existing unimplemented classnames
(`speaker`, `func_tankmortar`, `anti_rush`, …), none of them touched here, and `desertcircle`
reports zero. A live headless client ran 150 s on `desertcircle` with the new protocol
extension negotiated: no `Host_EndGame`, no unknown-bit complaint, no disconnect.

### Owed in-game checks

1. **The marksman's gun.** A `desertcircle` tower/squadmaker sniper must now visibly hold a
   *scoped bolt-action*, not a rifle. This is the one that proves the engine fix — the server
   was already right, so only the screen can confirm it.
2. **Every other bodygroup in the game**, for the same reason: Barney drawing and holstering,
   a disarmed corpse going empty-handed, the shotgun grunt, the SAW grunt, the RPG grunt.
   None of these have ever been seen working.
3. **A `weapons 5` grunt** (`base2sm3`, `castlesm4`) holding an M16 and lobbing M203 rounds.
4. **The doorway.** Fill a base room and watch them file out. Counters say clean; only the eye
   can say "no longer comical".
5. **Both class teleports** — feet on the floor, and a native-map teleport still correct.
6. **The UZI on key 1** from the grenadier teleport, a floor pickup while holding a pistol,
   and the SMG buy screen not dropping your sidearm.
7. **The flag.** Hold `+use` at pole 1 for 7.5 s: lever sound, the flag rises 264 units, no
   invisible post to bump into, slow decay on release.
8. **`weapon_m16` M203 rounds** — still owed from PATCH 140.

### Not done, and why

- **The other three movement causes** — monster-vs-monster yielding, `func_monsterclip`
  respect at path-request and collision time, and the stale `NAV_LINK_DIST = 2304` "goal is
  close" beeline fallback. Scoped out deliberately; the reported symptom is the doorway.
- **Multi-button sync** for `momentary_rot_button` (HL's `UpdateAllButtons`), and `master` /
  `use_type` on both momentary classes. Unused by this map.
- **`cycler_sprite`'s frame wrap.** `sv_cycler_sprite.qc:71-72` claims FTE wraps sprite frames
  and `sv_env_sprite.qc:92-95` proves by measurement that it does not, so `cycler_sprite` will
  spam `no such frame N`. Real, adjacent, untouched.

---

## PATCH 140 — the three deferrals: sniper ballistics, the RPG grunt, and weapon_m16

The three items PATCH 139 recorded under "Not done, and why", asked for by name. Two of
them turned out to be mostly already present *in the models*, and the third exposed a
bodygroup bug that was bigger than the one it was blocking.

### A correction to PATCH 139

PATCH 139 said converting `Grunt_BodyInit` to stem matching fixed the "low quality looking
assault rifle". **It did not** — it only fixed the *shotgun* grunt. Making the branch run
still composes body 0 for an ordinary grunt, and body 0 on `models/descrcl/hgrunt.mdl` is
the M4. The symptom survived the fix and is only now actually gone. Measured before and
after on desertcircle: `weapons=1 body=20 → sub=M4`, now `body=16 → sub=MP5`.

### What the models already carried — measured, not assumed

Dumped from the studio headers rather than inferred:

| sequence | act | frames / fps | events |
|---|---|---|---|
| `crouching_m40a1` / `standing_m40a1` | 28 | 13 @ 15 = 0.867 s | **one** (`f1:e4`) |
| `rpg_shoot` (+ `rpg_idle`/`rpg_aim`/`rpg_reload`) | 28 | 16 @ 30 = 0.533 s | **one** (`f10:e4`) |
| HL `crouching_mp5`, for contrast | 28 | 13 @ 20 | three (`e4 e5 e6`) |

Both specialist sequences raise `GRU_AE_BURST1` exactly once and the M40A1 runs slower than
the MP5, so the model already *is* the single-shot and the bolt cycle. Neither attack needed
a firing loop — only a branch in the two places the loadout is read, plus the ballistics.

### Three rigs answer to the stem `hgrunt`, and no two lay out the same

| rig | seqs | `crouching_m40a1` | `rpg_shoot` | weapons | index 0 |
|---|---|---|---|---|---|
| `Half-Life/valve/models/hgrunt.mdl` | 82 | no | no | n=3 base=4 | MP5 |
| `svencoop/models/hgrunt.mdl` | 95 | **yes** | yes | n=6 **base=5** | M16 |
| `svencoop/models/descrcl/hgrunt.mdl` | 88 | no | **yes** | n=5 base=4 | M4 |

The old formula describes the first and only the first. `Grunt_BodyInit` now resolves a
per-rig index table and tells them apart with `AI_SeqNameExists` — **`crouching_m40a1` is
the marker for the six-weapon base-5 rig**, because the M40A1 *is* the sixth submodel.
`rpg_shoot` is deliberately *not* the marker: that was the first attempt and desertcircle's
grunts came out holding an M4 anyway (`body=20`), because that rig carries the whole RPG
sequence set and still uses base 4.

**Which rig is live, measured:** `sv_ai_selftest 1` prints a sequence count per rig, and
`models/hgrunt.mdl` reports **82** — Half-Life's. `fs_addons.txt` lists `steam:Half-Life/valve`
above `steam:Sven Co-op/svencoop` and valve wins the name. So the Sven-rig M16 bug is
**latent, not on screen today**; the desertcircle one was live and is what was reported.
`models/hgrunt_opfor.mdl` reports **73**, which is Opposing Force's rig (Sven's is 75) — and
on that one index 0 genuinely *is* the MP5, so that branch keeps 0 as its default.

`models/hgrunt_sniper.mdl` is a fourth stock Sven rig that matched **no branch at all**
(the `!Rig_StemIs(mdl, "hgrunt_")` guard pushed it past the generic branch and no specialist
claimed it), so it fell to `else return;` and wore an MP5 whatever the map asked. It now
resolves.

### Verified headlessly

- **Bodygroups, desertcircle:** `weapons=1 → body=16 (MP5)`, `weapons=64 → body=12 (RPG)`,
  `monster_male_assassin weapons=128 → body=3 (M40A1)`. All three previously wrong.
- **Bodygroups, sc_persia** (57 grunts, 17 assassins): assassins `weapons=128 body=3`;
  `hgrunt_opfor weapons=5 → body=128 (MP5)`, `weapons=8 → body=32 (spas12)`.
- **Sequence resolution:** `sv_ai_selftest 1` reports `crouching_m40a1`/`standing_m40a1`
  present on `massn.mdl` (53 seqs) and `hgrunt_sniper.mdl` (51), `standing_saw`/`crouching_saw`
  present on `hgrunt_opfor.mdl`, and all three MISSING on Half-Life's `hgrunt.mdl` — which is
  what routes it to the fallback branch. The probe list now carries these names permanently.
- Three VMs at 0 warnings; `optional_audit` PASS (319), `check_serverfire` PASS (31/66),
  `cvar_audit` 12 = baseline before the three new cvars.

### Owed in-game checks (this patch)

1. **A sniper actually snipes.** `ai_spawn monster_male_assassin 1 8` (or a desertcircle
   tower). He must play `crouching_m40a1`/`standing_m40a1`, fire **one** round per sequence
   at 40 (`sv_ai_sniper_dmg`, Sven's own `sk_massassin_sniper`), gap ~2 s between shots, and
   the report must be `weapons/sniper_fire.wav`, not the MP5. **A double-fire would mean a
   rig raising codes 5/6** — the guard should prevent it, but it has not been seen.
2. **The rocket flies.** `ai_spawn monster_human_grunt 1 64`. A rocket must leave the muzzle,
   trail, and explode with the full `env_explosion` visual. **This has never been observed** —
   see the gap below.
3. **The rocket credits the grunt.** Kill yourself with one and check the killfeed names him
   rather than showing `KILLFEED_NO_ATTACKER`. This is the one thing that made reusing
   `TankRocket_Launch` wrong, so it is the one thing most worth looking at.
4. **He will not frag himself.** Walk inside 256 units of an RPG grunt; he must stop launching
   and fall back to melee or chase rather than firing into his own feet.
5. **`weapon_m16` is the M16 everywhere.** `wep_give m16` and a map-cfg equip (`crystal` and
   `hl_c05_a1` both list it) must both hand over `v_m16a2.mdl` with a 30-round mag and **2**
   M203 rounds — the aux pool was never seeded on this path. Then walk over `ammo_ARgrenades`
   and confirm it refills.
6. **The SAW is in his hands.** `pizza_ya_san1`'s shop owner is `weapons 16`; he has mimed a
   SAW since that patch while holding an MP5. Only the OpFor rig has the submodel.

### Not done, and why

- **The firing paths were never exercised.** Monster combat needs a live in-world player and
  the headless client did not reach one in this session — it connected and stayed
  `solid=0 movetype=0` for minutes on both `crossfire` and `hl_c01_a1`. So the loadout →
  bodygroup → sequence-name chain is verified end to end with real numbers, and everything
  downstream of `GRU_AE_BURST1` — the rocket entity, the sniper round, the min-range veto,
  the cadence — is **reviewed but unobserved**. Checks 1-4 above are the whole of it.
- **No scope, falloff or bolt audio for the sniper grunt.** The shot is single, tight and 40
  damage; the player M40A1's penetration/falloff model (90→70 over 8192,
  `W_PenetratingHitscanShoot`) stays player-only. Monsters have no penetration path.
- **`rpg_aim` / `rpg_idle` are not posed.** Only `rpg_shoot` is wired, because it is the one
  tagged act 28 and carrying the fire event. The aim and idle sequences would need an
  activity of their own.
- **desertcircle's RPG grunts will fire from an MP5 pose.** Their rig has the RPG submodel and
  the `rpg_*` sequences but `AI_SetSequenceNamed` picks by name and that rig's `rpg_shoot`
  *is* present — so this should in fact resolve. Worth an eye during check 2.
- **The Sven-rig M16 bug is fixed but unreachable.** Valve's `hgrunt.mdl` wins the name on this
  install. Unmount valve, or ship a map naming `svencoop/models/hgrunt.mdl` by path, to see it.

---

## PATCH 139 — desertcircle follow-up: the equip path gave stand-in weapons, and four grunt bugs

Reported as "the start teleports give weapons that alias to similar guns rather than the
actual ones — I think we HAVE the actual weapons", and "the grunts carry a low quality
assault rifle but fire shotguns, don't see you from far away, and always open with a
grenade". Both reports were correct. The weapons one was a half-finished migration; the
grunt one turned out to be four unrelated bugs.

### Owed in-game checks (this patch)

1. **The two start teleports hand out the real guns.** Sniper class → M40A1 (scoped,
   5-round) + 9mm handgun + 3× `ammo_762`; grenadier class → UZI (32-round) + hand grenade
   + `ammo_9mmbox`. Check the viewmodel is genuinely the M40A1 and the UZI, and that the
   ammo pickups actually top them up — the ammo routing was the half that would have
   silently swallowed your reserve.
2. **A shotgun grunt looks like a shotgun grunt.** desertcircle's grunts are
   `models/descrcl/hgrunt.mdl`, whose bodygroup 0 is an M4; the shotgun submodel is index
   1. Confirm `weapons 8`/`10` grunts visibly carry the shotgun they fire.
3. **The tower marksmen snipe instead of firing buckshot.** They are still invisible and
   unkillable by design (PATCH 138 check 2), so judge by the SOUND and the damage pattern:
   a single crack, not a shotgun blast.
4. **First contact is gunfire, not a grenade.** Walk into a grunt's view. The opening move
   must be shooting or taking cover; a grenade should only appear once the fight has been
   running a couple of seconds AND the thrower is standing still.
5. **The doubled sight range is affordable.** `sv_ai_sight` went 1024 → 2048, which also
   quadruples the area in which idle monsters wake. Watch the frame time on the busiest
   maps; `sv_ai_sight 1024` restores the old behaviour.

### Verified statically (file evidence, not inference)

- **The equip path and the pickup path handed out DIFFERENT GUNS for the same classname.**
  `weapon_sniperrifle` and `weapon_uzi` already had real implementations that map-placed
  pickups used (`sh_wpn_opsniperrifle.qc:312`, `sh_wpn_svuzi.qc:237`), but
  `game_player_equip` resolves through `WeaponManifest_IdFromString`, an ORDERED chain in
  which an older stand-in block sat above them: `sniperrifle -> WMF_WEP_CSAWP`,
  `uzi -> WMF_WEP_CFMAC10`. Seven keys were shadowed this way — also `uziakimbo`,
  `minigun`, `pipewrench`, `sporelauncher`, `eagle`.
  The file warns about exactly this ("ORDER MATTERS, these tests run first and would keep
  winning if the keys stayed here") and five keys had already been moved; these seven were
  missed. The **ammo** half had already been migrated —
  `sv_goldsrc_ammo.qc` calls them "the nine promoted out of the alias block" and routes
  `CAL_762 -> WEP_SNIPERRIFLE` — so the two halves disagreed and the alias half won.
- **Promoting alone would have eaten your ammo.** `Ammo_GiveToCarried` still routed
  `CAL_762` to `WEP_CSAWP` and `CAL_556` to `WEP_M249` ONLY, so a desertcircle sniper
  banking three `ammo_762` would have topped up a weapon they no longer carried. Both
  halves are now "fill both that you carry", the shape `CAL_9MM` and `CAL_URANIUM` already
  used.
- **The M4 look, dumped from the model.** `Grunt_BodyInit` matched exact model paths, so
  `models/descrcl/hgrunt.mdl` matched nothing and kept bodygroup 0. Read out of the file:
  `heads n=4 base=1`, `weapons n=5 base=4 : [0] M4 [1] shotgun [2] blank [3] RPG [4] MP5`.
  Bodygroup 0 is literally an M4 — the reported "low quality looking assault rifle" — while
  the firing path read `HGRUNT_SHOTGUN` correctly. Its bases are the same 1 and 4 as stock
  `hgrunt.mdl`, so the formula was always right and only the compare was wrong.
  (Stock `hgrunt.mdl` is confirmed unaffected: HL's `valve/models/hgrunt.mdl` is
  `heads n=4 base=1, weapons n=3 base=4`, exactly what the branch says. Note Sven ships a
  DIFFERENT `hgrunt.mdl` at 5 heads / 6 weapons — if that one ever wins the search path,
  this branch is wrong for it.)
- **`weapons` bit 8 is class-dependent, and nothing here knew.** From the two
  `weapons(Choices)` blocks in `sven-coop.fgd`: on `monster_human_grunt` 8 = Shotgun,
  64 = Rocket Launcher, 128 = Sniper Rifle; on `monster_male_assassin` 8 = **Sniper
  Rifle**, 256 = Sniper-No drop. One bit, two guns. Every assassin a map armed as a sniper
  was firing a shotgun. 64 and 128 had no constants at all, so four desertcircle
  squadmakers on `weapons 64` silently defaulted to an MP5.
- **The sight distance was half of Half-Life's, with a comment claiming it WAS Half-Life's.**
  The SDK is `m_flDistLook = 2048.0` (`dlls/monsters.cpp:2042`), documented in
  `dlls/basemonster.h:100` as "distance monster sees (Default 2048)"; only CLeech overrides
  it. `sv_ai_sight` was 1024.
- **Grenade-first was structural.** `Grunt_SelectSched` runs ahead of the generic combat
  block, so once the cover rolls declined, the throw was the first thing tested. Half-Life
  cannot do that: `CHGrunt::CheckRangeAttack2` refuses outright while
  `m_flGroundSpeed != 0` (hgrunt.cpp:482-486 — a moving grunt never throws), and
  `GetSchedule` handles `bits_COND_NEW_ENEMY` BEFORE the grenade branch, returning
  `SCHED_TAKE_COVER_FROM_ENEMY` for a non-leader or `SCHED_GRUNT_SUPPRESS` /
  `SCHED_GRUNT_ESTABLISH_LINE_OF_FIRE` for the leader. Both gates added; the second as a
  timestamp (`ai_enemy_since`), since this tree has no `COND_NEW_ENEMY`.
- Three VMs at **0 warnings**; `optional_audit` PASS (319); `check_serverfire` PASS
  (31 / 66); `cvar_audit` baseline **12**.

### Not done, and why

- **No sniper ballistics.** An assassin with `weapons 8` now visibly holds the M40A1 and no
  longer fires buckshot, but it still uses the default burst cadence and damage rather than
  a single high-power shot. The bit and the model are right; the gun's feel is not modelled.
- **No rocket behaviour for `HGRUNT_RPG` (64).** The constant exists so the bit stops being
  invisible, but a `weapons 64` grunt still fires the default burst. desertcircle's
  `base2sm4` / `base3sm4` are the placements.
- **`weapon_m16` deliberately left on `WMF_WEP_HLSMG`.** Sven's own M16 exists as
  `WMF_WEP_SVM16` and the manifest even lists the key (unreachably), but promoting it moves
  every `weapon_m16` in the corpus onto a different gun and belongs in its own change.

---

## PATCH 138 — desertcircle: the world-write crash, and the three NPC symptoms

Reported as "the grunts don't seem to spawn, some don't move, some don't actually shoot",
plus a burst of load errors. The load errors and the NPC symptoms turned out to be
unrelated, and the three NPC symptoms turned out to be three different bugs.

### Owed in-game checks (this patch)

1. **The mortar is drivable and its shells land.** `op4mortar` and
   `func_op4mortarcontroller` are the one item here that **nothing exercised
   headlessly** — no headless client ever `+use`d a control brush. On desertcircle,
   `+use` the vertical brush and the horizontal one: the tube should elevate and slew
   within ±120° of its spawn yaw, `+attack` should lob a shell on a HIGH arc (the
   ballistic solver deliberately takes the high root — a mortar lobs over things), and
   the shell should explode on impact. Then shoot the cannoneer standing beside it and
   confirm the `mgruntani` relay makes the mortar fire on its own.
   Code-reviewed, not measured — call it out if it misbehaves.
2. **The reskinned assassins actually hurt you.** desertcircle's 8 tower snipers use
   `models/descrcl/massnf.mdl`. Expect to take damage from a tower with **nothing
   visible in it** — they are `rendermode 5` with no `renderamt`, so they are fully
   invisible, and `takedamage 0 / health 99999`, so they are unkillable. That is
   faithful; Sven does the same. Verify the DAMAGE, not the visuals.
3. **Guards arrive.** `SCHED_GUARD` is selected and the grunts walk (verified: peak 60
   move ticks per half-second window), but **zero arrivals were observed in a 4-minute
   run** — desertcircle creates `base1goal` 2200 units away and 400 units above the
   squadmaker that produces the grunts guarding it. Watch whether they get there, mill
   about short of it, or bounce off geometry.
4. **Roaming reads as wandering, not pacing.** `freeroam` is on **2189 placements across
   48 of 141 corpus maps**, so this is the widest-reach change in the patch. A roamer
   should walk somewhere, stand for a couple of seconds, then pick somewhere else.
   Shuffling on the spot means the throttle is being defeated.
5. **The nav supplement has not degraded a hand-noded map.** It fires on any map whose
   info_node graph is under 90% in one component, which is most of them. Watch for
   monsters routing through walls or taking obviously silly detours on `hl_c01_a1` and
   `pizza_ya_san1`. `sv_nav_supplement 0` restores strict "info_nodes only".

### Verified headlessly (numbers, not claims)

- **The QC exception burst is gone: 6 → 0**, and `[mm-reap]` drops 75 → 72. Root cause
  caught in the act with `sv_debug_use 1`:
  `[mm-hook] ent=0 classname="" key="compiler" value="ZHLT v3.4 VL33 (Feb 2 2014)"` —
  desertcircle's worldspawn is classname-last, so its unrecognised keys reached the slot
  capture as **edict 0**. World is writable during parsing and read-only afterwards
  (`sv_init.c:1652`), so the capture succeeded silently and `MM_ReapOrphanSlots` detonated
  on the first `StartFrame`. Guarded at both ends.
- **All three "no spawn function" lines are gone** — `op4mortar`,
  `func_op4mortarcontroller`, `info_texlights`. The FGD declares `info_texlights` with an
  EMPTY key list (`sven-coop.fgd:3373`): it is compile-time texture-light data for VHLT's
  RAD, so an empty stub is the whole of it.
- **The nav graph was shattered, and is measured, not guessed.** Before:
  `components=6 largest=103 (53.6% of 192 nodes)`. After:
  `192 -> 2048 nodes, components=10 largest=1857 (90.7%)`. The supplement also reported
  **17 monster spawn points with no graph within 256 units** — desertcircle's node cloud
  tops out at z=912 while its castle squadmakers sit at z=896..1152.
- **The spawn chain was never broken.** `[entity_iterator] "base1iter" matched 0` on a
  server with no players, looping correctly every ~14 s, and with a real client attached
  `[squadmaker] base1sm1 #1 type=monster_human_grunt made=1 live=1`. The map spawns one
  grunt per iterator run **per player** at base 1 only; bases 2/3/castle are gated behind
  flag captures. A quiet map early on is the map's design, not a bug.
- **The rig override never fired on this map, and the model headers say why.**
  `Grunt_RigOverride` matched full paths, and desertcircle reskins every NPC into
  `models/descrcl/`. Read out of the files: `descrcl/massnf.mdl` is **55 bones / 53 seqs /
  2 bone controllers**, against stock `massn.mdl` 56/53/2 and `hassassin.mdl` 62/17/0 — a
  massn rig, so the assassins were running `Assassin_Event` (codes 1/2/3) on a rig raising
  the hgrunt vocabulary (3/4/5/6). Now matched on the basename stem; verified that each
  known rig resolves to exactly one handler with no cross-matching.
- **The supplement helps the campaign maps more than it helps desertcircle**, measured as
  the size of the largest component a monster can actually path within:

  | map | before | after | error greps |
  |---|---|---|---|
  | `crossfire` | 651 / 701 (92.9%) | untouched — cleared the bar | 0 |
  | `hl_c01_a1` | 39 / 98 | **205** / 588 | 0 |
  | `pizza_ya_san1` | ~94 / 98 | **1674** / 2048 | 0 |
  | `desertcircle` | 103 / 192 | **1857** / 2048 | 0 |

  Note the percentages can FALL while the graph improves — `hl_c01_a1` goes 39.8% to
  34.9% because the denominator grew faster than the largest component. The absolute node
  count is the number that matters to a monster; the percentage is only the trigger.
- Three VMs at **0 warnings**; `optional_audit` PASS (319 files); `check_serverfire` PASS
  (31 / 66); `cvar_audit` back to the baseline **12**. The MENU vm matters here too —
  `shared/sh_cvar_table.qc` is in `m_progs.src`, so the new cvars go stale in the menu
  silently if only the server is rebuilt.

### Two bugs found in this patch's own code, both by measurement

- **A schedule that cannot succeed re-selects forever.** The first working build gave
  `439 -> "guard"` and `435 -> "fail"` with zero arrivals — the 1:1 signature the tree
  already documents for the blocked follower. `AI_MoveAlongPath` returning BLOCKED/NOPATH
  routed guard into `SCHED_FAIL`, which re-selected the same unreachable post. Guard and
  roam now treat both as "got as close as the geometry allows", with a 10 s backoff, the
  same shape as the follow case at `sv_ai_core.qc:2042`.
- **`guard_ent` and `freeroam` cancelled each other out.** desertcircle's makers set BOTH,
  and `AI_WantsToGuard` answers FALSE for "no post" *and* for "already standing on it" —
  so every grunt walked to its post and immediately wandered off again. `AI_WantsToRoam`
  now tests the resolved pointer, which is the only thing that separates those two cases.

### Not done, and why

- **Dormancy is only half-lifted.** A monster with an unreached `guard_ent` stays awake
  until it arrives; a monster that only has `freeroam` does not. Keeping every roamer on a
  48-map corpus awake at 10 Hz plus a path request per leg is exactly the cost the
  dormancy gate exists to avoid, and nobody can watch a monster wander with no player
  within 1024 units. If roamers turn out to need it, the exemption is one clause wider.
- **`op4mortar`'s `classify` is parsed and not consulted.** The mortar is not a monster —
  no `.ai_class`, not in the monster chain, never consults the faction matrix — so
  `is_player_ally` picks its side and the 20-way classify enum does not. Both FGD values
  behave; the enum would be a lie.
- Map-side defects found while measuring, **not** tree bugs, listed so nobody re-derives
  them: nine squadmakers target `base1seqmm` / `base2seqmm` / `castleseqmm`, none of which
  exist in the map; `sniperschangev` sets `takedamage` with no `m_iszNewValue`;
  `tower1snipersb` is never killtargeted, so two invisible unkillable snipers outlive
  their tower; `gunnerseq1` and `mgruntani` each name two different entities.
- `desertcircle_skl.cfg` sets `sk_healthkit1/2/3 "50"` and the `_skl.cfg` reader is still
  unimplemented (carried from PATCH 137). `killnpc` still bridges to `mp_npckill`, which
  is read by nothing.

---

## PATCH 137 — Hazardous Course 2 (hc2_*, 20 maps): cross-map state, the long jump, the difficulty vote

### Owed in-game checks (this patch)

1. **The long jump actually launches, and does not rubber-band.** This is the only change in
   the patch that touches shared prediction code, so it is the only one that can regress
   movement on maps with nothing to do with hc2. Run at speed, hold crouch, jump: you should
   get Half-Life's flat 560 u/s launch with a 56-unit apex instead of the usual 268 / 45.
   Then do it on a client with real latency and watch for a mid-flight snap — a snap means
   the `pm_longjump` byte is not surviving reconcile.
   Note the deliberate divergence: **a player carrying the module no longer slides.** Slide
   entry and HL's longjump are both "press crouch while running" and they cannot coexist —
   slide entry zeroes `pm_duck_msec`, which is exactly the window the longjump requires. The
   module wins. If sliding matters more somewhere, that gate is one line in `PM_CheckDuck`.
2. **Look angle changes the distance.** HL writes only forward[0]/forward[1] of the raw look
   vector without normalising, so looking down shortens the jump. Valve flagged this as an
   "UNDONE" and it was kept on purpose, because hc2's gaps were authored against it. If a gap
   feels impossible, check the pitch before changing the constant.
3. **The 21-scientist hub reads back.** Collect a scientist on any of `hc2_c1`..`hc2_c9`,
   then return to `hc2_a1` and confirm the trophy is lit. Verified headlessly at the store
   and entity level; what is not verified is that the map's own display chain looks right.
4. **The keycard chain across the three secret maps.** `hc2_s2` -> `s2a` -> `s2b` share
   keycard/valve globals, and `kcy_gbl` drives a wall at a level change. Ride the whole loop.
5. **`hc2_a2` really is a reset room.** Entering it wipes all 50 slots — faithful to kmkz's
   script, where the reset arm sits above the use-type switch and therefore fires from the
   entity's own spawn. It prints `[func_global] ... !reset ... cleared`. Confirm that is what
   the room is meant to be and not a surprise.
6. **A `func_guntarget` dies when shot.** This is the one code path in the patch that could
   not be measured headlessly — nothing shoots on a dedicated server with no player. On
   `hc2_c2`'s range: the target must take damage only after it is switched on, must stop on
   death, and must then fire its `message` (`gt1_hit`..`gt7_hit`) and NOT its `target`, which
   is its first path corner. `gt8_hit` is what advances the range, so if the stages do not
   chain, look here first.
7. **The escorted barney is escortable.** `hc2_c5`'s `create_barney` produces the NPC at the
   right place with its keys bound (verified), but whether it then follows and behaves like
   a map-placed barney is a client-side eye-check. Note its `TriggerCondition 4` is bound but
   not yet *evaluated* — see "Not done" — so the mission-failed rule will not fire yet.

### Verified headlessly (numbers, not claims)

- **`func_global` (74 placements / 17 maps)** — was MISSING entirely, so all 64 of the
  `trigger_condition`s polling `health == 1` on one could never fire. `hc2_a1` now prints
  `[func_global] 26 on this map, series "hc2", 0 set`. The self-test
  (`sv_mapglobals_selftest 1`) exercises store, entity resync, the real `.use` path and a
  file round-trip: `[mgtest] func_global self-test: 1 entity(s) on slot 1, BAD=0`.
- **Cross-map persistence** — `cfg/mapglobals_hc2.txt`, 50 lines in kmkz's own `globalNNN=V`
  format. FTE does not reload progs between maps so the array alone survives a changelevel;
  the file is what survives a server restart.
- **The difficulty vote, end to end across maps.** On `hc2_a1`:
  `[trigger_save] 'save_difficulty' saved $s_difficulty="normal" as "diff_saved" for level hc2_a1`
  -> `cfg/mapsaves.txt`. Then on `hc2_c1`:
  `[trigger_load] 'Diff_Initialization' loaded "diff_saved" -> $s_difficulty="normal"`
  -> `[trigger_condition] "diff_condition" poll $s_difficulty(normal) op0 "normal" -> true`
  -> `[mapscript] hc2: difficulty NORMAL (spawn 100hp/100ap)`. The extreme branch was
  round-tripped the same way and lands `[mapscript] hc2: difficulty EXTREME (spawn 1hp/1ap)`.
- **Sven `$s_`/`$i_`/`$f_`/`$v_` custom keyvalues** — previously discarded outright by
  `ED_ParseUnknownEpair`. Now harvested (`[customkey] 1 custom keyvalue(s) harvested` on
  hc2_a1) and readable by `trigger_condition` / writable by `trigger_changevalue`.
- **`TriggerCondition` / `TriggerTarget` now bind on map-placed monsters.** hc2_c2 prints 21
  of each via `[keyfold] TriggerTarget -> triggertarget`. They previously matched no field at
  all and fell through to the slot capture, where each one also burned an `mm_slot` edict.
- **The long jump grant** — `[mapcfg] equipped Player: 1 weapon(s)` on hc2_b2b, i.e. the
  cfg's bare `item_longjump` token now reaches the player. 17 of the 20 cfgs carry it.
- **Wire v23 -> v24** with a new fixed byte in the movement section; a real headless client
  connected and decoded it with no `bad read` and no `Host_EndGame`.
- **`func_guntarget` (7, hc2_c2's shooting gallery)** — was MISSING. The trap here is that a
  GoldSrc brush mover's `origin` is its brush centre, not its first corner, so a naive
  implementation parks all seven at the corner coordinate and the gallery is unplayable.
  All seven now resolve correctly, e.g.
  `[guntarget r_gt1] centre-offset=1840 1682 56 first corner "gt1_stp0" at 784 -5040 -3728 -> origin 2624 -3358 -3672`
  — i.e. `(2624 -3358 -3672)`, not `(784 -5040 -3728)`. They then ping-pong their corner
  chains indefinitely (17 arrivals in a 45 s sample). Implemented by building a translated
  private copy of each corner chain at spawn and pointing `train_target` at it, so the whole
  of `sv_func_train.qc` runs verbatim rather than being forked. **Documented cost:** a
  `trigger_changetarget` rewriting a real corner mid-game would not reach the copy — no
  corpus map does this. **Not measured:** the death path (`.on_killed` -> fire `.message`) is
  wired and code-reviewed but needs a client, since nothing shoots it on a dedicated server.
- **`trigger_createentity` (7, 6 maps)** — was MISSING. Both child shapes proven:
  `[createentity] "create_barney" created monster_barney "barney" at -1159 -1645 -615.969 (keys applied=3 dropped=2)`
  on hc2_c5, where `z` moved -586 -> -615.969 (so `Monster_Build` really ran and floor-snapped
  it) and the child then prints `[keyfold] TriggerCondition -> triggercondition = "4" on
  monster_barney` — the `on monster_barney` suffix being the proof `self` was bound to the
  child during replay. `dropped=2` is exactly `UseSentence`/`UnUseSentence`, which have no
  home. And the runtime brush case on hc2_s2:
  `created func_breakable "brk1_il_rdr" at -3008 -3056 -1296 modelindex=159` — a nonzero
  `modelindex` is the cheapest signal that a `-model` key arrived after the spawn function's
  own `setmodel`. The `-`-prefixed keys no longer allocate junk `mm_slot` edicts:
  `grep -c 'mm-parse.*target="-'` is **0**.
- Three VMs at **0 warnings**; `optional_audit` PASS (318 files); `check_serverfire` PASS;
  `cvar_audit` back to the baseline **12**. Regression smoke clean on `hc2_c1`, `hc2_c2`,
  `pizza_ya_san1`, `hl_c01_a1`, `crossfire`.

### Verified NOT to need work (measured, so nobody re-derives it)

- **`anti_rush` (16 placements)** — `HC2.as` sets `blAntiRushEnabled = false`, so the entity
  is never registered and is inert **in Sven too**. Its `killtarget`ed blockers are
  `func_wall_toggle spawnflags 1` (Start Off) and nothing else switches them on.
- **`point_checkpoint` (18)** — already implemented, and it appears on exactly the 12 maps
  with `mp_survival_supported 1` and no others. Sven spawns it *disabled* unless survival
  mode is active, so it is a no-op in normal co-op by design.
- **`ammo_9mmclip 15`** (hc2_s1 cfg) — not a valid Sven token. The manual documents exactly
  ten ammo tokens and this tree implements all ten, so Sven drops that line too. It is a
  mapper typo for `ammo_9mm`; "fixing" it would diverge from Sven, not toward it.
- **`mp_disable_autoclimb`** (all 20 cfgs) — there is no ledge-mantle here to disable. The
  `WJ_*` block in `sh_pmove.qc` is GoldSrc **water** jump.
- **No multi_manager keyvalue collisions** in this series: every hc2 multi_manager key was
  intersected against all 1,803 declared server fields and none collide.

### Two bugs found the hard way, both worth remembering

- **QC has ONE global namespace and fteqcc does not warn on a collision — it silently
  merges.** The new named-value store was written as `ms_*` and its `ms_loaded` latch merged
  with `shared/sh_matsounds.qc:59`'s, which is set to 1 during map load. Result:
  `trigger_load` believed the file was already read, never read it, and every saved value
  came back missing, with no compile warning and no runtime error. Renamed `msave_*`. Grep
  the tree before adding a global.
- **`cvar()` reads 0 for a name registered later than the caller.** Both of
  `sv_mapglobals.qc`'s early callers run during map load and can precede `CVar_Init`, so a
  plain `cvar("sv_mapglobals_persist")` test reported "persistence off" for exactly the calls
  that needed it. Reads are now ungated and only an explicit `0` disables writes.

### Not done, and why

- **`func_clip` (5, hc2_c3)**, **`<mapname>_skl.cfg`** (hc2_c2's instakill headcrabs/zombies;
  36 corpus files, 474 distinct `sk_` keys of which only ~20 map onto existing cvars),
  **`player_weaponstrip`'s dead `pws_active` flag** (9 placements), and the **unspendable
  CAL_556 bank** — all scoped as cheap wins, none landed this round.
- **`TriggerCondition` evaluation.** The keys now BIND, but nothing acts on them yet: there
  is no `FCheckAITrigger` equivalent. So hc2_c2's shooting range still cannot advance past
  its bullsquid stages and no "mission failed" escort rule fires. Binding was the
  prerequisite and is done; evaluation is the other half. **12 of the 46 placements are on
  `monster_sitting_scientist` / `monster_generic`, which are `SOLID_NOT` / `DAMAGE_NO` by
  construction — and condition 2 (Take Damage) is 31 of the 46 uses, so those bodies have to
  become damageable or the rule stays dead.**
- **Survival mode**, `speaker` (34), `trigger_cdaudio` (5), `env_beverage` (25),
  `env_shake` (27), `func_friction` (5), `func_tankmortar` (1), `monster_rat` AI (40).

---

## PATCH 136 — pizza_ya_san2: swallowed multi_manager slots, the discarded map cfg, 976 dead edicts

### Owed in-game checks (this patch)

1. **The pizza shop owner spawns.** The squadmaker named `sq_owner` is fired only by two
   multi_managers (`mm_opend` at 16s, `mm_endmi2` at 0s), and both slots were being eaten by
   the `.entity sq_owner` field — the field is now `.sq_maker`, and both slots are confirmed
   captured headlessly. What headless can't do is *fire* them, because that needs the shop
   sequence to run. Play to the shop-open beat and check the title character appears.
2. **The cyclers still animate.** This is the change with real visual risk. The per-tick
   `.frame` driver is no longer installed on studio (HL) models — all 82 in the corpus — on
   the grounds that `.frame` is a SEQUENCE index there and the client advances animation time
   itself. Check pizza_ya_san2's 31 drones, `hl_c01_a2`'s 17 `hair.mdl`, `hl_c00`'s
   `apache.mdl` rotor, and especially `hl_c05_a2`/`hl_c05_a3`'s `rengine.mdl` — that one has
   **three** sequences and should now sit in one animation instead of strobing between them.
   If anything freezes, the probe in `Cycler_IsStudioModel` is what to revisit.
3. **The map cfg loadout.** `pizza_ya_san2.cfg` asks for five weapons, 50 armour and six ammo
   pools; headless confirms 5 weapons, 1174 rounds and armor 50 applied at spawn. Confirm in
   the HUD that the SOFLAM and the AS shotgun are actually usable, not just present.
4. **The secret weapon.** `ml_secretwep_2` is a squadmaker whose `monstertype` is
   `weapon_as_soflam`; it used to dispense nothing. It now resolves through the weapon
   manifest. Trigger it and check a SOFLAM lands on the floor and can be picked up.
5. **Recovered slots actually fire.** The collision scan restored 28 slots across the corpus.
   Spot-check the two that carry visible behaviour: `hl_t00`'s `firingmm2`/`firingmm3`/
   `firingmm4` (eight `target1`..`target8` slots, 4.2–12.2s) and `hl_c16_a1`'s `startmap_mm`
   `fadein` at 0.5s.

### Verified headlessly (numbers, not claims)

- **Field-name collisions.** 36 multi_manager slots across 17 maps were bound to declared QC
  fields and silently dropped. **28 restored.** `hl_t00` recovered 8 in one map;
  `hl_c16_a1` 1; `hl_c05_a2`/`uplink` recovered their `drop` slot via the deleted dead field.
- **8 remain lost and now say so on the console.** 6 are `fadein` with delay 0 (crystal,
  hl_c08_a2, judgement ×3, th_ep3_04) — a zero in a float field is indistinguishable from an
  absent key once the engine has bound it. 2 are `.void()` fields: `hl_c12`'s `blocked`
  (an engine field, unrenameable) and `toonrun3`'s `shoot`. `hl_c12` prints the warning.
- **Orphan slot edicts reaped**: pizza_ya_san2 **976**, hl_c01_a1 264, th_ep1_00 91.
- **Map cfg**: `[mapcfg] equipment: 5 weapon/item, 6 ammo, armor 50` then
  `[mapcfg] equipped Player: 5 weapon(s), 1174 round(s), health 100, armor 50`.
  1174 = 20×17 + 10×12 + 3×200 + 5×2 + 5×20 + 2×2, i.e. the manual's clip multipliers exactly.
- **Cyclers**: 31 `[cycler] ... studio model - frame driver not installed` on pizza_ya_san2.
- Regression sweep clean on th_ep1_00, hl_c01_a1, hl_c06, pizza_ya_san1, crossfire.

### Behaviour changes worth knowing about

- **Map cfgs now equip players.** 85 corpus maps name `weapon_crowbar`, 66 name `ammo_9mm`,
  24 set `startarmor`. All of it was being dropped or turned into junk cvars; all of it now
  lands. Loadouts on those maps will differ from every previous build.
- **`nomedkit` / `nosuit` are parsed and reported but NOT enforced**, by choice: they are the
  two tokens that take things away from the player, `nosuit` also kills the flashlight and all
  armour pickups, and 20 cfgs set `nomedkit` — including every They Hunger chapter and the
  whole HL campaign. Say the word and they become a cvar.
- **A give-mode `game_player_equip` suppresses the map cfg**, which is Sven's documented rule;
  `SF_GPE_APPEND_MAP_CFG` (declared since Patch 130 and referenced nowhere) now inverts it.

### Not done, and why

- **`<mapname>_skl.cfg` is still never opened.** pizza_ya_san2 does not ship one and its main
  cfg carries no `sk_*` lines, so it is not a pizza2 blocker; 34 other cfgs do carry inline
  `sk_*` values, which are now consumed rather than becoming junk cvars but are still ignored.
- **`xenmaker` / `env_xenmaker`** left alone — 1 placement, verified to gate nothing.

---

## PATCH 135 — hl_c06's inert grunts, the gargantua's hands and stomp, func_platrot

### Owed in-game checks (this patch)

1. **Squads on hl_c06.** Map-placed monsters now take their squad name from `netname`
   (HL `squadmonster.cpp:327-346`) instead of the squadmaker-only `squadname`, and only a
   leader recruits. Headless can't reach them — squad formation needs a player nearby, and
   both the before and after runs read `squads=0` from the spawn point. Walk to the balcony
   and the lift on `hl_c06` and check `squad_initial` / `squad_lift` / `squad_back` stay three
   separate squads rather than merging into one. 278 map-placed monsters across 29 maps.
2. **Gagged monsters are audible again.** 13 `.gag` early-outs came out of `mon_grunt.qc`
   and one out of `AI_SndPlay`; the flag now gates SPEECH only, through `AI_SndSpeak`, with
   HL's combat override. Precache is verifiable headlessly, playback is not — so listen to a
   `spawnflags 3` grunt on `hl_c06`: it must fire audibly, grunt when hit and scream when it
   dies, while still not chattering until it is engaged. 538 monsters across 68 maps.
3. **The gargantua's flame comes out of its hands.** Verified at runtime as far as headless
   can go — the tag lookup reports `OK` rather than `FALLBACK` and returns a live,
   animation-driven position (`bones=57`, attachment 1 at `rel=17.6 -67.7 44.1` mid-sweep
   against `-67.7 -23.3 44.1` idle) — but nothing renders, so whether the jet *looks* like it
   leaves the palms is an eye check. Also check the jet now tilts at a target above or below
   you, which it never did.
4. **The stomp travels.** `stomps=1` then `stomps=2` fifteen seconds apart in the fire test,
   so the entity spawns, moves and expires. What headless cannot show is the shape: stand
   BESIDE a gargantua when it stomps (must be safe now — HL's stomp has no radial component
   at all) and then in front of it (must not be). The ring and ground-fire burst are now
   telegraph only.
5. **The gargantua's hull changed** from the default 32x32x72 to HL's 64x64x64
   (`gargantua.cpp:752`). It is wider — walk one through `hl_c06`'s tunnels and
   `pizza_ya_san1`'s shop to confirm nothing gets stuck in a doorway.
6. **`func_platrot` and the plat sign.** The `hl_c01_a1` chain is verified headlessly end to
   end (button -> `ele_x` -> `ele_2` -> arrival fires `ele_at_btm` -> `edoor_1`), but *riding*
   it is not: stand on the cage and confirm you are carried both up and around as it rotates
   90 degrees. And `func_plat`'s travel sign was inverted — `pizza_ya_san1`'s two shop
   shutters must now roll UP out of the doorway, not sink into the floor.
7. **The 29 non-toggle plats.** `func_plat` gained HL's auto-call trigger volume, start-at-
   bottom-when-unnamed, one-shot use and 3-second auto-descend. None of the 37 corpus plats
   is unnamed, so the start-at-bottom branch is dormant and untested by definition.

### Verified headlessly (no in-game check owed)

- `hl_c06` placement: 3 stripped monsters before, 0 after; the two doorway grunts are rescued
  by HL's +1 lift outright, `dragguy` and the sentry are now kept live instead of stripped.
- `ele_top_bttn`'s link box moves from `2781.9 -1875.1 -1122.1` back onto the brush at
  `-1875 -2788 -1122`. 278 buttons across 31 maps were mis-linked this way.
- Gargantua fire test: `dmg=842.6` on the player, the highest of the eight classes;
  `sweeps=4 ticks=95 hits=380`.
- `th_ep1_00` and `hl_c05_a1` regressions clean; the `pickup` truck chain still parses its
  explicit `usetype=0`.

---

## PATCH 134 — tracktrain driving, two broken scripted rides, water through the sky

### Owed in-game checks (this patch)

1. **Driving a train.** Headless cannot tap `+forward`, so the throttle is compile-and-run
   verified only. On `hl_c05_a1`, stand on `twain` and press `+use` — that map ships **no**
   `func_traincontrols`, so a successful mount proves the new default control volume (the
   train's own bbox plus 72 units of headroom, HL `plats.cpp:1516-1518`). Then check: one tap
   = one quarter step, nine states from full reverse to full forward; reverse actually walks
   the chain backwards; jumping, strafing or stepping off all release; the HUD reads
   REVERSE / NEUTRAL / SLOW / MEDIUM / FAST; and crossing `ridepath20` throws you off the
   controls mid-ride.
2. **Rider drift.** The mechanism is fixed structurally — there are no `setorigin` calls left
   in the per-tick movement path at all (only the unused Sven `PT_TELEPORT` flag and the spawn
   placement), so the rider carry's `brush.velocity * pm_frametime` is now exact. Whether it
   *feels* right on a long ride is still an eye check. Ride `hl_c05_a1` and `hl_c07_a1` end to
   end and watch a corner in particular.
3. **Water sides / sky.** Eye check by definition. On `th_ep1_00` the water's vertical faces
   should be gone and the sky should occlude what is behind it. Counter-check `hl_c05_a2`,
   which has **sloped** water — its surface must still be visible (the old test hid those).
   `r_hlwater_hidesides 0` restores the previous behaviour if a map turns out to build a
   waterfall from vertical water faces.

### The two rides were broken by four bugs, none of them the one that was suspected

**`USE_OFF` is 0, and so was "nobody set a use type".** `Trigger_UseTargets` rewrote a 0 to
`USE_TOGGLE`, so **every explicit Off in the mod** was promoted to a Toggle at the last dispatch
hop. New sentinel `USE_UNSET = -1` (`sv_customdefs.qc`), seeded in worldspawn and re-seeded per
`+use`; all six `sub_use_type ? … : USE_TOGGLE` ternaries converted — that idiom throws away a 0
and so reintroduced the bug locally wherever it survived.

Measured on `th_ep1_00`: the `pu5b` pass-target now arrives as `useType=0` where it read
`useType=3`, and the stop sticks. The long comment in `sv_func_tracktrain.qc` that recorded this
as an unexplained "`useType=3`" observation has been replaced with the cause.

**`trigger_camera` fired its own look-at entity.** On a `trigger_camera`, `target` is the entity
to *look at* — `Cutscene_AimEntity` reads it for exactly that, and HL's `CTriggerCamera::Use`
only assigns it to `m_hTarget`, never `FireTargets`. The QC also fired it. Invisible on 211 of
276 camera targets (inert `info_target`), **not** invisible on the 45 `func_train` and 10
`func_tracktrain` look-at targets. `th_ep1_00`'s `firstcam` has `target pickup`, so opening the
intro shot started the truck ~7 s early and the authored `pickup` toggle at t=8 then *stopped*
it — the intro ran backwards through its own script.

**A blocked pusher freezes forever, and crush never killed.** `func_tracktrain_blocked` and
`func_train_blocked` both did a raw `other.health -= self.dmg` — no death, no unlink. A blocked
`MOVETYPE_PUSH` brush does not advance `.ltime`, and every think is scheduled on `ltime`, so one
monster on the rails stops the train for the rest of the map. Measured on `hl_c05_a1`: a
`monster_houndeye` at `ridepath15` reached health **-5,300,000**, still decrementing every frame.
Now HL's order (`plats.cpp:1022-1027`) — shove clear, then `W_ApplyDamage`. **Behaviour change:
train crush now genuinely kills where it previously did nothing.**

**`sv_first_player_spawned` was declared and never assigned.** `sv_trigger_logic.qc:63` declares
it and its own comment says "Flipped TRUE on the first PlayerSpawn (sv_player.qc)" — that
assignment did not exist. `trigger_auto`'s dispatch and the tracktrain autostart both wait on it,
so with `sv_waitforplayer` enabled every intro sequence in the game was silently disabled and both
just re-scheduled their thinks forever. Latent at the shipped default of 0.

### `func_tracktrain` rebuilt on HL's continuous path walk

The old train walked node to node and `setorigin`'d onto each node it reached. That single shape
caused three of the reports: riders slid off (a teleport moves the train and not the rider — the
compensating term is `#ifdef CSQC` and its counter is only ever written client-side, so the
server never applied it, ~11.7 qu per node at `speed 500`); reverse was impossible, so driving was
impossible; and `PT_DISABLE_TRAIN` had been implemented as "halt".

`sv_path_track.qc` is now HL's real graph (`pt_next`/`pt_prev`/`pt_alt`, `LookAhead` with signed
distance, `ValidPath`, `Project`, `Nearest`, and a `.use` handler — which is why
`sv_th_entities.qc`'s `func_trackchange` could previously flip `PT_DISABLED` with no effect). The
train asks "where am I `speed * dt` further along the polyline?" and sets velocity to get there.
`LookAhead` carries a 512-iteration cap that HL does not have, because an unbounded walk over a
cyclic chain is an `SV_Error` here — or a silent hang under `QCJIT`.

Deliberate divergence: HL re-aims every 0.5 s and lets the train coast on a stale velocity, which
is why HL trains visibly cut corners. This re-aims every `sv_func_tickrate` tick (64 Hz), which
tracks the rails more tightly and keeps each velocity valid for exactly one tick — what the rider
carry needs.

Also fixed while in there: `PT_FIRE_ONCE` latched one bit on the **train**, so the first
fire-once node muted every other one on the route (53 nodes across 8 maps); per-node `speed` was
adopted unconditionally where HL gates it behind `TT_NO_USERCONTROL`; the dead-end `netname` fire
(28 nodes, 11 maps) was read by nothing; and `PT_DISABLE_TRAIN` returned *before* the message
fire, losing the pass-target on any node carrying both.

Measured on `hl_c05_a1`, the full authored runaway sequence: crossings continue past the
(now-survivable) houndeye, then `ridepath20` sets `TT_NO_USERCONTROL` and the train adopts
**450 → 500 → 550 → 600** from ridepath20/21/23/24, firing `gatesmash` (the breakable wall +
its warning sound), `horse1`, `horse2`, and `stopbars` (both breakables, both ejector
`trigger_push`es, and the relay that kills them 0.5 s later), ending at the dead end.

### `th_ep1_00`'s opening

Plays as authored end to end: truck starts at +8 s, stops at `pu5b` on an explicit `USE_OFF`,
`ratty` crosses on all three `moverat` marks in **7 s**, truck restarts on `USE_ON` at +8 s.

`models/hunger/hungercrab.mdl` is a different model from `headcrab.mdl` with its own authored
pace — 60 fps cycles giving **walk 15.43 / run 78.00** by HL's `GetSequenceInfo` formula, about
1.55× the stock crab. Driving it at stock speeds skated the feet through the whole crossing.
Per-model row added; the stock numbers were re-measured and confirmed exact (`hlclassic/headcrab.mdl`
is 9.54 / 50.20 against the tuned 10 / 50), so nothing else changed.

### Engine: water sides, and the sky that doesn't occlude them

Both mechanisms, in `C:\msys64\home\Lex\fteqw`.

**The `NULL` texture is a dead end and it is worth saying so.** ZHLT's `NULL` is stripped by CSG at
compile time — across all 108 Sven maps it appears as a miptex entry in 10 and on **zero faces**.
The faces being seen are the water texture itself (`!nm_water3`). No texture name can fix an
already-compiled BSP.

FTE already had a purpose-built cull for this symptom (`gl_model.c`, Spoike 2016 / Eukara 2021) —
gated on `&& i`, the submodel index, so it ran for water built as a brush *entity* and never for
water built into worldspawn. Corpus-wide that left **338 worldspawn side faces drawn** against
2745 correctly suppressed. The keep-test is now the face normal (matching the 0.5 threshold
`Surf_WaterShouldRipple` already uses in the same file) rather than a bbox midpoint, which is
meaningless for worldspawn and additionally mis-hid **sloped** water tops. Behind
`r_hlwater_hidesides` (default 1, archived, takes effect on map load).

Verified directly: on `th_ep1_00`, `hlwater: submodel 0 - kept 37 surface face(s), hid 95
side/underside face(s)` — exactly the 58 sides + 37 undersides the corpus scan predicted.

**The sky writes no depth on a HL BSP.** `cls.allow_unmaskedskyboxes` is true for any non-Quake
game, which both strips `depthwrite` from the forced-skybox shader and turned `GL_SkyForceDepth`
into a no-op. Worse, every They Hunger map sets worldspawn `skyname`, which puts `R_DrawSkyChain`
on a `forcedsky` branch that returns *above* both masking calls. `r_sky_forcedepth` now overrides
the veto and the cubemap branch masks before returning.

`gl_model.c` compiles into the **dedicated server**, which does not link `renderer.c` — the cvar
read is `#ifndef SERVERONLY`d, or `sv-rel` fails to link. (Found the hard way.)

### Not done, and why

- **`SF_MON_WAIT_FOR_SCRIPT` (128) — left alone.** In the HL SDK the flag is *defined*
  (`monsters.h:51`) and *cleared once* (`scripted.cpp:914`) and **read by nothing**. The mod
  declaring-and-not-reading it is already faithful. 134 monsters (3.5%) carry it, so implementing
  a freeze would have been invented behaviour on all of them.
- **`StartDisabled` — not needed for this work.** `hl_c05_a1`'s `stopbars` volumes are
  `spawnflags 66` = `PUSH_SILENT|PUSH_START_OFF`, so they already start off. Corpus-wide, 38 of
  the 44 `StartDisabled 1` entities are covered by an equivalent spawnflag; the 6 that are not
  are 4 `trigger_once` + 2 `trigger_multiple`, which would need Sven's generic trigger toggle —
  vanilla HL gives `ToggleUse` only to `trigger_hurt`, `trigger_push` and `trigger_monsterjump`.
- **`aaatrigger` still renders** as an ordinary wall — FTE has no rule for it, and it is on
  **6174 faces** across 16 maps. Unrelated to this round; recorded because the census found it.

### New test affordances

- `ent_fire <targetname> [usetype]` — client command, cheat-gated.
- `sv_debug_firetarget` / `sv_debug_firedelay` / `sv_debug_fireusetype` — the headless
  equivalent, because the harness can only pass cvars and can never type into a connected
  client, which made any map whose logic starts at a walk-into trigger untestable. Registered in
  `sh_cvar_table.qc`: an unregistered name reads back empty from `cvar_string()`, so a bare
  `+set` silently never armed.
- `sv_debug_func_train` now logs node crossings and `BLOCKED` events.

---

## PATCH 133 — two runaway-loop crashes, monster behaviour, and three map-entity gaps

### Both crashes were ONE bug: a cycle in the monster list

`SV_Error: runaway loop error` twice, from stacks that look unrelated. Neither reported
function was the culprit. The budget is **100,000,000 QC instructions** per
`PR_ExecuteProgram` entry (`pr_exec.c:1817`), so these were genuine non-terminating loops.

Both innermost frames sit inside a `while (e) { … e = e.monster_chain_next; }` walk —
`Script_FindMonster` (`sv_scripted.qc:235`) and `AI_FindEnemy` (`sv_ai_core.qc:353-369`).
`AI_Relationship`, the function the second trace names, **contains no loop at all**; it is a
flat if-ladder, and the counter merely expired in the deepest callee. Both walks are bounded
only by list length, so the list was circular.

A cycle can only form one way, and FTE makes it easy: `ED_Free` does **not** clear fields
(`pr_edict.c:198-209` is commented out) and `ED_Alloc` re-issues a slot after **0.5 s**. So a
monster freed while still linked leaves its neighbours pointing at the slot; when that slot
comes back as a new monster, zeroed, `monster_chain_add`'s guard sees a pristine entity and
inserts it at the head while the stale link still points back at it.

**The hole: `SUB_KillTargets`** ([sv_triggers.qc:52-63](server/sv_triggers.qc#L52)) —
`killtarget`'s only implementation, a bare `remove()` with no `Monster_Teardown`. It predates
the list and was never brought into line, and `SUB_UseTargets` calls it *before*
`Trigger_UseTargets`, which is the `sv_triggers.qc:127` frame in the first trace. Now fixed.

**But honestly: that is not what crashed you.** I parsed the entity lump of **275 maps** — all
108 in `svencoop/maps` (20 of them They Hunger), plus the addon, downloads, vanilla and local
sets — and **not one** has a `killtarget` naming a monster. It is a real latent bug on a path
every trigger type reaches, and it is fixed, but the live hole is still unidentified.

**So the actual protection is the backstop**, `Monster_Chain_Verify`
([sv_monsters.qc](server/sv_monsters.qc)), and it was the right call regardless: there are
~25 unguarded walks over this list, so any single missed teardown turns all of them into a
dead server. It sweeps at 4 Hz — inside the 0.5 s recycle window — unlinking freed edicts
*before* the slot can come back and close the ring, and walks under a cap so it is safe even
on an already-circular list. Two counters print with the AI report and **must stay at zero**:

```
[ai]   chain: 47 linked, freed-unlinked=0 cycles-broken=0
```

The freed-edict line is deliberately **not** debug-gated and names the classname. That is how
we find the real hole — please report it if it ever appears.

*Also worth knowing: `pr_exec.c:1809-1815` skips the runaway check entirely under `QCJIT`. On a
JIT build these were silent hangs, not errors.*

### `+use` during a scripted sequence

Separate bug, and the reason the crash was reproducible on demand. `AI_ToggleFollow` had no
check for `ai_script`, `MS_SCRIPT`, or HL's `m_useTime`, so the press spoke on `CHAN_VOICE`
(cutting the actor's `scripted_sentence`) and set `ai_taskdone = TRUE`, force-completing the
running script task without `Script_MayPlay` ever being consulted. GoldSrc refuses twice over
(`talkmonster.cpp:1419-1420` and `:1403-1407`). **`Script_CanInterrupt` already existed**
(`sv_scripted.qc:783`) and nothing on the `+use` path called it. Note `sv_scripted.qc:80-81`
records spawnflag 96 (NOINTERRUPT) as the corpus's commonest value at 355 uses.

Fixed alongside: `TASK_PLAY_SCRIPT` called `AI_TaskComplete` unconditionally after
`Script_SequenceDone`, which clobbered the schedule reset if the fired chain re-possessed the
monster — silently skipping a hand-off scene's first task.

### Bullsquid spit drew a bullet tracer

`AI_ProjTouch` reused `W_ImpactEffectFrom`, which hard-codes `is_entry = 1` — the "a bullet
travelled this line, draw the streak" flag — and passed the owner, which the client resolves
through `Montrace_ResolveMuzzle`. So a spit landed and a streak was drawn from the creature's
muzzle to the impact point. **Four monsters had it**: bullsquid, alien grunt (five hornets a
volley, so five streaks), pitdrone, gonome. New `W_ImpactEffectFromNoTracer` passes
`is_entry = 0`, which already means "decal only, no tracer" (`cl_bulletimpact.qc:1800-1803`).
HL's `CSquidSpit::Touch` draws no tracer of any kind.

Everything else audited clean: beam attacks never call `W_ImpactEffect*`, blast attacks don't
either, and hitscan users keep their tracers **correctly**.

### Infighting: two bugs, and one deliberate addition

The matrix was never the problem — headcrab↔houndeye is `R_NONE` both ways, matching
`monsters.cpp:2210`. Two real faults:

1. **`Headcrab_LeapTouch` was missing HL's same-`Classify()` guard** (`headcrab.cpp:350-353`).
   A leaping crab bit every crab and every monster it clipped en route, across 705 placements.
   Measured after the fix: **ten headcrabs spawned in a pile around the player, 11 bites, every
   one on the player, zero crab-on-crab.**
2. **`AI_FindEnemy` sorted by distance only.** HL's `BestVisibleEnemy` (`monsters.cpp:2428-2472`)
   sorts by **relationship first**, distance as tiebreak — "No need to do a distance check", in
   Valve's words. A grunt would turn its back on you to swat something it merely disliked.

Two cases that *look* wrong are faithful and were left alone: the houndeye blast excludes by
classname (so does `houndeye.cpp:620-621`) and the garg flame excludes `CLASS_ALIEN_MONSTER`
(so does `gargantua.cpp:627-630`). No general faction filter was added to `W_ApplyDamage` —
Half-Life has none, and it would stop the player's own explosives working.

**Deliberate, and pulling the other way:** HL's `ALIEN_PREDATOR → ALIEN_PREY` is `R_HT`
(`monsters.cpp:2212`) — bullsquids genuinely hunt headcrabs — and predator-vs-predator is
`R_DL`. Both were flattened to `R_NONE` here and are now restored, so you *will* see bullsquids
chasing crabs. That is authored behaviour, not the accidental kind the two fixes above remove.

### Scientists run away

The fear code existed and was **unreachable**. `SCHED_FLEE_ENEMY`, `TASK_GET_PATH_FLEE` and an
`R_FEAR` faction answer were all in place, but the fear branch sits at `sv_ai_core.qc:986` and
every path a shot scientist takes returns before it — the `MS_COMBAT` block falls out of its
bottom to `SCHED_CHASE_ENEMY` because both attack ranges are 0. So he walked at you, playing
`ACT_RUN`, forever.

Fixed with a class selector in the cockroach's shape (`Scientist_SelectSched`), which runs
*before* the ladder. `ACT_WALK_SCARED` (63) and `ACT_RUN_SCARED` (64) were declared, marked
looping, and referenced by nothing; `scientist.mdl` carries both (`walk_scared` idx 1,
`run1`/`run2` idx 3/4) plus `panic` as `ACT_EXCITED`. The flee schedule now asks for
`ACT_RUN_SCARED`, an escort that is frightened uses the scared gaits on HL's own 190/270 band
(`scientist.cpp:566-574`), and he says `SC_PLFEAR`/`SC_FEAR` on the transition. Measured:
`flee_enemy` selected, `chase_enemy` never.

### Map entities

- **`monster_tripmine` did not exist.** The armed wall mine and the pickup are two classes in
  the SDK (`tripmine.cpp:77` vs `:355`); this tree had only the weapon, so all 8 placements on
  `hl_c04` became inert relays — on **10 of the 35** Sven `hl_c*` maps. `W_TripmineSpawn` was
  already the implementation; it needed a map-entity door taking direction from the mapper's
  `angles`, no owner (and therefore **no deploy beeps** — `tripmine.cpp:130-137` gates them on
  the owner), and spawnflag 1 for the 1.0 s fast arm. Measured on hl_c04: **8/8 armed**, beam
  directions matching each placement's `angles`.
- **`func_tracktrain` ignored `height`.** Both keys *were* being read — they are declared
  fields and FTE's parser binds them — but `height` was used by nothing except a debug print,
  while `wheels` was used correctly all along (the header calling it "v1: unused" was stale).
  In HL `m_height` is a permanent vertical offset of the origin above the track
  (`plats.cpp:1186-1198`, `:1390-1403`). Five sites needed it, including the per-tick velocity
  delta — miss that one and the train steers downward even while moving. Measured on
  hl_c05_a1: `track=-1844 placed=-1804 height=40`, exactly as predicted.
- **`monster_grunt_repel` was aliased to the wrong entity.** It is Half-Life's own classname
  for `CHGruntRepel` (`hgrunt.cpp:2389`), an invisible use-triggered spawner that drops a grunt
  on a rope — not They Hunger's standing grunt. The alias made it a solid hgrunt floating at
  the rope anchor. Now an honest, documented no-op stub. Latent: zero placements across the
  campaign, because Sven's port replaced the rappel scene with squadmakers.

### Gargantua flame

It was **particles using a generic `aparticle` texture**. Half-Life uses four sprite `CBeam`s
of **`sprites/xbeam3.spr`** — worth saying because the obvious guess is wrong: there is no
`sprites/flame.spr` in `gargantua.cpp` at all. Two outer at width 240 in orange (255 130 90),
two shorter inner at 140 in blue (0 120 255) starting 40% down the jet, brightness 190,
`SetScrollRate(20)` — and the scroll is what makes it read as *flowing* flame.

Rebuilt onto `HLBeam_EntUpdate`, the persistent networked beam the gauss and egon already use,
which takes width/brightness/scroll in the SDK's own units. That also fixes a structural wart:
the old version re-multicast a fresh 0.16 s effect **twice per tick for 4.5 seconds**, where HL
creates the beams once and removes them at the end.

### Not done

`hl_c05_a1` has **no grunts to restore** — its entire monster list is 8 bullsquids, 7
headcrabs, 5 houndeyes and 1 zombie, every classname implemented. That is faithful: hl_c05 is
Blast Pit (`c1a4*`), pre-HECU, and no vanilla `c1a4` map has a grunt either. The marines first
appear on `hl_c04`, which does have them.

Also still missing on hl_c04, unrelated: `speaker` and `func_mortar_field`.

### Owed in game

- [ ] **The crash is the one to watch.** If `[monster] chain: unlinked a FREED edict` ever
      appears in a log, that names the removal path still leaking — please send the line.
- [ ] **+use a scientist mid-scene.** The line should play through and nothing should happen;
      previously it cut the sentence and crashed shortly after.
- [ ] **Bullsquid / alien grunt impacts** keep decal, sound and spray with **no** streak back
      to the muzzle. Apache, turrets and grunts must keep theirs.
- [ ] **Shoot a scientist**: he should scream and run, walking when close and bolting when far,
      never walking at you.
- [ ] **Bullsquids will now hunt headcrabs.** Deliberate — see above.
- [ ] **Ride both trains** (hl_c05_a1, hl_c07_a1) and check the carriage sits on the rails.
- [ ] **hl_c04's wall mines** should be visible, silent on spawn, with live beams.
- [ ] **The gargantua's flame** should be a scrolling orange jet with a blue core, not a
      cloud of blobs.

---

## PATCH 132 — music volume, barnacle tongues, and the escort navigation run

Four reports. Three had a different cause than the report implied, and the fourth
turned out to be correct behaviour.

### Music: the control never existed, and the level is out of proportion

FTE's cvar is **`musicvolume`** (legacy alias `bgmvolume`, `snd_dma.c:83`, default
`0.3`, archived). GoldSrc's `MP3Volume` does not exist here, which is why looking
for it found nothing. Nothing in the mod exposed it: no table row, no menu slider,
not in `client_config_cvars[]`.

**And `volume` does not scale music in FTE** — it is game sounds only
(`snd_dma.c:85`). `cfg/default.cfg` sets `volume 0.07` and set nothing for music,
so every MP3 has been playing at 0.3 against a game at 0.07, i.e. **roughly four
times louder than everything else**. Now ships `musicvolume 0.06`; the cfg line is
the only thing that can apply it, since `registercvar` is a no-op on an
engine-owned cvar.

Added: an **`mp3volume`** console command under the name people reach for, a
**Music Volume** slider on the Settings General tab, and persistence to
`cfg/settings.cfg`. Also deleted `bgmvolume 0` from `cfg/backupcommands.cfg` —
nothing execs that file, but 0 is an off switch rather than a fade
(`Media_NextTrack`, `m_mp3.c:181-182`, refuses to start a track at all), so it was
a mute waiting to happen.

**`cvar_audit.py` had been dead since the `data/` → `cfg/` rename** — it died on
FileNotFoundError before its first check, which is why the CFG-DIFF class of
finding had gone quiet rather than clean. Fixed; it reports 12 pre-existing
findings, none from this patch.

### Looping is correct, and it is the mapper's choice

`music <track>` with one argument **loops forever**; a literal `"-"` as the second
argument is the engine's documented play-once (`m_mp3.c:474-475`). `target_cdaudio`
passes one argument and loops. `ambient_music` chooses per placement — and of the
44 placements across 29 Sven maps, **39 have no Loop flag**. What is being heard is
faithful. No code change.

### Barnacle: the floor distance was measured and thrown away

The tongue is one bone-controller write, and its resting length was the constant
`BARN_TONGUE_REST = 64` regardless of ceiling height. `Barnacle_FindVictim` was
already tracing downward and reading `trace_ent` while **discarding
`trace_endpos`** — the engine computed the answer and the QC binned it.

Now traced properly (`MOVE_NOMONSTERS`, architecture only, as `barnacle.cpp:400`
does), on a **separate** trace from the victim search so a corpse lying underneath
no longer makes the barnacle reel its tongue up.

Also added, and the floor trace is wrong without it: **`m_flTongueAdj`**. Each
sequence has tongue baked in — ~100 units idle, ~20 chomping (`barnacle.cpp:121`,
`:278`) — and HL subtracts it so the drawn tip lands on the measured altitude.
Plus: seeded at spawn (a dormant barnacle's `.ai_tick` never runs, so anything
computed only there sat at the baked minimum until you walked within 1024 units),
zeroed on death (`barnacle.cpp:347`), measured to the victim's **eyes**, eased down
at 8 units/think, and gated on `m_fTongueExtended` before a grab.

Measured on `th_ep1_02` with `sv_ai_debug 2`: `ceil=349.96 ctrl=-249.96` — a real
350-unit measurement where it used to be 64, less the 100 already in the animation.

**`BARN_TONGUE_MAX = 512` is a hard wire limit, not a taste call.** Bone controllers
cross as a short scaled by `ES_BONECONTROL_SCALE = 64` (`protocol.h:1298`, clamped
`sv_ents.c:3654`), so 512 is the largest magnitude that can be transmitted at all.
HL traces 2048; a barnacle higher than 512 above its floor will clamp, and lifting
that needs a protocol change. Re-commented so nobody raises it and gets silence.

### Escort navigation: four mechanisms, measured before and after

Driven with a new harness (a headless client holding `+forward +left` at
`cl_yawspeed 25`, i.e. a leader that actually walks a circle — the stock harness
stands still, so a follower arrived once and stopped, and none of this was
reachable). `hl_c01_a1`, ~44 allies escorting, 2-second windows:

| | before | after |
|---|---|---|
| direct `walkmove` failure rate | 51/63 = **81%** | 16-19/57-60 = **~30%** |
| sidesteps | 266 | **34-55** |
| corner-cuts | **0** | 1-2 |
| `moving` | 32-35 | **57-58** |
| `blocked` | 7 | 0-2 |
| degrees of body yaw turned | 126-168 | **291-542** |
| follow selections / arrivals (75 s) | 121 / 3 | **38** / 3 |
| move ticks with no waypoint (crossfire) | ~85% | **0** |

What was wrong:

1. **The turn ran before the decision.** `AI_ChangeYaw` sat one line above
   `AI_RunSchedule`, so the body turned toward the ideal yaw computed on the
   *previous* tick while the step was taken along the new one — permanently a tick
   stale, and against a moving leader it never converged. HL turns inside the move
   (`monsters.cpp:1847-1848`); it now does too. `AI_ChangeYaw` derives its own
   elapsed time from `.ai_yawtime` (HL's `m_flLastYawTime`) so calling it from two
   places does not double anyone's turn rate.
2. **The turn branch clobbered the walk cycle and nothing restored it.**
   `ai_moveact` is written only at task start and on a follow-band crossing, and
   that second site is guarded by `want != m.ai_moveact` — which is false after a
   turn, because it is the *activity* that got overwritten, not the field. Barney
   and scientist rigs carry no `ACT_TURN_*`, so they fell back to `ACT_IDLE` and
   then travelled at full running speed **in an idle pose**. That is the skating.
3. **`SCHED_FOLLOW` never dropped its stale route** — it has no `TASK_STOP_MOVING`,
   and leftover waypoints take priority over the goal, so a re-selected follower
   walked back toward where the leader *had been*. Now cleared when the goal moves
   further than the arrival radius. **Clearing it unconditionally is worse than not
   clearing at all** — measured: it took no-waypoint move ticks from ~85% to 100%,
   because follow re-selects far faster than `AI_REPATH_OK` allows a replacement.
4. **A route-less monster could not ask for a route.** The 1-second courtesy
   throttle applied even to a monster with no path at all, which beelines and
   presses into geometry. It may now skip the soft throttle; a genuine failure
   still takes the full hard backoff. This is the change that took no-waypoint
   ticks to **0**.

Plus a geometric fix for a route opening with a **backwards leg**: a path is
anchored at `Nav_NearestNode(origin)`, which is routinely behind the monster, and
is retired only within 48 units.

**New: `sv_ai_debug 2`** names what refused a step. `walkmove` returns a bare
FALSE, and a refusal rate cannot distinguish a wall from another monster from a
ledge. It re-sweeps as a tracebox **from a stepped-up origin** — the first version
swept flat from `m.origin`, which clips the floor on any non-level ground and made
every failure look like a wall. That correction changed the conclusion: on
`crossfire` the honest answer is `by FOOTING (sweep clear)`, i.e. `SV_CheckBottom`
refusing on sloped terrain, and on `hl_c01_a1` the residual blockers are **other
monsters** (48 barney, 27 scientist) — 44 escorts jamming each other, a test
artifact rather than a nav fault.

### Not fixed, and worth knowing

- **`hl_c01_a1`'s nav graph is genuinely broken**: 98 nodes in **8 components**,
  largest holding 39.8%, and **22 of 32 random node pairs have no path**. That is
  map data, not code, and it caps how confident any NPC can be there. `crossfire`
  by contrast is 701 nodes, 92.9% in one component, 28/32 reachable.
- The follow gait band is a start-stop generator: stop at 128, resume at 192, and
  *walk* below 190 at `ai_speed_walk` **61** for barney — far slower than a walking
  player, so an escort in the band can never keep station with a moving leader.

### Owed in game

- [ ] **Music level against gunfire.** `musicvolume 0.06` is a first guess made
      proportionate to `volume 0.07`; the slider and `mp3volume` are there to
      re-tune it by ear. Check a They Hunger map with an `ambient_music` placement.
- [ ] **`mp3volume 0` prints its warning** and music genuinely does not restart
      until the value goes back up — that is an engine gate, not a fade.
- [ ] **Barnacle tongues at different ceiling heights.** They should each reach
      their own floor. `cfg/aidebug.cfg` F6 spawns one — aim at a **ceiling**.
      A dead barnacle's tongue should vanish, not hang.
- [ ] **A tongue in a room taller than 512 units will clamp.** Expected; the wire
      cannot carry more.
- [ ] **Lead an escort round a doorframe and a pillar.** `sv_ai_debug 1` prints
      `sidestep=` and `cornercut=`; `sv_ai_debug 2` names the blocker. The walk
      cycle should now play while they travel — the specific thing to watch for is
      an ally sliding with its feet planted, which is fix 2 having regressed.
- [ ] **Escorts should no longer walk backwards** toward where you were standing.

---

## PATCH 131 — pickup respawn, the sound replacement layer, and the They Hunger entity gap

Two questions drove this: "Sven has a cvar that leaves map weapons on the ground
when you pick them up", and "what else do They Hunger and pizza_ya_san1 still
need". Both had a wrong premise, and finding that out was most of the work.

**`mp_respawnweapons` does not exist.** Not in any Sven cfg, the FGD, or any
AngelScript. The cvar is **`mp_weaponstay`** — `svencoop/server.cfg:34` sets it
to 1 and `default_map_settings.cfg:160-167` documents it. Three sibling delay
cvars sit beside it (`mp_weapon_/ammo_/item_respawndelay`) on a `-2 / -1 / 0 / >0`
encoding: no global delay / never unless the entity overrides / instant /
seconds. All four are implemented, plus the per-entity `m_flCustomRespawnTime`
override and the `Disable Respawn` spawnflag (1024), which wins over both.

**Shipped default 0, where Sven ships 1**, and that is deliberate. This mod's
campaign feel is single-player Half-Life, where a picked-up weapon is gone;
defaulting to 1 would silently change every existing map. `cfg/server.cfg` can
carry the Sven-faithful value.

**`mp_dropweapons` is a name collision — do not touch it.** Sven's is 0/1 "may
players drop weapons at all"; this mod's (`sh_cvar_table.qc:1917`, default 2) is
*what gear is dropped on death*. Same name, different meaning, and ours is
load-bearing. Noted in a comment beside it.

### What the census actually found

22 BSPs decoded (20 They Hunger maps + pizza_ya_san1/2, 22,744 entities), every
classname cross-referenced against the compiled server progs, then a second pass
that dumped every KEY per class rather than only presence.

**pizza_ya_san1 needs nothing** and did not before this patch either — zero
unimplemented placements.

**The per-class key dump is what earned its keep.** `env_shooter` — 55
placements across 15 of the 22 maps, the largest single gap — never appeared on
any "unimplemented classnames" list, because **a stub counts as implemented**: it
sat on `GoldSrc_InertMonster` in `sv_goldsrc_compat.qc:268`, spawned, invisible,
doing nothing. Presence-based auditing cannot see that class of hole.

Implemented this pass, all with their real HL/Sven keys and defaults:

| entity | placements / maps | what it is |
|---|---|---|
| `env_shooter` | 55 / 15 | model thrower — HL's `CEnvShooter`, which *derives from* `CGibShooter` |
| `env_glow` | 49 / 8 | sprite glow |
| `gibshooter` | 28 / 12 | gib emitter |
| `point_checkpoint` | 32 / 16 | Sven checkpoint: revives everyone who died before you touched it |
| `player_respawn_zone` | 25 / 14 | brush volume that gathers players to it |
| `trigger_hurt_remote` | 10 / 6 | hurts a NAMED entity, not the toucher |
| `env_blood` | 8 / 6 | mapper-fired blood spray |
| `func_healthcharger` / `func_recharge` | 5 / 3 here; 58 and 45 across the full corpus | wall chargers |
| `monster_grunt_repel` | 4 / 1 | the unprefixed twin of `monster_th_grunt_repel` |
| `monster_th_boss`, `monster_th_cyberfranklin` | 1 each, th_ep3_07 | the finale pair |
| `monster_snark`, `monster_rat` | 18 / 8, 1 / 1 | live snark, and one decorative rat |

**Neither boss is a new creature**, and reading the AngelScript rather than the
model is what showed it. `monster_th_boss.as` is Half-Life's `CApache` wearing
`hunger/boss.mdl` — same rotor loop, same `HuntThink`/`FlyTouch`/`DyingThink`/
`CrashTouch` machine, same `m_posDesired`/`m_vecDesired` steering, member name
for member name. `monster_th_cyberfranklin.as` is `CHGrunt`: its animation-event
codes are the hgrunt's verbatim (RELOAD 2, KICK 3, BURST1..3 4-6, GREN_TOSS 7,
GREN_LAUNCH 8, GREN_DROP 9, CAUGHT_ENEMY 10, DROP_GUN 11). Both are registered
as re-skins of archetypes this mod already had, with the party-scaled health
their scripts specify (1000 + 200/player, 400 + 110/player). That is the same
structural fact the campaign relies on everywhere else: **They Hunger is stock
Half-Life classnames wearing `models/hunger/*.mdl` skins.**

**Corpus result: 32 unimplemented classes across the 22 maps → 14.** Excluding
`th_escape` (deliberately out of scope, kept in the sweep as a stressor), what
remains on the 20 campaign maps + pizza is 11 placements across 10 classes:
`ambient_music`, `button_target`, `func_tankrocket`, `func_trackchange`,
`global_light_control`, `player_loadsaved`, `trigger_autosave`,
`trigger_changesky`, `trigger_condition`, `trigger_monsterjump`.

### The sentences claim was wrong, and the correction is the useful part

The plan asserted that `sound/hunger/hunger_sentences.txt` was unloaded and that
**all 73 `scripted_sentence` entities therefore had nothing to say**. Measured:
**69 of the 73 use Sven's `+path/file.wav` literal-sample form**, which
`sv_goldsrc_compat.qc` has implemented — and precached at spawn — all along. Of
the remaining four, three name stock Half-Life groups (`SC_TENT`, `BA_HEAR`,
`BA_QUESTION`) that already resolve out of valve's file. **Exactly one line in
the whole campaign needed the extra table** (`TH_SHERIFF` on th_ep2_00).

It is still loaded, because the mechanism is right even where the payoff is
small: `sentence_file` is a real worldspawn key (th_ep3_04 sets it), and a map
that omits it is recognised as They Hunger by the `globalsoundlist` it already
sets — the same key the sound replacement layer keys off, so the two cannot
disagree. Verified: **70 extra sentences, 1065 → 1135**.

### `globalsoundlist`

The sound twin of Patch 130's `globalmodellist`, and the broadest single gap
left: 12 of the 22 maps set it against `globalmodellist`'s 2. Same
builtin-rename trick — `sound`/`precache_sound`/`localsound` become `*_raw` in
the mod-owned defs and QC wrappers take the original names, so every call site is
routed with zero edits. Shared, not server-only: the client plays predicted
weapon audio through `localsound`, so a server-side table would leave every
predicted shot on the stock sample.

**`optional` was the obstacle and defltvalue was the answer.** `sound` has
optional parameters, and `optional` on a QC-defined function is banned here
(`optional_audit.py` exists because it has silently broken this codebase three
times; `qcc_pr_comp.c:9186`'s `&& !optional` means marking a parameter optional
*defeats* a declared default). fteqcc's own comment points at **default values**
instead, and they work — so the wrapper is audit-clean.

**There are two files called `hungerglobal.txt`.** `models/hunger/` holds a MODEL
pair list; the maps' `globalsoundlist` resolves under `sound/`, and that one is
the sound table. Reading the wrong one leads straight to the conclusion that the
feature is about models.

### Two bugs the self-tests caught that nothing visible would have

**`sv_pickup_test`** asserts the four states a player never observes: that a
weapon left standing under `mp_weaponstay` is still `SOLID_TRIGGER` *and still
`.touch`-wired* (`sv_use.qc:91` finds pickups by `e.touch == weapon_touch`, so a
stayed weapon that lost it is a gun you can see, walk into, and never pick up);
that its stored ammo cannot be re-farmed; that `m_flCustomRespawnTime` schedules
on time; and that spawnflag 1024 never revives.

Writing it found a real defect in the re-farm guard. The guard called
`W_SlotAmmo_ClearForWeapon(pickup, pickup.weapon)`, which routes through
`W_SlotAmmo_SetForWeapon` and writes `.slot_primary_*` / `.slot_secondary_*` —
**player fields**. What the next taker actually reads off the world entity is
`.weapon_drop_mag/_ammo/_aux` (`W_SlotAmmo_CopyDropToPlayer`,
`sh_weapon_slotammo.qc:309`). So the guard zeroed three fields nobody consults
and left the payout untouched — worse than nothing, because it *read* as
present. It also covered no melee or utility weapon at all, since
`SetForWeapon` only branches on PRIMARY and SECONDARY, which is most of the
grenade-shaped things worth farming. Fixed by clearing the drop fields.

**The per-map census lines latched on the wrong side of their own emptiness
check.** `[goldsrc-fx]`, `[checkpoint]` and `[charger]` each set their
"reported" flag on entry, then counted, then returned when the count was zero.
`AI_Tick`'s first call lands on a frame where the map's entity lump has not been
parsed — measured: 40 edicts, every classname empty, `time` 0 — so each report
consumed itself before there was anything to count and never printed again.
`Modellist_Report` tests `!ml_paircount` *in the same breath as* its latch for
exactly this reason. Ordering fixed; all three now print.

One more worth writing down, because it cost a build: **in fteqcc a second
declaration of an already-DEFINED function is not a harmless prototype** — it
re-emits the global as an empty function and every call silently returns 0. Two
files forward-declared `GoldSrcFX_Count` below its definition and the census
reported zeros on a map that demonstrably had the entities.

### Deliberate divergences, so nobody "fixes" them by accident

- **Chargers are driven by a held-`+use` poll, not by `.use`.** HL's chargers are
  `FCAP_CONTINUOUS_USE`; here `+use` arrives as `impulse 11`, fired once on the
  rising edge only (`cl_player.qc:414`), so a Use-per-press charger would need
  the key mashed ten times a second. `sv_momentary.qc` already solved this for
  the turn-wheels — `PM_BTN_USE` is set continuously in `input_buttons` — and
  `Charger_TickInteraction` is that function's shape, called from the same place.
- **Dropping is NOT disabled under weaponstay.** HL does that
  (`player.cpp:4679`); this mod has a whole physics-drop system and silently
  removing it would be the worse surprise. Draining the entity closes the
  exploit instead.
- **The gibshooter cone is re-derived from the shooter's own angles.** HL spreads
  the shot with `gpGlobals->v_right/v_forward/v_up`, which it never sets in
  `ShootThink` — those globals hold whatever the last `UTIL_MakeVectors` in the
  frame left behind, so HL's cone points somewhere arbitrary and different every
  firing. Ours points where the key means.
- **`env_glow` gets a toggle `.use`; HL's `CGlow` has none.** Ten placements
  carry a targetname (nine of them `bulb7`, beside the light they belong to).
  It still always starts VISIBLE — honouring a START_ON-style spawnflag would
  remove light the original game shows.
- **A live-gib cap of 96, recycling oldest-first.** HL has no cap because its
  gibs are client-side temp entities; ours are real edicts, and 21 of the 55
  `env_shooter`s set `m_flGibLife 600`. At the cap the oldest piece is recycled
  rather than the new throw dropped — a shooter that silently stops working is
  the worse failure, because the one the player is standing in front of is the
  new one.
- **`player_respawn_zone` relocates; it does not become the standing spawn
  point.** Reproducing that would put a second spawn-point source alongside
  `PlayerGetSpawnPointEntity`'s classname chain and the `.spawn_disabled`
  toggles the maps already drive (`sv_player.qc:39-46`) — two systems
  disagreeing about where a player belongs. The maps that care drive both.

### Verified headlessly

Both VMs **0 warnings**; `optional_audit` **PASS** (311 files). Entity counts
below were cross-checked against the BSP entity lumps and match exactly.

| map | result |
|---|---|
| th_ep3_00 | `gibshooter=2 env_shooter=3 env_glow=0 env_blood=0`, `point_checkpoint=1 player_respawn_zone=1`, `func_healthcharger=2` |
| th_ep3_01 | `gibshooter=4 env_shooter=3 env_glow=8 env_blood=1`, `point_checkpoint=2 player_respawn_zone=4` |
| th_ep3_04 | sentence file loads; **zero** unimplemented classnames; `monster_grunt_repel` resolves |
| th_ep3_07 | both bosses resolve — self-test table reports `monster_th_boss models/hunger/boss.mdl hp=1000` and `monster_th_cyberfranklin models/hunger/franklin2.mdl hp=400` |
| th_ep1_01 | `[sentences] 1135`, `[gsoundlist] 18 pair(s)`, `env_shooter=6 env_blood=2`, `point_checkpoint=2 player_respawn_zone=2` |
| th_escape | stressor — no regression; `env_shooter=6 env_glow=4`, `func_healthcharger=1` |
| pizza_ya_san1 | regression — still zero unimplemented, `[modellist] 20 pair(s)` |

All five pre-existing AI self-tests still `BAD=0` on every map, and
`[pickuptest] BAD=0`.

### Owed in-game (the harness cannot reach these)

- A weapon staying under `mp_weaponstay 1` and a **second player** taking it —
  the two-client case is the whole feature and the harness runs one client.
- Ammo / health / batteries reappearing on their respawn delays.
- A charger actually charging while `+use` is held, and its loop sound stopping
  when you walk away. Precache is verified; playback is not.
- Gibs and blood *looking* right — `env_shooter` throwing the right submodel,
  `env_blood` spraying the right colour, `env_glow` rendering additively.
  Nothing renders headlessly.
- Walking into a `point_checkpoint` while dead and being revived at it, with the
  lightning bolt.
- The They Hunger voice track (zombies, the Zork, the dog) instead of stock
  Half-Life, and the sheriff speaking `TH_SHERIFF` on th_ep2_00.
- The two `th_ep3_07` bosses fighting — they are registered as apache and hgrunt
  re-skins, so the archetype behaviour is inherited rather than newly written,
  but nobody has watched either one move.

---

## PATCH 130 — the model replacement layer, the last five keys, and eleven real weapons

Patch 129 answered "the NPCs do not show up". This is the audit that followed it:
every classname and every key in pizza_ya_san1's 897-entity lump, checked against
the compiled server progs rather than against memory.

**What the audit found.** One classname with no spawn function (`weapon_as_soflam`),
one worldspawn key that bound to nothing (`globalmodellist`), and five keys that
bound to a field nothing read. Everything else — all 55 map-placed classnames, 24
of the 25 squadmaker monstertypes — already resolved.

Three keys **look** missing and are not, which is worth recording so the next audit
does not re-open them: `m_iObeyTriggerMode` (×26) is inert because every value the
map writes already equals that class's FGD default; `spawnorigin` (×4) is a
compile-time lighting key set to `0 0 0`; and `m_flRepeat` on a `scripted_sequence`
is dead in Half-Life too — `CCineMonster` parses it at `scripted.cpp:80` and never
reads it. `target_count` is redundant by design: `TriggerRandom_FireOne` enumerates
the populated slots itself rather than trusting the count.

### globalmodellist — 722 call sites, no call-site edits

Sven's global model replacement file, the model-side twin of the per-monster
soundlist Patch 129 built. worldspawn names one file of old/new pairs and every
model matching the left column loads the right one instead; pizza_ya_san1 uses it
for **20 pairs** — the medkit, crowbar, glock, M16, grenade and barnacle grapple in
all three forms, plus the HEV battery as a rice bowl.

The obvious implementation is wrong. There is no single chokepoint: **401
`precache_model` and 321 `setmodel` calls** across `server/`, `shared/` and
`client/`, 231 of the setmodels one-per-weapon inside `shared/weapons/`. Wrapping
them by hand is 700 edits that rot the moment someone adds the 702nd.

What makes it cheap is that **the builtins are declared in mod-owned files**:
`sv_defs.qc:752`/`:815` and `cl_defs.qc:834`/`:891` bind `setmodel = #3` and
`precache_model = #20`, and each defs file is the FIRST entry in its `.src`.
Renaming those four declarations to `*_raw` and giving the original names to two QC
wrappers in a new `shared/sh_modellist.qc` — inserted second in both `.src` — routes
every existing call site and every future one through the remap. Inline BSP
submodels (`*43`) and `setmodelindex` are untouched: the lookup is an exact string
match and an index carries no path.

**It has to be shared, not server-only.** The first-person viewmodel is set
*entirely* by CSQC — `setmodel(csqc_viewmodel_ent, predicted_player.weapon_viewmodel)`
in `cl_weapons.qc`, from a compile-time constant in the weapon's own shared file —
and `.weapon_viewmodel` is never networked. A server-side table would remap monsters
and brushes and leave every gun in your hands stock.

Each VM sources the path its own way: the server declares `.string globalmodellist`
and reads it at the top of `worldspawn()`, before `precache_everything()` and
`AI_Init()` both precache wholesale; the client walks the BSP entity lump with
`getentitytoken` in `CSQC_WorldLoaded`, the way `cl_maplights.qc` already does.

Two things this cost that are worth knowing:

- **CSQC persists across a map change**, so `Modellist_Reset()` is not optional —
  without it map two keeps map one's replacements and leaks every strzone'd pair.
  `CSQC_WorldLoaded` opens by clearing stale lists for exactly this reason.
- **The client's report has to be `print`, not `dprint`.** `cfg/default.cfg` sets
  `developer 0` and re-execs on every map load, after any `+set` or bare
  `+developer` on the command line, so a developer-gated line in a per-map hook is
  invisible on the client however it was launched. `MapLights_Load` uses `print` one
  line below the same call site, for the same reason. This cost a full
  diagnose-and-rerun cycle: the client code was correct from the first build and
  simply could not say so.

### The four remaining keys

- **`spawn_mode`** (37 makers — 15 "block until clear", 22 "force spawn"). All three
  modes now exist. FORCE rides down to the child as `.ai_forceplace`, because the
  overlap is not discovered until `AI_Spawn` tries to stand the body up; BLOCK is
  handled by the maker, which is the only thing that can decide to try again — it
  gives the `monstercount` slot back, does **not** fire the target chain, and retries
  in 0.5 s instead of the full between-waves delay. Not firing the chain is the whole
  point: falling through would hit the Death fallback, which exists so a maker that
  can *never* produce a body does not stall the map, and on a momentarily blocked one
  that is a wave counter ticking up for a monster still on its way.
- **`onlytrigger`** (7 doors). Tested in `rotdoor_use` and **not** folded into
  `.door_player_usable`, because every reader of that field is additionally gated on
  `cvar("sv_door_use_only")` — a compat heuristic someone can switch off — while
  `onlytrigger` is a statement the mapper wrote into the BSP. `rotdoor_touch` needed
  the same guard separately or a player just shoulders the door open: the touch path
  re-enters `rotdoor_use` with `sv_use_is_player_direct` still FALSE, so that gate
  sees a body slamming into the brush as a trigger chain.
- **`damagetype`** (27 hurts: 23 nerve gas, 3 burn, 1 freeze). **The bits collide and
  a straight copy would have been a real bug.** This mod's own vocabulary
  (`sh_weapon_standard.qc:574`) shares Half-Life's NAMES and not its VALUES: our
  `DMG_SONIC` is 8 where HL's `DMG_BURN` is, our `DMG_CRUSH` is 16 where HL's
  `DMG_FREEZE` is, and both of ours are inside `DMG_GIB_CORPSE` — so assigning the
  map's key into `sv_dmg_bits` would have gibbed every corpse lying in a gas trap.
  Translated instead, and a `DMGHUD_*` byte now rides on `CSQC_EVENT_DAMAGE_FLASH` to
  tint the pain flash by cause. Adding that byte is a coordinated four-site change
  (both writers, the size table, the parser); `sv_player.qc:1229` documents what
  happens when those drift.
- **`linearmin`/`linearmax`** (17 of 18 ambients) and **func_tank's slew**. The
  falloff is an **approximation and is labelled one in the source**: FTE's `sound()`
  has no radius parameter and no falloff flag, so an exact linear curve would need
  `SOUNDFLAG_UNICAST` plus a per-player distance recomputed at 20 Hz — which restarts
  the sample every time, the exact problem the dedup latch exists to avoid.
  `linearmax` is converted to the attenuation that fades out at about the right
  distance: the wrong curve shape at the right reach, instead of ATTN_NORM's much
  shorter one. func_tank now slews at `yawrate`/`pitchrate` and honours the
  tolerances, driven through `avelocity` so `cl_brushsync.qc` extrapolates it
  smoothly — **zeroed on arrival**, or the client sails past the stop and snaps back.

**A pre-existing bug fell out of that last one.** `tank_fire` traced from
`makevectors(p.v_angle)` — the *operator's view* — while `tank_think` clamps the
*barrel* to `yawrange`/`pitchrange`. On any tank with an arc limit the shots already
left the visible arc; you could stand behind the gun, look backwards, and shoot
through it. Now aimed down the barrel, which is also what makes the tolerance gate
mean anything.

### Eleven weapons

Nine of these were **aliases that handed you a different gun** — `weapon_uzi` gave
you a CrossFire MAC-10, `weapon_sniperrifle` a Counter-Strike AWP, `weapon_minigun`
an M249 with no spin-up (its own comment called that "the weakest match of the
four"). `weapon_medkit` rewrote itself into a 25 HP floor pickup, flagged as an
honest downgrade in a comment that has now been cashed in. Every model and almost
every sound was on the mount, unused.

| Weapon | Was | Now |
|---|---|---|
| `weapon_medkit` | `item_healthkit` pickup | carryable healing tool, 100-charge pool, heals another player |
| `weapon_uzi` / `weapon_uziakimbo` | CF MAC-10 / CF Elite | the real pair, off the 17-file `uzi/` set |
| `weapon_minigun` | CS M249 | spin-up before it fires, which is the entire weapon |
| `weapon_m16` (Sven) | HL SMG | 5.56 rifle firing 5.56, so `ammo_556clip` finally feeds something |
| `weapon_pipewrench` | mod's wrench | with the charged big swing and its five unused samples |
| `weapon_sniperrifle` | CS AWP | M40A1 with its two-stage reload |
| `weapon_sporelauncher` | grenade launcher | spores out of `spore.mdl` |
| `weapon_eagle` | CS Deagle | OpFor's own, with its laser-sight samples |
| `weapon_as_shotgun` | **nothing** | the map's own 4-shell shorty |
| `weapon_as_soflam` | **nothing** | laser designator → 8-mortar airstrike |
| `ammo_uziclip` | **nothing** | the only FGD ammo class with no handler at all |

`weapon_as_shotgun` was a **live gap, not polish**: `pizza_ya_san.as:5` maps
`weapon_shotgun → weapon_as_shotgun` in `g_ItemMappings`, so every shotgun placed in
that map resolved to a classname with no spawn function.

Three model names were wrong when guessed from the classname and right when read off
the mount, and all three would have produced an invisible weapon: the medkit's world
model is **`w_pmedkit.mdl`** (`w_medkit.mdl` belongs to `item_healthkit`), the M16's
viewmodel is **`v_m16a2.mdl`** (there is no `v_m16.mdl`), and the akimbo UZI has **no
viewmodel of its own** — it is sequences 8–16 of `v_uzi.mdl`, which is why looking
for `v_2uzis.mdl` is a dead end. `v_medkit.mdl`'s holster sequence carries **fps = 0**,
so any duration computed from it divides by zero; it is hardcoded and the file has no
animation events, so the heal is a QC timer.

**Two substitutions, stated rather than hidden.** The mount ships **no minigun audio
at all** — not one file under `sound/weapons/` matches — and no M16-specific samples;
both borrow the SAW's set. If the real audio turns up it is a three-line change.

**A new self-test replaces a script that does not exist.** `sh_weapons.qc:585` cites
`check_serverfire.py` as the guard that keeps
`W_FireIsServerAutonomous` honest; there is no such file on disk. `AI_WeaponRosterSelfTest`
now runs on every headless map load and checks all 97 weapons for a manifest row and a
slot-ammo round trip in both directions — the mirror-table failure being the one that
is *invisible*, printing 0 on the HUD while the server holds the real value.

Its first run reported 12 failures, and **eleven of them were the test's fault**: it
demanded a magazine and a reserve from every weapon, which is wrong for the charge
weapons (gauss, egon, hornetgun, shock rifle, displacer, tesla), the mag-only ones
(grenade launcher, rebar, flak shotgun) and the two that carry neither (gravity gun,
grapple). Expectations now come from the manifest, so the test asserts the narrower
thing that actually breaks: a value a weapon *is* supposed to have must survive.

### Counters

Server and client progs **0 warnings** each. `optional_audit` **PASS** (306 files).
On pizza_ya_san1: `[modellist] 20 pair(s)` in **both** VMs with lookup, pass-through
and brush pass-through assertions passing; `[soundlist] 6 file(s), 158 pair(s)`
unchanged; `weapon roster: 97 weapons, 0 missing rows, 0 mirror failures`; squad
accounting / squad monsters / cover / schedules / squadmaker keys all `BAD=0`. On
hl_c01_a1 — a **valve-only** map with no globalmodellist — the modellist is
completely silent (0 log lines), every self-test still `BAD=0`, and no asset went
missing. All ~30 newly precached models and ~45 sounds resolve; the only "unable to
load" anywhere is the deliberate `__ai_probe_control__.mdl` negative control.
Manifest ordering re-verified externally: loadout, debug and buy runs all contiguous,
no gaps, no duplicates.

### Owed in game

- **The weapons in your hands are the pizza-shop reskins** — crowbar, glock, M16,
  grenade, medkit, bgrap, and the battery as a rice bowl. This is the payoff of the
  whole model layer and only a rendered frame can confirm it.
- **The eleven new weapons firing.** The roster test proves every one has a manifest
  row and a working ammo mirror, and the build proves every model and sound resolves
  — but **the debug weapon grid never spawned in any headless run**: `sv_debug_weapons`
  fires from `PutClientInServer`, and the headless client did not reach an in-world
  spawn on either map tried. So the spawn functions are verified to compile, precache
  and register; they are **not** verified to have run. Treat first play as the test.
- The medkit heals another player and refuses at full health with `medshotno1`. Note
  it does **not** self-heal — Sven puts that on secondary and that mode is not
  implemented, so on a server with nobody else on it this weapon has nothing to do.
- The minigun's spin-up gate — hold fire, wait, then it shoots.
- The pipewrench's charged swing on secondary.
- The SOFLAM's sky test: it should refuse a target with anything overhead, and the
  laser should turn cyan (and double to 16 shells) while you keep it on the strike.
- The seven `onlytrigger` doors refusing `+use`, and the gas traps flashing green
  rather than red.
- The mounted gun's barrel slewing rather than snapping, with its shots following it.

---

## PATCH 129 — pizza_ya_san1: the shop staff, and the keys that make an NPC friendly

The report was "the NPCs do not show up". One line of code, and then six more
things behind it that would each have shown up as the next report.

**Nothing was missing on disk.** All 32 NPC models resolve through the mounted
`svencoop_downloads` path, all 6 sound-replacement lists are present, and every one
of the ~500 `.wav` files they name exists. The map's AngelScript is 14 lines and
registers two weapons; it contains no NPC logic. Every fault below was in QC.

### The shop counter was empty because an untargeted spawner never starts

`squadmaker()` armed a think **only** for `spawnflags & START_ON`. Half-Life's
`CMonsterMaker::Spawn` (`dlls/monstermaker.cpp:110-137`) has a third branch the port
omitted:

```cpp
else
{// no targetname, just start.
        pev->nextthink = gpGlobals->time + m_flDelay;
        m_fActive = TRUE;
        SetThink ( &CMonsterMaker::MakerThink );
}
```

A maker with no targetname can never be triggered by anything, so HL runs it
unconditionally and mappers use that as the idiom for "this NPC is simply here".
pizza_ya_san1 has **97 squadmakers, zero of them START_ON**, and exactly three with
no targetname: the pizza shop owner, the chief and the leader. Ten
`scripted_sequence`s address them by netname, so the one missing branch also
starved the whole opening.

**Measured**: all three now build at t≈0.5 s —
`[monster] monster_human_grunt_ally "pizza shop owner" model=models/pizza_ya_san/owner_shin.mdl`,
`"cheif"` on `empenuze.mdl`, `"leader"` on `emptake.mdl`.

### `is_player_ally` is a FLIP, and it reached nothing

`AI_ClassOf` read `classify` then `ai_class` and **never consulted
`is_player_ally`**; `Monster_Spawn` wrote `respawn_as_playerally` into
`.is_player_ally`, which `AI_ClassInit` then overwrote with the class default a
moment later. So 14 squadmakers and 2 map-placed NPCs on this map were
`+use`-followable **and hostile**.

The key is not a boolean. The FGD spells it three ways and they all mean the same
thing — a plain monster reads "No (Default) / Yes", a talkmonster reads "Yes
(Default) / No", squadmaker's `respawn_as_playerally` reads "Default (0) /
Opposite (1)". One rule covers all three, and only a flip explains why this map's
four seated customers are a `monster_human_assassin`, a `monster_zombie`, a
`monster_babygarg` and a `monster_male_assassin` wearing custom models. The map key
now lands in `.ai_ally_flip` at build time and is applied in `AI_Spawn` **after**
`AI_ClassInit`, which is the earliest point the class default exists.

`SF_MON_PRISONER` (16) — "never fights, never targeted" — had been declared since B2
and read nowhere. It is honoured in `AI_ValidEnemy` in both directions now, and a
prisoner is deliberately **not** `+use`-followable: every one on this map is held by
a scripted_sequence, and marching a seated customer around the shop is not the
interaction the map offers.

Two more tri-states that were being read as booleans: `gag` is `-1 Default / 0 No /
1 Yes` and all 19 of this map's NPC spawners write `-1`, so as plain truthiness every
customer, both clerks and every stray dog was muted by the key that means "nothing
special"; and `bloodcolor` is `0 default / -1 none / 1 red / 2 yellow`, where 1 and 2
are *symbols* rather than palette indices and `-1` was being clobbered by every class
init's `if (bloodcolor <= 0)` default (narrowed to `== 0`, 20 sites).

### The Japanese voice track was parsed and thrown away

`.soundlist` was declared "accepted, not implemented", read nowhere, and **not even
copied to the children**. New `server/sv_soundlist.qc`: a flat old→new pair pool
shared between makers, parsed and precached once at map parse, with `AI_Sound` /
`AI_SoundEx` as the drop-in `sound()` chokepoint — 61 emission sites across the AI
layer and the monster classes now route through it.

The trap in this feature is that the lookup is keyed on the **left** column, which is
the path *Sven's* monster emits — so a class of ours that spells its sounds
differently silently matches nothing, however correct the parser is. Three classes
were exactly that, and all three are fixed at the emitting class because matching
Sven's paths is right independently of any map:

| class | emitted | Sven, and what the map remaps |
|---|---|---|
| `monster_human_grunt_ally` | `hgrunt/gr_pain%g`, `hgrunt/gr_die%g` | `fgrunt/gr_pain1-6`, `fgrunt/death1-6` |
| `monster_babygarg` | `garg/gar_*` | `babygarg/gar_*` |
| `monster_alien_babyvoltigore` | *the classname appeared nowhere in the mod* | `baby_voltigore.mdl` |

Both voice swaps are guarded on the folder being mounted (`Monster_SoundExists`), because
`fgrunt/` and `babygarg/` are svencoop content and trading "sounds like the wrong monster"
for "silent" is the worse of the two on a valve-only install.

**Measured**: `[soundlist] 6 file(s), 158 pair(s)`, 0 missing on disk, and a
lookup + pass-through assertion per file —
`ownershin.txt: 61 pairs, "fgrunt/ass.wav" -> "pizza_ya_san/koraa.wav"`,
`electro.txt: "babygarg/gar_alert1.wav" -> "uboa45/electro/idle1.wav"`,
`houndeye.txt: "houndeye/he_alert1.wav" -> "hungerzork/ag_alert3.wav"`.

`daikonfarmer.txt` has two lines with an unterminated closing quote; the parser
tolerates them. Termination is a run of empty reads, not `while (line)` — the same
constraint `Sentences_Load` documents, because QC cannot tell fgets' EOF null string
from a blank line.

### Four more, all of which would have been the next report

- **44 of 97 squadmakers dispense items, not monsters** — `ammo_9mmbox` ×9,
  `ammo_buckshot` ×8, `ammo_556` ×7, `ammo_rpgclip` ×7, `ammo_ARgrenades` ×5,
  `item_healthkit` ×4 and four guns, i.e. the entire resupply for the radar sequence
  and the shop siege, and `Monster_Spawn` only ever built monster bodies. Dispatch
  now runs through `Breakable_ObjectName` **backwards**, so there is no parallel table
  to drift; `weapon_as_shotgun` maps to the shotgun exactly as the map's own script
  does. Every one is `monstercount -1`, so the live cap is enforced by scanning
  (`.sq_ownerid`) rather than latched — a pickup can leave the world four different
  ways and hooking all four is the bug the latch exists to avoid.
- **`trigger_target` fired on spawn**, and all 28 users on this map set
  `trigger_condition 4` = Death. `cnt_meatshop`/`cnt_vegeshop` want 15 dead stray dogs
  and `cnt_finale` wants 40, so the shop sequence completed while its dogs were still
  standing. It fires from `Monster_Killed` now, with a spawn-time fallback when the
  maker can produce no body at all — a map waiting on kills that cannot happen is
  stalled forever.
- **The live cap was gated on the child having AI**, so a maker with an
  unimplemented class free-ran at its `delay` forever: `ml_flour5` pumped twelve
  counts into `cnt_flour` in six seconds while producing nothing.
- **Failed placement was permanent and silent.** `AI_Spawn` left the body inert, an
  inert child can never die, its slot never came back — and **72 of 97 makers have
  `m_imaxlivechildren 1`**, so one blocked spawn killed that spawner for the rest of
  the map, with the only trace behind `sv_ai_debug` (default 0). The child is now
  removed and the maker retries, which is HL's own behaviour
  (`monstermaker.cpp:172-186` boxes the spawn point first and simply does not spawn).
  Related: `Monster_ClassHull` had no turret case, so all four of this map's
  **ceiling-mounted** turrets wore the human hull; HL sizes them symmetrically about
  the mount (`turret.cpp:308`, `:340`).

### Also fixed, outside this map

- `HGruntAlly_ClassInit` never called `AI_MakeTalker`, so **406 grunt allies** had no
  head turn, no jaw and no idle behaviour. Group `"FG"`, deliberately: valve's is the
  only `sentences.txt` this install loads and it has no `FG_` groups, so he gets the
  look-at behaviour and stays quiet rather than shouting English military callouts —
  and if op4's file is ever mounted (145 `FG_` groups over `fgrunt/*`) those lines
  light up *and* land on the remap, which is what the map is built for.
- `Scientist_ClassInit` set neither `.ai_painsound` nor `.ai_death`, and `AI_Damaged`
  requires one — so **271 scientists** took a crowbar and died in silence. HL's
  `DeathSound` is literally `PainSound()` (`scientist.cpp:826`).
- Sven's `weapons` bits 16 (SAW), 32 (No Weapons) and 256 (Don't drop) matched nothing
  in the mod's set. The shop owner is `weapons 16` on a rig whose firing sequences are
  `standing_saw` / `crouching_saw`, so he asked for a sequence his model does not own
  and fired from an idle pose; `mon_employeeuboa` is `weapons 32` and was issued an MP5
  and dropped one on death.

### Counters

Server progs **0 warnings**, client progs **0 warnings**, `optional_audit` PASS
(294 files). Three headless self-tests, all `BAD=0` on both pizza_ya_san1 and
hl_c01_a1: `squad accounting`, `squad monsters`, and a new **`squadmaker keys`** case
covering the ally flip in both directions, the no-flip case, the prisoner gate from
both ends, and the item dispenser's cap and refill. Sound register 225 registered,
0 missing. `[soundlist] 6 file(s), 158 pair(s)` with no missing targets.

The squad-accounting test was rewritten: it used to assert that three children spawned
at the world origin were counted "whether or not a body could be stood up", and both
halves of that are now wrong — an unplaceable child is dropped, *and* placement at the
origin does not reliably fail (measured: all three stood up on pizza_ya_san1). It now
asserts the invariant instead — booked slots must equal children actually in the world —
which is true either way and is the property that matters.

### Owed in game

Only play reaches the story, which is gated behind `trigger_vote vote_start` and then
15 `ml_gomi*` trash buttons → `cnt_gomi` → `mm_kyaku` → `sq_kyaku1`:

- The three staff standing at the counter on load, **and not shooting you**.
- Collect the 15 trash items: the four seated customers should appear, stay seated,
  and stay peaceful. That is the cheapest live test of the flip + prisoner path.
- The owner should say `koraa` / `arigato` rather than English grunt lines, and the
  stray dogs should bark the `hungerzork` set.
- **Bodygroups.** Five NPCs set `new_body 1`/`2` (nekomata JK, electro, daikon farmer,
  the houndeyes). `.body` is set server-side but only reaches the client on a
  protocol-negotiated path — the same mechanism that failed for the tripmine. A
  customer showing the wrong sub-model is this, not the spawn work.
- Break a flour sack: the babyvoltigores are newly implemented and have never been
  seen, and `baby_voltigore.mdl` is being driven by the adult's event table.
- Check no cfg sets `sv_sound_strip_undecodable 1` — it rewrites `.mp3` sample paths
  and would silence all seven of the map's BGM tracks.

Two known map warts, expected rather than bugs: `scrp_shin3` plays sequence `idle`,
which `owner_shin.mdl` does not have (it has `idle1`/`idle2`), and `ml_finale3` is
referenced by nothing in the map.

---

## PATCH 128 — the assassin's trigger, and corpses that bleed

### The assassin had never fired a shot

`monster_human_assassin` / `monster_male_assassin` — **504 placements**. `hassassin.mdl`'s
`shoot` sequence raises event code **1** (`ASSASSIN_AE_SHOOT1`, `hassassin.cpp:57`), and
`Assassin_ClassInit` inherited `Grunt_Event`, whose lowest handled code is 2. Her shoot fell
off the end of the dispatch; her grenade toss **is** code 2 and was swallowed by the grunt's
reload no-op. They chased you and mimed.

Now `Assassin_Event`, with HL's escalating accuracy (`hassassin.cpp:201-210`): the cone
opens to 0.10 after a two-second lull and walks shut by 0.01 per round to a floor of 0.02.
Sustained fire is what makes her dangerous; breaking the streak is the counter.

**Measured**: `[ai] shots: grunt=0 barney=0 assassin=15` on fresh progs.

Her grenade handler is written but **inert on purpose** — `hassassin.cpp:688` gates the
throw on `m_iFrustration > 2`, a counter that only climbs when she cannot reach or hit you.
Handing her grenades without it would make her open every fight with one.

### Corpses — and a correction to our own comment

`sv_ai_core.qc` said *"Corpses do not block. HL makes them non-solid for the same reason"*
and went `SOLID_NOT`. **Half-Life does not.** `schedule.cpp:451-468` has the
`pev->solid = SOLID_NOT;` line **commented out** and squashes the bbox to a one-unit-tall
pancake instead — solving the exact problem (bodies blocking a doorway) without giving up
the body. That one line was why nothing about corpse damage worked.

`BecomeDead()` (`combat.cpp:518-532`) is now mirrored exactly: stays `DAMAGE_YES`, gets
`max_health/2` as its own gib pool, and `max_health` is repurposed as a blood-decal budget.

Damage type arrives through a new `sv_dmg_bits` global — 0 means bullet, and only the
handful of non-bullet sources set it. That is 8 edits instead of 58, and the same shape as
the `sv_in_radius_explosion` flag directly above it.

**Measured, `sv_ai_corpsetest 1`:**

```
[corpse] killed "monster_headcrab": deadflag=2 solid=3 takedamage=1 health=5 size_z=1
[corpse] 10 bullets: hits=10 gibs=0 (gibs MUST be 0) health=5
[corpse] club swings to gib: 17 (chips=16 gibs=1)
```

Bullets bleed a body and never break it — `DMG_BULLET` is deliberately absent from
`DMG_GIB_CORPSE` (`cbase.h:638`). Club/blast/sonic/crush chip it by `damage * 0.1` and the
hit that lands over the remainder tears it apart.

**Three defects the numbers caught, all fixed:**

1. `max_health` was never recorded at spawn, so the corpse pool was derived from a health
   that was already zero — every body came out at 1 HP and burst on the first swing.
2. A freed edict keeps returning its old field values for the rest of the frame, so a
   shotgun's remaining pellets or a radius blast walking its list would re-enter the corpse
   branch and gib the same body repeatedly. `Monster_Gib` now tears down the identity
   *before* the remove.
3. `AI_PublishMonsterModels` rebuilt its set from `monster_chain`, which corpses **leave**
   on death — so when the last live grunt died, every grunt corpse stopped being traceable
   by the shooter's own client. Bodies bled only while one of their kind was still alive.
   The set now accumulates and never forgets.

**Owed check A — gib appearance.** Gibs are CSQC-spawned, and `setcustomskin` is live for
CSQC (`pr_csqc.c:7152`) even though it is `PF_Fixme` on the server — so `hgibs.mdl`'s 11
submodels and `agibs.mdl`'s 4 are selectable **today**, without the engine bodygroup work.
Human classes throw 5 chunks, alien 4, launch speed scaled by overkill (×0.7 / ×2 / ×4).
None of it has been looked at.

**Owed check B — corpses are solid now.** They keep their x/y footprint and collapse to one
unit tall. Walk over a pile of bodies and check nothing snags. This is the one item with a
real fallback if it feels wrong (per-class `SOLID_NOT`).

Regression after both: five maps, `BAD=0` on both self-tests, errors 0, **crashaddr
unchanged at 1824**.

---

## PATCH 127 — the headless CLIENT, and the four HL equipment weapons

### The harness changed: a real client, no window

FTE ships a null renderer (`engine/client/vid_headless.c`, `QR_HEADLESS`) and
`config_fteqw.h` leaves `HEADLESSQUAKE` defined, so the shipped `fteqw64.exe`
can run as a **real connected client with no window**:

```
fteqw64.exe -game quakers -nohome +set vid_renderer headless \
    +developer 1 +sv_debug_ent_types 1 +connect 127.0.0.1:27500
```

Driver: `/c/tmp/hlclient.sh <map> <seconds> <tag> [server args...]`.

Three things had to be right before it produced anything:

| symptom | cause |
|---|---|
| "Connection lost or aborted" every retry | `+set port 27500` is ignored; the server binds an ephemeral port. Use **`-port 27500`** |
| client in-game but every test stalls "waiting for a live in-world player" | a client with nobody at the keyboard sits in **team select** forever at `SOLID_NOT`/`MOVETYPE_NONE`. New **`sv_autojoin 1`** takes the same path the menu button does |
| every developer-gated CSQC `print()` silently missing | `cfg/default.cfg:115` sets `developer 0` and execs **after** every `+set` on the command line. Pass the bare command form `+developer 1` as well |

### The grenade: both halves now proven correct, so it is not what it looked like

`sv_proj_test 1` spawns one **world-owned** HL grenade 64 units in front of you.
That matters because `projectile_SendEntity` hides a projectile from its owner —
so in single player the replicated path is **only** ever exercised by a monster's
grenade, and the player's own is always the CSQC-predicted fake.

Driven through the headless client, the CSQC entity is created, holds
`modelindex=388` and `drawmask=1`, sits at a sane origin, and **survives the full
24 s of the test** (48 consecutive live samples). Server side was already proven
last patch. Both halves are correct; whatever you saw is in the final draw, which
is the one step the headless renderer cannot reach.

**Owed check 1.** `sv_proj_test 1` in-game. If you can see that grenade, the
replication path is fine and the grunt's throw differs for some other reason; if
you cannot, it is the renderer and the next step is a `predraw` breakpoint.

### While packing: the CSQC half of Patch 126 had never shipped

`quakers_csprogs.pk3` contained the montrace work but **not** the `[proj]`
diagnostic — `cl_progs.src` was compiled before that edit and the pack ran on the
stale `.dat`. So Patch 126's monster-collision bleeding may not have been in the
build you played. It is now. `/c/tmp/hlclient.sh` refuses to launch if any
`client/` or `shared/` source is newer than the packed pk3, checked **separately**
from the server's own staleness test.

### The four weapons — satchel, tripmine, snark, hivehand

Ported from `satchel.cpp`, `tripmine.cpp`, `squeakgrenade.cpp`, `hornetgun.cpp` +
`hornet.cpp`. Sequence indices were read out of the models, not the enums, and
they agree. Damage from `valve/skill.cfg`: satchel 150, tripmine 150, snark
bite 10 / pop 5 / health 2, hornet 5. Radii are HL's derived `damage * 2.5`.

All four use the mount's **GoldSrc IDST viewmodels directly**
(`weapon_uses_sequences = TRUE`) — no converted IDPO copies needed.

**The `w_tripmine.mdl` compromise turned out not to exist.** HL draws the deployed
mine as `v_tripmine.mdl` at body 3; FTE cannot select that (`gl_hlmdl.c:1767`
hardcodes `entity_body = 0`, and `cl_ents.c:5109` clears `customskin` for every
replicated entity). But `p_tripmine.mdl` has one bodypart, `reference_tripmine` —
already the bare mine with no hands, which is exactly what body 3 selected.

Verified headlessly with `sv_hlequip_test 1` (fires each weapon once, 2 s apart,
then counts what is alive):

```
[tripmine] placed at 536 272 -232 normal=0 0 1 surface="worldspawn"
[tripmine] armed, beamfrac=0.0644
[tripmine] beam broken: was 0.0644 now 0.0096 by "monster_snark"
[tripmine] delaydeath -> explode ; beams still alive=0
[hlequip] satchels=0 (thrown AND detonated) mines=0 snarks=1 hornets=2 beams=0
[hlequip] ammo left: satchel=4 tripmine=4 snark=14 hornet=6
```

The snark walking into the tripmine's laser was not staged — it is a behavioural
proof that the snark hunts and that the beam-break test fires on a real mover.

**Two real bugs the test caught, both since fixed:**

1. **The two hornets annihilated each other** — `[hornet] died on "hornet" after
   0 s`. `hornet.cpp:369` ignores another hornet by modelindex *and* goes
   `SOLID_NOT` so the pair stop re-touching. I had also collapsed `TrackTouch`
   into `DieTouch`: a **tracking** hornet bounces off anything it will not hurt
   (`hornet.cpp:376-388`) and only the fast dart dies on contact. Now `hornets=2`.
2. **`.takedamage` is not the test for a player in this mod** — players sit at
   `DAMAGE_NO` and are accepted inside `W_CanDamageTarget` (`sv_weapons.qc:1149`).
   Gating on it alone meant a snark bit crates and monsters but walked straight
   over the person it was hunting. Same fix in the hornet.

Also fixed: the snark's kill credit. `squeakgrenade.cpp:266` clears `pev->owner`
on the first bounce — that is what lets a snark turn round and bite its thrower —
but keeps `m_hOwner` for attribution. Collapsing the two handed every snark kill
to the snark; `.snark_owner` is now separate.

**Owed check 2 — the satchel's two-viewmodel dance.** Throwing swaps you to
`v_satchel_radio.mdl`; `+attack2` detonates every charge you own anywhere on the
map and the idle swaps the satchel back. The state machine is measured, the model
swap is not.

**Owed check 3 — tripmine placement orientation.** `p_tripmine.mdl` is authored to
hang off a player's hand, so its origin/rotation may not sit flush against a wall
the way `v_tripmine`'s world bodygroup would. The mine is placed at
`endpos + normal*8` facing `vectoangles(normal)`, which is HL's own maths; if it
looks wrong it is the model's pivot, not the placement.

**Owed check 4 — the tripmine laser.** It rides the shipped `env_beam` transport
(`CSQC_ENT_ENV_BEAM`) at HL's colour `0 214 198`, brightness 64, width 10. The
beam entity is created, sent and cleaned up (`beams still alive=0` measured at the
moment of death) — but nobody has looked at it.

**Owed check 5 — the hornet's flight.** Tracking uses HL's turn-rate falloff
(`hornet.cpp:243`: the wider the turn the slower it goes). Two speeds, red 600 /
orange 800, two-in-five red. Measured to exist; not watched.

Regression after all of the above: five maps, `schedules: 27 built, 110/384 tasks
used, BAD=0`, `squad accounting: BAD=0`, errors 0 on every map, **crashaddr
unchanged at 1824**.

---

## PATCH 126 — NPC fidelity from the Half-Life SDK

**The SDK is on this machine**: `/c/msys64/home/Lex/halflife/dlls`, 104 `.cpp` files.
Everything in this section was read out of it rather than recalled, and each item
below cites the file and line it came from. That changes the character of this
work — these are ports, not reimplementations.

### Verified headlessly (numbers in the session log)

| what | evidence |
|---|---|
| Barney's fire sound | was `weapons/hks*.wav`, the **player's MP5** (`mon_grunt.qc:115`). Now `barney/ba_attack2.wav` with HL's lopsided pitch shift (`barney.cpp:356-364`) |
| one report per burst | HL emits the gun sound on **BURST1 only** (`hgrunt.cpp:913-937`); ours played it on all three codes, stacking three overlapping samples per burst |
| shotgun grunts | `HGRUNT_SHOTGUN` had been declared and never read, so `weapons/sbarrel1.wav` was precached and never once played. Now one 5-pellet blast at `VECTOR_CONE_15DEGREES` (`hgrunt.cpp:828`, `sk_hgrunt_pellets2`) |
| Barney's accuracy | was the grunt's 5°; `barney.cpp:355` is `VECTOR_CONE_2DEGREES` |
| provoke escalation | measured end-to-end: hit 1 aimed away → `dot=-1 stray`, `memory=1` (SUSPICIOUS), still friendly; hit 2 → `memory=3`, `enemy=PLAYER`; then `forgiven=1` exactly 6 s later at `sv_ai_grudge_time 6` |
| scientists provoke instantly | `scientist.cpp:771-778` has no facing test and no line — and `SC_MAD`/`SC_SHOT` genuinely do not exist in `sentences.txt`, so that is deliberate on Valve's part, not an omission |
| the complaining scientist | `SC_SCARED` is HL's `TLK_NOSHOOT` group (`scientist.cpp:745`), spoken by a **bystander** when a player *damages* a talker (`talkmonster.cpp:1193`). Ours fired it on every gunshot within 1280 u. Measured `noshoot=1` per provoke now |
| monster model broadcast | `published 4 monster modelindexes to clients` on `hl_c01_a1` |

### Ground speeds — the animation is the speed

HL never stores monster speeds as constants: `GetSequenceInfo`
(`animation.cpp:245-249`) derives them from each sequence's own baked
`linearmovement`, so the gait and the travel rate physically cannot disagree.
Ours were hand-typed and **almost every run was about half its real value** —
which is exactly "they move at walking speed while using their running animations".

Measured off the shipped models with the programme's struct reader:

| | ours was | real | |
|---|---|---|---|
| barney | 160 | **362.4** | 44% of its own run cycle |
| hgrunt | 180 | **304.0** | |
| scientist | 170 | **275.4** | (RUN_SCARED is 315.5) |
| houndeye | 200 | **409.6** | |
| assassin | 220 | **483.4** | the fastest thing in HL |
| gargantua | 180 | **356.0** | |
| headcrab | 150 | **50.2** | *slower* — its threat is the leap, not the chase |
| zombie | 40 | **72.5** | |

Flyers and swimmers (controller, ichthyosaur, leech, apache, osprey) measure 0
because HL moves them in code, not animation — their hand-set values were left
alone.

### Where the walk animation went

`SCHED_FOLLOW` asked for `ACT_RUN` unconditionally, and following is the only
movement most allies ever do — so the walk cycle was effectively unreachable in
normal play. HL picks by **distance**, not by schedule:
`TASK_MOVE_TO_TARGET_RANGE` (`AI_BaseNPC_Schedule.cpp:429-436`) walks under 190,
runs at 270 or more, and holds in between (the SDK's own comment: "overlap the
range to prevent oscillation").

*My plan said HL picks the gait by monster state. That was wrong — it is baked
per-schedule and per-distance. Corrected against the source before implementing.*

---

## Owed in-game checks from Patch 126

Client-visible, so headlessly unverifiable — **please check these with the new
`fteqw64.exe`**:

1. **NPCs bleed when you shoot them.** Monsters are engine entities and were
   invisible to CSQC's trace, so the shooter's bullet passed *through* them and
   the local impact landed on the wall behind — as concrete, with a bullet hole,
   at the wrong depth. Everyone else saw it correctly, because they get the
   server's version; the shooter is the one player `W_ImpactEffectSend` skips.
   Now ray-vs-AABB over `getentity()` (`cl_monstertrace.qc`).
   Console check: `developer 1` prints `[montrace] models=N sweeps=N monster-hits=N`.
2. **Heads move smoothly.** Bone controllers were taken raw at the AI think rate
   (10 Hz) while the body interpolated. Now blended — but **only for bounded
   controllers**; wrapping ones (`type & 0x8000`) still snap, which is what the
   original "never interpolate" note was really protecting.
3. **Mouths follow the actual audio.** Was `0.5 + 0.5*sin(time*22)`, unconnected
   to the sound. GoldSrc drives the jaw from the sample's amplitude in the *sound
   engine*, and `S_GetChannelLevel` already computed exactly that and had no
   callers. Now wired into controller 4 and scaled into each model's own range.
4. **Brushes through the They Hunger skybox.** `gl_warp.c:480` names the symptom
   verbatim. The cause: when the sky shader carries a GLSL program — the normal
   case — `R_DrawSkyChain` returns "draw as normal" from *above* the
   `GL_SkyForceDepth` call at the bottom, so the mask never runs. World geometry
   is still hidden by BSP PVS, which is why the leak shows as entities and never
   as walls. Fixed behind **`r_sky_forcedepth`** (default 1); set it to 0 to
   confirm the diagnosis by making the bug come back.
5. **`r_hlmdl_seqblend 1` — animation blending.** `gl_hlmdl.c` has carried
   `FIXME: we don't handle frame2` forever: HL models never cross-fade between
   sequences, they snap. The data was already being computed and discarded.
   **Default OFF** — it is the hottest path in HL model rendering and affects
   every studiomodel including players, and I cannot see it. Turn it on and judge.
6. **The grunt's grenade.** The server side is *proven* correct — measured
   `modelindex=388`, live velocity, `SendFlags` bumped every tick. So the fault is
   client-side. `developer 1` now prints `[proj] new type=N model="..." modelindex=N`
   on every projectile: modelindex 0 means the client never precached it, an empty
   model string means the type byte did not resolve. One throw names the cause.

---

## PATCH 125b — bone controllers were never actually switched on  *(CORRECTION)*

**Patch 125 was reported as working and was not.** Every part of the feature was
correct — the QC set the values, the delta flagged them, the writer wrote five
shorts, the reader read them, the renderer consumed them — except that the
extension bit was never put in an advertised mask. `PEXT2_BONECONTROLS` appeared
only in `PEXT2_CLIENTSUPPORT`, which is the *"warn about unknown bits"* set, not
the offered one. `Net_PextMask()` never returned it, so neither side offered it,
negotiation always came back 0, the server's `pext2 & PEXT2_BONECONTROLS` gate was
never true, and **not one byte of bone-controller data was ever transmitted.**

That is why head turn and mouth both did nothing, and why "I traced the whole path
and it looks right" was worthless as evidence — the path *was* right, and switched
off.

One line in `common/net_chan.c` fixes it, inside the replacementdeltas block
(the payload rides in `UF_BONEDATA`, which only exists in that stream).

**Verified, not inferred:** a real client against a real server now logs
`client: pext2=0x97f bonecontrols=YES deltas=YES`. `0x97f` contains `0x800`.

There is now a permanent connect-time line (`developer 1`) reporting exactly this
per client, because a silently-unnegotiated capability is indistinguishable from
QC that never ran.

- [ ] **Heads should track you** (±60° scientist/barney/otis, ±70° hgrunt).
- [ ] **Jaws should move while talking.**
- [ ] **Turret guns should lead and elevate**; the barnacle tongue should stretch.
- [ ] Confirm the line above appears when you connect.

## F4 test bench — nothing was clickable

`NPC_PanelInputEvent` swallowed the mouse and returned TRUE **without ever calling
`sui_input_event`**. SUI is where the cursor lives and where `sui_action_element`
hit-tests, so no widget was ever under the pointer: every button drew, none ever
highlighted, none ever fired. The panel looked complete and was completely inert.

F1 (`cl_debugpanel.qc:297`), F2 (`cl_serverpanel.qc:1026`) and F3
(`cl_carpanel.qc:412`) all forward then absorb; F4 was the only one that did not.
Now matches.

## Level transitions corrupted textures

**Not a renderer bug — a WAD resolution bug.** The create-server menu loads a map
as `map "@<spec>/<name>"`; `SV_Map_f` stashes the spec, `SV_SpawnServer` biases the
worldmodel *and the texture WAD lookups* to that game, and publishes it as the
`*mappref` serverinfo key. A bare `changelevel foo` deliberately **clears** that
hint (`sv_ccmds.c:751` names changelevel as one of the paths that must not inherit
a stale one), so the next map's WADs resolve by plain mount priority instead.

The names collide and the content does not. Measured on this install:
`halflife.wad` exists in `Half-Life/valve`, `Half-Life/bshift` and
`Sven Co-op/svencoop`, **all three exactly 37,914,096 bytes, and valve's MD5
differs from the other two.** Same name, same size, different texture data — so a
map that loaded its WAD from one game and then gets another after a transition
renders every face with the wrong pixels. `hl_c01_a1 → a2` and the Opposing Force
maps are exactly the ones that hit it.

Both QC changelevel sites now re-attach the spec. The `@` form is explicitly
exempt from the package-manager's gamecode block (`sv_ccmds.c:817` tests
`*mangled != '@'`), so QC is allowed to use it.

- [ ] **Walk `hl_c01_a1` → `a2` and check the textures survive.** Then an Opposing
      Force chapter transition.

## GoldSrc / OpFor / Blue Shift pickups — weapons and ammo are complete

Census across all four mounted games (125 valve + 55 gearbox + 37 bshift + 108
svencoop maps): **72 distinct pickup classnames, ~7500 placements**, almost none of
which had a spawn function — so they were becoming invisible inert relays.

**As of PATCH 142 every weapon and ammo placement in all four mounted corpora
resolves — 7194/7194, 100%**, across 338 maps:

| corpus | maps | placements | resolve |
|---|---|---|---|
| valve | 125 | 1763 | 100% |
| gearbox | 68 | 2125 | 100% |
| bshift | 37 | 120 | 100% |
| svencoop | 108 | 3186 | 100% |

Measured with `scratchpad/wpnresolve.py`, which scores placed classnames against
the spawn functions that actually exist in the tree. Gearbox went 62% → 100%.

**PATCH 141 claimed this and was scoped too narrowly:** it measured valve,
gearbox and bshift (4008 placements) and did not include svencoop at all, which
was still at 98% — and svencoop is the corpus the Sven `hl_` campaign maps belong
to. Do not read a resolve percentage without checking which corpora it covered.

What remains unresolved in these maps is entity logic, not pickups:
`point_checkpoint`, `gibshooter`, `env_glow`, `func_healthcharger`, the vehicle
classes.

Note for anyone re-running the older `wpncensus.py`: it reads BSP lump 0 as the
entity lump, and **Blue Shift swaps lumps 0 and 1**, so it silently reports zero
for all 37 bshift maps. `wpnresolve.py` picks whichever lump actually looks like
text.

**Now working (name-only aliases to guns this mod already has):**
`weapon_shotgun` (186), `weapon_9mmAR` (214), `weapon_mp5`, `weapon_9mmhandgun`,
`weapon_handgrenade` (458 — the single biggest), `weapon_rpg` (104),
`weapon_egon`, `weapon_python`. Plus real pickups for **`item_suit`**,
`item_battery`, `item_longjump`, `item_antidote`, `item_security`.

`item_suit` grants armour (50, capped 100; battery 15 — Half-Life's own numbers).
That is a **deliberate divergence**: HL's suit grants no armour, it switches the
HEV suit on, which unlocks the HUD/flashlight/voice — none of which are gated
here, so a faithful port would be a pickup that visibly does nothing. The plan's
note that "no armour stat exists in this mod" was wrong; `.float armor` is in
`sv_customdefs.qc`.

**This section used to list seven weapons as "no such weapon exists in this mod, so
aliasing would be a lie" — `weapon_satchel`, `weapon_tripmine`, `weapon_snark`,
`weapon_hornetgun`, `weapon_m249`, `weapon_eagle`, `weapon_knife`. All seven have
resolved since the four-weapon port at PATCH 132 (documented at line 142 of this
same file, which is how the claim went stale). Do not trust a "still missing" list
without re-measuring.**

The Opposing Force set is now complete too, by two different routes:

- **Aliased to a good behavioural match, with the original world model** (PATCH 141)
  — `weapon_sniperrifle` → the AWP wearing `w_m40a1.mdl`, `weapon_pipewrench` → the
  wrench wearing `w_pipe_wrench.mdl`, `weapon_sporelauncher` → the grenade launcher
  wearing `w_spore_launcher.mdl`, `weapon_penguin` → snarks wearing
  `w_penguinnest.mdl`. Plus nine They Hunger guns the same way. **Stated
  limitation: only the world model is overridden — the view and hand models stay
  stock**, because those are chosen client-side from the WEP id, while the world
  model is networked as a string (`dropped_weapon_SendEntity`, `sv_player.qc:2059`)
  and so can be overridden per-entity.
- **Implemented for real** (PATCH 141) — `weapon_shockrifle`, `weapon_displacer`
  and `weapon_grapple`, because nothing in the mod behaved like them. Plus Sven's
  jetpack.

Sven's own `weapon_uzi` and `weapon_m16` still have no spawn function. Neither is
placed in any valve/gearbox/bshift map, so they cost nothing today; note that
They Hunger's `weapon_m16a1` is a *different* classname and does resolve.

**Still missing — no such system:** `item_longjump` spawns and fires its chain but
grants nothing (no longjump module in the movement code); the Opposing Force CTF
items (`item_ctfflag`, `item_ctfbase`, `item_ctfaccelerator`, …, 22+9×5) need CTF.

**`ammo_*` used to be listed here as un-aliasable, and that design question is now
answered.** Half-Life keeps global per-calibre pools, so `ammo_357` means "add
rounds to the .357 pool" whether or not you own the gun; this mod keeps ammo per
slot (`shared/sh_weapon_slotammo.qc`), so there was nothing for a pickup to add to
unless you already carried the weapon. `sv_goldsrc_ammo.qc` resolves that with a
**per-calibre reserve bank**: ammo for a gun you have not found yet is banked by
calibre and released when you find it. All 2481 ammo placements now resolve.

`ammo_9mmAR` alone was 294 of them — the #2 most-placed pickup in Half-Life, and
its own second name for `ammo_mp5clip`, which had worked all along. One line.

**Three defects were found in that reserve system while extending it, and the
third had never been caught by reading the code.** `Ammo_GiveToCarried` topped up
any pool that was below its cap without ever asking whether the player *carried*
that weapon — and a player carrying nothing has every pool at 0. So the give always
"succeeded", the pickup was consumed, and the bank underneath was never written.
**The headline feature of the file had never once executed.** A fourth gap followed
from the fix: banked rounds were stranded forever, because map weapons spawn full
and the drain only ran at pickup — the one moment it could never succeed. Both are
covered by `sv_ammo_selftest`, which goes 3 FAIL → BAD=0 across the fix.

## scripted_sequence is live — the maps have choreography now

**This is the big one and it is what puts barney in the chair.** 2019 of these
corpus-wide; `hl_c01_a1` alone has 95 and **zero** `path_corner`, so this class is
not part of that map's choreography system, it *is* the choreography system.

Verified headless on `hl_c01_a1`:

| | |
|---|---|
| scripts on the map | **95**, of which **7** claim an actor at map load |
| actors posed and holding | **7/7** — barneyatdesk, leaningbarney, airlockbarney, introroomleaner, coffee, and the arguing gman + scientist |
| scenes played to completion | 3 played → 3 done → 3 chains fired |
| soft-lock guards fired | lost=0 forced=0 broke=0 |

**What to look at in-game.** Spawn on `hl_c01_a1` and walk the intro:

1. **The security guard is sitting at the desk** in the first room. That is
   `barneyatdesk`, teleported onto his mark and holding `sit1` forever. If he is
   standing, possession failed — check `developer 1` for `[script] "" claimed
   monster_barney "barneyatdesk"`.
2. **The G-Man and a scientist are arguing** further in. The G-Man is a posed body
   with no AI at all (`mon_corpses.qc` builds him that way, correctly — gman.mdl
   has no attacks), so he is driven straight from the script entity. He should be
   in `idle01` and should play `listen` / `bigno` / `bigyes` when the scene fires.
3. **The intro walkers walk** when you cross their trigger.
4. `sv_ai_debug 1` prints `[ai]   script now: walking=N posed=N playing=N` every
   two seconds — the live census. `posed=7` on this map with nothing triggered.

**KNOWN LIMITATION — scripted transit, not scripted acting.** Two of three
scripted *walks* on `hl_c01_a1` stop short of their mark. Both causes were
measured, and neither is in the script layer:

- `gizmoscistart`: 155 units short, blocker = **worldspawn**. The mark is round a
  corner and the nav graph cannot route there — that map's 98 `info_node`s build
  into **8 disconnected components**, the largest holding 39 of them.
- `introwalkerguy1mm`: 521 units short, blocker = **another `monster_scientist`**
  standing in the route. Monsters do not currently push past or route around each
  other.

Both give up *safely*: the actor stops, the scene plays from where it got to, and
the target chain still fires, so nothing can soft-lock. Improving either means
improving locomotion (nav connectivity / monster-vs-monster avoidance), which is
its own piece of work. Watch for actors that stop in corridors — that is this, not
a broken script.

**Also worth confirming by eye:** `m_iszPlay` names that the installed models do
not carry. `hl_c01_a1`'s `enterbarney2`/`enterbarney3` ask for `sit2` and `sit3`,
and **neither Valve's barney.mdl nor Sven's replacement has them** — only `sit1`.
Those scripts complete and fire their chains rather than freezing him, and the
`noseq` counter records it.

## Talkers — mouth, refusals, and gunfire  *(all three were reported broken in-game)*

- **The jaw window was wrong, not the wiring.** The mouth envelope used the same
  0.85 s as the word spacing. Measured over the 1448 words `sentences.txt`
  actually references that resolve in the mount: **median 0.89 s, mean 2.02 s, p90
  4.17 s**. Spacing wants the median, total speaking time wants the mean — using
  the median for both shut the jaw after 0.85 s of a line still going four seconds
  later, which reads as no jaw movement at all. Now 2.0 s/word for the mouth.
  *Needs the Patch 125 client to be visible at all — if you are running
  `fteqw64.prepatch125.exe`, no bone controller reaches the client and the head
  will not turn either.*
- **"I'm busy" is now spoken.** Pre-disaster talkers play HL's own `SC_POK` /
  `BA_POK` group (`barney/ba_post`, `ba_duty`, `ba_raincheck`, `ba_later`) instead
  of only printing a line. Accepting a follow plays `SC_OK`/`BA_OK`, telling one to
  wait plays `SC_WAIT`/`BA_WAIT`. The console text stays as the fallback for
  classes with no sentence group.
- **They react to gunfire now.** `COND_HEAR_SOUND` had exactly one producer —
  taking damage — so a player could empty a magazine in a room of scientists and
  nothing looked up. `AI_HeardGunfire` is called from `SH_StandardTryFire`, the one
  authoritative fire point for every standard weapon; talkers within 1280 units
  turn, look and play `SC_SCARED`/`BA_SCARED`. **They deliberately do not flee** —
  HL scientists take cover from danger sounds, but an escort that bolts every time
  you fire is unusable in co-op.

## Cockroaches  *(reported: stacked, moving in lockstep, camera sinks)*

- **The pile is the map, not a bug.** `th_ep1_01` has six `monstermaker`s asking
  for `monster_cockroach` with `m_imaxlivechildren` up to **7** and
  `monstercount -1`, all spawning on the maker's own origin. The count is correct.
- **They now scatter and desync**: a traced random offset at spawn (skipped if it
  would push one through a wall) plus per-roach speed jitter around 90.
- **You can squash them, and that fixes the camera too.** HL's `CRoach::Touch`
  kills a roach on contact with any *moving* player. A roach is a solid 2×2×1 box,
  so standing on one puts the player a unit up while CSQC prediction — which does
  not have it — predicts the floor; that disagreement *is* the sinking view. In HL
  it cannot happen because the roach dies before it can support you. Same three
  lines fix both symptoms. `roach/rch_smash.wav` plays (the old comment here
  claiming roach.mdl has no sounds was wrong — HL precaches three and all three
  are in the mount).
- **Still missing vs HL's CRoach:** light sensitivity (roaches flee lit areas),
  food-seeking and eating, and idle wander to random spots. The wander is the one
  you would notice — HL roaches scurry constantly rather than holding position.

## ENGINE PATCH 125 — bone controllers are now networked  *(needs the new binaries)*

**This is the one item that changes the engine, so read it first.** `fteqw64.exe` and
`fteqwsv64.exe` in `C:\FTEQuake` are new builds; the previous ones are kept beside them as
`fteqw64.prepatch125.exe` / `fteqwsv64.prepatch125.exe`. If anything below misbehaves, swap
those back and everything returns to the pre-patch behaviour.

`.bonecontrol1..5` existed in progdefs and `framestate_t.bonecontrols` was already read by the
HL model renderer, but nothing ever carried them across the wire — so a server-side HL model
could not aim. `PEXT2_BONECONTROLS` (0x800) now sends five shorts inside the existing
`UF_BONEDATA` payload, under a spare flag bit.

- [ ] **A pre-patch client must still connect to a patched server, and vice versa.** This is
      the compatibility claim and the only thing I cannot verify without a real client. It is
      airtight *by construction* — the 0x20 flag bit is only ever set when the extension is in
      `client->fteprotocolextensions2`, which an old client never advertises, and both baseline
      emitters pass that same per-client set (verified by reading, `sv_user.c:1724` and `:1862`)
      — but "airtight by construction" is not the same as "seen working".
- [ ] **Existing demos must still replay.** Same mechanism, same reasoning, same caveat.
- [ ] **Turret aim.** `monster_sentry` / `miniturret` / `turret`: the base should still swivel
      as before, and the **gun should now lead it** and **elevate**, which the chassis could
      never do. Verified headlessly only that they still deploy, scan, fire and hit
      (4 attacks, `shots=2 hits=2`).
- [ ] **Barnacle tongue is now drawn.** It should hang ~64 units at rest and stretch to the
      victim when something walks under it. The length comes from the same trace that applies
      the damage, so the drawn tip should be exactly where the biting happens.
- [ ] **Grunt / barney aim tracking.** Their spine should turn toward you between bursts, up to
      the model's own limit (±70° hgrunt, ±60° barney) and no further, with the body catching up
      after. If a grunt tracks *past* those limits something is wrong with the units.

**The units are not uniform, and this is the trap.** `HL_CalcBoneAdj` (gl_hlmdl.c:988) branches
on the controller's `type`: `& 0x8000` (wrapping rotation) is consumed **raw as radians and
unclamped**; `[0x0008,0x0020]` is **degrees, clamped** to the model's own range; anything else
is **raw units**. That is why the turret's yaw is passed in radians and its pitch in degrees, in
the same function. Measured ranges are documented in `sv_ai_combat.qc`.

---

## Grenades are live  *(the byte→short widening landed)*

`GREN_TOSS` / `LAUNCH` / `DROP` are no longer no-ops. The HL grenade's owner field is now a
**short** on the wire in both directions, which is what was blocking this: a monster edict past
255 aliased onto whatever player sat at `(n & 255)` and that player silently lost the explosion FX.

Measured: **10 range_attack2 selections → 9 throws → 9 explosions**, owner correctly attributed
as `monster_human_grunt`, peak 100 at radius 250. All four safety vetoes observed firing
(9 "no clear arc", 6 "enemy too close", 3 "friendly inside the blast", 1 "enemy airborne").

- [ ] **Watch a grunt actually throw one.** The arc is HL's own `VecCheckToss`, so it should lob
      over cover rather than through it.
- [ ] **They should not frag each other or you.** The 256-unit minimum and the faction proximity
      check are what prevent it; `sv_ai_debug 1` names the veto whenever a throw is refused.
- [ ] **hgrunt.mdl has TWO sequences tagged act 29** — `throwgrenade` (code 7) and
      `launchgrenade` (code 8) — and `frameforaction` picks between them at random. Both codes
      now release whatever the grunt is *carrying* rather than what the animation rolled, so a
      hand-grenade grunt should never fire a contact round. Worth confirming by eye.
- [ ] Grenade count is `sv_ai_grunt_grenades` (default 3). HL's grunts have unlimited; 3 is a
      multiplayer-sanity choice, not a port of anything.

---

## Allies follow on +use

The `monster_player_usable` gate added back in B2 finally does something. **+use an ally** and it
escorts you; +use again and it waits. `cmd ai_follow` (aim at an ally, `sv_cheats 1`) runs the
exact same path, for when you want to know whether the behaviour is broken or the press just
landed on a wall.

Three failures were found and fixed getting here, all measured:

| | before | after |
|---|---|---|
| follow selections | 20 | 354 |
| follow **failures** | 19 | **0** |

1. The follower walked to the leader's **exact origin** (`AI_GOAL_REACH` is 40) while its stop
   band is 128 — so it shoved into the player, tripped the stuck counter and reported BLOCKED.
   It could not succeed even once, by construction.
2. It **waited on the nav queue**. Eight allies requesting in one tick meant most were refused,
   each waited out a 2 s deadline, failed with `COND_NO_PATH`, and the failure backoff pushed the
   next request out past its own retry — permanent starvation. HL's allies do not graph-search to
   the player at all; `CTalkMonster` walks straight at them. It now asks the queue as a courtesy
   and gets on with walking.
3. All followers aimed at the **same point** and jammed into each other. They now spread around a
   ring, at an angle derived from the edict number so it is stable.

- [ ] **An escorted ally still fights.** Verified: 4 range attacks, 3 hits on headcrabs, 6 crab
      kills *while following*. Worth seeing.
- [ ] **KNOWN, and HL-accurate: an ally will shoot you if you stand in its line of fire.**
      Measured once in 80 s with eight allies ringed around one player (10 damage, pass-through
      while it was shooting a headcrab). Its enemy was never the player — the faction matrix
      prevents that — the bullet simply went through. Newly *more likely* because followers now
      stand close. Say the word and the ring widens or ally bullets pass through allies.
- [ ] The escort drops if you die or get more than 1024 units away.

---

## Bigmomma lays headcrabs  *(was OPEN)*

Her spawn sequence is tagged `ACT_MELEE_ATTACK2` and **nothing in the generic ladder ever selects
that activity** — the event was wired, event-correct, and unreachable. It now has its own
schedule and a class selector.

Measured: **13 selections → 13 births**, and the live-child count rises *and falls*
(1,1,1,2,2,1…3), which is the slot-release path working — so a gonarch whose brood is killed can
birth a fresh one.

- [ ] Watch her actually birth one. `sv_ai_bigmomma_crabgap` (8 s) and
      `sv_ai_bigmomma_maxcrabs` (10) tune it; drop the gap to 2 to see it quickly.
- [ ] She refuses to birth into solid, so a gonarch backed against a wall should skip rather than
      drop a crab inside the geometry.

---


## THE TEST BENCH  —  **F4**

A drawn CSQC panel, same family as F1 (cvars), F2 (server browser) and F3 (car
tuning): draggable, cursor takeover, game keeps ticking underneath. It reuses the
F1 panel's visual constants and its button helper, so the two cannot drift apart.

**Spawn tab** — all 37 AI classes as buttons in four labelled groups (humans and
allies / aliens / static-aquatic-airborne / heavy). Each spawns **where you are
looking**, so aim at a bit of floor and click. Labels carry the warnings that
matter: `^2ALLY` on the ones that must not shoot you, `FLEES` on scientist and
roach, `UP` on the barnacle (aim at a **ceiling**), `WATER` on the swimmers.

**Bottom bar** — spawn count -/+ (1..16), `freeze` (pause every monster
mid-animation and walk around it), `hurt` (damage what you are aiming at, to test
flinch and death without shooting), `clear all`.

**Status tab** — `ai_status` and `ai_list` to console, plus a live count of
monster entities this client can actually see. That count is the fastest way to
notice "the server says it spawned eight and I can see none", which is exactly
the failure the W3 grunts had.

`ai_status` is the important readout: every bug in this programme showed up as
the **wrong schedule**, not a wrong task, and that is the column it prints — hp,
state, schedule name, condition bits, current enemy, distance.

Everything is `sv_cheats`-gated except the two read-only commands. The same
commands work from the console (`cmd ai_spawn <class> [n]`) and there is an
optional `cfg/aidebug.cfg` of keybinds if you ever want them without the panel.

## VERIFIED — allies actually fight (3 bugs found and fixed)

`sv_ai_spawnclass2` was added so two different classes can be spawned side by
side; without it the faction matrix could not be tested at all. Barney + headcrab
on th_ep1_01, with a player present:

| | before | after |
|---|---|---|
| barney -> headcrab hits | 1 | **6** |
| headcrab -> barney hits | 12 | 4 |
| headcrab deaths | 0 | **6** |
| barney -> player hits | 0 | **0** |
| schedule selections, all classes | 1793 | **763** |

Three real bugs, all in shipped code:

1. **Barney had a melee range but no melee animation.** `barney.mdl` has no
   `act 30` at all, so `SCHED_MELEE_ATTACK1` fell through the activity fallback to
   sequence 0 and he stood playing an IDLE pose while "attacking". The hgrunt
   keeps its melee because it genuinely has a frontkick.
2. **The close-range veto left him with nothing.** `Grunt_CheckAttack` refuses the
   gun inside 70 units because grunts kick instead — with melee removed that left
   Barney unable to do anything at all at contact range. It now only vetoes when a
   melee alternative exists.
3. **`COND_PROVOKED` is never cleared** and was in `alert_stand`'s interrupt mask,
   so that schedule was interrupted on its first tick forever — 707 selections in
   50 s. It is HL's persistent *memory* flag, not an event. Removed from that mask;
   still in `idle_stand`'s, where waking a dormant monster is the point.

- [ ] Confirm in game: an ally should shoot monsters, never you, and should not
      visibly stutter between poses.

## W7 — bosses, part one (bigmomma, apache, osprey)

Bigmomma verified: 25 `melee_attack1`, hits landing.

- [ ] **Bigmomma is 1000 hp, 50 melee, 120-unit reach.** Check she is a fight and
      not a wall.
- [ ] Her **mortar** is a 200-unit blast centred on YOU, not a lobbed projectile.
      HL lobs a real shell; this is the same threat without a new projectile type,
      but it cannot be dodged by out-running the arc. Change if it feels unfair.
- [ ] **`monster_apache`** hovers at 320 units and fires 3-round bursts.
      **`monster_osprey`** is deliberately UNARMED — in HL it is a troop transport
      that drops grunts, and the dropping belongs with scripted_sequence (W8).
      Both are one-sequence models, so they have no death animation: they will
      simply stop. Known.

## OPEN — bigmomma never lays headcrabs

The `LAY_CRAB` handler is written and wired to the right event (code 12), and it
spawns a real `monster_headcrab` through `Monster_Build` so the child gets a brain
and a hull like any other. But the sequence carrying that event is tagged
**act 31 (ACT_MELEE_ATTACK2)**, and no schedule in the table ever selects that
activity — so the event never fires. Her signature behaviour is therefore absent.
Needs a class `ai_selectsched` that periodically picks a lay-crab schedule.
Written up rather than left as a silent gap.

## OPEN — stukabat lands no damage

`monster_stukabat` selects `range_attack1` 12 times in 45 s and connects zero
times. Three causes ruled out: the attack IS correctly tagged `act 28` (its model
has no `act 30` at all), the sweep reach now matches the range that gates it, and
volume-mode melee now aims in 3D rather than along the yaw plane. Still zero.
Most likely it never actually closes to within its 80-unit reach because a flyer
follows waypoints lifted to its cruise height. Everything else works — it flies,
chases and plays the attack. Low priority (60 placements), flagged not hidden.

## W5/W6 tail — heavy melee (189 placements)

Gargantua verified: 3 `melee_attack1`, 3 hitclaims.

- [ ] **Gargantua stomp lands at 1.36 s of a 1.5 s animation** — the wind-up is
      the tell, same as the houndeye. 800 hp, 50 dmg slash, 50 dmg stomp in a
      400-unit radius. Check it is survivable.
- [ ] `monster_babygarg` is the same rig at half damage and 0.5 scale reach.
- [ ] Neither gargantua bleeds (HL behaviour).
- [ ] **`monster_kingpin`'s model has only 3 sequences** — idle, walk, run, no
      attack animation at all. It deals damage from the per-tick hook, so it
      walks into you and hurts without an animated swing. Known, not a bug.


## W6 — turrets (453 placements, 3 classnames)

The first classes to use AIMODE_STATIC and named sequences. Verified headless:
13 shots / 13 hits / 104 dmg, `arrived=0` and `volstep=0` (no static monster ever
entered the movement path), 18 schedules built, `BAD=0`.

- [ ] **Rate of fire comes from the model.** The looping `fire` sequence carries
      one `EVENT_MUZZLEFLASH` per round — 3 on sentry, 7 on miniturret, 3 on
      turret at 150 fps — so each keeps its own authored cadence. Check they
      sound distinct from each other and that the flash matches the shot.
- [ ] **Deploy / retire.** `monster_miniturret` and `monster_turret` start
      retracted, pop up on sighting, and fold away after 5 s with no target.
      `monster_sentry` starts deployed and never retires (it is the free-standing
      one). Check the pop-up animation plays fully and isn't re-triggered.
- [ ] **Ceiling mounts must not fall.** STATIC skips `droptofloor` entirely —
      that is the whole reason the mode exists. Find a ceiling turret and confirm
      it stays on the ceiling.
- [ ] Turrets swivel their base to aim (`ai_yaw_speed 120`). HL aims with bone
      controllers instead, which is W1a; until then the whole model rotates.
      Check that reads acceptably.
- [ ] They do not bleed (`bloodcolor -1`) and take **metal** impacts, not flesh.

## W4 — factions and allies (FIXES A SHIPPED BUG)

`monster_barney` (319), `monster_otis` (81), `monster_human_grunt_ally` (406) and
`monster_human_medic_ally` (52) were **shooting players** from W3 until now — they
were tagged `CLASS_PLAYER_ALLY` but nothing read the tag. Verified headless that
allies no longer damage players and that hostiles still do (grunt 13 hitclaims on
the bot).

- [ ] **Allies must not shoot you.** Barney/otis/ally-grunts/medics.
- [ ] **Allies SHOULD shoot monsters.** This is the part the harness could not
      construct — it spawns one class at a time, so allies and hostiles were never
      co-located. Put a barney near a headcrab and confirm it engages.
- [ ] **`monster_scientist` (271) must never fight.** Both attack ranges are 0 and
      the matrix returns R_FEAR, so it should run (`SCHED_FLEE_ENEMY`, the schedule
      built for the cockroach in W2). Check it flees rather than standing still.
- [ ] **Aliens must ignore each other.** A zombie should not attack a headcrab.
      HL's real table is R_NO across the whole alien block; my first draft had
      predators hunting prey, which would have had maps killing themselves off
      before the player arrived.
- [ ] Turrets/robogrunts (`CLASS_MACHINE`) shoot players and aliens but not
      human military.
- [ ] The map `classify` key overrides the class default — 2969 entities in the
      corpus carry one and none were read before now. Worth spot-checking a map
      that uses it.
- [ ] Scientists are now `monster_player_usable`; +use does nothing yet (follow
      behaviour is still to come) but the gate is live.

## W6c — barnacle (183 placements)

Verified headless: 8/8 hung from the ceiling by the test harness, tongue landed
damage, `barnacle_chomp` fires on contact.

- [ ] **The tongue is not drawn and the victim is not lifted.** Both need the
      bone-controller engine patch (W1a) — that controller is what sets tongue
      length. What works today is the gameplay: standing under one hurts
      continuously and it visibly chews. This is the most visibly incomplete
      class in the programme; it is not a bug report.
- [ ] Barnacles must stay on the **ceiling**. AIMODE_STATIC skips `droptofloor`
      specifically for this class.
- [ ] Damage is 10 every 0.5 s (`sv_ai_barnacle_dmg`). Check that is a hazard
      rather than an instant death.
- [ ] A barnacle over a catwalk must not reach through it — the tongue trace is
      `MOVE_NORMAL` so world geometry blocks it.

## W6b — swimmers and the flyer (398 placements)

First classes written AGAINST the locomotion modes rather than forced into them
with `sv_ai_forcemode`. Verified headless: controller held clearance
`max=64 mean=52.9` against a configured `ai_flyheight` of 64, constant across the
whole run; leech refused 89 volume steps that would have beached it.

- [ ] **`monster_alien_controller`** hovers at 64 units and never closes — it has
      no melee range at all. Check it looks like it is floating, not standing.
      Its energy ball reuses the **egon beam**; change if it reads wrong.
- [ ] **`monster_leech`** has NO walk or run — both gait cycles are tagged
      `ACT_SWIM`. The activity fallback now routes WALK → SWIM → IDLE; before that
      it glided everywhere in its hover pose. Check it swims rather than glides.
- [ ] **`monster_ichthyosaur`** bites for 35 (HL's figure) with a 90-unit reach.
      That is a lot — check it is not unfair in a confined pool.
- [ ] Swimmers placed **out of water** log a warning once and then cannot move at
      all, by design. If a map's leeches sit motionless, check the log for
      "swimmer placed out of water" before assuming the AI is broken.

## W5 — alien melee/ranged (816 placements, 5 classnames)

First monsters with real projectiles. Verified headless: agrunt 9 class events /
9 hitclaims, bullsquid 8 `range_attack1` / 15 class events / 7 hitclaims.

- [ ] **The alien grunt fires FIVE hornets per attack** (codes 1-5), and its
      `longshoot` sequence fires seven. The volley is the attack. Check it reads
      as a volley and isn't overwhelming — `sv_ai_agrunt_dmg` (default 8) tunes it.
- [ ] **Bullsquid spit arcs** (gravity 0.5), **pitdrone spikes fly flat**
      (gravity 0). Check both look right and that neither tunnels through a
      player at close range (they use `MOVETYPE_FLYMISSILE` for that reason).
- [ ] Projectiles are plain server entities, not the CSQC `PROJ_TYPE_*` system —
      so they are **not** client-predicted. At high ping they may look slightly
      behind. That is expected, not a bug.
- [ ] `monster_alien_voltigore`'s ranged attack reuses the **egon beam** rather
      than a projectile. If it reads wrong, that's the thing to change.
- [ ] `monster_gonome` falls back to the **zombie** model if Opposing Force
      content is ever unmounted; `pitdrone` falls back to **bullsquid**.

## W3 — the gun shooters (~2600 placements, 13 classnames)

Verified headless: grunt 15 shots / 13 hits / 104 dmg, barney 10 shots / 10 hits.

- [ ] **Three-round burst.** A grunt fires 3 rounds per attack, 0.1 s apart, from
      anim events on a LOOPING sequence. 15 shots from 5 attacks confirms the
      mechanism; check it *sounds* and *looks* like a burst, not a stutter.
- [ ] Grunts kick instead of shooting inside 70 units — check the transition.
- [ ] **Model resolution.** `steam:Half-Life/gearbox` is now mounted, so every AI
      class resolves to a real file — run `sv_ai_selftest 1` and read the
      `[ai-selftest] model ...` inventory, which prints what each class got and
      which mounted game it came from. Current result, zero MISSING:
      valve → headcrab, zombie, roach, islave, houndeye, hgrunt, hassassin, barney;
      gearbox → massn (419), otis, strooper, hgrunt_opfor/medic/torch;
      svencoop → hwgrunt.
      Only `monster_robogrunt` and `monster_bodyguard` fall back (to hgrunt and
      barney) — no mounted game ships those two.
- [ ] **Blue Shift is not installed** (no `bshift` dir, no Steam manifest). The
      `fs_addons.txt` line is present but commented; uncomment after installing.
- [x] ~~**Grenades are deliberately inert.**~~ **DONE** — the owner field is now a short and
      all three events release a real grenade. See the grenades section above.

## W1d / W5-first — new monsters (spawn-tested headless, never seen)

`sv_ai_spawnclass <class>` + `sv_ai_spawntest 8`.

- [ ] **`monster_alien_slave`** (726 placements, #2 class in the corpus). Verified
      headless: 10 `range_attack1`, 58 class anim events, 10 hitclaims landing.
      The beam fires **1.6 s into** the animation, after four charge-up events —
      check the zap looks synced to the arms coming up, not early.
      Uses `HL_BEAM_EGON` for the visual; swap to `HL_BEAM_GAUSS` if the colour
      reads wrong.
- [ ] A single islave claw swing carries **three** damage events (0.32/0.59/0.95 s),
      which is HL-correct but means melee hurts ~3x its per-hit number. Check it
      isn't brutal.
- [ ] **`monster_houndeye`** (231). Blast lands **2.36 s into** a 2.4 s animation —
      the long tell is the whole point, backing off should save you.
- [ ] Houndeye blast no longer damages other houndeyes (same-classname exclusion).
      Confirm a pack doesn't wipe itself; deaths went 5 → 0 headless.
- [ ] Monsters now take **flesh** impact effects instead of concrete dust
      (`W_ClassifyImpactMaterial` ignored `FL_MONSTER` entirely before). Shoot a
      headcrab and check for blood, not stone chips.

## W1b — wire-format widths (HIGH: desync would be obvious but severe)

Three fields changed byte → short. Server and client ship together and each field
has exactly one writer and one reader (verified statically), but the path was
never exercised.

A reader one byte short desynchronises **every event after it in the same
packet**, so a mistake here is loud, not subtle — impacts and tracers would go
visibly haywire rather than being slightly off.

- [ ] Fire a gun near another player. Tracer must start at **their muzzle**, not
      fly in from an arbitrary point.
- [ ] Fire the **gauss** and the **egon**. Onlookers must see the beam.
- [ ] Take a hit. Flinch animation must play.
- [ ] Shoot a `func_breakable`. Bullet holes must attach and vanish with it.

## W1e — animation events

- [ ] **Zombie footsteps.** Their walk cycle carries six `EVENT_SOUND` events
      naming `common/npc_step1..4.wav`. These have never played — the events were
      mis-documented as vestigial. Precache is confirmed (8 sounds found in
      `zombie.mdl`); audibility is not.
- [ ] **Body-drop thud** when a zombie dies (`EVENT_BODYDROP_LIGHT` at 0.650 s of
      `diesimple`).

## W1c — locomotion modes

Counters prove QC is the only thing moving these and that clearance holds at the
configured height, but nothing proves they *look* right.

- [ ] `sv_ai_forcemode 1` + `sv_ai_spawntest 8` — flying headcrabs should hover
      and track, not skate along the floor or bob.
- [ ] `sv_ai_forcemode 3` — static headcrabs should sit still and rotate to face,
      never try to close distance.
- [ ] A dead flyer should **fall** and land (`FL_FLY` is cleared on death).

## B2/B3 — still owed from earlier waves

- [ ] Headcrab **leap feel** — the ballistic solve is HL's, but the arc has never
      been watched.
- [ ] Walk/run speeds are **hand-set**. HL derives them from
      `seq->linearmovement`, which no QC builtin exposes, so a monster that skates
      or moon-walks means the number needs tuning, not that the code is wrong.
      Current: headcrab 60/150, zombie 40/40, zombie_soldier 35/35, roach 90/90.

---

## Notes / assumptions to confirm

- Sven Co-op's *They Hunger* monster set is assumed to work from the mounted
  Steam HL install. Models resolve from `steam:Half-Life/valve` — see the
  `hl-models-come-from-steam-mount` memory note. `th_*` classnames that are pure
  reskins are handled as variants of the base class.
- `monster_male_assassin` was pointing at `models/male_assassin.mdl`, which does
  not exist; corrected to `models/massn.mdl` (419 placements).
- Three `-> "?"` lines (an unbuilt schedule id) appear at map load on dead
  entities during the squad self-test. Predates this programme, confined to the
  `sv_ai_selftest` path, no gameplay effect. Cosmetic.

---

# PATCH 129 — the playtest defects (round 4)

Fourteen reports from a session at the keyboard, which collapsed into six systemic
faults. Three of them were caused by Patch 128's own corpse change.

## What was measured, not assumed

`sv_ai_animtest` (new, runs under `sv_ai_selftest 1`) prints, per registered class,
how many of Half-Life's 77 activities resolve to a real sequence and **every distinct
low event code the model raises**. It found a third broken shooter nobody had reported.

`sv_ai_firetest` (new) spawns the reported-broken shooters around the first live
player with line of sight, keeps the target alive, and prints the damage each one
lands. On `2fort`:

| class | before | after |
|---|---|---|
| `monster_male_assassin` | 0 (structurally) | **400** |
| `monster_shocktrooper`  | 0 (structurally) | **232** |
| `monster_hwgrunt`       | 0 (structurally) | **116** |
| `monster_alien_slave`   | worked, silent   | **30**, with sounds |
| `monster_houndeye`      | 0                | **still 0 — see owed test C** |

`sv_ai_corpsetest`: `deadflag=2 solid=5 takedamage=1 size_z=1` (5 = `SOLID_CORPSE`),
`10 bullets: hits=10 gibs=0`, `club swings to gib: 42 (chips=41 gibs=1)`.

Five-map regression clean, both self-tests `BAD=0`, errors 0, crashaddr 1824 → 1824.

## OWED IN-GAME TESTS

**A — corpses.** They are `SOLID_CORPSE` now: walk over a pile and confirm you pass
straight through with no snag and **no view sink with `cl_driftlock 1`**, and that a
crowbar still breaks a body apart. That last part is the risk — the melee/hitscan
opt-in in `W_WeaponTraceLine` and `W_ServerTraceLineWithPhysDrops` is the only thing
keeping corpses hittable at all. If bodies become unshootable, that pair is why.

**B — bullet holes from NPCs.** Stand where a grunt is shooting at a wall. Before,
exactly one hole appeared per monster per life. There should now be one per shot.

**C — the houndeye.** `sv_ai_firetest` still reports `dmg=0`, but with
`sched=chase_enemy` — it was walking, not attacking, so the blast is **unconfirmed**
rather than known-broken. The `takedamage` filter that provably excluded players is
gone from `AI_BlastAttack`. Spawn one with `cmd ai_spawn monster_houndeye`, stand at
~200 units and let it wind up. It should hurt, and hurt less the further out you are
(falloff now reaches zero at the rim, as HL does). It still has **no visible shockwave** —
that sprite is not implemented.

**D — dropped weapons.** `sv_ai_dropweapons` defaults on. Barneys drop a glock, grunts
an MP5 or shotgun. **Known cosmetic gap:** the corpse keeps a painted-on gun as well,
because selecting a bodygroup on a server entity needs the engine change that is next.

**E — firing cadence.** Barney/grunts fire ~2.4x faster (the flat 1.2 s cooldown that
sat on top of the animation is gone). `sv_ai_range_cadence 0` = exactly Half-Life;
1 (default) makes distant shooters slower and slightly irregular.

**F — the roach.** `Cockroach_Touch` had never been called in the mod's life: player
touch is dispatched by hand in `SV_CheckTouchTriggers` and only knew triggers and
buttons. Walk over one; it should squash.

**G — OpFor voices.** Shocktroopers and gonomes were entirely mute (all their sounds
sit on event 1011, which nothing handled and nothing precached). They should now speak,
step and die audibly.

---

## PATCH 130 — houndeye voice + visible blast, lipsync, the OpFor sidearm

Four playtest reports, and a fifth never-firing NPC that the sweep found on its own.

### Measured

| | before | after |
|---|---|---|
| `monster_human_medic_ally` damage landed | **0** (never fired in its life) | 160 |
| `monster_human_torch_ally` damage landed | 0 | 168 |
| `monster_houndeye` damage landed | **0** (unconfirmed since patch 129) | **28.4 — confirmed** |
| `hl_c01_a1` scripted_sentence speakers resolved by name | 0 / 24 | **24 / 24** |
| houndeye voices used | 5 of 6 | 6 of 6 (`he_hunt` was dead) |

Five-map regression clean, `crashaddr` 1824 → 1824, all three VMs 0 warnings.

### What was wrong

**The squeak is `he_hunt`, and nothing had ever played it.** It is not on an event and
not on a schedule: `houndeye.cpp:846-852` rolls 20% per think while the hound is in
COMBAT and running. `HOUND_AE_WARN` (code 1) plays it too, and we had that code filed
under "movement beats" as a deliberate no-op. Both are wired now, plus the blink
(`pev->skin` against the three eye skins in `houndeyeT.mdl` — no monster in this mod
had ever set `.skin`).

**The blast was invisible because the engine has no `TE_BEAMCYLINDER`.** `SonicAttack`
writes two of them and nothing else; the wind-up writes a `TE_IMPLOSION` every frame.
Neither temp entity exists in FTE. `shared/sh_shockwave.qc` + `CSQC_EVENT_SHOCKWAVE`
draw both as ribbon rings through the same `spriteframe()` / `_beam` shader route
`cl_env_beam.qc` uses for its RING mode, from HL's own `sprites/shockwave.spr`.

**39% of the game's scripted dialogue came out of the wrong mouth.** `scripted_sentence`
names its speaker with a key spelled `entity`, which cannot be a QC field name — the old
note here concluded it was unreachable and fell back to a nearest-monster radius search.
It is reachable: the engine calls `ED_ParseUnknownEpair` (`pr_cmds.c:487-506`) and this
mod has implemented it since the multi_manager work. Measured over the corpus: 758
scripted_sentences, **all** carrying the key; the radius guess found nothing for 98 (the
line then played from an invisible point entity, which is why no jaw moved — the mouth is
driven by the voice channel's amplitude on the *speaking entity*) and picked the wrong
monster for 196 more. `hl_c01_a1` alone was 20 wrong out of 24.

**The torch ally's gun sound was an MP5 because the animation is called `crouching_mp5`.**
The sequence name is inherited from the shared rig and lies. The bodyparts lump does not:
`hgrunt_torch.mdl`'s weapons group is `Desert_Eagle / engineer_torch / gunholster`, and
`hgrunt_medic.mdl`'s is `Desert_Eagle / glock / hypodermic / gunholster`. Both now use
`weapons/desert_eagle_fire.wav`, a handgun's 2 degree cone instead of the grunt's 5, a
pistol drop, and no grenade loadout they have no sequence for.

**The medic ally had never fired a shot.** `monster_human_medic_ally` runs
`Barney_ClassInit`, whose handler shoots on code 3; `hgrunt_medic.mdl` fires on code 4.
Same shape as the male assassin and the shocktrooper, found by diffing the codes each
model raises (`sv_ai_animtest`) against the codes its handler consumes.

### Engine

`r_hlmdl_seqblend` now defaults **on**. The cross-sequence bone blend landed in Patch 126
defaulted off because it could not be verified without eyes on it; it has now been played
and asked for. It also got its own clock — it used to borrow `lerpweight[0]`, which is
"how long the *previous* sequence happened to run for", so a monster idling ten seconds
faded over 0.3 s while one whose schedule churned faded over 0.03 s and still snapped.
`r_hlmdl_seqblend_time` (default 0.12) is now the whole answer.

### Owed in-game tests

**A — the houndeye.** `cmd ai_spawn monster_houndeye`. It should chatter while running at
you, rear up with rings converging inward, then throw two expanding rings on the thump.

**B — lipsync.** Any Half-Life chapter map. Scripted lines should come out of the NPC that
is actually talking, and that NPC's jaw should move.

**C — animation smoothing.** Watch any NPC change from idle to walk to attack. Toggle
`r_hlmdl_seqblend 0/1` to compare; tune with `r_hlmdl_seqblend_time`.

**D — the torch/medic allies.** They should fire a Desert Eagle, one loud round at a time.

### Found, not fixed

A **headless client crashes on 2fort with HL studio monsters spawned on it** (Quake BSP29
plus studiomodels). `hl_c01_a1` with the same seven models is clean, and it reproduces
with `r_hlmdl_seqblend 0`, so it is neither this patch's QC nor its engine change — a
pre-existing engine bug that only this test-harness combination reaches.

*Diagnosed and fixed in Patch 131 — it was the BC7 texture decoder, not the monsters.*

---

## PATCH 131 — the BC7 crash, the corner fix, and the gun in the hand

### The crash was a texture decoder, not a monster and not a missing mount

Symbolised from `crashaddr.txt` against the unstripped `fteqw64.exe.db` the Makefile keeps
beside the shipped binary: the fault was in **`Image_Decode_BC7_Block`**, on the texture
worker thread, nothing to do with the monsters that appeared to trigger it. They only
correlated because spawning them pulled new textures through the hi-res replacement path.

Four bugs in that one function, all long-standing:

1. **A write sixteen pixels behind the block.** The RGB pass walks `out` forward by
   `4*(w-4)` across the four rows; the alpha pass and the channel-rotation pass each
   rewound by `w*4` before running again. For the first block of an image that writes
   behind the heap allocation, and for a partial block (where the caller hands the decoder
   a 16×16 stack scratch) it writes behind a stack array. The damage lands in memory freed
   later, which is why the visible fault was inside `BZ_Free`. Both passes are reached only
   by BC7 modes 4 and 5, which is why the two `FIXME: untested` notes above them survived
   so long. Fixed structurally: the decoder now fills a local 4×4 and blits once, so no
   pass does pointer arithmetic at all.
2. **`etc_expandv` ran outside the subset loop**, on `palette[i]` with `i == numsubsets` —
   `palette[3]` on a 3-subset block, an out-of-bounds read-modify-write into `tab`. It also
   meant the endpoints were never expanded, so **every BC7 texture in the game has been
   decoding darker than it was authored**.
3. A copy-paste that read `palette[i][0]` where it meant `[1]`, making the second
   endpoint's alpha a duplicate of the first's.
4. **Mode 8 (reserved) was unhandled** — reachable from any block whose first byte is zero.

What made it start biting is content: **6095 BC7 textures in the material packs, 145 of them
not a multiple of 4 in one axis**, which is what drives the partial-block paths.

Verified: the headless client on 2fort died within ~10 s before, and now survives a full
five minutes plus a clean 40 s run, `crashaddr` unmoved.

### Corners

`AI_StepToward` tried `yaw+40` then `yaw-40` with no memory. Forty degrees does not clear an
inside corner — the monster's own bounding box still overlaps the wall — so both usually
failed and it stalled. When one did succeed nothing recorded which, so the next tick was
free to pick the other: right, left, right, forever, with `walkmove` reporting success every
time, which also meant **the stuck detector never fired and it never re-pathed**.

Three changes, all things HL already does: the fan **widens** (45 / 90 / 135 — 90 is the
pure slide that actually clears a corner), the side is **latched** until the direct line
reopens, and a successful sidestep is followed by an immediate retry of the original heading
— the **corner cut**, which rounds a doorframe in one tick instead of scraping the wall.

Two bookkeeping bugs fixed alongside: the blocked branch never re-seated `ai_lastorg`, so
the first step that did succeed compared against a stale point and reset the stuck counter;
and the `>60°` turn gate returned MOVING without touching any counter, so a monster whose
wanted heading kept flipping span on the spot indefinitely. A blocked route is now also
**discarded** — it used to be kept, so the re-selected schedule marched straight back into
the same corner.

*(Correction to the plan note: `Nav_RequestPath`'s `avoid` argument is a link-flag mask,
not a position to route around, so feeding it the blocking point would have done nothing.)*

### p_models

`gl_hlmdl.c` read `entity_body = 0/*rent->body*/`, so **every studiomodel in the game drew
its default parts**. `barney.mdl` spawns at `BARNEY_BODY_GUNHOLSTERED`, so his pistol was in
his holster exactly as authored; `hgrunt.mdl`'s default happens to be the MP5, which is why
grunts looked right and he did not — the same bug, invisible on one model and glaring on the
other. `.body` was parsed and stored by the monster spawner and read by nothing.

Now a real entvar, networked in `entity_state_t` under its own `PEXT2_BODYGROUP` extension
(its own bit, not riding on `PEXT2_BONECONTROLS`, so older builds and existing demos are not
dropped on the new flag), and read by the renderer. Values are dumped from each model's
bodyparts lump — GoldSrc packs every part into one integer via `(body / base) % nummodels`.

That also lights up three animation events the sweep had flagged as raised-but-unconsumed:
`BAR_AE_DRAW`, `BAR_AE_HOLSTER` and `GRU_AE_DROP_GUN` — so a corpse that drops a pickup no
longer keeps the same weapon welded to its hand.

### Measured

| | before | after |
|---|---|---|
| 2fort headless client survival | ~10 s to segfault | **5 min, clean** |
| `hl_c01_a1` barneys with a gun in hand | 0 / 4 | **4 / 4** |
| corner-cuts (sidestep → original heading) | n/a (no such move) | fires; `sidestep=1 cornercut=1` |

Five-map regression clean, `crashaddr` 1956 → 1956, all three VMs 0 warnings.

### Owed in-game tests

**A — Barney's pistol.** It should be in his hand, not his holster, and gone from the corpse
once he drops it. Shotgun grunts should show the shotgun head.

**B — corners.** Lead an NPC round a doorframe and a pillar. `sv_ai_debug 1` prints
`sidestep=` and `cornercut=`; if sidesteps climb while cornercuts stay near zero, the fan is
finding room but not converting it into progress.

**C — BC7 textures.** Everything with a `.dds` should look slightly *brighter* than before
(the endpoints are finally being expanded). Anything that now looks wrong is bug 2 above
having been load-bearing somewhere.

### Not verified headlessly

The movement counters are structurally near-zero in every headless scenario available —
monsters on the test maps stay dormant, and the fire test hands them an enemy already in
range so they never walk. One sample did catch the full new path executing
(`walkmove=1 fails=1 sidestep=1 cornercut=1`), so it runs and works end to end, but it has
not been stress-tested. That is what owed test B is for.

---

## PATCH 132 — five systemic bugs in one function

Everything here lives in `AI_HandleSharedEvent` / `AI_EventSoundName`
(`server/sv_ai_anim.qc`), the one place every monster's animation events pass through. Three
were found by reading Valve's `HandleAnimEvent` beside ours line for line; two were found by
scanning the model corpus. All five were silent — the symptom in every case is a sound that
does not play, which looks exactly like a monster that has no such sound.

### 1 — the `*` prefix was never stripped, and the engine never even looked

GoldSrc writes `*` in front of a sound name to mean "stream this, don't cache it". It is a
storage hint, not part of the filename. FTE reads it as something else entirely: `S_LoadSound`
tests `*name == '*'`, takes it for a **Quake 2 sexed sound**, sets `SLS_FAILED` and returns
before the path is ever built (`engine/client/snd_mem.c:1058-1063`). So these were not files
that failed to resolve — they were files nobody looked for.

Measured across the 42 rigs the mod warms: **21 distinct names on 54 events**, every one of
them Valve's own — barney's and otis's `*buttons/blip1.wav`, the zombie's
`*debris/bustcrate1.wav`, and twenty scientist lines including `*scientist/scream3.wav` and
both `sci_pain` files. All 21 resolve in `valve/` the moment the star comes off.

### 2 — event code 2003 was unhandled

Not in the Half-Life SDK at all (`monsterevent.h` stops at 2010) — it is Sven Co-op's.
Identified by scanning **all 12038 loose `.mdl` files** in the mounts rather than guessing:
104 occurrences across 19 rigs, and every single one sits on a locomotion sequence — `walk`,
`walk_new`, `walk_scared`, `run`, `run1`, `run2`, `creeping_walk`, `pistol_walk` — with an
**empty options string in all 104**. It is a footstep event and there is nothing else it could
be.

Empty options means the sample has to be named in code, exactly like `BODYDROP`. The family is
quoted from the corpus rather than chosen: Valve's own models name `common/npc_step1..4.wav` in
843 `EVENT_SOUND` events, i.e. the same sound for the same purpose on the rigs that spell it out
instead of using 2003.

In *this* install only `hwgrunt.mdl` reaches the code — the valve copies of
hgrunt/barney/scientist/zombie win the path lookup — but that is a fact about mount order.

### 3 — `SWISHSOUND` was swallowed under a comment that was wrong

2010 rides on every melee wind-up in the gearbox rigs. It used to be discarded here under a
note claiming HL's client dll owned the sample and there was nothing to play. The sample is
named inline in the **server** dll (`monsters.cpp:2721-2726`), directly beneath Valve's own
all-caps warning that any monster using the event must precache it. An empty options field
means "the name is in the code", not "there is no name". Thirteen melee wind-ups across six
rigs had been swinging in silence.

### 4 — `BODYDROP` was invented rather than read

Three details wrong in one four-line branch (`monsters.cpp:2694-2719`):

| | was | Half-Life |
|---|---|---|
| file | LIGHT → bodydrop3, HEAVY → bodydrop4 | **random between the two, for both codes** |
| pitch | always 100 | HEAVY goes out at **90** (`EMIT_SOUND_DYN`) |
| gate | none | both gated on **`FL_ONGROUND`** |

So every heavy landing sounded identical to a light one, and a monster killed in mid-air
thudded while it was still falling.

### 5 — `ATTN_NORM` where Half-Life uses `ATTN_IDLE`

`monsters.cpp:2659` and `:2663` both pass `ATTN_IDLE` for `SCRIPT_EVENT_SOUND` and
`SCRIPT_EVENT_SOUND_VOICE`. The two engines agree on what that constant means — GoldSrc and
Quake both cut a sound off at `1000/attenuation` units and `ATTN_IDLE` is 2.0 in both — so this
is an exact match at 500 units. `ATTN_NORM` was carrying every monster footstep and every event
voice line 1000 units in a game whose own AI can only hear 1024, which is why one zombie could
be heard walking from most of a map away.

### New tool: `sv_ai_walktest`

`sv_ai_firetest` places its subjects already in range, so they stand still and shoot: a whole
firetest run reports `walkmove=0`. That left the entire moving half of the animation system
with no number on it. The walk test is its mirror — subjects spawn ~900 units out and have to
walk in — and its roster is one rig of each footstep dialect on purpose:
`monster_human_grunt` (spells footsteps out as `EVENT_SOUND`) as the control, `monster_hwgrunt`
(code 2003, no name) as the subject. `shared` moving while `step` stays at 0 would localise a
fault to the 2003 branch and nothing else.

### Measured

| counter | before | after |
|---|---|---|
| `star=` (stream prefixes stripped) | 0 — structurally impossible | **59** at map load |
| `step=` (2003 footsteps) | 0 — code unhandled | **1** in a 16 s walk test |
| `swish=` (2010 melee) | 0 — deliberately discarded | **2** in a firetest run |

59 rather than the corpus's 54 because `monster_bodyguard` falls back to `barney.mdl` on this
install, so that rig is warmed twice — confirmed against the model report, not assumed.

Five-map regression clean, `crashaddr` 1956 → 1956, all three VMs 0 warnings.

### Owed in-game tests

**A — volume.** Item 5 is the one change here that is HL-correct without being obviously
*better*. Monster footsteps and event voice lines now carry half as far. If NPC lines read as
too quiet, `ATTN_IDLE` → `ATTN_NORM` in the two `sound()` calls reverts it.

**B — the scientist.** Sixteen of his lines have never played. He should now be audible on the
scripted sequences in `hl_c01_a1`.

**C — the swish.** Grunt and male-assassin melee wind-ups should have a whoosh.

### Not verified headlessly

That the stripped names actually *load* on a client. The headless client harness runs with
`nosound 1`, so no sample is loaded either way — the run is clean but that is not evidence. The
claim rests on two things that are: all 21 files were confirmed present in `valve/` by direct
lookup through the mounts, and the engine's load path is unambiguous about the star.

---

## PATCH 133 — the grenade animation, and the same bug on four other rigs

### The reported bug, and Half-Life's own fix

> *"I think it plays the submachinegun grenade animation and not the grenade animation."*

Exactly right. `hgrunt.mdl` tags **two** sequences as activity 29: `throwgrenade` (the overhand
toss, event code 7 at 1.20 s) and `launchgrenade` (the underbarrel M203 shot, code 8 at
0.53 s). `frameforaction` re-rolls its weighted random on every call, so which one played was a
coin flip — and the *behaviour* was already loadout-driven, so the two openly disagreed: the
grunt mimed an M203 shot and a hand grenade came out.

Half-Life never had this because `CHGrunt::SetActivity` (`hgrunt.cpp:1866-1972`) picks these
**by name** and lets everything else fall through to `LookupActivity`. That per-class hook had
no equivalent here, so it is now `.ai_seqfor(m, act)` — called from `AI_SetActivity` at exactly
the point HL calls it, returning `""` to fall through, and falling through silently when a rig
does not carry the name (Sven ships replacement models freely).

### Four more collisions the same table resolves

Measured, not assumed — every activity tag with more than one candidate, across the shipped rigs:

| rig | act | candidates |
|---|---|---|
| hgrunt | 28 | `crouching_mp5` / `crouching_shotgun` |
| hgrunt | 29 | `launchgrenade` / `throwgrenade` |
| hgrunt_opfor | 28 | + `crouching_saw` |
| massn | 28 | + `crouching_m40a1` |
| hwgrunt | 28 | `attack` / `pistol_shoot` / `pistol_crouchshoot` |
| hwgrunt | 3, 4 | `creeping_walk`/`pistol_walk`, `run`/`pistol_run` |

So an MP5 grunt fired the shotgun pose half the time; an OpFor grunt fired the **SAW** pose a
third of the time, and the SAW animation raises *seven* burst codes against the MP5's three, so
he put twice the rounds downrange for free; and the HW grunt played a pistol animation two
times in three.

**The HW grunt case is also the sound bug**, and this is why it is one fix and not two: the
sound is chosen by which event code arrives, and the code comes from the animation. Playing
`pistol_shoot` routed him into the pistol branch, which called `Grunt_FireSound` → the MP5
report. He made a submachine gun's noise while holding a minigun. Fixing the pose fixes the
audio because on this rig they are the same decision.

**And `standing_mp5` / `standing_shotgun` carry `act=0 w=0`** — no activity tag at all. They
were unreachable, so **every grunt in this mod has fired from a crouch since the day the AI
landed**. HL reaches them by name off `m_fStanding`, which flips on a 1-in-10 roll per attack
selection; that is now ported too.

### The minigun had no sound call at all

`HWGrunt_Event`'s muzzleflash branch fired fifteen rounds over 0.58 s in complete silence.
`hassault/hw_shoot1-3.wav` have shipped in `valve/` since 1998 and were precached by nobody.
Rate-limited to one per burst rather than one per flash, because the samples are **1.19–1.29 s**
each — a full burst of minigun fire, not a single round.

### massn's bodygroup arithmetic was the hgrunt's

Dumped from the bodyparts lump:

```
hgrunt.mdl   heads n=4 base=1, weapons n=3 base=4   ->  body = head + weapon*4
massn.mdl    heads n=3 base=1, weapons n=3 base=3   ->  body = head + weapon*3
```

They shared a branch. massn's "gun gone" value was `head + 8`, which on a base of 3 asks for
weapon 8/3 — floored, that is the **M40A1**, so a disarmed massn corpse was handed a sniper
rifle. Split out with its own bases.

### Two invented sounds removed

`HGRUNT_AE_GREN_TOSS` (`hgrunt.cpp:882-892`) plays **nothing**; the callout is the `HG_THROW`
sentence, a different system. What was here instead was `hgrunt/gr_mgun1.wav` on `CHAN_VOICE` —
the MP5 burst report coming out of the grunt's throat on every single grenade throw. The M203's
`weapons/glauncher.wav` also goes out at HL's own volume of 0.8 rather than 1.

### The invisible grenade model: measured, and it is not the QC

Instrumented end to end with `sv_proj_test`, which now **repeats every 6 s** instead of firing
once (the headless client needs the better part of a minute to mount every VPK and start CSQC,
so a one-shot always fired into a world with nobody able to see it and its 30 s fuse expired
unseen) and falls back to a spectating player when no live one exists (the harness client never
presses fire, so the strict test waited 79 seconds and threw nothing — a silent early-out that
read exactly like "thrown and invisible").

Ten grenades over one run, server and client agreeing on every field:

```
[projtest] type=0 owner=world model="models/weapons/wpn_hlgrenade/w_grenade.mdl" modelindex=90
[proj] new  type=0 model="models/weapons/wpn_hlgrenade/w_grenade.mdl" modelindex=90 org=...
[proj] live type=0 modelindex=90 drawmask=1 org=... vel=...
```

That eliminates all three causes the instrumentation was written to distinguish: the model
resolves, the index is non-zero on **both** sides, `drawmask` is set and the origin tracks the
server through flight and settle. The model file is fine too — 7.2 × 6.6 × 11.0 units, an 85-colour
skin, no shader or replacement-texture override anywhere. Whatever remains is downstream of
everything the QC controls, and needs a screen.

### Measured

| | before | after |
|---|---|---|
| grenade sequence vs loadout | coin flip, uncorrelated | `if (weapons & HANDGRENADE)` — no randomness left |
| `seq overrides: taken=` | 0 (no such mechanism) | **17–19 per 2 s** in a firetest |
| `seq overrides: missing=` | n/a | **0** |
| boot-time `seqprobe` MISSING, 7 rigs | n/a | **empty on all seven** |
| HW grunt firetest damage | 124 | 128 |
| sound `not precached` warnings | — | **0** |

The boot-time probe is the better of the two numbers: the counter only reports names that were
actually *requested* during play, so a rig with a missing grenade animation would stay silent
until somebody happened to fight it at the right range. The probe reports on every map load, on
every install.

Five-map regression clean, `crashaddr` 1956 → 1956.

### Also fixed while here

`sv_ai_firetest`'s report window was 14 s, and the houndeye — the class the test was *added* to
clear — selects its first attack about three seconds after the report has already printed,
because it opens in `combat_face` and then needs a 2.36 s wind-up. Traced out of the log rather
than guessed at. Window is now 20 s, and **all seven of the roster land damage for the first
time**:

| class | 14 s window | 20 s window |
|---|---|---|
| male assassin | 464 | 696 |
| shocktrooper | 248 | 368 |
| human medic ally | 168 | 248 |
| human torch ally | 152 | 232 |
| hwgrunt | 128 | 124 |
| alien slave | 30 | 50 |
| **houndeye** | **0** | **2.83** |

### Owed in-game tests

**A — the grenade.** Watch a grunt throw. The overhand toss, not the M203 shot, and no MP5
report out of his throat.

**B — standing fire.** Grunts should now sometimes fire from a stand instead of always from a
crouch, and always with the pose for the gun they are holding.

**C — the HW grunt.** A minigun burst that sounds like a minigun.

**D — the grenade model.** Still the open one. `sv_proj_test 1` now throws one every six
seconds in front of you, so it is a single command to check.

---

## PATCH 134 — the sound audit: every class, and a check that cannot rot

### Four files that have never existed

The audit's method was to verify every sound name against the **mounts**, not against the SDK
and not against memory. That immediately found four names that are in this tree, precached
correctly, played correctly, and referring to nothing:

| name | where | consequence |
|---|---|---|
| `controller/con_fire1.wav`, `con_fire2.wav` | `mon_swimfly.qc:62-63, :167` | the controller's energy ball has **always** been silent, and two precache slots failed at every map load |
| `gonarch/gon_pain3.wav` | `mon_bosses.qc:56, :225` | one arm of a coin flip, so **half** the gonarch's pain events were silent |
| `ichy/ichy_bite3.wav` | `mon_swimfly.qc:121` | the bite rolled 1..3 against a family of 2, so **one ichthyosaur bite in three** was silent |

Every one is a `sprintf("...%g...", ceil(random() * n))`, and every one of those is an unwritten
claim that the family runs `1..n` with no gaps. The claim is false more often than not:

```
ichthyosaur   HL takes pain 2/3/5, alert 2/3, die 2/4  (pain1, alert1, die1, die3 exist, unused)
gonarch       pain 2/4/5                               (there is no gon_pain1 or gon_pain3 anywhere)
islave        alert 1/3/4                              (slv_alert2 does not exist)
gonome        death 2/3/4                              (there is no gonome_death1)
agrunt        alert 1/3/4/5                            (ag_alert2 exists and Valve does not use it)
```

### The fix is a data structure, not twenty more functions

`.ai_snd_pain` / `_die` / `_idle` / `_alert` hold a space-separated list of complete paths;
`AI_SndPlay` picks one and `AI_SndPrecache` walks the identical string. The `.void()` virtuals
still win where a class has real logic, so nothing that already worked changed.

Two things this buys that the old shape could not:

- **Gaps are expressible.** A family is what Valve's array says it is, not `1..n`.
- **One literal precaches and plays.** Precached-but-never-played and played-but-never-precached
  stop being possible on this path. Both were present in this tree.

It also carries HL's own emit parameters, which were being dropped: `EMIT_SOUND_ARRAY_DYN`
(`monsters.h`) is **not** a plain `EMIT_SOUND` — it plays at `RANDOM_LONG(95,105)` pitch, and
that jitter is most of why four idle lines do not sound like exactly four idle lines.
`.ai_snd_atten` and `.ai_snd_pitch` carry the per-class overrides (ichthyosaur 0.6, leech alert
0.4, gargantua ±10, roach ±20). Both engines cut a sound off at `1000/attenuation` units, so
those numbers cross over unconverted.

### Sounds that were precached and unreachable

Not a stylistic complaint — each line below is a sample that has shipped since 1998, that this
mod loads into a precache slot on every map, and that no code path could ever play.

| sample(s) | class | why it never played |
|---|---|---|
| `weapons/hks1-3.wav` | miniturret, sentry | precached in **`mon_grunt.qc`**, described as "the weapon sounds HL's grunts use". They are not — they are the miniturret and sentry guns (`turret.cpp:633-635, :1193-1195`). Every turret in the mod fired `tu_fire1`, which is only the **ceiling** turret's gun |
| `headcrab/hc_pain1-3.wav` | headcrab | the class had no `.ai_painsound` at all — 705 placements, the third most-placed class in the corpus |
| `roach/rch_die.wav` | cockroach | no `.ai_death` |
| `barnacle/bcl_bite3.wav` | barnacle | Valve's own comment on the precache line calls it *"just got food to mouth"*. It is the one sound that tells you a teammate has been grabbed |
| `apache/ap_rotor2.wav` | apache | an apache was **completely silent** until it opened fire |
| `garg/gar_step1-2`, `gar_breathe1-3` | gargantua | its footstep and breathing events were explicit no-ops under a comment saying the model names no file on them. True, and beside the point: HL names them in the **server dll**, exactly as it does the zombie's SWISHSOUND |
| `weapons/357_shot1.wav` | turret | not a turret sound in Half-Life and never played here. Removed |

### Wrong sounds

- **The apache's gun was `apache/ap_whine1.wav`** — a 75 KB **turbine loop**, fired once per
  burst. HL fires `turret/tu_fire1.wav` at attenuation 0.3 (`apache.cpp:834`), which carries
  3333 units: a gunship shooting at someone else is meant to be a map-wide event.
- **Otis fired Barney's 9 mm.** `otis.mdl`'s five textures are `otis.BMP`, **`Desert_Eagle.bmp`**,
  `donut.bmp` and two heads. With no OpFor SDK on this machine the model is the authority, and
  it is not ambiguous — `barney.mdl` carries no such texture. He shares Barney's rig, events,
  sentence group and class init, so the rig-override hook now changes exactly the one thing that
  differs.
- **The gonarch's SCREAM played her ATTACK family.** Event 14 is the alert (`bigmomma.cpp:492`),
  so `gon_alert1-3` were unreachable and the scream sounded like a second swing.
- **The turret's alert was `tu_active2`** — the running-**spin loop**, a sample meant to sit
  under it continuously on `CHAN_STATIC`, not a one-shot. `tu_alert.wav` had never been
  precached by anything.
- **The gonarch's sack sloshed on every event.** HL gates it at 30 % (`bigmomma.cpp:507`)
  because the event sits on her idle *and* her run cycle.

### Classes that made no sound at all

`monster_gonome` (127 placements), `monster_alien_voltigore` (38) and `monster_kingpin` (26)
had no pain hook and no death hook, and none of their sounds were precached — so on an install
that *has* the mounts they also produced live `SV_StartSound: not precached` warnings. All three
now carry idle/alert/pain/die plus their melee and ranged attack samples, and all of it is
guarded on `m.model` rather than on the classname: `Monster_DefaultModel` falls a pitdrone back
to `bullsquid.mdl` when gearbox is absent, and the gearbox *sound* directory is missing on
exactly the same installs, so the test that picked the model has to pick the voice.

`monster_stukabat` (60 placements) gets the one sample Sven ships for it — a 1.5 KB wing flap.
That is genuinely its entire sound set; nothing was invented to fill the gap.

One entry on the plan's list of missing hooks was **wrong, and stays unfixed on purpose**: the
zombie has no `.ai_death` because `CZombie` has no `DeathSound` either. Zombies do not have a
death sound in Half-Life.

### The callout the grunts never made

The grunt family speaks in **sentences**, and the talk layer already covered IDLE, HELLO, SHOT,
MAD, SCARED, OK, WAIT and POK. What no class had was the line it says the moment it *sees* you.
`HG_ALERT` and `BA_ATTACK` are now installed on `.ai_alertsound`, which `SCHED_WAKE_ANGRY`
runs at exactly the right beat. (Groups confirmed present in all three mounted `sentences.txt`
files: valve 404 groups, gearbox 323, bshift 293.)

And `HG_THROW` is back on the grenade — the second half of PATCH 133's fix. Removing the MP5
burst report that used to play out of the grunt's throat there was right (`hgrunt.cpp:882-892`
plays no *sound*), but HL does **speak** on that beat, and dropping the wrong noise without
restoring the right one left a silent throw.

### The check that replaces the compiler's

Routing families through a runtime walk defeats fteqcc's F210 *"sound used but not directly
precached"*, so the trade had to be paid for. Every name that goes through `AI_SndPrecache` is
kept in a register, and `sv_ai_selftest` walks it asking `whichpack()` — which is a **stronger**
check than F210, because F210 can only tell you a precache line is missing, while `whichpack`
tells you the file does not exist. That is the failure mode this whole audit kept finding.

```
[ai-selftest] sounds: 204 registered, 0 dupes, 0 overflow, 0 MISSING
[ai-selftest]   control: absent=notfound(ok) present=found(ok)
```

The control line is the reason the report is worth reading: a name that cannot exist must report
missing and a name that must exist must report present. Without it, a wrong path prefix would
make every entry report missing and the number would look alarming but mean nothing.

### `sv_ai_voicetest` — because the other two harnesses cannot fail here

The first run of the family path reported `voices played=0` on all five regression maps *and*
under `sv_ai_firetest`. That is not a bug: the firetest roster is the seven classes that
**shoot** and the walktest roster is two grunts, and all nine keep hand-written `.ai_painsound`
functions. Neither harness touches `AI_SndPlay` at all, so both would have reported 0 whether
the new path worked or was dead code. A harness that cannot fail is not a test.

So: a roster of five classes that have **nothing but** families, hurt on a timer.

```
[voicetest] spawned monster_headcrab          pain=[hc_pain1 hc_pain2 hc_pain3]
[voicetest] spawned monster_alien_grunt       pain=[ag_pain1..ag_pain5]
[voicetest] spawned monster_alien_controller  pain=[con_pain1..con_pain3]
[voicetest] spawned monster_bullchicken       pain=[bc_pain1..bc_pain4]
[voicetest] spawned monster_pitdrone          pain=[pit_drone_pain1..pit_drone_pain4]
[voicetest] monster_pitdrone           painstamp=1 families=4
[voicetest] monster_bullchicken        painstamp=1 families=4
[voicetest] monster_alien_controller   painstamp=1 families=4
[voicetest] monster_alien_grunt        painstamp=1 families=4
[voicetest] monster_headcrab           painstamp=1 families=2
[voicetest] hurt ticks=24  voices played this run=94  registered=204
```

94 over twelve seconds against a pain rate limit of one per monster per second — the surplus is
the idle and alert families, which these classes also did not have before. `painstamp`
distinguishes *hurt but mute* from *never hurt at all*, which look identical in a total. The
pitdrone reporting `pit_drone_*` rather than `bc_*` is the model-guard branch resolving
correctly on an install that has gearbox.

Two bugs of the harness's own, both found by it failing to print at all: it lost its player to
the roster it had just spawned and hurt (fixed the way the walktest does, by keeping the observer
alive), and it took its delta against the counter the periodic `[ai]` report zeroes every two
seconds.

### Verification

- Five-map regression: both self-tests `BAD=0`, errors 0, `crashaddr 1956 → 1956`.
- `sounds: 204 registered, 0 MISSING`, control passing in both directions.
- `voicetest: 94 voices played, 5/5 classes painstamped`.
- Compiles at **0 warnings**, including F210 — the direct `sound()` call sites keep their
  literal `precache_sound` so the static check still covers everything it can see.

### Owed in game

None of the above proves a sound is **audible**; the harness runs `nosound 1`. What is proven is
that every name resolves, that the families reach `sound()`, and that the counts are right.
Worth listening for specifically:

1. **A controller attacking.** Its shot has been silent since the class landed.
2. **A gargantua walking toward you.** The footsteps are the arrival warning and there were none.
3. **An apache before you see it** — the rotor loop, and it must stop when the apache dies
   (`AI_Died` clears `.ai_snd_loop`; a forced loop otherwise runs until something replaces it).
4. **A miniturret vs the big ceiling turret.** They should no longer sound identical, and both
   should now make a noise deploying and retracting.
5. **Otis.** A Desert Eagle, not a Glock.
6. **A grunt spotting you**, and a grunt throwing a grenade — both should now say something.

---

## PATCH 135 — monster tracers, the shock bolt, and a skill table that was never sourced

### No monster in this game has ever drawn a tracer

Not a shocktrooper bug, which is how it was reported. `CSQC_SpawnTracer` is called from three
places and all three are player weapon paths (`sh_weapon_logic.qc:1282, :1371, :1603`). The one
path that *should* have covered monsters is `CSQC_BulletImpactRemote`, which reconstructs the
tracer's start from the shooter entnum carried in `CSQC_EVENT_IMPACT` — and it resolves that
entnum two ways, both of which are structurally player-only:

```
findchain(classname, "player_visual_proxy")   CSQC entities, spawned by us
findfloat(world, entnum, shooter_entnum)      also CSQC entities: .entnum is a field
                                              WE set on entities WE made
```

A monster is a plain engine-networked entity with no CSQC counterpart at all, so it is in
neither set, the lookup returned `world`, and the tracer was skipped. What a monster's fire has
always looked like is a muzzle flash and a wall puff with nothing in between.

`getentity()` (#504) reaches the set `findfloat` cannot, and `cl_monstertrace.qc` already
maintains the answer to "which of those are monsters" — the per-map modelindex registry the
server publishes as `CSQC_EVENT_MONSTER_MODELS`. So the fix is a second consumer of an existing
structure rather than a new one, at zero extra bandwidth.

The muzzle is reconstructed two thirds up the hull and pushed 12 units along the yaw-plane
facing — the same `AI_MUZZLE_FRAC` / `AI_MUZZLE_FWD` the server fired from. Both ends are
approximations (HL uses a per-model attachment point and neither end has one), but they are the
*same* approximation, so the streak leaves where the flash is.

**The registry gate is load-bearing, not belt-and-braces.** The entnum arrives on the wire and
is read a ping later, by which time a monster that died has freed its slot for reuse. Anchoring
a tracer on a door is worse than drawing none.

### The report that had never been called

`CSQC_MonsterTrace_Report` has existed since the monster-collision fix landed and **nothing has
ever called it**. The one module whose entire output is a visual effect — and which therefore
leaves no other trace in a log — was reporting into a void. It is now called from
`CSQC_UpdateView` and from `CSQC_Parse_Event`, and it prints its zeroes deliberately: a silent
report cannot distinguish "monsters fired and no tracer drew" from "no monster fired", which is
the exact confusion that let the original bug ship in this very file.

### An engine bug the first honest reading exposed

The first run reported `tracers=0 unanchored=20`, so the resolve was rejecting every shot. The
per-gate breakdown named it immediately, and then the control line finished the job:

```
[montrace]   unanchored: range=0 inactive=20 notmon=0 | live-slots=0 of 0, monsters=0
```

`getentity` reported a table of size **zero** while several hundred entities were live on the
wire. `cl.lerpents` — and the `cl.maxlerpents` that bounds it — is populated only by
`CL_TransitionEntities`, which under QuakeWorld is reached from `CSQC_DrawView` and
`V_RenderView` and nowhere else. `Headless_SCR_UpdateScreen` (`engine/client/vid_headless.c:206`)
sleeps 100 ms and returns.

So **a headless client's entity table is permanently empty**, and that is not a rendering
difference. Everything that reads it silently does nothing: CSQC `getentity` (`pr_csqc.c:6070`
tests `cl.maxlerpents` first), entity sound spatialisation (`snd_dma.c:2771`), the
spectator-track camera (`cl_pred.c:1067`), status-bar entity lookups (`sbar.c:3669`). A null
renderer is a null *renderer*, not a null client frame. One guarded `CL_TransitionEntities()`
call fixes it, and turns the whole `getentity` API — the only way CSQC reaches non-CSQC entities
— from untestable-without-a-screen into a number.

```
before   models=11 sweeps=0 monster-hits=0 tracers=0  unanchored=20
after    models=11 sweeps=0 monster-hits=0 tracers=20 unanchored=0
```

The plan's requirement for this item was "monster tracer events emitted, **today provably 0**".

### The shocktrooper carries a shock rifle

Hitscan was not merely invisible here, it was the wrong primitive. `monster_shocktrooper` (208
placements) fires a bolt of energy, so it now goes down `AI_FireBeam` — the islave's and the
voltigore's path — with a beam kind of its own. Fixing the tracer blindness alone would have
given it a lead streak.

`Shocktrooper_Event` is a thin handler: it intercepts the firing and kick codes and hands
everything else straight back to `Grunt_Event`, so the shared hgrunt vocabulary stays shared.
`strooper.mdl`'s `crouching_mp5` raises **one** firing code (4 @0.07), so this is one bolt per
trigger pull.

**The colour is read out of the file, not remembered.** The shock rifle is usually described as
a green weapon. `sprites/muzzle_shock.spr` (gearbox, 32×32, 3 frames) disagrees — its 256-entry
palette is

```
(0,251,252) (1,213,237) (0,184,196) (4,148,203) (2,112,155) (2,94,145) (2,45,85)
```

red at zero the whole way down. It is **cyan**. Green would have been a plausible, checkable,
wrong answer, and `HL_BEAM_SHOCK` exists as a third kind rather than a recoloured egon precisely
because the kind is what picks the dlight: borrowing `HL_BEAM_EGON` would have put a blue Xen
glow on it on every client.

### A skill table that was never sourced from anything

`Sven Co-op/svencoop/skill.cfg` is on disk — 323 lines, "VERSION: Sven Co-op v5.23". This
matters more than it sounds. Where a class exists in Half-Life, this mod's numbers are HL's own
and can be checked. The classes below **exist only in Sven and Opposing Force**, there is no
OpFor SDK on this machine, and their numbers here were therefore never sourced from anything —
they were picked to look plausible beside their HL cousins.

| class | was | skill.cfg |
|---|---|---|
| `monster_shocktrooper` | 50 (fell through to the line grunt) | **200** |
| `monster_hwgrunt` | 50 (likewise — it is the *heavy* grunt) | **200** |
| `monster_otis` | 35 (fell through to Barney) | **65** |
| `monster_alien_voltigore` | 200 | **350** |
| `monster_kingpin` | 250 | **450** |
| `monster_babygarg` | 400 | **600** |
| `monster_stukabat` | 60 | **123** |

A shocktrooper at a quarter of its intended health is not a balance preference; it is a class
that dies to one magazine on a map built around it taking four.

Damage followed the same pattern: the voltigore's energy ball was 25 against
`sk_voltigore_dmg_beam` 40, the pitdrone's melee 22 against 25, the gonome's claw 20 against 30,
the kingpin's 30 against 40, the stukabat's 15 against 12, and the shocktrooper's kick was
`dmg*2` = 16 against `sk_shocktrooper_kick` 12. The bolt is `sk_plr_shockrifle` 15 — skill.cfg
has no monster-side entry because the trooper fires the *player's* weapon, which is the whole
point of the class.

**And the Desert Eagle hit like a Glock.** PATCH 134 fixed the sound on the three rigs that
carry one (`otis.mdl`, `hgrunt_torch.mdl`, `hgrunt_medic.mdl` — read out of their bodygroups).
The damage is the other half of the same fact, and it was still coming from the classname:
`sk_otis_bullet` is **34**, and they were doing Barney's 10. New `.ai_shot_dmg` is a per-rig
override, 0 meaning "use the class cvar", set in the same rig-override branch that already knew.

Every value is a cvar, so a server that wants Sven's numbers for the HL classes too has the
table above to set them from. The HL classes deliberately keep HL's.

### The column that caught one more

Both existing harnesses overwrite health — the firetest sets its subjects to 100000 so a bot
cannot shoot them, the voicetest keeps hurting them — so "what does a monster of this class
spawn with" had no number anywhere, and a class silently inheriting another class's default
produced no symptom short of playing the map. The boot-time class inventory now carries it:

```
[ai-selftest] model monster_hwgrunt         models/hwgrunt.mdl    hp=200 <- svencoop
[ai-selftest] model monster_shocktrooper    models/strooper.mdl   hp=200 <- gearbox
[ai-selftest] model monster_otis            models/otis.mdl       hp=65  <- gearbox
[ai-selftest] model monster_stukabat        models/stukabat.mdl   hp=123 <- valve
[ai-selftest] model monster_kingpin         models/kingpin.mdl    hp=450 <- valve
[ai-selftest] model monster_alien_voltigore models/voltigore.mdl  hp=350 <- gearbox
```

Reading it found one the audit had missed: `monster_human_medic_ally` at 35 beside
`monster_human_torch_ally` at 50. They are the same Opposing Force engineer pair on the same
rig; the medic had Barney's number only because it runs `Barney_ClassInit` for its *talk*
behaviour — the right init and the wrong health table. Both take the grunt's now.

### Verification

- Five-map regression: both self-tests `BAD=0`, errors 0, `crashaddr 1956 → 1956`.
- `sounds: 204 registered, 0 MISSING`, control passing both ways.
- `[montrace] tracers=20 unanchored=0` per two seconds, against `tracers=0 unanchored=20`
  before, with `live-slots` proving `getentity` is answering.
- `sv_ai_firetest`: all seven classes still land damage. The shocktrooper's 480 is now beam
  damage, not hitscan; the torch and medic went 240 → 816 on the deagle correction.
- Server, client and menu compile at **0 warnings**; engine builds clean and is deployed to
  `C:\FTEQuake` and `Desktop\Quakers`.

### Owed in game

The tracer *appearance* — that it leaves the right place and reads as one streak per round
rather than a swarm — and the shock bolt's cyan. The counters prove the events fire and anchor;
they cannot prove either looks right.

---

## PATCH 136 — creature attack visuals, and three colours that memory would have got wrong

### There was not one creature effect in the particle set

The whole set is weapons, impacts and weather. That is not an oversight per class, it is
structural: **the server never called `pointparticles` or `trailparticles` once**, and never set
`.traileffectnum` on anything. So every creature attack arrived as a bare model or sprite entity
with nothing around it, and the ones with no entity at all — the gargantua's stomp, the alien
slave's zap wind-up, the controller's hands — arrived as nothing whatsoever.

`CSQC_EVENT_ALIEN_FX` is **one** event rather than one per creature, because all of them are the
same shape on the wire: a point, a direction, and which effect. The kind picks both the recipe
and the dynamic light client-side, so adding a creature effect is one row in `sh_alienfx.qc` plus
one `r_part` block in the new `particles/aliens.cfg`. 16 bytes; direction is quantised to three
signed bytes the same way `W_ImpactEffectSend` quantises its normal, which matters because these
fire on animation events at up to ten a second per creature.

| beat | before | now |
|---|---|---|
| bullsquid / pitdrone / gonome spit | bare `bigspit.spr` entity | spray at the mouth **and again where it lands** (`bullsquid.cpp:554-561, :157-164`) |
| alien grunt hornets | bare `hornet.mdl` | magenta muzzle flare per hornet, five per volley (`agrunt.cpp:458-464`) |
| alien slave zap wind-up | **sound only** | a flare per powerup, four per zap, brightening (`islave.cpp:368-377`) |
| alien slave zap | egon beam | + muzzle flare, thrown along the beam |
| alien controller charge | **explicit no-ops** | hand energy at the head |
| gargantua stomp | **no visual of any kind** | red ring at the damage radius + eight ground bursts |

### The colours are read out of the sprite files

Three of the five would have been wrong from memory. Method: parse the GoldSrc sprite header's
256-entry palette directly. texFormat 0 = normal, 1 = additive, 2 = index-alpha, 3 = alpha-test.

```
muz4.spr      64x64  additive     (255,255,255) (222,148,222) (189,16,148) (156,24,132)
xspark4.spr   32x32  additive     (255,252,14)  (226,197,9)   (188,134,0)  (151,80,0)
gargeye1.spr  32x32  additive     (255,255,255) (231,24,24)   (181,16,16)
tinyspit.spr  16x16  INDEX-ALPHA  a flat 0..255 greyscale ramp
```

- The alien grunt's hornet muzzle is **magenta**, not the orange a muzzle flash is assumed to be.
- The controller's hand energy is **yellow-orange**. The controller reads as a blue creature and
  its energy is not blue.
- The gargantua stomp is **red with a white core**.
- `tinyspit.spr` and `bigspit.spr` are **index-alpha**: the greyscale ramp *is* the alpha channel,
  so those two files carry no colour information whatsoever and the spit's familiar yellow-green
  comes from the entity tint. The value in `aliens.cfg` is therefore the only one here that is a
  choice, and it is labelled as one.

The shock rifle got the same treatment in PATCH 135 and it went the same way — `muzzle_shock.spr`
is cyan, not the green the weapon is always described as. Four sprites checked, four assumptions
that would have been wrong.

### The stomp is a ring, deliberately

HL's `CStomp` (`gargantua.cpp:79-195`) walks a wave of ten sprites **forward**, because HL's stomp
damages forward. This port's is `AI_BlastAttack`, which is **radial**. Drawing a travelling line
would advertise a threat model the damage does not implement — and the extent is the entire
gameplay information in this attack, which is exactly why having none was worse here than
anywhere else. It reuses `CSQC_EVENT_SHOCKWAVE` at the real damage radius, plus eight discrete
ground bursts rather than a continuous skirt (a solid ring reads as a dome; HL's wave is ten
separate sprites).

### Two bugs found on the way in

**A gagged alien slave wound up flat.** `.ai_zapstage` was incremented *inside* the `if (!self.gag)`
test, so it doubled as a sound counter. `.gag` mutes a monster, not its visuals, so a gagged
slave would have raised four powerups at stage 0 and shown a flat flare instead of a building
one. The counter is out of the gag test now.

**`particleeffectquery` cannot be used as a gate.** The first run reported `events=4 unrecipe=4`
— the wire path working perfectly and every recipe rejected. `particleeffectnum` returns a slot
even for a name that was never registered, so `particleeffectquery` is the only thing that can
confirm a recipe exists, and it is what `Tracer_Resolve` gates on. But **`pe_null` — the particle
engine active whenever the renderer is headless — has a `NULL` `ParticleQuery` entry**
(`engine/client/p_null.c:56`), so the query returns empty for every name in a headless client.
Gating on it killed all seven recipes in the only configuration that can measure them.

Emitting on an unregistered slot is a harmless no-op, so the gate bought nothing. It is a
**diagnostic** now, reported separately: `noslot` is always a bug, `unverified` is 7 in any
headless run and 0 with a real renderer.

### Verification

```
[alienfx] events=4 recipes: noslot=0 unverified=7      <- the slave's four zap wind-ups
[alienfx] events=1 recipes: noslot=0 unverified=7      <- ...then the release
```

The alternating 4 / 1 is the strongest evidence available without a screen: it is the alien
slave's own event cadence arriving intact, per beat, on the client. Five-map regression clean
(`BAD=0`, errors 0, `crashaddr 1956 → 1956`), server and client at **0 warnings**.

### Not in this pass

**The gargantua's flame attack still does not exist.** `Garg_Event` handles SLASH and STOMP and
nothing else; HL's flame is four `CBeam`s of `xbeam3.spr` driven from a sustained attack state
(`gargantua.cpp:492-592`), which is a new attack with its own schedule, not a visual bolted to an
existing beat. Adding a half of it would have been worse than leaving it out. The colours are
already measured and recorded for when it lands: `xbeam3.spr` is a white ramp, so it is tinted at
runtime, and `gargantua.cpp` tints it 255/130/90 and 0/120/255 at brightness 190, scroll 20.

The alien slave's **arm beams** (`lgtning.spr`, `islave.cpp:75-82`) are also still absent — this
port has no persistent per-limb beam, which is why `SLV_AE_ZAP_DONE`'s `ClearBeams()` has nothing
to clear.

### Owed in game

Every effect in this patch. The counters prove each one is decided, sent, parsed and handed to
the particle system with a live slot; nothing here can prove one looks right, and the recipes are
the first draft of a look rather than a measured match. `reloadweapons` hot-reloads
`particles/aliens.cfg`, so tuning them needs no rebuild.

---

## PATCH 137 — directional death and hitgroup flinch, and a test that can see them

### Every monster in the game died the same way from every angle

`ACT_DIE_HEADSHOT`, `CHESTSHOT`, `GUTSHOT`, `BACKSHOT` and the seven `ACT_FLINCH_*`
(`sv_ai_defs.qc:162-172`) each had **exactly one reference tree-wide: their own declaration**.
`SCHED_DIE` played `ACT_DIESIMPLE` from a table constant and `SCHED_SMALL_FLINCH` played
`ACT_SMALL_FLINCH`, so a grunt shot in the back from twenty feet and a grunt headshot at
point-blank range played the same animation, and being shot in the leg looked like being shot
in the chest.

Half-Life decides both at the moment the task starts — `GetDeathActivity` (`combat.cpp:346-460`)
and `GetSmallFlinchActivity` (`combat.cpp:469-517`) — from two pieces of state that had **no QC
equivalent at all**: `m_LastHitGroup` and `g_vecAttackDir`.

### The plumbing already half existed

The weapon layer resolves a hitgroup per bullet (`W_BoneToHitgroup` plus the OBB fallback,
`sh_weapon_logic.qc:560-670`) and stamps `.death_hitgroup` on the victim before calling
`W_ApplyDamage`. So the hitgroup did not need re-deriving — re-tracing here would have been a
second, differently-wrong answer to a question already answered. `AI_ConsumeHit` copies it, and
computes `g_vecAttackDir` centre-to-centre exactly as `combat.cpp:864-872` does, including
Valve's "pretend the inflictor is ten units lower" fudge.

It is called from `AI_Damaged` for a survivable hit and from `AI_Died` for a fatal one —
exactly one of the two runs per hit, because `W_ApplyDamage` dispatches `.on_damaged` only
while health remains and `.on_killed` only when it does not. Without the second call site the
death animation would be chosen from whatever the *previous* non-fatal hit was, and for
anything that dies in one shot, from nothing at all.

**Read-and-clear, which is a deliberate divergence from Half-Life.** `.death_hitgroup` is
written by the eleven paths that resolve one and by none of the other **52** callers of
`W_ApplyDamage` — doors, lasers, radius blasts, debug commands. Left latched, a monster shot
once in the head and later crushed by a door plays the headshot death. Half-Life has that bug
(`m_LastHitGroup` is written only in `TraceAttack` and never cleared) and it is not worth
porting: clearing makes an unstamped path read `HITGROUP_GENERIC`, which is precisely what
GENERIC means to both pickers — "no region, use the direction". Safe because every other reader
of `.death_hitgroup` inside `W_ApplyDamage` is gated on `classname == "player"`.

### `LookupActivity` had to be built, because the existing lookup always says yes

`AI_SeqForActivity` walks a fallback chain by design, so it can never answer "does this rig
carry that tag" — it always finds *something*. Both pickers need the honest answer, because
Half-Life's whole structure is *ask for the ideal, and where the model cannot do it choose
something else instead*, not *ask and take whatever comes back*. `AI_HasActivity` is the exact
test, range-checked against `modelframecount` for the same reason `AI_SeqForActivity` is —
`frameduration` silently clamps an out-of-range index and hands back a plausible number for it.

### Which of these animations exist at all

Censused across the 41 rigs this mod resolves, because "the constant exists in the SDK" and
"any model was ever authored with it" are different claims:

| activity | rigs carrying it |
|---|---|
| `ACT_DIE_HEADSHOT` | **16** |
| `ACT_DIE_GUTSHOT` | **14** |
| `ACT_DIEFORWARD` / `ACT_DIEBACKWARD` | **22 / 21** |
| `ACT_FLINCH_LEFTARM` / `RIGHTARM` / `LEFTLEG` / `RIGHTLEG` | **10 each** |
| `ACT_DIE_CHESTSHOT`, `ACT_DIE_BACKSHOT` | **0** |
| `ACT_FLINCH_HEAD`, `ACT_FLINCH_CHEST`, `ACT_FLINCH_STOMACH` | **0** |

Nothing in Valve's, Gearbox's or Sven's model set tags the last five, and **Half-Life's own two
functions never ask for `CHESTSHOT` or `BACKSHOT` either** — those constants are dead in
Half-Life as well, not merely unimplemented here. The consequence for the flinch half is worth
stating plainly rather than leaving to be discovered: `GetSmallFlinchActivity`'s `HITGROUP_HEAD`
and `HITGROUP_STOMACH` cases resolve to `ACT_SMALL_FLINCH` on **every monster in the game**, so
the entire visible effect of the flinch picker is the four limb flinches on ten rigs.

The census is now a column in `sv_ai_animtest` (`die/flinch=head gut fwd back limbs`) rather
than a number in this document, so a Sven install with replacement rigs reports its own answer
instead of inheriting Valve's.

### `TASK_PLAY_DEATH` and `TASK_PLAY_FLINCH`

Two new opcodes, because these are the only two activities a schedule **cannot** name up front.
Half-Life has the same pair for the same reason (`TASK_DIE` and `TASK_SMALL_FLINCH` assign
`m_IdealActivity` from the pickers rather than from a table constant). Both then behave exactly
like `TASK_PLAY_SEQUENCE` and block until the sequence ends.

### The test, which is the actual work

This system **fails silently by design**, and that is not a figure of speech. Every activity the
death picker can return already resolved to something before this patch: `ACT_DIE_HEADSHOT`
walks the fallback chain to `ACT_DIESIMPLE`, which is exactly what the old table constant asked
for directly. A completely dead directional-death system produces byte-identical logs,
identical framerates and identical damage numbers to a working one. Nothing short of shooting a
**known rig from a known direction at a known hitgroup and reading back which sequence it
actually chose** can tell them apart.

`sv_ai_deathtest` does that for eight subjects chosen to span the census — every branch of both
HL functions in one run rather than the happy path eight times:

```
monster_human_grunt    hg=head     front  flinch=flinch_leftarm  death=die_headshot   ideal=die_headshot
monster_barney         hg=stomach  front  flinch=flinch_leftarm  death=die_gutshot    ideal=die_gutshot
monster_zombie         hg=generic  behind flinch=flinch_leftarm  death=die_forward    ideal=die_forward
monster_alien_slave    hg=generic  front  flinch=flinch_leftarm  death=die_backward   ideal=die_backward
monster_alien_grunt    hg=leftleg  front  flinch=flinch_leftarm  death=die_simple     ideal=die_backward
monster_houndeye       hg=generic  behind flinch=small_flinch    death=die_simple     ideal=die_forward
monster_headcrab       hg=head     front  flinch=small_flinch    death=die_simple     ideal=die_headshot  (rig lacks it)
totals: deaths group=2 dir=2 simple=6 (nowhere-to-fall=2)  flinch limb=5 generic=2
```

Reading it: the region pick fires on both rigs that carry one; the direction pick falls the
right way twice (shot in the back → forward, shot in the front → backward); the two
`die_simple` rows whose ideal was **available** are the fall-room trace refusing, which is why
`nowhere-to-fall=2` is printed beside it; and the headcrab is the control — it must report
`die_simple` whatever it is asked for, and does. The flinch column splits exactly along the
census: `flinch_leftarm` on the five rigs that carry limb flinches, `small_flinch` on the two
that do not.

The shot direction is exact because the inflictor is a **dummy entity parked 100 units off the
subject's own facing**, not the player. That makes the dot product ±1 by construction, and it
keeps `AI_Provoke` out of the measurement — a player damaging an ally turns it hostile and puts
it straight into a combat schedule, which is the state that was delaying the flinch pick.

### Four bugs found while making the test tell the truth

Each of these produced a plausible-looking wrong answer rather than an error.

**A 100000-damage killing blow gibs everything.** `Gib_ShouldGibOnDeath` is HL's "was the
killing blow far past zero" test, and a gibbed monster is removed outright and never plays a
death sequence at all — reported as eight subjects that died without choosing anything. The
test now drops the pool to ten and takes it off with twelve.

**`Monster_Killed` calls `Monster_Teardown`, which unlinks the body from `monster_chain`
before `AI_Died` has even started the death animation.** A report that walks the chain
therefore finds nothing and says "8 of 8 test monsters gone" about eight corpses lying right
there. Subjects are held by reference now.

**Reading `.monster_chain_next` off an entity you are about to kill ends the walk.** The first
version of the kill loop killed exactly one subject and stopped, which reads as seven monsters
that refused to die. `sv_ai_core.qc:2707` has the same line for the same reason.

**The subjects fought each other.** With their own factions they were all in `MS_COMBAT`
running `range_attack1` within two seconds, and a monster mid-attack takes its schedule from
the class virtual, which sits above the generic flinch branch in `AI_SelectSchedule` — so the
flinch arrived several seconds late and the run measured schedule precedence rather than the
picker. One faction for all eight.

### A flaw in the existing harnesses, found and stated rather than quietly fixed

`sv_ai_firetest` and `sv_ai_walktest` place their subjects in a ring around the first live
player without checking that the player is anywhere real. On `th_ep1_00` a `bot_minplayers`
bot sits at `'0 0 37'` — the map origin — for the whole run, and **all seven firetest subjects
report "COULD NOT BE PLACED anywhere"**, which on the console is indistinguishable from seven
monsters that spawned fine and did not shoot. `sv_ai_spawntest` already documents this trap
(`sv_ai_core.qc:2353-2366`); the other two never got the guard.

The deathtest carries the nav-proximity guard, and it is **weaker than it looks**: `th_ep1_00`
has nav nodes near the origin, so the proximity test passes and the subjects still fail to
place. It is kept because it turns the case it *can* catch into a named line. The results above
were taken on `2fort`, where the bot spawns properly — and the firetest passes there too, all
seven landing damage.

### Also

`cmd ai_hurt [amount] [hitgroup]` takes a hitgroup now, and prints back the sequence the
monster **chose** rather than the one asked for, on a deferred think — the pick happens on the
monster's next decision tick, not inside `W_ApplyDamage`, so it cannot be read at the moment
damage is applied.

`evgap.py`'s animtest regex was updated for the new column and skips it non-greedily, so it
reads logs from either side of this patch.

### Verification

Five-map regression clean (`BAD=0` on all five, errors 0, `crashaddr 1956 → 1956`), server and
client at **0 warnings**, firetest 7/7 landing damage on 2fort.

### Owed in game

Whether the right animation *looks* right on each rig. The counters prove the correct activity
is chosen, resolved to a real sequence index and handed to the animation pump; they cannot show
that `hgrunt.mdl`'s `die_headshot` is the pose a player expects, or that a body downgraded by
the fall-room trace does not still clip a wall.

---

## PATCH 138 — the gargantua's flame, the slave's arm beams, and a harness that was lying

This closes the two gaps PATCH 136 named and deliberately left open.

### The gargantua had no flamethrower

`Garg_Event` handled SLASH and STOMP and nothing else, so the single most recognisable thing a
gargantua does was absent from a boss with 208 placements across the corpus.

**Why it needed a schedule rather than an animation event, which is why it was deferred.** Every
other attack in this mod lands on an event: the animation reaches a frame, damage happens, the
attack is over. The flame is not shaped like that — it burns for four and a half seconds, tracks
the enemy while it burns, damages continuously and re-draws itself ten times a second. Bolting
that onto `GARG_AE_SLASH` would have produced one frame of orange and no threat.

So: `SCHED_GARG_FLAME` and `TASK_FLAME_SWEEP`, task for task from `gargantua.cpp:394-403`. Two
things about that schedule are unlike every other attack here and both are load-bearing.

`TASK_SET_ACTIVITY`, not `TASK_PLAY_SEQUENCE` — `ACT_MELEE_ATTACK2` on `garg.mdl` is a **looping**
flame pose, so waiting for it to end would wait forever. The task owns the duration and the pose
plays under it. Half-Life commented out its own `TASK_PLAY_SEQUENCE` line for the same reason.

Zero interrupts, and that one is a gameplay decision rather than an animation one: a gargantua
that stops flaming because it took a bullet can be interrupted indefinitely by anyone with an
automatic weapon, which turns the boss of the corridor into scenery. HL's `slGargFlame` has no
interrupt mask either.

The cooldown is stamped at the **start** of the sweep, not the end (`gargantua.cpp:1092`), so a
sweep cut short by the target escaping still costs the full six seconds — otherwise a gargantua
re-lights every time someone steps in and out of the cone.

**The damage is a cone along the jet, not a radius at the monster.** `FlameDamage`
(`gargantua.cpp:608-672`) searches a sphere centred on the beam's *midpoint* with a radius of
half its length, projects each candidate onto the jet, and falls damage off past 64 units from
that line. Standing beside a gargantua is safe; standing three hundred units in front of one is
not. That shape is the entire reason the attack is worth implementing rather than approximating
with another blast.

Selection is `CheckMeleeAttack2` (`gargantua.cpp:934-947`): a **band**, 80 to 330 units, inside a
45-degree cone. Closer than 80 and it slashes instead. Damage is `sk_gargantua_dmg_fire` = 4 per
tick from Sven's `skill.cfg`, so an unbroken 4.5-second sweep is worth about 180 — which is what
the six-second cooldown and the cone are there to bound.

### The colours could not be measured, so the SDK is the authority

PATCH 136 measured four sprite palettes and three of them contradicted memory. That method does
not work here: `xbeam3.spr` is a plain **white ramp**, so both flame colours are runtime tints
and the file has nothing to read. `gargantua.cpp:514-520` is the only source:

```
i < 2 : width 240, SetColor( 255, 130,  90 )    <- the outer flame
i >= 2: width 140, SetColor(   0, 120, 255 )    <- the inner core
both  : SetBrightness( 190 ), SetScrollRate( 20 ), BEAM_FSHADEIN
```

The blue inner is genuinely blue and genuinely inside the orange — it is what makes garg fire
read as a cutting torch rather than a jet of petrol, and it is exactly the detail that working
from memory drops. It ships as the `+garg_flame` sub-recipe rather than a second wire event: the
two are one visual, always drawn together, and this is the only attack in the game that fires
ten times a second for four and a half seconds.

`++garg_flame` (embers) is **not** in Half-Life and is labelled as an addition. HL gets its
motion from a scrolling sprite; this port has no scroll, so without something moving the flame
reads as a static orange stick.

### The alien slave's arm beams

`SLV_AE_ZAP_DONE`'s `ClearBeams()` had nothing to clear because there were no beams —
`CISlave::ArmBeam` (`islave.cpp:723-762`) had no port.

Worth saying what this is *not*: it is not a beam at the enemy. The slave throws **three sample
rays at random angles** out to the side and up/down from a point above its shoulder, keeps
whichever hit closest, and hangs an arc between that spot and its hand. So the arcs land on the
wall, the ceiling, a crate — and a slave charging in the open produces **none at all**, because
nothing is close enough. That is the behaviour, not a limitation of the port, and it is why the
counter exists: "no arcs visible" has two causes and only a number separates them.

Three samples and keep the nearest, exactly as HL does: one ray would as often as not fly off
down a corridor and the arc would vanish for that powerup.

Colour and brightness are Valve's own, and the SDK even leaves the rejected value in place above
the shipped one:

```
// SetColor( 180, 255, 96 );      <- commented out in islave.cpp
SetColor( 96, 128, 16 );          <- what actually ships
SetBrightness( 64 );   SetNoise( 80 );
```

A **dim, muddy yellow-green at a quarter brightness** — nothing like the bright zap that follows,
and that contrast is the point: the wind-up should look like something gathering, not like the
attack. `HL_BEAM_ARC` casts no dynamic light at all, because up to eight are alive at once and a
light per arc would pulse a corridor brighter than the zap.

This port has no persistent per-limb beam, so `die 0.55` makes the four powerup events overlap
their own arcs instead — continuous rather than four blinks.

### A takedamage gate that made the flame do nothing, exactly as documented three patches ago

First measured run of the flame:

```
[firetest] monster_gargantua  dmg=87.0051  sched=garg_flame
[ai] slave-arcs=47  garg-flames: sweeps=5 ticks=222 hits=0
```

Five sweeps, 222 ticks of burning, **zero hits** — while the gargantua went on landing 87 damage
from its stomp. On the console that reads as "the flame does no damage". What it actually meant
is that `FlameDamage` was ported faithfully, including HL's `pev->takedamage != DAMAGE_NO`
filter, and **players in this mod sit at `DAMAGE_NO` permanently**. The filter excluded the only
target that mattered and nothing else.

`AI_BlastAttack` carries a comment about precisely this (`sv_ai_combat.qc:236-243`) — it is the
bug that meant the houndeye's sonic blast had never once hurt a player. Same trap, same shape,
one patch later. Gate removed; `W_ApplyDamage` asks `W_CanDamageTarget`, which is the authority.

```
[firetest] monster_gargantua  dmg=692.705  sched=garg_flame
[ai] slave-arcs=48  garg-flames: sweeps=4 ticks=179 hits=179
```

`hits == ticks` is the strongest available evidence: every tick of the burn reaches the target,
which is what a sustained flame is supposed to do.

### The firetest was reporting failures it had caused itself

While building `sv_ai_deathtest` (PATCH 137) the same "COULD NOT BE PLACED anywhere" appeared for
all eight subjects, and running `sv_ai_firetest` on the same map produced it for **all seven of
its own**. A `bot_minplayers` bot appears in `player_chain` within a second of map load and is
still standing at the **map origin** at that point, so the ring of candidate spots is measured
against a position in the void.

On the console that is indistinguishable from seven monsters that spawned fine and did not shoot
— the exact confusion the firetest exists to remove. Reproduced on `th_ep1_00` and
`pizza_ya_san1`; the runs where this test worked are the ones where the bot happened to have
moved first. `sv_ai_spawntest` documents the trap (`sv_ai_core.qc:2353-2366`) and was the only
one of the four harnesses that guarded against it.

The firetest now arms and waits five seconds before placing. Its roster gains
`monster_gargantua`, which belongs there by the roster's own rule: it is a shooter that was
caught not shooting.

### Verification

```
[firetest] monster_gargantua        dmg=692.705 state=2 sched=garg_flame
[firetest] monster_shocktrooper     dmg=720
[firetest] monster_human_torch_ally dmg=1088
[firetest] monster_human_medic_ally dmg=1054
[firetest] monster_hwgrunt          dmg=668
[firetest] monster_male_assassin    dmg=528
[firetest] monster_alien_slave      dmg=50
[firetest] monster_houndeye         dmg=27.0495
[ai] slave-arcs=48  garg-flames: sweeps=4 ticks=179 hits=179
```

All eight land damage. Five-map regression clean — 28 schedules built (was 27), `BAD=0` on all
five, errors 0, `crashaddr 1956 → 1956` — server and client at **0 warnings**.

### Owed in game

The look of both, and for the flame that is a larger owing than usual: the counters prove the
jet is traced, drawn, aimed by bone controllers and burning the right thing on every tick, but
nothing here can show whether a 330-unit orange beam with a blue core at scale 14 reads as fire
rather than as a wide laser. `reloadweapons` hot-reloads `particles/beams.cfg`, so tuning
`garg_flame`, `+garg_flame`, `++garg_flame` and `islave_arc` needs no rebuild.

---

## PATCH 139 — squads: the callout, the ration, and two ordering bugs the harness caught

The first half of item H. Half-Life's `CSquadMonster` had **no QC equivalent whatsoever**, and the
tell was a one-line grep: `COND_FRIEND_DAMAGED` (`sv_ai_defs.qc:268`) had exactly one reference
tree-wide — its own declaration.

Three behaviours fall out of the absence, and all three are things players notice without being
able to name:

- **grunts never call out**, so a squad discovers you one man at a time, in whatever order their
  individual sight cones happen to sweep across you;
- **grunts all fire at once**, because nothing rations who may engage;
- **houndeyes never form the pack**, so their blast ring is stuck on the solo colour — a piece of
  gameplay information that has been unreadable since it was written.

### A chain, not five handles

`m_hSquadMember[4]` plus the "`MySquadMember(4)` returns the leader" trick exists because the C++
side needed a fixed-size save/restore block. A QC entity chain has neither constraint, so the
leader is the **head of its own chain** and "walk the squad" is one loop with no special case.
The five-member cap is enforced on the way in instead, which is also what makes a room with nine
grunts form two squads rather than silently drop four of them.

Recruitment runs on a monster's **first waking tick**, not at spawn. That is structural, not a
preference: a monster built while the `.bsp` is still being parsed cannot see squadmates that
have not been spawned yet, so recruiting from `Monster_Build` would give the first entity in the
file an empty squad and every later one a squad of the wrong size. Half-Life has exactly this
shape — `SquadRecruit` runs from `StartMonster`, off the first think.

**Leadership is inherited, not disbanded.** Killing a leader promotes the first surviving member
and re-points everyone at it, including the slot bitfield. Dropping the squad instead would mean
that shooting the right grunt first silently turns the other three back into individuals — a
strange and invisible reward for an arbitrary choice.

### The callout is placed where a monster acquires an enemy *by looking*

`Squad_MakeEnemy` sits in `AI_GatherConditions`, at the one point in the tree where a monster
finds an enemy on its own. Deliberately **not** in `AI_Damaged`: being shot at needs no
announcement to be believable, and a squadmate handed an enemy by the callout must not
re-announce it or a four-man squad would broadcast sixteen times for one sighting.

It only tells members who are **not already engaged**, which is the part that makes it read as
communication rather than mind-reading: a grunt already shooting at you does not swap targets
because someone shouted, and a grunt staring at a wall turns round. It hands over
`ai_lastseenpos` as well as the enemy — `SquadCopyEnemyInfo`'s whole payload — because
`TASK_GET_PATH_LKP` fails outright when `ai_lastseen` is zero, so without it a called-out grunt
would hold an enemy it could never path to.

### `NoFriendlyFire` is a wedge, not a ray

Valve's own comment calls the plane maths a bugbug. It is kept anyway, and coarse on purpose:
the thing being avoided is a **spread**, and `AI_FireBullets` throws its rounds inside a cone, so
a shot that misses a squadmate down the centre line can still hit him with the edge of the group.

### Two ordering bugs, both found by the harnesses rather than by reading

**The slot ration did nothing at all.** `ScheduleChange` — hand the attack slot back — was wired
into `AI_SetSchedule`, which runs *after* `AI_SelectSchedule` has already asked for a slot. Every
grant was undone by the assignment that followed it. Half-Life has the same two steps in the
opposite order (`schedule.cpp:229`, `ScheduleChange()` then `GetSchedule()`).

What made it visible was that the wrong version looked healthy:

```
totals: squads=1 members=3 callouts=3 slots won=64 denied=0 ff-holds=192
grunt squad=4 leader=other slot=0 enemy=player sched=range_attack1
grunt squad=4 leader=self  slot=0 enemy=player sched=range_attack1
```

Sixty-four grants and not one refusal is not a ration — it is a counter being incremented by
something immediately thrown away, and `slot=0` on a grunt that is mid-attack is the proof. After
moving the vacate to all three re-selection sites:

```
grunt squad=4 leader=other slot=2 enemy=player sched=range_attack1
grunt squad=4 leader=other slot=1 enemy=player sched=range_attack1
```

Two attackers holding **distinct** engage bits, the other two held off.

**A self-test that depended on which map was loaded.** The squad self-test built its four bodies
at the world origin and called `Squad_Recruit`, which ends in a traceline between the two
monsters. It passed on `th_ep1_00` and `hl_c01_a1` and reported `BAD=6` on `th_ep1_01` and
`2fort` — not because squads were broken there, but because the world origin is inside solid
geometry on those two and the trace never arrived. A self-test whose result depends on the map is
worse than none, because it teaches the reader to ignore it. The structural half is built by hand
now; the recruitment filters get a separate check that asserts what must **not** happen (a late
arrival standing on top of an existing squad must come away with nobody), which needs no line of
sight.

### The houndeye pack colour finally says something

`CHoundeye::WriteBeamColor` (`houndeye.cpp:511-541`) picks the blast ring's colour from the squad
size, and this port has been stuck on the solo value since the ring was added. Valve's table is
not a smooth ramp and is reproduced rather than tidied — the step from 2 to 3 is the big one and
4 goes darker rather than bluer:

```
solo 188 220 255   |   2: 101 133 221   |   3: 67 85 255   |   4: 62 33 211
```

One deliberate divergence: HL's `default` case for a squad **bigger** than 4 falls back to the
*solo* colour with an `at_aiconsole` complaint, which would make a bigger pack look weaker than a
smaller one. Clamped to the four-strong colour instead.

### Which classes ration, and which do not

Slots are declared per family, exactly as `squadmonster.h:22-48` lays them out: hgrunt two engage,
alien grunt two hornet, houndeye three attack. Everything else has none — giving every monster
slots would make a pair of headcrabs take turns, which is not a behaviour Half-Life has.

The ranged attack is rationed and **melee is not**: all of HL's slots are ranged, because the
thing they exist to stop is a firing line. Melee already rations itself — only so many bodies fit
within arm's reach, and a squad that queued to punch you would just stand still.

A refused slot falls **through** to the rest of the ladder rather than returning `SCHED_NONE`,
which is the difference between a squad that takes turns and a squad where three of the four
freeze.

### `sv_ai_squadtest`, because none of the existing harnesses could reach this

The firetest, walktest and deathtest all spawn **one of each class**, and two of a kind within
1024 units with line of sight is the entire precondition for a squad. So the squad behaviours had
no test that could touch them. Four grunts, one player, twenty seconds:

```
[squadtest] grunt squad=4 leader=other slot=0 enemy=player sched=alert_stand
[squadtest] grunt squad=4 leader=self  slot=0 enemy=player sched=combat_face
[squadtest] grunt squad=4 leader=other slot=2 enemy=player sched=range_attack1
[squadtest] grunt squad=4 leader=other slot=1 enemy=player sched=range_attack1
[squadtest] totals: squads=1 members=3 callouts=3 slots won=64 denied=0 ff-holds=194
```

`callouts=3` is the headline: one grunt found the player and handed him to the other three.

**`denied=0` is a true reading and not a broken ration**, stated plainly because it looks like a
failure. `Squad_MayEngage` asks `NoFriendlyFire` first, matching HL's ordering, so in any
arrangement where four grunts face one target from one side the two without a clear line are
stopped by friendly fire and never reach the slot request. Widening the spawn arc from 25 to 40
degrees was an attempt to change that and did not work — the placement retry loop rejects most of
the wide angles as unstandable and lands the four in much the same bunch either way (`d=223..229`
both times, `ff-holds` 193 then 194). The attempt is recorded rather than reverted, because the
failed attempt is the finding. The ration is proven deterministically by the self-test (2 of 4
win a slot) and observably above by the two attackers holding distinct bits.

### Verification

Five-map regression clean, with the new self-test now part of it:

```
sched : schedules: 28 built, 116/384 tasks used, BAD=0
squad : squad accounting: BAD=0          <- the SPAWNER's child budget
sqmon : squad monsters: BAD=0            <- the squad a monster FIGHTS in
errors: 0        crashaddr: 1956 -> 1956
```

Those two lines are entirely different subjects sharing an unfortunate word, and
`Monster_Teardown` now calls both — a corpse left lying around must starve neither its spawner
nor its squadmates' attack slots. Server and client at **0 warnings**. A real 4-strong squad
forms unaided on `th_ep1_00`.

### Not in this pass

**Take-cover**, which is the other half of item H: no analogue of
`SCHED_TAKE_COVER_FROM_ENEMY`, `SCHED_COWER`, `TASK_FIND_COVER_FROM_ENEMY` or `FValidateCover`
exists yet, and `COND_BLOCKED` is still raised (`sv_ai_core.qc:1560`) and tested by nothing. The
plan sequences squad first precisely so that cover has `NoFriendlyFire` and `SquadMakeEnemy`
underneath it — without them, monsters breaking for cover reads as monsters wandering off.

`COND_FRIEND_DAMAGED` is now **raised** and propagated, but nothing consumes it yet: it is one of
cover's inputs, and wiring it into a selector before the cover schedules exist would only produce
a monster that reacts to a squadmate being shot by doing exactly what it was already doing.

### Owed in game

Whether the ration reads as coordination or as hesitation. The counters prove at most two of four
grunts engage at once and that the other two are doing something else; they cannot show whether a
squad that takes turns feels smarter than one that does not, and that is the one judgement this
whole item rests on. `sv_ai_squadtest 1` reproduces the arrangement on demand.

---

## PATCH 140 — take cover: the second half of item H, and a scheduling bug it exposed

Until this patch the entire vocabulary of a monster under fire was **chase, face, shoot, lob**.
Every one of those moves toward you or stands still. There was no way for a monster to decide
that where it is standing is a bad place to be, which is why sustained fire has always produced
the same picture: a queue of monsters walking into it.

### Two searches, in Half-Life's order, and they are different in kind

**Lateral is a sidestep** (`monsters.cpp:3146-3196`). Five 48-unit steps left and right in the
monster's own frame, alternating sides, nearest first. It is a **local move**: no pathfinder, no
nav graph, just a hull sweep — exactly as HL's `CheckLocalMove` is local. This is the one that
reads as ducking behind the crate you were already standing next to, and in practice it is the
one that fires most: 25 of 33 successes on `th_ep1_01`, 16 of 16 on one `2fort` placement.

Deliberately **not** a path request. `Nav_RequestPath` snaps both ends to the nearest node, and
over 48–240 units both ends usually snap to the *same* node — a one-node path that retires on
the first tick and a monster that never moves. `AI_MoveAlongPath` already walks straight at
`ai_goalpos` when it has no waypoints and the goal is inside `NAV_LINK_DIST`, so a sidestep
needs no route at all.

**Node is a relocation** (`monsters.cpp:2235-2330`). The nav graph already holds the candidate
positions, so cover is "a node that blocks the enemy's view of me" rather than any new spatial
structure — which is what the plan called for, and the whole reason this could follow squads
rather than needing a month of its own.

Two deliberate divergences. HL takes the **first** node its rotating scan accepts; this takes
the **nearest**, because a monster that sprints past three usable corners to reach a fourth
reads as a monster that has decided to leave — and the squad spacing rule is what stops four of
them choosing the same corner. And HL compares graph **path lengths** to insist the node is not
further from the monster than from the threat (`monsters.cpp:2303`), which it can afford with an
all-pairs table; straight-line distance stands in for it here. The test exists to stop a monster
running *through* its enemy to reach cover behind them, and for that the two agree everywhere
except inside a maze.

The gather is grid-first rather than HL's "scan all `m_cNodes` and rotate a global cursor",
because this graph is bigger than Valve's and the lookup grid already exists.

### The bug the harness found: a node qualifies as cover *because* the trace to it is blocked

`Cover_Hides` cannot tell "hidden behind that crate" from "on the other side of a wall with no
way round" — both are a blocked traceline. On `hl_c01_a1` **every** candidate it accepted was
the second kind: 49 confident node picks in twenty seconds and not one monster moved a unit.

Half-Life has this gate and it is easy to miss, because it is disguised as the action.
`FindCover`'s accept condition is

```cpp
if ( FValidateCover ( node.m_vecOrigin ) && MoveToLocation( ACT_RUN, 0, node.m_vecOrigin ) )
```

and `MoveToLocation` is what **builds the route** — so a node with no route fails the test and
the loop moves on to the next candidate rather than failing the whole search. `Nav_FindPathNodes`
is the same synchronous A* the request queue uses, driven directly on two node indices; safe to
call from a think because a queued search runs to completion inside one `Nav_Think`, so the two
can never interleave over the shared open set. Bounded at four per search, and only reached by
candidates that have already passed every cheaper test. `noroute` counts the rejections — 8 on
one `th_ep1_01` run.

Also added: if `Nav_NearestNode(m.origin)` is -1 the monster is not on the graph at all, so node
cover is not available to it. Say so once, cheaply, rather than discovering it per candidate.

### A failed task now outranks the class virtual

This is Half-Life's own structure and this mod had it backwards. `MaintainSchedule`
(`schedule.cpp:238-259`) tests `bits_COND_TASK_FAILED` and runs the fail schedule; the call to
`GetSchedule` — the class virtual — is the **else** of that branch. The two are mutually
exclusive and failure wins.

Here the virtual was asked first, which made the fail branch unreachable for any monster whose
class had an opinion. It was latent for as long as the virtuals were narrow: the grenade sits
behind an attack cooldown, the gargantua's flame behind a six-second one, and the turret and
barnacle state machines almost never fail a task. Cover is the first virtual that answers on
*every* damaged tick, so it collided immediately, and the symptom said nothing about ordering:

```
sched=186 arrived=0 tries=17 ... cower=12
monster_human_grunt moved=0 was-visible=yes now=visible sched=take_cover
```

Cover chosen 186 times, the search reached 17 times, and not one monster moved. `COND_TASK_FAILED`
was set, nothing could clear it because `SCHED_COVER_FAILED` — the only schedule that clears it —
could never be selected, and `take_cover`'s own interrupt mask contains it, so every selection was
thrown away 0.2 s later by the condition that selected it. After the fix, 53 selections and 53
searches: 1:1.

The scripted_sequence branch stays above it. HL puts task-failed above everything, but
`Script_Schedule` has its own retry-and-release handling and letting a failed task pull a monster
out of a cutscene would undo it.

### The interrupt mask is the design, and it is deliberately tiny

HL's is a single bit. Every obvious addition destroys the schedule: `COND_DAMAGE` aborts the run
to cover at the first round that lands — the one moment cover is *for* — and `COND_ATTACK_READY`
stops the monster halfway to shoot from the open. Either produces a monster that visibly sets off
somewhere and then does not go, which reads worse than never having moved. `AI_CoverSelfTest`
asserts both, because neither would ever produce an error.

The 0.2 s wait before the search is HL's and is not a rounding error: it is the beat that makes
the break for cover look like a decision rather than a reflex.

`SCHED_FLEE_ENEMY` is a different thing and stays. Fleeing is for a monster with no attack at all
and ends in `TASK_FORGET_ENEMY` — the cockroach runs away and stops caring. Cover ends in
`TASK_FACE_ENEMY`: this monster is still in the fight and is repositioning inside it.

### Which classes take cover, and the two that turn out not to

Seven HL classes reference `SCHED_TAKE_COVER_FROM_ENEMY`. Only **five** of them can actually
reach it: `CBaseMonster::GetSchedule` never returns it (only `SCHED_TAKE_COVER_FROM_ORIGIN`, in
the ALERT state on a danger sound), so **agrunt and controller have a `GetScheduleOfType` case
for a trigger that does not fire**. Nothing to port for either.

| class | trigger | source |
|---|---|---|
| hgrunt family | light damage, 90 % cover / 10 % flinch | `hgrunt.cpp:2100-2124` |
| hgrunt family | blocked **and** hurt → `SCHED_COWER` | `hgrunt.cpp:1571` |
| hgrunt family | a squadmate was hit and I am not the leader | stand-in, see below |
| alien slave | hurt, **or seen while being looked at** — below 20 HP | `islave.cpp:678-691` |
| barney / otis | heavy damage only | `barney.cpp:720` |
| houndeye | hurt, either weight | `houndeye.cpp:1272-1288` |
| hassassin | `bits_COND_NEW_ENEMY` — **not ported**, no such condition here | `hassassin.cpp:947` |

The grunt's squadmate rule is stated as a **stand-in rather than a port**: HL's trigger is
`bits_COND_NEW_ENEMY` on a squad member that is not the leader, and this mod has no such
condition. What it does have is `COND_FRIEND_DAMAGED`, which the squad work raised for the first
time last patch and which nothing consumed — and "the man beside me was just hit and I did not
find this fight myself" lands in almost exactly the place Valve's condition does.

**`COND_BLOCKED` finally has a reader.** It has been raised at the movement failure since the AI
landed and tested by nothing at all. Cower is where it lands, and the pairing with damage is
deliberate: a grunt merely wedged on a doorframe should keep trying to walk; one wedged on a
doorframe *under fire* has run out of options, which is what the animation depicts.

**`COND_ENEMY_FACING_ME` likewise** — declared since the AI landed, referenced only by its own
declaration, and the alien slave is the one class in the SDK that uses it. Raised only *with*
sight: whether a thing is looking at you is a question you can only ask about something you can
see, and deriving it from angles alone would let a monster through a wall know it was being aimed
at. It costs no trace, since the sight test already paid for one. The player case reads `v_angle`
rather than entity yaw, or every player would appear to face wherever their model was turned.

### `ACT_COWER` exists on exactly the five rigs that need it

Censused before implementing, the same way item G's death activities were: `ACT_COWER` is carried
by `hgrunt`, `hgrunt_medic`, `hgrunt_opfor`, `hgrunt_torch` and `massn` — **and by nothing else in
the corpus**. Half-Life reaches `SCHED_COWER` from exactly one place in the whole SDK, the
hgrunt's take-cover-from-best-sound fail schedule. The two facts agree, which is why this is a
real schedule rather than decoration: Valve only ever cowers a grunt, and only grunts were ever
animated for it. `cower` is 61 frames at 28 fps, non-looping, so `TASK_PLAY_SEQUENCE` is the right
task.

### The islave gate the firetest caught in one number

The first version of the slave's trigger missed the guard that wraps *both* of HL's cover
branches: `if (pev->health < 20 || m_iBravery < 0)` (`islave.cpp:678`) — out of 60 starting
health, so the last third. A slave that breaks for cover whenever it is *looked at* breaks for
cover permanently, because a player in a fight is looking at it.

The firetest said so immediately, and this is exactly what that harness is for: the slave's damage
to the player fell from the **50** recorded in PATCH 138 to **10**, while every other class on the
roster held its figure. With the gate restored it is 50 again.

```
                        before      broken     fixed
monster_alien_slave        50          10        50
monster_human_torch_ally 1088        1088      1088
monster_human_medic_ally 1054        1054      1054
monster_gargantua      692.7       654.2     657.2
monster_houndeye        27.05       27.19     27.19
```

The bravery half is **not** implemented and that is recorded rather than glossed: it counts
visible slaves, plus one per living and minus one per dead (`islave.cpp:488-500`), and this mod
unlinks a corpse from `monster_chain` in `Monster_Teardown`, so "how many of my kind are lying
dead near me" is not a question the chain can answer. The health term is the dominant one.

### `sv_ai_covertest`, and three ways it lied before it worked

The five-map regression **structurally cannot reach cover**: nothing in it ever damages a monster,
so the whole system reports `sched=0 tries=0` and reads exactly like code that is not there. Four
monsters with four different triggers, one player, and a round every half second for twenty
seconds.

The headline is `score`, not `sched`. A monster that selects cover forty times and is still
standing in the open has not taken cover, it has dithered — so each subject's line of sight to the
player is traced at the end and compared with the same trace at spawn.

```
[covertest] monster_human_grunt    moved=133 was-visible=yes now=HIDDEN sched=take_cover
[covertest] monster_alien_slave    moved=95  was-visible=yes now=HIDDEN sched=take_cover
[covertest] score: 4 of 4 started exposed, 3 of those are now hidden
[covertest] totals: sched=41 arrived=40 tries=41 lateral=37 node=1
```

Three corrections were needed before that number meant anything, and all three are the same
mistake in different clothes — a harness reporting success for a subject that did nothing:

1. **Subjects that were never exposed.** The first version took any standable spot; on
   `th_ep1_01` three of four spawned already out of sight, and `now=HIDDEN` for a monster that was
   never visible is not evidence. Placement now requires the player to be able to see the subject.
2. **Subjects that could not move.** `FL_MONSTER` means "this body fits here", which is weaker
   than "this body can walk from here". Placement now probes four directions with the same hull
   sweep the cover search uses.
3. **A player who never spawned.** This is the trap `sv_ai_spawntest` documents, and the
   deathtest's guard — the player's distance to the nearest nav node against `NAV_LINK_DIST * 2`,
   i.e. 4608 units — is far too loose to catch it. On `hl_c01_a1` the bot sits at `'0 0 37'` for
   the whole run with nodes well inside 4608, so the guard passes and the harness reports
   `sched=49 node=48 arrived=0` with every subject at `moved=0`: a perfect picture of broken
   cover, produced entirely by where the bot was standing. **"Did the player move in five
   seconds"** needs no map knowledge and no threshold to tune, and it turns that into one line:

   ```
   [covertest] "Maverick" has not moved from 0 0 37 in five seconds -
               it never spawned properly, refusing to measure anything
   ```

   The player position was never printed and had to be recovered from the subjects' own
   coordinates, which is a good enough reason to print it.

A fourth correction is a measurement bug rather than a lie. The pulse gap was two seconds, and
`COND_DAMAGE` lives for a moment — raised when the round lands, cleared by the next flinch or by
the selector when the flinch cooldown is running. Selection only happens at schedule boundaries,
so whether cover was ever *chosen* came down to the phase relationship between the pulses and
those boundaries: two consecutive `2fort` runs reported `sched=28` and `sched=2`. At half a second
the same placement reports the same number twice, and sustained fire is the honest scenario
anyway — cover is not for one round every two seconds.

The walktest was the control that proved `hl_c01_a1` itself was fine: a grunt moved 956 units on
the same map while the covertest's four subjects sat at zero.

### Where cover does not fire, and why that is the right answer

The counters are split by cause because "cover was rarely chosen" has three different responses:

```
[covertest] totals: asked=14 sched=4 floor=10 nodmg=4
[covertest] totals: none=4 refused=0 capped=0 noroute=0
```

On that `2fort` placement every search genuinely found nowhere (`none=4`) and the retry floor then
correctly suppressed re-searching (`floor=10`). That is the system working: a monster standing in
an open room under fire would otherwise run a full gather plus a dozen tracelines ten times a
second for the length of the fight. HL needs no such floor because its all-pairs table makes the
search cheap; this is a stated divergence with a counter attached.

`pizza_ya_san1` reports `none=19 lateral=0 node=0` — a large open room with 50 nodes has no cover
near the player, and the honest answer is to say so rather than invent somewhere.

### Verification

Five-map regression clean, with the new self-test in it:

```
sched : schedules: 31 built, 132/384 tasks used, BAD=0
squad : squad accounting: BAD=0
sqmon : squad monsters: BAD=0
cover : cover: BAD=0
errors: 0        crashaddr: 1956 -> 1956
```

Server at **0 warnings**; no client-side change in this patch. The firetest's eight shooters all
still land damage.

`AI_CoverSelfTest` is geometry-independent **by construction** — the lesson from the squad
self-test, whose first version called `Squad_Recruit` and so reported `BAD=6` on the two maps
whose world origin is inside solid. Nothing in it fires a trace: spacing, the guard rail, the
facing test and the schedule shapes are all arithmetic. It also found a bug in its own wiring —
the schedule-shape half has to run from `AI_Init`, because the `AI_Tick` self-tests do not run
after `AI_SchedBuildAll` in the order the log actually shows. **Nothing that reads `sched_*` may
run from `AI_Tick`; nothing that spawns may run from `AI_Init`.**

### Not in this pass

`SCHED_TAKE_COVER_FROM_BEST_SOUND` and `SCHED_TAKE_COVER_FROM_ORIGIN`, because both are driven by
HL's **danger-sound** system, which has no equivalent here — `CSound`, `PBestSound` and
`bits_SOUND_DANGER` are a whole subsystem, and it is what a thrown grenade uses to make everyone
nearby scatter. That is the natural next piece and it would give `SCHED_COWER` its original HL
trigger back rather than the stand-in it has.

`bits_MEMORY_INCOVER` is deliberately **not** ported. Nine schedules in Half-Life set it and
nothing anywhere reads it — the same write-only shape `COND_FRIEND_DAMAGED` had here before last
patch, and worth naming so nobody ports it out of a sense of completeness.

The houndeye's `SCHED_HOUND_HOP_RETREAT` — a scripted backward leap taken 40 % of the time when a
128-unit hull trace behind it is clear — is not ported. It is built on `TASK_HOUND_HOP_BACK` and
belongs with that class's movement rather than with the cover mechanism, but the two behaviours
look quite different in play.

The retry floor is a blunt three seconds and does not reset when the monster moves, even though
moving is exactly what changes the answer.

### Owed in game

Whether a monster breaking for cover reads as tactics or as running away. The counters prove it
picks somewhere the player cannot see it and gets there — `4 of 4 exposed, 3 now hidden` — but
not whether the 0.2 s beat before it moves lands as hesitation, whether a grunt ducking behind a
crate and leaning back out is legible at all, or whether the 90/10 split between covering and
flinching is the right ratio at this mod's rate of fire. `sv_ai_covertest 1` reproduces the
arrangement on demand.

Both halves of item H are now in, which closes the last item on the round-5 plan.

---

## PATCH 141 — the pickup gap was ammo, not weapons, and the reserve bank had never run

The round opened with an audit that produced the opposite of the expected answer. The docs said
the weapon port was the unfinished part; the measurement said **the base Half-Life arsenal was
already complete, 14 of 14**, and that the hole was ammo — 68% of ammo placements resolved
against 90% of weapon placements. The single biggest missing pickup in all of Half-Life was
`ammo_9mmAR` at **294 placements**, which is Half-Life's own second classname for
`ammo_mp5clip`. That one had worked since the beginning. The alias was one line.

Two census numbers were wrong when first produced, both in the direction of false confidence:

- **Blue Shift reported 0 weapons across 37 maps.** Blue Shift BSPs swap lumps 0 and 1, so
  reading lump 0 as the entity lump yields plane data, which parses to nothing without error.
  The real figure is 120 placements. `scratchpad/wpnresolve.py` now picks whichever lump
  actually begins with `{`, and scores placements against the spawn functions that exist in the
  tree rather than only counting them.
- **Every world-model path guessed from a classname was wrong, three for three.** The barnacle
  grapple is `w_bgrap.mdl`, not `w_grapple.mdl`; the 5.56 box is `w_saw_clip.mdl`, not
  `w_556ammobox.mdl`; the 7.62 box is `w_m40a1clip.mdl`. **The Sven FGD is the authority**
  (`svencoop/sven-coop.fgd`) and names the model for every classname. Do not guess these.

Final state: **4008 of 4008 weapon and ammo placements resolve, 100%**, across valve, gearbox and
Blue Shift — 43 distinct classnames, each confirmed to have a real spawn function rather than a
regex match. Gearbox moved 62% → 100%. The 22-map headless sweep, which uses the engine's own
`SV_OnEntityNoSpawnFunction` rather than a grep, went from 48 distinct unhandled classnames to
32, and **not one `weapon_*` or `ammo_*` name remains in it.** What is left is entity logic:
`point_checkpoint`, `gibshooter`, `env_glow`, `func_healthcharger`, the vehicle classes.

### The defect that a careful reading had missed for the whole life of the file

Two ammo defects were known going in, both found by reading. The instruction was to reproduce
them headlessly before fixing anything, and doing so turned up a third that neither the reading
nor the two known bugs covered:

**`Ammo_GiveToCarried` topped up any pool below its cap without ever checking whether the player
carried the matching weapon.** A player carrying nothing has every pool at zero, so the condition
was always true, the give always reported success, the pickup was always consumed — and the
reserve bank underneath, the entire point of `sv_goldsrc_ammo.qc`, was never written. **The
headline feature of the file had never once executed.** It is invisible to a static read because
every individual line is correct; the bug is that the guard which would have made the bank
reachable was never there to be read.

Fixed with `Ammo_PlayerHas`, which asks the four slot fields directly, and a data-driven
`Ammo_TopUpWeapon` replacing the hand-written per-calibre branches — the branch shape is what let
a missing consumer hide, since the Egon's uranium was landing in `.ammo_gauss`, a field the Egon
does not read (defect 1).

**A fourth gap fell straight out of the fix**, and it is the more interesting one. With the bank
finally reachable, banked rounds were stranded there forever: the drain ran only at weapon
pickup, and map weapons spawn *full*, so the one moment the drain executed was the one moment it
could never do anything. `Ammo_TickDrain` now runs once a second from `W_WeaponFrame`.

Fixing that then broke the fix — `Ammo_DrainForWeapon` was called *before* the block that sets
`player.slot_primary`, so the new carries-check correctly saw a player who did not yet carry the
weapon they were in the act of picking up. The call moved after slot registration, and the
ordering is now commented as load-bearing at that site.

### The alias trap: delegate-then-setmodel reverts on the first round restart

The obvious way to give an aliased weapon its original world model is to call the base spawn
function and then `setmodel` over it. **This is wrong, and it fails silently until a round
restarts.** `W_RegisterMapWeapon` stores the function pointer it is *handed* in
`.map_weapon_spawn`, and `W_RespawnMapWeapons` re-calls it (`sv_weapons.qc:595-597`) — a base
spawn function passes *itself*, so the stock model comes back and stays back. Two further
reasons the naive shape is wrong: the `droptofloor` inside registration runs against the old
model's hull, and re-registering re-enters `W_PhysDropStart` in the same frame under the default
`sv_phys_drops 1`.

All 13 aliases are therefore standalone spawn functions ending in
`W_RegisterMapWeapon(<the alias itself>)`. This invalidated a code shape that had already been
shown as a preview, which is the cost of finding it late.

`sv_wpnalias_test` re-runs every map weapon's *stored* pointer **twice** and compares the two
results, which is the only comparison that proves the pointer is stable rather than merely that
the first spawn looked right.

### Four bugs were found by distrusting a number, not by reading code

Worth recording as a group, because every one of them first presented as a pass or a clean zero:

- `sv_wpnalias_test` ran on frame 1 and reported `map weapons=0`.
- Every model then came back **empty**, because `cfg/server.cfg:49` sets `mp_nomapweapons "1"`
  and map weapons spawn with `setmodel(self, "")`. The test now forces the cvar off and restores
  it.
- The first before/after comparison labelled everything REVERTED when what it had actually
  measured was hidden→visible.
- And in this patch's own final run, the harness reported **zero `[ammotest]` lines on every
  map** — not a failure, just silence. `W_AmmoSelfTest` walks `player_chain_head` and returns at
  its first guard when no player exists; the invocation had omitted `bot_minplayers 1`. A test
  that cannot run looks identical to a test with nothing to report unless it says so.

The same run also named a map `op4_of1a1`; the real basename is `of1a1`. FTE segfaults inside its
own "Couldn't load a map" error path rather than exiting, which charged 17 lines to
`crashaddr.txt` — engine behaviour on a bad map name, not a fault in this patch.

### Four weapons implemented rather than aliased

The design pass reshaped three of the four away from what the plan assumed, in each case because
the mod already contained most of the answer:

- **The grapple** was budgeted as the highest-risk item — rope physics the mod does not have.
  `server/sv_grapple.qc` already had all of it: rope, prediction, CSQC rendering. `weapon_grapple`
  is a deliberately thin shell over `W_GrappleEngage`/`W_GrappleRelease`.
- **The shock rifle** reuses `HL_BEAM_SHOCK`, which already existed for the shocktrooper, so it
  inherited its entire visual. It self-recharges, which sidesteps the ammo layer completely.
- **`w_shock_rifle.mdl` is the shockroach creature, not the pickup.** The pickup is `w_shock.mdl`.
  The basename recorded from the FGD was the wrong one of the two.
- **The displacer's teleport refuses and refunds** on maps with no `info_displacer_*_target`. The
  tempting fallback is `PlayerPlaceAtSpawnPoint`, which lands the player at `'0 0 1'` — outside
  the world. Campaign maps do not contain those targets, so this path is the common case, not the
  edge case.

The **jetpack writes `.gravity` from shared predicted code**, because that field is read by
`sh_pmove.qc` and replicated by nothing. Constants are expressed per-second and scaled by
`frametime`/`input_timelength` so both sides agree. If it still drifts in play, the fallback is a
two-line addition to the prediction proxy. `JET_MAX_RISE 400` is a deliberate divergence from the
AngelScript, which has no rise cap.

### Counters

Five-map regression (`/c/tmp/regress.sh`): schedules `31 built, 132/384 tasks used, BAD=0`,
squad accounting BAD=0, squad monsters BAD=0, cover BAD=0, **errors 0 on all five**, and
**`crashaddr.txt` 1956 → 1956**. A later run took it to 1973 purely on the bad map name above; a
clean six-map pass then held it at **1973 → 1973**.

`sv_ammo_selftest` — all four stages PASS, `BAD=0`, on every map that ran it:

```
[ammotest] 1 egon uranium:    want=30 got=30 (gauss field got 0)      PASS
[ammotest] 2 carried-not-held: want=60 got=60 slot=60                 PASS
[ammotest] 3 no-gun banks:    want=6  got=6  (leaked to ammo_357=0)   PASS
[ammotest] 4 stranded bank:   kept-while-full=6 want=18 got=18 bank=0 PASS
```

`sv_wpnalias_test` — `BAD=0` on all six maps, with the overridden models observed directly after
two consecutive respawns of the *stored* pointer: `w_pipe_wrench.mdl`, `w_1911.mdl`, `w_m14.mdl`,
`w_dbarrel.mdl`, `w_spanner.mdl`, `w_tommygun.mdl`, `w_greasegun.mdl`, plus the two new weapons
`w_bgrap.mdl` and `pizza_ya_san/w_glock18jet.mdl`.

**Every map reports `weapon_*` one higher than `registered`** (28/27, 14/13, 6/5, 2/1). That is
not an unregistered map weapon: `pizza_ya_san2` reads 13/13 with no bot and 14/13 with one, so
the extra entity is the bot's own carried weapon, which correctly has no `map_weapon_spawn`.
Recorded here because the gap looks like a defect and will be re-noticed.

### What is deliberately not done

**Only the world model is overridden on aliased weapons — the view and hand models stay stock.**
This is a real limitation and the accepted cost of the alias approach. It is not cheaply fixable:
the world model is networked as a string (`dropped_weapon_SendEntity`, `sv_player.qc:2059`) and
applied client-side, so it can vary per entity, whereas the view and hand models are chosen from
the WEP id and would need a client-side id→model table that does not exist.

`weapon_glock` still gives the CS Glock 18 rather than Half-Life's 9mm, which that classname
aliases in HL. Three valve placements want the 9mm; the whole CS corpus legitimately wants the
Glock 18 under that name. Documented rather than changed.

Sven's `weapon_uzi` and `weapon_m16` have no spawn function. Neither appears in any
valve/gearbox/bshift map. They Hunger's `weapon_m16a1` is a different classname and does resolve.

### Owed in game

Nothing in this patch's verification can see any of these.

- **That the overridden world models actually look right on the floor.** Sven ships HD
  replacements at several of the same paths (`w_saw` 53 KB vs 287 KB, `w_egon` 6 KB vs 95 KB) and
  whichever mount wins the search order changes both the visual and the bounds.
- **The jetpack's feel under prediction** — the one thing the shared-code approach was chosen to
  protect, and the one thing a headless run cannot measure.
- **The displacer's teleport on real campaign maps**, where refuse-and-refund is the expected
  outcome rather than the exception. Whether that reads as a broken weapon or as a weapon with a
  prerequisite is a judgement about play.
- **Whether the grapple is usable at all.** It inherits a rope built for a different weapon and
  has never been driven from a player's hands at this one's rate of fire.
- `w_penguin.mdl`/`w_penguinnest.mdl` exist only in the gearbox mount, so the penguin alias
  depends on Half-Life being mounted in a way the They Hunger models do not.

---

## PATCH 142 — the weapons were there all along, and the crates were not

Reported from play rather than from a counter: on the Sven `hl_` campaign maps, shotgun and
grenade pickups were missing while their ammo boxes sat there untouched, and breaking a crate
produced debris and nothing else. Both are real, both are one layer below where PATCH 141 was
looking, and the first of them had been sitting in front of that patch's own test output.

### `mp_nomapweapons` shipped as 1, and that strips weapons but not ammo

`cfg/server.cfg` shipped `mp_nomapweapons "1"`. The gamemode block sets that cvar in exactly two
branches — paintgun and prophunt, both of which genuinely want it, since the whole point is that
nobody arms themselves mid-round. **Every other mode inherited the config default**, so TDM on a
Half-Life campaign map stripped all of it.

The asymmetry the report describes is the giveaway, and it is structural rather than incidental.
Weapons register through `W_RegisterMapWeapon`, whose hide path does `setmodel(self, "")` plus
`SOLID_NOT` (`sv_weapons.qc:446`). Ammo spawns through `GoldSrc_SpawnPickup`, which never
consults the cvar at all. So the flag removes every gun a map places and leaves every ammo box
exactly where it was — which is 165 weapons against 292 ammo pickups across the 36 `hl_` maps.
Not "shotgun and grenades are missing": *all* of them were, and those two just have the highest
placement counts (`weapon_handgrenade` 49, `weapon_satchel` 32, `weapon_tripmine` 22,
`weapon_shotgun` 12).

Default is now `"0"`. Two notes on the change:

- **PATCH 141 hit this and wrote it up as a harness nuisance.** `sv_wpnalias_test` read every map
  weapon as having an empty model, the cause was diagnosed correctly as this exact cvar, and the
  fix was to force it off *inside the test* and restore it afterwards. The harness was made to
  see past the bug instead of reporting it. A test that has to disable a shipped setting to see
  anything is evidence about the shipped setting.
- **Every gamemode branch now sets the cvar explicitly**, including the ones that want it off.
  Paintgun and prophunt turned it on and never turned it off again; while the default was `"1"`
  that latch was invisible, because leaving prophunt for TDM landed on the value TDM would have
  had anyway. With the default flipped, the same latch would have stripped every mode entered
  after a prophunt round until the next map load. The bug predates this patch; flipping the
  default is what would have made it visible.

### `spawnobject` — 202 crates on the `hl_` maps that dropped nothing

GoldSrc's `func_breakable` carries a `spawnobject` key: an index into a fixed pickup table,
dropped at the brush centre when it breaks. This mod parsed the key and discarded it, and
`sv_func_pushable.qc:64` said why — the listed keys "need systems this mod does not have
(... item spawning ...)".

That was true when written. It stopped being true in PATCH 141, which gave all 39 table entries a
spawn function. `Breakable_SpawnObject` is now a straight dispatch.

Three things about the wiring are load-bearing and none were obvious:

- **The field had to move.** It was `.string spawnobject` declared in `sv_func_pushable.qc`
  (position 151), but `sv_breakable.qc` reads it at position 28, and **QC can forward-declare
  functions but not fields**. It is now `.float` — the FGD types it as choices, so the engine
  converts `"17"` to `17` on parse — and lives in `sv_customdefs.qc` at position 15.
- **The dispatch had to go last.** It calls every weapon, ammo and item spawn function in the
  tree, which are spread from position 42 to 228, so it sits at the end of `sv_goldsrc_ammo.qc`
  (232) and is forward-declared back to the breakable.
- **The spawn call had to move to the end of `func_breakable_break`.** The item is
  `MOVETYPE_TOSS` and is created inside the volume the crate occupied, so creating it before
  `self.solid = SOLID_NOT` starts it embedded in a solid brush.

A crate drop also explicitly clears `.map_weapon`/`.map_weapon_spawn`. `W_RegisterMapWeapon`
stamps those on the way through, and `W_RespawnMapWeapons` re-runs the stored spawn function for
anything carrying them — so leaving them set would hand the map a free weapon every round
restart, next to the crate that the breakable round-reset has just restored intact. Cleared, the
same function removes the drop at restart, which is what a dropped item should do.

### Two more harnesses that lied, in the same two shapes as last patch

`sv_breakobj_test` drives the real break path rather than calling the dispatch directly, because
most of what can break here is in the wiring. It was wrong twice before it was right:

- **`findradius` shreds `.chain`.** The worklist of crates was threaded through `.chain`, and
  `func_breakable_break` runs a `findradius` to wake phys-drops resting on the brush — which
  rewrites `.chain` on every entity it touches. The walk lost its list on the first break and
  wandered into whatever `findradius` had linked up. It reported `broke=3` out of 15 crates, and
  a `spawnobject=0` entry that was never in the list. The list now uses its own field.
- **The counter could not see what it was counting.** With the list fixed, ammo and health drops
  still reported "produced NOTHING" while weapons passed. `GoldSrc_SpawnPickup` sets model, size,
  solid and touch — but **not `.classname`**, because a map-placed pickup gets its classname from
  the entity lump and there had never been a synthetic one. The items were spawning correctly and
  were invisible to a classname-based count. Fixed on both sides: the dispatch now sets the
  classname (so crate drops are consistent with map-placed pickups and `W_RespawnMapWeapons` can
  see them), and the harness stopped being wrong about it.

- **And once it was passing, it started failing for a third reason.** `th_escape` reported
  `nomodel=16` — sixteen pickups spawned invisible — on a map where only three crates fired. The
  model check was walking *every* pickup-ish entity rather than the ones the breaks created:
  twelve were `item_inventory`, an unimplemented Sven class caught by the `item_` prefix, and
  four were entities that merely carry a `weapon` **key** in the entity lump, which the engine
  parses straight into the declared `.weapon` field. The check now marks everything that predates
  the break loop and looks only at what appears after it. The `+N` delta counts were never
  affected, because a false positive present both before and after cancels.

That is seven harness defects across two patches, every one of which first presented as a pass or
a clean zero. The pattern is now specific enough to name: **a count that comes back suspiciously
low, suspiciously round, or suspiciously high is a bug in the counter until proven otherwise** —
and the third of those is the one that nearly shipped a false bug report rather than a false
all-clear.

### Counters

Five-map regression: all BAD=0, errors 0, **`crashaddr.txt` 1973 → 1973** (the 1956 → 1973 step
was a bad map name in PATCH 141's own test script, not a fault in either patch).

`sv_breakobj_test`, after the three harness fixes — **68 keyed crates, 68 pickups, BAD=0**:

```
th_escape   crates=274 keyed= 3 broke= 3 pickups 470->473 (+ 3) nomodel=0 leaked=0 BAD=0
hl_c11_a4   crates= 63 keyed=15 broke=15 pickups 128->143 (+15) nomodel=0 leaked=0 BAD=0
hl_c06      crates=107 keyed=25 broke=25 pickups 143->168 (+25) nomodel=0 leaked=0 BAD=0
hl_c08_a2   crates= 91 keyed=22 broke=22 pickups 116->138 (+22) nomodel=0 leaked=0 BAD=0
of1a1       crates= 64 keyed= 3 broke= 3 pickups   6->  9 (+ 3) nomodel=0 leaked=0 BAD=0
```

`sv_ammo_selftest` BAD=0 and `sv_wpnalias_test` BAD=0 on all five self-test maps. The alias test's
`weapon_*` count now runs 3 ahead of `registered` rather than 1, because with map weapons no
longer stripped the bot carries a full loadout instead of a single gun.

### Four Sven guns, and a fourth wrong model basename

`weapon_m16` (32), `weapon_uzi` (23), `weapon_uziakimbo` (11) and `weapon_minigun` (4) had no
spawn function. Aliased to `WEP_HLSMG`, `WEP_CFMAC10`, `WEP_CFELITE` and `WEP_M249` respectively,
each with its own world model.

`weapon_uziakimbo`'s model is **`w_2uzis.mdl`**, not the `w_uziakimbo.mdl` its classname suggests
— the fourth basename this round that was wrong when guessed and right when read out of the FGD.
And note `weapon_m16` (Sven, `models/w_m16.mdl`) is a different file from `weapon_m16a1`
(They Hunger, `models/hunger/weapons/m16a1/w_m16.mdl`): same basename, two guns.

The minigun is the weakest match of the four and is recorded as such — Sven's is a spin-up heavy
weapon that slows the carrier, and the M249 has neither the spin-up nor the movement penalty. At
4 placements that beats building a new weapon.

### Correction to PATCH 141's headline number

PATCH 141 reported **4008/4008, 100%** and named its scope as valve, gearbox and Blue Shift. That
figure is accurate as stated and was measured correctly, but the scope was too narrow to support
the impression it gave: **the 108-map svencoop corpus is a fourth corpus and was never in it**,
and it was sitting at 98% with the four classnames above unresolved. It is also the corpus these
`hl_` maps belong to — so the patch that declared the pickup gap closed had not measured the maps
the gap was reported on.

With this patch, all four corpora:

| corpus | maps | placements | resolve |
|---|---|---|---|
| valve | 125 | 1763 | 100% |
| gearbox | 68 | 2125 | 100% |
| bshift | 37 | 120 | 100% |
| svencoop | 108 | 3186 | 100% |
| **total** | **338** | **7194** | **100%** |

---

## PATCH 143 — the satchel detonator, and an F5 weapon bench

Two requests from play: a debug menu to swap weapons, and "I picked up a satchel and threw it,
but it doesn't detonate with +attack".

### The Half-Life SDK is on this machine, and not reading it cost a decision

**The full HL SDK is at `C:\msys64\home\Lex\halflife\dlls\`** — `satchel.cpp`, `weapons.h`,
`multiplay_gamerules.cpp`, all of it. The standing assumption in these notes has been that only
They Hunger's AngelScript is available and that HL behaviour must be inferred; that is wrong for
base Half-Life, and it should have been checked before this round rather than during it.

The cost was concrete. This patch was scoped on the claim that HL's primary fire detonates live
satchels, and the user picked an option on that basis. The source says the opposite:

```c
void CSatchel::PrimaryAttack()                 // satchel.cpp:351
{ if( m_chargeReady != 2 ) { Throw(); } }      // ALWAYS throws, never detonates

void CSatchel::SecondaryAttack( void )         // satchel.cpp:361
{ if ( m_chargeReady == 1 ) { ...detonate every owned monster_satchel... } }
```

**The mod already matched Half-Life exactly**, and the existing comments citing
`satchel.cpp:353` / `:360` were correct all along. There was no parity to restore, and the
decision had to be re-taken with the real behaviour on the table. Grep the SDK before asserting
what Half-Life does.

### What was actually broken

The mapping was right; three things around it were not.

**The detonator was predicted off the wrong button.** `sh_wpn_hlsatchel.qc:444` tested
`input_buttons & 2`, which is `PM_BTN_JUMP` (`sh_pmove.qc:42`). `+attack2` is bit 4. So the
server detonated and the client played no radio animation at all, while `+jump` predicted a
detonation the server never performed. That is the single biggest reason the weapon read as a
dead key. The identical one-character defect existed in `sh_wpn_hlhornetgun.qc:501` and
`sh_wpn_svjetpack.qc:388` — the jetpack's being the worst of the three, because `SH_JetThrust`
mutates `.velocity`, so jumping applied predicted thrust the server never applied.

**The weapon disowned itself.** `W_UtilityPlayerHasWeapon(WEP_SATCHEL)` was `ammo_satchel > 0`,
so throwing your last charge meant you no longer owned a satchel: `W_SelectWeapon` refused it
(`sv_weapons.qc:3055-3059`), impulse-4 skipped it, `W_UtilityRefreshSlotBinding` reassigned the
slot away — and since the deployed charge has no fuse and nothing else can detonate it, **the
charges were stranded on the map until it changed.** HL states the correct test twice, in
`CanDeploy` (`satchel.cpp:294`) and `IsUseable` (`:275`), both as `ammo > 0 || m_chargeReady != 0`.

**Neither `ammo_satchel` nor `satchel_state` was networked.** They rode client prediction with
nothing to reconcile them, so the two sides could drift apart permanently.

### The chosen divergence

`+attack` throws while you have satchels and **detonates once you have none left to throw**.
`+attack2` still detonates, unchanged. Multi-charge is untouched — throw up to five, then blow
them with either key.

| input | condition | result |
|---|---|---|
| `+attack` | `ammo > 0` | throw (HL) |
| `+attack` | `ammo == 0`, charges live | **detonate** (new) |
| `+attack2` | charges live | detonate (HL) |

It changes only the case that was previously useless — a dry-fire click, which is itself a mod
invention with no HL equivalent (`Throw()` at zero ammo is silent). That click is why the wrong
key felt like the right key failing. The branch lives in the shared gate `SH_SatchelTryThrow`,
returning a new `-2`, so the server and the CSQC prediction take one code path into the existing
`SH_SatchelTryDetonate` rather than two copies of the decision.

### Three corrections caught before they shipped

Worth recording individually, because each was a plausible-looking change that was wrong:

- **The ownership clause went into the wrong function first.** `W_UtilityEntityHasWeapon` has
  exactly two callers and both are *pickup* questions — `sv_weapons.qc:2774` is the
  duplicate-pickup gate. Putting the "or charges are live" clause there would have **refused to
  let you pick up a satchel pouch to rearm while your charges were out**, which is precisely
  backwards. It belongs in the `self` wrapper `W_UtilityPlayerHasWeapon`, whose 12 callers are
  all the ownership/selection question.
- **The wire change needed two things beyond the read and the write.**
  `PM_CSQC_PROXY_VERSION` had to go 20 → 21 or a stale `csprogs.dat` reads garbage, and
  `pm_ammo_mb1 = 15` had to become `31` at **both** `sv_player.qc:2374` and `:3247` — the
  respawn force-resend. Miss either and the new field never re-sends on spawn, which is the
  documented "first join shows 0" bug at `:1989-1998`.
- **The same wire change was needed for the tripmine and snark, and was missed.** `v21` added
  `ammo_satchel` on the reasoning that the other deployables "auto-switch on empty so their drift
  self-corrects". That reasoning does not hold: `ammo_tripmine` and `ammo_snark` were never on the
  wire *at all*, so the client's copy started at 0 and nothing ever raised it — there was no drift
  to correct, only a permanent zero. `SH_TripmineTryPlace` / `SH_SnarkTryThrow` failed their own
  `ammo <= 0` gate, so the client never entered `WS_FIRE` and never played a place/throw animation,
  the HUD printed 0, and `W_UtilityPlayerHasWeapon` denied a weapon the server had you holding.
  Fixed in **v22**, with the same four-part checklist as v21: write, read, mask bit, and the
  baseline `pm_ammo_mb1` re-arm at **both** `sv_player.qc:2412` and `:3373` (`31` → `127`).
- **Resetting `satchel_state` on spawn created a new orphan path.** The reset is mandatory —
  without it a stale ARMED makes you permanently own a satchel you do not have — but clearing
  the state while the previous life's charges are still on the map strands them just as surely.
  Cleanup had to go in `PlayerSpawn`, not only `PlayerKilled`, because **not every respawn goes
  through a kill** (round restart and team change do not). `W_SatchelDeactivateAll` removes
  rather than detonates, matching HL's `DeactivateSatchels` — a death-triggered blast would be a
  free posthumous frag.

### The F5 weapon bench

Fifth in the dev-overlay family (F1 cvars, F2 server, F3 car tuning, F4 NPC bench). Built on
`cl_npcpanel.qc`'s structure and `cl_debugpanel.qc`'s `Debug_Button` and `DBG_*` constants, so
nothing new was drawn from scratch. **Zero new networking:** `sh_weapon_manifest.qc` compiles
into CSQC as well as SSQC, so the client already knows every weapon's name and slot.

Two modes, because they are genuinely different operations:

- **EQUIP** → `cmd wep_give <id>` → `W_GiveWeaponToSlot`. 77 weapons across four slot tabs.
- **SPAWN** → `cmd wep_spawn <token> [n]` → a pickup on the floor, plus a fifth **GoldSrc/Sven**
  tab holding the 16 alias classnames.

**The aliases are SPAWN-only, and that is the whole design point.** All 16 collapse onto 11
existing `WEP_` ids and differ *only* in the world model, which is replaced the moment you touch
it — equipping `weapon_tommygun` and `weapon_m16a1` gives a byte-identical result. In EQUIP mode
they would be duplicate rows that lie. On the floor they are the only way to see those models,
which also discharges the model check owed since PATCH 141.

Three things the implementation had to respect:

- **Resolution order in `wep_spawn` is load-bearing: classname first, id second.**
  `WeaponManifest_IdFromKey` maps `"uzi"` → `WMF_WEP_CFMAC10`, so resolving the id first would
  turn every alias back into its underlying weapon and hand back the stock model.
  `SV_DebugSpawnWeaponId` dispatches by id and structurally cannot express an alias, so SPAWN
  needs a second classname-keyed chain — the same shape as `Breakable_SpawnObject`, for the same
  reason: QC has no call-by-name.
- **`sv_debug_weapon_spawning` must bracket the spawn.** `W_RegisterMapWeapon` early-returns on
  it; without the bracket a debug-spawned weapon registers as a *map* weapon and respawns at
  every round restart forever.
- **Off-screen rows must be culled.** `MAX_ACTION_ELEMENTS` is 256 and is *shared* across every
  open panel; the primary tab alone is 48 rows. It degrades with a runtime warning, not a
  compile error.

### `debug_order` was hiding eight weapons, and fixing it by hand made it worse

`WeaponManifest_DebugWeapon` scans ids ascending and returns the first match on `debug_order`.
Eight orders (42-49) were each claimed twice — once by a Crossfire weapon and once by HL/OpFor
equipment — so satchel, tripmine, snark, hornetgun, shock rifle, displacer, jetpack and barnacle
grapple were **unreachable through the debug list entirely**, including all four weapons PATCH
141 added. Nothing errored: `DebugCount()` still returned the right total, so the
`sv_debug_weapons` grid just spawned eight fewer guns and left eight holes.

The first fix attempt made it worse, and the reason is worth naming. A quick regex over the
manifest matched **73 of 78 rows** and reported "no duplicates remain" — so the renumber walked
straight into `WMF_WEP_GRAVITYGUN`, one of the five rows the parser silently skipped, and that
same blind spot had also hidden a pre-existing SATCHEL/SLINGSHOT collision. **A parser that
silently matches a subset produces a confident, wrong all-clear.** The fix was to assert the row
count (78), then renumber both fields deterministically over the full set, preserving relative
order so the dropdowns look unchanged.

Now provable: `debug_order` is unique and contiguous **1..77** over exactly the DEBUG-flagged
set, and `loadout_order` is contiguous 1..N in all four slots. `sv_satchel_test` asserts it every
run — the guard whose absence let eight weapons disappear.

Also fixed: **`weapon_uziakimbo` declared `SLOT_SECONDARY` while the manifest said PRIMARY**, and
the two halves of a pickup read the slot from different places — `weapon_touch` from
`.weapon_slot`, `W_SlotAmmo_SetForWeapon` from the manifest. The gun landed in your pistol slot
while spending your rifle slot's ammo counters. `GoldSrc_AliasSetup` now dprints on any
disagreement, which catches the whole class rather than this instance.

### The harness lied twice more, in a new way

`sv_satchel_test` reported a clean cascade of failures on `hl_c11_a4` and passed everywhere else.
Both causes were in the test:

- **The bot kept dying mid-run.** Stages 2-6 assume the charges thrown in stage 1 are still
  yours, and `PlayerSpawn` now deliberately destroys them — so a death invalidates the sequence
  and every later stage fails. The test now detects a respawn and restarts, bounded at five
  attempts. That is a harness bug reading as a code bug, and it is the same shape as the
  `mp_nomapweapons` misdiagnosis two patches ago.
- **The throw went wherever the bot happened to be looking**, so on a large campaign map a charge
  could bounce somewhere it was lost. Fixed by throwing level and forward — exactly the reason
  the tripmine stage already picks a fixed angle, which was documented right there and not read.

### Counters

Both progs 0 warnings. Five-map regression all `BAD=0`, errors 0, **`crashaddr.txt`
1973 → 1973**. All four self-tests `BAD=0` across four maps (`th_ep1_00`, `2fort`, `of1a1`,
`hl_c06`) — ammo, alias, crate drops and the new satchel test.

`sv_satchel_test`, every stage:

```
1 throw makes a charge / spends ammo / state is ARMED        PASS
2 second charge out / ammo empty / STILL OWNS at 0 ammo      PASS   <- fails on the old code
3 switched away / re-selected the satchel / charges live     PASS
4 +attack detonated everything                               PASS
5 threw one / +attack2 detonated it                          PASS
6 nothing thrown / does not own an empty satchel             PASS
manifest debug_order reaches every weapon: got=77 want=77    PASS
wep_spawn alias made 2 pickups                               PASS
wep_spawn alias used the ALIAS models                        PASS
wep_spawn alias not registered as map weapons                PASS
```

The last three matter more than they look: the alias check spawns `weapon_tommygun` and
`weapon_uzi` through the panel's own SPAWN path and asserts the entities carry
`w_tommygun.mdl` / `w_uzi.mdl` rather than the stock HL SMG and MAC-10 models. Resolving those
names through the id table instead — the mistake the resolution order exists to prevent — would
produce two perfectly working pickups wearing the wrong guns, and nothing else in the tree would
notice.

### Owed in game

- That `+attack` on a spent satchel *feels* like a detonator and not a misfire, and that the
  radio animation now plays locally on `+attack2`.
- The jetpack thrust, which changed button bit — it now predicts on `+attack2` and no longer
  applies phantom thrust on jump. This is a movement change and only play will show it.
- The F5 panel itself: drag, scroll, the EQUIP/SPAWN toggle, and whether the GoldSrc tab's world
  models are the right ones.
- Whether EQUIP dropping the incumbent weapon at your feet is convenient or messy in practice.

## PATCH 144 — `optional` is a lie, GoldSrc additive art, and trails that never ran

Three shared defects behind ten reports. Two of them I introduced in the previous patch, and the
third made two of that patch's "fixes" no-ops.

### `optional` parameters are stale garbage, and it had already bitten twice

FTEQCC's `optional` is safe on **builtins only**. Three places in the toolchain say so:

- `qclib/qcc.h:379` — the compiler's own comment: *"argument may safely be omitted, for builtin
  functions. for qc functions use the defltvalue instead."*
- `qcc_pr_comp.c:9186-9193` — on a short call the compiler sets `np = arg` and emits `OP_CALL0`.
  **Nothing is written to `OFS_PARM0`.** The `&& !optional` on 9186 also means `optional` *defeats*
  a declared default value, so `optional float x = 3` is not a fix either.
- `pr_exec.c:553-562` — `PR_EnterFunction` copies `f->numparms`, the **declared** count, out of
  `OFS_PARM0` regardless of what the caller passed. Nothing is zeroed anywhere.

So an omitted argument reads whatever the previous call left behind. `client/cl_hud.qc:828`
already documented this exact trap and resolved it by making the parameter required — and then
PATCH 143 added three more `optional` parameters anyway.

Eleven QC functions declared `optional`; four had callers that actually passed short:

| Function | Short calls | What it did |
|---|---|---|
| `CSQC_MuzzleFlash` | 12 | every wrong muzzle colour in the report |
| `CSQC_SendHitclaim` | 4 | **garbage hitgroup on every melee and paintball hit** — unreported |
| `HLBeam_EntUpdate` | 2 | garbage `end_sprite` modelindex on the networked egon beam |
| `CSQC_EnvBeam_Local` | 2 | ditto on the shooter's local one |

The colour case is worth spelling out, because it explains why each gun was wrong *consistently*
rather than randomly: `CSQC_MuzzleFlash()` is the first statement in each shared hitscan helper,
so the stale word was that helper's own first argument. `HLSG_PELLETS` = 8 gave the shotgun an
8x-oversaturated white; `HLSG_DBL_PELLETS` = 16 gave its alt a different wrong colour; a `0.01`
spread constant gave the Python and the SMG a red of ~0, i.e. green.

The hitgroup one is the one nobody reported and the one that actually matters: the guard at
`sh_weapon_logic.qc:1000` only rejects a stale value that falls outside
`[HITGROUP_HEAD..HITGROUP_RIGHTLEG]`, so a melee hit intermittently applied a limb or headshot
multiplier at random.

`optional` is now gone from all eleven, and **`optional_audit.py`** (repo root, beside
`cvar_audit.py`) fails on any QC-defined function that declares one. It lives in the repo rather
than a scratchpad precisely because this class has now recurred three times.

`MUZZLE_TINT_DEFAULT` (`'1 0.8 0.4'`, burning powder) is what every conventional firearm passes.
The tesla gun passes `'1 1 1'`, which is not a guess — `weapon_teslagun.as:214` and `:347` call
`DynamicLight(pPlayer.pev.origin, 10, 255, 255, 255, 1, 10)`.

The light also moved from the camera to the barrel (`CSQC_MuzzleLightPos`), so a wall beside the
gun lights up instead of only what you face. Weapons that never stamp a muzzle offset keep the old
camera-relative push.

### FTE does not read GoldSrc additive art, in either format

`sprites/exit1.spr` declares `texFormat 1 = SPR_ADDITIVE` in its own header.
`Mod_LoadSpriteFrame` (`gl/gl_model.c:6925-7005`) acts only on `SPRHL_INDEXALPHA` and
`SPRHL_ALPHATEST`; additive falls into the `else` that forces every palette entry to alpha 255.
The frame then registers as `SPRITE_SHADER_UNLIT`, which at the shipped `gl_blendsprites 0`
compiles to `alphafunc ge128` + depthwrite — so every texel passes. HL additive art is opaque
paletted art whose **black is the transparency**, hence the reported black square around the
displacer ball.

Same gap for studio models: `shock_effect.mdl`'s one texture is `blueChrome.bmp`, flags
`0x0003 = FLATSHADE|CHROME`, drawn `rgbgen lightingdiffuse` — a lit metal sliver, not an energy
bolt. FTE has no `STUDIO_NF_ADDITIVE` at all (`gl_hlmdl.c:543-580`).

The fix is `.effects |= EF_ADDITIVE`, which the mod already used at `cl_bulletimpact.qc:449` and
`cl_c4.qc:22`. **Rule: every HL sprite or additive-effect model spawned as an entity needs it** —
and on the CSQC entity, not just the server one, because these are all `SendEntity` projectiles so
what renders is built by `CSQC_Projectile_Update`. `Projectile_TypeIsAdditive` now carries that.

The orb is also a 25-frame animation that was pinned to frame 0 on every update, and the egon's
impact flare an 11-frame one (`XSpark1.spr`) that HL cycles at 8 fps (`egon.cpp:417-419`).

### `.traileffectnum` does nothing on a CSQC entity

It is an `entity_state_t` field, applied only in `CL_LinkPacketEntities` for delta-replicated
**packet** entities (`cl_ents.c:5601`). `CopyCSQCEdictToEntity` never reads it. Every projectile
here is a `SendEntity` projectile — a CSQC entity on both the networked and the fake path — so
PATCH 143's RPG smoke and crossbow tracer were dead code that nobody, shooter or bystander, could
ever have seen. The recipes in `particles/trails.cfg` were fine all along.

`client/cl_throwtrail.qc` — which already does this correctly, with `trailparticles()`, an anchor
accumulator and a self-healing effect handle — now carries three effects instead of one and walks
`csqc_fake_projectile` as well. The RPG rocket, crossbow bolt and SMG contact grenade fakes are
tagged into it. The hornet gun is **not** affected: it has no `SendEntity`, so it is a real packet
entity and its `.traileffectnum` genuinely works.

Note the visibility ordering across the five CSQC fakes is monotonic in speed — orb 500 and rocket
250 were seen; bolt 2000, shock bolt 2000 and SMG grenade 1000 were not — and no other field
differs between them. Every silent-drop path was ruled out: `CopyCSQCEdictToEntity` drops only on
a null model (`pr_csqc.c:767`), alpha 0 becomes 1, scale 0 becomes 1, and CSQC `setmodel`
late-caches, so client-side precaching is irrelevant.

### The rest

- **Egon beam lag.** Prediction stamps the muzzle once per *input* frame from the raw predicted
  origin; the camera is rebuilt every *render* frame with `CSQC_ApplyLocalSmoothOffset` plus bob
  and weight (`cl_main.qc:811-821`). HL never sends a muzzle coordinate — `SetEndAttachment(1)` /
  `R_BeamEntPoint(idx | 0x1000, ...)`. Ported as `eb_view_anchor`: the start is re-resolved in the
  predraw from the live camera, and only the impact end stays a snapshot.
- **Egon light and muzzle effect: the user was right, HL has neither.** No dlight and no muzzle
  flash exist anywhere in `dlls/egon.cpp` or `EV_EgonFire`. The only sprite is the impact flare,
  which HL deliberately does *not* `FL_SKIPLOCALHOST`, so the shooter is meant to see it.
- **RPG dot.** `sv_weapons.qc:3852` dispatches `altfire()` every frame the button is *held*, and
  `SH_RPGTryAltFire` was a bare toggle on a 0.3 s timer — so holding right-click flipped the laser
  on and off twice a second, each flip `remove()`ing and respawning the entity, while CSQC ran the
  same toggle out of phase against its own clock. Now edge-triggered on both sides, with the
  server's spot `nodrawtoclient` to its owner and a CSQC-local dot traced from live aim.
- **Displacer secondary.** `DISP_SPINUP_TIME` and `DISP_SEQ_SPIN` were declared and used by
  nothing: `W_DispAltFire` teleported on the press. Now a real committed 1 s wind-up (ammo up
  front, no abort) that the client predicts for the animation while the server keeps sole authority
  over where you land. `CSQC_DispDisplayFrame` mapped only DRAW/FIRE/IDLE1, so it was overriding
  the server's spin-up sequence with the primary fire animation every frame.
- **Grapple.** A weapon that never became a physics body — a map spawn or a `give`, which
  `W_SyncMapWeaponPhysics` only converts when phys-eligible — fell into the pickup "tug" branch,
  which set `MOVETYPE_TOSS` on an entity whose client copy is drawn from a `SendEntity` snapshot.
  The server moved something the client was never told had moved. Weapons are now promoted with
  `W_PhysDropStart` and carried by `Carry_TryGrab`, the same path a crate takes. Releasing
  `+attack` now retracts the tongue, and the tongue draws with `gearbox/sprites/tongue.spr` through
  FTE's per-frame `_beam` shader instead of the generic rope PNG.

### Counters

Both progs **0 warnings**. `optional_audit` PASS (293 files, 0 offenders); `check_serverfire` PASS
(27 server-autonomous, 59 client-notified); `check_adsprofile` PASS (38 symmetric);
`check_durations` 254 constants with 1 pre-existing documented `SNARK_DRAW_DURATION` hit,
unchanged. `sv_satchel_test` **32 PASS / 0 FAIL, BAD=0**, including "manifest debug_order reaches
every weapon: got=85 want=85" and "every advertised weapon can be given: got=0 want=0". Headless
server and headless client both load with **zero weapon precache warnings** (only the two
pre-existing `gign.iqm` / `leet.iqm` player models) and no CSQC errors; all eight particle configs
exec, `trails.cfg` included.

### Owed in game

Everything here is visual, so only play will confirm it:

- **The colours, first.** Python, SMG, shotgun primary *and* alt, and each They Hunger gun should
  now flash the same powder orange; gauss, displacer, shock and tesla their own. And the light
  should come off the barrel, not your eye.
- Displacer ball as a churning ball of light with no black square, and the shock bolt visible.
- RPG smoke, crossbow tracer and SMG grenade trail — all three were the same dead mechanism, so
  they should appear or fail together.
- RPG dot steady while `+attack2` is held, and the rocket steering to it.
- Egon beam welded to the muzzle while strafing, and its impact flare animating.
- Displacer alt: spins up for a second, beeps, then teleports.
- Grapple: a weapon comes to hand like `+use` does, the rope holds until you release `+attack`, and
  the tongue looks like a tongue.
- The melee hitgroup fix has no visible tell; it will show up only as melee damage becoming
  consistent shot to shot.
