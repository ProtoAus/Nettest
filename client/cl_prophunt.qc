// ============================================================================
//  PROP HUNT (GAMEMODE_PROPHUNT) — client-side helpers + overlays
// ============================================================================
//  RED = SEEKERS, BLUE = HIDERS.  The disguise itself is rendered by the
//  visual-proxy predraw branch in cl_player.qc; the third-person self view and
//  the input-side gates key off CSQC_PropHunt_LocalDisguised() below.
//  Compiles after cl_player.qc; earlier files reach these via the forward
//  declarations in cl_customdefs.qc (CSQC_SpawnCorpseRagdoll pattern).
// ============================================================================

// TRUE when the LOCAL player is currently disguised as a prop.  Reads the
// prediction-proxy state (Wire B): the hull bytes ride that wire, the
// modelindex does not — so the predicate is ph_hull_height > 0, matching what
// PM_CurrentMins/Maxs keys on (the two MUST agree or camera and hull split).
float() CSQC_PropHunt_LocalDisguised =
{
	if (getstatf(STAT_GAMEMODE) != GAMEMODE_PROPHUNT)
		return FALSE;
	if (!predicted_player || !csqc_prediction_valid)
		return FALSE;
	if (getstatf(STAT_IS_DEAD))
		return FALSE;
	return predicted_player.ph_hull_height > 0;
};

// Release announcement: the moment the blindfold lifts, the HIDERS need to
// know the hunt is on (the seekers' own cue is the blindfold lifting).
// Phase-edge detected locally from the stats — no wire needed.  ph_seen_phase
// starts at -1 so a late joiner landing mid-ACTIVE doesn't get a stale banner.
const float PH_RELEASE_BANNER_TIME = 4.0;	// seconds on screen (last ~1s fades)
var float ph_seen_phase = -1;
float ph_release_time;				// cltime the FREEZE->ACTIVE edge landed; 0 = none

// --- Disguise breath cue (LOCAL ONLY) ---------------------------------------
// A short inhale as you slip into a prop, an exhale as you drop it.  Entirely
// client-side: nothing is networked and localsound() is listener-relative, so
// only the player who transforms hears it — it can never give a hider's
// position away to a seeker standing nearby.
//
// Edge-detected off CSQC_PropHunt_LocalDisguised(), the SAME predicate the
// third-person camera gate uses, so the cue lands on exactly the frame the view
// switches.  That also means every decloak path is covered for free — voluntary
// (impulse 7), death, and round restart all clear the hull.
//
// Channel 10 is unclaimed (1-4 standard, 5/7/9/11 car, 6 physprop scrape,
// 8 rain), so the cue can neither cut off nor be cut off by anything else —
// notably the sniper hold-breath in cl_codscope.qc, which plays these SAME two
// wavs on the auto channel.
const float PH_BREATH_CHAN = 10;
const float PH_BREATH_VOL  = 0.5;
// -1 = not sampled yet, so connecting (or changing map) while already disguised
// latches silently instead of firing a phantom cue on the first frame.
var float ph_breath_disguised = -1;

void() PropHunt_UpdateDisguiseBreath =
{
	if (getstatf(STAT_GAMEMODE) != GAMEMODE_PROPHUNT)
	{
		ph_breath_disguised = -1;	// re-arm; leaving the mode is not a decloak
		return;
	}
	// Do NOT sample through a prediction gap (map change, teleport, respawn
	// reset): the predicate reads "undisguised" for a frame or two there, which
	// would fire a phantom exhale/inhale pair.  Hold the latch instead.
	if (!predicted_player || !csqc_prediction_valid)
		return;

	float now_disguised = CSQC_PropHunt_LocalDisguised() ? 1 : 0;
	if (now_disguised == ph_breath_disguised)
		return;
	if (ph_breath_disguised >= 0)	// -1 = first sample: latch, don't play
		localsound(now_disguised ? "sounds/player/breathin.wav"
		                         : "sounds/player/breathout.wav",
		           PH_BREATH_CHAN, PH_BREATH_VOL);
	ph_breath_disguised = now_disguised;
};

// Full-screen overlays, called once per frame from the HUD pass (cl_hud.qc)
// just before the centre-message draw so the round timer / countdown / HUD
// text still render ON TOP of the blindfold fill.
void() PropHunt_DrawOverlays =
{
	// Runs BEFORE the gamemode gate so the breath latch re-arms when the mode
	// changes.  Cheap (one statf + one predicate) and self-gating.
	PropHunt_UpdateDisguiseBreath();

	if (getstatf(STAT_GAMEMODE) != GAMEMODE_PROPHUNT)
		return;

	float phase = getstatf(STAT_ROUND_PHASE);
	float team  = getstatf(STAT_PLAYERTEAM);

	// FREEZE -> ACTIVE edge = the seekers just got released.
	if (phase != ph_seen_phase)
	{
		if (ph_seen_phase == ROUND_PHASE_FREEZE && phase == ROUND_PHASE_ACTIVE)
		{
			ph_release_time = cltime;
			if (team == TEAM_BLUE)
				localsound("sounds/effects/orchestralhit.mp3");	// the win-banner sting — dread, repurposed
		}
		ph_seen_phase = phase;
	}

	// Hider-side release banner, big and red, fading out over the last second.
	if (ph_release_time > 0 && team == TEAM_BLUE && !getstatf(STAT_IS_DEAD)
	    && phase == ROUND_PHASE_ACTIVE)
	{
		float age = cltime - ph_release_time;
		if (age <= PH_RELEASE_BANNER_TIME)
		{
			float ba = 1;
			if (age > PH_RELEASE_BANNER_TIME - 1)
				ba = PH_RELEASE_BANNER_TIME - age;	// linear fade over the final second
			string b1 = "THE SEEKERS ARE LOOSE!";
			string b2 = "Stay still. Stay quiet.";
			vector bsz1 = [26, 26];
			vector bsz2 = [13, 13];
			drawstring([g_width * 0.5 - stringwidth(b1, TRUE, bsz1) * 0.5, g_height * 0.30], b1, bsz1, '1 0.35 0.35', ba, 0);
			drawstring([g_width * 0.5 - stringwidth(b2, TRUE, bsz2) * 0.5, g_height * 0.30 + 36], b2, bsz2, '0.9 0.9 0.9', ba * 0.9, 0);
		}
		else
			ph_release_time = 0;	// expired — stop evaluating
	}

	if (phase == ROUND_PHASE_FREEZE && team == TEAM_RED && !getstatf(STAT_IS_DEAD))
	{
		// SEEKER BLINDFOLD: opaque cover while the hiders scatter.  The freeze
		// countdown (STAT_FREEZE_TIMELEFT) is drawn by the standard HUD on top.
		drawfill('0 0 0', [g_width, g_height], '0.03 0.03 0.05', 1, 0);

		string t1 = "SEEKER";
		string t2 = "The props are hiding...";
		vector sz1 = [28, 28];
		vector sz2 = [14, 14];
		drawstring([g_width * 0.5 - stringwidth(t1, TRUE, sz1) * 0.5, g_height * 0.40], t1, sz1, '1 0.42 0.42', 1, 0);
		drawstring([g_width * 0.5 - stringwidth(t2, TRUE, sz2) * 0.5, g_height * 0.40 + 40], t2, sz2, '0.85 0.85 0.85', 1, 0);
		return;
	}

	if (team == TEAM_BLUE && !getstatf(STAT_IS_DEAD))
	{
		// HIDER hint: how to play, until they're disguised (then just the
		// rotation-lock reminder during the hide phase).
		string hint = "";
		if (!CSQC_PropHunt_LocalDisguised())
			hint = "Look at a prop and press +use to DISGUISE";
		else if (phase == ROUND_PHASE_FREEZE)
			hint = "Hide! Reload key toggles rotation lock";
		if (hint != "")
		{
			vector hsz = [12, 12];
			drawstring([g_width * 0.5 - stringwidth(hint, TRUE, hsz) * 0.5, g_height * 0.72], hint, hsz, '0.9 0.85 0.5', 0.9, 0);
		}
	}
};
