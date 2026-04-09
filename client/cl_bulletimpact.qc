// ============================================================
//  client/cl_bulletimpact.qc  -  Bullet impact effects
//
//  Client-predicted impact light, particles, and ricochet sounds.
//  The shooter sees these instantly. Other players see them via
//  the server's CSQC_EVENT_IMPACT multicast (which already
//  excludes the shooter via dimension masking).
// ============================================================

// Forward declarations (defined in cl_bulletholes.qc)
void(vector hit_pos, vector hit_normal, entity hit_target) CSQC_SpawnBulletHole;

// Remove a client-side fake projectile entity
void() CSQC_FakeProjectileExpire =
{
    remove(self);
};

.vector fake_proj_hitpos;   // pre-traced wall hit position for fake projectiles
.string fake_proj_hitsnd;  // impact sound to play when fake projectile sticks

void(vector pos) CSQC_AddImpactLight;

// Stop a fake projectile at the wall — sticks in place, plays impact sound, then expires
void() CSQC_FakeProjectileStick =
{
    self.velocity = '0 0 0';
    self.movetype = MOVETYPE_NONE;
    setorigin(self, self.fake_proj_hitpos);

    // Play impact sound at hit location
    if (self.fake_proj_hitsnd != "")
        pointsound(self.fake_proj_hitpos, self.fake_proj_hitsnd, 1, ATTN_NORM);

    // Impact light + particles at hit point
    CSQC_AddImpactLight(self.fake_proj_hitpos);
    te_gunshot(self.fake_proj_hitpos);

    // Expire when server entity should arrive
    float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
    self.think = CSQC_FakeProjectileExpire;
    self.nextthink = time + bound(0.1, ping_est, 1.0) + 0.2;
};

const float IMPACT_LIGHT_RADIUS   = 60;
const float IMPACT_LIGHT_DURATION = 0.06;
const float IMPACT_LIGHT_MAX      = 8;   // max simultaneous impact lights

vector impact_light_pos[8];
float  impact_light_time[8];
float  impact_light_count;

void(vector pos) CSQC_AddImpactLight =
{
    float slot;

    slot = impact_light_count - floor(impact_light_count / IMPACT_LIGHT_MAX) * IMPACT_LIGHT_MAX;
    impact_light_pos[slot] = pos;
    impact_light_time[slot] = cltime;
    impact_light_count += 1;
};

// Called every render frame from CSQC_UpdateView, before renderscene()
void() CSQC_DrawImpactLights =
{
    float i, age, frac;

    for (i = 0; i < IMPACT_LIGHT_MAX; i++)
    {
        if (impact_light_time[i] <= 0)
            continue;

        age = cltime - impact_light_time[i];
        if (age >= IMPACT_LIGHT_DURATION)
        {
            impact_light_time[i] = 0;
            continue;
        }

        frac = 1.0 - (age / IMPACT_LIGHT_DURATION);
        dynamiclight_add(impact_light_pos[i], IMPACT_LIGHT_RADIUS * frac, '1 0.7 0.3' * frac);
    }
};

// Full bullet impact: particles + light + ricochet sound
// Called from hitscan prediction (CSQC_PredictedImpact / ShotgunImpact)
void(vector pos, vector normal) CSQC_BulletImpact =
{
    vector offset_pos;
    float r;

    // Pull effect off the surface so it's not flush against the wall
    offset_pos = pos + normal * 8;

    te_gunshot(offset_pos);
    CSQC_AddImpactLight(offset_pos);
    CSQC_SpawnBulletHole(pos, normal, trace_ent);

    // Random ricochet sound (ric1-5) at impact location
    r = floor(random() * 5) + 1;
    r = bound(1, r, 5);
    pointsound(offset_pos, sprintf("sounds/weapons/ric%g.wav", r), 1, ATTN_NORM);
    CSQC_RecordPredictedAutoSound();
};

// Silent bullet impact: particles + light only (no ricochet)
// Called from melee prediction (CSQC_PredictedMeleeTrace)
void(vector pos, vector normal) CSQC_BulletImpactSilent =
{
    vector offset_pos;

    offset_pos = pos + normal * 8;

    te_gunshot(offset_pos);
    CSQC_AddImpactLight(offset_pos);
    CSQC_SpawnBulletHole(pos, normal, trace_ent);
};

// Full impact for other players receiving server events
// Same as CSQC_BulletImpact but uses pointsound for positional audio
void(vector pos, vector normal) CSQC_BulletImpactRemote =
{
    vector offset_pos;
    float r;

    offset_pos = pos + normal * 8;

    te_gunshot(offset_pos);
    CSQC_AddImpactLight(offset_pos);
    CSQC_SpawnBulletHole(pos, normal, world);

    // Positional ricochet sound for other players
    r = floor(random() * 5) + 1;
    r = bound(1, r, 5);
    pointsound(offset_pos, sprintf("sounds/weapons/ric%g.wav", r), 1, ATTN_NORM);
};
