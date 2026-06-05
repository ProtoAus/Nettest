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
// Returns 1.0 when the local lightmap sample is below the cap; a
// smaller multiplier when above so the rendered model's perceived
// brightness is bounded. Hue is preserved (the scalar applies to all
// three channels equally — won't shift team-tint colours).
//
// `cap_byte` is in the same 0–255 byte range r_viewmodel_maxlight
// uses, matching getlight()'s native output. cap_byte <= 0 disables
// the cap entirely. Used by the team-tint pass and the dropped-
// weapon predraw to enforce r_playermodels_maxlight /
// r_physdrops_maxlight respectively without an engine patch.
float(vector pos, float cap_byte) CSQC_MaxlightScale =
{
    if (cap_byte <= 0)
        return 1.0;
    vector light = getlight(pos);
    float maxch = light_x;
    if (light_y > maxch) maxch = light_y;
    if (light_z > maxch) maxch = light_z;
    if (maxch <= cap_byte)
        return 1.0;
    return cap_byte / maxch;
};

void() CSQC_ApplyTeamTints =
{
    float enabled = cvar("cl_teamcolours") > 0;
    float cap = cvar("r_playermodels_maxlight");
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
        scale = CSQC_MaxlightScale(vis.origin, cap);

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
