//
//  sv_env_explosion.qc  –  env_explosion  (HL/GoldSrc point entity)
//
//  Triggered by Trigger_UseTargets / direct +use.  Fires:
//    - fireball sprite     (gfx/eexplo.spr)
//    - explosion sound     (HE grenade boom)
//    - smoke puffs         (gfx/smoke, drift-up bursts)
//    - scorch decal        (gfx/scorch1, dropped onto nearest surface)
//    - particle sparks     (same effect as func_button SPARKS)
//    - radius damage       (peak = iMagnitude, falloff to 0 over radius)
//
//  Each visual element is gateable per the HL spec via spawnflag bits;
//  the sound is unconditional.  All visuals are CSQC-side via a single
//  multicast event so the multiple draw paths (sprite + smoke entity +
//  scorch + spark particles) live in one client handler.
//
//  Spawnflags:
//    1   NO_DAMAGE   – no W_RadiusExplode pass.
//    2   REPEATABLE  – do NOT remove the entity after firing; mapper
//                      can re-trigger any number of times.
//    4   NO_FIREBALL – skip the gfx/eexplo.spr sprite.
//    8   NO_SMOKE    – skip the smoke-puff burst emitter.
//    16  NO_DECAL    – skip the scorch decal.
//    32  NO_SPARKS   – skip the spark particles.
//
//  Keys:
//    "iMagnitude"  – power.  Default 100 (HE-grenade equivalent).  Scales
//                    radius linearly (radius = magnitude * 2.6).
//

// Forward decls — sh_pmove.qc + sv_weapons.qc compile after us.
void(vector center, float radius,
     float peak_damage, float min_damage,
     float push_force, float push_uplift,
     entity attacker) W_RadiusExplode;

// Mapper key — declared so the BSP entity-block parser populates it
// on the spawn entity.  Default 100 if unset (matches HL).
.float iMagnitude;

const float EXPL_NO_DAMAGE   = 1;
const float EXPL_REPEATABLE  = 2;
const float EXPL_NO_FIREBALL = 4;
const float EXPL_NO_SMOKE    = 8;
const float EXPL_NO_DECAL    = 16;
const float EXPL_NO_SPARKS   = 32;

// Split out of env_explosion's spawn function so a func_breakable carrying
// `explodemagnitude` can precache the same assets at MAP LOAD.  Without that
// the brush would only pull them in at the moment it breaks, which is a
// late-precache warning at best.
void() Explosion_Precache =
{
    // Sprite + decal textures are already precached by HE grenade / scorch
    // wiring, but precache them defensively in case the map has neither
    // grenades nor scorches.
    precache_model("gfx/eexplo.spr");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode3.wav");
};

void() env_explosion_fire =
{
    float magnitude = self.iMagnitude;
    if (magnitude <= 0) magnitude = 100;

    // Multicast the visual-effect event to every client in PVS of
    // the explosion.  CSQC handler dispatches the gateable elements
    // per spawnflags.  Always plays the boom sound on the receiving
    // client.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_EXPLOSION);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z);
    WriteShort(MSG_MULTICAST, magnitude);
    WriteByte(MSG_MULTICAST, self.spawnflags);
    multicast(self.origin, MULTICAST_PVS);

    // Server-side: radius damage if NO_DAMAGE not set.  Scaling is
    // tuned so the default magnitude=100 matches a HE grenade
    // (radius 260, damage 100, falloff to 25 at the edge).
    if (!(self.spawnflags & EXPL_NO_DAMAGE))
    {
        float radius = magnitude * 2.6;
        float damage = magnitude;

        // PULL THE BLAST CENTRE OUT OF THE SURFACE IT IS SITTING ON.
        //
        // A mapper drops an env_explosion ON a wall or floor, so its origin is
        // flush with (or just inside) solid brushwork.  W_RadiusExplode traces
        // from the blast centre to each victim, and a centre embedded in the
        // world means the trace starts solid and every victim is reported as
        // occluded — no damage, no push, for anybody.  Half-Life avoids this in
        // CEnvExplosion::Spawn (dlls/explode.cpp:170-186), which fires a
        // TraceLine straight down and, when it hits, lifts the entity to
        // `tr.vecEndPos + (tr.vecPlaneNormal * (m_iMagnitude - 24) * 0.6)`.
        //
        // Same idea, kept simple and symmetric: step out along the surface
        // normal of whatever we are touching.  8 units clears the epsilon that
        // makes a flush trace start solid without moving the blast far enough
        // to change who is in range.
        vector centre = self.origin;
        traceline(centre, centre - '0 0 24', TRUE, self);
        if (trace_fraction < 1)
            centre = trace_endpos + trace_plane_normal * 8;

        // ATTACKER, NOT `world`.  ExplosionCreate already stores the entity
        // that caused the blast in .owner (see below, and sv_breakable.qc's
        // exploding func_breakable, which passes the breaking brush) — passing
        // `world` here threw that away, so nothing could be credited, and any
        // consumer of the attacker in the damage chain saw the world entity.
        // Half-Life passes `pev` as both inflictor and attacker
        // (dlls/explode.cpp:214).
        entity blamed = self.owner;
        if (!blamed) blamed = self;

        W_RadiusExplode(centre, radius, damage, damage * 0.25,
                        // Knockback scaled by magnitude rather than a flat
                        // 800/350.  HL's blast impulse is proportional to the
                        // damage actually dealt, so a magnitude-30 charge used
                        // to shove exactly as hard as a magnitude-300 one.
                        // The constants are the HE grenade's values at its own
                        // magnitude of 100, so a default explosion is unchanged.
                        800 * (magnitude / 100), 350 * (magnitude / 100),
                        blamed);
    }

    // REPEATABLE off (default) — fire-and-forget; remove after the
    // event has been queued.
    if (!(self.spawnflags & EXPL_REPEATABLE))
        remove(self);
};

void() env_explosion_use = { env_explosion_fire(); };

/*QUAKED env_explosion (.5 .5 0) (-8 -8 -8) (8 8 8) NO_DAMAGE REPEATABLE NO_FIREBALL NO_SMOKE NO_DECAL NO_SPARKS
HL/GoldSrc-style point-entity explosion.  Triggered via Trigger_UseTargets.

"iMagnitude"  Explosion power (default 100; scales radius/damage).

NO_DAMAGE    Disable radius damage entirely.
REPEATABLE   Don't remove on first fire (allow multiple triggerings).
NO_FIREBALL  Disable the fireball sprite.
NO_SMOKE     Disable the smoke-puff burst.
NO_DECAL     Disable the scorch decal.
NO_SPARKS    Disable the spark particles.
*/
void() env_explosion =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = env_explosion_use;

    Explosion_Precache();
};

// ===========================================================================
//  ExplosionCreate — HL's explode.cpp:258, for code that needs to detonate
//  something without a mapper-placed env_explosion.
// ===========================================================================
//
// The SDK spawns a real env_explosion at the point, feeds it an iMagnitude and
// immediately Use()s it, which is exactly what this does — same entity, same
// fire path, so a breakable's blast and a mapper's env_explosion cannot drift
// apart.  Callers earlier in sv_progs.src than this file reach it by
// forward-declaring the FUNCTION (fields cannot be forward-declared, which is
// why .explodemagnitude lives in sv_customdefs.qc).
//
// The caller is responsible for having called Explosion_Precache() at map load
// — creating the entity here would otherwise precache mid-game.
// `expl_owner`, not `owner`: QC has ONE namespace for fields, locals and
// parameters, so a parameter called `owner` shadows the .owner FIELD and
// `e.owner = owner` fails to compile with "owner is not a field".
void(vector center, float magnitude, entity expl_owner) ExplosionCreate =
{
    entity e = spawn();
    e.classname  = "env_explosion";
    e.origin     = center;
    e.iMagnitude = magnitude;
    e.owner      = expl_owner;
    e.movetype   = MOVETYPE_NONE;
    e.solid      = SOLID_NOT;
    setorigin(e, center);

    // Fire it directly rather than through .use: env_explosion_fire reads
    // `self`, and it removes itself afterwards (REPEATABLE is not set here,
    // matching ExplosionCreate's fire-and-forget contract).
    entity oself = self;
    self = e;
    env_explosion_fire();
    self = oself;
};
