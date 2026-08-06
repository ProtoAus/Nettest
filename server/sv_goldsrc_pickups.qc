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
//   2. NO SUCH WEAPON.  weapon_snark, weapon_satchel, weapon_tripmine,
//      weapon_hornetgun, the whole Opposing Force set (displacer, shock rifle,
//      spore launcher, sniper rifle, pipe wrench, grapple, penguin) and Sven's
//      own additions have no counterpart in this mod at all.  Aliasing them to
//      something else would be a lie; they stay unimplemented and are LISTED, so
//      the gap is a known quantity rather than a surprise.
//   3. NO SUCH SYSTEM.  item_longjump needs a longjump module, the CTF items
//      need CTF.  Same treatment: named, not faked.
//
// AMMO IS ITS OWN PROBLEM and is deliberately not bulk-aliased here.  Half-Life
// keeps global per-calibre pools, so `ammo_357` means "add 6 rounds to the .357
// pool" whether or not you own the gun.  This mod keeps ammo PER SLOT
// (slot_primary_ammo / secondary / melee, see shared/sh_weapon_slotammo.qc), so
// there is no pool to add to unless the player already carries the matching
// weapon.  The two ammo classes that DO work (ammo_9mmclip / ammo_9mmbox) work
// because sv_goldsrc_compat.qc special-cased them against the glock and SMG.
// Doing the rest properly means deciding what ammo-without-a-gun means in a
// slot-based mod, which is a design question, not a mapping exercise.
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
// Respawn is NOT implemented, matching Half-Life single-player behaviour - these
// are campaign pickups, not deathmatch ones, and 7500 respawning items would
// change how every campaign map plays.
void(entity plyr) GoldSrc_PickupTaken =
{
    if (self.target != "")
        SUB_UseTargets(self, plyr, USE_TOGGLE);
    remove(self);
};

void() GoldSrc_Suit_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
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
// 65 placements, and there is no longjump module to switch on - the player
// movement code has no such mode.  It is still spawned as a VISIBLE pickup that
// fires its chain, because a chunk of those placements gate progression behind
// picking it up, and an invisible relay means the player walks past the thing
// the map is waiting on.  It grants nothing and says so.
void() GoldSrc_Longjump_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
    sprint(other, PRINT_HIGH, "Long jump module collected (no effect in this mod).\n");
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
