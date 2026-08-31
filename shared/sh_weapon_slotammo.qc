// ============================================================
//  shared/sh_weapon_slotammo.qc
//
//  Slot-ammo bridge.  Primary/secondary slot fields are canonical for
//  inventory, prediction, HUD, and dropped weapons; the existing per-weapon
//  mag/ammo fields remain active-weapon working registers.
// ============================================================

float slotammo_mag;
float slotammo_ammo;
float slotammo_aux;

float(float wep) W_SlotAmmo_UsesSlot =
{
    float slot = WeaponManifest_Slot(wep);
    return slot == SLOT_PRIMARY || slot == SLOT_SECONDARY;
};

void(entity player, float wep, float mag, float ammo, float aux) W_SlotAmmo_SetForWeapon =
{
    float slot = WeaponManifest_Slot(wep);
    if (slot == SLOT_PRIMARY)
    {
        player.slot_primary_mag = mag;
        player.slot_primary_ammo = ammo;
        player.slot_primary_aux = aux;
    }
    else if (slot == SLOT_SECONDARY)
    {
        player.slot_secondary_mag = mag;
        player.slot_secondary_ammo = ammo;
        player.slot_secondary_aux = aux;
    }
};

void(entity player, float wep) W_SlotAmmo_GetForWeapon =
{
    float slot = WeaponManifest_Slot(wep);
    slotammo_mag = 0;
    slotammo_ammo = 0;
    slotammo_aux = 0;

    if (slot == SLOT_PRIMARY)
    {
        slotammo_mag = player.slot_primary_mag;
        slotammo_ammo = player.slot_primary_ammo;
        slotammo_aux = player.slot_primary_aux;
    }
    else if (slot == SLOT_SECONDARY)
    {
        slotammo_mag = player.slot_secondary_mag;
        slotammo_ammo = player.slot_secondary_ammo;
        slotammo_aux = player.slot_secondary_aux;
    }
};

void(entity player, float wep) W_SlotAmmo_SetDefaults =
{
    W_SlotAmmo_SetForWeapon(player, wep,
        WeaponManifest_DefaultMag(wep),
        WeaponManifest_DefaultAmmo(wep),
        WeaponManifest_DefaultAux(wep));
};

void(entity player, float wep) W_SlotAmmo_ClearForWeapon =
{
    W_SlotAmmo_SetForWeapon(player, wep, 0, 0, 0);
};

void(entity player) W_SlotAmmo_ClearSlots =
{
    player.slot_primary_mag = 0;
    player.slot_primary_ammo = 0;
    player.slot_primary_aux = 0;
    player.slot_secondary_mag = 0;
    player.slot_secondary_ammo = 0;
    player.slot_secondary_aux = 0;
};

void(entity player, float slot) W_SlotAmmo_ClearSlot =
{
    if (slot == SLOT_PRIMARY)
    {
        player.slot_primary_mag = 0;
        player.slot_primary_ammo = 0;
        player.slot_primary_aux = 0;
    }
    else if (slot == SLOT_SECONDARY)
    {
        player.slot_secondary_mag = 0;
        player.slot_secondary_ammo = 0;
        player.slot_secondary_aux = 0;
    }
};

// ---------------------------------------------------------------------------
//  THE DATA MODEL, stated once, because multi-carry broke the old one
// ---------------------------------------------------------------------------
// AUTHORITY: for every weapon the player carries, that weapon's own legacy
//   .mag_x / .ammo_x / aux fields are the sole authoritative store of its ammo.
// CACHE: slot_primary_mag/_ammo/_aux and slot_secondary_* describe ONLY the
//   weapon its slot's cursor currently names.  They exist because they are the
//   ammo bytes on the wire, the numbers the HUD reads, and what CSQC reconcile
//   writes.
// INVARIANT: canonical(slot) == legacy(cursor(slot)), always, on both sides.
//
// This was implicitly true when a slot held exactly one weapon.  Multi-carry
// made a slot hold up to four, and W_SlotAmmo_SetForWeapon routes purely by
// WeaponManifest_Slot() — so TWO PRIMARIES SHARE ONE REGISTER SET and every
// operation that assumed otherwise silently laundered one gun's ammo onto
// another.  That is one bug with four faces: a debug-menu/buy/equip give handing
// out an empty weapon, a cursor move copying the old gun's count onto the new
// one, an ammo box topping up the wrong gun, and dropping one primary zeroing
// the survivor's HUD.
//
// NAMING WARNING, because it reads backwards and will trip you:
//     W_SlotAmmo_SaveLegacy(p, w)  is  w's legacy -> canonical   (HYDRATE)
//     W_SlotAmmo_LoadLegacy(p, w)  is  canonical -> w's legacy   (PERSIST)
// The names are kept because renaming them means touching two ~90-row dispatch
// tables, which is exactly the kind of edit that makes the two copies drift.
// ---------------------------------------------------------------------------

// Both dispatch tables are defined further down this file, below this block.
// They must be declared here rather than relied on: sv_weapons.qc happens to
// forward-declare them for the server VM, so a missing declaration here compiles
// clean on the server and fails only on CSQC.
void(entity player, float wep) W_SlotAmmo_SaveLegacy;
void(entity player, float wep) W_SlotAmmo_LoadLegacy;

// Read a weapon's AUTHORITATIVE ammo into slotammo_mag/_ammo/_aux without
// disturbing the slot cache.  W_SlotAmmo_SaveLegacy cannot be used for this: it
// is a WRITE to the cache, which is illegal when `wep` is not the cursor.
//
// Implemented by snapshot/restore around SaveLegacy rather than as a third copy
// of the 90-row dispatch table — deliberately.  Two copies of that table have
// already drifted once (see the notes further down this file); a third would be
// a standing invitation.
void(entity player, float wep) W_SlotAmmo_ReadWeapon =
{
    float slot = WeaponManifest_Slot(wep);
    if (slot != SLOT_PRIMARY && slot != SLOT_SECONDARY)
    {
        slotammo_mag = 0; slotammo_ammo = 0; slotammo_aux = 0;
        return;
    }
    W_SlotAmmo_GetForWeapon(player, wep);
    float km = slotammo_mag, ka = slotammo_ammo, kx = slotammo_aux;   // cache
    W_SlotAmmo_SaveLegacy(player, wep);                               // legacy -> cache
    W_SlotAmmo_GetForWeapon(player, wep);                             // read it out
    float rm = slotammo_mag, ra = slotammo_ammo, rx = slotammo_aux;
    W_SlotAmmo_SetForWeapon(player, wep, km, ka, kx);                 // put the cache back
    slotammo_mag = rm; slotammo_ammo = ra; slotammo_aux = rx;
};

// Write a weapon's AUTHORITATIVE ammo.  Refreshes the slot cache only when `wep`
// really is that slot's cursor, so a write aimed at a holstered gun cannot
// clobber the held one's HUD.
void(entity player, float wep, float m, float a, float x) W_SlotAmmo_WriteWeapon =
{
    float slot = WeaponManifest_Slot(wep);
    if (slot != SLOT_PRIMARY && slot != SLOT_SECONDARY)
        return;

    float cur = (slot == SLOT_PRIMARY) ? player.slot_primary : player.slot_secondary;

    W_SlotAmmo_GetForWeapon(player, wep);
    float km = slotammo_mag, ka = slotammo_ammo, kx = slotammo_aux;   // cache

    W_SlotAmmo_SetForWeapon(player, wep, m, a, x);
    W_SlotAmmo_LoadLegacy(player, wep);                               // cache -> legacy

    if (cur != wep)
        W_SlotAmmo_SetForWeapon(player, wep, km, ka, kx);             // restore the cursor's
};

// THE cursor move, and the only sanctioned way to change slot_primary /
// slot_secondary outside a wholesale loadout reset.  Persist the outgoing
// weapon into its own store, move the cursor, hydrate the incoming one.
//
// sh_weapons.qc used to point at a "W_SlotAmmo_PointAt ... the one line that
// re-points them on a cursor move" that was never written.  This is it.
void(entity p, float slot, float wep) W_SlotAmmo_PointAt =
{
    float cur = (slot == SLOT_PRIMARY) ? p.slot_primary : p.slot_secondary;
    if (cur == wep)
        return;                                   // already correct

    if (cur != WEP_NONE && W_SlotAmmo_UsesSlot(cur))
        W_SlotAmmo_LoadLegacy(p, cur);            // PERSIST cache -> cur's legacy

    if (slot == SLOT_PRIMARY) p.slot_primary   = wep;
    else                      p.slot_secondary = wep;

    if (wep != WEP_NONE && W_SlotAmmo_UsesSlot(wep))
        W_SlotAmmo_SaveLegacy(p, wep);            // HYDRATE wep's legacy -> cache
    else
        W_SlotAmmo_ClearSlot(p, slot);
};

void(entity player, float wep) W_SlotAmmo_LoadLegacy =
{
    W_SlotAmmo_GetForWeapon(player, wep);

         if (wep == WEP_AK47 || wep == WEP_HDAK47) { player.mag_ak47 = slotammo_mag; player.ammo_ak47 = slotammo_ammo; }
    else if (wep == WEP_M4A1)            { player.mag_m4a1 = slotammo_mag; player.ammo_m4a1 = slotammo_ammo; player.m4a1_silenced = slotammo_aux; }
    else if (wep == WEP_CSAWP)           { player.mag_awp = slotammo_mag; player.ammo_awp = slotammo_ammo; }
    else if (wep == WEP_G3SG1)           { player.mag_g3sg1 = slotammo_mag; player.ammo_g3sg1 = slotammo_ammo; }
    else if (wep == WEP_CSM3)            { player.mag_m3 = slotammo_mag; player.ammo_m3 = slotammo_ammo; }
    else if (wep == WEP_CSMP5)           { player.mag_mp5 = slotammo_mag; player.ammo_mp5 = slotammo_ammo; }
    // The thirteen Counter-Strike 1.6 guns.
    else if (wep == WEP_CSP228)          { player.mag_p228 = slotammo_mag; player.ammo_p228 = slotammo_ammo; }
    else if (wep == WEP_CSFIVESEVEN)     { player.mag_fiveseven = slotammo_mag; player.ammo_fiveseven = slotammo_ammo; }
    else if (wep == WEP_CSELITE)         { player.mag_elite = slotammo_mag; player.ammo_elite = slotammo_ammo; }
    else if (wep == WEP_CSTMP)           { player.mag_tmp = slotammo_mag; player.ammo_tmp = slotammo_ammo; }
    else if (wep == WEP_CSMAC10)         { player.mag_mac10 = slotammo_mag; player.ammo_mac10 = slotammo_ammo; }
    else if (wep == WEP_CSUMP45)         { player.mag_ump45 = slotammo_mag; player.ammo_ump45 = slotammo_ammo; }
    else if (wep == WEP_CSP90)           { player.mag_p90 = slotammo_mag; player.ammo_p90 = slotammo_ammo; }
    else if (wep == WEP_CSGALIL)         { player.mag_galil = slotammo_mag; player.ammo_galil = slotammo_ammo; }
    else if (wep == WEP_CSFAMAS)         { player.mag_famas = slotammo_mag; player.ammo_famas = slotammo_ammo; }
    else if (wep == WEP_CSAUG)           { player.mag_aug = slotammo_mag; player.ammo_aug = slotammo_ammo; }
    else if (wep == WEP_CSSG552)         { player.mag_sg552 = slotammo_mag; player.ammo_sg552 = slotammo_ammo; }
    else if (wep == WEP_CSSG550)         { player.mag_sg550 = slotammo_mag; player.ammo_sg550 = slotammo_ammo; }
    else if (wep == WEP_CSXM1014)        { player.mag_xm1014 = slotammo_mag; player.ammo_xm1014 = slotammo_ammo; }
    else if (wep == WEP_DOD98K)          { player.mag_98k = slotammo_mag; player.ammo_98k = slotammo_ammo; }
    else if (wep == WEP_DODCOLT)         { player.mag_dodcolt = slotammo_mag; player.ammo_dodcolt = slotammo_ammo; }
    else if (wep == WEP_DODLUGER)        { player.mag_dodluger = slotammo_mag; player.ammo_dodluger = slotammo_ammo; }
    else if (wep == WEP_DODWEBLEY)       { player.mag_dodwebley = slotammo_mag; player.ammo_dodwebley = slotammo_ammo; }
    else if (wep == WEP_DODGARAND)       { player.mag_dodgarand = slotammo_mag; player.ammo_dodgarand = slotammo_ammo; }
    else if (wep == WEP_DODCARBINE)      { player.mag_dodcarbine = slotammo_mag; player.ammo_dodcarbine = slotammo_ammo; }
    else if (wep == WEP_DODK43)          { player.mag_dodk43 = slotammo_mag; player.ammo_dodk43 = slotammo_ammo; }
    else if (wep == WEP_DODTOMMY)        { player.mag_dodtommy = slotammo_mag; player.ammo_dodtommy = slotammo_ammo; }
    else if (wep == WEP_DODMP40)         { player.mag_dodmp40 = slotammo_mag; player.ammo_dodmp40 = slotammo_ammo; }
    else if (wep == WEP_DODSTEN)         { player.mag_dodsten = slotammo_mag; player.ammo_dodsten = slotammo_ammo; }
    else if (wep == WEP_DODGREASE)       { player.mag_dodgrease = slotammo_mag; player.ammo_dodgrease = slotammo_ammo; }
    else if (wep == WEP_DODMP44)         { player.mag_dodmp44 = slotammo_mag; player.ammo_dodmp44 = slotammo_ammo; }
    else if (wep == WEP_DODBAR)          { player.mag_dodbar = slotammo_mag; player.ammo_dodbar = slotammo_ammo; }
    // Day of Defeat, third batch.  The BINOCULARS are deliberately absent for
    // the same reason as the melee weapons below: no ammo, and
    // W_SlotAmmo_UsesSlot is FALSE for SLOT_UTILITY anyway.
    else if (wep == WEP_DODBREN)         { player.mag_dodbren = slotammo_mag; player.ammo_dodbren = slotammo_ammo; }
    else if (wep == WEP_DODFG42)         { player.mag_dodfg42 = slotammo_mag; player.ammo_dodfg42 = slotammo_ammo; }
    else if (wep == WEP_DODFG42S)        { player.mag_dodfg42s = slotammo_mag; player.ammo_dodfg42s = slotammo_ammo; }
    else if (wep == WEP_DODFCARB)        { player.mag_dodfcarb = slotammo_mag; player.ammo_dodfcarb = slotammo_ammo; }
    else if (wep == WEP_DODENFIELD)      { player.mag_dodenfield = slotammo_mag; player.ammo_dodenfield = slotammo_ammo; }
    else if (wep == WEP_DODMORTAR)       { player.mag_dodmortar = slotammo_mag; player.ammo_dodmortar = slotammo_ammo; }
    // Day of Defeat, second batch.  The four MELEE weapons are deliberately
    // absent from both tables: they have no ammo at all, and
    // W_SlotAmmo_UsesSlot is FALSE for SLOT_MELEE, so a row here would be dead.
    else if (wep == WEP_DODSCOPED98K)    { player.mag_dodscoped98k = slotammo_mag; player.ammo_dodscoped98k = slotammo_ammo; }
    else if (wep == WEP_DODSPRING)       { player.mag_dodspring    = slotammo_mag; player.ammo_dodspring    = slotammo_ammo; }
    else if (wep == WEP_DODENFIELDS)     { player.mag_dodenfields  = slotammo_mag; player.ammo_dodenfields  = slotammo_ammo; }
    else if (wep == WEP_DOD30CAL)        { player.mag_dod30cal     = slotammo_mag; player.ammo_dod30cal     = slotammo_ammo; }
    else if (wep == WEP_DODMG34)         { player.mag_dodmg34      = slotammo_mag; player.ammo_dodmg34      = slotammo_ammo; }
    else if (wep == WEP_DODMG42)         { player.mag_dodmg42      = slotammo_mag; player.ammo_dodmg42      = slotammo_ammo; }
    else if (wep == WEP_DODBAZOOKA)      { player.mag_dodbazooka   = slotammo_mag; player.ammo_dodbazooka   = slotammo_ammo; }
    else if (wep == WEP_DODSCHRECK)      { player.mag_dodschreck   = slotammo_mag; player.ammo_dodschreck   = slotammo_ammo; }
    else if (wep == WEP_DODPIAT)         { player.mag_dodpiat      = slotammo_mag; player.ammo_dodpiat      = slotammo_ammo; }
    else if (wep == WEP_FLAKSHOTGUN)     { player.mag_flakshotgun = slotammo_mag; }
    else if (wep == WEP_GAUSS)           { player.ammo_gauss = slotammo_ammo; }
    else if (wep == WEP_GRENADELAUNCHER) { player.mag_grenadelauncher = slotammo_mag; }
    else if (wep == WEP_CROSSBOW)        { player.mag_crossbow = slotammo_mag; player.ammo_crossbow = slotammo_ammo; }
    else if (wep == WEP_HLEGON)          { player.ammo_hlegon = slotammo_ammo; }
    else if (wep == WEP_HLRPG)           { player.mag_hlrpg = slotammo_mag; player.ammo_hlrpg = slotammo_ammo; }
    else if (wep == WEP_HLSHOTGUN)       { player.mag_shotgun = slotammo_mag; player.ammo_shotgun = slotammo_ammo; }
    else if (wep == WEP_HLSMG)           { player.mag_hlsmg = slotammo_mag; player.ammo_hlsmg = slotammo_ammo; player.ammo_hlsmg_grenades = slotammo_aux; }
    else if (wep == WEP_TH1911)          { player.mag_th1911 = slotammo_mag; player.ammo_th1911 = slotammo_ammo; }
    else if (wep == WEP_THTOMMY)         { player.mag_thtommy = slotammo_mag; player.ammo_thtommy = slotammo_ammo; }
    else if (wep == WEP_THGREASE)        { player.mag_thgrease = slotammo_mag; player.ammo_thgrease = slotammo_ammo; }
    else if (wep == WEP_THM14)           { player.mag_thm14 = slotammo_mag; player.ammo_thm14 = slotammo_ammo; }
    else if (wep == WEP_THM16)           { player.mag_thm16 = slotammo_mag; player.ammo_thm16 = slotammo_ammo; }
    else if (wep == WEP_THSAWOFF)        { player.mag_thsawoff = slotammo_mag; player.ammo_thsawoff = slotammo_ammo; }
    else if (wep == WEP_THTESLA)         { player.ammo_thtesla = slotammo_ammo; }
    // The slot registers are the ONLY channel a weapon's ammo reaches the
    // client on - the prediction proxy ships slot_primary_*/slot_secondary_*
    // and nothing else.  These five were given working server-side ammo in
    // W_RefreshPrimarySlot/W_RefreshSecondarySlot but never got a bridge row,
    // so slot_primary_ammo stayed 0 and every client-side reader saw 0:
    // the HUD printed "0", CSQC_ApplyPickupAmmo restored 0, and a dropped
    // weapon carried 0.  The displacer's symptom was the giveaway - the HUD
    // said 0 while the SERVER still had 100, so the first alt-fire spent 60
    // and the second was refused.  Hornetgun and shock rifle regenerate every
    // tick (SH_HGunRegrow / SH_ShockRegrow), so wiring them here is also what
    // makes the charge visibly climb.
    else if (wep == WEP_HORNETGUN)       { player.ammo_hornet = slotammo_ammo; }
    else if (wep == WEP_SHOCKRIFLE)      { player.ammo_shockrifle = slotammo_ammo; }
    else if (wep == WEP_DISPLACER)       { player.ammo_displacer = slotammo_ammo; }
    else if (wep == WEP_JETPACK)         { player.mag_jetpack = slotammo_mag; player.ammo_jetpack = slotammo_ammo; player.ammo_jetfuel = slotammo_aux; }
    else if (wep == WEP_M249)            { player.mag_m249 = slotammo_mag; player.ammo_m249 = slotammo_ammo; }
    else if (wep == WEP_REBAR)           { player.mag_rebar = slotammo_mag; }
    else if (wep == WEP_SCOUT)           { player.mag_scout = slotammo_mag; player.ammo_scout = slotammo_ammo; }
    else if (wep == WEP_PAINTBALL)       { player.mag_paintball = slotammo_mag; player.ammo_paintball = slotammo_ammo; }
    else if (wep == WEP_CFAUG)           { player.mag_cfaug = slotammo_mag; player.ammo_cfaug = slotammo_ammo; }
    else if (wep == WEP_CFFAMAS)         { player.mag_cffamas = slotammo_mag; player.ammo_cffamas = slotammo_ammo; }
    else if (wep == WEP_CFMAC10)         { player.mag_cfmac10 = slotammo_mag; player.ammo_cfmac10 = slotammo_ammo; }
    else if (wep == WEP_CFMP5)           { player.mag_cfmp5 = slotammo_mag; player.ammo_cfmp5 = slotammo_ammo; }
    else if (wep == WEP_CFVECTOR)        { player.mag_cfvector = slotammo_mag; player.ammo_cfvector = slotammo_ammo; }
    else if (wep == WEP_CFTYPE89)        { player.mag_cftype89 = slotammo_mag; player.ammo_cftype89 = slotammo_ammo; }
    else if (wep == WEP_CFUMP45)         { player.mag_cfump45 = slotammo_mag; player.ammo_cfump45 = slotammo_ammo; }
    else if (wep == WEP_CFM249)          { player.mag_cfm249 = slotammo_mag; player.ammo_cfm249 = slotammo_ammo; }
    else if (wep == WEP_CFAWM)           { player.mag_cfawm = slotammo_mag; player.ammo_cfawm = slotammo_ammo; }
    else if (wep == WEP_CFKS23)          { player.mag_cfks23 = slotammo_mag; player.ammo_cfks23 = slotammo_ammo; }
    else if (wep == WEP_CFM4)            { player.mag_cfm4 = slotammo_mag; player.ammo_cfm4 = slotammo_ammo; }
    else if (wep == WEP_CFMK23)          { player.mag_cfmk23 = slotammo_mag; player.ammo_cfmk23 = slotammo_ammo; player.cfmk23_silenced = slotammo_aux; }
    else if (wep == WEP_CSUSP)           { player.mag_csusp = slotammo_mag; player.ammo_csusp = slotammo_ammo; player.csusp_silenced = slotammo_aux; }
    else if (wep == WEP_CFGALIL)         { player.mag_cfgalil = slotammo_mag; player.ammo_cfgalil = slotammo_ammo; }
    else if (wep == WEP_CFGLOCK)         { player.mag_cfglock = slotammo_mag; player.ammo_cfglock = slotammo_ammo; }
    else if (wep == WEP_CFELITE)         { player.mag_cfelite = slotammo_mag; player.ammo_cfelite = slotammo_ammo; }
    else if (wep == WEP_CFP228)          { player.mag_cfp228 = slotammo_mag; player.ammo_cfp228 = slotammo_ammo; }
    else if (wep == WEP_CFMSG90)         { player.mag_cfmsg90 = slotammo_mag; player.ammo_cfmsg90 = slotammo_ammo; }
    else if (wep == WEP_CFSG552)         { player.mag_cfsg552 = slotammo_mag; player.ammo_cfsg552 = slotammo_ammo; }
    else if (wep == WEP_CFSL8)           { player.mag_cfsl8 = slotammo_mag; player.ammo_cfsl8 = slotammo_ammo; }
    else if (wep == WEP_DEAGLE)          { player.mag_deagle = slotammo_mag; player.ammo_deagle = slotammo_ammo; }
    else if (wep == WEP_GLOCK)           { player.mag_glock = slotammo_mag; player.ammo_glock = slotammo_ammo; }
    else if (wep == WEP_357)             { player.mag_357 = slotammo_mag; player.ammo_357 = slotammo_ammo; }
    else if (wep == WEP_HLGLOCK)         { player.mag_hlglock = slotammo_mag; player.ammo_hlglock = slotammo_ammo; }
    else if (wep == WEP_PISTOL)          { player.mag_pistol = slotammo_mag; player.ammo_pistol = slotammo_ammo; }
    else if (wep == WEP_CFM9)     { player.mag_cfm9 = slotammo_mag; player.ammo_cfm9 = slotammo_ammo; }
    else if (wep == WEP_CFREVOLVER)        { player.mag_cfrevolver = slotammo_mag; player.ammo_cfrevolver = slotammo_ammo; }
    else if (wep == WEP_CFBARRETT)           { player.mag_cfbarrett = slotammo_mag; player.ammo_cfbarrett = slotammo_ammo; }
    else if (wep == WEP_CFPSG1)         { player.mag_cfpsg1 = slotammo_mag; player.ammo_cfpsg1 = slotammo_ammo; }
    else if (wep == WEP_CFDDEAGLE)         { player.mag_cfddeagle = slotammo_mag; player.ammo_cfddeagle = slotammo_ammo; }
    else if (wep == WEP_CFSPAS12)        { player.mag_cfspas12 = slotammo_mag; player.ammo_cfspas12 = slotammo_ammo; }
    else if (wep == WEP_CFM700)     { player.mag_cfm700 = slotammo_mag; player.ammo_cfm700 = slotammo_ammo; }
    else if (wep == WEP_CFM3)            { player.mag_cfm3 = slotammo_mag; player.ammo_cfm3 = slotammo_ammo; }
    else if (wep == WEP_CFSCAR)         { player.mag_cfscar = slotammo_mag; player.ammo_cfscar = slotammo_ammo; }
    else if (wep == WEP_CFMAUSER)         { player.mag_cfmauser = slotammo_mag; player.ammo_cfmauser = slotammo_ammo; }
    else if (wep == WEP_CFSVD)         { player.mag_cfsvd = slotammo_mag; player.ammo_cfsvd = slotammo_ammo; }
    // Sven Co-op and Opposing Force.  The minigun is belt-fed with no magazine,
    // so its whole supply rides in the ammo half and the mag half stays 0.
    else if (wep == WEP_UZI             ) { player.mag_uzi = slotammo_mag; player.ammo_uzi = slotammo_ammo; }
    else if (wep == WEP_UZIAKIMBO       ) { player.mag_uziakimbo = slotammo_mag; player.ammo_uziakimbo = slotammo_ammo; }
    else if (wep == WEP_MINIGUN         ) { player.ammo_minigun = slotammo_ammo; }
    else if (wep == WEP_SVM16           ) { player.mag_svm16 = slotammo_mag; player.ammo_svm16 = slotammo_ammo; player.ammo_svm16_grenades = slotammo_aux; }
    else if (wep == WEP_SNIPERRIFLE     ) { player.mag_sniper = slotammo_mag; player.ammo_sniper = slotammo_ammo; }
    else if (wep == WEP_SPORELAUNCHER   ) { player.mag_spore = slotammo_mag; player.ammo_sporelauncher = slotammo_ammo; }
    else if (wep == WEP_EAGLE           ) { player.mag_eagle = slotammo_mag; player.ammo_eagle = slotammo_ammo; }
    else if (wep == WEP_ASSHOTGUN       ) { player.mag_asshotgun = slotammo_mag; player.ammo_asshotgun = slotammo_ammo; }
    // The last three Opposing Force weapons.  The knife has no ammo at all and so
    // has no row - W_SlotAmmo_UsesSlot keeps it out of the mirror entirely.
    //
    // THE PENGUIN HAD A ROW HERE AND IT WAS ACTIVELY HARMFUL.  It is
    // WMF_SLOT_UTILITY (sh_weapon_manifest.qc:764), and W_SlotAmmo_GetForWeapon
    // returns a hard 0 for anything that is not PRIMARY or SECONDARY — so this
    // line did not restore the count, it OVERWROTE it with zero.  Every other
    // caller is gated on W_SlotAmmo_UsesSlot and so never reached it, but
    // CSQC_PredictSelectWeapon (client/cl_weapons.qc:96) is ungated: selecting
    // the penguin blanked the predicted count for a round trip, so the HUD read
    // 0 and the client refused to predict a throw the server was performing.
    // The supply travels correctly by three other routes and always did — the
    // utility branch of W_SlotAmmo_CopyPlayerToDrop (:507), the proxy byte at
    // server/sv_player.qc:2427, and the unconditional reconcile at
    // client/cl_player.qc:1199 — so removing the row is the whole fix.
    //
    // This is the exact failure mode the comment at :508 warns about, arrived at
    // from the other direction: a row that reads as wired-up while doing the
    // wrong thing.  Check the manifest SLOT before adding a row to this table.
    else if (wep == WEP_OPSAW           ) { player.mag_saw = slotammo_mag; player.ammo_saw = slotammo_ammo; }
};

void(entity player, float wep) W_SlotAmmo_SaveLegacy =
{
         if (wep == WEP_AK47 || wep == WEP_HDAK47) W_SlotAmmo_SetForWeapon(player, wep, player.mag_ak47, player.ammo_ak47, 0);
    else if (wep == WEP_M4A1)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_m4a1, player.ammo_m4a1, player.m4a1_silenced);
    else if (wep == WEP_CSAWP)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_awp, player.ammo_awp, 0);
    else if (wep == WEP_G3SG1)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_g3sg1, player.ammo_g3sg1, 0);
    else if (wep == WEP_CSM3)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_m3, player.ammo_m3, 0);
    else if (wep == WEP_CSMP5)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_mp5, player.ammo_mp5, 0);
    // The thirteen Counter-Strike 1.6 guns.
    else if (wep == WEP_CSP228)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_p228, player.ammo_p228, 0);
    else if (wep == WEP_CSFIVESEVEN)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_fiveseven, player.ammo_fiveseven, 0);
    else if (wep == WEP_CSELITE)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_elite, player.ammo_elite, 0);
    else if (wep == WEP_CSTMP)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_tmp, player.ammo_tmp, 0);
    else if (wep == WEP_CSMAC10)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_mac10, player.ammo_mac10, 0);
    else if (wep == WEP_CSUMP45)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_ump45, player.ammo_ump45, 0);
    else if (wep == WEP_CSP90)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_p90, player.ammo_p90, 0);
    else if (wep == WEP_CSGALIL)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_galil, player.ammo_galil, 0);
    else if (wep == WEP_CSFAMAS)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_famas, player.ammo_famas, 0);
    else if (wep == WEP_CSAUG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_aug, player.ammo_aug, 0);
    else if (wep == WEP_CSSG552)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_sg552, player.ammo_sg552, 0);
    else if (wep == WEP_CSSG550)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_sg550, player.ammo_sg550, 0);
    else if (wep == WEP_CSXM1014)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_xm1014, player.ammo_xm1014, 0);
    else if (wep == WEP_DOD98K)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_98k, player.ammo_98k, 0);
    else if (wep == WEP_DODCOLT)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodcolt, player.ammo_dodcolt, 0);
    else if (wep == WEP_DODLUGER)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodluger, player.ammo_dodluger, 0);
    else if (wep == WEP_DODWEBLEY)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodwebley, player.ammo_dodwebley, 0);
    else if (wep == WEP_DODGARAND)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodgarand, player.ammo_dodgarand, 0);
    else if (wep == WEP_DODCARBINE)      W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodcarbine, player.ammo_dodcarbine, 0);
    else if (wep == WEP_DODK43)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodk43, player.ammo_dodk43, 0);
    else if (wep == WEP_DODTOMMY)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodtommy, player.ammo_dodtommy, 0);
    else if (wep == WEP_DODMP40)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodmp40, player.ammo_dodmp40, 0);
    else if (wep == WEP_DODSTEN)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodsten, player.ammo_dodsten, 0);
    else if (wep == WEP_DODGREASE)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodgrease, player.ammo_dodgrease, 0);
    else if (wep == WEP_DODMP44)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodmp44, player.ammo_dodmp44, 0);
    else if (wep == WEP_DODBAR)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodbar, player.ammo_dodbar, 0);
    // Day of Defeat, third batch — binoculars deliberately absent, see above.
    else if (wep == WEP_DODBREN)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodbren,    player.ammo_dodbren,    0);
    else if (wep == WEP_DODFG42)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodfg42,    player.ammo_dodfg42,    0);
    else if (wep == WEP_DODFG42S)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodfg42s,   player.ammo_dodfg42s,   0);
    else if (wep == WEP_DODFCARB)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodfcarb,   player.ammo_dodfcarb,   0);
    else if (wep == WEP_DODENFIELD)      W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodenfield, player.ammo_dodenfield, 0);
    else if (wep == WEP_DODMORTAR)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodmortar,  player.ammo_dodmortar,  0);
    // Day of Defeat, second batch — melee deliberately absent, see the note in
    // the persist table above.
    else if (wep == WEP_DODSCOPED98K)    W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodscoped98k, player.ammo_dodscoped98k, 0);
    else if (wep == WEP_DODSPRING)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodspring,    player.ammo_dodspring,    0);
    else if (wep == WEP_DODENFIELDS)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodenfields,  player.ammo_dodenfields,  0);
    else if (wep == WEP_DOD30CAL)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_dod30cal,     player.ammo_dod30cal,     0);
    else if (wep == WEP_DODMG34)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodmg34,      player.ammo_dodmg34,      0);
    else if (wep == WEP_DODMG42)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodmg42,      player.ammo_dodmg42,      0);
    else if (wep == WEP_DODBAZOOKA)      W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodbazooka,   player.ammo_dodbazooka,   0);
    else if (wep == WEP_DODSCHRECK)      W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodschreck,   player.ammo_dodschreck,   0);
    else if (wep == WEP_DODPIAT)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_dodpiat,      player.ammo_dodpiat,      0);
    else if (wep == WEP_FLAKSHOTGUN)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_flakshotgun, 0, 0);
    else if (wep == WEP_GAUSS)           W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_gauss, 0);
    else if (wep == WEP_GRENADELAUNCHER) W_SlotAmmo_SetForWeapon(player, wep, player.mag_grenadelauncher, 0, 0);
    else if (wep == WEP_CROSSBOW)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_crossbow, player.ammo_crossbow, 0);
    else if (wep == WEP_HLEGON)          W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_hlegon, 0);
    else if (wep == WEP_HLRPG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlrpg, player.ammo_hlrpg, 0);
    else if (wep == WEP_HLSHOTGUN)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_shotgun, player.ammo_shotgun, 0);
    else if (wep == WEP_HLSMG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlsmg, player.ammo_hlsmg, player.ammo_hlsmg_grenades);
    else if (wep == WEP_TH1911)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_th1911, player.ammo_th1911, 0);
    else if (wep == WEP_THTOMMY)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_thtommy, player.ammo_thtommy, 0);
    else if (wep == WEP_THGREASE)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_thgrease, player.ammo_thgrease, 0);
    else if (wep == WEP_THM14)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_thm14, player.ammo_thm14, 0);
    else if (wep == WEP_THM16)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_thm16, player.ammo_thm16, 0);
    else if (wep == WEP_THSAWOFF)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_thsawoff, player.ammo_thsawoff, 0);
    else if (wep == WEP_THTESLA)         W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_thtesla, 0);
    // Mirrors of the five added to W_SlotAmmo_LoadLegacy - see the note there.
    // W_SlotAmmo_SaveCurrent runs at the end of every weapon frame, so once
    // these exist the regenerating counters tick on the wire for free.
    else if (wep == WEP_HORNETGUN)       W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_hornet, 0);
    else if (wep == WEP_SHOCKRIFLE)      W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_shockrifle, 0);
    else if (wep == WEP_DISPLACER)       W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_displacer, 0);
    else if (wep == WEP_JETPACK)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_jetpack, player.ammo_jetpack, player.ammo_jetfuel);
    else if (wep == WEP_M249)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_m249, player.ammo_m249, 0);
    else if (wep == WEP_REBAR)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_rebar, 0, 0);
    else if (wep == WEP_SCOUT)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_scout, player.ammo_scout, 0);
    else if (wep == WEP_PAINTBALL)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_paintball, player.ammo_paintball, 0);
    else if (wep == WEP_CFAUG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfaug, player.ammo_cfaug, 0);
    else if (wep == WEP_CFFAMAS)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cffamas, player.ammo_cffamas, 0);
    else if (wep == WEP_CFMAC10)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfmac10, player.ammo_cfmac10, 0);
    else if (wep == WEP_CFMP5)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfmp5, player.ammo_cfmp5, 0);
    else if (wep == WEP_CFVECTOR)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfvector, player.ammo_cfvector, 0);
    else if (wep == WEP_CFTYPE89)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cftype89, player.ammo_cftype89, 0);
    else if (wep == WEP_CFUMP45)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfump45, player.ammo_cfump45, 0);
    else if (wep == WEP_CFM249)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm249, player.ammo_cfm249, 0);
    else if (wep == WEP_CFAWM)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfawm, player.ammo_cfawm, 0);
    else if (wep == WEP_CFKS23)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfks23, player.ammo_cfks23, 0);
    else if (wep == WEP_CFM4)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm4, player.ammo_cfm4, 0);
    else if (wep == WEP_CFMK23)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfmk23, player.ammo_cfmk23, player.cfmk23_silenced);
    else if (wep == WEP_CSUSP)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_csusp, player.ammo_csusp, player.csusp_silenced);
    else if (wep == WEP_CFGALIL)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfgalil, player.ammo_cfgalil, 0);
    else if (wep == WEP_CFGLOCK)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfglock, player.ammo_cfglock, 0);
    else if (wep == WEP_CFELITE)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfelite, player.ammo_cfelite, 0);
    else if (wep == WEP_CFP228)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfp228, player.ammo_cfp228, 0);
    else if (wep == WEP_CFMSG90)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfmsg90, player.ammo_cfmsg90, 0);
    else if (wep == WEP_CFSG552)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfsg552, player.ammo_cfsg552, 0);
    else if (wep == WEP_CFSL8)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfsl8, player.ammo_cfsl8, 0);
    else if (wep == WEP_DEAGLE)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_deagle, player.ammo_deagle, 0);
    else if (wep == WEP_GLOCK)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_glock, player.ammo_glock, 0);
    else if (wep == WEP_357)             W_SlotAmmo_SetForWeapon(player, wep, player.mag_357, player.ammo_357, 0);
    else if (wep == WEP_HLGLOCK)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlglock, player.ammo_hlglock, 0);
    else if (wep == WEP_PISTOL)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_pistol, player.ammo_pistol, 0);
    else if (wep == WEP_CFM9)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm9, player.ammo_cfm9, 0);
    else if (wep == WEP_CFREVOLVER)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfrevolver, player.ammo_cfrevolver, 0);
    else if (wep == WEP_CFBARRETT)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfbarrett, player.ammo_cfbarrett, 0);
    else if (wep == WEP_CFPSG1)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfpsg1, player.ammo_cfpsg1, 0);
    else if (wep == WEP_CFDDEAGLE)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfddeagle, player.ammo_cfddeagle, 0);
    else if (wep == WEP_CFSPAS12)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfspas12, player.ammo_cfspas12, 0);
    else if (wep == WEP_CFM700)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm700, player.ammo_cfm700, 0);
    else if (wep == WEP_CFM3)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm3, player.ammo_cfm3, 0);
    else if (wep == WEP_CFSCAR)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfscar, player.ammo_cfscar, 0);
    else if (wep == WEP_CFMAUSER)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfmauser, player.ammo_cfmauser, 0);
    else if (wep == WEP_CFSVD)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfsvd, player.ammo_cfsvd, 0);
    // See the note on the matching block in W_SlotAmmo_LoadLegacy.
    else if (wep == WEP_UZI             ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_uzi, player.ammo_uzi, 0);
    else if (wep == WEP_UZIAKIMBO       ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_uziakimbo, player.ammo_uziakimbo, 0);
    else if (wep == WEP_MINIGUN         ) W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_minigun, 0);
    else if (wep == WEP_SVM16           ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_svm16, player.ammo_svm16, player.ammo_svm16_grenades);
    else if (wep == WEP_SNIPERRIFLE     ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_sniper, player.ammo_sniper, 0);
    else if (wep == WEP_SPORELAUNCHER   ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_spore, player.ammo_sporelauncher, 0);
    else if (wep == WEP_EAGLE           ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_eagle, player.ammo_eagle, 0);
    else if (wep == WEP_ASSHOTGUN       ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_asshotgun, player.ammo_asshotgun, 0);
    // See the matching block in W_SlotAmmo_LoadLegacy — the penguin's row is gone
    // from both tables for the reason recorded there.  This one was merely inert
    // (W_SlotAmmo_SetForWeapon writes nothing for a UTILITY slot); its twin was not.
    else if (wep == WEP_OPSAW           ) W_SlotAmmo_SetForWeapon(player, wep, player.mag_saw, player.ammo_saw, 0);
};

void(entity player) W_SlotAmmo_LoadCurrent =
{
    if (W_SlotAmmo_UsesSlot(player.weapon))
        W_SlotAmmo_LoadLegacy(player, player.weapon);
};

void(entity player) W_SlotAmmo_SaveCurrent =
{
    if (W_SlotAmmo_UsesSlot(player.weapon))
        W_SlotAmmo_SaveLegacy(player, player.weapon);
};

void(entity drop, entity player, float wep) W_SlotAmmo_CopyPlayerToDrop =
{
    drop.weapon_drop_mag = 0;
    drop.weapon_drop_ammo = 0;
    drop.weapon_drop_aux = 0;

    if (W_SlotAmmo_UsesSlot(wep))
    {
        W_SlotAmmo_GetForWeapon(player, wep);
        drop.weapon_drop_mag = slotammo_mag;
        drop.weapon_drop_ammo = slotammo_ammo;
        drop.weapon_drop_aux = slotammo_aux;
    }
    else if (wep == WEP_HLGRENADE)       drop.weapon_drop_ammo = player.ammo_hlgrenade;
    else if (wep == WEP_SATCHEL)         drop.weapon_drop_ammo = player.ammo_satchel;
    else if (wep == WEP_TRIPMINE)        drop.weapon_drop_ammo = player.ammo_tripmine;
    else if (wep == WEP_SNARK)           drop.weapon_drop_ammo = player.ammo_snark;
    // The penguin is UTILITY, so W_SlotAmmo_UsesSlot is FALSE for it and this
    // branch is the one that runs — unlike the SAW, which is PRIMARY and takes
    // the slot path above.
    else if (wep == WEP_PENGUIN)         drop.weapon_drop_ammo = player.ammo_penguin;
    // NOTE: hornetgun / shock rifle / tesla / displacer / jetpack used to have
    // rows here.  They were unreachable - all five are PRIMARY or SECONDARY, so
    // W_SlotAmmo_UsesSlot() is TRUE and the branch above always wins.  They read
    // as wired-up while doing nothing, which is how the missing bridge rows in
    // W_SlotAmmo_{Load,Save}Legacy went unnoticed.  The slot branch is correct
    // for them now that those rows exist.
    else if (wep == WEP_SNOWBALL)        drop.weapon_drop_ammo = player.ammo_snowball;
    else if (wep == WEP_CSHEGRENADE)     drop.weapon_drop_ammo = player.ammo_cshegrenade;
    else if (wep == WEP_DODMILLS)        drop.weapon_drop_ammo = player.ammo_dodmills;
    else if (wep == WEP_DODSTICK)        drop.weapon_drop_ammo = player.ammo_dodstick;
    else if (wep == WEP_CSFLASHBANG)     drop.weapon_drop_ammo = player.ammo_csflashbang;
    else if (wep == WEP_CSSMOKEGRENADE)  drop.weapon_drop_ammo = player.ammo_cssmokegrenade;
    else if (wep == WEP_CFC4)            drop.weapon_drop_ammo = player.ammo_cfc4;
    else if (wep == WEP_SLINGSHOT)       drop.weapon_drop_aux = player.snowball_has_slingshot;
};

void(entity player, entity drop) W_SlotAmmo_CopyDropToPlayer =
{
    if (!W_SlotAmmo_UsesSlot(drop.weapon))
        return;

    // Snapshot the legacy values pickupcopy just set into the slot,
    // so a map-spawned drop (which never sets weapon_drop_*) falls
    // back to the spawn-time defaults instead of zeroing out the
    // legacy via LoadLegacy below.  Player-dropped weapons always set
    // weapon_drop_* via W_SlotAmmo_CopyPlayerToDrop, so they take the
    // explicit branch.
    if (drop.weapon_drop_mag != 0
        || drop.weapon_drop_ammo != 0
        || drop.weapon_drop_aux != 0)
    {
        W_SlotAmmo_SetForWeapon(player, drop.weapon,
            drop.weapon_drop_mag,
            drop.weapon_drop_ammo,
            drop.weapon_drop_aux);
    }
    else
    {
        // No explicit drop ammo — promote the legacy values
        // pickupcopy just stamped into slot ammo so LoadLegacy
        // below doesn't zero them.
        W_SlotAmmo_SaveLegacy(player, drop.weapon);
    }
    W_SlotAmmo_LoadLegacy(player, drop.weapon);
};

float(entity player, float wep) W_SlotAmmo_HudMag =
{
    W_SlotAmmo_GetForWeapon(player, wep);
    return slotammo_mag;
};

float(entity player, float wep) W_SlotAmmo_HudAmmo =
{
    W_SlotAmmo_GetForWeapon(player, wep);
    if (slotammo_mag <= 0 && slotammo_ammo > 0)
        return slotammo_ammo;
    return slotammo_ammo;
};

// The "charge" weapons: no magazine, and a reserve that is a bounded pool the
// weapon regenerates into or spends out of, rather than an open-ended ammo
// count you top up from pickups.  Hornetgun and shock rifle regrow theirs every
// tick (SH_HGunRegrow / SH_ShockRegrow); the displacer and tesla spend a fixed
// cost per shot out of a fixed capacitor.  These read as "current / max" so the
// regeneration is legible — a bare "6" gives no sense of how close to full the
// hive is, and is indistinguishable from a weapon that is simply low.
//
// Deliberately NOT every mag-less weapon: the gauss and egon draw from an
// ordinary reserve that pickups refill, so they keep the single-number layout
// they have always had.
// Shell-by-shell loaders whose per-shell ammo credit happens ONLY in their
// server-side frame function, so the client cannot predict the magazine
// climbing during a reload.
//
// The client's ammo reconcile normally refuses a snapshot that is older than its
// own last predicted action, which is right for a weapon that predicts its own
// reload — force-syncing mid-reload would corrupt its apply arithmetic.  For
// these two there is nothing to corrupt: the client never moves the ammo at all,
// so the HUD simply froze for the whole reload (5.9 s on the shotgun) and only
// caught up at the end.  Trusting the server for these makes the count climb
// live, one ping behind, which is as good as a server-driven reload can be.
//
// You cannot fire mid-reload for these except by CANCELLING the reload, and the
// cancel is a fresh action that bumps wep_action_id, so there is no window where
// a predicted fire decrement could be overwritten by a stale snapshot.
float(float wep) W_ReloadIsServerDriven =
{
    // The Shorty is the third of these — pizza_ya_san's shortened HL shotgun is
    // a shell-at-a-time loader for the same reason the other two are, and its
    // per-shell credit likewise lives only in W_ASShotgunFrame.  Before it was
    // listed here its magazine was applied in ONE lump by SH_StandardTickState
    // at the very end of the reload, so the HUD sat still through all four
    // inserts and then jumped by the whole magazine.
    return wep == WEP_CSM3 || wep == WEP_HLSHOTGUN || wep == WEP_ASSHOTGUN;
};

float(float wep) W_SlotAmmo_IsCharge =
{
    return wep == WEP_HORNETGUN || wep == WEP_SHOCKRIFLE
        || wep == WEP_DISPLACER  || wep == WEP_THTESLA
        // Belt-fed, no magazine and no reload animation in the model, so the
        // two-number "mag / reserve" layout has nothing to put in the first
        // slot.  Same for the medkit's charge and the SOFLAM's five calls.
        || wep == WEP_MINIGUN    || wep == WEP_MEDKIT
        || wep == WEP_ASSOFLAM;
};

// Second number in the "a / b" layout: reserve for a mag weapon, pool ceiling
// for a charge weapon.  The ceiling comes from the manifest, so a weapon that
// changes capacity does not need a second edit here.
float(entity player, float wep) W_SlotAmmo_HudSecondaryValue =
{
    W_SlotAmmo_GetForWeapon(player, wep);
    if (WeaponManifest_DefaultMag(wep) > 0)
        return slotammo_ammo;
    return WeaponManifest_DefaultAmmo(wep);
};

float(entity player, float wep) W_SlotAmmo_HudFormat =
{
    // "Mag / Reserve" pair display when the weapon has a mag at all
    // (default mag size from the manifest > 0).  Without this gate the
    // HUD dropped the "0 /" prefix the moment the mag emptied —
    // showing just "120" while the player was actually out of mag —
    // which made the reload state ambiguous.  Now mag-using weapons
    // always render as "mag / reserve", and weapons that genuinely
    // have no mag (Gauss, Egon, grenade launcher, etc.) keep the
    // single-value layout.
    if (WeaponManifest_DefaultMag(wep) > 0)
        return 1;
    // Charge weapons borrow the same two-number layout — see W_SlotAmmo_IsCharge.
    if (W_SlotAmmo_IsCharge(wep))
        return 1;
    return 2;
};

float(entity player, float wep) W_SlotAmmo_HudPrimaryValue =
{
    W_SlotAmmo_GetForWeapon(player, wep);
    // Mag-using weapons always render mag as the first number
    // (matches the format-1 layout in HUD_CacheAmmoString); only
    // mag-less weapons fall through to showing reserve.
    if (WeaponManifest_DefaultMag(wep) > 0)
        return slotammo_mag;
    return slotammo_ammo;
};
