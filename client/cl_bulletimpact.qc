// ============================================================
//  client/cl_bulletimpact.qc  -  Bullet impact effects
//
//  Client-predicted impact light, particles, and ricochet sounds.
//  The shooter sees these instantly. Other players see them via
//  the server's CSQC_EVENT_IMPACT multicast (which already
//  excludes the shooter via dimension masking).
// ============================================================

// Forward declarations (defined in cl_bulletholes.qc)
void(vector hit_pos, vector hit_normal, entity hit_target, float impact_mat, float action) CSQC_SpawnBulletHole;
void(entity owner_ent) CSQC_BulletHolesRemoveByOwner;

// Forward declaration (defined in cl_rain.qc — compiles after this file).
// Spawns the rain-splash sprite+ring visual at the given water-surface
// world point, gated on cl_rain_splash.  Called from CSQC_BulletImpact.
void(vector pos) CSQC_Rain_SpawnBulletWaterSplash;

// Forward declarations (defined in cl_breakable.qc — compiles after this file)
void(vector mins, vector maxs, float count, float damage_scale,
     float owner_entnum,
     float throw_mode, vector throw_dir, float throw_force) CSQC_SpawnGlassGibs;
void(vector mins, vector maxs, float style, float count, float damage_scale,
     float custom_idx, float alpha_byte, float owner_entnum,
     float throw_mode, vector throw_dir, float throw_force) CSQC_SpawnDebrisGibs;

// Fields declared in cl_brushsync.qc which compiles after this file.
// Forward declared here so Impact_ClassifyLocal can read brush_material
// off trace_ent, and CSQC_PredictBreakableBreak can track predicted HP
// + spawn matching gibs using the replicated max_health / cnt.
.float brush_material;
.float brush_health;
.float brush_max_health;
.float brush_cnt;
.float brush_broken_predicted;
.float brush_broken_confirmed;
.float brush_type;        // BRUSH_TYPE_STATIC / DOOR / BUTTON

// Field declared in cl_breakable.qc (compiles after this file). Tagged on
// each predicted-break gib so the rollback sweep can find and remove just
// the ghost debris when a false-positive prediction expires.
.float owner_brush_entnum;

// Cached effect IDs for per-surface bullet impacts. All defined in
// particles/weapons.cfg.
//
// Lazy lookup: particleeffectnum() returns -1 if the effect isn't
// registered yet. Because r_particledesc is set via localcmd in CSQC_Init
// (queued — runs at end of frame), the lookup MUST happen later than init,
// so we resolve on first call. By the time the user fires their first
// bullet the queued command has long since executed.

float impact_effect_default;
float impact_effect_flesh;
float impact_effect_flesh_lethal;
float impact_effect_metal;
float impact_effect_glass;
float impact_effect_wood;
// Smoke-only variant of "impact" — same dark rising puff component
// the bullet effect uses, with the orange chip-burst and the
// streaking textured-sparks layer omitted.  Used by melee weapons
// (fists, katana) per the user's request: bullet-style smoke, no
// sparks.  Defined in particles/weapons.cfg as "weapons.impact_smoke".
float impact_effect_smoke;
float impact_effect_resolved;

// Bullet-impact DEBRIS effect handles (particles/weapons.cfg, namespace
// weapons).  Lazily resolved + validated like the impact_effect_* handles
// above (particleeffectnum returns a slot even for unregistered names, so
// particleeffectquery is the real validator).  Each impact fires 3 layers:
// a CHUNK spray (stone or dirt by mode) + a shared DUST cloud + shared SPARKS.
float debris_effect_rock;   // stone chunks  (mode 0)
float debris_effect_dirt;   // dirt chunks   (mode 1)
float debris_effect_dust;   // expanding dust cloud (shared)
float debris_effect_spark;  // hot sparks    (shared)
float exitsmoke_effect;     // bullet wall-bang EXIT dust puff (weapons.metal_impact —
                            // the prop_car tailpipe / prop contact puff; NOT resolved
                            // through Debris_Resolve, see CSQC_BulletExitSmoke)
// Per-shot debris-burst counter, capped by cl_impact_debris_per_shot — keeps
// shotgun pellet loops / penetration from multiplying the debris.  Scoped to a
// single trigger pull by debris_last_action_id below (NOT CSQC_Impact_ResetShot,
// which gauss/crossbow/rebar bypass).
float debris_per_shot_count;
// wep_action_id of the shot the counter is currently scoped to.  A change means
// a new trigger pull -> zero the counter.  This is robust for the weapons that
// reach CSQC_BulletImpact without the CSQC_Impact_ResetShot funnel.
float debris_last_action_id;


// Validity check helper.  FTE's particleeffectnum (pr_csqc.c:3735) ALWAYS
// returns a negative slot index even when the named effect doesn't exist
// — the `if (precache != P_INVALID)` guard is commented out.  So a raw
// non-zero return is NOT proof the effect is real; pointparticles(slot)
// against an invalid slot is a silent no-op.  particleeffectquery returns
// "" for invalid slots; use it to scrub missing variants down to 0 so
// the picker's `!= 0` fallback correctly routes to the base effect.
float(float id) Impact_NormalizeEffect =
{
    if (id == 0) return 0;
    if (particleeffectquery(id, 0) == "") return 0;
    return id;
};

// One-shot resolve — called from Impact_GetEffectFor on first use.  The
// particles/weapons.cfg load happens earlier, in cfg/default.cfg, via the
// menu VM's Menu_LoadConfig (which runs after PScript_InitParticles has
// set pe_script_enabled and before any CSQC loads).  By the time this
// function runs on first shot, every effect is already registered.
void() Impact_ResolveAll =
{
    if (impact_effect_resolved) return;

    float def = particleeffectnum("weapons.impact");
    if (def == 0)
        return;   // slot table full — retry next call

    impact_effect_default      = def;
    impact_effect_flesh        = Impact_NormalizeEffect(particleeffectnum("weapons.flesh_impact"));
    impact_effect_flesh_lethal = Impact_NormalizeEffect(particleeffectnum("weapons.flesh_impact_lethal"));
    impact_effect_metal        = Impact_NormalizeEffect(particleeffectnum("weapons.metal_impact"));
    impact_effect_glass        = Impact_NormalizeEffect(particleeffectnum("weapons.glass_impact"));
    impact_effect_wood         = Impact_NormalizeEffect(particleeffectnum("weapons.wood_impact"));
    // Skip Impact_NormalizeEffect — particleeffectquery returns "" for the
    // smoke recipe even when valid, zeroing it and silently disabling the
    // melee smoke spawn.  Trust the raw slot id.
    impact_effect_smoke             = particleeffectnum("weapons.impact_smoke");

    impact_effect_resolved     = 1;
};

// Spawn the smoke-only impact puff (no sparks, no chip burst).
// Used by melee weapons that want bullet-style smoke without the
// bullet visual.  Caller passes the same (pos, normal) it would
// give Impact_SpawnParticles.  Lazy-resolves the effect on first
// use, matching the pattern in Impact_SpawnParticles.
void(vector pos, vector normal) Impact_SpawnSmokeOnly =
{
    Impact_ResolveAll();
    if (impact_effect_smoke == 0)
        return;
    // Token velocity push only — the recipe's own velbias/friction
    // governs the plume.  A larger injection rockets the lone puff off
    // the wall before it can be seen (the bullet path's 200 u/s only
    // works because the orange spark burst masks the drift).
    pointparticles(impact_effect_smoke, pos, normal * 8, 1);
};

// Pick the right particle effect ID for a given IMPACT_MAT_* code.
// Falls back to default if the material-specific effect failed to load
// (so e.g. an old particles/weapons.cfg without the new entries still
// shows *something*).  CSQC's particleeffectnum returns 0 when the slot
// table is full — any other value (including negative client-side slot
// indices) is a valid handle for pointparticles.
float(float mat) Impact_GetEffectFor =
{
    Impact_ResolveAll();
    if (mat == IMPACT_MAT_FLESH_LETHAL && impact_effect_flesh_lethal != 0) return impact_effect_flesh_lethal;
    if (mat == IMPACT_MAT_FLESH        && impact_effect_flesh        != 0) return impact_effect_flesh;
    if (mat == IMPACT_MAT_METAL        && impact_effect_metal        != 0) return impact_effect_metal;
    if (mat == IMPACT_MAT_METAL_NODECAL && impact_effect_metal       != 0) return impact_effect_metal;
    if (mat == IMPACT_MAT_GLASS        && impact_effect_glass        != 0) return impact_effect_glass;
    if (mat == IMPACT_MAT_WOOD         && impact_effect_wood         != 0) return impact_effect_wood;
    return impact_effect_default;
};

// Per-shot impact counters — declared above the first user
// (Impact_SpawnParticles below) since cl_bulletimpact.qc has the
// const-block decls further down.  Reset by CSQC_Impact_ResetShot at
// the top of every predicted hitscan shot.  Each is capped by its
// own cvar (0 = unlimited).
//   _light_count  ↔ cl_impact_dlights_per_shot
//   _effect_count ↔ cl_impact_effects_per_shot
float  impact_per_shot_light_count;
float  impact_per_shot_effect_count;

// Impact particles on/off.  cl_impact_quality 0 = none; >=1 = full per-material
// smoke + sparks.  (The old "1 = cheap _fast spark/chip" tier was collapsed —
// there's a single particle quality now.  The per-impact dynamic light is a
// separate toggle, cl_impact_light.)
float() Impact_Quality =
{
    if (cvar("cl_impact_quality") <= 0) return 0;
    return 1;
};

void(vector pos, vector normal, float mat) Impact_SpawnParticles =
{
    float q = Impact_Quality();
    if (q <= 0)
        return;

    // Per-shot particle-effect cap.  A penetrating shot fires this
    // once per surface it passes through, so they stack up fast —
    // the cap stops one shot blowing up the particle budget at
    // higher impact_quality.  (It does NOT reach the exit SMOKE:
    // CSQC_BulletExitSmoke is called from CSQC_FireImpactCosmetics,
    // outside this function, and has its own cl_impact_exitsmoke*.)
    // bh_shotgun_blast bypasses the cap for the shotgun pellet loop
    // — same latch CSQC_PredictedShotgunImpact uses for the bullet-
    // hole cap so each pellet draws its own impact FX.
    float effect_cap = cvar("cl_impact_effects_per_shot");
    if (!bh_shotgun_blast
        && effect_cap > 0
        && impact_per_shot_effect_count >= effect_cap)
        return;
    impact_per_shot_effect_count += 1;

    // Metal sparks get a smaller outward velocity so they stay close to the surface
    // (thinner, less spray) — combined with the lowered randomvel in the metal_impact
    // particle block.  Other materials keep the original spread.  Metal-only.
    float vel_scale = 200;
    if (mat == IMPACT_MAT_METAL || mat == IMPACT_MAT_METAL_NODECAL)
        vel_scale = 100;

    pointparticles(Impact_GetEffectFor(mat), pos, normal * vel_scale, 1);

    // Flesh hits also stamp projected blood-splat decals on nearby
    // BSP geometry — wall behind the target plus a small floor pool.
    // See cl_bloodsplat.qc.  Engine particles are simulated in C and
    // can't be inspected from QC, so we approximate "blood that flew
    // and hit something" with tracelines instead of literal particle
    // collision.
    if (mat == IMPACT_MAT_FLESH || mat == IMPACT_MAT_FLESH_LETHAL)
        CSQC_SpawnBloodDecals(pos, normal);
};

// Local prediction inspects trace_ent (the shooter's own CSQC trace).
// Players appear as entities with classname == "player"; replicated
// brush entities (func_wall, func_breakable) carry a brush_material
// byte set in CSQC_SolidBrush_Update from the server's BREAKABLE_*
// style. 0 = default/concrete for non-breakable brushes.
// Metal phys objects — barrel, can, filing cabinet, and dropped weapons all
// collide as a SOLID_PHYSICS box and read as metal: bullet hits give metal sparks
// + the metal ricochet ping, NO debris chunks, NO decal.  Each sets its classname
// before any trace can land (cabinet + weapons via their CSQC mirrors, barrel/can
// via engine replication), so the classname match is reliable.
float(entity e) CL_IsMetalPhysObj =
{
	return e && (e.classname == "phys_files" || e.classname == "phys_barrel"
	          || e.classname == "phys_can"   || e.classname == "csqc_dropped_weapon");
};

float(entity hit) Impact_ClassifyLocal =
{
    // hit == world (edict 0, falsy in QC) OR a genuine miss: resolve the hit surface's TEXTURE
    // -> material (from the hit POINT trace_endpos — Q1 traces carry no surface) so the shooter's
    // predicted effect matches the server-sent one for everyone else.
    if (!hit) return Surf_ImpactMat(Surf_MaterialAtPoint(hit, trace_endpos));
    // All player hits use the lethal spark-splash variant — promoted from
    // headshot/killing-blow only so every body shot reads with the same
    // visceral look. Server uses IMPACT_MAT_FLESH_LETHAL for player hits
    // too (sh_weapon_standard.qc + shotgun pellet paths), keeping the
    // predicted local effect identical to the authoritative one.
    if (hit.classname == "player") return IMPACT_MAT_FLESH_LETHAL;
    // Remote players in this mod render through player_visual_proxy
    // (CSQC entity networked via CSQC_Ent_Update), not via engine player
    // slots. Classify them as flesh too so local-hit particles land.
    if (hit.classname == "player_visual_proxy") return IMPACT_MAT_FLESH_LETHAL;

    // Monsters, via the getentity ray sweep in cl_monstertrace.qc.  FLESH rather
    // than FLESH_LETHAL: the server's own classifier reserves the lethal splash
    // for a monster that is already dead (sv_weapons.qc:869), and the client
    // cannot know the health, so the routine variant is the honest match.  The
    // difference everyone else sees is the spark-splash, not the blood.
    if (hit.classname == "csqc_monster_proxy") return IMPACT_MAT_FLESH;

    // Physics props — metal sparks/ric on hit, no hole (the bullet-
    // hole gate rejects by classname).  Replicated via SendEntity
    // (cl_physprop.qc) which sets classname before the trace can
    // ever land, so this match is reliable now.
    if (CL_IsMetalPhysObj(hit))
        return IMPACT_MAT_METAL_NODECAL;

    // Breakable brush — read material code mirroring server values.
    // Style numbering matches the BREAKABLE_*_CL constants in
    // cl_breakable.qc (which mirror sv_breakable.qc).
    //   0 GLASS / 7 UNBREAKABLE_GLASS → glass impact FX
    //   1 WOOD  / 5 TILE              → wood
    //   2 METAL / 6 COMPUTER          → metal
    //   3 FLESH                       → flesh
    //   4 CINDER / 8 ROCKS            → default (concrete-dust)
    float m = hit.brush_material;
    if (m == 0 || m == 7)        return IMPACT_MAT_GLASS;
    if (m == 1 || m == 5)        return IMPACT_MAT_WOOD;
    if (m == 2 || m == 6)        return IMPACT_MAT_METAL;
    if (m == 3)                  return IMPACT_MAT_FLESH;
    // Untagged brush (func_wall/door, sentinel material): fall back to the surface TEXTURE (point).
    return Surf_ImpactMat(Surf_MaterialAtPoint(hit, trace_endpos));
};

// Remove a client-side fake projectile entity
void() CSQC_FakeProjectileExpire =
{
    remove(self);
};

.vector fake_proj_hitpos;   // pre-traced wall hit position for fake projectiles
.string fake_proj_hitsnd;  // impact sound to play when fake projectile sticks

void(vector pos, vector normal) CSQC_AddImpactLight;

// Stop a fake projectile at the wall — sticks in place, plays impact sound, then expires
void() CSQC_FakeProjectileStick =
{
    self.velocity = '0 0 0';
    self.movetype = MOVETYPE_NONE;
    setorigin(self, self.fake_proj_hitpos);

    // Play impact sound at hit location
    if (self.fake_proj_hitsnd != "")
        pointsound(self.fake_proj_hitpos, self.fake_proj_hitsnd, 1, ATTN_NORM);

    // Impact light + particles at hit point.  No surface normal is stored
    // for stuck projectiles, so feed zero velocity and let the particle
    // effect's own randomvel/veladd scatter it.
    // Stuck-fake-projectile has no recorded surface normal; pass zero
    // and the cl_impact_light_offset stack collapses to no extra lift.
    CSQC_AddImpactLight(self.fake_proj_hitpos, '0 0 0');
    Impact_SpawnParticles(self.fake_proj_hitpos, '0 0 0', IMPACT_MAT_DEFAULT);

    // Expire when server entity should arrive
    float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
    self.think = CSQC_FakeProjectileExpire;
    self.nextthink = time + bound(0.1, ping_est, 1.0) + 0.2;
};

const float IMPACT_LIGHT_RADIUS   = 60;
const float IMPACT_LIGHT_DURATION = 0.06;
const float IMPACT_LIGHT_MAX      = 8;   // max simultaneous impact lights
// (impact_per_shot_light_count / _effect_count are declared above
// Impact_SpawnParticles since that function fires first in the file
// and uses _effect_count.)

vector impact_light_pos[8];
float  impact_light_time[8];
float  impact_light_count;

// Reset hook called from sh_weapon_standard.qc at the top of every
// penetrating hitscan shot so cl_impact_dlights_per_shot scopes to
// that single shot.
void() CSQC_Impact_ResetShot =
{
    impact_per_shot_light_count  = 0;
    impact_per_shot_effect_count = 0;
    // NOTE: the debris cap is NOT reset here — it is scoped by wep_action_id at
    // the call site instead, so it works for gauss/crossbow/rebar which reach
    // CSQC_BulletImpact without going through this reset hook.
};

// Explosion lights — same ringbuffer pattern but brighter / wider / longer
// so grenade explosions read as the real visual punch (not a tiny bullet
// flash). dynamiclight_add wants a per-frame call to persist, so the
// lifetime fades the radius + intensity over EXPLOSION_LIGHT_DURATION.
const float EXPLOSION_LIGHT_RADIUS   = 360;
const float EXPLOSION_LIGHT_DURATION = 0.45;
const float EXPLOSION_LIGHT_MAX      = 4;

vector explosion_light_pos[4];
float  explosion_light_time[4];
float  explosion_light_count;

void(vector pos, vector normal) CSQC_AddImpactLight =
{
    float slot;
    float scale;

    // Decoupled from cl_impact_quality (which only steps particles 0-2).
    // cl_impact_light is the dedicated dlight toggle — pairs with
    // cl_explosion_light so users can kill bullet-impact dlights without
    // also losing the particle smoke/spark from quality 2.
    if (!cvar("cl_impact_light"))
        return;

    scale = bound(0, cvar("cl_impact_light_scale"), 2);
    if (scale <= 0)
        return;

    // Per-shot dlight cap — the dominant cost of cl_impact_quality 3
    // during sustained fire is dynamiclight_add() called per hit;
    // with penetration a single shot can spawn 8 lights.  Cap here so
    // a burst doesn't turn into a per-tick lightmap relight storm.
    float dl_cap = cvar("cl_impact_dlights_per_shot");
    if (dl_cap > 0 && impact_per_shot_light_count >= dl_cap)
        return;
    impact_per_shot_light_count += 1;

    // Stand the light OFF the wall along the surface normal by
    // cl_impact_light_offset.  A dlight flush with the surface (offset 0)
    // barely lights the wall face — it's coplanar/half-buried — so pulling it
    // a few units into the room lets the wall light up.  Separate from
    // cl_impact_particle_offset (2u, just enough to keep smoke off the decal):
    // the light wants a bigger standoff than the particles.
    float loff = cvar("cl_impact_light_offset");
    if (loff < 0) loff = 0;
    slot = impact_light_count - floor(impact_light_count / IMPACT_LIGHT_MAX) * IMPACT_LIGHT_MAX;
    impact_light_pos[slot] = pos + normal * loff;
    impact_light_time[slot] = cltime;
    impact_light_count += 1;
    // Force this render frame's gate to "yes" so the brightest first
    // sample (frac == 1.0) reaches the engine even when
    // cl_dlight_update_hz would otherwise skip it.
    CSQC_DlightGate_ForceUpdate();
};

void(vector pos) CSQC_AddExplosionLight =
{
    // Bail before allocating a slot when the cvar is off.  Existing
    // active lights still play out their fade; this just suppresses
    // NEW ones, so flipping the cvar mid-fight doesn't strobe in/out.
    if (!cvar("cl_explosion_light"))
        return;

    float slot;
    slot = explosion_light_count - floor(explosion_light_count / EXPLOSION_LIGHT_MAX) * EXPLOSION_LIGHT_MAX;
    explosion_light_pos[slot] = pos;
    explosion_light_time[slot] = cltime;
    explosion_light_count += 1;
    // Force this render frame's gate to "yes" so the bright peak of
    // the explosion lands on a drawn frame, not a skipped one.
    CSQC_DlightGate_ForceUpdate();
};

// HL-grenade explosion sprite — animates frames 0..5 of fexplo.spr.
// Spawned explicitly because CSQC's te_explosion builtin only emits
// particles + sound, not the sprite (the sprite is part of the engine's
// network temp-entity handler, which doesn't fire when te_explosion is
// called locally from CSQC). Switched from progs/s_explod.spr to
// gfx/fexplo.spr per content update — same 6-frame layout, just a
// nicer-looking fireball.
void() CSQC_ExplodeSpriteThink =
{
    self.frame = self.frame + 1;
    if (self.frame >= 6)
    {
        remove(self);
        return;
    }
    self.nextthink = time + 0.05;
};

void(vector pos) CSQC_SpawnExplodeSprite =
{
    // Lift the sprite center 16 qu so the lower half doesn't sink
    // through the ground when the grenade detonates near the floor.
    entity spr = spawn();
    setorigin(spr, pos + '0 0 16');
    setmodel(spr, "gfx/fexplo.spr");
    spr.drawmask  = MASK_ENGINE;
    spr.effects   = EF_ADDITIVE;
    spr.renderflags = RF_NOSHADOW;   // an explosion FLASH casting a shadow reads absurd (r_shadows 2)
    spr.frame     = 0;
    spr.think     = CSQC_ExplodeSpriteThink;
    spr.nextthink = time + 0.05;
};

// Called every render frame from CSQC_UpdateView, before renderscene()
//
// cl_dlight_update_hz throttles the dynamiclight_add calls (see
// CSQC_DlightGate_Tick in cl_main.qc) — the expiry/timestamp
// bookkeeping always runs so dlights still time out correctly,
// only the engine submission is skipped on non-update frames.
void() CSQC_DrawImpactLights =
{
    float i, age, frac;
    float impact_scale;
    float gate = csqc_dlight_update_this_frame;

    impact_scale = bound(0, cvar("cl_impact_light_scale"), 2);

    // A shadow-casting dlight re-projects every entity in its volume each frame.
    // Impact flashes are 0.06s flickers, so their cast shadows are pure noise that
    // reads as "the impact smoke casts a shadow" — force them OFF regardless of the
    // cvar (see the impact loop below).  cl_combat_light_shadows still governs the
    // steadier EXPLOSION lights via lflags.
    float lflags = cvar("cl_combat_light_shadows") ? 0 : PFLAGS_NOSHADOW;

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
        if (impact_scale > 0 && gate)
            dynamiclight_add(impact_light_pos[i],
                             IMPACT_LIGHT_RADIUS * impact_scale * frac,
                             '1 0.7 0.3' * frac, 0, "", PFLAGS_NOSHADOW);  // never cast (0.06s flicker = noise)
    }

    // Explosion lights — same per-frame fade. Color skewed warm-orange
    // with super-bright peak (>1 components ride the HDR path so the
    // light blooms hot in the first frames) then linearly fades out.
    for (i = 0; i < EXPLOSION_LIGHT_MAX; i++)
    {
        if (explosion_light_time[i] <= 0)
            continue;

        age = cltime - explosion_light_time[i];
        if (age >= EXPLOSION_LIGHT_DURATION)
        {
            explosion_light_time[i] = 0;
            continue;
        }

        frac = 1.0 - (age / EXPLOSION_LIGHT_DURATION);
        if (gate)
            dynamiclight_add(explosion_light_pos[i],
                             EXPLOSION_LIGHT_RADIUS * frac,
                             '2.5 1.6 0.7' * frac, 0, "", lflags);
    }
};

// Pull particles off the surface so they depth-sort in front of the
// client-side bullet-hole sprite. The bullet hole itself sits only a
// fraction of a unit off the wall, while particles can tolerate a larger
// normal offset without looking detached.
float() Impact_ParticleOffset =
{
    // Single knob — clamped low end at 2 u so particles don't z-fight
    // the bullet-hole decal at default; upper end now uncapped so
    // testing high values for "hover above BSP" works without
    // needing a second cvar.
    float off = cvar("cl_impact_particle_offset");
    if (off < 2) off = 2;
    return off;
};

// Should we spawn a persistent bullet-hole decal for this impact?
// Any material that leaves a solid surface behind gets a hole — for
// func_breakables the hole attaches to the brush entity via
// CSQC_SpawnBulletHole's bh_dynamic path, follows it if it moves, and
// is removed by CSQC_BulletHolesRemoveByOwner on brush destruction.
// Glass included: cracks on a pane that's still intact look great, and
// the same destroy-event cleanup yanks them the instant the pane breaks.
// Excluded:
//   FLESH / FLESH_LETHAL — hit target is a player or gibbing flesh
//                          breakable; decal would orphan on the body.
float(float mat) Impact_ShouldSpawnHole =
{
    if (mat == IMPACT_MAT_FLESH)        return 0;
    if (mat == IMPACT_MAT_FLESH_LETHAL) return 0;
    if (mat == IMPACT_MAT_METAL_NODECAL) return 0;
    return 1;
};

// CSQC mirror of sv_breakable.qc BreakableRandomImpactSound. Takes the
// raw BREAKABLE_* style code (the replicated brush_material byte) so the
// variant table lines up 1:1 with the server. The attacker's client
// calls this on predicted impact; remote clients hit it via the
// CSQC_EVENT_BREAKABLE_IMPACT_SOUND multicast path. `random()` draws
// differ per side, but both pull from the same set — indistinguishable.
void(vector pos, float style) Impact_PlayBreakableSound =
{
    string snd;
    float v = random();

    // Style routing: GLASS (0) + UNBREAKABLE_GLASS (7) → glass;
    // CINDER (4) + ROCKS (8) → concrete; WOOD (1) + TILE (5) → wood;
    // FLESH (3) → flesh; METAL (2) + COMPUTER (6) and any
    // unrecognised value fall through to the metal pool.
    if (style == 0 || style == 7)
    {
        if      (v < 0.25) snd = "sounds/debris/impact_glasshl1.wav";
        else if (v < 0.50) snd = "sounds/debris/impact_glasshl2.wav";
        else if (v < 0.75) snd = "sounds/debris/impact_glasshl3.wav";
        else               snd = "sounds/debris/impact_glasshl4.wav";
    }
    else if (style == 4 || style == 8)
    {
        if      (v < 0.333) snd = "sounds/debris/impact_concretehl1.wav";
        else if (v < 0.666) snd = "sounds/debris/impact_concretehl2.wav";
        else                snd = "sounds/debris/impact_concretehl3.wav";
    }
    else if (style == 1 || style == 5)
    {
        if      (v < 0.25) snd = "sounds/debris/impact_woodhl1.wav";
        else if (v < 0.50) snd = "sounds/debris/impact_woodhl2.wav";
        else if (v < 0.75) snd = "sounds/debris/impact_woodhl3.wav";
        else               snd = "sounds/debris/impact_woodhl4.wav";
    }
    else if (style == 3)
    {
        if      (v < 0.167) snd = "sounds/debris/impact_fleshhl1.wav";
        else if (v < 0.333) snd = "sounds/debris/impact_fleshhl2.wav";
        else if (v < 0.500) snd = "sounds/debris/impact_fleshhl3.wav";
        else if (v < 0.667) snd = "sounds/debris/impact_fleshhl4.wav";
        else if (v < 0.833) snd = "sounds/debris/impact_fleshhl5.wav";
        else                snd = "sounds/debris/impact_fleshhl6.wav";
    }
    else  // METAL, COMPUTER, fallback
    {
        if      (v < 0.167) snd = "sounds/debris/impact_metalhl1.wav";
        else if (v < 0.333) snd = "sounds/debris/impact_metalhl2.wav";
        else if (v < 0.500) snd = "sounds/debris/impact_metalhl3.wav";
        else if (v < 0.667) snd = "sounds/debris/impact_metalhl4.wav";
        else if (v < 0.833) snd = "sounds/debris/impact_metalhl5.wav";
        else                snd = "sounds/debris/impact_metalhl6.wav";
    }

    pointsound(pos, snd, 1, ATTN_NORM);
};

// CSQC mirror of sv_breakable.qc BreakableRandomBreakSound. Used when the
// attacker's predicted damage would bring brush_health to zero — we play
// the destruction sound immediately and let the server's multicast event
// route the remote-client copy, skipping the attacker so no echo stacks.
void(vector pos, float style) Impact_PlayBreakableBreakSound =
{
    string snd;
    float v = random();

    // Style routing: GLASS (0); CINDER (4) / ROCKS (8) → concrete;
    // WOOD (1) / TILE (5) → wood; FLESH (3); COMPUTER (6) →
    // electronic; METAL (2) and any unrecognised value fall through
    // to the metal pool.  UNBREAKABLE_GLASS (7) never reaches this
    // path (gated in func_breakable_break server-side).
    if (style == 0)
    {
        if      (v < 0.333) snd = "sounds/debris/break_glasshl1.wav";
        else if (v < 0.666) snd = "sounds/debris/break_glasshl2.wav";
        else                snd = "sounds/debris/break_glasshl3.wav";
    }
    else if (style == 4 || style == 8)
    {
        if (v < 0.5) snd = "sounds/debris/break_concretehl1.wav";
        else         snd = "sounds/debris/break_concretehl2.wav";
    }
    else if (style == 1 || style == 5)
    {
        if      (v < 0.333) snd = "sounds/debris/break_woodhl1.wav";
        else if (v < 0.666) snd = "sounds/debris/break_woodhl2.wav";
        else                snd = "sounds/debris/break_woodhl3.wav";
    }
    else if (style == 3)
    {
        if (v < 0.5) snd = "sounds/debris/break_fleshhl1.wav";
        else         snd = "sounds/debris/break_fleshhl2.wav";
    }
    else if (style == 6)
    {
        if      (v < 0.125) snd = "sounds/debris/break_eletronichl1.wav";
        else if (v < 0.250) snd = "sounds/debris/break_eletronichl2.wav";
        else if (v < 0.375) snd = "sounds/debris/break_eletronichl3.wav";
        else if (v < 0.500) snd = "sounds/debris/break_eletronichl4.wav";
        else if (v < 0.625) snd = "sounds/debris/break_eletronichl5.wav";
        else if (v < 0.750) snd = "sounds/debris/break_eletronichl6.wav";
        else if (v < 0.875) snd = "sounds/debris/break_eletronichl7.wav";
        else                snd = "sounds/debris/break_eletronichl8.wav";
    }
    else  // metal, machine, fallback
    {
        if (v < 0.5) snd = "sounds/debris/break_metalhl1.wav";
        else         snd = "sounds/debris/break_metalhl2.wav";
    }

    pointsound(pos, snd, 1, ATTN_NORM);
};

// How long CSQC keeps a predicted break locally-hidden before deciding
// the server is never going to confirm it (lag-comp reject, dimension
// mismatch, etc) and rolling back. 2.0 s is comfortably longer than a
// sv_minping 999 round-trip + server processing, so real-but-slow
// confirmations still arrive in time to set brush_broken_confirmed.
const float BREAK_PREDICT_TIMEOUT = 2.0;

// .think fired via .nextthink from CSQC_PredictBreakableBreak. If the
// server has since confirmed the break (via CSQC_EVENT_BRUSH_DESTROY or
// a snapshot with broken=1), leave the brush hidden. Otherwise roll back
// the local hide so the brush reappears, and sweep the ghost gibs that
// were spawned by the predicted break.
void() CSQC_BreakPredict_Expire =
{
    if (!self.brush_broken_predicted) return;   // already cleared elsewhere
    if (self.brush_broken_confirmed)  return;   // real break — keep hidden

    if (cvar("developer"))
        print(sprintf("^1[break-rollback]^7 brush ^2#%g^7 style=%g unconfirmed after %gs — restoring\n",
                      num_for_edict(self), self.brush_material, BREAK_PREDICT_TIMEOUT));

    self.brush_broken_predicted = 0;
    self.drawmask = MASK_ENGINE;
    self.solid    = SOLID_BSP;

    // Sweep tagged gibs so there's no orphan debris floating where the
    // brush is now re-visible. findchainfloat builds a linked list via
    // .chain; iterate that before remove() so we don't chase freed ents.
    float own_num = num_for_edict(self);
    entity g = findchainfloat(owner_brush_entnum, own_num);
    while (g)
    {
        entity nxt = g.chain;
        remove(g);
        g = nxt;
    }
};

// Predict whether `damage` dealt to `target` would break it, and fire the
// break sound + local hide immediately. trace_ent is the breakable brush
// replicated via solid_brush_SendEntity with brush_health updated on every
// damaging server snapshot. The brush_broken_predicted flag gates repeats
// until the server resets the brush to full HP (round restart) or confirms
// the break — preventing double break sounds on rapid-fire weapons
// hammering the same breakable.
void(entity target, float damage) CSQC_PredictBreakableBreak =
{
    if (!target)                              return;
    if (target.classname == "player")         return;
    // brush_type filter: only static brushwork (func_breakable) is
    // predict-broken.  func_button / func_door also use brush_health
    // for shootable activation (Q1 killed-callback fires the button
    // and resets HP, NOT a destroy).  Without this gate the predict
    // path played the break sound + hid the button locally on every
    // shot, then the server's "still alive" snapshot rolled it back.
    if (target.brush_type != BRUSH_TYPE_STATIC) return;
    // brush_health > 0 identifies a live breakable. brush_material can be
    // 0 for BREAKABLE_CONCRETE, so don't gate on that — non-breakable
    // brushes have health == 0 and are excluded by the next check.
    if (target.brush_health <= 0)             return;    // not a breakable / already gone
    if (target.brush_broken_predicted)        return;    // already predicted

    // User toggle (Settings → Perf & Net → Predict Breaks). When off,
    // breakables wait for the server's authoritative destroy event
    // before disappearing — adds ~1 RTT of latency before the brush
    // visibly breaks but eliminates rollback flicker on contested or
    // mispredicted hits.
    if (!cvar("cl_predict_breaks")) return;

    // sv_trust_clientbreak: emit the per-shot damage claim BEFORE the
    // local-vs-lethal split so non-lethal hits also drive server-side
    // HP.  The helper internally gates on the server's serverinfo and
    // pm_suppress_sounds (replay), so this is a no-op when trust is off
    // or we're inside a reconcile-replay pass.
    CSQC_SendBreakClaim(target, damage);

    // Non-lethal: subtract locally so the NEXT shot fired before the
    // server has acknowledged this one sees the reduced HP. Without this,
    // rapid fire at high ping stacks multiple shots against full HP — the
    // server eventually breaks the brush but CSQC never predicts it, so
    // the attacker hears only impact sounds and no break cue. The server
    // overwrites brush_health on its next SendFlags update, so any
    // over-decrement self-corrects.
    if (damage < target.brush_health)
    {
        target.brush_health -= damage;
        return;
    }

    target.brush_broken_predicted = 1;

    if (cvar("developer"))
        print(sprintf("^5[break-predict]^7 brush ^2#%g^7 style=%g dmg=%g hp=%g\n",
                      num_for_edict(target), target.brush_material, damage, target.brush_health));

    // Hide the brush locally so the shooter sees it disappear instantly.
    // Next solid_brush_SendEntity snapshot with broken=1 confirms, or a
    // round-reset full-HP snapshot clears the flag. If NEITHER arrives
    // (lag-comp rejected the hit server-side, so no SendFlags update),
    // the think below rolls us back.
    target.drawmask = 0;
    target.solid    = SOLID_NOT;

    // Clear any tracked-decal bullet holes attached to this brush so
    // they vanish with the predicted break instead of floating in
    // place for ~1 RTT until the server's CSQC_EVENT_BRUSH_DESTROY
    // arrives and triggers the same cleanup.  Idempotent: if the
    // server confirms first the list is already empty.
    CSQC_BulletHolesRemoveByOwner(target);

    target.think     = CSQC_BreakPredict_Expire;
    target.nextthink = time + BREAK_PREDICT_TIMEOUT;

    vector center = (target.absmin + target.absmax) * 0.5;
    Impact_PlayBreakableBreakSound(center, target.brush_material);

    // Predicted gib spawn — uses the same helpers the server gib events
    // call on remote clients, so the shooter's local debris looks the
    // same as everyone else's (positions are randomised per side but the
    // count + material + bbox are identical). The server's gib events
    // skip this player via the exclude byte, so no doubled gibs. The
    // trailing entnum tags each gib so a rollback via CSQC_BreakPredict_
    // Expire can sweep just these pieces without touching server-spawned
    // debris from other breakables.
    float ds = max(target.brush_max_health, 20);
    float own = num_for_edict(target);
    // Predicted break — derive damage direction from the brush's
    // bbox centre toward the local shooter (us).  Reverses the
    // server's direction so the gibs throw OUT toward the shooter,
    // matching the perception that "I shot it, gibs come at me".
    // The server's authoritative event will overwrite the visual
    // for remote clients; the local shooter only sees the predicted
    // copy via the attacker-exclude byte.  custom_idx=0 → fall
    // back to material-default model; alpha=0 → full opacity.
    // Server can override these via map-editor mdl / alpha2 fields
    // — the attacker's predicted gibs will mismatch briefly on
    // custom-override breakables, acceptable MVP drift.
    vector pred_dir = '0 0 1';
    float pred_force = 0;
    float pred_throw_mode = 0;   // explosion-mode key isn't replicated
                                  // to CSQC, so we can't reliably
                                  // predict the directional kick yet.
                                  // Random-throw look matches both
                                  // the legacy behaviour and the
                                  // server's broadcast for non-
                                  // explosion breakables.
    if (target.brush_material == 0 /*BREAKABLE_GLASS*/)
        CSQC_SpawnGlassGibs(target.absmin, target.absmax, target.brush_cnt, ds, own,
                            pred_throw_mode, pred_dir, pred_force);
    else
        CSQC_SpawnDebrisGibs(target.absmin, target.absmax,
                             target.brush_material, target.brush_cnt,
                             ds, 0, 0, own,
                             pred_throw_mode, pred_dir, pred_force);

    // Matching the server's cleanup: drop any decals still anchored to the
    // brush so they don't float in the air after the predicted break.
    CSQC_BulletHolesRemoveByOwner(target);
};

// Locate the EMPTY/WATER boundary above an underwater point.  Hitscan
// traces ignore liquids, so trace_endpos for an underwater shot lands
// on the BSP floor below — we need the surface above for splash FX.
// Step up in 16qu increments until pointcontents stops returning WATER,
// then refine downward 1qu to sit just above the surface.
// Find the water-entry point along the ray from `from` (player view
// or eye) to `to` (under-water impact).  Steps 4qu along the segment
// until pointcontents flips to CONTENT_WATER, then binary-refines.
// Falls back to a straight-up scan from `to` if the camera ray never
// enters water (e.g. shot from beneath the surface).
vector(vector from, vector to) Impact_FindWaterSurface =
{
    vector seg = to - from;
    float dist = vlen(seg);
    if (dist > 0.5)
    {
        vector dir = seg / dist;
        float step = 4;
        float t = 0;
        while (t < dist)
        {
            vector sp = from + dir * t;
            if (pointcontents(sp) == CONTENT_WATER)
            {
                float lo = t - step; if (lo < 0) lo = 0;
                float hi = t;
                while ((hi - lo) > 0.5)
                {
                    float mid = (lo + hi) * 0.5;
                    if (pointcontents(from + dir * mid) == CONTENT_WATER)
                        hi = mid;
                    else
                        lo = mid;
                }
                return from + dir * hi;
            }
            t = t + step;
        }
    }
    // Fallback: straight-up scan from `to`.
    vector p = to;
    float climbed = 0;
    while (pointcontents(p) == CONTENT_WATER && climbed < 4096)
    {
        p_z += 16;
        climbed += 16;
    }
    while (pointcontents(p) != CONTENT_WATER && climbed > 0)
    {
        p_z -= 1;
        climbed -= 1;
    }
    p_z += 1;
    return p;
};

// Resolve + validate a weapons.cfg particle effect, mirroring Rain_SpawnLandSpray
// (cl_rain.qc): particleeffectnum returns a slot even for an unregistered name,
// so particleeffectquery (non-empty == registered) is the real validator.  A 0
// cache re-resolves every call (weapons.cfg can exec a few frames after CSQC
// init), then sticks once it resolves.
float(float cached, string ename) Debris_Resolve =
{
    if (cached != 0)
        return cached;
    cached = particleeffectnum(ename);
    if (cached != 0 && particleeffectquery(cached, 0) == "")
        cached = 0;   // not registered yet — retry next call
    return cached;
};

// Bullet-impact debris — a cheap, NO-BOUNCE impact burst flung off the surface:
//   1. CHUNKS  (stone mode 0 / dirt mode 1) — DIE on contact, so no floor jitter
//   2. DUST    (shared) — a soft expanding cloud
//   3. SPARKS  (shared) — a few hot additive streaks
// Particles can't bounce AND come to rest in FTE — a bouncing part snap-jitters
// until `die` (the >10u trace gate vs the auto-settle threshold, p_script.c:
// 7508/7581) — so the chunks DIE on first contact instead, which is clean.
// The CALLER gates on material (no flesh) and, on the local predicted path, on
// the per-shot cap.  `dir` = surface normal * cl_impact_debris_force is the
// launch velocity (each effect's veladd scales it per layer).
void(vector pos, vector normal) CSQC_SpawnImpactDebris =
{
    if (!cvar("cl_impact_debris"))
        return;

    float n = cvar("cl_impact_debris_count");
    if (n <= 0) n = 4;
    float force = cvar("cl_impact_debris_force");
    if (force <= 0) force = 110;
    vector dir = normal * force;

    // Pick the chunk colour by mode (stone vs dirt); dust + sparks are shared.
    float chunks;
    if (cvar("cl_impact_debris_mode"))
    {
        debris_effect_dirt = Debris_Resolve(debris_effect_dirt, "weapons.debris_dirt");
        chunks = debris_effect_dirt;
    }
    else
    {
        debris_effect_rock = Debris_Resolve(debris_effect_rock, "weapons.debris_rock");
        chunks = debris_effect_rock;
    }
    debris_effect_dust  = Debris_Resolve(debris_effect_dust,  "weapons.debris_dust");
    debris_effect_spark = Debris_Resolve(debris_effect_spark, "weapons.debris_spark");

    // n chunks (the effect's own count x n) + one dust burst + one spark burst.
    if (chunks != 0)
        pointparticles(chunks, pos, dir, n);
    if (debris_effect_dust != 0)
        pointparticles(debris_effect_dust, pos, dir, 1);
    if (debris_effect_spark != 0)
        pointparticles(debris_effect_spark, pos, dir, 1);
};

// Bullet wall-bang EXIT dust smoke — spawned where a PENETRATING shot LEAVES the
// far face (never on entries; the caller gates on a non-zero exit_dir + non-flesh).
// `dir` is the bullet's SHOT LINE out the far face (eye->exit), so the plume grows
// along the actual exit angle — an angled shot leans that way, not perpendicular
// to the wall.  Escalates SIZE (per-puff particle count — a denser plume reads as
// bigger) and OFFSET across N puffs; the recipe owns the expand/fade.
//
// Uses weapons.metal_impact — the SAME puff as the prop_car tailpipe, the prop
// slide/bump contact smoke and the Prop Hunt decloak, so every smoke in the game is
// one look.  (Was weapons.exitsmoke, a smaller pale spinning gfx/smoke puff; that
// recipe is still in particles/impacts.cfg, now unreferenced.)
void(vector pos, vector dir) CSQC_BulletExitSmoke =
{
    if (!cvar("cl_impact_exitsmoke"))
        return;

    vector d = normalize(dir);
    if (d == '0 0 0')
        return;

    // metal_impact is `+`-APPEND-ONLY (its base r_part block is commented out at
    // particles/impacts.cfg:190), so particleeffectquery returns "" for it and
    // Debris_Resolve — which treats an empty query as "not registered" — would
    // scrub the id to 0 every call and silently disable this.  Resolve RAW.
    //
    // ONLY 0 MEANS FAILURE.  Engine contract, PF_cs_particleeffectnum
    // (pr_csqc.c:3775-3777): "0 for error, non-0 for success. >0 match server,
    // <0 are client-only."  A particle-SCRIPT effect is client-only, so it always
    // comes back NEGATIVE (the search loop returns -i, i starting at 1); a positive
    // id only ever comes from a server precache, and nothing in this mod calls
    // particleeffectnum server-side.  So `<= 0` rejects every id we can ever get,
    // and `!= -1` throws away the perfectly valid first client slot.  Test `!= 0`.
    float eid = exitsmoke_effect;
    if (eid == 0)
    {
        eid = particleeffectnum("weapons.metal_impact");
        if (eid != 0)
            exitsmoke_effect = eid;   // only ever cache a VALID id (cfg can exec late)
    }
    if (eid == 0)
        return;

    float n = cvar("cl_impact_exitsmoke_count");
    if (n <= 0) n = 4;

    // This recipe carries no `veladd`, so the pointparticles velocity argument is
    // inert here (p_script.c:5229-5235 — dir only ever scales veladd, and with
    // areaspread/spawnvel also 0 the axis is unused too); every puff rises on the
    // recipe's own `velbias 0 0 30`.  The "leaves the far face" read therefore
    // comes from POSITION, not launch velocity: successive puffs are staggered
    // further out along the shot line.  If the old outward spray is wanted back,
    // it needs a `veladd 1` clone of the recipe — adding veladd to +metal_impact
    // itself would also fling the tailpipe/contact/decloak puffs.
    float i;
    for (i = 0; i < n; i = i + 1)
    {
        float dens  = 1 + i;                       // successive puffs THICKER
        vector ppos = pos + d * (4 + i * 9);       // ...and further out ALONG the shot line
        pointparticles(eid, ppos, d, dens);
    }
};

// ============================================================================
//  Penetration-exit debris CHIPS — small material-matched IQM chips thrown out
//  the far face alongside the exit smoke (models/gibs/<mat>/<mat>_debris.iqm,
//  9 geomset variants per set, authored 5x + near-uniform so the random .scale
//  — not the bake — decides in-game size).
//  Purely cosmetic client entities: MOVETYPE_BOUNCE like the breakable gibs,
//  then a predraw alpha fade + remove (no gib in the mod fades — chips do).
//  classname "csqc_debris" so the round-restart sweep (CSQC_ShellsWipeAll)
//  clears them with the shells/gibs for free.
// ============================================================================

.float chip_expire;             // time this chip finishes fading + removes
float chips_last_action_id;     // per-shot cap scope (mirrors debris_last_action_id)
float chips_per_shot_count;
float chip_models_loaded;       // lazy one-shot precache guard (CSQC_LoadDebrisModels pattern)

void() CSQC_LoadImpactChipModels =
{
    if (chip_models_loaded)
        return;
    precache_model("models/gibs/wood/wood_debris.iqm");
    precache_model("models/gibs/rock/rock_debris.iqm");
    precache_model("models/gibs/glass/glass_debris.iqm");
    precache_model("models/gibs/metal/metal_debris.iqm");
    chip_models_loaded = TRUE;
};

// Material -> chip set.  Flesh never reaches here (caller gate); anything that
// isn't wood/glass/metal reads as masonry -> rock chips.
string(float mat) Chip_ModelForMat =
{
    if (mat == IMPACT_MAT_WOOD)  return "models/gibs/wood/wood_debris.iqm";
    if (mat == IMPACT_MAT_GLASS) return "models/gibs/glass/glass_debris.iqm";
    if (mat == IMPACT_MAT_METAL || mat == IMPACT_MAT_METAL_NODECAL)
        return "models/gibs/metal/metal_debris.iqm";
    return "models/gibs/rock/rock_debris.iqm";
};

// PARTICLE MODE (cl_impact_chips_mode 1): per-material engine effects
// (weapons.impactchips_* in particles/impacts.cfg — the 9 variants are baked
// as separate <mat>_debris1..9.iqm files there, since model-particles can't
// pick geomsets).  Lazily resolved like the other impact effects.
float chipfx_wood;
float chipfx_rock;
float chipfx_glass;
float chipfx_metal;
float chipfx_wood_entry;    // entry-side spall variants (slower, wide-cone configs)
float chipfx_rock_entry;
float chipfx_glass_entry;
float chipfx_metal_entry;

float(float mat, float entry) ChipFx_ForMat =
{
    if (mat == IMPACT_MAT_WOOD)
    {
        if (entry)
        {
            chipfx_wood_entry = Debris_Resolve(chipfx_wood_entry, "weapons.impactchips_wood_entry");
            return chipfx_wood_entry;
        }
        chipfx_wood = Debris_Resolve(chipfx_wood, "weapons.impactchips_wood");
        return chipfx_wood;
    }
    if (mat == IMPACT_MAT_GLASS)
    {
        if (entry)
        {
            chipfx_glass_entry = Debris_Resolve(chipfx_glass_entry, "weapons.impactchips_glass_entry");
            return chipfx_glass_entry;
        }
        chipfx_glass = Debris_Resolve(chipfx_glass, "weapons.impactchips_glass");
        return chipfx_glass;
    }
    if (mat == IMPACT_MAT_METAL || mat == IMPACT_MAT_METAL_NODECAL)
    {
        if (entry)
        {
            chipfx_metal_entry = Debris_Resolve(chipfx_metal_entry, "weapons.impactchips_metal_entry");
            return chipfx_metal_entry;
        }
        chipfx_metal = Debris_Resolve(chipfx_metal, "weapons.impactchips_metal");
        return chipfx_metal;
    }
    if (entry)
    {
        chipfx_rock_entry = Debris_Resolve(chipfx_rock_entry, "weapons.impactchips_rock_entry");
        return chipfx_rock_entry;
    }
    chipfx_rock = Debris_Resolve(chipfx_rock, "weapons.impactchips_rock");
    return chipfx_rock;
};

// ---------------------------------------------------------------------------
// WALL-TEXTURE chips (cl_impact_chips_walltex, entity mode only): sample the
// struck surface's texture name at the TRUE hit point and dress the chip in it
// via `.forceshader` — ONE shader handle overrides every surface on the model
// (gl_alias.c picks e->forcedshader over the skin), and it composes with the
// setcustomskin geomset pick (independent visedict fields), so the chosen
// variant mesh simply renders with the wall's texture.
//
// The shader is registered per texture as "chipwall_<name>" — the mod's first
// `rgbgen lightingdiffuse` body (model lighting) + `alphagen entity` +
// blendFunc so the predraw fade keeps working (a custom forceshader does NOT
// inherit the default skin path's implicit entity-alpha handling).
// shaderforname is idempotent and re-called on every burst, so a vid_restart
// re-registers automatically (the P79 dangling-shader lesson).
//
// Availability gate: the loose textures/<name>.png must exist (fopen reads
// through the whole VFS incl. pk3 — the whichpack-misses-loose-files trap; the
// WAD pipeline ships every mod wall texture flat).  Missing image (mounted-map
// content etc.) -> return 0 -> the painted chip texture, never a checkerboard.
// Results are memoized in a tiny ring (getsurfacetexture returns a TEMPSTRING,
// so cache entries are strzone'd).
// ---------------------------------------------------------------------------

const float CHIPWALL_CACHE = 24;
string chipwall_names[24];      // literal dim MUST equal CHIPWALL_CACHE
float  chipwall_ok[24];
float  chipwall_count;

float(string tex) Chip_WallTexUsable =
{
    float seen = chipwall_count;
    if (seen > CHIPWALL_CACHE) seen = CHIPWALL_CACHE;
    float i;
    for (i = 0; i < seen; i = i + 1)
        if (chipwall_names[i] == tex)
            return chipwall_ok[i];

    float fh = fopen(strcat("textures/", tex, ".png"), FILE_READ);
    float ok = 0;
    if (fh >= 0)
    {
        ok = 1;
        fclose(fh);
    }

    float slot = chipwall_count - floor(chipwall_count / CHIPWALL_CACHE) * CHIPWALL_CACHE;
    if (chipwall_names[slot] != "")
        strunzone(chipwall_names[slot]);
    chipwall_names[slot] = strzone(tex);
    chipwall_ok[slot]    = ok;
    chipwall_count       = chipwall_count + 1;
    return ok;
};

// Returns a shader handle to force onto the chips, or 0 = use the painted set.
float(entity e, vector p) Chip_WallShader =
{
    if (e != world && wasfreed(e))     // breakable shattered mid-flight -> sample the world behind it
        e = world;
    string tex = Surf_TexAtPoint(e, p);   // TEMPSTRING — consume before the pool churns
    if (tex == "")
        return 0;
    if (!Chip_WallTexUsable(tex))
        return 0;

    // GoldSrc '{'-masked textures: a shader NAME must not start with '{' (the
    // block-open token — the spray/infodecal lesson); key on the stem and
    // alphatest the masked pixels.  With alphagen entity the fade drops below
    // the GE128 test halfway through — an early pop-out, acceptable for spall.
    float masked  = (substring(tex, 0, 1) == "{");
    string stem   = masked ? substring(tex, 1, strlen(tex) - 1) : tex;
    string mask_l = masked ? "\t\talphaFunc GE128\n" : "";

    string body = sprintf(
        "{\n\t{\n%s\t\trgbgen lightingdiffuse\n\t\talphagen entity\n\t\tblendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n\t\tmap \"textures/%s.png\"\n\t}\n}",
        mask_l, tex);
    return shaderforname(strcat("chipwall_", stem), body);
};

// Per-frame: fade the chip's last 0.8s to transparent, then remove.  Never sets
// alpha to exactly 0 (FTE treats 0 as "unset" = opaque); left > 0 is guaranteed
// on the fade branch and the entity is removed the frame it expires.
// MUST return PREDRAW_AUTOADD on the visible path — PREDRAW_NEXT means "skip
// drawing entirely" (for removed/explicitly-addentity'd ents) and left the
// chips simulated but invisible.
float() CSQC_ImpactChipPredraw =
{
    float left = self.chip_expire - time;
    if (left <= 0)
    {
        remove(self);
        return PREDRAW_NEXT;
    }
    if (left < 0.8)
        self.alpha = left / 0.8;
    return PREDRAW_AUTOADD;    // engine addentity(self)'s the chip for us
};

// Entry-side per-shot cap state — SEPARATE from the exit counters so a wallbang
// shows BOTH its entry burst and its exit burst (a shared counter would let
// whichever fires first consume the other's cap).
float entry_chips_last_action_id;
float entry_chips_per_shot_count;

// Throw a burst of chips.  Two flavours sharing one spawner:
//   EXIT  (entry=FALSE): `dir` = the bullet's shot line out the far face (same
//         vector the exit smoke sprays along) — fast, fairly straight.
//   ENTRY (entry=TRUE):  `dir` = the struck surface's normal — slow SPALL back
//         out of the wall in a much wider random cone ("comes back at you").
// Per-shot capped per SIDE (shotguns/multi-wall penetrations don't multiply;
// remote impacts pass action == -1 = one burst per event).
// `wallshader` (entity mode): non-zero = a chipwall_* shader handle sampled from
// the struck surface — forced onto each chip so it "wears the wall"; 0 = painted.
void(vector pos, vector dir, float mat, float action, float entry, float wallshader) CSQC_SpawnImpactChips =
{
    float allow = 1;
    if (action != -1)
    {
        float cap = cvar("cl_impact_chips_per_shot");
        if (entry)
        {
            if (action != entry_chips_last_action_id)
            {
                entry_chips_last_action_id = action;
                entry_chips_per_shot_count = 0;
            }
            allow = (cap <= 0 || entry_chips_per_shot_count < cap);
            if (allow)
                entry_chips_per_shot_count = entry_chips_per_shot_count + 1;
        }
        else
        {
            if (action != chips_last_action_id)
            {
                chips_last_action_id = action;
                chips_per_shot_count = 0;
            }
            allow = (cap <= 0 || chips_per_shot_count < cap);
            if (allow)
                chips_per_shot_count = chips_per_shot_count + 1;
        }
    }
    if (!allow)
        return;

    vector d = normalize(dir);
    if (d == '0 0 0')
        return;

    // per-side tuning: entry = slow + wide, exit = fast + fairly straight
    float force;
    float n;
    if (entry)
    {
        force = cvar("cl_impact_chips_entry_force");
        if (force <= 0) force = 70;
        n = cvar("cl_impact_chips_entry_count");
    }
    else
    {
        force = cvar("cl_impact_chips_force");
        if (force <= 0) force = 260;
        n = cvar("cl_impact_chips_count");
    }
    if (n <= 0) n = 2;

    // MODE 1: engine model-particles — the chips become temp-entities simulated
    // in C (hardcoded gravity/bounce/rest + linear fade; see particles/impacts.cfg).
    // dir carries the launch speed (effect veladd 1); the count arg = burst size;
    // the _entry effect variants carry the wider scatter in their config.
    // Falls through to the entity path if the effect config isn't loaded.
    if (cvar("cl_impact_chips_mode") == 1)
    {
        float fx = ChipFx_ForMat(mat, entry);
        if (fx != 0)
        {
            pointparticles(fx, pos, d * force, n);
            return;
        }
    }

    CSQC_LoadImpactChipModels();
    string mdl = Chip_ModelForMat(mat);

    float life = cvar("cl_impact_chips_life");
    if (life <= 0) life = 10;
    float smin = cvar("cl_impact_chips_scale_min");
    float smax = cvar("cl_impact_chips_scale_max");
    if (smin <= 0) smin = 0.16;
    if (smax < smin) smax = smin;

    float i;
    for (i = 0; i < n; i = i + 1)
    {
        entity chip = spawn();
        chip.classname = "csqc_debris";           // swept by CSQC_ShellsWipeAll on round restart
        setmodel(chip, mdl);
        // pick one of the 9 authored variants (geomsets baked by iqmtool; 0-BASED —
        // id 0 is also the engine default, so an unpicked chip still shows variant 0)
        setcustomskin(chip, "", strcat("geomset 0 ", ftos(floor(random() * 9)), "\n"));
        if (wallshader > 0)
            chip.forceshader = wallshader;   // wear the wall's texture (composes with the geomset pick)
        setsize(chip, '0 0 0', '0 0 0');
        setorigin(chip, pos);

        chip.scale     = smin + random() * (smax - smin);
        chip.movetype  = MOVETYPE_BOUNCE;
        chip.solid     = SOLID_NOT;
        chip.drawmask  = MASK_ENGINE;
        chip.renderflags = cvar("cl_debris_shadows") ? 0 : RF_NOSHADOW;  // cast into the r_shadows-2 map
                               // (one tiny extra depth draw per chip).  NOTE: cl_impact_chips_mode 1
                               // (particle-model path) stays shadowless — engine model-particles default RF_NOSHADOW.
        chip.alpha     = 1;
        if (entry)
        {
            // spall: weak launch out of the wall, scatter LARGE relative to the
            // speed (lateral jitter greater than the base speed itself = wide cone)
            chip.velocity  = d * (force * (0.5 + random() * 0.8));
            chip.velocity_x += (random() - 0.5) * force * 1.2;
            chip.velocity_y += (random() - 0.5) * force * 1.2;
            chip.velocity_z += 30 + random() * 40;
        }
        else
        {
            // exit: fast along the shot line, slight jitter, small up-bias arc
            chip.velocity  = d * (force * (0.7 + random() * 0.6));
            chip.velocity_x += (random() - 0.5) * 60;
            chip.velocity_y += (random() - 0.5) * 60;
            chip.velocity_z += 40 + random() * 50;
        }
        chip.avelocity = [random() * 600, random() * 600, random() * 600];

        chip.chip_expire = time + life + random() * 3;   // stagger so a burst doesn't blink out together
        chip.predraw     = CSQC_ImpactChipPredraw;
    }
};

// ============================================================================
//  Tracer-synced delayed impact cosmetics
// ----------------------------------------------------------------------------
//  With tracers on, the VISIBLE impact FX (particles + debris + dlight + bullet
//  hole + ricochet ping) are DEFERRED so they land when the tracer streak reaches
//  the wall — the bullet "whizzes" out then hits.  The bullet itself stays instant
//  hitscan; the gameplay-coupled bits (predicted breakable break/sound, autosound
//  reconcile) also stay INSTANT in CSQC_BulletImpact because they touch the live
//  trace_ent.  Material is classified ONCE at fire time and carried, so the
//  glass/metal/wood decal+effect at arrival is correct with zero re-classify.
//  Arrival = cltime + distance/cl_tracer_travel_speed (the streak's own speed).
//  cl_tracer_impact_delay 0 (or cl_tracer 0) restores instant FX.
// ============================================================================
const float PEND_MAX = 32;
vector pend_pos[PEND_MAX];
vector pend_normal[PEND_MAX];
float  pend_mat[PEND_MAX];
float  pend_metalphys[PEND_MAX];
float  pend_action[PEND_MAX];
entity pend_ent[PEND_MAX];
float  pend_water[PEND_MAX];
float  pend_play_ric[PEND_MAX];
float  pend_arrival[PEND_MAX];
float  pend_active[PEND_MAX];
vector pend_exit_dir[PEND_MAX];  // non-zero = penetration exit; also the shot dir the smoke sprays along
// Whether this impact belongs to a shotgun BLAST, captured at enqueue time.
//
// bh_shotgun_blast is a latch that CSQC_PredictedShotgunImpact raises around its
// pellet loop and lowers immediately after (sh_weapon_logic.qc), so the per-shot
// decal/effect caps don't clip a spray down to one pellet.  That worked when
// impacts drew immediately.  They no longer do — they park here for the tracer's
// flight time and draw from CSQC_ProcessPendingImpacts, by which point the latch
// is long since back to 0.  Every pellet of a blast also shares one
// wep_action_id, so all of them land in the same per-shot cap bucket and 7 of 8
// were being thrown away.  That is the "shotgun leaves 1 bullet impact" bug, and
// it affected every multi-pellet weapon in the mod.
//
// So the decision has to travel with the impact, exactly as play_ric already
// does (decided while the latch is live, carried, replayed at draw time).
float  pend_blast[PEND_MAX];

// Fire the VISIBLE impact cosmetics at `pos`.  Extracted verbatim from the old
// inline CSQC_BulletImpact body so the look is identical — only the call timing
// changes.  `ent` is re-validated (wasfreed) before a breakable decal attaches.
void(vector pos, vector normal, float mat, float metalphys, float action, entity ent, float play_ric, vector exit_dir, float blast) CSQC_FireImpactCosmetics =
{
    float r;

    // Re-assert the blast bypass for the duration of this impact's cosmetics.
    // The caps live downstream in Impact_SpawnParticles and
    // CSQC_BulletHole_CapAllows, which read bh_shotgun_blast live — and by the
    // time a parked impact drains, the firing code that raised it has long
    // since lowered it.  Saved/restored rather than assigned so an inline
    // (point-blank) impact fired from inside a live pellet loop doesn't clear
    // the latch out from under the pellets that follow it.
    float saved_blast = bh_shotgun_blast;
    bh_shotgun_blast = blast;

    vector offset_pos = pos + normal * Impact_ParticleOffset();

    Impact_SpawnParticles(offset_pos, normal, mat);

    // Wall-texture chips: sample the struck surface ONCE per impact event, at the
    // TRUE hit point (pre-offset — getsurfacenearpoint wants a point ON the wall).
    // Entity mode only; 0 = painted chip textures (also the mode-1/missing-image path).
    float chip_wallshader = 0;
    if (cvar("cl_impact_chips") && cvar("cl_impact_chips_walltex")
        && cvar("cl_impact_chips_mode") != 1
        && mat != IMPACT_MAT_FLESH && mat != IMPACT_MAT_FLESH_LETHAL)
        chip_wallshader = Chip_WallShader(ent, pos);

    // Wall-bang EXIT: escalating dust smoke out the far face.  Only on the
    // penetration-exit impact (non-zero exit_dir = the shot line), not through flesh (that's blood).
    if (exit_dir != '0 0 0' && mat != IMPACT_MAT_FLESH && mat != IMPACT_MAT_FLESH_LETHAL)
    {
        CSQC_BulletExitSmoke(offset_pos, exit_dir);
        // nettest: material-matched debris chips thrown out the exit alongside the smoke
        if (cvar("cl_impact_chips"))
            CSQC_SpawnImpactChips(offset_pos, exit_dir, mat, action, FALSE, chip_wallshader);
    }

    if (!metalphys && mat != IMPACT_MAT_FLESH && mat != IMPACT_MAT_FLESH_LETHAL)
    {
        // nettest: ENTRY-side chip spall — slow, wide-cone chips back out of the wall
        // on every impact.  Gated to NON-exit events (exit_dir zero) so the exit hole
        // doesn't stack spall on top of its own fast exit burst; the entry impact of a
        // wallbang is its own event and still sprays.  Own per-shot cap inside.
        if (exit_dir == '0 0 0' && cvar("cl_impact_chips") && cvar("cl_impact_chips_entry"))
            CSQC_SpawnImpactChips(offset_pos, normal, mat, action, TRUE, chip_wallshader);

        float allow_debris = 1;
        if (action != -1)   // -1 = no per-shot cap (remote impacts: each its own event)
        {
            if (action != debris_last_action_id)
            {
                debris_last_action_id = action;
                debris_per_shot_count = 0;
            }
            float debris_cap = cvar("cl_impact_debris_per_shot");
            allow_debris = (debris_cap <= 0 || debris_per_shot_count < debris_cap);
            if (allow_debris)
                debris_per_shot_count = debris_per_shot_count + 1;
        }
        if (allow_debris)
            CSQC_SpawnImpactDebris(offset_pos, normal);
    }

    CSQC_AddImpactLight(pos, normal);

    // Static world (ent==world) always gets the hole; a breakable that shattered
    // mid-flight (wasfreed) is skipped so the decal doesn't orphan.
    if (Impact_ShouldSpawnHole(mat) && (ent == world || !wasfreed(ent)))
        CSQC_SpawnBulletHole(pos, normal, ent, mat, action);   // action_id scopes the per-shot decal cap

    if (play_ric)
    {
        // Material-driven bullet ping.  The FINE sound set is re-derived here from
        // (ent, pos) — the same pair Chip_WallShader above already samples — so the LOCAL
        // path (trace in hand) and the REMOTE path (position + the target entnum the wire
        // ALREADY carries, resolved in cl_main.qc before CSQC_BulletImpactRemote) land on
        // the same sound with ZERO wire changes.  IMPACT_MAT_* stays the PARTICLE code; it
        // is far too coarse to key sound off (DEFAULT covers concrete/plaster/cardboard/
        // plastic/rubber/dirt).  `metalphys` is no longer consulted here: phys props now
        // resolve through PropMat_For and ping as what they actually are, which is exactly
        // what the old blanket "every phys prop pings metal" branch is being replaced by.
        string ricsnd = "";
        if (mat == IMPACT_MAT_FLESH || mat == IMPACT_MAT_FLESH_LETHAL)
        {
            // FLESH DOES NOT RICOCHET, and until now it did.
            //
            // MatSnd_SetForImpact is skipped for flesh (a body has no material
            // entry), so `ricsnd` stayed empty and every flesh impact fell into
            // the ric1-5 fallback below — a bullet PING off a person.  Under
            // gunfire that is masked by the shot itself, which is why it survived
            // this long; the case that exposed it has no gunshot at all.  Standing
            // on a cockroach fires one IMPACT_MAT_FLESH event (mon_cockroach.qc's
            // squash splat) into a silent room, and it pinged like a wall hit.
            //
            // The HL flesh impact set is what belongs here and was already on disk
            // and already precached (sh_customdefs.qc:1551) for the func_breakable
            // FLESH style — the same six samples GoldSrc uses for a bullet into
            // meat.  Quieter than a ric on purpose: it is a texture under the blood
            // and the hit marker, not an event of its own.
            r = floor(random() * 6) + 1;
            r = bound(1, r, 6);
            ricsnd = sprintf("sounds/debris/impact_fleshhl%g.wav", r);
            pointsound(offset_pos, ricsnd, 0.7, ATTN_NORM);
        }
        else
        {
            float ricset = MatSnd_SetForImpact(ent, pos, mat);
            if (ricset >= 0)
                ricsnd = MatSnd_Pick(ricset, MSND_BULLET);

            if (ricsnd != "")
                pointsound(offset_pos, ricsnd, 1, ATTN_NORM);
            else
            {
                // Fallback ONLY: anything that didn't resolve (e.g. a client with no
                // scripts/materialsounds.txt).  Kept as a FALLBACK, not a layer —
                // layering ric under every material would muddy 8 distinct timbres
                // and double the pointsound count on a spray.
                r = floor(random() * 5) + 1;
                r = bound(1, r, 5);
                pointsound(offset_pos, sprintf("sounds/weapons/ric%g.wav", r), 1, ATTN_NORM);
            }
        }
    }

    bh_shotgun_blast = saved_blast;
};

// Park an impact to fire at `arrival` — or fire it NOW if there's no meaningful
// delay (tracers/delay off, or point-blank).
void(vector pos, vector normal, float mat, float metalphys, float action, entity ent, float water, float play_ric, float arrival, vector exit_dir, float blast) CSQC_EnqueueImpact =
{
    if (arrival <= cltime + 0.002)
    {
        if (water) CSQC_Rain_SpawnBulletWaterSplash(pos);
        else       CSQC_FireImpactCosmetics(pos, normal, mat, metalphys, action, ent, play_ric, exit_dir, blast);
        return;
    }
    float i; float slot = -1;
    for (i = 0; i < PEND_MAX; i = i + 1)
        if (!pend_active[i]) { slot = i; break; }
    if (slot < 0)
    {
        // Ring full (extreme spray) — flush the soonest-arriving slot early.
        slot = 0;
        for (i = 1; i < PEND_MAX; i = i + 1)
            if (pend_arrival[i] < pend_arrival[slot]) slot = i;
        if (pend_water[slot]) CSQC_Rain_SpawnBulletWaterSplash(pend_pos[slot]);
        else CSQC_FireImpactCosmetics(pend_pos[slot], pend_normal[slot], pend_mat[slot],
                                      pend_metalphys[slot], pend_action[slot], pend_ent[slot], pend_play_ric[slot], pend_exit_dir[slot], pend_blast[slot]);
    }
    pend_active[slot]    = 1;
    pend_pos[slot]       = pos;
    pend_normal[slot]    = normal;
    pend_mat[slot]       = mat;
    pend_metalphys[slot] = metalphys;
    pend_action[slot]    = action;
    pend_ent[slot]       = ent;
    pend_water[slot]     = water;
    pend_play_ric[slot]  = play_ric;
    pend_arrival[slot]   = arrival;
    pend_exit_dir[slot]  = exit_dir;
    pend_blast[slot]     = blast;
};

// Per-frame drain — called next to CSQC_DrawImpactLights.  Fires any parked
// impact whose arrival time has passed.
void() CSQC_ProcessPendingImpacts =
{
    float i;
    for (i = 0; i < PEND_MAX; i = i + 1)
    {
        if (!pend_active[i]) continue;
        if (cltime < pend_arrival[i]) continue;
        pend_active[i] = 0;
        if (pend_water[i])
            CSQC_Rain_SpawnBulletWaterSplash(pend_pos[i]);
        else
            CSQC_FireImpactCosmetics(pend_pos[i], pend_normal[i], pend_mat[i],
                                     pend_metalphys[i], pend_action[i], pend_ent[i], pend_play_ric[i], pend_exit_dir[i], pend_blast[i]);
    }
};

// Full bullet impact: particles + light + ricochet sound
// Called from hitscan prediction (CSQC_PredictedImpact / ShotgunImpact)

void(vector pos, vector normal, float damage, float is_exit) CSQC_BulletImpact =
{
    vector offset_pos;
    float r;

    // No impact on sky surfaces
    // Check slightly into the surface to detect sky
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    // Tracer-synced delay: the VISIBLE FX fire when the streak reaches the wall.
    // Distance from the eye is within ~16qu of the true muzzle->impact length, so
    // it matches the streak's flight time to well under a frame.
    vector eye = (vector)getproperty(VF_ORIGIN);
    float tspeed = cvar("cl_tracer_travel_speed"); if (tspeed <= 0) tspeed = 8000;
    float arrival = cltime;
    if (cvar("cl_tracer") > 0 && cvar("cl_tracer_impact_delay") != 0)
        arrival = cltime + vlen(pos - eye) / tspeed;

    // Water-surface hit — splash on the actual water surface (not trace_endpos,
    // the BSP floor under the water since hitscan ignores liquids), deferred to
    // arrival.  Suppress the wall-impact FX so only the splash plays.
    float impact_was_water = 0;
    if (pointcontents(pos) == CONTENT_WATER)
    {
        vector surf = Impact_FindWaterSurface(eye, pos);
        CSQC_EnqueueImpact(surf, normal, 0, 0, self.wep_action_id, world, 1, 0, arrival, '0 0 0', bh_shotgun_blast);
        impact_was_water = 1;
    }

    // (Dropped weapons used to be skipped here — their bbox sparks read as
    // oversized.  Full-parity now: shooting a dropped gun gets the metal spark +
    // ping like the cabinet, via the tight gun-shaped SOLID_PHYSICS box below.)

    // Pull effect off the surface so it's not flush against the wall
    offset_pos = pos + normal * Impact_ParticleOffset();

    // Local prediction: classify based on what we hit. CSQC can only see
    // player vs. anything-else (func_breakable isn't replicated to CSQC),
    // so most surfaces will use the default impact effect on the local
    // shooter's screen. The server's CSQC_EVENT_IMPACT carries the
    // material byte for the full per-surface picker on remote viewers.
    float mat = Impact_ClassifyLocal(trace_ent);

    // Metal phys object (cabinet / barrel / can / dropped weapon): metal SPARK +
    // light flash only — NO debris chunks and NO decal (METAL_NODECAL already
    // suppresses the hole), plus the dedicated metal bullet ping (not generic ric).
    float is_metalphys = CL_IsMetalPhysObj(trace_ent);

    // Underwater impact: splash is the entire visual — no sparks,
    // dlight, hole, ricochet ping, or breakable thump.  Still register
    // the autosound so weapon prediction reconciles correctly.
    if (impact_was_water)
    {
        CSQC_RecordPredictedAutoSound();
        return;
    }

    // Ricochet gate decided NOW (shotgun: one ric per blast, latched after the
    // first pellet), but the ric SOUND + ALL the visible FX (particles / debris /
    // dlight / hole) are deferred to the streak's arrival via the ring.  The
    // material `mat` and the hit `trace_ent` are captured here while they're
    // valid, so the deferred decal+effect is material-correct.
    float play_ric = 0;
    if (!bh_shotgun_blast || !bh_shotgun_ric_played)
    {
        play_ric = 1;
        if (bh_shotgun_blast)
            bh_shotgun_ric_played = 1;
    }
    // Exit smoke sprays along the shot line out the far face (pos == exit_pos here); '0 0 0'
    // on entries so the cosmetics sink never emits exit smoke on an entry impact.
    vector exit_dir = is_exit ? normalize(pos - eye) : '0 0 0';
    // bh_shotgun_blast is sampled HERE, inside the pellet loop while the latch
    // is still raised — the same reason play_ric is decided here rather than at
    // draw time.  See the pend_blast declaration.
    CSQC_EnqueueImpact(pos, normal, mat, is_metalphys, self.wep_action_id,
                       trace_ent, 0, play_ric, arrival, exit_dir, bh_shotgun_blast);

    // Predicted breakable material thump. Gate on brush_health > 0 so we
    // identify live breakables regardless of their material style — style
    // 0 is BREAKABLE_CONCRETE (a valid material), NOT a "non-breakable"
    // sentinel. Non-breakable func_wall/etc brushes default health = 0,
    // so this correctly separates damageable brushes from static ones.
    // The server's BreakablePlayImpactSound routes the matching multicast
    // event to every OTHER client, so we don't double up locally.
    // Same brush_type gate as the predict-break below — shootable
    // buttons/doors have brush_health > 0 too, but their "thump" cue
    // is the button's own activation sound, not the breakable
    // material sound.
    if (trace_ent && trace_ent.classname != "player"
        && trace_ent.brush_type == BRUSH_TYPE_STATIC
        && trace_ent.brush_health > 0)
        Impact_PlayBreakableSound(offset_pos, trace_ent.brush_material);

    // Predicted breakable destruction: if `damage` would drop the brush's
    // replicated health to zero, play the break sound and hide the brush
    // locally. Works off the brush_health snapshot from the last server
    // update — accurate enough that the attacker sees/hears the break on
    // their killing shot without waiting for the server round-trip.
    CSQC_PredictBreakableBreak(trace_ent, damage);

    CSQC_RecordPredictedAutoSound();
};

// Silent bullet impact: particles + light only (no ricochet)
// Called from melee prediction (CSQC_PredictedMeleeTrace)
void(vector pos, vector normal) CSQC_BulletImpactSilent =
{
    vector offset_pos;

    // Check slightly into the surface to detect sky
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    // Underwater hit: splash only, no sparks/dlight/hole.
    if (pointcontents(pos) == CONTENT_WATER)
    {
        vector surf = Impact_FindWaterSurface((vector)getproperty(VF_ORIGIN), pos);
        CSQC_Rain_SpawnBulletWaterSplash(surf);
        return;
    }

    // Same dropped-weapon bbox suppression as CSQC_BulletImpact.
    if (trace_ent && trace_ent.classname == "csqc_dropped_weapon")
        return;

    offset_pos = pos + normal * Impact_ParticleOffset();

    float mat = Impact_ClassifyLocal(trace_ent);
    Impact_SpawnParticles(offset_pos, normal, mat);
    // Light at the RAW hit position so it sits on the wall and lights
    // outward — feeding offset_pos here would put the light behind the
    // smoke cloud and cause the particle quad to silhouette darkly
    // against the dlight's illuminated patch on the wall.  The extra
    // cl_impact_light_offset lift still applies inside CSQC_AddImpactLight.
    CSQC_AddImpactLight(pos, normal);
    if (Impact_ShouldSpawnHole(mat))
        CSQC_SpawnBulletHole(pos, normal, trace_ent, mat, -1);   // melee: single hit, no per-shot grouping
};

// Forward decl — defined in cl_tracers.qc, compiled later.
void(vector start_pos, vector end_pos) CSQC_SpawnTracer;

// Full impact for other players receiving server events.
// `mat` = IMPACT_MAT_* code from the server multicast — server has full
// trace_ent visibility (including func_breakable.style) and classifies
// per-surface there, so this gets the accurate per-material effect.
// `target` is the BSP entity the trace hit (resolved via the entnum
// that rides along in the CSQC_EVENT_IMPACT payload), or world for
// static-geometry hits. Passing the real target lets bullet-hole
// decals attach to func_breakables on remote-shooter impacts so they
// vanish along with the breakable on CSQC_EVENT_BRUSH_DESTROY.
//
// `shooter_entnum` is the player who fired the shot.  Used to
// reconstruct the tracer's start point at the shooter's current eye
// position.  Not used for any gameplay decision — purely a visual
// anchor.  0 (or a slot we can't resolve) skips the tracer, all
// other effects still play normally.
float() Killcam_Active;	// cl_killcam.qc (compiled later) — mask remote FX during a replay
vector(float weapon_id) CSQC_WeaponMuzzleOffsetVec;	// cl_weapons.qc (compiled later)
float csqc_remote_muz_seq;	// decrementing unique action-id for remote muzzle-flash dedup

void(vector pos, vector normal, float mat, entity target, float shooter_entnum, float is_entry, float action, float blast) CSQC_BulletImpactRemote =
{
    if (Killcam_Active())	// don't bleed live-player impact/tracer FX into the killcam
        return;

    // Check slightly into the surface to detect sky
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    // Underwater remote hit: splash only (no tracer, instant — as before).
    if (pointcontents(pos) == CONTENT_WATER)
    {
        vector surf = Impact_FindWaterSurface((vector)getproperty(VF_ORIGIN), pos);
        CSQC_Rain_SpawnBulletWaterSplash(surf);
        return;
    }

    // Same dropped-weapon bbox suppression as the local variants.  For remote
    // impacts the hit entity arrives as `target` (resolved from the wire entnum).
    if (target && target.classname == "csqc_dropped_weapon")
        return;

    // Resolve the shooter's eye — the tracer start AND the impact-arrival anchor.
    // Skipped for the LOCAL player so we don't double the predicted tracer/impact
    // (the local shot already ran CSQC_BulletImpact + its own tracer).
    vector shooter_eye = pos;
    float has_shooter = 0;
    if (shooter_entnum > 0 && shooter_entnum != player_localentnum)
    {
        // Bots / remote players exist on the client only as a player_visual_proxy
        // (keyed by vis_owner_entnum, NOT .entnum), so the live-entity lookup missed
        // them and no tracer drew for a spectator.  Resolve the proxy first — but a
        // dead player's CORPSE proxy shares vis_owner_entnum with their RESPAWNED
        // proxy, so a bare findfloat can return the corpse and anchor the tracer at
        // the death-spot ("across the map").  Walk the chain and take the LIVE one.
        // (Gate on vis_is_dead — vis_is_corpse is SSQC-only, always 0 in CSQC.  Same
        // precedent as the extrap/killcam/lookatname owner-keyed lookups.)
        entity shooter = world;
        entity sp;
        for (sp = findchain(classname, "player_visual_proxy"); sp; sp = sp.chain)
        {
            if (sp.vis_owner_entnum != shooter_entnum || sp.vis_is_dead)
                continue;
            shooter = sp;
            break;
        }
        if (shooter && shooter != world)
        {
            float eh = PM_VIEW_OFS_z; if (eh <= 0) eh = 22;
            // Start the tracer at the shooter's actual per-weapon MUZZLE (the offset
            // configured for that gun) instead of a generic chest point — applied in
            // the shooter's aim basis (pitch+yaw, from vis_pitch + vis_aim_yaw, the
            // CLEAN aim with no leg-twist).  Bone-attached weapons (no scalar offset)
            // fall back to the generic gun-line.
            makevectors([shooter.vis_pitch, shooter.vis_aim_yaw, 0]);
            vector mo = CSQC_WeaponMuzzleOffsetVec(shooter.vis_weapon_id);
            if (mo != '0 0 0')
                shooter_eye = shooter.origin + [0, 0, eh] + v_forward * mo_x + v_right * mo_y - v_up * mo_z;
            else
                shooter_eye = shooter.origin + [0, 0, eh - 10] + v_forward * 14 + v_right * 5;
            // Muzzle FLASH for remote shots while DEAD/spectating (no local gun to
            // clobber the shared sprite state; a unique decrementing action-id dodges
            // the dedup).  STAT_IS_DEAD avoids needing spec_target (declared later).
            if (getstatf(STAT_IS_DEAD))
            {
                csqc_remote_muz_seq = csqc_remote_muz_seq - 1;
                CSQC_MuzzleFlashAtWorld(shooter_eye, csqc_remote_muz_seq);
            }
        }
        else
        {
            shooter = findfloat(world, entnum, shooter_entnum);
            if (shooter && shooter != world)
            {
                makevectors([0, shooter.angles_y, 0]);
                shooter_eye = shooter.origin + shooter.view_ofs - '0 0 10' + v_forward * 14 + v_right * 5;
            }
        }
        // MONSTERS.  Neither lookup above can reach one - both search CSQC
        // entities, and a monster is a plain engine-networked entity with no
        // CSQC counterpart - so `shooter` is world here for every round any NPC
        // in this game has ever fired, and the tracer below was skipped.  See
        // Montrace_ResolveMuzzle (cl_monstertrace.qc), which reaches the engine
        // entity set through getentity() and gates on the same per-map monster
        // modelindex registry the local bullet sweep already uses.
        float mon_anchor = FALSE;
        if ((!shooter || shooter == world) && is_entry)
        {
            mon_anchor = Montrace_ResolveMuzzle(shooter_entnum);
            if (mon_anchor)
            {
                shooter_eye = montrace_muzzle;
                montrace_dbg_tracers = montrace_dbg_tracers + 1;
            }
            else
                montrace_dbg_tracefail = montrace_dbg_tracefail + 1;
        }

        if (((shooter && shooter != world) || mon_anchor) && is_entry)
        {						// penetration EXIT (is_entry=0): decal
            has_shooter = 1;				// only, NO tracer (entry drew it) + no
            CSQC_SpawnTracer(shooter_eye, pos);		// travel delay so the exit decal is instant
        }
    }

    // Defer the wall FX so they land when that shooter's streak reaches the wall
    // (same speed the streak flies).  No delay if there's no tracer.
    float tspeed = cvar("cl_tracer_travel_speed"); if (tspeed <= 0) tspeed = 8000;
    float arrival = cltime;
    if (has_shooter && cvar("cl_tracer") > 0 && cvar("cl_tracer_impact_delay") != 0)
        arrival = cltime + vlen(pos - shooter_eye) / tspeed;

    // mat = server-classified material (glass/metal/wood — accurate).  `action` = the
    // shooter+shot key from the wire, so the per-shot bullet-hole cap (and the debris cap)
    // scope a remote penetrating shot's entry+exit just like a local one.
    // play_ric = is_entry: the penetration EXIT (is_entry=0) still spawns its decal/
    // particles but plays NO ricochet ping — the entry already pinged, and a 2nd ping
    // was the "doubled sound" (a pointsound, so the CHAN_WEAPON mute couldn't catch it,
    // and it bleeds into the death-cam delay where Killcam_Active() is false).
    // Exit smoke sprays along the shot line from the shooter's eye through the exit; '0 0 0' on
    // entries.  Fall back to the surface normal if the shooter entity wasn't resolved this frame.
    vector exit_dir = is_entry ? '0 0 0'
                    : ((shooter_eye != pos) ? normalize(pos - shooter_eye) : normal);
    // A server impact with NO shooter (entnum 0) is not part of anybody's shot, so it must not
    // be billed to one.  The cockroach squash is the case that exists today: mon_cockroach.qc
    // deliberately sends W_ImpactEffectSend(..., world, world, 1) because nothing client-side
    // predicts a squash.
    //
    // impact_per_shot_effect_count (:174) is a free-running global that EVERY impact effect
    // increments, but that ONLY the local player's own fire resets — CSQC_Impact_ResetShot has
    // five call sites and all five are trigger pulls.  So once cl_impact_effects_per_shot
    // (default 3, sh_cvar_table.qc:855) is spent, Impact_SpawnParticles returns at the cap
    // (:201-206) and takes CSQC_SpawnBloodDecals (:223-224) down with it — the decal call sits
    // BELOW the early return.
    //
    // That is why a squashed roach marks the floor only sometimes: the mark survives exactly as
    // long as the budget left over from your last shot, and one shotgun blast spends it all.
    // The squash still SOUNDS right either way, which is what made it look random — rch_smash
    // is played server-side unconditionally and the flesh ping is fired from
    // CSQC_FireImpactCosmetics, outside the capped function.
    //
    // Note this also un-caps monster gunfire and other players' impacts, which were silently
    // limited to "3 since you last fired" by the same global.
    if (shooter_entnum <= 0)
        CSQC_Impact_ResetShot();

    CSQC_EnqueueImpact(pos, normal, mat, 0, action, target, 0, is_entry, arrival, exit_dir, blast);
};
