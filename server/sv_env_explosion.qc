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
    // (radius 260, damage 100, falloff to 25 at the edge).  Push
    // force / uplift mirror the HE values.
    if (!(self.spawnflags & EXPL_NO_DAMAGE))
    {
        float radius = magnitude * 2.6;
        float damage = magnitude;
        W_RadiusExplode(self.origin, radius, damage, damage * 0.25,
                        800, 350, world);
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

    // Precache assets the CSQC handler will look up.  Sprite + decal
    // textures are already precached by HE grenade / scorch wiring,
    // but precache them defensively in case env_explosion is on a map
    // without grenades or scorches yet.
    precache_model("gfx/eexplo.spr");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode3.wav");
};
