// ============================================================
//  shared/sh_shockwave.qc  -  GoldSrc TE_BEAMCYLINDER / TE_IMPLOSION
//
//  The houndeye's sonic blast is the only attack in the base game whose
//  ENTIRE visual is a temp entity: houndeye.cpp:559-611 writes two
//  TE_BEAMCYLINDER rings and nothing else, and RunTask writes a
//  TE_IMPLOSION every frame of the 2.4-second wind-up.  This engine has
//  neither temp entity (grep BEAMCYLINDER across engine/ returns nothing),
//  so the blast landed damage and made a noise while being completely
//  invisible - "I can't visually see their attack".
//
//  Drawn the same way env_beam's RING mode is drawn (cl_env_beam.qc), for
//  the same reasons documented at length there: the sprite's pixels are
//  only reachable through spriteframe(), and the "_beam" shader variant is
//  required because the auto-generated sprite shader alpha-tests and
//  depth-writes, which an additive ribbon must not do.
// ============================================================

const float SHOCKWAVE_EXPAND  = 0;      // ring grows 0 -> radius   (TE_BEAMCYLINDER)
const float SHOCKWAVE_IMPLODE = 1;      // ring shrinks radius -> 0 (TE_IMPLOSION)

const string SHOCKWAVE_SPRITE = "sprites/shockwave.spr";

#ifdef SSQC

// pos      centre of the ring
// radius   world units at full extent
// life     seconds the ring is visible
// width    ribbon width in world units (HL's TE_BEAMCYLINDER width byte)
// colour   0..255 RGB, straight off WriteBeamColor
// kind     SHOCKWAVE_EXPAND / SHOCKWAVE_IMPLODE
void(vector pos, float radius, float life, float width, vector colour, float kind) Shockwave_Multicast =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_SHOCKWAVE);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    // SHORT.  The houndeye's outer ring is 384 units and a gargantua stomp
    // would be larger still; a byte would wrap every ring in the game.
    WriteShort(MSG_MULTICAST, radius);
    WriteByte(MSG_MULTICAST, bound(1, floor(life * 20 + 0.5), 255));   // 1/20 s units
    WriteByte(MSG_MULTICAST, bound(1, floor(width + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(colour_x + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(colour_y + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(colour_z + 0.5), 255));
    WriteByte(MSG_MULTICAST, kind);
    // PHS, not PVS.  This is a blast the player is meant to react to, and a
    // houndeye that thumps around a corner should still put a ring through
    // the doorway - which is exactly the set MSG_PAS names in HL.
    multicast(pos, MULTICAST_PHS);
};

#endif // SSQC

#ifdef CSQC

// 28 segments is what cl_env_beam.qc uses for its rings and the two are drawn
// side by side often enough (an env_beam RING and a houndeye blast in the same
// room) that matching the tessellation matters more than tuning it.
const float SHOCKWAVE_SEGMENTS = 28;

.float sw_radius;
.float sw_life;
.float sw_born;
.float sw_width;
.vector sw_colour;      // 0..1
.float sw_kind;

float() CSQC_Shockwave_Predraw =
{
    float age = cltime - self.sw_born;
    if (age >= self.sw_life)
    {
        remove(self);
        return PREDRAW_NEXT;
    }

    float frac = age / self.sw_life;

    // The RADIUS ramp and the ALPHA ramp are deliberately different curves.
    //
    // GoldSrc's R_BeamCylinder steps the radius linearly and fades the beam on
    // its own life curve; a linear radius on a 0.2 s ring reads as a hard disc
    // popping into place, because the eye tracks the leading edge and a linear
    // edge has no deceleration.  sqrt() front-loads the expansion so the ring
    // leaves the houndeye fast and settles at the rim, which is what makes the
    // damage radius legible - and the radius IS the gameplay information here.
    float r = self.sw_radius * ((self.sw_kind == SHOCKWAVE_IMPLODE)
                                ? (1 - frac)
                                : sqrt(frac));
    if (r < 1)
        return PREDRAW_NEXT;

    // Quadratic fade.  A linear alpha on an additive ribbon stays visible far
    // too long against a dark HL corridor.
    float alpha = (1 - frac) * (1 - frac);

    string sh = spriteframe(SHOCKWAVE_SPRITE, 0, cltime);
    if (sh == "" || !sh)
        sh = "ebeam";
    else
        sh = strcat(sh, "_beam");   // see CSQC_EnvBeam_ShaderName

    R_BeginPolygon(sh, DRAWFLAG_ADD | DRAWFLAG_TWOSIDED);

    float i;
    for (i = 0; i <= SHOCKWAVE_SEGMENTS; i = i + 1)
    {
        float t = i / SHOCKWAVE_SEGMENTS;
        float a = t * 2 * M_PI;
        vector p = self.origin + [cos(a) * r, sin(a) * r, 0];

        // S is pinned by the ribbon bias below; T runs around the loop so the
        // sprite tiles along the circumference rather than being stretched
        // once around a 384-unit ring.
        float tex_t = t * 4;
        R_PolygonVertex(p, [0, tex_t - floor(tex_t), 0], self.sw_colour, alpha);
    }
    R_EndPolygonRibbon(self.sw_width * 0.5, '1 0 0');

    return PREDRAW_NEXT;
};

void() CSQC_Shockwave_Parse =
{
    vector pos;
    pos_x = readcoord();
    pos_y = readcoord();
    pos_z = readcoord();
    float radius = readshort();
    float life   = readbyte() * 0.05;
    float width  = readbyte();
    float r      = readbyte();
    float g      = readbyte();
    float b      = readbyte();
    float kind   = readbyte();

    entity sw = spawn();
    setorigin(sw, pos);
    // No model: the predraw builds every vertex itself.  setmodel("") also
    // clears whatever this recycled slot was drawing before.
    setmodel(sw, "");
    sw.classname = "shockwave";
    sw.drawmask  = MASK_ENGINE;
    sw.predraw   = CSQC_Shockwave_Predraw;
    sw.sw_radius = radius;
    sw.sw_life   = life;
    sw.sw_born   = cltime;
    sw.sw_width  = width;
    sw.sw_colour = [r / 255, g / 255, b / 255];
    sw.sw_kind   = kind;

    // A ring 384 units across is not inside the 0-sized bbox its origin
    // implies, and the engine culls predraw entities on that box.  Give it the
    // full extent so a blast centred just out of sight still draws the arc that
    // reaches the player.
    setsize(sw, [-radius, -radius, -width], [radius, radius, width]);
};

#endif // CSQC
