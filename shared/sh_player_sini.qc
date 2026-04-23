// ============================================================
//  shared/sh_player_sini.qc  -  Sini model animation lookups
//
//  Uses frameforname() to resolve animations by name at runtime,
//  so this works regardless of sequence index ordering.
//
//  Sini bone layout:
//    0-15: Root, Pelvis, Spine chain, Arms, Hands, Head
//    16-21: Legs (L Leg=16, R Leg=19)
//    Basebone split: "Bip01 L Leg" (index 16)
//    Bone controllers 0-3: Bip01, Pelvis, Spine, Spine1
// ============================================================

// Safe frameforname wrapper — returns fallback (idle=1) if name not found.
float(float mdlidx, string name) Sini_Frame =
{
    if (mdlidx <= 0)
        return 1; // no model loaded yet, use idle

    float f = frameforname(mdlidx, name);
    if (f < 0)
    {
        dprint(sprintf("SINI: animation '%s' not found (mdlidx=%d)\n", name, mdlidx));
        return 1; // fallback to idle
    }
    return f;
};

// Map weapon animation family to sini's animation name suffix.
// Names match the $sequence names in sini's QC exactly.
string(float family) Sini_GetAnimSuffix =
{
    switch (family)
    {
    case PANIM_KNIFE:    return "crowbar";
    case PANIM_ONEHAND:  return "onehanded";
    case PANIM_CARBINE:  return "m16";
    case PANIM_RIFLE:    return "sniper";
    case PANIM_MP5:      return "mp5";
    case PANIM_SHOTGUN:  return "shotgun";
    case PANIM_PARA:     return "minigun";  // sini calls M249/SAW "minigun"
    case PANIM_GRENADE:  return "gren";
    case PANIM_AK47:     return "mp5";      // no ak47 in sini, use mp5
    default:             return "onehanded";
    }
};

// --- Weapon pose lookups ---

float(float mdlidx, float family, float crouching) Sini_GetAimAnim =
{
    string suf = Sini_GetAnimSuffix(family);
    if (crouching)
        return Sini_Frame(mdlidx, strcat("crouch_aim_", suf));
    else
        return Sini_Frame(mdlidx, strcat("ref_aim_", suf));
};

float(float mdlidx, float family, float crouching) Sini_GetShootAnim =
{
    string suf = Sini_GetAnimSuffix(family);
    if (crouching)
        return Sini_Frame(mdlidx, strcat("crouch_shoot_", suf));
    else
        return Sini_Frame(mdlidx, strcat("ref_shoot_", suf));
};

float(float mdlidx, float family, float crouching) Sini_GetReloadAnim =
{
    string suf = Sini_GetAnimSuffix(family);
    // Knife and grenade have no reload — return aim pose
    if (family == PANIM_KNIFE || family == PANIM_GRENADE)
        return Sini_GetAimAnim(mdlidx, family, crouching);

    if (crouching)
        return Sini_Frame(mdlidx, strcat("crouch_reload_", suf));
    else
        return Sini_Frame(mdlidx, strcat("ref_reload_", suf));
};

// --- Locomotion ---

float(float mdlidx) Sini_GetIdleAnim =
{
    return Sini_Frame(mdlidx, "idle");
};

float(float mdlidx) Sini_GetCrouchIdleAnim =
{
    return Sini_Frame(mdlidx, "crouch_idle");
};

float(float mdlidx) Sini_GetRunAnim =
{
    return Sini_Frame(mdlidx, "run2");
};

float(float mdlidx) Sini_GetCrouchRunAnim =
{
    return Sini_Frame(mdlidx, "crawl");
};

float(float mdlidx) Sini_GetJumpAnim =
{
    return Sini_Frame(mdlidx, "jump");
};

// --- Death ---

float(float mdlidx) Sini_GetRandomDeathAnim =
{
    float r = floor(random() * 7);
    switch (r)
    {
    case 0: return Sini_Frame(mdlidx, "die_simple");
    case 1: return Sini_Frame(mdlidx, "die_backwards1");
    case 2: return Sini_Frame(mdlidx, "die_backwards");
    case 3: return Sini_Frame(mdlidx, "die_forwards");
    case 4: return Sini_Frame(mdlidx, "headshot");
    case 5: return Sini_Frame(mdlidx, "die_spin");
    default: return Sini_Frame(mdlidx, "gutshot");
    }
};
