//shared definitions
#pragma target fte_5768
#define printf(x, ...) print(sprintf(x, __VA_ARGS__))

const float FL_DUCKING = 8192;
const float PM_CSQC_PROXY_VERSION = 10;
const float PM_CSQC_PROXY_SEND_STATE = 1;
const string PM_CSQC_PROXY_CLASSNAME = "pm_csqc_proxy";

// CSQC entity type IDs (first byte sent by SendEntity)
const float CSQC_ENT_PUSH_TRIGGER = 2;
const float CSQC_ENT_SOLID_BRUSH    = 5;
const float CSQC_ENT_DROPPED_WEAPON = 7;

// trigger_push spawnflags
const float PUSH_ONCE     = 1;  // remove after first touch
const float PUSH_SILENT   = 2;  // no wind sound
const float PUSH_ADDITIVE = 4;  // add to velocity rather than replace
const float PUSH_TUNNEL   = 8;  // pull toward trigger centerline while pushing
const float PUSH_SOURCE   = 16; // boost along movedir up to speed, don't overwrite sideways

// Linked list fields for trigger chains
.entity push_next;
.entity tele_next;
.entity ladder_next;

// Generic movement/entity fields not declared in the engine-generated defs
.float speed;
.float waterlevel;   // synced from pm_waterlevel: 0=dry, 1=feet, 2=waist, 3=eyes
.float spread_penalty;       // decaying spread penalty from jump/landing (0 = none)
.float fire_spread_penalty;  // decaying spread penalty from sustained fire (0 = none)
.float fire_spread_pending;  // pending penalty to apply AFTER current shot resolves
.float altfire_finished;     // separate cooldown for alt-fire (doesn't block primary)

// --- Fire spread penalty tuning ---
const float FIRE_SPREAD_PENALTY_PER_SHOT = 3.0;  // penalty added per bullet fired
const float FIRE_SPREAD_PENALTY_DECAY    = 30.0;   // decay rate per second
const float FIRE_SPREAD_PENALTY_MAX      = 10;   // maximum penalty cap

// Trigger linked list heads (populated on server by spawn, on client by CSQC_Ent_Update)
entity push_trigger_list;
entity teleport_trigger_list;
entity ladder_trigger_list;

const float CSQC_ENT_LADDER_TRIGGER = 4;

// ---- trigger_push spawnflags already declared above ----

// trigger_teleport / info_teleport_destination
const float CSQC_ENT_TELEPORT_TRIGGER = 3;
const float TELEPORT_KEEPVEL          = 4;  // spawnflag: keep velocity through teleporter
const float TELEPORT_KEEPANGLE        = 8;  // spawnflag: keep current view angle (ignore dest angles)

// Per-teleport-trigger entity fields (cached destination, set at spawn time)
.vector tele_dest_origin;  // world-space destination position
.vector tele_dest_angles;  // destination view angles (zero = no snap)
.float  tele_resolved;     // TRUE once Teleport_FindDestination succeeded

// Per-player entity fields for teleport state
.float  pm_teleport_time;       // countdown guard: seconds remaining before player can re-teleport
.float  pm_ladder_detach_time;  // countdown guard: seconds remaining before player can re-grab a ladder
.float  pm_fuser2;              // CS 1.6 stamina: msec of landing fatigue remaining (0 = none)
.float  pm_step_time;           // seconds until next footstep sound fires


// Custom player stats — sent from server to client via clientstat()
const float STAT_CROSSHAIR_BASESPREAD = 32;
const float STAT_CROSSHAIR_MOVESPREAD = 33;
const float STAT_CROSSHAIR_FULLSPEED  = 34;
const float STAT_CROSSHAIR_GAPSCALE   = 35;
const float STAT_CROSSHAIR_DISABLED   = 36;

// Zoom/scope stats
const float STAT_ZOOMSTAGE            = 42;
const float ZOOM_FOV_STAGE1           = 24;
const float ZOOM_FOV_STAGE2           = 12;

// Team constants
const float TEAM_NONE = 0;
const float TEAM_BLUE = 1;
const float TEAM_RED  = 2;

// Team stats — sent from server to client via clientstat()
const float STAT_PLAYERTEAM       = 39;
const float STAT_TEAMMENU_REQUEST = 40;

// Round timer stat — seconds remaining in the current round
const float STAT_ROUNDTIMER       = 41;
const float STAT_MAPTIMELEFT      = 43;
const float STAT_ROUNDNUM         = 44;
const float STAT_MAXROUNDS        = 45;
const float STAT_ROUND_PHASE      = 46;
const float STAT_FREEZE_TIMELEFT  = 47;
const float STAT_GAMEMODE         = 48;
const float STAT_WINNING_TEAM     = 49;
const float STAT_DEATH_DELAY_LEFT = 50;
const float STAT_IS_DEAD          = 51;

// Gamemode constants
const float GAMEMODE_TDM         = 0;
const float GAMEMODE_ELIMINATION = 1;

// Round phase constants
const float ROUND_PHASE_NONE      = 0;
const float ROUND_PHASE_FREEZE    = 1;
const float ROUND_PHASE_ACTIVE    = 2;
const float ROUND_PHASE_ROUND_END = 3;
const float ROUND_PHASE_MAP_END   = 4;

void() precache_everything =
{
	precache_sound("sounds/null.wav");

	// Player Models / Sounds
	precache_model("models/testplayer.iqm");
	precache_sound("sounds/player/use.wav");
	precache_sound("sounds/player/step1.wav");
	precache_sound("sounds/player/step2.wav");
	precache_sound("sounds/player/step3.wav");
	precache_sound("sounds/player/step4.wav");
	precache_sound("sounds/player/ladder1.wav");
	precache_sound("sounds/player/ladder2.wav");
	precache_sound("sounds/player/ladder3.wav");
	precache_sound("sounds/player/ladder4.wav");
	precache_sound("sounds/player/waterstep1.wav");
	precache_sound("sounds/player/waterstep2.wav");
	precache_sound("sounds/player/waterstep3.wav");
	precache_sound("sounds/player/waterstep4.wav");
	precache_sound("sounds/player/waterstep5.wav");
	precache_sound("sounds/player/waterstep6.wav");
	precache_sound("sounds/player/waterstep7.wav");
	precache_sound("sounds/player/waterstep8.wav");
	precache_sound("sounds/player/waterstep9.wav");
	precache_sound("sounds/player/waterstep10.wav");
	precache_sound("sounds/player/fallpain1.wav");
	precache_sound("sounds/player/fallpain2.wav");

	// All guns
	precache_model("models/weapons/9mmcasing.mdl");
	precache_model("models/weapons/redcasing.mdl");
	precache_model("models/weapons/riflecasing.mdl");
	precache_model("models/weapons/riflecasingbig.mdl");
	precache_model("models/weapons/shotgunshell1.mdl");
	precache_model("models/weapons/shotgunshell2.mdl");
	precache_model("models/weapons/pistolmag.mdl");
	precache_model("models/weapons/pistolmaghl.mdl");
	precache_model("models/weapons/riflemag.mdl");
	precache_sound("sounds/weapons/casing1.wav");
	precache_sound("sounds/weapons/casing2.wav");
	precache_sound("sounds/weapons/casing3.wav");
	precache_sound("sounds/weapons/draw.wav");
	precache_sound("sounds/weapons/dryfire1.wav");
	precache_sound("sounds/weapons/pickup1.wav");
    precache_sound("sounds/weapons/explode1.wav");
    precache_sound("sounds/weapons/explode2.wav");
    precache_sound("sounds/weapons/explode3.wav");
	precache_sound("sounds/weapons/ric1.wav");
	precache_sound("sounds/weapons/ric2.wav");
	precache_sound("sounds/weapons/ric3.wav");
	precache_sound("sounds/weapons/ric4.wav");
	precache_sound("sounds/weapons/ric5.wav");

	// CS Glock
    precache_model("models/weapons/wpn_csglock/w_glock.mdl");
    precache_model("models/weapons/wpn_csglock/v_glock.mdl");
    precache_sound("sounds/weapons/wpn_csglock/reload.wav");
    precache_sound("sounds/weapons/wpn_csglock/fire.wav");
    precache_sound("sounds/weapons/wpn_csglock/fireburst.wav");
    precache_sound("sounds/weapons/wpn_csglock/sliderelease.wav");
    precache_sound("sounds/weapons/wpn_csglock/slideback.wav");

	// CS g3sg1
    precache_model("models/weapons/wpn_csg3sg1/w_g3sg1.mdl");
    precache_model("models/weapons/wpn_csg3sg1/v_g3sg1.mdl");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipin.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipout.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/fire.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/slide.wav");

	// HL Gauss
    precache_model("models/weapons/wpn_hlgauss/w_gauss.mdl");
    precache_model("models/weapons/wpn_hlgauss/v_gauss.mdl");
    precache_sound("sounds/weapons/wpn_hlgauss/charge.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro1.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro2.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro3.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/fire.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce1.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce2.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce3.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce4.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce5.wav");

	// HL Crossbow
    precache_model("models/weapons/wpn_hlcrossbow/w_crossbow.mdl");
    precache_model("models/weapons/wpn_hlcrossbow/v_crossbow.mdl");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fire.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fly.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/reload.wav");

	// HL 357
	precache_model("models/weapons/wpn_hl357/w_357.mdl");
    precache_model("models/weapons/wpn_hl357/v_357.mdl");
    precache_sound("sounds/weapons/wpn_hl357/cock.wav");
    precache_sound("sounds/weapons/wpn_hl357/reload.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire1.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire2.wav");

	// DOD 98k
    precache_model("models/weapons/wpn_dod98k/w_98k.mdl");
    precache_model("models/weapons/wpn_dod98k/v_98k.mdl");
    precache_sound("sounds/weapons/wpn_dod98k/fire.wav");
    precache_sound("sounds/weapons/wpn_dod98k/boltback.wav");
    precache_sound("sounds/weapons/wpn_dod98k/boltforward.wav");
    precache_sound("sounds/weapons/wpn_dod98k/reload.wav");
    precache_sound("sounds/weapons/wpn_dod98k/stab.wav");

	// CS Scout
    precache_model("models/weapons/wpn_csscout/w_scout.mdl");
    precache_model("models/weapons/wpn_csscout/v_scout.mdl");
    precache_sound("sounds/weapons/wpn_csscout/bolt.wav");
    precache_sound("sounds/weapons/wpn_csscout/clipin.wav");
    precache_sound("sounds/weapons/wpn_csscout/clipout.wav");
    precache_sound("sounds/weapons/wpn_csscout/fire.wav");

	// Grenade Launcher
    precache_model("models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl");
    precache_model("models/weapons/wpn_grenadelauncher/v_grenlauncher.mdl");
    precache_model("models/weapons/wpn_grenadelauncher/grenade.mdl");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire1.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire2.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire3.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/reload.wav");

	// CS M249
    precache_model("models/weapons/wpn_csm249/w_m249.mdl");
    precache_model("models/weapons/wpn_csm249/v_m249.mdl");
    precache_sound("sounds/weapons/wpn_csm249/boxin.wav");
    precache_sound("sounds/weapons/wpn_csm249/boxout.wav");
    precache_sound("sounds/weapons/wpn_csm249/chain.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverdown.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverup.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire1.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire2.wav");

	// HL Crowbar
    precache_model("models/weapons/wpn_hlcrowbar/w_crowbar.mdl");
    precache_model("models/weapons/wpn_hlcrowbar/v_crowbar.mdl");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall1.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall2.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/miss.wav");

	// HL Shotgun
    precache_model("models/weapons/wpn_hlshotgun/w_shotgun.mdl");
    precache_model("models/weapons/wpn_hlshotgun/v_shotgun.mdl");
    precache_sound("sounds/weapons/wpn_hlshotgun/fire1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/fire2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/cock.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload3.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell3.wav");

	// CS M3
    precache_model("models/weapons/wpn_csm3/w_m3.mdl");
    precache_model("models/weapons/wpn_csm3/v_m3.mdl");
    precache_sound("sounds/weapons/wpn_csm3/fire.wav");
    precache_sound("sounds/weapons/wpn_csm3/insertshell.wav");
    precache_sound("sounds/weapons/wpn_csm3/pump.wav");

	// CS MP5
    precache_model("models/weapons/wpn_csmp5/w_mp5.mdl");
    precache_model("models/weapons/wpn_csmp5/v_mp5.mdl");
    precache_sound("sounds/weapons/wpn_csmp5/clipin.wav");
    precache_sound("sounds/weapons/wpn_csmp5/clipout.wav");
    precache_sound("sounds/weapons/wpn_csmp5/slideback.wav");
    precache_sound("sounds/weapons/wpn_csmp5/fire1.wav");
    precache_sound("sounds/weapons/wpn_csmp5/fire2.wav");

	// Rebar
    precache_model("models/weapons/wpn_rebar/w_rebar.mdl");
    precache_model("models/weapons/wpn_rebar/v_rebar.mdl");
    precache_model("models/weapons/wpn_rebar/rebar.mdl");
    precache_sound("sounds/weapons/wpn_rebar/fire.wav");
    precache_sound("sounds/weapons/wpn_rebar/stick.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload1.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload2.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload3.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload4.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowclank.wav");

	// CS AWP
	precache_model("models/weapons/wpn_csawp/w_awp.mdl");
    precache_model("models/weapons/wpn_csawp/v_awp.mdl");
    precache_sound("sounds/weapons/wpn_csawp/clipin.wav");
    precache_sound("sounds/weapons/wpn_csawp/clipout.wav");
    precache_sound("sounds/weapons/wpn_csawp/deploy.wav");
    precache_sound("sounds/weapons/wpn_csawp/fire.wav");
    precache_sound("sounds/weapons/wpn_csawp/zoom.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltup.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltdown.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltpull.wav");

	// Wrench
	precache_model("models/weapons/wpn_wrench/v_wrench.mdl");
	precache_model("models/weapons/wpn_wrench/g_wrench.mdl");
    precache_sound("sounds/weapons/wpn_wrench/wrenchswing.wav");
    precache_sound("sounds/weapons/wpn_wrench/wrenchclank1.wav");
    precache_sound("sounds/weapons/wpn_wrench/wrenchclank2.wav");

	// CS Deagle
	precache_model("models/weapons/wpn_csdeagle/v_deagle.mdl");
	precache_model("models/weapons/wpn_csdeagle/w_deagle.mdl");
	precache_sound("sounds/weapons/wpn_csdeagle/deploy.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire1.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire2.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipin.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipout.wav");

	// CS Knife
	precache_model("models/weapons/wpn_csknife/v_knife.mdl");
	precache_model("models/weapons/wpn_csknife/w_knife.mdl");
	precache_sound("sounds/weapons/wpn_csknife/deploy.wav");
	precache_sound("sounds/weapons/wpn_csknife/hit1.wav");
	precache_sound("sounds/weapons/wpn_csknife/hit2.wav");
	precache_sound("sounds/weapons/wpn_csknife/hitwall.wav");
	precache_sound("sounds/weapons/wpn_csknife/slash.wav");
	precache_sound("sounds/weapons/wpn_csknife/stab.wav");

	// CS AK47
	precache_model("models/weapons/wpn_csak47/v_ak47.mdl");
	precache_model("models/weapons/wpn_csak47/w_ak47.mdl");
	precache_sound("sounds/weapons/wpn_csak47/fire1.wav");
	precache_sound("sounds/weapons/wpn_csak47/fire2.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipin.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipout.wav");
	precache_sound("sounds/weapons/wpn_csak47/boltpull.wav");

	// CS M4a1
	precache_model("models/weapons/wpn_csm4a1/v_m4a1.mdl");
	precache_model("models/weapons/wpn_csm4a1/v_m4a1_unsil.mdl");
	precache_model("models/weapons/wpn_csm4a1/w_m4a1.mdl");
	precache_sound("sounds/weapons/wpn_csm4a1/fire1.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/fire2.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/sfire1.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/clipin.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/clipout.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/deploy.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/boltpull.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/silenceroff.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/silenceron.wav");

	// FlakShotgun
	precache_model("models/weapons/wpn_flakshotgun/v_flakshotgun.mdl");
	precache_model("models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire1.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire2.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire3.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire4.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/reload.wav");

	// Pistol
	precache_model("models/weapons/wpn_pistol/v_pistol.mdl");
	precache_model("models/weapons/wpn_pistol/w_pistol.mdl");
	precache_sound("sounds/weapons/wpn_pistol/deadlockreload.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire1.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire2.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire3.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire4.wav");
	precache_sound("sounds/weapons/wpn_pistol/reload.wav");
	precache_sound("sounds/weapons/wpn_pistol/magdrop.wav");
};
