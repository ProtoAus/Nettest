// ============================================================
//  server/sv_weapons.qc  -  Core weapon system
//  Damage helpers, weapon pickup touch, weapon slot management.
// ============================================================

// Forward declarations
void(entity player) PM_SyncPredictionProxy;  // defined in sv_player.qc
// Defined in sv_physprop.qc (sv_progs.src:301, after this file at :45 — QC
// forward-declares functions, which is all this needs).  It self-guards on
// .pp_scrape_active, so calling it on a prop that is not scraping is free.
//
// THE SCRAPE LOOP IS ISSUED WITH SOUNDFLAG_FORCELOOP|SOUNDFLAG_FOLLOW
// (sv_physprop.qc), and snd_mix.c rewinds a CF_FORCELOOP channel forever.  The
// only thing that ever cancels it is an explicit stop on the same entity and
// channel — so any code path that makes a scraping entity stop being ticked, by
// removing it OR by hiding it, strands that sample playing for the rest of the
// map.  This file had zero calls to it.
void(entity prop) PhysFiles_StopScrape;
void(float slot) W_RebindSlot;               // defined in sv_player.qc
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
// Day of Defeat, the twelve added beside the K98 above.
void() W_DodColtEquip;    void() W_DodColtDrop;
void() W_DodLugerEquip;   void() W_DodLugerDrop;
void() W_DodWebleyEquip;  void() W_DodWebleyDrop;
void() W_DodGarandEquip;  void() W_DodGarandDrop;
void() W_DodCarbineEquip; void() W_DodCarbineDrop;
void() W_DodK43Equip;     void() W_DodK43Drop;
void() W_DodTommyEquip;   void() W_DodTommyDrop;
void() W_DodMP40Equip;    void() W_DodMP40Drop;
void() W_DodStenEquip;    void() W_DodStenDrop;
void() W_DodGreaseEquip;  void() W_DodGreaseDrop;
void() W_DodMP44Equip;    void() W_DodMP44Drop;
void() W_DodBarEquip;     void() W_DodBarDrop;
// Day of Defeat, third batch.  The binoculars have NO Drop — no world model
// exists for them (see sh_wpn_dodbinocs.qc), so they cannot be dropped at all.
void() W_DodAutoEquip;    void() W_DodAutoDrop;
void() W_DodFCarbEquip;   void() W_DodFCarbDrop;
void() W_DodEnfEquip;     void() W_DodEnfDrop;
void() W_DodMortarEquip;  void() W_DodMortarDrop;
void() W_DodBinocsEquip;
// The two DoD grenades live in sh_wpn_csgrenades.qc, which compiles well after
// this file (sv_progs.src:50 vs :88), so both utility tables below need them
// declared here — same reason every other pair above is declared.
void() W_DodMillsEquip;   void() W_DodMillsDrop;
void() W_DodStickEquip;   void() W_DodStickDrop;
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
void() W_SatchelEquip;
void() W_SatchelDrop;
void() W_TripmineEquip;
void() W_TripmineDrop;
void() W_SnarkEquip;
void() W_SnarkDrop;
void() W_PenguinEquip;
void() W_PenguinDrop;
void() W_HGunEquip;
void() W_ShockEquip;
void() W_DispEquip;
void() W_JetEquip;
void() W_BGrapEquip;
// Drop halves of the four weapons W_RefreshPrimarySlot/SecondarySlot were
// missing — the equip halves were already declared above.
void() W_ShockDrop;
void() W_DispDrop;
void() W_JetDrop;
void() W_BGrapDrop;
// They Hunger's eight.  Declared here for the same reason as everything above:
// this file compiles at sv_progs.src:29, long before shared/weapons/sh_wpn_th*.qc
// at the bottom of the weapon block, and QC forward-declares functions but not
// fields — so the equip/drop pairs need a line each and the ammo fields stay
// with their own files.
void() W_TH1911Equip;
void() W_TH1911Drop;
void() W_THTommyEquip;
void() W_THTommyDrop;
void() W_THGreaseEquip;
void() W_THGreaseDrop;
void() W_THM14Equip;
void() W_THM14Drop;
void() W_THM16Equip;
void() W_THM16Drop;
void() W_THSawoffEquip;
void() W_THSawoffDrop;
void() W_THSpannerEquip;
void() W_THSpannerDrop;
void() W_THTeslaEquip;
void() W_THTeslaDrop;
// Sven Co-op and Opposing Force, defined in shared/weapons/sh_wpn_{sv,op,as}*.qc
// which compile AFTER this file.
void() W_MedkitEquip;      void() W_MedkitDrop;
void() W_UziEquip;         void() W_UziDrop;
void() W_UziAkEquip;       void() W_UziAkDrop;
void() W_MinigunEquip;     void() W_MinigunDrop;
void() W_SVM16Equip;       void() W_SVM16Drop;
void() W_PWrenchEquip;     void() W_PWrenchDrop;
void() W_SniperEquip;      void() W_SniperDrop;
void() W_SporeEquip;       void() W_SporeDrop;
void() W_EagleEquip;       void() W_EagleDrop;
void() W_ASShotgunEquip;   void() W_ASShotgunDrop;
void() W_SoflamEquip;      void() W_SoflamDrop;
void() weapon_medkit;      void() weapon_uzi;           void() weapon_uziakimbo;
void() weapon_minigun;     void() weapon_m16;           void() weapon_pipewrench;
void() weapon_sniperrifle; void() weapon_sporelauncher; void() weapon_eagle;
void() weapon_as_shotgun;  void() weapon_as_soflam;
void() W_HGunDrop;
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
// Day of Defeat's own classnames, out of dod.fgd, except the three noted in
// sh_weapons.qc: weapon_dodgreasegun (They Hunger owns weapon_greasegun), and
// weapon_sten / weapon_webley, which DoD delivers from a class menu rather than
// a map entity and so never named.
void() weapon_colt;
void() weapon_luger;
void() weapon_webley;
void() weapon_garand;
void() weapon_m1carbine;
void() weapon_gewehr;
void() weapon_thompson;
void() weapon_mp40;
void() weapon_sten;
void() weapon_dodgreasegun;
void() weapon_mp44;
void() weapon_bar;
void() weapon_bren;
void() weapon_fg42;
void() weapon_scopedfg42;
void() weapon_fcarb;
void() weapon_enfield;
void() weapon_mortar;
// No weapon_binoculars: dod ships no w_binoculars.mdl, so there is nothing to
// place on a map.  See sh_wpn_dodbinocs.qc.
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
// The thirteen Counter-Strike 1.6 guns.  These carry the REAL CS classnames -
// all thirteen were unused in this tree before they were added, so a GoldSrc CS
// map placing weapon_aug gets the AUG rather than "no spawn function".
void() weapon_p228;
void() weapon_fiveseven;
void() weapon_elite;
void() weapon_tmp;
void() weapon_mac10;
void() weapon_ump45;
void() weapon_p90;
void() weapon_galil;
void() weapon_famas;
void() weapon_aug;
void() weapon_sg552;
void() weapon_sg550;
void() weapon_xm1014;
void() PlayerSpawn;           // defined in sv_player.qc
void(float) W_SelectWeapon;   // defined later in this file
void() weapon_become_solid;   // defined later in this file
void() weapon_settle_think;   // defined later in this file
void() W_UtilityRefreshSlotBinding; // defined later in this file
float(float) W_UtilityWeaponSelectable; // defined in sh_wpn_snowball.qc
float(float) W_UtilityWeaponPickup;
// Releases any banked ammo for the weapon just picked up.  Defined in
// server/sv_goldsrc_ammo.qc, which compiles much later (it needs every weapon's
// MAX_AMMO_* constant), so it is reached through a forward declaration.
void(entity p, float wep) Ammo_DrainForWeapon;
void(entity p) Ammo_TickDrain;
float(entity, float) W_UtilityEntityHasWeapon;
float(float) W_UtilityPlayerHasWeapon;
// sh_wpn_hlsatchel.qc is sv_progs.src:59, this file is :29 — forward-declared
// so PlayerKilled can clear a dead player's live charges.
void(entity who) W_SatchelDeactivateAll;
float(float) W_UtilityNextCarried;
float(float, float) W_UtilityCycleCarried;
void() W_PhysDropThink;       // defined later in this file
float(float) W_PhysDropAllowed; // defined later in this file
void(entity, float) W_PhysDropStart; // defined later in this file
float() RoundToss_NextThinkInterval; // defined later in this file
float(entity, float) dropped_weapon_SendEntity;  // defined later in this file
void() W_DropAllWeaponsOnDeath;  // defined later in this file
void(entity p) CS_Shield_DropFrom;  // server/sv_cs_entities.qc, compiled after this
void(entity player, float wep) W_SlotAmmo_LoadLegacy;
void(entity player, float wep) W_SlotAmmo_SaveLegacy;
float(float wep) W_SlotAmmo_UsesSlot;
void(entity player) W_SlotAmmo_SaveCurrent;
void(entity drop, entity player, float wep) W_SlotAmmo_CopyPlayerToDrop;
void(entity player, entity drop) W_SlotAmmo_CopyDropToPlayer;
void(entity player, float wep) W_SlotAmmo_ClearForWeapon;
// The multi-carry primitives (sh_weapon_slotammo.qc, sv_progs.src:155 — this
// file is :40, so every slot-ammo call in here needs declaring first).
void(entity p, float slot, float wep) W_SlotAmmo_PointAt;
void(entity player, float wep) W_SlotAmmo_ReadWeapon;
void(entity player, float wep, float m, float a, float x) W_SlotAmmo_WriteWeapon;

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
        // WORSE THAN A REMOVE: this path hides the entity and clears its think,
        // so the prop contact detector never runs on it again.  A weapon that was
        // mid-slide when mp_nomapweapons hid it would keep its FORCELOOP scrape
        // sample playing forever, on an invisible entity, with nothing left alive
        // to cancel it.  No edict recycling required — it just never stops.
        PhysFiles_StopScrape(self);
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
    // W_PhysDropAllowed is NOT a pure predicate: it probes physics_supported()
    // and LATCHES sv_ode_loaded to "1" or "-1" (see :1896).  It must therefore be
    // evaluated in its own statement, never as the tail of an && chain.
    //
    // Why this matters: the term immediately before it reads the very cvar this
    // call writes.  fteqcc's `lo` (logic-ops / short-circuit) flag is currently
    // OFF, so every term runs unconditionally and this call doubles as the REPAIR
    // path - it is what flips a stale "-1" back to "1" on a later map, once the
    // physics plugin has finished loading.  Turn short-circuiting on with the call
    // still inline and that repair disappears: sv_ode_loaded > 0 is false while the
    // value is -1, the call is skipped, and nothing else in the tree can move it.
    // sv_main.qc:992 only retries the attach on == 0, so -1 becomes an unrecoverable
    // dead latch - every phys prop, dropped weapon, barrel and ragdoll inert until
    // the server process restarts.  Reached on any machine where the first
    // physics_supported(TRUE) fails: plug_load not yet complete, fteplug_box3d
    // missing, or the sv_physics_engine escape hatch at sv_main.qc:1630 failing.
    //
    // Hoisting keeps today's behaviour exactly (the call already early-outs on
    // sv_phys_drops <= 0 and on ineligible weapons, so it stays cheap).
    float phys_drop_allowed = W_PhysDropAllowed(self.weapon);
    float will_phys_drop = (cvar("sv_phys_drops") > 0
        && Weapon_PhysDropEligible(self.weapon)
        && cvar("sv_ode_loaded") > 0
        && phys_drop_allowed);

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
                    // Same stranded-loop trap as the W_RegisterMapWeapon hide
                    // path — see the note there.
                    PhysFiles_StopScrape(self);
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
                    //
                    // Same stranded-loop trap as the strip branch above, and it was
                    // only fixed there.  A map weapon that was mid-slide when the
                    // round ended is teleported by the setorigin() below and then
                    // re-spawned through W_RegisterMapWeapon -> W_PhysDropStart, and
                    // nothing in that chain clears .pp_scrape_active — so the loop
                    // keeps playing, now anchored to the weapon's ORIGINAL spawn
                    // point, at the start of every round.
                    PhysFiles_StopScrape(self);
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
                // Remove dropped weapons.  A round can restart while a dropped
                // gun is still sliding, and a bare remove() strands its scrape
                // loop — the sample keeps playing on a freed edict until
                // something else claims the slot.
                PhysFiles_StopScrape(e);
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
// Monsters get the same treatment through the same bookends, so there is exactly
// one pair of them in the mod.  Bodies live in sv_monsters.qc, which compiles
// after this file — QC forward-declares functions, which is all this needs.
// See Monster_ClassRenderBox there for what these do and why (short version:
// Half-Life's SetObjectCollisionBox, the shot-cull volume that is separate from
// the movement hull, which this build had never ported).
void() W_MonstersExpandHitboxes;
void() W_MonstersRestoreHitboxes;
// Broadphase hint for the walk above — publish the trace's segment + swept hull and
// it skips monsters the trace cannot reach.  Valid only until the matching restore.
void(vector a, vector b, vector hmin, vector hmax) Monster_CullSegment;
// The NPC half of sv_debug_hitboxes.  Body is in sv_monsters.qc, not here, because it
// reads monster_render_min/max — QC forward-declares FUNCTIONS but not GLOBALS, and
// this file compiles ahead of that one.
void(entity target, float mode) W_SendServerNPCHitbox;

void() W_PlayersExpandHitboxes =
{
    W_MonstersExpandHitboxes();

    // NOTE: no early-out on expand<=0.  A disguised hider needs its rotation-safe
    // trace volume regardless of the limb-padding cvar — the two are unrelated.
    float expand = cvar("sv_hitbox_expand");

    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.solid == SOLID_SLIDEBOX)
        {
            if (p.ph_disguise_modelindex)
            {
                // Prop Hunt: still no limb-reach padding on a disguised hider — a
                // tincan's hitbox is exactly the tincan — but the box must ENCLOSE the
                // rotated prop mesh or MOVE_HITMODEL culls the shot before it reaches a
                // triangle.  See PH_ExpandTraceBbox (shared/sh_weapons.qc).
                PH_ExpandTraceBbox(p);
            }
            else if (expand > 0)
            {
                vector mn = p.mins;
                vector mx = p.maxs;
                mn_x -= expand; mn_y -= expand; mn_z -= expand;
                mx_x += expand; mx_y += expand; mx_z += expand;
                setsize(p, mn, mx);
            }
        }
        p = p.player_chain_next;
    }
};

void() W_PlayersRestoreHitboxes =
{
    W_MonstersRestoreHitboxes();

    float expand = cvar("sv_hitbox_expand");

    entity p = player_chain_head;
    while (p)
    {
        // The disguised path restores from an absolute save, so it is exact and needs
        // no condition beyond its own latch.  The padding path stays delta math against
        // the same predicate the expand used.
        if (p.ph_trace_inflated)
            PH_RestoreTraceBbox(p);
        else if (expand > 0 && !p.is_dead && p.solid == SOLID_SLIDEBOX
                 && !p.ph_disguise_modelindex)
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
    // Per-frame cache, not three cvar() hashes per traceline: a penetrating shot
    // calls this FIVE times (once per trace) and its restore partner five more,
    // so this cost 30 string-hash lookups per shot and 600 a second on an MG.
    // Refreshed in StartFrame beside the other pp_cached_* values.
    float tx = pp_cached_wep_trace_bbox_x;
    float ty = pp_cached_wep_trace_bbox_y;
    float tz = pp_cached_wep_trace_bbox_z;
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
    if (!target)
        return;
    // NPCs are not excluded from hitbox EXPANSION — W_MonstersExpandHitboxes
    // (sv_monsters.qc) runs inside the same bookend players use.  They were
    // only excluded from the OVERLAY, and they cannot use the player wire format:
    // the entnum below is a WriteByte and a monster edict passes 255.  Different
    // event, different payload, single cull box instead of 20 player bone boxes.
    if (target.classname != "player")
    {
        W_SendServerNPCHitbox(target, 1);
        return;
    }

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

    // Melee's half of the corpse opt-in.  See W_CorpseMaskBegin
    // (sh_weapon_standard.qc) for why this is needed and why it is a pair —
    // hitscan goes through W_ServerTraceLineWithPhysDrops, not through here.
    // Half-Life's rule is that both reach a corpse: bullets bleed it and never
    // gib it, club/blast/sonic chip it apart, and W_DeadTakeDamage already
    // enforces that split by damage type.
    int saved_mask = W_CorpseMaskBegin(self);

    // THE MONSTER CULL BOX HAS TO BE INFLATED HERE TOO, and for years it was not.
    // sv_monsters.qc:932-936 asserted that W_PlayersExpandHitboxes "is already
    // bracketed correctly around every weapon trace in the mod".  It is bracketed
    // around three: W_StandardHitscanShoot, W_PenetratingHitscanShoot and paintball.
    // This function is the OTHER funnel — every melee weapon reaches it through
    // W_MeleeTrace, and the shotguns, gauss, egon, crossbow, tesla, rebar, wrench and
    // medkit call it directly: 27 sites in all, every one of them tracing against a
    // monster's raw MOVEMENT hull.  A gargantua drawn 214 units tall was shootable up
    // to z=64 with a crowbar or a shotgun but to z=214 with a rifle, and nothing said
    // so.  World_ClipToLinks rejects on absmin/absmax before MOVE_HITMODEL ever runs.
    //
    // Bracketing the funnel rather than the 27 leaves is the whole point — the comment
    // above was right that 27 hand-written pairs is how one ends up unpaired — and the
    // pair is now nest-safe (mon_cull_depth) so wrapping a bracketed caller is fine.
    Monster_CullSegment(src, end, '0 0 0', '0 0 0');
    W_PlayersExpandHitboxes();
    Lagcomp_TraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();

    W_CorpseMaskEnd(self, saved_mask);
    self.dimension_hit = saved_dim_hit;
};

// ============================================================
//  W_MeleeTrace — the line trace, then Half-Life's HULL fallback.
// ============================================================
// EVERY Half-Life melee weapon does this and none of ours did:
//
//     UTIL_TraceLine( vecSrc, vecEnd, dont_ignore_monsters, ..., &tr );
//     if ( tr.flFraction >= 1.0 )
//     {
//         UTIL_TraceHull( vecSrc, vecEnd, dont_ignore_monsters, head_hull, ..., &tr );
//         ...
//     }
//                                       -- dlls/crowbar.cpp, CCrowbar::Swing
//
// `head_hull` is hull 3, (-16,-16,-18)..(16,16,18).  So a swing that a
// hair-thin ray misses is retried with a 32x32x36 box, and THAT is why melee in
// Half-Life connects when it looks like it should.  Without it a crowbar had to
// be aimed at a single pixel of a hitbox, which on something small and low - a
// headcrab is 24 wide and 24 tall, and its model is smaller than its bbox -
// meant swinging repeatedly through it for no damage.  That is the reported
// "melee hits, but no damage" and "melee on NPCs is just inaccurate and bad".
//
// The hull result is used AS the hit: HL only re-derives a nicer impact POINT
// from it (FindHullIntersection), and the entity it names is the entity that
// takes the damage either way.  trace_endpos after a box trace is the box's
// centre at contact, which for a 32-wide box can sit slightly inside the target;
// that is only ever read for the impact effect, so it is left alone rather than
// approximated.
//
// Only ever widens a MISS.  A line trace that already hit something is returned
// untouched, so a swing that connects with the wall in front of you still
// connects with the wall and not with whatever the box happens to clip.
const vector MELEE_HULL_MIN = '-16 -16 -18';
const vector MELEE_HULL_MAX = '16 16 18';

void(vector src, vector end) W_WeaponTraceLine;

float(vector src, vector end) W_MeleeTrace =
{
    W_WeaponTraceLine(src, end);
    if (trace_fraction < 1.0)
        return FALSE;                       // the ray found it; nothing to widen

    float saved_dim_hit = self.dimension_hit;
    self.dimension_hit = saved_dim_hit | PHYSDROP_DIM;
    int saved_mask = W_CorpseMaskBegin(self);

    // The hull retry needs the same inflation the ray above just got — see the note
    // in W_WeaponTraceLine.  Without it the widened swing is widened against the
    // movement hull only, which is exactly the case (something big, or a limb out to
    // the side) the retry exists to catch.
    // Segment padded by the swing HULL, not the bare ray — this is a tracebox, so the
    // swept volume is 32x32x36 wider than the line and the broadphase must say so or
    // it can cull exactly the off-axis target the hull retry exists to catch.
    Monster_CullSegment(src, end, MELEE_HULL_MIN, MELEE_HULL_MAX);
    W_PlayersExpandHitboxes();
    Lagcomp_TraceBox(src, MELEE_HULL_MIN, MELEE_HULL_MAX, end,
                     MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();

    W_CorpseMaskEnd(self, saved_mask);
    self.dimension_hit = saved_dim_hit;

    return trace_fraction < 1.0;            // TRUE only when the hull saved it
};

// ============================================================
//  W_MeleeHitIsBody — "thwack" or "dong"?
// ============================================================
// Half-Life picks the melee impact sound from the target's CLASSIFICATION, not
// from whether it is damageable:
//
//     if ( pEntity->Classify() != CLASS_NONE && pEntity->Classify() != CLASS_MACHINE )
//         ... cbar_hitbod1/2/3 ...
//     if (fHitWorld)
//         ... TEXTURETYPE_PlaySound + cbar_hit1/2 ...
//
// CLASS_NONE is what every non-monster returns - the world, a func_breakable, a
// crate - so a wooden box gets the metal-on-material sound and a zombie gets
// flesh.  CLASS_MACHINE is the opt-out for robots and gun turrets, which is
// exactly the "unless the NPC is a robot" the report asks for.
//
// Players are not a Classify() case in HL (they are CLASS_PLAYER, non-zero,
// non-machine) and are included here for the same reason.
//
// This is NOT W_CanDamageTarget: that answers "may I hurt this", which is TRUE
// for breakable brushes and would give a crate a wet thump.
float(entity hit) W_MeleeHitIsBody =
{
    if (!hit || hit == world)
        return FALSE;
    if (hit.classname == "player")
        return TRUE;
    if (!(hit.flags & FL_MONSTER) && !hit.ai_class)
        return FALSE;                       // brushwork, props, the world
    if (hit.ai_class == CLASS_MACHINE)
        return FALSE;                       // robots and turrets ring, not squelch
    return TRUE;
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
    // Monsters are flesh too.  Without this a headcrab took a CONCRETE DUST hit,
    // because the fallback at the bottom resolves the WORLD TEXTURE under the
    // impact point and a monster has no surface to resolve.  .bloodcolor was set
    // by every AI class and read by absolutely nothing until here; it stays the
    // per-class value so a future CSQC tint can use it, while the material code
    // is what picks the flesh effect today.
    if (hit && (hit.flags & FL_MONSTER))
        return (hit.health <= 0) ? IMPACT_MAT_FLESH_LETHAL : IMPACT_MAT_FLESH;
    if (hit && Brush_IsBreakableClass(hit))
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
    // World / untagged brush: resolve the hit surface's TEXTURE -> material.  Q1 BSP traces carry
    // no surface (trace_surfacename is empty), so look the texture up from the hit POINT
    // (trace_endpos, still the fire trace's endpoint here) on the hit brush model.  Falls back to
    // IMPACT_MAT_DEFAULT when nothing resolves.
    return Surf_ImpactMat(Surf_MaterialAtPoint(hit, trace_endpos));
};

// Send bullet impact effect to all players EXCEPT the shooter.
// ---------------------------------------------------------------------------
// One writer for every impact-effect entry point below.
//
// The three functions that follow differed only in where the normal and the
// material came from and whether the hit was an entry; the wire layout itself
// was copy-pasted three times.  That is precisely how the shooter field came to
// be a byte in three places at once, and why fixing it in one of them would have
// left two live.
//
// `shooter` is an explicit parameter rather than `self` because monsters fire
// through this path too, and the tracer has to anchor on whoever actually shot.
// Raised around a multi-pellet fire loop so every pellet's impact event goes out
// tagged as part of one blast; see the pack in W_ImpactEffectSend below and
// pend_blast in client/cl_bulletimpact.qc for why the receiver needs it.
//
// Loop-scoped rather than wrapped around each send because a pellet loop emits
// through THREE senders depending on what it hit (W_ImpactEffect for world,
// W_ImpactEffectAllMat twice for flesh and breakables) — 17 call sites across
// the seven multi-pellet weapons. Scoping it to the loop covers all of them,
// including any added later.
//
// Unlike the client's bh_shotgun_blast this cannot go stale: these sends are
// synchronous, so the flag is down again before the fire function returns.
float sv_impact_is_blast;

void(vector pos, vector normal, float mat, entity target, entity shooter, float is_entry) W_ImpactEffectSend =
{
    entity p = player_chain_head;
    while (p)
    {
        // PVS-cull + skip bots (no netchan): only players who can see the impact
        // need the ric/decal/tracer.  Skipping the shooter avoids echoing their
        // own predicted impact back at them; for a monster nobody is skipped,
        // which is correct - no client predicted that shot.
        //
        // ...EXCEPT WHEN THE TARGET IS A MONSTER, which is now the one case where
        // the shooter is NOT predicting their own impact.  CSQC used to draw the
        // flesh burst itself off a ray-vs-AABB test that is a strict superset of
        // the server's per-bone HLMDL_Trace, so it painted blood on shots that
        // landed no damage at all - "hit splashes but the HP doesn't change".  That
        // prediction is gone (sh_weapon_logic.qc, the csqc_monster_proxy branches),
        // and this is what replaces it: the authoritative effect, at the
        // hitbox-precise position, delivered to the shooter as well.  One ping of
        // latency buys the invariant that blood means damage.
        float to_shooter = (target.flags & FL_MONSTER) != 0;
        if ((p != shooter || to_shooter) && SV_PlayerHasNetchan(p) && checkpvs(pos, p))
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            // Normal is a unit vector (components in [-1,+1]); quantise to
            // a signed byte biased by 127 to save 9 B/event over WriteCoord.
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            // Target entnum so remote clients can attach bullet-hole decals to
            // the correct func_breakable / BSP entity and remove them on
            // CSQC_EVENT_BRUSH_DESTROY.  0 = world / non-BSP hit.
            WriteShort(MSG_ONE, num_for_edict(target));
            // Shooter entnum, used by remote clients to anchor the tracer's start.
            //
            // SHORT, not byte.  The old comment here read "players never exceed
            // maxclients so a byte is enough" - true for players, and false the
            // moment a monster pulls a trigger.  th_ep1_01 alone builds 209
            // monsters on top of the world's own entities, so monster edict
            // numbers pass 255 routinely, and a truncated number does not fail
            // safely: it resolves to whatever entity occupies slot (n & 255) and
            // the tracer flies in from there.
            WriteShort(MSG_ONE, num_for_edict(shooter));
            // bit 0 = is_entry, bit 1 = multi-pellet BLAST.
            //
            // Packed into the existing byte rather than sent as a new one: a
            // blast is 8-16 of these events, so a whole extra byte each would
            // cost more than the flag is worth, and is_entry only ever uses one
            // bit.  The receiver needs it because every pellet of a blast
            // carries the SAME wep_action_id below, so without it they all fall
            // into one per-shot cap bucket and a remote viewer sees a single
            // decal for the whole spray.
            WriteByte(MSG_ONE, (is_entry ? 1 : 0) | (sv_impact_is_blast ? 2 : 0));
            WriteByte(MSG_ONE, shooter.wep_action_id);   // per-shot action id -> remote per-shot decal cap
        }
        p = p.player_chain_next;
    }
};

// The shooter sees their own predicted impact instantly.
void(vector pos) W_ImpactEffect =
{
    if (pointcontents(pos + trace_plane_normal * -2) == CONTENT_SKY)
        return;

    // is_entry=1: the primary/entry impact draws the tracer.
    W_ImpactEffectSend(pos, trace_plane_normal, W_ClassifyImpactMaterial(trace_ent),
                       trace_ent, self, 1);
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

    // is_entry=0: penetration EXIT — decal only, NO tracer (the entry already
    // drew it; an exit tracer is the doubled line).
    W_ImpactEffectSend(pos, normal, W_ClassifyImpactMaterial(trace_ent),
                       trace_ent, self, 0);
};

// Same as W_ImpactEffectAll but with an explicit material code, bypassing
// the auto-classifier. Lets the caller upgrade FLESH → FLESH_LETHAL on
// killing blows and headshots so the lethal blood-splash variant fires.
void(vector pos, vector normal, float mat) W_ImpactEffectAllMat =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    // is_entry=1: explicit-material primary hit (player/flesh) — draws a tracer.
    // The shooter is skipped inside the writer: their CSQC_PredictFireWeapon path
    // already ran CSQC_BulletImpact and plays the ric at the impact point, so
    // without the skip the attacker hears a ping-delayed echo.
    W_ImpactEffectSend(pos, normal, mat, trace_ent, self, 1);
};

// As above, but for a shot fired by something that is not `self` — the monster
// combat layer, which runs its traces with `self` already switched but wants the
// option of naming the shooter explicitly (a squad leader's tracer anchoring on
// the member that actually fired, for instance).
void(vector pos, vector normal, float mat, entity shooter) W_ImpactEffectFrom =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    W_ImpactEffectSend(pos, normal, mat, trace_ent, shooter, 1);
};

// Same, for an impact that was NOT made by a bullet.
//
// is_entry = 0 is not a hack here, it is the flag's existing meaning: the client
// reads it as "decal only, no tracer, no travel delay" (see the comment beside
// CSQC_SpawnTracer, client/cl_bulletimpact.qc:1800-1803, where it is already used
// for a penetration exit wound). Everything else is unchanged - the decal, the
// material, the ric, and the shooter's own .wep_action_id, which is what buckets
// the remote per-shot decal cap and is the reason the OWNER still has to be passed
// rather than the projectile.
//
// The bug this exists for: a monster's spit/hornet/spike landed and a bullet
// streak was drawn from the creature's muzzle to the impact point, because
// AI_ProjTouch reused W_ImpactEffectFrom above and that hard-codes is_entry = 1.
// A projectile did not travel that line as a bullet - it flew there as an entity
// the player could already see - so there is nothing to draw. Half-Life's
// CSquidSpit::Touch (bullsquid.cpp:127-175) emits a decal, two sounds and a
// sprite spray, and no tracer of any kind.
void(vector pos, vector normal, float mat, entity shooter) W_ImpactEffectFromNoTracer =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    W_ImpactEffectSend(pos, normal, mat, trace_ent, shooter, 0);
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
    // trigger_camera "Player Invulnerable" (spawnflag 256).  Checked BEFORE
    // the unconditional player accept below, which is the whole reason this
    // is the right chokepoint: .takedamage is meaningless on players in this
    // mod (they sit at DAMAGE_NO and are accepted anyway), so a takedamage
    // gate would do nothing.  Every hitscan / pellet / melee / projectile /
    // trigger_hurt path funnels through here.
    //
    // NOT covered — the movers that subtract .health directly instead of
    // calling W_ApplyDamage: func_train_blocked, func_tracktrain, and
    // func_vehicle.  Those carry their own cutscene_immune test.
    if (target.cutscene_immune)
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
            && Brush_IsBreakableClass(target)
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

// Sven item_inventory drop-on-death.  Defined in sv_item_inventory.qc
// (position 265), which compiles after this file; the INV_LEAVE_* modes it
// takes are in sv_customdefs.qc for the reason QC always forces — a function
// forward-declares, a constant does not.
void(entity plyr, float leave) Inv_DropAll;

// Map-script death hook — server/sv_mapscript.qc, position 377.  Same forward
// declaration story as Inv_DropAll above.
void() MapScript_PlayerDiedOrLeft;

void(entity attacker, entity victim) PlayerKilled =
{
    Carry_Drop(victim);        // drop any carried prop on death so it falls free
    Ragdoll_CarryDrop(victim);  // and release any gravity-gunned corpse
    // Sven item_inventory: drop the carried items unless the mapper ticked
    // holder_keep_on_death, whose stated purpose is "so they can keep it while
    // being revived".  Dropping is the default, and it is what puts a quest
    // item back in play when its carrier dies halfway to the objective.
    Inv_DropAll(victim, INV_LEAVE_DEATH);
    // HL's DeactivateSatchels on PlayerKilled.  Removes, never detonates - a
    // death-triggered blast would be a free posthumous frag.  Without this the
    // spawn-time satchel_state reset would strand the previous life's charges
    // on the map with nothing able to set them off.
    W_SatchelDeactivateAll(victim);

    // ...and the GRAPPLE, which this never tore down.  PlayerPreThink returns
    // early for a dead player, so W_GrapplePullTick stops running the moment the
    // player dies: nothing clears the hook entity, nothing clears the CSQC rope
    // flag, and nothing stops the CHAN_BODY pull loop — that state simply sits
    // there until PlayerSpawn's defensive W_GrappleRelease at respawn.  The
    // audio tail is only the audible half; the state leak is the bug.
    // W_GrappleRelease already removes the hook, clears
    // grapple_attached / grapple_rope_active / grapple_next_loop and calls
    // SV_StopChannel(player, CHAN_BODY).
    if (victim.grapple_hook || victim.grapple_rope_active)
        W_GrappleRelease(victim);

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

            // Prop Hunt: finding + killing a hider HEALS the seeker (offsets the
            // missfire self-damage economy; classic prop-hunt balance).
            if (cvar("sv_gamemode") == GAMEMODE_PROPHUNT
                && attacker.player_team == TEAM_RED
                && victim.player_team == TEAM_BLUE
                && !attacker.is_dead)
                attacker.health = min(attacker.health + cvar("mp_ph_killheal"), 100);
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

    // nettest server ragdoll: stash the victim's LAST ALIVE framestate BEFORE SH_PlayerAnim_Death
    // overwrites it, so the ragdoll (spawned below) starts in the pose they were shot in (mid-run etc.).
    // Prop Hunt: capture UNCONDITIONALLY — a disguised hider DECLOAKS on death (the disguise is
    // cleared below, before the detach), so the corpse reveals the real player model and ragdolls
    // it.  victim.frame/baseframe hold a valid player anim even while disguised (SH_PlayerAnim_Update
    // runs every PlayerPostThink; the prop mesh is a client-render-only substitution).
    Ragdoll_CaptureAlivePose(victim);

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

    // Prop Hunt DECLOAK: clear the disguise on the victim BEFORE the detach.  The
    // corpse proxy's server .model is ALWAYS the team player model (the prop is a
    // client-render-only substitution keyed on ph_disguise_modelindex), so zeroing
    // the disguise here makes the detach's final Sync network disguise=0 → the
    // client reverts the corpse to the real player model, which the ragdoll below
    // then flops.  The smoke poof (W_ApplyDamage) covers the swap.  MUST come
    // after Ragdoll_CaptureAlivePose (needs the live pose) and before the detach.
    if (victim.ph_disguise_modelindex)
        PropHunt_ClearDisguise(victim);

    // Detach the visual proxy as a corpse — the body persists on the
    // ground for the rest of the round (cleaned up by RoundRestart's
    // corpse sweep). Works in both TDM (PlayerSpawn's Ensure spawns a
    // fresh proxy at the respawn point) and Elimination (PlayerJoinSpectate
    // sees player_visual_proxy == world and skips its remove).
    // Detach reads victim.velocity for the corpse's initial fall vector,
    // so this MUST run before the velocity zero below.
    Player_VisualProxy_DetachAsCorpse(victim);

    // nettest server ragdoll: spawn the authoritative flopping corpse from the just-detached proxy
    // (reads victim.last_corpse for the model/skin/pose + victim.velocity for the death momentum, so
    // this MUST run after the detach and BEFORE the velocity zero below).  Only on weapon/FF kills.
    // Prop Hunt: the disguise was cleared above, so a killed hider ragdolls its revealed player
    // model here just like any other death (non-IQM team models no-op inside → plain decloaked corpse).
    if (kf_cause == KILL_CAUSE_WEAPON || kf_cause == KILL_CAUSE_FRIENDLYFIRE)
        Ragdoll_SpawnFromDeath(attacker, victim);

    // Now safe to wipe the live player's velocity — corpse already has
    // its copy.  The dead player entity stays at rest until respawn.
    victim.velocity = '0 0 0';

    // Map-script PlayerKilled hook.  LAST, after victim.health is already 0 and
    // the body is settled, because th_escape's stand-in counts the living and
    // ends the map when the count reaches zero — running it earlier would count
    // the corpse.
    MapScript_PlayerDiedOrLeft();
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

// ---------------------------------------------------------------------------
// corpses
// ---------------------------------------------------------------------------
// Defined in sv_ai_gibs.qc (compiles after the AI layer, because picking a gib
// set needs the monster's CLASS_* classification).
void(entity body, entity attacker) Monster_Gib;
float(entity m, float dmgbits, float lastdmg) Gib_ShouldGibOnDeath;
// Defined in sv_ai_core.qc, same arrangement and same reason as the two above:
// the pre-damage veto a monster class is allowed to have.  See .ai_damagefilter.
float(entity m, float damage, float dmgbits) AI_DamageFilter;

// Declared authoritatively in sv_monsters.qc, which compiles at position 308 —
// far behind this file.  QC cannot forward-declare a field, and an IDENTICAL
// re-declaration resolves to the same offset, so this is the same arrangement
// sub_use_type already uses across sv_doors/sv_triggers/sv_th_entities.
.float  bloodcolor;

float ai_dbg_corpse_hit;	// shots that landed on a body
float ai_dbg_corpse_chip;	// gib-type hits that took a bite out of one
float ai_dbg_corpse_gib;	// bodies torn apart

// combat.cpp:974-1017, CBaseMonster::DeadTakeDamage.
//
// The return value matters and is easy to get wrong: HL returns 1 for a bullet
// that does nothing at all, because by the time this runs TraceAttack has
// ALREADY spawned the blood.  "This hit did no damage" and "this hit did not
// land" are different answers, and only the second one should suppress an
// impact effect.  So this returns the damage either way.
// How much env_blood "damage to simulate" one point of real damage buys.  The
// CSQC end turns this into a particle count (amount * 0.1, capped at 48), so a
// 10-damage crowbar swing at x10 is a ten-particle puff and a shotgun blast is
// the cap.  The floor keeps a 1-damage graze from producing a single speck.
const float CORPSE_BLOOD_SCALE = 10;
const float CORPSE_BLOOD_MIN   = 60;

float(entity attacker, entity target, float damage, float bits) W_DeadTakeDamage =
{
    ai_dbg_corpse_hit = ai_dbg_corpse_hit + 1;

    // BLEED IT.  Half-Life sprays before this function is ever reached, and the
    // note above about the return value is the same fact seen from the other
    // side: CBaseMonster::TraceAttack (combat.cpp:1113) calls SpawnBlood +
    // TraceBleed on ANY target whose pev->takedamage is set, live or dead, and
    // only then hands off to DeadTakeDamage.  A body on the floor bleeds when
    // you hit it in Half-Life for exactly that reason.
    //
    // Nothing in this tree reproduced that half.  The crowbar's own body branch
    // plays cbar_hitbod and stops — W_ImpactEffect is in its ELSE — and the
    // hitscan paths pick IMPACT_MAT_FLESH off W_ClassifyImpactMaterial, which
    // never runs for a corpse because the corpse return above short-circuits
    // W_ApplyDamage first.  So hitting a body was audible and completely
    // invisible.
    //
    // env_blood's wire is reused rather than a new event added: it already
    // carries origin, direction, amount, colour and a decal flag, and its client
    // half already resolves the flesh recipes.  SF_BLOOD_DECAL is what leaves the
    // pool on the floor afterwards.
    //
    // Sprayed from the body's CENTRE rather than from trace_endpos.  The trace
    // globals do still hold the melee hit here, but W_ApplyDamage is reached from
    // radius blasts and script damage too, where they hold something unrelated or
    // nothing at all — and a blood puff that appears across the room is worse
    // than one a few units off.
    if (target.bloodcolor != 0 || (target.flags & FL_MONSTER))
    {
        vector bpos = target.origin + (target.mins + target.maxs) * 0.5;
        vector bdir = '0 0 -1';
        if (attacker && attacker != target)
        {
            bdir = bpos - (attacker.origin + attacker.view_ofs);
            bdir_z = 0;
            if (bdir == '0 0 0')
                bdir = '1 0 0';
            bdir = normalize(bdir);
            // Biased downward so the decal lands on the floor the body is lying
            // on rather than on whatever wall happens to be behind it.
            bdir_z = -1;
            bdir = normalize(bdir);
        }
        // BloodColor(): HL's BLOOD_COLOR_YELLOW is 195 and BLOOD_COLOR_RED 247.
        // Every AI class sets .bloodcolor, so this is the class's own answer.
        float bcol = (target.bloodcolor == 195) ? BLOODCOL_YELLOW : BLOODCOL_RED;
        EnvBlood_Multicast(bpos, bdir,
                           max(CORPSE_BLOOD_MIN, damage * CORPSE_BLOOD_SCALE),
                           bcol, SF_BLOOD_DECAL);
    }

    // Bullets bleed a corpse and nothing more — DMG_BULLET is deliberately
    // absent from DMG_GIB_CORPSE.  Everything heavier chips away at the pool
    // BecomeDead left behind, and the hit that lands over what remains tears
    // the body apart.
    if (bits & DMG_GIB_CORPSE)
    {
        if (target.health <= damage)
        {
            target.health = -50;	// drives the gib launch speed, combat.cpp:235
            ai_dbg_corpse_gib = ai_dbg_corpse_gib + 1;
            Monster_Gib(target, attacker);
            return damage;
        }
        // The 0.1 is HL's, and it is what makes a corpse take several crowbar
        // swings rather than bursting on the first one.
        target.health = target.health - damage * 0.1;
        ai_dbg_corpse_chip = ai_dbg_corpse_chip + 1;
    }

    return damage;
};

float(entity attacker, entity target, float damage) W_ApplyDamage =
{
    entity saved;
    entity old_activator;

    // Read-and-clear, before ANY early return, so a damage type set by one
    // caller can never leak into the next hit.  0 means bullet.
    float dmgbits = sv_dmg_bits;
    sv_dmg_bits = 0;
    if (!dmgbits)
        dmgbits = DMG_BULLET;
    // Same read-and-clear discipline for the HUD's reason byte, and for exactly
    // the same reason — leave it set and the next bullet wound would flash green
    // because the last thing to run was a nerve-gas trigger.
    float dmghud = sv_dmg_hudtype;
    sv_dmg_hudtype = 0;
    if (sv_in_radius_explosion)
        dmgbits = dmgbits | DMG_BLAST;

    // A corpse is a legal target and takes its own damage rules.  This has to
    // come BEFORE W_CanDamageTarget, which rejects anything dead outright — and
    // it cannot test health, because BecomeDead deliberately leaves a corpse
    // with POSITIVE health (its gib pool).  deadflag is the only honest test.
    if (target.deadflag == DEAD_DEAD && (target.flags & FL_MONSTER)
        && target.takedamage == DAMAGE_YES)
        return W_DeadTakeDamage(attacker, target, damage, dmgbits);

    if (!W_CanDamageTarget(target))
        return 0;

    // Per-monster tally of damage that actually reached a PLAYER.  This is the
    // one number that answers the whole class of "monster X doesn't hit me"
    // report — shots fired, animations played and schedules selected can all look
    // healthy while the damage goes nowhere, which is exactly what the houndeye's
    // blast and the male assassin's burst were both doing.
    if ((attacker.flags & FL_MONSTER) && target.classname == "player")
        attacker.ai_dbg_dmgdealt = attacker.ai_dbg_dmgdealt + damage;

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

    // The tactical shield gets first refusal, BEFORE kevlar — a round stopped by
    // a slab of polycarbonate never reaches the vest, so spending armour on it
    // would be charging the player twice for one bullet.  Returns the surviving
    // fraction (0 stops it outright), and is a no-op for anyone not carrying
    // one.  Explosions deliberately go through: sv_in_radius_explosion damage
    // arrives from a point, but it arrives as pressure from every direction, and
    // a shield you can hide a whole grenade behind is not the CS shield.
    if (target.classname == "player" && target.has_shield
        && !sv_in_radius_explosion && attacker && attacker != target)
    {
        damage = damage * SH_ShieldDamageFraction(target, attacker.origin);
        if (damage <= 0)
        {
            // Tell the shooter their round went nowhere — otherwise a blocked
            // burst is indistinguishable from a miss, which is the single most
            // confusing thing a shield can do to the person shooting at it.
            sound(target, CHAN_BODY, "weapons/ric2.wav", 1, ATTN_NORM);
            return 0;
        }
    }

    // Kevlar absorbs part of the incoming damage before it reaches health
    // (a helmet halves a headshot first — the 4x head multiplier is already
    // baked into `damage`).  No-op when the player has no armor and no
    // helmet.  Players only; world/breakables are unaffected.
    // Prop Hunt: a DISGUISED hider gets no armor absorb — a 1-HP tincan must
    // die to one hit regardless of any kevlar bought pre-shuffle.
    if (target.classname == "player" && !target.ph_disguise_modelindex)
        damage = Armor_Absorb(target, damage, target.death_hitgroup == HITGROUP_HEAD);

    // The class's own last word on this hit, BEFORE it lands.  Monsters only:
    // this is the AI layer's veto (.ai_damagefilter), and the null case costs one
    // field test.  It has to sit above the clamp below rather than below it,
    // because a filter that survives a killing blow works by returning LESS than
    // the target's health — clamping first would already have decided the kill.
    if (target.flags & FL_MONSTER)
        damage = AI_DamageFilter(target, damage, dmgbits);

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
        // DMGHUD_* — why the player is losing health.  Every writer of this
        // event must send it and _net_event_bytes must count it; see the note on
        // the matching write in sv_player.qc.
        WriteByte(MSG_ONE, dmghud);
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
        //
        // SHORT, not byte.  The VICTIM above is always a living player, but the
        // ATTACKER is not: a zombie or headcrab damaging a player reaches here
        // today, and monster edict numbers pass 255 routinely.  Truncated, the
        // number can land on a real player's slot - and this field's only job is
        // "skip the flinch on that client", so the failure is an innocent player
        // silently losing their flinch reaction whenever a monster hits someone.
        WriteShort(MSG_MULTICAST, num_for_edict(attacker));
        multicast(target.origin, MULTICAST_PVS);

        // Camo body paint: getting shot scrubs a slice of coverage off
        // (sv_paint.qc; no-op when unpainted).  Same gating as the flinch —
        // real external damage on a living player.
        SV_Paint_OnDamage(target);
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
        // Prop Hunt: a killed disguised hider DECLOAKS instead of gibbing —
        // the prop poofs into smoke and PlayerKilled (below) reveals + ragdolls
        // the real player model.  Fire the smoke burst at the disguise hull's
        // CENTRE (the z the old flesh-gib burst used).  NO attacker needed
        // (trigger/void deaths decloak too), and NO corpse-modelindex zeroing —
        // the corpse becomes the ragdoll's owner, not an exploded nothing.
        float ph_prop_gib = (target.ph_disguise_modelindex != 0);
        if (ph_prop_gib)
        {
            float poof_z = target.origin_z + target.ph_hull_minz
                         + target.ph_hull_height * 0.5;
            WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
            WriteByte(MSG_MULTICAST, CSQC_EVENT_PROP_DECLOAK);
            WriteCoord(MSG_MULTICAST, target.origin_x);
            WriteCoord(MSG_MULTICAST, target.origin_y);
            WriteCoord(MSG_MULTICAST, poof_z);
            WriteByte(MSG_MULTICAST, bound(4, target.ph_hull_height, 72));  // hull size → poof scale
            multicast(target.origin, MULTICAST_PVS);
        }
        // Headshot kill on a REAL player → flesh chunks + blood ("the head
        // explodes").  Hitgroup-based, not damage-based.  Disguised hiders never
        // reach here — their hits normalize to GENERIC and they decloak above.
        else if (target.death_hitgroup == HITGROUP_HEAD && attacker)
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
            float gib_z = target.origin_z + 24;               // center of mass

            WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
            WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_GIBS);
            WriteCoord(MSG_MULTICAST, target.origin_x);
            WriteCoord(MSG_MULTICAST, target.origin_y);
            WriteCoord(MSG_MULTICAST, gib_z);
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

            // Latched for the medkit's revive (sh_wpn_svmedkit.qc).  Sven's rule
            // is "you can only revive players and NPCs that haven't been gibed",
            // and there is no other way to ask afterwards: the corpse's zeroed
            // modelindex above is also what a decloaked prop-hunt hider and an
            // ordinary model-less state look like.  Cleared in PlayerSpawn.
            target.death_was_gib = TRUE;
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
    //
    // `!target.on_killed` matters: this branch RETURNS, so anything carrying
    // both a .use and an .on_killed never reached the on_killed dispatch 20
    // lines below.  Every shootable door is in that set — func_door has had
    // .use = door_use and .on_killed = door_killed since it was written, so
    // shooting one ran door_use and skipped door_killed's health re-arm
    // entirely, leaving health at 0 so every following bullet re-fired the
    // open.  func_breakable is the same shape and lands on
    // func_breakable_break either way, so it is unaffected.
    //
    // The precedence is the right way round on its own terms too: .on_killed
    // is the specific death handler, .use is the generic activation one.
    if (target.health <= 0 && target.use && !target.on_killed)
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
        // How far past zero this blow drove them, captured BEFORE the death
        // dispatch.  It has to be: on_killed reaches AI_Died, which replaces
        // health with the corpse's own positive gib pool (max_health/2), so
        // reading it afterwards would always say "not overkilled".
        float overkill = target.health;
        float was_monster = (target.flags & FL_MONSTER);

        saved = self;
        self  = target;
        self.on_killed();
        self  = saved;

        // combat.cpp:596-601 — the killing blow decides whether there is a body
        // at all.  Restore the overkill figure for the test, because Monster_Gib
        // scales the launch speed off it.
        if (was_monster && target.deadflag == DEAD_DEAD)
        {
            float saved_health = target.health;
            target.health = overkill;
            if (Gib_ShouldGibOnDeath(target, dmgbits, damage))
            {
                ai_dbg_corpse_gib = ai_dbg_corpse_gib + 1;
                Monster_Gib(target, attacker);
                return damage;
            }
            target.health = saved_health;
        }
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
// is literally "" (unregistered, or blanked by a stale cfg/server.cfg
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
    // (no po_fx_soundset any more — PhysObj_Setup resolves po_sndset from po_is_weapon_drop
    //  to the "weapon" set in materialsounds.txt: weapon_impact_* + soda_can_scrape.)

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
    drop_ent.po_material = -1;   // weapon drops keep their own tuned bounce/damp (no prop-material)
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
    // The sleeping branch of W_PhysDropThink never calls PhysObj_DetectContactFX, so
    // this is the last tick on which anything would cut the loop.  In practice the
    // thresholds already exclude it (sleep needs speed <= 8 for 0.2 s, sliding needs
    // >= 35) but that is an accident of two independently-tunable cvars, not a
    // guarantee — set sv_physprop_sleep_speed above sv_physprop_slide_min_speed and a
    // drop could fall asleep mid-scrape.  Free when not scraping.
    PhysFiles_StopScrape(drop_ent);

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

    // This repoints .think at weapon_become_solid, so PhysObj_DetectContactFX — the
    // ONLY thing that ever cuts the loop on the free-slide path — never runs on this
    // entity again.  A latch still set here would survive until the watchdog swept it.
    PhysFiles_StopScrape(self);

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
            // A removed edict has its fields cleared, so nothing downstream — not the
            // watchdog, not a later think — can ever cancel a loop still latched here.
            // Every remove() on a prop must stop first.  Free when not scraping.
            PhysFiles_StopScrape(self);
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
        PhysFiles_StopScrape(self);
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
        PhysFiles_StopScrape(self);
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
    // THE ONE GENUINELY LIVE LEAK for weapon drops.  The other despawn paths
    // (escaped-world, stuck-in-BSP, sleep, fallback-to-toss) all need seconds of
    // awake ticks first, and PhysObj_DetectContactFX cuts the loop 0.2 s after a
    // slide stops — so a scrape cannot survive them.  This one is reached from
    // W_PhysDropBeginRemove the instant a player PICKS UP a gun that is still
    // sliding, with the loop still playing.
    PhysFiles_StopScrape(self);
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

// ---------------------------------------------------------------------------
// sv_proj_test  —  spawn a MONSTER-owned projectile in front of player 1
// ---------------------------------------------------------------------------
// "the grunts grenade was invisible" is a report about a projectile whose owner
// is not a client, and in single player that is the ONLY way this send path is
// ever exercised: projectile_SendEntity hides the object from its owner, so a
// player's own grenade/rocket/bolt is always the CSQC-predicted fake and the
// replicated one is never seen by the only person watching.
//
// Reproducing it through a real grunt means winning a firefight at over 256
// units with the 4-second grenade cooldown up - possible, but not a test.  This
// spawns the identical entity (W_HLGrenadeSpawn, owner = world, so the hide
// branch cannot fire) on demand, so the client half can be read off a log.
//
// Set to PROJ_TYPE_* PLUS ONE (so 1 is the HL grenade, type 0) - the off value
// has to be 0, and a negative sentinel on a command line gets eaten as a switch.
// Self-clears after one spawn.
//
// Both of these live in files that compile AFTER this one (the grenade in
// shared/weapons/, SUB_Remove in the subs), so they come in by prototype.
entity(entity thrower, vector org, vector vel, float fuse_end) W_HLGrenadeSpawn;
void() SUB_Remove;

float projtest_next;	// next throw; see the note in W_ProjTest
float projtest_gripe;	// rate limit on the "nobody to throw it in front of" line

void() W_ProjTest =
{
    float ty = cvar("sv_proj_test");
    if (ty < 1)
        return;
    ty = ty - 1;

    // A LIVE player if there is one, otherwise any player at all.  The fallback is
    // what makes this usable from the headless harness: that client connects and
    // its entity joins the chain, but it never presses fire, so it stays dead and
    // non-solid forever and the strict test waited 79 seconds and threw nothing.
    // A spectator's origin is its camera, which is exactly where a visibility test
    // wants the object anyway.
    entity p = player_chain_head;
    while (p && (p.health <= 0 || p.solid == SOLID_NOT))
        p = p.player_chain_next;
    if (!p)
        p = player_chain_head;
    if (!p)
    {
        // SAY SO, once a second.  A silent early-out here is indistinguishable
        // from "spawned and the client never drew it", which is precisely the
        // question this test exists to answer - a headless run produced an empty
        // log and the obvious reading was that the grenade had gone out and
        // vanished, when in fact nothing had ever been thrown.
        if (time >= projtest_gripe)
        {
            projtest_gripe = time + 1;
            dprint(sprintf("[projtest] waiting: no live player (chain head %s)\n",
                           (player_chain_head) ? player_chain_head.classname : "<none>"));
        }
        return;
    }

    // NOT self-clearing any more, and the reason is the harness: the headless
    // client takes the better part of a minute to mount every VPK, download the
    // packed csprogs and start CSQC, while the server has a live player long
    // before that.  A one-shot therefore always fired into a world with nobody
    // able to see it, and its 30-second fuse had expired by the time the client
    // was ready.  Re-throwing on a timer means the test cannot lose that race.
    // `sv_proj_test 0` stops it.
    if (time < projtest_next)
        return;
    projtest_next = time + 6;

    makevectors(p.angles);
    vector org = p.origin + p.view_ofs + v_forward * 64;

    entity g;
    if (ty == PROJ_TYPE_HLGRENADE)
    {
        // owner = world, exactly like a monster as far as SendEntity cares
        g = W_HLGrenadeSpawn(world, org, v_forward * 200 + '0 0 100', time + 30);
    }
    else
    {
        g = spawn();
        g.owner      = world;
        g.classname  = "proj_test";
        g.movetype   = MOVETYPE_TOSS;
        g.solid      = SOLID_NOT;
        setmodel(g, Projectile_TypeModel(ty));
        setsize(g, '-2 -2 -2', '2 2 2');
        setorigin(g, org);
        g.velocity   = v_forward * 200 + '0 0 100';
        g.avelocity  = '180 360 120';
        g.gravity    = Projectile_TypeGravity(ty);
        g.proj_type  = ty;
        g.SendEntity = projectile_SendEntity;
        g.SendFlags  = 1;
        g.think      = SUB_Remove;
        g.nextthink  = time + 30;
    }

    dprint(sprintf("[projtest] type=%g owner=world model=\"%s\" modelindex=%g org=%v\n",
                   ty, g.model, g.modelindex, g.origin));
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
//  Pickup respawn  -  Sven Co-op's mp_weaponstay and the three delay cvars
// ============================================================
//
// THE CVAR EVERYONE ASKS FOR BY NAME IS mp_respawnweapons AND IT DOES NOT
// EXIST.  See the block in shared/sh_cvar_table.qc for the evidence; the real
// one is mp_weaponstay.
//
// HALF-LIFE DOES NOT IMPLEMENT "WEAPONS STAY" BY NEVER REMOVING THE ENTITY.
// CHalfLifeMultiplay::FlWeaponRespawnTime (multiplay_gamerules.cpp:858) returns
// `gpGlobals->time + 0` when weaponstay is on - an INSTANT respawn - and
// CanHavePlayerItem (:922) refuses a player who already carries that weapon.
// Copying that shape means "stays" and "respawns after N seconds" are one code
// path with a different number in it, rather than two mechanisms that disagree
// at the edges.
//
// What this mod already had: a map weapon is HIDDEN rather than removed
// (see the tail of weapon_touch), keeping map_weapon_origin / _angles /
// _spawn intact so W_RespawnMapWeapons can revive it.  Everything below is the
// missing half - a caller other than RoundRestart.

// Sven's Pickup base class spawnflags (sven-coop.fgd:291-298).  None of these
// were read before.
const float PICKUP_SF_TOUCH_ONLY = 128;
const float PICKUP_SF_USE_ONLY   = 256;
const float PICKUP_SF_USE_NO_LOS = 512;
const float PICKUP_SF_NO_RESPAWN = 1024;

// ITEM IS ZERO ON PURPOSE.  .pickup_kind is set at spawn only by the classes
// that are not items, so an entity nobody thought about defaults to the item
// rules - which is the safe direction, and means GoldSrc_PickupTaken (reached
// by eight different spawn functions) can read the field without every one of
// them having to set it.
const float PICKUP_KIND_ITEM   = 0;
const float PICKUP_KIND_AMMO   = 1;
const float PICKUP_KIND_WEAPON = 2;

// Per-entity override, sven-coop.fgd:348-351 (CustomRespawnDelay base class,
// carried by Weapon, Ammo, Item, item_inventory and weaponbox).
//
// DECLARED LOWERCASE ON PURPOSE.  The FGD spells it m_flCustomRespawnTime and
// ED_FindField is a plain strcmp, so a CamelCase declaration binds only for the
// compilers that emit CamelCase.  ED_ParseUnknownEpair case-folds a miss onto a
// lowercase field (sv_multi_manager.qc:412), so declaring it lowercase is what
// makes ONE field serve both spellings - the same reasoning sv_scripted.qc
// records for the m_isz* keys.  The FGD types it `string`; the engine converts
// by FIELD type, not by FGD type, so .float is correct and saves a stof.
.float m_flcustomrespawntime;

// Absolute time this pickup comes back.  0 = nothing scheduled.
.float pickup_respawn_at;
// Which delay cvar governs it - set at spawn, because by the time it is taken
// the classname may have been rewritten (weapon_crowbar -> weapon_hlcrowbar).
.float pickup_kind;
// What to put back for a NON-weapon pickup.  A map weapon is revived by
// re-running map_weapon_spawn, which rebuilds everything; ammo and items have no
// such stored function (GoldSrc_SpawnPickup is called with a model and a touch
// and nothing records which spawn function called it), and adding one would mean
// threading a third argument through every one of its callers.  Saving the two
// values that actually change is smaller and does not touch those call sites.
.string pickup_model;
.void() pickup_touch;

// Counter-Strike armoury_entity stock — CArmoury::m_iCount.  One armoury_entity
// with count 5 is FIVE guns stacked on one spot, not five entities: the CS wiki
// puts it as "it will look like there is only one in game, but there will be the
// number you have used and the weapon model won't disappear until they are all
// used up".  Set by server/sv_cs_entities.qc and read in Pickup_Taken below;
// zero on every other pickup in the game, which is why the check there is a
// single compare rather than a branch on classname.
.float armoury_left;

// How long until this pickup returns, or -1 for "never".
//
// Precedence is Sven's, and the spawnflag is FIRST: a mapper who ticked
// "Disable Respawn" on one crate means that crate, whatever the server is set
// to.  A cvar has no business overruling a key written into the BSP - the same
// call made for `onlytrigger` in sv_doors_rotating.qc.
float(entity e, float kind) Pickup_RespawnDelay =
{
    if (e.spawnflags & PICKUP_SF_NO_RESPAWN)
        return -1;

    // Weaponstay: instant, exactly as HL does it.  Checked before the custom
    // time because weaponstay is a statement about the whole server's rules,
    // and a map that also set a custom delay was describing the non-stay case.
    if (kind == PICKUP_KIND_WEAPON && cvar("mp_weaponstay") > 0)
        return 0;

    if (e.m_flcustomrespawntime > 0)
        return e.m_flcustomrespawntime;

    float d;
    if (kind == PICKUP_KIND_AMMO)      d = cvar("mp_ammo_respawndelay");
    else if (kind == PICKUP_KIND_ITEM) d = cvar("mp_item_respawndelay");
    else                               d = cvar("mp_weapon_respawndelay");

    // Sven's encoding, IN FULL (manual/mapping-config.html, and the shipped
    // default_map_settings.cfg):
    //   -2  use the GAME DEFAULT delay - it respawns
    //   -1  never respawn, unless the entity carries m_flCustomRespawnTime
    //       (that override was already taken above)
    //    0  instant
    //   >0  after this many seconds
    //
    // -2 USED TO BE FOLDED INTO "never" RIGHT HERE, so the campaign corpus
    // would not start respawning the moment this code landed.  That protection
    // now lives on the DEFAULT instead - sh_cvar_table.qc registers all three
    // delays at -1 - which keeps a server that never touches them on the
    // single-player "a pickup you take is gone" behaviour, and leaves -2 free
    // to mean what Sven says it means.  With the fold in place there was no
    // value AT ALL that asked for the game's own schedule: -1 meant never, -2
    // meant never, and a server.cfg copied from a Sven server (where these sit
    // at -2 and pickups do come back) read as "never".  That is the reported
    // crowbar/healthkit bug.
    if (d <= -2)
    {
        // Half-Life's own constants, multiplay_gamerules.cpp:45-47 -
        // ITEM_RESPAWN_TIME 30, WEAPON_RESPAWN_TIME 20, AMMO_RESPAWN_TIME 20.
        // FlWeaponRespawnTime's weaponstay shortcut is not repeated here
        // because it was already taken at the top of this function.
        if (kind == PICKUP_KIND_ITEM)
            return 30;
        return 20;                  // weapon and ammo
    }

    if (d < 0)
        return -1;                  // -1: never
    return d;                       // 0 = instant, >0 = seconds
};

// The revive.  Deliberately the same two lines W_RespawnMapWeapons uses
// (sv_weapons.qc, the map_weapon arm): re-running the stored spawn function
// re-wires model, SendEntity, touch and think from scratch, so it does not
// matter whether the entity was hidden or merely stale.
void() Pickup_RespawnThink =
{
    self.pickup_respawn_at = 0;

    if (self.map_weapon && self.map_weapon_spawn)
    {
        setorigin(self, self.map_weapon_origin);
        self.angles = self.map_weapon_angles;
        self.map_weapon_spawn();

        if (self.movetype != MOVETYPE_PHYSICS)
        {
            self.velocity = '0 0 -100';
            if (!droptofloor())
                self.velocity = '0 0 -200';
        }
        self.SendFlags |= 1;
        return;
    }

    // Non-weapon pickup: put back exactly what Pickup_Taken took away.  Size,
    // solidity and movetype are GoldSrc_SpawnPickup's own constants
    // (sv_goldsrc_pickups.qc) - repeated rather than shared because that
    // function is reached through eight different spawn functions and none of
    // them records which one it was.
    if (self.pickup_model == "" || !self.pickup_touch)
    {
        // Nothing to restore.  Only reachable if the model or touch was cleared
        // while a respawn was pending; a crate drop clears its spawn bookkeeping
        // for exactly this reason (sv_goldsrc_ammo.qc), so drop the entity
        // rather than leave an invisible solid standing in the world.
        remove(self);
        return;
    }

    setorigin(self, self.map_weapon_origin);
    setmodel(self, self.pickup_model);
    setsize(self, '-16 -16 0', '16 16 16');
    self.solid     = SOLID_TRIGGER;
    self.movetype  = MOVETYPE_TOSS;
    self.touch     = self.pickup_touch;
    self.SendFlags |= 1;
};

// Called from every pickup's taken-path.  Returns TRUE when the entity has been
// dealt with (hidden, scheduled, or deliberately left standing) and the caller
// must NOT remove it; FALSE means "no respawn is owed, remove it as before".
float(entity e, float kind) Pickup_Taken =
{
    float delay = Pickup_RespawnDelay(e, kind);

    // CS armoury stock, taken BEFORE the delay is acted on so it overrides every
    // rule above: a mapper who stacked five rifles on one armoury_entity means
    // five rifles regardless of what mp_weapon_respawndelay says, and the stack
    // must not start obeying the server's respawn schedule until it is empty.
    //
    // Folding it into `delay = 0` rather than returning early is deliberate - it
    // reuses the two instant-respawn paths that already exist just below, so the
    // stack behaves EXACTLY like mp_weaponstay for a gun (left standing, solid,
    // still .touch-wired, with weapon_touch's slot-occupancy guard refusing the
    // same player a second copy) and like an instant item respawn for kevlar
    // (hidden, back on the next think).  That second distinction is load-bearing:
    // an item left standing would re-grant on every touch frame, which is the
    // infinite-ammo trap the comment below this one already records.
    if (e.armoury_left > 0)
    {
        e.armoury_left = e.armoury_left - 1;
        delay = 0;
    }

    // Never coming back.  Map weapons still get hidden rather than removed,
    // because RoundRestart revives them and always did.
    if (delay < 0)
        return FALSE;

    // Instant, and A WEAPON: this is mp_weaponstay's whole point.  Leave it
    // exactly as it is - solid, visible, and STILL .touch-wired.
    //
    // .touch matters beyond the obvious: sv_use.qc identifies a weapon pickup by
    // `e.touch == weapon_touch`, so nulling it (as the hide path does) would
    // also shut off the +use route and the gun would become un-takeable by the
    // one input most likely to be aimed at it.
    //
    // DELIBERATELY WEAPONS ONLY.  A weapon left standing is safe because the
    // slot-occupancy checks at the top of weapon_touch refuse the second take;
    // an ammo crate has no such guard, so leaving one solid would hand out its
    // contents on every touch frame - infinite ammo, not an instant respawn.
    // Ammo and items with a 0 delay hide and come back on the next think
    // instead, which is the same behaviour one frame later and cannot run away.
    if (delay == 0 && kind == PICKUP_KIND_WEAPON)
        return TRUE;

    // Delayed: hide, and come back later.  Same hidden state the round-reset
    // path uses, so the two cannot drift.
    //
    // Remember where it was and what it looked like BEFORE clearing any of it -
    // map_weapon_origin is already the weapon path's own record, and reusing it
    // means one revive knows where to put either kind back.
    if (!e.map_weapon)
    {
        e.map_weapon_origin = e.origin;
        e.map_weapon_angles = e.angles;
        if (e.model != "")
            e.pickup_model = e.model;
        if (e.touch)
            e.pickup_touch = e.touch;
    }

    // THE SAME HIDE TRAP AS mp_nomapweapons, and this one was missed when that
    // was fixed.  A map weapon that an explosion has sent sliding is a live ODE
    // body with a scrape latched on it; hiding it here clears .touch and repoints
    // .think at the respawn timer, so the contact detector that owns the scrape
    // never runs on this entity again and nothing is left to cancel it.  Both the
    // sound and the physics body have to be torn down BEFORE the entity is parked.
    // Mirrors sv_weapons.qc:536-541 exactly.
    PhysFiles_StopScrape(e);
    if (e.movetype == MOVETYPE_PHYSICS || e.weapon_physdrop_sleeping)
        physics_enable(e, FALSE);
    e.weapon_physdrop_sleeping   = FALSE;
    e.weapon_physdrop_rest_start = 0;

    e.solid     = SOLID_NOT;
    e.movetype  = MOVETYPE_NONE;
    setmodel(e, "");
    e.touch     = __NULL__;
    e.SendFlags |= 1;               // see the ghost-pickup note in weapon_touch

    e.pickup_respawn_at = time + delay;
    e.think     = Pickup_RespawnThink;
    e.nextthink = e.pickup_respawn_at;
    return TRUE;
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

    // Prop Hunt: hiders stay weaponless (mp_ph_hider_noweapons).  THE choke point for
    // both pickup routes — walking over a gun lands here via .touch, and the +use route
    // (SV_TryWeaponPickup / SV_TryWeaponSwap, sv_use.qc) invokes this same function.
    if (PropHunt_HiderNoWeapons(player))
        return;

    // Sven's Pickup routing flags (sven-coop.fgd:291-298), neither of which was
    // read before.  Both routes land in this one function - walking over a gun
    // arrives via .touch, and +use arrives via SV_TryWeaponPickup calling
    // .touch() directly - and sv_use_is_player_direct is TRUE across that whole
    // call (sv_use.qc:281), so it is what tells the two apart.
    //
    // Returning rather than consuming: a "USE Only" weapon someone walks over
    // must stay takeable by the input that IS allowed, and a "TOUCH Only" one
    // must let the press fall through to whatever is behind it.
    if ((pickup.spawnflags & PICKUP_SF_USE_ONLY) && !sv_use_is_player_direct)
        return;
    if ((pickup.spawnflags & PICKUP_SF_TOUCH_ONLY) && sv_use_is_player_direct)
        return;

    slot = pickup.weapon_slot;

    // Tactical shield, rule 2: it is one hand, so the other hand may hold a
    // pistol, the knife or a grenade and nothing else.  Refuse rather than drop
    // the shield automatically — losing equipment you paid for by brushing past
    // a rifle is exactly the accident +use exists to avoid, and Counter-Strike
    // refuses here too.
    if (SH_ShieldBlocksPickup(player, pickup.weapon))
    {
        centerprint(player, "Drop the shield first\n");
        return;
    }

    // Reject if player already has a weapon in this slot — utility is a
    // small inventory, so only duplicate utility pickups are blocked.
    // SLOT_MELEE has a special case for WEP_MELEE (fists): fists are
    // INTRINSIC so the slot is effectively "empty" for pickup purposes
    // — walking over a katana / knife / crowbar while only carrying
    // fists overwrites the slot with the real weapon.  Without this
    // exception the player would be stuck with fists forever since
    // the drop key can't drop them.
    // PRIMARY / SECONDARY are now bounded by mp_maxprimary / mp_maxsecondary
    // rather than by "is the slot occupied".  At a limit of 1 this is exactly the
    // old test.  At the limit, walking over a gun still REFUSES it — +use remains
    // the deliberate swap route (SV_TryWeaponSwap), so you cannot lose a weapon by
    // brushing past another one.
    if (slot == SLOT_PRIMARY || slot == SLOT_SECONDARY)
    {
        if (W_CarryIndexOf(player, slot, pickup.weapon) >= 0)          return;
        if (W_CarryCount(player, slot) >= W_CarryLimit(slot))          return;
    }
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
        W_CarryAdd(player, SLOT_PRIMARY, pickup.weapon);
        player.slot_primary       = pickup.weapon;
        player.slot_primary_equip = pickup.weap_draw;
        player.slot_primary_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_SECONDARY)
    {
        W_CarryAdd(player, SLOT_SECONDARY, pickup.weapon);
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

    // The reserve pays out HERE, and only here.  Ammo pickups for a gun the
    // player does not carry bank their rounds by calibre (sv_goldsrc_ammo.qc);
    // finding the gun is what releases them.
    //
    // ORDER IS LOAD-BEARING, and it moved: this used to sit above the slot
    // registration, next to the pickupcopy.  Ammo_GiveToCarried now refuses to
    // fill a weapon the player does not carry — which is the whole point of a
    // reserve — and "carries" is decided by the slot fields assigned just above.
    // Draining before them meant the player provably did not own the gun yet, so
    // the drain silently did nothing.  It must also stay BEFORE the auto-equip
    // below, so the equip's W_SlotAmmo_LoadLegacy reads the topped-up value.
    Ammo_DrainForWeapon(player, pickup.weapon);

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
        // ...or not hidden at all, under mp_weaponstay / a 0 delay.  Pickup_Taken
        // owns that decision and returns TRUE once it has acted.
        if (Pickup_Taken(pickup, PICKUP_KIND_WEAPON))
        {
            // AMMO RE-FARMING IS THE REAL EXPLOIT HERE, not double pickup.
            // Walking over a stayed weapon twice is already refused by the
            // slot-occupancy checks at the top of this function - but pick up,
            // DROP (mp_dropweapons), and touch it again and the slot is free,
            // so W_SlotAmmo_CopyDropToPlayer and Ammo_DrainForWeapon above run
            // a second time and pay out the world entity's stored ammo again.
            // Repeat for unlimited ammo.
            //
            // Half-Life closes this by disabling dropping entirely under
            // weaponstay (player.cpp:4679).  NOT PORTED: this mod has a whole
            // physics-drop system and silently disabling it would be a worse
            // surprise than the exploit.  Draining the entity instead means the
            // first taker gets weapon + ammo and everyone after gets the
            // weapon - which is the honest reading of "the weapon stays".
            // RoundRestart re-runs the spawn function and restores it.
            if (pickup.solid != SOLID_NOT)
            {
                // CLEAR THE DROP FIELDS, NOT THE SLOT FIELDS, and the first
                // version of this line got it wrong in a way nothing visible
                // would ever have shown.  W_SlotAmmo_ClearForWeapon routes
                // through W_SlotAmmo_SetForWeapon, which writes
                // .slot_primary_*/.slot_secondary_* (sh_weapon_slotammo.qc:19)
                // - PLAYER fields.  What the next taker actually reads off this
                // world entity is .weapon_drop_mag/_ammo/_aux, in
                // W_SlotAmmo_CopyDropToPlayer (:309).  So the old call zeroed
                // three fields nobody consults and left the payout untouched,
                // and it was worse than nothing: the guard READ as present.
                // It also silently covered no melee or utility weapon at all,
                // because SetForWeapon only has branches for PRIMARY and
                // SECONDARY - which is most of the grenade-shaped things a
                // player would want to farm.  Caught by sv_pickup_test.
                pickup.weapon_drop_mag  = 0;
                pickup.weapon_drop_ammo = 0;
                pickup.weapon_drop_aux  = 0;
                W_SlotAmmo_ClearForWeapon(pickup, pickup.weapon);

                // THE CLIENT HAS ALREADY HIDDEN THIS WEAPON.
                // CSQC_PredictPickupWeapon sets drawmask = 0 the moment the
                // player overlaps it (cl_weapons.qc), and nothing on the entity
                // changed here, so without a forced resend the client would sit
                // on a hidden-but-still-solid weapon until PICKUP_PREDICT_TIMEOUT
                // expired and restored it - a visible flicker on every take.
                //
                // Bumping SendFlags sends the entity again WITH its real model,
                // which lands in CSQC_DroppedWeapon_Update's existing rollback
                // branch and restores drawmask on the spot.  No new client code
                // and no cvar replication: the machinery written for "the server
                // denied your prediction" is exactly the machinery for "the
                // weapon stayed", because from the client's side those are the
                // same event.  (The sv_debug_pickups line will say "server
                // denied prediction" for a take that succeeded - harmless, and
                // noted here so it does not read as a bug in a log.)
                pickup.SendFlags |= 1;
            }
        }
        else
        {
            // Same tear-down as Pickup_Taken above, and for the same reason: this
            // hides a possibly-sliding ODE body and clears its touch, so anything
            // still latched on it would have nothing left to cancel it.
            PhysFiles_StopScrape(pickup);
            if (pickup.movetype == MOVETYPE_PHYSICS || pickup.weapon_physdrop_sleeping)
                physics_enable(pickup, FALSE);
            pickup.weapon_physdrop_sleeping   = FALSE;
            pickup.weapon_physdrop_rest_start = 0;

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
    // The emplaced stance, same default-off rule as the ADS profile above: only
    // the five deployable DoD weapons re-assert it in their own Equip.  Leaving
    // it set would carry a mortar's movement lock onto the next weapon.
    self.weapon_deployable   = 0;
    self.wep_deployed        = 0;
    // The held crouch is narrower still — the mortar alone re-asserts it.
    self.weapon_deploy_crouched = 0;
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
    else if (self.slot_utility == WEP_SATCHEL)
    {
        self.slot_utility_equip = W_SatchelEquip;
        self.slot_utility_drop = W_SatchelDrop;
    }
    else if (self.slot_utility == WEP_TRIPMINE)
    {
        self.slot_utility_equip = W_TripmineEquip;
        self.slot_utility_drop = W_TripmineDrop;
    }
    else if (self.slot_utility == WEP_SNARK)
    {
        self.slot_utility_equip = W_SnarkEquip;
        self.slot_utility_drop = W_SnarkDrop;
    }
    else if (self.slot_utility == WEP_PENGUIN)
    {
        self.slot_utility_equip = W_PenguinEquip;
        self.slot_utility_drop = W_PenguinDrop;
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
    else if (self.slot_utility == WEP_MEDKIT)
    {
        self.slot_utility_equip = W_MedkitEquip;
        self.slot_utility_drop = W_MedkitDrop;
    }
    else if (self.slot_utility == WEP_ASSOFLAM)
    {
        self.slot_utility_equip = W_SoflamEquip;
        self.slot_utility_drop = W_SoflamDrop;
    }
    // THE THREE DoD UTILITIES WERE MISSING FROM THIS TABLE, and because the
    // function opens by NULLing both pointers, it did not merely fail to bind
    // them — it wiped the binding W_RefreshUtilitySlot (sv_player.qc:3910-3923)
    // had already set correctly.  That is the reported "the binoculars despawn
    // as soon as you spawn one and try to swap to it": selecting them left the
    // server holding weaponmodel "", fire __NULL__ and wepframe __NULL__.
    //
    // The binoculars have no drop by design (sh_wpn_dodbinocs.qc:16) — they are
    // a spotting tool with no world pickup — so their drop pointer stays null
    // and the dispatcher's own null test handles it.
    else if (self.slot_utility == WEP_DODMILLS)
    {
        self.slot_utility_equip = W_DodMillsEquip;
        self.slot_utility_drop = W_DodMillsDrop;
    }
    else if (self.slot_utility == WEP_DODSTICK)
    {
        self.slot_utility_equip = W_DodStickEquip;
        self.slot_utility_drop = W_DodStickDrop;
    }
    else if (self.slot_utility == WEP_DODBINOCS)
    {
        self.slot_utility_equip = W_DodBinocsEquip;
        self.slot_utility_drop = __NULL__;
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
    else if (self.weapon == WEP_SATCHEL)
        W_SatchelEquip();
    else if (self.weapon == WEP_TRIPMINE)
        W_TripmineEquip();
    else if (self.weapon == WEP_SNARK)
        W_SnarkEquip();
    else if (self.weapon == WEP_PENGUIN)
        W_PenguinEquip();
    else if (self.weapon == WEP_HORNETGUN)
        W_HGunEquip();
    else if (self.weapon == WEP_SHOCKRIFLE)
        W_ShockEquip();
    else if (self.weapon == WEP_DISPLACER)
        W_DispEquip();
    else if (self.weapon == WEP_JETPACK)
        W_JetEquip();
    else if (self.weapon == WEP_BGRAPPLE)
        W_BGrapEquip();
    else if (self.weapon == WEP_SNOWBALL)
        W_SnowballEquip();
    else if (self.weapon == WEP_CSHEGRENADE)
        W_CSHEGrenadeEquip();
    else if (self.weapon == WEP_CSFLASHBANG)
        W_CSFlashbangEquip();
    else if (self.weapon == WEP_CSSMOKEGRENADE)
        W_CSSmokeGrenadeEquip();
    else if (self.weapon == WEP_MEDKIT)
        W_MedkitEquip();
    else if (self.weapon == WEP_ASSOFLAM)
        W_SoflamEquip();
    // THE THREE DoD UTILITIES HAD NO ARM HERE, and W_ClearWeaponBindings() ran
    // unconditionally above — so selecting one left the SERVER holding
    // weaponmodel "", fire __NULL__ and wepframe __NULL__.  All three are
    // server-autonomous (sh_weapons.qc:907, :914), which means W_WeaponFrame's
    // `if (self.fire) self.fire();` is their ONLY entry point, and it was null.
    // The binoculars' own header predicted this failure in advance
    // (sh_wpn_dodbinocs.qc:37): "the server would never call self.fire() —
    // +attack would do nothing, silently".  That is the reported despawn.
    //
    // NOT dispatched through self.slot_utility_equip, tempting as it looks:
    // W_UtilityRefreshSlotBinding re-derives slot_utility from
    // W_UtilityNextCarried(WEP_NONE), which is the first CARRIED utility in ring
    // order and not necessarily self.weapon — so the pointer can name a
    // different weapon than the one being equipped.  Keyed on self.weapon like
    // every other arm.
    else if (self.weapon == WEP_DODMILLS)
        W_DodMillsEquip();
    else if (self.weapon == WEP_DODSTICK)
        W_DodStickEquip();
    else if (self.weapon == WEP_DODBINOCS)
        W_DodBinocsEquip();
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

    // OWNERSHIP, not "is it the cursor".  W_CarryHas covers melee and both carry
    // lists; under multi-carry the cursor is only one of what may be several
    // primaries, so the old four-way cursor comparison would refuse to select a
    // weapon the player demonstrably owns.
    if (!W_CarryHas(self, new_weapon) &&
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

    // ONE call does the whole cursor move now: persist the outgoing weapon into
    // its OWN legacy store, move the cursor, hydrate the incoming weapon from
    // ITS store.  See the data-model block at the top of sh_weapon_slotammo.qc.
    //
    // What used to be here was `W_SlotAmmo_SaveLegacy(self, cur)` — a HYDRATE of
    // the outgoing weapon, which leaves the shared registers describing the gun
    // you just put away, right before W_RebindSlot snapshotted them and stamped
    // them onto the gun you just drew.  That is how the F5 bench handed out
    // empty weapons and how cycling two primaries swapped their magazines.
    //
    // The previous comment here argued at length that it must be the OUTGOING
    // weapon and cited sv_ammo_selftest stage 2 going want=60 got=10.  The
    // observation was real; the conclusion was wrong.  Stage 2 was failing
    // because Ammo_TopUpWeapon wrote the SLOT cache for a holstered gun, so the
    // only way to see those rounds again was to read the cache back — a second
    // bug propping up the first.  Ammo_TopUp* now writes the weapon's own store
    // (sv_goldsrc_ammo.qc), so stage 2 passes by construction and this can be
    // what it should always have been.
    float ns = WeaponManifest_Slot(new_weapon);
    if (ns == SLOT_PRIMARY || ns == SLOT_SECONDARY)
    {
        W_SlotAmmo_PointAt(self, ns, new_weapon);
        W_RebindSlot(ns);
    }

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
        && (W_CarryHas(self, self.previous_weapon)
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

    // The tactical shield goes FIRST, and takes the press on its own.  It has no
    // slot for the dispatcher below to find, and the drop key is the only way to
    // be rid of it — which is exactly what a player who wants a rifle has to do,
    // since weapon_touch refuses one while it is carried.  Dropping the pistol
    // out from under the shield instead would leave them stuck with no way out.
    if (self.has_shield)
    {
        CS_Shield_DropFrom(self);
        return;
    }

    cur = self.weapon;
    if (cur == WEP_NONE)
        return;

    drop_func = __NULL__;
    if (cur == self.slot_primary   && self.slot_primary_drop)   drop_func = self.slot_primary_drop;
    if (cur == self.slot_secondary && self.slot_secondary_drop) drop_func = self.slot_secondary_drop;
    if (cur == self.slot_melee     && self.slot_melee_drop)     drop_func = self.slot_melee_drop;
    if (cur == WEP_HLGRENADE && self.ammo_hlgrenade > 0)        drop_func = W_HLGrenadeDrop;
    if (cur == WEP_SATCHEL   && self.ammo_satchel > 0)          drop_func = W_SatchelDrop;
    if (cur == WEP_TRIPMINE  && self.ammo_tripmine > 0)         drop_func = W_TripmineDrop;
    if (cur == WEP_SNARK     && self.ammo_snark > 0)            drop_func = W_SnarkDrop;
    if (cur == WEP_SNOWBALL  && self.ammo_snowball > 0)         drop_func = W_SnowballDrop;
    if (cur == WEP_CSHEGRENADE && self.ammo_cshegrenade > 0)    drop_func = W_CSHEGrenadeDrop;
    if (cur == WEP_CSFLASHBANG && self.ammo_csflashbang > 0)    drop_func = W_CSFlashbangDrop;
    if (cur == WEP_CSSMOKEGRENADE && self.ammo_cssmokegrenade > 0) drop_func = W_CSSmokeGrenadeDrop;
    if (cur == WEP_CFC4 && self.ammo_cfc4 > 0)                  drop_func = W_CFC4Drop;
    // The medkit is a SLOT_UTILITY tool and its drop binding lives in
    // slot_utility_drop (W_UtilityRefreshSlotBinding, :3742) — a field this
    // dispatcher has never read, so impulse 8 fell through to the early-out below
    // and did nothing at all.  The client had already predicted the drop, and the
    // correcting snapshot re-deploying the medkit is what replayed the draw
    // animation the reporter saw on every press.
    //
    // Ammo is deliberately NOT the gate the way it is for the ordnance above:
    // ownership of the medkit is "the utility slot holds it"
    // (W_UtilityPlayerHasWeapon, shared/weapons/sh_wpn_snowball.qc:257-258), and an
    // empty medkit is still a medkit you may put down.
    //
    // GENERALISED, because the medkit was never the only one.  That fix was made
    // for the medkit alone and left every other slot-bound utility falling
    // through — the DoD grenades, the SOFLAM and the penguin all had a perfectly
    // good W_*Drop that this dispatcher could not reach, so impulse 8 on any of
    // them did nothing while the CLIENT had already predicted the drop.  That
    // mismatch is the reported "some of the DoD utility cannot be dropped,
    // causing a draw animation to occur when nothing is happening": CSQC drops
    // it, stamps WS_DRAW on the next weapon, and the correcting snapshot then
    // stamps WS_DRAW again on the weapon that never left. Two draws, no drop.
    //
    // W_UtilityPlayerHasWeapon is the right gate because it already encodes BOTH
    // ownership conventions — ammo > 0 for the counted ordnance, slot ownership
    // for the tools — so this cannot hand out an empty grenade.  The binoculars
    // resolve to a null drop pointer and are refused below, which is intended
    // (sh_wpn_dodbinocs.qc:16: no world pickup exists for them).
    if (!drop_func && self.slot_utility_drop
        && cur == self.slot_utility && W_UtilityPlayerHasWeapon(cur))
        drop_func = self.slot_utility_drop;

    if (!drop_func)
    {
        // AND SAY SO.  The refusal used to be completely silent — no sprint, no
        // sound, no dprint — so a player pressing drop on something undroppable
        // got a phantom draw animation and no explanation for it.
        sprint(self, PRINT_HIGH, "you can't drop that\n");
        return;
    }

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

    // Clear the vacated slot.  Under multi-carry the cursor does not simply go
    // to WEP_NONE — it falls back to whatever else is still held in that slot,
    // and only empties when the list does.
    // THE ClearForWeapon THAT USED TO CLOSE EACH ARM IS GONE, and it was a bug:
    // it clears the SLOT's registers, and by the time it ran the cursor had
    // already fallen back to the surviving weapon — so dropping primary #1 while
    // carrying #2 zeroed #2's magazine and reserve on the HUD.  W_SlotAmmo_PointAt
    // owns those registers now and leaves them describing whoever survived (or
    // zeroes them when the list empties, which is the case that call was for).
    if (cur == self.slot_primary)
    {
        W_CarryRemove(self, SLOT_PRIMARY, cur);
        W_SlotAmmo_PointAt(self, SLOT_PRIMARY, W_CarryAt(self, SLOT_PRIMARY, 0));
        if (self.slot_primary == WEP_NONE)
        {
            self.slot_primary_equip = __NULL__;
            self.slot_primary_drop  = __NULL__;
        }
        else
            W_RebindSlot(SLOT_PRIMARY);
    }
    else if (cur == self.slot_secondary)
    {
        W_CarryRemove(self, SLOT_SECONDARY, cur);
        W_SlotAmmo_PointAt(self, SLOT_SECONDARY, W_CarryAt(self, SLOT_SECONDARY, 0));
        if (self.slot_secondary == WEP_NONE)
        {
            self.slot_secondary_equip = __NULL__;
            self.slot_secondary_drop  = __NULL__;
        }
        else
            W_RebindSlot(SLOT_SECONDARY);
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
        // ORDER IS LOAD-BEARING for the medkit.  Its OWNERSHIP is "the utility slot
        // holds it", not an ammo pool (W_UtilityPlayerHasWeapon,
        // shared/weapons/sh_wpn_snowball.qc:257-258), and W_UtilityNextCarried walks
        // the ring inclusive of from_wep on its final step (:308-312).  Asking it
        // what is left while the cursor still names the medkit therefore wraps all
        // the way round and hands the medkit straight back — the player would throw
        // one on the floor and W_SelectStrongest below would immediately re-deploy
        // the one still in the slot.  Vacate first, then ask.  The ordnance above
        // needs no such step: their drop functions zero the ammo pool that IS their
        // ownership test.
        if (cur == WEP_MEDKIT)
            self.slot_utility = WEP_NONE;
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

    // The tactical shield rides the same gate: it is equipment rather than a
    // weapon so it has no slot to appear in the loop below, but a player who
    // dies holding one should leave it on the floor like everything else.
    CS_Shield_DropFrom(self);
    float slot_max = (drop_mode == 1) ? 2 : 12;

    for (slot_idx = 0; slot_idx < slot_max; slot_idx++)
    {
        drop_func = __NULL__;
        slot_wep = 0;
        // MULTI-CARRY: slots 0 and 1 drain their whole carry list rather than
        // dropping only the cursor.  Without this, dying with two primaries
        // dropped one and DELETED the other - indistinguishable in play from the
        // drop physics having eaten it.
        //
        // The `slot_idx--` keeps the loop on this slot for another pass; it is
        // safe because each pass removes one entry, and once the list is empty
        // slot_wep stays 0 and the loop advances normally.  Rebinding is what
        // makes drop_func point at the weapon actually being dropped.
        if (slot_idx == 0)
        {
            slot_wep = W_CarryAt(self, SLOT_PRIMARY, 0);
            if (slot_wep != WEP_NONE)
            {
                // PointAt, not a bare cursor write: each corpse-drop must carry
                // ITS OWN magazine.  A raw assignment left the slot registers
                // describing whichever gun was in hand, so dying with two
                // primaries produced two pickups with identical ammo.
                W_SlotAmmo_PointAt(self, SLOT_PRIMARY, slot_wep);
                W_RebindSlot(SLOT_PRIMARY);
                drop_func = self.slot_primary_drop;
                W_CarryRemove(self, SLOT_PRIMARY, slot_wep);
                slot_idx--;
            }
        }
        else if (slot_idx == 1)
        {
            slot_wep = W_CarryAt(self, SLOT_SECONDARY, 0);
            if (slot_wep != WEP_NONE)
            {
                W_SlotAmmo_PointAt(self, SLOT_SECONDARY, slot_wep);
                W_RebindSlot(SLOT_SECONDARY);
                drop_func = self.slot_secondary_drop;
                W_CarryRemove(self, SLOT_SECONDARY, slot_wep);
                slot_idx--;
            }
        }
        else if (slot_idx == 2) { slot_wep = self.slot_melee;     drop_func = self.slot_melee_drop; }
        else if (slot_idx == 3)
        {
            slot_wep = self.slot_utility;
            if (slot_wep == WEP_HLGRENADE && self.ammo_hlgrenade > 0) drop_func = W_HLGrenadeDrop;
            else if (slot_wep == WEP_SNOWBALL && self.ammo_snowball > 0) drop_func = W_SnowballDrop;
            else if (slot_wep == WEP_CSHEGRENADE && self.ammo_cshegrenade > 0) drop_func = W_CSHEGrenadeDrop;
            else if (slot_wep == WEP_CSFLASHBANG && self.ammo_csflashbang > 0) drop_func = W_CSFlashbangDrop;
            else if (slot_wep == WEP_CSSMOKEGRENADE && self.ammo_cssmokegrenade > 0) drop_func = W_CSSmokeGrenadeDrop;
            else if (slot_wep == WEP_SATCHEL && self.ammo_satchel > 0) drop_func = W_SatchelDrop;
            else if (slot_wep == WEP_TRIPMINE && self.ammo_tripmine > 0) drop_func = W_TripmineDrop;
            else if (slot_wep == WEP_SNARK && self.ammo_snark > 0) drop_func = W_SnarkDrop;
            // A FOURTH COPY OF THE SAME ALLOWLIST, and this one DESTROYED the
            // item rather than merely refusing to drop it: dying while carrying
            // a medkit, a penguin, a SOFLAM or either DoD grenade left no pickup
            // at all, because the corpse-drop found no drop_func and moved on.
            // W_UtilityRefreshSlotBinding now binds every one of them, and
            // W_UtilityPlayerHasWeapon carries both ownership conventions, so the
            // fallback covers the whole set instead of naming five more ids.
            // (The binoculars stay destroyed — they have no world pickup, so
            // slot_utility_drop is null for them and this leaves drop_func null.)
            else if (self.slot_utility_drop && W_UtilityPlayerHasWeapon(slot_wep))
                drop_func = self.slot_utility_drop;
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
        // The HL equipment carried in the OTHER utility pockets, same shape as
        // slots 4-8 above: one slot each so a death drops every pouch, not
        // just whichever one happened to be selected.
        else if (slot_idx == 9)
        {
            if (self.slot_utility != WEP_SATCHEL && self.ammo_satchel > 0)
            { slot_wep = WEP_SATCHEL; drop_func = W_SatchelDrop; }
        }
        else if (slot_idx == 10)
        {
            if (self.slot_utility != WEP_TRIPMINE && self.ammo_tripmine > 0)
            { slot_wep = WEP_TRIPMINE; drop_func = W_TripmineDrop; }
        }
        else if (slot_idx == 11)
        {
            if (self.slot_utility != WEP_SNARK && self.ammo_snark > 0)
            { slot_wep = WEP_SNARK; drop_func = W_SnarkDrop; }
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
    // Pressing a slot key while already holding something from that slot CYCLES
    // to the next weapon in it — the same shape case 4 (utility) has always had.
    // W_SelectWeapon no-ops on WEP_NONE, so the old `if (self.slot_*)` guards are
    // folded into W_SlotPressTarget.
    case WEAPON_IMPULSE_PRIMARY:   // Select / cycle primary slot
        W_SelectWeapon(W_SlotPressTarget(self, SLOT_PRIMARY));
        break;
    case WEAPON_IMPULSE_SECONDARY:   // Select / cycle secondary slot
        W_SelectWeapon(W_SlotPressTarget(self, SLOT_SECONDARY));
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
        // Prop Hunt: a disguised hider has no weapon, so the reload key is
        // repurposed as the ROTATION LOCK toggle (freeze the shown prop's yaw
        // so looking around doesn't spin your disguise).  Self-gates; consumes
        // the impulse only when it acted.
        if (PropHunt_ToggleYawLock(self))
            break;
        if (self.reload) self.reload();
        break;
    case WEAPON_IMPULSE_SPECIAL:  // Weapon-specific action (menu "Weapon Special")
        // Tactical shield: refused outright while one is carried.  Not a balance
        // call — none of the nine combined view models has a pose for it, and
        // the USP's silencer toggle asked for sequences 7 and 15 against their
        // 9-entry table, so it played `shield_up` and then nothing.  Mirrored in
        // CSQC_PredictWeaponImpulse; both must agree or the client animates a
        // toggle the server never performed.
        if (self.has_shield)
            break;
        // Prop Hunt: a disguised hider has no weapon, so Weapon Special is repurposed as
        // DECLOAK (drop the disguise with a smoke poof).  Self-gates; consumes only when it
        // acted, so a seeker's real Weapon Special is untouched.
        if (PropHunt_TryDecloak(self))
            break;
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
    //
    // The per-weapon half of this test used to be a hand-written id list right
    // here, and it drifted twice: ten weapons that never emit `cmd cs` were
    // missing from it, so their +attack reached the server through NEITHER route
    // and did nothing at all — no damage to monsters or breakables, no gunfire
    // for the AI to hear, no third-person shoot pose.  It now lives beside the
    // weapon ids it names (shared/sh_weapons.qc), where the full rationale is,
    // and check_serverfire.py derives the correct membership from the
    // weapon sources so a new bespoke try-fire can't go missing silently again.
    float wep_bypasses_cs_notify = (self.is_bot
                                 || W_FireIsServerAutonomous(self.weapon));
    // Prop Hunt: a weaponless hider never fires, whatever they are somehow holding
    // (mid-round team switch, admin give).  Backstop — the pickup block in weapon_touch
    // is what actually keeps a gun out of their hands.
    float ph_nofire = PropHunt_HiderNoWeapons(self);
    // Rule 3, applied centrally.  SH_ShieldBlocksFire is consulted inside
    // SH_StandardTryFire, which the knife and the three grenades — four of the
    // eleven shield-legal weapons — do not go through: they have bespoke
    // try-fires, so a raised shield never stopped a slash or a throw.  Gating
    // the dispatch instead of the try-fire covers every route at once, and
    // matches the mask CSQC_PredictWeaponCommand puts on input_buttons.
    float shield_nofire = (self.has_shield && self.shield_deployed);
    if ((cvar("sv_trust_clienthits") < 1 || wep_bypasses_cs_notify)
        && self.button0 && time >= self.attack_finished
        && !ph_nofire && !shield_nofire)
    {
        if (self.fire)
            self.fire();
    }

    // Backstop for rule 2.  weapon_touch and the buy menu both refuse a
    // two-handed weapon while the shield is carried, but `give`, a map script
    // and an admin command all reach past them — and a player holding an AK47
    // behind a shield would render as PANIM_SHIELDGUN with a rifle in it.  One
    // field test per frame buys immunity to every route that has not been
    // thought of yet.
    if (self.has_shield && !SH_ShieldAllowsWeapon(self.weapon))
        CS_Shield_DropFrom(self);

    // Tactical shield: +attack2 raises and lowers it.  Taken BEFORE the weapon's
    // own alt-fire, because in Counter-Strike the shield owns that button
    // outright — a silenced USP does not toggle its silencer while you are
    // carrying one, it raises the shield.  SH_ShieldToggle answers FALSE when
    // there is no shield, so nothing changes for anyone not carrying it.
    // RISING EDGE, not "while held": the shield is a toggle, and a held button
    // against SH_ShieldToggle's 0.4 s debounce would flap it up and down twice a
    // second for as long as the player leant on the key.
    float shield_took_alt = self.has_shield;   // consumed for as long as carried
    if (self.has_shield && self.button1 && !self.shield_alt_held)
        SH_ShieldToggle(time);
    self.shield_alt_held = self.button1;

    // sv_debug_shield — the server half of the shield trace.  Prints on any EDGE
    // of the four inputs that decide the shield's behaviour, so a run produces a
    // handful of lines rather than 64 a second.  Its client counterpart is
    // cl_debug_shield (client/cl_weapons.qc) and the two are meant to be read
    // side by side: every symptom this feature has produced so far has been the
    // two sides disagreeing about has_shield / shield_deployed, and there was no
    // way to see that from either log alone.
    if (cvar("sv_debug_shield"))
    {
        float sdbg = (self.has_shield ? 1 : 0) | (self.shield_deployed ? 2 : 0)
                   | (self.button0 ? 4 : 0)     | (self.button1 ? 8 : 0);
        if (sdbg != self.shield_dbg_last)
        {
            self.shield_dbg_last = sdbg;
            // Split in two: fteqcc warns past 8 varargs, and the tree builds clean.
            print(sprintf("[shield-sv] t=%.2f has=%g dep=%g b0=%g b1=%g wep=%g wstate=%g\n",
                          time, self.has_shield, self.shield_deployed,
                          self.button0, self.button1, self.weapon, self.weaponstate));
            print(sprintf("[shield-sv]   nofire=%g tookalt=%g nexttog=%.2f atkfin=%.2f\n",
                          shield_nofire, shield_took_alt,
                          self.shield_next_toggle, self.attack_finished));
        }
    }

    // Check alt-fire button
    if (self.button1 && !shield_took_alt && time >= self.attack_finished && !ph_nofire)
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

        // The 0.3 is now only a MINIMUM hold — the pose itself is held for as
        // long as the weapon stays in the state (see SH_PlayerAnim_Update), and
        // wep_state_dur tells PlayTop how long the action actually runs so a
        // body animation longer than it can be compressed to fit instead of
        // being cut off part-way through.  Weapons on bespoke gates leave
        // wep_state_dur at 0, which PlayTop reads as "unknown" and plays at 1x
        // exactly as before.
        if (self.weaponstate == WS_FIRE)
            SH_PlayerAnim_PlayTop(mdlidx, SH_GetShootAnim(mdlidx, family, crouching),
                                  0.3, 0);
        else if (self.weaponstate == WS_RELOAD)
            SH_PlayerAnim_PlayTop(mdlidx, SH_GetReloadAnim(mdlidx, family, crouching),
                                  0.3, self.wep_state_dur);

        self.prev_weaponstate_anim = self.wep_action_id;
    }

    W_SlotAmmo_SaveCurrent(self);
    Ammo_TickDrain(self);	// banked rounds into a gun that has made room since pickup
};
