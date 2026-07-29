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
    self.eb_scroll     = readbyte();
    self.eb_framestart = readbyte();
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

    // Dedicated "ebeam" shader (scripts/env_beam.shader) — uses
    // $whiteimage as the texture with rgbgen vertex + blendfunc add
    // explicitly declared, so the per-vertex colour we pass actually
    // reaches the fragment output.  Going through spriteframe()
    // previously picked up an auto-generated sprite shader using
    // rgbgen identitylighting which collapsed to black on non-surface
    // ribbon geometry.  DRAWFLAG_TWOSIDED disables backface culling.
    R_BeginPolygon("ebeam", DRAWFLAG_TWOSIDED);

    // Quantize the noise-jitter seed to a 60Hz tick so the beam doesn't
    // flicker faster on high-refresh displays.  Per-frame jitter at 240Hz
    // looks like white noise; at 60Hz it reads as a coherent crackle that
    // matches the GoldSrc/HL look.  The renderer still runs at full
    // refresh — only the random-jitter seed advances at 60Hz.
    float jitter_tick = floor(time * 60);

    // Texture U coordinate scrolls along the beam by eb_scroll * time.
    // HL scrolls at "0..100" mapping to "fast scroll" — we use the
    // raw value as units-per-second, so 100 = one full texture wrap
    // per (eb_width)-length segment per second.  Tunable.
    float scroll_u = -self.eb_scroll * time * 0.1;

    float seg_count = (self.eb_netflags & EBEAM_NET_RING_CL)
                      ? EBEAM_RING_SEGMENTS
                      : EBEAM_PATH_SEGMENTS;
    float i;
    vector prev_pos;

    for (i = 0; i <= seg_count; i++)
    {
        float t = i / seg_count;
        vector pos;

        if (self.eb_netflags & EBEAM_NET_RING_CL)
        {
            pos = CSQC_EnvBeam_RingPoint(self.eb_start_pos, self.eb_end_pos, t);
        }
        else
        {
            pos = self.eb_start_pos + (self.eb_end_pos - self.eb_start_pos) * t;

            // Random noise jitter — endpoints stay pinned (t=0 and t=1
            // get zero jitter).  Amplitude scales with beam length so
            // long beams look as "shaky" as short ones at the same
            // NoiseAmplitude value — matches the HL spec note that
            // longer beams are visibly more affected by the same value.
            if (self.eb_noise > 0 && t > 0 && t < 1)
            {
                float falloff = 4 * t * (1 - t);   // 0 at ends, 1 at midpoint
                float amp = self.eb_noise * vlen(self.eb_end_pos - self.eb_start_pos) * 0.1 * falloff;
                // Hash-seed per (tick, segment, axis) so jitter is
                // deterministic within a 60Hz tick window AND unique
                // per segment.  Mix in self.entnum so two beams at
                // the same position don't jitter identically.
                float seed_base = jitter_tick + i * 17 + self.entnum * 113;
                vector jitter;
                jitter_x = EnvBeam_HashNoise(seed_base + 1.7) * amp;
                jitter_y = EnvBeam_HashNoise(seed_base + 3.3) * amp;
                jitter_z = EnvBeam_HashNoise(seed_base + 5.1) * amp;
                pos = pos + jitter;
            }
        }

        // Per-vertex shading: SHADE_START fades alpha from 1 (at end)
        // to 0 (at start); SHADE_END fades from 1 (at start) to 0 (at
        // end).  Spec: SHADE_START wins if both flags set.
        float alpha = self.eb_brightness;
        if (self.eb_netflags & EBEAM_NET_SHADE_START_CL)
            alpha = alpha * t;                  // bright at end
        else if (self.eb_netflags & EBEAM_NET_SHADE_END_CL)
            alpha = alpha * (1 - t);            // bright at start

        // Texcoord: U along the beam, V across (set to 0 — the ribbon
        // builder duplicates each vertex with V=0 and V=1 sides).
        // V is provided via the texcoordbias arg to R_EndPolygonRibbon.
        vector tc;
        tc_x = scroll_u + t * 4;     // tile the sprite ~4× along the beam length
        tc_y = 0;
        tc_z = 0;
        R_PolygonVertex(pos, tc, self.eb_color, alpha);

        prev_pos = pos;
    }

    // Half-width of the ribbon (eb_width is the full width key in
    // world units; HL's BoltWidth is *0.1, applied during update).
    R_EndPolygonRibbon(self.eb_width * 0.5, '0 1 0');

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
            // Same "ebeam" shader for the end sprite quad — a solid
            // billboarded square in the beam colour.  Mapper's
            // EndSprite key is precached server-side (so the protocol
            // can ship a non-zero modelindex), but the visual is the
            // unified vertex-colored additive shader.
            R_BeginPolygon("ebeam", DRAWFLAG_TWOSIDED);

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
