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
void(entity owner_ent) CSQC_BulletHolesRemoveByOwner;

// Forward declarations (defined in cl_breakable.qc — compiles after this file)
void(vector mins, vector maxs, float count, float damage_scale,
     float owner_entnum) CSQC_SpawnGlassGibs;
void(vector mins, vector maxs, float style, float count, float damage_scale,
     float custom_idx, float alpha_byte, float owner_entnum) CSQC_SpawnDebrisGibs;

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
float impact_effect_resolved;

// One-shot resolve — called from Impact_GetEffectFor on first use.  The
// particles/weapons.cfg load happens earlier, in data/default.cfg, via the
// menu VM's Menu_LoadConfig (which runs after PScript_InitParticles has
// set pe_script_enabled and before any CSQC loads).  By the time this
// function runs on first shot, every effect is already registered and
// particleeffectnum returns a valid negative slot index for each.
void() Impact_ResolveAll =
{
    if (impact_effect_resolved) return;

    float def = particleeffectnum("weapons.impact");
    if (def == 0)
        return;   // slot table full — retry next call

    impact_effect_default      = def;
    impact_effect_flesh        = particleeffectnum("weapons.flesh_impact");
    impact_effect_flesh_lethal = particleeffectnum("weapons.flesh_impact_lethal");
    impact_effect_metal        = particleeffectnum("weapons.metal_impact");
    impact_effect_glass        = particleeffectnum("weapons.glass_impact");
    impact_effect_wood         = particleeffectnum("weapons.wood_impact");
    impact_effect_resolved     = 1;
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
    if (mat == IMPACT_MAT_GLASS        && impact_effect_glass        != 0) return impact_effect_glass;
    if (mat == IMPACT_MAT_WOOD         && impact_effect_wood         != 0) return impact_effect_wood;
    return impact_effect_default;
};

// Local prediction inspects trace_ent (the shooter's own CSQC trace).
// Players appear as entities with classname == "player"; replicated
// brush entities (func_wall, func_breakable) carry a brush_material
// byte set in CSQC_SolidBrush_Update from the server's BREAKABLE_*
// style. 0 = default/concrete for non-breakable brushes.
float(entity hit) Impact_ClassifyLocal =
{
    if (!hit) return IMPACT_MAT_DEFAULT;
    if (hit.classname == "player") return IMPACT_MAT_FLESH;

    // Breakable brush — read material code mirroring server values.
    // Hardcoded values mirror sv_breakable.qc:14-21 (BREAKABLE_*).
    float m = hit.brush_material;
    if (m == 5)                      return IMPACT_MAT_FLESH;   // BREAKABLE_FLESH
    if (m == 4)                      return IMPACT_MAT_GLASS;   // BREAKABLE_GLASS
    if (m == 3)                      return IMPACT_MAT_WOOD;    // BREAKABLE_WOOD
    if (m == 2 || m == 6 || m == 7)  return IMPACT_MAT_METAL;   // METAL/MACHINE/CIRCUIT
    return IMPACT_MAT_DEFAULT;
};

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

    // Impact light + particles at hit point.  No surface normal is stored
    // for stuck projectiles, so feed zero velocity and let the particle
    // effect's own randomvel/veladd scatter it.
    CSQC_AddImpactLight(self.fake_proj_hitpos);
    pointparticles(Impact_GetEffectFor(IMPACT_MAT_DEFAULT), self.fake_proj_hitpos, '0 0 0', 1);

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

// Pull particles just slightly off the surface — far enough that the
// dust+sparks burst renders in front of the bullet hole decal, close
// enough that the effect looks attached to the wall instead of floating
// in mid-air.
const float IMPACT_PARTICLE_OFFSET = 4;

// Should we spawn a persistent bullet-hole decal for this impact?
// Static surfaces (world / func_wall / unbreakable brushes) yes — they
// don't move or get destroyed. Flesh and breakables no, because the
// decal would get orphaned when the target dies, moves, or breaks.
float(float mat) Impact_ShouldSpawnHole =
{
    return (mat == IMPACT_MAT_DEFAULT);
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

    if (style == 4)  // BREAKABLE_GLASS
    {
        if      (v < 0.25) snd = "sounds/debris/impact_glasshl1.wav";
        else if (v < 0.50) snd = "sounds/debris/impact_glasshl2.wav";
        else if (v < 0.75) snd = "sounds/debris/impact_glasshl3.wav";
        else               snd = "sounds/debris/impact_glasshl4.wav";
    }
    else if (style == 0 || style == 1)  // BREAKABLE_ROCK / BREAKABLE_CONCRETE
    {
        if      (v < 0.333) snd = "sounds/debris/impact_concretehl1.wav";
        else if (v < 0.666) snd = "sounds/debris/impact_concretehl2.wav";
        else                snd = "sounds/debris/impact_concretehl3.wav";
    }
    else if (style == 3)  // BREAKABLE_WOOD
    {
        if      (v < 0.25) snd = "sounds/debris/impact_woodhl1.wav";
        else if (v < 0.50) snd = "sounds/debris/impact_woodhl2.wav";
        else if (v < 0.75) snd = "sounds/debris/impact_woodhl3.wav";
        else               snd = "sounds/debris/impact_woodhl4.wav";
    }
    else if (style == 5)  // BREAKABLE_FLESH
    {
        if      (v < 0.167) snd = "sounds/debris/impact_fleshhl1.wav";
        else if (v < 0.333) snd = "sounds/debris/impact_fleshhl2.wav";
        else if (v < 0.500) snd = "sounds/debris/impact_fleshhl3.wav";
        else if (v < 0.667) snd = "sounds/debris/impact_fleshhl4.wav";
        else if (v < 0.833) snd = "sounds/debris/impact_fleshhl5.wav";
        else                snd = "sounds/debris/impact_fleshhl6.wav";
    }
    else  // metal, machine, circuit, and any unrecognised style
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

    if (style == 4)  // BREAKABLE_GLASS
    {
        if      (v < 0.333) snd = "sounds/debris/break_glasshl1.wav";
        else if (v < 0.666) snd = "sounds/debris/break_glasshl2.wav";
        else                snd = "sounds/debris/break_glasshl3.wav";
    }
    else if (style == 0 || style == 1)  // BREAKABLE_ROCK / BREAKABLE_CONCRETE
    {
        if (v < 0.5) snd = "sounds/debris/break_concretehl1.wav";
        else         snd = "sounds/debris/break_concretehl2.wav";
    }
    else if (style == 3)  // BREAKABLE_WOOD
    {
        if      (v < 0.333) snd = "sounds/debris/break_woodhl1.wav";
        else if (v < 0.666) snd = "sounds/debris/break_woodhl2.wav";
        else                snd = "sounds/debris/break_woodhl3.wav";
    }
    else if (style == 5)  // BREAKABLE_FLESH
    {
        if (v < 0.5) snd = "sounds/debris/break_fleshhl1.wav";
        else         snd = "sounds/debris/break_fleshhl2.wav";
    }
    else if (style == 7)  // BREAKABLE_CIRCUIT
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
    // brush_health > 0 identifies a live breakable. brush_material can be
    // 0 for BREAKABLE_CONCRETE, so don't gate on that — non-breakable
    // brushes have health == 0 and are excluded by the next check.
    if (target.brush_health <= 0)             return;    // not a breakable / already gone
    if (target.brush_broken_predicted)        return;    // already predicted

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
    if (target.brush_material == 4 /*BREAKABLE_GLASS*/)
        CSQC_SpawnGlassGibs(target.absmin, target.absmax, target.brush_cnt, ds, own);
    else
        // custom_idx=0 → fall back to material-default model; alpha=0 →
        // full opacity. Server can override these via map-editor mdl/
        // alpha2 fields — the attacker's predicted gibs will mismatch
        // briefly on custom-override breakables, which is acceptable MVP
        // drift. Fixing requires replicating custom_mdl_idx + alpha2.
        CSQC_SpawnDebrisGibs(target.absmin, target.absmax,
                             target.brush_material, target.brush_cnt,
                             ds, 0, 0, own);

    // Matching the server's cleanup: drop any decals still anchored to the
    // brush so they don't float in the air after the predicted break.
    CSQC_BulletHolesRemoveByOwner(target);
};

// Full bullet impact: particles + light + ricochet sound
// Called from hitscan prediction (CSQC_PredictedImpact / ShotgunImpact)
void(vector pos, vector normal, float damage) CSQC_BulletImpact =
{
    vector offset_pos;
    float r;

    // No impact on sky surfaces
    // Check slightly into the surface to detect sky
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    // Pull effect off the surface so it's not flush against the wall
    offset_pos = pos + normal * IMPACT_PARTICLE_OFFSET;

    // Local prediction: classify based on what we hit. CSQC can only see
    // player vs. anything-else (func_breakable isn't replicated to CSQC),
    // so most surfaces will use the default impact effect on the local
    // shooter's screen. The server's CSQC_EVENT_IMPACT carries the
    // material byte for the full per-surface picker on remote viewers.
    float mat = Impact_ClassifyLocal(trace_ent);

    // normal * 200 = base velocity for the particle set, gets the dust
    // and sparks "spitting" outward from the surface instead of hanging flat.
    pointparticles(Impact_GetEffectFor(mat), offset_pos, normal * 200, 1);
    CSQC_AddImpactLight(offset_pos);
    // Only place bullet-hole decals on static surfaces — decals on
    // players or breakables would orphan when the target moves or dies.
    if (Impact_ShouldSpawnHole(mat))
        CSQC_SpawnBulletHole(pos, normal, trace_ent);

    // Random ricochet sound (ric1-5) at impact location
    r = floor(random() * 5) + 1;
    r = bound(1, r, 5);
    pointsound(offset_pos, sprintf("sounds/weapons/ric%g.wav", r), 1, ATTN_NORM);

    // Predicted breakable material thump. Gate on brush_health > 0 so we
    // identify live breakables regardless of their material style — style
    // 0 is BREAKABLE_CONCRETE (a valid material), NOT a "non-breakable"
    // sentinel. Non-breakable func_wall/etc brushes default health = 0,
    // so this correctly separates damageable brushes from static ones.
    // The server's BreakablePlayImpactSound routes the matching multicast
    // event to every OTHER client, so we don't double up locally.
    if (trace_ent && trace_ent.classname != "player" && trace_ent.brush_health > 0)
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

    offset_pos = pos + normal * IMPACT_PARTICLE_OFFSET;

    float mat = Impact_ClassifyLocal(trace_ent);
    pointparticles(Impact_GetEffectFor(mat), offset_pos, normal * 200, 1);
    CSQC_AddImpactLight(offset_pos);
    if (Impact_ShouldSpawnHole(mat))
        CSQC_SpawnBulletHole(pos, normal, trace_ent);
};

// Full impact for other players receiving server events.
// `mat` = IMPACT_MAT_* code from the server multicast — server has full
// trace_ent visibility (including func_breakable.style) and classifies
// per-surface there, so this gets the accurate per-material effect.
void(vector pos, vector normal, float mat) CSQC_BulletImpactRemote =
{
    vector offset_pos;
    float r;

    // Check slightly into the surface to detect sky
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    offset_pos = pos + normal * IMPACT_PARTICLE_OFFSET;

    pointparticles(Impact_GetEffectFor(mat), offset_pos, normal * 200, 1);
    CSQC_AddImpactLight(offset_pos);
    if (Impact_ShouldSpawnHole(mat))
        CSQC_SpawnBulletHole(pos, normal, world);

    // Positional ricochet sound for other players
    r = floor(random() * 5) + 1;
    r = bound(1, r, 5);
    pointsound(offset_pos, sprintf("sounds/weapons/ric%g.wav", r), 1, ATTN_NORM);
};
