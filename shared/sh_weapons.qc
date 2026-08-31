// ============================================================
//  shared/sh_weapons.qc  -  Cross-weapon system constants & fields
//  Included by both sv_progs and cl_progs.
//
//  Per-weapon constants and ammo fields live in each weapon's
//  own file: shared/weapons/sh_wpn_*.qc
// ============================================================

// Forward decl — implemented in sh_pmove.qc.  SSQC's progs.src
// includes every weapon file before sh_pmove (because sh_pmove uses
// per-weapon ammo fields), so the fire-block helper has to be
// declared here, in a header included earlier than any weapon file.
// Body uses pm_movetype + PM_MOVETYPE_NOCLIP which live in sh_pmove
// — those don't escape the function body so a plain forward decl is
// enough.
float() Weapon_SprintBlocksFire;
// Lower-pose fire gate — same compile-order story.  Body references
// grapple_rope_active (shared field, declared in sh_customdefs.qc
// which compiles before this header) and pm_on_ladder_cached
// (declared right next to pm_ladder_detach_time in sh_customdefs.qc).
float() Weapon_LowerBlocksFire;
// Same compile-order story for the ADS gate — sh_weapon_logic.qc
// compiles before sh_pmove.qc on SSQC, so the helper's body
// references (pm_movetype, PM_MOVETYPE_NOCLIP, PM_BTN_SPRINT,
// PM_ReadMovevar) need to be visible to the SSQC compiler.  The
// helper itself is forward-declared so SH_GetSpreadScale (defined
// further down sh_weapon_logic.qc) can call it.
.float pm_movetype;
float  PM_MOVETYPE_NOCLIP = 5;
float  PM_BTN_SPRINT      = 8;
float(string name, float fallback) PM_ReadMovevar;
float() Weapon_IsADSActive;
// Grapple shared field is declared in sh_pmove.qc which compiles
// AFTER sh_weapon_logic.qc on SSQC (sv_progs.src), so the forward-
// decl here lets Weapon_IsADSActive's grapple-cancel branch see the
// field.  The .vector grapple_anchor that sits next to it isn't
// needed here — only the rope-active gate.
.float grapple_rope_active;

// --- Weapon IDs ---
const float WEP_NONE   = 0;
const float WEP_DEAGLE = 1;
const float WEP_KNIFE  = 2;
const float WEP_AK47         = 3;
const float WEP_M4A1         = 4;
const float WEP_FLAKSHOTGUN  = 5;
const float WEP_PISTOL       = 6;
const float WEP_GAUSS            = 7;
const float WEP_CROSSBOW         = 8;
const float WEP_357              = 9;
const float WEP_DOD98K           = 10;
const float WEP_SCOUT            = 11;
const float WEP_GRENADELAUNCHER  = 12;
const float WEP_M249             = 13;
const float WEP_HLCROWBAR        = 14;
const float WEP_HLSHOTGUN        = 15;
const float WEP_CSM3             = 16;
const float WEP_CSMP5            = 17;
const float WEP_REBAR            = 18;
const float WEP_CSAWP            = 19;
const float WEP_WRENCH           = 20;
const float WEP_GLOCK            = 21;
const float WEP_G3SG1            = 22;
const float WEP_HLSMG            = 23;
const float WEP_HLRPG            = 24;
const float WEP_HLGRENADE        = 25;
const float WEP_HLGLOCK          = 26;
const float WEP_HLEGON           = 27;
const float WEP_CSUSP            = 28;   // CS 1.6 USP-45 (semi-auto .45 pistol, secondary, silencer toggle)
// HD AK47 — sequence-driven GoldSrc viewmodel variant of WEP_AK47.
// Shares the same ammo pool (mag_ak47 / ammo_ak47) and balance numbers,
// only differs in v/w/p models + animation system.
const float WEP_HDAK47           = 29;
const float WEP_SNOWBALL         = 30;
const float WEP_SLINGSHOT        = 31;  // pickup-only snowball upgrade
const float WEP_PAINTBALL        = 32;
const float WEP_CSHEGRENADE      = 33;
const float WEP_CSFLASHBANG      = 34;
const float WEP_CSSMOKEGRENADE   = 35;
const float WEP_BUTTERFLY        = 36;
const float WEP_CFAUG            = 37;
const float WEP_CFFAMAS          = 38;
const float WEP_CFMAC10          = 39;
const float WEP_CFC4             = 40;
// Fists-only "weapon" — sequence-driven viewmodel only (no p_/w_model);
// random punch picks on +attack, random kick picks on +altattack,
// block_low on special.  Can't be dropped (no world model).
const float WEP_MELEE            = 41;
// Katana sword — sequence-driven, full p_/w_/v_ model set, droppable.
// Random slash on +attack (slash1/2/3), no-op block on +altattack.
const float WEP_KATANA           = 42;
// CF-series new weapons (Beretta M9, Colt Anaconda, Barrett, PSG1, Dual
// Desert Deagle).  Each gets its own ammo pool — no sharing across
// look-alike pairs (e.g. WEP_CFREVOLVER is independent from WEP_DEAGLE).
const float WEP_CFM9      = 43;   // Beretta M9 (pistol, secondary)
const float WEP_CFREVOLVER         = 44;   // Colt Anaconda (revolver, secondary)
const float WEP_CFBARRETT            = 45;   // Barrett M82 (bolt-action sniper, primary, CoD-scope)
const float WEP_CFPSG1          = 46;   // PSG1 (semi-auto sniper, primary, CoD-scope, no scope-out on fire)
const float WEP_CFDDEAGLE          = 47;   // Dual Desert Deagle (dual-wield pistol, secondary)
const float WEP_CFSPAS12         = 48;   // SPAS-12 (pump shotgun, primary)
const float WEP_CFM700      = 49;   // Remington M700 (bolt-action sniper, primary, CoD-scope)
const float WEP_CFM3             = 50;   // Winchester (pump shotgun, primary)
const float WEP_CFSCAR          = 51;   // FN SCAR (full-auto rifle, primary)
const float WEP_CFMAUSER          = 52;   // C96 Mauser (semi-auto pistol, secondary)
const float WEP_CFSVD          = 53;   // SVD Dragunov (semi-auto sniper, primary, CoD-scope, no scope-out on fire)
// CrossFire SMG/rifle additions — sequence-driven GoldSrc viewmodels,
// full-auto, penetrating hitscan.  Each has its own ammo pool.
const float WEP_CFMP5            = 54;   // CF MP5 (full-auto 9mm SMG, primary)
const float WEP_CFVECTOR         = 55;   // CF Vector (full-auto .45 SMG, primary)
const float WEP_CFTYPE89         = 56;   // CF Type 89 (full-auto 5.56 rifle, primary)
const float WEP_CFUMP45          = 57;   // CF UMP45 (full-auto .45 SMG, primary)
const float WEP_CFM249           = 58;   // CF M249 (full-auto 5.56 LMG, primary)
const float WEP_CFAWM            = 59;   // CF AWM (bolt-action sniper, primary, CoD-scope)
const float WEP_CFKS23           = 60;   // CF KS-23 (pump shotgun, primary, 3-shell big-bore)
const float WEP_CFM4             = 61;   // CF M4 Super 90 (auto shotgun, primary, shell-by-shell)
const float WEP_CFMK23           = 62;   // CF MK23 SOCOM (semi-auto .45 pistol, secondary, silencer toggle)
const float WEP_CFGALIL          = 63;   // CF Galil (full-auto rifle, primary)
const float WEP_CFGLOCK          = 64;   // CF Glock 18 (full-auto pistol, secondary)
const float WEP_CFELITE          = 65;   // CF Scout Elite (semi-auto scout sniper, primary, CoD-scope)
const float WEP_CFP228           = 66;   // CF P228 (semi-auto pistol, secondary)
const float WEP_CFMSG90          = 67;   // CF MSG90 (semi-auto sniper, primary, CoD-scope)
const float WEP_CFSG552          = 68;   // CF SG552 (full-auto scoped assault rifle, primary, CoD-scope like CFAUG)
const float WEP_CFSL8            = 69;   // CF SL8 (semi-auto marksman rifle, primary)
// Half-Life 2 gravity gun — sequence-driven GoldSrc viewmodel, primary slot,
// infinite energy (no ammo/reload).  +attack grabs/throws one ODE phys prop at
// range (reuses the +use carry system); +attack2 held spins up a black-hole pull
// of all phys props in a radius, release blasts them outward.
const float WEP_GRAVITYGUN       = 70;   // Gravity Gun (primary, physics manipulator)

// The four Half-Life equipment weapons, ported from the SDK (satchel.cpp,
// tripmine.cpp, squeakgrenade.cpp, hornetgun.cpp).  All four use GoldSrc
// sequence-indexed viewmodels straight off the valve mount - no converted
// IDPO copies exist or are needed.
const float WEP_SATCHEL          = 71;   // Satchel charge (utility, throw + radio detonate)
const float WEP_TRIPMINE         = 72;   // Tripmine (utility, wall-mounted laser mine)
const float WEP_SNARK            = 73;   // Snark (utility, live hunting grenade)
const float WEP_HORNETGUN        = 74;   // Hornet gun / hivehand (primary, self-regenerating ammo)

// Opposing Force and Sven, implemented rather than aliased because no weapon in
// this mod does what any of them do.  There is NO OpFor SDK on this machine, so
// unlike the four above these are not ports - see each file's header for which
// numbers had a source and which are this mod's own.
const float WEP_SHOCKRIFLE       = 75;   // Shock rifle (primary, self-regenerating ammo)
const float WEP_DISPLACER        = 76;   // Displacer (primary, energy orb + teleport)
const float WEP_JETPACK          = 77;   // Glock 18 jetpack (secondary, thrust on +attack2)
const float WEP_BGRAPPLE         = 78;   // Barnacle grapple (primary, no ammo)

// They Hunger's eight.  Every one of them already existed as a PICKUP ALIAS in
// server/sv_goldsrc_pickups.qc — a They Hunger world model bolted onto the
// nearest Half-Life weapon, so picking up a Thompson handed you an MP5 with an
// M203.  All eight ship complete v_/w_/p_ sets under
// svencoop/models/hunger/weapons/, and the campaign's own behaviour is on disk
// as AngelScript (svencoop/scripts/maps/hunger/weapons/*.as), so unlike the
// OpFor four above these ARE ports and each file cites the script line by line.
// The aliases now spawn these instead.
const float WEP_TH1911           = 79;   // Colt M1911A1 (secondary, 7-round magazine)
const float WEP_THTOMMY          = 80;   // Thompson M1921 (primary, 50-round drum)
const float WEP_THGREASE         = 81;   // M3 grease gun (primary, slow cyclic rate)
const float WEP_THM14            = 82;   // M14 (primary, semi-auto, 2-stage scope)
const float WEP_THM16            = 83;   // M16A1 (primary, full-auto + 3-round burst)
const float WEP_THSAWOFF         = 84;   // Sawed-off TOZ-34 (primary, 2 shells, both barrels on alt)
const float WEP_THSPANNER        = 85;   // Spanner (melee)
const float WEP_THTESLA          = 86;   // Tesla gun (primary, short arc + hold-to-charge)

// --- Sven Co-op and Opposing Force, promoted out of the pickup-alias block in
// server/sv_goldsrc_pickups.qc.  Every one of these was a classname that handed
// you a DIFFERENT gun: weapon_uzi gave you a CrossFire MAC-10, weapon_sniperrifle
// a CS AWP, weapon_medkit a floor healthkit.  The models and (bar the minigun's)
// the sounds were on the Sven mount the whole time.
const float WEP_MEDKIT           = 87;   // Sven medkit (utility, heals another player)
const float WEP_UZI              = 88;   // Sven UZI (secondary, 9mm)
const float WEP_UZIAKIMBO        = 89;   // Sven akimbo UZIs (secondary, 9mm, shares v_uzi)
const float WEP_MINIGUN          = 90;   // Sven minigun (primary, spin-up)
const float WEP_SVM16            = 91;   // Sven M16 (primary, 5.56 — v_m16a2.mdl)
const float WEP_PIPEWRENCH       = 92;   // OpFor pipe wrench (melee, charged big swing)
const float WEP_SNIPERRIFLE      = 93;   // OpFor M40A1 (primary, 7.62, zoom)
const float WEP_SPORELAUNCHER    = 94;   // OpFor spore launcher (primary, spores)
const float WEP_EAGLE            = 95;   // OpFor Desert Eagle (secondary, .357)
const float WEP_ASSHOTGUN        = 96;   // pizza_ya_san shortened shotgun (primary, 4-shell)
const float WEP_ASSOFLAM         = 97;   // pizza_ya_san SOFLAM laser designator (utility)

// --- The last three Opposing Force weapons.  gearbox declares TEN in its own
// sprites/weapon_*.txt (displacer, eagle, grapple, knife, m249, penguin,
// pipewrench, shockrifle, sniperrifle, sporelauncher) and only seven of them had
// ever been built here.  Every model and sound they need was on the gearbox
// mount already.
//
// The first two take GoldSrc classnames that Counter-Strike guns were sitting
// on: `weapon_knife` and `weapon_m249` now spawn THESE, and the CS pair answers
// to weapon_csknife / weapon_csm249.  A GoldSrc map placing either name means
// the Opposing Force weapon.
const float WEP_OPKNIFE          = 98;   // OpFor combat knife (melee, charged stab)
const float WEP_OPSAW            = 99;   // OpFor M249 SAW (primary, 5.56, 200-round belt)
const float WEP_PENGUIN          = 100;  // OpFor penguin (utility, snark reskin)

// --- The thirteen Counter-Strike 1.6 guns that were still missing. ---
//
// The mod already implemented twelve of CS's twenty-five (ak47, m4a1, mp5navy,
// m3, m249, awp, scout, g3sg1, deagle, glock18, usp, knife) plus the three
// grenades.  These are the rest of the arsenal.
//
// EVERY ONE OF THEM SHIPS NO NEW ASSET.  cstrike is mounted (fs_addons.txt:16)
// and carries v_/w_/p_ for all thirteen plus their whole audio set, so each
// weapon file points straight at "models/v_<n>.mdl" the way sh_wpn_csglock.qc
// and sh_wpn_hlcrowbar.qc already point at the cstrike and valve mounts.
//
// They take the REAL CS classnames (weapon_p228, weapon_aug, ...), all thirteen
// of which were unused in this tree, so a GoldSrc CS map placing one gets the
// right gun for free.  The bare manifest keys "aug"/"famas"/"galil"/"p228"/
// "elite"/"mac10"/"ump45"/"sg552"/"xm1014"/"fiveseven"/"sg550" stay bound to the
// CrossFire twins that already own them - these answer to "cs<name>".
const float WEP_CSP228           = 101;  // SIG P228 (secondary, .357 SIG)
const float WEP_CSFIVESEVEN      = 102;  // FN Five-seven (secondary, 5.7x28mm)
const float WEP_CSELITE          = 103;  // dual Berettas (secondary, alternating 9mm)
const float WEP_CSTMP            = 104;  // Steyr TMP (primary, silenced 9mm SMG)
const float WEP_CSMAC10          = 105;  // Ingram MAC-10 (primary, .45 SMG)
const float WEP_CSUMP45          = 106;  // HK UMP45 (primary, .45 SMG)
const float WEP_CSP90            = 107;  // FN P90 (primary, 50-round 5.7mm SMG)
const float WEP_CSGALIL          = 108;  // IMI Galil (primary, 5.56 rifle)
const float WEP_CSFAMAS          = 109;  // FAMAS (primary, 5.56 rifle, burst on alt)
const float WEP_CSAUG            = 110;  // Steyr AUG (primary, 5.56 rifle, scope on alt)
const float WEP_CSSG552          = 111;  // SIG SG-552 (primary, 5.56 rifle, scope on alt)
const float WEP_CSSG550          = 112;  // SIG SG-550 (primary, 5.56 autosniper)
const float WEP_CSXM1014         = 113;  // Benelli XM1014 (primary, semi-auto 12ga)

// --- Day of Defeat, the infantry core of both sides. ---
//
// The mod already had ONE Day of Defeat weapon, the K98 (WEP_DOD98K above),
// and it is the odd one out: it ships copies of its models and sounds under
// models/weapons/wpn_dod98k/ and sounds/weapons/wpn_dod98k/.  These twelve ship
// NOTHING.  steam:Half-Life/dod is mounted (fs_addons.txt) and carries v_/w_/p_
// for every one of them plus their whole audio set, so each file points straight
// at "models/v_<n>.mdl" the way the thirteen Counter-Strike guns above point at
// the cstrike mount.
//
// DoD IS MOUNTED LOW, and unlike Sven Co-op that position is the point: DoD
// reuses ten Half-Life MODEL names (v_/w_/p_grenade, v_/w_/p_satchel,
// player.mdl, playert.mdl, player/, shrapnel.mdl) and 117 sound names.  Mounted
// high it would put a German stick grenade in the HL hand grenade's viewmodel
// slot and replace every player model in the mod.  Every path these twelve ask
// for was checked against all five other mounts and is DoD-exclusive.
//
// They take Day of Defeat's own classnames from dod.fgd (weapon_colt,
// weapon_garand, weapon_mp40, ...), all of which were unused in this tree, so a
// GoldSrc DoD map placing one gets the right gun for free.  The two exceptions
// are named for the collision they would otherwise cause: the M3 grease gun
// answers to weapon_dodgreasegun because They Hunger's own grease gun already
// owns weapon_greasegun, and the Sten and Webley are British weapons DoD never
// gave a map entity to, so they take the obvious spellings.
const float WEP_DODCOLT          = 114;  // Colt M1911A1 (secondary, .45 ACP)
const float WEP_DODLUGER         = 115;  // Luger P08 (secondary, 9mm Parabellum)
const float WEP_DODWEBLEY        = 116;  // Webley Mk VI (secondary, .455 revolver)
const float WEP_DODGARAND        = 117;  // M1 Garand (primary, semi-auto .30-06)
const float WEP_DODCARBINE       = 118;  // M1 Carbine (primary, semi-auto .30 Carbine)
const float WEP_DODK43           = 119;  // Gewehr 43 (primary, semi-auto 7.92 Mauser)
const float WEP_DODTOMMY         = 120;  // Thompson M1A1 (primary, .45 SMG)
const float WEP_DODMP40          = 121;  // MP40 (primary, 9mm SMG)
const float WEP_DODSTEN          = 122;  // Sten Mk II (primary, 9mm SMG)
const float WEP_DODGREASE        = 123;  // M3 Grease Gun (primary, .45 SMG)
const float WEP_DODMP44          = 124;  // StG44 (primary, 7.92 Kurz assault rifle)
const float WEP_DODBAR           = 125;  // M1918 BAR (primary, .30-06 automatic rifle)

// Day of Defeat, second batch — snipers, machine guns, anti-tank and melee.
// Same arrangement as the twelve above: NOTHING is shipped for any of them, all
// models and sounds resolve out of the steam:Half-Life/dod mount that sits
// deliberately at the BOTTOM of fs_addons.txt.
//
// FOUR CLASSNAMES ARE THE MOD'S OWN SPELLING, not dod.fgd's, because DoD hands
// these out from a class menu and never gave them map entities: weapon_spring,
// weapon_enfield_scoped, weapon_fairbairn and weapon_paraknife.  The rest use
// DoD's names.  weapon_pschreck follows DoD's own w_pschreck.mdl abbreviation
// rather than spelling out Panzerschreck, which only the view model does.
const float WEP_DODSCOPED98K     = 126;  // scoped Kar98k    (primary, bolt sniper + bayonet)
const float WEP_DODSPRING        = 127;  // M1903 Springfield(primary, bolt sniper)
const float WEP_DODENFIELDS      = 128;  // scoped Lee-Enfield(primary, bolt sniper, 10 rds)
const float WEP_DOD30CAL         = 129;  // M1919A6 .30 cal  (primary, belt-fed MG)
const float WEP_DODMG34          = 130;  // MG34             (primary, belt-fed MG)
const float WEP_DODMG42          = 131;  // MG42             (primary, belt-fed MG)
const float WEP_DODBAZOOKA       = 132;  // M1A1 bazooka     (primary, anti-tank rocket)
const float WEP_DODSCHRECK       = 133;  // Panzerschreck    (primary, anti-tank rocket)
const float WEP_DODPIAT          = 134;  // PIAT             (primary, anti-tank spigot)
const float WEP_DODAMERK         = 135;  // US M3 trench knife    (melee)
const float WEP_DODFAIRBAIRN     = 136;  // Fairbairn-Sykes       (melee)
const float WEP_DODPARAKNIFE     = 137;  // Fallschirmjager knife (melee)
const float WEP_DODSPADE         = 138;  // Wehrmacht spade       (melee)
// The two DoD hand grenades.  They live in sh_wpn_csgrenades.qc rather than a
// file of their own — they are the CS HE grenade's lifecycle with different
// assets — see that file's header, which also records why the US Mk2 frag is
// NOT here (its v_grenade.mdl is one of the ten names DoD collides with HL on,
// and the dod mount sits below Sven, so that path can never resolve to DoD's).
const float WEP_DODMILLS         = 139;  // Mills bomb        (utility, thrown)
const float WEP_DODSTICK         = 140;  // Stielhandgranate  (utility, thrown)

// Day of Defeat, third batch — the rest of the roster.  Same rule as the two
// batches above: nothing is shipped for any of them, everything resolves out of
// the steam:Half-Life/dod mount.  Classnames are DoD's own here; none of the
// seven collided with the mod's 168 existing weapon_* spawn functions.
//
// The scoped FG42 has NO w_scopedfg42.mdl in the mount and borrows the plain
// FG42's world model — see the header of sh_wpn_dodauto.qc.  The binoculars have
// neither a w_ nor a p_ model, which is why they are a UTILITY item that cannot
// be dropped or map-placed rather than a slot weapon.
const float WEP_DODBREN          = 141;  // Bren Mk II       (primary, .303 LMG)
const float WEP_DODFG42          = 142;  // FG42             (primary, 7.92 automatic rifle)
const float WEP_DODFG42S         = 143;  // scoped FG42      (primary, as above + ZF4)
const float WEP_DODFCARB         = 144;  // M1A1 carbine     (primary, folding-stock .30 carbine)
const float WEP_DODENFIELD       = 145;  // Lee-Enfield No.4 (primary, bolt rifle + bayonet)
const float WEP_DODMORTAR        = 146;  // 3-inch mortar    (primary, indirect fire)
const float WEP_DODBINOCS        = 147;  // binoculars       (utility, spotting scope)

// --- Slot IDs ---
const float SLOT_NONE      = 0;
const float SLOT_PRIMARY   = 1;
const float SLOT_SECONDARY = 2;
const float SLOT_MELEE     = 3;
const float SLOT_UTILITY   = 4;

// Physics weapon drops live outside FTE's default dimension mask (255).
// dimension_solid = PHYSDROP_DIM (only) means player movement (which has
// dimension_hit = dimension_default) doesn't collide with their ODE bodies.
// dimension_hit = dimension_default | PHYSDROP_DIM means the drop CAN
// collide with regular brushwork (world, func_breakable, func_door,
// func_button …) and with other phys drops.  Server weapon traces
// temporarily OR PHYSDROP_DIM into self.dimension_hit when they need
// to shoot the drops themselves.
const float PHYSDROP_DIM = 256;

// Server-side death ragdolls (sv_ragdoll.qc) live on their OWN dimension bit so the
// main bullet/movement traces (dimension_hit = dimension_default) PASS THROUGH corpses
// (CS-style: a corpse is not cover) while a dedicated shove/grab trace ORs RAGDOLL_DIM
// in to hit them.  Kept distinct from PHYSDROP_DIM so ragdoll shoves don't touch drops.
const float RAGDOLL_DIM = 512;

// THE canonical ragdoll doll file — ONE file for every humanoid player model.  A .rag doll binds
// its bodies/joints to the skeleton by BONE NAME ("Bip01 ..."), and all the IQM player models share
// that skeleton, so a single file serves them all (it used to be 11 byte-identical `<model>.iqm.rag`
// siblings — editing one never propagated).  Loaded explicitly via skel_ragupdate("doll <path>") by
// both the server death ragdoll (sv_ragdoll.qc) and the CSQC dev spawner (cl_ragdoll.qc).
// *** NEVER rename this to `<model>.doll` *** — the engine AUTO-loads a doll named exactly
// `<modelpath>.doll` and ragdolls every LIVE player using that model (then crashes).
const string RAGDOLL_DOLL_PATH = "models/player/humanoid.rag";

// Grace window before a player can pick their own toss back up. This is
// separate from fake-drop handoff: CSQC swaps to the real server entity as
// soon as that entity arrives, but pickup prediction stays locked until here.
const float WEAPON_DROP_PICKUP_DELAY = 0.5;

// Pickup zone — a fixed cube anchored at the dropped weapon's origin used
// to test "is the player close enough to pick this up?". Decoupled from
// the entity's setsize hull because ODE phys-drops have a setsize that
// can be much larger than the visible weapon (its trimesh hull) AND
// rotates with the body. Anchoring a fixed cube keeps pickup feel
// consistent across weapon types and lets client + server agree on the
// same authoritative reach. Both sides use these numbers — keep edits
// in sync naturally by keeping them here.
const float WEAPON_PICKUP_HALF_W    = 18;
const float WEAPON_PICKUP_HEIGHT_DN = 12;
const float WEAPON_PICKUP_HEIGHT_UP = 28;
// Slack pad on the pickup zone — keeps a player whose bbox grazes the
// authoritative cube from bouncing pickup-eligible state on/off when
// snapshot jitter wobbles their position by a unit or two. Same value
// on both sides so client predict and server +use agree on whether
// you're "in the zone".
const float WEAPON_PICKUP_PAD       = 4;

float(float wep) Weapon_PhysDropEligible =
{
    if (wep == WEP_NONE)
        return FALSE;
    return TRUE;
};

// --- Weapon impulses ---
const float WEAPON_IMPULSE_PRIMARY   = 1;
const float WEAPON_IMPULSE_SECONDARY = 2;
const float WEAPON_IMPULSE_MELEE     = 3;
// (impulse 4 = utility cycle — handled inline in the dispatcher)
// C4 select on impulse 5, mirroring the inventory-slot pattern of
// 1=primary / 2=secondary / 3=melee / 4=utility / 5=C4.  Drop got
// shifted to impulse 8 to keep this slot ordering clean — bind via
// `bind g "impulse 8"` (the default).
const float WEAPON_IMPULSE_C4        = 5;
const float WEAPON_IMPULSE_RELOAD    = 6;
const float WEAPON_IMPULSE_SPECIAL   = 7;
const float WEAPON_IMPULSE_DROP      = 8;
// Grappling hook — sv_grappling-gated.
//
//   `impulse 9`   — legacy toggle: press to fire, press again to release.
//                   Bind via `bind <key> "impulse 9"`.
//
//   `impulse 91`  — press-and-hold RELEASE half: paired with the
//                   +grapple / -grapple aliases registered in
//                   CSQC_Init.  `+grapple` fires impulse 9 on key
//                   press, `-grapple` fires impulse 91 on key release.
//                   Bind via `bind <key> "+grapple"`.
//
// The impulse-pair approach is used (rather than a held button bit)
// because the user-command button mask is byte-limited on the
// protocol in use here — bit 256 (+button9) wouldn't traverse the
// wire reliably.  Impulses are scalar and protocol-agnostic.
const float WEAPON_IMPULSE_GRAPPLE        = 9;
const float WEAPON_IMPULSE_GRAPPLE_RELEASE = 91;
const float WEAPON_IMPULSE_NEXT      = 12;
const float WEAPON_IMPULSE_PREV      = 13;
const float WEAPON_IMPULSE_LASTINV   = 14;
// Client-only flashlight toggle. Handled entirely on CSQC — toggles
// a local-render dlight + plays the click sound. Not networked, so
// other players don't see the cone in this version.
const float WEAPON_IMPULSE_FLASHLIGHT = 50;

// --- Weapon slot groups (broader category used by some weapons) ---
const float WSG_MELEE = 3;

// --- Weapon animation states ---
const float WS_IDLE    = 0;
const float WS_DRAW    = 1;
const float WS_FIRE    = 2;
const float WS_RELOAD  = 3;
const float WS_SPECIAL = 4;   // alt-fire / stab / throw

// --- CSQC event IDs (server→client multicast) ---
const float CSQC_EVENT_IMPACT  = 1;   // bullet impact effect
const float CSQC_EVENT_SHELL   = 2;   // shell casing eject
const float CSQC_EVENT_MAGDROP = 3;   // magazine drop
const float CSQC_EVENT_POINTSOUND = 4; // positioned sound (respects dimension masking)
const float CSQC_EVENT_DEBUG_IMPACT = 5; // debug: server bullet hit position
const float CSQC_EVENT_ROUND_CLEANUP = 6; // wipe all client-side debris (bulletholes, shells, mags)
const float CSQC_EVENT_DAMAGE_FLASH = 7; // pain flash HUD element (sent only to victim)
// The reason byte CSQC_EVENT_DAMAGE_FLASH carries after the damage byte: what is
// hurting you, so a player standing in nerve gas does not get the same red flash
// as a player being shot.  A small enum rather than HL's 24-bit field because the
// flash can only be one colour and one byte is the whole budget.
//
// HL draws a sprite icon per type (DMG_SHOWNHUD, cbase.h:641).  The Sven mount
// ships none of that art, so the flash is tinted instead — see
// HUD_PainFlashColour in client/cl_hud.qc.
//
// Lives here rather than beside sv_dmg_bits in sh_weapon_standard.qc because
// that block is inside #ifdef SSQC and the client is half of this contract.
const float DMGHUD_NONE      = 0;
const float DMGHUD_BURN      = 1;   // DMG_BURN | DMG_SLOWBURN
const float DMGHUD_FREEZE    = 2;   // DMG_FREEZE | DMG_SLOWFREEZE
const float DMGHUD_GAS       = 3;   // DMG_NERVEGAS
const float DMGHUD_POISON    = 4;   // DMG_POISON
const float DMGHUD_ACID      = 5;   // DMG_ACID
const float DMGHUD_SHOCK     = 6;   // DMG_SHOCK
const float DMGHUD_RADIATION = 7;   // DMG_RADIATION
const float DMGHUD_DROWN     = 8;   // DMG_DROWN
const float CSQC_EVENT_HITMARKER = 8;   // hitmarker confirmation (sent only to attacker)
const float CSQC_EVENT_BRUSH_DESTROY = 9; // remove bullet holes on a destroyed brush entity
const float CSQC_EVENT_SERVER_HITBOXES = 10; // debug: server-side hitbox state snapshot
const float CSQC_EVENT_GLASS_GIBS = 11;     // glass breakable gib spawn (client-side for submodel selection)
const float CSQC_EVENT_PLAYER_GIBS = 12;    // player gibbed by overkill damage — flesh chunks + blood
const float CSQC_EVENT_DEBRIS_GIBS = 13;    // non-glass breakable debris (concrete/wood/metal/etc.) — purely cosmetic CSQC entities
const float CSQC_EVENT_KILLFEED    = 14;    // kill-feed entry (attacker slot, victim slot, cause, weapon, headshot)
const float CSQC_EVENT_WEAPON_PICKUP_SOUND = 15;  // pickup confirm sound routed to all PVS clients EXCEPT the pickup-er (who already played it via CSQC prediction)
const float CSQC_EVENT_BREAKABLE_IMPACT_SOUND = 16;  // breakable material thump routed to PVS clients except the attacker (who predicted it locally in CSQC_BulletImpact)
const float CSQC_EVENT_BREAKABLE_BREAK_SOUND = 17;   // breakable destruction sound routed to PVS clients except the attacker (who predicted it via replicated brush_health)
const float CSQC_EVENT_FOOTSTEP_SOUND = 18;          // player footstep, routed to PVS clients except the stepper (whose CSQC pmove plays it via localsound as the predicted step fires)
const float CSQC_EVENT_DEATH_DROP = 19;              // visual fake-drop scatter for non-physics death drops; ODE drops use the real SendEntity immediately
const float CSQC_EVENT_GRENADE_EXPLODE = 20;         // grenade detonation FX — sprite + particles + light + boom sound. Server multicasts to PVS EXCEPT shooter (who handles all FX locally via CSQC_FakeHLGrenadeExplode). Carries a sample-variant byte for the boom; the dimension_send mask on the multicast does the filtering (sound() builtin doesn't honor dimension_send, so we route the audio via this event).
const float CSQC_EVENT_DAMAGE_REPORT   = 21;         // death-screen damage report (sent only to the dying player) — given/taken lists with each opponent's name + current HP. cl_playerdamage gates display.
const float CSQC_EVENT_GRENADE_BOUNCE  = 22;         // grenade surface bounce sound. Server multicasts to PVS EXCEPT shooter (who plays it locally via CSQC_FakeHLGrenadeBounce). Carries the sample-variant byte. Same rationale as CSQC_EVENT_GRENADE_EXPLODE — sound() doesn't honor dimension_send, multicast does.
const float CSQC_EVENT_HL_BEAM         = 23;         // HL Gauss/Egon beam segment. Shooter predicts locally; server event is attacker-excluded for remote viewers.
const float CSQC_EVENT_SNOWSPLAT       = 24;         // snowball impact sound/decal. Wall decals are attacker-excluded because the shooter predicts them locally.
const float CSQC_EVENT_PAINTSPLAT      = 25;         // paintball hit decal. Shooter predicts locally; server event is attacker-excluded for remote viewers.
const float CSQC_EVENT_CSGRENADE_EXPLODE = 26;       // CS grenade detonation FX. Payload carries type so HE/flash/smoke can share the multicast.
const float CSQC_EVENT_CSGRENADE_BOUNCE  = 27;       // CS grenade bounce sound. Shooter predicts locally, remote clients receive this.
const float CSQC_EVENT_C4_EXPLODE        = 28;       // C4 detonation FX — sprite gfx/fexplo.spr at 4x scale + boom sound.
const float CSQC_EVENT_DOOR_VIEWROT      = 29;       // private rotating-door yaw delta sent to a single carried player so their CSQC adds it to input_angles.
const float CSQC_EVENT_TRIGGER_HURT_HIT  = 30;       // (reserved, future use; kept here for the byte ordering reference)
const float CSQC_EVENT_BUTTON_SPARK      = 31;       // SPARKS-flagged func_button — server multicasts to PVS, CSQC fires "fx_spark.main" via pointparticles. te_spark didn't render in this engine config; pointparticles with the loaded particle config does.
const float CSQC_EVENT_ENV_EXPLOSION     = 32;       // env_explosion (HL point entity) — fireball sprite + smoke emitter + scorch decal + sparks + sound, masked by spawnflag bits NoDamage/NoFireball/NoSmoke/NoDecal/NoSparks.  Sound always plays per HL spec.
const float CSQC_EVENT_CLEANMODELS       = 33;       // server-console "cleanmodels" trigger — wipes shells/mags client-side (corpses are removed server-side and replicate naturally via SendEntity).
const float CSQC_EVENT_CLEANDECALS       = 34;       // server-console "cleandecals" trigger — wipes bullet holes, scorch decals, muzzle smoke, and CS smoke-grenade puffs client-side.
const float CSQC_EVENT_SPRAY             = 35;       // player spray decal spawn (impulse 19). Payload: spray_id short, owner entnum byte, pos 3×coord, normal 3×coord, name string. Multicast PVS.
const float CSQC_EVENT_SPRAY_REMOVE      = 36;       // FIFO eviction of a player's oldest spray when sv_spraymax is hit. Payload: spray_id short. Multicast ALL so any client that allocated the slot can free it.
const float CSQC_EVENT_PLAYER_FLINCH     = 37;       // visual flinch reaction when a player takes damage.  Payload: 1 byte victim slot, 1 byte hitgroup (HITGROUP_HEAD/GENERIC), 1 SHORT attacker entnum (short because the attacker can be a monster, whose edict number passes 255).  Server multicasts on every non-fatal player hit; the attacker also predicts locally via CSQC_SendHitclaim so they see flinch instantly without waiting for the server round-trip.
const float CSQC_EVENT_ENV_FADE          = 38;       // env_fade HUD overlay. Payload: rgb bytes, alpha byte, duration float, hold float, flags byte.
const float CSQC_EVENT_ENV_MESSAGE       = 39;       // env_message title text. Payload: message/title key string; client resolves titles.txt.
const float CSQC_EVENT_DAMAGE_VIEWKICK   = 40;       // private victim camera punch. Payload: signed short pitch*100, signed short roll*100.
const float CSQC_EVENT_RADIO_CALL        = 41;       // radio quick-chat playback. Payload: resolved voice-line path string. CSQC plays beep1 → voice → beep2 in sequence using soundlength() to time each stage.
const float CSQC_EVENT_PHYSPROP_IMPACT   = 42;       // phys_files contact smoke. Payload: pos 3×coord, normal 3 bytes (0..255 = -1..1), bucket byte (0 slide / 1 soft / 2 hard). Server multicasts to PVS; CSQC fires "weapons.physprop_smoke" via pointparticles. The impact/slide SOUND is server-side sound(), NOT routed through this event.
const float CSQC_EVENT_SLIDE_SOUND       = 43;       // CoD-slide engage sound. Routed to PVS clients EXCEPT the slider (whose CSQC plays it via localsound the instant the slide is predicted). Payload: 1 exclude byte + 1 variant byte (slideN.wav, N=1..5) + 3×coord origin. Mirrors CSQC_EVENT_FOOTSTEP_SOUND.
const float CSQC_EVENT_KILL_REWARD       = 44;       // dopamine kill-cash popup, sent ONLY to the killer. Payload: short reward + 1 headshot byte. CSQC delays the center-top popup 0.5s (orchestralhit) and plays killsound.wav immediately on a headshot kill.
const float CSQC_EVENT_ROUND_REWARD      = 45;       // round win/lose cash, sent ONLY to each surviving-team player at round end. Payload: short amount + 1 win byte. CSQC shows "+$amount" under the win/lose banner + plays cashregister.
const float CSQC_EVENT_NAV_GRAPH         = 46;       // debug: bot nav-graph node chunk. Payload: short total, short start, byte n, then per node: 3×coord + byte linkcount + linkcount×short neighbour. Gated on sv_debug_nav; multicast ALL; cl_navdebug draws nodes + links.
const float CSQC_EVENT_BOT_DEBUG         = 47;       // debug: per-bot AI state. Payload: byte n, then per bot: byte entnum + 3×coord origin + byte state + byte enemy entnum + byte weapon + byte mag. Gated on sv_debug_nav; multicast ALL; cl_navdebug draws labels + enemy lines.
const float CSQC_EVENT_KILLCAM_TRACK     = 48;       // server-side killcam: the KILLER's recorded camera track, reliably unicast to the victim on death so the rewind shows the killer's out-of-PVS approach. Payload: killer slot byte + frame_count byte, then per frame (oldest→newest): short delta_ms (kill_time - frame_time) + 3×coord origin + 2×WriteAngle (pitch, yaw) + weaponstate byte + weapon_id byte.
const float CSQC_EVENT_PLAYER_PAINT      = 49;       // player body paint (sv_paint.qc -> cl_paint.qc). Sub-byte: 0 = camo set (slot byte + amt byte + wall-texture string), 1 = paintball splat (slot byte + r g b bytes + seed short), 2 = clear all (slot byte, respawn wash). MULTICAST_ALL (persistent visual state must reach out-of-PVS clients too).
const float CSQC_EVENT_VOTE_START        = 51;       // trigger_vote opened. Payload: string question + string yes-label + string no-label + byte duration_secs + byte pass_percent. MULTICAST_ALL reliable — a client that misses this shows no prompt and can never answer.
const float CSQC_EVENT_VOTE_UPDATE       = 52;       // running tally while a vote is live. Payload: byte yes + byte no + byte eligible. Sent on every answer, not per-frame.
const float CSQC_EVENT_VOTE_END          = 53;       // vote resolved. Payload: byte outcome (0 = failed, 1 = passed, 2 = nobody voted). Closes the prompt.
const float CSQC_EVENT_GAME_TEXT         = 54;       // GoldSrc game_text. Unlike CSQC_EVENT_ENV_MESSAGE (which ships a titles.txt KEY and resolves styling client-side), game_text carries its styling inline on the map entity, so the resolved values travel on the wire. Payload: byte channel (1..4) + 2×coord x/y (-1 = auto-centre) + byte effect + 3 bytes colour + 3 bytes colour2 + 4×float fadein/fadeout/holdtime/fxtime + string message.
const float CSQC_EVENT_PROP_DECLOAK      = 50;       // Prop Hunt: a disguised hider died — smoke poof at the disguise hull centre as the real player model is revealed + ragdolled (server-side). Payload: pos 3×coord + hull-height byte (poof scale). MULTICAST_PVS.
const float CSQC_EVENT_MONSTER_MODELS    = 55;       // the set of modelindexes that belong to AI monsters, so the SHOOTER's own predicted bullet trace can stop on a monster instead of passing through it (see CSQC_Monster_OverrideTrace). Payload: byte n, then n×short modelindex. MULTICAST_ALL reliable, sent once the map's monsters are built and again if a later spawn introduces a new model.
const float CSQC_EVENT_MONSTER_GIBS      = 56;       // a monster body torn apart.  Payload: 3×coord origin, 3×coord direction, byte count, short damage-scale, byte gibset (0 = human hgibs.mdl, 1 = alien agibs.mdl).  The gib set is chosen server-side from the monster's CLASS_* (combat.cpp:256-285) because CSQC has no idea what classification a replicated monster carries.
const float CSQC_EVENT_SHOCKWAVE         = 57;       // GoldSrc TE_BEAMCYLINDER / TE_IMPLOSION, which this engine has neither of — an expanding (or imploding) horizontal ring of sprites/shockwave.spr.  Payload: 3×coord centre, short radius, byte life (1/20 s), byte width, 3 bytes colour, byte kind (0 expand / 1 implode).  MULTICAST_PHS, matching HL's MSG_PAS.  See shared/sh_shockwave.qc.
const float CSQC_EVENT_ALIEN_FX          = 58;       // one event for every creature attack visual, because they are all the same shape on the wire and were all missing for the same reason: the server never called pointparticles/trailparticles at all.  Payload: byte kind (ALIENFX_*), 3×coord origin, 3 bytes direction (0..255 = -1..+1, 127 = 0).  The kind picks the recipe AND the dlight client-side, so adding a creature effect is one table row rather than a new event.  MULTICAST_PVS.  See shared/sh_alienfx.qc.
const float CSQC_EVENT_ENV_BLOOD         = 59;       // env_blood, the mapper-fired blood spray (HL effects.cpp:1718).  Payload: 3×coord origin, 3 bytes direction (same quantisation as ALIEN_FX), short amount, byte colour (0 red / 1 yellow), byte spawnflags (RANDOM/STREAM/PLAYER/DECAL).  Client-side for the same structural reason as ALIEN_FX: the particle config is only loaded into the CLIENT VM, so a server pointparticles() cannot resolve a recipe name at all.  MULTICAST_PVS.  See shared/sh_envblood.qc.

const float CSQC_EVENT_LOOKAT_NPC        = 64;       // the NPC under this player's crosshair, so the look-at name tag (client/cl_lookatname.qc, which has always been player-only) can name monsters and show their HP.  Payload: SHORT entnum (0 = looking at nothing), and when non-zero SHORT health + SHORT max_health + BYTE newtarget, plus a STRING display name ONLY on the frame the target changes — a name cannot change while the target does not.  Unicast to the looker (msg_entity) and sent on CHANGE, exactly like CSQC_EVENT_TRAIN_HUD, so a player staring at an undamaged monster costs nothing at all.  SHORT for the entnum because a monster's edict number passes 255 routinely.  WHY THE SERVER TRACES rather than CSQC asking about an entnum it found itself: CSQC can identify the monster (getentity + the CSQC_EVENT_MONSTER_MODELS whitelist, cl_monstertrace.qc) but no GE_* property carries health — the engine's enum has 37 members and none of them is one (pr_common.h:1020-1060) — so the health has to come over the wire regardless, and a server-side trace costs one traceline per player per 100 ms with no round-trip and no lag skew.  See sv_lookatnpc.qc.
const float CSQC_EVENT_SERVER_NPC_HITBOX = 65;       // sv_debug_hitboxes on NPCs.  The player overlay (CSQC_EVENT_SERVER_HITBOXES) ships a pose and the client rebuilds the 20 per-bone boxes from the SHARED hitbox table — but that table is the IQM PLAYER rig and an HL .mdl carries its own studio hitboxes, which QC cannot enumerate at all: addmodelhitbox is the only hitbox builtin in either VM and it is write-only.  So what a monster gets sent is the ONE box that actually gates its shots — the expanded cull AABB W_MonstersExpandHitboxes installs (sv_monsters.qc) — already summed server-side.  Payload: SHORT entnum + 3×coord origin + 3×coord mins + 3×coord maxs + BYTE mode (1 per-shot / 2 continuous).  SHORT entnum for the same reason CSQC_EVENT_LOOKAT_NPC uses one: a monster edict passes 255 routinely, and the player event's WriteByte would alias it onto a player slot.  Mode 1 unicasts to the shooter, mode 2 multicasts PVS.  See W_SendServerNPCHitbox (server/sv_monsters.qc) and CSQC_DrawNPCHitboxes (client/cl_debuginfo.qc).
const float CSQC_EVENT_INVENTORY         = 63;     // Sven Co-op item_inventory: what the player is currently carrying, so the HUD can show it.  Payload: byte count (0..INV_HUD_MAX) + byte overflow, then per item a string icon path and a string label.  Unicast to the holder (msg_entity) and sent on CHANGE, exactly like CSQC_EVENT_TRAIN_HUD — an inventory only moves when somebody picks something up.  Strings rather than indices because item_icon is a mapper-authored sprite path with no id space to compress it into, and a carried inventory changes a handful of times per map.  Sven's own first release of this shipped with no HUD at all (its changelog offers only an `inventory` console listing, "a fancy UI will be added in a future release"), so this widget has no upstream layout to match.  See sv_item_inventory.qc / cl_hud.qc.
const float CSQC_EVENT_ENV_FUNNEL        = 61;       // env_funnel, HL's TE_LARGEFUNNEL (effects.cpp:2111-2134) — a 16x16 grid of flares converging on the entity, or flying out from it with SF_FUNNEL_REVERSE.  Payload: 3×coord origin + 1 byte reverse.  Client-side because the grid, the heights and the speeds all live in the ENGINE's R_FunnelSprite rather than in the SDK, and because a particle recipe name only resolves inside the client VM.  MULTICAST_PVS.  See shared/sh_envfunnel.qc.
const float CSQC_EVENT_SCREENSHAKE       = 62;       // GoldSrc gmsgShake (UTIL_ScreenShake, util.cpp:674) — the screen-shake channel this tree never had, which is why env_shake was a do-nothing stub and mortar impacts landed silently. Payload: 3 floats, amplitude / duration / frequency, already quantised server-side onto HL's 4.12 and 8.8 fixed-point grids so the SDK's numbers (and its 15.99976 amplitude ceiling) carry over exactly. UNICAST per player, because the sender tests FL_ONGROUND and the radius individually — a PVS multicast would shake airborne players too. See sv_screenshake.qc / cl_screenshake.qc.
const float CSQC_EVENT_TRAIN_HUD         = 60;       // func_tracktrain driver readout — HL's gmsgTrain (player.cpp:4254-4263), which the HUD draws as a throttle indicator.  Payload: ONE byte, the TRAIN_* state (0 off / 1 neutral / 2 slow / 3 medium / 4 fast / 5 back), packed server-side by TrainSpeed() against the train's authored max.  Unicast to the driver only (msg_entity), and sent on CHANGE rather than per-frame, exactly as HL gates it on the TRAIN_NEW bit.  See sv_func_traincontrols.qc / cl_hud.qc.

// --- func_tracktrain HUD states.  HL player.cpp:63-68, the low nibble of m_iTrain. ---
const float TRAIN_HUD_OFF     = 0;
const float TRAIN_HUD_NEUTRAL = 1;
const float TRAIN_HUD_SLOW    = 2;
const float TRAIN_HUD_MEDIUM  = 3;
const float TRAIN_HUD_FAST    = 4;
const float TRAIN_HUD_BACK    = 5;

// --- Kill-feed causes (byte payload of CSQC_EVENT_KILLFEED) ---
const float KILL_CAUSE_WEAPON       = 0;
const float KILL_CAUSE_FALL         = 1;
const float KILL_CAUSE_SUICIDE      = 2;
const float KILL_CAUSE_FRIENDLYFIRE = 3;
const float KILLFEED_NO_ATTACKER    = 255;

// --- Server-projectile types (CSQC_ENT_PROJECTILE sub-byte) ---
// Routed through the CSQC tosssmooth pipeline (cl_projectiles.qc parser
// + cl_tosssmooth.qc extrap+smooth predraw) so other players see the
// projectile fly smoothly instead of snapping at every server send tick.
// Each type carries its own model + gravity factor — see Projectile_Type
// helpers below. Add new entries here AND in those helpers.
const float PROJ_TYPE_HLGRENADE     = 0;   // hand grenade (gravity 0.5)
const float PROJ_TYPE_GRENADE       = 1;   // GL grenade   (gravity 1.0)
const float PROJ_TYPE_RPG_ROCKET    = 2;   // RPG rocket   (gravity 0.0)
const float PROJ_TYPE_CROSSBOW_BOLT = 3;   // crossbow     (gravity 0.0)
const float PROJ_TYPE_SNOWBALL      = 4;   // snowball     (gravity 0.65)
const float PROJ_TYPE_CSHEGRENADE   = 5;   // CS HE        (gravity 0.55)
const float PROJ_TYPE_CSFLASHBANG   = 6;   // CS flashbang (gravity 0.55)
const float PROJ_TYPE_CSSMOKEGRENADE = 7;  // CS smoke     (gravity 0.55)
const float PROJ_TYPE_DISPLACER_BALL = 9;  // displacer orb (gravity 0.0)
const float PROJ_TYPE_PAINTBALL     = 8;   // paintball — sv_paintball_projectile mode. Reuses
                                           // w_snowball.mdl shrunk via .scale, tinted via
                                           // .colormod (3 extra wire bytes when ptype==8).
const float PROJ_TYPE_SHOCK_BOLT    = 10;  // OpFor shock rifle (gravity 0.0)
// OpFor spore launcher.  It used to ride PROJ_TYPE_GRENADE, and because CSQC
// resolves the model PURELY from this byte, every observer saw a grenade-
// launcher grenade instead of a spore — while the shooter saw nothing at all
// (projectile_SendEntity hides the real one from its owner and there was no
// local fake).  Both halves of "the projectile is invisible".
const float PROJ_TYPE_SPORE         = 11;  // OpFor spore      (gravity 1.0)
// The MP5/M203 contact grenade needs a type of its OWN rather than sharing
// PROJ_TYPE_GRENADE with the grenade launcher and the SOFLAM mortar: it wants
// Half-Life's flight shape (800 u/s, gravity 0.5, no up-kick — ggrenade.cpp:364,
// mp5.cpp:230) and the model is resolved from this byte, so reusing the GL's
// type would have dragged the GL onto the same numbers.
const float PROJ_TYPE_SMG_GRENADE   = 12;  // MP5 / M203 contact grenade (gravity 0.5)
// Day of Defeat anti-tank.  THREE types rather than one, because DoD ships three
// distinct rocket meshes (w_bazooka_rocket / w_pschreck_rocket / w_piat_rocket)
// and the projectile MODEL is chosen from this id on both sides — one shared id
// would put an American rocket on a Panzerschreck.  The PIAT is separated for a
// second reason as well: it is a SPIGOT MORTAR, not a rocket, so it arcs
// (gravity 0.4) while the other two fly flat.
const float PROJ_TYPE_DOD_BAZOOKA   = 13;  // M1A1 bazooka rocket        (gravity 0.0)
const float PROJ_TYPE_DOD_SCHRECK   = 14;  // Panzerschreck rocket       (gravity 0.0)
const float PROJ_TYPE_DOD_PIAT      = 15;  // PIAT bomb, lobbed          (gravity 0.4)
// The two DoD hand grenades.  Same 0.55 gravity as the CS three — they go
// through the identical throw/bounce/fuse lifecycle in sh_wpn_csgrenades.qc —
// and separate ids only so each gets its own world mesh on the wire.
const float PROJ_TYPE_DOD_MILLS     = 16;  // Mills bomb                 (gravity 0.55)
const float PROJ_TYPE_DOD_STICK     = 17;  // Stielhandgranate           (gravity 0.55)
// The mortar bomb: the only projectile here at FULL gravity, because a mortar is
// the one weapon whose whole point is the arc.  DoD ships no mortar-shell mesh
// (checked: the only *_rocket models are the bazooka's, the schreck's and the
// PIAT's), so it borrows the PIAT's spigot bomb, which is the closest shape and
// is DoD-exclusive.
const float PROJ_TYPE_DOD_MORTAR    = 18;  // 3-inch mortar bomb         (gravity 1.0)

// Type → world model path. Matches the SSQC spawn site of each
// projectile. Used by the CSQC parser to setmodel the local entity
// once it knows the type byte.
string(float t) Projectile_TypeModel =
{
    // These MUST track the setmodel() the server does for the same projectile.
    // The HL grenade and the RPG rocket both moved to the mounted valve
    // originals with the weapons; the crossbow bolt deliberately did not (see
    // sh_wpn_hlcrossbow.qc:23) and still points at the local conversion.
    if (t == PROJ_TYPE_HLGRENADE)     return "models/w_grenade.mdl";
    if (t == PROJ_TYPE_GRENADE)       return "models/weapons/wpn_grenadelauncher/grenade.mdl";
    if (t == PROJ_TYPE_RPG_ROCKET)    return "models/rpgrocket.mdl";
    if (t == PROJ_TYPE_CROSSBOW_BOLT) return "models/weapons/wpn_hlcrossbow/bolt.mdl";
    if (t == PROJ_TYPE_SNOWBALL)      return "models/weapons/wpn_snowball/w_snowball.mdl";
    // CS grenades: the mount's, not the mod-local copies.  Those were QUAKE MDL
    // (`IDPO`) conversions at 287-653 KB against the cstrike originals' 24 KB of
    // GoldSrc studio — a palettised 8-bit skin and no bodygroups, which is what a
    // "black smear" thrown grenade actually is.
    if (t == PROJ_TYPE_CSHEGRENADE)   return "models/w_hegrenade.mdl";
    if (t == PROJ_TYPE_CSFLASHBANG)   return "models/w_flashbang.mdl";
    if (t == PROJ_TYPE_CSSMOKEGRENADE) return "models/w_smokegrenade.mdl";
    if (t == PROJ_TYPE_PAINTBALL)     return "models/weapons/wpn_snowball/w_snowball.mdl";
    if (t == PROJ_TYPE_DISPLACER_BALL) return "sprites/exit1.spr";
    // Opposing Force's own shock bolt mesh, out of the mounted gearbox tree.
    if (t == PROJ_TYPE_SHOCK_BOLT)    return "sprites/muzzle_shock.spr";
    // Sven's own spore mesh, out of the mounted svencoop tree.  Verified IDST.
    if (t == PROJ_TYPE_SPORE)         return "models/spore.mdl";
    // Half-Life's own contact-grenade mesh (ggrenade.cpp:351).  Verified IDST.
    if (t == PROJ_TYPE_SMG_GRENADE)   return "models/grenade.mdl";
    // Day of Defeat's own three, out of the mounted dod tree.  All DoD-exclusive
    // names — none of the ten HL filenames the dod mount collides on.
    if (t == PROJ_TYPE_DOD_BAZOOKA)   return "models/w_bazooka_rocket.mdl";
    if (t == PROJ_TYPE_DOD_SCHRECK)   return "models/w_pschreck_rocket.mdl";
    if (t == PROJ_TYPE_DOD_PIAT)      return "models/w_piat_rocket.mdl";
    if (t == PROJ_TYPE_DOD_MILLS)     return "models/w_mills.mdl";
    if (t == PROJ_TYPE_DOD_STICK)     return "models/w_stick.mdl";
    if (t == PROJ_TYPE_DOD_MORTAR)    return "models/w_piat_rocket.mdl";   // no mortar mesh exists
    return "";
};

// Is this projectile's world model a GoldSrc IDST model rather than a Quake
// IDPO one?  Decides whether its pitch has to be negated — see W_ModelAngles.
//
// Checked against the files, not guessed from the path: rpgrocket.mdl and
// w_grenade.mdl come from the mounted valve originals and begin "IDST"; the
// grenade-launcher grenade and the crossbow bolt are local conversions and
// begin "IDPO".  Keep this in step with Projectile_TypeModel above.
float(float t) Projectile_TypeIsHLModel =
{
    // The shock bolt used to be here, when it was the IDST shock_effect.mdl.
    // It is a view-facing sprite now (see SHOCK_BOLT_MODEL), and a sprite has
    // no mesh orientation to negate.
    return t == PROJ_TYPE_RPG_ROCKET   || t == PROJ_TYPE_HLGRENADE
        || t == PROJ_TYPE_SPORE        || t == PROJ_TYPE_SMG_GRENADE
        // EVERY DoD PROJECTILE WAS MISSING, and the file's own instruction two
        // lines up — "Keep this in step with Projectile_TypeModel above" — is
        // exactly what went unfollowed when the six DoD rows were added there.
        // All five meshes begin "IDST" (checked on the mounted dod tree), and
        // every SERVER site already passed TRUE by hand, so server and client
        // were negating pitch differently for the same projectile: the server
        // said +45, the client drew -45.  Since these are SendEntity
        // projectiles with no owner skip, the CSQC copy is the only thing
        // anyone sees, so the client's version was the one on screen.
        || t == PROJ_TYPE_DOD_BAZOOKA  || t == PROJ_TYPE_DOD_SCHRECK
        || t == PROJ_TYPE_DOD_PIAT     || t == PROJ_TYPE_DOD_MORTAR
        || t == PROJ_TYPE_DOD_MILLS    || t == PROJ_TYPE_DOD_STICK;
};

// DoD's rocket meshes are authored with the NOSE AT -X, the opposite of
// GoldSrc's +X-forward convention, so handing them their direction of travel
// flies them TAIL-FIRST.  Measured by transforming every vertex through the
// seq-0 frame-0 bone pose (the bone default pose alone is not enough — the
// animation deltas carry most of the rotation):
//
//   w_bazooka_rocket.mdl   single-vertex cone apex at X=-11.61, widest ring
//                          X=-7.85 r=1.46, stabiliser flanges at X=+5.19/+9.44
//   w_pschreck_rocket.mdl  apex X=-10.37, flat 8-vertex cap at X=+10.08
//   w_piat_rocket.mdl      fuze rod X=-7.44..-5.59, body r=1.55 at
//                          X=-4.59..-1.55, flange r=1.62 at X=+5.46
//
// CONTROL for the measuring pipeline: rpgrocket.mdl has its apex at X=+15.47,
// and Half-Life orients that model with plain VecToAngles plus a negated pitch
// (rpg.cpp) and it looks right — so +X really is forward, and these four really
// are mirrored.  On the mortar this compounded with the pitch-sign bug above:
// the two errors happened to cancel into "nose 45 degrees up" while the yaw
// stayed 180 out, which is why it read as "faces straight up" rather than as an
// obviously backwards rocket.
//
// The grenades (w_mills, w_stick) are absent on purpose: they tumble on
// avelocity and have no meaningful forward axis to get wrong.
float(float t) Projectile_TypeModelPointsBackwards =
{
    return t == PROJ_TYPE_DOD_BAZOOKA || t == PROJ_TYPE_DOD_SCHRECK
        || t == PROJ_TYPE_DOD_PIAT    || t == PROJ_TYPE_DOD_MORTAR;
};

// Does this projectile NOSE OVER along its flight path, as opposed to tumbling
// on .avelocity?  cl_projectiles.qc re-derives .angles from the extrapolated
// velocity every render frame for these; everything else keeps the avelocity
// spin.  The two are mutually exclusive and none of these is ever given an
// avelocity at its spawn site.
float(float t) Projectile_TypeFacesVelocity =
{
    return t == PROJ_TYPE_RPG_ROCKET    || t == PROJ_TYPE_CROSSBOW_BOLT
        || t == PROJ_TYPE_DOD_BAZOOKA   || t == PROJ_TYPE_DOD_SCHRECK
        || t == PROJ_TYPE_DOD_PIAT      || t == PROJ_TYPE_DOD_MORTAR;
};

// Projectile_FlightAngles, which combines the two corrections above with the
// pitch negation, is defined immediately after W_ModelAngles below — it needs it.

// Does this projectile's art expect ADDITIVE blending?
//
// FTE does not read a GoldSrc asset's own blend mode, in either format:
//
//   * Sprites.  sprites/exit1.spr declares texFormat 1 = SPR_ADDITIVE in its
//     header, but Mod_LoadSpriteFrame (gl_model.c:6925-7005) only ever acts on
//     SPRHL_INDEXALPHA and SPRHL_ALPHATEST -- SPR_ADDITIVE falls into the else
//     that forces every palette entry to alpha 255.  The frame then registers
//     as SPRITE_SHADER_UNLIT, which at the shipped gl_blendsprites 0 compiles
//     to `alphafunc ge128` + depthwrite, so every texel passes.  HL additive art
//     is opaque paletted art whose BLACK is the transparency, so the result is
//     an opaque black square with the effect drawn inside it.  That is exactly
//     the "displacer ball has a black square background" report.
//
//   * Studio models.  shock_effect.mdl's one texture is blueChrome.bmp with
//     flags 0x0003 = FLATSHADE|CHROME, which FTE draws tcgen environment +
//     rgbgen lightingdiffuse -- a LIT metal sliver, not an energy bolt.  FTE
//     has no STUDIO_NF_ADDITIVE handling at all (gl_hlmdl.c:543-580).
//
// The fix in both cases is the same and the mod already uses it elsewhere
// (cl_bulletimpact.qc:449, cl_c4.qc:22): .effects |= EF_ADDITIVE, which the
// engine maps NQEF_ADDITIVE -> RF_ADDITIVE (pr_csqc.c:811) -> BEF_FORCEADDITIVE,
// and gl_backend.c:3140 then clears the alpha test and depthwrite and forces
// SRC_ALPHA,ONE.  It works for sprites (gl_alias.c:2903) and models alike.
//
// MUST be applied on the CSQC entity, not just the server one: these are all
// SendEntity projectiles, so the thing being rendered is built by
// CSQC_Projectile_Update -- and again on each weapon's CSQC-local fake, which
// is the only copy the shooter ever sees (projectile_SendEntity excludes the
// owner, sv_weapons.qc:2568).
float(float t) Projectile_TypeIsAdditive =
{
    return t == PROJ_TYPE_DISPLACER_BALL || t == PROJ_TYPE_SHOCK_BOLT;
};

// Frames per second for a projectile whose model is an ANIMATED sprite, or 0
// for anything that holds a single frame.
//
// exit1.spr carries 25 frames and the mod was pinning .frame to 0 on every
// update, so the orb read as a dead blob.  Opposing Force animates it the same
// way it animates the egon flare -- a plain frame walk, no group sprite.
float(float t) Projectile_TypeSpriteFPS =
{
    if (t == PROJ_TYPE_DISPLACER_BALL) return 15;
    if (t == PROJ_TYPE_SHOCK_BOLT)     return 12;   // 3 frames of crackle
    return 0;
};

// Advance an animated-sprite projectile's frame from its spawn time.  Shared by
// the networked twin's predraw and the weapons' CSQC-local fakes so the two
// cannot drift.  `born` is the cltime the entity appeared.
//
// CSQC only: cltime and modelframecount are client-side, and the server has no
// say in a sprite's frame anyway (these projectiles are all SendEntity, so what
// gets drawn is built entirely in CSQC).
#ifdef CSQC
void(entity e, float ptype, float born) Projectile_AnimateSprite =
{
    float fps = Projectile_TypeSpriteFPS(ptype);
    if (fps <= 0)
        return;
    float frames = modelframecount(e.modelindex);
    if (frames <= 1)
        return;
    float f = floor((cltime - born) * fps);
    e.frame = f - floor(f / frames) * frames;    // f % frames, in floats
};
#endif

// Angles for a projectile pointing along `v`.
//
// vectoangles() answers in MESH convention (+pitch = UP).  FTE only converts to
// that convention for mod_alias models — cl_ents.c and the CSQC path in
// pr_csqc.c both gate the r_meshpitch flip on `model->type == mod_alias` — and a
// GoldSrc IDST model is mod_halflife, so it renders +pitch = DOWN.  Feed
// vectoangles() straight into an IDST model's .angles and it points at twice
// its pitch in the wrong direction: level shots look fine, a rocket fired at the
// ceiling appears to dive at the floor.
//
// Half-Life compensates in exactly the same place (rpg.cpp negates pitch right
// after MakeVectors), and this repo already does it by hand for the tripmine.
//
// `is_hl_model` rather than a blanket negate because it is genuinely per-model:
// the crossbow bolt is IDPO and must NOT be flipped.
vector(vector v, float is_hl_model) W_ModelAngles =
{
    vector a = vectoangles(v);
    if (is_hl_model)
        a_x = -a_x;
    return a;
};

// THE ONE PLACE that turns a projectile's velocity into renderable .angles.
// Both corrections — the IDST pitch negation and the nose-at-minus-X mirror —
// live here so the server spawn, the client spawn and the client predraw cannot
// drift apart again.  Drifting is exactly what happened: every server site
// passed is_hl_model=TRUE by hand while the client asked
// Projectile_TypeIsHLModel, which had never been updated for the DoD rows, so
// the two sides negated the pitch differently for the same projectile.
vector(float t, vector v) Projectile_FlightAngles =
{
    if (Projectile_TypeModelPointsBackwards(t))
        v = '0 0 0' - v;
    return W_ModelAngles(v, Projectile_TypeIsHLModel(t));
};

// Type → gravity factor for CSQC extrap. Must match the .gravity each
// projectile sets on its server-spawn site so the CSQC trajectory
// extrapolation curves the same way the server's MOVETYPE_TOSS path
// computes between snapshots.
float(float t) Projectile_TypeGravity =
{
    if (t == PROJ_TYPE_HLGRENADE)     return 0.5;
    if (t == PROJ_TYPE_GRENADE)       return 1.0;
    if (t == PROJ_TYPE_RPG_ROCKET)    return 0;
    if (t == PROJ_TYPE_CROSSBOW_BOLT) return 0;
    if (t == PROJ_TYPE_SNOWBALL)      return 0.65;
    if (t == PROJ_TYPE_CSHEGRENADE)   return 0.55;
    if (t == PROJ_TYPE_CSFLASHBANG)   return 0.55;
    if (t == PROJ_TYPE_CSSMOKEGRENADE) return 0.55;
    if (t == PROJ_TYPE_PAINTBALL)     return 0.45;   // PAINTBALL_PROJ_GRAVITY (sh_wpn_paintball.qc)
    if (t == PROJ_TYPE_DISPLACER_BALL) return 0;
    if (t == PROJ_TYPE_SHOCK_BOLT)    return 0;
    if (t == PROJ_TYPE_SPORE)         return 1.0;   // matches sp.gravity at the spawn site
    if (t == PROJ_TYPE_SMG_GRENADE)   return 0.5;   // HL's pev->gravity (ggrenade.cpp:364)
    if (t == PROJ_TYPE_DOD_BAZOOKA)   return 0;
    if (t == PROJ_TYPE_DOD_SCHRECK)   return 0;
    if (t == PROJ_TYPE_DOD_PIAT)      return 0.4;   // spigot mortar — it arcs
    if (t == PROJ_TYPE_DOD_MILLS)     return 0.55;
    if (t == PROJ_TYPE_DOD_STICK)     return 0.55;
    if (t == PROJ_TYPE_DOD_MORTAR)    return 1.0;    // a mortar IS the arc
    return 0;
};

// Should the HUD crosshair render for this weapon?  Melees, utility
// items, and scope-capable snipers all hide it.  Must stay in sync with
// the `show_crosshair` parameter passed to W_SetCrosshairProfile in
// each weapon's equip function.  Used by cl_crosshair.qc so visibility
// tracks the predicted weapon switch instantly — server still networks
// STAT_CROSSHAIR_DISABLED but the client no longer reads it, avoiding
// the stale-crosshair-after-switch stutter at high ping.
float(float wep_id) Weapon_HasCrosshair =
{
    return WeaponManifest_HasCrosshair(wep_id);
};

// Can this weapon enter a scoped (zoomstage > 0) state via its alt-fire?
// Used by the HUD to suppress the scope overlay after a weapon switch
// leaves the server still reporting zoomstage > 0 (the real state catches
// up a moment later under high ping).  If a non-scope weapon is equipped
// we treat zoomstage as 0 for HUD gating, regardless of the stat.
float(float wep_id) Weapon_HasScope =
{
    // sv_codscopes mode reassigns +attack2 on scout / awp from the
    // CS-style stage-cycle to a CoD-style ADS-hold scope (state
    // machine in client/cl_codscope.qc).  Hiding the scope-capable
    // flag for those two weapons under codscopes mode automatically
    // suppresses the legacy zoom path: CSQC_UpdateViewAliveSensitivity
    // (cl_main.qc), HUD_DrawScope gate (cl_hud.qc), CSQC_ApplySniperSway
    // (cl_cameras.qc), and the predicted-shot zero-spread branch all
    // gate on Weapon_HasScope — when this returns 0 for scout/awp the
    // legacy stack treats them as unscoped weapons and the CoD
    // overlay / FOV / fog story owns the entire feel for them.
    // WEP_SNIPERRIFLE belongs in this list for exactly the same reason the other
    // two are here: it is registered SCOPE_CLASS_SNIPER_BOLT and is therefore
    // owned by the CoD overlay whenever sv_codscopes is on (cfg/server.cfg ships
    // it as 1).  Leaving it out meant the legacy stack kept treating it as a
    // scope-capable weapon under codscopes mode, so the two scope systems both
    // believed they owned its FOV, sway and overlay.
    if ((wep_id == WEP_SCOUT || wep_id == WEP_CSAWP || wep_id == WEP_SNIPERRIFLE)
        && PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    return WeaponManifest_HasScope(wep_id);
};

// DOES THIS WEAPON PRESENT A ZOOMED VIEW?  A strictly wider question than
// Weapon_HasScope, and deliberately kept separate from it.
//
// Weapon_HasScope answers "is this a SCOPE", and a yes drags in the whole sniper
// story: hold-breath stamina, scope sway, the sniper fog, the CoD state machine's
// eligibility, the post-fire scope-out.  The binoculars are none of those things —
// they cannot fire at all — but they do magnify, and the three places that decide
// what the SCREEN looks like should treat them like any other zoom:
//   client/cl_hud.qc          the static overlay
//   client/cl_main.qc         the zoom FOV + mouse sensitivity scaler
//   client/cl_codscope.qc     hiding the viewmodel while zoomed
//
// So those three ask this, and everything else keeps asking Weapon_HasScope.  That
// split is the whole reason the binoculars can have a scope picture without also
// growing a hold-breath meter.
float(float wep_id) Weapon_HasZoomView =
{
    if (wep_id == WEP_DODBINOCS)
        return 1;
    return Weapon_HasScope(wep_id);
};

// Does the SERVER own this weapon's +attack, rather than waiting to be told?
//
// Under sv_trust_clienthits >= 1 (the shipped default, sh_cvar_table.qc) the
// server's autonomous fire in W_WeaponFrame is switched off and self.fire() runs
// only when the client sends `cmd cs`.  That command is emitted from exactly ONE
// place in the tree - SH_StandardTryFire, sh_weapon_standard.qc - so a weapon
// that hand-rolls its own try-fire and never calls it MUST answer TRUE here or
// its +attack never reaches the server at all.  There are only two self.fire()
// call sites (sv_player.qc's `cs` handler and sv_weapons.qc's W_WeaponFrame), so
// the failure is total, not partial: no damage to monsters/breakables/props
// (client hitclaims are rejected outside player slots, sh_weapon_logic.qc), no
// AI_HeardGunfire (its only call site is inside SH_StandardTryFire), and no
// third-person shoot pose (it keys off wep_action_id, which only the server's
// fire advances).  +attack2 is NOT gated, which is why a half-broken weapon
// still works on right-click - the tell that sent us here.
//
// This lived as a hand-written boolean inside W_WeaponFrame and drifted twice.
// check_serverfire.py now derives the correct set straight from the
// weapon sources and fails if this list disagrees with it; run it after adding
// any weapon.
//
// Two populations, and it is worth keeping them visually apart:
//   (a) weapons whose fire IS a server-side action - melee (so a swing reaches
//       PhysProp_TryPushFromTrace), thrown/placed ordnance, the gravity gun's
//       Carry_TryGrab, the grapple's hook spawn.  These can never emit `cs`.
//   (b) ordinary predicted guns that simply predate SH_StandardTryFire and kept
//       their own try-fire.  These were silently dead.
float(float wep_id) W_FireIsServerAutonomous =
{
    // (a) server-side actions
    if (wep_id == WEP_MELEE           || wep_id == WEP_KNIFE
     || wep_id == WEP_HLCROWBAR       || wep_id == WEP_WRENCH
     || wep_id == WEP_KATANA          || wep_id == WEP_BUTTERFLY
     || wep_id == WEP_THSPANNER       || wep_id == WEP_PIPEWRENCH
     || wep_id == WEP_OPKNIFE)        return TRUE;
    // The medkit heals and the SOFLAM calls a strike: both are server-side
    // actions with no shot to predict and both hand-roll their try-fire, which
    // is exactly the pair of properties that puts a weapon here.
    // Tools.  The binoculars belong here for exactly the stated reason:
    // SH_DodBinocsTryToggle is a hand-rolled two-state latch (there is no
    // magazine, no refire and no dry-fire for SH_StandardTryFire to gate on), so
    // it emits no `cmd cs` and +attack would raise them client-side and nowhere
    // else.  Note the DoD LONG ARMS added alongside them are NOT here — every one
    // of them reaches SH_StandardTryFire / SemiAuto, and listing such a weapon
    // makes the server fire a second time per trigger pull.
    if (wep_id == WEP_MEDKIT          || wep_id == WEP_ASSOFLAM
     || wep_id == WEP_DODBINOCS)      return TRUE;
    if (wep_id == WEP_HLGRENADE       || wep_id == WEP_SATCHEL
     || wep_id == WEP_TRIPMINE        || wep_id == WEP_SNARK
     || wep_id == WEP_CSHEGRENADE     || wep_id == WEP_CSFLASHBANG
     || wep_id == WEP_CSSMOKEGRENADE  || wep_id == WEP_CFC4
     || wep_id == WEP_SNOWBALL        || wep_id == WEP_SLINGSHOT
     || wep_id == WEP_DODMILLS        || wep_id == WEP_DODSTICK
     || wep_id == WEP_PENGUIN)        return TRUE;
    // The four DoD melee weapons.  SH_DodMeleeTryFire hand-rolls the whole gate
    // (it has no magazine to check, so SH_StandardTryFire cannot be used), which
    // means it emits no `cmd cs` and the server would otherwise never call
    // self.fire() for them at all.
    //
    // THE THREE ANTI-TANK LAUNCHERS ARE DELIBERATELY *NOT* HERE, and this note
    // exists because putting them here was the obvious-looking mistake:
    // SH_DodATTryFire spawns a projectile rather than a hitscan, which FEELS
    // like the same category, but it reaches SH_StandardTryFireSemiAuto to do
    // it — so it already emits `cmd cs` and the server already fires on that.
    // Listing them as autonomous as well launched two rockets per trigger pull.
    // check_serverfire.py caught it, which is what that script is for.
    if (wep_id == WEP_DODAMERK        || wep_id == WEP_DODFAIRBAIRN
     || wep_id == WEP_DODPARAKNIFE    || wep_id == WEP_DODSPADE) return TRUE;
    if (wep_id == WEP_GRAVITYGUN      || wep_id == WEP_BGRAPPLE) return TRUE;

    // (b) predicted guns with a bespoke try-fire
    // WEP_MINIGUN belongs here: its gate is the barrel SPIN rather than a
    // magazine, so it hand-rolls its try-fire and never calls SH_StandardTryFire.
    // It was excluded on the stated grounds that it "still emits `cmd cs`
    // through the normal predicted path" — it does not, and the result was a gun
    // with unlimited ammo that dealt no damage and made no sound.
    // WEP_CSXM1014 is the third instance of exactly the same omission, found by
    // check_serverfire.py once its false positives were cleared out of the way.
    // SH_CSXM1014TryFire hand-rolls the whole gate (sprint / lower / WS_IDLE /
    // attack_finished / magazine, then a phase-locked advance) and never touches
    // SH_StandardTryFire, so it emitted no `cmd cs` and the server never called
    // self.fire() for it — the same silent, total failure the minigun had, on the
    // sibling of WEP_CSM3 which was listed here from the start.
    if (wep_id == WEP_HLSHOTGUN       || wep_id == WEP_CSM3
     || wep_id == WEP_CSXM1014
     || wep_id == WEP_GAUSS           || wep_id == WEP_HLEGON
     || wep_id == WEP_DISPLACER       || wep_id == WEP_SHOCKRIFLE
     || wep_id == WEP_HORNETGUN       || wep_id == WEP_THTESLA
     || wep_id == WEP_MINIGUN)  return TRUE;

    return FALSE;
};

// Canonicalize a weapon token so console-friendly aliases like
// "desert eagle", "hl_shotgun", ".357", and "AK47" all collapse to a
// simple comparable key.
string(string raw) Weapon_NameKey =
{
    return WeaponManifest_NameKey(raw);
};

// Accept either a numeric weapon id or a short weapon alias. Unknown
// strings fall back to the caller-provided value so existing numeric
// cvar behavior remains intact.
float(string raw, float fallback) Weapon_IdFromStringOrDefault =
{
    return WeaponManifest_IdFromStringOrDefault(raw, fallback);
};

// Walk a comma-separated weapon-id list (e.g. "33,34" or "hegrenade,flashbang")
// and return the first valid weapon id, or `fallback` if the list is empty
// or contains only unknown tokens.  Whitespace inside tokens is allowed.
// Single-id strings ("33") still parse since tokenizebyseparator returns
// one token in that case.
float(string list, float fallback) Weapon_FirstIdFromList =
{
    if (list == "")
        return fallback;
    float n = tokenizebyseparator(list, ",");
    float i;
    for (i = 0; i < n; i++)
    {
        float id = Weapon_IdFromStringOrDefault(argv(i), WEP_NONE);
        if (id != WEP_NONE)
            return id;
    }
    return fallback;
};

// Iterate a comma-separated weapon-id list, calling `action(id)` once per
// valid weapon id (skipping unknowns).  Order preserved.  Caller passes a
// statically-known function pointer so QC's call indirection is one less
// hop than walking + dispatching by id at the call site.
//
// Usage: tokenize the cvar once, walk the tokens, give ammo per id.  See
// W_GiveStartingAmmo's utility post-pass.
float(string list) Weapon_TokenizeIdList =
{
    if (list == "")
        return 0;
    return tokenizebyseparator(list, ",");
};

// Short display name for a weapon ID — used by the kill feed and (potentially)
// future UI.  Matches the labels in menu/m_createserver.qc loadout arrays.
string(float wep_id) Weapon_DisplayName =
{
    return WeaponManifest_DisplayName(wep_id);
};

// Per-weapon walk/run-speed multiplier applied to mv_maxspeed and
// mv_shiftspeed in PM_PlayerMoveStep.  Heavier weapons feel slower in
// both run and shift-walk modes.  1.0 = full default speed (melee);
// 0.926 ≈ 250 qu/s when sv_maxspeed is the mod default of 270.
// Predicted automatically — both SSQC and CSQC read self.weapon.
float(float wep_id) Weapon_SpeedFactor =
{
    return WeaponManifest_SpeedFactor(wep_id);
};

// Definition moved below — Weapon_SpeedFactor_Smooth references .weapon
// and .pm_weapon_* fields that are declared further down in the file.
// See the function body after the field block.

// --- Bullet impact material codes (sent in CSQC_EVENT_IMPACT) ---
// Used by CSQC to pick the right particle effect per surface.
// Some materials allow decals on static BSP, while METAL_NODECAL is reserved
// for physics bodies that should spark but never receive a bullet hole.
const float IMPACT_MAT_DEFAULT      = 0;   // static wall/concrete (orange dust + decal)
const float IMPACT_MAT_FLESH        = 1;   // routine flesh hit (cloud only, no sparks)
const float IMPACT_MAT_METAL        = 2;   // BREAKABLE_METAL/MACHINE/CIRCUIT (sparks)
const float IMPACT_MAT_GLASS        = 3;   // BREAKABLE_GLASS (clear shards)
const float IMPACT_MAT_WOOD         = 4;   // BREAKABLE_WOOD (brown debris)
const float IMPACT_MAT_FLESH_LETHAL = 5;   // killing blow OR headshot (cloud + spark splash)
const float IMPACT_MAT_METAL_NODECAL = 6;  // physics metal hit (sparks, no decal)

// --- Shell/mag type IDs (sent in multicast events) ---
const float SHELL_9MM       = 0;
const float SHELL_RED       = 1;
const float SHELL_RIFLE     = 2;
const float SHELL_RIFLE_BIG = 3;
const float SHELL_SHOTGUN1  = 4;   // shotgunshell1.mdl (CS M3)
const float SHELL_SHOTGUN2  = 5;   // shotgunshell2.mdl (HL shotgun, flak shotgun)
const float MAG_PISTOL      = 6;
const float MAG_PISTOL_HL   = 7;
const float MAG_RIFLE       = 8;

// --- Brush entity types (sent via brush sync) ---
const float BRUSH_TYPE_STATIC = 0;
const float BRUSH_TYPE_DOOR   = 1;
const float BRUSH_TYPE_BUTTON = 2;
const float BRUSH_TYPE_CONVEYOR = 4;   // ships movedir + speed in brushsync wire
const float BRUSH_TYPE_TRAIN    = 5;   // func_train / func_tracktrain — CSQC predicts platform carry + geometry push via PM_CheckMovingPushers train branch
const float BRUSH_TYPE_CAMTARGET = 7;  // trigger_cameratarget — clickable during a trigger_camera
                                       // cutscene with the Mouse Cursor flag.  CSQC needs it as a real
                                       // brush entity so the cursor ray can traceline against it.
                                       // (6 is the last of the original run; 3 is a retired id, left
                                       // unused deliberately rather than recycled.)
const float BRUSH_TYPE_VEHICLE  = 6;   // func_vehicle — player-driven free-steer brush; rides the TRAIN carry branch, ships avelocity_z (yaw rate) so live steering extrapolates via the avelocity path (not snap-differentiation)

// TRUE for every brush class that runs the func_breakable damage / break
// pipeline.  func_pushable (sv_func_pushable.qc) reuses that pipeline whole —
// GoldSrc literally derives CPushable from CBreakable — but keeps its own
// classname so it can be told apart for physics and round-reset.  Every gate
// that used to compare against the "func_breakable" string literal asks this
// instead, otherwise a breakable crate would be immune to explosions, immune to
// a one-hit crowbar, and report no material for impact FX.
// Defined here (sh_weapons.qc, early in BOTH progs) so it is in scope for the
// weapon files, sv_weapons.qc and sv_brushsync.qc alike.
float(entity e) Brush_IsBreakableClass =
{
    return (e.classname == "func_breakable" || e.classname == "func_pushable");
};

// --- Door/button state (shared between server and client) ---
const float MOVER_STATE_BOTTOM = 0;
const float MOVER_STATE_UP     = 1;
const float MOVER_STATE_TOP    = 2;
const float MOVER_STATE_DOWN   = 3;

// --- Player attack animation hints ---
const float PLAYER_ATTACKANIM_SHOT  = 1;
const float PLAYER_ATTACKANIM_MELEE = 2;

// --- Player weapon slot fields ---
//
// slot_primary / slot_secondary are THE CURSOR, not the inventory: "the primary I
// currently have selected".  That is the same relationship slot_utility has always
// had to the .ammo_* counters — it names which utility is bound, while ownership
// lives elsewhere.  Reading them as "the one primary I own" is only correct while
// mp_maxprimary is 1.
//
// Keeping the names is deliberate.  There are ~210 references to these two fields
// across 20 files and under cursor semantics essentially all of them stay right
// verbatim: `if (self.slot_primary)` still means "do I have a primary",
// `W_SelectWeapon(self.slot_primary)` still means "select my primary".  Only the
// handful that mean OWNERSHIP or OCCUPANCY had to change, and those now go through
// W_CarryHas / W_CarryCount below.
.float slot_primary;
.float slot_secondary;
.float slot_melee;
.float slot_utility;

// --- Multi-carry inventory (mp_maxprimary / mp_maxsecondary) ----------------
//
// Packed, 0-terminated, no interior gaps.  There is deliberately NO count field:
// a stored count is a second source of truth and therefore a desync source, and
// scanning four floats costs nothing.
//
// Field arrays are a shipping construct in this tree — .float proj_consumed_ids[32]
// below is read AND written with a variable index — so this needs no new machinery.
//
// Carried-but-not-selected weapons keep their magazine in their OWN legacy
// .mag_x/.ammo_x fields, which nothing else touches while they are holstered.
// That is why this change adds no ammo storage and no ammo wire bytes: the
// canonical slot_primary_mag/_ammo/_aux registers below stay exactly what they
// are, the register set for whatever the cursor points at.  See
// W_SlotAmmo_PointAt in sh_weapon_slotammo.qc for the one line that re-points
// them on a cursor move.
const float CARRY_MAX = 4;          // == the mp_max* upper bound
.float carry_primary[4];
.float carry_secondary[4];

// All of these take an explicit entity rather than using `self`, so SSQC and CSQC
// prediction share one body and cannot drift.  Slot membership always comes from
// WeaponManifest_Slot() — never a hand-written table.  (The utility ring in
// sh_wpn_snowball.qc is a hand-written table, and its own header records what that
// cost: a weapon missing from it could be GIVEN but never selected.)

float(entity p, float slot, float i) W_CarryAt =
{
    if (i < 0 || i >= CARRY_MAX)
        return WEP_NONE;
    if (slot == SLOT_PRIMARY)   return p.carry_primary[i];
    if (slot == SLOT_SECONDARY) return p.carry_secondary[i];
    return WEP_NONE;
};

void(entity p, float slot, float i, float wep) W_CarrySet =
{
    if (i < 0 || i >= CARRY_MAX)
        return;
    if (slot == SLOT_PRIMARY)        p.carry_primary[i]   = wep;
    else if (slot == SLOT_SECONDARY) p.carry_secondary[i] = wep;
};

// Packed and 0-terminated, so the first empty entry IS the count.
float(entity p, float slot) W_CarryCount =
{
    float i;
    for (i = 0; i < CARRY_MAX; i = i + 1)
        if (W_CarryAt(p, slot, i) == WEP_NONE)
            return i;
    return CARRY_MAX;
};

float(entity p, float slot, float wep) W_CarryIndexOf =
{
    if (wep == WEP_NONE)
        return -1;
    float i;
    for (i = 0; i < CARRY_MAX; i = i + 1)
    {
        float w = W_CarryAt(p, slot, i);
        if (w == WEP_NONE)  return -1;      // packed: nothing beyond here
        if (w == wep)       return i;
    }
    return -1;
};

// Slot-agnostic OWNERSHIP.  This is the function every widened gate calls, and it
// is why those gates no longer need to know which slot a weapon lives in.
float(entity p, float wep) W_CarryHas =
{
    if (wep == WEP_NONE)
        return FALSE;
    if (p.slot_melee == wep)
        return TRUE;
    if (W_CarryIndexOf(p, SLOT_PRIMARY, wep) >= 0)
        return TRUE;
    if (W_CarryIndexOf(p, SLOT_SECONDARY, wep) >= 0)
        return TRUE;
    return FALSE;
};

// How many of this slot may be carried.  The ONLY reader of the limit cvars.
// CSQC must go through serverinfo: cvar_audit.py flags a CVAR_SIDE_SV cvar read
// by CSQC via cvar() as UNDER, and replication is the accepted fix in this tree.
float(float slot) W_CarryLimit =
{
    string k;
    if (slot == SLOT_PRIMARY)        k = "mp_maxprimary";
    else if (slot == SLOT_SECONDARY) k = "mp_maxsecondary";
    else                             return 1;
#ifdef CSQC
    float v = serverkeyfloat(k, 2);
#else
    float v = cvar(k);
#endif
    if (v < 1)
        v = 1;                      // unset reads 0; never let that mean "none"
    return bound(1, v, CARRY_MAX);
};

// FALSE if it is already held or the slot is full.  Does NOT enforce the limit
// itself — callers decide whether a full slot means "refuse" (walk-over pickup)
// or "drop one first" (give / +use swap).
float(entity p, float slot, float wep) W_CarryAdd =
{
    if (wep == WEP_NONE)
        return FALSE;
    if (W_CarryIndexOf(p, slot, wep) >= 0)
        return FALSE;
    float n = W_CarryCount(p, slot);
    if (n >= CARRY_MAX)
        return FALSE;
    W_CarrySet(p, slot, n, wep);
    return TRUE;
};

// Compacts, so the array keeps its no-interior-gaps invariant.
void(entity p, float slot, float wep) W_CarryRemove =
{
    float at = W_CarryIndexOf(p, slot, wep);
    if (at < 0)
        return;
    float i;
    for (i = at; i < CARRY_MAX - 1; i = i + 1)
        W_CarrySet(p, slot, i, W_CarryAt(p, slot, i + 1));
    W_CarrySet(p, slot, CARRY_MAX - 1, WEP_NONE);
};

void(entity p) W_CarryClearAll =
{
    float i;
    for (i = 0; i < CARRY_MAX; i = i + 1)
    {
        p.carry_primary[i]   = WEP_NONE;
        p.carry_secondary[i] = WEP_NONE;
    }
};

// Rebuild the carry lists from the cursors, i.e. collapse to the historical
// one-weapon-per-slot state.  For the spawn / loadout paths, which assign the
// cursors wholesale and have no notion of a second gun.
//
// NOT for the round-survivor path: that one carries inventory over, and calling
// this there would silently confiscate everything but the selected weapon.
void(entity p) W_CarryResyncFromCursors =
{
    W_CarryClearAll(p);
    if (p.slot_primary != WEP_NONE)
        W_CarryAdd(p, SLOT_PRIMARY, p.slot_primary);
    if (p.slot_secondary != WEP_NONE)
        W_CarryAdd(p, SLOT_SECONDARY, p.slot_secondary);
};

// Step to the next carried weapon in `slot`.  `wrap` matches the split the
// utility ring already draws (sh_wpn_snowball.qc:295 vs :336): the slot KEY wraps
// so repeated presses cycle forever, the MOUSEWHEEL does not, so it can walk off
// the end and escape into the next slot.
float(entity p, float slot, float from, float dir, float wrap) W_CarryCycle =
{
    float n = W_CarryCount(p, slot);
    if (n <= 0)
        return WEP_NONE;
    float at = W_CarryIndexOf(p, slot, from);
    if (at < 0)
        return W_CarryAt(p, slot, 0);       // not in this slot - enter at the near end

    float nx = at + dir;
    if (!wrap)
    {
        if (nx < 0 || nx >= n)
            return WEP_NONE;                // walked off - caller leaves the slot
        return W_CarryAt(p, slot, nx);
    }
    // Wrapping.  n is always <= CARRY_MAX so this cannot spin.
    while (nx < 0)   nx = nx + n;
    while (nx >= n)  nx = nx - n;
    return W_CarryAt(p, slot, nx);
};

// What a press of this slot's key should select.
//
// DELIBERATELY DOES NOT READ THE LIMIT.  Cycling therefore depends only on
// replicated inventory state, so a stale mp_max* serverinfo can mispredict a
// pickup but can never desync which weapon a keypress selects.
float(entity p, float slot) W_SlotPressTarget =
{
    if (W_CarryCount(p, slot) <= 0)
        return WEP_NONE;
    // Already holding something from this slot: advance.
    if (W_CarryIndexOf(p, slot, p.weapon) >= 0)
        return W_CarryCycle(p, slot, p.weapon, 1, TRUE);
    // Otherwise re-enter at the cursor if it is still valid, else the first held.
    float cursor = (slot == SLOT_PRIMARY) ? p.slot_primary : p.slot_secondary;
    if (W_CarryIndexOf(p, slot, cursor) >= 0)
        return cursor;
    return W_CarryAt(p, slot, 0);
};

// Canonical ammo state for single-weapon inventory slots.  Legacy
// per-weapon mag/ammo fields are still used as active-weapon working
// registers by the existing weapon implementations; sh_weapon_slotammo.qc
// mirrors them to/from these slot fields.
.float slot_primary_mag;
.float slot_primary_ammo;
.float slot_primary_aux;
.float slot_secondary_mag;
.float slot_secondary_ammo;
.float slot_secondary_aux;

// Utility inventory fields live here because sv_weapons.qc manages the
// utility slot before the individual utility weapon files are compiled.
.float ammo_hlgrenade;
.float ammo_snowball;
// Same reason: sv_weapons.qc drives the utility slot at line 27 of
// sv_progs.src, long before shared/weapons/sh_wpn_hl*.qc at 57-60.
.float ammo_satchel;
.float ammo_tripmine;
.float ammo_snark;
// The penguin's OWN pool, not the snark's — sharing one would make a penguin
// pickup refill snarks and vice versa, and the maps that place both place them
// as separate items.  Declared up here rather than in sh_wpn_oppenguin.qc for
// the reason above: sh_wpn_snowball.qc's utility ring reads it and compiles
// FIRST (sv_progs.src line 79 against the penguin's 148), and QC forward-
// declares functions but not FIELDS.
.float ammo_penguin;
.float ammo_hornet;
// Opposing Force's four.  Declared up here with the rest for the same reason:
// sv_weapons.qc runs the slot machinery long before shared/weapons/*.qc.
.float ammo_shockrifle;
.float ammo_displacer;
.float ammo_jetfuel;
// The two new UTILITY pools, declared here for the same reason as their
// neighbours: sv_weapons.qc drives the utility slot long before
// shared/weapons/*.qc is compiled.
.float ammo_medkit;
.float ammo_soflam;
.float ammo_cshegrenade;
// Day of Defeat's two thrown grenades.  SLOT_UTILITY, so these are NOT carried
// by the slot bridge (W_SlotAmmo_UsesSlot is FALSE for utility) — their only
// route to the client is the prediction proxy's ammo section, which is why they
// were added there in the same change.  See PM_CSQC_PROXY_VERSION v28.
.float ammo_dodmills;
.float ammo_dodstick;
.float ammo_csflashbang;
.float ammo_cssmokegrenade;
.float ammo_cfc4;
.float snowball_has_slingshot;
.float snowball_use_slingshot;

.void() slot_primary_equip;
.void() slot_secondary_equip;
.void() slot_melee_equip;
.void() slot_utility_equip;

.void() slot_primary_drop;
.void() slot_secondary_drop;
.void() slot_melee_drop;
.void() slot_utility_drop;

// --- Current weapon state ---
.float attack_finished;       // debounce timestamp — shared for prediction
.float previous_weapon;
.float weaponstate;
.float wep_action_id;    // increments whenever a new weapon action starts

// Server-side replay-protection ring for SV_HandleProjhitClaim.
// Stores the last 32 action_ids consumed by a successful projhit so
// the same shot can't claim twice.  We no longer require the live
// projectile entity to exist when the claim arrives — server-side
// physics often consumes the projectile (fuse, world touch) before
// the client's hit claim lands, which caused the "shot doesn't
// register" bug.  Window-based validation against wep_action_id
// proves the player actually fired that shot recently; this ring
// prevents replays.
.float proj_consumed_ids[32];
.float proj_consumed_ring_idx;
.float wep_nextframe;    // server-side: absolute server time of next frame tick
.float wep_anim_start;   // absolute time when the current animation began

// How long the action just started is expected to last, in seconds.  Stamped by
// the standard fire / reload gates, which already receive the number; 0 means
// "this weapon uses a bespoke gate and did not say", and callers must fall back.
//
// Exists so the THIRD-PERSON body animation can be matched to the weapon rather
// than to a constant.  sv_weapons.qc used to hold the player's shoot pose for a
// flat 0.3 s and the reload pose for a flat 3.0 s no matter what the weapon was
// doing, which is wrong at both ends of the range: the SAW reloads in 1.5-2.4 s
// and several weapons take longer than 3.
.float wep_state_dur;

// --- The emplaced stance (mortar, MG34, MG42, .30 cal, BAR) ---------------
//
// Five Day of Defeat weapons are DEPLOYABLE: they carry a full `down_*` set in
// their view models — a deployed idle, a deployed shoot and the up_to_down /
// down_to_up transitions between them — for a gun put on its bipod (or, for the
// mortar, its baseplate).  DoD makes that a real movement stance: planted,
// rooted, and steadier for it.
//
// ONE FLAG AND ONE PROXY BYTE for all five rather than a field apiece.  The
// mortar arrived first and briefly had its own; generalising it was cheaper than
// four more copies of the same wire, the same reconcile and the same lock.
//
//   weapon_deployable  set in the weapon's Equip, exactly as weapon_ads_eligible
//                      is.  Off for everything else, so the lock below can never
//                      catch a weapon that has no stance to be in.
//   wep_deployed       0 = standing / hipfire, 1 = planted.  Rides the prediction
//                      proxy's weapon-state section (v29) and is reconciled
//                      UNCONDITIONALLY — a stance that could latch would leave
//                      the player unable to move with no way to lift it.
//
// The transition itself runs in WS_SPECIAL and the flag flips when the take ENDS,
// so during a plant or a lift the flag still names the stance being LEFT.  That
// is what lets a display function pick the right take without a second field, and
// it is why the lock below also covers WS_SPECIAL: otherwise a player could walk
// away in the middle of planting and arrive somewhere else already emplaced.
.float weapon_deployable;
.float wep_deployed;

// AND WHETHER THE STANCE HOLDS YOU DOWN.  Separate from weapon_deployable
// because it is NOT a property of being deployed — it is a property of the
// mortar, and only the mortar.
//
// All five deployables gate the plant on FL_DUCKING (a bipod goes on a sandbag,
// a baseplate goes on the ground), but only the mortar is a CREW-SERVED weapon
// that is worked from a kneel: the gunner has to reach the muzzle to drop a bomb
// in, and every emplaced take in v_mortar.mdl is posed for it.  A bipodded MG42
// is not — the gun rests on its own legs and the gunner behind it can be at any
// height the cover allows.
//
// Forcing PM_BTN_DUCK for every deployable is what produced "the machine guns
// weapon special, plus the mount, slowly lower you to crouched to perform the
// action, like the button acts like a crouch button as well?"  That reading was
// exactly right — the deploy button WAS also holding the duck button down, for
// as long as the gun was planted, on five weapons when one wanted it.
//
// The MOVEMENT lock (SH_DeployLocksPlayer) is unchanged and still covers all
// five: an MG gunner who stands up while planted stays rooted to the spot, which
// is the part that matters. Only the posture is given back.
.float weapon_deploy_crouched;

// THE RISING-EDGE LATCH FOR THE STANCE TOGGLE.
//
// +attack2 on a deployable weapon is a TOGGLE, and both dispatchers poll it while
// HELD rather than on a press: sv_weapons.qc calls .altfire every frame the button
// is down and time >= attack_finished, and each weapon's CSQC predictor tests
// `input_buttons & 4` the same way.  SH_..TryStance sets attack_finished to the end
// of the transition take, so the frame AFTER the take completes has weaponstate
// back at WS_IDLE and attack_finished already passed — and a still-held button
// immediately re-enters the opposite transition.  Hold +attack2 on a mortar for
// more than 1.233 s and it plants and instantly unplants, cycling for as long as
// the key is down.  A tap hides it, which is why it survived alongside the louder
// wire bug above.
//
// The tactical shield already had this exact problem and already has the answer
// (sv_weapons.qc, `shield_alt_held`: "RISING EDGE, not while held"), and so does
// the FAMAS selector (.famas_alt_held).  This is the same latch, shared by the
// five deployables.
//
// NOT on the prediction proxy, deliberately, and for the reason .famas_alt_held
// gives: both sides derive it every frame from the SAME button bit they both
// already have, so it re-converges on its own and a stale copy cannot outlive one
// command.
.float wep_stance_alt_held;

// TRUE only on the frame the button goes down.  Call with the live button state
// every frame from BOTH sides — the clearing half matters as much as the gate.
float(float held) SH_StanceAltEdge =
{
    if (!held)
    {
        self.wep_stance_alt_held = 0;
        return FALSE;
    }
    if (self.wep_stance_alt_held)
        return FALSE;
    self.wep_stance_alt_held = 1;
    return TRUE;
};

// Weapon-special (impulse 7) is an EVENT, not a held button, so it has no
// press/release pair for the latch above to ride.  Every deployable's TryStance
// opens with SH_StanceAltEdge(TRUE), which would refuse the impulse outright any
// time the latch happened to be set — and there is nothing on the impulse path to
// clear it, because only .altrelease (SSQC) and the button-up arm of the CSQC
// predictor do that, and both need +attack2 to actually be bound and released.
//
// Call this immediately before the TryStance on an impulse path.  It makes the
// edge test pass exactly once per impulse, and the normal button-up clear on the
// following frame re-arms +attack2 as usual, so the two entry points cannot
// interfere with each other.
void() SH_StanceAltArmForImpulse =
{
    self.wep_stance_alt_held = 0;
};

// The DoD binoculars' carry count — 1 while carried, 0 when not.  Declared HERE
// rather than in sh_wpn_dodbinocs.qc because sh_wpn_snowball.qc's utility tables
// read it and compile 134 lines earlier, and QC cannot forward-declare a field.
// See that weapon's header for why it needs a count at all when it has no rounds:
// the slot-based ownership test it used to carry was circular.
.float ammo_dodbinocs;

// THE ONE PREDICATE.  Everything that has to know "is this player rooted to a
// bipod / baseplate right now" asks this, on both VMs: the speed factor below, the
// four input-zeroing sites in cl_player.qc / sv_player.qc, and the horizontal
// velocity clamp in PM_PlayerMoveStep.
//
// Takes an entity because the two sides pass different ones — SSQC passes self,
// CSQC passes predicted_player — and every field it reads exists on both.  It
// lives here rather than beside SH_RoundFreezeLocksPlayer in sh_pmove.qc because
// sh_weapons.qc compiles FIRST on both sides (sv_progs.src and cl_progs.src agree),
// so putting it here lets sh_pmove.qc call it without a forward declaration while
// the speed factor below still sees it.
//
// WS_SPECIAL is included so a player cannot walk away during the plant and arrive
// somewhere else already emplaced.
float(entity pl) SH_DeployLocksPlayer =
{
    if (pl == world)                  return FALSE;
    if (!pl.weapon_deployable)        return FALSE;
    if (pl.wep_deployed)              return TRUE;
    if (pl.weaponstate == WS_SPECIAL) return TRUE;
    return FALSE;
};

// The narrower predicate: is this player rooted AND worked from a kneel?  Only
// PM_PlayerMoveStep's held-crouch asks this — see weapon_deploy_crouched above
// for why it is not the same question as SH_DeployLocksPlayer.
float(entity pl) SH_DeployHoldsCrouch =
{
    if (!pl.weapon_deploy_crouched) return FALSE;
    return SH_DeployLocksPlayer(pl);
};

// Multiplied into Weapon_SpeedFactor_Smooth beside the tactical shield's.  A hard
// 0, not a penalty: a planted gun is not carried at all.
//
// KEPT even though the input-zeroing sites now cover the same ground, and
// deliberately: the zeroing is applied to a usercmd, so it is only as trustworthy
// as the client that built it (the C4 plant freeze this pattern is copied from is
// client-side ONLY, and a client that skips it walks freely through the whole
// plant).  This runs inside the server's own pmove and is the authoritative half.
// Expressed through the shared predicate so the two can never drift apart.
float() SH_DeploySpeedFactor =
{
    return SH_DeployLocksPlayer(self) ? 0.0 : 1.0;
};

// Speed-factor transition state (used by Weapon_SpeedFactor_Smooth in
// PM_ReadMovevars).  On weapon switch, both client and server reset
// pm_weapon_blend_progress to 0 and capture the CURRENT effective factor
// into pm_weapon_prev_factor.  PM_ReadMovevars advances progress by
// input_timelength / sv_wepswap_speed_transition per pmove tick.  The
// smooth helper interpolates from prev → new based on progress.
//
// Input-tick-driven (NOT wall-clock-driven): both sides advance progress
// using the same input_timelength per buffered command, so client live,
// client replay, and server pmove all reach the same progress at the
// same input frame.  Mirrors shift-walk's input-bit determinism — see
// the rewrite history in plans/radiant-popping-hollerith.md for context.
//
// Serialized via the prediction proxy (PM_SF_WEAPON_STATE section) so a
// reconcile mid-blend doesn't lose in-flight transition state.
.float pm_weapon_blend_progress;   // 0 = at prev_factor, 1 = at new_factor
.float pm_weapon_prev_factor;
.float zoomstage;        // scope zoom level: 0=unscoped, 1=zoom1, 2=zoom2
                         // sent through proxy as elapsed time; used by CSQC to
                         // compute the display frame via cltime - wep_anim_start

// Returns the player's CURRENT effective speed factor, smoothing the
// transition from the prior weapon's factor (pm_weapon_prev_factor) to
// the new weapon's factor based on pm_weapon_blend_progress (0..1).
// PM_ReadMovevars advances progress per pmove tick.
//
// Input-tick-driven so both client live, client replay, and server pmove
// reach the same progress at the same input frame — pmove output stays
// deterministic regardless of ping.
//
// The "prev factor" snapshot at switch time is intentionally the CURRENT
// effective factor (which may itself be mid-transition from a previous
// switch).  That makes rapid back-to-back switches blend smoothly
// instead of snapping back to an old reference point each time.
//
// Defined here, not earlier with Weapon_SpeedFactor, because it needs
// .pm_weapon_* and .weapon (declared above) to be in scope.
//
// Forward decl: the tactical shield's own movement penalty multiplies whatever
// the weapon asks for, and its file is compiled after this one because it needs
// the PANIM_* constants further down.
float() SH_ShieldSpeedFactor;
float() Weapon_SpeedFactor_Smooth =
{
    // mp_weaponweight 0 disables the per-weapon movement penalty entirely
    // (AWP / M249 / sniper rifles no longer slow you down). Server-pushed
    // via serverinfo so CSQC prediction reads the same value the SSQC
    // pmove uses — otherwise the predicted speed would diverge.
#ifdef CSQC
    float weight_on = serverkeyfloat("mp_weaponweight", 1);
#else
    float weight_on = cvar("mp_weaponweight");
#endif
    // The emplaced lock is NOT a weapon weight and is deliberately tested before
    // mp_weaponweight: a server that has turned the weight system off has not
    // thereby said a planted mortar or a bipodded MG can be carried around.
    if (SH_DeploySpeedFactor() <= 0)
        return 0.0;

    if (weight_on == 0)
        return 1.0;

    float new_factor = Weapon_SpeedFactor(self.weapon);
    float t = self.pm_weapon_blend_progress;

    if (t >= 1.0) return new_factor;
    if (t <= 0.0) return self.pm_weapon_prev_factor;

    // Smoothstep — zero slope at both endpoints so the factor leaves
    // prev_factor and reaches new_factor without slope discontinuities.
    // Rapid back-to-back switches blend continuously because each switch
    // captures prev_factor at the current effective value.
    float smooth_t = t * t * (3 - 2 * t);
    return (self.pm_weapon_prev_factor
         + (new_factor - self.pm_weapon_prev_factor) * smooth_t)
         * SH_ShieldSpeedFactor();
};

// --- Active weapon function pointers (set by equip, valid for current weapon) ---
.void() fire;
.void() reload;
.void() wepframe;
.void() altfire;              // secondary/alt-fire action
.void() altrelease;           // called when alt-fire button released
.void() shoot;                // raw attack trace (called by frame at the hit frame)
.void() special;              // weapon-specific action (throw, inspect, etc.)

// --- CSQC prediction function pointers (set by per-weapon CSQC equip) ---
.void() csqc_predict_cmd;             // per-frame weapon logic (fire, sounds, etc.)
.void() csqc_predict_reload;          // reload initiation
.void() csqc_drop_clear;              // zero this weapon's ammo fields on drop
.float(float elapsed) csqc_display_frame;  // returns viewmodel animation frame

// --- Weapon data fields (set during equip, used by HUD/viewmodel/drop) ---
.string weapon_viewmodel;              // view model path
.string weapon_worldmodel;             // world model path
.string weapon_deploy_sound;           // deploy sound (empty string = none)
.float  weapon_uses_sequences;         // TRUE for GoldSrc-format MDLs (sequence-driven, not frame-driven)
.float  weapon_viewmodel_flip;         // TRUE to mirror the viewmodel horizontally (left-handed source models). Engine-side: RF_XFLIP flips projection X and inverts cull winding.
// Muzzle tag — set in the CSQC equip function for weapons whose
// viewmodel has a usable muzzleflash bone (e.g. HL studio MDLs with a
// $attachment).  Empty `weapon_muzzle_bone` = no tag → the sway pivot
// code in cl_viewfx.qc falls back to translation parallax.  Offset is
// in HL studio coords (+X forward, +Y left, +Z up) just like the
// existing muzzle-flash plumbing, so the same constants used for the
// flash also describe the pivot point.
.string weapon_muzzle_bone;
.vector weapon_muzzle_offset;

// --- ADS / scope classification (set per-weapon in Equip; read by the
//     shared ADS + CoD-scope logic in sh_weapon_logic.qc / sh_pmove.qc /
//     cl_viewfx.qc / cl_codscope.qc instead of hardcoded WEP_* lists). ---
.float  weapon_ads_eligible;   // 1 => pose-ADS on +attack2 without codscope
.string weapon_ads_prefix;     // cl_ads cvar prefix ("" => shared "cl_ads")
.float  weapon_scope_class;    // SCOPE_CLASS_*
const float SCOPE_CLASS_NONE           = 0;
const float SCOPE_CLASS_SNIPER_BOLT    = 1;  // post-fire scope-out (scout/awp/awm/elite)
const float SCOPE_CLASS_SNIPER_SEMI    = 2;  // stay scoped through fire (psg1/svd/msg90)
const float SCOPE_CLASS_RIFLE_LOWPOWER = 3;  // 1.2x FOV, full-auto, stay scoped (aug/sg552/sl8)

// Set a weapon's ADS/scope profile in one call from its Equip (both the
// SSQC W_*Equip and the CSQC CSQC_*Equip).  Compiled both sides.
void(float eligible, string prefix, float scope_class) W_SetADSProfile =
{
    self.weapon_ads_eligible = eligible;
    self.weapon_ads_prefix   = prefix;
    self.weapon_scope_class  = scope_class;
};

// --- World weapon entity fields ---
.float weapon_slot;           // SLOT_* this pickup belongs to
.float weapon_slot_group;     // WSG_* broader category
.string weapon_name;          // display name
.float  weapon_draw_start_frame;
.float  weapon_player_attack_anim;  // PLAYER_ATTACKANIM_*
.void() weap_draw;            // equip function: sets fire/reload/wepframe/weaponmodel on player
.void() weap_drop_func;       // drop function: copies ammo from player to weapon_drop_target, sets up world ent
.void(entity) pickupcopy;     // copies ammo FROM this world ent TO receiver player
.void() equip;                // equip function pointer (alternative to weap_draw)
// A `.void() drop;` used to sit here.  It had ZERO readers or writers anywhere in
// the tree — weap_drop_func above is the live one — but declaring it cost real
// map behaviour: a declared field name owns that spelling in the BSP keyvalue
// namespace, so the engine bound it and ED_ParseUnknownEpair never saw it, which
// swallowed the "drop" multi_manager slot on hl_c05_a2 and uplink (both "5.7").
// A function field cannot be recovered by readback (the mapper's delay is not a
// function name), so the dead declaration had to go rather than be worked around.
// Do not re-add it under this name; see sv_multi_manager.qc MM_CollisionScan.
.void() spawnitem;            // world spawn function for this weapon type

// Generic dropped-ammo payload.  SendEntity and CSQC pickup prediction read
// this directly; individual weapon drop funcs still populate their legacy
// fields for compatibility.
.float weapon_drop_mag;
.float weapon_drop_ammo;
.float weapon_drop_aux;

// --- Player animation family constants ---
const float PANIM_NONE     = 0;
const float PANIM_ONEHAND  = 1;
const float PANIM_CARBINE  = 2;
const float PANIM_RIFLE    = 3;
const float PANIM_MP5      = 4;
const float PANIM_SHOTGUN  = 5;
const float PANIM_PARA     = 6;
const float PANIM_KNIFE    = 7;
const float PANIM_GRENADE  = 8;
const float PANIM_AK47     = 9;

// --- Half-Life / Sven Co-op animation families ---
//
// 0-9 above are Counter-Strike's, and the player models address them by
// sequence INDEX through the CSANIM_* constants in sh_player_anims.qc.  The
// ones below are Sven's, and are addressed by NAME through frameforname(), so
// they cost nothing on a model that does not have them - SH_GetAimAnim falls
// back to the CS family named in SH_HLAnimFallback when the lookup misses.
//
// The names are Sven's own `ref_aim_<suffix>` / `crouch_aim_<suffix>` spelling,
// which is also what the sini model already used (shared/sh_player_sini.qc) -
// this generalises that one model's mechanism to every player model, now that
// the 11 CS-derived IQMs carry Sven's 168 extra sequences alongside their own.
const float PANIM_HL_CROWBAR = 10;
const float PANIM_HL_PYTHON  = 11;
const float PANIM_HL_GAUSS   = 12;
const float PANIM_HL_EGON    = 13;
const float PANIM_HL_RPG     = 14;
const float PANIM_HL_SAW     = 15;
const float PANIM_HL_SNIPER  = 16;
const float PANIM_HL_M16     = 17;
const float PANIM_HL_MINIGUN = 18;
const float PANIM_HL_BOW     = 19;
const float PANIM_HL_HIVE    = 20;
const float PANIM_HL_SQUEAK  = 21;
const float PANIM_HL_TRIP    = 22;
const float PANIM_HL_WRENCH  = 23;
const float PANIM_HL_UZIS    = 24;
const float PANIM_HL_GREN    = 25;
const float PANIM_HL_M203    = 26;

// Two more Counter-Strike families, wired late because the SEQUENCES were
// always there and nothing pointed at them.  Every CS-derived player model
// ships a full dual-pistol set (CSANIM_*_DUALPISTOLS, indices 22-29, including
// the alternating SHOOT2) and a full C4 set (indices 60-64), and until now no
// PANIM_ constant reached either: the akimbo guns rendered on the SINGLE
// pistol pose and the C4 on the grenade throw.
const float PANIM_DUALPISTOLS = 27;
const float PANIM_C4          = 28;
// The four tactical-shield sets (CS sequence indices 83..98).  These are an
// OVERRIDE rather than a manifest row: the shield is equipment, and which of the
// four applies depends on what is in the player's other hand and whether the
// shield is raised — see SH_ShieldAnimFamily in sh_wpn_csshield.qc.
const float PANIM_SHIELDGUN   = 29;
const float PANIM_SHIELDKNIFE = 30;
const float PANIM_SHIELDGREN  = 31;
const float PANIM_SHIELDED    = 32;

// Forward decl — sh_wpn_csshield.qc is compiled after this file (it needs the
// PANIM_* constants above), but W_GetPlayerAnimFamily below has to call into it.
float(float family) SH_ShieldAnimFamily;

// Maps weapon ID to animation family for player model sequences.
//
// Both call sites (sv_weapons.qc's PlayTop trigger and SH_PlayerAnim_Update)
// pass self.weapon with `self` as the player, which is what lets the shield
// override live here instead of being duplicated at each of them.
float(float wep) W_GetPlayerAnimFamily =
{
    return SH_ShieldAnimFamily(WeaponManifest_PlayerAnimFamily(wep));
};

// Maps weapon ID to the p_*.mdl path for third-person weapon attachment.
string(float wep) W_GetPModelPath =
{
    return WeaponManifest_PModelPath(wep);
};

// Linear damage falloff from close_dmg at point-blank to min_dmg at `range`.
// Shared between SSQC (authoritative shot) and CSQC (predicted shot), so both
// sides agree on the damage dealt — critical for breakable-break prediction.
float(float dist, float close_dmg, float min_dmg, float range) W_LinearDamageFalloff =
{
    float t;
    if (range <= 0)
        return close_dmg;
    t = bound(0, dist / range, 1);
    return close_dmg + (min_dmg - close_dmg) * t;
};

// --- Per-bone hitbox table (SHARED) ---
// The 20 oriented boxes that cl_debug_hitboxes / sv_debug_hitboxes draw AND
// that hit detection / hitgroup classification use.  Moved here (from
// cl_debuginfo.qc) so the SERVER can classify a hit point by which box it lands
// in (W_HitgroupClassify SSQC path) — accurate head/chest/limb instead of a
// Z-height guess.  Each box is axis-aligned in its bone's local frame
// (mins/maxs along the bone's forward/right/up from gettaginfo).
const float HITBOX_COUNT = 20;

string hitbox_bonename[] = {
    "Bip01 Pelvis",       // group 3 stomach
    "Bip01 L Thigh",      // group 6 left leg
    "Bip01 L Calf",       // group 6
    "Bip01 L Foot",       // group 6
    "Bip01 R Thigh",      // group 7 right leg
    "Bip01 R Calf",       // group 7
    "Bip01 R Foot",       // group 7
    "Bip01 Spine",        // group 3 stomach
    "Bip01 Spine1",       // group 2 chest
    "Bip01 Spine2",       // group 2
    "Bip01 Neck",         // group 2
    "Bip01 Head",         // group 1 head
    "Bip01 L Clavicle",   // group 4 left arm
    "Bip01 L UpperArm",   // group 4
    "Bip01 L Forearm",    // group 4
    "Bip01 L Hand",       // group 4
    "Bip01 R Clavicle",   // group 5 right arm
    "Bip01 R UpperArm",   // group 5
    "Bip01 R Forearm",    // group 5
    "Bip01 R Hand"        // group 5
};

float hitbox_group[] = {
    3, 6, 6, 6, 7, 7, 7, 3, 2, 2, 2, 1, 4, 4, 4, 4, 5, 5, 5, 5
};

vector hitbox_mins[] = {
    '-4.69 -4.44 -6.75',
    '2.66 -3.69 -3.09',
    '0.38 -3.97 -2.84',
    '0.85 -3.24 -2.64',
    '2.47 -3.69 -3.16',
    '0.31 -3.97 -2.84',
    '0.85 -3.24 -2.64',
    '-3.25 -5.5 -5.5',
    '-0.06 -5.53 -7.59',
    '-2.25 -6.81 -6.31',
    '-3.11 -1.5 -3',
    '-0.33 -4.5 -2.5',
    '0.94 -2.88 -4.13',
    '-2.16 -2.34 -2.56',
    '0.59 -1.81 -2.19',
    '-0.13 -1.9 -2.24',
    '1.38 -2.84 -3.56',
    '-1.88 -2.47 -2.16',
    '0.44 -1.97 -2.34',
    '-0.13 -1.9 -2.24'
};

vector hitbox_maxs[] = {
    '4 5.56 6.75',
    '18.16 4.88 3.31',
    '17.6 4 2.94',
    '5.73 8.53 3.17',
    '18.13 4.88 3.38',
    '17.6 3.94 2.97',
    '5.73 8.53 3.17',
    '4.83 5.5 5.5',
    '8 7 7.59',
    '6.5 5.09 6.31',
    '2.05 3.5 3',
    '8 4.5 2.5',
    '5.44 4.28 3.5',
    '11.56 3.41 2.38',
    '10.75 2.84 2.41',
    '4.86 2.08 2.37',
    '5.69 4.31 4.31',
    '11.81 3.28 2.81',
    '10.59 2.72 2.22',
    '4.86 2.08 2.37'
};

// nettest Patch 36 Part B: register the 20 boxes above on a player model so the engine
// traces them (native per-bone hit detection) instead of the mesh, and returns the struck
// box's hitgroup.  Called once per player model from precache_everything (sh_customdefs.qc)
// in BOTH the SSQC and CSQC progs (each side has its own model_t), so trust 0 (server trace)
// and trust 1 (client trace) both classify off the same boxes.  Boxes ride the Part A
// view-pitch bend automatically (Alias_GetBoneInformation), so they lean with the player.
// addmodelhitbox no-ops on non-alias models (e.g. the sini .mdl, which has native hitboxes)
// and on unknown bones, so passing every player model is safe.
void(string modelname) Hitbox_RegisterModel =
{
    if (modelname == "")
        return;
    if (!checkbuiltin(addmodelhitbox))
        return;	// unpatched engine → fall back to mesh + Z-height classify
    float modelindex = getmodelindex(modelname);
    if (!modelindex)
    {
        if (cvar("developer"))
            print("[hitbox] no modelindex for ", modelname, "\n");
        return;
    }
    float i, ok = 0;
    for (i = 0; i < HITBOX_COUNT; i = i + 1)
        ok = ok + addmodelhitbox(modelindex, hitbox_bonename[i], hitbox_group[i], hitbox_mins[i], hitbox_maxs[i]);
    // Under developer 1 this confirms registration: IQM players report 20/20; the sini .mdl
    // (HL native hitboxes) reports 0/20 (no-op, expected).  0/20 on an IQM model means the
    // head galiasinfo carries no bones — the boxes won't trace and detection stays Z-based.
    if (cvar("developer"))
        print(sprintf("[hitbox] %s idx=%g registered %g/%g boxes\n", modelname, modelindex, ok, HITBOX_COUNT));
};

// --- sv_hitbox_expand bookends ---
//
// Inflate every alive (CSQC: remote) player's bbox by sv_hitbox_expand
// for the duration of a hit trace, then restore.  Used by both the
// CSQC predicted trace and the SSQC authoritative trace so they agree
// on which limbs are reachable after lag rewind.  CSQC walks the
// player_visual_proxy chain; SSQC walks the live player chain (impl
// in server/sv_weapons.qc, declared here so callers compiled earlier
// in sv_progs.src — sh_weapon_logic.qc, sh_weapon_standard.qc — see
// the symbol without a per-file forward decl).
// ---- Prop Hunt: rotation-safe trace hit volume (SHARED) --------------------------
//
// A disguised hider wears the prop's MODEL and weapon traces are MOVE_HITMODEL, so hit
// detection is already per-triangle against the prop mesh — props register no
// addmodelhitbox boxes, so Mod_Trace falls through to the mesh loop and mesh accuracy
// comes for free.  What was broken is the volume that GATES that refinement: the engine
// treats the entity bbox as a hard cull volume — "The bounding box MUST be set to
// completely encompass the entity or those extra areas will be non-solid (leaving a hole
// for things to go through)" (MOVE_HITMODEL, sv_defs.qc).  The disguise hull is the
// possess box, which enclosed the prop UPRIGHT; rotate the prop and its mesh hangs
// outside that box, so every shot at the part hanging out passed straight through.
//
// The old code did not merely fail to grow the box — W_PlayersExpandHitboxes SKIPPED
// disguised players outright ("a tincan's hitbox is exactly the tincan").  That is the
// right instinct about the flat sv_hitbox_expand padding, which is a player-anatomy
// limb-reach allowance with no business on a crate, but it left the enclosing volume too
// small for any pose that is not dead upright.
//
// The fix mirrors W_PhysDropsExpandTraceBboxes (server/sv_weapons.qc), which already
// solves exactly this for dropped weapons: swap in a trace-only AABB that encloses the
// hull box AT THIS ORIENTATION, trace, restore inside the same QC frame.  Nothing else —
// pmove, ODE, pushers, the possess room test — ever observes the inflated size.
//
// SHARED because both sides must agree: sv_trust_clienthits defaults to 1, making the
// CLIENT the damage authority, and before this the two disagreed outright — the CSQC
// twin had no disguise check at all, so it applied to a disguised hider the very padding
// the server refused to.
//
// KNOWN GAP, unchanged here: the RENDER re-grounds a tilted prop so its rotated box
// rests on the floor (disguise predraw, cl_player.qc) while the server entity stays
// anchored at the player's feet, so the trace samples the mesh at the un-shifted pivot.
// Upright the two offsets cancel exactly, so the common case is correct; a heavily posed
// prop can still hitreg slightly off from where it is drawn.  Closing that is NOT a
// bookend fix: W_PlayersExpandHitboxes runs BEFORE Lagcomp_StartRewind, whose setorigin
// would overwrite any shift applied here.
void(entity e) PH_ExpandTraceBbox =
{
    // CarryRot_CenterOfs / CarryRot_RotatedHalf both go through CarryRot_Axes, which
    // CALLS MAKEVECTORS (sh_carryrot.qc says so in as many words).  Callers of the
    // expand bookend compute their trace direction from v_forward, so save and restore
    // the builtin globals rather than trusting every call site to have finished with them.
    vector sv_f = v_forward, sv_r = v_right, sv_u = v_up;

    // MESH box, not the collision hull.  The collision hull is deliberately capped at
    // player width (so a bulky disguise can still tuck into a corner), which makes it
    // narrower than the prop actually is — enclosing THAT would leave the crate's own
    // edges non-solid to gunfire even standing upright.
    vector hmn = PH_MeshMins(e);
    vector hmx = PH_MeshMaxs(e);
    // World-axis enclosure of the mesh box at the shown pose: the rotated centre offset
    // plus the 8-corner projected half-extent.  Same two helpers the disguise predraw
    // uses to re-ground the drawn prop, so the box tracks the drawn silhouette instead
    // of a guess — and it is exactly the projection the engine broadphase does when it
    // links a rotated physics box (server/world.c).
    vector cofs  = CarryRot_CenterOfs(e.angles, hmn, hmx);
    vector rhalf = CarryRot_RotatedHalf(e.angles, (hmx - hmn) * 0.5);

    e.ph_trace_mins_save = e.mins;
    e.ph_trace_maxs_save = e.maxs;
    e.ph_trace_inflated  = TRUE;
    setsize(e, cofs - rhalf, cofs + rhalf);

    v_forward = sv_f; v_right = sv_r; v_up = sv_u;
};

void(entity e) PH_RestoreTraceBbox =
{
    if (!e.ph_trace_inflated)
        return;
    setsize(e, e.ph_trace_mins_save, e.ph_trace_maxs_save);
    e.ph_trace_inflated = FALSE;
};

#ifdef SSQC
void() W_PlayersExpandHitboxes;
void() W_PlayersRestoreHitboxes;
#endif

#ifdef CSQC
void() W_PlayersExpandHitboxes =
{
    float expand = serverkeyfloat("sv_hitbox_expand");
    if (expand <= 0) expand = cvar("sv_hitbox_expand");
    // NOTE: do NOT early-out on expand<=0 — we still need to pose each proxy for the
    // trace below (Patch 36 fix), independent of bbox expansion.

    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (!p.vis_is_dead && p.solid == SOLID_BBOX)
        {
            // nettest Patch 36 fix: pose the proxy at its rendered framestate (stashed by
            // CSQC_PlayerVisual_Predraw) so the engine MOVE_HITMODEL trace hits the same
            // silhouette the shooter sees.  The trace runs at prediction time, BEFORE this
            // frame's predraw, so the live .frame/.basebone would otherwise be a frame stale
            // or degenerate (bad basebone -> the whole model collapses to one frame group).
            if (p.vis_trace_pose_valid)
            {
                p.frame          = p.vis_trace_frame;
                p.frame1time     = p.vis_trace_frame1time;
                p.frame2         = p.vis_trace_frame2;
                p.lerpfrac       = p.vis_trace_lerpfrac;
                p.baseframe      = p.vis_trace_baseframe;
                p.baseframe1time = p.vis_trace_baseframe1time;
                p.baseframe2     = p.vis_trace_baseframe2;
                p.baselerpfrac   = p.vis_trace_baselerpfrac;
                p.basebone       = p.vis_trace_basebone;
                p.subblendfrac   = p.vis_trace_subblendfrac;
                p.subblend2frac  = p.vis_trace_subblend2frac;
            }

            // Prop Hunt: a disguised hider gets a rotation-safe enclosure instead of the
            // flat limb padding — which is what the SERVER has always done for it, while
            // this side silently applied the padding anyway.  Under the default
            // sv_trust_clienthits 1 that made the CLIENT (the damage authority) disagree
            // with the server about the hit volume on every disguised target.
            if (p.ph_disguise_modelindex)
            {
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
        p = p.chain;
    }
};

void() W_PlayersRestoreHitboxes =
{
    float expand = serverkeyfloat("sv_hitbox_expand");
    if (expand <= 0) expand = cvar("sv_hitbox_expand");
    // NOTE: no early-out on expand<=0 — the disguised path below inflated regardless.

    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (p.ph_trace_inflated)
            PH_RestoreTraceBbox(p);
        else if (expand > 0 && !p.vis_is_dead && p.solid == SOLID_BBOX
                 && !p.ph_disguise_modelindex)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x += expand; mn_y += expand; mn_z += expand;
            mx_x -= expand; mx_y -= expand; mx_z -= expand;
            setsize(p, mn, mx);
        }
        p = p.chain;
    }
};
#endif
