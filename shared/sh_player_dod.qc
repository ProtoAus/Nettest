// ============================================================
//  shared/sh_player_dod.qc  -  Day of Defeat player body animation
//
//  The THIRD model shape, alongside Counter-Strike (CSANIM_* indices) and Sven
//  (ref_<verb>_<suffix> names, sh_player_sini.qc).  Structural sibling of that
//  file; read it first, this one mirrors its shape deliberately.
//
//  Compiled by BOTH sv_progs and cl_progs — it sits immediately before
//  shared/sh_player_anims.qc in both .src lists, the same way sh_player_sini.qc
//  does.  Only SSQC calls the pose lookups today (SH_PlayerAnim_Update and
//  server/sv_weapons.qc drive them), but CSQC needs the death and locomotion
//  tables for the index sites it computes locally.
// ============================================================
//
//  NAME SHAPE — <stance>_<token>_<verb>, which is the REVERSE token order of
//  Sven's `ref_<verb>_<suffix>`.  SH_HLFrame builds `pre + verb + "_" + suf`
//  (sh_player_anims.qc) and therefore cannot be reused here; this imitates it
//  rather than extending it.
//
//      stand_rifle_aim      112      crouch_rifle_aim      113
//      stand_rifle_shoot     30      crouch_rifle_shoot     31
//      stand_garand_reload  239      crouch_garand_reload  266
//
//  MEASURED off dod/models/player/us-inf/us-inf.mdl — 345 sequences, 34 bones,
//  ZERO bone controllers.  All five DoD player models carry a byte-identical
//  345-name list in identical order (verified by diffing the sorted name dumps
//  of all five), so ONE table serves every model and no per-nation gap exists.
//  Their bone arrays do NOT match — 34/34/34/35/32 — but `Bip01 Spine` is bone 8
//  on all five, which is the only bone index this feature depends on.
//
//  THE AIM TOKEN AND THE RELOAD TOKEN ARE DIFFERENT SETS, and that is the whole
//  reason this file keys on the WEAPON and not on the animation family:
//
//      aim/shoot tokens (20): 30cal bazooka bolt bren fcarb grease gren knife
//                             mg mills mp40 piat pistol pschreck rifle spade
//                             sten stg44 stick tommy
//      reload tokens    (18): bar bazooka bolt bren fcarb fg42 garand grease
//                             k43 m1carb mp40 piat pistol pschreck sten stg44
//                             tommy webley
//      reload-only (6): bar fg42 garand k43 m1carb webley
//      aim-only    (8): 30cal gren knife mg mills rifle spade stick
//
//  The Garand and the Gewehr 43 are both PANIM_RIFLE in the manifest, both aim
//  as `rifle`, and reload as `garand` and `k43` respectively.  No function of
//  the family alone can tell them apart, so the family is the FALLBACK and
//  self.weapon is the primary key — exactly the way SH_ShieldAnimFamily reads
//  self.has_shield rather than taking it as a parameter.  `self` is the player
//  at every call site (SH_PlayerAnim_Update sets self.angles_y from
//  self.v_angle_y; server/sv_weapons.qc's site is inside the player's own
//  weapon frame), so no signature changes and no call site moves.
//
//  DELIBERATELY NOT ~26 NEW PANIM_DOD_* FAMILIES.  The PANIM_ enum in
//  sh_weapons.qc and the WMF_PANIM_ enum in sh_weapon_manifest.qc must stay
//  numerically identical and NOTHING asserts that they do; and
//  SH_ShieldAnimFamily (sh_wpn_csshield.qc) ends `return PANIM_SHIELDGUN;` for
//  everything it does not name, so a family it had never heard of would route
//  every DoD long arm to the pistol shield pose.  Two silent failure modes
//  bought for nothing: the tokens below are per-weapon data, not a new taxonomy.
//
//  WHAT DoD DOES NOT HAVE, and what this file does about it:
//    * no `mortar` take at all — the mortar aims as `piat` (DoD's own dll makes
//      the same substitution) and has no reload of its own.
//    * no standing or crouched reload for the three belt-fed MGs (30cal, mg34,
//      mg42): those exist only in the bipod_/sandbag_ stances.  They fall back
//      to the aim pose, which is what SH_GetReloadAnim already does for the nine
//      Half-Life families that have no reload.
//    * no `rifle` reload — every rifle-shaped weapon reloads under its own name.
//    * `crouch_reload_webley` is spelled BACKWARDS, and is the only inverted
//      name in all 345.  Handled in DoD_StanceName, not by a special case at
//      every call.
//    * no bone controllers, so there is no torso counter-rotation to drive; the
//      caller zeroes leg_twist for this shape.

// Forward declarations — the three dispatchers live in sh_player_anims.qc, which
// compiles AFTER this file in both .src lists (it has to: its DoD arms call the
// functions below).  Only DoD_SelfTest needs them, and it needs the real
// dispatchers rather than the DoD_ ones underneath: the whole point of the test
// is to prove the ARM is wired, not that this file's own lookups work.
float(float mdlidx, float family, float crouching) SH_GetAimAnim;
float(float mdlidx, float family, float crouching) SH_GetShootAnim;
float(float mdlidx, float family, float crouching) SH_GetReloadAnim;

// ------------------------------------------------------------
//  Safe lookup
// ------------------------------------------------------------
//
// Returns -1 on a miss, NOT 1 the way Sini_Frame does.  That difference is
// load-bearing: sequence 1 on a DoD model is `dod_idle1`, a perfectly plausible
// standing pose, so a Sini-style fallback would turn every missing take into a
// silent, believable wrong answer.  The callers below decide what a miss means.
float(float mdlidx, string name) DoD_Frame =
{
    if (mdlidx <= 0)
        return -1;
    return frameforname(mdlidx, name);
};

// ------------------------------------------------------------
//  Stance prefix
// ------------------------------------------------------------
//
// Stand and crouch only.  Prone is NOT reachable: roughly 130 of the 345
// sequences are prone_ / bipod_ / sandbag_ / get_down / get_up, and this mod has
// no player prone state at all (MS_PRONE is a MONSTER state, used by the
// barnacle's grab).  The sandbag_ and bipod_ sets become reachable if
// .wep_deployed is ever wired in here, but note four of the eight deployables
// have a deployed reload and no deployed aim or shoot, and the world weapon
// model would need its own bipod-down variant to match — see the note in
// sh_weapon_manifest.qc about pmodel being one string per weapon.
string(float crouching) DoD_StancePrefix =
{
    return crouching ? "crouch_" : "stand_";
};

// The full sequence name.  ONE special case, and it is the model's own
// inconsistency rather than ours: the Webley's crouched reload is spelled
// `crouch_reload_webley` — verb and token transposed — and it is the only name
// in the whole 345 that does that.  Centralised here so no caller has to know.
string(float crouching, string token, string verb) DoD_SeqName =
{
    if (crouching && token == "webley" && verb == "reload")
        return "crouch_reload_webley";
    return strcat(DoD_StancePrefix(crouching), token, "_", verb);
};

// ------------------------------------------------------------
//  Weapon -> token
// ------------------------------------------------------------
//
// Sourced from Day of Defeat's OWN per-weapon table, which survives as adjacent
// string literals in dod/dlls/dod.dll (each entry is p_model, v_model, w_model,
// then the aim extension and the reload extension), and then checked against the
// sequence names actually present in us-inf.mdl.  Where the dll and the model
// disagree the MODEL wins — it is what frameforname will answer.
//
// TOTAL over the DoD weapons; anything else falls through to the family map
// below.  Both halves must be total or the failure is the one
// sh_player_sini.qc:51-55 records: a partial table silently answered
// "onehanded" for 26 weapons, i.e. every crowbar and RPG went back to being held
// like a pistol on that one model.
string(float wep) DoD_WeaponAimToken =
{
    switch (wep)
    {
    // --- bolt-action rifles -> bolt
    case WEP_DOD98K:        return "bolt";
    case WEP_DODSCOPED98K:  return "bolt";
    case WEP_DODSPRING:     return "bolt";
    case WEP_DODENFIELD:    return "bolt";
    case WEP_DODENFIELDS:   return "bolt";
    // The binoculars are `bolt` in DoD too — the dll reuses the Springfield's
    // p_model for them outright, which is why they share its pose.
    case WEP_DODBINOCS:     return "bolt";

    // --- semi-auto rifles -> rifle (they differ only in the RELOAD, below)
    case WEP_DODGARAND:     return "rifle";
    case WEP_DODCARBINE:    return "rifle";
    case WEP_DODK43:        return "rifle";
    case WEP_DODBAR:        return "rifle";
    case WEP_DODMP44:       return "stg44";
    case WEP_DODFCARB:      return "fcarb";

    // --- submachine guns
    case WEP_DODTOMMY:      return "tommy";
    case WEP_DODMP40:       return "mp40";
    case WEP_DODSTEN:       return "sten";
    case WEP_DODGREASE:     return "grease";
    // The FG42 is held like a Thompson in DoD and reloads under its own name.
    case WEP_DODFG42:       return "tommy";
    case WEP_DODFG42S:      return "tommy";

    // --- machine guns
    case WEP_DODBREN:       return "bren";
    case WEP_DOD30CAL:      return "30cal";
    case WEP_DODMG34:       return "mg";
    case WEP_DODMG42:       return "mg";

    // --- pistols
    case WEP_DODCOLT:       return "pistol";
    case WEP_DODLUGER:      return "pistol";
    case WEP_DODWEBLEY:     return "pistol";

    // --- anti-tank.  The MORTAR aims as `piat` — DoD's own table says so, and
    //     there is no `mortar` take anywhere in the 345 names.
    case WEP_DODBAZOOKA:    return "bazooka";
    case WEP_DODSCHRECK:    return "pschreck";
    case WEP_DODPIAT:       return "piat";
    case WEP_DODMORTAR:     return "piat";

    // --- melee.  The spade has its own aim/shoot and reloads as a knife.
    case WEP_DODAMERK:      return "knife";
    case WEP_DODFAIRBAIRN:  return "knife";
    case WEP_DODPARAKNIFE:  return "knife";
    case WEP_DODSPADE:      return "spade";

    // --- grenades
    case WEP_DODMILLS:      return "mills";
    case WEP_DODSTICK:      return "stick";

    default:                return "";      // not a DoD weapon — use the family
    }
};

// The reload token, which is a DIFFERENT set — see the header.  Only the
// weapons whose reload take is not their aim take need a row; everything else
// falls through to the aim token.
string(float wep) DoD_WeaponReloadToken =
{
    switch (wep)
    {
    case WEP_DODGARAND:   return "garand";
    case WEP_DODCARBINE:  return "m1carb";
    case WEP_DODK43:      return "k43";
    case WEP_DODBAR:      return "bar";
    case WEP_DODFG42:     return "fg42";
    case WEP_DODFG42S:    return "fg42";
    case WEP_DODWEBLEY:   return "webley";
    // The spade swings as a spade and stows as a knife.
    case WEP_DODSPADE:    return "knife";
    default:              return DoD_WeaponAimToken(wep);
    }
};

// ------------------------------------------------------------
//  Family -> token  (everything that is NOT a DoD weapon)
// ------------------------------------------------------------
//
// A DoD-shaped player holding an AK47, a crowbar or an RPG still has to stand
// somewhere.  This is the same job Sini_GetAnimSuffix does and it is total for
// the same reason — every PANIM_, Counter-Strike and Half-Life alike, mapped by
// SILHOUETTE: what reads third-person is whether the gun is one-handed, at the
// shoulder or braced, not its calibre.
string(float family) DoD_FamilyToken =
{
    switch (family)
    {
    // --- Counter-Strike families
    case PANIM_ONEHAND:     return "pistol";
    case PANIM_CARBINE:     return "fcarb";
    case PANIM_RIFLE:       return "rifle";
    case PANIM_MP5:         return "tommy";
    case PANIM_SHOTGUN:     return "bolt";   // pump-action reads closest to a bolt gun
    case PANIM_PARA:        return "bren";   // braced two-handed
    case PANIM_KNIFE:       return "knife";
    case PANIM_GRENADE:     return "gren";
    case PANIM_AK47:        return "stg44";  // the StG44 IS the ancestor
    case PANIM_DUALPISTOLS: return "pistol";
    case PANIM_C4:          return "gren";   // planted like a charge

    // --- Half-Life families
    case PANIM_HL_CROWBAR:  return "knife";
    case PANIM_HL_WRENCH:   return "spade";
    case PANIM_HL_PYTHON:   return "pistol";
    case PANIM_HL_HIVE:     return "pistol";
    case PANIM_HL_GAUSS:    return "rifle";
    case PANIM_HL_SNIPER:   return "bolt";
    case PANIM_HL_BOW:      return "bolt";
    case PANIM_HL_EGON:     return "bren";
    case PANIM_HL_RPG:      return "bazooka";
    case PANIM_HL_SAW:      return "bren";
    case PANIM_HL_MINIGUN:  return "30cal";
    case PANIM_HL_M16:      return "stg44";
    case PANIM_HL_M203:     return "stg44";
    case PANIM_HL_UZIS:     return "pistol";
    case PANIM_HL_SQUEAK:   return "gren";
    case PANIM_HL_TRIP:     return "gren";
    case PANIM_HL_GREN:     return "gren";

    // --- The tactical shield.  DoD has no shield pose of any kind, so these
    //     land on the closest carry: a raised shield is a one-handed sidearm in
    //     the other hand.  Named explicitly rather than left to the default so
    //     the four are visibly accounted for.
    case PANIM_SHIELDGUN:   return "pistol";
    case PANIM_SHIELDKNIFE: return "knife";
    case PANIM_SHIELDGREN:  return "gren";
    case PANIM_SHIELDED:    return "pistol";

    default:                return "rifle";
    }
};

// The one place the two keys are combined.  Weapon first, family second.
string(float wep, float family, float is_reload) DoD_Token =
{
    string t = is_reload ? DoD_WeaponReloadToken(wep) : DoD_WeaponAimToken(wep);
    if (t != "")
        return t;
    return DoD_FamilyToken(family);
};

// ------------------------------------------------------------
//  Pose lookups
// ------------------------------------------------------------
//
// Each returns -1 if this model does not carry the take, which is the caller's
// signal to substitute.  They read self.weapon; see the header for why.

float(float mdlidx, float family, float crouching) DoD_GetAimAnim =
{
    return DoD_Frame(mdlidx, DoD_SeqName(crouching, DoD_Token(self.weapon, family, FALSE), "aim"));
};

float(float mdlidx, float family, float crouching) DoD_GetShootAnim =
{
    float f = DoD_Frame(mdlidx, DoD_SeqName(crouching, DoD_Token(self.weapon, family, FALSE), "shoot"));
    if (f >= 0)
        return f;
    // A token with an aim but no shoot: hold the aim rather than dropping the
    // whole weapon back onto a Counter-Strike index.
    return DoD_GetAimAnim(mdlidx, family, crouching);
};

float(float mdlidx, float family, float crouching) DoD_GetReloadAnim =
{
    float f = DoD_Frame(mdlidx, DoD_SeqName(crouching, DoD_Token(self.weapon, family, TRUE), "reload"));
    if (f >= 0)
        return f;
    // CROUCHED RELOAD MISSING -> try the standing one before giving up.  Eight
    // tokens have no reload in any stance (30cal gren knife mg mills rifle spade
    // stick) and the three belt-fed MGs have one only in the deployed stances,
    // so this second chance is what keeps a crouched MG42 gunner on a DoD pose
    // instead of a Counter-Strike one.
    if (crouching)
    {
        f = DoD_Frame(mdlidx, DoD_SeqName(FALSE, DoD_Token(self.weapon, family, TRUE), "reload"));
        if (f >= 0)
            return f;
    }
    // No reload anywhere: substitute the aim pose, which is exactly what
    // SH_GetReloadAnim already does for the nine Half-Life families that have no
    // reload of their own.
    return DoD_GetAimAnim(mdlidx, family, crouching);
};

// ------------------------------------------------------------
//  Death
// ------------------------------------------------------------
//
// DoD names its deaths; the Counter-Strike path indexes them (CSANIM_DEATH1 and
// up), and every DoD death index (19-29) falls OUTSIDE that range, so the CS
// range tests in client/cl_player.qc and client/cl_killfeed.qc would treat a
// correct DoD death pose as invalid and overwrite it.  Those sites ask this.
//
// `hitgroup` is the mod's HITGROUP_* of the killing blow, 0 when unknown.
float(float mdlidx, float hitgroup, float crouching) DoD_GetDeathAnim =
{
    float f;
    if (hitgroup == HITGROUP_HEAD)
    {
        f = DoD_Frame(mdlidx, crouching ? "die_crouch_head" : "die_headshot");
        if (f >= 0) return f;
    }
    if (hitgroup == HITGROUP_STOMACH)
    {
        f = DoD_Frame(mdlidx, "die_gutshot");
        if (f >= 0) return f;
    }
    if (crouching)
    {
        f = DoD_Frame(mdlidx, "die_crouch_backwards");
        if (f >= 0) return f;
    }
    f = DoD_Frame(mdlidx, "die_simple");
    if (f >= 0) return f;
    return DoD_Frame(mdlidx, "dod_idle1");
};

// Is this frame already one of DoD's death poses?  The Counter-Strike path
// answers the same question with a range test over
// CSANIM_DEATH1..CSANIM_DIE_FORWARD, and every DoD death index falls outside it,
// so that test would call a CORRECT pose invalid and stamp a generic one over it
// on every snapshot.  Two contiguous runs: die_simple..die_prone1 (19-29) and
// the four static corpse poses deadback..deadtable (341-344).
float(float mdlidx, float f) DoD_IsDeathPose =
{
    float lo = DoD_Frame(mdlidx, "die_simple");
    float hi = DoD_Frame(mdlidx, "die_prone1");
    if (lo >= 0 && hi >= lo && f >= lo && f <= hi)
        return TRUE;
    float d0 = DoD_Frame(mdlidx, "deadback");
    float d1 = DoD_Frame(mdlidx, "deadtable");
    return (d0 >= 0 && d1 >= d0 && f >= d0 && f <= d1);
};

// ------------------------------------------------------------
//  Locomotion
// ------------------------------------------------------------
//
// The Counter-Strike arm uses CSANIM_LEGS_IDLE_STATIC / _CROUCH_STATIC — single
// frozen leg poses with no root translation — because the full-body CS idles
// carry root-motion IK that the basebone split severs, producing the documented
// "feet drift / swim" symptom.  DoD has no single-frame equivalent (its shortest
// standing pose, dod_crouch_idle, is 11 frames), so this uses the real idles and
// the drift has to be MEASURED rather than assumed absent.
float(float mdlidx, float moving, float crouching, float onground) DoD_GetLegsAnim =
{
    float f;
    if (!onground)
    {
        f = DoD_Frame(mdlidx, "jump");
        if (f >= 0) return f;
    }
    if (!moving)
        return DoD_Frame(mdlidx, crouching ? "dod_crouch_idle" : "dod_idle1");
    if (crouching)
    {
        f = DoD_Frame(mdlidx, "dod_crawl");
        if (f >= 0) return f;
    }
    return DoD_Frame(mdlidx, "dod_jog");
};

// ------------------------------------------------------------
//  Selftest
// ------------------------------------------------------------
//
// The acceptance test for this whole file, run headlessly beside the rest of the
// [ai-selftest] block.  It answers the one question a log can otherwise never
// answer: did the DoD arm actually take, or is the resolver quietly handing back
// Counter-Strike indices that happen to be valid numbers?
//
// A CSANIM_* value IS a valid sequence index on a 345-sequence model — CSANIM_-
// AIM_RIFLE is 33, and 33 on us-inf.mdl is `stand_bolt_aim` — so "the index is in
// range" proves nothing at all.  The test therefore asserts the resolved index
// equals the index of the take we NAMED, which is the only check that can fail
// when the arm is missing.
//
// Runs on a scratch entity: these lookups read self.weapon (see the header), and
// the selftest's own `self` must not be written to.
void(float mdl) DoD_SelfTest =
{
    entity old_self = self;
    entity probe = spawn();
    self = probe;
    setmodel(probe, "models/player/us-inf/us-inf.mdl");

    float pass = 0, bad = 0, i, crouch;
    string firstbad = "";

    // Every DoD weapon id: WEP_DOD98K sits apart at 10, the rest run 114..147.
    for (i = 0; i <= 147; i = i + 1)
    {
        if (i != WEP_DOD98K && (i < 114 || i > 147))
            continue;
        string tok_a = DoD_WeaponAimToken(i);
        if (tok_a == "")
            continue;                       // not a DoD weapon id in that range
        string tok_r = DoD_WeaponReloadToken(i);

        for (crouch = 0; crouch <= 1; crouch = crouch + 1)
        {
            self.weapon = i;
            // The family argument is deliberately PANIM_NONE: if the weapon table
            // is doing its job the family is never consulted, so passing a real
            // one would hide a hole in it.
            float got_a = SH_GetAimAnim(mdl, PANIM_NONE, crouch);
            float got_s = SH_GetShootAnim(mdl, PANIM_NONE, crouch);
            float got_r = SH_GetReloadAnim(mdl, PANIM_NONE, crouch);

            float want_a = frameforname(mdl, DoD_SeqName(crouch, tok_a, "aim"));
            float want_s = frameforname(mdl, DoD_SeqName(crouch, tok_a, "shoot"));
            // The reload legitimately falls back — crouch to stand, then to the
            // aim pose for the eight tokens with no reload anywhere.  Mirror that
            // ladder here rather than asserting a take that does not exist.
            float want_r = frameforname(mdl, DoD_SeqName(crouch, tok_r, "reload"));
            if (want_r < 0)
                want_r = frameforname(mdl, DoD_SeqName(FALSE, tok_r, "reload"));
            if (want_r < 0)
                want_r = want_a;
            if (want_s < 0)
                want_s = want_a;

            if (got_a == want_a && got_a >= 0) pass = pass + 1;
            else { bad = bad + 1; if (firstbad == "") firstbad = strcat(DoD_SeqName(crouch, tok_a, "aim"), " got ", ftos(got_a), " want ", ftos(want_a)); }
            if (got_s == want_s && got_s >= 0) pass = pass + 1;
            else { bad = bad + 1; if (firstbad == "") firstbad = strcat(DoD_SeqName(crouch, tok_a, "shoot"), " got ", ftos(got_s), " want ", ftos(want_s)); }
            if (got_r == want_r && got_r >= 0) pass = pass + 1;
            else { bad = bad + 1; if (firstbad == "") firstbad = strcat(DoD_SeqName(crouch, tok_r, "reload"), " got ", ftos(got_r), " want ", ftos(want_r)); }
        }
    }

    // The family table must be TOTAL — every PANIM_, Counter-Strike, Half-Life
    // and shield alike, must name a take this model actually has.  A hole here is
    // the sh_player_sini.qc failure: a partial table silently answers with the
    // default for every weapon it does not know.
    float fambad = 0;
    string firstfam = "";
    for (i = PANIM_NONE; i <= PANIM_SHIELDED; i = i + 1)
    {
        string ft = DoD_FamilyToken(i);
        if (frameforname(mdl, strcat("stand_", ft, "_aim")) < 0)
        {
            fambad = fambad + 1;
            if (firstfam == "")
                firstfam = strcat("family ", ftos(i), " -> '", ft, "' has no stand_*_aim");
        }
    }

    remove(probe);
    self = old_self;

    print(sprintf("[panim-dod] resolver selftest: %g PASS, BAD=%g%s\n",
                  pass, bad, (bad > 0) ? strcat("  first: ", firstbad) : ""));
    print(sprintf("[panim-dod] family table totality: %g families, BAD=%g%s\n",
                  PANIM_SHIELDED + 1, fambad,
                  (fambad > 0) ? strcat("  first: ", firstfam) : ""));
};

// THE GAIT CLOCK HAS AUTHORED NUMBERS ON THIS MODEL.  GoldSrc advances the leg
// cycle by DISTANCE, not by time — StudioModelRenderer.cpp does
// `gaitframe += (m_flGaitMovement / pseqdesc->linearmovement[0]) * numframes` —
// and `linearmovement[0]` is qu-per-cycle metadata rather than baked root
// motion, which is why a pose dump of these takes measures a root X span of
// zero.  The mod's own distance-driven foot clock therefore has exact per-take
// constants here instead of the CS-tuned sv_anim_qu_per_sec.
//
// Read off us-inf.mdl.  Returns 0 for anything that is not a walk cycle, which
// the caller reads as "fall back to the cvar".
float(string take) DoD_GaitDistance =
{
    if (take == "dod_walk")   return 46.67;
    if (take == "dod_jog")    return 130.02;
    if (take == "dod_sprint") return 300.0;
    if (take == "dod_crawl")  return 100.0;
    return 0;
};
