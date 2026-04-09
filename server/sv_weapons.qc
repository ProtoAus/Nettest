// ============================================================
//  server/sv_weapons.qc  -  Core weapon system
//  Damage helpers, weapon pickup touch, weapon slot management.
// ============================================================

// Forward declarations
void(entity player) PM_SyncPredictionProxy;  // defined in sv_player.qc
void() W_DeagleEquip;         // defined in wpn_deagle.qc
void() W_DeagleDrop;          // defined in wpn_deagle.qc
void() W_KnifeEquip;
void() W_KnifeDrop;
void() W_AK47Equip;
void() W_AK47Drop;
void() W_M4A1Equip;
void() W_M4A1Drop;
void() W_FlakShotgunEquip;
void() W_FlakShotgunDrop;
void() W_PistolEquip;
void() W_PistolDrop;
void() W_ScoutEquip;
void() W_ScoutDrop;
void() W_357Equip;
void() W_357Drop;
void() W_WrenchEquip;
void() W_WrenchDrop;
void() W_M249Equip;
void() W_M249Drop;
void() W_AWPEquip;
void() W_AWPDrop;
void() W_98KEquip;
void() W_98KDrop;
void() W_CrowbarEquip;
void() W_CrowbarDrop;
void() W_ShotgunEquip;
void() W_ShotgunDrop;
void() W_M3Equip;
void() W_M3Drop;
void() W_MP5Equip;
void() W_MP5Drop;
void() W_CrossbowEquip;
void() W_CrossbowDrop;
void() W_GLEquip;
void() W_GLDrop;
void() W_RebarEquip;
void() W_RebarDrop;
void() W_GaussEquip;
void() W_GaussDrop;
void() weapon_ak47;
void() weapon_pistol;
void() weapon_flakshotgun;
void() weapon_scout;
void() weapon_357;
void() weapon_wrench;
void() weapon_m249;
void() weapon_csawp;
void() weapon_dod98k;
void() weapon_hlcrowbar;
void() weapon_hlshotgun;
void() weapon_csm3;
void() weapon_csmp5;
void() weapon_crossbow;
void() weapon_grenadelauncher;
void() weapon_rebar;
void() weapon_gauss;
void() PlayerSpawn;           // defined in sv_player.qc
void(float) W_SelectWeapon;   // defined later in this file
void() weapon_become_solid;   // defined later in this file

// Global set by W_DropCurrentWeapon before calling the slot drop function.
// The drop function reads this to know which entity to populate.
entity weapon_drop_target;

// ============================================================
//  W_SetCrosshairProfile
//  Called by every weapon equip function to declare its crosshair
//  parameters.  The engine auto-networks the fields to the client
//  via clientstat() so the crosshair reacts on the next server frame.
//
//  show_crosshair: TRUE = show crosshair (guns); FALSE = hide (knife)
// ============================================================

void() W_ClearZoom =
{
    self.zoomstage = 0;
    self.sv_zoomstage = 0;
};

void(float basespread, float movespread, float fullspeed,
     float gapscale, float show_crosshair) W_SetCrosshairProfile =
{
    self.sv_crosshair_basespread = basespread;
    self.sv_crosshair_movespread = movespread;
    self.sv_crosshair_fullspeed  = fullspeed;
    self.sv_crosshair_gapscale   = gapscale;
    self.sv_crosshair_disabled   = !show_crosshair;
};

// ============================================================
//  W_WeaponTraceLine
//  Lag-compensated traceline wrapper used by melee and hitscan.
// ============================================================

void(vector src, vector end) W_WeaponTraceLine =
{
    traceline(src, end, MOVE_NORMAL | MOVE_LAGGED, self);
};

// ============================================================
//  SpawnImpactLight / PlayerModelPlayPrimaryAttack
//  Stub implementations — extend later for visual effects and
//  player animation events.
// ============================================================

void(vector pos) SpawnImpactLight =
{
    // placeholder: add a dynamic light or particle burst here
};

// Send bullet impact effect to all players EXCEPT the shooter (self).
// The shooter sees it instantly via client-side prediction.
void(vector pos) W_ImpactEffect =
{
    float saved_dim = dimension_send;

    // Exclude the shooter: temporarily clear their dimension bit
    dimension_send = dimension_send & ~self.dimension_seen;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_IMPACT);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_x);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_y);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_z);
    multicast(pos, MULTICAST_PVS);

    dimension_send = saved_dim;
};

// Send shell casing eject to all players EXCEPT the shooter.
// The shooter sees it instantly via client-side prediction.
void(float shell_type, vector origin_offset, vector base_vel, vector base_avel) W_ShellEffect =
{
    float saved_dim = dimension_send;
    dimension_send = dimension_send & ~self.dimension_seen;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_SHELL);
    WriteByte(MSG_MULTICAST, shell_type);
    WriteCoord(MSG_MULTICAST, org_x);
    WriteCoord(MSG_MULTICAST, org_y);
    WriteCoord(MSG_MULTICAST, org_z);
    WriteCoord(MSG_MULTICAST, vel_x);
    WriteCoord(MSG_MULTICAST, vel_y);
    WriteCoord(MSG_MULTICAST, vel_z);
    WriteCoord(MSG_MULTICAST, base_avel_x);
    WriteCoord(MSG_MULTICAST, base_avel_y);
    WriteCoord(MSG_MULTICAST, base_avel_z);
    multicast(org, MULTICAST_PVS);

    dimension_send = saved_dim;
};

// Send magazine drop to all players EXCEPT the shooter.
void(float mag_type, vector origin_offset, vector base_vel) W_MagDropEffect =
{
    float saved_dim = dimension_send;
    dimension_send = dimension_send & ~self.dimension_seen;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_MAGDROP);
    WriteByte(MSG_MULTICAST, mag_type);
    WriteCoord(MSG_MULTICAST, org_x);
    WriteCoord(MSG_MULTICAST, org_y);
    WriteCoord(MSG_MULTICAST, org_z);
    WriteCoord(MSG_MULTICAST, vel_x);
    WriteCoord(MSG_MULTICAST, vel_y);
    WriteCoord(MSG_MULTICAST, vel_z);
    multicast(org, MULTICAST_PVS);

    dimension_send = saved_dim;
};

void() PlayerModelPlayPrimaryAttack =
{
    // placeholder: trigger player model attack animation here
};

// ============================================================
//  Damage helpers  (referenced by NewQuake/weapons/damage.qc)
// ============================================================

float(entity target) W_CanDamageTarget =
{
    if (target == world)
        return FALSE;
    if (target.health <= 0)
        return FALSE;
    if (target.classname == "player")
        return TRUE;
    if (target.takedamage != DAMAGE_YES)
        return FALSE;
    return TRUE;
};

void(entity attacker, entity victim) PlayerKilled =
{
    bprint(PRINT_HIGH, attacker.netname);
    bprint(PRINT_HIGH, " shot ");
    bprint(PRINT_HIGH, victim.netname);
    bprint(PRINT_HIGH, "\n");

    victim.deaths = victim.deaths + 1;
    PlayerRefreshScoreboardInfo(victim);

    if (attacker.classname == "player")
    {
        if (attacker == victim)
            attacker.frags = attacker.frags - 1;
        else
            attacker.frags = attacker.frags + 1;

        PlayerRefreshScoreboardInfo(attacker);
        logfrag(attacker, victim);
    }

    // Deferred death — body stays visible for death cam, respawn/spectate
    // handled in StartFrame after mp_deathdelay expires.
    victim.is_dead = TRUE;
    victim.death_time = time;
    victim.solid = SOLID_NOT;
    victim.health = 0;
    victim.velocity = '0 0 0';

    // Strip weapons so dead player can't switch
    victim.weapon = WEP_NONE;
    victim.weaponmodel = "";
    victim.weaponframe = 0;
};

float(float dist, float close_dmg, float min_dmg, float range) W_LinearDamageFalloff =
{
    float t;
    if (range <= 0)
        return close_dmg;
    t = bound(0, dist / range, 1);
    return close_dmg + (min_dmg - close_dmg) * t;
};

float(entity attacker, entity target, float damage) W_ApplyDamage =
{
    entity saved;
    entity old_activator;

    if (!W_CanDamageTarget(target))
        return 0;

    if (damage > target.health)
        damage = target.health;

    target.health       = target.health - damage;
    target.dmg_take     = damage;
    target.dmg_inflictor = attacker;

    if (target.health <= 0 && target.classname == "player")
    {
        PlayerKilled(attacker, target);
        return damage;
    }

    // Non-player entity killed: fire its .use function so buttons/triggers activate.
    // Set activator = attacker so the target chain knows who pulled the trigger.
    if (target.health <= 0 && target.use)
    {
        saved         = self;
        old_activator = activator;
        self          = target;
        activator     = attacker;
        self.use();
        self          = saved;
        activator     = old_activator;
        return damage;
    }

    if (target.health > 0 && target.on_damaged)
    {
        saved = self;
        self  = target;
        self.on_damaged();
        self  = saved;
    }

    if (target.health <= 0 && target.on_killed)
    {
        saved = self;
        self  = target;
        self.on_killed();
        self  = saved;
    }

    return damage;
};

// ============================================================
//  Weapon become solid  -  deferred think on dropped weapons
//  Prevents the dropper from immediately re-picking up the weapon.
// ============================================================

void() weapon_become_solid =
{
    self.solid = SOLID_TRIGGER;
    // Unhide from dropper now that weapon has settled
    self.nodrawtoclient = world;
};


// ============================================================
//  Weapon touch  -  called when a player walks over a pickup
// ============================================================

void() weapon_touch =
{
    entity player = other;
    entity pickup = self;
    entity saved;
    float  slot;

    if (player.classname != "player")
        return;

    slot = pickup.weapon_slot;

    // Reject if player already has a weapon in this slot — must drop first
    if (slot == SLOT_PRIMARY   && player.slot_primary)   return;
    if (slot == SLOT_SECONDARY && player.slot_secondary) return;
    if (slot == SLOT_MELEE     && player.slot_melee)     return;

    // Copy ammo from world entity to player (self = pickup for pickupcopy)
    saved = self;
    self = pickup;
    if (self.pickupcopy)
        self.pickupcopy(player);
    self = saved;

    // Register weapon in the correct player slot
    if (slot == SLOT_PRIMARY)
    {
        player.slot_primary       = pickup.weapon;
        player.slot_primary_equip = pickup.weap_draw;
        player.slot_primary_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_SECONDARY)
    {
        player.slot_secondary       = pickup.weapon;
        player.slot_secondary_equip = pickup.weap_draw;
        player.slot_secondary_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_MELEE)
    {
        player.slot_melee       = pickup.weapon;
        player.slot_melee_equip = pickup.weap_draw;
        player.slot_melee_drop  = pickup.weap_drop_func;
    }

    // Auto-equip if this is a better weapon than what we're holding.
    // Primary > Secondary > Melee.
    {
        float should_equip = FALSE;

        if (player.weapon == WEP_NONE)
            should_equip = TRUE;
        else if (slot == SLOT_PRIMARY)
            should_equip = TRUE;   // primary is always best
        else if (slot == SLOT_SECONDARY && !player.slot_primary)
            should_equip = TRUE;   // secondary is best if no primary

        if (should_equip)
        {
            saved = self;
            self  = player;
            W_SelectWeapon(pickup.weapon);
            self = saved;
        }
    }

    sound(player, CHAN_ITEM, "sounds/weapons/pickup1.wav", 1, ATTN_NORM);

    // Sync proxy immediately so the client receives correct ammo values
    PM_SyncPredictionProxy(player);

    remove(pickup);
};

// ============================================================
//  Weapon bindings management
// ============================================================

void() W_ClearWeaponBindings =
{
    self.weaponmodel    = "";
    self.weaponframe    = 0;
    self.weaponstate    = WS_IDLE;
    self.wep_nextframe  = 0;
    self.wep_anim_start = 0;
    self.attack_finished = 0;
    self.fire           = __NULL__;
    self.reload         = __NULL__;
    self.wepframe       = __NULL__;
};

// Equip the weapon that matches self.weapon, using the supplied function.
void(float slot_weapon, void() slot_equip) W_TryEquipSlot =
{
    if (self.weapon != slot_weapon || !slot_equip)
        return;
    W_ClearWeaponBindings();
    slot_equip();   // sets weaponmodel, fire, reload, wepframe, initial frame/state
};

void() W_ChangeWeapon =
{
    W_TryEquipSlot(self.slot_primary,   self.slot_primary_equip);
    W_TryEquipSlot(self.slot_secondary, self.slot_secondary_equip);
    W_TryEquipSlot(self.slot_melee,     self.slot_melee_equip);
};

void(float new_weapon) W_SelectWeapon =
{
    float cur = self.weapon;

    if (new_weapon == WEP_NONE || new_weapon == cur)
        return;

    if (self.slot_primary   != new_weapon &&
        self.slot_secondary != new_weapon &&
        self.slot_melee     != new_weapon)
        return;

    if (cur != WEP_NONE)
        self.previous_weapon = cur;

    self.weapon = new_weapon;
    W_ChangeWeapon();
};

// ============================================================
//  Weapon cycling
// ============================================================

void() W_SelectNextWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    // No weapon equipped - pick first available
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
};

void() W_SelectPrevWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }
    // No weapon - pick last available
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
};

void() W_SelectLastWeapon =
{
    if (self.previous_weapon == WEP_NONE)
        return;
    if (self.previous_weapon == self.weapon)
        return;

    // Make sure we still have the previous weapon
    if (self.slot_primary   != self.previous_weapon &&
        self.slot_secondary != self.previous_weapon &&
        self.slot_melee     != self.previous_weapon)
        return;

    W_SelectWeapon(self.previous_weapon);
};

// ============================================================
//  Drop current weapon
// ============================================================

void() W_DropCurrentWeapon =
{
    void() drop_func;
    entity drop_ent;
    float  cur;

    cur = self.weapon;
    if (cur == WEP_NONE)
        return;

    drop_func = __NULL__;
    if (cur == self.slot_primary   && self.slot_primary_drop)   drop_func = self.slot_primary_drop;
    if (cur == self.slot_secondary && self.slot_secondary_drop) drop_func = self.slot_secondary_drop;
    if (cur == self.slot_melee     && self.slot_melee_drop)     drop_func = self.slot_melee_drop;

    if (!drop_func)
        return;

    // Spawn the world entity, toss it forward from view
    drop_ent = spawn();
    makevectors(self.v_angle);
    setorigin(drop_ent, self.origin + self.view_ofs + v_forward * 24);
    drop_ent.velocity = v_forward * 200 + '0 0 80';

    weapon_drop_target = drop_ent;
    drop_func();          // populates drop_ent (ammo, model, solid, touch, etc.)
    weapon_drop_target = world;

    // Hide from dropper — their client-side fake drop covers the visual.
    // weapon_become_solid fires at +0.7s; we unhide at +1.5s after that.
    drop_ent.nodrawtoclient = self;

    // Clear the vacated slot
    if (cur == self.slot_primary)
    {
        self.slot_primary       = WEP_NONE;
        self.slot_primary_equip = __NULL__;
        self.slot_primary_drop  = __NULL__;
    }
    else if (cur == self.slot_secondary)
    {
        self.slot_secondary       = WEP_NONE;
        self.slot_secondary_equip = __NULL__;
        self.slot_secondary_drop  = __NULL__;
    }
    else if (cur == self.slot_melee)
    {
        self.slot_melee       = WEP_NONE;
        self.slot_melee_equip = __NULL__;
        self.slot_melee_drop  = __NULL__;
    }

    self.weapon = WEP_NONE;
    W_ClearWeaponBindings();
    W_SelectNextWeapon();
};

// ============================================================
//  Impulse dispatch  -  call from CheckImpulses in sv_player.qc
//  Handles weapon impulses only; zeros self.impulse for those it claims.
// ============================================================

void() W_CheckImpulses =
{
    if (!self.impulse)
        return;

    switch (self.impulse)
    {
    case WEAPON_IMPULSE_PRIMARY:   // Select primary slot
        if (self.slot_primary) W_SelectWeapon(self.slot_primary);
        break;
    case WEAPON_IMPULSE_SECONDARY:   // Select secondary slot
        if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
        break;
    case WEAPON_IMPULSE_MELEE:   // Select melee slot
        if (self.slot_melee) W_SelectWeapon(self.slot_melee);
        break;
    case 4:   // Utility - reserved
        break;
    case WEAPON_IMPULSE_DROP:   // Drop current weapon
        W_DropCurrentWeapon();
        break;
    case WEAPON_IMPULSE_RELOAD:   // Reload
        if (self.reload) self.reload();
        break;
    case WEAPON_IMPULSE_NEXT:  // Next weapon (bind mwheelup "impulse 12")
        W_SelectNextWeapon();
        break;
    case WEAPON_IMPULSE_PREV:  // Previous weapon (bind mwheeldown "impulse 13")
        W_SelectPrevWeapon();
        break;
    case WEAPON_IMPULSE_LASTINV:  // Last inventory (bind q "impulse 14")
        W_SelectLastWeapon();
        break;
    default:
        return;   // not a weapon impulse, leave self.impulse intact
    }
    self.impulse = 0;
};

// ============================================================
//  Per-command weapon frame  -  call from PlayerPreThink
// ============================================================

void() W_WeaponFrame =
{
    // Check fire button (attack_finished debounce)
    if (self.button0 && time >= self.attack_finished)
    {
        if (self.fire)
            self.fire();
    }

    // Check alt-fire button
    if (self.button1 && time >= self.attack_finished)
    {
        if (self.altfire)
            self.altfire();
    }
    else if (!self.button1 && self.altrelease)
    {
        self.altrelease();
    }

    // Advance weapon animation on schedule
    if (self.wep_nextframe > 0 && time >= self.wep_nextframe)
    {
        if (self.wepframe)
            self.wepframe();
    }
};
