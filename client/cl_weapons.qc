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

    // Exact mirror of W_SelectWeapon's gate on the server (sv_weapons.qc), which
    // is why both now call the same shared W_CarryHas: a cursor comparison would
    // refuse to select the second primary the player is demonstrably carrying,
    // and the two sides would disagree about what a keypress did.
    if (W_CarryHas(self, weapon_id))
        return TRUE;
    if (W_UtilityWeaponSelectable(weapon_id) && W_UtilityPlayerHasWeapon(weapon_id))
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

    // Latched before self.weapon is overwritten below — the ammo hand-off needs
    // the OUTGOING weapon.
    float prev_wep = self.weapon;

    if (self.weapon != WEP_NONE)
        self.previous_weapon = self.weapon;

    // Switching weapons disconnects the smoke source from the muzzle —
    // kill any pending chain so puffs don't keep appearing at the new
    // weapon's barrel.  This early-outs on same-weapon above so it
    // doesn't fire during reconcile re-equips.
    CSQC_MuzzleSmokeStopChain();

    if (cvar("sv_debug_wepswap"))
    {
        dprint(sprintf("[CL wepswap] cltime=%g  %g→%g  origin=%v  velocity=%v  speed=%.1f\n",
            cltime, self.weapon, new_weapon, self.origin, self.velocity, vlen(self.velocity)));
        CL_Drift_Dump();
    }

    // Capture the CURRENT effective speed factor (which may itself be
    // mid-transition from a prior switch) BEFORE updating self.weapon,
    // then reset blend progress to 0 — PM_ReadMovevars advances it per
    // pmove tick, deterministic between live, replay and server.
    self.pm_weapon_prev_factor    = Weapon_SpeedFactor_Smooth();
    self.pm_weapon_blend_progress = 0;

    self.weapon         = new_weapon;
    // Move the cursor and re-point the canonical ammo register, mirroring
    // W_SelectWeapon on the server.  The client needs no W_RebindSlot — it
    // dispatches equip by weapon id (CSQC_WeaponEquip below) rather than through
    // per-slot function pointers — but it DOES need the ammo hand-off, or a
    // predicted cycle between two primaries shows the wrong magazine until the
    // next snapshot corrects it.
    // EXACT MIRROR of the server's W_SelectWeapon: one W_SlotAmmo_PointAt does
    // the persist / move / hydrate.  These two must move together — the client
    // carried the identical bug (a HYDRATE of the outgoing weapon rather than a
    // persist), which is precisely why nobody ever saw a desync from it: both
    // halves were wrong the same way.
    float nsl = WeaponManifest_Slot(new_weapon);
    if (nsl == SLOT_PRIMARY || nsl == SLOT_SECONDARY)
        W_SlotAmmo_PointAt(self, nsl, new_weapon);
    // C4 stays out of slot_utility — selecting it shouldn't clobber
    // the player's actual carried utility (HE/flash/etc.).
    if (W_UtilityWeaponSelectable(new_weapon) && new_weapon != WEP_CFC4)
        self.slot_utility = new_weapon;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = csqc_pred_time;
    // Mirror server's W_ClearWeaponBindings — without this the previous
    // weapon's debounce (e.g. scout's long firetime) carries onto the
    // new one and CSQC silently rejects fast follow-up shots while the
    // server happily registers them (no client sound/decal but real
    // server damage).
    self.attack_finished    = 0;
    self.altfire_finished   = 0;
    self.csqc_fire_guard    = 0;
    self.csqc_reload_guard  = 0;
    W_SlotAmmo_LoadLegacy(self, new_weapon);
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
    // Inside the utility "section" cycle through carried grenades one
    // at a time before falling out to the next slot.  Without this the
    // mousewheel jumped straight from any utility to PRIMARY, leaving
    // extra carried utilities unreachable except via the dedicated
    // utility-cycle key (impulse 4).
    if (W_UtilityWeaponSelectable(self.weapon))
    {
        float u = W_UtilityCycleCarried(self.weapon, 1);
        if (u != WEP_NONE) { CSQC_PredictSelectWeapon(u); return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        return;
    }

    if (self.weapon == self.slot_primary)
    {
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
};

void() CSQC_PredictSelectPrevWeapon =
{
    if (W_UtilityWeaponSelectable(self.weapon))
    {
        float u = W_UtilityCycleCarried(self.weapon, -1);
        if (u != WEP_NONE) { CSQC_PredictSelectWeapon(u); return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        return;
    }

    if (self.weapon == self.slot_primary)
    {
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
        return;
    }
    if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
};

// Pick the player's strongest carried weapon, in slot priority:
// primary > secondary > melee > utility.  Used after dropping the
// currently-held weapon — the player should always end up holding
// the best thing they still have, not whatever the cycle order
// happens to land on.
void() CSQC_PredictSelectStrongest =
{
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
};

void() CSQC_PredictSelectLastWeapon =
{
    // Normal "last inventory" path: switch back to the previously-held
    // weapon if it's still in inventory.
    if (self.previous_weapon != WEP_NONE
        && self.previous_weapon != self.weapon
        && CSQC_PlayerHasWeapon(self.previous_weapon))
    {
        CSQC_PredictSelectWeapon(self.previous_weapon);
        return;
    }

    // Spawn fallback (no previous_weapon yet, or it was dropped/lost):
    // jump to the secondary slot first since that's the most useful
    // "other" weapon — fall through to melee, then utility, then
    // primary if nothing else exists.  Skip the currently-held weapon
    // so impulse 14 always changes the active slot.
    if (self.slot_secondary && self.slot_secondary != self.weapon)
    { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee     && self.slot_melee     != self.weapon)
    { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility   && self.slot_utility   != self.weapon)
    { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
    if (self.slot_primary   && self.slot_primary   != self.weapon)
    { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
};

// --- Drop prediction ---

// Forward declarations — fake-drop and dropped-weapon helpers call
// into each other across the file.  QC compiler is one-pass, so
// references to functions/consts defined below need declaring here.
void(entity w) dropped_weapon_list_add_csqc;
void(entity w) dropped_weapon_list_remove_csqc;
void() CSQC_PickupPredict_Expire;
const float PICKUP_PREDICT_TIMEOUT = 2.0;

// Fake drops — visual-only client entities rendered for the dropper
// during the short pickup-grace window before the server reveals the
// authoritative CSQC entity.  Linked list because death drops produce
// up to four simultaneously (one per inventory slot).  Each ent self-
// expires by cltime vs its stored csqc_fake_drop_expire_time.
void() CSQC_CheckFakeDropRemoval =
{
    entity w = csqc_fake_drop_list;
    entity prev = world;
    float  i = 0;
    while (w)
    {
        entity nxt = w.csqc_fake_drop_next;
        if (cltime > w.csqc_fake_drop_expire_time)
        {
            if (prev)
                prev.csqc_fake_drop_next = nxt;
            else
                csqc_fake_drop_list = nxt;
            // Also unlink from dropped_weapon_list where fakes live for
            // CheckPickupTouches visibility.
            dropped_weapon_list_remove_csqc(w);
            remove(w);
        }
        else
            prev = w;
        w = nxt;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_CheckFakeDropRemoval: cycle detected, breaking chain\n");
            if (prev)
                prev.csqc_fake_drop_next = world;
            return;
        }
    }
};

// Size helper — matches server's drop bbox per weapon type. Width and
// height MUST stay in sync with the server-side setsize calls in
// shared/weapons/sh_wpn_*.qc; any drift makes +use register on the
// client (within the local fake's touch hull) but get rejected on the
// server (outside the real entity's touch hull) → "I'm using it but
// nothing happens" bug.
//
// Note: pickup detection is decoupled from this physics-body size on
// the server (see WEAPON_PICKUP_HALF_W in sv_weapons.qc), so the only
// thing that has to match here is the visual/touch hull, not the
// pickup zone.
void(float weapon_id, __inout vector mins, __inout vector maxs) CSQC_FakeDrop_Size =
{
    if (weapon_id == WEP_DEAGLE || weapon_id == WEP_PISTOL || weapon_id == WEP_357)
    {
        mins = '-12 -12 0';
        maxs = '12 12 40';
    }
    else
    {
        mins = '-16 -16 0';
        maxs = '16 16 48';
    }
};

// Mirror of sv_weapons.qc weapon_settle_think. Polls the fake's velocity,
// then locks the pickup upright instead of laying it flat on the floor.
void() CSQC_FakeDrop_SettleThink =
{
    vector flat_vel;
    float  yaw;

    flat_vel    = self.velocity;
    flat_vel_z  = 0;
    if ((fabs(self.velocity_z) > 30 || vlen(flat_vel) > 30)
        && time < self.weapon_settle_deadline)
    {
        self.nextthink = time + 0.2;
        return;
    }

    yaw = self.angles_y;
    self.angles = [0, yaw, 0];
};

// Core spawn used by both explicit drop (in front of view) and death-
// drop scatter (server-supplied origin/velocity).  wmodel comes from
// the caller so death drops don't depend on self.weapon_worldmodel
// (which is cleared by the time the death event lands).  slot is
// required so CSQC_CheckPickupTouches can predict-pickup the fake
// before the real networked entity arrives (pickup grace + latency).
void(float weapon_id, float slot, string wmodel, vector spawn_origin,
     vector spawn_velocity, float expire_dur,
     float drop_mag, float drop_ammo, float drop_aux) CSQC_SpawnFakeDropAt =
{
    vector drop_mins = '0 0 0';
    vector drop_maxs = '0 0 0';
    entity fd;

    if (wmodel == "")
        return;

    CSQC_FakeDrop_Size(weapon_id, drop_mins, drop_maxs);

    fd = spawn();
    setmodel(fd, wmodel);
    setsize(fd, drop_mins, drop_maxs);
    setorigin(fd, spawn_origin);
    fd.velocity  = spawn_velocity;
    fd.avelocity = '0 0 0';
    fd.angles    = '0 0 0';
    fd.movetype  = MOVETYPE_TOSS;
    fd.solid     = SOLID_NOT;
    fd.drawmask  = MASK_ENGINE;
    fd.csqc_fake_drop_expire_time = cltime + expire_dur;

    // Classify as a dropped_weapon so CSQC_CheckPickupTouches picks it
    // up (mirrors the fields CSQC_DroppedWeapon_Update isnew sets).
    fd.classname            = "csqc_dropped_weapon";
    fd.dropped_weapon_id    = weapon_id;
    fd.dropped_weapon_slot  = slot;
    fd.dropped_weapon_mag   = drop_mag;
    fd.dropped_weapon_ammo  = drop_ammo;
    fd.dropped_weapon_silencer = drop_aux;

    // Match server's SOLID_NOT -> SOLID_TRIGGER gate inside weapon_
    // become_solid: drop_ent is un-touchable during the pickup grace.
    // Without this the dropper immediately predict-picks their own
    // toss, server denies, and CSQC rolls back 1 RTT later.
    fd.dropped_weapon_pickup_time = cltime + WEAPON_DROP_PICKUP_DELAY;

    // Upright settle think — matches server's weapon_settle_think.
    fd.weapon_settle_deadline = time + 10;
    fd.think     = CSQC_FakeDrop_SettleThink;
    fd.nextthink = time + 0.2;

    // Two lists: dropped_weapon_list so CheckPickupTouches sees it,
    // csqc_fake_drop_list so CheckFakeDropRemoval expires it and the
    // isnew-swap can find/remove it by weapon_id.
    dropped_weapon_list_add_csqc(fd);
    fd.csqc_fake_drop_next = csqc_fake_drop_list;
    csqc_fake_drop_list = fd;
};

void(float weapon_id) CSQC_SpawnFakeDrop =
{
    if (pm_suppress_sounds)
        return;
    if (serverkeyfloat("sv_phys_drops", 0) > 0
        && Weapon_PhysDropEligible(weapon_id))
        return;

    string wmodel = self.weapon_worldmodel;
    if (wmodel == "")
        return;

    // Resolve slot from the dropper's current inventory BEFORE the
    // caller clears it (CSQC_PredictDropWeapon calls this spawn first,
    // then zeros self.slot_*).  Without the slot the fake can't be
    // predict-picked by CSQC_CheckPickupTouches.
    float slot = 0;
    if      (self.slot_primary   == weapon_id) slot = SLOT_PRIMARY;
    else if (self.slot_secondary == weapon_id) slot = SLOT_SECONDARY;
    else if (self.slot_melee     == weapon_id) slot = SLOT_MELEE;
    else if (W_UtilityWeaponSelectable(weapon_id) && W_UtilityPlayerHasWeapon(weapon_id)) slot = SLOT_UTILITY;

    float drop_mag = 0;
    float drop_ammo = 0;
    float drop_aux = 0;
    if (W_SlotAmmo_UsesSlot(weapon_id))
    {
        // ReadWeapon, not SaveLegacy+Get: this must report the DROPPED weapon's
        // own ammo without writing the slot cache, which belongs to whatever the
        // cursor names.  With multi-carry those are not always the same weapon.
        W_SlotAmmo_ReadWeapon(self, weapon_id);
        drop_mag = slotammo_mag;
        drop_ammo = slotammo_ammo;
        drop_aux = slotammo_aux;
    }
    else if (weapon_id == WEP_HLGRENADE)       drop_ammo = self.ammo_hlgrenade;
    else if (weapon_id == WEP_SATCHEL)         drop_ammo = self.ammo_satchel;
    else if (weapon_id == WEP_TRIPMINE)        drop_ammo = self.ammo_tripmine;
    else if (weapon_id == WEP_SNARK)           drop_ammo = self.ammo_snark;
    else if (weapon_id == WEP_HORNETGUN)       drop_ammo = self.ammo_hornet;
    else if (weapon_id == WEP_SHOCKRIFLE)      drop_ammo = self.ammo_shockrifle;
    else if (weapon_id == WEP_THTESLA)         drop_ammo = self.ammo_thtesla;
    // Sven Co-op and Opposing Force.  Single-pool weapons only - the magazine
    // guns carry their reserve through the slot-ammo mirror instead.
    else if (weapon_id == WEP_MINIGUN)         drop_ammo = self.ammo_minigun;
    else if (weapon_id == WEP_MEDKIT)          drop_ammo = self.ammo_medkit;
    else if (weapon_id == WEP_ASSOFLAM)        drop_ammo = self.ammo_soflam;
    else if (weapon_id == WEP_DISPLACER)       drop_ammo = self.ammo_displacer;
    else if (weapon_id == WEP_JETPACK)         drop_ammo = self.ammo_jetpack;
    else if (weapon_id == WEP_SNOWBALL)        drop_ammo = self.ammo_snowball;
    else if (weapon_id == WEP_CSHEGRENADE)     drop_ammo = self.ammo_cshegrenade;
    else if (weapon_id == WEP_CSFLASHBANG)     drop_ammo = self.ammo_csflashbang;
    else if (weapon_id == WEP_CSSMOKEGRENADE)  drop_ammo = self.ammo_cssmokegrenade;
    else if (weapon_id == WEP_DODMILLS)        drop_ammo = self.ammo_dodmills;
    else if (weapon_id == WEP_DODSTICK)        drop_ammo = self.ammo_dodstick;
    else if (weapon_id == WEP_SLINGSHOT)       drop_aux = self.snowball_has_slingshot;

    makevectors(input_angles);
    vector spawn_origin   = self.origin + self.view_ofs + v_forward * 24;
    vector spawn_velocity = self.velocity + v_forward * 200 + '0 0 80';

    // Expire shortly after the pickup-grace window; the real CSQC entity
    // should appear as soon as the server reveals it.
    float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
    ping_est = bound(0.05, ping_est, 1.0);

    CSQC_SpawnFakeDropAt(weapon_id, slot, wmodel, spawn_origin, spawn_velocity,
                         ping_est + WEAPON_DROP_PICKUP_DELAY + 0.1,
                         drop_mag, drop_ammo, drop_aux);
};

void() CSQC_PredictDropWeapon =
{
    float cur = self.weapon;

    if (cur == WEP_NONE)
        return;

    // A WEAPON WITH NO WORLD PICKUP CANNOT BE DROPPED, and predicting the drop
    // anyway is what produced the reported "draw animation occurs when nothing
    // is happening".  The chain: the server's dispatcher refuses (there is no
    // drop function to call), while this ran regardless — clearing the slot and
    // letting CSQC_PredictSelectStrongest stamp WS_DRAW plus a deploy sound on
    // the next weapon.  One round trip later the correcting snapshot restores
    // the weapon that never left and cl_player.qc:1071 stamps WS_DRAW a SECOND
    // time.  Two draw animations, nothing dropped, and for the binoculars not
    // even a visible object flying out — CSQC_SpawnFakeDrop below early-outs on
    // the same empty string this now tests.
    //
    // A server-side fix alone could not have helped: the first draw is entirely
    // client-side, and reconcile never writes weaponstate back
    // (cl_player.qc:1022), so the server's refusal is invisible here by
    // construction.  Testing the world model rather than an id list means a
    // future pickup-less tool is covered without touching this again.
    if (self.weapon_worldmodel == "")
        return;

    // Spawn visual toss entity instantly
    CSQC_SpawnFakeDrop(cur);

    // Clear the vacated slot and zero its ammo via per-weapon drop clear
    // Mirror of W_DropCurrentWeapon on the server: drop the entry from the carry
    // list and fall the cursor back to whatever is still in that slot, rather
    // than emptying it outright.  The old form also left the carry list holding
    // the weapon it had just dropped, so for about one round trip
    // CSQC_PlayerHasWeapon would happily approve selecting a gun on the floor.
    if (cur == self.slot_primary)
    {
        W_CarryRemove(self, SLOT_PRIMARY, cur);
        W_SlotAmmo_PointAt(self, SLOT_PRIMARY, W_CarryAt(self, SLOT_PRIMARY, 0));
    }
    else if (cur == self.slot_secondary)
    {
        W_CarryRemove(self, SLOT_SECONDARY, cur);
        W_SlotAmmo_PointAt(self, SLOT_SECONDARY, W_CarryAt(self, SLOT_SECONDARY, 0));
    }
    else if (cur == self.slot_melee)
        self.slot_melee = WEP_NONE;

    if (self.csqc_drop_clear)
        self.csqc_drop_clear();
    // C4 stays out of slot_utility — dropping it shouldn't change the
    // carried utility (HE/flash/etc.) that the cycle tracks.
    if (W_UtilityWeaponSelectable(cur) && cur != WEP_CFC4)
    {
        // Mirror of the vacate-then-ask in the server's W_DropCurrentWeapon
        // (server/sv_weapons.qc, the W_UtilityWeaponSelectable branch): the medkit is
        // owned by the slot, so leaving the cursor on it makes W_UtilityNextCarried
        // wrap round and return the very weapon just dropped.  The two sides must
        // move together or CSQC predicts keeping a medkit the server threw away.
        // The SOFLAM and the binoculars share the medkit's slot-based ownership
        // (sh_wpn_snowball.qc:267 tests all three the same way), so vacating only
        // the medkit let W_UtilityNextCarried wrap round and hand the other two
        // straight back — the exact failure the comment above argues against.
        if (cur == WEP_MEDKIT || cur == WEP_ASSOFLAM || cur == WEP_DODBINOCS)
            self.slot_utility = WEP_NONE;
        self.slot_utility = W_UtilityNextCarried(cur);
    }

    self.weapon         = WEP_NONE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;

    // Auto-switch to the strongest weapon left in inventory
    // (primary > secondary > melee > utility) — previously called
    // PredictSelectNextWeapon, which picked based on cycle order
    // and so could leave the player on melee after dropping their
    // secondary even though they still had a primary.
    CSQC_PredictSelectStrongest();
};

// --- Reload dispatcher ---

void() CSQC_PredictReload =
{
    // Reload disconnects the smoke source from the muzzle (mag is
    // out, weapon is open) — kill any pending chain so puffs stop
    // appearing at the muzzle.  Already-drifting puffs continue to
    // fade naturally; only NEW spawns are suppressed.
    CSQC_MuzzleSmokeStopChain();

    if (self.csqc_predict_reload)
        self.csqc_predict_reload();
};

// ============================================================
//  Dropped-weapon CSQC replication + pickup prediction
//
//  Server networks dropped weapons via CSQC_ENT_DROPPED_WEAPON (see
//  sv_weapons.qc dropped_weapon_SendEntity). On each predicted-player
//  pmove step we walk the list and check proximity; on overlap we
//  mirror the server's weapon_touch slot/equip logic locally so the
//  viewmodel swaps instantly at high ping. Ammo stays server-
//  authoritative for MVP — HUD may briefly read 0 until the next
//  PM_CSQC_PROXY snapshot lands. Rollback on denied pickup is handled
//  by the standard prediction-reconciliation path.
// ============================================================

// Add-with-cycle-guard: if w is somehow already in the list (either as
// head or reachable via dropped_weapon_next), skip the add.  Prevents
// the class of runaway-loop crash seen in push_trigger_list where a
// stomped-to-world .next field on a still-reachable entity got re-
// added and formed a cycle.
void(entity w) dropped_weapon_list_add_csqc =
{
    entity scan;
    float  i = 0;
    if (dropped_weapon_list == w)
        return;
    for (scan = dropped_weapon_list; scan; scan = scan.dropped_weapon_next)
    {
        if (scan == w)
            return;
        i = i + 1;
        if (i > 4096)
        {
            dprint("dropped_weapon_list_add_csqc: cycle detected during add-scan\n");
            return;
        }
    }
    w.dropped_weapon_next = dropped_weapon_list;
    dropped_weapon_list = w;
}

void(entity w) dropped_weapon_list_remove_csqc =
{
    entity prev;
    float  i;
    if (dropped_weapon_list == w)
    {
        dropped_weapon_list = w.dropped_weapon_next;
        w.dropped_weapon_next = world;
        return;
    }
    prev = dropped_weapon_list;
    i = 0;
    while (prev && prev.dropped_weapon_next != w)
    {
        prev = prev.dropped_weapon_next;
        i = i + 1;
        if (i > 4096)
        {
            dprint("dropped_weapon_list_remove_csqc: cycle detected, breaking chain\n");
            if (prev)
                prev.dropped_weapon_next = world;
            return;
        }
    }
    if (prev)
    {
        prev.dropped_weapon_next = w.dropped_weapon_next;
        w.dropped_weapon_next = world;
    }
}

vector dw_trace_hit_normal;

float(vector trace_src, vector dir_unit, float dirlen, vector mn, vector mx) CSQC_DroppedWeapon_RayAABB =
{
    float tmin = 0;
    float tmax = dirlen;
    float t1, t2, tmp;
    vector n = '0 0 0';
    vector axis_n;

    if (fabs(dir_unit_x) < 0.000001)
    {
        if (trace_src_x < mn_x || trace_src_x > mx_x) return -1;
    }
    else
    {
        t1 = (mn_x - trace_src_x) / dir_unit_x;
        t2 = (mx_x - trace_src_x) / dir_unit_x;
        axis_n = '-1 0 0';
        if (t1 > t2)
        {
            tmp = t1; t1 = t2; t2 = tmp;
            axis_n = '1 0 0';
        }
        if (t1 > tmin) { tmin = t1; n = axis_n; }
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return -1;
        if (tmax < 0) return -1;
    }

    if (fabs(dir_unit_y) < 0.000001)
    {
        if (trace_src_y < mn_y || trace_src_y > mx_y) return -1;
    }
    else
    {
        t1 = (mn_y - trace_src_y) / dir_unit_y;
        t2 = (mx_y - trace_src_y) / dir_unit_y;
        axis_n = '0 -1 0';
        if (t1 > t2)
        {
            tmp = t1; t1 = t2; t2 = tmp;
            axis_n = '0 1 0';
        }
        if (t1 > tmin) { tmin = t1; n = axis_n; }
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return -1;
        if (tmax < 0) return -1;
    }

    if (fabs(dir_unit_z) < 0.000001)
    {
        if (trace_src_z < mn_z || trace_src_z > mx_z) return -1;
    }
    else
    {
        t1 = (mn_z - trace_src_z) / dir_unit_z;
        t2 = (mx_z - trace_src_z) / dir_unit_z;
        axis_n = '0 0 -1';
        if (t1 > t2)
        {
            tmp = t1; t1 = t2; t2 = tmp;
            axis_n = '0 0 1';
        }
        if (t1 > tmin) { tmin = t1; n = axis_n; }
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return -1;
        if (tmax < 0) return -1;
    }

    if (tmin < 0.001) return -1;
    if (tmin > dirlen) return -1;

    dw_trace_hit_normal = n;
    return tmin;
};

void(vector trace_src, vector trace_end) CSQC_DroppedWeapon_OverrideTrace =
{
    // Dropped weapons replicate as oversized AABBs around the visual
    // mesh — the bbox covers everything from the tip of the barrel
    // out past the magazine, and bullets that fly clear of the model
    // were still stopping at the box.  Visible under cl_debug_impacts
    // as a green dot floating in space next to the gun, sometimes
    // with the bullet appearing to "pass through" via penetration
    // re-traces.  Default to TRANSPARENT (skip this override entirely)
    // so bullets continue to whatever's behind the weapon.  Flip the
    // cvar back to 1 if you want the AABB to block again.
    if (!cvar("cl_dropped_weapon_blocks_bullets"))
        return;

    vector dir = trace_end - trace_src;
    float dirlen = vlen(dir);
    if (dirlen < 0.001)
        return;

    vector dir_unit = dir * (1 / dirlen);
    float best_t = trace_fraction * dirlen;
    if (trace_fraction >= 1)
        best_t = dirlen;

    entity best_ent = world;
    vector best_normal = '0 0 0';
    entity w = dropped_weapon_list;
    float i = 0;

    while (w)
    {
        // Phys drops are skipped: their world-space AABB is much
        // larger than the rotated mesh silhouette, so ray-AABB
        // produced visible "sparks in mid-air" near phys-dropped
        // weapons.  CSQC predict on phys drops would need a real
        // mesh trace (not available in QC) — fall back to the
        // server's CSQC_EVENT_IMPACT multicast for that case, which
        // shows up 1 RTT late but at the correct surface point.
        if (!w.dropped_weapon_predicted_taken
            && !w.dropped_weapon_physdrop
            && w.drawmask != 0
            && w.model != "")
        {
            float t = CSQC_DroppedWeapon_RayAABB(trace_src, dir_unit, dirlen,
                                                 w.absmin, w.absmax);
            if (t >= 0 && t < best_t)
            {
                best_t = t;
                best_ent = w;
                best_normal = dw_trace_hit_normal;
            }
        }

        w = w.dropped_weapon_next;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_DroppedWeapon_OverrideTrace: cycle in dropped_weapon_list\n");
            return;
        }
    }

    if (best_ent != world)
    {
        trace_endpos = trace_src + dir_unit * best_t;
        trace_plane_normal = best_normal;
        trace_ent = best_ent;
        trace_fraction = best_t / dirlen;
    }
};

// Predraw for every dropped weapon. Two responsibilities:
//   1. Run the toss-smoothing extrap (cl_tosssmooth.qc) so the entity
//      flies smoothly between server samples instead of snapping every
//      sv_toss_tickrate tick. ODE drops use the same visual smoother,
//      fed by server ODE origin/velocity samples.
//   2. Spin yaw locally on classic-Quake-style pickups (.dropped_spin).
//      Non-spin, non-physics drops stay upright; physics drops may tumble
//      visually from the server-sent angular velocity if explicitly enabled.
// Always assigned in CSQC_DroppedWeapon_Update so the smoothing path
// is in effect for both spinning and settled drops.
// Forward decls from cl_teamtint.qc — same brightness-cap helpers used
// by the player-tint pass. The _Cached form stores the getlight() sample
// per entity (settled drops never move) so the predraw doesn't re-sample
// the lightmap every frame.
float(vector pos, float cap_byte, float knee_frac) CSQC_MaxlightScale;
float(float cap_byte, float knee_frac)             CSQC_MaxlightScale_Cached;

// Per-frame dropped-weapon state, refreshed once on the first drop of the
// frame via the inline cltime gate at the top of the predraw below. Holds
// the brightness-cap cvars (r_physdrops_maxlight / r_maxlight_softknee),
// the camera origin, and the squared cull radius. Inlining the refresh
// (rather than a helper call) avoids a QC CALL per drop; cltime is constant
// across a frame's predraws, and the polled flag forces the very first
// predraw ever to populate the globals.
float  g_physdrop_maxlight;
float  g_physdrop_knee;
float  g_physdrop_maxdist_sq;   // squared r_physdrops_maxdist; 0 = cull disabled
float  g_physdrop_pvscull;      // r_physdrops_pvscull; checkpvs() occlusion cull
vector g_physdrop_vieworg;
float  g_physdrop_poll_cltime;
float  g_physdrop_polled;

float() CSQC_DroppedWeapon_Predraw =
{
    // Refresh the per-frame globals once (first drop of the frame).
    if (!g_physdrop_polled || g_physdrop_poll_cltime != cltime)
    {
        g_physdrop_polled      = 1;
        g_physdrop_poll_cltime = cltime;
        g_physdrop_maxlight    = cvar("r_physdrops_maxlight");
        g_physdrop_knee        = cvar("r_maxlight_softknee");
        g_physdrop_vieworg     = (vector)getproperty(VF_ORIGIN);
        float md               = cvar("r_physdrops_maxdist");
        g_physdrop_maxdist_sq  = (md > 0) ? md * md : 0;
        g_physdrop_pvscull     = cvar("r_physdrops_pvscull");
    }

    // Sleeping-item fast-path. When all of:
    //   - server's last sample had ~zero linear velocity (toss_moving=0)
    //   - no smoothing decay in flight (extrap_error_cltime==0)
    //   - no angular spin to integrate (matches the gate at the
    //     angular-extrap branch below)
    //   - not a classic Quake spin pickup (which derives yaw from cltime)
    // …then CSQC_TossPredraw is provably a no-op (Toss_PredictedNow
    // returns toss_last_origin unchanged, smoothing block skipped,
    // setorigin no-op) and the angular-extrap branch is also a no-op.
    // Skipping the function call entirely saves ~5-10 QC ops per
    // sleeping item per frame — at 200+ settled drops on a busy map
    // this was the dominant CSQC self-time cluster after bullet
    // holes. Wake-up is automatic on the next CSQC_TossSampleApply
    // (server snapshot will set toss_moving / extrap_error_cltime).
    if (!self.dropped_spin
        && !self.toss_moving
        && self.extrap_error_cltime == 0
        && (self.avelocity * self.avelocity) <= 1)
    {
        // Optional distance cull (r_physdrops_maxdist; 0 = off). Settled
        // drops are PVSF_NOREMOVE, so once seen they persist map-wide and
        // their predraw + a full engine entity-copy runs every frame with
        // no engine-side cull. Beyond the radius, skip the submit entirely
        // (PREDRAW_NEXT without adding) — the renderer would cull it anyway,
        // this avoids the per-drop copy. Scoped to the settled path so a
        // moving drop's smoothing origin is never frozen.
        if (g_physdrop_maxdist_sq > 0)
        {
            vector vd = self.origin - g_physdrop_vieworg;
            if ((vd * vd) > g_physdrop_maxdist_sq)
                return PREDRAW_NEXT;
        }

        // Optional PVS occlusion cull (r_physdrops_pvscull). Catches drops
        // within the distance radius but behind walls / out of the
        // potentially-visible set. checkpvs() is fail-safe on every BSP format
        // (CoD's NULL-deref is fixed engine-side in CODBSP_ClusterPVS) — it
        // returns "visible" when PVS data is missing, so it never hides a drop
        // you can actually see. The drop is a real CSQC edict with valid
        // pvsinfo (setsize/setorigin populate it), so self can be tested
        // directly. Settled-path only, so a moving drop never freezes.
        if (g_physdrop_pvscull && !checkpvs(g_physdrop_vieworg, self))
            return PREDRAW_NEXT;

        // r_physdrops_maxlight cap — keeps a dropped weapon under a
        // bright sky-tile / lava-glow from blowing out. Cached: a settled
        // drop reuses last frame's scalar (no getlight()). Returning
        // PREDRAW_AUTOADD lets the engine add the entity itself (identical
        // CopyCSQCEdictToEntity, reads colormod live) — one fewer QC->builtin
        // call than an explicit addentity(self).
        //
        // Settle latch: the colormod persists on the edict, so once it has been
        // written for this exact (origin, cap, knee) there is nothing to do — skip
        // both the Cached call and the store. The key match is the same hit
        // condition CSQC_MaxlightScale_Cached uses internally, so a cvar change or
        // a wake-up (origin move) falls through and recomputes correctly.
        if (self.maxlight_cache_committed
            && self.maxlight_cache_cap  == g_physdrop_maxlight
            && self.maxlight_cache_knee == g_physdrop_knee)
        {
            vector cd = self.origin - self.maxlight_cache_origin;
            if ((cd * cd) < 1)
                return PREDRAW_AUTOADD;
        }
        float scale = CSQC_MaxlightScale_Cached(g_physdrop_maxlight, g_physdrop_knee);
        self.colormod = '1 1 1' * scale;
        self.maxlight_cache_committed = 1;
        return PREDRAW_AUTOADD;
    }

    CSQC_TossPredraw(self);
    if (self.dropped_spin)
        self.angles_y = cltime * 100;
    else if (self.dropped_weapon_physdrop
             && CSQC_PhysDropAngularExtrap()
             && (self.avelocity * self.avelocity) > 1)
        self.angles = self.angles + self.avelocity * frametime;
    {
        // Same brightness cap on the moving-drop path (in-flight,
        // post-bounce, ODE-driven physics drops). A moving drop changes
        // origin each frame, so _Cached misses and re-samples — correct.
        // Reuses the `scale` local from the sleeping-fast-path branch
        // above — QC has function-scope locals regardless of `{}`, so
        // re-declaring with `float` triggers Q207 ("duplicate definition
        // ignored").
        scale = CSQC_MaxlightScale_Cached(g_physdrop_maxlight, g_physdrop_knee);
        self.colormod = '1 1 1' * scale;
    }
    // PREDRAW_AUTOADD — engine auto-adds using the origin/angles/colormod
    // just set above (identical render to an explicit addentity(self)).
    return PREDRAW_AUTOADD;
};

void(float isnew) CSQC_DroppedWeapon_Update =
{
    self.dropped_weapon_id   = readbyte();
    self.dropped_weapon_slot = readbyte();
    vector new_origin;
    new_origin_x = readcoord();
    new_origin_y = readcoord();
    new_origin_z = readcoord();
    // Velocity for the toss-smoothing extrap (cl_tosssmooth.qc). Read
    // even on settled weapons (server sends 0,0,0) so the parse layout
    // stays one-shape regardless of phase.
    vector new_velocity;
    new_velocity_x = readcoord();
    new_velocity_y = readcoord();
    new_velocity_z = readcoord();
    vector new_avelocity;
    new_avelocity_x = readcoord();
    new_avelocity_y = readcoord();
    new_avelocity_z = readcoord();
    string mdl   = readstring();
    self.dropped_weapon_mag      = readbyte();
    self.dropped_weapon_ammo     = readbyte();
    self.dropped_weapon_silencer = readbyte();
    self.dropped_spin            = readbyte();
    // Server angles. Spin pickups override yaw locally; non-spin TOSS
    // pickups stay upright and physics drops use ODE-driven angles.
    vector new_angles;
    new_angles_x = readcoord();
    new_angles_y = readcoord();
    new_angles_z = readcoord();
    self.dropped_weapon_physdrop = readbyte();

    if (isnew)
    {
        self.classname = "csqc_dropped_weapon";
        self.solid     = SOLID_NOT;   // proximity-check manually, don't trigger-touch
        self.drawmask  = MASK_ENGINE;
        dropped_weapon_list_add_csqc(self);

        // Default the predict-pickup grace deadline conservatively so any
        // newly-arrived dropped weapon is gated against immediate predict-
        // pickup (which would be denied by the server's weapon_solid_time
        // and bounce back via CSQC_PickupPredict_Expire — the source of
        // the repeated pickup-sound spam during the drop grace window).
        // Phys drops in particular bypass the fake-spawn path entirely,
        // so the fake-inheritance branch below never runs for them and
        // pickup_time stayed at 0 (cltime >= 0 always).  Non-droppers
        // walking onto old weapons just get a one-time 0.5 s delay
        // before client-side predict — server-side pickup itself is
        // unaffected, so the snapshot still fills the slot promptly.
        self.dropped_weapon_pickup_time = cltime + WEAPON_DROP_PICKUP_DELAY;

        // Swap the matching fake drop (same weapon id) for this real
        // networked entity.  Without this the fake lives on its own
        // cltime-based expiry (ping + pickup grace), which at high ping
        // leaves a ~0.5s window where both visuals render simultaneously.
        // If the user already predict-picked the fake before the real
        // arrived, inherit the predicted_taken + drawmask state so the
        // pickup stays committed across the handoff.
        entity fd   = csqc_fake_drop_list;
        entity prev = world;
        float  fd_i = 0;
        while (fd)
        {
            entity nxt = fd.csqc_fake_drop_next;
            if (fd.dropped_weapon_id == self.dropped_weapon_id)
            {
                // Inherit prediction state from the fake.
                if (fd.dropped_weapon_predicted_taken)
                {
                    self.dropped_weapon_predicted_taken = 1;
                    self.drawmask = 0;
                    // Re-arm the Expire timeout on the real entity so
                    // a never-confirmed predict on the fake still times
                    // out after PICKUP_PREDICT_TIMEOUT.
                    self.think     = CSQC_PickupPredict_Expire;
                    self.nextthink = time + PICKUP_PREDICT_TIMEOUT;
                }

                // Refine the default deadline above with the fake's
                // actual deadline (slightly earlier — fake was spawned
                // at the drop instant rather than at this snapshot's
                // arrival time).  Pick the later of the two so we don't
                // shorten the grace if the fake ran out earlier than
                // the conservative default.
                if (fd.dropped_weapon_pickup_time > self.dropped_weapon_pickup_time)
                    self.dropped_weapon_pickup_time = fd.dropped_weapon_pickup_time;

                if (prev)
                    prev.csqc_fake_drop_next = nxt;
                else
                    csqc_fake_drop_list = nxt;
                dropped_weapon_list_remove_csqc(fd);
                remove(fd);
                break;
            }
            prev = fd;
            fd = nxt;
            fd_i = fd_i + 1;
            if (fd_i > 4096)
            {
                dprint("CSQC_DroppedWeapon_Update: cycle detected in csqc_fake_drop_list, breaking chain\n");
                if (prev)
                    prev.csqc_fake_drop_next = world;
                break;
            }
        }
    }

    // Single predraw covers both spin-yaw and toss-smoothing extrap.
    // Non-physics non-spin drops receive upright server angles.
    self.predraw = CSQC_DroppedWeapon_Predraw;
    if (!self.dropped_spin)
        self.angles = new_angles;
    self.avelocity = new_avelocity;

    // Always call setmodel: relying on `self.model != mdl` to skip
    // redundant calls leaves the entity with model name set but
    // modelindex=0 in some FTE QC string-compare paths, killing
    // rendering after a cvar-driven hide -> show transition.
    // A recycled CSQC slot can still carry an explicit player IQM
    // skeleton from a former player_visual_proxy. Dropped weapons never
    // need an explicit skelobject, so delete it before rebinding the
    // weapon model.
    if (self.skeletonindex)
    {
        skel_delete(self.skeletonindex);
        self.skeletonindex = 0;
    }
    setmodel(self, mdl);
    // A dropped weapon whose model string arrived but resolved to modelindex 0
    // is a pickup you can walk onto and cannot see.  The server cannot detect
    // this - its own modelindex is fine - so the check has to live here.
    if (isnew && !self.modelindex && cvar("sv_debug_pickups"))
        print(sprintf("^1[dropped-weapon]^7 %s: model \"%s\" resolved to modelindex 0 (invisible)\n",
                      Weapon_DisplayName(self.dropped_weapon_id), mdl));
    // Match the fake drop's per-weapon hitbox so the fake→real handoff
    // doesn't also change the pickup-touch radius visibly.
    vector real_mins = '0 0 0';
    vector real_maxs = '0 0 0';
    CSQC_FakeDrop_Size(self.dropped_weapon_id, real_mins, real_maxs);
    setsize(self, real_mins, real_maxs);
    // Route position through the smoothing helper instead of a bare
    // setorigin. Non-physics drops still predict MOVETYPE_TOSS. ODE drops
    // default to smoothing authoritative samples without velocity/angle
    // prediction because ODE contact jitter looks like visible wobble when
    // extrapolated on the client.
    if (self.dropped_weapon_physdrop)
    {
        float phys_extrap = CSQC_PhysDropExtrapScale();
        CSQC_TossSampleApply(self, new_origin, new_velocity * phys_extrap, phys_extrap);
    }
    else
        CSQC_TossSampleApply(self, new_origin, new_velocity, 1.0);

    // Hidden-vs-still-present dispatch:
    //   • empty model → server has hidden the pickup (post-touch on a
    //     map weapon — the entity persists via PVSF_NOREMOVE for round-
    //     reset but shouldn't be interactable until reset re-arms it
    //     with a real model). Lock it hidden locally so there's no
    //     ghost to walk over and pick up again.
    //   • real model + we'd previously predicted a pickup → contested
    //     rollback: server is still offering the weapon, meaning our
    //     prediction was denied. Un-hide so CSQC_CheckPickupTouches
    //     considers it next tick.
    //   • real model + no prediction → normal visible pickup, nothing
    //     to do here (drawmask/solid/predicted_taken already correct
    //     from the `isnew` path above).
    if (mdl == "")
    {
        // Print + sound only on the visible→hidden transition.  The
        // server's weapon_settle_think (and the per-0.2s SendFlags
        // pulses it emits while polling velocity) can cause this
        // branch to re-fire dozens of times for a single pickup;
        // dropped_weapon_logged latches at the first event so the
        // log line and local sound fire exactly once.  The latch
        // clears when the entity becomes visible again (round
        // respawn or contested rollback).
        if (!self.dropped_weapon_logged)
        {
            if (self.dropped_weapon_predicted_taken)
            {
                // Predict already played the sound locally.
                if (cvar("sv_debug_pickups"))
                    print(sprintf("^2[pickup-confirm]^7 weapon ^2%s^7 — server confirmed prediction\n",
                                  Weapon_DisplayName(self.dropped_weapon_id)));
            }
            else
            {
                // Catch-up: server took the map weapon before CSQC
                // could predict it (low-ping case).  Sound play is
                // deferred to the CSQC_EVENT_WEAPON_PICKUP_SOUND
                // handler, which gates by whether CSQC predict
                // already fired — robust against event/update
                // ordering within a single snapshot.
                if (cvar("sv_debug_pickups"))
                    print(sprintf("^3[pickup-catchup]^7 weapon ^2%s^7 — server took it, no local prediction\n",
                                  Weapon_DisplayName(self.dropped_weapon_id)));
            }
            self.dropped_weapon_logged = 1;
        }

        self.drawmask = 0;
        self.solid = SOLID_NOT;
        self.dropped_weapon_predicted_taken = 1;
        self.nextthink = 0;   // cancel any pending Expire timeout
    }
    else if (self.dropped_weapon_predicted_taken)
    {
        if (cvar("sv_debug_pickups"))
            print(sprintf("^1[pickup-rollback]^7 weapon ^2%s^7 — server denied prediction, restoring\n",
                          Weapon_DisplayName(self.dropped_weapon_id)));

        self.dropped_weapon_predicted_taken = 0;
        self.drawmask = MASK_ENGINE;
        self.solid = SOLID_NOT;   // still proximity-detected, not trigger-touched
        self.nextthink = 0;   // cancel any pending Expire timeout
        // Re-arm the log latch: if this weapon gets taken again we
        // want the confirm/catchup line to fire once more.
        self.dropped_weapon_logged = 0;
    }
    else if (mdl != "" && self.dropped_weapon_logged)
    {
        // Round-respawn path: entity reappears with a real model
        // after being hidden (mp_nomapweapons toggle off, or any
        // map-weapon respawn after a hide).  Restore drawmask +
        // clear predicted_taken so the entity renders again — the
        // sibling predicted_taken branch above handles the same
        // restore for the rollback case, but it doesn't fire here
        // when predicted_taken got cleared by an earlier Expire
        // timeout or by the round restart sequencing.  Without
        // this restore the model is set on the entity but
        // drawmask stayed at 0 from the prior mdl=="" branch, so
        // the engine never renders it (the source of "weapons
        // respawned server-side but invisible client-side" after
        // mp_nomapweapons 1 -> 0).
        self.dropped_weapon_logged = 0;
        self.dropped_weapon_predicted_taken = 0;
        self.drawmask = MASK_ENGINE;
        self.solid = SOLID_NOT;
        self.nextthink = 0;
    }
}

// Dispatches by weapon id to apply the dropped weapon's mag/ammo/silencer
// to the predicted player. Mirrors server's W_*PickupCopy functions and
// the SendEntity dispatch table in sv_weapons.qc dropped_weapon_SendEntity.
// If any entry here drifts from the server, client shows wrong ammo until
// the next PM_CSQC_PROXY snapshot corrects it — same self-healing path as
// every other mispredict.
void(float wep, float mag, float ammo, float silencer) CSQC_ApplyPickupAmmo =
{
    if (W_SlotAmmo_UsesSlot(wep))
    {
        W_SlotAmmo_SetForWeapon(self, wep, mag, ammo, silencer);
        W_SlotAmmo_LoadLegacy(self, wep);
    }
    else if (wep == WEP_HLGRENADE)       {                                 self.ammo_hlgrenade = ammo;       }
    else if (wep == WEP_SATCHEL)         {                                 self.ammo_satchel = ammo;         }
    else if (wep == WEP_TRIPMINE)        {                                 self.ammo_tripmine = ammo;        }
    else if (wep == WEP_SNARK)           {                                 self.ammo_snark = ammo;           }
    else if (wep == WEP_SNOWBALL)        {                                 self.ammo_snowball = ammo;        }
    else if (wep == WEP_CSHEGRENADE)     {                                 self.ammo_cshegrenade = ammo;     }
    else if (wep == WEP_CSFLASHBANG)     {                                 self.ammo_csflashbang = ammo;     }
    else if (wep == WEP_CSSMOKEGRENADE)  {                                 self.ammo_cssmokegrenade = ammo;  }
    else if (wep == WEP_DODMILLS)        {                                 self.ammo_dodmills = ammo;        }
    else if (wep == WEP_DODSTICK)        {                                 self.ammo_dodstick = ammo;        }
    else if (wep == WEP_SLINGSHOT)       {                                 self.snowball_has_slingshot = TRUE; }
    // Melee (WRENCH/KNIFE/HLCROWBAR) — no ammo fields.
    //
    // ONLY UTILITY WEAPONS BELONG BELOW THE SLOT BRANCH.  W_SlotAmmo_UsesSlot()
    // is TRUE for every PRIMARY and SECONDARY weapon, so the first branch always
    // wins for them and any `else if (wep == <slot weapon>)` here is unreachable.
    // Twelve such rows were removed (hornetgun, shock rifle, displacer, jetpack,
    // paintball and all eight They Hunger guns) — they read as wiring while doing
    // nothing, which is exactly how the missing W_SlotAmmo_{Load,Save}Legacy rows
    // for the first four stayed invisible.  To give a slot weapon its ammo, add a
    // row to that bridge in shared/sh_weapon_slotammo.qc, not here.
}

// Safety net: if a predicted pickup never gets a confirm nor a rollback
// signal from the server within this window, restore the weapon locally.
// Covers the silent-deny case where the server rejects the touch (slot
// full server-side, or any mispredict where the server's inventory view
// differs from ours) and sends nothing in response — no SendEntity
// update, no remove().  2.0 s comfortably exceeds sv_minping 999 + a few
// ticks of processing.  (Const defined up top in the forward block.)

void() CSQC_PickupPredict_Expire =
{
    if (!self.dropped_weapon_predicted_taken) return;

    if (cvar("sv_debug_pickups"))
        print(sprintf("^1[pickup-rollback]^7 weapon ^2%s^7 unconfirmed after %gs — restoring\n",
                      Weapon_DisplayName(self.dropped_weapon_id), PICKUP_PREDICT_TIMEOUT));

    self.dropped_weapon_predicted_taken = 0;
    self.drawmask = MASK_ENGINE;
    self.solid    = SOLID_NOT;

    // Back off the predict-pickup gate so we don't immediately try again
    // and produce a tight expire→predict→expire loop (and the
    // accompanying repeated localsound) when the server can't actually
    // pick up — e.g. dropper hovering just outside the server's AABB
    // pickup pad while CSQC's looser 40-unit sphere still matches.  A
    // full PICKUP_PREDICT_TIMEOUT back-off means the next predict can
    // only fire after the next snapshot has had time to confirm or
    // refute the previous attempt.
    self.dropped_weapon_pickup_time = cltime + PICKUP_PREDICT_TIMEOUT;
};

// Walk the dropped-weapon list asking "is there a still-pending predicted
// pickup occupying this slot?".  Needed because predicted_player.slot_*
// gets wiped on every CSQC_ResetToConfirmedMoveState — the gate inside
// CSQC_PredictPickupWeapon can't rely on self.slot_* to answer "is this
// slot already claimed by something I've predicted".
//
// Important: dropped_weapon_predicted_taken is overloaded — it also
// acts as a "server-hidden lock" flag set by the mdl=="" branch of
// CSQC_DroppedWeapon_Update (e.g. map weapons someone else picked up
// in a prior round).  We distinguish "genuine pending local predict"
// by the Expire timeout: only actual predictions arm nextthink, and the
// confirm / rollback branches clear it back to 0.
// A COUNT of in-flight predicted pickups for this slot, not a boolean.
//
// It had to stop being a boolean once a slot can hold more than one weapon: with
// mp_maxprimary 2 and one primary already held, a single pending pickup is fine
// and the old "any pending -> refuse" test would have blocked the legitimate
// second one for a whole round-trip.
float(float slot) CSQC_SlotPredictedCount =
{
    entity w = dropped_weapon_list;
    float  i = 0, n = 0;
    while (w)
    {
        if (w.dropped_weapon_predicted_taken
            && w.nextthink > time
            && w.dropped_weapon_slot == slot)
            n = n + 1;
        w = w.dropped_weapon_next;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_SlotPredictedCount: cycle in dropped_weapon_list\n");
            return n;
        }
    }
    return n;
};

float(float slot) CSQC_IsSlotPredictedFilled =
{
    return CSQC_SlotPredictedCount(slot) > 0;
};

float(float wep) CSQC_IsUtilityPredictedFilled =
{
    entity w = dropped_weapon_list;
    float  i = 0;
    while (w)
    {
        if (w.dropped_weapon_predicted_taken
            && w.nextthink > time
            && w.dropped_weapon_slot == SLOT_UTILITY
            && w.dropped_weapon_id == wep)
            return TRUE;
        w = w.dropped_weapon_next;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_IsUtilityPredictedFilled: cycle in dropped_weapon_list\n");
            return FALSE;
        }
    }
    return FALSE;
};

// Mirrors sv_weapons.qc weapon_touch (lines 888-977) — slot occupancy,
// slot assignment, auto-equip, ammo copy.
void(entity w) CSQC_PredictPickupWeapon =
{
    float slot = w.dropped_weapon_slot;
    float wep  = w.dropped_weapon_id;

    // Slot occupancy — check BOTH the ack'd state (wiped on reconcile)
    // AND any pending local prediction for the same slot.  Without the
    // second check, at high ping the reconcile clears self.slot_primary
    // each snapshot and the next frame's touch scan predicts picking up
    // the next weapon in range, cascading until the player "eats" every
    // weapon they walked over in the RTT window.
    //
    // SLOT_MELEE special case: WEP_MELEE (fists) is INTRINSIC and acts
    // as an empty melee slot for pickup purposes — mirrors the server
    // check in weapon_touch (sv_weapons.qc).  Without this the client
    // predict would refuse to take a real melee weapon while holding
    // fists and the player would see no preview pickup at all.
    float melee_held = self.slot_melee && self.slot_melee != WEP_MELEE;
    // Mirrors weapon_touch's gate: already-held, or the slot is at its limit once
    // in-flight predicted pickups are counted.  This is the ONE place a stale
    // mp_max* serverinfo can bite, and the damage is bounded — a mispredicted
    // pickup, corrected on the next snapshot.  Cycling never reads the limit.
    if (slot == SLOT_PRIMARY || slot == SLOT_SECONDARY)
    {
        if (W_CarryIndexOf(self, slot, wep) >= 0) return;
        if (W_CarryCount(self, slot) + CSQC_SlotPredictedCount(slot)
            >= W_CarryLimit(slot)) return;
    }
    if (slot == SLOT_MELEE     && (melee_held          || CSQC_IsSlotPredictedFilled(SLOT_MELEE)))     return;
    if (slot == SLOT_UTILITY)
    {
        if (!W_UtilityWeaponPickup(wep)) return;
        if (wep == WEP_SLINGSHOT && self.snowball_has_slingshot) return;
        if (W_UtilityPlayerHasWeapon(wep) || CSQC_IsUtilityPredictedFilled(wep)) return;
    }

    // Copy ammo BEFORE equip so the equip path sees correct mag/reserve
    // for HUD redraw (matches server where pickupcopy precedes
    // W_SelectWeapon in weapon_touch, lines 906-957).
    CSQC_ApplyPickupAmmo(wep, w.dropped_weapon_mag, w.dropped_weapon_ammo,
                         w.dropped_weapon_silencer);

    // Assign slot. CSQC dispatches equip by weapon id (CSQC_WeaponEquip),
    // so we don't need function pointers like the server does.
         if (slot == SLOT_PRIMARY)   { W_CarryAdd(self, SLOT_PRIMARY, wep);   self.slot_primary   = wep; }
    else if (slot == SLOT_SECONDARY) { W_CarryAdd(self, SLOT_SECONDARY, wep); self.slot_secondary = wep; }
    else if (slot == SLOT_MELEE)     self.slot_melee     = wep;
    else if (slot == SLOT_UTILITY && wep != WEP_SLINGSHOT)
    {
        if (!W_UtilityPlayerHasWeapon(self.slot_utility))
            self.slot_utility = wep;
    }

    // Auto-equip — exact mirror of server lines 942-957
    float should_equip = FALSE;
    if (self.weapon == WEP_NONE && wep != WEP_SLINGSHOT)   should_equip = TRUE;
    else if (slot == SLOT_PRIMARY)                         should_equip = TRUE;
    else if (slot == SLOT_SECONDARY && !self.slot_primary) should_equip = TRUE;

    if (should_equip)
        CSQC_PredictSelectWeapon(wep);

    // Hide locally + flag so CheckPickupTouches skips, and so a re-
    // affirmed server send (in CSQC_DroppedWeapon_Update above) can
    // restore the weapon if the pickup was denied.
    w.drawmask = 0;
    w.dropped_weapon_predicted_taken = 1;

    // Timeout safety net — mirror of breakables' CSQC_BreakPredict_Expire
    // pattern.  If neither confirm (empty-model snapshot or ent-remove)
    // nor rollback (re-sent with real model) arrives within the timeout,
    // assume the server silently denied and restore the weapon.
    w.think     = CSQC_PickupPredict_Expire;
    w.nextthink = time + PICKUP_PREDICT_TIMEOUT;

    if (cvar("sv_debug_pickups"))
        print(sprintf("^5[pickup-predict]^7 weapon ^2%s^7 slot=%g wep_id=%g (entnum=%g)\n",
                      Weapon_DisplayName(wep), slot, wep, num_for_edict(w)));

    if (!pm_suppress_sounds)
    {
        localsound("sounds/weapons/pickup1.wav");
        // Latch so the server's pickup-sound event, when it arrives
        // ~1 RTT later, knows we already played locally and skips.
        // Use cltime (monotonic wall clock) so the gate reflects real
        // elapsed seconds regardless of snapshot arrival jitter.
        cl_local_predict_sound_time = cltime;
    }
}

// Called once per predicted pmove step (from cl_player.qc just after
// PM_PlayerMove, with self = predicted_player). Cheap O(N) scan over
// the small dropped-weapon list.
void() CSQC_CheckPickupTouches =
{
    // Skip entirely while the local player is in team-select — predicted_player
    // is seeded from the camera-placed engine player, and if any dropped_weapon
    // happens to sit within 40 units of a camera OR the predicted_player is
    // uninitialised at origin (0,0,0), CSQC will locally predict a pickup that
    // the server never confirms.  The shooter then sees a phantom weapon they
    // can "fire" via CSQC prediction while the server still has slot_primary=0.
    if (getstati(STAT_PLAYERTEAM) <= TEAM_NONE)
        return;

    // Same rationale for the dying state — server's weapon_touch
    // rejects pickups when is_dead=TRUE (sv_weapons.qc:1708), so any
    // CSQC predict during the death animation is doomed to be rolled
    // back by CSQC_PickupPredict_Expire 2 s later, then re-fired,
    // producing the audible pickup-sound spam if a dropped weapon
    // lands on the dying player.
    if (getstatf(STAT_IS_DEAD))
        return;

    // Player bbox in absolute coords. self == predicted_player here so
    // mins/maxs were setsize'd to player dimensions during pmove init.
    vector pmins = self.origin + self.mins;
    vector pmaxs = self.origin + self.maxs;

    entity w = dropped_weapon_list;
    float  i = 0;
    while (w)
    {
        entity next_w = w.dropped_weapon_next;   // safe against list unlink
        if (!w.dropped_weapon_predicted_taken
            && cltime >= w.dropped_weapon_pickup_time)
        {
            // Pickup-zone overlap test — exact mirror of server
            // W_PhysDropPlayerClose so client predict and server +use
            // agree on whether the player is "in the zone". Old code
            // was a single vlen<40 sphere which let the client predict
            // pickups the server then refused (or refuse pickups the
            // server granted) on long/short weapons.
            vector zmins = w.origin + [-(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                       -(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                       -(WEAPON_PICKUP_HEIGHT_DN + WEAPON_PICKUP_PAD)];
            vector zmaxs = w.origin + [ (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                        (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                        (WEAPON_PICKUP_HEIGHT_UP + WEAPON_PICKUP_PAD)];

            if (pmaxs_x >= zmins_x && pmins_x <= zmaxs_x
             && pmaxs_y >= zmins_y && pmins_y <= zmaxs_y
             && pmaxs_z >= zmins_z && pmins_z <= zmaxs_z)
                CSQC_PredictPickupWeapon(w);
        }
        w = next_w;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_CheckPickupTouches: cycle in dropped_weapon_list\n");
            return;
        }
    }
}

// Debug-draw the WEAPON_PICKUP_* zone cube around every pickable
// dropped weapon (real network entities + locally-spawned fakes).
// Cube matches what server W_PhysDropPlayerClose AND CSQC predict
// touch tests, so anything green here is what +use considers in
// range — independent of the entity's setsize physics body that
// r_showbboxes shows. Gated on cl_debug_pickupzone.
void() CSQC_DrawDebugPickupZones =
{
    if (!cvar("cl_debug_pickupzone"))
        return;

    vector col_active = '0.2 1 0.2';   // green — pickable
    vector col_locked = '1 0.5 0.2';   // orange — predicted/grace-locked
    float  alpha      = 0.55;

    entity w;
    float i;

    // Real network drops first, then locally-spawned fakes.
    w = dropped_weapon_list;
    i = 0;
    while (w)
    {
        entity nxt = w.dropped_weapon_next;
        i = i + 1;
        if (i > 4096) break;

        vector col = col_active;
        if (w.dropped_weapon_predicted_taken
         || cltime < w.dropped_weapon_pickup_time)
            col = col_locked;

        vector zmins = w.origin + [-(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                   -(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                   -(WEAPON_PICKUP_HEIGHT_DN + WEAPON_PICKUP_PAD)];
        vector zmaxs = w.origin + [ (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                    (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                    (WEAPON_PICKUP_HEIGHT_UP + WEAPON_PICKUP_PAD)];

        // 12 cube edges via dbg_hitbox_line (already used by hitbox + phys-prop debug).
        vector v000 = [zmins_x, zmins_y, zmins_z];
        vector v100 = [zmaxs_x, zmins_y, zmins_z];
        vector v010 = [zmins_x, zmaxs_y, zmins_z];
        vector v110 = [zmaxs_x, zmaxs_y, zmins_z];
        vector v001 = [zmins_x, zmins_y, zmaxs_z];
        vector v101 = [zmaxs_x, zmins_y, zmaxs_z];
        vector v011 = [zmins_x, zmaxs_y, zmaxs_z];
        vector v111 = [zmaxs_x, zmaxs_y, zmaxs_z];

        dbg_hitbox_line(v000, v100, col, alpha);
        dbg_hitbox_line(v100, v110, col, alpha);
        dbg_hitbox_line(v110, v010, col, alpha);
        dbg_hitbox_line(v010, v000, col, alpha);
        dbg_hitbox_line(v001, v101, col, alpha);
        dbg_hitbox_line(v101, v111, col, alpha);
        dbg_hitbox_line(v111, v011, col, alpha);
        dbg_hitbox_line(v011, v001, col, alpha);
        dbg_hitbox_line(v000, v001, col, alpha);
        dbg_hitbox_line(v100, v101, col, alpha);
        dbg_hitbox_line(v110, v111, col, alpha);
        dbg_hitbox_line(v010, v011, col, alpha);

        w = nxt;
    }
};

// --- Impulse handling ---

void() CSQC_PredictWeaponImpulse =
{
    if (!input_impulse)
        return;

    switch (input_impulse)
    {
    // Byte-for-byte the same decision the server makes in W_CheckImpulses, via
    // the same shared W_SlotPressTarget.  It deliberately never reads the carry
    // LIMIT, so a stale mp_max* serverinfo can mispredict a pickup but can never
    // make a keypress select a different weapon here than it does there.
    case WEAPON_IMPULSE_PRIMARY:
        CSQC_PredictSelectWeapon(W_SlotPressTarget(self, SLOT_PRIMARY));
        break;
    case WEAPON_IMPULSE_SECONDARY:
        CSQC_PredictSelectWeapon(W_SlotPressTarget(self, SLOT_SECONDARY));
        break;
    case WEAPON_IMPULSE_MELEE:
        if (self.slot_melee)
            CSQC_PredictSelectWeapon(self.slot_melee);
        break;
    case 4:
    {
        float utility_wep = W_UtilityNextCarried(self.weapon);
        if (utility_wep)
            CSQC_PredictSelectWeapon(utility_wep);
        break;
    }
    case WEAPON_IMPULSE_DROP:
        CSQC_PredictDropWeapon();
        break;
    case USE_IMPULSE:
        if (!pm_suppress_sounds)
            CSQC_PredictUse();
        break;
    case WEAPON_IMPULSE_RELOAD:
        // Prop Hunt: for a disguised hider the reload key is the rotation-lock
        // toggle (server-side, W_CheckImpulses) — nothing to predict.
        if (!CSQC_PropHunt_LocalDisguised())
            CSQC_PredictReload();
        break;
    case WEAPON_IMPULSE_SPECIAL:
        // Tactical shield: refused outright, mirroring W_CheckImpulses.  Not a
        // balance call — no shield model has a pose for it.  The USP's silencer
        // toggle asked for sequence 7 and 15 against a 9-entry table, so it
        // played `shield_up` and then an out-of-range index, which is why
        // `impulse 7` looked like the only working way to raise the shield.
        if (self.has_shield)
            break;
        if (self.weapon == WEP_SNOWBALL)
            CSQC_PredictSnowballSpecial();
        else if (self.weapon == WEP_BUTTERFLY)
            CSQC_PredictButterflySpecial();
        else if (self.weapon == WEP_MELEE)
            CSQC_PredictMeleeSpecial();
        else if (self.weapon == WEP_M4A1)
            CSQC_PredictM4A1Special();
        else if (self.weapon == WEP_CSUSP)
            CSQC_PredictCSUSPSpecial();
        else if (self.weapon == WEP_CFMK23)
            CSQC_PredictCFMk23Special();
        else if (self.weapon == WEP_DODK43)
            CSQC_PredictDodK43Special();
        // THE THREE BAYONET RIFLES.  Every one of them binds .special on the
        // server and none of them was on this list, so impulse 7 reached the
        // server, the stab landed, the sound played — and the viewmodel never
        // moved, because a weaponstate the SERVER alone sets never reaches
        // predicted_player (reconcile does not write fire-decision state back,
        // cl_player.qc:1022) and each weapon's WS_SPECIAL display arm therefore
        // could not fire.  Reported as "only makes sound when you do the melee,
        // no visuals" on the two Kar98ks, and as the Enfield having no bayonet
        // at all.  sh_wpn_dodk43.qc:505 already carried the warning.
        else if (self.weapon == WEP_DODENFIELD)
            CSQC_PredictDodEnfSpecial();
        else if (self.weapon == WEP_DOD98K)
            CSQC_Predict98KSpecial();
        else if (self.weapon == WEP_DODSCOPED98K)
            CSQC_PredictDodS98KSpecial();
        // The Garand's rifle butt, moved off +attack2 for the same reason the
        // K43's was: the rifle declares an ADS profile, and a smash bound to
        // .altfire meant the two fought over one button — every sight picture
        // also swung the stock, and every swing also pulled the view in.
        else if (self.weapon == WEP_DODGARAND)
            CSQC_PredictDodGarandSpecial();
        // The Bren / FG42 / scoped FG42 bipod.  On weapon-special rather than
        // +attack2 because all three already use that button — the first two for
        // the ADS hold, the scoped FG42 for its scope, which under sv_codscopes
        // (shipped as 1) is owned outright by the CoD scope state machine.
        else if (self.weapon == WEP_DODBREN || self.weapon == WEP_DODFG42
                 || self.weapon == WEP_DODFG42S)
            CSQC_PredictDodAutoSpecial();
        // THE OTHER FIVE DEPLOYABLES.  The three machine guns, the BAR and the
        // mortar plant on +attack2 and bound no .special at all, so weapon-special
        // did nothing on them while it was the ONLY way to plant the three above —
        // "none of the machine guns up_to_down work? I try weapon special and
        // nothing?".  Both buttons now work on all six; the impulse path re-arms
        // the button edge latch first (SH_StanceAltArmForImpulse).
        else if (self.weapon == WEP_DOD30CAL || self.weapon == WEP_DODMG34
                 || self.weapon == WEP_DODMG42)
            CSQC_PredictDodMGSpecial();
        else if (self.weapon == WEP_DODBAR)
            CSQC_PredictDodBarSpecial();
        else if (self.weapon == WEP_DODMORTAR)
            CSQC_PredictDodMortarSpecial();
        // WEP_GRAVITYGUN is DELIBERATELY absent and was re-checked here.  Its
        // .special is W_GravGun_ToggleShift, which flips .gravshift_toggle and
        // nothing else — no weaponstate, so there is no viewmodel take to miss.
        // Everything the flag drives lives in GravShift_UpdateActivation, which is
        // #ifdef SSQC and owns a SERVER-GLOBAL direction latch (gravshift_owner /
        // gravshift_world_dir, republished as the "gravdir" serverinfo key); a
        // client copy of the bit alone would change nothing the client renders.
        // One snapshot late, not broken.
        // The jetpack's boost level.  It is NOT on the prediction proxy and the
        // client's own pmove reads it through SH_JetTickGravity, so an unpredicted
        // cycle left the client flying at the boost it drew with while the server
        // used the new one — the centreprint said 7 and you flew like a 3.
        else if (self.weapon == WEP_JETPACK)
            CSQC_PredictJetSpecial();
        break;
    case WEAPON_IMPULSE_C4:
        // Dedicated C4 select — gated on having a charge.  Skips the
        // utility cycle entirely.
        if (self.ammo_cfc4 > 0)
            CSQC_PredictSelectWeapon(WEP_CFC4);
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
    case 10:  // noclip toggle — predict instantly
        if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
            self.pm_movetype = PM_MOVETYPE_NORMAL;
        else
            self.pm_movetype = PM_MOVETYPE_NOCLIP;
        break;
    case WEAPON_IMPULSE_GRAPPLE:
        // Local toggle that mirrors W_GrappleImpulse's server-side
        // press-to-fire / press-to-release semantics.  Without this,
        // grapple_rope_active only flips on CSQC when the prediction
        // proxy delivers the server's update — RTT/2 + 1 snapshot
        // interval of "gun visible, fire allowed" while the server
        // already entered grapple state.  At 30 ms ping with 50 ms
        // snapshot interval that's 0-1 phantom shots per grapple-press
        // for sustained-fire weapons.  Mirroring the toggle locally
        // closes the window.  The server's authoritative reconcile
        // wins if the press is rejected (e.g. sv_grappling == 0).
        if (PM_ReadMovevar("sv_grappling", 0))
            self.grapple_rope_active = !self.grapple_rope_active;
        break;
    case WEAPON_IMPULSE_GRAPPLE_RELEASE:
        // CSQC mirror for the -grapple alias.  Force-clears the rope
        // flag locally so the rope disappears the instant the key is
        // released, without waiting for the next server snapshot.
        // Same RTT/2 reasoning as the engage mirror above.
        if (PM_ReadMovevar("sv_grappling", 0))
            self.grapple_rope_active = 0;
        break;
    case WEAPON_IMPULSE_FLASHLIGHT:
        CSQC_Flashlight_Toggle();
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

// ----------------------------------------------------------------
//  CSQC mirror of W_GrappleHeldTick — predicts the engage/release
//  edge of PM_BTN_GRAPPLE locally so the rope shows / hides without
//  the RTT/2 latency of waiting for the next server snapshot.
//
//  CSQC cannot spawn the hook entity (server-only); it only flips
//  the rope-render flag.  The server's authoritative grapple_hook
//  state then comes through the prediction proxy and either
//  confirms the predicted flip or corrects it.  Mirrors the SSQC
//  W_GrappleHeldTick logic exactly (rising edge → engage, falling
//  edge → release) so replay produces matching state.
// ----------------------------------------------------------------
void() CSQC_PredictGrappleHeldEdge =
{
    if (PM_ReadMovevar("sv_grappling", 0) <= 0)
    {
        self.pm_grapple_held_last = 0;
        return;
    }
    if (getstatf(STAT_IS_DEAD))
    {
        self.pm_grapple_held_last = 0;
        return;
    }

    float held     = (input_buttons & PM_BTN_GRAPPLE) ? 1 : 0;
    float was_held = self.pm_grapple_held_last;

    if (held && !was_held && !self.grapple_rope_active)
    {
        // Rising edge — engage prediction.  Mirrors the same
        // grapple_rope_active = 1 stamp that SSQC W_GrappleEngage
        // does.  Anchor stays whatever it was (likely 0 0 0) until
        // the next server snapshot delivers the real hook position;
        // cl_rope.qc handles the zero-anchor case as "rope not yet
        // visible" until the SSQC PullTick arrives.
        self.grapple_rope_active = 1;
    }
    else if (!held && was_held && self.grapple_rope_active)
    {
        // Falling edge — release prediction.
        self.grapple_rope_active = 0;
    }

    self.pm_grapple_held_last = held;
};

// SILENCE THE LOCALLY-PREDICTED WEAPON AUDIO WHEN THE LOCAL PLAYER DIES.
//
// The server already plays a null.wav on the victim's CHAN_WEAPON when it kills
// them (sv_weapons.qc, PlayerKilled), and for every OTHER client that is both
// correct and sufficient.  It can never work for the dying player themselves,
// because the loop THEY hear was not played by the server at all:
//
//   * the gauss charge and the egon windup/run are played by CSQC prediction,
//     with self == predicted_player (a CSQC-local spawn(), cl_player.qc);
//   * CSQC's sound() is PF_cs_sound, which mixes on the NEGATED entity number —
//     `S_StartSound(-entity->entnum, ...)` (fteqw/engine/client/pr_csqc.c:4756);
//   * a server sound arrives on the POSITIVE entnum (cl_parse.c);
//   * the mixer matches a stop on entnum + entchannel (snd_dma.c), and -N and +N
//     are disjoint keys.
//
// On top of that the server's own copy of the charge is deliberately suppressed
// on the shooter's machine by the predicted-echo dedup in cl_main.qc, so the
// dying player has exactly ONE copy of the loop, it is on -predicted_player.entnum,
// and nothing in the mod ever addressed that key.  Result: you die mid-charge and
// the gauss keeps winding in your ears until you respawn.
//
// stopsound() is PF_stopsound -> S_StopSound(-entity->entnum, channel), i.e. the
// SAME key CSQC's sound() writes, and channel 0 is a WILDCARD that clears every
// channel on that entnum.  So one call covers every predicted weapon sound with
// no per-weapon list, including weapons added later.
//
// Safe as a wildcard: nothing else attaches sound to predicted_player.  Pmove
// footsteps and slides use localsound() (entnum 0), the CS-grenade ring uses its
// own entity, and the fake RPG rocket uses its own entity.
//
// NOT DONE HERE, deliberately: zeroing the predicted-echo timestamps.  That
// window exists to swallow the server echo of your own last predicted shot,
// which arrives ~1 RTT after prediction played it — and dying immediately after
// firing is the common case, so clearing it would make you hear your own last
// shot twice on every death.  CSQC_ResetPredictionState already declines to
// clear those globals on death for the same reason.
//
// Known remaining gap, out of scope here: the same loop also survives an
// ordinary weapon SWITCH or DROP, because CSQC_WeaponEquip clears
// .csqc_predict_cmd and the egon's own stop branch is what would have cut it.
// The proper fix is a .csqc_weapon_holster hook invoked on the OUTGOING weapon
// from CSQC_WeaponEquip — HL calls Holster() from the switch site, not only from
// Killed().  That is a separate change; this one is the reported bug.
float csqc_weapon_audio_was_dead;

void() CSQC_SilenceLocalWeaponAudioOnDeath =
{
    float is_dead = getstatf(STAT_IS_DEAD);
    if (is_dead && !csqc_weapon_audio_was_dead && predicted_player)
    {
        stopsound(predicted_player, 0);
        // Clear the state that would otherwise re-issue the loop the moment the
        // predictor runs again.
        predicted_player.weaponstate = WS_IDLE;
    }
    csqc_weapon_audio_was_dead = is_dead;
};

// Headless-visible trace of the client's weapon state.  cl_debug_weapon has
// only ever been a DRAWN panel, which no automated run can see — and "the
// server reloaded but the gun never animated" is exactly the class of bug those
// runs exist to catch (sh_wpn_hlrpg.qc:205 documents one that shipped).
//
// IT LIVES IN THE PREDICTION PATH, NOT THE DISPLAY PATH, and that is the whole
// point of it: CSQC_GetWeaponDisplayFrame is only reached from
// CSQC_AddPredictedViewmodel, i.e. from the render, and under
// `vid_renderer headless` that never runs — a trace placed there produced zero
// lines on a run that was working perfectly.  CSQC_PredictWeaponCommand runs
// every prediction tick whether or not anything is being drawn.
//
// .weaponframe is the sequence the SERVER stamped, so a line here shows the
// authoritative animation as well as the state that chooses the viewmodel's.
// Prints on a weapon or state CHANGE only, so a held pose costs one line.
float csqc_wepdbg_wep;
float csqc_wepdbg_state;
float csqc_wepdbg_armed;
float csqc_wepdbg_deadstat;

void() CSQC_PredictWeaponCommand =
{
    // Runs on both sides of the branch so the latch stays cleared while alive —
    // otherwise the edge only fires once per map.
    CSQC_SilenceLocalWeaponAudioOnDeath();

    // ABOVE the death gate on purpose.  Below it, a headless harness client that
    // never clears STAT_IS_DEAD produces exactly one line and then silence, which
    // reads as "the weapon state never changed" when the truth is "this function
    // stopped running" — two very different diagnoses.  `dead` is in the line so
    // the log says which.
    float wepdbg_dead = getstatf(STAT_IS_DEAD);
    if (cvar("cl_debug_weapon") && predicted_player
        && (!csqc_wepdbg_armed
            || predicted_player.weapon      != csqc_wepdbg_wep
            || predicted_player.weaponstate != csqc_wepdbg_state
            || wepdbg_dead                  != csqc_wepdbg_deadstat))
    {
        csqc_wepdbg_armed    = TRUE;
        csqc_wepdbg_wep      = predicted_player.weapon;
        csqc_wepdbg_state    = predicted_player.weaponstate;
        csqc_wepdbg_deadstat = wepdbg_dead;
        print(sprintf("[wepdbg] t=%.2f wep=%g state=%g svframe=%g dead=%g mag=%g\n",
                      cltime, csqc_wepdbg_wep, csqc_wepdbg_state,
                      predicted_player.weaponframe, wepdbg_dead,
                      predicted_player.slot_primary_mag));
    }

    if (wepdbg_dead)
        return;

    W_SlotAmmo_LoadCurrent(self);
    CSQC_PredictWeaponImpulse();
    CSQC_PredictGrappleHeldEdge();

    // Bias input_angles by the cached scope sway delta so the
    // predicted trace (the per-weapon csqc_predict_cmd → makevectors
    // path used by every PredictedHitscanImpact / PenetratingImpact /
    // ShotgunImpact helper) traces from the same direction the
    // swayed camera renders.  Mirrors the view-kick bias pattern in
    // sh_weapon_logic.qc.  Restore around the dispatch so the next
    // tick's input doesn't accumulate.  Sway is zero for unscoped
    // weapons / sv_snipersway off, so the save/restore is a free
    // no-op in the common case.
    vector saved_input_angles = input_angles;
    input_angles_x += csqc_codscope_sway_pitch;
    input_angles_y += csqc_codscope_sway_yaw;

    // Tactical shield: take the attack buttons away from the weapon before it
    // ever sees them, which is what the server does at the equivalent point
    // (sv_weapons.qc, `shield_took_alt`).  Masking here rather than adding a
    // test to each weapon is the whole point — there are three bespoke
    // try-fires among the shield-legal weapons alone (knife, the three
    // grenades, the USP), and SH_ShieldBlocksFire only reaches the ones that go
    // through SH_StandardTryFire.  Missing that is why the shield could be
    // raised and still slash, and why +attack2 aimed down sights in first
    // person while the server was raising the shield in third.
    //
    // input_buttons is the client's own copy for prediction — the usercmd has
    // already gone to the server, which applies its own identical gate.  This
    // makes the two agree; it does not hide input from the server.
    // DO NOT WRITE THIS WITH `&~=`.  fteqcc64 as shipped in this tree miscompiles
    // that operator: `input_buttons &~= 4` leaves input_buttons EQUAL TO 4 rather
    // than clearing bit 2, and it does so silently — no warning, no error.
    // Measured with cl_debug_shield (see the harness at /c/tmp/shieldtest.sh):
    //     raw=1 (+attack)  shield down -> masked=4   the weapon saw ALT-FIRE
    //     raw=4 (+attack2) shield down -> masked=4   not masked at all
    //     raw=1 (+attack)  shield UP   -> masked=1   fired through a raised shield
    // which is exactly the reported "cannot fire any weapon with the shield, and
    // the Glock burst-fires on +attack2".  Use the subtract idiom, which this tree
    // already relies on in CSQC_SetLiveButton (client/cl_player.qc).
    float saved_input_buttons = input_buttons;
    if (self.has_shield)
    {
        // +attack2 belongs to the shield
        input_buttons = input_buttons - (input_buttons & 4);
        if (self.shield_deployed)
            input_buttons = input_buttons - (input_buttons & 1);   // raised: no trigger
    }

    // cl_debug_shield — the client half of the shield trace; see the matching
    // block in server/sv_weapons.qc (sv_debug_shield) for why both exist.  Edge
    // triggered on the same four inputs, and it prints BOTH button globals,
    // because they are separate paths and the ADS envelope reads the other one.
    if (cvar("cl_debug_shield"))
    {
        float sdbg = (self.has_shield ? 1 : 0) | (self.shield_deployed ? 2 : 0)
                   | (saved_input_buttons & 1 ? 4 : 0) | (saved_input_buttons & 4 ? 8 : 0);
        if (sdbg != self.shield_dbg_last)
        {
            self.shield_dbg_last = sdbg;
            // Split in two: fteqcc warns past 8 varargs, and the tree builds clean.
            print(sprintf("[shield-cl] t=%.2f has=%g dep=%g raw=%g masked=%g live=%g\n",
                          cltime, self.has_shield, self.shield_deployed,
                          saved_input_buttons, input_buttons, csqc_live_buttons));
            print(sprintf("[shield-cl]   wep=%g wstate=%g stat=%g vm=%s\n",
                          self.weapon, self.weaponstate, getstatf(STAT_SHIELD),
                          (self.has_shield && SH_ShieldViewModel(self.weapon) != "")
                              ? SH_ShieldViewModel(self.weapon) : "(weapon's own)"));
        }
    }

    if (self.csqc_predict_cmd)
        self.csqc_predict_cmd();
    input_buttons = saved_input_buttons;
    input_angles = saved_input_angles;
    W_SlotAmmo_SaveCurrent(self);
};

// ============================================================
//  CSQC_ShieldDisplayFrame — the tactical shield's own sequence table
//
//  The nine combined models (models/shield/v_shield_*.mdl) do NOT share a
//  sequence layout with the pistol / knife / grenade view models they replace,
//  so the weapon's own csqc_display_frame is not consulted at all while one is
//  on screen.  The three measured layouts, and what each wrong index used to
//  play, are written up in shared/weapons/sh_wpn_csshield.qc.
//
//  The raise is an ANIMATION on the model already in hand, not a swap to a
//  second model: shield_up for its own length, then shield_idle, and
//  shield_down on the way back down.  csqc_shield_phase_start is stamped in
//  CSQC_ResetToConfirmedState, which is the only place in the client that ever
//  writes predicted_player.shield_deployed — so the edge cannot be missed the
//  way it could if this function tried to detect it, since this function is
//  skipped entirely in chase cam, in a cutscene and while scoped.
// ============================================================

float csqc_shield_phase_start;    // cltime of the last raise / lower edge
float csqc_shield_was_deployed;   // previous shield_deployed, for that edge

float() CSQC_ShieldDisplayFrame =
{
    float wep   = predicted_player.weapon;
    float phase = max(0, cltime - csqc_shield_phase_start);
    float up, down, idle_dur, t;

    if (predicted_player.shield_deployed)
    {
        up = SH_ShieldUpDuration(wep);
        if (phase < up)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = phase;
            return SH_ShieldSeqUp(wep);
        }
        // shield_idle carries no looping flag — measured, and not one sequence
        // in any of the nine models does — so under a monotonic clock the
        // engine runs it once and freezes on the last frame.  Wrap it by hand
        // rather than let the held pose die two seconds after it is raised.
        idle_dur = SH_ShieldIdleDuration(wep);
        t = phase - up;
        if (idle_dur > 0)
            t = t - floor(t / idle_dur) * idle_dur;
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = t;
        return SH_ShieldSeqIdle(wep);
    }

    // Lowering.  Hold shield_down for its own length before handing the model
    // back to the weapon, or the slab snaps out of shot with no transition.
    // The phase_start guard keeps a freshly picked-up shield (never raised, so
    // the stamp is still 0) out of this branch.
    down = SH_ShieldDownDuration(wep);
    if (csqc_shield_phase_start > 0 && phase < down)
    {
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = phase;
        return SH_ShieldSeqDown(wep);
    }

    // Carried but down — the weapon drives, through the shield model's table.
    // Pistols are the only shield-legal weapons with a magazine and they are
    // all SLOT_SECONDARY, so slot_secondary_mag is the shot-accurate count
    // without re-entering the slot-ammo cache from the render path.
    return SH_ShieldWeaponSeq(wep, predicted_player.weaponstate,
                              predicted_player.slot_secondary_mag,
                              predicted_player.wep_action_id);
};

// TRUE when the shield model is the one actually on screen.  Not the same test
// as .has_shield: a weapon with no combined model cannot be carried with a
// shield at all (rule 2), but W_CheckImpulses drops the shield a frame LATER
// than an admin `give` hands over an AK47, and for that one frame the model
// lookup must lose rather than draw an AK47's indices against a shield table.
float() CSQC_ShieldViewmodelActive =
{
    if (!predicted_player || !predicted_player.has_shield)
        return FALSE;
    return SH_ShieldViewModel(predicted_player.weapon) != "";
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

    csqc_viewmodel_sequence_time_override = FALSE;
    csqc_viewmodel_sequence_time = elapsed;

    // Must come after the override reset above, and before the per-weapon
    // dispatch — the shield REPLACES that dispatch, it does not post-process it.
    if (CSQC_ShieldViewmodelActive())
        return CSQC_ShieldDisplayFrame();

    if (!predicted_player.csqc_display_frame)
        return 0;

    return predicted_player.csqc_display_frame(elapsed);
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
    // Chase cam renders the third-person proxy — the viewmodel would float
    // in front of the camera like first-person, which looks wrong.  Same for a
    // Prop Hunt disguise (weaponless anyway, but belt-and-braces).
    if (cvar("chase_active") || CSQC_PropHunt_LocalDisguised())
        return;
    // trigger_camera cutscene — the view is coming from a camera elsewhere in
    // the map, so the player's gun would hang in the middle of the shot.
    if (Cutscene_Active())
        return;
    // Scope visibility — hide the viewmodel while the player is
    // "looking through" any scope so the gun doesn't poke through the
    // scope overlay.  Helper covers FADING_IN / SCOPED / FADING_OUT
    // (CoD scope phases where the screen is dominated by the overlay)
    // and the legacy CS-style zoomstage>0 path.  RAISING and FALLING
    // are NOT hidden — the user needs to see the gun animate up/down.
    if (CSQC_CodScope_HidesViewmodel())
        return;
    // Driving a prop_car / func_car — the player is hidden in third-person; the on-screen
    // gun would float in front of the chase cam.  Hide it (pm_incar is replicated to CSQC).
    if (predicted_player.pm_incar)
        return;

    mdl = predicted_player.weapon_viewmodel;

    // Tactical shield: Counter-Strike does not draw the shield beside the gun,
    // it ships a COMBINED view model per pistol (cstrike/models/shield/
    // v_shield_usp.mdl and its eight siblings), so this is a whole-model
    // substitution rather than a second entity.
    //
    // ONE model for both states.  This used to swap again to v_shield_r.mdl on
    // deploy, on the assumption that the file is the shield by itself.  It is
    // not — it is the shield with a full FN Five-Seven in it, which is what
    // "my gun turns into a five-seven when I press +attack2" was.  The raise
    // lives inside the combined model as shield_up / shield_idle /
    // shield_down; CSQC_ShieldDisplayFrame plays them.
    float shield_vm = CSQC_ShieldViewmodelActive();
    if (shield_vm)
        mdl = SH_ShieldViewModel(predicted_player.weapon);

    if (mdl == "")
        return;

    if (!csqc_viewmodel_ent)
    {
        csqc_viewmodel_ent = spawn();
        csqc_viewmodel_ent.classname = "csqc_viewmodel";
        csqc_viewmodel_ent.movetype = MOVETYPE_NONE;
    }

    setmodel(csqc_viewmodel_ent, mdl);
    // Viewmodels are cosmetic. Keep them out of CSQC bullet traces,
    // especially MOVE_HITMODEL traces against converted GoldSrc MDLs
    // with large hand/weapon hitbox sets.
    csqc_viewmodel_ent.solid = SOLID_NOT;
    setsize(csqc_viewmodel_ent, '0 0 0', '0 0 0');

    // `|| shield_vm` is load-bearing, not belt-and-braces.  All nine combined
    // models are stock GoldSrc IDST and MUST take the sequence branch, but the
    // weapon whose flag this normally is need not be: the Deagle's own view
    // model is a flat IDPO frame bake and leaves weapon_uses_sequences unset,
    // so a shield + Deagle took the frame-stepping branch and froze on frame 0.
    if (predicted_player.weapon_uses_sequences || shield_vm)
    {
        // GoldSrc-format viewmodel: .frame is a sequence index, the engine
        // animates within the sequence based on .frame1time. We pass the
        // elapsed time since the current weapon state began so the engine
        // can find the right sub-frame.
        //
        // When idle (wep_anim_start == 0), pass cltime so non-looping idle
        // sequences (e.g. slide-locked-back after a last-shot) advance past
        // their final frame and the engine clamps to the end pose. Looping
        // idle sequences keep looping naturally.
        float seq = CSQC_GetWeaponDisplayFrame();
        float elapsed;
        if (csqc_viewmodel_sequence_time_override)
            elapsed = csqc_viewmodel_sequence_time;
        else if (predicted_player.wep_anim_start > 0)
            elapsed = max(0, cltime - predicted_player.wep_anim_start);
        else
            elapsed = cltime;
        csqc_viewmodel_ent.frame    = seq;
        csqc_viewmodel_ent.frame1time = elapsed;
        // .frame2 = seq, NOT 0.  On an HL model this engine reads .frame2 as the
        // PREVIOUS SEQUENCE INDEX and cross-fades out of it over
        // r_hlmdl_seqblend_time (0.12 s, gl_hlmdl.c) whenever oldseq != newseq.
        // Writing a literal 0 told it "the previous sequence was index 0" for
        // every weapon in the mod, and .frame2time is never written anywhere in
        // the client, so the old pose was sampled at frame 0 of sequence 0.
        //
        // Setting .lerpfrac = 0 on the next line does NOT suppress it — that path
        // never reads lerpweight at all; the blend has its own clock and its own
        // trigger.  Making the two indices equal is what short-circuits it
        // (gl_hlmdl.c's oldseq != newseq test), the same trick cl_muzzleflash.qc
        // already uses.
        //
        // It bit the Sven M16 hardest because v_m16a2.mdl is one of only two
        // viewmodels on the mount whose sequence 0 is `draw` rather than an idle:
        // every shot cross-faded out of the draw pose, a 93.8-degree bone delta,
        // which is the "very wrong firing animation".  Weapons whose sequence 0
        // IS their idle were blending from something close to rest and mostly got
        // away with it.
        csqc_viewmodel_ent.frame2   = seq;
        csqc_viewmodel_ent.lerpfrac = 0;
    }
    else
    {
        float disp = CSQC_GetWeaponDisplayFrame();
        float fi   = floor(disp);
        csqc_viewmodel_ent.frame       = fi;
        csqc_viewmodel_ent.frame2      = fi + 1;
        csqc_viewmodel_ent.lerpfrac    = disp - fi;
    }

    // XOR the user's cl_lefthand toggle against the per-weapon default.
    // A weapon authored with a left-handed source mesh sets
    // weapon_viewmodel_flip = TRUE so it appears right-handed by default;
    // cl_lefthand 1 then flips it back to left-handed (and vice versa
    // for right-handed source meshes).
    float vm_flip = predicted_player.weapon_viewmodel_flip;
    // The nine shield models are stock right-handed Counter-Strike assets, so
    // the per-weapon default belongs to the model that is NOT on screen.  It
    // matters for the three grenades, which set the flag TRUE for their own
    // left-handed meshes — mirroring a shield model would put the slab on the
    // wrong arm and read as a different bug entirely.
    if (shield_vm)
        vm_flip = FALSE;
    if (cvar("cl_lefthand"))
        vm_flip = !vm_flip;
    // RF_NOSHADOW: the first-person viewmodel must never cast into the fake-shadow
    // maps (r_shadows 2) — the floating gun silhouette gives away nothing but looks
    // broken; the BODY shadow comes from the player proxy instead.
    float vm_renderflags = RF_VIEWMODEL | RF_DEPTHHACK | RF_NOSHADOW;
    if (vm_flip)
        vm_renderflags |= RF_XFLIP;
    csqc_viewmodel_ent.renderflags  = vm_renderflags;
    // Viewmodel sits at the camera origin so it's permanently inside the
    // muzzleflash dlight radius — the per-mesh dlight loop (one
    // distance/sample iter per active dlight, gl_alias.c:1515-1559) hits
    // its worst case every frame the flash is alive.  EF_FULLBRIGHT
    // early-outs that whole branch.  Trade lit muzzleflash on the gun
    // mesh for the FPS recovery; users on weak GPUs flip this on.
    if (cvar("cl_viewmodel_nolight"))
        csqc_viewmodel_ent.effects |= EF_FULLBRIGHT;
    else
        // NOT `&~=` — fteqcc64 miscompiles it into a plain assignment of the
        // right-hand operand, so this line used to SET EF_FULLBRIGHT in the very
        // branch that exists to clear it: once cl_viewmodel_nolight had been on,
        // turning it off left the viewmodel permanently fullbright.  Same trap,
        // same silence, as the shield button mask in CSQC_PredictWeaponCommand.
        csqc_viewmodel_ent.effects = csqc_viewmodel_ent.effects
                                   - (csqc_viewmodel_ent.effects & EF_FULLBRIGHT);
    // Bob / weight / sway offsets — engine treats .origin/.angles on an
    // RF_VIEWMODEL entity as camera-relative (R_RotateForEntity multiplies
    // by weaponmatrix), so writes here only affect screen position, not
    // world-space prediction state.
    CSQC_ApplyViewmodelOffsets(csqc_viewmodel_ent);
    addentity(csqc_viewmodel_ent);
};

// ============================================================
//  CSQC_AddRemoteViewmodel — first-person viewmodel for ANOTHER player
//  (spectated target / killcam killer), reconstructed from the networked
//  weapon id + weaponstate + wep_action (proxy vis_* fields, sh_customdefs).
//
//  Reuses the per-weapon equip + display callback by pointing a scratch
//  "source" entity (and predicted_player, which the callbacks read) at the
//  remote's state.  SAFE only while the local player is dead/spectating: the
//  equip's only side effects are weapon-specific sound globals, meaningless
//  with no live local gun and reset on respawn.  Idle/fire/draw are faithful;
//  multi-phase reloads show their first phase (per-weapon reload state isn't
//  networked).  The pose is simplified (no bob/sway — remote input isn't sent).
// ============================================================
entity csqc_remotevm_src;   // scratch holding the reconstructed weapon config
entity csqc_remotevm_ent;   // the rendered viewmodel entity

void(float wepid, float wstate, float wep_action, float anim_start) CSQC_AddRemoteViewmodel =
{
    if (wepid == WEP_NONE)
        return;

    if (!csqc_remotevm_src)
    {
        csqc_remotevm_src = spawn();
        csqc_remotevm_src.classname = "remote_vm_src";
    }
    if (!csqc_remotevm_ent)
    {
        csqc_remotevm_ent = spawn();
        csqc_remotevm_ent.classname = "remote_vm";
        csqc_remotevm_ent.movetype = MOVETYPE_NONE;
        csqc_remotevm_ent.solid = SOLID_NOT;
    }

    entity old_self = self;
    entity old_pp   = predicted_player;

    csqc_remotevm_src.weaponstate    = wstate;
    csqc_remotevm_src.wep_action_id  = wep_action;
    csqc_remotevm_src.wep_anim_start = anim_start;

    // (Re)configure the scratch's viewmodel fields only on weapon change.
    if (csqc_remotevm_src.weapon != wepid)
    {
        csqc_remotevm_src.weapon = wepid;
        self = csqc_remotevm_src;
        predicted_player = csqc_remotevm_src;
        CSQC_WeaponEquip(wepid);
        self = old_self;
        predicted_player = old_pp;
    }

    string mdl = csqc_remotevm_src.weapon_viewmodel;
    if (mdl == "")
        return;
    if (csqc_remotevm_ent.model != mdl)
        setmodel(csqc_remotevm_ent, mdl);

    // Frame: the per-weapon display callback reads predicted_player.*, so point
    // it at the scratch for the duration of the call.
    float elapsed = max(0, cltime - anim_start);
    float disp = 0;
    predicted_player = csqc_remotevm_src;
    if (csqc_remotevm_src.csqc_display_frame)
        disp = csqc_remotevm_src.csqc_display_frame(elapsed);
    predicted_player = old_pp;

    if (csqc_remotevm_src.weapon_uses_sequences)
    {
        csqc_remotevm_ent.frame      = disp;
        csqc_remotevm_ent.frame1time = elapsed;
        // Same HL sequence cross-fade as the first-person path above — and here
        // .frame2 was not written at all, so it carried whatever the entity was
        // last left holding.  Pinning it to the current sequence short-circuits
        // the blend rather than leaving it to chance.
        csqc_remotevm_ent.frame2     = disp;
        csqc_remotevm_ent.lerpfrac   = 0;
    }
    else
    {
        float fi = floor(disp);
        csqc_remotevm_ent.frame    = fi;
        csqc_remotevm_ent.frame2   = fi + 1;
        csqc_remotevm_ent.lerpfrac = disp - fi;
    }

    float vm_flip = csqc_remotevm_src.weapon_viewmodel_flip;
    if (cvar("cl_lefthand"))
        vm_flip = !vm_flip;
    float rf = RF_VIEWMODEL | RF_DEPTHHACK;
    if (vm_flip)
        rf |= RF_XFLIP;
    csqc_remotevm_ent.renderflags = rf;
    csqc_remotevm_ent.effects = cvar("cl_viewmodel_nolight") ? EF_FULLBRIGHT : 0;
    // Simplified pose: base viewmodel position (camera-relative for RF_VIEWMODEL).
    setorigin(csqc_remotevm_ent, '0 0 0');
    csqc_remotevm_ent.angles = '0 0 0';
    addentity(csqc_remotevm_ent);
};

// ============================================================
//  CSQC_WeaponEquip — single dispatch
//  Maps weapon ID to per-weapon CSQC equip function.
//  Sets all client-side function pointers and weapon data fields.
//  Called from CSQC_PredictSelectWeapon and proxy weapon sync.
// ============================================================

// Prime the muzzle-smoke offset chain at equip time so the per-frame
// producer has the current weapon's basis BEFORE the first shot.
// Without this, the first puff of a new weapon emits from the previous
// weapon's stashed offsets (see cl_muzzlesmoke.qc ms_chain_*).  Weapons
// without a fire-path muzzle (knife/grenade/melee) are skipped — their
// producer guard (`ms_has_offsets` plus zero heat) keeps them silent.
// CF/HD weapons use $attachment muzzles resolved per-shot — set zero
// offsets here so the first shot's basis is still updated by the
// AtWorld path's round-trip conversion.
void(float weapon_id) CSQC_PrimeMuzzleSmokeOffsets =
{
    if      (weapon_id == WEP_AK47)         CSQC_MuzzleSmokeSetOffsets(AK47_MUZZLE_FORWARD, AK47_MUZZLE_RIGHT, AK47_MUZZLE_DOWN);
    else if (weapon_id == WEP_M4A1)         CSQC_MuzzleSmokeSetOffsets(M4A1_MUZZLE_FORWARD, M4A1_MUZZLE_RIGHT, M4A1_MUZZLE_DOWN);
    else if (weapon_id == WEP_FLAKSHOTGUN)  CSQC_MuzzleSmokeSetOffsets(FLAKSHOTGUN_MUZZLE_FORWARD, FLAKSHOTGUN_MUZZLE_RIGHT, FLAKSHOTGUN_MUZZLE_DOWN);
    else if (weapon_id == WEP_PISTOL)       CSQC_MuzzleSmokeSetOffsets(PISTOL_MUZZLE_FORWARD, PISTOL_MUZZLE_RIGHT, PISTOL_MUZZLE_DOWN);
    else if (weapon_id == WEP_357)          CSQC_MuzzleSmokeSetOffsets(W357_MUZZLE_FORWARD, W357_MUZZLE_RIGHT, W357_MUZZLE_DOWN);
    else if (weapon_id == WEP_UZI)          CSQC_MuzzleSmokeSetOffsets(UZI_MUZZLE_FORWARD, UZI_MUZZLE_RIGHT, UZI_MUZZLE_DOWN);
    else if (weapon_id == WEP_UZIAKIMBO)    CSQC_MuzzleSmokeSetOffsets(UZIAK_MUZZLE_FORWARD, UZIAK_MUZZLE_RIGHT, UZIAK_MUZZLE_DOWN);
    else if (weapon_id == WEP_MINIGUN)      CSQC_MuzzleSmokeSetOffsets(MINIGUN_MUZZLE_FORWARD, MINIGUN_MUZZLE_RIGHT, MINIGUN_MUZZLE_DOWN);
    else if (weapon_id == WEP_SVM16)        CSQC_MuzzleSmokeSetOffsets(SVM16_MUZZLE_FORWARD, SVM16_MUZZLE_RIGHT, SVM16_MUZZLE_DOWN);
    else if (weapon_id == WEP_SNIPERRIFLE)  CSQC_MuzzleSmokeSetOffsets(SNIPER_MUZZLE_FORWARD, SNIPER_MUZZLE_RIGHT, SNIPER_MUZZLE_DOWN);
    else if (weapon_id == WEP_EAGLE)        CSQC_MuzzleSmokeSetOffsets(EAGLE_MUZZLE_FORWARD, EAGLE_MUZZLE_RIGHT, EAGLE_MUZZLE_DOWN);
    else if (weapon_id == WEP_ASSHOTGUN)    CSQC_MuzzleSmokeSetOffsets(ASSG_MUZZLE_FORWARD, ASSG_MUZZLE_RIGHT, ASSG_MUZZLE_DOWN);
    else if (weapon_id == WEP_DOD98K)       CSQC_MuzzleSmokeSetOffsets(K98_MUZZLE_FORWARD, K98_MUZZLE_RIGHT, K98_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODCOLT)      CSQC_MuzzleSmokeSetOffsets(DODCOLT_MUZZLE_FORWARD, DODCOLT_MUZZLE_RIGHT, DODCOLT_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODLUGER)     CSQC_MuzzleSmokeSetOffsets(DODLUGER_MUZZLE_FORWARD, DODLUGER_MUZZLE_RIGHT, DODLUGER_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODWEBLEY)    CSQC_MuzzleSmokeSetOffsets(DODWEBLEY_MUZZLE_FORWARD, DODWEBLEY_MUZZLE_RIGHT, DODWEBLEY_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODGARAND)    CSQC_MuzzleSmokeSetOffsets(DODGARAND_MUZZLE_FORWARD, DODGARAND_MUZZLE_RIGHT, DODGARAND_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODCARBINE)   CSQC_MuzzleSmokeSetOffsets(DODCARBINE_MUZZLE_FORWARD, DODCARBINE_MUZZLE_RIGHT, DODCARBINE_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODK43)       CSQC_MuzzleSmokeSetOffsets(DODK43_MUZZLE_FORWARD, DODK43_MUZZLE_RIGHT, DODK43_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODTOMMY)     CSQC_MuzzleSmokeSetOffsets(DODTOMMY_MUZZLE_FORWARD, DODTOMMY_MUZZLE_RIGHT, DODTOMMY_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODMP40)      CSQC_MuzzleSmokeSetOffsets(DODMP40_MUZZLE_FORWARD, DODMP40_MUZZLE_RIGHT, DODMP40_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODSTEN)      CSQC_MuzzleSmokeSetOffsets(DODSTEN_MUZZLE_FORWARD, DODSTEN_MUZZLE_RIGHT, DODSTEN_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODGREASE)    CSQC_MuzzleSmokeSetOffsets(DODGREASE_MUZZLE_FORWARD, DODGREASE_MUZZLE_RIGHT, DODGREASE_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODMP44)      CSQC_MuzzleSmokeSetOffsets(DODMP44_MUZZLE_FORWARD, DODMP44_MUZZLE_RIGHT, DODMP44_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODBAR)       CSQC_MuzzleSmokeSetOffsets(DODBAR_MUZZLE_FORWARD, DODBAR_MUZZLE_RIGHT, DODBAR_MUZZLE_DOWN);
    // The Bren and the two FG42s share one triple, like the machine guns above.
    else if (weapon_id == WEP_DODBREN || weapon_id == WEP_DODFG42 || weapon_id == WEP_DODFG42S)
        CSQC_MuzzleSmokeSetOffsets(DODAUTO_MUZZLE_FORWARD, DODAUTO_MUZZLE_RIGHT, DODAUTO_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODFCARB)     CSQC_MuzzleSmokeSetOffsets(DODFCARB_MUZZLE_FORWARD, DODFCARB_MUZZLE_RIGHT, DODFCARB_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODENFIELD)   CSQC_MuzzleSmokeSetOffsets(DODENF_MUZZLE_FORWARD, DODENF_MUZZLE_RIGHT, DODENF_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODMORTAR)    CSQC_MuzzleSmokeSetOffsets(DODMORTAR_MUZZLE_FORWARD, DODMORTAR_MUZZLE_RIGHT, DODMORTAR_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODSCOPED98K) CSQC_MuzzleSmokeSetOffsets(DODS98K_MUZZLE_FORWARD, DODS98K_MUZZLE_RIGHT, DODS98K_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODSPRING)    CSQC_MuzzleSmokeSetOffsets(DODSPRING_MUZZLE_FORWARD, DODSPRING_MUZZLE_RIGHT, DODSPRING_MUZZLE_DOWN);
    else if (weapon_id == WEP_DODENFIELDS)  CSQC_MuzzleSmokeSetOffsets(DODENFS_MUZZLE_FORWARD, DODENFS_MUZZLE_RIGHT, DODENFS_MUZZLE_DOWN);
    // The three machine guns share one offset triple — their muzzles sit within
    // a couple of units of each other and the smoke is a fat puff, not a line.
    else if (weapon_id == WEP_DOD30CAL || weapon_id == WEP_DODMG34 || weapon_id == WEP_DODMG42)
        CSQC_MuzzleSmokeSetOffsets(DODMG_MUZZLE_FORWARD, DODMG_MUZZLE_RIGHT, DODMG_MUZZLE_DOWN);
    // ...and so do the three launchers, whose "muzzle" is the back of a tube.
    else if (weapon_id == WEP_DODBAZOOKA || weapon_id == WEP_DODSCHRECK || weapon_id == WEP_DODPIAT)
        CSQC_MuzzleSmokeSetOffsets(DODAT_MUZZLE_FORWARD, DODAT_MUZZLE_RIGHT, DODAT_MUZZLE_DOWN);
    // (No melee entry — a knife has no muzzle, and the four DoD melee weapons
    //  never call the muzzle-smoke chain.)
    else if (weapon_id == WEP_SCOUT)        CSQC_MuzzleSmokeSetOffsets(SCOUT_MUZZLE_FORWARD, SCOUT_MUZZLE_RIGHT, SCOUT_MUZZLE_DOWN);
    else if (weapon_id == WEP_M249)         CSQC_MuzzleSmokeSetOffsets(M249_MUZZLE_FORWARD, M249_MUZZLE_RIGHT, M249_MUZZLE_DOWN);
    else if (weapon_id == WEP_HLSHOTGUN)    CSQC_MuzzleSmokeSetOffsets(HLSG_MUZZLE_FORWARD, HLSG_MUZZLE_RIGHT, HLSG_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSM3)         CSQC_MuzzleSmokeSetOffsets(M3_MUZZLE_FORWARD, M3_MUZZLE_RIGHT, M3_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSMP5)        CSQC_MuzzleSmokeSetOffsets(MP5_MUZZLE_FORWARD, MP5_MUZZLE_RIGHT, MP5_MUZZLE_DOWN);
    // The thirteen Counter-Strike 1.6 guns.
    else if (weapon_id == WEP_CSP228)          CSQC_MuzzleSmokeSetOffsets(CSP228_MUZZLE_FORWARD, CSP228_MUZZLE_RIGHT, CSP228_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSFIVESEVEN)     CSQC_MuzzleSmokeSetOffsets(CSFIVESEVEN_MUZZLE_FORWARD, CSFIVESEVEN_MUZZLE_RIGHT, CSFIVESEVEN_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSELITE)         CSQC_MuzzleSmokeSetOffsets(CSELITE_MUZZLE_FORWARD, CSELITE_MUZZLE_RIGHT, CSELITE_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSTMP)           CSQC_MuzzleSmokeSetOffsets(CSTMP_MUZZLE_FORWARD, CSTMP_MUZZLE_RIGHT, CSTMP_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSMAC10)         CSQC_MuzzleSmokeSetOffsets(CSMAC10_MUZZLE_FORWARD, CSMAC10_MUZZLE_RIGHT, CSMAC10_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSUMP45)         CSQC_MuzzleSmokeSetOffsets(CSUMP45_MUZZLE_FORWARD, CSUMP45_MUZZLE_RIGHT, CSUMP45_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSP90)           CSQC_MuzzleSmokeSetOffsets(CSP90_MUZZLE_FORWARD, CSP90_MUZZLE_RIGHT, CSP90_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSGALIL)         CSQC_MuzzleSmokeSetOffsets(CSGALIL_MUZZLE_FORWARD, CSGALIL_MUZZLE_RIGHT, CSGALIL_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSFAMAS)         CSQC_MuzzleSmokeSetOffsets(CSFAMAS_MUZZLE_FORWARD, CSFAMAS_MUZZLE_RIGHT, CSFAMAS_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSAUG)           CSQC_MuzzleSmokeSetOffsets(CSAUG_MUZZLE_FORWARD, CSAUG_MUZZLE_RIGHT, CSAUG_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSSG552)         CSQC_MuzzleSmokeSetOffsets(CSSG552_MUZZLE_FORWARD, CSSG552_MUZZLE_RIGHT, CSSG552_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSSG550)         CSQC_MuzzleSmokeSetOffsets(CSSG550_MUZZLE_FORWARD, CSSG550_MUZZLE_RIGHT, CSSG550_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSXM1014)        CSQC_MuzzleSmokeSetOffsets(CSXM1014_MUZZLE_FORWARD, CSXM1014_MUZZLE_RIGHT, CSXM1014_MUZZLE_DOWN);
    else if (weapon_id == WEP_CSAWP)        CSQC_MuzzleSmokeSetOffsets(AWP_MUZZLE_FORWARD, AWP_MUZZLE_RIGHT, AWP_MUZZLE_DOWN);
    else if (weapon_id == WEP_DEAGLE)       CSQC_MuzzleSmokeSetOffsets(DEAGLE_MUZZLE_FORWARD, DEAGLE_MUZZLE_RIGHT, DEAGLE_MUZZLE_DOWN);
    else if (weapon_id == WEP_GLOCK)        CSQC_MuzzleSmokeSetOffsets(GLOCK_MUZZLE_FORWARD, GLOCK_MUZZLE_RIGHT, GLOCK_MUZZLE_DOWN);
    else if (weapon_id == WEP_G3SG1)        CSQC_MuzzleSmokeSetOffsets(G3SG1_MUZZLE_FORWARD, G3SG1_MUZZLE_RIGHT, G3SG1_MUZZLE_DOWN);
    else if (weapon_id == WEP_HLSMG)        CSQC_MuzzleSmokeSetOffsets(HLSMG_MUZZLE_FORWARD, HLSMG_MUZZLE_RIGHT, HLSMG_MUZZLE_DOWN);
    else if (weapon_id == WEP_HLGLOCK)      CSQC_MuzzleSmokeSetOffsets(HLGLOCK_MUZZLE_FORWARD, HLGLOCK_MUZZLE_RIGHT, HLGLOCK_MUZZLE_DOWN);
    else if (weapon_id == WEP_TH1911)       CSQC_MuzzleSmokeSetOffsets(TH1911_MUZZLE_FORWARD, TH1911_MUZZLE_RIGHT, TH1911_MUZZLE_DOWN);
    else if (weapon_id == WEP_THTOMMY)      CSQC_MuzzleSmokeSetOffsets(THTOMMY_MUZZLE_FORWARD, THTOMMY_MUZZLE_RIGHT, THTOMMY_MUZZLE_DOWN);
    else if (weapon_id == WEP_THGREASE)     CSQC_MuzzleSmokeSetOffsets(THGREASE_MUZZLE_FORWARD, THGREASE_MUZZLE_RIGHT, THGREASE_MUZZLE_DOWN);
    else if (weapon_id == WEP_THM14)        CSQC_MuzzleSmokeSetOffsets(THM14_MUZZLE_FORWARD, THM14_MUZZLE_RIGHT, THM14_MUZZLE_DOWN);
    else if (weapon_id == WEP_THM16)        CSQC_MuzzleSmokeSetOffsets(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT, THM16_MUZZLE_DOWN);
    else if (weapon_id == WEP_THSAWOFF)     CSQC_MuzzleSmokeSetOffsets(THSAWOFF_MUZZLE_FORWARD, THSAWOFF_MUZZLE_RIGHT, THSAWOFF_MUZZLE_DOWN);
    else if (weapon_id == WEP_PAINTBALL)    CSQC_MuzzleSmokeSetOffsets(PAINTBALL_PROJ_MUZZLE_FORWARD, PAINTBALL_PROJ_MUZZLE_RIGHT, PAINTBALL_PROJ_MUZZLE_DOWN);
    else if (weapon_id == WEP_CFAUG)        CSQC_MuzzleSmokeSetOffsets(CFAUG_MUZZLE_FORWARD, CFAUG_MUZZLE_RIGHT, CFAUG_MUZZLE_DOWN);
    // Bone-attached weapons resolve the muzzle via $attachment each shot;
    // mark offsets valid with zeros so the producer guard passes — the
    // first shot's AtWorld call overwrites with the real basis on the same
    // tick.  Keyed off the weapon_muzzle_bone the equip set (no WEP_* list).
    else if (self.weapon_muzzle_bone != "")
        CSQC_MuzzleSmokeSetOffsets(0, 0, 0);
};

// Vector form of the per-weapon muzzle offset (forward, right, down) for the REMOTE /
// spectated shot path (CSQC_BulletImpactRemote).  Reuses the CSQC_PrimeMuzzleSmokeOffsets
// switch (no per-weapon table drift) but SNAPSHOTS + restores the local muzzle-smoke
// chain globals so a remote shot doesn't clobber the local player's smoke offsets.
// Returns '0 0 0' for bone-attached / unknown weapons -> caller uses a generic gun-line.
vector(float weapon_id) CSQC_WeaponMuzzleOffsetVec =
{
    float sf = ms_chain_fwd, sr = ms_chain_right, sd = ms_chain_down;
    float ss = ms_chain_side, sh = ms_has_offsets;
    ms_has_offsets = 0;
    CSQC_PrimeMuzzleSmokeOffsets(weapon_id);
    vector r = ms_has_offsets ? [ms_chain_fwd, ms_chain_right, ms_chain_down] : '0 0 0';
    ms_chain_fwd = sf; ms_chain_right = sr; ms_chain_down = sd;
    ms_chain_side = ss; ms_has_offsets = sh;
    return r;
};

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
    self.weapon_uses_sequences = FALSE;
    self.weapon_viewmodel_flip = FALSE;
    // ADS/scope profile + muzzle bone default to "no ADS, no bone"; each
    // weapon's CSQC equip re-asserts what it needs (see W_SetADSProfile).
    self.weapon_ads_eligible = 0;
    self.weapon_ads_prefix   = "";
    self.weapon_scope_class  = SCOPE_CLASS_NONE;
    self.weapon_muzzle_bone  = "";
    // Emplaced-stance eligibility, cleared the same way.  NOT wep_deployed: this
    // function re-runs on every snapshot reconcile, so zeroing the stance itself
    // here would unplant a deployed weapon 20 times a second.  The stance comes
    // off the prediction proxy; only the eligibility flag is rebuilt per equip.
    self.weapon_deployable   = 0;
    self.weapon_deploy_crouched = 0;

    if (weapon_id == WEP_DEAGLE)            CSQC_DeagleEquip();
    else if (weapon_id == WEP_KNIFE)        CSQC_KnifeEquip();
    else if (weapon_id == WEP_AK47)         CSQC_AK47Equip();
    else if (weapon_id == WEP_HDAK47)       CSQC_HDAK47Equip();
    else if (weapon_id == WEP_M4A1)         CSQC_M4A1Equip();
    else if (weapon_id == WEP_FLAKSHOTGUN)  CSQC_FlakShotgunEquip();
    else if (weapon_id == WEP_PISTOL)       CSQC_PistolEquip();
    else if (weapon_id == WEP_GAUSS)        CSQC_GaussEquip();
    else if (weapon_id == WEP_CROSSBOW)     CSQC_CrossbowEquip();
    else if (weapon_id == WEP_357)          CSQC_357Equip();
    else if (weapon_id == WEP_DOD98K)       CSQC_98KEquip();
    else if (weapon_id == WEP_DODCOLT)      CSQC_DodColtEquip();
    else if (weapon_id == WEP_DODLUGER)     CSQC_DodLugerEquip();
    else if (weapon_id == WEP_DODWEBLEY)    CSQC_DodWebleyEquip();
    else if (weapon_id == WEP_DODGARAND)    CSQC_DodGarandEquip();
    else if (weapon_id == WEP_DODCARBINE)   CSQC_DodCarbineEquip();
    else if (weapon_id == WEP_DODK43)       CSQC_DodK43Equip();
    else if (weapon_id == WEP_DODTOMMY)     CSQC_DodTommyEquip();
    else if (weapon_id == WEP_DODMP40)      CSQC_DodMP40Equip();
    else if (weapon_id == WEP_DODSTEN)      CSQC_DodStenEquip();
    else if (weapon_id == WEP_DODGREASE)    CSQC_DodGreaseEquip();
    else if (weapon_id == WEP_DODMP44)      CSQC_DodMP44Equip();
    else if (weapon_id == WEP_DODBAR)       CSQC_DodBarEquip();
    else if (weapon_id == WEP_DODBREN)      CSQC_DodBrenEquip();
    else if (weapon_id == WEP_DODFG42)      CSQC_DodFG42Equip();
    else if (weapon_id == WEP_DODFG42S)     CSQC_DodFG42SEquip();
    else if (weapon_id == WEP_DODFCARB)     CSQC_DodFCarbEquip();
    else if (weapon_id == WEP_DODENFIELD)   CSQC_DodEnfEquip();
    else if (weapon_id == WEP_DODMORTAR)    CSQC_DodMortarEquip();
    else if (weapon_id == WEP_DODBINOCS)    CSQC_DodBinocsEquip();
    else if (weapon_id == WEP_DODSCOPED98K) CSQC_DodS98KEquip();
    else if (weapon_id == WEP_DODSPRING)    CSQC_DodSpringEquip();
    else if (weapon_id == WEP_DODENFIELDS)  CSQC_DodEnfSEquip();
    else if (weapon_id == WEP_DOD30CAL)     CSQC_Dod30CalEquip();
    else if (weapon_id == WEP_DODMG34)      CSQC_DodMG34Equip();
    else if (weapon_id == WEP_DODMG42)      CSQC_DodMG42Equip();
    else if (weapon_id == WEP_DODBAZOOKA)   CSQC_DodBazookaEquip();
    else if (weapon_id == WEP_DODSCHRECK)   CSQC_DodSchreckEquip();
    else if (weapon_id == WEP_DODPIAT)      CSQC_DodPiatEquip();
    else if (weapon_id == WEP_DODAMERK)     CSQC_DodAmerkEquip();
    else if (weapon_id == WEP_DODFAIRBAIRN) CSQC_DodFairbairnEquip();
    else if (weapon_id == WEP_DODPARAKNIFE) CSQC_DodParaknifeEquip();
    else if (weapon_id == WEP_DODSPADE)     CSQC_DodSpadeEquip();
    else if (weapon_id == WEP_SCOUT)        CSQC_ScoutEquip();
    else if (weapon_id == WEP_GRENADELAUNCHER) CSQC_GLEquip();
    else if (weapon_id == WEP_M249)         CSQC_M249Equip();
    else if (weapon_id == WEP_HLCROWBAR)    CSQC_CrowbarEquip();
    else if (weapon_id == WEP_HLSHOTGUN)    CSQC_ShotgunEquip();
    else if (weapon_id == WEP_CSM3)         CSQC_M3Equip();
    else if (weapon_id == WEP_CSMP5)        CSQC_MP5Equip();
    // The thirteen Counter-Strike 1.6 guns.
    else if (weapon_id == WEP_CSP228)          CSQC_CSP228Equip();
    else if (weapon_id == WEP_CSFIVESEVEN)     CSQC_CSFiveSevenEquip();
    else if (weapon_id == WEP_CSELITE)         CSQC_CSEliteEquip();
    else if (weapon_id == WEP_CSTMP)           CSQC_CSTmpEquip();
    else if (weapon_id == WEP_CSMAC10)         CSQC_CSMac10Equip();
    else if (weapon_id == WEP_CSUMP45)         CSQC_CSUmp45Equip();
    else if (weapon_id == WEP_CSP90)           CSQC_CSP90Equip();
    else if (weapon_id == WEP_CSGALIL)         CSQC_CSGalilEquip();
    else if (weapon_id == WEP_CSFAMAS)         CSQC_CSFamasEquip();
    else if (weapon_id == WEP_CSAUG)           CSQC_CSAugEquip();
    else if (weapon_id == WEP_CSSG552)         CSQC_CSSg552Equip();
    else if (weapon_id == WEP_CSSG550)         CSQC_CSSg550Equip();
    else if (weapon_id == WEP_CSXM1014)        CSQC_CSXM1014Equip();
    else if (weapon_id == WEP_REBAR)        CSQC_RebarEquip();
    else if (weapon_id == WEP_CSAWP)        CSQC_AWPEquip();
    else if (weapon_id == WEP_WRENCH)       CSQC_WrenchEquip();
    else if (weapon_id == WEP_GLOCK)        CSQC_GlockEquip();
    else if (weapon_id == WEP_G3SG1)        CSQC_G3SG1Equip();
    else if (weapon_id == WEP_HLSMG)        CSQC_HLSMGEquip();
    else if (weapon_id == WEP_HLRPG)        CSQC_RPGEquip();
    else if (weapon_id == WEP_HLGRENADE)    CSQC_HLGrenadeEquip();
    else if (weapon_id == WEP_SATCHEL)      CSQC_SatchelEquip();
    else if (weapon_id == WEP_TRIPMINE)     CSQC_TripmineEquip();
    else if (weapon_id == WEP_SNARK)        CSQC_SnarkEquip();
    else if (weapon_id == WEP_HORNETGUN)    CSQC_HGunEquip();
    else if (weapon_id == WEP_SHOCKRIFLE)   CSQC_ShockEquip();
    else if (weapon_id == WEP_TH1911)       CSQC_TH1911Equip();
    else if (weapon_id == WEP_THTOMMY)      CSQC_THTommyEquip();
    else if (weapon_id == WEP_THGREASE)     CSQC_THGreaseEquip();
    else if (weapon_id == WEP_THM14)        CSQC_THM14Equip();
    else if (weapon_id == WEP_THM16)        CSQC_THM16Equip();
    else if (weapon_id == WEP_THSAWOFF)     CSQC_THSawoffEquip();
    else if (weapon_id == WEP_THSPANNER)    CSQC_THSpannerEquip();
    else if (weapon_id == WEP_THTESLA)      CSQC_THTeslaEquip();
    // Sven Co-op and Opposing Force.  A missing branch here leaves
    // .weapon_viewmodel unset, and CSQC_AddPredictedViewmodel returns early on
    // an empty string - so the weapon works and is simply invisible in your
    // hands, which is a hard symptom to trace back to one absent line.
    else if (weapon_id == WEP_MEDKIT)       CSQC_MedkitEquip();
    else if (weapon_id == WEP_UZI)          CSQC_UziEquip();
    else if (weapon_id == WEP_UZIAKIMBO)    CSQC_UziAkimboEquip();
    else if (weapon_id == WEP_MINIGUN)      CSQC_MinigunEquip();
    else if (weapon_id == WEP_SVM16)        CSQC_SVM16Equip();
    else if (weapon_id == WEP_PIPEWRENCH)   CSQC_PWrenchEquip();
    else if (weapon_id == WEP_SNIPERRIFLE)  CSQC_SniperEquip();
    else if (weapon_id == WEP_SPORELAUNCHER) CSQC_SporeEquip();
    else if (weapon_id == WEP_EAGLE)        CSQC_EagleEquip();
    else if (weapon_id == WEP_ASSHOTGUN)    CSQC_ASShotgunEquip();
    else if (weapon_id == WEP_ASSOFLAM)     CSQC_SoflamEquip();
    // The last three Opposing Force weapons.  A missing row here is the symptom
    // the comment above describes: the gun equips server-side and the client is
    // left holding the previous weapon's viewmodel and prediction.
    else if (weapon_id == WEP_OPKNIFE)      CSQC_OpKnifeEquip();
    else if (weapon_id == WEP_OPSAW)        CSQC_SawEquip();
    else if (weapon_id == WEP_PENGUIN)      CSQC_PenguinEquip();
    else if (weapon_id == WEP_DISPLACER)    CSQC_DispEquip();
    else if (weapon_id == WEP_JETPACK)      CSQC_JetEquip();
    else if (weapon_id == WEP_BGRAPPLE)     CSQC_BGrapEquip();
    else if (weapon_id == WEP_SNOWBALL)     CSQC_SnowballEquip();
    else if (weapon_id == WEP_CSHEGRENADE)  CSQC_CSHEGrenadeEquip();
    else if (weapon_id == WEP_DODMILLS)     CSQC_DodMillsEquip();
    else if (weapon_id == WEP_DODSTICK)     CSQC_DodStickEquip();
    else if (weapon_id == WEP_CSFLASHBANG)  CSQC_CSFlashbangEquip();
    else if (weapon_id == WEP_CSSMOKEGRENADE) CSQC_CSSmokeGrenadeEquip();
    else if (weapon_id == WEP_PAINTBALL)    CSQC_PaintballEquip();
    else if (weapon_id == WEP_HLGLOCK)      CSQC_HLGlockEquip();
    else if (weapon_id == WEP_HLEGON)       CSQC_EgonEquip();
    else if (weapon_id == WEP_BUTTERFLY)    CSQC_ButterflyEquip();
    else if (weapon_id == WEP_MELEE)        CSQC_MeleeEquip();
    else if (weapon_id == WEP_KATANA)       CSQC_KatanaEquip();
    else if (weapon_id == WEP_CFAUG)        CSQC_CFAugEquip();
    else if (weapon_id == WEP_CFFAMAS)      CSQC_CFFamasEquip();
    else if (weapon_id == WEP_CFMAC10)      CSQC_CFMac10Equip();
    else if (weapon_id == WEP_CFMP5)        CSQC_CFMp5Equip();
    else if (weapon_id == WEP_CFVECTOR)     CSQC_CFVectorEquip();
    else if (weapon_id == WEP_CFTYPE89)     CSQC_CFType89Equip();
    else if (weapon_id == WEP_CFUMP45)      CSQC_CFUmp45Equip();
    else if (weapon_id == WEP_CFM249)       CSQC_CFM249Equip();
    else if (weapon_id == WEP_CFAWM)        CSQC_CFAwmEquip();
    else if (weapon_id == WEP_CFKS23)       CSQC_CFKs23Equip();
    else if (weapon_id == WEP_CFM4)         CSQC_CFM4Equip();
    else if (weapon_id == WEP_CFMK23)       CSQC_CFMk23Equip();
    else if (weapon_id == WEP_CSUSP)        CSQC_CSUSPEquip();
    else if (weapon_id == WEP_CFGALIL)      CSQC_CFGalilEquip();
    else if (weapon_id == WEP_CFGLOCK)      CSQC_CFGlockEquip();
    else if (weapon_id == WEP_CFELITE)      CSQC_CFEliteEquip();
    else if (weapon_id == WEP_CFP228)       CSQC_CFP228Equip();
    else if (weapon_id == WEP_CFMSG90)      CSQC_CFMsg90Equip();
    else if (weapon_id == WEP_CFSG552)      CSQC_CFSG552Equip();
    else if (weapon_id == WEP_CFSL8)        CSQC_CFSl8Equip();
    else if (weapon_id == WEP_GRAVITYGUN)   CSQC_GravGunEquip();
    else if (weapon_id == WEP_CFC4)         CSQC_CFC4Equip();
    else if (weapon_id == WEP_CFM9)  CSQC_CFM9Equip();
    else if (weapon_id == WEP_CFREVOLVER)     CSQC_CFRevolverEquip();
    else if (weapon_id == WEP_CFBARRETT)        CSQC_CFBarrettEquip();
    else if (weapon_id == WEP_CFPSG1)      CSQC_CFPSG1Equip();
    else if (weapon_id == WEP_CFDDEAGLE)      CSQC_CFDdeagleEquip();
    else if (weapon_id == WEP_CFSPAS12)     CSQC_CFSPAS12Equip();
    else if (weapon_id == WEP_CFM700)  CSQC_CFM700Equip();
    else if (weapon_id == WEP_CFM3)         CSQC_CFM3Equip();
    else if (weapon_id == WEP_CFSCAR)      CSQC_CFScarEquip();
    else if (weapon_id == WEP_CFMAUSER)      CSQC_CFMauserEquip();
    else if (weapon_id == WEP_CFSVD)      CSQC_CFSVDEquip();

    // Prime the muzzle-smoke offset AFTER the equip ran, so the bone path
    // can key off the weapon_muzzle_bone the equip just set.
    CSQC_PrimeMuzzleSmokeOffsets(weapon_id);
};
