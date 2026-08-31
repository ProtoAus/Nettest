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
const float WMF_WEP_GRAVITYGUN      = 70;
const float WMF_WEP_SATCHEL         = 71;
const float WMF_WEP_TRIPMINE        = 72;
const float WMF_WEP_SNARK           = 73;
const float WMF_WEP_HORNETGUN       = 74;
const float WMF_WEP_SHOCKRIFLE      = 75;
const float WMF_WEP_DISPLACER       = 76;
const float WMF_WEP_JETPACK         = 77;
const float WMF_WEP_BGRAPPLE        = 78;
// They Hunger's eight, promoted out of server/sv_goldsrc_pickups.qc's alias
// block — see the note beside WEP_TH1911 in shared/sh_weapons.qc.
const float WMF_WEP_TH1911          = 79;
const float WMF_WEP_THTOMMY         = 80;
const float WMF_WEP_THGREASE        = 81;
const float WMF_WEP_THM14           = 82;
const float WMF_WEP_THM16           = 83;
const float WMF_WEP_THSAWOFF        = 84;
const float WMF_WEP_THSPANNER       = 85;
const float WMF_WEP_THTESLA         = 86;
// Sven Co-op and Opposing Force, promoted out of the pickup-alias block in
// server/sv_goldsrc_pickups.qc.  Values MUST match the WEP_* twins in
// shared/sh_weapons.qc, which nothing asserts - see the note at the top of this
// file for why the two enums exist separately.
const float WMF_WEP_MEDKIT          = 87;
const float WMF_WEP_UZI             = 88;
const float WMF_WEP_UZIAKIMBO       = 89;
const float WMF_WEP_MINIGUN         = 90;
const float WMF_WEP_SVM16           = 91;
const float WMF_WEP_PIPEWRENCH      = 92;
const float WMF_WEP_SNIPERRIFLE     = 93;
const float WMF_WEP_SPORELAUNCHER   = 94;
const float WMF_WEP_EAGLE           = 95;
const float WMF_WEP_ASSHOTGUN       = 96;
const float WMF_WEP_ASSOFLAM        = 97;
// The last three Opposing Force weapons — see the note beside WEP_OPKNIFE in
// shared/sh_weapons.qc.  WMF_WEP_OPKNIFE and WMF_WEP_OPSAW take the GoldSrc
// classnames `weapon_knife` and `weapon_m249` off the Counter-Strike guns that
// were holding them; both old spellings survive as aliases in
// WeaponManifest_IdFromKey below.
const float WMF_WEP_OPKNIFE         = 98;
const float WMF_WEP_OPSAW           = 99;
const float WMF_WEP_PENGUIN         = 100;
// The thirteen remaining Counter-Strike 1.6 guns.  Values MUST match the WEP_*
// twins in shared/sh_weapons.qc, which nothing asserts — see the note at the top
// of this file for why the two enums exist separately.  The comment block beside
// WEP_CSP228 there explains why none of these ships an asset.
const float WMF_WEP_CSP228          = 101;
const float WMF_WEP_CSFIVESEVEN     = 102;
const float WMF_WEP_CSELITE         = 103;
const float WMF_WEP_CSTMP           = 104;
const float WMF_WEP_CSMAC10         = 105;
const float WMF_WEP_CSUMP45         = 106;
const float WMF_WEP_CSP90           = 107;
const float WMF_WEP_CSGALIL         = 108;
const float WMF_WEP_CSFAMAS         = 109;
const float WMF_WEP_CSAUG           = 110;
const float WMF_WEP_CSSG552         = 111;
const float WMF_WEP_CSSG550         = 112;
const float WMF_WEP_CSXM1014        = 113;
// Day of Defeat, the infantry core of both sides.  See the block comment beside
// the matching WEP_DOD* constants in sh_weapons.qc for why DoD is mounted low
// and which two classnames had to be renamed around a collision.
const float WMF_WEP_DODCOLT         = 114;
const float WMF_WEP_DODLUGER        = 115;
const float WMF_WEP_DODWEBLEY       = 116;
const float WMF_WEP_DODGARAND       = 117;
const float WMF_WEP_DODCARBINE      = 118;
const float WMF_WEP_DODK43          = 119;
const float WMF_WEP_DODTOMMY        = 120;
const float WMF_WEP_DODMP40         = 121;
const float WMF_WEP_DODSTEN         = 122;
const float WMF_WEP_DODGREASE       = 123;
const float WMF_WEP_DODMP44         = 124;
const float WMF_WEP_DODBAR          = 125;
// Day of Defeat, second batch — see the block comment beside the matching WEP_*
// ids in shared/sh_weapons.qc.
const float WMF_WEP_DODSCOPED98K    = 126;
const float WMF_WEP_DODSPRING       = 127;
const float WMF_WEP_DODENFIELDS     = 128;
const float WMF_WEP_DOD30CAL        = 129;
const float WMF_WEP_DODMG34         = 130;
const float WMF_WEP_DODMG42         = 131;
const float WMF_WEP_DODBAZOOKA      = 132;
const float WMF_WEP_DODSCHRECK      = 133;
const float WMF_WEP_DODPIAT         = 134;
const float WMF_WEP_DODAMERK        = 135;
const float WMF_WEP_DODFAIRBAIRN    = 136;
const float WMF_WEP_DODPARAKNIFE    = 137;
const float WMF_WEP_DODSPADE        = 138;
const float WMF_WEP_DODMILLS        = 139;
const float WMF_WEP_DODSTICK        = 140;
const float WMF_WEP_DODBREN         = 141;
const float WMF_WEP_DODFG42         = 142;
const float WMF_WEP_DODFG42S        = 143;
const float WMF_WEP_DODFCARB        = 144;
const float WMF_WEP_DODENFIELD      = 145;
const float WMF_WEP_DODMORTAR       = 146;
const float WMF_WEP_DODBINOCS       = 147;
// Bump this with every addition — it bounds the iteration, so a stale value
// truncates the roster silently rather than erroring.
//
// The wire is fine: sv_player.qc:2058 sends the weapon id as a BYTE, so 147
// still leaves 108 spare.
const float WMF_WEP_LAST            = 147;

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
// Half-Life / Sven families.  MUST stay numerically identical to the PANIM_*
// constants in sh_weapons.qc - WeaponManifest_PlayerAnimFamily's return value
// is fed straight into SH_GetAimAnim as a PANIM_, so the two enums are one
// enum written twice.
const float WMF_PANIM_HL_CROWBAR = 10;
const float WMF_PANIM_HL_PYTHON  = 11;
const float WMF_PANIM_HL_GAUSS   = 12;
const float WMF_PANIM_HL_EGON    = 13;
const float WMF_PANIM_HL_RPG     = 14;
const float WMF_PANIM_HL_SAW     = 15;
const float WMF_PANIM_HL_SNIPER  = 16;
const float WMF_PANIM_HL_M16     = 17;
const float WMF_PANIM_HL_MINIGUN = 18;
const float WMF_PANIM_HL_BOW     = 19;
const float WMF_PANIM_HL_HIVE    = 20;
const float WMF_PANIM_HL_SQUEAK  = 21;
const float WMF_PANIM_HL_TRIP    = 22;
const float WMF_PANIM_HL_WRENCH  = 23;
const float WMF_PANIM_HL_UZIS    = 24;
const float WMF_PANIM_HL_GREN    = 25;
const float WMF_PANIM_HL_M203    = 26;

// See sh_weapons.qc: the dual-pistol and C4 sequences ship on every CS-derived
// player model and had no family pointing at them.
const float WMF_PANIM_DUALPISTOLS = 27;
const float WMF_PANIM_C4          = 28;

// Buy-menu categories (the 8 buy-menu screens).  These SUBDIVIDE the 4
// internal slots: SECONDARY -> HANDGUN, MELEE -> MELEE, UTILITY -> EQUIPMENT,
// and PRIMARY is split into SHOTGUN/SMG/SNIPER/RIFLE/LMG.  Tagged explicitly
// per weapon in WeaponManifest_LoadBuy (NOT derived from anim — unreliable:
// AWP/G3SG1 use a rifle anim but are snipers).
const float BUYCAT_NONE      = 0;   // not buyable (fists, C4, intrinsic)
const float BUYCAT_HANDGUN   = 1;
const float BUYCAT_SHOTGUN   = 2;
const float BUYCAT_SMG       = 3;
const float BUYCAT_SNIPER    = 4;
const float BUYCAT_RIFLE     = 5;
const float BUYCAT_LMG       = 6;
const float BUYCAT_MELEE     = 7;
const float BUYCAT_EQUIPMENT = 8;
const float BUYCAT_LAST      = 8;

// Source game.  Which game a weapon came out of, for grouping the F5 weapon
// panel and the buy menu under headings.
//
// This is DELIBERATELY tagged per weapon rather than derived from the constant
// name, because the two disagree constantly: WMF_WEP_357 lives in
// sh_wpn_hl357.qc (Half-Life) while WMF_WEP_GLOCK lives in sh_wpn_csglock.qc
// (Counter-Strike), and nothing in either NAME says so.  The FILE is the
// authority, and the tags below were generated by walking
// SV_DebugSpawnWeaponId's WEP_x -> weapon_y table into the file that defines
// each weapon_y, not by reading the names.
//
// Values are ordered for DISPLAY: the GoldSrc family first, then the imports,
// then this mod's own.  Renumbering them reorders every menu that groups by
// game, which is the intended way to change that order.
const float WMF_GAME_NONE     = 0;
const float WMF_GAME_HL       = 1;   // Half-Life                     (14)
const float WMF_GAME_OPFOR    = 2;   // Opposing Force                (10)
const float WMF_GAME_SVEN     = 3;   // Sven Co-op                     (8)
const float WMF_GAME_HUNGER   = 4;   // They Hunger                    (8)
const float WMF_GAME_CS       = 5;   // Counter-Strike 1.6            (29)
const float WMF_GAME_CROSSFIRE= 6;   // CrossFire                     (31)
const float WMF_GAME_DOD      = 7;   // Day of Defeat                 (26)
const float WMF_GAME_HL2      = 8;   // Half-Life 2                    (1)
const float WMF_GAME_QUAKERS  = 9;   // this mod's own                (10)
const float WMF_GAME_LAST     = 9;

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
float  weapon_manifest_price;       // buy-menu cost (CS-style; pure data)
float  weapon_manifest_buycat;      // BUYCAT_* — which buy screen it lives on
float  weapon_manifest_buy_order;   // contiguous 1..N index within its buycat
float  weapon_manifest_game;        // WMF_GAME_* — which game it came out of

// Single-entry memo for WeaponManifest_Load.  The thin accessors below
// (SpeedFactor / HasScope / HasCrosshair / ...) each re-call Load(wep) then read
// ONE of the 13 globals, and Load is hit ~13x/frame + once per pmove step on an
// UNCHANGED weapon — re-running the ~60-case switch + 13 stores every time.  A hit
// leaves exactly the state a miss would (every Load fully repopulates all 13
// globals via WeaponManifest_Set, and nothing else writes them), so returning the
// cached result for the same wep is bit-identical.  Invalidated in
// WeaponManifest_LoadBuy as defensive insurance (see note there).  A separate
// "valid" flag (not a sentinel wep value) guarantees the first call always runs
// the switch even if some wep id is negative.
float  weapon_manifest_cached_valid;
float  weapon_manifest_cached_wep;
float  weapon_manifest_cached_ret;

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

float(float wep) WeaponManifest_LoadUncached =
{
    switch (wep)
    {
    case WMF_WEP_AK47:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AK47", "AK47", "AK47", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_AK47, "models/p_ak47.mdl", 30, 90, 0, 1, 1); return TRUE;
    case WMF_WEP_HDAK47:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HD AK47", "HD AK47", "HD AK47", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_AK47, "models/weapons/wpn_hdak47/p_ak47.mdl", 30, 90, 0, 2, 2); return TRUE;
    case WMF_WEP_CFAUG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AUG", "AUG", "AUG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfaug/p_aug.mdl", 30, 90, 0, 21, 37); return TRUE;
    case WMF_WEP_CFFAMAS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "FAMAS", "FAMAS", "FAMAS", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cffamas/p_famas.mdl", 25, 90, 0, 22, 38); return TRUE;
    case WMF_WEP_CFMAC10:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MAC10", "MAC10", "MAC10", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/weapons/wpn_cfmac10/p_mac10.mdl", 30, 100, 0, 23, 39); return TRUE;
    case WMF_WEP_M4A1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M4A1", "M4A1", "M4A1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "models/p_m4a1.mdl", 30, 90, 1, 3, 3); return TRUE;
    case WMF_WEP_CSAWP:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AWP", "AWP", "AWP", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/p_awp.mdl", 10, 20, 0, 4, 4); return TRUE;
    case WMF_WEP_G3SG1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "G3SG1", "G3SG1", "G3SG1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/p_g3sg1.mdl", 20, 60, 0, 5, 5); return TRUE;
    case WMF_WEP_CSM3:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M3", "M3", "M3", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/p_m3.mdl", 8, 24, 0, 6, 6); return TRUE;
    case WMF_WEP_CSMP5:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MP5", "MP5", "MP5", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_mp5.mdl", 30, 120, 0, 7, 7); return TRUE;
    case WMF_WEP_PAINTBALL:
        // pmodel intentionally empty — p_excal.mdl has no skeletal
        // bones the player attach pipeline can hook into, so it ends
        // up rendered at world origin.  Empty path makes
        // CSQC_PlayerVisualProxy_Predraw skip the attachment entirely.
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Paintball", "PAINTBALL", "Paintball", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "", 100, 200, 0, 8, 8); return TRUE;
    case WMF_WEP_DOD98K:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "K98", "98K", "K98", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "models/p_k98.mdl", 5, 25, 0, 9, 9); return TRUE;

    // --- Day of Defeat ---
    // Every p_ path here comes from the mounted dod gamedir, not from
    // models/weapons/ — the K98 above is the odd one out, it predates the mount.
    // Speeds follow the tree's convention (heavier gun, slower carry): pistols
    // 0.97, carbine/SMG 0.96, full-power rifles 0.945, the BAR 0.889 with the
    // M249.
    case WMF_WEP_DODCOLT:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "M1911", "M1911", "M1911 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/p_colt.mdl", 7, 21, 0, 73, 113); return TRUE;
    case WMF_WEP_DODLUGER:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Luger P08", "LUGER", "Luger P08", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/p_luger.mdl", 8, 24, 0, 74, 114); return TRUE;
    case WMF_WEP_DODWEBLEY:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Webley", "WEBLEY", "Webley Mk VI", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/p_webley.mdl", 6, 18, 0, 75, 115); return TRUE;
    case WMF_WEP_DODGARAND:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M1 Garand", "GARAND", "M1 Garand", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_garand.mdl", 8, 32, 0, 76, 116); return TRUE;
    case WMF_WEP_DODCARBINE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M1 Carbine", "CARBINE", "M1 Carbine", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_CARBINE, "models/p_m1carb.mdl", 15, 45, 0, 77, 117); return TRUE;
    case WMF_WEP_DODK43:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Gewehr 43", "K43", "Gewehr 43", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_k43.mdl", 10, 30, 0, 78, 118); return TRUE;
    case WMF_WEP_DODTOMMY:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Thompson", "THOMPSON", "Thompson M1A1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_tommy.mdl", 30, 90, 0, 79, 119); return TRUE;
    case WMF_WEP_DODMP40:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MP40", "MP40", "MP40", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_mp40.mdl", 32, 96, 0, 80, 120); return TRUE;
    case WMF_WEP_DODSTEN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Sten", "STEN", "Sten Mk II", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_sten.mdl", 32, 96, 0, 81, 121); return TRUE;
    case WMF_WEP_DODGREASE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M3 Grease Gun", "M3 SMG", "M3 Grease Gun (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_grease.mdl", 30, 90, 0, 82, 122); return TRUE;
    case WMF_WEP_DODMP44:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "StG44", "STG44", "StG44", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_stg44.mdl", 30, 90, 0, 83, 123); return TRUE;
    case WMF_WEP_DODBAR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "BAR", "BAR", "M1918 BAR", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_PARA, "models/p_barbu.mdl", 20, 60, 0, 84, 124); return TRUE;

    // --- Day of Defeat, second batch ---------------------------------------
    // Speed factors follow the existing ladder: bolt rifles ~0.93, the belt-fed
    // machine guns are the SLOWEST things in the game at 0.82-0.85 (they weigh
    // 12-25 kg with a loaded belt), the launchers 0.88, and melee 1.0.
    //
    // WMF_FLAG_SCOPE on the three snipers is what puts them through the scope
    // machine rather than the plain ADS envelope.
    //
    // Player models are the DoD ones, and three of them do NOT match their view
    // model's name: the scoped K98 is p_k98s, the scoped Enfield p_enfields, and
    // the two German MGs use their "bipod up" variants (p_mg34bu / p_mg42bu)
    // because hipfire is the only stance this mod drives — see sh_wpn_dodmgs.qc.
    // The .30 cal is the one MG with a plain p_30cal.
    case WMF_WEP_DODSCOPED98K:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scoped K98", "SK98", "Scoped Kar98k (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR | WMF_FLAG_SCOPE, 0.93, WMF_PANIM_RIFLE, "models/p_k98s.mdl", 5, 25, 0, 85, 125); return TRUE;
    case WMF_WEP_DODSPRING:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Springfield", "SPRING", "M1903 Springfield (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR | WMF_FLAG_SCOPE, 0.93, WMF_PANIM_RIFLE, "models/p_spring.mdl", 5, 25, 0, 86, 126); return TRUE;
    case WMF_WEP_DODENFIELDS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scoped Enfield", "SENF", "Scoped Lee-Enfield (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR | WMF_FLAG_SCOPE, 0.93, WMF_PANIM_RIFLE, "models/p_enfields.mdl", 10, 30, 0, 87, 127); return TRUE;
    case WMF_WEP_DOD30CAL:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, ".30 Cal", "30CAL", "M1919A6 .30 Cal (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.82, WMF_PANIM_PARA, "models/p_30cal.mdl", 100, 200, 0, 88, 128); return TRUE;
    case WMF_WEP_DODMG34:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MG34", "MG34", "MG34 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.84, WMF_PANIM_PARA, "models/p_mg34bu.mdl", 50, 150, 0, 89, 129); return TRUE;
    case WMF_WEP_DODMG42:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MG42", "MG42", "MG42 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.85, WMF_PANIM_PARA, "models/p_mg42bu.mdl", 50, 150, 0, 90, 130); return TRUE;
    case WMF_WEP_DODBAZOOKA:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Bazooka", "ZOOKA", "M1A1 Bazooka (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.88, WMF_PANIM_HL_RPG, "models/p_bazooka.mdl", 1, 4, 0, 91, 131); return TRUE;
    case WMF_WEP_DODSCHRECK:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Panzerschreck", "PSCHRK", "Panzerschreck (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.88, WMF_PANIM_HL_RPG, "models/p_pschreck.mdl", 1, 4, 0, 92, 132); return TRUE;
    case WMF_WEP_DODPIAT:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "PIAT", "PIAT", "PIAT (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.88, WMF_PANIM_HL_RPG, "models/p_piat.mdl", 1, 3, 0, 93, 133); return TRUE;
    case WMF_WEP_DODAMERK:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Trench Knife", "KNIFE", "US Trench Knife (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_amerk.mdl", 0, 0, 0, 94, 134); return TRUE;
    case WMF_WEP_DODFAIRBAIRN:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Commando Knife", "KNIFE", "Fairbairn-Sykes (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_fairbairn.mdl", 0, 0, 0, 95, 135); return TRUE;
    case WMF_WEP_DODPARAKNIFE:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Gravity Knife", "KNIFE", "Gravity Knife (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_paraknife.mdl", 0, 0, 0, 96, 136); return TRUE;
    case WMF_WEP_DODSPADE:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Spade", "SPADE", "Wehrmacht Spade (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_spade.mdl", 0, 0, 0, 97, 137); return TRUE;
    // The two DoD hand grenades.  Mag column is 0 and the AMMO column carries
    // the count, which is how every other SLOT_UTILITY thrown weapon in this
    // table is written (the CS three, the snowball, the snark).
    case WMF_WEP_DODMILLS:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Mills Bomb", "MILLS", "Mills Bomb (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/p_mills.mdl", 0, 2, 0, 98, 138); return TRUE;
    case WMF_WEP_DODSTICK:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Stick Grenade", "STICK", "Stielhandgranate (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/p_stick.mdl", 0, 2, 0, 99, 139); return TRUE;

    // --- Day of Defeat, third batch ----------------------------------------
    // Speeds keep the existing ladder: the Bren is an LMG and carries at 0.889
    // with the BAR and the M249; the FG42 pair are automatic rifles at 0.926;
    // the folding carbine is the lightest long arm in the game at 0.96; the
    // Lee-Enfield is a bolt rifle at 0.945; the mortar is the slowest thing in
    // the mod at 0.82, with the belt-fed guns, because it is 19 kg of tube and
    // baseplate.
    //
    // TWO PLAYER MODELS DO NOT MATCH THEIR VIEW MODEL'S NAME, as with the second
    // batch: the scoped FG42 is p_fg42s (there is no p_scopedfg42), and the
    // folding carbine is p_fcarb.  The BINOCULARS HAVE NO PLAYER MODEL AT ALL —
    // DoD ships neither p_binoculars nor w_binoculars — so the pmodel string is
    // empty, following WMF_WEP_FLAKSHOTGUN.  Do not invent a path: an unprecached
    // setmodel gives modelindex 0 and the engine drops the entity.
    case WMF_WEP_DODBREN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Bren", "BREN", "Bren Mk II (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_PARA, "models/p_bren.mdl", 30, 90, 0, 100, 140); return TRUE;
    case WMF_WEP_DODFG42:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "FG42", "FG42", "FG42 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.926, WMF_PANIM_RIFLE, "models/p_fg42.mdl", 20, 60, 0, 101, 141); return TRUE;
    case WMF_WEP_DODFG42S:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scoped FG42", "FG42-S", "Scoped FG42 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/p_fg42s.mdl", 20, 60, 0, 102, 142); return TRUE;
    case WMF_WEP_DODFCARB:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M1A1 Carbine", "M1A1", "M1A1 Folding Carbine (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_CARBINE, "models/p_fcarb.mdl", 15, 45, 0, 103, 143); return TRUE;
    case WMF_WEP_DODENFIELD:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Lee-Enfield", "ENFIELD", "Lee-Enfield No.4 (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "models/p_enfield.mdl", 10, 30, 0, 104, 144); return TRUE;
    case WMF_WEP_DODMORTAR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Mortar", "MORTAR", "3-inch Mortar (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.82, WMF_PANIM_PARA, "models/p_mortar.mdl", 1, 8, 0, 105, 145); return TRUE;
    case WMF_WEP_DODBINOCS:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Binoculars", "BINOCS", "Binoculars (DoD)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "", 0, 0, 0, 106, 146); return TRUE;
    case WMF_WEP_FLAKSHOTGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Flak Shotgun", "SHOTGUN", "Flak Shotgun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "", 24, 0, 0, 10, 10); return TRUE;
    case WMF_WEP_GAUSS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Gauss", "GAUSS", "Gauss", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_HL_GAUSS, "models/p_gauss.mdl", 0, 120, 0, 11, 11); return TRUE;
    case WMF_WEP_GRENADELAUNCHER:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Grenade Launcher", "GL", "Grenade Launcher", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_HL_M203, "", 6, 0, 0, 12, 12); return TRUE;
    case WMF_WEP_CROSSBOW:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Crossbow", "CROSSBOW", "Crossbow", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.97, WMF_PANIM_HL_BOW, "models/p_crossbow.mdl", 5, 10, 0, 13, 13); return TRUE;
    case WMF_WEP_HLEGON:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Egon", "EGON", "Egon", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_HL_EGON, "models/p_egon.mdl", 0, 100, 0, 14, 14); return TRUE;
    case WMF_WEP_HLRPG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "RPG", "RPG", "RPG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_HL_RPG, "models/p_rpg.mdl", 1, 5, 0, 15, 15); return TRUE;
    case WMF_WEP_HLSHOTGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HL Shotgun", "SHOTGUN", "HL Shotgun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/p_shotgun.mdl", 8, 24, 0, 16, 16); return TRUE;
    case WMF_WEP_HLSMG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "HL SMG", "SMG", "HL SMG", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_CARBINE, "models/p_9mmar.mdl", 50, 250, 2, 17, 17); return TRUE;
    case WMF_WEP_M249:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M249", "M249", "M249", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_PARA, "models/p_m249.mdl", 50, 150, 0, 18, 18); return TRUE;
    case WMF_WEP_REBAR:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Rebar", "REBAR", "Rebar", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 1.0, WMF_PANIM_CARBINE, "", 12, 0, 0, 19, 19); return TRUE;
    case WMF_WEP_SCOUT:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Scout", "SCOUT", "Scout", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.945, WMF_PANIM_CARBINE, "models/p_scout.mdl", 10, 30, 0, 20, 20); return TRUE;

    case WMF_WEP_CSUSP:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "USP", "USP-45", "USP", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/p_usp.mdl", 12, 24, 0, 1, 27); return TRUE;
    case WMF_WEP_DEAGLE:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Desert Eagle", "DEAGLE", "Desert Eagle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/p_deagle.mdl", 7, 35, 0, 2, 28); return TRUE;
    case WMF_WEP_GLOCK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Glock", "GLOCK", "Glock", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/p_glock18.mdl", 20, 40, 0, 3, 29); return TRUE;
    case WMF_WEP_357:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, ".357", ".357", ".357", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_HL_PYTHON, "models/p_357.mdl", 6, 18, 0, 4, 30); return TRUE;
    case WMF_WEP_HLGLOCK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "HL Glock", "HL GLOCK", "HL Glock", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/p_9mmhandgun.mdl", 17, 250, 0, 5, 31); return TRUE;
    case WMF_WEP_PISTOL:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "9mm", "PISTOL", "9mm", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "", 12, 24, 0, 6, 32); return TRUE;
    case WMF_WEP_CFM9:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Beretta M9", "M9", "Beretta M9", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/weapons/wpn_cfm9/p_m9.mdl", 15, 90, 0, 7, 42); return TRUE;
    case WMF_WEP_CFREVOLVER:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Colt Anaconda", "ANACONDA", "Colt Anaconda", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_HL_PYTHON, "models/weapons/wpn_cfrevolver/p_revolver.mdl", 6, 36, 0, 8, 43); return TRUE;
    case WMF_WEP_CFDDEAGLE:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Dual Desert Deagle", "ELITE", "Dual Desert Deagle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_DUALPISTOLS, "models/weapons/wpn_cfddeagle/p_ddeagle.mdl", 30, 90, 0, 9, 44); return TRUE;
    case WMF_WEP_CFBARRETT:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Barrett M82", "BARRETT", "Barrett M82", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.889, WMF_PANIM_RIFLE, "models/weapons/wpn_cfbarrett/p_barrett.mdl", 10, 30, 0, 24, 45); return TRUE;
    case WMF_WEP_CFPSG1:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "PSG1", "PSG1", "PSG1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/weapons/wpn_cfpsg1/p_psg1.mdl", 20, 60, 0, 25, 46); return TRUE;
    case WMF_WEP_CFSPAS12:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SPAS-12", "SPAS-12", "SPAS-12", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/weapons/wpn_cfspas12/p_spas12.mdl", 8, 32, 0, 26, 47); return TRUE;
    case WMF_WEP_CFM700:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M700", "M700", "M700", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.945, WMF_PANIM_RIFLE, "models/weapons/wpn_cfm700/p_m700.mdl", 5, 30, 0, 27, 48); return TRUE;
    case WMF_WEP_CFM3:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Winchester", "WINCHESTER", "Winchester", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/weapons/wpn_cfm3/p_m3.mdl", 7, 28, 0, 28, 49); return TRUE;
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
    case WMF_WEP_GRAVITYGUN:
        // Infinite energy (mag/ammo/aux all 0); no p-model (only v_/w_ provided).
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Gravity Gun", "GRAVGUN", "Gravity Gun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_CARBINE, "", 0, 0, 0, 44, 69); return TRUE;

    case WMF_WEP_WRENCH:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Wrench", "WRENCH", "Wrench", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_WRENCH, "", 0, 0, 0, 1, 33); return TRUE;
    case WMF_WEP_KNIFE:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Knife", "KNIFE", "Knife", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_knife.mdl", 0, 0, 0, 2, 34); return TRUE;
    case WMF_WEP_HLCROWBAR:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Crowbar", "CROWBAR", "Crowbar", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_CROWBAR, "models/p_crowbar.mdl", 0, 0, 0, 3, 35); return TRUE;
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
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Grenade", "GRENADE", "Grenade", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_GREN, "models/p_grenade.mdl", 0, 5, 0, 1, 21); return TRUE;

    // HL equipment.  The three utility items carry their whole load in
    // def_ammo (no magazine), and the hivehand's 8 hornets are a pool that
    // refills itself, so it too has no magazine.
    //
    // THE LAST TWO ARGUMENTS OF EVERY ROW BELOW WERE COLLIDING.  This block and
    // the Crossfire block above each grew into debug_order 42-49 independently,
    // and WeaponManifest_DebugWeapon (:666) scans ids ASCENDING and returns the
    // first match - so the low-id CF weapon won all eight times and satchel,
    // tripmine, snark, hornetgun, shock rifle, displacer, jetpack and barnacle
    // grapple were unreachable through the debug list entirely.  Nothing
    // errored: DebugCount() still returned the right total, so the
    // sv_debug_weapons grid just spawned 8 fewer guns and left 8 holes.
    // Same story for loadout_order 30/31/32/34 against the CF primaries, and
    // the jetpack sat at SECONDARY order 33 when that slot only runs 1..13,
    // which is the "gap leaves a None hole in the dropdown" failure the note at
    // WMF_WEP_KATANA already warns about.
    // These now occupy unique trailing orders.  Keep them unique.
    case WMF_WEP_SATCHEL:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Satchel", "SATCHEL", "Satchel", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_TRIP, "models/p_satchel.mdl", 0, 5, 0, 6, 70); return TRUE;
    case WMF_WEP_TRIPMINE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Tripmine", "TRIPMINE", "Tripmine", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_TRIP, "models/p_tripmine.mdl", 0, 5, 0, 8, 71); return TRUE;
    case WMF_WEP_SNARK:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Snark", "SNARK", "Snark", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_SQUEAK, "models/p_squeak.mdl", 0, 15, 0, 9, 72); return TRUE;
    case WMF_WEP_HORNETGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Hornetgun", "HORNETGUN", "Hornet Gun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_HIVE, "models/p_hgun.mdl", 0, 8, 0, 45, 73); return TRUE;
    case WMF_WEP_SHOCKRIFLE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Shock Rifle", "SHOCK", "Shock Rifle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_HL_EGON, "models/p_shock.mdl", 0, 10, 0, 46, 74); return TRUE;
    case WMF_WEP_DISPLACER:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Displacer", "DISPLACER", "Displacer", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.889, WMF_PANIM_HL_EGON, "models/p_displacer.mdl", 0, 100, 0, 47, 75); return TRUE;
    case WMF_WEP_JETPACK:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Glock 18 Jetpack", "JETPACK", "Glock 18 Jetpack", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/pizza_ya_san/p_glock18jet.mdl", 20, 100, 100, 14, 76); return TRUE;
    case WMF_WEP_BGRAPPLE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Barnacle Grapple", "GRAPPLE", "Barnacle Grapple", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_ONEHAND, "models/p_bgrap.mdl", 0, 0, 0, 48, 77); return TRUE;

    // --- They Hunger's eight -------------------------------------------------
    // loadout_order continues each slot's run (PRIMARY was full to 48,
    // SECONDARY to 14, MELEE to 5) and debug_order continues the single global
    // run, which was full to 77.  Both are CONTIGUOUS indices, not ids: a gap
    // truncates the list silently and a duplicate makes the lower id win, which
    // is the exact failure the block above this one documents.  The
    // sv_satchel_test terminal stage asserts both, so a mistake here fails
    // loudly in-game rather than showing up as a missing menu row.
    // p_models are all present under svencoop/models/hunger/weapons/.
    case WMF_WEP_TH1911:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Colt 1911", "COLT1911", "Colt M1911A1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 1.0, WMF_PANIM_ONEHAND, "models/hunger/weapons/colt/p_1911.mdl", 7, 250, 0, 15, 78); return TRUE;
    case WMF_WEP_THTOMMY:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Tommygun", "TOMMYGUN", "Thompson M1921", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.955, WMF_PANIM_MP5, "models/hunger/weapons/tommygun/p_tommygun.mdl", 50, 250, 0, 49, 79); return TRUE;
    case WMF_WEP_THGREASE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Grease Gun", "GREASEGUN", "M3 Grease Gun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_MP5, "models/hunger/weapons/greasegun/p_greasegun.mdl", 20, 250, 0, 50, 80); return TRUE;
    case WMF_WEP_THM14:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M14", "M14", "M14", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR | WMF_FLAG_SCOPE, 0.94, WMF_PANIM_RIFLE, "models/hunger/weapons/m14/p_m14.mdl", 10, 15, 0, 51, 81); return TRUE;
    case WMF_WEP_THM16:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M16A1", "M16A1", "M16A1", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.95, WMF_PANIM_HL_M16, "models/hunger/weapons/m16a1/p_m16.mdl", 20, 250, 0, 52, 82); return TRUE;   // 250 not 600: the wire is a byte, see MAX_AMMO_THM16
    case WMF_WEP_THSAWOFF:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Sawed-Off", "SAWEDOFF", "Sawed-Off Shotgun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_SHOTGUN, "models/hunger/weapons/dbarrel/p_dbarrel.mdl", 2, 125, 0, 53, 83); return TRUE;
    case WMF_WEP_THSPANNER:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Spanner", "SPANNER", "Spanner", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_CROWBAR, "models/hunger/weapons/spanner/p_spanner.mdl", 0, 0, 0, 6, 84); return TRUE;
    // --- Sven Co-op and Opposing Force ---------------------------------------
    // loadout_order continues each slot's run (PRIMARY was full to 54,
    // SECONDARY to 15, MELEE to 6, UTILITY to 9) and debug_order continues the
    // single global run, which was full to 85.  Both are CONTIGUOUS indices,
    // not ids: a gap leaves a "None" hole in the dropdown and a duplicate makes
    // the higher weapon unreachable.
    case WMF_WEP_MEDKIT:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Medkit", "MEDKIT", "Medkit", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_ONEHAND, "models/p_medkit.mdl", 0, 100, 0, 10, 86); return TRUE;
    // THE UZIS ARE PRIMARIES, and this table's own rule is what says so: the
    // buy-category block at the top of this file states that categories
    // SUBDIVIDE the four slots and that BUYCAT_SMG is one of PRIMARY's
    // subdivisions.  These two were the ONLY weapons in the tree that were
    // BUYCAT_SMG and WMF_SLOT_SECONDARY at the same time, so buying an UZI off
    // the SMG screen threw your sidearm on the floor and left key 1 empty.
    //
    // Sven files it with the handguns - its manual lists the UZI under
    // "Single-hand guns" beside the 9 mm and the .357 - and that is a five-slot
    // HUD where a slot holds several weapons.  This tree has four slots holding
    // ONE weapon each, so "same slot as the pistol" cannot mean what it means
    // there: it means the 32-round SMG evicts the pistol.  desertcircle's
    // grenadier teleport is the case in point - it hands you crowbar, medkit,
    // grenade and UZI, and the UZI is plainly the gun you fight with.
    //
    // loadout_order continues PRIMARY's run, which was full to 59.  Both runs
    // stay contiguous - see the note above: a gap leaves a "None" hole in the
    // dropdown and a duplicate makes the higher weapon unreachable.  SECONDARY
    // closes over the two indices these vacate, just below.
    //
    // WMF_PANIM_ONEHAND stays.  It is the third-person ANIMATION family, not the
    // slot, and the UZI really is fired one-handed - doubly so akimbo.
    case WMF_WEP_UZI:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "UZI", "UZI", "UZI", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.97, WMF_PANIM_ONEHAND, "models/p_uzi.mdl", 32, 250, 0, 60, 87); return TRUE;
    case WMF_WEP_UZIAKIMBO:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Akimbo UZIs", "AKIMBO", "Akimbo UZIs", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.95, WMF_PANIM_HL_UZIS, "models/p_2uzis.mdl", 64, 250, 0, 61, 88); return TRUE;
    // p_minigunidle.mdl, not p_minigunspin.mdl.  The model ships TWO player
    // models and the manifest carries one; a third-person player holding a
    // still minigun is right whenever they are not firing, and swapping per
    // state is a shape this table does not have.
    case WMF_WEP_MINIGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Minigun", "MINIGUN", "Minigun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.80, WMF_PANIM_HL_MINIGUN, "models/p_minigunidle.mdl", 0, 200, 0, 55, 89); return TRUE;
    // def_aux was 0 and the weapon has an M203: sh_wpn_svm16.qc carries
    // MAX_AMMO_SVM16_GRENADES = 2 and a full secondary-fire path.  WMF_WEP_HLSMG,
    // the same launcher on a different rifle, has always declared 2 here.  It
    // mattered the moment "m16" started resolving to this id, because
    // Ammo_TopUpAux refuses outright when WeaponManifest_DefaultAux() <= 0.
    case WMF_WEP_SVM16:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M16", "M16", "M16", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.94, WMF_PANIM_HL_M16, "models/p_m16.mdl", 30, 250, 2, 56, 90); return TRUE;
    case WMF_WEP_PIPEWRENCH:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Pipe Wrench", "WRENCH", "Pipe Wrench", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_WRENCH, "models/p_pipe_wrench.mdl", 0, 0, 0, 7, 91); return TRUE;
    case WMF_WEP_SNIPERRIFLE:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Sniper Rifle", "M40A1", "Sniper Rifle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR | WMF_FLAG_SCOPE, 0.90, WMF_PANIM_HL_SNIPER, "models/p_m40a1.mdl", 5, 20, 0, 57, 92); return TRUE;
    case WMF_WEP_SPORELAUNCHER:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Spore Launcher", "SPORE", "Spore Launcher", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 0.92, WMF_PANIM_HL_RPG, "models/p_spore_launcher.mdl", 5, 20, 0, 58, 93); return TRUE;
    case WMF_WEP_EAGLE:
    // loadout_order 18 -> 16: the two UZIs left for PRIMARY and this was the only
    // entry above them in SECONDARY's run, so it closes the gap and the slot
    // stays contiguous at 1..16.
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Desert Eagle", "EAGLE", "Desert Eagle", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.98, WMF_PANIM_ONEHAND, "models/p_desert_eagle.mdl", 7, 36, 0, 16, 94); return TRUE;
    case WMF_WEP_ASSHOTGUN:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Shorty", "SHORTY", "Shorty", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.95, WMF_PANIM_SHOTGUN, "models/pizza_ya_san/p_shotgun_shorty.mdl", 4, 125, 0, 59, 95); return TRUE;
    case WMF_WEP_ASSOFLAM:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "SOFLAM", "SOFLAM", "SOFLAM", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_ONEHAND, "models/pizza_ya_san/p_soflam.mdl", 0, 5, 0, 11, 96); return TRUE;
    // The last three Opposing Force weapons.  loadout_order continues each slot's
    // own run (MELEE was 1..7, PRIMARY 1..61, UTILITY 1..11) and debug_order
    // continues the single global run, which was 1..96.  Both must stay
    // contiguous: sv_main.qc's terminal self-test walks
    // WeaponManifest_DebugWeapon(0..DebugCount-1) and asserts none resolve to
    // WEP_NONE, so a gap is a hole in the F5 panel and the sv_debug_weapons grid.
    case WMF_WEP_OPKNIFE:
        WeaponManifest_Set(WMF_SLOT_MELEE, "Combat Knife", "KNIFE", "Combat Knife", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_KNIFE, "models/p_knife.mdl", 0, 0, 0, 8, 97); return TRUE;
    case WMF_WEP_OPSAW:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "M249 SAW", "SAW", "M249 SAW", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.87, WMF_PANIM_HL_SAW, "models/p_saw.mdl", 200, 200, 0, 62, 98); return TRUE;

    // --- The thirteen Counter-Strike 1.6 guns. ---
    //
    // Orders continue the existing runs exactly as the note above demands:
    // PRIMARY loadout was 1..62 and goes on to 72, SECONDARY was 1..15 and goes
    // on to 18, and the single global debug run was 1..100 and goes on to 113.
    //
    // pmodel comes off the mounted cstrike gamedir like the view and world
    // models — see the header of shared/weapons/sh_wpn_csaug.qc.
    //
    // MENU NAMES DISAMBIGUATE ONLY WHERE THEY MUST.  Seven of these share a name
    // with a CrossFire weapon the mod already carries (AUG, FAMAS, MAC10, UMP45,
    // Galil, SG552, P228), and both the F5 panel and the buy menu label their
    // buttons with WeaponManifest_MenuName.  The F5 panel groups by
    // WeaponManifest_Game so it would read them apart on its own, but the buy
    // menu groups by BUYCAT only and would show the same word twice — so those
    // seven carry a "(CS)" suffix and the other six, which collide with nothing,
    // stay plain.  display/hud stay the bare gun name in every case: only one of
    // them is ever in your hands, so the HUD has nothing to disambiguate.
    case WMF_WEP_CSP228:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "P228", "P228", "P228 (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/p_p228.mdl", 13, 52, 0, 16, 100); return TRUE;
    case WMF_WEP_CSFIVESEVEN:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Five-Seven", "57", "Five-Seven", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_ONEHAND, "models/p_fiveseven.mdl", 20, 100, 0, 17, 101); return TRUE;
    case WMF_WEP_CSELITE:
        WeaponManifest_Set(WMF_SLOT_SECONDARY, "Dual Berettas", "ELITE", "Dual Berettas", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.985, WMF_PANIM_DUALPISTOLS, "models/p_elite.mdl", 30, 120, 0, 18, 102); return TRUE;
    case WMF_WEP_CSTMP:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "TMP", "TMP", "TMP", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_tmp.mdl", 30, 120, 0, 63, 103); return TRUE;
    case WMF_WEP_CSMAC10:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "MAC-10", "MAC10", "MAC-10 (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_mac10.mdl", 30, 100, 0, 64, 104); return TRUE;
    case WMF_WEP_CSUMP45:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "UMP45", "UMP45", "UMP45 (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_ump45.mdl", 25, 100, 0, 65, 105); return TRUE;
    case WMF_WEP_CSP90:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "P90", "P90", "P90", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.96, WMF_PANIM_MP5, "models/p_p90.mdl", 50, 100, 0, 66, 106); return TRUE;
    case WMF_WEP_CSGALIL:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Galil", "GALIL", "Galil (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_galil.mdl", 35, 90, 0, 67, 107); return TRUE;
    case WMF_WEP_CSFAMAS:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "FAMAS", "FAMAS", "FAMAS (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_famas.mdl", 25, 90, 0, 68, 108); return TRUE;
    case WMF_WEP_CSAUG:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "AUG", "AUG", "AUG (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_aug.mdl", 30, 90, 0, 69, 109); return TRUE;
    case WMF_WEP_CSSG552:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SG552", "SG552", "SG552 (CS)", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_RIFLE, "models/p_sg552.mdl", 30, 90, 0, 70, 110); return TRUE;
    case WMF_WEP_CSSG550:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "SG550", "SG550", "SG550", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_SCOPE, 0.926, WMF_PANIM_RIFLE, "models/p_sg550.mdl", 30, 90, 0, 71, 111); return TRUE;
    case WMF_WEP_CSXM1014:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "XM1014", "XM1014", "XM1014", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.945, WMF_PANIM_SHOTGUN, "models/p_xm1014.mdl", 7, 32, 0, 72, 112); return TRUE;

    case WMF_WEP_PENGUIN:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Penguin", "PENGUIN", "Penguin", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_HL_SQUEAK, "models/p_penguin.mdl", 0, 15, 0, 12, 99); return TRUE;
    case WMF_WEP_THTESLA:
        WeaponManifest_Set(WMF_SLOT_PRIMARY, "Tesla Gun", "TESLA", "Tesla Gun", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG | WMF_FLAG_CROSSHAIR, 0.93, WMF_PANIM_HL_GAUSS, "models/hunger/weapons/tesla/p_tesla.mdl", 0, 100, 0, 54, 85); return TRUE;
    case WMF_WEP_SNOWBALL:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Snowball", "SNOWBALL", "Snowball", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_snowball/p_snowball.mdl", 0, 50, 0, 2, 22); return TRUE;
    case WMF_WEP_SLINGSHOT:
        // Slingshot is the snowball-upgrade variant; selecting it as a
        // loadout item gives the player snowball ammo plus the
        // slingshot bonus (handled in W_GiveStartingAmmo).
        // p_slingshot.mdl was sitting unused next to p_snowball.mdl in
        // models/weapons/wpn_snowball/ — the snowball row had been filled and
        // this one simply missed, so the slingshot rendered nothing in third
        // person while its sibling rendered fine.
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Slingshot", "SLINGSHOT", "Slingshot", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/weapons/wpn_snowball/p_slingshot.mdl", 0, 0, 0, 7, 23); return TRUE;
    case WMF_WEP_CSHEGRENADE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "HE Grenade", "HE", "HE Grenade", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/p_hegrenade.mdl", 0, 1, 0, 3, 24); return TRUE;
    case WMF_WEP_CSFLASHBANG:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Flashbang", "FLASH", "Flashbang", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/p_flashbang.mdl", 0, 1, 0, 4, 25); return TRUE;
    case WMF_WEP_CSSMOKEGRENADE:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "Smoke Grenade", "SMOKE", "Smoke", WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, 1.0, WMF_PANIM_GRENADE, "models/p_smokegrenade.mdl", 0, 1, 0, 5, 26); return TRUE;
    case WMF_WEP_CFC4:
        WeaponManifest_Set(WMF_SLOT_UTILITY, "C4", "C4", "C4", WMF_FLAG_DEBUG, 1.0, WMF_PANIM_C4, "models/weapons/wpn_cfc4/p_c4.mdl", 0, 1, 0, 0, 40); return TRUE;
    }

    WeaponManifest_Set(WMF_SLOT_NONE, "?", "", "", 0, 1.0, WMF_PANIM_ONEHAND, "", 0, 0, 0, 0, 0);
    return FALSE;
};

// Memoized public entry — see the weapon_manifest_cached_wep note above.  On a hit
// the 13 globals already hold this wep's data (only WeaponManifest_Set, called
// solely from the uncached body, ever writes them), so we return without re-running
// the switch.  Every accessor (and the per-step / per-frame HUD callers) goes
// through here.
float(float wep) WeaponManifest_Load =
{
    if (weapon_manifest_cached_valid && wep == weapon_manifest_cached_wep)
        return weapon_manifest_cached_ret;
    weapon_manifest_cached_valid = TRUE;
    weapon_manifest_cached_wep = wep;
    weapon_manifest_cached_ret = WeaponManifest_LoadUncached(wep);
    return weapon_manifest_cached_ret;
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
    // THE CLASSNAME HANDOVER.  Bare "knife" is the GoldSrc name and now resolves
    // to Opposing Force's combat knife (further down, beside the other OpFor
    // rows); Counter-Strike's keeps every CS-flavoured spelling.  A map or a
    // console command saying "knife" in a GoldSrc corpus means the OpFor weapon.
    if (key == "csknife" || key == "wepknife" || key == "wepcsknife") return WMF_WEP_KNIFE;
    if (key == "ak47" || key == "wepak47") return WMF_WEP_AK47;
    if (key == "hdak47" || key == "wephdak47") return WMF_WEP_HDAK47;
    if (key == "m4a1" || key == "wepm4a1") return WMF_WEP_M4A1;
    if (key == "flakshotgun" || key == "wepflakshotgun") return WMF_WEP_FLAKSHOTGUN;
    if (key == "9mm" || key == "pistol" || key == "weppistol") return WMF_WEP_PISTOL;
    if (key == "gauss" || key == "wepgauss") return WMF_WEP_GAUSS;
    if (key == "crossbow" || key == "wepcrossbow") return WMF_WEP_CROSSBOW;
    if (key == "357" || key == "wep357") return WMF_WEP_357;
    // "98k" is the spelling on the HUD and the one people actually type; it was
    // missing, so `wep_give 98k` reported "no such weapon" on the weapon whose
    // display name is 98K.
    if (key == "k98" || key == "98k" || key == "kar98k" || key == "dod98k"
        || key == "wepdod98k" || key == "weaponkar") return WMF_WEP_DOD98K;
    // Day of Defeat.  Each takes its short name, a "dod"-prefixed alias, and the
    // GoldSrc classname key from dod.fgd, so `give weapon_garand` and a map that
    // places one both land on the same weapon.  NameKey has already stripped
    // spaces, underscores, hyphens and dots, which is why "weapon_m1carbine"
    // arrives here as "weaponm1carbine".
    if (key == "m1911" || key == "dodcolt" || key == "wepdodcolt" || key == "weaponcolt") return WMF_WEP_DODCOLT;
    if (key == "luger" || key == "dodluger" || key == "wepdodluger" || key == "weaponluger") return WMF_WEP_DODLUGER;
    if (key == "webley" || key == "dodwebley" || key == "wepdodwebley" || key == "weaponwebley") return WMF_WEP_DODWEBLEY;
    if (key == "garand" || key == "dodgarand" || key == "wepdodgarand" || key == "weapongarand") return WMF_WEP_DODGARAND;
    if (key == "m1carbine" || key == "carbine" || key == "dodcarbine" || key == "wepdodcarbine" || key == "weaponm1carbine") return WMF_WEP_DODCARBINE;
    if (key == "k43" || key == "gewehr" || key == "gewehr43" || key == "dodk43" || key == "wepdodk43" || key == "weapongewehr") return WMF_WEP_DODK43;
    if (key == "thompson" || key == "tommy" || key == "dodtommy" || key == "wepdodtommy" || key == "weaponthompson") return WMF_WEP_DODTOMMY;
    if (key == "mp40" || key == "dodmp40" || key == "wepdodmp40" || key == "weaponmp40") return WMF_WEP_DODMP40;
    if (key == "sten" || key == "dodsten" || key == "wepdodsten" || key == "weaponsten") return WMF_WEP_DODSTEN;
    // NOT bare "greasegun": They Hunger's M3 already owns that key and its own
    // weapon_greasegun classname, which is why this one spawns as
    // weapon_dodgreasegun.  Same handover shape as "m249" below.
    if (key == "dodgreasegun" || key == "dodgrease" || key == "wepdodgrease" || key == "weapondodgreasegun") return WMF_WEP_DODGREASE;
    if (key == "stg44" || key == "mp44" || key == "dodmp44" || key == "wepdodmp44" || key == "weaponmp44") return WMF_WEP_DODMP44;
    if (key == "bar" || key == "dodbar" || key == "wepdodbar" || key == "weaponbar") return WMF_WEP_DODBAR;
    // Day of Defeat, second batch.  "k98s" and "sk98" both reach the scoped K98
    // without colliding with the unscoped "k98"; "enfields" is DoD's own
    // abbreviation for the scoped Enfield and matches p_enfields.mdl.
    if (key == "scoped98k" || key == "sk98" || key == "k98s" || key == "dodscoped98k" || key == "weaponscoped98k") return WMF_WEP_DODSCOPED98K;
    if (key == "spring" || key == "springfield" || key == "dodspring" || key == "weaponspring") return WMF_WEP_DODSPRING;
    if (key == "enfields" || key == "senf" || key == "scopedenfield" || key == "dodenfields" || key == "weaponenfieldscoped") return WMF_WEP_DODENFIELDS;
    if (key == "30cal" || key == "dod30cal" || key == "weapon30cal") return WMF_WEP_DOD30CAL;
    if (key == "mg34" || key == "dodmg34" || key == "weaponmg34") return WMF_WEP_DODMG34;
    if (key == "mg42" || key == "dodmg42" || key == "weaponmg42") return WMF_WEP_DODMG42;
    if (key == "bazooka" || key == "zooka" || key == "dodbazooka" || key == "weaponbazooka") return WMF_WEP_DODBAZOOKA;
    if (key == "pschreck" || key == "panzerschreck" || key == "schreck" || key == "dodschreck" || key == "weaponpschreck") return WMF_WEP_DODSCHRECK;
    if (key == "piat" || key == "dodpiat" || key == "weaponpiat") return WMF_WEP_DODPIAT;
    if (key == "amerk" || key == "trenchknife" || key == "dodamerk" || key == "weaponamerknife") return WMF_WEP_DODAMERK;
    if (key == "fairbairn" || key == "commandoknife" || key == "dodfairbairn" || key == "weaponfairbairn") return WMF_WEP_DODFAIRBAIRN;
    if (key == "paraknife" || key == "gravityknife" || key == "dodparaknife" || key == "weaponparaknife") return WMF_WEP_DODPARAKNIFE;
    if (key == "spade" || key == "dodspade" || key == "weaponspade") return WMF_WEP_DODSPADE;
    if (key == "mills" || key == "millsbomb" || key == "dodmills" || key == "weaponmills") return WMF_WEP_DODMILLS;
    if (key == "stick" || key == "stickgrenade" || key == "dodstick" || key == "weaponstick") return WMF_WEP_DODSTICK;
    // Day of Defeat, third batch.  NOTE the folding carbine deliberately does NOT
    // claim the bare key "carbine": the M1 carbine already owns it and is tested
    // earlier in this ladder, so the alias would be dead code — the same trap the
    // Grease Gun note above records for "greasegun".
    if (key == "bren" || key == "dodbren" || key == "wepdodbren" || key == "weaponbren") return WMF_WEP_DODBREN;
    if (key == "fg42" || key == "dodfg42" || key == "wepdodfg42" || key == "weaponfg42") return WMF_WEP_DODFG42;
    if (key == "scopedfg42" || key == "fg42s" || key == "dodfg42s" || key == "weaponscopedfg42") return WMF_WEP_DODFG42S;
    if (key == "fcarb" || key == "fcarbine" || key == "foldingcarbine" || key == "paracarbine"
        || key == "dodfcarb" || key == "weaponfcarb") return WMF_WEP_DODFCARB;
    if (key == "enfield" || key == "leeenfield" || key == "dodenfield" || key == "weaponenfield") return WMF_WEP_DODENFIELD;
    if (key == "mortar" || key == "dodmortar" || key == "wepdodmortar" || key == "weaponmortar") return WMF_WEP_DODMORTAR;
    if (key == "binoculars" || key == "binocs" || key == "dodbinocs" || key == "weaponbinoculars") return WMF_WEP_DODBINOCS;
    if (key == "scout" || key == "wepscout") return WMF_WEP_SCOUT;
    if (key == "gl" || key == "grenadelauncher" || key == "wepgrenadelauncher") return WMF_WEP_GRENADELAUNCHER;
    // Handover, as for the knife above: bare "m249" is the GoldSrc name and now
    // resolves to Opposing Force's belt-fed SAW.
    if (key == "csm249" || key == "wepm249" || key == "wepcsm249") return WMF_WEP_M249;
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
    if (key == "satchel" || key == "hlsatchel" || key == "wepsatchel") return WMF_WEP_SATCHEL;
    if (key == "tripmine" || key == "hltripmine" || key == "weptripmine") return WMF_WEP_TRIPMINE;
    if (key == "snark" || key == "squeak" || key == "wepsnark") return WMF_WEP_SNARK;
    if (key == "hornetgun" || key == "hivehand" || key == "wephornetgun") return WMF_WEP_HORNETGUN;
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
    if (key == "gravitygun" || key == "gravgun" || key == "wpngravitygun") return WMF_WEP_GRAVITYGUN;

    // ---- GoldSrc / Opposing Force / They Hunger classnames -----------------
    // These are the names MAPS use, and until now they resolved for map
    // placement (sv_goldsrc_pickups.qc has a spawn function for each) but NOT
    // for game_player_equip, which strips "weapon_" and looks the remainder up
    // here (sv_goldsrc_entities.qc:361-367).  So a map that placed a shotgun got
    // one and a map that equipped you with one silently got nothing.  That gap
    // predates this round for the eight original aliases; it is closed for all
    // of them at once.
    //
    // NOTE what is NOT here: "mp5" already resolves, to the Counter-Strike MP5
    // rather than HL's SMG.  Left alone - CS maps outnumber HL ones for that
    // name and both are 9mm submachine guns, so the wrong one is still a
    // reasonable one.
    // "m16" is Sven's own rifle and "m16a1" is They Hunger's - two classnames,
    // two world models with the same basename.  BOTH now resolve to their own
    // weapon further down; neither is a stand-in any more.
    //
    // Five keys left this line and the two below it in the same round -
    // "tommygun", "m16a1", "greasegun", "colt1911" and "sawedoff" - because
    // each now names a real weapon rather than a Half-Life stand-in.  They
    // resolve at the bottom of this function; ORDER MATTERS, these tests run
    // first and would keep winning if the keys stayed here.
    // SEVEN MORE KEYS LEFT THIS BLOCK, for exactly the reason the note above
    // gives: each names a weapon this tree now implements for real, and while the
    // key stayed here the stand-in kept winning, because these tests run first.
    //
    //   sniperrifle -> was WMF_WEP_CSAWP           now WMF_WEP_SNIPERRIFLE (p_m40a1)
    //   uzi         -> was WMF_WEP_CFMAC10         now WMF_WEP_UZI         (p_uzi)
    //   uziakimbo   -> was WMF_WEP_CFELITE         now WMF_WEP_UZIAKIMBO   (p_2uzis)
    //   minigun     -> was WMF_WEP_M249            now WMF_WEP_MINIGUN     (p_minigunidle)
    //   pipewrench  -> was WMF_WEP_WRENCH          now WMF_WEP_PIPEWRENCH  (p_pipe_wrench)
    //   sporelauncher -> was WMF_WEP_GRENADELAUNCHER now WMF_WEP_SPORELAUNCHER
    //   eagle       -> was WMF_WEP_DEAGLE          now WMF_WEP_EAGLE       (p_desert_eagle)
    //
    // This was not a pending decision, it was an unfinished one: the AMMO side had
    // already been promoted (sv_goldsrc_ammo.qc:319-331 calls them "the nine
    // promoted out of the alias block" and routes CAL_762 to WEP_SNIPERRIFLE,
    // CAL_9MM to WEP_UZI, and so on), so the two halves disagreed and the alias
    // half was the one maps actually hit.  desertcircle is where that shows: its
    // opening teleports hand out weapon_sniperrifle + ammo_762 and weapon_uzi +
    // ammo_9mmbox, and the player got a CS AWP and a MAC-10 instead.
    //
    // "9mmar" stays: that IS Half-Life's 9mm AR and WMF_WEP_HLSMG is the weapon.
    //
    // "m16" HAS NOW LEFT, which is the eighth key to do so and the one the note
    // above deferred: "promoting it moves every weapon_m16 in the corpus onto a
    // different gun and belongs in its own change".  This is that change.
    // WMF_WEP_SVM16 is a real, complete weapon - shared/weapons/sh_wpn_svm16.qc,
    // v_m16a2.mdl / w_m16.mdl / p_m16.mdl, a 30-round mag on the 5.56 pool, a
    // genuine 3-round burst on primary and the M203 on secondary.
    //
    // The classname was ALREADY the real weapon: weapon_m16() at
    // sh_wpn_svm16.qc:447 sets WEP_SVM16, so a pickup on the floor has always
    // handed over the M16.  Only this string-key path lagged - and that is the
    // path game_player_equip, the map .cfg equip lists, wep_give, squadmaker and
    // the buy menu all take.  Same classname, two different guns depending on how
    // you acquired it, exactly as with weapon_sniperrifle last round.
    //
    // Measured reach: 34 pickup placements over 19 maps (already correct), plus
    // 42 map .cfg equip lists that were silently handing out an MP5 - the whole
    // Half-Life campaign (hl_c05_a1 .. hl_c17), crystal, last1-4, sandstone,
    // sc_tetris2-6, polar_rescue.  Those maps now hand out an M16, which is what
    // Sven Co-op itself does with that line.
    if (key == "9mmar")                             return WMF_WEP_HLSMG;
    if (key == "9mmhandgun")                        return WMF_WEP_HLGLOCK;
    if (key == "shotgun")                           return WMF_WEP_HLSHOTGUN;
    if (key == "handgrenade")                       return WMF_WEP_HLGRENADE;
    if (key == "python" || key == "thtaurus")       return WMF_WEP_357;
    // "penguin" used to land on the SNARK — the model-swap stand-in this weapon
    // has now replaced.  It resolves to the real thing; see WMF_WEP_PENGUIN.

    // The four implemented outright.
    if (key == "shockrifle" || key == "shock" || key == "wepshockrifle") return WMF_WEP_SHOCKRIFLE;
    if (key == "displacer" || key == "wepdisplacer")                     return WMF_WEP_DISPLACER;
    if (key == "jetpack" || key == "asjetpack" || key == "wepjetpack")   return WMF_WEP_JETPACK;
    if (key == "grapple" || key == "bgrap" || key == "barnacle" || key == "wepbgrapple")
        return WMF_WEP_BGRAPPLE;

    // They Hunger's eight.  Three of these keys USED to resolve to a stand-in
    // and have been moved off it: "m14" pointed at WMF_WEP_CSAWP, "spanner" at
    // WMF_WEP_WRENCH and "teslagun" at WMF_WEP_HLEGON, which is what the pickup
    // aliases did before the real weapons existed.  "sniperrifle" and
    // "pipewrench" stay where they were — those are OPPOSING FORCE classnames
    // that happen to share the alias block, not They Hunger ones.
    if (key == "colt1911" || key == "1911" || key == "colt" || key == "wepth1911")
        return WMF_WEP_TH1911;
    if (key == "tommygun" || key == "thompson" || key == "tommy" || key == "wepthtommy")
        return WMF_WEP_THTOMMY;
    if (key == "greasegun" || key == "grease" || key == "m3" || key == "wepthgrease")
        return WMF_WEP_THGREASE;
    if (key == "m14" || key == "wepthm14")                        return WMF_WEP_THM14;
    // Still deliberately NOT "m16" — that is Sven Co-op's own rifle, and it now
    // resolves to WMF_WEP_SVM16 in the Sven block below.  Two classnames, two
    // world models with the same basename, and each finally reaches its own gun.
    if (key == "m16a1" || key == "wepthm16")                      return WMF_WEP_THM16;
    if (key == "sawedoff" || key == "dbarrel" || key == "sawnoff" || key == "wepthsawoff")
        return WMF_WEP_THSAWOFF;
    if (key == "spanner" || key == "wepthspanner")                return WMF_WEP_THSPANNER;
    if (key == "teslagun" || key == "tesla" || key == "wepthtesla")
        return WMF_WEP_THTESLA;
    // Sven Co-op and Opposing Force.  Both the classname's own spelling and the
    // bare noun, because game_player_equip strips "weapon_" and looks the
    // remainder up here (sv_goldsrc_entities.qc:361).
    if (key == "medkit" || key == "wepmedkit")                             return WMF_WEP_MEDKIT;
    if (key == "uzi" || key == "wepuzi")                                   return WMF_WEP_UZI;
    if (key == "uziakimbo" || key == "akimbo" || key == "wepuziakimbo")    return WMF_WEP_UZIAKIMBO;
    if (key == "minigun" || key == "wepminigun")                           return WMF_WEP_MINIGUN;
    if (key == "m16" || key == "svm16" || key == "wepsvm16")               return WMF_WEP_SVM16;
    if (key == "pipewrench" || key == "weppipewrench")                     return WMF_WEP_PIPEWRENCH;
    if (key == "sniperrifle" || key == "m40a1" || key == "wepsniperrifle") return WMF_WEP_SNIPERRIFLE;
    if (key == "sporelauncher" || key == "wepsporelauncher")               return WMF_WEP_SPORELAUNCHER;
    if (key == "eagle" || key == "deserteagle" || key == "wepeagle")       return WMF_WEP_EAGLE;
    // The last three.  These take the BARE GoldSrc keys "knife", "m249" and
    // "penguin" — the Counter-Strike knife and M249 moved to "csknife"/"csm249"
    // above, and "penguin" no longer lands on the snark.
    if (key == "knife" || key == "combatknife" || key == "opknife" || key == "wepopknife")
        return WMF_WEP_OPKNIFE;
    if (key == "m249" || key == "saw" || key == "opsaw" || key == "wepopsaw")
        return WMF_WEP_OPSAW;
    if (key == "penguin" || key == "weppenguin")                          return WMF_WEP_PENGUIN;
    if (key == "asshotgun" || key == "shorty" || key == "wepasshotgun")    return WMF_WEP_ASSHOTGUN;
    if (key == "assoflam" || key == "soflam" || key == "wepassoflam")      return WMF_WEP_ASSOFLAM;

    // --- The thirteen Counter-Strike 1.6 guns. ---
    //
    // THESE DELIBERATELY DO NOT TAKE THE BARE GUN NAME.  "aug", "famas", "galil",
    // "p228", "elite", "mac10", "ump45", "sg552", "xm1014", "fiveseven" and
    // "sg550" are all already bound above to CrossFire weapons that have owned
    // them for several patches; stealing one would silently redirect every
    // existing wep_give, map-cfg equip and buy alias that names it.  So each of
    // these answers to "cs<name>" and to its own GoldSrc classname key only.
    //
    // Note "sg550" in particular: it currently resolves to WMF_WEP_CFSVD, which
    // is the Dragunov wearing an SG-550 alias.  That row stays as it is.
    if (key == "csp228" || key == "wepcsp228" || key == "weaponp228")           return WMF_WEP_CSP228;
    if (key == "csfiveseven" || key == "cs57" || key == "wepcsfiveseven"
        || key == "weaponfiveseven")                                           return WMF_WEP_CSFIVESEVEN;
    if (key == "cselite" || key == "dualberettas" || key == "wepcselite"
        || key == "weaponelite")                                               return WMF_WEP_CSELITE;
    if (key == "cstmp" || key == "tmp" || key == "wepcstmp" || key == "weapontmp")
        return WMF_WEP_CSTMP;
    if (key == "csmac10" || key == "wepcsmac10" || key == "weaponmac10")        return WMF_WEP_CSMAC10;
    if (key == "csump45" || key == "csump" || key == "wepcsump45"
        || key == "weaponump45")                                               return WMF_WEP_CSUMP45;
    if (key == "csp90" || key == "p90" || key == "wepcsp90" || key == "weaponp90")
        return WMF_WEP_CSP90;
    if (key == "csgalil" || key == "wepcsgalil" || key == "weapongalil")        return WMF_WEP_CSGALIL;
    if (key == "csfamas" || key == "wepcsfamas" || key == "weaponfamas")        return WMF_WEP_CSFAMAS;
    if (key == "csaug" || key == "wepcsaug" || key == "weaponaug")              return WMF_WEP_CSAUG;
    if (key == "cssg552" || key == "wepcssg552" || key == "weaponsg552")        return WMF_WEP_CSSG552;
    if (key == "cssg550" || key == "commando" || key == "wepcssg550"
        || key == "weaponsg550")                                               return WMF_WEP_CSSG550;
    // NOT "xm1014" and NOT "m4super90": both are already claimed further up this
    // chain — "xm1014" by WMF_WEP_CFSPAS12 and "m4super90" by WMF_WEP_CFM4 — and
    // a first match wins, so listing them here would be dead code that reads as
    // if it worked.
    if (key == "csxm1014" || key == "wepcsxm1014" || key == "weaponxm1014")     return WMF_WEP_CSXM1014;

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

// ============================================================
//  Buy-menu data — price + category.  Kept in a PARALLEL switch so the
//  existing ~69 WeaponManifest_Set call sites stay untouched.  buy_order
//  must be CONTIGUOUS 1..N within each buycat (same no-gap rule as
//  loadout_order — BuyCat_Weapon walks 1..N for an exact match; a gap
//  leaves a blank buy-menu row).  Prices are CS 1.6-style defaults — pure
//  data, tweak freely.  Fists / C4 / NONE fall through (not buyable).
// ============================================================
float(float wep) WeaponManifest_LoadBuy =
{
    // Defensive: LoadBuy writes only the 3 buy globals (not the 13 core), so it
    // can't corrupt the Load memo today — but invalidate it anyway so any future
    // code that writes a core global from a buy path can't be masked by a stale
    // memo hit.  LoadBuy is buy-menu only (never per-frame in gameplay), so this
    // costs the hot path nothing.
    weapon_manifest_cached_valid = FALSE;
    weapon_manifest_price = 0;
    weapon_manifest_buycat = BUYCAT_NONE;
    weapon_manifest_buy_order = 0;
    switch (wep)
    {
    // --- Handguns (secondary slot) ---
    case WMF_WEP_CSUSP:      weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 1;  return TRUE;
    case WMF_WEP_DEAGLE:     weapon_manifest_price = 700;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 2;  return TRUE;
    case WMF_WEP_GLOCK:      weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 3;  return TRUE;
    case WMF_WEP_357:        weapon_manifest_price = 600;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 4;  return TRUE;
    case WMF_WEP_HLGLOCK:    weapon_manifest_price = 300;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 5;  return TRUE;
    case WMF_WEP_PISTOL:     weapon_manifest_price = 200;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 6;  return TRUE;
    case WMF_WEP_CFM9:       weapon_manifest_price = 400;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 7;  return TRUE;
    case WMF_WEP_CFREVOLVER: weapon_manifest_price = 600;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_CFDDEAGLE:  weapon_manifest_price = 800;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_CFMAUSER:   weapon_manifest_price = 500;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_CFMK23:     weapon_manifest_price = 500;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_CFGLOCK:    weapon_manifest_price = 400;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 12; return TRUE;
    case WMF_WEP_CFP228:     weapon_manifest_price = 600;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 13; return TRUE;

    // --- Shotguns (primary subset) ---
    case WMF_WEP_CSM3:        weapon_manifest_price = 1700; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 1; return TRUE;
    case WMF_WEP_FLAKSHOTGUN: weapon_manifest_price = 1700; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 2; return TRUE;
    case WMF_WEP_HLSHOTGUN:   weapon_manifest_price = 1700; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 3; return TRUE;
    case WMF_WEP_CFSPAS12:    weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 4; return TRUE;
    case WMF_WEP_CFM3:        weapon_manifest_price = 1800; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 5; return TRUE;
    case WMF_WEP_CFKS23:      weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 6; return TRUE;
    case WMF_WEP_CFM4:        weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 7; return TRUE;

    // --- SMG (primary subset) ---
    case WMF_WEP_CSMP5:    weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 1; return TRUE;
    case WMF_WEP_HLSMG:    weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 2; return TRUE;
    case WMF_WEP_CFMAC10:  weapon_manifest_price = 1050; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 3; return TRUE;
    case WMF_WEP_CFMP5:    weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 4; return TRUE;
    case WMF_WEP_CFVECTOR: weapon_manifest_price = 2350; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 5; return TRUE;
    case WMF_WEP_CFUMP45:  weapon_manifest_price = 1050; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 6; return TRUE;
    case WMF_WEP_PAINTBALL:weapon_manifest_price = 1000; weapon_manifest_buycat = BUYCAT_SMG; weapon_manifest_buy_order = 7; return TRUE;

    // --- Snipers (primary subset; Crossbow is here) ---
    case WMF_WEP_CSAWP:    weapon_manifest_price = 4750; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 1;  return TRUE;
    case WMF_WEP_G3SG1:    weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 2;  return TRUE;
    case WMF_WEP_DOD98K:   weapon_manifest_price = 2750; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 3;  return TRUE;
    case WMF_WEP_SCOUT:    weapon_manifest_price = 2750; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 4;  return TRUE;
    case WMF_WEP_CROSSBOW: weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 5;  return TRUE;
    case WMF_WEP_CFBARRETT:weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 6;  return TRUE;
    case WMF_WEP_CFPSG1:   weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 7;  return TRUE;
    case WMF_WEP_CFM700:   weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_CFSVD:    weapon_manifest_price = 4200; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_CFAWM:    weapon_manifest_price = 5500; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_CFELITE:  weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_CFMSG90:  weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_SNIPER; weapon_manifest_buy_order = 12; return TRUE;

    // --- Rifles (primary subset + exotic catch-all) ---
    case WMF_WEP_AK47:     weapon_manifest_price = 2500; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 1;  return TRUE;
    case WMF_WEP_HDAK47:   weapon_manifest_price = 2500; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 2;  return TRUE;
    case WMF_WEP_M4A1:     weapon_manifest_price = 3100; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 3;  return TRUE;
    case WMF_WEP_CFAUG:    weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 4;  return TRUE;
    case WMF_WEP_CFFAMAS:  weapon_manifest_price = 2250; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 5;  return TRUE;
    case WMF_WEP_CFSCAR:   weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 6;  return TRUE;
    case WMF_WEP_CFTYPE89: weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 7;  return TRUE;
    case WMF_WEP_CFGALIL:  weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_CFSG552:  weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_CFSL8:    weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_GAUSS:    weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_GRENADELAUNCHER: weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 12; return TRUE;
    case WMF_WEP_HLEGON:   weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 13; return TRUE;
    case WMF_WEP_HLRPG:    weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 14; return TRUE;
    case WMF_WEP_REBAR:    weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_RIFLE; weapon_manifest_buy_order = 15; return TRUE;

    // --- LMG (primary subset) ---
    case WMF_WEP_M249:    weapon_manifest_price = 5750; weapon_manifest_buycat = BUYCAT_LMG; weapon_manifest_buy_order = 1; return TRUE;
    case WMF_WEP_CFM249:  weapon_manifest_price = 5750; weapon_manifest_buycat = BUYCAT_LMG; weapon_manifest_buy_order = 2; return TRUE;

    // --- Melee (free) ---
    case WMF_WEP_WRENCH:    weapon_manifest_price = 0; weapon_manifest_buycat = BUYCAT_MELEE; weapon_manifest_buy_order = 1; return TRUE;
    case WMF_WEP_KNIFE:     weapon_manifest_price = 0; weapon_manifest_buycat = BUYCAT_MELEE; weapon_manifest_buy_order = 2; return TRUE;
    case WMF_WEP_HLCROWBAR: weapon_manifest_price = 0; weapon_manifest_buycat = BUYCAT_MELEE; weapon_manifest_buy_order = 3; return TRUE;
    case WMF_WEP_BUTTERFLY: weapon_manifest_price = 0; weapon_manifest_buycat = BUYCAT_MELEE; weapon_manifest_buy_order = 4; return TRUE;
    case WMF_WEP_KATANA:    weapon_manifest_price = 0; weapon_manifest_buycat = BUYCAT_MELEE; weapon_manifest_buy_order = 5; return TRUE;

    // --- Equipment (utility grenades; armor + defuse kit are separate
    //     non-weapon items appended by the buy menu, see cl_buymenu.qc) ---
    //
    // buy_order 6 WAS CLAIMED TWICE HERE — by SATCHEL and by SLINGSHOT — and the
    // two failures that caused are worth recording, because neither one errored.
    // BuyCat_Weapon (:834) scans weapon ids ASCENDING and returns the first row
    // whose order matches, so SLINGSHOT (id 31) always beat SATCHEL (id 71) and
    // the satchel could not be bought at all.  Meanwhile BuyCat_Count (:849)
    // counts ROWS, not orders: it returned 9 against a highest order of 8, so the
    // buy menu drew a ninth row, asked BuyCat_Weapon for order 9, got
    // WMF_WEP_NONE back and rendered it as a blank $0 line.  One duplicated
    // integer, one missing weapon and one phantom row.
    //
    // Orders are now contiguous 1..9.  sv_buyorder_test asserts that on map load.
    case WMF_WEP_CSHEGRENADE:    weapon_manifest_price = 300; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 1; return TRUE;
    case WMF_WEP_CSFLASHBANG:    weapon_manifest_price = 200; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 2; return TRUE;
    case WMF_WEP_CSSMOKEGRENADE: weapon_manifest_price = 300; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 3; return TRUE;
    case WMF_WEP_HLGRENADE:      weapon_manifest_price = 300; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 4; return TRUE;
    case WMF_WEP_SNOWBALL:       weapon_manifest_price = 100; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 5; return TRUE;
    case WMF_WEP_SLINGSHOT:      weapon_manifest_price = 200; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 6; return TRUE;
    case WMF_WEP_SATCHEL:        weapon_manifest_price = 700; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 7; return TRUE;
    case WMF_WEP_TRIPMINE:       weapon_manifest_price = 700; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 8; return TRUE;
    case WMF_WEP_SNARK:          weapon_manifest_price = 400; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 9; return TRUE;

    // --- The six that had no buy entry at all ---
    // Every one of them carried WMF_FLAG_LOADOUT | WMF_FLAG_DEBUG, so they were
    // reachable from the loadout dropdown and the debug spawn grid but simply
    // absent from the buy menu — WeaponManifest_LoadBuy fell through to FALSE and
    // BuyCat_Count never counted them.  Nothing anywhere reported a gap.
    //
    // The jetpack is a Glock 18 and sits in SLOT_SECONDARY, so it belongs with the
    // handguns; the other five are SLOT_PRIMARY and go to the rifle screen, which
    // the header above already describes as the exotic catch-all.  Prices are the
    // same pure-data guesswork as every other row here — tune freely.
    case WMF_WEP_JETPACK:        weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 14; return TRUE;
    case WMF_WEP_GRAVITYGUN:     weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 16; return TRUE;
    case WMF_WEP_HORNETGUN:      weapon_manifest_price = 2500; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 17; return TRUE;
    case WMF_WEP_SHOCKRIFLE:     weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 18; return TRUE;
    case WMF_WEP_DISPLACER:      weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 19; return TRUE;
    case WMF_WEP_BGRAPPLE:       weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 20; return TRUE;

    // --- They Hunger's eight ---
    // buy_order continues each category's run (HANDGUN was full to 14, SMG to
    // 7, RIFLE to 20, SHOTGUN to 7, SNIPER to 12, MELEE to 5).  These are
    // CONTIGUOUS indices within a category, not ids: BuyCat_Weapon scans
    // ascending and takes the first match, so a duplicate silently hides the
    // higher id, and BuyCat_Count counts ROWS, so a gap draws a blank $0 row.
    // That is not hypothetical — it is what the Satchel/Slingshot collision
    // documented above this function actually did.  sv_satchel_test asserts it.
    case WMF_WEP_TH1911:         weapon_manifest_price = 500;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 15; return TRUE;
    case WMF_WEP_THTOMMY:        weapon_manifest_price = 1600; weapon_manifest_buycat = BUYCAT_SMG;     weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_THGREASE:       weapon_manifest_price = 1100; weapon_manifest_buycat = BUYCAT_SMG;     weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_THM14:          weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_SNIPER;  weapon_manifest_buy_order = 13; return TRUE;
    case WMF_WEP_THM16:          weapon_manifest_price = 2400; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 21; return TRUE;
    case WMF_WEP_THSAWOFF:       weapon_manifest_price = 1200; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_THSPANNER:      weapon_manifest_price = 200;  weapon_manifest_buycat = BUYCAT_MELEE;   weapon_manifest_buy_order = 6;  return TRUE;
    case WMF_WEP_THTESLA:        weapon_manifest_price = 4500; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 22; return TRUE;
    // buy_order continues each CATEGORY's run: EQUIPMENT was full to 9, HANDGUN
    // to 15, LMG to 2, MELEE to 6, RIFLE to 22, SHOTGUN to 8, SMG to 9,
    // SNIPER to 13.  Contiguous WITHIN the category, not global.
    case WMF_WEP_MEDKIT:         weapon_manifest_price = 800;  weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_ASSOFLAM:       weapon_manifest_price = 5000; weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 11; return TRUE;
    // The last three Opposing Force weapons.  buy_order continues each category's
    // own run — MELEE was 1..7, LMG 1..3, EQUIPMENT 1..11 — and must stay
    // contiguous per category, which sv_main.qc's terminal self-test asserts
    // across all eight BUYCAT_* buckets.
    //
    // Prices: the knife is free like every other melee entry bar the pipe wrench
    // (which charges 250 for its power swing, and the knife's charged stab is the
    // same kind of upgrade, so it matches).  The SAW is priced above both existing
    // M249s for its 200-round belt.
    case WMF_WEP_OPKNIFE:        weapon_manifest_price = 250;  weapon_manifest_buycat = BUYCAT_MELEE;     weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_OPSAW:          weapon_manifest_price = 6250; weapon_manifest_buycat = BUYCAT_LMG;       weapon_manifest_buy_order = 4;  return TRUE;
    case WMF_WEP_PENGUIN:        weapon_manifest_price = 400;  weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 12; return TRUE;

    // --- The thirteen Counter-Strike 1.6 guns. ---
    //
    // Prices are the REAL CS 1.6 ones, which is the only defensible answer for a
    // set this size: they are already a balanced ladder, they are what anyone who
    // has played the game expects, and inventing thirteen fresh numbers would put
    // them at odds with the CrossFire twins that were themselves priced against
    // CS.  buy_order continues each category's own run — HANDGUN was 1..16, SMG
    // 1..11, RIFLE 1..24, SNIPER 1..14, SHOTGUN 1..9 — which sv_main.qc's terminal
    // self-test asserts stays contiguous across all eight buckets.
    case WMF_WEP_CSP228:         weapon_manifest_price = 600;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 17; return TRUE;
    case WMF_WEP_CSFIVESEVEN:    weapon_manifest_price = 750;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 18; return TRUE;
    case WMF_WEP_CSELITE:        weapon_manifest_price = 800;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 19; return TRUE;
    case WMF_WEP_CSTMP:          weapon_manifest_price = 1250; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 12; return TRUE;
    case WMF_WEP_CSMAC10:        weapon_manifest_price = 1400; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 13; return TRUE;
    case WMF_WEP_CSUMP45:        weapon_manifest_price = 1700; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 14; return TRUE;
    case WMF_WEP_CSP90:          weapon_manifest_price = 2350; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 15; return TRUE;
    case WMF_WEP_CSGALIL:        weapon_manifest_price = 2000; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 25; return TRUE;
    case WMF_WEP_CSFAMAS:        weapon_manifest_price = 2250; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 26; return TRUE;
    case WMF_WEP_CSAUG:          weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 27; return TRUE;
    case WMF_WEP_CSSG552:        weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 28; return TRUE;
    case WMF_WEP_CSSG550:        weapon_manifest_price = 4200; weapon_manifest_buycat = BUYCAT_SNIPER;   weapon_manifest_buy_order = 15; return TRUE;
    case WMF_WEP_CSXM1014:       weapon_manifest_price = 3000; weapon_manifest_buycat = BUYCAT_SHOTGUN;  weapon_manifest_buy_order = 10; return TRUE;

    // --- Day of Defeat ---
    // Priced against the ladder above rather than against DoD, which has no
    // economy at all -- every gun there is free from a class menu.  The shape
    // that carries over is the RELATIVE one: a 1940s service pistol is the
    // cheapest thing in its bucket, the two full-power semi-auto rifles are
    // priced as rifles rather than as the snipers their damage resembles
    // (no optic, so no sniper bucket), and the BAR sits under the M249 because
    // it holds 20 rounds instead of 100.  buy_order continues each category's
    // own contiguous run, which sv_main.qc's terminal self-test asserts.
    case WMF_WEP_DODCOLT:        weapon_manifest_price = 700;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 20; return TRUE;
    case WMF_WEP_DODLUGER:       weapon_manifest_price = 650;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 21; return TRUE;
    case WMF_WEP_DODWEBLEY:      weapon_manifest_price = 700;  weapon_manifest_buycat = BUYCAT_HANDGUN;  weapon_manifest_buy_order = 22; return TRUE;
    case WMF_WEP_DODTOMMY:       weapon_manifest_price = 1600; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 16; return TRUE;
    case WMF_WEP_DODMP40:        weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 17; return TRUE;
    case WMF_WEP_DODSTEN:        weapon_manifest_price = 1250; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 18; return TRUE;
    case WMF_WEP_DODGREASE:      weapon_manifest_price = 1300; weapon_manifest_buycat = BUYCAT_SMG;      weapon_manifest_buy_order = 19; return TRUE;
    case WMF_WEP_DODGARAND:      weapon_manifest_price = 2900; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 29; return TRUE;
    case WMF_WEP_DODCARBINE:     weapon_manifest_price = 1800; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 30; return TRUE;
    case WMF_WEP_DODK43:         weapon_manifest_price = 2900; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 31; return TRUE;
    case WMF_WEP_DODMP44:        weapon_manifest_price = 2700; weapon_manifest_buycat = BUYCAT_RIFLE;    weapon_manifest_buy_order = 32; return TRUE;
    case WMF_WEP_DODBAR:         weapon_manifest_price = 3300; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 5;  return TRUE;
    // Day of Defeat, second batch.  Priced against the CS ladder the buy menu
    // already uses: the AWP is the most expensive weapon in the game at 4750, so
    // three bolt snipers with no one-shot body kill sit well under it; the belt-
    // fed MGs are priced like the M249 (5750) because that is what a machine gun
    // costs; and the three anti-tank launchers are the dearest things on the
    // board — one round, three-second reload, and they delete anyone they land
    // near.  The four melee weapons are FREE, like every other melee in this
    // tree: you always have one, and charging for a knife makes no sense.
    case WMF_WEP_DODSCOPED98K:   weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_SNIPER;   weapon_manifest_buy_order = 16; return TRUE;
    case WMF_WEP_DODSPRING:      weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_SNIPER;   weapon_manifest_buy_order = 17; return TRUE;
    case WMF_WEP_DODENFIELDS:    weapon_manifest_price = 4200; weapon_manifest_buycat = BUYCAT_SNIPER;   weapon_manifest_buy_order = 18; return TRUE;
    case WMF_WEP_DOD30CAL:       weapon_manifest_price = 5750; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 6;  return TRUE;
    case WMF_WEP_DODMG34:        weapon_manifest_price = 5750; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 7;  return TRUE;
    case WMF_WEP_DODMG42:        weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 8;  return TRUE;
    case WMF_WEP_DODBAZOOKA:     weapon_manifest_price = 6500; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_DODSCHRECK:     weapon_manifest_price = 6500; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_DODPIAT:        weapon_manifest_price = 6000; weapon_manifest_buycat = BUYCAT_LMG;      weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_DODAMERK:       weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_MELEE;    weapon_manifest_buy_order = 9;  return TRUE;
    case WMF_WEP_DODFAIRBAIRN:   weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_MELEE;    weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_DODPARAKNIFE:   weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_MELEE;    weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_DODSPADE:       weapon_manifest_price = 0;    weapon_manifest_buycat = BUYCAT_MELEE;    weapon_manifest_buy_order = 12; return TRUE;
    // The two DoD grenades sit in EQUIPMENT beside the CS three (HE is 300) and
    // are priced a shade under it, since you get two for the money and they hit
    // for less apiece — see CSGrenadeBlastDamage in sh_wpn_csgrenades.qc.
    case WMF_WEP_DODMILLS:       weapon_manifest_price = 250;  weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 13; return TRUE;
    case WMF_WEP_DODSTICK:       weapon_manifest_price = 250;  weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 14; return TRUE;
    // Day of Defeat, third batch.  Priced against their neighbours: the Bren
    // alongside the BAR (3300) with more magazine, the FG42 pair as premium
    // automatics, the folding carbine slightly under the M1 carbine's bracket,
    // the Lee-Enfield with the bolt rifles, and the mortar as the most expensive
    // thing in the LMG bucket because eight bombs at 150 damage is what it is.
    case WMF_WEP_DODBREN:        weapon_manifest_price = 3500; weapon_manifest_buycat = BUYCAT_LMG;       weapon_manifest_buy_order = 12; return TRUE;
    case WMF_WEP_DODFG42:        weapon_manifest_price = 3800; weapon_manifest_buycat = BUYCAT_RIFLE;     weapon_manifest_buy_order = 33; return TRUE;
    case WMF_WEP_DODFG42S:       weapon_manifest_price = 4400; weapon_manifest_buycat = BUYCAT_SNIPER;    weapon_manifest_buy_order = 19; return TRUE;
    case WMF_WEP_DODFCARB:       weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_RIFLE;     weapon_manifest_buy_order = 34; return TRUE;
    case WMF_WEP_DODENFIELD:     weapon_manifest_price = 2900; weapon_manifest_buycat = BUYCAT_RIFLE;     weapon_manifest_buy_order = 35; return TRUE;
    case WMF_WEP_DODMORTAR:      weapon_manifest_price = 5200; weapon_manifest_buycat = BUYCAT_LMG;       weapon_manifest_buy_order = 13; return TRUE;
    case WMF_WEP_DODBINOCS:      weapon_manifest_price = 300;  weapon_manifest_buycat = BUYCAT_EQUIPMENT; weapon_manifest_buy_order = 15; return TRUE;
    case WMF_WEP_UZI:            weapon_manifest_price = 1400; weapon_manifest_buycat = BUYCAT_SMG;     weapon_manifest_buy_order = 10; return TRUE;
    case WMF_WEP_UZIAKIMBO:      weapon_manifest_price = 2800; weapon_manifest_buycat = BUYCAT_SMG;     weapon_manifest_buy_order = 11; return TRUE;
    case WMF_WEP_MINIGUN:        weapon_manifest_price = 6500; weapon_manifest_buycat = BUYCAT_LMG;     weapon_manifest_buy_order = 3;  return TRUE;
    case WMF_WEP_SVM16:          weapon_manifest_price = 2600; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 23; return TRUE;
    case WMF_WEP_SPORELAUNCHER:  weapon_manifest_price = 4000; weapon_manifest_buycat = BUYCAT_RIFLE;   weapon_manifest_buy_order = 24; return TRUE;
    case WMF_WEP_PIPEWRENCH:     weapon_manifest_price = 250;  weapon_manifest_buycat = BUYCAT_MELEE;   weapon_manifest_buy_order = 7;  return TRUE;
    case WMF_WEP_SNIPERRIFLE:    weapon_manifest_price = 4750; weapon_manifest_buycat = BUYCAT_SNIPER;  weapon_manifest_buy_order = 14; return TRUE;
    case WMF_WEP_EAGLE:          weapon_manifest_price = 900;  weapon_manifest_buycat = BUYCAT_HANDGUN; weapon_manifest_buy_order = 16; return TRUE;
    case WMF_WEP_ASSHOTGUN:      weapon_manifest_price = 1500; weapon_manifest_buycat = BUYCAT_SHOTGUN; weapon_manifest_buy_order = 9;  return TRUE;
    }
    return FALSE;   // WMF_WEP_MELEE (fists), WMF_WEP_CFC4, NONE -> not buyable
};

float(float wep) WeaponManifest_Price =
{
    if (!WeaponManifest_LoadBuy(wep)) return 0;
    return weapon_manifest_price;
};

float(float wep) WeaponManifest_BuyCat =
{
    if (!WeaponManifest_LoadBuy(wep)) return BUYCAT_NONE;
    return weapon_manifest_buycat;
};

// 1-based enumeration within a buy category (no synthetic "None" row).
float(float cat, float idx) BuyCat_Weapon =
{
    float wep;
    if (idx <= 0)
        return WMF_WEP_NONE;
    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_LoadBuy(wep))
            continue;
        if (weapon_manifest_buycat == cat && weapon_manifest_buy_order == idx)
            return wep;
    }
    return WMF_WEP_NONE;
};

float(float cat) BuyCat_Count =
{
    float count = 0;
    float wep;
    for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
    {
        if (!WeaponManifest_LoadBuy(wep))
            continue;
        if (weapon_manifest_buycat == cat)
            count = count + 1;
    }
    return count;
};

// ============================================================
//  Source-game data.  A PARALLEL switch, for exactly the reason
//  WeaponManifest_LoadBuy is one: WeaponManifest_Set already takes 13
//  arguments across 78 call sites, and a 14th would mean editing every one of
//  them to carry a value that only the menus read.
//
//  Every tag below was GENERATED, not typed: SV_DebugSpawnWeaponId's
//  WEP_x -> weapon_y table was walked into the file that defines each
//  weapon_y, and the FILE's prefix decided the game.  That matters because the
//  constant names lie about it in roughly twenty cases — WMF_WEP_357 is
//  Half-Life (sh_wpn_hl357.qc) while WMF_WEP_GLOCK is Counter-Strike
//  (sh_wpn_csglock.qc), and neither name says so.  The trailing comment on
//  each row is the file it was derived from; re-derive rather than hand-edit.
//
//  Deliberately NOT invalidating weapon_manifest_cached_valid the way LoadBuy
//  does.  LoadBuy documents that invalidation as defensive insurance it can
//  afford because it only ever runs from the buy menu.  This one is called per
//  weapon per frame while the F5 panel is open, and it provably writes only
//  weapon_manifest_game — none of the 13 memoised core globals — so there is
//  nothing for a stale memo to be wrong about, and invalidating would re-run
//  the ~78-case core switch on every single call.
// ============================================================
float(float wep) WeaponManifest_LoadGame =
{
    weapon_manifest_game = WMF_GAME_NONE;
    switch (wep)
    {
    // --- Half-Life (14) ---
    case WMF_WEP_357:       weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hl357.qc
    case WMF_WEP_CROSSBOW:  weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlcrossbow.qc
    case WMF_WEP_GAUSS:     weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlgauss.qc
    case WMF_WEP_HLCROWBAR: weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlcrowbar.qc
    case WMF_WEP_HLEGON:    weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlegon.qc
    case WMF_WEP_HLGLOCK:   weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlglock.qc
    case WMF_WEP_HLGRENADE: weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlgrenade.qc
    case WMF_WEP_HLRPG:     weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlrpg.qc
    case WMF_WEP_HLSHOTGUN: weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlshotgun.qc
    case WMF_WEP_HLSMG:     weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlsmg.qc
    case WMF_WEP_HORNETGUN: weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlhornetgun.qc
    case WMF_WEP_SATCHEL:   weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlsatchel.qc
    case WMF_WEP_SNARK:     weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hlsnark.qc
    case WMF_WEP_TRIPMINE:  weapon_manifest_game = WMF_GAME_HL;         return TRUE;   // sh_wpn_hltripmine.qc

    // --- Opposing Force (3) ---
    case WMF_WEP_BGRAPPLE:   weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opbgrapple.qc
    case WMF_WEP_DISPLACER:  weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opdisplacer.qc
    case WMF_WEP_SHOCKRIFLE: weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opshockrifle.qc

    // --- Sven Co-op (1) ---
    case WMF_WEP_JETPACK: weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svjetpack.qc

    // --- They Hunger (8) ---
    // Tagged by hand, not generated: the generator keyed off the FILENAME
    // prefix and these files did not exist when it ran.  The `th` prefix is
    // now part of the taxonomy alongside cs/cf/hl/op/sv/dod/hd.
    case WMF_WEP_TH1911:     weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_th1911.qc
    case WMF_WEP_THTOMMY:    weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thtommygun.qc
    case WMF_WEP_THGREASE:   weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thgreasegun.qc
    case WMF_WEP_THM14:      weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thm14.qc
    case WMF_WEP_THM16:      weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thm16a1.qc
    case WMF_WEP_THSAWOFF:   weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thsawedoff.qc
    case WMF_WEP_THSPANNER:  weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thspanner.qc
    case WMF_WEP_THTESLA:    weapon_manifest_game = WMF_GAME_HUNGER;     return TRUE;   // sh_wpn_thtesla.qc

    // --- Counter-Strike (16) ---
    case WMF_WEP_AK47:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csak47.qc
    case WMF_WEP_CSAWP:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csawp.qc
    case WMF_WEP_CSFLASHBANG:    weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csgrenades.qc
    case WMF_WEP_CSHEGRENADE:    weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csgrenades.qc
    case WMF_WEP_CSM3:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csm3.qc
    case WMF_WEP_CSMP5:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csmp5.qc
    case WMF_WEP_CSSMOKEGRENADE: weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csgrenades.qc
    case WMF_WEP_CSUSP:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csusp.qc
    case WMF_WEP_DEAGLE:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csdeagle.qc
    case WMF_WEP_G3SG1:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csg3sg1.qc
    case WMF_WEP_GLOCK:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csglock.qc
    case WMF_WEP_HDAK47:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_hdak47.qc  (HD model pack)
    case WMF_WEP_KNIFE:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csknife.qc
    case WMF_WEP_M249:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csm249.qc
    case WMF_WEP_M4A1:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csm4a1.qc
    case WMF_WEP_SCOUT:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csscout.qc

    // --- CrossFire (31) ---
    case WMF_WEP_CFAUG:      weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfaug.qc
    case WMF_WEP_CFAWM:      weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfawm.qc
    case WMF_WEP_CFBARRETT:  weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfbarrett.qc
    case WMF_WEP_CFC4:       weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfc4.qc
    case WMF_WEP_CFDDEAGLE:  weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfddeagle.qc
    case WMF_WEP_CFELITE:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfelite.qc
    case WMF_WEP_CFFAMAS:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cffamas.qc
    case WMF_WEP_CFGALIL:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfgalil.qc
    case WMF_WEP_CFGLOCK:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfglock.qc
    case WMF_WEP_CFKS23:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfks23.qc
    case WMF_WEP_CFM249:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfm249.qc
    case WMF_WEP_CFM3:       weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfm3.qc
    case WMF_WEP_CFM4:       weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfm4.qc
    case WMF_WEP_CFM700:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfm700.qc
    case WMF_WEP_CFM9:       weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfm9.qc
    case WMF_WEP_CFMAC10:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfmac10.qc
    case WMF_WEP_CFMAUSER:   weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfmauser.qc
    case WMF_WEP_CFMK23:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfmk23.qc
    case WMF_WEP_CFMP5:      weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfmp5.qc
    case WMF_WEP_CFMSG90:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfmsg90.qc
    case WMF_WEP_CFP228:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfp228.qc
    case WMF_WEP_CFPSG1:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfpsg1.qc
    case WMF_WEP_CFREVOLVER: weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfrevolver.qc
    case WMF_WEP_CFSCAR:     weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfscar.qc
    case WMF_WEP_CFSG552:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfsg552.qc
    case WMF_WEP_CFSL8:      weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfsl8.qc
    case WMF_WEP_CFSPAS12:   weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfspas12.qc
    case WMF_WEP_CFSVD:      weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfsvd.qc
    case WMF_WEP_CFTYPE89:   weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cftype89.qc
    case WMF_WEP_CFUMP45:    weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfump45.qc
    case WMF_WEP_CFVECTOR:   weapon_manifest_game = WMF_GAME_CROSSFIRE;  return TRUE;   // sh_wpn_cfvector.qc

    // --- Day of Defeat (13) ---
    case WMF_WEP_DOD98K: weapon_manifest_game = WMF_GAME_DOD;        return TRUE;   // sh_wpn_dod98k.qc
    case WMF_WEP_DODCOLT:    weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodcolt.qc
    case WMF_WEP_DODLUGER:   weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodluger.qc
    case WMF_WEP_DODWEBLEY:  weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodwebley.qc
    case WMF_WEP_DODGARAND:  weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodgarand.qc
    case WMF_WEP_DODCARBINE: weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodcarbine.qc
    case WMF_WEP_DODK43:     weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodk43.qc
    case WMF_WEP_DODTOMMY:   weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodtommy.qc
    case WMF_WEP_DODMP40:    weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodmp40.qc
    case WMF_WEP_DODSTEN:    weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodsten.qc
    case WMF_WEP_DODGREASE:  weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodgrease.qc
    case WMF_WEP_DODMP44:    weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodmp44.qc
    case WMF_WEP_DODBAR:     weapon_manifest_game = WMF_GAME_DOD;    return TRUE;   // sh_wpn_dodbar.qc
    case WMF_WEP_DODSCOPED98K:  weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodscoped98k.qc
    case WMF_WEP_DODSPRING:     weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodspring.qc
    case WMF_WEP_DODENFIELDS:   weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodenfieldscoped.qc
    case WMF_WEP_DOD30CAL:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmgs.qc
    case WMF_WEP_DODMG34:       weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmgs.qc
    case WMF_WEP_DODMG42:       weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmgs.qc
    case WMF_WEP_DODBAZOOKA:    weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodat.qc
    case WMF_WEP_DODSCHRECK:    weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodat.qc
    case WMF_WEP_DODPIAT:       weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodat.qc
    case WMF_WEP_DODAMERK:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmelee.qc
    case WMF_WEP_DODFAIRBAIRN:  weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmelee.qc
    case WMF_WEP_DODPARAKNIFE:  weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmelee.qc
    case WMF_WEP_DODSPADE:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmelee.qc
    case WMF_WEP_DODMILLS:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_csgrenades.qc
    case WMF_WEP_DODSTICK:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_csgrenades.qc
    case WMF_WEP_DODBREN:       weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodauto.qc
    case WMF_WEP_DODFG42:       weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodauto.qc
    case WMF_WEP_DODFG42S:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodauto.qc
    case WMF_WEP_DODFCARB:      weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodfcarb.qc
    case WMF_WEP_DODENFIELD:    weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodenfield.qc
    case WMF_WEP_DODMORTAR:     weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodmortar.qc
    case WMF_WEP_DODBINOCS:     weapon_manifest_game = WMF_GAME_DOD; return TRUE;   // sh_wpn_dodbinocs.qc

    // --- Half-Life 2 (1) ---
    // The one row the generator could not derive: the file is unprefixed because
    // this mod wrote the gravity gun from scratch rather than porting it, so the
    // filename says nothing about where the weapon comes from.  Tagged by hand.
    case WMF_WEP_GRAVITYGUN: weapon_manifest_game = WMF_GAME_HL2;        return TRUE;   // sh_wpn_gravitygun.qc

    // --- Quakers' own (10) ---
    case WMF_WEP_BUTTERFLY:       weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_butterfly.qc
    case WMF_WEP_FLAKSHOTGUN:     weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_flakshotgun.qc
    case WMF_WEP_GRENADELAUNCHER: weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_grenadelauncher.qc
    case WMF_WEP_KATANA:          weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_katana.qc
    case WMF_WEP_PAINTBALL:       weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_paintball.qc
    case WMF_WEP_PISTOL:          weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_pistol.qc
    case WMF_WEP_REBAR:           weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_rebar.qc
    case WMF_WEP_SLINGSHOT:       weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_snowball.qc
    case WMF_WEP_SNOWBALL:        weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_snowball.qc
    case WMF_WEP_WRENCH:          weapon_manifest_game = WMF_GAME_QUAKERS;    return TRUE;   // sh_wpn_wrench.qc
    // Tagged by the FILE that defines each one, not by the constant name - the
    // two disagree constantly (see the note above this function).  The four
    // Opposing Force weapons are OPFOR even though Sven's FGD is where their
    // classnames were read from; the two pizza_ya_san guns are SVEN, because a
    // Sven map's own AngelScript is Sven content.
    case WMF_WEP_MEDKIT:          weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svmedkit.qc
    case WMF_WEP_UZI:             weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svuzi.qc
    case WMF_WEP_UZIAKIMBO:       weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svuziakimbo.qc
    case WMF_WEP_MINIGUN:         weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svminigun.qc
    case WMF_WEP_SVM16:           weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_svm16.qc
    case WMF_WEP_ASSHOTGUN:       weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_asshotgun.qc
    case WMF_WEP_ASSOFLAM:        weapon_manifest_game = WMF_GAME_SVEN;       return TRUE;   // sh_wpn_assoflam.qc
    case WMF_WEP_OPKNIFE:         weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opknife.qc
    case WMF_WEP_OPSAW:           weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opsaw.qc
    case WMF_WEP_PENGUIN:         weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_oppenguin.qc
    case WMF_WEP_PIPEWRENCH:      weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_oppipewrench.qc
    case WMF_WEP_SNIPERRIFLE:     weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opsniperrifle.qc
    case WMF_WEP_SPORELAUNCHER:   weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opsporelauncher.qc
    case WMF_WEP_EAGLE:           weapon_manifest_game = WMF_GAME_OPFOR;      return TRUE;   // sh_wpn_opeagle.qc
    // The thirteen that finish the Counter-Strike arsenal.  These are what makes
    // the F5 panel list them under the "Counter-Strike 1.6" header beside the
    // twelve that were already here, rather than mixed into CrossFire's block.
    case WMF_WEP_CSP228:          weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csp228.qc
    case WMF_WEP_CSFIVESEVEN:     weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csfiveseven.qc
    case WMF_WEP_CSELITE:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_cselite.qc
    case WMF_WEP_CSTMP:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_cstmp.qc
    case WMF_WEP_CSMAC10:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csmac10.qc
    case WMF_WEP_CSUMP45:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csump45.qc
    case WMF_WEP_CSP90:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csp90.qc
    case WMF_WEP_CSGALIL:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csgalil.qc
    case WMF_WEP_CSFAMAS:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csfamas.qc
    case WMF_WEP_CSAUG:           weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csaug.qc
    case WMF_WEP_CSSG552:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_cssg552.qc
    case WMF_WEP_CSSG550:         weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_cssg550.qc
    case WMF_WEP_CSXM1014:        weapon_manifest_game = WMF_GAME_CS;         return TRUE;   // sh_wpn_csxm1014.qc
    }
    // WMF_WEP_MELEE (fists) is the only weapon with no tag, and correctly so:
    // it is intrinsic, has no spawn function, and carries neither menu flag.
    return FALSE;
};

float(float wep) WeaponManifest_Game =
{
    if (!WeaponManifest_LoadGame(wep))
        return WMF_GAME_NONE;
    return weapon_manifest_game;
};

string(float game) WeaponManifest_GameLabel =
{
    switch (game)
    {
    case WMF_GAME_HL:        return "Half-Life";
    case WMF_GAME_OPFOR:     return "Opposing Force";
    case WMF_GAME_SVEN:      return "Sven Co-op";
    case WMF_GAME_HUNGER:    return "They Hunger";
    case WMF_GAME_CS:        return "Counter-Strike";
    case WMF_GAME_CROSSFIRE: return "CrossFire";
    case WMF_GAME_DOD:       return "Day of Defeat";
    case WMF_GAME_HL2:       return "Half-Life 2";
    case WMF_GAME_QUAKERS:   return "Quakers";
    }
    return "Other";
};

string(float cat) BuyCat_Label =
{
    switch (cat)
    {
    case BUYCAT_HANDGUN:   return "Handguns";
    case BUYCAT_SHOTGUN:   return "Shotguns";
    case BUYCAT_SMG:       return "SMG";
    case BUYCAT_SNIPER:    return "Snipers";
    case BUYCAT_RIFLE:     return "Rifles";
    case BUYCAT_LMG:       return "LMG";
    case BUYCAT_MELEE:     return "Melee";
    case BUYCAT_EQUIPMENT: return "Equipment";
    }
    return "?";
};

// ============================================================
//  Non-weapon buy items (Equipment screen): armor + defuse kit.  Reserved
//  ids >= 10000 so they never collide with WMF_WEP_* (0..69).  Shared so the
//  CSQC buy menu can list/price them and the SSQC buy handler can apply them.
//  Appended after the EQUIPMENT grenades on the buy menu's 8th screen.
// ============================================================
const float BUYITEM_KEVLAR     = 10001;
const float BUYITEM_KEVLARHELM = 10002;
const float BUYITEM_DEFUSEKIT  = 10003;
// The tactical shield is equipment for the same reason kevlar is — it is not a
// weapon, it occupies no slot, and it modifies how you take damage.  $2200 is
// Counter-Strike's own price, and it is priced that way because carrying one
// costs you a primary weapon entirely.
const float BUYITEM_SHIELD     = 10004;
const float BUYITEM_COUNT      = 4;

float(float idx) BuyItem_ByIndex =   // idx 1..BUYITEM_COUNT
{
    switch (idx)
    {
    case 1: return BUYITEM_KEVLAR;
    case 2: return BUYITEM_KEVLARHELM;
    case 3: return BUYITEM_DEFUSEKIT;
    case 4: return BUYITEM_SHIELD;
    }
    return 0;
};

float(float item) BuyItem_IsItem =
{
    return (item >= BUYITEM_KEVLAR && item <= BUYITEM_SHIELD);
};

string(float item) BuyItem_Name =
{
    switch (item)
    {
    case BUYITEM_KEVLAR:     return "Kevlar";
    case BUYITEM_KEVLARHELM: return "Kevlar+Helmet";
    case BUYITEM_DEFUSEKIT:  return "Defuse Kit";
    case BUYITEM_SHIELD:     return "Tactical Shield";
    }
    return "?";
};

float(float item) BuyItem_Price =
{
    switch (item)
    {
    case BUYITEM_KEVLAR:     return 650;
    case BUYITEM_KEVLARHELM: return 1000;
    case BUYITEM_DEFUSEKIT:  return 400;
    case BUYITEM_SHIELD:     return 2200;
    }
    return 0;
};
