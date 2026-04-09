// ============================================================
//  client/cl_weapons.qc  -  CSQC weapon dispatchers & selection
//
//  Per-weapon prediction and display logic lives in each
//  weapon's shared file (shared/weapons/sh_wpn_*.qc).
//  This file handles weapon selection, impulse dispatch,
//  and the main prediction + viewmodel dispatchers.
// ============================================================

// --- Weapon selection ---

float(float weapon_id) CSQC_PlayerHasWeapon =
{
    if (weapon_id == WEP_NONE)
        return FALSE;

    if (self.slot_primary == weapon_id)
        return TRUE;
    if (self.slot_secondary == weapon_id)
        return TRUE;
    if (self.slot_melee == weapon_id)
        return TRUE;

    return FALSE;
};

void(float weapon_id) CSQC_WeaponEquip;  // forward declaration

void(float new_weapon) CSQC_PredictSelectWeapon =
{
    if (new_weapon == WEP_NONE || new_weapon == self.weapon)
        return;
    if (!CSQC_PlayerHasWeapon(new_weapon))
        return;

    if (self.weapon != WEP_NONE)
        self.previous_weapon = self.weapon;

    self.weapon         = new_weapon;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = csqc_pred_time;
    CSQC_WeaponEquip(new_weapon);
    CSQC_MarkPendingWeaponAck();

    if (!pm_suppress_sounds)
    {
        if (self.weapon_deploy_sound != "")
            localsound(self.weapon_deploy_sound);
        CSQC_RecordPredictedWeaponSound();
    }
};

void() CSQC_PredictSelectNextWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
};

void() CSQC_PredictSelectPrevWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
};

void() CSQC_PredictSelectLastWeapon =
{
    if (self.previous_weapon == WEP_NONE)
        return;
    if (self.previous_weapon == self.weapon)
        return;
    if (!CSQC_PlayerHasWeapon(self.previous_weapon))
        return;

    CSQC_PredictSelectWeapon(self.previous_weapon);
};

// --- Drop prediction ---

// Fake drop entity — visual only, removed when server entity arrives.
entity csqc_fake_drop;
float  csqc_fake_drop_expire;

void() CSQC_CheckFakeDropRemoval =
{
    if (!csqc_fake_drop)
        return;

    if (cltime > csqc_fake_drop_expire)
    {
        remove(csqc_fake_drop);
        csqc_fake_drop = world;
    }
};


void(float weapon_id) CSQC_SpawnFakeDrop =
{
    string wmodel;
    vector drop_mins, drop_maxs;

    if (pm_suppress_sounds)
        return;

    wmodel = self.weapon_worldmodel;
    if (wmodel == "")
        return;

    // Match server entity sizing
    if (weapon_id == WEP_DEAGLE || weapon_id == WEP_PISTOL || weapon_id == WEP_357)
    {
        drop_mins = '-12 -12 0';
        drop_maxs = '12 12 24';
    }
    else
    {
        drop_mins = '-16 -16 0';
        drop_maxs = '16 16 32';
    }

    // Remove previous fake drop if any
    if (csqc_fake_drop)
    {
        remove(csqc_fake_drop);
        csqc_fake_drop = world;
    }

    makevectors(input_angles);

    csqc_fake_drop = spawn();
    setmodel(csqc_fake_drop, wmodel);
    setsize(csqc_fake_drop, drop_mins, drop_maxs);
    setorigin(csqc_fake_drop, self.origin + self.view_ofs + v_forward * 24);
    csqc_fake_drop.velocity  = v_forward * 200 + '0 0 80';
    csqc_fake_drop.angles    = '0 0 0';
    csqc_fake_drop.movetype  = MOVETYPE_TOSS;
    csqc_fake_drop.solid     = SOLID_NOT;
    csqc_fake_drop.drawmask  = MASK_ENGINE;
    // Expire after: ping (server entity appears) + ~0.7s (toss settles)
    {
        // Match server's weapon_become_solid timing (0.7s) + ping
        float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
        ping_est = bound(0.05, ping_est, 1.0);
        csqc_fake_drop_expire = cltime + ping_est + 0.75;
    }
};

void() CSQC_PredictDropWeapon =
{
    float cur = self.weapon;

    if (cur == WEP_NONE)
        return;

    // Spawn visual toss entity instantly
    CSQC_SpawnFakeDrop(cur);

    // Clear the vacated slot and zero its ammo via per-weapon drop clear
    if (cur == self.slot_primary)
        self.slot_primary = WEP_NONE;
    else if (cur == self.slot_secondary)
        self.slot_secondary = WEP_NONE;
    else if (cur == self.slot_melee)
        self.slot_melee = WEP_NONE;

    if (self.csqc_drop_clear)
        self.csqc_drop_clear();

    self.weapon         = WEP_NONE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;

    // Auto-switch to next available weapon
    CSQC_PredictSelectNextWeapon();
};

// --- Reload dispatcher ---

void() CSQC_PredictReload =
{
    if (self.csqc_predict_reload)
        self.csqc_predict_reload();
};

// --- Impulse handling ---

void() CSQC_PredictWeaponImpulse =
{
    if (!input_impulse)
        return;

    switch (input_impulse)
    {
    case WEAPON_IMPULSE_PRIMARY:
        if (self.slot_primary)
            CSQC_PredictSelectWeapon(self.slot_primary);
        break;
    case WEAPON_IMPULSE_SECONDARY:
        if (self.slot_secondary)
            CSQC_PredictSelectWeapon(self.slot_secondary);
        break;
    case WEAPON_IMPULSE_MELEE:
        if (self.slot_melee)
            CSQC_PredictSelectWeapon(self.slot_melee);
        break;
    case WEAPON_IMPULSE_DROP:
        CSQC_PredictDropWeapon();
        break;
    case USE_IMPULSE:
        if (!pm_suppress_sounds)
            CSQC_PredictUse();
        break;
    case WEAPON_IMPULSE_RELOAD:
        CSQC_PredictReload();
        break;
    case WEAPON_IMPULSE_NEXT:
        CSQC_PredictSelectNextWeapon();
        break;
    case WEAPON_IMPULSE_PREV:
        CSQC_PredictSelectPrevWeapon();
        break;
    case WEAPON_IMPULSE_LASTINV:
        CSQC_PredictSelectLastWeapon();
        break;
    default:
        break;
    }
};

// ============================================================
//  CSQC_PredictWeaponCommand — dispatcher
//  Called after PM_PlayerMove() with self = predicted_player.
//  Delegates to per-weapon prediction functions defined in
//  shared/weapons/sh_wpn_*.qc.
// ============================================================

void() CSQC_PredictWeaponCommand =
{
    if (getstatf(STAT_IS_DEAD))
        return;

    CSQC_PredictWeaponImpulse();

    if (self.csqc_predict_cmd)
        self.csqc_predict_cmd();
};

// ============================================================
//  CSQC_GetWeaponDisplayFrame — dispatcher
//  Returns the fractional animation frame for viewmodel lerp.
//  Delegates to per-weapon display functions.
// ============================================================

float() CSQC_GetWeaponDisplayFrame =
{
    float elapsed;

    if (!predicted_player)
        return 0;

    elapsed = (predicted_player.wep_anim_start > 0)
              ? max(0, cltime - predicted_player.wep_anim_start)
              : 0;

    if (predicted_player.csqc_display_frame)
        return predicted_player.csqc_display_frame(elapsed);

    return 0;
};

// ============================================================
//  CSQC_AddPredictedViewmodel
//  Submits the viewmodel entity driven by predicted weapon state.
// ============================================================

void() CSQC_AddPredictedViewmodel =
{
    string mdl;

    if (!predicted_player || predicted_player.weapon == WEP_NONE)
        return;
    if (getstatf(STAT_IS_DEAD))
        return;

    mdl = predicted_player.weapon_viewmodel;
    if (mdl == "")
        return;

    if (!csqc_viewmodel_ent)
        csqc_viewmodel_ent = spawn();

    setmodel(csqc_viewmodel_ent, mdl);

    {
        float disp = CSQC_GetWeaponDisplayFrame();
        float fi   = floor(disp);
        csqc_viewmodel_ent.frame       = fi;
        csqc_viewmodel_ent.frame2      = fi + 1;
        csqc_viewmodel_ent.lerpfrac    = disp - fi;
    }

    csqc_viewmodel_ent.renderflags  = RF_VIEWMODEL | RF_DEPTHHACK;
    addentity(csqc_viewmodel_ent);
};

// ============================================================
//  CSQC_WeaponEquip — single dispatch
//  Maps weapon ID to per-weapon CSQC equip function.
//  Sets all client-side function pointers and weapon data fields.
//  Called from CSQC_PredictSelectWeapon and proxy weapon sync.
// ============================================================

void(float weapon_id) CSQC_WeaponEquip =
{
    // Clear previous weapon's pointers
    self.csqc_predict_cmd    = __NULL__;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = __NULL__;
    self.csqc_drop_clear     = __NULL__;
    self.weapon_viewmodel    = "";
    self.weapon_worldmodel   = "";
    self.weapon_deploy_sound = "";

    if (weapon_id == WEP_DEAGLE)            CSQC_DeagleEquip();
    else if (weapon_id == WEP_KNIFE)        CSQC_KnifeEquip();
    else if (weapon_id == WEP_AK47)         CSQC_AK47Equip();
    else if (weapon_id == WEP_M4A1)         CSQC_M4A1Equip();
    else if (weapon_id == WEP_FLAKSHOTGUN)  CSQC_FlakShotgunEquip();
    else if (weapon_id == WEP_PISTOL)       CSQC_PistolEquip();
    else if (weapon_id == WEP_GAUSS)        CSQC_GaussEquip();
    else if (weapon_id == WEP_CROSSBOW)     CSQC_CrossbowEquip();
    else if (weapon_id == WEP_357)          CSQC_357Equip();
    else if (weapon_id == WEP_DOD98K)       CSQC_98KEquip();
    else if (weapon_id == WEP_SCOUT)        CSQC_ScoutEquip();
    else if (weapon_id == WEP_GRENADELAUNCHER) CSQC_GLEquip();
    else if (weapon_id == WEP_M249)         CSQC_M249Equip();
    else if (weapon_id == WEP_HLCROWBAR)    CSQC_CrowbarEquip();
    else if (weapon_id == WEP_HLSHOTGUN)    CSQC_ShotgunEquip();
    else if (weapon_id == WEP_CSM3)         CSQC_M3Equip();
    else if (weapon_id == WEP_CSMP5)        CSQC_MP5Equip();
    else if (weapon_id == WEP_REBAR)        CSQC_RebarEquip();
    else if (weapon_id == WEP_CSAWP)        CSQC_AWPEquip();
    else if (weapon_id == WEP_WRENCH)       CSQC_WrenchEquip();
    else if (weapon_id == WEP_GLOCK)        CSQC_GlockEquip();
    else if (weapon_id == WEP_G3SG1)        CSQC_G3SG1Equip();
};
