// ============================================================================
//  Map lights — client-side table of the map's light entities, driving
//  light-aware shadow directions.
//
//  Inert `light` entities are DELETED server-side at spawn (sv_customdefs.qc),
//  so the only complete source is the BSP's own entity lump — which CSQC can
//  read locally via getentitytoken (its documented purpose; no networking).
//  MapLights_Load parses it once per map from CSQC_WorldLoaded.
//
//  Consumers:
//    * MapLights_SwingThrowDir (per frame, CSQC_UpdateView): steers the engine's
//      r_shadows-2 fake-shadow ortho direction (r_shadows_throwdirection) toward
//      the WEIGHTED blend of nearby lights + the env_sun — your shadow swings
//      smoothly around as you walk past lamps.  cl_lightshadow_swing to enable.
//    * BlobShadow_WriteForEnt (cl_blobshadow.qc): per-entity blob skew away from
//      that entity's own dominant light.
//
//  Weighting: each light contributes normalize(point - light) * bright²/dist²
//  within ~1.5×bright reach; the sun contributes -r_sun_dir * cl_lightshadow_sunweight
//  when active (r_sun_colour non-zero — the per-map cvar env_sun maintains; r_sun_dir
//  alone goes stale across maps).  Sun default weight 2 ≈ a 200-bright lamp at 141qu,
//  so lamps own you up close and the sun owns the outdoors.
// ============================================================================

const float ML_MAX = 512;

auto vector ml_org[ML_MAX];
auto float  ml_bright[ML_MAX];
float ml_count;

// Swing state (per-frame smoothing + change-gated cvar writes).
vector ml_smooth_dir;
vector ml_last_written;
float  ml_swing_was_on;

// Parse the worldmodel's entity lump and collect light origins + brightness.
// Token stream is `{ key value key value ... } { ... }`.  TEMPSTRING SAFETY:
// getentitytoken returns tempstrings — every comparison happens IMMEDIATELY
// (key flags captured before the value token is fetched, values converted
// in place); nothing string-typed is stored across further token reads.
void() MapLights_Load =
{
    ml_count = 0;
    string t;
    float guard = 0;

    getentitytoken("");                        // reset to the worldmodel lump
    while ((t = getentitytoken()) != "")
    {
        guard = guard + 1;
        if (guard > 400000) break;             // malformed-lump backstop
        if (t != "{")
            continue;

        float is_light = 0;
        float has_org  = 0;
        vector org     = '0 0 0';
        float bright   = 0;

        for (;;)
        {
            t = getentitytoken();              // key
            guard = guard + 1;
            if (guard > 400000) break;
            if (t == "") break;
            if (t == "}") break;
            float k_class = (t == "classname");
            float k_origin = (t == "origin");
            float k_light = 0;
            if (t == "light") k_light = 1;     // Quake:  light "200"  /  HL: "R G B D"
            if (t == "_light") k_light = 1;    // Source: _light "R G B I"

            t = getentitytoken();              // value
            guard = guard + 1;
            if (t == "") break;

            if (k_class)
            {
                if (t == "light")
                    is_light = 1;
                else if (substring(t, 0, 6) == "light_")
                    is_light = 1;              // light_torch/globe/fluoro/... presets
            }
            else if (k_origin)
            {
                org = stov(t);
                has_org = 1;
            }
            else if (k_light)
            {
                float n = tokenize(t);
                if (n >= 4)
                    bright = stof(argv(3));    // 4-value form: intensity is the 4th
                else
                    bright = stof(argv(0));
            }
        }

        if (!is_light) continue;
        if (!has_org)  continue;
        if (bright <= 0) bright = 200;         // Quake default light value
        if (ml_count < ML_MAX)
        {
            ml_org[ml_count]    = org;
            ml_bright[ml_count] = bright;
            ml_count = ml_count + 1;
        }
    }

    if (cvar("developer"))
        print(sprintf("MapLights: %g light entities parsed from the entity lump\n", ml_count));
};

// Weighted "direction light travels" at a point: sum of away-from-light vectors
// weighted bright²/dist² (within reach), plus the env_sun term when the sun is
// active this map.  '0 0 0' = nothing meaningful in range (caller falls back).
vector(vector at) MapLights_DirAt =
{
    vector acc = '0 0 0';
    float i;
    for (i = 0; i < ml_count; i = i + 1)
    {
        vector d = at - ml_org[i];
        float dist2 = d * d;
        if (dist2 < 1)
            continue;                          // standing inside the light: no direction
        float reach = ml_bright[i] * 1.5;      // approximate influence radius (qu)
        if (dist2 > reach * reach)
            continue;
        acc = acc + normalize(d) * ((ml_bright[i] * ml_bright[i]) / dist2);
    }

    float sw = cvar("cl_lightshadow_sunweight");
    if (sw > 0)
    {
        // Sun-active gate = _map_sun_active (stuffed per map by sv_env_sun).
        // r_sun_dir carries only the DIRECTION now (god rays removed; r_sun_colour
        // is held at 0 by the sv_env_sun clear-first stuff).
        if (cvar("_map_sun_active"))
        {
            vector sd = stov(cvar_string("r_sun_dir"));
            if (sd != '0 0 0')
                acc = acc + ('0 0 0' - normalize(sd)) * sw;
        }
    }

    if (acc == '0 0 0')
        return acc;
    return normalize(acc);
};

// Direction to hand back when no lights are in range / the swing is disabled:
// the env_sun throw (matches what sv_env_sun stuffs) or the engine default.
vector() MapLights_FallbackDir =
{
    if (cvar("_map_sun_active"))    // the map-has-a-sun truth flag (stuffed by sv_env_sun)
    {
        vector sd = stov(cvar_string("r_sun_dir"));
        if (sd != '0 0 0')
            return '0 0 0' - normalize(sd);
    }
    return '0 0 -1';
};

// ---- Per-CASTER fake shadows (engine multi-fakeshadow atlas) ----------------------
// *** DEPRECATED / EXPERIMENTAL — do NOT enable (cl_lightshadow_perlight 0 / keep
// r_shadows_fakecount 1). *** It has a fundamental flaw: only MOVING casters that call
// BlobShadow_Emit register here, but SETTLED physics props unhook their predraw
// (cl_physprop.qc settle path) and prop_static/Source scenery has no CSQC predraw at all
// (sv_props.qc) — so static props never get their own slot and instead fall inside the
// nearest MOVING caster's (the player's) ortho box, inheriting the PLAYER's throw
// direction. Result: "every prop shadow shares the player's angle," and raising
// r_shadows_fakelightsize just widens the box and engulfs more props. Fixing it needs
// static-caster registration AND per-slot entnum isolation in the depth pass — not worth
// it. Use r_shadows 2 (implicit fakecount 1) = one sun/directional shadow; models
// self-shadow via nettest/glsl/defaultskin.glsl. Code kept dormant only for reference.
//
// (Original design notes:) Source RTT-shadow model: instead of one ortho box per LIGHT
// (which cast the whole scene along the local player's single direction), each nearby
// ENTITY gets its OWN slot: box centred on that entity, aimed from ITS dominant light
// (MapLights_DirAt), fed to the engine as r_shadows_fakelightN "cx cy cz dx dy dz".
//
// Candidates are registered each frame by the casters' own predraws (next to their
// BlobShadow_Emit calls) via MapLights_RegisterShadowCaster.  The driver runs in
// CSQC_UpdateView BEFORE the scene renders, so it consumes LAST frame's list (a 1-frame
// lag, imperceptible) and then resets it for this frame's predraws to repopulate.
#define ML_CAND_MAX 64
vector ml_cand_org[ML_CAND_MAX];   // caster origins registered this frame
float  ml_cand_used[ML_CAND_MAX];  // consumed-by-a-slot mark (per selection pass)
float  ml_cand_count;
float  ml_caster_active;           // cached enable (gates the register fn cheaply)
float  ml_slot_inited;             // have we pushed slot cvars since enabling?

// Called from each caster's predraw (player/prop/ragdoll) with its world origin.
// No-op unless the per-caster system is active this frame (set by the driver).
void(vector org) MapLights_RegisterShadowCaster =
{
    if (!ml_caster_active) return;
    if (ml_cand_count >= ML_CAND_MAX) return;
    ml_cand_org[ml_cand_count] = org;
    ml_cand_count = ml_cand_count + 1;
};

void() MapLights_DriveCasterShadows =
{
    float nslots = cvar("r_shadows_fakecount") - 1;
    if (nslots > 7) nslots = 7;
    float on = 0;
    if (cvar("cl_lightshadow_perlight"))
        if (cvar("r_shadows") == 2)
            if (nslots > 0)
                on = 1;

    float s, k;
    if (!on)
    {
        ml_caster_active = 0;
        ml_cand_count = 0;           // drop any stale registrations
        if (ml_slot_inited)
        {   // disable edge: clear the slot cvars so the engine drops the projections
            for (s = 0; s < 7; s = s + 1)
                cvar_set(sprintf("r_shadows_fakelight%g", s + 1), "");
            ml_slot_inited = 0;
        }
        return;
    }
    ml_slot_inited = 1;

    vector eye = '0 0 0';
    if (predicted_player)
        eye = predicted_player.origin;

    // Fill slots with the nearest-to-eye candidates (repeated nearest-unused pick).
    // The local player is a candidate at ~distance 0, so it always claims a slot.
    for (s = 0; s < nslots; s = s + 1)
    {
        float best = -1;
        float bestd2 = 0;
        for (k = 0; k < ml_cand_count; k = k + 1)
        {
            if (ml_cand_used[k]) continue;
            vector d = eye - ml_cand_org[k];
            float d2 = d * d;
            if (best < 0)
            {
                best = k;
                bestd2 = d2;
            }
            else if (d2 < bestd2)
            {
                best = k;
                bestd2 = d2;
            }
        }
        if (best < 0)
        {   // no more casters: clear this slot (and, since we go nearest-first, the rest)
            cvar_set(sprintf("r_shadows_fakelight%g", s + 1), "");
            continue;
        }
        ml_cand_used[best] = 1;

        vector co = ml_cand_org[best];
        vector dir = MapLights_DirAt(co);       // dominant-light throw AT this caster
        if (dir == '0 0 0')
            dir = MapLights_FallbackDir();       // sun / straight-down when no lamp in range
        // 6 values (fmt + 6 = 7 args, under fteqcc's 8-vararg limit)
        cvar_set(sprintf("r_shadows_fakelight%g", s + 1),
                 sprintf("%f %f %f %f %f %f", co_x, co_y, co_z, dir_x, dir_y, dir_z));
    }

    // Reset the candidate list for THIS frame's predraws to repopulate; arm the
    // register fn so those predraws (running during renderscene) are captured.
    for (k = 0; k < ml_cand_count; k = k + 1)
        ml_cand_used[k] = 0;
    ml_cand_count = 0;
    ml_caster_active = 1;
};

// Per-frame (CSQC_UpdateView): steer the fake-shadow ortho direction toward the
// local light blend, smoothed over cl_lightshadow_smooth secs.  SUNLESS MAPS ONLY:
// on env_sun maps (_map_sun_active) the server-stuffed sun direction is authoritative
// and the swing hard-disables, so every caster (player, props, ragdolls) keeps the
// sun's throw.  The cvar_set is CHANGE-GATED (>~1 degree); on the disable edge the
// fallback is written ONCE — on a sun map MapLights_FallbackDir returns the sun throw,
// so control self-heals to the sun even if swing was mid-flight when it engaged.
void() MapLights_SwingThrowDir =
{
    float on = 0;
    if (cvar("cl_lightshadow_swing"))
        if (cvar("r_shadows") == 2)
            if (!cvar("_map_sun_active"))   // sun maps: the stuffed sun dir is authoritative
                on = 1;

    if (!on)
    {
        if (ml_swing_was_on)
        {
            vector fb = MapLights_FallbackDir();
            cvar_set("r_shadows_throwdirection", sprintf("%f %f %f", fb_x, fb_y, fb_z));
            ml_last_written = fb;
            ml_swing_was_on = 0;
        }
        return;
    }

    vector eye = '0 0 0';
    if (predicted_player)
        eye = predicted_player.origin;
    vector target = MapLights_DirAt(eye);
    if (target == '0 0 0')
        target = MapLights_FallbackDir();

    if (!ml_swing_was_on)
    {
        ml_smooth_dir = target;                // engage: snap (no lerp from stale state)
        ml_swing_was_on = 1;
    }
    else
    {
        float st = cvar("cl_lightshadow_smooth");
        if (st <= 0) st = 0.001;
        float f = frametime / st;
        if (f > 1) f = 1;
        ml_smooth_dir = ml_smooth_dir + (target - ml_smooth_dir) * f;
        if (ml_smooth_dir == '0 0 0')
            ml_smooth_dir = target;            // exact opposites cancelled mid-lerp
        ml_smooth_dir = normalize(ml_smooth_dir);
    }

    if ((ml_smooth_dir * ml_last_written) < 0.9998)   // moved > ~1 degree
    {
        cvar_set("r_shadows_throwdirection",
                 sprintf("%f %f %f", ml_smooth_dir_x, ml_smooth_dir_y, ml_smooth_dir_z));
        ml_last_written = ml_smooth_dir;
    }
};
