// ============================================================
//  shared/sh_weapon_manifest.qc
//
//  Metadata-only weapon manifest shared by menu, CSQC, and SSQC.
//  Keep this file free of entity fields and weapon implementation symbols
//  so MenuQC can include it too.
// ============================================================

const float WMF_WEP_NONE            = 0;
const float WMF_WEP_DEAGLE          = 1;
const float WMF_WEP_KNIFE           = 2;
const float WMF_WEP_AK47            = 3;
const float WMF_WEP_M4A1            = 4;
const float WMF_WEP_FLAKSHOTGUN     = 5;
const float WMF_WEP_PISTOL          = 6;
const float WMF_WEP_GAUSS           = 7;
const float WMF_WEP_CROSSBOW        = 8;
const float WMF_WEP_357             = 9;
const float WMF_WEP_DOD98K          = 10;
const float WMF_WEP_SCOUT           = 11;
const float WMF_WEP_GRENADELAUNCHER = 12;
const float WMF_WEP_M249            = 13;
const float WMF_WEP_HLCROWBAR       = 14;
const float WMF_WEP_HLSHOTGUN       = 15;
const float WMF_WEP_CSM3            = 16;
const float WMF_WEP_CSMP5           = 17;
const float WMF_WEP_REBAR           = 18;
const float WMF_WEP_CSAWP           = 19;
const float WMF_WEP_WRENCH          = 20;
const float WMF_WEP_GLOCK           = 21;
const float WMF_WEP_G3SG1           = 22;
const float WMF_WEP_HLSMG           = 23;
const float WMF_WEP_HLRPG           = 24;
const float WMF_WEP_HLGRENADE       = 25;
const float WMF_WEP_HLGLOCK         = 26;
const float WMF_WEP_HLEGON          = 27;
const float WMF_WEP_CSUSP           = 28;
const float WMF_WEP_HDAK47          = 29;
const float WMF_WEP_SNOWBALL        = 30;
const float WMF_WEP_SLINGSHOT       = 31;
const float WMF_WEP_PAINTBALL       = 32;
const float WMF_WEP_CSHEGRENADE     = 33;
const float WMF_WEP_CSFLASHBANG     = 34;
const float WMF_WEP_CSSMOKEGRENADE  = 35;
const float WMF_WEP_BUTTERFLY       = 36;
const float WMF_WEP_CFAUG           = 37;
const float WMF_WEP_CFFAMAS         = 38;
const float WMF_WEP_CFMAC10         = 39;
const float WMF_WEP_CFC4            = 40;
const float WMF_WEP_MELEE           = 41;
const float WMF_WEP_KATANA          = 42;
const float WMF_WEP_CFM9     = 43;
const float WMF_WEP_CFREVOLVER        = 44;
const float WMF_WEP_CFBARRETT           = 45;
const float WMF_WEP_CFPSG1         = 46;
const float WMF_WEP_CFDDEAGLE         = 47;
const float WMF_WEP_CFSPAS12        = 48;
const float WMF_WEP_CFM700     = 49;
const float WMF_WEP_CFM3            = 50;
const float WMF_WEP_CFSCAR         = 51;
const float WMF_WEP_CFMAUSER         = 52;
const float WMF_WEP_CFSVD         = 53;
const float WMF_WEP_CFMP5           = 54;
const float WMF_WEP_CFVECTOR        = 55;
const float WMF_WEP_CFTYPE89        = 56;
const float WMF_WEP_CFUMP45         = 57;
const float WMF_WEP_CFM249          = 58;
const float WMF_WEP_CFAWM           = 59;
const float WMF_WEP_CFKS23          = 60;
const float WMF_WEP_CFM4            = 61;
const float WMF_WEP_CFMK23          = 62;
const float WMF_WEP_CFGALIL         = 63;
const float WMF_WEP_CFGLOCK         = 64;
const float WMF_WEP_CFELITE         = 65;
const float WMF_WEP_CFP228          = 66;
const float WMF_WEP_CFMSG90         = 67;
const float WMF_WEP_CFSG552         = 68;
const float WMF_WEP_CFSL8           = 69;
const float WMF_WEP_LAST            = 69;

const float WMF_SLOT_NONE      = 0;
const float WMF_SLOT_PRIMARY   = 1;
const float WMF_SLOT_SECONDARY = 2;
const float WMF_SLOT_MELEE     = 3;
const float WMF_SLOT_UTILITY   = 4;

const float WMF_FLAG_LOADOUT   = 1;
const float WMF_FLAG_DEBUG     = 2;
const float WMF_FLAG_CROSSHAIR = 4;
const float WMF_FLAG_SCOPE     = 8;

const float WMF_PANIM_NONE    = 0;
const float WMF_PANIM_ONEHAND = 1;
const float WMF_PANIM_CARBINE = 2;
const float WMF_PANIM_RIFLE   = 3;
const float WMF_PANIM_MP5     = 4;
const float WMF_PANIM_SHOTGUN = 5;
const float WMF_PANIM_PARA    = 6;
const float WMF_PANIM_KNIFE   = 7;
const float WMF_PANIM_GRENADE = 8;
const float WMF_PANIM_AK47    = 9;

float  weapon_manifest_slot;
float  weapon_manifest_flags;
float  weapon_manifest_speed;
float  weapon_manifest_anim;
float  weapon_manifest_default_mag;
float  weapon_manifest_default_ammo;
float  weapon_manifest_default_aux;
float  weapon_manifest_loadout_order;
float  weapon_manifest_debug_order;
string weapon_manifest_display;
string weapon_manifest_hud;
string weapon_manifest_menu;
string weapon_manifest_pmodel;

void(float slot, string display, string hud, string menu,
     float flags, float speed, float anim, string pmodel,
     float def_mag, float def_ammo, float def_aux,
     float loadout_order, float debug_order) WeaponManifest_Set =
{
    weapon_manifest_slot = slot;
    weapon_manifest_display = display;
    weapon_manifest_hud = hud;
    weapon_manifest_menu = menu;
    weapon_manifest_flags = flags;
    weapon_manifest_speed = speed;
    weapon_manifest_anim = anim;
    weapon_manifest_pmodel = pmodel;
    weapon_manifest_default_mag = def_mag;
    weapon_manifest_default_ammo = def_ammo;
    weapon_manifest_default_aux = def_aux;
    weapon_manifest_loadout_order = loadout_order;
    weapon_manifest_debug_order = debug_order;
};

float(float wep) WeaponManifest_Load =
{
    switch (wep)
    {
    case WMF_WEP_AK47:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AK47", "AK47", "AK47", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_AK47, "models/weapons/wpn_csak47/p_ak47.mdl", 30, 90, 0, 1, 1); return TRUE;
    case WMF_WEP_HDAK47:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HD AK47", "HD AK47", "HD AK47", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_AK47, "models/weapons/wpn_hdak47/p_ak47.mdl", 30, 90, 0, 2, 2); return TRUE;
    case WMF_WEP_CFAUG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AUG", "AUG", "AUG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfaug/p_aug.mdl", 30, 90, 0, 21, 37); return TRUE;
    case WMF_WEP_CFFAMAS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "FAMAS", "FAMAS", "FAMAS", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cffamas/p_famas.mdl", 25, 90, 0, 22, 38); return TRUE;
    case WMF_WEP_CFMAC10:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MAC10", "MAC10", "MAC10", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_cfmac10/p_mac10.mdl", 30, 100, 0, 23, 39); return TRUE;
    case WMF_WEP_M4A1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M4A1", "M4A1", "M4A1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "models/weapons/wpn_csm4a1/p_m4a1.mdl", 30, 90, 1, 3, 3); return TRUE;
    case WMF_WEP_CSAWP:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AWP", "AWP", "AWP", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_csawp/p_awp.mdl", 10, 20, 0, 4, 4); return TRUE;
    case WMF_WEP_G3SG1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "G3SG1", "G3SG1", "G3SG1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/weapons/wpn_csg3sg1/p_g3sg1.mdl", 20, 60, 0, 5, 5); return TRUE;
    case WMF_WEP_CSM3:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M3", "M3", "M3", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/weapons/wpn_csm3/p_m3.mdl", 8, 24, 0, 6, 6); return TRUE;
    case WMF_WEP_CSMP5:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MP5", "MP5", "MP5", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_csmp5/p_mp5.mdl", 30, 120, 0, 7, 7); return TRUE;
    case WMF_WEP_PAINTBALL:
        // pmodel intentionally empty — p_excal.mdl has no skeletal
        // bones the player attach pipeline can hook into, so it ends
        // up rendered at world origin.  Empty path makes
        // CSQC_PlayerVisualProxy_Predraw skip the attachment entirely.
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Paintball", "PAINTBALL", "Paintball", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "", 100, 200, 0, 8, 8); return TRUE;
    case WMF_WEP_DOD98K:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "K98", "98K", "K98", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "models/weapons/wpn_dod98k/p_k98.mdl", 5, 25, 0, 9, 9); return TRUE;
    case WMF_WEP_FLAKSHOTGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Flak Shotgun", "SHOTGUN", "Flak Shotgun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "", 24, 0, 0, 10, 10); return TRUE;
    case WMF_WEP_GAUSS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Gauss", "GAUSS", "Gauss", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "", 0, 120, 0, 11, 11); return TRUE;
    case WMF_WEP_GRENADELAUNCHER:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Grenade Launcher", "GL", "Grenade Launcher", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_GRENADE, "", 6, 0, 0, 12, 12); return TRUE;
    case WMF_WEP_CROSSBOW:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Crossbow", "CROSSBOW", "Crossbow", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.97, WMF_PANIM_CARBINE, "", 5, 10, 0, 13, 13); return TRUE;
    case WMF_WEP_HLEGON:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Egon", "EGON", "Egon", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "", 0, 100, 0, 14, 14); return TRUE;
    case WMF_WEP_HLRPG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "RPG", "RPG", "RPG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "", 1, 5, 0, 15, 15); return TRUE;
    case WMF_WEP_HLSHOTGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HL Shotgun", "SHOTGUN", "HL Shotgun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "", 8, 24, 0, 16, 16); return TRUE;
    case WMF_WEP_HLSMG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HL SMG", "SMG", "HL SMG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_CARBINE, "", 50, 250, 2, 17, 17); return TRUE;
    case WMF_WEP_M249:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M249", "M249", "M249", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_PARA, "models/weapons/wpn_csm249/p_m249.mdl", 50, 150, 0, 18, 18); return TRUE;
    case WMF_WEP_REBAR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Rebar", "REBAR", "Rebar", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 1.0, WMF_PANIM_CARBINE, "", 12, 0, 0, 19, 19); return TRUE;
    case WMF_WEP_SCOUT:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scout", "SCOUT", "Scout", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.945, WMF_PANIM_CARBINE, "models/weapons/wpn_csscout/p_scout.mdl", 10, 30, 0, 20, 20); return TRUE;

    case WMF_WEP_CSUSP:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "USP", "USP-45", "USP", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_csusp/p_usp.mdl", 12, 24, 0, 1, 27); return TRUE;
    case WMF_WEP_DEAGLE:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Desert Eagle", "DEAGLE", "Desert Eagle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/weapons/wpn_csdeagle/p_deagle.mdl", 7, 35, 0, 2, 28); return TRUE;
    case WMF_WEP_GLOCK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Glock", "GLOCK", "Glock", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_csglock/p_glock.mdl", 20, 40, 0, 3, 29); return TRUE;
    case WMF_WEP_357:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, ".357", ".357", ".357", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "", 6, 18, 0, 4, 30); return TRUE;
    case WMF_WEP_HLGLOCK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "HL Glock", "HL GLOCK", "HL Glock", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "", 17, 250, 0, 5, 31); return TRUE;
    case WMF_WEP_PISTOL:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "9mm", "PISTOL", "9mm", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "", 12, 24, 0, 6, 32); return TRUE;
    case WMF_WEP_CFM9:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Beretta M9", "M9", "Beretta M9", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfm9/p_m9.mdl", 15, 90, 0, 7, 42); return TRUE;
    case WMF_WEP_CFREVOLVER:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Colt Anaconda", "ANACONDA", "Colt Anaconda", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfrevolver/p_revolver.mdl", 6, 36, 0, 8, 43); return TRUE;
    case WMF_WEP_CFDDEAGLE:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Dual Desert Deagle", "ELITE", "Dual Desert Deagle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfddeagle/p_ddeagle.mdl", 30, 90, 0, 9, 44); return TRUE;
    case WMF_WEP_CFBARRETT:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Barrett M82", "BARRETT", "Barrett M82", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_cfbarrett/p_barrett.mdl", 10, 30, 0, 24, 45); return TRUE;
    case WMF_WEP_CFPSG1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "PSG1", "PSG1", "PSG1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/weapons/wpn_psg1/p_psg1.mdl", 20, 60, 0, 25, 46); return TRUE;
    case WMF_WEP_CFSPAS12:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SPAS-12", "SPAS-12", "SPAS-12", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/weapons/wpn_cfspas12/p_spas12.mdl", 8, 32, 0, 26, 47); return TRUE;
    case WMF_WEP_CFM700:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M700", "M700", "M700", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfm700/p_m700.mdl", 5, 30, 0, 27, 48); return TRUE;
    case WMF_WEP_CFM3:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Winchester", "WINCHESTER", "Winchester", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfm3/p_m3.mdl", 7, 28, 0, 28, 49); return TRUE;
    case WMF_WEP_CFSCAR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "FN SCAR", "SCAR", "FN SCAR", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfscar/p_scar.mdl", 30, 90, 0, 29, 50); return TRUE;
    case WMF_WEP_CFMAUSER:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "C96 Mauser", "MAUSER", "C96 Mauser", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfmauser/p_mauser.mdl", 10, 60, 0, 10, 51); return TRUE;
    case WMF_WEP_CFSVD:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SVD Dragunov", "DRAGUNOV", "SVD Dragunov", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/weapons/wpn_cfsvd/p_svd.mdl", 10, 30, 0, 30, 52); return TRUE;
    case WMF_WEP_CFMP5:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "CF MP5", "CF MP5", "CF MP5", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_cfmp5/p_mp5.mdl", 30, 120, 0, 31, 53); return TRUE;
    case WMF_WEP_CFVECTOR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Vector", "VECTOR", "Vector", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_cfvector/p_vector.mdl", 25, 125, 0, 32, 54); return TRUE;
    case WMF_WEP_CFTYPE89:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Type 89", "TYPE89", "Type 89", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cftype89/p_type89.mdl", 30, 90, 0, 33, 55); return TRUE;
    case WMF_WEP_CFUMP45:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "UMP45", "UMP45", "UMP45", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_cfump45/p_ump45.mdl", 25, 100, 0, 34, 56); return TRUE;
    case WMF_WEP_CFM249:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M249", "M249", "M249", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_PARA, "models/weapons/wpn_cfm249/p_m249.mdl", 100, 200, 0, 35, 57); return TRUE;
    case WMF_WEP_CFAWM:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AWM", "AWM", "AWM", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_cfawm/p_awm.mdl", 10, 30, 0, 36, 58); return TRUE;
    case WMF_WEP_CFKS23:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "KS-23", "KS-23", "KS-23", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_SHOTGUN, "models/weapons/wpn_cfks23/p_ks23.mdl", 3, 12, 0, 37, 59); return TRUE;
    case WMF_WEP_CFM4:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M4 Super 90", "M4SUPER90", "M4 Super 90", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.93, WMF_PANIM_SHOTGUN, "models/weapons/wpn_cfm4/p_m4.mdl", 7, 32, 0, 38, 60); return TRUE;
    case WMF_WEP_CFMK23:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "MK23 SOCOM", "MK23", "MK23 SOCOM", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfmk23/p_mk23.mdl", 12, 36, 0, 11, 61); return TRUE;
    case WMF_WEP_CFGALIL:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Galil", "GALIL", "Galil", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfgalil/p_galil.mdl", 35, 90, 0, 39, 62); return TRUE;
    case WMF_WEP_CFGLOCK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Glock 18", "GLOCK18", "Glock 18", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfglock/p_glock18.mdl", 20, 120, 0, 12, 63); return TRUE;
    case WMF_WEP_CFELITE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scout Elite", "SCOUTELITE", "Scout Elite", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_cfelite/p_scout.mdl", 10, 30, 0, 40, 64); return TRUE;
    case WMF_WEP_CFP228:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "P228", "P228", "P228", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfp228/p_p228.mdl", 13, 52, 0, 13, 65); return TRUE;
    case WMF_WEP_CFMSG90:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MSG90", "MSG90", "MSG90", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_cfmsg90/p_msg90.mdl", 10, 30, 0, 41, 66); return TRUE;
    case WMF_WEP_CFSG552:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SG552", "SG552", "SG552", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfsg552/p_sg552.mdl", 30, 90, 0, 42, 67); return TRUE;
    case WMF_WEP_CFSL8:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SL8", "SL8", "SL8", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfsl8/p_sl8.mdl", 20, 80, 0, 43, 68); return TRUE;

    case WMF_WEP_WRENCH:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Wrench", "WRENCH", "Wrench", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "", 0, 0, 0, 1, 33); return TRUE;
    case WMF_WEP_KNIFE:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Knife", "KNIFE", "Knife", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/weapons/wpn_csknife/p_knife.mdl", 0, 0, 0, 2, 34); return TRUE;
    case WMF_WEP_HLCROWBAR:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Crowbar", "CROWBAR", "Crowbar", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "", 0, 0, 0, 3, 35); return TRUE;
    case WMF_WEP_BUTTERFLY:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Butterfly", "BALISONG", "Butterfly", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/weapons/wpn_butteryfly/p_knife.mdl", 0, 0, 0, 4, 36); return TRUE;
    case WMF_WEP_MELEE:
        // Fists — INTRINSIC.  No menu flags (LOADOUT / DEBUG both
        // omitted) so they don't appear in the create-server
        // loadout dropdown or the F2 debug spawn list.  The slot
        // dispatch in sv_player.qc unconditionally backfills
        // slot_melee = WEP_MELEE when no other melee is equipped,
        // so the manifest entry is only here to provide a display
        // name + p_model lookup for HUD / scoreboard code.
        WeaponManifest_Set(WMF_SLOT_MELEE, "Fists", "FISTS", "Fists", 0, 1.0, WMF_PANIM_KNIFE, "", 0, 0, 0, 0, 0); return TRUE;
    case WMF_WEP_KATANA:
        // Loadout / debug orders are CONTIGUOUS lookup indices —
        // WeaponManifest_LoadoutWeapon walks 1..N looking for an
        // exact match.  A gap (e.g. order=6 with no order=5 in the
        // same slot) leaves a "None" hole in the dropdown.  Melee
        // slot currently fills 1..4 with wrench/knife/crowbar/
        // butterfly, so katana takes 5.  Global debug grid runs
        // 1..40 (CFC4 was the previous tail at 40) → katana = 41.
        WeaponManifest_Set(WMF_SLOT_MELEE, "Katana", "KATANA", "Katana", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/weapons/wpn_katana/p_katana.mdl", 0, 0, 0, 5, 41); return TRUE;

    case WMF_WEP_HLGRENADE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Grenade", "GRENADE", "Grenade", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "", 0, 5, 0, 1, 21); return TRUE;
    case WMF_WEP_SNOWBALL:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Snowball", "SNOWBALL", "Snowball", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_snowball/p_snowball.mdl", 0, 50, 0, 2, 22); return TRUE;
    case WMF_WEP_SLINGSHOT:
        // Slingshot is the snowball-upgrade variant; selecting it as a
        // loadout item gives the player snowball ammo plus the
        // slingshot bonus (handled in W_GiveStartingAmmo).
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Slingshot", "SLINGSHOT", "Slingshot", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "", 0, 0, 0, 6, 23); return TRUE;
    case WMF_WEP_CSHEGRENADE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "HE Grenade", "HE", "HE Grenade", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_cshegrenade/p_hegrenade.mdl", 0, 1, 0, 3, 24); return TRUE;
    case WMF_WEP_CSFLASHBANG:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Flashbang", "FLASH", "Flashbang", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_csflashbang/p_flashbang.mdl", 0, 1, 0, 4, 25); return TRUE;
    case WMF_WEP_CSSMOKEGRENADE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Smoke Grenade", "SMOKE", "Smoke", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_cssmokegrenade/p_smokegrenade.mdl", 0, 1, 0, 5, 26); return TRUE;
    case WMF_WEP_CFC4:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "C4", "C4", "C4", WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_cfc4/p_c4.mdl", 0, 1, 0, 0, 40); return TRUE;
    }

    WeaponManifest_Set(WMF_SLOT_NONE, "?", "", "", 0, 1.0, WMF_PANIM_ONEHAND, "", 0, 0, 0, 0, 0);
    return FALSE;
};

string(string raw) WeaponManifest_NameKey =
{
    raw = strtolower(raw);
    raw = strreplace(" ", "", raw);
    raw = strreplace("_", "", raw);
    raw = strreplace("-", "", raw);
    raw = strreplace(".", "", raw);
    return raw;
};

float(string key) WeaponManifest_IdFromKey =
{
    if (key == "none" || key == "wepnone") return WMF_WEP_NONE;
    if (key == "usp" || key == "csusp" || key == "wepcsusp" || key == "wpncsusp") return WMF_WEP_CSUSP;
    if (key == "deagle" || key == "deserteagle" || key == "wepdeagle") return WMF_WEP_DEAGLE;
    if (key == "knife" || key == "wepknife") return WMF_WEP_KNIFE;
    if (key == "ak47" || key == "wepak47") return WMF_WEP_AK47;
    if (key == "hdak47" || key == "wephdak47") return WMF_WEP_HDAK47;
    if (key == "m4a1" || key == "wepm4a1") return WMF_WEP_M4A1;
    if (key == "flakshotgun" || key == "wepflakshotgun") return WMF_WEP_FLAKSHOTGUN;
    if (key == "9mm" || key == "pistol" || key == "weppistol") return WMF_WEP_PISTOL;
    if (key == "gauss" || key == "wepgauss") return WMF_WEP_GAUSS;
    if (key == "crossbow" || key == "wepcrossbow") return WMF_WEP_CROSSBOW;
    if (key == "357" || key == "wep357") return WMF_WEP_357;
    if (key == "k98" || key == "dod98k" || key == "wepdod98k") return WMF_WEP_DOD98K;
    if (key == "scout" || key == "wepscout") return WMF_WEP_SCOUT;
    if (key == "gl" || key == "grenadelauncher" || key == "wepgrenadelauncher") return WMF_WEP_GRENADELAUNCHER;
    if (key == "m249" || key == "wepm249") return WMF_WEP_M249;
    if (key == "crowbar" || key == "hlcrowbar" || key == "wephlcrowbar") return WMF_WEP_HLCROWBAR;
    if (key == "hlshotgun" || key == "wephlshotgun") return WMF_WEP_HLSHOTGUN;
    if (key == "m3" || key == "csm3" || key == "wepcsm3") return WMF_WEP_CSM3;
    if (key == "mp5" || key == "csmp5" || key == "wepcsmp5") return WMF_WEP_CSMP5;
    if (key == "rebar" || key == "weprebar") return WMF_WEP_REBAR;
    if (key == "awp" || key == "csawp" || key == "wepcsawp") return WMF_WEP_CSAWP;
    if (key == "wrench" || key == "wepwrench") return WMF_WEP_WRENCH;
    if (key == "glock" || key == "wepglock") return WMF_WEP_GLOCK;
    if (key == "g3sg1" || key == "wepg3sg1") return WMF_WEP_G3SG1;
    if (key == "hlsmg" || key == "wephlsmg") return WMF_WEP_HLSMG;
    if (key == "rpg" || key == "hlrpg" || key == "wephlrpg") return WMF_WEP_HLRPG;
    if (key == "grenade" || key == "hlgrenade" || key == "wephlgrenade") return WMF_WEP_HLGRENADE;
    if (key == "hlglock" || key == "wephlglock") return WMF_WEP_HLGLOCK;
    if (key == "egon" || key == "hlegon" || key == "wephlegon") return WMF_WEP_HLEGON;
    if (key == "snowball" || key == "wepsnowball" || key == "wpnsnowball") return WMF_WEP_SNOWBALL;
    if (key == "slingshot" || key == "wepslingshot" || key == "wpnslingshot") return WMF_WEP_SLINGSHOT;
    if (key == "paintball" || key == "excal" || key == "weppaintball" || key == "wpnpaintball") return WMF_WEP_PAINTBALL;
    if (key == "he" || key == "hegrenade" || key == "cshegrenade" || key == "wepcshegrenade" || key == "wpncshegrenade") return WMF_WEP_CSHEGRENADE;
    if (key == "flash" || key == "flashbang" || key == "csflashbang" || key == "wepcsflashbang" || key == "wpncsflashbang") return WMF_WEP_CSFLASHBANG;
    if (key == "smoke" || key == "smokegrenade" || key == "cssmokegrenade" || key == "wepcssmokegrenade" || key == "wpncssmokegrenade") return WMF_WEP_CSSMOKEGRENADE;
    if (key == "butterfly" || key == "balisong" || key == "wepbutterfly" || key == "wpnbutterfly") return WMF_WEP_BUTTERFLY;
    if (key == "aug" || key == "cfaug" || key == "wepcfaug" || key == "wpncfaug") return WMF_WEP_CFAUG;
    if (key == "famas" || key == "cffamas" || key == "wepcffamas" || key == "wpncffamas") return WMF_WEP_CFFAMAS;
    if (key == "mac10" || key == "cfmac10" || key == "wepcfmac10" || key == "wpncfmac10") return WMF_WEP_CFMAC10;
    if (key == "m9" || key == "beretta" || key == "fiveseven" || key == "cfm9" || key == "wepcfm9" || key == "wpncfm9") return WMF_WEP_CFM9;
    if (key == "anaconda" || key == "colt" || key == "cfrevolver" || key == "wepcfrevolver" || key == "wpncfrevolver") return WMF_WEP_CFREVOLVER;
    if (key == "barrett" || key == "cfbarrett" || key == "wepcfbarrett" || key == "wpncfbarrett") return WMF_WEP_CFBARRETT;
    if (key == "psg1" || key == "cfpsg1" || key == "wepcfpsg1" || key == "wpncfpsg1") return WMF_WEP_CFPSG1;
    if (key == "ddeagle" || key == "elites" || key == "duals" || key == "cfddeagle" || key == "wepcfddeagle" || key == "wpncfddeagle") return WMF_WEP_CFDDEAGLE;
    if (key == "spas" || key == "spas12" || key == "xm1014" || key == "cfspas12") return WMF_WEP_CFSPAS12;
    if (key == "m700" || key == "remington" || key == "cfscout" || key == "cfm700") return WMF_WEP_CFM700;
    if (key == "winchester" || key == "cfm3") return WMF_WEP_CFM3;
    if (key == "scar" || key == "fnscar" || key == "cfscar") return WMF_WEP_CFSCAR;
    if (key == "mauser" || key == "c96" || key == "cfmauser") return WMF_WEP_CFMAUSER;
    if (key == "dragunov" || key == "svd" || key == "cfsvd" || key == "sg550") return WMF_WEP_CFSVD;
    if (key == "c4" || key == "cfc4" || key == "wepcfc4" || key == "wpncfc4") return WMF_WEP_CFC4;
    if (key == "cfmp5" || key == "wepcfmp5" || key == "wpncfmp5") return WMF_WEP_CFMP5;
    if (key == "vector" || key == "cfvector" || key == "wepcfvector" || key == "wpncfvector") return WMF_WEP_CFVECTOR;
    if (key == "type89" || key == "cftype89" || key == "wepcftype89" || key == "wpncftype89") return WMF_WEP_CFTYPE89;
    if (key == "ump45" || key == "ump" || key == "cfump45" || key == "wepcfump45" || key == "wpncfump45") return WMF_WEP_CFUMP45;
    if (key == "cfm249" || key == "wepcfm249" || key == "wpncfm249") return WMF_WEP_CFM249;
    if (key == "awm" || key == "cfawm" || key == "wepcfawm" || key == "wpncfawm") return WMF_WEP_CFAWM;
    if (key == "ks23" || key == "cfks23" || key == "wepcfks23" || key == "wpncfks23") return WMF_WEP_CFKS23;
    if (key == "m4" || key == "cfm4" || key == "m4super90" || key == "wepcfm4" || key == "wpncfm4") return WMF_WEP_CFM4;
    if (key == "mk23" || key == "socom" || key == "cfmk23" || key == "wepcfmk23" || key == "wpncfmk23") return WMF_WEP_CFMK23;
    if (key == "galil" || key == "cfgalil" || key == "wepcfgalil" || key == "wpncfgalil") return WMF_WEP_CFGALIL;
    if (key == "glock18" || key == "cfglock" || key == "wepcfglock" || key == "wpncfglock") return WMF_WEP_CFGLOCK;
    if (key == "elite" || key == "scoutelite" || key == "cfelite" || key == "wepcfelite" || key == "wpncfelite") return WMF_WEP_CFELITE;
    if (key == "p228" || key == "cfp228" || key == "wepcfp228" || key == "wpncfp228") return WMF_WEP_CFP228;
    if (key == "msg90" || key == "cfmsg90" || key == "wepcfmsg90" || key == "wpncfmsg90") return WMF_WEP_CFMSG90;
    if (key == "sg552" || key == "cfsg552" || key == "wepcfsg552" || key == "wpncfsg552") return WMF_WEP_CFSG552;
    if (key == "sl8" || key == "cfsl8" || key == "wepcfsl8" || key == "wpncfsl8") return WMF_WEP_CFSL8;
    return -1;
};

float(string raw, float fallback) WeaponManifest_IdFromStringOrDefault =
{
    string key = WeaponManifest_NameKey(raw);
    float numeric;
    string numeric_key;
    float id;

    if (key == "")
        return fallback;

    numeric = stof(raw);
    numeric_key = WeaponManifest_NameKey(sprintf("%g", numeric));
    if (key == numeric_key && numeric == floor(numeric)
        && numeric >= WMF_WEP_NONE && numeric <= WMF_WEP_LAST)
        return numeric;

    id = WeaponManifest_IdFromKey(key);
    if (id >= 0)
        return id;

    return fallback;
};

float(float wep) WeaponManifest_Slot =
{
    if (!WeaponManifest_Load(wep)) return WMF_SLOT_NONE;
    return weapon_manifest_slot;
};

string(float wep) WeaponManifest_DisplayName =
{
    if (!WeaponManifest_Load(wep)) return "?";
    return weapon_manifest_display;
};

string(float wep) WeaponManifest_HudName =
{
    if (!WeaponManifest_Load(wep)) return "";
    return weapon_manifest_hud;
};

string(float wep) WeaponManifest_MenuName =
{
    if (!WeaponManifest_Load(wep)) return "";
    return weapon_manifest_menu;
};

float(float wep) WeaponManifest_HasCrosshair =
{
    if (!WeaponManifest_Load(wep)) return FALSE;
    return (weapon_manifest_flags & WMF_FLAG_CROSSHAIR) != 0;
};

float(float wep) WeaponManifest_HasScope =
{
    if (!WeaponManifest_Load(wep)) return FALSE;
    return (weapon_manifest_flags & WMF_FLAG_SCOPE) != 0;
};

float(float wep) WeaponManifest_SpeedFactor =
{
    if (!WeaponManifest_Load(wep)) return 1.0;
    return weapon_manifest_speed;
};

float(float wep) WeaponManifest_PlayerAnimFamily =
{
    if (!WeaponManifest_Load(wep)) return WMF_PANIM_ONEHAND;
    return weapon_manifest_anim;
};

string(float wep) WeaponManifest_PModelPath =
{
    if (!WeaponManifest_Load(wep)) return "";
    return weapon_manifest_pmodel;
};

float(float wep) WeaponManifest_DefaultMag =
{
    if (!WeaponManifest_Load(wep)) return 0;
    return weapon_manifest_default_mag;
};

float(float wep) WeaponManifest_DefaultAmmo =
{
    if (!WeaponManifest_Load(wep)) return 0;
    return weapon_manifest_default_ammo;
};

float(float wep) WeaponManifest_DefaultAux =
{
    if (!WeaponManifest_Load(wep)) return 0;
    return weapon_manifest_default_aux;
};

float(float slot, float idx) WeaponManifest_LoadoutWeapon =
{
    float want_order = idx;
    float wep;

    if (idx <= 0)
        return WMF_WEP_NONE;

    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_Load(wep))
            continue;
        if (weapon_manifest_slot == slot
            && (weapon_manifest_flags & WMF_FLAG_LOADOUT)
            && weapon_manifest_loadout_order == want_order)
            return wep;
    }
    return WMF_WEP_NONE;
};

float(float slot) WeaponManifest_LoadoutCount =
{
    float count = 1; // None
    float wep;
    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_Load(wep))
            continue;
        if (weapon_manifest_slot == slot
            && (weapon_manifest_flags & WMF_FLAG_LOADOUT))
            count = count + 1;
    }
    return count;
};

string(float slot, float idx) WeaponManifest_LoadoutLabel =
{
    float wep = WeaponManifest_LoadoutWeapon(slot, idx);
    if (idx <= 0 || wep == WMF_WEP_NONE)
        return "None";
    return WeaponManifest_MenuName(wep);
};

float(float slot, float wep) WeaponManifest_LoadoutFindIndex =
{
    float i;
    float count = WeaponManifest_LoadoutCount(slot);
    for (i = 0; i < count; i = i + 1)
        if (WeaponManifest_LoadoutWeapon(slot, i) == wep)
            return i;
    return 0;
};

float(float idx) WeaponManifest_DebugWeapon =
{
    float want_order = idx + 1;
    float wep;

    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_Load(wep))
            continue;
        if ((weapon_manifest_flags & WMF_FLAG_DEBUG)
            && weapon_manifest_debug_order == want_order)
            return wep;
    }
    return WMF_WEP_NONE;
};

float() WeaponManifest_DebugCount =
{
    float count = 0;
    float wep;
    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_Load(wep))
            continue;
        if (weapon_manifest_flags & WMF_FLAG_DEBUG)
            count = count + 1;
    }
    return count;
};
