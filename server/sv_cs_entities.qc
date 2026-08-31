// server/sv_cs_entities.qc
// ----------------------------------------------------------------------------
// Counter-Strike point entities.
//
// Only one so far, but it is the one that matters: armoury_entity is how a CS
// map puts a gun on the ground.  Every weapon_* classname the mod already
// answers is the SECOND way, and it is the rarer one by two orders of magnitude.
//
// Measured over the 184 Counter-Strike maps on this machine
// (Half-Life/cstrike/maps + cstrike_downloads/maps, entity lumps parsed
// statically):
//
//   armoury_entity   1802 placements / 152 maps
//   weapon_*           35 placements /   4 maps
//
// So before this file existed, essentially every ground weapon in the CS corpus
// was an entity with no spawn function - the guns were integrated, and nothing
// placed them.  That is the reported "they are not spawning in on maps".
//
// The stock 33-map CS set barely uses it (2 placements, de_storm and de_torn)
// because in real Counter-Strike you BUY your gun; it is the community maps -
// deathrun, awp_, fy_, aim_, surf_ - that hand them out, and those are 1800 of
// the 1802.  A single deathrun map routinely carries 20-40 of them.
// ----------------------------------------------------------------------------

// The CS "Item" key.  Declared lowercase because ED_FindField is a plain
// strcmp against the name in the BSP, and the BSP spells it "item".
//
// DEFAULTS TO 0 = weapon_mp5navy, WHICH IS LOAD-BEARING RATHER THAN INCIDENTAL:
// 393 of the 1802 placements carry no `item` key at all, and CS spawns the MP5
// for those.  A field left at 0 lands on the right weapon by itself, so there is
// no "was the key present" question to answer.
.float item;

// `count` is already declared by sv_triggers.qc (trigger_counter's "Count before
// activation").  The classnames are disjoint, so one field serves both.
//
// No forward declarations for the weapon spawn functions: sv_progs.src compiles
// every shared/weapons/ file around line 45-65, several hundred lines before
// this one, so they are all already defined by the time this file is read.

// ---------------------------------------------------------------------------
// item_kevlar / item_assaultsuit
// ---------------------------------------------------------------------------
// CS body armour.  This mod has no separate armour TYPE - .armor is one 0..100
// pool shared with the HEV suit - so both grant into that pool at CS's own
// values (CS gives 100 armour, and SUIT_ARMOR_MAX is 100).
//
// DELIBERATE DIVERGENCE, stated rather than hidden: the assault suit is kevlar
// PLUS a helmet, and there is no head-hitbox armour rule here for a helmet to
// modify.  It therefore grants the same armour and additionally sets .has_suit,
// which is the nearest thing in this mod to "you are wearing the full kit" and
// is a flag maps can already ask about.  The alternative - two pickups that do
// exactly the same thing - would make the more expensive one a lie.
const float CS_KEVLAR_ARMOR = 100;

void() CS_Kevlar_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    if (other.armor >= CS_KEVLAR_ARMOR)
        return;                 // full; leave it for someone who needs it

    // SET, not added: CS kevlar is a fixed 100-point vest, not a battery.
    other.armor = CS_KEVLAR_ARMOR;
    sound(other, CHAN_ITEM, "items/tr_kevlar.wav", 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

void() CS_AssaultSuit_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;

    // Suit bit first, for the same reason GoldSrc_Suit_Touch sets it first: a
    // player who walks over this at full armour has still picked up the suit,
    // and making the answer depend on their armour is the confusion .has_suit
    // exists to end.
    other.has_suit = TRUE;

    if (other.armor >= CS_KEVLAR_ARMOR)
        return;

    other.armor = CS_KEVLAR_ARMOR;
    sound(other, CHAN_ITEM, "items/tr_kevlar.wav", 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

// ---------------------------------------------------------------------------
// weapon_shield — the tactical shield
// ---------------------------------------------------------------------------
// Equipment, not a weapon, for the reasons written up at the top of
// shared/weapons/sh_wpn_csshield.qc.  It lives beside item_kevlar because that
// is what it is: a thing you walk over that changes how you take damage.
//
// The classname is Counter-Strike's own (`weapon_shield`), so a GoldSrc CS map
// that places one gets it for free — same arrangement as the thirteen guns.
void() CS_Shield_Touch =
{
    if (other.classname != "player" || other.health <= 0)
        return;
    if (other.has_shield)
        return;                     // already carrying one

    // Rule 2 from the other direction: a player holding a two-handed weapon
    // cannot pick this up.  Refusing quietly would look like a broken pickup,
    // so say why — this is the same trap CS players hit and it is not obvious.
    if (!SH_ShieldAllowsWeapon(other.weapon))
    {
        centerprint(other, "You cannot carry a shield with that weapon\n");
        return;
    }

    other.has_shield      = TRUE;
    other.shield_deployed = FALSE;
    sound(other, CHAN_ITEM, "items/gunpickup2.wav", 1, ATTN_NORM);
    GoldSrc_PickupTaken(other);
};

void() weapon_shield =
{
    precache_model(SHIELD_WORLDMODEL);
    precache_sound("items/gunpickup2.wav");
    GoldSrc_SpawnPickup(SHIELD_WORLDMODEL, CS_Shield_Touch);
};

// Drop the shield back into the world — called when a player dies, or takes a
// weapon that cannot be held beside it.
void(entity p) CS_Shield_DropFrom =
{
    if (!p.has_shield)
        return;
    SH_ShieldClear(p);

    entity s = spawn();
    setmodel(s, SHIELD_WORLDMODEL);
    setsize(s, '-16 -16 0', '16 16 16');
    s.classname = "weapon_shield";
    // PICKUP_SF_NO_RESPAWN is load-bearing, not decoration.  CS_Shield_Touch
    // ends in GoldSrc_PickupTaken, which for a map-placed pickup HIDES the
    // entity and schedules it back under mp_item_respawndelay.  A player-dropped
    // one that went through that path would respawn itself forever: drop, pick
    // up, drop, and the map fills with shields.  The flag makes
    // Pickup_RespawnDelay answer -1, which is what routes it to remove().
    s.spawnflags = PICKUP_SF_NO_RESPAWN;
    s.solid     = SOLID_NOT;        // becomes a trigger once it settles
    s.movetype  = MOVETYPE_TOSS;
    makevectors([0, p.v_angle_y, 0]);
    setorigin(s, p.origin + v_forward * 24 + '0 0 16');
    s.velocity  = v_forward * 180 + '0 0 120';
    s.touch     = CS_Shield_Touch;
    s.think     = weapon_become_solid;
    s.nextthink = time + 0.7;
};

void() item_kevlar =
{
    precache_sound("items/tr_kevlar.wav");
    GoldSrc_SpawnPickup("models/w_kevlar.mdl", CS_Kevlar_Touch);
};

void() item_assaultsuit =
{
    precache_sound("items/tr_kevlar.wav");
    GoldSrc_SpawnPickup("models/w_assault.mdl", CS_AssaultSuit_Touch);
};

// ---------------------------------------------------------------------------
// armoury_entity — CArmoury
// ---------------------------------------------------------------------------
// The `item` key is an INDEX, not a classname, and the numbering is CS's own.
// Reproduced verbatim from the entity reference, with this mod's spawn function
// beside each one:
//
//    0  weapon_mp5navy       -> weapon_csmp5      (mod name)
//    1  weapon_tmp           -> weapon_tmp
//    2  weapon_p90           -> weapon_p90
//    3  weapon_mac10         -> weapon_mac10
//    4  weapon_ak47          -> weapon_ak47
//    5  weapon_sg552         -> weapon_sg552
//    6  weapon_m4a1          -> weapon_m4a1
//    7  weapon_aug           -> weapon_aug
//    8  weapon_scout         -> weapon_scout
//    9  weapon_g3sg1         -> weapon_g3sg1
//   10  weapon_awp           -> weapon_csawp      (mod name)
//   11  weapon_m3            -> weapon_csm3       (mod name)
//   12  weapon_xm1014        -> weapon_xm1014
//   13  weapon_m249          -> weapon_csm249     (SEE BELOW)
//   14  weapon_flashbang     -> weapon_csflashbang
//   15  weapon_hegrenade     -> weapon_cshegrenade
//   16  item_kevlar          -> item_kevlar
//   17  item_assaultsuit     -> item_assaultsuit
//   18  weapon_smokegrenade  -> weapon_cssmokegrenade
//
// INDEX 13 IS THE ONE TRAP.  `weapon_m249` IS a spawn function in this mod, but
// it is not the CS M249 - shared/sh_weapons.qc:189 records that the classname
// was deliberately taken off the Counter-Strike gun and given to another one.
// Dispatching by classname string would therefore hand out the wrong weapon for
// index 13 and nobody would notice, because the right gun does exist under a
// different name.  Calling weapon_csm249 directly is what makes that impossible.
// The same reasoning covers 0, 10 and 11, where the CS classname simply is not
// registered at all.
//
// Every branch calls a spawn function that ends in W_RegisterMapWeapon, so an
// armoury weapon is a MAP WEAPON in every sense the rest of the mod already
// understands: floor-snapped at spawn, ODE-dropped if sv_phys_drops is on,
// hidden rather than removed by mp_nomapweapons, revived by RoundRestart, and
// CSQC-replicated for pickup prediction.  Nothing here re-implements any of it.
//
// The mapper's `angles` survives because W_RegisterMapWeapon stores
// self.angles into map_weapon_angles before anything else touches the entity.
float() Armoury_SpawnItem =
{
    float it = self.item;

    if (it ==  0) { weapon_csmp5();          return TRUE; }
    if (it ==  1) { weapon_tmp();            return TRUE; }
    if (it ==  2) { weapon_p90();            return TRUE; }
    if (it ==  3) { weapon_mac10();          return TRUE; }
    if (it ==  4) { weapon_ak47();           return TRUE; }
    if (it ==  5) { weapon_sg552();          return TRUE; }
    if (it ==  6) { weapon_m4a1();           return TRUE; }
    if (it ==  7) { weapon_aug();            return TRUE; }
    if (it ==  8) { weapon_scout();          return TRUE; }
    if (it ==  9) { weapon_g3sg1();          return TRUE; }
    if (it == 10) { weapon_csawp();          return TRUE; }
    if (it == 11) { weapon_csm3();           return TRUE; }
    if (it == 12) { weapon_xm1014();         return TRUE; }
    if (it == 13) { weapon_csm249();         return TRUE; }
    if (it == 14) { weapon_csflashbang();    return TRUE; }
    if (it == 15) { weapon_cshegrenade();    return TRUE; }
    if (it == 16) { item_kevlar();           return TRUE; }
    if (it == 17) { item_assaultsuit();      return TRUE; }
    if (it == 18) { weapon_cssmokegrenade(); return TRUE; }

    return FALSE;
};

// One-line map-load summary, in the same shape as GoldSrcFX_Report's
// "[goldsrc-fx] ..." line.  Worth having permanently rather than as a temporary
// diagnostic: armoury_entity is the entity a CS map places its whole arsenal
// with, so "did the guns spawn" is the first question on any CS map, and the
// answer is otherwise only visible by walking the level.
//
// Deferred through a throwaway entity rather than printed per-spawn: 43 lines on
// deathrun_4life is noise, and the totals are not known until the last
// armoury_entity has run.
float armoury_placed;
float armoury_stock;
float armoury_unknown;
float armoury_nomodel;
float armoury_stuck;
float armoury_rawsolid;
float armoury_reported;

void() Armoury_Report =
{
    remove(self);
    if (armoury_reported)
        return;
    armoury_reported = TRUE;
    print(sprintf("[cs] armoury_entity: %g placed, %g total pickups, %g unknown index, %g no model, %g buried (%g placed in solid)\n",
                  armoury_placed, armoury_stock, armoury_unknown, armoury_nomodel,
                  armoury_stuck, armoury_rawsolid));
};

void() armoury_entity =
{
    // Read the stock BEFORE dispatching.  The weapon spawn functions overwrite
    // .classname and a good deal else on the way through, and a couple of them
    // (the grenades) call a shared helper that resets fields wholesale; reading
    // first means this cannot become order-dependent later.
    float stock = self.count;
    if (stock < 1)
        stock = 1;              // CS: an absent or zero count is one weapon

    float it = self.item;
    vector raw_org = self.origin;
    if (pointcontents(raw_org) == CONTENT_SOLID)
        armoury_rawsolid = armoury_rawsolid + 1;

    // First armoury_entity on the map arms the summary print.
    if (!armoury_placed && !armoury_unknown)
    {
        entity rep = spawn();
        rep.classname = "armoury_report";
        rep.think     = Armoury_Report;
        rep.nextthink = time + 0.1;
    }

    if (!Armoury_SpawnItem())
    {
        // Out-of-range index.  Say so and remove, rather than leaving an
        // invisible solid where the mapper expected a gun - the CS reference
        // itself notes "not all CS weapons are available", so a map built
        // against a different build can legitimately carry an index we do not
        // know, and it should be visible in the log rather than silent.
        armoury_unknown = armoury_unknown + 1;
        dprint("armoury_entity: unknown item index ");
        dprint(ftos(it));
        dprint(" - removed\n");
        remove(self);
        return;
    }

    armoury_placed = armoury_placed + 1;
    armoury_stock  = armoury_stock + stock;

    // An armoury weapon that reached here solid but with no modelindex is
    // pickable and invisible, which is the single most confusing way for this
    // entity to fail.  Count it, and name it under `developer 1`.
    if (!self.modelindex)
    {
        armoury_nomodel = armoury_nomodel + 1;
        dprint(sprintf("armoury_entity: item %g -> %s has NO MODEL (model=\"%s\")\n",
                       it, self.classname, self.model));
    }

    // The OTHER way this entity goes invisible: buried.  A weapon whose origin
    // is inside world geometry still trigger-touches (SOLID_TRIGGER overlaps
    // work from inside a brush) so it is pickable, and renders entirely inside
    // the floor so it cannot be seen.  Count both the mapper's raw placement
    // and where the weapon actually came to rest.
    if (pointcontents(self.origin + '0 0 4') == CONTENT_SOLID)
    {
        armoury_stuck = armoury_stuck + 1;
        dprint(sprintf("armoury_entity: item %g -> %s BURIED at %v (raw %v)\n",
                       it, self.classname, self.origin, raw_org));
    }

    // Extra takes beyond the first.  Pickup_Taken (sv_weapons.qc) decrements
    // this and forces an instant respawn while it lasts, so one entity hands
    // out `count` weapons from one spot and only then obeys the server's normal
    // respawn rules - which is exactly what the CS reference describes.
    //
    // Set AFTER the dispatch: mp_nomapweapons routes W_RegisterMapWeapon down a
    // hide path that clears a lot of the entity, and this must survive it.
    self.armoury_left = stock - 1;
};

// ---------------------------------------------------------------------------
// The four real Counter-Strike classnames that were not registered
// ---------------------------------------------------------------------------
// armoury_entity does not need these - it dispatches by function, above - but a
// map is free to place the weapon directly, and four of the CS classnames had no
// spawn function because this mod named those guns differently.  All four names
// were unused in the tree, so claiming them costs nothing and cannot shadow an
// existing weapon.
//
// weapon_m249 is POINTEDLY ABSENT from this list: unlike the four below it IS
// already a spawn function here, for a different gun, and sh_weapons.qc:189 says
// that was deliberate.  Re-pointing it at the CS M249 would silently change what
// every existing map placing weapon_m249 hands out.
void() weapon_mp5navy = { weapon_csmp5(); };
void() weapon_awp     = { weapon_csawp(); };
void() weapon_m3      = { weapon_csm3(); };
void() weapon_usp     = { weapon_csusp(); };
