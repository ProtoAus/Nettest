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

void(float new_weapon) CSQC_PredictSelectWeapon =
{
    string snd;

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
    CSQC_MarkPendingWeaponAck();

    if (!pm_suppress_sounds)
    {
        snd = SH_WeaponDeploySound(new_weapon);
        if (snd != "")
            localsound(snd);
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

    wmodel = SH_WeaponWorldModel(weapon_id);
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

    // Clear the vacated slot and zero its ammo
    if (cur == self.slot_primary)
    {
        self.slot_primary = WEP_NONE;
        if (cur == WEP_AK47)         { self.mag_ak47 = 0; self.ammo_ak47 = 0; }
        else if (cur == WEP_M4A1)    { self.mag_m4a1 = 0; self.ammo_m4a1 = 0; self.m4a1_silenced = 0; }
        else if (cur == WEP_FLAKSHOTGUN) { self.mag_flakshotgun = 0; }
        else if (cur == WEP_SCOUT)   { self.mag_scout = 0; self.ammo_scout = 0; self.zoomstage = 0; }
        else if (cur == WEP_M249)    { self.mag_m249 = 0; self.ammo_m249 = 0; }
        else if (cur == WEP_CSAWP)   { self.mag_awp = 0; self.ammo_awp = 0; self.zoomstage = 0; }
        else if (cur == WEP_DOD98K)  { self.mag_98k = 0; self.ammo_98k = 0; }
        else if (cur == WEP_HLSHOTGUN) { self.mag_shotgun = 0; self.ammo_shotgun = 0; }
        else if (cur == WEP_CSM3)    { self.mag_m3 = 0; self.ammo_m3 = 0; }
        else if (cur == WEP_CSMP5)   { self.mag_mp5 = 0; self.ammo_mp5 = 0; }
        else if (cur == WEP_CROSSBOW) { self.mag_crossbow = 0; self.ammo_crossbow = 0; self.zoomstage = 0; }
        else if (cur == WEP_GRENADELAUNCHER) { self.mag_grenadelauncher = 0; }
        else if (cur == WEP_REBAR)   { self.mag_rebar = 0; }
        else if (cur == WEP_GAUSS)   { self.ammo_gauss = 0; }
    }
    else if (cur == self.slot_secondary)
    {
        self.slot_secondary = WEP_NONE;
        if (cur == WEP_DEAGLE)       { self.mag_deagle = 0; self.ammo_deagle = 0; }
        else if (cur == WEP_PISTOL)  { self.mag_pistol = 0; self.ammo_pistol = 0; }
        else if (cur == WEP_357)     { self.mag_357 = 0; self.ammo_357 = 0; }
    }
    else if (cur == self.slot_melee)
    {
        self.slot_melee = WEP_NONE;
    }

    self.weapon         = WEP_NONE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;

    // Auto-switch to next available weapon
    CSQC_PredictSelectNextWeapon();
};

// --- Reload dispatcher ---

void() CSQC_PredictReload =
{
    if (self.weapon == WEP_DEAGLE)       { CSQC_PredictDeagleReload();       return; }
    if (self.weapon == WEP_AK47)         { CSQC_PredictAK47Reload();         return; }
    if (self.weapon == WEP_M4A1)         { CSQC_PredictM4A1Reload();         return; }
    if (self.weapon == WEP_PISTOL)       { CSQC_PredictPistolReload();       return; }
    if (self.weapon == WEP_SCOUT)        { CSQC_PredictScoutReload();        return; }
    if (self.weapon == WEP_357)          { CSQC_Predict357Reload();          return; }
    if (self.weapon == WEP_M249)         { CSQC_PredictM249Reload();         return; }
    if (self.weapon == WEP_CSAWP)        { CSQC_PredictAWPReload();          return; }
    if (self.weapon == WEP_DOD98K)       { CSQC_Predict98KReload();          return; }
    if (self.weapon == WEP_HLSHOTGUN)    { CSQC_PredictShotgunReload();      return; }
    if (self.weapon == WEP_CSM3)         { CSQC_PredictM3Reload();           return; }
    if (self.weapon == WEP_CSMP5)        { CSQC_PredictMP5Reload();          return; }
    if (self.weapon == WEP_CROSSBOW)     { CSQC_PredictCrossbowReload();     return; }
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

    if (self.weapon == WEP_DEAGLE) { CSQC_PredictDeagleCommand(); return; }
    if (self.weapon == WEP_KNIFE)  { CSQC_PredictKnifeCommand();  return; }
    if (self.weapon == WEP_AK47)         { CSQC_PredictAK47Command();         return; }
    if (self.weapon == WEP_M4A1)         { CSQC_PredictM4A1Command();         return; }
    if (self.weapon == WEP_FLAKSHOTGUN)  { CSQC_PredictFlakShotgunCommand();  return; }
    if (self.weapon == WEP_PISTOL)       { CSQC_PredictPistolCommand();       return; }
    if (self.weapon == WEP_SCOUT)        { CSQC_PredictScoutCommand();        return; }
    if (self.weapon == WEP_357)          { CSQC_Predict357Command();          return; }
    if (self.weapon == WEP_WRENCH)       { CSQC_PredictWrenchCommand();       return; }
    if (self.weapon == WEP_M249)         { CSQC_PredictM249Command();         return; }
    if (self.weapon == WEP_CSAWP)        { CSQC_PredictAWPCommand();          return; }
    if (self.weapon == WEP_DOD98K)       { CSQC_Predict98KCommand();          return; }
    if (self.weapon == WEP_HLCROWBAR)    { CSQC_PredictCrowbarCommand();      return; }
    if (self.weapon == WEP_HLSHOTGUN)    { CSQC_PredictShotgunCommand();      return; }
    if (self.weapon == WEP_CSM3)         { CSQC_PredictM3Command();           return; }
    if (self.weapon == WEP_CSMP5)        { CSQC_PredictMP5Command();          return; }
    if (self.weapon == WEP_CROSSBOW)     { CSQC_PredictCrossbowCommand();     return; }
    if (self.weapon == WEP_GRENADELAUNCHER) { CSQC_PredictGLCommand();        return; }
    if (self.weapon == WEP_REBAR)        { CSQC_PredictRebarCommand();        return; }
    if (self.weapon == WEP_GAUSS)        { CSQC_PredictGaussCommand();        return; }
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

    if (predicted_player.weapon == WEP_DEAGLE) return CSQC_DeagleDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_KNIFE)  return CSQC_KnifeDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_AK47)         return CSQC_AK47DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_M4A1)         return CSQC_M4A1DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_FLAKSHOTGUN)  return CSQC_FlakShotgunDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_PISTOL)       return CSQC_PistolDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_SCOUT)        return CSQC_ScoutDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_357)          return CSQC_357DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_WRENCH)       return CSQC_WrenchDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_M249)         return CSQC_M249DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_CSAWP)        return CSQC_AWPDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_DOD98K)       return CSQC_98KDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_HLCROWBAR)    return CSQC_CrowbarDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_HLSHOTGUN)    return CSQC_ShotgunDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_CSM3)         return CSQC_M3DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_CSMP5)        return CSQC_MP5DisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_CROSSBOW)     return CSQC_CrossbowDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_GRENADELAUNCHER) return CSQC_GLDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_REBAR)        return CSQC_RebarDisplayFrame(elapsed);
    if (predicted_player.weapon == WEP_GAUSS)        return CSQC_GaussDisplayFrame(elapsed);

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

    // M4A1 viewmodel depends on silencer state
    if (predicted_player.weapon == WEP_M4A1)
    {
        entity old_self = self;
        self = predicted_player;
        mdl = SH_M4A1ViewModel();
        self = old_self;
    }
    else
        mdl = SH_WeaponViewModel(predicted_player.weapon);
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
