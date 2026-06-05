//
//  cl_env_explosion.qc  –  CSQC FX dispatch for env_explosion
//
//  Receives CSQC_EVENT_ENV_EXPLOSION (multicast from sv_env_explosion.qc)
//  and fires the per-element FX gated by spawnflag bits.  Sound is
//  unconditional (HL spec).  Smoke is a slow burst emitter — 5 puffs
//  every 0.5 s for ~3 s — using the same gfx/smoke material the
//  smoke grenade and muzzle smoke use, so the puffs drift up, grow
//  and fade out the same way.
//

// Forward decls from sh_wpn_csgrenades.qc (CSQC half) — both compile
// before this file but the QCC parser still wants the forward look-up.
void(vector pos, float sample) CSQC_SpawnCSGrenadeSprite;
void(vector pos)               CSQC_SpawnSmokePuff;

// Forward decls from cl_scorch.qc.
void(vector pos, float kind)   CSQC_SpawnScorchDecal;

// Forward decls from cl_bulletimpact.qc — populated by Impact_ResolveAll
// at first use; mirrors the CSQC_EVENT_BUTTON_SPARK lookup pattern.
void()  Impact_ResolveAll;
float   impact_effect_metal;

// env_explosion spawnflag bits — must match sv_env_explosion.qc.
const float EE_NO_DAMAGE   = 1;
const float EE_REPEATABLE  = 2;
const float EE_NO_FIREBALL = 4;
const float EE_NO_SMOKE    = 8;
const float EE_NO_DECAL    = 16;
const float EE_NO_SPARKS   = 32;

// Per-emitter state for the 0.5-s smoke-burst timer.
.float  ee_remaining_bursts;
.vector ee_smoke_origin;

// Tick handler — spawns 5 puffs each call, decrements the burst
// counter, reschedules every 0.5 s, removes itself when done.
void() CSQC_EnvExplosionSmokeTick =
{
    if (self.ee_remaining_bursts <= 0)
    {
        remove(self);
        return;
    }

    float i = 0;
    while (i < 5)
    {
        CSQC_SpawnSmokePuff(self.ee_smoke_origin);
        i = i + 1;
    }

    self.ee_remaining_bursts = self.ee_remaining_bursts - 1;
    self.nextthink = time + 0.5;
};

// Spawn a smoke-burst emitter at `pos`.  Does 6 bursts × 5 puffs over
// ~3 s, matching the user-requested cadence.  Each puff uses the
// existing CSQC_SpawnSmokePuff which already handles drift-up, grow
// and fade-out — same look as the muzzle barrel smoke and the smoke
// grenade.  Origin is pulled down 8 qu so the puffs hug the ground
// instead of sinking through it.
void(vector pos) CSQC_EnvExplosionSpawnSmokeEmitter =
{
    entity emit = spawn();
    emit.classname           = "env_explosion_smoke_emit";
    emit.ee_smoke_origin     = pos - '0 0 8';
    emit.ee_remaining_bursts = 6;
    emit.think               = CSQC_EnvExplosionSmokeTick;
    emit.nextthink           = time;
};

// Fire ~12 spark bursts in random outward directions at `pos`.  Same
// pointparticles call shape as CSQC_EVENT_BUTTON_SPARK uses, scaled up
// in count + spread because an explosion casts sparks omnidirectionally
// vs a button's narrow press-face emit.
void(vector pos) CSQC_EnvExplosionSpawnSparks =
{
    Impact_ResolveAll();
    float spark_id = impact_effect_metal;
    if (spark_id == 0)
        spark_id = particleeffectnum("weapons.metal_impact");
    if (spark_id == -1 || spark_id == 0)
        return;

    float i = 0;
    while (i < 12)
    {
        vector dir;
        dir_x = (random() * 2) - 1;
        dir_y = (random() * 2) - 1;
        dir_z = random() * 0.8 + 0.1;   // bias slightly upward
        dir = normalize(dir);
        pointparticles(spark_id, pos, dir * 300, 1);
        i = i + 1;
    }
};

// Pick a random HE-grenade explode WAV (the assets are already
// precached for HE grenades / by sv_env_explosion's spawn).  Sound
// is unconditional per HL spec — no spawnflag gates this.
string() CSQC_EnvExplosionPickSound =
{
    float r = floor(random() * 3);
    if (r == 0) return "sounds/weapons/wpn_cshegrenade/explode1.wav";
    if (r == 1) return "sounds/weapons/wpn_cshegrenade/explode2.wav";
    return "sounds/weapons/wpn_cshegrenade/explode3.wav";
};

// Top-level dispatch from cl_main.qc CSQC_ParseGameEvent.
void(vector pos, float magnitude, float spawnflags) CSQC_EnvExplosionFX =
{
    // Sound — always plays.
    pointsound(pos, CSQC_EnvExplosionPickSound(), 1, ATTN_NORM);

    if (!(spawnflags & EE_NO_FIREBALL))
        CSQC_SpawnCSGrenadeSprite(pos, 0);   // gfx/eexplo.spr

    if (!(spawnflags & EE_NO_SMOKE))
        CSQC_EnvExplosionSpawnSmokeEmitter(pos);

    if (!(spawnflags & EE_NO_DECAL))
        CSQC_SpawnScorchDecal(pos, 1);       // gfx/scorch1

    if (!(spawnflags & EE_NO_SPARKS))
        CSQC_EnvExplosionSpawnSparks(pos);
};
