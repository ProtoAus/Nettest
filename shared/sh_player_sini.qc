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
    // Sven's only two-guns-in-two-hands pose is the akimbo UZIs'; a Sven-shaped
    // model has no dual-pistol set of its own, so the dual Berettas and the
    // dual Deagles borrow it.  C4 is planted like a satchel/tripmine charge.
    case PANIM_DUALPISTOLS: return "uzis";
    case PANIM_C4:          return "trip";

    // The Half-Life families pass STRAIGHT THROUGH, because sini is itself a
    // Sven-shaped model and its sequences are already named this way - the
    // suffixes here are Sven's own.  Without these the default below would
    // silently answer "onehanded" for all 26 weapons that were retargeted onto
    // the HL families, i.e. every crowbar, RPG and SAW would go back to being
    // held like a pistol on this one model.
    case PANIM_HL_CROWBAR: return "crowbar";
    case PANIM_HL_PYTHON:  return "python";
    case PANIM_HL_GAUSS:   return "gauss";
    case PANIM_HL_EGON:    return "egon";
    case PANIM_HL_RPG:     return "rpg";
    case PANIM_HL_SAW:     return "saw";
    case PANIM_HL_SNIPER:  return "sniper";
    case PANIM_HL_M16:     return "m16";
    case PANIM_HL_MINIGUN: return "minigun";
    case PANIM_HL_BOW:     return "bow";
    case PANIM_HL_HIVE:    return "hive";
    case PANIM_HL_SQUEAK:  return "squeak";
    case PANIM_HL_TRIP:    return "trip";
    case PANIM_HL_WRENCH:  return "wrench";
    case PANIM_HL_UZIS:    return "uzis";
    case PANIM_HL_GREN:    return "gren";
    case PANIM_HL_M203:    return "m16";    // underbarrel: aims as the rifle

    default:             return "onehanded";
    }
};

// --- Weapon pose lookups ---

float(float mdlidx, float family, float crouching) Sini_GetAimAnim =
{
    string suf = Sini_GetAnimSuffix(family);
    string pre = crouching ? "crouch_" : "ref_";
    if (mdlidx <= 0)
        return 1;
    // Try aim, then HOLD.  The wrench has no aim pose anywhere in the Sven
    // animation set - its ready stance is spelt `ref_hold_wrench` - and sini
    // carries the full 191-sequence Sven set, so without this the pipe wrench
    // misses and Sini_Frame drops the whole model to idle.  Same substitution
    // SH_HLFrame makes for the rebuilt CS models; keeping the two in step is
    // why it is spelt out here rather than special-cased in the suffix table.
    float f = frameforname(mdlidx, strcat(pre, "aim_", suf));
    if (f >= 0)
        return f;
    f = frameforname(mdlidx, strcat(pre, "hold_", suf));
    if (f >= 0)
        return f;
    return Sini_Frame(mdlidx, strcat(pre, "aim_", suf));   // logs the miss
};

// Per-hand suffix swap, matching SH_HLFrame's.  Sini carries the full
// 191-sequence Sven set, so it hits the same naming quirk: the akimbo UZIs are
// animated PER HAND as _both / _left / _right, and there is no bare
// `ref_shoot_uzis` or `ref_reload_uzis` at all — only the aim pose carries the
// plain name.  Left unhandled here the miss is worse than on the CS models,
// because Sini_Frame's fallback is the whole-body idle rather than another
// weapon pose: the player would stand up straight mid-burst.
string(float family, string verb, string suf) Sini_VerbSuffix =
{
    if (family == PANIM_HL_UZIS)
    {
        if (verb == "shoot")  return "uzis_both";
        if (verb == "reload") return "uzis_right";
    }
    return suf;
};

float(float mdlidx, float family, float crouching) Sini_GetShootAnim =
{
    string suf = Sini_VerbSuffix(family, "shoot", Sini_GetAnimSuffix(family));
    string pre = crouching ? "crouch_" : "ref_";
    if (mdlidx <= 0)
        return 1;
    float f = frameforname(mdlidx, strcat(pre, "shoot_", suf));
    if (f >= 0)
        return f;
    // Hold the aim pose rather than let Sini_Frame drop the model to idle —
    // the wrong gun pose is bad, standing at ease while firing is worse.
    return Sini_GetAimAnim(mdlidx, family, crouching);
};

float(float mdlidx, float family, float crouching) Sini_GetReloadAnim =
{
    string suf = Sini_VerbSuffix(family, "reload", Sini_GetAnimSuffix(family));
    string pre = crouching ? "crouch_" : "ref_";
    if (mdlidx <= 0)
        return 1;
    // Knife and grenade have no reload — return aim pose
    if (family == PANIM_KNIFE || family == PANIM_GRENADE)
        return Sini_GetAimAnim(mdlidx, family, crouching);

    float f = frameforname(mdlidx, strcat(pre, "reload_", suf));
    if (f >= 0)
        return f;
    // Neither does most of the Half-Life set — crowbar, wrench, gren, squeak,
    // trip, gauss, egon, minigun and hive all lack a reload in Sven's own
    // animation list.  SH_GetReloadAnim substitutes the aim pose for exactly
    // this reason; do the same here instead of logging a miss and idling.
    return Sini_GetAimAnim(mdlidx, family, crouching);
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
