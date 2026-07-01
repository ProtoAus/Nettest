// ============================================================
//  server/sv_weapons.qc  -  Core weapon system
//  Damage helpers, weapon pickup touch, weapon slot management.
// ============================================================

// Forward declarations
void(entity player) PM_SyncPredictionProxy;  // defined in sv_player.qc
void(entity player) Player_VisualProxy_DetachAsCorpse;  // defined in sv_player.qc
void() W_DeagleEquip;         // defined in wpn_deagle.qc
void() W_DeagleDrop;          // defined in wpn_deagle.qc
void() W_KnifeEquip;
void() W_KnifeDrop;
void() W_ButterflyEquip;
void() W_ButterflyDrop;
void() W_MeleeEquip;
void() W_MeleeDrop;
void() W_KatanaEquip;
void() W_KatanaDrop;
void() W_CFAugEquip;
void() W_CFAugDrop;
void() W_CFFamasEquip;
void() W_CFFamasDrop;
void() W_CFMac10Equip;
void() W_CFMac10Drop;
void() W_CFC4Equip;
void() W_CFC4Drop;
void() W_AK47Equip;
void() W_AK47Drop;
void() W_HDAK47Equip;
void() W_HDAK47Drop;
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
void() W_GlockEquip;
void() W_GlockDrop;
void() W_G3SG1Equip;
void() W_G3SG1Drop;
void() W_HLSMGEquip;
void() W_HLSMGDrop;
void() W_RPGEquip;
void() W_RPGDrop;
void() W_HLGrenadeEquip;
void() W_HLGrenadeDrop;
void() W_SnowballEquip;
void() W_SnowballDrop;
void() W_CSHEGrenadeEquip;
void() W_CSHEGrenadeDrop;
void() W_CSFlashbangEquip;
void() W_CSFlashbangDrop;
void() W_CSSmokeGrenadeEquip;
void() W_CSSmokeGrenadeDrop;
void() W_PaintballEquip;
void() W_PaintballDrop;
void() W_HLGlockEquip;
void() W_HLGlockDrop;
void() W_EgonEquip;
void() W_EgonDrop;
void() W_CFM9Equip;
void() W_CFM9Drop;
void() weapon_cfm9;
void() W_CFRevolverEquip;
void() W_CFRevolverDrop;
void() weapon_cfrevolver;
void() W_CFBarrettEquip;
void() W_CFBarrettDrop;
void() weapon_cfbarrett;
void() W_CFPSG1Equip;
void() W_CFPSG1Drop;
void() weapon_cfpsg1;
void() W_CFDdeagleEquip;
void() W_CFDdeagleDrop;
void() weapon_cfddeagle;
void() W_CFSPAS12Equip;
void() W_CFSPAS12Drop;
void() weapon_cfspas12;
void() W_CFM700Equip;
void() W_CFM700Drop;
void() weapon_cfm700;
void() W_CFM3Equip;
void() W_CFM3Drop;
void() weapon_cfm3;
void() W_CFScarEquip;
void() W_CFScarDrop;
void() weapon_cfscar;
void() W_CFMauserEquip;
void() W_CFMauserDrop;
void() weapon_cfmauser;
void() W_CFSVDEquip;
void() W_CFSVDDrop;
void() weapon_cfsvd;
void() W_CFMp5Equip;
void() W_CFMp5Drop;
void() weapon_cfmp5;
void() W_CFVectorEquip;
void() W_CFVectorDrop;
void() weapon_cfvector;
void() W_CFType89Equip;
void() W_CFType89Drop;
void() weapon_cftype89;
void() W_CFUmp45Equip;
void() W_CFUmp45Drop;
void() weapon_cfump45;
void() W_CFM249Equip;
void() W_CFM249Drop;
void() weapon_cfm249;
void() W_CFAwmEquip;
void() W_CFAwmDrop;
void() weapon_cfawm;
void() W_CFKs23Equip;
void() W_CFKs23Drop;
void() weapon_cfks23;
void() W_CFM4Equip;
void() W_CFM4Drop;
void() weapon_cfm4;
void() W_CFMk23Equip;
void() W_CFMk23Drop;
void() weapon_cfmk23;
void() W_CSUSPEquip;
void() W_CSUSPDrop;
void() weapon_csusp;
void() W_CFGalilEquip;  void() W_CFGalilDrop;  void() weapon_cfgalil;
void() W_CFGlockEquip;  void() W_CFGlockDrop;  void() weapon_cfglock;
void() W_CFEliteEquip;  void() W_CFEliteDrop;  void() weapon_cfelite;
void() W_CFP228Equip;   void() W_CFP228Drop;   void() weapon_cfp228;
void() W_CFMsg90Equip;  void() W_CFMsg90Drop;  void() weapon_cfmsg90;
void() W_CFSG552Equip;  void() W_CFSG552Drop;  void() weapon_cfsg552;
void() W_CFSl8Equip;    void() W_CFSl8Drop;    void() weapon_cfsl8;
void() W_GravGunEquip;  void() W_GravGunDrop;  void() weapon_gravitygun;
void() weapon_deagle;
void() weapon_m4a1;
void() weapon_ak47;
void() weapon_hdak47;
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
void() weapon_glock;
void() weapon_g3sg1;
void() weapon_hlsmg;
void() weapon_hlrpg;
void() weapon_hlgrenade;
void() weapon_snowball;
void() weapon_slingshot;
void() weapon_cshegrenade;
void() weapon_csflashbang;
void() weapon_cssmokegrenade;
void() weapon_paintball;
void() weapon_hlglock;
void() weapon_hlegon;
void() weapon_butterfly;
void() weapon_melee;
void() weapon_katana;
void() weapon_cfaug;
void() weapon_cffamas;
void() weapon_cfmac10;
void() weapon_cfc4;
void() PlayerSpawn;           // defined in sv_player.qc
void(float) W_SelectWeapon;   // defined later in this file
void() weapon_become_solid;   // defined later in this file
void() weapon_settle_think;   // defined later in this file
void() W_UtilityRefreshSlotBinding; // defined later in this file
float(float) W_UtilityWeaponSelectable; // defined in sh_wpn_snowball.qc
float(float) W_UtilityWeaponPickup;
float(entity, float) W_UtilityEntityHasWeapon;
float(float) W_UtilityPlayerHasWeapon;
float(float) W_UtilityNextCarried;
float(float, float) W_UtilityCycleCarried;
void() W_PhysDropThink;       // defined later in this file
float(float) W_PhysDropAllowed; // defined later in this file
void(entity, float) W_PhysDropStart; // defined later in this file
float() RoundToss_NextThinkInterval; // defined later in this file
float(entity, float) dropped_weapon_SendEntity;  // defined later in this file
void() W_DropAllWeaponsOnDeath;  // defined later in this file
void(entity player, float wep) W_SlotAmmo_LoadLegacy;
void(entity player, float wep) W_SlotAmmo_SaveLegacy;
void(entity player) W_SlotAmmo_SaveCurrent;
void(entity drop, entity player, float wep) W_SlotAmmo_CopyPlayerToDrop;
void(entity player, entity drop) W_SlotAmmo_CopyDropToPlayer;
void(entity player, float wep) W_SlotAmmo_ClearForWeapon;

// Global set by W_DropCurrentWeapon before calling the slot drop function.
// The drop function reads this to know which entity to populate.
entity weapon_drop_target;

// Per-entity fail-safe: even if a dropped weapon is perched on a fragile
// slope and never quite stops bouncing, force it to settle by this time
// so we don't keep polling forever.
.float weapon_settle_deadline;

// Absolute server time at which a dropped weapon transitions from the
// toss phase (SOLID_NOT, players can't grab it) to the settled-trigger
// phase. Set to (spawn_time + WEAPON_DROP_PICKUP_DELAY) for player
// drops. Driven
// by weapon_become_solid's dual-phase logic — while time < this value
// the function just bumps SendFlags and reschedules; once crossed it
// finalises the solid state and hands off to weapon_settle_think.
.float weapon_solid_time;
.float weapon_round_toss;

// Physics-drop startup probe. If an ODE body fails to start (for example a
// model cannot produce a usable physics mesh), the server origin stays frozen
// while CSQC extrapolates falling motion. Probe once and fall back to TOSS.
.vector weapon_physdrop_last_origin;
.float weapon_physdrop_probe_time;
.float weapon_physdrop_rest_start;
// Saved tight-ODE bbox while a trace-time inflate is in flight.  Set by
// W_PhysDropsExpandTraceBboxes, consumed by the matching Restore — see
// the helpers in this file.
.vector weapon_physdrop_trace_mins_save;
.vector weapon_physdrop_trace_maxs_save;
.float  weapon_physdrop_trace_inflated;
// Server-time of first "embedded in BSP" detection on this entity, or
// 0 when the entity is currently clear. W_PhysDropStuckDuration uses
// this to surface "stuck for N seconds" without per-tick tracebox cost.
// Used by W_PhysDropThink + PhysProp_VoidWatchdog to despawn props
// that ODE can't free.
.float phys_stuck_since;

// ============================================================
//  Map weapon registration — call from weapon_*() spawn functions
//  Records origin + spawn function so the weapon can be recreated on round reset.
// ============================================================

float sv_debug_weapon_spawning;   // TRUE during debug weapon spawn — skips map registration

// Snap a phys-eligible map weapon to the surface immediately below it,
// using the entity's pickup bbox (sized by weapon_*() via setsize). Adds
// 1 u clearance so SOLID_PHYSICS_TRIMESH can activate without ODE
// detecting mesh-below-bbox penetration and ejecting the body upward —
// the source of the bounce-on-spawn cascade at round-restart with
// sv_phys_drops on.  droptofloor() snaps absmin to the floor, but the
// trimesh used by ODE is the model mesh (not the bbox) and weapon meshes
// often have geometry below the bbox bottom.  Returns TRUE on success;
// FALSE if no floor was found within the search distance.
//
// Trace distance is generous (256 u) because debug-spawn places weapons
// in a grid in front of the player — the player's origin can be elevated
// above the local floor (stairs, ramps, stack of crates) and the spawn
// grid extends out into space where the ground sits well below the
// player's feet.  64 u was too short and left those weapons in mid-air
// at round-restart, falling under gravity instead of snapping flat.
float() W_PhysDropGroundSnap =
{
    vector probe_start = self.origin;
    vector probe_end   = self.origin - '0 0 256';
    tracebox(probe_start, self.mins, self.maxs, probe_end, MOVE_NORMAL, self);
    if (trace_fraction >= 1)
        return FALSE;

    // Rest the EVENTUAL ODE collision shape on the floor — NOT the pickup bbox.
    // The trace above rested the model's pickup bbox (feet at mins_z) on the floor,
    // but W_PhysDropEnable's BOX geom is CENTRED on the origin (half-height bbox_z),
    // so leaving the origin at floor+1 buried the centred box ~bbox_z units and ODE
    // ejected the weapon violently ("map weapons fly all over on spawn").  Lift the
    // origin by the box half-height so the centred box settles ON the floor.
    float new_origin_z;
    if (cvar("sv_physprop_weapon_geom") > 0.5)
    {
        // Trimesh collides as the mesh; the traced model bbox already rests it on
        // the floor — a 1 u clearance is enough.
        new_origin_z = trace_endpos_z + 1;
    }
    else
    {
        float bz = cvar("sv_physprop_weapon_bbox_z");
        if (bz <= 0) bz = max(fabs(self.mins_z), fabs(self.maxs_z));
        float floor_z = trace_endpos_z + self.mins_z;   // bottom of the traced bbox = floor
        new_origin_z  = floor_z + bz + 1;                // centred box bottom 1 u above floor
    }

    vector rest = trace_endpos;
    rest_z = new_origin_z;
    setorigin(self, rest);
    self.velocity  = '0 0 0';
    self.avelocity = '0 0 0';
    return TRUE;
};

// True only when the entity's CENTER is inside solid BSP. We use
// pointcontents (not tracebox-startsolid) because the latter trips on
// a resting prop's bbox skimming the floor — that produced a "weapons
// fly into the air after landing" loop in the first cut of this
// system. Embedded-against-a-wall cases reliably put the center in
// solid, so this catches the cases that matter.
float(entity ent) W_PhysDropIsEmbedded =
{
    // Test the bbox CENTRE, not the entity origin. Models whose origin sits at
    // the feet (e.g. filecabinet, mins_z 0) read CONTENT_SOLID the instant they
    // rest on the floor — pointcontents(origin) is at the floor surface — and
    // the stuck-detector would despawn them after ~5 s. The centre is the right
    // "is the body buried in BSP" probe; for centred props (barrel/can/weapon
    // drops) mins_z+maxs_z ≈ 0 so this is a no-op.
    return pointcontents(ent.origin + '0 0 1' * ((ent.mins_z + ent.maxs_z) * 0.5)) == CONTENT_SOLID;
};

// "How long has this entity been embedded for?" detector. Returns
// elapsed seconds, with the timer self-resetting whenever the prop
// becomes clear. Caller picks a despawn threshold (e.g. 2s for drops,
// 5s for barrels). Stores state on .phys_stuck_since.
float(entity ent) W_PhysDropStuckDuration =
{
    if (!W_PhysDropIsEmbedded(ent))
    {
        ent.phys_stuck_since = 0;
        return 0;
    }
    if (ent.phys_stuck_since == 0)
    {
        ent.phys_stuck_since = time;
        return 0;
    }
    return time - ent.phys_stuck_since;
};

// Output of W_PhysDropFindClearBackstep. Read by caller after the
// helper returns TRUE.
vector w_physdrop_clear_pos;

// Pre-spawn back-step search. Given a starting position that may be
// inside a wall (e.g. player drops while facing a wall), step BACK
// along -dir in 4-unit increments until a clear position is found.
// Returns TRUE + sets w_physdrop_clear_pos if found within 64u.
// Returns FALSE when no clear spot exists in that range — caller
// should abort the drop and tell the player.
//
// Uses pointcontents only (not tracebox) because the bbox isn't fully
// known until the drop_func runs and sets it. The 4-unit increment is
// fine-grained enough that the prop almost always lands in clear
// space inside the player's first body-radius from the wall.
float(vector start_pos, vector dir) W_PhysDropFindClearBackstep =
{
    // Already clear?
    if (pointcontents(start_pos) != CONTENT_SOLID)
    {
        w_physdrop_clear_pos = start_pos;
        return TRUE;
    }

    vector back = -1 * normalize(dir);
    float step;
    for (step = 4; step <= 64; step = step + 4)
    {
        vector cand = start_pos + back * step;
        if (pointcontents(cand) != CONTENT_SOLID)
        {
            w_physdrop_clear_pos = cand;
            return TRUE;
        }
    }
    w_physdrop_clear_pos = start_pos;
    return FALSE;
};

void(void() spawn_func) W_RegisterMapWeapon =
{
    if (sv_debug_weapon_spawning)
        return;

    // Record the spec (origin, angles, spawn function) on the entity up
    // front — even if mp_nomapweapons is currently on.  Keeping the
    // entity alive (just hidden) means flipping the cvar off later can
    // re-run map_weapon_spawn to bring the weapon back exactly where the
    // mapper placed it.  If we instead remove()'d, the spawn_func pointer
    // would be lost and the weapon could never respawn until a map change.
    if (!self.map_weapon)
    {
        self.map_weapon_origin = self.origin;
        self.map_weapon_angles = self.angles;
    }

    self.map_weapon = TRUE;
    self.map_weapon_spawn = spawn_func;
    W_SlotAmmo_SaveLegacy(self, self.weapon);
    W_SlotAmmo_CopyPlayerToDrop(self, self, self.weapon);

    // mp_nomapweapons: hide the entity (no model, no collision, no
    // think).  The bookkeeping above still stands so
    // W_RespawnMapWeapons can revive us on round restart when the
    // cvar is off.  KEEP SendEntity wired and bump SendFlags so the
    // engine broadcasts the empty-model state once — without that,
    // clients hold their last-known visible copy of the weapon and
    // the visual diverges from the server.  Idle resends with the
    // same empty payload after that are cheap; the alternative
    // (null SendEntity, hope the client guesses) is the source of
    // the "mp_nomapweapons feels inconsistent" reports.
    if (cvar("mp_nomapweapons") > 0)
    {
        if (self.movetype == MOVETYPE_PHYSICS || self.weapon_physdrop_sleeping)
            physics_enable(self, FALSE);
        self.weapon_physdrop_sleeping = FALSE;
        self.weapon_physdrop_rest_start = 0;
        self.weapon_round_toss = FALSE;
        setmodel(self, "");
        self.modelindex = 0;
        self.solid      = SOLID_NOT;
        self.movetype   = MOVETYPE_NONE;
        self.dimension_solid = dimension_default;
        self.dimension_hit   = dimension_default;
        // Wire SendEntity (idempotent if already wired) and force a
        // resend so the empty-model payload reaches every client.
        self.pvsflags   = PVSF_NOREMOVE;
        self.SendEntity = dropped_weapon_SendEntity;
        self.SendFlags |= 1;
        self.think      = __NULL__;
        self.nextthink  = 0;
        return;
    }

    // Snap to the floor at spawn time. W_RespawnMapWeapons does the
    // same on round restart, which is why round-2+ weapons appeared
    // grounded while the round-1 (initial map load) ones floated.
    //
    // Branch the snap on whether ODE is about to take over: phys-drop
    // eligible weapons get the mesh-aware tracebox + 1 u clearance so
    // SOLID_PHYSICS_TRIMESH activates without penetration; everything
    // else uses droptofloor() (engine TOSS settles any residual).
    float will_phys_drop = (cvar("sv_phys_drops") > 0
        && Weapon_PhysDropEligible(self.weapon)
        && cvar("sv_ode_loaded") > 0
        && W_PhysDropAllowed(self.weapon));

    if (will_phys_drop)
    {
        if (!W_PhysDropGroundSnap())
        {
            // Mapper placed weapon in the void — fall back to a
            // velocity-driven engine TOSS so it lands somewhere.
            self.velocity = '0 0 -200';
        }
    }
    else
    {
        self.velocity = '0 0 -100';
        if (!droptofloor())
            self.velocity = '0 0 -200';
    }

    // Enable CSQC replication for pickup prediction. Unlike player-
    // dropped weapons, map weapons are pickup-ready immediately, so we
    // wire SendEntity here rather than in weapon_become_solid.
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = dropped_weapon_SendEntity;
    self.SendFlags = 1;
    self.weapon_round_toss = TRUE;

    if (will_phys_drop)
    {
        // Map weapons are already floor-snapped above; start them as quiet
        // ODE bodies so shooting/using them can wake and move them.
        // (Snap helper already zeroed velocity/avelocity; left here as
        // defence-in-depth for any future caller that lands here without
        // going through W_PhysDropGroundSnap.)
        self.owner = world;
        self.velocity = '0 0 0';
        self.avelocity = '0 0 0';
        W_PhysDropStart(self, 0);
        return;
    }

    // Run settle_think to bump SendFlags while the engine TOSS physics still
    // has residual motion (from droptofloor's fallback velocity or if it
    // failed). Once motion stops, settle keeps the pickup upright.
    self.weapon_settle_deadline = time + 10;
    self.think     = weapon_settle_think;
    self.nextthink = time + RoundToss_NextThinkInterval();
};

// Respawn all map weapons — called from RoundRestart
void() W_RespawnMapWeapons =
{
    entity e, next, saved;
    float  strip_map_weapons = (cvar("mp_nomapweapons") > 0);

    e = nextent(world);
    while (e)
    {
        next = nextent(e);

        if (e.classname != "player" && e.classname != "pm_csqc_proxy"
            && e.weapon && e.weapon != WEP_NONE)
        {
            if (e.map_weapon)
            {
                saved = self;
                self = e;
                if (strip_map_weapons)
                {
                    // mp_nomapweapons on — hide the entity but keep all
                    // map_weapon bookkeeping (origin/angles/spawn_func)
                    // intact so a later round can revive it verbatim.
                    // Mirrors the hide path in W_RegisterMapWeapon —
                    // KEEPS SendEntity + bumps SendFlags so clients get
                    // the empty-model payload broadcast (otherwise CSQC
                    // holds the last-known visible state and the panel
                    // looks like it's still there).
                    if (self.movetype == MOVETYPE_PHYSICS || self.weapon_physdrop_sleeping)
                        physics_enable(self, FALSE);
                    self.weapon_physdrop_sleeping = FALSE;
                    self.weapon_physdrop_rest_start = 0;
                    self.weapon_round_toss = FALSE;
                    setmodel(self, "");
                    self.modelindex = 0;
                    self.solid      = SOLID_NOT;
                    self.movetype   = MOVETYPE_NONE;
                    self.dimension_solid = dimension_default;
                    self.dimension_hit   = dimension_default;
                    self.pvsflags   = PVSF_NOREMOVE;
                    self.SendEntity = dropped_weapon_SendEntity;
                    self.SendFlags |= 1;
                    self.think      = __NULL__;
                    self.nextthink  = 0;
                }
                else
                {
                    // Reset to original state.  Works for both "was live"
                    // and "was hidden last round" — the nested
                    // W_RegisterMapWeapon call inside map_weapon_spawn
                    // sees the cvar is off and re-wires model/SendEntity/
                    // think exactly like first-time spawn.
                    setorigin(self, self.map_weapon_origin);
                    self.angles = self.map_weapon_angles;
                    self.map_weapon_spawn();     // re-runs weapon_ak47() etc.
                    // Non-physics spawns keep the old fallback floor-snap.
                    // Physics spawns have already been floor-snapped and
                    // handed to ODE by W_RegisterMapWeapon.
                    if (self.movetype != MOVETYPE_PHYSICS)
                    {
                        self.velocity = '0 0 -100';
                        if (!droptofloor())
                            self.velocity = '0 0 -200';
                    }
                }
                self = saved;
            }
            else
            {
                // Remove dropped weapons
                if (e.movetype == MOVETYPE_PHYSICS)
                    physics_enable(e, FALSE);
                remove(e);
            }
        }

        e = next;
    }
};

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
//  Hitgroup system — bone-based damage multipliers
//  Uses MOVE_HITMODEL to trace against HLMDL hitboxes.
//  trace_bone_id is 1-based (0 = unknown).
// ============================================================

// W_BoneToHitgroup + W_HitgroupDamageMultiplier moved to shared/sh_weapon_logic.qc
// so CSQC can call them too (needed for predicted-death's lethality math).
// They're pure functions of trace_ent + bone_id — work identically on either side.

string(float hitgroup) W_HitgroupName =
{
    switch (hitgroup)
    {
    case HITGROUP_HEAD:     return "head";
    case HITGROUP_CHEST:    return "chest";
    case HITGROUP_STOMACH:  return "stomach";
    case HITGROUP_LEFTARM:  return "left arm";
    case HITGROUP_RIGHTARM: return "right arm";
    case HITGROUP_LEFTLEG:  return "left leg";
    case HITGROUP_RIGHTLEG: return "right leg";
    default:                return "body";
    }
};

// Temporarily expand every alive player's bbox by sv_hitbox_expand so weapon
// traces (MOVE_HITMODEL) can reach outstretched limbs.  Movement is
// unaffected: pmove uses the PM_MINS/PM_MAXS constants directly, not
// self.mins/self.maxs — so player-vs-player collision stays at the
// true movement hull.
//
// Z is expanded too (was X+Y only).  Without it, ducking players —
// whose duck-hull caps at PM_DUCK_MAXS_z = 18u above origin — had any
// head-bone above that height culled before MOVE_HITMODEL even reached
// the per-bone test.  cl_debug_hbexpand 1 made this visible.  Bigger
// bbox is purely an early-out / cull volume; the actual hit decision
// is per-bone, so expanding can only add forgiveness, never produce
// false hits above/below the real hitboxes.
//
// Must be paired with W_PlayersRestoreHitboxes after the trace(s).
// Lag comp still works because we're expanding the real player entity
// (not a separate proxy); MOVE_LAGGED rewinds origin and the expanded
// bbox moves with it.
//
// Expand/restore use delta math (read current mins/maxs, shift, write back)
// so we don't need to know the normal vs ducking hull values here.
void() W_PlayersExpandHitboxes =
{
    float expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.solid == SOLID_SLIDEBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x -= expand; mn_y -= expand; mn_z -= expand;
            mx_x += expand; mx_y += expand; mx_z += expand;
            setsize(p, mn, mx);
        }
        p = p.player_chain_next;
    }
};

void() W_PlayersRestoreHitboxes =
{
    float expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.solid == SOLID_SLIDEBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x += expand; mn_y += expand; mn_z += expand;
            mx_x -= expand; mx_y -= expand; mx_z -= expand;
            setsize(p, mn, mx);
        }
        p = p.player_chain_next;
    }
};

// Phys-drop bbox bookends — split traceline AABB from the ODE collision
// shape.  ODE keeps a tight gun-shaped box (so dropped guns rest on the
// silhouette), but hitscan needs a larger AABB to catch the rotated mesh
// at any orientation.  Walk every phys-drop, swap .mins/.maxs to the
// inflated traceline volume just before the trace, restore right after.
//
// Safe vs ODE because the engine compares cached vs current mins/maxs
// at the next physics step (com_phys_ode.c:2155-2167) — destroying and
// recreating the geom (and losing velocity) if they differ.  We restore
// synchronously inside the same QC frame before ODE's next tick, so
// ODE never observes the inflated size.
void() W_PhysDropsExpandTraceBboxes =
{
    float tx = cvar("sv_physprop_weapon_trace_bbox_x");
    float ty = cvar("sv_physprop_weapon_trace_bbox_y");
    float tz = cvar("sv_physprop_weapon_trace_bbox_z");
    if (tx <= 0 || ty <= 0 || tz <= 0) return;

    entity e = nextent(world);
    while (e)
    {
        if (e.weapon
            && (e.solid == SOLID_PHYSICS_BOX || e.solid == SOLID_PHYSICS_TRIMESH))
        {
            // Stash the live ODE size so restore is exact even if
            // multiple traces stack within one frame (they won't, but
            // delta math via cvar would drift if cvars change mid-shot).
            e.weapon_physdrop_trace_mins_save = e.mins;
            e.weapon_physdrop_trace_maxs_save = e.maxs;
            setsize(e, [-tx, -ty, -tz], [tx, ty, tz]);
            e.weapon_physdrop_trace_inflated = TRUE;
        }
        e = nextent(e);
    }
};

void() W_PhysDropsRestoreTraceBboxes =
{
    entity e = nextent(world);
    while (e)
    {
        if (e.weapon_physdrop_trace_inflated)
        {
            setsize(e, e.weapon_physdrop_trace_mins_save,
                       e.weapon_physdrop_trace_maxs_save);
            e.weapon_physdrop_trace_inflated = FALSE;
        }
        e = nextent(e);
    }
};

// Send the server's view of a target's hitbox state to the shooter.
// The client creates a ghost entity from this and draws orange hitbox wireframes.
// Mode 1 = per-shot snapshot (this function). Mode 2 = continuous, handled
// in sv_main.qc's StartFrame. Wire format is identical so the client parser
// is a single path.
void(entity target) W_SendServerHitboxes =
{
    if (cvar("sv_debug_hitboxes") != 1)
        return;
    if (!target || target.classname != "player")
        return;

    msg_entity = self;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_SERVER_HITBOXES);
    WriteByte(MSG_ONE, num_for_edict(target));
    WriteShort(MSG_ONE, target.modelindex);
    WriteCoord(MSG_ONE, target.origin_x);
    WriteCoord(MSG_ONE, target.origin_y);
    WriteCoord(MSG_ONE, target.origin_z);
    WriteFloat(MSG_ONE, target.angles_x);
    WriteFloat(MSG_ONE, target.angles_y);
    WriteFloat(MSG_ONE, target.angles_z);
    WriteByte(MSG_ONE, target.frame);
    WriteByte(MSG_ONE, target.baseframe);
    WriteByte(MSG_ONE, target.basebone);
    WriteFloat(MSG_ONE, target.frame1time);
    WriteFloat(MSG_ONE, target.baseframe1time);
    WriteFloat(MSG_ONE, target.subblendfrac);
    WriteFloat(MSG_ONE, target.subblend2frac);
    WriteFloat(MSG_ONE, target.bonecontrol1);
    WriteFloat(MSG_ONE, target.bonecontrol2);
    WriteFloat(MSG_ONE, target.bonecontrol3);
    WriteFloat(MSG_ONE, target.bonecontrol4);
    WriteByte(MSG_ONE, 1); // mode: 1 = per-shot snapshot
};

// ============================================================
//  W_WeaponTraceLine
//  Lag-compensated traceline wrapper used by melee and hitscan.
// ============================================================

void(vector src, vector end) W_WeaponTraceLine =
{
    // No MOVE_LAGGED: our QC ring buffer (sv_lagcomp.qc) has already
    // rewound every other player to the shooter's view-time before
    // this trace runs. Passing the engine flag would trigger a second,
    // independent rewind on top of ours.
    float saved_dim_hit = self.dimension_hit;
    self.dimension_hit = saved_dim_hit | PHYSDROP_DIM;
    Lagcomp_TraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    self.dimension_hit = saved_dim_hit;
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

// Inspect trace_ent and return an IMPACT_MAT_* code so CSQC can pick the
// right particle effect per surface. Players → flesh, func_breakable →
// material from .style, anything else → default (concrete-dust look).
float(entity hit) W_ClassifyImpactMaterial =
{
    if (hit && hit.classname == "player")
        return IMPACT_MAT_FLESH;
    if (hit && hit.classname == "func_breakable")
    {
        float s = hit.style;
        if (s == BREAKABLE_FLESH)                                         return IMPACT_MAT_FLESH;
        // GLASS + UNBREAKABLE_GLASS share the glass impact look —
        // the unbreakable variant takes the same FX, just doesn't
        // actually break.
        if (s == BREAKABLE_GLASS || s == BREAKABLE_UNBREAKABLE_GLASS)     return IMPACT_MAT_GLASS;
        // WOOD + TILE share the wood impact look (TILE aliases wood
        // for assets per the user spec).
        if (s == BREAKABLE_WOOD || s == BREAKABLE_TILE)                   return IMPACT_MAT_WOOD;
        // METAL + COMPUTER share the metal impact look.
        if (s == BREAKABLE_METAL || s == BREAKABLE_COMPUTER)              return IMPACT_MAT_METAL;
        // CINDER and ROCKS fall through to IMPACT_MAT_DEFAULT
        // (concrete-dust) below — that's the right look.
    }
    // Physics props and physics weapon drops — sparks + metal ric, no decal.
    if (hit && ((hit.classname == "phys_barrel" || hit.classname == "phys_can")
        || (hit.weapon && (hit.movetype == MOVETYPE_PHYSICS || hit.weapon_physdrop_sleeping))))
        return IMPACT_MAT_METAL_NODECAL;
    return IMPACT_MAT_DEFAULT;
};

// Send bullet impact effect to all players EXCEPT the shooter.
// The shooter sees their own predicted impact instantly.
void(vector pos) W_ImpactEffect =
{
    if (pointcontents(pos + trace_plane_normal * -2) == CONTENT_SKY)
        return;

    float mat = W_ClassifyImpactMaterial(trace_ent);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self && SV_PlayerHasNetchan(p) && checkpvs(pos, p))   // nettest: PVS-cull + skip bots (no netchan) - only players who can see the impact need the ric/decal/tracer (was sent to ALL players)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            // Normal is a unit vector (components in [-1,+1]); quantise to
            // a signed byte biased by 127 to save 9 B/event over WriteCoord.
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            // Target entnum so remote clients can attach bullet-hole
            // decals to the correct func_breakable / BSP entity and
            // remove them on CSQC_EVENT_BRUSH_DESTROY. 0 = world /
            // non-BSP hit (client treats as stationary world decal).
            WriteShort(MSG_ONE, num_for_edict(trace_ent));
            // Shooter entnum — used by remote clients to anchor the
            // bullet tracer's start at the shooter's eye position.
            // Players never exceed maxclients so a byte is enough.
            WriteByte(MSG_ONE, num_for_edict(self));
            WriteByte(MSG_ONE, 1);   // is_entry=1: the primary/entry impact draws the tracer
        }
        p = p.player_chain_next;
    }
};

// Impact effect sent to all OTHER players, with the material classified
// from the current trace_ent. The shooter already predicted the first-hit
// ric via CSQC_BulletImpact; for post-penetration and exit impacts CSQC
// can't predict, so in those cases the shooter simply gets no ric for the
// follow-up hits — still better than a ping-delayed echo layered on top
// of their predicted entry sound.
void(vector pos, vector normal) W_ImpactEffectAll =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    float mat = W_ClassifyImpactMaterial(trace_ent);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self && SV_PlayerHasNetchan(p) && checkpvs(pos, p))   // nettest: PVS-cull + skip bots (no netchan) - only players who can see the impact need the ric/decal/tracer (was sent to ALL players)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            WriteShort(MSG_ONE, num_for_edict(trace_ent));   // target entnum for decal attach
            WriteByte(MSG_ONE, num_for_edict(self));         // shooter entnum for tracer start
            WriteByte(MSG_ONE, 0);   // is_entry=0: penetration EXIT — decal only, NO tracer (the
                                     // entry already drew it; an exit tracer = the doubled line)
        }
        p = p.player_chain_next;
    }
};

// Same as W_ImpactEffectAll but with an explicit material code, bypassing
// the auto-classifier. Lets the caller upgrade FLESH → FLESH_LETHAL on
// killing blows and headshots so the lethal blood-splash variant fires.
void(vector pos, vector normal, float mat) W_ImpactEffectAllMat =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    // Skip the shooter — their CSQC_PredictFireWeapon path already ran
    // CSQC_BulletImpact which plays the ric sound at the impact point.
    // Without this skip the attacker hears a ping-delayed echo.
    entity p = player_chain_head;
    while (p)
    {
        if (p != self && SV_PlayerHasNetchan(p) && checkpvs(pos, p))   // nettest: PVS-cull + skip bots (no netchan) - only players who can see the impact need the ric/decal/tracer (was sent to ALL players)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            WriteShort(MSG_ONE, num_for_edict(trace_ent));   // target entnum for decal attach
            WriteByte(MSG_ONE, num_for_edict(self));         // shooter entnum for tracer start
            WriteByte(MSG_ONE, 1);   // is_entry=1: explicit-material primary hit (player/flesh) — tracer
        }
        p = p.player_chain_next;
    }
};

// Send a positioned sound via multicast. Respects dimension_send,
// unlike sound() which bypasses dimension masking.
void(vector pos, string snd) W_MulticastSound =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_POINTSOUND);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteString(MSG_MULTICAST, snd);
    multicast(pos, MULTICAST_PHS);
};

// Send shell casing eject to all players in PVS.
// The shooter's client deduplicates against its own predicted casing.
void(float shell_type, vector origin_offset, vector base_vel, vector base_avel) W_ShellEffect =
{

    // Global shell adjustments: push forward, raise, adjust ejection velocity
    origin_offset_x += 4;
    origin_offset_z += 1;
    base_vel_y += 20;
    base_vel_z += 10;

    // Per-shot randomization so each ejected case flies + tumbles differently
    // for the OTHER players watching (the shooter's own casing is the separately
    // jittered CSQC-predicted one in cl_shells.qc).  Applied in the gun's local
    // frame before makevectors below; one random() draw per shot, broadcast
    // identically to every observer so it stays consistent across clients.
    base_vel_x  += (random() - 0.5) * 12;
    base_vel_y  += (random() - 0.5) * 26;
    base_vel_z  += (random() - 0.5) * 26;
    base_avel_x += (random() - 0.5) * 240;
    base_avel_y += (random() - 0.5) * 360;
    base_avel_z += (random() - 0.5) * 300;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self && SV_PlayerHasNetchan(p) && checkpvs(org, p))   // nettest: PVS-cull + skip bots - only players who can see the shooter need the casing eject (was sent to ALL players)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_SHELL);
            WriteByte(MSG_ONE, shell_type);
            WriteCoord(MSG_ONE, org_x);
            WriteCoord(MSG_ONE, org_y);
            WriteCoord(MSG_ONE, org_z);
            WriteCoord(MSG_ONE, vel_x);
            WriteCoord(MSG_ONE, vel_y);
            WriteCoord(MSG_ONE, vel_z);
            WriteCoord(MSG_ONE, base_avel_x);
            WriteCoord(MSG_ONE, base_avel_y);
            WriteCoord(MSG_ONE, base_avel_z);
        }
        p = p.player_chain_next;
    }
};

// Send magazine drop to all players in PVS.
// The shooter's client deduplicates against its own predicted mag.
void(float mag_type, vector origin_offset, vector base_vel) W_MagDropEffect =
{
    // Lower mag drop origin on player
    origin_offset_z -= 4;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self && SV_PlayerHasNetchan(p) && checkpvs(org, p))   // nettest: PVS-cull + skip bots - only players who can see the reload need the mag drop (was sent to ALL players)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_MAGDROP);
            WriteByte(MSG_ONE, mag_type);
            WriteCoord(MSG_ONE, org_x);
            WriteCoord(MSG_ONE, org_y);
            WriteCoord(MSG_ONE, org_z);
            WriteCoord(MSG_ONE, vel_x);
            WriteCoord(MSG_ONE, vel_y);
            WriteCoord(MSG_ONE, vel_z);
        }
        p = p.player_chain_next;
    }
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
    {
        // BREAKABLE_ONLY_EXPLOSION brushes deliberately have
        // takedamage = DAMAGE_NO so hitscan can't touch them — but
        // the whole point of the flag is that explosions CAN.
        // sv_in_radius_explosion is set TRUE while W_RadiusExplode
        // is iterating its breakable list, so accept here.
        if (sv_in_radius_explosion
            && target.classname == "func_breakable"
            && (target.spawnflags & BREAKABLE_ONLY_EXPLOSION))
            return TRUE;
        return FALSE;
    }
    return TRUE;
};

void(float attacker_slot, float victim_slot, float cause, float weapon, float headshot) SV_SendKillFeed =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_KILLFEED);
    WriteByte(MSG_MULTICAST, attacker_slot);
    WriteByte(MSG_MULTICAST, victim_slot);
    WriteByte(MSG_MULTICAST, cause);
    WriteByte(MSG_MULTICAST, weapon);
    WriteByte(MSG_MULTICAST, headshot);
    multicast('0 0 0', MULTICAST_ALL);
};

void(entity attacker, entity victim) PlayerKilled =
{
    Carry_Drop(victim);   // drop any carried prop on death so it falls free

    victim.deaths = victim.deaths + 1;
    victim.prog_deaths = victim.prog_deaths + 1;   // nettest progression: lifetime deaths

    // Kill-feed broadcast — attacker may be non-player (world / env_hurt)
    // which we surface as KILLFEED_NO_ATTACKER.  Headshot flag is latched
    // on the victim by W_BoneToHitgroup during the killing hitscan.
    float kf_cause;
    float kf_atk_slot = (attacker.classname == "player")
        ? num_for_edict(attacker) - 1
        : KILLFEED_NO_ATTACKER;
    float kf_vic_slot = num_for_edict(victim) - 1;
    if (attacker == victim || attacker.classname != "player")
        kf_cause = KILL_CAUSE_SUICIDE;
    else if (!Gamemode_HasUnifiedTeams()
             && attacker.player_team != TEAM_NONE
             && attacker.player_team == victim.player_team)
        kf_cause = KILL_CAUSE_FRIENDLYFIRE;
    else
        kf_cause = KILL_CAUSE_WEAPON;
    SV_SendKillFeed(kf_atk_slot, kf_vic_slot, kf_cause, attacker.weapon,
                    (victim.death_hitgroup == HITGROUP_HEAD) ? 1 : 0);

    // nettest server-side killcam: weapon/FF deaths trigger the victim's killcam
    // (matches cl_killfeed.qc) — unicast the killer's recorded camera track so the
    // rewind shows their approach even through stretches the victim's PVS never saw.
    if (kf_cause == KILL_CAUSE_WEAPON || kf_cause == KILL_CAUSE_FRIENDLYFIRE)
        Killcam_SV_SendTrack(attacker, victim);

    if (attacker.classname == "player")
    {
        if (attacker == victim)
            attacker.frags = attacker.frags - 1;
        else
        {
            attacker.frags = attacker.frags + 1;
            // Cash reward for a legitimate enemy kill (kf_cause excludes
            // suicides and team-kills).  Headshot adds mp_cashheadshot.
            if (kf_cause == KILL_CAUSE_WEAPON)
            {
                float reward = cvar("mp_cashreward");
                float hs = (victim.death_hitgroup == HITGROUP_HEAD) ? 1 : 0;
                if (hs)
                    reward = reward + cvar("mp_cashheadshot");
                AddMoney(attacker, reward);

                // Dopamine kill-cash popup — unicast to the killer only.
                // CSQC delays the center-top "+$" popup 0.5s (orchestralhit)
                // and plays killsound.wav immediately on a headshot kill.
                if (reward > 0 && SV_PlayerHasNetchan(attacker))
                {
                    msg_entity = attacker;
                    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
                    WriteByte(MSG_ONE, CSQC_EVENT_KILL_REWARD);
                    WriteShort(MSG_ONE, reward);
                    WriteByte(MSG_ONE, hs);
                }

                // nettest progression: XP for a legitimate kill (+headshot bonus).
                Prog_AwardXP(attacker, PROG_XP_KILL + (hs ? PROG_XP_HEADSHOT : 0), "kill");
                attacker.prog_kills = attacker.prog_kills + 1;
                if (hs)
                    attacker.prog_headshots = attacker.prog_headshots + 1;
            }
        }

        PlayerRefreshScoreboardInfo(attacker);
        logfrag(attacker, victim);
    }

    // Deferred death — body stays visible for death cam, respawn/spectate
    // handled in StartFrame after mp_respawndelay expires.
    victim.is_dead = TRUE;
    // Refresh AFTER is_dead so the scoreboard sees the new dead state.
    PlayerRefreshScoreboardInfo(victim);
    victim.death_time = time;
    victim.solid = SOLID_NOT;
    victim.health = 0;
    // NOTE: do NOT zero victim.velocity yet — Player_VisualProxy_DetachAsCorpse
    // reads it to seed the corpse's ballistic motion (so a player who dies
    // mid-air completes the fall, an explosive blast sends the body flying).
    // Velocity is zeroed AFTER the detach copy below.

    // Play death animation + scatter carried weapons, all with self = victim
    {
        entity saved;
        saved = self;
        self = victim;
        SH_PlayerAnim_Death();
        W_DropAllWeaponsOnDeath();
        self = saved;
    }

    // Strip weapons so dead player can't switch
    victim.weapon = WEP_NONE;
    victim.weaponmodel = "";
    victim.weaponframe = 0;

    // Stop any looping weapon sounds (e.g. gauss charge)
    sound(victim, CHAN_WEAPON, "sounds/null.wav", 1, ATTN_NORM);
    victim.weaponstate = WS_IDLE;

    // Detach the visual proxy as a corpse — the body persists on the
    // ground for the rest of the round (cleaned up by RoundRestart's
    // corpse sweep). Works in both TDM (PlayerSpawn's Ensure spawns a
    // fresh proxy at the respawn point) and Elimination (PlayerJoinSpectate
    // sees player_visual_proxy == world and skips its remove).
    // Detach reads victim.velocity for the corpse's initial fall vector,
    // so this MUST run before the velocity zero below.
    Player_VisualProxy_DetachAsCorpse(victim);

    // Now safe to wipe the live player's velocity — corpse already has
    // its copy.  The dead player entity stays at rest until respawn.
    victim.velocity = '0 0 0';
};

// ============================================================
//  Damage report (cl_playerdamage death-screen panel)
//
//  32×32 sparse matrix of (attacker, target) damage totals + hit
//  counts, accumulated per-life. On death we walk the victim's row
//  (Given) and column (Taken) and ship the result as a single
//  CSQC_EVENT_DAMAGE_REPORT to the dying player only. Cleared
//  per-player on PlayerSpawn so each life starts fresh.
//
//  Index = attacker_slot0 * 32 + target_slot0  (slot0 = 0..31).
// ============================================================
const float DR_MAX_PLAYERS = 32;
const float DR_REPORT_CAP  = 16;   // entries per side on the wire

float dr_dmg [DR_MAX_PLAYERS * DR_MAX_PLAYERS];
float dr_hits[DR_MAX_PLAYERS * DR_MAX_PLAYERS];

void(float slot0) DamageReport_ClearForPlayer =
{
    if (slot0 < 0 || slot0 >= DR_MAX_PLAYERS) return;
    float i;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        // row: damage this player dealt to others
        dr_dmg [slot0 * DR_MAX_PLAYERS + i] = 0;
        dr_hits[slot0 * DR_MAX_PLAYERS + i] = 0;
        // column: damage this player received from others
        dr_dmg [i * DR_MAX_PLAYERS + slot0] = 0;
        dr_hits[i * DR_MAX_PLAYERS + slot0] = 0;
    }
};

void(entity attacker, entity target, float damage) DamageReport_Record =
{
    if (!attacker || !target) return;
    if (attacker == target) return;
    if (attacker.classname != "player") return;
    if (target.classname   != "player") return;

    float a = num_for_edict(attacker) - 1;
    float t = num_for_edict(target)   - 1;
    if (a < 0 || a >= DR_MAX_PLAYERS) return;
    if (t < 0 || t >= DR_MAX_PLAYERS) return;

    float idx = a * DR_MAX_PLAYERS + t;
    dr_dmg [idx] = dr_dmg [idx] + damage;
    dr_hits[idx] = dr_hits[idx] + 1;
};

// Walk the victim's row (Given) and column (Taken) and ship the
// report as a single CSQC event to the victim.
void(entity victim) DamageReport_Send =
{
    if (!victim || victim.classname != "player" || clienttype(victim) != CLIENTTYPE_REAL) return;   // skip bots (engine-truth guard)
    float v = num_for_edict(victim) - 1;
    if (v < 0 || v >= DR_MAX_PLAYERS) return;

    msg_entity = victim;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_REPORT);

    // ---- Given list (victim damaged whom) ----
    float given_count = 0;
    float i;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        if (dr_dmg[v * DR_MAX_PLAYERS + i] > 0)
            given_count = given_count + 1;
    }
    if (given_count > DR_REPORT_CAP) given_count = DR_REPORT_CAP;
    WriteByte(MSG_ONE, given_count);

    float written = 0;
    for (i = 0; i < DR_MAX_PLAYERS && written < given_count; i = i + 1)
    {
        float idx = v * DR_MAX_PLAYERS + i;
        if (dr_dmg[idx] <= 0) continue;
        entity tgt = edict_num(i + 1);
        float hp   = (tgt && tgt.classname == "player") ? tgt.health : 0;
        WriteByte (MSG_ONE, i + 1);                                // 1-based slot
        WriteShort(MSG_ONE, bound(0, rint(dr_dmg[idx]), 32767));
        WriteByte (MSG_ONE, bound(0, dr_hits[idx], 255));
        WriteByte (MSG_ONE, bound(0, rint(hp), 255));
        written = written + 1;
    }

    // ---- Taken list (who damaged victim) ----
    float taken_count = 0;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        if (dr_dmg[i * DR_MAX_PLAYERS + v] > 0)
            taken_count = taken_count + 1;
    }
    if (taken_count > DR_REPORT_CAP) taken_count = DR_REPORT_CAP;
    WriteByte(MSG_ONE, taken_count);

    written = 0;
    for (i = 0; i < DR_MAX_PLAYERS && written < taken_count; i = i + 1)
    {
        float idx = i * DR_MAX_PLAYERS + v;
        if (dr_dmg[idx] <= 0) continue;
        entity atk = edict_num(i + 1);
        float hp   = (atk && atk.classname == "player") ? atk.health : 0;
        WriteByte (MSG_ONE, i + 1);
        WriteShort(MSG_ONE, bound(0, rint(dr_dmg[idx]), 32767));
        WriteByte (MSG_ONE, bound(0, dr_hits[idx], 255));
        WriteByte (MSG_ONE, bound(0, rint(hp), 255));
        written = written + 1;
    }
};

// Re-entrancy flag: SV_HandleBreakclaim sets this TRUE around its own
// W_ApplyDamage call so the breakable-defer gate below doesn't fire
// recursively and reject the very claim it's processing.  Globals (not
// a parameter) so the dozen-plus weapon files calling W_ApplyDamage
// don't all need a refactor.
float sv_in_breakclaim_apply;
// sv_in_radius_explosion is declared in sh_weapon_standard.qc so
// W_RadiusExplode can set/clear it.  Used here in W_ApplyDamage to
// bypass the sv_trust_clientbreak deferral on explosion hits, and in
// W_CanDamageTarget to accept BREAKABLE_ONLY_EXPLOSION brushes.

void(entity victim, float damage, float fall_twist) SV_SendDamageViewKick =
{
    if (victim.classname != "player")
        return;
    if (damage <= 0)
        return;
    if (cvar("sv_headkick") <= 0)
        return;

    float pitch = 0;
    float roll = 0;

    if (fall_twist)
    {
        float roll_strength = cvar("sv_headkick_fall_roll_strength");
        if (roll_strength <= 0) roll_strength = 0.18;
        float roll_max = cvar("sv_headkick_fall_roll_max");
        if (roll_max <= 0) roll_max = 14;

        roll = bound(0, damage * roll_strength, roll_max);
        if (random() < 0.5)
            roll = 0 - roll;
    }
    else
    {
        float pitch_strength = cvar("sv_headkick_strength");
        if (pitch_strength <= 0) pitch_strength = 0.12;
        float pitch_max = cvar("sv_headkick_max");
        if (pitch_max <= 0) pitch_max = 8;

        // Negative pitch looks upward in Quake/FTE angle convention.
        pitch = 0 - bound(0, damage * pitch_strength, pitch_max);
    }

    if ((pitch == 0 && roll == 0) || clienttype(victim) != CLIENTTYPE_REAL)   // skip bots (engine-truth guard)
        return;

    msg_entity = victim;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_VIEWKICK);
    WriteShort(MSG_ONE, bound(-32768, rint(pitch * 100), 32767));
    WriteShort(MSG_ONE, bound(-32768, rint(roll * 100), 32767));
};

// Defined in sv_func_vehicle.qc (compiles later) — a shot nudges a vehicle free.
void(entity veh, entity attacker) Vehicle_ShotNudge;

float(entity attacker, entity target, float damage) W_ApplyDamage =
{
    entity saved;
    entity old_activator;

    if (!W_CanDamageTarget(target))
        return 0;

    // func_vehicle: a hit doesn't damage it — it shoves the car along the shot
    // into clear space, so players can shoot a stuck vehicle free.
    if (target.classname == "func_vehicle")
    {
        Vehicle_ShotNudge(target, attacker);
        return 0;
    }

    // sv_trust_clientbreak: when ON, the client owns breakable damage
    // (sends `cmd breakclaim` per shot, server applies via
    // SV_HandleBreakclaim).  Skip server-auth damage here so the same
    // shot doesn't double up.  Centralized inside W_ApplyDamage to
    // cover all hitscan / pellet / melee / projectile call sites
    // without per-weapon edits.  The breakclaim handler itself sets
    // sv_in_breakclaim_apply so this gate doesn't reject its own call.
    // Radius explosions also bypass — no client-side prediction path
    // exists for them, so deferral would silently drop the damage.
    if (!sv_in_breakclaim_apply
        && !sv_in_radius_explosion
        && target.classname == "func_breakable"
        && W_ShouldDeferBreakToClaim(attacker))
        return 0;

    // Friendlyfire check: block teammate damage if disabled.
    // Unified-team modes (FFA + Bhop) bypass entirely — every player
    // is fair game regardless of the backend team value (which exists
    // only so admin-switching back to a team mode lands players on a
    // valid team).
    if (!Gamemode_HasUnifiedTeams()
        && attacker.classname == "player" && target.classname == "player"
        && attacker != target
        && attacker.player_team == target.player_team
        && attacker.player_team != TEAM_NONE
        && !cvar("mp_friendlyfire"))
        return 0;

    // Kevlar absorbs part of the incoming damage before it reaches health
    // (a helmet halves a headshot first — the 4x head multiplier is already
    // baked into `damage`).  No-op when the player has no armor and no
    // helmet.  Players only; world/breakables are unaffected.
    if (target.classname == "player")
        damage = Armor_Absorb(target, damage, target.death_hitgroup == HITGROUP_HEAD);

    if (damage > target.health)
        damage = target.health;

    target.health       = target.health - damage;
    target.dmg_inflictor = attacker;

    // sv_debug_hitclaim (and the existing cl_debug_hitclaim on the
    // client) — single chokepoint for "what damage just landed".
    // Covers every code path that reaches W_ApplyDamage:
    //   server-auth hitscan (sh_weapon_standard.qc),
    //   trust_clienthits 1 hitclaim (sv_player.qc:SV_HandleHitclaim),
    //   melee / projectile / breakclaim handlers, etc.
    // Prints attacker, weapon, target, hitgroup, and final damage so
    // a user diffing trust 0 vs trust 1 can confirm the exact damage
    // each path lands on each shot.  Wrap in the cvar so production
    // play isn't polluted.
    if (cvar("sv_debug_hitclaim"))
    {
        string atk_name = (attacker && attacker.classname == "player")
                          ? attacker.netname : attacker.classname;
        string tgt_name = (target.classname == "player")
                          ? target.netname : target.classname;
        float hg_byte = target.death_hitgroup;
        print(sprintf("[hit] %s wep=%g -> %s hg=%g dmg=%.1f hp=%.1f trust=%g\n",
                      atk_name, attacker.weapon, tgt_name,
                      hg_byte, damage, target.health,
                      cvar("sv_trust_clienthits")));
    }

    // Snap sub-1 HP slivers to 0 so a player who'd otherwise sit at
    // 0.3 HP (displayed as 0 on the HUD because the byte rounds
    // down) is counted as killed.  Only applies to player targets —
    // func_breakable and other damageables keep their full float
    // precision so the prediction layer can show "almost broken"
    // states accurately.
    if (target.classname == "player"
        && target.health > 0 && target.health < 1)
        target.health = 0;

    // Damage report — record (attacker, target, damage) for the
    // death-screen "Given/Taken" panel. Skips self-damage and
    // non-player attackers (world / fall damage) inside the helper.
    DamageReport_Record(attacker, target, damage);

    // Dedup anchor for sv_trust_clienthits — the hitclaim handler checks
    // these fields to avoid double-damaging the same target when both
    // server-auth and client-claim hit land in the same shot.
    if (attacker)
    {
        attacker.last_damaged_target = target;
        attacker.last_damaged_time   = time;
    }

    // Send pain flash only to the victim.  Attacker origin trails
    // the damage byte so the CSQC hit indicator can rotate toward
    // the source.  Falls back to target.origin (zero relative
    // direction → indicator suppresses itself) when there's no
    // meaningful external attacker.
    if (target.classname == "player" && SV_PlayerHasNetchan(target))   // skip bots (engine-truth guard)
    {
        vector atk_pos = attacker ? attacker.origin : target.origin;
        msg_entity = target;
        WriteByte(MSG_ONE, SVC_CGAMEPACKET);
        WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_FLASH);
        WriteByte(MSG_ONE, bound(1, damage, 255));
        WriteCoord(MSG_ONE, atk_pos_x);
        WriteCoord(MSG_ONE, atk_pos_y);
        WriteCoord(MSG_ONE, atk_pos_z);
        SV_SendDamageViewKick(target, damage, FALSE);
    }

    // Shot a bot with no / stale enemy: wake it to the attacker.  This bypasses the
    // frontal acquisition cone (bot_fov) — being hit is legitimate knowledge of
    // where the shot came from, so a flanked bot turns to fight instead of staying blind.
    if (target.classname == "player" && target.is_bot
        && attacker && attacker != target && IsBotEnemy(target, attacker))
    {
        target.bot_lasthurt_time = time;    // recently shot -> bias toward the attacker (gates the bot's periodic re-pick)

        // Snap to the attacker = the NEAREST current threat.  Adopt it when we have no valid
        // target, OR the current one is stale/unseen, OR we can't currently SEE the current
        // target, OR the attacker is simply CLOSER (across multiple shooters this converges to
        // the nearest, and it won't thrash between equidistant foes).  logicops is OFF here, so
        // each test is its own statement and bot_enemy.origin is read only after the validity
        // checks.  Still bypasses the FOV cone — being hit is legitimate knowledge of the threat.
        float take_attacker = FALSE;
        if (!target.bot_enemy || target.bot_enemy.is_dead || !IsBotEnemy(target, target.bot_enemy))
            take_attacker = TRUE;                       // no valid current target
        else if ((time - target.bot_enemy_time) > 5)
            take_attacker = TRUE;                       // current target stale (unseen >5s)
        else if (target.bot_los_lost_time != 0)
            take_attacker = TRUE;                       // can't see the current target -> the shooter is the live threat
        else if (vlen(attacker.origin - target.origin) < vlen(target.bot_enemy.origin - target.origin))
            take_attacker = TRUE;                       // attacker is closer than the current target

        if (take_attacker)
        {
            target.bot_enemy         = attacker;
            target.bot_enemy_time    = time;            // open the 360 tracking window
            target.bot_enemy_lastpos = attacker.origin; // hunt toward the shooter if no LOS
        }
    }

    // Visual flinch broadcast — all clients in PVS see the victim's
    // proxy play CSANIM_GUT_FLINCH / CSANIM_HEAD_FLINCH for ~0.3 s.
    // Gated on the hit being non-fatal (lethal hits play the death
    // sequence instead) and the attacker being some external entity
    // (so falling / void / status damage doesn't flinch).  Covers
    // BOTH the no-trust path (server-auth W_ApplyDamage IS the
    // single source of damage) and the trust path (server damage is
    // deferred, but the hitclaim handler also routes through
    // W_ApplyDamage — same code).  The shooter additionally predicts
    // the flinch locally in CSQC_SendHitclaim so they see it without
    // the server round-trip; that local predict is overwritten by
    // this multicast harmlessly.
    if (target.classname == "player"
        && target.health > 0
        && attacker != target
        && attacker
        && attacker != world
        && damage > 0)
    {
        float hg = (target.death_hitgroup == HITGROUP_HEAD)
                   ? HITGROUP_HEAD : HITGROUP_GENERIC;
        WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
        WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_FLINCH);
        WriteByte(MSG_MULTICAST, num_for_edict(target));
        WriteByte(MSG_MULTICAST, hg);
        // nettest Patch 36: tag the attacker's slot so their own client can skip this flinch —
        // they already predicted it locally (CSQC_SendHitclaim).  Timing-independent dedup (a
        // client-side time window loses at high ping, e.g. sv_minping 500).  Witnesses apply it.
        WriteByte(MSG_MULTICAST, num_for_edict(attacker));
        multicast(target.origin, MULTICAST_PVS);
    }

    // Hitmarker: server-confirmed hit on any damageable.
    // When sv_trust_clienthits >= 1 AND target is a player, the
    // attacker's CSQC already played the marker locally on the
    // predicted hit (sh_weapon_logic.qc), so suppress the server-side
    // emit to avoid the marker firing twice — once on the predicted
    // trace, again when the server's confirmation packet round-trips
    // back ~ping ms later.  Breakable / phys-prop / world hits keep
    // firing the server marker because the client doesn't predict
    // hitmarkers for non-player targets.
    if (attacker.classname == "player" && SV_PlayerHasNetchan(attacker))   // skip bots (engine-truth guard)
    {
        float trust = cvar("sv_trust_clienthits");
        float client_owns_marker = (target.classname == "player" && trust >= 1);
        if (!client_owns_marker)
        {
            msg_entity = attacker;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_HITMARKER);
        }
    }

    if (target.health <= 0 && target.classname == "player")
    {
        // Headshot kill → broadcast CSQC_EVENT_PLAYER_GIBS so every client
        // spawns flesh chunks + blood ("the head explodes").  Trigger is
        // hitgroup-based, not damage-based: any lethal headshot gibs,
        // regardless of weapon power.  Body-shot kills, even with high
        // damage, do not gib — they play the standard death animation.
        // death_hitgroup is set by every damage source before this
        // function is called (hitscan paths, hitclaim handler, shotgun
        // pellet paths) so the hitgroup of the actual killing blow is
        // available here.
        if (target.death_hitgroup == HITGROUP_HEAD && attacker)
        {
            vector gib_dir = target.origin - attacker.origin;
            if (vlen(gib_dir) > 0)
                gib_dir = normalize(gib_dir);
            else
                gib_dir = '0 0 1';

            // Fixed at 6 — readable spray volume without overwhelming
            // the per-gib blood-drip particle budget (6 gibs × 25-drop
            // spray + 8-drop trickle ≈ 200 simultaneous polygons at
            // peak vs ~1200 under the old 12-gib × 100-drop scheme).
            float gib_count = 6;

            WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
            WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_GIBS);
            WriteCoord(MSG_MULTICAST, target.origin_x);
            WriteCoord(MSG_MULTICAST, target.origin_y);
            WriteCoord(MSG_MULTICAST, target.origin_z + 24);  // center of mass
            WriteCoord(MSG_MULTICAST, gib_dir_x);
            WriteCoord(MSG_MULTICAST, gib_dir_y);
            WriteCoord(MSG_MULTICAST, gib_dir_z);
            WriteByte(MSG_MULTICAST, gib_count);
            WriteShort(MSG_MULTICAST, bound(0, damage, 32767));
            // Victim slot — lets the attacker's CSQC suppress this gib
            // spawn when cl_predict_death already fired for that proxy
            // (vis_pred_gibs_at_time within the staleness window).
            // Without this, the predicted gibs and the server's authoritative
            // gibs visibly double up at high ping.
            WriteByte(MSG_MULTICAST, num_for_edict(target));
            multicast(target.origin, MULTICAST_PVS);

            // Suppress the corpse visual — the player exploded, there's no body.
            target.modelindex = 0;
            if (target.player_visual_proxy)
                target.player_visual_proxy.modelindex = 0;
        }

        PlayerKilled(attacker, target);

        // Death-screen damage report — send to the dying player
        // before their slot resets on respawn. Sent via MSG_ONE
        // (victim only). cl_playerdamage gates client display.
        DamageReport_Send(target);

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

// Dropped-weapon CSQC replication — body lives in server/sv_player.qc
// so it can reference the per-weapon mag_*/ammo_* fields (declared in
// the sh_wpn_*.qc files, which compile AFTER this file). Forward
// declaration is at the top of this file near weapon_become_solid.

// Shared in-flight send interval for dropped weapons + projectiles.
// Reads sv_toss_tickrate (Hz, default 20, clamped 5..100) and returns
// the seconds-per-tick value used as nextthink offsets. Centralised so
// admins tune one cvar to control every airborne entity's send rate.
float() Toss_NextThinkInterval =
{
    return 1.0 / bound(5, cvar("sv_toss_tickrate"), 100);
};

float() RoundToss_NextThinkInterval =
{
    return 1.0 / bound(1, cvar("sv_roundtoss_tickrate"), 100);
};

float(entity drop_ent) WeaponDrop_NextThinkInterval =
{
    if (drop_ent.weapon_round_toss)
        return RoundToss_NextThinkInterval();
    return Toss_NextThinkInterval();
};

// Optional ODE-backed weapon drops/spawns.
// (Pickup zone constants WEAPON_PICKUP_HALF_W / *_HEIGHT_* / *_PAD live
// in shared/sh_weapons.qc so client predict and server +use agree.)

// Void-Z threshold: a prop whose origin drops below this is despawned.
// -10000 ≈ 5s of free-fall (0.5 * 800 * 5²) — gives a fall-through-floor
// case enough time to notice + react without sitting in the void
// forever. Far below any legit map gameplay floor (most maps bottom-out
// around -1024). Bump further if a future map has gameplay below this
// depth. Keep in sync with PHYSPROP_VOID_Z (sv_physprop.qc) and the
// void clamp in CSQC's Toss_PredictedNow (cl_tosssmooth.qc).
const float PHYSDROP_VOID_Z = -10000;
const float PHYSDROP_COORD_CAP = 65536;
const float PHYSDROP_SLEEP_POLL = 0.2;     // polling cadence, not a feel knob

// Phys-drop sleep thresholds — float globals refreshed from the shared
// sv_physprop_sleep_* cvars at each W_PhysDropEnable call.  The per-tick sleep
// checks in W_PhysDropThink read them so a live cvar tweak takes effect on the
// next think (~0.2 s latency, fine for tuning).  (Mass / friction / bounce /
// damping now live in PhysObj_Setup via the shared sv_physprop_* family.)
float PHYSDROP_SLEEP_SPEED;
float PHYSDROP_SLEEP_ANGSPEED;
float PHYSDROP_SLEEP_DELAY;

// Fallback used by W_PhysDropRefreshCvars below.  cvar() returns 0
// both for "set to 0 by admin" and "cvar string is empty" — distinguish
// via cvar_string() and substitute the default only when the string
// is literally "" (unregistered, or blanked by a stale data/server.cfg
// exec).  Without this, dedicated servers were spawning weapons with
// zeroed mass / friction / sleep thresholds because registercvar
// didn't override values the engine already knew about.
float(string name, float def) W_PhysDropCvarOrDefault =
{
    string s = cvar_string(name);
    if (s == "")
        return def;
    return stof(s);
};

void() W_PhysDropRefreshCvars =
{
    // Only the sleep thresholds for W_PhysDropThink remain here — now from the
    // SHARED phys-object family (sv_physprop_sleep_*).  Mass / friction / bounce /
    // erp / damping are all set in PhysObj_Setup (the unified ODE core), so they
    // are no longer refreshed into the now-unused PHYSDROP_* globals.
    PHYSDROP_SLEEP_SPEED    = W_PhysDropCvarOrDefault("sv_physprop_sleep_speed",    8);
    PHYSDROP_SLEEP_ANGSPEED = W_PhysDropCvarOrDefault("sv_physprop_sleep_angspeed", 30);
    PHYSDROP_SLEEP_DELAY    = W_PhysDropCvarOrDefault("sv_physprop_sleep_delay",    0.2);
};

float(float wep) W_PhysDropAllowed =
{
    if (cvar("sv_phys_drops") <= 0)
        return FALSE;
    if (!Weapon_PhysDropEligible(wep))
        return FALSE;
    if (!physics_supported(TRUE))
    {
        cvar_set("sv_ode_loaded", "-1");
        if (cvar("sv_debug_physprops"))
            dprint("[physdrop] sv_phys_drops is on, but ODE physics is unavailable\n");
        return FALSE;
    }
    cvar_set("sv_ode_loaded", "1");
    return TRUE;
};

float(entity drop_ent) W_PhysDropRadius =
{
    vector mn = drop_ent.mins;
    vector mx = drop_ent.maxs;
    float r;

    r = max(fabs(mn_x), fabs(mx_x));
    r = max(r, fabs(mn_y));
    r = max(r, fabs(mx_y));
    r = max(r, fabs(mn_z));
    r = max(r, fabs(mx_z));

    // Trimesh collision uses the model surface; this cube is just the broad
    // ODE/entity AABB, so keep it generous enough for rotated weapon meshes.
    return bound(12, r + 4, 64);
};

void(entity drop_ent) W_PhysDropEnable =
{
    // Refresh tunables from cvars so live tweaks (sv_physdrop_*) apply
    // to the next phys-enable without a map restart.
    W_PhysDropRefreshCvars();

    // Geometry shape — TRIMESH uses the model's triangle mesh as the
    // collision surface (visually accurate rest, but unreliable on
    // GoldSrc .mdl files whose mesh data has gaps / duplicate verts,
    // causing the "flickers in place / stuck on nothing / stuck on
    // player" symptoms the user reported on the CF series).
    //
    // SOLID_PHYSICS_BOX uses the entity's bbox as the collision shape —
    // strictly an AABB, simpler, ODE-stable across model formats, and
    // sized from the model's natural $bbox (which setmodel stamps into
    // mins/maxs).  Default to BOX for that reason; flip
    // sv_physprop_weapon_geom to 1 to opt back into TRIMESH per-server.
    float use_trimesh = cvar("sv_physprop_weapon_geom") > 0.5;

    if (use_trimesh)
    {
        // Trimesh path — broad AABB is a generous cube around the
        // model's bounding sphere so any rotation stays inside.
        float r = W_PhysDropRadius(drop_ent);
        setsize(drop_ent, [-r, -r, -r], [r, r, r]);
        drop_ent.solid = SOLID_PHYSICS_TRIMESH;
    }
    else
    {
        // Box path — the natural $bbox in GoldSrc .mdl world models is
        // basically always tiny (1-2 units around the origin) because
        // the original engine never used it for collision on dropped
        // weapons.  Trusting it means dropped guns rest with the model
        // sunk into the floor.  Force a tight gun-shaped half-extent box
        // that matches the silhouette so ODE rests the body on the gun
        // shape.  Hitscan AABB is grown separately at trace time by
        // W_PhysDropsExpandTraceBboxes (mirrors the sv_hitbox_expand
        // playermodel pattern) — keeping the ODE shape tight here.
        // Tunable per-server via sv_physprop_weapon_bbox_(x|y|z); 0 means
        // "use model's natural".
        float bx = W_PhysDropCvarOrDefault("sv_physprop_weapon_bbox_x", 12);
        float by = W_PhysDropCvarOrDefault("sv_physprop_weapon_bbox_y", 5);
        float bz = W_PhysDropCvarOrDefault("sv_physprop_weapon_bbox_z", 3);
        if (bx > 0 && by > 0 && bz > 0)
            setsize(drop_ent, [-bx, -by, -bz], [bx, by, bz]);
        else if (drop_ent.maxs == drop_ent.mins)
            setsize(drop_ent, '-8 -8 -2', '8 8 2');
        drop_ent.solid = SOLID_PHYSICS_BOX;
    }
    // Unified phys-object config — weapon drops share the cabinet/barrel/can core.
    // FX on (impact/slide/scrape/smoke/spark), sleep on (perf — many drops settle
    // to detached ODE bodies), weapon-drop semantics (PHYSDROP_DIM passthrough so
    // you walk over them + weapon_touch pickup), 2s BSP-embed despawn grace.
    drop_ent.po_fx_enabled     = TRUE;
    drop_ent.po_sleep_enabled  = TRUE;
    drop_ent.po_is_weapon_drop = TRUE;
    drop_ent.po_stuck_grace    = 2;
    drop_ent.po_fx_soundset    = 1;   // weapon set: weapon_impact_* + soda_can_scrape

    drop_ent.weapon_physdrop_sleeping   = FALSE;
    drop_ent.weapon_physdrop_rest_start = 0;

    // Physics drops must use server angles, not CSQC's classic spin path.  Set the
    // spin BEFORE PhysObj_Setup so physics_enable snapshots it onto the ODE body.
    drop_ent.dropped_spin = 0;
    if (drop_ent.avelocity == '0 0 0' && (drop_ent.velocity * drop_ent.velocity) > 1)
        drop_ent.avelocity = [random() * 360 - 180, random() * 600 - 300, random() * 360 - 180];

    drop_ent.weapon_physdrop_last_origin = drop_ent.origin;
    if ((drop_ent.velocity * drop_ent.velocity) > 1)
        drop_ent.weapon_physdrop_probe_time = time + 0.25;
    else
        drop_ent.weapon_physdrop_probe_time = 0;

    // Shared ODE core (PhysObj_Setup): movetype, bounce, erp, damping, PHYSDROP_DIM
    // dimension masks, physics_enable.  Light + grippy (mass 1.5 / friction ~0.5) so
    // a dropped gun moves when hit/blasted but settles quickly.  max_angular bumped
    // back to 35 after (guns tumble more freely than the heavier props at 20).
    PhysObj_Setup(drop_ent,
                  W_PhysDropCvarOrDefault("sv_physprop_weapon_mass",     20),
                  W_PhysDropCvarOrDefault("sv_physprop_weapon_friction", 0.5));
    drop_ent.max_angular = 35;

    if (cvar("sv_debug_physprops"))
    {
        float r_dbg = use_trimesh ? W_PhysDropRadius(drop_ent) : 0;
        dprint(sprintf("[physdrop] enabled %s wep=%g ent=%g origin=%v vel=%v shape=%s r=%.1f\n",
            drop_ent.classname, drop_ent.weapon, num_for_edict(drop_ent),
            drop_ent.origin, drop_ent.velocity,
            use_trimesh ? "trimesh" : "box", r_dbg));
    }

    // (No immediate-sleep flip here.  An earlier version called
    // W_PhysDropSleep right after physics_enable(TRUE) when velocity
    // was zero — wake/sleep in the same tick crashed dedicated
    // servers via dxNormalize4 / LCP "s <= 0" when the body sat
    // partially embedded in the floor at activation time.  Let ODE
    // simulate naturally for ~PHYSDROP_SLEEP_DELAY seconds; the
    // sleep path inside W_PhysDropThink takes over once the body's
    // velocity drops below the sleep threshold.)
};

void(entity drop_ent) W_PhysDropSleep =
{
    drop_ent.weapon_physdrop_sleeping = TRUE;
    drop_ent.weapon_physdrop_rest_start = 0;
    drop_ent.velocity = '0 0 0';
    drop_ent.avelocity = '0 0 0';
    drop_ent.SendFlags |= 1;

    physics_enable(drop_ent, FALSE);
    drop_ent.movetype = MOVETYPE_NONE;
    // Keep the physics-solid shape while asleep so hitscan traces still
    // use the model bbox / mesh instead of the broad pickup bbox.
    drop_ent.solid = (cvar("sv_physprop_weapon_geom") > 0.5)
                   ? SOLID_PHYSICS_TRIMESH : SOLID_PHYSICS_BOX;
    drop_ent.dimension_solid = PHYSDROP_DIM;
    drop_ent.dimension_hit = dimension_default | PHYSDROP_DIM;
    drop_ent.think = W_PhysDropThink;
    drop_ent.nextthink = time + PHYSDROP_SLEEP_POLL;

    if (cvar("sv_debug_physprops"))
        dprint(sprintf("[physdrop] slept %s ent=%g origin=%v\n",
            drop_ent.classname, num_for_edict(drop_ent), drop_ent.origin));
};

void(entity drop_ent) W_PhysDropWake =
{
    if (!drop_ent.weapon_physdrop_sleeping)
        return;

    drop_ent.weapon_physdrop_sleeping = FALSE;
    drop_ent.weapon_physdrop_rest_start = 0;
    // Clear the embedded-since stamp on every wake. Otherwise a prop
    // that sat sleeping at a position whose pointcontents was solid
    // (e.g. settled with origin barely below floor — common for low-
    // hull weapons like the shotgun/crossbow/rebar) carries a stale
    // phys_stuck_since across the sleep, and the very first awake
    // tick reports time-vs-stale-arm-time as way over the 2 s
    // threshold and despawns the prop instantly. Resetting here
    // makes the 2-s clock measure only "embedded time WHILE awake",
    // which is what the stuck-detector was meant to gate on.
    drop_ent.phys_stuck_since = 0;
    drop_ent.weapon_round_toss = FALSE;
    // Mirror the W_PhysDropEnable geometry choice on wake — see that
    // function for why BOX is the default.
    drop_ent.solid = (cvar("sv_physprop_weapon_geom") > 0.5)
                   ? SOLID_PHYSICS_TRIMESH : SOLID_PHYSICS_BOX;
    drop_ent.movetype = MOVETYPE_PHYSICS;
    drop_ent.dimension_solid = PHYSDROP_DIM;
    drop_ent.dimension_hit = dimension_default | PHYSDROP_DIM;
    physics_enable(drop_ent, TRUE);
    drop_ent.think = W_PhysDropThink;
    drop_ent.nextthink = time + WeaponDrop_NextThinkInterval(drop_ent);
    drop_ent.SendFlags |= 1;

    if (cvar("sv_debug_physprops"))
        dprint(sprintf("[physdrop] woke %s ent=%g origin=%v\n",
            drop_ent.classname, num_for_edict(drop_ent), drop_ent.origin));
};

void(entity drop_ent, float pickup_delay) W_PhysDropStart =
{
    drop_ent.pvsflags = PVSF_NOREMOVE;
    drop_ent.SendEntity = dropped_weapon_SendEntity;
    drop_ent.SendFlags |= 1;
    drop_ent.nodrawtoclient = world;
    drop_ent.weapon_solid_time = time + pickup_delay;
    W_PhysDropEnable(drop_ent);
    drop_ent.think = W_PhysDropThink;
    drop_ent.nextthink = time + WeaponDrop_NextThinkInterval(drop_ent);
};

void() W_SyncMapWeaponPhysics =
{
    entity e = nextent(world);
    entity saved = self;

    while (e)
    {
        if (e.map_weapon
            && e.weapon != WEP_NONE
            && e.model != ""
            && Weapon_PhysDropEligible(e.weapon)
            && e.movetype != MOVETYPE_PHYSICS
            && !e.weapon_physdrop_sleeping)
        {
            self = e;
            if (W_PhysDropAllowed(e.weapon))
            {
                e.owner = world;
                e.velocity = '0 0 0';
                e.avelocity = '0 0 0';
                e.weapon_round_toss = TRUE;
                W_PhysDropStart(e, 0);
            }
        }
        e = nextent(e);
    }

    self = saved;
};

void() W_PhysDropFallbackToToss =
{
    if (cvar("sv_debug_physprops"))
        dprint(sprintf("[physdrop] fallback to TOSS for %s ent=%g origin=%v vel=%v\n",
            self.classname, num_for_edict(self), self.origin, self.velocity));

    physics_enable(self, FALSE);
    self.weapon_physdrop_sleeping = FALSE;
    self.weapon_physdrop_rest_start = 0;
    self.solid = SOLID_NOT;
    self.movetype = MOVETYPE_TOSS;
    self.dimension_solid = dimension_default;
    self.dimension_hit = dimension_default;
    self.owner = world;
    self.think = weapon_become_solid;
    self.nextthink = time + WeaponDrop_NextThinkInterval(self);
};

float() W_PhysDropEscapedWorld =
{
    if (self.origin_z < PHYSDROP_VOID_Z)
        return TRUE;
    if (fabs(self.origin_x) > PHYSDROP_COORD_CAP)
        return TRUE;
    if (fabs(self.origin_y) > PHYSDROP_COORD_CAP)
        return TRUE;
    if (fabs(self.origin_z) > PHYSDROP_COORD_CAP)
        return TRUE;
    if (self.origin_x != self.origin_x)
        return TRUE;
    if (self.origin_y != self.origin_y)
        return TRUE;
    if (self.origin_z != self.origin_z)
        return TRUE;
    return FALSE;
};

// Pickup-overlap test against the custom WEAPON_PICKUP_* zone, NOT the
// physics body. ODE-backed drops have a setsize hull that can be much
// larger than the visible weapon (e.g. AWP's trimesh cube), and rotates
// with the body — neither of which we want driving pickup feel. Anchor
// a fixed cube at the prop's origin instead so every weapon picks up
// from the same zone and the client-predicted reach stays in sync.
float(entity player) W_PhysDropPlayerClose =
{
    vector zone_mins = self.origin + [-WEAPON_PICKUP_HALF_W, -WEAPON_PICKUP_HALF_W, -WEAPON_PICKUP_HEIGHT_DN];
    vector zone_maxs = self.origin + [ WEAPON_PICKUP_HALF_W,  WEAPON_PICKUP_HALF_W,  WEAPON_PICKUP_HEIGHT_UP];

    vector wmins = zone_mins - [WEAPON_PICKUP_PAD, WEAPON_PICKUP_PAD, WEAPON_PICKUP_PAD];
    vector wmaxs = zone_maxs + [WEAPON_PICKUP_PAD, WEAPON_PICKUP_PAD, WEAPON_PICKUP_PAD];

    if (player.absmax_x < wmins_x || player.absmin_x > wmaxs_x) return FALSE;
    if (player.absmax_y < wmins_y || player.absmin_y > wmaxs_y) return FALSE;
    if (player.absmax_z < wmins_z || player.absmin_z > wmaxs_z) return FALSE;
    return TRUE;
};

float() W_PhysDropTryPickup =
{
    entity oldself = self;
    entity oldother = other;
    entity p = player_chain_head;

    while (p)
    {
        if (p.classname == "player"
            && p.player_team != TEAM_NONE
            && !p.is_dead
            && p.solid == SOLID_SLIDEBOX
            && W_PhysDropPlayerClose(p))
        {
            other = p;
            self = oldself;
            if (self.touch)
                self.touch();
            other = oldother;
            return TRUE;
        }
        p = p.player_chain_next;
    }

    self = oldself;
    other = oldother;
    return FALSE;
};

void() W_PhysDropThink =
{
    if (self.weapon_physdrop_sleeping)
    {
        if (W_PhysDropEscapedWorld())
        {
            if (cvar("sv_debug_physprops"))
                dprint(sprintf("[physdrop] removing escaped sleeping %s at %v\n", self.classname, self.origin));
            remove(self);
            return;
        }

        self.nextthink = time + PHYSDROP_SLEEP_POLL;

        if (time < self.weapon_solid_time)
            return;

        self.owner = world;
        self.nodrawtoclient = world;
        if (W_PhysDropTryPickup())
            return;
        return;
    }

    self.SendFlags |= 1;

    if (W_PhysDropEscapedWorld())
    {
        if (cvar("sv_debug_physprops"))
            dprint(sprintf("[physdrop] removing escaped %s at %v\n", self.classname, self.origin));
        physics_enable(self, FALSE);
        remove(self);
        return;
    }

    // Runtime stuck-despawn — if a moving brush or an explosion has
    // shoved the prop's center into solid BSP and it's been there for
    // more than 2 seconds, ODE isn't going to free it. Despawn rather
    // than try to nudge it (the per-tick unstick attempts in an
    // earlier version misclassified resting-on-floor as embedded and
    // launched weapons into the air every tick). Cheap: pointcontents
    // is one engine call, runs only on the awake-think tick rate.
    if (cvar("sv_phys_unstick") && W_PhysDropStuckDuration(self) > 2)
    {
        if (cvar("sv_debug_physprops"))
            dprint(sprintf("[physdrop] removing %s at %v (stuck in BSP > 2s)\n",
                self.classname, self.origin));
        physics_enable(self, FALSE);
        remove(self);
        return;
    }

    self.nextthink = time + WeaponDrop_NextThinkInterval(self);

    // Contact FX — impact thud / scrape loop / smoke / metal spark, the SAME
    // detection the cabinet/barrel/can use (PhysObj_DetectContactFX infers an
    // impact from a one-tick speed drop, a slide from sustained surface motion).
    // Runs every AWAKE tick (a sleeping drop is a detached body, no motion → no
    // FX); pp_prev_velocity is latched here for the next tick's drop test.
    if (self.po_fx_enabled)
        PhysObj_DetectContactFX(vlen(self.velocity));
    self.pp_prev_velocity = self.velocity;

    if (self.weapon_physdrop_probe_time > 0 && time >= self.weapon_physdrop_probe_time)
    {
        self.weapon_physdrop_probe_time = 0;
        if (vlen(self.origin - self.weapon_physdrop_last_origin) < 4)
        {
            W_PhysDropFallbackToToss();
            return;
        }
    }

    if (time < self.weapon_solid_time)
        return;

    self.owner = world;
    self.nodrawtoclient = world;

    if (vlen(self.velocity) <= PHYSDROP_SLEEP_SPEED
        && vlen(self.avelocity) <= PHYSDROP_SLEEP_ANGSPEED)
    {
        if (self.weapon_physdrop_rest_start <= 0)
            self.weapon_physdrop_rest_start = time;
        else if (time - self.weapon_physdrop_rest_start >= PHYSDROP_SLEEP_DELAY)
        {
            W_PhysDropSleep(self);
            if (W_PhysDropTryPickup())
                return;
            return;
        }
    }
    else
    {
        self.weapon_physdrop_rest_start = 0;
    }

    // Physics solids are not trigger pickups, so manually run the normal
    // weapon_touch path when a live player overlaps the pickup hull.
    if (W_PhysDropTryPickup())
        return;
};

void() W_PhysDropDeferredRemove =
{
    physics_enable(self, FALSE);
    remove(self);
};

void(entity drop_ent) W_PhysDropBeginRemove =
{
    // Hide from CSQC immediately, but defer the actual remove so we never
    // dSpaceRemove a geom from inside ODE's locked collision callback.
    drop_ent.model = "";
    drop_ent.touch = __NULL__;
    drop_ent.solid = SOLID_NOT;
    drop_ent.SendFlags |= 1;
    drop_ent.owner = world;
    physics_enable(drop_ent, FALSE);
    drop_ent.weapon_physdrop_sleeping = FALSE;
    drop_ent.weapon_physdrop_rest_start = 0;
    drop_ent.think = W_PhysDropDeferredRemove;
    drop_ent.nextthink = time + 0.1;
};

// Shared CSQC SendEntity for every server-spawned projectile (HL grenade,
// GL grenade, RPG rocket, crossbow bolt). Returning FALSE for the shooter
// hides the entity from them — they see only their CSQC-predicted fake.
// Other PVS clients receive origin + velocity + avelocity; the CSQC
// parser (cl_projectiles.qc) routes through cl_tosssmooth.qc for extrap +
// smooth, so visible flight stays smooth between server samples.
//
// Model + gravity factor are derived from proj_type via
// Projectile_TypeModel / Projectile_TypeGravity (shared/sh_weapons.qc),
// so we don't burn bytes on the wire for either.
float(entity playerent, float changedflags) projectile_SendEntity =
{
    if (playerent == self.owner)
        return FALSE;

    WriteByte(MSG_ENTITY, CSQC_ENT_PROJECTILE);
    WriteByte(MSG_ENTITY, self.proj_type);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);
    WriteCoord(MSG_ENTITY, self.avelocity_x);
    WriteCoord(MSG_ENTITY, self.avelocity_y);
    WriteCoord(MSG_ENTITY, self.avelocity_z);
    // Paintball projectiles carry per-shot colormod so remote viewers
    // see the same tinted ball the shooter does. Other types skip
    // the bytes entirely — wire stays compact for the common case.
    if (self.proj_type == PROJ_TYPE_PAINTBALL)
    {
        WriteByte(MSG_ENTITY, bound(0, floor(self.colormod_x * 255 + 0.5), 255));
        WriteByte(MSG_ENTITY, bound(0, floor(self.colormod_y * 255 + 0.5), 255));
        WriteByte(MSG_ENTITY, bound(0, floor(self.colormod_z * 255 + 0.5), 255));
    }
    return TRUE;
};

void() weapon_become_solid =
{
    // Bump SendFlags on every call regardless of phase.  During the toss
    // phase this drives the CSQC position update — rate is sv_toss_tickrate
    // (default 40 Hz) so observers see smooth physics instead of the
    // weapon freezing until weapon_settle_think starts pulsing.
    self.SendFlags |= 1;

    if (time < self.weapon_solid_time)
    {
        // Toss phase — poll at sv_toss_tickrate so CSQC gets a fresh
        // origin + velocity as the TOSS physics carries the drop through
        // the air. Faster send rate → less per-snapshot snap to absorb in
        // the CSQC smoothing layer.
        self.nextthink = time + WeaponDrop_NextThinkInterval(self);
        return;
    }

    // Pickup grace crossed: finalise the transition. Flip solid so the
    // dropper (and everyone else) can now touch for pickup, unhide
    // from the dropper, and hand off to weapon_settle_think which
    // will watch for motion to stop and then lock the pickup upright.
    self.solid = SOLID_TRIGGER;
    self.nodrawtoclient = world;
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = dropped_weapon_SendEntity;  // idempotent; safe re-assert

    // 3 s deadline (was 10 s). Most weapons settle below the 30 qu/s
    // threshold within a second of landing; the rest used to ride out
    // a 10 s deadline rolling on slight inclines, leaving them visibly
    // "alive" long after they should have stopped. weapon_settle_think
    // also damps residual motion below 100 qu/s to encourage faster
    // convergence within this window.
    self.weapon_settle_deadline = time + 3;
    self.think = weapon_settle_think;
    self.nextthink = time + WeaponDrop_NextThinkInterval(self);
};

// Polled once the weapon is solid. Waits until motion drops below a
// threshold (or the deadline hits), then keeps the pickup upright. No
// further think is scheduled afterward — the pickup remains a static trigger.
void() weapon_settle_think =
{
    vector flat_vel;
    float yaw;

    // Push a fresh CSQC snapshot on every poll tick so the client's
    // dropped-weapon entity tracks the server's falling/bouncing
    // origin. Without this the CSQC copy would freeze at whatever
    // position existed when SendEntity was first set (mid-toss for
    // player drops, spawn-placed origin for map weapons).
    self.SendFlags |= 1;

    flat_vel = self.velocity;
    flat_vel_z = 0;
    if ((fabs(self.velocity_z) > 30 || vlen(flat_vel) > 30)
        && time < self.weapon_settle_deadline)
    {
        // Strong damping once motion is moderate — encourages a fast
        // final settle so the weapon doesn't ride out the 3 s deadline
        // rolling/sliding at low speed. Skipped while still actively
        // bouncing (|vel| > 200) so the natural arc isn't squashed.
        if (vlen(self.velocity) < 200)
        {
            self.velocity  = self.velocity  * 0.65;
            self.avelocity = self.avelocity * 0.65;
        }

        // Still moving — keep ticking at sv_toss_tickrate so the CSQC
        // smoothing layer always has fresh samples to extrapolate from.
        self.nextthink = time + WeaponDrop_NextThinkInterval(self);
        return;
    }

    // Non-physics drops stay upright like classic Quake pickups. ODE drops
    // use their physics-driven angles and never enter this settle path.
    yaw = self.angles_y;
    self.angles = [0, yaw, 0];

    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.think = __NULL__;
    self.nextthink = 0;
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

    // Team-select players cycle through map cameras with PM_MOVETYPE_NONE
    // and no team yet.  They shouldn't pick up anything — otherwise the
    // camera player silently grabs weapons near the camera points (e.g.
    // the Scout on bloodassault spawns within touch range of a team-
    // select camera).
    if (player.player_team == TEAM_NONE || player.is_dead)
        return;

    slot = pickup.weapon_slot;

    // Reject if player already has a weapon in this slot — utility is a
    // small inventory, so only duplicate utility pickups are blocked.
    // SLOT_MELEE has a special case for WEP_MELEE (fists): fists are
    // INTRINSIC so the slot is effectively "empty" for pickup purposes
    // — walking over a katana / knife / crowbar while only carrying
    // fists overwrites the slot with the real weapon.  Without this
    // exception the player would be stuck with fists forever since
    // the drop key can't drop them.
    if (slot == SLOT_PRIMARY   && player.slot_primary)   return;
    if (slot == SLOT_SECONDARY && player.slot_secondary) return;
    if (slot == SLOT_MELEE
        && player.slot_melee
        && player.slot_melee != WEP_MELEE)               return;
    if (slot == SLOT_UTILITY)
    {
        if (!W_UtilityWeaponPickup(pickup.weapon)) return;
        if (pickup.weapon == WEP_SLINGSHOT && player.snowball_has_slingshot) return;
        if (W_UtilityEntityHasWeapon(player, pickup.weapon)) return;
    }

    // Copy ammo from world entity to player (self = pickup for pickupcopy)
    saved = self;
    self = pickup;
    if (self.pickupcopy)
        self.pickupcopy(player);
    self = saved;
    W_SlotAmmo_CopyDropToPlayer(player, pickup);

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
    else if (slot == SLOT_UTILITY)
    {
        if (pickup.weapon != WEP_SLINGSHOT)
        {
            if (!W_UtilityEntityHasWeapon(player, player.slot_utility))
                player.slot_utility = pickup.weapon;
            saved = self;
            self = player;
            W_UtilityRefreshSlotBinding();
            self = saved;
        }
    }

    // Auto-equip if this is a better weapon than what we're holding.
    // Primary > Secondary > Melee.  Holding WEP_MELEE (fists) counts
    // as "nothing equipped" for this decision — any real melee
    // pickup immediately swaps off the intrinsic fists.
    {
        float should_equip = FALSE;

        if (player.weapon == WEP_NONE || player.weapon == WEP_MELEE)
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

    // Route the pickup confirm sound through a CSQC multicast event
    // so the pickup-er's client can skip it (they already played the
    // sound locally via CSQC_PredictPickupWeapon). Without this skip,
    // 0-ping listen servers produce an audible echo — standard Quake
    // `sound()` has no exclude-client mode.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_WEAPON_PICKUP_SOUND);
    WriteByte(MSG_MULTICAST, num_for_edict(player));
    WriteCoord(MSG_MULTICAST, player.origin_x);
    WriteCoord(MSG_MULTICAST, player.origin_y);
    WriteCoord(MSG_MULTICAST, player.origin_z);
    multicast(player.origin, MULTICAST_PVS);

    // Sync proxy immediately so the client receives correct ammo values
    PM_SyncPredictionProxy(player);

    // Map weapons are hidden instead of removed so they can respawn on round reset
    if (pickup.map_weapon)
    {
        pickup.solid = SOLID_NOT;
        pickup.movetype = MOVETYPE_NONE;
        setmodel(pickup, "");
        pickup.touch = __NULL__;
        // Force a SendEntity re-fire so the CSQC copy receives the
        // empty model and hides locally. Without this, FTE's delta
        // compression sometimes skips the resend after setmodel(""),
        // leaving a ghost pickup on the client (visible, can be
        // walked over again, but slot-occupied so no re-pickup).
        pickup.SendFlags |= 1;
    }
    else
    {
        if (pickup.movetype == MOVETYPE_PHYSICS)
            W_PhysDropBeginRemove(pickup);
        else
            remove(pickup);
    }
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
    // ADS/scope profile + muzzle bone default to "no ADS, no bone" — each
    // weapon's Equip re-asserts what it needs (see W_SetADSProfile).
    self.weapon_ads_eligible = 0;
    self.weapon_ads_prefix   = "";
    self.weapon_scope_class  = SCOPE_CLASS_NONE;
    self.weapon_muzzle_bone  = "";
    W_ClearZoom();
};

// Equip the weapon that matches self.weapon, using the supplied function.
void(float slot_weapon, void() slot_equip) W_TryEquipSlot =
{
    if (self.weapon != slot_weapon || !slot_equip)
        return;
    W_ClearWeaponBindings();
    W_SlotAmmo_LoadLegacy(self, slot_weapon);
    slot_equip();   // sets weaponmodel, fire, reload, wepframe, initial frame/state
};

void() W_UtilityRefreshSlotBinding =
{
    self.slot_utility = W_UtilityNextCarried(WEP_NONE);
    self.slot_utility_equip = __NULL__;
    self.slot_utility_drop = __NULL__;

    if (self.slot_utility == WEP_HLGRENADE)
    {
        self.slot_utility_equip = W_HLGrenadeEquip;
        self.slot_utility_drop = W_HLGrenadeDrop;
    }
    else if (self.slot_utility == WEP_SNOWBALL)
    {
        self.slot_utility_equip = W_SnowballEquip;
        self.slot_utility_drop = W_SnowballDrop;
    }
    else if (self.slot_utility == WEP_CSHEGRENADE)
    {
        self.slot_utility_equip = W_CSHEGrenadeEquip;
        self.slot_utility_drop = W_CSHEGrenadeDrop;
    }
    else if (self.slot_utility == WEP_CSFLASHBANG)
    {
        self.slot_utility_equip = W_CSFlashbangEquip;
        self.slot_utility_drop = W_CSFlashbangDrop;
    }
    else if (self.slot_utility == WEP_CSSMOKEGRENADE)
    {
        self.slot_utility_equip = W_CSSmokeGrenadeEquip;
        self.slot_utility_drop = W_CSSmokeGrenadeDrop;
    }
};

void(float utility_wep) W_UtilitySetCurrentSlot =
{
    // C4 lives outside slot_utility entirely — it has its own dedicated
    // impulse (5) and HUD slot.  Skip here so selecting the C4 doesn't
    // clobber the player's actual carried utility (HE/flash/smoke).
    if (utility_wep == WEP_CFC4)
        return;

    if (!W_UtilityWeaponSelectable(utility_wep)
        || !W_UtilityPlayerHasWeapon(utility_wep))
        return;

    self.slot_utility = utility_wep;
    W_UtilityRefreshSlotBinding();
};

void() W_TryEquipUtility =
{
    // C4 lives entirely outside slot_utility — has its own impulse (5)
    // and HUD slot.  Bind self.fire/wepframe/etc. via W_CFC4Equip()
    // directly without touching slot_utility (which keeps tracking the
    // actual carried utility, e.g. HE/flash/smoke).  Drop uses the
    // direct WEP_CFC4 dispatch in W_DropCurrentWeapon, not
    // slot_utility_drop, so we don't bind that either.
    if (self.weapon == WEP_CFC4 && self.ammo_cfc4 > 0)
    {
        W_ClearWeaponBindings();
        W_CFC4Equip();
        return;
    }

    if (!W_UtilityWeaponSelectable(self.weapon)
        || !W_UtilityPlayerHasWeapon(self.weapon))
        return;

    W_UtilitySetCurrentSlot(self.weapon);
    W_ClearWeaponBindings();

    if (self.weapon == WEP_HLGRENADE)
        W_HLGrenadeEquip();
    else if (self.weapon == WEP_SNOWBALL)
        W_SnowballEquip();
    else if (self.weapon == WEP_CSHEGRENADE)
        W_CSHEGrenadeEquip();
    else if (self.weapon == WEP_CSFLASHBANG)
        W_CSFlashbangEquip();
    else if (self.weapon == WEP_CSSMOKEGRENADE)
        W_CSSmokeGrenadeEquip();
};

void() W_ChangeWeapon =
{
    W_TryEquipSlot(self.slot_primary,   self.slot_primary_equip);
    W_TryEquipSlot(self.slot_secondary, self.slot_secondary_equip);
    W_TryEquipSlot(self.slot_melee,     self.slot_melee_equip);
    W_TryEquipUtility();
};

void(float new_weapon) W_SelectWeapon =
{
    float cur = self.weapon;

    if (new_weapon == WEP_NONE || new_weapon == cur)
        return;

    if (self.slot_primary   != new_weapon &&
        self.slot_secondary != new_weapon &&
        self.slot_melee     != new_weapon &&
        !(W_UtilityWeaponSelectable(new_weapon) && W_UtilityPlayerHasWeapon(new_weapon)))
        return;

    if (cur != WEP_NONE)
        self.previous_weapon = cur;

    if (cvar("sv_debug_wepswap"))
    {
        dprint(sprintf("[SV wepswap] frame=%g  %g→%g  origin=%v  velocity=%v  speed=%.1f\n",
            time, cur, new_weapon, self.origin, self.velocity, vlen(self.velocity)));
        Drift_Dump("SV");
    }

    // Snapshot current effective speed factor before the weapon change,
    // then reset blend progress to 0 — PM_ReadMovevars advances it per
    // pmove tick.  Mirrors CSQC_PredictSelectWeapon.
    self.pm_weapon_prev_factor    = Weapon_SpeedFactor_Smooth();
    self.pm_weapon_blend_progress = 0;

    self.weapon = new_weapon;
    if (W_UtilityWeaponSelectable(new_weapon))
        W_UtilitySetCurrentSlot(new_weapon);
    W_ChangeWeapon();
};

// ============================================================
//  Weapon cycling
// ============================================================

void() W_SelectNextWeapon =
{
    // Mirror of CSQC_PredictSelectNextWeapon — when on a utility,
    // step through carried grenades before falling out to primary.
    if (W_UtilityWeaponSelectable(self.weapon))
    {
        float u = W_UtilityCycleCarried(self.weapon, 1);
        if (u != WEP_NONE) { W_SelectWeapon(u); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }

    if (self.weapon == self.slot_primary)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    // No weapon equipped - pick first available
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
};

void() W_SelectPrevWeapon =
{
    if (W_UtilityWeaponSelectable(self.weapon))
    {
        float u = W_UtilityCycleCarried(self.weapon, -1);
        if (u != WEP_NONE) { W_SelectWeapon(u); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }

    if (self.weapon == self.slot_primary)
    {
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        return;
    }
    // No weapon - pick last available
    if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
};

// Pick the player's strongest carried weapon, in slot priority:
// primary > secondary > melee > utility.  Used after dropping the
// currently-held weapon (W_DropCurrentWeapon) so the player always
// ends up holding the best thing they still have.
void() W_SelectStrongest =
{
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
};

void() W_SelectLastWeapon =
{
    // Standard "last inventory" path: switch back to previous_weapon
    // if it's still in our inventory.
    if (self.previous_weapon != WEP_NONE
        && self.previous_weapon != self.weapon
        && (self.slot_primary   == self.previous_weapon
         || self.slot_secondary == self.previous_weapon
         || self.slot_melee     == self.previous_weapon
         || (W_UtilityWeaponSelectable(self.previous_weapon)
             && W_UtilityPlayerHasWeapon(self.previous_weapon))))
    {
        W_SelectWeapon(self.previous_weapon);
        return;
    }

    // Spawn fallback (previous_weapon never set, or it was dropped /
    // consumed): jump to secondary first, then melee, then utility,
    // then primary as a last resort.  Mirror of
    // CSQC_PredictSelectLastWeapon's fallback so prediction and
    // server reach the same destination.
    if (self.slot_secondary && self.slot_secondary != self.weapon)
    { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee     && self.slot_melee     != self.weapon)
    { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility   && self.slot_utility   != self.weapon)
    { W_SelectWeapon(self.slot_utility);   return; }
    if (self.slot_primary   && self.slot_primary   != self.weapon)
    { W_SelectWeapon(self.slot_primary);   return; }
};

// ============================================================
//  Drop current weapon
// ============================================================

void() W_DropCurrentWeapon =
{
    void() drop_func;
    entity drop_ent;
    float  cur;
    float  phys_drop;

    cur = self.weapon;
    if (cur == WEP_NONE)
        return;

    drop_func = __NULL__;
    if (cur == self.slot_primary   && self.slot_primary_drop)   drop_func = self.slot_primary_drop;
    if (cur == self.slot_secondary && self.slot_secondary_drop) drop_func = self.slot_secondary_drop;
    if (cur == self.slot_melee     && self.slot_melee_drop)     drop_func = self.slot_melee_drop;
    if (cur == WEP_HLGRENADE && self.ammo_hlgrenade > 0)        drop_func = W_HLGrenadeDrop;
    if (cur == WEP_SNOWBALL  && self.ammo_snowball > 0)         drop_func = W_SnowballDrop;
    if (cur == WEP_CSHEGRENADE && self.ammo_cshegrenade > 0)    drop_func = W_CSHEGrenadeDrop;
    if (cur == WEP_CSFLASHBANG && self.ammo_csflashbang > 0)    drop_func = W_CSFlashbangDrop;
    if (cur == WEP_CSSMOKEGRENADE && self.ammo_cssmokegrenade > 0) drop_func = W_CSSmokeGrenadeDrop;
    if (cur == WEP_CFC4 && self.ammo_cfc4 > 0)                  drop_func = W_CFC4Drop;

    if (!drop_func)
        return;

    // Compute spawn position + velocity, with a wall-close check so a
    // player facing geometry doesn't get a "throw" that just slams the
    // prop into the wall in front of them.
    //   1. Trace forward from view by 48u — if we hit a wall under
    //      ~32u away, there's no throw room. Spawn at chest height
    //      with player-velocity only (no forward kick) — looks like a
    //      release rather than a throw, and the prop falls straight
    //      down past the player's feet.
    //   2. Otherwise normal throw (24u forward + forward/up velocity),
    //      with the back-step guard in case the spawn position itself
    //      lands in solid (tight corners, partial cover). If even the
    //      back-step can't find a clear spot, fall back to the chest
    //      drop instead of aborting — the player still loses the
    //      weapon either way.
    makevectors(self.v_angle);
    vector view_pos  = self.origin + self.view_ofs;
    vector throw_dir = v_forward;
    float  wall_close = FALSE;

    // Compute a safe drop-at-feet position. Trace DOWN from view to
    // find the actual floor and spawn 32u above it — this clears the
    // trimesh of even the chunkiest weapon (AWP radius ~32, USP ~28
    // per the [physdrop] enable logs). The previous "self.origin +
    // '0 0 24'" hardcode put the USP's trimesh 4u inside the floor on
    // a ducking-look-down drop, ODE's contact solver flung it
    // downward through the BSP, and the void watchdog only fired
    // 10-20s later when free-fall reached Z=-16384. Trace-then-clear
    // makes it physically impossible to spawn embedded.
    vector chest_pos;
    traceline(view_pos, view_pos - '0 0 1024', MOVE_NORMAL, self);
    if (trace_fraction < 1)
        chest_pos = trace_endpos + '0 0 32';
    else
        chest_pos = view_pos;   // no floor found in 1024u — just use eye

    if (cvar("sv_phys_unstick"))
    {
        // 64u trace, trigger if wall is within 48u — long-barrelled
        // weapons (AWP especially) extend far enough that the prop
        // model still clips even when the bbox CENTER is well clear.
        // Bumped from the original 32u threshold to give 16u of extra
        // breathing room.
        traceline(view_pos, view_pos + throw_dir * 64, MOVE_NORMAL, self);
        if (trace_fraction < 0.75)   // hit within ~48u
            wall_close = TRUE;
    }

    vector spawn_pos;
    vector spawn_vel;

    if (wall_close)
    {
        spawn_pos = chest_pos;
        spawn_vel = self.velocity;
    }
    else
    {
        spawn_pos = view_pos + throw_dir * 24;
        spawn_vel = self.velocity + throw_dir * 200 + '0 0 80';

        if (cvar("sv_phys_unstick"))
        {
            if (W_PhysDropFindClearBackstep(spawn_pos, throw_dir))
                spawn_pos = w_physdrop_clear_pos;
            else
            {
                // Even the back-step couldn't find a clear spot —
                // chest-drop fallback. Player still drops the weapon
                // (no slot-keep) so the action isn't silently swallowed.
                spawn_pos = chest_pos;
                spawn_vel = self.velocity;
            }
        }
    }

    // Spawn the world entity at the resolved position.
    drop_ent = spawn();
    drop_ent.owner = self;
    drop_ent.weapon_round_toss = FALSE;
    setorigin(drop_ent, spawn_pos);
    drop_ent.velocity = spawn_vel;

    weapon_drop_target = drop_ent;
    W_SlotAmmo_SaveLegacy(self, cur);
    drop_func();          // populates drop_ent (ammo, model, solid, touch, etc.)
    W_SlotAmmo_CopyPlayerToDrop(drop_ent, self, cur);
    weapon_drop_target = world;
    phys_drop = W_PhysDropAllowed(drop_ent.weapon);

    // Drop SFX — fires only once per committed drop (after the
    // drop_func != NULL early-out at the top of this function).
    // CHAN_VOICE so it doesn't step on weapon-fire sounds.  Attached
    // to the player so remote listeners hear it positioned correctly.
    sound(self, CHAN_VOICE, "sounds/player/weapondrop.wav", 1, ATTN_NORM);

    // Wire CSQC replication IMMEDIATELY rather than waiting for
    // weapon_become_solid after the pickup grace.  If we let the engine do
    // standard replication during the toss phase and then bolt
    // SendEntity on after the pickup grace, observers see BOTH the engine-side
    // flying entity AND the new CSQC entity simultaneously - the
    // "double drop" bug.  Map weapons avoid this by wiring
    // SendEntity at spawn (W_RegisterMapWeapon); death drops do
    // the same in W_DropAllWeaponsOnDeath; this matches.
    // weapon_become_solid still fires to flip solidity
    // (the re-wiring of SendEntity it does is idempotent).
    drop_ent.pvsflags = PVSF_NOREMOVE;
    drop_ent.SendEntity = dropped_weapon_SendEntity;
    drop_ent.SendFlags = 1;

    // Show the real server entity to the dropper immediately. CSQC swaps
    // out the local fake as soon as this confirmation arrives, while
    // weapon_solid_time still prevents early re-pickup.
    drop_ent.nodrawtoclient = world;

    // Override the drop_func's think schedule so weapon_become_solid
    // runs at 20 Hz from spawn.  Its dual-phase logic bumps SendFlags
    // each call so CSQC observers see the toss animate smoothly, then
    // after the pickup grace it finalises solidity and hands off to
    // weapon_settle_think (also at 20 Hz).  Stores the solidify
    // threshold separately so the function can tell which phase
    // it's in without relying on tick counting.
    drop_ent.weapon_solid_time = time + WEAPON_DROP_PICKUP_DELAY;
    if (phys_drop)
    {
        // The spawn position was already moved out of solid by the
        // pre-spawn back-step check at the top of this function, so
        // ODE sees a clear bbox here. No additional unstick needed.
        W_PhysDropStart(drop_ent, WEAPON_DROP_PICKUP_DELAY);
    }
    else
    {
        drop_ent.think = weapon_become_solid;   // idempotent
        drop_ent.nextthink = time + 0.05;
    }

    // Clear the vacated slot
    if (cur == self.slot_primary)
    {
        self.slot_primary       = WEP_NONE;
        self.slot_primary_equip = __NULL__;
        self.slot_primary_drop  = __NULL__;
        W_SlotAmmo_ClearForWeapon(self, cur);
    }
    else if (cur == self.slot_secondary)
    {
        self.slot_secondary       = WEP_NONE;
        self.slot_secondary_equip = __NULL__;
        self.slot_secondary_drop  = __NULL__;
        W_SlotAmmo_ClearForWeapon(self, cur);
    }
    else if (cur == self.slot_melee)
    {
        // Fists are intrinsic — after dropping the equipped melee
        // (knife, katana, etc.), fall back to WEP_MELEE so the
        // player always has SOMETHING in slot_melee.  Mirrors the
        // slot dispatch in sv_player.qc (WEP_NONE → WEP_MELEE).
        self.slot_melee       = WEP_MELEE;
        self.slot_melee_equip = W_MeleeEquip;
        self.slot_melee_drop  = __NULL__;
    }
    else if (W_UtilityWeaponSelectable(cur))
    {
        self.slot_utility = W_UtilityNextCarried(cur);
        W_UtilityRefreshSlotBinding();
    }

    self.weapon = WEP_NONE;
    W_ClearWeaponBindings();
    // Mirror of CSQC drop-then-equip: pick the strongest remaining
    // slot (primary > secondary > melee > utility) instead of the
    // cycle-order next, so dropping secondary leaves you on primary
    // rather than melee.
    W_SelectStrongest();
};

// ============================================================
//  Drop every inventory slot in random directions (on death)
// ============================================================
void() W_DropAllWeaponsOnDeath =
{
    float slot_idx;
    void() drop_func;
    float slot_wep;
    entity drop_ent;
    float yaw, pitch;
    float phys_drop;

    // mp_dropweapons gate (default 2 = drop everything):
    //   0 — drop nothing.  Bail before the slot loop entirely.
    //   1 — drop primary + secondary only.  Loop runs only over
    //       slot_idx 0 and 1.
    //   2 — drop everything (existing behaviour).  Loop runs the
    //       full 9-slot range.
    float drop_mode = cvar("mp_dropweapons");
    if (drop_mode <= 0)
        return;
    float slot_max = (drop_mode == 1) ? 2 : 9;

    for (slot_idx = 0; slot_idx < slot_max; slot_idx++)
    {
        drop_func = __NULL__;
        slot_wep = 0;
        if (slot_idx == 0)      { slot_wep = self.slot_primary;   drop_func = self.slot_primary_drop; }
        else if (slot_idx == 1) { slot_wep = self.slot_secondary; drop_func = self.slot_secondary_drop; }
        else if (slot_idx == 2) { slot_wep = self.slot_melee;     drop_func = self.slot_melee_drop; }
        else if (slot_idx == 3)
        {
            slot_wep = self.slot_utility;
            if (slot_wep == WEP_HLGRENADE && self.ammo_hlgrenade > 0) drop_func = W_HLGrenadeDrop;
            else if (slot_wep == WEP_SNOWBALL && self.ammo_snowball > 0) drop_func = W_SnowballDrop;
            else if (slot_wep == WEP_CSHEGRENADE && self.ammo_cshegrenade > 0) drop_func = W_CSHEGrenadeDrop;
            else if (slot_wep == WEP_CSFLASHBANG && self.ammo_csflashbang > 0) drop_func = W_CSFlashbangDrop;
            else if (slot_wep == WEP_CSSMOKEGRENADE && self.ammo_cssmokegrenade > 0) drop_func = W_CSSmokeGrenadeDrop;
        }
        else if (slot_idx == 4)
        {
            if (self.slot_utility != WEP_HLGRENADE && self.ammo_hlgrenade > 0)
            { slot_wep = WEP_HLGRENADE; drop_func = W_HLGrenadeDrop; }
        }
        else if (slot_idx == 5)
        {
            if (self.slot_utility != WEP_SNOWBALL && self.ammo_snowball > 0)
            { slot_wep = WEP_SNOWBALL; drop_func = W_SnowballDrop; }
        }
        else if (slot_idx == 6)
        {
            if (self.slot_utility != WEP_CSHEGRENADE && self.ammo_cshegrenade > 0)
            { slot_wep = WEP_CSHEGRENADE; drop_func = W_CSHEGrenadeDrop; }
        }
        else if (slot_idx == 7)
        {
            if (self.slot_utility != WEP_CSFLASHBANG && self.ammo_csflashbang > 0)
            { slot_wep = WEP_CSFLASHBANG; drop_func = W_CSFlashbangDrop; }
        }
        else if (slot_idx == 8)
        {
            if (self.slot_utility != WEP_CSSMOKEGRENADE && self.ammo_cssmokegrenade > 0)
            { slot_wep = WEP_CSSMOKEGRENADE; drop_func = W_CSSmokeGrenadeDrop; }
        }

        if (!slot_wep || !drop_func)
            continue;

        drop_ent = spawn();
        drop_ent.owner = self;
        drop_ent.weapon_round_toss = FALSE;

        yaw   = random() * 360;
        pitch = -40 + random() * 20;   // upward-ish toss
        makevectors([pitch, yaw, 0]);

        setorigin(drop_ent, self.origin + self.view_ofs * 0.5 + v_forward * 8);
        drop_ent.velocity = self.velocity + v_forward * (150 + random() * 150) + [0, 0, 100 + random() * 120];
        drop_ent.avelocity = '0 0 0';

        weapon_drop_target = drop_ent;
        W_SlotAmmo_SaveLegacy(self, slot_wep);
        drop_func();
        W_SlotAmmo_CopyPlayerToDrop(drop_ent, self, slot_wep);
        weapon_drop_target = world;
        phys_drop = W_PhysDropAllowed(drop_ent.weapon);

        // Wire CSQC replication IMMEDIATELY rather than waiting for
        // weapon_become_solid after the pickup grace.  If we let the engine do
        // standard replication during the toss phase and then bolt
        // SendEntity on after the pickup grace, observers see BOTH the engine-side
        // flying entity AND the new CSQC entity simultaneously - the
        // "double drop" bug.  Map weapons avoid this by wiring
        // SendEntity at spawn (W_RegisterMapWeapon); we do the same
        // here so death drops never have an engine-standard phase.
        // weapon_become_solid still fires to flip solidity
        // (the re-wiring of SendEntity it does is idempotent).
        drop_ent.pvsflags = PVSF_NOREMOVE;
        drop_ent.SendEntity = dropped_weapon_SendEntity;
        drop_ent.SendFlags = 1;

        // Show the real server entity to the victim immediately. Non-physics
        // fake scatter remains only until this SendEntity confirmation lands.
        drop_ent.nodrawtoclient = world;

        // Override the drop_func's think schedule so weapon_become_solid
        // runs at 20 Hz from spawn — its dual-phase logic bumps
        // SendFlags each call so the CSQC-replicated toss animates
        // smoothly for observers, instead of freezing until the pickup grace ends.
        drop_ent.weapon_solid_time = time + WEAPON_DROP_PICKUP_DELAY;
        if (phys_drop)
            W_PhysDropStart(drop_ent, WEAPON_DROP_PICKUP_DELAY);
        else
        {
            drop_ent.think = weapon_become_solid;  // idempotent
            drop_ent.nextthink = time + 0.05;
        }

        if (!phys_drop && SV_PlayerHasNetchan(self))   // skip bots (no netchan); engine-truth guard
        {
            // Unicast the victim a CSQC fake-drop event so they see the
            // scatter visually during the pickup-grace window. Physics drops skip
            // this so the ODE body is the only visual source.
            msg_entity = self;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_DEATH_DROP);
            WriteByte(MSG_ONE, slot_wep);
            WriteByte(MSG_ONE, drop_ent.weapon_slot);
            WriteCoord(MSG_ONE, drop_ent.origin_x);
            WriteCoord(MSG_ONE, drop_ent.origin_y);
            WriteCoord(MSG_ONE, drop_ent.origin_z);
            WriteCoord(MSG_ONE, drop_ent.velocity_x);
            WriteCoord(MSG_ONE, drop_ent.velocity_y);
            WriteCoord(MSG_ONE, drop_ent.velocity_z);
            WriteString(MSG_ONE, drop_ent.model);
        }

        if (slot_idx == 0)      { self.slot_primary   = WEP_NONE; self.slot_primary_equip   = __NULL__; self.slot_primary_drop   = __NULL__; W_SlotAmmo_ClearForWeapon(self, slot_wep); }
        else if (slot_idx == 1) { self.slot_secondary = WEP_NONE; self.slot_secondary_equip = __NULL__; self.slot_secondary_drop = __NULL__; W_SlotAmmo_ClearForWeapon(self, slot_wep); }
        else if (slot_idx == 2) { self.slot_melee     = WEP_NONE; self.slot_melee_equip     = __NULL__; self.slot_melee_drop     = __NULL__; }
        else if (slot_idx == 3) { self.slot_utility   = WEP_NONE; self.slot_utility_equip   = __NULL__; self.slot_utility_drop   = __NULL__; }
    }

    self.slot_utility = WEP_NONE;
    self.slot_utility_equip = __NULL__;
    self.slot_utility_drop = __NULL__;
    self.snowball_use_slingshot = FALSE;
};

// Drop the weapon currently in a slot as a world pickup — used by the buy
// menu when a purchase replaces an existing slot weapon.  Mirrors the
// per-slot drop in W_DropAllWeaponsOnDeath above, minus the death-only
// CSQC fake-drop event (this runs while the buyer is alive).  slot_idx:
// 0 primary / 1 secondary / 2 melee.  The caller passes the slot's CURRENT
// weapon + its drop fn-pointer BEFORE overwriting the slot.  Operates on
// self; the old weapon's ammo is moved onto the dropped pickup and cleared
// from the player so the new weapon's ammo is set cleanly by W_Refresh*Slot.
void(float slot_idx, float slot_wep, void() drop_func) W_DropSlotForBuy =
{
    entity drop_ent;
    float yaw, pitch, phys_drop;

    if (!slot_wep || !drop_func)
        return;

    drop_ent = spawn();
    drop_ent.owner = self;
    drop_ent.weapon_round_toss = FALSE;

    yaw   = random() * 360;
    pitch = -40 + random() * 20;   // upward-ish toss
    makevectors([pitch, yaw, 0]);

    setorigin(drop_ent, self.origin + self.view_ofs * 0.5 + v_forward * 8);
    drop_ent.velocity = self.velocity + v_forward * (150 + random() * 150) + [0, 0, 100 + random() * 120];
    drop_ent.avelocity = '0 0 0';

    weapon_drop_target = drop_ent;
    W_SlotAmmo_SaveLegacy(self, slot_wep);
    drop_func();
    W_SlotAmmo_CopyPlayerToDrop(drop_ent, self, slot_wep);
    weapon_drop_target = world;
    phys_drop = W_PhysDropAllowed(drop_ent.weapon);

    drop_ent.pvsflags = PVSF_NOREMOVE;
    drop_ent.SendEntity = dropped_weapon_SendEntity;
    drop_ent.SendFlags = 1;
    drop_ent.nodrawtoclient = world;
    drop_ent.weapon_solid_time = time + WEAPON_DROP_PICKUP_DELAY;
    if (phys_drop)
        W_PhysDropStart(drop_ent, WEAPON_DROP_PICKUP_DELAY);
    else
    {
        drop_ent.think = weapon_become_solid;
        drop_ent.nextthink = time + 0.05;
    }

    if (slot_idx == 0)      { self.slot_primary   = WEP_NONE; self.slot_primary_equip   = __NULL__; self.slot_primary_drop   = __NULL__; W_SlotAmmo_ClearForWeapon(self, slot_wep); }
    else if (slot_idx == 1) { self.slot_secondary = WEP_NONE; self.slot_secondary_equip = __NULL__; self.slot_secondary_drop = __NULL__; W_SlotAmmo_ClearForWeapon(self, slot_wep); }
    else if (slot_idx == 2) { self.slot_melee     = WEP_NONE; self.slot_melee_equip     = __NULL__; self.slot_melee_drop     = __NULL__; }
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
    case 4:   // Utility slot
    {
        float utility_wep = W_UtilityNextCarried(self.weapon);
        if (utility_wep) W_SelectWeapon(utility_wep);
        break;
    }
    case WEAPON_IMPULSE_DROP:   // Drop current weapon
        W_DropCurrentWeapon();
        break;
    case WEAPON_IMPULSE_GRAPPLE: // sv_grappling — fire / re-press release
        W_GrappleImpulse();
        break;
    case WEAPON_IMPULSE_GRAPPLE_RELEASE:
        // Press-and-hold release half — fired by the -grapple alias
        // on key release.  Force-releases the hook if one is live;
        // no-op otherwise (e.g. hook already auto-released via
        // timeout or arrived-at-anchor while the user kept holding).
        if (cvar("sv_grappling") && self.grapple_hook)
            W_GrappleRelease(self);
        break;
    case WEAPON_IMPULSE_RELOAD:   // Reload
        if (self.reload) self.reload();
        break;
    case WEAPON_IMPULSE_SPECIAL:  // Weapon-specific action (menu "Weapon Special")
        if (self.special)
        {
            self.special();
            W_SlotAmmo_SaveCurrent(self);
        }
        break;
    case WEAPON_IMPULSE_C4:  // Dedicated C4 select (impulse 5)
        if (self.ammo_cfc4 > 0)
            W_SelectWeapon(WEP_CFC4);
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

.float prev_weaponstate_anim;  // tracks weaponstate for player anim dispatch

void() W_WeaponFrame =
{
    float prev_state = self.prev_weaponstate_anim;

    // Check fire button (attack_finished debounce).
    //
    // Under sv_trust_clienthits >= 1 the server's autonomous fire is
    // disabled — the client drives fire timing via a `cmd cs`
    // notification (SH_StandardTryFire in shared/sh_weapon_standard.qc
    // → SV_ParseClientCommand "cs" handler in server/sv_player.qc).
    // Without this gate the server fires whenever IT observes button0
    // held and attack_finished elapsed, which diverges from the
    // client's count whenever input-cmd timestamps straddle a server-
    // tick boundary differently from the client's local clock —
    // visible as the "client mag empty, server fires an extra shot"
    // burst-trick symptom.  Under trust=1 the cs cmd is the sole
    // entry point for self.fire(); under trust=0 the existing
    // autonomous path is the sole entry point.  Exactly one source
    // of truth either way.
    // Hand-thrown grenades (HL hand, CS HE/Flash/Smoke) AND the C4 plant use
    // button0 directly (pin-pull / pre-throw / plant prefire) — those entry
    // points DON'T go through SH_StandardTryFire, so they never emit a `cmd cs`
    // notification.  Under trust>=1 the autonomous fire path is the ONLY way
    // they run server-side; gating them on trust would silently drop every
    // throw / plant (CSQC predicts it for the shooter, but no real projectile
    // spawns and no bomb is planted — the "+attack does nothing" report).
    // Always allow these.  W_CFC4Fire self-gates on weaponstate/ammo/location,
    // so polling it every held-button frame is safe (re-entry returns early
    // once WS_FIRE has started).
    // The gravity gun's +attack is a server-side prop GRAB (Carry_TryGrab), not
    // hitscan — it never emits a `cmd cs`, so like the grenades/C4 it must run
    // self.fire() autonomously or it does nothing under sv_trust_clienthits>=1.
    // W_GravGunFire self-gates (cooldown / already-carrying / spinning), so
    // polling it every held-button frame is safe.
    // Bots have no client to emit the `cmd cs` fire notification, so under
    // sv_trust_clienthits>=1 they'd never shoot.  Always let a bot fire its
    // weapon server-side (autonomous path) — same as the grenade/C4/gravgun
    // entry points below.
    // Melee weapons run the swing SERVER-side so a hit on a physics prop reaches
    // PhysProp_TryPushFromTrace (SSQC-only) and actually shoves it — otherwise the swing
    // only runs in client prediction and the hitclaim path damages players but never pushes
    // props.  W_MeleeStrike already masks its hit sound off the predicting attacker and defers
    // player damage to the hitclaim, so running it server-side adds no double FX/damage.
    float wep_bypasses_cs_notify = (self.is_bot
                                 || self.weapon == WEP_MELEE
                                 || self.weapon == WEP_KNIFE
                                 || self.weapon == WEP_HLCROWBAR
                                 || self.weapon == WEP_WRENCH
                                 || self.weapon == WEP_KATANA
                                 || self.weapon == WEP_BUTTERFLY
                                 || self.weapon == WEP_HLGRENADE
                                 || self.weapon == WEP_CSHEGRENADE
                                 || self.weapon == WEP_CSFLASHBANG
                                 || self.weapon == WEP_CSSMOKEGRENADE
                                 || self.weapon == WEP_CFC4
                                 || self.weapon == WEP_GRAVITYGUN);
    if ((cvar("sv_trust_clienthits") < 1 || wep_bypasses_cs_notify)
        && self.button0 && time >= self.attack_finished)
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

    // Trigger player body animation on ANY entry into FIRE or RELOAD.
    // Uses wep_action_id to detect re-fires even without a state transition
    // (e.g. melees that set WS_FIRE directly without SH_StandardTryFire).
    if (self.wep_action_id != self.prev_weaponstate_anim)
    {
        float family = W_GetPlayerAnimFamily(self.weapon);
        float crouching = (self.flags & FL_DUCKING) != 0;
        float mdlidx = self.player_visual_proxy ? self.player_visual_proxy.modelindex : 0;

        if (self.weaponstate == WS_FIRE)
            SH_PlayerAnim_PlayTop(SH_GetShootAnim(mdlidx, family, crouching), 0.3);
        else if (self.weaponstate == WS_RELOAD)
            SH_PlayerAnim_PlayTop(SH_GetReloadAnim(mdlidx, family, crouching), 3.0);

        self.prev_weaponstate_anim = self.wep_action_id;
    }

    W_SlotAmmo_SaveCurrent(self);
};
