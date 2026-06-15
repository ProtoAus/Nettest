// ============================================================
//  client/cl_teamtint.qc  -  Team-colour player tint
//
//  Sets .colormod on every player_visual_proxy entity each frame so
//  remote player models render with a faint team-coloured wash.
//  The engine forwards .colormod to built-in shaders as e_colourident
//  (see pr_csqc.c:881-886 + defaultskin.glsl:398), which is multiplied
//  into the final fragment colour — so no custom GLSL is needed.
//
//  IMPORTANT: the visible body of a player is NOT the engine player
//  at edict_num(slot+1).  That's the authority entity — it has a
//  modelindex but the draw path uses a separate CSQC entity with
//  classname "player_visual_proxy" (see cl_player.qc:1918 CSQC_Ent_Update).
//  vis_owner_entnum on each proxy is the 1-based edict of the owning
//  player — subtract 1 for the 0-based slot getplayerkeyvalue expects.
//
//  Gated by cl_teamcolours (registered in cl_main.qc CSQC_Init).
//  When off, every proxy is reset to '1 1 1' (engine default).
// ============================================================

const vector TEAMTINT_BLUE    = '0.6 0.75 1';
const vector TEAMTINT_RED     = '1 0.65 0.65';
const vector TEAMTINT_NEUTRAL = '1 1 1';

// Compute the brightness clamp scalar for a given world position.
// Returns 1.0 when the local lightmap sample is below the soft knee; a
// smaller multiplier above it so the rendered model's perceived
// brightness rolls off smoothly toward the cap instead of blowing out.
// Hue is preserved (the scalar applies to all three channels equally —
// won't shift team-tint colours).
//
// `cap_byte` is in the same 0–255 byte range r_viewmodel_maxlight
// uses, matching getlight()'s native output. cap_byte <= 0 disables
// the cap entirely. `knee_frac` (0–1, from r_maxlight_softknee) sets how
// early the rolloff begins; 1 = original hard clamp. Used by the
// team-tint pass and the dropped-weapon predraw to enforce
// r_playermodels_maxlight / r_physdrops_maxlight respectively without an
// engine patch.
float(vector pos, float cap_byte, float knee_frac) CSQC_MaxlightScale =
{
    if (cap_byte <= 0)
        return 1.0;
    vector light = getlight(pos);
    float maxch = light_x;
    if (light_y > maxch) maxch = light_y;
    if (light_z > maxch) maxch = light_z;

    // Soft knee: samples below the knee are left untouched (scale 1, the
    // common case); brighter samples are smoothly compressed so the
    // model's rendered brightness asymptotes toward cap instead of
    // hard-clamping flat at it (which made a 200-bright and a 255-bright
    // tile render identically). knee_frac is the fraction of cap where
    // the rolloff begins; knee_frac >= 1 collapses the soft zone and
    // reproduces the original hard clamp exactly.
    float knee = cap_byte * knee_frac;
    if (maxch <= knee)
        return 1.0;
    float range = cap_byte - knee;
    if (range <= 0)                          // hard-clamp fallback
        return cap_byte / maxch;
    float over = maxch - knee;               // Reinhard rolloff on the excess:
    float outv = knee + over / (1 + over / range);  // outv -> cap as maxch -> inf
    return outv / maxch;
};

// Cached variant for entities that mostly sit still (dropped weapons).
// Re-runs the getlight() sample only when `self` moved more than ~1qu or
// the cap/knee changed; otherwise returns the stored scalar. This is what
// removes the per-frame getlight() on settled drops seen in the profiler.
float(float cap_byte, float knee_frac) CSQC_MaxlightScale_Cached =
{
    if (cap_byte <= 0)
        return 1.0;
    vector d = self.origin - self.maxlight_cache_origin;
    if (self.maxlight_cache_cap == cap_byte
        && self.maxlight_cache_knee == knee_frac
        && (d * d) < 1)
        return self.maxlight_cache_scale;               // hit: no getlight()
    self.maxlight_cache_scale  = CSQC_MaxlightScale(self.origin, cap_byte, knee_frac);
    self.maxlight_cache_origin = self.origin;
    self.maxlight_cache_cap    = cap_byte;
    self.maxlight_cache_knee   = knee_frac;
    return self.maxlight_cache_scale;
};

void() CSQC_ApplyTeamTints =
{
    float enabled = cvar("cl_teamcolours") > 0;
    float cap = cvar("r_playermodels_maxlight");
    float knee = cvar("r_maxlight_softknee");
    entity vis;
    float slot;
    string t;
    float team_id;
    vector tint;
    float scale;

    vis = findchain(classname, "player_visual_proxy");
    while (vis)
    {
        slot = vis.vis_owner_entnum - 1;

        // Brightness cap is sampled at the visible body's render
        // origin so a player crossing a bright tile dims uniformly.
        // Scalar = 1 when below the cap (cheap, the common case).
        scale = CSQC_MaxlightScale(vis.origin, cap, knee);

        if (!enabled || slot < 0 || slot >= maxclients)
        {
            vis.colormod = TEAMTINT_NEUTRAL * scale;
            vis = vis.chain;
            continue;
        }

        t = getplayerkeyvalue(slot, "modteam");
        team_id = (t != "") ? stof(t) : TEAM_NONE;

        if (team_id == TEAM_BLUE)
            tint = TEAMTINT_BLUE;
        else if (team_id == TEAM_RED)
            tint = TEAMTINT_RED;
        else
            tint = TEAMTINT_NEUTRAL;

        // Stack the brightness clamp on top of the team tint — same
        // hue, capped intensity.
        vis.colormod = tint * scale;
        vis = vis.chain;
    }
};
