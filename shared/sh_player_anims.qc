// ============================================================
//  shared/sh_player_anims.qc  -  GoldSrc CS-style player body animation
//
//  Server-authoritative single-layer animation for the third-person
//  player model. Picks one of the canonical CS 1.6 player sequences
//  (idle / walk / run / crouch / jump) based on velocity, ground
//  state, and crouch state, then writes it to self.frame.
//
//  The full-body sequences (CSANIM_WALK, CSANIM_RUN, etc.) include
//  animated legs even though they look stationary in HLMV — HLMV
//  defaults to playing upper-body-only aim sequences. The locomotion
//  sequences are full body and animate the legs correctly.
//
//  Single-layer is intentional for phase A: only self.frame is used,
//  which is a standard replicated entity field. The dual-layer split
//  (torso aim + leg gait via .baseframe / bonecontrols) is a future
//  upgrade — those fields require a custom SendEntity to replicate
//  reliably, and that plumbing is its own phase.
//
//  This file is compiled by BOTH sv_progs and cl_progs so the
//  CSANIM_* enum is visible everywhere. The update function is
//  server-only.
// ============================================================

// --- CS 1.6 player model sequence indices ---
// Ported verbatim from cstrike/src/shared/Animations.h.
// gsg9.mdl and the other 4 player models follow this layout.
const float CSANIM_DUMMY1                  = 0;
const float CSANIM_IDLE                    = 1;
const float CSANIM_IDLE_CROUCH             = 2;
const float CSANIM_WALK                    = 3;
const float CSANIM_RUN                     = 4;
const float CSANIM_RUN_CROUCH              = 5;
const float CSANIM_JUMP                    = 6;
const float CSANIM_LONGJUMP                = 7;
const float CSANIM_SWIM                    = 8;
const float CSANIM_TREADWATER              = 9;
const float CSANIM_CROUCH_AIM_CARBINE      = 10;
const float CSANIM_CROUCH_SHOOT_CARBINE    = 11;
const float CSANIM_CROUCH_RELOAD_CARBINE   = 12;
const float CSANIM_AIM_CARBINE             = 13;
const float CSANIM_SHOOT_CARBINE           = 14;
const float CSANIM_RELOAD_CARBINE          = 15;
const float CSANIM_CROUCH_AIM_ONEHAND      = 16;
const float CSANIM_CROUCH_SHOOT_ONEHAND    = 17;
const float CSANIM_CROUCH_RELOAD_ONEHAND   = 18;
const float CSANIM_AIM_ONEHAND             = 19;
const float CSANIM_SHOOT_ONEHAND           = 20;
const float CSANIM_RELOAD_ONEHAND          = 21;
const float CSANIM_CROUCH_AIM_DUALPISTOLS  = 22;
const float CSANIM_CROUCH_SHOOT_DUALPISTOLS = 23;
const float CSANIM_CROUCH_SHOOT2_DUALPISTOLS = 24;
const float CSANIM_CROUCH_RELOAD_DUALPISTOLS = 25;
const float CSANIM_AIM_DUALPISTOLS         = 26;
const float CSANIM_SHOOT_DUALPISTOLS       = 27;
const float CSANIM_SHOOT2_DUALPISTOLS      = 28;
const float CSANIM_RELOAD_DUALPISTOLS      = 29;
const float CSANIM_CROUCH_AIM_RIFLE        = 30;
const float CSANIM_CROUCH_SHOOT_RIFLE      = 31;
const float CSANIM_CROUCH_RELOAD_RIFLE     = 32;
const float CSANIM_AIM_RIFLE               = 33;
const float CSANIM_SHOOT_RIFLE             = 34;
const float CSANIM_RELOAD_RIFLE            = 35;
const float CSANIM_CROUCH_AIM_MP5          = 36;
const float CSANIM_CROUCH_SHOOT_MP5        = 37;
const float CSANIM_CROUCH_RELOAD_MP5       = 38;
const float CSANIM_AIM_MP5                 = 39;
const float CSANIM_SHOOT_MP5               = 40;
const float CSANIM_RELOAD_MP5              = 41;
const float CSANIM_CROUCH_AIM_SHOTGUN      = 42;
const float CSANIM_CROUCH_SHOOT_SHOTGUN    = 43;
const float CSANIM_CROUCH_RELOAD_SHOTGUN   = 44;
const float CSANIM_AIM_SHOTGUN             = 45;
const float CSANIM_SHOOT_SHOTGUN           = 46;
const float CSANIM_RELOAD_SHOTGUN          = 47;
const float CSANIM_CROUCH_AIM_PARA         = 48;
const float CSANIM_CROUCH_SHOOT_PARA       = 49;
const float CSANIM_CROUCH_RELOAD_PARA      = 50;
const float CSANIM_AIM_PARA                = 51;
const float CSANIM_SHOOT_PARA              = 52;
const float CSANIM_RELOAD_PARA             = 53;
const float CSANIM_DUMMY2                  = 54;
const float CSANIM_DUMMY3                  = 55;
const float CSANIM_AIM_GRENADE             = 56;
const float CSANIM_SHOOT_GRENADE           = 57;
const float CSANIM_CROUCH_AIM_GRENADE      = 58;
const float CSANIM_CROUCH_SHOOT_GRENADE    = 59;
const float CSANIM_CROUCH_AIM_C4           = 60;
const float CSANIM_CROUCH_SHOOT_C4         = 61;
const float CSANIM_AIM_C4                  = 62;
const float CSANIM_SHOOT_C4                = 63;
const float CSANIM_RELOAD_C4               = 64;
const float CSANIM_DUPLICATE1              = 65;
const float CSANIM_DUPLICATE2              = 66;
const float CSANIM_DUPLICATE3              = 67;
const float CSANIM_DUPLICATE4              = 68;
const float CSANIM_DUPLICATE5              = 69;
const float CSANIM_DUPLICATE6              = 70;
const float CSANIM_DUPLICATE7              = 71;
const float CSANIM_DUPLICATE8              = 72;
const float CSANIM_CROUCH_AIM_KNIFE        = 73;
const float CSANIM_CROUCH_SHOOT_KNIFE      = 74;
const float CSANIM_AIM_KNIFE               = 75;
const float CSANIM_SHOOT_KNIFE             = 76;
const float CSANIM_CROUCH_AIM_AK47         = 77;
const float CSANIM_CROUCH_SHOOT_AK47       = 78;
const float CSANIM_CROUCH_RELOAD_AK47      = 79;
const float CSANIM_AIM_AK47                = 80;
const float CSANIM_SHOOT_AK47              = 81;
const float CSANIM_RELOAD_AK47             = 82;
// Indices 83-98 are the shield variants, and they are no longer unused: the
// tactical shield (shared/weapons/sh_wpn_csshield.qc) plays them.  Verified
// against cstrike/models/player/urban/urban.mdl's own 111-sequence list, which
// is the file the CSANIM_* block above was transcribed from.
const float CSANIM_CROUCH_AIM_SHIELDGREN   = 83;
const float CSANIM_CROUCH_SHOOT_SHIELDGREN = 84;
const float CSANIM_AIM_SHIELDGREN          = 85;
const float CSANIM_SHOOT_SHIELDGREN        = 86;
const float CSANIM_CROUCH_AIM_SHIELDKNIFE  = 87;
const float CSANIM_CROUCH_SHOOT_SHIELDKNIFE = 88;
const float CSANIM_AIM_SHIELDKNIFE         = 89;
const float CSANIM_SHOOT_SHIELDKNIFE       = 90;
const float CSANIM_CROUCH_AIM_SHIELDGUN    = 91;
const float CSANIM_CROUCH_SHOOT_SHIELDGUN  = 92;
const float CSANIM_CROUCH_RELOAD_SHIELDGUN = 93;
const float CSANIM_AIM_SHIELDGUN           = 94;
const float CSANIM_SHOOT_SHIELDGUN         = 95;
const float CSANIM_RELOAD_SHIELDGUN        = 96;
// The two "shield up" poses.  There is no shoot or reload here by design —
// a raised shield is exactly the state in which you can do neither.
const float CSANIM_CROUCH_AIM_SHIELDED     = 97;
const float CSANIM_AIM_SHIELDED            = 98;
// Flinch and death sequences start at 99+ (0-indexed).
const float CSANIM_GUT_FLINCH              = 99;
const float CSANIM_HEAD_FLINCH             = 100;
const float CSANIM_DEATH1                  = 101;  // land on stomach
const float CSANIM_DEATH2                  = 102;  // land on back
const float CSANIM_DEATH3                  = 103;  // dramatic
const float CSANIM_DIE_HEAD                = 104;  // headshot
const float CSANIM_DIE_GUT                 = 105;  // gutshot
const float CSANIM_DIE_LEFT                = 106;  // hit from right, fall left
const float CSANIM_DIE_BACK                = 107;  // hit from front, fall backward
const float CSANIM_DIE_RIGHT               = 108;  // hit from left, fall right
const float CSANIM_DIE_FORWARD             = 109;  // hit from behind, fall forward
const float CSANIM_CROUCH_DIE              = 110;  // die while crouching
// Custom: single-frame static-leg poses used by the legs-side anim slot
// during idle/crouch-idle. Replace CSANIM_IDLE / CSANIM_IDLE_CROUCH on
// the legs side because idle1 / crouch_idle have internal IK that fights
// FTE's basebone split (the legs counter-rotate against root translation
// that the split severs from them, producing the "feet drift" symptom).
// All 8 player models append both sequences in the same order after the
// stock 0..110 list, so the indices match across every model.
const float CSANIM_LEGS_IDLE_STATIC        = 111;
const float CSANIM_LEGS_CROUCH_STATIC      = 112;

// ---------------------------------------------------------------------------
//  Half-Life / Sven animation families, resolved by NAME
// ---------------------------------------------------------------------------
// The 11 CS-derived player IQMs now carry Sven's 168 extra sequences appended
// after the stock 113 (see Desktop/playermodels/merge_sven_anims.py), so a
// crowbar can play `ref_aim_crowbar` instead of borrowing the CS knife pose.
//
// BY NAME, NOT BY INDEX, and that is the whole point: the CSANIM_* constants
// below are sequence indices and adding anything ahead of them would break
// every one of them, so the Sven set was APPENDED and is addressed through
// frameforname().  A model that has not been rebuilt simply misses, and
// SH_HLAnimFallback puts it back on the CS family it used before - so this is
// safe to ship ahead of the models, and safe on any custom player model a
// server owner drops in.
string(float family) SH_HLAnimSuffix =
{
    switch (family)
    {
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
    case PANIM_HL_M203:    return "m203";
    default:               return "";
    }
};

// Where each HL family lands when the model has no Sven sequences.  Chosen by
// silhouette rather than by calibre: what matters third-person is whether the
// gun is held one-handed, at the shoulder, or braced, so the RPG and the SAW
// both fall back to PARA (the two-handed braced pose) rather than to RIFLE.
float(float family) SH_HLAnimFallback =
{
    switch (family)
    {
    case PANIM_HL_CROWBAR: return PANIM_KNIFE;
    case PANIM_HL_WRENCH:  return PANIM_KNIFE;
    case PANIM_HL_PYTHON:  return PANIM_ONEHAND;
    case PANIM_HL_HIVE:    return PANIM_ONEHAND;
    case PANIM_HL_GAUSS:   return PANIM_RIFLE;
    case PANIM_HL_SNIPER:  return PANIM_RIFLE;
    case PANIM_HL_BOW:     return PANIM_RIFLE;
    case PANIM_HL_EGON:    return PANIM_PARA;
    case PANIM_HL_RPG:     return PANIM_PARA;
    case PANIM_HL_SAW:     return PANIM_PARA;
    case PANIM_HL_MINIGUN: return PANIM_PARA;
    case PANIM_HL_M16:     return PANIM_CARBINE;
    case PANIM_HL_M203:    return PANIM_CARBINE;
    // Akimbo falls back to the CS DUAL-PISTOL pose, not the MP5.  Two guns in
    // two hands is a far closer read than one submachine gun in both, and the
    // dual-pistol sequences are present on every CS-derived model.
    case PANIM_HL_UZIS:    return PANIM_DUALPISTOLS;
    case PANIM_HL_SQUEAK:  return PANIM_GRENADE;
    case PANIM_HL_TRIP:    return PANIM_GRENADE;
    case PANIM_HL_GREN:    return PANIM_GRENADE;
    // UNCHANGED, not PANIM_ONEHAND.  Every CS family reaches this default too,
    // and mapping those onto ONEHAND would silently replace the entire stock
    // animation set with the pistol pose.
    default:               return family;
    }
};

// Resolve one HL pose.  Returns -1 when this is not an HL family or the model
// does not carry the sequence, which is the caller's signal to fall through to
// the Counter-Strike index table.
//
// `verb` is "aim" / "shoot" / "reload"; the prefix is Sven's own
// crouch_<verb>_<suffix> / ref_<verb>_<suffix> spelling.
float(float mdlidx, float family, float crouching, string verb) SH_HLFrame =
{
    if (mdlidx <= 0)
        return -1;
    string suf = SH_HLAnimSuffix(family);
    if (suf == "")
        return -1;
    string pre = crouching ? "crouch_" : "ref_";

    // The M203 is an underbarrel launcher.  Sven gives it its own shoot and
    // reload but NO aim of its own, because what you are aiming is the M16 it
    // is bolted to - so borrow the rifle's aim rather than missing and dropping
    // the whole weapon back onto a Counter-Strike pose.
    if (verb == "aim" && family == PANIM_HL_M203)
        suf = "m16";

    // The akimbo UZIs are animated PER HAND: Sven ships ref_shoot_uzis_both /
    // _left / _right and ref_reload_uzis_left / _right, and no plain
    // `ref_shoot_uzis` or `ref_reload_uzis` at all.  Only the aim pose carries
    // the bare name.  Without this the shoot verb misses and SH_HLAnimFallback
    // drops the player onto the CS MP5 pose for the whole burst - one gun in
    // one hand, then back to two the moment they stop firing.  Fire both, and
    // reload the right hand (the mod reloads the pair as one action, so either
    // hand's animation is a fair stand-in and the right one reads better than
    // holding the aim pose).
    if (family == PANIM_HL_UZIS)
    {
        if (verb == "shoot")
            suf = "uzis_both";
        else if (verb == "reload")
            suf = "uzis_right";
    }

    float f = frameforname(mdlidx, strcat(pre, verb, "_", suf));
    if (f >= 0)
        return f;

    // The wrench has no aim pose either: Sven spells its ready stance
    // `ref_hold_wrench`, the same way it spells the primed grenade's.  Measured
    // on the rebuilt models - without this, 15 of the 17 families resolved and
    // the wrench and M203 silently reverted to the CS knife and carbine.
    if (verb == "aim")
        return frameforname(mdlidx, strcat(pre, "hold_", suf));
    return -1;
};

// One line per map, self-latching, in the same shape as GoldSrcFX_Report and
// Modellist_Report.  Answers the only question that matters after rebuilding
// the player models: did the Half-Life sequences actually land in them?
//
// Worth being a permanent report rather than a one-off check, because the
// failure is silent and looks like nothing: a model that was not rebuilt
// resolves none of these, SH_HLAnimFallback quietly puts every HL weapon back
// on its old Counter-Strike pose, and the game looks exactly as it did before.
// "It did not work" and "it was never built" are otherwise the same
// observation - the same reasoning sv_ai_core.qc records for its own reports.
float sh_hlanim_reported;

// Is this model animated the Sven Co-op way rather than the Counter-Strike way?
//
// This matters because the CSANIM_* constants are INDICES into the
// Counter-Strike sequence list, and on a Sven-shaped model those indices land
// on unrelated animations.  Measured against th_civpaul.mdl: ALL 97 of them
// miss.  CSANIM_IDLE plays `look_idle`, CSANIM_RUN plays `walk2handed`,
// CSANIM_AIM_RIFLE plays `ref_cock_gren`, CSANIM_DEATH1 plays
// `ref_shoot_squeak`.  That is not hypothetical: th_escape hands every player
// one of sixteen Sven models (sv_mapscript_thescape.qc:736), and
// player_model_override lets a map script pin any other.
//
// The complete name-based path for such a model already existed - it was
// written for sini and gated on one hardcoded player_model_index.  Gate it on
// the MODEL instead and every Sven-shaped model gets it.
//
// Positive test for BOTH shapes, defaulting to the Counter-Strike path:
//   ref_aim_carbine / _blend05  exists only on CS-derived models (the rebuilt
//                               IQMs carry it under the source SMD's filename)
//   ref_hold_wrench             exists on anything carrying the Sven set
// A model matching NEITHER - a stock Half-Life player model, an unknown custom
// one - keeps the old behaviour rather than being sent down a path whose
// sequences it certainly does not have.  Verified across 151 models on disk:
// 11 rebuilt IQMs, 15 CS .mdl, sini, 101 Sven, 9 stock cstrike, 14 stock HL -
// zero misroutes either way.
float(float mdlidx) SH_ModelIsSven =
{
    if (mdlidx <= 0)
        return FALSE;
    if (frameforname(mdlidx, "ref_aim_carbine") >= 0)
        return FALSE;
    if (frameforname(mdlidx, "ref_aim_carbine_blend05") >= 0)
        return FALSE;
    return (frameforname(mdlidx, "ref_hold_wrench") >= 0);
};

// ============================================================
//  DAY OF DEFEAT — shape test and measurement probe
// ============================================================
//
// A THIRD model shape, alongside Counter-Strike (index table) and Sven (name
// table).  DoD's player models carry 345 sequences named
// <stance>_<weapon>_<verb> — `stand_rifle_aim`, `crouch_garand_reload`,
// `bipod_mg42_reload` — which is the REVERSE token order of Sven's
// `ref_<verb>_<suffix>`, so SH_HLFrame cannot be reused for them; it has to be
// imitated.  Nothing calls this yet: it is the shape test the resolver arm will
// need, landed early so the probe below can measure with the real predicate
// rather than a throwaway one.
//
// Positive test on TWO names, the same discipline SH_ModelIsSven uses:
//   dod_idle1        the locomotion set's root — present on all five DoD models
//   stand_rifle_aim  a weapon pose, so a model carrying DoD locomotion but no
//                    weapon takes cannot pass
// A model matching neither shape keeps the Counter-Strike index path, exactly as
// before.  ORDER MATTERS at the call sites: this must be asked before the CS
// fallback and it must not disturb SH_ModelIsSven's "zero misroutes across 151
// models" result, so the two probes share no name.
float(float mdlidx) SH_ModelIsDoD =
{
    if (mdlidx <= 0)
        return FALSE;
    if (frameforname(mdlidx, "dod_idle1") < 0)
        return FALSE;
    return (frameforname(mdlidx, "stand_rifle_aim") >= 0);
};

float sh_dodanim_reported;

// One line per model per map, self-latching, in the shape of SH_HLAnimReport
// below and of GoldSrcFX_Report / Modellist_Report.  This is Phase 0 of the DoD
// body-animation work and it exists to answer, headlessly, the four questions
// every later phase depends on:
//
//   1. does FTE load a 345-sequence studio player model at all, and does
//      frameforname answer on it (the mount at fs_addons.txt:50 is real);
//   2. is `Bip01 Spine` at the same bone on all five (it is — 8, on 34/34/34/35/32
//      bone rigs), which is the basebone split the torso/legs layering needs;
//   3. do the DoD takes resolve by name, and at WHICH INDEX;
//   4. HOW MANY OF THOSE INDICES ARE ABOVE 255 — the visual proxy writes
//      .frame and .baseframe as single bytes (sv_player.qc, VP_SF_ANIM), so any
//      take at 256+ arrives at the client as index-256: a DIFFERENT REAL POSE,
//      silently, because WriteByte masks rather than erroring.  That count is the
//      whole argument for widening the wire, so it is measured, not asserted.
//
// The bone probe needs an ENTITY (gettagindex takes one, frameforname takes a
// modelindex), so a scratch entity is spawned and removed per model.  gettagindex
// is 1-BASED — it returns bone_index + 1 — so the printed `spine` value is one
// more than the array index, and that off-by-one is exactly the thing the
// server/client basebone asymmetry turns on.  Printed raw and labelled.
void(float mdl, string label) SH_DoDReportOne =
{
    entity probe = spawn();
    setmodel(probe, label);
    float spine = gettagindex(probe, "Bip01 Spine");
    float lleg  = gettagindex(probe, "Bip01 L Leg");
    float lfoot = gettagindex(probe, "Bip01 R Foot");
    remove(probe);

    print(sprintf("[panim-dod] %s idx=%g seqs=%g shape=%s spine=%g lleg=%g rfoot=%g (gettagindex is 1-based)\n",
                  label, mdl, modelframecount(mdl),
                  SH_ModelIsDoD(mdl) ? "DoD" : (SH_ModelIsSven(mdl) ? "Sven" : "Counter-Strike"),
                  spine, lleg, lfoot));

    // A representative spread rather than all 345: one take per stance/verb
    // class, chosen so the OVER-255 cases are in the sample.  stand_* reloads sit
    // at 239-255 and just fit; every crouch reload and every deployed reload does
    // not, and those are the ones the current wire silently aliases.
    float a  = frameforname(mdl, "stand_rifle_aim");
    float b  = frameforname(mdl, "crouch_rifle_aim");
    float c  = frameforname(mdl, "stand_rifle_shoot");
    float d  = frameforname(mdl, "stand_garand_reload");
    float e  = frameforname(mdl, "crouch_garand_reload");
    float f  = frameforname(mdl, "bipod_mg42_reload");
    float g  = frameforname(mdl, "die_headshot");
    float h  = frameforname(mdl, "dod_walk");

    print(sprintf("[panim-dod]   stand_rifle_aim=%g crouch_rifle_aim=%g stand_rifle_shoot=%g stand_garand_reload=%g\n",
                  a, b, c, d));
    print(sprintf("[panim-dod]   crouch_garand_reload=%g bipod_mg42_reload=%g die_headshot=%g dod_walk=%g\n",
                  e, f, g, h));

    // The wire verdict, counted rather than claimed.
    float over = 0;
    if (a > 255) over = over + 1;
    if (b > 255) over = over + 1;
    if (c > 255) over = over + 1;
    if (d > 255) over = over + 1;
    if (e > 255) over = over + 1;
    if (f > 255) over = over + 1;
    if (g > 255) over = over + 1;
    if (h > 255) over = over + 1;
    print(sprintf("[panim-dod]   %g of 8 sampled takes are ABOVE 255 -> alias through the one-byte VP_SF_ANIM wire\n",
                  over));
};

void() SH_DoDAnimReport =
{
    if (sh_dodanim_reported)
        return;
    float probe = getmodelindex("models/player/us-inf/us-inf.mdl");
    if (probe <= 0)
        return;                 // not loaded yet; try again next tick
    sh_dodanim_reported = TRUE;

    SH_DoDReportOne(probe, "models/player/us-inf/us-inf.mdl");
    SH_DoDReportOne(getmodelindex("models/player/axis-inf/axis-inf.mdl"),   "models/player/axis-inf/axis-inf.mdl");
    SH_DoDReportOne(getmodelindex("models/player/brit-inf/brit-inf.mdl"),   "models/player/brit-inf/brit-inf.mdl");
    SH_DoDReportOne(getmodelindex("models/player/us-para/us-para.mdl"),     "models/player/us-para/us-para.mdl");
    SH_DoDReportOne(getmodelindex("models/player/axis-para/axis-para.mdl"), "models/player/axis-para/axis-para.mdl");

    // The CS models must still classify as Counter-Strike — a new positive probe
    // that accidentally matched them would silently re-route every shipping model.
    float cs = getmodelindex("models/player/leet/leet.iqm");
    print(sprintf("[panim-dod] control: leet.iqm shape=%s (must be Counter-Strike)\n",
                  SH_ModelIsDoD(cs) ? "DoD" : (SH_ModelIsSven(cs) ? "Sven" : "Counter-Strike")));
};

void() SH_HLAnimReport =
{
    if (sh_hlanim_reported)
        return;
    // getmodelindex, not a captured precache handle: precache_model returns the
    // NAME in this tree (Hitbox_RegisterModel takes a string for the same
    // reason), and getmodelindex is the builtin that turns one into an index -
    // it is what Hitbox_RegisterModel itself uses, in both VMs.
    float mdl = getmodelindex("models/player/chickenman/chickenman.iqm");
    if (mdl <= 0)
        return;                 // model not loaded yet; try again next tick
    sh_hlanim_reported = TRUE;

    float fam, crouch, found = 0, total = 0;
    string missing = "";
    for (fam = PANIM_HL_CROWBAR; fam <= PANIM_HL_M203; fam = fam + 1)
    {
        string suf = SH_HLAnimSuffix(fam);
        if (suf == "")
            continue;
        for (crouch = 0; crouch <= 1; crouch = crouch + 1)
        {
            // Aim AND shoot AND reload, standing AND crouched - the whole
            // surface the game actually asks for.  This used to check the aim
            // pose only, and that is exactly how the akimbo UZIs shipped
            // firing the Counter-Strike MP5 pose: `ref_aim_uzis` exists, but
            // Sven animates the pair per hand and `ref_shoot_uzis` does not,
            // so the one verb that was never measured was the one that broke.
            total = total + 3;

            // Through SH_HLFrame, not a bare frameforname, so the audit
            // measures what the game will actually resolve - including the
            // hold / m16 / per-hand substitutions above.  A check narrower
            // than the real lookup reports failures the game does not have.
            if (SH_HLFrame(mdl, fam, crouch, "aim") >= 0)
                found = found + 1;
            else
                missing = strcat(missing, " ", suf, crouch ? ":crouch-aim" : ":aim");

            if (SH_HLFrame(mdl, fam, crouch, "shoot") >= 0)
                found = found + 1;
            else
                missing = strcat(missing, " ", suf, crouch ? ":crouch-shoot" : ":shoot");

            // Most of the Half-Life set has no reload at all - crowbar,
            // wrench, gren, squeak, trip, gauss, egon, minigun, hive - and
            // SH_GetReloadAnim deliberately substitutes the aim pose there.
            // So a pass here is "stays on a Half-Life sequence", not "has its
            // own reload"; scoring it any stricter would report 9 permanent
            // failures that are not failures.
            if (SH_HLFrame(mdl, fam, crouch, "reload") >= 0
             || SH_HLFrame(mdl, fam, crouch, "aim") >= 0)
                found = found + 1;
            else
                missing = strcat(missing, " ", suf, crouch ? ":crouch-reload" : ":reload");
        }
    }

    print(sprintf("[panim] Half-Life poses on the player model: %g/%g resolved%s\n",
                  found, total,
                  (found == total) ? "" : strcat(" — MISSING:", missing)));

    // Which of the two animation paths this model lands on, and the three
    // probes SH_ModelIsSven asks.  Reported because getting it wrong is silent
    // and total: a CS-shaped model sent down the Sven path finds no sequence
    // by name, and a Sven-shaped model left on the Counter-Strike path indexes
    // into a list that is not its own - all 97 CSANIM_* constants land on
    // unrelated animations.  One line here turns either into something a log
    // can answer.
    print(sprintf("[panim] %s is %s-shaped (ref_aim_carbine=%g _blend05=%g ref_hold_wrench=%g)\n",
                  "chickenman",
                  SH_ModelIsSven(mdl) ? "Sven" : "Counter-Strike",
                  frameforname(mdl, "ref_aim_carbine"),
                  frameforname(mdl, "ref_aim_carbine_blend05"),
                  frameforname(mdl, "ref_hold_wrench")));
};

// --- Animation sequence lookup by weapon family + crouch state ---
// These take a modelindex for frameforname-based models (sini, and now every
// rebuilt player model for the HL families).
// For CS families on CS models, modelindex is ignored (hardcoded CSANIM_*).

// Is this model animated the Sven Co-op way rather than the Counter-Strike way?
//
// This matters because the CSANIM_* constants are INDICES into the
// Counter-Strike sequence list, and on a Sven-shaped model those indices land
// on unrelated animations.  Measured against th_civpaul.mdl: ALL 97 of them
// miss.  CSANIM_IDLE plays `look_idle`, CSANIM_RUN plays `walk2handed`,
// CSANIM_AIM_RIFLE plays `ref_cock_gren`, CSANIM_DEATH1 plays
// `ref_shoot_squeak`.  That is not hypothetical: th_escape hands every player
// one of sixteen Sven models (sv_mapscript_thescape.qc:736), and
// player_model_override lets a map script pin any other.
//
// The complete name-based path for such a model already existed - it was
// written for sini and gated on one hardcoded player_model_index.  Gate it on
// the MODEL instead and every Sven-shaped model gets it.
//
// Positive test for BOTH shapes, defaulting to the Counter-Strike path:
//   ref_aim_carbine / _blend05  exists only on CS-derived models (the rebuilt
//                               IQMs carry it under the source SMD's filename)
//   ref_hold_wrench             exists on anything carrying the Sven set
// A model matching NEITHER - a stock Half-Life player model, an unknown custom
// one - keeps the old behaviour rather than being sent down a path whose
// sequences it certainly does not have.  Verified across 151 models on disk:
// 11 rebuilt IQMs, 15 CS .mdl, sini, 101 Sven, 9 stock cstrike, 14 stock HL -
// zero misroutes either way.
// Cached per entity: this is asked several times per player per frame, and
// frameforname walks the model's sequence names.  Recomputed only when the
// modelindex changes, which is exactly when the answer can change.
.float pm_anim_shape;      // 0 = not yet known, 1 = CS-shaped, 2 = Sven-shaped
.float pm_anim_shape_mdl;  // the modelindex pm_anim_shape was computed for

float(float mdlidx) SH_UseSvenAnims =
{
    if (mdlidx <= 0)
        return FALSE;
    if (self.pm_anim_shape_mdl != mdlidx || !self.pm_anim_shape)
    {
        self.pm_anim_shape_mdl = mdlidx;
        self.pm_anim_shape = SH_ModelIsSven(mdlidx) ? 2 : 1;
    }
    return (self.pm_anim_shape == 2);
};

float(float mdlidx, float family, float crouching) SH_GetAimAnim =
{
    if (SH_UseSvenAnims(mdlidx))
        return Sini_GetAimAnim(mdlidx, family, crouching);

    float hl = SH_HLFrame(mdlidx, family, crouching, "aim");
    if (hl >= 0)
        return hl;
    family = SH_HLAnimFallback(family);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_AIM_ONEHAND  : CSANIM_AIM_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_AIM_CARBINE  : CSANIM_AIM_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_AIM_RIFLE    : CSANIM_AIM_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_AIM_MP5      : CSANIM_AIM_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_AIM_SHOTGUN  : CSANIM_AIM_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_AIM_PARA     : CSANIM_AIM_PARA;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_AIM_KNIFE    : CSANIM_AIM_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_AIM_GRENADE  : CSANIM_AIM_GRENADE;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_AIM_AK47     : CSANIM_AIM_AK47;
    case PANIM_DUALPISTOLS: return crouching ? CSANIM_CROUCH_AIM_DUALPISTOLS : CSANIM_AIM_DUALPISTOLS;
    case PANIM_C4:       return crouching ? CSANIM_CROUCH_AIM_C4       : CSANIM_AIM_C4;
    case PANIM_SHIELDGUN:   return crouching ? CSANIM_CROUCH_AIM_SHIELDGUN   : CSANIM_AIM_SHIELDGUN;
    case PANIM_SHIELDKNIFE: return crouching ? CSANIM_CROUCH_AIM_SHIELDKNIFE : CSANIM_AIM_SHIELDKNIFE;
    case PANIM_SHIELDGREN:  return crouching ? CSANIM_CROUCH_AIM_SHIELDGREN  : CSANIM_AIM_SHIELDGREN;
    case PANIM_SHIELDED:    return crouching ? CSANIM_CROUCH_AIM_SHIELDED    : CSANIM_AIM_SHIELDED;
    default:             return crouching ? CSANIM_CROUCH_AIM_ONEHAND  : CSANIM_AIM_ONEHAND;
    }
};

float(float mdlidx, float family, float crouching) SH_GetShootAnim =
{
    if (SH_UseSvenAnims(mdlidx))
        return Sini_GetShootAnim(mdlidx, family, crouching);

    float hl = SH_HLFrame(mdlidx, family, crouching, "shoot");
    if (hl >= 0)
        return hl;
    family = SH_HLAnimFallback(family);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_SHOOT_ONEHAND  : CSANIM_SHOOT_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_SHOOT_CARBINE  : CSANIM_SHOOT_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_SHOOT_RIFLE    : CSANIM_SHOOT_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_SHOOT_MP5      : CSANIM_SHOOT_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_SHOOT_SHOTGUN  : CSANIM_SHOOT_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_SHOOT_PARA     : CSANIM_SHOOT_PARA;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_SHOOT_KNIFE    : CSANIM_SHOOT_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_SHOOT_GRENADE  : CSANIM_SHOOT_GRENADE;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_SHOOT_AK47     : CSANIM_SHOOT_AK47;
    // The dual pistols alternate hands, and the model has a take for each:
    // SHOOT fires the right, SHOOT2 the left.  Alternate on the weapon's own
    // fire counter so the pose matches which barrel actually went off - both
    // sh_wpn_cselite.qc and sh_wpn_cfddeagle.qc drive their viewmodel the same
    // way, off a parity bit.
    case PANIM_DUALPISTOLS:
        if (self.wep_action_id & 1)
            return crouching ? CSANIM_CROUCH_SHOOT2_DUALPISTOLS : CSANIM_SHOOT2_DUALPISTOLS;
        return crouching ? CSANIM_CROUCH_SHOOT_DUALPISTOLS : CSANIM_SHOOT_DUALPISTOLS;
    case PANIM_C4:       return crouching ? CSANIM_CROUCH_SHOOT_C4       : CSANIM_SHOOT_C4;
    case PANIM_SHIELDGUN:   return crouching ? CSANIM_CROUCH_SHOOT_SHIELDGUN   : CSANIM_SHOOT_SHIELDGUN;
    case PANIM_SHIELDKNIFE: return crouching ? CSANIM_CROUCH_SHOOT_SHIELDKNIFE : CSANIM_SHOOT_SHIELDKNIFE;
    case PANIM_SHIELDGREN:  return crouching ? CSANIM_CROUCH_SHOOT_SHIELDGREN  : CSANIM_SHOOT_SHIELDGREN;
    // A raised shield cannot fire, so there is no shoot pose to reach for and
    // none was authored — hold the shielded stance.
    case PANIM_SHIELDED:    return crouching ? CSANIM_CROUCH_AIM_SHIELDED      : CSANIM_AIM_SHIELDED;
    default:             return crouching ? CSANIM_CROUCH_SHOOT_ONEHAND  : CSANIM_SHOOT_ONEHAND;
    }
};

float(float mdlidx, float family, float crouching) SH_GetReloadAnim =
{
    if (SH_UseSvenAnims(mdlidx))
        return Sini_GetReloadAnim(mdlidx, family, crouching);

    // Reload first, then AIM as the substitute.  Several Sven families have no
    // reload at all - crowbar, wrench, gren, squeak, trip - and asking for a
    // sequence that does not exist would drop straight through to the CS table
    // and swap the weapon's whole pose mid-reload.  Holding the HL aim pose
    // keeps the right gun in the right hands.
    float hl = SH_HLFrame(mdlidx, family, crouching, "reload");
    if (hl < 0)
        hl = SH_HLFrame(mdlidx, family, crouching, "aim");
    if (hl >= 0)
        return hl;
    family = SH_HLAnimFallback(family);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_RELOAD_ONEHAND : CSANIM_RELOAD_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_RELOAD_CARBINE : CSANIM_RELOAD_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_RELOAD_RIFLE   : CSANIM_RELOAD_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_RELOAD_MP5     : CSANIM_RELOAD_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_RELOAD_SHOTGUN : CSANIM_RELOAD_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_RELOAD_PARA    : CSANIM_RELOAD_PARA;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_RELOAD_AK47    : CSANIM_RELOAD_AK47;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_AIM_KNIFE      : CSANIM_AIM_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_AIM_GRENADE    : CSANIM_AIM_GRENADE;
    case PANIM_DUALPISTOLS: return crouching ? CSANIM_CROUCH_RELOAD_DUALPISTOLS : CSANIM_RELOAD_DUALPISTOLS;
    case PANIM_C4:       return crouching ? CSANIM_CROUCH_AIM_C4         : CSANIM_RELOAD_C4;
    // Only the gun set has a shield reload; knife and grenade have nothing to
    // reload, and the raised shield forbids it outright.
    case PANIM_SHIELDGUN:   return crouching ? CSANIM_CROUCH_RELOAD_SHIELDGUN  : CSANIM_RELOAD_SHIELDGUN;
    case PANIM_SHIELDKNIFE: return crouching ? CSANIM_CROUCH_AIM_SHIELDKNIFE   : CSANIM_AIM_SHIELDKNIFE;
    case PANIM_SHIELDGREN:  return crouching ? CSANIM_CROUCH_AIM_SHIELDGREN    : CSANIM_AIM_SHIELDGREN;
    case PANIM_SHIELDED:    return crouching ? CSANIM_CROUCH_AIM_SHIELDED      : CSANIM_AIM_SHIELDED;
    default:             return crouching ? CSANIM_CROUCH_RELOAD_ONEHAND : CSANIM_RELOAD_ONEHAND;
    }
};

// Per-player animation state (custom fields, no engine shadows).
.float anim_top;
.float anim_top_time;
.float anim_top_delay;
.float anim_top_gen;     // increments each PlayTop call — client detects re-fires
// Playback speed multiplier for the torso layer, 1 = the sequence's own rate.
// Set by SH_PlayerAnim_PlayTop when a body animation is longer than the weapon
// action it represents; replicated to the client in the VP_SF_ANIM section so
// the drawn model and the server's hitbox pose advance at the same speed.
.float anim_top_rate;
.float anim_bottom;
.float anim_bottom_time;

// Wall-clock timestamps when the current anim layer last (re-)started.
// Server computes baseframe1time / idle-frame1time as (time - *_start) so
// both layers track real wall time exactly — no accumulator drift vs
// the client's cltime-based visual model.
.float anim_top_start;
.float anim_bottom_start;

// ============================================================
//  SERVER ONLY
// ============================================================
// ============================================================

#ifdef SSQC

// Pick a random death animation and set it as the full-body frame.
// Pick a death animation based on the last hitgroup that killed the player.
// Falls back to random generic death if no hitgroup info available.
// .death_hitgroup should be set by the damage system before calling this.
.float death_hitgroup;

void() SH_PlayerAnim_Death =
{
    float mdlidx = 0;
    if (self.player_visual_proxy)
        mdlidx = self.player_visual_proxy.modelindex;

    float deathframe;
#ifdef SSQC
    float gm = cvar("sv_gamemode");
#else
    float gm = getstatf(STAT_GAMEMODE);
#endif
    if (gm == GAMEMODE_PAINTGUN)
    {
        // Paintgun mode plays one fixed "tag-out" animation across
        // every kill so the visual reads as a clean elimination.
        // Skip the hitgroup / crouch / model-specific branches.
        deathframe = CSANIM_DEATH2;
    }
    else if (SH_UseSvenAnims(mdlidx))
    {
        deathframe = Sini_GetRandomDeathAnim(mdlidx);
    }
    else
    {
        float crouching = (self.flags & FL_DUCKING) != 0;
        if (crouching)
        {
            deathframe = CSANIM_CROUCH_DIE;
        }
        else if (self.death_hitgroup == HITGROUP_HEAD)
        {
            deathframe = CSANIM_DIE_HEAD;
        }
        else if (self.death_hitgroup == HITGROUP_STOMACH)
        {
            deathframe = CSANIM_DIE_GUT;
        }
        else
        {
            // Generic random death for chest/limbs/fall/unknown
            float r = floor(random() * 6);
            if (r == 0)      deathframe = CSANIM_DEATH1;
            else if (r == 1) deathframe = CSANIM_DEATH2;
            else if (r == 2) deathframe = CSANIM_DEATH3;
            else if (r == 3) deathframe = CSANIM_DIE_BACK;
            else if (r == 4) deathframe = CSANIM_DIE_FORWARD;
            else             deathframe = CSANIM_DIE_LEFT;
        }
    }
    self.frame = deathframe;
    self.baseframe = deathframe;
};

// Trigger a one-shot upper-body animation (fire, reload, draw).
// Holds anim_top at the given sequence for `duration` seconds,
// then reverts to the weapon's aim pose.
//
// `mdlidx` is the visual proxy's model, used to measure the sequence; pass 0 if
// it isn't known and the timing rules below simply do not engage.
// `holddur` is how long the ACTION lasts (a refire period, a reload); 0 means
// unknown.
void(float mdlidx, float anim, float duration, float holddur) SH_PlayerAnim_PlayTop =
{
    float seqdur = (mdlidx > 0) ? frameduration(mdlidx, anim) : 0;

    // ALREADY RUNNING THIS SEQUENCE AND NOT FINISHED?  LET IT FINISH.
    //
    // PlayTop is called once per SHOT (sv_weapons.qc watches wep_action_id), so
    // a weapon that fires faster than its own body animation restarted the
    // sequence from frame 0 on every round: the SAW at 0.075 s against a
    // ref_shoot_saw of 5 frames at 24 fps is thirteen restarts a second, and
    // the minigun at 0.05 s is twenty.  The torso never got past its first
    // frame or two, and
    // each restart also bumped anim_top_gen, which is the client's cue to zero
    // vis_anim_top_time AND begin a fresh inter-sequence blend — a blend that
    // could not possibly complete before the next one replaced it.  The pose
    // being played was right all along; the retriggering was shredding it.
    // That is the "weird firing animation" on the SAW.
    if (anim == self.anim_top && self.anim_top_start > 0 && seqdur > 0
        && (time - self.anim_top_start) < seqdur)
    {
        // Extend the hold so the pose is not dropped mid-burst, but do NOT
        // touch the generation counter — that is what restarts it.
        if (duration > self.anim_top_delay)
            self.anim_top_delay = duration;
        return;
    }

    self.anim_top       = anim;
    self.anim_top_time  = 0;
    self.anim_top_delay = duration;
    self.anim_top_gen   = (self.anim_top_gen + 1) & 255; // wrapping byte counter
    self.anim_top_start = time;                          // wall-clock anchor

    // PLAYBACK RATE.  The body animation and the weapon's action are authored
    // independently and routinely disagree by a lot: Sven's ref_reload_saw runs
    // 211 frames at 30 fps (7.0 s) while this mod's M249 reloads in 1.5 s (top
    // up) or 2.44 s (dry belt).  Played at 1x the model leans a third of the way
    // into the drill and then snaps back to the aim pose when the gun finishes —
    // the "slides forward and jumps back" report.
    //
    // Only ever speeds an animation UP, and only when the action is the shorter
    // of the two, so a weapon whose animation already fits is left exactly as it
    // was.  Capped at 4x: past that it reads as a glitch rather than a fast
    // reload, and a partial animation is the lesser evil.
    self.anim_top_rate = 1;
    if (seqdur > 0 && holddur > 0 && seqdur > holddur)
        self.anim_top_rate = min(seqdur / holddur, 4);
};

.float player_spine_skel_modelindex;
.float player_spine_debug_next;

const float PLAYER_SPINE_PI_RAD = 3.14159265358979;

float(float f) SH_PlayerAnim_FloatGood =
{
    return (fabs(f) < 100000);
};

float(vector v) SH_PlayerAnim_VectorGood =
{
    return (SH_PlayerAnim_FloatGood(v_x)
         && SH_PlayerAnim_FloatGood(v_y)
         && SH_PlayerAnim_FloatGood(v_z));
};

float(float skel, float bone_idx) SH_PlayerAnim_LoadBoneBasis =
{
    if (bone_idx <= 0 || skel == 0)
        return FALSE;

    skel_get_bonerel(skel, bone_idx);

    if (!SH_PlayerAnim_VectorGood(v_forward)
        || !SH_PlayerAnim_VectorGood(v_right)
        || !SH_PlayerAnim_VectorGood(v_up)
        || vlen(v_forward) < 0.001
        || vlen(v_right) < 0.001
        || vlen(v_up) < 0.001)
        return FALSE;

    vector old_f = v_forward;
    vector old_r = v_right;
    vector old_u = v_up;
    vector lf = normalize(old_f);
    vector lu = old_u - lf * (old_u * lf);
    if (vlen(lu) < 0.001)
        lu = crossproduct(old_r, lf);
    if (vlen(lu) < 0.001)
        return FALSE;
    lu = normalize(lu);
    vector lr = crossproduct(lf, lu);
    if (vlen(lr) < 0.001)
        return FALSE;
    lr = normalize(lr);
    if (lr * old_r < 0)
    {
        lr = -lr;
        lu = -lu;
    }

    v_forward = lf;
    v_right   = lr;
    v_up      = lu;
    return TRUE;
};

void(float skel) SH_PlayerAnim_OrthonormalizeSkeleton =
{
    float n = skel_get_numbones(skel);
    float i;
    for (i = 1; i <= n; i++)
    {
        vector bone_org = skel_get_bonerel(skel, i);
        if (!SH_PlayerAnim_VectorGood(bone_org))
            bone_org = '0 0 0';
        if (SH_PlayerAnim_LoadBoneBasis(skel, i))
            skel_set_bone(skel, i, bone_org, v_forward, v_right, v_up);
        else
            skel_set_bone(skel, i, bone_org, '1 0 0', '0 1 0', '0 0 1');
    }
};

void(float skel) SH_PlayerAnim_BuildPoseSkeleton =
{
    float splitbone = self.basebone;

    // Match the client-side IQM spine path: build the base/torso and
    // regular/leg ranges separately so the explicit skeleton keeps the
    // current frame2 lerps instead of freezing locomotion bones.
    if (splitbone > 1)
    {
        skel_build(skel, self, self.modelindex, 0, 1, splitbone);
        skel_build(skel, self, self.modelindex, 0, splitbone, 0);
    }
    else
    {
        skel_build(skel, self, self.modelindex, 0, 0, 0);
    }
};

float() SH_PlayerAnim_ModelIsIQM =
{
    float len = strlen(self.model);
    if (len < 4)
        return FALSE;
    return (substring(strtolower(self.model), len - 4, 4) == ".iqm");
};

void(float skel, float bone_idx, float deg) SH_PlayerAnim_TwistBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!SH_PlayerAnim_LoadBoneBasis(skel, bone_idx))
        return;

    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PLAYER_SPINE_PI_RAD / 180);
    float s = sin(deg * PLAYER_SPINE_PI_RAD / 180);
    skel_set_bone(skel, bone_idx, bone_org, lf, lr * c + lu * s, -lr * s + lu * c);
};

void(float skel, float bone_idx, float deg) SH_PlayerAnim_PitchBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!SH_PlayerAnim_LoadBoneBasis(skel, bone_idx))
        return;

    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PLAYER_SPINE_PI_RAD / 180);
    float s = sin(deg * PLAYER_SPINE_PI_RAD / 180);
    skel_set_bone(skel, bone_idx, bone_org, lf * c - lr * s, lf * s + lr * c, lu);
};

void(float leg_twist) SH_PlayerAnim_ApplyIQMSpine =
{
    if (!cvar("cl_player_spine_deform") || !self.modelindex || !SH_PlayerAnim_ModelIsIQM())
    {
        if (self.skeletonindex)
        {
            skel_delete(self.skeletonindex);
            self.skeletonindex = 0;
            self.player_spine_skel_modelindex = 0;
        }
        return;
    }

    float twist_scale = cvar("cl_player_spine_twist_scale");
    float pitch_scale = cvar("cl_player_spine_pitch_scale");
    if (twist_scale == 0 && pitch_scale == 0)
    {
        if (self.skeletonindex)
        {
            skel_delete(self.skeletonindex);
            self.skeletonindex = 0;
            self.player_spine_skel_modelindex = 0;
        }
        return;
    }

    if (self.skeletonindex && self.player_spine_skel_modelindex != self.modelindex)
    {
        skel_delete(self.skeletonindex);
        self.skeletonindex = 0;
        self.player_spine_skel_modelindex = 0;
    }

    if (!self.skeletonindex)
    {
        self.skeletonindex = skel_create(self.modelindex);
        self.player_spine_skel_modelindex = self.modelindex;
    }

    if (!self.skeletonindex)
        return;

    SH_PlayerAnim_BuildPoseSkeleton(self.skeletonindex);
    SH_PlayerAnim_OrthonormalizeSkeleton(self.skeletonindex);

    float iqm_twist = -leg_twist * twist_scale;
    float pitch_max = cvar("cl_player_spine_pitch_max");
    if (pitch_max <= 0)
        pitch_max = 35;
    float pitch_frac = bound(-1, self.v_angle_x / 90, 1);
    float iqm_pitch = bound(-pitch_max, pitch_frac * pitch_max * pitch_scale, pitch_max);

    float sb0 = skel_find_bone(self.skeletonindex, "Bip01 Spine");
    float sb1 = skel_find_bone(self.skeletonindex, "Bip01 Spine1");
    float sb2 = skel_find_bone(self.skeletonindex, "Bip01 Spine2");
    float sb3 = skel_find_bone(self.skeletonindex, "Bip01 Spine3");
    float sbn = skel_find_bone(self.skeletonindex, "Bip01 Neck");

    if (iqm_twist != 0)
    {
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb0, iqm_twist);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb1, iqm_twist * 0.5);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb2, iqm_twist * 0.25);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb3, iqm_twist * 0.125);
    }

    if (iqm_pitch != 0)
    {
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb0, iqm_pitch * 0.05);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb1, iqm_pitch * 0.15);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb2, iqm_pitch * 0.30);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb3, iqm_pitch * 0.35);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sbn, iqm_pitch * 0.15);
    }

    if (cvar("cl_player_spine_debug") && time >= self.player_spine_debug_next)
    {
        sprint(self, PRINT_HIGH, sprintf("[spine sv] model='%s' skel=%g\n", self.model, self.skeletonindex));
        sprint(self, PRINT_HIGH, sprintf("           bones=%g/%g/%g/%g/%g\n", sb0, sb1, sb2, sb3, sbn));
        sprint(self, PRINT_HIGH, sprintf("           leg=%.1f twist=%.1f pitch=%.1f max=%.1f\n", leg_twist, iqm_twist, iqm_pitch, pitch_max));
        self.player_spine_debug_next = time + 0.5;
    }
};

void() SH_PlayerAnim_ClearIQMSpine =
{
    if (self.skeletonindex && self.player_spine_skel_modelindex)
    {
        skel_delete(self.skeletonindex);
        self.skeletonindex = 0;
        self.player_spine_skel_modelindex = 0;
    }
};

void() SH_PlayerAnim_Update =
{
    float speed;
    float crouching;
    float onground;
    float family;

    if (self.health <= 0)
        return;

    // Get the visual proxy's modelindex for frameforname lookups
    float mdlidx = 0;
    if (self.player_visual_proxy)
        mdlidx = self.player_visual_proxy.modelindex;

    speed     = vlen(self.velocity);
    crouching = (self.flags & FL_DUCKING) != 0;
    onground  = (self.flags & FL_ONGROUND) != 0;

    // func_vehicle: a seated driver carries the car's velocity (so a dismount
    // inherits its momentum) but isn't actually running — present them as
    // stationary & grounded so the legs play idle instead of run/jump.  The
    // velocity-driven leg-twist below is also gated off (see speed2d use).
    if (self.pm_driving)
    {
        speed    = 0;
        onground = TRUE;
    }

    // Tick timers
    self.anim_top_time  += frametime;
    self.anim_top_delay -= frametime;

    // Upper body.  WEAPON STATE FIRST, hold timer second.
    //
    // The old order asked the timer first, so a pair of constants in
    // sv_weapons.qc decided the pose instead of the weapon: 0.3 s of shoot and
    // 3.0 s of reload for everything.  Both ends of that are wrong.  A 1.5 s
    // reload left the body still loading for a second and a half after the gun
    // was ready; a reload longer than three seconds snapped the body back to
    // the aim pose while the gun was visibly still working.  Reading the state
    // means the third person shows exactly what the weapon is doing, for
    // exactly as long as it is doing it, on every weapon at once.
    //
    // The 15 s cap is a backstop, not a policy: a weapon left stuck in
    // WS_RELOAD by some other bug should not pin the body's pose forever.
    // If crouching changed mid-action, this also swaps to the correct variant.
    family = W_GetPlayerAnimFamily(self.weapon);
    float state_held = (self.wep_anim_start > 0 && (time - self.wep_anim_start) < 15);
    if (self.weaponstate == WS_FIRE && state_held)
        self.anim_top = SH_GetShootAnim(mdlidx, family, crouching);
    else if (self.weaponstate == WS_RELOAD && state_held)
        self.anim_top = SH_GetReloadAnim(mdlidx, family, crouching);
    else if (self.anim_top_delay <= 0)
    {
        self.anim_top = SH_GetAimAnim(mdlidx, family, crouching);
        // Back at rest: drop any compression the last action asked for.  Aim
        // poses loop and have no action length to be fitted to, and clearing it
        // here bounds a stale rate to the single action that set it — which
        // matters for the weapons on bespoke gates, whose reloads reach the
        // branch above without ever going through PlayTop.
        self.anim_top_rate = 1;
    }
    // else: the weapon state has already retired but PlayTop's minimum hold has
    // not expired — keep the pose, so a weapon whose WS_FIRE is shorter than one
    // animation still shows a complete recoil rather than a single frame of it.

    // Lower body: locomotion
    if (SH_UseSvenAnims(mdlidx))
    {
        // Sven-shaped model (sini, the They Hunger cast): look up by name
        if (!onground)
            self.anim_bottom = Sini_GetJumpAnim(mdlidx);
        else if (speed < 1)
            self.anim_bottom = crouching ? Sini_GetCrouchIdleAnim(mdlidx) : Sini_GetIdleAnim(mdlidx);
        else
            self.anim_bottom = crouching ? Sini_GetCrouchRunAnim(mdlidx) : Sini_GetRunAnim(mdlidx);
    }
    else
    {
        // CS models: hardcoded indices
        if (!onground)
            self.anim_bottom = CSANIM_JUMP;
        else if (speed < 1)
            // Standing/crouching idle: use single-frame static leg
            // sequences instead of CSANIM_IDLE / CSANIM_IDLE_CROUCH.
            // The stock CSANIM_IDLE* are full-body anims whose leg
            // keyframes contain root-translation IK that the basebone
            // split severs (root is in torso group), causing the legs
            // to counter-rotate against translation that no longer
            // happens — the "feet drift / swim" symptom. The static
            // variants are one frozen leg pose, no root motion, no IK.
            self.anim_bottom = crouching ? CSANIM_LEGS_CROUCH_STATIC : CSANIM_LEGS_IDLE_STATIC;
        else
            self.anim_bottom = crouching ? CSANIM_RUN_CROUCH : CSANIM_RUN;
    }

    // Body faces aim direction (set BEFORE leg twist computation).
    self.angles_y = self.v_angle_y;
    self.angles_x = 0;
    self.angles_z = 0;

    // --- Strafe body twist + backpedal detection ---
    // Computed BEFORE animation timer so locomotion can use backpedaling flag.
    // Mirrors CSQC cl_player.qc's hysteresis exactly (cl_player_backpedal_*_angle
    // cvars + .sv_backpedaling latch) so hitboxes flip at the same instant the
    // visual model does.  Without this, the server used a hardcoded ±95° flip
    // while the client had wider hysteresis, so hitboxes desynced from visuals
    // during small mouse corrections near 90°.
    vector vel2d = self.velocity;
    vel2d_z = 0;
    float speed2d = vlen(vel2d);
    float leg_twist = 0;
    float backpedaling = FALSE;

    float bp_enter = cvar("cl_player_backpedal_enter_angle");
    float bp_exit  = cvar("cl_player_backpedal_exit_angle");
    if (bp_enter <= 0) bp_enter = 150;
    if (bp_exit  <= 0) bp_exit  = 100;
    bp_enter = bound(91, bp_enter, 179);
    bp_exit  = bound(1, bp_exit, bp_enter - 1);

    if (speed2d > 10 && !self.pm_driving)
    {
        float vel_yaw = vectoyaw(vel2d);
        float yaw_diff = vel_yaw - self.v_angle_y;
        // Normalize to -180..180
        yaw_diff -= floor((yaw_diff + 180) / 360) * 360;

        // Hysteresis: enter backpedal late, leave it earlier — keeps pure
        // strafing stable while the player makes small aim corrections.
        float abs_yaw = fabs(yaw_diff);
        if (self.sv_backpedaling)
        {
            if (abs_yaw < bp_exit)
                self.sv_backpedaling = FALSE;
        }
        else if (abs_yaw > bp_enter)
            self.sv_backpedaling = TRUE;

        if (self.sv_backpedaling)
        {
            backpedaling = TRUE;
            // Mirror angle so legs face opposite dir
            if (yaw_diff > 0)
                yaw_diff = yaw_diff - 180;
            else
                yaw_diff = yaw_diff + 180;
        }

        float speed_frac = bound(0, speed2d / 250, 1);
        leg_twist = yaw_diff * speed_frac;
    }
    else
        self.sv_backpedaling = FALSE;

    // Rotate whole model toward movement (legs face walk direction)
    self.angles_y += leg_twist;

    // Counter-rotate upper body back to aim direction
    self.subblendfrac = bound(-1, leg_twist / 90, 1);
    self.subblend2frac = self.v_angle_x / 90;

    // --- Frame writes ---
    // FTE basebone rule: bones < basebone → .baseframe, bones >= basebone → .frame

    // Lower body (legs): detect anim change → stamp wall-clock start.
    if (self.anim_bottom != self.frame)
    {
        self.frame2 = self.frame;
        self.frame2time = self.frame1time;
        self.frame = self.anim_bottom;
        self.frame1time = 0;
        self.anim_bottom_start = time;
    }
    self.lerpfrac = 1;

    // Upper body (torso/aim): anim change updates lerp target and, if this
    // was a transition NOT caused by PlayTop (e.g. delay expired back to
    // aim pose), stamp the wall-clock anchor ourselves.
    if (self.anim_top != self.baseframe)
    {
        self.baseframe2 = self.baseframe;
        self.baseframe2time = self.baseframe1time;
        self.baseframe = self.anim_top;
        // Guard: PlayTop already stamped anim_top_start at trigger time;
        // only overwrite for transitions that bypass PlayTop (e.g. idle
        // aim restoration, crouch variant swap).
        if (self.anim_top_delay <= 0)
            self.anim_top_start = time;
    }
    // Wall-clock driven — matches CSQC's cltime-based vis_anim_top_time
    // exactly, so no drift between server hitbox and client visual model.
    // Scaled by anim_top_rate for the same reason the client scales its copy:
    // a body animation longer than the action it stands for is compressed to
    // fit rather than cut off part-way (see SH_PlayerAnim_PlayTop).
    if (self.anim_top_rate <= 0)
        self.anim_top_rate = 1;
    self.baseframe1time = (time - self.anim_top_start) * self.anim_top_rate;
    self.baselerpfrac = 1;

    // --- Locomotion timer: distance-based (matches CSQC for hitbox sync) ---
    // For RUN/CROUCH_RUN, advance frame1time by horizontal distance traveled
    // so feet sync to ground speed. For idle/jump, use plain time.
    float is_locomotion = (self.anim_bottom == CSANIM_RUN
                        || self.anim_bottom == CSANIM_RUN_CROUCH);

    if (is_locomotion && speed2d > 1)
    {
        // Crouch uses its own qu_per_sec since crouch movement is slower.
        // See cl_player.qc for the matching CSQC-side branch.
        float qu_per_sec;
        if (self.anim_bottom == CSANIM_RUN_CROUCH)
        {
#ifdef SSQC
            // Cached once per tick in sv_main.qc StartFrame.
            qu_per_sec = sv_cached_anim_qu_per_sec_crouch;
#else
            qu_per_sec = cvar("sv_anim_qu_per_sec_crouch");
            if (qu_per_sec <= 0) qu_per_sec = 100;
#endif
        }
        else
        {
#ifdef SSQC
            qu_per_sec = sv_cached_anim_qu_per_sec;
#else
            qu_per_sec = cvar("sv_anim_qu_per_sec");
            if (qu_per_sec <= 0) qu_per_sec = 240;
#endif
        }

        vector delta = self.origin - self.pm_anim_prev_origin;
        delta_z = 0;
        makevectors([0, self.angles_y, 0]);

        float dist_fwd = delta * v_forward;
        if (backpedaling)
            dist_fwd = -fabs(dist_fwd);

        self.frame1time += dist_fwd / qu_per_sec;
    }
    else
    {
        // Wall-clock driven for idle/jump so the server hitbox leg timing
        // matches the CSQC visual model exactly (no usercmd-duration drift).
        // Backpedal case keeps the legacy negative-time trick (wrap below).
        if (backpedaling)
            self.frame1time = -(time - self.anim_bottom_start);
        else
            self.frame1time = time - self.anim_bottom_start;
    }
    self.pm_anim_prev_origin = self.origin;

    // Wrap negative time so engine doesn't choke (matches valve/CSQC hack)
    if (self.frame1time < 0)
        self.frame1time = 10.0;

    float bb = cvar("sv_player_basebone");
    if (bb <= 0)
    {
        // Where the legs start, asked of the MODEL rather than of a hardcoded
        // player_model_index.  Counter-Strike skeletons spell the thigh
        // "Bip01 L Thigh"; Sven/Half-Life ones spell it "Bip01 L Leg" - the
        // same rename mdl_anim_to_smd.py undoes when it retargets animation.
        // Probing in that order costs one extra gettagindex on Sven models and
        // makes every Sven-shaped model split its body correctly, not just the
        // one that used to be index 5.
        bb = gettagindex(self, "Bip01 L Thigh");
        if (bb <= 0)
            bb = gettagindex(self, "Bip01 L Leg");
    }
    self.basebone = bb;

    // Progressive spine twist from lateral velocity
    makevectors([0, self.angles_y, 0]);
    float fCorrect = dotproduct(self.velocity, v_right) * 0.25;
    self.bonecontrol1 = fCorrect;
    self.bonecontrol2 = fCorrect * 0.5;
    self.bonecontrol3 = fCorrect * 0.25;
    self.bonecontrol4 = fCorrect * 0.125;

    // Keep the server entity on FTE's normal framestate path.  An
    // explicit IQM skeleton here is visible to MOVE_HITMODEL lagcomp
    // traces during firing, and the converted split-body poses can make
    // that path unstable while players are moving.  CSQC still applies
    // the visual spine deformation on the player_visual_proxy.
    SH_PlayerAnim_ClearIQMSpine();

    // Debug: verify blend values are being written (remove after testing)
    if (cvar("sv_debug_blendfracs"))
        dprint(sprintf("blend: sbf=%.3f sb2f=%.3f v_ang_x=%.1f bc1=%.3f bb=%g frame=%g bframe=%g\n",
            self.subblendfrac, self.subblend2frac, self.v_angle_x,
            self.bonecontrol1, self.basebone, self.frame, self.baseframe));
};

#endif // SSQC
