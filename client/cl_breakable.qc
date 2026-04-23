// ============================================================
//  client/cl_breakable.qc  -  Client-side breakable debris
//
//  Glass gibs use a GoldSrc model with 7 submodels (body groups).
//  Submodel selection requires setcustomskin() which is CSQC-only,
//  so glass debris is spawned here instead of on the server.
//
//  All other breakable debris (concrete, wood, metal, ...) also
//  spawns here via CSQC_EVENT_DEBRIS_GIBS, since the gibs are
//  cosmetic-only — keeping per-piece state off the wire saves the
//  long debris-lifetime entity-delta tail the old SSQC path paid.
// ============================================================

// Mirror of server-side BREAKABLE_* (sv_breakable.qc:21-26). Kept local
// because they aren't declared in shared scope.
const float BREAKABLE_METAL_CL    = 2;
const float BREAKABLE_WOOD_CL     = 3;
const float BREAKABLE_GLASS_CL    = 4;
const float BREAKABLE_MACHINE_CL  = 6;
const float BREAKABLE_CIRCUIT_CL  = 7;

// Tag written onto each csqc_debris gib so a mispredicted-break rollback
// in CSQC_BreakPredict_Expire can sweep only the ghost gibs that came
// from the predicted brush. 0 = server-authoritative spawn (never rolled
// back); non-zero = `num_for_edict` of the predicting brush.
.float owner_brush_entnum;

void() CSQC_GlassGibExpire =
{
    remove(self);
};

void(vector mins, vector maxs, float count, float damage_scale,
     float owner_entnum) CSQC_SpawnGlassGibs =
{
    float i;
    for (i = 0; i < count; i++)
    {
        entity gib = spawn();
        gib.classname = "csqc_debris";
        gib.owner_brush_entnum = owner_entnum;

        vector org;
        org_x = mins_x + (maxs_x - mins_x) * random();
        org_y = mins_y + (maxs_y - mins_y) * random();
        org_z = mins_z + (maxs_z - mins_z) * random();

        setmodel(gib, "models/gibs/glassgibs.mdl");
        setorigin(gib, org);
        setsize(gib, '0 0 0', '0 0 0');

        // Pick a random submodel variant (geomset is 1-indexed, 7 variants)
        float variant = 1 + floor(random() * 7);
        setcustomskin(gib, "", strcat("geomset 0 ", ftos(variant), "\n"));

        gib.velocity_x = (random() - 0.5) * (140 + damage_scale * 2);
        gib.velocity_y = (random() - 0.5) * (140 + damage_scale * 2);
        gib.velocity_z = 120 + random() * 160 + damage_scale;

        gib.movetype = MOVETYPE_BOUNCE;
        gib.solid = SOLID_NOT;
        gib.avelocity_x = random() * 600;
        gib.avelocity_y = random() * 600;
        gib.avelocity_z = random() * 600;
        gib.alpha = 0.35;
        gib.drawmask = MASK_ENGINE;

        gib.think = CSQC_GlassGibExpire;
        gib.nextthink = time + 10 + random() * 10;
    }
};

// ============================================================
//  Generic debris gibs — fired by CSQC_EVENT_DEBRIS_GIBS for
//  every non-glass breakable.  Mirrors the old SSQC spawn loop
//  in BreakableSpawnDebris but as local CSQC entities so no
//  per-piece state crosses the wire.
// ============================================================

// Lazy precache: server-side func_breakable already precaches these
// at spawn time, but on CSQC the models were never loaded (debris
// used to be SSQC entities). Resolve on first event so we don't pay
// precache cost on maps without breakables.
float csqc_debris_models_loaded;

void() CSQC_LoadDebrisModels =
{
    if (csqc_debris_models_loaded)
        return;
    precache_model("models/gibs/debris1.mdl");
    precache_model("models/gibs/debris2.mdl");
    precache_model("models/gibs/debris3.mdl");
    precache_model("models/gibs/woodgib1.mdl");
    precache_model("models/gibs/woodgib2.mdl");
    precache_model("models/gibs/woodgib3.mdl");
    csqc_debris_models_loaded = 1;
}

// Pick a random debris model path for the material.  Mirrors
// server-side BreakableRandomDebrisModel (now deleted).
string(float style) CSQC_DebrisModelForStyle =
{
    float v = random();
    if (style == BREAKABLE_WOOD_CL)
    {
        if (v < 0.333) return "models/gibs/woodgib1.mdl";
        if (v < 0.666) return "models/gibs/woodgib2.mdl";
        return "models/gibs/woodgib3.mdl";
    }
    if (v < 0.333) return "models/gibs/debris1.mdl";
    if (v < 0.666) return "models/gibs/debris2.mdl";
    return "models/gibs/debris3.mdl";
}

// Random frame index appropriate for the material.  Metal/machine/
// circuit roll 0-2 (small/big/flat); everything else rolls 0-1.
float(float style) CSQC_DebrisFrameForStyle =
{
    if (style == BREAKABLE_METAL_CL
        || style == BREAKABLE_MACHINE_CL || style == BREAKABLE_CIRCUIT_CL)
        return floor(random() * 3);
    return floor(random() * 2);
}

void(vector mins, vector maxs, float style, float count, float damage_scale,
     float custom_idx, float alpha_byte, float owner_entnum) CSQC_SpawnDebrisGibs =
{
    CSQC_LoadDebrisModels();

    float i;
    for (i = 0; i < count; i++)
    {
        entity gib = spawn();
        gib.classname = "csqc_debris";
        gib.owner_brush_entnum = owner_entnum;

        vector org;
        org_x = mins_x + (maxs_x - mins_x) * random();
        org_y = mins_y + (maxs_y - mins_y) * random();
        org_z = mins_z + (maxs_z - mins_z) * random();

        if (custom_idx)
            setmodelindex(gib, custom_idx);
        else
            setmodel(gib, CSQC_DebrisModelForStyle(style));

        setorigin(gib, org);
        setsize(gib, '0 0 0', '0 0 0');

        gib.velocity_x = (random() - 0.5) * (140 + damage_scale * 2);
        gib.velocity_y = (random() - 0.5) * (140 + damage_scale * 2);
        gib.velocity_z = 120 + random() * 160 + damage_scale;

        gib.movetype  = MOVETYPE_BOUNCE;
        gib.solid     = SOLID_NOT;
        gib.avelocity_x = random() * 600;
        gib.avelocity_y = random() * 600;
        gib.avelocity_z = random() * 600;
        gib.drawmask  = MASK_ENGINE;

        if (style == BREAKABLE_WOOD_CL || custom_idx)
        {
            gib.skin  = 0;
            gib.frame = 0;
        }
        else
        {
            gib.skin  = style;
            gib.frame = CSQC_DebrisFrameForStyle(style);
        }

        if (alpha_byte)
            gib.alpha = alpha_byte / 255;

        gib.think     = CSQC_GlassGibExpire;   // generic remove(self) cleanup
        gib.nextthink = time + 10 + random() * 10;
    }
};

// ============================================================
//  Player gibs — fired by CSQC_EVENT_PLAYER_GIBS when a killing
//  blow clears sv_gib_threshold. Uses fleshgibs.mdl (single
//  multi-submodel asset) and adds a per-gib blood-drip trail
//  via the "bloodtrail" particle defined in particles/weapons.cfg.
// ============================================================

// Engine-defined field for auto-attached particle trails (DP_ENT_TRAILEFFECTNUM).
// The CSQC sysdefs file in this mod doesn't declare it explicitly — add it here.
.float traileffectnum;

// Lazy lookup: r_particledesc is queued at end-of-frame from CSQC_Init,
// so particle effects aren't registered until after init completes.
// Resolve on first call instead of eager-precaching.
float playergib_bloodtrail_id;
float playergib_bloodtrail_resolved;
float playergib_bloodsplat_id;
float playergib_bloodsplat_resolved;

// The weapons particle set is loaded at menu-VM init (data/default.cfg
// execs particles/weapons.cfg into the "weapons" namespace).  By the
// time CSQC runs these resolvers, every effect is registered, so a
// single lookup returns a valid slot index.  Zero means the CSQC slot
// table is full — treat as transient and retry.
float() PlayerGib_GetBloodTrail =
{
    if (!playergib_bloodtrail_resolved)
    {
        float id = particleeffectnum("weapons.bloodtrail");
        if (id == 0)
            return 0;   // slot table full — retry on next call
        playergib_bloodtrail_id = id;
        playergib_bloodtrail_resolved = 1;
    }
    return playergib_bloodtrail_id;
};

float() PlayerGib_GetBloodSplat =
{
    if (!playergib_bloodsplat_resolved)
    {
        float id = particleeffectnum("weapons.gibsplat");
        if (id == 0)
            return 0;   // slot table full — retry on next call
        playergib_bloodsplat_id = id;
        playergib_bloodsplat_resolved = 1;
    }
    return playergib_bloodsplat_id;
};

// dir = unit vector along the killing shot (attacker → victim).
// Gibs fan out around dir with random spread; each gets a trail.
void(vector pos, vector dir, float count, float damage_scale) CSQC_SpawnPlayerGibs =
{
    // Resolve effect IDs once (lazy). Both used below.
    float trail_id = PlayerGib_GetBloodTrail();

    // Initial big blood spray at the impact point — front-loads the gore.
    pointparticles(PlayerGib_GetBloodSplat(), pos, dir * 200, 1);

    // Pre-play a wet flesh-burst sound (one of two HL flesh break sounds).
    if (random() < 0.5)
        pointsound(pos, "sounds/debris/break_fleshhl1.wav", 1, ATTN_NORM);
    else
        pointsound(pos, "sounds/debris/break_fleshhl2.wav", 1, ATTN_NORM);

    float i;
    for (i = 0; i < count; i++)
    {
        entity gib = spawn();
        gib.classname = "csqc_debris";

        setmodel(gib, "models/gibs/human/fleshgibs.mdl");
        setorigin(gib, pos);
        setsize(gib, '0 0 0', '0 0 0');

        // Pick a random submodel variant for visual variety.
        // fleshgibs.mdl variants are 1-indexed; clamp to a safe upper bound.
        float variant = 1 + floor(random() * 5);
        setcustomskin(gib, "", strcat("geomset 0 ", ftos(variant), "\n"));

        // Velocity: bias along killing-shot direction + random fan.
        // Stronger overkill = stronger spread.
        float spread = 180 + damage_scale * 1.5;
        gib.velocity_x = dir_x * (120 + damage_scale) + (random() - 0.5) * spread;
        gib.velocity_y = dir_y * (120 + damage_scale) + (random() - 0.5) * spread;
        gib.velocity_z = 200 + random() * 180 + damage_scale * 0.5;

        gib.movetype = MOVETYPE_BOUNCE;
        gib.solid = SOLID_NOT;
        gib.avelocity_x = (random() - 0.5) * 1200;
        gib.avelocity_y = (random() - 0.5) * 1200;
        gib.avelocity_z = (random() - 0.5) * 1200;
        gib.drawmask = MASK_ENGINE;

        // Attach the dripping blood trail.
        gib.traileffectnum = trail_id;

        gib.think = CSQC_GlassGibExpire;
        gib.nextthink = time + 8 + random() * 7;
    }
};

void() CSQC_PrecacheBreakables =
{
    precache_model("models/gibs/glassgibs.mdl");
    precache_model("models/gibs/human/fleshgibs.mdl");
    precache_sound("sounds/debris/break_fleshhl1.wav");
    precache_sound("sounds/debris/break_fleshhl2.wav");
    // Particle effect IDs are looked up lazily on first use — see
    // PlayerGib_GetBloodTrail / PlayerGib_GetBloodSplat above.
    // r_particledesc is set via localcmd from CSQC_Init, so the effects
    // aren't registered yet at the time this function runs.
};
