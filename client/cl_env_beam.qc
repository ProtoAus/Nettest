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

// --- View-anchored start (Half-Life's `entindex | 0x1000` attachment beams) ---
//
// A sustained first-person beam CANNOT store its muzzle end as a world point.
// Prediction runs at INPUT rate and stamps the point from the raw predicted
// origin; the camera is rebuilt every RENDER frame from a further-advanced
// origin plus CSQC_ApplyLocalSmoothOffset, plus camera bob and weight
// (cl_main.qc:811-821).  So the stored point trails the eye by the smoothing
// term and sits off-axis by the bob term, and the beam visibly follows the
// player around instead of leaving the gun.  That is the reported egon lag.
//
// Half-Life never sends a muzzle coordinate at all: CEgon::CreateEffect uses
// PointEntInit + SetEndAttachment(1) (egon.cpp:433-436) and the client uses
// R_BeamEntPoint(idx | 0x1000, ...) (ev_hldm.cpp:1483), i.e. an
// entity+attachment handle the engine re-evaluates every render frame.  Only
// the far end is ever a world point.
//
// eb_view_ofs is that muzzle offset in CAMERA-LOCAL units (x=forward, y=right,
// z=up) and is resolved against the live camera at the top of the predraw.
.float  eb_view_anchor;    // 1 = eb_start_pos is derived from eb_view_ofs each frame
.vector eb_view_ofs;       // camera-local muzzle offset (forward, right, up)

float() CSQC_EnvBeam_Predraw;
void() CSQC_EnvBeam_LocalExpire = { remove(self); };

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

// ============================================================
//  CLIENT-LOCAL BEAMS  —  the shooter's own half of a weapon beam
// ============================================================
//
// Half-Life draws a firing player's gauss / egon beam TWICE, from two
// different places.  The server's CBeams carry FL_SKIPLOCALHOST (egon.cpp), so
// they never reach the player who fired; that client instead draws its own pair
// in EV_EgonFire / EV_FireGauss (cl_dll/ev_hldm.cpp).  The point is latency: a
// sustained beam swept across a room has to track the crosshair exactly, and a
// networked one trails it by a round trip.
//
// This is the CSQC half.  It builds the SAME entity CSQC_EnvBeam_Update builds
// from the wire and hands it to the SAME predraw, so the shooter's beam and the
// observers' beam are the same renderer with the same numbers -- which is the
// whole reason to do it here rather than with a particle approximation.  The
// arguments are in the SERVER's units (rendercolor 0-255, renderamt 0-255,
// BoltWidth and NoiseAmplitude in tenths, TextureScroll signed) so a weapon can
// pass one set of constants to both sides and trust they match; the conversions
// below are copied from the wire parse above and must stay in step with it.
//
// Pass `b` = an existing beam to refresh it in place (sustained fire), or world
// to spawn one.  life > 0 self-removes after that long; life <= 0 means the
// caller owns it and must call CSQC_EnvBeam_LocalKill.
entity(entity b, vector from, vector to, float sprite_idx, vector col,
       float bright, float width, float noise, float scroll, float life,
       float end_sprite)
    CSQC_EnvBeam_Local =
{
    if (!b || b == world)
    {
        b = spawn();
        b.classname = "env_beam";
        b.drawmask  = MASK_ENGINE;
        b.predraw   = CSQC_EnvBeam_Predraw;
        setmodel(b, "");
    }

    b.eb_netflags   = EBEAM_NET_ACTIVE_CL;
    b.eb_start_pos  = from;
    b.eb_end_pos    = to;
    b.eb_sprite_idx = sprite_idx;
    b.eb_color      = [bound(0, col_x, 255) / 255,
                       bound(0, col_y, 255) / 255,
                       bound(0, col_z, 255) / 255];
    b.eb_brightness = bound(0, bright, 255) / 255;
    b.eb_width      = bound(0, width, 255) * 0.1;
    b.eb_noise      = bound(0, noise, 255) / 255;
    b.eb_scroll     = scroll;
    b.eb_framestart = 0;
    b.eb_framerate  = 0;
    b.eb_end_sprite_idx = end_sprite;
    b.eb_active_last = EBEAM_NET_ACTIVE_CL;

    // Midpoint origin, matching the networked path — the predraw fills the
    // ribbon itself, but the origin is what the engine sorts and culls on.
    setorigin(b, (from + to) * 0.5);

    if (life > 0)
    {
        b.think     = CSQC_EnvBeam_LocalExpire;
        b.nextthink = time + life;
    }
    else
    {
        // Dead-man timer: a sustained beam refreshes this every tick, so if the
        // weapon is switched away, the player dies, or prediction simply stops
        // calling us, the beam disappears on its own instead of hanging in the
        // air for the rest of the map.
        b.think     = CSQC_EnvBeam_LocalExpire;
        b.nextthink = time + 0.3;
    }
    return b;
};

// Mark a local beam's START as camera-relative rather than a world point, so it
// is re-resolved every render frame instead of every input frame.  `local_ofs` is
// (forward, right, up) in camera space -- the same convention the muzzle-flash
// sprite offsets use.  This is the port of HL's `entindex | 0x1000` attachment
// beams; call it on any SUSTAINED first-person beam, and leave one-shot flashes
// (the gauss) alone, where a stored point is correct and cheaper.
void(entity b, vector local_ofs) CSQC_EnvBeam_LocalAnchorToView =
{
    if (!b || b == world)
        return;
    b.eb_view_anchor = 1;
    b.eb_view_ofs    = local_ofs;
};

void(entity b) CSQC_EnvBeam_LocalKill =
{
    if (b && b != world)
        remove(b);
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

    // Re-derive a view-anchored muzzle against THIS frame's camera before any
    // geometry is built — the whole point is that it is never a stored world
    // point.  Done first so nothing below can observe the stale value, and the
    // makevectors basis it needs is consumed immediately.  See eb_view_anchor.
    if (self.eb_view_anchor)
    {
        vector cam_org = (vector)getproperty(VF_ORIGIN);
        makevectors((vector)getproperty(VF_ANGLES));
        self.eb_start_pos = cam_org
                          + v_forward * self.eb_view_ofs_x
                          + v_right   * self.eb_view_ofs_y
                          + v_up      * self.eb_view_ofs_z;
        // Keep the sort/cull origin in step with the ribbon it represents.
        setorigin(self, (self.eb_start_pos + self.eb_end_pos) * 0.5);
    }

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

            // Scale with brightness, as HL does: EV_FireGauss sizes the impact
            // glow by flDamage/255 (ev_hldm.cpp:1033), so a charged shot flares
            // and a tap does not.  This was a fixed 16 regardless.
            float hs = 16 * bound(0.5, self.eb_brightness / 255, 2.0);
            vector ep = self.eb_end_pos;

            // UNTINTED, deliberately.  HL draws the impact glow with kRenderGlow
            // at the sprite's own colour (ev_hldm.cpp:1011, :1033) — it is a hot
            // white-yellow flare, not a coloured one.  Feeding eb_color in here
            // stained the biggest bright area on screen with the beam's tint,
            // which is what made the gauss read as "the wrong orange" even
            // though the BEAM colour ('255 128 0') already matches the SDK.
            vector glow_col = '1 1 1';

            R_PolygonVertex(ep + view_right * -hs + view_up *  hs, '0 0 0', glow_col, self.eb_brightness);
            R_PolygonVertex(ep + view_right *  hs + view_up *  hs, '1 0 0', glow_col, self.eb_brightness);
            R_PolygonVertex(ep + view_right *  hs + view_up * -hs, '1 1 0', glow_col, self.eb_brightness);
            R_PolygonVertex(ep + view_right * -hs + view_up * -hs, '0 1 0', glow_col, self.eb_brightness);
            R_EndPolygon();
        }
    }

    return PREDRAW_NEXT;
};


// ============================================================================
//  RPG ROCKET FLARE  -  the sprite half of Half-Life's EF_LIGHT
// ----------------------------------------------------------------------------
//  const.h:110 names EF_LIGHT exactly: "rocket flare glow sprite".  rpg.cpp:201
//  sets it in CRpgRocket::IgniteThink -- so it appears when the MOTOR LIGHTS,
//  not at launch -- and rpg.cpp:304-307 clears it when the motor cuts out.
//
//  FTE does not implement the GoldSrc effects bits, so nothing drew it: the
//  rocket flew as a bare model with only its smoke ribbon behind it, which is
//  the "flickering sprite behind the rocket" that was missing.
//
//  IT LIVES HERE RATHER THAN IN cl_projectiles.qc for one mechanical reason:
//  spriteframe() and the DRAWFLAG_* constants are declared in this file, and
//  cl_projectiles.qc compiles BEFORE it (cl_progs.src :32 vs :34).  The dynamic
//  light half stays there, where it needs nothing from here.  Between them they
//  are EF_LIGHT: a glow sprite AND the light it casts.
//
//  The walk matches on .model so it catches BOTH copies -- the networked rocket
//  everyone else sees and the shooter's own CSQC-local fake, which is a
//  different entity with a different classname but necessarily the same model.
//  Without that the person who fired would be the only one seeing no flare,
//  which is the trap CSQC_Projectile_DrawLights documents at length.
// ============================================================================
void() CSQC_DrawRocketFlares =
{
    entity cur;
    vector fview_right, fview_up, fp;
    float flick, fhs;
    string fl_shader;

    fl_shader = spriteframe("sprites/glow01.spr", 0, time);
    if (fl_shader == "" || !fl_shader)
        fl_shader = "ebeam";

    // Camera basis once for the whole walk -- every flare is screen-aligned to
    // the same view, so re-deriving it per rocket would be pure waste.
    makevectors(getproperty(VF_ANGLES));
    fview_right = v_right;
    fview_up    = v_up;

    cur = nextent(world);
    while (cur)
    {
        if (cur.model == "models/rpgrocket.mdl")
        {
            // Same flicker expression as the light in cl_projectiles.qc, keyed
            // the same way, so the glow and the light pulse together instead of
            // beating against each other.
            flick = 0.82 + 0.18 * sin(cltime * 47 + num_for_edict(cur));
            fhs   = 9 * flick;

            // Behind the rocket along its own facing: the flare is exhaust, so
            // it belongs at the tail, not at the centre of the model.
            makevectors(cur.angles);
            fp = cur.origin - v_forward * 12;

            R_BeginPolygon(fl_shader, DRAWFLAG_ADD | DRAWFLAG_TWOSIDED);
            R_PolygonVertex(fp + fview_right * -fhs + fview_up *  fhs, '0 0 0', '1 0.66 0.30', 1);
            R_PolygonVertex(fp + fview_right *  fhs + fview_up *  fhs, '1 0 0', '1 0.66 0.30', 1);
            R_PolygonVertex(fp + fview_right *  fhs + fview_up * -fhs, '1 1 0', '1 0.66 0.30', 1);
            R_PolygonVertex(fp + fview_right * -fhs + fview_up * -fhs, '0 1 0', '1 0.66 0.30', 1);
            R_EndPolygon();
        }
        cur = nextent(cur);
    }
};
