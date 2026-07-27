// ===========================================================================
// sh_propmaterials.qc - physics-prop MATERIAL + WEIGHT table.
//
// Sister to sh_surfaceprops.qc, but keyed on an ENTITY MODEL path instead of a
// world texture: PropMat_For(entity.model) -> material index, from which weight
// (density x bbox volume), friction, bounce, damping (and later sound / impact /
// debris) are derived.  Data lives in scripts/propmaterials.txt.
//
// Shared unit - compiled into csprogs AND qwprogs.  MUST be listed AFTER
// shared/sh_weapons.qc (needs IMPACT_MAT_*) and AFTER shared/sh_surfaceprops.qc
// (reuses Surf_TexMatch + Surf_ImpactNameToCode).
//
// Reload live: `propmat_reloadmaterials`.  See propmaterials.txt for the format.
// ===========================================================================

const float PM_MAX_MAT = 16;
const float PM_MAX_PAT = 384;

float  pm_mat_count;
string pm_name    [PM_MAX_MAT];   // material name (assignment + debug readout)
float  pm_density [PM_MAX_MAT];   // mass = clamp(density*(bboxvol/1000)*scale, min, max)
float  pm_massmin [PM_MAX_MAT];
float  pm_massmax [PM_MAX_MAT];
float  pm_friction[PM_MAX_MAT];   // ODE surface friction
float  pm_restit  [PM_MAX_MAT];   // bouncefactor
float  pm_dampmult[PM_MAX_MAT];   // multiplies the sv_physprop_damp_* cvars
string pm_fxsound [PM_MAX_MAT];   // contact-sound set token   (reserved: sound phase)
float  pm_impact  [PM_MAX_MAT];   // IMPACT_MAT_* for bullet fx (reserved: impact phase)
string pm_debris  [PM_MAX_MAT];   // gib/debris style token     (reserved: break phase)
float  pm_health  [PM_MAX_MAT];   // base-health multiplier     (reserved: break phase)
float  pm_break   [PM_MAX_MAT];   // 1 = destructible           (reserved: break phase)

float  pm_pat_count;
string pm_pat_text[PM_MAX_PAT];   // pattern (lowercased), file order
float  pm_pat_mat [PM_MAX_PAT];   // -> material index

float  pm_default_mat;            // fallback material index (-1 = table not loaded)
float  pm_loaded;

// material NAME -> index (-1 if unknown).
float(string name) PropMat_NameToIndex =
{
    float i;
    for (i = 0; i < pm_mat_count; i = i + 1)
        if (pm_name[i] == name)
            return i;
    return -1;
};

// Normalize an entity model path to the key patterns match on: lowercase, drop a
// leading "models/", drop the file extension.  e.g.
//   "models/props/containers/mega/metal_barrel_mp_1.iqm" -> "mega/containers/metal_barrel_mp_1"
string(string model) PropMat_Normalize =
{
    string s = strtolower(model);
    if (substring(s, 0, 7) == "models/")
        s = substring(s, 7, strlen(s) - 7);
    // truncate at the LAST '.' (the extension) - keep any dots in dir names intact.
    float dot = -1, p = strstrofs(s, ".", 0);
    while (p >= 0) { dot = p; p = strstrofs(s, ".", p + 1); }
    if (dot >= 0)
        s = substring(s, 0, dot);
    return s;
};

// model path -> material index (pm_default_mat, or -1, when nothing matches).
float(string model) PropMat_For =
{
    if (model == "") return pm_default_mat;
    string key = PropMat_Normalize(model);
    float found = pm_default_mat;
    float i;
    for (i = 0; i < pm_pat_count; i = i + 1)
        if (Surf_TexMatch(pm_pat_text[i], key))   // reused from sh_surfaceprops.qc
        {
            found = pm_pat_mat[i];
            break;
        }
    return found;
};

// ---- accessors (clamped; safe defaults when the table is missing / out of range) ----
string(float m) PropMat_Name     = { if (m < 0 || m >= pm_mat_count) return "default"; return pm_name[m]; };
float (float m) PropMat_Density  = { if (m < 0 || m >= pm_mat_count) return 0.5;  return pm_density[m]; };
float (float m) PropMat_Friction = { if (m < 0 || m >= pm_mat_count) return 1.0;  return pm_friction[m]; };
float (float m) PropMat_Restit   = { if (m < 0 || m >= pm_mat_count) return 0.0;  return pm_restit[m]; };
float (float m) PropMat_DampMult = { if (m < 0 || m >= pm_mat_count) return 1.0;  return pm_dampmult[m]; };
string(float m) PropMat_FxSound  = { if (m < 0 || m >= pm_mat_count) return "";   return pm_fxsound[m]; };
float (float m) PropMat_ImpactMat= { if (m < 0 || m >= pm_mat_count) return IMPACT_MAT_DEFAULT; return pm_impact[m]; };
string(float m) PropMat_Debris   = { if (m < 0 || m >= pm_mat_count) return "wood"; return pm_debris[m]; };
float (float m) PropMat_Health   = { if (m < 0 || m >= pm_mat_count) return 1.0;  return pm_health[m]; };
float (float m) PropMat_Breakable= { if (m < 0 || m >= pm_mat_count) return 0;    return pm_break[m]; };

// Derived weight: density * bbox-volume, clamped to the material's min/max, times
// the global sv_propmat_mass_scale knob.  Call AFTER setmodel (needs e.mins/maxs).
float(float m, entity e) PropMat_Mass =
{
    if (m < 0 || m >= pm_mat_count)
        return 20;   // no material -> a sane fallback mass
    float vol = (e.maxs_x - e.mins_x) * (e.maxs_y - e.mins_y) * (e.maxs_z - e.mins_z);
    if (vol < 0) vol = 0 - vol;
    float scale = cvar("sv_propmat_mass_scale"); if (scale <= 0) scale = 1;
    float mm = pm_density[m] * (vol / 1000) * scale;
    if (mm < pm_massmin[m]) mm = pm_massmin[m];
    if (mm > pm_massmax[m]) mm = pm_massmax[m];
    return mm;
};

// (Re)load scripts/propmaterials.txt.  Called at client + server init and from
// `propmat_reloadmaterials`.  Missing file => PropMat_For returns -1 => cvar fallback.
void() PropMat_LoadMaterials =
{
    float k;
    if (pm_loaded)   // free strzoned strings on reload
    {
        for (k = 0; k < pm_mat_count; k = k + 1)
        {
            strunzone(pm_name[k]);
            strunzone(pm_fxsound[k]);
            strunzone(pm_debris[k]);
        }
        for (k = 0; k < pm_pat_count; k = k + 1)
            strunzone(pm_pat_text[k]);
    }
    pm_mat_count = 0;
    pm_pat_count = 0;
    pm_default_mat = -1;
    pm_loaded = 0;

    filestream f = fopen("scripts/propmaterials.txt", FILE_READ);
    if (f < 0)
        return;

    string line = fgets(f);
    while (line)
    {
        float n = tokenize(line);
        if (n >= 13 && argv(0) == "propmat" && pm_mat_count < PM_MAX_MAT)
        {
            float mi = pm_mat_count;
            pm_name[mi]     = strzone(strtolower(argv(1)));
            pm_density[mi]  = stof(argv(2));
            pm_massmin[mi]  = stof(argv(3));
            pm_massmax[mi]  = stof(argv(4));
            pm_friction[mi] = stof(argv(5));
            pm_restit[mi]   = stof(argv(6));
            pm_dampmult[mi] = stof(argv(7));
            pm_fxsound[mi]  = strzone(strtolower(argv(8)));
            pm_impact[mi]   = Surf_ImpactNameToCode(strtolower(argv(9)));
            pm_debris[mi]   = strzone(strtolower(argv(10)));
            pm_health[mi]   = stof(argv(11));
            pm_break[mi]    = stof(argv(12));
            if (pm_name[mi] == "default")
                pm_default_mat = mi;
            pm_mat_count = mi + 1;
        }
        else if (n >= 3 && argv(0) == "propassign")
        {
            float amat = PropMat_NameToIndex(strtolower(argv(1)));
            if (amat < 0) amat = pm_default_mat;   // unknown material -> default
            float pi;
            for (pi = 2; pi < n && pm_pat_count < PM_MAX_PAT; pi = pi + 1)
            {
                pm_pat_text[pm_pat_count] = strzone(strtolower(argv(pi)));
                pm_pat_mat[pm_pat_count]  = amat;
                pm_pat_count = pm_pat_count + 1;
            }
        }
        line = fgets(f);
    }
    fclose(f);

    if (pm_default_mat < 0 && pm_mat_count > 0)
        pm_default_mat = pm_mat_count - 1;
    pm_loaded = 1;
};
