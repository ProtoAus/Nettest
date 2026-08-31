// server/sv_goldsrc_pickups.qc
// ----------------------------------------------------------------------------
// Half-Life / Opposing Force / Blue Shift pickups.
//
// Measured across all four mounted games (125 valve maps, 55 gearbox, 37 bshift,
// 108 svencoop): 72 distinct pickup classnames, ~7500 placements.  Almost none of
// them had a spawn function, so almost all of them were landing in
// SV_OnEntityNoSpawnFunction and becoming invisible inert relays - which is why
// a Half-Life map looks stripped even when its layout is perfect.
//
// THREE DIFFERENT PROBLEMS WEAR THE SAME NAME, and separating them is most of
// the work here:
//
//   1. NAME ONLY.  Half-Life calls it weapon_shotgun, this mod calls the same
//      gun weapon_hlshotgun.  An alias is the entire fix, and it is what the
//      shipped weapon_crowbar alias has always done.  This is the big win by
//      volume - weapon_handgrenade alone is 458 placements.
//   2. SAME JOB, DIFFERENT OBJECT.  A sawn-off double barrel, a Thompson, a
//      pipe wrench: the mod has a gun that behaves right but not one that LOOKS
//      right, and a bare alias puts a visibly wrong item on the floor.  These
//      get the mod's behaviour and the original's world model - see the second
//      block below, and read the note there before copying the pattern, because
//      the obvious way to write it silently reverts on the first round restart.
//   3. NO SUCH WEAPON AT ALL.  The displacer, the shock rifle, the barnacle
//      grapple and pizza_ya_san2's jetpack do things nothing in this mod does.
//      These were IMPLEMENTED rather than aliased or skipped -
//      shared/weapons/sh_wpn_opshockrifle.qc, sh_wpn_opdisplacer.qc,
//      sh_wpn_svjetpack.qc, sh_wpn_opbgrapple.qc.
//   4. NO SUCH SYSTEM.  item_longjump needs a longjump module, the CTF items
//      need CTF.  Those are named, not faked.
//
// AMMO used to be listed here as a design question that had not been answered:
// Half-Life keeps global per-calibre pools, this mod keeps ammo per weapon, so
// there was nothing for a pickup to add to unless you already carried the gun.
// THAT IS NO LONGER TRUE.  sv_goldsrc_ammo.qc implements per-calibre RESERVES -
// ammo for a gun you have not found yet is banked by calibre and released when
// you find it - and every GoldSrc, Opposing Force and Sven ammo classname now
// resolves through it.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// weapon name aliases
// ---------------------------------------------------------------------------
// Each of these is Half-Life's classname for a gun this mod already has, so the
// alias hands straight over to the mod's own spawn function - which builds a
// real pickup with the right slot, ammo, draw and drop behaviour.  Setting
// .classname first matters: the pickup path and the "already have this slot"
// tests downstream read it, and leaving the HL name on the entity would make a
// picked-up shotgun report as something the weapon manifest has never heard of.

void() weapon_shotgun =
{
    self.classname = "weapon_hlshotgun";
    weapon_hlshotgun();
};

// HL's SMG. Three names for one gun across the corpus: weapon_9mmAR (214),
// weapon_mp5 (6) and Sven's weapon_m16 uses its own model, so only the first two
// alias here.  NOTE THE CAPITALS - the classname really is "9mmAR" and QC
// identifiers are case sensitive, so this must match the BSP exactly.
void() weapon_9mmAR =
{
    self.classname = "weapon_hlsmg";
    weapon_hlsmg();
};

void() weapon_mp5 =
{
    self.classname = "weapon_hlsmg";
    weapon_hlsmg();
};

void() weapon_9mmhandgun =
{
    self.classname = "weapon_hlglock";
    weapon_hlglock();
};

void() weapon_handgrenade =
{
    self.classname = "weapon_hlgrenade";
    weapon_hlgrenade();
};

void() weapon_rpg =
{
    self.classname = "weapon_hlrpg";
    weapon_hlrpg();
};

void() weapon_egon =
{
    self.classname = "weapon_hlegon";
    weapon_hlegon();
};

// Half-Life's internal name for the .357 revolver.  One placement corpus-wide,
// but it costs a line and a map that uses it is otherwise missing its magnum.
// The mod's spawn function for the HL magnum is plainly weapon_357 (it lives in
// sh_wpn_hl357.qc but is not itself prefixed), so this alias points there rather
// than at a "weapon_hl357" that does not exist.
void() weapon_python =
{
    self.classname = "weapon_357";
    weapon_357();
};

// ---------------------------------------------------------------------------
// aliases that also carry the ORIGINAL world model
// ---------------------------------------------------------------------------
// The aliases above hand straight over to the mod's spawn function and get the
// mod's gun on the floor.  That is fine when the two guns are the same object -
// HL's shotgun and this mod's are both pump shotguns.  It is not fine for a
// sawn-off double barrel, a Thompson, or a pipe wrench, where the map is placing
// a visibly different object and the player is entitled to recognise it.
//
// So these keep the mod's BEHAVIOUR and take back the ORIGINAL model.  The view
// and hand models stay stock; that is a real and deliberate limitation, stated
// rather than hidden, and it is invisible until you actually hold the thing.
//
// THE SHAPE OF THESE IS LOAD-BEARING AND IT IS NOT THE OBVIOUS ONE.
//
// The obvious version - call the base spawn function, then setmodel over the top
// - is wrong, and wrong in a way no amount of walking up to the pickup would
// reveal.  W_RegisterMapWeapon stores the function pointer it is HANDED into
// .map_weapon_spawn (sv_weapons.qc:409), and W_RespawnMapWeapons calls that
// pointer again on every round restart and on any mp_nomapweapons 1->0 revive
// (sv_weapons.qc:595-597).  A base spawn function passes ITSELF.  So the first
// round restart re-runs the stock function and the model quietly reverts, for
// the rest of the map, with nothing logged.
//
// Two further reasons the obvious version is wrong even before a restart: the
// floor snap inside W_RegisterMapWeapon (droptofloor / W_PhysDropGroundSnap)
// would run against the stock model's hull rather than the one now on the
// entity, and re-registering re-enters W_PhysDropStart -> physics_enable a
// second time in the same frame under the default sv_phys_drops 1.
//
// Hence: full spawn functions, each ending in W_RegisterMapWeapon(<itself>).
// setsize after setmodel is mandatory - setmodel restamps mins/maxs from the
// model's own $bbox, and GoldSrc world models carry a 1-2 unit box.
//
// Every model path below came out of svencoop/sven-coop.fgd and was then checked
// against the mounts. Guessing them from the classname does not work: the
// barnacle grapple is w_bgrap.mdl, the 5.56 box is w_saw_clip.mdl, and the
// sniper rifle is w_m40a1.mdl.  Three for three wrong on the first attempt.

// Shared scaffolding: everything the aliases have in common.  The ammo fields
// and the registration stay with the caller, because the field NAMES are
// per-weapon and the registration has to name the alias itself.
void(string mdl, vector mns, vector mxs, float wep, float slot,
     void() eqp, void() drp, void(entity) cpy) GoldSrc_AliasSetup =
{
    // Precached HERE rather than in sh_customdefs.qc's central block, following
    // GoldSrc_SpawnPickup: these models belong to Half-Life and They Hunger, and
    // a Counter-Strike map should not spend thirteen precache slots on guns it
    // will never place.  Spawn functions run during map load, so this is legal.
    // Every alias funnels through here, so this is the one place that can catch
    // a slot disagreement.  weapon_touch routes a pickup by .weapon_slot while
    // the slot-ammo code derives the slot from the manifest - when the two
    // differ the gun goes in one slot and its ammo in another, silently.
    // weapon_uziakimbo shipped that way; this makes the next one loud.
    if (slot != WeaponManifest_Slot(wep))
        dprint(sprintf("[goldsrc] ALIAS SLOT MISMATCH: %s declares slot %g, manifest says %g\n",
                       self.classname, slot, WeaponManifest_Slot(wep)));

    precache_model(mdl);
    setmodel(self, mdl);
    setsize(self, mns, mxs);
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = wep;
    self.weapon_slot    = slot;
    self.weap_draw      = eqp;
    self.weap_drop_func = drp;
    self.pickupcopy     = cpy;
    self.touch          = weapon_touch;
};

// --- Opposing Force ---------------------------------------------------------

// 36 placements.  OpFor's M40A1 bolt-action; the AWP is the mod's closest gun
// and shares the 7.62 pool ammo_762 now feeds.
// weapon_sniperrifle is now a REAL weapon -
// shared/weapons/sh_wpn_opsniperrifle.qc - the real M40A1, with its
// two-stage reload and its eleven sounds, instead of a Counter-Strike AWP.

// 27 placements across OpFor and They Hunger.  A melee wrench for a melee
// wrench - the closest match in the whole of this round.
// weapon_pipewrench is now a REAL weapon -
// shared/weapons/sh_wpn_oppipewrench.qc - with the CHARGED swing this
// alias could not express, and the five big-swing samples nothing was playing.

// 29 placements.  Lobs explosive organic pods; the grenade launcher is the
// mechanic, and ammo_spore feeds its magazine (it carries no reserve).
// weapon_sporelauncher is now a REAL weapon -
// shared/weapons/sh_wpn_opsporelauncher.qc - firing spores out of
// spore.mdl instead of a steel grenade out of a living weapon.

// 4 placements.  weapon_penguin is now a REAL weapon -
// shared/weapons/sh_wpn_oppenguin.qc - with its own ammo pool and its own
// viewmodel, instead of a model swap that dressed the pickup as a penguin nest
// and then handed you snarks.  It was the LAST GoldSrc_AliasSetup stand-in left
// in this file.
//
// Its thrown creature is still the snark's, deliberately: OpFor's penguin IS
// CSqueakGrenade with a different model, so W_PenguinSpawn calls W_SnarkSpawn
// and re-models the result rather than forking the AI.  See that file's header.

// --- They Hunger ------------------------------------------------------------
//
// ALL EIGHT ARE NOW REAL WEAPONS.  They used to be aliases in the strict sense:
// GoldSrc_AliasSetup dressed the nearest Half-Life weapon in a They Hunger
// world model, so weapon_tommygun handed you an MP5 with an M203 and
// weapon_sawedoff handed you an eight-shell pump gun.  Every one of them ships
// a complete v_/w_/p_ set under svencoop/models/hunger/weapons/ that went
// unused, and the campaign's own behaviour is on disk as AngelScript
// (svencoop/scripts/maps/hunger/weapons/*.as), so there was nothing to guess.
//
// What is left here is the CLASSNAME.  Maps place these names, so the spawn
// functions have to keep them; each now just calls the real weapon's spawn,
// the same shape weapon_th_taurus below already uses.  The stats that used to
// be quoted in these comments live in the weapon files now, next to the code
// that acts on them, cited line by line.
//
// The models and sounds moved with them: they are precached in the THEY HUNGER
// GUNS block in shared/sh_customdefs.qc rather than here.  That is a real
// change of policy for these eight — GoldSrc_AliasSetup precaches lazily, per
// placement, deliberately so that a Counter-Strike map does not spend slots on
// guns it will never see.  These eight are now reachable from the buy menu and
// the F5 panel on ANY map, so a lazy precache would make every one of those
// routes a late precache, which is a client desync rather than a missing model.

void() weapon_sawedoff =
{
    self.classname = "weapon_sawedoff";
    weapon_thsawedoff();
};

void() weapon_colt1911 =
{
    self.classname = "weapon_colt1911";
    weapon_th1911();
};

void() weapon_m14 =
{
    self.classname = "weapon_m14";
    weapon_thm14();
};

void() weapon_tommygun =
{
    self.classname = "weapon_tommygun";
    weapon_thtommygun();
};

void() weapon_spanner =
{
    self.classname = "weapon_spanner";
    weapon_thspanner();
};

void() weapon_teslagun =
{
    self.classname = "weapon_teslagun";
    weapon_thteslagun();
};

void() weapon_m16a1 =
{
    self.classname = "weapon_m16a1";
    weapon_thm16a1();
};

void() weapon_greasegun =
{
    self.classname = "weapon_greasegun";
    weapon_thgreasegun();
};

// 1 placement, th_ep3_00.  A Taurus revolver, and the ONLY They Hunger weapon
// classname with no .as file and no model of its own in the mount - so unlike
// the eight above there is nothing to take back, and it stays on the stock .357.
void() weapon_th_taurus =
{
    self.classname = "weapon_357";
    weapon_357();
};

// --- Sven Co-op's own guns --------------------------------------------------
//
// 70 placements across the 108-map svencoop corpus, which is a FOURTH corpus:
// the round-6 census measured valve, gearbox and bshift and reported 100%, and
// that figure never covered these maps.  With the four below the svencoop
// corpus goes 98% -> 100%.
//
// Note the model collision: this weapon_m16 is Sven's, models/w_m16.mdl, and is
// a DIFFERENT FILE from They Hunger's weapon_m16a1 at
// models/hunger/weapons/m16a1/w_m16.mdl.  Same basename, two guns.

// 32 placements.  Sven's M16 is a 9mm assault rifle with an M203 - which is
// exactly what WEP_HLSMG already is, so this is the same match weapon_m16a1
// takes, wearing the other m16 model.
// weapon_m16 is now a REAL weapon -
// shared/weapons/sh_wpn_svm16.qc - a 5.56 rifle firing 5.56, instead of a
// 9mm MP5 wearing an M16's world model while ammo_556clip drained into it.

// 23 placements.  A 9mm machine pistol; the MAC-10 is the mod's own, and the
// two are close enough that only the model gives it away.
// weapon_uzi is now a REAL weapon -
// shared/weapons/sh_wpn_svuzi.qc - with the UZI's own 17-file sound set
// and its own viewmodel, instead of a CrossFire MAC-10.

// 11 placements.  Dual wield, so the Elite rather than the MAC-10 - it is the
// mod's only akimbo gun and the firing pattern is the point of the pickup.
// The model is w_2uzis.mdl; "w_uziakimbo.mdl" does not exist, which is the
// fourth model basename this round that was wrong when guessed from the
// classname and right when read out of the FGD.
// weapon_uziakimbo is now a REAL weapon -
// shared/weapons/sh_wpn_svuziakimbo.qc - the akimbo half of v_uzi.mdl
// (sequences 8-16), instead of CrossFire's Elite pistols.  The SLOT_PRIMARY /
// SLOT_SECONDARY disagreement documented on the old alias is gone with it: the
// new weapon declares SECONDARY in both the manifest and its spawn function.

// 4 placements, and the weakest match of the four - stated rather than hidden.
// Sven's minigun is a spin-up heavy weapon that slows the carrier; the M249 is
// the mod's only belt-fed and shares the "big magazine, no reload mid-burst"
// feel, but there is no spin-up here and no movement penalty.  At 4 placements
// that is the right trade against building a new weapon.
// weapon_minigun is now a REAL weapon -
// shared/weapons/sh_wpn_svminigun.qc - WITH the spin-up this alias
// explicitly could not express.  Its own comment called this "the weakest match
// of the four"; that is now fixed rather than documented.

// ---------------------------------------------------------------------------
// item_suit — the HEV suit
// ---------------------------------------------------------------------------
// Asked for by name, and the plan's note that "no armour stat exists in this
// mod" was wrong: .float armor is declared in sv_customdefs.qc and carries the
// Kevlar value 0..100.  So this can be a real pickup rather than a decision.
//
// DELIBERATE DIVERGENCE, stated rather than hidden.  Half-Life's item_suit
// grants no armour at all - it switches the HEV suit ON, which is what unlocks
// the HUD, the flashlight and the voice.  None of those are gated here (the HUD
// and flashlight are always available), so a faithful port would be a pickup
// that visibly does nothing.  Granting armour is the nearest thing that means
// something in this mod, and it matches the player's expectation that picking up
// the suit makes you tougher.
//
// The armour VALUE is Half-Life's own: CItemBattery gives 15 per battery and the
// suit caps at 100, so a suit that starts you at 50 is the middle of the range
// it was designed around.
const float SUIT_ARMOR_GRANT   = 50;
const float SUIT_ARMOR_MAX     = 100;
const float BATTERY_ARMOR_GRANT = 15;	// HL's gSkillData.batteryCapacity

const string SND_ITEM_PICKUP = "items/gunpickup2.wav";
const string SND_SUIT_PICKUP = "items/suitchargeok1.wav";

// Shared tail for every simple pickup below: fire the target chain, then vanish.
//
// Respawn used to be flatly unimplemented here, "matching Half-Life
// single-player behaviour - these are campaign pickups, not deathmatch ones, and
// 7500 respawning items would change how every campaign map plays."  THAT
// REASONING STILL HOLDS AND IS WHY IT IS OPT-IN: mp_item_respawndelay and
// mp_ammo_respawndelay default to -2, Pickup_RespawnDelay reads that as "never",
// and this function then removes the entity exactly as it always did.  Nothing
// changes for any existing map unless a server or a mapper asks for it.
void(entity plyr) GoldSrc_PickupTaken =
{
    if (self.target != "")
        SUB_UseTargets(self, plyr, USE_TOGGLE);
    // .pickup_kind, not a literal: ammo reaches this same tail and must be
    // governed by mp_ammo_respawndelay rather than mp_item_respawndelay.
    // Unset means ITEM, which is what every caller here except ammo is.
    if (Pickup_Taken(self, self.pickup_kind))
        return;                     // hidden and scheduled - do not remove
    remove(self);
};

void() GoldSrc_Suit_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;

    // THE SUIT BIT IS SET BEFORE THE ARMOUR GUARD, and the order matters.
    // The guard below exists so a full-armour player leaves the pickup for
    // someone who needs it - but in Half-Life the suit is a boolean the map
    // can ask about, and a player who walks over it at 100 armour has still
    // picked up the suit.  Setting it after the guard would mean the answer
    // depended on your armour, which is exactly the confusion .has_suit was
    // added to end.  hl_c01_a1's airlock nag is the case that cares.
    other.has_suit = TRUE;

    if (other.armor >= SUIT_ARMOR_MAX)
        return;			// nothing to give; leave it for someone who needs it

    other.armor = min(SUIT_ARMOR_MAX, other.armor + SUIT_ARMOR_GRANT);
    sound(other, CHAN_ITEM, SND_SUIT_PICKUP, 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

void() GoldSrc_Battery_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    if (other.armor >= SUIT_ARMOR_MAX)
        return;

    other.armor = min(SUIT_ARMOR_MAX, other.armor + BATTERY_ARMOR_GRANT);
    sound(other, CHAN_ITEM, SND_SUIT_PICKUP, 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

// Common body for the model-plus-touch pickups.  MOVETYPE_TOSS so an item the
// mapper floated above a desk settles onto it, exactly as Half-Life's items do -
// several of the corpus placements rely on that rather than being placed
// precisely.
void(string mdl, void() tch) GoldSrc_SpawnPickup =
{
    string use = self.model;
    if (use == "" || !use)
        use = mdl;

    precache_model(use);
    precache_sound(SND_SUIT_PICKUP);
    precache_sound(SND_ITEM_PICKUP);

    setmodel(self, use);
    setsize(self, '-16 -16 0', '16 16 16');
    self.solid    = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.touch    = tch;
};

void() item_suit =
{
    GoldSrc_SpawnPickup("models/w_suit.mdl", GoldSrc_Suit_Touch);
};

void() item_battery =
{
    GoldSrc_SpawnPickup("models/w_battery.mdl", GoldSrc_Battery_Touch);
};

// ---------------------------------------------------------------------------
// item_longjump
// ---------------------------------------------------------------------------
// 65 placements.  The module is now REAL: it sets .pm_longjump, which is
// replicated to CSQC and read by PM_CheckJump on both sides
// (shared/sh_pmove.qc), giving Half-Life's duck-jump super jump.
//
// Still spawned as a VISIBLE pickup that fires its chain, because a chunk of
// those placements gate progression behind picking it up and an invisible relay
// means the player walks past the thing the map is waiting on.
void() GoldSrc_Longjump_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
    GoldSrc_GrantItemClass(other, "item_longjump");
    sprint(other, PRINT_HIGH, "Long jump module collected.\n");
    GoldSrc_PickupTaken(other);
};

void() item_longjump =
{
    GoldSrc_SpawnPickup("models/w_longjump.mdl", GoldSrc_Longjump_Touch);
};

// ---------------------------------------------------------------------------
// item_antidote / item_security
// ---------------------------------------------------------------------------
// Half-Life declares both and neither does anything in HL either - CItemAntidote
// and CItemSecurity are stubs that just disappear on touch.  Reproducing that
// faithfully is one function, and it stops 8 placements being inert relays.
void() GoldSrc_NullItem_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

void() item_antidote =
{
    GoldSrc_SpawnPickup("models/w_antidote.mdl", GoldSrc_NullItem_Touch);
};

void() item_security =
{
    GoldSrc_SpawnPickup("models/w_security.mdl", GoldSrc_NullItem_Touch);
};
