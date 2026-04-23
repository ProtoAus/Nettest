
float menu_active;

float splash_time;

// Pick a random map name from maps.txt in the gamedir.  One map per
// line; blank lines and lines starting with '#' are skipped.  Returns
// "" if the file is missing, empty, or unreadable — caller falls back
// to the cl_menumap cvar.
//
// Two passes: count valid lines, then re-open and grab the Nth.  QC
// has no dynamic arrays and string temporaries can evaporate between
// frames; a second fopen is simpler than juggling preallocated buffers.
string() Menu_PickMapFromFile =
{
    float f = fopen("maps.txt", FILE_READ);
    if (f < 0)
        return "";

    float count = 0;
    string line = fgets(f);
    while (line)
    {
        // FTE's fgets strips LF but can leave a trailing CR on files
        // written with Windows line endings.
        float n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
        {
            line = substring(line, 0, n - 1);
            n = n - 1;
        }
        if (n > 0 && substring(line, 0, 1) != "#")
            count = count + 1;
        line = fgets(f);
    }
    fclose(f);

    if (count <= 0)
        return "";

    // Pick source: wall-clock seconds, reduced to the last 5 digits
    // so it fits safely in a 32-bit float.
    //
    // Why not random()?  The engine does srand(time(0)) at boot, but
    // libc rand() (especially MSVC's LCG) has very flat output right
    // after seeding — floor(random() * 5) can stick on the same
    // bucket for hundreds of seconds of seed variation.
    //
    // Why the last 5 digits?  Full unix timestamps are ~1.76e9, well
    // past float32's 2^24 precision limit; multiplying or reducing
    // such a value loses the low bits entirely and we get 0 every
    // time.  The last 5 digits (0-99999) stay exact in float32 and
    // still change every second, so successive launches pick
    // different maps reliably.
    //
    // 100000 seconds (~27 h) is more than enough uniqueness window;
    // the 5-digit value wraps but the user never sees two back-to-back
    // launches straddle the boundary in a noticeable way.
    string ts_str = strftime(1, "%s");
    float tn = strlen(ts_str);
    string tail = (tn > 5) ? substring(ts_str, tn - 5, 5) : ts_str;
    float seed = stof(tail);
    // Mix in an intra-second sample from random() so same-second
    // relaunches don't collide.  random() is weak, but any low-bit
    // noise from it is pure bonus here — the seconds tick is what
    // actually drives the pick.
    seed = seed + floor(random() * 997);
    float pick = seed - floor(seed / count) * count;
    if (pick < 0)      pick = pick + count;
    if (pick >= count) pick = count - 1;

    f = fopen("maps.txt", FILE_READ);
    if (f < 0)
        return "";

    string chosen = "";
    float i = 0;
    line = fgets(f);
    while (line)
    {
        n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
        {
            line = substring(line, 0, n - 1);
            n = n - 1;
        }
        if (n > 0 && substring(line, 0, 1) != "#")
        {
            if (i == pick)
            {
                chosen = line;
                break;
            }
            i = i + 1;
        }
        line = fgets(f);
    }
    fclose(f);

    return chosen;
};

void() m_init =
{
	splash_time = 0;
	registercommand("togglemenu2");
	setcursormode(TRUE,"gfx/xhair", [16, 16], cvar("vid_conautoscale"));
	menu_font = loadfont("hud", "gfx/RobotoEB", "8 12 16 18 24 36 48 60 72", -1, 0, 0);
	current_menu = MENU_MAIN;
	localcmd("set _nettest_menu_active 0\n");

	// Permanent binds — not configurable
	localcmd("bind escape togglemenu\n");
	localcmd("bind ` toggleconsole\n");
	localcmd("bind ~ toggleconsole\n");
	localcmd("bind f9 screenshot\n");
	localcmd("bind f10 quit\n");

	Menu_LoadConfig();

	// Background map — start a local listen server on this map so the main
	// menu renders over a live world instead of a black void.  The map's
	// "camera" entities cycle via the team-select camera system (the local
	// player is TEAM_NONE on launch).  The togglemenu afterwards reopens the
	// main menu, because the engine auto-closes it when transitioning into
	// a map load.  Blank cl_menumap to disable the whole thing.
	//
	// Map picked from maps.txt in the gamedir (one name per line), so the
	// rotation covers every official map instead of always booting into the
	// same one.  cl_menumap is used as the fallback when maps.txt is
	// missing / empty, and still disables the backdrop when set to "none".
	//
	// cl_menu_backdrop_active is the persistent flag CSQC reads to suppress
	// HUD + team-select while the user is looking at the backdrop world.
	// It stays TRUE even after the main menu is closed (so pressing ESC on
	// the main menu leaves the user with a clean backdrop view), and gets
	// cleared only when the user transitions to a real server via Connect
	// or Create Server (see main_menu / create_server_launch).
	registercvar("cl_menumap", "surf_gigariver", 0);
	registercvar("cl_menu_backdrop_active", "0", 0);
	string menumap = Menu_PickMapFromFile();
	if (menumap == "")
		menumap = cvar_string("cl_menumap");
	if (menumap != "" && menumap != "none")
	{
		// Force >=2 maxclients + deathmatch so FTE's PAUSE_AUTO logic doesn't
		// engage.  The engine freezes single-slot listen servers whenever a
		// menu or console is up (sv_main.c PAUSE_AUTO check), which halts the
		// backdrop camera cycling.  Two slots bypasses that; data/server.cfg
		// can still raise it further.
		localcmd("set cl_menu_backdrop_active 1\n");
		localcmd("deathmatch 1\n");
		localcmd("maxclients 2\n");
		localcmd(sprintf("map %s\n", menumap));
		localcmd("togglemenu\n");
	}
};

vector() randomofs = { return [random() - 0.5, random() - 0.5] * 2; };

void(vector screensize) m_draw =
{
//	clearscene();

	
	vector realsize = getproperty(VF_SCREENPSIZE);
	float target_conauto = 2;
	if (realsize_y < 600) target_conauto = 1;
	else if (realsize_y < 1440) target_conauto = 2;
	else target_conauto = 4;
	
	if (target_conauto != cvar("vid_conautoscale")) localcmd(sprintf("vid_conautoscale %f\n", target_conauto));
	
	
	drawfont = menu_font;
	sui_begin(screensize_x, screensize_y);
	if (menu_active)
		root_menu(screensize);
	else if (m_loading_should_show())
	{
		// Main menu is closed but the engine hasn't raised scr_drawloading
		// yet (happens during the "Downloading maps/foo.bsp..." phase where
		// FTE pulls content before flagging a loading plaque).  Piggy-back
		// on m_draw to show our loading panel anyway; the guard keeps us
		// from covering the live game view during normal in-game play.
		sui_fill([0, 0], screensize, '0.01 0.01 0.02', 1, 0);
		m_loading_draw_panel(screensize);
	}

	if (time < splash_time)
	{
		sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
		float diff = splash_time - time;
		float a;
		if (diff > 2.5)
		{
			a = 1 - (diff - 2.5) * 2;
			float xstretch = (diff - 2.5) * 4;
			sui_fill([0, 0], screensize, '0 0 0', 1, 0);
			sui_pic(randomofs() * 1, [screensize_y * (0.7 + xstretch), screensize_y * 0.7], "gfx/splash.tga", '1 1 1', a * 0.75, 1);
			sui_pic(randomofs() * 1, [screensize_y * (0.7 + xstretch), screensize_y * 0.7], "gfx/splash.tga", '1 1 1', a * 0.75, 1);
		}
		else 
		{
			a = diff * 0.6;
			sui_fill([0, 0], screensize, '0 0 0', a * 2, 0);
			sui_pic(randomofs() * a, [screensize_y * 0.7, screensize_y * 0.7], "gfx/splash.tga", '1 1 1', a, 1);
			sui_pic(randomofs() * a, [screensize_y * (0.7 + random() * 0.05), screensize_y * 0.7], "gfx/splash.tga", '1 1 1', a * 0.5, 1);
		}
	}

	sui_menu_nav();
	
	sui_end();
};

void() m_close =
{
	Menu_SaveConfig();
	setkeydest(0);
	menu_active = FALSE;
	localcmd("set _nettest_menu_active 0\n");
};

void() m_open =
{
	setkeydest(2);
	menu_active = TRUE;
	localcmd("set _nettest_menu_active 1\n");
};

float(float evtype, float scanx, float chary, float devid) Menu_InputEvent =
{
	float used = sui_input_event(evtype, scanx, chary, devid);

	if (evtype == IE_KEYDOWN && !used)
	{
		switch (scanx)
		{
			case K_GP_START:
				m_close();
				return TRUE;
				break;
			default: break;
		}
		string cmd = getkeybind(scanx);
		switch (cmd)
		{
		case "togglemenu":
			m_close();
			return TRUE;
			break;
		default: break;
		}
	}
	return FALSE;
};

float(string cmd) m_consolecommand =
{
	tokenize(cmd);
	switch (argv(0))
	{
	default: break;
	}

	return FALSE;
};

void(float wantmode) m_toggle =
{
	if (menu_active) m_close();
	else m_open();
};

void() m_shutdown =
{
	Menu_SaveConfig();
	localcmd("set _nettest_menu_active 0\n");
};