
void() CSQC_Ent_Remove =
{
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

void(float use_world_ignoreent) CSQC_DebugPredTrace =
{
	entity probe_ent;
	entity ignore_ent;
	entity saved;
	vector start;
	vector mins;
	vector maxs;
	vector dest;
	string ignore_name;
	float hit_entnum;
	string hit_classname;
	string hit_model;
	string line;

	probe_ent = predicted_player;
	if (!probe_ent)
		probe_ent = CSQC_GetEngineLocalPlayer();

	if (!probe_ent)
	{
		print("pred_trace: no player entity available\n");
		return;
	}

	saved = self;
	self = probe_ent;

	PM_ReadMovevars();
	mins = PM_CurrentMins();
	maxs = PM_CurrentMaxs();
	start = probe_ent.origin;

	if (use_world_ignoreent)
	{
		ignore_ent = world;
		ignore_name = "world";
	}
	else
	{
		ignore_ent = probe_ent;
		ignore_name = "self";
	}

	tracebox(start, mins, maxs, start, MOVE_NOMONSTERS, ignore_ent);
	hit_entnum = trace_ent ? trace_ent.entnum : 0;
	hit_classname = trace_ent ? trace_ent.classname : "";
	hit_model = trace_ent ? trace_ent.model : "";
	line = strcat(
		sprintf("pred_trace [%s] point: startsolid=%.0f allsolid=%.0f fraction=%.3f ",
			ignore_name, trace_startsolid, trace_allsolid, trace_fraction),
		sprintf("hitent=%.0f classname=%s model=%s\n",
			hit_entnum, hit_classname, hit_model)
	);
	print(line);

	dest = start - '0 0 64';
	tracebox(start, mins, maxs, dest, MOVE_NOMONSTERS, ignore_ent);
	hit_entnum = trace_ent ? trace_ent.entnum : 0;
	hit_classname = trace_ent ? trace_ent.classname : "";
	hit_model = trace_ent ? trace_ent.model : "";
	line = strcat(
		sprintf("pred_trace [%s] down64: startsolid=%.0f allsolid=%.0f fraction=%.3f ",
			ignore_name, trace_startsolid, trace_allsolid, trace_fraction),
		sprintf("end=(%.1f %.1f %.1f) ",
			trace_endpos_x, trace_endpos_y, trace_endpos_z),
		sprintf("hitent=%.0f classname=%s model=%s\n",
			hit_entnum, hit_classname, hit_model)
	);
	print(line);

	line = strcat(
		sprintf("pred_trace [%s] probe: entnum=%.0f solid=%.0f flags=%.0f ",
			ignore_name, probe_ent.entnum, probe_ent.solid, probe_ent.flags),
		sprintf("hitmaski=%s dphitmask=%.0f dim_hit=%.0f dim_solid=%.0f ",
			itos(probe_ent.hitcontentsmaski), probe_ent.dphitcontentsmask,
			probe_ent.dimension_hit, probe_ent.dimension_solid),
		sprintf("mins=(%.1f %.1f %.1f) maxs=(%.1f %.1f %.1f)\n",
			mins_x, mins_y, mins_z, maxs_x, maxs_y, maxs_z)
	);
	print(line);

	self = saved;
};

noref void(float apiver, string enginename, float enginever) CSQC_Init =
{
	CSQC_EnsureWorldSolid();
	drawfont = loadfont("", "Courier Prime Code", "12,16,24,32,64,72,128,256,512", -1, 0, 0);
	precache_everything();
	registercommand("pred_debug");
	registercommand("pred_trace");
};

noref void() CSQC_WorldLoaded =
{
	CSQC_EnsureWorldSolid();
	CSQC_ResetPredictionState();
};

// CSQC_Ent_Update is implemented in cl_player.qc

// CALLED EVERY CLIENT RENDER FRAME
void(float width, float height, float menushown) CSQC_UpdateView =
{
	//clear and update our global screen resolution vars
	clearscene();
	g_width = width;
	g_height = height;

	//disable quake status bar and quake crosshair
	setproperty(VF_DRAWENGINESBAR, 0);
	setproperty(VF_DRAWCROSSHAIR, 0);

	CSQC_BuildPresentationView();

	// use predicted player position for the camera if prediction is active
	if (predicted_player && csqc_prediction_valid)
	{
		if (csqc_present_valid)
			campos = csqc_present_origin + csqc_present_view_ofs;
		else
			campos = predicted_player.origin + predicted_player.view_ofs;
		// consume teleport angle snap if prediction fired one this frame
		camang = view_angles;
		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, camang);
	}
	else
	{
		campos = getproperty(VF_ORIGIN);
		camang = getproperty(VF_ANGLES);
	}

	// extrapolate remote players beyond the last received server snapshot
	CSQC_ExtrapolateRemotePlayers();

	//autoadd entities received from servers for drawing
	addentities(MASK_ENGINE);

	//does what you think it does
	renderscene();
	CSQC_DrawPredictionDebug();
	
	/*
	sui_begin(g_width, g_height);
	
	// Insert your own sui code here even for CSQC
	// Make sure to uncomment sui_input_event as well.
	
	sui_menu_nav();
	
	sui_end();
	*/
};

// Suppress the server echo of the local player's footstep sounds when CSQC
// already played them locally.  Suppression is gated on pm_last_local_step_time
// so that prediction divergence (CSQC missed a step) lets the server sound
// through instead of silencing it.
//
// "sounds/player/" is the full path used in this mod.  FTE's QW protocol may
// strip the "sounds/" prefix on the wire, so both forms are accepted.
noref float(float entnum, float channel, string soundname, float vol,
            float attenuation, vector pos, float pitchmod, float flags)
CSQC_Event_Sound =
{
    float ping_est;
    float age;

    if (channel != CHAN_BODY)
        return FALSE;
    if (entnum != player_localentnum || player_localentnum <= 0)
        return FALSE;
    if (substring(soundname, 0, 14) != "sounds/player/"
        && substring(soundname, 0, 7) != "player/")
        return FALSE;

    // Only suppress if CSQC actually played this sound recently.
    // Window = estimated round-trip ping + 100 ms of jitter margin.
    // If CSQC didn't predict the step (pm_last_local_step_time is stale),
    // age will be large and the server echo passes through unchanged.
    ping_est = bound(0, cltime - time, 0.3);
    age      = cltime - pm_last_local_step_time;
    if (age < ping_est + 0.1)
        return TRUE;   // echo of a sound we already played — suppress

    return FALSE;      // CSQC missed this step — let the server sound play
};

float(string cmd) CSQC_ConsoleCommand =
{
	tokenize(cmd);
	switch(argv(0))
	{
		case "pred_debug":
			if (argv(1) != "")
				csqc_pred_debug = stof(argv(1));
			else
				csqc_pred_debug = !csqc_pred_debug;
			print(sprintf("pred_debug %g\n", csqc_pred_debug));
			return TRUE;
		case "pred_trace":
			CSQC_DebugPredTrace(argv(1) == "world");
			return TRUE;
		default:
			return FALSE;
	}
	return TRUE;
};

float(float evtype, float scanx, float chary, float devid) CSQC_InputEvent =
{
	// sui_input_event(evtype, scanx, chary, devid);
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


void() CSQC_Parse_Event =
{
	float first = readbyte();
	switch(first) {
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
