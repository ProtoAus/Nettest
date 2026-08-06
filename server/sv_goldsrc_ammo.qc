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

// The reserves.  Separate fields rather than an array because QC arrays cannot
// be entity fields, and seven floats is cheaper than the indirection would be.
.float bank_9mm;
.float bank_357;
.float bank_buckshot;
.float bank_argren;
.float bank_rocket;
.float bank_uranium;
.float bank_bolt;

float(entity p, float cal) Ammo_BankGet =
{
	if (cal == CAL_9MM)      return p.bank_9mm;
	if (cal == CAL_357)      return p.bank_357;
	if (cal == CAL_BUCKSHOT) return p.bank_buckshot;
	if (cal == CAL_ARGREN)   return p.bank_argren;
	if (cal == CAL_ROCKET)   return p.bank_rocket;
	if (cal == CAL_URANIUM)  return p.bank_uranium;
	if (cal == CAL_BOLT)     return p.bank_bolt;
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
};

// The cap for a calibre is the cap of the weapon that eats it, so a reserve can
// never hold more than the gun could.
float(float cal) Ammo_CalibreMax =
{
	if (cal == CAL_9MM)      return MAX_AMMO_HLSMG;		// the larger of glock/SMG
	if (cal == CAL_357)      return MAX_AMMO_357;
	if (cal == CAL_BUCKSHOT) return MAX_AMMO_SHOTGUN;
	if (cal == CAL_ARGREN)   return MAX_AMMO_HLSMG_GRENADES;
	if (cal == CAL_ROCKET)   return MAX_AMMO_HLRPG;
	if (cal == CAL_URANIUM)  return MAX_AMMO_GAUSS;
	if (cal == CAL_BOLT)     return MAX_AMMO_CROSSBOW;
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
	return "ammo";
};

// ---------------------------------------------------------------------------
// giving
// ---------------------------------------------------------------------------
// Top up every weapon of this calibre the player actually carries, and return how
// much was taken.  HL shares 9mm between the glock and the SMG; this mod's
// separate pools mean "shared" has to become "fill both", which is what
// GoldSrc_Ammo9mm_Touch already did by hand and what this generalises.
float(entity p, float cal, float amt) Ammo_GiveToCarried =
{
	float took = 0;

	if (cal == CAL_9MM)
	{
		if (p.ammo_hlglock < MAX_AMMO_HLGLOCK)
		{
			p.ammo_hlglock = min(MAX_AMMO_HLGLOCK, p.ammo_hlglock + amt);
			took = 1;
		}
		if (p.ammo_hlsmg < MAX_AMMO_HLSMG)
		{
			p.ammo_hlsmg = min(MAX_AMMO_HLSMG, p.ammo_hlsmg + amt);
			took = 1;
		}
		return took;
	}
	if (cal == CAL_357)
	{
		if (p.ammo_357 >= MAX_AMMO_357) return 0;
		p.ammo_357 = min(MAX_AMMO_357, p.ammo_357 + amt);
		return 1;
	}
	if (cal == CAL_BUCKSHOT)
	{
		if (p.ammo_shotgun >= MAX_AMMO_SHOTGUN) return 0;
		p.ammo_shotgun = min(MAX_AMMO_SHOTGUN, p.ammo_shotgun + amt);
		return 1;
	}
	if (cal == CAL_ARGREN)
	{
		if (p.ammo_hlsmg_grenades >= MAX_AMMO_HLSMG_GRENADES) return 0;
		p.ammo_hlsmg_grenades = min(MAX_AMMO_HLSMG_GRENADES, p.ammo_hlsmg_grenades + amt);
		return 1;
	}
	if (cal == CAL_ROCKET)
	{
		if (p.ammo_hlrpg >= MAX_AMMO_HLRPG) return 0;
		p.ammo_hlrpg = min(MAX_AMMO_HLRPG, p.ammo_hlrpg + amt);
		return 1;
	}
	if (cal == CAL_URANIUM)
	{
		if (p.ammo_gauss >= MAX_AMMO_GAUSS) return 0;
		p.ammo_gauss = min(MAX_AMMO_GAUSS, p.ammo_gauss + amt);
		return 1;
	}
	if (cal == CAL_BOLT)
	{
		if (p.ammo_crossbow >= MAX_AMMO_CROSSBOW) return 0;
		p.ammo_crossbow = min(MAX_AMMO_CROSSBOW, p.ammo_crossbow + amt);
		return 1;
	}
	return 0;
};

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
	if (wep == WEP_CROSSBOW)   return CAL_BOLT;
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
