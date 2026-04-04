
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

	remove(self);
};

void() CSQC_Shutdown =
{
	CSQC_ResetPredictionState();
};

noref void(float apiver, string enginename, float enginever) CSQC_Init =
{
	drawfont = loadfont("", "Courier Prime Code", "12,16,24,32,64,72,128,256,512", -1, 0, 0);
	precache_everything();
	registercommand("pred_debug");
};

noref void() CSQC_WorldLoaded =
{
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
		camang = view_angles;
		setproperty(VF_ORIGIN, campos);
		setproperty(VF_ANGLES, camang);
	}
	else
	{
		campos = getproperty(VF_ORIGIN);
		camang = getproperty(VF_ANGLES);
	}

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
