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
    if (self.slot_utility == weapon_id)
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
    // Mirror server's W_ClearWeaponBindings — without this the previous
    // weapon's debounce (e.g. scout's long firetime) carries onto the
    // new one and CSQC silently rejects fast follow-up shots while the
    // server happily registers them (no client sound/decal but real
    // server damage).
    self.attack_finished    = 0;
    self.altfire_finished   = 0;
    self.csqc_fire_guard    = 0;
    self.csqc_reload_guard  = 0;
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
    if (self.weapon == self.slot_utility)
    {
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
};

void() CSQC_PredictSelectPrevWeapon =
{
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
    if (self.weapon == self.slot_utility)
    {
        if (self.slot_melee)     { CSQC_PredictSelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { CSQC_PredictSelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { CSQC_PredictSelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.slot_utility)   { CSQC_PredictSelectWeapon(self.slot_utility);   return; }
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

// Forward declarations — fake-drop and dropped-weapon helpers call
// into each other across the file.  QC compiler is one-pass, so
// references to functions/consts defined below need declaring here.
void(entity w) dropped_weapon_list_add_csqc;
void(entity w) dropped_weapon_list_remove_csqc;
void() CSQC_PickupPredict_Expire;
const float PICKUP_PREDICT_TIMEOUT = 2.0;

// Fake drops — visual-only client entities rendered for the dropper
// during the 0.7s window before the server's weapon_become_solid wires
// the real CSQC SendEntity.  Linked list because death drops produce
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

// Size helper — matches server's drop bbox per weapon type.
void(float weapon_id, __inout vector mins, __inout vector maxs) CSQC_FakeDrop_Size =
{
    if (weapon_id == WEP_DEAGLE || weapon_id == WEP_PISTOL || weapon_id == WEP_357)
    {
        mins = '-12 -12 0';
        maxs = '12 12 24';
    }
    else
    {
        mins = '-16 -16 0';
        maxs = '16 16 32';
    }
};

// Mirror of sv_weapons.qc weapon_settle_think.  Polls the fake's
// velocity every 0.2s; once motion drops below 30 qu/s (or the 10s
// deadline hits), tracelines 32qu down and pitches/rolls the model
// flat against the floor normal.  Without this, at high ping the
// player sees an upright weapon frozen mid-toss for the whole
// ping-window before the real networked entity arrives pre-oriented.
void() CSQC_FakeDrop_SettleThink =
{
    vector flat_vel;
    vector floor_normal;
    float  yaw;

    flat_vel    = self.velocity;
    flat_vel_z  = 0;
    if ((fabs(self.velocity_z) > 30 || vlen(flat_vel) > 30)
        && time < self.weapon_settle_deadline)
    {
        self.nextthink = time + 0.2;
        return;
    }

    floor_normal = '0 0 1';
    traceline(self.origin, self.origin - '0 0 32', TRUE, self);
    if (trace_fraction < 1)
        floor_normal = trace_plane_normal;

    yaw = self.angles_y;
    if (floor_normal_z > 0.99)
    {
        self.angles = [0, yaw, 0];
    }
    else
    {
        vector fwd, rt;
        makevectors([0, yaw, 0]);
        fwd = v_forward;
        rt  = v_right;
        self.angles_x = -asin(floor_normal * fwd) * (180.0 / M_PI);
        self.angles_z =  asin(floor_normal * rt)  * (180.0 / M_PI);
        self.angles_y = yaw;
    }
};

// Core spawn used by both explicit drop (in front of view) and death-
// drop scatter (server-supplied origin/velocity).  wmodel comes from
// the caller so death drops don't depend on self.weapon_worldmodel
// (which is cleared by the time the death event lands).  slot is
// required so CSQC_CheckPickupTouches can predict-pickup the fake
// before the real networked entity arrives (~1.2s delay at sv_minping
// 999: 0.7s weapon_become_solid + one-way latency).
void(float weapon_id, float slot, string wmodel, vector spawn_origin,
     vector spawn_velocity, float expire_dur) CSQC_SpawnFakeDropAt =
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
    fd.avelocity = [random() * 600 - 300, random() * 600 - 300, random() * 600 - 300];
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

    // Match server's SOLID_NOT → SOLID_TRIGGER gate inside weapon_
    // become_solid: drop_ent is un-touchable for the first 0.7s.
    // Without this the dropper immediately predict-picks their own
    // toss, server denies, and CSQC rolls back 1 RTT later.
    fd.dropped_weapon_pickup_time = cltime + 0.7;

    // Settle-to-floor think — matches server's weapon_settle_think.
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
    else if (self.slot_utility   == weapon_id) slot = SLOT_UTILITY;

    makevectors(input_angles);
    vector spawn_origin   = self.origin + self.view_ofs + v_forward * 24;
    vector spawn_velocity = self.velocity + v_forward * 200 + '0 0 80';

    // Expire after: ping (network version appears) + ~0.75s (toss settles).
    float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
    ping_est = bound(0.05, ping_est, 1.0);

    CSQC_SpawnFakeDropAt(weapon_id, slot, wmodel, spawn_origin, spawn_velocity, ping_est + 0.75);
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
    else if (cur == self.slot_utility)
        self.slot_utility = WEP_NONE;

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

// Predraw for spinning dropped-weapon pickups (classic-Quake feel).
// Server flags the weapon via .dropped_spin; client rotates yaw from
// cltime so every client sees synchronized rotation without angle
// replication. 100 deg/sec = one revolution per 3.6 s (tuneable).
float() CSQC_DroppedWeapon_Predraw =
{
    self.angles_y = cltime * 100;
    addentity(self);
    return PREDRAW_NEXT;
};

void(float isnew) CSQC_DroppedWeapon_Update =
{
    self.dropped_weapon_id   = readbyte();
    self.dropped_weapon_slot = readbyte();
    vector new_origin;
    new_origin_x = readcoord();
    new_origin_y = readcoord();
    new_origin_z = readcoord();
    string mdl   = readstring();
    self.dropped_weapon_mag      = readbyte();
    self.dropped_weapon_ammo     = readbyte();
    self.dropped_weapon_silencer = readbyte();
    self.dropped_spin            = readbyte();
    // Settled angles from the server's weapon_settle_think trace — only
    // meaningful when dropped_spin is 0 (spin overrides yaw locally).
    vector new_angles;
    new_angles_x = readcoord();
    new_angles_y = readcoord();
    new_angles_z = readcoord();

    if (isnew)
    {
        self.classname = "csqc_dropped_weapon";
        self.solid     = SOLID_NOT;   // proximity-check manually, don't trigger-touch
        self.drawmask  = MASK_ENGINE;
        dropped_weapon_list_add_csqc(self);

        // Swap the matching fake drop (same weapon id) for this real
        // networked entity.  Without this the fake lives on its own
        // cltime-based expiry (ping + 0.75s), which at sv_minping 999
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

    // Attach / detach the rotation predraw based on the server's flag.
    // Changing the flag mid-life (e.g. by a different server snapshot)
    // flips behaviour correctly.
    if (self.dropped_spin)
        self.predraw = CSQC_DroppedWeapon_Predraw;
    else
    {
        self.predraw = __NULL__;
        // Inherit the settled pitch/yaw/roll the server's weapon_settle_
        // think computed from the floor normal — otherwise the real ent
        // renders flat at (0,0,0) and visibly jumps off the slope when
        // the fake drop is swapped out.
        self.angles = new_angles;
    }

    if (self.model != mdl)
        setmodel(self, mdl);
    // Match the fake drop's per-weapon hitbox so the fake→real handoff
    // doesn't also change the pickup-touch radius visibly.
    vector real_mins = '0 0 0';
    vector real_maxs = '0 0 0';
    CSQC_FakeDrop_Size(self.dropped_weapon_id, real_mins, real_maxs);
    setsize(self, real_mins, real_maxs);
    setorigin(self, new_origin);

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
        // after being hidden.  Clear the log latch so future pickups
        // are reported again.
        self.dropped_weapon_logged = 0;
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
         if (wep == WEP_AK47)            { self.mag_ak47 = mag;            self.ammo_ak47 = ammo;            }
    else if (wep == WEP_M4A1)            { self.mag_m4a1 = mag;            self.ammo_m4a1 = ammo;            self.m4a1_silenced = silencer; }
    else if (wep == WEP_CSAWP)           { self.mag_awp = mag;             self.ammo_awp = ammo;             }
    else if (wep == WEP_G3SG1)           { self.mag_g3sg1 = mag;           self.ammo_g3sg1 = ammo;           }
    else if (wep == WEP_CSM3)            { self.mag_m3 = mag;              self.ammo_m3 = ammo;              }
    else if (wep == WEP_CSMP5)           { self.mag_mp5 = mag;             self.ammo_mp5 = ammo;             }
    else if (wep == WEP_DOD98K)          { self.mag_98k = mag;             self.ammo_98k = ammo;             }
    else if (wep == WEP_FLAKSHOTGUN)     { self.mag_flakshotgun = mag;                                       }
    else if (wep == WEP_GAUSS)           {                                 self.ammo_gauss = ammo;           }
    else if (wep == WEP_GRENADELAUNCHER) { self.mag_grenadelauncher = mag;                                   }
    else if (wep == WEP_CROSSBOW)        { self.mag_crossbow = mag;        self.ammo_crossbow = ammo;        }
    else if (wep == WEP_HLEGON)          {                                 self.ammo_hlegon = ammo;          }
    else if (wep == WEP_HLRPG)           { self.mag_hlrpg = mag;           self.ammo_hlrpg = ammo;           }
    else if (wep == WEP_HLSHOTGUN)       { self.mag_shotgun = mag;         self.ammo_shotgun = ammo;         }
    else if (wep == WEP_HLSMG)           { self.mag_hlsmg = mag;           self.ammo_hlsmg = ammo;           }
    else if (wep == WEP_M249)            { self.mag_m249 = mag;            self.ammo_m249 = ammo;            }
    else if (wep == WEP_REBAR)           { self.mag_rebar = mag;                                             }
    else if (wep == WEP_SCOUT)           { self.mag_scout = mag;           self.ammo_scout = ammo;           }
    else if (wep == WEP_CSUSP)           { self.mag_csusp = mag;           self.ammo_csusp = ammo;           self.csusp_silenced = silencer; }
    else if (wep == WEP_DEAGLE)          { self.mag_deagle = mag;          self.ammo_deagle = ammo;          }
    else if (wep == WEP_GLOCK)           { self.mag_glock = mag;           self.ammo_glock = ammo;           }
    else if (wep == WEP_357)             { self.mag_357 = mag;             self.ammo_357 = ammo;             }
    else if (wep == WEP_HLGLOCK)         { self.mag_hlglock = mag;         self.ammo_hlglock = ammo;         }
    else if (wep == WEP_PISTOL)          { self.mag_pistol = mag;          self.ammo_pistol = ammo;          }
    else if (wep == WEP_HLGRENADE)       {                                 self.ammo_hlgrenade = ammo;       }
    // Melee (WRENCH/KNIFE/HLCROWBAR) — no ammo fields.
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
float(float slot) CSQC_IsSlotPredictedFilled =
{
    entity w = dropped_weapon_list;
    float  i = 0;
    while (w)
    {
        if (w.dropped_weapon_predicted_taken
            && w.nextthink > time
            && w.dropped_weapon_slot == slot)
            return TRUE;
        w = w.dropped_weapon_next;
        i = i + 1;
        if (i > 4096)
        {
            dprint("CSQC_IsSlotPredictedFilled: cycle in dropped_weapon_list\n");
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
    if (slot == SLOT_PRIMARY   && (self.slot_primary   || CSQC_IsSlotPredictedFilled(SLOT_PRIMARY)))   return;
    if (slot == SLOT_SECONDARY && (self.slot_secondary || CSQC_IsSlotPredictedFilled(SLOT_SECONDARY))) return;
    if (slot == SLOT_MELEE     && (self.slot_melee     || CSQC_IsSlotPredictedFilled(SLOT_MELEE)))     return;
    if (slot == SLOT_UTILITY   && (self.slot_utility   || CSQC_IsSlotPredictedFilled(SLOT_UTILITY)))   return;

    // Copy ammo BEFORE equip so the equip path sees correct mag/reserve
    // for HUD redraw (matches server where pickupcopy precedes
    // W_SelectWeapon in weapon_touch, lines 906-957).
    CSQC_ApplyPickupAmmo(wep, w.dropped_weapon_mag, w.dropped_weapon_ammo,
                         w.dropped_weapon_silencer);

    // Assign slot. CSQC dispatches equip by weapon id (CSQC_WeaponEquip),
    // so we don't need function pointers like the server does.
         if (slot == SLOT_PRIMARY)   self.slot_primary   = wep;
    else if (slot == SLOT_SECONDARY) self.slot_secondary = wep;
    else if (slot == SLOT_MELEE)     self.slot_melee     = wep;
    else if (slot == SLOT_UTILITY)   self.slot_utility   = wep;

    // Auto-equip — exact mirror of server lines 942-957
    float should_equip = FALSE;
    if (self.weapon == WEP_NONE)                           should_equip = TRUE;
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

    entity w = dropped_weapon_list;
    float  i = 0;
    while (w)
    {
        entity next_w = w.dropped_weapon_next;   // safe against list unlink
        if (!w.dropped_weapon_predicted_taken
            && cltime >= w.dropped_weapon_pickup_time)
        {
            // ~40 unit pickup radius matches the stock Quake-style
            // trigger+player bbox overlap threshold closely enough for
            // prediction purposes — a small mis-predict just means the
            // server's touch fires a frame later, no visible artefact.
            if (vlen(self.origin - w.origin) < 40)
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
    case 4:
        if (self.slot_utility)
            CSQC_PredictSelectWeapon(self.slot_utility);
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
    case 10:  // noclip toggle — predict instantly
        if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
            self.pm_movetype = PM_MOVETYPE_NORMAL;
        else
            self.pm_movetype = PM_MOVETYPE_NOCLIP;
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

    if (predicted_player.weapon_uses_sequences)
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
        if (predicted_player.wep_anim_start > 0)
            elapsed = max(0, cltime - predicted_player.wep_anim_start);
        else
            elapsed = cltime;
        csqc_viewmodel_ent.frame    = seq;
        csqc_viewmodel_ent.frame1time = elapsed;
        csqc_viewmodel_ent.frame2   = 0;
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
    self.weapon_uses_sequences = FALSE;

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
    else if (weapon_id == WEP_HLSMG)        CSQC_HLSMGEquip();
    else if (weapon_id == WEP_HLRPG)        CSQC_RPGEquip();
    else if (weapon_id == WEP_HLGRENADE)    CSQC_HLGrenadeEquip();
    else if (weapon_id == WEP_HLGLOCK)      CSQC_HLGlockEquip();
    else if (weapon_id == WEP_HLEGON)       CSQC_EgonEquip();
    else if (weapon_id == WEP_CSUSP)        CSQC_CSUSPEquip();
};
