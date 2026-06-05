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

void(entity player, float wep) W_SlotAmmo_LoadLegacy =
{
    W_SlotAmmo_GetForWeapon(player, wep);

         if (wep == WEP_AK47 || wep == WEP_HDAK47) { player.mag_ak47 = slotammo_mag; player.ammo_ak47 = slotammo_ammo; }
    else if (wep == WEP_M4A1)            { player.mag_m4a1 = slotammo_mag; player.ammo_m4a1 = slotammo_ammo; player.m4a1_silenced = slotammo_aux; }
    else if (wep == WEP_CSAWP)           { player.mag_awp = slotammo_mag; player.ammo_awp = slotammo_ammo; }
    else if (wep == WEP_G3SG1)           { player.mag_g3sg1 = slotammo_mag; player.ammo_g3sg1 = slotammo_ammo; }
    else if (wep == WEP_CSM3)            { player.mag_m3 = slotammo_mag; player.ammo_m3 = slotammo_ammo; }
    else if (wep == WEP_CSMP5)           { player.mag_mp5 = slotammo_mag; player.ammo_mp5 = slotammo_ammo; }
    else if (wep == WEP_DOD98K)          { player.mag_98k = slotammo_mag; player.ammo_98k = slotammo_ammo; }
    else if (wep == WEP_FLAKSHOTGUN)     { player.mag_flakshotgun = slotammo_mag; }
    else if (wep == WEP_GAUSS)           { player.ammo_gauss = slotammo_ammo; }
    else if (wep == WEP_GRENADELAUNCHER) { player.mag_grenadelauncher = slotammo_mag; }
    else if (wep == WEP_CROSSBOW)        { player.mag_crossbow = slotammo_mag; player.ammo_crossbow = slotammo_ammo; }
    else if (wep == WEP_HLEGON)          { player.ammo_hlegon = slotammo_ammo; }
    else if (wep == WEP_HLRPG)           { player.mag_hlrpg = slotammo_mag; player.ammo_hlrpg = slotammo_ammo; }
    else if (wep == WEP_HLSHOTGUN)       { player.mag_shotgun = slotammo_mag; player.ammo_shotgun = slotammo_ammo; }
    else if (wep == WEP_HLSMG)           { player.mag_hlsmg = slotammo_mag; player.ammo_hlsmg = slotammo_ammo; player.ammo_hlsmg_grenades = slotammo_aux; }
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
    else if (wep == WEP_DEAGLE)          { player.mag_deagle = slotammo_mag; player.ammo_deagle = slotammo_ammo; }
    else if (wep == WEP_GLOCK)           { player.mag_glock = slotammo_mag; player.ammo_glock = slotammo_ammo; }
    else if (wep == WEP_357)             { player.mag_357 = slotammo_mag; player.ammo_357 = slotammo_ammo; }
    else if (wep == WEP_HLGLOCK)         { player.mag_hlglock = slotammo_mag; player.ammo_hlglock = slotammo_ammo; }
    else if (wep == WEP_PISTOL)          { player.mag_pistol = slotammo_mag; player.ammo_pistol = slotammo_ammo; }
    else if (wep == WEP_CFFIVESEVEN)     { player.mag_cffiveseven = slotammo_mag; player.ammo_cffiveseven = slotammo_ammo; }
    else if (wep == WEP_CFDEAGLE)        { player.mag_cfdeagle = slotammo_mag; player.ammo_cfdeagle = slotammo_ammo; }
    else if (wep == WEP_CFAWP)           { player.mag_cfawp = slotammo_mag; player.ammo_cfawp = slotammo_ammo; }
    else if (wep == WEP_CFG3SG1)         { player.mag_cfg3sg1 = slotammo_mag; player.ammo_cfg3sg1 = slotammo_ammo; }
    else if (wep == WEP_CFELITE)         { player.mag_cfelite = slotammo_mag; player.ammo_cfelite = slotammo_ammo; }
    else if (wep == WEP_CFXM1014)        { player.mag_cfxm1014 = slotammo_mag; player.ammo_cfxm1014 = slotammo_ammo; }
    else if (wep == WEP_CFSCOUTM700)     { player.mag_cfscoutm700 = slotammo_mag; player.ammo_cfscoutm700 = slotammo_ammo; }
    else if (wep == WEP_CFM3)            { player.mag_cfm3 = slotammo_mag; player.ammo_cfm3 = slotammo_ammo; }
    else if (wep == WEP_CFGALIL)         { player.mag_cfgalil = slotammo_mag; player.ammo_cfgalil = slotammo_ammo; }
    else if (wep == WEP_CFGLOCK)         { player.mag_cfglock = slotammo_mag; player.ammo_cfglock = slotammo_ammo; }
    else if (wep == WEP_CFSG550)         { player.mag_cfsg550 = slotammo_mag; player.ammo_cfsg550 = slotammo_ammo; }
};

void(entity player, float wep) W_SlotAmmo_SaveLegacy =
{
         if (wep == WEP_AK47 || wep == WEP_HDAK47) W_SlotAmmo_SetForWeapon(player, wep, player.mag_ak47, player.ammo_ak47, 0);
    else if (wep == WEP_M4A1)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_m4a1, player.ammo_m4a1, player.m4a1_silenced);
    else if (wep == WEP_CSAWP)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_awp, player.ammo_awp, 0);
    else if (wep == WEP_G3SG1)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_g3sg1, player.ammo_g3sg1, 0);
    else if (wep == WEP_CSM3)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_m3, player.ammo_m3, 0);
    else if (wep == WEP_CSMP5)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_mp5, player.ammo_mp5, 0);
    else if (wep == WEP_DOD98K)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_98k, player.ammo_98k, 0);
    else if (wep == WEP_FLAKSHOTGUN)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_flakshotgun, 0, 0);
    else if (wep == WEP_GAUSS)           W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_gauss, 0);
    else if (wep == WEP_GRENADELAUNCHER) W_SlotAmmo_SetForWeapon(player, wep, player.mag_grenadelauncher, 0, 0);
    else if (wep == WEP_CROSSBOW)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_crossbow, player.ammo_crossbow, 0);
    else if (wep == WEP_HLEGON)          W_SlotAmmo_SetForWeapon(player, wep, 0, player.ammo_hlegon, 0);
    else if (wep == WEP_HLRPG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlrpg, player.ammo_hlrpg, 0);
    else if (wep == WEP_HLSHOTGUN)       W_SlotAmmo_SetForWeapon(player, wep, player.mag_shotgun, player.ammo_shotgun, 0);
    else if (wep == WEP_HLSMG)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlsmg, player.ammo_hlsmg, player.ammo_hlsmg_grenades);
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
    else if (wep == WEP_DEAGLE)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_deagle, player.ammo_deagle, 0);
    else if (wep == WEP_GLOCK)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_glock, player.ammo_glock, 0);
    else if (wep == WEP_357)             W_SlotAmmo_SetForWeapon(player, wep, player.mag_357, player.ammo_357, 0);
    else if (wep == WEP_HLGLOCK)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_hlglock, player.ammo_hlglock, 0);
    else if (wep == WEP_PISTOL)          W_SlotAmmo_SetForWeapon(player, wep, player.mag_pistol, player.ammo_pistol, 0);
    else if (wep == WEP_CFFIVESEVEN)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_cffiveseven, player.ammo_cffiveseven, 0);
    else if (wep == WEP_CFDEAGLE)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfdeagle, player.ammo_cfdeagle, 0);
    else if (wep == WEP_CFAWP)           W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfawp, player.ammo_cfawp, 0);
    else if (wep == WEP_CFG3SG1)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfg3sg1, player.ammo_cfg3sg1, 0);
    else if (wep == WEP_CFELITE)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfelite, player.ammo_cfelite, 0);
    else if (wep == WEP_CFXM1014)        W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfxm1014, player.ammo_cfxm1014, 0);
    else if (wep == WEP_CFSCOUTM700)     W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfscoutm700, player.ammo_cfscoutm700, 0);
    else if (wep == WEP_CFM3)            W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfm3, player.ammo_cfm3, 0);
    else if (wep == WEP_CFGALIL)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfgalil, player.ammo_cfgalil, 0);
    else if (wep == WEP_CFGLOCK)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfglock, player.ammo_cfglock, 0);
    else if (wep == WEP_CFSG550)         W_SlotAmmo_SetForWeapon(player, wep, player.mag_cfsg550, player.ammo_cfsg550, 0);
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
    else if (wep == WEP_SNOWBALL)        drop.weapon_drop_ammo = player.ammo_snowball;
    else if (wep == WEP_CSHEGRENADE)     drop.weapon_drop_ammo = player.ammo_cshegrenade;
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
