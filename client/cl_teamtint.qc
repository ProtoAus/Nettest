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

void() CSQC_ApplyTeamTints =
{
    float enabled = cvar("cl_teamcolours") > 0;
    entity vis;
    float slot;
    string t;
    float team_id;
    vector tint;

    vis = findchain(classname, "player_visual_proxy");
    while (vis)
    {
        slot = vis.vis_owner_entnum - 1;

        if (!enabled || slot < 0 || slot >= maxclients)
        {
            vis.colormod = TEAMTINT_NEUTRAL;
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

        vis.colormod = tint;
        vis = vis.chain;
    }
};
