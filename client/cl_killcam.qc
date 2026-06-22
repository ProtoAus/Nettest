// client/cl_killcam.qc
// ----------------------------------------------------------------------------
// Rewind-replay killcam (MW2-style).  Continuously ring-buffers every visible
// player's pose + weapon-anim state (from the player_visual_proxy stream the
// client already receives).  On local death, the kill-feed tells us the killer
// (no server change) and we replay the last ~2s from the killer's POV: the
// camera sits at the killer's recorded eye, their viewmodel is rebuilt via
// CSQC_AddRemoteViewmodel, and every OTHER player's proxy is re-posed from the
// buffer (reusing the normal proxy render).  Then we hand off to live spectate.
//
// Smoothness: poses are recorded at KC_HZ and INTERPOLATED between the two ring
// frames that bracket the current replay time (origin lerp + shortest-path
// angle lerp), so playback is smooth regardless of the record rate.
//
// Pure CSQC.  Compile order: after cl_weapons.qc (CSQC_AddRemoteViewmodel) +
// cl_spectate.qc, before cl_killfeed.qc (Killcam_Begin) + cl_main.qc (hooks).
// ----------------------------------------------------------------------------

const float KC_RING     = 330;      // ring frames — buffer span = KC_RING / tickrate seconds (≈11s @ 30Hz default, ≈2.6s @ 128Hz max)
const float KC_SLOTS    = 32;       // player slots (1-based entnum)
const float KC_TICKRATE = 30;       // default record Hz (cvar cl_killcam_tickrate, clamp 10..128)
const float KC_LOOKBACK = 2.0;      // default seconds rewound before the kill (cvar override)
const float KC_DURATION = 3.5;      // default total killcam length (cvar override)
const float KC_CAM_DAMP = 9;        // camera low-pass time constant (exp damp; higher = snappier)

vector kc_origin   [KC_SLOTS * KC_RING];
vector kc_eyeang   [KC_SLOTS * KC_RING];  // (pitch, yaw, 0)
float  kc_wepid    [KC_SLOTS * KC_RING];
float  kc_wstate   [KC_SLOTS * KC_RING];
float  kc_wpaction [KC_SLOTS * KC_RING];
float  kc_animstart[KC_SLOTS * KC_RING];
float  kc_botframe [KC_SLOTS * KC_RING];
float  kc_topframe [KC_SLOTS * KC_RING];
float  kc_anim_bottime[KC_SLOTS * KC_RING];  // K1: vis_anim_bottom_time (locomotion clock)
float  kc_anim_toptime[KC_SLOTS * KC_RING];  // K1: vis_anim_top_time (aim clock)
float  kc_legtwist [KC_SLOTS * KC_RING];     // strafe leg_twist (drives subblendfrac + spine YawBone)
float  kc_lifeserial[KC_SLOTS * KC_RING];    // per-frame vis_life_serial — reject cross-life frames
float  kc_valid    [KC_SLOTS * KC_RING];
float  kc_rtime    [KC_RING];

float  kc_head;
float  kc_last_rec;

float  killcam_on;
float  killcam_killer;       // 1-based entnum
float  killcam_death_time;   // rewind/aftermath boundary — the REAL death time S (see Killcam_DeathWatch)
float  killcam_real_death_time;  // S latched at the STAT_IS_DEAD 0->1 edge (0 = alive); seeds killcam_death_time
string killcam_killer_name;

float  kc_posed;             // 1 while proxies are overridden by a replay frame

// Bracket result (set by Killcam_Bracket).
float  kc_lerp_f0, kc_lerp_f1, kc_lerp_frac;

// SERVER-sent killer camera track (sv_killcam.qc) — fills the rewind's out-of-PVS
// gap.  Killer-only (one track), so no slot dimension.  Frames carry a DELTA before
// the kill (not an absolute time): the effective replay-time is computed at bracket
// time as killcam_death_time - kc_srv_delta[i], so the blob can arrive on its own
// (reliable) channel before OR after the killfeed sets killcam_death_time.
vector kc_srv_origin[KC_RING];
float  kc_srv_pitch [KC_RING];
float  kc_srv_yaw   [KC_RING];
float  kc_srv_wstate[KC_RING];
float  kc_srv_wepid [KC_RING];
float  kc_srv_delta [KC_RING];	// seconds BEFORE the kill
float  kc_srv_valid [KC_RING];
float  kc_srv_count;		// frames written (0 = no track)
float  kc_srv_killer;		// killer slot this track is for (must match killcam_killer)
float  kc_srv_f0, kc_srv_f1, kc_srv_frac;	// Killcam_BracketServer result
float  kc_cam_source;		// what drove the camera THIS frame (1 = client buffer, 2 = SERVER track, 3 = hold) — for cl_killcam_debug

// Camera smoothing (low-pass the raw recorded aim like the spec cam).
vector kc_cam_smooth_org, kc_cam_smooth_ang;
float  kc_cam_smooth_valid;

// Camera RECOIL.  sv_gunkick is a LOCAL-predicted-player-only camera spring (the
// observed shooter's view_kick_* is never networked), so reproduce it locally: an
// upward pitch impulse on each killer FIRE edge that decays back.  Gated on sv_gunkick.
float  kc_cam_kick_pitch;

float  kc_killerstate_animstart;	// out-param for Killcam_KillerState
float  kc_replay_killer_wepid;		// killer's weapon this replay frame (for the killcam crosshair)
float  kc_last_fire_action;		// killer action-id we last played a killcam fire sound for (H)
float  kc_last_fx_action;		// killer action-id we last spawned killcam shot FX (muzzle/tracer) for

// Tunables (cvar-driven so the user can tune the rewind window / length / sampling).
float() Killcam_Tickrate =
{
	float v = cvar("cl_killcam_tickrate");
	if (v <= 0) v = KC_TICKRATE;
	return bound(10, v, 128);		// record Hz
};
// Slow-mo aftermath: continue the replay PAST the kill at this playback rate (0 = off,
// reverts to the clamp-at-death behaviour).  AftermathWindow = seconds of post-kill
// death anim to record + replay (0 when slow-mo off).  Defined ABOVE Killcam_Lookback
// because the lookback clamp must subtract the aftermath span from the ring budget.
float() Killcam_Slowmo = { return bound(0, cvar("cl_killcam_slowmo"), 1); };
float() Killcam_AftermathWindow = { return (Killcam_Slowmo() > 0) ? bound(0, cvar("cl_killcam_aftermath"), 4) : 0; };
float() Killcam_Lookback =
{
	float v = cvar("cl_killcam_lookback");
	if (v <= 0) v = KC_LOOKBACK;
	// The ring must hold lookback + aftermath (the aftermath keeps recording PAST the
	// kill); subtract the aftermath span so a high tickrate / large aftermath can't wrap
	// the recording over the oldest lookback frames.  Floor so it stays positive.
	float maxspan = (KC_RING - 2) / Killcam_Tickrate() - Killcam_AftermathWindow();
	if (maxspan < 0.5) maxspan = 0.5;
	return (v > maxspan) ? maxspan : v;
};
float() Killcam_Duration =
{
	float v = cvar("cl_killcam_duration"); if (v <= 0) v = KC_DURATION;
	float sm = Killcam_Slowmo();
	if (sm > 0)
	{
		// Active window must cover the rewind (1x) + the slow aftermath + a brief hold.
		float needed = Killcam_Lookback() + Killcam_AftermathWindow() / sm + 0.5;
		if (needed > v) v = needed;
	}
	return v;
};
// Seconds of normal third-person death cam BEFORE the killcam rewind takes over.
// Held until at least the death ANIMATION finishes, so switching to the rewind
// doesn't freeze the death anim early.  Death-anim length is the local victim
// corpse's frameduration, cached per killcam (kc_death_anim_dur; -1 = whiffed).
float  kc_death_anim_dur;
float() Killcam_Delay =
{
	float d = bound(0, cvar("cl_killcam_delay"), 10);	// the user's death-cam duration (was capped at 3)
	// With slow-mo ON the death-cam delay must be at least the AFTERMATH window: the
	// victim's death anim is recorded LIVE during the delay (the replay isn't posing
	// yet), so the slow-mo rewind can replay it.  A brief 3rd-person glimpse of the
	// death during this window then becomes the dramatic slow-mo from the killer POV.
	if (Killcam_Slowmo() > 0)
	{
		float aw = Killcam_AftermathWindow() + 0.2;
		if (aw > d) d = aw;
	}
	// Death-anim HOLD only when slow-mo is OFF (Part 11 — don't cut the death anim).
	if (Killcam_Slowmo() <= 0)
	{
		if (kc_death_anim_dur == 0)		// not resolved yet — the corpse can lag the killfeed
		{
			entity c;
			for (c = findchain(classname, "player_visual_proxy"); c; c = c.chain)
				if (c.vis_owner_entnum == player_localentnum && c.vis_is_dead && c.modelindex)
				{
					float dd = frameduration(c.modelindex, c.vis_anim_bottom);
					if (dd > 0) kc_death_anim_dur = dd + 0.2;	// + settle margin
					break;
				}
			if (kc_death_anim_dur == 0 && (cltime - killcam_death_time) > 1.0)
				kc_death_anim_dur = -1;	// give up after 1s (gibbed / no corpse)
		}
		if (kc_death_anim_dur > d)
			d = kc_death_anim_dur;
	}
	return bound(0, d, 10);				// cap so the killcam can never hang on the death cam
};

float() Killcam_Active =
{
	if (!killcam_on || !getstatf(STAT_IS_DEAD) || killcam_killer < 1)
		return FALSE;
	// Hold the third-person death cam for cl_killcam_delay seconds first, THEN
	// run the killcam for cl_killcam_duration seconds.
	float t = cltime - killcam_death_time - Killcam_Delay();
	return t >= 0 && t < Killcam_Duration();
};

// TRUE on a frame where Killcam_Replay actually stamped proxies (a successful
// bracket).  The predraw reads this so a failed-bracket frame doesn't hide
// every proxy.  Forward-declared in cl_player.qc (compiled before this file).
float() Killcam_IsPosing = { return kc_posed; };

// Put every proxy (+ its bone-mirrored weapon) back to fully visible.  The proxy
// network update never resets .alpha, so a replay's alpha=-1 would otherwise
// persist and hide bodies after respawn ("walking gun, no body").
void() Killcam_RestoreProxies =
{
	entity vp;
	for (vp = findchain(classname, "player_visual_proxy"); vp; vp = vp.chain)
	{
		vp.alpha = 1;
		if (vp.vis_weapon_ent)
			vp.vis_weapon_ent.alpha = 1;
		vp.vis_killcam_posed = 0;		// K4: clear the per-frame stamp
		vp.vis_kc_replay_valid = 0;		// foot-clock reseeds on the next killcam
		vp.vis_force_rebuild = 1;		// force ONE skel rebuild — a corpse hidden during the
							// replay (P1 early-returns BEFORE the rebuild) never built
							// its death pose, so it'd render upright/bind ("frozen dead
							// bodies"); this re-solves it once, then it re-freezes settled
		// Snap proxies the replay MOVED back to their pre-killcam pose.  Out-of-PVS
		// proxies get no network update to fix the replay origin / velocity=0, so
		// without this they freeze ("a lot of frozen playermodels" after respawn).
		// A corpse that appeared mid-replay was hidden (never vis_kc_saved) — the
		// alpha=1 above makes it visible again at its networked (frozen) origin.
		if (vp.vis_kc_saved)
		{
			setorigin(vp, vp.vis_kc_save_origin);
			vp.velocity  = vp.vis_kc_save_velocity;
			vp.angles_y  = vp.vis_kc_save_angy;
			vp.vis_pitch = vp.vis_kc_save_pitch;
			// Restore the pre-replay anim ONLY for a still-ALIVE proxy.  The save was
			// captured once on the first replay frame (an alive locomotion frame).  A
			// proxy that DIED mid-cam already holds the correct networked CSANIM_DEATH*
			// in vis_anim_*; reverting it to the stale ALIVE save is exactly what left
			// "frozen dead bodies looking alive" (the forced rebuild below then solved
			// the skeleton from that wrong alive frame and corpse_frozen locked it).
			// vis_force_rebuild (line 166, unconditional) still re-solves the death pose.
			if (!vp.vis_is_dead)
			{
				vp.vis_anim_bottom      = vp.vis_kc_save_anim_bottom;
				vp.vis_anim_top         = vp.vis_kc_save_anim_top;
				vp.vis_anim_bottom_time = vp.vis_kc_save_anim_bottime;
				vp.vis_anim_top_time    = vp.vis_kc_save_anim_toptime;
			}
			vp.vis_kc_saved = 0;
		}
	}
	kc_posed = 0;
};

// Once the killcam stops driving the scene, restore the proxies we overrode.
void() Killcam_MaybeRestore =
{
	if (kc_posed && !Killcam_Active())
		Killcam_RestoreProxies();
};

// Record one ring frame (snapshot all visible player proxies).  Called every
// frame from CSQC_UpdateView, gated to ~KC_HZ.
void() Killcam_Record =
{
	// (Killcam_MaybeRestore is now called every frame from CSQC_UpdateView; this
	// function runs AFTER the scene's predraw so it records FRESH anim clocks.)

	// The replay POSED proxies this frame (a killcam is driving the scene) — recording
	// them would capture the replay pose, not the live scene.  So skip: the aftermath
	// is recorded during the death-cam DELAY (before the rewind starts), where kc_posed
	// is still 0.
	if (kc_posed)
		return;

	// While dead: keep recording the death AFTERMATH (your corpse's death anim) for a
	// bounded window so the slow-mo replay can play it, THEN freeze.  Freezing is what
	// preserves the buffered ALIVE lookback (continuing to advance + clear the ring
	// would eventually wipe it) — the bounded window (~1.2s) is far inside the ring's
	// ~9s headroom, so the lookback survives.  Window is 0 when slow-mo is off, so this
	// is identical to the old immediate freeze.
	// Keyed off the REAL death time S (latched in Killcam_DeathWatch), NOT killcam_on:
	// we must capture the death anim from S even before the killfeed lands (D >= S), or
	// the aftermath replay finds empty frames at the kill and the body vanishes.
	if (getstatf(STAT_IS_DEAD) && killcam_real_death_time > 0)
	{
		if (cltime - killcam_real_death_time > Killcam_AftermathWindow())
			return;
	}

	if (cltime - kc_last_rec < 1 / Killcam_Tickrate())
		return;
	kc_last_rec = cltime;

	float f = kc_head;
	kc_rtime[f] = cltime;

	float i;
	for (i = 0; i < KC_SLOTS; i = i + 1)
		kc_valid[i * KC_RING + f] = 0;

	// Record the LOCAL victim's corpse (death anim — CSANIM_DEATH* with an advancing
	// clock) ONLY once we're past the REAL death S (latched).  Frames then stamp
	// kc_rtime >= S, so they land in the AFTERMATH range (rt >= killcam_death_time=S),
	// NEVER the rewind lookback (kc_rtime < S) — that boundary alignment is what keeps
	// the rewind showing your ALIVE body while the aftermath plays the death anim.
	float aftermath_rec = (getstatf(STAT_IS_DEAD) && killcam_real_death_time > 0);
	entity vp;
	for (vp = findchain(classname, "player_visual_proxy"); vp; vp = vp.chain)
	{
		float slot = vp.vis_owner_entnum;
		if (slot < 1 || slot >= KC_SLOTS
		    || (vp.vis_is_dead && !(slot == player_localentnum && aftermath_rec)))
			continue;
		float idx = slot * KC_RING + f;
		vector ea;
		ea_x = vp.vis_pitch;
		ea_y = vp.angles_y;
		ea_z = 0;
		kc_origin[idx]    = vp.origin;
		kc_eyeang[idx]    = ea;
		kc_wepid[idx]     = vp.vis_weapon_id;
		kc_wstate[idx]    = vp.vis_weaponstate;
		kc_wpaction[idx]  = vp.vis_wep_action;
		kc_animstart[idx] = vp.vis_wep_anim_start;
		kc_botframe[idx]  = vp.vis_anim_bottom;
		kc_topframe[idx]  = vp.vis_anim_top;
		kc_anim_bottime[idx] = vp.vis_anim_bottom_time;	// K2: locomotion clock
		kc_anim_toptime[idx] = vp.vis_anim_top_time;	// K2: aim clock
		kc_legtwist[idx]  = vp.vis_last_leg_twist;	// strafe twist (P5 replays it)
		kc_lifeserial[idx] = vp.vis_life_serial;	// so a respawn (new serial) rejects old-life frames
		kc_valid[idx]     = 1;
	}

	kc_head = f + 1;
	if (kc_head >= KC_RING)
		kc_head = 0;
};

// Find the two ring frames bracketing replay time rt (+ the interpolation frac).
// Sets kc_lerp_f0 / kc_lerp_f1 / kc_lerp_frac.  Returns FALSE if there's no data.
float(float rt) Killcam_Bracket =
{
	float f0 = -1, f1 = -1;
	float t0 = -1000000000, t1 = 1000000000;
	float i;
	for (i = 0; i < KC_RING; i = i + 1)
	{
		float t = kc_rtime[i];
		if (t <= 0)
			continue;
		if (t <= rt && t > t0) { t0 = t; f0 = i; }	// latest frame at/before rt
		if (t >  rt && t < t1) { t1 = t; f1 = i; }	// earliest frame after rt
	}
	if (f0 < 0 && f1 < 0)
		return FALSE;
	if (f0 < 0) f0 = f1;		// rt before the oldest frame — clamp
	if (f1 < 0) f1 = f0;		// rt at/after the newest frame — hold
	kc_lerp_f0 = f0;
	kc_lerp_f1 = f1;
	if (f0 == f1 || t1 <= t0)
		kc_lerp_frac = 0;
	else
		kc_lerp_frac = (rt - t0) / (t1 - t0);
	return TRUE;
};

// Bracket the SERVER killer track at replay-time rt.  The effective time of frame i
// is killcam_death_time - kc_srv_delta[i] (computed HERE, at replay time, when the
// death time is known — the blob may arrive before it's set).  Sets kc_srv_f0/f1/frac.
float(float rt) Killcam_BracketServer =
{
	if (kc_srv_count < 2 || kc_srv_killer != killcam_killer)
		return FALSE;
	float f0 = -1, f1 = -1;
	float t0 = -1000000000, t1 = 1000000000;
	float i;
	for (i = 0; i < kc_srv_count; i = i + 1)
	{
		if (!kc_srv_valid[i])
			continue;
		float t = killcam_death_time - kc_srv_delta[i];
		if (t <= rt && t > t0) { t0 = t; f0 = i; }
		if (t >  rt && t < t1) { t1 = t; f1 = i; }
	}
	if (f0 < 0 && f1 < 0)
		return FALSE;
	if (f0 < 0) f0 = f1;
	if (f1 < 0) f1 = f0;
	kc_srv_f0 = f0;
	kc_srv_f1 = f1;
	if (f0 == f1 || t1 <= t0)
		kc_srv_frac = 0;
	else
		kc_srv_frac = (rt - t0) / (t1 - t0);
	return TRUE;
};

// Read the server killer-track blob (CSQC_EVENT_KILLCAM_TRACK), dispatched from
// cl_main.qc CSQC_Parse_Event.  Replaces any prior track (one track at a time).
void() Killcam_SV_ParseTrack =
{
	float killer = readbyte();
	float n      = readbyte();

	kc_srv_killer = killer;
	float i;
	for (i = 0; i < KC_RING; i = i + 1)
		kc_srv_valid[i] = 0;

	float w = 0;
	for (i = 0; i < n; i = i + 1)
	{
		float delta_ms = readshort();
		vector o;
		o_x = readcoord();
		o_y = readcoord();
		o_z = readcoord();
		float pit = readangle();
		float yaw = readangle();
		float ws  = readbyte();
		float wid = readbyte();
		if (w < KC_RING)	// always READ all n frames (don't desync the parse); store up to KC_RING
		{
			kc_srv_origin[w] = o;
			kc_srv_pitch[w]  = pit;
			kc_srv_yaw[w]    = yaw;
			kc_srv_wstate[w] = ws;
			kc_srv_wepid[w]  = wid;
			kc_srv_delta[w]  = delta_ms * 0.001;
			kc_srv_valid[w]  = 1;
			w = w + 1;
		}
	}
	kc_srv_count = w;
};

// Shortest-path interpolation between two angles (degrees).
float(float a, float b, float frac) Killcam_LerpAngle =
{
	float d = b - a;
	while (d > 180)  d = d - 360;
	while (d < -180) d = d + 360;
	return a + d * frac;
};

// Latch on local death (called from KillFeed_Parse).  killer = 1-based entnum;
// 0 / out-of-range (suicide / fall / world) cancels — caller falls back to the
// normal death-spot cam.
float killcam_headshot;		// the recorded kill was a headshot (replay the head-gib FX)
float kc_gib_fired;		// one-shot latch: head-gib emitted at the replayed kill moment

float kc_was_dead;		// local STAT_IS_DEAD rising-edge detector (latch the REAL death time S)

// Latch the REAL death time S (the STAT_IS_DEAD 0->1 edge) so the killcam rewind/
// aftermath boundary is the ACTUAL death, NOT when the killfeed packet happened to
// land (D).  D races S across snapshots: when the killfeed lands BEFORE the death
// registers locally (D < S), Killcam_Begin already ran with the cltime=D fallback,
// which left the aftermath window's [D,S] head empty -> the body VANISHED at the kill
// ~50% of the time.  Retro-correcting killcam_death_time to S here closes that gap.
// Called every frame from cl_main BEFORE the spectate/record path.
void() Killcam_DeathWatch =
{
	float is_dead = getstatf(STAT_IS_DEAD);
	if (is_dead && !kc_was_dead)			// just died: latch S
	{
		killcam_real_death_time = cltime;
		if (killcam_on && cltime - killcam_death_time < 1.0)	// D < S: killfeed landed first,
			killcam_death_time = cltime;			// so fix the D fallback -> S
	}
	else if (!is_dead && kc_was_dead)		// respawned: clear the latch
		killcam_real_death_time = 0;
	kc_was_dead = is_dead;
};

void(float killer_entnum, string killer_name, float headshot) Killcam_Begin =
{
	if (!cvar("cl_killcam"))
	{
		killcam_on = 0;
		return;
	}
	if (killer_entnum < 1 || killer_entnum >= KC_SLOTS)
	{
		killcam_on = 0;
		return;
	}
	killcam_killer      = killer_entnum;
	killcam_killer_name = killer_name;
	// Anchor the boundary at the REAL death S if it was already latched (D >= S, the
	// common case); else fall back to cltime=D and let Killcam_DeathWatch retro-fix it
	// when S latches a frame or two later (D < S).
	killcam_death_time  = (killcam_real_death_time > 0) ? killcam_real_death_time : cltime;
	killcam_on          = 1;
	killcam_headshot    = headshot;
	kc_gib_fired        = 0;
	kc_cam_smooth_valid = 0;		// seed the camera smoothing fresh on the first replay frame
	kc_last_fire_action = -1;		// so the first replayed shot plays its sound
	kc_last_fx_action   = -1;		// and its first muzzle/tracer
	kc_death_anim_dur   = 0;		// recompute the death-anim hold for this death
	kc_cam_kick_pitch   = 0;		// clear any leftover recoil
};

void() Killcam_End =
{
	killcam_on = 0;
	killcam_killer = 0;
	kc_cam_smooth_valid = 0;
	kc_srv_count = 0;		// drop the server track so it can't carry into the next death
	if (kc_posed)
		Killcam_RestoreProxies();
};

// Scan the killer's recorded frames in a short window around replay time rt for
// the most-active weapon state (RELOAD > FIRE > DRAW > IDLE) + its anim-start, so
// the replay viewmodel shows firing/reloading (WS_FIRE is too brief to reliably
// land on the single bracketed frame).  Sets kc_killerstate_animstart.
float(float rt) Killcam_KillerState =
{
	float best = WS_IDLE, bestpri = 0, beststart = 0;
	float i;
	for (i = 0; i < KC_RING; i = i + 1)
	{
		float t = kc_rtime[i];
		if (t <= 0 || t < rt - 0.35 || t > rt + 0.05)
			continue;
		float kidx = killcam_killer * KC_RING + i;
		if (!kc_valid[kidx])
			continue;
		float ws = kc_wstate[kidx];
		float pri = (ws == WS_RELOAD) ? 4 : (ws == WS_FIRE) ? 3 : (ws == WS_DRAW) ? 2 : 1;
		if (pri > bestpri) { bestpri = pri; best = ws; beststart = kc_animstart[kidx]; }
	}
	kc_killerstate_animstart = beststart;
	return best;
};

// Existence check that works for LOOSE files too — whichpack() only finds files
// inside a .pak/.pk3, so it returned "" for the loose cf*/Mauser sounds (which then
// fell back to the AK47 sample).  fopen reads through the full VFS (loose + packed).
float(string path) Killcam_FileExists =
{
	float h = fopen(path, FILE_READ);
	if (h < 0)
		return FALSE;
	fclose(h);
	return TRUE;
};

// Resolve a weapon's killcam fire sound.  MELEE has no gunshot — use the knife slash
// as a generic swing (the fist played the AK47 fallback otherwise).  For guns, derive
// the weapon folder from the manifest p_model ("models/weapons/wpn_xxx/...") and try a
// candidate list (filenames aren't uniform: most cf* use fire.WAV, some fire1.wav).
// One folder diverges (HD AK47 p_model wpn_hdak47, sounds under wpn_csak47).
string(float wepid) Killcam_FireSoundPath =
{
	if (WeaponManifest_Slot(wepid) == WMF_SLOT_MELEE)
		return "sounds/weapons/wpn_csknife/slash.wav";	// generic melee swing (no gunshot)

	string pm = W_GetPModelPath(wepid);
	string folder = "";
	if (pm != "")
	{
		float a = strstrofs(pm, "weapons/", 0);
		if (a >= 0)
		{
			a = a + 8;				// past "weapons/"
			float b = strstrofs(pm, "/", a);
			if (b >= 0)
				folder = substring(pm, a, b - a);	// "wpn_csak47"
		}
	}
	if (folder == "wpn_hdak47")
		folder = "wpn_csak47";				// only p_model-vs-sound folder divergence

	if (folder != "")
	{
		string base = strcat("sounds/weapons/", folder, "/");
		string c1 = strcat(base, "fire1.wav"); if (Killcam_FileExists(c1)) return c1;
		string c2 = strcat(base, "fire.wav");  if (Killcam_FileExists(c2)) return c2;
		string c3 = strcat(base, "fire.WAV");  if (Killcam_FileExists(c3)) return c3;
	}
	// Generic fallback (confirmed on disk + precached) so no weapon is ever silent.
	return "sounds/weapons/wpn_csak47/fire1.wav";
};

// Replay the killer's shot sound.  Plays once per distinct FIRE action-id while
// the reconstructed state is WS_FIRE (the live server fire sound played in the
// past, so the rewound replay is otherwise silent).  localsound = at the camera
// (= killer POV), so it sounds first-person like their gun.
void(float wepid, float wpaction, float wstate) Killcam_FireSound =
{
	if (wstate != WS_FIRE || wpaction == kc_last_fire_action)
		return;
	kc_last_fire_action = wpaction;
	string snd = Killcam_FireSoundPath(wepid);
	if (snd != "")
		localsound(snd);
};

// Emit a muzzle flash + downrange tracer from a recorded frame's gun (eye + aim).
// The live FX are masked during the killcam, so this is how the replay shows shots.
// Generic muzzle offset (no per-weapon table) — plenty for a cosmetic replay.  These
// are the REPLAY's own FX (NOT gated by Killcam_Active, unlike the live event FX).
void(float idx) Killcam_EmitShotFX =
{
	vector eye = kc_origin[idx];
	eye_z = eye_z + PM_VIEW_OFS_z;
	makevectors(kc_eyeang[idx]);				// recorded aim → v_forward/right/up
	vector muzzle = eye + v_forward * 24 + v_right * 6 - v_up * 5;
	// Trace along the recorded aim to the world (posed proxies are SOLID_NOT, so the
	// line passes THROUGH bodies to the wall behind — the tracer streaks past them).
	traceline(muzzle, muzzle + v_forward * 8192, MOVE_NORMAL, world);
	CSQC_SpawnTracer(muzzle, trace_endpos);
	CSQC_MuzzleFlashAtWorld(muzzle, kc_wpaction[idx]);
};

// Killer (camera POV) shot FX — edge-latched on the global kc_last_fx_action.
void(float wpaction, float wstate, float killer_idx) Killcam_FireEffects =
{
	if (wstate != WS_FIRE || wpaction == kc_last_fx_action)
		return;
	kc_last_fx_action = wpaction;
	Killcam_EmitShotFX(killer_idx);
	// Recoil: kick the camera UP a touch on each shot (decays in the camera block).
	if (cvar("sv_gunkick"))
	{
		float gs = cvar("sv_gunkick_strength"); if (gs <= 0) gs = 1;
		kc_cam_kick_pitch = bound(-7, kc_cam_kick_pitch - 1.5 * gs, 0);	// -pitch = up
	}
};

// Per-BODY shot FX (the VICTIM + any other replayed player who was firing) — so you
// see everyone in the replay actually shoot, not just the killer.  Edge-latched on
// the proxy's OWN recorded action-id.
void(entity vp, float idx) Killcam_ProxyFireFX =
{
	if (kc_wstate[idx] != WS_FIRE || kc_wpaction[idx] == vp.vis_kc_last_fx_action)
		return;
	vp.vis_kc_last_fx_action = kc_wpaction[idx];
	Killcam_EmitShotFX(idx);
};

// Replay one frame: pose proxies from the buffer (interpolated) + set the camera
// at the killer's recorded eye + render the killer's viewmodel.  Returns TRUE if
// it drove the view, FALSE (no buffered data) so the caller can fall back.
float() Killcam_Replay =
{
	float since    = cltime - killcam_death_time - Killcam_Delay();
	float lookback = Killcam_Lookback();
	float slowmo   = Killcam_Slowmo();
	float rt;
	if (slowmo <= 0 || since < lookback)
		rt = killcam_death_time - lookback + since;		// REWIND (1x) — up to the kill
	else
		rt = killcam_death_time + (since - lookback) * slowmo;	// AFTERMATH — slow-mo PAST the kill
	float maxrt = killcam_death_time + Killcam_AftermathWindow();	// (0 when slow-mo off = clamp at death)
	if (rt > maxrt)
		rt = maxrt;					// hold on the final settled death pose
	if (!Killcam_Bracket(rt))
		return FALSE;

	float f0 = kc_lerp_f0, f1 = kc_lerp_f1, frac = kc_lerp_frac;

	// HEADSHOT GIB: the head-explode is a one-shot event that already fired (+ was
	// masked) at the live death, so re-emit it ONCE when the replay reaches the kill
	// moment, at the victim's recorded head, thrown away from the killer.  With slow-mo
	// on it sprays in dramatic slow motion.
	if (killcam_headshot && !kc_gib_fired && rt >= killcam_death_time && player_localentnum >= 1)
	{
		float gvidx = player_localentnum * KC_RING + f0;
		if (kc_valid[gvidx])
		{
			kc_gib_fired = 1;
			vector gpos = kc_origin[gvidx] + '0 0 24';	// center of mass (matches server)
			vector gdir = gpos - kc_origin[killcam_killer * KC_RING + f0];
			gdir = (vlen(gdir) > 1) ? normalize(gdir) : '0 0 1';
			CSQC_SpawnPlayerGibs(gpos, gdir, 6, 100);
		}
	}

	// Re-pose every proxy from the buffer (the existing proxy render then shows
	// the recorded scene).  Hide the killer (first-person) + slots with no data;
	// the weapon p_model follows the body's .alpha via the predraw mirror.
	entity vp;
	for (vp = findchain(classname, "player_visual_proxy"); vp; vp = vp.chain)
	{
		float slot = vp.vis_owner_entnum;
		float idx0 = slot * KC_RING + f0;
		// kc_lifeserial mismatch = a frame from a PREVIOUS life (you spawned mid-lookback).
		// Without this the replay lerps from the old death spot to the new spawn = the
		// "model slowly floats toward the spawn point" bug.
		float hide = (slot < 1 || slot >= KC_SLOTS || slot == killcam_killer || !kc_valid[idx0]
		              || kc_lifeserial[idx0] != vp.vis_life_serial);
		// Pose a DEAD proxy ONLY for the local VICTIM (their alive replay is the whole
		// point — you watch yourself get shot).  HIDE any OTHER dead body: a remote
		// player who died before OR DURING the cam.  Posing them with stale alive
		// frames left them standing UPRIGHT after the cam ("frozen dead bodies");
		// hidden, the replay never overwrites their networked death pose, so they show
		// lying dead once the cam ends.  (Also subsumes the respawn glued-corpse case —
		// the corpse is dead+remote → hidden, the live respawn proxy is posed.)
		if (!hide && vp.vis_is_dead && slot != player_localentnum)
			hide = TRUE;
		if (hide)
		{
			vp.alpha = -1;				// hidden
			if (vp.vis_weapon_ent)
				vp.vis_weapon_ent.alpha = -1;
			vp.vis_kc_replay_valid = 0;		// reseed the foot-clock when it reappears
			vp.vis_kc_last_fx_action = -1;		// re-arm shot FX too
			continue;
		}
		float idx1 = slot * KC_RING + f1;
		float fr = frac;
		if (!kc_valid[idx1]) { idx1 = idx0; fr = 0; }	// no straddling frame for this slot

		if (!vp.vis_kc_saved)	// snapshot the live pose ONCE so RestoreProxies can snap back
		{
			vp.vis_kc_save_origin       = vp.origin;
			vp.vis_kc_save_velocity     = vp.velocity;
			vp.vis_kc_save_angy         = vp.angles_y;
			vp.vis_kc_save_pitch        = vp.vis_pitch;
			vp.vis_kc_save_anim_bottom  = vp.vis_anim_bottom;	// the DEATH pose for a corpse
			vp.vis_kc_save_anim_top     = vp.vis_anim_top;
			vp.vis_kc_save_anim_bottime = vp.vis_anim_bottom_time;
			vp.vis_kc_save_anim_toptime = vp.vis_anim_top_time;
			vp.vis_kc_saved = 1;
		}

		vector e0 = kc_eyeang[idx0];
		vector e1 = kc_eyeang[idx1];
		vector o0 = kc_origin[idx0];
		vector o1 = kc_origin[idx1];
		vector neworg = o0 + (o1 - o0) * fr;
		vp.alpha           = 1;
		setorigin(vp, neworg);
		vp.angles_y        = Killcam_LerpAngle(e0_y, e1_y, fr);
		vp.vis_pitch       = Killcam_LerpAngle(e0_x, e1_x, fr);
		vp.vis_anim_bottom = kc_botframe[idx0];
		vp.vis_anim_top    = kc_topframe[idx0];
		vp.vis_weapon_id   = kc_wepid[idx0];
		// Strafe twist (P5 applies this to subblendfrac + the spine YawBone deform).
		vp.vis_kc_legtwist = kc_legtwist[idx0] + (kc_legtwist[idx1] - kc_legtwist[idx0]) * fr;

		// Aim clock: lerp on matching top-frame index (per-sequence playback time).
		float tt0 = kc_anim_toptime[idx0], tt1 = kc_anim_toptime[idx1];
		vp.vis_anim_top_time = (kc_topframe[idx0] == kc_topframe[idx1]) ? (tt0 + (tt1 - tt0) * fr) : tt0;

		// Locomotion foot-clock: RUN/RUN_CROUCH are the ONLY clock-driven leg anims
		// (jump/idle are static poses), so a held/flat recorded clock freezes the
		// legs ONLY on run — exactly the reported "jump fine, walk frozen".  DRIVE
		// the run clock from the replayed origin MOTION (which always advances — the
		// body visibly travels) like the live distance-timer, so the feet stay synced
		// to the replayed travel regardless of the recorded clock.  Static anims keep
		// the buffered clock.
		float bf = kc_botframe[idx0];
		if ((bf == CSANIM_RUN || bf == CSANIM_RUN_CROUCH) && vp.vis_kc_replay_valid)
		{
			vector rd = neworg - vp.vis_kc_replay_prevorg; rd_z = 0;
			makevectors([0, vp.angles_y, 0]);
			float qps = (bf == CSANIM_RUN_CROUCH) ? cvar("sv_anim_qu_per_sec_crouch") : cvar("sv_anim_qu_per_sec");
			if (qps <= 0) qps = (bf == CSANIM_RUN_CROUCH) ? 100 : 240;
			vp.vis_anim_bottom_time += (rd * v_forward) / qps;
		}
		else
		{
			float bt0 = kc_anim_bottime[idx0], bt1 = kc_anim_bottime[idx1];
			vp.vis_anim_bottom_time = (kc_botframe[idx0] == kc_botframe[idx1]) ? (bt0 + (bt1 - bt0) * fr) : bt0;
		}
		vp.vis_kc_replay_prevorg = neworg;
		vp.vis_kc_replay_valid   = 1;

		vp.vis_aim_yaw       = vp.angles_y;		// keep the predraw yaw-reset consistent
		vp.velocity          = '0 0 0';			// replay drives anim from the buffer, not movement
		vp.vis_killcam_posed = cltime;			// per-frame "the killcam owns this proxy" stamp
		Killcam_ProxyFireFX(vp, idx0);			// muzzle + tracer for THIS body's recorded shots
	}
	kc_posed = 1;

	// Camera at the killer's recorded eye (interpolated) + their viewmodel.  Prefer the
	// SERVER track (sv_killcam.qc) for the killer ONLY where our own buffer has a gap
	// (the killer was out of our PVS) — normal in-PVS kills keep the proven client path,
	// and the smoothing below hides the one-frame source switch at a PVS boundary.
	float k0 = killcam_killer * KC_RING + f0;
	float srv_ok = (rt <= killcam_death_time && !kc_valid[k0]
	                && kc_srv_count >= 2 && kc_srv_killer == killcam_killer
	                && Killcam_BracketServer(rt));
	if (kc_valid[k0] || srv_ok)
	{
		vector eye, ang, c0, c1;
		if (kc_valid[k0])
		{
			kc_cam_source = 1;	// CLIENT buffer (killer was in our PVS)
			float k1 = killcam_killer * KC_RING + f1;
			float kfr = frac;
			if (!kc_valid[k1]) { k1 = k0; kfr = 0; }
			vector a0 = kc_eyeang[k0];
			vector a1 = kc_eyeang[k1];
			c0 = kc_origin[k0];
			c1 = kc_origin[k1];
			eye = c0 + (c1 - c0) * kfr;
			ang_x = Killcam_LerpAngle(a0_x, a1_x, kfr);
			ang_y = Killcam_LerpAngle(a0_y, a1_y, kfr);
		}
		else	// SERVER track — fills the killer's out-of-PVS approach
		{
			kc_cam_source = 2;	// SERVER track (our buffer had a gap here)
			c0 = kc_srv_origin[kc_srv_f0];
			c1 = kc_srv_origin[kc_srv_f1];
			eye = c0 + (c1 - c0) * kc_srv_frac;
			ang_x = Killcam_LerpAngle(kc_srv_pitch[kc_srv_f0], kc_srv_pitch[kc_srv_f1], kc_srv_frac);
			ang_y = Killcam_LerpAngle(kc_srv_yaw[kc_srv_f0], kc_srv_yaw[kc_srv_f1], kc_srv_frac);
		}
		eye_z = eye_z + PM_VIEW_OFS_z;
		ang_z = 0;

		// Frame the VICTIM (you).  The camera stays at the killer's eye, but its AIM is
		// steered toward your recorded body — because with the killer's raw aim alone
		// you only appeared on screen ~50% of the time (whenever they happened to be
		// looking at you).  Pitch negated (vectoangles -> v_angle, per Bot_AimAt).
		if (slowmo > 0 && rt > killcam_death_time && player_localentnum >= 1)
		{
			// AFTERMATH: full look-at — your death is the focus.
			float vidx = player_localentnum * KC_RING + f0;
			if (kc_valid[vidx])
			{
				vector veye = kc_origin[vidx];
				veye_z = veye_z + PM_VIEW_OFS_z * 0.5;	// the body, not the feet
				vector look = vectoangles(veye - eye);
				ang_x = 0 - look_x;
				ang_y = look_y;
			}
		}
		else if (rt <= killcam_death_time && player_localentnum >= 1)
		{
			// REWIND: BLEND the killer's aim toward you (0.3 early → 0.5 at the kill) so
			// you're framed throughout the lookback while keeping the killer-POV feel.
			vidx = player_localentnum * KC_RING + f0;
			if (kc_valid[vidx])
			{
				veye = kc_origin[vidx];
				veye_z = veye_z + PM_VIEW_OFS_z * 0.5;
				look = vectoangles(veye - eye);
				float blend = 0.5 - 0.2 * bound(0, (killcam_death_time - rt) / lookback, 1);
				ang_x = Killcam_LerpAngle(ang_x, 0 - look_x, blend);
				ang_y = Killcam_LerpAngle(ang_y, look_y, blend);
			}
		}

		// Low-pass smooth the camera every render frame (like the spec cam) so the
		// raw network-sampled killer aim doesn't flicker/stutter left-right.  Frame-
		// rate-INDEPENDENT exp damping (was frametime*16, which over/under-smooths
		// off 60fps); damped enough that a bot killer's aim-snaps pan instead of
		// flickering.
		if (!kc_cam_smooth_valid)
		{
			kc_cam_smooth_org   = eye;
			kc_cam_smooth_ang   = ang;
			kc_cam_smooth_valid = 1;
		}
		else
		{
			float sl = bound(0, 1 - pow(2.718281, -KC_CAM_DAMP * frametime), 1);
			kc_cam_smooth_org   = kc_cam_smooth_org + (eye - kc_cam_smooth_org) * sl;
			kc_cam_smooth_ang_x = Killcam_LerpAngle(kc_cam_smooth_ang_x, ang_x, sl);
			kc_cam_smooth_ang_y = Killcam_LerpAngle(kc_cam_smooth_ang_y, ang_y, sl);
			kc_cam_smooth_ang_z = 0;
		}
		// Recoil: decay the kick, add it to the rendered pitch (not the smoothed base).
		kc_cam_kick_pitch -= kc_cam_kick_pitch * bound(0, frametime * 9, 1);
		vector kickang = kc_cam_smooth_ang;
		kickang_x += kc_cam_kick_pitch;
		setproperty(VF_ORIGIN, kc_cam_smooth_org);
		setproperty(VF_ANGLES, kickang);
		setproperty(VF_VIEWENTITY, 0);

		// Viewmodel: the FULL reconstructed fire/reload path (+ shot sound/muzzle/tracer)
		// when OUR buffer has the killer — that's at/around the kill, in PVS, where the
		// firing happens.  During the server-track approach (out of PVS) draw a static
		// idle gun from the recorded weapon — nothing's being fired yet.
		if (kc_valid[k0])
		{
			// Viewmodel POSE uses the WINDOW state (kws) — it stays stable across the sparse
			// 30Hz samples.  But the shot SOUND + muzzle/tracer must edge off the INSTANT
			// bracket-frame state (kc_wstate[k0]) so state + action come from the SAME frame:
			// keying the sound on kws DOUBLE-FIRED it — the window's +0.05s look-ahead reports
			// FIRE one frame before f0 lands on the shot, so the edge gate saw the pre-shot
			// action AND the shot action as two shots (the "doubled up" flam).
			float kws = Killcam_KillerState(rt);
			CSQC_AddRemoteViewmodel(kc_wepid[k0], kws, kc_wpaction[k0],
			                        kc_killerstate_animstart + (cltime - rt));
			Killcam_FireSound(kc_wepid[k0], kc_wpaction[k0], kc_wstate[k0]);	// shot sound — INSTANT state (no flam)
			Killcam_FireEffects(kc_wpaction[k0], kc_wstate[k0], k0);		// + muzzle flash & tracer (same)
			kc_replay_killer_wepid = kc_wepid[k0];			// for the killcam crosshair
		}
		else
		{
			CSQC_AddRemoteViewmodel(kc_srv_wepid[kc_srv_f0], kc_srv_wstate[kc_srv_f0], 0, 0);
			kc_replay_killer_wepid = kc_srv_wepid[kc_srv_f0];
		}
	}
	else if (kc_cam_smooth_valid)
	{
		kc_cam_source = 3;	// HOLD (no client frame, no server track — e.g. sv_killcam off)
		// The killer has NO buffered frame at this replay instant (they were out of
		// our PVS when they fired).  HOLD the last good camera rather than leave the
		// view undriven on a stale value — that was the "tracks the wrong player /
		// snaps the angle back-and-forth" glitch (the camera flipped between the
		// killer eye and whatever the view was before).
		setproperty(VF_ORIGIN, kc_cam_smooth_org);
		setproperty(VF_ANGLES, kc_cam_smooth_ang);
		setproperty(VF_VIEWENTITY, 0);
	}
	return TRUE;
};

// "KILLCAM — killed by X" banner, drawn from the spectator HUD while replaying.
void() Killcam_DrawHUD =
{
	if (!Killcam_Active())
		return;

	// Cinematic fade-in (first ~0.35s) + fade-out (last ~0.35s).
	if (cvar("cl_killcam_fade") != 0)
	{
		float fsince = cltime - killcam_death_time - Killcam_Delay();
		float fdur   = Killcam_Duration();
		float fw     = 0.35;
		float fa     = 0;
		if (fsince < fw)
			fa = 1 - (fsince / fw);
		else if (fsince > fdur - fw)
			fa = 1 - ((fdur - fsince) / fw);
		fa = bound(0, fa, 1);
		if (fa > 0)
			drawfill('0 0 0', [g_width, g_height, 0], '0 0 0', fa, 0);
	}

	// Procedural CRT scanlines + a faint cool tint (no scanline texture exists).
	if (cvar("cl_killcam_scanlines") != 0)
	{
		float sy;
		for (sy = 0; sy < g_height; sy = sy + 3)
			drawfill([0, sy, 0], [g_width, 1, 0], '0 0 0', 0.12, 0);
		drawfill('0 0 0', [g_width, g_height, 0], '0.6 0.8 1', 0.04, 0);
	}

	float prev_font = drawfont;
	drawfont = hud_font;
	string t1 = "KILLCAM";
	vector s1 = [28, 28];
	float w1 = stringwidth(t1, 1, s1);
	drawstring([g_width * 0.5 - w1 * 0.5, g_height * 0.12], t1, s1, '1 0.85 0.4', 0.95, 0);
	if (killcam_killer_name != "")
	{
		string t2 = strcat("Killed by ", killcam_killer_name);
		vector s2 = [18, 18];
		float w2 = stringwidth(t2, 1, s2);
		drawstring([g_width * 0.5 - w2 * 0.5, g_height * 0.12 + 32], t2, s2, '1 1 1', 0.9, 0);
	}

	// cl_killcam_debug: show which source is driving the camera THIS frame.  The
	// SERVER track only engages where your own buffer has a gap (the killer's out-of-
	// PVS approach), so a green "SERVER TRACK" readout IS the proof it's working — a
	// normal in-PVS kill stays on "client buffer".  srv=N is how many frames the
	// server sent for this death (0 = none arrived / sv_killcam off).
	if (cvar("cl_killcam_debug"))
	{
		string src = (kc_cam_source == 2) ? "SERVER TRACK"
		           : (kc_cam_source == 1) ? "client buffer" : "hold (no data)";
		vector dcol = (kc_cam_source == 2) ? '0.3 1 0.3' : '0.8 0.8 0.8';
		string td = strcat("cam: ", src, "   srv=", ftos(kc_srv_count));
		vector sd = [15, 15];
		float wd = stringwidth(td, 1, sd);
		drawstring([g_width * 0.5 - wd * 0.5, g_height * 0.12 + 58], td, sd, dcol, 0.95, 0);
	}
	drawfont = prev_font;
};
