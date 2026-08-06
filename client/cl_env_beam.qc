//
// cl_env_beam.qc — CSQC receiver + renderer for env_beam.
//
// Pairs with server/sv_env_beam.qc.  Wire format (must match exactly):
//   byte  CSQC_ENT_ENV_BEAM
//   byte  netflags  (active / ring / shade_start / shade_end /
//                    start_sparks / end_sparks)
//   coord ×3  start position
//   coord ×3  end position
//   short  sprite modelindex
//   byte ×3  rgb
//   byte  brightness (0..255)
//   byte  width (0..255, /10 = world units)
//   byte  noise amplitude (0..255)
//   byte  scroll rate (0..100)
//   byte  framestart
//
// Render path: predraw generates N path points (with per-frame
// random noise jitter), submits them as a polygon-vertex strip, and
// closes with R_EndPolygonRibbon to extrude each vertex sideways
// into a billboarded quad band of half-width = width/20 world units.
//

// Builtin declarations not present in the project's cl_defs.qc but
// shipped in FTE's csqcsysdefs.qc.  Brought in locally rather than
// editing cl_defs.qc since they're only used by this file.
string(string modelname, int frame, float frametime) spriteframe = #0:spriteframe;
void(float radius, vector texcoordbias) R_EndPolygonRibbon = #0:R_EndPolygonRibbon;

// Forward decl — cl_scorch.qc compiles after this file, so we declare
// the function we need (DECAL_END handling) here.  Real definition
// lives at client/cl_scorch.qc:82.
void(vector pos, float kind) CSQC_SpawnScorchDecal;

// Drawflag constants (not declared in project cl_defs.qc — copied
// from FTE's csqcsysdefs.qc).  Used by R_BeginPolygon's flags arg to
// force additive blending + twosided culling for the beam ribbon.
const float DRAWFLAG_ADD      = 1;
const float DRAWFLAG_TWOSIDED = 1024;

// Deterministic float-seeded PRNG.  Maps a single float seed to a
// pseudo-random value in [-1, 1].  Used by the per-frame noise jitter
// so the beam jitter shape is stable WITHIN a 60Hz tick window (the
// jitter_tick + segment index gives a unique seed per (tick, vertex,
// axis); the hash maps that to the displacement).  Without this, the
// noise would re-roll on every render frame, producing white noise on
// high-refresh displays instead of the GoldSrc 60Hz crackle.
float(float seed) EnvBeam_HashNoise =
{
    float s = sin(seed * 12.9898 + 78.233) * 43758.5453;
    s = s - floor(s);          // 0..1
    return s * 2 - 1;          // -1..1
};

const float EBEAM_NET_ACTIVE_CL       = 1;
const float EBEAM_NET_RING_CL         = 2;
const float EBEAM_NET_SHADE_START_CL  = 4;
const float EBEAM_NET_SHADE_END_CL    = 8;
const float EBEAM_NET_START_SPARKS_CL = 16;
const float EBEAM_NET_END_SPARKS_CL   = 32;
const float EBEAM_NET_DECAL_END_CL    = 64;

// Path resolution.  16 segments gives 15 jitter degrees of freedom
// between the fixed endpoints — enough to read as "lightning" without
// burning render time on a quad strip the player will see for ~1
// second per strike.
const float EBEAM_PATH_SEGMENTS = 16;
const float EBEAM_RING_SEGMENTS = 28;

// Ceiling on how many times the sprite tiles along one beam.  GoldSrc uses
// length*0.01 unbounded, which on a 4000-unit beam is 40 repeats; every repeat
// costs vertices in the walk below, and th_ep1_00 alone draws 129 beams per
// frame.  32 keeps the worst case at ~70 verts a beam while leaving every rain
// streak in the corpus (512 units -> 5.12) far under the cap.
const float EBEAM_MAX_REPEATS   = 32;

// Sub-samples per repeat for a beam with NoiseAmplitude set.  A straight beam
// only needs its repeat boundaries, but a jittering one needs enough vertices
// along the length to read as lightning rather than a bent stick.
const float EBEAM_SUBDIV_NOISY  = 4;

.float  eb_netflags;
.vector eb_start_pos;
.vector eb_end_pos;
.float  eb_sprite_idx;
.vector eb_color;          // 0..1 RGB
.float  eb_brightness;     // 0..1
.float  eb_width;          // world units (BoltWidth / 10)
.float  eb_noise;          // 0..1 normalized amplitude
.float  eb_scroll;         // tex U units per second
.float  eb_framestart;
.float  eb_framerate;      // frames/sec for multi-frame beam sprites (0 = static)
.float  eb_end_sprite_idx; // env_laser EndSprite modelindex (0 = none)
.float  eb_active_last;    // for spark-burst trigger on rising edge

float() CSQC_EnvBeam_Predraw;

// Spawn a small spark burst at `pos`.  Re-uses the bullet-impact
// metal-spark particle effect — registered + precached by the
// impact system at boot, so no per-beam precache needed.  Quiet
// fallback if the effect isn't available (e.g. dedicated render
// path with particles disabled).
void(vector pos) CSQC_EnvBeam_SpawnSparks =
{
    // != 0 is the WHOLE test.  particleeffectnum returns <0 for a client-side
    // (particle-script) effect, >0 only for a server precache, and 0 for failure —
    // pr_csqc.c:3775-3777.  weapons.metal_impact is a particle-script effect, so its
    // id is always NEGATIVE: the old `<= 0` rejected every id it could ever get and
    // these sparks never once rendered.
    float spark_id = particleeffectnum("weapons.metal_impact");
    if (spark_id == 0)
        return;
    float i = 0;
    while (i < 6)
    {
        vector dir;
        dir_x = (random() * 2) - 1;
        dir_y = (random() * 2) - 1;
        dir_z = random() * 0.8 + 0.1;
        dir = normalize(dir);
        pointparticles(spark_id, pos, dir * 220, 1);
        i = i + 1;
    }
};

void() CSQC_EnvBeam_Update =
{
    float was_active = self.eb_active_last;

    float netflags = readbyte();
    self.eb_netflags = netflags;

    float sx = readcoord();
    float sy = readcoord();
    float sz = readcoord();
    self.eb_start_pos = [sx, sy, sz];
    float ex = readcoord();
    float ey = readcoord();
    float ez = readcoord();
    self.eb_end_pos = [ex, ey, ez];

    self.eb_sprite_idx = readshort();
    float r = readbyte();
    float g = readbyte();
    float b = readbyte();
    self.eb_color = [r / 255, g / 255, b / 255];
    self.eb_brightness = readbyte() / 255;
    self.eb_width      = readbyte() * 0.1;       // BoltWidth is in 1/10 units
    self.eb_noise      = readbyte() / 255;
    self.eb_scroll     = readbyte() - 128;       // signed, biased on the wire
    self.eb_framestart = readbyte();
    self.eb_framerate  = readbyte();
    self.eb_end_sprite_idx = readshort();

    // Position the entity at the midpoint so PVS culling has something
    // sensible to gate on.  The actual render fills space along the
    // ribbon, not just the entity origin.
    setorigin(self, (self.eb_start_pos + self.eb_end_pos) * 0.5);

    float now_active = (netflags & EBEAM_NET_ACTIVE_CL);

    if (now_active && !was_active)
    {
        // Rising edge — emit a spark burst at flagged endpoints once.
        if (netflags & EBEAM_NET_START_SPARKS_CL)
            CSQC_EnvBeam_SpawnSparks(self.eb_start_pos);
        if (netflags & EBEAM_NET_END_SPARKS_CL)
            CSQC_EnvBeam_SpawnSparks(self.eb_end_pos);
        // env_laser DECAL_END: scorch the surface at the hit point.
        // For env_beam DECAL_END (HL "seemingly unused") this same
        // path makes it actually do something — a one-shot decal at
        // the visible end of the beam on activation.
        if (netflags & EBEAM_NET_DECAL_END_CL)
            CSQC_SpawnScorchDecal(self.eb_end_pos, 1);
    }
    self.eb_active_last = now_active;

    self.classname = "env_beam";
    self.drawmask  = MASK_ENGINE;
    self.predraw   = CSQC_EnvBeam_Predraw;
    // No engine-rendered model — the predraw builds the geometry directly
    // via R_BeginPolygon.  Clear the model slot in case this CSQC entity
    // slot was previously used for something else.
    setmodel(self, "");
};

// Resolve the shader to draw this beam's ribbon with.
//
// THE SPRITE'S PIXELS ARE ONLY REACHABLE THROUGH spriteframe().
//
// This used to build a name like "ebeam_nm_rain" and look it up in
// scripts/env_beam.shader, where the block said `map sprites/nm_rain`.  That
// can never work: `map <name>` asks FTE's image loader for
// sprites/nm_rain.tga/.png/.jpg/..., and the rain streak does not exist as a
// standalone image — it lives inside sprites/nm_rain.spr.  The lookup failed
// silently and the stage fell back to a blank white texture, so all 129 of
// th_ep1_00's rain beams drew as flat white bars.  Scrolling a uniform white
// texture produces no visible motion, which is exactly the reported symptom:
// the rain rendered, but sat there.
//
// What actually holds those pixels is the shader FTE synthesises per sprite
// frame in Mod_LoadSpriteFrameShader (gl_model.c:6648): it registers a shader
// named "<modelpath>_<frame>.tga" and binds the decoded frame to its $diffuse.
// spriteframe() hands back that name, and R_BeginPolygon takes it directly —
// which is what the builtin is documented for.
//
// The generated shader already carries `rgbgen vertex` + `alphagen vertex`
// (SPRITE_SHADER_MAIN), so the per-vertex colour and alpha we pass survive.
// Its blend mode follows gl_blendsprites and defaults to an alpha TEST with
// depthwrite, which would give a hard-edged, depth-writing rain streak — so
// the caller passes DRAWFLAG_ADD.  BEF_FORCEADDITIVE clears the alpha-test and
// depthwrite bits outright (gl_backend.c:3140) and forces SRC_ALPHA/ONE, which
// is correct for every HL beam sprite: they are all authored additive.
//
// Frame selection: HL cycles a beam sprite's frames at `framerate` starting
// from `framestart`.  sprites/lgtning.spr has 3, and none of them animated
// before because framestart was read and dropped and framerate never crossed
// the wire at all.  For a single-frame sprite like nm_rain this is a no-op.
//
// Falls back to the untextured "ebeam" block when there is no sprite, or when
// the model turns out not to be a sprite (spriteframe returns "" for a .mdl),
// so an unknown texture key still draws something rather than vanishing.
string(entity beam) CSQC_EnvBeam_ShaderName =
{
    if (beam.eb_sprite_idx <= 0)
        return "ebeam";

    string path = modelnameforindex(beam.eb_sprite_idx);
    if (path == "" || !path)
        return "ebeam";

    // spriteframe() returns "" for an out-of-range frame rather than clamping,
    // so wrap against the sprite's real frame count.  A rate of 0 (the default,
    // and every rain beam) just sits on framestart.
    float nframes = modelframecount(beam.eb_sprite_idx);
    if (nframes < 1)
        nframes = 1;

    float frame = beam.eb_framestart;
    if (beam.eb_framerate > 0)
        frame = frame + floor(time * beam.eb_framerate);
    frame = frame - floor(frame / nframes) * nframes;    // wrap into 0..nframes-1

    string sh = spriteframe(path, frame, time);
    if (sh == "" || !sh)
        return "ebeam";          // not a sprite (a .mdl "texture" key, say)

    // "_beam", not the sprite's own shader.  The stock one is registered as
    // "defaultsprite#MASK=0.666" at the default gl_blendsprites 0, and that MASK
    // is a discard inside the fragment program testing the TEXTURE's alpha —
    // nm_rain.spr peaks at 96/255, so every texel of the rain was thrown away
    // and the beams drew as nothing.  It also depth-writes, which an additive
    // ribbon must not.  Mod_LoadSpriteFrameShader registers this second shader
    // over the same image with blendfunc add, rgbgen/alphagen vertex and no
    // mask; see the comment there.
    return strcat(sh, "_beam");
};

// One ribbon vertex.  `frac` is 0..1 along the beam (drives the SHADE_START /
// SHADE_END alpha ramp), `tex_t` is the texcoord along the beam and MUST already
// be inside [0,1] — see the long note in the predraw about IF_CLAMP.
//
// S is left at 0 here; R_EndPolygonRibbon's texcoordbias puts the other edge of
// the ribbon at S=1.
void(vector pos, float frac, float tex_t) CSQC_EnvBeam_Vertex =
{
    // SHADE_START fades alpha from 1 (at the end) to 0 (at the start);
    // SHADE_END fades from 1 (at the start) to 0 (at the end).  Spec:
    // SHADE_START wins if both flags are set.
    float alpha = self.eb_brightness;
    if (self.eb_netflags & EBEAM_NET_SHADE_START_CL)
        alpha = alpha * frac;
    else if (self.eb_netflags & EBEAM_NET_SHADE_END_CL)
        alpha = alpha * (1 - frac);

    vector tc;
    tc_x = 0;
    tc_y = tex_t;
    tc_z = 0;
    R_PolygonVertex(pos, tc, self.eb_color, alpha);
};

// NoiseAmplitude displacement for a point `frac` of the way along a beam of
// length `len`.  Endpoints stay pinned.  Amplitude scales with beam length so
// long beams look as "shaky" as short ones at the same NoiseAmplitude — which
// matches the HL spec note that longer beams are visibly more affected by the
// same value.
//
// The seed is derived from the POSITION along the beam rather than a vertex
// index, because the tiling walk emits duplicate vertices at every repeat
// boundary: index-seeded jitter would displace the two copies differently and
// tear the ribbon open at each seam.
vector(vector pos, float frac, float len, float jitter_tick) CSQC_EnvBeam_Jitter =
{
    if (self.eb_noise <= 0) return pos;
    if (frac <= 0)          return pos;
    if (frac >= 1)          return pos;

    float falloff = 4 * frac * (1 - frac);   // 0 at the ends, 1 at the midpoint
    float amp     = self.eb_noise * len * 0.1 * falloff;

    // Quantised to a 60Hz tick so the beam doesn't flicker faster on a
    // high-refresh display: per-frame jitter at 240Hz looks like white noise,
    // at 60Hz it reads as the coherent crackle GoldSrc had.  self.entnum is
    // mixed in so two beams at the same position don't jitter identically.
    float seed_base = jitter_tick + floor(frac * 64) * 17 + self.entnum * 113;
    vector jitter;
    jitter_x = EnvBeam_HashNoise(seed_base + 1.7) * amp;
    jitter_y = EnvBeam_HashNoise(seed_base + 3.3) * amp;
    jitter_z = EnvBeam_HashNoise(seed_base + 5.1) * amp;
    return pos + jitter;
};

// Build a "ring" path: a horizontal ellipse between the two endpoints.
// The XY-plane circle has its diameter equal to the start->end length
// and a Z offset that interpolates linearly across the ring.  Matches
// HL's behaviour where the ring "tends toward horizontal" — pure
// horizontal here for simplicity.
vector(vector s, vector e, float t) CSQC_EnvBeam_RingPoint =
{
    vector mid = (s + e) * 0.5;
    vector axis_dir = e - s;
    float  axis_len = vlen(axis_dir);
    if (axis_len < 1) axis_len = 1;
    axis_dir = axis_dir / axis_len;

    // Pick an orthogonal "side" axis perpendicular to the line.  For
    // a horizontal-ish line this gives a near-vertical perpendicular,
    // which produces a near-flat ring — HL behaviour.
    vector ref = '0 0 1';
    if (fabs(axis_dir_z) > 0.95)   // line is mostly vertical
        ref = '1 0 0';
    vector side = normalize(crossproduct(axis_dir, ref));

    float angle = t * 2 * 3.14159265;
    float r = axis_len * 0.5;
    return mid + axis_dir * (cos(angle) * r) + side * (sin(angle) * r);
};

float() CSQC_EnvBeam_Predraw =
{
    if (!(self.eb_netflags & EBEAM_NET_ACTIVE_CL))
        return PREDRAW_NEXT;
    if (vlen(self.eb_end_pos - self.eb_start_pos) < 1)
        return PREDRAW_NEXT;

    // Per-sprite shader out of scripts/env_beam.shader.  Each block declares
    // rgbgen vertex + blendfunc add explicitly, so the per-vertex colour we
    // pass actually reaches the fragment output — going through spriteframe()
    // instead picks up an auto-generated sprite shader using
    // rgbgen identitylighting, which collapses to black on non-surface ribbon
    // geometry.
    //
    // Resolving the mapper's actual sprite (rather than a hand-written shader
    // that could never reach the .spr's pixels) is what makes rain look like
    // rain: nm_rain.spr is an 8x48 additive streak, and drawing it with a blank
    // white texture produced one solid bar from cloud to ground that no amount
    // of scrolling could animate.  See CSQC_EnvBeam_ShaderName.
    //
    // DRAWFLAG_ADD forces the additive blend every HL beam sprite expects,
    // overriding the alpha-test-plus-depthwrite the generated sprite shader
    // uses at the default gl_blendsprites 0.  DRAWFLAG_TWOSIDED disables
    // backface culling — the ribbon is viewed from arbitrary angles.
    // DRAWFLAG_ADD is load-bearing, not decorative.  The ribbon resolves to the
    // engine's SPRITE_SHADER_BEAM, whose `blendfunc add` compiles to
    // GL_ONE/GL_ONE (gl_shader.c) -- which DISCARDS the fragment alpha.  Both
    // renderamt (eb_brightness) and the SHADE_START/SHADE_END ramp are carried
    // in vertex alpha by CSQC_EnvBeam_Vertex, so without this flag both were
    // silently thrown away and every beam drew at 100% of the sprite's raw
    // colour.  nm_rain.spr is pure cyan (R=0 in every used palette entry,
    // brightest (0,132,156)) at renderamt 100, so the rain drew 2.55x too bright
    // at its brightest point and 5.1x too bright averaged along the beam --
    // clipping G and B with R pinned at 0, i.e. "too blue".
    //
    // DRAWFLAG_ADD sets BEF_FORCEADDITIVE, which the backend rewrites to
    // SRC_ALPHA/ONE -- GoldSrc's exact beam blend, colour x brightness x shade.
    R_BeginPolygon(CSQC_EnvBeam_ShaderName(self), DRAWFLAG_ADD | DRAWFLAG_TWOSIDED);

    // Quantize the noise-jitter seed to a 60Hz tick so the beam doesn't
    // flicker faster on high-refresh displays.  Per-frame jitter at 240Hz
    // looks like white noise; at 60Hz it reads as a coherent crackle that
    // matches the GoldSrc/HL look.  The renderer still runs at full
    // refresh — only the random-jitter seed advances at 60Hz.
    float jitter_tick = floor(time * 60);

    // The texture scrolls ALONG the beam.  GoldSrc's TextureScroll is in tenths
    // of a texture-repeat per second (Xash's own comment: "Scroll speed 3.5 --
    // scrolls 3.5/sec, 1.0 is the entire texture"), which is what the 0.1 is.
    // The value is signed; -20 scrolls downward, i.e. falling rain.
    //
    // Only the FRACTIONAL part matters.  Every repeat draws the same texture, so
    // scrolling by a whole repeat is a no-op, and keeping the offset in [0,1)
    // is what lets the tiling walk below stay inside the texture (see there).
    float scroll_rate = cvar("cl_beam_scroll");
    if (scroll_rate <= 0) scroll_rate = 1;
    // SIGN.  The vertex walk below makes T increase monotonically from the START
    // vertex to the END vertex: T(f) = frac(scroll_t + f * beam_reps).  So a
    // texture feature at row V sits at f = (V - scroll_t) / beam_reps, and
    // d(f)/d(scroll_t) is NEGATIVE -- an offset that GROWS over time drags the
    // image BACKWARD, toward the start vertex.
    //
    // th_ep1_00's 124 rain beams all author TextureScroll -20, and every one of
    // them runs start ABOVE end by exactly 416 units (measured from the
    // referenced info_targets: 416->0 x28, -1064->-1480 x30, -1370->-1786 x64).
    // Falling rain therefore needs the offset to SHRINK.  The unary minus that
    // used to be here turned -20 into +2 repeats/sec of RISING offset and
    // scrolled all 124 rain beams upward, out of the floor and into the sky.
    //
    // This is a global convention change, not a rain-only one: of 1349 beams
    // across the corpus only 127 have negative TextureScroll, so the other 1222
    // (902 of them at +35) also reverse.  That is intended -- the negation was
    // simply wrong, and rain is the one case where ground truth is measurable.
    //
    // The [0,1) wrap on the next line is unaffected: floor() handles negatives,
    // e.g. -2.3 - floor(-2.3) = 0.7, and the mapping is periodic in scroll_t.
    float scroll_t = self.eb_scroll * time * 0.1 * scroll_rate;
    scroll_t = scroll_t - floor(scroll_t);

    // Repeats along the beam, proportional to its LENGTH, exactly as GoldSrc's
    // R_DrawSegs does (`length *= 0.01; vStep = length * div;`).
    float beam_reps = vlen(self.eb_end_pos - self.eb_start_pos) * 0.01;
    if (beam_reps < 0.5)
        beam_reps = 0.5;        // GoldSrc keeps some texture on very short beams
    if (beam_reps > EBEAM_MAX_REPEATS)
        beam_reps = EBEAM_MAX_REPEATS;

    // Sub-samples per texture repeat.  A straight beam only needs its repeat
    // boundaries; a noisy one needs enough vertices along the length for the
    // jitter to read as lightning rather than a bent stick.
    float sub = (self.eb_noise > 0) ? EBEAM_SUBDIV_NOISY : 1;

    // ---------------------------------------------------------------------
    //  Vertex walk
    //
    // TEXCOORD AXES ARE S=ACROSS, T=ALONG, which is the opposite of what this
    // function used to do.  GoldSrc's R_DrawSegs emits glTexCoord2f(0, vLast)
    // and glTexCoord2f(1, vLast): S is pinned to the two edges of the ribbon
    // and T accumulates down its length.  sprites/nm_rain.spr is an 8x48 image
    // whose single rain streak runs down the 48-pixel axis and whose 8-pixel
    // axis is empty except for one column — transposing the two smeared that
    // one column along the whole beam and squashed the streak across its width.
    //
    // T IS KEPT INSIDE [0,1] BY SUBDIVIDING, NOT BY LETTING IT RUN PAST 1.
    // Sprite frames are uploaded with IF_CLAMP (gl_model.c's
    // Mod_LoadSpriteFrame), which becomes GL_CLAMP_TO_EDGE, so any coordinate
    // outside [0,1] samples the border texel forever.  nm_rain's first and last
    // rows are fully transparent, so the old "T = scroll + t*reps" — which is
    // almost always well past 1 — clamped every fragment to alpha 0 and the
    // rain vanished outright.  We cannot ask for a repeating copy either:
    // Image_FindTexture keys its cache on IF_CLAMP among other flags, so a
    // non-clamped request misses the sprite's pixels and tries (and fails) to
    // load a file of that name.
    //
    // So the tiling is done in GEOMETRY: walk the beam in texture space, and at
    // every integer boundary emit the vertex twice — once closing the previous
    // repeat at T=1, once opening the next at T=0.  Both copies sit at the same
    // point, so the quad between them has zero area and draws nothing; every
    // other quad spans exactly one in-range slice of the texture.  Scrolling is
    // then just moving where the boundaries land, which is why scroll_t above
    // only keeps its fractional part.
    // ---------------------------------------------------------------------
    float i;

    if (self.eb_netflags & EBEAM_NET_RING_CL)
    {
        // Rings are a closed ellipse, not a straight run; keep them on a plain
        // even subdivision and just let the texture wrap over the whole loop.
        for (i = 0; i <= EBEAM_RING_SEGMENTS; i++)
        {
            float t = i / EBEAM_RING_SEGMENTS;
            vector pos = CSQC_EnvBeam_RingPoint(self.eb_start_pos, self.eb_end_pos, t);
            CSQC_EnvBeam_Vertex(pos, t, t - floor(t));
        }
    }
    else
    {
        vector dir = self.eb_end_pos - self.eb_start_pos;
        float  len = vlen(dir);

        float t_end = scroll_t + beam_reps;    // texture coord at the far end
        float tcur  = scroll_t;                // texture coord at the near end
        float guard = 0;                       // hard stop; see EBEAM_MAX_REPEATS

        // Opening vertex.
        CSQC_EnvBeam_Vertex(self.eb_start_pos, 0, tcur - floor(tcur));

        while (tcur < t_end)
        {
            guard = guard + 1;
            if (guard > EBEAM_MAX_REPEATS + 2)
                break;

            float tnext = floor(tcur) + 1;      // next repeat boundary
            float closes = TRUE;                // does this span end on one?
            if (tnext >= t_end)
            {
                tnext  = t_end;
                closes = FALSE;
            }

            // Sub-samples inside this repeat.  j runs to `sub` so the last one
            // lands exactly on tnext.
            float j;
            for (j = 1; j <= sub; j++)
            {
                float ts   = tcur + (tnext - tcur) * (j / sub);
                float frac = (ts - scroll_t) / beam_reps;    // 0..1 along the beam
                vector pos = self.eb_start_pos + dir * frac;
                pos = CSQC_EnvBeam_Jitter(pos, frac, len, jitter_tick);
                CSQC_EnvBeam_Vertex(pos, frac, ts - floor(tcur));
            }

            if (closes)
            {
                // Duplicate the boundary vertex with the texcoord wrapped back
                // to 0.  Zero-length span, so nothing is drawn between the two.
                float frac = (tnext - scroll_t) / beam_reps;
                vector pos = self.eb_start_pos + dir * frac;
                pos = CSQC_EnvBeam_Jitter(pos, frac, len, jitter_tick);
                CSQC_EnvBeam_Vertex(pos, frac, 0);
            }
            tcur = tnext;
        }
    }

    // Half-width of the ribbon (eb_width is the full width key in world units;
    // HL's BoltWidth is *0.1, applied during update).  The bias is on S now,
    // not T — one edge of the ribbon gets S=0, the other S=1.
    R_EndPolygonRibbon(self.eb_width * 0.5, '1 0 0');

    // env_laser EndSprite — a billboarded sprite quad at the end
    // point.  Drawn additively with the beam's tint so the end glow
    // matches the beam colour.  Size is a fixed 16-unit half-extent;
    // GoldSrc had the size locked to the sprite's native dimensions
    // (the HL bug "regardless of beam width" — we honour that for
    // compatibility, mapper can swap sprites for variety).
    if (self.eb_end_sprite_idx > 0)
    {
        string end_name = modelnameforindex(self.eb_end_sprite_idx);
        if (end_name != "" && end_name != __NULL__)
        {
            // Draw the mapper's actual EndSprite, via the same
            // spriteframe() route the ribbon uses — this used to hard-code
            // the untextured "ebeam" block, so all 52 EndSprites in the
            // corpus rendered as a flat coloured square rather than the
            // glow the mapper picked.
            string end_shader = spriteframe(end_name, 0, time);
            if (end_shader == "" || !end_shader)
                end_shader = "ebeam";
            R_BeginPolygon(end_shader, DRAWFLAG_ADD | DRAWFLAG_TWOSIDED);

            // Build screen-aligned billboard via the camera right/up
            // vectors at the end position.  Read them via the engine's
            // view properties (set per-frame by the renderer).
            vector view_right, view_up;
            makevectors(getproperty(VF_ANGLES));
            view_right = v_right;
            view_up    = v_up;

            float hs = 16;        // half-size in world units
            vector ep = self.eb_end_pos;

            R_PolygonVertex(ep + view_right * -hs + view_up *  hs, '0 0 0', self.eb_color, self.eb_brightness);
            R_PolygonVertex(ep + view_right *  hs + view_up *  hs, '1 0 0', self.eb_color, self.eb_brightness);
            R_PolygonVertex(ep + view_right *  hs + view_up * -hs, '1 1 0', self.eb_color, self.eb_brightness);
            R_PolygonVertex(ep + view_right * -hs + view_up * -hs, '0 1 0', self.eb_color, self.eb_brightness);
            R_EndPolygon();
        }
    }

    return PREDRAW_NEXT;
};
