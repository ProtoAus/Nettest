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

// Mirror of server-side BREAKABLE_* (sv_breakable.qc:32-50).  Kept local
// because they aren't declared in shared scope.  These are the
// gameplay-facing style numbers — see CSQC_DebrisSkinForStyle below
// for the translation to the debris model's baked skin order.
const float BREAKABLE_GLASS_CL              = 0;
const float BREAKABLE_WOOD_CL               = 1;
const float BREAKABLE_METAL_CL              = 2;
const float BREAKABLE_FLESH_CL              = 3;
const float BREAKABLE_CINDER_CL             = 4;
const float BREAKABLE_TILE_CL               = 5;
const float BREAKABLE_COMPUTER_CL           = 6;
const float BREAKABLE_UNBREAKABLE_GLASS_CL  = 7;
const float BREAKABLE_ROCKS_CL              = 8;

// Debris model skins are baked in this order:
//   0=concrete, 1=rock, 2=metal, 3=wood, 4=glass, 5=flesh,
//   6=machine, 7=circuit
// The new gameplay style numbers don't line up with that order, so
// we translate at debris-spawn time.  Unbreakable glass never spawns
// debris (gated on the server) but is included for completeness.
float(float style) CSQC_DebrisSkinForStyle =
{
    if (style == BREAKABLE_GLASS_CL)             return 4;
    if (style == BREAKABLE_WOOD_CL)              return 3;
    if (style == BREAKABLE_METAL_CL)             return 2;
    if (style == BREAKABLE_FLESH_CL)             return 5;
    if (style == BREAKABLE_CINDER_CL)            return 0;   // concrete skin
    if (style == BREAKABLE_TILE_CL)              return 3;   // wood skin
    if (style == BREAKABLE_COMPUTER_CL)          return 7;   // circuit skin
    if (style == BREAKABLE_UNBREAKABLE_GLASS_CL) return 4;
    if (style == BREAKABLE_ROCKS_CL)             return 1;
    return 0;
};

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
     float owner_entnum,
     float throw_mode, vector throw_dir, float throw_force) CSQC_SpawnGlassGibs =
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

        if (throw_mode > 0)
        {
            // Directional: dominant component along the damage
            // direction scaled by force, plus a small jitter so
            // the gibs don't visibly travel in a clean line.
            float jitter_xy = throw_force * 0.4;
            float jitter_z  = throw_force * 0.25;
            gib.velocity_x = throw_dir_x * throw_force + (random() - 0.5) * jitter_xy;
            gib.velocity_y = throw_dir_y * throw_force + (random() - 0.5) * jitter_xy;
            gib.velocity_z = throw_dir_z * throw_force + 60 + random() * jitter_z;
        }
        else
        {
            gib.velocity_x = (random() - 0.5) * (140 + damage_scale * 2);
            gib.velocity_y = (random() - 0.5) * (140 + damage_scale * 2);
            gib.velocity_z = 120 + random() * 160 + damage_scale;
        }

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

// Pick a random debris model path for the material.  WOOD and TILE
// both pull from the woodgibs set (TILE's "use wood" alias from the
// material spec).  Everything else uses the generic debris models.
string(float style) CSQC_DebrisModelForStyle =
{
    float v = random();
    if (style == BREAKABLE_WOOD_CL || style == BREAKABLE_TILE_CL)
    {
        if (v < 0.333) return "models/gibs/woodgib1.mdl";
        if (v < 0.666) return "models/gibs/woodgib2.mdl";
        return "models/gibs/woodgib3.mdl";
    }
    if (v < 0.333) return "models/gibs/debris1.mdl";
    if (v < 0.666) return "models/gibs/debris2.mdl";
    return "models/gibs/debris3.mdl";
}

// Random frame index appropriate for the material.  Metal and
// COMPUTER (alias for the old "machine/circuit" pool) roll 0-2
// (small / big / flat); everything else rolls 0-1.
float(float style) CSQC_DebrisFrameForStyle =
{
    if (style == BREAKABLE_METAL_CL || style == BREAKABLE_COMPUTER_CL)
        return floor(random() * 3);
    return floor(random() * 2);
}

void(vector mins, vector maxs, float style, float count, float damage_scale,
     float custom_idx, float alpha_byte, float owner_entnum,
     float throw_mode, vector throw_dir, float throw_force) CSQC_SpawnDebrisGibs =
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

        if (throw_mode > 0)
        {
            // Directional: dominant component along the damage
            // direction scaled by force, plus a small jitter so the
            // gibs read as scattered rather than a single line.
            float jitter_xy = throw_force * 0.4;
            float jitter_z  = throw_force * 0.25;
            gib.velocity_x = throw_dir_x * throw_force + (random() - 0.5) * jitter_xy;
            gib.velocity_y = throw_dir_y * throw_force + (random() - 0.5) * jitter_xy;
            gib.velocity_z = throw_dir_z * throw_force + 60 + random() * jitter_z;
        }
        else
        {
            gib.velocity_x = (random() - 0.5) * (140 + damage_scale * 2);
            gib.velocity_y = (random() - 0.5) * (140 + damage_scale * 2);
            gib.velocity_z = 120 + random() * 160 + damage_scale;
        }

        gib.movetype  = MOVETYPE_BOUNCE;
        gib.solid     = SOLID_NOT;
        gib.avelocity_x = random() * 600;
        gib.avelocity_y = random() * 600;
        gib.avelocity_z = random() * 600;
        gib.drawmask  = MASK_ENGINE;

        if (style == BREAKABLE_WOOD_CL || style == BREAKABLE_TILE_CL || custom_idx)
        {
            // Woodgibs / tile / custom debris models — single-skin /
            // single-frame at index 0.
            gib.skin  = 0;
            gib.frame = 0;
        }
        else
        {
            // Translate the gameplay style number to the debris
            // model's baked skin index (the model artist's order
            // doesn't match the new style numbering).
            gib.skin  = CSQC_DebrisSkinForStyle(style);
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
//  multi-submodel asset) and adds a per-gib blood-drip stream.
// ============================================================

// Engine-defined field for auto-attached particle trails (DP_ENT_TRAILEFFECTNUM).
// The CSQC sysdefs file in this mod doesn't declare it explicitly — add it here.
.float traileffectnum;

const float  PLAYERGIB_THINK_STEP          = 0.04;
const float  PLAYERGIB_BOUNCE_DAMP         = 0.28;
const float  PLAYERGIB_AVEL_DAMP           = 0.45;
const float  PLAYERGIB_TANGENT_DAMP        = 0.52;
const float  PLAYERGIB_SETTLE_SPEED        = 70;
const float  PLAYERGIB_MAX_BOUNCES         = 4;
const float  PLAYERGIB_BOUNCE_BLOOD_DELAY  = 0.07;
// Two-phase emission: dense initial spray (mimics the burst of
// blood right after the head bursts) then a tapered trickle that
// dies out.  Per-gib spray length is randomised within
// SPRAY_DURATION_MIN..MAX so all six gibs don't transition to the
// trickle on the same frame.
const float  PLAYERGIB_SPRAY_INTERVAL      = 0.01;   // 100 Hz
const float  PLAYERGIB_SPRAY_DURATION_MIN  = 0.05;
const float  PLAYERGIB_SPRAY_DURATION_MAX  = 0.25;
const float  PLAYERGIB_DRIP_INTERVAL       = 0.10;   //  10 Hz
const float  PLAYERGIB_DRIP_DURATION       = 0.80;
// Drops inherit this fraction of the gib's instantaneous velocity at
// emission time so they trail behind the gib instead of dropping
// straight down from its centre.  Low value (15%) keeps gravity
// dominant within ~200 ms so drops settle quickly under the gib.
const float  PLAYERGIB_DRIP_VEL_INHERIT    = 0.15;
// Spinning-object scatter — each emission rotates a horizontal
// "throw direction" by PHASE_STEP radians and adds a small tangential
// velocity to the drop along that direction.  Amplitude scales with
// the gib's |avelocity| (faster spinning gibs throw blood wider),
// capped at SCATTER_MAX so a max-spin gib doesn't fling drops 100+
// units sideways.  PHASE_STEP at 0.7 rad ≈ 40° per drop, so a full
// 360° rotation completes in ~9 drops — visible as a curved trail
// when consecutive drops fall and land.
const float  PLAYERGIB_DRIP_SCATTER_SCALE  = 0.012;
const float  PLAYERGIB_DRIP_SCATTER_MAX    = 50;
const float  PLAYERGIB_DRIP_PHASE_STEP     = 0.7;
const float  PLAYERGIB_GRAVITY             = 800;
const float  PLAYERGIB_DRIP_COLOR          = 73;
const float  PLAYERGIB_DRIP_COUNT          = 1;
const float  PLAYERGIB_SPAWN_Z_SPREAD      = 18;
const float  PLAYERGIB_LAUNCH_Z_JITTER     = 70;
const float  PLAYERGIB_DRIP_DROP_SIZE      = 1.1;
// In-flight TTL: max time a drop is allowed to fall before being
// removed without ever landing.  Generous so a drop spawned high
// above a pit still has time to reach the floor before timing out.
const float  PLAYERGIB_DRIP_DROP_TTL       = 5.0;
// Post-landing fade window — drop sits on the floor at full alpha
// then linearly fades to 0 over this many seconds.  Per the spec:
// "fade out after 3 seconds" once landed.
const float  PLAYERGIB_DRIP_DROP_LAND_TIME = 3.0;
const string PLAYERGIB_DRIP_DROP_SHADER    = "gfx/blood/blooddrop";

.float playergib_expire_time;
.float playergib_next_drip_time;
.float playergib_next_blood_time;
.float playergib_bounce_count;
.float playergib_landed_blood;
.float playergib_last_time;
.float playergib_settled;
// playergib_spray_end_time — cltime at which the per-gib 100 Hz
//   spray phase yields to the 10 Hz trickle (random in
//   SPRAY_DURATION_MIN..MAX so the 6 gibs stagger their transitions).
// playergib_drip_end_time — cltime at which all blood emission stops
//   for this gib (spray_end_time + DRIP_DURATION).
// playergib_drip_phase — radians; advances PHASE_STEP per emission,
//   feeds sin/cos for the rotating-direction scatter perturbation
//   on each drop (the "spinning object slinging blood" effect).
.float playergib_spray_end_time;
.float playergib_drip_end_time;
.float playergib_drip_phase;

.float blooddrop_expire_time;
.float blooddrop_last_time;
.float blooddrop_landed;
.float blooddrop_landed_time;

// Lazy lookup: r_particledesc is queued at end-of-frame from CSQC_Init,
// so particle effects aren't registered until after init completes.
// Resolve on first call instead of eager-precaching.
float playergib_bloodsplat_id;
float playergib_bloodsplat_resolved;

// The weapons particle set is loaded at menu-VM init (data/default.cfg
// execs particles/weapons.cfg into the "weapons" namespace).  By the
// time CSQC runs these resolvers, every effect is registered, so a
// single lookup returns a valid slot index.  Zero means the CSQC slot
// table is full — treat as transient and retry.
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

float() CSQC_PlayerBloodDropPredraw =
{
    float now = cltime;
    if (now >= self.blooddrop_expire_time)
    {
        remove(self);
        return PREDRAW_NEXT;
    }

    float dt = now - self.blooddrop_last_time;
    if (dt < 0) dt = 0;
    if (dt > 0.05) dt = 0.05;
    self.blooddrop_last_time = now;

    if (!self.blooddrop_landed && dt > 0)
    {
        vector old_origin = self.origin;
        self.velocity_z = self.velocity_z - PLAYERGIB_GRAVITY * dt;
        vector end = self.origin + self.velocity * dt;

        entity saved_ent           = trace_ent;
        float  saved_fraction      = trace_fraction;
        vector saved_endpos        = trace_endpos;
        vector saved_plane_normal  = trace_plane_normal;
        float  saved_plane_dist    = trace_plane_dist;
        float  saved_inopen        = trace_inopen;
        float  saved_inwater       = trace_inwater;

        traceline(old_origin, end, MOVE_NOMONSTERS, self);
        float  hit_fraction = trace_fraction;
        vector hit_pos      = trace_endpos;
        vector hit_normal   = trace_plane_normal;

        trace_ent           = saved_ent;
        trace_fraction      = saved_fraction;
        trace_endpos        = saved_endpos;
        trace_plane_normal  = saved_plane_normal;
        trace_plane_dist    = saved_plane_dist;
        trace_inopen        = saved_inopen;
        trace_inwater       = saved_inwater;

        if (hit_fraction < 1 && vlen(hit_normal) > 0)
        {
            setorigin(self, hit_pos + normalize(hit_normal) * 0.35);
            self.velocity = '0 0 0';
            self.blooddrop_landed = 1;
            self.blooddrop_landed_time = now;
            self.blooddrop_expire_time = now + PLAYERGIB_DRIP_DROP_LAND_TIME;
        }
        else
        {
            setorigin(self, end);
        }
    }

    float alpha = 1.0;
    float half = PLAYERGIB_DRIP_DROP_SIZE;
    if (self.blooddrop_landed)
    {
        alpha = 1.0 - (now - self.blooddrop_landed_time)
            / PLAYERGIB_DRIP_DROP_LAND_TIME;
        half = half * 0.85;
    }
    if (alpha <= 0)
    {
        remove(self);
        return PREDRAW_NEXT;
    }

    makevectors(getproperty(VF_ANGLES));
    vector right = v_right * half;
    vector up = v_up * half;
    vector colour = '0.26 0.015 0.008';

    R_BeginPolygon(PLAYERGIB_DRIP_DROP_SHADER, 0, 0);
    R_PolygonVertex(self.origin - right - up, '0 1 0', colour, alpha);
    R_PolygonVertex(self.origin + right - up, '1 1 0', colour, alpha);
    R_PolygonVertex(self.origin + right + up, '1 0 0', colour, alpha);
    R_PolygonVertex(self.origin - right + up, '0 0 0', colour, alpha);
    R_EndPolygon();

    return PREDRAW_NEXT;
};

void(vector pos, vector vel) CSQC_SpawnPlayerBloodDrop =
{
    entity drop = spawn();
    drop.classname = "csqc_blooddrop";
    setorigin(drop, pos);
    setsize(drop, '0 0 0', '0 0 0');
    drop.movetype = MOVETYPE_NONE;
    drop.solid = SOLID_NOT;
    // MUST be in MASK_ENGINE — predraw fires from addentities(mask)
    // only when (drawmask & mask) is nonzero.  Without this the
    // R_BeginPolygon render call AND the expire / remove(self) check
    // are both dead code: the entity sits invisibly forever (visible
    // as a persistent r_showbboxes 1 dot at the spawn point) and the
    // polygon is never emitted.
    drop.drawmask = MASK_ENGINE;
    // Seed velocity from the caller (15% of gib velocity) so the
    // first few frames of fall trail behind the moving gib instead
    // of dropping straight down from its origin — sells the "blood
    // coming OFF the gib" look.  Gravity in the predraw catches up
    // within ~200 ms.
    drop.velocity = vel;
    drop.predraw = CSQC_PlayerBloodDropPredraw;
    drop.blooddrop_expire_time = cltime + PLAYERGIB_DRIP_DROP_TTL;
    drop.blooddrop_last_time = cltime;
    drop.blooddrop_landed = 0;
    drop.blooddrop_landed_time = 0;
};

void(vector pos, vector vel) CSQC_PlayerGibDripParticle =
{
    CSQC_SpawnPlayerBloodDrop(pos, vel);
};

// ============================================================
//  Headshot back-spurt — fired at the entry wound when a kill-shot
//  lethally hits HITGROUP_HEAD.  Drops fly back along the bullet's
//  travel direction (i.e. toward where the attacker stood at fire
//  time) at 100 Hz for 50 ms.  Each tick emits a BURST of drops
//  (each with its own speed jitter + cone spread) so the per-tick
//  visual reads as a small cluster, not a single sniper-trail dot.
//  Default: 5 ticks × 3 drops = 15 drops total.
// ============================================================
const float  HEADSHOT_SPURT_INTERVAL  = 0.01;   // 100 Hz
const float  HEADSHOT_SPURT_COUNT     = 5;      // 100 Hz × 50 ms = 5 ticks
const float  HEADSHOT_SPURT_BURST     = 3;      // drops per tick → 15 total
const float  HEADSHOT_SPURT_SPEED     = 320;    // qu/s base back-velocity
const float  HEADSHOT_SPURT_SPEED_VAR = 100;    // ± qu/s speed jitter
const float  HEADSHOT_SPURT_SPREAD    = 70;     // ± qu/s lateral cone

.float  headshot_spurt_remaining;
.vector headshot_spurt_dir;

void() CSQC_HeadshotSpurtThink =
{
    if (self.headshot_spurt_remaining <= 0)
    {
        remove(self);
        return;
    }

    // Cone basis — derived once for the whole burst.  makevectors
    // clobbers v_forward/v_right/v_up but this is the only consumer
    // in this think, so no save/restore needed.
    makevectors(vectoangles(self.headshot_spurt_dir));
    vector basis_fwd   = v_forward;
    vector basis_right = v_right;
    vector basis_up    = v_up;

    // Emit a burst of HEADSHOT_SPURT_BURST drops this tick.  Each
    // drop rolls its own speed jitter and lateral spread so the
    // three don't overlap into a single trail.
    float b;
    for (b = 0; b < HEADSHOT_SPURT_BURST; b = b + 1)
    {
        // Per-drop speed jitter — keep positive so we never bounce a
        // drop forward (would look like splatter, not back-spurt).
        float speed = HEADSHOT_SPURT_SPEED
                    + (random() - 0.5) * 2 * HEADSHOT_SPURT_SPEED_VAR;
        if (speed < 80) speed = 80;

        vector vel = basis_fwd   * speed
                   + basis_right * (random() - 0.5) * 2 * HEADSHOT_SPURT_SPREAD
                   + basis_up    * (random() - 0.5) * 2 * HEADSHOT_SPURT_SPREAD;

        CSQC_SpawnPlayerBloodDrop(self.origin, vel);
    }

    self.headshot_spurt_remaining = self.headshot_spurt_remaining - 1;
    self.nextthink = time + HEADSHOT_SPURT_INTERVAL;
};

// pos: world position of the bullet entry (head).
// fwd_dir: bullet travel direction (attacker → victim, normalised).
//          The function flips it internally so drops spray BACK
//          toward the attacker.
void(vector pos, vector fwd_dir) CSQC_SpawnHeadshotSpurt =
{
    if (vlen(fwd_dir) <= 0)
        return;

    entity emitter = spawn();
    emitter.classname = "csqc_headshot_spurt";
    setorigin(emitter, pos);
    setsize(emitter, '0 0 0', '0 0 0');
    emitter.movetype = MOVETYPE_NONE;
    emitter.solid    = SOLID_NOT;
    // No drawmask: emitter is invisible.  Its only job is to call
    // think 5 times, each spawning a (drawable) blood drop child.
    emitter.drawmask = 0;
    emitter.headshot_spurt_remaining = HEADSHOT_SPURT_COUNT;
    emitter.headshot_spurt_dir       = normalize(fwd_dir) * -1;
    emitter.think     = CSQC_HeadshotSpurtThink;
    emitter.nextthink = time;   // first drop on the next tick
};

void() CSQC_PlayerGibSettle =
{
    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.touch = __NULL__;
    self.traileffectnum = 0;
    self.playergib_settled = 1;
};

void(vector pos, vector n) CSQC_PlayerGibStampBlood =
{
    if (vlen(n) < 0.01)
        n = '0 0 1';
    n = normalize(n);

    if (cltime < self.playergib_next_blood_time)
        return;

    CSQC_SpawnBloodDecalAt(pos, n);
    float splat_id = PlayerGib_GetBloodSplat();
    if (splat_id > 0)
        pointparticles(splat_id, pos + n, n * 80, 1);
    self.playergib_next_blood_time = cltime + PLAYERGIB_BOUNCE_BLOOD_DELAY;
};

void() CSQC_PlayerGibTryLandingBlood =
{
    if (self.playergib_landed_blood)
        return;

    entity saved_ent           = trace_ent;
    float  saved_fraction      = trace_fraction;
    vector saved_endpos        = trace_endpos;
    vector saved_plane_normal  = trace_plane_normal;
    float  saved_plane_dist    = trace_plane_dist;
    float  saved_inopen        = trace_inopen;
    float  saved_inwater       = trace_inwater;

    traceline(self.origin + '0 0 2', self.origin - '0 0 16',
              MOVE_NOMONSTERS, self);
    float  hit_fraction = trace_fraction;
    vector hit_pos      = trace_endpos;
    vector hit_normal   = trace_plane_normal;

    trace_ent           = saved_ent;
    trace_fraction      = saved_fraction;
    trace_endpos        = saved_endpos;
    trace_plane_normal  = saved_plane_normal;
    trace_plane_dist    = saved_plane_dist;
    trace_inopen        = saved_inopen;
    trace_inwater       = saved_inwater;

    if (hit_fraction >= 1 || vlen(hit_normal) <= 0)
        return;

    self.playergib_landed_blood = 1;
    CSQC_PlayerGibStampBlood(hit_pos, hit_normal);
};

void(vector hit_pos, vector n) CSQC_PlayerGibImpact =
{
    if (vlen(n) < 0.01)
        n = '0 0 1';
    n = normalize(n);

    CSQC_PlayerGibStampBlood(hit_pos, n);
    if (n_z > 0.6)
        self.playergib_landed_blood = 1;

    self.playergib_bounce_count = self.playergib_bounce_count + 1;
    self.avelocity = self.avelocity * PLAYERGIB_AVEL_DAMP;

    vector normal_vel = n * (self.velocity * n);
    vector tangent_vel = self.velocity - normal_vel;
    self.velocity = tangent_vel * PLAYERGIB_TANGENT_DAMP
                  - normal_vel * PLAYERGIB_BOUNCE_DAMP;

    if ((n_z > 0.6 && vlen(self.velocity) < PLAYERGIB_SETTLE_SPEED)
        || self.playergib_bounce_count >= PLAYERGIB_MAX_BOUNCES)
        CSQC_PlayerGibSettle();
};

float() CSQC_PlayerGibPredraw =
{
    float now = cltime;

    if (now >= self.playergib_expire_time)
    {
        remove(self);
        return PREDRAW_NEXT;
    }

    float dt = now - self.playergib_last_time;
    if (dt < 0) dt = 0;
    if (dt > 0.05) dt = 0.05;
    self.playergib_last_time = now;

    if (!self.playergib_settled && dt > 0)
    {
        vector old_origin = self.origin;
        self.velocity_z = self.velocity_z - PLAYERGIB_GRAVITY * dt;
        vector end = self.origin + self.velocity * dt;

        entity saved_ent           = trace_ent;
        float  saved_fraction      = trace_fraction;
        vector saved_endpos        = trace_endpos;
        vector saved_plane_normal  = trace_plane_normal;
        float  saved_plane_dist    = trace_plane_dist;
        float  saved_inopen        = trace_inopen;
        float  saved_inwater       = trace_inwater;

        tracebox(self.origin, self.mins, self.maxs, end,
                 MOVE_NOMONSTERS, self);
        float  hit_fraction = trace_fraction;
        vector hit_pos      = trace_endpos;
        vector hit_normal   = trace_plane_normal;

        trace_ent           = saved_ent;
        trace_fraction      = saved_fraction;
        trace_endpos        = saved_endpos;
        trace_plane_normal  = saved_plane_normal;
        trace_plane_dist    = saved_plane_dist;
        trace_inopen        = saved_inopen;
        trace_inwater       = saved_inwater;

        if (hit_fraction < 1 && vlen(hit_normal) > 0)
        {
            hit_normal = normalize(hit_normal);
            setorigin(self, hit_pos + hit_normal * 0.35);
            CSQC_PlayerGibImpact(hit_pos - hit_normal * 2, hit_normal);
        }
        else
        {
            setorigin(self, end);
        }

        self.angles = self.angles + self.avelocity * dt;

        // Two-phase emission — see PLAYERGIB_SPRAY_* / DRIP_* constants.
        //   spray phase:   now < spray_end_time   → 100 Hz
        //   drip phase:    now < drip_end_time    →  10 Hz
        //   off:           past drip_end_time     → no emission
        // emitted-cap of 8 per frame is unchanged: it's just a safety
        // valve so a long stutter frame can't generate hundreds of
        // backlog drops in one tick.
        if (self.playergib_next_drip_time < self.playergib_drip_end_time)
        {
            float emit_until = now;
            if (emit_until > self.playergib_drip_end_time)
                emit_until = self.playergib_drip_end_time;

            vector inherit_vel = self.velocity * PLAYERGIB_DRIP_VEL_INHERIT;
            // Scatter amplitude depends on the gib's current spin —
            // a barely-rotating gib drips almost straight under
            // itself, a fast-spinning one flings drops in a curving
            // arc.  Capped so the spread stays believable.
            float scatter_amp = vlen(self.avelocity) * PLAYERGIB_DRIP_SCATTER_SCALE;
            if (scatter_amp > PLAYERGIB_DRIP_SCATTER_MAX)
                scatter_amp = PLAYERGIB_DRIP_SCATTER_MAX;

            float emitted = 0;
            while (self.playergib_next_drip_time <= emit_until && emitted < 8)
            {
                float frac = (self.playergib_next_drip_time - (now - dt)) / dt;
                if (frac < 0) frac = 0;
                if (frac > 1) frac = 1;

                // Rotating-direction scatter — each emission advances
                // the phase, sin/cos give a horizontal throw direction
                // that rotates around the gib like blood being slung
                // off a spinning surface.
                vector scatter = '0 0 0';
                scatter_x = cos(self.playergib_drip_phase) * scatter_amp;
                scatter_y = sin(self.playergib_drip_phase) * scatter_amp;
                self.playergib_drip_phase = self.playergib_drip_phase
                                          + PLAYERGIB_DRIP_PHASE_STEP;

                CSQC_PlayerGibDripParticle(old_origin
                    + (self.origin - old_origin) * frac,
                    inherit_vel + scatter);

                float next_interval;
                if (self.playergib_next_drip_time < self.playergib_spray_end_time)
                    next_interval = PLAYERGIB_SPRAY_INTERVAL;
                else
                    next_interval = PLAYERGIB_DRIP_INTERVAL;

                self.playergib_next_drip_time = self.playergib_next_drip_time
                    + next_interval;
                emitted = emitted + 1;
            }

            // Catch-up bail: if we hit the per-frame emit cap and are
            // still behind, snap forward to "now + next interval" so
            // we don't infinite-loop on the next frame.  Picks the
            // interval matching the phase we'd be emitting into.
            if (emitted >= 8 && self.playergib_next_drip_time < now)
            {
                float catchup_interval;
                if (now < self.playergib_spray_end_time)
                    catchup_interval = PLAYERGIB_SPRAY_INTERVAL;
                else
                    catchup_interval = PLAYERGIB_DRIP_INTERVAL;
                self.playergib_next_drip_time = now + catchup_interval;
            }
        }
    }

    addentity(self);
    return PREDRAW_NEXT;
};

// dir = unit vector along the killing shot (attacker → victim).
// Gibs fan out around dir with random spread; each gets a trail.
void(vector pos, vector dir, float count, float damage_scale) CSQC_SpawnPlayerGibs =
{
    // Initial big blood spray at the impact point — front-loads the gore.
    float splat_id = PlayerGib_GetBloodSplat();
    if (splat_id > 0)
        pointparticles(splat_id, pos, dir * 200, 1);

    // Pre-play a wet flesh-burst sound (one of two HL flesh break sounds).
    if (random() < 0.5)
        pointsound(pos, "sounds/debris/break_fleshhl1.wav", 1, ATTN_NORM);
    else
        pointsound(pos, "sounds/debris/break_fleshhl2.wav", 1, ATTN_NORM);

    // Backspray out of the bullet hole — spawns the 100 Hz / 50 ms
    // five-drop jet aimed back along the bullet's travel direction.
    // CSQC_SpawnPlayerGibs is only ever called on headshot kills (the
    // server gates the CSQC_EVENT_PLAYER_GIBS broadcast on
    // HITGROUP_HEAD in sv_weapons.qc and the local predict-death
    // path mirrors that gate in sh_weapon_logic.qc), so calling this
    // unconditionally here is safe.  `pos` is at chest+24; nudge up
    // ~12 qu so the spurt origin sits roughly at head height.
    CSQC_SpawnHeadshotSpurt(pos + '0 0 12', dir);

    float i;
    for (i = 0; i < count; i++)
    {
        entity gib = spawn();
        gib.classname = "csqc_debris";

        setmodel(gib, "models/gibs/human/fleshgibs.mdl");
        vector spawn_pos;
        float launch_height = random() * PLAYERGIB_SPAWN_Z_SPREAD;
        spawn_pos_x = pos_x + (random() - 0.5) * 10;
        spawn_pos_y = pos_y + (random() - 0.5) * 10;
        spawn_pos_z = pos_z - 4 + launch_height;
        setorigin(gib, spawn_pos);
        setsize(gib, '-2 -2 -2', '2 2 2');

        // Pick a random submodel variant for visual variety.
        // fleshgibs.mdl variants are 1-indexed; clamp to a safe upper bound.
        float variant = 1 + floor(random() * 5);
        setcustomskin(gib, "", strcat("geomset 0 ", ftos(variant), "\n"));

        // ~12.5% darker render tint — the stock fleshgibs.mdl reads a
        // touch too bright/pink against typical map lighting; this nudge
        // pushes it toward a more "freshly torn" muscle tone without
        // having to repaint the texture.
        gib.colormod = '0.75 0.75 0.75';

        // Velocity: bias along killing-shot direction + random fan.
        // Stronger overkill = stronger spread.
        float spread = 180 + damage_scale * 1.5;
        gib.velocity_x = dir_x * (120 + damage_scale) + (random() - 0.5) * spread;
        gib.velocity_y = dir_y * (120 + damage_scale) + (random() - 0.5) * spread;
        gib.velocity_z = 190 + random() * 170
            + (random() - 0.5) * PLAYERGIB_LAUNCH_Z_JITTER
            + launch_height * 3
            + damage_scale * 0.5;

        gib.movetype = MOVETYPE_NONE;
        gib.solid = SOLID_NOT;
        gib.gravity = 0;
        gib.bouncefactor = 0;
        gib.bouncestop = 0;
        gib.avelocity_x = (random() - 0.5) * 2800;
        gib.avelocity_y = (random() - 0.5) * 2800;
        gib.avelocity_z = (random() - 0.5) * 2800;
        gib.drawmask = MASK_ENGINE;
        gib.touch = __NULL__;
        gib.predraw = CSQC_PlayerGibPredraw;

        // Dripping is driven manually from predraw so the stream remains
        // one drop per 0.01 seconds instead of a scatter burst.
        gib.traileffectnum = 0;

        gib.playergib_expire_time = cltime + 8 + random() * 7;
        gib.playergib_next_drip_time = cltime;
        // Randomised spray length per gib so the 6 gibs don't all
        // crossfade to the 10 Hz trickle on the same render frame.
        float spray_len = PLAYERGIB_SPRAY_DURATION_MIN
                        + random() * (PLAYERGIB_SPRAY_DURATION_MAX
                                    - PLAYERGIB_SPRAY_DURATION_MIN);
        gib.playergib_spray_end_time = cltime + spray_len;
        gib.playergib_drip_end_time  = gib.playergib_spray_end_time
                                     + PLAYERGIB_DRIP_DURATION;
        // Random starting phase per gib so the 6 spinning sprays don't
        // align into a single visible ring — each gib's drops trace
        // their own rotating arc starting from a different angle.
        gib.playergib_drip_phase = random() * 6.2831853;
        gib.playergib_next_blood_time = cltime;
        gib.playergib_bounce_count = 0;
        gib.playergib_landed_blood = 0;
        gib.playergib_last_time = cltime;
        gib.playergib_settled = 0;
        gib.think = __NULL__;
        gib.nextthink = 0;
    }
};

void() CSQC_PrecacheBreakables =
{
    precache_model("models/gibs/glassgibs.mdl");
    precache_model("models/gibs/human/fleshgibs.mdl");
    precache_pic(PLAYERGIB_DRIP_DROP_SHADER);
    precache_sound("sounds/debris/break_fleshhl1.wav");
    precache_sound("sounds/debris/break_fleshhl2.wav");
    // Particle effect IDs are looked up lazily on first use — see
    // PlayerGib_GetBloodSplat above.
    // r_particledesc is set via localcmd from CSQC_Init, so the effects
    // aren't registered yet at the time this function runs.
};
