// server/sv_goldsrc_ammo.qc
// ----------------------------------------------------------------------------
// Half-Life ammo pickups, on a reserve model.
//
// THE PROBLEM.  Half-Life keeps global per-calibre pools, so `ammo_357` means
// "add six rounds to the .357 pool" whether or not you own the revolver.  This
// mod keeps ammo PER WEAPON (.ammo_357, .ammo_hlshotgun, ... each with its own
// MAX_AMMO_* cap), so there is nothing for a pickup to add to unless the player
// already carries the matching gun.  That is why ~2600 ammo placements across the
// corpus were landing in SV_OnEntityNoSpawnFunction and becoming invisible
// relays, and why only ammo_9mmclip / ammo_9mmbox worked: they were special-cased
// against the glock and the SMG by hand.
//
// THE DESIGN, which is the one you asked for: a pickup ALWAYS succeeds.  If you
// carry the gun, it tops the gun up as Half-Life would.  If you do not, the
// rounds go into a per-calibre RESERVE you keep carrying, and the moment you pick
// up a weapon that uses that calibre the reserve is drained into it and cleared.
//
// So walking past a crate of buckshot before you have found the shotgun is not
// wasted, which is exactly how the campaign maps are laid out - Half-Life scatters
// ammo for weapons you have not been given yet all through the early chapters.
//
// TWO PROPERTIES WORTH STATING, because they are choices rather than facts:
//
//   The reserve is capped at the weapon's own MAX_AMMO_*.  An uncapped bank would
//   let a player sweep a whole map and arrive at the shotgun with 400 shells,
//   which is not a reserve, it is a different game.
//
//   Draining is all-or-nothing per calibre and happens once, on pickup.  A
//   half-drained reserve (gun full, remainder kept) would be more "efficient" and
//   would also mean the bank never empties and the player can never tell what
//   they are carrying.  It empties.
// ----------------------------------------------------------------------------

// Forward decls — the weapon files compile before this one, but the ammo FIELDS
// they declare are what this reads, so no forward declaration is needed for
// those.  These are the give helpers from sv_goldsrc_pickups.qc.
void(entity plyr) GoldSrc_PickupTaken;
void(string mdl, void() tch) GoldSrc_SpawnPickup;
// sv_player.qc, which compiles later: the id -> spawn-function dispatch for
// every weapon in the mod.  Squadmaker_SpawnItem uses it for the mod weapons
// that have no Half-Life object-table index.
void(vector org, float weapon_id) SV_DebugSpawnWeaponId;

// ---------------------------------------------------------------------------
// the calibres
// ---------------------------------------------------------------------------
// One id per POOL, not per pickup class: ammo_buckshot and a Sven crate of
// shells are the same calibre and must share a reserve.
const float CAL_9MM       = 1;
const float CAL_357       = 2;
const float CAL_BUCKSHOT  = 3;
const float CAL_ARGREN    = 4;	// M203 grenades for the SMG
const float CAL_ROCKET    = 5;
const float CAL_URANIUM   = 6;	// gauss + egon share it in HL, and here
const float CAL_BOLT      = 7;	// crossbow
// Opposing Force's three.  They are not exotic additions - ammo_556 (122
// placements) and ammo_762 (94) and ammo_spore (288, the single most placed
// pickup in the whole of OpFor) outnumber most of the calibres above.
const float CAL_556       = 8;	// M249 SAW
const float CAL_762       = 9;	// sniper rifle; Sven's weaponbox calls it "m40a1"
const float CAL_SPORE     = 10;	// spore launcher

// The reserves.  Separate fields rather than an array because QC arrays cannot
// be entity fields, and ten floats is cheaper than the indirection would be.
.float bank_9mm;
.float bank_357;
.float bank_buckshot;
.float bank_argren;
.float bank_rocket;
.float bank_uranium;
.float bank_bolt;
.float bank_556;
.float bank_762;
.float bank_spore;

float(entity p, float cal) Ammo_BankGet =
{
	if (cal == CAL_9MM)      return p.bank_9mm;
	if (cal == CAL_357)      return p.bank_357;
	if (cal == CAL_BUCKSHOT) return p.bank_buckshot;
	if (cal == CAL_ARGREN)   return p.bank_argren;
	if (cal == CAL_ROCKET)   return p.bank_rocket;
	if (cal == CAL_URANIUM)  return p.bank_uranium;
	if (cal == CAL_BOLT)     return p.bank_bolt;
	if (cal == CAL_556)      return p.bank_556;
	if (cal == CAL_762)      return p.bank_762;
	if (cal == CAL_SPORE)    return p.bank_spore;
	return 0;
};

void(entity p, float cal, float v) Ammo_BankSet =
{
	if (cal == CAL_9MM)      { p.bank_9mm      = v; return; }
	if (cal == CAL_357)      { p.bank_357      = v; return; }
	if (cal == CAL_BUCKSHOT) { p.bank_buckshot = v; return; }
	if (cal == CAL_ARGREN)   { p.bank_argren   = v; return; }
	if (cal == CAL_ROCKET)   { p.bank_rocket   = v; return; }
	if (cal == CAL_URANIUM)  { p.bank_uranium  = v; return; }
	if (cal == CAL_BOLT)     { p.bank_bolt     = v; return; }
	if (cal == CAL_556)      { p.bank_556      = v; return; }
	if (cal == CAL_762)      { p.bank_762      = v; return; }
	if (cal == CAL_SPORE)    { p.bank_spore    = v; return; }
};

// The cap for a calibre is the cap of the weapon that eats it, so a reserve can
// never hold more than the gun could.
//
// Returning 0 here is NOT harmless: GoldSrc_Ammo_Touch compares held >= cap, so
// an unregistered calibre computes 0 >= 0, refuses the pickup, prints nothing,
// and leaves the box on the floor forever.  That reads as "the model is broken"
// rather than "the calibre is missing a line", which is why it is called out.
float(float cal) Ammo_CalibreMax =
{
	if (cal == CAL_9MM)      return MAX_AMMO_HLSMG;		// the larger of glock/SMG
	if (cal == CAL_357)      return MAX_AMMO_357;
	if (cal == CAL_BUCKSHOT) return MAX_AMMO_SHOTGUN;
	if (cal == CAL_ARGREN)   return MAX_AMMO_HLSMG_GRENADES;
	if (cal == CAL_ROCKET)   return MAX_AMMO_HLRPG;
	if (cal == CAL_URANIUM)  return MAX_AMMO_GAUSS;
	if (cal == CAL_BOLT)     return MAX_AMMO_CROSSBOW;
	if (cal == CAL_556)      return MAX_AMMO_M249;
	if (cal == CAL_762)      return MAX_AMMO_AWP;
	if (cal == CAL_SPORE)    return MAX_MAG_GRENADELAUNCHER;	// mag-only weapon
	return 0;
};

string(float cal) Ammo_CalibreName =
{
	if (cal == CAL_9MM)      return "9mm";
	if (cal == CAL_357)      return ".357";
	if (cal == CAL_BUCKSHOT) return "buckshot";
	if (cal == CAL_ARGREN)   return "AR grenades";
	if (cal == CAL_ROCKET)   return "rockets";
	if (cal == CAL_URANIUM)  return "uranium";
	if (cal == CAL_BOLT)     return "bolts";
	if (cal == CAL_556)      return "5.56mm";
	if (cal == CAL_762)      return "7.62mm";
	if (cal == CAL_SPORE)    return "spores";
	return "ammo";
};

// ---------------------------------------------------------------------------
// giving
// ---------------------------------------------------------------------------
// Top up every weapon of this calibre the player actually carries, and return how
// much was taken.  HL shares 9mm between the glock and the SMG; this mod's
// separate pools mean "shared" has to become "fill both", which is what
// GoldSrc_Ammo9mm_Touch already did by hand and what this generalises.
// Does the player actually CARRY this weapon?
//
// The reserve system exists for "ammo for a gun you have not found yet", so
// every give has to ask this question first.  The version that shipped never
// did: it topped up any pool sitting below its cap, and a player carrying
// nothing has every pool at 0, which is below the cap.  So the give always
// "succeeded", GoldSrc_Ammo_Touch treated the box as consumed, and the bank
// path underneath it was unreachable - the feature never once ran.
float(entity p, float wep) Ammo_PlayerHas =
{
	if (wep == WEP_NONE)         return FALSE;
	// W_CarryHas covers the multi-carry case: this gate decides whether an ammo
	// box releases its banked reserve, so a cursor-only test would refuse to fill
	// a second primary and bank those rounds forever.
	//
	// The four cursor tests are KEPT as well, and that is not redundancy - it is
	// what makes this strictly more permissive than the code it replaced.  The
	// cursor is set by paths that do not all go through the carry list (map
	// scripts, gamemode loadouts, the ammo self-test's own fixture), and a weapon
	// named by a cursor is owned by definition.  Dropping them made
	// sv_ammo_selftest stage 2 regress from PASS to `want=60 got=10`: the pickup
	// silently banked instead of filling.
	if (W_CarryHas(p, wep))      return TRUE;
	if (p.slot_primary   == wep) return TRUE;
	if (p.slot_secondary == wep) return TRUE;
	if (p.slot_melee     == wep) return TRUE;
	if (p.slot_utility   == wep) return TRUE;
	return FALSE;
};

// Top up one carried weapon's reserve.
//
// READS AND WRITES THE WEAPON'S OWN STORE, not the slot cache.  This function's
// entire job is filling a gun you are NOT holding, and under multi-carry that is
// routinely a different weapon from the one its slot's cursor names - so the old
// canonical read/write topped up the wrong gun in both directions: the rounds
// landed on the held weapon, and the holstered one never saw them.
//
// It used to be the other way round, with a comment arguing the slot fields are
// "the inventory of record".  They are - for the CURSOR.  When a slot could only
// hold one weapon those were the same statement; multi-carry split them.  See
// the data-model block at the top of sh_weapon_slotammo.qc.
//
// W_SlotAmmo_WriteWeapon subsumes the old `if (p.weapon == wep)` special case,
// and fixes it on the way past: the question was never "is it in your hands" but
// "is it this slot's cursor" - a primary can be the cursor while a grenade is in
// hand, and that case wrote the cache and skipped the legacy.
//
// The cap comes from the manifest rather than the weapon file's MAX_AMMO_*
// const, because the manifest row is the copy the slot fields are already
// validated against - and it means a new calibre needs no new cap plumbing.
float(entity p, float wep, float amt) Ammo_TopUpWeapon =
{
	if (!Ammo_PlayerHas(p, wep))   return 0;
	if (!W_SlotAmmo_UsesSlot(wep)) return 0;	// melee/utility keep no reserve

	float cap = WeaponManifest_DefaultAmmo(wep);
	if (cap <= 0) return 0;

	W_SlotAmmo_ReadWeapon(p, wep);
	if (slotammo_ammo >= cap) return 0;

	W_SlotAmmo_WriteWeapon(p, wep, slotammo_mag,
	                       min(cap, slotammo_ammo + amt), slotammo_aux);
	return 1;
};

// The SMG's M203 rounds are the AUX value, not the reserve - a separate pool on
// the same weapon, which is why it cannot go through Ammo_TopUpWeapon.
float(entity p, float wep, float amt) Ammo_TopUpAux =
{
	if (!Ammo_PlayerHas(p, wep))   return 0;
	if (!W_SlotAmmo_UsesSlot(wep)) return 0;

	float cap = WeaponManifest_DefaultAux(wep);
	if (cap <= 0) return 0;

	W_SlotAmmo_ReadWeapon(p, wep);
	if (slotammo_aux >= cap) return 0;

	W_SlotAmmo_WriteWeapon(p, wep, slotammo_mag, slotammo_ammo,
	                       min(cap, slotammo_aux + amt));
	return 1;
};

// Some weapons carry a magazine and no reserve at all - the grenade launcher is
// one (manifest row 6/0/0), and it is what the spore launcher aliases onto.  For
// those the magazine IS the pool, so the rounds have to land there instead.
float(entity p, float wep, float amt) Ammo_TopUpMag =
{
	if (!Ammo_PlayerHas(p, wep))   return 0;
	if (!W_SlotAmmo_UsesSlot(wep)) return 0;

	float cap = WeaponManifest_DefaultMag(wep);
	if (cap <= 0) return 0;

	W_SlotAmmo_ReadWeapon(p, wep);
	if (slotammo_mag >= cap) return 0;

	W_SlotAmmo_WriteWeapon(p, wep, min(cap, slotammo_mag + amt),
	                       slotammo_ammo, slotammo_aux);
	return 1;
};

float(entity p, float cal, float amt) Ammo_GiveToCarried =
{
	float took = 0;

	// Half-Life shares one 9mm pool between the pistol and the SMG; this mod
	// keeps them separate, so "shared" becomes "fill both that you carry".
	if (cal == CAL_9MM)
	{
		if (Ammo_TopUpWeapon(p, WEP_HLGLOCK,   amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_HLSMG,     amt)) took = 1;
		// ...and the UZIs, which are 9mm and are now what weapon_uzi /
		// weapon_uziakimbo actually resolve to.
		if (Ammo_TopUpWeapon(p, WEP_UZI,       amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_UZIAKIMBO, amt)) took = 1;
		return took;
	}
	if (cal == CAL_357)
	{
		if (Ammo_TopUpWeapon(p, WEP_357,   amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_EAGLE, amt)) took = 1;
		return took;
	}
	if (cal == CAL_BUCKSHOT)
	{
		if (Ammo_TopUpWeapon(p, WEP_HLSHOTGUN, amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_ASSHOTGUN, amt)) took = 1;
		return took;
	}
	// Two rifles carry the M203, not one.  sh_wpn_svm16.qc reuses the HL SMG's
	// contact grenade wholesale ("in Half-Life and Sven they are literally the
	// same launcher") but banks it in its own .ammo_svm16_grenades, so an M16
	// carrier who fired both rounds could not be resupplied by the 191
	// ammo_ARgrenades / ammo_mp5grenades placements across 41 maps.  Same "fill
	// both that you carry" shape as CAL_9MM and CAL_556 below.
	if (cal == CAL_ARGREN)
	{
		if (Ammo_TopUpAux(p, WEP_HLSMG, amt)) took = 1;
		if (Ammo_TopUpAux(p, WEP_SVM16, amt)) took = 1;
		return took;
	}
	if (cal == CAL_ROCKET)   return Ammo_TopUpWeapon(p, WEP_HLRPG,      amt);

	// Uranium feeds BOTH energy weapons.  This used to write .ammo_gauss only,
	// so an Egon-only player's cells landed in a field the Egon never reads -
	// and worse, picking up the Egon drained the bank into that same dead field
	// and zeroed it, destroying the reserve outright.
	if (cal == CAL_URANIUM)
	{
		if (Ammo_TopUpWeapon(p, WEP_GAUSS,     amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_HLEGON,    amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_DISPLACER, amt)) took = 1;
		return took;
	}
	if (cal == CAL_BOLT)     return Ammo_TopUpWeapon(p, WEP_CROSSBOW,   amt);

	// Opposing Force's three.  These USED to name only the stand-in each classname
	// was aliased onto, which was correct while the alias was what you could be
	// carrying and became a silent ammo sink the moment the real weapons were
	// promoted in sh_weapon_manifest.qc: a desertcircle player picking up the
	// sniper class banked three ammo_762 into CAL_762, and CAL_762 topped up a CS
	// AWP they did not have.  "Fill both that you carry", the same shape CAL_9MM
	// and CAL_URANIUM already use, because either weapon can legitimately be the
	// one in your hands depending on which classname the map spawned.
	if (cal == CAL_556)
	{
		if (Ammo_TopUpWeapon(p, WEP_M249,    amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_MINIGUN, amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_SVM16,   amt)) took = 1;
		// The OpFor SAW, added with the weapon.  Without this line ammo_556 and
		// ammo_556clip - which is what the GoldSrc maps that place weapon_m249
		// also place next to it - would bank into CAL_556 and top up guns the
		// player is not carrying, which is exactly the silent ammo sink the
		// comment above this block exists to describe.
		if (Ammo_TopUpWeapon(p, WEP_OPSAW,   amt)) took = 1;
		return took;
	}
	if (cal == CAL_762)
	{
		if (Ammo_TopUpWeapon(p, WEP_CSAWP,       amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_SNIPERRIFLE, amt)) took = 1;
		return took;
	}
	// THE SPORE LAUNCHER IS NOT MAGAZINE-ONLY, and treating it as one made its
	// reserve unreachable.  It carries mag 5 / reserve 20 (sh_weapon_manifest.qc:497)
	// and its reload draws from ammo_sporelauncher - but Ammo_TopUpMag only ever
	// fills the MAGAZINE, and caps at WeaponManifest_DefaultMag, so the 20-round
	// reserve could not be refilled by any pickup in the game.  You got five spores
	// and that was the map.  The line above is inherited from when this classname was
	// an alias onto the genuinely magazine-only grenade launcher, which still is one.
	if (cal == CAL_SPORE)
	{
		if (Ammo_TopUpMag(p,    WEP_GRENADELAUNCHER, amt)) took = 1;
		if (Ammo_TopUpWeapon(p, WEP_SPORELAUNCHER,   amt)) took = 1;
		return took;
	}
	return 0;
};

// Throttle for Ammo_TickDrain, below.
.float ammo_next_drain;

// Called when a weapon is picked up: drain whatever was banked for its calibre.
// Exported because the weapon pickup path lives elsewhere.
void(entity p, float cal) Ammo_DrainBank =
{
	float held = Ammo_BankGet(p, cal);
	if (held <= 0)
		return;

	if (Ammo_GiveToCarried(p, cal, held))
	{
		Ammo_BankSet(p, cal, 0);
		sprint(p, PRINT_HIGH, sprintf("Loaded %g reserve %s.\n", held, Ammo_CalibreName(cal)));
	}
};

// Weapon id -> the calibre it eats.  Driven off WEP_* rather than the classname
// so an aliased pickup (weapon_shotgun -> weapon_hlshotgun) resolves the same.
// A weapon with no HL calibre returns 0 and drains nothing.
float(float wep) Ammo_CalibreForWeapon =
{
	if (wep == WEP_HLGLOCK)    return CAL_9MM;
	if (wep == WEP_HLSMG)      return CAL_9MM;
	if (wep == WEP_357)        return CAL_357;
	if (wep == WEP_HLSHOTGUN)  return CAL_BUCKSHOT;
	if (wep == WEP_HLRPG)      return CAL_ROCKET;
	if (wep == WEP_GAUSS)      return CAL_URANIUM;
	if (wep == WEP_HLEGON)     return CAL_URANIUM;
	if (wep == WEP_DISPLACER)  return CAL_URANIUM;
	if (wep == WEP_CROSSBOW)   return CAL_BOLT;
	// The three Opposing Force pools.  weapon_m249 and weapon_sniperrifle both
	// resolve to mod weapons already, so these banks have somewhere to empty
	// into - a calibre with no consumer is just a slow way of deleting ammo.
	if (wep == WEP_M249)            return CAL_556;
	if (wep == WEP_CSAWP)           return CAL_762;
	if (wep == WEP_GRENADELAUNCHER) return CAL_SPORE;
	// The nine promoted out of the alias block.  Each lands on the pool its
	// ROUND belongs to, which is also the pool the maps' own ammo pickups feed:
	// ammo_uziclip and ammo_9mmbox for the UZIs, ammo_556clip for the M16,
	// ammo_762 for the sniper, ammo_357 for the Eagle, ammo_spore for the
	// launcher.  No new CAL_* was needed for any of them.
	if (wep == WEP_UZI)             return CAL_9MM;
	if (wep == WEP_UZIAKIMBO)       return CAL_9MM;
	if (wep == WEP_SVM16)           return CAL_556;
	if (wep == WEP_MINIGUN)         return CAL_556;
	if (wep == WEP_SNIPERRIFLE)     return CAL_762;
	if (wep == WEP_EAGLE)           return CAL_357;
	if (wep == WEP_SPORELAUNCHER)   return CAL_SPORE;
	if (wep == WEP_ASSHOTGUN)       return CAL_BUCKSHOT;
	// The last three OpFor weapons.  The SAW is 5.56 like the M16 and the
	// minigun, so ammo_556 / ammo_556clip feed it with no new calibre.  The knife
	// and the penguin take none: melee has no ammo, and the penguin carries its
	// own creature pool the way the snark does rather than a calibre.
	if (wep == WEP_OPSAW)           return CAL_556;
	return 0;
};

// Called from weapon_touch the instant a weapon is added to a slot.
void(entity p, float wep) Ammo_DrainForWeapon =
{
	float cal = Ammo_CalibreForWeapon(wep);
	if (cal)
		Ammo_DrainBank(p, cal);

	// The SMG carries a second, separate pool for its M203 rounds, so picking one
	// up must release BOTH banks.  Missing this is the kind of gap that looks like
	// the reserve is broken when only one calibre of it is.
	if (wep == WEP_HLSMG)
		Ammo_DrainBank(p, CAL_ARGREN);
};

// Release banked rounds into a gun that has since made room for them.
//
// Ammo_DrainForWeapon only fires at the instant a weapon is picked up, and map
// weapons always spawn at MAX_AMMO - so a player who banked rounds first and
// found the gun second had the drain correctly refused for being full, and the
// bank was then stranded with no second chance at it.  Firing is what makes the
// room, so the release has to be able to happen later than the pickup.
//
// Only the held weapon, and throttled to once a second: this runs per player per
// frame, and the overwhelmingly common case (an empty bank) costs one float
// compare.  Switching to a gun makes it the held weapon, so a full inventory
// still drains within a second of the player showing interest in it.
void(entity p) Ammo_TickDrain =
{
	if (time < p.ammo_next_drain)
		return;
	p.ammo_next_drain = time + 1;

	float cal = Ammo_CalibreForWeapon(p.weapon);
	if (cal)
		Ammo_DrainBank(p, cal);
	if (p.weapon == WEP_HLSMG)
		Ammo_DrainBank(p, CAL_ARGREN);
};

// The pickup itself.
.float ammo_calibre;
.float ammo_amount;

void() GoldSrc_Ammo_Touch =
{
	if (other.classname != "player" || other.health <= 0)
		return;

	float cal = self.ammo_calibre;
	float amt = self.ammo_amount;

	// Straight into the gun if it is carried and not full.
	if (Ammo_GiveToCarried(other, cal, amt))
	{
		sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
		GoldSrc_PickupTaken(other);
		return;
	}

	// Otherwise bank it - unless the bank is already full, in which case leave
	// the pickup on the floor for someone who can use it.  Refusing rather than
	// silently deleting matters in co-op: a full player walking over a crate must
	// not destroy it for the teammate behind them.
	float cap  = Ammo_CalibreMax(cal);
	float held = Ammo_BankGet(other, cal);
	if (held >= cap)
		return;

	Ammo_BankSet(other, cal, min(cap, held + amt));
	sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
	sprint(other, PRINT_HIGH, sprintf("Picked up %g %s (no weapon for it yet - held in reserve).\n",
	                                  amt, Ammo_CalibreName(cal)));
	GoldSrc_PickupTaken(other);
};

void(string mdl, float cal, float amt) GoldSrc_AmmoSpawn =
{
	self.ammo_calibre = cal;
	self.ammo_amount  = amt;
	// Governed by mp_ammo_respawndelay rather than mp_item_respawndelay.  These
	// share GoldSrc_PickupTaken with the items, so the only thing telling the
	// two apart is this field.
	self.pickup_kind  = PICKUP_KIND_AMMO;
	GoldSrc_SpawnPickup(mdl, GoldSrc_Ammo_Touch);
};

// ---------------------------------------------------------------------------
// the classes
// ---------------------------------------------------------------------------
// Amounts are Half-Life's own (the AmmoAmount passed to AddAmmo in each
// CBasePlayerAmmo subclass), models are the mounted originals.
//
// spawnfunc_ prefix on the .357 one only, mirroring the existing convention in
// sv_goldsrc_compat.qc: `ammo_357` would otherwise collide with the `.float
// ammo_357` field the revolver declares, and QC has one namespace for both.
void() spawnfunc_ammo_357        = { GoldSrc_AmmoSpawn("models/w_357ammobox.mdl", CAL_357,      6); };
void() ammo_buckshot             = { GoldSrc_AmmoSpawn("models/w_shotbox.mdl",    CAL_BUCKSHOT, 12); };
void() ammo_rpgclip              = { GoldSrc_AmmoSpawn("models/w_rpgammo.mdl",    CAL_ROCKET,   1); };
void() ammo_ARgrenades           = { GoldSrc_AmmoSpawn("models/w_ARgrenade.mdl",  CAL_ARGREN,   2); };
void() ammo_gaussclip            = { GoldSrc_AmmoSpawn("models/w_gaussammo.mdl",  CAL_URANIUM,  20); };
// spawnfunc_ too: .float ammo_crossbow is the crossbow's own ammo FIELD, and QC
// puts fields and functions in one namespace, so a bare `void() ammo_crossbow`
// is a redeclaration rather than a spawn function.  Exactly the trap the
// existing note in sv_goldsrc_compat.qc warns about.
void() spawnfunc_ammo_crossbow   = { GoldSrc_AmmoSpawn("models/w_crossbow_clip.mdl", CAL_BOLT,  5); };

// Sven / HL aliases for the same pools.  Named separately rather than folded in,
// because a map that spawns "ammo_egonclip" expects a gauss/egon pickup and there
// is no reason to make it look like a different item.
void() ammo_egonclip             = { GoldSrc_AmmoSpawn("models/w_chainammo.mdl",  CAL_URANIUM,  20); };
void() ammo_glockclip            = { GoldSrc_AmmoSpawn("models/w_9mmclip.mdl",    CAL_9MM,      17); };
void() ammo_mp5clip              = { GoldSrc_AmmoSpawn("models/w_9mmarclip.mdl",  CAL_9MM,      50); };
void() ammo_mp5grenades          = { GoldSrc_AmmoSpawn("models/w_ARgrenade.mdl",  CAL_ARGREN,   2); };

// The two that used to live in sv_goldsrc_compat.qc as the only working ammo
// classes.  Amounts are the ones that shipped (100 / 34), not HL's, because those
// are the numbers this mod has been balanced against.
void() spawnfunc_ammo_9mmbox     = { GoldSrc_AmmoSpawn("models/w_9mmclip.mdl",    CAL_9MM,      100); };
void() spawnfunc_ammo_9mmclip    = { GoldSrc_AmmoSpawn("models/w_9mmclip.mdl",    CAL_9MM,      34); };

// ammo_9mmAR - Half-Life's OWN second classname for ammo_mp5clip (mp5.cpp links
// both to CMP5AmmoClip), and by placement count the biggest single hole this mod
// had: 151 in valve, 136 in gearbox, 7 in bshift, 11 in They Hunger.  305 across
// 73 maps, the second most placed pickup in Half-Life, and it was landing in
// SV_OnEntityNoSpawnFunction.  Note the capitals - the classname really is
// "9mmAR" and the BSP must match exactly.
void() ammo_9mmAR                = { GoldSrc_AmmoSpawn("models/w_9mmarclip.mdl",  CAL_9MM,      50); };
// One placement, one valve map, and it is a mapper typo: no such classname exists
// in Half-Life either, so it was inert there too.  Costs a line to honour.
void() ammo_9mmARclip            = { GoldSrc_AmmoSpawn("models/w_9mmarclip.mdl",  CAL_9MM,      50); };

// ---------------------------------------------------------------------------
// Opposing Force
// ---------------------------------------------------------------------------
// Models are the FGD's, not the ones the classname suggests - w_saw_clip and
// w_m40a1clip, NOT the "w_556ammobox"/"w_762ammobox" a reasonable person would
// guess.  Both guesses were wrong and both were checked against the mount.
//
// Amounts follow the mod's convention of sizing to the gun rather than copying
// numbers this machine has no SDK to read: a 556 box is two thirds of the M249's
// 150, a 762 magazine is half the AWP's 20, and a spore is one grenade.
void() ammo_556                  = { GoldSrc_AmmoSpawn("models/w_saw_clip.mdl",   CAL_556,      100); };
void() ammo_762                  = { GoldSrc_AmmoSpawn("models/w_m40a1clip.mdl",  CAL_762,      10); };
void() ammo_spore                = { GoldSrc_AmmoSpawn("models/spore_ammo.mdl",   CAL_SPORE,    1); };
void() ammo_sporeclip            = { GoldSrc_AmmoSpawn("models/spore.mdl",        CAL_SPORE,    1); };
// Sven's name for the M16 magazine, same 5.56 pool.
void() ammo_556clip              = { GoldSrc_AmmoSpawn("models/w_9mmARclip.mdl",  CAL_556,      20); };

// ---------------------------------------------------------------------------
// Sven Co-op
// ---------------------------------------------------------------------------
// ammo_uziclip (sven-coop.fgd:1493, "9mm Uzi magazine") was the ONLY class in
// the FGD's ammo list with no handler at all - it fell straight into
// SV_OnEntityNoSpawnFunction.  It had nothing to feed until this pass, because
// weapon_uzi was an alias onto a CrossFire MAC-10 drawing from a different pool.
void() ammo_uziclip              = { GoldSrc_AmmoSpawn("models/w_uzi_clip.mdl",   CAL_9MM,      32); };

// ---------------------------------------------------------------------------
// GoldSrc_GiveByClassname — Half-Life's GiveNamedItem, for the entities that
// hand out items by CLASSNAME STRING rather than by a pickup you walk over.
// ---------------------------------------------------------------------------
// HL does this by spawning the real pickup entity at the player's feet, marking
// it SF_NORESPAWN and dispatching its own Touch (dlls/player.cpp:3472-3489).
// That one trick is why every classname "just works" there, and it is why
// game_player_equip needs no per-item knowledge at all.
//
// This mod could not do the same: GamePlayerEquip_Apply only ever understood
// weapon manifest names and item_longjump, so `ammo_*` and every other `item_*`
// were captured onto the gpe_item chain and then silently dropped.
// desertcircle's ammo crates are three keys - ammo_9mmbox, ammo_762,
// item_healthkit - and ALL THREE were being discarded, so the crate would have
// given nothing even once its button was reachable.  The map's two class-select
// booths were quietly losing their ammo lines the same way.
//
// The calibre/amount table below is NOT a new one: it is the same pairing the
// spawn functions above use, kept adjacent to them on purpose so the two cannot
// drift.  Do NOT be tempted to call MapCfgEquip_AmmoCalibre instead - that is
// keyed on the map-CFG noun namespace (`ammo_9mm`, `ammo_556`) and misses
// ammo_9mmbox / ammo_9mmclip / ammo_9mmAR / ammo_buckshot entirely.
//
// Lives HERE rather than beside game_player_equip because sv_goldsrc_entities.qc
// compiles first (sv_progs.src:311 vs :345) and QC forward-declares functions but
// not constants or fields - so the CAL_* constants and the ammo bank can only be
// named from this side.  Exactly the inverse of GoldSrc_GrantItemClass.
float gs_give_amount;      // out-param of GoldSrc_AmmoClassCalibre

float(string cls) GoldSrc_AmmoClassCalibre =
{
    gs_give_amount = 0;
         if (cls == "ammo_9mmbox")     { gs_give_amount = 100; return CAL_9MM;      }
    else if (cls == "ammo_9mmclip")    { gs_give_amount = 34;  return CAL_9MM;      }
    else if (cls == "ammo_glockclip")  { gs_give_amount = 17;  return CAL_9MM;      }
    else if (cls == "ammo_mp5clip")    { gs_give_amount = 50;  return CAL_9MM;      }
    else if (cls == "ammo_9mmAR")      { gs_give_amount = 50;  return CAL_9MM;      }
    else if (cls == "ammo_9mmARclip")  { gs_give_amount = 50;  return CAL_9MM;      }
    else if (cls == "ammo_uziclip")    { gs_give_amount = 32;  return CAL_9MM;      }
    else if (cls == "ammo_357")        { gs_give_amount = 6;   return CAL_357;      }
    else if (cls == "ammo_buckshot")   { gs_give_amount = 12;  return CAL_BUCKSHOT; }
    else if (cls == "ammo_rpgclip")    { gs_give_amount = 1;   return CAL_ROCKET;   }
    else if (cls == "ammo_ARgrenades") { gs_give_amount = 2;   return CAL_ARGREN;   }
    else if (cls == "ammo_mp5grenades"){ gs_give_amount = 2;   return CAL_ARGREN;   }
    else if (cls == "ammo_gaussclip")  { gs_give_amount = 20;  return CAL_URANIUM;  }
    else if (cls == "ammo_egonclip")   { gs_give_amount = 20;  return CAL_URANIUM;  }
    else if (cls == "ammo_crossbow")   { gs_give_amount = 5;   return CAL_BOLT;     }
    else if (cls == "ammo_556")        { gs_give_amount = 100; return CAL_556;      }
    else if (cls == "ammo_556clip")    { gs_give_amount = 20;  return CAL_556;      }
    else if (cls == "ammo_762")        { gs_give_amount = 10;  return CAL_762;      }
    else if (cls == "ammo_spore")      { gs_give_amount = 1;   return CAL_SPORE;    }
    else if (cls == "ammo_sporeclip")  { gs_give_amount = 1;   return CAL_SPORE;    }
    return 0;
};

// Returns TRUE if the classname was recognised and consumed.  `qty` is HL's
// max(1, atoi(value)) repeat count - it multiplies the amount rather than
// looping the give, which is equivalent for ammo and health and much cheaper.
float(entity plyr, string cls, float qty) GoldSrc_GiveByClassname =
{
    if (!plyr || plyr.classname != "player" || cls == "")
        return FALSE;
    if (qty < 1)
        qty = 1;

    float cal = GoldSrc_AmmoClassCalibre(cls);
    if (cal)
    {
        float amt = gs_give_amount * qty;
        // Carried guns first, bank the remainder - the same two-step every ammo
        // pickup in this file already does (GoldSrc_Ammo_Touch below).
        if (!Ammo_GiveToCarried(plyr, cal, amt))
        {
            float cap  = Ammo_CalibreMax(cal);
            float held = Ammo_BankGet(plyr, cal);
            if (held < cap)
                Ammo_BankSet(plyr, cal, min(cap, held + amt));
        }
        return TRUE;
    }

    if (cls == "item_healthkit")
    {
        plyr.health = min(100, plyr.health + HEALTHKIT_AMOUNT * qty);
        return TRUE;
    }
    if (cls == "item_battery")
    {
        plyr.armor = min(SUIT_ARMOR_MAX, plyr.armor + BATTERY_ARMOR_GRANT * qty);
        return TRUE;
    }
    if (cls == "item_suit")
    {
        // Sets the bit even at full armour, matching GoldSrc_Suit_Touch.
        plyr.has_suit = TRUE;
        plyr.armor    = min(SUIT_ARMOR_MAX, plyr.armor + SUIT_ARMOR_GRANT);
        return TRUE;
    }
    if (cls == "item_longjump")
    {
        plyr.pm_longjump = 1;
        return TRUE;
    }

    return FALSE;
};

// ---------------------------------------------------------------------------
// weaponbox — Sven's ammo container
// ---------------------------------------------------------------------------
// A bag of per-pool quantities, and it maps onto the reserve bank so exactly
// that it is barely any code: every key is a calibre and a count, which is what
// a bank IS.  28 placements in pizza_ya_san2, all identical (9mm 400, buckshot
// 100, uranium 100, 5.56 100, everything else zero).
//
// The four weapon-carrying keys grant the weapon rather than ammo, and all four
// of those weapons exist in this mod.
void(entity plyr, float cal, float amt) WeaponBox_Give =
{
	if (amt <= 0)
		return;

	// Into the guns first, remainder to the bank - the same two-step every ammo
	// pickup uses, so a box behaves like the boxes it is standing in for.
	if (Ammo_GiveToCarried(plyr, cal, amt))
		return;

	float cap  = Ammo_CalibreMax(cal);
	float held = Ammo_BankGet(plyr, cal);
	if (held >= cap)
		return;
	Ammo_BankSet(plyr, cal, min(cap, held + amt));
};

void() WeaponBox_Touch =
{
	if (other.classname != "player" || other.health <= 0)
		return;

	WeaponBox_Give(other, CAL_9MM,      self.wbox_9mm);
	WeaponBox_Give(other, CAL_357,      self.wbox_357);
	WeaponBox_Give(other, CAL_BUCKSHOT, self.wbox_buckshot);
	WeaponBox_Give(other, CAL_BOLT,     self.wbox_bolts);
	WeaponBox_Give(other, CAL_556,      self.wbox_556);
	WeaponBox_Give(other, CAL_ARGREN,   self.wbox_argren);
	WeaponBox_Give(other, CAL_ROCKET,   self.wbox_rockets);
	WeaponBox_Give(other, CAL_URANIUM,  self.wbox_uranium);
	WeaponBox_Give(other, CAL_762,      self.wbox_762);
	WeaponBox_Give(other, CAL_SPORE,    self.wbox_spore);

	// W_GiveWeaponToSlot works on `self`, so the box has to step aside and hand
	// the player the microphone - hence reading the counts off `saved`.
	entity saved = self;
	self = other;
	if (saved.wbox_handgrenade > 0) W_GiveWeaponToSlot(WEP_HLGRENADE);
	if (saved.wbox_satchel     > 0) W_GiveWeaponToSlot(WEP_SATCHEL);
	if (saved.wbox_tripmine    > 0) W_GiveWeaponToSlot(WEP_TRIPMINE);
	if (saved.wbox_snarks      > 0) W_GiveWeaponToSlot(WEP_SNARK);
	self = saved;

	sound(other, CHAN_ITEM, SND_ITEM_PICKUP, 1, ATTN_NORM);
	sprint(other, PRINT_HIGH, "Picked up a weapon box.\n");
	GoldSrc_PickupTaken(other);
};

void() weaponbox =
{
	GoldSrc_SpawnPickup("models/w_weaponbox.mdl", WeaponBox_Touch);
};

// ===========================================================================
//  func_breakable "spawnobject" — the item a crate leaves behind
// ===========================================================================
//
// GoldSrc's func_breakable carries a `spawnobject` key: an index into a fixed
// table of pickups, dropped at the brush centre when it breaks.  This mod
// parsed the key and threw it away, and sv_func_pushable.qc:64 said why -
// "need systems this mod does not have (... item spawning ...)".
//
// THAT IS NO LONGER TRUE.  Every one of the 39 table entries now has a spawn
// function, so the key is implementable as a straight dispatch.  Volume: 202
// placements across the 36 Sven hl_ maps alone, led by Healthkit (45),
// Battery (39), Machine Gun Clip (17) and Tripmine (15) - which is why
// breaking crates in the campaign produced nothing but debris.
//
// This lives at the END of the pickup files on purpose.  sv_breakable.qc
// compiles at position 28 and the spawn functions it needs are spread from 42
// (shared/weapons) to 228 (sv_goldsrc_pickups.qc), so the dispatch has to sit
// after all of them and be forward-declared back to the breakable.
//
// The index numbers are the FGD's, not Half-Life's - Sven extends the stock
// table past 22 with the Opposing Force and Sven guns.  Read
// svencoop/sven-coop.fgd if a new one appears; do not infer it.

// The classname each index spawns under.  Kept beside the dispatch so the two
// cannot drift apart, and used for the entity's own .classname (see below).
string(float idx) Breakable_ObjectName =
{
	     if (idx == 1)  return "item_battery";
	else if (idx == 2)  return "item_healthkit";
	else if (idx == 3)  return "weapon_9mmhandgun";
	else if (idx == 4)  return "ammo_9mmclip";
	else if (idx == 5)  return "weapon_9mmAR";
	else if (idx == 6)  return "ammo_9mmAR";
	else if (idx == 7)  return "ammo_ARgrenades";
	else if (idx == 8)  return "weapon_shotgun";
	else if (idx == 9)  return "ammo_buckshot";
	else if (idx == 10) return "weapon_crossbow";
	else if (idx == 11) return "ammo_crossbow";
	else if (idx == 12) return "weapon_357";
	else if (idx == 13) return "ammo_357";
	else if (idx == 14) return "weapon_rpg";
	else if (idx == 15) return "ammo_rpgclip";
	else if (idx == 16) return "ammo_gaussclip";
	else if (idx == 17) return "weapon_handgrenade";
	else if (idx == 18) return "weapon_tripmine";
	else if (idx == 19) return "weapon_satchel";
	else if (idx == 20) return "weapon_snark";
	else if (idx == 21) return "weapon_hornetgun";
	else if (idx == 22) return "weapon_crowbar";
	else if (idx == 23) return "weapon_pipewrench";
	else if (idx == 24) return "weapon_sniperrifle";
	else if (idx == 25) return "ammo_762";
	else if (idx == 26) return "weapon_m16";
	else if (idx == 27) return "weapon_m249";
	else if (idx == 28) return "weapon_minigun";
	else if (idx == 29) return "ammo_556";
	else if (idx == 30) return "weapon_sporelauncher";
	else if (idx == 31) return "ammo_spore";
	else if (idx == 32) return "ammo_9mmbox";
	else if (idx == 33) return "weapon_uzi";
	else if (idx == 34) return "weapon_uziakimbo";
	else if (idx == 35) return "weapon_eagle";
	else if (idx == 36) return "weapon_grapple";
	else if (idx == 37) return "weapon_medkit";
	else if (idx == 38) return "item_suit";
	else if (idx == 39) return "item_antidote";
	return "";
};

// The last object this made, for the one caller that needs to keep hold of it.
// squadmaker stamps its own id on a dispensed item so its live-child cap can be
// counted; a return value would be cleaner but this function is called from six
// places that all ignore it, and widening the signature for one of them is not.
entity breakable_last_object;

void(vector org, float idx) Breakable_SpawnObject =
{
	breakable_last_object = world;
	if (idx <= 0 || idx > 39)
		return;

	// mp_nomapweapons is a deliberate strip in paintgun and prophunt, where
	// the whole point is that nobody arms themselves mid-round.  A crate is
	// just another way to arm yourself, so weapons obey it - but health,
	// armour and ammo do not, exactly as map-placed ammo does not.
	float strip = (cvar("mp_nomapweapons") > 0);
	float is_weapon =
		(idx == 3)  || (idx == 5)  || (idx == 8)  || (idx == 10) ||
		(idx == 12) || (idx == 14) || (idx == 17) || (idx == 18) ||
		(idx == 19) || (idx == 20) || (idx == 21) || (idx == 22) ||
		(idx == 23) || (idx == 24) || (idx == 26) || (idx == 27) ||
		(idx == 28) || (idx == 30) || (idx == 33) || (idx == 34) ||
		(idx == 35) || (idx == 36) || (idx == 37);
	if (strip && is_weapon)
		return;

	entity it    = spawn();
	entity saved = self;
	self = it;
	// Origin before the dispatch: the spawn functions setmodel/setsize and
	// (for weapons) floor-snap against wherever the entity already is.
	setorigin(self, org);

	// Classname before the dispatch, because the ammo and item spawn functions
	// do NOT set one - GoldSrc_SpawnPickup only does model/size/solid/touch,
	// and a map-placed pickup gets its classname from the entity lump instead.
	// A synthetic spawn has no lump, so without this the crate drops a working
	// but anonymous entity: it can be picked up, but nothing that keys on
	// classname can see it, including W_RespawnMapWeapons' cleanup.
	// The weapon spawn functions set their own and will overwrite this with
	// the identical string.
	self.classname = Breakable_ObjectName(idx);

	     if (idx == 1)  item_battery();
	else if (idx == 2)  item_healthkit();
	else if (idx == 3)  weapon_9mmhandgun();
	else if (idx == 4)  spawnfunc_ammo_9mmclip();
	else if (idx == 5)  weapon_9mmAR();
	else if (idx == 6)  ammo_9mmAR();
	else if (idx == 7)  ammo_ARgrenades();
	else if (idx == 8)  weapon_shotgun();
	else if (idx == 9)  ammo_buckshot();
	else if (idx == 10) weapon_crossbow();
	else if (idx == 11) spawnfunc_ammo_crossbow();
	else if (idx == 12) weapon_357();
	else if (idx == 13) spawnfunc_ammo_357();
	else if (idx == 14) weapon_rpg();
	else if (idx == 15) ammo_rpgclip();
	else if (idx == 16) ammo_gaussclip();
	else if (idx == 17) weapon_handgrenade();
	else if (idx == 18) weapon_tripmine();
	else if (idx == 19) weapon_satchel();
	else if (idx == 20) weapon_snark();
	else if (idx == 21) weapon_hornetgun();
	else if (idx == 22) weapon_crowbar();
	else if (idx == 23) weapon_pipewrench();
	else if (idx == 24) weapon_sniperrifle();
	else if (idx == 25) ammo_762();
	else if (idx == 26) weapon_m16();
	else if (idx == 27) weapon_m249();
	else if (idx == 28) weapon_minigun();
	else if (idx == 29) ammo_556();
	else if (idx == 30) weapon_sporelauncher();
	else if (idx == 31) ammo_spore();
	else if (idx == 32) spawnfunc_ammo_9mmbox();
	else if (idx == 33) weapon_uzi();
	else if (idx == 34) weapon_uziakimbo();
	else if (idx == 35) weapon_eagle();
	else if (idx == 36) weapon_grapple();
	else if (idx == 37) weapon_medkit();
	else if (idx == 38) item_suit();
	else                item_antidote();

	self = saved;

	// A crate drop is NOT a map weapon.  W_RegisterMapWeapon stamped
	// .map_weapon on the way through, and W_RespawnMapWeapons re-runs the
	// stored spawn function for anything carrying it (sv_weapons.qc:562) -
	// so leaving it set would put the gun back every round restart while the
	// breakable round-reset ALSO restores the intact crate, and the map would
	// gain a free weapon per round forever.  Cleared, the same function
	// removes it at restart (sv_weapons.qc:615) which is what a dropped item
	// should do.
	it.map_weapon       = 0;
	it.map_weapon_spawn = __NULL__;
	// ...and it must not enter the RESPAWN path either, for the same reason one
	// step further: mp_weapon_respawndelay would otherwise put a fresh gun back
	// on the crate's spot on a timer, which is the free-weapon-per-round bug
	// again without even needing a round to pass.  Both halves of the non-weapon
	// revive are cleared too, so Pickup_RespawnThink cannot resurrect it from
	// the model/touch pair.
	it.pickup_respawn_at = 0;
	it.pickup_model      = "";
	it.pickup_touch      = __NULL__;
	it.spawnflags        = it.spawnflags | PICKUP_SF_NO_RESPAWN;

	breakable_last_object = it;
};

// ---------------------------------------------------------------------------
//  squadmaker as an item dispenser
// ---------------------------------------------------------------------------
// 44 of pizza_ya_san1's 97 squadmakers name an AMMO or WEAPON classname in
// `monstertype` rather than a monster, which is Sven's ordinary idiom for a
// resupply crate you cannot break: ammo_9mmbox x9, ammo_buckshot x8, ammo_556 x7,
// ammo_rpgclip x7, ammo_ARgrenades x5, item_healthkit x4, plus four guns.  It is
// the entire resupply for the radar sequence and the shop siege, and it produced
// nothing at all - Monster_Spawn only ever builds a monster body, so the class
// gate in squadmaker_spawn_one dropped every one of them.
//
// Lives HERE rather than in sv_monsters.qc because the spawn functions it needs
// are all in this file and QC cannot forward-declare its way to 39 of them;
// squadmaker reaches it through one forward-declared entry point, the same way
// sv_monsters.qc reaches AI_Spawn.
//
// The index comes from Breakable_ObjectName run BACKWARDS rather than from a
// second hand-written table.  That is deliberate: a parallel table is a thing
// that silently stops agreeing, and this one cannot - a classname added to the
// dispatcher is reachable here on the same commit.
float(string cls) Squadmaker_ItemIndex =
{
	if (cls == "" || !cls)
		return 0;

	// Sven's map-script weapons, which the map's own pizza_ya_san.as remaps the
	// same way: weapon_as_shotgun IS the shotgun, registered under a script name.
	//
	// The comment that used to sit here said weapon_as_soflam had "no counterpart
	// in this mod at all".  That stopped being true when sh_wpn_assoflam.qc was
	// written - the SOFLAM is a full weapon with a manifest entry (WEP_ASSOFLAM)
	// and a spawn function - but the note stayed, and with it the behaviour: the
	// one squadmaker on pizza_ya_san2 that dispenses it (ml_secretwep_2, the map's
	// secret weapon) produced nothing.  Resolved through the weapon manifest by
	// Squadmaker_ManifestWeaponId below rather than by adding another special
	// case here, so this cannot go stale a second time.
	if (cls == "weapon_as_shotgun")
		cls = "weapon_shotgun";

	float i;
	for (i = 1; i <= 39; i = i + 1)
		if (Breakable_ObjectName(i) == cls)
			return i;
	return 0;
};

// A squadmaker monstertype that names a weapon the MANIFEST knows but the HL
// object table above does not.  That table is Half-Life's 39 pickup classes; a
// mod weapon (the SOFLAM, the jetpack, They Hunger's eight, the CrossFire set)
// has no index in it and never will, yet a map is perfectly entitled to name one
// as a squadmaker's monstertype.
//
// Resolved through the same manifest lookup game_player_equip uses, so every
// weapon in the mod is reachable and no per-weapon list exists here to rot.
// Returns WEP_NONE for anything that is not a weapon classname.
float(string cls) Squadmaker_ManifestWeaponId =
{
	if (substring(cls, 0, 7) != "weapon_")
		return WEP_NONE;
	// WeaponManifest_NameKey strips underscores, so "as_soflam" folds onto the
	// "assoflam" key that sh_weapon_manifest.qc:683 already answers to.
	return Weapon_IdFromStringOrDefault(substring(cls, 7, strlen(cls) - 7), WEP_NONE);
};

// TRUE if `cls` names something this file can produce.  Asked before anything is
// spawned, so squadmaker can tell "an item" from "a monster it has no AI for".
float(string cls) Squadmaker_IsItem =
{
	if (Squadmaker_ItemIndex(cls) > 0)
		return TRUE;
	return Squadmaker_ManifestWeaponId(cls) != WEP_NONE;
};

entity(string cls, vector org) Squadmaker_SpawnItem =
{
	float idx = Squadmaker_ItemIndex(cls);
	float wid;

	if (idx > 0)
	{
		Breakable_SpawnObject(org, idx);
		return breakable_last_object;
	}

	// Mod weapon with no HL object index.  SV_DebugSpawnWeaponId owns the full
	// id -> spawn-function dispatch (and the slot-ammo seeding a raw spawn call
	// would skip), so route through it and pick the result back up from the
	// handle it publishes.  "Debug" is a misnomer of history: it is simply the
	// place a weapon gets put on the floor by id.
	wid = Squadmaker_ManifestWeaponId(cls);
	if (wid == WEP_NONE)
		return world;

	sv_last_spawned_weapon = world;
	SV_DebugSpawnWeaponId(org, wid);
	return sv_last_spawned_weapon;
};
