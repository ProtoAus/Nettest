
void() CSQC_Ent_Remove =
{
	if (self.classname == "player_visual_proxy")
	{
		entity wep = self.vis_weapon_ent;
		if (wep)
		{
			if (wep.skeletonindex)
			{
				skel_delete(wep.skeletonindex);
				wep.skeletonindex = 0;
			}
			setattachment(wep, world, "");
			remove(wep);
			self.vis_weapon_ent = world;
			self.vis_weapon_model = "";
		}

		if (self.skeletonindex)
		{
			skel_delete(self.skeletonindex);
			self.skeletonindex = 0;
			self.vis_skel_modelindex = 0;
		}
	}
	else if (self.classname == "player_weapon_attach" && self.skeletonindex)
	{
		skel_delete(self.skeletonindex);
		self.skeletonindex = 0;
	}

	if (self == csqc_authority_proxy)
	{
		csqc_authority_proxy = world;
		csqc_proxy_seen = FALSE;
		csqc_proxy_entnum = 0;
		csqc_baseline_valid = FALSE;
		csqc_prediction_valid = FALSE;
		csqc_present_valid = FALSE;
		csqc_dbg_seed_source = 0;
	}

	push_list_remove_csqc(self);
	tele_list_remove_csqc(self);
	ladder_list_remove_csqc(self);
	Conveyor_RemoveFromList(self);
	RotatingBrush_RemoveFromList(self);
	MovingBrush_RemoveFromList(self);

	// Planted-C4 light-walk count (cl_c4.qc) — decrement when a tagged C4 entity
	// is removed so CSQC_C4_DrawLights can early-out of its per-frame walk again.
	if (self.classname == "csqc_c4")
	{
		csqc_c4_count = csqc_c4_count - 1;
		if (csqc_c4_count < 0)
			csqc_c4_count = 0;
	}

	// Release the throwtrail slot when a tracked projectile is
	// removed (impact, explode, timeout).  Cheap no-op for non-
	// projectile entities.  Covers both classnames the throwtrail
	// iterator scans.
	if (self.classname == "csqc_projectile"
	    || self.classname == "csqc_fake_csgrenade")
		ThrowTrail_OnProjectileRemove(num_for_edict(self));

	// func_rain volume cleanup — drops the slot so the rain spawn
	// picker stops handing out drops inside a volume that no longer
	// exists.  Cheap no-op for entities that aren't func_rain.
	if (self.classname == "csqc_func_rain")
		CSQC_FuncRain_Remove();
	if (self.classname == "csqc_env_sound")
		CSQC_EnvSound_Remove();

	// Server removes a dropped_weapon entity when accepting a touch of a
	// player-dropped weapon (sv_weapons.qc remove() path).  Map-placed
	// weapons are hidden with setmodel("") instead, so they route through
	// CSQC_DroppedWeapon_Update's mdl=="" branch — but player-dropped
	// ones never fire that update.  Mirror the same confirm/catchup
	// semantics here so the debug trace isn't silent on the drop-and-
	// pickup path (where the predict was silently rejected because the
	// dropper's slot_primary is still stale on CSQC until the drop
	// server-acks).
	if (self.classname == "csqc_dropped_weapon" && !self.dropped_weapon_logged)
	{
		// Dedup: if the mdl=="" branch already printed/played for this
		// same entity, don't fire again on the remove.  Pickup sound
		// play lives in the CSQC_EVENT_WEAPON_PICKUP_SOUND handler;
		// see its comment for the predict-vs-catchup gate.
		if (self.dropped_weapon_predicted_taken)
		{
			if (cvar("sv_debug_pickups"))
				print(sprintf("^2[pickup-confirm]^7 weapon ^2%s^7 — server removed entity (player-drop accept)\n",
				              Weapon_DisplayName(self.dropped_weapon_id)));
		}
		else
		{
			if (cvar("sv_debug_pickups"))
				print(sprintf("^3[pickup-catchup]^7 weapon ^2%s^7 — server removed entity, no local prediction\n",
				              Weapon_DisplayName(self.dropped_weapon_id)));
		}
		self.dropped_weapon_logged = 1;
	}

	dropped_weapon_list_remove_csqc(self);

	remove(self);
};

void() CSQC_Shutdown =
{
	CSQC_ResetPredictionState();
};

void() CSQC_EnsureWorldSolid =
{
	world.solid = SOLID_BSP;
};

// --- Dynamic-light re-issue throttle ---
//
// Per-frame-mutable dlights (muzzle flash, bullet impact, explosion)
// call dynamiclight_add() from CSQC_Draw* on every render frame to
// drive a smooth decay fade.  At 1000 fps render this hammers the
// engine's lightmap-hack path (MarkLights + Surf_BuildLightMap, r_surf.c
// :2320) once per dlight per frame for nothing visually new.
//
// CSQC_DlightGate_Tick samples cl_dlight_update_hz once per frame and
// sets csqc_dlight_update_this_frame to 1 if enough wall-clock time
// has elapsed since the last "yes" frame.  Each dlight callsite
// checks that flag and skips its dynamiclight_add when 0 — the engine
// then sees no live dlight that frame and skips the rebuild.
//
// Skipped frames are visually dark for that dlight, which is why the
// default sits at 500 Hz: on any monitor up to ~240 Hz the dlight is
// present in at least every other displayed frame and persistence of
// vision masks the gap.  Lower caps (120-250) cost more visible
// flicker but cut work by 4-8x at 1000 fps render.
// (csqc_dlight_update_this_frame is declared in cl_customdefs.qc so
// the early-included weapon/impact files can see it.)
float csqc_dlight_last_update_stamp;

void() CSQC_DlightGate_Tick =
{
	float hz = cvar("cl_dlight_update_hz");
	if (hz <= 0)
	{
		csqc_dlight_update_this_frame = 1;
		return;
	}
	float interval = 1.0 / hz;
	if (cltime - csqc_dlight_last_update_stamp >= interval)
	{
		csqc_dlight_last_update_stamp = cltime;
		csqc_dlight_update_this_frame = 1;
	}
	else
		csqc_dlight_update_this_frame = 0;
};

// Force the current frame to be a dlight-update frame and rebase the
// cap interval to now.  Called from event-spawn helpers (muzzle flash
// start, impact spawn, explosion spawn) so the peak `frac == 1.0`
// frame of the new effect is always submitted to the engine even
// when the throttle would otherwise have skipped this render frame.
// Without this, dropping cl_dlight_update_hz to 120/250 visibly dims
// flashes — the brightest first-frame sample is the one most likely
// to land in a "skip" window, leaving only already-faded follow-up
// samples to colour the wall.
void() CSQC_DlightGate_ForceUpdate =
{
	csqc_dlight_update_this_frame = 1;
	csqc_dlight_last_update_stamp  = cltime;
};

void(string mode,
     float t0, float t_begin, float t_dlight, float t_lookat,
     float t_view, float t_state, float t_alivecam, float t_interp,
     float t_env, float t_scene, float t_hud) CSQC_ReportSpike =
{
	float total_ms = (t_hud - t0) * 1000;
	float threshold_ms = cvar("cl_debug_spike_ms");

	if (!cvar("cl_debug_spikes"))
		return;
	if (threshold_ms <= 0)
		threshold_ms = 2.0;
	if (total_ms < threshold_ms)
		return;

	print(sprintf("^1[csqc-spike]^7 t=%.3f total=%.3fms ft=%.3fms mode=%s ",
	              cltime, total_ms, frametime * 1000, mode));
	print(sprintf("begin=%.3f dlight=%.3f lookat=%.3f view=%.3f state=%.3f ",
	              (t_begin - t0) * 1000,
	              (t_dlight - t_begin) * 1000,
	              (t_lookat - t_dlight) * 1000,
	              (t_view - t_lookat) * 1000,
	              (t_state - t_view) * 1000));
	print(sprintf("alivecam=%.3f interp=%.3f env=%.3f scene=%.3f hud=%.3f\n",
	              (t_alivecam - t_state) * 1000,
	              (t_interp - t_alivecam) * 1000,
	              (t_env - t_interp) * 1000,
	              (t_scene - t_env) * 1000,
	              (t_hud - t_scene) * 1000));
};

noref void(float apiver, string enginename, float enginever) CSQC_Init =
{
	CSQC_EnsureWorldSolid();
	drawfont = loadfont("", "Courier Prime Code", "12,16,24,32,64,72,128,256,512", -1, 0, 0);
	// outline=1 bakes a 1px dark border into each glyph's atlas cell (FTE
	// gl_font.c), so HUD text renders its legibility border in ONE drawstring
	// instead of the old shadow-pass + main-pass double draw.  The manual black
	// drop-shadows are removed everywhere these two fonts are used (see the HUD
	// draws) — keeping them would double up with the baked outline.  Bump to
	// outline=2 for a heavier border.
	hud_font = loadfont("hud", "gfx/RobotoEB", "outline=2 8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	hud_font_regular = loadfont("hud_regular", "gfx/Roboto", "8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	hud_font_mono = loadfont("hud_mono", "gfx/GoogleMed", "outline=2 8 12 16 18 24 32 36 48 60 72", -1, 0, 0);
	// NOTE: we do NOT touch r_particledesc here. The cvar's reload callback
	// bails when the client is in ca_connected state (p_script.c:3799), so
	// setting it from CSQC_Init has no effect on the loaded set.  Instead,
	// every particleeffectnum() call uses the "weapons.foo" prefix syntax
	// which auto-loads particles/weapons.cfg on first miss (p_script.c:668).

	precache_everything();
	CSQC_PrecacheShells();
	CSQC_PrecacheBreakables();
	CSQC_BulletHolesInit();
	CSQC_TracersInit();
	CSQC_Rope_Init();
	CSQC_Scorch_Precache();
	CSQC_Bloodsplat_Precache();
	CSQC_Rain_Precache();
	CSQC_Flashlight_Precache();
	CSQC_MuzzleFlash_Precache();
	// Dopamine kill/cash feedback sounds (cl_hud.qc popups).
	precache_sound("sounds/effects/orchestralhit.mp3");
	precache_sound("sounds/effects/killsound.wav");
	precache_sound("sounds/effects/cashregister1.mp3");
	CSQC_EnvHud_Reset();
	precache_pic("gfx/scope.png");
	precache_pic("gfx/360hitindicator.png");
	HUD_VoIP_PrecachePics();
	registercommand("spectate");
	registercommand("spec");
	registercommand("firstperson");
	registercommand("thirdperson");
	registercommand("probe");
	registercommand("edicts_near");
	registercommand("cl_edicts_near");
	registercommand("csqc_dump_player_bones");
	registercommand("sv_defaultprimary");
	registercommand("sv_defaultsecondary");
	registercommand("sv_defaultmelee");
	registercommand("sv_defaultutility");
	registercommand("radio");
	registercommand("buymenu");
	registercommand("impactdebris");
	// Grapple press-and-hold aliases.  Bound via `bind <key> "+grapple"`:
	// the engine fires `+grapple` on key down and `-grapple` on key up,
	// which our aliases translate into the engage/release impulse pair
	// (9 / 91).  This is the protocol-agnostic counterpart to the
	// legacy `bind <key> "impulse 9"` toggle, which still works.
	// Aliases (not registercommand) so the engine's standard +/-
	// dispatch hits them without needing CSQC to handle the strings.
	localcmd("alias +grapple \"impulse 9\"\n");
	localcmd("alias -grapple \"impulse 91\"\n");
	// NOTE on +voip binding: FTE's engine guards `+voip` with a
	// `Cmd_IsInsecure()` check (see S_Voip_Enable_f /
	// snd_dma.c:1672 in the FTE source).  Any command invocation
	// coming from QC's `localcmd` is flagged INSECURE — including
	// the indirect invocation when an insecurely-bound key fires.
	// That means a bind set through the QC-side settings menu
	// (which writes via localcmd("bind z +voip")) will appear in
	// `bind z` but won't transmit voice when the key is pressed.
	// A CSQC-registered wrapper (registercommand + localcmd)
	// doesn't sidestep the check because the wrapper itself is
	// invoked from an insecure context.  The only known workaround
	// is for the user to type `bind <key> +voip` directly in the
	// console — that source IS trusted, so the resulting bind
	// passes Cmd_IsInsecure.  Documented in the bindlist row name.

	// All custom cvars are registered from a single shared table —
	// edit shared/sh_cvar_table.qc CVar_Init() to change defaults or
	// add new cvars. The table is the source of truth for the auto-
	// generated data/allcommands.cfg too.
	CVar_Init();
	CVar_RegisterMine();
};

noref void() CSQC_WorldLoaded =
{
	// Clear stale linked lists from previous map
	ladder_trigger_list = world;
	teleport_trigger_list = world;

	CSQC_EnsureWorldSolid();
	CSQC_ResetPredictionState();
	Smooth_Reset();
	CSQC_ClearSprays();
	CSQC_RegenerateSpraysShader();
	CSQC_EnvHud_Reset();
	CSQC_EnvSound_Reset();

	// Drop any stale throw-trail particle handle across the level boundary so it
	// re-resolves against the freshly-loaded "weapons" namespace.  (The handle can
	// be left pointing at a particle type the connect/map particle FLUSH unloaded;
	// ThrowTrail_Resolve detects that via a body-1 query and self-heals with a
	// namespace re-exec, so we deliberately do NOT force a re-exec here — an
	// unconditional reload at world-load could itself unload handles mid-session.)
	CSQC_ThrowTrail_Clear();

	// Reset live input state across the level boundary.  Two layers
	// of input state get stuck through changelevel:
	//
	// 1. CSQC's csqc_live_* mirror (what THIS mod reads to build
	//    pmove commands).  Cleared inline below.
	// 2. The ENGINE's own +cmd state machine (in_forward, in_attack,
	//    in_button6 etc.).  These are managed by the engine in
	//    response to +forward/-forward style binds.  When a key is
	//    held through changelevel, the engine never sees the
	//    -release event, so the state stays "down" on the server
	//    after the new map loads.  No QC-only assignment reaches
	//    these — they have to be released via the engine's own
	//    -<cmd> dispatch path, which we trigger by queueing the
	//    -release commands through localcmd().  After this, the
	//    user's actual still-held key will re-fire a +press on the
	//    next OS auto-repeat or release-and-press cycle.
	csqc_live_forward = 0;
	csqc_live_back    = 0;
	csqc_live_left    = 0;
	csqc_live_right   = 0;
	csqc_live_up      = 0;
	csqc_live_down    = 0;
	csqc_live_buttons = 0;

	localcmd("-forward\n");
	localcmd("-back\n");
	localcmd("-moveleft\n");
	localcmd("-moveright\n");
	localcmd("-moveup\n");
	localcmd("-movedown\n");
	localcmd("-attack\n");
	localcmd("-attack2\n");
	localcmd("-jump\n");
	localcmd("-button4\n");      // sprint (this mod's bind)
	localcmd("-button6\n");      // duck
	localcmd("-button7\n");      // alternate sprint bind
	localcmd("-use\n");
	localcmd("-voip\n");
	localcmd("-showscores\n");

	// Push the current cl_spray choice to the server so it sticks
	// immediately on connect / map change without waiting for the
	// menu to be opened.  The server stores it on the player entity
	// (see SV_HandleSetSpray in sv_spray.qc).  Empty cl_spray (fresh
	// install with no saved value) sends "" — server falls back to
	// "nospray" on its end.
	{
		string saved = cvar_string("cl_spray");
		if (saved == "") saved = "nospray";
		localcmd(sprintf("cmd setspray %s\n", saved));
	}

	// Clear any stale kill-feed entries carried over from the previous map.
	KillFeed_Clear();

	// Suppress the scoreboard's player rows for a brief grace window so
	// stale userinfo (frags / deaths / team / dead-flag) carried over
	// from the previous map doesn't render until the new server pushes
	// fresh SETINFO updates.  Scoreboard_PlayerName returns "" for every
	// slot during this window, which makes both the count and the row-
	// draw loops act as if the map has zero players.
	scoreboard_grace_until = cltime + SCOREBOARD_GRACE_AFTER_LOAD;
};

// CSQC_Ent_Update is implemented in cl_player.qc

// Tracks the previous frame's STAT_GAMEMODE so CSQC_UpdateView can
// detect a gamemode switch and react once-per-transition. Currently
// drives the Bhop auto-enable of cl_speedometer; reusable for any
// future "do X when entering mode Y" client-side hook.
float cl_last_gamemode;

// Track the last-applied serverkey("sv_mintic") value so we only stuff
// `cl_netfps` into the local console when the server's tickrate
// actually changes (or first arrives on connect).  See
// Sync_NetFPS_To_Tickrate just below.
float cl_netfps_synced_mintic;

// Auto-align the client's outgoing usercmd rate (cl_netfps) to the
// server's tick rate.  Server pushes sv_mintic (= seconds per tick) via
// serverinfo.  Reading it back as serverkeyfloat lets the client
// compute hz = 1 / mintic and stuff `cl_netfps <hz>` into the console.
//
// Why: cl_netfps decoupled from the server tick rate produces uneven
// usercmd-to-tick alignment — the engine bunches multiple usercmds into
// one server tick or splits one client frame across multiple ticks,
// which jitters pmove input_timelength on both sides.  Matching them
// keeps one usercmd per server tick.
//
// Fires on:
//   - first sv_mintic arrival after connect (tracker is 0 → triggers).
//   - any subsequent server-side tickrate change (cvar pushed via the
//     existing serverinfo plumbing in sv_main.qc).
void() Sync_NetFPS_To_Tickrate =
{
	float mintic = serverkeyfloat("sv_mintic", 0);
	if (mintic <= 0.0001) return;   // not pushed yet

	if (mintic != cl_netfps_synced_mintic)
	{
		float hz = floor(1.0 / mintic + 0.5);
		localcmd(sprintf("cl_netfps %g\n", hz));
		cl_netfps_synced_mintic = mintic;
	}
};

// cl_spray change watcher.  CSQC_WorldLoaded sends `cmd setspray` once
// at connect time, but if the user changes cl_spray at runtime (via
// console, autoexec, or any path that doesn't go through the menu's
// Apply button), the server never hears about it until they re-open
// the menu.  Symptom: "I set cl_spray hitup but every spray shows up
// as nospray.png until I click the spray in the menu".  Polling once
// per frame catches every change path at trivial cost.
//
// strzone the previous value so the next-frame string comparison sees
// stable memory (cvar_string returns engine-managed temps that may
// alias between calls).  strunzone before re-zoning to avoid leaks.
string cl_spray_last_seen;       // strzone'd, "" before first poll
void() CSQC_Spray_PollCvar =
{
	string cur = cvar_string("cl_spray");
	if (cur == "") cur = "nospray";
	// Use strncmp for explicit value-comparison.  cvar_string returns
	// engine-managed temp strings that don't pointer-equal across
	// calls even when the underlying value is identical, so the QC
	// `!=` operator would either always-fire (ref compare) or never-
	// fire (broken value compare) depending on fteqcc/engine build.
	float diff = 1;
	if (cl_spray_last_seen != "")
		diff = strncmp(cur, cl_spray_last_seen, 64);
	if (diff != 0)
	{
		localcmd(sprintf("cmd setspray %s\n", cur));
		if (cvar("cl_debug_spray"))
			print(sprintf("[spray] cvar change '%s' -> '%s' — setspray sent\n",
			              cl_spray_last_seen, cur));
		if (cl_spray_last_seen != "")
			strunzone(cl_spray_last_seen);
		cl_spray_last_seen = strzone(cur);
	}
};

float(float width, float height) CSQC_UpdateViewFrameBegin =
{
	Sync_NetFPS_To_Tickrate();
	// Drive the radio beep/voice/beep sequence forward.  Cheap when
	// nothing is pending; checks two cltime gates and returns.
	Radio_TickSequence();
	CSQC_Spray_PollCvar();
	//clear and update our global screen resolution vars
	clearscene();
	g_width = width;
	g_height = height;
	CSQC_BulletHolesStartFrame();
	CSQC_DrawSprays();
	CSQC_InfoDecal_DrawTrisoup();   // infodecals: live-swap dispatch on r_decal_renderer (1=trisoup / 0=adddecal)

	//disable quake status bar and quake crosshair
	setproperty(VF_DRAWENGINESBAR, 0);
	setproperty(VF_DRAWCROSSHAIR, 0);

	// Smoothing diagnostics — push per-frame samples.  Gate frametime
	// on > 0 so engine-paused ticks (menu open, alt-tab) don't inject
	// zero-width samples that corrupt min / stddev.
	if (frametime > 0)
		Smooth_Push(SMOOTH_M_FT, frametime * 1000);
	Smooth_Push(SMOOTH_M_UNACK, pred_cmd_latest_sequence - sv_confirmed_cmdframe);

	// Backdrop mode: we're running the cl_menumap listen server purely as a
	// render backdrop for the main menu.  Server-authoritative — the backdrop
	// listen server publishes sv_backdrop=1 via serverinfo (see sv_main.qc),
	// and any real game (including console `connect localhost`) reports 0.
	// Reading from serverinfo instead of a local cvar means HUD/team-select
	// suppression follows the actual server identity, not a menu flag that
	// can desync if the user joins a server through the console.
	float in_menu_backdrop = serverkeyfloat("sv_backdrop", 0) > 0;

	// Bhop quality-of-life: auto-enable cl_speedometer when the gamemode
	// switches INTO Bhop, so movement-focused players get the readout
	// without having to remember the cvar. Latched on transition only —
	// we don't keep forcing it, so the user can disable it manually if
	// they want. Tracked locally; compared to the server-pushed
	// STAT_GAMEMODE each frame. cl_last_gamemode is a static-style
	// file-scope float declared just above CSQC_UpdateView's prototype
	// chain — see the declaration block near top of this file.
	float gm_now = getstatf(STAT_GAMEMODE);
	if (gm_now != cl_last_gamemode)
	{
		if (gm_now == GAMEMODE_BHOP)
			cvar_set("cl_speedometer", "1");
		cl_last_gamemode = gm_now;
	}

	return in_menu_backdrop;
};

void() CSQC_DrawTeamDebugServerPanels =
{
	// VOIP mute mode hijacks the scoreboard for clickable rows —
	// we need an SUI bracket around HUD_DrawScoreboard so the
	// per-row sui_action_element calls register correctly.
	// Wrap the scoreboard draw inside this same sui_begin/end so
	// only one bracket exists per frame (sui_begin is not re-entrant).
	float mute_active = hud_voipmute_mode && HUD_ScoreboardVisible() && !TeamMenuIsOpen();
	if (TeamMenuIsOpen() || Debug_PanelOpen() || Server_PanelOpen() || mute_active)
	{
		float prev_font = drawfont;
		drawfont = hud_font;
		sui_begin(g_width, g_height);
		if (mute_active)
		{
			HUD_DrawScoreboard();
		}
		if (TeamMenuIsOpen())
		{
			TeamMenuDraw();
			sui_menu_nav();
		}
		if (Debug_PanelOpen())
		{
			Debug_PanelDraw();
		}
		if (Server_PanelOpen())
		{
			Server_PanelDraw();
		}
		sui_end();
		drawfont = prev_font;
	}
};

// nettest: reconstruct + show the spectated target's first-person viewmodel
// (their gun, animated from the networked weapon state) while watching through
// their eyes.  Used by live spectate; the killcam replay calls the builder directly.
void() Spectate_AddViewmodel =
{
	if (spec_mode != SPEC_MODE_FIRSTPERSON || spec_target <= 0 || Spectate_InDeathCam())
		return;
	entity vp = Spectate_FindProxy(spec_target);	// the live body, not a lingering corpse
	if (!vp || vp.classname != "player_visual_proxy" || vp.vis_is_dead)
		return;
	CSQC_AddRemoteViewmodel(vp.vis_weapon_id, vp.vis_weaponstate, vp.vis_wep_action, vp.vis_wep_anim_start);
};

void(float in_menu_backdrop) CSQC_UpdateViewSpectator =
{
	// nettest killcam: while replaying, Killcam_Replay drives the camera + poses
	// the recorded scene + renders the killer's viewmodel; skip the live spectate
	// camera/extrapolation for the duration.
	float kc = Killcam_Active();
	if (kc)
		kc = Killcam_Replay();

	if (!kc)
	{
		Spectate_CheckTargetAlive();
		Spectate_UpdateCamera();
		CSQC_EnvSound_UpdateListener();

		CSQC_SampleRemotePlayersForInterp();
		CSQC_ExtrapolateRemotePlayers();
		if (spec_mode == SPEC_MODE_FIRSTPERSON && spec_target > 0 && !Spectate_InDeathCam())
		{
			setproperty(VF_VIEWENTITY, spec_target);
			// Lock mouse — the target's view drives angles, the local mouse
			// delta would just accumulate as phantom drift to be resolved on
			// detach / freecam swap.
			setsensitivityscaler(0);
		}
		else
		{
			setproperty(VF_VIEWENTITY, 0);
			setsensitivityscaler(1);
		}
	}
	else
		setsensitivityscaler(0);

	addentities(MASK_ENGINE);
	// nettest killcam slow-mo: while DEAD, keep recording the death AFTERMATH (your
	// corpse's death anim) here — the alive-path Killcam_Record below never runs once
	// you're spectating.  NOT gated on killcam_on: the killfeed (which sets killcam_on)
	// can land AFTER the death registers, so we must start capturing from the real death
	// S or the aftermath has an empty head.  Killcam_Record self-bounds it (kc_posed
	// skips replayed frames; the S+window cap stops it), so it only grabs the LIVE death.
	if (getstatf(STAT_IS_DEAD))
		Killcam_Record();
	if (!kc)
	{
		Spectate_AddViewmodel();	// nettest: the spectated player's animated viewmodel
		// Live-player FX (muzzle flash/smoke, tracers/impacts, ropes, throw trails)
		// are MASKED during the killcam replay so alive players outside the replay
		// don't bleed their effects into the recorded scene.
		CSQC_DrawMuzzleFlash();
		CSQC_DrawMuzzleFlashSprite();
		CSQC_DrawMuzzleSmoke();
		CSQC_Rope_Draw();
		CSQC_Rope_DrawRemotes();
		CSQC_ThrowTrail_Tick();
		CSQC_C4_DrawLights();
		CSQC_C4_DrawPlanterFlash();
		CSQC_DrawMuzzleDebug();
		CSQC_DrawImpactLights();
		CSQC_ProcessPendingImpacts();
	}
	CSQC_DrawDebugHitboxes();
	CSQC_DrawDebugHitboxExpand();
	CSQC_DrawDebugPhysProps();
	CSQC_DrawDebugPhysDropBboxes();
	CSQC_DrawDebugPickupZones();
	CSQC_DrawServerHitboxes();
	CSQC_DrawContinuousHitboxes();
	NavDebug_DrawScene();	// nettest: nav-graph + links + spectated-bot path (also while spectating)
	renderscene();
	NavDebug_DrawText();	// nettest: bot state labels + spectated-bot panel (2D, after renderscene)

	if (!in_menu_backdrop)
	{
		float spec_prev_font = drawfont;
		drawfont = hud_font;
		Spectate_DrawHUD();
		HUD_DrawSpectatorCrosshair();	// nettest: crosshair for first-person spectate
		HUD_DrawKillcamCrosshair();	// nettest: crosshair for the killcam (killer's weapon)
		Killcam_DrawHUD();	// nettest: KILLCAM / "killed by X" banner
		HUD_DrawCenterMessage();
		HUD_DrawRoundTimer();
		HUD_DrawKillFeed();
		HUD_DopamineFrame();
		// Also draw the death-screen damage report here — when you
		// die you immediately enter the spectate / death-cam branch
		// (Spectate_IsActive() is true), and this `return` below
		// short-circuits the alive-camera HUD path. Without this
		// call you'd only see the panel after respawning.
		HUD_DrawDamageReport();
		drawfont = spec_prev_font;

		// Still allow scoreboard, team menu, and the F1/F2 panels
		// while spectating / dead.
		TeamMenuUpdateCursorState();
		// Skip the generic scoreboard draw while the team menu is
		// open — TeamMenuDraw runs HUD_DrawScoreboard with
		// hud_scoreboard_teamselect=TRUE for the team picker UI,
		// and we don't want to also stamp the regular scoreboard
		// (with the hostname title) underneath it.  That double-
		// draw is what produced the "two stacked titles + glow"
		// look the user reported.
		if (HUD_ScoreboardVisible() && !TeamMenuIsOpen())
			HUD_DrawScoreboard();
		CSQC_DrawTeamDebugServerPanels();
		CSQC_EnvHud_Draw();
	}
};

float() CSQC_UpdateViewAliveCamera =
{
	// --- Normal alive camera ---
	// While the local player is still in team-select (player_team <= TEAM_NONE),
	// the server is driving their origin every tick via Camera_PlacePlayerAtCurrent.
	// We have no prediction proxy for them yet (PM_EnsurePredictionProxy doesn't run
	// until PlayerSpawn), so predicted_player can get seeded from a stale
	// engine_player.origin (often 0,0,0 on the very first frame), lock
	// csqc_prediction_valid = TRUE, and from then on its bogus origin overrides
	// the engine's authoritative view.  Skip the CSQC override while in team-select
	// and let the engine render from the real player entity.
	float in_team_select = getstati(STAT_PLAYERTEAM) <= TEAM_NONE;

	if (predicted_player && csqc_prediction_valid && !in_team_select)
	{
		if (csqc_present_valid)
			campos = csqc_present_origin + csqc_present_view_ofs;
		else
			campos = predicted_player.origin + predicted_player.view_ofs;
		camang = view_angles;
		// View-feel position offsets (cl_camerabob, cl_viewmodelweight).
		// Done first so the angle modifiers below see the final camang
		// when CSQC_ApplyCameraBob calls makevectors(camang) internally.
		// camang has not been touched yet on this frame; it's just
		// view_angles, which is the lateral basis we want bob to use.
		campos = CSQC_ApplyCameraBob(campos);
		campos = CSQC_ApplyCameraWeight(campos);
		// Sniper breathing sway — pure visual modifier.  view_angles is
		// untouched so input_angles / server-side v_angle stay authoritative.
		camang = CSQC_ApplySniperSway(camang);
		// sv_gunkick — bias the rendered camera by the spring-decayed
		// per-shot view kick. Same field SH_ApplyViewKick wrote into
		// at fire time; pmove integrates the spring decay each tick.
		camang = CSQC_ApplyViewKick(camang);
		camang = CSQC_ApplyDamageViewKick(camang);
		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, camang);

		// Player flashlight — projects a cookie-textured dlight from
		// the camera in the camera's forward direction. Reads VF_ORIGIN
		// + VF_ANGLES we just set so it tracks sniper sway / gunkick
		// bias exactly.
		CSQC_Flashlight_Render();
	}
	else
	{
		// Don't trust the engine's fallback camera — it can snap to the wrong
		// player on some maps. Keep the last known good position instead.
		camang = view_angles;

		// Client-side sway while the player is still in team-select — runs
		// at render rate against cltime so motion stays smooth regardless
		// of ping / server tick rate.  See cl_cameras.qc for the math.
		if (in_team_select)
			camang = CSQC_TeamSelectSwayAngles(camang);
		camang = CSQC_ApplyDamageViewKick(camang);

		setproperty(VF_ANGLES, camang);
	}

	// CSQC-side camera debug — mirrors the server sv_debug_camera bprint so
	// we can see both sides of the origin-sync pipeline in the same log.
	// Mode 1 = one-shot on first frame; mode 2 = 1 Hz continuous.
	float cam_dbg_mode = cvar("sv_debug_camera");
	if (cam_dbg_mode)
	{
		static float cl_cam_last_dbg;
		static float cl_cam_printed_once;
		float show;
		if (cam_dbg_mode >= 2)
			show = (cltime - cl_cam_last_dbg > 1.0);
		else
			show = !cl_cam_printed_once;

		if (show)
		{
			cl_cam_last_dbg = cltime;
			cl_cam_printed_once = 1;
			vector pp_org = predicted_player ? predicted_player.origin : '0 0 0';
			vector pp_vof = predicted_player ? predicted_player.view_ofs : '0 0 0';
			print(sprintf("[camdbg CSQC] predicted.origin=%v view_ofs=%v present_valid=%g present_origin=%v campos=%v\n",
			              pp_org, pp_vof, csqc_present_valid, csqc_present_origin, campos));
		}
	}

	// Third-person chase cam — honour chase_active/chase_back/chase_up/chase_right
	if (cvar("chase_active"))
	{
		vector chase_fwd, chase_rt, chase_up;
		makevectors(camang);
		chase_fwd = v_forward;
		chase_rt = v_right;
		chase_up = v_up;

		float cb = cvar("chase_back");   if (!cb) cb = 100;
		float cr = cvar("chase_right");
		float cu = cvar("chase_up");     if (!cu) cu = 16;

		vector chase_pos = campos
			- chase_fwd * cb
			+ chase_rt * cr
			+ chase_up * cu;

		// Wall clip to prevent camera going through geometry
		traceline(campos, chase_pos, TRUE, world);
		if (trace_fraction < 1)
			chase_pos = trace_endpos + trace_plane_normal * 2;

		// Camera angles stay parallel to the player's view — the offset
		// just shifts what's on screen (over-the-shoulder feel for
		// chase_right). Aiming the camera AT the player would tilt the
		// view inward whenever chase_right/up are non-zero, which is
		// not what users expect from the cvar's name.
		campos = chase_pos;
		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, camang);
	}

	return in_team_select;
};

void(float in_team_select) CSQC_UpdateViewAliveSensitivity =
{
	// Zoom FOV override + sensitivity scaling for scoped weapons.
	// In team-select (TEAM_NONE) the server drives origin + angles through
	// the camera system via fixangle — zero the mouse scaler so the user's
	// mouse doesn't accumulate phantom deltas that would be committed the
	// moment they actually join a team.
	if (in_team_select)
	{
		setsensitivityscaler(0);
	}
	else if (predicted_player && csqc_prediction_valid && predicted_player.zoomstage > 0
	         && Weapon_HasScope(predicted_player.weapon))
	{
		// Same client-side gate as HUD_DrawScope in cl_hud.qc: if the
		// predicted weapon can't scope, ignore a lingering zoomstage
		// (stale from the previous weapon under high ping) and fall
		// through to the default sensitivity / unzoomed FOV branch.
		float zoom_fov;
		if (predicted_player.zoomstage == 1)
			zoom_fov = ZOOM_FOV_STAGE1;
		else
			zoom_fov = ZOOM_FOV_STAGE2;

		setproperty(VF_AFOV, zoom_fov);
		setsensitivityscaler(zoom_fov / cvar("fov"));
	}
	else if (CSQC_CodScope_IsScoped())
	{
		// CoD-style scope owns the FOV path for scout/awp under
		// sv_codscopes (Weapon_HasScope returns 0 for those weapons
		// in CoD mode so the legacy branch above never triggers).
		CSQC_CodScope_ApplyFOV();
	}
	else
	{
		// Default unzoomed path — apply per-state FOV biases driven by
		// the existing CSQC viewfx envelopes (cl_viewfx.qc owns the
		// smoothing).  ADS reduces FOV (zoom in slightly); sprint
		// raises it (sense of speed).  Both are additive on the
		// player's base fov cvar and stack cleanly when partially
		// blended (e.g. mid-fade between sprint and ADS).
		float base_fov   = cvar("fov");
		float ads_bias   = cvar("cl_ads_fov");
		float spr_bias   = cvar("cl_sprinting_fov");
		float final_fov  = base_fov
		                 - csqc_viewfx_ads_env    * ads_bias
		                 + csqc_viewfx_sprint_env * spr_bias;
		if (final_fov < 10)  final_fov = 10;
		if (final_fov > 170) final_fov = 170;
		setproperty(VF_AFOV, final_fov);
		setsensitivityscaler(1);
	}
};

void() CSQC_UpdateViewAliveScene =
{
	// Paint team-colour tints on player entities BEFORE the engine adds
	// them for this frame — .colormod reaches the shader as e_colourident.
	CSQC_ApplyTeamTints();

	//autoadd entities received from servers for drawing
	addentities(MASK_ENGINE);
	CSQC_AddPredictedViewmodel();
	CSQC_CheckFakeDropRemoval();
	CSQC_DrawMuzzleFlash();
	CSQC_DrawMuzzleFlashSprite();
	CSQC_DrawMuzzleSmoke();
	CSQC_Rope_Draw();
	CSQC_Rope_DrawRemotes();
	CSQC_ThrowTrail_Tick();
	CSQC_C4_DrawLights();
	CSQC_C4_DrawPlanterFlash();
	CSQC_DrawMuzzleDebug();
	CSQC_DrawImpactLights();
	CSQC_ProcessPendingImpacts();
	CSQC_DrawSmokeClouds();
	CSQC_DrawScorchDecals();
	CSQC_DrawBloodDecals();
	CSQC_Rain_Tick();
	CSQC_DrawDebugImpacts();
	NavDebug_DrawScene();	// nettest: bot nav-graph + links + enemy lines (server-gated on sv_debug_nav)
	CSQC_DrawSkelDebug();	// nettest: live player skeleton overlay (cl_skel_debug) for the warp diagnosis
	CSQC_DrawDebugHitboxes();
	CSQC_DrawDebugHitboxExpand();
	CSQC_DrawDebugPhysProps();
	CSQC_DrawDebugPhysDropBboxes();
	CSQC_DrawDebugPickupZones();
	CSQC_DrawServerHitboxes();
	CSQC_DrawContinuousHitboxes();

	// VOIP overhead icons — billboarded sprites floating above
	// every remote speaker.  Submitted via R_BeginPolygon so they
	// participate in renderscene's transparent pass.  See
	// HUD_VoIP_DrawWorldOverheads in cl_voip_hud.qc.
	HUD_VoIP_DrawWorldOverheads();

	//does what you think it does
	renderscene();
	CSQC_DrawDebugImpactText();
	NavDebug_DrawText();	// nettest: bot state labels (2D, after renderscene)
};

void(float in_menu_backdrop) CSQC_UpdateViewAliveHud =
{
	if (!in_menu_backdrop)
	{
		// Populate per-frame HUD cvar caches BEFORE any HUD draw fn
		// reads them. Cheap (7 cvar reads + 1 tokenize for the
		// crosshair colour) but avoids the same reads being repeated
		// inside HUD_DrawCrosshair every frame.
		HUD_RefreshCrosshairCache();

		HUD_DrawPainFlash();
		HUD_DrawHitIndicators();
		CSQC_DrawFlashbangOverlay();
		HUD_DrawHitmarker();
		HUD_DrawDefuseBar();
		// HUD_DrawCodStaminaBar moved into CSQC_DrawWeaponHUD so it
		// composites AFTER the scope overlay (z-order requirement).
		CSQC_DrawWeaponHUD();
		Radio_Draw();
		Buy_Draw();
		HUD_DrawSpeedometer();
		HUD_DrawNetGraph();
		HUD_DrawKillFeed();
		HUD_DopamineFrame();
		HUD_DrawDamageReport();
		HUD_VoIP_Tick();
		HUD_VoIP_Draw();

		// Look-at name tag — small HUD label below-left of the
		// crosshair, plus a world-projected label above the looked-at
		// player's head.  Both are 2D draws (DrawWorld uses project()
		// to map 3D→2D), so they live in the HUD pass after renderscene.
		CSQC_LookatName_DrawWorld();
		CSQC_LookatName_DrawHUD();

		CSQC_DrawDebugPanels();
		CSQC_Weather_DebugDraw();   // cl_debug_weather overlay (no-op when 0)

		// Update team menu cursor state every frame
		TeamMenuUpdateCursorState();

		// Draw scoreboard (raw draw calls, no SUI needed).  Skip
		// the generic draw when the team menu is open — TeamMenuDraw
		// (called via CSQC_DrawTeamDebugServerPanels below) runs its
		// own HUD_DrawScoreboard with hud_scoreboard_teamselect=TRUE
		// for the team picker UI; doing both stacks two scoreboards
		// (hostname title and "Select a Team" title both visible).
		// Also skip when VOIP mute mode is active — the scoreboard
		// is then drawn inside CSQC_DrawTeamDebugServerPanels's SUI
		// bracket so its per-row click rects register correctly.
		if (HUD_ScoreboardVisible() && !TeamMenuIsOpen() && !hud_voipmute_mode)
			HUD_DrawScoreboard();

		// Draw team select and/or the F1/F2 panels — all need SUI, share
		// a single sui_begin/end pair per frame so the input queue
		// isn't double-pumped.
		CSQC_DrawTeamDebugServerPanels();
		CSQC_EnvHud_Draw();
	}
};

// CALLED EVERY CLIENT RENDER FRAME
void(float width, float height, float menushown) CSQC_UpdateView =
{
	float in_menu_backdrop;
	float in_team_select;
	float spike_debug;
	float spike_t0 = 0;
	float spike_t_begin = 0;
	float spike_t_dlight = 0;
	float spike_t_lookat = 0;
	float spike_t_view = 0;
	float spike_t_state = 0;
	float spike_t_alivecam = 0;
	float spike_t_interp = 0;
	float spike_t_env = 0;
	float spike_t_scene = 0;
	float spike_t_hud = 0;

	spike_debug = cvar("cl_debug_spikes");
	if (spike_debug)
		spike_t0 = gettime(0);

	in_menu_backdrop = CSQC_UpdateViewFrameBegin(width, height);
	if (spike_debug)
		spike_t_begin = gettime(0);

	// Sample the dynamic-light re-issue gate exactly once per render
	// frame so every CSQC_Draw*Lights callsite below reads the same
	// answer (otherwise sequential checks would alias against the
	// last_update_stamp and only the first dlight type each cap-
	// interval would update).
	CSQC_DlightGate_Tick();
	if (spike_debug)
		spike_t_dlight = gettime(0);

	// Look-at name pulse — 5 Hz traceline that resolves the player
	// currently under the crosshair into `lookat_target_slot`.  Must
	// run before HUD_VoIP_DrawWorldOverheads (which reads the slot to
	// bump the icon up by LOOKAT_VOIP_OFFSET_BUMP px).
	CSQC_LookatName_Pulse();
	if (spike_debug)
		spike_t_lookat = gettime(0);

	CSQC_BuildPresentationView();
	if (spike_debug)
		spike_t_view = gettime(0);

	// --- Spectator / death cam ---
	Spectate_UpdateState();
	Killcam_DeathWatch();	// nettest: latch the REAL death time S (before any record/replay this frame)
	Killcam_MaybeRestore();	// nettest: restore killcam-posed proxies every frame (alive or dead)
	if (spike_debug)
		spike_t_state = gettime(0);

	if (Spectate_IsActive())
	{
		CSQC_UpdateViewSpectator(in_menu_backdrop);
		if (spike_debug)
		{
			spike_t_alivecam = spike_t_state;
			spike_t_interp = spike_t_state;
			spike_t_env = spike_t_state;
			spike_t_scene = gettime(0);
			spike_t_hud = spike_t_scene;
			CSQC_ReportSpike("spectator", spike_t0, spike_t_begin,
			                 spike_t_dlight, spike_t_lookat, spike_t_view,
			                 spike_t_state, spike_t_alivecam, spike_t_interp,
			                 spike_t_env, spike_t_scene, spike_t_hud);
		}
		return;
	}

	in_team_select = CSQC_UpdateViewAliveCamera();
	if (spike_debug)
		spike_t_alivecam = gettime(0);

	// Record the current server snapshot into the interp ring buffer
	// (no-op unless a new snapshot has arrived since last call), then
	// either lerp-behind (cl_interp_time > 0) or extrap.
	CSQC_PushInterpUserInfo();
	CSQC_PushPredictHitsUserInfo();
	CSQC_SampleRemotePlayersForInterp();
	CSQC_ExtrapolateRemotePlayers();
	if (spike_debug)
		spike_t_interp = gettime(0);

	// CSQC submits its own predicted viewmodel, so keep the engine's
	// authoritative weaponmodel hidden to avoid double-rendering.
	setproperty(VF_VIEWENTITY, 0);

	CSQC_UpdateViewAliveSensitivity(in_team_select);
	CSQC_EnvSound_UpdateListener();
	if (spike_debug)
		spike_t_env = gettime(0);
	CSQC_UpdateViewAliveScene();
	// nettest killcam: record AFTER the scene's predraw so the proxy anim clocks
	// (vis_anim_*_time) are this frame's freshly-computed values, not last frame's
	// stale ones — otherwise the buffered victim body plays back frozen.
	Killcam_Record();
	if (spike_debug)
		spike_t_scene = gettime(0);
	CSQC_UpdateViewAliveHud(in_menu_backdrop);
	if (spike_debug)
	{
		spike_t_hud = gettime(0);
		CSQC_ReportSpike("alive", spike_t0, spike_t_begin,
		                 spike_t_dlight, spike_t_lookat, spike_t_view,
		                 spike_t_state, spike_t_alivecam, spike_t_interp,
		                 spike_t_env, spike_t_scene, spike_t_hud);
	}
};

// Suppress the server echo of the local player's footstep and weapon sounds
// when CSQC already played them locally.  Suppression is gated on the last
// local playback timestamp so that prediction divergence still lets the
// authoritative server sound through.
//
// "sounds/player/" is the full path used in this mod.  FTE's QW protocol may
// strip the "sounds/" prefix on the wire, so both forms are accepted.
noref float(float entnum, float channel, string soundname, float vol,
            float attenuation, vector pos, float pitchmod, float flags)
CSQC_Event_Sound =
{
    float ping_est;
    float age;

    // During the killcam, MUTE all LIVE weapon/auto sounds — they play in real time
    // (the killer is still alive shooting), DOUBLING the replayed shot.  Do NOT key
    // on `entnum != player_localentnum`: a TRUE spectator auto-tracking the killer
    // (Elimination) has player_localentnum == the killer, so that term SKIPPED the
    // mute — the persistent double.  The killcam's own replay sound is localsound()
    // (never routed through here), so it still plays = exactly one sound per shot.
    if (Killcam_Active() && (channel == CHAN_WEAPON || channel == CHAN_AUTO))
        return TRUE;

    if (entnum != player_localentnum || player_localentnum <= 0)
        return FALSE;

    // Suppress predicted weapon echoes on the local player.
    // Use a fixed 1-second window — covers slow weapons (shotgun pump)
    // and avoids ping-estimation edge cases that cause double sounds.
    if (channel == CHAN_WEAPON)
    {
        age = cltime - csqc_last_predicted_weapon_sound_time;
        if (csqc_last_predicted_weapon_sound_time > 0 && age < 1.0)
            return TRUE;
        return FALSE;
    }

    // Suppress predicted CHAN_AUTO echoes (bolt, reload, pump sounds)
    if (channel == CHAN_AUTO)
    {
        age = cltime - csqc_last_predicted_auto_sound_time;
        if (csqc_last_predicted_auto_sound_time > 0 && age < 1.0)
            return TRUE;
        return FALSE;
    }

    if (channel != CHAN_BODY)
        return FALSE;
    if (substring(soundname, 0, 14) != "sounds/player/"
        && substring(soundname, 0, 7) != "player/")
        return FALSE;

    return FALSE;
};

void(string alias_name, string cvarname) CSQC_SetDefaultWeaponAlias =
{
	string weapon = argv(1);
	if (weapon == "")
	{
		string current = Server_GetString(cvarname);
		print(sprintf("%s usage: %s <weapon>\n", alias_name, alias_name));
		print(sprintf("%s current: %s\n", alias_name, current != "" ? current : "0"));
		return;
	}

	Server_SetQuoted(cvarname, weapon);
};

float(string cmd) CSQC_ConsoleCommand =
{
	tokenize(cmd);
	switch(argv(0))
	{
		case "sv_defaultprimary":
			CSQC_SetDefaultWeaponAlias("sv_defaultprimary", "sv_default_primary");
			return TRUE;
		case "sv_defaultsecondary":
			CSQC_SetDefaultWeaponAlias("sv_defaultsecondary", "sv_default_secondary");
			return TRUE;
		case "sv_defaultmelee":
			CSQC_SetDefaultWeaponAlias("sv_defaultmelee", "sv_default_melee");
			return TRUE;
		case "sv_defaultutility":
			CSQC_SetDefaultWeaponAlias("sv_defaultutility", "sv_default_utility");
			return TRUE;
		case "spectate":
		case "spec":
			localcmd("cmd spectate\n");
			return TRUE;
		case "firstperson":
		case "thirdperson":
			// Both names toggle chase_active — they're aliases, picked
			// for binding-readability ("bind b thirdperson" reads as
			// the user's intent even though it's a flip-flop).
			cvar_set("chase_active", cvar("chase_active") ? "0" : "1");
			return TRUE;
		case "csqc_dump_player_bones":
			CSQC_DumpPlayerBones();
			return TRUE;
		case "radio":
			Radio_Toggle();
			return TRUE;
		case "buymenu":
			Buy_Toggle();
			return TRUE;
		case "impactdebris":
			// Swap the chunk colour.  No arg = flip stone<->dirt;
			// `impactdebris 0|1` sets it explicitly (0 = stone, 1 = dirt).
			if (argv(1) != "")
				cvar_set("cl_impact_debris_mode", argv(1));
			else
				cvar_set("cl_impact_debris_mode", cvar("cl_impact_debris_mode") ? "0" : "1");
			print(sprintf("impact debris chunks: %s\n",
			      cvar("cl_impact_debris_mode") ? "dirt" : "stone"));
			return TRUE;
		case "probe":
		{
			// Diagnostic: fire a player-hull tracebox forward from the
			// local eye, print what CSQC sees, then ask the server to
			// do the same. Mismatch between the two lines identifies
			// invisible-collider / prediction-drift bugs.
			vector eye = predicted_player.origin + predicted_player.view_ofs;
			makevectors(view_angles);
			vector end = eye + v_forward * 1024;
			tracebox(eye, '-16 -16 0', '16 16 56', end, MOVE_NORMAL, predicted_player);
			if (trace_fraction < 1)
			{
				print(sprintf("^3[probe]^7 client: hit classname='%s' ent=%g origin=%v solid=%g\n",
					trace_ent.classname, trace_ent.entnum, trace_ent.origin, trace_ent.solid));
				print(sprintf("              mins=%v maxs=%v model='%s' frac=%.3f endpos=%v\n",
					trace_ent.mins, trace_ent.maxs, trace_ent.model, trace_fraction, trace_endpos));
			}
			else
				print(sprintf("^3[probe]^7 client: no hit (full 1024 trace, endpos=%v)\n", trace_endpos));
			localcmd("cmd probe\n");
			return TRUE;
		}
		case "edicts_near":
		{
			// Diagnostic: forward the whole arg line to the server so it
			// can dump every SSQC edict whose origin lies within radius R
			// of point P. Catches non-networked colliders the client
			// never learns about. Usage: edicts_near "0 0 0" 16
			localcmd(sprintf("cmd edicts_near \"%s\" %s\n",
				argv(1), argv(2)));
			return TRUE;
		}
		case "cl_edicts_near":
		{
			// CSQC-side mirror: walk every CSQC entity and dump any whose
			// world bbox is within radius of the search point. This is
			// what to use when the server scan is empty but pmove still
			// blocks — a stale CSQC entity (PVSF_NOREMOVE leftover, bad
			// snapshot, etc.) is the only thing left that could have a
			// solid hull on this side without one on the server.
			vector p = stov(argv(1));
			float  r = stof(argv(2));
			if (r <= 0)
				r = 32;
			print(sprintf("^3[cl_edicts_near]^7 scanning bbox within %g of %v:\n", r, p));
			float hits = 0;
			entity e = world;
			while ((e = nextent(e)))
			{
				if (e.classname == "" && e.model == "" && e.solid == 0)
					continue;
				vector amin = e.origin + e.mins;
				vector amax = e.origin + e.maxs;
				vector closest;
				closest_x = max(amin_x, min(p_x, amax_x));
				closest_y = max(amin_y, min(p_y, amax_y));
				closest_z = max(amin_z, min(p_z, amax_z));
				if (vlen(closest - p) > r)
					continue;
				print(sprintf(" ent=%g class='%s' origin=%v solid=%g\n",
					e.entnum, e.classname, e.origin, e.solid));
				print(sprintf("    absmin=%v absmax=%v model='%s' drawmask=%g\n",
					amin, amax, e.model, e.drawmask));
				hits = hits + 1;
			}
			print(sprintf("^3[cl_edicts_near]^7 done, %g matched\n", hits));
			return TRUE;
		}
		case "noclip":
		{
			// Cheats gate — read the serverinfo mirror the server publishes
			// each StartFrame.  If off, forward the text command so the
			// server's existing "noclip requires mp_cheats 1" sprint fires.
			string cheats = serverkey("mp_cheats");
			if (cheats == "" || cheats == "0")
			{
				localcmd("cmd noclip\n");
				return TRUE;
			}

			// Route through impulse 10 — the CSQC_PredictWeaponImpulse path
			// at cl_weapons.qc:544 already toggles pm_movetype during replay,
			// and the impulse is stored in the buffered usercmd ring so
			// CSQC_ReconcilePrediction re-applies it every frame until the
			// server ack catches up.  Directly mutating predicted_player
			// .pm_movetype does not survive — CSQC_ResetToConfirmedState
			// restores the last ack'd value on every reconcile (which is
			// why at 999 ping the local flip was instantly wiped, but in
			// the void — where no snapshots arrive — it appeared to work).
			localcmd("impulse 10\n");

			// Local feedback this frame; the server's matching sprint
			// lands ~RTT later.
			if (predicted_player)
			{
				if (predicted_player.pm_movetype == PM_MOVETYPE_NOCLIP)
					print("noclip OFF\n");
				else
					print("noclip ON\n");
			}

			return TRUE;
		}
		default:
			return FALSE;
	}
	return TRUE;
};

float(float evtype, float scanx, float chary, float devid) CSQC_InputEvent =
{
	// Debug panel: when open it absorbs all input (clicks, mouse,
	// scroll, ESC + F1 internally close).  Must run BEFORE the F1
	// open-toggle below so F1 inside the panel hits the close path
	// in Debug_PanelInputEvent rather than re-toggling open here.
	if (Debug_PanelOpen())
	{
		if (Debug_PanelInputEvent(evtype, scanx, chary, devid))
			return TRUE;
	}

	// Server panel: same shape as debug panel but on F2.
	if (Server_PanelOpen())
	{
		if (Server_PanelInputEvent(evtype, scanx, chary, devid))
			return TRUE;
	}

	// F1 opens the debug panel from gameplay.
	if (evtype == IE_KEYDOWN && scanx == K_F1)
	{
		Debug_PanelToggle();
		return TRUE;
	}

	// F2 opens the server panel from gameplay.
	if (evtype == IE_KEYDOWN && scanx == K_F2)
	{
		Server_PanelToggle();
		return TRUE;
	}

	// Buy menu — when open, swallow 1-9 + ESC + mouse-1 so they don't
	// leak to weapon binds / +attack.  Movement etc. still passes through.
	if (Buy_IsOpen())
	{
		if (Buy_InputEvent(evtype, scanx, chary, devid))
			return TRUE;
	}

	// Radio overlay — when open, swallow 1-8 + ESC + the bound radio
	// key so weapon binds on those scancodes don't double-fire. All
	// other input (movement, +attack, etc.) passes through so the
	// player keeps full control while the panel is up.
	if (Radio_IsOpen())
	{
		if (Radio_InputEvent(evtype, scanx, chary, devid))
			return TRUE;
	}

	// Team menu gets the remaining input when either panel didn't
	// consume it. This lets F1/F2 open on top of team selection, and
	// keeps the panels interactive while the team menu stays visible.
	if (TeamMenuIsOpen())
		return TeamMenuInputEvent(evtype, scanx, chary, devid);

	// Spectator input (post-deathdelay only, not during death cam)
	if (Spectate_IsActive() && !Spectate_InDeathCam())
	{
		if (Spectate_HandleInput(evtype, scanx, chary, devid))
			return TRUE;
	}

	// Scoreboard intercepts TAB/+showscores.  This may flip
	// hud_scoreboard_held; we read it back below to gate the
	// +attack2 mute-mode entry.  If the scoreboard handler
	// claims the event (TRUE) we still need to exit mute mode
	// on +showscores release so the mute cursor doesn't get
	// stuck on after the user lets go.
	float sb_held_before = hud_scoreboard_held;
	if (HUD_ScoreboardInputEvent(evtype, scanx, chary, devid))
	{
		if (sb_held_before && !hud_scoreboard_held && hud_voipmute_mode)
			HUD_VoIP_ExitMuteMode();
		return TRUE;
	}

	// +attack2 while +showscores is held → enter mute mode (toggle ON).
	// Mute mode stays on until +showscores is released — there's no
	// exit-on-+attack2-release path, matching the user's spec of
	// "toggle on mouse movement until +showscores is released".
	{
		string cmd_lookup = getkeybind(scanx);
		if (cmd_lookup == "+attack2"
		    && hud_scoreboard_held
		    && evtype == IE_KEYDOWN)
		{
			HUD_VoIP_EnterMuteMode();
			return TRUE;
		}
	}

	// In mute mode: forward all input to SUI (so the per-row click
	// detection registers) AND swallow primary fire so mouse1 clicks
	// don't fire the active weapon.  Mouse motion / cursor position
	// updates also go to SUI here.
	if (hud_voipmute_mode)
	{
		sui_input_event(evtype, scanx, chary, devid);

		// Cursor-position events keep the SUI cursor tracking the
		// mouse; let them through but consume.
		if (evtype == IE_MOUSEABS || evtype == IE_MOUSEDELTA)
			return TRUE;

		if (evtype == IE_KEYDOWN || evtype == IE_KEYUP)
		{
			string cmd_attack = getkeybind(scanx);
			// Suppress primary fire / mouse1 so clicking a row doesn't
			// also fire the weapon.  Also suppress +attack2 itself so
			// holding it doesn't drive secondary-fire / scope.
			if (cmd_attack == "+attack" || cmd_attack == "+attack2"
			    || scanx == K_MOUSE1)
				return TRUE;
		}
	}

	switch(evtype)
	{
	case IE_KEYDOWN:
		CSQC_UpdateLiveInputFromBind(scanx, TRUE);
		return FALSE;
	case IE_KEYUP:
		CSQC_UpdateLiveInputFromBind(scanx, FALSE);
		return FALSE;
	case IE_MOUSEDELTA:
		return FALSE;
	case IE_MOUSEABS:
		cursor_pos_x = scanx;
		cursor_pos_y = chary;
		return FALSE;
	}
	return FALSE;
};


// Estimated wire bytes per event ID (SVC + event byte + payload).
// POINTSOUND is a string → rough average. Use for the debug bandwidth HUD.
float(float ev) _net_event_bytes =
{
	if (ev == CSQC_EVENT_IMPACT)          return 22;  // svc+ev+pos[3 coord]+normal[3 byte]+mat byte+target entnum (short)+shooter entnum (byte)+is_entry (byte)
	if (ev == CSQC_EVENT_SHELL)           return 39;
	if (ev == CSQC_EVENT_MAGDROP)         return 27;
	if (ev == CSQC_EVENT_POINTSOUND)      return 34;
	if (ev == CSQC_EVENT_DEBUG_IMPACT)    return 28;
	if (ev == CSQC_EVENT_ROUND_CLEANUP)   return 2;
	if (ev == CSQC_EVENT_DAMAGE_FLASH)    return 15;  // svc+ev+dmg byte + 12 attacker origin coords
	if (ev == CSQC_EVENT_HITMARKER)       return 2;
	if (ev == CSQC_EVENT_BRUSH_DESTROY)   return 6;
	if (ev == CSQC_EVENT_SERVER_HITBOXES) return 63;  // 2 svc hdr + 55 fixed payload + 8 (f1t+bf1t)
	if (ev == CSQC_EVENT_GLASS_GIBS)      return 35;  // +5 throw bytes vs prior
	if (ev == CSQC_EVENT_PLAYER_GIBS)     return 32;  // 2 + 12 + 12 + 1 + 2 + 1 + 2 svc/event hdr
	if (ev == CSQC_EVENT_DEBRIS_GIBS)     return 39;  // +5 throw bytes vs prior
	if (ev == CSQC_EVENT_KILLFEED)        return 7;   // 2 svc hdr + 5 kill-feed bytes
	if (ev == CSQC_EVENT_WEAPON_PICKUP_SOUND) return 15;  // 2 svc hdr + 1 exclude + 12 origin
	if (ev == CSQC_EVENT_BREAKABLE_IMPACT_SOUND) return 16;  // 2 svc hdr + 1 exclude + 1 style + 12 origin
	if (ev == CSQC_EVENT_BREAKABLE_BREAK_SOUND)  return 16;  // same wire layout as impact sound
	if (ev == CSQC_EVENT_FOOTSTEP_SOUND)         return 17;  // 2 svc hdr + 1 exclude + 1 vol + 1 snd_idx + 12 origin
	if (ev == CSQC_EVENT_SLIDE_SOUND)            return 16;  // 2 svc hdr + 1 exclude + 1 variant + 12 origin
	if (ev == CSQC_EVENT_DEATH_DROP)             return 61;  // 2 svc hdr + 1 weapon + 1 slot + 24 origin/vel + ~32 model path (variable)
	if (ev == CSQC_EVENT_GRENADE_EXPLODE)        return 16;  // 2 svc hdr + 1 exclude + 12 origin + 1 sample byte
	if (ev == CSQC_EVENT_GRENADE_BOUNCE)         return 16;  // 2 svc hdr + 1 exclude + 12 origin + 1 sample byte
	if (ev == CSQC_EVENT_HL_BEAM)                return 28;  // 2 svc hdr + 1 exclude + 1 type + 24 start/end coords
	if (ev == CSQC_EVENT_SNOWSPLAT)              return 21;  // 2 svc hdr + 1 exclude + 1 flags + 12 origin + 3 normal bytes + 2 entnum
	if (ev == CSQC_EVENT_PAINTSPLAT)             return 23;  // 2 svc hdr + 1 exclude + 12 origin + 3 normal + 3 color + 2 target
	if (ev == CSQC_EVENT_CSGRENADE_EXPLODE)      return 17;  // 2 svc hdr + 1 exclude + 1 type + 12 origin + 1 sample
	if (ev == CSQC_EVENT_CSGRENADE_BOUNCE)       return 17;  // same layout as explode
	if (ev == CSQC_EVENT_C4_EXPLODE)             return 14;  // 2 svc hdr + 12 origin
	if (ev == CSQC_EVENT_DOOR_VIEWROT)           return 4;   // 2 svc hdr + 2 short delta
	if (ev == CSQC_EVENT_BUTTON_SPARK)           return 17;  // 2 svc hdr + 12 origin + 3 normal bytes
	if (ev == CSQC_EVENT_PHYSPROP_IMPACT)        return 18;  // 2 svc hdr + 12 pos + 3 normal bytes + 1 bucket
	if (ev == CSQC_EVENT_ENV_EXPLOSION)          return 17;  // 2 svc hdr + 12 origin + 2 magnitude + 1 spawnflags
	if (ev == CSQC_EVENT_SPRAY)                  return 53;  // 2 svc hdr + 2 sid + 1 owner + 12 pos + 12 normal + 12 eye + ~12 name (avg)
	if (ev == CSQC_EVENT_SPRAY_REMOVE)           return 4;   // 2 svc hdr + 2 sid
	if (ev == CSQC_EVENT_PLAYER_FLINCH)          return 5;   // 2 svc hdr + 1 victim slot + 1 hitgroup + 1 attacker slot
	if (ev == CSQC_EVENT_ENV_FADE)               return 14;  // 2 svc hdr + rgba bytes + 2 floats + 1 flags
	if (ev == CSQC_EVENT_ENV_MESSAGE)            return 34;  // 2 svc hdr + variable title key string
	if (ev == CSQC_EVENT_DAMAGE_VIEWKICK)        return 6;   // 2 svc hdr + 2 signed shorts
	if (ev == CSQC_EVENT_RADIO_CALL)             return 34;  // 2 svc hdr + ~32 voice-path string (variable)
	if (ev == CSQC_EVENT_KILL_REWARD)            return 5;   // 2 svc hdr + 2 short reward + 1 headshot byte
	if (ev == CSQC_EVENT_ROUND_REWARD)           return 5;   // 2 svc hdr + 2 short amount + 1 win byte
	if (ev == CSQC_EVENT_KILLCAM_TRACK)          return 860;  // 4 hdr + ~66 frames × 13 bytes (one-shot per death, variable)
	return 2;
};

// Last-time bookkeeping for cl_debug_footsteps cadence logs. Set to the
// event's receive time each time the CSQC_EVENT_FOOTSTEP_SOUND handler
// processes a payload (play or skip), so the `dt` field in subsequent
// lines shows the interval between received step events.
float cl_last_recv_step_time;

// (cl_local_pickup_exclude_time lives in client/cl_customdefs.qc so both
// cl_weapons.qc — compiled earlier — and cl_main.qc can see it.)

void() CSQC_Parse_Event =
{
	float first = readbyte();
	CSQC_NetStat_RecordEvent(_net_event_bytes(first));
	switch(first) {
		case CSQC_EVENT_KILLFEED:
			KillFeed_Parse();
			break;
		case CSQC_EVENT_KILLCAM_TRACK:
			Killcam_SV_ParseTrack();	// server-side killcam: the killer's recorded camera track
			break;
		case CSQC_EVENT_IMPACT:
		{
			vector pos, normal;
			pos_x = readcoord();
			pos_y = readcoord();
			pos_z = readcoord();
			// Normal is a biased signed byte (127 = 0, 0 = -1, 254 = +1);
			// server quantises it to 3 bytes to save 9 B/event. Decode
			// back to the unit-vector range [-1, +1].
			normal_x = (readbyte() - 127) * (1.0 / 127.0);
			normal_y = (readbyte() - 127) * (1.0 / 127.0);
			normal_z = (readbyte() - 127) * (1.0 / 127.0);
			float rem_mat = readbyte();
			// Target entnum for decal attach — 0 = world (static decal).
			// findfloat resolves to the CSQC-replicated brush entity so
			// bullet-hole ownership is preserved across clients.
			float rem_entnum = readshort();
			entity rem_target = world;
			if (rem_entnum > 0)
			{
				entity found = findfloat(world, entnum, rem_entnum);
				if (found) rem_target = found;
			}
			// Shooter entnum — used by the remote tracer spawner to
			// anchor the ribbon's start at the shooter's eye position.
			// 0 / out-of-range falls back to no-tracer (CSQC_BulletImpactRemote
			// skips the spawn when it can't resolve the shooter).
			float rem_shooter = readbyte();
			// is_entry: 1 = entry/primary impact (draw the tracer), 0 = penetration
			// EXIT (decal only — drawing it too gave the "two tracer lines" double).
			float rem_entry = readbyte();
			CSQC_BulletImpactRemote(pos, normal, rem_mat, rem_target, rem_shooter, rem_entry);
			break;
		}
		case CSQC_EVENT_SHELL:
		{
			float sh_type = readbyte();
			vector sh_org = readvector();
			vector sh_vel = readvector();
			vector sh_avel = readvector();
			string sh_mdl = CSQC_ShellModelForType(sh_type);
			if (!Killcam_Active())	// D: live casings must not bleed into the killcam replay
				CSQC_SpawnRemoteCasing(sh_mdl, sh_org, sh_vel, sh_avel);
			break;
		}
		case CSQC_EVENT_MAGDROP:
		{
			float mg_type = readbyte();
			vector mg_org = readvector();
			vector mg_vel = readvector();
			string mg_mdl = CSQC_MagModelForType(mg_type);
			if (!Killcam_Active())	// D: no live mag drops during the killcam replay
				CSQC_SpawnRemoteMag(mg_mdl, mg_org, mg_vel, '0 180 0');
			break;
		}
		case CSQC_EVENT_POINTSOUND:
		{
			vector snd_pos;
			snd_pos_x = readcoord();
			snd_pos_y = readcoord();
			snd_pos_z = readcoord();
			string snd_path = readstring();
			if (!Killcam_Active())	// D: mute live world sounds so only the replay plays
				pointsound(snd_pos, snd_path, 1, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_RADIO_CALL:
		{
			string radio_path = readstring();
			Radio_StartSequence(radio_path);
			break;
		}
		case CSQC_EVENT_DEBUG_IMPACT:
		{
			vector dbg_pos, dbg_eye;
			float dbg_dmg, dbg_hitgroup;
			dbg_pos_x = readcoord();
			dbg_pos_y = readcoord();
			dbg_pos_z = readcoord();
			dbg_eye_x = readcoord();
			dbg_eye_y = readcoord();
			dbg_eye_z = readcoord();
			dbg_dmg = readbyte();
			dbg_hitgroup = readbyte();
			if (cvar("cl_debug_impacts"))
			{
				// Color by hitgroup: red=head, yellow=stomach, white=chest, grey=limbs
				vector dbg_col;
				if (dbg_hitgroup == HITGROUP_HEAD)
					dbg_col = '1 0.2 0.2';
				else if (dbg_hitgroup == HITGROUP_STOMACH)
					dbg_col = '1 0.8 0.2';
				else if (dbg_hitgroup == HITGROUP_CHEST)
					dbg_col = '1 1 1';
				else if (dbg_hitgroup >= HITGROUP_LEFTARM)
					dbg_col = '0.6 0.6 0.7';
				else
					dbg_col = '0.6 0 1';  // generic/world = purple

				CSQC_AddDebugImpact(dbg_pos, dbg_eye, dbg_col, dbg_dmg, dbg_hitgroup);
			}
			break;
		}
		case CSQC_EVENT_ROUND_CLEANUP:
		{
			CSQC_BulletHolesWipeAll();
			CSQC_TracersWipeAll();
			CSQC_ShellsWipeAll();
			CSQC_ScorchWipeAll();
			CSQC_BloodsplatWipeAll();
			CSQC_MuzzleSmokeWipeAll();
			CSQC_CSGrenadeSmokeWipeAll();   // smoke-grenade puffs have an 11-17 s lifetime independent of round timing — without this they survive across rounds
			break;
		}
		case CSQC_EVENT_CLEANMODELS:
		{
			// Server "cleanmodels" — wipe casings + mags only.
			// Corpses are removed server-side and disappear via
			// SendEntity replication; nothing to do for them here.
			CSQC_ShellsWipeAll();
			break;
		}
		case CSQC_EVENT_CLEANDECALS:
		{
			// Server "cleandecals" — wipe every visual decal /
			// particle category in one frame.  Casings + corpses
			// survive (use cleanmodels for those).
			CSQC_BulletHolesWipeAll();
			CSQC_ScorchWipeAll();
			CSQC_BloodsplatWipeAll();
			CSQC_MuzzleSmokeWipeAll();
			CSQC_CSGrenadeSmokeWipeAll();
			CSQC_ClearSprays();
			break;
		}
		case CSQC_EVENT_SPRAY:
		{
			float sid    = readshort();
			readbyte();                   // owner entnum (reserved — future per-owner UI)
			vector spos;
			spos_x = readcoord(); spos_y = readcoord(); spos_z = readcoord();
			vector snrm;
			snrm_x = readcoord(); snrm_y = readcoord(); snrm_z = readcoord();
			vector seye;
			seye_x = readcoord(); seye_y = readcoord(); seye_z = readcoord();
			string sname = readstring();
			if (!Killcam_Active())	// D: no live sprays during the killcam replay
				CSQC_SpawnSprayDecal(sid, spos, snrm, seye, sname, SPRAY_QUAD_HALF, SPRAY_QUAD_HALF);	// square (unchanged)
			break;
		}
		case CSQC_EVENT_SPRAY_REMOVE:
		{
			float remove_sid = readshort();
			CSQC_RemoveSprayDecal(remove_sid);
			break;
		}
		case CSQC_EVENT_PLAYER_FLINCH:
		{
			// Set the matching proxy's vis_flinch_until so its torso
			// plays CSANIM_GUT_FLINCH / HEAD_FLINCH for a short window.
			// Server multicasts on every non-fatal hit (server-side
			// `target.health > 0` gate); the attacker may also have
			// predicted this locally in CSQC_SendHitclaim.  Both
			// write the same value, so the multicast harmlessly
			// re-stamps the attacker's prediction.
			//
			// Skipped on proxies the local client has already flagged
			// as dead — either via predicted-death (cl_predict_death)
			// or because a death snapshot arrived between the hit and
			// this event.  Without this gate, a near-lethal hit
			// followed instantly by the kill would briefly snap the
			// torso back to the flinch pose before / during the death
			// anim — the user-reported "flinch messes with death
			// animation" symptom.
			float flinch_slot     = readbyte();
			float flinch_hg       = readbyte();
			float flinch_attacker = readbyte();
			float flinch_dur  = cvar("cl_player_flinch_time");
			if (flinch_dur <= 0)
				break;   // disabled
			// nettest Patch 36: the attacker already predicted this flinch locally
			// (CSQC_SendHitclaim), so skip the server re-stamp on THEIR client — otherwise it
			// restarts the flinch anim and double-plays on the shooter's screen.  This is
			// timing-independent (works at any ping, incl. sv_minping 500, where a client-side
			// time-window latch failed).  Witnesses (local != attacker) apply it once.
			if (flinch_attacker == player_localentnum)
				break;
			entity fp = findchain(classname, "player_visual_proxy");
			while (fp)
			{
				if (fp.vis_owner_entnum == flinch_slot)
				{
					if (!fp.vis_is_dead)
					{
						fp.vis_flinch_until    = cltime + flinch_dur;
						fp.vis_flinch_hitgroup = flinch_hg;
					}
					break;
				}
				fp = fp.chain;
			}
			break;
		}
		case CSQC_EVENT_ENV_FADE:
		{
			CSQC_EnvFade_Parse();
			break;
		}
		case CSQC_EVENT_ENV_MESSAGE:
		{
			CSQC_EnvMessage_Parse();
			break;
		}
		case CSQC_EVENT_DAMAGE_FLASH:
		{
			float dmg = readbyte();
			vector atk_pos;
			atk_pos_x = readcoord();
			atk_pos_y = readcoord();
			atk_pos_z = readcoord();
			csqc_pain_flash_time = cltime;
			csqc_pain_flash_alpha = bound(0.1, dmg * 0.01, 0.6);
			// Hit indicator: server packs the attacker's world origin
			// after the damage byte.  Fall damage / world damage sends
			// the victim's own origin so the spawn helper rejects it
			// (zero relative direction).
			Hitindicator_Spawn(atk_pos);
			// Play bullet hit pain sound for the victim
			if (random() < 0.5)
				localsound("sounds/player/bullethit1.wav");
			else
				localsound("sounds/player/bullethit2.wav");
			break;
		}
		case CSQC_EVENT_DAMAGE_VIEWKICK:
		{
			float pitch = readshort() * 0.01;
			float roll = readshort() * 0.01;
			CSQC_DamageViewKick_Add(pitch, roll);
			break;
		}
		case CSQC_EVENT_DAMAGE_REPORT:
		{
			// Death-screen Given/Taken report. Server caps each list at
			// DR_HUD_CAP entries (matches the client storage). Slot is
			// 1-based on the wire (edict-num convention); HUD_DrawDamageReport
			// subtracts 1 for getplayerkeyvalue lookups.
			float n, i;
			n = readbyte();
			if (n > DR_HUD_CAP) n = DR_HUD_CAP;
			dr_g_count = n;
			for (i = 0; i < n; i = i + 1)
			{
				dr_g_slot [i] = readbyte();
				dr_g_dmg  [i] = readshort();
				dr_g_hits [i] = readbyte();
				dr_g_hp   [i] = readbyte();
			}
			n = readbyte();
			if (n > DR_HUD_CAP) n = DR_HUD_CAP;
			dr_t_count = n;
			for (i = 0; i < n; i = i + 1)
			{
				dr_t_slot [i] = readbyte();
				dr_t_dmg  [i] = readshort();
				dr_t_hits [i] = readbyte();
				dr_t_hp   [i] = readbyte();
			}
			dr_show_until = cltime + DR_HUD_DURATION;
			break;
		}
		case CSQC_EVENT_DEATH_DROP:
		{
			// Server-authoritative scatter visual for the dying local
			// player. The real SendEntity version appears after the
			// short pickup-grace window, at which point the fake expires.
			float dd_weapon = readbyte();
			float dd_slot   = readbyte();
			vector dd_org, dd_vel;
			dd_org_x = readcoord();
			dd_org_y = readcoord();
			dd_org_z = readcoord();
			dd_vel_x = readcoord();
			dd_vel_y = readcoord();
			dd_vel_z = readcoord();
			string dd_mdl = readstring();
			float dd_ping = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
			dd_ping = bound(0.05, dd_ping, 1.0);
			CSQC_SpawnFakeDropAt(dd_weapon, dd_slot, dd_mdl, dd_org, dd_vel,
			                     dd_ping + WEAPON_DROP_PICKUP_DELAY + 0.1,
			                     0, 0, 0);
			break;
		}
		case CSQC_EVENT_GRENADE_EXPLODE:
		{
			// Grenade detonation FX (sprite + particles + light + boom).
			// Server multicasts to all PVS clients with the shooter's
			// entnum as the exclude byte; the shooter skips because
			// they already played everything locally via
			// CSQC_FakeHLGrenadeExplode's predict path. (CSQC-side
			// entnum compare is the actual working owner-exclude
			// pattern in this codebase — dimension_send doesn't filter
			// multicasts the way you'd expect, so the explicit byte is
			// load-bearing.)
			float ge_exclude = readbyte();
			vector ge_pos;
			ge_pos_x = readcoord();
			ge_pos_y = readcoord();
			ge_pos_z = readcoord();
			float ge_snd = readbyte();
			if (ge_exclude == player_localentnum)
				break;
			te_explosion(ge_pos);            // particles
			CSQC_SpawnExplodeSprite(ge_pos); // classic Quake explode sprite
			CSQC_AddExplosionLight(ge_pos);
			CSQC_SpawnScorchDecal(ge_pos, 2);
			string es;
			if      (ge_snd == 0) es = "sounds/weapons/wpn_hlgrenade/explode1.wav";
			else if (ge_snd == 1) es = "sounds/weapons/wpn_hlgrenade/explode2.wav";
			else                  es = "sounds/weapons/wpn_hlgrenade/explode3.wav";
			pointsound(ge_pos, es, 1, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_GRENADE_BOUNCE:
		{
			// Grenade surface bounce sound. Same exclude-byte pattern as
			// CSQC_EVENT_GRENADE_EXPLODE — shooter skips because the
			// CSQC fake's CSQC_FakeHLGrenadeBounce already played the
			// bounce locally.
			float gbn_exclude = readbyte();
			vector gbn_pos;
			gbn_pos_x = readcoord();
			gbn_pos_y = readcoord();
			gbn_pos_z = readcoord();
			float gbn_snd = readbyte();
			if (gbn_exclude == player_localentnum)
				break;
			string bs;
			if      (gbn_snd == 0) bs = "sounds/weapons/wpn_hlgrenade/hit1.wav";
			else if (gbn_snd == 1) bs = "sounds/weapons/wpn_hlgrenade/hit2.wav";
			else                   bs = "sounds/weapons/wpn_hlgrenade/hit3.wav";
			pointsound(gbn_pos, bs, 1, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_CSGRENADE_EXPLODE:
		{
			float cg_exclude = readbyte();
			float cg_wep = readbyte();
			vector cg_pos;
			cg_pos_x = readcoord();
			cg_pos_y = readcoord();
			cg_pos_z = readcoord();
			float cg_snd = readbyte();
			if (cg_exclude != player_localentnum)
				CSQC_CSGrenadeExplodeFX(cg_wep, cg_pos, cg_snd);
			break;
		}
		case CSQC_EVENT_C4_EXPLODE:
		{
			vector c4_pos;
			c4_pos_x = readcoord();
			c4_pos_y = readcoord();
			c4_pos_z = readcoord();
			CSQC_C4_SpawnExplosionSprite(c4_pos);
			break;
		}
		case CSQC_EVENT_DOOR_VIEWROT:
		{
			// Private yaw-delta event sent by func_door_rotating
			// while it carries this player.  Pitch / roll are
			// left untouched so the player's vertical look
			// survives — this is the whole reason the previous
			// fixangle approach didn't work.
			//
			// Accumulate into a per-tick offset; CSQC_Input_Frame
			// folds the offset into input_angles after the engine
			// has stamped its mouse-tracked yaw, so the bump is
			// what gets buffered into the next outgoing command
			// and the engine's view state then catches up.
			float dvr_delta = readshort() * 0.01;
			csqc_door_yaw_offset = csqc_door_yaw_offset + dvr_delta;
			break;
		}
		case CSQC_EVENT_ENV_EXPLOSION:
		{
			vector ee_pos;
			ee_pos_x = readcoord();
			ee_pos_y = readcoord();
			ee_pos_z = readcoord();
			float ee_mag   = readshort();
			float ee_flags = readbyte();
			CSQC_EnvExplosionFX(ee_pos, ee_mag, ee_flags);
			break;
		}
		case CSQC_EVENT_BUTTON_SPARK:
		{
			// Sparker idle pulse for SPARKS-flagged func_button.
			// Server multicasts the emit position to PVS each
			// audible click; we fire weapons.metal_impact — the
			// same particle the user already confirmed working
			// when shooting electronics / computer surfaces.
			//
			// Direction is the outward normal off the press face
			// (i.e. -movedir on the server side), encoded as 3
			// bytes biased to -1..1.  Multiplied by 200 it matches
			// the velocity scale used by Impact_SpawnParticles.
			vector bs_pos;
			bs_pos_x = readcoord();
			bs_pos_y = readcoord();
			bs_pos_z = readcoord();
			vector bs_norm;
			bs_norm_x = (readbyte() - 128) / 127;
			bs_norm_y = (readbyte() - 128) / 127;
			bs_norm_z = (readbyte() - 128) / 127;
			Impact_ResolveAll();
			float bs_id = impact_effect_metal;
			if (bs_id == 0)
				bs_id = particleeffectnum("weapons.metal_impact");
			if (bs_id != -1 && bs_id != 0)
				pointparticles(bs_id, bs_pos, bs_norm * 200, 1);
			break;
		}
		case CSQC_EVENT_PHYSPROP_IMPACT:
		{
			// Filing-cabinet contact smoke (server detects the impact/slide; the sound
			// is server-side sound(), this event is the smoke only).  bucket: 0 slide /
			// 1 soft / 2 hard → a harder hit pushes more smoke off the surface (2 puffs).
			vector pp_pos;
			pp_pos_x = readcoord();
			pp_pos_y = readcoord();
			pp_pos_z = readcoord();
			vector pp_norm;
			pp_norm_x = (readbyte() - 128) / 127;
			pp_norm_y = (readbyte() - 128) / 127;
			pp_norm_z = (readbyte() - 128) / 127;
			float pp_bucket = readbyte();
			float pp_sid = particleeffectnum("weapons.physprop_smoke");
			if (pp_sid != -1 && pp_sid != 0)
				pointparticles(pp_sid, pp_pos, pp_norm * (pp_bucket == 2 ? 30 : 12),
				               pp_bucket == 2 ? 2 : 1);
			// Slide (bucket 0): throw metal sparks off the scraped surface using
			// the SAME effect a bullet impact spawns (weapons.metal_impact,
			// normal * 100, count 1 — see cl_bulletimpact.qc), so dragging the
			// cabinet along a wall/floor sparks like it's being ground down.
			if (pp_bucket == 0)
			{
				float pp_spark = particleeffectnum("weapons.metal_impact");
				if (pp_spark != -1 && pp_spark != 0)
					pointparticles(pp_spark, pp_pos, pp_norm * 100, 1);
			}
			break;
		}
		case CSQC_EVENT_CSGRENADE_BOUNCE:
		{
			float cb_exclude = readbyte();
			float cb_wep = readbyte();
			vector cb_pos;
			cb_pos_x = readcoord();
			cb_pos_y = readcoord();
			cb_pos_z = readcoord();
			float cb_snd = readbyte();
			if (cb_exclude != player_localentnum)
				CSQC_CSGrenadeBounceFX(cb_wep, cb_snd, cb_pos);
			break;
		}
		case CSQC_EVENT_HL_BEAM:
		{
			HLBeam_Parse();
			break;
		}
		case CSQC_EVENT_SNOWSPLAT:
		{
			float ss_exclude = readbyte();
			float ss_flags = readbyte();
			vector ss_pos, ss_normal;
			ss_pos_x = readcoord();
			ss_pos_y = readcoord();
			ss_pos_z = readcoord();
			ss_normal_x = (readbyte() - 127) * (1.0 / 127.0);
			ss_normal_y = (readbyte() - 127) * (1.0 / 127.0);
			ss_normal_z = (readbyte() - 127) * (1.0 / 127.0);
			float ss_entnum = readshort();
			entity ss_target = world;
			if (ss_entnum > 0)
			{
				entity ss_found = findfloat(world, entnum, ss_entnum);
				if (ss_found) ss_target = ss_found;
			}
			if (ss_flags & 1)
				CSQC_SpawnSnowSplat(ss_pos, ss_normal, ss_target);
			if (ss_exclude != player_localentnum)
				pointsound(ss_pos, SNOWBALL_HIT_SOUND, 1, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_PAINTSPLAT:
		{
			float pbs_exclude = readbyte();
			vector pbs_pos, pbs_normal, pbs_color;
			pbs_pos_x = readcoord();
			pbs_pos_y = readcoord();
			pbs_pos_z = readcoord();
			pbs_normal_x = (readbyte() - 127) * (1.0 / 127.0);
			pbs_normal_y = (readbyte() - 127) * (1.0 / 127.0);
			pbs_normal_z = (readbyte() - 127) * (1.0 / 127.0);
			pbs_color_x = readbyte() * (1.0 / 255.0);
			pbs_color_y = readbyte() * (1.0 / 255.0);
			pbs_color_z = readbyte() * (1.0 / 255.0);
			float pbs_entnum = readshort();
			entity pbs_target = world;
			if (pbs_entnum > 0)
			{
				entity pbs_found = findfloat(world, entnum, pbs_entnum);
				if (pbs_found) pbs_target = pbs_found;
			}
			if (pbs_exclude != player_localentnum)
				CSQC_SpawnPaintSplat(pbs_pos, pbs_normal, pbs_target, pbs_color, PAINTBALL_SPLAT_HALF_SIZE);
			break;
		}
		case CSQC_EVENT_GLASS_GIBS:
		{
			// Attacker-exclude: the shooter's CSQC_PredictBreakableBreak
			// already spawned matching gibs locally, so skip the server
			// copy to avoid doubled debris.
			float gb_exclude = readbyte();
			vector gb_mins, gb_maxs;
			gb_mins_x = readcoord();
			gb_mins_y = readcoord();
			gb_mins_z = readcoord();
			gb_maxs_x = readcoord();
			gb_maxs_y = readcoord();
			gb_maxs_z = readcoord();
			float gb_count = readbyte();
			float gb_dmg = readshort();
			float gb_throw_mode = readbyte();
			vector gb_throw_dir;
			gb_throw_dir_x = (readbyte() - 127) * (1.0 / 127.0);
			gb_throw_dir_y = (readbyte() - 127) * (1.0 / 127.0);
			gb_throw_dir_z = (readbyte() - 127) * (1.0 / 127.0);
			float gb_throw_force = readbyte();
			if ((gb_exclude == 0 || gb_exclude != player_localentnum) && !Killcam_Active())
				CSQC_SpawnGlassGibs(gb_mins, gb_maxs, gb_count, gb_dmg, 0,
				                    gb_throw_mode, gb_throw_dir, gb_throw_force);	// D: no live gibs in the killcam
			break;
		}
		case CSQC_EVENT_PLAYER_GIBS:
		{
			vector pg_pos, pg_dir;
			pg_pos_x = readcoord();
			pg_pos_y = readcoord();
			pg_pos_z = readcoord();
			pg_dir_x = readcoord();
			pg_dir_y = readcoord();
			pg_dir_z = readcoord();
			float pg_count = readbyte();
			float pg_dmg = readshort();
			float pg_target_slot = readbyte();

			// Dedupe against cl_predict_death: if this client already
			// fired gibs for the same victim within the staleness
			// window, skip the server's authoritative spawn so the
			// gibs/sound/particles don't visibly double up at high
			// ping.  Look up the proxy by entnum; if no proxy or no
			// recent predicted-gib latch, fall through and play.
			float pg_skip = 0;
			if (pg_target_slot > 0)
			{
				entity vis = findfloat(world, vis_owner_entnum, pg_target_slot);
				if (vis && vis.classname == "player_visual_proxy"
				    && vis.vis_pred_gibs_at_time > 0)
				{
					float ping_s = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
					float window = bound(0.05, ping_s + 0.20, 3.0);
					if (time - vis.vis_pred_gibs_at_time <= window)
						pg_skip = 1;
				}
			}
			// No live player gibs during the killcam.  ALSO suppress the LOCAL victim's
			// live head-gibs (cl_killcam replays them at the kill moment) so they aren't
			// already lying on the ground during the rewind.  pg_target_slot is a 1-based
			// num_for_edict (server sv_weapons.qc), so compare player_localentnum.  When
			// cl_killcam is off the clause is false -> live gibs spawn normally.
			float pg_local_kc = (cvar("cl_killcam") && pg_target_slot == player_localentnum);
			if (!pg_skip && !Killcam_Active() && !pg_local_kc)
				CSQC_SpawnPlayerGibs(pg_pos, pg_dir, pg_count, pg_dmg);
			break;
		}
		case CSQC_EVENT_DEBRIS_GIBS:
		{
			// Attacker-exclude: same pattern as CSQC_EVENT_GLASS_GIBS.
			float db_exclude = readbyte();
			vector db_mins, db_maxs;
			db_mins_x = readcoord();
			db_mins_y = readcoord();
			db_mins_z = readcoord();
			db_maxs_x = readcoord();
			db_maxs_y = readcoord();
			db_maxs_z = readcoord();
			float db_style    = readbyte();
			float db_count    = readbyte();
			float db_dmg      = readshort();
			float db_idx      = readshort();
			float db_alpha    = readbyte();
			float db_throw_mode = readbyte();
			vector db_throw_dir;
			db_throw_dir_x = (readbyte() - 127) * (1.0 / 127.0);
			db_throw_dir_y = (readbyte() - 127) * (1.0 / 127.0);
			db_throw_dir_z = (readbyte() - 127) * (1.0 / 127.0);
			float db_throw_force = readbyte();
			if ((db_exclude == 0 || db_exclude != player_localentnum) && !Killcam_Active())
				CSQC_SpawnDebrisGibs(db_mins, db_maxs, db_style, db_count,
				                     db_dmg, db_idx, db_alpha, 0,
				                     db_throw_mode, db_throw_dir, db_throw_force);	// D: no live debris in the killcam
			break;
		}
		case CSQC_EVENT_WEAPON_PICKUP_SOUND:
		{
			// Server-routed pickup sound. The pickup-er's entnum is in
			// the payload — that client already played the sound via
			// CSQC_PredictPickupWeapon, so they skip. Everyone else in
			// PVS plays pointsound at the pickup origin.
			float ps_exclude = readbyte();
			vector ps_pos;
			ps_pos_x = readcoord();
			ps_pos_y = readcoord();
			ps_pos_z = readcoord();
			if (ps_exclude == player_localentnum)
			{
				// WE are the picker.  Play locally unless CSQC_Predict
				// PickupWeapon already fired recently — the latch
				// stores cltime so the window needs to exceed the
				// RTT for a high-ping predict→confirm round trip
				// (up to ~2s at sv_minping 999).  Derive the gate
				// from actual ping so rapid successive catchup
				// pickups don't get suppressed by a stale latch at
				// low ping.
				float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
				ping_est = bound(0.05, ping_est, 1.5);
				float predict_window = ping_est * 2 + 0.5;
				if ((cltime - cl_local_predict_sound_time) > predict_window)
					localsound("sounds/weapons/pickup1.wav");
			}
			else
			{
				pointsound(ps_pos, "sounds/weapons/pickup1.wav", 1, ATTN_NORM);
			}
			break;
		}
		case CSQC_EVENT_BREAKABLE_IMPACT_SOUND:
		{
			// Attacker-excluded breakable thump. The shooter already
			// predicted the variant via Impact_PlayBreakableSound
			// inside CSQC_BulletImpact, so they skip. Remote clients
			// pick a variant from the same BREAKABLE_* style byte and
			// play it at the brush center.
			float bi_exclude = readbyte();
			float bi_style   = readbyte();
			vector bi_pos;
			bi_pos_x = readcoord();
			bi_pos_y = readcoord();
			bi_pos_z = readcoord();
			if (bi_exclude == 0 || bi_exclude != player_localentnum)
				Impact_PlayBreakableSound(bi_pos, bi_style);
			break;
		}
		case CSQC_EVENT_BREAKABLE_BREAK_SOUND:
		{
			// Same attacker-exclude pattern as the impact thump. The
			// shooter's CSQC_PredictBreakableBreak already fired the
			// break sound the moment they landed the lethal shot —
			// skip here so they don't hear a ping-delayed second copy.
			float bk_exclude = readbyte();
			float bk_style   = readbyte();
			vector bk_pos;
			bk_pos_x = readcoord();
			bk_pos_y = readcoord();
			bk_pos_z = readcoord();
			if (bk_exclude == 0 || bk_exclude != player_localentnum)
				Impact_PlayBreakableBreakSound(bk_pos, bk_style);
			break;
		}
		case CSQC_EVENT_FOOTSTEP_SOUND:
		{
			// Stepper's CSQC already played this via localsound in
			// PM_EmitStepSound on the non-replay prediction tick. Remote
			// clients receive it here via the normal PVS multicast path.
			// Sound is a byte enum (FS_SOUND_*); FS_SoundName rebuilds
			// the path string.
			float fs_exclude = readbyte();
			float fs_vol     = readbyte() / 255;
			float fs_snd_idx = readbyte();
			string fs_snd    = FS_SoundName(fs_snd_idx);
			vector fs_pos;
			fs_pos_x = readcoord();
			fs_pos_y = readcoord();
			fs_pos_z = readcoord();

			float fs_is_own_echo = (fs_exclude != 0 && fs_exclude == player_localentnum);

			if (cvar("cl_debug_footsteps"))
			{
				float fs_dt = cl_last_recv_step_time > 0 ? (time - cl_last_recv_step_time) : 0;
				if (fs_is_own_echo)
					print(sprintf("^3[step-recv-skip]^7 t=%.3f dt=%.3f exclude=%g me=%g snd=%s (own echo dropped)\n",
					              time, fs_dt, fs_exclude, player_localentnum, fs_snd));
				else
					print(sprintf("^2[step-recv-play]^7 t=%.3f dt=%.3f exclude=%g me=%g snd=%s vol=%.2f\n",
					              time, fs_dt, fs_exclude, player_localentnum, fs_snd, fs_vol));
				cl_last_recv_step_time = time;
			}

			if (!fs_is_own_echo)
				pointsound(fs_pos, fs_snd, fs_vol, ATTN_NORM);
			break;
		}
		case CSQC_EVENT_SLIDE_SOUND:
		{
			// The slider's own CSQC plays this instantly via an edge-latch in
			// CSQC_Input_Frame (no ping lag). Remote clients receive it here; the
			// exclude byte drops the slider's own echo so they never hear it twice.
			float sl_exclude = readbyte();
			float sl_variant = readbyte();
			vector sl_pos;
			sl_pos_x = readcoord();
			sl_pos_y = readcoord();
			sl_pos_z = readcoord();
			if (!(sl_exclude != 0 && sl_exclude == player_localentnum))
			{
				// pointsound is the one that actually plays for remotes — a CSQC
				// sound() on a player_visual_proxy is silent (its .entnum is the
				// SERVER number, not the CSQC edict slot). FTE's falloff is LINEAR
				// to a true zero at 1000/attenuation units, so ATTN_NORM (1.0) cut
				// to dead silence at exactly 1000u — that hard arithmetic edge is
				// the "instant cutoff". attenuation 0.5 doubles the radius to
				// ~2000u so the ramp is longer and tapers off smoothly. Also
				// re-anchor at the slider's CURRENT proxy origin instead of the
				// stale server engage-point sl_pos (proxy carries the slider's
				// slot as vis_owner_entnum == the exclude byte; modelindex guards
				// a real proxy). vol 0.4 — lowered for other players (the gentler
				// 0.5 attenuation raised mid-range loudness, so trim the volume).
				vector sl_play = sl_pos;
				entity sl_p = findfloat(world, vis_owner_entnum, sl_exclude);
				if (sl_p && sl_p.modelindex)
					sl_play = sl_p.origin;
				pointsound(sl_play, sprintf("sounds/player/slide%g.wav", sl_variant), 0.4, 0.5);
			}
			break;
		}
		case CSQC_EVENT_KILL_REWARD:
		{
			float kr_reward = readshort();
			float kr_hs     = readbyte();
			HUD_OnKillReward(kr_reward, kr_hs);
			break;
		}
		case CSQC_EVENT_ROUND_REWARD:
		{
			float rr_amount = readshort();
			float rr_won    = readbyte();
			HUD_OnRoundReward(rr_amount, rr_won);
			break;
		}
		case CSQC_EVENT_BRUSH_DESTROY:
		{
			// Server-side func_breakable was destroyed.  Hide the replicated
			// CSQC brush immediately (drawmask + solid) and drop its
			// bullet-hole decals.  Keep the model loaded — the next
			// SendEntity snapshot carries broken=1 and on round restart
			// flips to 0, so drawmask/solid snap back on with no setmodel
			// round-trip needed.  Do NOT remove() — PVSF_NOREMOVE and the
			// server-entnum→CSQC-slot link must survive the break/reset
			// cycle.
			float sv_entnum = readfloat();
			entity ent = findfloat(world, entnum, sv_entnum);
			if (ent)
			{
				CSQC_BulletHolesRemoveByOwner(ent);

				// Catch-up path for client-miss / server-hit. The break-
				// sound and gib events are attacker-excluded, so if the
				// attacker's local trace missed (but the server's lag-
				// compensated trace connected), they'd otherwise see the
				// brush vanish silently. Fire the missing feedback here
				// using the replicated brush fields. Skip when our own
				// prediction already handled it — otherwise correctly-
				// predicted breaks double up with a ping-delayed echo.
				if (!ent.brush_broken_predicted)
				{
					if (cvar("developer"))
						print(sprintf("^3[break-catchup]^7 brush ^2#%g^7 style=%g — server broke it, no local prediction, firing delayed fx\n",
						              sv_entnum, ent.brush_material));

					vector cd_center = (ent.absmin + ent.absmax) * 0.5;
					Impact_PlayBreakableBreakSound(cd_center, ent.brush_material);

					float cd_ds = max(ent.brush_max_health, 20);
					// Server-confirmed catch-up has no damage-direction
					// info (we never predicted the break), so always
					// fall back to the random throw — matches the look
					// the user would have seen pre-prediction anyway.
					if (ent.brush_material == 0 /*BREAKABLE_GLASS*/)
						CSQC_SpawnGlassGibs(ent.absmin, ent.absmax,
						                    ent.brush_cnt, cd_ds, 0,
						                    0, '0 0 0', 0);
					else
						CSQC_SpawnDebrisGibs(ent.absmin, ent.absmax,
						                     ent.brush_material, ent.brush_cnt,
						                     cd_ds, 0, 0, 0,
						                     0, '0 0 0', 0);
				}
				else if (cvar("developer"))
				{
					print(sprintf("^2[break-confirm]^7 brush ^2#%g^7 style=%g — server confirmed prediction\n",
					              sv_entnum, ent.brush_material));
				}

				// Server-confirmed truth. brush_broken_confirmed short-
				// circuits the prediction-timeout rollback in
				// CSQC_BreakPredict_Expire so a legitimate slow
				// confirmation doesn't get un-hidden.
				ent.brush_broken_confirmed = 1;

				ent.drawmask = 0;
				ent.solid    = SOLID_NOT;
			}
			break;
		}
		case CSQC_EVENT_HITMARKER:
		{
			// Server-confirmed hit — debounce to avoid double-play if client already triggered
			if (cvar("cl_hitmarker") && (cltime - csqc_hitmarker_time > 0.2))
			{
				localsound("sounds/weapons/hitmarker.wav");
				HUD_TriggerHitmarker();
			}
			break;
		}
		case CSQC_EVENT_SERVER_HITBOXES:
		{
			float hb_entnum = readbyte();
			float sv_mdlidx = readshort();
			vector sv_org;
			sv_org_x = readcoord();
			sv_org_y = readcoord();
			sv_org_z = readcoord();
			vector sv_ang;
			sv_ang_x = readfloat();
			sv_ang_y = readfloat();
			sv_ang_z = readfloat();
			float sv_fr = readbyte();
			float sv_bfr = readbyte();
			float sv_bb = readbyte();
			float sv_f1t = readfloat();
			float sv_bf1t = readfloat();
			float sv_sbf = readfloat();
			float sv_sb2f = readfloat();
			float sv_bc1 = readfloat();
			float sv_bc2 = readfloat();
			float sv_bc3 = readfloat();
			float sv_bc4 = readfloat();
			float sv_mode = readbyte();  // 1 = per-shot snapshot, 2 = continuous
			if (sv_mode == 2)
				CSQC_UpdateContinuousHitbox(hb_entnum, sv_mdlidx, sv_org, sv_ang, sv_fr, sv_bfr, sv_bb, sv_f1t, sv_bf1t, sv_sbf, sv_sb2f, sv_bc1, sv_bc2, sv_bc3, sv_bc4);
			else
				CSQC_AddServerHitbox(sv_mdlidx, sv_org, sv_ang, sv_fr, sv_bfr, sv_bb, sv_f1t, sv_bf1t, sv_sbf, sv_sb2f, sv_bc1, sv_bc2, sv_bc3, sv_bc4);
			break;
		}
		default:
			printf("No action for byte %f\n", first);
			break;
	}
};


float(string key, string val) find_player_id =
{
	for (int currentindex = 0; currentindex < maxclients; currentindex++)
	{
		if (getplayerkeyvalue(currentindex, key) == val) return currentindex;
	}
	return -1;
}

void(string printmsg, float printlvl) CSQC_Parse_Print =
{
	print(printmsg);
};
