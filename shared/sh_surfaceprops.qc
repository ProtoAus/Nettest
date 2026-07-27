// ===========================================================================
// sh_surfaceprops.qc — Source-style surface material properties.
//
// Tags world TEXTURES with a material (via scripts/surfaceprops.txt) so gameplay
// can react per-surface.  The hit/ground texture name comes from the engine
// global `trace_surfacename`, which traceline/tracebox set on BOTH the client
// and the server (engine pr_csqc.c / pr_cmds.c).  Works for Q1/HL/Q2/Q3 BSP
// world surfaces; Q1 surfaceflags are NOT populated, so the texture NAME is the
// key.  Shared unit — compiled into csprogs AND qwprogs (must be listed AFTER
// shared/sh_weapons.qc, which defines IMPACT_MAT_*, and BEFORE sh_pmove.qc).
//
// Currently drives: bullet-impact effect (W_ClassifyImpactMaterial /
// Impact_ClassifyLocal) + footstep sound (sh_pmove.qc).
//
// File format (scripts/surfaceprops.txt), one material per line:
//   mat <name> <soundset> <impact-mat> <texture-patterns...>
//     soundset     : a set name in scripts/materialsounds.txt (sh_matsounds.qc).
//                    Drives BOTH the footstep set (sh_pmove.qc PM_FootstepBase)
//                    and the bullet-impact ric (cl_bulletimpact.qc).  "dirt"
//                    ships no wavs: generic footsteps + concrete rics via sndalias.
//     impact-mat   : default|metal|wood|glass|flesh  (-> IMPACT_MAT_*).  PARTICLE
//                    code only - deliberately coarse, NOT the sound key.
//     patterns     : foo* (prefix) | *foo (suffix) | *foo* (substring) | foo (exact) | * (any)
//   First matching pattern wins, so list SPECIFIC before GENERAL.  Unmatched
//   textures fall back to the last material loaded (or IMPACT_MAT_DEFAULT if the
//   file is missing).  NO BLANK LINES — a blank line ends parsing (fgets idiom).
// ===========================================================================

const float SP_MAX_MAT = 32;    // materials
const float SP_MAX_PAT = 256;   // texture patterns total

float  sp_mat_count;
string sp_mat_name    [SP_MAX_MAT];   // material name (debug/readout)
float  sp_mat_impact  [SP_MAX_MAT];   // IMPACT_MAT_* for the bullet-impact effect
string sp_mat_footstep[SP_MAX_MAT];   // footstep-set name ("" => generic step)

float  sp_pat_count;
string sp_pat_text[SP_MAX_PAT];       // pattern (lowercased), file order
float  sp_pat_mat [SP_MAX_PAT];       // -> material index

float  sp_default_mat;                // fallback material index (-1 = none)
float  sp_loaded;
// NOTE: no result cache here on purpose.  getsurfacetexture returns a TEMPSTRING, and caching it
// by reference misfired as tempstring buffers got recycled (the look-lookup's material leaked into
// the footstep lookup).  The pattern scan is cheap (a few calls/sec), so just always scan.

// impact-mat name (file token) -> IMPACT_MAT_* (sh_weapons.qc, included earlier).
float(string s) Surf_ImpactNameToCode =
{
    if (s == "metal") return IMPACT_MAT_METAL;
    if (s == "wood")  return IMPACT_MAT_WOOD;
    if (s == "glass") return IMPACT_MAT_GLASS;
    if (s == "flesh") return IMPACT_MAT_FLESH;
    return IMPACT_MAT_DEFAULT;   // default / concrete / dirt / unknown
};

// Does `tex` (already lowercase) match `pat` (already lowercase)?
//   "foo*" prefix | "*foo" suffix | "*foo*" substring | "foo" exact | "*" any.
float(string pat, string tex) Surf_TexMatch =
{
    float pl = strlen(pat);
    if (pl == 0) return FALSE;
    if (pat == "*") return TRUE;
    float star_head = (substring(pat, 0, 1) == "*");
    float star_tail = (substring(pat, pl - 1, 1) == "*");
    if (star_head && star_tail)
    {
        string mid = substring(pat, 1, pl - 2);
        if (strlen(mid) == 0) return TRUE;
        return (strstrofs(tex, mid, 0) >= 0);
    }
    if (star_tail)
    {
        string pre = substring(pat, 0, pl - 1);
        return (substring(tex, 0, strlen(pre)) == pre);
    }
    if (star_head)
    {
        string suf = substring(pat, 1, pl - 1);
        float tl = strlen(tex), sl = strlen(suf);
        if (sl > tl) return FALSE;
        return (substring(tex, tl - sl, sl) == suf);
    }
    return (tex == pat);
};

// Texture name -> material index (sp_default_mat, or -1, when nothing matches).
float(string texname) Surf_MaterialFor =
{
    if (texname == "") return sp_default_mat;
    string tex = strtolower(texname);
    float found = sp_default_mat;
    float i;
    for (i = 0; i < sp_pat_count; i = i + 1)
        if (Surf_TexMatch(sp_pat_text[i], tex))
        {
            found = sp_pat_mat[i];
            break;
        }
    return found;
};

// material index -> IMPACT_MAT_* (DEFAULT when out of range).
float(float mat) Surf_ImpactMat =
{
    if (mat < 0 || mat >= sp_mat_count) return IMPACT_MAT_DEFAULT;
    return sp_mat_impact[mat];
};

// material index -> footstep-set name ("" => generic step; sh_pmove maps it).
string(float mat) Surf_FootstepName =
{
    if (mat < 0 || mat >= sp_mat_count) return "";
    return sp_mat_footstep[mat];
};

// material index -> SOUND-SET name (a set in scripts/materialsounds.txt).
// Same column as Surf_FootstepName: col 3 is now "which material sound family is
// this surface", which drives the footstep set AND the bullet-impact ric
// (cl_bulletimpact.qc via MatSnd_SetForImpact).  "" => nothing resolves.
string(float mat) Surf_SoundSet =
{
    return Surf_FootstepName(mat);
};

// material index -> display name (for the debug readout).
string(float mat) Surf_MatName =
{
    if (mat < 0 || mat >= sp_mat_count) return "default";
    return sp_mat_name[mat];
};

// Q1 BSP hull traces carry NO surface, so trace_surfacename is empty on Q1/HL maps.  Resolve a
// hit surface's TEXTURE from the hit POINT instead: getsurfacenearpoint finds the nearest surface
// on entity e's brush model, getsurfacetexture reads its texinfo texture name.  Works on all BSP
// types (Q1/HL/Q2/Q3), world + brush entities.  The point should be ON the surface (a trace
// endpos) so "nearest" is exact.  Returns "" if e has no brush surface near p.
string(entity e, vector p) Surf_TexAtPoint =
{
    if (!e) e = world;
    float si = getsurfacenearpoint(e, p);
    if (si < 0) return "";
    return getsurfacetexture(e, si);
};
// Convenience: material index of the surface at world point p on entity e.
float(entity e, vector p) Surf_MaterialAtPoint =
{
    return Surf_MaterialFor(Surf_TexAtPoint(e, p));
};

// (Re)load scripts/surfaceprops.txt.  Called at client + server init, and from
// the `surf_reloadmaterials` debug command.  Missing file => graceful default.
void() Surf_LoadMaterials =
{
    float k;
    // Free the previous strzoned strings (reload via surf_reloadmaterials) so we don't leak.
    if (sp_loaded)
    {
        for (k = 0; k < sp_mat_count; k = k + 1)
        {
            strunzone(sp_mat_name[k]);
            strunzone(sp_mat_footstep[k]);
        }
        for (k = 0; k < sp_pat_count; k = k + 1)
            strunzone(sp_pat_text[k]);
    }

    sp_mat_count  = 0;
    sp_pat_count  = 0;
    sp_default_mat = -1;
    sp_loaded     = 0;

    filestream f = fopen("scripts/surfaceprops.txt", FILE_READ);
    if (f < 0)
        return;   // no file: Surf_MaterialFor -> -1 -> IMPACT_MAT_DEFAULT / generic footstep

    string line = fgets(f);
    while (line)
    {
        float n = tokenize(line);
        // comment/blank lines have argv(0) != "mat" and are skipped naturally.
        if (n >= 4 && argv(0) == "mat" && sp_mat_count < SP_MAX_MAT)
        {
            float mi = sp_mat_count;
            // strzone every stored token: argv()/strtolower() return TEMPSTRINGS that get recycled
            // during gameplay (getsurfacetexture churns the pool), which would corrupt the table.
            sp_mat_name[mi]     = strzone(argv(1));
            sp_mat_footstep[mi] = strzone(strtolower(argv(2)));
            sp_mat_impact[mi]   = Surf_ImpactNameToCode(strtolower(argv(3)));
            sp_mat_count = mi + 1;
            if (sp_mat_name[mi] == "default")
                sp_default_mat = mi;
            float pi;
            for (pi = 4; pi < n && sp_pat_count < SP_MAX_PAT; pi = pi + 1)
            {
                sp_pat_text[sp_pat_count] = strzone(strtolower(argv(pi)));
                sp_pat_mat[sp_pat_count]  = mi;
                sp_pat_count = sp_pat_count + 1;
            }
        }
        line = fgets(f);
    }
    fclose(f);

    // Ensure a fallback even if no material was named "default".
    if (sp_default_mat < 0 && sp_mat_count > 0)
        sp_default_mat = sp_mat_count - 1;
    sp_loaded = 1;
};
