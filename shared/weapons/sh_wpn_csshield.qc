// ============================================================
//  shared/weapons/sh_wpn_csshield.qc  -  Counter-Strike tactical shield
//
//  Slot  : none — this is EQUIPMENT, not a selectable weapon
//  Fire  : none of its own; the pistol in the other hand does the shooting
//  Alt   : +attack2 raises the shield (blocks, slows, cannot fire)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: cstrike/models/{v_shield_r,p_shield,w_shield}.mdl plus the nine
//  {v,p}_shield_<x>.mdl pairs in cstrike/models/shield/, all present in the
//  mounted Counter-Strike install.  Every player model in this mod already
//  carries the four shield pose sets (indices 83..98 — shieldgren, shieldknife,
//  shieldgun with a reload, and shielded), which is the strongest evidence that
//  the shield was always meant to be here: nothing else in the mod referenced a
//  single one of them.
//
//  WHY IT IS NOT A WEAPON.  In Counter-Strike the shield is not something you
//  select — it is strapped to your left arm and every pistol you draw is drawn
//  one-handed beside it.  Modelling it as a weapon_* in a slot would mean
//  inventing a "shield weapon" that Counter-Strike does not have and that the
//  animation set does not describe.  It is a flag on the player instead, in the
//  same family as item_kevlar, and it modifies whatever is in your hands.
//
//  THE FIVE RULES, from the CS behaviour it reproduces:
//    1. Pistols, the knife and grenades only.  Nine shield view models exist and
//       that is exactly the list; see SH_ShieldSuffix.
//    2. No primary weapon while carrying it, and vice versa (SH_ShieldBlocks*).
//    3. +attack2 deploys.  Deployed you cannot fire, and you move at
//       SHIELD_DEPLOY_SPEED of normal.
//    4. Deployed, it stops damage arriving inside a frontal arc outright.
//    5. Undeployed it still catches some of what hits it from directly ahead,
//       because the slab is still in front of your chest.
//
//  Rules 4 and 5 are a STATED APPROXIMATION, not a port: real CS traces the shot
//  against the shield's own hitbox, and this mod has no per-limb geometry to
//  trace against for a model that is not even in the player's mesh.  An angular
//  arc is the honest substitute — it is predictable, it is symmetric for
//  attacker and defender, and it cannot be cheesed by a hitbox seam.

// --- State ---------------------------------------------------------------
// Shared, because CSQC predicts the deploy toggle and the movement penalty and
// must land on the same answer the server does.
.float has_shield;         // carrying weapon_shield
.float shield_deployed;    // ...and holding it up
.float shield_next_toggle; // debounce, so a fast double-tap cannot flicker it
.float shield_alt_held;    // +attack2 last tick, for the rising-edge test
// Edge latch for the sv_debug_shield / cl_debug_shield traces (packed bitfield of
// the inputs those print).  Shared so both VMs get the field from one declaration.
.float shield_dbg_last;

const float SHIELD_TOGGLE_DELAY = 0.4;
const float SHIELD_DEPLOY_SPEED = 0.45;   // of normal, while deployed
const float SHIELD_CARRY_SPEED  = 0.85;   // of normal, merely carrying it

// Frontal arcs, as the COSINE of the half-angle, so the test is one dot product.
// Deployed: +-70 degrees, i.e. a 140 degree wall.  Undeployed: +-35 degrees, and
// only half the damage, because all that is in the way is the slab itself.
const float SHIELD_DEPLOY_COS   = 0.342;  // cos(70)
const float SHIELD_CARRY_COS    = 0.819;  // cos(35)
const float SHIELD_CARRY_ABSORB = 0.5;

const string SHIELD_WORLDMODEL  = "models/w_shield.mdl";
const string SHIELD_PMODEL      = "models/p_shield.mdl";

// v_shield_r.mdl IS NOT THE SHIELD ALONE, which is what the name suggests and
// what this file used to assume.  Measured: 58 bones, and its `reload` fires
// weapons/fiveseven_clipout.wav / _clipin.wav / _sliderelease.wav — it is the
// shield with a full FN Five-Seven built into it.  Swapping to it on deploy is
// exactly the reported "my gun turns into a five-seven when I press +attack2".
//
// It is also unnecessary.  Every combined model already carries shield_up,
// shield_idle and shield_down, so the raise is an animation on the model
// already on screen, not a second model.  Kept named here only so the next
// person to go looking for it finds this note instead of the file.
const string SHIELD_BAREVIEW    = "models/v_shield_r.mdl";  // DO NOT DRAW — see above

// --- Which weapons the shield can be carried with -------------------------
//
// The answer is not a design choice — it is the list of files Counter-Strike
// ships in cstrike/models/shield/.  A weapon with no shield view model cannot be
// held with one, which is exactly CS's own rule and is why the rule reads as a
// model lookup rather than a table of ids.
string(float wep) SH_ShieldSuffix =
{
    switch (wep)
    {
    case WEP_CSUSP:          return "usp";
    case WEP_GLOCK:          return "glock18";   // the CS Glock 18 is WEP_GLOCK
    case WEP_CFGLOCK:        return "glock18";   // CrossFire's twin, same silhouette
    case WEP_DEAGLE:         return "deagle";    // the CS Desert Eagle is WEP_DEAGLE
    case WEP_CSP228:         return "p228";
    case WEP_CFP228:         return "p228";
    case WEP_CSFIVESEVEN:    return "fiveseven";
    case WEP_KNIFE:          return "knife";     // the CS knife is WEP_KNIFE
    case WEP_CSHEGRENADE:    return "hegrenade";
    case WEP_CSFLASHBANG:    return "flashbang";
    case WEP_CSSMOKEGRENADE: return "smokegrenade";
    }
    return "";
};

float(float wep) SH_ShieldAllowsWeapon =
{
    return SH_ShieldSuffix(wep) != "";
};

// The combined view model for a shield + this weapon, or "" if there is none.
string(float wep) SH_ShieldViewModel =
{
    string suf = SH_ShieldSuffix(wep);
    if (suf == "")
        return "";
    return strcat("models/shield/v_shield_", suf, ".mdl");
};

string(float wep) SH_ShieldPlayerModel =
{
    string suf = SH_ShieldSuffix(wep);
    if (suf == "")
        return SHIELD_PMODEL;
    return strcat("models/shield/p_shield_", suf, ".mdl");
};

// --- The substituted model has its OWN sequence list ----------------------
//
// THE BUG THIS BLOCK EXISTS TO FIX.  Swapping the view model is not enough.
// Each weapon's csqc_display_frame returns an index into the model it was
// written against, and none of the nine combined models share that layout, so
// every index landed on a different animation:
//
//   Glock, firing        -> asked for 3 (`shoot3` on v_glock18.mdl)
//                           got  `shoot_empty` -> the slide-locked-back take,
//                           on every shot.  This is the reported "last bullet
//                           animation every time".
//   USP, silencer toggle -> asked for 7 and 15 (`add_silencer` / `detach`)
//                           got  `shield_up`, and 15 does not exist at all.
//                           This is the reported "impulse 7 is the only thing
//                           that raises the shield".
//
// Neither is an animation bug or a timing bug; both are one index read against
// the wrong table.
//
// MEASURED from the nine files, not assumed.  They come in exactly three
// layouts, and the difference is not cosmetic — the pistols have four takes the
// other two do not:
//
//   pistol   (usp, glock18, deagle, p228, fiveseven)   9 seqs
//       0 idle1  1 shoot1  2 shoot2  3 shoot_empty  4 reload  5 draw
//       6 shield_idle  7 shield_up  8 shield_down
//   knife                                             7 seqs
//       0 idle   1 slash   2 hit     3 deploy
//       4 shield_idle  5 shield_up  6 shield_down
//   grenade  (hegrenade, flashbang, smokegrenade)      7 seqs
//       0 idle1  1 pullpin 2 throw   3 draw
//       4 shield_idle  5 shield_up  6 shield_down
//
// Every lookup below goes through SH_SeqForName, so the indices above are
// documentation and the fallbacks; a cstrike mount that ships a different
// build cannot silently shift them the way the hardcoded ones did.
//
// NOT FIXABLE FROM HERE: all five pistol models fire fiveseven_*.wav from
// their own `reload` events regardless of which pistol is in them.  That is in
// the model data Valve shipped, it is the same in the retail cstrike and czero
// copies, and the only cure is editing the .mdl — which would mean carrying a
// borrowed asset in the mod.
const float SHIELDFAM_PISTOL  = 0;
const float SHIELDFAM_KNIFE   = 1;
const float SHIELDFAM_GRENADE = 2;

// SH_SeqForName and SH_SeqDuration live in sh_weapon_standard.qc, which is
// compiled AFTER this file on purpose (see the note at sv_progs.src:21).
// Forward-declared for the same reason sh_weapon_slotammo.qc forward-declares
// the legacy save/load pair.
float(string viewmodel_path, string seqname, float fallback) SH_SeqForName;
float(string viewmodel_path, float seq, float fallback) SH_SeqDuration;

// Derived from the PLAYER animation family rather than a second weapon table,
// so this and SH_ShieldAnimFamily cannot end up disagreeing about what a
// weapon is.
float(float wep) SH_ShieldFamily =
{
    switch (WeaponManifest_PlayerAnimFamily(wep))
    {
    case PANIM_KNIFE:   return SHIELDFAM_KNIFE;
    case PANIM_GRENADE: return SHIELDFAM_GRENADE;
    }
    return SHIELDFAM_PISTOL;
};

// The three shield poses.  Same three names in all nine models; only the
// indices move, which is precisely why they are looked up by name.
float(float wep) SH_ShieldSeqUp =
{
    return SH_SeqForName(SH_ShieldViewModel(wep), "shield_up",
                         (SH_ShieldFamily(wep) == SHIELDFAM_PISTOL) ? 7 : 5);
};
float(float wep) SH_ShieldSeqDown =
{
    return SH_SeqForName(SH_ShieldViewModel(wep), "shield_down",
                         (SH_ShieldFamily(wep) == SHIELDFAM_PISTOL) ? 8 : 6);
};
float(float wep) SH_ShieldSeqIdle =
{
    return SH_SeqForName(SH_ShieldViewModel(wep), "shield_idle",
                         (SH_ShieldFamily(wep) == SHIELDFAM_PISTOL) ? 6 : 4);
};

// Read rather than baked, even though all nine agree: up and down are 11 frames
// at 30 fps (0.333 s) and shield_idle is 31 at 15 (2.0 s).
float(float wep) SH_ShieldUpDuration =
{ return SH_SeqDuration(SH_ShieldViewModel(wep), SH_ShieldSeqUp(wep),   0.333); };
float(float wep) SH_ShieldDownDuration =
{ return SH_SeqDuration(SH_ShieldViewModel(wep), SH_ShieldSeqDown(wep), 0.333); };
float(float wep) SH_ShieldIdleDuration =
{ return SH_SeqDuration(SH_ShieldViewModel(wep), SH_ShieldSeqIdle(wep), 2.0); };

// What the COMBINED model should play for the weapon's current state, while the
// shield is carried but NOT raised.  `mag` is the magazine after the shot, for
// the slide-locked-back take; the knife and grenade layouts have no such pose
// and ignore it.
float(float wep, float state, float mag, float action_id) SH_ShieldWeaponSeq =
{
    string mdl = SH_ShieldViewModel(wep);
    float  fam = SH_ShieldFamily(wep);

    if (fam == SHIELDFAM_KNIFE)
    {
        if (state == WS_DRAW)    return SH_SeqForName(mdl, "deploy", 3);
        if (state == WS_FIRE)    return SH_SeqForName(mdl, "slash",  1);
        if (state == WS_SPECIAL) return SH_SeqForName(mdl, "hit",    2);
        return SH_SeqForName(mdl, "idle", 0);
    }
    if (fam == SHIELDFAM_GRENADE)
    {
        if (state == WS_DRAW)    return SH_SeqForName(mdl, "draw",    3);
        if (state == WS_SPECIAL) return SH_SeqForName(mdl, "pullpin", 1);
        if (state == WS_FIRE)    return SH_SeqForName(mdl, "throw",   2);
        return SH_SeqForName(mdl, "idle1", 0);
    }

    if (state == WS_DRAW)   return SH_SeqForName(mdl, "draw",   5);
    if (state == WS_RELOAD) return SH_SeqForName(mdl, "reload", 4);
    if (state == WS_FIRE)
    {
        if (mag <= 0)
            return SH_SeqForName(mdl, "shoot_empty", 3);
        // TWO takes here, where the bare pistols have three or four.  Alternate
        // on the shot counter rather than reusing the weapon's own hash: the
        // pick only has to be stable for one shot and identical on both sides,
        // and a hash tuned for a 3-way split would bias a 2-way one.
        return (action_id & 1) ? SH_SeqForName(mdl, "shoot2", 2)
                               : SH_SeqForName(mdl, "shoot1", 1);
    }
    // No shield model has a pose for WS_SPECIAL, which is why the USP's
    // silencer toggle is refused outright while the shield is carried
    // (W_CheckImpulses / CSQC_PredictWeaponImpulse) rather than animated wrong.
    return SH_SeqForName(mdl, "idle1", 0);
};

// --- Rule 2: the shield and a primary are mutually exclusive --------------
float(entity p, float wep) SH_ShieldBlocksPickup =
{
    if (!p.has_shield)
        return FALSE;
    if (SH_ShieldAllowsWeapon(wep))
        return FALSE;
    // Everything else is a two-handed weapon.  Melee that is not the knife
    // (crowbar, wrench, katana...) is two-handed too and blocked with the rest —
    // there is no one-handed pose for it beside a shield.
    return TRUE;
};

// --- Rule 3: cannot fire while it is up ----------------------------------
float() SH_ShieldBlocksFire =
{
    return (self.has_shield && self.shield_deployed);
};

// --- The animation family the shield imposes on whatever is held ----------
//
// Called from W_GetPlayerAnimFamily with `self` as the player, so the ONE place
// that answers "which pose is this player in" answers correctly for the shield
// too, on the server (hitboxes) and in CSQC (the drawn model) alike.
float(float family) SH_ShieldAnimFamily =
{
    if (!self.has_shield)
        return family;
    if (self.shield_deployed)
        return PANIM_SHIELDED;
    switch (family)
    {
    case PANIM_KNIFE:   return PANIM_SHIELDKNIFE;
    case PANIM_GRENADE: return PANIM_SHIELDGREN;
    }
    // Pistols, and anything else that got through rule 2.
    return PANIM_SHIELDGUN;
};

// --- Rules 4 and 5: does the shield stop this hit? ------------------------
//
// Returns the FRACTION of the damage that gets through, 0..1.  Split out here
// rather than written inline in W_ApplyDamage so the number is testable and so
// the arcs live beside the constants that define them.
//
// `src` is where the damage came from.  A hit with no meaningful direction
// (drowning, crush, a trigger_hurt the player is standing in) is left alone:
// a shield is a thing you point at someone, and there is nothing to point at.
// SSQC only.  Damage is server-authoritative, and .v_angle is not a field CSQC
// can read off an arbitrary entity — the client only ever knows its own.
#ifdef SSQC
float(entity victim, vector src) SH_ShieldDamageFraction =
{
    if (!victim.has_shield)
        return 1.0;

    vector to_src = src - (victim.origin + victim.view_ofs);
    to_src_z = 0;
    if (vlen(to_src) < 1)
        return 1.0;                       // no direction to test
    to_src = normalize(to_src);

    // The shield faces where the player is LOOKING, which on the server is
    // v_angle and not .angles — .angles has the strafe leg-twist folded into it
    // (sh_player_anims.qc rotates the whole model toward movement), and a player
    // sidestepping would otherwise find their shield pointing at the wall.
    makevectors([0, victim.v_angle_y, 0]);
    float facing = to_src * v_forward;

    if (victim.shield_deployed)
        return (facing >= SHIELD_DEPLOY_COS) ? 0.0 : 1.0;
    if (facing >= SHIELD_CARRY_COS)
        return 1.0 - SHIELD_CARRY_ABSORB;
    return 1.0;
};
#endif

// --- Movement penalty ----------------------------------------------------
float() SH_ShieldSpeedFactor =
{
    if (!self.has_shield)
        return 1.0;
    return self.shield_deployed ? SHIELD_DEPLOY_SPEED : SHIELD_CARRY_SPEED;
};

// --- The deploy toggle, shared so prediction and the server agree ---------
// Returns TRUE if the state changed.
float(float now) SH_ShieldToggle =
{
    if (!self.has_shield)
        return FALSE;
    if (now < self.shield_next_toggle)
        return FALSE;
    // A shield cannot be raised mid-reload any more than a gun can be fired
    // mid-reload; both hands are busy.
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return FALSE;

    self.shield_deployed    = !self.shield_deployed;
    self.shield_next_toggle = now + SHIELD_TOGGLE_DELAY;
    return TRUE;
};

// Losing the shield (dropped, died, took a primary) must also lower it, or the
// player keeps the deployed pose and the movement penalty with nothing in hand.
void(entity p) SH_ShieldClear =
{
    p.has_shield      = FALSE;
    p.shield_deployed = FALSE;
};
